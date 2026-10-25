use super::*;

#[test]
fn partial_scan_preserves_only_inaccessible_paths_and_their_associations() {
    let dir = tempfile::tempdir().unwrap();
    let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
    core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
        .unwrap();
    let file = |path: &str| ScannedLibraryItem {
        relative_path: path.into(),
        directory: false,
        size: 10,
        modified: 1,
        needs_download: false,
    };
    core.scan_library_shelf(
        "s".into(),
        vec![
            file("bad/keep.txt"),
            file("bad-sibling/gone.txt"),
            file("deleted.txt"),
        ],
    )
    .unwrap();
    let before = core
        .source_files("s".into())
        .unwrap()
        .into_iter()
        .find(|f| f.relative_path == "bad/keep.txt")
        .unwrap();
    core.scan_library_shelf_partial("s".into(), vec![file("new.txt")], vec!["bad".into()])
        .unwrap();
    let after = core.source_files("s".into()).unwrap();
    assert_eq!(after.len(), 2);
    assert!(
        after
            .iter()
            .any(|f| f.id == before.id && f.relative_path == "bad/keep.txt")
    );
    assert!(after.iter().any(|f| f.relative_path == "new.txt"));
    core.scan_library_shelf("s".into(), vec![]).unwrap();
    assert!(core.source_files("s".into()).unwrap().is_empty());
}

#[test]
fn search_candidates_leave_unmatched_folder_covers_unqueried() {
    let dir = tempfile::tempdir().unwrap();
    let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
    core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
        .unwrap();
    core.lock().unwrap().execute_batch(
            "INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
             INSERT INTO library_files VALUES('book','s','folder/book.txt','folder','book.txt',0,100,1,0,NULL,'auto');"
        ).unwrap();
    let query = core.query_snapshot("{}".into()).unwrap();
    let before = FOLDER_COVER_QUERIES.with(|count| count.get());
    let candidates = query
        .library_search_candidates(
            crate::CatalogueScope {
                shelf_id: Some("s".into()),
                parent_path: None,
                recursive: true,
            },
            false,
        )
        .unwrap();
    assert!(candidates.iter().any(|c| c.entry.directory));
    assert!(candidates.iter().all(|c| c.entry.cover_previews.is_empty()));
    // Matching happens in Swift; an unmatched search stops here without any cover SQL.
    assert_eq!(FOLDER_COVER_QUERIES.with(|count| count.get()), before);
    let covers = query
        .library_folder_cover_previews("s".into(), "folder".into())
        .unwrap();
    assert_eq!(covers[0].file_id, "book");
    assert_eq!(FOLDER_COVER_QUERIES.with(|count| count.get()), before + 1);
}

