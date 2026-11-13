//! Typed reading facts for prepared queries. Swift binds row IDs, owns candidate
//! selection, and keeps the original payload in SwiftData.
use crate::{ReaderError, ReadingExposure, ReadingSlice, Result};
use serde::{Deserialize, Deserializer, Serialize};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FactDecodeStatus {
    Accepted,
    Unreadable,
    NewerFormat,
}

// Serde's named-struct derive also accepts positional arrays. Require
// JSON objects at the wire boundaries using the same derived field visitor.
struct ObjectDeserializer<D>(D);

impl<'de, D: Deserializer<'de>> Deserializer<'de> for ObjectDeserializer<D> {
    type Error = D::Error;

    fn deserialize_any<V: serde::de::Visitor<'de>>(
        self,
        visitor: V,
    ) -> std::result::Result<V::Value, Self::Error> {
        self.0.deserialize_map(visitor)
    }

    serde::forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string
        bytes byte_buf option unit unit_struct newtype_struct seq tuple
        tuple_struct map struct enum identifier ignored_any
    }
}

#[repr(transparent)]
#[derive(Deserialize)]
#[serde(transparent, bound(deserialize = "T: Deserialize<'de>"))]
struct JsonObject<T>(#[serde(deserialize_with = "deserialize_object")] T);

fn deserialize_object<'de, T: Deserialize<'de>, D: Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<T, D::Error> {
    T::deserialize(ObjectDeserializer(deserializer))
}

pub(super) fn deserialize_exposures<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Vec<ReadingExposure>, D::Error> {
    Vec::<JsonObject<ReadingExposure>>::deserialize(deserializer)
        .map(|items| items.into_iter().map(|item| item.0).collect())
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct FactPayload<V> {
    #[serde(default, rename = "v")]
    version: V,
    content_key: String,
    title: String,
    device: String,
    #[serde(deserialize_with = "deserialize_object")]
    slice: ReadingSlice,
}

#[uniffi::export]
pub fn encode_reading_fact(
    content_key: String,
    title: String,
    device: String,
    slice: ReadingSlice,
) -> Result<String> {
    serde_json::to_string(&FactPayload {
        version: 1,
        content_key,
        title,
        device,
        slice,
    })
    .map_err(|_| ReaderError::InvalidSettings)
}

#[derive(Default, Deserialize)]
#[serde(transparent)]
struct FactVersion(#[serde(deserialize_with = "present_version")] Option<i64>);

// Absence defaults to v1. A present version must decode as an integer, not null.
fn present_version<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<i64>, D::Error> {
    i64::deserialize(deserializer).map(Some)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum FactGeometry {
    FirstExposure,
    Full,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FactSelectionCue {
    pub id: String,
    pub session_id: String,
    pub started_ms: i64,
    pub local_day: i64,
    pub has_version: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FactCue {
    pub batch_id: u64,
    pub ordinal: u64,
    pub status: FactDecodeStatus,
    pub selection: Option<FactSelectionCue>,
}

pub(super) struct FactData {
    pub(super) title: String,
    pub(super) device: String,
    pub(super) slice: ReadingSlice,
    pub(super) exposures: Arc<[ReadingExposure]>,
}

pub(super) struct DecodedFact {
    pub(super) data: FactData,
    has_version: bool,
    payload_content_key: String,
}

impl<V> FactPayload<V> {
    fn into_parts(self) -> (String, FactData) {
        let Self {
            content_key,
            title,
            device,
            mut slice,
            ..
        } = self;
        let exposures = std::mem::take(&mut slice.exposures).into();
        (
            content_key,
            FactData {
                title,
                device,
                slice,
                exposures,
            },
        )
    }
}

impl DecodedFact {
    fn cue(&self) -> FactSelectionCue {
        FactSelectionCue {
            id: self.data.slice.id.clone(),
            session_id: self.data.slice.session_id.clone(),
            started_ms: self.data.slice.started_ms,
            local_day: self.data.slice.local_day,
            has_version: self.has_version,
        }
    }
}

fn decode(text: &str) -> std::result::Result<Arc<DecodedFact>, FactDecodeStatus> {
    use FactDecodeStatus::{NewerFormat, Unreadable};
    let JsonObject(value): JsonObject<FactPayload<FactVersion>> =
        serde_json::from_str(text).map_err(|_| Unreadable)?;
    match value.version.0.unwrap_or(1) {
        1 => (),
        version if version > 1 => return Err(NewerFormat),
        _ => return Err(Unreadable),
    }
    // Nonempty ID equality is a Swift decision (including Unicode equivalence).
    if value.slice.id.is_empty() {
        return Err(Unreadable);
    }
    let has_version = value.version.0.is_some();
    let (payload_content_key, data) = value.into_parts();
    Ok(Arc::new(DecodedFact {
        data,
        has_version,
        payload_content_key,
    }))
}

#[derive(uniffi::Object)]
pub struct DecodedFactBatch {
    id: u64,
    base: u64,
    entries: Vec<std::result::Result<Arc<DecodedFact>, FactDecodeStatus>>,
}

static NEXT_FACT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn next_handle() -> Result<u64> {
    NEXT_FACT_HANDLE
        .try_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
        .map_err(|_| ReaderError::InvalidRange)
}

#[uniffi::export]
pub fn decode_fact_batch(base: u64, payloads: Vec<String>) -> Result<Arc<DecodedFactBatch>> {
    if !payloads.is_empty() {
        base.checked_add((payloads.len() - 1) as u64)
            .ok_or(ReaderError::InvalidRange)?;
    }
    let id = next_handle()?;
    Ok(Arc::new(DecodedFactBatch {
        id,
        base,
        entries: payloads.into_iter().map(|text| decode(&text)).collect(),
    }))
}

#[uniffi::export]
impl DecodedFactBatch {
    /// For portable backup only. Query routing uses the SwiftData row key.
    pub fn payload_content_key(&self, ordinal: u64) -> Result<String> {
        let index = ordinal
            .checked_sub(self.base)
            .and_then(|index| usize::try_from(index).ok())
            .ok_or(ReaderError::InvalidRange)?;
        let fact = self
            .entries
            .get(index)
            .ok_or(ReaderError::InvalidRange)?
            .as_ref()
            .map_err(|_| ReaderError::InvalidSettings)?;
        Ok(fact.payload_content_key.clone())
    }

    pub fn cues(&self) -> Vec<FactCue> {
        self.entries
            .iter()
            .enumerate()
            .map(|(index, fact)| {
                let (status, selection) = match fact {
                    Ok(fact) => (FactDecodeStatus::Accepted, Some(fact.cue())),
                    Err(status) => (*status, None),
                };
                FactCue {
                    batch_id: self.id,
                    ordinal: self.base + index as u64,
                    status,
                    selection,
                }
            })
            .collect()
    }
}

#[derive(uniffi::Record)]
pub struct FactBatchPick {
    pub batch_id: u64,
    pub ordinal: u64,
    pub content_key: String,
}

#[derive(uniffi::Record)]
pub struct FactBatchSelection {
    pub batch: Arc<DecodedFactBatch>,
    pub picks: Vec<FactBatchPick>,
}

#[derive(uniffi::Object)]
pub struct PreparedReadingFacts {
    id: u64,
    pub(super) selected: Vec<SelectedFact>,
}

pub(super) struct SelectedFact {
    pub(super) content_key: String,
    pub(super) fact: Arc<DecodedFact>,
}

#[uniffi::export]
pub fn seal_prepared_facts(chunks: Vec<FactBatchSelection>) -> Result<Arc<PreparedReadingFacts>> {
    let mut selected = Vec::new();
    let mut ordinals = std::collections::HashSet::new();
    for chunk in &chunks {
        for pick in &chunk.picks {
            if pick.batch_id != chunk.batch.id {
                return Err(ReaderError::InvalidRange);
            }
            let index = pick
                .ordinal
                .checked_sub(chunk.batch.base)
                .and_then(|index| usize::try_from(index).ok())
                .ok_or(ReaderError::InvalidRange)?;
            // Store-prepared input uses one contiguous ordinal space. The same
            // ordinal must not be reused via a second batch object.
            if !ordinals.insert(pick.ordinal) {
                return Err(ReaderError::InvalidRange);
            }
            let fact = chunk
                .batch
                .entries
                .get(index)
                .ok_or(ReaderError::InvalidRange)?
                .as_ref()
                .map_err(|_| ReaderError::InvalidSettings)?;
            selected.push(SelectedFact {
                content_key: pick.content_key.clone(),
                fact: fact.clone(),
            });
        }
    }
    // Preserve the Swift caller's chosen store-local output order.
    Ok(Arc::new(PreparedReadingFacts {
        id: next_handle()?,
        selected,
    }))
}

#[uniffi::export]
impl PreparedReadingFacts {
    pub fn first_title(&self) -> Option<String> {
        self.selected
            .first()
            .map(|item| item.fact.data.title.clone())
    }

    pub fn prepared_id(&self) -> u64 {
        self.id
    }
}

/// Indices into the store's sealed winner order, picked by Swift after the
/// date filter. Absent indices mean all winners; an empty list means none.
#[derive(uniffi::Record)]
pub struct FactQuerySelection {
    pub prepared: Arc<PreparedReadingFacts>,
    pub prepared_id: u64,
    pub indices: Option<Vec<u64>>,
}

impl FactQuerySelection {
    pub(super) fn try_each<'a>(&'a self, mut visit: impl FnMut(&'a SelectedFact)) -> Result<()> {
        if self.prepared.id != self.prepared_id {
            return Err(ReaderError::InvalidRange);
        }
        if let Some(indices) = &self.indices {
            let mut previous = None;
            for &index in indices {
                if previous.is_some_and(|previous| previous >= index) {
                    return Err(ReaderError::InvalidRange);
                }
                previous = Some(index);
                let item = usize::try_from(index)
                    .ok()
                    .and_then(|i| self.prepared.selected.get(i))
                    .ok_or(ReaderError::InvalidRange)?;
                visit(item);
            }
        } else {
            for item in &self.prepared.selected {
                visit(item);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    pub(in crate::user) fn payload(id: &str, day: i64, exposures: &str) -> String {
        format!(
            r#"{{"content_key":"embedded","title":"Synthetic","device":"fixture","slice":{{"id":"{id}","session_id":"s","visit_id":"v","book_id":"cached","started_ms":1200,"ended_ms":4200,"local_day":{day},"utc_offset_seconds":3600,"preview":false,"exposures":{exposures}}}}}"#,
        )
    }

    pub(in crate::user) fn pick(
        batch: &DecodedFactBatch,
        ordinal: u64,
        content_key: &str,
    ) -> FactBatchPick {
        FactBatchPick {
            batch_id: batch.id,
            ordinal,
            content_key: content_key.into(),
        }
    }

    #[test]
    fn typed_facts_validate_versions_shapes_and_integer_widths() -> Result<()> {
        use FactDecodeStatus::{Accepted, NewerFormat, Unreadable};

        let exposure = r#"[{"start_utf8":0,"end_utf8":18446744073709551615,"duration_ms":3000}]"#;
        let bare = payload("one", i64::MAX, exposure)
            .replace(
                r#""started_ms":1200"#,
                r#""started_ms":-9223372036854775808"#,
            )
            .replace(
                r#""utc_offset_seconds":3600"#,
                r#""utc_offset_seconds":-2147483648"#,
            );
        let with_version = |v: &str| format!(r#"{{"v":{v},{}"#, &bare[1..]);
        let positional_slice = r#"["one","s","v","cached",1200,4200,12,3600,false,[]]"#;
        let named_slice = &payload("one", 12, "[]");
        let slice_prefix = named_slice.split_once(r#""slice":"#).unwrap().0;
        let positional_fact = format!(
            r#"[1,"embedded","Synthetic","fixture",{}]"#,
            &named_slice[slice_prefix.len() + r#""slice":"#.len()..named_slice.len() - 1]
        );
        let batch = decode_fact_batch(
            0,
            vec![
                bare.clone(),
                with_version("1"),
                with_version("2"),
                with_version("0"),
                with_version("null"),
                with_version(r#""1""#),
                bare.replace(r#""device":"fixture","#, ""),
                positional_fact,
                format!(r#"{slice_prefix}"slice":{positional_slice}}}"#),
                payload("one", 12, "[[0,32,3000]]"),
                bare.replace(r#""preview":false"#, r#""preview":0"#),
                bare.replace(
                    r#""title":"Synthetic""#,
                    r#""title":"Synthetic","unknown":0"#,
                ),
                bare.replace(r#""visit_id":"v""#, r#""visit_id":"v","unknown":0"#),
                bare.replace(r#""duration_ms":3000"#, r#""duration_ms":3000,"unknown":0"#),
                bare.replace("9223372036854775807", "9223372036854775808"),
                bare.replace("-2147483648", "-2147483649"),
                bare.replace("18446744073709551615", "18446744073709551616"),
            ],
        )?;
        let cues = batch.cues();
        assert_eq!(cues[0].status, Accepted);
        assert_eq!(cues[1].status, Accepted);
        assert_eq!(cues[2].status, NewerFormat);
        assert!(cues[3..].iter().all(|cue| cue.status == Unreadable));
        assert!(cues[2..].iter().all(|cue| cue.selection.is_none()));
        let cue = cues[0].selection.as_ref().unwrap();
        assert_eq!(cue.local_day, i64::MAX);
        assert_eq!(cue.started_ms, i64::MIN);
        assert!(!cue.has_version);
        assert!(cues[1].selection.as_ref().unwrap().has_version);
        let fact = batch.entries[0].as_ref().unwrap();
        assert_eq!(fact.data.slice.utc_offset_seconds, i32::MIN);
        assert_eq!(fact.data.exposures[0].end_utf8, u64::MAX);
        Ok(())
    }

    #[test]
    fn fact_intake_uses_standard_serde_json() {
        let bare = payload("one", 12, "[]");
        for malformed in [
            format!("\u{feff}{bare}"),
            format!("{},}}", &bare[..bare.len() - 1]),
            format!(r#"{{"v":1,"v":1,{}"#, &bare[1..]),
            bare.replace(r#""local_day":12"#, r#""local_day":12.0"#),
        ] {
            assert!(matches!(
                decode(&malformed),
                Err(FactDecodeStatus::Unreadable)
            ));
        }
    }

    #[test]
    fn selections_are_bound_and_cannot_seal_an_unreadable_sibling() -> Result<()> {
        let bare = payload("one", 12, "[]");
        // The same external ID may appear on a bad sibling. Expose the
        // status, never a selection cue; Swift owns the group barrier.
        let bad = bare.replace(r#""preview":false"#, r#""preview":0"#);
        let batch = decode_fact_batch(7, vec![bare.clone(), bad])?;
        let other = decode_fact_batch(7, vec![bare])?;
        assert!(batch.cues()[1].selection.is_none());
        let seal = |picks| {
            seal_prepared_facts(vec![FactBatchSelection {
                batch: batch.clone(),
                picks,
            }])
        };
        for picks in [
            vec![pick(&other, 7, "key")],
            vec![pick(&batch, 6, "key")],
            vec![pick(&batch, 9, "key")],
            vec![pick(&batch, 7, "key"), pick(&batch, 7, "key")],
        ] {
            assert!(matches!(seal(picks), Err(ReaderError::InvalidRange)));
        }
        assert!(matches!(
            seal(vec![pick(&batch, 8, "key")]),
            Err(ReaderError::InvalidSettings)
        ));
        assert!(matches!(
            decode_fact_batch(u64::MAX, vec![String::new(), String::new()]),
            Err(ReaderError::InvalidRange)
        ));
        let prepared = seal(vec![pick(&batch, 7, "row-key")])?;
        let mut selected = Vec::new();
        let mut query = FactQuerySelection {
            prepared_id: prepared.id,
            prepared,
            indices: Some(vec![0]),
        };
        query.try_each(|row| selected.push(row.content_key.clone()))?;
        assert_eq!(selected, ["row-key"]);
        for indices in [vec![0, 0], vec![1]] {
            query.indices = Some(indices);
            assert!(matches!(
                query.try_each(|_| ()),
                Err(ReaderError::InvalidRange)
            ));
        }
        query.indices = None;
        query.prepared_id += 1;
        assert!(matches!(
            query.try_each(|_| ()),
            Err(ReaderError::InvalidRange)
        ));
        Ok(())
    }
}
