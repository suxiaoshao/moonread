//! File metadata is an index of the platform's real directories. Content and
//! reading records remain independently keyed by the normalized text hash.
mod catalogue_cards;
pub use catalogue_cards::{LibrarySearchFields, LibraryTagMembership, LibraryTaggedCards};
pub(crate) mod full_index;
mod information_source;
mod metadata_exchange;
mod recent;
pub use metadata_exchange::*;
pub use recent::RecentLibraryRanking;

use crate::identity::content::reading_key_column;
use crate::{ReaderCore, ReaderError, Result, SourceContentKey, valid_source_key};
use rusqlite::{Connection, params};
use std::collections::HashSet;

// One copy-selection order, shared by the full catalogue and scoped recents.
pub(crate) const PREFERRED_SOURCE_ORDER: &str = "COALESCE(p.preferred_file_id=f.id,0) DESC,f.id";

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

use crate::library::order::natural_cmp;
pub(crate) use crate::storage::validation::relative as validate_relative;

fn entries(
    db: &Connection,
    shelf: Option<&str>,
    parent: Option<&str>,
    books_only: bool,
) -> Result<Vec<LibraryEntry>> {
    filtered_entries(db, shelf, parent, books_only, None, None, None)
}

const FOLDER_LAST_READ: &str = "CASE WHEN f.directory=1 THEN COALESCE((SELECT max(cp.last_read) FROM library_files child
           JOIN file_identities ci ON ci.file_id=child.id
           JOIN user_positions cp ON cp.content_key=ci.content_sha256
           WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/'),0)
           ELSE COALESCE(p.last_read,0) END";
static LIBRARY_ENTRIES_SQL: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
    format!("SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,f.directory,f.size,f.modified,f.needs_download,
       b.id,COALESCE(p.position_utf8,0),COALESCE(si.utf8_bytes,b.byte_count,0),
       (SELECT title FROM effective_chapters c WHERE c.book_id=b.id AND c.start_utf8<=p.position_utf8 ORDER BY c.start_utf8 DESC LIMIT 1),
       CASE WHEN f.directory=1 THEN (SELECT count(*) FROM library_files child WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/') ELSE 0 END,
       {FOLDER_LAST_READ},COALESCE(p.preferred_file_id=f.id,0),m.value,fi.content_sha256
       FROM library_files f JOIN library_shelves s ON s.id=f.shelf_id
       LEFT JOIN file_identities fi ON fi.file_id=f.id
       LEFT JOIN reading_books b ON b.id=fi.associated_book_id
       LEFT JOIN (SELECT content_sha256,MAX(utf8_bytes) utf8_bytes FROM source_identities GROUP BY content_sha256) si ON si.content_sha256=fi.content_sha256
       LEFT JOIN user_positions p ON p.content_key=fi.content_sha256
       LEFT JOIN book_metadata m ON m.content_sha=fi.content_sha256
       WHERE (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR f.parent_path=?2) AND (?3=0 OR f.directory=0) AND (?4 IS NULL OR f.id=?4) AND (?5 IS NULL OR b.id=?5) AND (?6 IS NULL OR fi.content_sha256=?6)")
});

fn card_entries(
    db: &Connection,
    shelf: Option<&str>,
    parent: Option<&str>,
    books_only: bool,
) -> Result<Vec<LibraryEntry>> {
    let mut statement = db.prepare_cached(&LIBRARY_ENTRIES_SQL)?;
    Ok(statement
        .query_map(
            params![
                shelf,
                parent,
                books_only,
                None::<String>,
                None::<String>,
                None::<String>
            ],
            library_card_row,
        )?
        .collect::<std::result::Result<_, _>>()?)
}

fn filtered_entries(
    db: &Connection,
    shelf: Option<&str>,
    parent: Option<&str>,
    books_only: bool,
    file: Option<&str>,
    book: Option<&str>,
    sha: Option<&str>,
) -> Result<Vec<LibraryEntry>> {
    let mut stmt = db.prepare_cached(&LIBRARY_ENTRIES_SQL)?;
    Ok(stmt
        .query_map(
            params![shelf, parent, books_only, file, book, sha],
            library_entry_row,
        )?
        .collect::<std::result::Result<_, _>>()?)
}

