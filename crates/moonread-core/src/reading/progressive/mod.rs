//! A committed, immutable prefix is readable while import continues.
use crate::*;
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ImportPhase {
    Preparing,
    Importing,
    Finalizing,
    Complete,
    Paused,
    Failed,
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum PreparationState {
    Preparing,
    Importing,
    Finalizing,
    Complete,
    Paused { detail: PauseDetail },
    Failed { detail: FailureDetail },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum PauseDetail {
    Unknown,
    Interrupted,
    NoActiveWorker,
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum FailureDetail {
    Reported { error: ReaderError },
    Unavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadablePrefix {
    Unavailable,
    Readable,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportByteProgress {
    pub read: u64,
    pub total: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingSnapshot {
    /// For a draft/alias this ID stays stable throughout the reading session.
    pub book: BookInfo,
    pub preparation: PreparationState,
    pub generation: u64,
    /// Already committed text may be readable even after a worker fails.
    pub readable_prefix: ReadablePrefix,
    /// Formal reading activity, including the first body position (offset 0).
    /// Preparing or viewing a cover does not start reading.
    pub has_started: bool,
    pub byte_progress: ImportByteProgress,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingDirection {
    Forward,
    Backward,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ReadingWindowStatus {
    Ready,
    Awaiting,
    End,
    Beginning,
    Deferred,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct SourceSpan {
    pub start_utf8: u64,
    pub end_utf8: u64,
}

#[derive(Debug, uniffi::Record)]
pub struct ReadingFrame {
    pub snapshot: ReadingSnapshot,
    /// Target heading from the same read transaction as the bounded frame.
    pub chapter: Option<ChapterInfo>,
    pub chunks: Vec<TextChunk>,
    pub paragraphs: Vec<ReadingParagraph>,
    pub is_end_of_book: bool,
    pub omitted: Vec<SourceSpan>,
    pub source_start: u64,
    pub source_end: u64,
    pub cursor: u64,
    /// A loaded retained scalar, including paragraph whitespace; not an ink witness.
    pub projection_anchor: Option<u64>,
    pub has_non_whitespace_payload: bool,
    pub status: ReadingWindowStatus,
    pub next_cursor: Option<u64>,
    pub previous_cursor: Option<u64>,
    pub projection_revision: u64,
}

/// Import lifecycle metadata contains no user position or reading activity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportText {
    pub encoding: String,
    pub id: String,
    pub title: String,
    pub reading_key: ReadingKey,
    pub byte_count: u64,
    pub chunk_count: u32,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportStatus {
    pub text: ImportText,
    pub phase: ImportPhase,
}
impl From<BookInfo> for ImportText {
    fn from(book: BookInfo) -> Self {
        Self {
            id: book.id,
            title: book.title,
            reading_key: book.reading_key,
            encoding: book.encoding,
            byte_count: book.byte_count,
            chunk_count: book.chunk_count,
        }
    }
}
