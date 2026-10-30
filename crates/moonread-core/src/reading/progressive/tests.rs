use super::*;
use encoding_rs::UTF_8;
use sha2::Digest;
use sha2::Sha256;
use std::io::Cursor;
use std::io::Read;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;
use tempfile::TempDir;
#[test]
fn changed_raw_input_during_decode_cannot_finalize_or_publish_cache() {
    struct Changed {
        remaining: usize,
        first: bool,
    }
    impl Read for Changed {
        fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
            let n = out.len().min(self.remaining);
            out[..n].fill(if self.first { b'a' } else { b'b' });
            self.first = false;
            self.remaining -= n;
            Ok(n)
        }
    }
    let dir = TempDir::new().unwrap();
    let core = ReaderCore::new(dir.path().join("db").to_string_lossy().into()).unwrap();
    let token = core.create_import("Synthetic".into()).unwrap();
    let key = crate::SourceContentKey {
        raw_sha256: sha256_hex(Sha256::digest(vec![b'a'; 512 * 1024])),
        decoding: "auto".into(),
    };
    core.validate_import_source(token.clone(), key.clone())
        .unwrap();
    let result = core.stream_reader(
        &token,
        &mut Changed {
            remaining: 512 * 1024,
            first: true,
        },
        UTF_8,
    );
    assert!(matches!(result, Err(ReaderError::SourceChanged)));
    assert!(core.finish_import(token).is_err());
    assert!(core.source_book(key).unwrap().is_none());
    let file = dir.path().join("preflight.txt");
    std::fs::write(&file, "原文甲").unwrap();
    let token = core.create_import("Preflight".into()).unwrap();
    let raw = raw(&file);
    let key = crate::SourceContentKey {
        raw_sha256: raw.clone(),
        decoding: "auto".into(),
    };
    core.validate_import_source(token.clone(), key.clone())
        .unwrap();
    std::fs::write(&file, "原文乙").unwrap();
    assert!(
        matches!(
            core.stream_import(token.clone(), file.to_string_lossy().into(), raw, None),
            Err(ReaderError::SourceChanged)
        ),
        "replacement after preflight"
    );
    assert!(core.finish_import(token).is_err());
    assert!(core.source_book(key).unwrap().is_none());
}

fn raw(path: &std::path::Path) -> String {
    sha256_hex(Sha256::digest(std::fs::read(path).unwrap()))
}

fn setup() -> (TempDir, Arc<ReaderCore>) {
    let dir = TempDir::new().unwrap();
    let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
    (dir, core)
}

fn story() -> String {
    format!(
        "第一章 月光\n{}\n第二章 归途\n{}",
        "窗外的月光落在书页上，夜色安静。👨‍👩‍👧‍👦e\u{301}\n".repeat(1600),
        "沿着小路继续走。\n".repeat(1000)
    )
}

#[test]
fn import_failure_keeps_kind_and_parameters_after_reopen() {
    let (dir, core) = setup();
    let token = core.create_import("Fixture".into()).unwrap();
    let id = token.book_id();
    core.fail_import(
        token,
        ReaderError::Decode {
            message: "invalid byte at 42".into(),
        },
    )
    .unwrap();
    let stored: String = core
        .lock()
        .unwrap()
        .query_row(
            "SELECT error FROM import_jobs WHERE book_id=?1",
            [&id],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&stored).unwrap(),
        serde_json::json!({"kind": "decode", "message": "invalid byte at 42"})
    );
    drop(core);
    let reopened = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
    let state = reopened.reading_snapshot(id.clone()).unwrap();
    assert_eq!(state.phase, ImportPhase::Failed);
    assert!(
        matches!(state.error, Some(ReaderError::Decode { message }) if message == "invalid byte at 42")
    );
    let retry = reopened.resume_import(id.clone()).unwrap();
    assert!(
        reopened
            .reading_snapshot(id.clone())
            .unwrap()
            .error
            .is_none()
    );
    retry.pause();
    reopened.fail_import(retry, ReaderError::Paused).unwrap();
    let paused = reopened.reading_snapshot(id).unwrap();
    assert_eq!(paused.phase, ImportPhase::Paused);
    assert!(paused.error.is_none());
}

