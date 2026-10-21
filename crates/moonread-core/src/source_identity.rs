//! Read-only, bounded normalized identity probing for a small admitted candidate set.
//! Uses exactly the import decoder and normalization-v1, without any database writes.
use crate::{ReaderError, Result, decoding_policy, sha::sha256_hex, text};
use encoding_rs::Encoding;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

#[derive(Debug, Clone, uniffi::Record)]
pub struct SourceTextIdentity {
    pub content_sha256: String,
    pub raw_sha256: String,
    pub encoding: String,
    pub source_bytes: u64,
    pub utf8_bytes: u64,
    pub char_count: u64,
}
#[derive(Default, uniffi::Object)]
pub struct SourceIdentityProbe {
    cancelled: AtomicBool,
}
struct Input<'a> {
    file: File,
    probe: &'a SourceIdentityProbe,
    hash: Sha256,
    bytes: u64,
}
impl Read for Input<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.probe.cancelled.load(Ordering::Acquire) {
            return Err(std::io::ErrorKind::Interrupted.into());
        }
        let n = self.file.read(buffer)?;
        self.hash.update(&buffer[..n]);
        self.bytes += n as u64;
        Ok(n)
    }
}
#[uniffi::export]
impl SourceIdentityProbe {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn identify(&self, file_path: String, decoding: String) -> Result<SourceTextIdentity> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(ReaderError::Paused);
        }
        let mut file = File::open(file_path)?;
        let policy = decoding_policy(&decoding)?;
        let encoding = if policy == "auto" {
            text::detect_encoding(&mut file)?
        } else {
            Encoding::for_label(policy.as_bytes()).ok_or(ReaderError::InvalidSettings)?
        };
        file.seek(SeekFrom::Start(0))?;
        let mut input = Input {
            file,
            probe: self,
            hash: Sha256::new(),
            bytes: 0,
        };
        let mut content = Sha256::new();
        let mut has_text = false;
        let mut utf8_bytes = 0;
        let mut char_count = 0;
        text::decode_chunks(&mut input, encoding, |part| {
            content.update(part.as_bytes());
            utf8_bytes += part.len() as u64;
            char_count += part.chars().filter(|c| !c.is_whitespace()).count() as u64;
            has_text |= part.chars().any(|c| !c.is_whitespace());
            Ok(())
        })?;
        if self.cancelled.load(Ordering::Acquire) {
            return Err(ReaderError::Paused);
        }
        if !has_text {
            return Err(ReaderError::EmptyBook);
        }
        Ok(SourceTextIdentity {
            content_sha256: sha256_hex(content.finalize()),
            raw_sha256: sha256_hex(input.hash.finalize()),
            encoding: encoding.name().into(),
            source_bytes: input.bytes,
            utf8_bytes,
            char_count,
        })
    }
}
#[uniffi::export]
pub fn normalize_source_decoding(decoding: String) -> Result<String> {
    Ok(decoding_policy(&decoding)?.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ReaderCore, ScannedLibraryItem};
    use std::io::Write;

    #[test]
    fn read_only_probe_matches_import_normalization_across_encodings() {
        let directory = tempfile::tempdir().unwrap();
        let core =
            ReaderCore::new(directory.path().join("cache").to_string_lossy().into()).unwrap();
        let plain = "第一章 原创样本\n窗边有一盏灯。\n第二段原创文字。\n";
        let expected = sha256_hex(Sha256::digest(plain.as_bytes()));
        let crlf = plain.replace('\n', "\r\n");
        let mut utf16 = vec![0xff, 0xfe];
        for c in crlf.encode_utf16() {
            utf16.extend(c.to_le_bytes());
        }
        let encoded = encoding_rs::GB18030.encode(&crlf).0.into_owned();
        for (index, (bytes, policy)) in [
            (plain.as_bytes().to_vec(), "auto"),
            (
                [vec![0xef, 0xbb, 0xbf], crlf.as_bytes().to_vec()].concat(),
                "auto",
            ),
            (utf16, "UTF-16LE"),
            (encoded, "gb18030"),
        ]
        .into_iter()
        .enumerate()
        {
            let path = directory.path().join(format!("original-{index}.txt"));
            std::fs::write(&path, &bytes).unwrap();
            let identity = SourceIdentityProbe::new()
                .identify(path.to_string_lossy().into(), policy.into())
                .unwrap();
            assert_eq!(identity.content_sha256, expected);
            assert_eq!(identity.raw_sha256, sha256_hex(Sha256::digest(&bytes)));
            assert_eq!(identity.source_bytes, bytes.len() as u64);
            assert_eq!(
                core.lock()
                    .unwrap()
                    .query_row("SELECT count(*) FROM books", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                0
            );
            // Compare the same established import path after the read-only assertion.
            let task = core.create_import("Original sample".into()).unwrap();
            core.stream_import(
                task.clone(),
                path.to_string_lossy().into(),
                identity.raw_sha256,
                if policy == "auto" {
                    None
                } else {
                    Some(policy.into())
                },
            )
            .unwrap();
            let id = core.finish_import(task).unwrap();
            assert_eq!(
                core.query_snapshot("{}".into())
                    .unwrap()
                    .book_info(id)
                    .unwrap()
                    .content_sha256,
                expected
            );
            // Reset only this test's cache; originals are untouched.
            core.lock()
                .unwrap()
                .execute("DELETE FROM books", [])
                .unwrap();
            assert_eq!(std::fs::read(path).unwrap(), bytes);
        }
    }
    #[test]
    fn cancelled_and_wrong_decoding_probes_never_create_cache_rows() {
        let directory = tempfile::tempdir().unwrap();
        let mut file = tempfile::NamedTempFile::new_in(directory.path()).unwrap();
        file.write_all(&[0xff, 0xfe, 0, 0x4e]).unwrap();
        let probe = SourceIdentityProbe::new();
        probe.cancel();
        assert!(matches!(
            probe.identify(file.path().to_string_lossy().into(), "auto".into()),
            Err(ReaderError::Paused)
        ));
        assert!(
            SourceIdentityProbe::new()
                .identify(file.path().to_string_lossy().into(), "UTF-8".into())
                .is_err()
        );
    }
    #[test]
    fn reopening_reclaims_only_unpublished_restoration_drafts() {
        let directory = tempfile::tempdir().unwrap();
        let cache = directory
            .path()
            .join("cache")
            .to_string_lossy()
            .into_owned();
        let path = directory.path().join("sample.txt");
        std::fs::write(&path, "Original synthetic story.\n").unwrap();
        let core = ReaderCore::new(cache.clone()).unwrap();
        let ordinary = core.create_import("Reader".into()).unwrap();
        let interrupted = core
            .create_restoration_import("Interrupted".into())
            .unwrap();
        let complete = core.create_restoration_import("Complete".into()).unwrap();
        let identity = SourceIdentityProbe::new()
            .identify(path.to_string_lossy().into(), "auto".into())
            .unwrap();
        core.stream_import(
            complete.clone(),
            path.to_string_lossy().into(),
            identity.raw_sha256,
            None,
        )
        .unwrap();
        let canonical = core.finish_import(complete).unwrap();
        // A deduplicated alias can also be interrupted after finalization. Its
        // pending scaffolding is disposable, never the shared canonical book.
        let alias = core.create_restoration_import("Alias".into()).unwrap();
        core.reuse_import(alias.clone(), canonical.clone()).unwrap();
        drop(core);
        let reopened = ReaderCore::new(cache).unwrap();
        assert!(reopened.import_status(interrupted.book_id()).is_err());
        assert!(reopened.import_status(alias.book_id()).is_err());
        assert_eq!(
            reopened.import_status(ordinary.book_id()).unwrap().phase,
            crate::ImportPhase::Paused
        );
        assert_eq!(
            reopened.text_id_for_sha(identity.content_sha256).unwrap(),
            canonical
        );
        assert_eq!(
            std::fs::read(&path).unwrap(),
            b"Original synthetic story.\n"
        );
    }

    #[test]
    fn association_checks_source_snapshot_and_sha_and_cleanup_preserves_shared_text() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("sample.txt");
        std::fs::write(&path, "Original chapter\nOriginal text.\n").unwrap();
        let core =
            ReaderCore::new(directory.path().join("cache").to_string_lossy().into()).unwrap();
        core.save_library_shelf(
            "builtin".into(),
            "Synthetic".into(),
            vec![],
            "local".into(),
            true,
        )
        .unwrap();
        core.scan_library_shelf(
            "builtin".into(),
            vec![ScannedLibraryItem {
                relative_path: "sample.txt".into(),
                directory: false,
                size: 32,
                modified: 1,
                needs_download: false,
            }],
        )
        .unwrap();
        let captured = core.source_file_snapshots(None).unwrap().remove(0);
        let imported = core
            .import_book(path.to_string_lossy().into(), "Original".into())
            .unwrap();
        assert!(
            !core
                .link_restored_library_file(
                    captured.clone(),
                    "auto".into(),
                    imported.id.clone(),
                    "wrong".into()
                )
                .unwrap()
        );
        core.set_source_decoding(captured.id.clone(), "UTF-8".into())
            .unwrap();
        assert!(
            !core
                .link_restored_library_file(
                    captured.clone(),
                    "auto".into(),
                    imported.id.clone(),
                    imported.content_sha256.clone()
                )
                .unwrap()
        );
        let current = core
            .source_file_snapshots(Some(captured.id.clone()))
            .unwrap()
            .remove(0);
        assert!(
            core.link_restored_library_file(
                current,
                "UTF-8".into(),
                imported.id.clone(),
                imported.content_sha256.clone()
            )
            .unwrap()
        );
        let ordinary = core.create_import("Reader-owned".into()).unwrap();
        assert!(core.discard_restoration_import(ordinary.clone()).is_err());
        assert!(core.import_status(ordinary.book_id()).is_ok());
        let draft = core.create_restoration_import("Disposable".into()).unwrap();
        let draft_id = draft.book_id();
        core.discard_restoration_import(draft).unwrap();
        assert!(core.import_status(draft_id).is_err());
        assert_eq!(
            core.source_file_snapshots(Some(captured.id)).unwrap()[0].book_id,
            Some(imported.id.clone())
        );
        assert!(core.text_id_for_sha(imported.content_sha256).is_ok());
    }
}
