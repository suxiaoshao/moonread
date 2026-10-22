use moonread_core::{LibrarySort, ReaderCore, ScannedLibraryItem, library_child_path};
use tempfile::TempDir;

fn core(dir: &TempDir) -> std::sync::Arc<ReaderCore> {
    let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
    for (id, builtin) in [("builtin", true), ("external", false)] {
        core.save_library_shelf(id.into(), id.into(), vec![1], "local".into(), builtin)
            .unwrap();
    }
    core
}
fn item(path: &str, directory: bool) -> ScannedLibraryItem {
    ScannedLibraryItem {
        relative_path: path.into(),
        directory,
        size: 50,
        modified: 1,
        needs_download: false,
    }
}

#[test]
fn scope_tree_and_natural_order_use_only_metadata() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    core.scan_library_shelf(
        "builtin".into(),
        vec![
            item("奇幻", true),
            item("奇幻/山海.txt", false),
            item("10.txt", false),
            item("2.txt", false),
        ],
    )
    .unwrap();
    core.scan_library_shelf("external".into(), vec![item("山中.txt", false)])
        .unwrap();
    let root = core
        .query_snapshot("{}".into())
        .unwrap()
        .library_entries(Some("builtin".into()), Some("".into()), LibrarySort::Name)
        .unwrap();
    assert_eq!(
        root.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(),
        ["奇幻", "2.txt", "10.txt"]
    );
    assert_eq!(root[0].child_book_count, 1);
    assert_eq!(root[0].cover_previews[0].name, "山海.txt");
    let catalogue = core
        .query_snapshot("{}".into())
        .unwrap()
        .all_library_books("builtin".into())
        .unwrap();
    assert_eq!(
        catalogue
            .iter()
            .map(|e| e.name.as_str())
            .collect::<Vec<_>>(),
        ["2.txt", "10.txt", "山海.txt"]
    );
    assert!(
        catalogue
            .iter()
            .all(|e| !e.directory && e.shelf_id == "builtin")
    );
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .search_library(None, "山".into(), None, None)
            .unwrap()
            .len(),
        2
    );
    let scoped = core
        .query_snapshot("{}".into())
        .unwrap()
        .search_library(Some("builtin".into()), "山".into(), None, None)
        .unwrap();
    assert_eq!(scoped.len(), 1);
    assert_eq!(scoped[0].parent_path, "奇幻");
    assert!(
        core.query_snapshot("{}".into())
            .unwrap()
            .recent_library_entries(3)
            .unwrap()
            .is_empty()
    );
    assert!(
        rusqlite::Connection::open(dir.path().join("data/reader.sqlite3"))
            .unwrap()
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get::<_, i64>(0))
            .unwrap()
            == 0,
        "Listing/search never ingests novels"
    );
    core.scan_library_shelf(
        "external".into(),
        vec![
            item("月.txt", false),
            item("阿.txt", false),
            item("10.txt", false),
            item("2.txt", false),
        ],
    )
    .unwrap();
    let names = core
        .query_snapshot("{}".into())
        .unwrap()
        .library_entries(Some("external".into()), Some("".into()), LibrarySort::Name)
        .unwrap();
    assert_eq!(
        names.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        ["2.txt", "10.txt", "月.txt", "阿.txt"],
        "natural names including Chinese alphabet classes"
    );
}

