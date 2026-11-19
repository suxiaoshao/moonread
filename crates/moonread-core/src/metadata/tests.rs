use super::*;
use serde_json::json;
use std::{
    collections::HashMap,
    io::{Cursor, Seek, SeekFrom, Write},
    sync::{Arc, Mutex},
};
use zip::{ZipWriter, write::SimpleFileOptions};

#[derive(Default)]
struct Bytes(Mutex<Vec<u8>>);

impl Bytes {
    fn from(bytes: impl Into<Vec<u8>>) -> Arc<Self> {
        Arc::new(Self(Mutex::new(bytes.into())))
    }
}

impl MetadataInput for Bytes {
    fn length(&self) -> u64 {
        self.0.lock().unwrap().len() as u64
    }

    fn read(&self, offset: u64, count: u32) -> crate::Result<Vec<u8>> {
        let data = self.0.lock().unwrap();
        let offset = (offset as usize).min(data.len());
        let end = (offset + count as usize).min(data.len());
        Ok(data[offset..end].to_vec())
    }
}

impl MetadataOutput for Bytes {
    fn write(&self, offset: u64, bytes: Vec<u8>) -> crate::Result<()> {
        let mut data = self.0.lock().unwrap();
        let mut cursor = Cursor::new(&mut *data);
        cursor.seek(SeekFrom::Start(offset))?;
        cursor.write_all(&bytes)?;
        Ok(())
    }
}

#[derive(Default)]
struct Stage {
    books: Mutex<Vec<(MetadataBook, Option<u64>, u64)>>,
    diagnostics: Mutex<Vec<MetadataDiagnostic>>,
    members: Mutex<HashMap<String, Arc<Bytes>>>,
}

impl MetadataStagingSink for Stage {
    fn record(
        &self,
        sha: String,
        payload: String,
        source_line: Option<u64>,
        record_index: u64,
    ) -> crate::Result<()> {
        let book = decode_staged_metadata_book(payload)?;
        assert_eq!(sha, book.content_sha256);
        self.books
            .lock()
            .unwrap()
            .push((book, source_line, record_index));
        Ok(())
    }

    fn diagnostic(&self, diagnostic: MetadataDiagnostic) -> crate::Result<()> {
        self.diagnostics.lock().unwrap().push(diagnostic);
        Ok(())
    }

    fn has_cover(&self, name: String) -> bool {
        self.members.lock().unwrap().contains_key(&name)
    }
}

impl MetadataArchiveOutput for Stage {
    fn create_member(&self, name: String) -> crate::Result<Arc<dyn MetadataOutput>> {
        let bytes = Arc::new(Bytes::default());
        self.members.lock().unwrap().insert(name, bytes.clone());
        Ok(bytes)
    }
}

impl MetadataArchiveInput for Stage {
    fn open_member(&self, name: String) -> crate::Result<Arc<dyn MetadataInput>> {
        Ok(self.members.lock().unwrap()[&name].clone())
    }
}

fn inspect(text: &str, format: MetadataFormat) -> Arc<Stage> {
    let stage = Arc::new(Stage::default());
    parse_metadata_manifest(Bytes::from(text), format, false, stage.clone()).unwrap();
    stage
}

fn inspect_archive(input: Arc<Bytes>) -> crate::Result<Arc<Stage>> {
    let stage = Arc::new(Stage::default());
    let manifest = unpack_metadata_archive(input, stage.clone(), stage.clone())?;
    parse_metadata_manifest(
        stage.open_member(manifest.name)?,
        manifest.format,
        true,
        stage.clone(),
    )?;
    Ok(stage)
}

fn archive(names: &[&str]) -> Arc<Bytes> {
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    for name in names {
        zip.start_file(*name, SimpleFileOptions::default()).unwrap();
        zip.write_all(b"{}").unwrap();
    }
    Bytes::from(zip.finish().unwrap().into_inner())
}

fn book() -> serde_json::Value {
    json!({"v":1,"content_sha256":"a".repeat(64),"author":"林舟","tags":["短篇"]})
}

