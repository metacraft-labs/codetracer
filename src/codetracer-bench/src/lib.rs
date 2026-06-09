//! Shared infrastructure for the Performance + E2E Coverage campaign's
//! P2 / P3 / P4 benchmark suites.
//!
//! The three suites (omniscient-DB size, slice prep speed, GUI ops
//! latency) share a common harness:
//!
//! * [`LanguageProbe`] — narrow-sentinel availability checks per
//!   language (mirrors the M3 / M5 / M11 SKIP discipline).
//! * [`FixtureRecorder`] — invokes the relevant recorder for a fixture
//!   program and returns the resulting trace directory.
//! * [`OmniscientPrep`] — invokes the `ct trace omniscient-prep` Rust
//!   subprocess against a slice folder.
//! * [`ReportWriter`] — emits CSV + JSON + Markdown to a
//!   `target/codetracer-bench/<bench-name>/` directory.
//!
//! The library deliberately keeps measurement and reporting separate
//! so unit tests can verify report shape without invoking any
//! external recorder (see the synthetic-fixture path in the P3
//! verification tests).

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
}

/// Narrow per-language recorder probe.
///
/// Each variant names exactly one binary or environment dependency the
/// bench needs and emits a precise sentinel via [`Probe::sentinel`]
/// when the dependency is absent. The probes deliberately avoid
/// broad heuristics like "any recorder missing" — per the M3 review,
/// each SKIP message must name a single load-bearing dependency so
/// operators can fix it.
///
/// ## Sibling-detection contract
///
/// The CodeTracer dev shell's `scripts/detect-siblings.sh` exports
/// per-recorder env vars (`CODETRACER_PYTHON_INTERPRETER`,
/// `CODETRACER_PYTHON_RECORDER_SRC`, ...).  When run inside the shell
/// the probe consults those env vars *first*: this is the route that
/// the campaign brief calls "Approach B" — the test/bench must be
/// invoked from `nix develop` (or with `source scripts/detect-siblings.sh`
/// in the calling environment) so the recorder is reachable without
/// requiring it to be on the bare PATH.
pub struct LanguageProbe;

