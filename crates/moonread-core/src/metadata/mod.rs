//! External book information, not a backup or a second metadata/LWW owner.
mod archive;
mod document;
mod model;
mod parse;
mod stream;
mod writer;

pub use archive::*;
pub use document::*;
pub use model::*;
pub use stream::*;
pub use writer::*;

pub(crate) fn invalid(message: &str) -> crate::ReaderError {
    crate::ReaderError::MetadataExchange {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests;
