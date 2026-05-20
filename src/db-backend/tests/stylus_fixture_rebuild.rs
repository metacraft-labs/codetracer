//! Helper integration test that regenerates the Stylus DAP-test fixture
//! `tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct`.
//!
//! Gated behind `#[ignore]` so a normal `cargo test` run does not touch
//! the on-disk fixture. Invoked explicitly by
//! `tests/fixtures/regenerate-stylus-fixture.sh`.
//!
//! Background
//! ----------
//! db-backend dropped the legacy 3-file materialized-trace bundle
//! (`trace.json` + `trace_metadata.json` + `trace_paths.json`) in favour
//! of the CTFS `.ct` container. The recorded Stylus trace data itself
//! never changed — it is a deterministic capture of a `fund(2)`
//! transaction against the `stylus_fund_tracker` contract. The recorded
//! event stream and metadata are therefore committed in this repo as
//! `trace.events.json` / `trace_metadata.json` next to this fixture, and
//! this helper repacks them into the canonical `.ct` container the DAP
//! tests load.
//!
//! Strategy: read the committed `trace.events.json` (a JSON array of
//! `TraceLowLevelEvent`), serialize every event as one CBOR value into a
//! sequential `events.log`, pair it with a `meta.json` carrying the
//! recorded program/args/workdir plus a freshly-minted UUIDv7
//! `recording_id`, and emit a CTFS `.ct` via the production
//! `write_minimal_ctfs` helper.

use std::path::PathBuf;

use codetracer_trace_types::{TraceLowLevelEvent, TraceMetadata};
use db_backend::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;

/// The committed Stylus fixture directory.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/stylus-fund-trace")
}

#[test]
#[ignore = "regeneration helper, invoked by tests/fixtures/regenerate-stylus-fixture.sh"]
fn rebuild_stylus_ctfs_fixture() {
    let dir = fixture_dir();

    // 1. Load the committed recorded event stream.
    let events_json = std::fs::read_to_string(dir.join("trace.events.json"))
        .expect("read committed trace.events.json");
    let events: Vec<TraceLowLevelEvent> =
        serde_json::from_str(&events_json).expect("parse trace.events.json as TraceLowLevelEvent array");
    assert!(!events.is_empty(), "recorded event stream must be non-empty");

    // 2. Load the committed recorded metadata (legacy shape — no
    //    recording_id) and re-stamp it with a UUIDv7 via TraceMetadata::new.
    #[derive(serde::Deserialize)]
    struct LegacyMeta {
        workdir: String,
        program: String,
        args: Vec<String>,
    }
    let meta_json =
        std::fs::read_to_string(dir.join("trace_metadata.json")).expect("read committed trace_metadata.json");
    let legacy: LegacyMeta = serde_json::from_str(&meta_json).expect("parse trace_metadata.json");
    let metadata = TraceMetadata::new(legacy.program, legacy.args, PathBuf::from(legacy.workdir));
    let meta_bytes = serde_json::to_vec(&metadata).expect("serialize meta.json");

    // 3. Serialize the events as a sequential CBOR `events.log` — the same
    //    legacy CBOR-streaming layout `CTFSTraceReader::load_events`
    //    accepts (no chunk headers).
    let mut events_log: Vec<u8> = Vec::new();
    for event in &events {
        events_log = cbor4ii::serde::to_vec(events_log, event).expect("CBOR-encode event");
    }

    // 4. Pack into the canonical CTFS `.ct` container.
    let ct_path = dir.join("stylus_fund_tracking_demo.ct");
    write_minimal_ctfs(
        &ct_path,
        &[
            ("meta.json", meta_bytes.as_slice()),
            ("events.log", events_log.as_slice()),
        ],
    )
    .expect("write stylus .ct fixture");

    let size = std::fs::metadata(&ct_path).expect("stat .ct fixture").len();
    eprintln!(
        "wrote {} ({} bytes, {} events)",
        ct_path.display(),
        size,
        events.len()
    );
}
