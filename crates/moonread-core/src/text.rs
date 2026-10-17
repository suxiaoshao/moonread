use crate::{ReaderError, Result};
use encoding_rs::{DecoderResult, Encoding};
use std::io::Read;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) const CHUNK_BYTES: usize = 12 * 1024;
const MAX_GRAPHEME_BYTES: usize = 64 * 1024;

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
