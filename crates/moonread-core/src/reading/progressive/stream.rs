use super::*;
use encoding_rs::Encoding;
use rusqlite::params;
use sha2::Digest;
use sha2::Sha256;
use std::io::Read;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;
impl ReaderCore {
    pub(super) fn stream_reader(
        &self,
        token: &ImportControl,
        reader: &mut impl Read,
        encoding: &'static Encoding,
    ) -> Result<()> {
        let old = self.reading_snapshot(token.id.clone())?;
        let count = AtomicU64::new(0);
        let mut input = CountingReader {
            reader,
            count: &count,
            token,
            hash: Sha256::new(),
        };
        let mut hasher = Sha256::new();
        let mut scanner = ChapterScanner::default();
        let mut blanks = crate::reading::layout::BlankScanner::default();
        let mut index = 0u32;
        let mut offset = 0u64;
        let mut visible = false;
        let mut published_visible = old.can_read;
        let mut batch: Vec<(TextChunk, u64, u64)> = Vec::new();
        let mut batch_bytes = 0usize;
        let mut last_commit = Instant::now();
        let mut consume = |text: &str| {
            if token.cancelled.load(Ordering::Acquire) {
                return Err(ReaderError::Paused);
            }
            let end = offset
                .checked_add(text.len() as u64)
                .filter(|v| *v <= i64::MAX as u64)
                .ok_or(ReaderError::InvalidSettings)?;
            visible |= text.chars().any(|c| !c.is_whitespace());
            hasher.update(text.as_bytes());
            let start_count = scanner.char_count;
            scanner.push_chunk(offset, text);
            blanks.push(text);
            if index < old.book.chunk_count {
                scanner.chapters.clear();
                blanks.discard_published_prefix();
            } else {
                batch.push((
                    TextChunk {
                        index,
                        start_utf8: offset,
                        end_utf8: end,
                        text: text.to_owned(),
                    },
                    start_count,
                    scanner.char_count,
                ));
                batch_bytes += text.len();
            }
            offset = end;
            index = index.checked_add(1).ok_or(ReaderError::InvalidSettings)?;
            if !batch.is_empty()
                && ((!published_visible && visible)
                    || batch_bytes >= 128 * 1024
                    || last_commit.elapsed() >= Duration::from_millis(80))
            {
                self.commit_prefix(
                    token,
                    &mut batch,
                    &mut scanner.chapters,
                    &mut blanks,
                    visible,
                    count.load(Ordering::Relaxed),
                )?;
                published_visible = visible;
                batch_bytes = 0;
                last_commit = Instant::now();
            }
            Ok(())
        };
        // Recovery-v1 can change decoder output/chunk boundaries around malformed
        // input. Compare the old published prefix byte-for-byte and feed it back
        // at its original boundaries, preserving chunks, offsets and pending data.
        // No failed task or user facts are discarded and its recorded encoding stays fixed.
        let mut replay_index = 0;
        let mut replay_at = 0;
        let mut replay_end = 0;
        let mut replay = if old.book.chunk_count > 0 {
            Some(chunk(&*self.read_lock()?, &token.id, 0)?)
        } else {
            None
        };
        crate::reading::text::decode_chunks(&mut input, encoding, |mut text| {
            while !text.is_empty() {
                if let Some(stored) = replay.as_ref() {
                    if stored.start_utf8 != replay_end
                        || stored.end_utf8 != stored.start_utf8 + stored.text.len() as u64
                    {
                        return Err(ReaderError::SourceChanged);
                    }
                    let length = text.len().min(stored.text.len() - replay_at);
                    if text.as_bytes()[..length]
                        != stored.text.as_bytes()[replay_at..replay_at + length]
                    {
                        return Err(ReaderError::SourceChanged);
                    }
                    replay_at += length;
                    text = &text[length..];
                    if replay_at == stored.text.len() {
                        consume(&stored.text)?;
                        replay_end = stored.end_utf8;
                        replay_index += 1;
                        replay_at = 0;
                        replay = if replay_index < old.book.chunk_count {
                            Some(chunk(&*self.read_lock()?, &token.id, replay_index)?)
                        } else {
                            None
                        };
                    }
                } else {
                    consume(text)?;
                    break;
                }
            }
            Ok(())
        })?;
        let raw_sha = sha256_hex(input.hash.finalize());
        let expected: Option<String> = self.lock()?.query_row(
            "SELECT expected_raw_sha256 FROM import_jobs WHERE book_id=?1",
            [&token.id],
            |r| r.get(0),
        )?;
        if expected.as_ref().is_some_and(|value| value != &raw_sha) {
            return Err(ReaderError::SourceChanged);
        }
        if index < old.book.chunk_count {
            return Err(ReaderError::SourceChanged);
        }
        if !visible {
            return Err(ReaderError::EmptyBook);
        }
        scanner.finish_line();
        blanks.finish_line();
        self.commit_prefix(
            token,
            &mut batch,
            &mut scanner.chapters,
            &mut blanks,
            visible,
            count.load(Ordering::Relaxed),
        )?;
        let db = self.lock()?;
        self.check_control(&db, token)?;
        db.execute(
            "UPDATE import_jobs SET phase='finalizing',final_sha=?1,bytes_read=?2 WHERE book_id=?3",
            params![
                sha256_hex(hasher.finalize()),
                count.load(Ordering::Relaxed) as i64,
                token.id
            ],
        )?;
        Ok(())
    }

    pub(super) fn commit_prefix(
        &self,
        token: &ImportControl,
        batch: &mut Vec<(TextChunk, u64, u64)>,
        chapters: &mut Vec<IndexedChapter>,
        blanks: &mut crate::reading::layout::BlankScanner,
        visible: bool,
        read: u64,
    ) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        self.check_control(&tx, token)?;
        for (chunk, start_count, end_count) in batch.iter() {
            tx.execute(
                "INSERT INTO chunks VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    token.id,
                    chunk.index,
                    chunk.start_utf8 as i64,
                    chunk.end_utf8 as i64,
                    chunk.text,
                    *start_count as i64,
                    *end_count as i64
                ],
            )?;
        }
        if let Some((last, _, _)) = batch.last() {
            tx.execute(
                "UPDATE books SET byte_count=?1,chunk_count=?2 WHERE id=?3",
                params![last.end_utf8 as i64, last.index + 1, token.id],
            )?;
        }
        blanks.publish(&tx, &token.id)?;
        for chapter in chapters.iter() {
            tx.execute(
                "INSERT OR IGNORE INTO import_chapters VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    token.id,
                    chapter.start_utf8 as i64,
                    chapter.title,
                    chapter.level,
                    chapter.start_char_count as i64,
                    chapter.body_char_count as i64
                ],
            )?;
        }
        tx.execute(
            "UPDATE import_jobs SET has_text=?1,bytes_read=?2 WHERE book_id=?3",
            params![visible, read as i64, token.id],
        )?;
        tx.commit()?;
        batch.clear();
        chapters.clear();
        Ok(())
    }
}
struct CountingReader<'a, R> {
    reader: &'a mut R,
    count: &'a AtomicU64,
    token: &'a ImportControl,
    hash: Sha256,
}
impl<R: Read> Read for CountingReader<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.token.cancelled.load(Ordering::Acquire) {
            return Err(std::io::Error::other("导入已暂停"));
        }
        let n = self.reader.read(buffer)?;
        self.hash.update(&buffer[..n]);
        self.count.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}
