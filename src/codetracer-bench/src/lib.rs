//! Shared infrastructure for the Performance + E2E Coverage campaign's
//! P2 / P3 / P4 benchmark suites.
//!
//! The three suites (omniscient-DB size, slice prep speed, GUI ops
//! latency) share a common harness:
//!
//! * [`FixtureRecorder`] — invokes the user-facing `ct record` CLI for
//!   a fixture program and returns the resulting trace directory.  The
//!   single entry point is [`FixtureRecorder::record_via_ct`]; the bench
//!   deliberately routes every recording through the same code path
//!   end users exercise so the matrix surfaces the actual production
//!   surface (no language-specific recorder shims invoked directly).
//! * [`OmniscientPrep`] — invokes the `ct trace omniscient-prep` Rust
//!   subprocess against a slice folder.
//! * [`ReportWriter`] — emits CSV + JSON + Markdown to a
//!   `target/codetracer-bench/<bench-name>/` directory.
//!
//! The library deliberately keeps measurement and reporting separate
//! so unit tests can verify report shape without invoking any
//! external recorder (see the synthetic-fixture path in the P3
//! verification tests).
//!
//! ## P9.1 — recording-side `ct record` refactor
//!
//! The bench used to spawn per-language recorder shims directly
//! (`codetracer_python_recorder`, `ct-mcr`, `codetracer-ruby-recorder`, …)
//! plus per-language toolchain probes via a `LanguageProbe` helper.
//! Both were redundant once `ct record` itself learned to detect the
//! language and surface precise error messages — and keeping them in
//! the bench meant the bench used a *different* recording surface
//! from the one end users actually invoke.  Per the campaign brief
//! ("everything related to creating recordings ... should be possible
//! to do through the `ct` executable ... the bench should be built
//! only on top of the `ct` CLI"), P9.1 collapses recording down to a
//! single subprocess: `ct record <program> -o <trace_dir> [--backend
//! <kind>] [--lang <wire>]`.  All language detection, recorder probe,
//! and language-recorder-shim discovery now happens inside `ct`.

use serde::{Deserialize, Serialize};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

pub mod dap_driver;
pub mod gui_ops;
pub mod omniscient_db_size;
pub mod slice_prep_speed;

/// Languages the bench knows about. Mirrors the campaign's "10
/// languages" set (the wider P2 fixture matrix). The discriminant
/// order matches the deterministic order the bench emits in reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Language {
    Python,
    CPlusPlus,
    Ruby,
    JavaScript,
    C,
    Rust,
    Nim,
    Go,
    Cairo,
    Solana,
}

