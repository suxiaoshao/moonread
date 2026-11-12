mod catalogue;
mod search;
mod text;

pub(crate) use catalogue::{chapter, content_key};
pub use search::SearchJob;

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct TextRange {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub text: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MarkKind {
    Bookmark,
    Annotation,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ReaderMark {
    pub id: String,
    pub kind: MarkKind,
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub excerpt: String,
    pub note: String,
    pub created: u64,
}
#[derive(uniffi::Record)]
pub struct MarkPage {
    pub items: Vec<ReaderMark>,
    pub has_more: bool,
}
#[derive(uniffi::Record)]
pub struct ChapterOutline {
    pub items: Vec<ChapterEntry>,
    pub is_complete: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChapterEntry {
    pub start_utf8: u64,
    pub title: String,
    pub word_count: u64,
    pub count_complete: bool,
    pub level: u32,
    pub parent_utf8: Option<u64>,
    pub parent_title: Option<String>,
    pub covered_characters: Option<u64>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchRange {
    pub start_utf8: u64,
    pub end_utf8: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SearchHit {
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub excerpt: String,
    pub highlight_start: u32,
    pub highlight_end: u32,
    pub chapter: Option<String>,
}
#[derive(uniffi::Record)]
pub struct SearchBatch {
    pub hits: Vec<SearchHit>,
    pub done: bool,
    pub cancelled: bool,
    /// Coverage warning: a long regex line was skipped. This is independent of
    /// `done`; callers must keep requesting batches until completion/cancellation.
    pub truncated: bool,
    pub partial_book: bool,
    pub scanned_utf8: u64,
    pub available_utf8: u64,
}
