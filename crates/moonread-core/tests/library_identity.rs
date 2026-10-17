use moonread_core::{
    LibraryHandoffFile, ReaderCore, ReaderError, ScannedLibraryItem, SourceContentKey,
};
use sha2::{Digest, Sha256};
use std::{path::Path, sync::Arc};
use tempfile::TempDir;
fn raw(path: &Path) -> String {
    Sha256::digest(std::fs::read(path).unwrap())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn key(path: &Path, decoding: &str) -> SourceContentKey {
    SourceContentKey {
        raw_sha256: raw(path),
        decoding: decoding.into(),
    }
}
fn setup() -> (TempDir, Arc<ReaderCore>) {
    let d = TempDir::new().unwrap();
    let c = ReaderCore::new(d.path().join("db").to_string_lossy().into()).unwrap();
    for (id, builtin) in [("builtin", true), ("other", false)] {
        c.save_library_shelf(id.into(), id.into(), vec![1], "local".into(), builtin)
            .unwrap();
    }
    (d, c)
}
fn item(path: &str, directory: bool) -> ScannedLibraryItem {
    ScannedLibraryItem {
        relative_path: path.into(),
        directory,
        size: 100,
        modified: 1,
        needs_download: false,
    }
}
fn prepare(c: &ReaderCore, path: &Path, decoding: Option<&str>) -> String {
    let token = c.create_import("Synthetic".into()).unwrap();
    c.stream_import(
        token.clone(),
        path.to_string_lossy().into(),
        raw(path),
        decoding.map(Into::into),
    )
    .unwrap();
    c.finish_import(token).unwrap()
}
#[test]
fn scan_and_managed_tree_moves_preserve_last_known_links() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "正文甲").unwrap();
    let book = prepare(&c, &p, None);
    c.scan_library_shelf(
        "builtin".into(),
        vec![item("folder", true), item("folder/book.txt", false)],
    )
    .unwrap();
    let files = c.source_files("builtin".into()).unwrap();
    let f = files.iter().find(|v| !v.directory).unwrap();
    let dir = files.iter().find(|v| v.directory).unwrap();
    c.link_library_file(f.id.clone(), book.clone()).unwrap();
    let mut changed = item("folder/book.txt", false);
    changed.size = 10000;
    changed.modified = 99999;
    changed.needs_download = true;
    c.scan_library_shelf("builtin".into(), vec![item("folder", true), changed])
        .unwrap();
    assert_eq!(
        c.source_file_location(f.id.clone()).unwrap().book_id,
        Some(book.clone())
    );
    c.set_library_shelf_error("builtin".into(), Some("unavailable".into()))
        .unwrap();
    assert_eq!(
        c.source_file_location(f.id.clone()).unwrap().book_id,
        Some(book.clone())
    );
    c.relocate_library_entry(dir.id.clone(), "other".into(), "renamed".into())
        .unwrap();
    c.scan_library_shelf(
        "other".into(),
        vec![item("renamed", true), item("renamed/book.txt", false)],
    )
    .unwrap();
    let moved = c.source_file_location(f.id.clone()).unwrap();
    assert_eq!(moved.book_id, Some(book.clone()));
    assert_eq!(moved.relative_path, "renamed/book.txt");
    c.relocate_library_entry(f.id.clone(), "builtin".into(), "new.txt".into())
        .unwrap();
    assert_eq!(
        c.source_file_location(f.id.clone()).unwrap().book_id,
        Some(book)
    );
    c.scan_library_shelf("builtin".into(), vec![item("new.txt", true)])
        .unwrap();
    assert!(c.source_file_location(f.id.clone()).is_err());
    assert!(
        c.source_files("builtin".into()).unwrap()[0]
            .book_id
            .is_none()
    );
}
#[test]
fn external_rename_relinks_by_raw_bytes_and_changed_content_keeps_old_book() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "正文甲").unwrap();
    let old = prepare(&c, &p, None);
    c.scan_library_shelf("builtin".into(), vec![item("old.txt", false)])
        .unwrap();
    let f = c.source_files("builtin".into()).unwrap()[0].id.clone();
    c.link_library_file(f.clone(), old.clone()).unwrap();
    c.scan_library_shelf(
        "builtin".into(),
        vec![item("new.txt", false), item("copy.txt", false)],
    )
    .unwrap();
    assert!(c.source_file_location(f).is_err());
    for f in c.source_files("builtin".into()).unwrap() {
        assert!(f.book_id.is_none());
        let cached = c.source_book(key(&p, "auto")).unwrap().unwrap();
        c.link_library_file(f.id, cached.id).unwrap();
    }
    std::fs::write(&p, "正文乙").unwrap();
    assert!(c.source_book(key(&p, "auto")).unwrap().is_none());
    let new = prepare(&c, &p, None);
    assert_ne!(old, new);
    let f = c.source_files("builtin".into()).unwrap()[0].id.clone();
    c.link_library_file(f.clone(), new.clone()).unwrap();
    assert_eq!(c.source_file_location(f).unwrap().book_id, Some(new));
    assert!(
        c.query_snapshot("{}".into())
            .unwrap()
            .book_info(old)
            .is_ok()
    );
}
#[test]
fn decoding_policy_is_part_of_cache_key_and_persists() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "合法的中文正文").unwrap();
    let auto = prepare(&c, &p, None);
    assert!(c.source_book(key(&p, "utf-8")).unwrap().is_none());
    let explicit = prepare(&c, &p, Some("utf-8"));
    assert_eq!(auto, explicit);
    assert_eq!(c.source_book(key(&p, "UTF-8")).unwrap().unwrap().id, auto);
    assert!(c.source_book(key(&p, "gb18030")).unwrap().is_none());
    drop(c);
    let c = ReaderCore::new(d.path().join("db").to_string_lossy().into()).unwrap();
    assert_eq!(c.source_book(key(&p, "auto")).unwrap().unwrap().id, auto);
}
#[test]
fn replacement_after_preflight_never_publishes_a_false_mapping() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "正文甲".repeat(50000)).unwrap();
    let original = key(&p, "auto");
    let token = c.create_import("Synthetic".into()).unwrap();
    c.validate_import_source(token.clone(), original.clone())
        .unwrap();
    std::fs::write(&p, "正文乙".repeat(50000)).unwrap();
    assert!(matches!(
        c.stream_import(
            token.clone(),
            p.to_string_lossy().into(),
            original.raw_sha256.clone(),
            None
        ),
        Err(ReaderError::SourceChanged)
    ));
    assert!(c.finish_import(token).is_err());
    assert!(c.source_book(original).unwrap().is_none());
    assert!(c.source_book(key(&p, "auto")).unwrap().is_none());
}
#[test]
fn resume_rejects_prefix_tail_and_same_size_replacements_preserving_old_prefix() {
    for replacement in [
        format!("乙{}", "甲".repeat(50000)),
        format!("{}乙", "甲".repeat(50000)),
        "丙".repeat(50001),
    ] {
        let (d, c) = setup();
        let p = d.path().join("book.txt");
        std::fs::write(&p, "甲".repeat(50001)).unwrap();
        let token = c.create_import("Synthetic".into()).unwrap();
        let id = token.book_id();
        c.stream_import(token.clone(), p.to_string_lossy().into(), raw(&p), None)
            .unwrap();
        token.pause();
        c.fail_import(token, ReaderError::Paused).unwrap();
        let before = c
            .query_snapshot("{}".into())
            .unwrap()
            .reading_frame(id.clone(), 0)
            .unwrap()
            .chunks[0]
            .text
            .clone();
        std::fs::write(&p, replacement).unwrap();
        let next = c.resume_import(id.clone()).unwrap();
        assert!(matches!(
            c.stream_import(next, p.to_string_lossy().into(), raw(&p), None),
            Err(ReaderError::SourceChanged)
        ));
        assert_eq!(
            c.query_snapshot("{}".into())
                .unwrap()
                .reading_frame(id, 0)
                .unwrap()
                .chunks[0]
                .text,
            before
        );
        let new = prepare(&c, &p, None);
        assert!(!new.is_empty());
    }
}
#[test]
fn handoff_recovers_canonical_after_pending_alias_reclaimed_without_blessing_bytes() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "合成正文").unwrap();
    let canonical = prepare(&c, &p, None);
    c.scan_library_shelf("builtin".into(), vec![item("book.txt", false)])
        .unwrap();
    let f = c.source_files("builtin".into()).unwrap()[0].id.clone();
    let pending = c.create_import("Alias".into()).unwrap();
    let id = pending.book_id();
    c.link_library_file(f.clone(), id.clone()).unwrap();
    c.stream_import(pending.clone(), p.to_string_lossy().into(), raw(&p), None)
        .unwrap();
    c.finish_import(pending).unwrap();
    c.reclaim_completed_imports(vec![]).unwrap();
    c.publish_library_handoff(
        vec![2],
        vec![LibraryHandoffFile {
            file_id: f.clone(),
            book_id: Some(id),
            source: key(&p, "auto"),
            relative_path: "book.txt".into(),
        }],
    )
    .unwrap();
    assert_eq!(c.source_file_location(f).unwrap().book_id, Some(canonical));
}

