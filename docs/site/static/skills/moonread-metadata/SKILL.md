---
name: moonread-metadata
description: Edit a Moonread-exported JSON or JSONL metadata manifest for reimport, optionally packaged with JPEG/PNG covers. Use for book titles, authors, tags, descriptions, covers and reading states; not for novel text or reading-data backups.
---

# Moonread metadata v1

Work on a copy of the user's exported manifest. Preserve every `content_sha256` and the entire `reference` object exactly. Moonread matches only this indexed normalized-text identity: never calculate a hash from the TXT, choose a target by filename/path, or infer that equal titles are the same book. Do not request novel text for matching.

Schema: https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json
Format: https://suxiaoshao.github.io/moonread/en/metadata-format/
Examples: [JSON](examples/metadata.json), [JSONL](examples/metadata.jsonl).

- JSONL: one Book object per nonblank physical line, each with `v: 1`.
- JSON: envelope `{ "format": "moonread-metadata", "version": 1, "books": [...] }`; each book still has `v: 1`. Optional `$schema` uses the product schema URL above.
- UTF-8, LF or CRLF, optional leading BOM, final newline optional. No duplicate object keys, comments or trailing commas.
- Keep unknown information absent. Never invent an author or substitute `reference.author` as an edit without evidence. Disclose uncertain research to the user before writing it.

## Writable fields

`author`: one nonblank string; do not split into invented coauthors.
`tags`: strings; Moonread trims whitespace and removes empty/duplicate tags. Default import appends, not replaces. Maximum 100 tags, 128 UTF-8 bytes per normalized tag.
`description`: nonblank string, newline escapes allowed, at most 64 KiB UTF-8.
`author` is limited to 1024 UTF-8 bytes.
`reading_state`: exactly `unread`, `reading`, `finished`, `paused`. Setting a state never resets progress; `unread` is ignored when reading records exist.
`title`: optional real-file rename suggestion without the TXT extension. Default off in preview; only available when the SHA has exactly one currently indexed file across all shelves. Never use it to relocate a file.
`cover`: relative `covers/...jpg`, `.jpeg` or `.png`, in a ZIP package. No URLs, base64 or SVG. Do not invent a nonexistent asset.

Missing means unchanged. `null` never means clear. Empty author/description is invalid. Only an explicit `clear` array may clear `author`, `tags`, `description`, or `cover`; it must not repeat entries or assign and clear the same field. Propose destructive edits only when the user requests them; Moonread also requires explicit preview selection. `tags: []` with default append changes nothing.

`series`/`authors` and other optional fields are not imported; future re-export does not preserve them. Initial `requires` supported capabilities are empty: do not add a nonempty list to a v1 file.

## Delivering a file

Prefer JSONL for large edits. Validate the envelope or each JSONL Book against the same JSON Schema 2020-12. Runtime matching, byte limits, archive and image safety still apply after schema validation.

For covers, ZIP exactly one root `metadata.jsonl` or `metadata.json` with optional `README.txt` and `covers/` JPEG/PNG files, and name it `.moonread-metadata`. No absolute paths, dot/dotdot components, backslashes, links, duplicate/case-colliding members or nested archives. Bare manifests do not authorize reading neighboring cover files. Reuse Moonread's backup archive budgets, not a newly invented limit.

Return the edited file plus a short list of changed fields, uncertain entries and any proposed clear/rename. Do not upload it or alter user originals. The user imports it in Settings → Data management → Novel information and reviews per-book differences. Existing conflicting values, clears and renames are not automatically accepted. Unindexed files are skipped; changed identities report “Book not found.” Metadata saved before a later storage failure or cancellation remains saved; rename failure does not roll it back. This format does not restore reading positions, annotations or statistics.
