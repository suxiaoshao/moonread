//! Platform-independent text ingestion, normalized positions and reader state.
//! The caller owns authorization and file coordination for source paths.

mod identity;
pub use identity::*;
mod validation;
pub use validation::*;
mod book_details;
mod bookshelf;
mod library_order;
pub use book_details::*;
mod library_tools;
mod migrations;
pub use bookshelf::*;
mod cover_page;
mod coverage;
pub use cover_page::extract_page_images;
mod full_index;
mod navigation;
mod progressive;
mod reading_layout;
mod sha;
mod source_identity;
use sha::sha256_hex;
pub use source_identity::*;
mod statistics;
mod user_projection;
pub use statistics::*;
mod text;
pub use user_projection::*;
mod themes;
pub use library_tools::{
    ChapterEntry, ChapterOutline, MarkKind, MarkPage, ReaderMark, SearchBatch, SearchHit,
    SearchJob, SearchRange, TextRange,
};
pub use navigation::*;
pub use progressive::{
    ImportControl, ImportPhase, ImportStatus, ImportText, ReadingDirection, ReadingFrame,
    ReadingSnapshot, ReadingWindowStatus, SourceSpan,
};
pub use reading_layout::*;
pub use themes::*;

use encoding_rs::{Encoding, UTF_8};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::File,
    io::{Cursor, Read, Seek, SeekFrom},
    path::Path,
    sync::{Arc, Mutex, MutexGuard},
};
use uuid::Uuid;

uniffi::setup_scaffolding!();

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, thiserror::Error, uniffi::Error)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ReaderError {
    #[error("文件访问失败：{message}")]
    Io { message: String },
    #[error("数据存储失败：{message}")]
    Storage { message: String },
    #[error("正文编码无效或不支持：{message}")]
    Decode { message: String },
    #[error("单个组合字符超过 64 KiB，无法安全分块")]
    GraphemeTooLong,
    #[error("文件具有二进制特征，或文字编码选择不正确")]
    BinaryContent,
    #[error("正文超过可存储的范围")]
    TextCapacityExceeded,
    #[error("未找到书籍或正文片段")]
    NotFound,
    #[error("文件没有正文")]
    EmptyBook,
    #[error("设置值无效")]
    InvalidSettings,
    #[error("准备已暂停，已读内容和位置已保留")]
    Paused,
    #[error("小说仍在准备，请稍后重试")]
    ImportBusy,
    #[error("源文件已改变，请重新打开；之前的阅读位置仍保留")]
    SourceChanged,
    #[error("Database predates the supported v20 baseline; no migration is available")]
    IncompatibleStore,
    #[error("Database version {version} is newer than supported version {current}; update the app")]
    StoreTooNew { version: u32, current: u32 },
    #[error("Local reading data belongs to a different iCloud account")]
    CloudAccountChanged,
    #[error("Invalid text range")]
    InvalidRange,
    #[error("Search pattern: {message}")]
    SearchPattern { message: String },
    #[error("A paragraph exceeds the search memory limit")]
    SearchLineTooLong,
}

impl From<std::io::Error> for ReaderError {
    fn from(value: std::io::Error) -> Self {
        Self::Io {
            message: value.to_string(),
        }
    }
}
impl From<rusqlite::Error> for ReaderError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Storage {
            message: value.to_string(),
        }
    }
}
type Result<T> = std::result::Result<T, ReaderError>;

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookInfo {
    pub id: String,
    pub title: String,
    /// SHA-256 of normalization-v1 UTF-8, not the original file's bytes.
    pub content_sha256: String,
    pub encoding: String,
    pub byte_count: u64,
    pub chunk_count: u32,
    pub position_utf8: u64,
}

#[derive(Debug, uniffi::Record)]
pub struct TextChunk {
    pub index: u32,
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub text: String,
}

