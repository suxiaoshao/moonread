//! Release baseline is v20. Append one transactional step per subsequent version.
use crate::{ReaderError, Result};
use rusqlite::Connection;

const BASELINE: u32 = 20;
const STEPS: &[&str] = &[];

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
            20
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
        let mut db = Connection::open_in_memory().unwrap();
        initialize(&mut db).unwrap();
        db.execute_batch("PRAGMA user_version=21").unwrap();
        assert!(matches!(
            initialize(&mut db),
            Err(ReaderError::StoreTooNew {
                version: 21,
                current: 20
            })
        ));
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, u32>(0))
                .unwrap(),
            21
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
