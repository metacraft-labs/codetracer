//! `ct-jsbound assemble` (JS-Boundary-Recording.md §5.6): staged batches in,
//! a four-member `.ct` out.
//!
//! No mocks: the batches are written by the real encoders, assembled by the
//! real `ct-jsbound` binary (or the library function it calls), and read back
//! with `CtfsReader` through `BoundaryRecording`, which decodes the log
//! strictly and checks `jsbound.blb` and `jsbound.chk` against it.
//!
//! JBR-M1 verification entry: `test_jsbound_assemble_is_deterministic`.

mod support;

use std::collections::BTreeSet;
use std::fs;

use sha2::{Digest, Sha256};

use jsbound::record::{end_reason, gap_reason};
use jsbound::{assemble, AssembleOptions, BlobRef, BoundaryRecording, Finalisation, Record};
use support::*;

fn options(finalisation: Finalisation) -> AssembleOptions {
    AssembleOptions {
        recording_id: RECORDING_ID.into(),
        finalisation,
        refused_batches: BTreeSet::new(),
    }
}

fn bodies(batches: &[StagedBatch]) -> Vec<Vec<u8>> {
    batches.iter().map(StagedBatch::body).collect()
}

fn gaps(rec: &BoundaryRecording) -> Vec<(u64, u64, u8)> {
    rec.log
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
        .collect()
}

/// The same staged batches assembled twice give byte-identical `.ct` files;
/// the batches presented in reverse order give the same bytes; one batch
/// removed gives a `Gap` covering exactly its `first_seq..last_seq`.
///
/// Negative control: one byte of one batch body changed (inside a string,
/// so the batch still assembles) changes the output's hash.
#[test]
fn test_jsbound_assemble_is_deterministic() {
    let tmp = tempfile::tempdir().unwrap();
    let batches = session_batches();
    let staged = stage(&tmp.path().join("staging"), &batches);

    let first = assemble_files(&tmp.path().join("a.ct"), &staged, &[]);
    let second = assemble_files(&tmp.path().join("b.ct"), &staged, &[]);
    assert_eq!(first, second, "the same batches assembled twice differ");

    let reversed: Vec<_> = staged.iter().rev().cloned().collect();
    let third = assemble_files(&tmp.path().join("c.ct"), &reversed, &[]);
    assert_eq!(
        first, third,
        "the batches in reverse order assemble differently"
    );

    // The directory form (the staging prefix) is the same input.
    let from_dir = assemble_files(&tmp.path().join("d.ct"), &[tmp.path().join("staging")], &[]);
    assert_eq!(first, from_dir);

    // The output is a real recording: it reads back and is not trivially
    // small (both blobs and checkpoints are in it).
    let rec = BoundaryRecording::read(first.clone()).expect("the assembled .ct verifies");
    assert_eq!(rec.log.records.len(), 2 + 12 + 1);
    assert!(gaps(&rec).is_empty());

    // One batch removed: batch 2 carried seq 7..=9.
    let without: Vec<_> = staged
        .iter()
        .filter(|p| !p.ends_with("2"))
        .cloned()
        .collect();
    assert_eq!(without.len(), 3);
    let holed = assemble_files(&tmp.path().join("e.ct"), &without, &[]);
    let rec = BoundaryRecording::read(holed).expect("the holed .ct verifies");
    assert_eq!(gaps(&rec), vec![(7, 9, gap_reason::BATCH_NEVER_ARRIVED)]);
    let seqs: Vec<u64> = rec.log.records.iter().filter_map(Record::seq).collect();
    assert_eq!(seqs, vec![1, 2, 3, 4, 5, 6, 10, 11, 12]);

    // Negative control: "exposure" -> "exposurf" in batch 2's Mark.
    let mut body = fs::read(&staged[2]).unwrap();
    let at = body
        .windows(8)
        .position(|w| w == b"exposure")
        .expect("batch 2 carries the Mark");
    body[at + 7] = b'f';
    let edited_dir = tmp.path().join("edited");
    fs::create_dir_all(&edited_dir).unwrap();
    for (i, p) in staged.iter().enumerate() {
        let bytes = if i == 2 {
            body.clone()
        } else {
            fs::read(p).unwrap()
        };
        fs::write(edited_dir.join(i.to_string()), bytes).unwrap();
    }
    let edited = assemble_files(&tmp.path().join("f.ct"), &[edited_dir], &[]);
    assert_ne!(
        Sha256::digest(&edited),
        Sha256::digest(&first),
        "changing one byte of one batch did not change the output"
    );
}

