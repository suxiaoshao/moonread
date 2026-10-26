use moonread_core::*;
use serde_json::json;
use tempfile::TempDir;

fn fixture() -> (TempDir, std::sync::Arc<ReaderCore>, ImportText) {
    let root = TempDir::new().unwrap();
    let core = ReaderCore::new(root.path().join("db").to_string_lossy().into()).unwrap();
    let path = root.path().join("text.txt");
    std::fs::write(
        &path,
        "第一章 月\n\n甲乙丙丁戊己庚辛壬癸\n第二章 星\n\n再次阅读\n",
    )
    .unwrap();
    let book = core
        .import_book(path.to_string_lossy().into(), "Test".into())
        .unwrap();
    (root, core, book)
}
fn fact(
    book: &ImportText,
    id: &str,
    session: &str,
    visit: &str,
    started: i64,
    duration: i64,
    range: (u64, u64),
) -> serde_json::Value {
    json!({"content_key":book.content_sha256,"title":book.title,"device":session,"slice":{
        "id":id,"session_id":session,"visit_id":visit,"book_id":book.id,"started_ms":started,"ended_ms":started+duration,
        "local_day":20000,"utc_offset_seconds":28800,"preview":false,
        "exposures":[{"start_utf8":range.0,"end_utf8":range.1,"duration_ms":duration}]}})
}
#[test]
fn temporary_user_inputs_never_persist_in_the_text_database() {
    let (root, core, book) = fixture();
    let query = core.query_snapshot(json!({"positions":[{"content_key":book.content_sha256,"offset":24,"updated":99,"visible":true,"preferred":null}],"metadata":[{"sha":book.content_sha256,"author":"作者","synopsis":"介绍","tags":["月"],"cover":null,"status":"Reading"}]}).to_string()).unwrap();
    assert_eq!(query.book_info(book.id.clone()).unwrap().position_utf8, 24);
    assert_eq!(
        query
            .book_details(Some(book.id.clone()), None)
            .unwrap()
            .metadata
            .author,
        "作者"
    );
    drop(core);
    let reopened = ReaderCore::new(root.path().join("db").to_string_lossy().into()).unwrap();
    assert_eq!(
        reopened
            .query_snapshot("{}".into())
            .unwrap()
            .book_info(book.id.clone())
            .unwrap()
            .position_utf8,
        0
    );
    assert_eq!(
        reopened
            .query_snapshot("{}".into())
            .unwrap()
            .book_details(Some(book.id), None)
            .unwrap()
            .metadata
            .author,
        ""
    );
    let db = rusqlite::Connection::open(root.path().join("db/reader.sqlite3")).unwrap();
    for name in [
        "reading_activity",
        "reading_marks",
        "book_metadata",
        "appearance",
        "settings",
        "chapter_overrides",
        "sync_meta",
    ] {
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM sqlite_master WHERE name=?1",
                [name],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
    }
}
#[test]
fn overlapping_devices_accumulate_and_fact_retry_does_not_double_count() {
    let (_root, core, book) = fixture();
    let a = fact(&book, "a", "device-a", "visit-a", 1_000, 15_000, (20, 50));
    let b = fact(&book, "b", "device-b", "visit-b", 1_000, 15_000, (20, 50));
    let query = core
        .query_snapshot(json!({"facts":[a.clone(),b,a]}).to_string())
        .unwrap();
    let overview = query.statistics_overview(20000, 20000, None).unwrap();
    assert_eq!(overview.books[0].duration_ms, 30_000);
    assert_eq!(overview.days[0].duration_ms, 30_000);
    assert_eq!(
        query.reading_activities(20000, 20000, None).unwrap().len(),
        2
    );
    let query = core.query_snapshot("{}".into()).unwrap();
    assert!(
        query
            .statistics_overview(20000, 20000, None)
            .unwrap()
            .books
            .is_empty()
    );
}
#[test]
fn coverage_spans_checkpoints_but_does_not_add_disjoint_visits() {
    let (_root, core, book) = fixture();
    let a = fact(&book, "a", "s", "v", 0, 1500, (19, 49));
    let b = fact(&book, "b", "s", "v", 1500, 1500, (19, 49));
    let query = core
        .query_snapshot(json!({"facts":[a.clone(),b]}).to_string())
        .unwrap();
    assert!(
        query.chapter_outline(book.id.clone()).unwrap().items[0]
            .covered_characters
            .unwrap()
            > 0
    );
    let c = fact(&book, "c", "s", "other", 1500, 1500, (19, 49));
    let query = core
        .query_snapshot(json!({"facts":[a,c]}).to_string())
        .unwrap();
    assert_eq!(
        query.chapter_outline(book.id).unwrap().items[0].covered_characters,
        Some(0)
    );
}
#[test]
fn chapter_corrections_are_inputs_and_rebuild_retains_text_integrity() {
    let root = TempDir::new().unwrap();
    let data = root.path().join("db").to_string_lossy().into_owned();
    let path = root.path().join("original.txt");
    let text = "第壹部 星港\n第一話 月光\n原創正文。\n第二話 歸舟\n原創正文。\n尾聲\n燈火未眠。\n";
    std::fs::write(&path, text).unwrap();
    let core = ReaderCore::new(data.clone()).unwrap();
    let book = core
        .import_book(path.to_string_lossy().into(), "星港".into())
        .unwrap();
    let first = text.find("第一話").unwrap() as u64;
    let second = text.find("第二話").unwrap() as u64;
    let ending = text.find("尾聲").unwrap() as u64;
    let imported = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_outline(book.id.clone())
        .unwrap();
    assert_eq!(
        imported
            .items
            .iter()
            .map(|c| (c.title.as_str(), c.level, c.parent_utf8))
            .collect::<Vec<_>>(),
        vec![
            ("第壹部 星港", 0, None),
            ("第一話 月光", 1, Some(0)),
            ("第二話 歸舟", 1, Some(0)),
            ("尾聲", 1, Some(0))
        ]
    );
    drop(core);
    // Represent an already cached book from before these rules existed.
    let db = rusqlite::Connection::open(root.path().join("db/reader.sqlite3")).unwrap();
    db.execute("DELETE FROM import_chapters WHERE book_id=?1", [&book.id])
        .unwrap();
    drop(db);
    let core = ReaderCore::new(data).unwrap();
    let input = json!({"positions":[{"content_key":book.content_sha256,"offset":first,"updated":99,"visible":true,"preferred":null}],
        "corrections":[
            {"content_key":book.content_sha256,"offset":first,"title":"手工分組","level":0,"excluded":false},
            {"content_key":book.content_sha256,"offset":second,"title":"不顯示","level":1,"excluded":true},
            {"content_key":book.content_sha256,"offset":ending,"title":"手工結語","level":1,"excluded":false}
        ]}).to_string();
    let before = core.query_snapshot(input.clone()).unwrap();
    assert_eq!(
        before.chapter_outline(book.id.clone()).unwrap().items.len(),
        2
    );
    assert!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_outline(book.id.clone())
            .unwrap()
            .items
            .is_empty()
    );
    let job = core.rebuild_chapters(book.id.clone()).unwrap();
    while !job.next_batch().unwrap().done {}
    // Preparing a preview alone must not replace the old index.
    assert_eq!(job.preview(0, 80).unwrap().len(), 4);
    assert!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_outline(book.id.clone())
            .unwrap()
            .items
            .is_empty()
    );
    job.apply().unwrap();
    let after = core.query_snapshot(input).unwrap();
    let outline = after.chapter_outline(book.id.clone()).unwrap();
    assert_eq!(
        outline
            .items
            .iter()
            .map(|c| (c.title.as_str(), c.level))
            .collect::<Vec<_>>(),
        vec![("第壹部 星港", 0), ("手工分組", 0), ("手工結語", 1)]
    );
    assert_eq!(
        after.book_info(book.id.clone()).unwrap().position_utf8,
        first
    );
    assert_eq!(
        core.import_status(book.id.clone())
            .unwrap()
            .text
            .content_sha256,
        book.content_sha256
    );
    let rebuilt: String = (0..book.chunk_count)
        .map(|i| core.read_chunk(book.id.clone(), i).unwrap().text)
        .collect();
    assert_eq!(rebuilt, text);
    assert_eq!(std::fs::read_to_string(path).unwrap(), text);
}

