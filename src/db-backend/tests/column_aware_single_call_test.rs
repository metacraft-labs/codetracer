//! A long, single-call, COLUMN-AWARE trace opened the way the browser opens it
//! must not cost a walk to the end of the call on every `load_location`.
//!
//! ## The defect this pins
//!
//! codetracer-pm `issues/2026-11-26-large-evm-recordings-cannot-be-debugged-in-the-hydrated-debug-page.md`:
//! in the browser a 673,363-step EVM recording loaded in 0.6 s and then never
//! finished `launch`; a 39k-step one took 29 s to become ready and 7-21 s per
//! step.
//!
//! `TraceReader::load_location` finds a function's LAST line as the greatest
//! line over the suffix of the current call's step run that starts at the
//! current step. It reaches that computation whenever the source cannot be
//! loaded, which in the browser is always (there is no filesystem). M0/3 serves
//! it from two indices — the lazy step cache's resident call-key array (the
//! run's end) and the container's `step-map.ns` (the run's greatest line) — and
//! needs BOTH. An EVM trace is column-aware, and the Nim writer does not emit
//! `step-map.ns` for a column-aware trace, so the line half is always missing:
//! in the browser (`from_bytes`, which keeps a lazy step cache even for a
//! column-aware trace) and natively (`open`, which reads a column-aware trace
//! eagerly and so has no call-key array either). `load_location` therefore
//! walked the run one step at a time, and an EVM transaction is one call: each
//! `load_location` walked to the end of the trace, and the flow preloader,
//! which loads a location after every move through the call, walked O(n^2)
//! steps.
//!
//! ## How it is measured
//!
//! By an operation count, not a clock:
//! `call_run_line_index::function_last_step_reads_on_this_thread` counts every step
//! read on behalf of `function_last`. The bounds below are linear in the trace
//! length with a generous constant, and the defect they catch is quadratic, so
//! the two are orders of magnitude apart at these sizes and host load cannot
//! move a result across the line.
//!
//! ## The fixture
//!
//! Written at test time by the production Nim writer with the calls the EVM
//! recorder makes (`enable_column_aware_steps`, paths registered with their
//! line lengths, `register_step_with_column`), across two source files inside
//! one call. The source paths do not exist on this host, so the native
//! `load_file` fails exactly as the browser's does and `load_location` takes
//! the same branch. No mocks: the reader, the replay session and the flow
//! preloader are the production ones.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::{CallKey, Line, NO_KEY, StepId, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::call_run_line_index::function_last_step_reads_on_this_thread;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::MaterializedReplaySession;
use db_backend::expr_loader::ExprLoader;
use db_backend::flow_preloader::FlowPreloader;
use db_backend::task::{CoreTrace, FlowMode, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;

/// Two source files, as an EVM contract and the library it calls into. Neither
/// exists, so `ExprLoader::load_file` fails for both.
const CONTRACT: &str = "/nonexistent-column-aware-fixture/Token.sol";
const LIBRARY: &str = "/nonexistent-column-aware-fixture/SafeMath.sol";

/// Lines per registered file. Every recorded line is within this.
const FILE_LINES: usize = 500;

/// Steps recorded at top level after the call returns, so the trace has a run
/// boundary after the long call and not only before it.
const TRAILING_TOPLEVEL_STEPS: usize = 3;

/// The line of the `i`-th step inside the call: scattered over the file, so
/// the suffix maximum changes along the run instead of being one constant.
fn line_of(i: usize) -> i64 {
    5 + ((i * 7919) % (FILE_LINES - 10)) as i64
}

/// Write a column-aware, single-call container of `call_steps` steps inside
/// the call, and return its path.
fn write_column_aware_single_call(dir: &Path, call_steps: usize) -> PathBuf {
    let stem = "column_aware_single_call";
    let trace_path = dir.join(stem);
    let ct_path = dir.join(format!("{stem}.ct"));

    let mut writer = NimTraceWriter::new(stem, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    // The EVM recorder's order: column awareness first, before any step.
    writer.enable_column_aware_steps();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let contract = Path::new(CONTRACT);
    let library = Path::new(LIBRARY);
    // Registered with their line lengths BEFORE `start`, as the EVM recorder
    // does: a column-aware reader maps a step's global position back to
    // (line, column) through this table.
    let line_lengths = vec![40u32; FILE_LINES];
    writer.register_path_with_line_lengths(contract, &line_lengths).unwrap();
    writer.register_path_with_line_lengths(library, &line_lengths).unwrap();

    writer.start(contract, Line(1));
    // Defined at the entry step's position, so the `<toplevel>` root that
    // `start` opens is recognised as a wrapper and replay starts INSIDE the
    // call, as it does for an EVM recording (`first_user_call`).
    let fid = writer.ensure_function_id("transfer", contract, Line(1));
    writer.register_function("transfer", contract, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "uint256");

    writer.register_step_with_column(contract, Line(1), Some(Line(1)));
    TraceWriter::register_call(&mut writer, fid, vec![]);
    for i in 0..call_steps {
        // One step in eight is in the library, inside the same call: the EVM
        // recorder attributes a whole transaction to one call whatever file
        // the source map points into.
        let path = if i % 8 == 7 { library } else { contract };
        writer.register_step_with_column(path, Line(line_of(i)), Some(Line(1 + (i % 30) as i64)));
        writer.register_variable_with_full_value(
            "balance",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
    }
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    for i in 0..TRAILING_TOPLEVEL_STEPS {
        writer.register_step_with_column(contract, Line(2 + i as i64), Some(Line(1)));
    }
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), "the Nim writer must produce {}", ct_path.display());
    ct_path
}

/// Which constructor opened the container.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Opened {
    /// `from_bytes` — the browser's only constructor. It keeps a LAZY step
    /// cache even for a column-aware trace, so the call-run end is served from
    /// its resident call-key array, but there is no `step-map.ns` to serve the
    /// line maximum.
    Browser,
    /// `open` — the native constructor, which reads a column-aware trace
    /// EAGERLY, so neither index exists.
    Native,
}

