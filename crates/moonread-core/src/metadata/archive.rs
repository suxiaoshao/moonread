use super::{
    MetadataArchiveManifest, MetadataFormat, invalid,
    stream::{Input, MetadataInput, MetadataOutput, Output},
};
use crate::{Result, storage::maintenance::archive_limits::*};
use std::{
    io::{Read, Write},
    sync::Arc,
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

#[uniffi::export(with_foreign)]
pub trait MetadataArchiveInput: Send + Sync {
    fn open_member(&self, name: String) -> Result<Arc<dyn MetadataInput>>;
}

#[uniffi::export(with_foreign)]
pub trait MetadataArchiveOutput: Send + Sync {
    fn create_member(&self, name: String) -> Result<Arc<dyn MetadataOutput>>;
}

/// Both protocols use the same path, symlink, central-directory and byte gates.
pub(super) fn unpack(
    input: Input,
    destination: &dyn MetadataArchiveOutput,
) -> Result<(MetadataArchiveManifest, usize)> {
    let mut zip = open_archive_stream(input, true, limit)
        .map_err(|_| invalid("小说信息ZIP无效、路径不安全或超过公共资源预算"))?;
    let mut manifest = None;
    let mut warnings = 0;
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
            manifest = Some(MetadataArchiveManifest {
                name: name.clone(),
                format,
            });
        }
        let used = format.is_some() || cover_path(&name) || name == "README.txt";
        if !used && !name.starts_with("__MACOSX/") && !name.split('/').any(|p| p.starts_with('.')) {
            warnings += 1;
        }
        let mut output: Box<dyn Write> = if used {
            Box::new(Output::new(destination.create_member(name.clone())?))
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
    Ok((
        manifest.ok_or_else(|| invalid("包中缺少metadata.json或metadata.jsonl"))?,
        warnings,
    ))
}

/// The caller enumerates private export staging; only admitted members enter ZIP.
#[uniffi::export]
pub fn encode_metadata_archive(
    members: Vec<String>,
    source: Arc<dyn MetadataArchiveInput>,
    destination: Arc<dyn MetadataOutput>,
) -> Result<()> {
    if members.len() > MAX_MEMBERS
        || members
            .iter()
            .filter(|s| matches!(s.as_str(), "metadata.json" | "metadata.jsonl"))
            .count()
            != 1
    {
        return Err(invalid("清单数量或成员数量无效"));
    }
    let mut zip = ZipWriter::new(Output::new(destination));
    let mut total = 0u64;
    let mut names = std::collections::HashSet::new();
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o600);
    for name in members {
        safe_relative_member(&name).map_err(|_| invalid("暂存路径无效"))?;
        if !matches!(
            name.as_str(),
            "metadata.json" | "metadata.jsonl" | "README.txt"
        ) && !cover_path(&name)
        {
            return Err(invalid("导出暂存中含未知成员"));
        }
        if !names.insert(name.to_lowercase()) {
            return Err(invalid("重复成员"));
        }
        let mut file = Input::new(source.open_member(name.clone())?);
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
    let output = zip.finish().map_err(|_| invalid("无法完成小说信息ZIP"))?;
    if output.length() > MAX_ARCHIVE {
        return Err(invalid("超过公共压缩包预算"));
    }
    Ok(())
}

#[uniffi::export]
pub fn validate_metadata_cover_path(name: String) -> Result<()> {
    if !cover_path(&name) {
        return Err(invalid("封面路径不安全"));
    }
    Ok(())
}
