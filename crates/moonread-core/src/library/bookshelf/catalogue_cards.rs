use super::*;
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

/// Membership is keyed by physical file, not by SHA. One card may belong to
/// several groups without copying its presentation across the FFI.
pub(super) fn tag_memberships(books: &[LibraryEntry]) -> Vec<LibraryTagMembership> {
    let mut tagged = BTreeMap::<&str, Vec<String>>::new();
    let mut untagged = Vec::new();
    let mut unindexed = Vec::new();
    for book in books {
        let Some(row) = book.book() else { continue };
        if row.key().is_none() {
            unindexed.push(book.id.clone());
        } else if let Some(metadata) = row.metadata.as_ref().filter(|value| !value.tags.is_empty())
        {
            let tags: std::collections::BTreeSet<_> =
                metadata.tags.iter().map(String::as_str).collect();
            for tag in tags {
                tagged.entry(tag).or_default().push(book.id.clone());
            }
        } else {
            untagged.push(book.id.clone());
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
    groups.sort_by(|a, b| natural_cmp(&a.tag, &b.tag).then_with(|| a.tag.cmp(&b.tag)));
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

impl ReaderCore {
    pub(crate) fn all_library_book_cards(&self, shelf_id: String) -> Result<Vec<LibraryEntry>> {
        let db = self.read_lock()?;
        let mut cards = card_entries(&db, Some(&shelf_id), None, true)?;
        cards.sort_by(crate::library::order::file_order);
        Ok(cards)
    }

    pub(crate) fn all_library_tag_cards(&self, shelf_id: String) -> Result<LibraryTaggedCards> {
        let mut cards = self.all_library_books(shelf_id)?;
        let groups = tag_memberships(&cards);
        for card in &mut cards {
            if let LibraryItem::Book { row } = &mut card.item {
                row.card_metadata = row.metadata.take().map(|m| LibraryCardMetadata {
                    author: m.author,
                    cover: m.cover,
                });
            }
        }
        Ok(LibraryTaggedCards { cards, groups })
    }

    /// The matcher does not use body lengths, position offsets, chapter titles
    /// or covers. Directory activity remains part of the original search rank.
    pub(crate) fn library_search_matches(
        &self,
        scope: crate::CatalogueScope,
        books_only: bool,
    ) -> Result<Vec<LibrarySearchCandidate>> {
        let (shelf, parent, recursive) = scope.sql_scope();
        if let Some(parent) = parent {
            validate_relative(parent, true)?;
        }
        let db = self.read_lock()?;
        let mut statement = db.prepare_cached(&format!(
            "SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,f.directory,
                    f.size,f.modified,f.needs_download,fi.associated_book_id,0,0,NULL,0,
                    {FOLDER_LAST_READ},0,m.value,fi.content_sha256
             FROM library_files f JOIN library_shelves s ON s.id=f.shelf_id
             LEFT JOIN file_identities fi ON fi.file_id=f.id
             LEFT JOIN user_positions p ON p.content_key=fi.content_sha256
             LEFT JOIN book_metadata m ON m.content_sha=fi.content_sha256
             WHERE (?1 IS NULL OR f.shelf_id=?1) AND (?3=0 OR f.directory=0)
             AND (?2 IS NULL OR (?4=0 AND f.parent_path=?2) OR (?4=1 AND
                  (?2='' OR substr(f.relative_path,1,length(?2)+1)=?2||'/')))",
        ))?;
        let values = statement
            .query_map(
                params![shelf, parent, books_only, recursive],
                library_entry_row,
            )?
            .collect::<std::result::Result<_, _>>()?;
        search_candidates(&db, values, true)
    }

    pub(crate) fn library_search_detail_keys(
        &self,
        file_ids: Vec<String>,
    ) -> Result<LibraryDirectoryDetailKeys> {
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let input = serde_json::to_string(&file_ids).map_err(|_| ReaderError::InvalidSettings)?;
        let mut statement = tx.prepare_cached(
            "SELECT f.shelf_id,f.relative_path,f.directory,fi.content_sha256
             FROM json_each(?1) hit JOIN library_files f ON f.id=hit.value
             LEFT JOIN file_identities fi ON fi.file_id=f.id",
        )?;
        let mut rows = statement.query([input])?;
        super::directory_detail_keys(&tx, &mut rows)
    }

    pub(crate) fn library_search_cards(&self, file_ids: Vec<String>) -> Result<Vec<LibraryEntry>> {
        if file_ids.is_empty() {
            return Ok(vec![]);
        }
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let input = serde_json::to_string(&file_ids).map_err(|_| ReaderError::InvalidSettings)?;
        let mut statement = tx.prepare_cached(&format!(
            "{} AND f.id IN (SELECT value FROM json_each(?7))",
            *LIBRARY_ENTRIES_SQL,
        ))?;
        let mut cards = statement
            .query_map(
                params![
                    None::<String>,
                    None::<String>,
                    false,
                    None::<String>,
                    None::<String>,
                    None::<String>,
                    input
                ],
                library_card_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        drop(statement);
        populate_cover_previews(&tx, &mut cards)?;
        tx.commit()?;
        Ok(cards)
    }
}
