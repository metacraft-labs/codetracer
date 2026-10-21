//! The `jsbound.log` encoder (JS-Boundary-Recording.md §5.2).
//!
//! A frame is assembled whole before anyone writes it, so a producer that
//! writes each frame with one `write` and then dies leaves whole frames and
//! no `End`: a stream the decoder classifies as unterminated, never torn.

use crate::decode::stream_prefix;
use crate::record::Record;

/// Encode one record as a complete frame: `len:u32`, then `tag:u8 body`.
pub fn encode_frame(record: &Record) -> Vec<u8> {
    let mut payload = vec![record.tag()];
    record.encode_body(&mut payload);
    let len = u32::try_from(payload.len()).expect("a jsbound record is smaller than 4 GiB");
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&len.to_le_bytes());
    frame.extend_from_slice(&payload);
    frame
}

/// Encode a frame run with no stream prefix (the body of an uploaded batch).
pub fn encode_frames(records: &[Record]) -> Vec<u8> {
    let mut out = Vec::new();
    for r in records {
        out.extend_from_slice(&encode_frame(r));
    }
    out
}

/// Encode a whole `jsbound.log`: the `"CTBL" 1` prefix and every frame.
///
/// Returns the bytes and the offset of each record's frame in them.
pub fn encode_log(records: &[Record]) -> (Vec<u8>, Vec<u64>) {
    let mut out = stream_prefix().to_vec();
    let mut offsets = Vec::with_capacity(records.len());
    for r in records {
        offsets.push(out.len() as u64);
        out.extend_from_slice(&encode_frame(r));
    }
    (out, offsets)
}
