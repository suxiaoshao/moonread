use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReaderFont {
    System,
    Serif,
    Rounded,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReadingIndent {
    Original,
    Smart,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReadingOrientation {
    System,
    Portrait,
    Landscape,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ReaderSettings {
    pub mode: ReadingMode,
    pub font_size: f64,
    pub line_spacing: f64,
    pub font: ReaderFont,
    pub paragraph_spacing: f64,
    pub indent: ReadingIndent,
    pub horizontal_margin: f64,
    pub maximum_line_width: f64,
    pub keep_awake: bool,
    /// None leaves the system brightness alone. Values are normalized 0...1.
    pub brightness: Option<f64>,
    pub orientation: ReadingOrientation,
}

/// Shared control metadata; native and web renderers still own font metrics.
#[derive(Clone, Debug, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ReaderNumberControl {
    pub minimum: f64,
    pub maximum: f64,
    pub step: f64,
    pub default_value: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ReaderTypographyControls {
    pub font_size: ReaderNumberControl,
    pub line_spacing: ReaderNumberControl,
    pub paragraph_spacing: ReaderNumberControl,
}

#[uniffi::export]
pub fn reader_typography_controls() -> ReaderTypographyControls {
    ReaderTypographyControls {
        font_size: ReaderNumberControl {
            minimum: 12.0,
            maximum: 48.0,
            step: 1.0,
            default_value: 20.0,
        },
        line_spacing: ReaderNumberControl {
            minimum: 0.0,
            maximum: 32.0,
            step: 2.0,
            default_value: 8.0,
        },
        paragraph_spacing: ReaderNumberControl {
            minimum: 0.0,
            maximum: 32.0,
            step: 1.0,
            default_value: 7.0,
        },
    }
}

#[uniffi::export]
pub fn default_reader_settings() -> ReaderSettings {
    let controls = reader_typography_controls();
    ReaderSettings {
        mode: ReadingMode::Scroll,
        font_size: controls.font_size.default_value,
        line_spacing: controls.line_spacing.default_value,
        font: ReaderFont::System,
        paragraph_spacing: controls.paragraph_spacing.default_value,
        indent: ReadingIndent::Smart,
        horizontal_margin: 16.0,
        maximum_line_width: 680.0,
        keep_awake: false,
        brightness: None,
        orientation: ReadingOrientation::System,
    }
}

pub(super) fn valid(settings: &ReaderSettings) -> bool {
    let controls = reader_typography_controls();
    [
        (
            settings.font_size,
            controls.font_size.minimum,
            controls.font_size.maximum,
        ),
        (
            settings.line_spacing,
            controls.line_spacing.minimum,
            controls.line_spacing.maximum,
        ),
        (
            settings.paragraph_spacing,
            controls.paragraph_spacing.minimum,
            controls.paragraph_spacing.maximum,
        ),
        (settings.horizontal_margin, 12.0, 48.0),
        (settings.maximum_line_width, 320.0, 1200.0),
    ]
    .iter()
    .all(|&(value, min, max)| value.is_finite() && (min..=max).contains(&value))
        && settings
            .brightness
            .is_none_or(|v| v.is_finite() && (0.0..=1.0).contains(&v))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ParagraphKind {
    Body,
    Heading,
    Volume,
    Blank,
    List,
}

/// Semantic information only. Offsets and text are never rewritten for layout.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReadingParagraph {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub kind: ParagraphKind,
    pub continuation: bool,
    pub indented: bool,
}

pub(super) fn paragraphs(
    db: &Connection,
    id: &str,
    chunks: &[TextChunk],
) -> Result<Vec<ReadingParagraph>> {
    let Some(first) = chunks.first() else {
        return Ok(Vec::new());
    };
    let end = chunks.last().unwrap().end_utf8;
    let mut stmt = db.prepare("SELECT start_utf8,level FROM effective_chapters WHERE book_id=?1 AND start_utf8>=?2 AND start_utf8<?3")?;
    let headings = stmt
        .query_map(params![id, first.start_utf8 as i64, end as i64], |r| {
            Ok((unsigned_column(r, 0)?, r.get::<_, u32>(1)?))
        })?
        .collect::<std::result::Result<HashMap<_, _>, _>>()?;
    let continues = if first.start_utf8 > 0 {
        let raw_index = chunk_index(db, id, first.start_utf8 - 1)?;
        let raw = chunk(db, id, raw_index)?;
        let prefix = &raw.text[..(first.start_utf8 - raw.start_utf8) as usize];
        !prefix.ends_with('\n')
    } else {
        false
    };
    let text: String = chunks.iter().map(|c| c.text.as_str()).collect();
    let mut offset = 0;
    let mut result = Vec::new();
    for line in text.split_inclusive('\n') {
        let start = first.start_utf8 + offset as u64;
        let body = line.trim();
        let kind = match headings.get(&start) {
            Some(0) => ParagraphKind::Volume,
            Some(_) => ParagraphKind::Heading,
            None if body.is_empty() && db.query_row(
                "SELECT EXISTS(SELECT 1 FROM reading_blanks WHERE book_id=?1 AND start_utf8=(SELECT max(start_utf8) FROM reading_blanks WHERE book_id=?1 AND start_utf8<=?2) AND end_utf8>=?3)",
                params![id, start as i64, (start + line.len() as u64) as i64], |r| r.get::<_,bool>(0))? => ParagraphKind::Blank,
            None if body.starts_with(['•', '●', '※'])
                || body.starts_with("- ")
                || body.starts_with("* ") =>
            {
                ParagraphKind::List
            }
            None => ParagraphKind::Body,
        };
        offset += line.len();
        result.push(ReadingParagraph {
            start_utf8: start,
            end_utf8: first.start_utf8 + offset as u64,
            kind,
            continuation: start == first.start_utf8 && continues,
            indented: line.starts_with([' ', '\t', '　']),
        });
    }
    Ok(result)
}

/// Uses constant memory even for an arbitrarily long whitespace-only line.
/// A prefix is not blank until its LF (or final EOF) confirms the whole paragraph.
#[derive(Default)]
pub(super) struct BlankScanner {
    start: u64,
    end: u64,
    visible: bool,
    run: Option<(u64, u64)>,
    updates: Vec<(u64, u64)>,
}
impl BlankScanner {
    pub fn push(&mut self, text: &str) {
        for c in text.chars() {
            self.end += c.len_utf8() as u64;
            if c == '\n' {
                self.finish_line();
            } else {
                self.visible |= !c.is_whitespace();
            }
        }
    }
    pub fn finish_line(&mut self) {
        if self.start < self.end && !self.visible {
            let start = self
                .run
                .filter(|(_, end)| *end == self.start)
                .map_or(self.start, |(start, _)| start);
            self.run = Some((start, self.end));
            if let Some(last) = self.updates.last_mut().filter(|(a, _)| *a == start) {
                last.1 = self.end;
            } else {
                self.updates.push((start, self.end));
            }
        } else {
            self.run = None;
        }
        self.start = self.end;
        self.visible = false;
    }
    pub fn discard_published_prefix(&mut self) {
        self.updates.clear();
    }
    pub fn publish(&mut self, db: &Connection, id: &str) -> Result<()> {
        let frontier = if self.visible { self.end } else { self.start };
        // Replay may visit an already published prefix. Never regress a generation.
        db.execute("UPDATE books SET projection_end=?2,projection_revision=projection_revision+1 WHERE id=?1 AND projection_end<?2 AND byte_count>=?2", params![id, frontier as i64])?;
        for (start, end) in self.updates.drain(..) {
            let changed = db.execute("INSERT INTO reading_blanks VALUES(?1,?2,?3) ON CONFLICT(book_id,start_utf8) DO UPDATE SET end_utf8=excluded.end_utf8 WHERE end_utf8<>excluded.end_utf8", params![id, start as i64, end as i64])?;
            if changed > 0 {
                db.execute(
                    "UPDATE books SET projection_revision=projection_revision+1 WHERE id=?1",
                    [id],
                )?;
            }
        }
        Ok(())
    }
}

/// Runs are disjoint and maximal. One predecessor and a bounded start interval
/// avoid scanning all earlier paragraphs when paging near the end of a book.
pub(super) fn blank_ranges(db: &Connection, id: &str, lo: u64, hi: u64) -> Result<Vec<(u64, u64)>> {
    let predecessor: Option<(u64,u64)> = db.query_row(
        "SELECT start_utf8,end_utf8 FROM reading_blanks WHERE book_id=?1 AND start_utf8<?2 ORDER BY start_utf8 DESC LIMIT 1",
        params![id,lo as i64],|r|Ok((unsigned_column(r,0)?,unsigned_column(r,1)?))).optional()?;
    let mut result = predecessor
        .filter(|(_, end)| *end > lo)
        .into_iter()
        .collect::<Vec<_>>();
    let mut query = db.prepare("SELECT start_utf8,end_utf8 FROM reading_blanks WHERE book_id=?1 AND start_utf8>=?2 AND start_utf8<?3 ORDER BY start_utf8")?;
    result.extend(
        query
            .query_map(params![id, lo as i64, hi as i64], |r| {
                Ok((unsigned_column(r, 0)?, unsigned_column(r, 1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?,
    );
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn eof_only_blank_confirmation_revises_projection_without_new_chunks() {
        let dir = tempfile::TempDir::new().unwrap();
        let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
        let source = "甲\n \t　";
        let book = core
            .ingest(
                &mut std::io::Cursor::new(source.as_bytes()),
                "合成".into(),
                encoding_rs::UTF_8,
            )
            .unwrap();
        core.lock()
            .unwrap()
            .execute("DELETE FROM reading_blanks WHERE book_id=?1", [&book.id])
            .unwrap();
        let before = core.reading_frame(book.id.clone(), 0).unwrap();
        let mut scanner = BlankScanner::default();
        scanner.push(source);
        scanner.publish(&core.lock().unwrap(), &book.id).unwrap();
        assert!(
            core.reading_frame(book.id.clone(), 0)
                .unwrap()
                .omitted
                .is_empty()
        );
        scanner.finish_line();
        scanner.publish(&core.lock().unwrap(), &book.id).unwrap();
        let after = core.reading_frame(book.id.clone(), 0).unwrap();
        assert_eq!(
            before.snapshot.book.byte_count,
            after.snapshot.book.byte_count
        );
        assert_eq!(
            before.snapshot.book.chunk_count,
            after.snapshot.book.chunk_count
        );
        assert!(after.projection_revision > before.projection_revision);
        assert_eq!(after.omitted.len(), 1);
        assert_eq!(after.chunks[0].text, "甲\n");
    }
    #[test]
    fn heading_metadata_spans_adjacent_physical_chunks() {
        let dir = tempfile::TempDir::new().unwrap();
        let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
        let title = "第1章 跨物理块标题\n";
        let book = core
            .ingest(
                &mut std::io::Cursor::new(format!("{title}正文。").as_bytes()),
                "合成".into(),
                encoding_rs::UTF_8,
            )
            .unwrap();
        let mut db = core.lock().unwrap();
        let tx = db.transaction().unwrap();
        tx.execute("DELETE FROM chunks WHERE book_id=?1", [&book.id])
            .unwrap();
        let source = format!("{title}正文。");
        let split = "第1章 跨".len();
        for (index, (start, end)) in [(0, split), (split, source.len())].into_iter().enumerate() {
            let text = &source[start..end];
            tx.execute(
                "INSERT INTO chunks VALUES(?1,?2,?3,?4,?5,0,0)",
                params![book.id, index as u32, start as i64, end as i64, text],
            )
            .unwrap();
        }
        tx.execute("UPDATE books SET chunk_count=2 WHERE id=?1", [&book.id])
            .unwrap();
        tx.commit().unwrap();
        drop(db);
        let frame = core.reading_frame(book.id.clone(), 0).unwrap();
        assert_eq!(frame.paragraphs[0].kind, ParagraphKind::Heading);
        assert_eq!(frame.paragraphs[0].end_utf8, title.len() as u64);
        assert_eq!(frame.paragraphs.len(), 2);
    }
}