struct Gate {
    input: Cursor<Vec<u8>>,
    reached: mpsc::Sender<()>,
    proceed: mpsc::Receiver<()>,
    released: bool,
}
impl Read for Gate {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if !self.released && self.input.position() >= 64 * 1024 {
            self.reached.send(()).unwrap();
            self.proceed
                .recv_timeout(Duration::from_secs(5))
                .map_err(std::io::Error::other)?;
            self.released = true;
        }
        self.input.read(buffer)
    }
}

fn gated(
    core: &Arc<ReaderCore>,
    text: &str,
) -> (
    Arc<ImportControl>,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    std::thread::JoinHandle<Result<()>>,
) {
    let control = core.create_import("月下试读".into()).unwrap();
    core.lock()
        .unwrap()
        .execute(
            "UPDATE books SET encoding='UTF-8' WHERE id=?1",
            [&control.id],
        )
        .unwrap();
    let (reached_tx, reached) = mpsc::channel();
    let (proceed, proceed_rx) = mpsc::channel();
    let mut input = Gate {
        input: Cursor::new(text.as_bytes().to_vec()),
        reached: reached_tx,
        proceed: proceed_rx,
        released: false,
    };
    let worker_core = core.clone();
    let token = control.clone();
    let worker = std::thread::spawn(move || {
        let result = worker_core.stream_reader(&token, &mut input, UTF_8);
        if let Err(ref error) = result {
            worker_core.fail_import(token, error.clone()).unwrap();
        }
        result
    });
    (control, reached, proceed, worker)
}

#[test]
fn blank_window_awaiting_pause_resume_confirms_only_whole_lines() {
    for suffix in ["\n乙段。\n", "乙段。\n"] {
        let (_dir, core) = setup();
        let text = format!("甲段。\n{}{}", " ".repeat(200000), suffix);
        let (token, reached, proceed, worker) = gated(&core, &text);
        reached.recv_timeout(Duration::from_secs(5)).unwrap();
        let before = core.reading_frame(token.id.clone(), 0).unwrap();
        assert_eq!(before.status, ReadingWindowStatus::Ready);
        assert!(
            before.omitted.is_empty(),
            "Unterminated whitespace is not a blank paragraph"
        );
        let waiting = core
            .reading_frame_extension(
                token.id.clone(),
                before.snapshot.book.byte_count,
                ReadingDirection::Forward,
                None,
            )
            .unwrap();
        assert_eq!(waiting.status, ReadingWindowStatus::Awaiting);
        assert!(waiting.chunks.is_empty());
        assert!(waiting.projection_anchor.is_none());
        assert!(waiting.next_cursor.is_none());
        assert!(!waiting.is_end_of_book);
        let pending_cursor = before.snapshot.book.byte_count - 1;
        let pending_locate = core
            .reading_frame(token.id.clone(), pending_cursor)
            .unwrap();
        assert_eq!(pending_locate.status, ReadingWindowStatus::Awaiting);
        assert!(pending_locate.chunks.is_empty());
        assert!(matches!(
            core.display_text_range(token.id.clone(), 0, pending_cursor),
            Err(ReaderError::ImportBusy)
        ));
        assert!(
            before.source_end < before.snapshot.book.byte_count,
            "Pending suffix is not Ready payload"
        );
        let backwards = core
            .reading_frame_extension(
                token.id.clone(),
                pending_cursor,
                ReadingDirection::Backward,
                None,
            )
            .unwrap();
        assert_eq!(
            backwards.status,
            ReadingWindowStatus::Ready,
            "Pending tail does not block confirmed data to its left"
        );
        token.pause();
        proceed.send(()).unwrap();
        assert!(worker.join().unwrap().is_err());
        assert_eq!(
            core.reading_snapshot(token.id.clone()).unwrap().phase,
            ImportPhase::Paused
        );
        let resumed = core.resume_import(token.id.clone()).unwrap();
        core.stream_reader(&resumed, &mut Cursor::new(text.as_bytes()), UTF_8)
            .unwrap();
        core.finish_import(resumed).unwrap();
        let frame = core
            .reading_frame(token.id.clone(), before.snapshot.book.byte_count)
            .unwrap();
        assert!(frame.projection_anchor.is_some());
        if suffix.starts_with('\n') {
            assert_eq!(frame.omitted.len(), 1);
            assert_eq!(
                frame.omitted[0].end_utf8 - frame.omitted[0].start_utf8,
                200001
            );
            assert!(frame.chunks.iter().any(|c| c.text.contains("乙段")));
        } else {
            assert!(
                frame.omitted.is_empty(),
                "Spaces inside the confirmed nonblank paragraph must survive"
            );
            let restored = core.reading_frame(token.id.clone(), 10000).unwrap();
            assert_eq!(restored.status, ReadingWindowStatus::Ready);
            assert_eq!(restored.projection_anchor, Some(10000));
            assert!(restored.projection_revision > before.projection_revision);
        }
        assert_eq!(frame.snapshot.book.position_utf8, 0);
    }
}

