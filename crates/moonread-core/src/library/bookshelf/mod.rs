//! File metadata is an index of the platform's real directories. Content and
//! reading records remain independently keyed by the normalized text hash.
use crate::{ReaderCore, ReaderError, Result, SourceContentKey, valid_source_key};
use rusqlite::{Connection, params};
use std::collections::HashSet;

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
    pub directory: bool,
    pub size: u64,
    pub modified: i64,
    pub needs_download: bool,
    pub book_id: Option<String>,
    pub position_utf8: u64,
    pub byte_count: u64,
    pub chapter_title: Option<String>,
    pub child_book_count: u64,
    pub last_read: i64,
    pub preferred: bool,
    pub cover_previews: Vec<LibraryCoverPreview>,
    pub metadata: Option<crate::BookMetadata>,
    pub content_sha256: Option<String>,
    pub reading_identity: Option<crate::ReadingKey>,
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
    filtered_entries(db, shelf, parent, books_only, None, None)
}

fn filtered_entries(
    db: &Connection,
    shelf: Option<&str>,
    parent: Option<&str>,
    books_only: bool,
    file: Option<&str>,
    book: Option<&str>,
) -> Result<Vec<LibraryEntry>> {
    let mut stmt=db.prepare("SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,f.directory,f.size,f.modified,f.needs_download,
       b.id,COALESCE(p.position_utf8,0),COALESCE(si.utf8_bytes,b.byte_count,0),
       (SELECT title FROM effective_chapters c WHERE c.book_id=b.id AND c.start_utf8<=p.position_utf8 ORDER BY c.start_utf8 DESC LIMIT 1),
       CASE WHEN f.directory=1 THEN (SELECT count(*) FROM library_files child WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/') ELSE 0 END,
       CASE WHEN f.directory=1 THEN COALESCE((SELECT max(cp.last_read) FROM library_files child
           JOIN file_identities ci ON ci.file_id=child.id
           JOIN user_positions cp ON cp.content_key=ci.content_sha256
           WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/'),0)
           ELSE COALESCE(p.last_read,0) END,COALESCE(p.preferred_file_id=f.id,0),m.value,fi.content_sha256
       FROM library_files f JOIN library_shelves s ON s.id=f.shelf_id
       LEFT JOIN file_identities fi ON fi.file_id=f.id
       LEFT JOIN reading_books b ON b.id=fi.associated_book_id
       LEFT JOIN (SELECT content_sha256,MAX(utf8_bytes) utf8_bytes FROM source_identities GROUP BY content_sha256) si ON si.content_sha256=fi.content_sha256
       LEFT JOIN user_positions p ON p.content_key=fi.content_sha256
       LEFT JOIN book_metadata m ON m.content_sha=fi.content_sha256
       WHERE (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR f.parent_path=?2) AND (?3=0 OR f.directory=0) AND (?4 IS NULL OR f.id=?4) AND (?5 IS NULL OR b.id=?5)")?;
    Ok(stmt
        .query_map(
            params![shelf, parent, books_only, file, book],
            library_entry_row,
        )?
        .collect::<std::result::Result<_, _>>()?)
}

fn library_entry_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<LibraryEntry> {
    Ok(LibraryEntry {
        id: r.get(0)?,
        shelf_id: r.get(1)?,
        shelf_name: r.get(2)?,
        relative_path: r.get(3)?,
        parent_path: r.get(4)?,
        name: r.get(5)?,
        directory: r.get(6)?,
        size: r.get::<_, i64>(7)? as u64,
        modified: r.get(8)?,
        needs_download: r.get(9)?,
        book_id: r.get(10)?,
        position_utf8: r.get::<_, i64>(11)? as u64,
        byte_count: r.get::<_, i64>(12)? as u64,
        chapter_title: r.get(13)?,
        child_book_count: r.get::<_, i64>(14)? as u64,
        last_read: r.get(15)?,
        preferred: r.get(16)?,
        cover_previews: Vec::new(),
        metadata: metadata_column(r, 17)?,
        content_sha256: r.get(18)?,
        reading_identity: r
            .get::<_, Option<String>>(18)?
            .and_then(|s| crate::parse_reading_key(s).ok()),
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
        "SELECT f.id,f.name,m.value FROM library_files f
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
            Ok(LibraryCoverPreview {
                file_id: r.get(0)?,
                name: r.get(1)?,
                cover: metadata_column(r, 2)?.and_then(|m| m.cover),
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}

fn populate_cover_previews(db: &Connection, entries: &mut [LibraryEntry]) -> Result<()> {
    for folder in entries.iter_mut().filter(|e| e.directory) {
        folder.cover_previews = folder_cover_previews(db, &folder.shelf_id, &folder.relative_path)?;
    }
    Ok(())
}

fn metadata_column(
    r: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<crate::BookMetadata>> {
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
        let mut entries = entries(&db, shelf_id.as_deref(), parent_path.as_deref(), false)?;
        entries.sort_by(|a, b| crate::library::order::directory_order(a, b, sort));
        populate_cover_previews(&db, &mut entries)?;
        Ok(entries)
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
        if let Some(p) = &scope.parent_path {
            validate_relative(p, true)?;
        }
        let db = self.read_lock()?;
        let mut values = entries(
            &db,
            scope.shelf_id.as_deref(),
            if scope.recursive {
                None
            } else {
                scope.parent_path.as_deref()
            },
            books_only,
        )?;
        if scope.recursive
            && let Some(parent) = scope.parent_path.filter(|p| !p.is_empty())
        {
            let prefix = format!("{parent}/");
            values.retain(|e| e.relative_path.starts_with(&prefix));
        }
        values.sort_by(crate::library::order::file_order);
        let mut statement = db.prepare("SELECT content_sha256 FROM reading_content_positions")?;
        let reading: HashSet<String> = statement
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?;
        values
            .into_iter()
            .enumerate()
            .map(|(i, entry)| {
                let resolved_metadata = entry
                    .content_sha256
                    .as_ref()
                    .filter(|sha| crate::valid_sha(sha))
                    .map(|sha| {
                        crate::reading::book_details::project_metadata(
                            sha,
                            entry.metadata.clone(),
                            reading.contains(sha),
                        )
                    });
                Ok(LibrarySearchCandidate {
                    entry,
                    natural_order_ordinal: i as u64,
                    resolved_metadata,
                })
            })
            .collect()
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
        let mut tagged = std::collections::BTreeMap::<String, Vec<LibraryEntry>>::new();
        let mut untagged = Vec::new();
        let mut unindexed = Vec::new();
        for book in books {
            if book.content_sha256.is_none() {
                unindexed.push(book);
                continue;
            }
            let tags: std::collections::BTreeSet<_> = book
                .metadata
                .as_ref()
                .map(|m| m.tags.iter().collect())
                .unwrap_or_default();
            if tags.is_empty() {
                untagged.push(book);
            } else {
                for tag in tags {
                    tagged.entry(tag.clone()).or_default().push(book.clone());
                }
            }
        }
        let mut groups: Vec<_> = tagged
            .into_iter()
            .map(|(tag, entries)| LibraryTagGroup {
                kind: LibraryTagGroupKind::Tag,
                tag,
                entries,
            })
            .collect();
        groups.sort_by(|a, b| natural_cmp(&a.tag, &b.tag).then_with(|| a.tag.cmp(&b.tag)));
        for (kind, entries) in [
            (LibraryTagGroupKind::Untagged, untagged),
            (LibraryTagGroupKind::Unindexed, unindexed),
        ] {
            if !entries.is_empty() {
                groups.push(LibraryTagGroup {
                    kind,
                    tag: String::new(),
                    entries,
                });
            }
        }
        Ok(LibraryTagCatalogue { book_count, groups })
    }
    pub(crate) fn library_entry(&self, file_id: String) -> Result<LibraryEntry> {
        let db = self.read_lock()?;
        filtered_entries(&db, None, None, false, Some(&file_id), None)?
            .into_iter()
            .next()
            .ok_or(ReaderError::NotFound)
    }
    pub(crate) fn recent_library_entries(&self, limit: u32) -> Result<Vec<LibraryEntry>> {
        let db = self.read_lock()?;
        let mut statement = db.prepare(
            "WITH recent_positions AS (
                SELECT * FROM user_positions
                WHERE last_read>0 AND COALESCE(recent_visible,1)=1
            ), ranked AS (
                SELECT f.id,f.shelf_id,s.name shelf_name,f.relative_path,f.parent_path,f.name,
                    f.directory,f.size,f.modified,f.needs_download,
                    b.id book_id,
                    COALESCE(p.position_utf8,0) position_utf8,COALESCE(si.utf8_bytes,b.byte_count,0) byte_count,
                    (SELECT title FROM effective_chapters c WHERE c.book_id=b.id AND b.content_sha256=p.content_key
                        AND c.start_utf8<=p.position_utf8 ORDER BY c.start_utf8 DESC LIMIT 1) chapter_title,
                    0 child_book_count,p.last_read,COALESCE(p.preferred_file_id=f.id,0) preferred,
                    m.value,p.content_key,
                    ROW_NUMBER() OVER (PARTITION BY p.content_key ORDER BY COALESCE(p.preferred_file_id=f.id,0) DESC,f.id) chosen
                FROM recent_positions p
                JOIN file_identities fi ON fi.content_sha256=p.content_key
                JOIN library_files f ON f.id=fi.file_id
                JOIN library_shelves s ON s.id=f.shelf_id
                LEFT JOIN books b ON b.id=fi.associated_book_id
                LEFT JOIN (SELECT content_sha256,MAX(utf8_bytes) utf8_bytes FROM source_identities GROUP BY content_sha256) si ON si.content_sha256=fi.content_sha256
                LEFT JOIN book_metadata m ON m.content_sha=fi.content_sha256
            )
            SELECT * FROM ranked WHERE chosen=1
            ORDER BY last_read DESC,preferred DESC,id LIMIT ?1",
        )?;
        Ok(statement
            .query_map([limit.min(1000)], library_entry_row)?
            .collect::<std::result::Result<_, _>>()?)
    }
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
    pub natural_order_ordinal: u64,
    pub resolved_metadata: Option<crate::BookMetadata>,
}

mod mutations;
mod source;
pub(crate) use source::source_snapshots;
#[cfg(test)]
mod tests;