#[test]
fn reading_order_mixes_books_and_folders_and_keeps_empty_folders_last() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let files = [
        ("Fresh.txt", false, 1),
        ("Shelf", true, 1),
        ("Shelf/Nested", true, 1),
        ("Shelf/Nested/read.txt", false, 1),
        ("2read.txt", false, 1),
        ("10read.txt", false, 9000),
        ("New.txt", false, 900),
        ("Unread", true, 800),
        ("Unread/child.txt", false, 1),
        ("Old.txt", false, 100),
        ("Empty2", true, 9999),
        ("Empty10", true, 9999),
        ("Empty2/Nested", true, 9999),
    ]
    .into_iter()
    .map(|(path, directory, modified)| {
        let mut entry = item(path, directory);
        entry.modified = modified;
        entry
    })
    .collect();
    core.scan_library_shelf("builtin".into(), files).unwrap();
    let all = core
        .query_snapshot("{}".into())
        .unwrap()
        .all_library_books("builtin".into())
        .unwrap();
    let mut positions = Vec::new();
    for (path, updated) in [
        ("Fresh.txt", 300),
        ("Shelf/Nested/read.txt", 200),
        ("2read.txt", 100),
        ("10read.txt", 100),
    ] {
        let source = dir.path().join("source.txt");
        std::fs::write(&source, format!("Chapter 1\nUnique fixture {path}")).unwrap();
        let book = core
            .import_book(source.to_string_lossy().into(), path.into())
            .unwrap();
        let file = all
            .iter()
            .find(|entry| entry.relative_path == path)
            .unwrap();
        core.link_library_file(file.id.clone(), book.id.clone())
            .unwrap();
        positions.push(serde_json::json!({"content_key": book.content_sha256, "offset": 0, "updated": updated, "visible": true, "preferred": file.id}));
    }
    let query = core
        .query_snapshot(serde_json::json!({"positions": positions}).to_string())
        .unwrap();
    let entries = query
        .library_entries(
            Some("builtin".into()),
            Some("".into()),
            LibrarySort::Reading,
        )
        .unwrap();
    assert_eq!(
        entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        [
            "Fresh.txt",
            "Shelf",
            "2read.txt",
            "10read.txt",
            "New.txt",
            "Unread",
            "Old.txt",
            "Empty2",
            "Empty10"
        ]
    );
    assert_eq!(
        entries[1].last_read, 200,
        "A folder uses its latest descendant reading time"
    );
    assert_eq!(entries[5].child_book_count, 1);
    assert_eq!(
        entries[7].child_book_count, 0,
        "Nested empty folders are still empty, and remain visible"
    );
}

#[test]
fn invalid_scan_cannot_wipe_the_last_good_tree() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    core.scan_library_shelf("builtin".into(), vec![item("保留.txt", false)])
        .unwrap();
    assert!(
        core.scan_library_shelf("builtin".into(), vec![item("../坏.txt", false)])
            .is_err()
    );
    core.set_library_shelf_error("builtin".into(), Some("offline".into()))
        .unwrap();
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .library_entries(None, None, LibrarySort::Name)
            .unwrap()
            .len(),
        1
    );
    assert!(library_child_path("..".into(), "逃逸.txt".into()).is_err());
    assert!(library_child_path("".into(), "../逃逸.txt".into()).is_err());
}

#[test]
fn cover_previews_are_bounded_recursive_and_follow_current_files() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let mut files = vec![
        item("集%_", true),
        item("集%_/子目录", true),
        item("空目录", true),
        item("集%_外/旁边.txt", false),
    ];
    for index in 1..=6 {
        let mut file = item(&format!("集%_/子目录/小说{index}.txt"), false);
        file.modified = index;
        file.needs_download = true;
        files.push(file);
    }
    core.scan_library_shelf("builtin".into(), files).unwrap();
    core.scan_library_shelf("external".into(), vec![item("集%_/其他书架.txt", false)])
        .unwrap();
    let preview = || {
        core.query_snapshot("{}".into())
            .unwrap()
            .library_entries(
                Some("builtin".into()),
                Some("".into()),
                LibrarySort::Reading,
            )
            .unwrap()
    };
    let folders = preview();
    let folder = folders.iter().find(|e| e.name == "集%_").unwrap();
    assert_eq!(folder.child_book_count, 6);
    assert_eq!(
        folder
            .cover_previews
            .iter()
            .map(|p| p.name.as_str())
            .collect::<Vec<_>>(),
        ["小说6.txt", "小说5.txt", "小说4.txt", "小说3.txt"]
    );
    assert!(
        folders
            .iter()
            .find(|e| e.name == "空目录")
            .unwrap()
            .cover_previews
            .is_empty()
    );
    // A real move immediately changes the derived preview; there is no separate
    // cover cache or virtual membership to repair.
    core.relocate_library_entry(
        folder.cover_previews[0].file_id.clone(),
        "external".into(),
        "移出.txt".into(),
    )
    .unwrap();
    let folders = preview();
    let updated = folders.iter().find(|e| e.name == "集%_").unwrap();
    assert_eq!(updated.child_book_count, 5);
    assert_eq!(updated.cover_previews[0].name, "小说5.txt");
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .all_library_books("builtin".into())
            .unwrap()
            .len(),
        6
    );
    assert!(
        rusqlite::Connection::open(dir.path().join("data/reader.sqlite3"))
            .unwrap()
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get::<_, i64>(0))
            .unwrap()
            == 0,
        "Previews do not ingest cloud files"
    );
}

