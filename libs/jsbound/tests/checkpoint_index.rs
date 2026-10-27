//! The checkpoint index, `jsbound.chk` (JS-Boundary-Recording.md §5.5): it is
//! derived from `jsbound.log`, any reader may rebuild it from the log, and a
//! reader must refuse a stored index that disagrees with the log.
//!
//! No mocks: the batches are written by the real encoders and assembled by the
//! real `ct-jsbound` binary, and the recording is read back from its file with
//! `CtfsReader`. The index is checked against an oracle that does not share the
//! library's derivation: it walks the assembled log's frames by their length
//! prefix and reads each `Checkpoint` frame's `seq` and `ordinal` from the
//! bytes, as the wire layout (spec §5.2, §5.3) places them.

mod support;

use std::collections::BTreeSet;

use codetracer_ctfs::CtfsReader;
use jsbound::container::{write_container, CHK_MEMBER, LOG_MEMBER};
use jsbound::record::gap_reason;
use jsbound::{
    assemble, rebuild_checkpoint_index, AssembleOptions, BoundaryRecording, ContainerError,
    Finalisation, Members, Record,
};
use support::*;

/// The `Checkpoint` frame's tag (spec §5.2).
const CHECKPOINT_TAG: u8 = 0x4D;

/// A session whose log moves frames around between upload and assembly: two
/// bodies over the inline limit before the later checkpoints (moved into
/// `jsbound.blb`, so their frames shrink), a batch that never arrives (the
/// assembler writes a `Gap` frame in its place) and a range the client's ring
/// dropped (a second `Gap`). Five checkpoints at seq 3, 10, 17, 24 and 29.
fn moving_session() -> Vec<StagedBatch> {
    let checkpoints = [3u64, 10, 17, 24, 29];
    let record = |seq: u64| -> Record {
        if let Some(ordinal) = checkpoints.iter().position(|&c| c == seq) {
            return Record::Checkpoint {
                seq,
                ordinal: ordinal as u32,
                scheme: "dom-v1".into(),
                state_hash: format!("{seq:064x}"),
                dom_digest: String::new(),
            };
        }
        match seq {
            5 | 12 => record_at(5_u64).with_seq(seq),
            _ => record_at(1).with_seq(seq),
        }
    };
    // Batches: 0 = seq 1..=7, 1 = 8..=14, 2 = 15..=18, 3 = 19..=21 (never
    // arrives), 4 = 22..=26 with 25 and 26 dropped by the ring, 5 = 27..=30.
    let ranges: [(u64, u64, u64); 6] = [
        (0, 1, 7),
        (1, 8, 14),
        (2, 15, 18),
        (3, 19, 21),
        (4, 22, 26),
        (5, 27, 30),
    ];
    ranges
        .iter()
        .filter(|(b, _, _)| *b != 3)
        .map(|&(b, first, last)| {
            let mut records = Vec::new();
            if b == 0 {
                records.push(header());
                records.push(env());
            }
            let mut dropped = Vec::new();
            for seq in first..=last {
                if b == 4 && seq >= 25 {
                    continue;
                }
                records.push(record(seq));
            }
            if b == 4 {
                dropped.push([25, 26]);
            }
            if b == 5 {
                records.push(Record::End {
                    last_seq: 30,
                    reason: 1,
                });
            }
            StagedBatch {
                batch_seq: b,
                records,
                dropped,
            }
        })
        .collect()
}

/// `record` with its `seq` replaced (the fixture's records are built for one
/// seq and reused at another).
trait WithSeq {
    fn with_seq(self, seq: u64) -> Record;
}

impl WithSeq for Record {
    fn with_seq(self, s: u64) -> Record {
        match self {
            Record::Clock { src, bits, .. } => Record::Clock { seq: s, src, bits },
            Record::NetResponse {
                req_id,
                outcome,
                status,
                status_text,
                url,
                redirected,
                response_type,
                headers,
                body,
                ..
            } => Record::NetResponse {
                seq: s,
                req_id,
                outcome,
                status,
                status_text,
                url,
                redirected,
                response_type,
                headers,
                body,
            },
            other => panic!("the fixture does not reuse {}", other.kind_name()),
        }
    }
}

