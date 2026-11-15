use crate::*;

#[derive(uniffi::Record)]
pub struct ReadingPayloadChunk {
    pub chunk: TextChunk,
    /// The byte preceding the indexed chunk, supplied only from the same
    /// published snapshot. A gap ending between chunks supplies its own LF.
    pub continued: bool,
}

#[derive(uniffi::Record)]
pub struct ReadingPayload {
    pub chunks: Vec<TextChunk>,
    pub paragraphs: Vec<ReadingParagraph>,
    pub has_non_whitespace: bool,
}

/// Split a bounded, already fetched set of chunks by proven blank runs. Swift
/// owns data access; this kernel neither fetches text nor retains any state.
#[uniffi::export]
pub fn project_reading_payload(
    source: Vec<ReadingPayloadChunk>,
    confirmed: u64,
    omitted: Vec<SourceSpan>,
    headings: Vec<ChapterInfo>,
) -> Result<ReadingPayload> {
    let mut groups: Vec<(Vec<TextChunk>, bool)> = Vec::new();
    let mut gap_index = 0;
    for ReadingPayloadChunk { chunk, continued } in source {
        let end = chunk.end_utf8.min(confirmed);
        let mut cursor = chunk.start_utf8;
        if end <= cursor {
            continue;
        }
        while gap_index < omitted.len() && omitted[gap_index].end_utf8 <= cursor {
            gap_index += 1;
        }
        let mut retained = Vec::new();
        while let Some(gap) = omitted.get(gap_index).filter(|span| span.start_utf8 < end) {
            if cursor < gap.start_utf8 {
                retained.push((cursor, gap.start_utf8));
            }
            cursor = gap.end_utf8;
            if cursor > end {
                break;
            }
            gap_index += 1;
        }
        if cursor < end {
            retained.push((cursor, end));
        }
        for (lo, hi) in retained {
            let start = (lo - chunk.start_utf8) as usize;
            let end = (hi - chunk.start_utf8) as usize;
            let text = chunk
                .text
                .get(start..end)
                .ok_or(ReaderError::InvalidRange)?;
            let value = TextChunk {
                index: chunk.index,
                start_utf8: lo,
                end_utf8: hi,
                text: text.to_owned(),
            };
            if let Some((group, _)) = groups
                .last_mut()
                .filter(|(group, _)| group.last().is_some_and(|item| item.end_utf8 == lo))
            {
                group.push(value);
            } else {
                let continued = if start == 0 {
                    continued
                } else {
                    chunk.text.as_bytes()[start - 1] != b'\n'
                };
                groups.push((vec![value], continued));
            }
        }
    }

    let mut paragraphs = Vec::new();
    let mut chunks = Vec::new();
    for (group, continued) in groups {
        // Classify groups separately: no paragraph bridges an omitted run.
        let start = group[0].start_utf8;
        let end = group.last().unwrap().end_utf8;
        let from = headings.partition_point(|chapter| chapter.start_utf8 < start);
        let to = headings.partition_point(|chapter| chapter.start_utf8 < end);
        paragraphs.extend(layout::classify_paragraphs(
            &group,
            &headings[from..to],
            &[],
            continued,
        ));
        chunks.extend(group);
    }
    Ok(ReadingPayload {
        has_non_whitespace: chunks
            .iter()
            .any(|chunk| chunk.text.chars().any(|c| !c.is_whitespace())),
        chunks,
        paragraphs,
    })
}
