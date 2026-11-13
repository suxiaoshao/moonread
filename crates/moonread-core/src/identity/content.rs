//! One owner for content keys and file/cache identity associations.
use crate::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;

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

pub(crate) fn reading_key_column(
    row: &rusqlite::Row<'_>,
    index: usize,
) -> rusqlite::Result<Option<ReadingKey>> {
    row.get::<_, Option<String>>(index)?
        .map(|value| {
            parse_reading_key(value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    index,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()
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
impl CatalogueScope {
    pub(crate) fn sql_scope(&self) -> (Option<&str>, Option<&str>, bool) {
        match self {
            Self::All => (None, None, true),
            Self::Shelf {
                shelf_id,
                parent_path,
                recursive,
            } => (Some(shelf_id), Some(parent_path), *recursive),
        }
    }
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
    SELECT f.id file_id,si.content_sha256,si.utf8_bytes,li.raw_sha256,li.decoding
    FROM main.library_files f JOIN main.library_identities li ON li.file_id=f.id
      AND li.decoding=f.decoding AND li.indexed_size=f.size AND li.indexed_modified=f.modified
    JOIN main.source_identities si ON si.raw_sha256=li.raw_sha256 AND si.decoding=li.decoding
    WHERE f.directory=0;
    CREATE TEMP VIEW file_identities AS
    SELECT f.id file_id,COALESCE(si.content_sha256,b.content_sha256) content_sha256,
      CASE WHEN b.content_sha256=COALESCE(si.content_sha256,b.content_sha256) THEN b.id END associated_book_id,
      b.content_sha256 catalogue_book_sha
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

fn effective_key(db: &Connection, key: &ReadingKey) -> Result<ReadingKey> {
    match key {
        ReadingKey::Formal { sha256 } => {
            parse_sha256(sha256.clone())?;
            Ok(key.clone())
        }
        ReadingKey::Pending { book_id } if book_id.is_empty() => Err(ReaderError::InvalidSettings),
        ReadingKey::Pending { book_id } => match resolve(db, book_id) {
            Ok(value) => Ok(value.key),
            Err(ReaderError::NotFound | ReaderError::InvalidSettings) => Ok(key.clone()),
            Err(error) => Err(error),
        },
    }
}

fn scope_keys(db: &Connection, key: ReadingKey, effective: &ReadingKey) -> Result<Vec<ReadingKey>> {
    let mut keys = vec![effective.clone()];
    if &key != effective {
        keys.push(key);
    }
    if let ReadingKey::Formal { sha256 } = effective {
        let mut query = db.prepare("SELECT original.id FROM main.books original LEFT JOIN main.import_jobs j ON j.book_id=original.id JOIN main.books b ON b.id=COALESCE(j.canonical_id,original.id) WHERE b.content_sha256=?1 ORDER BY original.id")?;
        let aliases = query.query_map([sha256], |row| row.get::<_, String>(0))?;
        for book_id in aliases {
            let key = ReadingKey::Pending { book_id: book_id? };
            if !keys.contains(&key) {
                keys.push(key);
            }
        }
    }
    Ok(keys)
}

fn file_identity(db: &Connection, file_id: String) -> Result<FileIdentity> {
    let (key, associated_book_id, original):(Option<String>,Option<String>,Option<String>)=db.query_row("SELECT fi.content_sha256,fi.associated_book_id,f.book_id FROM main.library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id WHERE f.id=?1 AND f.directory=0",[&file_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?.ok_or(ReaderError::NotFound)?;
    Ok(FileIdentity {
        file_id,
        key: key.map(parse_reading_key).transpose()?,
        associated_book_id,
        pending_alias: original.map(|book_id| ReadingKey::Pending { book_id }),
    })
}

pub(crate) fn resolve_target(db: &Connection, target: BookTarget) -> Result<BookResolution> {
    let (key, original, associated) = match &target {
        BookTarget::File { file_id } => match file_identity(db, file_id.clone()) {
            Ok(file) => match file.key {
                Some(key) => (key, file.pending_alias, file.associated_book_id),
                None => {
                    return Ok(BookResolution::Unidentified {
                        file_id: file.file_id,
                    });
                }
            },
            Err(ReaderError::NotFound) => return Ok(BookResolution::Missing { target }),
            Err(error) => return Err(error),
        },
        BookTarget::Cached { book_id } => match resolve(db, book_id) {
            Ok(record) => (
                record.key,
                Some(ReadingKey::Pending {
                    book_id: book_id.clone(),
                }),
                Some(record.canonical_book_id),
            ),
            Err(ReaderError::NotFound) => return Ok(BookResolution::Missing { target }),
            Err(error) => return Err(error),
        },
        BookTarget::Record { key } => {
            let effective = effective_key(db, key)?;
            let associated = match &effective {
                ReadingKey::Formal { sha256 } => db
                    .query_row(
                        "SELECT id FROM main.books WHERE content_sha256=?1 ORDER BY id LIMIT 1",
                        [sha256],
                        |row| row.get(0),
                    )
                    .optional()?,
                ReadingKey::Pending { book_id } => match resolve(db, book_id) {
                    Ok(record) => Some(record.canonical_book_id),
                    Err(ReaderError::NotFound | ReaderError::InvalidSettings) => None,
                    Err(error) => return Err(error),
                },
            };
            (effective, Some(key.clone()), associated)
        }
    };
    let aliases = scope_keys(db, original.unwrap_or_else(|| key.clone()), &key)?
        .into_iter()
        .filter(|alias| alias != &key)
        .collect();
    let body = associated.map_or(BodyAssociation::Absent, |book_id| {
        BodyAssociation::Associated { book_id }
    });
    Ok(BookResolution::Resolved {
        record: ResolvedBookRecord { key, body, aliases },
    })
}

#[uniffi::export]
impl ReaderCore {
    /// Immutable normalized lengths remain useful even when no local file or
    /// body cache is available. A partial import is never a full-book length.
    pub fn reading_data_percentage(&self, sha: String, offset: u64) -> Result<Option<f64>> {
        parse_sha256(sha.clone())?;
        let db = self.lock()?;
        let bytes: Option<i64> = db.query_row(
            "SELECT MAX(bytes) FROM (
                SELECT utf8_bytes bytes FROM source_identities WHERE content_sha256=?1
                UNION ALL SELECT byte_count FROM books b WHERE content_sha256=?1
                AND NOT EXISTS(SELECT 1 FROM import_jobs j WHERE j.book_id=b.id AND j.phase!='complete')
            )", [&sha], |r| r.get(0))?;
        Ok(bytes
            .filter(|n| *n > 0)
            .map(|n| crate::reading::navigation::reading_percentage(offset, n as u64)))
    }
    pub fn resolve_book_identity(&self, book_id: String) -> Result<ResolvedBookIdentity> {
        resolve(&*self.lock()?, &book_id)
    }
    pub fn resolve_book_target(&self, target: BookTarget) -> Result<BookResolution> {
        resolve_target(&*self.lock()?, target)
    }
    pub fn resolve_reading_keys(&self, keys: Vec<ReadingKey>) -> Result<Vec<ReadingKeyResolution>> {
        let db = self.lock()?;
        keys.into_iter()
            .map(|original| {
                let effective = effective_key(&db, &original)?;
                Ok(ReadingKeyResolution {
                    original,
                    effective,
                })
            })
            .collect()
    }
    /// The complete formal/pending scope of one content identity. Keep alias
    /// resolution here rather than teaching each Swift consumer another rule.
    pub fn reading_scope_keys(&self, key: ReadingKey) -> Result<Vec<ReadingKey>> {
        let db = self.lock()?;
        let effective = effective_key(&db, &key)?;
        scope_keys(&db, key, &effective)
    }
    pub fn file_identity(&self, file_id: String) -> Result<FileIdentity> {
        file_identity(&*self.lock()?, file_id)
    }
    /// Includes original pending aliases before Swift reads/reduces user facts.
    pub fn catalogue_content_keys(&self, scope: CatalogueScope) -> Result<Vec<ReadingKey>> {
        let (shelf, parent, recursive) = scope.sql_scope();
        if let Some(p) = parent {
            crate::library::bookshelf::validate_relative(p, true)?;
        }
        let db = self.lock()?;
        let mut stmt=db.prepare("SELECT fi.content_sha256,f.book_id FROM main.library_files f LEFT JOIN file_identities fi ON fi.file_id=f.id WHERE f.directory=0 AND (?1 IS NULL OR f.shelf_id=?1) AND (?2 IS NULL OR (?3=0 AND f.parent_path=?2) OR (?3=1 AND (?2='' OR substr(f.relative_path,1,length(?2)+1)=?2||'/')))")?;
        let mut keys = std::collections::BTreeSet::new();
        for row in stmt.query_map(params![shelf, parent, recursive], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
            ))
        })? {
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
    /// The requested record and the original aliases contributed by actual
    /// catalogue files, including an original book behind a different index key.
    pub fn catalogue_record_keys(&self, sha: String) -> Result<Vec<ReadingKey>> {
        let sha = parse_sha256(sha)?;
        let db = self.read_lock()?;
        let mut statement = db.prepare_cached(
            "SELECT DISTINCT f.book_id FROM file_identities fi
             JOIN main.library_files f ON f.id=fi.file_id
             WHERE fi.catalogue_book_sha=?1 AND f.book_id IS NOT NULL",
        )?;
        let mut keys = statement
            .query_map([&sha], |row| {
                Ok(ReadingKey::Pending {
                    book_id: row.get(0)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        keys.push(ReadingKey::Formal { sha256: sha });
        Ok(keys)
    }
    pub fn source_files_for_sha(&self, sha: String) -> Result<Vec<SourceFileSnapshot>> {
        parse_sha256(sha.clone())?;
        let db = self.lock()?;
        crate::library::bookshelf::source_snapshots(
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
        crate::library::bookshelf::validate_relative(&relative_path, false)?;
        let db = self.lock()?;
        crate::library::bookshelf::source_snapshots(
            &db,
            "WHERE f.directory=0 AND f.shelf_id=?1 AND f.relative_path=?2",
            [shelf_id, relative_path],
        )
    }
}

pub(crate) fn valid_sha(value: &str) -> bool {
    parse_sha256(value.into()).is_ok()
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
        assert_eq!(core.reading_data_percentage(sha.clone(), 2).unwrap(), None);
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
        let file_target = BookTarget::File {
            file_id: file.id.clone(),
        };
        assert_eq!(
            core.resolve_book_target(file_target.clone()).unwrap(),
            BookResolution::Unidentified {
                file_id: file.id.clone()
            }
        );
        let missing = BookTarget::File {
            file_id: "missing".into(),
        };
        assert_eq!(
            core.resolve_book_target(missing.clone()).unwrap(),
            BookResolution::Missing { target: missing }
        );
        let record_key = ReadingKey::Formal {
            sha256: sha.clone(),
        };
        assert_eq!(
            core.resolve_book_target(BookTarget::Record {
                key: record_key.clone()
            })
            .unwrap(),
            BookResolution::Resolved {
                record: ResolvedBookRecord {
                    key: record_key.clone(),
                    body: BodyAssociation::Absent,
                    aliases: vec![],
                }
            },
            "a formal record does not require local text"
        );
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
        assert_eq!(
            core.reading_data_percentage(sha.clone(), 2).unwrap(),
            Some(25.0)
        );
        assert_eq!(
            core.reading_data_percentage(sha.clone(), 99).unwrap(),
            Some(100.0)
        );
        // A complete cached body also supplies its length without a file link.
        assert_eq!(
            core.reading_data_percentage(old.reading_key.formal_sha().unwrap().to_owned(), 0)
                .unwrap(),
            Some(0.0)
        );
        let found = core.file_identity(file.id.clone()).unwrap();
        assert_eq!(
            core.resolve_book_target(file_target).unwrap(),
            BookResolution::Resolved {
                record: ResolvedBookRecord {
                    key: record_key,
                    body: BodyAssociation::Absent,
                    aliases: vec![ReadingKey::Pending {
                        book_id: old.id.clone()
                    }],
                }
            },
        );
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
                .book()
                .unwrap()
                .book_id()
                .is_none()
        );
        let keys = core
            .catalogue_content_keys(CatalogueScope::Shelf {
                shelf_id: "s".into(),
                parent_path: "folder".into(),
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
                sha256: old.reading_key.formal_sha().unwrap().to_owned()
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
        let resolved = core.resolve_book_identity(alias.clone()).unwrap();
        let scope = core
            .reading_scope_keys(ReadingKey::Formal {
                sha256: old.reading_key.formal_sha().unwrap().to_owned(),
            })
            .unwrap();
        assert!(scope.contains(&ReadingKey::Pending { book_id: alias }));
        assert!(scope.contains(&ReadingKey::Pending {
            book_id: old.id.clone()
        }));
        assert!(scope.contains(&resolved.key));
        assert_eq!(resolved.canonical_book_id, old.id);
        assert_eq!(
            resolved.key,
            ReadingKey::Formal {
                sha256: old.reading_key.formal_sha().unwrap().to_owned()
            }
        );
    }
}
