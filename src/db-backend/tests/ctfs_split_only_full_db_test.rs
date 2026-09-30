//! M23e-2 — VERIFY the db-backend fully serves a PRODUCTION split-only `.ct`
//! bundle (no `events.log`), and BOUND the legacy `events.log` reader.
//!
//! ## What this proves
//!
//! The production trace format is split-stream-only: the Nim
//! `MultiStreamTraceWriter` (driven by every live recorder — Ruby/Python/JS/
//! shell — via FFI) emits ONLY the split per-kind streams (`steps.dat`,
//! `calls.dat`, `values.dat`, `events.dat`, interning) and NEVER `events.log`.
//! `CTFSTraceReader::open` routes such a bundle (detected by `steps.dat`
//! presence) through `open_new_format_nim`, which builds the full `Db` from the
//! split streams via the Nim FFI — `events.log` is never read.
//!
//! These tests assert, against a GENUINELY `events.log`-free split bundle:
//!
//!  1. The bundle really is split-only — `steps.dat` present, `events.log`
//!     ABSENT — so `CTFSTraceReader::open` takes the new-format (split) path,
//!     not the legacy `events.log` fallback.
//!  2. The full `Db` is correctly populated: steps, calls, and per-step
//!     variable values all surface through the `TraceReader` trait.
//!  3. The CELL / COMPOUND HISTORY accessors (`compound_at`, `cells_at`,
//!     `cell_changes_for`, `variable_cells_at`) — M22's `[~]` remainder —
//!     behave CORRECTLY for a split-only bundle. The split format stores
//!     INLINE FULL VALUES per step (via the Nim writer's
//!     `register_variable_with_full_value` → `values.dat` `StepValues`), NOT
//!     `Cell`/`Assign` references, so the cell-change index is legitimately
//!     EMPTY and every local is served from the per-step variable snapshot
//!     (`variables_at`). The cell machinery (`load_value_for_place`) is the
//!     value-loading fallback for `ValueRecord::Cell { place }` references,
//!     which the split format does not emit — so an empty cell history is the
//!     CORRECT, complete answer here, and M22's `[~]` remainder is RESOLVED for
//!     split bundles: the debugger's locals view (`full_value_locals`) is fully
//!     served without any cell history.
//!  4. PARITY (A/B): the same logical recording as a LEGACY `events.log`
//!     bundle (read through `open_old_format` → `TraceProcessor::postprocess`)
//!     yields the SAME steps and per-step variable values as the split-only
//!     bundle — so the debugger shows identical data on either format.
//!
//! ## Where the legacy bundle comes from
//!
//! No writer emits `events.log` any more — the spec defines no such stream and
//! the Rust writer stopped writing it in codetracer-trace-format `ac413d7` — but
//! recordings made before that still carry it and the reader still opens them.
//! The legacy bundle is therefore produced byte-for-byte by
//! `common::legacy_events_log`, not by a writer switch.
//!
//! ## The call tree is rooted at `<toplevel>`
//!
//! `start` interns `<toplevel>` as function 0 and opens its call as call 0 at
//! depth 0 (`trace-events.md`, "Recorder Integration — Starting a Recording").
//! A recording whose entry point is `main` therefore has BOTH: `<toplevel>` at
//! depth 0 and `main` below it at depth 1.
//!
//! Requires the `nim-reader` feature (the production split-stream reader). It is
//! in the crate's default feature set, so the regular `cargo test` runs it.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod common;

use std::path::{Path, PathBuf};