/// The container, opened by one of the two constructors.
struct Fixture {
    _dir: tempfile::TempDir,
    reader: Arc<CTFSTraceReader>,
    /// The call holding the long run.
    call_key: CallKey,
    /// The first step of that run.
    run_start: StepId,
}

fn fixture(call_steps: usize, opened: Opened) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_column_aware_single_call(dir.path(), call_steps);
    let reader = match opened {
        Opened::Browser => CTFSTraceReader::from_bytes(std::fs::read(&ct).unwrap())
            .expect("from_bytes must open the column-aware container"),
        Opened::Native => CTFSTraceReader::open(&ct).expect("open must open the column-aware container"),
    };

    // THE PREMISE. Each of these is a reason the M0/3 indices cannot answer,
    // and if one stops holding this suite is measuring a different path.
    assert!(
        reader.step_count() >= call_steps,
        "the trace must hold the call's steps ({} < {call_steps})",
        reader.step_count()
    );
    assert!(
        !reader.has_prepopulated_step_map(),
        "the Nim writer does not emit step-map.ns for a column-aware trace"
    );
    match opened {
        Opened::Browser => assert_eq!(
            reader.lazy_full_steps_materialized(),
            Some(false),
            "from_bytes serves steps from a lazy cache"
        ),
        Opened::Native => assert_eq!(
            reader.lazy_full_steps_materialized(),
            None,
            "open reads a column-aware trace EAGERLY (no lazy step cache)"
        ),
    }
    assert!(
        (0..reader.step_count() as i64).any(|i| reader.step(StepId(i)).is_some_and(|s| s.column.is_some())),
        "the steps must carry columns, or the trace is not column-aware"
    );

    // The long run: the first step whose call is `transfer`.
    let (run_start, call_key) = (0..reader.step_count() as i64)
        .map(StepId)
        .find_map(|id| {
            let step = reader.step(id)?;
            let call = reader.call(step.call_key)?;
            let name = &reader.function(call.function_id)?.name;
            (name == "transfer").then_some((id, step.call_key))
        })
        .expect("the trace must record the transfer call");
    let run_end = reader.call_run_end(run_start, call_key);
    assert_eq!(
        run_end.is_some(),
        opened == Opened::Browser,
        "only the lazy (browser) reader has the resident call-key index"
    );
    if let Some(run_end) = run_end {
        assert_eq!(
            reader.max_line_over_steps(run_start, run_end),
            None,
            "without step-map.ns the range maximum is not served"
        );
    }

    Fixture {
        _dir: dir,
        reader: Arc::new(reader),
        call_key,
        run_start,
    }
}

/// `function_last` as the pre-fix walk computed it, verbatim: the function's
/// line, raised by every line over the run of `call_key` beginning at `start`.
fn walked_function_last(reader: &dyn TraceReader, start: i64, call_key: CallKey) -> i64 {
    let call = reader.call(call_key).expect("call");
    let mut last_line = reader.function(call.function_id).expect("function").line.0;
    for i in start..reader.step_count() as i64 {
        let Some(step) = reader.step(StepId(i)) else { continue };
        if step.call_key == call_key {
            if step.line.0 > last_line {
                last_line = step.line.0;
            }
        } else {
            break;
        }
    }
    last_line
}

fn loader() -> ExprLoader {
    ExprLoader::new(CoreTrace::default())
}

