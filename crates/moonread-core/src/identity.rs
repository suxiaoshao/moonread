//! One owner for content keys and file/cache identity associations.
use crate::*;

#[derive(Clone, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ReadingKey {
    Formal { sha256: String },
    Pending { book_id: String },
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
#[derive(Clone, Debug, uniffi::Record)]
pub struct CatalogueScope {
    pub shelf_id: Option<String>,
    pub parent_path: Option<String>,
    pub recursive: bool,
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

pub(crate) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TEMP VIEW valid_indexed_identities AS
    SELECT f.id file_id,si.content_sha256,si.utf8_bytes
    FROM main.library_files f JOIN main.library_identities li ON li.file_id=f.id
      AND li.decoding=f.decoding AND li.indexed_size=f.size AND li.indexed_modified=f.modified
    JOIN main.source_identities si ON si.raw_sha256=li.raw_sha256 AND si.decoding=li.decoding
    WHERE f.directory=0;
    CREATE TEMP VIEW file_identities AS
    SELECT f.id file_id,COALESCE(si.content_sha256,b.content_sha256) content_sha256,
      CASE WHEN b.content_sha256=COALESCE(si.content_sha256,b.content_sha256) THEN b.id END associated_book_id
    FROM main.library_files f
    LEFT JOIN valid_indexed_identities si ON si.file_id=f.id
    LEFT JOIN main.import_jobs j ON j.book_id=f.book_id
    LEFT JOIN main.books b ON b.id=COALESCE(j.canonical_id,f.book_id)
    WHERE f.directory=0 AND COALESCE(si.content_sha256,b.content_sha256) IS NOT NULL;")?;
    Ok(())
}
fn resolve(db: &Connection, id: &str) -> Result<ResolvedBookIdentity> {
    let (canonical, sha): (String,String) = db.query_row(
        "SELECT b.id,b.content_sha256 FROM main.books original LEFT JOIN main.import_jobs j ON j.book_id=original.id JOIN main.books b ON b.id=COALESCE(j.canonical_id,original.id) WHERE original.id=?1", [id], |r| Ok((r.get(0)?,r.get(1)?)))
        .optional()?.ok_or(ReaderError::NotFound)?;
    Ok(ResolvedBookIdentity {
        key: parse_reading_key(sha)?,
        canonical_book_id: canonical,
    })
}
#[uniffi::export]
impl ReaderCore {
    pub fn resolve_book_identity(&self, book_id: String) -> Result<ResolvedBookIdentity> {
        resolve(&*self.lock()?, &book_id)
    }
    pub fn resolve_reading_keys(&self, keys: Vec<ReadingKey>) -> Result<Vec<ReadingKeyResolution>> {
        let db = self.lock()?;
        keys.into_iter()
            .map(|original| {
                let effective = match &original {
                    ReadingKey::Formal { sha256 } => {
                        parse_sha256(sha256.clone())?;
                        original.clone()
                    }
                    ReadingKey::Pending { book_id } => {
                        if book_id.is_empty() {
                            return Err(ReaderError::InvalidSettings);
                        }
                        match resolve(&db, book_id) {
                            Ok(value) => value.key,
                            Err(ReaderError::NotFound | ReaderError::InvalidSettings) => {
                                original.clone()
                            }
                            Err(e) => return Err(e),
                        }
                    }
                };
                Ok(ReadingKeyResolution {
                    original,
                    effective,
                })
            })
            .collect()
    }
    pub fn file_identity(&self, file_id: String) -> Result<FileIdentity> {
        let db = self.lock()?;
        let (key, associated_book_id, original):(Option<String>,Option<String>,Option<String>)=db.query_row("SELECT fi.content_sha256,fi.associated_book_id,f.book_id FROM main.library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id WHERE f.id=?1",[&file_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?.ok_or(ReaderError::NotFound)?;
        Ok(FileIdentity {
            file_id,
            key: key.map(parse_reading_key).transpose()?,
            associated_book_id,
            pending_alias: original.map(|book_id| ReadingKey::Pending { book_id }),
        })
    }
    /// Includes original pending aliases before Swift reads/reduces user facts.
    pub fn catalogue_content_keys(&self, scope: CatalogueScope) -> Result<Vec<ReadingKey>> {
        if let Some(p) = &scope.parent_path {
            crate::bookshelf::validate_relative(p, true)?;
        }
        let db = self.lock()?;
        let mut stmt=db.prepare("SELECT fi.content_sha256,f.book_id FROM main.library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id WHERE f.directory=0 AND (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR (?3=0 AND f.parent_path=?2) OR (?3=1 AND (?2='' OR substr(f.relative_path,1,length(?2)+1)=?2||'/')))")?;
        let mut keys = std::collections::BTreeSet::new();
        for row in stmt.query_map(
            params![scope.shelf_id, scope.parent_path, scope.recursive],
            |r| {
                Ok((
                    r.get::<_, Option<String>>(0)?,
                    r.get::<_, Option<String>>(1)?,
                ))
            },
        )? {
            let (key, id) = row?;
            if let Some(key) = key {
                keys.insert(key);
            }
            if let Some(id) = id {
                keys.insert(serialize_reading_key(ReadingKey::Pending { book_id: id }));
            }
        }
        keys.into_iter().map(parse_reading_key).collect()
    }
    pub fn source_files_for_sha(&self, sha: String) -> Result<Vec<SourceFileSnapshot>> {
        parse_sha256(sha.clone())?;
        let db = self.lock()?;
        crate::bookshelf::source_snapshots(
            &db,
            "WHERE f.directory=0 AND fi.content_sha256=?1",
            [sha],
        )
    }
    pub fn source_files_at_path(
        &self,
        shelf_id: String,
        relative_path: String,
    ) -> Result<Vec<SourceFileSnapshot>> {
        crate::bookshelf::validate_relative(&relative_path, false)?;
        let db = self.lock()?;
        crate::bookshelf::source_snapshots(
            &db,
            "WHERE f.directory=0 AND f.shelf_id=?1 AND f.relative_path=?2",
            [shelf_id, relative_path],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keys_and_valid_index_associations_share_one_owner() {
        let sha = "a".repeat(64);
        assert_eq!(parse_sha256(sha.clone()).unwrap(), sha);
        for invalid in [
            "A".repeat(64),
            "ａ".repeat(64),
            "a".repeat(63),
            "g".repeat(64),
        ] {
            assert!(parse_sha256(invalid).is_err());
        }
        for encoded in [sha.clone(), "pending:legacy-non-uuid".into()] {
            assert_eq!(
                serialize_reading_key(parse_reading_key(encoded.clone()).unwrap()),
                encoded
            );
        }
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().to_string_lossy().into()).unwrap();
        core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
            .unwrap();
        let item = |path: &str| ScannedLibraryItem {
            relative_path: path.into(),
            directory: false,
            size: 10,
            modified: 1,
            needs_download: false,
        };
        core.scan_library_shelf(
            "s".into(),
            vec![item("folder/book.txt"), item("folder2/other.txt")],
        )
        .unwrap();
        let file = core
            .source_file_snapshots(None)
            .unwrap()
            .into_iter()
            .find(|f| f.relative_path == "folder/book.txt")
            .unwrap();
        let old = core.create_sample_book().unwrap();
        core.link_library_file(file.id.clone(), old.id.clone())
            .unwrap();
        let identity = SourceTextIdentity {
            raw_sha256: "b".repeat(64),
            content_sha256: sha.clone(),
            encoding: "UTF-8".into(),
            source_bytes: 10,
            utf8_bytes: 8,
            char_count: 4,
        };
        assert!(
            core.publish_source_identity(file.clone(), identity)
                .unwrap()
        );
        let found = core.file_identity(file.id.clone()).unwrap();
        assert_eq!(
            found.key,
            Some(ReadingKey::Formal {
                sha256: sha.clone()
            })
        );
        assert!(
            found.associated_book_id.is_none(),
            "indexing a new SHA cannot claim old cached text"
        );
        assert!(
            core.query_snapshot("{}".into())
                .unwrap()
                .library_entry(file.id.clone())
                .unwrap()
                .book_id
                .is_none()
        );
        let keys = core
            .catalogue_content_keys(CatalogueScope {
                shelf_id: Some("s".into()),
                parent_path: Some("folder".into()),
                recursive: true,
            })
            .unwrap();
        assert!(keys.contains(&ReadingKey::Formal {
            sha256: sha.clone()
        }));
        assert!(keys.contains(&ReadingKey::Pending {
            book_id: old.id.clone()
        }));
        assert_eq!(keys.len(), 2, "prefix siblings are excluded");
        let resolutions = core
            .resolve_reading_keys(vec![
                ReadingKey::Pending {
                    book_id: old.id.clone(),
                },
                ReadingKey::Pending {
                    book_id: "missing".into(),
                },
            ])
            .unwrap();
        assert_eq!(
            resolutions[0].effective,
            ReadingKey::Formal {
                sha256: old.content_sha256.clone()
            }
        );
        assert_eq!(resolutions[1].original, resolutions[1].effective);
        // Every member of the validity tuple participates; cache fallback is retained.
        for update in [
            "UPDATE library_files SET size=11",
            "UPDATE library_files SET modified=2",
            "UPDATE library_files SET decoding='UTF-8'",
        ] {
            core.lock().unwrap().execute(update, []).unwrap();
            assert!(
                core.indexed_source_keys(Some("s".into()), Some(file.id.clone()))
                    .unwrap()
                    .is_empty()
            );
            assert!(
                core.pending_identity_files("s".into())
                    .unwrap()
                    .iter()
                    .any(|f| f.id == file.id)
            );
            assert_eq!(
                core.file_identity(file.id.clone())
                    .unwrap()
                    .associated_book_id,
                Some(old.id.clone())
            );
            core.lock()
                .unwrap()
                .execute(
                    "UPDATE library_files SET size=10,modified=1,decoding='auto'",
                    [],
                )
                .unwrap();
        }
        let alias = core.create_import("alias".into()).unwrap().book_id();
        core.lock()
            .unwrap()
            .execute(
                "UPDATE import_jobs SET canonical_id=?1 WHERE book_id=?2",
                params![old.id, alias],
            )
            .unwrap();
        let resolved = core.resolve_book_identity(alias).unwrap();
        assert_eq!(resolved.canonical_book_id, old.id);
        assert_eq!(
            resolved.key,
            ReadingKey::Formal {
                sha256: old.content_sha256
            }
        );
    }
}
