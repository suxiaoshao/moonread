use moonread_core::{ReaderCore, ReaderError};
use tempfile::TempDir;
fn setup(text: &str) -> (TempDir, std::sync::Arc<ReaderCore>, String) {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("sample.txt");
    std::fs::write(&path, text).unwrap();
    let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
    let id = core
        .import_book(path.to_string_lossy().into(), "Synthetic".into())
        .unwrap()
        .id;
    (dir, core, id)
}

#[test]
fn chapter_counts_exclude_headings_and_whitespace_across_chunks() {
    let text = format!(
        "序言不计入第一章\n  第1章 起点  \n甲 🌙 A\n　乙。\t\n第2章 长章\n{}\n第3章 空章",
        "文".repeat(10000)
    );
    let (_dir, core, id) = setup(&text);
    let page = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_outline(id.clone())
        .unwrap();
    assert_eq!(
        page.items.iter().map(|c| c.word_count).collect::<Vec<_>>(),
        [5, 10000, 0]
    );
    assert!(page.items.iter().all(|c| c.count_complete));
}

#[test]
fn complete_outline_contains_ten_thousand_chapters_in_order_after_reopen() {
    let text = (1..=81)
        .map(|i| format!("第{i}章 月光\n故事🌙继续。\n"))
        .collect::<String>();
    let (dir, core, id) = setup(&text);
    drop(core);
    let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
    let outline = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_outline(id)
        .unwrap();
    assert!(outline.is_complete);
    assert_eq!(outline.items.len(), 81);
    assert_eq!(outline.items.first().unwrap().start_utf8, 0);
    assert_eq!(outline.items.last().unwrap().title, "第81章 月光");
    assert!(
        outline
            .items
            .windows(2)
            .all(|pair| pair[0].start_utf8 < pair[1].start_utf8)
    );
    assert!(
        outline
            .items
            .iter()
            .all(|item| item.word_count == 6 && item.count_complete)
    );
}

#[test]
fn partial_last_chapter_count_is_not_advertised_as_final_and_survives_promotion() {
    let text = "第1章 已完成\n月光。\n第2章 末章\n故事仍在继续。\n";
    let (dir, core, _) = setup(text);
    let control = core.create_import("Duplicate".into()).unwrap();
    core.stream_import(
        control.clone(),
        dir.path().join("sample.txt").to_string_lossy().into(),
        core.hash_import_source(
            control.clone(),
            dir.path().join("sample.txt").to_string_lossy().into(),
        )
        .unwrap(),
        None,
    )
    .unwrap();
    let pending = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_outline(control.book_id())
        .unwrap();
    assert!(!pending.is_complete);
    assert!(pending.items[0].count_complete);
    assert!(!pending.items[1].count_complete);
    assert_eq!(pending.items[1].word_count, 7);
    core.finish_import(control.clone()).unwrap();
    let completed = core
        .query_snapshot("{}".into())
        .unwrap()
        .chapter_outline(control.book_id())
        .unwrap();
    assert!(completed.is_complete);
    assert!(completed.items[1].count_complete);
    assert_eq!(completed.items[1].word_count, 7);
}

#[test]
fn search_matches_across_storage_chunks_and_limits_regex_and_cancellation() {
    let text = format!("{}Moonread moonread Moonr.ad", "甲".repeat(4095));
    let (_dir, core, id) = setup(&text);
    let start = text.find("Moonread").unwrap() as u64;
    assert_ne!(
        core.find_chunk(id.clone(), start).unwrap(),
        core.find_chunk(id.clone(), start + 7).unwrap()
    );
    for (pattern, regex, sensitive, expected) in [
        ("Moonread", false, true, vec!["Moonread"]),
        (
            "Moonr.ad",
            true,
            false,
            vec!["Moonread", "moonread", "Moonr.ad"],
        ),
    ] {
        let job = core
            .query_snapshot("{}".into())
            .unwrap()
            .start_search(id.clone(), pattern.into(), regex, sensitive, None)
            .unwrap();
        let mut hits = Vec::new();
        loop {
            let batch = job.next_batch().unwrap();
            hits.extend(batch.hits);
            if batch.done {
                break;
            }
        }
        let matches: Vec<_> = hits
            .iter()
            .map(|hit| {
                assert!(text.is_char_boundary(hit.start_utf8 as usize));
                assert!(text.is_char_boundary(hit.end_utf8 as usize));
                &text[hit.start_utf8 as usize..hit.end_utf8 as usize]
            })
            .collect();
        assert_eq!(
            matches, expected,
            "{pattern} regex={regex} sensitive={sensitive}"
        );
    }
    assert!(matches!(
        core.query_snapshot("{}".into()).unwrap().start_search(
            id.clone(),
            "[".into(),
            true,
            false,
            None
        ),
        Err(ReaderError::SearchPattern { .. })
    ));
    let job = core
        .query_snapshot("{}".into())
        .unwrap()
        .start_search(id, "Moonread".into(), false, true, None)
        .unwrap();
    job.cancel();
    assert!(job.next_batch().unwrap().cancelled);
}