/// A heading detected in the normalized text. `start_utf8` is its byte offset.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChapterInfo {
    pub title: String,
    pub start_utf8: u64,
    pub level: u32,
}

/// Raw bytes plus the requested decoding policy, never a file identity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceContentKey {
    pub raw_sha256: String,
    pub decoding: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum ReadingMode {
    Scroll,
    Pages,
}

#[derive(uniffi::Object)]
pub struct ReaderCore {
    db: Mutex<Connection>,
    reader: Mutex<Connection>,
    imports: Mutex<HashMap<String, std::sync::Weak<ImportControl>>>,
    import_failures: Mutex<HashMap<String, progressive::ImportFailure>>,
    database_path: std::path::PathBuf,
}

#[uniffi::export]
impl ReaderCore {
    #[uniffi::constructor]
    pub fn new(data_directory: String) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&data_directory)?;
        let database_path = Path::new(&data_directory).join("reader.sqlite3");
        let mut db = Connection::open(&database_path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")?;
        migrations::initialize(&mut db)?;
        user_projection::initialize(&db)?;
        progressive::recover(&mut db)?;
        let reader = Connection::open(&database_path)?;
        reader.busy_timeout(std::time::Duration::from_secs(5))?;
        reader.execute_batch("PRAGMA foreign_keys=ON;")?;
        user_projection::initialize(&reader)?;
        Ok(Arc::new(Self {
            db: Mutex::new(db),
            reader: Mutex::new(reader),
            imports: Mutex::new(HashMap::new()),
            import_failures: Mutex::new(HashMap::new()),
            database_path,
        }))
    }

    /// Call synchronously while the platform holds coordinated, authorized access.
    /// Import is transactional; originals are never modified and no external paths persist.
    pub fn import_book(&self, file_path: String, title: String) -> Result<ImportText> {
        let mut file = File::open(file_path)?;
        let encoding = text::detect_encoding(&mut file)?;
        file.seek(SeekFrom::Start(0))?;
        self.ingest(&mut file, title, encoding).map(Into::into)
    }

    /// The caller hashes the coordinated source before consulting this cache.
    pub fn source_book(&self, key: SourceContentKey) -> Result<Option<ImportText>> {
        if !valid_source_key(&key) {
            return Err(ReaderError::InvalidSettings);
        }
        Ok(self.lock()?.query_row(
            "SELECT b.id,b.title,b.content_sha256,b.encoding,b.byte_count,b.chunk_count,b.position_utf8 FROM source_imports s JOIN reading_books b ON b.id=s.book_id WHERE s.raw_sha256=?1 AND s.decoding=?2 AND b.content_sha256 NOT LIKE 'pending:%'",
            params![key.raw_sha256,decoding_policy(&key.decoding)?],book_row).optional()?.map(Into::into))
    }

    pub fn create_sample_book(&self) -> Result<ImportText> {
        // Explicit synthetic content only; no bundled personal novel.
        let mut sample = String::from(
            "月读技术样机 · 示例文本\n\n这是一份程序生成的排版测试文本，不是小说作品。\n\n",
        );
        for index in 1..=180 {
            sample.push_str(&format!("第 {index} 章 · 月下试读\n月光落在窗边，书页安静地展开。这一段用于检查中文标点、换行和阅读位置恢复。调整字号，切换滚动与分页，再返回同一处文字。\nMixed text: Moonread 123 — emoji 🌙📚👨‍👩‍👧‍👦 and café e\u{301}.\n\n"));
        }
        let book = self.ingest(&mut Cursor::new(sample), "月读 · 排版示例".into(), UTF_8)?;
        Ok(book.into())
    }

    pub fn text_id_for_sha(&self, sha: String) -> Result<String> {
        parse_sha256(sha.clone())?;
        self.lock()?
            .query_row("SELECT id FROM books WHERE content_sha256=?1", [sha], |r| {
                r.get(0)
            })
            .map_err(Into::into)
    }

    pub fn read_chunk(&self, book_id: String, index: u32) -> Result<TextChunk> {
        chunk(&*self.lock()?, &book_id, index)
    }

    /// EOF maps to the last chunk. Offsets past EOF are clamped.
    pub fn find_chunk(&self, book_id: String, offset_utf8: u64) -> Result<u32> {
        let db = self.lock()?;
        let info = book(&db, &book_id)?;
        chunk_index(&db, &book_id, offset_utf8.min(info.byte_count))
    }
}

