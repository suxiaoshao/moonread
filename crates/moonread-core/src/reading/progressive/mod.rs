//! A committed, immutable prefix is readable while import continues.
use crate::*;
use std::sync::atomic::AtomicBool;
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

impl PreparationState {
    pub(crate) fn is_complete(&self) -> bool {
        matches!(self, Self::Complete)
    }

    fn is_active(&self) -> bool {
        matches!(self, Self::Preparing | Self::Importing | Self::Finalizing)
    }

    /// The original flat status still serves the import management boundary.
    fn legacy_phase(&self) -> ImportPhase {
        match self {
            Self::Preparing => ImportPhase::Preparing,
            Self::Importing => ImportPhase::Importing,
            Self::Finalizing => ImportPhase::Finalizing,
            Self::Complete => ImportPhase::Complete,
            Self::Paused { .. } => ImportPhase::Paused,
            Self::Failed { .. } => ImportPhase::Failed,
        }
    }
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

#[derive(uniffi::Object)]
pub struct ImportControl {
    id: String,
    generation: u64,
    cancelled: AtomicBool,
    running: AtomicBool,
}

#[derive(Clone)]
pub(crate) struct ImportFailure {
    generation: u64,
    preparation: PreparationState,
}

/// Import lifecycle metadata contains no user position or reading activity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ImportText {
    pub encoding: String,
    pub id: String,
    pub title: String,
    pub content_sha256: String,
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
            content_sha256: book.content_sha256,
            encoding: book.encoding,
            byte_count: book.byte_count,
            chunk_count: book.chunk_count,
        }
    }
}

mod query;
mod recovery;
mod stream;
mod tasks;
pub(crate) use query::snapshot;
pub(crate) use recovery::recover;
#[cfg(test)]
mod tests;