use codetracer_trace_types::{CallKey, Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/split_only_prog.py";

/// Explicit user steps the fixture records, each carrying one integer local
/// `var_i = i * 100`. The recorded total is one larger because the leading
/// `register_step`/`start` pair emits an initial step at the function line.
const USER_STEPS: usize = 5;

/// Produce a GENUINELY `events.log`-free split-only `.ct` bundle via the Nim
/// multi-stream writer — the exact write path every live recorder drives.
///
/// Each user step `i` records a single integer local `var_i = i*100` through
/// `register_variable_with_full_value`, which lands in the `values.dat`
/// `StepValues` stream (the split-stream inline-full-value model). Returns the
/// absolute `.ct` path.
fn write_split_only_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("split_only");
    let ct_path = dir.join("split_only_prog.ct");

    let mut writer = NimTraceWriter::new("split_only_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer
        .begin_writing_trace_metadata(&trace_path)
        .expect("begin_writing_trace_metadata");
    writer.finish_writing_trace_metadata().unwrap();
    writer
        .begin_writing_trace_events(&trace_path)
        .expect("begin_writing_trace_events");
    writer
        .begin_writing_trace_paths(&trace_path)
        .expect("begin_writing_trace_paths");
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);

    // `start` is the first writer call after the paths: it interns
    // `<toplevel>` as function 0, opens its call, and records the entry step.
    writer.start(path, Line(1));

    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    // A step at the function definition line, then wrap the run in one `main`
    // call below `<toplevel>`.
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..USER_STEPS {
        writer.register_step(path, Line(10 + i as i64));
        // Inline full value — the split-stream value model. No Cell/Assign
        // events are emitted (the Nim writer does not expose them), so the
        // value is self-contained on the step.
        let value = ValueRecord::Int {
            i: (i * 100) as i64,
            type_id: int_type,
        };
        writer.register_variable_with_full_value(&format!("var_{i}"), value);
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

/// Produce the EQUIVALENT recording as a legacy `events.log` bundle, which
/// `CTFSTraceReader::open` serves through `open_old_format` →
/// `TraceProcessor::postprocess` (see `common::legacy_events_log`).
///
/// The event sequence mirrors `write_split_only_bundle`'s user-visible content:
/// one wrapping call, a leading step, then `USER_STEPS` steps each with
/// `var_i = i*100` recorded as a `Value` event (the materialized-path analogue
/// of the split path's inline `StepValues`).
fn write_events_log_bundle(dir: &Path) -> PathBuf {
    use codetracer_trace_types::{
        CallRecord, FullValueRecord, FunctionId, FunctionRecord, PathId, ReturnRecord, StepRecord, TraceLowLevelEvent,
        TypeRecord, TypeSpecificInfo, VariableId,
    };

    let int_type = TypeId(1);
    let mut events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(PathBuf::from(SRC)),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "Int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".to_string(),
        }),
        // The wrapping call MUST precede the first Step: TraceProcessor asserts
        // a call is active (`current_call_key >= 0`) before processing any step.
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
    ];

    for i in 0..USER_STEPS {
        events.push(TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(10 + i as i64),
        }));
        events.push(TraceLowLevelEvent::VariableName(format!("var_{i}")));
        events.push(TraceLowLevelEvent::Value(FullValueRecord {
            variable_id: VariableId(i),
            value: ValueRecord::Int {
                i: (i * 100) as i64,
                type_id: int_type,
            },
        }));
    }

    events.push(TraceLowLevelEvent::Return(ReturnRecord {
        return_value: ValueRecord::None { type_id: TypeId(0) },
    }));

    common::legacy_events_log::write_legacy_events_log_bundle(dir, "events_log_prog", &events)
}

/// Collect a step's `(var_name, int_value)` locals from a reader, projecting the
/// per-step variable snapshot the DAP locals view is built from. Only `Int`
/// values appear in the fixtures, so non-`Int` values would fail the lookup.
fn locals_at(reader: &CTFSTraceReader, step_id: StepId) -> Vec<(String, i64)> {
    let Some(vars) = reader.variables_at(step_id) else {
        return Vec::new();
    };
    vars.iter()
        .map(|v| {
            let name = reader.variable_name(v.variable_id).unwrap_or("<unknown>").to_string();
            let i = match v.value {
                ValueRecord::Int { i, .. } => i,
                ref other => panic!("expected Int local, got {other:?}"),
            };
            (name, i)
        })
        .collect()
}

/// Find the total-stream step index whose source line is `line`, scanning the
/// materialized step table. The fixtures put user step `i` at `Line(10 + i)`,
/// but the leading step / call bookkeeping can shift absolute indices, so we
/// resolve by line to compare the two bundles structurally.
fn step_index_for_line(reader: &CTFSTraceReader, line: i64) -> Option<StepId> {
    (0..reader.step_count() as i64)
        .map(StepId)
        .find(|&sid| reader.step(sid).map(|s| s.line == Line(line)).unwrap_or(false))
}

/// Deliverable #1 — the split-only bundle is GENUINELY `events.log`-free, so the
/// reader takes the new-format (split-stream) path, and the full `Db` (steps,
/// calls, values) is correctly populated.
#[test]
fn split_only_bundle_is_events_log_free_and_fully_served() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_split_only_bundle(dir.path());

    // ── The bundle layout is genuinely split-only ──────────────────────
    {
        let ctfs = CtfsReader::open(&ct).expect("open ctfs container");
        assert!(
            ctfs.has_file("steps.dat"),
            "production split bundle must carry steps.dat (got files: {:?})",
            ctfs.file_names()
        );
        assert!(
            !ctfs.has_file("events.log"),
            "production split bundle must NOT carry events.log — it is split-only \
             (got files: {:?})",
            ctfs.file_names()
        );
    }

    // ── The full Db is served through the split (new-format) path ───────
    let reader = CTFSTraceReader::open(&ct).expect("CTFSTraceReader::open split-only");

    // Steps: leading step + USER_STEPS explicit steps. We assert the user
    // steps are all present and resolve the locals by line below.
    assert!(
        reader.step_count() >= USER_STEPS,
        "expected at least {USER_STEPS} steps, got {}",
        reader.step_count()
    );

    // Calls: exactly `<toplevel>` (call 0, the root) and `main` below it.
    assert_eq!(
        reader.call_count(),
        2,
        "expected the `<toplevel>` root and one `main` call, got {}",
        reader.call_count()
    );
    let root = reader.call(CallKey(0)).expect("call 0 present");
    let root_fn = reader.function(root.function_id).expect("root function record");
    assert_eq!(root_fn.name, "<toplevel>", "call 0 must be the `<toplevel>` root");
    assert_eq!(root.depth, 0, "the `<toplevel>` root is at depth 0");
    let main_call = reader.call(CallKey(1)).expect("call 1 present");
    let main_fn = reader.function(main_call.function_id).expect("main function record");
    assert_eq!(main_fn.name, "main", "the call below the root should be `main`");
    assert_eq!(main_call.depth, 1, "`main` sits directly below `<toplevel>`");
    assert_eq!(
        main_call.parent_key,
        CallKey(0),
        "`main`'s parent is the `<toplevel>` root"
    );

    // Values: every user step's inline full value surfaces via variables_at.
    for i in 0..USER_STEPS {
        let line = 10 + i as i64;
        let sid = step_index_for_line(&reader, line).unwrap_or_else(|| panic!("no step at line {line}"));
        let locals = locals_at(&reader, sid);
        assert_eq!(
            locals,
            vec![(format!("var_{i}"), (i * 100) as i64)],
            "step at line {line} should serve var_{i} = {} via the split values stream",
            i * 100
        );
    }
}

