use super::{
    parse::{StrictValue, diagnostic},
    *,
};
use crate::{Result, storage::maintenance::archive_limits::*};
use rusqlite::{Connection, params};
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::{
    cell::Cell,
    collections::HashSet,
    fmt,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    path::PathBuf,
    rc::Rc,
    sync::{Arc, Mutex},
};

/// Private, disposable indexed staging, not a user database or a sync format.
/// Parsing and browsing stay bounded even when a manifest contains many books.
#[derive(Debug, uniffi::Object)]
pub struct MetadataDocument {
    root: PathBuf,
    db: Mutex<Connection>,
}
impl Drop for MetadataDocument {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn save_diagnostic(
    db: &Connection,
    mut d: MetadataDiagnostic,
    line: Option<u64>,
    index: Option<u64>,
) -> Result<()> {
    d.source_line = line;
    d.record_index = index;
    let json = serde_json::to_string(&d).map_err(|_| invalid("无法记录小说信息诊断"))?;
    db.execute("INSERT INTO diagnostics(payload) VALUES(?1)", [json])?;
    Ok(())
}
fn save_book(
    db: &Connection,
    root: &std::path::Path,
    packaged: bool,
    value: serde_json::Value,
    line: Option<u64>,
    index: u64,
) -> Result<()> {
    match parse::book(value) {
        Err(d) => save_diagnostic(db, *d, line, Some(index)),
        Ok((mut book, warnings)) => {
            for d in warnings {
                save_diagnostic(db, d, line, Some(index))?;
            }
            if let Some(name) = &book.cover
                && (!packaged || !super::archive::cover_path(name) || !root.join(name).is_file())
            {
                save_diagnostic(
                    db,
                    diagnostic(
                        "cover_unavailable",
                        Some("cover"),
                        Some(&book.content_sha256),
                        "封面不可用；只跳过封面，其他资料仍可导入",
                    ),
                    line,
                    Some(index),
                )?;
                book.cover = None;
            }
            let payload = serde_json::to_string(&book).map_err(|_| invalid("无法记录小说信息"))?;
            db.execute("INSERT INTO records(sha,payload,source_line,record_index,duplicates) VALUES(?1,?2,?3,?4,1) ON CONFLICT(sha,payload) DO UPDATE SET duplicates=duplicates+1",params![book.content_sha256,payload,line.map(|v| v as i64),index as i64])?;
            Ok(())
        }
    }
}

struct BudgetReader<R> {
    inner: R,
    bytes: Rc<Cell<u64>>,
    end: Rc<Cell<u64>>,
}
impl<R: Read> Read for BudgetReader<R> {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(output)?;
        self.bytes.set(self.bytes.get() + n as u64);
        if self.bytes.get() > self.end.get() || self.bytes.get() > MAX_TOTAL {
            return Err(std::io::Error::other(
                "shared record/stream budget exceeded",
            ));
        }
        Ok(n)
    }
}
struct Envelope<'a> {
    db: &'a Connection,
    root: &'a std::path::Path,
    packaged: bool,
    bytes: Rc<Cell<u64>>,
    end: Rc<Cell<u64>>,
}
impl<'de> DeserializeSeed<'de> for Envelope<'_> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> std::result::Result<(), D::Error> {
        d.deserialize_map(self)
    }
}
impl<'de> Visitor<'de> for Envelope<'_> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("moonread-metadata envelope")
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> std::result::Result<(), A::Error> {
        let mut keys = HashSet::new();
        let mut format = None;
        let mut version = None;
        let mut has_books = false;
        while let Some(key) = map.next_key::<String>()? {
            if !keys.insert(key.clone()) {
                return Err(de::Error::custom("duplicate envelope key"));
            }
            if key == "books" {
                has_books = true;
                struct Books<'a>(&'a Envelope<'a>);
                impl<'de> DeserializeSeed<'de> for Books<'_> {
                    type Value = ();
                    fn deserialize<D: serde::Deserializer<'de>>(
                        self,
                        d: D,
                    ) -> std::result::Result<(), D::Error> {
                        d.deserialize_seq(self)
                    }
                }
                impl<'de> Visitor<'de> for Books<'_> {
                    type Value = ();
                    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                        f.write_str("book array")
                    }
                    fn visit_seq<A: SeqAccess<'de>>(
                        self,
                        mut seq: A,
                    ) -> std::result::Result<(), A::Error> {
                        let mut index = 0;
                        loop {
                            self.0.end.set(self.0.bytes.get() + MAX_RECORD);
                            let Some(value) = seq.next_element::<StrictValue>()? else {
                                break;
                            };
                            save_book(
                                self.0.db,
                                self.0.root,
                                self.0.packaged,
                                value.0,
                                None,
                                index,
                            )
                            .map_err(|_| de::Error::custom("cannot stage metadata"))?;
                            index += 1;
                        }
                        Ok(())
                    }
                }
                map.next_value_seed(Books(&self))?;
            } else {
                self.end.set(self.bytes.get() + MAX_RECORD);
                let v = map.next_value::<StrictValue>()?.0;
                match key.as_str() {
                    "format" => format = Some(v),
                    "version" => version = Some(v),
                    "$schema" => {
                        if v.as_str() != Some(METADATA_SCHEMA_URL) {
                            return Err(de::Error::custom("unknown metadata schema"));
                        }
                    }
                    _ => save_diagnostic(
                        self.db,
                        diagnostic("unknown_field", None, None, "忽略未知可选字段"),
                        None,
                        None,
                    )
                    .map_err(|_| de::Error::custom("cannot stage diagnostic"))?,
                }
            }
        }
        if !has_books
            || format.as_ref().and_then(serde_json::Value::as_str) != Some("moonread-metadata")
            || version.as_ref().and_then(serde_json::Value::as_f64) != Some(1.0)
        {
            return Err(de::Error::custom("invalid metadata format/version"));
        }
        Ok(())
    }
}