#[test]
fn strict_extension_never_reverses_at_complete_boundaries() {
    let (dir, core) = setup();
    let text = format!("甲{}", " ".repeat(100000));
    let path = dir.path().join("trailing.txt");
    std::fs::write(&path, &text).unwrap();
    let book = core
        .import_book(path.to_string_lossy().into(), "合成".into())
        .unwrap();
    let located = core
        .reading_frame(book.id.clone(), book.byte_count)
        .unwrap();
    assert!(
        located.projection_anchor.is_some(),
        "Explicit locate may fall back"
    );
    let next = located.next_cursor;
    assert!(next.is_none(), "Locate at EOF has no retained continuation");
    let end = core
        .reading_frame_extension(
            book.id.clone(),
            book.byte_count,
            ReadingDirection::Forward,
            None,
        )
        .unwrap();
    assert_eq!(end.status, ReadingWindowStatus::End);
    assert!(end.chunks.is_empty());
    assert!(end.projection_anchor.is_none());
    assert!(end.next_cursor.is_none());
    let unicode = format!("{}乙🌙", " ".repeat(100000));
    std::fs::write(&path, &unicode).unwrap();
    let book = core
        .import_book(path.to_string_lossy().into(), "合成".into())
        .unwrap();
    let head = core
        .reading_frame_extension(book.id.clone(), 0, ReadingDirection::Backward, None)
        .unwrap();
    assert_eq!(head.status, ReadingWindowStatus::Ready);
    assert_eq!(
        head.projection_anchor,
        Some(0),
        "Retained indentation is available at BOF"
    );
    assert!(head.previous_cursor.is_none());
    let located = core
        .reading_frame(book.id.clone(), book.byte_count - 2)
        .unwrap();
    assert_eq!(
        located.projection_anchor,
        Some(book.byte_count - 4),
        "Locate rounds an interior UTF8 cursor down to its scalar"
    );
}

