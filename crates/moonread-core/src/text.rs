use crate::{ReaderError, Result};
use encoding_rs::{CoderResult, DecoderResult, Encoding};
use std::io::Read;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) const CHUNK_BYTES: usize = 12 * 1024;
const MAX_GRAPHEME_BYTES: usize = 64 * 1024;

/// Detection is shared by both import entry points. Decode/normalization stays in
/// encoding_rs; never retry the whole book under a different encoding after publish.
pub(crate) const ENCODING_PROBE_BYTES: usize = 64 * 1024;
pub(crate) fn detect_encoding(reader: &mut impl Read) -> Result<&'static Encoding> {
    let mut head = Vec::with_capacity(ENCODING_PROBE_BYTES + 1);
    // One lookahead byte distinguishes EOF from a truncated sample for chardetng.
    reader
        .take((ENCODING_PROBE_BYTES + 1) as u64)
        .read_to_end(&mut head)?;
    let complete = head.len() <= ENCODING_PROBE_BYTES;
    head.truncate(ENCODING_PROBE_BYTES);
    if let Some((encoding, _)) = Encoding::for_bom(&head) {
        return Ok(encoding);
    }
    // BOMless UTF-16 requires manual selection; do not add a competing heuristic.
    let mut decoder = encoding_rs::UTF_8.new_decoder_without_bom_handling();
    let mut output = vec![0; head.len() + 4];
    // Only a capped sample may end inside a scalar. At real EOF validate strictly.
    let (status, _, _) = decoder.decode_to_utf8_without_replacement(&head, &mut output, complete);
    // Like Zed file_content, ESC must reach the ISO-2022-JP detector, even in ASCII.
    if !matches!(status, DecoderResult::Malformed(..)) && !head.contains(&0x1b) {
        return Ok(encoding_rs::UTF_8);
    }
    let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
    detector.feed(&head, complete);
    let encoding = detector.guess(None, chardetng::Utf8Detection::Deny);
    // Preserve the GB18030 decoder and recorded name of existing simplified books,
    // including its four-byte extension. No TLD/language hint biases the detector.
    Ok(if encoding == encoding_rs::GBK {
        encoding_rs::GB18030
    } else {
        encoding
    })
}

// Recovery-v1 leaves all scalar values intact. Inspect fixed 4096-scalar windows,
// independently of reader/decoder buffer boundaries: >= 10% NUL (at least 4)
// is evidence of binary data or BOMless UTF-16 decoded as an 8-bit encoding.
// One stray NUL, VT/FF, ESC, C1 and existing U+FFFD are ordinary text, not errors.
#[derive(Default)]
struct BinaryGuard {
    scalars: usize,
    nuls: usize,
}
impl BinaryGuard {
    fn push(&mut self, c: char) -> Result<()> {
        self.scalars += 1;
        self.nuls += usize::from(c == '\0');
        if self.scalars == 4096 {
            self.finish()?;
        }
        Ok(())
    }
    fn finish(&mut self) -> Result<()> {
        if self.nuls >= 4 && self.nuls * 10 >= self.scalars {
            return Err(ReaderError::BinaryContent);
        }
        self.scalars = 0;
        self.nuls = 0;
        Ok(())
    }
}

/// Normalization v1: remove initial BOM, map CRLF/CR to LF, preserve all other text.
/// Fixed-size buffers keep ingestion memory independent of book size.
pub(crate) fn decode_chunks(
    reader: &mut impl Read,
    encoding: &'static Encoding,
    mut emit: impl FnMut(&str) -> Result<()>,
) -> Result<()> {
    let mut decoder = encoding.new_decoder_with_bom_removal();
    let mut input = [0u8; 8192];
    let mut output = [0u8; 32768];
    let mut pending = String::with_capacity(CHUNK_BYTES + output.len());
    let mut previous_cr = false;
    let mut binary = BinaryGuard::default();
    let mut header = Vec::with_capacity(16);
    loop {
        let count = reader.read(&mut input)?;
        let last = count == 0;
        header.extend(input[..count].iter().take(16 - header.len()));
        // These signatures contain controls rejected by the old strict reader;
        // recognizing them does not change any previously successful text SHA.
        if [
            b"\x89PNG\r\n\x1a\n".as_slice(),
            b"PK\x03\x04",
            b"\x1f\x8b",
            b"\xff\xd8\xff\xe0\x00\x10JFIF\x00",
        ]
        .iter()
        .any(|magic| header.starts_with(magic))
        {
            return Err(ReaderError::BinaryContent);
        }
        let mut consumed = 0;
        loop {
            let (status, read, written, _) =
                decoder.decode_to_utf8(&input[consumed..count], &mut output, last);
            consumed += read;
            // encoding_rs guarantees valid UTF-8 output, even before a malformed input.
            let decoded =
                std::str::from_utf8(&output[..written]).map_err(|e| ReaderError::Decode {
                    message: e.to_string(),
                })?;
            for c in decoded.chars() {
                binary.push(c)?;
                if c == '\n' && previous_cr {
                    previous_cr = false;
                    continue;
                }
                previous_cr = c == '\r';
                pending.push(if previous_cr { '\n' } else { c });
            }
            // Keep the trailing, potentially incomplete grapheme until more text or EOF.
            // This also handles a decoder buffer ending between a base and combining mark,
            // or between the scalars of a ZWJ emoji sequence.
            while pending.len() >= CHUNK_BYTES {
                let mut boundary = 0;
                for (index, _) in pending.grapheme_indices(true).skip(1) {
                    if index > CHUNK_BYTES {
                        if boundary == 0 && index <= MAX_GRAPHEME_BYTES {
                            boundary = index;
                        }
                        break;
                    }
                    boundary = index;
                }
                if boundary == 0 {
                    if pending.len() <= MAX_GRAPHEME_BYTES {
                        break;
                    }
                    // A pathological extended grapheme may grow without bound.
                    // Split only at scalar boundaries; never drop/rewrite codepoints.
                    boundary = CHUNK_BYTES;
                    while !pending.is_char_boundary(boundary) {
                        boundary -= 1;
                    }
                }
                if let Some(newline) = pending[..boundary].rfind('\n')
                    && newline >= CHUNK_BYTES / 2
                {
                    boundary = newline + 1;
                }
                emit(&pending[..boundary])?;
                pending.drain(..boundary);
            }
            match status {
                CoderResult::InputEmpty => break,
                CoderResult::OutputFull => continue,
            }
        }
        if last {
            break;
        }
    }
    binary.finish()?;
    if !pending.is_empty() {
        emit(&pending)?;
    }
    Ok(())
}

