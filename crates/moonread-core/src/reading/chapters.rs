/// A heading detected in the normalized text. `start_utf8` is its byte offset.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChapterInfo {
    pub title: String,
    pub start_utf8: u64,
    pub level: u32,
}

pub(crate) const MAX_CHAPTER_LINE_BYTES: usize = 4096;

#[derive(Default)]
pub(crate) struct ChapterScanner {
    pub(crate) chapters: Vec<IndexedChapter>,
    line: String,
    line_start_utf8: u64,
    line_start_char_count: u64,
    pub(crate) char_count: u64,
    line_too_long: bool,
}

pub(crate) struct IndexedChapter {
    pub(crate) start_utf8: u64,
    pub(crate) title: String,
    pub(crate) level: u32,
    pub(crate) start_char_count: u64,
    pub(crate) body_char_count: u64,
}

impl ChapterScanner {
    pub(crate) fn push_chunk(&mut self, chunk_start_utf8: u64, text: &str) {
        for (byte_index, character) in text.char_indices() {
            if !character.is_whitespace() {
                self.char_count += 1;
            }
            if character == '\n' {
                self.finish_line();
                self.line_start_utf8 = chunk_start_utf8 + byte_index as u64 + 1;
                self.line_start_char_count = self.char_count;
            } else if !self.line_too_long {
                if self.line.len() + character.len_utf8() <= MAX_CHAPTER_LINE_BYTES {
                    self.line.push(character);
                } else {
                    // Ignore very long prose lines while keeping memory bounded.
                    self.line.clear();
                    self.line_too_long = true;
                }
            }
        }
    }

    pub(crate) fn finish_line(&mut self) {
        if !self.line_too_long
            && let Some(title) = chapter_heading(&self.line)
        {
            self.chapters.push(IndexedChapter {
                level: heading_level(&title),
                title,
                start_utf8: self.line_start_utf8,
                start_char_count: self.line_start_char_count,
                body_char_count: self.char_count,
            });
        }
        self.line.clear();
        self.line_too_long = false;
    }

    pub(crate) fn finish(mut self) -> Vec<IndexedChapter> {
        self.finish_line();
        self.chapters
    }
}

fn chapter_heading(line: &str) -> Option<String> {
    let title = line.trim();
    if title.chars().count() > 80 {
        return None;
    }
    if is_chinese_chapter_heading(title)
        || is_english_chapter_heading(title)
        || is_special_heading(title)
    {
        Some(title.to_owned())
    } else {
        None
    }
}

/// Only 章 allows a compact title; other units require a heading boundary.
/// The number may use Arabic, simplified/traditional, or financial numerals.
fn is_chinese_chapter_heading(line: &str) -> bool {
    let Some(rest) = line.strip_prefix('第') else {
        return false;
    };
    let Some((unit_index, unit)) = rest.char_indices().find(|(_, character)| {
        matches!(
            character,
            '章' | '回'
                | '节'
                | '節'
                | '话'
                | '話'
                | '讲'
                | '講'
                | '篇'
                | '幕'
                | '卷'
                | '集'
                | '部'
                | '本'
                | '册'
                | '冊'
        )
    }) else {
        return false;
    };
    let number = rest[..unit_index].trim();
    if number.is_empty() || !number.chars().all(is_chapter_numeral) {
        return false;
    }
    let suffix = &rest[unit_index + unit.len_utf8()..];
    if unit != '章' {
        return has_heading_boundary(suffix);
    }
    // Preserve 1.0's compact 章 titles, with a bounded suffix to reject prose.
    if !has_heading_boundary(suffix) && suffix.chars().count() > 30 {
        return false;
    }
    ![
        "说过",
        "說過",
        "提到",
        "讲过",
        "講過",
        "已经",
        "已經",
        "里面",
        "裡面",
        "裏面",
        "的时候",
        "的時候",
        "的内容",
        "的內容",
    ]
    .iter()
    .any(|s| suffix.trim_start().starts_with(s))
}

fn heading_level(title: &str) -> u32 {
    if title.strip_prefix('第').is_some_and(|rest| {
        matches!(
            rest.chars()
                .find(|c| !c.is_whitespace() && !is_chapter_numeral(*c)),
            Some('卷' | '集' | '部' | '本' | '册' | '冊')
        )
    }) || title.to_ascii_lowercase().starts_with("volume ")
    {
        0
    } else {
        1
    }
}

fn is_special_heading(title: &str) -> bool {
    [
        "楔子", "序章", "序幕", "序言", "前言", "尾声", "尾聲", "终章", "終章", "后记", "後記",
        "番外", "外传", "外傳", "间章", "間章", "引子",
    ]
    .iter()
    .any(|prefix| {
        title.strip_prefix(prefix).is_some_and(|rest| {
            has_heading_boundary(rest)
                || has_heading_boundary(rest.trim_start_matches(is_chapter_numeral))
        })
    }) || ["prologue", "epilogue", "preface", "afterword"]
        .iter()
        .any(|prefix| {
            title
                .to_ascii_lowercase()
                .strip_prefix(prefix)
                .is_some_and(has_heading_boundary)
        })
        || title
            .to_ascii_lowercase()
            .strip_prefix("volume ")
            .is_some_and(|rest| {
                let count = rest
                    .chars()
                    .take_while(|c| c.is_ascii_digit() || matches!(c, 'i' | 'v' | 'x' | 'l' | 'c'))
                    .count();
                count > 0 && has_heading_boundary(&rest[count..])
            })
}