fn library_entry_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<LibraryEntry> {
    library_row(r, false)
}
fn library_card_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<LibraryEntry> {
    library_row(r, true)
}
fn library_row(r: &rusqlite::Row<'_>, card: bool) -> rusqlite::Result<LibraryEntry> {
    let id: String = r.get(0)?;
    let item = if r.get::<_, bool>(6)? {
        LibraryItem::Folder {
            row: FolderRow {
                child_book_count: r.get::<_, i64>(14)? as u64,
                cover_previews: Vec::new(),
            },
        }
    } else {
        let key = reading_key_column(r, 18)?;
        let resolution = if let Some(key) = key {
            crate::BookResolution::Resolved {
                record: crate::ResolvedBookRecord {
                    key,
                    body: r
                        .get::<_, Option<String>>(10)?
                        .map(|book_id| crate::BodyAssociation::Associated { book_id })
                        .unwrap_or(crate::BodyAssociation::Absent),
                    // This is a catalogue row, not a request to traverse historical aliases.
                    aliases: Vec::new(),
                },
            }
        } else {
            crate::BookResolution::Unidentified {
                file_id: id.clone(),
            }
        };
        LibraryItem::Book {
            row: Box::new(BookRow {
                resolution,
                needs_download: r.get(9)?,
                position_utf8: r.get::<_, i64>(11)? as u64,
                byte_count: r.get::<_, i64>(12)? as u64,
                chapter_title: r.get(13)?,
                preferred: r.get(16)?,
                metadata: if card { None } else { metadata_column(r, 17)? },
                card_metadata: if card {
                    decode_metadata_column(r, 17)?
                } else {
                    None
                },
            }),
        }
    };
    Ok(LibraryEntry {
        id,
        shelf_id: r.get(1)?,
        shelf_name: r.get(2)?,
        relative_path: r.get(3)?,
        parent_path: r.get(4)?,
        name: r.get(5)?,
        size: r.get::<_, i64>(7)? as u64,
        modified: r.get(8)?,
        last_read: r.get(15)?,
        item,
    })
}