#[test]
fn settings_codec_preserves_device_preferences_and_validates_ranges() {
    let mut value = default_reader_settings();
    let controls = reader_typography_controls();
    assert_eq!(value.font_size, controls.font_size.default_value);
    assert_eq!(value.line_spacing, controls.line_spacing.default_value);
    assert_eq!(
        value.paragraph_spacing,
        controls.paragraph_spacing.default_value
    );
    value.keep_awake = true;
    value.font = ReaderFont::Serif;
    assert_eq!(
        decode_reader_settings(encode_reader_settings(value.clone()).unwrap()).unwrap(),
        value
    );
    value.font_size = controls.font_size.maximum;
    assert!(decode_reader_settings(encode_reader_settings(value.clone()).unwrap()).is_ok());
    value.font_size += controls.font_size.step;
    assert!(decode_reader_settings(encode_reader_settings(value).unwrap()).is_err());
}

#[test]
fn effective_directory_is_explicit_for_navigation_search_and_isolated_queries() {
    let (root, core, book) = fixture();
    let text = std::fs::read_to_string(root.path().join("text.txt")).unwrap();
    let added = text.find('甲').unwrap() as u64;
    let second = text.find("第二章").unwrap() as u64;
    let corrected = core.query_snapshot(json!({"corrections":[
        {"content_key":book.content_sha256,"offset":0,"title":"重命名","level":1,"excluded":false},
        {"content_key":book.content_sha256,"offset":added,"title":"新增目录","level":1,"excluded":false},
        {"content_key":book.content_sha256,"offset":second,"title":"第二章 星","level":1,"excluded":true}
    ]}).to_string()).unwrap();
    assert_eq!(
        corrected
            .chapter_at(book.id.clone(), 0)
            .unwrap()
            .unwrap()
            .title,
        "重命名"
    );
    assert_eq!(
        corrected
            .adjacent_chapter(book.id.clone(), 0, true)
            .unwrap()
            .unwrap()
            .start_utf8,
        added
    );
    assert_eq!(
        corrected
            .chapter_at(book.id.clone(), second + 1)
            .unwrap()
            .unwrap()
            .title,
        "新增目录"
    );
    assert_eq!(
        corrected
            .reading_location(book.id.clone(), 100.0)
            .unwrap()
            .chapter
            .unwrap()
            .title,
        "新增目录"
    );
    let job = corrected
        .start_search(book.id.clone(), "甲|阅读".into(), true, true, None)
        .unwrap();
    let hits = job.next_batch().unwrap().hits;
    assert_eq!(hits.len(), 2);
    assert!(
        hits.iter()
            .all(|hit| hit.chapter.as_deref() == Some("新增目录"))
    );
    let restored = core.query_snapshot("{}".into()).unwrap();
    assert_eq!(
        restored
            .chapter_at(book.id.clone(), 0)
            .unwrap()
            .unwrap()
            .title,
        "第一章 月"
    );
    assert_eq!(
        restored
            .start_search(book.id.clone(), "阅读".into(), false, true, None)
            .unwrap()
            .next_batch()
            .unwrap()
            .hits[0]
            .chapter
            .as_deref(),
        Some("第二章 星")
    );
    // No caller can accidentally seed a subsequent raw or corrected query.
    assert_eq!(
        core.query_snapshot("{}".into())
            .unwrap()
            .chapter_at(book.id.clone(), 0)
            .unwrap()
            .unwrap()
            .title,
        "第一章 月"
    );
    assert_eq!(
        corrected.chapter_at(book.id, 0).unwrap().unwrap().title,
        "重命名"
    );
}

