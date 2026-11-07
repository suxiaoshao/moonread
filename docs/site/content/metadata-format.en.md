+++
title = "Organize book information outside Moonread"
[extra]
kind = "metadata"
+++

Edit a manifest exported from Moonread, or create one directly from local TXT files. Organize authors, tags, descriptions and covers yourself or with an agent, then review each change in Moonread.

Available in Moonread 1.5. This exchanges book information; use **Reading data backup** to restore positions, bookmarks and notes.

## What you can do

- **Tidy up tags.** Combine “Sci-fi” and “Science fiction” into one label, or categorize a batch of books.
- **Fill in missing details.** Add authors, descriptions and custom covers from reliable information you already have, without editing every book on your phone.
- **Organize reading states.** Mark books as reading, finished or paused without changing your reading position.
- **Prepare rename suggestions.** Make filenames consistent, then decide which suggestions to apply in Moonread.

## Three steps to prepare and import information

### 1. Start with a manifest or TXT files

**Existing Moonread information:** go to Settings → Data management → Novel information → Export. Choose all shelves or one shelf and save a JSONL/JSON manifest; custom covers are packaged in `.moonread-metadata`. Edit a copy, preserving existing identities and references. Unindexed books are skipped and counted; indexed iCloud books need not be downloaded to export their information.

**No manifest yet:** give a local agent the paths to your TXT files. It can calculate text identities using the public normalization-v1 algorithm below and create JSONL/JSON directly. A Moonread export is not required. `reference` can be omitted or contain known titles, authors and relative paths; do not invent shelf details. Add these TXT files to Moonread and index them before importing metadata, so they can be matched.

<div class="metadata-shots">
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../../images/metadata/en-dark-export-scope-480.webp 480w, ../../images/metadata/en-dark-export-scope-960.webp 960w, ../../images/metadata/en-dark-export-scope-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../../images/metadata/en-light-export-scope-960.webp" srcset="../../images/metadata/en-light-export-scope-480.webp 480w, ../../images/metadata/en-light-export-scope-960.webp 960w, ../../images/metadata/en-light-export-scope-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="Choose the export scope and format" loading="lazy" decoding="async">
</picture>
<figcaption>Choose the export scope and format</figcaption>
</figure>
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../../images/metadata/en-dark-export-result-480.webp 480w, ../../images/metadata/en-dark-export-result-960.webp 960w, ../../images/metadata/en-dark-export-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../../images/metadata/en-light-export-result-960.webp" srcset="../../images/metadata/en-light-export-result-480.webp 480w, ../../images/metadata/en-light-export-result-960.webp 960w, ../../images/metadata/en-light-export-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="Share or save the exported manifest" loading="lazy" decoding="async">
</picture>
<figcaption>Share or save the exported manifest</figcaption>
</figure>
</div>

### 2. Organize the information

Either starting point lets you add authors, tidy tags, edit descriptions and supply custom covers. JSONL has one book per text line; JSON holds the books in one document. Neither is an Excel spreadsheet. Use the agent prompt below if you prefer not to edit the format yourself.

Keep identities in existing manifests; calculate new ones from TXT using the algorithm, never a title or path. Leave uncertain details out rather than inventing them. Direct generation does not require sending text to a cloud service: calculate hashes locally and share only the information you want edited.

### 3. Import and review

Return to Novel information → Import and choose the edited file. See which books have changes, then open each book to compare before and after. **Nothing is saved until you confirm.**

By default, Moonread fills empty fields and appends tags, keeping existing values when they differ. Replacing tags, clearing information and renaming real files require explicit selection. Rename suggestions are off by default; when the same text has multiple source files, renaming is unavailable.

<div class="metadata-shots">
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../../images/metadata/en-dark-import-preview-480.webp 480w, ../../images/metadata/en-dark-import-preview-960.webp 960w, ../../images/metadata/en-dark-import-preview-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../../images/metadata/en-light-import-preview-960.webp" srcset="../../images/metadata/en-light-import-preview-480.webp 480w, ../../images/metadata/en-light-import-preview-960.webp 960w, ../../images/metadata/en-light-import-preview-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="Review the books to update" loading="lazy" decoding="async">
</picture>
<figcaption>Review the books to update</figcaption>
</figure>
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../../images/metadata/en-dark-import-result-480.webp 480w, ../../images/metadata/en-dark-import-result-960.webp 960w, ../../images/metadata/en-dark-import-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../../images/metadata/en-light-import-result-960.webp" srcset="../../images/metadata/en-light-import-result-480.webp 480w, ../../images/metadata/en-light-import-result-960.webp 960w, ../../images/metadata/en-light-import-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="See which books were saved" loading="lazy" decoding="async">
</picture>
<figcaption>See which books were saved</figcaption>
</figure>
</div>

