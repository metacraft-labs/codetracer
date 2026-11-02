//! The narrative deriver (`ct-jsbound narrate`) and the decoded records the
//! boundary tools serve (`ct-jsbound events`).
//!
//! `test_narrate_fixture_session_golden` reads a real recorded session: the
//! fixture checkout page of `tests/fixtures/narrate/site`, recorded in
//! headless Chromium by the generic boundary shim (`capture.mjs` there; see
//! its README), assembled here by the real assembler, and narrated. Its
//! negative control is the same page recorded again with one extra click.
//! The other tests build small logs from records, to pin one rule each.
//!
//! No mocks: every recording goes through the real batch encoder, assembler,
//! container reader and binary.

mod support;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use jsbound::narrate::{full_entries, step_entries, What, SENSITIVE};
use jsbound::{
    assemble, decode_log, encode_batch, narrate, AssembleOptions, BoundaryRecording, Envelope,
    Finalisation, Record, Termination, HOLE_TOKEN,
};
use serde_json::{json, Value};
use support::*;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/narrate")
        .join(name)
}

/// The `.ct` of a session uploaded as `batches` (`(batch_seq, records)`, the
/// first starting with `Header`, the last ending with `End`), with the
/// `refused` batch numbers refused by the ingest.
fn container_of(batches: &[(u64, Vec<Record>)], refused: &[u64]) -> Vec<u8> {
    let (session_id, build_hash) = match &batches[0].1[0] {
        Record::Header {
            session_id,
            build_hash,
            ..
        } => (session_id.clone(), build_hash.clone()),
        other => panic!("a log starts with Header, not {other:?}"),
    };
    let bodies: Vec<Vec<u8>> = batches
        .iter()
        .map(|(batch_seq, records)| {
            let seqs: Vec<u64> = records.iter().filter_map(Record::seq).collect();
            let envelope = Envelope {
                session_id: session_id.clone(),
                batch_seq: *batch_seq,
                first_seq: seqs.first().copied().unwrap_or(0),
                last_seq: seqs.last().copied().unwrap_or(0),
                dropped: Vec::new(),
                build_hash: build_hash.clone(),
                is_final: records.iter().any(|r| matches!(r, Record::End { .. })),
            };
            encode_batch(&envelope, records)
        })
        .collect();
    assemble(
        &bodies,
        &AssembleOptions {
            recording_id: RECORDING_ID.into(),
            finalisation: Finalisation::Ended,
            refused_batches: refused.iter().copied().collect::<BTreeSet<u64>>(),
        },
    )
    .expect("the session assembles")
    .container
}

/// The records as one final batch, assembled into a verified recording.
fn recording_of(records: &[Record]) -> BoundaryRecording {
    BoundaryRecording::read(container_of(&[(0, records.to_vec())], &[]))
        .expect("the recording reads back")
}

/// A captured `jsbound.log` (the shim's `log()`) as one batch's records.
fn captured_records(name: &str) -> Vec<Record> {
    let log = decode_log(&fs::read(fixture(name)).unwrap()).expect("the capture decodes");
    assert_eq!(
        log.termination,
        Termination::Complete,
        "{name} ends with End"
    );
    log.records
}

/// A captured `jsbound.log` (the shim's `log()`) as a verified recording.
fn captured(name: &str) -> BoundaryRecording {
    recording_of(&captured_records(name))
}

/// An entry without what differs between two recordings of the same steps:
/// its `seq` and `time`.
fn without_position(entry: &Value) -> Value {
    let mut e = entry.clone();
    let map = e.as_object_mut().unwrap();
    map.remove("seq");
    map.remove("time");
    map.remove("response_seq");
    e
}

