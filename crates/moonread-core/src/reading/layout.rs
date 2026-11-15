use crate::*;
use std::collections::HashMap;
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum ReadingMode {
    Scroll,
    Pages,
}

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ReaderFont {
    System,
    Serif,
    Rounded,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReaderFontChoice {
    Builtin {
        font: ReaderFont,
    },
    Imported {
        id: ImportedReaderFont,
        fallback: ReaderFont,
    },
}

#[uniffi::export]
pub fn resolve_reader_font_choice(
    font: ReaderFont,
    imported: Option<ImportedReaderFont>,
) -> ReaderFontChoice {
    match imported {
        // Previous readers used the system font when a selected import was unavailable.
        Some(id) => ReaderFontChoice::Imported {
            id,
            fallback: ReaderFont::System,
        },
        None => ReaderFontChoice::Builtin { font },
    }
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
    #[serde(default = "default_auto_reading_speed")]
    pub auto_reading_speed: f64,
    pub font: ReaderFont,
    #[serde(default)]
    pub imported_font: Option<ImportedReaderFont>,
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

fn default_auto_reading_speed() -> f64 {
    10.0
}

/// Unitless device-local speed levels; the platform supplies reading geometry.
#[uniffi::export]
pub fn auto_reading_control() -> ReaderNumberControl {
    ReaderNumberControl {
        minimum: 1.0,
        maximum: 30.0,
        step: 1.0,
        default_value: default_auto_reading_speed(),
    }
}

fn valid_auto_reading_speed(speed: f64) -> bool {
    let control = auto_reading_control();
    speed.is_finite()
        && (control.minimum..=control.maximum).contains(&speed)
        && speed.fract() == 0.0
}

/// Full-line equivalent layout advance, not measured words or characters.
#[uniffi::export]
pub fn auto_reading_em_per_minute(speed: f64) -> Result<f64> {
    if !valid_auto_reading_speed(speed) {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(150.0 * 1.16_f64.powf(speed - 1.0))
}

#[uniffi::export]
pub fn default_reader_settings() -> ReaderSettings {
    let controls = reader_typography_controls();
    ReaderSettings {
        mode: ReadingMode::Scroll,
        font_size: controls.font_size.default_value,
        line_spacing: controls.line_spacing.default_value,
        auto_reading_speed: default_auto_reading_speed(),
        font: ReaderFont::System,
        imported_font: None,
        paragraph_spacing: controls.paragraph_spacing.default_value,
        indent: ReadingIndent::Smart,
        horizontal_margin: 16.0,
        maximum_line_width: 680.0,
        keep_awake: false,
        brightness: None,
        orientation: ReadingOrientation::System,
    }
}

pub(crate) fn valid(settings: &ReaderSettings) -> bool {
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
        && valid_auto_reading_speed(settings.auto_reading_speed)
        && settings
            .imported_font
            .as_ref()
            .is_none_or(ImportedReaderFont::valid)
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

/// Unicode horizontal whitespace only: never paragraph boundaries or zero-width text.
pub(crate) fn horizontal_indent(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Runtime display omissions, not normalization or persisted source coordinates.
#[uniffi::export]
pub fn reading_indent_omissions(
    chunks: Vec<TextChunk>,
    paragraphs: Vec<ReadingParagraph>,
    indent: ReadingIndent,
) -> Vec<SourceSpan> {
    indent_omissions(&chunks, &paragraphs, indent)
}
pub(crate) fn indent_omissions(
    chunks: &[TextChunk],
    paragraphs: &[ReadingParagraph],
    indent: ReadingIndent,
) -> Vec<SourceSpan> {
    if indent != ReadingIndent::Smart {
        return Vec::new();
    }
    paragraphs
        .iter()
        .filter(|p| p.kind == ParagraphKind::Body && !p.continuation)
        .filter_map(|p| {
            let mut end = p.start_utf8;
            let mut resolved = false;
            'prefix: for chunk in chunks {
                if chunk.end_utf8 <= end {
                    continue;
                }
                if chunk.start_utf8 > end || end >= p.end_utf8 {
                    break;
                }
                let from = (end - chunk.start_utf8) as usize;
                let to = (p.end_utf8.min(chunk.end_utf8) - chunk.start_utf8) as usize;
                let Some(text) = chunk.text.get(from..to) else {
                    break;
                };
                for c in text.chars() {
                    if !horizontal_indent(c) {
                        resolved = true;
                        break 'prefix;
                    }
                    end += c.len_utf8() as u64;
                }
            }
            // An all-horizontal window suffix has no confirmed body yet.
            (end > p.start_utf8 && resolved).then_some(SourceSpan {
                start_utf8: p.start_utf8,
                end_utf8: end,
            })
        })
        .collect()
}

/// Only classify the supplied window; Swift selects its confirmed blank ranges and headings.
#[uniffi::export]
pub fn classify_reading_paragraphs(
    chunks: Vec<TextChunk>,
    chapters: Vec<ChapterInfo>,
    blank_runs: Vec<SourceSpan>,
    continues: bool,
) -> Vec<ReadingParagraph> {
    let Some(first) = chunks.first() else {
        return Vec::new();
    };
    let headings: HashMap<_, _> = chapters
        .into_iter()
        .map(|chapter| (chapter.start_utf8, chapter.level))
        .collect();
    let is_blank = |start, end| {
        let index = blank_runs.partition_point(|run| run.start_utf8 <= start);
        index > 0 && blank_runs[index - 1].end_utf8 >= end
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
            None if body.is_empty() && is_blank(start, start + line.len() as u64) => {
                ParagraphKind::Blank
            }
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
    result
}

/// Uses constant memory even for an arbitrarily long whitespace-only line.
/// A prefix is not blank until its LF (or final EOF) confirms the whole paragraph.
#[derive(Default)]
pub(crate) struct BlankScanner {
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
    pub(crate) fn drain(&mut self) -> (u64, Vec<(u64, u64)>) {
        let frontier = if self.visible { self.end } else { self.start };
        (frontier, std::mem::take(&mut self.updates))
    }
}