impl ReaderCore {
    fn lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.db.lock().map_err(|_| ReaderError::Storage {
            message: "存储锁不可用，请重新打开应用".into(),
        })
    }

    fn ingest(
        &self,
        reader: &mut impl Read,
        title: String,
        encoding: &'static Encoding,
    ) -> Result<BookInfo> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let id = Uuid::new_v4().to_string();
        let title = if title.trim().is_empty() {
            "未命名文本".into()
        } else {
            title
        };
        tx.execute(
            "INSERT INTO books(id,title,content_sha256,encoding) VALUES(?1,?2,?3,?4)",
            params![id, title, format!("pending:{id}"), encoding.name()],
        )?;
        let mut hasher = Sha256::new();
        let mut offset = 0u64;
        let mut index = 0u32;
        let mut has_visible_text = false;
        let mut scanner = ChapterScanner::default();
        let mut blanks = reading_layout::BlankScanner::default();
        text::decode_chunks(reader, encoding, |text| {
            has_visible_text |= text.chars().any(|c| !c.is_whitespace());
            let end = offset
                .checked_add(text.len() as u64)
                .ok_or(ReaderError::TextCapacityExceeded)?;
            if end > i64::MAX as u64 {
                return Err(ReaderError::TextCapacityExceeded);
            }
            let start_count = scanner.char_count;
            scanner.push_chunk(offset, text);
            blanks.push(text);
            tx.execute(
                "UPDATE books SET byte_count=?2 WHERE id=?1",
                params![id, end as i64],
            )?;
            blanks.publish(&tx, &id)?;
            tx.execute(
                "INSERT INTO chunks VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    id,
                    index,
                    offset as i64,
                    end as i64,
                    text,
                    start_count as i64,
                    scanner.char_count as i64
                ],
            )?;
            hasher.update(text.as_bytes());
            offset = end;
            index = index
                .checked_add(1)
                .ok_or(ReaderError::TextCapacityExceeded)?;
            Ok(())
        })?;
        if !has_visible_text {
            return Err(ReaderError::EmptyBook);
        }
        blanks.finish_line();
        blanks.publish(&tx, &id)?;
        let hash = sha256_hex(hasher.finalize());
        let existing: Option<String> = tx
            .query_row(
                "SELECT id FROM reading_books WHERE content_sha256=?1",
                [&hash],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            // Drop rolls back all staged cache rows and preserves the existing title/progress.
            return book(&tx, &existing);
        }
        tx.execute(
            "UPDATE books SET content_sha256=?1,byte_count=?2,chunk_count=?3 WHERE id=?4",
            params![hash, offset as i64, index, id],
        )?;
        for heading in scanner.finish() {
            tx.execute(
                "INSERT INTO import_chapters VALUES(?1,?2,?3,?4,?5,?6)",
                params![
                    id,
                    heading.start_utf8 as i64,
                    heading.title,
                    heading.level,
                    heading.start_char_count as i64,
                    heading.body_char_count as i64
                ],
            )?;
        }
        let result = book(&tx, &id)?;
        tx.commit()?;
        Ok(result)
    }
}

fn book_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookInfo> {
    Ok(BookInfo {
        id: row.get(0)?,
        title: row.get(1)?,
        content_sha256: row.get(2)?,
        encoding: row.get(3)?,
        byte_count: unsigned_column(row, 4)?,
        chunk_count: row.get(5)?,
        position_utf8: unsigned_column(row, 6)?,
    })
}

