//! Portable transport only. SwiftData remains the owner of payload schemas and merge rules.
use crate::{ReaderError, Result, parse_sha256, validate_relative_path};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const MAX_ARCHIVE: u64 = 512 * 1024 * 1024;
const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
const MAX_MEMBERS: usize = 100_000;
const MAX_RECORD: u64 = 16 * 1024 * 1024;
const MAX_ASSET: u64 = 32 * 1024 * 1024;
const RECORDS: [&str; 5] = [
    "records/values.jsonl",
    "records/positions.jsonl",
    "records/annotations.jsonl",
    "records/facts.jsonl",
    "records/statistics-clears.jsonl",
];
fn invalid(message: &str) -> ReaderError {
    ReaderError::Backup {
        message: message.into(),
    }
}
fn zipped<T>(value: zip::result::ZipResult<T>) -> Result<T> {
    value.map_err(|_| invalid("备份 ZIP 无效、不完整或使用不支持的压缩方式"))
}
fn safe_name(name: &str) -> Result<()> {
    validate_relative_path(name.into(), false).map_err(|_| invalid("备份包含不安全路径"))?;
    // The portable member namespace is ASCII; this also prevents Unicode-normalization collisions.
    if !name.is_ascii()
        || name.contains(':')
        || name.contains('\\')
        || name
            .split('/')
            .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return Err(invalid("备份包含不安全路径"));
    }
    if name == "manifest.json" || RECORDS.contains(&name) || name.starts_with("extensions/") {
        return Ok(());
    }
    if let Some(hash) = name
        .strip_prefix("assets/")
        .and_then(|s| s.strip_suffix(".bin"))
    {
        parse_sha256(hash.into()).map_err(|_| invalid("备份清单摘要无效"))?;
        return Ok(());
    }
    Err(invalid("备份包含未知成员路径"))
}
fn limit(name: &str) -> u64 {
    if name == "manifest.json" {
        MAX_RECORD
    } else if name.starts_with("assets/") {
        MAX_ASSET
    } else {
        MAX_TOTAL
    }
}

