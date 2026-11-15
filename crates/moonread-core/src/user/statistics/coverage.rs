//! Continuous dwell calculation over facts supplied in visit/time order by Swift.
use crate::{ReadingExposure, SourceSpan};
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
    let mut dwell = VisibleDwell::default();
    let mut previous: Option<(String, i64)> = None;
    let mut observed = false;
    for fact in facts {
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
    observed.then(|| {
        dwell
            .covered
            .into_iter()
            .map(|(start_utf8, end_utf8)| SourceSpan {
                start_utf8,
                end_utf8,
            })
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
