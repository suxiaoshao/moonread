//! Derived body eviction. Never touches user facts, authorization, decoding or unfinished jobs.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CachedBody {
    pub book_id: String,
    pub content_sha256: String,
    pub title: String,
    pub bytes: u64,
    pub protected: bool,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct CacheSummary {
    pub bytes: u64,
    pub protected: u64,
    pub bodies: u64,
}
