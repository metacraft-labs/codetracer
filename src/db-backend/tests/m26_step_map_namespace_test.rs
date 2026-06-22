//! M26 / M26b — BREAKPOINT line→step resolution PREFERS the prepopulated
//! `step-map.ns` breakpoint index when a `.ct` carries one, WITHOUT materializing
//! the whole step table; and falls back to the M24c lazy / M25b parallel
//! whole-table build when the index is absent.
//!
//! ## What this proves
//!
//! 1. PARITY — for a bundle carrying `step-map.ns`, breakpoint resolution
//!    (`step_ids_on_line`) returns IDENTICAL step sets to the whole-table build,
//!    for every recorded line.
//! 2. NO whole-table build — when a breakpoint resolves via the prepopulated
//!    index, the lazy whole-step-table is NOT materialized
//!    (`lazy_full_steps_materialized() == false`).
//! 3. FALLBACK — a bundle WITHOUT the index resolves correctly via the
//!    whole-table build (unchanged M24c/M25b behaviour).
//!
//! ## M26b — the index is REAL and PRODUCED BY THE NIM WRITER
//!
//! As of M26b the Nim `MultiStreamTraceWriter` EMITS the spec's §4.1 `STMP`
//! namespace as a container-internal `step-map.ns` file BY DEFAULT on the
//! line-only production write path (see
//! `codetracer-trace-format-nim/src/codetracer_trace_writer/step_map_builder.nim`
//! and `multi_stream_writer.nim`). So `write_production_bundle` below — the exact
//! FFI write path every live recorder drives — now yields a `.ct` that ALREADY
//! carries the prepopulated breakpoint table. This test closes the write↔read
//! loop: the bytes the Nim writer serialized are parsed back by the M26 Rust
//! consumer (`StepMapNamespace::parse`) and asserted IDENTICAL to the whole-table
//! `step_map_for_path` derivation, line by line.
//!
//! For the FALLBACK / malformed scenarios we need a bundle WITHOUT a usable
//! internal index. Since emission is now default-on, those bundles are
//! synthesized by STRIPPING the `step-map.ns` root entry from a produced `.ct`
//! (`strip_internal_step_map`) — yielding a genuine legacy (pre-M26b) bundle.
//!
//! Requires the `nim-reader` feature (the production split-stream reader).

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{trace_writer::TraceWriter, NimTraceWriter, TraceEventsFileFormat};

use db_backend::ctfs_trace_reader::step_map_namespace::{StepMapNamespace, STEP_MAP_FILE};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/m26_step_map_prog.py";

/// Number of user steps recorded — enough to span multiple `steps.dat` chunks
/// (chunk size 4096) so the no-whole-table-build proof is meaningful.
const USER_STEPS: usize = 9000;

/// Distinct user lines the steps spread across.
const DISTINCT_LINES: usize = 50;

/// The recorded line of user step `i` — a deterministic spread so the line→step
/// map is non-trivial AND multiple steps share a line.
fn line_of_user_step(i: usize) -> i64 {
    10 + (i % DISTINCT_LINES) as i64
}

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the exact write path every live recorder drives.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m26_step_map");
    let ct_path = dir.join("m26_step_map_prog.ct");

    let mut writer = NimTraceWriter::new("m26_step_map_prog", &[], TraceEventsFileFormat::Ctfs);
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
        writer.register_step(path, Line(line_of_user_step(i)));
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

/// The CTFS base40 file-name alphabet (`\0`, `0-9`, `a-z`, `.`, `/`, `-`),
/// matching `codetracer-trace-format-nim/src/codetracer_ctfs/base40.nim` and the
/// reader's `base40_encode`. Used only to LOCATE the `step-map.ns` root entry
/// when synthesizing a legacy (no-index) bundle.
fn base40_encode(name: &str) -> u64 {
    let mut val: u64 = 0;
    let mut mult: u64 = 1;
    for i in 0..12 {
        let mut idx: u64 = 0;
        if let Some(c) = name.as_bytes().get(i).copied() {
            idx = match c {
                b'0'..=b'9' => (c - b'0') as u64 + 1,
                b'a'..=b'z' => (c - b'a') as u64 + 11,
                b'.' => 37,
                b'/' => 38,
                b'-' => 39,
                _ => 0,
            };
        }
        val += idx * mult;
        mult *= 40;
    }
    val
}

