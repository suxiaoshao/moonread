-- v1: independent of the index schema. GRDB installs this in usr only.
CREATE TABLE usr.cover_asset (
 asset_id TEXT PRIMARY KEY NOT NULL, legacy_cover_id TEXT, bytes BLOB, expected_sha TEXT,
 availability TEXT NOT NULL CHECK (availability IN ('available','missing','invalid')),
 CHECK ((availability='available')=(bytes IS NOT NULL))
);
CREATE TABLE usr.metadata_text_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, logical_key TEXT NOT NULL, field TEXT NOT NULL CHECK(field IN ('author','synopsis','status')),
 device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL, value_text TEXT NOT NULL,
 PRIMARY KEY(partition,record_id), UNIQUE(partition,book_key,field,device_id)
);
CREATE INDEX usr.metadata_text_book ON metadata_text_candidate(book_key,field,updated_ms,token);
CREATE TABLE usr.tag_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, logical_key TEXT NOT NULL, member_key TEXT NOT NULL,
 device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL, tag_text TEXT, is_deleted INTEGER NOT NULL,
 CHECK(is_deleted IN (0,1) AND (is_deleted=1)=(tag_text IS NULL)),
 PRIMARY KEY(partition,record_id), UNIQUE(partition,book_key,member_key,device_id)
);
CREATE INDEX usr.tag_book ON tag_candidate(book_key,member_key);
CREATE TABLE usr.cover_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 is_empty INTEGER NOT NULL CHECK (is_empty IN (0,1)), asset_id TEXT REFERENCES cover_asset(asset_id),
 sha256 TEXT, format TEXT, width INTEGER, height INTEGER,
 CHECK ((is_empty=1 AND asset_id IS NULL AND sha256 IS NULL AND format IS NULL AND width IS NULL AND height IS NULL)
   OR (is_empty=0 AND asset_id IS NOT NULL AND sha256 IS NOT NULL AND format IS NOT NULL AND width IS NOT NULL AND height IS NOT NULL)),
 PRIMARY KEY(partition,record_id), UNIQUE(partition,book_key,device_id)
);
CREATE INDEX usr.cover_book ON cover_candidate(book_key,updated_ms,token);
CREATE TABLE usr.position_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 offset TEXT NOT NULL CHECK (length(offset)=20 AND offset NOT GLOB '*[^0-9]*' AND offset<='18446744073709551615'),
 device_id TEXT, source_kind TEXT, relative_path TEXT, file_name TEXT, byte_size INTEGER, decoding TEXT,
 PRIMARY KEY(partition,record_id)
);
CREATE INDEX usr.position_book ON position_candidate(book_key,updated_ms DESC,token DESC);
CREATE TABLE usr.opened_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 opened_ms INTEGER NOT NULL, PRIMARY KEY(partition,record_id), UNIQUE(partition,book_key,device_id)
);
CREATE INDEX usr.opened_book ON opened_candidate(book_key,updated_ms,token);
CREATE TABLE usr.chapter_override_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 offset TEXT NOT NULL CHECK (length(offset)=20 AND offset NOT GLOB '*[^0-9]*' AND offset<='18446744073709551615'),
 is_retracted INTEGER NOT NULL CHECK (is_retracted IN (0,1)), title TEXT, level INTEGER, excluded INTEGER CHECK (excluded IN (0,1)),
 CHECK ((is_retracted=1 AND title IS NULL AND level IS NULL AND excluded IS NULL)
   OR (is_retracted=0 AND title IS NOT NULL AND level IS NOT NULL AND excluded IS NOT NULL)),
 PRIMARY KEY(partition,record_id), UNIQUE(partition,book_key,offset,device_id)
);
CREATE INDEX usr.chapter_override_book ON chapter_override_candidate(book_key,offset);
CREATE TABLE usr.annotation_candidate (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, mark_id TEXT NOT NULL,
 created TEXT NOT NULL CHECK(length(created)=20 AND created NOT GLOB '*[^0-9]*' AND created<='18446744073709551615'),
 bookmark INTEGER NOT NULL CHECK(bookmark IN (0,1)), is_deleted INTEGER NOT NULL CHECK(is_deleted IN (0,1)),
 start TEXT CHECK (length(start)=20 AND start NOT GLOB '*[^0-9]*' AND start<='18446744073709551615'),
 end TEXT CHECK (length(end)=20 AND end NOT GLOB '*[^0-9]*' AND end<='18446744073709551615'),
 excerpt TEXT, note TEXT, merged_into TEXT,
 CHECK ((is_deleted=1 AND start IS NULL AND end IS NULL AND excerpt IS NULL AND note IS NULL)
   OR (is_deleted=0 AND start IS NOT NULL AND end IS NOT NULL AND excerpt IS NOT NULL AND note IS NOT NULL)),
 PRIMARY KEY(partition,record_id)
);
CREATE INDEX usr.annotation_mark ON annotation_candidate(book_key,mark_id);
CREATE INDEX usr.annotation_mark_lookup ON annotation_candidate(partition,mark_id,book_key);
CREATE INDEX usr.annotation_range ON annotation_candidate(book_key,start,end);
CREATE TABLE usr.annotation_ancestor (
 partition INTEGER NOT NULL, candidate_id TEXT NOT NULL, ancestor_id TEXT NOT NULL,
 PRIMARY KEY(partition,candidate_id,ancestor_id),
 FOREIGN KEY(partition,candidate_id) REFERENCES annotation_candidate(partition,record_id) ON DELETE CASCADE
);
CREATE INDEX usr.annotation_ancestor_reverse ON annotation_ancestor(partition,ancestor_id);
CREATE TABLE usr.annotation_related_mark (
 partition INTEGER NOT NULL, candidate_id TEXT NOT NULL, related_mark_id TEXT NOT NULL,
 PRIMARY KEY(partition,candidate_id,related_mark_id),
 FOREIGN KEY(partition,candidate_id) REFERENCES annotation_candidate(partition,record_id) ON DELETE CASCADE
);
CREATE INDEX usr.annotation_related_reverse ON annotation_related_mark(partition,related_mark_id);
CREATE TABLE usr.reading_fact (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), fact_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT NOT NULL, title_at_reading TEXT NOT NULL, device_id TEXT NOT NULL,
 session_id TEXT NOT NULL, visit_id TEXT NOT NULL,
 started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, local_day INTEGER NOT NULL, utc_offset_seconds INTEGER NOT NULL,
 preview INTEGER NOT NULL CHECK(preview IN (0,1)), duration_ms INTEGER NOT NULL,
 first_exposure_start TEXT CHECK(length(first_exposure_start)=20 AND first_exposure_start NOT GLOB '*[^0-9]*' AND first_exposure_start<='18446744073709551615'),
 derivation_version INTEGER NOT NULL, exposure_version INTEGER NOT NULL, exposures_text TEXT NOT NULL,
 PRIMARY KEY(partition,fact_id)
);
CREATE INDEX usr.fact_day_book ON reading_fact(local_day,book_key,fact_id);
CREATE INDEX usr.fact_book_session ON reading_fact(book_key,session_id,started_ms);
CREATE INDEX usr.fact_identity ON reading_fact(fact_id,partition);
CREATE TABLE usr.reading_segment (
 partition INTEGER NOT NULL CHECK(partition IN (0,1)), segment_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 owner_instance_id TEXT NOT NULL CHECK(length(owner_instance_id)>0), book_key TEXT NOT NULL,
 title_at_reading TEXT NOT NULL, device_id TEXT NOT NULL, session_id TEXT NOT NULL, visit_id TEXT NOT NULL,
 started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL CHECK(ended_ms>started_ms),
 local_day INTEGER NOT NULL, utc_offset_seconds INTEGER NOT NULL, preview INTEGER NOT NULL CHECK(preview IN (0,1)),
 revision TEXT NOT NULL CHECK(length(revision)=20 AND revision NOT GLOB '*[^0-9]*'
   AND revision BETWEEN '00000000000000000001' AND '18446744073709551615'),
 duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 1 AND 86400000),
 sealed INTEGER NOT NULL CHECK(sealed IN (0,1)),
 first_exposure_start TEXT NOT NULL CHECK(length(first_exposure_start)=20 AND first_exposure_start NOT GLOB '*[^0-9]*'
   AND first_exposure_start<='18446744073709551615'),
 exposure_version INTEGER NOT NULL,
 exposures_text TEXT NOT NULL CHECK(length(CAST(exposures_text AS BLOB)) BETWEEN 2 AND 262144),
 local_unsealed_owner TEXT CHECK(local_unsealed_owner IS NULL OR (sealed=0 AND local_unsealed_owner=owner_instance_id)),
 PRIMARY KEY(partition,segment_id)
);
CREATE INDEX usr.segment_identity ON reading_segment(segment_id,partition);
CREATE INDEX usr.segment_book_session ON reading_segment(book_key,session_id,started_ms);
CREATE INDEX usr.segment_local_unsealed ON reading_segment(local_unsealed_owner,partition,segment_id)
 WHERE local_unsealed_owner IS NOT NULL AND sealed=0;