/// `meta.dat` carries the given `recording_id`, `recorder_id =
/// codetracer-js-boundary/1`, the page's origin and path without query or
/// fragment, empty args and workdir, and no flag.
#[test]
fn assemble_writes_the_boundary_meta_dat() {
    let a = assemble(&bodies(&session_batches()), &options(Finalisation::Ended)).unwrap();
    let rec = BoundaryRecording::read(a.container).unwrap();
    assert_eq!(rec.meta.recording_id, RECORDING_ID);
    assert_eq!(rec.meta.recorder_id, "codetracer-js-boundary/1");
    assert_eq!(rec.meta.program, "https://shop.example/cart");
    assert!(rec.meta.args.is_empty());
    assert_eq!(rec.meta.workdir, "");
    assert_eq!(rec.meta.flags, 0);
}

/// Bodies over 1024 bytes move to `jsbound.blb`, once per distinct body, in
/// first-reference order; the log references them by hash.
#[test]
fn assemble_moves_large_bodies_to_blb() {
    let a = assemble(&bodies(&session_batches()), &options(Finalisation::Ended)).unwrap();
    let rec = BoundaryRecording::read(a.container).unwrap();
    let hash: [u8; 32] = Sha256::digest(large_body()).into();
    assert_eq!(
        rec.blobs.len(),
        1,
        "the two references to one body store it once"
    );
    assert_eq!(rec.blobs.get(&hash), Some(&large_body()[..]));
    assert_eq!(a.members.blb.len(), 32 + 8 + LARGE_BODY_LEN);
    let refs: Vec<&BlobRef> = rec.log.records.iter().filter_map(Record::blob).collect();
    assert_eq!(
        refs,
        vec![
            &BlobRef::Ref {
                sha256: hash,
                len: LARGE_BODY_LEN as u64
            },
            &BlobRef::Ref {
                sha256: hash,
                len: LARGE_BODY_LEN as u64
            }
        ]
    );
}

/// `jsbound.chk` has one row per `Checkpoint`, with its ordinal, seq and the
/// offset of its frame in `jsbound.log`.
#[test]
fn assemble_indexes_checkpoints() {
    let a = assemble(&bodies(&session_batches()), &options(Finalisation::Ended)).unwrap();
    let rec = BoundaryRecording::read(a.container).unwrap();
    assert_eq!(rec.checkpoints.len(), 2);
    for (row, (ordinal, seq)) in rec.checkpoints.iter().zip([(0, 6), (1, 9)]) {
        assert_eq!((row.ordinal, row.seq), (ordinal, seq));
        let at = row.log_offset as usize;
        assert_eq!(
            a.members.log[at + 4],
            0x4D,
            "log_offset {at} is not a Checkpoint frame"
        );
        assert_eq!(&a.members.log[at + 5..at + 13], &seq.to_le_bytes());
    }
    assert_eq!(a.members.chk.len(), 2 * 20);
}

/// A recording whose `jsbound.chk` disagrees with its log is refused by the
/// reader (spec §5.5).
#[test]
fn reader_refuses_a_disagreeing_checkpoint_index() {
    let a = assemble(&bodies(&session_batches()), &options(Finalisation::Ended)).unwrap();
    let mut members = a.members.clone();
    members.chk[4] ^= 1; // seq of the first row
    let container = jsbound::container::write_container(&members).unwrap();
    let err = BoundaryRecording::read(container).unwrap_err();
    assert!(
        matches!(err, jsbound::ContainerError::CheckpointIndexMismatch(_)),
        "{err}"
    );
}

