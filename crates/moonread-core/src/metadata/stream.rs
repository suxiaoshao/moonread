use crate::Result;
use std::{
    io::{self, Read, Seek, SeekFrom, Write},
    sync::Arc,
};

// Keep buffer transfers bounded independently of ZIP's or the parser's read sizes.
const CHUNK: usize = 64 * 1024;

#[uniffi::export(with_foreign)]
pub trait MetadataInput: Send + Sync {
    fn length(&self) -> u64;
    fn read(&self, offset: u64, count: u32) -> Result<Vec<u8>>;
}

#[uniffi::export(with_foreign)]
pub trait MetadataOutput: Send + Sync {
    fn write(&self, offset: u64, bytes: Vec<u8>) -> Result<()>;
}

pub(super) struct Input {
    stream: Arc<dyn MetadataInput>,
    length: u64,
    position: u64,
}

impl Input {
    pub(super) fn new(stream: Arc<dyn MetadataInput>) -> Self {
        Self {
            length: stream.length(),
            stream,
            position: 0,
        }
    }

    pub(super) fn length(&self) -> u64 {
        self.length
    }
}

impl Read for Input {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count =
            (buffer.len().min(CHUNK) as u64).min(self.length.saturating_sub(self.position)) as u32;
        if count == 0 {
            return Ok(0);
        }
        let bytes = self
            .stream
            .read(self.position, count)
            .map_err(io::Error::other)?;
        if bytes.len() > count as usize {
            return Err(io::Error::other("invalid metadata stream read length"));
        }
        buffer[..bytes.len()].copy_from_slice(&bytes);
        self.position += bytes.len() as u64;
        Ok(bytes.len())
    }
}

pub(super) struct Output {
    stream: Arc<dyn MetadataOutput>,
    length: u64,
    position: u64,
}

impl Output {
    pub(super) fn new(stream: Arc<dyn MetadataOutput>) -> Self {
        Self {
            stream,
            position: 0,
            length: 0,
        }
    }

    pub(super) fn length(&self) -> u64 {
        self.length
    }
}

impl Write for Output {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let count = bytes.len().min(CHUNK);
        self.stream
            .write(self.position, bytes[..count].to_vec())
            .map_err(io::Error::other)?;
        self.position += count as u64;
        self.length = self.length.max(self.position);
        Ok(count)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Seek for Input {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        seek(&mut self.position, self.length, from)
    }
}

impl Seek for Output {
    fn seek(&mut self, from: SeekFrom) -> io::Result<u64> {
        seek(&mut self.position, self.length, from)
    }
}

fn seek(position: &mut u64, length: u64, from: SeekFrom) -> io::Result<u64> {
    *position = match from {
        SeekFrom::Start(offset) => Some(offset),
        SeekFrom::Current(offset) => position.checked_add_signed(offset),
        SeekFrom::End(offset) => length.checked_add_signed(offset),
    }
    .ok_or_else(|| io::Error::other("invalid metadata stream offset"))?;
    Ok(*position)
}
