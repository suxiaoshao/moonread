//! Identity-only indexing. Neither publication nor lookup creates readable text.
use crate::{
    ReaderCore, ReaderError, Result, SourceFileSnapshot, SourceTextIdentity, decoding_policy,
};
use rusqlite::{OptionalExtension, params};

#[uniffi::export]
impl ReaderCore {
    pub fn indexed_source_keys(
        &self,
        shelf_id: Option<String>,
        file_id: Option<String>,
    ) -> Result<Vec<String>> {
        let db = self.lock()?;
        let mut stmt = db.prepare("SELECT DISTINCT s.content_sha256 FROM library_files f JOIN valid_indexed_identities s ON s.file_id=f.id WHERE (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR f.id=?2)")?;
        Ok(stmt
            .query_map(params![shelf_id, file_id], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?)
    }
    pub fn pending_identity_files(&self, shelf_id: String) -> Result<Vec<SourceFileSnapshot>> {
        let db = self.lock()?;
        crate::bookshelf::source_snapshots(
            &db,
            "WHERE f.directory=0 AND f.shelf_id=?1 AND NOT EXISTS(SELECT 1 FROM valid_indexed_identities v WHERE v.file_id=f.id) ORDER BY f.id",
            [shelf_id],
        )
    }

    pub fn publish_source_identity(
        &self,
        file: SourceFileSnapshot,
        identity: SourceTextIdentity,
    ) -> Result<bool> {
        let policy = decoding_policy(&file.decoding)?;
        if crate::parse_sha256(identity.raw_sha256.clone()).is_err()
            || crate::parse_sha256(identity.content_sha256.clone()).is_err()
            || identity.source_bytes != file.size
            || identity.utf8_bytes > i64::MAX as u64
            || identity.char_count > i64::MAX as u64
        {
            return Err(ReaderError::InvalidSettings);
        }
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let exists = tx.query_row("SELECT 1 FROM library_files WHERE id=?1 AND shelf_id=?2 AND relative_path=?3 AND directory=0 AND size=?4 AND modified=?5 AND decoding=?6",params![file.id,file.shelf_id,file.relative_path,file.size as i64,file.modified,policy], |_|Ok(())).optional()?.is_some();
        if !exists {
            return Ok(false);
        }
        tx.execute("INSERT INTO source_identities VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(raw_sha256,decoding) DO UPDATE SET content_sha256=excluded.content_sha256,encoding=excluded.encoding,utf8_bytes=excluded.utf8_bytes,char_count=excluded.char_count",params![identity.raw_sha256,policy,identity.content_sha256,identity.encoding,identity.utf8_bytes as i64,identity.char_count as i64])?;
        tx.execute(
            "INSERT OR REPLACE INTO library_identities VALUES(?1,?2,?3,?4,?5)",
            params![
                file.id,
                identity.raw_sha256,
                policy,
                file.size as i64,
                file.modified
            ],
        )?;
        tx.commit()?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ScannedLibraryItem, SourceIdentityProbe};
    fn scan(core: &ReaderCore, size: u64, modified: i64) {
        core.scan_library_shelf(
            "s".into(),
            vec![ScannedLibraryItem {
                relative_path: "sample.txt".into(),
                directory: false,
                size,
                modified,
                needs_download: false,
            }],
        )
        .unwrap();
    }
    #[test]
    fn full_index_matches_open_utf8_and_gbk() {
        let dir = tempfile::tempdir().unwrap();
        let plain = "第一章 月港\n林舟在窗边读书。\n";
        for (i, bytes) in [
            plain.as_bytes().to_vec(),
            encoding_rs::GB18030.encode(plain).0.into_owned(),
        ]
        .into_iter()
        .enumerate()
        {
            let path = dir.path().join(format!("{i}.txt"));
            std::fs::write(&path, bytes).unwrap();
            let core = ReaderCore::new(
                dir.path()
                    .join(format!("cache-{i}"))
                    .to_string_lossy()
                    .into(),
            )
            .unwrap();
            let identity = SourceIdentityProbe::new()
                .identify(path.to_string_lossy().into(), "auto".into())
                .unwrap();
            assert_eq!(
                core.lock()
                    .unwrap()
                    .query_row("SELECT count(*) FROM chunks", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                0
            );
            let task = core.create_import("Original".into()).unwrap();
            core.stream_import(
                task.clone(),
                path.to_string_lossy().into(),
                identity.raw_sha256.clone(),
                None,
            )
            .unwrap();
            let id = core.finish_import(task).unwrap();
            let db = core.lock().unwrap();
            let (sha, count):(String,i64) = db.query_row("SELECT content_sha256,(SELECT max(end_char_count) FROM chunks WHERE book_id=books.id) FROM books WHERE id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?))).unwrap();
            assert_eq!(sha, identity.content_sha256);
            assert_eq!(count as u64, identity.char_count);
        }
    }
    #[test]
    fn full_index_skips_unchanged_and_recomputes_changed_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sample.txt");
        std::fs::write(&path, "原创正文。\n").unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        let identity = SourceIdentityProbe::new()
            .identify(path.to_string_lossy().into(), "auto".into())
            .unwrap();
        scan(&core, identity.source_bytes, 1);
        let file = core.pending_identity_files("s".into()).unwrap().remove(0);
        assert!(
            core.publish_source_identity(file.clone(), identity.clone())
                .unwrap()
        );
        scan(&core, identity.source_bytes, 1);
        assert!(core.pending_identity_files("s".into()).unwrap().is_empty());
        scan(&core, identity.source_bytes, 2);
        assert_eq!(core.pending_identity_files("s".into()).unwrap().len(), 1);
        assert!(
            !core
                .publish_source_identity(file, identity.clone())
                .unwrap()
        );
        let fresh = core.pending_identity_files("s".into()).unwrap().remove(0);
        assert!(core.publish_source_identity(fresh, identity).unwrap());
        assert!(core.pending_identity_files("s".into()).unwrap().is_empty());
    }
    #[test]
    fn full_index_v21_to_v22_preserves_files() {
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("schema.sql")).unwrap();
        db.execute_batch("ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading'; PRAGMA user_version=21; INSERT INTO library_shelves VALUES('s','Shelf',X'0102','local',0,NULL);").unwrap();
        crate::migrations::initialize(&mut db).unwrap();
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            22
        );
        assert_eq!(
            db.query_row("SELECT bookmark FROM library_shelves", [], |r| r
                .get::<_, Vec<u8>>(0))
                .unwrap(),
            vec![1, 2]
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM source_identities", [], |r| r
                .get::<_, u32>(0))
                .unwrap(),
            0
        );
    }
}
