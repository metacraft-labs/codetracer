//! CoW namespace reader for production `linehits.tc` images.
//!
//! M8 wires the Nim `MultiStreamTraceWriter` line-hit builder to emit
//! `linehits.tc` as an `NSB1` copy-on-write namespace. The B-tree itself stores
//! fixed-width Type-B descriptors: `[payload_offset:u64][payload_len:u64]`.
//! Payload bytes are appended after the page-aligned B-tree image and contain
//! the varint-encoded step ids for one global line index.

use super::cow_namespace_reader::{CowLeafType, CowNamespaceReader, CowNsError};
use super::ctfs_container::{CtfsError, CtfsReader};
use crate::omniscient_db::{OmniscientDb, Tick, WriteRecord};

/// The CTFS internal-file name for the production line-hit namespace.
pub const CTFS_LINEHITS_COW_FILE: &str = "linehits.tc";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinehitsNsError {
    Cow(CowNsError),
    Container(String),
    BadDescriptor(usize),
    PayloadOutOfBounds { offset: usize, len: usize },
    VarintEof,
    VarintTooLong,
}

impl std::fmt::Display for LinehitsNsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LinehitsNsError::Cow(e) => write!(f, "linehits namespace index: {e}"),
            LinehitsNsError::Container(e) => write!(f, "linehits namespace container: {e}"),
            LinehitsNsError::BadDescriptor(n) => write!(f, "linehits descriptor has {n} bytes, expected 16"),
            LinehitsNsError::PayloadOutOfBounds { offset, len } => {
                write!(f, "linehits payload [{offset}, {}) out of bounds", offset + len)
            }
            LinehitsNsError::VarintEof => write!(f, "linehits payload ended inside a varint"),
            LinehitsNsError::VarintTooLong => write!(f, "linehits payload varint exceeds 10 bytes"),
        }
    }
}

impl std::error::Error for LinehitsNsError {}

impl From<CowNsError> for LinehitsNsError {
    fn from(e: CowNsError) -> Self {
        LinehitsNsError::Cow(e)
    }
}

impl From<CtfsError> for LinehitsNsError {
    fn from(e: CtfsError) -> Self {
        LinehitsNsError::Container(e.to_string())
    }
}

/// Read-only view of a CoW-backed `linehits.tc` namespace image.
pub struct LinehitsNamespace<'a> {
    image: &'a [u8],
    index: Option<CowNamespaceReader<'a>>,
}

fn read_u64(buf: &[u8], off: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&buf[off..off + 8]);
    u64::from_le_bytes(bytes)
}

fn read_varint(buf: &[u8], pos: &mut usize) -> Result<u64, LinehitsNsError> {
    let mut result = 0u64;
    let mut shift = 0u32;
    for _ in 0..10 {
        let b = *buf.get(*pos).ok_or(LinehitsNsError::VarintEof)?;
        *pos += 1;
        result |= ((b & 0x7F) as u64) << shift;
        if b & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
    }
    Err(LinehitsNsError::VarintTooLong)
}

impl<'a> LinehitsNamespace<'a> {
    /// Open a production CoW `linehits.tc` image.
    pub fn open(image: &'a [u8]) -> Result<Self, LinehitsNsError> {
        let index = match CowNamespaceReader::open(image, CowLeafType::TypeB) {
            Ok(index) => Some(index),
            Err(CowNsError::Empty) => None,
            Err(e) => return Err(e.into()),
        };
        Ok(LinehitsNamespace { image, index })
    }

    /// Return all step ids recorded for `global_line_index`.
    pub fn hits(&self, global_line_index: u64) -> Result<Vec<u64>, LinehitsNsError> {
        let Some(index) = &self.index else {
            return Ok(Vec::new());
        };
        let desc = match index.lookup(global_line_index) {
            Ok(desc) => desc,
            Err(CowNsError::KeyNotFound(_)) => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        if desc.len() != 16 {
            return Err(LinehitsNsError::BadDescriptor(desc.len()));
        }
        let offset = read_u64(desc, 0) as usize;
        let len = read_u64(desc, 8) as usize;
        let payload = self
            .image
            .get(offset..offset.saturating_add(len))
            .ok_or(LinehitsNsError::PayloadOutOfBounds { offset, len })?;
        let mut pos = 0usize;
        let mut hits = Vec::new();
        while pos < payload.len() {
            hits.push(read_varint(payload, &mut pos)?);
        }
        Ok(hits)
    }
}

/// Owned `linehits.tc` namespace loaded from a CTFS container.
#[derive(Debug)]
pub struct OwnedLinehitsNamespace {
    image: Vec<u8>,
}

impl OwnedLinehitsNamespace {
    /// Read `linehits.tc` from a CTFS container and validate that it is a CoW
    /// namespace image. Missing files surface as the underlying container error.
    pub fn open_from_ctfs(reader: &mut CtfsReader) -> Result<Self, LinehitsNsError> {
        let image = reader.read_file(CTFS_LINEHITS_COW_FILE)?;
        match CowNamespaceReader::open(&image, CowLeafType::TypeB) {
            Ok(_) | Err(CowNsError::Empty) => {}
            Err(e) => return Err(e.into()),
        }
        Ok(OwnedLinehitsNamespace { image })
    }

