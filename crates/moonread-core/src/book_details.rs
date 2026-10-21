//! Supplemental information belongs to complete normalized text, never a file or import job.
use crate::*;
use serde::{Deserialize, Serialize};

use std::collections::BTreeSet;

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
    pub book: Option<BookInfo>,
    pub metadata: BookMetadata,
    pub word_count: u64,
    pub chapter_count: u64,
    pub current_chapter: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookFilterOptions {
    pub authors: Vec<String>,
    pub tags: Vec<String>,
}

pub(crate) fn valid_sha(sha: &str) -> bool {
    sha.len() == 64
        && sha
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
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

pub(crate) fn metadata(db: &Connection, sha: &str) -> Result<BookMetadata> {
    let text: Option<String> = db
        .query_row(
            "SELECT value FROM book_metadata WHERE content_sha=?1",
            [sha],
            |r| r.get(0),
        )
        .optional()?;
    let mut result = text
        .map(|v| serde_json::from_str(&v).map_err(|_| ReaderError::InvalidSettings))
        .transpose()?
        .unwrap_or_else(|| empty(sha));
    if result.status == BookReadingStatus::Unread
        && db.query_row(
            "SELECT EXISTS(SELECT 1 FROM reading_books WHERE content_sha256=?1 AND last_read>0)",
            [sha],
            |r| r.get::<_, bool>(0),
        )?
    {
        result.status = BookReadingStatus::Reading;
    }
    Ok(result)
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn book_details(
        &self,
        book_id: Option<String>,
        content_sha: Option<String>,
    ) -> Result<BookDetails> {
        let db = self.read_lock()?;
        let info = if let Some(id) = book_id {
            Some(book(&db, &library_tools::content_key(&db, &id)?)?)
        } else if let Some(sha) = &content_sha {
            db.query_row(
                "SELECT id FROM reading_books WHERE content_sha256=?1",
                [sha],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .map(|id| book(&db, &id))
            .transpose()?
        } else {
            None
        };
        let sha = info
            .as_ref()
            .map(|b| b.content_sha256.clone())
            .or(content_sha)
            .unwrap_or_default();
        let m = if valid_sha(&sha) {
            metadata(&db, &sha)?
        } else {
            empty("")
        };
        let (word_count, chapter_count, current_chapter) = if let Some(b) = &info {
            (
                db.query_row(
                    "SELECT COALESCE(MAX(end_char_count),0) FROM chunks WHERE book_id=?1",
                    [&b.id],
                    |r| unsigned_column(r, 0),
                )?,
                db.query_row(
                    "SELECT COUNT(*) FROM effective_chapters WHERE book_id=?1 AND level=1",
                    [&b.id],
                    |r| unsigned_column(r, 0),
                )?,
                library_tools::chapter(&db, &b.id, b.position_utf8)?.map(|c| c.title),
            )
        } else {
            (0, 0, None)
        };
        Ok(BookDetails {
            book: info,
            metadata: m,
            word_count,
            chapter_count,
            current_chapter,
        })
    }
    pub(crate) fn book_filter_options(
        &self,
        shelf_id: Option<String>,
    ) -> Result<BookFilterOptions> {
        let db = self.read_lock()?;
        let mut q = db.prepare(
            "SELECT DISTINCT m.value FROM library_files f
        JOIN file_identities fi ON fi.file_id=f.id
        JOIN book_metadata m ON m.content_sha=fi.content_sha256
        WHERE (?1 IS NULL OR f.shelf_id=?1)",
        )?;
        let mut authors = BTreeSet::new();
        let mut tags = BTreeSet::new();
        for row in q.query_map([shelf_id], |r| r.get::<_, String>(0))? {
            let m: BookMetadata =
                serde_json::from_str(&row?).map_err(|_| ReaderError::InvalidSettings)?;
            if !m.author.is_empty() {
                authors.insert(m.author);
            }
            tags.extend(m.tags);
        }
        Ok(BookFilterOptions {
            authors: authors.into_iter().collect(),
            tags: tags.into_iter().collect(),
        })
    }
}
