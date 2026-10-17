use moonread_core::{ReaderCore, ReaderError};
use tempfile::TempDir;
use unicode_segmentation::UnicodeSegmentation;

fn core(dir: &TempDir) -> std::sync::Arc<ReaderCore> {
    ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap()
}

fn import(core: &ReaderCore, dir: &TempDir, name: &str, bytes: &[u8]) -> moonread_core::ImportText {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    core.import_book(path.to_string_lossy().into(), name.into())
        .unwrap()
}
fn full_text(core: &ReaderCore, book: &moonread_core::ImportText) -> String {
    let mut result = String::new();
    for index in 0..book.chunk_count {
        let chunk = core.read_chunk(book.id.clone(), index).unwrap();
        assert_eq!(chunk.start_utf8, result.len() as u64);
        assert_eq!(chunk.end_utf8 - chunk.start_utf8, chunk.text.len() as u64);
        assert!(chunk.text.len() <= 12 * 1024);
        assert_eq!(
            core.find_chunk(book.id.clone(), chunk.start_utf8).unwrap(),
            index
        );
        result.push_str(&chunk.text);
    }
    assert_eq!(result.len() as u64, book.byte_count);
    result
}

#[test]
fn long_unicode_paragraphs_and_chunk_boundaries_are_lossless() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let text = format!(
        "{}\n{}",
        "中🌙👨‍👩‍👧‍👦e\u{301}".repeat(25000),
        "短行\n".repeat(5000)
    );
    let book = import(&core, &dir, "unicode.txt", text.as_bytes());
    assert!(book.chunk_count > 10);
    assert_eq!(full_text(&core, &book), text);
    assert_eq!(
        std::fs::read(dir.path().join("unicode.txt")).unwrap(),
        text.as_bytes()
    );
    assert_eq!(
        core.find_chunk(book.id.clone(), u64::MAX).unwrap(),
        book.chunk_count - 1
    );
}

#[test]
fn encodings_and_newlines_share_normalized_identity() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let expected = "中文\n第二行\n最后一行\n";
    let input = "中文\r\n第二行\r最后一行\n";
    let utf8 = import(
        &core,
        &dir,
        "utf8.txt",
        format!("\u{feff}{input}").as_bytes(),
    );
    assert_eq!(full_text(&core, &utf8), expected);
    let mut le = vec![0xff, 0xfe];
    let mut be = vec![0xfe, 0xff];
    for unit in input.encode_utf16() {
        le.extend(unit.to_le_bytes());
        be.extend(unit.to_be_bytes());
    }
    let (gb, _, errors) = encoding_rs::GBK.encode(input);
    assert!(!errors);
    for (name, bytes) in [
        ("utf16le.txt", le.as_slice()),
        ("utf16be.txt", be.as_slice()),
        ("gbk.txt", gb.as_ref()),
    ] {
        let book = import(&core, &dir, name, bytes);
        assert_eq!(book.id, utf8.id);
        assert_eq!(full_text(&core, &book), expected);
    }
    assert_eq!(
        rusqlite::Connection::open(dir.path().join("data/reader.sqlite3"))
            .unwrap()
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn gb18030_four_byte_sequences_decode_without_replacement() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let (bytes, _, errors) = encoding_rs::GB18030.encode("月读🌙中文");
    assert!(!errors);
    let book = import(&core, &dir, "gb18030.txt", &bytes);
    assert_eq!(book.encoding, "gb18030");
    assert_eq!(full_text(&core, &book), "月读🌙中文");
}

#[test]
fn normalization_handles_decoder_buffer_boundaries() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let text = format!("{}\r\n中文🌙\r", "a".repeat(8191));
    let book = import(&core, &dir, "boundary.txt", text.as_bytes());
    assert_eq!(
        full_text(&core, &book),
        format!("{}\n中文🌙\n", "a".repeat(8191))
    );
}