/// The envelope's `dropped` range becomes a `Gap` with reason 1.
#[test]
fn assemble_turns_dropped_into_a_ring_overflow_gap() {
    let mut batches = session_batches();
    // Batch 2 lost its first two records to the client's ring.
    batches[2]
        .records
        .retain(|r| r.seq() != Some(7) && r.seq() != Some(8));
    batches[2].dropped = vec![[7, 8]];
    let a = assemble(&bodies(&batches), &options(Finalisation::Ended)).unwrap();
    let rec = BoundaryRecording::read(a.container).unwrap();
    assert_eq!(gaps(&rec), vec![(7, 8, gap_reason::CLIENT_RING_OVERFLOW)]);
}

/// A hole that only batches the ingest refused explain is a `Gap` with
/// reason 3; with one of them not refused it is reason 2.
#[test]
fn assemble_marks_refused_batches() {
    let batches: Vec<_> = session_batches()
        .into_iter()
        .filter(|b| b.batch_seq != 1)
        .collect();
    let mut o = options(Finalisation::Ended);
    o.refused_batches.insert(1);
    let rec = BoundaryRecording::read(assemble(&bodies(&batches), &o).unwrap().container).unwrap();
    assert_eq!(gaps(&rec), vec![(4, 6, gap_reason::BATCH_REFUSED)]);

    let batches: Vec<_> = session_batches()
        .into_iter()
        .filter(|b| b.batch_seq == 0 || b.batch_seq == 3)
        .collect();
    let rec = BoundaryRecording::read(assemble(&bodies(&batches), &o).unwrap().container).unwrap();
    assert_eq!(gaps(&rec), vec![(4, 9, gap_reason::BATCH_NEVER_ARRIVED)]);
}

/// A stream without `End` gets `End{reason: 3}` when finalised as idle and
/// `End{reason: 4}` at the session cap, and is refused otherwise (through
/// the binary, which exits 1 and names the refusal).
#[test]
fn assemble_appends_end_on_idle_and_refuses_an_unterminated_stream() {
    let batches: Vec<_> = session_batches()
        .into_iter()
        .filter(|b| b.batch_seq != 3)
        .collect();
    for (finalisation, reason) in [
        (Finalisation::Idle, end_reason::IDLE_FINALISATION),
        (Finalisation::SessionCap, end_reason::SESSION_CAP),
    ] {
        let rec = BoundaryRecording::read(
            assemble(&bodies(&batches), &options(finalisation))
                .unwrap()
                .container,
        )
        .unwrap();
        assert_eq!(
            rec.log.records.last(),
            Some(&Record::End {
                last_seq: 9,
                reason
            })
        );
    }
    // A stream that ended by itself keeps its own End when finalised idle.
    let rec = BoundaryRecording::read(
        assemble(&bodies(&session_batches()), &options(Finalisation::Idle))
            .unwrap()
            .container,
    )
    .unwrap();
    assert_eq!(
        rec.log.records.last(),
        Some(&Record::End {
            last_seq: 12,
            reason: end_reason::PAGEHIDE
        })
    );

    let tmp = tempfile::tempdir().unwrap();
    let staged = stage(tmp.path(), &batches);
    let out = tmp.path().join("x.ct");
    let mut args = vec![
        "assemble",
        "--recording-id",
        RECORDING_ID,
        "--out",
        out.to_str().unwrap(),
    ];
    args.extend(staged.iter().map(|p| p.to_str().unwrap()));
    let (code, _, stderr) = ct_jsbound(&args);
    assert_eq!(code, 1, "{stderr}");
    assert!(stderr.contains("Unterminated"), "{stderr}");
    assert!(!out.exists(), "a refused assembly left an output file");
    let idle = assemble_files(&out, &staged, &["--idle"]);
    assert!(BoundaryRecording::read(idle).is_ok());
}

