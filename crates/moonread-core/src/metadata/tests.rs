use super::*;
use serde_json::json;
use std::fs;

fn inspect(text: &str, suffix: &str) -> (tempfile::TempDir, std::sync::Arc<MetadataDocument>) {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join(format!("input.{suffix}"));
    fs::write(&path, text).unwrap();
    let doc = inspect_metadata_exchange(
        path.to_string_lossy().into(),
        temp.path().join("stage").to_string_lossy().into(),
    )
    .unwrap();
    (temp, doc)
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
    let (_tmp, doc) = inspect(&text, "jsonl");
    let summary = doc.summary().unwrap();
    assert_eq!(summary.books, 1);
    assert_eq!(summary.variants, 1);
    let rows = doc.records(None, 0, 100).unwrap();
    assert_eq!(rows.records[0].duplicates, 2);
    assert!(rows.records[0].book.reference.is_none());
    assert_eq!(rows.records[0].source_line, Some(2));
    let d = doc.diagnostics(0, 100).unwrap().diagnostics;
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
    let (_private_dir, private_doc) = inspect(&private_key.to_string(), "jsonl");
    let diagnostic = private_doc
        .diagnostics(0, 10)
        .unwrap()
        .diagnostics
        .remove(0);
    assert!(diagnostic.field.is_none());
    assert!(!diagnostic.message.contains("private"));
    for bad in ["{\"v\":1,\"v\":1}", "{\"v\":1,\"content_sha256\":null}"] {
        let (_temp, doc) = inspect(bad, "jsonl");
        assert_eq!(doc.summary().unwrap().books, 0);
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
    let (_example_dir, example_doc) = inspect(&example.to_string(), "json");
    assert!(example_doc.summary().unwrap().books > 0);
    for line in include_str!(
        "../../../../docs/site/static/skills/moonread-metadata/examples/metadata.jsonl"
    )
    .lines()
    .filter(|s| !s.trim().is_empty())
    {
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert!(validator.is_valid(&value));
        let (_dir, document) = inspect(line, "jsonl");
        assert_eq!(document.summary().unwrap().books, 1);
    }
    let value = json!({"format":"moonread-metadata","version":1,"books":[book()]});
    assert!(validator.is_valid(&value));
    let (tmp, doc) = inspect(&value.to_string(), "json");
    let b = doc.records(None, 0, 1).unwrap().records.remove(0).book;
    assert!(validator.is_valid(&serde_json::to_value(&b).unwrap()));
    for format in [MetadataFormat::Json, MetadataFormat::Jsonl] {
        let path = tmp.path().join(if format == MetadataFormat::Json {
            "out.json"
        } else {
            "out.jsonl"
        });
        let writer = create_metadata_writer(path.to_string_lossy().into(), format, false).unwrap();
        writer.append(b.clone()).unwrap();
        writer.finish().unwrap();
        let other = inspect_metadata_exchange(
            path.to_string_lossy().into(),
            tmp.path().join("stage").to_string_lossy().into(),
        )
        .unwrap();
        assert_eq!(other.summary().unwrap().books, 1);
    }
    let path = tmp.path().join("bad.json");
    fs::write(
        &path,
        "{\"format\":\"moonread-metadata\",\"version\":1,\"books\":[],\"books\":[]}",
    )
    .unwrap();
    assert!(
        inspect_metadata_exchange(
            path.to_string_lossy().into(),
            tmp.path().join("stage").to_string_lossy().into()
        )
        .is_err()
    );
}

#[test]
fn metadata_zip_reuses_safety_and_missing_cover_only_blocks_cover() {
    use std::io::Write;
    use zip::{ZipWriter, write::SimpleFileOptions};
    let tmp = tempfile::tempdir().unwrap();
    for unsafe_name in [
        "../outside",
        "/outside",
        "covers/../outside",
        "covers\\outside",
    ] {
        let path = tmp.path().join("bad.moonread-metadata");
        let mut zip = ZipWriter::new(fs::File::create(&path).unwrap());
        zip.start_file(unsafe_name, SimpleFileOptions::default())
            .unwrap();
        zip.write_all(b"bad").unwrap();
        zip.finish().unwrap();
        assert!(
            inspect_metadata_exchange(
                path.to_string_lossy().into(),
                tmp.path().join("stage").to_string_lossy().into()
            )
            .is_err()
        );
    }
    let mut b = book();
    b["cover"] = json!("covers/missing.png");
    let (_tmp, doc) = inspect(&b.to_string(), "jsonl");
    let page = doc.records(None, 0, 1).unwrap();
    assert_eq!(page.records[0].book.author.as_deref(), Some("林舟"));
    assert!(page.records[0].book.cover.is_none());
    assert_eq!(
        doc.diagnostics(0, 10).unwrap().diagnostics[0].code,
        "cover_unavailable"
    );
    for names in [
        vec!["metadata.json", "metadata.jsonl"],
        vec!["covers/A.png", "covers/a.png"],
    ] {
        let path = tmp.path().join("collisions.zip");
        let mut zip = ZipWriter::new(fs::File::create(&path).unwrap());
        for name in names {
            zip.start_file(name, SimpleFileOptions::default()).unwrap();
            zip.write_all(b"{}").unwrap();
        }
        zip.finish().unwrap();
        assert!(
            inspect_metadata_exchange(
                path.to_string_lossy().into(),
                tmp.path().join("stage").to_string_lossy().into()
            )
            .is_err()
        );
    }
    let root = tmp.path().join("export");
    fs::create_dir(&root).unwrap();
    fs::write(root.join("metadata.jsonl"), book().to_string()).unwrap();
    let package = tmp.path().join("good.moonread-metadata");
    write_metadata_archive(
        root.to_string_lossy().into(),
        package.to_string_lossy().into(),
    )
    .unwrap();
    assert_eq!(
        inspect_metadata_exchange(
            package.to_string_lossy().into(),
            tmp.path().join("stage").to_string_lossy().into()
        )
        .unwrap()
        .summary()
        .unwrap()
        .books,
        1
    );
}
