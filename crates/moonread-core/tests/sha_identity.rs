use moonread_core::{ReaderCore, SourceContentKey};
use tempfile::TempDir;

#[test]
fn raw_counted_and_normalized_import_hashes_match_sha010_database_values() {
    let root = TempDir::new().unwrap();
    let core = ReaderCore::new(root.path().join("db").to_string_lossy().into()).unwrap();
    let text = "第一章 春风\r\n中文正文。\r\n";
    let fixtures = [
        (
            "utf8",
            text.as_bytes().to_vec(),
            "a75a54637975d3955b99cfad7abaeaf3a55ad7ac0ecf91438d38b67e826eea3a",
        ),
        (
            "bom",
            [b"\xef\xbb\xbf".as_slice(), text.as_bytes()].concat(),
            "fd9c5a61dec44b88ffeeebcad7a9f7f0986e6509a9c300c38cbccdbcf8d5567c",
        ),
        (
            "gb18030",
            encoding_rs::GB18030.encode(text).0.into_owned(),
            "72f19e5bbf0b6b984a882666ad044e0331f6bee3445f470832b99b123c65ab08",
        ),
        (
            "utf16le",
            [
                vec![0xff, 0xfe],
                text.encode_utf16().flat_map(u16::to_le_bytes).collect(),
            ]
            .concat(),
            "5e9d6cf1efeeb6a69d3b40abd77e93b0a7d88fc556dc9f7c3d2c78ff3882fbe6",
        ),
    ];
    for (name, bytes, expected_raw) in fixtures {
        let path = root.path().join(format!("{name}.txt"));
        std::fs::write(&path, &bytes).unwrap();
        let imported = core
            .import_book(path.to_string_lossy().into(), name.into())
            .unwrap();
        assert_eq!(
            imported.content_sha256,
            "5aae5263622e54a70db8174765a6171f6e3447f4eedd84c37a773474a62c8be2"
        );
        let control = core.create_import(name.into()).unwrap();
        assert_eq!(
            core.hash_import_source(control.clone(), path.to_string_lossy().into())
                .unwrap(),
            expected_raw
        );
        let key = SourceContentKey {
            raw_sha256: expected_raw.into(),
            decoding: "auto".into(),
        };
        core.validate_import_source(control.clone(), key.clone())
            .unwrap();
        // stream_import's CountingReader checks the same raw input before publishing the cache.
        core.stream_import(
            control.clone(),
            path.to_string_lossy().into(),
            expected_raw.into(),
            None,
        )
        .unwrap();
        core.finish_import(control).unwrap();
        assert_eq!(
            core.source_book(key).unwrap().unwrap().content_sha256,
            imported.content_sha256
        );
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
}
