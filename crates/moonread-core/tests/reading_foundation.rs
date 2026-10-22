use moonread_core::*;
use tempfile::TempDir;

fn fixture(text: &str) -> (TempDir, std::sync::Arc<ReaderCore>, ImportText) {
    let dir = TempDir::new().unwrap();
    let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
    let path = dir.path().join("synthetic.txt");
    std::fs::write(&path, text).unwrap();
    let book = core
        .import_book(path.to_string_lossy().into(), "Synthetic".into())
        .unwrap();
    (dir, core, book)
}

#[test]
fn display_selection_range_matches_retained_pages_and_preserves_lf() {
    let raw = format!("\n甲🌙。\n{}乙段。\n\n末段。", " \t　\n".repeat(5000));
    let (_dir, core, book) = fixture(&raw);
    let query = core.query_snapshot("{}".into()).unwrap();
    let start = raw.find('甲').unwrap() as u64;
    let end = book.byte_count;
    let value = core
        .display_text_range(book.id.clone(), start, end)
        .unwrap();
    assert_eq!(value.text, "甲🌙。\n乙段。\n末段。");
    assert_eq!((value.start_utf8, value.end_utf8), (start, end));
    let frame = query.reading_frame(book.id.clone(), start).unwrap();
    assert_eq!(
        value.text,
        frame
            .chunks
            .iter()
            .map(|c| c.text.as_str())
            .collect::<String>()
    );
    let one_end = start + "甲🌙。".len() as u64;
    assert_eq!(
        core.display_text_range(book.id.clone(), start, one_end)
            .unwrap()
            .text,
        "甲🌙。"
    );
    assert!(
        core.display_text_range(book.id.clone(), start + 1, one_end)
            .is_err()
    );
    let blank_start = raw.find(" \t").unwrap() as u64;
    let blank_end = raw.find("乙段").unwrap() as u64;
    assert_eq!(
        core.display_text_range(book.id, blank_start, blank_end)
            .unwrap()
            .text,
        ""
    );
}

#[test]
fn retained_whitespace_is_an_exact_anchor_and_bidirectional_frontier() {
    let raw = format!("甲{}乙。\n\n丙。", " \t　".repeat(60000));
    let (_dir, core, book) = fixture(&raw);
    let query = core.query_snapshot("{}".into()).unwrap();
    let anchor = raw.char_indices().find(|(n, _)| *n > 150000).unwrap().0 as u64;
    let initial = query.reading_frame(book.id.clone(), anchor).unwrap();
    assert_eq!(initial.status, ReadingWindowStatus::Ready);
    assert_eq!(initial.projection_anchor, Some(anchor));
    assert!(!initial.has_non_whitespace_payload);
    assert!(
        initial
            .chunks
            .iter()
            .any(|c| c.start_utf8 <= anchor && anchor < c.end_utf8)
    );
    assert!(initial.chunks.iter().map(|c| c.text.len()).sum::<usize>() <= 65536);
    assert_source_partition(&initial, &raw);
    assert_eq!(initial.snapshot.book.position_utf8, 0);
    let wide = raw
        .char_indices()
        .find(|(n, c)| *n > 150000 && *c == '　')
        .unwrap()
        .0 as u64;
    assert_eq!(
        query
            .reading_frame(book.id.clone(), wide + 1)
            .unwrap()
            .projection_anchor,
        Some(wide)
    );
    assert_eq!(
        query
            .reading_frame_extension(book.id.clone(), wide + 1, ReadingDirection::Forward, None)
            .unwrap()
            .projection_anchor,
        Some(wide + 3)
    );
    assert_eq!(
        query
            .reading_frame_extension(book.id.clone(), wide + 2, ReadingDirection::Backward, None)
            .unwrap()
            .projection_anchor,
        Some(wide)
    );
    for direction in [ReadingDirection::Forward, ReadingDirection::Backward] {
        let mut window = query.reading_frame(book.id.clone(), anchor).unwrap();
        let mut seen = std::collections::HashSet::new();
        for _ in 0..50 {
            let Some(cursor) = (if direction == ReadingDirection::Forward {
                window.next_cursor
            } else {
                window.previous_cursor
            }) else {
                break;
            };
            assert!(raw.is_char_boundary(cursor as usize));
            assert!(
                seen.insert(cursor),
                "Retained spaces must not cause a repeat/defer loop"
            );
            let keep_at = if direction == ReadingDirection::Forward {
                window
                    .chunks
                    .last()
                    .unwrap()
                    .text
                    .char_indices()
                    .last()
                    .map(|(n, _)| window.chunks.last().unwrap().start_utf8 + n as u64)
                    .unwrap()
            } else {
                window.chunks.first().unwrap().start_utf8
            };
            let keep_end =
                keep_at + raw[keep_at as usize..].chars().next().unwrap().len_utf8() as u64;
            window = query
                .reading_frame_extension(
                    book.id.clone(),
                    cursor,
                    direction,
                    Some(SourceSpan {
                        start_utf8: keep_at,
                        end_utf8: keep_end,
                    }),
                )
                .unwrap();
            assert_eq!(window.status, ReadingWindowStatus::Ready);
            assert!(
                window
                    .chunks
                    .iter()
                    .any(|c| c.start_utf8 <= keep_at && keep_at < c.end_utf8)
            );
            assert_source_partition(&window, &raw);
        }
        if direction == ReadingDirection::Forward {
            assert!(window.chunks.iter().any(|c| c.text.contains('乙')));
            assert!(window.next_cursor.is_none());
        } else {
            assert!(window.chunks.iter().any(|c| c.text.contains('甲')));
            assert!(window.previous_cursor.is_none());
        }
    }
}