#[test]
fn search_batches_keep_the_directory_snapshot_with_which_the_job_started() {
    let root = TempDir::new().unwrap();
    let core = ReaderCore::new(root.path().join("db").to_string_lossy().into()).unwrap();
    let file = root.path().join("book.txt");
    std::fs::write(&file, format!("第一章 原名\n{}", "命中句子\n".repeat(120))).unwrap();
    let book = core
        .import_book(file.to_string_lossy().into(), "Long search".into())
        .unwrap();
    let query = |name| {
        core.query_snapshot(json!({"corrections":[{"content_key":book.content_sha256,"offset":0,"title":name,"level":1,"excluded":false}]}).to_string()).unwrap()
    };
    let old = query("旧目录");
    let job = old
        .start_search(book.id.clone(), "命中".into(), false, true, None)
        .unwrap();
    let first = job.next_batch().unwrap();
    assert!(!first.done);
    assert!(
        first
            .hits
            .iter()
            .all(|hit| hit.chapter.as_deref() == Some("旧目录"))
    );
    let new = query("新目录");
    assert_eq!(
        new.start_search(book.id, "命中".into(), false, true, None)
            .unwrap()
            .next_batch()
            .unwrap()
            .hits[0]
            .chapter
            .as_deref(),
        Some("新目录")
    );
    let later = job.next_batch().unwrap();
    assert!(!later.hits.is_empty());
    assert!(
        later
            .hits
            .iter()
            .all(|hit| hit.chapter.as_deref() == Some("旧目录"))
    );
}

