//! A committed, immutable prefix is readable while the rest is being imported.
use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ImportPhase {
    Preparing,
    Importing,
    Finalizing,
    Complete,
    Paused,
    Failed,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingSnapshot {
    /// For a draft/alias this ID stays stable throughout the reading session.
    pub book: BookInfo,
    pub phase: ImportPhase,
    pub generation: u64,
    pub can_read: bool,
    /// Formal reading activity, including the first body position (offset 0).
    /// Preparing or viewing a cover does not start reading.
    pub has_started: bool,
    pub source_bytes_read: u64,
    pub source_byte_count: u64,
    pub error: Option<ReaderError>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingDirection {
    Forward,
    Backward,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingWindowStatus {
    Ready,
    Awaiting,
    End,
    Beginning,
    Deferred,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SourceSpan {
    pub start_utf8: u64,
    pub end_utf8: u64,
}

#[derive(Debug, uniffi::Record)]
pub struct ReadingFrame {
    pub snapshot: ReadingSnapshot,
    pub chunks: Vec<TextChunk>,
    pub paragraphs: Vec<ReadingParagraph>,
    pub is_end_of_book: bool,
    pub omitted: Vec<SourceSpan>,
    pub source_start: u64,
    pub source_end: u64,
    pub cursor: u64,
    /// A loaded retained scalar, including paragraph whitespace; not an ink witness.
    pub projection_anchor: Option<u64>,
    pub has_non_whitespace_payload: bool,
    pub status: ReadingWindowStatus,
    pub next_cursor: Option<u64>,
    pub previous_cursor: Option<u64>,
    pub projection_revision: u64,
}

#[derive(uniffi::Object)]
pub struct ImportControl {
    id: String,
    generation: u64,
    cancelled: AtomicBool,
    running: AtomicBool,
}

#[derive(Clone)]
pub(super) struct ImportFailure {
    generation: u64,
    paused: bool,
    error: ReaderError,
}

impl ReaderCore {
    fn reclaim_imports(
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

pub(super) fn recover(db: &Connection) {
    let _ = db.execute("UPDATE import_jobs SET phase='paused' WHERE phase IN ('preparing','importing','finalizing')", []);
}

fn phase(value: &str) -> ImportPhase {
    match value {
        "preparing" => ImportPhase::Preparing,
        "importing" => ImportPhase::Importing,
        "finalizing" => ImportPhase::Finalizing,
        "complete" => ImportPhase::Complete,
        "failed" => ImportPhase::Failed,
        _ => ImportPhase::Paused,
    }
}

pub(crate) fn snapshot(db: &Connection, id: &str) -> Result<ReadingSnapshot> {
    let mut value = book(db, id)?;
    let has_started = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM reading_books WHERE last_read>0 AND id IN (?1, COALESCE((SELECT canonical_id FROM import_jobs WHERE book_id=?1),?1)))",
        [id], |r| r.get::<_, bool>(0),
    )?;
    type JobRow = (String, u64, u64, u64, bool, Option<String>, Option<String>);
    let job: Option<JobRow> = db.query_row(
        "SELECT phase,generation,bytes_read,source_size,has_text,error,canonical_id FROM import_jobs WHERE book_id=?1", [id],
        |r| Ok((r.get(0)?, unsigned_column(r,1)?, unsigned_column(r,2)?, unsigned_column(r,3)?, r.get(4)?, r.get(5)?, r.get(6)?))
    ).optional()?;
    let Some((state, generation, read, size, visible, error, canonical)) = job else {
        return Ok(ReadingSnapshot {
            can_read: value.chunk_count > 0,
            has_started,
            book: value,
            phase: ImportPhase::Complete,
            generation: 0,
            source_bytes_read: 0,
            source_byte_count: 0,
            error: None,
        });
    };
    if let Some(canonical) = canonical {
        let existing = book(db, &canonical)?;
        value.position_utf8 = existing.position_utf8;
        value.byte_count = existing.byte_count;
        value.chunk_count = existing.chunk_count;
        value.content_sha256 = existing.content_sha256;
        value.encoding = existing.encoding;
    } else if value.content_sha256.starts_with("pending:") {
        value.content_sha256.clear();
    }
    Ok(ReadingSnapshot {
        book: value,
        phase: phase(&state),
        generation,
        can_read: visible,
        has_started,
        source_bytes_read: read,
        source_byte_count: size,
        error: error
            .map(|json| {
                serde_json::from_str(&json).map_err(|e| ReaderError::Storage {
                    message: e.to_string(),
                })
            })
            .transpose()?,
    })
}

fn content_id(db: &Connection, id: &str) -> Result<String> {
    Ok(db
        .query_row(
            "SELECT canonical_id FROM import_jobs WHERE book_id=?1",
            [id],
            |r| r.get::<_, Option<String>>(0),
        )?
        .unwrap_or_else(|| id.to_owned()))
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

    pub fn create_import(&self, title: String) -> Result<Arc<ImportControl>> {
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
            tx.execute("INSERT INTO import_jobs(book_id) VALUES(?1)", [&id])?;
            tx.commit()?;
        }
        self.resume_import(id)
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
        let mut file = File::open(file_path)?;
        let mut hash = Sha256::new();
        let mut buffer = vec![0; 1024 * 1024];
        loop {
            if control.cancelled.load(Ordering::Acquire) {
                return Err(ReaderError::Paused);
            }
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hash.update(&buffer[..n]);
        }
        Ok(sha256_hex(hash.finalize()))
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
                text::detect_encoding(&mut file)?
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
    fn runtime_state(&self, mut state: ReadingSnapshot) -> ReadingSnapshot {
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

    pub(crate) fn read_lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.reader.lock().map_err(|_| ReaderError::Storage {
            message: "读取连接不可用".into(),
        })
    }

    fn check_control(&self, db: &Connection, token: &ImportControl) -> Result<()> {
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

    fn clean_duplicate(&self, id: &str) -> Result<()> {
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

    fn stream_reader(
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
        let mut blanks = reading_layout::BlankScanner::default();
        let mut index = 0u32;
        let mut offset = 0u64;
        let mut visible = false;
        let mut published_visible = old.can_read;
        let mut batch: Vec<(TextChunk, u64, u64)> = Vec::new();
        let mut batch_bytes = 0usize;
        let mut last_commit = Instant::now();
        text::decode_chunks(&mut input, encoding, |text| {
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
                let stored = chunk(&*self.read_lock()?, &token.id, index)?;
                if stored.start_utf8 != offset || stored.text != text {
                    return Err(ReaderError::SourceChanged);
                }
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

    fn commit_prefix(
        &self,
        token: &ImportControl,
        batch: &mut Vec<(TextChunk, u64, u64)>,
        chapters: &mut Vec<IndexedChapter>,
        blanks: &mut reading_layout::BlankScanner,
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

#[cfg(test)]
mod tests {
    use super::*;
    use encoding_rs::GB18030;
    use std::sync::mpsc;
    use tempfile::TempDir;
    #[test]
    fn changed_raw_input_during_decode_cannot_finalize_or_publish_cache() {
        struct Changed {
            remaining: usize,
            first: bool,
        }
        impl Read for Changed {
            fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
                let n = out.len().min(self.remaining);
                out[..n].fill(if self.first { b'a' } else { b'b' });
                self.first = false;
                self.remaining -= n;
                Ok(n)
            }
        }
        let dir = TempDir::new().unwrap();
        let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
        let token = core.create_import("Synthetic".into()).unwrap();
        let key = crate::SourceContentKey {
            raw_sha256: sha256_hex(Sha256::digest(vec![b'a'; 512 * 1024])),
            decoding: "auto".into(),
        };
        core.validate_import_source(token.clone(), key.clone())
            .unwrap();
        let result = core.stream_reader(
            &token,
            &mut Changed {
                remaining: 512 * 1024,
                first: true,
            },
            UTF_8,
        );
        assert!(matches!(result, Err(ReaderError::SourceChanged)));
        assert!(core.finish_import(token).is_err());
        assert!(core.source_book(key).unwrap().is_none());
    }

    fn raw(path: &std::path::Path) -> String {
        sha256_hex(Sha256::digest(std::fs::read(path).unwrap()))
    }

    fn setup() -> (TempDir, Arc<ReaderCore>) {
        let dir = TempDir::new().unwrap();
        let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
        (dir, core)
    }

    fn story() -> String {
        format!(
            "第一章 月光\n{}\n第二章 归途\n{}",
            "窗外的月光落在书页上，夜色安静。👨‍👩‍👧‍👦e\u{301}\n".repeat(1600),
            "沿着小路继续走。\n".repeat(1000)
        )
    }

    #[test]
    fn import_failure_keeps_kind_and_parameters_after_reopen() {
        let (dir, core) = setup();
        let token = core.create_import("Fixture".into()).unwrap();
        let id = token.book_id();
        core.fail_import(
            token,
            ReaderError::Decode {
                message: "invalid byte at 42".into(),
            },
        )
        .unwrap();
        let stored: String = core
            .lock()
            .unwrap()
            .query_row(
                "SELECT error FROM import_jobs WHERE book_id=?1",
                [&id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&stored).unwrap(),
            serde_json::json!({"kind": "decode", "message": "invalid byte at 42"})
        );
        drop(core);
        let reopened = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
        let state = reopened.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.phase, ImportPhase::Failed);
        assert!(
            matches!(state.error, Some(ReaderError::Decode { message }) if message == "invalid byte at 42")
        );
        let retry = reopened.resume_import(id.clone()).unwrap();
        assert!(
            reopened
                .reading_snapshot(id.clone())
                .unwrap()
                .error
                .is_none()
        );
        retry.pause();
        reopened.fail_import(retry, ReaderError::Paused).unwrap();
        let paused = reopened.reading_snapshot(id).unwrap();
        assert_eq!(paused.phase, ImportPhase::Paused);
        assert!(paused.error.is_none());
    }

    struct Gate {
        input: Cursor<Vec<u8>>,
        reached: mpsc::Sender<()>,
        proceed: mpsc::Receiver<()>,
        released: bool,
    }
    impl Read for Gate {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            if !self.released && self.input.position() >= 64 * 1024 {
                self.reached.send(()).unwrap();
                self.proceed
                    .recv_timeout(Duration::from_secs(5))
                    .map_err(std::io::Error::other)?;
                self.released = true;
            }
            self.input.read(buffer)
        }
    }

    fn gated(
        core: &Arc<ReaderCore>,
        text: &str,
    ) -> (
        Arc<ImportControl>,
        mpsc::Receiver<()>,
        mpsc::Sender<()>,
        std::thread::JoinHandle<Result<()>>,
    ) {
        let control = core.create_import("月下试读".into()).unwrap();
        core.lock()
            .unwrap()
            .execute(
                "UPDATE books SET encoding='UTF-8' WHERE id=?1",
                [&control.id],
            )
            .unwrap();
        let (reached_tx, reached) = mpsc::channel();
        let (proceed, proceed_rx) = mpsc::channel();
        let mut input = Gate {
            input: Cursor::new(text.as_bytes().to_vec()),
            reached: reached_tx,
            proceed: proceed_rx,
            released: false,
        };
        let worker_core = core.clone();
        let token = control.clone();
        let worker = std::thread::spawn(move || {
            let result = worker_core.stream_reader(&token, &mut input, UTF_8);
            if let Err(ref error) = result {
                worker_core.fail_import(token, error.clone()).unwrap();
            }
            result
        });
        (control, reached, proceed, worker)
    }

    #[test]
    fn blank_window_awaiting_pause_resume_confirms_only_whole_lines() {
        for suffix in ["\n乙段。\n", "乙段。\n"] {
            let (_dir, core) = setup();
            let text = format!("甲段。\n{}{}", " ".repeat(200000), suffix);
            let (token, reached, proceed, worker) = gated(&core, &text);
            reached.recv_timeout(Duration::from_secs(5)).unwrap();
            let before = core.reading_frame(token.id.clone(), 0).unwrap();
            assert_eq!(before.status, ReadingWindowStatus::Ready);
            assert!(
                before.omitted.is_empty(),
                "Unterminated whitespace is not a blank paragraph"
            );
            let waiting = core
                .reading_frame_extension(
                    token.id.clone(),
                    before.snapshot.book.byte_count,
                    ReadingDirection::Forward,
                    None,
                )
                .unwrap();
            assert_eq!(waiting.status, ReadingWindowStatus::Awaiting);
            assert!(waiting.chunks.is_empty());
            assert!(waiting.projection_anchor.is_none());
            assert!(waiting.next_cursor.is_none());
            assert!(!waiting.is_end_of_book);
            let pending_cursor = before.snapshot.book.byte_count - 1;
            let pending_locate = core
                .reading_frame(token.id.clone(), pending_cursor)
                .unwrap();
            assert_eq!(pending_locate.status, ReadingWindowStatus::Awaiting);
            assert!(pending_locate.chunks.is_empty());
            assert!(matches!(
                core.display_text_range(token.id.clone(), 0, pending_cursor),
                Err(ReaderError::ImportBusy)
            ));
            assert!(
                before.source_end < before.snapshot.book.byte_count,
                "Pending suffix is not Ready payload"
            );
            let backwards = core
                .reading_frame_extension(
                    token.id.clone(),
                    pending_cursor,
                    ReadingDirection::Backward,
                    None,
                )
                .unwrap();
            assert_eq!(
                backwards.status,
                ReadingWindowStatus::Ready,
                "Pending tail does not block confirmed data to its left"
            );
            token.pause();
            proceed.send(()).unwrap();
            assert!(worker.join().unwrap().is_err());
            assert_eq!(
                core.reading_snapshot(token.id.clone()).unwrap().phase,
                ImportPhase::Paused
            );
            let resumed = core.resume_import(token.id.clone()).unwrap();
            core.stream_reader(&resumed, &mut Cursor::new(text.as_bytes()), UTF_8)
                .unwrap();
            core.finish_import(resumed).unwrap();
            let frame = core
                .reading_frame(token.id.clone(), before.snapshot.book.byte_count)
                .unwrap();
            assert!(frame.projection_anchor.is_some());
            if suffix.starts_with('\n') {
                assert_eq!(frame.omitted.len(), 1);
                assert_eq!(
                    frame.omitted[0].end_utf8 - frame.omitted[0].start_utf8,
                    200001
                );
                assert!(frame.chunks.iter().any(|c| c.text.contains("乙段")));
            } else {
                assert!(
                    frame.omitted.is_empty(),
                    "Spaces inside the confirmed nonblank paragraph must survive"
                );
                let restored = core.reading_frame(token.id.clone(), 10000).unwrap();
                assert_eq!(restored.status, ReadingWindowStatus::Ready);
                assert_eq!(restored.projection_anchor, Some(10000));
                assert!(restored.projection_revision > before.projection_revision);
            }
            assert_eq!(frame.snapshot.book.position_utf8, 0);
        }
    }

    #[test]
    fn strict_extension_never_reverses_at_complete_boundaries() {
        let (dir, core) = setup();
        let text = format!("甲{}", " ".repeat(100000));
        let path = dir.path().join("trailing.txt");
        std::fs::write(&path, &text).unwrap();
        let book = core
            .import_book(path.to_string_lossy().into(), "合成".into())
            .unwrap();
        let located = core
            .reading_frame(book.id.clone(), book.byte_count)
            .unwrap();
        assert!(
            located.projection_anchor.is_some(),
            "Explicit locate may fall back"
        );
        let next = located.next_cursor;
        assert!(next.is_none(), "Locate at EOF has no retained continuation");
        let end = core
            .reading_frame_extension(
                book.id.clone(),
                book.byte_count,
                ReadingDirection::Forward,
                None,
            )
            .unwrap();
        assert_eq!(end.status, ReadingWindowStatus::End);
        assert!(end.chunks.is_empty());
        assert!(end.projection_anchor.is_none());
        assert!(end.next_cursor.is_none());
        let unicode = format!("{}乙🌙", " ".repeat(100000));
        std::fs::write(&path, &unicode).unwrap();
        let book = core
            .import_book(path.to_string_lossy().into(), "合成".into())
            .unwrap();
        let head = core
            .reading_frame_extension(book.id.clone(), 0, ReadingDirection::Backward, None)
            .unwrap();
        assert_eq!(head.status, ReadingWindowStatus::Ready);
        assert_eq!(
            head.projection_anchor,
            Some(0),
            "Retained indentation is available at BOF"
        );
        assert!(head.previous_cursor.is_none());
        let located = core
            .reading_frame(book.id.clone(), book.byte_count - 2)
            .unwrap();
        assert_eq!(
            located.projection_anchor,
            Some(book.byte_count - 4),
            "Locate rounds an interior UTF8 cursor down to its scalar"
        );
    }

    #[test]
    fn late_encoding_error_preserves_published_text_and_explicit_retry_is_separate() {
        let (dir, core) = setup();
        let mut bytes = b"Chapter 1\nA long evening.\n".repeat(10000);
        let (tail, _, _) = GB18030.encode("中文小说");
        bytes.extend_from_slice(&tail);
        let file = dir.path().join("encoded.txt");
        std::fs::write(&file, bytes).unwrap();
        let token = core.create_import("编码小说".into()).unwrap();
        assert!(matches!(
            core.stream_import(
                token.clone(),
                file.to_string_lossy().into(),
                raw(&file),
                None
            ),
            Err(ReaderError::Decode { .. })
        ));
        let state = core.reading_snapshot(token.id.clone()).unwrap();
        assert!(state.can_read);
        assert_eq!(state.phase, ImportPhase::Failed);
        let old_text = core.reading_frame(token.id.clone(), 0).unwrap().chunks[0]
            .text
            .clone();
        let retry = core.create_import("编码小说".into()).unwrap();
        core.stream_import(
            retry.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            Some("gb18030".into()),
        )
        .unwrap();
        core.finish_import(retry).unwrap();
        assert_eq!(
            core.reading_frame(token.id.clone(), 0).unwrap().chunks[0].text,
            old_text
        );
        assert_eq!(
            core.reading_snapshot(token.id.clone()).unwrap().phase,
            ImportPhase::Failed
        );
    }

    #[test]
    fn source_changed_during_pause_cannot_append_to_old_prefix() {
        let (dir, core) = setup();
        let text = story();
        let (token, reached, proceed, worker) = gated(&core, &text);
        reached.recv_timeout(Duration::from_secs(5)).unwrap();
        token.pause();
        proceed.send(()).unwrap();
        assert!(worker.join().unwrap().is_err());
        let original = core.reading_frame(token.id.clone(), 0).unwrap().chunks[0]
            .text
            .clone();
        let file = dir.path().join("changed.txt");
        std::fs::write(&file, format!("Changed\n{text}")).unwrap();
        let retry = core.resume_import(token.id.clone()).unwrap();
        assert!(matches!(
            core.stream_import(retry, file.to_string_lossy().into(), raw(&file), None),
            Err(ReaderError::SourceChanged)
        ));
        assert_eq!(
            core.reading_frame(token.id.clone(), 0).unwrap().chunks[0].text,
            original
        );
    }

    #[test]
    fn encoding_probe_handles_bom_and_tiny_statistical_input() {
        assert_eq!(
            text::detect_encoding(&mut Cursor::new(&[0xff, 0xfe, 0x41, 0])).unwrap(),
            encoding_rs::UTF_16LE
        );
        assert_eq!(
            text::detect_encoding(&mut Cursor::new(&[0xef, 0xbb, 0xbf, b'A'])).unwrap(),
            UTF_8
        );
        // Statistically insufficient tiny files use the detector's pinned result;
        // users can select an encoding manually. No locale/TLD or fallback heuristic.
        assert_eq!(
            text::detect_encoding(&mut Cursor::new(&[0xd6, 0xd0])).unwrap(),
            encoding_rs::WINDOWS_1252
        );
    }

    #[test]
    fn storage_failure_preserves_prefix_even_if_error_status_cannot_be_written() {
        let (dir, core) = setup();
        let file = dir.path().join("space.txt");
        std::fs::write(&file, story()).unwrap();
        let token = core.create_import("空间不足".into()).unwrap();
        core.lock().unwrap().execute_batch("CREATE TEMP TRIGGER fail_chunks BEFORE INSERT ON chunks WHEN NEW.chunk_index > 3
            BEGIN SELECT RAISE(FAIL,'disk full'); END;
            CREATE TEMP TRIGGER fail_status BEFORE UPDATE OF phase ON import_jobs WHEN NEW.phase='failed'
            BEGIN SELECT RAISE(FAIL,'disk full'); END;").unwrap();
        assert!(
            core.stream_import(
                token.clone(),
                file.to_string_lossy().into(),
                raw(&file),
                None
            )
            .is_err()
        );
        let state = core.reading_snapshot(token.id.clone()).unwrap();
        assert!(state.can_read);
        assert_eq!(state.phase, ImportPhase::Failed);
        let prefix = core.reading_frame(token.id.clone(), 0).unwrap().chunks[0]
            .text
            .clone();
        core.lock()
            .unwrap()
            .execute_batch("DROP TRIGGER fail_chunks; DROP TRIGGER fail_status;")
            .unwrap();
        let retry = core.resume_import(token.id.clone()).unwrap();
        core.stream_import(
            retry.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        core.finish_import(retry).unwrap();
        assert_eq!(
            core.reading_frame(token.id.clone(), 0).unwrap().chunks[0].text,
            prefix
        );
    }
    #[test]
    fn readable_and_position_calculation_works_before_eof() {
        let (_dir, core) = setup();
        let text = story();
        let (token, reached, proceed, worker) = gated(&core, &text);
        reached.recv_timeout(Duration::from_secs(5)).unwrap();
        let state = core.reading_snapshot(token.id.clone()).unwrap();
        assert!(state.can_read);
        assert!(state.book.byte_count < text.len() as u64);
        assert!(state.book.content_sha256.is_empty());
        assert!(
            !core
                .reading_frame(token.id.clone(), 0)
                .unwrap()
                .is_end_of_book
        );
        assert_eq!(
            core.normalized_position(token.id.clone(), 120).unwrap(),
            118
        );
        assert_eq!(
            core.reading_snapshot(token.id.clone())
                .unwrap()
                .book
                .position_utf8,
            0,
            "Position calculation never persists user state in the text store"
        );
        assert_eq!(
            core.chapter_at(token.id.clone(), 120)
                .unwrap()
                .unwrap()
                .title,
            "第一章 月光"
        );
        proceed.send(()).unwrap();
        worker.join().unwrap().unwrap();
        let id = core.finish_import(token).unwrap();
        let state = core.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.phase, ImportPhase::Complete);
        assert_eq!(state.book.byte_count, text.len() as u64);
        assert!(core.reading_frame(id, u64::MAX).unwrap().is_end_of_book);
    }

    #[test]
    fn paused_prefix_survives_reopen_and_replay_continues_without_duplication() {
        let (dir, core) = setup();
        let text = story();
        let file = dir.path().join("story.txt");
        std::fs::write(&file, &text).unwrap();
        let (token, reached, proceed, worker) = gated(&core, &text);
        reached.recv_timeout(Duration::from_secs(5)).unwrap();
        let id = token.id.clone();
        assert_eq!(core.normalized_position(id.clone(), 120).unwrap(), 118);
        let partial = core.chapter_outline(id.clone()).unwrap();
        assert!(!partial.is_complete);
        assert!(!partial.items.last().unwrap().count_complete);
        let available = core.book_info(id.clone()).unwrap().byte_count as usize;
        let body = text.find('\n').unwrap() + 1;
        assert_eq!(
            partial.items[0].word_count,
            text[body..available]
                .chars()
                .filter(|c| !c.is_whitespace())
                .count() as u64
        );
        let prefix = core.reading_frame(id.clone(), 0).unwrap().chunks[0]
            .text
            .clone();
        token.pause();
        proceed.send(()).unwrap();
        assert!(matches!(worker.join().unwrap(), Err(ReaderError::Paused)));
        drop(core);
        let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
        assert_eq!(
            core.reading_snapshot(id.clone()).unwrap().phase,
            ImportPhase::Paused
        );
        let next = core.resume_import(id.clone()).unwrap();
        core.stream_import(
            next.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        core.finish_import(next).unwrap();
        let state = core.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.book.position_utf8, 0); // 120 is inside a UTF-8 scalar.
        let outline = core.chapter_outline(id.clone()).unwrap();
        let second = text.find("第二章").unwrap();
        let second_body = second + text[second..].find('\n').unwrap() + 1;
        assert!(outline.is_complete);
        assert_eq!(
            outline
                .items
                .iter()
                .map(|c| c.word_count)
                .collect::<Vec<_>>(),
            [
                text[body..second]
                    .chars()
                    .filter(|c| !c.is_whitespace())
                    .count() as u64,
                text[second_body..]
                    .chars()
                    .filter(|c| !c.is_whitespace())
                    .count() as u64,
            ]
        );
        assert_eq!(state.book.byte_count, text.len() as u64);
        assert_eq!(
            core.reading_frame(id.clone(), 0).unwrap().chunks[0].text,
            prefix
        );
        let full = (0..state.book.chunk_count)
            .map(|i| core.read_chunk(id.clone(), i).unwrap().text)
            .collect::<String>();
        assert_eq!(full, text);
    }

    #[test]
    fn interrupted_finalization_reopens_as_readable_paused_content() {
        let (dir, core) = setup();
        let file = dir.path().join("interrupted.txt");
        std::fs::write(&file, story()).unwrap();
        let token = core.create_import("中断后继续".into()).unwrap();
        core.stream_import(
            token.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        let id = token.id.clone();
        assert_eq!(core.normalized_position(id.clone(), 120).unwrap(), 118);
        drop(core);
        drop(token);
        let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
        let state = core.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.phase, ImportPhase::Paused);
        assert!(state.can_read);
        assert!(
            !core
                .reading_frame(id.clone(), u64::MAX)
                .unwrap()
                .is_end_of_book
        );
        let token = core.resume_import(id.clone()).unwrap();
        core.stream_import(
            token.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        core.finish_import(token).unwrap();
        assert_eq!(core.reading_snapshot(id).unwrap().book.position_utf8, 0);
    }
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn reading_snapshot(&self, book_id: String) -> Result<ReadingSnapshot> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let result = self.runtime_state(snapshot(&tx, &book_id)?);
        tx.commit()?;
        Ok(result)
    }
    pub(crate) fn recent_readings(&self) -> Result<Vec<ReadingSnapshot>> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let ids = {
            let mut stmt = tx.prepare(
                "SELECT b.id FROM reading_books b LEFT JOIN import_jobs j ON b.id=j.book_id
                WHERE j.canonical_id IS NULL
                ORDER BY b.last_read DESC,b.id",
            )?;
            stmt.query_map([], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        let readings = ids
            .iter()
            .map(|id| snapshot(&tx, id).map(|value| self.runtime_state(value)))
            .collect::<Result<_>>()?;
        tx.commit()?;
        Ok(readings)
    }
    /// Metadata, confirmed blank gaps and bounded visible payload share one WAL snapshot.
    pub(crate) fn reading_frame(&self, book_id: String, offset_utf8: u64) -> Result<ReadingFrame> {
        self.reading_frame_request(book_id, offset_utf8, ReadingDirection::Forward, true, None)
    }
    pub(crate) fn reading_frame_extension(
        &self,
        book_id: String,
        cursor: u64,
        direction: ReadingDirection,
        keep: Option<SourceSpan>,
    ) -> Result<ReadingFrame> {
        self.reading_frame_request(book_id, cursor, direction, false, keep)
    }
    fn reading_frame_request(
        &self,
        book_id: String,
        cursor: u64,
        direction: ReadingDirection,
        locate: bool,
        keep: Option<SourceSpan>,
    ) -> Result<ReadingFrame> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let state = self.runtime_state(snapshot(&tx, &book_id)?);
        let id = if state.generation > 0 {
            content_id(&tx, &book_id)?
        } else {
            book_id
        };
        let count = state.book.byte_count;
        let requested = cursor.min(count);
        let gap_at = |offset: u64| -> Result<Option<(u64, u64)>> {
            Ok(tx.query_row("SELECT start_utf8,end_utf8 FROM (SELECT start_utf8,end_utf8 FROM reading_blanks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1) WHERE end_utf8>?2", params![id, offset as i64], |r| Ok((unsigned_column(r,0)?,unsigned_column(r,1)?))).optional()?)
        };
        let confirmed: u64 =
            tx.query_row("SELECT projection_end FROM books WHERE id=?1", [&id], |r| {
                unsigned_column(r, 0)
            })?;
        // Retained whitespace is display data. Only proven blank runs may be
        // skipped; an unresolved trailing suffix is unavailable, not omitted.
        let resolve = |offset: u64, forward: bool| -> Result<Option<u64>> {
            if confirmed == 0 || (forward && offset >= confirmed) {
                return Ok(None);
            }
            let mut point = offset.min(confirmed - 1);
            if let Some((start, end)) = gap_at(point)? {
                if forward {
                    if end >= confirmed {
                        return Ok(None);
                    }
                    point = end;
                } else {
                    let Some(prior) = start.checked_sub(1) else {
                        return Ok(None);
                    };
                    point = prior;
                }
            }
            let value = chunk(&tx, &id, chunk_index(&tx, &id, point)?)?;
            let mut local = (point - value.start_utf8) as usize;
            while !value.text.is_char_boundary(local) {
                if forward {
                    local += 1;
                } else {
                    local -= 1;
                }
            }
            let resolved = value.start_utf8 + local as u64;
            Ok((resolved < confirmed).then_some(resolved))
        };
        let forward = direction == ReadingDirection::Forward;
        let normalized = if locate && requested < count {
            let value = chunk(&tx, &id, chunk_index(&tx, &id, requested)?)?;
            let mut local = (requested - value.start_utf8) as usize;
            while !value.text.is_char_boundary(local) {
                local -= 1;
            }
            value.start_utf8 + local as u64
        } else {
            requested
        };
        let target = if locate && normalized >= confirmed && state.phase != ImportPhase::Complete {
            None
        } else {
            resolve(normalized, forward)?
        };
        let mut status = if target.is_some() {
            ReadingWindowStatus::Ready
        } else if locate && normalized >= confirmed && state.phase != ImportPhase::Complete {
            ReadingWindowStatus::Awaiting
        } else if !forward {
            ReadingWindowStatus::Beginning
        } else if state.phase == ImportPhase::Complete {
            ReadingWindowStatus::End
        } else {
            ReadingWindowStatus::Awaiting
        };
        // At complete EOF locate can restore the last retained scalar, including spaces.
        let mut projection_anchor =
            if locate && target.is_none() && state.phase == ImportPhase::Complete {
                resolve(requested, !forward)?
            } else {
                target
            };
        let neighbor = |offset: u64, forward: bool| -> Result<Option<u64>> {
            if offset >= confirmed {
                return Ok(None);
            }
            if let Some((start, end)) = gap_at(offset)? {
                Ok(if forward {
                    (end < confirmed).then_some(end)
                } else {
                    start.checked_sub(1)
                })
            } else {
                Ok(Some(offset))
            }
        };
        const PAYLOAD_BYTES: u64 = 64 * 1024;
        const MAX_SOURCE_CHUNKS: usize = 256;
        let payload_cost = |index: u32| -> Result<u64> {
            let (a, raw_end): (u64, u64) = tx.query_row(
                "SELECT start_utf8,end_utf8 FROM chunks WHERE book_id=?1 AND chunk_index=?2",
                params![id, index],
                |r| Ok((unsigned_column(r, 0)?, unsigned_column(r, 1)?)),
            )?;
            if a >= confirmed {
                // A protected interval outside confirmed data cannot fit a
                // ready extension; do not underflow a clipped pending chunk.
                return Ok(PAYLOAD_BYTES + 1);
            }
            let b = raw_end.min(confirmed);
            let blank = reading_layout::blank_ranges(&tx, &id, a, b)?
                .iter()
                .map(|(start, end)| end.min(&b) - start.max(&a))
                .sum::<u64>();
            Ok(b - a - blank)
        };
        let self_keep = keep;
        let mut payload_bytes = 0;

        let mut indices = std::collections::BTreeSet::new();
        if let Some(anchor) = projection_anchor {
            let center = chunk_index(&tx, &id, anchor)?;
            if let Some(keep) =
                self_keep.filter(|r| r.start_utf8 < count && r.start_utf8 < r.end_utf8)
            {
                let left = chunk_index(&tx, &id, keep.start_utf8)?.min(center);
                let right =
                    chunk_index(&tx, &id, keep.end_utf8.min(count).saturating_sub(1))?.max(center);
                let mut index = left;
                loop {
                    let cost = payload_cost(index)?;
                    if indices.len() >= MAX_SOURCE_CHUNKS || payload_bytes + cost > PAYLOAD_BYTES {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    }
                    indices.insert(index);
                    payload_bytes += cost;
                    if index == right {
                        break;
                    }
                    let value = chunk(&tx, &id, index)?;
                    let Some(point) = neighbor(value.end_utf8, true)? else {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    };
                    let next = chunk_index(&tx, &id, point)?;
                    if next <= index || next > right {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    }
                    index = next;
                }
            } else {
                indices.insert(center);
                payload_bytes = payload_cost(center)?;
            }
            let center_chunk = chunk(&tx, &id, center)?;
            let mut before = if let Some(first) = indices.first() {
                chunk(&tx, &id, *first)?.start_utf8
            } else {
                center_chunk.start_utf8
            };
            let mut after = if let Some(last) = indices.last() {
                chunk(&tx, &id, *last)?.end_utf8
            } else {
                center_chunk.end_utf8
            };
            // Confirmed gaps cost no retained bytes. The work cap is independent
            // of payload size and comfortably exceeds a native viewport of tiny
            // LF-separated islands; it never scans an arbitrary book synchronously.
            for go_forward in
                std::iter::once(!forward).chain(std::iter::repeat_n(forward, MAX_SOURCE_CHUNKS))
            {
                if status == ReadingWindowStatus::Deferred || indices.len() >= MAX_SOURCE_CHUNKS {
                    break;
                }
                let candidate = if go_forward {
                    if after >= count {
                        None
                    } else {
                        neighbor(after, true)?
                    }
                } else {
                    before
                        .checked_sub(1)
                        .map(|p| neighbor(p, false))
                        .transpose()?
                        .flatten()
                };
                let Some(position) = candidate else {
                    if go_forward == forward {
                        break;
                    } else {
                        continue;
                    }
                };
                let index = chunk_index(&tx, &id, position)?;
                let value = chunk(&tx, &id, index)?;
                before = before.min(value.start_utf8);
                after = after.max(value.end_utf8);
                if !indices.contains(&index) {
                    let cost = payload_cost(index)?;
                    if payload_bytes + cost > PAYLOAD_BYTES {
                        if go_forward == forward {
                            break;
                        } else {
                            continue;
                        }
                    }
                    indices.insert(index);
                    payload_bytes += cost;
                }
            }
        }
        let mut chunks = Vec::new();
        let mut omitted = Vec::new();
        let mut coverage_start = count;
        let mut coverage_end = 0;
        for index in indices {
            let mut value = chunk(&tx, &id, index)?;
            value.end_utf8 = value.end_utf8.min(confirmed);
            value
                .text
                .truncate((value.end_utf8 - value.start_utf8) as usize);
            coverage_start = coverage_start.min(value.start_utf8);
            coverage_end = coverage_end.max(value.end_utf8);
            let gaps = reading_layout::blank_ranges(&tx, &id, value.start_utf8, value.end_utf8)?;
            let mut start = value.start_utf8;
            for (a, b) in gaps {
                if a > start {
                    chunks.push(TextChunk {
                        index,
                        start_utf8: start,
                        end_utf8: a,
                        text: value.text
                            [(start - value.start_utf8) as usize..(a - value.start_utf8) as usize]
                            .to_owned(),
                    });
                }
                omitted.push(SourceSpan {
                    start_utf8: a,
                    end_utf8: b,
                });
                start = b.min(value.end_utf8);
            }
            if start < value.end_utf8 {
                chunks.push(TextChunk {
                    index,
                    start_utf8: start,
                    end_utf8: value.end_utf8,
                    text: value.text[(start - value.start_utf8) as usize..].to_owned(),
                });
            }
        }
        if chunks.is_empty() {
            coverage_start = requested.min(confirmed);
            coverage_end = requested.min(confirmed);
        }
        if let Some((start, end)) = gap_at(requested.min(count.saturating_sub(1)))?
            && start <= coverage_end
            && end >= coverage_start
        {
            coverage_start = coverage_start.min(start);
            coverage_end = coverage_end.max(end);
        }
        if coverage_start < coverage_end {
            if let Some((start, _)) = gap_at(coverage_start)? {
                coverage_start = start;
            }
            if let Some((_, end)) = gap_at(coverage_end - 1)? {
                coverage_end = end;
            }
        }
        // Include entire proven gaps between loaded spans without reading their bytes.
        if coverage_start < coverage_end {
            omitted = reading_layout::blank_ranges(&tx, &id, coverage_start, coverage_end)?
                .into_iter()
                .map(|(a, b)| SourceSpan {
                    start_utf8: a,
                    end_utf8: b,
                })
                .collect();
        }
        let mut paragraphs = Vec::new();
        let mut from = 0;
        while from < chunks.len() {
            let mut to = from + 1;
            while to < chunks.len() && chunks[to - 1].end_utf8 == chunks[to].start_utf8 {
                to += 1;
            }
            paragraphs.extend(reading_layout::paragraphs(&tx, &id, &chunks[from..to])?);
            from = to;
        }
        let next_cursor = if chunks.is_empty() {
            None
        } else {
            resolve(coverage_end, true)?
        };
        let previous_cursor = if chunks.is_empty() {
            None
        } else if let Some(position) = coverage_start.checked_sub(1) {
            resolve(position, false)?
        } else {
            None
        };
        let end = state.phase == ImportPhase::Complete
            && (!chunks.is_empty() && next_cursor.is_none() || status == ReadingWindowStatus::End);
        let projection_revision: u64 = tx.query_row(
            "SELECT projection_revision FROM books WHERE id=?1",
            [&id],
            |r| unsigned_column(r, 0),
        )?;
        let has_non_whitespace_payload = chunks
            .iter()
            .any(|c| c.text.chars().any(|c| !c.is_whitespace()));
        let projection_anchor = projection_anchor.filter(|anchor| {
            chunks
                .iter()
                .any(|c| c.start_utf8 <= *anchor && *anchor < c.end_utf8)
        });
        tx.commit()?;
        Ok(ReadingFrame {
            snapshot: state,
            chunks,
            paragraphs,
            is_end_of_book: end,
            omitted,
            source_start: coverage_start,
            source_end: coverage_end,
            cursor: requested,
            projection_anchor,
            has_non_whitespace_payload,
            status,
            next_cursor,
            previous_cursor,
            projection_revision,
        })
    }
}

/// Import lifecycle metadata contains no user position or reading activity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportText {
    pub encoding: String,
    pub id: String,
    pub title: String,
    pub content_sha256: String,
    pub byte_count: u64,
    pub chunk_count: u32,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportStatus {
    pub text: ImportText,
    pub phase: ImportPhase,
}
#[uniffi::export]
impl ReaderCore {
    pub fn import_status(&self, book_id: String) -> Result<ImportStatus> {
        let state = self.reading_snapshot(book_id)?;
        Ok(ImportStatus {
            text: state.book.into(),
            phase: state.phase,
        })
    }
}

impl From<BookInfo> for ImportText {
    fn from(book: BookInfo) -> Self {
        Self {
            id: book.id,
            title: book.title,
            content_sha256: book.content_sha256,
            encoding: book.encoding,
            byte_count: book.byte_count,
            chunk_count: book.chunk_count,
        }
    }
}
