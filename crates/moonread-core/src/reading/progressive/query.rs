use super::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
fn phase(value: &str) -> ImportPhase {
    match value {
        "preparing" => ImportPhase::Preparing,
        "importing" => ImportPhase::Importing,
        "finalizing" => ImportPhase::Finalizing,
        "complete" => ImportPhase::Complete,
        "failed" => ImportPhase::Failed,
        _ => ImportPhase::Paused,
    }
}

pub(crate) fn snapshot(db: &Connection, id: &str) -> Result<ReadingSnapshot> {
    let mut value = book(db, id)?;
    let has_started = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM reading_books WHERE last_read>0 AND id IN (?1, COALESCE((SELECT canonical_id FROM import_jobs WHERE book_id=?1),?1)))",
        [id], |r| r.get::<_, bool>(0),
    )?;
    type JobRow = (String, u64, u64, u64, bool, Option<String>, Option<String>);
    let job: Option<JobRow> = db.query_row(
        "SELECT phase,generation,bytes_read,source_size,has_text,error,canonical_id FROM import_jobs WHERE book_id=?1", [id],
        |r| Ok((r.get(0)?, unsigned_column(r,1)?, unsigned_column(r,2)?, unsigned_column(r,3)?, r.get(4)?, r.get(5)?, r.get(6)?))
    ).optional()?;
    let Some((state, generation, read, size, visible, error, canonical)) = job else {
        return Ok(ReadingSnapshot {
            can_read: value.chunk_count > 0,
            has_started,
            book: value,
            phase: ImportPhase::Complete,
            generation: 0,
            source_bytes_read: 0,
            source_byte_count: 0,
            error: None,
        });
    };
    if let Some(canonical) = canonical {
        let existing = book(db, &canonical)?;
        value.position_utf8 = existing.position_utf8;
        value.byte_count = existing.byte_count;
        value.chunk_count = existing.chunk_count;
        value.content_sha256 = existing.content_sha256;
        value.encoding = existing.encoding;
    } else if value.content_sha256.starts_with("pending:") {
        value.content_sha256.clear();
    }
    Ok(ReadingSnapshot {
        book: value,
        phase: phase(&state),
        generation,
        can_read: visible,
        has_started,
        source_bytes_read: read,
        source_byte_count: size,
        error: error
            .map(|json| {
                serde_json::from_str(&json).map_err(|e| ReaderError::Storage {
                    message: e.to_string(),
                })
            })
            .transpose()?,
    })
}

