use super::{LibraryEntry, LibraryTagGroupKind};

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryTagMembership {
    pub kind: LibraryTagGroupKind,
    pub tag: String,
    pub file_ids: Vec<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibraryTaggedCards {
    pub cards: Vec<LibraryEntry>,
    pub groups: Vec<LibraryTagMembership>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LibrarySearchFields {
    pub author: String,
    pub tags: Vec<String>,
    pub status: crate::BookReadingStatus,
    pub stored: bool,
}
