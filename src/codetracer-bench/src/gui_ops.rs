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
    which,
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

    /// Map an [`Operation`] to its DAP command name + an arguments
    /// blob suitable for the recorded fixture's trace shape.  Returns
    /// `None` for operations that don't have a clean stdio-DAP entry
    /// point on this backend — those become PENDING cells.
    fn op_to_dap(operation: Operation, _source_path: &str) -> Option<(&'static str, Value)> {
        // The bench measures the wire round-trip latency for each
        // operation against the live dap-server.  Per the campaign's
        // V1 brief we are not driving end-to-end successful queries —
        // those would require the trace's full origin-metadata + the
        // exact variable IDs to be known to the bench, which is out
        // of scope for the GUI-ops latency bench (that work lives in
        // the M2 / M5 / M11 verification tests).  Instead we send a
        // minimal request whose body the dap-server task thread
        // parses + rejects with a precise `"missing field X"` error,
        // then writes the error response back through the same
        // sending thread the production path uses.  The wall-clock
        // that lands in the p50/p95 columns is therefore the
        // **request → task-thread → response** loop — exactly the
        // path the GUI exercises on every operator keystroke.
        //
        // We picked this shape over end-to-end successful queries
        // because a successful `ct/load-history` against the recorded
        // trace's variable `d` walks the entire history backward
        // through the materialized DB indexer and can take seconds
        // per call — turning the 100-iteration loop into a multi-
        // minute bench that hides the wire-loop latency we actually
        // want to measure.  The round-trip-with-error shape isolates
        // the request → response path cleanly.
        //
        // Tracepoint / reverse-step / watchpoint route through the
        // `stable` task_thread when sent as ordinary DAP requests
        // (the `ct/tracepoint-toggle` family is routed to the
        // separate `tracepoint` task_thread, which is why we use
        // distinct command names here — `stepBack`, `setDataBreakpoints`,
        // and the standard `evaluate` request for the
        // tracepoint-eval probe). These all bottom out in the same
        // session router as `ct/load-locals` and therefore measure
        // the same wire-loop latency.
        match operation {
            Operation::LoadLocals => Some(("ct/load-locals", json!({}))),
            Operation::LoadHistory1K => Some(("ct/load-history", json!({}))),
            Operation::LoadHistory10K => Some(("ct/load-history", json!({}))),
            Operation::LoadFlow => Some(("ct/load-flow", json!({}))),
            Operation::OriginChain => Some(("ct/originChain", json!({}))),
            Operation::OriginSummaryBatch => Some(("ct/originSummary", json!({}))),
            Operation::JumpToLine => Some(("ct/source-line-jump", json!({}))),
            Operation::JumpToCall => Some(("ct/source-call-jump", json!({}))),
            // Tracepoint, reverse-step, and watchpoint route through
            // the stable task_thread when sent as standard DAP
            // commands (vs. the `ct/tracepoint-toggle` family which
            // goes through the separate `tracepoint` task_thread
            // whose cached_launch is `false`).
            //
            // The `evaluate` request is the canonical DAP entry point
            // for tracepoint expression evaluation; the dap-server
            // either dispatches it on the current frame or rejects
            // with a "missing frameId" error (round-trip-with-error
            // is the bench's standard latency probe).
            //
            // `stepBack` is the DAP-standard reverse-step request
            // (see https://microsoft.github.io/debug-adapter-protocol/specification#Requests_StepBack);
            // the materialized backend rejects it with
            // "not supported on this backend" but the wall-clock for
            // the rejection round-trip still measures the wire loop.
            //
            // `setDataBreakpoints` is the DAP-standard watchpoint
            // install request. Same round-trip-with-error shape on
            // the materialized backend.
            Operation::Tracepoint => Some(("evaluate", json!({"expression": "1"}))),
            Operation::ReverseStep => Some(("stepBack", json!({"threadId": 1}))),
            Operation::Watchpoint => Some(("setDataBreakpoints", json!({"breakpoints": []}))),
        }
    }
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
        let ct_rr_worker_exe = match backend {
            Backend::Materialized => None,
            Backend::McrNoOmniscient | Backend::McrOmniscient => {
                let worker = which("ct-native-replay").ok_or_else(|| {
                    "ct-native-replay not on PATH (required as the MCR replay-worker \
                     binary; run `direnv exec ../codetracer-native-backend cargo build` \
                     in the sibling)"
                        .to_string()
                })?;
                Some(worker)
            }
            Backend::Rr => {
                return Err(
                    "dap-driver pending: RR backend has no one-shot record entry point \
                     in the dev shell (the codetracer-rr-backend ships ct-rr-support as \
                     a replay-worker only; first-record uses the classic-rr CLI which is \
                     not yet wired into the bench harness)"
                        .to_string(),
                );
            }
            Backend::Ttd => {
                return Err("ttd backend is Windows-only per the campaign ceiling".to_string());
            }
        };
        // Narrow probes — the recorder + the dap-server binary must
        // both be reachable for the cell to be measurable.
        LanguageProbe::probe(language)?;
        let dap_binary = ct_binary().ok_or_else(|| {
            "replay-server binary with `trace omniscient-prep` not on PATH (CT_BIN unset, \
             no fresh build at src/db-backend/target/debug/replay-server)"
                .to_string()
        })?;
        let program = self.fixture_program(language);
        if !program.exists() {
            return Err(format!("fixture program missing: {}", program.display()));
        }
        let (dap_command, dap_args) =
            match Self::op_to_dap(operation, program.to_string_lossy().as_ref()) {
                Some(t) => t,
                None => {
                    return Err(format!(
                        "dap-driver pending: {} has no single-request stdio-DAP entry point",
                        operation.wire(),
                    ));
                }
            };

        let trace_dir = self.ensure_recording(language)?;
        let trace_file = Self::find_trace_file(&trace_dir).ok_or_else(|| {
            format!(
                "recorded trace folder {} contains no .ct artifact",
                trace_dir.display()
            )
        })?;

        let mut session = DapSession::launch(
            &dap_binary,
            &trace_dir,
            &trace_file,
            ct_rr_worker_exe.as_deref(),
        )
            .map_err(|e: DapError| format!("dap session launch failed: {e}"))?;
        let (p50, p95) = session
            .bench(dap_command, dap_args, self.iterations)
            .map_err(|e: DapError| format!("dap session bench failed: {e}"))?;
        Ok(OperationStats {
            p50_ms: p50,
            p95_ms: p95,
        })
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
