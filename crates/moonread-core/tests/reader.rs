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
    let text = format!("{}👨‍👩‍👧‍👦e\u{301}{}", "a".repeat(8191), "中🌙".repeat(800));
    let book = import(&core, &dir, "unicode.txt", text.as_bytes());
    assert_eq!(full_text(&core, &book), text);
    let boundaries: std::collections::HashSet<usize> = text
        .grapheme_indices(true)
        .map(|(i, _)| i)
        .chain([text.len()])
        .collect();
    for index in 0..book.chunk_count {
        let chunk = core.read_chunk(book.id.clone(), index).unwrap();
        assert!(boundaries.contains(&(chunk.start_utf8 as usize)));
        assert!(boundaries.contains(&(chunk.end_utf8 as usize)));
    }
    assert_eq!(
        std::fs::read(dir.path().join("unicode.txt")).unwrap(),
        text.as_bytes()
    );
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
    let text = "前言\n原文。\n第一卷 星港\n第1章 归舟\n正文。\nChapter 2 Moon\n尾声正文。\n";
    let book = import(&core, &dir, "chapters.txt", text.as_bytes());
    let query = core.query_snapshot("{}".into()).unwrap();
    let outline = query.chapter_outline(book.id.clone()).unwrap();
    assert_eq!(outline.items.len(), 4);
    for item in &outline.items {
        assert_eq!(
            query
                .chapter_at(book.id.clone(), item.start_utf8)
                .unwrap()
                .unwrap()
                .title,
            item.title
        );
    }
    let volume = text.find("第一卷").unwrap() as u64;
    assert_eq!(outline.items[1].level, 0);
    assert_eq!(outline.items[2].parent_utf8, Some(volume));
    let plain = import(&core, &dir, "plain.txt", "这本书没有章节标记。".as_bytes());
    assert!(
        query.chapter_at(plain.id, u64::MAX).unwrap().is_none(),
        "prose must not acquire an invented chapter"
    );
}
