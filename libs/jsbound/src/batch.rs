//! The uploaded batch (Boundary-Ingest.md §4): the assembler's input.
//!
//! ```text
//! batch    := magic envelope frames
//! magic    := "CTJB" u8 version (1)
//! envelope := len:u32 json[len]        UTF-8 JSON, at most 4 KiB
//! frames   := CTBL-framed jsbound records, first_seq..last_seq
//! ```
//!
//! The ingest checks only the envelope and never decodes the frames; that is
//! the assembler's job, out of process (JS-Boundary-Recording.md §5.6).

use serde::{Deserialize, Serialize};
use std::fmt;

use crate::decode::{decode_record, DecodeError, FrameRunEnd, FrameSplitter};
use crate::record::Record;

/// The batch magic.
pub const BATCH_MAGIC: &[u8; 4] = b"CTJB";
/// The one batch version.
pub const BATCH_VERSION: u8 = 1;
/// The largest envelope (Boundary-Ingest.md §4).
pub const MAX_ENVELOPE_LEN: u32 = 4096;

/// The batch envelope (Boundary-Ingest.md §4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    /// The client-minted session id, 32 lowercase hex digits.
    pub session_id: String,
    /// The batch's position in the session, from 0.
    pub batch_seq: u64,
    /// The `seq` of the batch's first seq-bearing record.
    pub first_seq: u64,
    /// The `seq` of the batch's last seq-bearing record.
    pub last_seq: u64,
    /// Inclusive `seq` ranges the client dropped from its ring before this
    /// batch (JS-Boundary-Recording.md §11.1).
    #[serde(default)]
    pub dropped: Vec<[u64; 2]>,
    /// The session's build hash, 64 lowercase hex digits.
    pub build_hash: String,
    /// Whether this is the session's last batch.
    #[serde(rename = "final", default)]
    pub is_final: bool,
}

/// A parsed batch: its envelope and its decoded records, each with the
/// offset of its frame in the batch body.
#[derive(Debug, Clone, PartialEq)]
pub struct Batch {
    pub envelope: Envelope,
    pub records: Vec<(u64, Record)>,
}

/// Why a batch body was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BatchError {
    /// Not `"CTJB"`.
    BadMagic,
    /// A batch version other than 1.
    UnsupportedVersion(u8),
    /// The envelope's declared length exceeds 4 KiB.
    EnvelopeTooLarge(u32),
    /// The body ends inside its prefix, its envelope or a frame.
    Truncated(String),
    /// The envelope is not the JSON object of Boundary-Ingest.md §4.
    BadEnvelope(String),
    /// A frame was refused by the strict decoder.
    Frame(DecodeError),
}

impl BatchError {
    /// The contract name of this refusal, as the shared batch vectors spell
    /// it and the TypeScript parser (`BatchFormatError.code`) reports it.
    pub fn name(&self) -> &'static str {
        match self {
            BatchError::BadMagic => "BadMagic",
            BatchError::UnsupportedVersion(_) => "UnsupportedVersion",
            BatchError::EnvelopeTooLarge(_) => "EnvelopeTooLarge",
            BatchError::Truncated(_) => "Truncated",
            BatchError::BadEnvelope(_) => "BadEnvelope",
            BatchError::Frame(_) => "Frame",
        }
    }
}

impl fmt::Display for BatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BatchError::BadMagic => write!(f, "the batch does not start with \"CTJB\""),
            BatchError::UnsupportedVersion(v) => {
                write!(f, "batch version {v} is not supported (only 1)")
            }
            BatchError::EnvelopeTooLarge(n) => {
                write!(
                    f,
                    "the envelope declares {n} bytes; the limit is {MAX_ENVELOPE_LEN}"
                )
            }
            BatchError::Truncated(what) => write!(f, "the batch is truncated: {what}"),
            BatchError::BadEnvelope(why) => write!(f, "the envelope is malformed: {why}"),
            BatchError::Frame(e) => write!(f, "a frame is refused: {e}"),
        }
    }
}

impl std::error::Error for BatchError {}

/// Parse a batch body. Every frame must be whole and decode strictly; the
/// stream-level rules are applied later, to the assembled log.
pub fn parse_batch(body: &[u8]) -> Result<Batch, BatchError> {
    if body.len() < 5 {
        return Err(BatchError::Truncated(format!(
            "{} byte(s), shorter than the prefix",
            body.len()
        )));
    }
    if &body[..4] != BATCH_MAGIC {
        return Err(BatchError::BadMagic);
    }
    if body[4] != BATCH_VERSION {
        return Err(BatchError::UnsupportedVersion(body[4]));
    }
    if body.len() < 9 {
        return Err(BatchError::Truncated("inside the envelope length".into()));
    }
    let env_len = u32::from_le_bytes(body[5..9].try_into().expect("4 bytes"));
    if env_len > MAX_ENVELOPE_LEN {
        return Err(BatchError::EnvelopeTooLarge(env_len));
    }
    let frames_at = 9 + env_len as usize;
    if body.len() < frames_at {
        return Err(BatchError::Truncated("inside the envelope".into()));
    }
    let envelope: Envelope = serde_json::from_slice(&body[9..frames_at])
        .map_err(|e| BatchError::BadEnvelope(e.to_string()))?;
    validate_envelope(&envelope)?;

    let mut splitter = FrameSplitter::new(&body[frames_at..], frames_at as u64);
    let mut records = Vec::new();
    while let Some(frame) = splitter.next_frame().map_err(BatchError::Frame)? {
        let record = decode_record(frame.payload, frame.offset).map_err(BatchError::Frame)?;
        records.push((frame.offset, record));
    }
    if let FrameRunEnd::MidFrame { partial } = splitter.end() {
        return Err(BatchError::Truncated(format!(
            "{partial} byte(s) of a partial frame at the end"
        )));
    }
    Ok(Batch { envelope, records })
}

fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn validate_envelope(e: &Envelope) -> Result<(), BatchError> {
    if !is_lower_hex(&e.session_id, 32) {
        return Err(BatchError::BadEnvelope(format!(
            "session_id {:?} is not 32 lowercase hex digits",
            e.session_id
        )));
    }
    if !is_lower_hex(&e.build_hash, 64) {
        return Err(BatchError::BadEnvelope(format!(
            "build_hash {:?} is not 64 lowercase hex digits",
            e.build_hash
        )));
    }
    for [a, b] in &e.dropped {
        if a > b || *a == 0 {
            return Err(BatchError::BadEnvelope(format!(
                "dropped range [{a}, {b}] is not a seq range"
            )));
        }
    }
    Ok(())
}

/// Encode a batch body: the inverse of [`parse_batch`]. Used by tests and by
/// any Rust producer of batches.
pub fn encode_batch(envelope: &Envelope, records: &[Record]) -> Vec<u8> {
    let json = serde_json::to_vec(envelope).expect("an envelope serialises");
    let mut out = BATCH_MAGIC.to_vec();
    out.push(BATCH_VERSION);
    out.extend_from_slice(&(json.len() as u32).to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(&crate::encode::encode_frames(records));
    out
}
