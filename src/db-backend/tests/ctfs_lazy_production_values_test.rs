//! M24c — VERIFY the db-backend's PRODUCTION read path is actually SEEKABLE for
//! step values: the M22 seekable overlays ENGAGE on a real Nim production bundle,
//! `open_new_format_nim` no longer EAGERLY materializes the value table, a step's
//! values decompress only the one needed `values.dat` chunk, and the lazily
//! served values are byte-identical to the eager materialization.
//!
//! ## Why this is the real production path
//!
//! The bundle is written by the Nim `MultiStreamTraceWriter` (driven by every
//! live recorder — Ruby/Python/JS/shell — via FFI), the exact write path
//! production uses. M24a-1/M24a-2 brought its `steps.dat`/`values.dat` onto the
//! SPEC-canonical wire format and made `close()` set `has_step_stream` (bit 9) +
//! `has_value_stream` (bit 10), so the Rust seekable readers can now read it AND
//! the flag-gated overlays attach. This test proves that end-to-end on a
//! genuinely `events.log`-free split bundle, then proves the lazy / bounded
//! properties M24 set out to deliver.
//!
//! Requires the `nim-reader` feature (the production split-stream reader), which
//! is in the crate's default feature set.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId, TypeId, TypeKind, ValueRecord, VariableId};

use codetracer_trace_writer_nim::{trace_writer::TraceWriter, NimTraceWriter, TraceEventsFileFormat};

use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/lazy_production_values_prog.py";

/// Number of user steps recorded. The value stream's chunk size is 256
/// (`DEFAULT_VALUES_CHUNK_SIZE`), so > 256 value records guarantees the bundle
/// spans MULTIPLE `values.dat` chunks — letting us prove a single step fetch
/// decompresses exactly one of them, not the whole stream.
const USER_STEPS: usize = 600;

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the exact write path every live recorder drives.
///
/// Each user step `i` records a single integer local `var = i` through
/// `register_variable_with_full_value`, landing in the `values.dat` `StepValues`
/// stream (the split-stream inline-full-value model). Returns the `.ct` path.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("lazy_production_values");
    let ct_path = dir.join("lazy_production_values_prog.ct");

    let mut writer = NimTraceWriter::new("lazy_production_values_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..USER_STEPS {
        // Spread lines across a 50-line span so the step table is non-trivial.
        writer.register_step(path, Line(10 + (i % 50) as i64));
        let value = ValueRecord::Int {
            i: i as i64,
            type_id: int_type,
        };
        writer.register_variable_with_full_value("var", value);
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

/// The recorded step total: a leading step at the function line + `USER_STEPS`
/// user steps. (`start`+`register_step` emit one initial step before the loop.)
fn expected_step_count() -> usize {
    USER_STEPS + 2
}

/// Read step `sid`'s single integer local `var` from a reader, via the borrowing
/// `variables_at` accessor (the lazy path under test). `None` when the step has
/// no `var` value.
fn var_at(reader: &CTFSTraceReader, sid: StepId) -> Option<i64> {
    let vars = reader.variables_at(sid)?;
    vars.iter().find_map(|v| {
        if reader.variable_name(v.variable_id) == Some("var") {
            match v.value {
                ValueRecord::Int { i, .. } => Some(i),
                _ => None,
            }
        } else {
            None
        }
    })
}

/// DELIVERABLE 1 — the seekable step + value OVERLAYS ENGAGE on a real Nim
/// production bundle (flags set by M24a, Rust readers open the Nim spec-format
/// streams). If this regresses, M24a's wire-format reconciliation or flag
/// plumbing broke.
#[test]
fn overlays_engage_on_production_bundle() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // The bundle really is split-only — `steps.dat` present, `events.log` ABSENT
    // — so `open()` takes the new-format (Nim FFI) path, not the legacy fallback.
    {
        let ctfs = CtfsReader::open(&ct).expect("open ctfs container");
        assert!(ctfs.has_file("steps.dat"), "production bundle must ship steps.dat");
        assert!(ctfs.has_file("values.dat"), "production bundle must ship values.dat");
        assert!(
            !ctfs.has_file("events.log"),
            "production bundle must be events.log-free (split-only)"
        );
    }

    let reader = CTFSTraceReader::open(&ct).expect("CTFSTraceReader::open production");

    // Both overlays attached — the seekable readers opened the Nim spec-format
    // streams (flags set + format compatible). This is the M23e-4 gap, closed.
    assert_eq!(
        reader.seekable_step_count(),
        Some(expected_step_count()),
        "seekable steps.dat overlay must engage on a production bundle"
    );
    assert_eq!(
        reader.seekable_value_count(),
        Some(expected_step_count()),
        "seekable values.dat overlay must engage on a production bundle"
    );
}

