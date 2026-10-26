//! Release baseline is v20. Append one transactional step per subsequent version.
use crate::{ReaderError, Result};
use rusqlite::Connection;

const BASELINE: u32 = 20;
const STEPS: &[&str] = &[
    "ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading';",
    include_str!("../library/full_index.sql"),
    include_str!("source_decoding_migration.sql"),
];

pub(crate) fn initialize(db: &mut Connection) -> Result<()> {
    migrate(db, STEPS)
}

fn migrate(db: &mut Connection, steps: &[&str]) -> Result<()> {
    let mut version: u32 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let current = BASELINE + steps.len() as u32;
    if version > current {
        return Err(ReaderError::StoreTooNew { version, current });
    }
    if version != 0 && version < BASELINE {
        return Err(ReaderError::IncompatibleStore);
    }
    if version == 0 {
        let tx = db.transaction()?;
        tx.execute_batch(include_str!("schema.sql"))?;
        tx.commit()?;
        version = BASELINE;
    }
    while version < current {
        let tx = db.transaction()?;
        tx.execute_batch(steps[(version - BASELINE) as usize])?;
        tx.pragma_update(None, "user_version", version + 1)?;
        tx.commit()?;
        version += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn baseline_is_idempotent_and_preserves_authorization() {
        let mut db = Connection::open_in_memory().unwrap();
        initialize(&mut db).unwrap();
        db.execute_batch(
            "INSERT INTO library_shelves VALUES('s','Shelf',X'010203','local',0,NULL)",
        )
        .unwrap();
        initialize(&mut db).unwrap();
        let bookmark: Vec<u8> = db
            .query_row("SELECT bookmark FROM library_shelves", [], |r| r.get(0))
            .unwrap();
        assert_eq!(bookmark, [1, 2, 3]);
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            23
        );
    }

    #[test]
    fn v20_imports_upgrade_as_reading_and_preserve_sources() {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("schema.sql")).unwrap();
        db.execute_batch("INSERT INTO books(id,title,content_sha256,encoding) VALUES('draft','Original','pending:draft','UTF-8'); INSERT INTO import_jobs(book_id,generation) VALUES('draft',7); INSERT INTO library_shelves VALUES('s','Shelf',X'010203','local',0,NULL);").unwrap();
        initialize(&mut db).unwrap();
        initialize(&mut db).unwrap();
        let task: (String, u32) = db
            .query_row(
                "SELECT purpose,generation FROM import_jobs WHERE book_id='draft'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(task, ("reading".into(), 7));
        assert_eq!(
            db.query_row("SELECT bookmark FROM library_shelves", [], |r| r
                .get::<_, Vec<u8>>(0))
                .unwrap(),
            vec![1, 2, 3]
        );
    }

    #[test]
    fn steps_are_ordered_and_failed_step_rolls_back() {
        let mut db = Connection::open_in_memory().unwrap();
        let steps = [
            "CREATE TABLE migration_probe(value TEXT); INSERT INTO migration_probe VALUES('kept');",
            "ALTER TABLE migration_probe ADD COLUMN extra TEXT; INSERT INTO missing_table VALUES(1);",
        ];
        assert!(migrate(&mut db, &steps).is_err());
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            21
        );
        assert!(db.prepare("SELECT extra FROM migration_probe").is_err());
        migrate(
            &mut db,
            &[
                steps[0],
                "ALTER TABLE migration_probe ADD COLUMN extra TEXT;",
            ],
        )
        .unwrap();
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            22
        );
        assert_eq!(
            db.query_row("SELECT value FROM migration_probe", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "kept"
        );
    }

    #[test]
    fn future_and_prebaseline_versions_are_rejected_without_reset() {
        let dir = tempfile::tempdir().unwrap();
        let mut db = Connection::open(dir.path().join("reader.sqlite3")).unwrap();
        initialize(&mut db).unwrap();
        db.execute_batch("PRAGMA user_version=24").unwrap();
        assert!(matches!(
            initialize(&mut db),
            Err(ReaderError::StoreTooNew {
                version: 24,
                current: 23
            })
        ));
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            24
        );
        assert!(
            matches!(
                crate::ReaderCore::new(dir.path().to_string_lossy().into()),
                Err(ReaderError::StoreTooNew { .. })
            ),
            "public open must preserve the same too-new error"
        );
        db.execute_batch("PRAGMA user_version=19").unwrap();
        assert!(matches!(
            initialize(&mut db),
            Err(ReaderError::IncompatibleStore)
        ));
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            19
        );
    }
}

#[cfg(test)]
mod decoding_tests {
    use super::*;
    #[test]
    fn v22_registers_only_manual_choices_once_with_only_verified_raw_identity() {
        let mut db = Connection::open_in_memory().unwrap();
        migrate(&mut db, &STEPS[..2]).unwrap();
        db.execute_batch("INSERT INTO library_shelves VALUES('s','Shelf',X'01','local',0,NULL);
            INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,decoding) VALUES
            ('auto','s','auto.txt','','auto.txt',0,10,20,0,'auto'),('manual','s','manual.txt','','manual.txt',0,10,20,0,'GB18030'),
            ('stale','s','stale.txt','','stale.txt',0,10,21,0,'Big5'),('offline','s','offline.txt','','offline.txt',0,10,20,0,'UTF-8');").unwrap();
        let raw = "a".repeat(64);
        db.execute(
            "INSERT INTO source_identities VALUES(?1,'GB18030',?1,'GB18030',10,10)",
            [&raw],
        )
        .unwrap();
        db.execute(
            "INSERT INTO source_identities VALUES(?1,'Big5',?1,'Big5',10,10)",
            [&raw],
        )
        .unwrap();
        db.execute(
            "INSERT INTO library_identities VALUES('manual',?1,'GB18030',10,20)",
            [&raw],
        )
        .unwrap();
        db.execute(
            "INSERT INTO library_identities VALUES('stale',?1,'Big5',10,20)",
            [&raw],
        )
        .unwrap();
        initialize(&mut db).unwrap();
        let rows: Vec<(String, Option<String>)> = db
            .prepare("SELECT file_id,raw_sha256 FROM source_decoding_migration ORDER BY file_id")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<std::result::Result<_, _>>()
            .unwrap();
        assert_eq!(
            rows,
            vec![
                ("manual".into(), Some(raw)),
                ("offline".into(), None),
                ("stale".into(), None)
            ]
        );
        db.execute(
            "DELETE FROM source_decoding_migration WHERE file_id='manual'",
            [],
        )
        .unwrap();
        initialize(&mut db).unwrap();
        assert_eq!(
            db.query_row("SELECT count(*) FROM source_decoding_migration", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            2
        );
    }
}
