//! Original UTF-8 sources; encoded bytes are generated at runtime, never real novels.
use encoding_rs::Encoding;
use moonread_core::{ReaderCore, ReaderError, SourceContentKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use tempfile::TempDir;

#[derive(Deserialize)]
struct Sample {
    id: String,
    encoding: String,
    bom: bool,
    text: String,
    detected: String,
}
fn bytes(sample: &Sample) -> Vec<u8> {
    let mut bytes = match sample.encoding.as_str() {
        "UTF-16LE" => sample
            .text
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect(),
        "UTF-16BE" => sample
            .text
            .encode_utf16()
            .flat_map(u16::to_be_bytes)
            .collect(),
        _ => {
            let encoding = Encoding::for_label(sample.encoding.as_bytes()).unwrap();
            let (encoded, _, errors) = encoding.encode(&sample.text);
            assert!(!errors, "{} cannot be represented losslessly", sample.id);
            encoded.into_owned()
        }
    };
    if sample.bom {
        let bom = match sample.encoding.as_str() {
            "UTF-8" => &[0xef, 0xbb, 0xbf][..],
            "UTF-16LE" => &[0xff, 0xfe],
            "UTF-16BE" => &[0xfe, 0xff],
            _ => panic!("Unexpected BOM"),
        };
        bytes.splice(..0, bom.iter().copied());
    }
    bytes
}
fn body(core: &ReaderCore, id: &str, count: u32) -> String {
    (0..count)
        .map(|i| core.read_chunk(id.into(), i).unwrap().text)
        .collect()
}

#[test]
fn frozen_corpus_detects_and_decodes_identically_through_both_import_paths() {
    let samples: Vec<Sample> =
        serde_json::from_str(include_str!("fixtures/encodings/corpus.json")).unwrap();
    let mut mismatches = Vec::new();
    for sample in samples {
        let root = TempDir::new().unwrap();
        let file = root.path().join("source.txt");
        let bytes = bytes(&sample);
        std::fs::write(&file, &bytes).unwrap();
        let expected = sample.text.replace("\r\n", "\n").replace('\r', "\n");
        let expected_sha = Sha256::digest(expected.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let direct = ReaderCore::new(root.path().join("direct").to_string_lossy().into()).unwrap();
        let book = direct
            .import_book(file.to_string_lossy().into(), sample.id.clone())
            .unwrap();
        if book.encoding != sample.detected {
            mismatches.push(format!(
                "{}: expected {}, detected {}, decoded {:?}",
                sample.id,
                sample.detected,
                book.encoding,
                body(&direct, &book.id, book.chunk_count)
            ));
            continue;
        }
        assert_eq!(
            body(&direct, &book.id, book.chunk_count),
            expected,
            "{} direct",
            sample.id
        );
        assert_eq!(book.content_sha256, expected_sha, "{} SHA", sample.id);

        let stream = ReaderCore::new(root.path().join("stream").to_string_lossy().into()).unwrap();
        let token = stream.create_import(sample.id.clone()).unwrap();
        let raw = stream
            .hash_import_source(token.clone(), file.to_string_lossy().into())
            .unwrap();
        stream
            .stream_import(
                token.clone(),
                file.to_string_lossy().into(),
                raw.clone(),
                None,
            )
            .unwrap();
        let id = stream.finish_import(token).unwrap();
        let book = stream
            .source_book(SourceContentKey {
                raw_sha256: raw,
                decoding: "auto".into(),
            })
            .unwrap()
            .unwrap();
        assert_eq!(book.encoding, sample.detected, "{} progressive", sample.id);
        assert_eq!(
            body(&stream, &id, book.chunk_count),
            expected,
            "{} progressive",
            sample.id
        );
        assert_eq!(
            book.content_sha256, expected_sha,
            "{} progressive SHA",
            sample.id
        );
        assert_eq!(std::fs::read(&file).unwrap(), bytes);
    }
    assert!(
        mismatches.is_empty(),
        "Frozen corpus changed:\n{}",
        mismatches.join("\n")
    );
}

#[test]
fn explicit_legacy_encoding_survives_reclaim_and_reopen() {
    let root = TempDir::new().unwrap();
    let core = ReaderCore::new(root.path().join("db").to_string_lossy().into()).unwrap();
    let original = "窓の外には静かな朝がありました。新しい本を読みます。\n";
    let (shift_jis, _, errors) = encoding_rs::SHIFT_JIS.encode(original);
    assert!(!errors);
    let utf16be: Vec<u8> = original.encode_utf16().flat_map(u16::to_be_bytes).collect();
    for (encoding, bytes) in [("Shift_JIS", shift_jis.into_owned()), ("UTF-16BE", utf16be)] {
        let core = ReaderCore::new(root.path().join(encoding).to_string_lossy().into()).unwrap();
        let path = root.path().join("source.txt");
        std::fs::write(&path, &bytes).unwrap();
        let token = core.create_import("Original".into()).unwrap();
        let raw = core
            .hash_import_source(token.clone(), path.to_string_lossy().into())
            .unwrap();
        core.stream_import(
            token.clone(),
            path.to_string_lossy().into(),
            raw.clone(),
            Some(encoding.into()),
        )
        .unwrap();
        core.finish_import(token.clone()).unwrap();
        core.reclaim_completed_import(token.book_id()).unwrap();
        let reopened = core
            .source_book(SourceContentKey {
                raw_sha256: raw,
                decoding: encoding.into(),
            })
            .unwrap()
            .unwrap();
        assert_eq!(body(&core, &reopened.id, reopened.chunk_count), original);
        assert_eq!(reopened.encoding, encoding);
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    assert!(matches!(
        core.source_book(SourceContentKey {
            raw_sha256: "a".repeat(64),
            decoding: "replacement".into()
        }),
        Err(ReaderError::InvalidSettings)
    ));
}