#[test]
fn jsonl_isolates_bad_lines_capabilities_and_ignores_readonly_references() {
    let valid = book();
    let mut unknown = book();
    unknown["requires"] = json!(["future"]);
    let mut readonly = book();
    readonly["reference"] =
        json!({"match":{"path":"../../not-a-selector"},"author":"never written"});
    readonly["future_field"] = json!(42);
    let text = format!("\u{feff}\n{}\r\n{{bad}}\n{}\n{}", valid, unknown, readonly);
    let stage = inspect(&text, MetadataFormat::Jsonl);
    let records = stage.books.lock().unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].0, records[1].0);
    assert!(records[0].0.reference.is_none());
    assert_eq!(records[0].1, Some(2));
    let d = stage.diagnostics.lock().unwrap();
    assert!(
        d.iter()
            .any(|v| v.code == "invalid_json" && v.source_line == Some(3))
    );
    assert!(
        d.iter()
            .any(|v| v.code == "unsupported_feature" && v.source_line == Some(4))
    );
    assert!(d.iter().any(|v| v.code == "unknown_field"));
    let mut private_key = book();
    private_key["/private/source-or-secret-key"] = json!("not logged");
    let private_doc = inspect(&private_key.to_string(), MetadataFormat::Jsonl);
    let diagnostic = private_doc.diagnostics.lock().unwrap().remove(0);
    assert!(diagnostic.field.is_none());
    assert!(!diagnostic.message.contains("private"));
    for bad in ["{\"v\":1,\"v\":1}", "{\"v\":1,\"content_sha256\":null}"] {
        let stage = inspect(bad, MetadataFormat::Jsonl);
        assert!(stage.books.lock().unwrap().is_empty());
    }
}

#[test]
fn json_stream_and_writer_use_published_schema_and_roundtrip_samples() {
    let schema: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../docs/site/static/schema/moonread-metadata-v1.schema.json"
    ))
    .unwrap();
    let validator = jsonschema::draft202012::new(&schema).unwrap();
    // Published examples and runtime parsing are checked against the same schema.
    let example: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../docs/site/static/skills/moonread-metadata/examples/metadata.json"
    ))
    .unwrap();
    assert!(validator.is_valid(&example));
    let example_stage = inspect(&example.to_string(), MetadataFormat::Json);
    assert!(!example_stage.books.lock().unwrap().is_empty());
    for line in include_str!(
        "../../../../docs/site/static/skills/moonread-metadata/examples/metadata.jsonl"
    )
    .lines()
    .filter(|s| !s.trim().is_empty())
    {
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert!(validator.is_valid(&value));
        let stage = inspect(line, MetadataFormat::Jsonl);
        assert_eq!(stage.books.lock().unwrap().len(), 1);
    }
    let value = json!({"format":"moonread-metadata","version":1,"books":[book()]});
    assert!(validator.is_valid(&value));
    let stage = inspect(&value.to_string(), MetadataFormat::Json);
    let (b, source_line, index) = stage.books.lock().unwrap().remove(0);
    assert_eq!(source_line, None);
    assert_eq!(index, 0);
    assert!(validator.is_valid(&serde_json::to_value(&b).unwrap()));
    for format in [MetadataFormat::Json, MetadataFormat::Jsonl] {
        let output = Arc::new(Bytes::default());
        let writer = create_metadata_writer(output.clone(), format, false).unwrap();
        writer.append(b.clone()).unwrap();
        writer.finish().unwrap();
        let other = Arc::new(Stage::default());
        parse_metadata_manifest(output, format, false, other.clone()).unwrap();
        assert_eq!(other.books.lock().unwrap()[0].0, b);
    }
    let duplicate_keys = r#"{"format":"moonread-metadata","version":1,"books":[],"books":[]}"#;
    assert!(
        parse_metadata_manifest(
            Bytes::from(duplicate_keys),
            MetadataFormat::Json,
            false,
            Arc::new(Stage::default()),
        )
        .is_err()
    );
}

#[test]
fn metadata_zip_reuses_safety_and_missing_cover_only_blocks_cover() {
    for unsafe_name in [
        "../outside",
        "/outside",
        "covers/../outside",
        "covers\\outside",
    ] {
        assert!(inspect_archive(archive(&[unsafe_name])).is_err());
    }
    let mut b = book();
    b["cover"] = json!("covers/missing.png");
    let stage = inspect(&b.to_string(), MetadataFormat::Jsonl);
    let records = stage.books.lock().unwrap();
    assert_eq!(records[0].0.author.as_deref(), Some("林舟"));
    assert!(records[0].0.cover.is_none());
    assert_eq!(
        stage.diagnostics.lock().unwrap()[0].code,
        "cover_unavailable"
    );
    for names in [
        ["metadata.json", "metadata.jsonl"],
        ["covers/A.png", "covers/a.png"],
    ] {
        assert!(inspect_archive(archive(&names)).is_err());
    }

    let stage = Arc::new(Stage::default());
    let name = String::from("metadata.jsonl");
    stage
        .members
        .lock()
        .unwrap()
        .insert(name.clone(), Bytes::from(book().to_string()));
    let package = Arc::new(Bytes::default());
    encode_metadata_archive(vec![name], stage, package.clone()).unwrap();
    assert_eq!(
        inspect_archive(package)
            .unwrap()
            .books
            .lock()
            .unwrap()
            .len(),
        1
    );
}
