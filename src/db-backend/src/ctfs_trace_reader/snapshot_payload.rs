//! MCR snapshot payloads: memory-snapshot members stored either raw or as a
//! Chunked Compressed Table of bytes.
//!
//! Normative description: `codetracer-trace-format-spec/internal-files.md`,
//! "Snapshot payloads (MCR recorder) are Chunked Compressed Tables of bytes".
//! The producer is the native recorder's `ct_recorder/snapshot_payload.nim`.
//!
//! A payload has a LOGICAL name (`cp0.mem`, `cp.entry.mem`, `cppages.ns`, ...)
//! and is stored in exactly one of two forms:
//!
//! * **raw** — the payload bytes under the logical name. A writer uses it for a
//!   payload of at most one container block (4096 bytes).
//! * **compressed** — a data member of concatenated zstd frames and an index
//!   member `[chunk_size: u32 LE][offset: u64 LE]*`, one offset per frame. The
//!   names replace the extension `<ext>` with `<ext[0]>zd` / `<ext[0]>zi`
//!   (`cp0.mem` -> `cp0.mzd` + `cp0.mzi`). A record is one byte, so every
//!   frame but the last inflates to exactly `chunk_size` bytes.
//!
//! The form is decided by WHICH MEMBERS EXIST, never by the bytes: a raw memory
//! page can begin with the zstd frame magic. Both forms at once, or half of the
//! compressed pair, is a malformed container and is refused.

use super::ctfs_container::CtfsReader;

/// The member names one logical snapshot payload can be stored under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotPayloadNames {
    pub logical: String,
    pub data: String,
    pub index: String,
}

/// Longest member name a CTFS directory key holds (base40, 12 characters).
const MAX_CTFS_NAME_LEN: usize = 12;

/// Uncompressed bytes per frame the recorder writes (`SnapshotPayloadChunkBytes`).
pub const SNAPSHOT_PAYLOAD_CHUNK_BYTES: usize = 1 << 20;

/// A payload of at most this many bytes is written raw (one container block).
pub const SNAPSHOT_PAYLOAD_RAW_MAX: usize = 4096;

/// Derive the data and index member names for `logical`.
pub fn snapshot_payload_names(logical: &str) -> Result<SnapshotPayloadNames, String> {
    let Some(dot) = logical.rfind('.') else {
        return Err(format!("{logical}: a snapshot payload name needs an extension"));
    };
    let (stem, ext) = (&logical[..dot], &logical[dot + 1..]);
    let Some(first) = ext.chars().next() else {
        return Err(format!("{logical}: a snapshot payload name needs an extension"));
    };
    let data = format!("{stem}.{first}zd");
    let index = format!("{stem}.{first}zi");
    if data.len() > MAX_CTFS_NAME_LEN {
        return Err(format!(
            "{logical}: its compressed members ({data}, {index}) exceed the {MAX_CTFS_NAME_LEN}-character CTFS name limit"
        ));
    }
    Ok(SnapshotPayloadNames {
        logical: logical.to_string(),
        data,
        index,
    })
}

/// Read the snapshot payload stored under `logical`, in whichever form the
/// container holds it. `Ok(None)` means the container holds neither form.
pub fn read_snapshot_payload(ctfs: &mut CtfsReader, logical: &str) -> Result<Option<Vec<u8>>, String> {
    let names = snapshot_payload_names(logical)?;
    let have_raw = ctfs.has_file(&names.logical);
    let have_data = ctfs.has_file(&names.data);
    let have_index = ctfs.has_file(&names.index);
    if have_data != have_index {
        return Err(format!(
            "{logical}: the container holds only half of its compressed form ({} {}, {} {})",
            names.data,
            if have_data { "present" } else { "ABSENT" },
            names.index,
            if have_index { "present" } else { "ABSENT" },
        ));
    }
    if have_raw && have_data {
        return Err(format!(
            "{logical}: the container holds it both raw and compressed ({}, {}); a writer emits exactly one form",
            names.data, names.index
        ));
    }
    if have_data {
        let data = ctfs
            .read_file(&names.data)
            .map_err(|e| format!("{logical}: reading {}: {e}", names.data))?;
        let index = ctfs
            .read_file(&names.index)
            .map_err(|e| format!("{logical}: reading {}: {e}", names.index))?;
        return decode_snapshot_payload(logical, &data, &index).map(Some);
    }
    if have_raw {
        return ctfs
            .read_file(&names.logical)
            .map(Some)
            .map_err(|e| format!("{logical}: reading the raw member: {e}"));
    }
    Ok(None)
}