fn parse_manifest(
    db: &Connection,
    root: &std::path::Path,
    path: &std::path::Path,
    format: MetadataFormat,
    packaged: bool,
) -> Result<()> {
    let file = File::open(path)?;
    if file.metadata()?.len() > if packaged { MAX_TOTAL } else { MAX_ARCHIVE } {
        return Err(invalid("超过公共资源预算"));
    }
    let mut reader = BufReader::new(file);
    if reader.fill_buf()?.starts_with(&[0xef, 0xbb, 0xbf]) {
        reader.consume(3);
    }
    match format {
        MetadataFormat::Json => {
            let bytes = Rc::new(Cell::new(0));
            let end = Rc::new(Cell::new(MAX_RECORD));
            let bounded = BudgetReader {
                inner: reader,
                bytes: bytes.clone(),
                end: end.clone(),
            };
            let mut decoder = serde_json::Deserializer::from_reader(bounded);
            Envelope {
                db,
                root,
                packaged,
                bytes,
                end,
            }
            .deserialize(&mut decoder)
            .map_err(|_| invalid("JSON清单语法、重复键、版本或公共资源预算无效；整份未导入"))?;
            decoder
                .end()
                .map_err(|_| invalid("JSON清单含多余内容；整份未导入"))?;
        }
        MetadataFormat::Jsonl => {
            let mut line = 0;
            let mut index = 0;
            loop {
                let mut buffer = Vec::new();
                let n = Read::by_ref(&mut reader)
                    .take(MAX_RECORD + 1)
                    .read_until(b'\n', &mut buffer)?;
                if n == 0 {
                    break;
                }
                line += 1;
                if buffer.len() as u64 > MAX_RECORD {
                    if buffer.last() != Some(&b'\n') {
                        loop {
                            let data = reader.fill_buf()?;
                            if data.is_empty() {
                                break;
                            }
                            let end = data.iter().position(|b| *b == b'\n');
                            let n = end.map_or(data.len(), |i| i + 1);
                            reader.consume(n);
                            if end.is_some() {
                                break;
                            }
                        }
                    }
                    save_diagnostic(
                        db,
                        diagnostic("record_budget", None, None, "超过公共单记录资源预算"),
                        Some(line),
                        Some(index),
                    )?;
                    index += 1;
                    continue;
                }
                if std::str::from_utf8(&buffer).is_ok_and(|s| s.trim().is_empty()) {
                    continue;
                }
                match serde_json::from_slice::<StrictValue>(&buffer) {
                    Ok(v) => save_book(db, root, packaged, v.0, Some(line), index)?,
                    Err(_) => save_diagnostic(
                        db,
                        diagnostic(
                            "invalid_json",
                            None,
                            None,
                            "此行不是有效UTF-8 JSON，或包含重复键",
                        ),
                        Some(line),
                        Some(index),
                    )?,
                }
                index += 1;
            }
        }
    }
    Ok(())
}