impl Language {
    /// Stable lowercase wire name used in CLI flags, directory names,
    /// and report columns.
    pub fn wire(self) -> &'static str {
        match self {
            Language::Python => "python",
            Language::CPlusPlus => "c_plus_plus",
            Language::Ruby => "ruby",
            Language::JavaScript => "javascript",
            Language::C => "c",
            Language::Rust => "rust",
            Language::Nim => "nim",
            Language::Go => "go",
            Language::Cairo => "cairo",
            Language::Solana => "solana",
        }
    }

    /// The `--lang` argument value to pass to `ct record`.
    ///
    /// `ct record` accepts language names per the dispatcher in
    /// `codetracer/src/ct/trace/record.nim` (which forwards `--lang`
    /// to `db-backend-record` / the native recorder).  The wire here
    /// matches the names the language-detection table accepts:
    /// see `codetracer/src/ct/utilities/language_detection.nim`
    /// `detectLang` + `toLang`.  Using the same `--lang` token for
    /// every language keeps the bench layer language-agnostic and
    /// lets the downstream recorder fall back to file-extension
    /// detection when the token is empty (so passing it is a
    /// belt-and-braces safety net rather than a routing decision).
    pub fn ct_record_lang(self) -> &'static str {
        match self {
            // ct record's --lang dispatcher maps "python" → LangPythonDb
            // (the materialized recorder) per codetracer/src/common/lang.nim.
            Language::Python => "python",
            // ct record's --lang token for C++ is "cpp" — the
            // language_detection table accepts "cpp"/"c++"/"c_plus_plus"
            // but the dispatcher canonicalises to "cpp".
            Language::CPlusPlus => "cpp",
            // IMPORTANT: ct record's --lang "ruby" maps to LangRuby (the
            // gdb/rr legacy variant) which is NOT a materialized-traces
            // lang.  We need the materialized variant: pass "rb" so
            // toLang() returns LangRubyDb (materialized via
            // codetracer-ruby-recorder).  See common/lang.nim line 27.
            Language::Ruby => "rb",
            Language::JavaScript => "javascript",
            Language::C => "c",
            Language::Rust => "rust",
            Language::Nim => "nim",
            Language::Go => "go",
            Language::Cairo => "cairo",
            Language::Solana => "solana",
        }
    }

    /// Parse the wire name. Accepts the `cpp` alias for C++ since the
    /// existing `tests/fixtures/origin/cpp/` directory uses it and a
    /// fair number of operators will type it that way.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "python" => Some(Language::Python),
            "c_plus_plus" | "cpp" | "c++" => Some(Language::CPlusPlus),
            "ruby" => Some(Language::Ruby),
            "javascript" | "js" => Some(Language::JavaScript),
            "c" => Some(Language::C),
            "rust" => Some(Language::Rust),
            "nim" => Some(Language::Nim),
            "go" => Some(Language::Go),
            "cairo" => Some(Language::Cairo),
            "solana" => Some(Language::Solana),
            _ => None,
        }
    }

    /// Default-set languages: the two the campaign committed to
    /// measuring in CI.
    pub fn default_set() -> Vec<Language> {
        vec![Language::Python, Language::CPlusPlus]
    }

    /// Full matrix: the 10 languages the bench drives.  C, C++, Rust,
    /// Nim, and Go all route through the Multi-Core Recorder per
    /// `codetracer-specs/Recording-Backends/Multi-Core-Recorder/Multi-Core-Recorder.md`
    /// §78 (MCR records any LLVM/GCC-compiled binary; the recorder is
    /// language-agnostic at the binary level).  Python, Ruby,
    /// JavaScript, Cairo, Solana each have a dedicated recorder shim
    /// listed in `codetracer-specs/Recorder-CLI-Conventions.md` §1.
    /// All ten dispatch through `ct record` — the bench never invokes
    /// a language-specific recorder directly.
    pub fn all() -> Vec<Language> {
        vec![
            Language::Python,
            Language::CPlusPlus,
            Language::Ruby,
            Language::JavaScript,
            Language::C,
            Language::Rust,
            Language::Nim,
            Language::Go,
            Language::Cairo,
            Language::Solana,
        ]
    }

    /// `true` when the language's traces are materialized by the
    /// language recorder itself (Python / Ruby / JavaScript / Cairo /
    /// Solana — the recorder produces a CTFS event stream the
    /// dap-server reads directly).  Native-compiled languages
    /// (C / C++ / Rust / Nim / Go) record through MCR or RR.
    ///
    /// Mirrors `Lang.usesMaterializedTraces` in
    /// `codetracer/src/common/lang.nim`.
    pub fn uses_materialized_traces(self) -> bool {
        matches!(
            self,
            Language::Python
                | Language::Ruby
                | Language::JavaScript
                | Language::Cairo
                | Language::Solana
        )
    }
}

