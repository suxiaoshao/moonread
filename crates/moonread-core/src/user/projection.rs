//! Disposable inputs for Rust calculations. These TEMP tables never enter reader.sqlite3.
use crate::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
use serde::Deserialize;
use std::sync::Arc;
use std::sync::Mutex;

#[derive(Default, Deserialize)]
struct UserProjection {
    #[serde(default)]
    positions: Vec<PositionInput>,
    #[serde(default)]
    metadata: Vec<BookMetadata>,
    #[serde(default)]
    facts: Vec<FactInput>,
    #[serde(default)]
    corrections: Vec<ChapterInput>,
    #[serde(default)]
    generation: u64,
    #[serde(default = "enabled")]
    enabled: bool,
}
fn enabled() -> bool {
    true
}
#[derive(Deserialize)]
struct PositionInput {
    content_key: String,
    offset: u64,
    updated: i64,
    visible: bool,
    preferred: Option<String>,
}
#[derive(Deserialize)]
struct FactInput {
    content_key: String,
    title: String,
    device: String,
    slice: ReadingSlice,
}
#[derive(Deserialize)]
struct ChapterInput {
    content_key: String,
    offset: u64,
    title: String,
    level: u32,
    excluded: bool,
}

pub(crate) fn initialize(db: &Connection) -> Result<()> {
    crate::identity::content::initialize(db)?;
    db.execute_batch(&format!("CREATE TEMP TABLE user_positions(content_key TEXT PRIMARY KEY,position_utf8 INTEGER,last_read INTEGER,recent_visible INTEGER,preferred_file_id TEXT);
    CREATE TEMP VIEW ranked_library_sources AS
    SELECT f.id file_id,fi.content_sha256,
      ROW_NUMBER() OVER (PARTITION BY fi.content_sha256 ORDER BY {source_order}) source_rank
    FROM main.library_files f JOIN file_identities fi ON fi.file_id=f.id
    LEFT JOIN user_positions p ON p.content_key=fi.content_sha256;
    CREATE TEMP VIEW reading_content_positions AS SELECT content_key content_sha256 FROM user_positions WHERE last_read>0;
    CREATE TEMP VIEW reading_books AS SELECT b.*,COALESCE(p.position_utf8,0) position_utf8,COALESCE(p.last_read,0) last_read,COALESCE(p.recent_visible,1) recent_visible,p.preferred_file_id FROM main.books b LEFT JOIN user_positions p ON p.content_key=b.content_sha256;
    CREATE TEMP TABLE book_metadata(content_sha TEXT PRIMARY KEY,value TEXT);
    CREATE TEMP TABLE chapter_overrides(book_id TEXT,start_utf8 INTEGER,title TEXT,level INTEGER,excluded INTEGER,start_char_count INTEGER,body_char_count INTEGER,PRIMARY KEY(book_id,start_utf8));
    CREATE TEMP VIEW effective_chapters AS
    SELECT a.book_id,a.start_utf8,COALESCE(o.title,a.title) title,COALESCE(o.level,a.level) level,COALESCE(o.start_char_count,a.start_char_count) start_char_count,COALESCE(o.body_char_count,a.body_char_count) body_char_count FROM import_chapters a LEFT JOIN chapter_overrides o ON a.book_id=o.book_id AND a.start_utf8=o.start_utf8 WHERE COALESCE(o.excluded,0)=0
    UNION ALL SELECT o.book_id,o.start_utf8,o.title,o.level,o.start_char_count,o.body_char_count FROM chapter_overrides o WHERE o.excluded=0 AND NOT EXISTS(SELECT 1 FROM import_chapters a WHERE a.book_id=o.book_id AND a.start_utf8=o.start_utf8);
    CREATE TEMP TABLE statistics_preferences(singleton INTEGER,enabled INTEGER,generation INTEGER);
    INSERT INTO statistics_preferences VALUES(1,1,0);
    CREATE TEMP TABLE reading_activity(id TEXT PRIMARY KEY,session_id TEXT,book_id TEXT,content_key TEXT,title TEXT,device_id TEXT,started_ms INTEGER,ended_ms INTEGER,local_day INTEGER,utc_offset_seconds INTEGER,preview INTEGER,exposures TEXT,visit_id TEXT,deleted INTEGER DEFAULT 0);", source_order = crate::library::bookshelf::PREFERRED_SOURCE_ORDER))?;
    Ok(())
}
fn apply(db: &mut Connection, value: &UserProjection) -> Result<()> {
    let tx = db.transaction()?;
    tx.execute_batch("DELETE FROM user_positions; DELETE FROM book_metadata; DELETE FROM chapter_overrides; DELETE FROM reading_activity;")?;
    tx.execute(
        "UPDATE statistics_preferences SET enabled=?1,generation=?2",
        params![value.enabled, value.generation as i64],
    )?;
    for p in &value.positions {
        tx.execute(
            "INSERT INTO user_positions VALUES(?1,?2,?3,?4,?5)",
            params![
                p.content_key,
                p.offset as i64,
                p.updated,
                p.visible,
                p.preferred
            ],
        )?;
    }
    for m in &value.metadata {
        tx.execute(
            "INSERT OR REPLACE INTO book_metadata VALUES(?1,?2)",
            params![
                m.sha,
                serde_json::to_string(m).map_err(|_| ReaderError::InvalidSettings)?
            ],
        )?;
    }
    for f in &value.facts {
        let s = &f.slice;
        let id: Option<String> = tx
            .query_row(
                "SELECT id FROM main.books WHERE content_sha256=?1",
                [&f.content_key],
                |r| r.get(0),
            )
            .optional()?;
        tx.execute("INSERT OR IGNORE INTO reading_activity VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,0)",params![s.id,s.session_id,id,f.content_key,f.title,f.device,s.started_ms,s.ended_ms,s.local_day,s.utc_offset_seconds,s.preview,serde_json::to_string(&s.exposures).map_err(|_|ReaderError::InvalidSettings)?,s.visit_id])?;
    }
    for c in &value.corrections {
        let id: Option<String> = tx
            .query_row(
                "SELECT id FROM main.books WHERE content_sha256=?1",
                [&c.content_key],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(id) = id {
            let (start, body) = crate::reading::navigation::chapter_counts(&tx, &id, c.offset)?;
            tx.execute(
                "INSERT OR REPLACE INTO chapter_overrides VALUES(?1,?2,?3,?4,?5,?6,?7)",
                params![
                    id,
                    c.offset as i64,
                    c.title,
                    c.level,
                    c.excluded,
                    start as i64,
                    body as i64
                ],
            )?;
        }
    }
    tx.commit()?;
    Ok(())
}
#[uniffi::export]
impl ReaderCore {
    /// A query owns its complete user input. It never changes the core's shared
    /// connections; subsequent queries cannot alter this snapshot or its jobs.
    pub fn query_snapshot(&self, json: String) -> Result<Arc<ReaderQuery>> {
        let value: UserProjection =
            serde_json::from_str(&json).map_err(|_| ReaderError::InvalidSettings)?;
        let open = || -> Result<Connection> {
            let mut db = Connection::open(&self.database_path)?;
            db.busy_timeout(std::time::Duration::from_secs(5))?;
            db.execute_batch("PRAGMA foreign_keys=ON;")?;
            initialize(&db)?;
            apply(&mut db, &value)?;
            db.execute_batch("PRAGMA query_only=ON;")?;
            Ok(db)
        };
        Ok(Arc::new(ReaderQuery {
            core: ReaderCore {
                db: Mutex::new(open()?),
                reader: Mutex::new(open()?),
                imports: Mutex::new(
                    self.imports
                        .lock()
                        .map_err(|_| ReaderError::ImportBusy)?
                        .clone(),
                ),
                import_failures: Mutex::new(
                    self.import_failures
                        .lock()
                        .map_err(|_| ReaderError::ImportBusy)?
                        .clone(),
                ),
                database_path: self.database_path.clone(),
            },
        }))
    }
    pub fn validate_chapter_offset(&self, book_id: String, offset_utf8: u64) -> Result<()> {
        let db = self.read_lock()?;
        let id = crate::library::tools::content_key(&db, &book_id)?;
        crate::reading::navigation::chapter_counts(&db, &id, offset_utf8)?;
        Ok(())
    }
    pub fn normalized_position(&self, book_id: String, offset_utf8: u64) -> Result<u64> {
        let db = self.read_lock()?;
        let id = crate::library::tools::content_key(&db, &book_id)?;
        let info = book(&db, &id)?;
        if info.byte_count == 0 {
            return Ok(0);
        }
        let mut offset = offset_utf8.min(info.byte_count);
        let c = chunk(&db, &id, chunk_index(&db, &id, offset)?)?;
        while !c.text.is_char_boundary((offset - c.start_utf8) as usize) {
            offset -= 1;
        }
        Ok(offset)
    }
}
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
#[uniffi::export]
pub fn encode_reading_slice(value: ReadingSlice) -> Result<String> {
    serde_json::to_string(&value).map_err(|_| ReaderError::InvalidSettings)
}

#[derive(uniffi::Object)]
pub struct ReaderQuery {
    core: ReaderCore,
}
#[uniffi::export]
impl ReaderQuery {
    pub fn book_info(&self, book_id: String) -> Result<BookInfo> {
        self.core.book_info(book_id)
    }
    pub fn reading_snapshot(&self, book_id: String) -> Result<ReadingSnapshot> {
        self.core.reading_snapshot(book_id)
    }
    pub fn recent_readings(&self) -> Result<Vec<ReadingSnapshot>> {
        self.core.recent_readings()
    }
    pub fn reading_frame(&self, book_id: String, offset_utf8: u64) -> Result<ReadingFrame> {
        self.core.reading_frame(book_id, offset_utf8)
    }
    pub fn reading_frame_extension(
        &self,
        book_id: String,
        cursor: u64,
        direction: ReadingDirection,
        keep: Option<SourceSpan>,
    ) -> Result<ReadingFrame> {
        self.core
            .reading_frame_extension(book_id, cursor, direction, keep)
    }
    pub fn chapter_at(&self, book_id: String, offset_utf8: u64) -> Result<Option<ChapterInfo>> {
        self.core.chapter_at(book_id, offset_utf8)
    }
    pub fn chapter_outline(&self, book_id: String) -> Result<ChapterOutline> {
        self.core.chapter_outline(book_id)
    }
    pub fn reading_location(&self, book_id: String, percentage: f64) -> Result<ReadingLocation> {
        self.core.reading_location(book_id, percentage)
    }
    pub fn adjacent_chapter(
        &self,
        book_id: String,
        offset_utf8: u64,
        forward: bool,
    ) -> Result<Option<ChapterInfo>> {
        self.core.adjacent_chapter(book_id, offset_utf8, forward)
    }
    pub fn start_search(
        &self,
        book_id: String,
        query: String,
        regular_expression: bool,
        case_sensitive: bool,
        range: Option<SearchRange>,
    ) -> Result<Arc<SearchJob>> {
        self.core
            .start_search(book_id, query, regular_expression, case_sensitive, range)
    }
    pub fn book_details(
        &self,
        book_id: Option<String>,
        content_sha: Option<String>,
    ) -> Result<BookDetails> {
        self.core.book_details(book_id, content_sha)
    }
    pub fn book_filter_options(&self, shelf_id: Option<String>) -> Result<BookFilterOptions> {
        self.core.book_filter_options(shelf_id)
    }
    pub fn library_entries(
        &self,
        shelf_id: Option<String>,
        parent_path: Option<String>,
        sort: LibrarySort,
    ) -> Result<Vec<LibraryEntry>> {
        self.core.library_entries(shelf_id, parent_path, sort)
    }
    pub fn library_folder_cover_previews(
        &self,
        shelf_id: String,
        relative_path: String,
    ) -> Result<Vec<crate::LibraryCoverPreview>> {
        self.core
            .library_folder_cover_previews(shelf_id, relative_path)
    }
    pub fn library_search_candidates(
        &self,
        scope: CatalogueScope,
        books_only: bool,
    ) -> Result<Vec<LibrarySearchCandidate>> {
        self.core.library_search_candidates(scope, books_only)
    }
    pub fn all_library_books(&self, shelf_id: String) -> Result<Vec<LibraryEntry>> {
        self.core.all_library_books(shelf_id)
    }
    pub fn all_library_tag_groups(&self, shelf_id: String) -> Result<LibraryTagCatalogue> {
        self.core.all_library_tag_groups(shelf_id)
    }
    pub fn library_entry(&self, file_id: String) -> Result<LibraryEntry> {
        self.core.library_entry(file_id)
    }
    pub fn system_reading_catalogue(&self) -> Result<Vec<SystemReadingBookProjection>> {
        self.core.system_reading_catalogue()
    }
    pub fn system_reading_sources(&self, content_sha256: String) -> Result<Vec<LibraryEntry>> {
        self.core.system_reading_sources(content_sha256)
    }
    pub fn recent_library_entries(&self, limit: u32) -> Result<Vec<LibraryEntry>> {
        self.core.recent_library_entries(limit)
    }
    pub fn statistics_overview(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<String>,
    ) -> Result<StatisticsOverview> {
        self.core
            .statistics_overview(first_day, last_day, content_key)
    }
    pub fn reading_activities(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<String>,
    ) -> Result<Vec<ReadingActivity>> {
        self.core
            .reading_activities(first_day, last_day, content_key)
    }
}