#[test]
fn tolerant_decode_resumes_old_failed_prefix_and_matches_index_identity() {
    let (dir, core) = setup();
    let mut bytes = "第一章 月光\n原创正文。\n".repeat(10000).into_bytes();
    bytes.extend_from_slice(b"\x0b\x0c\0\xfftail\xe4\xb8");
    let file = dir.path().join("recovery.txt");
    std::fs::write(&file, &bytes).unwrap();
    let token = core.create_import("恢复".into()).unwrap();
    core.validate_import_source(
        token.clone(),
        crate::SourceContentKey {
            raw_sha256: raw(&file),
            decoding: "auto".into(),
        },
    )
    .unwrap();
    core.lock()
        .unwrap()
        .execute("UPDATE books SET encoding='UTF-8' WHERE id=?1", [&token.id])
        .unwrap();
    // Simulate a legacy failed task containing a valid, shorter published
    // chunk. Recovery must respect that boundary instead of replacing it.
    let prefix = "第一章 月光\n原创正文。\n";
    let mut scanner = ChapterScanner::default();
    scanner.push_chunk(0, prefix);
    let mut blanks = crate::reading::layout::BlankScanner::default();
    blanks.push(prefix);
    core.commit_prefix(
        &token,
        &mut vec![(
            TextChunk {
                index: 0,
                start_utf8: 0,
                end_utf8: prefix.len() as u64,
                text: prefix.into(),
            },
            0,
            scanner.char_count,
        )],
        &mut scanner.chapters,
        &mut blanks,
        true,
        prefix.len() as u64,
    )
    .unwrap();
    core.fail_import(
        token.clone(),
        ReaderError::Decode {
            message: "legacy strict failure".into(),
        },
    )
    .unwrap();
    let retry = core.resume_import(token.id.clone()).unwrap();
    core.stream_import(
        retry.clone(),
        file.to_string_lossy().into(),
        raw(&file),
        None,
    )
    .unwrap();
    core.finish_import(retry).unwrap();
    let state = core.reading_snapshot(token.id.clone()).unwrap();
    assert_eq!(state.phase, ImportPhase::Complete);
    assert_eq!(core.read_chunk(token.id.clone(), 0).unwrap().text, prefix);
    let actual: String = (0..state.book.chunk_count)
        .map(|i| core.read_chunk(token.id.clone(), i).unwrap().text)
        .collect();
    assert_eq!(actual, String::from_utf8_lossy(&bytes));
    let identity = crate::SourceIdentityProbe::new()
        .identify(file.to_string_lossy().into(), "auto".into())
        .unwrap();
    assert_eq!(identity.content_sha256, state.book.content_sha256);
}

