use crate::SourceFileSnapshot;

#[derive(Debug, Clone, uniffi::Record)]
pub struct LibraryIdentityInventory {
    pub total: u64,
    pub pending: Vec<SourceFileSnapshot>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct IndexedSourcePolicy {
    pub file_id: String,
    pub raw_sha256: String,
    pub decoding: String,
}
