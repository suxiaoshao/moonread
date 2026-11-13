use super::{LibraryEntry, LibraryItem, library_entry_row};
use crate::library::order::directory_order;
use crate::{BookTarget, LibrarySort, ReaderCore, ReaderError, ReadingKey, Result, parse_sha256};

impl ReaderCore {
    /// Reuse the file action envelope for the details page, with only file and
    /// progress fields. Full metadata and chapters come from book details.
    pub(crate) fn book_information_source(
        &self,
        target: BookTarget,
    ) -> Result<Option<LibraryEntry>> {
        let (predicate, value) = match target {
            BookTarget::File { file_id } => ("f.id=?1", file_id),
            BookTarget::Record {
                key: ReadingKey::Formal { sha256 },
            } => ("fi.content_sha256=?1", parse_sha256(sha256)?),
            _ => return Err(ReaderError::InvalidSettings),
        };
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let mut statement = tx.prepare_cached(&format!(
            "SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,
                f.directory,f.size,f.modified,f.needs_download,fi.associated_book_id,
                COALESCE(p.position_utf8,0),0,NULL,0,COALESCE(p.last_read,0),
                COALESCE(p.preferred_file_id=f.id,0),NULL,fi.content_sha256
             FROM library_files f JOIN library_shelves s ON s.id=f.shelf_id
             LEFT JOIN file_identities fi ON fi.file_id=f.id
             LEFT JOIN user_positions p ON p.content_key=fi.content_sha256
             WHERE f.directory=0 AND {predicate}",
        ))?;
        let mut selected: Option<LibraryEntry> = None;
        let mut rows = statement.query([value])?;
        while let Some(row) = rows.next()? {
            let source = library_entry_row(row)?;
            if selected.as_ref().is_none_or(|current| {
                directory_order(&source, current, LibrarySort::Reading).is_lt()
            }) {
                selected = Some(source);
            }
        }
        drop(rows);
        drop(statement);
        let Some(mut source) = selected else {
            return Ok(None);
        };
        if let LibraryItem::Book { row } = &mut source.item {
            let key = row.key().cloned().map(crate::serialize_reading_key);
            row.byte_count = tx.query_row(
                "SELECT COALESCE((SELECT MAX(utf8_bytes) FROM source_identities WHERE content_sha256=?1),
                    (SELECT byte_count FROM books WHERE id=?2),0)",
                (key, row.book_id()), |r| r.get::<_, i64>(0),
            )? as u64;
        }
        tx.commit()?;
        Ok(Some(source))
    }
}
