#[derive(Clone, Debug, uniffi::Record)]
pub struct SystemReadingBookProjection {
    pub content_sha256: String,
    pub title: String,
    pub author: Option<String>,
    pub tags: Vec<String>,
    pub cover: Option<crate::BookCoverAsset>,
    pub source_shelf_ids: Vec<String>,
    pub source_count: u64,
    pub needs_download: bool,
    pub percentage: Option<f64>,
    pub chapter_title: Option<String>,
    pub recent_rank: Option<u32>,
    pub natural_order_ordinal: u64,
}
