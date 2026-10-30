//! ReaderCore ownership and public text/cache entry points.
use crate::*;
use encoding_rs::UTF_8;
use rusqlite::Connection;
use rusqlite::OptionalExtension;
use rusqlite::params;
use std::collections::HashMap;
use std::fs::File;
use std::io::Cursor;
use std::io::Seek;
use std::io::SeekFrom;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::MutexGuard;
#[derive(Clone, Debug, uniffi::Record)]
pub struct BookInfo {
    pub id: String,
    pub title: String,
    /// SHA-256 of normalization-v1 UTF-8, not the original file's bytes.
    pub content_sha256: String,
    pub encoding: String,
    pub byte_count: u64,
    pub chunk_count: u32,
    pub position_utf8: u64,
}

#[derive(Debug, uniffi::Record)]
pub struct TextChunk {
    pub index: u32,
    pub start_utf8: u64,
    pub end_utf8: u64,
    pub text: String,
}

/// Raw bytes plus the requested decoding policy, never a file identity.
#[derive(Clone, Debug, uniffi::Record)]
pub struct SourceContentKey {
    pub raw_sha256: String,
    pub decoding: String,
}

#[derive(uniffi::Object)]
pub struct ReaderCore {
    pub(crate) db: Mutex<Connection>,
    pub(crate) reader: Mutex<Connection>,
    pub(crate) imports: Mutex<HashMap<String, std::sync::Weak<ImportControl>>>,
    pub(crate) import_failures: Mutex<HashMap<String, crate::reading::progressive::ImportFailure>>,
    pub(crate) database_path: std::path::PathBuf,
}

#[uniffi::export]
impl ReaderCore {
    #[uniffi::constructor]
    pub fn new(data_directory: String) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&data_directory)?;
        let database_path = Path::new(&data_directory).join("reader.sqlite3");
        let mut db = Connection::open(&database_path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")?;
        crate::storage::migrations::initialize(&mut db)?;
        crate::user::projection::initialize(&db)?;
        crate::reading::progressive::recover(&mut db)?;
        let reader = Connection::open(&database_path)?;
        reader.busy_timeout(std::time::Duration::from_secs(5))?;
        reader.execute_batch("PRAGMA foreign_keys=ON;")?;
        crate::user::projection::initialize(&reader)?;
        Ok(Arc::new(Self {
            db: Mutex::new(db),
            reader: Mutex::new(reader),
            imports: Mutex::new(HashMap::new()),
            import_failures: Mutex::new(HashMap::new()),
            database_path,
        }))
    }

    /// Call synchronously while the platform holds coordinated, authorized access.
    /// Import is transactional; originals are never modified and no external paths persist.
    pub fn import_book(&self, file_path: String, title: String) -> Result<ImportText> {
        let mut file = File::open(file_path)?;
        let encoding = crate::reading::text::detect_encoding(&mut file)?;
        file.seek(SeekFrom::Start(0))?;
        self.ingest(&mut file, title, encoding).map(Into::into)
    }

    /// The caller hashes the coordinated source before consulting this cache.
    pub fn source_book(&self, key: SourceContentKey) -> Result<Option<ImportText>> {
        if !valid_source_key(&key) {
            return Err(ReaderError::InvalidSettings);
        }
        Ok(self.lock()?.query_row(
            "SELECT b.id,b.title,b.content_sha256,b.encoding,b.byte_count,b.chunk_count,b.position_utf8 FROM source_imports s JOIN reading_books b ON b.id=s.book_id WHERE s.raw_sha256=?1 AND s.decoding=?2 AND b.content_sha256 NOT LIKE 'pending:%'",
            params![key.raw_sha256,decoding_policy(&key.decoding)?],book_row).optional()?.map(Into::into))
    }

    pub fn create_sample_book(&self) -> Result<ImportText> {
        // Explicit synthetic content only; no bundled personal novel.
        let mut sample = String::from(
            "月读技术样机 · 示例文本\n\n这是一份程序生成的排版测试文本，不是小说作品。\n\n",
        );
        for index in 1..=180 {
            sample.push_str(&format!("第 {index} 章 · 月下试读\n月光落在窗边，书页安静地展开。这一段用于检查中文标点、换行和阅读位置恢复。调整字号，切换滚动与分页，再返回同一处文字。\nMixed text: Moonread 123 — emoji 🌙📚👨‍👩‍👧‍👦 and café e\u{301}.\n\n"));
        }
        let book = self.ingest(&mut Cursor::new(sample), "月读 · 排版示例".into(), UTF_8)?;
        Ok(book.into())
    }

    pub fn text_id_for_sha(&self, sha: String) -> Result<String> {
        parse_sha256(sha.clone())?;
        self.lock()?
            .query_row("SELECT id FROM books WHERE content_sha256=?1", [sha], |r| {
                r.get(0)
            })
            .map_err(Into::into)
    }

    pub fn read_chunk(&self, book_id: String, index: u32) -> Result<TextChunk> {
        chunk(&*self.lock()?, &book_id, index)
    }

    /// EOF maps to the last chunk. Offsets past EOF are clamped.
    pub fn find_chunk(&self, book_id: String, offset_utf8: u64) -> Result<u32> {
        let db = self.lock()?;
        let info = book(&db, &book_id)?;
        chunk_index(&db, &book_id, offset_utf8.min(info.byte_count))
    }
}

impl ReaderCore {
    pub(crate) fn lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.db.lock().map_err(|_| ReaderError::Storage {
            message: "存储锁不可用，请重新打开应用".into(),
        })
    }
}
impl ReaderCore {
    pub(crate) fn book_info(&self, book_id: String) -> Result<BookInfo> {
        book(&*self.lock()?, &book_id)
    }
    /// Return the latest recognized heading at or before a normalized UTF-8 offset.
    /// Read the persisted index produced alongside normalized text ingestion.
    pub(crate) fn chapter_at(
        &self,
        book_id: String,
        offset_utf8: u64,
    ) -> Result<Option<ChapterInfo>> {
        let db = self.reader.lock().map_err(|_| ReaderError::ImportBusy)?;
        let id = crate::library::tools::content_key(&db, &book_id)?;
        crate::library::tools::chapter(&db, &id, offset_utf8)
    }
}

impl ReaderCore {
    pub(crate) fn read_lock(&self) -> Result<MutexGuard<'_, Connection>> {
        self.reader.lock().map_err(|_| ReaderError::Storage {
            message: "读取连接不可用".into(),
        })
    }
}