#[test]
fn paragraph_range_crosses_chunks_without_truncating_or_splitting_unicode() {
    let text = format!("第一章 长段\n{}\n尾声", "月光🌙".repeat(6000));
    let (_d, core, id) = setup(&text);
    let range = core
        .paragraph_range(id.clone(), "第一章 长段\n月光".len() as u64)
        .unwrap();
    assert_eq!(range.text, "月光🌙".repeat(6000));
    assert_eq!(
        core.text_range(id, range.start_utf8, range.end_utf8)
            .unwrap()
            .text,
        range.text
    );
}

#[test]
fn search_reaches_late_hits_without_global_hit_limit() {
    use moonread_core::SearchRange;
    let text = format!(
        "第1章 前文\n{}第2章 番外\n命中🌙结尾\n",
        "命中\n".repeat(2100)
    );
    let (_dir, core, id) = setup(&text);
    let query = core.query_snapshot("{}".into()).unwrap();
    let info = query.book_info(id.clone()).unwrap();
    let outline = query.chapter_outline(id.clone()).unwrap();
    let all = query
        .start_search(id.clone(), "命中".into(), false, true, None)
        .unwrap();
    let mut total = 0;
    loop {
        let batch = all.next_batch().unwrap();
        assert!(!batch.truncated);
        total += batch.hits.len();
        if batch.done {
            break;
        }
    }
    assert_eq!(total, 2101);
    let start = outline.items[1].start_utf8;
    let job = query
        .start_search(
            id.clone(),
            "命中".into(),
            false,
            true,
            Some(SearchRange {
                start_utf8: start,
                end_utf8: info.byte_count,
            }),
        )
        .unwrap();
    let mut hits = Vec::new();
    loop {
        let batch = job.next_batch().unwrap();
        assert!(!batch.truncated);
        hits.extend(batch.hits);
        if batch.done {
            break;
        }
    }
    assert_eq!(hits.len(), 1);
    assert!(hits[0].start_utf8 >= start);
    assert_eq!(hits[0].chapter.as_deref(), Some("第2章 番外"));
    assert!(
        query
            .start_search(
                id.clone(),
                "命中".into(),
                false,
                true,
                Some(SearchRange {
                    start_utf8: 1,
                    end_utf8: info.byte_count
                })
            )
            .is_err()
    );
    assert!(
        query
            .start_search(
                id,
                "命中".into(),
                false,
                true,
                Some(SearchRange {
                    start_utf8: start,
                    end_utf8: info.byte_count + 1
                })
            )
            .is_err()
    );
}

#[test]
fn text_context_skips_blank_lines_and_preserves_unicode_boundaries() {
    let (_dir, core, id) = setup("第一章 开始\n甲🌙前文\n\n乙目标\n\n丙后文\n丁末尾");
    let size = core
        .query_snapshot("{}".into())
        .unwrap()
        .book_info(id.clone())
        .unwrap()
        .byte_count;
    let text = core.text_range(id.clone(), 0, size).unwrap().text;
    let anchor = text.find("目标").unwrap() as u64;
    let context = core.text_context(id.clone(), anchor, 1, 1).unwrap();
    assert_eq!(context.text.trim(), "甲🌙前文\n\n乙目标\n\n丙后文");
    assert_eq!(
        core.text_range(id.clone(), context.start_utf8, context.end_utf8)
            .unwrap(),
        context
    );
    let first = core.text_context(id.clone(), 0, 20, 0).unwrap();
    assert_eq!(first.start_utf8, 0);
    let last_offset = text.find("丁末尾").unwrap() as u64;
    let last = core.text_context(id.clone(), last_offset, 0, 20).unwrap();
    assert_eq!(last.text.trim(), "丁末尾");
    assert!(core.text_context(id.clone(), anchor + 1, 1, 1).is_err());
    assert!(core.text_context(id, size, 1, 1).is_err());
}

#[test]
fn oversized_lines_keep_literal_matches_and_regex_continues_after_skipped_line() {
    let text = format!(
        "{}月光{}月光\n尾声月光\n",
        "a".repeat(1024 * 1024 - 1),
        "b".repeat(1024 * 1024)
    );
    let (_dir, core, id) = setup(&text);
    let query = core.query_snapshot("{}".into()).unwrap();
    for regex in [false, true] {
        let search = query
            .start_search(id.clone(), "月光".into(), regex, true, None)
            .unwrap();
        let mut hits = Vec::new();
        loop {
            let batch = search.next_batch().unwrap();
            hits.extend(batch.hits);
            if batch.done {
                assert_eq!(batch.truncated, regex);
                break;
            }
        }
        assert_eq!(hits.len(), if regex { 1 } else { 3 });
        for hit in hits {
            assert_eq!(
                &text[hit.start_utf8 as usize..hit.end_utf8 as usize],
                "月光"
            );
        }
    }
}
