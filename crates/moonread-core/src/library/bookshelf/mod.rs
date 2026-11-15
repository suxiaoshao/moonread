//! File metadata is an index of the platform's real directories. Content and
//! reading records remain independently keyed by the normalized text hash.
mod catalogue_cards;
pub use catalogue_cards::{LibrarySearchFields, LibraryTagMembership, LibraryTaggedCards};
pub(crate) mod full_index;
mod metadata_exchange;
use crate::SourceContentKey;
pub use metadata_exchange::*;

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryShelf {
    pub id: String,
    pub name: String,
    pub bookmark: Vec<u8>,
    pub location: String,
    pub builtin: bool,
    pub error: Option<String>,
    pub book_count: u64,
}

/// Journal location carried only after Swift verifies both copies' raw bytes.
#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryHandoffFile {
    pub file_id: String,
    pub book_id: Option<String>,
    pub source: SourceContentKey,
    pub relative_path: String,
}

/// Platform metadata only. Scanning never requires hashing or reading a novel.
#[derive(Clone, Debug, uniffi::Record)]
pub struct ScannedLibraryItem {
    pub relative_path: String,
    pub directory: bool,
    pub size: u64,
    pub modified: i64,
    pub needs_download: bool,
}

/// File index only; no reading/user-data projection is needed to admit a source.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceFileSnapshot {
    pub id: String,
    pub shelf_id: String,
    pub relative_path: String,
    pub size: u64,
    pub modified: i64,
    pub needs_download: bool,
    pub book_id: Option<String>,
    pub decoding: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryCoverPreview {
    pub file_id: String,
    pub name: String,
    pub reading_key: Option<crate::ReadingKey>,
    pub author: Option<String>,
    pub cover: Option<crate::BookCoverAsset>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryEntry {
    pub id: String,
    pub shelf_id: String,
    pub shelf_name: String,
    pub relative_path: String,
    pub parent_path: String,
    pub name: String,
    pub size: u64,
    pub modified: i64,
    pub last_read: i64,
    pub item: LibraryItem,
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum LibraryItem {
    Folder { row: FolderRow },
    Book { row: Box<BookRow> },
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FolderRow {
    pub child_book_count: u64,
    pub cover_previews: Vec<LibraryCoverPreview>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize, uniffi::Record)]
pub struct LibraryCardMetadata {
    pub author: String,
    pub cover: Option<crate::BookCoverAsset>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryDirectoryDetailKeys {
    pub direct: Vec<crate::ReadingKey>,
    pub covers: Vec<crate::ReadingKey>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct BookRow {
    pub resolution: crate::BookResolution,
    pub needs_download: bool,
    pub position_utf8: u64,
    pub byte_count: u64,
    pub chapter_title: Option<String>,
    pub preferred: bool,
    pub metadata: Option<crate::BookMetadata>,
    pub card_metadata: Option<LibraryCardMetadata>,
}

impl LibraryEntry {
    pub fn book(&self) -> Option<&BookRow> {
        match &self.item {
            LibraryItem::Book { row } => Some(row),
            LibraryItem::Folder { .. } => None,
        }
    }

    pub fn folder(&self) -> Option<&FolderRow> {
        match &self.item {
            LibraryItem::Folder { row } => Some(row),
            LibraryItem::Book { .. } => None,
        }
    }
}

impl BookRow {
    pub fn key(&self) -> Option<&crate::ReadingKey> {
        match &self.resolution {
            crate::BookResolution::Resolved { record } => Some(&record.key),
            _ => None,
        }
    }

    pub fn book_id(&self) -> Option<&str> {
        match &self.resolution {
            crate::BookResolution::Resolved {
                record:
                    crate::ResolvedBookRecord {
                        body: crate::BodyAssociation::Associated { book_id },
                        ..
                    },
            } => Some(book_id),
            _ => None,
        }
    }

    pub fn formal_sha(&self) -> Option<&str> {
        self.key().and_then(crate::ReadingKey::formal_sha)
    }
}

/// A virtual tag section in one shelf's file catalogue, never a filesystem folder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum LibraryTagGroupKind {
    Tag,
    Untagged,
    Unindexed,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryTagGroup {
    pub kind: LibraryTagGroupKind,
    pub tag: String,
    pub entries: Vec<LibraryEntry>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryTagCatalogue {
    pub book_count: u64,
    pub groups: Vec<LibraryTagGroup>,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum LibrarySort {
    Reading,
    Name,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceFileLocation {
    pub id: String,
    pub directory: bool,
    pub shelf_id: String,
    pub relative_path: String,
    pub book_id: Option<String>,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct LibrarySearchCandidate {
    pub entry: LibraryEntry,
    /// Equal natural names share a rank, so later explicit sort keys can break ties.
    pub natural_name_ordinal: u64,
    pub natural_order_ordinal: u64,
    pub resolved_metadata: Option<crate::BookMetadata>,
    pub match_fields: Option<LibrarySearchFields>,
}

mod decoding_migration;
pub use decoding_migration::*;

mod system_reading;
pub use system_reading::SystemReadingBookProjection;
