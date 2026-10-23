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
    natural_cmp(&a.name, &b.name)
        .then_with(|| a.relative_path.cmp(&b.relative_path))
        .then_with(|| a.id.cmp(&b.id))
}

pub(crate) fn directory_order(
    a: &crate::LibraryEntry,
    b: &crate::LibraryEntry,
    sort: crate::LibrarySort,
) -> std::cmp::Ordering {
    use crate::LibrarySort;
    match sort {
        LibrarySort::Reading => (a.directory && a.child_book_count == 0)
            .cmp(&(b.directory && b.child_book_count == 0))
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
            .directory
            .cmp(&a.directory)
            .then_with(|| natural_cmp(&a.name, &b.name)),
    }
    .then_with(|| a.relative_path.cmp(&b.relative_path))
    .then_with(|| a.id.cmp(&b.id))
}
