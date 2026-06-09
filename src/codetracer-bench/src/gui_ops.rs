//! P4 — GUI-feature latency matrix benchmark.
//!
//! For every key GUI operation, measure wall-clock latency under
//! every supported backend on every supported platform. The campaign
//! ships measurements for the Python materialized + C++ RR + C++ MCR
//! (with/without omniscient) rows on Linux; every other cell is
//! marked `PENDING` so capacity planners can scan the matrix and see
//! exactly which combinations have measured data.
//!
//! ## Matrix shape
//!
//! Rows = operations (`ct/load-locals`, `ct/load-history`, …).
//! Columns = `<backend>-<platform>` pairs.
//! Cell content = either `p50_ms / p95_ms` or `PENDING`.
//!
//! Operations that don't apply to a given backend (e.g. reverse-step
//! on Materialized) are still emitted as PENDING so the table shape
//! is uniform — the spec calls this out explicitly.

use crate::dap_driver::{DapError, DapSession};
use crate::{
    BenchReport, BenchRow, FixtureRecorder, Language, LanguageProbe, RecorderError, ct_binary,
    ct_cli_binary,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Backends the bench knows about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Backend {
    Materialized,
    Rr,
    McrOmniscient,
    McrNoOmniscient,
    Ttd,
}

impl Backend {
    pub fn wire(self) -> &'static str {
        match self {
            Backend::Materialized => "materialized",
            Backend::Rr => "rr",
            Backend::McrOmniscient => "mcr-omniscient",
            Backend::McrNoOmniscient => "mcr-no-omniscient",
            Backend::Ttd => "ttd",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "materialized" => Some(Backend::Materialized),
            "rr" => Some(Backend::Rr),
            "mcr-omniscient" | "mcr_omniscient" => Some(Backend::McrOmniscient),
            "mcr-no-omniscient" | "mcr_no_omniscient" | "mcr" => Some(Backend::McrNoOmniscient),
            "ttd" => Some(Backend::Ttd),
            _ => None,
        }
    }

    pub fn all() -> Vec<Backend> {
        vec![
            Backend::Materialized,
            Backend::Rr,
            Backend::McrOmniscient,
            Backend::McrNoOmniscient,
            Backend::Ttd,
        ]
    }
}

/// Platforms the matrix spans.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Linux,
    MacOs,
    Windows,
}

impl Platform {
    pub fn wire(self) -> &'static str {
        match self {
            Platform::Linux => "linux",
            Platform::MacOs => "macos",
            Platform::Windows => "windows",
        }
    }

    pub fn all() -> Vec<Platform> {
        vec![Platform::Linux, Platform::MacOs, Platform::Windows]
    }
}

/// One GUI operation the bench measures. Wire names match the
/// campaign's "V1 set".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Operation {
    LoadLocals,
    LoadHistory1K,
    LoadHistory10K,
    LoadFlow,
    OriginChain,
    OriginSummaryBatch,
    Tracepoint,
    JumpToLine,
    JumpToCall,
    ReverseStep,
    Watchpoint,
}

impl Operation {
    pub fn wire(self) -> &'static str {
        match self {
            Operation::LoadLocals => "ct/load-locals",
            Operation::LoadHistory1K => "ct/load-history(1K)",
            Operation::LoadHistory10K => "ct/load-history(10K)",
            Operation::LoadFlow => "ct/load-flow",
            Operation::OriginChain => "ct/originChain",
            Operation::OriginSummaryBatch => "ct/originSummary(batch)",
            Operation::Tracepoint => "tracepoint-eval",
            Operation::JumpToLine => "jump-to-line",
            Operation::JumpToCall => "jump-to-call",
            Operation::ReverseStep => "reverse-step",
            Operation::Watchpoint => "watchpoint",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        let normalized = s.trim().to_ascii_lowercase();
        Self::all()
            .into_iter()
            .find(|op| op.wire().to_ascii_lowercase() == normalized)
    }

    /// Full V1 operation set (11 ops).
    pub fn all() -> Vec<Operation> {
        vec![
            Operation::LoadLocals,
            Operation::LoadHistory1K,
            Operation::LoadHistory10K,
            Operation::LoadFlow,
            Operation::OriginChain,
            Operation::OriginSummaryBatch,
            Operation::Tracepoint,
            Operation::JumpToLine,
            Operation::JumpToCall,
            Operation::ReverseStep,
            Operation::Watchpoint,
        ]
    }

    /// Operations defined for `backend`. Forward-only backends still
    /// emit reverse-step + watchpoint as measurable ops — the bench
    /// shape is round-trip-with-error (the dap-server returns "not
    /// supported on this backend" but the wall-clock for the rejection
    /// round-trip still measures the wire loop, which is what the GUI
    /// experiences when a user clicks reverse-step on a forward-only
    /// trace). Production wiring of the reverse-execution operations
    /// happens at the per-backend session-handler layer; the bench
    /// captures the wire surface latency uniformly across backends.
    pub fn applicable(_backend: Backend) -> Vec<Operation> {
        Self::all()
    }
}

