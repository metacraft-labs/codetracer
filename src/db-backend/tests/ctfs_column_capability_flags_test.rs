//! M-capability-flags — column-aware capability bits propagate through
//! the CTFS read path.
//!
//! Spec: `codetracer-trace-format-spec/internal-files.md` § "Column-Aware
//! Capability Flags".  Pins the contract:
//!
//!   1. A trace written with both capability opt-ins
//!      (`enable_column_breakpoints_support`,
//!      `enable_column_motions_support`) round-trips its capability
//!      bits through `CTFSTraceReader::column_capabilities()`.
//!   2. A trace that opts into column-aware mode but NOT the
//!      capability flags surfaces both flags as `false`, so the GUI's
//!      back-compat default — "hide per-column UI" — fires.
//!   3. A pure line-only trace surfaces both flags as `false`.
//!
//! This is the headless DAP-layer test the M-capability-flags
//! milestone calls for; the GUI's per-column affordances gate on the
//! `ColumnAwareCapabilities` accessor surfaced through this reader.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use codetracer_trace_types::Line;
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use std::path::Path;

/// Helper: build a minimal `.ct` container at `program_name`.ct, apply
/// `configure` to the writer before any step is emitted, then return
/// the path so the caller can re-open it.
fn build_trace_with(program_name: &str, configure: impl FnOnce(&mut NimTraceWriter)) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let trace_path = dir.path().join("trace");

    let mut writer = NimTraceWriter::new(program_name, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir.path());
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    configure(&mut writer);

    // Every CTFS trace needs at least one step so the exec stream is
    // non-empty — otherwise the reader rejects the container.
    let path = Path::new("/tmp/caps.py");
    writer.start(path, Line(1));

    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    dir
}

#[test]
fn capability_flags_round_trip_through_ctfs_reader() {
    let dir = build_trace_with("caps_both_on", |writer| {
        writer.enable_column_breakpoints_support();
        writer.enable_column_motions_support();
    });
    let ct_path = dir.path().join("caps_both_on.ct");

    let reader = CTFSTraceReader::open(&ct_path).expect("open trace with both capability bits set");
    let caps = reader.column_capabilities();
    assert!(
        caps.supports_column_breakpoints,
        "FLAG_SUPPORTS_COLUMN_BREAKPOINTS (bit 6) must round-trip through CTFSTraceReader"
    );
    assert!(
        caps.supports_column_motions,
        "FLAG_SUPPORTS_COLUMN_MOTIONS (bit 7) must round-trip through CTFSTraceReader"
    );
}

#[test]
fn only_breakpoints_capability_round_trips() {
    let dir = build_trace_with("caps_bp_only", |writer| {
        writer.enable_column_breakpoints_support();
    });
    let ct_path = dir.path().join("caps_bp_only.ct");

    let reader = CTFSTraceReader::open(&ct_path).expect("open trace with breakpoint capability only");
    let caps = reader.column_capabilities();
    assert!(caps.supports_column_breakpoints);
    assert!(
        !caps.supports_column_motions,
        "motions bit stays clear when only breakpoint support was opted in"
    );
}

#[test]
fn column_aware_without_capability_opt_in_keeps_flags_clear() {
    let dir = build_trace_with("caps_off_but_column_aware", |writer| {
        writer.enable_column_aware_steps();
    });
    let ct_path = dir.path().join("caps_off_but_column_aware.ct");

    let reader = CTFSTraceReader::open(&ct_path).expect("open column-aware trace without capability opt-in");
    let caps = reader.column_capabilities();
    assert!(
        !caps.supports_column_breakpoints,
        "capability bit must stay clear unless the writer explicitly opts in"
    );
    assert!(!caps.supports_column_motions);
}

#[test]
fn legacy_line_only_trace_reports_no_capabilities() {
    let dir = build_trace_with("legacy_line_only", |_writer| {
        // Don't touch column-aware nor capability APIs.
    });
    let ct_path = dir.path().join("legacy_line_only.ct");

    let reader = CTFSTraceReader::open(&ct_path).expect("open legacy line-only trace");
    let caps = reader.column_capabilities();
    assert!(
        !caps.supports_column_breakpoints && !caps.supports_column_motions,
        "legacy traces must surface zero capability bits — GUI default is 'no per-column UI'"
    );
}
