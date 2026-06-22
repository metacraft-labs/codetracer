//! CoW namespace reader/writer helpers for production `memwrites.tc` images.
//!
//! The live lazy materialization path writes `memwrites.tc` as an `NSB1`
//! copy-on-write namespace whose keys are memory addresses. Each Type-B
//! descriptor is `[payload_offset:u64][payload_len:u64]` and points at an
//! appended payload with the variable-size write records for that address.
//!
//! The payload keeps the sparse `interval_id` next to every value record:
//! `[interval_id:u32][tick:u64][pc:u64][size:u32][old_value:u64][new_value:u64]`.
//! Current warm-restart callers can flatten this back to `(address, write)`,
//! while the stored image preserves the information needed for sparse sub-list
//! reconstruction.

use super::cow_namespace_reader::{CowLeafType, CowNamespaceReader, CowNsError, PAGE_SIZE};
use super::cow_namespace_writer::{CowNamespaceWriter, CowWriteError};
use super::interval_tagged_map::{IntervalTaggedMap, MemWriteEntry};

pub const CTFS_MEMWRITES_COW_FILE: &str = "memwrites.tc";

const RECORD_SIZE: usize = 4 + 8 + 8 + 4 + 8 + 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MemwritesNsError {
    Cow(CowNsError),
    Write(CowWriteError),
    BadDescriptor(usize),
    PayloadOutOfBounds { offset: usize, len: usize },
    BadPayloadLen(usize),
    EmptyImage,
}

impl std::fmt::Display for MemwritesNsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MemwritesNsError::Cow(e) => write!(f, "memwrites namespace index: {e}"),
            MemwritesNsError::Write(e) => write!(f, "memwrites namespace writer: {e}"),
            MemwritesNsError::BadDescriptor(n) => {
                write!(f, "memwrites descriptor has {n} bytes, expected 16")
            }
            MemwritesNsError::PayloadOutOfBounds { offset, len } => {
                write!(f, "memwrites payload [{offset}, {}) out of bounds", offset + len)
            }
            MemwritesNsError::BadPayloadLen(n) => {
                write!(f, "memwrites payload has {n} bytes, not a whole record array")
            }
            MemwritesNsError::EmptyImage => write!(f, "memwrites namespace image is empty"),
        }
    }
}

impl std::error::Error for MemwritesNsError {}

impl From<CowNsError> for MemwritesNsError {
    fn from(e: CowNsError) -> Self {
        MemwritesNsError::Cow(e)
    }
}

impl From<CowWriteError> for MemwritesNsError {
    fn from(e: CowWriteError) -> Self {
        MemwritesNsError::Write(e)
    }
}

fn read_u32(buf: &[u8], off: usize) -> u32 {
    let mut bytes = [0u8; 4];
    bytes.copy_from_slice(&buf[off..off + 4]);
    u32::from_le_bytes(bytes)
}

fn read_u64(buf: &[u8], off: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&buf[off..off + 8]);
    u64::from_le_bytes(bytes)
}

fn descriptor(offset: usize, len: usize) -> [u8; 16] {
    let mut d = [0u8; 16];
    d[0..8].copy_from_slice(&(offset as u64).to_le_bytes());
    d[8..16].copy_from_slice(&(len as u64).to_le_bytes());
    d
}

fn encode_record(interval_id: u32, write: &MemWriteEntry, out: &mut Vec<u8>) {
    out.extend_from_slice(&interval_id.to_le_bytes());
    out.extend_from_slice(&write.tick.to_le_bytes());
    out.extend_from_slice(&write.pc.to_le_bytes());
    out.extend_from_slice(&write.size.to_le_bytes());
    out.extend_from_slice(&write.old_value.to_le_bytes());
    out.extend_from_slice(&write.new_value.to_le_bytes());
}

fn decode_records(payload: &[u8]) -> Result<Vec<(u32, MemWriteEntry)>, MemwritesNsError> {
    if !payload.len().is_multiple_of(RECORD_SIZE) {
        return Err(MemwritesNsError::BadPayloadLen(payload.len()));
    }
    let mut out = Vec::with_capacity(payload.len() / RECORD_SIZE);
    for record in payload.chunks_exact(RECORD_SIZE) {
        let interval_id = read_u32(record, 0);
        let tick = read_u64(record, 4);
        let pc = read_u64(record, 12);
        let size = read_u32(record, 20);
        let old_value = read_u64(record, 24);
        let new_value = read_u64(record, 32);
        out.push((
            interval_id,
            MemWriteEntry {
                tick,
                pc,
                size,
                old_value,
                new_value,
            },
        ));
    }
    Ok(out)
}

