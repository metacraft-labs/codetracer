//! CoW namespace reader for production `linehits.tc` images.
//!
//! M8 wires the Nim `MultiStreamTraceWriter` line-hit builder to emit
//! `linehits.tc` as an `NSB1` copy-on-write namespace. The B-tree itself stores
//! fixed-width Type-B descriptors: `[payload_offset:u64][payload_len:u64]`.
//! Payload bytes are appended after the page-aligned B-tree image and contain
//! the varint-encoded step ids for one global line index.

use codetracer_trace_writer::line_position::LinePositionSpace;

use super::cow_namespace_reader::{CowLeafType, CowNamespaceReader, CowNsError};
use super::cow_namespace_writer::CowNamespaceWriter;
use super::ctfs_container::{CtfsError, CtfsReader};
use super::interval_tagged_map::{IntervalTaggedMap, LineHitEntry};
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

/// Encode live materialized line hits as the production `NSB1` Type-B
/// `linehits.tc` namespace image.
///
/// Sparse interval ids are intentionally flattened at this file boundary: the
/// authoritative production `linehits.tc` reader stores one tick list per global
/// line key. The coverage map remains the source of truth for which tick ranges
/// have been materialized.
pub fn encode_linehits_cow_namespace(map: &IntervalTaggedMap<LineHitEntry>) -> Result<Option<Vec<u8>>, String> {
    if map.is_empty() {
        return Ok(None);
    }

    let keys = map.keys();
    let mut sizing = CowNamespaceWriter::new(CowLeafType::TypeB, true);
    for key in &keys {
        sizing.insert_and_commit(*key, &[0u8; 16]).map_err(|e| e.to_string())?;
    }
    let payload_base = sizing.serialize().len();

    let mut payload = Vec::new();
    let mut writer = CowNamespaceWriter::new(CowLeafType::TypeB, true);
    for key in keys {
        let offset = payload_base + payload.len();
        let before = payload.len();
        let mut hits = map.collapse_key(key);
        hits.sort_by_key(|hit| hit.tick);
        hits.dedup_by_key(|hit| hit.tick);
        for hit in hits {
            put_varint(hit.tick, &mut payload);
        }
        writer
            .insert_and_commit(key, &descriptor(offset, payload.len() - before))
            .map_err(|e| e.to_string())?;
    }

    let mut image = writer.serialize();
    image.extend_from_slice(&payload);
    while !image.len().is_multiple_of(super::cow_namespace_reader::PAGE_SIZE) {
        image.push(0);
    }
    Ok(Some(image))
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
    /// The container's own line-only address space. The writer keys a hit by the
    /// address of the line it happened on, so a query must build the SAME
    /// address from `(file_id, line)` or it looks up a key that was never
    /// written. `None` for a container that registers no paths, where no key can
    /// be built at all.
    space: Option<LinePositionSpace>,
}

impl OwnedLinehitsNamespace {
    /// Read `linehits.tc` from a CTFS container and validate that it is a CoW
    /// namespace image. Missing files surface as the underlying container error.
    ///
    /// The container's path table is read at the same time, because the keys in
    /// this namespace are addresses in the space that table defines.
    pub fn open_from_ctfs(reader: &mut CtfsReader) -> Result<Self, LinehitsNsError> {
        let image = reader.read_file(CTFS_LINEHITS_COW_FILE)?;
        match CowNamespaceReader::open(&image, CowLeafType::TypeB) {
            Ok(_) | Err(CowNsError::Empty) => {}
            Err(e) => return Err(e.into()),
        }
        let space = super::line_position_space::container_line_space(reader);
        Ok(OwnedLinehitsNamespace { image, space })
    }

    /// Return all step ids recorded for `global_line_index`.
    pub fn hits(&self, global_line_index: u64) -> Result<Vec<u64>, LinehitsNsError> {
        LinehitsNamespace::open(&self.image)?.hits(global_line_index)
    }
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
        // The writer keys a hit by the line's address in the trace's own space
        // (`linehits_builder.nim` `recordHit`, called with the same
        // `global_line_index` the step stream carries), so the query must build
        // that address rather than a differently-shaped integer — which matches
        // nothing and returns an empty list with no error anywhere.
        let Some(space) = self.space.as_ref() else {
            return Vec::new();
        };
        let Some(key) = space.global_index_of(file_id as usize, i64::from(line)) else {
            return Vec::new();
        };
        self.hits(key).unwrap_or_default()
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

    /// A query for `(file_id, line)` must build the key the WRITER built for
    /// that location — the line's address in the trace's own space — or it looks
    /// up a key nothing wrote and reports no hits without an error anywhere.
    #[test]
    fn omniscient_db_serves_source_line_hits_from_cow_namespace() {
        let mut space = LinePositionSpace::uniform(8);
        let key = space.global_index(7, 100);
        let image = image_with_entries(&[(key, vec![11, 13, 21])]);
        let ns = LinehitsNamespace::open(&image).expect("open linehits namespace");
        assert_eq!(ns.hits(key).unwrap(), vec![11, 13, 21]);

        let owned = OwnedLinehitsNamespace {
            image,
            space: Some(space),
        };
        assert_eq!(owned.source_line_hits(7, 100), vec![11, 13, 21]);
        assert_eq!(owned.source_line_hits(7, 101), Vec::<u64>::new());
    }

    /// THE MULTI-PATH ARM. Path 0 is where every apportionment of the address
    /// space agrees, so a single-file query cannot see a keying disagreement at
    /// all. Two files, and the hits are on the second.
    #[test]
    fn source_line_hits_finds_a_hit_recorded_in_the_second_file() {
        let mut space = LinePositionSpace::uniform(2);
        // What the Nim `linehits_builder` writes for a step at (path 1, line 12):
        // the same `global_line_index` the step stream carries.
        let key = space.global_index(1, 12);
        assert_eq!(key, 100_011);
        let image = image_with_entries(&[(key, vec![4, 9])]);

        let owned = OwnedLinehitsNamespace {
            image,
            space: Some(space),
        };
        assert_eq!(
            owned.source_line_hits(1, 12),
            vec![4, 9],
            "a breakpoint on the second file's line 12 must find the steps recorded there"
        );
        assert_eq!(owned.source_line_hits(0, 12), Vec::<u64>::new());
    }

    /// A container that registers no paths has no space to key into, and says so
    /// by reporting no hits rather than keying into an invented one.
    #[test]
    fn a_pathless_container_reports_no_hits_rather_than_guessing_a_key() {
        let image = image_with_entries(&[(0, vec![1])]);
        let owned = OwnedLinehitsNamespace { image, space: None };
        assert_eq!(owned.source_line_hits(0, 1), Vec::<u64>::new());
    }

    #[test]
    fn encodes_interval_tagged_linehits_as_cow_namespace() {
        let mut map: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
        map.append(10, 1, LineHitEntry { tick: 30 });
        map.append(10, 0, LineHitEntry { tick: 5 });
        map.append(20, 0, LineHitEntry { tick: 8 });

        let image = encode_linehits_cow_namespace(&map)
            .expect("encode")
            .expect("non-empty image");
        assert_eq!(&image[0..4], b"NSB1");
        let ns = LinehitsNamespace::open(&image).expect("open encoded image");
        assert_eq!(ns.hits(10).unwrap(), vec![5, 30]);
        assert_eq!(ns.hits(20).unwrap(), vec![8]);
    }
}