/// The oracle: `jsbound.chk` as the wire layout gives it, read from the log's
/// bytes without the library's decoder. `stream := "CTBL" version:u8 frame*`,
/// `frame := len:u32 tag:u8 body` with `len` counting the tag and the body;
/// a `Checkpoint` body starts `seq:u64 ordinal:u32`; a row is `ordinal:u32
/// seq:u64 log_offset:u64`, little-endian (spec §5.2, §5.5).
fn index_from_frames(log: &[u8]) -> (Vec<u8>, usize) {
    assert_eq!(&log[..4], b"CTBL");
    let mut at = 5;
    let mut out = Vec::new();
    let mut rows = 0;
    while at < log.len() {
        let len = u32::from_le_bytes(log[at..at + 4].try_into().unwrap()) as usize;
        if log[at + 4] == CHECKPOINT_TAG {
            let seq = &log[at + 5..at + 13];
            let ordinal = &log[at + 13..at + 17];
            out.extend_from_slice(ordinal);
            out.extend_from_slice(seq);
            out.extend_from_slice(&(at as u64).to_le_bytes());
            rows += 1;
        }
        at += 4 + len;
    }
    assert_eq!(at, log.len(), "the log ends inside a frame");
    (out, rows)
}

/// One edit of a stored `jsbound.chk`.
type ChkEdit<'a> = Box<dyn Fn(&mut Vec<u8>) + 'a>;

/// The members of the recording at `bytes`, read raw through `CtfsReader`.
fn raw_member(bytes: &[u8], name: &str) -> Vec<u8> {
    let mut reader = CtfsReader::from_bytes(bytes.to_vec()).unwrap();
    reader.read_file(name).unwrap()
}

