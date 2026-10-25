//! SQLite decoding and lookups for the normalized text cache.
use crate::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
pub(crate) fn book_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookInfo> {
    Ok(BookInfo {
        id: row.get(0)?,
        title: row.get(1)?,
        content_sha256: row.get(2)?,
        encoding: row.get(3)?,
        byte_count: unsigned_column(row, 4)?,
        chunk_count: row.get(5)?,
        position_utf8: unsigned_column(row, 6)?,
    })
}

pub(crate) fn book(db: &Connection, id: &str) -> Result<BookInfo> {
    db.query_row("SELECT id,title,content_sha256,encoding,byte_count,chunk_count,position_utf8 FROM reading_books WHERE id=?1", [id], book_row).optional()?.ok_or(ReaderError::NotFound)
}
pub(crate) fn chunk(db: &Connection, id: &str, index: u32) -> Result<TextChunk> {
    db.query_row("SELECT chunk_index,start_utf8,end_utf8,text FROM chunks WHERE book_id=?1 AND chunk_index=?2", params![id,index], |r| {
        Ok(TextChunk { index: r.get(0)?, start_utf8: unsigned_column(r, 1)?, end_utf8: unsigned_column(r, 2)?, text: r.get(3)? })
    }).optional()?.ok_or(ReaderError::NotFound)
}
pub(crate) fn chunk_index(db: &Connection, id: &str, offset: u64) -> Result<u32> {
    db.query_row("SELECT chunk_index FROM chunks WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1", params![id,offset as i64], |r| r.get(0)).optional()?.ok_or(ReaderError::NotFound)
}

pub(crate) fn unsigned_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Integer,
            Box::new(e),
        )
    })
}
