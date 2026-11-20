//! Pure, bounded data-layer calls. The caller owns I/O and all commit points.
use crate::reading::input::text::{
    DECODER_WINDOW, ENCODING_PROBE_BYTES, TextDecoder, detect_sample,
};
use crate::reading::layout::BlankScanner;
use crate::*;
use encoding_rs::Encoding;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

/// UniFFI references can be aliased. Taking the value is the only state change
/// visible to an alias; a successor is a new object with exclusive contents.
pub(crate) struct StepState<T>(Mutex<Option<T>>);

impl<T> StepState<T> {
    pub(crate) fn new(value: T) -> Self {
        Self(Mutex::new(Some(value)))
    }

    pub(crate) fn take(&self) -> Result<T> {
        self.0
            .lock()
            .map_err(|_| ReaderError::InvalidSettings)?
            .take()
            .ok_or(ReaderError::InvalidSettings)
    }
}

#[uniffi::export]
pub fn detect_import_encoding(sample: Vec<u8>) -> Result<String> {
    if sample.len() > ENCODING_PROBE_BYTES + 1 {
        return Err(ReaderError::InvalidSettings);
    }
    let encoding = detect_sample(
        &sample[..sample.len().min(ENCODING_PROBE_BYTES)],
        sample.len() <= ENCODING_PROBE_BYTES,
    );
    Ok(encoding.name().to_owned())
}

#[derive(uniffi::Object)]
pub struct RawHashState(StepState<Sha256>);

#[derive(uniffi::Record)]
pub struct RawHashStep {
    pub next: Option<Arc<RawHashState>>,
    pub sha256: Option<String>,
}

#[uniffi::export]
pub fn begin_raw_hash() -> Arc<RawHashState> {
    Arc::new(RawHashState(StepState::new(Sha256::new())))
}

/// At most 1 MiB. An error consumes the input ticket as well.
#[uniffi::export]
pub fn advance_raw_hash(
    previous: Arc<RawHashState>,
    bytes: Vec<u8>,
    eof: bool,
) -> Result<RawHashStep> {
    let mut hash = previous.0.take()?;
    if bytes.len() > 1024 * 1024 {
        return Err(ReaderError::InvalidSettings);
    }
    hash.update(bytes);
    Ok(if eof {
        RawHashStep {
            next: None,
            sha256: Some(sha256_hex(hash.finalize())),
        }
    } else {
        RawHashStep {
            next: Some(Arc::new(RawHashState(StepState::new(hash)))),
            sha256: None,
        }
    })
}

#[derive(Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TextImportMode {
    Index,
    Identity,
}

#[derive(uniffi::Object)]
pub struct TextImportState(StepState<TextImport>);

struct TextImport {
    encoding: &'static Encoding,
    decoder: TextDecoder,
    // Reconstitute the published decoder window even when the I/O adapter
    // returns short reads. Don't let the Swift batching choose chunk boundaries.
    input: Vec<u8>,
    raw: Sha256,
    source_bytes: u64,
    output: ImportOutput,
}

struct ImportOutput {
    index: Option<ImportIndex>,
    text: Sha256,
    normalized_bytes: u64,
    char_count: u64,
}

struct ImportIndex {
    scanner: ChapterScanner,
    blanks: BlankScanner,
    next_chunk: u32,
    offset: u64,
    replay_count: u32,
    replay_at: usize,
}

#[derive(uniffi::Record)]
pub struct IndexedTextChunk {
    pub chunk: TextChunk,
    pub start_char_count: u64,
    pub end_char_count: u64,
}

#[derive(uniffi::Record)]
pub struct TextImportStep {
    pub next: Option<Arc<TextImportState>>,
    pub identity: Option<SourceTextIdentity>,
    pub chunks: Vec<IndexedTextChunk>,
    pub chapters: Vec<IndexedChapter>,
    pub blank_updates: Vec<SourceSpan>,
    pub projection_end: u64,
    pub source_bytes: u64,
    pub next_replay_chunk: Option<u32>,
    pub has_text: bool,
}