> Screenshot to come: field-by-field comparison and choices.

Books that cannot be found are skipped. A book with reading records cannot be changed to “unread,” but its other selected fields can still be imported; reading records are not deleted. If saving fails or you cancel, completed books stay saved. The result explains failures and lists unprocessed books. On reimport, information already saved and not changed since is shown as unchanged.

## Working with an agent

An agent here means an external AI tool of your choice that can work with files. **Moonread's built-in AI does not need to be enabled.** Provide an existing manifest copy or point an agent with local file access to your TXT files. A tool without local access can use identities you calculate locally; uploading full text is unnecessary. Fill in the input and editing request below.

```text
Prepare or edit a Moonread metadata manifest for me to review and import.
Input: [a manifest copy OR local TXT paths; choose one]
Request: [for example, unify tags and fill authors/descriptions from reliable facts I provide]

Read:
https://suxiaoshao.github.io/moonread/skills/moonread-metadata/SKILL.md
Algorithm and runnable reference:
https://suxiaoshao.github.io/moonread/skills/moonread-metadata/identity/README.md
Schema:
https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json

For a manifest, preserve existing content_sha256 and reference values.
For TXT, read locally without modifying it and calculate normalization-v1 identities
with the published reference, not Python strict decoding of a 64 KiB slice.
Use the same manual encoding as Moonread, if any.
Do not hash raw TXT bytes or guess identity from a title or path.
Do not upload full text, rewrite/move/delete TXT files or execute renames.
Do not invent authors/descriptions; list uncertainties. Without an explicit request,
do not clear fields or propose renames.

Return Schema-valid JSONL, JSON or a cover package named .moonread-metadata,
plus changes, selected encodings and unresolved questions. Do not import it for me.
Remind me that Moonread needs a matching shelf index; unmatched identities are skipped.
If needed, check the encoding or use an exported manifest instead.
```

If the tool cannot open links, download the [agent editing instructions (Skill)](../../skills/moonread-metadata/SKILL.md) and [JSON Schema](../../schema/moonread-metadata-v1.schema.json), and provide them with your input. The Skill explains how to edit; the Schema checks the file structure. If your tool cannot handle cover packages, start with a manifest without covers.

**Check the information before sending it.** Metadata manifests may contain titles, authors, shelf names and relative paths, along with your descriptions and custom covers. Sending the file to an external service shares that information with the service; send only what you are comfortable sharing.

Moonread does not fetch missing information automatically or rewrite book text or the input manifest. A real filename changes only if you explicitly select its rename suggestion in the preview; files are not moved to another directory or overwritten.

## Format reference for agents and developers

The following describes v1. Downloads: [Schema 2020-12](../../schema/moonread-metadata-v1.schema.json) · [Skill](../../skills/moonread-metadata/SKILL.md) · [agent.txt](../../agent.txt) · synthetic [JSON](../../skills/moonread-metadata/examples/metadata.json) / [JSONL](../../skills/moonread-metadata/examples/metadata.jsonl) examples.

### Fields and defaults

Each book requires `v: 1` and `content_sha256`. An omitted editable field means unchanged; `null` does not clear a field, and blank authors or descriptions are invalid.

| Field | Meaning and limits |
| --- | --- |
| `content_sha256` | 64 lowercase hexadecimal characters; preserve an existing identity or calculate it from TXT using normalization-v1 below |
| `reference` | Optional title, known author, shelf names and relative paths; preserve existing context or omit when creating a manifest; ignored during import |
| `title` | Real-file rename suggestion without the extension, off by default; only for an identity with exactly one indexed file across all current shelves; keeps its directory and original extension |
| `author` | One nonblank string, up to 1024 UTF-8 bytes |
| `tags` | Strings, trimmed and deduplicated with empty entries removed; up to 100 tags, 128 UTF-8 bytes each; appends by default, replacement is a preview choice; `[]` changes nothing when appending |
| `description` | Nonblank text, newlines allowed, up to 64 KiB UTF-8 |
| `cover` | Packaged `covers/…jpg`, `.jpeg` or `.png`; a missing or invalid image skips only the cover field |
| `reading_state` | `unread`, `reading`, `finished`, `paused`; never changes position; existing reading records block only `unread` |
| `clear` | Unique names from `author`, `tags`, `description`, `cover`, explicitly requesting removal; cannot also assign the same field or clear title/state; off by default in preview |
| `requires` | Required capabilities; initial v1 support is empty, and unknown requirements block that record |

`series`, `authors` and unknown optional fields are reported but not applied; re-export does not guarantee their preservation. Schema validation checks structure; runtime checks still enforce byte budgets, capabilities, index matching, file safety and image decoding.

