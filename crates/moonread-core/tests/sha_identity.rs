use moonread_core::{
    TextImportMode, advance_text_import, begin_text_import, detect_import_encoding,
};

#[test]
fn raw_counted_and_normalized_import_hashes_match_sha010_database_values() {
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
        let encoding = detect_import_encoding(bytes.clone()).unwrap();
        let input = begin_text_import(encoding, TextImportMode::Identity, 0).unwrap();
        let result = advance_text_import(input, bytes, true, vec![])
            .unwrap()
            .identity
            .unwrap();
        assert_eq!(result.raw_sha256, expected_raw, "{name} raw");
        assert_eq!(
            result.content_sha256,
            "5aae5263622e54a70db8174765a6171f6e3447f4eedd84c37a773474a62c8be2",
            "{name} normalized"
        );
    }
}