#[uniffi::export]
pub fn begin_text_import(
    encoding: String,
    mode: TextImportMode,
    published_chunk_count: u32,
) -> Result<Arc<TextImportState>> {
    if mode == TextImportMode::Identity && published_chunk_count != 0 {
        return Err(ReaderError::InvalidSettings);
    }
    let encoding = Encoding::for_label(encoding.as_bytes()).ok_or(ReaderError::InvalidSettings)?;
    Ok(Arc::new(TextImportState(StepState::new(TextImport {
        encoding,
        decoder: TextDecoder::new(encoding),
        input: Vec::with_capacity(DECODER_WINDOW * 2),
        raw: Sha256::new(),
        source_bytes: 0,
        output: ImportOutput {
            index: (mode == TextImportMode::Index).then(|| ImportIndex {
                scanner: Default::default(),
                blanks: Default::default(),
                next_chunk: 0,
                offset: 0,
                replay_count: published_chunk_count,
                replay_at: 0,
            }),
            text: Sha256::new(),
            normalized_bytes: 0,
            char_count: 0,
        },
    }))))
}

/// Pass at most 8192 new bytes with an explicit EOF. On restart, supply a
/// window of at most 16 old chunks starting at the last returned replay index
/// (0 initially). The state never retains their text or replays a whole prefix
/// per batch. Swift must discard the returned state if a commit fails.
#[uniffi::export]
pub fn advance_text_import(
    previous: Arc<TextImportState>,
    bytes: Vec<u8>,
    eof: bool,
    replay: Vec<TextChunk>,
) -> Result<TextImportStep> {
    let mut state = previous.0.take()?;
    if bytes.len() > DECODER_WINDOW
        || replay.len() > 16
        || replay
            .iter()
            .any(|c| c.text.is_empty() || c.text.len() > 64 * 1024)
        || (state.output.index.is_none() && !replay.is_empty())
    {
        return Err(ReaderError::InvalidSettings);
    }
    state.raw.update(&bytes);
    state.source_bytes = checked_bytes(state.source_bytes, bytes.len())?;
    state.input.extend(bytes);

    let mut chunks = Vec::new();
    let first = state
        .output
        .index
        .as_ref()
        .map_or(0, |index| index.next_chunk);
    let mut accept = |text: &str| state.output.accept(text, first, &replay, &mut chunks);
    if state.input.len() >= DECODER_WINDOW {
        state
            .decoder
            .decode(&state.input[..DECODER_WINDOW], false, &mut accept)?;
        state.input.drain(..DECODER_WINDOW);
    }
    if eof {
        if !state.input.is_empty() {
            state.decoder.decode(&state.input, false, &mut accept)?;
        }
        state.decoder.decode(&[], true, &mut accept)?;
    }

    let mut chapters = Vec::new();
    let mut blank_updates = Vec::new();
    let mut projection_end = 0;
    let mut next_replay_chunk = None;
    if let Some(index) = &mut state.output.index {
        if index.next_chunk < index.replay_count {
            if eof {
                return Err(ReaderError::SourceChanged);
            }
            next_replay_chunk = Some(index.next_chunk);
        }
        if eof {
            index.scanner.finish_line();
            index.blanks.finish_line();
        }
        chapters = std::mem::take(&mut index.scanner.chapters);
        let (end, updates) = index.blanks.drain();
        projection_end = end;
        blank_updates = updates
            .into_iter()
            .map(|(start_utf8, end_utf8)| SourceSpan {
                start_utf8,
                end_utf8,
            })
            .collect();
    }

    let source_bytes = state.source_bytes;
    let has_text = state.output.char_count > 0;
    let (next, identity) = if eof {
        if !has_text {
            return Err(ReaderError::EmptyBook);
        }
        (
            None,
            Some(SourceTextIdentity {
                content_sha256: sha256_hex(state.output.text.finalize()),
                raw_sha256: sha256_hex(state.raw.finalize()),
                encoding: state.encoding.name().to_owned(),
                source_bytes,
                utf8_bytes: state.output.normalized_bytes,
                char_count: state.output.char_count,
            }),
        )
    } else {
        (Some(Arc::new(TextImportState(StepState::new(state)))), None)
    };
    Ok(TextImportStep {
        next,
        identity,
        chunks,
        chapters,
        blank_updates,
        projection_end,
        source_bytes,
        next_replay_chunk,
        has_text,
    })
}

