//! Platform-independent text ingestion, normalized positions and reader state.
//! The caller owns authorization and file coordination for source paths.

mod core;
mod error;
mod identity;
mod library;
mod reading;
mod storage;
mod user;

pub use core::{BookInfo, ReaderCore, SourceContentKey, TextChunk};
pub use error::ReaderError;
pub use identity::*;
pub use library::*;
pub use reading::*;
pub use storage::*;
pub use user::*;

pub(crate) use error::Result;
pub(crate) use identity::content::valid_sha;
pub(crate) use identity::sha::sha256_hex;
pub(crate) use identity::source::{decoding_policy, valid_source_key};
pub(crate) use reading::chapters::{ChapterScanner, IndexedChapter};
pub(crate) use storage::rows::{book, book_row, chunk, chunk_index, unsigned_column};

uniffi::setup_scaffolding!();
