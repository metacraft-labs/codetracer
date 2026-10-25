//! Shared fixtures for the assembler tests: a recorded session as the
//! recorder would upload it, split into batches (Boundary-Ingest.md §4).
//!
//! Nothing here is a mock: the batches are encoded by the real batch and
//! frame encoders, and every test assembles them with the real assembler.

#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use jsbound::{encode_batch, BlobRef, Envelope, Record};

pub const SESSION_ID: &str = "0123456789abcdef0123456789abcdef";
pub const BUILD_HASH: &str = "aa11bb22cc33dd44ee55ff6600778899aa11bb22cc33dd44ee55ff6600778899";
pub const RECORDING_ID: &str = "01920f3e-7c4a-7b2e-9d1f-3a5b7c9e1f20";
/// A response body over the 1024-byte inline limit.
pub const LARGE_BODY_LEN: usize = 3000;

pub fn header() -> Record {
    Record::Header {
        vocab: 1,
        protocol_level: 0,
        recorder_id: "codetracer-boundary-shim/0.1.0".into(),
        framework: String::new(),
        build_hash: BUILD_HASH.into(),
        session_id: SESSION_ID.into(),
        prev_session: String::new(),
        capabilities: "[]".into(),
    }
}

pub fn env() -> Record {
    Record::Env {
        ua: "Mozilla/5.0 Chrome/141.0.0.0".into(),
        ua_major: 141,
        viewport_w: 1024,
        viewport_h: 768,
        dpr: 2.0,
        locale: "en".into(),
        tz: "UTC".into(),
        fonts_digest: String::new(),
        color_scheme: 0,
        reduced_motion: 0,
        arms: "{}".into(),
        url: "https://shop.example/cart?session=secret#top".into(),
        referrer_origin: String::new(),
        traceparent: String::new(),
    }
}

pub fn large_body() -> Vec<u8> {
    (0..LARGE_BODY_LEN).map(|i| (i % 251) as u8).collect()
}

/// The seq-bearing record at `seq` of the fixture session: a mix that
/// includes a large network body (seq 5), a repeat of it (seq 11), and two
/// checkpoints (seq 6 and 9).
pub fn record_at(seq: u64) -> Record {
    match seq {
        5 => Record::NetResponse {
            seq,
            req_id: 1,
            outcome: 1,
            status: 200,
            status_text: String::new(),
            url: String::new(),
            redirected: 0,
            response_type: 0,
            headers: "[]".into(),
            body: BlobRef::Inline(large_body()),
        },
        11 => Record::WsMessage {
            seq,
            req_id: 2,
            dir: 1,
            frame: 0,
            event: String::new(),
            last_event_id: String::new(),
            data: BlobRef::Inline(large_body()),
        },
        6 | 9 => Record::Checkpoint {
            seq,
            ordinal: if seq == 6 { 0 } else { 1 },
            scheme: "generic/1".into(),
            state_hash: format!("{seq:08x}"),
            dom_digest: String::new(),
        },
        8 => Record::Mark {
            seq,
            name: "exposure".into(),
            data: "{}".into(),
        },
        _ => Record::Clock {
            seq,
            src: 1,
            bits: 0x4279_0000_0000_0000 + seq,
        },
    }
}

/// One batch of the fixture: its records and envelope.
pub struct StagedBatch {
    pub batch_seq: u64,
    pub records: Vec<Record>,
    pub dropped: Vec<[u64; 2]>,
}

impl StagedBatch {
    pub fn body(&self) -> Vec<u8> {
        let seqs: Vec<u64> = self.records.iter().filter_map(Record::seq).collect();
        let envelope = Envelope {
            session_id: SESSION_ID.into(),
            batch_seq: self.batch_seq,
            first_seq: seqs.first().copied().unwrap_or(0),
            last_seq: seqs.last().copied().unwrap_or(0),
            dropped: self.dropped.clone(),
            build_hash: BUILD_HASH.into(),
            is_final: self.records.iter().any(|r| matches!(r, Record::End { .. })),
        };
        encode_batch(&envelope, &self.records)
    }
}

/// The fixture session, 12 seqs in four batches of three, the first
/// starting with Header and Env and the last ending with End.
pub fn session_batches() -> Vec<StagedBatch> {
    (0..4u64)
        .map(|b| {
            let mut records = Vec::new();
            if b == 0 {
                records.push(header());
                records.push(env());
            }
            records.extend((b * 3 + 1..=b * 3 + 3).map(record_at));
            if b == 3 {
                records.push(Record::End {
                    last_seq: 12,
                    reason: 1,
                });
            }
            StagedBatch {
                batch_seq: b,
                records,
                dropped: Vec::new(),
            }
        })
        .collect()
}

/// Write each batch to `dir/<batch_seq>`, the staging layout, and return
/// the paths in batch order.
pub fn stage(dir: &Path, batches: &[StagedBatch]) -> Vec<PathBuf> {
    fs::create_dir_all(dir).unwrap();
    batches
        .iter()
        .map(|b| {
            let p = dir.join(b.batch_seq.to_string());
            fs::write(&p, b.body()).unwrap();
            p
        })
        .collect()
}

/// Run the real `ct-jsbound` binary; returns (status, stdout, stderr).
pub fn ct_jsbound(args: &[&str]) -> (i32, String, String) {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_ct-jsbound"))
        .args(args)
        .output()
        .expect("ct-jsbound runs");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

/// `ct-jsbound assemble` the given batch paths into `out`; panics on failure.
pub fn assemble_files(out: &Path, inputs: &[PathBuf], extra: &[&str]) -> Vec<u8> {
    let mut args = vec![
        "assemble",
        "--recording-id",
        RECORDING_ID,
        "--out",
        out.to_str().unwrap(),
    ];
    args.extend_from_slice(extra);
    let inputs: Vec<&str> = inputs.iter().map(|p| p.to_str().unwrap()).collect();
    args.extend(inputs);
    let (code, stdout, stderr) = ct_jsbound(&args);
    assert_eq!(
        code, 0,
        "ct-jsbound assemble failed\nstdout: {stdout}\nstderr: {stderr}"
    );
    fs::read(out).unwrap()
}
