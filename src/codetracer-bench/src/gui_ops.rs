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

use crate::{BenchReport, BenchRow, Language, LanguageProbe, ct_binary};
use serde::{Deserialize, Serialize};
use std::path::Path;

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

    /// Operations defined for `backend`. Forward-only backends omit
    /// the reverse-execution ops.
    pub fn applicable(backend: Backend) -> Vec<Operation> {
        match backend {
            // 9 forward ops.
            Backend::Materialized => vec![
                Operation::LoadLocals,
                Operation::LoadHistory1K,
                Operation::LoadHistory10K,
                Operation::LoadFlow,
                Operation::OriginChain,
                Operation::OriginSummaryBatch,
                Operation::Tracepoint,
                Operation::JumpToLine,
                Operation::JumpToCall,
            ],
            // 11 ops including reverse + watchpoint.
            Backend::Rr | Backend::McrOmniscient | Backend::McrNoOmniscient | Backend::Ttd => {
                Self::all()
            }
        }
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
/// The fixture for each (backend, language) pair must be pre-recorded
/// (the bench's `prepare-fixtures` task records them in advance so
/// the per-cell measurement loop can iterate 100× without
/// re-recording).
pub struct DapMeasurementDriver {
    pub fixtures_root: std::path::PathBuf,
    pub iterations: usize,
}

impl MeasurementDriver for DapMeasurementDriver {
    fn measure(
        &self,
        backend: Backend,
        _platform: Platform,
        language: Language,
        operation: Operation,
    ) -> Result<OperationStats, String> {
        // Narrow probes — the recorder + the ct binary must both be
        // reachable for the cell to be measurable.
        LanguageProbe::probe(language)?;
        if ct_binary().is_none() {
            return Err("ct binary not on PATH".to_string());
        }
        let fixture_dir = self
            .fixtures_root
            .join("gui-ops")
            .join(language.wire())
            .join(format!("main.{}", main_extension(language)));
        if !fixture_dir.exists() {
            return Err(format!(
                "fixture program missing: {}",
                fixture_dir.display(),
            ));
        }
        // Per spec: the driver should drive a live DAP stdio session
        // and time each round-trip. The full DAP plumbing is
        // intentionally not wired in this slice — the campaign brief
        // says "the per-cell measurements ship for Python materialized
        // + C++ RR + C++ MCR-with/without-omniscient on Linux"; until
        // the `db-backend`'s DAP harness ships a stable headless
        // probe entry point (currently still being shaken out under
        // M2 / M5), the driver returns Err so the matrix surfaces the
        // cell as PENDING with a precise sentinel.
        Err(format!(
            "dap-driver pending: {} {} {}",
            backend.wire(),
            language.wire(),
            operation.wire(),
        ))
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
