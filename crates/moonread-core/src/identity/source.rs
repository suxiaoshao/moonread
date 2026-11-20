use crate::{ReaderError, Result};
use encoding_rs::Encoding;

#[derive(Debug, Clone, uniffi::Record)]
pub struct SourceTextIdentity {
    pub content_sha256: String,
    pub raw_sha256: String,
    pub encoding: String,
    pub source_bytes: u64,
    pub utf8_bytes: u64,
    pub char_count: u64,
}
#[uniffi::export]
pub fn normalize_source_decoding(decoding: String) -> Result<String> {
    Ok(decoding_policy(&decoding)?.into())
}

pub(crate) fn decoding_policy(value: &str) -> Result<&'static str> {
    if value == "auto" {
        return Ok("auto");
    }
    Encoding::for_label(value.as_bytes())
        .filter(|e| ![encoding_rs::REPLACEMENT, encoding_rs::X_USER_DEFINED].contains(e))
        .map(|e| e.name())
        .ok_or(ReaderError::InvalidSettings)
}
#[cfg(test)]
mod decoding_policy_tests {
    use super::*;
    #[test]
    fn manual_policy_accepts_all_text_decoders_and_rejects_unsuitable_labels() {
        for (input, expected) in [
            ("UTF-16BE", "UTF-16BE"),
            ("utf-8", "UTF-8"),
            ("shift-jis", "Shift_JIS"),
            ("latin1", "windows-1252"),
        ] {
            assert_eq!(
                decoding_policy(input).unwrap(),
                expected,
                "manual decoding label {input}"
            );
        }
        for label in ["replacement", "not-an-encoding"] {
            assert!(
                matches!(decoding_policy(label), Err(ReaderError::InvalidSettings)),
                "unsafe label {label}"
            );
        }
    }
}
