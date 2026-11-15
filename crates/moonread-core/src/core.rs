//! Data at the reader computation boundary.
use crate::ReadingKey;

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookInfo {
    pub id: String,
    pub title: String,
    pub reading_key: ReadingKey,
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

/// Raw bytes plus the requested decoding policy, never a file identity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceContentKey {
    pub raw_sha256: String,
    pub decoding: String,
}