#[test]
fn source_changed_during_pause_cannot_append_to_old_prefix() {
    for change in ["prefix", "tail", "same size"] {
        let (dir, core) = setup();
        let text = "甲".repeat(5001);
        let file = dir.path().join("paused.txt");
        std::fs::write(&file, &text).unwrap();
        let token = core.create_import("Paused".into()).unwrap();
        let id = token.id.clone();
        core.stream_import(
            token.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        token.pause();
        core.fail_import(token, ReaderError::Paused).unwrap();
        let before = core.reading_frame(id.clone(), 0).unwrap().chunks[0]
            .text
            .clone();
        let changed = match change {
            "prefix" => format!("乙{}", "甲".repeat(5000)),
            "tail" => format!("{}乙", "甲".repeat(5000)),
            _ => "丙".repeat(5001),
        };
        std::fs::write(&file, changed).unwrap();
        let next = core.resume_import(id.clone()).unwrap();
        assert!(
            matches!(
                core.stream_import(next, file.to_string_lossy().into(), raw(&file), None),
                Err(ReaderError::SourceChanged)
            ),
            "{change}"
        );
        assert_eq!(
            core.reading_frame(id, 0).unwrap().chunks[0].text,
            before,
            "old prefix: {change}"
        );
    }
}

#[test]
fn storage_failure_preserves_prefix_even_if_error_status_cannot_be_written() {
    let (dir, core) = setup();
    let file = dir.path().join("space.txt");
    std::fs::write(&file, story()).unwrap();
    let token = core.create_import("空间不足".into()).unwrap();
    core.lock().unwrap().execute_batch("CREATE TEMP TRIGGER fail_chunks BEFORE INSERT ON chunks WHEN NEW.chunk_index > 3
            BEGIN SELECT RAISE(FAIL,'disk full'); END;
            CREATE TEMP TRIGGER fail_status BEFORE UPDATE OF phase ON import_jobs WHEN NEW.phase='failed'
            BEGIN SELECT RAISE(FAIL,'disk full'); END;").unwrap();
    assert!(
        core.stream_import(
            token.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None
        )
        .is_err()
    );
    let state = core.reading_snapshot(token.id.clone()).unwrap();
    assert!(state.can_read);
    assert_eq!(state.phase, ImportPhase::Failed);
    let prefix = core.reading_frame(token.id.clone(), 0).unwrap().chunks[0]
        .text
        .clone();
    core.lock()
        .unwrap()
        .execute_batch("DROP TRIGGER fail_chunks; DROP TRIGGER fail_status;")
        .unwrap();
    let retry = core.resume_import(token.id.clone()).unwrap();
    core.stream_import(
        retry.clone(),
        file.to_string_lossy().into(),
        raw(&file),
        None,
    )
    .unwrap();
    core.finish_import(retry).unwrap();
    assert_eq!(
        core.reading_frame(token.id.clone(), 0).unwrap().chunks[0].text,
        prefix
    );
}
#[test]
fn readable_and_position_calculation_works_before_eof() {
    let (_dir, core) = setup();
    let text = story();
    let (token, reached, proceed, worker) = gated(&core, &text);
    reached.recv_timeout(Duration::from_secs(5)).unwrap();
    let state = core.reading_snapshot(token.id.clone()).unwrap();
    assert!(state.can_read);
    assert!(state.book.byte_count < text.len() as u64);
    assert!(state.book.content_sha256.is_empty());
    assert!(
        !core
            .reading_frame(token.id.clone(), 0)
            .unwrap()
            .is_end_of_book
    );
    assert_eq!(
        core.normalized_position(token.id.clone(), 120).unwrap(),
        118
    );
    assert_eq!(
        core.reading_snapshot(token.id.clone())
            .unwrap()
            .book
            .position_utf8,
        0,
        "Position calculation never persists user state in the text store"
    );
    assert_eq!(
        core.chapter_at(token.id.clone(), 120)
            .unwrap()
            .unwrap()
            .title,
        "第一章 月光"
    );
    proceed.send(()).unwrap();
    worker.join().unwrap().unwrap();
    let id = core.finish_import(token).unwrap();
    let state = core.reading_snapshot(id.clone()).unwrap();
    assert_eq!(state.phase, ImportPhase::Complete);
    assert_eq!(state.book.byte_count, text.len() as u64);
    assert!(core.reading_frame(id, u64::MAX).unwrap().is_end_of_book);
}

#[test]
fn paused_prefix_survives_reopen_and_replay_continues_without_duplication() {
    for interruption in ["partial decode", "before final commit"] {
        let (dir, core) = setup();
        let text = story();
        let file = dir.path().join("story.txt");
        std::fs::write(&file, &text).unwrap();
        let id = if interruption == "partial decode" {
            let (token, reached, proceed, worker) = gated(&core, &text);
            reached.recv_timeout(Duration::from_secs(5)).unwrap();
            let id = token.id.clone();
            token.pause();
            proceed.send(()).unwrap();
            assert!(matches!(worker.join().unwrap(), Err(ReaderError::Paused)));
            id
        } else {
            let token = core.create_import("Interrupted".into()).unwrap();
            core.stream_import(
                token.clone(),
                file.to_string_lossy().into(),
                raw(&file),
                None,
            )
            .unwrap();
            token.id.clone()
        };
        drop(core);
        let core = ReaderCore::new(dir.path().join("data").to_string_lossy().into()).unwrap();
        let state = core.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.phase, ImportPhase::Paused, "{interruption}");
        assert!(state.can_read, "{interruption}");
        let next = core.resume_import(id.clone()).unwrap();
        core.stream_import(
            next.clone(),
            file.to_string_lossy().into(),
            raw(&file),
            None,
        )
        .unwrap();
        core.finish_import(next).unwrap();
        let state = core.reading_snapshot(id.clone()).unwrap();
        assert_eq!(state.phase, ImportPhase::Complete, "{interruption}");
        assert_eq!(
            (0..state.book.chunk_count)
                .map(|i| core.read_chunk(id.clone(), i).unwrap().text)
                .collect::<String>(),
            text,
            "replay must not duplicate: {interruption}"
        );
    }
}
