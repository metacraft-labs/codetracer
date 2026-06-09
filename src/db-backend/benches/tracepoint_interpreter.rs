//! Criterion bench for the tracepoint_interpreter hot path.
//!
//! Per Performance + E2E Coverage campaign P4.6 / P9.2: exercises the
//! production [`db_backend::tracepoint_interpreter::TracepointInterpreter`]
//! against a synthetic event stream so the measurement isn't dominated
//! by trace I/O. The interpreter itself is the production code path —
//! only the inputs (variable values, call expression results, step ids)
//! are synthesised by a lightweight in-process [`SyntheticReplaySession`].
//!
//! ## Matrix report
//!
//! The bench's headline deliverable is a CSV/JSON/Markdown matrix that
//! matches the shape `ct-bench gui-ops` emits at
//! `target/codetracer-bench/gui-ops-latency/report.{csv,json,md}`. The
//! emit happens automatically when the bench's measurement loop closes
//! so consumers don't have to merge two report shapes when comparing
//! the tracepoint hot path against the GUI-op latencies. The bench
//! writes to
//! `target/codetracer-bench/tracepoint-interpreter/report.{csv,json,md}`
//! (or the path under `$CODETRACER_BENCH_OUT` if set).
//!
//! The actual CSV / JSON / Markdown bytes are produced by
//! [`db_backend::bench_matrix_report`] so the verification integration
//! test can call the same emitter directly without spawning
//! `cargo bench` as a subprocess.

use std::cell::RefCell;
use std::error::Error as StdError;
use std::time::{Duration, Instant};

use codetracer_trace_types::{FieldTypeRecord, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo};
use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};

use db_backend::bench_matrix_report::{self, CellResult};
use db_backend::db::DbRecordEvent;
use db_backend::expr_loader::ExprLoader;
use db_backend::lang::Lang;
use db_backend::replay::ReplaySession;
use db_backend::task::{
    Action, Breakpoint, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord,
    LoadHistoryArg, Location, ProgramEvent, VariableWithRecord,
};
use db_backend::tracepoint_interpreter::TracepointInterpreter;
use db_backend::value::ValueRecordWithType;

/// Synthetic event-stream sizes the bench drives through `evaluate`.
/// Each entry becomes one row in the matrix report.
const STREAM_SIZES: &[usize] = &[10, 100, 1_000, 10_000];

/// Representative set of tracepoint expressions the bench compiles and
/// evaluates against the synthetic stream. The set hits every
/// `Instruction` variant the production VM dispatches:
///
/// * `log(scalar)` — PushVariable, Log
/// * `log(arr[2])` — PushVariable, PushInt, Index, Log
/// * `log(obj.x)` — PushVariable, Field, Log
/// * `log(a + b * c)` — BinaryOperation (+/*)
/// * `log(a > 0 && a < 100)` — Comparison + boolean and
/// * `if a > 0 { log(arr[0]) }` — JumpIfFalse, conditional Log
/// * `log(-a)` — UnaryOperation (negation)
/// * `log(text)` — PushVariable returning a string
///
/// Together these exercise variable reads (the hot path for any
/// realistic tracepoint), arithmetic, control flow, indexing, field
/// access, and string / boolean comparisons — i.e. every shape of
/// `RValue` the M14 / Value Origin Tracking pipeline produces.
const TRACEPOINTS: &[&str] = &[
    "log(scalar)",
    "log(arr[2])",
    "log(obj.x)",
    "log(a + b * c)",
    "log(a > 0 && a < 100)",
    "if a > 0 { log(arr[0]) }",
    "log(-a)",
    "log(text)",
];

/// A minimal in-process [`ReplaySession`] that returns canned values for
/// `load_value` / `evaluate_call_expression`. The interpreter never
/// invokes the navigation, breakpoint, history, or origin surfaces, so
/// the rest of the trait methods are `unimplemented!()` — the bench
/// fails loudly if a future interpreter change reaches for one of them.
///
/// The session deliberately rebuilds nothing per `evaluate` call so the
/// measurement isolates the VM dispatch + value cloning cost, not the
/// cost of constructing the synthetic value graph.
#[derive(Debug)]
struct SyntheticReplaySession {
    /// Current step id reported to the interpreter. Bumped per
    /// synthetic event so the evaluator sees forward progress.
    step_id: StepId,
    /// Cache of the canned values returned for each well-known
    /// variable name in [`TRACEPOINTS`]. Pre-built once at session
    /// construction time so the per-iteration cost is bounded by the
    /// cloning cost (a real session pays this cost too — DB rows
    /// materialise into `ValueRecordWithType` per query).
    canned: RefCell<Vec<(String, ValueRecordWithType)>>,
}

