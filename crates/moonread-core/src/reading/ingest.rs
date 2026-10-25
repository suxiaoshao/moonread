//! Transactional normalized text ingestion; source bytes remain untouched.
use crate::*;
use encoding_rs::Encoding;
use rusqlite::OptionalExtension;
use rusqlite::params;
use sha2::Digest;
use sha2::Sha256;
use std::io::Read;
use uuid::Uuid;
impl ReaderCore {
    pub(crate) fn ingest(
        &self,
        reader: &mut impl Read,
        title: String,
        encoding: &'static Encoding,
    ) -> Result<BookInfo> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let id = Uuid::new_v4().to_string();
        let title = if title.trim().is_empty() {
            "未命名文本".into()
        } else {
            title
        };
        tx.execute(
            "INSERT INTO books(id,title,content_sha256,encoding) VALUES(?1,?2,?3,?4)",
            params![id, title, format!("pending:{id}"), encoding.name()],
        )?;
        let mut hasher = Sha256::new();
        let mut offset = 0u64;
        let mut index = 0u32;
        let mut has_visible_text = false;
        let mut scanner = ChapterScanner::default();
        let mut blanks = crate::reading::layout::BlankScanner::default();
        crate::reading::text::decode_chunks(reader, encoding, |text| {
            has_visible_text |= text.chars().any(|c| !c.is_whitespace());
            let end = offset
                .checked_add(text.len() as u64)
                .ok_or(ReaderError::TextCapacityExceeded)?;
            if end > i64::MAX as u64 {
                return Err(ReaderError::TextCapacityExceeded);
            }
            let start_count = scanner.char_count;
            scanner.push_chunk(offset, text);
            blanks.push(text);
            tx.execute(
                "UPDATE books SET byte_count=?2 WHERE id=?1",
                params![id, end as i64],
            )?;
            blanks.publish(&tx, &id)?;
            tx.execute(
                "INSERT INTO chunks VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    id,
                    index,
                    offset as i64,
                    end as i64,
                    text,
                    start_count as i64,
                    scanner.char_count as i64
                ],
            )?;
            hasher.update(text.as_bytes());
            offset = end;
            index = index
                .checked_add(1)
                .ok_or(ReaderError::TextCapacityExceeded)?;
            Ok(())
        })?;
        if !has_visible_text {
            return Err(ReaderError::EmptyBook);
        }
        blanks.finish_line();
        blanks.publish(&tx, &id)?;
        let hash = sha256_hex(hasher.finalize());
        let existing: Option<String> = tx
            .query_row(
                "SELECT id FROM reading_books WHERE content_sha256=?1",
                [&hash],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            // Drop rolls back all staged cache rows and preserves the existing title/progress.
            return book(&tx, &existing);
        }
        tx.execute(
            "UPDATE books SET content_sha256=?1,byte_count=?2,chunk_count=?3 WHERE id=?4",
            params![hash, offset as i64, index, id],
        )?;
        for heading in scanner.finish() {
            tx.execute(
                "INSERT INTO import_chapters VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    id,
                    heading.start_utf8 as i64,
                    heading.title,
                    heading.level,
                    heading.start_char_count as i64,
                    heading.body_char_count as i64
                ],
            )?;
        }
        let result = book(&tx, &id)?;
        tx.commit()?;
        Ok(result)
    }
}