#[test]
fn tag_groups_repeat_multitagged_files_and_separate_identity_states_within_shelf() {
    let dir = tempfile::tempdir().unwrap();
    let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
    for shelf in ["s", "other"] {
        core.save_library_shelf(shelf.into(), shelf.into(), vec![], "local".into(), false)
            .unwrap();
    }
    {
        let db = core.lock().unwrap();
        db.execute_batch("INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('tagged','s','folder/tagged.txt','folder','tagged.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('untagged','s','untagged.txt','','untagged.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('unknown','s','unknown.txt','','unknown.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('stale','s','stale.txt','','stale.txt',0,101,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('outside','other','outside.txt','','outside.txt',0,100,1,0,NULL,'auto');
                INSERT INTO source_identities VALUES('raw','auto','tagged-sha','UTF-8',100,80);
                INSERT INTO source_identities VALUES('raw-untagged','auto','untagged-sha','UTF-8',100,80);
                INSERT INTO library_identities VALUES('tagged','raw','auto',100,1);
                INSERT INTO library_identities VALUES('untagged','raw-untagged','auto',100,1);
                INSERT INTO library_identities VALUES('stale','raw','auto',100,1);
                INSERT INTO library_identities VALUES('outside','raw','auto',100,1);").unwrap();
    }
    let query = core.query_snapshot(serde_json::json!({"metadata": [{
            "sha": "tagged-sha", "author": "", "synopsis": "", "tags": ["B", "A"], "cover": null, "status": "Unread"
        }]}).to_string()).unwrap();
    let catalogue = query.all_library_tag_groups("s".into()).unwrap();
    assert_eq!(catalogue.book_count, 4);
    assert_eq!(
        catalogue.groups.iter().map(|g| g.kind).collect::<Vec<_>>(),
        [
            LibraryTagGroupKind::Tag,
            LibraryTagGroupKind::Tag,
            LibraryTagGroupKind::Untagged,
            LibraryTagGroupKind::Unindexed
        ]
    );
    assert_eq!(
        catalogue
            .groups
            .iter()
            .map(|g| g.tag.as_str())
            .collect::<Vec<_>>(),
        ["A", "B", "", ""]
    );
    let ids = |i: usize| {
        catalogue.groups[i]
            .entries
            .iter()
            .map(|e| e.id.as_str())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(0), ["tagged"]);
    assert_eq!(ids(1), ["tagged"]);
    assert_eq!(ids(2), ["untagged"]);
    assert_eq!(ids(3), ["stale", "unknown"]);
    assert!(
        catalogue
            .groups
            .iter()
            .flat_map(|g| &g.entries)
            .all(|e| e.shelf_id == "s" && !e.directory)
    );
}

#[test]
fn folder_last_read_includes_index_only_child_with_synced_position() {
    let dir = tempfile::tempdir().unwrap();
    let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
    core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
        .unwrap();
    let sha = "a".repeat(64);
    {
        let db = core.lock().unwrap();
        db.execute_batch("INSERT INTO library_files VALUES('folder','s','folder','','folder',1,0,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('indexed','s','folder/indexed.txt','folder','indexed.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_identities VALUES('indexed','raw','auto',100,1);
                INSERT INTO books(id,title,content_sha256,encoding,byte_count) VALUES('cached','Cached','cached-sha','UTF-8',100);
                INSERT INTO library_files VALUES('cached-file','s','folder/cached.txt','folder','cached.txt',0,100,999,0,'cached','auto');").unwrap();
        db.execute(
            "INSERT INTO source_identities VALUES('raw','auto',?1,'UTF-8',100,80)",
            [&sha],
        )
        .unwrap();
    }
    let query = core
        .query_snapshot(
            serde_json::json!({"positions": [{
            "content_key": sha, "offset": 50, "updated": 123456, "visible": true, "preferred": null
        },{"content_key":"cached-sha","offset":10,"updated":10,"visible":true,"preferred":null}]})
            .to_string(),
        )
        .unwrap();
    let folder = query
        .library_entries(Some("s".into()), Some("".into()), LibrarySort::Reading)
        .unwrap()
        .remove(0);
    assert!(folder.directory);
    assert_eq!(folder.last_read, 123456);
    let child = query.library_entry("indexed".into()).unwrap();
    assert!(child.book_id.is_none());
    assert_eq!(child.last_read, folder.last_read);
    // Two paths to one SHA both inherit it; replacing the input snapshot can
    // lower a folder's time (no monotonically increasing UI-side max).
    core.lock().unwrap().execute_batch("INSERT INTO library_files VALUES('second-folder','s','second','','second',1,0,1,0,NULL,'auto'); INSERT INTO library_files VALUES('second-copy','s','second/copy.txt','second','copy.txt',0,100,1,0,NULL,'auto'); INSERT INTO library_identities VALUES('second-copy','raw','auto',100,1);").unwrap();
    let lower=core.query_snapshot(serde_json::json!({"positions":[{"content_key":sha,"offset":20,"updated":5,"visible":true,"preferred":null}]}).to_string()).unwrap();
    let folders = lower
        .library_entries(Some("s".into()), Some("".into()), LibrarySort::Reading)
        .unwrap();
    assert!(folders.iter().all(|f| f.last_read == 5));

    assert_eq!(
        folder
            .cover_previews
            .iter()
            .map(|p| p.file_id.as_str())
            .collect::<Vec<_>>(),
        ["indexed", "cached-file"],
        "preview order must follow the same projected reading times"
    );
}

#[test]
fn recent_entries_include_index_only_and_null_visibility() {
    let dir = tempfile::tempdir().unwrap();
    let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
    core.save_library_shelf("s".into(), "Shelf".into(), vec![], "local".into(), false)
        .unwrap();
    {
        let db = core.lock().unwrap();
        db.execute_batch("INSERT INTO books(id,title,content_sha256,encoding,byte_count) VALUES('prepared','Prepared','prepared-sha','UTF-8',100);
                INSERT INTO library_files VALUES('prepared-file','s','prepared.txt','','prepared.txt',0,100,1,0,'prepared','auto');
                INSERT INTO library_files VALUES('indexed-file','s','indexed.txt','','indexed.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('indexed-copy','s','copy.txt','','copy.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('hidden-file','s','hidden.txt','','hidden.txt',0,100,1,0,NULL,'auto');
                INSERT INTO source_identities VALUES('raw-index','auto','indexed-sha','UTF-8',100,80);
                INSERT INTO source_identities VALUES('raw-hidden','auto','hidden-sha','UTF-8',100,80);
                INSERT INTO library_identities VALUES('indexed-file','raw-index','auto',100,1);
                INSERT INTO library_identities VALUES('indexed-copy','raw-index','auto',100,1);
                INSERT INTO library_identities VALUES('hidden-file','raw-hidden','auto',100,1);").unwrap();
    }
    core.read_lock()
        .unwrap()
        .execute_batch(
            "INSERT INTO user_positions VALUES('prepared-sha',25,10,NULL,NULL);
            INSERT INTO user_positions VALUES('indexed-sha',50,20,NULL,'indexed-file');
            INSERT INTO user_positions VALUES('hidden-sha',50,30,0,NULL);",
        )
        .unwrap();
    let recent = core.recent_library_entries(10).unwrap();
    assert_eq!(
        recent.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
        ["indexed-file", "prepared-file"]
    );
    assert_eq!(recent[0].book_id, None);
    assert_eq!(recent[0].content_sha256.as_deref(), Some("indexed-sha"));
    assert_eq!(recent[0].position_utf8, 50);
}