#[cfg(test)]
thread_local! {
    static FOLDER_COVER_QUERIES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn folder_cover_previews(
    db: &Connection,
    shelf_id: &str,
    relative_path: &str,
) -> Result<Vec<LibraryCoverPreview>> {
    #[cfg(test)]
    FOLDER_COVER_QUERIES.with(|count| count.set(count.get() + 1));
    let mut stmt = db.prepare_cached(
        "SELECT f.id,f.name,m.value,fi.content_sha256 FROM library_files f
        LEFT JOIN file_identities fi ON fi.file_id=f.id
        LEFT JOIN user_positions p ON p.content_key=fi.content_sha256
        LEFT JOIN book_metadata m ON m.content_sha=fi.content_sha256
        WHERE f.shelf_id=?1 AND f.directory=0 AND f.relative_path>=?2 AND f.relative_path<?3
        ORDER BY COALESCE(p.last_read,0) DESC,f.modified DESC,f.name,f.id LIMIT 4",
    )?;
    // Literal path bounds also handle names containing SQL LIKE wildcards.
    let prefix = format!("{relative_path}/");
    let end = format!("{relative_path}0");
    Ok(stmt
        .query_map(params![shelf_id, prefix, end], |r| {
            let metadata: Option<LibraryCardMetadata> = decode_metadata_column(r, 2)?;
            Ok(LibraryCoverPreview {
                reading_key: reading_key_column(r, 3)?,
                author: metadata
                    .as_ref()
                    .map(|m| m.author.clone())
                    .filter(|a| !a.is_empty()),
                file_id: r.get(0)?,
                name: r.get(1)?,
                cover: metadata.and_then(|m| m.cover),
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}

fn populate_cover_previews(db: &Connection, entries: &mut [LibraryEntry]) -> Result<()> {
    for entry in entries {
        if let LibraryItem::Folder { row } = &mut entry.item {
            row.cover_previews = folder_cover_previews(db, &entry.shelf_id, &entry.relative_path)?;
        }
    }
    Ok(())
}

pub(crate) fn metadata_column(
    r: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<crate::BookMetadata>> {
    decode_metadata_column(r, index)
}

fn decode_metadata_column<T: serde::de::DeserializeOwned>(
    r: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<T>> {
    r.get::<_, Option<String>>(index)?
        .map(|text| {
            serde_json::from_str(&text).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    index,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })
        })
        .transpose()
}

// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    pub(crate) fn library_entries(
        &self,
        shelf_id: Option<String>,
        parent_path: Option<String>,
        sort: LibrarySort,
    ) -> Result<Vec<LibraryEntry>> {
        if let Some(parent) = &parent_path {
            validate_relative(parent, true)?;
        }
        let db = self.read_lock()?;
        // Rows, aggregates and cover candidates must see the same file index.
        let tx = db.unchecked_transaction()?;
        let mut entries = entries(&tx, shelf_id.as_deref(), parent_path.as_deref(), false)?;
        entries.sort_by(|a, b| crate::library::order::directory_order(a, b, sort));
        populate_cover_previews(&tx, &mut entries)?;
        tx.commit()?;
        Ok(entries)
    }
    pub(crate) fn library_directory_cards(
        &self,
        shelf_id: String,
        parent_path: String,
        sort: LibrarySort,
    ) -> Result<Vec<LibraryEntry>> {
        validate_relative(&parent_path, true)?;
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let mut entries = card_entries(&tx, Some(&shelf_id), Some(&parent_path), false)?;
        entries.sort_by(|a, b| crate::library::order::directory_order(a, b, sort));
        populate_cover_previews(&tx, &mut entries)?;
        tx.commit()?;
        Ok(entries)
    }
    pub(crate) fn library_directory_detail_keys(
        &self,
        shelf_id: String,
        parent_path: String,
    ) -> Result<LibraryDirectoryDetailKeys> {
        validate_relative(&parent_path, true)?;
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let mut stmt = tx.prepare_cached(
            "SELECT f.shelf_id,f.relative_path,f.directory,fi.content_sha256
             FROM library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id
             WHERE f.shelf_id=?1 AND f.parent_path=?2",
        )?;
        let mut rows = stmt.query(params![shelf_id, parent_path])?;
        directory_detail_keys(&tx, &mut rows)
    }
    pub(crate) fn library_folder_cover_previews(
        &self,
        shelf_id: String,
        relative_path: String,
    ) -> Result<Vec<LibraryCoverPreview>> {
        validate_relative(&relative_path, false)?;
        let db = self.read_lock()?;
        folder_cover_previews(&db, &shelf_id, &relative_path)
    }

    pub(crate) fn library_search_candidates(
        &self,
        scope: crate::CatalogueScope,
        books_only: bool,
    ) -> Result<Vec<LibrarySearchCandidate>> {
        let (shelf, parent, recursive) = scope.sql_scope();
        if let Some(p) = parent {
            validate_relative(p, true)?;
        }
        let db = self.read_lock()?;
        let mut values = entries(
            &db,
            shelf,
            if recursive { None } else { parent },
            books_only,
        )?;
        if recursive && let Some(parent) = parent.filter(|p| !p.is_empty()) {
            let prefix = format!("{parent}/");
            values.retain(|e| e.relative_path.starts_with(&prefix));
        }
        search_candidates(&db, values, false)
    }
    /// The complete file catalogue of one shelf, including nested directories.
    /// Copies remain separate file entries; no document is read or downloaded.
    pub(crate) fn all_library_books(&self, shelf_id: String) -> Result<Vec<LibraryEntry>> {
        let db = self.read_lock()?;
        let mut books = entries(&db, Some(&shelf_id), None, true)?;
        books.sort_by(crate::library::order::file_order);
        Ok(books)
    }
    /// Identity and metadata are projected through file_identities by all_library_books.
    /// A multi-tagged file is repeated in its sections, but counted only once.
    pub(crate) fn all_library_tag_groups(&self, shelf_id: String) -> Result<LibraryTagCatalogue> {
        let books = self.all_library_books(shelf_id)?;
        let book_count = books.len() as u64;
        let members = catalogue_cards::tag_memberships(&books);
        let cards: std::collections::HashMap<_, _> = books
            .into_iter()
            .map(|book| (book.id.clone(), book))
            .collect();
        let groups = members
            .into_iter()
            .map(|group| LibraryTagGroup {
                kind: group.kind,
                tag: group.tag,
                entries: group.file_ids.iter().map(|id| cards[id].clone()).collect(),
            })
            .collect();
        Ok(LibraryTagCatalogue { book_count, groups })
    }
    pub(crate) fn library_entry(&self, file_id: String) -> Result<LibraryEntry> {
        let db = self.read_lock()?;
        filtered_entries(&db, None, None, false, Some(&file_id), None, None)?
            .into_iter()
            .next()
            .ok_or(ReaderError::NotFound)
    }
}

fn directory_detail_keys(
    db: &Connection,
    rows: &mut rusqlite::Rows<'_>,
) -> Result<LibraryDirectoryDetailKeys> {
    let mut direct = HashSet::new();
    let mut covers = HashSet::new();
    while let Some(row) = rows.next()? {
        if row.get::<_, bool>(2)? {
            let shelf: String = row.get(0)?;
            let path: String = row.get(1)?;
            covers.extend(
                folder_cover_previews(db, &shelf, &path)?
                    .into_iter()
                    .filter_map(|preview| preview.reading_key),
            );
        } else if let Some(key) = reading_key_column(row, 3)? {
            direct.insert(key);
        }
    }
    Ok(LibraryDirectoryDetailKeys {
        covers: covers.difference(&direct).cloned().collect(),
        direct: direct.into_iter().collect(),
    })
}

fn search_candidates(
    db: &Connection,
    mut values: Vec<LibraryEntry>,
    narrow: bool,
) -> Result<Vec<LibrarySearchCandidate>> {
    values.sort_by(crate::library::order::file_order);
    let mut statement = db.prepare("SELECT content_sha256 FROM reading_content_positions")?;
    let reading: HashSet<String> = statement
        .query_map([], |r| r.get(0))?
        .collect::<std::result::Result<_, _>>()?;
    let mut previous_name = None::<String>;
    let mut name_ordinal = 0_u64;
    values
        .into_iter()
        .enumerate()
        .map(|(i, mut entry)| {
            if previous_name
                .as_ref()
                .is_some_and(|name| !natural_cmp(name, &entry.name).is_eq())
            {
                name_ordinal += 1;
            }
            previous_name = Some(entry.name.clone());
            let resolved_metadata = entry.book().and_then(|book| {
                book.formal_sha().map(|sha| {
                    crate::reading::book_details::project_metadata(
                        sha,
                        book.metadata.clone(),
                        reading.contains(sha),
                    )
                })
            });
            let (resolved_metadata, match_fields) = if narrow {
                let stored = match &mut entry.item {
                    LibraryItem::Book { row } => row.metadata.take(),
                    LibraryItem::Folder { .. } => None,
                };
                let has_stored = stored.is_some();
                let fields = resolved_metadata.or(stored).map(|m| LibrarySearchFields {
                    author: m.author,
                    tags: m.tags,
                    status: m.status,
                    stored: has_stored,
                });
                (None, fields)
            } else {
                (resolved_metadata, None)
            };
            Ok(LibrarySearchCandidate {
                entry,
                natural_order_ordinal: i as u64,
                natural_name_ordinal: name_ordinal,
                resolved_metadata,
                match_fields,
            })
        })
        .collect()
}

/// Authorized file location and verified text association, without user presentation data.
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
mod mutations;
mod source;
pub use decoding_migration::*;
pub(crate) use source::source_snapshots;
#[cfg(test)]
mod tests;

mod system_reading;
pub use system_reading::SystemReadingBookProjection;
