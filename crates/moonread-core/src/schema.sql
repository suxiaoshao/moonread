CREATE TABLE books (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, content_sha256 TEXT NOT NULL UNIQUE,
 encoding TEXT NOT NULL, byte_count INTEGER NOT NULL DEFAULT 0,
 chunk_count INTEGER NOT NULL DEFAULT 0, projection_revision INTEGER NOT NULL DEFAULT 0, projection_end INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE chunks (
 book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
 chunk_index INTEGER NOT NULL, start_utf8 INTEGER NOT NULL, end_utf8 INTEGER NOT NULL,
 text TEXT NOT NULL, start_char_count INTEGER NOT NULL, end_char_count INTEGER NOT NULL,
 PRIMARY KEY(book_id,chunk_index)
);
CREATE INDEX chunk_offsets ON chunks(book_id,start_utf8);
-- Confirmed whole blank paragraphs only; adjacent runs share one indexed range.
CREATE TABLE reading_blanks (
 book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
 start_utf8 INTEGER NOT NULL, end_utf8 INTEGER NOT NULL,
 PRIMARY KEY(book_id,start_utf8)
);
CREATE TABLE source_imports (
 raw_sha256 TEXT NOT NULL, decoding TEXT NOT NULL,
 book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
 PRIMARY KEY(raw_sha256,decoding)
);
CREATE INDEX source_imports_book ON source_imports(book_id);
CREATE TABLE import_jobs (
 book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
 phase TEXT NOT NULL DEFAULT 'paused', generation INTEGER NOT NULL DEFAULT 0,
 source_size INTEGER NOT NULL DEFAULT 0, bytes_read INTEGER NOT NULL DEFAULT 0,
 has_text INTEGER NOT NULL DEFAULT 0, error TEXT, final_sha TEXT,
 canonical_id TEXT REFERENCES books(id),
 expected_raw_sha256 TEXT, decoding TEXT, library_file_id TEXT
);
CREATE TABLE import_chapters (
 book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
 start_utf8 INTEGER NOT NULL, title TEXT NOT NULL, level INTEGER NOT NULL DEFAULT 1,
 start_char_count INTEGER NOT NULL, body_char_count INTEGER NOT NULL,
 PRIMARY KEY(book_id,start_utf8)
);
CREATE TABLE library_shelves (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, bookmark BLOB NOT NULL,
 location TEXT NOT NULL, builtin INTEGER NOT NULL DEFAULT 0, error TEXT
);
CREATE TABLE library_files (
 id TEXT PRIMARY KEY, shelf_id TEXT NOT NULL REFERENCES library_shelves(id) ON DELETE CASCADE,
 relative_path TEXT NOT NULL, parent_path TEXT NOT NULL, name TEXT NOT NULL,
 directory INTEGER NOT NULL,
 size INTEGER NOT NULL, modified INTEGER NOT NULL, needs_download INTEGER NOT NULL,
 book_id TEXT REFERENCES books(id), decoding TEXT NOT NULL DEFAULT 'auto', UNIQUE(shelf_id,relative_path)
);
CREATE INDEX library_children ON library_files(shelf_id,parent_path);
CREATE INDEX library_content ON library_files(book_id);
PRAGMA user_version=20;
