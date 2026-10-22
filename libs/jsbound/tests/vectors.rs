//! The shared byte vectors, read from `libs/jsbound/vectors/` as committed:
//! the bytes the TypeScript decoder in codetracer-js-recorder is held to.
//!
//! No mocks: these tests read the committed files and run the real decoder
//! and encoder over them.
//!
//! JBR-M1 verification entries (codetracer-pm
//! milestones/Cooperative-JS-Boundary-Recording.milestones.org):
//! `test_jsbound_vectors_roundtrip`, `test_jsbound_strict_decode_refusals`,
//! `test_jsbound_truncation_classified`.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use serde_json::Value;
use sha2::{Digest, Sha256};

use jsbound::record::hex;
use jsbound::{decode_log, encode_log, DecodeErrorKind, Record, Termination, RECORD_KINDS};

fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vectors")
}

struct OnDisk {
    name: String,
    class: String,
    base: Option<String>,
    bytes: Vec<u8>,
    expected: Value,
}

/// Every vector the committed manifest lists, with its committed bytes and
/// expectation.
fn load() -> Vec<OnDisk> {
    let dir = vectors_dir();
    let manifest: Value = serde_json::from_slice(
        &fs::read(dir.join("manifest.json")).expect("vectors/manifest.json"),
    )
    .unwrap();
    manifest["vectors"]
        .as_array()
        .expect("manifest.vectors is an array")
        .iter()
        .map(|v| {
            let s = |k: &str| {
                v[k].as_str()
                    .unwrap_or_else(|| panic!("manifest entry lacks {k}: {v}"))
                    .to_string()
            };
            OnDisk {
                name: s("name"),
                class: s("class"),
                base: v["base"].as_str().map(str::to_string),
                bytes: fs::read(dir.join(s("bytes"))).unwrap(),
                expected: serde_json::from_slice(&fs::read(dir.join(s("expected"))).unwrap())
                    .unwrap(),
            }
        })
        .collect()
}

fn records_json(records: &[Record]) -> Value {
    Value::from(records.iter().map(Record::to_json).collect::<Vec<_>>())
}

