use super::{
    archive::{self, MetadataArchiveOutput, cover_path},
    parse::{StrictValue, diagnostic},
    stream::{Input, MetadataInput},
    *,
};
use crate::{Result, storage::maintenance::archive_limits::*};
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use std::{
    cell::Cell,
    collections::HashSet,
    fmt,
    io::{BufRead, BufReader, Read},
    rc::Rc,
    sync::Arc,
};

/// Each callback stages at most one bounded record or diagnostic.
#[uniffi::export(with_foreign)]
pub trait MetadataStagingSink: Send + Sync {
    fn record(
        &self,
        sha: String,
        payload: String,
        source_line: Option<u64>,
        record_index: u64,
    ) -> Result<()>;
    fn diagnostic(&self, diagnostic: MetadataDiagnostic) -> Result<()>;
    fn has_cover(&self, name: String) -> bool;
}

fn save_diagnostic(
    sink: &dyn MetadataStagingSink,
    mut d: MetadataDiagnostic,
    line: Option<u64>,
    index: Option<u64>,
) -> Result<()> {
    d.source_line = line;
    d.record_index = index;
    sink.diagnostic(d)
}

fn save_book(
    sink: &dyn MetadataStagingSink,
    packaged: bool,
    value: serde_json::Value,
    line: Option<u64>,
    index: u64,
) -> Result<()> {
    match parse::book(value) {
        Err(d) => save_diagnostic(sink, *d, line, Some(index)),
        Ok((mut book, warnings)) => {
            for d in warnings {
                save_diagnostic(sink, d, line, Some(index))?;
            }
            if let Some(name) = &book.cover
                && (!packaged || !cover_path(name) || !sink.has_cover(name.clone()))
            {
                save_diagnostic(
                    sink,
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
            sink.record(book.content_sha256, payload, line, index)
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
    sink: &'a dyn MetadataStagingSink,
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
                            save_book(self.0.sink, self.0.packaged, value.0, None, index)
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
                        self.sink,
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

#[uniffi::export]
pub fn parse_metadata_manifest(
    input: Arc<dyn MetadataInput>,
    format: MetadataFormat,
    packaged: bool,
    sink: Arc<dyn MetadataStagingSink>,
) -> Result<()> {
    let input = Input::new(input);
    if input.length() > if packaged { MAX_TOTAL } else { MAX_ARCHIVE } {
        return Err(invalid("超过公共资源预算"));
    }
    let sink = sink.as_ref();
    let mut reader = BufReader::new(input);
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
                sink,
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
                        sink,
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
                    Ok(v) => save_book(sink, packaged, v.0, Some(line), index)?,
                    Err(_) => save_diagnostic(
                        sink,
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
pub fn unpack_metadata_archive(
    input: Arc<dyn MetadataInput>,
    destination: Arc<dyn MetadataArchiveOutput>,
    sink: Arc<dyn MetadataStagingSink>,
) -> Result<MetadataArchiveManifest> {
    let (manifest, warnings) = archive::unpack(Input::new(input), destination.as_ref())?;
    for _ in 0..warnings {
        save_diagnostic(
            sink.as_ref(),
            diagnostic("unused_member", None, None, "忽略未使用的附属文件"),
            None,
            None,
        )?;
    }
    Ok(manifest)
}

#[derive(uniffi::Record)]
pub struct MetadataArchiveManifest {
    pub name: String,
    pub format: MetadataFormat,
}

#[uniffi::export]
pub fn decode_staged_metadata_book(payload: String) -> Result<MetadataBook> {
    serde_json::from_str(&payload).map_err(|_| invalid("小说信息暂存无法读取"))
}