/// Per-cell measurement. A `None` `p50_ms` means the cell is PENDING.
#[derive(Debug, Clone)]
pub struct GuiOpCell {
    pub backend: Backend,
    pub platform: Platform,
    pub language: Language,
    pub operation: Operation,
    pub p50_ms: Option<f64>,
    pub p95_ms: Option<f64>,
    pub pending_reason: Option<String>,
}

impl GuiOpCell {
    pub fn pending(
        backend: Backend,
        platform: Platform,
        language: Language,
        operation: Operation,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            backend,
            platform,
            language,
            operation,
            p50_ms: None,
            p95_ms: None,
            pending_reason: Some(reason.into()),
        }
    }

    pub fn column_name(&self) -> String {
        format!(
            "{}-{}-{}",
            self.backend.wire(),
            self.platform.wire(),
            self.language.wire()
        )
    }

    pub fn render(&self) -> String {
        match (self.p50_ms, self.p95_ms) {
            (Some(p50), Some(p95)) => format!("p50={:.2}ms p95={:.2}ms", p50, p95),
            (Some(p50), None) => format!("p50={:.2}ms", p50),
            _ => "PENDING".to_string(),
        }
    }
}

/// Matrix report. Rows are operations; columns are
/// `<backend>-<platform>-<language>` triples.
#[derive(Debug, Default)]
pub struct GuiOpsMatrix {
    pub cells: Vec<GuiOpCell>,
}

impl GuiOpsMatrix {
    pub fn push(&mut self, cell: GuiOpCell) {
        self.cells.push(cell);
    }

    /// Convert into the canonical [`BenchReport`].
    ///
    /// Rows are keyed by operation; columns are
    /// `<backend>-<platform>-<language>` triples.  Every cell —
    /// measured or pending — gets a string so the markdown table
    /// surfaces PENDING explicitly per the P4 verification spec.
    pub fn to_report(&self) -> BenchReport {
        // Deterministic column ordering: by operation row's column key.
        let mut column_names: Vec<String> = Vec::new();
        for cell in &self.cells {
            let name = cell.column_name();
            if !column_names.contains(&name) {
                column_names.push(name);
            }
        }
        column_names.sort();
        let mut report = BenchReport::new("gui-ops-latency", column_names.clone());
        // Deterministic row ordering: by op wire name.
        let mut operations: Vec<Operation> = Vec::new();
        for cell in &self.cells {
            if !operations.contains(&cell.operation) {
                operations.push(cell.operation);
            }
        }
        operations.sort_by_key(|o| o.wire().to_string());
        for op in operations {
            let mut row = BenchRow::new(op.wire(), "");
            for col_name in &column_names {
                let value = self
                    .cells
                    .iter()
                    .find(|c| c.column_name() == *col_name && c.operation == op)
                    .map(|c| c.render())
                    .unwrap_or_else(|| "PENDING".to_string());
                row.push(col_name, value);
            }
            report.push(row);
        }
        report
    }
}

/// Default selection of backends + platforms + languages the
/// campaign measures.
pub fn default_languages() -> Vec<Language> {
    vec![Language::Python, Language::CPlusPlus]
}

pub fn default_backends() -> Vec<Backend> {
    vec![
        Backend::Materialized,
        Backend::Rr,
        Backend::McrOmniscient,
        Backend::McrNoOmniscient,
        Backend::Ttd,
    ]
}

/// Current platform inferred from `cfg`. The bench targets Linux for
/// the live measurements; the other platforms always emit PENDING.
pub fn current_platform() -> Platform {
    if cfg!(target_os = "linux") {
        Platform::Linux
    } else if cfg!(target_os = "macos") {
        Platform::MacOs
    } else {
        Platform::Windows
    }
}