impl SyntheticReplaySession {
    fn new() -> Self {
        let int_t = simple_type(TypeKind::Int, "int");
        let str_t = simple_type(TypeKind::String, "string");
        let seq_t = simple_type(TypeKind::Seq, "seq[int]");
        let struct_t = struct_type("Obj", &[("x", TypeId(0)), ("y", TypeId(0))]);

        let canned: Vec<(String, ValueRecordWithType)> = vec![
            ("scalar".to_string(), int_val(42, &int_t)),
            (
                "arr".to_string(),
                ValueRecordWithType::Sequence {
                    elements: vec![
                        int_val(10, &int_t),
                        int_val(20, &int_t),
                        int_val(30, &int_t),
                        int_val(40, &int_t),
                        int_val(50, &int_t),
                    ],
                    is_slice: false,
                    typ: seq_t,
                },
            ),
            (
                "obj".to_string(),
                ValueRecordWithType::Struct {
                    field_values: vec![int_val(7, &int_t), int_val(11, &int_t)],
                    typ: struct_t,
                },
            ),
            ("a".to_string(), int_val(5, &int_t)),
            ("b".to_string(), int_val(3, &int_t)),
            ("c".to_string(), int_val(2, &int_t)),
            (
                "text".to_string(),
                ValueRecordWithType::String {
                    text: "hello-tracepoint".to_string(),
                    typ: str_t,
                },
            ),
        ];

        Self {
            step_id: StepId(0),
            canned: RefCell::new(canned),
        }
    }

    fn advance(&mut self) {
        self.step_id = StepId(self.step_id.0 + 1);
    }
}

fn simple_type(kind: TypeKind, lang_type: &str) -> TypeRecord {
    TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

fn struct_type(lang_type: &str, fields: &[(&str, TypeId)]) -> TypeRecord {
    TypeRecord {
        kind: TypeKind::Struct,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::Struct {
            fields: fields
                .iter()
                .map(|(name, id)| FieldTypeRecord {
                    name: (*name).to_string(),
                    type_id: *id,
                })
                .collect(),
        },
    }
}

fn int_val(i: i64, typ: &TypeRecord) -> ValueRecordWithType {
    ValueRecordWithType::Int { i, typ: typ.clone() }
}

impl ReplaySession for SyntheticReplaySession {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn StdError>> {
        Ok(Location::default())
    }
    fn run_to_entry(&mut self) -> Result<(), Box<dyn StdError>> {
        Ok(())
    }
    fn load_events(&mut self) -> Result<Events, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls load_events")
    }
    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls step")
    }
    fn load_locals(
        &mut self,
        _arg: CtLoadLocalsArguments,
    ) -> Result<Vec<VariableWithRecord>, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls load_locals")
    }
    fn load_value(
        &mut self,
        expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn StdError>> {
        // Linear scan over the canned vector: the interpreter only
        // queries 7 variables, so a HashMap lookup would add per-call
        // hashing cost without changing the asymptotics. Mirrors how
        // the production MaterializedReplaySession resolves names
        // against a small local-scope slice.
        let canned = self.canned.borrow();
        for (name, value) in canned.iter() {
            if name == expression {
                return Ok(value.clone());
            }
        }
        Err(format!("synthetic session: no canned value for variable {expression}").into())
    }
    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls load_return_value")
    }
    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        Vec::new()
    }
    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls load_callstack")
    }
    fn load_history(
        &mut self,
        _arg: &LoadHistoryArg,
    ) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls load_history")
    }
    fn add_breakpoint(&mut self, _path: &str, _line: i64) -> Result<Breakpoint, Box<dyn StdError>> {
        unimplemented!("synthetic session: interpreter never calls add_breakpoint")
    }
    fn delete_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<bool, Box<dyn StdError>> {
        unimplemented!()
    }
    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn StdError>> {
        unimplemented!()
    }
    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn StdError>> {
        unimplemented!()
    }
    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn StdError>> {
        unimplemented!()
    }
    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn StdError>> {
        unimplemented!()
    }
    fn jump_to(&mut self, step_id: StepId) -> Result<bool, Box<dyn StdError>> {
        self.step_id = step_id;
        Ok(true)
    }
    fn jump_to_call(&mut self, location: &Location) -> Result<Location, Box<dyn StdError>> {
        Ok(location.clone())
    }
    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn StdError>> {
        unimplemented!()
    }
    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn StdError>> {
        unimplemented!()
    }
    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn StdError>> {
        Ok(())
    }
    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn StdError>> {
        unimplemented!()
    }
    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn StdError>> {
        // Production interpreters call this for function-call captures
        // such as `log(my_func())`. The bench's tracepoint set doesn't
        // exercise this branch by default — we return an int sentinel
        // so a future TRACEPOINTS entry like `log(my_func())` benches
        // the dispatch cost rather than crashing the suite.
        Ok(ValueRecordWithType::Int {
            i: 0,
            typ: simple_type(TypeKind::Int, "int"),
        })
    }
    fn current_step_id(&mut self) -> StepId {
        self.step_id
    }
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

/// Built once and reused across every iteration of every bench cell so
/// the bytecode-compile cost (tree-sitter parse + lowering) is paid
/// once per bench run. The interpreter's measurement is then `evaluate`
/// over the synthetic event stream.
struct Compiled {
    interpreter: TracepointInterpreter,
}