#[cfg(test)]
mod encoding_tests {
    use super::*;
    use std::io::Cursor;
    #[test]
    fn recovery_preserves_controls_and_rejects_binary_evidence() {
        let text = format!("{}\u{b}\u{c}\0\u{1a}\u{85}尾", "正文\r\n".repeat(20000));
        let mut recovered = String::new();
        decode_chunks(&mut Cursor::new(text.as_bytes()), encoding_rs::UTF_8, |s| {
            recovered.push_str(s);
            Ok(())
        })
        .unwrap();
        assert_eq!(recovered, text.replace("\r\n", "\n"));
        for bytes in [
            b"a\0b\0c\0d\0".as_slice(),
            b"PK\x03\x04rest",
            b"\x89PNG\r\n\x1a\nrest",
        ] {
            assert!(matches!(
                decode_chunks(&mut Cursor::new(bytes), encoding_rs::UTF_8, |_| Ok(())),
                Err(ReaderError::BinaryContent)
            ));
        }
        // Three legacy characters can resemble a JPEG prefix; require the full
        // JFIF header (with NUL), not just those previously readable bytes.
        decode_chunks(
            &mut Cursor::new([0xff, 0xd8, 0xff]),
            encoding_rs::WINDOWS_1252,
            |_| Ok(()),
        )
        .unwrap();
        let mut recovered = String::new();
        decode_chunks(
            &mut Cursor::new([0xff, 0xfe, 0x41, 0, 0, 0xd8]),
            encoding_rs::UTF_16LE,
            |s| {
                recovered.push_str(s);
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(recovered, "A\u{fffd}");
    }

    #[test]
    fn encoding_probe_handles_bom_and_tiny_statistical_input() {
        assert_eq!(
            detect_encoding(&mut Cursor::new(&[0xff, 0xfe, 0x41, 0])).unwrap(),
            encoding_rs::UTF_16LE
        );
        assert_eq!(
            detect_encoding(&mut Cursor::new(&[0xef, 0xbb, 0xbf, b'A'])).unwrap(),
            encoding_rs::UTF_8
        );
        // Statistically insufficient tiny files use the detector's pinned result;
        // users can select an encoding manually. No locale/TLD or fallback heuristic.
        assert_eq!(
            detect_encoding(&mut Cursor::new(&[0xd6, 0xd0])).unwrap(),
            encoding_rs::WINDOWS_1252
        );
        let mut recovered = String::new();
        decode_chunks(&mut Cursor::new([0x81]), encoding_rs::SHIFT_JIS, |s| {
            recovered.push_str(s);
            Ok(())
        })
        .unwrap();
        assert_eq!(recovered, "\u{fffd}");
    }

    #[test]
    fn probe_is_bounded_and_preserves_truncated_utf8_without_late_retry() {
        let text = format!(
            "{}中{}",
            "A".repeat(ENCODING_PROBE_BYTES - 2),
            "B".repeat(ENCODING_PROBE_BYTES)
        );
        let mut reader = Cursor::new(text.as_bytes());
        assert_eq!(detect_encoding(&mut reader).unwrap(), encoding_rs::UTF_8);
        assert_eq!(reader.position(), (ENCODING_PROBE_BYTES + 1) as u64);
        let mut late = vec![b'A'; ENCODING_PROBE_BYTES + 20];
        late.push(0xff);
        let mut reader = Cursor::new(late.as_slice());
        let encoding = detect_encoding(&mut reader).unwrap();
        assert_eq!(encoding, encoding_rs::UTF_8);
        assert_eq!(reader.position(), (ENCODING_PROBE_BYTES + 1) as u64);
        let mut recovered = String::new();
        decode_chunks(&mut Cursor::new(&late), encoding, |s| {
            recovered.push_str(s);
            Ok(())
        })
        .unwrap();
        assert_eq!(
            recovered,
            format!("{}\u{fffd}", "A".repeat(ENCODING_PROBE_BYTES + 20))
        );
    }
}