/// Refusals: a hole between consecutive batches that no `dropped` range
/// explains, a `Gap` sent by a recorder, a reference to a body no record
/// carried, a frame the strict decoder refuses, a batch that is not one,
/// two batches with one `batch_seq`, and a `recording_id` that is not a
/// UUIDv7. Each is refused by name and the clean session assembles (the
/// negative control).
#[test]
fn assemble_refuses_what_it_cannot_justify() {
    let refuse = |batches: Vec<StagedBatch>, name: &str| {
        let err = assemble(&bodies(&batches), &options(Finalisation::Ended)).unwrap_err();
        assert_eq!(err.name(), name, "{err}");
    };
    assert!(assemble(&bodies(&session_batches()), &options(Finalisation::Ended)).is_ok());

    let mut b = session_batches();
    b[2].records.retain(|r| r.seq() != Some(7));
    refuse(b, "UnexplainedGap");

    let mut b = session_batches();
    b[1].records.push(Record::Gap {
        first_seq: 7,
        last_seq: 7,
        reason: 2,
    });
    refuse(b, "GapFromRecorder");

    let mut b = session_batches();
    b[0].records.push(Record::NetResponse {
        seq: 4,
        req_id: 9,
        outcome: 1,
        status: 200,
        headers: "[]".into(),
        body: BlobRef::Ref {
            sha256: [7; 32],
            len: 9,
        },
    });
    b[1].records.retain(|r| r.seq() != Some(4));
    refuse(b, "MissingBlob");

    // An envelope that misstates its batch's seq range.
    let b = session_batches();
    let mut bodies_ = bodies(&b);
    bodies_[1] = jsbound::encode_batch(
        &jsbound::Envelope {
            session_id: SESSION_ID.into(),
            batch_seq: 1,
            first_seq: 4,
            last_seq: 7,
            dropped: Vec::new(),
            build_hash: BUILD_HASH.into(),
            is_final: false,
        },
        &b[1].records,
    );
    let err = assemble(&bodies_, &options(Finalisation::Ended)).unwrap_err();
    assert_eq!(err.name(), "EnvelopeSeqMismatch", "{err}");

    let mut b = session_batches();
    b[3].batch_seq = 2;
    refuse(b, "DuplicateBatch");

    let mut b = session_batches();
    b[0].records.swap(0, 1);
    refuse(b, "HeaderNotFirst");

    let mut bodies_ = bodies(&session_batches());
    bodies_[1][0] = b'X';
    let err = assemble(&bodies_, &options(Finalisation::Ended)).unwrap_err();
    assert_eq!(err.name(), "BadBatch", "{err}");

    let mut o = options(Finalisation::Ended);
    o.recording_id = "01920f3e-7c4a-4b2e-9d1f-3a5b7c9e1f20".into(); // a v4
    assert_eq!(
        assemble(&bodies(&session_batches()), &o)
            .unwrap_err()
            .name(),
        "BadRecordingId"
    );
}

/// A hole between the last record and `End.last_seq` is a hole like any
/// other (spec §5.3 rule 3: `End.last_seq` counts a `Gap`): the client's
/// ring overflowing just before `pagehide`, or the batch before a final
/// batch that carries only `End` never arriving, gives a `Gap` before the
/// `End`, not a refused stream.
#[test]
fn assemble_writes_a_gap_before_the_end() {
    // Batch 3 lost seq 10..=12 to the client's ring and carries only End.
    let mut batches = session_batches();
    batches[3].records.retain(|r| r.seq().is_none());
    batches[3].dropped = vec![[10, 12]];
    let rec = BoundaryRecording::read(
        assemble(&bodies(&batches), &options(Finalisation::Ended))
            .unwrap()
            .container,
    )
    .unwrap();
    assert_eq!(gaps(&rec), vec![(10, 12, gap_reason::CLIENT_RING_OVERFLOW)]);
    assert!(matches!(
        rec.log.records.last(),
        Some(Record::End { last_seq: 12, .. })
    ));

    // Batch 2 (seq 7..=9) never arrived and batch 3 carries only End{12}.
    let mut batches: Vec<_> = session_batches()
        .into_iter()
        .filter(|b| b.batch_seq != 2)
        .collect();
    batches[2].records.retain(|r| r.seq().is_none());
    let rec = BoundaryRecording::read(
        assemble(&bodies(&batches), &options(Finalisation::Ended))
            .unwrap()
            .container,
    )
    .unwrap();
    assert_eq!(gaps(&rec), vec![(7, 12, gap_reason::BATCH_NEVER_ARRIVED)]);

    // The same End in the batch right after the last record's, with no
    // dropped range: nothing explains the hole, so it is refused.
    let mut batches = session_batches();
    batches[3].records.retain(|r| r.seq().is_none());
    let err = assemble(&bodies(&batches), &options(Finalisation::Ended)).unwrap_err();
    assert_eq!(err.name(), "UnexplainedGap", "{err}");
}