/// The entries `b` adds to `a` and removes from it, by a longest common
/// subsequence, each compared without its position.
fn entry_diff(a: &[Value], b: &[Value]) -> (Vec<Value>, Vec<Value>) {
    let a: Vec<Value> = a.iter().map(without_position).collect();
    let b: Vec<Value> = b.iter().map(without_position).collect();
    let mut lcs = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    let (mut added, mut removed) = (Vec::new(), Vec::new());
    while i < a.len() || j < b.len() {
        if i < a.len() && j < b.len() && a[i] == b[j] {
            i += 1;
            j += 1;
        } else if j < b.len() && (i == a.len() || lcs[i][j + 1] >= lcs[i + 1][j]) {
            added.push(b[j].clone());
            j += 1;
        } else {
            removed.push(a[i].clone());
            i += 1;
        }
    }
    (added, removed)
}

fn texts(narrative: &Value, granularity: &str) -> Vec<String> {
    narrative[granularity]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["text"].as_str().unwrap().to_string())
        .collect()
}

/// The narrative of
/// the recorded fixture session equals its reviewed golden JSON
/// (`checkout.narrative.json`; regenerate with `JSBOUND_UPDATE_GOLDEN=1`
/// only after reviewing the difference), with inputs shown by label and the
/// e-mail field's declassifier output (invalid on the first try, then valid)
/// shown by `fn_id`. Negative control: the same page recorded with one extra
/// click differs from it in exactly one `steps` entry, that click.
#[test]
fn test_narrate_fixture_session_golden() {
    let recording = captured("checkout.jsbound.log");
    let narrative = narrate(&recording);
    let golden_path = fixture("checkout.narrative.json");
    let rendered = serde_json::to_string_pretty(&narrative).unwrap() + "\n";
    if std::env::var_os("JSBOUND_UPDATE_GOLDEN").is_some_and(|v| v == "1") {
        fs::write(&golden_path, &rendered).unwrap();
    }
    let golden: Value = serde_json::from_str(&fs::read_to_string(&golden_path).unwrap()).unwrap();

    // Vacuity guards, before the comparison: the session is what the
    // capture script did, so the golden cannot have been taken of an empty
    // or a different session.
    let steps = texts(&narrative, "steps");
    for expected in [
        "click on \u{201C}Add to cart\u{201D}",
        "click on \u{201C}Show details\u{201D}",
        "typed 3 characters into \u{201C}Name\u{201D}: Ada",
        "isValidEmail \u{2192} false",
        "isValidEmail \u{2192} true",
        "mark exposure:checkout {\"arm\":\"B\"}",
        "mark conversion:purchase {\"items\":1}",
    ] {
        assert!(
            steps.iter().any(|s| s == expected),
            "steps lack {expected:?}: {steps:#?}"
        );
    }
    // The e-mail field is sensitive: typed into, shown as a placeholder.
    let email: Vec<&String> = steps
        .iter()
        .filter(|s| s.contains("\u{201C}E-mail\u{201D}"))
        .collect();
    assert_eq!(
        email.len(),
        2,
        "two runs of typing into the e-mail field: {steps:#?}"
    );
    assert!(
        email.iter().all(|s| s.ends_with(&format!(": {SENSITIVE}"))),
        "{email:?}"
    );
    // The declassifier's outputs, in order, by fn_id.
    assert_eq!(
        narrative["declassified"],
        json!([
            {"fn_id": "isValidEmail", "output": false},
            {"fn_id": "isValidEmail", "output": true},
        ])
    );
    assert_eq!(narrative["arms"], json!({"checkout": "B"}));
    assert_eq!(narrative["end"], "stopped");
    assert!(steps
        .iter()
        .any(|s| s.starts_with("fetch POST http://127.0.0.1:47811/api/checkout \u{2192} 200")));
    // The secret typed into the e-mail field is nowhere in the narrative.
    assert!(!rendered.contains("ada@example.org") && !rendered.contains("ada-at-example.org"));
    // Every entry has a time once the page read the clock.
    assert!(narrative["start_time"].as_f64().unwrap() > 1.7e12);

    assert_eq!(
        narrative,
        golden,
        "the narrative differs from the reviewed golden {}",
        golden_path.display()
    );

    // Negative control: one extra click is exactly one more step.
    let extra = narrate(&captured("checkout-extra-click.jsbound.log"));
    let (added, removed) = entry_diff(
        narrative["steps"].as_array().unwrap(),
        extra["steps"].as_array().unwrap(),
    );
    assert!(
        removed.is_empty(),
        "the extra click removed entries: {removed:#?}"
    );
    assert_eq!(added.len(), 1, "the extra click added {added:#?}");
    assert_eq!(added[0]["text"], "click on \u{201C}Show details\u{201D}");
    // Positive control of the diff: the full granularity, which keeps every
    // pointer event, differs by more than one entry.
    let (full_added, _) = entry_diff(
        narrative["full"].as_array().unwrap(),
        extra["full"].as_array().unwrap(),
    );
    assert!(full_added.len() > 1, "{full_added:#?}");
}

