use crate::{ReaderError, Result};
use encoding_rs::{DecoderResult, Encoding};
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
    let mut decoder = encoding_rs::UTF_8.new_decoder_without_bom_handling();
    let mut output = vec![0; head.len() + 4];
    // last=false: a UTF-8 scalar cut at the probe boundary is not invalid.
    let (status, _, _) = decoder.decode_to_utf8_without_replacement(&head, &mut output, false);
    if !matches!(status, DecoderResult::Malformed(..)) {
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
    loop {
        let count = reader.read(&mut input)?;
        let last = count == 0;
        let mut consumed = 0;
        loop {
            let (status, read, written) = decoder.decode_to_utf8_without_replacement(
                &input[consumed..count],
                &mut output,
                last,
            );
            consumed += read;
            // encoding_rs guarantees valid UTF-8 output, even before a malformed input.
            let decoded =
                std::str::from_utf8(&output[..written]).map_err(|e| ReaderError::Decode {
                    message: e.to_string(),
                })?;
            for c in decoded.chars() {
                if c == '\0' || (c.is_control() && !matches!(c, '\n' | '\r' | '\t' | '\u{c}')) {
                    return Err(ReaderError::Decode {
                        message: "文件包含非文本控制字符".into(),
                    });
                }
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
            if pending
                .graphemes(true)
                .any(|g| g.len() > MAX_GRAPHEME_BYTES)
            {
                return Err(ReaderError::GraphemeTooLong);
            }
            while pending.len() >= CHUNK_BYTES {
                let mut boundary = 0;
                for (index, _) in pending.grapheme_indices(true).skip(1) {
                    if index > CHUNK_BYTES {
                        if boundary == 0 {
                            boundary = index;
                        }
                        break;
                    }
                    boundary = index;
                }
                if boundary == 0 {
                    break;
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
                DecoderResult::Malformed(..) => {
                    return Err(ReaderError::Decode {
                        message: format!("{} 中存在无法解码的字节", encoding.name()),
                    });
                }
                DecoderResult::InputEmpty => break,
                DecoderResult::OutputFull => continue,
            }
        }
        if last {
            break;
        }
    }
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
        assert!(matches!(
            decode_chunks(&mut Cursor::new(&late), encoding, |_| Ok(())),
            Err(ReaderError::Decode { .. })
        ));
    }
}