/// The issue's cause, at the layer it lives in: `load_location` over many steps
/// of one long call reads each step of the trace a bounded number of times in
/// total, not once per `load_location`.
///
/// Unfixed, the 4,000 calls below read about 4 x 10^7 steps (each walks to the
/// end of the call); the bound is 2 x the trace length.
fn assert_load_location_does_not_walk_the_call_each_time(opened: Opened) {
    const CALL_STEPS: usize = 20_000;
    let f = fixture(CALL_STEPS, opened);
    let n = f.reader.step_count() as u64;
    let mut expr_loader = loader();

    let before = function_last_step_reads_on_this_thread();
    let mut probes = 0u64;
    for step in (f.run_start.0..f.run_start.0 + CALL_STEPS as i64).step_by(5) {
        let location = f.reader.load_location(StepId(step), CallKey(-1), &mut expr_loader);
        assert_eq!(location.key, f.call_key.0.to_string());
        probes += 1;
    }
    let reads = function_last_step_reads_on_this_thread() - before;

    assert!(
        reads <= 2 * n,
        "{opened:?}: {probes} load_location calls over one {CALL_STEPS}-step call read {reads} \
         steps to find function_last; a resident index reads each of the {n} steps at most once, \
         and a walk per call reads ~{probes} x {} — the quadratic cost that kept a 673k-step EVM \
         launch from completing",
        CALL_STEPS / 2
    );
}

#[test]
fn browser_load_location_over_a_long_column_aware_call_does_not_walk_the_call_each_time() {
    assert_load_location_does_not_walk_the_call_each_time(Opened::Browser);
}

#[test]
fn native_load_location_over_a_long_column_aware_call_does_not_walk_the_call_each_time() {
    assert_load_location_does_not_walk_the_call_each_time(Opened::Native);
}

/// The same cost through the path the browser actually drives: a call flow over
/// the long call, which steps `Next` through it and loads a location after
/// every move. Unfixed this is ~10,000 moves x ~7,000-step walks.
#[test]
fn a_browser_call_flow_over_a_long_column_aware_call_reads_the_trace_a_bounded_number_of_times() {
    const CALL_STEPS: usize = 12_000;
    let f = fixture(CALL_STEPS, Opened::Browser);
    let n = f.reader.step_count() as u64;
    let reader: Arc<dyn TraceReader> = f.reader.clone();

    let mut location = reader.load_location(f.run_start, f.call_key, &mut loader());
    location.rr_ticks = RRTicks(f.run_start.0);

    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let mut flow_preloader = FlowPreloader::new();
    let before = function_last_step_reads_on_this_thread();
    let flow = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);
    let reads = function_last_step_reads_on_this_thread() - before;

    assert!(!flow.error, "the flow must load: {}", flow.error_message);
    let walked = flow.view_updates.first().map(|v| v.steps.len()).unwrap_or(0);
    assert!(
        walked >= 1_000,
        "the flow must actually walk the call (walked {walked} steps)"
    );
    assert!(
        reads <= 2 * n,
        "a {walked}-step call flow over one {CALL_STEPS}-step call read {reads} steps to find \
         function_last; the bound is 2 x {n}"
    );
}

/// The fix must not change a single answer: `load_location`'s `function_last`
/// equals the walk's at every sampled step, against the step's own call key,
/// against a key it does not carry (an empty run), and at the top-level steps
/// on either side of the call.
fn assert_function_last_agrees_with_the_walk(opened: Opened) {
    const CALL_STEPS: usize = 6_000;
    let f = fixture(CALL_STEPS, opened);
    let n = f.reader.step_count() as i64;
    let mut expr_loader = loader();

    let mut empty_runs = 0;
    let mut real_runs = 0;
    let samples = (0..n).step_by(37).chain([0, n - 1, f.run_start.0, f.run_start.0 - 1]);
    for start in samples.filter(|s| *s >= 0 && *s < n) {
        let own = f.reader.step(StepId(start)).unwrap().call_key;
        let mut keys = vec![CallKey(-1)];
        if own != NO_KEY {
            keys.push(own);
        }
        // A real call this step is NOT in: its run from here is empty.
        let other = if own == f.call_key { CallKey(0) } else { f.call_key };
        if other != own {
            keys.push(other);
        }
        for key in keys {
            let effective = if key.0 >= 0 { key } else { own };
            if effective == NO_KEY {
                continue;
            }
            let location = f.reader.load_location(StepId(start), key, &mut expr_loader);
            if location.function_name == "<top-level>" {
                // `load_location` leaves the boundaries unset there; nothing
                // to compare.
                continue;
            }
            let want = walked_function_last(&*f.reader, start, effective);
            assert_eq!(
                location.function_last, want,
                "{opened:?}: function_last disagrees with the walk at step {start} for call key \
                 {key:?} (effective {effective:?})"
            );
            if f.reader.step(StepId(start)).unwrap().call_key == effective {
                real_runs += 1;
            } else {
                empty_runs += 1;
            }
        }
    }
    assert!(
        empty_runs > 0 && real_runs > 0,
        "both an empty run and a real one must be compared ({empty_runs} empty / {real_runs} real)"
    );
}

#[test]
fn browser_function_last_agrees_with_the_walk_it_replaces() {
    assert_function_last_agrees_with_the_walk(Opened::Browser);
}

#[test]
fn native_function_last_agrees_with_the_walk_it_replaces() {
    assert_function_last_agrees_with_the_walk(Opened::Native);
}