fn checked_bytes(offset: u64, added: usize) -> Result<u64> {
    offset
        .checked_add(added as u64)
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or(ReaderError::TextCapacityExceeded)
}

impl ImportOutput {
    fn accept(
        &mut self,
        text: &str,
        first: u32,
        replay: &[TextChunk],
        chunks: &mut Vec<IndexedTextChunk>,
    ) -> Result<()> {
        self.normalized_bytes = checked_bytes(self.normalized_bytes, text.len())?;
        self.text.update(text.as_bytes());
        self.char_count += text.chars().filter(|c| !c.is_whitespace()).count() as u64;
        let Some(index) = &mut self.index else {
            return Ok(());
        };
        let mut bytes = text.as_bytes();
        while !bytes.is_empty() && index.next_chunk < index.replay_count {
            let old = replay
                .get((index.next_chunk - first) as usize)
                .ok_or(ReaderError::SourceChanged)?;
            let end = checked_bytes(index.offset, old.text.len())?;
            if old.index != index.next_chunk
                || old.start_utf8 != index.offset
                || old.end_utf8 != end
                || index.replay_at >= old.text.len()
            {
                return Err(ReaderError::SourceChanged);
            }
            let compared = bytes.len().min(old.text.len() - index.replay_at);
            if bytes[..compared] != old.text.as_bytes()[index.replay_at..index.replay_at + compared]
            {
                return Err(ReaderError::SourceChanged);
            }
            bytes = &bytes[compared..];
            index.replay_at += compared;
            if index.replay_at == old.text.len() {
                index.scanner.push_chunk(index.offset, &old.text);
                index.blanks.push(&old.text);
                index.scanner.chapters.clear();
                index.blanks.discard_published_prefix();
                index.advance(end)?;
                index.replay_at = 0;
            }
        }
        if !bytes.is_empty() {
            let text = std::str::from_utf8(bytes).map_err(|_| ReaderError::SourceChanged)?;
            let end = checked_bytes(index.offset, text.len())?;
            let start_char_count = index.scanner.char_count;
            index.scanner.push_chunk(index.offset, text);
            index.blanks.push(text);
            chunks.push(IndexedTextChunk {
                chunk: TextChunk {
                    index: index.next_chunk,
                    start_utf8: index.offset,
                    end_utf8: end,
                    text: text.to_owned(),
                },
                start_char_count,
                end_char_count: index.scanner.char_count,
            });
            index.advance(end)?;
        }
        Ok(())
    }
}

impl ImportIndex {
    fn advance(&mut self, end: u64) -> Result<()> {
        self.offset = end;
        self.next_chunk = self
            .next_chunk
            .checked_add(1)
            .ok_or(ReaderError::TextCapacityExceeded)?;
        Ok(())
    }
}

#[derive(uniffi::Object)]
pub struct ChapterScanState(StepState<ChapterScan>);

#[derive(Default)]
struct ChapterScan {
    scanner: ChapterScanner,
    next: u32,
    offset: u64,
}

#[derive(uniffi::Record)]
pub struct ChapterScanStep {
    pub next: Option<Arc<ChapterScanState>>,
    pub chapters: Vec<IndexedChapter>,
    pub next_chunk: u32,
}

#[uniffi::export]
pub fn begin_chapter_scan() -> Arc<ChapterScanState> {
    Arc::new(ChapterScanState(StepState::new(ChapterScan::default())))
}

