use super::*;
use rusqlite::OptionalExtension;
use rusqlite::params;
use std::collections::HashMap;
use uuid::Uuid;
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
        let canonical = crate::library::tools::content_key(&db, &book_id)?;
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
                .map(|id| crate::library::tools::content_key(&tx, &id))
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