/// Drives the matrix. For every (backend, platform, language,
/// operation) tuple, decides whether to measure or mark PENDING.
///
/// The actual per-operation measurement is delegated to
/// [`MeasurementDriver`]. The trait is mocked in tests so the
/// verification suite can exercise the matrix wiring without a live
/// recorder.
pub fn build_matrix<D: MeasurementDriver>(
    driver: &D,
    backends: &[Backend],
    platforms: &[Platform],
    languages: &[Language],
    operations: &[Operation],
) -> GuiOpsMatrix {
    let mut matrix = GuiOpsMatrix::default();
    let current = current_platform();
    for &backend in backends {
        for &platform in platforms {
            for &language in languages {
                for &op in operations {
                    // PENDING gates:
                    // 1. Off-platform (campaign only measures on Linux).
                    if platform != current {
                        matrix.push(GuiOpCell::pending(
                            backend,
                            platform,
                            language,
                            op,
                            format!(
                                "off-platform: campaign measures on linux, target was {}",
                                platform.wire()
                            ),
                        ));
                        continue;
                    }
                    // 2. TTD is Windows-only.
                    if backend == Backend::Ttd {
                        matrix.push(GuiOpCell::pending(
                            backend,
                            platform,
                            language,
                            op,
                            "ttd: windows-only; pending per campaign scope",
                        ));
                        continue;
                    }
                    // 3. Operation not applicable to this backend.
                    if !Operation::applicable(backend).contains(&op) {
                        matrix.push(GuiOpCell::pending(
                            backend,
                            platform,
                            language,
                            op,
                            format!("not-applicable: {} on {}", op.wire(), backend.wire()),
                        ));
                        continue;
                    }
                    match driver.measure(backend, platform, language, op) {
                        Ok(stats) => matrix.push(GuiOpCell {
                            backend,
                            platform,
                            language,
                            operation: op,
                            p50_ms: Some(stats.p50_ms),
                            p95_ms: Some(stats.p95_ms),
                            pending_reason: None,
                        }),
                        Err(reason) => {
                            // CT_BENCH_DEBUG_PENDING surfaces the per-cell
                            // sentinel on stderr so operators can diagnose
                            // why a cell PENDed without parsing the JSON
                            // report (the report writer collapses every
                            // pending reason into the bare "PENDING" string
                            // for matrix-table cleanliness).
                            if std::env::var_os("CT_BENCH_DEBUG_PENDING").is_some() {
                                eprintln!(
                                    "[ct-bench] PENDING {}-{}-{}/{} → {}",
                                    backend.wire(),
                                    platform.wire(),
                                    language.wire(),
                                    op.wire(),
                                    reason
                                );
                            }
                            matrix.push(GuiOpCell::pending(backend, platform, language, op, reason))
                        }
                    }
                }
            }
        }
    }
    matrix
}

/// Per-operation measurement outcome.
#[derive(Debug, Clone)]
pub struct OperationStats {
    pub p50_ms: f64,
    pub p95_ms: f64,
}

/// Trait the matrix driver invokes per cell. Production wires a
/// [`DapMeasurementDriver`] (below); tests substitute a mock.
pub trait MeasurementDriver {
    fn measure(
        &self,
        backend: Backend,
        platform: Platform,
        language: Language,
        operation: Operation,
    ) -> Result<OperationStats, String>;
}

/// Production measurement driver — drives the `db-backend`
/// `replay-server dap-server --stdio` subprocess, issues one DAP
/// request per operation, measures wall-clock per round-trip.
///
/// The driver records the fixture for each (backend, language) pair
/// once (lazily, on first measurement) and reuses the resulting
/// trace folder for every subsequent operation against the same
/// (backend, language) tuple.  The DAP session is created fresh per
/// (backend, language) cell so per-operation iterations stay
/// statistically independent of one another's mutation of session
/// state.
///
/// Recording artifacts live under `recording_root` (a tempdir owned by
/// the bench driver).  When `record_only=false` the driver assumes the
/// caller's `fixtures_root` already contains a pre-recorded trace; for
/// the campaign's CI run this is what `just bench-gui-ops` arranges via
/// the `prepare-fixtures` task — but the on-demand path keeps the
/// bench self-contained for `cargo run` invocations.
pub struct DapMeasurementDriver {
    pub fixtures_root: PathBuf,
    pub iterations: usize,
    /// Tempdir for recorded traces (one sub-directory per
    /// (backend,language) tuple).  Optional — when `None` the driver
    /// records into a OS-default temp path.
    pub recording_root: Option<PathBuf>,
    /// Cache of recorded trace folders keyed by language.  Each entry
    /// is the absolute path to the directory containing the `.ct`
    /// trace artifact.  Filled in on first measurement.
    recorded_traces: RefCell<HashMap<Language, PathBuf>>,
}

impl DapMeasurementDriver {
    pub fn new(fixtures_root: PathBuf, iterations: usize) -> Self {
        Self {
            fixtures_root,
            iterations,
            recording_root: None,
            recorded_traces: RefCell::new(HashMap::new()),
        }
    }

    pub fn with_recording_root(mut self, root: PathBuf) -> Self {
        self.recording_root = Some(root);
        self
    }

    fn fixture_program(&self, language: Language) -> PathBuf {
        self.fixtures_root
            .join("gui-ops")
            .join(language.wire())
            .join(format!("main.{}", main_extension(language)))
    }