#[test]
fn filtered_fact_snapshots_update_overview_book_and_days_without_duplicate_ids() {
    let (root, core, first) = fixture();
    let path = root.path().join("second.txt");
    std::fs::write(&path, "第一章 第二本\n保留另一部书的阅读记录。\n").unwrap();
    let second = core
        .import_book(path.to_string_lossy().into(), "Second".into())
        .unwrap();
    let a = fact(&first, "a", "device", "visit-a", 1000, 1000, (0, 12));
    let mut b = fact(&first, "b", "device", "visit-b", 3000, 2000, (0, 12));
    b["slice"]["local_day"] = json!(20001);
    let mut c = fact(&second, "c", "device", "visit-c", 6000, 3000, (0, 12));
    c["slice"]["local_day"] = json!(20001);
    for (facts, total, first_total, days) in [
        (
            vec![a.clone(), b.clone(), c.clone(), a.clone()],
            6000,
            3000,
            2,
        ),
        (vec![b.clone(), c.clone()], 5000, 2000, 1),
        (vec![a.clone(), c.clone(), c.clone()], 4000, 1000, 2),
    ] {
        let query = core
            .query_snapshot(json!({"facts": facts}).to_string())
            .unwrap();
        let overview = query.statistics_overview(20000, 20001, None).unwrap();
        assert_eq!(overview.total_duration_ms, total);
        assert_eq!(
            overview.books.iter().map(|b| b.duration_ms).sum::<u64>(),
            total
        );
        assert_eq!(
            overview.days.iter().map(|d| d.duration_ms).sum::<u64>(),
            total
        );
        assert_eq!(overview.days.len(), days);
        let book = query
            .statistics_overview(20000, 20001, Some(first.content_sha256.clone()))
            .unwrap();
        assert_eq!(book.books[0].duration_ms, first_total);
        assert_eq!(
            query
                .reading_activities(20000, 20001, Some(second.content_sha256.clone()))
                .unwrap()
                .len(),
            1
        );
    }
}
