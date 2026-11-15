//! Natural file ordering, independent of localized display grouping.
pub(crate) fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let a = a.to_lowercase();
    let b = b.to_lowercase();
    let mut a = a.chars().peekable();
    let mut b = b.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut x = String::new();
                let mut y = String::new();
                while a.peek().is_some_and(char::is_ascii_digit) {
                    x.push(a.next().unwrap());
                }
                while b.peek().is_some_and(char::is_ascii_digit) {
                    y.push(b.next().unwrap());
                }
                let nx = x.trim_start_matches('0');
                let ny = y.trim_start_matches('0');
                let order = nx
                    .len()
                    .cmp(&ny.len())
                    .then_with(|| nx.cmp(ny))
                    .then_with(|| x.len().cmp(&y.len()));
                if !order.is_eq() {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.cmp(&y);
                if !order.is_eq() {
                    return order;
                }
                a.next();
                b.next();
            }
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
        }
    }
}

pub(crate) fn file_order(a: &crate::LibraryEntry, b: &crate::LibraryEntry) -> std::cmp::Ordering {
    file_order_fields(
        (&a.name, &a.relative_path, &a.id),
        (&b.name, &b.relative_path, &b.id),
    )
}

pub(crate) fn file_order_fields(
    a: (&str, &str, &str),
    b: (&str, &str, &str),
) -> std::cmp::Ordering {
    natural_cmp(a.0, b.0)
        .then_with(|| a.1.cmp(b.1))
        .then_with(|| a.2.cmp(b.2))
}

#[derive(Debug, uniffi::Record)]
pub struct DirectorySortEntry {
    pub id: String,
    pub name: String,
    pub relative_path: String,
    pub folder_descendants: Option<u64>,
    pub last_read: i64,
    pub modified: i64,
}

/// Preserve the published row order, using only the already selected rows.
#[uniffi::export]
pub fn library_directory_order(
    mut rows: Vec<DirectorySortEntry>,
    sort: crate::LibrarySort,
) -> Vec<String> {
    rows.sort_by(|a, b| directory_order(a, b, sort));
    rows.into_iter().map(|v| v.id).collect()
}

fn directory_order(
    a: &DirectorySortEntry,
    b: &DirectorySortEntry,
    sort: crate::LibrarySort,
) -> std::cmp::Ordering {
    use crate::LibrarySort;
    match sort {
        LibrarySort::Reading => (a.folder_descendants == Some(0))
            .cmp(&(b.folder_descendants == Some(0)))
            .then_with(|| b.last_read.cmp(&a.last_read))
            .then_with(|| {
                if a.last_read == 0 && b.last_read == 0 {
                    b.modified.cmp(&a.modified)
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .then_with(|| natural_cmp(&a.name, &b.name)),
        LibrarySort::Name => b
            .folder_descendants
            .is_some()
            .cmp(&a.folder_descendants.is_some())
            .then_with(|| natural_cmp(&a.name, &b.name)),
    }
    .then_with(|| a.relative_path.cmp(&b.relative_path))
    .then_with(|| a.id.cmp(&b.id))
}

#[derive(Debug, uniffi::Record)]
pub struct ReadingDataSortEntry {
    pub key: String,
    pub title: String,
    pub last_read: i64,
}
#[uniffi::export]
pub fn reading_data_order(mut entries: Vec<ReadingDataSortEntry>, recent: bool) -> Vec<String> {
    entries.sort_by(|a, b| {
        (if recent {
            b.last_read.cmp(&a.last_read)
        } else {
            std::cmp::Ordering::Equal
        })
        .then_with(|| natural_cmp(&a.title, &b.title))
        .then_with(|| a.key.cmp(&b.key))
    });
    entries.into_iter().map(|v| v.key).collect()
}
