use super::{MetadataFormat, invalid};
use crate::{Result, storage::maintenance::archive_limits::*};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use zip::{ZipWriter, write::SimpleFileOptions};

fn limit(name: &str) -> u64 {
    if name.starts_with("covers/") {
        MAX_ASSET
    } else if name == "README.txt" {
        MAX_RECORD
    } else {
        MAX_TOTAL
    }
}
pub(super) fn cover_path(name: &str) -> bool {
    safe_relative_member(name).is_ok()
        && name.starts_with("covers/")
        && ["jpg", "jpeg", "png"]
            .iter()
            .any(|e| name.ends_with(&format!(".{e}")))
}

/// Both protocols use the same path, symlink, central-directory and byte gates.
pub(super) fn unpack(input: &Path, root: &Path) -> Result<(PathBuf, MetadataFormat, Vec<String>)> {
    let mut zip = open_archive(input, true, limit)
        .map_err(|_| invalid("小说信息ZIP无效、路径不安全或超过公共资源预算"))?;
    let mut manifest = None;
    let mut warnings = Vec::new();
    let mut total = 0u64;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|_| invalid("小说信息ZIP无法读取"))?;
        let name = entry
            .name()
            .map_err(|_| invalid("小说信息ZIP成员名无法读取"))?
            .into_owned();
        if entry.is_dir() {
            continue;
        }
        let format = match name.as_str() {
            "metadata.json" => Some(MetadataFormat::Json),
            "metadata.jsonl" => Some(MetadataFormat::Jsonl),
            _ => None,
        };
        if let Some(format) = format {
            if manifest.is_some() {
                return Err(invalid("包中只能有一个metadata.json或metadata.jsonl"));
            }
            manifest = Some((root.join(&name), format));
        }
        let used = format.is_some() || cover_path(&name) || name == "README.txt";
        if !used && !name.starts_with("__MACOSX/") && !name.split('/').any(|p| p.starts_with('.')) {
            warnings.push(name.clone());
        }
        let mut output: Box<dyn Write> = if used {
            let path = root.join(&name);
            fs::create_dir_all(path.parent().ok_or_else(|| invalid("包路径无效"))?)?;
            Box::new(OpenOptions::new().create_new(true).write(true).open(path)?)
        } else {
            Box::new(std::io::sink())
        };
        let copied = std::io::copy(&mut entry.by_ref().take(limit(&name) + 1), &mut output)
            .map_err(|_| invalid("ZIP成员损坏或CRC错误"))?;
        total = total
            .checked_add(copied)
            .ok_or_else(|| invalid("超过公共资源预算"))?;
        if copied > limit(&name) || total > MAX_TOTAL || copied != entry.size() {
            return Err(invalid("超过公共资源预算或ZIP成员大小不符"));
        }
    }
    let (path, format) =
        manifest.ok_or_else(|| invalid("包中缺少metadata.json或metadata.jsonl"))?;
    Ok((path, format, warnings))
}

/// The caller supplies a private export directory; only admitted members enter ZIP.
#[uniffi::export]
pub fn write_metadata_archive(staging_directory: String, destination: String) -> Result<()> {
    let root = Path::new(&staging_directory).canonicalize()?;
    let mut members = Vec::new();
    fn collect(root: &Path, dir: &Path, members: &mut Vec<String>) -> Result<()> {
        for file in fs::read_dir(dir)? {
            let file = file?;
            let kind = file.file_type()?;
            if kind.is_symlink() {
                return Err(invalid("暂存中含链接"));
            }
            if kind.is_dir() {
                collect(root, &file.path(), members)?;
            } else if kind.is_file() {
                let name = file
                    .path()
                    .strip_prefix(root)
                    .map_err(|_| invalid("暂存路径无效"))?
                    .to_str()
                    .ok_or_else(|| invalid("暂存路径无效"))?
                    .to_owned();
                safe_relative_member(&name).map_err(|_| invalid("暂存路径无效"))?;
                if !["metadata.json", "metadata.jsonl", "README.txt"].contains(&name.as_str())
                    && !cover_path(&name)
                {
                    return Err(invalid("导出暂存中含未知成员"));
                }
                members.push(name);
            } else {
                return Err(invalid("暂存中含非普通文件"));
            }
        }
        Ok(())
    }
    collect(&root, &root, &mut members)?;
    if members.len() > MAX_MEMBERS
        || members
            .iter()
            .filter(|s| s.as_str() == "metadata.json" || s.as_str() == "metadata.jsonl")
            .count()
            != 1
    {
        return Err(invalid("清单数量或成员数量无效"));
    }
    let output = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&destination)?;
    let result = (|| {
        let mut zip = ZipWriter::new(output);
        let mut total = 0u64;
        let mut names = std::collections::HashSet::new();
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated)
            .unix_permissions(0o600);
        for name in members {
            if !names.insert(name.to_lowercase()) {
                return Err(invalid("重复成员"));
            }
            let mut file = File::open(root.join(&name))?;
            zip.start_file(&name, options)
                .map_err(|_| invalid("无法写入小说信息ZIP"))?;
            let copied = std::io::copy(
                &mut Read::by_ref(&mut file).take(limit(&name) + 1),
                &mut zip,
            )?;
            total = total
                .checked_add(copied)
                .ok_or_else(|| invalid("超过公共资源预算"))?;
            if copied > limit(&name) || total > MAX_TOTAL {
                return Err(invalid("超过公共资源预算"));
            }
        }
        let file = zip.finish().map_err(|_| invalid("无法完成小说信息ZIP"))?;
        file.sync_all()?;
        if file.metadata()?.len() > MAX_ARCHIVE {
            return Err(invalid("超过公共压缩包预算"));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(destination);
    }
    result
}
