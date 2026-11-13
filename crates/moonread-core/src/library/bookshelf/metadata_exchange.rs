//! Exchange reads the file index and metadata, never the presentation catalogue.
use super::{PREFERRED_SOURCE_ORDER, metadata_column};
use crate::{BookMetadata, ReaderCore, ReaderError, ReadingKey, Result, parse_reading_key};
use rusqlite::Connection;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;

#[derive(Clone, Debug, uniffi::Enum)]
pub enum MetadataExchangeRequest {
    Import { shas: Vec<String> },
    Export { shelf_id: Option<String> },
}

#[derive(Clone, Debug, Eq, PartialEq, uniffi::Record)]
pub struct MetadataExchangeFile {
    pub id: String,
    pub shelf_id: String,
    pub shelf_name: String,
    pub relative_path: String,
    pub parent_path: String,
    pub name: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExportFile {
    pub file: MetadataExchangeFile,
    pub sha: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExchangeBook {
    pub metadata: BookMetadata,
    pub has_reading_position: bool,
    pub source_count: u64,
    pub first_source_name: String,
    pub unique_source: Option<MetadataExchangeFile>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MetadataExchangeRead {
    pub export_files: Vec<MetadataExportFile>,
    pub books: Vec<MetadataExchangeBook>,
}

#[derive(Debug, Eq, PartialEq)]
struct IndexedFile {
    file: MetadataExchangeFile,
    key: Option<String>,
    original_book: Option<String>,
    catalogue_book_sha: Option<String>,
}

#[derive(Debug, Eq, PartialEq, uniffi::Object)]
pub struct MetadataExchangeInventory {
    files: Vec<IndexedFile>,
    counts: BTreeMap<String, u64>,
    keys: Vec<ReadingKey>,
}

#[uniffi::export]
impl MetadataExchangeInventory {
    pub fn record_keys(&self) -> Vec<ReadingKey> {
        self.keys.clone()
    }
}

fn json_keys<'a>(keys: impl IntoIterator<Item = &'a String>) -> Result<String> {
    serde_json::to_string(&keys.into_iter().collect::<Vec<_>>())
        .map_err(|_| ReaderError::InvalidSettings)
}

const FILE_ROWS: &str = "SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,
    fi.content_sha256,f.book_id,fi.catalogue_book_sha
    FROM main.library_files f JOIN main.library_shelves s ON s.id=f.shelf_id
    LEFT JOIN file_identities fi ON fi.file_id=f.id";

const EXPORT_COUNTS: &str = "SELECT content_sha256,COUNT(*) FROM file_identities
    WHERE content_sha256 IN (SELECT value FROM json_each(?1)) GROUP BY content_sha256";

fn import_sql(rank_sources: bool) -> String {
    let rank_join = if rank_sources {
        " LEFT JOIN user_positions p ON p.content_key=fi.content_sha256"
    } else {
        ""
    };
    let order = if rank_sources {
        format!(" ORDER BY {PREFERRED_SOURCE_ORDER}")
    } else {
        String::new()
    };
    format!("WITH wanted AS MATERIALIZED (SELECT value FROM json_each(?1))
        {FILE_ROWS}{rank_join}
        WHERE f.directory=0 AND (fi.content_sha256 IN wanted OR fi.catalogue_book_sha IN wanted){order}")
}

impl MetadataExchangeRequest {
    fn inventory(
        &self,
        db: &Connection,
        rank_sources: bool,
    ) -> Result<(
        MetadataExchangeInventory,
        HashMap<String, MetadataExchangeFile>,
    )> {
        let (sql, input) = match self {
            Self::Import { shas } => {
                // One bounded SQL shape for any manifest size. Materialize the
                // requested key set, not the catalogue or its presentation rows.
                let keys = shas
                    .iter()
                    .cloned()
                    .map(crate::parse_sha256)
                    .collect::<Result<BTreeSet<_>>>()?;
                if keys.is_empty() {
                    return Ok((
                        MetadataExchangeInventory {
                            files: vec![],
                            counts: BTreeMap::new(),
                            keys: vec![],
                        },
                        HashMap::new(),
                    ));
                }
                (import_sql(rank_sources), Some(json_keys(&keys)?))
            }
            Self::Export { shelf_id: Some(id) } => (
                format!("{FILE_ROWS} WHERE f.directory=0 AND f.shelf_id=?1"),
                Some(id.clone()),
            ),
            Self::Export { shelf_id: None } => (format!("{FILE_ROWS} WHERE f.directory=0"), None),
        };
        let mut statement = db.prepare(&sql)?;
        let mut rows = if let Some(input) = &input {
            statement.query([input])?
        } else {
            statement.query([])?
        };
        let requested = match self {
            Self::Import { shas } => Some(shas.iter().map(String::as_str).collect::<BTreeSet<_>>()),
            Self::Export { .. } => None,
        };
        let mut files = Vec::new();
        let mut counts = BTreeMap::new();
        let mut first = HashMap::new();
        while let Some(row) = rows.next()? {
            let file = MetadataExchangeFile {
                id: row.get(0)?,
                shelf_id: row.get(1)?,
                shelf_name: row.get(2)?,
                relative_path: row.get(3)?,
                parent_path: row.get(4)?,
                name: row.get(5)?,
            };
            let key: Option<String> = row.get(6)?;
            if let Some(sha) = key.as_ref().filter(|sha| {
                !sha.starts_with("pending:")
                    && requested
                        .as_ref()
                        .is_none_or(|wanted| wanted.contains(sha.as_str()))
            }) {
                *counts.entry(sha.clone()).or_insert(0) += 1;
                if rank_sources && requested.is_some() && !first.contains_key(sha) {
                    first.insert(sha.clone(), file.clone());
                }
            }
            files.push(IndexedFile {
                file,
                key,
                original_book: row.get(7)?,
                catalogue_book_sha: row.get(8)?,
            });
        }
        // catalogue_content_keys includes each in-scope file's original book id,
        // even when a verified index points at a different effective identity.
        // Only keep such aliases if they resolve to an actually matched SHA.
        let mut keys = counts.keys().cloned().collect::<BTreeSet<_>>();
        for row in &files {
            if let (Some(id), Some(sha)) = (&row.original_book, &row.catalogue_book_sha)
                && counts.contains_key(sha)
            {
                keys.insert(format!("pending:{id}"));
            }
        }
        if matches!(self, Self::Export { shelf_id: Some(_) }) && !counts.is_empty() {
            // Global cardinality still governs title export for a single shelf.
            let mut statement = db.prepare(EXPORT_COUNTS)?;
            for row in statement.query_map([json_keys(counts.keys())?], |row| {
                Ok((row.get(0)?, row.get::<_, i64>(1)? as u64))
            })? {
                let (sha, count) = row?;
                counts.insert(sha, count);
            }
        }
        if requested.is_some() {
            // Equality compares live file facts, independent of the projection's rank.
            files.sort_unstable_by(|a, b| a.file.id.cmp(&b.file.id));
        } else {
            files.sort_by(|a, b| {
                let (a, b) = (&a.file, &b.file);
                crate::library::order::file_order_fields(
                    (&a.name, &a.relative_path, &a.id),
                    (&b.name, &b.relative_path, &b.id),
                )
            });
        }
        let keys = keys
            .into_iter()
            .map(parse_reading_key)
            .collect::<Result<_>>()?;
        Ok((
            MetadataExchangeInventory {
                files,
                counts,
                keys,
            },
            first,
        ))
    }
}

#[uniffi::export]
impl ReaderCore {
    pub fn metadata_exchange_inventory(
        &self,
        request: MetadataExchangeRequest,
    ) -> Result<Arc<MetadataExchangeInventory>> {
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let (inventory, _) = request.inventory(&tx, false)?;
        tx.commit()?;
        Ok(Arc::new(inventory))
    }
}

impl ReaderCore {
    pub(crate) fn metadata_exchange_read(
        &self,
        request: MetadataExchangeRequest,
        inventory: Arc<MetadataExchangeInventory>,
    ) -> Result<Option<MetadataExchangeRead>> {
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let (current, mut first) = request.inventory(&tx, true)?;
        if current != *inventory {
            return Ok(None);
        }
        let mut statement = tx.prepare(
            "SELECT wanted.value,m.value,p.content_sha256 IS NOT NULL
             FROM json_each(?1) wanted LEFT JOIN book_metadata m ON m.content_sha=wanted.value
             LEFT JOIN reading_content_positions p ON p.content_sha256=wanted.value",
        )?;
        let books = statement
            .query_map([json_keys(current.counts.keys())?], |row| {
                let sha: String = row.get(0)?;
                let has_reading_position = row.get(2)?;
                let metadata = crate::reading::book_details::project_metadata(
                    &sha,
                    metadata_column(row, 1)?,
                    has_reading_position,
                );
                let source_count = current.counts[&sha];
                let source = first.remove(&sha);
                Ok(MetadataExchangeBook {
                    metadata,
                    has_reading_position,
                    source_count,
                    first_source_name: source.as_ref().map(|f| f.name.clone()).unwrap_or_default(),
                    unique_source: source.filter(|_| source_count == 1),
                })
            })?
            .collect::<std::result::Result<_, _>>()?;
        drop(statement);
        tx.commit()?;
        let export_files = if matches!(request, MetadataExchangeRequest::Export { .. }) {
            current
                .files
                .into_iter()
                .map(|row| MetadataExportFile {
                    file: row.file,
                    sha: row.key.filter(|key| !key.starts_with("pending:")),
                })
                .collect()
        } else {
            Vec::new()
        };
        Ok(Some(MetadataExchangeRead {
            export_files,
            books,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::StatementStatus;

    #[test]
    fn metadata_exchange_scans_index_once_per_batch() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().to_string_lossy().into()).unwrap();
        {
            let db = core.lock().unwrap();
            db.execute_batch(
                "INSERT INTO library_shelves VALUES('fixture','Synthetic',x'','local',0,NULL);
                 WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<512)
                 INSERT INTO books(id,title,content_sha256,encoding)
                 SELECT printf('b%d',i),'Synthetic',printf('%064x',i),'utf8' FROM n;
                 INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id)
                 SELECT id,'fixture',id||'.txt','',id||'.txt',0,1,0,0,id FROM books;",
            ).unwrap();
        }
        let db = core.read_lock().unwrap();
        let run = |label: &str, sql: &str, size: usize| {
            let keys: Vec<_> = (1..=size).map(|i| format!("{i:064x}")).collect();
            let input = json_keys(&keys).unwrap();
            let mut query = db.prepare(sql).unwrap();
            let mut rows = query.query([&input]).unwrap();
            let mut count = 0;
            while rows.next().unwrap().is_some() {
                count += 1;
            }
            drop(rows);
            assert_eq!(count, size);
            let scans = query.get_status(StatementStatus::FullscanStep);
            eprintln!(
                "{label}: {size} keys, {count} rows, {scans} fullscan steps, {} VM steps, {} runs",
                query.get_status(StatementStatus::VmStep),
                query.get_status(StatementStatus::Run)
            );
            assert_eq!(query.get_status(StatementStatus::Run), 1);
            if size == 140 {
                let mut plan = db.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
                for line in plan
                    .query_map([&input], |row| row.get::<_, String>(3))
                    .unwrap()
                {
                    let line = line.unwrap();
                    eprintln!("  {line}");
                    assert!(!line.contains("CORRELATED"));
                }
            }
            scans
        };
        for (label, sql) in [
            ("preview candidates", import_sql(false)),
            ("preview ranked", import_sql(true)),
            ("export global counts", EXPORT_COUNTS.into()),
        ] {
            let single = run(label, &sql, 1);
            let batch = run(label, &sql, 140);
            assert!(
                batch < (single + 140) * 3,
                "Full scans should not scale with manifest keys"
            );
        }
    }
}