/// `ct-jsbound narrate` writes what the library derives, to `--out` or
/// stdout; a file that is not a boundary recording exits 1.
#[test]
fn narrate_command_writes_the_narrative() {
    let dir = tempfile::tempdir().unwrap();
    let ct = dir.path().join("recording.ct");
    let recording = captured("checkout.jsbound.log");
    let bytes = container_of(&[(0, captured_records("checkout.jsbound.log"))], &[]);
    fs::write(&ct, bytes).unwrap();
    let expected = narrate(&recording);

    let (code, stdout, stderr) = ct_jsbound(&["narrate", ct.to_str().unwrap()]);
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(serde_json::from_str::<Value>(&stdout).unwrap(), expected);

    let out = dir.path().join("narrative.json");
    let (code, _, stderr) = ct_jsbound(&[
        "narrate",
        ct.to_str().unwrap(),
        "--out",
        out.to_str().unwrap(),
    ]);
    assert_eq!(code, 0, "{stderr}");
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(&out).unwrap()).unwrap(),
        expected
    );
    assert_eq!(expected["recording_id"], RECORDING_ID);

    // Not a recording: exit 1. Usage errors: exit 2.
    let junk = dir.path().join("junk.ct");
    fs::write(&junk, b"not a container").unwrap();
    assert_eq!(ct_jsbound(&["narrate", junk.to_str().unwrap()]).0, 1);
    assert_eq!(ct_jsbound(&["narrate"]).0, 2);
    assert_eq!(ct_jsbound(&["narrate", "a.ct", "b.ct"]).0, 2);
    assert_eq!(ct_jsbound(&["narrate", "a.ct", "--bogus", "1"]).0, 2);

    // `events`: a range of one kind, its limit, and its refusals.
    let (code, stdout, stderr) =
        ct_jsbound(&["events", ct.to_str().unwrap(), "--kinds", "Declassify,Mark"]);
    assert_eq!(code, 0, "{stderr}");
    let events: Value = serde_json::from_str(&stdout).unwrap();
    let kinds: Vec<&str> = events["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["record"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["Mark", "Declassify", "Declassify", "Mark"]);
    let first_declassify: u64 = events["events"][1]["seq"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let (code, stdout, _) = ct_jsbound(&[
        "events",
        ct.to_str().unwrap(),
        "--seq-from",
        &first_declassify.to_string(),
        "--seq-to",
        &first_declassify.to_string(),
    ]);
    assert_eq!(code, 0);
    let one: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(one["events"].as_array().unwrap().len(), 1);
    assert_eq!(one["events"][0]["record"], "Declassify");
    assert_eq!(one["events"][0]["output"], "false");
    let (code, stdout, _) = ct_jsbound(&["events", ct.to_str().unwrap(), "--limit", "3"]);
    assert_eq!(code, 0);
    let page: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(page["events"].as_array().unwrap().len(), 3);
    assert_eq!(page["truncated"], true);
    assert_eq!(page["events"][0]["record"], "Header");
    for bad in [
        vec!["events", "x.ct", "--kinds", "Nope"],
        vec!["events", "x.ct", "--limit", "0"],
        vec!["events", "x.ct", "--limit", "2001"],
        vec!["events", "x.ct", "--seq-from", "5", "--seq-to", "4"],
        vec!["events", "x.ct", "--seq-from", "-1"],
    ] {
        assert_eq!(ct_jsbound(&bad).0, 2, "{bad:?}");
    }
}

fn input(seq: u64, ty: &str, target: &str, props: &str, label: &str) -> Record {
    Record::Input {
        seq,
        task_id: seq,
        r#type: ty.into(),
        target: target.into(),
        props: props.into(),
        label: label.into(),
    }
}

fn clock(seq: u64, src: u8, value: f64) -> Record {
    Record::Clock {
        seq,
        src,
        bits: value.to_bits(),
    }
}

/// A small session built from records: the rule of each kind of entry.
fn synthetic() -> Vec<Record> {
    vec![
        header(),
        env(),
        input(1, "pointerdown", "path:#q", "{}", "Search"),
        clock(2, 7, 1_700_000_000_000.0),
        clock(3, 2, 250.5),
        input(
            4,
            "keydown",
            "path:#q",
            r#"{"key":"a","code":"KeyA"}"#,
            "Search",
        ),
        Record::DomEffect {
            seq: 5,
            target: "path:#q".into(),
            effect: 1,
            value: "\"a\"".into(),
        },
        input(6, "input", "path:#q", "{}", "Search"),
        input(7, "keydown", "path:#q", r#"{"key":"Enter"}"#, "Search"),
        Record::DomEffect {
            seq: 8,
            target: "path:#q".into(),
            effect: 1,
            value: "\"ab\"".into(),
        },
        input(9, "change", "path:#q", "{}", "Search"),
        input(10, "scroll", "doc", "{}", ""),
        input(11, "scroll", "doc", "{}", ""),
        // A task boundary: the readings after it are not this task's.
        Record::Task {
            seq: 12,
            task_id: 99,
            kind: 4,
        },
        Record::NetRequest {
            seq: 13,
            req_id: 7,
            api: 1,
            method: "GET".into(),
            url: format!("https://shop.example/find?q={HOLE_TOKEN}"),
            body_digest: String::new(),
        },
        Record::NetRequest {
            seq: 14,
            req_id: 8,
            api: 2,
            method: "POST".into(),
            url: "https://shop.example/never".into(),
            body_digest: String::new(),
        },
        clock(15, 1, 1_700_000_001_000.0),
        Record::NetResponse {
            seq: 16,
            req_id: 7,
            outcome: 1,
            status: 404,
            status_text: "Not Found".into(),
            url: String::new(),
            redirected: 0,
            response_type: 2,
            headers: "[]".into(),
            body: jsbound::BlobRef::Inline(b"nope".to_vec()),
        },
        Record::Scrubbed {
            seq: 17,
            target: "path:#pw".into(),
            class: 1,
            length: 6,
        },
        input(18, "input", "path:#pw", "{}", ""),
        Record::Error {
            seq: 19,
            kind: 1,
            message: "Uncaught TypeError: <str> is not a function".into(),
            frames: r#"[{"url":"https://shop.example/app.js","line":12,"col":3,"fn":"f"}]"#.into(),
        },
        Record::Mark {
            seq: 20,
            name: "conversion:signup".into(),
            data: format!("{{\"who\":\"{HOLE_TOKEN}\"}}"),
        },
        Record::Refusal {
            seq: 21,
            feature: "web-worker".into(),
            detail: "new Worker".into(),
        },
        Record::Navigation {
            seq: 22,
            kind: 1,
            url: "https://shop.example/done".into(),
        },
    ]
}

/// The session of [`synthetic`] uploaded in three batches, the second (seqs
/// 23 to 25) refused by the ingest, so the log has a `Gap` there.
fn synthetic_recording() -> BoundaryRecording {
    let after = vec![
        input(26, "click", "path:#done", "{}", "Done"),
        Record::End {
            last_seq: 26,
            reason: 1,
        },
    ];
    BoundaryRecording::read(container_of(&[(0, synthetic()), (2, after)], &[1]))
        .expect("the recording reads back")
}

/// Each kind of entry, the hole token shown as a placeholder, times from the
/// recorded clocks, a request with no response pending, and the `steps`
/// folding: pointer noise dropped, typing into one field one entry (its
/// `change` included), scrolling one entry.
#[test]
fn narrative_rules_on_a_built_session() {
    let recording = synthetic_recording();
    let full = full_entries(&recording.log);
    let steps = step_entries(&full);
    let step_texts: Vec<&str> = steps.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(
        step_texts,
        [
            "typed 1 character into \u{201C}Search\u{201D} (keys: Enter): ab",
            "scrolled doc (2 events)",
            &format!("fetch GET https://shop.example/find?q={SENSITIVE} \u{2192} 404"),
            "xhr POST https://shop.example/never \u{2192} pending",
            &format!("typed 0 characters into path:#pw: {SENSITIVE}"),
            "error: Uncaught TypeError: <str> is not a function at https://shop.example/app.js:12",
            &format!("mark conversion:signup {{\"who\":\"{SENSITIVE}\"}}"),
            "refused web-worker: new Worker",
            "pushState to https://shop.example/done",
            "records 23 to 25 missing (batch-refused)",
            "click on \u{201C}Done\u{201D}",
        ]
    );
    // Times: the first reading at or after the entry in its task (the
    // pointerdown: the time origin plus the performance.now() reading after
    // it), else the last one before it (the keydown: no reading follows it
    // before the task boundary at seq 12); the request after the boundary
    // takes the Date.now() reading of its own task.
    assert_eq!(full[0].time, Some(1_700_000_000_250.5));
    assert_eq!(full[1].time, Some(1_700_000_000_250.5));
    let request = full.iter().find(|e| e.seq == 13).unwrap();
    assert_eq!(request.time, Some(1_700_000_001_000.0));
    let network: Vec<&What> = full
        .iter()
        .map(|e| &e.what)
        .filter(|w| matches!(w, What::Network { .. }))
        .collect();
    assert_eq!(
        network[0],
        &What::Network {
            api: "fetch",
            method: "GET".into(),
            url: format!("https://shop.example/find?q={SENSITIVE}"),
            status: Some(404),
            outcome: "response",
            response_seq: Some(16),
        }
    );
    // The full granularity keeps every input event, the pointerdown too.
    assert_eq!(
        full.iter()
            .filter(|e| matches!(e.what, What::Input { .. }))
            .count(),
        9
    );

    let narrative = narrate(&recording);
    assert_eq!(narrative["end"], "pagehide");
    assert_eq!(narrative["replayable"], false);
    assert_eq!(narrative["has_error"], true);
    assert_eq!(narrative["counts"]["entries"]["requests"], 2);
    assert_eq!(narrative["counts"]["input_events"]["scroll"], 2);
    // The summary keeps the session's milestones, no input and no request.
    let summary: Vec<&str> = narrative["summary"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["kind"].as_str().unwrap())
        .collect();
    assert_eq!(summary, ["error", "mark", "refusal", "navigation", "gap"]);
    assert_eq!(narrative["counts"]["entries"]["gaps"], 1);
    // No hole token survives anywhere.
    assert!(!narrative.to_string().contains(HOLE_TOKEN));

    // Events show bodies as text and holes as the placeholder.
    let events = jsbound::events(
        &recording,
        &jsbound::EventQuery {
            seq_from: 13,
            seq_to: 16,
            kinds: vec!["NetRequest".into(), "NetResponse".into()],
            limit: 10,
        },
    );
    let list = events["events"].as_array().unwrap();
    assert_eq!(list.len(), 3);
    assert_eq!(
        list[0]["url"],
        format!("https://shop.example/find?q={SENSITIVE}")
    );
    assert_eq!(list[2]["body"], json!({"len": 4, "text": "nope"}));
    assert_eq!(events["truncated"], false);
}

/// The hole token is shown as the placeholder in every text a narrative or
/// a record takes from the log (a label, a target, a key, an error and its
/// source, a refusal, a declassifier's id and output, a navigation, a
/// request, a body), so no sensitive value the recorder holed reaches an
/// agent as the token or as anything else. A narrative entry cuts a long
/// text; a record is served whole, a body up to 4 KiB as text.
#[test]
fn holes_are_placeholders_everywhere_and_records_are_served_whole() {
    let h = HOLE_TOKEN;
    let long_url = format!("https://shop.example/{}{h}", "a".repeat(600));
    let long_body = format!("{}{h}", "b".repeat(1000));
    let records = vec![
        header(),
        env(),
        input(
            1,
            "click",
            &format!("path:#x{h}"),
            "{}",
            &format!("Pay {h}"),
        ),
        input(
            2,
            "keydown",
            "path:#x",
            &format!("{{\"key\":\"{h}\"}}"),
            "Pay",
        ),
        Record::Error {
            seq: 3,
            kind: 1,
            message: format!("bad {h}"),
            frames: format!(
                r#"[{{"url":"https://shop.example/{h}.js","line":4,"col":1,"fn":"f"}}]"#
            ),
        },
        Record::Refusal {
            seq: 4,
            feature: "web-worker".into(),
            detail: format!("new Worker({h})"),
        },
        Record::Declassify {
            seq: 5,
            fn_id: format!("check{h}"),
            output: format!("\"{h}\""),
        },
        Record::Navigation {
            seq: 6,
            kind: 1,
            url: format!("https://shop.example/{h}"),
        },
        Record::NetRequest {
            seq: 7,
            req_id: 1,
            api: 1,
            method: "GET".into(),
            url: long_url.clone(),
            body_digest: String::new(),
        },
        Record::NetResponse {
            seq: 8,
            req_id: 1,
            outcome: 1,
            status: 200,
            status_text: "OK".into(),
            url: String::new(),
            redirected: 0,
            response_type: 2,
            headers: "[]".into(),
            body: jsbound::BlobRef::Inline(long_body.clone().into_bytes()),
        },
        Record::End {
            last_seq: 8,
            reason: 2,
        },
    ];
    let recording = recording_of(&records);
    let narrative = narrate(&recording);
    let rendered = narrative.to_string();
    assert!(!rendered.contains(h), "a hole token survived: {rendered}");
    let full = narrative["full"].as_array().unwrap();
    let texts: Vec<&str> = full.iter().map(|e| e["text"].as_str().unwrap()).collect();
    let s = SENSITIVE;
    for expected in [
        format!("click on \u{201C}Pay {s}\u{201D}"),
        format!("keydown {s} on \u{201C}Pay\u{201D}"),
        format!("error: bad {s} at https://shop.example/{s}.js:4"),
        format!("refused web-worker: new Worker({s})"),
        format!("check{s} \u{2192} \"{s}\""),
        format!("pushState to https://shop.example/{s}"),
    ] {
        assert!(
            texts.contains(&expected.as_str()),
            "{expected:?} not in {texts:#?}"
        );
    }
    assert_eq!(full[0]["target"], format!("path:#x{s}"));
    assert_eq!(
        narrative["declassified"],
        json!([{"fn_id": format!("check{s}"), "output": s}])
    );
    // A narrative entry cuts a long URL...
    let request = full.iter().find(|e| e["kind"] == "network").unwrap();
    let url = request["url"].as_str().unwrap();
    assert_eq!(url.chars().count(), jsbound::narrate::MAX_TEXT);
    assert!(url.ends_with('\u{2026}'), "{url}");

    // ...and the records serve it whole, as they serve the body.
    let events = jsbound::events(&recording, &jsbound::EventQuery::default());
    let rendered = events.to_string();
    assert!(!rendered.contains(h), "a hole token survived: {rendered}");
    let list = events["events"].as_array().unwrap();
    let net = |kind: &str| list.iter().find(|e| e["record"] == kind).unwrap();
    assert_eq!(net("NetRequest")["url"], long_url.replace(h, s));
    assert_eq!(
        net("NetResponse")["body"],
        json!({"len": long_body.len(), "text": long_body.replace(h, s)})
    );
    assert_eq!(net("Input")["label"], format!("Pay {s}"));
}