/// DELIVERABLE 2 — `open_new_format_nim` is LAZY for values: opening a production
/// bundle does NOT materialize the value table. `db.variables` is empty and the
/// lazy cache has decoded ZERO steps at open.
#[test]
fn open_does_not_materialize_value_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    // The eager value table is NOT built: `db.variables` is empty.
    assert!(
        reader.db().variables.is_empty(),
        "open() must NOT materialize db.variables on a production bundle (was {} entries)",
        reader.db().variables.len()
    );

    // The lazy cache is on the lazy path and has decoded nothing yet.
    assert_eq!(
        reader.lazy_values_populated(),
        Some(0),
        "no step's values should be decoded at open"
    );
    assert_eq!(
        reader.lazy_values_chunk_decompressions(),
        Some(0),
        "no values.dat chunk should be inflated at open"
    );

    // Sanity: the step count is real (steps are indexed), but values are lazy.
    assert_eq!(reader.step_count(), expected_step_count());
}

/// DELIVERABLE 3 — BOUNDED DECOMPRESSION on a production bundle: borrowing ONE
/// step's values inflates only ONE `values.dat` chunk (counter-proven via the
/// reader's `cached_chunk` probe), and the whole stream is never materialized.
#[test]
fn one_step_value_fetch_decompresses_one_chunk() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    assert_eq!(reader.lazy_values_chunk_decompressions(), Some(0));

    // Fetch one step deep in a LATER chunk (step 400 → value chunk 1, since chunk
    // size is 256). The borrowing accessor reads through the lazy cache's stream.
    let mid = StepId(400);
    let v = var_at(&reader, mid);
    assert!(v.is_some(), "step {} should carry its `var` value", mid.0);

    // Exactly one chunk inflated — bounded decompression, NOT the whole stream
    // (which spans 3 chunks for 602 records at chunk size 256).
    assert_eq!(
        reader.lazy_values_chunk_decompressions(),
        Some(1),
        "fetching one step's values must inflate exactly one values.dat chunk"
    );
    // Exactly one step slot decoded — the rest of the value table is still lazy.
    assert_eq!(
        reader.lazy_values_populated(),
        Some(1),
        "only the requested step's values should be decoded"
    );

    // Re-reading the SAME step inflates no new chunk (cache hit).
    let _ = var_at(&reader, mid);
    assert_eq!(
        reader.lazy_values_chunk_decompressions(),
        Some(1),
        "re-reading the same step must not inflate another chunk"
    );

    // Reading a step in a DIFFERENT chunk inflates exactly one more.
    let _ = var_at(&reader, StepId(50)); // chunk 0
    assert_eq!(
        reader.lazy_values_chunk_decompressions(),
        Some(2),
        "touching a step in a new chunk inflates exactly one more chunk"
    );
    assert_eq!(reader.lazy_values_populated(), Some(2));
}

/// DELIVERABLE 4 — PARITY: the lazily-served per-step values EQUAL what the eager
/// materialization produced. We assert the exact recorded value per user step:
/// user step `i` (reader step `i + 2`) carries `var = i`. So the debugger shows
/// identical data on the lazy path.
#[test]
fn lazy_values_equal_recorded_values() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    // The leading step (StepId(0)/(1)) carries no `var`; the call is registered
    // on the second step. User step `i` lands at reader step `i + 2`.
    for i in 0..USER_STEPS {
        let sid = StepId((i + 2) as i64);
        assert_eq!(
            var_at(&reader, sid),
            Some(i as i64),
            "lazy value at user step {i} (reader step {}) must equal the recorded `var = {i}`",
            sid.0
        );
    }

    // Every user step's values were decoded exactly once; nothing extra.
    assert_eq!(
        reader.lazy_values_populated(),
        Some(USER_STEPS),
        "exactly the borrowed steps should be decoded"
    );

    // An out-of-range step yields None (the borrowing accessor falls through),
    // matching the eager `db.variables.get` behaviour.
    assert!(
        reader.variables_at(StepId(expected_step_count() as i64)).is_none(),
        "out-of-range step must yield None"
    );
}

/// PARITY via the OWNED hot path too: `variables_at_owned` (the DAP variable
/// path, which prefers the `value_stream` overlay) must agree with the borrowing
/// lazy path for the same step. Both decode the same `StepValues` CBOR, so the
/// debugger's locals view is identical regardless of which accessor it uses.
#[test]
fn owned_and_borrowed_value_paths_agree() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("open production");

    for i in [0usize, 1, 100, 255, 256, 257, 599] {
        let sid = StepId((i + 2) as i64);
        let borrowed: Vec<(VariableId, i64)> = reader
            .variables_at(sid)
            .unwrap_or(&[])
            .iter()
            .filter_map(|v| match v.value {
                ValueRecord::Int { i, .. } => Some((v.variable_id, i)),
                _ => None,
            })
            .collect();
        let owned: Vec<(VariableId, i64)> = reader
            .variables_at_owned(sid)
            .unwrap_or_default()
            .iter()
            .filter_map(|v| match v.value {
                ValueRecord::Int { i, .. } => Some((v.variable_id, i)),
                _ => None,
            })
            .collect();
        assert_eq!(
            borrowed, owned,
            "owned and borrowed value paths must agree at reader step {}",
            sid.0
        );
        assert_eq!(borrowed.len(), 1, "each user step records exactly one local");
        assert_eq!(borrowed[0].1, i as i64, "recorded value must be var=i");
        assert_eq!(
            reader.variable_name(borrowed[0].0),
            Some("var"),
            "the recorded local is named `var`"
        );
    }
}