/// Inflate a compressed-form payload from its data and index member bytes.
/// Every frame's declared content size is checked against the size the index
/// implies, so a truncated or re-ordered payload fails.
pub fn decode_snapshot_payload(logical: &str, data: &[u8], index: &[u8]) -> Result<Vec<u8>, String> {
    if index.len() < 4 {
        return Err(format!(
            "{logical}: index member is {} bytes, shorter than its 4-byte header",
            index.len()
        ));
    }
    if !(index.len() - 4).is_multiple_of(8) {
        return Err(format!(
            "{logical}: index member has {} trailing bytes after its offsets",
            (index.len() - 4) % 8
        ));
    }
    let chunk_bytes = u64::from(u32::from_le_bytes([index[0], index[1], index[2], index[3]]));
    if chunk_bytes == 0 {
        return Err(format!("{logical}: index states a chunk size of 0"));
    }
    let offsets: Vec<u64> = index[4..]
        .chunks_exact(8)
        .map(|c| {
            let mut word = [0u8; 8];
            word.copy_from_slice(c);
            u64::from_le_bytes(word)
        })
        .collect();
    let Some(&last_offset) = offsets.last() else {
        if !data.is_empty() {
            return Err(format!(
                "{logical}: index lists no frames but the data member holds {} bytes",
                data.len()
            ));
        }
        return Ok(Vec::new());
    };
    if offsets[0] != 0 {
        return Err(format!("{logical}: first frame offset is {}, not 0", offsets[0]));
    }
    for i in 1..offsets.len() {
        if offsets[i] <= offsets[i - 1] {
            return Err(format!(
                "{logical}: frame offsets are not strictly increasing at frame {i}"
            ));
        }
    }
    let data_len = data.len() as u64;
    if last_offset >= data_len {
        return Err(format!(
            "{logical}: last frame offset {last_offset} is not inside the {data_len}-byte data member"
        ));
    }
    let mut out = Vec::new();
    for (i, &start) in offsets.iter().enumerate() {
        let end = offsets.get(i + 1).copied().unwrap_or(data_len);
        let frame = &data[start as usize..end as usize];
        let Some(declared) = declared_content_size(frame) else {
            return Err(format!(
                "{logical}: frame {i} at data offset {start} is not a zstd frame that states its content size"
            ));
        };
        let is_last = i + 1 == offsets.len();
        if (!is_last && declared != chunk_bytes) || (is_last && (declared == 0 || declared > chunk_bytes)) {
            return Err(format!(
                "{logical}: frame {i} declares {declared} bytes; the index's chunk size is {chunk_bytes}"
            ));
        }
        let content = inflate(frame).map_err(|e| format!("{logical}: frame {i} does not inflate: {e}"))?;
        if content.len() as u64 != declared {
            return Err(format!(
                "{logical}: frame {i} inflated to {} bytes but declares {declared}",
                content.len()
            ));
        }
        out.extend_from_slice(&content);
    }
    Ok(out)
}

/// Encode `payload` in the form a writer must emit for it: the raw form for a
/// payload of at most one block, the compressed form otherwise. Returns the
/// `(member name, bytes)` pairs to store.
#[cfg(not(target_arch = "wasm32"))]
pub fn encode_snapshot_payload(logical: &str, payload: &[u8]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let names = snapshot_payload_names(logical)?;
    if payload.len() <= SNAPSHOT_PAYLOAD_RAW_MAX {
        return Ok(vec![(names.logical, payload.to_vec())]);
    }
    let mut data = Vec::new();
    let mut index = (SNAPSHOT_PAYLOAD_CHUNK_BYTES as u32).to_le_bytes().to_vec();
    for chunk in payload.chunks(SNAPSHOT_PAYLOAD_CHUNK_BYTES) {
        index.extend_from_slice(&(data.len() as u64).to_le_bytes());
        let frame = zstd::bulk::compress(chunk, 3).map_err(|e| format!("{logical}: zstd compression failed: {e}"))?;
        data.extend_from_slice(&frame);
    }
    Ok(vec![(names.data, data), (names.index, index)])
}

/// The content size a zstd frame header declares, or `None` when the frame
/// declares none (RFC 8878 §3.1.1.1).
fn declared_content_size(frame: &[u8]) -> Option<u64> {
    if frame.len() < 5 || frame[0..4] != [0x28, 0xB5, 0x2F, 0xFD] {
        return None;
    }
    let fhd = frame[4];
    let fcs_flag = fhd >> 6;
    let single_segment = fhd & 0x20 != 0;
    let dict_id_bytes = [0usize, 1, 2, 4][(fhd & 0x03) as usize];
    let fcs_bytes = match fcs_flag {
        0 if single_segment => 1,
        0 => return None,
        1 => 2,
        2 => 4,
        _ => 8,
    };
    let start = 5 + usize::from(!single_segment) + dict_id_bytes;
    let field = frame.get(start..start + fcs_bytes)?;
    let mut raw = [0u8; 8];
    raw[..fcs_bytes].copy_from_slice(field);
    let value = u64::from_le_bytes(raw);
    Some(if fcs_bytes == 2 { value + 256 } else { value })
}