/// Build a production CoW `memwrites.tc` image from a sparse interval-tagged map.
pub fn encode_memwrites_cow_namespace(
    map: &IntervalTaggedMap<MemWriteEntry>,
) -> Result<Option<Vec<u8>>, MemwritesNsError> {
    if map.is_empty() {
        return Ok(None);
    }

    let keys = map.keys();
    let mut sizing = CowNamespaceWriter::new(CowLeafType::TypeB, true);
    for key in &keys {
        sizing.insert_and_commit(*key, &[0u8; 16])?;
    }
    let payload_base = sizing.serialize().len();

    let mut writer = CowNamespaceWriter::new(CowLeafType::TypeB, true);
    let mut payload = Vec::new();
    for key in keys {
        let offset = payload_base + payload.len();
        let before = payload.len();
        for (interval_id, records) in map.records_by_interval(key) {
            for record in records {
                encode_record(interval_id, &record, &mut payload);
            }
        }
        writer.insert_and_commit(key, &descriptor(offset, payload.len() - before))?;
    }

    let mut image = writer.serialize();
    image.extend_from_slice(&payload);
    while !image.len().is_multiple_of(PAGE_SIZE) {
        image.push(0);
    }
    Ok(Some(image))
}

/// Read-only view of a CoW-backed `memwrites.tc` namespace image.
pub struct MemwritesNamespace<'a> {
    image: &'a [u8],
    index: Option<CowNamespaceReader<'a>>,
}

impl<'a> MemwritesNamespace<'a> {
    pub fn open(image: &'a [u8]) -> Result<Self, MemwritesNsError> {
        if image.is_empty() {
            return Err(MemwritesNsError::EmptyImage);
        }
        let index = match CowNamespaceReader::open(image, CowLeafType::TypeB) {
            Ok(index) => Some(index),
            Err(CowNsError::Empty) => None,
            Err(e) => return Err(e.into()),
        };
        Ok(MemwritesNamespace { image, index })
    }

    /// Return every write stored for one address, preserving interval ids.
    pub fn writes_for_address(&self, address: u64) -> Result<Vec<(u32, MemWriteEntry)>, MemwritesNsError> {
        let Some(index) = &self.index else {
            return Ok(Vec::new());
        };
        let desc = match index.lookup(address) {
            Ok(desc) => desc,
            Err(CowNsError::KeyNotFound(_)) => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        if desc.len() != 16 {
            return Err(MemwritesNsError::BadDescriptor(desc.len()));
        }
        let offset = read_u64(desc, 0) as usize;
        let len = read_u64(desc, 8) as usize;
        let payload = self
            .image
            .get(offset..offset.saturating_add(len))
            .ok_or(MemwritesNsError::PayloadOutOfBounds { offset, len })?;
        decode_records(payload)
    }

    /// Flatten every key in the namespace to the legacy warm-restart shape.
    pub fn all_writes(&self) -> Result<Vec<(u64, MemWriteEntry)>, MemwritesNsError> {
        let Some(index) = &self.index else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for address in index.keys()? {
            for (_, write) in self.writes_for_address(address)? {
                out.push((address, write));
            }
        }
        out.sort_by_key(|(address, write)| (*address, write.tick));
        Ok(out)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    const ADDR: u64 = 0x4000;

    fn mw(tick: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc: 0xCAFE,
            size: 8,
            old_value: 0,
            new_value,
        }
    }

    fn mw_full(tick: u64, pc: u64, size: u32, old_value: u64, new_value: u64) -> MemWriteEntry {
        MemWriteEntry {
            tick,
            pc,
            size,
            old_value,
            new_value,
        }
    }

    #[test]
    fn cow_memwrites_roundtrip_preserves_interval_ids() {
        let mut map = IntervalTaggedMap::new();
        map.append(ADDR, 7, mw_full(700, 0xA007, 8, 0x10, 0x11));
        map.append(ADDR, 3, mw_full(300, 0xA003, 4, 0x20, 0x21));
        map.append(ADDR + 8, 7, mw_full(710, 0xB007, 1, 0x30, 0x31));

        let image = encode_memwrites_cow_namespace(&map).unwrap().expect("image");
        assert_eq!(&image[0..4], b"NSB1");

        let ns = MemwritesNamespace::open(&image).expect("open");
        assert_eq!(
            ns.writes_for_address(ADDR).unwrap(),
            vec![
                (3, mw_full(300, 0xA003, 4, 0x20, 0x21)),
                (7, mw_full(700, 0xA007, 8, 0x10, 0x11))
            ]
        );
        assert_eq!(
            ns.writes_for_address(ADDR + 8).unwrap(),
            vec![(7, mw_full(710, 0xB007, 1, 0x30, 0x31))]
        );
        assert_eq!(
            ns.writes_for_address(0xDEAD).unwrap(),
            Vec::<(u32, MemWriteEntry)>::new()
        );

        let flat = ns.all_writes().unwrap();
        assert_eq!(
            flat.iter().map(|(_, w)| w.tick).collect::<Vec<_>>(),
            vec![300, 700, 710]
        );
    }

    #[test]
    fn empty_map_writes_no_memwrites_file() {
        let map: IntervalTaggedMap<MemWriteEntry> = IntervalTaggedMap::new();
        assert_eq!(encode_memwrites_cow_namespace(&map).unwrap(), None);
    }

    #[test]
    fn rejects_legacy_wlog_blob_as_cow_namespace() {
        let result = MemwritesNamespace::open(b"WLOG legacy");
        assert!(matches!(result, Err(MemwritesNsError::Cow(_))));
    }
}
