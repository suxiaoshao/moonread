use super::content_key;
use crate::*;
use regex::{Regex, RegexBuilder};
use rusqlite::{Connection, params};
use std::collections::VecDeque;
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
    matcher: Regex,
    headings: Vec<ChapterInfo>,
    limit: u64,
    partial: bool,
    offset: u64,
    line_start: u64,
    line: String,
    hits: VecDeque<SearchHit>,
    done: bool,
    literal_overlap: Option<usize>,
    skipped_long_line: bool,
    skipping_line: bool,
    emitted_until: u64,
}
impl SearchState {
    fn scan_line(&mut self, cancelled: &AtomicBool) -> Result<()> {
        self.scan_matches(cancelled, self.line.len())?;
        self.line.clear();
        Ok(())
    }
    fn scan_matches(&mut self, cancelled: &AtomicBool, before: usize) -> Result<()> {
        for found in self.matcher.find_iter(&self.line) {
            if cancelled.load(Ordering::Relaxed) {
                break;
            }
            if found.start() >= before {
                break;
            }
            let start = self.line_start + found.start() as u64;
            if found.is_empty() || start < self.emitted_until {
                continue;
            }
            self.emitted_until = self.line_start + found.end() as u64;
            let mut left = found.start().saturating_sub(100);
            while !self.line.is_char_boundary(left) {
                left += 1;
            }
            let mut right = (found.end() + 160).min(self.line.len());
            while !self.line.is_char_boundary(right) {
                right -= 1;
            }
            let before = &self.line[left..found.start()];
            let matched: String = self.line[found.start()..found.end()]
                .chars()
                .take(160)
                .collect();
            let after = &self.line[found.end()..right];
            let highlight_start = before.len() as u32;
            let highlight_end = highlight_start + matched.len() as u32;
            self.hits.push_back(SearchHit {
                start_utf8: start,
                end_utf8: self.line_start + found.end() as u64,
                excerpt: format!("{before}{matched}{after}"),
                highlight_start,
                highlight_end,
                chapter: self
                    .headings
                    .partition_point(|c| c.start_utf8 <= start)
                    .checked_sub(1)
                    .map(|index| self.headings[index].title.clone()),
            });
        }
        Ok(())
    }
}
#[uniffi::export]
impl SearchJob {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn next_batch(&self) -> Result<SearchBatch> {
        let mut s = self.state.lock().map_err(|_| ReaderError::ImportBusy)?;
        let started = Instant::now();
        let start_offset = s.offset;
        while !s.done
            && s.hits.len() < 50
            && !self.cancelled.load(Ordering::Acquire)
            && s.offset - start_offset < 256 * 1024
            && started.elapsed().as_millis() < 20
        {
            if s.offset >= s.limit {
                s.scan_line(&self.cancelled)?;
                s.done = true;
                break;
            }
            // Resolve and read together: duplicate cleanup can switch the text
            // owner between batches without invalidating the frozen prefix.
            let bytes = {
                let tx = s.db.unchecked_transaction()?;
                let id = content_key(&tx, &s.book_id)?;
                let c = chunk(&tx, &id, chunk_index(&tx, &id, s.offset)?)?;
                let text = c
                    .text
                    .get(
                        (s.offset - c.start_utf8) as usize
                            ..((s.limit.min(c.end_utf8) - c.start_utf8) as usize),
                    )
                    .ok_or(ReaderError::InvalidRange)?
                    .to_owned();
                tx.commit()?;
                text
            };
            if bytes.is_empty() {
                return Err(ReaderError::InvalidRange);
            }
            for piece in bytes.split_inclusive('\n') {
                s.offset += piece.len() as u64;
                if s.skipping_line {
                    if piece.ends_with('\n') {
                        s.skipping_line = false;
                    }
                    s.line_start = s.offset;
                    continue;
                }
                s.line.push_str(piece);
                if s.line.len() > 1024 * 1024 {
                    if let Some(overlap) = s.literal_overlap {
                        let mut cut = s.line.len().saturating_sub(overlap);
                        while !s.line.is_char_boundary(cut) {
                            cut -= 1;
                        }
                        s.scan_matches(&self.cancelled, cut)?;
                        s.line.drain(..cut);
                        s.line_start += cut as u64;
                    } else {
                        // Arbitrary regex can depend on the whole line ($, lookaround,
                        // unbounded repetition). Do not invent segmented matches.
                        // Skip only this line, report incomplete coverage and continue.
                        s.skipped_long_line = true;
                        s.skipping_line = !piece.ends_with('\n');
                        s.line.clear();
                        s.line_start = s.offset;
                        continue;
                    }
                }
                if piece.ends_with('\n') {
                    s.line.pop();
                    s.scan_line(&self.cancelled)?;
                    s.line_start = s.offset;
                    if s.done || self.cancelled.load(Ordering::Acquire) {
                        break;
                    }
                }
            }
        }
        let hits = (0..50).filter_map(|_| s.hits.pop_front()).collect();
        Ok(SearchBatch {
            hits,
            done: s.done && s.hits.is_empty(),
            cancelled: self.cancelled.load(Ordering::Acquire),
            truncated: s.skipped_long_line,
            partial_book: s.partial,
            scanned_utf8: s.offset,
            available_utf8: s.limit,
        })
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
        if query.is_empty() || query.contains('\n') {
            return Err(ReaderError::SearchPattern {
                message: "Enter a nonempty single-line query.".into(),
            });
        }
        // Unicode simple case folding can expand each input scalar to four UTF-8
        // bytes. Retain enough for a literal crossing the segment and its excerpt.
        let literal_overlap =
            (!regular_expression).then(|| query.len().saturating_mul(4).saturating_add(164));
        let source = if regular_expression {
            query
        } else {
            regex::escape(&query)
        };
        let matcher = RegexBuilder::new(&source)
            .case_insensitive(!case_sensitive)
            .build()
            .map_err(|e| ReaderError::SearchPattern {
                message: e.to_string(),
            })?;
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
                matcher,
                headings,
                limit: end,
                partial: !snapshot.preparation.is_complete(),
                offset: start,
                line_start: start,
                line: String::new(),
                hits: VecDeque::new(),
                done: false,
                literal_overlap,
                skipped_long_line: false,
                skipping_line: false,
                emitted_until: start,
            }),
        }))
    }
}
