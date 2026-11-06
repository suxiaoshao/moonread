//! normalization-v1 reference, checked against Moonread SourceIdentityProbe.
//! Reads a local file without changing it. Keeps the entire file in memory.
//! Usage: cargo run --release -- path/to/book.txt [auto|utf-8|utf-16le|gb18030|...]
//! stdout: lowercase content_sha256; stderr: selected encoding or rejection.
use encoding_rs::{DecoderResult, Encoding};
use sha2::{Digest, Sha256};

pub fn identify(bytes: &[u8], policy: &str) -> Result<(String, &'static str), String> {
    let encoding = if policy == "auto" {
        let head = &bytes[..bytes.len().min(65536)];
        let complete = bytes.len() <= 65536;
        if let Some((encoding, _)) = Encoding::for_bom(head) {
            encoding
        } else {
            let mut decoder = encoding_rs::UTF_8.new_decoder_without_bom_handling();
            let mut output = vec![0; head.len() + 4];
            let (status, _, _) = decoder.decode_to_utf8_without_replacement(head, &mut output, complete);
            if !matches!(status, DecoderResult::Malformed(..)) && !head.contains(&0x1b) {
                encoding_rs::UTF_8
            } else {
                let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Allow);
                detector.feed(head, complete);
                let guessed = detector.guess(None, chardetng::Utf8Detection::Deny);
                if guessed == encoding_rs::GBK { encoding_rs::GB18030 } else { guessed }
            }
        }
    } else {
        Encoding::for_label(policy.as_bytes())
            .filter(|e| ![encoding_rs::REPLACEMENT, encoding_rs::X_USER_DEFINED].contains(e))
            .ok_or("Invalid encoding label")?
    };
    // Same binary admission checks as the reader, before newline normalization.
    if [b"\x89PNG\r\n\x1a\n".as_slice(), b"PK\x03\x04", b"\x1f\x8b", b"\xff\xd8\xff\xe0\x00\x10JFIF\x00"]
        .iter().any(|magic| bytes.starts_with(magic)) {
        return Err("BinaryContent".into());
    }
    // This method removes only a matching initial BOM. It does not sniff/switch encodings.
    // Malformed input uses encoding_rs replacement behavior, never errors='ignore'.
    let (decoded, _had_errors) = encoding.decode_with_bom_removal(bytes);
    let mut scalars = 0;
    let mut nuls = 0;
    for c in decoded.chars() {
        scalars += 1;
        nuls += usize::from(c == '\0');
        if scalars == 4096 {
            if nuls >= 4 && nuls * 10 >= scalars { return Err("BinaryContent".into()); }
            scalars = 0; nuls = 0;
        }
    }
    if nuls >= 4 && nuls * 10 >= scalars { return Err("BinaryContent".into()); }
    let normalized = decoded.replace("\r\n", "\n").replace('\r', "\n");
    if !normalized.chars().any(|c| !c.is_whitespace()) { return Err("EmptyBook".into()); }
    let digest = Sha256::digest(normalized.as_bytes());
    Ok((digest.iter().map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(""), encoding.name()))
}

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(path) = args.next() else {
        eprintln!("Usage: moonread-metadata-identity FILE [auto|ENCODING]");
        std::process::exit(2);
    };
    let policy = args.next().unwrap_or_else(|| "auto".into());
    if args.next().is_some() { eprintln!("Too many arguments"); std::process::exit(2); }
    let result = std::fs::read(path).map_err(|e| e.to_string()).and_then(|bytes| identify(&bytes, &policy));
    match result {
        Ok((sha, encoding)) => { println!("{sha}"); eprintln!("encoding: {encoding}"); }
        Err(error) => { eprintln!("{error}"); std::process::exit(1); }
    }
}