fn valid_source_key(key: &SourceContentKey) -> bool {
    valid_sha(&key.raw_sha256) && decoding_policy(&key.decoding).is_ok()
}
fn decoding_policy(value: &str) -> Result<&'static str> {
    if value == "auto" {
        return Ok("auto");
    }
    Encoding::for_label(value.as_bytes())
        .filter(|e| ![encoding_rs::REPLACEMENT, encoding_rs::X_USER_DEFINED].contains(e))
        .map(|e| e.name())
        .ok_or(ReaderError::InvalidSettings)
}
fn valid_sha(value: &str) -> bool {
    parse_sha256(value.into()).is_ok()
}

fn book(db: &Connection, id: &str) -> Result<BookInfo> {
    db.query_row("SELECT id,title,content_sha256,encoding,byte_count,chunk_count,position_utf8 FROM reading_books WHERE id=?1", [id], book_row).optional()?.ok_or(ReaderError::NotFound)
}
fn chunk(db: &Connection, id: &str, index: u32) -> Result<TextChunk> {
    db.query_row("SELECT chunk_index,start_utf8,end_utf8,text FROM chunks WHERE book_id=?1 AND chunk_index=?2", params![id,index], |r| {
        Ok(TextChunk { index: r.get(0)?, start_utf8: unsigned_column(r, 1)?, end_utf8: unsigned_column(r, 2)?, text: r.get(3)? })
    }).optional()?.ok_or(ReaderError::NotFound)
}
fn chunk_index(db: &Connection, id: &str, offset: u64) -> Result<u32> {
    db.query_row("SELECT chunk_index FROM chunks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1", params![id,offset as i64], |r| r.get(0)).optional()?.ok_or(ReaderError::NotFound)
}

const MAX_CHAPTER_LINE_BYTES: usize = 4096;

#[derive(Default)]
struct ChapterScanner {
    chapters: Vec<IndexedChapter>,
    line: String,
    line_start_utf8: u64,
    line_start_char_count: u64,
    char_count: u64,
    line_too_long: bool,
}

struct IndexedChapter {
    start_utf8: u64,
    title: String,
    level: u32,
    start_char_count: u64,
    body_char_count: u64,
}

impl ChapterScanner {
    fn push_chunk(&mut self, chunk_start_utf8: u64, text: &str) {
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

    fn finish_line(&mut self) {
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

    fn finish(mut self) -> Vec<IndexedChapter> {
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

fn unsigned_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Integer,
            Box::new(e),
        )
    })
}

impl ReaderCore {
    pub(crate) fn book_info(&self, book_id: String) -> Result<BookInfo> {
        book(&*self.lock()?, &book_id)
    }
    /// Return the latest recognized heading at or before a normalized UTF-8 offset.
    /// Read the persisted index produced alongside normalized text ingestion.
    pub(crate) fn chapter_at(
        &self,
        book_id: String,
        offset_utf8: u64,
    ) -> Result<Option<ChapterInfo>> {
        let db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let id = library_tools::content_key(&db, &book_id)?;
        library_tools::chapter(&db, &id, offset_utf8)
    }
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

#[cfg(test)]
mod decoding_policy_tests {
    use super::*;
    #[test]
    fn manual_policy_accepts_all_text_decoders_and_rejects_unsuitable_labels() {
        for (input, expected) in [
            ("UTF-16BE", "UTF-16BE"),
            ("utf-8", "UTF-8"),
            ("shift-jis", "Shift_JIS"),
            ("latin1", "windows-1252"),
        ] {
            assert_eq!(
                decoding_policy(input).unwrap(),
                expected,
                "manual decoding label {input}"
            );
        }
        for label in ["replacement", "not-an-encoding"] {
            assert!(
                matches!(decoding_policy(label), Err(ReaderError::InvalidSettings)),
                "unsafe label {label}"
            );
        }
    }
}
