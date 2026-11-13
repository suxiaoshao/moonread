//! Derived body eviction. Never touches user facts, authorization, decoding or unfinished jobs.
use crate::{ReaderCore, Result, SourceFileSnapshot, parse_sha256};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedBody {
    pub book_id: String,
    pub content_sha256: String,
    pub title: String,
    pub bytes: u64,
    pub protected: bool,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CacheSummary {
    pub bytes: u64,
    pub protected: u64,
    pub bodies: u64,
}
fn in_use(db: &rusqlite::Connection, id: &str, protected: &[String]) -> Result<bool> {
    // Jobs protect their canonical text as well as their draft/paused prefix.
    Ok(protected.iter().any(|p| p == id)
        || db.query_row(
            "SELECT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 OR canonical_id=?1)",
            [id],
            |r| r.get::<_, bool>(0),
        )?)
}
#[uniffi::export]
impl ReaderCore {
    /// One read snapshot, separate from both the text writer and interactive reads.
    pub fn cache_summary(&self, protected_book_ids: Vec<String>) -> Result<CacheSummary> {
        let db =
            Connection::open_with_flags(&self.database_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        crate::identity::content::initialize(&db)?;
        let protected = serde_json::json!(protected_book_ids).to_string();
        Ok(db.query_row(
            "WITH available(sha) AS MATERIALIZED (
                SELECT DISTINCT fi.content_sha256 FROM file_identities fi
                JOIN main.library_files f ON f.id=fi.file_id
                WHERE f.directory=0 AND f.needs_download=0
             ),
             protected(id) AS MATERIALIZED (
                SELECT value FROM json_each(?1)
                UNION SELECT book_id FROM main.import_jobs
                UNION SELECT canonical_id FROM main.import_jobs WHERE canonical_id IS NOT NULL
             ),
             candidates(id, reclaimable) AS MATERIALIZED (
                SELECT b.id, a.sha IS NOT NULL AND p.id IS NULL FROM main.books b
                LEFT JOIN available a ON a.sha=b.content_sha256
                LEFT JOIN protected p ON p.id=b.id
                WHERE b.content_sha256 NOT LIKE 'pending:%' AND b.chunk_count>0
             )
             SELECT COALESCE(SUM(CASE WHEN reclaimable THEN
                        (SELECT SUM(length(CAST(text AS BLOB))) FROM main.chunks WHERE book_id=c.id)
                        ELSE 0 END), 0),
                    COUNT(*) FILTER (WHERE NOT reclaimable),
                    COUNT(*) FILTER (WHERE reclaimable)
             FROM candidates c",
            [protected],
            |r| {
                Ok(CacheSummary {
                    bytes: r.get::<_, i64>(0)? as u64,
                    protected: r.get::<_, i64>(1)? as u64,
                    bodies: r.get::<_, i64>(2)? as u64,
                })
            },
        )?)
    }

    pub fn cache_inventory(&self, protected_book_ids: Vec<String>) -> Result<Vec<CachedBody>> {
        let db = self.lock()?;
        let mut statement = db.prepare("SELECT b.id,b.content_sha256,b.title,COALESCE((SELECT SUM(length(CAST(text AS BLOB))) FROM chunks WHERE book_id=b.id),0) FROM books b WHERE b.content_sha256 NOT LIKE 'pending:%' AND b.chunk_count>0")?;
        let rows = statement
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i64>(3)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(|(id, sha, title, bytes)| {
                let protected = in_use(&db, &id, &protected_book_ids)?;
                Ok(CachedBody {
                    book_id: id,
                    content_sha256: sha,
                    title,
                    bytes: bytes as u64,
                    protected,
                })
            })
            .collect()
    }
    pub fn evict_cached_body(
        &self,
        book_id: String,
        content_sha256: String,
        verified_file: Option<SourceFileSnapshot>,
        protected_book_ids: Vec<String>,
        discard_offline: bool,
    ) -> Result<bool> {
        parse_sha256(content_sha256.clone())?;
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let sha: Option<String> = tx
            .query_row(
                "SELECT content_sha256 FROM books WHERE id=?1",
                [&book_id],
                |r| r.get(0),
            )
            .optional()?;
        if sha.as_deref() != Some(&content_sha256) || in_use(&tx, &book_id, &protected_book_ids)? {
            return Ok(false);
        }
        if !discard_offline {
            let Some(file) = verified_file else {
                return Ok(false);
            };
            let valid = tx.query_row("SELECT EXISTS(SELECT 1 FROM library_files f JOIN valid_indexed_identities v ON v.file_id=f.id WHERE f.id=?1 AND f.shelf_id=?2 AND f.relative_path=?3 AND f.size=?4 AND f.modified=?5 AND f.decoding=?6 AND v.content_sha256=?7 AND f.needs_download=0)",params![file.id,file.shelf_id,file.relative_path,file.size as i64,file.modified,file.decoding,content_sha256],|r|r.get::<_,bool>(0))?;
            if !valid {
                return Ok(false);
            }
        }
        // Valid indexed identities survive independently; future opens prepare text again.
        // Do not retain an empty canonical book: old importers would deduplicate into it.
        tx.execute(
            "UPDATE library_files SET book_id=NULL WHERE book_id=?1",
            [&book_id],
        )?;
        tx.execute("DELETE FROM books WHERE id=?1", [book_id])?;
        tx.commit()?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ScannedLibraryItem, SourceIdentityProbe};
    #[test]
    fn eviction_requires_current_rebuild_proof_and_preserves_index_facts_and_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        let path = dir.path().join("original.txt");
        std::fs::write(&path, "第一章 原创\n可重建的正文。\n").unwrap();
        let book = core
            .import_book(path.to_string_lossy().into(), "Original".into())
            .unwrap();
        core.save_library_shelf(
            "s".into(),
            "Shelf".into(),
            vec![1, 2],
            "local".into(),
            false,
        )
        .unwrap();
        let identity = SourceIdentityProbe::new()
            .identify(path.to_string_lossy().into(), "auto".into())
            .unwrap();
        core.scan_library_shelf(
            "s".into(),
            vec![ScannedLibraryItem {
                relative_path: "original.txt".into(),
                directory: false,
                size: identity.source_bytes,
                modified: 1,
                needs_download: false,
            }],
        )
        .unwrap();
        let file = core.source_file_snapshots(None).unwrap().remove(0);
        assert_eq!(
            core.cache_summary(vec![]).unwrap(),
            CacheSummary {
                bytes: 0,
                protected: 1,
                bodies: 0
            }
        );
        assert!(
            !core
                .evict_cached_body(
                    book.id.clone(),
                    book.reading_key.formal_sha().unwrap().to_owned(),
                    None,
                    vec![],
                    false
                )
                .unwrap()
        );
        core.publish_source_identity(file.clone(), identity)
            .unwrap();
        let summary = core.cache_summary(vec![]).unwrap();
        assert_eq!(summary.bodies, 1);
        assert_eq!(summary.protected, 0);
        assert_eq!(summary.bytes, book.byte_count);
        assert_eq!(
            core.cache_summary(vec![book.id.clone()]).unwrap(),
            CacheSummary {
                bytes: 0,
                protected: 1,
                bodies: 0
            }
        );
        assert!(
            !core
                .evict_cached_body(
                    book.id.clone(),
                    book.reading_key.formal_sha().unwrap().to_owned(),
                    Some(file.clone()),
                    vec![book.id.clone()],
                    false
                )
                .unwrap()
        );
        let mut changed = file.clone();
        changed.modified += 1;
        assert!(
            !core
                .evict_cached_body(
                    book.id.clone(),
                    book.reading_key.formal_sha().unwrap().to_owned(),
                    Some(changed),
                    vec![],
                    false
                )
                .unwrap()
        );
        let other = core.create_import("Unfinished".into()).unwrap();
        let before_jobs: i64 = core
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM import_jobs", [], |r| r.get(0))
            .unwrap();
        assert!(
            core.evict_cached_body(
                book.id.clone(),
                book.reading_key.formal_sha().unwrap().to_owned(),
                Some(file.clone()),
                vec![],
                false
            )
            .unwrap()
        );
        assert!(
            !core
                .pending_identity_files("s".into())
                .unwrap()
                .iter()
                .any(|f| f.id == file.id)
        );
        assert_eq!(
            core.file_identity(file.id).unwrap().key,
            Some(crate::ReadingKey::Formal {
                sha256: book.reading_key.formal_sha().unwrap().to_owned()
            })
        );
        assert_eq!(
            core.lock()
                .unwrap()
                .query_row("SELECT count(*) FROM import_jobs", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            before_jobs
        );
        assert_eq!(core.library_shelves().unwrap()[0].bookmark, vec![1, 2]);
        assert!(core.import_status(other.book_id()).is_ok());
        assert_eq!(core.cache_summary(vec![]).unwrap(), CacheSummary::default());
        let rebuilt = core
            .import_book(path.to_string_lossy().into(), "Rebuilt".into())
            .unwrap();
        assert_eq!(rebuilt.reading_key, book.reading_key);
        assert!(rebuilt.chunk_count > 0);
    }
}
