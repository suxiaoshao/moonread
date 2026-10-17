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
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum LibrarySort {
    Reading,
    Name,
}

pub(crate) fn validate_relative(path: &str, allow_root: bool) -> Result<()> {
    if (path.is_empty() && !allow_root)
        || path.starts_with('/')
        || path.contains('\0')
        || (!path.is_empty()
            && path
                .split('/')
                .any(|p| p.is_empty() || p == "." || p == ".."))
    {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(())
}

#[uniffi::export]
pub fn library_child_path(parent: String, name: String) -> Result<String> {
    validate_relative(&parent, true)?;
    if name.trim().is_empty() || name.contains('/') || name.contains(':') || name.starts_with('.') {
        return Err(ReaderError::InvalidSettings);
    }
    validate_relative(&name, false)?;
    Ok(if parent.is_empty() {
        name
    } else {
        format!("{parent}/{name}")
    })
}

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
        let mut db = self.lock()?;
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
       b.id,COALESCE(b.position_utf8,0),COALESCE(b.byte_count,0),
       (SELECT title FROM effective_chapters c WHERE c.book_id=b.id AND c.start_utf8<=b.position_utf8 ORDER BY c.start_utf8 DESC LIMIT 1),
       CASE WHEN f.directory=1 THEN (SELECT count(*) FROM library_files child WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/') ELSE 0 END,
       CASE WHEN f.directory=1 THEN COALESCE((SELECT max(cb.last_read) FROM library_files child
           LEFT JOIN import_jobs cj ON cj.book_id=child.book_id LEFT JOIN reading_books cb ON cb.id=COALESCE(cj.canonical_id,child.book_id)
           WHERE child.shelf_id=f.shelf_id AND child.directory=0 AND substr(child.relative_path,1,length(f.relative_path)+1)=f.relative_path||'/'),0)
           ELSE COALESCE(b.last_read,0) END,COALESCE(b.preferred_file_id=f.id,0),m.value
       FROM library_files f JOIN library_shelves s ON s.id=f.shelf_id
       LEFT JOIN import_jobs j ON j.book_id=f.book_id LEFT JOIN reading_books b ON b.id=COALESCE(j.canonical_id,f.book_id)
       LEFT JOIN book_metadata m ON m.content_sha=b.content_sha256
       WHERE (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR f.parent_path=?2) AND (?3=0 OR f.directory=0) AND (?4 IS NULL OR f.id=?4) AND (?5 IS NULL OR b.id=?5)")?;
    Ok(stmt
        .query_map(params![shelf, parent, books_only, file, book], |r| {
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
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}

fn populate_cover_previews(db: &Connection, entries: &mut [LibraryEntry]) -> Result<()> {
    let mut stmt = db.prepare_cached(
        "SELECT f.id,f.name,m.value FROM library_files f
        LEFT JOIN import_jobs j ON j.book_id=f.book_id
        LEFT JOIN reading_books b ON b.id=COALESCE(j.canonical_id,f.book_id)
        LEFT JOIN book_metadata m ON m.content_sha=b.content_sha256
        WHERE f.shelf_id=?1 AND f.directory=0 AND f.relative_path>=?2 AND f.relative_path<?3
        ORDER BY COALESCE(b.last_read,0) DESC,f.modified DESC,f.name,f.id LIMIT 4",
    )?;
    for folder in entries.iter_mut().filter(|e| e.directory) {
        // Literal path bounds also handle names containing SQL LIKE wildcards.
        let prefix = format!("{}/", folder.relative_path);
        let end = format!("{}0", folder.relative_path);
        folder.cover_previews = stmt
            .query_map(params![folder.shelf_id, prefix, end], |r| {
                Ok(LibraryCoverPreview {
                    file_id: r.get(0)?,
                    name: r.get(1)?,
                    cover: metadata_column(r, 2)?.and_then(|m| m.cover),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
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

fn search_rank(entry: &LibraryEntry, query: &str) -> Option<u8> {
    if query.is_empty() {
        return Some(0);
    }
    let title = if entry.directory {
        entry.name.to_lowercase()
    } else {
        std::path::Path::new(&entry.name).file_stem().map_or_else(
            || entry.name.to_lowercase(),
            |s| s.to_string_lossy().to_lowercase(),
        )
    };
    if title.starts_with(query) {
        Some(0)
    } else if title.contains(query) {
        Some(1)
    } else if !entry.directory
        && entry
            .metadata
            .as_ref()
            .is_some_and(|m| m.author.to_lowercase().contains(query))
    {
        Some(2)
    } else {
        None
    }
}

fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let a = a.to_lowercase();
    let b = b.to_lowercase();
    let mut a = a.chars().peekable();
    let mut b = b.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut x = String::new();
                let mut y = String::new();
                while a.peek().is_some_and(char::is_ascii_digit) {
                    x.push(a.next().unwrap());
                }
                while b.peek().is_some_and(char::is_ascii_digit) {
                    y.push(b.next().unwrap());
                }
                let nx = x.trim_start_matches('0');
                let ny = y.trim_start_matches('0');
                let order = nx
                    .len()
                    .cmp(&ny.len())
                    .then_with(|| nx.cmp(ny))
                    .then_with(|| x.len().cmp(&y.len()));
                if !order.is_eq() {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.cmp(&y);
                if !order.is_eq() {
                    return order;
                }
                a.next();
                b.next();
            }
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
        }
    }
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
        entries.sort_by(|a, b| {
            match sort {
                LibrarySort::Reading => (a.directory && a.child_book_count == 0)
                    .cmp(&(b.directory && b.child_book_count == 0))
                    .then_with(|| b.last_read.cmp(&a.last_read))
                    .then_with(|| {
                        if a.last_read == 0 && b.last_read == 0 {
                            b.modified.cmp(&a.modified)
                        } else {
                            std::cmp::Ordering::Equal
                        }
                    })
                    .then_with(|| natural_cmp(&a.name, &b.name)),
                LibrarySort::Name => b
                    .directory
                    .cmp(&a.directory)
                    .then_with(|| natural_cmp(&a.name, &b.name)),
            }
            .then_with(|| a.relative_path.cmp(&b.relative_path))
            .then_with(|| a.id.cmp(&b.id))
        });
        populate_cover_previews(&db, &mut entries)?;
        Ok(entries)
    }
    /// Finds books and folders by visible title (no extension), author and folder name.
    /// Author/tag filters describe books, so they exclude folders. Books come first,
    /// ranked title prefix > title contains > author, ties by recent reading.
    pub(crate) fn search_library(
        &self,
        shelf_id: Option<String>,
        query: String,
        author: Option<String>,
        tag: Option<String>,
    ) -> Result<Vec<LibraryEntry>> {
        let query = query.trim().to_lowercase();
        let filtered = author.is_some() || tag.is_some();
        if query.is_empty() && !filtered {
            return Ok(Vec::new());
        }
        let db = self.read_lock()?;
        let mut ranked = entries(&db, shelf_id.as_deref(), None, filtered)?
            .into_iter()
            .filter(|e| {
                let metadata = e.metadata.as_ref();
                author
                    .as_ref()
                    .is_none_or(|a| metadata.is_some_and(|m| &m.author == a))
                    && tag
                        .as_ref()
                        .is_none_or(|t| metadata.is_some_and(|m| m.tags.contains(t)))
            })
            .filter_map(|e| search_rank(&e, &query).map(|rank| (rank, e)))
            .collect::<Vec<_>>();
        ranked.sort_by(|(ra, a), (rb, b)| {
            a.directory
                .cmp(&b.directory)
                .then(ra.cmp(rb))
                .then_with(|| b.last_read.cmp(&a.last_read))
                .then_with(|| natural_cmp(&a.name, &b.name))
                .then_with(|| a.relative_path.cmp(&b.relative_path))
                .then_with(|| a.id.cmp(&b.id))
        });
        let mut entries = ranked.into_iter().map(|(_, e)| e).collect::<Vec<_>>();
        populate_cover_previews(&db, &mut entries)?;
        Ok(entries)
    }
    /// The complete file catalogue of one shelf, including nested directories.
    /// Copies remain separate file entries; no document is read or downloaded.
    pub(crate) fn all_library_books(&self, shelf_id: String) -> Result<Vec<LibraryEntry>> {
        let db = self.read_lock()?;
        let mut books = entries(&db, Some(&shelf_id), None, true)?;
        books.sort_by(|a, b| {
            natural_cmp(&a.name, &b.name)
                .then_with(|| a.relative_path.cmp(&b.relative_path))
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(books)
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
        let ids = db
            .prepare("SELECT id FROM reading_books WHERE recent_visible=1 AND last_read>0")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut entries = Vec::new();
        for id in ids {
            entries.extend(filtered_entries(&db, None, None, true, None, Some(&id))?);
        }
        entries.sort_by(|a, b| {
            b.last_read
                .cmp(&a.last_read)
                .then_with(|| b.preferred.cmp(&a.preferred))
                .then_with(|| a.id.cmp(&b.id))
        });
        let mut books = HashSet::new();
        entries.retain(|e| books.insert(e.book_id.clone()));
        entries.truncate(limit.min(1000) as usize);
        Ok(entries)
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
