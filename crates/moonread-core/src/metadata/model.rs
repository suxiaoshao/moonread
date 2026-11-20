use serde::{Deserialize, Serialize};

pub const METADATA_SCHEMA_URL: &str =
    "https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
#[serde(rename_all = "lowercase")]
pub enum MetadataFormat {
    Json,
    Jsonl,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MetadataFileReference {
    pub title: String,
    pub shelf: String,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MetadataReference {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default)]
    pub files: Vec<MetadataFileReference>,
}

/// Validated transport fields only. Swift owns metadata normalization and edits.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct MetadataBook {
    pub v: u32,
    pub content_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<MetadataReference>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading_state: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub clear: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub requires: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct MetadataDiagnostic {
    pub source_line: Option<u64>,
    pub record_index: Option<u64>,
    pub code: String,
    pub field: Option<String>,
    pub content_sha256: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataRecord {
    pub id: u64,
    pub source_line: Option<u64>,
    pub record_index: u64,
    pub duplicates: u64,
    pub book: MetadataBook,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataKeysPage {
    pub keys: Vec<String>,
    pub done: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataRecordPage {
    pub records: Vec<MetadataRecord>,
    pub next_cursor: u64,
    pub done: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataDiagnosticsPage {
    pub diagnostics: Vec<MetadataDiagnostic>,
    pub next_cursor: u64,
    pub done: bool,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataDocumentSummary {
    pub books: u64,
    pub variants: u64,
    pub diagnostics: u64,
}

#[uniffi::export]
pub fn encode_metadata_book(book: MetadataBook) -> crate::Result<String> {
    let value = serde_json::to_value(&book).map_err(|_| super::invalid("小说信息无法编码"))?;
    // The exporter goes through the same structural/semantic admission as imports.
    let mut normalized = value.clone();
    normalized.as_object_mut().unwrap().remove("reference");
    super::parse::book(normalized).map_err(|d| super::invalid(&d.message))?;
    serde_json::to_string(&value).map_err(|_| super::invalid("小说信息无法编码"))
}