#[test]
fn chunks_preserve_graphemes_across_chunk_and_decoder_boundaries() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    // Force both the chunk target and an 8 KiB decoder read to land inside each cluster.
    for boundary in [8192, 12288, 16384, 24576] {
        for (variant, cluster) in ["👨‍👩‍👧‍👦", "e\u{301}", "🇨🇳"].iter().enumerate()
        {
            let text = format!(
                "{}{}{}",
                "a".repeat(boundary - 1),
                cluster,
                "结尾".repeat(9000)
            );
            let book = import(
                &core,
                &dir,
                &format!("grapheme-{boundary}-{variant}.txt"),
                text.as_bytes(),
            );
            let boundaries: std::collections::HashSet<usize> = text
                .grapheme_indices(true)
                .map(|(i, _)| i)
                .chain(std::iter::once(text.len()))
                .collect();
            for index in 0..book.chunk_count {
                let chunk = core.read_chunk(book.id.clone(), index).unwrap();
                assert!(boundaries.contains(&(chunk.start_utf8 as usize)));
                assert!(boundaries.contains(&(chunk.end_utf8 as usize)));
            }
            assert_eq!(full_text(&core, &book), text);
        }
    }
}

#[test]
fn long_grapheme_extends_chunk_and_excessive_grapheme_is_rejected_without_fallback() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let cluster = format!("e{}", "\u{301}".repeat(10_000));
    let text = format!("{cluster}尾");
    let book = import(&core, &dir, "long-grapheme.txt", text.as_bytes());
    assert_eq!(core.read_chunk(book.id.clone(), 0).unwrap().text, cluster);
    let joined: String = (0..book.chunk_count)
        .map(|index| core.read_chunk(book.id.clone(), index).unwrap().text)
        .collect();
    assert_eq!(joined, text);

    let path = dir.path().join("excessive-grapheme.txt");
    std::fs::write(&path, format!("e{}", "\u{301}".repeat(32_768))).unwrap();
    assert!(matches!(
        core.import_book(path.to_string_lossy().into(), "excessive".into()),
        Err(ReaderError::GraphemeTooLong)
    ));
    assert_eq!(
        rusqlite::Connection::open(dir.path().join("data/reader.sqlite3"))
            .unwrap()
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn chapter_lookup_recognizes_chinese_and_english_headings_by_offset() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let text = "作品序言\n作者的话\n\n第一章巫师世界\n正文内容\n第2回：归途\n更多内容\nChapter 3 — The Return\nEnding";
    let book = import(&core, &dir, "chapters.txt", text.as_bytes());

    assert!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(book.id.clone(), 0)
            .unwrap()
            .is_none()
    );
    let first = text.find("第一章").unwrap() as u64;
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(book.id.clone(), first + 8)
            .unwrap()
            .unwrap()
            .title,
        "第一章巫师世界"
    );
    let second = text.find("第2回").unwrap() as u64;
    let chapter = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_at(book.id.clone(), second + 4)
        .unwrap()
        .unwrap();
    assert_eq!(chapter.title, "第2回：归途");
    assert_eq!(chapter.start_utf8, second);
    let third = text.find("Chapter 3").unwrap() as u64;
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(book.id, third + 10)
            .unwrap()
            .unwrap()
            .title,
        "Chapter 3 — The Return"
    );
}

#[test]
fn chapter_lookup_recognizes_preface_but_ignores_prose_without_headings() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let front_matter = import(
        &core,
        &dir,
        "front-matter.txt",
        "前言\nChapter title discussion\n\n第三节 小雨\n正文".as_bytes(),
    );
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(front_matter.id.clone(), 8)
            .unwrap()
            .unwrap()
            .title,
        "前言"
    );
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(front_matter.id, u64::MAX)
            .unwrap()
            .unwrap()
            .title,
        "第三节 小雨"
    );

    let no_heading = import(
        &core,
        &dir,
        "no-heading.txt",
        "这本书没有章节标记。\nChapter title is only a phrase.".as_bytes(),
    );
    assert!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(no_heading.id, u64::MAX)
            .unwrap()
            .is_none()
    );
}

#[test]
fn unsupported_store_versions_are_rejected_without_reset() {
    let dir = TempDir::new().unwrap();
    drop(core(&dir));
    let db = rusqlite::Connection::open(dir.path().join("data/reader.sqlite3")).unwrap();
    db.execute_batch("PRAGMA user_version=21").unwrap();
    assert!(matches!(
        ReaderCore::new(dir.path().join("data").to_string_lossy().into()),
        Err(ReaderError::StoreTooNew {
            version: 21,
            current: 20
        })
    ));
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
            .unwrap(),
        21
    );
    db.execute_batch("PRAGMA user_version=1").unwrap();
    assert!(matches!(
        ReaderCore::new(dir.path().join("data").to_string_lossy().into()),
        Err(ReaderError::IncompatibleStore)
    ));
}