    /// Return all step ids recorded for `global_line_index`.
    pub fn hits(&self, global_line_index: u64) -> Result<Vec<u64>, LinehitsNsError> {
        LinehitsNamespace::open(&self.image)?.hits(global_line_index)
    }
}

fn pack_line_key(file_id: u32, line: u32) -> u64 {
    codetracer_trace_writer::step_stream::pack_global_line_index(file_id as usize, i64::from(line))
}

impl OmniscientDb for OwnedLinehitsNamespace {
    fn last_write_before(&self, _addr: u64, _size: u32, _tick: Tick) -> Option<WriteRecord> {
        None
    }

    fn value_at(&self, _addr: u64, _size: u32, _tick: Tick) -> Option<Vec<u8>> {
        None
    }

    fn writes_in_range(&self, _addr: u64, _size: u32, _tick_min: Tick, _tick_max: Tick) -> Vec<WriteRecord> {
        Vec::new()
    }

    fn source_line_hits(&self, file_id: u32, line: u32) -> Vec<Tick> {
        self.hits(pack_line_key(file_id, line)).unwrap_or_default()
    }

    fn is_present(&self) -> bool {
        true
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::cow_namespace_writer::CowNamespaceWriter;
    use crate::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};

    fn put_varint(mut value: u64, out: &mut Vec<u8>) {
        loop {
            let mut byte = (value & 0x7F) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                break;
            }
        }
    }

    fn descriptor(offset: usize, len: usize) -> [u8; 16] {
        let mut d = [0u8; 16];
        d[0..8].copy_from_slice(&(offset as u64).to_le_bytes());
        d[8..16].copy_from_slice(&(len as u64).to_le_bytes());
        d
    }

    fn image_with_entries(entries: &[(u64, Vec<u64>)]) -> Vec<u8> {
        let mut sizing = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        for (key, _) in entries {
            sizing.insert_and_commit(*key, &[0u8; 16]).unwrap();
        }
        let payload_base = sizing.serialize().len();
        let mut payload = Vec::new();
        let mut writer = CowNamespaceWriter::new(CowLeafType::TypeB, true);
        for (key, values) in entries {
            let offset = payload_base + payload.len();
            let before = payload.len();
            for value in values {
                put_varint(*value, &mut payload);
            }
            writer
                .insert_and_commit(*key, &descriptor(offset, payload.len() - before))
                .unwrap();
        }
        let mut image = writer.serialize();
        image.extend_from_slice(&payload);
        while !image
            .len()
            .is_multiple_of(super::super::cow_namespace_reader::PAGE_SIZE)
        {
            image.push(0);
        }
        image
    }

    #[test]
    fn opens_cow_linehits_namespace() {
        let image = image_with_entries(&[(10, vec![1, 2, 130]), (20, vec![7])]);
        let ns = LinehitsNamespace::open(&image).expect("open");
        assert_eq!(ns.hits(10).unwrap(), vec![1, 2, 130]);
        assert_eq!(ns.hits(20).unwrap(), vec![7]);
    }

    #[test]
    fn opens_empty_cow_linehits_namespace() {
        let image = image_with_entries(&[]);
        let ns = LinehitsNamespace::open(&image).expect("open empty");
        assert_eq!(ns.hits(10).unwrap(), Vec::<u64>::new());
    }

    #[test]
    fn rejects_legacy_namespace_blob() {
        let result = LinehitsNamespace::open(b"NS\x01\x00legacy whole-tree blob");
        assert!(matches!(result, Err(LinehitsNsError::Cow(_))));
    }

    #[test]
    fn opens_cow_linehits_from_ctfs_container() {
        let image = image_with_entries(&[(42, vec![3, 5, 8])]);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("linehits.ct");
        write_minimal_ctfs(&path, &[(CTFS_LINEHITS_COW_FILE, image.as_slice())]).unwrap();

        let mut reader = CtfsReader::open(&path).unwrap();
        let ns = OwnedLinehitsNamespace::open_from_ctfs(&mut reader).expect("open linehits.tc");
        assert_eq!(ns.hits(42).unwrap(), vec![3, 5, 8]);
        assert_eq!(ns.hits(404).unwrap(), Vec::<u64>::new());
    }

    #[test]
    fn omniscient_db_serves_source_line_hits_from_cow_namespace() {
        let key = pack_line_key(7, 100);
        let image = image_with_entries(&[(key, vec![11, 13, 21])]);
        let ns = LinehitsNamespace::open(&image).expect("open linehits namespace");
        assert_eq!(ns.hits(key).unwrap(), vec![11, 13, 21]);

        let owned = OwnedLinehitsNamespace { image };
        assert_eq!(owned.source_line_hits(7, 100), vec![11, 13, 21]);
        assert_eq!(owned.source_line_hits(7, 101), Vec::<u64>::new());
    }
}
