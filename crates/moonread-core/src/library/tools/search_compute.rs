//! Bounded text search driven by explicit UTF-8 ranges; no index or task owner.
use crate::reading::compute::StepState;
use crate::*;
use regex::{Match, Regex, RegexBuilder};
use std::sync::Arc;

pub(super) const MAX_INPUT: usize = 256 * 1024;
const MAX_LINE: usize = 1024 * 1024;
pub(super) const MAX_HITS: usize = 50;

#[derive(uniffi::Object)]
pub struct SearchScanState(StepState<SearchScan>);

#[derive(uniffi::Record)]
pub struct SearchScanStep {
    pub next: Option<Arc<SearchScanState>>,
    pub batch: SearchBatch,
    /// A bounded byte window. The caller may pass a shorter valid UTF-8
    /// slice beginning here, for example the remainder of an indexed chunk.
    pub requested: Option<SearchRange>,
}

pub(super) struct SearchScan {
    matcher: Regex,
    headings: Vec<ChapterInfo>,
    limit: u64,
    partial: bool,
    offset: u64,
    line_start: u64,
    line: String,
    input: String,
    input_at: usize,
    scan: Option<Matches>,
    done: bool,
    literal_overlap: Option<usize>,
    skipped_long_line: bool,
    skipping_line: bool,
    emitted_until: u64,
}

struct Matches {
    before: usize,
    resume: usize,
    has_previous: bool,
    after: AfterMatches,
}

enum AfterMatches {
    Line,
    Limit,
    Drain { bytes: usize, ends_line: bool },
}

impl SearchScan {
    pub(super) fn new(
        query: String,
        regular_expression: bool,
        case_sensitive: bool,
        start: u64,
        end: u64,
        partial: bool,
        headings: Vec<ChapterInfo>,
    ) -> Result<Self> {
        if start > end || end > i64::MAX as u64 {
            return Err(ReaderError::InvalidRange);
        }
        if query.is_empty() || query.contains('\n') {
            return Err(ReaderError::SearchPattern {
                message: "Enter a nonempty single-line query.".into(),
            });
        }
        // The literal's case folding/excerpt can cross a split in a long line.
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
        Ok(Self {
            matcher,
            headings,
            limit: end,
            partial,
            offset: start,
            line_start: start,
            line: String::new(),
            input: String::new(),
            input_at: 0,
            scan: None,
            done: false,
            literal_overlap,
            skipped_long_line: false,
            skipping_line: false,
            emitted_until: start,
        })
    }

    pub(super) fn requested(&self) -> Option<SearchRange> {
        (!self.done
            && self.scan.is_none()
            && self.input_at == self.input.len()
            && self.offset < self.limit)
            .then(|| SearchRange {
                start_utf8: self.offset,
                end_utf8: self.limit.min(self.offset + MAX_INPUT as u64),
            })
    }

    pub(super) fn offer(&mut self, input: TextRange) -> Result<()> {
        let request = self.requested().ok_or(ReaderError::InvalidRange)?;
        if input.text.is_empty()
            || input.start_utf8 != request.start_utf8
            || input.end_utf8 > request.end_utf8
            || input.start_utf8.checked_add(input.text.len() as u64) != Some(input.end_utf8)
        {
            return Err(ReaderError::InvalidRange);
        }
        self.input = input.text;
        self.input_at = 0;
        Ok(())
    }

    fn begin_matches(&mut self, before: usize, after: AfterMatches) {
        self.scan = Some(Matches {
            before,
            resume: 0,
            has_previous: false,
            after,
        });
    }

