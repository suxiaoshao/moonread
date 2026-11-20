---
name: moonread-metadata
description: Create Moonread metadata directly from local TXT files, or edit an existing JSON/JSONL manifest, optionally packaged with JPEG/PNG covers. Calculate normalization-v1 identities locally when needed; prepare authors, tags, descriptions, covers and reading states for user review in the app.
---

# Moonread metadata v1

## Two equally supported starting points

- **Existing manifest:** work on a copy; preserve its `content_sha256` and `reference` values. No TXT access is needed for this route.
- **Local TXT, no export:** read only files the user supplies/authorizes, calculate normalization-v1 with the reference below and create a new manifest. No export prerequisite. Do not change or upload full text. If you cannot access local files, ask the user to run the reference locally and provide hashes rather than requiring a full-text upload.

In either route Moonread matches only the identity against its current shelf index. The user must add and index the TXT in Moonread before importing metadata. Titles and paths are never fallback keys. For newly generated records, `reference` is optional; include only known title/author/relative-path context, never invent a shelf. Do not fabricate an author, synopsis, identity, or nonexistent cover asset. Existing `reference.author` is context, not automatically an intended author edit.

A manually selected encoding in Moonread takes precedence over auto detection: use the same policy. Other detectors or codec implementations, especially for non-UTF-8 input, may produce a different hash. A miss reports “Book not found” and skips the record rather than modifying a similarly named book. Check the encoding or fall back to Moonread's export when needed.

For direct TXT generation, omit `reference` entirely if unneeded. If you include `reference.files`, each item has `title` and relative `path`; `shelf` is **optional** and should be omitted when unknown, not guessed or filled with a placeholder. For example: `"reference": {"files": [{"title": "Sample book", "path": "sample.txt"}]}`. Preserve reference values in an existing export. The importer discards the whole reference object before parsing editable fields; none of it selects a book.

Schema: https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json
Format: https://suxiaoshao.github.io/moonread/en/metadata-format/
Examples: [JSON](examples/metadata.json), [JSONL](examples/metadata.jsonl).

- JSONL: one Book object per nonblank physical line, each with `v: 1`.
- JSON: envelope `{ "format": "moonread-metadata", "version": 1, "books": [...] }`; each book still has `v: 1`. Optional `$schema` uses the product schema URL above.
- UTF-8, LF or CRLF, optional leading BOM, final newline optional. No duplicate object keys, comments or trailing commas.
- Keep unknown information absent. Never invent an author or substitute `reference.author` as an edit without evidence. Disclose uncertain research to the user before writing it.

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

Download [identity.rs](identity/identity.rs) and [Cargo.toml](identity/Cargo.toml) into one directory. With a Rust 2024 toolchain, run there:

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

The full example includes detection, BOM handling, recovery and admission checks. Dependencies are pinned to chardetng 1.0.0, encoding_rs 0.8.42 and sha2 0.11.1. Python `chardet`, `charset-normalizer` or default `open()` is not an equivalent implementation. Try the [original synthetic TXT](identity/sample.txt) and [directly generated JSON](identity/generated.json): add and index the TXT in Moonread before importing the JSON. See the [reference notes](identity/README.md) for verification results.

For non-UTF-8 input, another detector, mapping/recovery policy or manual encoding can produce a different identity, especially for short files. An unmatched identity reports “Book not found” and is skipped; it never falls back to another book by title or path. Check Moonread's encoding, or use an identity from a Moonread export. Even an externally calculated identity requires a matching current shelf index; metadata import does not download or index the text automatically.

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

For covers, ZIP exactly one root `metadata.jsonl` or `metadata.json` with optional `README.txt` and `covers/` JPEG/PNG files, and name it `.moonread-metadata`. No absolute paths, dot/dotdot components, backslashes, links, duplicate/case-colliding members or nested archives. Bare manifests do not authorize reading neighboring cover files. Concrete shared limits (binary units, not decimal GB/MB): ZIP file or bare JSON/JSONL ≤ **512 MiB (536,870,912 bytes)**; total uncompressed ZIP members ≤ **2 GiB (2,147,483,648 bytes)**; at most **100,000 ZIP members** (including directory entries); each cover file ≤ **32 MiB (33,554,432 bytes)**; each book record and optional README.txt ≤ **16 MiB (16,777,216 bytes)**. The manifest inside a ZIP shares the 2 GiB total budget; individual fields retain their smaller limits above. The ZIP central directory is also limited to 64 MiB. Covers must decode successfully; these byte budgets do not waive image or path validation.

Return the created or edited file plus a short list of changed fields, uncertain entries and any proposed clear/rename. Do not upload it or alter user originals. The user imports it in Settings → Data management → Novel information → Import and reviews per-book differences. Existing conflicting values, clears and renames are not automatically accepted. Unindexed files are skipped on export; an import with no matching indexed identity reports “Book not found.” Metadata saved before a later storage failure or cancellation remains saved; rename failure does not roll it back. This format does not restore reading positions, annotations or statistics.