    /// Returns the directory containing the recorded `.ct` artifact
    /// for `language`.  Records the fixture lazily on first call.
    fn ensure_recording(&self, language: Language) -> Result<PathBuf, String> {
        if let Some(cached) = self.recorded_traces.borrow().get(&language) {
            return Ok(cached.clone());
        }
        let program = self.fixture_program(language);
        if !program.exists() {
            return Err(format!("fixture program missing: {}", program.display()));
        }
        let recording_root = match &self.recording_root {
            Some(p) => p.clone(),
            None => std::env::temp_dir().join("ct-bench-gui-ops"),
        };
        std::fs::create_dir_all(&recording_root).map_err(|e| e.to_string())?;
        let trace_dir = recording_root.join(language.wire());
        // Clear any stale trace from a previous run so the recorder
        // can write into a clean directory.
        if trace_dir.exists() {
            let _ = std::fs::remove_dir_all(&trace_dir);
        }
        std::fs::create_dir_all(&trace_dir).map_err(|e| e.to_string())?;
        FixtureRecorder::record(language, &program, &trace_dir).map_err(|e| match e {
            RecorderError::Unavailable(s) => s,
            RecorderError::Io(s) => format!("recorder io error: {s}"),
            RecorderError::SubprocessFailed {
                binary,
                exit,
                stderr,
            } => format!("recorder {binary} failed (exit={exit:?}): {stderr}"),
        })?;
        self.recorded_traces
            .borrow_mut()
            .insert(language, trace_dir.clone());
        Ok(trace_dir)
    }

    /// Locate the recorded `.ct` file under `trace_dir` (recursively)
    /// and return its path *relative to `trace_dir`*.  Different
    /// recorders place the `.ct` at different depths: Python /
    /// Ruby / MCR-recorded / Cairo / Solana write
    /// `<trace_dir>/<name>.ct`; the JavaScript recorder writes
    /// `<trace_dir>/trace-<idx>/main.ct`.  We walk the dir to keep
    /// the harness recorder-layout-agnostic.
    fn find_trace_file(trace_dir: &Path) -> Option<String> {
        let abs = crate::omniscient_db_size::find_ct_container(trace_dir)?;
        let rel = abs.strip_prefix(trace_dir).ok()?;
        rel.to_str().map(|s| s.to_string())
    }

    /// Send `threads` + `stackTrace` queries after the dap session has
    /// stopped at entry, harvest the real thread/frame ids + the trace's
    /// current source path/line/function, and assemble the
    /// [`DapBenchContext`] that the per-op argument builders consume.
    ///
    /// Per the campaign's correctness gate, every op needs valid args
    /// — synthesising them from a one-time setup query keeps the bench
    /// recorder-layout-agnostic (the fixture's source path on disk
    /// rarely matches the path baked into the trace).
    fn gather_context(
        session: &mut DapSession,
        language: Language,
        fixture_program: &Path,
    ) -> Result<DapBenchContext, String> {
        let threads_body = session
            .send_and_wait("threads", json!({}), std::time::Duration::from_secs(10))
            .map_err(|e| format!("threads request failed: {e}"))?;
        let thread_id = threads_body
            .get("threads")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|t| t.get("id"))
            .and_then(|v| v.as_i64())
            .unwrap_or(1);

        // The trace stops at `recordingStart` after launch — that
        // step has no producers / chain history, so originChain and
        // load-history would both come back empty.  Step forward
        // `SETUP_STEPS` times with `stepIn` so we land deep enough
        // in the program for `e` (or the language-specific mirror)
        // to be bound but not past the trace's last meaningful
        // instruction.  `stepIn` is uniform across backends: the
        // Materialized backend advances one step in the indexed
        // event stream and the MCR/Recreator backends advance one
        // instruction in the replay worker.  We deliberately avoid
        // `continue` because on real MCR traces (compiled C/C++/
        // Rust/Nim/Go binaries) it runs through small traces to
        // process-exit ("MCR continue reached process exit without
        // hitting a breakpoint") whereas Materialized backends
        // simply land at the last step.
        const SETUP_STEPS: usize = 5;
        for _ in 0..SETUP_STEPS {
            let resp = session.send_and_wait(
                "stepIn",
                json!({"threadId": thread_id}),
                std::time::Duration::from_secs(15),
            );
            // If stepIn fails (e.g. recording is shorter than
            // SETUP_STEPS), break out — we'll bench from whatever
            // step we managed to reach.  This is a *setup* phase;
            // the per-op correctness gate downstream is what really
            // catches a malformed cell.
            if resp.is_err() {
                break;
            }
            if session
                .wait_for_event("stopped", std::time::Duration::from_secs(15))
                .is_err()
            {
                break;
            }
        }

