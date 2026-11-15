//! Reading facts, not wall-clock time between opening and closing a book.
//! The platform supplies scene visibility, actual text interaction and a monotonic clock.
mod coverage;
pub use coverage::{CoverageFact, visible_dwell_ranges};

use crate::reading::compute::StepState;
use crate::*;
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
    /// Platform evidence: cumulative time that frames actually advanced text.
    /// Runtime only; never persisted or interpreted as manual interaction.
    pub automatic_moving: bool,
    pub automatic_milliseconds: u64,
    pub preview: bool,
    pub start_utf8: u64,
    pub end_utf8: u64,
}

/// A bounded observation of visible text. It is evidence, not a claim of read coverage.
#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct ReadingExposure {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub duration_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
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
    #[serde(deserialize_with = "super::reading_fact::deserialize_exposures")]
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
        Arc::new(Self(Mutex::new(ClockState::new(
            book_id,
            Uuid::new_v4().to_string(),
            Uuid::new_v4().to_string(),
        ))))
    }

    pub fn update(&self, moment: ReadingMoment) -> Vec<ReadingSlice> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        state.advance(
            moment,
            || Uuid::new_v4().to_string(),
            || Uuid::new_v4().to_string(),
        )
    }

    pub fn break_visit(&self) -> Vec<ReadingSlice> {
        let mut state = self.0.lock().unwrap_or_else(|e| e.into_inner());
        state.relocate(Uuid::new_v4().to_string())
    }
}

#[derive(uniffi::Object)]
pub struct ReadingClockState(StepState<ClockState>);

#[derive(uniffi::Record)]
pub struct ReadingClockStep {
    pub next: Arc<ReadingClockState>,
    pub slices: Vec<ReadingSlice>,
}