#[uniffi::export]
pub fn inspect_metadata_exchange(
    input_path: String,
    staging_root: String,
) -> Result<Arc<MetadataDocument>> {
    fs::create_dir_all(&staging_root)?;
    let root = PathBuf::from(staging_root).join(uuid::Uuid::new_v4().to_string());
    fs::create_dir(&root)?;
    let result = (|| {
        let input = std::path::Path::new(&input_path);
        let suffix = input
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let packaged = matches!(suffix.as_str(), "zip" | "moonread-metadata");
        let (manifest, format, warnings) = match suffix.as_str() {
            "json" => (input.to_owned(), MetadataFormat::Json, Vec::new()),
            "jsonl" => (input.to_owned(), MetadataFormat::Jsonl, Vec::new()),
            "zip" | "moonread-metadata" => super::archive::unpack(input, &root)?,
            _ => return Err(invalid("请选择JSON、JSONL或moonread-metadata文件")),
        };
        let db = Connection::open(root.join("inspection.sqlite"))?;
        db.execute_batch("CREATE TABLE records(id INTEGER PRIMARY KEY,sha TEXT NOT NULL,payload TEXT NOT NULL,source_line INTEGER,record_index INTEGER NOT NULL,duplicates INTEGER NOT NULL,UNIQUE(sha,payload)); CREATE INDEX records_sha ON records(sha,id); CREATE TABLE diagnostics(id INTEGER PRIMARY KEY,payload TEXT NOT NULL); BEGIN")?;
        for _ in warnings {
            save_diagnostic(
                &db,
                diagnostic("unused_member", None, None, "忽略未使用的附属文件"),
                None,
                None,
            )?;
        }
        parse_manifest(&db, &root, &manifest, format, packaged)?;
        db.execute_batch("COMMIT")?;
        if packaged {
            fs::remove_file(manifest)?;
        }
        Ok(Arc::new(MetadataDocument {
            root: root.clone(),
            db: Mutex::new(db),
        }))
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(root);
    }
    result
}

#[uniffi::export]
impl MetadataDocument {
    pub fn summary(&self) -> Result<MetadataDocumentSummary> {
        let db = self.db.lock().map_err(|_| invalid("小说信息暂存不可用"))?;
        Ok(MetadataDocumentSummary {
            books: db.query_row("SELECT count(DISTINCT sha) FROM records", [], |r| {
                crate::unsigned_column(r, 0)
            })?,
            variants: db.query_row("SELECT count(*) FROM records", [], |r| {
                crate::unsigned_column(r, 0)
            })?,
            diagnostics: db.query_row("SELECT count(*) FROM diagnostics", [], |r| {
                crate::unsigned_column(r, 0)
            })?,
        })
    }
    /// Enumerate identities without decoding every payload a second time.
    pub fn book_keys(&self, after: Option<String>, count: u32) -> Result<MetadataKeysPage> {
        if count == 0 {
            return Err(invalid("分页大小无效"));
        }
        let db = self.db.lock().map_err(|_| invalid("小说信息暂存不可用"))?;
        let mut query =
            db.prepare("SELECT DISTINCT sha FROM records WHERE sha>?1 ORDER BY sha LIMIT ?2")?;
        let mut keys = query
            .query_map(
                params![after.unwrap_or_default(), count as i64 + 1],
                |row| row.get::<_, String>(0),
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let done = keys.len() <= count as usize;
        keys.truncate(count as usize);
        Ok(MetadataKeysPage { keys, done })
    }
    pub fn records(
        &self,
        sha: Option<String>,
        cursor: u64,
        count: u32,
    ) -> Result<MetadataRecordPage> {
        if count == 0 || cursor > i64::MAX as u64 {
            return Err(crate::ReaderError::InvalidSettings);
        }
        if let Some(sha) = &sha {
            crate::parse_sha256(sha.clone())?;
        }
        let db = self.db.lock().map_err(|_| invalid("小说信息暂存不可用"))?;
        let (sql, values) = if let Some(sha) = sha {
            (
                "SELECT id,payload,source_line,record_index,duplicates FROM records WHERE sha=?1 AND id>?2 ORDER BY id LIMIT ?3",
                vec![
                    rusqlite::types::Value::from(sha),
                    rusqlite::types::Value::from(cursor as i64),
                    rusqlite::types::Value::from(count as i64 + 1),
                ],
            )
        } else {
            (
                "SELECT id,payload,source_line,record_index,duplicates FROM records WHERE id>?1 ORDER BY id LIMIT ?2",
                vec![
                    rusqlite::types::Value::from(cursor as i64),
                    rusqlite::types::Value::from(count as i64 + 1),
                ],
            )
        };
        let mut statement = db.prepare(sql)?;
        let mut rows = statement.query(rusqlite::params_from_iter(values))?;
        let mut records = Vec::new();
        while let Some(row) = rows.next()? {
            records.push(MetadataRecord {
                id: crate::unsigned_column(row, 0)?,
                book: serde_json::from_str(&row.get::<_, String>(1)?)
                    .map_err(|_| invalid("小说信息暂存无法读取"))?,
                source_line: row.get::<_, Option<i64>>(2)?.map(|v| v as u64),
                record_index: crate::unsigned_column(row, 3)?,
                duplicates: crate::unsigned_column(row, 4)?,
            });
        }
        let done = records.len() <= count as usize;
        records.truncate(count as usize);
        Ok(MetadataRecordPage {
            next_cursor: records.last().map_or(cursor, |r| r.id),
            records,
            done,
        })
    }
    pub fn diagnostics(&self, cursor: u64, count: u32) -> Result<MetadataDiagnosticsPage> {
        if count == 0 || cursor > i64::MAX as u64 {
            return Err(crate::ReaderError::InvalidSettings);
        }
        let db = self.db.lock().map_err(|_| invalid("小说信息暂存不可用"))?;
        let mut statement =
            db.prepare("SELECT id,payload FROM diagnostics WHERE id>?1 ORDER BY id LIMIT ?2")?;
        let values = statement
            .query_map(params![cursor as i64, count as i64 + 1], |r| {
                Ok((crate::unsigned_column(r, 0)?, r.get::<_, String>(1)?))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let done = values.len() <= count as usize;
        let mut next = cursor;
        let mut diagnostics = Vec::new();
        for (id, json) in values.into_iter().take(count as usize) {
            diagnostics.push(serde_json::from_str(&json).map_err(|_| invalid("诊断暂存无法读取"))?);
            next = id;
        }
        Ok(MetadataDiagnosticsPage {
            diagnostics,
            next_cursor: next,
            done,
        })
    }
    pub fn cover_path(&self, path: String) -> Result<String> {
        if !super::archive::cover_path(&path) {
            return Err(invalid("封面路径不安全"));
        }
        let file = self.root.join(path);
        if !file.is_file() {
            return Err(invalid("封面文件缺失"));
        }
        Ok(file.to_string_lossy().into_owned())
    }
    pub fn write_diagnostics(&self, destination: String) -> Result<()> {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(destination)?;
        let mut cursor = 0;
        loop {
            let page = self.diagnostics(cursor, 100)?;
            for d in page.diagnostics {
                serde_json::to_writer(&mut file, &d).map_err(|_| invalid("无法导出诊断"))?;
                file.write_all(b"\n")?;
            }
            if page.done {
                break;
            }
            cursor = page.next_cursor;
        }
        Ok(())
    }
}