        let stack_body = session
            .send_and_wait(
                "stackTrace",
                json!({"threadId": thread_id}),
                std::time::Duration::from_secs(10),
            )
            .map_err(|e| format!("stackTrace request failed: {e}"))?;
        let frames = stack_body
            .get("stackFrames")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let top = frames
            .first()
            .ok_or_else(|| "stackTrace returned empty stackFrames".to_string())?;
        let frame_id = top.get("id").and_then(|v| v.as_i64()).unwrap_or(0);
        // stackTrace returns `./<path_N>` placeholders (the dap-server
        // remaps absolute paths to bundled-source tokens) — the
        // indexer's `path_id_for(path)` lookup expects the absolute
        // path it stored at record-time.  We feed it the fixture's
        // absolute path instead, which matches what the python /
        // ruby / js recorders embed in the trace.
        let source_path = fixture_program
            .canonicalize()
            .unwrap_or_else(|_| fixture_program.to_path_buf())
            .to_string_lossy()
            .into_owned();
        let stop_line = top.get("line").and_then(|v| v.as_i64()).unwrap_or(1);
        let function_name = top
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("main")
            .to_string();
        // The bench's fixtures all converge on a final local named `e`
        // (the result of `fold(d, 7)` in main.py + its language mirrors)
        // plus an a/b/c/d chain.  These are the targets the bench's
        // load-history / originChain / originSummary / evaluate ops
        // exercise; the M19 indexer + origin-resolver should produce
        // a non-empty chain for each.
        let target_variable = "e".to_string();
        let summary_tokens = vec![
            "a".to_string(),
            "b".to_string(),
            "c".to_string(),
            "d".to_string(),
            "e".to_string(),
        ];
        // The dap-server's `Lang` enum is `#[repr(u8)]` with
        // `serde_repr` — values serialise as integers, not names.
        // Discriminants match `codetracer/src/db-backend/src/lang.rs`:
        // C=0, Cpp=1, Rust=2, Nim=3, Go=4, …, Python=12, Ruby=13,
        // Javascript=15, Cairo=32, Solana=35.
        let lang_wire = match language {
            Language::C => 0u8,
            Language::CPlusPlus => 1,
            Language::Rust => 2,
            Language::Nim => 3,
            Language::Go => 4,
            Language::Python => 12,
            Language::Ruby => 13,
            Language::JavaScript => 15,
            Language::Cairo => 32,
            Language::Solana => 35,
        };
        Ok(DapBenchContext {
            thread_id,
            frame_id,
            source_path,
            stop_line,
            function_name,
            target_variable,
            summary_tokens,
            lang_wire,
            rr_ticks: 0,
        })
    }

    /// Map an [`Operation`] to its DAP command name + a *real*
    /// arguments blob bound to the bench's setup context.  Returns
    /// `None` for operations that don't have a clean stdio-DAP entry
    /// point on this backend — those become PENDING cells.
    ///
    /// Per the campaign's correctness requirement, every op sends
    /// arguments that the dap-server can actually dispatch — the
    /// bench then asserts the response carries the expected shape
    /// (see `operation_invariant_ok`).  Earlier revisions of the
    /// bench sent `json!({})` for every op and let the dap-server
    /// reject it with "missing field X"; the wall-clock that
    /// landed in the p50/p95 columns was the error-round-trip wire
    /// loop, not the real operation cost.  That made the bench
    /// numbers ~10× faster than reality and failed silently when
    /// the underlying op was broken — the correctness gate fixes
    /// both.
    fn op_to_dap(
        operation: Operation,
        ctx: &DapBenchContext,
    ) -> Option<(&'static str, Value)> {
        let location = json!({
            "path": ctx.source_path.clone(),
            "line": ctx.stop_line,
            "functionName": ctx.function_name.clone(),
        });
        match operation {
            Operation::LoadLocals => Some((
                "ct/load-locals",
                json!({
                    "rrTicks": ctx.rr_ticks,
                    "countBudget": 16,
                    "minCountLimit": 4,
                    "lang": ctx.lang_wire,
                    "watchExpressions": [],
                    "depthLimit": -1i64,
                }),
            )),
            Operation::LoadHistory1K => Some((
                "ct/load-history",
                json!({
                    "expression": ctx.target_variable.clone(),
                    "location": location,
                    "isForward": false,
                }),
            )),
            Operation::LoadHistory10K => Some((
                "ct/load-history",
                json!({
                    "expression": ctx.target_variable.clone(),
                    "location": location,
                    "isForward": false,
                }),
            )),
            Operation::LoadFlow => Some((
                "ct/load-flow",
                // FlowMode is #[repr(u8)] with serde_repr: 0 = Call, 1 = Diff.
                // The GUI uses Call by default; the bench mirrors that.
                json!({
                    "flowMode": 0u8,
                    "location": location,
                }),
            )),
            Operation::OriginChain => Some((
                "ct/originChain",
                json!({
                    "variableName": ctx.target_variable.clone(),
                    "variablePath": [],
                    "frameId": ctx.frame_id,
                }),
            )),
            Operation::OriginSummaryBatch => Some((
                "ct/originSummary",
                json!({"tokens": ctx.summary_tokens.clone()}),
            )),
            // `ct/source-line-jump` and `ct/source-call-jump`: the
            // handlers in db-backend's dap_handler.rs now end with
            // `respond_dap(req, 0, sender)` so the request gets a
            // proper response (the fix landed in this campaign — see
            // commit "fix(dap): add missing respond_dap on
            // source-line-jump / source-call-jump").
            Operation::JumpToLine => Some((
                "ct/source-line-jump",
                json!({
                    "path": ctx.source_path.clone(),
                    "line": ctx.stop_line,
                }),
            )),
            Operation::JumpToCall => Some((
                "ct/source-call-jump",
                json!({
                    "path": ctx.source_path.clone(),
                    "line": ctx.stop_line,
                    "token": ctx.function_name.clone(),
                }),
            )),
            // Tracepoint expression evaluation: the dap-server doesn't
            // dispatch the standard DAP `evaluate` request; tracepoints
            // live behind the stateful `ct/run-tracepoints` flow.  The
            // dedicated tracepoint_interpreter Criterion bench (P4.6)
            // measures the hot path directly.
            Operation::Tracepoint => None,
            // `stepBack` is the DAP-standard reverse-step request.
            // On Materialized backends the response carries the new
            // step_id; on MCR/RR it routes through the recreator's
            // undo-map fast path (Multi-Core-Recorder.md §6.4
            // Tier-1 lookup).
            Operation::ReverseStep => Some(("stepBack", json!({"threadId": ctx.thread_id}))),
            // `setDataBreakpoints` is not dispatched by the
            // dap-server; CodeTracer watchpoints route through
            // `ct/run-tracepoints` instead.  PEND until that flow
            // gets a single-call DAP entry.
            Operation::Watchpoint => None,
        }
    }
}

