//! Supplemental information belongs to complete normalized text, never a file or import job.
use crate::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BookReadingStatus {
    Unread,
    Reading,
    Finished,
    Paused,
    Other { value: String },
}

impl Serialize for BookReadingStatus {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(match self {
            Self::Unread => "Unread",
            Self::Reading => "Reading",
            Self::Finished => "Finished",
            Self::Paused => "Paused",
            Self::Other { value } => value,
        })
    }
}
impl<'de> Deserialize<'de> for BookReadingStatus {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        Ok(match value.as_str() {
            "Unread" => Self::Unread,
            "Reading" => Self::Reading,
            "Finished" => Self::Finished,
            "Paused" => Self::Paused,
            _ => Self::Other { value },
        })
    }
}

#[cfg(test)]
mod status_tests {
    use super::*;

    #[test]
    fn unknown_status_round_trips_as_its_original_string() {
        let raw = r#""FutureReadingState""#;
        let value: BookReadingStatus = serde_json::from_str(raw).unwrap();
        assert_eq!(
            value,
            BookReadingStatus::Other {
                value: "FutureReadingState".into()
            }
        );
        assert_eq!(serde_json::to_string(&value).unwrap(), raw);
        assert_ne!(value, BookReadingStatus::Unread);
        for known in ["Unread", "Reading", "Finished", "Paused"] {
            let raw = serde_json::to_string(known).unwrap();
            let value: BookReadingStatus = serde_json::from_str(&raw).unwrap();
            assert_eq!(serde_json::to_string(&value).unwrap(), raw);
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BookCoverAsset {
    pub id: String,
    pub sha256: String,
    pub extension: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Record)]
pub struct BookMetadata {
    pub sha: String,
    pub author: String,
    pub synopsis: String,
    pub tags: Vec<String>,
    pub cover: Option<BookCoverAsset>,
    pub status: BookReadingStatus,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookDetails {
    pub metadata: BookMetadata,
    pub body: Option<BookBodyDetails>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct BookBodyDetails {
    pub book: BookInfo,
    pub word_count: u64,
    pub chapter_count: u64,
    pub current_chapter: Option<String>,
}
#[derive(Clone, Debug, uniffi::Enum)]
pub enum BookDetailsResult {
    Unidentified {
        file_id: String,
    },
    Missing {
        target: BookTarget,
    },
    Pending {
        identity: ResolvedBookRecord,
        body: Option<BookBodyDetails>,
    },
    Identified {
        identity: ResolvedBookRecord,
        details: BookDetails,
    },
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookFilterOptions {
    pub authors: Vec<String>,
    pub tags: Vec<String>,
}

fn empty(sha: &str) -> BookMetadata {
    BookMetadata {
        sha: sha.into(),
        author: String::new(),
        synopsis: String::new(),
        tags: vec![],
        cover: None,
        status: BookReadingStatus::Unread,
    }
}
