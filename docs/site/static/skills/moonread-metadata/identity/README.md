# Moonread normalization-v1 reference

Two routes are equally supported: edit an existing manifest, or generate metadata directly from local TXT. A Moonread export is not required. This directory is a downloadable documentation example, not a replacement App implementation or an installed agent tool.

Download **Cargo.toml and identity.rs** to the same directory. Use Rust edition 2024; the verified local toolchain was Rust 1.99.0. Run `cargo run --release -- /path/to/book.txt auto`. stdout is a 64-character lowercase SHA; stderr reports the selected encoding. For a manually chosen Moonread encoding, replace `auto` with the same label. First build fetches dependencies; the program itself only reads a local file. It holds the whole file in memory.

## Create an import file without exporting

1. Read only authorized TXT files and calculate each identity with the reference. Record the chosen encoding for troubleshooting, not as a new transport field.
2. Create `{"format":"moonread-metadata","version":1,"books":[...]}`; each book needs `v:1` and its calculated `content_sha256`. Add only known, requested editable fields. `reference` is optional and ignored for matching; unknown shelves/paths need not be invented.
3. Validate the document with the [public JSON Schema](../../../schema/moonread-metadata-v1.schema.json). For JSONL validate each physical nonblank line as a Book. Covers require the package described by the [Skill](../SKILL.md).
4. Ensure the corresponding TXT is in Moonread's shelf index, then import and review. An unknown identity is skipped; there is no title/path fallback. Manual encoding or another detector may yield a different identity; match the policy or use an export when uncertain.

Try [sample.txt](sample.txt) with [generated.json](generated.json). The manifest was created from TXT, not exported; it deliberately omits `reference`. Add and index the TXT in Moonread to make the metadata match. Do not paste this synthetic SHA into real records:

```text
9b84f52a4ad4aa3427d6c3c343e16c3bc6c5cb59dc18b69d14f5ecf5a3dacc8d
```

For direct TXT generation, omit `reference` entirely if unneeded. If you include `reference.files`, each item has `title` and relative `path`; `shelf` is **optional** and should be omitted when unknown, not guessed or filled with a placeholder. For example: `"reference": {"files": [{"title": "Sample book", "path": "sample.txt"}]}`. Preserve reference values in an existing export. The importer discards the whole reference object before parsing editable fields; none of it selects a book.

## Algorithm


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

Download [identity.rs](identity.rs) and [Cargo.toml](Cargo.toml) into one directory. With a Rust 2024 toolchain, run there:

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

The full example includes detection, BOM handling, recovery and admission checks. Dependencies are pinned to chardetng 1.0.0, encoding_rs 0.8.42 and sha2 0.11.1. Python `chardet`, `charset-normalizer` or default `open()` is not an equivalent implementation. Try the [original synthetic TXT](sample.txt) and [directly generated JSON](generated.json): add and index the TXT in Moonread before importing the JSON. Verification results are listed below.

For non-UTF-8 input, another detector, mapping/recovery policy or manual encoding can produce a different identity, especially for short files. An unmatched identity reports “Book not found” and is skipped; it never falls back to another book by title or path. Check Moonread's encoding, or use an identity from a Moonread export. Even an externally calculated identity requires a matching current shelf index; metadata import does not download or index the text automatically.


## Verification (2026-11-05)

Compared this exact reference with the production `SourceIdentityProbe::identify` at Moonread `27d1ce8196750898727f11aa8c2a14a29f719835`, using the same local synthetic bytes. Dependencies: chardetng 1.0.0, encoding_rs 0.8.42, sha2 0.11.1.

**39/39 agree:** 31 accepted files have identical SHA-256 and selected encoding; 6 binary inputs and 2 empty/whitespace inputs have the same rejection. [Per-sample results](verification.json). Coverage: UTF-8, initial/double/internal BOM, LF/CRLF/CR, final-newline presence, NFC vs NFD (not normalized), controls, UTF-16LE/BE with BOM and manual BOMless decoding, isolated surrogate/odd tail, wrong manual encoding, GB18030 auto and four-byte extension, truncated legacy sequences, ISO-2022-JP ESC, UTF-8 sample-cut/late-invalid-byte boundaries, decoder-boundary CRLF and a large combining cluster.

For example the two raw bytes D6 D0 detect as Windows-1252 in auto, but decode as GB18030 when explicitly selected; their identities differ. This is intentional, not a reason to guess a fallback. The sample corpus is bounded evidence, not proof for every possible byte sequence; pin decoder/detector versions and reverify before upgrading. No user novels were read or copied.

Production sources: [detection, decoding and normalization](https://github.com/suxiaoshao/moonread/blob/27d1ce8196750898727f11aa8c2a14a29f719835/crates/moonread-core/src/reading/input/text.rs), [identity probe](https://github.com/suxiaoshao/moonread/blob/27d1ce8196750898727f11aa8c2a14a29f719835/crates/moonread-core/src/identity/source.rs). Local commit links become available after that commit is pushed.
