use super::content_key;
use super::search_compute::{MAX_HITS, MAX_INPUT, SearchScan};
use crate::*;
use rusqlite::Connection;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

#[derive(uniffi::Object)]
pub struct SearchJob {
    cancelled: AtomicBool,
    state: Mutex<SearchState>,
}
struct SearchState {
    db: Connection,
    book_id: String,
    scan: SearchScan,
}

// Old worker still resolves chunks and cancellation until Swift owns the task.
#[uniffi::export]
impl SearchJob {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn next_batch(&self) -> Result<SearchBatch> {
        let mut s = self.state.lock().map_err(|_| ReaderError::ImportBusy)?;
        let started = Instant::now();
        let start_offset = s.scan.offset();
        let cancelled = || self.cancelled.load(Ordering::Acquire);
        let mut hits = Vec::new();
        while hits.len() < MAX_HITS && !cancelled() {
            s.scan.collect(&mut hits, &cancelled);
            if hits.len() == MAX_HITS || cancelled() {
                break;
            }
            let Some(request) = s.scan.requested() else {
                break;
            };
            if request.start_utf8 - start_offset >= MAX_INPUT as u64
                || started.elapsed().as_millis() >= 20
            {
                break;
            }
            // Resolve and read together: the committed prefix may have moved
            // to its canonical owner since the preceding batch.
            let text = {
                let tx = s.db.unchecked_transaction()?;
                let id = content_key(&tx, &s.book_id)?;
                let c = chunk(&tx, &id, chunk_index(&tx, &id, request.start_utf8)?)?;
                let end = c.end_utf8.min(request.end_utf8);
                let bytes = c
                    .text
                    .get(
                        (request.start_utf8 - c.start_utf8) as usize..(end - c.start_utf8) as usize,
                    )
                    .ok_or(ReaderError::InvalidRange)?
                    .to_owned();
                tx.commit()?;
                TextRange {
                    start_utf8: request.start_utf8,
                    end_utf8: end,
                    text: bytes,
                }
            };
            s.scan.offer(text)?;
        }
        Ok(s.scan.batch(hits, cancelled()))
    }
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn start_search(
        &self,
        book_id: String,
        query: String,
        regular_expression: bool,
        case_sensitive: bool,
        range: Option<SearchRange>,
    ) -> Result<Arc<SearchJob>> {
        // Prefix, canonical text identity and effective headings are captured
        // together. The worker receives this resolved directory, not an empty
        // TEMP override table or a later shared projection.
        let (snapshot, book_id, headings) = {
            let mut reader = self.read_lock()?;
            let tx = reader.transaction()?;
            let snapshot = crate::reading::progressive::snapshot(&tx, &book_id)?;
            let id = content_key(&tx, &book_id)?;
            let headings = {
                let mut statement = tx.prepare("SELECT start_utf8,title,level FROM effective_chapters WHERE book_id=?1 ORDER BY start_utf8")?;
                statement
                    .query_map([&id], |r| {
                        Ok(ChapterInfo {
                            start_utf8: unsigned_column(r, 0)?,
                            title: r.get(1)?,
                            level: r.get(2)?,
                        })
                    })?
                    .collect::<std::result::Result<Vec<_>, _>>()?
            };
            tx.commit()?;
            (snapshot, id, headings)
        };
        let start = range.as_ref().map_or(0, |r| r.start_utf8);
        let end = range
            .as_ref()
            .map_or(snapshot.book.byte_count, |r| r.end_utf8);
        if start > end || end > snapshot.book.byte_count {
            return Err(ReaderError::InvalidRange);
        }
        // Boundary validation must not materialize a paragraph: a readable line
        // may exceed the text-range API's 1 MiB output budget.
        {
            let mut reader = self.read_lock()?;
            let tx = reader.transaction()?;
            let id = content_key(&tx, &book_id)?;
            for point in [start, end] {
                if point < snapshot.book.byte_count {
                    let chunk = chunk(&tx, &id, chunk_index(&tx, &id, point)?)?;
                    if !chunk
                        .text
                        .is_char_boundary((point - chunk.start_utf8) as usize)
                    {
                        return Err(ReaderError::InvalidRange);
                    }
                }
            }
        }
        let db = Connection::open(&self.database_path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        crate::user::projection::initialize(&db)?;
        db.execute_batch("PRAGMA query_only=ON; PRAGMA foreign_keys=ON")?;
        Ok(Arc::new(SearchJob {
            cancelled: AtomicBool::new(false),
            state: Mutex::new(SearchState {
                db,
                book_id,
                scan: SearchScan::new(
                    query,
                    regular_expression,
                    case_sensitive,
                    start,
                    end,
                    !snapshot.preparation.is_complete(),
                    headings,
                )?,
            }),
        }))
    }
}