/// Synthesize a LEGACY (pre-M26b) bundle from a produced `.ct` by zeroing the
/// `step-map.ns` root directory entry in place. The CTFS root layout is
/// `[8-byte header][8-byte ext header][31 x 24-byte file entries]`, each entry
/// `[size:u64][map_block:u64][name:u64]` (see the reader's container parse). A
/// zeroed entry is skipped at open, so the resulting bundle reads exactly as a
/// pre-M26b `.ct` that never carried the index — exercising the whole-table
/// fallback. Panics if the entry is not found (the writer must have emitted it).
fn strip_internal_step_map(ct_path: &Path) {
    const HEADER_SIZE: usize = 8;
    const EXT_HEADER_SIZE: usize = 8;
    const FILE_ENTRY_SIZE: usize = 24;
    const MAX_ROOT_ENTRIES: usize = 31;

    let target = base40_encode(STEP_MAP_FILE);
    let mut data = std::fs::read(ct_path).expect("read produced .ct");
    let entry_start = HEADER_SIZE + EXT_HEADER_SIZE;
    let mut stripped = false;
    for i in 0..MAX_ROOT_ENTRIES {
        let off = entry_start + i * FILE_ENTRY_SIZE;
        if off + FILE_ENTRY_SIZE > data.len() {
            break;
        }
        let name = u64::from_le_bytes(data[off + 16..off + 24].try_into().unwrap());
        if name == target {
            // Zero the whole 24-byte entry so the reader treats the slot as free.
            for b in &mut data[off..off + FILE_ENTRY_SIZE] {
                *b = 0;
            }
            stripped = true;
            break;
        }
    }
    assert!(
        stripped,
        "step-map.ns root entry must be present (the Nim writer emits it by default) — \
         M26b regression if missing"
    );
    std::fs::write(ct_path, &data).expect("rewrite stripped .ct");
}

/// The ground-truth `(line -> ascending step ids)` set the whole-table build
/// produces, computed analytically from the fixture's line spread. Used as the
/// independent oracle both the index and the whole-table build must match.
fn expected_line_steps(line: usize) -> Vec<StepId> {
    (0..USER_STEPS)
        .filter(|i| line_of_user_step(*i) == line as i64)
        .map(|i| StepId((i + 2) as i64))
        .collect()
}

/// DELIVERABLE — when the `.ct` carries `step-map.ns`, the reader attaches it
/// and breakpoint resolution is served from the index.
#[test]
fn bundle_with_step_map_attaches_index() {
    let dir = tempfile::tempdir().unwrap();
    // M26b — the Nim writer emits step-map.ns by default; no sidecar needed.
    let ct = write_production_bundle(dir.path());

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    assert!(
        reader.has_prepopulated_step_map(),
        "a production bundle must carry the Nim-emitted step-map.ns and attach the prepopulated index"
    );

    let ns: &StepMapNamespace = reader.step_map().expect("index attached");
    // The recording spreads user steps across `DISTINCT_LINES` lines (10..59) and
    // ALSO records the leading step(s) at the function line (line 1), so the index
    // carries one entry per distinct line WITH steps: the 50 user lines + line 1.
    assert_eq!(
        ns.entry_count(),
        DISTINCT_LINES + 1,
        "the index must carry one entry per distinct recorded line (50 user lines + line 1)"
    );
}

/// DELIVERABLE — PARITY: the index returns IDENTICAL step sets to the
/// independent oracle (== the whole-table build) for every recorded line.
#[test]
fn index_resolution_matches_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    let path_id = reader.path_id_for(SRC).expect("source path interned");

    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let expected = expected_line_steps(line);

        let from_index = reader
            .step_ids_on_line(path_id, line)
            .expect("index resolves a recorded line");
        assert_eq!(
            from_index, expected,
            "index breakpoint resolution on line {line} must equal the recorded step set"
        );
    }

    // A line with no steps resolves to None through the index too.
    assert!(reader.step_ids_on_line(path_id, 9999).is_none());
}

/// DELIVERABLE — NO whole-table build: resolving breakpoints via the index does
/// NOT materialize the lazy whole-step-table.
#[test]
fn index_resolution_does_not_build_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    let reader = CTFSTraceReader::open(&ct).expect("open with step-map.ns");
    let path_id = reader.path_id_for(SRC).expect("source path interned");

    // At open the whole-table view is not built.
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // Resolve EVERY recorded line's breakpoint through the index.
    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let _ = reader.step_ids_on_line(path_id, line);
    }

    // The whole-table view is STILL not built — breakpoint resolution went
    // entirely through the O(unique-lines) index.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(false),
        "resolving breakpoints via step-map.ns must NOT materialize the whole step table"
    );
    // And the lazy step cache inflated nothing (no steps.dat access).
    assert_eq!(
        reader.lazy_steps_chunk_decompressions(),
        Some(0),
        "index breakpoint resolution must not inflate any steps.dat chunk"
    );
    assert_eq!(reader.lazy_steps_populated(), Some(0));
}