impl LanguageProbe {
    /// Run the probe for `language`. Returns `Ok(())` when the
    /// recorder is reachable, `Err(sentinel)` when it's not. The
    /// sentinel string is exactly the form the spec asks for: it
    /// names the missing binary or env var so callers can include it
    /// in their SKIP message.
    pub fn probe(language: Language) -> Result<(), String> {
        // Python: prefer the dev-shell-exported interpreter so the
        // sibling recorder's PyO3 extension can be loaded directly
        // (the bench doesn't need a `codetracer-python-recorder` console
        // script on PATH).
        if language == Language::Python && Self::python_recorder_reachable() {
            return Ok(());
        }
        // C / C++ / Rust: compile-then-record via the Multi-Core
        // Recorder (`ct-mcr`).  MCR is language-agnostic per
        // Multi-Core-Recorder.md §78 and produces a real CTFS event
        // stream (the bench's omniscient-prep step consumes that).
        // `ct-native-replay record` would also accept the binary but
        // it produces only a thin rr-metadata stub (~3 KB .ct file
        // wrapping the rr/ subdir); without a downstream rr→CTFS
        // decode pass the omniscient-prep step has nothing to index.
        if language == Language::CPlusPlus
            || language == Language::C
            || language == Language::Rust
        {
            if std::env::var_os("CODETRACER_CT_MCR_CMD").is_none() && which("ct-mcr").is_none() {
                return Err(
                    "ct-mcr (or CODETRACER_CT_MCR_CMD) not on PATH (run `direnv exec \
                     ../codetracer-native-recorder just build-ct-mcr` first)"
                        .to_string(),
                );
            }
            // C/C++ fixtures need a C++ compiler.  Rust needs rustc.
            if language == Language::CPlusPlus {
                if which("g++").is_none() && which("clang++").is_none() {
                    return Err(
                        "neither g++ nor clang++ on PATH (C++ fixture requires a C++ compiler; \
                         run from `nix develop` shell)"
                            .to_string(),
                    );
                }
            } else if language == Language::Rust && which("rustc").is_none() {
                return Err(
                    "rustc not on PATH (run from `nix develop` shell so the Rust \
                     toolchain is available)"
                        .to_string(),
                );
            }
            // The C path uses g++ (the C++ compiler accepts C); we
            // check for it here so the SKIP is precise.
            if language == Language::C && which("g++").is_none() && which("clang++").is_none() {
                return Err(
                    "neither g++ nor clang++ on PATH (the bench compiles C fixtures \
                     with the C++ compiler; run from `nix develop` shell)"
                        .to_string(),
                );
            }
            return Ok(());
        }
        // Ruby: sibling-detection prepends the gem's bin/ to PATH and
        // exports RUBY_RECORDER_ROOT. The binary check is the
        // load-bearing gate; runtime readiness (native_tracer.so etc.)
        // is the recorder's own responsibility — the bench surfaces
        // any subprocess error loudly so the operator can fix it,
        // rather than silently SKIPping on "recorder not ready".
        if language == Language::Ruby {
            if which("codetracer-ruby-recorder").is_some() {
                if which("ruby").is_some() {
                    return Ok(());
                }
                return Err(
                    "ruby not on PATH (run from `nix develop` shell so the ruby \
                     toolchain is available)"
                        .to_string(),
                );
            }
            let hint = match std::env::var_os("RUBY_RECORDER_ROOT") {
                Some(p) => format!(
                    "RUBY_RECORDER_ROOT={} but no codetracer-ruby-recorder binary on PATH \
                     (run `direnv exec ../codetracer-ruby-recorder just build` first)",
                    PathBuf::from(p).display()
                ),
                None => "codetracer-ruby-recorder not on PATH (run `direnv exec \
                         ../codetracer-ruby-recorder just build` first)"
                    .to_string(),
            };
            return Err(hint);
        }
        // JavaScript: sibling-detection prepends the node workspace's
        // `node_modules/.bin/` to PATH so the `codetracer-js-recorder`
        // shim resolves. Also need `node` on PATH for the JS recorder
        // to execute. Runtime readiness (the napi addon, instrumenter
        // package state) is the recorder's own responsibility — the
        // bench surfaces any subprocess error loudly so the operator
        // can fix it, rather than silently SKIPping.
        if language == Language::JavaScript {
            if which("codetracer-js-recorder").is_some() {
                if which("node").is_some() {
                    return Ok(());
                }
                return Err(
                    "node not on PATH (the JS recorder shells out to node; run from \
                     `nix develop` shell)"
                        .to_string(),
                );
            }
            return Err("codetracer-js-recorder not on PATH (run `direnv exec \
                 ../codetracer-js-recorder just build` first)"
                .to_string());
        }
        // Nim + Go: routed through the Multi-Core Recorder per
        // `codetracer-specs/Recording-Backends/Multi-Core-Recorder/Multi-Core-Recorder.md`
        // §78 (any LLVM/GCC-compiled binary is MCR-recordable).  The
        // probe verifies the toolchain (nim or go) + ct-mcr are both
        // reachable; FixtureRecorder::record_nim / record_go below
        // compile the fixture and invoke `ct-mcr record` against the
        // produced binary.
        if language == Language::Nim {
            if std::env::var_os("CODETRACER_CT_MCR_CMD").is_none() && which("ct-mcr").is_none() {
                return Err(
                    "ct-mcr (or CODETRACER_CT_MCR_CMD) not on PATH (run `direnv exec \
                     ../codetracer-native-recorder just build-ct-mcr` first)"
                        .to_string(),
                );
            }
            if which("nim").is_none() {
                return Err(
                    "nim not on PATH (run from `nix develop` shell so the Nim toolchain \
                     is available)"
                        .to_string(),
                );
            }
            return Ok(());
        }
        if language == Language::Go {
            if std::env::var_os("CODETRACER_CT_MCR_CMD").is_none() && which("ct-mcr").is_none() {
                return Err(
                    "ct-mcr (or CODETRACER_CT_MCR_CMD) not on PATH (run `direnv exec \
                     ../codetracer-native-recorder just build-ct-mcr` first)"
                        .to_string(),
                );
            }
            if which("go").is_none() {
                return Err(
                    "go not on PATH (run from `nix develop` shell so the Go toolchain \
                     is available)"
                        .to_string(),
                );
            }
            return Ok(());
        }
        // Fall through to the binary-on-PATH check below as the backup
        // path (e.g. a future build that ships the console script in
        // the venv).
        let binary = Self::expected_binary(language);
        if which(binary).is_some() {
            Ok(())
        } else if language == Language::Python {
            Err(
                "CODETRACER_PYTHON_INTERPRETER not set (run `nix develop` or \
                 `source scripts/detect-siblings.sh` first)"
                    .to_string(),
            )
        } else {
            Err(format!("{binary} not on PATH"))
        }
    }