For direct TXT generation, omit `reference` entirely if unneeded. If you include `reference.files`, each item has `title` and relative `path`; `shelf` is **optional** and should be omitted when unknown, not guessed or filled with a placeholder. For example: `"reference": {"files": [{"title": "Sample book", "path": "sample.txt"}]}`. Preserve reference values in an existing export. The importer discards the whole reference object before parsing editable fields; none of it selects a book.

### Text identity: normalization-v1

`content_sha256` is **SHA-256 of the decoded, newline-normalized UTF-8 text**, rendered as 64 lowercase hexadecimal characters, not a raw-file hash. Filenames, paths and metadata are excluded. Keep an existing exported identity, or generate one from TXT using this algorithm.

1. **Choose the encoding.** If an encoding was manually selected in Moonread, use that same policy externally. Resolve labels with `encoding_rs::Encoding::for_label` (`latin1`, for example, means Windows-1252), not a similarly named codec in another language. Reject `replacement` and `x-user-defined`. For automatic detection:
   - Read at most **65,537 bytes** from the start. Detect from the first 65,536; the extra byte only distinguishes EOF from a capped sample. `complete=true` when the file is at most 65,536 bytes.
   - First use `Encoding::for_bom`, recognizing UTF-8, UTF-16LE and UTF-16BE BOMs. There is no separate UTF-32 or BOMless UTF-16 heuristic; specify the encoding for BOMless UTF-16.
   - Without a BOM, validate the sample using a UTF-8 decoder's `decode_to_utf8_without_replacement`, with `last=complete`. Choose UTF-8 if it is not malformed and contains **no ESC (0x1B)**. A capped sample may end within a multibyte character; actual EOF is checked strictly.
   - Otherwise use pinned **chardetng 1.0.0**: `EncodingDetector::new(Iso2022JpDetection::Allow)`, `feed(sample, complete)`, then `guess(None, Utf8Detection::Deny)`. No language/TLD hint. Replace a GBK guess with GB18030; keep other guesses.
2. **Decode the whole file from the beginning.** Use **encoding_rs 0.8.42**, `new_decoder_with_bom_removal()` and repeated `decode_to_utf8`, finishing with `last=true` at EOF. Remove only one initial BOM matching the selected encoding; do not switch encodings. Malformed sequences, unpaired surrogates and truncated tails use that decoder's U+FFFD replacement rules, not ignored bytes or a presumed one-replacement-per-byte policy. Never redetect/retry after a later decoding error.
3. **Normalize.** CRLF → LF, then remaining CR → LF. Preserve everything else: no trimming, added/removed final newline, NFC/NFKC, removal of an internal or second BOM, spaces, tabs, controls or zero-width characters. Display rules such as smart indentation do not apply. CRLF across decoder chunks is still one LF.
4. **Hash.** Encode this string as UTF-8 without adding a BOM, then compute SHA-256. Production hashes incrementally; chunk boundaries, word counts and pagination are not part of identity.

**Do not replace this detector with Python strict decoding.** `sample.decode('utf-8', errors='strict')` treats the end of a 64 KiB slice as EOF: a valid UTF-8 file whose sample ends halfway through a character would fail that test. Moonread passes `last=false` when more bytes exist, so that incomplete suffix is allowed; malformed bytes within the sample still fail. At real EOF it passes `last=true`. Use the runnable reference, or reproduce these incremental-decoder rules exactly; do not substitute `errors='ignore'` or `errors='replace'` for detection.

Reader admission also matters: reject raw prefixes PNG (`89 50 4e 47 0d 0a 1a 0a`), ZIP (`50 4b 03 04`), gzip (`1f 8b`) and full JFIF (`ff d8 ff e0 00 10 4a 46 49 46 00`). Before newline normalization, inspect consecutive **4096-Unicode-scalar windows**, including the final partial window: reject when NUL count is at least 4 and at least 10% of that window. A stray NUL, VT/FF, C1 controls and existing U+FFFD are preserved. Reject a normalized string containing no non-whitespace scalar, as defined by Rust `char::is_whitespace`.

### Runnable reference implementation

**Prerequisites and working directory:** external users need an installed Rust/Cargo toolchain supporting edition 2024 and the pinned dependencies (verified with Rust 1.99.0), plus the platform's native linker/build tools. No Moonread checkout, Xcode project, Nix or `nix develop` is required. Download `Cargo.toml` and `identity.rs` into a new empty directory, open a terminal **in that directory**, and run the command below with an absolute TXT path. Cargo compiles the downloaded reference, not the App; the first build needs access to the dependency registry. If Rust/Cargo is unavailable, arrange a toolchain rather than silently substituting a Python detector.

For Moonread contributors only: `nix develop` uses the repository's `flake.nix`; run it at the repository root, then use `cargo run --manifest-path /absolute/path/to/reference/Cargo.toml -- /absolute/path/to/book.txt auto`. The reference directory need not be inside the repository. Running plain `nix develop` in the downloaded two-file directory will not work because it has no flake.

