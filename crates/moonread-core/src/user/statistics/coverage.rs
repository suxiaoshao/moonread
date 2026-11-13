//! Continuous visible-text dwell, independently of duration totals and layout pages.
use crate::user::projection::ExposureSlot;
use crate::*;
use rusqlite::Connection;
use rusqlite::params;
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
pub(crate) fn covered_char_ranges(
    db: &Connection,
    id: &str,
    exposures: &[Option<ExposureSlot>],
) -> Result<Option<Vec<(u64, u64)>>> {
    let mut q = db.prepare("SELECT visit_id,started_ms,ended_ms,exposure_slot FROM reading_activity WHERE book_id=?1 AND deleted=0 ORDER BY session_id,visit_id,started_ms,id")?;
    let mut dwell = VisibleDwell::default();
    let mut previous: Option<(String, i64)> = None;
    let mut observed = false;
    for row in q.query_map([id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, i64>(2)?,
            r.get::<_, Option<i64>>(3)?,
        ))
    })? {
        let (visit, start, end, slot) = row?;
        if previous
            .as_ref()
            .is_none_or(|(v, at)| *v != visit || *at != start)
        {
            dwell.active.clear();
        }
        if let Some(slot) = slot {
            let values = usize::try_from(slot)
                .ok()
                .and_then(|slot| exposures.get(slot))
                .and_then(Option::as_ref)
                .ok_or_else(|| ReaderError::Storage {
                    message: "Invalid reading exposure slot".into(),
                })?;
            for e in values.values() {
                observed = true;
                dwell.observe(e.start_utf8, e.end_utf8, e.duration_ms);
            }
        }
        previous = Some((visit, end));
    }
    if !observed {
        return Ok(None);
    }
    let endpoints: Vec<_> = dwell
        .covered
        .into_iter()
        .flat_map(|(a, b)| [a, b])
        .collect();
    let prefixes = character_prefixes(db, id, &endpoints)?;
    Ok(Some(
        prefixes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|p| (p[0], p[1]))
            .collect(),
    ))
}

/// Map all coverage endpoints together. Read chunk headers once and scan each
/// selected chunk's text once, rather than querying/scanning a prefix per point.
fn character_prefixes(db: &Connection, id: &str, offsets: &[u64]) -> Result<Vec<u64>> {
    let mut points: Vec<_> = offsets.iter().copied().enumerate().collect();
    points.sort_unstable_by_key(|&(_, offset)| offset);
    let Some(&(_, maximum)) = points.last() else {
        return Ok(Vec::new());
    };
    let mut headers = db.prepare("SELECT chunk_index,start_utf8,start_char_count FROM chunks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8,chunk_index")?;
    let mut rows = headers.query(params![id, maximum.min(i64::MAX as u64) as i64])?;
    let mut next = || -> Result<Option<(u64, u64, u64)>> {
        rows.next()?
            .map(|r| {
                Ok((
                    unsigned_column(r, 0)?,
                    unsigned_column(r, 1)?,
                    unsigned_column(r, 2)?,
                ))
            })
            .transpose()
    };
    let mut header = next()?;
    let mut selected: Option<(u64, u64, u64)> = None;
    let mut loaded = None;
    let mut text = String::new();
    let mut cursor = 0;
    let mut count = 0;
    let mut read_text =
        db.prepare("SELECT text FROM chunks WHERE book_id=?1 AND chunk_index=?2")?;
    let mut result = vec![0; offsets.len()];
    for (index, offset) in points {
        let eligible = offset.min(i64::MAX as u64);
        while let Some(value) = header.filter(|&(_, start, _)| start <= eligible) {
            // Preserve the original ORDER BY chunk_index DESC rule, including
            // empty chunks sharing an offset with the following chunk.
            if selected.is_none_or(|current| value.0 > current.0) {
                selected = Some(value);
            }
            header = next()?;
        }
        let Some((chunk, start, prefix)) = selected else {
            continue;
        };
        if loaded != Some(chunk) {
            text = read_text.query_row(params![id, chunk as i64], |r| r.get(0))?;
            loaded = Some(chunk);
            cursor = 0;
            count = prefix;
        }
        let mut end = (offset - start).min(text.len() as u64) as usize;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        count += text[cursor..end]
            .chars()
            .filter(|c| !c.is_whitespace())
            .count() as u64;
        cursor = end;
        result[index] = count;
    }
    Ok(result)
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
    fn batched_prefixes_and_chapter_counts_match_point_mapping() {
        use rusqlite::OptionalExtension;
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE chunks(book_id TEXT,chunk_index INTEGER,start_utf8 INTEGER,start_char_count INTEGER,text TEXT); CREATE INDEX chunk_offset ON chunks(book_id,start_utf8);").unwrap();
        let chunks = [
            (0, 0, "甲 \t乙\n"),
            (9, 2, ""),
            (9, 2, "🙂丙\u{a0}丁"),
            (21, 5, "　戊\n"),
            (28, 6, ""),
        ];
        for (index, (start, count, text)) in chunks.into_iter().enumerate() {
            db.execute(
                "INSERT INTO chunks VALUES('book',?1,?2,?3,?4)",
                params![index as i64, start, count, text],
            )
            .unwrap();
        }
        // The pre-optimization point query is retained only as a test oracle.
        let point = |id: &str, offset: u64| -> u64 {
            let row: Option<(u64,u64,String)> = db.query_row("SELECT start_utf8,start_char_count,text FROM chunks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY chunk_index DESC LIMIT 1", params![id,offset.min(i64::MAX as u64) as i64], |r| Ok((unsigned_column(r,0)?,unsigned_column(r,1)?,r.get(2)?))).optional().unwrap();
            row.map_or(0, |(start, count, text)| {
                let mut end = (offset - start).min(text.len() as u64) as usize;
                while !text.is_char_boundary(end) {
                    end -= 1;
                }
                count + text[..end].chars().filter(|c| !c.is_whitespace()).count() as u64
            })
        };
        let mut points: Vec<_> = (0..=35).rev().collect();
        points.extend([0, 9, 9, 28, u64::MAX]);
        let mapped = character_prefixes(&db, "book", &points).unwrap();
        assert_eq!(
            mapped,
            points
                .iter()
                .map(|&offset| point("book", offset))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            character_prefixes(&db, "missing", &points).unwrap(),
            vec![0; points.len()]
        );
        assert!(character_prefixes(&db, "book", &[]).unwrap().is_empty());
        assert_eq!(
            character_prefixes(&db, "book", &[0, 3, 5, 9, 13, 16, 18, 21, 24, 27, 28]).unwrap(),
            vec![0, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6]
        );
        let mut dwell = VisibleDwell::default();
        for (start, end) in [(0, 9), (3, 16), (18, 21), (24, 28)] {
            dwell.observe(start, end, 3_000);
        }
        let endpoints: Vec<_> = dwell
            .covered
            .into_iter()
            .flat_map(|(a, b)| [a, b])
            .collect();
        let old: Vec<_> = endpoints
            .as_chunks::<2>()
            .0
            .iter()
            .map(|p| (point("book", p[0]), point("book", p[1])))
            .collect();
        let prefixes = character_prefixes(&db, "book", &endpoints).unwrap();
        let new: Vec<_> = prefixes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|p| (p[0], p[1]))
            .collect();
        for start in 0..=6 {
            for end in start..=6 {
                assert_eq!(count(&new, start, end), count(&old, start, end));
            }
        }
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