    /// Returns the binary name the bench looks for. Operators can override
    /// per-language via env vars (the per-fixture `regenerate.sh`
    /// scripts honour the same env-var names).
    ///
    /// C, C++, Rust, Nim, and Go all route through the Multi-Core
    /// Recorder (`ct-mcr`) per Multi-Core-Recorder.md §78 — MCR is
    /// language-agnostic at the binary level.  The bench's
    /// `record_<lang>` methods compile the fixture with the language
    /// toolchain (`nim c`, `go build`, `g++`/`clang++`, `rustc`) and
    /// then invoke MCR against the resulting binary, producing a
    /// real CTFS event stream the omniscient-prep step can index.
    pub fn expected_binary(language: Language) -> &'static str {
        match language {
            Language::Python => "codetracer-python-recorder",
            Language::CPlusPlus | Language::C | Language::Rust => "ct-mcr",
            Language::Ruby => "codetracer-ruby-recorder",
            Language::JavaScript => "codetracer-js-recorder",
            Language::Nim | Language::Go => "ct-mcr",
            Language::Cairo => "codetracer-cairo-recorder",
            Language::Solana => "codetracer-solana-recorder",
        }
    }

    /// The Python recorder is reachable when the dev shell exported
    /// both:
    ///
    ///   * `CODETRACER_PYTHON_INTERPRETER` — a Python interpreter that
    ///     can import the recorder once `PYTHONPATH` includes the
    ///     recorder source dir.
    ///   * `CODETRACER_PYTHON_RECORDER_SRC` — the recorder source dir
    ///     (the package importable as `codetracer_python_recorder`).
    ///
    /// We additionally verify the interpreter path exists on disk; the
    /// `import` step is exercised lazily by the recorder invocation in
    /// [`FixtureRecorder::record`].
    pub fn python_recorder_reachable() -> bool {
        let interpreter = match std::env::var_os("CODETRACER_PYTHON_INTERPRETER") {
            Some(p) => PathBuf::from(p),
            None => return false,
        };
        let src = std::env::var_os("CODETRACER_PYTHON_RECORDER_SRC");
        if src.is_none() {
            return false;
        }
        interpreter.is_file()
    }
}

/// Minimal `which` — searches `PATH` for an executable. Used by the
/// probes and by the optional `ct` binary check in P2 / P3.
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
/// Honours per-language env-var overrides so operators on hosts where
/// the recorder lives under a different name (the CI nix shell vs.
/// a local checkout, for instance) can point the bench at the right
/// binary without recompiling.
pub struct FixtureRecorder;

impl FixtureRecorder {
    /// Record `program_path` into `trace_dir`. Returns the directory
    /// the recorder wrote into (which is the same as `trace_dir`
    /// when the recording succeeds).
    ///
    /// The driver invokes the per-language recorder binary as a
    /// subprocess; the binary name comes from [`LanguageProbe`].
    /// Errors propagate as [`RecorderError`] with enough detail for
    /// the bench driver to surface a SKIP message.
    pub fn record(
        language: Language,
        program_path: &Path,
        trace_dir: &Path,
    ) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        LanguageProbe::probe(language).map_err(RecorderError::Unavailable)?;