    fn take_matches(&mut self, output: &mut Vec<SearchHit>, cancelled: &impl Fn() -> bool) {
        let Some(mut scan) = self.scan.take() else {
            return;
        };
        while output.len() < MAX_HITS && !cancelled() {
            let Some(found) = scan.find(&self.matcher, &self.line) else {
                break;
            };
            if found.start() >= scan.before {
                break;
            }
            let start = self.line_start + found.start() as u64;
            if found.is_empty() || start < self.emitted_until {
                continue;
            }
            let end = self.line_start + found.end() as u64;
            self.emitted_until = end;
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
            output.push(SearchHit {
                start_utf8: start,
                end_utf8: end,
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
        if output.len() == MAX_HITS || cancelled() {
            self.scan = Some(scan);
            return;
        }
        match scan.after {
            AfterMatches::Line => {
                self.line.clear();
                self.line_start = self.offset;
            }
            AfterMatches::Limit => {
                self.line.clear();
                self.done = true;
            }
            AfterMatches::Drain { bytes, ends_line } => {
                self.line.drain(..bytes);
                self.line_start += bytes as u64;
                if ends_line {
                    self.line.pop();
                    self.begin_matches(self.line.len(), AfterMatches::Line);
                }
            }
        }
    }

    pub(super) fn collect(&mut self, output: &mut Vec<SearchHit>, cancelled: &impl Fn() -> bool) {
        while output.len() < MAX_HITS && !self.done && !cancelled() {
            if self.scan.is_some() {
                self.take_matches(output, cancelled);
                continue;
            }
            if self.input_at == self.input.len() {
                self.input = String::new();
                self.input_at = 0;
                if self.offset == self.limit {
                    self.begin_matches(self.line.len(), AfterMatches::Limit);
                    continue;
                }
                return;
            }
            let left = &self.input[self.input_at..];
            let next = left.find('\n').map_or(left.len(), |i| i + 1);
            let piece = &left[..next];
            let ends_line = piece.ends_with('\n');
            self.input_at += next;
            self.offset += next as u64;
            if self.skipping_line {
                if ends_line {
                    self.skipping_line = false;
                }
                self.line_start = self.offset;
                continue;
            }
            self.line.push_str(piece);
            if self.line.len() > MAX_LINE {
                if let Some(overlap) = self.literal_overlap {
                    let mut cut = self.line.len().saturating_sub(overlap);
                    while !self.line.is_char_boundary(cut) {
                        cut -= 1;
                    }
                    self.begin_matches(
                        cut,
                        AfterMatches::Drain {
                            bytes: cut,
                            ends_line,
                        },
                    );
                } else {
                    // Arbitrary regex may depend on the entire line. Keep
                    // the existing truncated result instead of making up matches.
                    self.skipped_long_line = true;
                    self.skipping_line = !ends_line;
                    self.line.clear();
                    self.line_start = self.offset;
                }
            } else if ends_line {
                self.line.pop();
                self.begin_matches(self.line.len(), AfterMatches::Line);
            }
        }
    }

    pub(super) fn batch(&self, hits: Vec<SearchHit>, cancelled: bool) -> SearchBatch {
        SearchBatch {
            hits,
            done: self.done,
            cancelled,
            truncated: self.skipped_long_line,
            partial_book: self.partial,
            scanned_utf8: self.offset,
            available_utf8: self.limit,
        }
    }
}

impl Matches {
    /// Same non-overlapping iteration as regex::find_iter. Save the position
    /// instead of borrowing the line through the across-call state. Empty
    /// matches adjacent to the previous match are not emitted.
    fn find<'a>(&mut self, matcher: &Regex, line: &'a str) -> Option<Match<'a>> {
        let mut found = matcher.find_at(line, self.resume)?;
        if found.is_empty() && self.has_previous && found.end() == self.resume {
            if self.resume == line.len() {
                return None;
            }
            found = matcher.find_at(line, self.resume + 1)?;
        }
        self.resume = found.end();
        self.has_previous = true;
        Some(found)
    }
}

#[uniffi::export]
pub fn begin_search_scan(
    query: String,
    regular_expression: bool,
    case_sensitive: bool,
    range: SearchRange,
    partial_book: bool,
    headings: Vec<ChapterInfo>,
) -> Result<Arc<SearchScanState>> {
    if headings
        .windows(2)
        .any(|w| w[0].start_utf8 >= w[1].start_utf8)
    {
        return Err(ReaderError::InvalidRange);
    }
    let scan = SearchScan::new(
        query,
        regular_expression,
        case_sensitive,
        range.start_utf8,
        range.end_utf8,
        partial_book,
        headings,
    )?;
    Ok(Arc::new(SearchScanState(StepState::new(scan))))
}

/// Consume the old state, optionally offer the next contiguous UTF-8 range,
/// and drain up to 50 hits. Pass nil to drive results already buffered.
#[uniffi::export]
pub fn advance_search_scan(
    previous: Arc<SearchScanState>,
    input: Option<TextRange>,
) -> Result<SearchScanStep> {
    let mut scan = previous.0.take()?;
    if let Some(input) = input {
        scan.offer(input)?;
    }
    let mut hits = Vec::new();
    scan.collect(&mut hits, &|| false);
    let requested = scan.requested();
    let batch = scan.batch(hits, false);
    let next = (!scan.done).then(|| Arc::new(SearchScanState(StepState::new(scan))));
    Ok(SearchScanStep {
        next,
        batch,
        requested,
    })
}

#[cfg(test)]
mod compute_tests {
    use super::*;

