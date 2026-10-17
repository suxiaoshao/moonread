//! Continuous visible-text dwell, independently of duration totals and layout pages.
use crate::*;
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

/// One query for the entire outline. Returning None distinguishes missing evidence from zero.
pub(crate) fn covered_char_ranges(db: &Connection, id: &str) -> Result<Option<Vec<(u64, u64)>>> {
    let mut q = db.prepare("SELECT visit_id,started_ms,ended_ms,exposures FROM reading_activity WHERE book_id=?1 AND deleted=0 ORDER BY session_id,visit_id,started_ms,id")?;
    let mut dwell = VisibleDwell::default();
    let mut previous: Option<(String, i64)> = None;
    let mut observed = false;
    for row in q.query_map([id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, String>(3)?,
        ))
    })? {
        let (visit, start, end, json) = row?;
        if previous
            .as_ref()
            .is_none_or(|(v, at)| *v != visit || *at != start)
        {
            dwell.active.clear();
        }
        let exposures: Vec<ReadingExposure> =
            serde_json::from_str(&json).map_err(|_| ReaderError::InvalidSettings)?;
        for e in exposures {
            observed = true;
            dwell.observe(e.start_utf8, e.end_utf8, e.duration_ms);
        }
        previous = Some((visit, end));
    }
    if !observed {
        return Ok(None);
    }
    dwell
        .covered
        .into_iter()
        .map(|(a, b)| Ok((character_prefix(db, id, a)?, character_prefix(db, id, b)?)))
        .collect::<Result<Vec<_>>>()
        .map(Some)
}

fn character_prefix(db: &Connection, id: &str, offset: u64) -> Result<u64> {
    let row: Option<(u64,u64,String)> = db.query_row("SELECT start_utf8,start_char_count,text FROM chunks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY chunk_index DESC LIMIT 1", params![id,offset.min(i64::MAX as u64) as i64], |r| Ok((unsigned_column(r,0)?,unsigned_column(r,1)?,r.get(2)?))).optional()?;
    let Some((start, count, text)) = row else {
        return Ok(0);
    };
    let mut length = (offset - start).min(text.len() as u64) as usize;
    while !text.is_char_boundary(length) {
        length -= 1;
    }
    Ok(count
        + text[..length]
            .chars()
            .filter(|c| !c.is_whitespace())
            .count() as u64)
}

pub(crate) fn count(ranges: &[(u64, u64)], start: u64, end: u64) -> u64 {
    let first = ranges.partition_point(|&(_, b)| b <= start);
    ranges[first..]
        .iter()
        .take_while(|&&(a, _)| a < end)
        .map(|&(a, b)| b.min(end).saturating_sub(a.max(start)))
        .sum()
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
    }
    #[test]
    fn scrolling_must_not_accumulate_separate_quick_passes() {
        let mut v = VisibleDwell::default();
        for _ in 0..4 {
            v.observe(0, 100, 1000);
            v.observe(200, 300, 1000);
        }
        assert!(v.covered.is_empty());
        v.observe(200, 300, 2000);
        assert_eq!(v.covered, BTreeMap::from([(200, 300)]));
    }
}
