//! One owner for content keys and file/cache identity associations.
use crate::*;
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReadingKey {
    Formal { sha256: String },
    Pending { book_id: String },
}
impl ReadingKey {
    pub fn formal_sha(&self) -> Option<&str> {
        match self {
            Self::Formal { sha256 } => Some(sha256),
            Self::Pending { .. } => None,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ResolvedBookIdentity {
    pub key: ReadingKey,
    pub canonical_book_id: String,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct FileIdentity {
    pub file_id: String,
    pub key: Option<ReadingKey>,
    pub associated_book_id: Option<String>,
    pub pending_alias: Option<ReadingKey>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingKeyResolution {
    pub original: ReadingKey,
    pub effective: ReadingKey,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BookTarget {
    File { file_id: String },
    Record { key: ReadingKey },
    Cached { book_id: String },
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BodyAssociation {
    Absent,
    Associated { book_id: String },
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ResolvedBookRecord {
    pub key: ReadingKey,
    pub body: BodyAssociation,
    pub aliases: Vec<ReadingKey>,
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BookResolution {
    Unidentified { file_id: String },
    Resolved { record: ResolvedBookRecord },
    Missing { target: BookTarget },
}
#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum CatalogueScope {
    All,
    Shelf {
        shelf_id: String,
        parent_path: String,
        recursive: bool,
    },
}
#[uniffi::export]
pub fn parse_sha256(value: String) -> Result<String> {
    if value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        Ok(value)
    } else {
        Err(ReaderError::InvalidSettings)
    }
}
#[uniffi::export]
pub fn parse_reading_key(value: String) -> Result<ReadingKey> {
    if let Some(id) = value.strip_prefix("pending:").filter(|id| !id.is_empty()) {
        Ok(ReadingKey::Pending { book_id: id.into() })
    } else {
        Ok(ReadingKey::Formal {
            sha256: parse_sha256(value)?,
        })
    }
}
#[uniffi::export]
pub fn serialize_reading_key(key: ReadingKey) -> String {
    match key {
        ReadingKey::Formal { sha256 } => sha256,
        ReadingKey::Pending { book_id } => format!("pending:{book_id}"),
    }
}

pub(crate) fn valid_sha(value: &str) -> bool {
    parse_sha256(value.into()).is_ok()
}
