//! The boundary recording container: `meta.dat`, `jsbound.log`,
//! `jsbound.blb` and `jsbound.chk` (CTFS-Binary-Format.md §4.8,
//! JS-Boundary-Recording.md §5.1, §5.4, §5.5).
//!
//! [`write_container`] is the only container writer (the assembler calls it);
//! [`BoundaryRecording::read`] is a verifying reader: it decodes the log
//! strictly, checks every `jsbound.blb` record against its hash, resolves
//! every `blobref`, and rebuilds `jsbound.chk` from the log and refuses a
//! stored index that disagrees (spec §5.5).

use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use codetracer_ctfs::{CompressionMethod, CtfsReader, CtfsWriter};
use codetracer_trace_writer::meta_dat::{decode_meta_dat, encode_meta_dat, MetaDat};

use crate::decode::{decode_log, DecodeError, DecodedLog, Termination};
use crate::record::{hex, BlobRef, Record};

/// `meta.dat`.
pub const META_MEMBER: &str = "meta.dat";
/// The boundary log.
pub const LOG_MEMBER: &str = "jsbound.log";
/// The content-addressed bodies.
pub const BLB_MEMBER: &str = "jsbound.blb";
/// The checkpoint index.
pub const CHK_MEMBER: &str = "jsbound.chk";
/// The four members, in the container's block order (§4.8 "Block order").
pub const MEMBERS: [&str; 4] = [META_MEMBER, LOG_MEMBER, BLB_MEMBER, CHK_MEMBER];
/// `meta.dat`'s `recorder_id` is this prefix followed by the `vocab`.
pub const RECORDER_ID_PREFIX: &str = "codetracer-js-boundary/";
/// The container block size the assembler writes.
pub const BLOCK_SIZE: u32 = 4096;
/// The root directory the assembler declares: exactly the four members
/// (CTFS-Binary-Format.md §4.8, "a root fixed at creation (four entries)").
pub const ROOT_ENTRIES: u32 = 4;
/// One `jsbound.chk` row: `ordinal:u32, seq:u64, log_offset:u64`.
pub const CHK_ROW_LEN: usize = 20;

/// The `recorder_id` a recording of `vocab` carries.
pub fn recorder_id(vocab: u16) -> String {
    format!("{RECORDER_ID_PREFIX}{vocab}")
}

/// Whether an open container is a JS boundary recording: by member presence
/// plus `recorder_id`, the way §5.1 declares the recording kind (no
/// `meta.dat` flag marks it). A reader that does not replay boundary logs
/// uses this to open such a container as a trace with no steps rather than
/// mistaking it for another kind.
pub fn is_boundary_recording(reader: &mut CtfsReader) -> bool {
    reader.file_size(LOG_MEMBER).is_some()
        && reader
            .read_file(META_MEMBER)
            .ok()
            .and_then(|bytes| decode_meta_dat(&bytes).ok())
            .is_some_and(|meta| meta.recorder_id.starts_with(RECORDER_ID_PREFIX))
}

/// [`is_boundary_recording`] for a file: `false` for anything that is not a
/// readable CTFS container.
pub fn is_boundary_recording_file(path: &Path) -> bool {
    path.is_file() && CtfsReader::open(path).is_ok_and(|mut r| is_boundary_recording(&mut r))
}

/// One row of `jsbound.chk`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointRow {
    pub ordinal: u32,
    pub seq: u64,
    /// Byte offset of the `Checkpoint` frame in `jsbound.log`.
    pub log_offset: u64,
}

/// Derive the checkpoint index from a decoded log (spec §5.5).
pub fn derive_checkpoint_index(log: &DecodedLog) -> Vec<CheckpointRow> {
    log.records
        .iter()
        .zip(&log.offsets)
        .filter_map(|(r, &log_offset)| match r {
            Record::Checkpoint { seq, ordinal, .. } => Some(CheckpointRow {
                ordinal: *ordinal,
                seq: *seq,
                log_offset,
            }),
            _ => None,
        })
        .collect()
}

/// Encode `jsbound.chk`.
pub fn encode_checkpoint_index(rows: &[CheckpointRow]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rows.len() * CHK_ROW_LEN);
    for row in rows {
        out.extend_from_slice(&row.ordinal.to_le_bytes());
        out.extend_from_slice(&row.seq.to_le_bytes());
        out.extend_from_slice(&row.log_offset.to_le_bytes());
    }
    out
}

/// The bodies of `jsbound.blb`, in first-reference order, each hash once.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BlobStore {
    order: Vec<[u8; 32]>,
    bodies: BTreeMap<[u8; 32], Vec<u8>>,
}

