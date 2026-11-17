use crate::*;
use uuid::Uuid;

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingVisit {
    pub id: String,
    pub offset_utf8: u64,
    pub title: String,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingHistory {
    pub entries: Vec<ReadingVisit>,
    pub cursor: u32,
}

#[uniffi::export]
pub fn empty_reading_history() -> ReadingHistory {
    ReadingHistory {
        entries: Vec::new(),
        cursor: 0,
    }
}

#[uniffi::export]
pub fn update_history_position(
    mut history: ReadingHistory,
    offset_utf8: u64,
    title: String,
) -> ReadingHistory {
    if let Some(entry) = history.entries.get_mut(history.cursor as usize) {
        entry.offset_utf8 = offset_utf8;
        entry.title = title;
    }
    history
}

#[uniffi::export]
pub fn visit_reading_position(
    mut history: ReadingHistory,
    from_utf8: u64,
    from_title: String,
    to_utf8: u64,
    to_title: String,
) -> ReadingHistory {
    if history.entries.is_empty() {
        history.entries.push(ReadingVisit {
            id: Uuid::new_v4().to_string(),
            offset_utf8: from_utf8,
            title: from_title.clone(),
        });
        history.cursor = 0;
    }
    history = update_history_position(history, from_utf8, from_title);
    history.entries.truncate(history.cursor as usize + 1);
    if from_utf8 != to_utf8 {
        history.entries.push(ReadingVisit {
            id: Uuid::new_v4().to_string(),
            offset_utf8: to_utf8,
            title: to_title,
        });
        if history.entries.len() > 32 {
            history.entries.remove(0);
        }
        history.cursor = (history.entries.len() - 1) as u32;
    }
    history
}

#[uniffi::export]
pub fn select_reading_history(mut history: ReadingHistory, id: String) -> Result<ReadingHistory> {
    let index = history
        .entries
        .iter()
        .position(|e| e.id == id)
        .ok_or(ReaderError::InvalidRange)?;
    history.cursor = index as u32;
    Ok(history)
}

#[derive(uniffi::Record)]
pub struct ReadingLocation {
    pub offset_utf8: u64,
    pub percentage: f64,
    pub chapter: Option<ChapterInfo>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ReadingContinuation {
    pub offset_utf8: u64,
    pub percentage: f64,
    pub chapter: Option<ChapterInfo>,
}
