use super::*;
use rusqlite::Connection;
use rusqlite::params;
use std::sync::atomic::Ordering;
pub(crate) fn recover(db: &mut Connection) -> Result<()> {
    let tx = db.transaction()?;
    // No reading session or pending user data ever belongs to these drafts.
    // Keep canonical/shared text and anything already linked to a source.
    tx.execute("DELETE FROM books WHERE content_sha256 LIKE 'pending:%' AND NOT EXISTS(SELECT 1 FROM library_files WHERE book_id=books.id) AND EXISTS(SELECT 1 FROM import_jobs WHERE book_id=books.id AND purpose='restoration')", [])?;
    tx.execute("UPDATE import_jobs SET phase='paused' WHERE phase IN ('preparing','importing','finalizing')", [])?;
    tx.commit()?;
    Ok(())
}

impl ReaderCore {
    pub(super) fn reclaim_imports(
        &self,
        retained_book_ids: Vec<String>,
        only: Option<String>,
    ) -> Result<Vec<String>> {
        let mut active = self.imports.lock().map_err(|_| ReaderError::ImportBusy)?;
        if only.is_none() {
            active.retain(|_, token| token.strong_count() > 0);
        }
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let jobs = {
            let mut query =
                tx.prepare("SELECT book_id,canonical_id FROM import_jobs WHERE phase='complete' AND (?1 IS NULL OR book_id=?1)")?;
            query
                .query_map([only.as_deref()], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        for (id, canonical) in jobs {
            if retained_book_ids.contains(&id)
                || active
                    .get(&id)
                    .and_then(std::sync::Weak::upgrade)
                    .is_some_and(|token| token.running.load(Ordering::Acquire))
            {
                continue;
            }
            if let Some(canonical) = canonical {
                tx.execute(
                    "UPDATE library_files SET book_id=?1 WHERE book_id=?2",
                    params![canonical, id],
                )?;
                tx.execute(
                    "UPDATE source_imports SET book_id=?1 WHERE book_id=?2",
                    params![canonical, id],
                )?;
                // Marks have already been merged at promotion. Keep this in the
                // same transaction as relinking, so no foreign key can dangle.
                tx.execute("DELETE FROM books WHERE id=?1", [&id])?;
            } else {
                tx.execute("DELETE FROM import_jobs WHERE book_id=?1", [&id])?;
            }
        }
        let remaining = {
            let mut query =
                tx.prepare("SELECT book_id FROM import_jobs WHERE (?1 IS NULL OR book_id=?1)")?;
            query
                .query_map([only.as_deref()], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        tx.commit()?;
        active.retain(|id, _| {
            only.as_ref().is_some_and(|target| id != target) || remaining.contains(id)
        });
        self.import_failures
            .lock()
            .map_err(|_| ReaderError::ImportBusy)?
            .retain(|id, _| {
                only.as_ref().is_some_and(|target| id != target) || remaining.contains(id)
            });
        Ok(remaining)
    }
    pub(super) fn clean_duplicate(&self, id: &str) -> Result<()> {
        loop {
            let changed = self.lock()?.execute("DELETE FROM chunks WHERE book_id=?1 AND chunk_index IN (SELECT chunk_index FROM chunks WHERE book_id=?1 LIMIT 16)", [id])?;
            if changed == 0 {
                break;
            }
            std::thread::yield_now();
        }
        self.lock()?
            .execute("DELETE FROM import_chapters WHERE book_id=?1", [id])?;
        Ok(())
    }
}