CREATE TABLE usr.statistics_clear (
 partition INTEGER NOT NULL CHECK (partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 book_key TEXT, session_id TEXT, through_ms INTEGER NOT NULL,
 scope_kind TEXT NOT NULL DEFAULT 'range' CHECK(scope_kind IN ('range','captured')),
 CHECK(schema_version<>1 OR scope_kind='range'),
 PRIMARY KEY(partition,record_id)
);
CREATE INDEX usr.clear_scope ON statistics_clear(book_key,session_id,through_ms);
CREATE TABLE usr.statistics_clear_id (
 partition INTEGER NOT NULL, clear_id TEXT NOT NULL, fact_id TEXT NOT NULL,
 PRIMARY KEY(partition,clear_id,fact_id),
 FOREIGN KEY(partition,clear_id) REFERENCES statistics_clear(partition,record_id) ON DELETE CASCADE
);
CREATE INDEX usr.clear_id_reverse ON statistics_clear_id(partition,fact_id);
CREATE TABLE usr.statistics_clear_segment (
 partition INTEGER NOT NULL, clear_id TEXT NOT NULL, segment_id TEXT NOT NULL,
 observed_revision TEXT NOT NULL CHECK(length(observed_revision)=20 AND observed_revision NOT GLOB '*[^0-9]*'
   AND observed_revision BETWEEN '00000000000000000001' AND '18446744073709551615'),
 covered_through_ms INTEGER NOT NULL,
 PRIMARY KEY(partition,clear_id,segment_id),
 FOREIGN KEY(partition,clear_id) REFERENCES statistics_clear(partition,record_id) ON DELETE CASCADE
);
CREATE INDEX usr.clear_segment_reverse ON statistics_clear_segment(partition,segment_id,covered_through_ms);
CREATE TABLE usr.source_decoding_candidate (
 partition INTEGER NOT NULL CHECK(partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 raw_sha256 TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 decoding TEXT NOT NULL, PRIMARY KEY(partition,record_id), UNIQUE(partition,raw_sha256,device_id)
);
CREATE INDEX usr.source_decoding_raw ON source_decoding_candidate(raw_sha256,updated_ms,token);
CREATE TABLE usr.palette_candidate (
 partition INTEGER NOT NULL CHECK(partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 palette_id TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 payload_palette_id TEXT, name TEXT, appearance TEXT, custom INTEGER CHECK (custom IN (0,1)), is_deleted INTEGER NOT NULL CHECK (is_deleted IN (0,1)),
 CHECK ((is_deleted=1 AND name IS NULL AND appearance IS NULL AND custom IS NULL)
   OR (is_deleted=0 AND name IS NOT NULL AND appearance IS NOT NULL AND custom IS NOT NULL)),
 PRIMARY KEY(partition,record_id), UNIQUE(partition,palette_id,device_id)
);
CREATE TABLE usr.palette_color (
 partition INTEGER NOT NULL, candidate_id TEXT NOT NULL, contrast_kind INTEGER NOT NULL CHECK(contrast_kind IN (0,1)),
 color_role TEXT NOT NULL, rgb INTEGER NOT NULL CHECK (rgb BETWEEN 0 AND 16777215),
 PRIMARY KEY(partition,candidate_id,contrast_kind,color_role),
 FOREIGN KEY(partition,candidate_id) REFERENCES palette_candidate(partition,record_id) ON DELETE CASCADE
);
CREATE TABLE usr.shelf_reference_candidate (
 partition INTEGER NOT NULL CHECK(partition IN (0,1)), record_id TEXT NOT NULL, schema_version INTEGER NOT NULL,
 shelf_id TEXT NOT NULL, logical_key TEXT NOT NULL, device_id TEXT NOT NULL, updated_ms INTEGER NOT NULL, token TEXT NOT NULL,
 name TEXT NOT NULL, location_description TEXT NOT NULL, reference_version INTEGER NOT NULL,
 PRIMARY KEY(partition,record_id), UNIQUE(partition,shelf_id,device_id)
);

CREATE TABLE usr.quarantined_record (
 quarantine_id INTEGER PRIMARY KEY, partition INTEGER NOT NULL CHECK(partition IN (0,1)),
 source TEXT NOT NULL, source_id TEXT NOT NULL, source_type TEXT NOT NULL, record_id TEXT NOT NULL, schema_version INTEGER,
 book_key TEXT, mark_id TEXT, logical_key TEXT, session_id TEXT, device_id TEXT,
 raw_format TEXT NOT NULL, raw_bytes BLOB NOT NULL, digest TEXT NOT NULL, reason TEXT NOT NULL,
 completeness TEXT NOT NULL CHECK(completeness IN ('complete','incomplete')),
 UNIQUE(partition,source,source_id,source_type,record_id,digest,reason)
);
CREATE INDEX usr.quarantine_scope ON quarantined_record(source_type,book_key,mark_id,logical_key,session_id);
CREATE INDEX usr.quarantine_id ON quarantined_record(source_type,record_id,partition);
CREATE INDEX usr.quarantine_logical_key ON quarantined_record(logical_key);
CREATE TABLE usr.quarantine_asset (
 quarantine_id INTEGER NOT NULL REFERENCES quarantined_record(quarantine_id) ON DELETE CASCADE, field TEXT NOT NULL,
 bytes BLOB, digest TEXT, missing_reason TEXT,
 CHECK ((missing_reason IS NULL AND bytes IS NOT NULL AND digest IS NOT NULL)
     OR (missing_reason IS NOT NULL AND bytes IS NULL)),
 PRIMARY KEY(quarantine_id,field)
);
CREATE TABLE usr.cloud_record_state (
 zone TEXT NOT NULL, record_type TEXT NOT NULL, record_name TEXT NOT NULL, business_id TEXT NOT NULL,
 server_state TEXT NOT NULL, system_fields BLOB,
 PRIMARY KEY(zone,record_type,record_name)
);
CREATE TABLE usr.cloud_outbox (
 zone TEXT NOT NULL, record_type TEXT NOT NULL, record_name TEXT NOT NULL, business_id TEXT NOT NULL,
 intent TEXT NOT NULL CHECK(intent IN ('save','delete')), content_digest TEXT, generation INTEGER NOT NULL,
 after_type TEXT, after_name TEXT, after_digest TEXT,
 CHECK ((intent='save')=(content_digest IS NOT NULL)),
 CHECK ((after_type IS NULL AND after_name IS NULL AND after_digest IS NULL)
     OR (after_type IS NOT NULL AND after_name IS NOT NULL AND after_digest IS NOT NULL)),
 PRIMARY KEY(zone,record_type,record_name)
);
CREATE TABLE usr.cloud_engine_state (
 zone TEXT PRIMARY KEY NOT NULL, checkpoint BLOB, region_state TEXT NOT NULL
);
CREATE TABLE usr.legacy_import_state (
 source_id TEXT NOT NULL, partition INTEGER NOT NULL CHECK(partition IN (0,1)), source_model TEXT NOT NULL,
 fingerprint TEXT, imported_count INTEGER NOT NULL, completeness TEXT NOT NULL CHECK(completeness IN ('complete','incomplete')),
 import_version INTEGER NOT NULL, PRIMARY KEY(source_id,partition,source_model)
);
CREATE TABLE usr.local_data_state (
 state_key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL
);
CREATE TABLE usr.local_hidden_book (book_key TEXT PRIMARY KEY NOT NULL);
CREATE TABLE usr.local_preferred_file (book_key TEXT PRIMARY KEY NOT NULL, file_id TEXT NOT NULL);
CREATE TABLE usr.local_resume (
 book_key TEXT PRIMARY KEY NOT NULL, last_local_write_token TEXT,
 offset TEXT NOT NULL CHECK (length(offset)=20 AND offset NOT GLOB '*[^0-9]*' AND offset<='18446744073709551615')
);

-- Current business references are replaced explicitly by the domain writer.
-- Deferred NO ACTION permits candidate maintenance before settlement, while
-- still rejecting an orphan reference at commit.
CREATE TABLE usr.reading_current (
 book_key TEXT PRIMARY KEY NOT NULL,
 position_partition INTEGER, position_id TEXT, position_updated_ms INTEGER,
 opened_partition INTEGER, opened_id TEXT, opened_ms INTEGER, recent_ms INTEGER NOT NULL,
 CHECK ((position_id IS NULL)=(position_partition IS NULL) AND (position_id IS NULL)=(position_updated_ms IS NULL)),
 CHECK ((opened_id IS NULL)=(opened_partition IS NULL) AND (opened_id IS NULL)=(opened_ms IS NULL)),
 CHECK (position_id IS NOT NULL OR opened_id IS NOT NULL),
 CHECK (recent_ms=coalesce(opened_ms,position_updated_ms)),
 FOREIGN KEY(position_partition,position_id) REFERENCES position_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(opened_partition,opened_id) REFERENCES opened_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX usr.reading_current_recent ON reading_current(recent_ms DESC,book_key);
-- Resume compares the local baseline with the formal store's own winner.
-- The shared reading row can be absent or point into the pending store.
CREATE TABLE usr.formal_position_current (
 book_key TEXT PRIMARY KEY NOT NULL,
 position_partition INTEGER NOT NULL DEFAULT 0 CHECK (position_partition=0),
 position_id TEXT NOT NULL,
 FOREIGN KEY(position_partition,position_id) REFERENCES position_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.metadata_current (
 book_key TEXT PRIMARY KEY NOT NULL,
 source_partition INTEGER NOT NULL CHECK(source_partition IN (0,1)),
 author_id TEXT, synopsis_id TEXT, status_id TEXT, cover_id TEXT,
 FOREIGN KEY(source_partition,author_id) REFERENCES metadata_text_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(source_partition,synopsis_id) REFERENCES metadata_text_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(source_partition,status_id) REFERENCES metadata_text_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(source_partition,cover_id) REFERENCES cover_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.tag_current (
 book_key TEXT NOT NULL, member_key TEXT NOT NULL, source_partition INTEGER NOT NULL, candidate_id TEXT NOT NULL,
 PRIMARY KEY(book_key,member_key),
 FOREIGN KEY(book_key) REFERENCES metadata_current(book_key) DEFERRABLE INITIALLY DEFERRED,
 FOREIGN KEY(source_partition,candidate_id) REFERENCES tag_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.chapter_override_current (
 book_key TEXT NOT NULL, offset TEXT NOT NULL CHECK(length(offset)=20 AND offset NOT GLOB '*[^0-9]*' AND offset<='18446744073709551615'),
 source_partition INTEGER NOT NULL, candidate_id TEXT NOT NULL, PRIMARY KEY(book_key,offset),
 FOREIGN KEY(source_partition,candidate_id) REFERENCES chapter_override_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.annotation_current_head (
 partition INTEGER NOT NULL, book_key TEXT NOT NULL, mark_id TEXT NOT NULL, candidate_id TEXT NOT NULL,
 PRIMARY KEY(partition,book_key,mark_id,candidate_id),
 FOREIGN KEY(partition,candidate_id) REFERENCES annotation_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX usr.annotation_current_lookup ON annotation_current_head(mark_id,partition,book_key);
CREATE TABLE usr.source_decoding_current (
 raw_sha256 TEXT PRIMARY KEY NOT NULL, source_partition INTEGER NOT NULL, candidate_id TEXT NOT NULL,
 FOREIGN KEY(source_partition,candidate_id) REFERENCES source_decoding_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.palette_current (
 palette_id TEXT PRIMARY KEY NOT NULL, source_partition INTEGER NOT NULL, candidate_id TEXT NOT NULL,
 FOREIGN KEY(source_partition,candidate_id) REFERENCES palette_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.shelf_reference_current (
 shelf_id TEXT PRIMARY KEY NOT NULL, source_partition INTEGER NOT NULL, candidate_id TEXT NOT NULL,
 FOREIGN KEY(source_partition,candidate_id) REFERENCES shelf_reference_candidate(partition,record_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE usr.reading_fact_current (
 fact_id TEXT PRIMARY KEY NOT NULL, source_partition INTEGER NOT NULL, book_key TEXT NOT NULL,
 session_id TEXT NOT NULL, visit_id TEXT NOT NULL,
 started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, local_day INTEGER NOT NULL, utc_offset_seconds INTEGER NOT NULL,
 preview INTEGER NOT NULL CHECK(preview IN (0,1)), duration_ms INTEGER NOT NULL CHECK(duration_ms>=0),
 first_exposure_start TEXT CHECK(length(first_exposure_start)=20 AND first_exposure_start NOT GLOB '*[^0-9]*' AND first_exposure_start<='18446744073709551615'),
 FOREIGN KEY(source_partition,fact_id) REFERENCES reading_fact(partition,fact_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX usr.reading_fact_current_by_day ON reading_fact_current(local_day,book_key,fact_id);
CREATE INDEX usr.reading_fact_current_by_book_day ON reading_fact_current(book_key,local_day);
CREATE INDEX usr.reading_fact_current_by_visit ON reading_fact_current(book_key,session_id,visit_id,started_ms,fact_id);
CREATE TABLE usr.reading_segment_current (
 segment_id TEXT PRIMARY KEY NOT NULL, source_partition INTEGER NOT NULL, book_key TEXT NOT NULL,
 session_id TEXT NOT NULL, visit_id TEXT NOT NULL,
 started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL CHECK(ended_ms>started_ms),
 local_day INTEGER NOT NULL, utc_offset_seconds INTEGER NOT NULL, preview INTEGER NOT NULL CHECK(preview IN (0,1)),
 revision TEXT NOT NULL CHECK(length(revision)=20 AND revision NOT GLOB '*[^0-9]*'
   AND revision BETWEEN '00000000000000000001' AND '18446744073709551615'),
 duration_ms INTEGER NOT NULL CHECK(duration_ms BETWEEN 1 AND 86400000),
 trim_prefix_ms INTEGER NOT NULL CHECK(trim_prefix_ms BETWEEN 0 AND 86399999),
 first_exposure_start TEXT NOT NULL CHECK(length(first_exposure_start)=20 AND first_exposure_start NOT GLOB '*[^0-9]*'
   AND first_exposure_start<='18446744073709551615'),
 FOREIGN KEY(source_partition,segment_id) REFERENCES reading_segment(partition,segment_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX usr.reading_segment_current_by_day ON reading_segment_current(local_day,book_key,segment_id);
CREATE INDEX usr.reading_segment_current_by_book_day ON reading_segment_current(book_key,local_day);
CREATE INDEX usr.reading_segment_current_by_visit ON reading_segment_current(book_key,session_id,visit_id,started_ms,segment_id);
CREATE VIEW usr.reading_contribution_head AS
 SELECT 'fact' AS kind,fact_id AS id,source_partition,book_key,session_id,visit_id,started_ms,ended_ms,
   local_day,utc_offset_seconds,preview,duration_ms,first_exposure_start
 FROM reading_fact_current
 UNION ALL
 SELECT 'segment',segment_id,source_partition,book_key,session_id,visit_id,started_ms,ended_ms,
   local_day,utc_offset_seconds,preview,duration_ms,first_exposure_start
 FROM reading_segment_current;
CREATE TABLE usr.reading_day (
 book_key TEXT NOT NULL, local_day INTEGER NOT NULL,
 duration_ms TEXT NOT NULL CHECK(length(duration_ms)=20 AND duration_ms NOT GLOB '*[^0-9]*' AND duration_ms<='18446744073709551615'),
 fact_count INTEGER NOT NULL CHECK(fact_count>0), -- effective fact or segment contributions
 first_started_ms INTEGER NOT NULL, last_ended_ms INTEGER NOT NULL, last_normal_ended_ms INTEGER,
 PRIMARY KEY(book_key,local_day)
);
CREATE INDEX usr.reading_day_by_date ON reading_day(local_day,book_key);
