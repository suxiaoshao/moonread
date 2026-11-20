use moonread_core::*;

#[test]
fn history_tracks_explicit_visits_and_truncates_forward_branch() {
    let mut history = empty_reading_history();
    history = visit_reading_position(history, 0, "原点".into(), 10, "A".into());
    history = visit_reading_position(history, 12, "A".into(), 20, "B".into());
    let a = history.entries[1].id.clone();
    history = select_reading_history(history, a).unwrap();
    history = visit_reading_position(history, 12, "A".into(), 30, "C".into());
    assert_eq!(
        history
            .entries
            .iter()
            .map(|v| v.offset_utf8)
            .collect::<Vec<_>>(),
        vec![0, 12, 30]
    );
    for n in 1..100 {
        history = visit_reading_position(history, n, "".into(), n + 1, "".into());
    }
    assert_eq!(history.entries.len(), 32);
    assert_eq!(history.cursor, 31);
    assert!(select_reading_history(history, "missing".into()).is_err());
}
