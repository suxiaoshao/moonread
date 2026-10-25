//! Reading facts, not wall-clock time between opening and closing a book.
//! The platform supplies scene visibility, actual text interaction and a monotonic clock.
use crate::*;
use rusqlite::Connection;
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::sync::Mutex;
use uuid::Uuid;

const IDLE_MS: u64 = 120_000;
const CHECKPOINT_MS: i64 = 15_000;
const DAY_MS: i64 = 86_400_000;

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingMoment {
    pub monotonic_ms: u64,
    pub unix_ms: i64,
    pub utc_offset_seconds: i32,
    pub readable: bool,
    pub interaction: bool,
    pub preview: bool,
    pub start_utf8: u64,
    pub end_utf8: u64,
}

/// A bounded observation of visible text. It is evidence, not a claim of read coverage.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ReadingExposure {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct ReadingSlice {
    pub id: String,
    pub session_id: String,
    pub visit_id: String,
    pub book_id: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    /// Gregorian day number at the place of reading; later timezone changes do not move it.
    pub local_day: i64,
    pub utc_offset_seconds: i32,
    pub preview: bool,
    pub exposures: Vec<ReadingExposure>,
}

struct ClockState {
    book_id: String,
    session_id: String,
    visit_id: String,
    previous: Option<ReadingMoment>,
    remaining: u64,
    pending: Option<ReadingSlice>,
}

#[derive(uniffi::Object)]
pub struct ReadingClock(Mutex<ClockState>);

#[uniffi::export]
impl ReadingClock {
    #[uniffi::constructor]
    pub fn new(book_id: String) -> Arc<Self> {
        Arc::new(Self(Mutex::new(ClockState {
            book_id,
            session_id: Uuid::new_v4().to_string(),
            visit_id: Uuid::new_v4().to_string(),
            previous: None,
            remaining: IDLE_MS,
            pending: None,
        })))
    }

    /// Returning to the foreground does not refresh idle credit. Only explicit interaction does.
    /// Emits immutable, retryable facts at checkpoints, pauses, midnight and kind changes.
    pub fn update(&self, moment: ReadingMoment) -> Vec<ReadingSlice> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut output = Vec::new();
        if let Some(previous) = state.previous.clone() {
            let elapsed = moment.monotonic_ms.saturating_sub(previous.monotonic_ms);
            let charged = if previous.readable {
                elapsed.min(state.remaining)
            } else {
                0
            };
            if charged > 0 {
                state.append(&previous, charged, &mut output);
                state.remaining -= charged;
            }
            let clock_changed = (moment.unix_ms.saturating_sub(previous.unix_ms)
                - i64::try_from(elapsed).unwrap_or(i64::MAX))
            .unsigned_abs()
                > 2_000;
            if !moment.readable
                || moment.preview != previous.preview
                || moment.utc_offset_seconds != previous.utc_offset_seconds
                || clock_changed
                || state.remaining == 0
            {
                state.finish(&mut output);
                state.visit_id = Uuid::new_v4().to_string();
            }
        }
        if moment.interaction {
            state.remaining = IDLE_MS;
        }
        state.previous = Some(moment);
        output
    }

    /// Called after settling the current moment, before an intentional relocation.
    pub fn break_visit(&self) -> Vec<ReadingSlice> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut output = Vec::new();
        state.finish(&mut output);
        state.visit_id = Uuid::new_v4().to_string();
        state.previous = None;
        output
    }
}

impl ClockState {
    fn finish(&mut self, output: &mut Vec<ReadingSlice>) {
        if let Some(value) = self.pending.take() {
            output.push(value);
        }
    }