/// Detect headings in existing normalized chunks. Swift determines EOF,
/// cancellation, staging, and whether the source revision still permits apply.
#[uniffi::export]
pub fn advance_chapter_scan(
    previous: Arc<ChapterScanState>,
    chunks: Vec<TextChunk>,
    eof: bool,
) -> Result<ChapterScanStep> {
    let mut scan = previous.0.take()?;
    if chunks.len() > 16 {
        return Err(ReaderError::InvalidSettings);
    }
    for chunk in chunks {
        if chunk.text.is_empty()
            || chunk.text.len() > 64 * 1024
            || chunk.index != scan.next
            || chunk.start_utf8 != scan.offset
            || chunk.end_utf8 != checked_bytes(scan.offset, chunk.text.len())?
        {
            return Err(ReaderError::SourceChanged);
        }
        scan.scanner.push_chunk(scan.offset, &chunk.text);
        scan.offset = chunk.end_utf8;
        scan.next = scan
            .next
            .checked_add(1)
            .ok_or(ReaderError::TextCapacityExceeded)?;
    }
    let next_chunk = scan.next;
    let (next, chapters) = if eof {
        (None, scan.scanner.finish())
    } else {
        let chapters = std::mem::take(&mut scan.scanner.chapters);
        (
            Some(Arc::new(ChapterScanState(StepState::new(scan)))),
            chapters,
        )
    };
    Ok(ChapterScanStep {
        next,
        chapters,
        next_chunk,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reading::input::text::decode_chunks;
    use std::io::Cursor;

    #[test]
    fn explicit_stream_preserves_published_decoder_and_identity() -> Result<()> {
        let source = "第一章 雨\r\n\r\n日本語の本文。\r\n".repeat(3100);
        for encoding in [encoding_rs::UTF_8, encoding_rs::ISO_2022_JP] {
            let (raw, _, replaced) = encoding.encode(&source);
            assert!(!replaced);
            let mut published = Vec::new();
            decode_chunks(&mut Cursor::new(raw.as_ref()), encoding, |text| {
                published.push(text.to_owned());
                Ok(())
            })?;
            let expected = source.replace("\r\n", "\n");
            assert_eq!(published.concat(), expected);
            let body_sha = sha256_hex(Sha256::digest(expected.as_bytes()));
            let raw_sha = sha256_hex(Sha256::digest(raw.as_ref()));
            let mut indexed = begin_text_import(encoding.name().into(), TextImportMode::Index, 0)?;
            let mut identity =
                begin_text_import(encoding.name().into(), TextImportMode::Identity, 0)?;
            let mut output = Vec::new();
            let mut offset = 0;
            let mut scalars = 0;
            let mut headings = 0;
            for part in raw.chunks(1499).chain(std::iter::once(&[][..])) {
                let eof = part.is_empty();
                let index = advance_text_import(indexed.clone(), part.to_vec(), eof, vec![])?;
                let id = advance_text_import(identity.clone(), part.to_vec(), eof, vec![])?;
                assert!(
                    id.chunks.is_empty() && id.chapters.is_empty() && id.blank_updates.is_empty()
                );
                for entry in index.chunks {
                    assert_eq!(entry.chunk.index as usize, output.len());
                    assert_eq!(entry.chunk.start_utf8, offset);
                    assert_eq!(entry.start_char_count, scalars);
                    offset += entry.chunk.text.len() as u64;
                    assert_eq!(entry.chunk.end_utf8, offset);
                    scalars += entry
                        .chunk
                        .text
                        .chars()
                        .filter(|c| !c.is_whitespace())
                        .count() as u64;
                    assert_eq!(entry.end_char_count, scalars);
                    output.push(entry.chunk.text);
                }
                headings += index.chapters.len();
                if eof {
                    for fingerprint in [index.identity.unwrap(), id.identity.unwrap()] {
                        assert_eq!(fingerprint.content_sha256, body_sha);
                        assert_eq!(fingerprint.raw_sha256, raw_sha);
                        assert_eq!(fingerprint.utf8_bytes, offset);
                        assert_eq!(fingerprint.source_bytes, raw.len() as u64);
                        assert_eq!(fingerprint.char_count, scalars);
                    }
                    assert_eq!(index.projection_end, expected.len() as u64);
                } else {
                    indexed = index.next.unwrap();
                    identity = id.next.unwrap();
                }
            }
            assert_eq!(output, published);
            assert_eq!(headings, 3100);
        }
        Ok(())
    }

    #[test]
    fn prefix_replay_preserves_old_boundaries_and_fails_closed() -> Result<()> {
        let head = "第一章 天亮\n\n";
        let body = format!("{head}\n{}\n第二章 傍晚", "继续阅读。\n".repeat(5100));
        let bytes = body.as_bytes();
        let stored = || TextChunk {
            index: 0,
            start_utf8: 0,
            end_utf8: head.len() as u64,
            text: head.into(),
        };
        let fresh = || begin_text_import("utf-8".into(), TextImportMode::Index, 1);
        let mut state = fresh()?;
        let mut replay = true;
        let mut headings = Vec::new();
        let mut suffix = String::new();
        let mut spans = Vec::new();
        for part in bytes.chunks(8192).chain(std::iter::once(&[][..])) {
            let result = advance_text_import(
                state.clone(),
                part.to_vec(),
                part.is_empty(),
                if replay { vec![stored()] } else { vec![] },
            )?;
            replay = result.next_replay_chunk.is_some();
            headings.extend(result.chapters);
            spans.extend(result.blank_updates);
            for block in result.chunks {
                assert_eq!(block.chunk.start_utf8 as usize, head.len() + suffix.len());
                suffix.push_str(&block.chunk.text);
            }
            if let Some(next) = result.next {
                state = next;
            }
        }
        assert_eq!(suffix, body[head.len()..]);
        assert_eq!(
            headings
                .iter()
                .map(|h| h.title.as_str())
                .collect::<Vec<_>>(),
            ["第二章 傍晚"]
        );
        assert!(
            spans.iter().any(|s| s.start_utf8 == (head.len() - 1) as u64
                && s.end_utf8 == (head.len() + 1) as u64)
        );

        let bad = fresh()?;
        let changed = TextChunk {
            text: head.replace("亮", "明"),
            ..stored()
        };
        assert!(matches!(
            advance_text_import(bad.clone(), bytes[..8192].to_vec(), true, vec![changed]),
            Err(ReaderError::SourceChanged)
        ));
        assert!(matches!(
            advance_text_import(bad, vec![], false, vec![]),
            Err(ReaderError::InvalidSettings)
        ));
        assert!(matches!(
            advance_text_import(fresh()?, vec![], true, vec![]),
            Err(ReaderError::SourceChanged)
        ));
        Ok(())
    }

    #[test]
    fn hash_and_chapter_tickets_are_consumed_even_on_invalid_input() -> Result<()> {
        let raw = begin_raw_hash();
        let next = advance_raw_hash(raw.clone(), b"abc".to_vec(), false)?
            .next
            .unwrap();
        assert!(matches!(
            advance_raw_hash(raw, vec![], true),
            Err(ReaderError::InvalidSettings)
        ));
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(
            advance_raw_hash(next, vec![], true)?.sha256.as_deref(),
            Some(expected)
        );
        let first = begin_chapter_scan();
        let words = "Chapter ";
        let step = advance_chapter_scan(
            first.clone(),
            vec![TextChunk {
                index: 0,
                start_utf8: 0,
                end_utf8: words.len() as u64,
                text: words.into(),
            }],
            false,
        )?;
        assert!(step.chapters.is_empty());
        assert!(matches!(
            advance_chapter_scan(first, vec![], true),
            Err(ReaderError::InvalidSettings)
        ));
        let end = "1\nA\nChapter 2";
        let final_step = advance_chapter_scan(
            step.next.unwrap(),
            vec![TextChunk {
                index: 1,
                start_utf8: words.len() as u64,
                end_utf8: (words.len() + end.len()) as u64,
                text: end.into(),
            }],
            true,
        )?;
        assert!(final_step.next.is_none());
        assert_eq!(
            final_step
                .chapters
                .iter()
                .map(|h| (h.title.as_str(), h.start_utf8))
                .collect::<Vec<_>>(),
            [("Chapter 1", 0), ("Chapter 2", 12)]
        );
        let bad = begin_chapter_scan();
        assert!(matches!(
            advance_chapter_scan(
                bad.clone(),
                vec![TextChunk {
                    index: 1,
                    start_utf8: 0,
                    end_utf8: 1,
                    text: "x".into()
                }],
                false
            ),
            Err(ReaderError::SourceChanged)
        ));
        assert!(matches!(
            advance_chapter_scan(bad, vec![], true),
            Err(ReaderError::InvalidSettings)
        ));
        Ok(())
    }
}
