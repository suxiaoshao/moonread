pub(crate) fn is_counted_scalar(scalar: char) -> bool {
    !scalar.is_whitespace()
}

pub(crate) fn count_text_scalars(text: &str) -> u64 {
    text.chars()
        .filter(|&scalar| is_counted_scalar(scalar))
        .count() as u64
}

#[derive(uniffi::Record)]
pub struct ChapterTextCounts {
    pub title_start: u64,
    pub body_start: u64,
}

/// The caller validates the line boundaries and reads the saved block prefix.
#[uniffi::export]
pub fn chapter_text_counts(
    block_prefix: u64,
    line_prefix: String,
    title: String,
) -> ChapterTextCounts {
    let title_start = block_prefix + count_text_scalars(&line_prefix);
    ChapterTextCounts {
        title_start,
        body_start: title_start + count_text_scalars(&title),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_count_excludes_whitespace_and_counts_combining_marks_separately() {
        assert_eq!(count_text_scalars(" \u{a0}\u{3000}e\u{301}🦉"), 3);
    }
}
