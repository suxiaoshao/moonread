use crate::user::projection::ExposureSlot;
use crate::*;
use rusqlite::{Connection, OptionalExtension, params};

pub(crate) fn content_key(db: &Connection, id: &str) -> Result<String> {
    db.query_row("SELECT COALESCE(j.canonical_id,b.id) FROM reading_books b LEFT JOIN import_jobs j ON j.book_id=b.id WHERE b.id=?1", [id], |r| r.get(0))
        .optional()?.ok_or(ReaderError::NotFound)
}
pub(crate) fn chapter(db: &Connection, id: &str, offset: u64) -> Result<Option<ChapterInfo>> {
    Ok(db.query_row("SELECT start_utf8,title,level FROM effective_chapters WHERE book_id=?1 AND start_utf8<=?2 ORDER BY start_utf8 DESC LIMIT 1",
        params![id, offset.min(i64::MAX as u64) as i64], |r| Ok(ChapterInfo { start_utf8: unsigned_column(r,0)?, title:r.get(1)?, level:r.get(2)? })).optional()?)
}
// Business projections are exported only by ReaderQuery.
impl ReaderCore {
    /// A complete, lightweight snapshot of every published heading. Counts use
    /// prefix totals built with the text cache; this query never loads prose.
    pub(crate) fn chapter_outline(
        &self,
        book_id: String,
        exposures: &[Option<ExposureSlot>],
    ) -> Result<ChapterOutline> {
        self.chapter_outline_with_coverage(book_id, Some(exposures))
    }
    pub(crate) fn chapter_structure(&self, book_id: String) -> Result<ChapterOutline> {
        self.chapter_outline_with_coverage(book_id, None)
    }
    fn chapter_outline_with_coverage(
        &self,
        book_id: String,
        exposures: Option<&[Option<ExposureSlot>]>,
    ) -> Result<ChapterOutline> {
        let mut db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let tx = db.transaction()?;
        let id = content_key(&tx, &book_id)?;
        let complete: bool = tx.query_row(
            "SELECT NOT EXISTS(SELECT 1 FROM import_jobs WHERE book_id=?1 AND phase!='complete')",
            [&id],
            |r| r.get(0),
        )?;
        let total: u64 = tx.query_row(
            "SELECT COALESCE((SELECT end_char_count FROM chunks WHERE book_id=?1 ORDER BY chunk_index DESC LIMIT 1),0)",
            [&id], |r| unsigned_column(r, 0),
        )?;
        let mut statement = tx.prepare(
            "SELECT start_utf8,title,level,start_char_count,body_char_count FROM effective_chapters WHERE book_id=?1 ORDER BY start_utf8"
        )?;
        let headings = statement
            .query_map([&id], |r| {
                Ok(IndexedChapter {
                    start_utf8: unsigned_column(r, 0)?,
                    title: r.get(1)?,
                    level: r.get(2)?,
                    start_char_count: unsigned_column(r, 3)?,
                    body_char_count: unsigned_column(r, 4)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let coverage = if let Some(exposures) = exposures {
            crate::user::statistics::coverage::covered_char_ranges(&tx, &id, exposures)?
        } else {
            None
        };
        let mut parent: Option<&IndexedChapter> = None;
        let mut items = Vec::with_capacity(headings.len());
        for (index, heading) in headings.iter().enumerate() {
            let next = headings.get(index + 1);
            let end = next.map_or(total, |next| next.start_char_count);
            let word_count = end
                .checked_sub(heading.body_char_count)
                .ok_or(ReaderError::InvalidRange)?;
            if heading.level == 0 {
                parent = None;
            }
            items.push(ChapterEntry {
                start_utf8: heading.start_utf8,
                title: heading.title.clone(),
                level: heading.level,
                word_count,
                count_complete: next.is_some() || complete,
                parent_utf8: parent.map(|parent| parent.start_utf8),
                parent_title: parent.map(|parent| parent.title.clone()),
                covered_characters: coverage
                    .as_ref()
                    .filter(|_| next.is_some() || complete)
                    .map(|ranges| {
                        crate::user::statistics::coverage::count(
                            ranges,
                            heading.body_char_count,
                            end,
                        )
                    }),
            });
            if heading.level == 0 {
                parent = Some(heading);
            }
        }
        Ok(ChapterOutline {
            items,
            is_complete: complete,
        })
    }
}