#[test]
fn many_tiny_visible_islands_share_a_bounded_payload_across_huge_gaps() {
    let gap = " \t　\n".repeat(8000);
    let text = (0..2)
        .map(|n| format!("岛{n}。\n{gap}"))
        .collect::<String>();
    let (_dir, core, book) = fixture(&text);
    let query = core.query_snapshot("{}".into()).unwrap();
    let located = query.reading_frame(book.id.clone(), 0).unwrap();
    let expected = (0..2).map(|n| format!("岛{n}。\n")).collect::<String>();
    assert_eq!(
        located
            .chunks
            .iter()
            .map(|c| c.text.as_str())
            .collect::<String>(),
        expected
    );
    assert_source_partition(&located, &text);
    let keep = Some(SourceSpan {
        start_utf8: 0,
        end_utf8: text.rfind("岛1").unwrap() as u64 + "岛1。".len() as u64,
    });
    for (cursor, direction) in [
        (0, ReadingDirection::Backward),
        (text.rfind("岛1").unwrap() as u64, ReadingDirection::Forward),
    ] {
        let frame = query
            .reading_frame_extension(book.id.clone(), cursor, direction, keep.clone())
            .unwrap();
        assert_ne!(frame.status, ReadingWindowStatus::Deferred);
        assert_eq!(
            frame
                .chunks
                .iter()
                .map(|c| c.text.as_str())
                .collect::<String>(),
            expected
        );
        assert_source_partition(&frame, &text);
        assert!(
            frame.chunks.iter().map(|c| c.text.len()).sum::<usize>() <= 64 * 1024,
            "sparse payload must stay bounded"
        );
        assert_eq!(
            frame.snapshot.book.position_utf8, 0,
            "window lookup must not save reading progress"
        );
    }
}

#[test]
fn history_tracks_explicit_visits_and_truncates_forward_branch() {
    let mut history = empty_reading_history();
    history = visit_reading_position(history, 0, "原点".into(), 10, "A".into());
    history = visit_reading_position(history, 12, "A".into(), 20, "B".into());
    let a = history.entries[1].id.clone();
    history = select_reading_history(history, a).unwrap();
    history = visit_reading_position(history, 12, "A".into(), 30, "C".into());
    assert_eq!(
        history
            .entries
            .iter()
            .map(|v| v.offset_utf8)
            .collect::<Vec<_>>(),
        vec![0, 12, 30]
    );
    for n in 1..100 {
        history = visit_reading_position(history, n, "".into(), n + 1, "".into());
    }
    assert_eq!(history.entries.len(), 32);
    assert_eq!(history.cursor, 31);
    assert!(select_reading_history(history, "missing".into()).is_err());
}

#[test]
fn paragraph_roles_preserve_unicode_and_long_paragraph_continuations() {
    let text = format!(
        "第一卷 归来\n序章\n正文没有缩进。\n\n　　原有缩进。\n• 列表\n{}\n番外（一）\n完",
        "中文🌙e\u{301}".repeat(6000)
    );
    let (_dir, core, book) = fixture(&text);
    let first = core
        .query_snapshot("{}".into())
        .unwrap()
        .reading_frame(book.id.clone(), 0)
        .unwrap();
    assert_eq!(first.paragraphs[0].kind, ParagraphKind::Volume);
    assert_eq!(first.paragraphs[1].kind, ParagraphKind::Heading);
    assert!(
        first
            .paragraphs
            .iter()
            .all(|p| p.kind != ParagraphKind::Blank)
    );
    assert!(!first.omitted.is_empty());
    assert!(
        first
            .paragraphs
            .iter()
            .any(|p| p.indented && p.kind == ParagraphKind::Body)
    );
    assert!(
        first
            .paragraphs
            .iter()
            .any(|p| p.kind == ParagraphKind::List)
    );
    let middle = core
        .query_snapshot("{}".into())
        .unwrap()
        .reading_frame(book.id.clone(), book.byte_count / 2)
        .unwrap();
    assert!(middle.paragraphs.first().unwrap().continuation);
    for c in middle.chunks {
        assert_eq!(c.text, text[c.start_utf8 as usize..c.end_utf8 as usize]);
    }
    let last = core
        .query_snapshot("{}".into())
        .unwrap()
        .reading_frame(book.id.clone(), book.byte_count)
        .unwrap();
    assert!(
        last.paragraphs
            .iter()
            .any(|p| p.kind == ParagraphKind::Heading)
    );
}