fn content_id(db: &Connection, id: &str) -> Result<String> {
    Ok(db
        .query_row(
            "SELECT canonical_id FROM import_jobs WHERE book_id=?1",
            [id],
            |r| r.get::<_, Option<String>>(0),
        )?
        .unwrap_or_else(|| id.to_owned()))
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn reading_snapshot(&self, book_id: String) -> Result<ReadingSnapshot> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let result = self.runtime_state(snapshot(&tx, &book_id)?);
        tx.commit()?;
        Ok(result)
    }
    pub(crate) fn recent_readings(&self) -> Result<Vec<ReadingSnapshot>> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let ids = {
            let mut stmt = tx.prepare(
                "SELECT b.id FROM reading_books b LEFT JOIN import_jobs j ON b.id=j.book_id
                WHERE j.canonical_id IS NULL
                ORDER BY b.last_read DESC,b.id",
            )?;
            stmt.query_map([], |r| r.get::<_, String>(0))?
                .collect::<std::result::Result<Vec<_>, _>>()?
        };
        let readings = ids
            .iter()
            .map(|id| snapshot(&tx, id).map(|value| self.runtime_state(value)))
            .collect::<Result<_>>()?;
        tx.commit()?;
        Ok(readings)
    }
    /// Metadata, confirmed blank gaps and bounded visible payload share one WAL snapshot.
    pub(crate) fn reading_frame(&self, book_id: String, offset_utf8: u64) -> Result<ReadingFrame> {
        self.reading_frame_request(book_id, offset_utf8, ReadingDirection::Forward, true, None)
    }
    pub(crate) fn reading_frame_extension(
        &self,
        book_id: String,
        cursor: u64,
        direction: ReadingDirection,
        keep: Option<SourceSpan>,
    ) -> Result<ReadingFrame> {
        self.reading_frame_request(book_id, cursor, direction, false, keep)
    }
    fn reading_frame_request(
        &self,
        book_id: String,
        cursor: u64,
        direction: ReadingDirection,
        locate: bool,
        keep: Option<SourceSpan>,
    ) -> Result<ReadingFrame> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let state = self.runtime_state(snapshot(&tx, &book_id)?);
        let id = if state.generation > 0 {
            content_id(&tx, &book_id)?
        } else {
            book_id
        };
        let count = state.book.byte_count;
        let requested = cursor.min(count);
        let gap_at = |offset: u64| -> Result<Option<(u64, u64)>> {
            Ok(tx.query_row("SELECT start_utf8,end_utf8 FROM (SELECT start_utf8,end_utf8 FROM reading_blanks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1) WHERE end_utf8>?2", params![id, offset as i64], |r| Ok((unsigned_column(r,0)?,unsigned_column(r,1)?))).optional()?)
        };
        let confirmed: u64 =
            tx.query_row("SELECT projection_end FROM books WHERE id=?1", [&id], |r| {
                unsigned_column(r, 0)
            })?;
        // Retained whitespace is display data. Only proven blank runs may be
        // skipped; an unresolved trailing suffix is unavailable, not omitted.
        let resolve = |offset: u64, forward: bool| -> Result<Option<u64>> {
            if confirmed == 0 || (forward && offset >= confirmed) {
                return Ok(None);
            }
            let mut point = offset.min(confirmed - 1);
            if let Some((start, end)) = gap_at(point)? {
                if forward {
                    if end >= confirmed {
                        return Ok(None);
                    }
                    point = end;
                } else {
                    let Some(prior) = start.checked_sub(1) else {
                        return Ok(None);
                    };
                    point = prior;
                }
            }
            let value = chunk(&tx, &id, chunk_index(&tx, &id, point)?)?;
            let mut local = (point - value.start_utf8) as usize;
            while !value.text.is_char_boundary(local) {
                if forward {
                    local += 1;
                } else {
                    local -= 1;
                }
            }
            let resolved = value.start_utf8 + local as u64;
            Ok((resolved < confirmed).then_some(resolved))
        };
        let forward = direction == ReadingDirection::Forward;
        let normalized = if locate && requested < count {
            let value = chunk(&tx, &id, chunk_index(&tx, &id, requested)?)?;
            let mut local = (requested - value.start_utf8) as usize;
            while !value.text.is_char_boundary(local) {
                local -= 1;
            }
            value.start_utf8 + local as u64
        } else {
            requested
        };
        let target = if locate && normalized >= confirmed && state.phase != ImportPhase::Complete {
            None
        } else {
            resolve(normalized, forward)?
        };
        let mut status = if target.is_some() {
            ReadingWindowStatus::Ready
        } else if locate && normalized >= confirmed && state.phase != ImportPhase::Complete {
            ReadingWindowStatus::Awaiting
        } else if !forward {
            ReadingWindowStatus::Beginning
        } else if state.phase == ImportPhase::Complete {
            ReadingWindowStatus::End
        } else {
            ReadingWindowStatus::Awaiting
        };
        // At complete EOF locate can restore the last retained scalar, including spaces.
        let mut projection_anchor =
            if locate && target.is_none() && state.phase == ImportPhase::Complete {
                resolve(requested, !forward)?
            } else {
                target
            };
        let neighbor = |offset: u64, forward: bool| -> Result<Option<u64>> {
            if offset >= confirmed {
                return Ok(None);
            }
            if let Some((start, end)) = gap_at(offset)? {
                Ok(if forward {
                    (end < confirmed).then_some(end)
                } else {
                    start.checked_sub(1)
                })
            } else {
                Ok(Some(offset))
            }
        };
        const PAYLOAD_BYTES: u64 = 64 * 1024;
        const MAX_SOURCE_CHUNKS: usize = 256;
        let payload_cost = |index: u32| -> Result<u64> {
            let (a, raw_end): (u64, u64) = tx.query_row(
                "SELECT start_utf8,end_utf8 FROM chunks WHERE book_id=?1 AND chunk_index=?2",
                params![id, index],
                |r| Ok((unsigned_column(r, 0)?, unsigned_column(r, 1)?)),
            )?;
            if a >= confirmed {
                // A protected interval outside confirmed data cannot fit a
                // ready extension; do not underflow a clipped pending chunk.
                return Ok(PAYLOAD_BYTES + 1);
            }
            let b = raw_end.min(confirmed);
            let blank = crate::reading::layout::blank_ranges(&tx, &id, a, b)?
                .iter()
                .map(|(start, end)| end.min(&b) - start.max(&a))
                .sum::<u64>();
            Ok(b - a - blank)
        };
        let self_keep = keep;
        let mut payload_bytes = 0;

        let mut indices = std::collections::BTreeSet::new();
        if let Some(anchor) = projection_anchor {
            let center = chunk_index(&tx, &id, anchor)?;
            if let Some(keep) =
                self_keep.filter(|r| r.start_utf8 < count && r.start_utf8 < r.end_utf8)
            {
                let left = chunk_index(&tx, &id, keep.start_utf8)?.min(center);
                let right =
                    chunk_index(&tx, &id, keep.end_utf8.min(count).saturating_sub(1))?.max(center);
                let mut index = left;
                loop {
                    let cost = payload_cost(index)?;
                    if indices.len() >= MAX_SOURCE_CHUNKS || payload_bytes + cost > PAYLOAD_BYTES {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    }
                    indices.insert(index);
                    payload_bytes += cost;
                    if index == right {
                        break;
                    }
                    let value = chunk(&tx, &id, index)?;
                    let Some(point) = neighbor(value.end_utf8, true)? else {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    };
                    let next = chunk_index(&tx, &id, point)?;
                    if next <= index || next > right {
                        status = ReadingWindowStatus::Deferred;
                        projection_anchor = None;
                        indices.clear();
                        break;
                    }
                    index = next;
                }
            } else {
                indices.insert(center);
                payload_bytes = payload_cost(center)?;
            }
            let center_chunk = chunk(&tx, &id, center)?;
            let mut before = if let Some(first) = indices.first() {
                chunk(&tx, &id, *first)?.start_utf8
            } else {
                center_chunk.start_utf8
            };
            let mut after = if let Some(last) = indices.last() {
                chunk(&tx, &id, *last)?.end_utf8
            } else {
                center_chunk.end_utf8
            };
            // Confirmed gaps cost no retained bytes. The work cap is independent
            // of payload size and comfortably exceeds a native viewport of tiny
            // LF-separated islands; it never scans an arbitrary book synchronously.
            for go_forward in
                std::iter::once(!forward).chain(std::iter::repeat_n(forward, MAX_SOURCE_CHUNKS))
            {
                if status == ReadingWindowStatus::Deferred || indices.len() >= MAX_SOURCE_CHUNKS {
                    break;
                }
                let candidate = if go_forward {
                    if after >= count {
                        None
                    } else {
                        neighbor(after, true)?
                    }
                } else {
                    before
                        .checked_sub(1)
                        .map(|p| neighbor(p, false))
                        .transpose()?
                        .flatten()
                };
                let Some(position) = candidate else {
                    if go_forward == forward {
                        break;
                    } else {
                        continue;
                    }
                };
                let index = chunk_index(&tx, &id, position)?;
                let value = chunk(&tx, &id, index)?;
                before = before.min(value.start_utf8);
                after = after.max(value.end_utf8);
                if !indices.contains(&index) {
                    let cost = payload_cost(index)?;
                    if payload_bytes + cost > PAYLOAD_BYTES {
                        if go_forward == forward {
                            break;
                        } else {
                            continue;
                        }
                    }
                    indices.insert(index);
                    payload_bytes += cost;
                }
            }
        }
        let mut chunks = Vec::new();
        let mut omitted = Vec::new();
        let mut coverage_start = count;
        let mut coverage_end = 0;
        for index in indices {
            let mut value = chunk(&tx, &id, index)?;
            value.end_utf8 = value.end_utf8.min(confirmed);
            value
                .text
                .truncate((value.end_utf8 - value.start_utf8) as usize);
            coverage_start = coverage_start.min(value.start_utf8);
            coverage_end = coverage_end.max(value.end_utf8);
            let gaps =
                crate::reading::layout::blank_ranges(&tx, &id, value.start_utf8, value.end_utf8)?;
            let mut start = value.start_utf8;
            for (a, b) in gaps {
                if a > start {
                    chunks.push(TextChunk {
                        index,
                        start_utf8: start,
                        end_utf8: a,
                        text: value.text
                            [(start - value.start_utf8) as usize..(a - value.start_utf8) as usize]
                            .to_owned(),
                    });
                }
                omitted.push(SourceSpan {
                    start_utf8: a,
                    end_utf8: b,
                });
                start = b.min(value.end_utf8);
            }
            if start < value.end_utf8 {
                chunks.push(TextChunk {
                    index,
                    start_utf8: start,
                    end_utf8: value.end_utf8,
                    text: value.text[(start - value.start_utf8) as usize..].to_owned(),
                });
            }
        }
        if chunks.is_empty() {
            coverage_start = requested.min(confirmed);
            coverage_end = requested.min(confirmed);
        }
        if let Some((start, end)) = gap_at(requested.min(count.saturating_sub(1)))?
            && start <= coverage_end
            && end >= coverage_start
        {
            coverage_start = coverage_start.min(start);
            coverage_end = coverage_end.max(end);
        }
        if coverage_start < coverage_end {
            if let Some((start, _)) = gap_at(coverage_start)? {
                coverage_start = start;
            }
            if let Some((_, end)) = gap_at(coverage_end - 1)? {
                coverage_end = end;
            }
        }
        // Include entire proven gaps between loaded spans without reading their bytes.
        if coverage_start < coverage_end {
            omitted = crate::reading::layout::blank_ranges(&tx, &id, coverage_start, coverage_end)?
                .into_iter()
                .map(|(a, b)| SourceSpan {
                    start_utf8: a,
                    end_utf8: b,
                })
                .collect();
        }
        let mut paragraphs = Vec::new();
        let mut from = 0;
        while from < chunks.len() {
            let mut to = from + 1;
            while to < chunks.len() && chunks[to - 1].end_utf8 == chunks[to].start_utf8 {
                to += 1;
            }
            paragraphs.extend(crate::reading::layout::paragraphs(
                &tx,
                &id,
                &chunks[from..to],
            )?);
            from = to;
        }
        let next_cursor = if chunks.is_empty() {
            None
        } else {
            resolve(coverage_end, true)?
        };
        let previous_cursor = if chunks.is_empty() {
            None
        } else if let Some(position) = coverage_start.checked_sub(1) {
            resolve(position, false)?
        } else {
            None
        };
        let end = state.phase == ImportPhase::Complete
            && (!chunks.is_empty() && next_cursor.is_none() || status == ReadingWindowStatus::End);
        let projection_revision: u64 = tx.query_row(
            "SELECT projection_revision FROM books WHERE id=?1",
            [&id],
            |r| unsigned_column(r, 0),
        )?;
        let has_non_whitespace_payload = chunks
            .iter()
            .any(|c| c.text.chars().any(|c| !c.is_whitespace()));
        let projection_anchor = projection_anchor.filter(|anchor| {
            chunks
                .iter()
                .any(|c| c.start_utf8 <= *anchor && *anchor < c.end_utf8)
        });
        tx.commit()?;
        Ok(ReadingFrame {
            snapshot: state,
            chunks,
            paragraphs,
            is_end_of_book: end,
            omitted,
            source_start: coverage_start,
            source_end: coverage_end,
            cursor: requested,
            projection_anchor,
            has_non_whitespace_payload,
            status,
            next_cursor,
            previous_cursor,
            projection_revision,
        })
    }
}
#[uniffi::export]
impl ReaderCore {
    pub fn import_status(&self, book_id: String) -> Result<ImportStatus> {
        let state = self.reading_snapshot(book_id)?;
        Ok(ImportStatus {
            text: state.book.into(),
            phase: state.phase,
        })
    }
    pub fn import_source_byte_count(&self, book_id: String) -> Result<u64> {
        Ok(self.reading_snapshot(book_id)?.source_byte_count)
    }
}
