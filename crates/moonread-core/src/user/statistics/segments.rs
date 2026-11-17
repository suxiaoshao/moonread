//! Single-author cumulative reading evidence. No storage, clock, or random
//! generator enters these calls. Swift owns the authorized book route and
//! commits each complete snapshot with its effective contribution.

use super::{CHECKPOINT_MS, DAY_MS, ReadingExposure, ReadingMoment, ReadingTiming};
use crate::reading::compute::StepState;
use crate::user::reading_fact::{
    FactDecodeStatus, JsonObject, deserialize_exposures, deserialize_object,
};
use crate::{ReaderError, Result, parse_reading_key};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

const MAX_EXPOSURES: u32 = 2_048;
const MAX_EXPOSURE_BYTES: u32 = 256 * 1024;
// Enough for one compact JSON object even with both offsets at UInt64::MAX,
// the largest permitted in-day duration, and the array brackets.
const MIN_EXPOSURE_BYTES: u32 = 128;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct ReadingSegmentAuthor {
    pub owner_instance_id: String,
    pub session_id: String,
    pub title: String,
    pub device: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
#[serde(deny_unknown_fields)]
pub struct ReadingSegmentHeader {
    pub id: String,
    #[serde(deserialize_with = "deserialize_object")]
    pub author: ReadingSegmentAuthor,
    pub visit_id: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    pub local_day: i64,
    pub utc_offset_seconds: i32,
    pub preview: bool,
    pub revision: u64,
    pub duration_ms: u64,
    pub sealed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ReadingSegment {
    pub header: ReadingSegmentHeader,
    pub first_exposure_start: u64,
    /// Canonical compact JSON, carried once over FFI and stored as TEXT.
    pub exposures_text: String,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct ReadingSegmentLimits {
    pub max_exposures: u32,
    pub max_exposure_bytes: u32,
}

#[uniffi::export]
pub fn reading_segment_limits() -> ReadingSegmentLimits {
    ReadingSegmentLimits {
        max_exposures: MAX_EXPOSURES,
        max_exposure_bytes: MAX_EXPOSURE_BYTES,
    }
}

#[derive(uniffi::Object)]
pub struct ReadingSegmentState(StepState<Capture>);

#[derive(uniffi::Record)]
pub struct ReadingSegmentStep {
    pub next: Arc<ReadingSegmentState>,
    pub segment_updates: Vec<ReadingSegment>,
    /// Counts this step's time once, even when no checkpoint was emitted.
    pub charged_delta_ms: u64,
}

struct Capture {
    author: ReadingSegmentAuthor,
    visit_id: String,
    timing: ReadingTiming,
    limits: ReadingSegmentLimits,
    active: Option<Active>,
    // The continuous axis survives a storage-only day/capacity split.
    end: Option<i64>,
}

struct Active {
    header: ReadingSegmentHeader,
    exposures: Vec<ReadingExposure>,
    exposure_bytes: usize,
    last_bytes: usize,
    checkpointed_duration: u64,
}

#[uniffi::export]
pub fn begin_reading_segment(
    author: ReadingSegmentAuthor,
    visit_id: String,
    limits: ReadingSegmentLimits,
) -> Result<Arc<ReadingSegmentState>> {
    if !valid_author(&author)
        || visit_id.is_empty()
        || !(1..=MAX_EXPOSURES).contains(&limits.max_exposures)
        || !(MIN_EXPOSURE_BYTES..=MAX_EXPOSURE_BYTES).contains(&limits.max_exposure_bytes)
    {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(Arc::new(ReadingSegmentState(StepState::new(Capture {
        author,
        visit_id,
        timing: ReadingTiming::new(),
        limits,
        active: None,
        end: None,
    }))))
}

#[uniffi::export]
pub fn advance_reading_segment(
    previous: Arc<ReadingSegmentState>,
    moment: ReadingMoment,
    segment_seed: String,
    next_visit_id: String,
) -> Result<ReadingSegmentStep> {
    let mut state = previous.0.take()?;
    let seed = Uuid::parse_str(&segment_seed)
        .map_err(|_| ReaderError::InvalidSettings)?
        .to_string();
    if next_visit_id.is_empty() || (moment.readable && moment.start_utf8 >= moment.end_utf8) {
        return Err(ReaderError::InvalidRange);
    }

    let mut output = Vec::new();
    let mut charged_delta_ms = 0;
    if let Some(charge) = state.timing.advance(moment) {
        charged_delta_ms = charge.duration;
        state.append(&charge.previous, charge.duration, &seed, &mut output)?;
        if charge.ends_visit || (charge.previous.readable && charge.duration < charge.elapsed) {
            state.finish(&mut output)?;
            state.end = None;
            state.visit_id = next_visit_id;
        } else if let Some(active) = &mut state.active
            && active.header.duration_ms - active.checkpointed_duration
                >= u64::try_from(CHECKPOINT_MS).unwrap()
        {
            // At most the last checkpoint of this ID in a single step. If
            // the step sealed it already, only the sealed version is sent.
            output.push(active.snapshot(false)?);
        }
    }
    Ok(state.step(output, charged_delta_ms))
}

/// Settle the final observation before this call when it is available.
#[uniffi::export]
pub fn break_reading_segment_visit(
    previous: Arc<ReadingSegmentState>,
    next_visit_id: String,
) -> Result<ReadingSegmentStep> {
    let mut state = previous.0.take()?;
    if next_visit_id.is_empty() {
        return Err(ReaderError::InvalidSettings);
    }
    let mut output = Vec::new();
    state.finish(&mut output)?;
    state.end = None;
    state.timing.previous = None;
    state.visit_id = next_visit_id;
    Ok(state.step(output, 0))
}

impl Capture {
    fn step(
        self,
        segment_updates: Vec<ReadingSegment>,
        charged_delta_ms: u64,
    ) -> ReadingSegmentStep {
        ReadingSegmentStep {
            next: Arc::new(ReadingSegmentState(StepState::new(self))),
            segment_updates,
            charged_delta_ms,
        }
    }

    fn finish(&mut self, output: &mut Vec<ReadingSegment>) -> Result<()> {
        if let Some(mut active) = self.active.take() {
            output.push(active.snapshot(true)?);
        }
        Ok(())
    }

    fn append(
        &mut self,
        observation: &ReadingMoment,
        mut duration: u64,
        seed: &str,
        output: &mut Vec<ReadingSegment>,
    ) -> Result<()> {
        let mut ordinal = 0;
        while duration > 0 {
            let at = self.end.unwrap_or(observation.unix_ms);
            let offset_ms = i128::from(observation.utc_offset_seconds) * 1000;
            let day = local_day(at, observation.utc_offset_seconds);
            let midnight = (i128::from(day) + 1) * i128::from(DAY_MS) - offset_ms;
            let delta = duration.min(
                u64::try_from(midnight - i128::from(at)).map_err(|_| ReaderError::InvalidRange)?,
            );
            let end = at
                .checked_add(i64::try_from(delta).map_err(|_| ReaderError::InvalidRange)?)
                .ok_or(ReaderError::InvalidRange)?;
            let active = self.active.get_or_insert_with(|| {
                let id = if ordinal == 0 {
                    seed.to_owned()
                } else {
                    format!("{seed}:{ordinal}")
                };
                ordinal += 1;
                Active {
                    header: ReadingSegmentHeader {
                        id,
                        author: self.author.clone(),
                        visit_id: self.visit_id.clone(),
                        started_ms: at,
                        ended_ms: at,
                        local_day: day,
                        utc_offset_seconds: observation.utc_offset_seconds,
                        preview: observation.preview,
                        revision: 0,
                        duration_ms: 0,
                        sealed: false,
                    },
                    exposures: Vec::new(),
                    exposure_bytes: 2,
                    last_bytes: 0,
                    checkpointed_duration: 0,
                }
            });
            if !active.append(observation, delta, end, self.limits)? {
                // The configured minimum fits any first exposure. Every
                // capacity split therefore seals a nonempty prefix.
                if active.exposures.is_empty() {
                    return Err(ReaderError::InvalidRange);
                }
                self.finish(output)?;
                continue;
            }
            self.end = Some(end);
            duration -= delta;
            if i128::from(end) == midnight {
                self.finish(output)?;
            }
        }
        Ok(())
    }
}

impl Active {
    fn append(
        &mut self,
        observation: &ReadingMoment,
        duration: u64,
        end: i64,
        limits: ReadingSegmentLimits,
    ) -> Result<bool> {
        let same_range = self.exposures.last().filter(|last| {
            last.start_utf8 == observation.start_utf8 && last.end_utf8 == observation.end_utf8
        });
        if same_range.is_none() && self.exposures.len() == limits.max_exposures as usize {
            return Ok(false);
        }
        let exposure = ReadingExposure {
            start_utf8: observation.start_utf8,
            end_utf8: observation.end_utf8,
            duration_ms: duration + same_range.map_or(0, |e| e.duration_ms),
        };
        // Measure just the new/changed element with the same compact codec.
        // A normal sample need not encode the entire active vector.
        let bytes = json(&exposure)?.len();
        let total = if same_range.is_some() {
            self.exposure_bytes - self.last_bytes + bytes
        } else {
            self.exposure_bytes + usize::from(!self.exposures.is_empty()) + bytes
        };
        if total > limits.max_exposure_bytes as usize {
            return Ok(false);
        }
        if same_range.is_some() {
            *self.exposures.last_mut().unwrap() = exposure;
        } else {
            self.exposures.push(exposure);
        }
        self.exposure_bytes = total;
        self.last_bytes = bytes;
        self.header.ended_ms = end;
        self.header.duration_ms += duration;
        Ok(true)
    }

    fn snapshot(&mut self, sealed: bool) -> Result<ReadingSegment> {
        self.header.revision = next_revision(self.header.revision)?;
        self.header.sealed = sealed;
        self.checkpointed_duration = self.header.duration_ms;
        let value = snapshot(self.header.clone(), &self.exposures)?;
        debug_assert_eq!(value.exposures_text.len(), self.exposure_bytes);
        Ok(value)
    }
}

fn json(value: &impl Serialize) -> Result<String> {
    serde_json::to_string(value).map_err(|_| ReaderError::InvalidSettings)
}
fn next_revision(revision: u64) -> Result<u64> {
    revision.checked_add(1).ok_or(ReaderError::InvalidRange)
}
fn local_day(at: i64, offset: i32) -> i64 {
    (i128::from(at) + i128::from(offset) * 1000).div_euclid(i128::from(DAY_MS)) as i64
}
fn valid_author(author: &ReadingSegmentAuthor) -> bool {
    !author.owner_instance_id.is_empty()
        && !author.session_id.is_empty()
        && !author.device.is_empty()
}

fn snapshot(header: ReadingSegmentHeader, exposures: &[ReadingExposure]) -> Result<ReadingSegment> {
    let first = exposures.first().ok_or(ReaderError::InvalidRange)?;
    Ok(ReadingSegment {
        header,
        first_exposure_start: first.start_utf8,
        exposures_text: json(&exposures)?,
    })
}

fn validate(header: &ReadingSegmentHeader, exposures: &[ReadingExposure]) -> Result<()> {
    let span = header
        .ended_ms
        .checked_sub(header.started_ms)
        .and_then(|duration| u64::try_from(duration).ok());
    if header.id.is_empty()
        || header.visit_id.is_empty()
        || !valid_author(&header.author)
        || header.revision == 0
        || header.duration_ms == 0
        || span != Some(header.duration_ms)
        || header.local_day != local_day(header.started_ms, header.utc_offset_seconds)
        || header.local_day != local_day(header.ended_ms - 1, header.utc_offset_seconds)
        || exposures.is_empty()
        || exposures.len() > MAX_EXPOSURES as usize
    {
        return Err(ReaderError::InvalidRange);
    }
    let mut sum = 0_u64;
    let mut last = None;
    for exposure in exposures {
        let range = (exposure.start_utf8, exposure.end_utf8);
        if range.0 >= range.1 || exposure.duration_ms == 0 || last == Some(range) {
            return Err(ReaderError::InvalidRange);
        }
        sum = sum
            .checked_add(exposure.duration_ms)
            .ok_or(ReaderError::InvalidRange)?;
        last = Some(range);
    }
    if sum != header.duration_ms {
        return Err(ReaderError::InvalidRange);
    }
    Ok(())
}

fn parse_exposure(segment: &ReadingSegment) -> Result<Vec<JsonObject<ReadingExposure>>> {
    if segment.exposures_text.len() > MAX_EXPOSURE_BYTES as usize {
        return Err(ReaderError::InvalidRange);
    }
    serde_json::from_str(&segment.exposures_text).map_err(|_| ReaderError::InvalidSettings)
}

fn validated_exposure(segment: &ReadingSegment) -> Result<Vec<ReadingExposure>> {
    let exposures: Vec<_> = parse_exposure(segment)?.into_iter().map(|e| e.0).collect();
    validate(&segment.header, &exposures)?;
    if exposures[0].start_utf8 != segment.first_exposure_start {
        return Err(ReaderError::InvalidRange);
    }
    Ok(exposures)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WireSegment {
    v: u32,
    exposure_version: u32,
    book_key: String,
    #[serde(deserialize_with = "deserialize_object")]
    segment: ReadingSegmentHeader,
    #[serde(deserialize_with = "deserialize_exposures")]
    exposures: Vec<ReadingExposure>,
}

#[derive(uniffi::Record)]
pub struct ReadingSegmentDecode {
    pub status: FactDecodeStatus,
    pub book_key: Option<String>,
    pub segment: Option<ReadingSegment>,
}

#[uniffi::export]
pub fn encode_reading_segment(book_key: String, segment: ReadingSegment) -> Result<String> {
    parse_reading_key(book_key.clone())?;
    let exposures = validated_exposure(&segment)?;
    json(&WireSegment {
        v: 1,
        exposure_version: 1,
        book_key,
        segment: segment.header,
        exposures,
    })
}

#[uniffi::export]
pub fn decode_reading_segment(payload: String) -> ReadingSegmentDecode {
    #[derive(Deserialize)]
    struct VersionProbe {
        v: Option<u32>,
        exposure_version: Option<u32>,
    }
    fn status(status: FactDecodeStatus) -> ReadingSegmentDecode {
        ReadingSegmentDecode {
            status,
            book_key: None,
            segment: None,
        }
    }
    let Ok(JsonObject(wire)) = serde_json::from_str::<JsonObject<WireSegment>>(&payload) else {
        return if serde_json::from_str::<JsonObject<VersionProbe>>(&payload).is_ok_and(|probe| {
            probe.0.v.is_some_and(|version| version > 1)
                || probe.0.exposure_version.is_some_and(|version| version > 1)
        }) {
            status(FactDecodeStatus::NewerFormat)
        } else {
            status(FactDecodeStatus::Unreadable)
        };
    };
    if wire.v > 1 || wire.exposure_version > 1 {
        return status(FactDecodeStatus::NewerFormat);
    }
    if wire.v != 1
        || wire.exposure_version != 1
        || parse_reading_key(wire.book_key.clone()).is_err()
        || validate(&wire.segment, &wire.exposures).is_err()
    {
        return status(FactDecodeStatus::Unreadable);
    }
    let Ok(segment) = snapshot(wire.segment, &wire.exposures) else {
        return status(FactDecodeStatus::Unreadable);
    };
    if segment.exposures_text.len() > MAX_EXPOSURE_BYTES as usize {
        return status(FactDecodeStatus::Unreadable);
    }
    ReadingSegmentDecode {
        status: FactDecodeStatus::Accepted,
        book_key: Some(wire.book_key),
        segment: Some(segment),
    }
}

#[derive(Debug, PartialEq, Eq, uniffi::Record)]
pub struct ReadingSegmentTail {
    pub started_ms: i64,
    pub ended_ms: i64,
    pub duration_ms: u64,
    pub trim_prefix_ms: u64,
    pub first_exposure_start: u64,
}

/// Return only the effective head; the raw snapshot and its exposure TEXT
/// are unchanged. Coverage can later start at the same trim offset.
#[uniffi::export]
pub fn trim_reading_segment(
    segment: ReadingSegment,
    covered_through_ms: i64,
) -> Result<Option<ReadingSegmentTail>> {
    let exposures = validated_exposure(&segment)?;
    let h = &segment.header;
    let start = covered_through_ms.clamp(h.started_ms, h.ended_ms);
    if start == h.ended_ms {
        return Ok(None);
    }
    let trim = u64::try_from(start - h.started_ms).map_err(|_| ReaderError::InvalidRange)?;
    let mut skip = trim;
    let first = exposures
        .into_iter()
        .find(|e| {
            if skip < e.duration_ms {
                true
            } else {
                skip -= e.duration_ms;
                false
            }
        })
        .ok_or(ReaderError::InvalidRange)?;
    Ok(Some(ReadingSegmentTail {
        started_ms: start,
        ended_ms: h.ended_ms,
        duration_ms: h.duration_ms - trim,
        trim_prefix_ms: trim,
        first_exposure_start: first.start_utf8,
    }))
}

/// Eligibility is checked by Swift against local_unsealed_owner and the
/// phase/lease. This pure transition never receives a new time or exposure.
#[uniffi::export]
pub fn seal_reading_segment(mut segment: ReadingSegment) -> Result<ReadingSegment> {
    validated_exposure(&segment)?;
    if segment.header.sealed {
        return Err(ReaderError::InvalidSettings);
    }
    segment.header.revision = next_revision(segment.header.revision)?;
    segment.header.sealed = true;
    Ok(segment)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn author() -> ReadingSegmentAuthor {
        ReadingSegmentAuthor {
            owner_instance_id: "install".into(),
            session_id: "session".into(),
            title: "Fixture".into(),
            device: "device".into(),
        }
    }

    fn moment(t: u64, wall: i64, range: (u64, u64)) -> ReadingMoment {
        ReadingMoment {
            monotonic_ms: t,
            unix_ms: wall,
            utc_offset_seconds: 0,
            readable: true,
            interaction: true,
            automatic_moving: false,
            automatic_milliseconds: 0,
            preview: false,
            start_utf8: range.0,
            end_utf8: range.1,
        }
    }

    fn tick(
        state: Arc<ReadingSegmentState>,
        observation: ReadingMoment,
        id: u64,
    ) -> Result<ReadingSegmentStep> {
        advance_reading_segment(
            state,
            observation,
            format!("00000000-0000-4000-8000-{id:012x}"),
            format!("visit-{id}"),
        )
    }

    #[test]
    fn one_hour_keeps_one_segment_and_counts_only_each_step_delta() -> Result<()> {
        let wall = DAY_MS * 40;
        let mut state =
            begin_reading_segment(author(), "original".into(), reading_segment_limits())?;
        let mut checked = None::<ReadingSegment>;
        let mut charged = 0;
        let mut emitted = 0;
        for second in 0..=3_600 {
            let t = second * 1_000;
            let step = tick(state, moment(t, wall + t as i64, (1, 200)), second)?;
            charged += step.charged_delta_ms;
            for saved in step.segment_updates {
                assert!(!saved.header.sealed);
                assert_eq!(saved.header.duration_ms, t);
                assert_eq!(saved.header.visit_id, "original");
                let exposure = validated_exposure(&saved)?;
                assert_eq!(exposure.len(), 1);
                assert_eq!(exposure[0].duration_ms, t);
                if let Some(prior) = checked.replace(saved.clone()) {
                    assert_eq!(saved.header.id, prior.header.id);
                    assert_eq!(saved.header.revision, prior.header.revision + 1);
                }
                emitted += 1;
            }
            state = step.next;
        }
        assert_eq!((emitted, charged), (240, 3_600_000));
        let settled = break_reading_segment_visit(state, "new-visit".into())?;
        assert_eq!(settled.charged_delta_ms, 0);
        assert_eq!(
            settled.segment_updates,
            [seal_reading_segment(checked.unwrap())?]
        );
        Ok(())
    }

    #[test]
    fn consume_state_and_preserve_storage_boundary_continuity() -> Result<()> {
        for limits in [
            ReadingSegmentLimits {
                max_exposures: 1,
                max_exposure_bytes: MAX_EXPOSURE_BYTES,
            },
            ReadingSegmentLimits {
                max_exposures: MAX_EXPOSURES,
                max_exposure_bytes: MIN_EXPOSURE_BYTES,
            },
        ] {
            let a = (u64::MAX - 99, u64::MAX - 50);
            let b = (u64::MAX - 50, u64::MAX);
            let wall = DAY_MS - 4_000;
            let empty = begin_reading_segment(author(), "visit".into(), limits)?;
            let start = tick(empty.clone(), moment(0, wall, a), 0)?;
            assert!(tick(empty, moment(0, wall, a), 8).is_err());
            let next = tick(start.next, moment(2_000, wall + 2_700, b), 1)?;
            assert!(next.segment_updates.is_empty());
            let end = tick(next.next, moment(5_000, wall + 5_700, b), 2)?;
            assert_eq!(end.charged_delta_ms, 3_000);
            assert_eq!(
                end.segment_updates.len(),
                2,
                "capacity seal and midnight seal"
            );
            let last = break_reading_segment_visit(end.next, "jump".into())?;
            let all = end
                .segment_updates
                .into_iter()
                .chain(last.segment_updates)
                .collect::<Vec<_>>();
            assert_eq!(
                all.iter()
                    .map(|s| (s.header.started_ms, s.header.ended_ms, s.header.local_day))
                    .collect::<Vec<_>>(),
                [
                    (wall, wall + 2_000, 0),
                    (wall + 2_000, DAY_MS, 0),
                    (DAY_MS, DAY_MS + 1_000, 1)
                ]
            );
            assert_eq!(
                all.iter().map(|s| s.header.id.as_str()).collect::<Vec<_>>(),
                [
                    "00000000-0000-4000-8000-000000000001",
                    "00000000-0000-4000-8000-000000000002",
                    "00000000-0000-4000-8000-000000000002:1",
                ]
            );
            let coverage = super::super::visible_dwell_ranges(
                all.iter()
                    .map(|segment| {
                        Ok(super::super::CoverageFact {
                            visit_id: segment.header.visit_id.clone(),
                            started_ms: segment.header.started_ms,
                            ended_ms: segment.header.ended_ms,
                            exposures: validated_exposure(segment)?,
                        })
                    })
                    .collect::<Result<_>>()?,
            )
            .unwrap();
            assert_eq!(coverage.len(), 1);
            assert_eq!(
                (coverage[0].start_utf8, coverage[0].end_utf8),
                b,
                "two seconds before midnight plus one after still use the original coverage rule"
            );
            for segment in all {
                assert!(segment.header.sealed);
                assert_eq!(segment.header.visit_id, "visit");
                assert!(segment.exposures_text.len() <= limits.max_exposure_bytes as usize);
                validated_exposure(&segment)?;
            }
        }
        let live = begin_reading_segment(author(), "initial".into(), reading_segment_limits())?;
        assert!(
            advance_reading_segment(
                live.clone(),
                moment(0, 100, (0, 5)),
                "bad seed".into(),
                "next".into()
            )
            .is_err()
        );
        assert!(
            tick(live, moment(0, 100, (0, 5)), 1).is_err(),
            "failure consumes the input state"
        );
        Ok(())
    }

    #[test]
    fn idle_preview_timezone_and_automatic_gap_end_visits_without_backfill() -> Result<()> {
        let mut state =
            begin_reading_segment(author(), "initial".into(), reading_segment_limits())?;
        let points = [
            (0, true, false, 0, false, 0, true),
            (200_000, true, false, 0, false, 0, true), // only 120 s credited
            (205_000, true, true, 0, true, 0, false),  // preview break after valid former reading
            (210_000, true, true, 0, true, 4_999, false), // a real 1 ms automatic gap
            (215_000, true, true, 3600, true, 8_999, false), // timezone changes
            (220_000, false, true, 3600, false, 9_999, false), // background
        ];
        let mut sealed = Vec::new();
        let mut deltas = Vec::new();
        let base = 8 * DAY_MS;
        for (index, (t, readable, preview, tz, automatic, motion, interaction)) in
            points.into_iter().enumerate()
        {
            let mut sample = moment(t, base + t as i64, (1, 15));
            sample.readable = readable;
            sample.preview = preview;
            sample.utc_offset_seconds = tz;
            sample.automatic_moving = automatic;
            sample.automatic_milliseconds = motion;
            sample.interaction = interaction;
            let step = tick(state, sample, index as u64)?;
            deltas.push(step.charged_delta_ms);
            sealed.extend(step.segment_updates);
            state = step.next;
        }
        assert_eq!(deltas, [0, 120_000, 5_000, 4_999, 4_000, 1_000]);
        assert_eq!(
            sealed
                .iter()
                .map(|s| s.header.visit_id.as_str())
                .collect::<Vec<_>>(),
            ["initial", "visit-1", "visit-2", "visit-3", "visit-4"]
        );
        assert!(sealed.iter().all(|s| s.header.sealed));
        assert_eq!(sealed[2].header.ended_ms + 1, sealed[3].header.started_ms);
        assert!(!sealed[1].header.preview);
        assert!(sealed[2].header.preview);
        assert_eq!(sealed[4].header.utc_offset_seconds, 3600);
        assert!(
            break_reading_segment_visit(state, "closed".into())?
                .segment_updates
                .is_empty()
        );
        Ok(())
    }

    fn version(revision: u64, sealed: bool, measurements: &[(u64, u64, u64)]) -> ReadingSegment {
        let exposures = measurements
            .iter()
            .map(|&(start_utf8, end_utf8, duration_ms)| ReadingExposure {
                start_utf8,
                end_utf8,
                duration_ms,
            })
            .collect::<Vec<_>>();
        let duration = exposures.iter().map(|e| e.duration_ms).sum::<u64>();
        snapshot(
            ReadingSegmentHeader {
                id: "segment".into(),
                author: author(),
                visit_id: "visit".into(),
                started_ms: 20,
                ended_ms: 20 + duration as i64,
                local_day: 0,
                utc_offset_seconds: 0,
                preview: false,
                revision,
                duration_ms: duration,
                sealed,
            },
            &exposures,
        )
        .unwrap()
    }

    #[test]
    fn sealing_and_clearing_do_not_change_the_raw_exposure_evidence() -> Result<()> {
        let a = version(1, false, &[(1, 4, 2_000), (9, 11, 1_000)]);
        let b = version(
            3,
            false,
            &[(1, 4, 2_000), (9, 11, 2_000), (20, u64::MAX, 2_000)],
        );
        let c = seal_reading_segment(b.clone())?;
        assert_eq!(c.header.revision, b.header.revision + 1);
        assert_eq!(c.header.ended_ms, b.header.ended_ms);
        assert_eq!(c.exposures_text, b.exposures_text);
        assert!(
            trim_reading_segment(a, 4_020)?.is_none(),
            "future clear removes the known prefix"
        );
        assert_eq!(
            trim_reading_segment(c.clone(), 4_020)?,
            Some(ReadingSegmentTail {
                started_ms: 4_020,
                ended_ms: 6_020,
                duration_ms: 2_000,
                trim_prefix_ms: 4_000,
                first_exposure_start: 20,
            })
        );
        assert_eq!(
            trim_reading_segment(c, 3_020)?
                .unwrap()
                .first_exposure_start,
            9
        );
        let mut exhausted = b;
        exhausted.header.revision = u64::MAX;
        assert!(seal_reading_segment(exhausted).is_err());
        Ok(())
    }

    #[test]
    fn typed_wire_uses_explicit_version_and_exact_duration_and_geometry() -> Result<()> {
        let source = version(2, true, &[(u64::MAX - 1, u64::MAX, 1_234)]);
        let book = "a".repeat(64);
        let wire = encode_reading_segment(book.clone(), source.clone())?;
        assert_eq!(decode_reading_segment(wire.clone()).segment, Some(source));
        assert_eq!(decode_reading_segment(wire.clone()).book_key, Some(book));
        for bad in [
            wire.replace(r#""duration_ms":1234"#,r#""duration_ms":1235"#),
            wire.replace(r#""local_day":0"#,r#""local_day":1"#),
            wire.replace(r#""exposures":[{"start_utf8":18446744073709551614,"end_utf8":18446744073709551615,"duration_ms":1234}]"#,
                         r#""exposures":[[18446744073709551614,18446744073709551615,1234]]"#),
            wire.replace(r#""v":1,"#,""),
        ] {
            assert_eq!(decode_reading_segment(bad).status, FactDecodeStatus::Unreadable);
        }
        assert_eq!(
            decode_reading_segment(
                wire.replace(r#""v":1"#, r#""v":2,"future":"typed differently""#)
            )
            .status,
            FactDecodeStatus::NewerFormat
        );
        assert_eq!(
            decode_reading_segment(
                wire.replace(r#""exposure_version":1"#, r#""exposure_version":2"#)
            )
            .status,
            FactDecodeStatus::NewerFormat
        );
        Ok(())
    }
}
