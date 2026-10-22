//! The shared byte vectors (JS-Boundary-Recording.md §5.3: "The Rust decoder
//! and the TypeScript decoder are held to one set of byte vectors").
//!
//! The catalogue is built here and written to `libs/jsbound/vectors/` by
//! `cargo run --example generate_vectors`; codetracer-js-recorder vendors that
//! directory (`scripts/vendor-jsbound-vectors.sh`, which checks it against
//! `SHA256SUMS`). The committed files are the contract, and
//! `tests/vectors.rs` checks that they are exactly what this catalogue
//! renders.
//!
//! Each vector's expectation is written from the records the vector was
//! *built* from (and, for a refusal, from the error the spec calls for), not
//! from what the decoder makes of the bytes; a decoder bug therefore cannot
//! write its own expectation.
//!
//! Three classes:
//!
//! * `valid`: a complete log; at least one per record kind of §5.2.
//! * `truncation`: a log cut at a frame boundary (`TruncatedUnterminated`)
//!   and one cut inside a frame (`TruncatedMidRecord`).
//! * `refusal`: a valid `base` vector with exactly one edit, which the
//!   decoder must refuse with the named error.
//!
//! Every enumerated field is held at both ends of its value set: the
//! `enum_greatest` vector carries each at its greatest value, and one
//! refusal vector per field steps one past it (and, for a set that starts
//! at 1, one before it, 0).

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

use crate::decode::{decode_log, DecodeErrorKind, Termination};
use crate::encode::{encode_frame, encode_log};
use crate::record::{hex, BlobRef, Record, MAX_FRAME_LEN, MAX_INLINE_BLOB, VALUE_SETS, VOCAB};

/// The class of a vector, with what the decoder must make of it.
#[derive(Debug, Clone, PartialEq)]
pub enum Expectation {
    /// Decodes to `records` with `termination`.
    Decodes {
        records: Vec<Record>,
        termination: Termination,
    },
    /// Refused with `error`; `base` is the valid vector it is one edit from.
    Refused {
        base: String,
        error: DecodeErrorKind,
    },
}

/// One shared vector.
#[derive(Debug, Clone, PartialEq)]
pub struct Vector {
    pub name: String,
    pub description: String,
    pub bytes: Vec<u8>,
    pub expectation: Expectation,
}

impl Vector {
    /// `valid`, `truncation` or `refusal`.
    pub fn class(&self) -> &'static str {
        match &self.expectation {
            Expectation::Decodes {
                termination: Termination::Complete,
                ..
            } => "valid",
            Expectation::Decodes { .. } => "truncation",
            Expectation::Refused { .. } => "refusal",
        }
    }

    /// The expectation as the vector's `.json` file holds it.
    pub fn expected_json(&self) -> Value {
        match &self.expectation {
            Expectation::Decodes {
                records,
                termination,
            } => json!({
                "termination": termination.name(),
                "records": records.iter().map(Record::to_json).collect::<Vec<_>>(),
            }),
            Expectation::Refused { error, .. } => json!({ "error": error.name() }),
        }
    }
}

const SESSION_ID: &str = "5f0c2a9e7b6d4e1f8a3c9b2d1e0f7a6b";
const BUILD_HASH: &str = "9c1e4b7a2d5f8e3c6b9a0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a";

fn header() -> Record {
    Record::Header {
        vocab: VOCAB,
        protocol_level: 0,
        recorder_id: "codetracer-boundary-shim/0.1.0".into(),
        framework: String::new(),
        build_hash: BUILD_HASH.into(),
        session_id: SESSION_ID.into(),
        prev_session: String::new(),
        capabilities: "[]".into(),
    }
}