#[test]
fn blank_paragraph_runs_preserve_every_source_byte_and_offset() {
    let text = "第一卷 合成\n\n第1章 空行\n \t　\n正文甲。\n\n\n\n正文乙。\n\u{00a0}\n末段。";
    let (_dir, core, book) = fixture(text);
    let frame = core
        .query_snapshot("{}".into())
        .unwrap()
        .reading_frame(book.id.clone(), 0)
        .unwrap();
    assert_eq!(
        frame
            .chunks
            .iter()
            .map(|c| c.text.as_str())
            .collect::<String>(),
        "第一卷 合成\n第1章 空行\n正文甲。\n正文乙。\n末段。"
    );
    assert!(
        frame
            .paragraphs
            .iter()
            .all(|p| p.kind != ParagraphKind::Blank)
    );
    assert_eq!(frame.omitted.len(), 4);
    assert_source_partition(&frame, text);
    let source: String = (0..book.chunk_count)
        .map(|i| core.read_chunk(book.id.clone(), i).unwrap().text)
        .collect();
    assert_eq!(source, text);
    let cross = format!("甲{}乙\n", " ".repeat(12289));
    let (_root, core, book) = fixture(&cross);
    let frame = core
        .query_snapshot("{}".into())
        .unwrap()
        .reading_frame(book.id, 8000)
        .unwrap();
    assert!(
        frame.omitted.is_empty(),
        "whitespace inside a visible paragraph is not a blank run"
    );
    assert_source_partition(&frame, &cross);
}

/// Run explicitly in release mode. Synthetic input never becomes a repo asset.

#[test]
fn percentage_locations_validate_inputs_and_normalize_unicode_boundaries() {
    // Empty text has no persisted reading identity: import rejects it before location lookup.
    let dir = TempDir::new().unwrap();
    let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
    let empty = dir.path().join("empty.txt");
    std::fs::write(&empty, "").unwrap();
    assert!(matches!(
        core.import_book(empty.to_string_lossy().into(), "Empty".into()),
        Err(ReaderError::EmptyBook)
    ));
    for text in ["甲🌙乙e\u{301}。", "甲"] {
        let (_dir, core, book) = fixture(text);
        let query = core.query_snapshot("{}".into()).unwrap();
        for percent in [0.0, 50.0, 100.0] {
            let location = query.reading_location(book.id.clone(), percent).unwrap();
            assert!(location.offset_utf8 <= text.len() as u64);
            assert!(text.is_char_boundary(location.offset_utf8 as usize));
            let expected = location.offset_utf8 as f64 / text.len().max(1) as f64 * 100.0;
            assert_eq!(location.percentage, expected);
            if percent == 0.0 {
                assert_eq!(location.offset_utf8, 0);
            }
            if percent == 100.0 {
                assert_eq!(location.offset_utf8, text.len() as u64);
            }
        }
        let inside = "甲".len() as u64 + 1;
        assert!(
            text.is_char_boundary(
                core.normalized_position(book.id.clone(), inside).unwrap() as usize
            )
        );
        assert_eq!(
            core.normalized_position(book.id.clone(), u64::MAX).unwrap(),
            book.byte_count
        );
        assert_eq!(
            query.book_info(book.id.clone()).unwrap().position_utf8,
            0,
            "location lookup is read-only"
        );
        for percent in [-1.0, 100.01, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(matches!(
                query.reading_location(book.id.clone(), percent),
                Err(ReaderError::InvalidRange)
            ));
        }
    }
}

fn assert_source_partition(frame: &ReadingFrame, source: &str) {
    let mut ranges: Vec<(u64, u64)> = frame
        .chunks
        .iter()
        .map(|c| {
            assert_eq!(c.text, source[c.start_utf8 as usize..c.end_utf8 as usize]);
            (c.start_utf8, c.end_utf8)
        })
        .collect();
    ranges.extend(
        frame
            .omitted
            .iter()
            .map(|g| {
                assert!(
                    source[g.start_utf8 as usize..g.end_utf8 as usize]
                        .trim()
                        .is_empty()
                );
                (
                    g.start_utf8.max(frame.source_start),
                    g.end_utf8.min(frame.source_end),
                )
            })
            .filter(|(a, b)| a < b),
    );
    ranges.sort_unstable();
    assert_eq!(ranges.first().unwrap().0, frame.source_start);
    assert_eq!(ranges.last().unwrap().1, frame.source_end);
    for pair in ranges.windows(2) {
        assert_eq!(pair[0].1, pair[1].0);
    }
    if let Some(anchor) = frame.projection_anchor {
        assert!(
            frame
                .chunks
                .iter()
                .any(|c| c.start_utf8 <= anchor && anchor < c.end_utf8)
        );
    }
}
