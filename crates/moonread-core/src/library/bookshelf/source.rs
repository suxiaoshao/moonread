use super::*;
use rusqlite::Connection;
use rusqlite::params;
#[uniffi::export]
impl ReaderCore {
    pub fn source_file_snapshots(
        &self,
        file_id: Option<String>,
    ) -> Result<Vec<SourceFileSnapshot>> {
        let db = self.lock()?;
        if let Some(id) = file_id {
            source_snapshots(&db, "WHERE f.id=?1 AND f.directory=0", [id])
        } else {
            source_snapshots(&db, "WHERE f.directory=0 ORDER BY f.id", [])
        }
    }

    pub fn source_decoding(&self, file_id: String) -> Result<String> {
        Ok(self.lock()?.query_row(
            "SELECT decoding FROM library_files WHERE id=?1 AND directory=0",
            [file_id],
            |r| r.get(0),
        )?)
    }
    pub fn set_source_decoding(&self, file_id: String, decoding: String) -> Result<()> {
        let policy = crate::decoding_policy(&decoding)?;
        let db = self.lock()?;
        if db.execute(
            "UPDATE library_files SET decoding=?1 WHERE id=?2 AND directory=0",
            params![policy, file_id],
        )? == 0
        {
            return Err(ReaderError::InvalidSettings);
        }
        Ok(())
    }

    pub fn source_file_location(&self, file_id: String) -> Result<SourceFileLocation> {
        let entry = self.library_entry(file_id)?;
        Ok(SourceFileLocation {
            id: entry.id,
            directory: entry.directory,
            shelf_id: entry.shelf_id,
            relative_path: entry.relative_path,
            book_id: entry.book_id,
        })
    }
}

#[uniffi::export]
impl ReaderCore {
    /// File operations consume index locations, never a user-facing book projection.
    pub fn source_files(&self, shelf_id: String) -> Result<Vec<SourceFileLocation>> {
        Ok(self
            .library_entries(Some(shelf_id), None, LibrarySort::Name)?
            .into_iter()
            .map(|entry| SourceFileLocation {
                id: entry.id,
                directory: entry.directory,
                shelf_id: entry.shelf_id,
                relative_path: entry.relative_path,
                book_id: entry.book_id,
            })
            .collect())
    }
}

pub(crate) fn source_snapshots<P: rusqlite::Params>(
    db: &Connection,
    condition: &str,
    params: P,
) -> Result<Vec<SourceFileSnapshot>> {
    let sql = format!(
        "SELECT f.id,f.shelf_id,f.relative_path,f.size,f.modified,f.needs_download,f.book_id,f.decoding FROM library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id {condition}"
    );
    let mut stmt = db.prepare(&sql)?;
    Ok(stmt
        .query_map(params, |r| {
            Ok(SourceFileSnapshot {
                id: r.get(0)?,
                shelf_id: r.get(1)?,
                relative_path: r.get(2)?,
                size: r.get::<_, i64>(3)? as u64,
                modified: r.get(4)?,
                needs_download: r.get(5)?,
                book_id: r.get(6)?,
                decoding: r.get(7)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}