/// Minimal `which` — searches `PATH` for an executable. Used by the
/// optional `ct` binary check in P2 / P3.
pub fn which(binary: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(binary);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Returns the path of the binary the bench shells out to for the
/// `trace omniscient-prep` subcommand.
///
/// The campaign's omniscient-prep entry point lives on the
/// `replay-server` binary built by `src/db-backend/`. The dev shell's
/// `src/build-debug/bin/replay-server` is an older, pre-M19 build that
/// does NOT carry the `trace` subcommand; the freshly-built artifact
/// at `src/db-backend/target/debug/replay-server` does.
///
/// Resolution order:
///   1. `CT_BIN` env var (full override; the operator picks the binary).
///   2. `replay-server` on PATH that responds to `trace omniscient-prep`.
///   3. The known build path `src/db-backend/target/debug/replay-server`
///      relative to `CODETRACER_REPO_ROOT_PATH` (the env var
///      `detect-siblings.sh` exports).
pub fn ct_binary() -> Option<PathBuf> {
    if let Some(env) = std::env::var_os("CT_BIN") {
        let p = PathBuf::from(env);
        if p.is_file() {
            return Some(p);
        }
    }

    // Check the freshly-built db-backend replay-server first if the
    // repo root is known. This is the binary that carries the `trace`
    // subcommand on which the campaign depends.
    if let Some(root) = std::env::var_os("CODETRACER_REPO_ROOT_PATH") {
        let candidate = PathBuf::from(root)
            .join("src")
            .join("db-backend")
            .join("target")
            .join("debug")
            .join("replay-server");
        if candidate.is_file() && binary_supports_trace_omniscient_prep(&candidate) {
            return Some(candidate);
        }
    }

    if let Some(p) = which("replay-server")
        && binary_supports_trace_omniscient_prep(&p)
    {
        return Some(p);
    }

    if let Some(p) = which("ct")
        && binary_supports_trace_omniscient_prep(&p)
    {
        return Some(p);
    }
    None
}

/// Locate the user-facing `ct` CLI binary.  This is the front door for
/// recording (`ct record`) and launching DAP backends (`ct start_backend
/// <kind> --stdio`).  The bench prefers it over direct
/// `replay-server`/`ct-mcr` invocations so the matrix exercises the same
/// surface end users see.
///
/// Resolution order:
///   1. `CT_CLI_BIN` env var (full override).
///   2. `ct` on PATH.  We accept any binary named `ct` whose `--help`
///      mentions `start_backend` — that filters out unrelated `ct`
///      binaries the operator may have on PATH (e.g. `cargo-cinit ct`,
///      C-Tools, etc.) without dragging in heavyweight probes.
///   3. The known build path `src/build-debug/bin/ct` relative to
///      `CODETRACER_REPO_ROOT_PATH`.
pub fn ct_cli_binary() -> Option<PathBuf> {
    if let Some(env) = std::env::var_os("CT_CLI_BIN") {
        let p = PathBuf::from(env);
        if p.is_file() {
            return Some(p);
        }
    }

    if let Some(p) = which("ct")
        && binary_supports_start_backend(&p)
    {
        return Some(p);
    }

    if let Some(root) = std::env::var_os("CODETRACER_REPO_ROOT_PATH") {
        let candidate = PathBuf::from(root)
            .join("src")
            .join("build-debug")
            .join("bin")
            .join("ct");
        if candidate.is_file() && binary_supports_start_backend(&candidate) {
            return Some(candidate);
        }
    }

    None
}

/// Quick probe that confirms a binary is the codetracer `ct` CLI by
/// checking its top-level `--help` output mentions the `start_backend`
/// subcommand.  Bounded to a short timeout so a hung binary on PATH
/// can't stall the bench at startup.
fn binary_supports_start_backend(path: &Path) -> bool {
    use std::process::Command;
    let output = Command::new(path)
        .arg("--help")
        .env("CODETRACER_IN_UI_TEST", "1")
        .output();
    match output {
        Ok(o) => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            let stderr = String::from_utf8_lossy(&o.stderr);
            stdout.contains("start_backend") || stderr.contains("start_backend")
        }
        Err(_) => false,
    }
}

/// Probe a candidate binary by spawning it with `trace omniscient-prep
/// --help` and inspecting the exit status. Used by [`ct_binary`] to
/// avoid surfacing the pre-M19 `replay-server` that doesn't carry the
/// subcommand. The probe is best-effort: any spawn error returns false
/// so we fall through to the next candidate.
fn binary_supports_trace_omniscient_prep(binary: &Path) -> bool {
    let Ok(output) = Command::new(binary)
        .arg("trace")
        .arg("omniscient-prep")
        .arg("--help")
        .output()
    else {
        return false;
    };
    output.status.success()
}

/// Outcome of a benchmark probe. Each driver returns one per fixture
/// so the report writer can collate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchRow {
    /// Identifier of the row. For P2 this is the fixture path; for
    /// P3 it's `slice=K concurrency=C`; for P4 it's an operation name.
    pub id: String,
    /// Language under test. May be empty for P3 multi-slice rows.
    pub language: String,
    /// Free-form columns. The report writer emits them in insertion
    /// order. The CSV path encodes each column as its own column;
    /// JSON uses an object; Markdown uses a row.
    pub columns: Vec<(String, String)>,
}

impl BenchRow {
    pub fn new(id: impl Into<String>, language: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            language: language.into(),
            columns: Vec::new(),
        }
    }

    pub fn push(&mut self, name: impl Into<String>, value: impl Into<String>) -> &mut Self {
        self.columns.push((name.into(), value.into()));
        self
    }
}

/// Whole-bench report. Holds the header column ordering plus the
/// per-fixture rows.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BenchReport {
    pub bench_name: String,
    pub columns: Vec<String>,
    pub rows: Vec<BenchRow>,
}