#[test]
fn search_ranks_titles_before_authors_and_filters_only_books() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    core.scan_library_shelf(
        "builtin".into(),
        vec![
            item("星河", true),
            item("星河/星河书简.txt", false),
            item("书简星河.txt", false),
            item("雨巷.txt", false),
            item("txt说明.txt", false),
        ],
    )
    .unwrap();
    core.scan_library_shelf("external".into(), vec![item("星河外传.txt", false)])
        .unwrap();
    let files = core
        .query_snapshot("{}".into())
        .unwrap()
        .all_library_books("builtin".into())
        .unwrap();
    let id = |name: &str| files.iter().find(|e| e.name == name).unwrap().id.clone();
    let book = core.create_sample_book().unwrap();
    core.link_library_file(id("雨巷.txt"), book.id.clone())
        .unwrap();
    let query = core
        .query_snapshot(
            serde_json::json!({"positions":[],"metadata":[{"sha":book.content_sha256,"author":"林澄","synopsis":"","tags":["武侠"],"cover":null,"status":"Unread"}]})
                .to_string(),
        )
        .unwrap();
    let names = |shelf: Option<&str>, text: &str, author: Option<&str>, tag: Option<&str>| {
        query
            .search_library(
                shelf.map(Into::into),
                text.into(),
                author.map(Into::into),
                tag.map(Into::into),
            )
            .unwrap()
            .into_iter()
            .map(|e| e.name)
            .collect::<Vec<_>>()
    };
    assert_eq!(
        names(None, " 星河 ", None, None),
        ["星河书简.txt", "星河外传.txt", "书简星河.txt", "星河"],
        "Books first; prefix before contains; folders last"
    );
    assert_eq!(
        names(Some("builtin"), "星河", None, None),
        ["星河书简.txt", "书简星河.txt", "星河"]
    );
    assert_eq!(
        names(None, "txt", None, None),
        ["txt说明.txt"],
        "The extension is not searchable"
    );
    assert_eq!(
        names(None, "林", None, None),
        ["雨巷.txt"],
        "Author text matches after titles"
    );
    assert_eq!(names(None, "", Some("林澄"), None), ["雨巷.txt"]);
    assert_eq!(names(None, "", None, Some("武侠")), ["雨巷.txt"]);
    assert!(
        names(None, "星", Some("林澄"), None).is_empty(),
        "Filters exclude folders and other books"
    );
    assert!(names(None, "  ", None, None).is_empty());
}

#[test]
fn combined_search_scope_keeps_indexed_unopened_copies_and_excludes_other_shelves() {
    let dir = TempDir::new().unwrap();
    let core = core(&dir);
    let text = "第一章 星灯\n仅用于组合搜索的合成正文。\n";
    let source = dir.path().join("source.txt");
    std::fs::write(&source, text).unwrap();
    let identity = moonread_core::SourceIdentityProbe::new()
        .identify(source.to_string_lossy().into(), "auto".into())
        .unwrap();
    let entry = |path: &str, directory: bool| ScannedLibraryItem {
        relative_path: path.into(),
        directory,
        size: if directory { 0 } else { text.len() as u64 },
        modified: 1,
        needs_download: false,
    };
    core.scan_library_shelf(
        "builtin".into(),
        vec![
            entry("星灯", true),
            entry("星灯.txt", false),
            entry("星灯/星灯副本.txt", false),
        ],
    )
    .unwrap();
    core.scan_library_shelf("external".into(), vec![entry("星灯.txt", false)])
        .unwrap();
    for file in core.source_file_snapshots(None).unwrap() {
        assert!(file.book_id.is_none());
        assert!(
            core.publish_source_identity(file, identity.clone())
                .unwrap()
        );
    }
    let query = core.query_snapshot(serde_json::json!({"metadata":[{
        "sha":identity.content_sha256,"author":"林澄","synopsis":"","tags":["旅途"],"cover":null,"status":"Unread"
    }]}).to_string()).unwrap();
    let books = query
        .search_library(
            Some("builtin".into()),
            "星灯".into(),
            Some("林澄".into()),
            Some("旅途".into()),
        )
        .unwrap();
    assert_eq!(books.len(), 2);
    assert!(
        books
            .iter()
            .all(|b| !b.directory && b.shelf_id == "builtin" && b.book_id.is_none())
    );
    assert_eq!(
        books
            .iter()
            .map(|b| &b.id)
            .collect::<std::collections::HashSet<_>>()
            .len(),
        2
    );
    assert!(
        query
            .search_library(
                Some("builtin".into()),
                "星灯".into(),
                Some("其他作者".into()),
                Some("旅途".into())
            )
            .unwrap()
            .is_empty()
    );
}
