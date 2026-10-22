/// SHA-256 identity uses exactly 64 lowercase hex characters, including leading zeros.
pub(crate) fn sha256_hex(bytes: impl AsRef<[u8]>) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let bytes = bytes.as_ref();
    debug_assert_eq!(bytes.len(), 32);
    let mut value = String::with_capacity(64);
    for &byte in bytes {
        value.push(HEX[(byte >> 4) as usize] as char);
        value.push(HEX[(byte & 15) as usize] as char);
    }
    value
}