impl BlobStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add `body` (if its hash is new) and return its hash.
    pub fn insert(&mut self, body: Vec<u8>) -> [u8; 32] {
        let hash: [u8; 32] = Sha256::digest(&body).into();
        if !self.bodies.contains_key(&hash) {
            self.order.push(hash);
            self.bodies.insert(hash, body);
        }
        hash
    }

    /// The body stored under `hash`.
    pub fn get(&self, hash: &[u8; 32]) -> Option<&[u8]> {
        self.bodies.get(hash).map(Vec::as_slice)
    }

    /// Number of bodies.
    pub fn len(&self) -> usize {
        self.order.len()
    }

    /// Whether there are no bodies.
    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    /// Encode `jsbound.blb`: `sha256:32, len:u64, bytes[len]` per body.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for hash in &self.order {
            let body = &self.bodies[hash];
            out.extend_from_slice(hash);
            out.extend_from_slice(&(body.len() as u64).to_le_bytes());
            out.extend_from_slice(body);
        }
        out
    }

    /// Decode `jsbound.blb`, refusing a truncated record, a body whose hash
    /// is not its key, and a hash stored twice.
    pub fn decode(bytes: &[u8]) -> Result<Self, ContainerError> {
        let mut store = BlobStore::new();
        let mut pos = 0usize;
        while pos < bytes.len() {
            let rest = &bytes[pos..];
            if rest.len() < 40 {
                return Err(ContainerError::Blob(format!(
                    "a record at byte {pos} is truncated"
                )));
            }
            let hash: [u8; 32] = rest[..32].try_into().expect("32 bytes");
            let len = u64::from_le_bytes(rest[32..40].try_into().expect("8 bytes"));
            let body = usize::try_from(len)
                .ok()
                .and_then(|len| rest.get(40..40usize.checked_add(len)?))
                .ok_or_else(|| {
                    ContainerError::Blob(format!("the body at byte {pos} is truncated"))
                })?;
            if store.bodies.contains_key(&hash) {
                return Err(ContainerError::Blob(format!(
                    "hash {} is stored twice",
                    hex(&hash)
                )));
            }
            if store.insert(body.to_vec()) != hash {
                return Err(ContainerError::Blob(format!(
                    "the body at byte {pos} does not hash to its key {}",
                    hex(&hash)
                )));
            }
            pos += 40 + body.len();
        }
        Ok(store)
    }
}

/// Why a boundary recording could not be written or read.
#[derive(Debug, Clone, PartialEq)]
pub enum ContainerError {
    /// The CTFS layer refused.
    Ctfs(String),
    /// A required member is absent.
    MissingMember(&'static str),
    /// A member a boundary recording does not have.
    UnexpectedMember(String),
    /// `meta.dat` does not parse, or does not describe a boundary recording.
    MetaDat(String),
    /// `jsbound.log` was refused by the strict decoder.
    Log(DecodeError),
    /// `jsbound.log` decodes but does not end with `End`.
    LogIncomplete(Termination),
    /// `jsbound.blb` is malformed.
    Blob(String),
    /// A `blobref` names a body `jsbound.blb` does not hold, or holds at
    /// another length.
    MissingBlob(String),
    /// `jsbound.chk` disagrees with the index rebuilt from the log.
    CheckpointIndexMismatch(String),
}

impl fmt::Display for ContainerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ContainerError::Ctfs(e) => write!(f, "CTFS: {e}"),
            ContainerError::MissingMember(m) => write!(f, "the container has no {m} member"),
            ContainerError::UnexpectedMember(m) => {
                write!(
                    f,
                    "the container has a member {m:?}, which a boundary recording does not"
                )
            }
            ContainerError::MetaDat(e) => write!(f, "meta.dat: {e}"),
            ContainerError::Log(e) => write!(f, "jsbound.log: {e}"),
            ContainerError::LogIncomplete(t) => {
                write!(f, "jsbound.log is {}, not Complete", t.name())
            }
            ContainerError::Blob(e) => write!(f, "jsbound.blb: {e}"),
            ContainerError::MissingBlob(e) => write!(f, "{e}"),
            ContainerError::CheckpointIndexMismatch(e) => write!(f, "jsbound.chk: {e}"),
        }
    }
}

impl std::error::Error for ContainerError {}

fn ctfs<E: fmt::Debug>(e: E) -> ContainerError {
    ContainerError::Ctfs(format!("{e:?}"))
}

/// Check that every `blobref` of kind 1 in `records` names a body of that
/// length in `blobs` (spec §5.3 rule 5).
pub fn check_blob_refs(records: &[Record], blobs: &BlobStore) -> Result<(), ContainerError> {
    for r in records {
        if let Some(BlobRef::Ref { sha256, len }) = r.blob() {
            match blobs.get(sha256) {
                None => {
                    return Err(ContainerError::MissingBlob(format!(
                        "{} references body {} which jsbound.blb does not hold",
                        r.kind_name(),
                        hex(sha256)
                    )))
                }
                Some(body) if body.len() as u64 != *len => {
                    return Err(ContainerError::MissingBlob(format!(
                        "{} references body {} as {len} bytes, but jsbound.blb holds {}",
                        r.kind_name(),
                        hex(sha256),
                        body.len()
                    )))
                }
                Some(_) => {}
            }
        }
    }
    Ok(())
}