impl BenchReport {
    pub fn new(bench_name: impl Into<String>, columns: Vec<String>) -> Self {
        Self {
            bench_name: bench_name.into(),
            columns,
            rows: Vec::new(),
        }
    }

    pub fn push(&mut self, row: BenchRow) {
        self.rows.push(row);
    }

    /// Render the report as CSV.
    pub fn to_csv(&self) -> String {
        let mut out = String::new();
        out.push_str("id,language");
        for c in &self.columns {
            out.push(',');
            out.push_str(&csv_escape(c));
        }
        out.push('\n');
        for row in &self.rows {
            out.push_str(&csv_escape(&row.id));
            out.push(',');
            out.push_str(&csv_escape(&row.language));
            // Map columns by name so the row order matches header.
            for header in &self.columns {
                out.push(',');
                let value = row
                    .columns
                    .iter()
                    .find(|(k, _)| k == header)
                    .map(|(_, v)| v.as_str())
                    .unwrap_or("");
                out.push_str(&csv_escape(value));
            }
            out.push('\n');
        }
        out
    }

    /// Render the report as JSON.
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }

    /// Render the report as a Markdown table.
    pub fn to_markdown(&self) -> String {
        let mut out = String::new();
        writeln!(out, "# {}", self.bench_name).ok();
        out.push('\n');
        out.push_str("| id | language");
        for c in &self.columns {
            out.push_str(" | ");
            out.push_str(c);
        }
        out.push_str(" |\n");
        out.push_str("| --- | ---");
        for _ in &self.columns {
            out.push_str(" | ---");
        }
        out.push_str(" |\n");
        for row in &self.rows {
            out.push_str("| ");
            out.push_str(&md_escape(&row.id));
            out.push_str(" | ");
            out.push_str(&md_escape(&row.language));
            for header in &self.columns {
                out.push_str(" | ");
                let value = row
                    .columns
                    .iter()
                    .find(|(k, _)| k == header)
                    .map(|(_, v)| v.as_str())
                    .unwrap_or("");
                out.push_str(&md_escape(value));
            }
            out.push_str(" |\n");
        }
        out
    }
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        let escaped = s.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        s.to_string()
    }
}

fn md_escape(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', " ")
}

/// Resolves the bench output directory.  Honours `CODETRACER_BENCH_OUT`
/// for tests; defaults to `target/codetracer-bench/<bench>/`.
pub fn bench_output_dir(bench_name: &str) -> PathBuf {
    if let Some(env) = std::env::var_os("CODETRACER_BENCH_OUT") {
        PathBuf::from(env).join(bench_name)
    } else {
        PathBuf::from("target")
            .join("codetracer-bench")
            .join(bench_name)
    }
}

/// Writes the report in all three formats under
/// `bench_output_dir(bench_name)`. Returns the directory the files
/// landed under so callers can surface it to the user.
pub fn write_report(report: &BenchReport) -> std::io::Result<PathBuf> {
    let dir = bench_output_dir(&report.bench_name);
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("report.csv"), report.to_csv())?;
    std::fs::write(dir.join("report.json"), report.to_json())?;
    std::fs::write(dir.join("report.md"), report.to_markdown())?;
    Ok(dir)
}

/// Recorder driver shared between P2 + P3 + P4.
///
/// Every recording goes through [`FixtureRecorder::record_via_ct`],
/// which spawns the user-facing `ct record` CLI as a subprocess.  All
/// language-specific recorder discovery (Python interpreter pinning,
/// `ct-mcr` location, ruby/js/cairo/solana shim resolution, native
/// compilation steps) happens inside `ct` — the bench inherits the
/// process environment so the sibling-detection env vars
/// (`CODETRACER_PYTHON_INTERPRETER`, `CODETRACER_PYTHON_RECORDER_SRC`,
/// `CODETRACER_CT_MCR_CMD`, `CAIRO_CORELIB_DIR`, `SBF_SDK_PATH`, …)
/// flow through unchanged.
///
/// This is the recording-side counterpart to the DAP-side refactor in
/// commit `3dc0d95c` ("feat(bench/P4): launch DAP through `ct
/// start_backend`; re-enable jump ops") — both sides now route
/// through the `ct` CLI rather than direct subprocess spawns.
pub struct FixtureRecorder;