        // Python takes the sibling-detected-interpreter route: invoke
        // `python -m codetracer_python_recorder --out-dir <out> --
        // <program>` rather than a binary on PATH, because the dev
        // shell installs only the pure-Python recorder into its venv;
        // the native Rust-backed recorder lives in the sibling repo's
        // source tree and is imported via `PYTHONPATH`.
        if language == Language::Python {
            return Self::record_python(program_path, trace_dir);
        }
        // C++ requires a compilation step before the native recorder
        // can attach to the binary; route through the specialized
        // method that compiles via g++ (or clang++).
        if language == Language::CPlusPlus {
            return Self::record_cpp(program_path, trace_dir);
        }
        // Ruby and JS recorders are shell wrappers that invoke their
        // respective interpreter; the dedicated methods double-check
        // the runtime is available + surface a precise error.
        if language == Language::Ruby {
            return Self::record_ruby(program_path, trace_dir);
        }
        if language == Language::JavaScript {
            return Self::record_javascript(program_path, trace_dir);
        }
        // Nim + Go: route through the Multi-Core Recorder (MCR is
        // language-agnostic per Multi-Core-Recorder.md §78).  Compile
        // the source with the language toolchain, then invoke
        // `ct-mcr record` against the resulting binary.
        if language == Language::Nim {
            return Self::record_nim(program_path, trace_dir);
        }
        if language == Language::Go {
            return Self::record_go(program_path, trace_dir);
        }
        // C: compile via record_cpp (g++ accepts C) then record via
        // MCR.  Rust: rustc + MCR.  Both produce real CTFS event
        // streams via ct-mcr — same path as Nim/Go.
        if language == Language::C {
            return Self::record_c(program_path, trace_dir);
        }
        if language == Language::Rust {
            return Self::record_rust(program_path, trace_dir);
        }
        // Solana: cargo-build-sbf compiles the fixture's Cargo project
        // to an SBF `.so` ELF, then codetracer-solana-recorder records
        // it through the SBF VM.  The fixture's `source_path` is the
        // project root (contains `Cargo.toml` + `src/lib.rs`).
        if language == Language::Solana {
            return Self::record_solana(program_path, trace_dir);
        }

        let binary = LanguageProbe::expected_binary(language);
        let mut cmd = Command::new(binary);
        match language {
            Language::Python => unreachable!("handled above"),
            Language::CPlusPlus | Language::Ruby | Language::JavaScript => {
                unreachable!("handled by per-language record_* methods above")
            }
            Language::Nim | Language::Go | Language::C | Language::Rust => {
                unreachable!("handled by per-language record_* methods above")
            }
            Language::Cairo => {
                cmd.arg("record")
                    .arg("--out-dir")
                    .arg(trace_dir)
                    .arg(program_path);
            }
            Language::Solana => unreachable!("handled by record_solana above"),
        }

