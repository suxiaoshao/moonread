//! File metadata is an index of the platform's real directories. Content and
//! reading records remain independently keyed by the normalized text hash.
use crate::{ReaderCore, ReaderError, Result, SourceContentKey, library_tools, valid_source_key};
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

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

use crate::library_order::natural_cmp;
pub(crate) use crate::validation::relative as validate_relative;

#[uniffi::export]
impl ReaderCore {
    pub fn save_library_shelf(
        &self,
        id: String,
        name: String,
        bookmark: Vec<u8>,
        location: String,
        builtin: bool,
    ) -> Result<()> {
        if id.is_empty() || name.trim().is_empty() || builtin != (id == "builtin") {
            return Err(ReaderError::InvalidSettings);
        }
        self.lock()?.execute("INSERT INTO library_shelves(id,name,bookmark,location,builtin) VALUES(?1,?2,?3,?4,?5)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name,bookmark=excluded.bookmark,location=excluded.location,error=NULL",
            params![id,name,bookmark,location,builtin])?;
        Ok(())
    }

    pub fn library_shelves(&self) -> Result<Vec<LibraryShelf>> {
        let db = self.read_lock()?;
        let mut stmt = db.prepare(
            "SELECT id,name,bookmark,location,builtin,error,
          (SELECT count(*) FROM library_files f WHERE f.shelf_id=s.id AND f.directory=0)
          FROM library_shelves s ORDER BY builtin DESC,rowid",
        )?;
        Ok(stmt
            .query_map([], |r| {
                Ok(LibraryShelf {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    bookmark: r.get(2)?,
                    location: r.get(3)?,
                    builtin: r.get(4)?,
                    error: r.get(5)?,
                    book_count: r.get::<_, i64>(6)? as u64,
                })
            })?
            .collect::<std::result::Result<_, _>>()?)
    }

    pub fn set_library_shelf_error(&self, shelf_id: String, message: Option<String>) -> Result<()> {
        self.lock()?.execute(
            "UPDATE library_shelves SET error=?1 WHERE id=?2",
            params![message, shelf_id],
        )?;
        Ok(())
    }

    pub fn remove_library_shelf(&self, shelf_id: String) -> Result<()> {
        if shelf_id == "builtin" {
            return Err(ReaderError::InvalidSettings);
        }
        self.lock()?.execute(
            "DELETE FROM library_shelves WHERE id=?1 AND builtin=0",
            [shelf_id],
        )?;
        Ok(())
    }

    /// Replace the index only after a complete, successful platform scan.
    /// Failed/inaccessible sources keep their last known list.
    pub fn scan_library_shelf(
        &self,
        shelf_id: String,
        items: Vec<ScannedLibraryItem>,
    ) -> Result<()> {
        self.scan_library_shelf_partial(shelf_id, items, Vec::new())
    }

