//! Supplemental information belongs to complete normalized text, never a file or import job.
use crate::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
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
    fn indexed_only_reading_status_is_shared_by_details_and_search() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        let sha = "a".repeat(64);
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        {
            let db = core.lock().unwrap();
            db.execute_batch("INSERT INTO library_files VALUES('indexed','s','novel.txt','','novel.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_identities VALUES('indexed','raw','auto',100,1);").unwrap();
            db.execute(
                "INSERT INTO source_identities VALUES('raw','auto',?1,'UTF-8',100,80)",
                [&sha],
            )
            .unwrap();
            assert_eq!(
                db.query_row("SELECT count(*) FROM books", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                0
            );
        }
        {
            let db = core.read_lock().unwrap();
            db.execute("INSERT INTO user_positions VALUES(?1,50,20,1,NULL)", [&sha])
                .unwrap();
        }
        let assert_status = |expected| {
            let BookDetailsResult::Identified { details, .. } = core
                .book_details(BookTarget::Record {
                    key: ReadingKey::Formal {
                        sha256: sha.clone(),
                    },
                })
                .unwrap()
            else {
                panic!("formal metadata should remain available without a local book")
            };
            assert!(details.body.is_none());
            assert_eq!(details.metadata.status, expected);
            let candidates = core
                .library_search_candidates(
                    CatalogueScope::Shelf {
                        shelf_id: "s".into(),
                        parent_path: String::new(),
                        recursive: true,
                    },
                    true,
                )
                .unwrap();
            assert_eq!(candidates.len(), 1);
            assert_eq!(
                candidates[0].entry.book().unwrap().formal_sha(),
                Some(sha.as_str())
            );
            assert_eq!(candidates[0].entry.book().unwrap().position_utf8, 50);
            assert_eq!(
                candidates[0].resolved_metadata.as_ref().unwrap().status,
                expected
            );
        };
        assert_status(BookReadingStatus::Reading);
        // An explicit finished/paused status still wins over the default.
        let mut stored = empty(&sha);
        stored.status = BookReadingStatus::Finished;
        core.read_lock()
            .unwrap()
            .execute(
                "INSERT INTO book_metadata VALUES(?1,?2)",
                rusqlite::params![sha, serde_json::to_string(&stored).unwrap()],
            )
            .unwrap();
        assert_status(BookReadingStatus::Finished);
        core.read_lock()
            .unwrap()
            .execute("DELETE FROM book_metadata", [])
            .unwrap();
        core.read_lock()
            .unwrap()
            .execute("UPDATE user_positions SET last_read=0", [])
            .unwrap();
        assert_status(BookReadingStatus::Unread);
    }

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

/// Formal reading-position truth shared by status projection and metadata imports.
pub(crate) fn has_reading_position(db: &Connection, sha: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM reading_content_positions WHERE content_sha256=?1)",
        [sha],
        |r| r.get::<_, bool>(0),
    )?)
}

pub(crate) fn metadata(db: &Connection, sha: &str) -> Result<BookMetadata> {
    let text: Option<String> = db
        .query_row(
            "SELECT value FROM book_metadata WHERE content_sha=?1",
            [sha],
            |r| r.get(0),
        )
        .optional()?;
    let stored = text
        .map(|v| serde_json::from_str(&v).map_err(|_| ReaderError::InvalidSettings))
        .transpose()?;
    let has_reading = has_reading_position(db, sha)?;
    Ok(project_metadata(sha, stored, has_reading))
}
/// Shared metadata defaults/status projection for details and catalogue batches.
pub(crate) fn project_metadata(
    sha: &str,
    stored: Option<BookMetadata>,
    has_reading: bool,
) -> BookMetadata {
    let mut result = stored.unwrap_or_else(|| empty(sha));
    if result.status == BookReadingStatus::Unread && has_reading {
        result.status = BookReadingStatus::Reading;
    }
    result
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn book_details(&self, target: BookTarget) -> Result<BookDetailsResult> {
        let db = self.read_lock()?;
        let identity = match crate::identity::content::resolve_target(&db, target)? {
            BookResolution::Unidentified { file_id } => {
                return Ok(BookDetailsResult::Unidentified { file_id });
            }
            BookResolution::Missing { target } => return Ok(BookDetailsResult::Missing { target }),
            BookResolution::Resolved { record } => record,
        };
        let body = match &identity.body {
            BodyAssociation::Absent => None,
            BodyAssociation::Associated { book_id } => {
                let info = book(&db, book_id)?;
                let word_count = db.query_row(
                    "SELECT COALESCE(MAX(end_char_count),0) FROM chunks WHERE book_id=?1",
                    [book_id],
                    |r| unsigned_column(r, 0),
                )?;
                let chapter_count = db.query_row(
                    "SELECT COUNT(*) FROM effective_chapters WHERE book_id=?1 AND level=1",
                    [book_id],
                    |r| unsigned_column(r, 0),
                )?;
                let current_chapter =
                    crate::library::tools::chapter(&db, book_id, info.position_utf8)?
                        .map(|c| c.title);
                Some(BookBodyDetails {
                    book: info,
                    word_count,
                    chapter_count,
                    current_chapter,
                })
            }
        };
        match &identity.key {
            ReadingKey::Formal { sha256 } => Ok(BookDetailsResult::Identified {
                details: BookDetails {
                    metadata: metadata(&db, sha256)?,
                    body,
                },
                identity,
            }),
            ReadingKey::Pending { .. } => Ok(BookDetailsResult::Pending { identity, body }),
        }
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
        #[derive(serde::Deserialize)]
        struct FilterMetadata {
            author: String,
            tags: Vec<String>,
        }
        let mut authors = BTreeSet::new();
        let mut tags = BTreeSet::new();
        for row in q.query_map([shelf_id], |r| r.get::<_, String>(0))? {
            let m: FilterMetadata =
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