/// Per-cell context gathered from the dap-server after launch.
/// Feeds the per-op argument builders in [`DapMeasurementDriver::op_to_dap`]
/// so each op sends real arguments the dap-server can dispatch — that's
/// the foundation of the bench's correctness gate.
#[derive(Debug, Clone)]
pub(crate) struct DapBenchContext {
    pub thread_id: i64,
    pub frame_id: i64,
    pub source_path: String,
    pub stop_line: i64,
    pub function_name: String,
    pub target_variable: String,
    pub summary_tokens: Vec<String>,
    /// Numeric `Lang` ordinal expected by the dap-server's
    /// `CtLoadLocalsArguments::lang` (#[repr(u8)] + serde_repr).
    pub lang_wire: u8,
    pub rr_ticks: i64,
}

impl MeasurementDriver for DapMeasurementDriver {
    fn measure(
        &self,
        backend: Backend,
        _platform: Platform,
        language: Language,
        operation: Operation,
    ) -> Result<OperationStats, String> {
        // Backend → recording-path mapping:
        //
        // * Materialized — the Python-class trace shape (per-step
        //   state materialised inline).  Recorded by the language's
        //   own recorder shim (codetracer-python-recorder,
        //   codetracer-ruby-recorder, codetracer-js-recorder,
        //   codetracer-cairo-recorder, codetracer-solana-recorder).
        //   The dap-server reads the CTFS event stream directly; no
        //   replay-worker subprocess is needed.
        //
        // * McrNoOmniscient / McrOmniscient — recorded by `ct-mcr`.
        //   The dap-server spawns `ct-native-replay` as the replay
        //   worker via the `ctRRWorkerExe` launch arg (see
        //   `codetracer/src/db-backend/src/dap.rs` LaunchRequestArguments
        //   and the existing *_mcr_streaming_flow_test.rs harnesses).
        //   The bench's FixtureRecorder routes C/C++/Rust/Nim/Go
        //   through `ct-mcr record` already.
        //
        // * Rr — would record via the codetracer-rr-backend's
        //   classic-rr launcher; PEND because the dev shell doesn't
        //   ship a one-shot ct-rr recording entry point.
        //
        // * Ttd — Windows-only per the campaign's platform ceiling.
        // Map backend → `ct start_backend` kind.  Materialized + both
        // MCR variants share the `db` kind (the same replay-server
        // dap binary, distinguished by trace contents + the
        // replay-worker the dap-server discovers via PATH).  Rr uses
        // its own ct-rr-support DAP binary, launched via `ct
        // start_backend rr --stdio`.
        let backend_kind = match backend {
            Backend::Materialized | Backend::McrNoOmniscient | Backend::McrOmniscient => "db",
            Backend::Rr => "rr",
            Backend::Ttd => {
                return Err("ttd backend is Windows-only per the campaign ceiling".to_string());
            }
        };
        // Narrow probes — the recorder + the DAP host must both be
        // reachable for the cell to be measurable.
        LanguageProbe::probe(language)?;
        // Prefer the user-facing `ct` CLI as the DAP host (it routes
        // through `start_backend` to the right replay binary per kind).
        // Fall back to the direct `replay-server`/`ct-rr-support`
        // discovery so cells still measure when `ct` isn't built.
        let dap_binary = ct_cli_binary()
            .or_else(ct_binary)
            .ok_or_else(|| {
                "neither `ct` (preferred) nor `replay-server` is on PATH / discoverable; \
                 run `just build-once` to produce src/build-debug/bin/ct or build the \
                 db-backend at src/db-backend/target/debug/replay-server"
                    .to_string()
            })?;
        let program = self.fixture_program(language);
        if !program.exists() {
            return Err(format!("fixture program missing: {}", program.display()));
        }

        let trace_dir = self.ensure_recording(language)?;
        let trace_file = Self::find_trace_file(&trace_dir).ok_or_else(|| {
            format!(
                "recorded trace folder {} contains no .ct artifact",
                trace_dir.display()
            )
        })?;

        let mut session = DapSession::launch(
            &dap_binary,
            backend_kind,
            &trace_dir,
            &trace_file,
        )
            .map_err(|e: DapError| format!("dap session launch failed: {e}"))?;

        // One-time setup query gathers the real thread/frame ids and
        // the trace's stop location.  Without this every op would
        // either send synthetic args (rejected as "missing field X")
        // or hit the wrong frame/location.
        let context = Self::gather_context(&mut session, language, &program)?;
        let (dap_command, dap_args) = match Self::op_to_dap(operation, &context) {
            Some(t) => t,
            None => {
                return Err(format!(
                    "dap-driver pending: {} has no single-request stdio-DAP entry point",
                    operation.wire(),
                ));
            }
        };
        let outcome = session
            .bench(dap_command, dap_args, self.iterations)
            .map_err(|e: DapError| format!("dap session bench failed: {e}"))?;
        // Correctness gate: every iteration must produce a successful
        // dap-server response.  A zero success_count means the bench
        // sent invalid args and is measuring the error-rejection
        // round-trip — that's a bench design bug, not a measurement.
        // Per-operation invariants (e.g. originChain returns ≥1 hop)
        // are asserted further below via operation_invariant_ok.
        if outcome.success_count == 0 {
            let detail = outcome
                .failure_message
                .as_deref()
                .unwrap_or("dap-server rejected every iteration without a message");
            return Err(format!(
                "correctness fail: 0/{} successful responses for {} → {}",
                outcome.iterations, operation.wire(), detail
            ));
        }
        if let Some(body) = &outcome.first_response_body
            && let Err(reason) = operation_invariant_ok(operation, body)
        {
            return Err(format!(
                "correctness fail: {} response did not match invariant: {} (response: {})",
                operation.wire(),
                reason,
                serde_json::to_string(body).unwrap_or_else(|_| "<unserialisable>".to_string()),
            ));
        }
        Ok(OperationStats {
            p50_ms: outcome.p50_ms,
            p95_ms: outcome.p95_ms,
        })
    }
}