#[cfg(not(target_arch = "wasm32"))]
fn inflate(frame: &[u8]) -> Result<Vec<u8>, String> {
    zstd::decode_all(std::io::Cursor::new(frame)).map_err(|e| e.to_string())
}

#[cfg(target_arch = "wasm32")]
fn inflate(frame: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut decoder =
        ruzstd::decoding::StreamingDecoder::new(std::io::Cursor::new(frame)).map_err(|e| e.to_string())?;
    let mut raw = Vec::new();
    decoder.read_to_end(&mut raw).map_err(|e| e.to_string())?;
    Ok(raw)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;

    fn container(members: &[(&str, &[u8])]) -> CtfsReader {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("p.ct");
        write_minimal_ctfs(&path, members).unwrap();
        CtfsReader::from_bytes(std::fs::read(&path).unwrap()).unwrap()
    }

    fn payload(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 7 + i / 4096) as u8).collect()
    }

    #[test]
    fn member_names_follow_the_extension_rule() {
        let n = snapshot_payload_names("cp0.mem").unwrap();
        assert_eq!((n.data.as_str(), n.index.as_str()), ("cp0.mzd", "cp0.mzi"));
        let n = snapshot_payload_names("cp.entry.mem").unwrap();
        assert_eq!((n.data.as_str(), n.index.as_str()), ("cp.entry.mzd", "cp.entry.mzi"));
        let n = snapshot_payload_names("cppages.ns").unwrap();
        assert_eq!((n.data.as_str(), n.index.as_str()), ("cppages.nzd", "cppages.nzi"));
    }

    #[test]
    fn compressed_form_round_trips_across_several_frames() {
        let bytes = payload(SNAPSHOT_PAYLOAD_CHUNK_BYTES * 2 + 12_345);
        let members = encode_snapshot_payload("cp0.mem", &bytes).unwrap();
        assert_eq!(
            members.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
            ["cp0.mzd", "cp0.mzi"]
        );
        let refs: Vec<(&str, &[u8])> = members.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
        let mut ctfs = container(&refs);
        assert_eq!(read_snapshot_payload(&mut ctfs, "cp0.mem").unwrap(), Some(bytes));
    }

    #[test]
    fn a_one_block_payload_is_written_and_read_raw() {
        let bytes = payload(SNAPSHOT_PAYLOAD_RAW_MAX);
        let members = encode_snapshot_payload("cp0.mem", &bytes).unwrap();
        assert_eq!(members.len(), 1);
        assert_eq!(members[0].0, "cp0.mem");
        let mut ctfs = container(&[("cp0.mem", &bytes)]);
        assert_eq!(read_snapshot_payload(&mut ctfs, "cp0.mem").unwrap(), Some(bytes));
    }

    #[test]
    fn an_absent_payload_reads_as_none() {
        let mut ctfs = container(&[("other.bin", b"x")]);
        assert_eq!(read_snapshot_payload(&mut ctfs, "cp0.mem").unwrap(), None);
    }

    #[test]
    fn half_a_compressed_pair_is_refused_by_name() {
        let mut ctfs = container(&[("cp0.mzd", b"\x28\xb5\x2f\xfd")]);
        let err = read_snapshot_payload(&mut ctfs, "cp0.mem").unwrap_err();
        assert!(err.contains("half") && err.contains("cp0.mzi ABSENT"), "{err}");
    }

    #[test]
    fn both_forms_at_once_are_refused() {
        let bytes = payload(SNAPSHOT_PAYLOAD_CHUNK_BYTES + 1);
        let members = encode_snapshot_payload("cp0.mem", &bytes).unwrap();
        let mut refs: Vec<(&str, &[u8])> = members.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
        refs.push(("cp0.mem", b"raw"));
        let mut ctfs = container(&refs);
        let err = read_snapshot_payload(&mut ctfs, "cp0.mem").unwrap_err();
        assert!(err.contains("both raw and compressed"), "{err}");
    }

    #[test]
    fn a_truncated_payload_is_refused() {
        let bytes = payload(SNAPSHOT_PAYLOAD_CHUNK_BYTES * 2 + 5);
        let members = encode_snapshot_payload("cp0.mem", &bytes).unwrap();
        // Drop the last frame's offset: the index now claims the middle frame
        // is the last, and it declares a full chunk, so the data member's tail
        // is read as part of it and the frame no longer inflates cleanly.
        let mut index = members[1].1.clone();
        index.truncate(index.len() - 8);
        let err = decode_snapshot_payload("cp0.mem", &members[0].1, &index).unwrap_err();
        assert!(err.contains("frame 1"), "{err}");
    }
}
