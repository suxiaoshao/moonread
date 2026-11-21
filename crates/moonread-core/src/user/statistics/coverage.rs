//! Continuous dwell calculation over facts supplied in visit/time order by Swift.
use crate::reading::text_count::count_text_scalars;
use crate::user::reading_fact::JsonObject;
use crate::{ReaderError, ReadingExposure, Result, SourceSpan};
use std::collections::BTreeMap;

const MIN_VISIBLE_MS: u64 = 3_000;

#[derive(Default)]
struct VisibleDwell {
    active: Vec<(u64, u64, u64)>,
    covered: BTreeMap<u64, u64>,
}
impl VisibleDwell {
    fn observe(&mut self, start: u64, end: u64, duration: u64) {
        if start >= end {
            self.active.clear();
            return;
        }
        let mut cuts = vec![start, end];
        for &(a, b, _) in &self.active {
            if a > start && a < end {
                cuts.push(a);
            }
            if b > start && b < end {
                cuts.push(b);
            }
        }
        cuts.sort_unstable();
        cuts.dedup();
        let mut next: Vec<(u64, u64, u64)> = Vec::new();
        for pair in cuts.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            let prior = self
                .active
                .iter()
                .find(|&&(s, e, _)| s <= a && e >= b)
                .map_or(0, |v| v.2);
            let elapsed = prior.saturating_add(duration).min(MIN_VISIBLE_MS);
            if elapsed >= MIN_VISIBLE_MS {
                self.cover(a, b);
            }
            if let Some(last) = next.last_mut()
                && last.1 == a
                && last.2 == elapsed
            {
                last.1 = b;
            } else {
                next.push((a, b, elapsed));
            }
        }
        self.active = next;
    }
    fn cover(&mut self, mut start: u64, mut end: u64) {
        if let Some((&a, &b)) = self.covered.range(..=start).next_back()
            && b >= start
        {
            start = a;
            end = end.max(b);
            self.covered.remove(&a);
        }
        while let Some((&a, &b)) = self.covered.range(start..).next() {
            if a > end {
                break;
            }
            end = end.max(b);
            self.covered.remove(&a);
        }
        self.covered.insert(start, end);
    }
}

#[derive(uniffi::Record)]
pub struct CoverageFact {
    pub visit_id: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    pub exposures: Vec<ReadingExposure>,
}

/// Byte ranges are disjoint and sorted. None distinguishes missing evidence from zero dwell.
#[uniffi::export]
pub fn visible_dwell_ranges(facts: Vec<CoverageFact>) -> Option<Vec<SourceSpan>> {
    dwell_ranges(facts.into_iter().map(|fact| Ok((String::new(), fact))))
        .expect("typed coverage cannot fail")
}

/// Selected current heads, ordered by session, visit, effective start and typed ID.
#[derive(uniffi::Record)]
pub struct CoverageExposureText {
    pub session: String,
    pub visit: String,
    pub started_ms: i64,
    pub ended_ms: i64,
    pub version: u32,
    pub trim_prefix_ms: u64,
    pub text: String,
}

#[uniffi::export]
pub fn visible_dwell_from_text(rows: Vec<CoverageExposureText>) -> Result<Option<Vec<SourceSpan>>> {
    dwell_ranges(rows.into_iter().map(|row| {
        if row.version != 1 {
            return Err(ReaderError::InvalidSettings);
        }
        let mut trim = row.trim_prefix_ms;
        let exposures = serde_json::from_str::<Vec<JsonObject<ReadingExposure>>>(&row.text)
            .map_err(|_| ReaderError::InvalidSettings)?
            .into_iter()
            .filter_map(|JsonObject(mut exposure)| {
                let clipped = trim.min(exposure.duration_ms);
                trim -= clipped;
                exposure.duration_ms -= clipped;
                (clipped == 0 || exposure.duration_ms > 0).then_some(exposure)
            })
            .collect();
        if trim != 0 {
            return Err(ReaderError::InvalidRange);
        }
        Ok((
            row.session,
            CoverageFact {
                visit_id: row.visit,
                started_ms: row.started_ms,
                ended_ms: row.ended_ms,
                exposures,
            },
        ))
    }))
}

fn dwell_ranges(
    rows: impl IntoIterator<Item = Result<(String, CoverageFact)>>,
) -> Result<Option<Vec<SourceSpan>>> {
    let mut dwell = VisibleDwell::default();
    let mut previous: Option<(String, i64)> = None;
    let mut observed = false;
    for row in rows {
        let (_, fact) = row?;
        if previous
            .as_ref()
            .is_none_or(|(v, at)| *v != fact.visit_id || *at != fact.started_ms)
        {
            dwell.active.clear();
        }
        for exposure in fact.exposures {
            observed = true;
            dwell.observe(exposure.start_utf8, exposure.end_utf8, exposure.duration_ms);
        }
        previous = Some((fact.visit_id, fact.ended_ms));
    }
    Ok(observed.then(|| {
        dwell
            .covered
            .into_iter()
            .map(|(start_utf8, end_utf8)| SourceSpan {
                start_utf8,
                end_utf8,
            })
            .collect()
    }))
}

