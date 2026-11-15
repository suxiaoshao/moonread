#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceDecodingMigration {
    pub file_id: String,
    pub shelf_id: String,
    pub relative_path: String,
    pub size: u64,
    pub modified: i64,
    pub decoding: String,
    pub raw_sha256: Option<String>,
}