// Bound central-directory allocation before the ZIP library parses it. Format
// validity/header consistency is still checked by zip; this is only a budget gate.
fn preflight_directory(file: &mut File) -> Result<()> {
    let length = file.metadata()?.len();
    if length > MAX_ARCHIVE {
        return Err(invalid("备份超过压缩包大小上限"));
    }
    let count = length.min(65557);
    file.seek(SeekFrom::End(-(count as i64)))?;
    let mut tail = vec![0; count as usize];
    file.read_exact(&mut tail)?;
    let at = (0..tail.len().saturating_sub(21))
        .rev()
        .find(|&i| {
            tail[i..].starts_with(b"PK\x05\x06")
                && i + 22 <= tail.len()
                && i + 22 + u16::from_le_bytes([tail[i + 20], tail[i + 21]]) as usize == tail.len()
        })
        .ok_or_else(|| invalid("备份 ZIP 无效、不完整或使用不支持的压缩方式"))?;
    let u16_at = |i| u16::from_le_bytes([tail[i], tail[i + 1]]);
    let u32_at = |i| u32::from_le_bytes(tail[i..i + 4].try_into().unwrap());
    if u16_at(at + 4) != 0 || u16_at(at + 6) != 0 {
        return Err(invalid("备份 ZIP 无效、不完整或使用不支持的压缩方式"));
    }
    let mut members = u16_at(at + 10) as u64;
    let mut bytes = u32_at(at + 12) as u64;
    if members == u16::MAX as u64 || bytes == u32::MAX as u64 {
        let end = length - count + at as u64;
        if end < 20 {
            return Err(invalid("备份清单无效"));
        }
        file.seek(SeekFrom::Start(end - 20))?;
        let mut locator = [0; 20];
        file.read_exact(&mut locator)?;
        if &locator[..4] != b"PK\x06\x07" {
            return Err(invalid("备份清单无效"));
        }
        let offset = u64::from_le_bytes(locator[8..16].try_into().unwrap());
        if offset > length.saturating_sub(56) {
            return Err(invalid("备份清单无效"));
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut header = [0; 56];
        file.read_exact(&mut header)?;
        if &header[..4] != b"PK\x06\x06" {
            return Err(invalid("备份清单无效"));
        }
        members = u64::from_le_bytes(header[32..40].try_into().unwrap());
        bytes = u64::from_le_bytes(header[40..48].try_into().unwrap());
    }
    if members > MAX_MEMBERS as u64 || bytes > 64 * 1024 * 1024 {
        return Err(invalid("备份超过成员数量上限"));
    }
    file.seek(SeekFrom::Start(0))?;
    Ok(())
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct BackupMember {
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub records: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    format: String,
    format_version: u32,
    identity_version: String,
    scope: String,
    members: Vec<BackupMember>,
}
fn manifest(text: &str) -> Result<Manifest> {
    let value: Manifest = serde_json::from_str(text).map_err(|_| invalid("备份清单无效"))?;
    if value.format != "moonread-backup"
        || value.format_version != 1
        || value.identity_version != "normalization-v1"
        || value.scope != "all"
    {
        return Err(invalid("备份版本或能力不受支持，请更新 App"));
    }
    if value.members.len() >= MAX_MEMBERS {
        return Err(invalid("备份超过成员数量上限"));
    }
    let mut names = HashSet::new();
    let mut total = 0u64;
    for m in &value.members {
        safe_name(&m.path)?;
        parse_sha256(m.sha256.clone()).map_err(|_| invalid("备份清单摘要无效"))?;
        if m.path == "manifest.json" || !names.insert(m.path.to_ascii_lowercase()) {
            return Err(invalid("备份有重复成员"));
        }
        total = total
            .checked_add(m.size)
            .ok_or_else(|| invalid("备份超过大小上限"))?;
        if m.size > limit(&m.path) || total > MAX_TOTAL {
            return Err(invalid("备份超过解包大小上限"));
        }
    }
    if RECORDS.iter().any(|p| !names.contains(*p)) {
        return Err(invalid("备份缺少记录成员"));
    }
    Ok(value)
}
fn copy_hash<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    name: &str,
) -> Result<BackupMember> {
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut records = 0u64;
    let mut line = 0u64;
    let mut buffer = [0; 65536];
    loop {
        let n = reader.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        if bytes > limit(name) {
            return Err(invalid("备份超过成员大小上限"));
        }
        if RECORDS.contains(&name) {
            for b in &buffer[..n] {
                if *b == b'\n' {
                    if line == 0 {
                        return Err(invalid("备份包含空记录"));
                    }
                    records += 1;
                    line = 0;
                } else {
                    line += 1;
                    if line > MAX_RECORD {
                        return Err(invalid("备份超过单记录大小上限"));
                    }
                }
            }
        }
        hash.update(&buffer[..n]);
        writer.write_all(&buffer[..n])?;
    }
    if line > 0 {
        records += 1;
    }
    Ok(BackupMember {
        path: name.into(),
        size: bytes,
        sha256: crate::sha256_hex(hash.finalize()),
        records,
    })
}
fn matches(a: &BackupMember, b: &BackupMember) -> Result<()> {
    if a.size != b.size || a.sha256 != b.sha256 || a.records != b.records {
        return Err(invalid("备份成员大小、摘要或记录数量不符"));
    }
    Ok(())
}
#[derive(Debug, uniffi::Record)]
pub struct BackupArchiveInfo {
    pub directory: String,
    pub manifest_json: String,
}

#[uniffi::export]
pub fn backup_member(path: String, file_path: String) -> Result<BackupMember> {
    safe_name(&path)?;
    copy_hash(&mut File::open(file_path)?, &mut std::io::sink(), &path)
}
#[uniffi::export]
pub fn inspect_backup(archive_path: String, staging_root: String) -> Result<BackupArchiveInfo> {
    let mut file = File::open(archive_path)?;
    preflight_directory(&mut file)?;
    let mut zip = zipped(ZipArchive::new(file))?;
    if zip.len() > MAX_MEMBERS {
        return Err(invalid("备份超过成员数量上限"));
    }
    zipped(zip.validate_header_consistency())?; // Reject duplicate names and overlapping/header-mismatched entries.
    let text = {
        let mut entry = zipped(zip.by_name("manifest.json"))?;
        if entry.size() > MAX_RECORD {
            return Err(invalid("备份清单超过大小上限"));
        }
        let mut data = Vec::new();
        copy_hash(&mut entry, &mut data, "manifest.json")?;
        String::from_utf8(data).map_err(|_| invalid("备份清单不是 UTF-8"))?
    };
    let value = manifest(&text)?;
    if zip.len() != value.members.len() + 1 {
        return Err(invalid("备份包含未列成员"));
    }
    // Preflight every member before making any directory from archive input.
    let mut names = HashSet::new();
    let members: HashMap<_, _> = value
        .members
        .iter()
        .map(|m| (m.path.as_str(), m.size))
        .collect();
    for i in 0..zip.len() {
        let entry = zipped(zip.by_index(i))?;
        let name = zipped(entry.name())?;
        safe_name(&name)?;
        if !names.insert(name.to_ascii_lowercase())
            || !entry.is_file()
            || entry.is_symlink()
            || entry.encrypted()
        {
            return Err(invalid("备份包含链接、重复或非普通文件"));
        }
        if entry.size() > limit(&name) {
            return Err(invalid("备份成员超过大小上限"));
        }
        if name != "manifest.json" && members.get(name.as_ref()).copied() != Some(entry.size()) {
            return Err(invalid("备份成员与清单不符"));
        }
    }
    let directory = Path::new(&staging_root).join(uuid::Uuid::new_v4().to_string());
    fs::create_dir_all(&staging_root)?;
    fs::create_dir(&directory)?;
    let result = (|| {
        fs::write(directory.join("manifest.json"), &text)?;
        for member in &value.members {
            let path = directory.join(&member.path);
            fs::create_dir_all(path.parent().ok_or_else(|| invalid("备份路径无效"))?)?;
            let mut output = OpenOptions::new().write(true).create_new(true).open(path)?;
            let actual = copy_hash(
                &mut zipped(zip.by_name(&member.path))?,
                &mut output,
                &member.path,
            )?;
            matches(member, &actual)?;
        }
        Ok(BackupArchiveInfo {
            directory: directory.to_string_lossy().into(),
            manifest_json: text,
        })
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(directory);
    }
    result
}
#[uniffi::export]
pub fn write_backup(staging_directory: String, destination: String) -> Result<()> {
    let root = Path::new(&staging_directory).canonicalize()?;
    let bytes = fs::read(root.join("manifest.json"))?;
    if bytes.len() as u64 > MAX_RECORD {
        return Err(invalid("备份清单超过大小上限"));
    }
    let value = manifest(std::str::from_utf8(&bytes).map_err(|_| invalid("备份清单不是 UTF-8"))?)?;
    let file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&destination)?;
    let result = (|| {
        let mut zip = ZipWriter::new(file);
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(0o600);
        zipped(zip.start_file("manifest.json", options))?;
        zip.write_all(&bytes)?;
        for member in value.members {
            let path = root.join(&member.path);
            if fs::symlink_metadata(&path)?.file_type().is_symlink()
                || !path.canonicalize()?.starts_with(&root)
            {
                return Err(invalid("备份暂存含不安全成员"));
            }
            zipped(zip.start_file(&member.path, options))?;
            matches(
                &member,
                &copy_hash(&mut File::open(path)?, &mut zip, &member.path)?,
            )?;
        }
        let file = zipped(zip.finish())?;
        file.sync_all()?;
        if file.metadata()?.len() > MAX_ARCHIVE {
            return Err(invalid("备份超过压缩包大小上限"));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(destination);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn snapshot(root: &Path) -> serde_json::Value {
        fs::create_dir_all(root.join("records")).unwrap();
        let mut members = Vec::new();
        for path in RECORDS {
            fs::write(
                root.join(path),
                if path == RECORDS[0] {
                    &b"{}\n"[..]
                } else {
                    &b""[..]
                },
            )
            .unwrap();
            members.push(
                backup_member(path.into(), root.join(path).to_string_lossy().into()).unwrap(),
            );
        }
        json!({"format":"moonread-backup","formatVersion":1,"identityVersion":"normalization-v1","scope":"all","requiredCapabilities":["user-facts-v1"],"members":members})
    }
    fn package(path: &Path, manifest: &serde_json::Value, extra: Option<(&str, &[u8])>) {
        let mut zip = ZipWriter::new(File::create(path).unwrap());
        let options = SimpleFileOptions::default();
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(manifest.to_string().as_bytes()).unwrap();
        for path in RECORDS {
            zip.start_file(path, options).unwrap();
            if path == RECORDS[0] {
                zip.write_all(b"{}\n").unwrap();
            }
        }
        if let Some((name, bytes)) = extra {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap();
    }
    #[test]
    fn portable_backup_roundtrip_preserves_bytes_and_optional_extensions() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("input");
        let mut manifest = snapshot(&root);
        fs::create_dir_all(root.join("extensions")).unwrap();
        fs::write(root.join("extensions/future.json"), b"{\"future\":true}").unwrap();
        let extension = backup_member(
            "extensions/future.json".into(),
            root.join("extensions/future.json").to_string_lossy().into(),
        )
        .unwrap();
        manifest["members"]
            .as_array_mut()
            .unwrap()
            .push(serde_json::to_value(extension).unwrap());
        fs::write(root.join("manifest.json"), manifest.to_string()).unwrap();
        let archive = dir.path().join("all.moonread-backup");
        write_backup(
            root.to_string_lossy().into(),
            archive.to_string_lossy().into(),
        )
        .unwrap();
        let restored = inspect_backup(
            archive.to_string_lossy().into(),
            dir.path().join("stage").to_string_lossy().into(),
        )
        .unwrap();
        assert_eq!(restored.manifest_json, manifest.to_string());
        assert_eq!(
            fs::read(Path::new(&restored.directory).join("extensions/future.json")).unwrap(),
            b"{\"future\":true}"
        );
        assert_eq!(
            fs::read(Path::new(&restored.directory).join(RECORDS[0])).unwrap(),
            b"{}\n"
        );
    }
    #[test]
    fn unsafe_incomplete_or_over_budget_backup_never_writes_outside_staging() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("input");
        let good = snapshot(&root);
        let outside = dir.path().join("outside");
        fs::write(&outside, b"keep").unwrap();
        let stage = dir.path().join("stage");
        for case in [
            "traversal",
            "absolute",
            "duplicate",
            "unlisted",
            "size",
            "digest",
            "truncated",
            "link",
        ] {
            let archive = dir.path().join(format!("{case}.zip"));
            let mut manifest = good.clone();
            let extra = match case {
                "traversal" => Some(("../outside", b"replace".as_slice())),
                "absolute" => Some(("/outside", b"replace".as_slice())),
                "unlisted" => Some(("extensions/extra", b"extra".as_slice())),
                "duplicate" => Some(("records/second.jsonl", b"{}\n".as_slice())),
                _ => None,
            };
            if case == "size" {
                manifest["members"][0]["size"] = json!(u64::MAX);
            }
            if case == "digest" {
                manifest["members"][0]["sha256"] = json!("a".repeat(64));
            }
            package(&archive, &manifest, extra);
            if case == "truncated" {
                let f = OpenOptions::new().write(true).open(&archive).unwrap();
                f.set_len(20).unwrap();
            }
            if case == "duplicate" {
                let mut bytes = fs::read(&archive).unwrap();
                let name = b"records/second.jsonl";
                for i in 0..bytes.len() - name.len() {
                    if &bytes[i..i + name.len()] == name {
                        bytes[i..i + name.len()].copy_from_slice(b"records/values.jsonl");
                    }
                }
                fs::write(&archive, bytes).unwrap();
            }
            if case == "link" {
                let mut zip = ZipWriter::new(File::create(&archive).unwrap());
                let o = SimpleFileOptions::default();
                zip.start_file("manifest.json", o).unwrap();
                zip.write_all(good.to_string().as_bytes()).unwrap();
                for path in RECORDS {
                    if path == RECORDS[0] {
                        zip.add_symlink(path, "../outside", o).unwrap();
                    } else {
                        zip.start_file(path, o).unwrap();
                    }
                }
                zip.finish().unwrap();
            }
            assert!(
                inspect_backup(
                    archive.to_string_lossy().into(),
                    stage.to_string_lossy().into()
                )
                .is_err(),
                "{case}"
            );
            assert_eq!(fs::read(&outside).unwrap(), b"keep");
            if stage.exists() {
                assert_eq!(fs::read_dir(&stage).unwrap().count(), 0, "{case}");
            }
        }
        let mut line = std::io::Cursor::new(vec![b'x'; MAX_RECORD as usize + 1]);
        assert!(copy_hash(&mut line, &mut std::io::sink(), RECORDS[0]).is_err());
    }
}
