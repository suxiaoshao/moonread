CREATE TABLE source_identities (
 raw_sha256 TEXT NOT NULL, decoding TEXT NOT NULL, content_sha256 TEXT NOT NULL,
 encoding TEXT NOT NULL, utf8_bytes INTEGER NOT NULL, char_count INTEGER NOT NULL,
 PRIMARY KEY(raw_sha256,decoding)
);
-- Scans remove identities for file IDs that no longer exist.
CREATE TABLE library_identities (
 file_id TEXT PRIMARY KEY, raw_sha256 TEXT NOT NULL, decoding TEXT NOT NULL,
 indexed_size INTEGER NOT NULL, indexed_modified INTEGER NOT NULL
);