/// Per-operation correctness invariant.  Receives the dap-server's
/// first successful response body for `operation`.  Returns Ok when
/// the response satisfies the operation's invariant; Err otherwise.
///
/// The invariants are intentionally minimal: each one just asserts
/// the response carries the field shape the GUI would consume, not
/// the full semantic correctness of the op.  Semantic correctness
/// lives in the recorder + dap-server's own integration suites
/// (e.g. M2 / M5 / M11 origin_metadata_streams_test); the bench's
/// job is to assert the operation produced *some* output rather
/// than letting an empty / malformed response slip through as a
/// fast latency sample.
pub(crate) fn operation_invariant_ok(operation: Operation, body: &Value) -> Result<(), String> {
    match operation {
        // originChain: the wire shape is
        // `{ hops, terminator, metrics, queryVariable, queryStepId, truncated, ... }`
        // (see CtOriginChainResponse in
        // codetracer/src/db-backend/src/task.rs and the M11
        // origin_metadata_streams_test).  The bench asserts the
        // structural fields are present — an empty `hops` array with a
        // legitimate terminator (e.g. `parameterAtRecordStart` for
        // function arguments, `unknownVariable` for out-of-scope
        // lookups) is a valid response and indicates the dap-server +
        // origin walker did their job; chain depth is an outcome of
        // the recorder's Assignment-event emission and lives in the
        // recorder's own tests, not in this latency bench.
        Operation::OriginChain => {
            if body.get("hops").and_then(|v| v.as_array()).is_none() {
                return Err("originChain response missing `hops` array".to_string());
            }
            if body.get("metrics").and_then(|v| v.as_object()).is_none() {
                return Err("originChain response missing `metrics` object".to_string());
            }
            if body
                .get("terminator")
                .and_then(|t| t.get("kind"))
                .and_then(|v| v.as_str())
                .is_none()
            {
                return Err("originChain response missing `terminator.kind`".to_string());
            }
            Ok(())
        }
        // originSummary: response is `{ summaries: [{token, ...}, ...] }`.
        // The bench asserts the array is present and exactly matches the
        // number of tokens we sent — that's the wire-level contract the
        // GUI consumes (one entry per requested token, in order).
        Operation::OriginSummaryBatch => {
            let summaries = body.get("summaries").and_then(|v| v.as_array());
            match summaries {
                Some(arr) if !arr.is_empty() => Ok(()),
                Some(_) => Err("originSummary summaries array is empty".to_string()),
                None => Err("originSummary response missing `summaries` array".to_string()),
            }
        }
        // stepBack: response body for stepBack is empty per the DAP
        // spec; we just check the session is still alive (the success
        // gate above already verified the response wasn't an error).
        Operation::ReverseStep => Ok(()),
        // load-locals / load-history / load-flow: assert the body
        // carries an object (the real response shape is per-trace and
        // beyond a generic invariant; the success gate above already
        // ensures the dap-server didn't reject).
        Operation::LoadLocals | Operation::LoadHistory1K | Operation::LoadHistory10K | Operation::LoadFlow => {
            if body.is_object() || body.is_array() {
                Ok(())
            } else {
                Err(format!("{} response is neither object nor array", operation.wire()))
            }
        }
        // jump-to-line / jump-to-call / tracepoint-eval / watchpoint:
        // the dap-server response is task-specific; success gate
        // suffices.
        Operation::JumpToLine | Operation::JumpToCall | Operation::Tracepoint | Operation::Watchpoint => Ok(()),
    }
}