impl FixtureRecorder {
    /// Record `program_path` into `trace_dir` via `ct record`.
    ///
    /// `backend_kind` is the value to pass after `--backend`:
    /// * `None` — omit `--backend`, let `ct` pick the default for the
    ///   language (materialized for VM langs; `mcr` on Linux for native
    ///   compiled langs).
    /// * `Some("mcr")` — explicit Multi-Core Recorder.
    /// * `Some("rr")` — explicit rr.
    /// * `Some("ttd")` — TTD (Windows-only; `ct record` will reject on
    ///   other platforms).
    ///
    /// On exit-zero the function returns the trace_dir path (where the
    /// `.ct` container landed).  Use [`crate::omniscient_db_size::find_ct_container`]
    /// to locate the actual file inside; recorders place it at varying
    /// depths under the output folder.
    ///
    /// On failure the error carries the **first 20 lines of stderr**
    /// from `ct record` so the bench's PENDING sentinel surfaces the
    /// real recorder diagnostic rather than swallowing it.
    pub fn record_via_ct(
        language: Language,
        backend_kind: Option<&str>,
        program_path: &Path,
        trace_dir: &Path,
    ) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;

        let ct = ct_cli_binary().ok_or_else(|| {
            RecorderError::Unavailable(
                "ct CLI not on PATH and not discoverable at src/build-debug/bin/ct \
                 — run `just build-once` to produce it, or set CT_CLI_BIN"
                    .to_string(),
            )
        })?;

        let mut cmd = Command::new(&ct);
        cmd.arg("record")
            // Pin --lang explicitly so the bench is robust against
            // surprising file-extension overlaps (e.g. Solana fixtures
            // are `.rs` files but must record via the SBF recorder,
            // not Rust+MCR).  `ct record` accepts an empty --lang and
            // falls back to extension detection, so passing the wire
            // form keeps us belt-and-braces safe.
            .arg("--lang")
            .arg(language.ct_record_lang())
            .arg("-o")
            .arg(trace_dir);
        if let Some(kind) = backend_kind {
            cmd.arg("--backend").arg(kind);
        }
        cmd.arg(program_path);

        let output = cmd
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn {}: {e}", ct.display())))?;
        if !output.status.success() {
            // ct record routes the recorder's output via
            // poStdErrToStdOut (see record.nim `recordInternal`), so
            // diagnostic text actually lands on stdout.  We harvest
            // both streams and keep the first 20 lines so the bench's
            // SKIP/PENDING sentinel surfaces the real recorder
            // diagnostic without dumping the entire program output.
            let stderr_text = String::from_utf8_lossy(&output.stderr).to_string();
            let stdout_text = String::from_utf8_lossy(&output.stdout).to_string();
            let combined = if stderr_text.trim().is_empty() {
                stdout_text
            } else if stdout_text.trim().is_empty() {
                stderr_text
            } else {
                format!("{stdout_text}\n{stderr_text}")
            };
            let stderr_tail = combined.lines().take(20).collect::<Vec<_>>().join("\n");
            return Err(RecorderError::RecordingFailed {
                exit_code: output.status.code(),
                stderr_tail,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Back-compat shim: record `program_path` into `trace_dir` letting
    /// `ct record` pick the default backend for the language.
    ///
    /// Equivalent to [`FixtureRecorder::record_via_ct`] with
    /// `backend_kind = None`.  Used by the omniscient-DB-size (P2) and
    /// slice-prep-speed (P3) suites where the bench measures the
    /// language's canonical recording surface rather than enumerating
    /// backends.
    pub fn record(
        language: Language,
        program_path: &Path,
        trace_dir: &Path,
    ) -> Result<PathBuf, RecorderError> {
        Self::record_via_ct(language, None, program_path, trace_dir)
    }
}

/// Failures the recorder driver surfaces.
#[derive(Debug)]
pub enum RecorderError {
    /// `ct` CLI not discoverable.  The bench surfaces this as a SKIP
    /// sentinel rather than failing the row outright.
    Unavailable(String),
    /// I/O error while setting up the recording directory.
    Io(String),
    /// `ct record` ran but exited non-zero.  Carries the first 20 lines
    /// of stderr (or stdout, since `ct record` routes recorder output
    /// via `poStdErrToStdOut`) so the bench's PENDING sentinel exposes
    /// the real recorder diagnostic.
    RecordingFailed {
        exit_code: Option<i32>,
        stderr_tail: String,
    },
}

impl std::fmt::Display for RecorderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecorderError::Unavailable(s) => write!(f, "{s}"),
            RecorderError::Io(s) => write!(f, "io: {s}"),
            RecorderError::RecordingFailed {
                exit_code,
                stderr_tail,
            } => {
                write!(f, "ct record exited with {exit_code:?}:\n{stderr_tail}")
            }
        }
    }
}