#[test]
fn same_bytes_under_distinct_decoders_never_share_a_cache_entry() {
    let (d, c) = setup();
    let path = d.path().join("ambiguous.txt");
    std::fs::write(&path, [0xc2, 0xa1]).unwrap();
    let auto = prepare(&c, &path, None);
    let gb = prepare(&c, &path, Some("gb18030"));
    assert_ne!(auto, gb);
    assert_eq!(c.source_book(key(&path, "auto")).unwrap().unwrap().id, auto);
    assert_eq!(
        c.source_book(key(&path, "GB18030")).unwrap().unwrap().id,
        gb
    );
}

#[test]
fn invalid_scan_and_handoff_roll_back_without_losing_existing_locations() {
    let (_d, c) = setup();
    c.scan_library_shelf("builtin".into(), vec![item("book.txt", false)])
        .unwrap();
    let f = c.source_files("builtin".into()).unwrap()[0].clone();
    assert!(
        c.scan_library_shelf("builtin".into(), vec![item("../escape", false)])
            .is_err()
    );
    assert_eq!(
        c.source_file_location(f.id.clone()).unwrap().relative_path,
        "book.txt"
    );
    assert!(
        c.publish_library_handoff(
            vec![2],
            vec![LibraryHandoffFile {
                file_id: f.id.clone(),
                book_id: None,
                source: SourceContentKey {
                    raw_sha256: "a".repeat(64),
                    decoding: "auto".into()
                },
                relative_path: "../escape".into()
            }]
        )
        .is_err()
    );
    assert_eq!(c.library_shelves().unwrap()[0].bookmark, vec![1]);
    assert_eq!(
        c.source_file_location(f.id).unwrap().relative_path,
        "book.txt"
    );
}