    fn append(&mut self, moment: &ReadingMoment, duration: u64, output: &mut Vec<ReadingSlice>) {
        let mut at = moment.unix_ms;
        let mut left = duration as i64;
        while left > 0 {
            let offset = i64::from(moment.utc_offset_seconds) * 1000;
            let day = (at + offset).div_euclid(DAY_MS);
            let boundary = (day + 1) * DAY_MS - offset;
            let slice = self.pending.get_or_insert_with(|| ReadingSlice {
                id: Uuid::new_v4().to_string(),
                session_id: self.session_id.clone(),
                visit_id: self.visit_id.clone(),
                book_id: self.book_id.clone(),
                started_ms: at,
                ended_ms: at,
                local_day: day,
                utc_offset_seconds: moment.utc_offset_seconds,
                preview: moment.preview,
                exposures: Vec::new(),
            });
            let delta = left
                .min(boundary - at)
                .min(CHECKPOINT_MS - (slice.ended_ms - slice.started_ms));
            slice.ended_ms += delta;
            if let Some(last) = slice.exposures.last_mut()
                && last.start_utf8 == moment.start_utf8
                && last.end_utf8 == moment.end_utf8
            {
                last.duration_ms += delta as u64;
            } else {
                slice.exposures.push(ReadingExposure {
                    start_utf8: moment.start_utf8,
                    end_utf8: moment.end_utf8,
                    duration_ms: delta as u64,
                });
            }
            at += delta;
            left -= delta;
            if at == boundary || slice.ended_ms - slice.started_ms == CHECKPOINT_MS {
                self.finish(output);
            }
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct StatisticsPreferences {
    pub enabled: bool,
    pub generation: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct StatisticsBook {
    pub content_key: String,
    pub book_id: Option<String>,
    pub title: String,
    pub duration_ms: u64,
    pub first_read_ms: i64,
    pub last_read_ms: i64,
    pub last_formal_ms: i64,
    pub reading_days: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct StatisticsDay {
    pub day: i64,
    pub duration_ms: u64,
    pub book_count: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct StatisticsOverview {
    pub total_duration_ms: u64,
    pub books: Vec<StatisticsBook>,
    pub days: Vec<StatisticsDay>,
    pub preferences: StatisticsPreferences,
}

/// Display-only summary of the existing effective activity projection.
#[derive(Clone, Debug, uniffi::Record)]
pub struct StatisticsWidgetSummary {
    pub has_reading_history: bool,
    pub today_duration_ms: u64,
    pub week_duration_ms: u64,
    pub current_streak_days: u64,
    pub days: Vec<StatisticsDay>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingActivity {
    pub id: String,
    pub session_id: String,
    pub content_key: String,
    pub book_id: Option<String>,
    pub title: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    pub local_day: i64,
    pub utc_offset_seconds: i32,
    pub preview: bool,
    pub start_utf8: u64,
}

fn preferences(db: &Connection) -> Result<StatisticsPreferences> {
    Ok(db.query_row(
        "SELECT enabled,generation FROM statistics_preferences WHERE singleton=1",
        [],
        |r| {
            Ok(StatisticsPreferences {
                enabled: r.get(0)?,
                generation: unsigned_column(r, 1)?,
            })
        },
    )?)
}

fn statistics_days(
    db: &Connection,
    first_day: i64,
    last_day: i64,
    content_key: Option<String>,
) -> Result<Vec<StatisticsDay>> {
    let mut query = db.prepare("SELECT local_day,SUM(ended_ms-started_ms),COUNT(DISTINCT content_key) FROM reading_activity WHERE deleted=0 AND local_day>=?1 AND local_day<=?2 AND (?3 IS NULL OR content_key=?3) GROUP BY local_day ORDER BY local_day")?;
    let days = query
        .query_map(params![first_day, last_day, content_key], |r| {
            Ok(StatisticsDay {
                day: r.get(0)?,
                duration_ms: unsigned_column(r, 1)?,
                book_count: unsigned_column(r, 2)?,
            })
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    Ok(days)
}

impl ReaderCore {
    pub(crate) fn statistics_overview(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<String>,
    ) -> Result<StatisticsOverview> {
        let db = self.read_lock()?;
        let mut query = db.prepare("SELECT content_key,book_id,title,SUM(ended_ms-started_ms),MIN(started_ms),MAX(ended_ms),MAX(CASE WHEN preview=0 THEN ended_ms ELSE 0 END),COUNT(DISTINCT local_day) FROM reading_activity WHERE deleted=0 AND local_day>=?1 AND local_day<=?2 AND (?3 IS NULL OR content_key=?3) GROUP BY content_key ORDER BY MAX(CASE WHEN preview=0 THEN ended_ms ELSE 0 END) DESC,title,content_key")?;
        let books = query
            .query_map(params![first_day, last_day, content_key], |r| {
                Ok(StatisticsBook {
                    content_key: r.get(0)?,
                    book_id: r.get(1)?,
                    title: r.get(2)?,
                    duration_ms: unsigned_column(r, 3)?,
                    first_read_ms: r.get(4)?,
                    last_read_ms: r.get(5)?,
                    last_formal_ms: r.get(6)?,
                    reading_days: unsigned_column(r, 7)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let days = statistics_days(&db, first_day, last_day, content_key)?;
        Ok(StatisticsOverview {
            total_duration_ms: books.iter().map(|book| book.duration_ms).sum(),
            books,
            days,
            preferences: preferences(&db)?,
        })
    }
    pub(crate) fn statistics_widget_summary(
        &self,
        today: i64,
        week_start: i64,
    ) -> Result<StatisticsWidgetSummary> {
        if today < i64::MIN + 7 || week_start > today {
            return Err(ReaderError::InvalidSettings);
        }
        let db = self.read_lock()?;
        let days = statistics_days(&db, i64::MIN, today, None)?;
        let durations: std::collections::BTreeMap<_, _> =
            days.iter().map(|d| (d.day, d.duration_ms)).collect();
        let mut cursor = if durations.get(&today).copied().unwrap_or(0) > 0 {
            today
        } else {
            today - 1
        };
        let mut streak = 0;
        while durations.get(&cursor).copied().unwrap_or(0) > 0 {
            streak += 1;
            let Some(previous) = cursor.checked_sub(1) else {
                break;
            };
            cursor = previous;
        }
        Ok(StatisticsWidgetSummary {
            has_reading_history: durations.values().any(|duration| *duration > 0),
            today_duration_ms: durations.get(&today).copied().unwrap_or(0),
            week_duration_ms: days
                .iter()
                .filter(|d| d.day >= week_start)
                .map(|d| d.duration_ms)
                .sum(),
            current_streak_days: streak,
            days: (today - 6..=today)
                .map(|day| StatisticsDay {
                    day,
                    duration_ms: durations.get(&day).copied().unwrap_or(0),
                    book_count: days
                        .iter()
                        .find(|d| d.day == day)
                        .map_or(0, |d| d.book_count),
                })
                .collect(),
        })
    }
    pub(crate) fn reading_activities(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<String>,
    ) -> Result<Vec<ReadingActivity>> {
        let db = self.read_lock()?;
        let mut query = db.prepare("SELECT id,session_id,content_key,book_id,title,started_ms,ended_ms,local_day,utc_offset_seconds,preview,COALESCE(json_extract(exposures,'$[0].start_utf8'),0) FROM reading_activity WHERE deleted=0 AND local_day>=?1 AND local_day<=?2 AND (?3 IS NULL OR content_key=?3) ORDER BY started_ms,id")?;
        let rows = query
            .query_map(params![first_day, last_day, content_key], |r| {
                Ok(ReadingActivity {
                    id: r.get(0)?,
                    session_id: r.get(1)?,
                    content_key: r.get(2)?,
                    book_id: r.get(3)?,
                    title: r.get(4)?,
                    started_ms: r.get(5)?,
                    ended_ms: r.get(6)?,
                    local_day: r.get(7)?,
                    utc_offset_seconds: r.get(8)?,
                    preview: r.get(9)?,
                    start_utf8: unsigned_column(r, 10)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn moment(ms: u64, readable: bool, interaction: bool) -> ReadingMoment {
        ReadingMoment {
            monotonic_ms: ms,
            unix_ms: 1_800_000_000_000 + ms as i64,
            utc_offset_seconds: 28_800,
            readable,
            interaction,
            preview: false,
            start_utf8: 0,
            end_utf8: 300,
        }
    }
    fn duration(slices: &[ReadingSlice]) -> i64 {
        slices.iter().map(|s| s.ended_ms - s.started_ms).sum()
    }
    #[test]
    fn widget_streak_uses_today_or_yesterday_and_effective_days_without_a_seven_day_cap() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        {
            let db = core.read_lock().unwrap();
            // Populate the same effective TEMP projection used after fact/clear adjudication.
            for day in 80..=100 {
                db.execute("INSERT INTO reading_activity(id,session_id,content_key,book_id,title,started_ms,ended_ms,local_day,utc_offset_seconds,preview,exposures,deleted) VALUES(?1,'s','key',NULL,'synthetic',0,60000,?2,0,0,'[]',0)", params![format!("day-{day}"),day]).unwrap();
            }
        }
        let summary = core.statistics_widget_summary(100, 99).unwrap();
        assert_eq!(summary.current_streak_days, 21);
        assert_eq!(summary.today_duration_ms, 60_000);
        assert_eq!(summary.week_duration_ms, 120_000); // Calendar week, not seven days.
        assert_eq!(summary.days.len(), 7);
        assert_eq!(
            core.statistics_widget_summary(101, 99)
                .unwrap()
                .current_streak_days,
            21
        );
        assert_eq!(
            core.statistics_widget_summary(102, 99)
                .unwrap()
                .current_streak_days,
            0
        );
        core.read_lock()
            .unwrap()
            .execute(
                "UPDATE reading_activity SET deleted=1 WHERE local_day=99",
                [],
            )
            .unwrap();
        assert_eq!(
            core.statistics_widget_summary(100, 99)
                .unwrap()
                .current_streak_days,
            1
        );
        core.read_lock()
            .unwrap()
            .execute("UPDATE reading_activity SET deleted=1", [])
            .unwrap();
        let empty = core.statistics_widget_summary(100, 99).unwrap();
        assert_eq!(empty.current_streak_days, 0);
        assert_eq!(empty.today_duration_ms, 0);
        assert!(empty.days.iter().all(|d| d.duration_ms == 0));
    }
    #[test]
    fn idle_is_capped_and_interaction_never_backfills() {
        let clock = ReadingClock::new("book".into());
        assert!(clock.update(moment(0, true, true)).is_empty());
        assert_eq!(duration(&clock.update(moment(90_000, true, false))), 90_000);
        assert_eq!(
            duration(&clock.update(moment(600_000, true, false))),
            30_000
        );
        assert!(clock.update(moment(700_000, true, true)).is_empty());
        assert_eq!(
            duration(&clock.update(moment(720_000, false, false))),
            20_000
        );
    }
    #[test]
    fn pauses_preserve_remaining_credit_and_kind_changes_split() {
        let clock = ReadingClock::new("book".into());
        clock.update(moment(0, true, true));
        assert_eq!(
            duration(&clock.update(moment(40_000, false, false))),
            40_000
        );
        assert!(clock.update(moment(900_000, true, false)).is_empty());
        let mut preview = moment(930_000, true, false);
        preview.preview = true;
        let formal = clock.update(preview.clone());
        assert_eq!(duration(&formal), 30_000);
        assert!(formal.iter().all(|s| !s.preview));
        preview.monotonic_ms = 1_030_000;
        preview.unix_ms += 100_000;
        let slices = clock.update(preview);
        assert_eq!(duration(&slices), 50_000);
        assert!(slices.iter().all(|s| s.preview));
    }
    #[test]
    fn midnight_and_clock_changes_do_not_change_elapsed_time() {
        let clock = ReadingClock::new("book".into());
        let mut start = moment(0, true, true);
        start.unix_ms = DAY_MS - 28_800_000 - 5_000;
        clock.update(start.clone());
        let mut end = start.clone();
        end.monotonic_ms = 10_000;
        end.unix_ms += 10_000;
        end.readable = false;
        let slices = clock.update(end);
        assert_eq!(duration(&slices), 10_000);
        assert_eq!(slices.len(), 2);
        assert_eq!(slices[0].local_day + 1, slices[1].local_day);
        let clock = ReadingClock::new("book".into());
        clock.update(start);
        let mut changed = moment(5_000, false, false);
        changed.unix_ms += 3_600_000;
        assert_eq!(duration(&clock.update(changed)), 5_000);
    }
}

// Business projections are exported only by ReaderQuery.
