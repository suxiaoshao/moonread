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

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn known_and_previous_sha010_vectors_match_for_all_chunk_boundaries() {
        // Captured from sha2 0.10.9, not recomputed by the implementation under test.
        let vectors = [
            (
                0,
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ),
            (
                3,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ),
            (
                55,
                "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            ),
            (
                56,
                "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            ),
            (
                63,
                "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            ),
            (
                64,
                "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            ),
            (
                65,
                "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            ),
            (
                1048593,
                "c26032d5154f96bd29c799447d715ab681d8d0aa308ecc6f321a35d98f0672da",
            ),
        ];
        for (size, expected) in vectors {
            let input = if size == 3 {
                b"abc".to_vec()
            } else {
                vec![b'a'; size]
            };
            assert_eq!(sha256_hex(Sha256::digest(&input)), expected);
            for chunk_size in [1, 7, 63, 64, 65, 1024 * 1024] {
                let mut hash = Sha256::new();
                for chunk in input.chunks(chunk_size) {
                    hash.update(chunk);
                }
                assert_eq!(sha256_hex(hash.finalize()), expected);
            }
        }
        assert_eq!(
            sha256_hex(Sha256::digest(b"286")),
            "00328ce57bbc14b33bd6695bc8eb32cdf2fb5f3a7d89ec14a42825e15d39df60"
        );
    }
}
