use crate::BookMetadata;

#[derive(Clone, Debug, uniffi::Enum)]
pub enum MetadataExchangeRequest {
    Import { shas: Vec<String> },
    Export { shelf_id: Option<String> },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct MetadataExchangeFile {
    pub id: String,
    pub shelf_id: String,
    pub shelf_name: String,
    pub relative_path: String,
    pub parent_path: String,
    pub name: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExportFile {
    pub file: MetadataExchangeFile,
    pub sha: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExchangeBook {
    pub metadata: BookMetadata,
    pub has_reading_position: bool,
    pub source_count: u64,
    pub first_source_name: String,
    pub unique_source: Option<MetadataExchangeFile>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExchangeRead {
    pub export_files: Vec<MetadataExportFile>,
    pub books: Vec<MetadataExchangeBook>,
}