impl std::error::Error for RecorderError {}

/// Invokes the `ct trace omniscient-prep` subprocess against
/// `slice_folder`. Returns the wall-clock duration of the subprocess
/// so the P3 driver can chart per-slice times.
pub struct OmniscientPrep;

impl OmniscientPrep {
    pub fn run(slice_folder: &Path, mode: &str) -> Result<std::time::Duration, RecorderError> {
        let bin = ct_binary()
            .ok_or_else(|| RecorderError::Unavailable("ct binary not on PATH".to_string()))?;
        let started = std::time::Instant::now();
        let output = Command::new(&bin)
            .arg("trace")
            .arg("omniscient-prep")
            .arg(slice_folder)
            .arg("--mode")
            .arg(mode)
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn {}: {e}", bin.display())))?;
        if !output.status.success() {
            let stderr_text = String::from_utf8_lossy(&output.stderr).to_string();
            let stdout_text = String::from_utf8_lossy(&output.stdout).to_string();
            let combined = if stderr_text.trim().is_empty() {
                stdout_text
            } else if stdout_text.trim().is_empty() {
                stderr_text
            } else {
                format!("{stdout_text}\n{stderr_text}")
            };
            let stderr_tail = combined.lines().take(20).collect::<Vec<_>>().join("\n");
            return Err(RecorderError::RecordingFailed {
                exit_code: output.status.code(),
                stderr_tail,
            });
        }
        Ok(started.elapsed())
    }
}

/// Recursively sums the on-disk size (in bytes) of every regular file
/// rooted at `path`. The P2 driver calls this against the recorded
/// trace directory + the omniscient artefacts to gather size columns.
pub fn dir_size_bytes(path: &Path) -> std::io::Result<u64> {
    if !path.exists() {
        return Ok(0);
    }
    let mut total = 0u64;
    for entry in walkdir::WalkDir::new(path) {
        let entry = entry.map_err(|e| std::io::Error::other(e.to_string()))?;
        if entry.file_type().is_file() {
            total += entry
                .metadata()
                .map_err(|e| std::io::Error::other(e.to_string()))?
                .len();
        }
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_parse_round_trip() {
        for lang in Language::all() {
            let parsed = Language::parse(lang.wire()).expect("round-trip");
            assert_eq!(parsed, lang);
        }
        assert_eq!(Language::parse("cpp"), Some(Language::CPlusPlus));
        assert_eq!(Language::parse("js"), Some(Language::JavaScript));
        assert_eq!(Language::parse("rust"), Some(Language::Rust));
        assert_eq!(Language::parse("unknown"), None);
    }

    #[test]
    fn report_emits_csv_json_md() {
        let mut report = BenchReport::new("demo", vec!["bytes".to_string(), "ratio".to_string()]);
        let mut row = BenchRow::new("fix1", "python");
        row.push("bytes", "1234").push("ratio", "0.5");
        report.push(row);
        let csv = report.to_csv();
        assert!(csv.contains("id,language,bytes,ratio"));
        assert!(csv.contains("fix1,python,1234,0.5"));
        let json = report.to_json();
        assert!(json.contains("\"bench_name\""));
        let md = report.to_markdown();
        assert!(md.contains("# demo"));
        assert!(md.contains("| fix1 | python | 1234 | 0.5 |"));
    }

    #[test]
    fn csv_escapes_commas_and_quotes() {
        let escaped = csv_escape("a,b\"c");
        assert_eq!(escaped, "\"a,b\"\"c\"");
    }

    #[test]
    fn materialized_languages_match_lang_nim() {
        // Cross-check against Lang.usesMaterializedTraces in
        // codetracer/src/common/lang.nim: Python/Ruby/JS/Cairo/Solana
        // are materialized; native compiled langs are not.
        assert!(Language::Python.uses_materialized_traces());
        assert!(Language::Ruby.uses_materialized_traces());
        assert!(Language::JavaScript.uses_materialized_traces());
        assert!(Language::Cairo.uses_materialized_traces());
        assert!(Language::Solana.uses_materialized_traces());
        assert!(!Language::C.uses_materialized_traces());
        assert!(!Language::CPlusPlus.uses_materialized_traces());
        assert!(!Language::Rust.uses_materialized_traces());
        assert!(!Language::Nim.uses_materialized_traces());
        assert!(!Language::Go.uses_materialized_traces());
    }
}