/// One copy of each endpoint chunk. Endpoints are in ascending order, and
/// can exceed the available prefix (e.g. another device read the full book).
#[derive(uniffi::Record)]
pub struct CoveragePrefixChunk {
    pub start_utf8: u64,
    pub prefix: u64,
    pub text: String,
    pub endpoints: Vec<u64>,
}

#[uniffi::export]
pub fn chapter_coverage_counts(
    chunks: Vec<CoveragePrefixChunk>,
    chapters: Vec<SourceSpan>,
) -> Result<Vec<u64>> {
    let mut prefixes = Vec::new();
    for chunk in chunks {
        let mut cursor = 0;
        let mut count = chunk.prefix;
        for offset in chunk.endpoints {
            let mut end = offset
                .saturating_sub(chunk.start_utf8)
                .min(chunk.text.len() as u64) as usize;
            while !chunk.text.is_char_boundary(end) {
                end -= 1;
            }
            let slice = chunk
                .text
                .get(cursor..end)
                .ok_or(ReaderError::InvalidRange)?;
            count += count_text_scalars(slice);
            cursor = end;
            prefixes.push(count);
        }
    }
    let (pairs, remainder) = prefixes.as_chunks::<2>();
    if !remainder.is_empty() {
        return Err(ReaderError::InvalidRange);
    }
    Ok(chapters
        .into_iter()
        .map(|chapter| {
            let first = pairs.partition_point(|&[_, b]| b <= chapter.start_utf8);
            pairs[first..]
                .iter()
                .take_while(|&&[a, _]| a < chapter.end_utf8)
                .map(|&[a, b]| {
                    b.min(chapter.end_utf8)
                        .saturating_sub(a.max(chapter.start_utf8))
                })
                .sum()
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exposure(session: &str, start: i64, end: i64, trim: u64) -> CoverageExposureText {
        CoverageExposureText {
            session: session.into(),
            visit: "same-visit".into(),
            started_ms: start + trim as i64,
            ended_ms: end,
            version: 1,
            trim_prefix_ms: trim,
            text: format!(
                r#"[{{"start_utf8":0,"end_utf8":9,"duration_ms":{}}}]"#,
                end - start
            ),
        }
    }

    #[test]
    fn coverage_text_preserves_no_evidence_zero_and_continuous_dwell_after_clear() {
        let mut empty = exposure("one", 0, 2000, 0);
        empty.text = "[]".into();
        assert!(visible_dwell_from_text(vec![empty]).unwrap().is_none());
        let short = visible_dwell_from_text(vec![exposure("one", 0, 4000, 1100)])
            .unwrap()
            .unwrap();
        assert!(
            short.is_empty(),
            "cleared prefix cannot qualify the segment"
        );
        for (session, next, expected) in [("one", 4000, 1), ("two", 4000, 1), ("one", 4001, 0)] {
            let ranges = visible_dwell_from_text(vec![
                exposure("one", 0, 4000, 1100),
                exposure(session, next, next + 100, 0),
            ])
            .unwrap()
            .unwrap();
            assert_eq!(ranges.len(), expected);
        }
        let mut future = exposure("one", 0, 5000, 0);
        future.version = 2;
        assert!(visible_dwell_from_text(vec![future]).is_err());
    }

    #[test]
    fn coverage_counts_snap_scalars_and_skip_heading_and_whitespace() {
        let chunks = vec![
            CoveragePrefixChunk {
                start_utf8: 0,
                prefix: 0,
                text: "甲 \t乙\n".into(),
                endpoints: vec![1, 9],
            },
            CoveragePrefixChunk {
                start_utf8: 9,
                prefix: 2,
                text: "🙂丙\u{00a0}丁".into(),
                endpoints: vec![11, 100],
            },
        ];
        let bounds = vec![
            SourceSpan {
                start_utf8: 1,
                end_utf8: 3,
            },
            SourceSpan {
                start_utf8: 3,
                end_utf8: 5,
            },
        ];
        assert_eq!(chapter_coverage_counts(chunks, bounds).unwrap(), vec![2, 2]);
    }

    #[test]
    fn slow_scroll_extends_overlap_without_qualifying_new_text() {
        let mut v = VisibleDwell::default();
        v.observe(0, 100, 1000);
        v.observe(20, 120, 1000);
        v.observe(40, 140, 1000);
        assert_eq!(v.covered, BTreeMap::from([(40, 100)]));
        v.observe(200, 300, 1000);
        v.observe(40, 140, 1000);
        assert_eq!(v.covered, BTreeMap::from([(40, 100)]));
        let mut separate = VisibleDwell::default();
        separate.observe(0, 100, 1000);
        separate.observe(200, 300, 1000);
        assert!(
            separate.covered.is_empty(),
            "separate quick passes must not accumulate"
        );
        separate.observe(200, 300, 2000);
        assert_eq!(separate.covered, BTreeMap::from([(200, 300)]));
    }
}