/// The four members' bytes, ready to be placed in a container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Members {
    pub meta_dat: Vec<u8>,
    pub log: Vec<u8>,
    pub blb: Vec<u8>,
    pub chk: Vec<u8>,
}

/// Build `meta.dat` for a boundary recording (§5.1): flags 0, empty `args`
/// and `workdir`, `recorder_id = codetracer-js-boundary/<vocab>`.
pub fn encode_meta(recording_id: &str, program: &str, vocab: u16) -> Vec<u8> {
    encode_meta_dat(recording_id, program, &[], "", &recorder_id(vocab), 0)
}

/// Write the four members into a closed, uncompressed CTFS container and
/// return its bytes. The members are created and written in [`MEMBERS`]
/// order, so their blocks follow that order and the same members always
/// produce the same container bytes.
pub fn write_container(members: &Members) -> Result<Vec<u8>, ContainerError> {
    let mut w = CtfsWriter::create_in_memory(BLOCK_SIZE, ROOT_ENTRIES, CompressionMethod::None)
        .map_err(ctfs)?;
    let contents: [&[u8]; 4] = [&members.meta_dat, &members.log, &members.blb, &members.chk];
    let mut handles = Vec::with_capacity(4);
    for name in MEMBERS {
        handles.push(w.add_file(name).map_err(ctfs)?);
    }
    for (handle, bytes) in handles.into_iter().zip(contents) {
        if !bytes.is_empty() {
            w.write(handle, bytes).map_err(ctfs)?;
        }
    }
    w.finish_to_bytes().map_err(ctfs)
}

/// A boundary recording read back and verified.
#[derive(Debug, Clone, PartialEq)]
pub struct BoundaryRecording {
    pub meta: MetaDat,
    pub log: DecodedLog,
    pub blobs: BlobStore,
    pub checkpoints: Vec<CheckpointRow>,
}

impl BoundaryRecording {
    /// Open and verify a `.ct` file.
    pub fn open(path: &Path) -> Result<Self, ContainerError> {
        let reader = CtfsReader::open(path).map_err(ctfs)?;
        Self::from_reader(reader)
    }

    /// Verify a `.ct` held in memory.
    pub fn read(bytes: Vec<u8>) -> Result<Self, ContainerError> {
        Self::from_reader(CtfsReader::from_bytes(bytes).map_err(ctfs)?)
    }

    fn from_reader(mut reader: CtfsReader) -> Result<Self, ContainerError> {
        for name in reader.list_files() {
            if !MEMBERS.contains(&name.as_str()) {
                return Err(ContainerError::UnexpectedMember(name));
            }
        }
        let mut read = |name: &'static str| -> Result<Vec<u8>, ContainerError> {
            if reader.file_size(name).is_none() {
                return Err(ContainerError::MissingMember(name));
            }
            reader.read_file(name).map_err(ctfs)
        };
        let meta_bytes = read(META_MEMBER)?;
        let log_bytes = read(LOG_MEMBER)?;
        let blb_bytes = read(BLB_MEMBER)?;
        let chk_bytes = read(CHK_MEMBER)?;

        let meta = decode_meta_dat(&meta_bytes).map_err(ContainerError::MetaDat)?;
        let log = decode_log(&log_bytes).map_err(ContainerError::Log)?;
        if log.termination != Termination::Complete {
            return Err(ContainerError::LogIncomplete(log.termination));
        }
        let Some(Record::Header { vocab, .. }) = log.records.first() else {
            unreachable!("a Complete log starts with Header");
        };
        if meta.recorder_id != recorder_id(*vocab) {
            return Err(ContainerError::MetaDat(format!(
                "recorder_id is {:?}, not {:?}",
                meta.recorder_id,
                recorder_id(*vocab)
            )));
        }
        let blobs = BlobStore::decode(&blb_bytes)?;
        check_blob_refs(&log.records, &blobs)?;
        let checkpoints = derive_checkpoint_index(&log);
        if encode_checkpoint_index(&checkpoints) != chk_bytes {
            return Err(ContainerError::CheckpointIndexMismatch(format!(
                "it holds {} byte(s), but the log's {} Checkpoint record(s) index as {} byte(s) of other content",
                chk_bytes.len(),
                checkpoints.len(),
                checkpoints.len() * CHK_ROW_LEN
            )));
        }
        Ok(BoundaryRecording {
            meta,
            log,
            blobs,
            checkpoints,
        })
    }
}