/// `--summary` writes what the ingest stores about the session, read from
/// the assembled log, so the ingest never decodes a frame itself: the `seq`
/// range, every `Gap` with its reason, the refusals, `replayable`, an
/// `Error`, the `traceparent`'s trace id and the experiment arms. Through the
/// binary, as the ingest runs it; a refused assembly writes no summary.
///
/// Negative controls: the complete fixture session is replayable with no
/// gap, no error, no trace id and empty arms, so each field below is read
/// from the records, not defaulted.
#[test]
fn assemble_writes_a_summary_for_the_ingest() {
    let tmp = tempfile::tempdir().unwrap();
    let read_summary = |dir: &str, batches: &[StagedBatch], extra: &[&str]| {
        let staged = stage(&tmp.path().join(dir), batches);
        let summary = tmp.path().join(format!("{dir}.json"));
        let out = tmp.path().join(format!("{dir}.ct"));
        let mut args = vec!["--summary", summary.to_str().unwrap()];
        args.extend_from_slice(extra);
        let ct = assemble_files(&out, &staged, &args);
        let json: serde_json::Value = serde_json::from_slice(&fs::read(&summary).unwrap()).unwrap();
        (json, ct)
    };

    let (plain, ct) = read_summary("plain", &session_batches(), &[]);
    assert_eq!(plain["session_id"], SESSION_ID);
    assert_eq!(plain["build_hash"], BUILD_HASH);
    assert_eq!(plain["batches"], 4);
    assert_eq!(plain["first_seq"], 1);
    assert_eq!(plain["last_seq"], 12);
    assert_eq!(plain["end_reason"], end_reason::PAGEHIDE);
    assert_eq!(plain["gaps"], serde_json::json!([]));
    assert_eq!(plain["refusals"], 0);
    assert_eq!(plain["replayable"], true);
    assert_eq!(plain["has_error"], false);
    assert_eq!(plain["trace_id"], serde_json::Value::Null);
    assert_eq!(plain["arms"], serde_json::json!({}));
    assert_eq!(plain["program"], "https://shop.example/cart");
    assert_eq!(plain["container_bytes"], ct.len());
    // Header, Env, 12 seq-bearing records, End.
    assert_eq!(plain["records"], 15);

    // A session with a refusal, an error, a traceparent and arms, whose
    // batch 1 the ingest refused and whose stream never ended.
    let mut batches = session_batches();
    batches.retain(|b| b.batch_seq != 1);
    batches[0].records[1] = match env() {
        Record::Env {
            ua,
            ua_major,
            viewport_w,
            viewport_h,
            dpr,
            locale,
            tz,
            fonts_digest,
            color_scheme,
            reduced_motion,
            url,
            referrer_origin,
            ..
        } => Record::Env {
            ua,
            ua_major,
            viewport_w,
            viewport_h,
            dpr,
            locale,
            tz,
            fonts_digest,
            color_scheme,
            reduced_motion,
            url,
            referrer_origin,
            arms: r#"{"checkout":"b"}"#.into(),
            traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01".into(),
        },
        _ => unreachable!(),
    };
    let last = batches.last_mut().unwrap();
    last.records.retain(|r| !matches!(r, Record::End { .. }));
    last.records[0] = Record::Refusal {
        seq: 10,
        feature: "SharedWorker".into(),
        detail: String::new(),
    };
    last.records[1] = Record::Error {
        seq: 11,
        kind: 1,
        message: "boom".into(),
        frames: "[]".into(),
    };
    let (rich, _) = read_summary("rich", &batches, &["--idle", "--refused-batch", "1"]);
    assert_eq!(
        rich["gaps"],
        serde_json::json!([{"first_seq": 4, "last_seq": 6, "reason": gap_reason::BATCH_REFUSED}])
    );
    assert_eq!(rich["refusals"], 1);
    assert_eq!(rich["replayable"], false);
    assert_eq!(rich["has_error"], true);
    assert_eq!(rich["trace_id"], "4bf92f3577b34da6a3ce929d0e0e4736");
    assert_eq!(rich["arms"], serde_json::json!({"checkout": "b"}));
    assert_eq!(rich["last_seq"], 12);
    assert_eq!(rich["end_reason"], end_reason::IDLE_FINALISATION);

    // A Refusal alone, with no Gap, makes a session not replayable.
    let mut refusing = session_batches();
    refusing[1].records[0] = Record::Refusal {
        seq: 4,
        feature: "SharedWorker".into(),
        detail: String::new(),
    };
    let (refusal_only, _) = read_summary("refusal", &refusing, &[]);
    assert_eq!(refusal_only["gaps"], serde_json::json!([]));
    assert_eq!(refusal_only["refusals"], 1);
    assert_eq!(refusal_only["replayable"], false);

    // A refused assembly leaves neither a .ct nor a summary.
    let refused = stage(&tmp.path().join("refused"), &batches);
    let summary = tmp.path().join("refused.json");
    let out = tmp.path().join("refused.ct");
    let mut args = vec![
        "assemble",
        "--recording-id",
        RECORDING_ID,
        "--out",
        out.to_str().unwrap(),
        "--summary",
        summary.to_str().unwrap(),
    ];
    args.extend(refused.iter().map(|p| p.to_str().unwrap()));
    let (status, _, stderr) = ct_jsbound(&args);
    assert_eq!(status, 1, "{stderr}");
    assert!(!out.exists() && !summary.exists());

    // A summary named like the `.ct` would replace the recording with JSON
    // after it was written: a usage error, and nothing is written.
    let staged = stage(&tmp.path().join("same"), &session_batches());
    let out = tmp.path().join("same.ct");
    let mut args = vec![
        "assemble",
        "--recording-id",
        RECORDING_ID,
        "--out",
        out.to_str().unwrap(),
        "--summary",
        out.to_str().unwrap(),
    ];
    args.extend(staged.iter().map(|p| p.to_str().unwrap()));
    let (status, _, stderr) = ct_jsbound(&args);
    assert_eq!(status, 2, "{stderr}");
    assert!(
        stderr.contains("--summary must name a different file"),
        "{stderr}"
    );
    assert!(!out.exists());
}