        let output = cmd
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn {binary}: {e}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: binary.to_string(),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Locate the MCR binary (ct-mcr) the bench should invoke.
    /// `CODETRACER_CT_MCR_CMD` is exported by detect-siblings.sh and
    /// points at codetracer-native-recorder's `ct_cli/ct_cli` build.
    fn ct_mcr_command() -> PathBuf {
        std::env::var_os("CODETRACER_CT_MCR_CMD")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("ct-mcr"))
    }

    /// Run `ct-mcr record -o <trace> -- <binary>` against an
    /// already-compiled binary.  Shared by the Nim and Go paths.
    fn record_via_mcr(binary_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        let recorder = Self::ct_mcr_command();
        let trace_file = trace_dir.join("trace.ct");
        let output = Command::new(&recorder)
            .arg("record")
            .arg("-o")
            .arg(&trace_file)
            .arg("--")
            .arg(binary_path)
            .output()
            .map_err(|e| {
                RecorderError::Io(format!("failed to spawn {}: {e}", recorder.display()))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: recorder.display().to_string(),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Record a Nim program via MCR.  Compiles `main.nim` with
    /// `nim c -d:release --out:<bin>` then invokes ct-mcr against the
    /// produced binary.  The Multi-Core Recorder is language-agnostic
    /// at the binary level (Multi-Core-Recorder.md §78), so the
    /// recording path is identical to C/C++/Rust once the binary
    /// exists.
    pub fn record_nim(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let build_dir = trace_dir.join("build");
        std::fs::create_dir_all(&build_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let binary_path = build_dir.join("main");
        let compile = Command::new("nim")
            .arg("c")
            .arg("-d:release")
            .arg("--mm:orc")
            .arg(format!("--out:{}", binary_path.display()))
            .arg(program_path)
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn nim: {e}")))?;
        if !compile.status.success() {
            let stderr = String::from_utf8_lossy(&compile.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: "nim".to_string(),
                exit: compile.status.code(),
                stderr,
            });
        }
        Self::record_via_mcr(&binary_path, trace_dir)
    }

    /// Record a Go program via MCR.  Compiles `main.go` with
    /// `go build -o <bin>` then invokes ct-mcr against the produced
    /// binary.  The Multi-Core Recorder is language-agnostic at the
    /// binary level (Multi-Core-Recorder.md §78); Go's default
    /// static-binary output is explicitly listed there as a launch
    /// target alongside Rust musl + BusyBox.
    pub fn record_go(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let build_dir = trace_dir.join("build");
        std::fs::create_dir_all(&build_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let binary_path = build_dir.join("main");
        let compile = Command::new("go")
            .arg("build")
            .arg("-o")
            .arg(&binary_path)
            .arg(program_path)
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn go: {e}")))?;
        if !compile.status.success() {
            let stderr = String::from_utf8_lossy(&compile.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: "go".to_string(),
                exit: compile.status.code(),
                stderr,
            });
        }
        Self::record_via_mcr(&binary_path, trace_dir)
    }

    /// Record a Solana program by compiling it with `cargo-build-sbf`
    /// (the Solana SBF toolchain) and then invoking
    /// `codetracer-solana-recorder record <.so>` against the
    /// produced ELF.  Per the recorder's own CLI, the ELF is
    /// executed through the SBF VM with register tracing; the
    /// resulting CTFS `.ct` lands in `trace_dir`.
    ///
    /// The fixture's `program_path` is the Cargo project root
    /// (containing `Cargo.toml` + `src/lib.rs`).  `cargo-build-sbf`
    /// writes the .so to `target/deploy/<crate>.so` under the
    /// project root, so the bench's trace_dir is unrelated to the
    /// cargo build dir.
    pub fn record_solana(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let project_root = program_path;
        let cargo_toml = project_root.join("Cargo.toml");
        if !cargo_toml.is_file() {
            return Err(RecorderError::SubprocessFailed {
                binary: "cargo-build-sbf".to_string(),
                exit: None,
                stderr: format!(
                    "Solana fixture {} is missing Cargo.toml (expected an SBF cargo project)",
                    project_root.display()
                ),
            });
        }
        let compile = Command::new("cargo-build-sbf")
            .arg("--no-rustup-override")
            .arg("--manifest-path")
            .arg(&cargo_toml)
            .output()
            .map_err(|e| {
                RecorderError::Io(format!("failed to spawn cargo-build-sbf: {e}"))
            })?;
        if !compile.status.success() {
            let stderr = String::from_utf8_lossy(&compile.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: "cargo-build-sbf".to_string(),
                exit: compile.status.code(),
                stderr,
            });
        }
        // cargo-build-sbf writes the .so to <project>/target/deploy/<crate>.so.
        // We discover the produced ELF rather than reconstruct the crate
        // name so this works for any fixture.
        let deploy_dir = project_root.join("target").join("deploy");
        let so_path = std::fs::read_dir(&deploy_dir)
            .map_err(|e| {
                RecorderError::Io(format!(
                    "cargo-build-sbf produced no deploy dir at {}: {e}",
                    deploy_dir.display()
                ))
            })?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .find(|p| p.extension().is_some_and(|ext| ext == "so"))
            .ok_or_else(|| RecorderError::SubprocessFailed {
                binary: "cargo-build-sbf".to_string(),
                exit: None,
                stderr: format!(
                    "no *.so artefact found in {} after cargo-build-sbf",
                    deploy_dir.display()
                ),
            })?;
        let recorder = std::env::var_os("CODETRACER_SOLANA_RECORDER")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("codetracer-solana-recorder"));
        let output = Command::new(&recorder)
            .arg("record")
            .arg(&so_path)
            .arg("-o")
            .arg(trace_dir)
            .output()
            .map_err(|e| {
                RecorderError::Io(format!("failed to spawn {}: {e}", recorder.display()))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: recorder.display().to_string(),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Record a C++ program by first compiling it with `g++` (or
    /// `clang++` as a fallback) and then invoking the native recorder
    /// against the resulting binary. The binary is produced under
    /// `trace_dir/build/main` so the test artefacts live in one place.
    /// Matches the per-fixture `regenerate.sh` contract — see
    /// `fixtures/omniscient-db-size/c_plus_plus/short_loop/regenerate.sh`.
    pub fn record_cpp(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        // Build the binary in a sibling temp dir, NOT inside trace_dir.
        // ct-mcr's record path tears down + rebuilds the trace dir at
        // recording time; if the binary lives at `trace_dir/build/main`
        // it gets removed before exec and the recorder reports
        // `execve failed: ... (or interpreter) not found (ENOENT)`.
        let build_root = trace_dir.with_file_name(format!(
            "{}-build",
            trace_dir.file_name().and_then(|s| s.to_str()).unwrap_or("ct-bench-cpp")
        ));
        std::fs::create_dir_all(&build_root).map_err(|e| RecorderError::Io(e.to_string()))?;
        // Choose the compiler. The detect-siblings hook does not pin a
        // specific compiler, so we accept g++ (the campaign's
        // regenerate.sh default) and clang++ (the macOS fallback).
        let cxx_env = std::env::var_os("CXX");
        let compiler = if let Some(c) = cxx_env.as_ref().and_then(|p| p.to_str()) {
            c.to_string()
        } else if which("g++").is_some() {
            "g++".to_string()
        } else if which("clang++").is_some() {
            "clang++".to_string()
        } else {
            return Err(RecorderError::Unavailable(
                "no C++ compiler on PATH (looked for g++ then clang++; set CXX to override)"
                    .to_string(),
            ));
        };
        let binary_path = build_root.join("main");
        let compile_output = Command::new(&compiler)
            .arg("-O0")
            .arg("-g")
            .arg("-no-pie")
            .arg("-o")
            .arg(&binary_path)
            .arg(program_path)
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn {compiler}: {e}")))?;
        if !compile_output.status.success() {
            let stderr = String::from_utf8_lossy(&compile_output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: compiler,
                exit: compile_output.status.code(),
                stderr,
            });
        }
        // Route through the Multi-Core Recorder so the resulting .ct is
        // a real CTFS event stream (omniscient-prep input) rather than
        // the thin rr-metadata stub that `ct-native-replay record`
        // produces.  MCR is language-agnostic per Multi-Core-Recorder.md
        // §78 — same as the Nim and Go paths below.
        Self::record_via_mcr(&binary_path, trace_dir)
    }

    /// Record a C program via `record_cpp` — the C source compiles
    /// cleanly with `g++` (which is the C++ compiler we already have
    /// reachable in the dev shell) and the resulting binary records
    /// through MCR identically.
    pub fn record_c(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        Self::record_cpp(program_path, trace_dir)
    }

    /// Record a Rust program by compiling with `rustc -g -O0` then
    /// invoking MCR on the binary.  Mirrors the C/C++/Nim/Go path:
    /// MCR records the produced ELF directly.
    pub fn record_rust(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        let build_root = trace_dir.with_file_name(format!(
            "{}-build",
            trace_dir.file_name().and_then(|s| s.to_str()).unwrap_or("ct-bench-rust")
        ));
        std::fs::create_dir_all(&build_root).map_err(|e| RecorderError::Io(e.to_string()))?;
        let binary_path = build_root.join("main");
        let compile = Command::new("rustc")
            .arg("-g")
            .arg("-O")
            .arg("-C")
            .arg("opt-level=0")
            .arg("-o")
            .arg(&binary_path)
            .arg(program_path)
            .output()
            .map_err(|e| RecorderError::Io(format!("failed to spawn rustc: {e}")))?;
        if !compile.status.success() {
            let stderr = String::from_utf8_lossy(&compile.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: "rustc".to_string(),
                exit: compile.status.code(),
                stderr,
            });
        }
        Self::record_via_mcr(&binary_path, trace_dir)
    }

    /// Record a Ruby program by invoking the `codetracer-ruby-recorder`
    /// shim (which itself shells out to a ruby interpreter). The shim
    /// must be on PATH — checked by the probe — and the wrapper picks
    /// up `RUBY_RECORDER_ROOT` when set so the operator can override
    /// the gem location.
    pub fn record_ruby(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let recorder = std::env::var_os("CODETRACER_RUBY_RECORDER")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("codetracer-ruby-recorder"));
        let output = Command::new(&recorder)
            .arg("--out-dir")
            .arg(trace_dir)
            .arg("--")
            .arg(program_path)
            .output()
            .map_err(|e| {
                RecorderError::Io(format!("failed to spawn {}: {e}", recorder.display()))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: recorder.display().to_string(),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Record a JS program via the `codetracer-js-recorder` shim. The
    /// shim wraps a Node CLI; the probe confirms node is on PATH.
    pub fn record_javascript(
        program_path: &Path,
        trace_dir: &Path,
    ) -> Result<PathBuf, RecorderError> {
        std::fs::create_dir_all(trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
        let recorder = std::env::var_os("CODETRACER_JS_RECORDER")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("codetracer-js-recorder"));
        // codetracer-js-recorder per Recorder-CLI-Conventions §3 +
        // its own packages/cli/src/record-cmd.ts: the program file is
        // a positional argument BEFORE any `--` separator (anything
        // after `--` is treated as application args), and the trace
        // output dir is set via `--out-dir <dir>`.  Matches the
        // canonical invocation used by codetracer-js-recorder's own
        // tests/e2e/e2e.test.ts.
        let output = Command::new(&recorder)
            .arg("record")
            .arg(program_path)
            .arg("--out-dir")
            .arg(trace_dir)
            .output()
            .map_err(|e| {
                RecorderError::Io(format!("failed to spawn {}: {e}", recorder.display()))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: recorder.display().to_string(),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }

    /// Record a Python program by invoking the sibling-detected Python
    /// interpreter against `codetracer_python_recorder` as a module.
    /// The PYTHONPATH is augmented with the sibling source dir so the
    /// recorder package (which lives in the sibling repo, not the venv)
    /// is importable.
    pub fn record_python(program_path: &Path, trace_dir: &Path) -> Result<PathBuf, RecorderError> {
        let interpreter = std::env::var_os("CODETRACER_PYTHON_INTERPRETER").ok_or_else(|| {
            RecorderError::Unavailable(
                "CODETRACER_PYTHON_INTERPRETER not set — run from `nix develop` shell".to_string(),
            )
        })?;
        let recorder_src = std::env::var_os("CODETRACER_PYTHON_RECORDER_SRC").ok_or_else(|| {
            RecorderError::Unavailable(
                "CODETRACER_PYTHON_RECORDER_SRC not set — sibling recorder repo not detected"
                    .to_string(),
            )
        })?;
        // The recorder produces a single CTFS `.ct` file under
        // `trace_dir/`. Some recordings need an empty target dir to
        // disambiguate names; we keep the caller's existing dir.
        let mut cmd = Command::new(&interpreter);
        cmd.arg("-m")
            .arg("codetracer_python_recorder")
            .arg("--out-dir")
            .arg(trace_dir)
            .arg("--")
            .arg(program_path);

        // Splice the recorder source dir onto PYTHONPATH so the venv
        // (which only ships the pure-Python recorder) still resolves
        // the native `codetracer_python_recorder` package.
        let mut pythonpath = std::ffi::OsString::from(&recorder_src);
        if let Some(existing) = std::env::var_os("PYTHONPATH") {
            pythonpath.push(":");
            pythonpath.push(existing);
        }
        cmd.env("PYTHONPATH", pythonpath);

        let output = cmd.output().map_err(|e| {
            RecorderError::Io(format!(
                "failed to spawn {} -m codetracer_python_recorder: {e}",
                std::path::Path::new(&interpreter).display(),
            ))
        })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: format!(
                    "{} -m codetracer_python_recorder",
                    std::path::Path::new(&interpreter).display()
                ),
                exit: output.status.code(),
                stderr,
            });
        }
        Ok(trace_dir.to_path_buf())
    }
}

/// Failures the recorder driver surfaces.
#[derive(Debug)]
pub enum RecorderError {
    /// Recorder binary not on PATH (the narrow SKIP sentinel).
    Unavailable(String),
    /// I/O error while setting up the recording directory.
    Io(String),
    /// Recorder ran but failed.
    SubprocessFailed {
        binary: String,
        exit: Option<i32>,
        stderr: String,
    },
}

impl std::fmt::Display for RecorderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecorderError::Unavailable(s) => write!(f, "{s}"),
            RecorderError::Io(s) => write!(f, "io: {s}"),
            RecorderError::SubprocessFailed {
                binary,
                exit,
                stderr,
            } => {
                write!(f, "{binary} exited with {exit:?}: {stderr}")
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
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            return Err(RecorderError::SubprocessFailed {
                binary: bin.display().to_string(),
                exit: output.status.code(),
                stderr,
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
}