/// Rebuilding the checkpoint index from the assembled `jsbound.log` gives the
/// assembled `jsbound.chk` byte for byte, and both equal the index read off
/// the log's frames by the independent oracle, on a session whose frames the
/// assembler moved (bodies moved to `jsbound.blb`, two `Gap` frames written).
/// An edited `jsbound.chk` — each kind of edit a stored index can suffer — is
/// refused by the reader, in process and through `ct-jsbound summarize`.
///
/// Vacuity guards: the session has five checkpoints, the assembler wrote two
/// `Gap`s and moved two bodies (so the offsets are not the uploaded ones),
/// and the oracle found five rows. Negative control: the unedited recording
/// is read and summarised, so each refusal is the edit's.
#[test]
fn test_jsbound_chk_rebuilt_equals_assembled() {
    let tmp = tempfile::tempdir().unwrap();
    let staged = stage(&tmp.path().join("staging"), &moving_session());
    let out = tmp.path().join("session.ct");
    let container = assemble_files(&out, &staged, &[]);

    let log = raw_member(&container, LOG_MEMBER);
    let chk = raw_member(&container, CHK_MEMBER);
    let rec = BoundaryRecording::read(container.clone()).unwrap();

    // Vacuity guards: what the assembler did to the frames.
    let gaps: Vec<(u64, u64, u8)> = rec
        .log
        .records
        .iter()
        .filter_map(|r| match r {
            Record::Gap {
                first_seq,
                last_seq,
                reason,
            } => Some((*first_seq, *last_seq, *reason)),
            _ => None,
        })
        .collect();
    assert_eq!(
        gaps,
        vec![
            (19, 21, gap_reason::BATCH_NEVER_ARRIVED),
            (25, 26, gap_reason::CLIENT_RING_OVERFLOW)
        ]
    );
    assert_eq!(
        rec.blobs.len(),
        1,
        "the two large bodies are one stored body"
    );
    let refs = rec
        .log
        .records
        .iter()
        .filter(|r| matches!(r.blob(), Some(jsbound::BlobRef::Ref { .. })))
        .count();
    assert_eq!(refs, 2, "both large bodies moved to jsbound.blb");

    // The oracle, from the frames.
    let (oracle, rows) = index_from_frames(&log);
    assert_eq!(rows, 5);
    assert_eq!(chk, oracle, "the assembled jsbound.chk");

    // The rebuild path.
    let rebuilt = rebuild_checkpoint_index(&log).unwrap();
    assert_eq!(rebuilt, chk, "jsbound.chk rebuilt from jsbound.log");
    assert_eq!(
        rec.checkpoints
            .iter()
            .map(|r| (r.ordinal, r.seq))
            .collect::<Vec<_>>(),
        vec![(0, 3), (1, 10), (2, 17), (3, 24), (4, 29)]
    );

    // Negative control: the unedited recording passes the CLI's reader too.
    let (code, _, stderr) = ct_jsbound(&["summarize", out.to_str().unwrap()]);
    assert_eq!(code, 0, "{stderr}");

    // Each edit of a stored index is refused.
    let row = 20;
    let edits: Vec<(&str, ChkEdit)> = vec![
        ("an ordinal changed", Box::new(|c| c[row] ^= 1)),
        ("a seq changed", Box::new(|c| c[row + 4] ^= 1)),
        ("a log_offset changed", Box::new(|c| c[row + 12] ^= 0x10)),
        (
            "a log_offset pointing at another Checkpoint frame",
            Box::new(|c| {
                let other: [u8; 8] = c[2 * row + 12..2 * row + 20].try_into().unwrap();
                c[row + 12..row + 20].copy_from_slice(&other);
            }),
        ),
        (
            "two rows swapped",
            Box::new(|c| {
                let first: Vec<u8> = c[..row].to_vec();
                let second: Vec<u8> = c[row..2 * row].to_vec();
                c[..row].copy_from_slice(&second);
                c[row..2 * row].copy_from_slice(&first);
            }),
        ),
        (
            "the last row removed",
            Box::new(|c| c.truncate(c.len() - row)),
        ),
        (
            "a row repeated",
            Box::new(|c| {
                let last: Vec<u8> = c[c.len() - row..].to_vec();
                c.extend_from_slice(&last);
            }),
        ),
        ("cut short by a byte", Box::new(|c| c.truncate(c.len() - 1))),
        ("emptied", Box::new(|c| c.clear())),
    ];
    let original = Members {
        meta_dat: raw_member(&container, "meta.dat"),
        log: log.clone(),
        blb: raw_member(&container, "jsbound.blb"),
        chk: chk.clone(),
    };
    // The members re-written unedited are the same recording.
    assert_eq!(write_container(&original).unwrap(), container);
    let mut seen = BTreeSet::new();
    for (name, edit) in &edits {
        let mut members = original.clone();
        edit(&mut members.chk);
        assert_ne!(members.chk, chk, "{name}: the edit changed nothing");
        assert!(seen.insert(members.chk.clone()), "{name}: a repeated edit");
        let edited = write_container(&members).unwrap();
        let err = BoundaryRecording::read(edited.clone()).unwrap_err();
        assert!(
            matches!(err, ContainerError::CheckpointIndexMismatch(_)),
            "{name}: {err}"
        );
        let path = tmp.path().join("edited.ct");
        std::fs::write(&path, &edited).unwrap();
        let (code, _, stderr) = ct_jsbound(&["summarize", path.to_str().unwrap()]);
        assert_eq!(code, 1, "{name}: ct-jsbound summarize exit status");
        assert!(stderr.contains("jsbound.chk"), "{name}: {stderr}");
    }
    // The library's assembler agrees with the binary's.
    let bodies: Vec<Vec<u8>> = moving_session().iter().map(StagedBatch::body).collect();
    let a = assemble(
        &bodies,
        &AssembleOptions {
            recording_id: RECORDING_ID.into(),
            finalisation: Finalisation::Ended,
            refused_batches: BTreeSet::new(),
        },
    )
    .unwrap();
    assert_eq!(a.members.chk, chk);
}