    fn search(
        needle: &str,
        regex: bool,
        input: &str,
        per_feed: usize,
    ) -> Result<(Vec<SearchHit>, bool)> {
        let mut state = begin_search_scan(
            needle.into(),
            regex,
            true,
            SearchRange {
                start_utf8: 0,
                end_utf8: input.len() as u64,
            },
            true,
            vec![ChapterInfo {
                title: "fixture".into(),
                start_utf8: 0,
                level: 1,
            }],
        )?;
        let mut offered = None;
        let mut all = Vec::new();
        loop {
            let result = advance_search_scan(state, offered.take())?;
            assert!(result.batch.hits.len() <= MAX_HITS && result.batch.partial_book);
            all.extend(result.batch.hits);
            if let Some(request) = result.requested {
                let start = request.start_utf8 as usize;
                let mut end = (request.end_utf8 as usize).min(start + per_feed);
                while !input.is_char_boundary(end) {
                    end -= 1;
                }
                assert!(end > start);
                offered = Some(TextRange {
                    start_utf8: start as u64,
                    end_utf8: end as u64,
                    text: input[start..end].into(),
                });
            }
            if let Some(next) = result.next {
                state = next;
            } else {
                assert!(result.batch.done);
                return Ok((all, result.batch.truncated));
            }
        }
    }

    #[test]
    fn explicit_search_drains_dense_matches_without_missing_utf8_or_empty_boundaries() -> Result<()>
    {
        let input = format!("{}\n", "汉ab😺".repeat(135));
        let query = r"(?:ab|[😺])|(?:)";
        let pattern = Regex::new(query).unwrap();
        let direct: Vec<_> = pattern
            .find_iter(input.trim_end_matches('\n'))
            .filter(|m| !m.is_empty())
            .map(|m| (m.start() as u64, m.end() as u64))
            .collect();
        let (hits, truncated) = search(query, true, &input, 13)?;
        assert!(!truncated && hits.len() > 50);
        assert_eq!(
            hits.iter()
                .map(|h| (h.start_utf8, h.end_utf8))
                .collect::<Vec<_>>(),
            direct
        );
        assert!(hits.iter().all(|h| h.chapter.as_deref() == Some("fixture")
            && h.excerpt.is_char_boundary(h.highlight_start as usize)
            && h.excerpt.is_char_boundary(h.highlight_end as usize)));
        Ok(())
    }

    #[test]
    fn explicit_long_line_search_preserves_literal_and_regex_rules() -> Result<()> {
        let input = format!("{}target\ntarget\n", "x".repeat(MAX_LINE + 30));
        let (literal, truncated) = search("target", false, &input, 12345)?;
        assert_eq!(literal.len(), 2);
        assert_eq!(literal[0].start_utf8, (MAX_LINE + 30) as u64);
        assert!(!truncated);
        let (regex, truncated) = search("target$", true, &input, 12345)?;
        assert_eq!(regex.len(), 1);
        assert_eq!(regex[0].start_utf8, (MAX_LINE + 37) as u64);
        assert!(truncated);
        let state = begin_search_scan(
            "a".into(),
            false,
            true,
            SearchRange {
                start_utf8: 10,
                end_utf8: 20,
            },
            false,
            vec![],
        )?;
        assert!(
            advance_search_scan(
                state.clone(),
                Some(TextRange {
                    start_utf8: 11,
                    end_utf8: 12,
                    text: "a".into()
                })
            )
            .is_err()
        );
        assert!(advance_search_scan(state, None).is_err());
        Ok(())
    }
}
