//! Shared transport budgets; metadata exchange does not invent its own limits.
use crate::{ReaderError, Result};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
};

pub(crate) const MAX_ARCHIVE: u64 = 512 * 1024 * 1024;
pub(crate) const MAX_TOTAL: u64 = 2 * 1024 * 1024 * 1024;
pub(crate) const MAX_MEMBERS: usize = 100_000;
pub(crate) const MAX_RECORD: u64 = 16 * 1024 * 1024;
pub(crate) const MAX_ASSET: u64 = 32 * 1024 * 1024;

fn invalid(message: &str) -> ReaderError {
    ReaderError::Backup {
        message: message.into(),
    }
}

pub(crate) fn safe_relative_member(name: &str) -> Result<()> {
    crate::validate_relative_path(name.into(), false).map_err(|_| invalid("备份包含不安全路径"))?;
    if name.contains(':')
        || name.contains('\\')
        || name
            .split('/')
            .any(|s| s.is_empty() || s == "." || s == "..")
    {
        return Err(invalid("备份包含不安全路径"));
    }
    Ok(())
}

pub(crate) fn open_archive(
    path: &std::path::Path,
    allow_directories: bool,
    limit: fn(&str) -> u64,
) -> Result<zip::ZipArchive<File>> {
    let mut file = File::open(path)?;
    preflight_directory(&mut file)?;
    let zipped = |_| invalid("备份 ZIP 无效、不完整或使用不支持的压缩方式");
    let mut zip = zip::ZipArchive::new(file).map_err(zipped)?;
    if zip.len() > MAX_MEMBERS {
        return Err(invalid("备份超过成员数量上限"));
    }
    zip.validate_header_consistency().map_err(zipped)?;
    let mut names = std::collections::HashSet::new();
    let mut total = 0u64;
    for index in 0..zip.len() {
        let entry = zip.by_index(index).map_err(zipped)?;
        let name = entry.name().map_err(zipped)?;
        let path = if entry.is_dir() && allow_directories {
            name.strip_suffix('/').unwrap_or(&name)
        } else {
            &name
        };
        safe_relative_member(path)?;
        let kind = entry.unix_mode().unwrap_or(0) & 0o170000;
        if !names.insert(path.to_lowercase())
            || entry.is_symlink()
            || entry.encrypted()
            || !(entry.is_file() || (allow_directories && entry.is_dir()))
            || ![0, 0o100000, 0o040000].contains(&kind)
        {
            return Err(invalid("备份包含链接、重复或非普通文件"));
        }
        total = total
            .checked_add(entry.size())
            .ok_or_else(|| invalid("备份超过解包大小上限"))?;
        if entry.size() > limit(path) || total > MAX_TOTAL {
            return Err(invalid("备份超过解包大小上限"));
        }
    }
    Ok(zip)
}

// Bound central-directory allocation before the ZIP library parses it. Format
// validity/header consistency is still checked by zip; this is only a budget gate.
pub(crate) fn preflight_directory(file: &mut File) -> Result<()> {
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
