//! Original UTF-8 sources; encoded bytes are generated at runtime, never real novels.
use encoding_rs::Encoding;
use moonread_core::{ReaderCore, SourceContentKey};
use serde::Deserialize;
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
        if ![
            "utf8",
            "utf8-bom",
            "utf16le",
            "utf16be",
            "gb18030",
            "gb18030-short",
            "big5",
            "shift-jis",
            "euc-jp",
            "euc-kr",
            "windows-1252",
            "windows-1252-eof",
            "iso-2022-jp",
        ]
        .contains(&sample.id.as_str())
        {
            continue;
        }
        let root = TempDir::new().unwrap();
        let file = root.path().join("source.txt");
        let bytes = bytes(&sample);
        std::fs::write(&file, &bytes).unwrap();
        let expected = sample.text.replace("\r\n", "\n").replace('\r', "\n");
        let expected_sha = match sample.id.as_str() {
            "utf8" => "bf18e419db634cbc944f3be8c32feb2d3337d2bed1ff4b9bba52ee6d385dac68",
            "utf8-bom" => "5c2f7bbb7ee7300e93abe16be48b83d4a6d6cd06567a42aed43877bd05d32a0e",
            "utf16le" => "b153733af344c8aded24ccad30c5a05cc4d72221dc210176079bc89bddf1fdeb",
            "utf16be" => "b153733af344c8aded24ccad30c5a05cc4d72221dc210176079bc89bddf1fdeb",
            "gb18030" => "93931c416d6356c736343cd4b3a72ec0708e69c4c391a91e705482f7333513a8",
            "gb18030-short" => "72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21",
            "big5" => "7a543a4d248e0a2ff6547aafd17977c46f444274515e16486598460b0fcd3384",
            "shift-jis" => "5f6897343e3638763afcea31be5407fce223f3f34007420ae298fe6cb3bea699",
            "euc-jp" => "5f6897343e3638763afcea31be5407fce223f3f34007420ae298fe6cb3bea699",
            "euc-kr" => "aa53a27bdbd25b09ca6e499bc0ca342e2aa01cefe6c273c0971af15398b188c0",
            "windows-1252" => "43459ab6034ff9f6ddaca10f3e8eec2afb63089a42a70577d0814543d976c848",
            "windows-1252-eof" => {
                "e6e20bfa14b8778e3260689ca7062f801e0431a3feb1e7ea0f56b07d83292dba"
            }
            "iso-2022-jp" => "431b19d2d004a88413a295baf231185d85307b167ae0961d7437d98a62f081d8",
            _ => continue,
        };
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
