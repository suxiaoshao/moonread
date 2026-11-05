+++
title = "Book metadata exchange"
[extra]
kind = "metadata"
+++

## Edit information, then bring it back

Moonread 1.5 supports exporting and importing title suggestions, author, tags, description, custom covers and reading state in Settings → Data management → Novel information. Edit a manifest yourself or ask an agent to help, then review each change in Moonread. No information is fetched automatically.

This is not a reading-data backup: it contains no novel text, positions, bookmarks, notes, statistics or file-access permissions.

- [JSON Schema 2020-12](../../schema/moonread-metadata-v1.schema.json)
- [Agent Skill](../../skills/moonread-metadata/SKILL.md) · [agent.txt](../../agent.txt)
- Synthetic examples: [JSON](../../skills/moonread-metadata/examples/metadata.json) / [JSONL](../../skills/moonread-metadata/examples/metadata.jsonl)

## Identity and read-only references

Keep `content_sha256` unchanged. It is Moonread's normalization-v1 indexed text identity, not the raw TXT hash. Do not calculate it yourself. Import matches only this identity in the current shelf index, never title, path or `reference`; it does not read or download TXT files or start indexing.

`reference` contains the exported title, known author and shelf-relative source paths within the export scope. It is entirely ignored during import. Unindexed files are skipped and counted separately from exported metadata records. An unmatched identity reports “Book not found.” Indexed iCloud files need not be downloaded to exchange existing information.

## JSON, JSONL and cover packages

JSONL has one Book object per nonblank physical line, each with `v:1`. Bad lines are isolated. JSON uses this envelope, also with `v:1` on each Book. A syntax error rejects the document; a semantic book error is reported separately.

```json
{
  "$schema": "https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json",
  "format": "moonread-metadata",
  "version": 1,
  "books": [{"v": 1, "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "tags": ["To organize"]}]
}
```

Use UTF-8, optionally one leading BOM, LF or CRLF, with or without a final newline. Duplicate object keys, comments and trailing commas are invalid.

Exports with custom covers use a ZIP named `.moonread-metadata`: exactly one root `metadata.jsonl` or `metadata.json`, optional `README.txt`, and JPEG/PNG under `covers/`. Paths are package-relative. URLs, base64, SVG, links, absolute paths, dot/dotdot components, backslashes, duplicate and case-colliding entries are rejected. A bare manifest cannot authorize reading neighboring images. Archive resource budgets and path safety are shared with reading-data backups; images must still decode successfully.

## Editable fields

| Field | Rule |
| --- | --- |
| `title` | Real-file rename suggestion without the extension, off by default. Available only for a single currently indexed source across all shelves; keeps directory and original extension, never overwrites an existing file |
| `author` | One nonblank string, up to 1024 UTF-8 bytes |
| `tags` | Strings, trimmed and deduplicated with empty tags removed. Up to 100 tags, 128 UTF-8 bytes each. Appended by default; replacement is a preview choice |
| `description` | Nonblank text, newlines allowed, up to 64 KiB UTF-8 |
| `cover` | Package-relative `covers/…jpg`, `.jpeg` or `.png`. A missing or invalid image blocks only the cover field |
| `reading_state` | `unread`, `reading`, `finished`, `paused`; never resets position. Existing reading records block only an imported `unread` |
| `clear` | Unique names from `author`, `tags`, `description`, `cover`. Cannot assign and clear the same field; cannot clear title or state |
| `requires` | Required capabilities. Initial v1 support is empty; unknown requirements block that record |

Missing fields mean unchanged. `null` does not clear, blank author/description is invalid, and `tags:[]` with default append changes nothing. `series`, `authors` and unknown optional fields are reported but not applied; re-export does not preserve them. The original import file remains untouched. Schema validation covers structure; runtime additionally enforces byte budgets, capabilities, index matching, file safety and image decoding.

## Review and results

Only empty fields are filled by default; existing different values are retained. Tags append. Clears, replacement and real renames require explicit selection. Identical same-SHA records coalesce; conflicting field values show their source positions so you can choose or keep the existing value. Multiple source files share metadata but cannot receive a rename suggestion.

Each book saves atomically through the existing synchronization rules. Confirmation applies the selected preview fields without another field comparison. Storage failure stops the batch; cancellation takes effect between books. Completed books stay saved. Results separate saved, failed and unprocessed entries. Reimporting unchanged metadata does not create new revisions.

Rename runs after metadata is saved and uses the existing source-snapshot check. It never downloads an unavailable original: metadata remains saved and the result explains the skipped rename. No updated manifest is required after a rename because matching uses text identity, not the historical reference path.

Diagnostic JSONL contains source line/record number, code, field, a valid identity and a controlled short reason, without novel text or private absolute paths. Do not send private manifests or books unsolicited when reporting a problem.
