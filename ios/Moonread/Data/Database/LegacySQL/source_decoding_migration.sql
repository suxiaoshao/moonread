-- Upgrade-only work, never a second runtime preference or synced queue.
CREATE TABLE source_decoding_migration (
 file_id TEXT PRIMARY KEY, shelf_id TEXT NOT NULL, relative_path TEXT NOT NULL,
 size INTEGER NOT NULL, modified INTEGER NOT NULL, decoding TEXT NOT NULL,
 raw_sha256 TEXT
);
INSERT INTO source_decoding_migration
 SELECT f.id,f.shelf_id,f.relative_path,f.size,f.modified,f.decoding,
  CASE WHEN li.indexed_size=f.size AND li.indexed_modified=f.modified
   AND li.decoding=f.decoding AND si.raw_sha256 IS NOT NULL THEN li.raw_sha256 END
 FROM library_files f
 LEFT JOIN library_identities li ON li.file_id=f.id
 LEFT JOIN source_identities si ON si.raw_sha256=li.raw_sha256 AND si.decoding=li.decoding
 WHERE f.directory=0 AND f.decoding<>'auto';
