use super::*;
use encoding_rs::Encoding;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
use std::fs::File;
use std::io::Seek;
use std::io::SeekFrom;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use uuid::Uuid;
impl ReaderCore {
    // Kept private: callers cannot assign arbitrary persisted task purposes.
    fn create_import_for_purpose(
        &self,
        title: String,
        purpose: &str,
    ) -> Result<Arc<ImportControl>> {
        let id = Uuid::new_v4().to_string();
        {
            let mut db = self.lock()?;
            let tx = db.transaction()?;
            tx.execute(
                "INSERT INTO books(id,title,content_sha256,encoding) VALUES(?1,?2,?3,'')",
                params![
                    id,
                    if title.trim().is_empty() {
                        "未命名文本"
                    } else {
                        &title
                    },
                    format!("pending:{id}")
                ],
            )?;
            tx.execute(
                "INSERT INTO import_jobs(book_id,purpose) VALUES(?1,?2)",
                params![id, purpose],
            )?;
            tx.commit()?;
        }
        self.resume_import(id)
    }
}
#[uniffi::export]
impl ImportControl {
    pub fn book_id(&self) -> String {
        self.id.clone()
    }
    pub fn pause(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

#[uniffi::export]
impl ReaderCore {
    /// Completed jobs are session scaffolding, not permanent book identities.
    /// The platform retains IDs while readers or workers may still use them.
    /// Pending position choices remain durable until the user resolves them.
    /// Returns the remaining job IDs, also allowing platform storage to recover
    /// if the process died between the SQLite commit and bookmark cleanup.
    pub fn reclaim_completed_imports(&self, retained_book_ids: Vec<String>) -> Result<Vec<String>> {
        self.reclaim_imports(retained_book_ids, None)
    }
    /// The hot path cleans only the released draft, never every completed job.
    pub fn reclaim_completed_import(&self, book_id: String) -> Result<bool> {
        Ok(self.reclaim_imports(Vec::new(), Some(book_id))?.is_empty())
    }

    /// Only the unpublished cache draft owned by a completed restoration worker
    /// is disposable. Never remove canonical/shared text or any linked source.
    pub fn discard_restoration_import(&self, control: Arc<ImportControl>) -> Result<()> {
        if control.running.load(Ordering::Acquire) {
            return Err(ReaderError::ImportBusy);
        }
        let db = self.lock()?;
        let owned = db.query_row("SELECT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND generation=?2 AND purpose='restoration')", params![control.id,control.generation as i64], |r| r.get::<_, bool>(0))?;
        if !owned {
            return Err(ReaderError::ImportBusy);
        }
        db.execute("DELETE FROM books WHERE id=?1 AND content_sha256 LIKE 'pending:%' AND NOT EXISTS(SELECT 1 FROM library_files WHERE book_id=?1) AND EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND generation=?2)", params![control.id,control.generation as i64])?;
        drop(db);
        let _ = self.reclaim_completed_import(control.id.clone());
        Ok(())
    }

    pub fn create_import(&self, title: String) -> Result<Arc<ImportControl>> {
        self.create_import_for_purpose(title, "reading")
    }

    pub fn create_restoration_import(&self, title: String) -> Result<Arc<ImportControl>> {
        self.create_import_for_purpose(title, "restoration")
    }

    pub fn resume_import(&self, book_id: String) -> Result<Arc<ImportControl>> {
        let mut active = self.imports.lock().map_err(|_| ReaderError::ImportBusy)?;
        if active
            .get(&book_id)
            .and_then(std::sync::Weak::upgrade)
            .is_some_and(|token| token.running.load(Ordering::Acquire))
        {
            return Err(ReaderError::ImportBusy);
        }
        let db = self.lock()?;
        let changed = db.execute("UPDATE import_jobs SET phase='preparing',generation=generation+1,error=NULL,final_sha=NULL
            WHERE book_id=?1 AND phase!='complete'", [&book_id])?;
        if changed != 1 {
            return Err(ReaderError::ImportBusy);
        }
        let generation = snapshot(&db, &book_id)?.generation;
        let control = Arc::new(ImportControl {
            id: book_id.clone(),
            generation,
            cancelled: AtomicBool::new(false),
            running: AtomicBool::new(false),
        });
        active.insert(book_id, Arc::downgrade(&control));
        if let Ok(mut failures) = self.import_failures.lock() {
            failures.remove(&control.id);
        }
        Ok(control)
    }

    /// Unchanged-source fast path: no draft text has ever been presented.
    pub fn reuse_import(&self, control: Arc<ImportControl>, existing_id: String) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        self.check_control(&tx, &control)?;
        let _ = book(&tx, &existing_id)?;
        tx.execute(
            "UPDATE import_jobs SET canonical_id=?1,phase='complete',has_text=1 WHERE book_id=?2",
            params![existing_id, control.id],
        )?;
        tx.execute(
            "UPDATE library_files SET book_id=?1 WHERE book_id=?2",
            params![existing_id, control.id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Runs on the platform's background coordinated accessor; cancellation is
    /// checked between bounded reads, without holding the database lock.
    pub fn hash_import_source(
        &self,
        control: Arc<ImportControl>,
        file_path: String,
    ) -> Result<String> {
        crate::identity::source::hash_source(&mut File::open(file_path)?, || {
            control.cancelled.load(Ordering::Acquire)
        })
    }

    pub fn validate_import_source(
        &self,
        control: Arc<ImportControl>,
        key: crate::SourceContentKey,
    ) -> Result<()> {
        if !crate::valid_source_key(&key) {
            return Err(ReaderError::InvalidSettings);
        }
        let policy = crate::decoding_policy(&key.decoding)?;
        let db = self.lock()?;
        self.check_control(&db, &control)?;
        let previous: (Option<String>, Option<String>) = db.query_row(
            "SELECT expected_raw_sha256,decoding FROM import_jobs WHERE book_id=?1",
            [&control.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if previous.0.as_ref().is_some_and(|p| p != &key.raw_sha256)
            || previous.1.as_deref().is_some_and(|p| p != policy)
        {
            return Err(ReaderError::SourceChanged);
        }
        db.execute(
            "UPDATE import_jobs SET expected_raw_sha256=?1,decoding=?2 WHERE book_id=?3",
            params![key.raw_sha256, policy, control.id],
        )?;
        Ok(())
    }

    /// Expected bytes are checked before prefix replay and against the exact
    /// input consumed by the decoder before any fast-open mapping is published.
    pub fn stream_import(
        &self,
        control: Arc<ImportControl>,
        file_path: String,
        expected_raw_sha256: String,
        encoding_override: Option<String>,
    ) -> Result<()> {
        if !crate::valid_sha(&expected_raw_sha256) {
            return Err(ReaderError::InvalidSettings);
        }
        if control.running.swap(true, Ordering::AcqRel) {
            return Err(ReaderError::ImportBusy);
        }
        let result = (|| {
            let mut file = File::open(file_path)?;
            let state = self.reading_snapshot(control.id.clone())?;
            let decoding = crate::decoding_policy(encoding_override.as_deref().unwrap_or("auto"))?;
            self.validate_import_source(
                control.clone(),
                crate::SourceContentKey {
                    raw_sha256: expected_raw_sha256.clone(),
                    decoding: decoding.into(),
                },
            )?;
            let encoding = if state.book.chunk_count > 0 {
                Encoding::for_label(state.book.encoding.as_bytes())
                    .ok_or(ReaderError::InvalidSettings)?
            } else if decoding != "auto" {
                Encoding::for_label(decoding.as_bytes()).ok_or(ReaderError::InvalidSettings)?
            } else {
                crate::reading::text::detect_encoding(&mut file)?
            };
            file.seek(SeekFrom::Start(0))?;
            {
                let db = self.lock()?;
                self.check_control(&db, &control)?;
                db.execute(
                    "UPDATE books SET encoding=?1 WHERE id=?2",
                    params![encoding.name(), control.id],
                )?;
                db.execute(
                    "UPDATE import_jobs SET phase='importing',source_size=?1 WHERE book_id=?2",
                    params![file.metadata()?.len() as i64, control.id],
                )?;
            }
            self.stream_reader(&control, &mut file, encoding)?;
            Ok(())
        })();
        control.running.store(false, Ordering::Release);
        if let Err(error) = result {
            let error = if control.cancelled.load(Ordering::Acquire) {
                ReaderError::Paused
            } else {
                error
            };
            self.fail_import(control, error.clone())?;
            return Err(error);
        }
        Ok(())
    }

    pub fn fail_import(&self, control: Arc<ImportControl>, error: ReaderError) -> Result<()> {
        let paused = control.cancelled.load(Ordering::Acquire);
        if let Ok(mut failures) = self.import_failures.lock() {
            failures.insert(
                control.id.clone(),
                ImportFailure {
                    generation: control.generation,
                    paused,
                    error: error.clone(),
                },
            );
        }
        let json = serde_json::to_string(&error).map_err(|e| ReaderError::Storage {
            message: e.to_string(),
        })?;
        let db = self.lock()?;
        db.execute("UPDATE import_jobs SET phase=?1,error=?2 WHERE book_id=?3 AND generation=?4 AND phase!='complete'",
            params![if paused { "paused" } else { "failed" }, if paused { None } else { Some(json) }, control.id,control.generation as i64])?;
        Ok(())
    }

    pub fn finish_import(&self, control: Arc<ImportControl>) -> Result<String> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        self.check_control(&tx, &control)?;
        let hash: String = tx.query_row(
            "SELECT final_sha FROM import_jobs WHERE book_id=?1 AND phase='finalizing'",
            [&control.id],
            |r| r.get(0),
        )?;
        let existing: Option<String> = tx
            .query_row(
                "SELECT id FROM reading_books WHERE content_sha256=?1",
                [&hash],
                |r| r.get(0),
            )
            .optional()?;
        let canonical = existing.unwrap_or_else(|| control.id.clone());
        if canonical == control.id {
            tx.execute(
                "UPDATE books SET content_sha256=?1 WHERE id=?2",
                params![hash, control.id],
            )?;
            tx.execute(
                "UPDATE import_jobs SET phase='complete',error=NULL WHERE book_id=?1",
                [&control.id],
            )?;
        } else {
            tx.execute("UPDATE import_jobs SET phase='complete',canonical_id=?1,error=NULL WHERE book_id=?2", params![canonical,control.id])?;
        }
        tx.execute("INSERT INTO source_imports(raw_sha256,decoding,book_id) SELECT expected_raw_sha256,decoding,?1 FROM import_jobs WHERE book_id=?2 AND expected_raw_sha256 IS NOT NULL ON CONFLICT(raw_sha256,decoding) DO UPDATE SET book_id=excluded.book_id",params![canonical,control.id])?;
        tx.execute(
            "UPDATE library_files SET book_id=?1 WHERE book_id=?2",
            params![canonical, control.id],
        )?;
        tx.commit()?;
        drop(db);
        // The alias is already atomically readable from the canonical text.
        // Reclaim duplicate text in small transactions; retain its checkpoint.
        if canonical != control.id {
            let _ = self.clean_duplicate(&control.id);
        }
        Ok(canonical)
    }
}

impl ReaderCore {
    pub(super) fn runtime_state(&self, mut state: ReadingSnapshot) -> ReadingSnapshot {
        if state.phase == ImportPhase::Complete {
            return state;
        }
        if let Ok(failures) = self.import_failures.lock()
            && let Some(failure) = failures.get(&state.book.id)
            && failure.generation == state.generation
        {
            state.phase = if failure.paused {
                ImportPhase::Paused
            } else {
                ImportPhase::Failed
            };
            state.error = (!failure.paused).then(|| failure.error.clone());
            return state;
        }
        if matches!(
            state.phase,
            ImportPhase::Preparing | ImportPhase::Importing | ImportPhase::Finalizing
        ) && let Ok(active) = self.imports.lock()
            && active
                .get(&state.book.id)
                .and_then(std::sync::Weak::upgrade)
                .is_none()
        {
            state.phase = ImportPhase::Paused;
        }
        state
    }

    pub(super) fn check_control(&self, db: &Connection, token: &ImportControl) -> Result<()> {
        if token.cancelled.load(Ordering::Acquire) {
            return Err(ReaderError::Paused);
        }
        let valid: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND generation=?2 AND phase IN ('preparing','importing','finalizing'))",
            params![token.id,token.generation as i64], |r| r.get(0))?;
        if valid {
            Ok(())
        } else {
            Err(ReaderError::ImportBusy)
        }
    }
}