fn env() -> Record {
    Record::Env {
        ua: "Mozilla/5.0 (X11; Linux x86_64) Chrome/141.0.0.0".into(),
        ua_major: 141,
        viewport_w: 1280,
        viewport_h: 800,
        dpr: 1.5,
        locale: "en-GB".into(),
        tz: "Europe/Sofia".into(),
        fonts_digest: "a1b2c3d4".into(),
        color_scheme: 1,
        reduced_motion: 0,
        arms: r#"{"hero":"b"}"#.into(),
        url: "https://shop.example/checkout".into(),
        referrer_origin: "https://search.example".into(),
        traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01".into(),
    }
}

fn end(last_seq: u64) -> Record {
    Record::End {
        last_seq,
        reason: 1,
    }
}

/// `Date.now()` = 1761000000123 ms, as IEEE-754 bits.
const NOW_BITS: u64 = 0x4279_A0C9_D5DF_B000;

/// One record of each seq-bearing kind (and `Gap`), each at `seq`.
fn one_of_each(seq: u64) -> Vec<(&'static str, Record)> {
    vec![
        (
            "task",
            Record::Task {
                seq,
                task_id: 7,
                kind: 1,
            },
        ),
        (
            "task_reg",
            Record::TaskReg {
                seq,
                task_id: 7,
                kind: 1,
                delay_ms: 16.5,
            },
        ),
        (
            "clock",
            Record::Clock {
                seq,
                src: 1,
                bits: NOW_BITS,
            },
        ),
        (
            "random",
            Record::Random {
                seq,
                src: 2,
                bytes: vec![0x00, 0x7f, 0x80, 0xff, 0x10, 0x20, 0x30, 0x40],
            },
        ),
        (
            "net_request",
            Record::NetRequest {
                seq,
                req_id: 3,
                api: 1,
                method: "POST".into(),
                url: "https://api.shop.example/cart?item=…".into(),
                body_digest: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae"
                    .into(),
            },
        ),
        (
            "net_response_inline",
            Record::NetResponse {
                seq,
                req_id: 3,
                outcome: 1,
                status: 200,
                headers: r#"[["content-type","application/json"]]"#.into(),
                body: BlobRef::Inline(br#"{"ok":true}"#.to_vec()),
            },
        ),
        (
            "net_response_ref",
            Record::NetResponse {
                seq,
                req_id: 4,
                outcome: 1,
                status: 200,
                headers: "[]".into(),
                body: BlobRef::Ref {
                    sha256: Sha256::digest(vec![b'x'; 2048]).into(),
                    len: 2048,
                },
            },
        ),
        (
            "ws_message",
            Record::WsMessage {
                seq,
                req_id: 5,
                dir: 1,
                data: BlobRef::Inline(b"ping".to_vec()),
            },
        ),
        (
            "storage_read",
            Record::StorageRead {
                seq,
                area: 1,
                key: "cart".into(),
                present: 1,
                value: "[42]".into(),
            },
        ),
        (
            "layout_read",
            Record::LayoutRead {
                seq,
                target: "iid:buy-button".into(),
                prop: "getBoundingClientRect".into(),
                value: r#"{"x":10,"y":20,"width":120,"height":40}"#.into(),
            },
        ),
        (
            "input",
            Record::Input {
                seq,
                task_id: 9,
                r#type: "click".into(),
                target: "iid:buy-button".into(),
                props: r#"{"button":0,"clientX":70,"clientY":40}"#.into(),
                label: "Купи".into(),
            },
        ),
        (
            "dom_effect",
            Record::DomEffect {
                seq,
                target: "iid:email".into(),
                effect: 1,
                value: r#""ada@example.com""#.into(),
            },
        ),
        (
            "checkpoint",
            Record::Checkpoint {
                seq,
                ordinal: 0,
                scheme: "isonim-signals/1".into(),
                state_hash: "0f1e2d3c".into(),
                dom_digest: String::new(),
            },
        ),
        (
            "refusal",
            Record::Refusal {
                seq,
                feature: "WebWorker".into(),
                detail: "new Worker('w.js')".into(),
            },
        ),
        (
            "navigation",
            Record::Navigation {
                seq,
                kind: 1,
                url: "https://shop.example/checkout/pay".into(),
            },
        ),
        (
            "error",
            Record::Error {
                seq,
                kind: 1,
                message: "TypeError: cannot read {0} of undefined".into(),
                frames: r#"[{"url":"https://shop.example/app.js","line":1,"col":4242,"fn":"pay"}]"#
                    .into(),
            },
        ),
        (
            "scrubbed",
            Record::Scrubbed {
                seq,
                target: "iid:card".into(),
                class: 2,
                length: 16,
            },
        ),
        (
            "mark",
            Record::Mark {
                seq,
                name: "exposure".into(),
                data: r#"{"experiment":"hero","arm":"b"}"#.into(),
            },
        ),
        (
            "xhr_event",
            Record::XhrEvent {
                seq,
                req_id: 3,
                target: 1,
                event: 2,
                loaded: 65_536,
                total: 2_097_152,
                length_computable: 1,
            },
        ),
    ]
}

/// An XMLHttpRequest that uploads a body and downloads a response, with the
/// `XhrEvent` of every `ProgressEvent` it dispatches (spec §5.2, §6, §10.4):
/// `loadstart` inside `send()` (no `Task`), the upload object's `progress`,
/// `load` and `loadend` in network tasks of their own, the head and a piece
/// at `readystatechange` (no `XhrEvent`), a `progress` with what the page
/// can read, the last `progress` at DONE, then `load` and `loadend`.
fn xhr_events_records() -> Vec<Record> {
    let xhr_event = |seq, target, event, loaded, total, length_computable| Record::XhrEvent {
        seq,
        req_id: 1,
        target,
        event,
        loaded,
        total,
        length_computable,
    };
    let task = |seq| Record::Task {
        seq,
        task_id: 1,
        kind: 4,
    };
    let piece = |seq, data: &[u8]| Record::WsMessage {
        seq,
        req_id: 1,
        dir: 1,
        data: BlobRef::Inline(data.to_vec()),
    };
    vec![
        header(),
        env(),
        Record::NetRequest {
            seq: 1,
            req_id: 1,
            api: 2,
            method: "POST".into(),
            url: "https://shop.example/api/upload".into(),
            body_digest: "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae".into(),
        },
        Record::TaskReg {
            seq: 2,
            task_id: 1,
            kind: 4,
            delay_ms: 0.0,
        },
        xhr_event(3, 1, 1, 0, 0, 0),
        xhr_event(4, 2, 1, 0, 3_000_000, 1),
        task(5),
        xhr_event(6, 2, 2, 65_536, 3_000_000, 1),
        task(7),
        xhr_event(8, 2, 5, 3_000_000, 3_000_000, 1),
        task(9),
        xhr_event(10, 2, 7, 3_000_000, 3_000_000, 1),
        task(11),
        Record::NetResponse {
            seq: 12,
            req_id: 1,
            outcome: 5,
            status: 200,
            headers: r#"[["content-type","text/plain"]]"#.into(),
            body: BlobRef::Inline(Vec::new()),
        },
        task(13),
        piece(14, b"c0\n"),
        task(15),
        piece(16, b"c1\n"),
        xhr_event(17, 1, 2, 6, 0, 0),
        task(18),
        piece(19, b"c2\n"),
        Record::WsMessage {
            seq: 20,
            req_id: 1,
            dir: 4,
            data: BlobRef::Inline(br#"{"outcome":1}"#.to_vec()),
        },
        xhr_event(21, 1, 2, 9, 0, 0),
        xhr_event(22, 1, 5, 9, 0, 0),
        xhr_event(23, 1, 7, 9, 0, 0),
        end(23),
    ]
}

fn complete(name: &str, description: &str, records: Vec<Record>) -> Vector {
    Vector {
        name: name.into(),
        description: description.into(),
        bytes: encode_log(&records).0,
        expectation: Expectation::Decodes {
            records,
            termination: Termination::Complete,
        },
    }
}

/// The records of the `session` vector: every kind, in one stream, with a
/// `Gap`.
fn session_records() -> Vec<Record> {
    let mut records = vec![header(), env()];
    let mut seq = 1;
    for (name, mut r) in one_of_each(0) {
        set_seq(&mut r, seq);
        records.push(r);
        seq += 1;
        if name == "checkpoint" {
            records.push(Record::Gap {
                first_seq: seq,
                last_seq: seq + 2,
                reason: 1,
            });
            seq += 3;
        }
    }
    records.push(end(seq - 1));
    records
}

/// A streamed `fetch` response (spec §5.2, §6, §10.4).
fn streamed_response_records() -> Vec<Record> {
    let piece = |seq, data: &[u8]| Record::WsMessage {
        seq,
        req_id: 1,
        dir: 1,
        data: BlobRef::Inline(data.to_vec()),
    };
    vec![
        header(),
        env(),
        Record::NetRequest {
            seq: 1,
            req_id: 1,
            api: 1,
            method: "GET".into(),
            url: "https://shop.example/api/stream".into(),
            body_digest: String::new(),
        },
        Record::TaskReg {
            seq: 2,
            task_id: 1,
            kind: 4,
            delay_ms: 0.0,
        },
        Record::Task {
            seq: 3,
            task_id: 1,
            kind: 4,
        },
        Record::NetResponse {
            seq: 4,
            req_id: 1,
            outcome: 5,
            status: 200,
            headers: r#"[["content-type","text/plain"]]"#.into(),
            body: BlobRef::Inline(Vec::new()),
        },
        piece(5, b"c0\n"),
        Record::Task {
            seq: 6,
            task_id: 1,
            kind: 4,
        },
        piece(7, b"c1\n"),
        Record::WsMessage {
            seq: 8,
            req_id: 1,
            dir: 4,
            data: BlobRef::Inline(br#"{"outcome":1}"#.to_vec()),
        },
        end(8),
    ]
}

/// The `session` records with every enumerated field (`Header`, `Env`,
/// `Gap` and `End` included) set to the greatest value of its set.
fn enum_greatest_records() -> Vec<Record> {
    let mut records = session_records();
    for r in &mut records {
        for &(record, field, _, hi) in VALUE_SETS {
            if r.kind_name() == record {
                assert!(r.set_u8_field(field, hi), "{record}.{field} is a u8 field");
            }
        }
    }
    records
}

/// `NetResponse` -> `net_response`.
fn snake(name: &str) -> String {
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

/// One refusal vector per end of every value set: the `enum_greatest`
/// vector with one enumerated field one past its greatest value, or one
/// before its least (0, for a set that starts at 1). Each differs from the
/// base in exactly that one byte.
fn enum_refusal_vectors(valid: &BTreeMap<String, Vector>) -> Vec<Vector> {
    let base = &valid["enum_greatest"];
    let mut out = Vec::new();
    for &(record, field, lo, hi) in VALUE_SETS {
        let mut values = vec![(hi.checked_add(1), "one past its greatest value")];
        if lo > 0 {
            values.push((Some(lo - 1), "one before its least value"));
        }
        for (value, which) in values {
            let Some(value) = value else { continue };
            let mut records = enum_greatest_records();
            let at = records
                .iter()
                .position(|r| r.kind_name() == record)
                .expect("enum_greatest has every record kind");
            assert!(records[at].set_u8_field(field, value));
            let bytes = encode_log(&records).0;
            let differing = bytes
                .iter()
                .zip(&base.bytes)
                .filter(|(a, b)| a != b)
                .count();
            assert!(
                bytes.len() == base.bytes.len() && differing == 1,
                "the {record}.{field} edit is one byte"
            );
            out.push(Vector {
                name: format!("enum_{}_{field}_{value}", snake(record)),
                description: format!("{record}.{field} is {value}, {which} ({lo} to {hi})"),
                bytes,
                expectation: Expectation::Refused {
                    base: "enum_greatest".into(),
                    error: DecodeErrorKind::UnknownEnumValue,
                },
            });
        }
    }
    out
}

fn set_seq(r: &mut Record, value: u64) {
    match r {
        Record::Task { seq, .. }
        | Record::TaskReg { seq, .. }
        | Record::Clock { seq, .. }
        | Record::Random { seq, .. }
        | Record::NetRequest { seq, .. }
        | Record::NetResponse { seq, .. }
        | Record::WsMessage { seq, .. }
        | Record::StorageRead { seq, .. }
        | Record::LayoutRead { seq, .. }
        | Record::Input { seq, .. }
        | Record::DomEffect { seq, .. }
        | Record::Checkpoint { seq, .. }
        | Record::Refusal { seq, .. }
        | Record::Navigation { seq, .. }
        | Record::Error { seq, .. }
        | Record::Scrubbed { seq, .. }
        | Record::Mark { seq, .. }
        | Record::XhrEvent { seq, .. } => *seq = value,
        _ => panic!("set_seq on a record without seq"),
    }
}

/// The valid and truncation vectors.
fn decoding_vectors() -> Vec<Vector> {
    let mut out = vec![complete(
        "minimal",
        "Header, Env and End: the shortest complete log",
        vec![header(), env(), end(0)],
    )];
    for (name, r) in one_of_each(1) {
        let kind = r.kind_name();
        out.push(complete(
            name,
            &format!("one {kind} record at seq 1"),
            vec![header(), env(), r, end(1)],
        ));
    }
    out.push(complete(
        "gap",
        "a Gap covering seq 2..4 between seq 1 and seq 5",
        vec![
            header(),
            env(),
            Record::Task {
                seq: 1,
                task_id: 1,
                kind: 11,
            },
            Record::Gap {
                first_seq: 2,
                last_seq: 4,
                reason: 2,
            },
            Record::Clock {
                seq: 5,
                src: 2,
                bits: 0x4059_0000_0000_0000,
            },
            end(5),
        ],
    ));
    out.push(complete(
        "end_idle",
        "End appended by the assembler on idle finalisation (reason 3)",
        vec![
            header(),
            env(),
            Record::Task {
                seq: 1,
                task_id: 1,
                kind: 1,
            },
            Record::End {
                last_seq: 1,
                reason: 3,
            },
        ],
    ));
    out.push(complete(
        "net_response_inline_max",
        "an inline body of exactly 1024 bytes, the most jsbound.log inlines",
        vec![
            header(),
            env(),
            Record::NetResponse {
                seq: 1,
                req_id: 1,
                outcome: 1,
                status: 200,
                headers: "[]".into(),
                body: BlobRef::Inline(vec![b'a'; MAX_INLINE_BLOB]),
            },
            end(1),
        ],
    ));
    out.push(complete(
        "session",
        "every record kind in one stream, with a Gap after the Checkpoint",
        session_records(),
    ));
    out.push(complete(
        "streamed_response",
        "a fetch whose body streams: its head (NetResponse outcome 5, no body), \
         two pieces (WsMessage dir 1), the second in a network task of its \
         own, and the end (WsMessage dir 4)",
        streamed_response_records(),
    ));
    out.push(complete(
        "xhr_events",
        "an XMLHttpRequest's ProgressEvents (XhrEvent): loadstart inside \
         send(), the upload object's progress, load and loadend each in a \
         network task, the response's progress events with the values the \
         page reads, the last at DONE, then load and loadend",
        xhr_events_records(),
    ));
    out.push(complete(
        "storage_shape_reads",
        "StorageRead present 2: the key list, length and key(n) of an area",
        vec![
            header(),
            env(),
            Record::StorageRead {
                seq: 1,
                area: 1,
                key: "keys".into(),
                present: 2,
                value: r#"["a","b"]"#.into(),
            },
            Record::StorageRead {
                seq: 2,
                area: 2,
                key: "length".into(),
                present: 2,
                value: "0".into(),
            },
            Record::StorageRead {
                seq: 3,
                area: 1,
                key: "key".into(),
                present: 2,
                value: "null".into(),
            },
            end(3),
        ],
    ));
    out.push(complete(
        "clock_event_time_stamp",
        "Clock src 5: a read of an event's timeStamp",
        vec![
            header(),
            env(),
            Record::Clock {
                seq: 1,
                src: 5,
                bits: 0x4059_0000_0000_0000,
            },
            end(1),
        ],
    ));
    out.push(complete(
        "refusal_timer_handler",
        "a Refusal of a timer handler that is not a function",
        vec![
            header(),
            env(),
            Record::Refusal {
                seq: 1,
                feature: "unrecordable-timer-handler".into(),
                detail: "setTimeout string".into(),
            },
            end(1),
        ],
    ));
    out.push(complete(
        "enum_greatest",
        "every enumerated field at the greatest value of its set",
        enum_greatest_records(),
    ));

    // Truncation: the session without its End, and the session cut inside
    // its eleventh frame.
    let session = session_records();
    let without_end = session[..session.len() - 1].to_vec();
    out.push(Vector {
        name: "truncated_unterminated".into(),
        description: "the session vector without its End frame".into(),
        bytes: encode_log(&without_end).0,
        expectation: Expectation::Decodes {
            records: without_end,
            termination: Termination::TruncatedUnterminated,
        },
    });
    let (bytes, offsets) = encode_log(&session);
    let cut = offsets[10] as usize + 7;
    out.push(Vector {
        name: "truncated_mid_record".into(),
        description: "the session vector cut 7 bytes into its eleventh frame".into(),
        bytes: bytes[..cut].to_vec(),
        expectation: Expectation::Decodes {
            records: session[..10].to_vec(),
            termination: Termination::TruncatedMidRecord,
        },
    });
    out
}

/// Frame offsets of a valid vector's log.
fn offsets_of(v: &Vector) -> Vec<usize> {
    let Expectation::Decodes { records, .. } = &v.expectation else {
        unreachable!("a base is a decoding vector")
    };
    encode_log(records)
        .1
        .into_iter()
        .map(|o| o as usize)
        .collect()
}

fn set_u32(bytes: &mut [u8], at: usize, v: u32) {
    bytes[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

fn set_u64(bytes: &mut [u8], at: usize, v: u64) {
    bytes[at..at + 8].copy_from_slice(&v.to_le_bytes());
}

fn frame_len(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().expect("4 bytes"))
}

/// The refusal vectors: each one edit away from its base.
fn refusal_vectors(valid: &BTreeMap<String, Vector>) -> Vec<Vector> {
    type Edit = Box<dyn Fn(&mut Vec<u8>, &[usize])>;
    // (name, base, error, description, edit). Frame offsets are those of the
    // base; frame 0 is Header, 1 Env, 2 the base's own record.
    let cases: Vec<(&str, &str, DecodeErrorKind, &str, Edit)> = vec![
        (
            "bad_magic",
            "minimal",
            DecodeErrorKind::BadMagic,
            "the first magic byte is 'X' instead of 'C'",
            Box::new(|b, _| b[0] = b'X'),
        ),
        (
            "ctbl_version_2",
            "minimal",
            DecodeErrorKind::UnsupportedVersion,
            "the CTBL version byte is 2",
            Box::new(|b, _| b[4] = 2),
        ),
        (
            "vocab_2",
            "minimal",
            DecodeErrorKind::UnsupportedVocab,
            "the Header's vocab is 2",
            Box::new(|b, o| b[o[0] + 5] = 2),
        ),
        (
            "unknown_tag",
            "clock",
            DecodeErrorKind::UnknownTag,
            "the third frame's tag is 0x54, unassigned in the jsbound range",
            Box::new(|b, o| b[o[2] + 4] = 0x54),
        ),
        (
            "empty_frame",
            "clock",
            DecodeErrorKind::EmptyFrame,
            "the third frame declares length 0",
            Box::new(|b, o| set_u32(b, o[2], 0)),
        ),
        (
            "frame_too_large",
            "clock",
            DecodeErrorKind::FrameTooLarge,
            "the third frame declares 64 MiB + 1 bytes",
            Box::new(|b, o| set_u32(b, o[2], MAX_FRAME_LEN + 1)),
        ),
        (
            "field_overrun",
            "clock",
            DecodeErrorKind::FieldOverrun,
            "the third frame declares one byte fewer than its fields need",
            Box::new(|b, o| {
                let n = frame_len(b, o[2]);
                set_u32(b, o[2], n - 1)
            }),
        ),
        (
            "trailing_field_bytes",
            "clock",
            DecodeErrorKind::TrailingFieldBytes,
            "the third frame declares one byte more than its fields",
            Box::new(|b, o| {
                let n = frame_len(b, o[2]);
                set_u32(b, o[2], n + 1)
            }),
        ),
        (
            "invalid_utf8",
            "minimal",
            DecodeErrorKind::InvalidUtf8,
            "the first byte of the Header's recorder_id is 0xff",
            // Header payload: tag(1) vocab(2) protocol_level(1) len(4) bytes.
            Box::new(|b, o| b[o[0] + 4 + 1 + 2 + 1 + 4] = 0xff),
        ),
        (
            "unknown_blob_kind",
            "net_response_inline",
            DecodeErrorKind::UnknownBlobKind,
            "the NetResponse body's blobref kind is 2",
            // The body is the last field: kind(1) len(4) 11 bytes.
            Box::new(|b, o| b[o[3] - 1 - 4 - 11] = 2),
        ),
        (
            "inline_blob_too_large",
            "net_response_inline_max",
            DecodeErrorKind::InlineBlobTooLarge,
            "the inline body is one byte longer: 1025 bytes",
            Box::new(|b, o| {
                let frame = encode_frame(&Record::NetResponse {
                    seq: 1,
                    req_id: 1,
                    outcome: 1,
                    status: 200,
                    headers: "[]".into(),
                    body: BlobRef::Inline(vec![b'a'; MAX_INLINE_BLOB + 1]),
                });
                b.splice(o[2]..o[3], frame);
            }),
        ),
        (
            "header_not_first",
            "minimal",
            DecodeErrorKind::HeaderNotFirst,
            "the Header and Env frames are swapped",
            Box::new(|b, o| {
                let header = b[o[0]..o[1]].to_vec();
                let env = b[o[1]..o[2]].to_vec();
                b.splice(o[0]..o[2], env.into_iter().chain(header));
            }),
        ),
        (
            "env_not_second",
            "clock",
            DecodeErrorKind::EnvNotSecond,
            "the Env and Clock frames are swapped",
            Box::new(|b, o| {
                let env = b[o[1]..o[2]].to_vec();
                let clock = b[o[2]..o[3]].to_vec();
                b.splice(o[1]..o[3], clock.into_iter().chain(env));
            }),
        ),
        (
            "seq_skip_without_gap",
            "clock",
            DecodeErrorKind::SeqDiscontinuity,
            "the Clock's seq is 2 where the first seq must be 1, with no Gap",
            Box::new(|b, o| set_u64(b, o[2] + 5, 2)),
        ),
        (
            "gap_mismatch",
            "gap",
            DecodeErrorKind::GapMismatch,
            "the Gap's first_seq is 3, leaving seq 2 uncovered",
            Box::new(|b, o| set_u64(b, o[3] + 5, 3)),
        ),
        (
            "end_seq_mismatch",
            "clock",
            DecodeErrorKind::EndSeqMismatch,
            "End.last_seq is 2, but the last seq is 1",
            Box::new(|b, o| set_u64(b, o[3] + 5, 2)),
        ),
        (
            "bytes_after_end",
            "minimal",
            DecodeErrorKind::BytesAfterEnd,
            "one 0x00 byte after the End frame",
            Box::new(|b, _| b.push(0)),
        ),
    ];
    cases
        .into_iter()
        .map(|(name, base, error, description, edit)| {
            let base_vector = &valid[base];
            let mut bytes = base_vector.bytes.clone();
            edit(&mut bytes, &offsets_of(base_vector));
            Vector {
                name: name.into(),
                description: description.into(),
                bytes,
                expectation: Expectation::Refused {
                    base: base.into(),
                    error,
                },
            }
        })
        .collect()
}

/// Every shared vector, in a fixed order: valid, truncation, refusal.
pub fn catalogue() -> Vec<Vector> {
    let decoding = decoding_vectors();
    let by_name: BTreeMap<String, Vector> = decoding
        .iter()
        .map(|v| (v.name.clone(), v.clone()))
        .collect();
    let mut all = decoding;
    all.extend(refusal_vectors(&by_name));
    all.extend(enum_refusal_vectors(&by_name));
    all
}

/// The manifest that lists the vectors: name, class, files, base, description.
pub fn manifest(vectors: &[Vector]) -> Value {
    json!({
        "format": "jsbound shared vectors (JS-Boundary-Recording.md §5)",
        "vocab": VOCAB,
        "vectors": vectors.iter().map(|v| {
            let mut entry = json!({
                "name": v.name,
                "class": v.class(),
                "bytes": format!("{}.bin", v.name),
                "expected": format!("{}.json", v.name),
                "description": v.description,
            });
            if let Expectation::Refused { base, .. } = &v.expectation {
                entry["base"] = json!(base);
            }
            entry
        }).collect::<Vec<_>>(),
    })
}

fn pretty(v: &Value) -> Vec<u8> {
    let mut s = serde_json::to_vec_pretty(v).expect("JSON serialises");
    s.push(b'\n');
    s
}

/// Every file of `libs/jsbound/vectors/`, by name: each vector's `.bin` and
/// `.json`, `manifest.json`, and `SHA256SUMS` over all of them.
pub fn render() -> BTreeMap<String, Vec<u8>> {
    let vectors = catalogue();
    let mut files = BTreeMap::new();
    for v in &vectors {
        files.insert(format!("{}.bin", v.name), v.bytes.clone());
        files.insert(format!("{}.json", v.name), pretty(&v.expected_json()));
    }
    files.insert("manifest.json".into(), pretty(&manifest(&vectors)));
    let mut sums = String::new();
    for (name, bytes) in &files {
        sums.push_str(&format!("{}  {name}\n", hex(&Sha256::digest(bytes))));
    }
    files.insert("SHA256SUMS".into(), sums.into_bytes());
    files
}

/// Decode `bytes` and say whether the result is what `v` expects; used by
/// the generator to refuse writing a catalogue its own decoder disagrees
/// with, and by the tests.
pub fn check(v: &Vector, bytes: &[u8]) -> Result<(), String> {
    match (&v.expectation, decode_log(bytes)) {
        (
            Expectation::Decodes {
                records,
                termination,
            },
            Ok(got),
        ) => {
            if got.termination != *termination {
                return Err(format!(
                    "decodes as {}, expected {}",
                    got.termination.name(),
                    termination.name()
                ));
            }
            let got_json: Vec<Value> = got.records.iter().map(Record::to_json).collect();
            let want_json: Vec<Value> = records.iter().map(Record::to_json).collect();
            if got_json != want_json {
                return Err(format!(
                    "decodes to {}\nexpected {}",
                    Value::from(got_json),
                    Value::from(want_json)
                ));
            }
            Ok(())
        }
        (Expectation::Decodes { .. }, Err(e)) => Err(format!("refused: {e}")),
        (Expectation::Refused { error, .. }, Err(e)) if e.kind == *error => Ok(()),
        (Expectation::Refused { error, .. }, Err(e)) => Err(format!(
            "refused with {}, expected {}: {e}",
            e.kind.name(),
            error.name()
        )),
        (Expectation::Refused { error, .. }, Ok(got)) => Err(format!(
            "decodes ({} records, {}), expected refusal {}",
            got.records.len(),
            got.termination.name(),
            error.name()
        )),
    }
}