#[test]
fn releasing_one_completed_alias_does_not_reclaim_other_jobs_or_canonical_text() {
    let (d, c) = setup();
    let p = d.path().join("book.txt");
    std::fs::write(&p, "第一章 合成\n仅用于回归的正文。\n").unwrap();
    let canonical = prepare(&c, &p, None);
    c.scan_library_shelf("builtin".into(), vec![item("book.txt", false)])
        .unwrap();
    let file = c.source_files("builtin".into()).unwrap()[0].id.clone();
    let first = c.create_import("First".into()).unwrap();
    let second = c.create_import("Second".into()).unwrap();
    c.reuse_import(first.clone(), canonical.clone()).unwrap();
    c.reuse_import(second.clone(), canonical.clone()).unwrap();
    c.link_library_file(file.clone(), first.book_id()).unwrap();
    assert!(c.reclaim_completed_import(first.book_id()).unwrap());
    assert!(c.import_status(first.book_id()).is_err());
    assert!(c.import_status(second.book_id()).is_ok());
    assert_eq!(
        c.source_file_location(file).unwrap().book_id,
        Some(canonical.clone())
    );
    assert!(c.read_chunk(canonical, 0).is_ok());
}

#[test]
fn selected_decoding_survives_reclaim_scan_moves_and_reopen() {
    let (d, c) = setup();
    let path = d.path().join("book.txt");
    let bytes: Vec<u8> = "第一章\n中文正文。\n"
        .encode_utf16()
        .flat_map(u16::to_le_bytes)
        .collect();
    std::fs::write(&path, bytes).unwrap();
    c.scan_library_shelf("builtin".into(), vec![item("book.txt", false)])
        .unwrap();
    let file = c.source_files("builtin".into()).unwrap()[0].id.clone();
    assert_eq!(c.source_decoding(file.clone()).unwrap(), "auto");
    c.set_source_decoding(file.clone(), "utf-16le".into())
        .unwrap();
    assert!(
        c.set_source_decoding(file.clone(), "invalid".into())
            .is_err()
    );
    let book = prepare(&c, &path, Some("utf-16le"));
    c.link_library_file(file.clone(), book.clone()).unwrap();
    c.reclaim_completed_imports(vec![]).unwrap();
    c.relocate_library_entry(file.clone(), "other".into(), "renamed.txt".into())
        .unwrap();
    c.scan_library_shelf("other".into(), vec![item("renamed.txt", false)])
        .unwrap();
    c.relocate_library_entry(file.clone(), "builtin".into(), "moved.txt".into())
        .unwrap();
    drop(c);
    let c = ReaderCore::new(d.path().join("db").to_string_lossy().into()).unwrap();
    let policy = c.source_decoding(file.clone()).unwrap();
    assert_eq!(policy, "UTF-16LE");
    let cached = c.source_book(key(&path, &policy)).unwrap().unwrap();
    assert_eq!(cached.id, book);
    let reopened = c.create_import("Reopened".into()).unwrap();
    c.reuse_import(reopened.clone(), cached.id.clone()).unwrap();
    c.link_library_file(file.clone(), reopened.book_id())
        .unwrap();
    assert!(c.reclaim_completed_import(reopened.book_id()).unwrap());
    assert_eq!(
        c.source_file_location(file.clone()).unwrap().book_id,
        Some(book)
    );
    assert_eq!(c.source_decoding(file).unwrap(), "UTF-16LE");
}