impl Compiled {
    fn build() -> Self {
        let mut interpreter = TracepointInterpreter::new(TRACEPOINTS.len());
        for (i, src) in TRACEPOINTS.iter().enumerate() {
            interpreter
                .register_tracepoint(i, src)
                .unwrap_or_else(|e| panic!("failed to register tracepoint {src:?}: {e}"));
        }
        Self { interpreter }
    }
}

thread_local! {
    /// Per-run accumulator the bench fills as `bench_tracepoint_eval`
    /// completes each cell. Drained by [`drain_results`] before being
    /// passed to [`bench_matrix_report::emit`].
    static RESULTS: RefCell<Vec<CellResult>> = const { RefCell::new(Vec::new()) };
}

/// Drive `interpreter.evaluate` `stream_size` times, rotating through
/// the registered tracepoints so each variant's hot path is exercised
/// uniformly.
fn drive_stream(compiled: &Compiled, session: &mut SyntheticReplaySession, stream_size: usize) {
    for i in 0..stream_size {
        let tp_idx = i % TRACEPOINTS.len();
        let step = session.step_id;
        let _ = compiled
            .interpreter
            .evaluate(tp_idx, step, session, Lang::Python);
        session.advance();
    }
}

/// Direct-measurement loop used by the matrix-report path. Criterion's
/// per-iteration timings live in a private `Estimates` struct; rather
/// than parse Criterion's JSON output, the bench reruns the workload
/// here under a fresh `Instant`-based sampler so the matrix report
/// gets the same numbers it would if it had peeked into Criterion's
/// internals.
pub fn measure_cell(stream_size: usize, samples: usize) -> CellResult {
    let compiled = Compiled::build();
    let mut session = SyntheticReplaySession::new();
    // Warmup: one pass to prime caches and ensure tree-sitter's
    // per-thread state is initialised — without this the first sample
    // is consistently ~20% slower than steady-state.
    drive_stream(&compiled, &mut session, stream_size);

    let mut timings_us: Vec<f64> = Vec::with_capacity(samples);
    for _ in 0..samples {
        let started = Instant::now();
        drive_stream(&compiled, &mut session, stream_size);
        let elapsed = started.elapsed();
        timings_us.push(elapsed.as_secs_f64() * 1_000_000.0);
    }
    timings_us.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50_us = percentile(&timings_us, 50.0);
    let p95_us = percentile(&timings_us, 95.0);
    CellResult {
        stream_size,
        p50_us,
        p95_us,
    }
}

fn percentile(sorted: &[f64], pct: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((pct / 100.0) * (sorted.len() as f64 - 1.0)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// Public re-export so the verification integration test can call the
/// bench's full measurement-and-emit pipeline through one entry point.
/// Returns the directory the report landed in.
pub fn run_and_emit(stream_sizes: &[usize], samples_per_cell: usize) -> std::io::Result<std::path::PathBuf> {
    let mut results = Vec::with_capacity(stream_sizes.len());
    for &n in stream_sizes {
        results.push(measure_cell(n, samples_per_cell));
    }
    bench_matrix_report::emit(&results, env!("CARGO_MANIFEST_DIR"))
}

/// Criterion entry point: drives the interpreter at each configured
/// stream size and records the per-cell result for the matrix report.
fn bench_tracepoint_eval(c: &mut Criterion) {
    let compiled = Compiled::build();
    let mut group = c.benchmark_group("tracepoint-eval");
    // Keep the Criterion sample-time short — the bench's headline
    // signal is the matrix report we emit ourselves, not Criterion's
    // per-bench HTML report. The Criterion measurement is here so the
    // bench shows up in `cargo bench` invocations and so we get
    // statistical-error bars for the per-iteration cost when operators
    // want them.
    group.sample_size(20);
    group.measurement_time(Duration::from_secs(2));

    for &n in STREAM_SIZES {
        group.bench_with_input(BenchmarkId::from_parameter(n), &n, |b, &n| {
            let mut session = SyntheticReplaySession::new();
            b.iter(|| drive_stream(&compiled, &mut session, n));
        });

        // Mirror the Criterion measurement into the matrix report via
        // our own sampling loop. 30 samples is enough for a stable p95
        // at the chosen stream sizes without inflating CI time (the
        // bench's outer budget stays bounded by `STREAM_SIZES`).
        let result = measure_cell(n, 30);
        RESULTS.with(|r| r.borrow_mut().push(result));
    }

    group.finish();

    let results = drain_results();
    if let Err(err) = bench_matrix_report::emit(&results, env!("CARGO_MANIFEST_DIR")) {
        // The matrix report is the bench's headline deliverable per
        // P4.6 — surface emit failures loudly so a sandboxed CI run
        // doesn't silently lose the rows.
        eprintln!("tracepoint_interpreter bench: failed to emit matrix report: {err}");
    }
}

fn drain_results() -> Vec<CellResult> {
    RESULTS.with(|r| r.borrow_mut().drain(..).collect())
}

criterion_group!(benches, bench_tracepoint_eval);
criterion_main!(benches);
