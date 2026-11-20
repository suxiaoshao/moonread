//! Platform-independent text ingestion, normalized positions and reader state.
//! The caller owns authorization and file coordination for source paths.

mod core;
mod error;
mod identity;
mod library;
mod metadata;
mod reading;
mod storage;
mod user;

pub use core::{BookInfo, SourceContentKey, TextChunk};
pub use error::{ReaderError, decode_import_error, encode_import_error};
pub use identity::*;
pub use library::*;
pub use metadata::*;
pub use reading::*;
pub use storage::*;
pub use user::*;

pub(crate) use error::Result;
pub(crate) use identity::content::valid_sha;
pub(crate) use identity::sha::sha256_hex;
pub(crate) use reading::chapters::ChapterScanner;
pub use reading::chapters::IndexedChapter;

uniffi::setup_scaffolding!();
