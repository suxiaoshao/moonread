use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) fn reading_percentage(offset: u64, total: u64) -> f64 {
    offset.min(total) as f64 / total.max(1) as f64 * 100.0
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingVisit {
    pub id: String,
    pub offset_utf8: u64,
    pub title: String,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingHistory {
    pub entries: Vec<ReadingVisit>,
    pub cursor: u32,
}

#[uniffi::export]
pub fn empty_reading_history() -> ReadingHistory {
    ReadingHistory {
        entries: Vec::new(),
        cursor: 0,
    }
}

#[uniffi::export]
pub fn update_history_position(
    mut history: ReadingHistory,
    offset_utf8: u64,
    title: String,
) -> ReadingHistory {
    if let Some(entry) = history.entries.get_mut(history.cursor as usize) {
        entry.offset_utf8 = offset_utf8;
        entry.title = title;
    }
    history
}

#[uniffi::export]
pub fn visit_reading_position(
    mut history: ReadingHistory,
    from_utf8: u64,
    from_title: String,
    to_utf8: u64,
    to_title: String,
) -> ReadingHistory {
    if history.entries.is_empty() {
        history.entries.push(ReadingVisit {
            id: Uuid::new_v4().to_string(),
            offset_utf8: from_utf8,
            title: from_title.clone(),
        });
        history.cursor = 0;
    }
    history = update_history_position(history, from_utf8, from_title);
    history.entries.truncate(history.cursor as usize + 1);
    if from_utf8 != to_utf8 {
        history.entries.push(ReadingVisit {
            id: Uuid::new_v4().to_string(),
            offset_utf8: to_utf8,
            title: to_title,
        });
        if history.entries.len() > 32 {
            history.entries.remove(0);
        }
        history.cursor = (history.entries.len() - 1) as u32;
    }
    history
}

#[uniffi::export]
pub fn select_reading_history(mut history: ReadingHistory, id: String) -> Result<ReadingHistory> {
    let index = history
        .entries
        .iter()
        .position(|e| e.id == id)
        .ok_or(ReaderError::InvalidRange)?;
    history.cursor = index as u32;
    Ok(history)
}

#[derive(uniffi::Record)]
pub struct ReadingLocation {
    pub offset_utf8: u64,
    pub percentage: f64,
    pub chapter: Option<ChapterInfo>,
}

fn require_complete(db: &Connection, id: &str) -> Result<BookInfo> {
    let active: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND phase!='complete')",
        [id],
        |r| r.get(0),
    )?;
    if active {
        return Err(ReaderError::ImportBusy);
    }
    book(db, id)
}

#[uniffi::export]
impl ReaderCore {
    /// Manual corrections live separately from the detected index and survive a rescan.
    pub fn rebuild_chapters(&self, book_id: String) -> Result<Arc<ChapterRebuild>> {
        let db = Connection::open(&self.database_path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA temp_store=FILE;")?;
        user_projection::initialize(&db)?;
        let id = library_tools::content_key(&db, &book_id)?;
        let book = require_complete(&db, &id)?;
        db.execute_batch("CREATE TEMP TABLE detected_chapters(start_utf8 INTEGER PRIMARY KEY,title TEXT NOT NULL,level INTEGER NOT NULL,start_char_count INTEGER NOT NULL,body_char_count INTEGER NOT NULL);")?;
        Ok(Arc::new(ChapterRebuild {
            cancelled: AtomicBool::new(false),
            state: Mutex::new(RebuildState {
                db,
                book,
                index: 0,
                scanner: ChapterScanner::default(),
                done: false,
                applied: false,
                count: 0,
            }),
        }))
    }
}

fn chapter_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ChapterInfo> {
    Ok(ChapterInfo {
        start_utf8: unsigned_column(r, 0)?,
        title: r.get(1)?,
        level: r.get(2)?,
    })
}

/// Derive a manual heading's prefix counts from one indexed chunk and its
/// bounded source line. Shared by local editing and cloud materialization.
pub(super) fn chapter_counts(db: &Connection, id: &str, offset: u64) -> Result<(u64, u64)> {
    let info = book(db, id)?;
    if offset >= info.byte_count {
        return Err(ReaderError::InvalidRange);
    }
    let text = chunk(db, id, chunk_index(db, id, offset)?)?;
    let relative = (offset - text.start_utf8) as usize;
    if !text.text.is_char_boundary(relative) {
        return Err(ReaderError::InvalidRange);
    }
    let line_start = if relative == 0 {
        text.index == 0 || chunk(db, id, text.index - 1)?.text.ends_with('\n')
    } else {
        text.text[..relative].ends_with('\n')
    };
    if !line_start {
        return Err(ReaderError::InvalidRange);
    }
    let tail = &text.text[relative..];
    let mut line = tail.split('\n').next().unwrap_or("").to_string();
    if !tail.contains('\n') && text.index + 1 < info.chunk_count {
        let next = chunk(db, id, text.index + 1)?;
        line.push_str(next.text.split('\n').next().unwrap_or(""));
        if !next.text.contains('\n') && text.index + 2 < info.chunk_count {
            return Err(ReaderError::InvalidRange);
        }
    }
    if line.len() > MAX_CHAPTER_LINE_BYTES
        || line.trim().is_empty()
        || line.trim().chars().count() > 80
    {
        return Err(ReaderError::InvalidRange);
    }
    let prefix = db.query_row(
        "SELECT start_char_count FROM chunks WHERE book_id=?1 AND chunk_index=?2",
        params![id, text.index],
        |r| unsigned_column(r, 0),
    )?;
    let start = prefix
        + text.text[..relative]
            .chars()
            .filter(|c| !c.is_whitespace())
            .count() as u64;
    Ok((
        start,
        start + line.chars().filter(|c| !c.is_whitespace()).count() as u64,
    ))
}

#[derive(uniffi::Record)]
pub struct ChapterRebuildProgress {
    pub fraction: f64,
    pub count: u64,
    pub done: bool,
    pub cancelled: bool,
}

struct RebuildState {
    db: Connection,
    book: BookInfo,
    index: u32,
    scanner: ChapterScanner,
    done: bool,
    applied: bool,
    count: u64,
}

#[derive(uniffi::Object)]
pub struct ChapterRebuild {
    state: Mutex<RebuildState>,
    cancelled: AtomicBool,
}

#[uniffi::export]
impl ChapterRebuild {
    /// A bounded unit of background work, with no long-lived reader transaction.
    pub fn next_batch(&self) -> Result<ChapterRebuildProgress> {
        let mut state = self.state.lock().map_err(|_| ReaderError::ImportBusy)?;
        for _ in 0..16 {
            if state.done || self.cancelled.load(Ordering::Acquire) {
                break;
            }
            if state.index < state.book.chunk_count {
                let c = chunk(&state.db, &state.book.id, state.index)?;
                state.scanner.push_chunk(c.start_utf8, &c.text);
                state.index += 1;
            }
            let headings = if state.index == state.book.chunk_count {
                state.done = true;
                std::mem::take(&mut state.scanner).finish()
            } else {
                std::mem::take(&mut state.scanner.chapters)
            };
            let tx = state.db.transaction()?;
            for h in &headings {
                tx.execute(
                    "INSERT INTO detected_chapters VALUES(?1,?2,?3,?4,?5)",
                    params![
                        h.start_utf8 as i64,
                        h.title,
                        h.level,
                        h.start_char_count as i64,
                        h.body_char_count as i64
                    ],
                )?;
            }
            tx.commit()?;
            state.count += headings.len() as u64;
        }
        Ok(ChapterRebuildProgress {
            fraction: state.index as f64 / state.book.chunk_count.max(1) as f64,
            count: state.count,
            done: state.done,
            cancelled: self.cancelled.load(Ordering::Acquire),
        })
    }

