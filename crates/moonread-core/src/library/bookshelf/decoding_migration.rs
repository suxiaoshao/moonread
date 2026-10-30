use super::*;
use rusqlite::params;

#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceDecodingMigration {
    pub file_id: String,
    pub shelf_id: String,
    pub relative_path: String,
    pub size: u64,
    pub modified: i64,
    pub decoding: String,
    pub raw_sha256: Option<String>,
}

#[uniffi::export]
impl ReaderCore {
    /// Rows survive scans, missing originals and SwiftData save failures.
    pub fn source_decoding_migrations(&self) -> Result<Vec<SourceDecodingMigration>> {
        let db = self.lock()?;
        let mut stmt = db.prepare("SELECT file_id,shelf_id,relative_path,size,modified,decoding,raw_sha256 FROM source_decoding_migration ORDER BY file_id")?;
        Ok(stmt
            .query_map([], |r| {
                Ok(SourceDecodingMigration {
                    file_id: r.get(0)?,
                    shelf_id: r.get(1)?,
                    relative_path: r.get(2)?,
                    size: r.get::<_, i64>(3)? as u64,
                    modified: r.get(4)?,
                    decoding: r.get(5)?,
                    raw_sha256: r.get(6)?,
                })
            })?
            .collect::<std::result::Result<_, _>>()?)
    }
    /// Called only after the corresponding epoch candidate is saved in SwiftData.
    pub fn finish_source_decoding_migration(&self, file_id: String) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        tx.execute(
            "DELETE FROM source_decoding_migration WHERE file_id=?1",
            params![file_id],
        )?;
        tx.commit()?;
        Ok(())
    }
}
