use super::{LibraryEntry, LibraryTagGroupKind};
use std::collections::BTreeMap;

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

#[derive(Debug, uniffi::Record)]
pub struct LibraryTagInput {
    pub file_id: String,
    pub identified: bool,
    pub tags: Vec<String>,
}

/// Takes already sorted file IDs and visible tag members, not full book cards.
#[uniffi::export]
pub fn catalogue_tag_memberships(rows: Vec<LibraryTagInput>) -> Vec<LibraryTagMembership> {
    let mut tagged = BTreeMap::<&str, Vec<String>>::new();
    let mut untagged = Vec::new();
    let mut unindexed = Vec::new();
    for row in &rows {
        if !row.identified {
            unindexed.push(row.file_id.clone());
        } else if !row.tags.is_empty() {
            let tags: std::collections::BTreeSet<_> = row.tags.iter().map(String::as_str).collect();
            for tag in tags {
                tagged.entry(tag).or_default().push(row.file_id.clone());
            }
        } else {
            untagged.push(row.file_id.clone());
        }
    }
    let mut groups: Vec<_> = tagged
        .into_iter()
        .map(|(tag, file_ids)| LibraryTagMembership {
            kind: LibraryTagGroupKind::Tag,
            tag: tag.into(),
            file_ids,
        })
        .collect();
    groups.sort_by(|a, b| {
        crate::library::order::natural_cmp(&a.tag, &b.tag).then_with(|| a.tag.cmp(&b.tag))
    });
    for (kind, file_ids) in [
        (LibraryTagGroupKind::Untagged, untagged),
        (LibraryTagGroupKind::Unindexed, unindexed),
    ] {
        if !file_ids.is_empty() {
            groups.push(LibraryTagMembership {
                kind,
                tag: String::new(),
                file_ids,
            });
        }
    }
    groups
}
