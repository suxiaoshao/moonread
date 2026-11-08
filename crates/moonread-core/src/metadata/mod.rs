//! External book information, not a backup or a second metadata/LWW owner.
mod archive;
mod document;
mod model;
mod parse;
mod writer;

pub use archive::*;
pub use document::*;
pub use model::*;
pub use writer::*;

pub(crate) fn invalid(message: &str) -> crate::ReaderError {
    crate::ReaderError::MetadataExchange {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests;