fn is_chapter_numeral(character: char) -> bool {
    character.is_ascii_digit()
        || matches!(
            character,
            '０'
                ..='９'
                    | '零'
                    | '〇'
                    | '一'
                    | '二'
                    | '两'
                    | '兩'
                    | '三'
                    | '四'
                    | '五'
                    | '六'
                    | '七'
                    | '八'
                    | '九'
                    | '十'
                    | '百'
                    | '千'
                    | '万'
                    | '萬'
                    | '亿'
                    | '億'
                    | '壹'
                    | '贰'
                    | '貳'
                    | '叁'
                    | '參'
                    | '肆'
                    | '伍'
                    | '陆'
                    | '陸'
                    | '柒'
                    | '捌'
                    | '玖'
                    | '拾'
                    | '佰'
                    | '仟'
                    | '廿'
                    | '卅'
                    | '卌'
        )
}

/// Recognize `Chapter N` (case-insensitive), optionally followed by a separated title.
fn is_english_chapter_heading(line: &str) -> bool {
    let Some(prefix) = line.get(..7) else {
        return false;
    };
    if !prefix.eq_ignore_ascii_case("Chapter") {
        return false;
    }
    let rest = &line[7..];
    if !rest.starts_with(char::is_whitespace) {
        return false;
    }
    let rest = rest.trim_start();
    let digits_end = rest
        .char_indices()
        .find_map(|(index, character)| (!character.is_ascii_digit()).then_some(index))
        .unwrap_or(rest.len());
    if digits_end == 0 {
        return false;
    }
    has_heading_boundary(&rest[digits_end..])
}

fn has_heading_boundary(suffix: &str) -> bool {
    suffix.is_empty()
        || suffix.starts_with(char::is_whitespace)
        || suffix.starts_with([
            ':', '：', '.', '．', '、', '-', '—', '–', '(', '（', ')', '）',
        ])
}

#[cfg(test)]
mod chapter_tests {
    use super::{ChapterScanner, chapter_heading, heading_level};

    #[test]
    fn numbered_heading_units_support_traditional_and_financial_numerals() {
        // One sample per syntax/numeral class; no unit × numeral × suffix matrix.
        for (title, level) in [
            ("第一章月下归舟", 1),
            ("第一回 灵根育孕", 1),
            ("第1話：月光", 1),
            ("第壹部 星港", 0),
            ("第三卷", 0),
            ("第二講 開場", 1),
            ("第一本", 0),
            ("第兩百節 星港", 1),
            ("第一萬集 星港", 0),
            ("第一億冊 星港", 0),
            ("第１２幕 星港", 1),
            ("尾聲", 1),
            ("終章：歸舟", 1),
            ("後記壹 月下", 1),
            ("番外二：归途", 1),
        ] {
            assert_eq!(
                chapter_heading(title).as_deref(),
                Some(title),
                "heading syntax: {title}"
            );
            assert_eq!(heading_level(title), level, "heading hierarchy: {title}");
        }
        for prose in [
            "第一回合",
            "第二節課",
            "終章已經結束",
            "番外三个人走进门",
            "第幾章 月下",
            "第1.5章 月下",
        ] {
            assert!(chapter_heading(prose).is_none(), "prose boundary: {prose}");
        }
    }

    #[test]
    fn compact_chapter_titles_allow_30_characters_and_separated_lines_allow_80() {
        for (prefix, count) in [("第一章", 30), ("第一章：", 76)] {
            let title = format!("{prefix}{}", "月".repeat(count));
            assert_eq!(
                chapter_heading(&title).as_deref(),
                Some(title.as_str()),
                "at boundary: {prefix}"
            );
            assert!(
                chapter_heading(&format!("{title}月")).is_none(),
                "over boundary: {prefix}"
            );
        }
        assert!(chapter_heading("第一章說過這件事").is_none());
        assert!(chapter_heading("第一章 的内容还没看").is_none());
    }

    #[test]
    fn rejects_ordinary_nouns_and_numbered_prose() {
        for prose in [
            "第三部分",
            "第一篇文章",
            "第一部电影",
            "第四本书",
            "第一話題",
        ] {
            assert!(
                chapter_heading(prose).is_none(),
                "body sentence must not become a chapter: {prose}"
            );
        }
        assert_eq!(
            chapter_heading("第三部 分别").as_deref(),
            Some("第三部 分别")
        );
    }

    #[test]
    fn new_headings_and_prose_are_stable_at_every_chunk_split() {
        let text = "正文🌙\n第一篇文章\n第兩百話：月下歸舟\n原創正文。\n尾聲";
        let mut whole = ChapterScanner::default();
        whole.push_chunk(0, text);
        let expected = whole.finish();
        assert_eq!(
            expected
                .iter()
                .map(|h| h.title.as_str())
                .collect::<Vec<_>>(),
            ["第兩百話：月下歸舟", "尾聲"]
        );
        // Legal UTF-8 boundary beside a multibyte numeral, and title separator.
        for split in [text.find('兩').unwrap(), text.find('：').unwrap()] {
            let mut scanner = ChapterScanner::default();
            scanner.push_chunk(0, &text[..split]);
            scanner.push_chunk(split as u64, &text[split..]);
            let actual = scanner.finish();
            assert_eq!(
                actual
                    .iter()
                    .map(|h| (&h.title, h.start_utf8, h.level))
                    .collect::<Vec<_>>(),
                expected
                    .iter()
                    .map(|h| (&h.title, h.start_utf8, h.level))
                    .collect::<Vec<_>>(),
                "split {split}"
            );
        }
    }
}

// Business projections are exported only by ReaderQuery.