/// Every valid and truncation vector decodes to its expected JSON, and
/// re-encoding what was decoded gives the vector's bytes back. For
/// `TruncatedMidRecord` the partial frame is discarded by rule, so the
/// re-encoding is compared with the vector up to the last whole frame.
///
/// Vacuity guard: at least as many valid vectors as record kinds, and every
/// kind of §5.2 decoded at least once.
#[test]
fn test_jsbound_vectors_roundtrip() {
    let vectors = load();
    let mut failures = Vec::new();
    let mut kinds_seen = BTreeSet::new();
    let mut valid = 0usize;
    for v in vectors.iter().filter(|v| v.class != "refusal") {
        let decoded = match decode_log(&v.bytes) {
            Ok(d) => d,
            Err(e) => {
                failures.push(format!("{}: refused: {e}", v.name));
                continue;
            }
        };
        if v.class == "valid" {
            valid += 1;
        }
        let got = serde_json::json!({
            "termination": decoded.termination.name(),
            "records": records_json(&decoded.records),
        });
        if got != v.expected {
            failures.push(format!(
                "{}: decodes to\n{got:#}\nexpected\n{:#}",
                v.name, v.expected
            ));
            continue;
        }
        kinds_seen.extend(decoded.records.iter().map(Record::kind_name));
        let (reencoded, _) = encode_log(&decoded.records);
        let want: &[u8] = match decoded.termination {
            Termination::TruncatedMidRecord => &v.bytes[..reencoded.len().min(v.bytes.len())],
            _ => &v.bytes,
        };
        if reencoded != want {
            failures.push(format!(
                "{}: re-encoding does not reproduce the vector's bytes",
                v.name
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "{} vector(s) failed:\n{}",
        failures.len(),
        failures.join("\n")
    );

    assert!(
        valid >= RECORD_KINDS.len(),
        "only {valid} valid vectors for {} record kinds",
        RECORD_KINDS.len()
    );
    let missing: Vec<&str> = RECORD_KINDS
        .iter()
        .map(|&(_, name)| name)
        .filter(|name| !kinds_seen.contains(name))
        .collect();
    assert!(
        missing.is_empty(),
        "no vector decodes a record of kind(s) {missing:?}"
    );
}

/// Each refusal vector is refused with its own named error, and its base
/// (the negative control) decodes cleanly, so the refusal is caused by the
/// one edit. Every refusal the decoder can make has a vector.
#[test]
fn test_jsbound_strict_decode_refusals() {
    let vectors = load();
    let mut failures = Vec::new();
    let mut errors_covered = BTreeSet::new();
    for v in vectors.iter().filter(|v| v.class == "refusal") {
        let want = v.expected["error"]
            .as_str()
            .expect("a refusal expects an error name");
        errors_covered.insert(want.to_string());
        match decode_log(&v.bytes) {
            Ok(d) => failures.push(format!(
                "{}: decoded ({} records, {}), expected {want}",
                v.name,
                d.records.len(),
                d.termination.name()
            )),
            Err(e) if e.kind.name() != want => failures.push(format!(
                "{}: refused as {}, expected {want}: {e}",
                v.name,
                e.kind.name()
            )),
            Err(_) => {}
        }
        // Negative control: the base, without the edit, decodes completely.
        let base_name = v
            .base
            .as_deref()
            .unwrap_or_else(|| panic!("{} names no base", v.name));
        let base = vectors
            .iter()
            .find(|b| b.name == base_name)
            .expect("the base vector exists");
        match decode_log(&base.bytes) {
            Ok(d) if d.termination == Termination::Complete => {}
            other => failures.push(format!(
                "{}: its base {base_name} does not decode cleanly: {other:?}",
                v.name
            )),
        }
        if base.bytes == v.bytes {
            failures.push(format!("{}: identical to its base {base_name}", v.name));
        }
    }
    assert!(
        failures.is_empty(),
        "{} refusal(s) failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
    let uncovered: Vec<&str> = DecodeErrorKind::ALL
        .iter()
        .map(|k| k.name())
        .filter(|n| !errors_covered.contains(*n))
        .collect();
    assert!(uncovered.is_empty(), "no refusal vector for {uncovered:?}");
    // The seven the milestone names, by name.
    for name in [
        "unknown_tag",
        "vocab_2",
        "ctbl_version_2",
        "frame_too_large",
        "bytes_after_end",
        "seq_skip_without_gap",
        "header_not_first",
    ] {
        assert!(
            vectors.iter().any(|v| v.name == name),
            "the refusal vector {name} is missing"
        );
    }
}

/// The complete `session` vector cut at every byte offset is never reported
/// complete: exactly the cuts at frame boundaries are
/// `TruncatedUnterminated` (and carry exactly the frames before the cut),
/// every other cut is `TruncatedMidRecord`.
///
/// Vacuity guard: both classes are observed, and the number of
/// `TruncatedUnterminated` cuts equals the vector's frame count (the cut
/// after the stream prefix, and after each frame but the last).
#[test]
fn test_jsbound_truncation_classified() {
    let session = load()
        .into_iter()
        .find(|v| v.name == "session")
        .expect("the session vector");
    let full = decode_log(&session.bytes).expect("the session vector decodes");
    assert_eq!(full.termination, Termination::Complete);
    let frames = full.records.len();
    let boundaries: BTreeSet<usize> = std::iter::once(5usize)
        .chain(full.offsets.iter().skip(1).map(|&o| o as usize))
        .collect();

    let (mut unterminated, mut mid) = (0usize, 0usize);
    for cut in 0..session.bytes.len() {
        let d = decode_log(&session.bytes[..cut])
            .unwrap_or_else(|e| panic!("the session vector cut at {cut} is refused: {e}"));
        match d.termination {
            Termination::Complete => panic!("the cut at {cut} is reported complete"),
            Termination::TruncatedUnterminated => {
                unterminated += 1;
                assert!(
                    boundaries.contains(&cut),
                    "cut {cut} is unterminated but not at a frame boundary"
                );
                let before = boundaries.range(..cut).count();
                assert_eq!(
                    d.records.len(),
                    before,
                    "cut {cut} carries the wrong records"
                );
                assert_eq!(d.records[..], full.records[..before]);
            }
            Termination::TruncatedMidRecord => {
                mid += 1;
                assert!(
                    !boundaries.contains(&cut),
                    "cut {cut} is at a frame boundary but classified mid-record"
                );
            }
        }
    }
    assert!(mid > 0, "no TruncatedMidRecord cut observed");
    assert_eq!(
        unterminated, frames,
        "TruncatedUnterminated cuts must equal the frame count"
    );
}

/// The committed directory is exactly what the catalogue renders: no vector
/// edited by hand, none missing, none stale.
#[test]
fn committed_vectors_are_the_catalogue() {
    let dir = vectors_dir();
    let rendered = jsbound::vectors::render();
    let mut on_disk: Vec<String> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    on_disk.sort();
    let want: Vec<String> = rendered.keys().cloned().collect();
    assert_eq!(
        on_disk, want,
        "vectors/ does not hold exactly the catalogue's files"
    );
    for (name, bytes) in &rendered {
        assert!(
            &fs::read(dir.join(name)).unwrap() == bytes,
            "vectors/{name} differs from the catalogue; run `cargo run --example generate_vectors`"
        );
    }
}

/// `SHA256SUMS` names every other file with its hash; the vendoring script
/// in codetracer-js-recorder trusts it.
#[test]
fn sha256sums_cover_every_vector_file() {
    let dir = vectors_dir();
    let sums = fs::read_to_string(dir.join("SHA256SUMS")).unwrap();
    let mut listed = BTreeSet::new();
    for line in sums.lines() {
        let (hash, name) = line.split_once("  ").expect("`<sha256>  <file>` lines");
        assert_eq!(
            hash,
            hex(&Sha256::digest(fs::read(dir.join(name)).unwrap())),
            "{name}"
        );
        listed.insert(name.to_string());
    }
    for entry in fs::read_dir(&dir).unwrap() {
        let name = entry.unwrap().file_name().into_string().unwrap();
        assert!(
            name == "SHA256SUMS" || listed.contains(&name),
            "{name} is not in SHA256SUMS"
        );
    }
}

/// The encoding is pinned byte for byte against the spec's layout, written
/// out by hand here rather than produced by the encoder, so that a layout
/// change made identically in the encoder and the decoder still fails.
#[test]
fn frames_are_encoded_exactly_as_the_spec_lays_them_out() {
    use jsbound::{encode_frame, BlobRef};
    assert_eq!(
        encode_frame(&Record::Clock {
            seq: 1,
            src: 2,
            bits: 0x4059_0000_0000_0000
        }),
        [18, 0, 0, 0, 0x44, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0x59, 0x40]
    );
    assert_eq!(
        encode_frame(&Record::Gap {
            first_seq: 2,
            last_seq: 4,
            reason: 2
        }),
        [18, 0, 0, 0, 0x52, 2, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 2]
    );
    assert_eq!(
        encode_frame(&Record::End {
            last_seq: 0,
            reason: 1
        }),
        [10, 0, 0, 0, 0x5F, 0, 0, 0, 0, 0, 0, 0, 0, 1]
    );
    assert_eq!(
        encode_frame(&Record::WsMessage {
            seq: 1,
            req_id: 5,
            dir: 2,
            data: BlobRef::Inline(b"hi".to_vec())
        }),
        [
            25, 0, 0, 0, 0x48, 1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0,
            b'h', b'i'
        ]
    );
    let mut sha = [0u8; 32];
    sha[0] = 0xAB;
    let frame = encode_frame(&Record::WsMessage {
        seq: 1,
        req_id: 5,
        dir: 1,
        data: BlobRef::Ref {
            sha256: sha,
            len: 2048,
        },
    });
    assert_eq!(&frame[..4], &[59, 0, 0, 0]);
    assert_eq!(frame[22], 1, "blobref kind 1");
    assert_eq!(frame[23], 0xAB);
    assert_eq!(&frame[55..63], &2048u64.to_le_bytes());
    // `str` lengths count UTF-8 bytes: "é" is two.
    assert_eq!(
        encode_frame(&Record::Mark {
            seq: 1,
            name: "é".into(),
            data: String::new()
        }),
        [19, 0, 0, 0, 0x53, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0xC3, 0xA9, 0, 0, 0, 0]
    );
    // f64 fields are the IEEE-754 bits, little-endian.
    let frame = encode_frame(&Record::TaskReg {
        seq: 1,
        task_id: 2,
        kind: 1,
        delay_ms: 16.5,
    });
    assert_eq!(&frame[22..30], &16.5f64.to_bits().to_le_bytes());
    // XhrEvent: seq, req_id, target, event, loaded, total, length_computable.
    assert_eq!(
        encode_frame(&Record::XhrEvent {
            seq: 1,
            req_id: 3,
            target: 2,
            event: 7,
            loaded: 0x0102,
            total: 0x0304,
            length_computable: 1,
        }),
        [
            36, 0, 0, 0, 0x56, 1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 7, 2, 1, 0, 0, 0,
            0, 0, 0, 4, 3, 0, 0, 0, 0, 0, 0, 1
        ]
    );
}
