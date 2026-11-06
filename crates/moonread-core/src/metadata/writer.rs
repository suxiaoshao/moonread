use super::*;
use crate::{Result, storage::maintenance::archive_limits::*};
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Debug)]
struct State {
    file: File,
    format: MetadataFormat,
    first: bool,
    finished: bool,
    budget: u64,
    bytes: u64,
}
#[derive(Debug, uniffi::Object)]
pub struct MetadataExportWriter {
    path: PathBuf,
    state: Mutex<State>,
}
impl Drop for MetadataExportWriter {
    fn drop(&mut self) {
        if self.state.get_mut().is_ok_and(|s| !s.finished) {
            let _ = fs::remove_file(&self.path);
        }
    }
}
#[uniffi::export]
pub fn create_metadata_writer(
    destination: String,
    format: MetadataFormat,
    packaged: bool,
) -> Result<Arc<MetadataExportWriter>> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&destination)?;
    let prefix = if format == MetadataFormat::Json {
        format!(
            "{{\"$schema\":\"{METADATA_SCHEMA_URL}\",\"format\":\"moonread-metadata\",\"version\":1,\"books\":[\n"
        )
    } else {
        String::new()
    };
    file.write_all(prefix.as_bytes())?;
    Ok(Arc::new(MetadataExportWriter {
        path: destination.into(),
        state: Mutex::new(State {
            file,
            format,
            first: true,
            finished: false,
            budget: if packaged { MAX_TOTAL } else { MAX_ARCHIVE },
            bytes: prefix.len() as u64,
        }),
    }))
}
#[uniffi::export]
impl MetadataExportWriter {
    pub fn append(&self, book: MetadataBook) -> Result<()> {
        if book
            .cover
            .as_ref()
            .is_some_and(|p| !super::archive::cover_path(p))
        {
            return Err(invalid("封面路径不安全"));
        }
        let json = encode_metadata_book(book)?;
        if json.len() as u64 > MAX_RECORD {
            return Err(invalid("超过公共单记录资源预算"));
        }
        let mut state = self.state.lock().map_err(|_| invalid("导出已结束"))?;
        if state.finished {
            return Err(invalid("导出已结束"));
        }
        let bytes = state.bytes + json.len() as u64 + 2;
        if bytes > state.budget {
            return Err(invalid("超过公共资源预算"));
        }
        if state.format == MetadataFormat::Json && !state.first {
            state.file.write_all(b",\n")?;
        }
        state.file.write_all(json.as_bytes())?;
        if state.format == MetadataFormat::Jsonl {
            state.file.write_all(b"\n")?;
        }
        state.first = false;
        state.bytes = bytes;
        Ok(())
    }
    pub fn finish(&self) -> Result<()> {
        let mut state = self.state.lock().map_err(|_| invalid("导出已结束"))?;
        if !state.finished {
            if state.format == MetadataFormat::Json {
                state.file.write_all(b"\n]}\n")?;
            }
            state.file.sync_all()?;
            if state.file.metadata()?.len() > state.budget {
                return Err(invalid("超过公共资源预算"));
            }
            state.finished = true;
        }
        Ok(())
    }
}