/// `ct-jsbound summarize` reads an assembled `.ct` back, verifies it, and
/// reports the same summary the assembler wrote (with `batches` 0), its
/// recording id and its four members; a file that is not a boundary
/// recording exits 1.
#[test]
fn summarize_reports_what_assemble_wrote() {
    let tmp = tempfile::tempdir().unwrap();
    let staged = stage(&tmp.path().join("staging"), &session_batches());
    let out = tmp.path().join("r.ct");
    let summary = tmp.path().join("s.json");
    assemble_files(&out, &staged, &["--summary", summary.to_str().unwrap()]);
    let written: serde_json::Value = serde_json::from_slice(&fs::read(&summary).unwrap()).unwrap();

    let (status, stdout, stderr) = ct_jsbound(&["summarize", out.to_str().unwrap()]);
    assert_eq!(status, 0, "{stderr}");
    let mut read: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap();
    assert_eq!(read["recording_id"], RECORDING_ID);
    assert_eq!(
        read["members"],
        serde_json::json!(["meta.dat", "jsbound.log", "jsbound.blb", "jsbound.chk"])
    );
    assert_eq!(read["batches"], 0);
    let obj = read.as_object_mut().unwrap();
    obj.remove("recording_id");
    obj.remove("members");
    obj.insert("batches".into(), written["batches"].clone());
    assert_eq!(read, written);

    let bogus = tmp.path().join("bogus.ct");
    fs::write(&bogus, b"not a container").unwrap();
    let (status, _, _) = ct_jsbound(&["summarize", bogus.to_str().unwrap()]);
    assert_eq!(status, 1);
}
