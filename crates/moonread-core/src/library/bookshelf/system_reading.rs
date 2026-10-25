//! Metadata-only system projection. Identity, representative copies, recent order,
//! natural order and percentages stay with their existing Rust owners.
use super::*;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, uniffi::Record)]
pub struct SystemReadingBookProjection {
    pub content_sha256: String,
    pub title: String,
    pub author: Option<String>,
    pub tags: Vec<String>,
    pub source_shelf_ids: Vec<String>,
    pub source_count: u64,
    pub needs_download: bool,
    pub percentage: Option<f64>,
    pub chapter_title: Option<String>,
    pub recent_rank: Option<u32>,
    pub natural_order_ordinal: u64,
}

impl ReaderCore {
    pub(crate) fn system_reading_catalogue(&self) -> Result<Vec<SystemReadingBookProjection>> {
        let recent: HashMap<_, _> = self
            .recent_library_entries(1000)?
            .into_iter()
            .enumerate()
            .filter_map(|(i, e)| Some((e.content_sha256?, i as u32)))
            .collect();
        let db = self.read_lock()?;
        let mut statement =
            db.prepare("SELECT file_id FROM ranked_library_sources WHERE source_rank=1")?;
        let chosen: HashSet<String> = statement
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?;
        let mut files = entries(&db, None, None, true)?;
        files.sort_by(crate::library::order::file_order);
        let mut sources: HashMap<String, Vec<String>> = HashMap::new();
        for e in &files {
            if let Some(sha) = &e.content_sha256 {
                sources
                    .entry(sha.clone())
                    .or_default()
                    .push(e.shelf_id.clone());
            }
        }
        Ok(files
            .into_iter()
            .enumerate()
            .filter_map(|(ordinal, e)| {
                let sha = e.content_sha256?;
                if !crate::valid_sha(&sha) || !chosen.contains(&e.id) {
                    return None;
                }
                let mut shelves = sources.remove(&sha).unwrap_or_default();
                let source_count = shelves.len() as u64;
                shelves.sort();
                shelves.dedup();
                let metadata = e.metadata;
                Some(SystemReadingBookProjection {
                    title: std::path::Path::new(&e.name)
                        .file_stem()?
                        .to_string_lossy()
                        .into_owned(),
                    author: metadata
                        .as_ref()
                        .map(|m| m.author.clone())
                        .filter(|s| !s.is_empty()),
                    tags: metadata.map(|m| m.tags).unwrap_or_default(),
                    source_shelf_ids: shelves,
                    source_count,
                    needs_download: e.needs_download,
                    percentage: (e.byte_count > 0 && e.last_read > 0).then(|| {
                        crate::reading::navigation::reading_percentage(
                            e.position_utf8,
                            e.byte_count,
                        )
                    }),
                    chapter_title: e.chapter_title,
                    recent_rank: recent.get(&sha).copied(),
                    content_sha256: sha,
                    natural_order_ordinal: ordinal as u64,
                })
            })
            .collect())
    }

    pub(crate) fn system_reading_sources(&self, sha: String) -> Result<Vec<LibraryEntry>> {
        crate::parse_sha256(sha.clone())?;
        let db = self.read_lock()?;
        let mut statement = db.prepare(
            "SELECT file_id,source_rank FROM ranked_library_sources WHERE content_sha256=?1",
        )?;
        let ranks: HashMap<String, u64> = statement
            .query_map([&sha], |r| Ok((r.get(0)?, r.get::<_, i64>(1)? as u64)))?
            .collect::<std::result::Result<_, _>>()?;
        let mut sources = filtered_entries(&db, None, None, true, None, None, Some(&sha))?;
        sources.retain(|e| ranks.contains_key(&e.id));
        sources.sort_by_key(|e| ranks[&e.id]);
        Ok(sources)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn catalog_publishes_only_verified_identities_and_reuses_source_recent_and_progress_rules() {
        let dir = tempfile::tempdir().unwrap();
        let core = ReaderCore::new(dir.path().join("cache").to_string_lossy().into()).unwrap();
        for id in ["s", "other"] {
            core.save_library_shelf(id.into(), id.into(), vec![], "local".into(), false)
                .unwrap();
        }
        let sha = "a".repeat(64);
        {
            let db = core.lock().unwrap();
            db.execute_batch("INSERT INTO library_files VALUES('a','s','副本.txt','','副本.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('b','other','第2本.txt','','第2本.txt',0,100,1,1,NULL,'auto');
                INSERT INTO library_files VALUES('unknown','s','未知.txt','','未知.txt',0,100,1,0,NULL,'auto');
                INSERT INTO library_files VALUES('stale','s','过期.txt','','过期.txt',0,101,1,0,NULL,'auto');
                INSERT INTO library_identities VALUES('a','raw','auto',100,1);
                INSERT INTO library_identities VALUES('b','raw','auto',100,1);
                INSERT INTO library_identities VALUES('stale','stale-raw','auto',100,1);").unwrap();
            db.execute(
                "INSERT INTO source_identities VALUES('raw','auto',?1,'UTF-8',100,80)",
                [&sha],
            )
            .unwrap();
            db.execute(
                "INSERT INTO source_identities VALUES('stale-raw','auto',?1,'UTF-8',100,80)",
                ["b".repeat(64)],
            )
            .unwrap();
        }
        {
            let db = core.read_lock().unwrap();
            db.execute(
                "INSERT INTO user_positions VALUES(?1,50,20,NULL,'b')",
                [&sha],
            )
            .unwrap();
            db.execute("INSERT INTO book_metadata VALUES(?1,?2)", params![sha,
                serde_json::json!({"sha":sha,"author":"合成作者","synopsis":"not published","tags":["合成标签"],"cover":null,"status":"Reading"}).to_string()]).unwrap();
        }
        let books = core.system_reading_catalogue().unwrap();
        assert_eq!(books.len(), 1);
        let book = &books[0];
        assert_eq!(book.title, "第2本");
        assert_eq!(book.content_sha256, sha);
        assert_eq!(book.source_count, 2);
        assert_eq!(book.source_shelf_ids, ["other", "s"]);
        assert_eq!(book.author.as_deref(), Some("合成作者"));
        assert_eq!(book.tags, ["合成标签"]);
        assert_eq!(book.percentage, Some(50.0));
        assert_eq!(book.recent_rank, Some(0));
        assert!(book.needs_download);
        let sources = core.system_reading_sources(sha.clone()).unwrap();
        assert_eq!(sources[0].id, core.recent_library_entries(1).unwrap()[0].id);
        assert_eq!(
            sources.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            ["b", "a"]
        );
        // A rename retains the identity; no file contents are opened by any query.
        core.lock().unwrap().execute("UPDATE library_files SET name='第3本.txt',relative_path='moved/第3本.txt' WHERE id='b'", []).unwrap();
        assert_eq!(
            core.system_reading_catalogue().unwrap()[0].content_sha256,
            sha
        );
        core.lock()
            .unwrap()
            .execute("DELETE FROM library_files WHERE id IN ('a','b')", [])
            .unwrap();
        assert!(core.system_reading_catalogue().unwrap().is_empty());
    }
}