    pub fn preview(&self, from_utf8: u64, limit: u32) -> Result<Vec<ChapterInfo>> {
        let state = self.state.lock().map_err(|_| ReaderError::ImportBusy)?;
        let mut stmt = state.db.prepare("SELECT start_utf8,title,level FROM detected_chapters WHERE start_utf8>=?1 ORDER BY start_utf8 LIMIT ?2")?;
        Ok(stmt
            .query_map(
                params![from_utf8.min(i64::MAX as u64) as i64, limit.clamp(1, 80)],
                chapter_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?)
    }

    pub fn apply(&self) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| ReaderError::ImportBusy)?;
        if !state.done || self.cancelled.load(Ordering::Acquire) {
            return Err(ReaderError::Paused);
        }
        if state.applied {
            return Ok(());
        }
        let original = state.book.clone();
        let tx = state.db.transaction()?;
        let current = require_complete(&tx, &original.id)?;
        if current.content_sha256 != original.content_sha256
            || current.byte_count != original.byte_count
        {
            return Err(ReaderError::SourceChanged);
        }
        tx.execute(
            "DELETE FROM import_chapters WHERE book_id=?1",
            [&original.id],
        )?;
        tx.execute(
            "INSERT INTO import_chapters SELECT ?1,start_utf8,title,level,start_char_count,body_char_count FROM detected_chapters",
            [&original.id],
        )?;
        tx.commit()?;
        state.applied = true;
        Ok(())
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn reading_location(
        &self,
        book_id: String,
        percentage: f64,
    ) -> Result<ReadingLocation> {
        if !percentage.is_finite() || !(0.0..=100.0).contains(&percentage) {
            return Err(ReaderError::InvalidRange);
        }
        let db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let id = library_tools::content_key(&db, &book_id)?;
        let info = require_complete(&db, &id)?;
        let mut offset =
            ((info.byte_count as f64 * percentage / 100.0).round() as u64).min(info.byte_count);
        let text = chunk(&db, &id, chunk_index(&db, &id, offset)?)?;
        while !text
            .text
            .is_char_boundary((offset - text.start_utf8) as usize)
        {
            offset -= 1;
        }
        Ok(ReadingLocation {
            offset_utf8: offset,
            percentage: reading_percentage(offset, info.byte_count),
            chapter: library_tools::chapter(&db, &id, offset)?,
        })
    }
    pub(crate) fn adjacent_chapter(
        &self,
        book_id: String,
        offset_utf8: u64,
        forward: bool,
    ) -> Result<Option<ChapterInfo>> {
        let db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let id = library_tools::content_key(&db, &book_id)?;
        let current = library_tools::chapter(&db, &id, offset_utf8)?
            .map(|c| c.start_utf8)
            .unwrap_or(0);
        let sql = if forward {
            "SELECT start_utf8,title,level FROM effective_chapters WHERE book_id=?1 AND start_utf8>?2 ORDER BY start_utf8 LIMIT 1"
        } else {
            "SELECT start_utf8,title,level FROM effective_chapters WHERE book_id=?1 AND start_utf8<?2 ORDER BY start_utf8 DESC LIMIT 1"
        };
        Ok(db
            .query_row(sql, params![id, current as i64], chapter_row)
            .optional()?)
    }
}
