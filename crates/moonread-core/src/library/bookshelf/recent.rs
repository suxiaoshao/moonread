//! The rank uses only reading activity and file identities; it fixes the exact
//! copies and offsets that presentation hydration must use.
use super::{LibraryEntry, PREFERRED_SOURCE_ORDER, library_card_row, library_entry_row};
use crate::{ReaderCore, ReaderError, ReadingKey, Result, parse_reading_key};
use rusqlite::Connection;
use serde::Serialize;
use std::sync::Arc;

#[derive(Debug, PartialEq, Serialize)]
struct RecentHit {
    file_id: String,
    content_key: String,
    book_id: Option<String>,
    position: i64,
    last_read: i64,
    preferred: bool,
}

#[derive(uniffi::Object)]
pub struct RecentLibraryRanking {
    limit: u32,
    hits: Vec<RecentHit>,
}

#[uniffi::export]
impl RecentLibraryRanking {
    pub fn reading_keys(&self) -> Result<Vec<ReadingKey>> {
        self.hits
            .iter()
            .map(|hit| parse_reading_key(hit.content_key.clone()))
            .collect()
    }
}

fn rank(db: &Connection, limit: u32) -> Result<Vec<RecentHit>> {
    let mut statement = db.prepare_cached(&format!(
        "WITH recent_positions AS (
            SELECT p.content_key,p.position_utf8,p.last_read,
                COALESCE(o.preferred_file_id,p.preferred_file_id) preferred_file_id,
                COALESCE(o.opened_ms,p.last_read) recent_order
            FROM user_positions p LEFT JOIN user_opened o ON o.content_key=p.content_key
            WHERE (p.last_read>0 OR o.opened_ms>0) AND COALESCE(p.recent_visible,1)=1
            UNION ALL
            SELECT o.content_key,0,0,o.preferred_file_id,o.opened_ms
            FROM user_opened o WHERE o.opened_ms>0 AND NOT EXISTS(SELECT 1 FROM user_positions p WHERE p.content_key=o.content_key)
        ), ranked AS (
            SELECT f.id,p.content_key,fi.associated_book_id,COALESCE(p.position_utf8,0) position_utf8,p.last_read,
                COALESCE(p.preferred_file_id=f.id,0) preferred,
                ROW_NUMBER() OVER (PARTITION BY p.content_key ORDER BY {PREFERRED_SOURCE_ORDER}) chosen,
                p.recent_order
            FROM recent_positions p
            JOIN file_identities fi ON fi.content_sha256=p.content_key
            JOIN library_files f ON f.id=fi.file_id
            JOIN library_shelves s ON s.id=f.shelf_id
        )
        SELECT id,content_key,associated_book_id,position_utf8,last_read,preferred
        FROM ranked WHERE chosen=1 ORDER BY recent_order DESC,preferred DESC,id LIMIT ?1"
    ))?;
    Ok(statement
        .query_map([limit.min(1000)], |r| {
            Ok(RecentHit {
                file_id: r.get(0)?,
                content_key: r.get(1)?,
                book_id: r.get(2)?,
                position: r.get(3)?,
                last_read: r.get(4)?,
                preferred: r.get(5)?,
            })
        })?
        .collect::<std::result::Result<_, _>>()?)
}

fn hydrate(db: &Connection, hits: &[RecentHit], cards: bool) -> Result<Option<Vec<LibraryEntry>>> {
    if hits.is_empty() {
        return Ok(Some(Vec::new()));
    }
    let input = serde_json::to_string(hits).map_err(|_| ReaderError::InvalidSettings)?;
    let mut statement = db.prepare_cached(
        "WITH selected AS MATERIALIZED (
            SELECT key ordinal,value->>'file_id' file_id,value->>'content_key' content_key,
                value->>'book_id' book_id,value->>'position' position_utf8,
                value->>'last_read' last_read,value->>'preferred' preferred
            FROM json_each(?1)
        ), lengths AS (
            SELECT content_sha256,MAX(utf8_bytes) utf8_bytes FROM source_identities
            WHERE content_sha256 IN (SELECT content_key FROM selected) GROUP BY content_sha256
        )
        SELECT f.id,f.shelf_id,s.name,f.relative_path,f.parent_path,f.name,f.directory,f.size,f.modified,f.needs_download,
            b.id,p.position_utf8,COALESCE(si.utf8_bytes,b.byte_count,0),
            (SELECT title FROM effective_chapters c WHERE c.book_id=b.id AND b.content_sha256=p.content_key
                AND c.start_utf8<=p.position_utf8 ORDER BY c.start_utf8 DESC LIMIT 1),
            0,p.last_read,p.preferred,m.value,p.content_key
        FROM selected p
        JOIN library_files f ON f.id=p.file_id
        JOIN library_shelves s ON s.id=f.shelf_id
        JOIN file_identities fi ON fi.file_id=f.id AND fi.content_sha256=p.content_key
            AND fi.associated_book_id IS p.book_id
        LEFT JOIN books b ON b.id=fi.associated_book_id
        LEFT JOIN lengths si ON si.content_sha256=p.content_key
        LEFT JOIN book_metadata m ON m.content_sha=p.content_key
        ORDER BY p.ordinal",
    )?;
    let entries: Vec<_> = statement
        .query_map(
            [input],
            if cards {
                library_card_row
            } else {
                library_entry_row
            },
        )?
        .collect::<std::result::Result<_, _>>()?;
    Ok((entries.len() == hits.len()).then_some(entries))
}

impl ReaderCore {
    pub(crate) fn recent_library_ranking(&self, limit: u32) -> Result<Arc<RecentLibraryRanking>> {
        Ok(Arc::new(RecentLibraryRanking {
            limit,
            hits: rank(&*self.read_lock()?, limit)?,
        }))
    }

    pub(crate) fn recent_library_ranking_matches(
        &self,
        ranking: &RecentLibraryRanking,
    ) -> Result<bool> {
        Ok(rank(&*self.read_lock()?, ranking.limit)? == ranking.hits)
    }

    pub(crate) fn hydrate_recent_library(
        &self,
        ranking: &RecentLibraryRanking,
        cards: bool,
    ) -> Result<Option<Vec<LibraryEntry>>> {
        hydrate(&*self.read_lock()?, &ranking.hits, cards)
    }

    pub(crate) fn recent_library_entries(&self, limit: u32) -> Result<Vec<LibraryEntry>> {
        let db = self.read_lock()?;
        let tx = db.unchecked_transaction()?;
        let hits = rank(&tx, limit)?;
        let result = hydrate(&tx, &hits, false)?.ok_or(ReaderError::NotFound)?;
        tx.commit()?;
        Ok(result)
    }
}
