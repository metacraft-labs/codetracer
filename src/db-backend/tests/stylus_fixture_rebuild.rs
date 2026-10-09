//! Helper integration test that regenerates the Stylus DAP-test fixture
//! `tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct`.
//!
//! Gated behind `#[ignore]` so a normal `cargo test` run does not touch
//! the on-disk fixture. Invoked explicitly by
//! `tests/fixtures/regenerate-stylus-fixture.sh` (or the per-fixture
//! `tests/fixtures/stylus-fund-trace/regenerate-stylus-fixture.sh`).
//!
//! M28 note: this harness is the **M27-aware** repacker. The
//! `vm_hooks` import surface it implicitly assumes is defined in
//! `codetracer-evm-recorder/stylus/codetracer.toml` and exposed as a
//! `PassThroughPlan` by the
//! `codetracer-wasm-host-module-framework` crate. The legacy
//! hand-written Go path (`codetracer-wasm-recorder/internal/stylus/`)
//! is retired by M28 in favour of that data-driven surface.
//!
//! Background
//! ----------
//! db-backend dropped the legacy 3-file materialized-trace bundle
//! (`trace.json` + `trace_metadata.json` + `trace_paths.json`) in favour
//! of the CTFS `.ct` container, and M-REC-1.5 then retired the legacy
//! `meta.json` fallback so a `.ct` must carry a binary `meta.dat`. The
//! recorded Stylus trace data itself never changed — it is a
//! deterministic capture of a `fund(2)` transaction against the
//! `stylus_fund_tracker` contract. The recorded event stream and
//! metadata are therefore committed in this repo as
//! `trace.events.json` / `trace_metadata.json` next to this fixture,
//! and this helper repacks them into the canonical `.ct` container the
//! DAP tests load.
//!
//! Strategy: read the committed `trace.events.json` (a JSON array of
//! `TraceLowLevelEvent`) and replay every event, in order, through the
//! production `CtfsTraceWriter`, which writes the container's split
//! streams, interning tables and `meta.dat` (the recorded
//! program/args/workdir plus a fixed canonical UUIDv7 `recording_id`).

use std::path::{Path, PathBuf};

use codetracer_trace_types::TraceLowLevelEvent;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

/// The committed Stylus fixture directory.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/stylus-fund-trace")
}

fn stylus_source_path() -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test-programs/stylus_fund_tracker/src/lib.rs")
        .canonicalize()
        .expect("canonicalize stylus source path")
        .display()
        .to_string()
}

#[test]
#[ignore = "regeneration helper, invoked by tests/fixtures/regenerate-stylus-fixture.sh"]
fn rebuild_stylus_ctfs_fixture() {
    let dir = fixture_dir();
    let source_path = stylus_source_path();

    // 1. Load the committed recorded event stream.
    let events_json = std::fs::read_to_string(dir.join("trace.events.json")).expect("read committed trace.events.json");
    let mut event_values: Vec<serde_json::Value> =
        serde_json::from_str(&events_json).expect("parse trace.events.json as JSON array");
    for event in &mut event_values {
        if let Some(path) = event.get_mut("Path") {
            *path = serde_json::Value::String(source_path.clone());
        }
    }
    let events: Vec<TraceLowLevelEvent> = serde_json::from_value(serde_json::Value::Array(event_values))
        .expect("parse trace.events.json as TraceLowLevelEvent array");
    assert!(!events.is_empty(), "recorded event stream must be non-empty");

    // 2. Load the committed recorded metadata (legacy shape).
    #[derive(serde::Deserialize)]
    struct LegacyMeta {
        program: String,
        args: Vec<String>,
    }
    let meta_json =
        std::fs::read_to_string(dir.join("trace_metadata.json")).expect("read committed trace_metadata.json");
    let legacy: LegacyMeta = serde_json::from_str(&meta_json).expect("parse trace_metadata.json");

    // 3. Replay the events through the production writer. The recording
    //    is deterministic, so a fixed `recording_id` keeps the regenerated
    //    fixture reproducible.
    let mut writer = CtfsTraceWriter::new(&legacy.program, &legacy.args);
    writer.set_recording_id("01949fcc-7d92-7e9c-aaaa-5747591d0001");
    TraceWriter::set_workdir(&mut writer, Path::new(env!("CARGO_MANIFEST_DIR")));
    TraceWriter::begin_writing_trace_events(&mut writer, &dir.join("stylus_fund_tracking_demo"))
        .expect("open the stylus .ct fixture for writing");
    let event_count = events.len();
    for event in events {
        TraceWriter::add_event(&mut writer, event);
    }
    TraceWriter::finish_writing_trace_events(&mut writer).expect("write stylus .ct fixture");
    let ct_path = dir.join("stylus_fund_tracking_demo.ct");

    let size = std::fs::metadata(&ct_path).expect("stat .ct fixture").len();
    eprintln!("wrote {} ({} bytes, {} events)", ct_path.display(), size, event_count);
}