    /// Inaccessible paths retain their previous rows (including descendants),
    /// while accessible portions still reconcile additions/removals normally.
    pub fn scan_library_shelf_partial(
        &self,
        shelf_id: String,
        mut items: Vec<ScannedLibraryItem>,
        failed_paths: Vec<String>,
    ) -> Result<()> {
        for path in &failed_paths {
            validate_relative(path, true)?;
        }
        let mut db = self.lock()?;
        if !failed_paths.is_empty() {
            let mut seen: HashSet<String> = items.iter().map(|i| i.relative_path.clone()).collect();
            let mut statement = db.prepare("SELECT relative_path,directory,size,modified,needs_download FROM library_files WHERE shelf_id=?1")?;
            let old = statement.query_map([&shelf_id], |r| {
                Ok(ScannedLibraryItem {
                    relative_path: r.get(0)?,
                    directory: r.get(1)?,
                    size: r.get::<_, i64>(2)? as u64,
                    modified: r.get(3)?,
                    needs_download: r.get(4)?,
                })
            })?;
            for row in old {
                let row = row?;
                if failed_paths.iter().any(|p| {
                    p.is_empty()
                        || row.relative_path == *p
                        || row.relative_path.starts_with(&format!("{p}/"))
                }) && seen.insert(row.relative_path.clone())
                {
                    items.push(row);
                }
            }
        }
        let mut paths = HashSet::new();
        for item in &items {
            validate_relative(&item.relative_path, false)?;
            if item.size > i64::MAX as u64 {
                return Err(ReaderError::InvalidSettings);
            }
            if !paths.insert(item.relative_path.clone()) {
                return Err(ReaderError::InvalidSettings);
            }
        }
        let tx = db.transaction()?;
        let old = {
            let mut stmt = tx.prepare(
                "SELECT id,relative_path,directory,book_id,decoding FROM library_files WHERE shelf_id=?1",
            )?;
            stmt.query_map([&shelf_id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, bool>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?
        };
        let by_path: HashMap<_, _> = old.iter().map(|r| (r.1.as_str(), r)).collect();
        tx.execute("DELETE FROM library_files WHERE shelf_id=?1", [&shelf_id])?;
        for item in items {
            let previous = by_path
                .get(item.relative_path.as_str())
                .filter(|p| p.2 == item.directory);
            let id = previous
                .map(|p| p.0.clone())
                .unwrap_or_else(|| Uuid::new_v4().to_string());
            let book_id = previous
                .filter(|_| !item.directory)
                .and_then(|p| p.3.clone());
            let (parent, name) = item
                .relative_path
                .rsplit_once('/')
                .unwrap_or(("", &item.relative_path));
            tx.execute("INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id,decoding) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",params![id,shelf_id,item.relative_path,parent,name,item.directory,item.size as i64,item.modified,item.needs_download,book_id,previous.map(|p| p.4.as_str()).unwrap_or("auto")])?;
        }
        tx.execute(
            "UPDATE library_shelves SET error=NULL WHERE id=?1",
            [shelf_id],
        )?;
        tx.execute(
            "DELETE FROM library_identities WHERE file_id NOT IN (SELECT id FROM library_files)",
            [],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn link_library_file(&self, file_id: String, book_id: String) -> Result<()> {
        let db = self.lock()?;
        let canonical = library_tools::content_key(&db, &book_id)?;
        db.execute(
            "UPDATE library_files SET book_id=?1 WHERE id=?2 AND directory=0",
            params![canonical, file_id],
        )?;
        db.execute(
            "UPDATE import_jobs SET library_file_id=?1 WHERE book_id=?2",
            params![file_id, book_id],
        )?;
        Ok(())
    }

    /// Background restoration never publishes a draft. A final verified text and
    /// the exact admitted source row must still agree in this one transaction.
    pub fn link_restored_library_file(
        &self,
        file: SourceFileSnapshot,
        decoding: String,
        book_id: String,
        content_sha256: String,
    ) -> Result<bool> {
        let decoding = crate::decoding_policy(&decoding)?;
        let db = self.lock()?;
        Ok(db.execute(
            "UPDATE library_files SET book_id=?1,decoding=?2 WHERE id=?3 AND directory=0 AND shelf_id=?4 AND relative_path=?5 AND size=?6 AND modified=?7 AND decoding=?8 AND book_id IS ?9 AND EXISTS(SELECT 1 FROM books b WHERE b.id=?1 AND b.content_sha256=?10)",
            params![book_id,decoding,file.id,file.shelf_id,file.relative_path,file.size as i64,file.modified,file.decoding,file.book_id,content_sha256],
        )? == 1)
    }

    /// Publish the journal and fixed root atomically. No raw mapping is created
    /// by moving a file: the saved book is only its last-known association.
    pub fn publish_library_handoff(
        &self,
        bookmark: Vec<u8>,
        files: Vec<LibraryHandoffFile>,
    ) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let mut ids = HashSet::new();
        for file in files {
            validate_relative(&file.relative_path, false)?;
            if !ids.insert(file.file_id.clone()) || !valid_source_key(&file.source) {
                return Err(ReaderError::InvalidSettings);
            }
            let current: Option<String> = tx
                .query_row(
                    "SELECT book_id FROM library_files WHERE id=?1 AND directory=0",
                    [&file.file_id],
                    |r| r.get(0),
                )
                .optional()?
                .flatten();
            let canonical = current
                .or(file.book_id)
                .map(|id| library_tools::content_key(&tx, &id))
                .transpose();
            let book = match canonical {
                Ok(book) => book,
                Err(ReaderError::NotFound) => tx
                    .query_row(
                        "SELECT book_id FROM source_imports WHERE raw_sha256=?1 AND decoding=?2",
                        params![file.source.raw_sha256, file.source.decoding],
                        |r| r.get::<_, String>(0),
                    )
                    .optional()?,
                Err(e) => return Err(e),
            };
            let (parent, name) = file
                .relative_path
                .rsplit_once('/')
                .unwrap_or(("", &file.relative_path));
            tx.execute("DELETE FROM library_files WHERE shelf_id='builtin' AND relative_path=?1 AND id<>?2",params![file.relative_path,file.file_id])?;
            tx.execute("UPDATE library_files SET shelf_id='builtin',relative_path=?1,parent_path=?2,name=?3,book_id=?4 WHERE id=?5",params![file.relative_path,parent,name,book,file.file_id])?;
        }
        if tx.execute("UPDATE library_shelves SET bookmark=?1,location='icloud',error=NULL WHERE id='builtin'",[bookmark])? != 1 { return Err(ReaderError::NotFound); }
        tx.commit()?;
        Ok(())
    }

    /// Applied only after the platform successfully moves the actual file tree.
    pub fn relocate_library_entry(
        &self,
        file_id: String,
        target_shelf: String,
        target_path: String,
    ) -> Result<()> {
        validate_relative(&target_path, false)?;
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let (shelf, old): (String, String) = tx.query_row(
            "SELECT shelf_id,relative_path FROM library_files WHERE id=?1",
            [&file_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let prefix = format!("{old}/");
        let changed = {
            let mut s=tx.prepare("SELECT id,relative_path FROM library_files WHERE shelf_id=?1 AND (relative_path=?2 OR substr(relative_path,1,length(?3))=?3)")?;
            s.query_map(params![shelf, old, prefix], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?
        };
        for (id, path) in changed {
            let path = format!("{}{}", target_path, &path[old.len()..]);
            let (parent, name) = path.rsplit_once('/').unwrap_or(("", &path));
            tx.execute(
                "DELETE FROM library_files WHERE shelf_id=?1 AND relative_path=?2 AND id<>?3",
                params![target_shelf, path, id],
            )?;
            tx.execute("UPDATE library_files SET shelf_id=?1,relative_path=?2,parent_path=?3,name=?4 WHERE id=?5",params![target_shelf,path,parent,name,id])?;
        }
        tx.commit()?;
        Ok(())
    }
}

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
        entries.sort_by(|a, b| crate::library_order::directory_order(a, b, sort));
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
        values.sort_by(crate::library_order::file_order);
        let mut statement =
            db.prepare("SELECT DISTINCT content_sha256 FROM reading_books WHERE last_read>0")?;
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
                        crate::book_details::project_metadata(
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
        books.sort_by(crate::library_order::file_order);
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
#[uniffi::export]
impl ReaderCore {
    pub fn source_file_snapshots(
        &self,
        file_id: Option<String>,
    ) -> Result<Vec<SourceFileSnapshot>> {
        let db = self.lock()?;
        if let Some(id) = file_id {
            source_snapshots(&db, "WHERE f.id=?1 AND f.directory=0", [id])
        } else {
            source_snapshots(&db, "WHERE f.directory=0 ORDER BY f.id", [])
        }
    }

    pub fn source_decoding(&self, file_id: String) -> Result<String> {
        Ok(self.lock()?.query_row(
            "SELECT decoding FROM library_files WHERE id=?1 AND directory=0",
            [file_id],
            |r| r.get(0),
        )?)
    }
    pub fn set_source_decoding(&self, file_id: String, decoding: String) -> Result<()> {
        let policy = crate::decoding_policy(&decoding)?;
        let db = self.lock()?;
        if db.execute(
            "UPDATE library_files SET decoding=?1 WHERE id=?2 AND directory=0",
            params![policy, file_id],
        )? == 0
        {
            return Err(ReaderError::InvalidSettings);
        }
        Ok(())
    }

    pub fn source_file_location(&self, file_id: String) -> Result<SourceFileLocation> {
        let entry = self.library_entry(file_id)?;
        Ok(SourceFileLocation {
            id: entry.id,
            directory: entry.directory,
            shelf_id: entry.shelf_id,
            relative_path: entry.relative_path,
            book_id: entry.book_id,
        })
    }
}

#[uniffi::export]
impl ReaderCore {
    /// File operations consume index locations, never a user-facing book projection.
    pub fn source_files(&self, shelf_id: String) -> Result<Vec<SourceFileLocation>> {
        Ok(self
            .library_entries(Some(shelf_id), None, LibrarySort::Name)?
            .into_iter()
            .map(|entry| SourceFileLocation {
                id: entry.id,
                directory: entry.directory,
                shelf_id: entry.shelf_id,
                relative_path: entry.relative_path,
                book_id: entry.book_id,
            })
            .collect())
    }
}

#[cfg(test)]
mod recent_tests {
    use super::*;

    #[test]
    fn partial_scan_preserves_only_inaccessible_paths_and_their_associations() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        let file = |path: &str| ScannedLibraryItem {
            relative_path: path.into(),
            directory: false,
            size: 10,
            modified: 1,
            needs_download: false,
        };
        core.scan_library_shelf(
            "s".into(),
            vec![
                file("bad/keep.txt"),
                file("bad-sibling/gone.txt"),
                file("deleted.txt"),
            ],
        )
        .unwrap();
        let before = core
            .source_files("s".into())
            .unwrap()
            .into_iter()
            .find(|f| f.relative_path == "bad/keep.txt")
            .unwrap();
        core.scan_library_shelf_partial("s".into(), vec![file("new.txt")], vec!["bad".into()])
            .unwrap();
        let after = core.source_files("s".into()).unwrap();
        assert_eq!(after.len(), 2);
        assert!(
            after
                .iter()
                .any(|f| f.id == before.id && f.relative_path == "bad/keep.txt")
        );
        assert!(after.iter().any(|f| f.relative_path == "new.txt"));
        core.scan_library_shelf("s".into(), vec![]).unwrap();
        assert!(core.source_files("s".into()).unwrap().is_empty());
    }

    #[test]
    fn search_candidates_leave_unmatched_folder_covers_unqueried() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        core.lock().unwrap().execute_batch(
            "INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
             INSERT INTO library_files VALUES('book','s','folder/book.txt','folder','book.txt',0,100,1,0,NULL,'auto');"
        ).unwrap();
        let query = core.query_snapshot("{}".into()).unwrap();
        let before = FOLDER_COVER_QUERIES.with(|count| count.get());
        let candidates = query
            .library_search_candidates(
                crate::CatalogueScope {
                    shelf_id: Some("s".into()),
                    parent_path: None,
                    recursive: true,
                },
                false,
            )
            .unwrap();
        assert!(candidates.iter().any(|c| c.entry.directory));
        assert!(candidates.iter().all(|c| c.entry.cover_previews.is_empty()));
        // Matching happens in Swift; an unmatched search stops here without any cover SQL.
        assert_eq!(FOLDER_COVER_QUERIES.with(|count| count.get()), before);
        let covers = query
            .library_folder_cover_previews("s".into(), "folder".into())
            .unwrap();
        assert_eq!(covers[0].file_id, "book");
        assert_eq!(FOLDER_COVER_QUERIES.with(|count| count.get()), before + 1);
    }

    #[test]
    fn tag_groups_repeat_multitagged_files_and_separate_identity_states_within_shelf() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        for shelf in ["s", "other"] {
            core.save_library_shelf(shelf.into(), shelf.into(), vec![], "local".into(), false)
                .unwrap();
        }
        {
            let db = core.lock().unwrap();
            db.execute_batch("INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('tagged','s','folder/tagged.txt','folder','tagged.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('untagged','s','untagged.txt','','untagged.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('unknown','s','unknown.txt','','unknown.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('stale','s','stale.txt','','stale.txt',0,101,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('outside','other','outside.txt','','outside.txt',0,100,1,0,NULL,'auto');
                INSERT INTO source_identities VALUES('raw','auto','tagged-sha','UTF-8',100,80);
                INSERT INTO source_identities VALUES('raw-untagged','auto','untagged-sha','UTF-8',100,80);
                INSERT INTO library_identities VALUES('tagged','raw','auto',100,1);
                INSERT INTO library_identities VALUES('untagged','raw-untagged','auto',100,1);
                INSERT INTO library_identities VALUES('stale','raw','auto',100,1);
                INSERT INTO library_identities VALUES('outside','raw','auto',100,1);").unwrap();
        }
        let query = core.query_snapshot(serde_json::json!({"metadata": [{
            "sha": "tagged-sha", "author": "", "synopsis": "", "tags": ["B", "A"], "cover": null, "status": "Unread"
        }]}).to_string()).unwrap();
        let catalogue = query.all_library_tag_groups("s".into()).unwrap();
        assert_eq!(catalogue.book_count, 4);
        assert_eq!(
            catalogue.groups.iter().map(|g| g.kind).collect::<Vec<_>>(),
            [
                LibraryTagGroupKind::Tag,
                LibraryTagGroupKind::Tag,
                LibraryTagGroupKind::Untagged,
                LibraryTagGroupKind::Unindexed
            ]
        );
        assert_eq!(
            catalogue
                .groups
                .iter()
                .map(|g| g.tag.as_str())
                .collect::<Vec<_>>(),
            ["A", "B", "", ""]
        );
        let ids = |i: usize| {
            catalogue.groups[i]
                .entries
                .iter()
                .map(|e| e.id.as_str())
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(0), ["tagged"]);
        assert_eq!(ids(1), ["tagged"]);
        assert_eq!(ids(2), ["untagged"]);
        assert_eq!(ids(3), ["stale", "unknown"]);
        assert!(
            catalogue
                .groups
                .iter()
                .flat_map(|g| &g.entries)
                .all(|e| e.shelf_id == "s" && !e.directory)
        );
    }

    #[test]
    fn folder_last_read_includes_index_only_child_with_synced_position() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        let sha = "a".repeat(64);
        {
            let db = core.lock().unwrap();
            db.execute_batch("INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('indexed','s','folder/indexed.txt','folder','indexed.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_identities VALUES('indexed','raw','auto',100,1);
                INSERT INTO books(id,title,content_sha256,encoding,byte_count) VALUES('cached','Cached','cached-sha','UTF-8',100);
                INSERT INTO library_files VALUES('cached-file','s','folder/cached.txt','folder','cached.txt',0,100,999,0,'cached','auto');").unwrap();
            db.execute(
                "INSERT INTO source_identities VALUES('raw','auto',?1,'UTF-8',100,80)",
                [&sha],
            )
            .unwrap();
        }
        let query = core
            .query_snapshot(
                serde_json::json!({"positions": [{
            "content_key": sha, "offset": 50, "updated": 123456, "visible": true, "preferred": null
        },{"content_key":"cached-sha","offset":10,"updated":10,"visible":true,"preferred":null}]})
                .to_string(),
            )
            .unwrap();
        let folder = query
            .library_entries(Some("s".into()), Some("".into()), LibrarySort::Reading)
            .unwrap()
            .remove(0);
        assert!(folder.directory);
        assert_eq!(folder.last_read, 123456);
        let child = query.library_entry("indexed".into()).unwrap();
        assert!(child.book_id.is_none());
        assert_eq!(child.last_read, folder.last_read);
        // Two paths to one SHA both inherit it; replacing the input snapshot can
        // lower a folder's time (no monotonically increasing UI-side max).
        core.lock().unwrap().execute_batch("INSERT INTO library_files VALUES('second-folder','s','second','','second',1,0,1,0,NULL,'auto'); INSERT INTO library_files VALUES('second-copy','s','second/copy.txt','second','copy.txt',0,100,1,0,NULL,'auto'); INSERT INTO library_identities VALUES('second-copy','raw','auto',100,1);").unwrap();
        let lower=core.query_snapshot(serde_json::json!({"positions":[{"content_key":sha,"offset":20,"updated":5,"visible":true,"preferred":null}]}).to_string()).unwrap();
        let folders = lower
            .library_entries(Some("s".into()), Some("".into()), LibrarySort::Reading)
            .unwrap();
        assert!(folders.iter().all(|f| f.last_read == 5));

        assert_eq!(
            folder
                .cover_previews
                .iter()
                .map(|p| p.file_id.as_str())
                .collect::<Vec<_>>(),
            ["indexed", "cached-file"],
            "preview order must follow the same projected reading times"
        );
    }

    #[test]
    fn recent_entries_include_index_only_and_null_visibility() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        {
            let db = core.lock().unwrap();
            db.execute_batch("INSERT INTO books(id,title,content_sha256,encoding,byte_count) VALUES('prepared','Prepared','prepared-sha','UTF-8',100);
                INSERT INTO library_files VALUES('prepared-file','s','prepared.txt','','prepared.txt',0,100,1,0,'prepared','auto');
                INSERT INTO library_files VALUES('indexed-file','s','indexed.txt','','indexed.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('indexed-copy','s','copy.txt','','copy.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('hidden-file','s','hidden.txt','','hidden.txt',0,100,1,0,NULL,'auto');
                INSERT INTO source_identities VALUES('raw-index','auto','indexed-sha','UTF-8',100,80);
                INSERT INTO source_identities VALUES('raw-hidden','auto','hidden-sha','UTF-8',100,80);
                INSERT INTO library_identities VALUES('indexed-file','raw-index','auto',100,1);
                INSERT INTO library_identities VALUES('indexed-copy','raw-index','auto',100,1);
                INSERT INTO library_identities VALUES('hidden-file','raw-hidden','auto',100,1);").unwrap();
        }
        core.read_lock()
            .unwrap()
            .execute_batch(
                "INSERT INTO user_positions VALUES('prepared-sha',25,10,NULL,NULL);
            INSERT INTO user_positions VALUES('indexed-sha',50,20,NULL,'indexed-file');
            INSERT INTO user_positions VALUES('hidden-sha',50,30,0,NULL);",
            )
            .unwrap();
        let recent = core.recent_library_entries(10).unwrap();
        assert_eq!(
            recent.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            ["indexed-file", "prepared-file"]
        );
        assert_eq!(recent[0].book_id, None);
        assert_eq!(recent[0].content_sha256.as_deref(), Some("indexed-sha"));
        assert_eq!(recent[0].position_utf8, 50);
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibrarySearchCandidate {
    pub entry: LibraryEntry,
    pub natural_order_ordinal: u64,
    pub resolved_metadata: Option<crate::BookMetadata>,
}

pub(crate) fn source_snapshots<P: rusqlite::Params>(
    db: &Connection,
    condition: &str,
    params: P,
) -> Result<Vec<SourceFileSnapshot>> {
    let sql = format!(
        "SELECT f.id,f.shelf_id,f.relative_path,f.size,f.modified,f.needs_download,f.book_id,f.decoding FROM library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id {condition}"
    );
    let mut stmt = db.prepare(&sql)?;
    Ok(stmt
        .query_map(params, |r| {
            Ok(SourceFileSnapshot {
                id: r.get(0)?,
                shelf_id: r.get(1)?,
                relative_path: r.get(2)?,
                size: r.get::<_, i64>(3)? as u64,
                modified: r.get(4)?,
                needs_download: r.get(5)?,
                book_id: r.get(6)?,
                decoding: r.get(7)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}
