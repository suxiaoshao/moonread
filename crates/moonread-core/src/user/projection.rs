//! Disposable inputs for Rust calculations. These TEMP tables never enter reader.sqlite3.
use super::reading_fact::FactData;
use crate::*;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
use rusqlite::types::Value;
use serde::{Deserialize, de::IgnoredAny};
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::Mutex;

#[derive(Default, Deserialize)]
struct UserProjection {
    #[serde(default)]
    positions: Vec<PositionInput>,
    #[serde(default)]
    opened: Vec<OpenedInput>,
    #[serde(default)]
    metadata: Vec<BookMetadata>,
    #[serde(default)]
    // Reject obsolete fact input explicitly; never drop data silently.
    facts: Vec<IgnoredAny>,
    #[serde(default)]
    corrections: Vec<ChapterInput>,
    #[serde(default)]
    generation: u64,
    #[serde(default = "enabled")]
    enabled: bool,
}
fn parse_projection(json: &str) -> Result<UserProjection> {
    let value: UserProjection =
        serde_json::from_str(json).map_err(|_| ReaderError::InvalidSettings)?;
    if !value.facts.is_empty() {
        return Err(ReaderError::InvalidSettings);
    }
    Ok(value)
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
struct OpenedInput {
    content_key: String,
    updated: i64,
    preferred: Option<String>,
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
    db.execute_batch(&format!("CREATE TEMP TABLE user_opened(content_key TEXT PRIMARY KEY,opened_ms INTEGER,preferred_file_id TEXT);
    CREATE TEMP TABLE user_positions(content_key TEXT PRIMARY KEY,position_utf8 INTEGER,last_read INTEGER,recent_visible INTEGER,preferred_file_id TEXT);
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
    CREATE TEMP TABLE reading_activity(id TEXT PRIMARY KEY,session_id TEXT,book_id TEXT,content_key TEXT,title TEXT,device_id TEXT,started_ms INTEGER,ended_ms INTEGER,local_day INTEGER,utc_offset_seconds INTEGER,preview INTEGER,first_exposure_start,visit_id TEXT,deleted INTEGER DEFAULT 0,exposure_slot INTEGER);", source_order = crate::library::bookshelf::PREFERRED_SOURCE_ORDER))?;
    Ok(())
}
struct FactRow<'a> {
    content_key: &'a str,
    data: &'a FactData,
}

fn apply(db: &mut Connection, value: &UserProjection, facts: &[FactRow<'_>]) -> Result<Vec<bool>> {
    let tx = db.transaction()?;
    tx.execute_batch("DELETE FROM user_positions; DELETE FROM user_opened; DELETE FROM book_metadata; DELETE FROM chapter_overrides; DELETE FROM reading_activity;")?;
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
    for o in &value.opened {
        tx.execute("INSERT INTO user_opened VALUES(?1,?2,?3) ON CONFLICT(content_key) DO UPDATE SET opened_ms=max(opened_ms,excluded.opened_ms),preferred_file_id=CASE WHEN excluded.opened_ms>=opened_ms THEN excluded.preferred_file_id ELSE preferred_file_id END",
            params![o.content_key, o.updated, o.preferred])?;
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
    let mut inserted = Vec::with_capacity(facts.len());
    for (slot, f) in facts.iter().enumerate() {
        let s = &f.data.slice;
        let id: Option<String> = tx
            .query_row(
                "SELECT id FROM main.books WHERE content_sha256=?1",
                [&f.content_key],
                |r| r.get(0),
            )
            .optional()?;
        let first = f.data.exposures.first().map_or(0, |e| e.start_utf8);
        // Legacy json_extract uses a SQLite Real outside signed range. Keep
        // that type so only the activity detail read fails, not the snapshot.
        let first = i64::try_from(first).map_or_else(|_| Value::Real(first as f64), Value::Integer);
        let exposure_slot = if f.data.exposures.is_empty() {
            None
        } else {
            Some(i64::try_from(slot).map_err(|_| ReaderError::InvalidRange)?)
        };
        let count = tx.execute(
            "INSERT OR IGNORE INTO reading_activity VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,0,?14)",
            params![s.id,s.session_id,id,f.content_key,f.data.title,f.data.device,s.started_ms,s.ended_ms,s.local_day,s.utc_offset_seconds,s.preview,first,s.visit_id,exposure_slot],
        )?;
        inserted.push(count != 0);
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
    Ok(inserted)
}
#[uniffi::export]
impl ReaderCore {
    /// A query owns its complete user input. It never changes the core's shared
    /// connections; subsequent queries cannot alter this snapshot or its jobs.
    pub fn query_snapshot(&self, json: String) -> Result<Arc<ReaderQuery>> {
        let value = parse_projection(&json)?;
        self.snapshot_with_projection(&value, &[], FactGeometry::Full)
    }

    /// A non-fact projection plus Swift's store-local winners, already
    /// filtered by date, in formal then pending order.
    pub fn query_snapshot_with_facts(
        &self,
        non_fact_json: String,
        formal: Option<FactQuerySelection>,
        pending: Option<FactQuerySelection>,
        geometry: FactGeometry,
    ) -> Result<Arc<ReaderQuery>> {
        let value = parse_projection(&non_fact_json)?;
        let mut rows = Vec::new();
        for selection in [&formal, &pending].into_iter().flatten() {
            selection.try_each(|item| {
                rows.push(FactRow {
                    content_key: &item.content_key,
                    data: &item.fact.data,
                });
            })?;
        }
        self.snapshot_with_projection(&value, &rows, geometry)
    }

    /// Keep the details' complete records for selected books and fill in
    /// timestamps for the remaining descendants from the index pass.
    pub fn query_snapshot_with_directory_activity(
        &self,
        json: String,
        activity: Arc<ReaderQuery>,
    ) -> Result<Arc<ReaderQuery>> {
        let mut value = parse_projection(&json)?;
        {
            let db = activity.core.read_lock()?;
            let mut positions = db.prepare("SELECT content_key,last_read FROM user_positions")?;
            let mut opened = db
                .prepare("SELECT content_key,opened_ms FROM user_opened")?
                .query_map([], |r| {
                    Ok(OpenedInput {
                        content_key: r.get(0)?,
                        updated: r.get(1)?,
                        preferred: None,
                    })
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            let mut ranks = positions
                .query_map([], |r| {
                    Ok(PositionInput {
                        content_key: r.get(0)?,
                        offset: 0,
                        updated: r.get(1)?,
                        visible: true,
                        preferred: None,
                    })
                })?
                .collect::<std::result::Result<Vec<_>, _>>()?;
            let detailed: HashSet<_> = value
                .positions
                .iter()
                .map(|row| row.content_key.as_str())
                .collect();
            ranks.retain(|row| !detailed.contains(row.content_key.as_str()));
            let detailed: HashSet<_> = value
                .opened
                .iter()
                .map(|row| row.content_key.as_str())
                .collect();
            opened.retain(|row| !detailed.contains(row.content_key.as_str()));
            value.positions.extend(ranks);
            value.opened.extend(opened);
        }
        self.snapshot_with_projection(&value, &[], FactGeometry::Full)
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

impl ReaderCore {
    fn snapshot_with_projection(
        &self,
        value: &UserProjection,
        facts: &[FactRow<'_>],
        geometry: FactGeometry,
    ) -> Result<Arc<ReaderQuery>> {
        let open = || -> Result<(Connection, Vec<bool>)> {
            let mut db = Connection::open(&self.database_path)?;
            db.busy_timeout(std::time::Duration::from_secs(5))?;
            db.execute_batch("PRAGMA foreign_keys=ON;")?;
            initialize(&db)?;
            let inserted = apply(&mut db, value, facts)?;
            db.execute_batch("PRAGMA query_only=ON;")?;
            Ok((db, inserted))
        };
        let (db, db_inserted) = open()?;
        let (reader, reader_inserted) = open()?;
        // The slot is the input index in both connections. Retain only if at
        // least one connection inserted that input. No entire prepared object
        // or consumed fact (title, key, etc.) is retained by a query.
        let exposures = facts
            .iter()
            .zip(db_inserted.into_iter().zip(reader_inserted))
            .map(|(row, (in_db, in_reader))| {
                if !(in_db || in_reader) {
                    return None;
                }
                let first = row.data.exposures.first()?;
                Some(match geometry {
                    FactGeometry::Full => ExposureSlot::Full(row.data.exposures.clone()),
                    FactGeometry::FirstExposure => ExposureSlot::First(first.clone()),
                })
            })
            .collect();
        Ok(Arc::new(ReaderQuery {
            core: ReaderCore {
                db: Mutex::new(db),
                reader: Mutex::new(reader),
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
            exposures,
        }))
    }
}

pub(crate) enum ExposureSlot {
    Full(Arc<[ReadingExposure]>),
    First(ReadingExposure),
}

impl ExposureSlot {
    pub(crate) fn values(&self) -> &[ReadingExposure] {
        match self {
            Self::Full(exposures) => exposures,
            Self::First(exposure) => std::slice::from_ref(exposure),
        }
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
#[derive(uniffi::Object)]
pub struct ReaderQuery {
    core: ReaderCore,
    exposures: Box<[Option<ExposureSlot>]>,
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
    pub fn display_text_range(
        &self,
        book_id: String,
        start_utf8: u64,
        end_utf8: u64,
        indent: ReadingIndent,
    ) -> Result<TextRange> {
        self.core
            .display_text_range(book_id, start_utf8, end_utf8, indent)
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
    pub fn chapter_structure(&self, book_id: String) -> Result<ChapterOutline> {
        self.core.chapter_structure(book_id)
    }
    pub fn chapter_outline(&self, book_id: String) -> Result<ChapterOutline> {
        self.core.chapter_outline(book_id, &self.exposures)
    }
    pub fn reading_location(&self, book_id: String, percentage: f64) -> Result<ReadingLocation> {
        self.core.reading_location(book_id, percentage)
    }
    pub fn reading_continuation(
        &self,
        book_id: String,
        local_offset: u64,
        winning_offset: u64,
    ) -> Result<Option<ReadingContinuation>> {
        self.core
            .reading_continuation(book_id, local_offset, winning_offset)
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
    pub fn book_details(&self, target: BookTarget) -> Result<BookDetailsResult> {
        self.core.book_details(target)
    }
    pub fn metadata_has_reading_position(&self, content_sha256: String) -> Result<bool> {
        crate::parse_sha256(content_sha256.clone())?;
        let db = self.core.read_lock()?;
        crate::reading::book_details::has_reading_position(&db, &content_sha256)
    }
    pub fn metadata_exchange_read(
        &self,
        request: crate::MetadataExchangeRequest,
        inventory: Arc<crate::MetadataExchangeInventory>,
    ) -> Result<Option<crate::MetadataExchangeRead>> {
        self.core.metadata_exchange_read(request, inventory)
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
    pub fn library_directory_cards(
        &self,
        shelf_id: String,
        parent_path: String,
        sort: LibrarySort,
    ) -> Result<Vec<LibraryEntry>> {
        self.core
            .library_directory_cards(shelf_id, parent_path, sort)
    }
    pub fn library_directory_detail_keys(
        &self,
        shelf_id: String,
        parent_path: String,
    ) -> Result<crate::LibraryDirectoryDetailKeys> {
        self.core
            .library_directory_detail_keys(shelf_id, parent_path)
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
    pub fn all_library_book_cards(&self, shelf_id: String) -> Result<Vec<LibraryEntry>> {
        self.core.all_library_book_cards(shelf_id)
    }
    pub fn all_library_tag_cards(&self, shelf_id: String) -> Result<crate::LibraryTaggedCards> {
        self.core.all_library_tag_cards(shelf_id)
    }
    pub fn library_search_matches(
        &self,
        scope: crate::CatalogueScope,
        books_only: bool,
    ) -> Result<Vec<LibrarySearchCandidate>> {
        self.core.library_search_matches(scope, books_only)
    }
    pub fn library_search_detail_keys(
        &self,
        file_ids: Vec<String>,
    ) -> Result<crate::LibraryDirectoryDetailKeys> {
        self.core.library_search_detail_keys(file_ids)
    }
    pub fn library_search_cards(&self, file_ids: Vec<String>) -> Result<Vec<LibraryEntry>> {
        self.core.library_search_cards(file_ids)
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
    pub fn book_information_source(&self, target: BookTarget) -> Result<Option<LibraryEntry>> {
        self.core.book_information_source(target)
    }
    pub fn recent_library_ranking(&self, limit: u32) -> Result<Arc<crate::RecentLibraryRanking>> {
        self.core.recent_library_ranking(limit)
    }
    pub fn recent_library_ranking_matches(
        &self,
        ranking: Arc<crate::RecentLibraryRanking>,
    ) -> Result<bool> {
        self.core.recent_library_ranking_matches(&ranking)
    }
    pub fn hydrate_recent_library_cards(
        &self,
        ranking: Arc<crate::RecentLibraryRanking>,
    ) -> Result<Option<Vec<LibraryEntry>>> {
        self.core.hydrate_recent_library(&ranking, true)
    }
    pub fn recent_library_entries(&self, limit: u32) -> Result<Vec<LibraryEntry>> {
        self.core.recent_library_entries(limit)
    }
    pub fn statistics_overview(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<ReadingKey>,
    ) -> Result<StatisticsOverview> {
        self.core
            .statistics_overview(first_day, last_day, content_key.map(serialize_reading_key))
    }
    pub fn statistics_widget_summary(
        &self,
        today: i64,
        week_start: i64,
    ) -> Result<StatisticsWidgetSummary> {
        self.core.statistics_widget_summary(today, week_start)
    }
    pub fn reading_activities(
        &self,
        first_day: i64,
        last_day: i64,
        content_key: Option<ReadingKey>,
    ) -> Result<Vec<ReadingActivity>> {
        self.core
            .reading_activities(first_day, last_day, content_key.map(serialize_reading_key))
    }
}

#[cfg(test)]
mod fact_snapshot_tests {
    use super::*;
    use crate::user::reading_fact::tests::{payload, pick};

    #[test]
    fn exposure_slots_survive_input_release_and_keep_snapshots_isolated() -> Result<()> {
        let root = tempfile::tempdir()?;
        let core = ReaderCore::new(root.path().to_string_lossy().into())?;
        let book = core.create_sample_book()?;
        let key = serialize_reading_key(book.reading_key.clone());
        let first = r#"{"start_utf8":16,"end_utf8":32,"duration_ms":3000}"#;
        let second = r#"{"start_utf8":200,"end_utf8":250,"duration_ms":3000}"#;
        let full = format!("[{first},{second}]");
        let wide = r#"[{"start_utf8":18446744073709551615,"end_utf8":32,"duration_ms":3000}]"#;
        let prepare = |base, rows: Vec<String>| -> Result<Arc<PreparedReadingFacts>> {
            let count = rows.len() as u64;
            let batch = decode_fact_batch(base, rows)?;
            let picks = (base..base + count)
                .map(|ordinal| pick(&batch, ordinal, &key))
                .collect();
            seal_prepared_facts(vec![FactBatchSelection { batch, picks }])
        };
        let formal = prepare(
            0,
            vec![payload("winner", 12, &full), payload("empty", 13, "[]")],
        )?;
        let pending = prepare(
            0,
            vec![
                payload("winner", 12, &format!("[{second}]")),
                payload("wide", 14, wide),
            ],
        )?;
        let selected = Arc::downgrade(&formal.selected[0].fact.data.exposures);
        let ignored = Arc::downgrade(&pending.selected[0].fact.data.exposures);
        let choose = |prepared: Arc<PreparedReadingFacts>, indices| FactQuerySelection {
            prepared_id: prepared.prepared_id(),
            prepared,
            indices,
        };
        // A formal candidate omitted by Swift's clear/date rules must not
        // hide the selected pending fact with the same ID.
        let pending_only = core.query_snapshot_with_facts(
            "{}".into(),
            Some(choose(formal.clone(), Some(vec![]))),
            Some(choose(pending.clone(), Some(vec![0]))),
            FactGeometry::FirstExposure,
        )?;
        let pending_activities = pending_only.reading_activities(12, 14, None)?;
        assert_eq!(pending_activities.len(), 1);
        assert_eq!(pending_activities[0].start_utf8, 200);

        let all = core.query_snapshot_with_facts(
            "{}".into(),
            Some(choose(formal.clone(), None)),
            Some(choose(pending, None)),
            FactGeometry::Full,
        )?;
        assert!(ignored.upgrade().is_none());

        let first_only = core.query_snapshot_with_facts(
            "{}".into(),
            Some(choose(formal, Some(vec![0]))),
            None,
            FactGeometry::FirstExposure,
        )?;
        let slots = |db: &Connection| -> rusqlite::Result<Vec<(String, Option<i64>)>> {
            db.prepare("SELECT id,exposure_slot FROM reading_activity ORDER BY id")?
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect()
        };
        let expected = [
            ("empty".into(), None),
            ("wide".into(), Some(3)),
            ("winner".into(), Some(0)),
        ];
        assert_eq!(slots(&all.core.db.lock().unwrap())?, expected);
        assert_eq!(slots(&all.core.reader.lock().unwrap())?, expected);
        assert!(selected.upgrade().is_some());

        // The two immutable queries can read on separate threads; a newer
        // first-exposure projection cannot replace the older complete geometry.
        std::thread::scope(|scope| -> Result<()> {
            let read_old = scope.spawn(|| all.chapter_outline(book.id.clone()));
            let read_new = scope.spawn(|| first_only.chapter_outline(book.id.clone()));
            assert_eq!(
                read_old.join().unwrap()?.items[0].covered_characters,
                Some(17)
            );
            assert_eq!(
                read_new.join().unwrap()?.items[0].covered_characters,
                Some(0)
            );
            Ok(())
        })?;
        assert_eq!(
            all.statistics_overview(12, 14, None)?.total_duration_ms,
            9000
        );
        assert_eq!(all.reading_activities(12, 12, None)?[0].start_utf8, 16);
        assert_eq!(all.reading_activities(13, 13, None)?[0].start_utf8, 0);
        assert!(matches!(
            all.reading_activities(14, 14, None),
            Err(ReaderError::Storage { message }) if message.contains("Invalid column type Real")
        ));
        drop(all);
        assert!(selected.upgrade().is_none());
        assert_eq!(
            first_only.reading_activities(12, 12, None)?[0].start_utf8,
            16
        );
        Ok(())
    }
}