/// Deliverable #3 (subsumes M22's `[~]` cell remainder) — the cell/compound
/// history accessors behave CORRECTLY for a split-only bundle.
///
/// The split format records INLINE FULL VALUES, not `Cell`/`Assign` references,
/// so the cell-change index, per-step cell/compound maps, and variable→place
/// maps are legitimately EMPTY — and every local is fully served from the
/// per-step variable snapshot (asserted in
/// `split_only_bundle_is_events_log_free_and_fully_served`). An empty cell
/// history is therefore the COMPLETE, correct answer for a split bundle: M22's
/// `[~]` remainder is resolved (the debugger's locals view needs no cell
/// history on the split path).
#[test]
fn split_only_bundle_cell_history_is_correctly_empty() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_split_only_bundle(dir.path());
    let reader = CTFSTraceReader::open(&ct).expect("CTFSTraceReader::open split-only");

    for i in 0..USER_STEPS {
        let line = 10 + i as i64;
        let sid = step_index_for_line(&reader, line).unwrap_or_else(|| panic!("no step at line {line}"));

        // The per-step maps exist (the new-format path pushes one HashMap per
        // step) but are empty: no Cell/Assign events ⇒ no compound/cell entries.
        let compound = reader.compound_at(sid).expect("compound map present per step");
        assert!(
            compound.is_empty(),
            "split bundle records no compound values at line {line}"
        );

        let cells = reader.cells_at(sid).expect("cells map present per step");
        assert!(cells.is_empty(), "split bundle records no cell values at line {line}");

        // No `register_variable`/`bind_variable` ⇒ no variable→place tracking.
        let vcells = reader
            .variable_cells_at(sid)
            .expect("variable_cells map present per step");
        assert!(
            vcells.is_empty(),
            "split bundle records no variable→place cells at line {line} \
             (locals come from the inline full-value snapshot, not cell refs)"
        );
    }

    // No `cell_changes` index at all — there are no places to track.
    use codetracer_trace_types::Place;
    assert!(
        reader.cell_changes_for(&Place(0)).is_none(),
        "split bundle has no cell-change history for any place"
    );
}

/// Deliverable #4 (PARITY / A/B) — the split-only bundle and the equivalent
/// legacy `events.log` bundle yield the SAME steps and per-step variable
/// values, so the debugger shows identical data whichever format it reads.
#[test]
fn split_only_and_events_log_bundles_agree() {
    let dir = tempfile::tempdir().unwrap();
    let split_ct = write_split_only_bundle(dir.path());
    let log_ct = write_events_log_bundle(dir.path());

    // Confirm the two bundles genuinely take different reader paths.
    {
        let split = CtfsReader::open(&split_ct).expect("open split");
        assert!(split.has_file("steps.dat") && !split.has_file("events.log"));
        let mut log = CtfsReader::open(&log_ct).expect("open log");
        assert!(
            !log.has_file("steps.dat"),
            "events.log bundle must NOT carry steps.dat (so it takes the legacy path)"
        );
        assert!(
            log.read_file("events.log").is_ok(),
            "events.log bundle must carry events.log"
        );
    }

    let split = CTFSTraceReader::open(&split_ct).expect("open split reader");
    let log = CTFSTraceReader::open(&log_ct).expect("open events.log reader");

    // For every user step, both readers resolve the SAME `(var_name, value)`.
    for i in 0..USER_STEPS {
        let line = 10 + i as i64;
        let split_sid = step_index_for_line(&split, line).unwrap_or_else(|| panic!("split: no step at line {line}"));
        let log_sid = step_index_for_line(&log, line).unwrap_or_else(|| panic!("events.log: no step at line {line}"));

        let split_locals = locals_at(&split, split_sid);
        let log_locals = locals_at(&log, log_sid);

        assert_eq!(
            split_locals, log_locals,
            "split and events.log bundles must serve identical locals at line {line}"
        );
        assert_eq!(
            split_locals,
            vec![(format!("var_{i}"), (i * 100) as i64)],
            "both bundles serve var_{i} = {} at line {line}",
            i * 100
        );
    }
}