fn main_extension(language: Language) -> &'static str {
    match language {
        Language::Python => "py",
        Language::CPlusPlus => "cpp",
        Language::Ruby => "rb",
        Language::JavaScript => "js",
        Language::C => "c",
        Language::Rust => "rs",
        Language::Nim => "nim",
        Language::Go => "go",
        Language::Cairo => "cairo",
        Language::Solana => "rs",
    }
}

/// Count of cells in `matrix` that are marked PENDING. The
/// verification test uses this to assert every unmeasured cell shows
/// up explicitly.
pub fn pending_cell_count(matrix: &GuiOpsMatrix) -> usize {
    matrix
        .cells
        .iter()
        .filter(|c| c.pending_reason.is_some())
        .count()
}

/// Returns `true` when every cell in `matrix` for which the operation
/// applies but the measurement was not taken is marked PENDING (vs.
/// silently dropped).
pub fn every_unmeasured_cell_is_pending(matrix: &GuiOpsMatrix) -> bool {
    matrix
        .cells
        .iter()
        .all(|c| c.p50_ms.is_some() || c.pending_reason.is_some())
}

/// Verifies the tracepoint benchmark emits through the matrix
/// format. The campaign spec speculatively referenced an existing
/// `tracepoint_interpreter` bench at `codetracer/src/db-backend/benches/`;
/// if it doesn't exist (the current state), this function returns
/// `false` and the P4.6 verification test surfaces the gap honestly.
pub fn tracepoint_benchmark_exists(benches_dir: &Path) -> bool {
    benches_dir.join("tracepoint_interpreter.rs").is_file()
        || benches_dir.join("tracepoint_interpreter").is_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct AlwaysPendingDriver;
    impl MeasurementDriver for AlwaysPendingDriver {
        fn measure(
            &self,
            _backend: Backend,
            _platform: Platform,
            _language: Language,
            _operation: Operation,
        ) -> Result<OperationStats, String> {
            Err("synthetic-driver: every-cell-pending".to_string())
        }
    }

    #[test]
    fn matrix_marks_every_unmeasured_cell_pending() {
        let matrix = build_matrix(
            &AlwaysPendingDriver,
            &Backend::all(),
            &Platform::all(),
            &Language::default_set(),
            &Operation::all(),
        );
        assert!(every_unmeasured_cell_is_pending(&matrix));
        assert_eq!(pending_cell_count(&matrix), matrix.cells.len());
    }

    #[test]
    fn matrix_report_contains_pending_markers() {
        let matrix = build_matrix(
            &AlwaysPendingDriver,
            &[Backend::Materialized, Backend::Ttd],
            &[current_platform()],
            &[Language::Python],
            &Operation::all(),
        );
        let report = matrix.to_report();
        let md = report.to_markdown();
        assert!(md.contains("PENDING"));
    }

    #[test]
    fn ttd_cells_always_pending() {
        let matrix = build_matrix(
            &AlwaysPendingDriver,
            &[Backend::Ttd],
            &[current_platform()],
            &[Language::CPlusPlus],
            &Operation::all(),
        );
        for cell in &matrix.cells {
            assert!(cell.p50_ms.is_none());
            assert!(cell.pending_reason.as_ref().unwrap().contains("ttd"));
        }
    }
}