#[uniffi::export]
pub fn begin_reading_clock(
    book_id: String,
    session_id: String,
    visit_id: String,
) -> Result<Arc<ReadingClockState>> {
    if book_id.is_empty() || session_id.is_empty() || visit_id.is_empty() {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(Arc::new(ReadingClockState(StepState::new(
        ClockState::new(book_id, session_id, visit_id),
    ))))
}

/// The host gives each step its own UUID seed; with more than one new slice
/// the later IDs are deterministic suffixes of that seed. Pending slices keep
/// the IDs assigned when they were opened, even if emitted on another step.
#[uniffi::export]
pub fn advance_reading_clock(
    previous: Arc<ReadingClockState>,
    moment: ReadingMoment,
    fact_seed: String,
    next_visit_id: String,
) -> Result<ReadingClockStep> {
    let mut state = previous.0.take()?;
    let seed = Uuid::parse_str(&fact_seed)
        .map_err(|_| ReaderError::InvalidSettings)?
        .to_string();
    if next_visit_id.is_empty()
        || moment.unix_ms.unsigned_abs()
            > (i64::MAX - i64::from(i32::MAX) * 1000 - 2 * DAY_MS) as u64
        || state.charged_for(&moment) > DAY_MS as u64
    {
        return Err(ReaderError::InvalidRange);
    }
    let mut ordinal = 0;
    let slices = state.advance(
        moment,
        || {
            let id = if ordinal == 0 {
                seed.clone()
            } else {
                format!("{seed}:{ordinal}")
            };
            ordinal += 1;
            id
        },
        || next_visit_id,
    );
    Ok(ReadingClockStep {
        next: Arc::new(ReadingClockState(StepState::new(state))),
        slices,
    })
}

/// The host has already settled the last moment before a relocation.
#[uniffi::export]
pub fn break_reading_clock_visit(
    previous: Arc<ReadingClockState>,
    next_visit_id: String,
) -> Result<ReadingClockStep> {
    let mut state = previous.0.take()?;
    if next_visit_id.is_empty() {
        return Err(ReaderError::InvalidSettings);
    }
    let slices = state.relocate(next_visit_id);
    Ok(ReadingClockStep {
        next: Arc::new(ReadingClockState(StepState::new(state))),
        slices,
    })
}

impl ClockState {
    fn new(book_id: String, session_id: String, visit_id: String) -> Self {
        Self {
            book_id,
            session_id,
            visit_id,
            previous: None,
            remaining: IDLE_MS,
            pending: None,
        }
    }

    fn charged_for(&self, moment: &ReadingMoment) -> u64 {
        let Some(previous) = &self.previous else {
            return 0;
        };
        if !previous.readable {
            return 0;
        }
        let elapsed = moment.monotonic_ms.saturating_sub(previous.monotonic_ms);
        if previous.automatic_moving {
            moment
                .automatic_milliseconds
                .saturating_sub(previous.automatic_milliseconds)
                .min(elapsed)
        } else {
            elapsed.min(self.remaining)
        }
    }

    /// Only explicit interaction refreshes idle credit. Emits checkpoints at
    /// the same column/visit/midnight boundaries for both adapters.
    fn advance(
        &mut self,
        moment: ReadingMoment,
        mut next_id: impl FnMut() -> String,
        next_visit: impl FnOnce() -> String,
    ) -> Vec<ReadingSlice> {
        let mut output = Vec::new();
        if let Some(previous) = self.previous.clone() {
            let elapsed = moment.monotonic_ms.saturating_sub(previous.monotonic_ms);
            let charged = self.charged_for(&moment);
            if charged > 0 {
                self.append(&previous, charged, &mut output, &mut next_id);
                if !previous.automatic_moving {
                    self.remaining -= charged;
                }
            }
            if previous.automatic_moving && charged < elapsed {
                self.finish(&mut output);
            }
            let clock_changed = moment
                .unix_ms
                .saturating_sub(previous.unix_ms)
                .saturating_sub(i64::try_from(elapsed).unwrap_or(i64::MAX))
                .unsigned_abs()
                > 2000;
            if !moment.readable
                || moment.preview != previous.preview
                || moment.utc_offset_seconds != previous.utc_offset_seconds
                || clock_changed
                || (self.remaining == 0 && !moment.automatic_moving)
            {
                self.finish(&mut output);
                self.visit_id = next_visit();
            }
        }
        if moment.interaction {
            self.remaining = IDLE_MS;
        }
        self.previous = Some(moment);
        output
    }

    fn relocate(&mut self, visit_id: String) -> Vec<ReadingSlice> {
        let mut output = Vec::new();
        self.finish(&mut output);
        self.visit_id = visit_id;
        self.previous = None;
        output
    }

    fn finish(&mut self, output: &mut Vec<ReadingSlice>) {
        if let Some(value) = self.pending.take() {
            output.push(value);
        }
    }

    fn append(
        &mut self,
        moment: &ReadingMoment,
        duration: u64,
        output: &mut Vec<ReadingSlice>,
        next_id: &mut impl FnMut() -> String,
    ) {
        let mut at = moment.unix_ms;
        let mut left = duration as i64;
        while left > 0 {
            let offset = i64::from(moment.utc_offset_seconds) * 1000;
            let day = (at + offset).div_euclid(DAY_MS);
            let boundary = (day + 1) * DAY_MS - offset;
            let slice = self.pending.get_or_insert_with(|| ReadingSlice {
                id: next_id(),
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
    pub content_key: ReadingKey,
    pub book_id: Option<String>,
    pub title: String,
    pub author: Option<String>,
    pub cover: Option<BookCoverAsset>,
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
    pub content_key: ReadingKey,
    pub book_id: Option<String>,
    pub title: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    pub local_day: i64,
    pub utc_offset_seconds: i32,
    pub preview: bool,
    pub start_utf8: u64,
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
            automatic_moving: false,
            automatic_milliseconds: 0,
            preview: false,
            start_utf8: 0,
            end_utf8: 300,
        }
    }
    fn duration(slices: &[ReadingSlice]) -> i64 {
        slices.iter().map(|s| s.ended_ms - s.started_ms).sum()
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
    fn automatic_reading_charges_only_actual_motion_without_refreshing_idle_credit() {
        let clock = ReadingClock::new("book".into());
        clock.update(moment(0, true, true));
        assert_eq!(
            duration(&clock.update(moment(120_000, true, false))),
            120_000
        );
        let mut point = moment(120_000, true, false);
        point.automatic_moving = true;
        clock.update(point.clone());
        point.monotonic_ms = 300_000;
        point.unix_ms = 300_000;
        point.automatic_milliseconds = 180_000;
        assert_eq!(duration(&clock.update(point.clone())), 180_000);
        point.monotonic_ms = 600_000;
        point.unix_ms = 600_000;
        // No advanced frames during the stall: no elapsed-time backfill.
        assert_eq!(duration(&clock.update(point.clone())), 0);
        point.automatic_moving = false;
        clock.update(point);
        assert_eq!(duration(&clock.update(moment(610_000, true, false))), 0);
        let mut hidden = moment(610_000, false, false);
        hidden.automatic_moving = true;
        clock.update(hidden.clone());
        hidden.monotonic_ms = 620_000;
        hidden.unix_ms = 620_000;
        hidden.automatic_milliseconds = 10_000;
        assert_eq!(duration(&clock.update(hidden)), 0);

        for base in [0, DAY_MS - 10_000] {
            // Both a fully stalled interval and a partially charged interval
            // leave a gap before motion resumes at 10 seconds.
            for (during_gap, first_end) in [(1_000, 1_000), (2_000, 2_000)] {
                let clock = ReadingClock::new("book".into());
                let mut slices = Vec::new();
                for (ms, moving_ms) in [
                    (0, 0),
                    (1_000, 1_000),
                    (10_000, during_gap),
                    (11_000, during_gap + 1_000),
                ] {
                    let mut point = moment(ms, ms != 11_000, false);
                    point.unix_ms = base + ms as i64;
                    point.utc_offset_seconds = 0;
                    point.automatic_moving = true;
                    point.automatic_milliseconds = moving_ms;
                    slices.extend(clock.update(point));
                }
                assert_eq!(slices.len(), 2);
                assert_eq!(
                    (slices[0].started_ms, slices[0].ended_ms),
                    (base, base + first_end)
                );
                assert_eq!(
                    (slices[1].started_ms, slices[1].ended_ms),
                    (base + 10_000, base + 11_000)
                );
                assert_eq!(duration(&slices), first_end + 1_000);
                assert_eq!(slices[0].local_day, base.div_euclid(DAY_MS));
                assert_eq!(slices[1].local_day, (base + 10_000).div_euclid(DAY_MS));
                assert_eq!(slices[0].visit_id, slices[1].visit_id);
                assert_eq!(
                    slices
                        .iter()
                        .flat_map(|s| &s.exposures)
                        .map(|e| e.duration_ms)
                        .sum::<u64>(),
                    (first_end + 1_000) as u64
                );
            }
        }
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
    fn explicit_clock_preserves_pending_id_and_midnight_with_host_inputs() -> Result<()> {
        let day_start = DAY_MS - 28_800_000 - 5_000;
        let mut start = moment(0, true, true);
        start.unix_ms = day_start;
        let a = begin_reading_clock("book".into(), "session".into(), "visit-1".into())?;
        let seed_a = "00000000-0000-4000-8000-000000000001";
        let seed_b = "00000000-0000-4000-8000-000000000002";
        let seed_c = "00000000-0000-4000-8000-000000000003";
        let b = advance_reading_clock(a.clone(), start, seed_a.into(), "unused-a".into())?.next;
        assert!(
            advance_reading_clock(a, moment(0, true, true), seed_a.into(), "unused-a".into())
                .is_err()
        );
        let mut mid = moment(2_000, true, false);
        mid.unix_ms = day_start + 2_000;
        let waiting = advance_reading_clock(b, mid, seed_b.into(), "unused-b".into())?;
        assert!(waiting.slices.is_empty());
        let mut stop = moment(10_000, false, false);
        stop.unix_ms = day_start + 10_000;
        let ended = advance_reading_clock(waiting.next, stop, seed_c.into(), "visit-2".into())?;
        assert_eq!(duration(&ended.slices), 10_000);
        assert_eq!(
            ended
                .slices
                .iter()
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>(),
            [seed_b, seed_c]
        );
        assert!(
            ended
                .slices
                .iter()
                .all(|s| s.session_id == "session" && s.visit_id == "visit-1")
        );
        assert_eq!(ended.slices[0].local_day + 1, ended.slices[1].local_day);
        let broken = break_reading_clock_visit(ended.next.clone(), "visit-3".into())?;
        assert!(broken.slices.is_empty());
        assert!(break_reading_clock_visit(ended.next, "visit-4".into()).is_err());
        Ok(())
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
