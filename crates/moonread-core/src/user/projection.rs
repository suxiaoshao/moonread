use crate::{BookMetadata, ReaderError, ReaderSettings, Result};

#[uniffi::export]
pub fn encode_reader_settings(value: ReaderSettings) -> Result<String> {
    serde_json::to_string(&value).map_err(|_| ReaderError::InvalidSettings)
}
#[uniffi::export]
pub fn decode_reader_settings(json: String) -> Result<ReaderSettings> {
    let value: ReaderSettings =
        serde_json::from_str(&json).map_err(|_| ReaderError::InvalidSettings)?;
    if !crate::reading::layout::valid(&value) {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(value)
}
#[uniffi::export]
pub fn encode_book_metadata(value: BookMetadata) -> Result<String> {
    serde_json::to_string(&value).map_err(|_| ReaderError::InvalidSettings)
}
#[uniffi::export]
pub fn decode_book_metadata(json: String) -> Result<BookMetadata> {
    serde_json::from_str(&json).map_err(|_| ReaderError::InvalidSettings)
}
