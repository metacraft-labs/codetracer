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

    /// Full matrix: the 10 languages the wider fixture set spans.
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
pub struct LanguageProbe;

impl LanguageProbe {
    /// Run the probe for `language`. Returns `Ok(())` when the
    /// recorder is reachable, `Err(sentinel)` when it's not. The
    /// sentinel string is exactly the form the spec asks for: it
    /// names the missing binary or env var so callers can include it
    /// in their SKIP message.
    pub fn probe(language: Language) -> Result<(), String> {
        let binary = Self::expected_binary(language);
        if which(binary).is_some() {
            Ok(())
        } else {
            Err(format!("{binary} not on PATH"))
        }
    }

    /// Name of the binary the bench looks for. Operators can override
    /// per-language via env vars (the per-fixture `regenerate.sh`
    /// scripts honour the same env-var names).
    fn expected_binary(language: Language) -> &'static str {
        match language {
            Language::Python => "codetracer-python-recorder",
            Language::CPlusPlus | Language::C => "ct-native-replay",
            Language::Ruby => "codetracer-ruby-recorder",
            Language::JavaScript => "codetracer-js-recorder",
            Language::Rust => "ct-native-replay",
            Language::Nim => "codetracer-nim",
            Language::Go => "codetracer-go-recorder",
            Language::Cairo => "codetracer-cairo-recorder",
            Language::Solana => "codetracer-solana-recorder",
        }
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

/// Returns the path of the `ct` (or `replay-server`) binary the bench
/// shells out to for the `omniscient-prep` subcommand. Honours the
/// `CT_BIN` env var first; falls back to `ct` on PATH; finally tries
/// `replay-server` (the db-backend binary name).
pub fn ct_binary() -> Option<PathBuf> {
    if let Some(env) = std::env::var_os("CT_BIN") {
        let p = PathBuf::from(env);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Some(p) = which("ct") {
        return Some(p);
    }
    which("replay-server")
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

        let binary = LanguageProbe::expected_binary(language);
        let mut cmd = Command::new(binary);
        match language {
            Language::Python => {
                cmd.arg("--out-dir")
                    .arg(trace_dir)
                    .arg("--")
                    .arg(program_path);
            }
            Language::CPlusPlus | Language::C | Language::Rust => {
                // `ct-native-replay record -o <out> -- <program>` —
                // see tests/fixtures/origin/cpp/*/regenerate.sh.
                cmd.arg("record")
                    .arg("-o")
                    .arg(trace_dir)
                    .arg("--")
                    .arg(program_path);
            }
            Language::Ruby | Language::JavaScript | Language::Nim | Language::Go => {
                cmd.arg("--out-dir")
                    .arg(trace_dir)
                    .arg("--")
                    .arg(program_path);
            }
            Language::Cairo | Language::Solana => {
                cmd.arg("record")
                    .arg("--out-dir")
                    .arg(trace_dir)
                    .arg(program_path);
            }
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