Download [identity.rs](../../skills/moonread-metadata/identity/identity.rs) and [Cargo.toml](../../skills/moonread-metadata/identity/Cargo.toml) into one directory. With a Rust 2024 toolchain, run there:

```sh
cargo run --release -- "/path/to/book.txt" auto
# If Moonread uses a manual encoding, use the same label, for example:
cargo run --release -- "/path/to/book.txt" gb18030
```

Standard output is only the hash; standard error reports the selected encoding or rejection. The program reads local files without changing or sending their text; the first build downloads Cargo dependencies. For clarity, this example holds the file in memory, while Moonread streams it. Both use the same decoder version. The core after decoding is below; **this snippet alone is not the complete encoding detector**:

```rust
use sha2::{Digest, Sha256};
let (decoded, _) = encoding.decode_with_bom_removal(bytes);
let normalized = decoded.replace("\r\n", "\n").replace('\r', "\n");
let digest = Sha256::digest(normalized.as_bytes());
let content_sha256 = digest.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join("");
```

The full example includes detection, BOM handling, recovery and admission checks. Dependencies are pinned to chardetng 1.0.0, encoding_rs 0.8.42 and sha2 0.11.1. Python `chardet`, `charset-normalizer` or default `open()` is not an equivalent implementation. Try the [original synthetic TXT](../../skills/moonread-metadata/identity/sample.txt) and [directly generated JSON](../../skills/moonread-metadata/identity/generated.json): add and index the TXT in Moonread before importing the JSON. See the [reference notes](../../skills/moonread-metadata/identity/README.md) for verification results.

For non-UTF-8 input, another detector, mapping/recovery policy or manual encoding can produce a different identity, especially for short files. An unmatched identity reports “Book not found” and is skipped; it never falls back to another book by title or path. Check Moonread's encoding, or use an identity from a Moonread export. Even an externally calculated identity requires a matching current shelf index; metadata import does not download or index the text automatically.

### JSON and JSONL

JSON uses the following structure. The identity here is a placeholder; use an existing identity or calculate one from TXT as described above.

```json
{
  "$schema": "https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json",
  "format": "moonread-metadata",
  "version": 1,
  "books": [
    {
      "v": 1,
      "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "tags": ["To organize"]
    }
  ]
}
```

JSONL omits the outer envelope: each nonblank physical line is one book object, also with `v: 1`. Bad lines are reported individually. A JSON syntax error rejects the whole document; individual book-field errors are reported separately. Use UTF-8, optionally one leading BOM, LF or CRLF, with or without a final newline. Duplicate object keys, comments and trailing commas are invalid.

### Packages with covers

A `.moonread-metadata` file is a ZIP with exactly one root `metadata.jsonl` or `metadata.json`, optional `README.txt`, and JPEG/PNG files under `covers/`. Image paths are relative to the package root; a bare manifest cannot read neighboring images.

URLs, base64, SVG, links, absolute paths, dot/dotdot components, backslashes, duplicate and case-colliding entries are rejected. Concrete shared limits (binary units, not decimal GB/MB): ZIP file or bare JSON/JSONL ≤ **512 MiB (536,870,912 bytes)**; total uncompressed ZIP members ≤ **2 GiB (2,147,483,648 bytes)**; at most **100,000 ZIP members** (including directory entries); each cover file ≤ **32 MiB (33,554,432 bytes)**; each book record and optional README.txt ≤ **16 MiB (16,777,216 bytes)**. The manifest inside a ZIP shares the 2 GiB total budget; individual fields retain their smaller limits above. The ZIP central directory is also limited to 64 MiB. Covers must decode successfully; these byte budgets do not waive image or path validation.

### Matching and saving

Matching uses only the indexed `content_sha256` (normalization-v1), not a raw TXT hash. It never guesses from titles, paths or `reference`, rereads or downloads TXT files, or starts indexing. If changed text no longer matches the identity, the record reports “Book not found” and is skipped.

Identical same-SHA records coalesce; conflicting fields show source positions and values for the user to choose or retain. Each book saves atomically through the existing synchronization rules, without another field comparison before confirmation. Storage failure stops the batch; cancellation takes effect at a book transaction boundary. Reimporting unchanged information creates no new revisions.

Real-file renaming and the existing source-snapshot check run after metadata is saved. Unavailable originals are not downloaded for a rename; a rename failure leaves metadata saved and explains why the file was not renamed. No updated manifest is required afterward: historical paths are not used for matching.

Diagnostic JSONL contains source line/record number, code, field, a valid text identity and a controlled reason, without private absolute paths. Do not send private manifests or books unsolicited when reporting a problem.
