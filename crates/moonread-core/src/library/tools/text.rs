use super::content_key;
use crate::*;
use rusqlite::{Connection, params};

fn range_text(db: &Connection, id: &str, start: u64, end: u64) -> Result<String> {
    if start > end || end - start > 1024 * 1024 || end > book(db, id)?.byte_count {
        return Err(ReaderError::InvalidRange);
    }
    let mut stmt = db.prepare("SELECT start_utf8,text FROM chunks WHERE book_id=?1 AND end_utf8>?2 AND start_utf8<?3 ORDER BY chunk_index")?;
    let mut text = String::new();
    for row in stmt.query_map(params![id, start as i64, end as i64], |r| {
        Ok((unsigned_column(r, 0)?, r.get::<_, String>(1)?))
    })? {
        let (base, chunk) = row?;
        let from = start.saturating_sub(base) as usize;
        let to = ((end - base) as usize).min(chunk.len());
        text.push_str(chunk.get(from..to).ok_or(ReaderError::InvalidRange)?);
    }
    if text.len() as u64 != end - start {
        return Err(ReaderError::InvalidRange);
    }
    Ok(text)
}

#[uniffi::export]
impl ReaderCore {
    /// The reader's display projection for an original selection envelope.
    /// Retained paragraph separators (LF) stay intact; only confirmed semantic
    /// blank runs and smart body-indent prefixes are omitted. Read retained spans,
    /// never concatenate a UI window.
    pub fn display_text_range(
        &self,
        book_id: String,
        start_utf8: u64,
        end_utf8: u64,
        indent: ReadingIndent,
    ) -> Result<TextRange> {
        let mut db = self.read_lock()?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let size = book(&tx, &id)?.byte_count;
        if start_utf8 > end_utf8 || end_utf8 > size {
            return Err(ReaderError::InvalidRange);
        }
        let confirmed: u64 =
            tx.query_row("SELECT projection_end FROM books WHERE id=?1", [&id], |r| {
                unsigned_column(r, 0)
            })?;
        if end_utf8 > confirmed {
            // A native selection cannot include the unresolved suffix. Other
            // callers must wait for the same semantic snapshot as the viewport.
            return Err(ReaderError::ImportBusy);
        }
        for offset in [start_utf8, end_utf8] {
            if offset < size {
                let value = chunk(&tx, &id, chunk_index(&tx, &id, offset)?)?;
                if !value
                    .text
                    .is_char_boundary((offset - value.start_utf8) as usize)
                {
                    return Err(ReaderError::InvalidRange);
                }
            }
        }
        let mut blanks = crate::reading::layout::blank_ranges(&tx, &id, start_utf8, end_utf8)?;
        if indent == ReadingIndent::Smart && start_utf8 < end_utf8 {
            // Preserve the existing 1 MiB retained-selection budget before
            // loading context (confirmed blank runs do not consume it).
            let retained = blanks
                .iter()
                .fold(end_utf8 - start_utf8, |left, &(lo, hi)| {
                    left.saturating_sub(hi.min(end_utf8).saturating_sub(lo.max(start_utf8)))
                });
            if retained > 1024 * 1024 {
                return Err(ReaderError::InvalidRange);
            }

            // Skip whole confirmed blank chunks, as the display window does.
            let mut stmt = tx.prepare("SELECT chunk_index,start_utf8,end_utf8,text FROM chunks c WHERE book_id=?1 AND end_utf8>?2 AND start_utf8<?3 AND COALESCE((SELECT b.end_utf8 FROM reading_blanks b WHERE b.book_id=c.book_id AND b.start_utf8<=c.start_utf8 ORDER BY b.start_utf8 DESC LIMIT 1),-1)<c.end_utf8 ORDER BY chunk_index")?;
            let mut chunks = stmt
                .query_map(params![id, start_utf8 as i64, end_utf8 as i64], |r| {
                    Ok(TextChunk {
                        index: r.get(0)?,
                        start_utf8: unsigned_column(r, 1)?,
                        end_utf8: unsigned_column(r, 2)?,
                        text: r.get(3)?,
                    })
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            if let Some(first) = chunks.first() {
                let before = &first.text[..start_utf8.saturating_sub(first.start_utf8) as usize];
                if before
                    .chars()
                    .all(crate::reading::layout::horizontal_indent)
                    && crate::reading::layout::blank_ranges(
                        &tx,
                        &id,
                        first.start_utf8,
                        first.start_utf8 + 1,
                    )?
                    .is_empty()
                {
                    let mut context = Vec::new();
                    let mut index = first.index;
                    // A remote paragraph head is not needed for a continuation.
                    // Keep context bounded; unresolved heads retain their bytes.
                    let mut budget: usize = 1024 * 1024;
                    while index > 0 && budget > 0 {
                        index -= 1;
                        let value = chunk(&tx, &id, index)?;
                        budget = budget.saturating_sub(value.text.len());
                        let boundary = value
                            .text
                            .chars()
                            .any(|c| !crate::reading::layout::horizontal_indent(c));
                        context.push(value);
                        if boundary {
                            break;
                        }
                    }
                    context.reverse();
                    context.append(&mut chunks);
                    chunks = context;
                }
            }
            let mut from = 0;
            while from < chunks.len() {
                let mut to = from + 1;
                while to < chunks.len() && chunks[to - 1].end_utf8 == chunks[to].start_utf8 {
                    to += 1;
                }
                let group = &chunks[from..to];
                let semantics = crate::reading::layout::paragraphs(&tx, &id, group)?;
                blanks.extend(
                    crate::reading::layout::indent_omissions(group, &semantics, indent)
                        .into_iter()
                        .map(|r| (r.start_utf8, r.end_utf8)),
                );
                from = to;
            }
            blanks.sort_unstable();
        }
        let mut cursor = start_utf8;
        let mut text = String::new();
        for (lo, hi) in blanks
            .into_iter()
            .chain(std::iter::once((end_utf8, end_utf8)))
        {
            let end = lo.max(cursor).min(end_utf8);
            if end - cursor > 1024 * 1024 - text.len() as u64 {
                return Err(ReaderError::InvalidRange);
            }
            if cursor < end {
                text.push_str(&range_text(&tx, &id, cursor, end)?);
            }
            cursor = hi.max(cursor).min(end_utf8);
        }
        Ok(TextRange {
            start_utf8,
            end_utf8,
            text,
        })
    }

    pub fn text_range(&self, book_id: String, start_utf8: u64, end_utf8: u64) -> Result<TextRange> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        Ok(TextRange {
            start_utf8,
            end_utf8,
            text: range_text(&tx, &id, start_utf8, end_utf8)?,
        })
    }

    /// Read the containing paragraph plus neighboring non-empty paragraphs.
    /// All offsets refer to normalized UTF-8, and traversal stays bounded.
    pub fn text_context(
        &self,
        book_id: String,
        offset_utf8: u64,
        before_paragraphs: u32,
        after_paragraphs: u32,
    ) -> Result<TextRange> {
        if before_paragraphs > 20 || after_paragraphs > 20 {
            return Err(ReaderError::InvalidRange);
        }
        let size = {
            let db = self.read_lock()?;
            book(&db, &content_key(&db, &book_id)?)?.byte_count
        };
        if offset_utf8 >= size {
            return Err(ReaderError::InvalidRange);
        }
        let anchor = self.paragraph_range(book_id.clone(), offset_utf8)?;
        let mut start = anchor.start_utf8;
        let mut end = anchor.end_utf8;
        for (forward, count) in [(false, before_paragraphs), (true, after_paragraphs)] {
            let mut remaining = count;
            while remaining > 0 {
                let point = if forward {
                    if end + 1 >= size {
                        break;
                    }
                    end + 1
                } else {
                    if start == 0 {
                        break;
                    }
                    start - 1 // the preceding newline is always one ASCII byte
                };
                let paragraph = self.paragraph_range(book_id.clone(), point)?;
                if forward {
                    end = paragraph.end_utf8;
                } else {
                    start = paragraph.start_utf8;
                }
                if end - start > 1024 * 1024 {
                    return Err(ReaderError::InvalidRange);
                }
                if !paragraph.text.trim().is_empty() {
                    remaining -= 1;
                }
            }
        }
        self.text_range(book_id, start, end)
    }

    pub fn paragraph_range(&self, book_id: String, offset_utf8: u64) -> Result<TextRange> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let size = book(&tx, &id)?.byte_count;
        if size == 0 {
            return Err(ReaderError::EmptyBook);
        }
        let point = offset_utf8.min(size - 1);
        let index = chunk_index(&tx, &id, point)?;
        let current = chunk(&tx, &id, index)?;
        let local = (point - current.start_utf8) as usize;
        if !current.text.is_char_boundary(local) {
            return Err(ReaderError::InvalidRange);
        }
        let mut start = current.start_utf8;
        let mut end = current.end_utf8;
        let mut text = current.text;
        let mut before = index;
        let mut after = index + 1;
        while !text[..(point - start) as usize].contains('\n') && before > 0 {
            before -= 1;
            let c = chunk(&tx, &id, before)?;
            start = c.start_utf8;
            text = c.text + &text;
            if text.len() > 1024 * 1024 {
                return Err(ReaderError::InvalidRange);
            }
        }
        while !text[(point - start) as usize..].contains('\n') && end < size {
            let c = chunk(&tx, &id, after)?;
            after += 1;
            end = c.end_utf8;
            text.push_str(&c.text);
            if text.len() > 1024 * 1024 {
                return Err(ReaderError::InvalidRange);
            }
        }
        let relative = (point - start) as usize;
        let left = text[..relative].rfind('\n').map_or(0, |p| p + 1);
        let right = text[relative..]
            .find('\n')
            .map_or(text.len(), |p| relative + p);
        Ok(TextRange {
            start_utf8: start + left as u64,
            end_utf8: start + right as u64,
            text: text[left..right].into(),
        })
    }
}
