use crate::*;
use regex::{Regex, RegexBuilder};
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TextRange {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub text: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MarkKind {
    Bookmark,
    Annotation,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReaderMark {
    pub id: String,
    pub kind: MarkKind,
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub excerpt: String,
    pub note: String,
    pub created: u64,
}
#[derive(uniffi::Record)]
pub struct MarkPage {
    pub items: Vec<ReaderMark>,
    pub has_more: bool,
}
#[derive(uniffi::Record)]
pub struct ChapterOutline {
    pub items: Vec<ChapterEntry>,
    pub is_complete: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChapterEntry {
    pub start_utf8: u64,
    pub title: String,
    pub word_count: u64,
    pub count_complete: bool,
    pub level: u32,
    pub parent_utf8: Option<u64>,
    pub parent_title: Option<String>,
    pub covered_characters: Option<u64>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchRange {
    pub start_utf8: u64,
    pub end_utf8: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchHit {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub excerpt: String,
    pub highlight_start: u32,
    pub highlight_end: u32,
    pub chapter: Option<String>,
}
#[derive(uniffi::Record)]
pub struct SearchBatch {
    pub hits: Vec<SearchHit>,
    pub done: bool,
    pub cancelled: bool,
    /// Coverage warning: a long regex line was skipped. This is independent of
    /// `done`; callers must keep requesting batches until completion/cancellation.
    pub truncated: bool,
    pub partial_book: bool,
    pub scanned_utf8: u64,
    pub available_utf8: u64,
}

pub(crate) fn content_key(db: &Connection, id: &str) -> Result<String> {
    db.query_row("SELECT COALESCE(j.canonical_id,b.id) FROM reading_books b LEFT JOIN import_jobs j ON j.book_id=b.id WHERE b.id=?1", [id], |r| r.get(0))
        .optional()?.ok_or(ReaderError::NotFound)
}
pub(crate) fn chapter(db: &Connection, id: &str, offset: u64) -> Result<Option<ChapterInfo>> {
    Ok(db.query_row("SELECT start_utf8,title,level FROM effective_chapters WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1",
        params![id, offset.min(i64::MAX as u64) as i64], |r| Ok(ChapterInfo { start_utf8: unsigned_column(r,0)?, title:r.get(1)?, level:r.get(2)? })).optional()?)
}
fn range_text(db: &Connection, id: &str, start: u64, end: u64) -> Result<String> {
    if start > end || end - start > 1024 * 1024 || end > book(db, id)?.byte_count {
        return Err(ReaderError::InvalidRange);
    }
    let mut stmt = db.prepare("SELECT start_utf8,text FROM chunks WHERE book_id=?1 AND end_utf8>?2 AND start_utf8<?3 ORDER BY chunk_index")?;
    let mut text = String::new();
    for row in stmt.query_map(params![id, start as i64, end as i64], |r| {
        Ok((unsigned_column(r, 0)?, r.get::<_, String>(1)?))
    })? {
        let (base, chunk) = row?;
        let from = start.saturating_sub(base) as usize;
        let to = ((end - base) as usize).min(chunk.len());
        text.push_str(chunk.get(from..to).ok_or(ReaderError::InvalidRange)?);
    }
    if text.len() as u64 != end - start {
        return Err(ReaderError::InvalidRange);
    }
    Ok(text)
}

#[uniffi::export]
impl ReaderCore {
    /// The reader's display projection for an original selection envelope.
    /// Retained paragraph separators (LF) stay intact; only confirmed semantic
    /// blank runs are omitted. Read retained spans, never concatenate a UI window.
    pub fn display_text_range(
        &self,
        book_id: String,
        start_utf8: u64,
        end_utf8: u64,
    ) -> Result<TextRange> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let size = book(&tx, &id)?.byte_count;
        if start_utf8 > end_utf8 || end_utf8 > size {
            return Err(ReaderError::InvalidRange);
        }
        let confirmed: u64 =
            tx.query_row("SELECT projection_end FROM books WHERE id=?1", [&id], |r| {
                unsigned_column(r, 0)
            })?;
        if end_utf8 > confirmed {
            // A native selection cannot include the unresolved suffix. Other
            // callers must wait for the same semantic snapshot as the viewport.
            return Err(ReaderError::ImportBusy);
        }
        for offset in [start_utf8, end_utf8] {
            if offset < size {
                let value = chunk(&tx, &id, chunk_index(&tx, &id, offset)?)?;
                if !value
                    .text
                    .is_char_boundary((offset - value.start_utf8) as usize)
                {
                    return Err(ReaderError::InvalidRange);
                }
            }
        }
        let blanks = crate::reading::layout::blank_ranges(&tx, &id, start_utf8, end_utf8)?;
        let mut cursor = start_utf8;
        let mut text = String::new();
        for (lo, hi) in blanks
            .into_iter()
            .chain(std::iter::once((end_utf8, end_utf8)))
        {
            let end = lo.max(cursor).min(end_utf8);
            if end - cursor > 1024 * 1024 - text.len() as u64 {
                return Err(ReaderError::InvalidRange);
            }
            if cursor < end {
                text.push_str(&range_text(&tx, &id, cursor, end)?);
            }
            cursor = hi.max(cursor).min(end_utf8);
        }
        Ok(TextRange {
            start_utf8,
            end_utf8,
            text,
        })
    }

    pub fn text_range(&self, book_id: String, start_utf8: u64, end_utf8: u64) -> Result<TextRange> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        Ok(TextRange {
            start_utf8,
            end_utf8,
            text: range_text(&tx, &id, start_utf8, end_utf8)?,
        })
    }

    /// Read the containing paragraph plus neighboring non-empty paragraphs.
    /// All offsets refer to normalized UTF-8, and traversal stays bounded.
    pub fn text_context(
        &self,
        book_id: String,
        offset_utf8: u64,
        before_paragraphs: u32,
        after_paragraphs: u32,
    ) -> Result<TextRange> {
        if before_paragraphs > 20 || after_paragraphs > 20 {
            return Err(ReaderError::InvalidRange);
        }
        let size = {
            let db = self.read_lock()?;
            book(&db, &content_key(&db, &book_id)?)?.byte_count
        };
        if offset_utf8 >= size {
            return Err(ReaderError::InvalidRange);
        }
        let anchor = self.paragraph_range(book_id.clone(), offset_utf8)?;
        let mut start = anchor.start_utf8;
        let mut end = anchor.end_utf8;
        for (forward, count) in [(false, before_paragraphs), (true, after_paragraphs)] {
            let mut remaining = count;
            while remaining > 0 {
                let point = if forward {
                    if end + 1 >= size {
                        break;
                    }
                    end + 1
                } else {
                    if start == 0 {
                        break;
                    }
                    start - 1 // the preceding newline is always one ASCII byte
                };
                let paragraph = self.paragraph_range(book_id.clone(), point)?;
                if forward {
                    end = paragraph.end_utf8;
                } else {
                    start = paragraph.start_utf8;
                }
                if end - start > 1024 * 1024 {
                    return Err(ReaderError::InvalidRange);
                }
                if !paragraph.text.trim().is_empty() {
                    remaining -= 1;
                }
            }
        }
        self.text_range(book_id, start, end)
    }

    pub fn paragraph_range(&self, book_id: String, offset_utf8: u64) -> Result<TextRange> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let size = book(&tx, &id)?.byte_count;
        if size == 0 {
            return Err(ReaderError::EmptyBook);
        }
        let point = offset_utf8.min(size - 1);
        let index = chunk_index(&tx, &id, point)?;
        let current = chunk(&tx, &id, index)?;
        let local = (point - current.start_utf8) as usize;
        if !current.text.is_char_boundary(local) {
            return Err(ReaderError::InvalidRange);
        }
        let mut start = current.start_utf8;
        let mut end = current.end_utf8;
        let mut text = current.text;
        let mut before = index;
        let mut after = index + 1;
        while !text[..(point - start) as usize].contains('\n') && before > 0 {
            before -= 1;
            let c = chunk(&tx, &id, before)?;
            start = c.start_utf8;
            text = c.text + &text;
            if text.len() > 1024 * 1024 {
                return Err(ReaderError::InvalidRange);
            }
        }
        while !text[(point - start) as usize..].contains('\n') && end < size {
            let c = chunk(&tx, &id, after)?;
            after += 1;
            end = c.end_utf8;
            text.push_str(&c.text);
            if text.len() > 1024 * 1024 {
                return Err(ReaderError::InvalidRange);
            }
        }
        let relative = (point - start) as usize;
        let left = text[..relative].rfind('\n').map_or(0, |p| p + 1);
        let right = text[relative..]
            .find('\n')
            .map_or(text.len(), |p| relative + p);
        Ok(TextRange {
            start_utf8: start + left as u64,
            end_utf8: start + right as u64,
            text: text[left..right].into(),
        })
    }
}

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
    /// A complete, lightweight snapshot of every published heading. Counts use
    /// prefix totals built with the text cache; this query never loads prose.
    pub(crate) fn chapter_outline(&self, book_id: String) -> Result<ChapterOutline> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let complete: bool = tx.query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND phase!='complete')",
            [&id],
            |r| r.get(0),
        )?;
        let total: u64 = tx.query_row(
            "SELECT COALESCE((SELECT end_char_count FROM chunks WHERE book_id=?1 ORDER BY chunk_index DESC LIMIT 1),0)",
            [&id], |r| unsigned_column(r, 0),
        )?;
        let mut statement = tx.prepare(
            "SELECT start_utf8,title,level,start_char_count,body_char_count FROM effective_chapters WHERE book_id=?1 ORDER BY start_utf8"
        )?;
        let headings = statement
            .query_map([&id], |r| {
                Ok(IndexedChapter {
                    start_utf8: unsigned_column(r, 0)?,
                    title: r.get(1)?,
                    level: r.get(2)?,
                    start_char_count: unsigned_column(r, 3)?,
                    body_char_count: unsigned_column(r, 4)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let coverage = crate::user::coverage::covered_char_ranges(&tx, &id)?;
        let mut parent: Option<&IndexedChapter> = None;
        let mut items = Vec::with_capacity(headings.len());
        for (index, heading) in headings.iter().enumerate() {
            let next = headings.get(index + 1);
            let end = next.map_or(total, |next| next.start_char_count);
            let word_count = end
                .checked_sub(heading.body_char_count)
                .ok_or(ReaderError::InvalidRange)?;
            if heading.level == 0 {
                parent = None;
            }
            items.push(ChapterEntry {
                start_utf8: heading.start_utf8,
                title: heading.title.clone(),
                level: heading.level,
                word_count,
                count_complete: next.is_some() || complete,
                parent_utf8: parent.map(|parent| parent.start_utf8),
                parent_title: parent.map(|parent| parent.title.clone()),
                covered_characters: coverage
                    .as_ref()
                    .filter(|_| next.is_some() || complete)
                    .map(|ranges| {
                        crate::user::coverage::count(ranges, heading.body_char_count, end)
                    }),
            });
            if heading.level == 0 {
                parent = Some(heading);
            }
        }
        Ok(ChapterOutline {
            items,
            is_complete: complete,
        })
    }
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
                partial: snapshot.phase != ImportPhase::Complete,
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
