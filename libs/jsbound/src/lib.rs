//! The JS boundary log and its recording container.
//!
//! A browser boundary recording is a CTFS container of four members
//! (`codetracer-pm` `spec/Trace-Files/CTFS-Binary-Format.md` §4.8):
//! `meta.dat`, `jsbound.log` (the boundary log: every clock, random value,
//! network response, storage and layout read, input and macrotask order the
//! page observed), `jsbound.blb` (large bodies, content-addressed) and
//! `jsbound.chk` (the checkpoint index). The records are specified in
//! `spec/Recording-Backends/JS-Boundary-Recording.md` §5.
//!
//! * [`record`]: the records of §5.2, declared once.
//! * [`encode`] and [`decode`]: the encoder and the strict decoder of §5.3.
//! * [`batch`]: the uploaded batch of Boundary-Ingest.md §4.
//! * [`assemble`]: batches to a recording (§5.6), the work of `ct-jsbound
//!   assemble`, whose command line is [`cli`].
//! * [`container`]: writing and verifying the four members, and the
//!   checkpoint index rebuilt from the log ([`rebuild_checkpoint_index`]).
//! * [`vectors`]: the byte vectors shared with the TypeScript implementation
//!   in codetracer-js-recorder `packages/boundary-format`.
//!
//! Layout of `jsbound.log` (all integers little-endian):
//!
//! ```text
//! stream  := "CTBL" version:u8(1) frame*
//! frame   := len:u32 tag:u8 body          1 <= len <= 64 MiB
//! str     := len:u32 utf8[len]
//! blobref := kind:u8 (0: str-of-bytes, at most 1024 | 1: sha256[32] len:u64)
//! ```

pub mod assemble;
pub mod batch;
pub mod cli;
pub mod container;
pub mod decode;
pub mod encode;
pub mod record;
pub mod vectors;

pub use assemble::{
    assemble, AssembleError, AssembleOptions, Assembled, Finalisation, GapSummary, Summary,
};
pub use batch::{encode_batch, parse_batch, Batch, BatchError, Envelope};
pub use container::{
    decode_checkpoint_index, rebuild_checkpoint_index, verify_checkpoint_index, BoundaryRecording,
    CheckpointRow, ContainerError, Members,
};
pub use decode::{decode_log, DecodeError, DecodeErrorKind, DecodedLog, Termination};
pub use encode::{encode_frame, encode_frames, encode_log};
pub use record::{BlobRef, Record, HOLE_TOKEN, RECORD_KINDS};