/// DELIVERABLE — FALLBACK: a bundle WITHOUT step-map.ns resolves breakpoints
/// correctly via the whole-table build (unchanged), and that build IS triggered
/// (proving the two paths are genuinely distinct).
#[test]
fn bundle_without_step_map_falls_back_to_whole_table() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());
    // Synthesize a LEGACY bundle by stripping the Nim-emitted internal index, so
    // the whole-table fallback path is exercised exactly as on a pre-M26b `.ct`.
    strip_internal_step_map(&ct);

    let reader = CTFSTraceReader::open(&ct).expect("open without step-map.ns");
    assert!(
        !reader.has_prepopulated_step_map(),
        "a bundle without step-map.ns must not attach an index"
    );

    let path_id = reader.path_id_for(SRC).expect("source path interned");
    assert_eq!(reader.lazy_full_steps_materialized(), Some(false));

    // Resolution still correct — served from the whole-table build.
    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let expected = expected_line_steps(line);
        let resolved = reader
            .step_ids_on_line(path_id, line)
            .expect("fallback resolves a recorded line");
        assert_eq!(
            resolved, expected,
            "fallback breakpoint resolution on line {line} must equal the recorded step set"
        );
    }

    // The whole-table build WAS triggered by the fallback path — the distinguishing
    // counter-proof that this bundle did not use an index.
    assert_eq!(
        reader.lazy_full_steps_materialized(),
        Some(true),
        "fallback breakpoint resolution must materialize the whole-table view"
    );
}

/// DELIVERABLE — the two paths agree end-to-end: index and fallback produce the
/// SAME breakpoint resolution for the SAME trace, line by line.
#[test]
fn index_and_fallback_agree() {
    let dir = tempfile::tempdir().unwrap();

    // Indexed reader — the native bundle carries the Nim-emitted step-map.ns.
    let indexed_ct = write_production_bundle(dir.path());
    let indexed = CTFSTraceReader::open(&indexed_ct).expect("open indexed");
    let ipath = indexed.path_id_for(SRC).expect("path");
    assert!(indexed.has_prepopulated_step_map());

    // Fallback reader — a separate bundle with the internal index stripped, so it
    // resolves via the whole-table build.
    let fallback_dir = tempfile::tempdir().unwrap();
    let fallback_ct = write_production_bundle(fallback_dir.path());
    strip_internal_step_map(&fallback_ct);
    let fallback = CTFSTraceReader::open(&fallback_ct).expect("open fallback");
    let fpath = fallback.path_id_for(SRC).expect("path");
    assert!(!fallback.has_prepopulated_step_map());

    for line_off in 0..DISTINCT_LINES {
        let line = 10 + line_off;
        let from_fallback = fallback.step_ids_on_line(fpath, line);
        let from_index = indexed.step_ids_on_line(ipath, line);
        assert_eq!(
            from_fallback, from_index,
            "index and whole-table fallback must resolve line {line} identically"
        );
    }

    // Sanity: the full trace really did span the chunked step stream.
    assert!(expected_step_count() > 4096, "fixture must span multiple steps.dat chunks");
}

/// DELIVERABLE — a MALFORMED step-map.ns is ignored (clean fallback), never a
/// hard open failure and never wrong breakpoints.
#[test]
fn malformed_step_map_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_production_bundle(dir.path());

    // Strip the (valid) internal index so the corrupt SIDECAR is the only
    // candidate — otherwise the internal index (which takes precedence) would
    // mask the malformed sidecar and this test wouldn't exercise the bad-bytes
    // path.
    strip_internal_step_map(&ct);

    // Write a corrupt sidecar (bad magic).
    let mut name = ct.file_name().unwrap().to_os_string();
    name.push(".");
    name.push(STEP_MAP_FILE);
    let sidecar = ct.parent().unwrap().join(name);
    std::fs::write(&sidecar, b"not a step map at all").expect("write corrupt sidecar");

    let reader = CTFSTraceReader::open(&ct).expect("open must succeed despite corrupt sidecar");
    assert!(
        !reader.has_prepopulated_step_map(),
        "a malformed step-map.ns must be ignored, not attached"
    );

    // Breakpoint resolution still correct via the fallback build.
    let path_id = reader.path_id_for(SRC).expect("path");
    let line = 10;
    assert_eq!(
        reader.step_ids_on_line(path_id, line),
        Some(expected_line_steps(line))
    );
}
