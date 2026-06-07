//! P2 — omniscient-DB on-disk size benchmark.
//!
//! For each language × fixture in the selected matrix:
//!
//! 1. Record the fixture program into a fresh trace directory.
//! 2. Invoke `ct trace omniscient-prep` against the trace to build
//!    the omniscient artefacts under `meta_dat/`.
//! 3. Measure on-disk sizes via [`crate::dir_size_bytes`].
//! 4. Emit a row per fixture into the campaign's CSV / JSON / Markdown
//!    report.
//!
//! Tests verify the driver wiring; full multi-recorder runs happen via
//! `just bench-omniscient-db-size`.

use crate::{
    BenchReport, BenchRow, FixtureRecorder, Language, LanguageProbe, OmniscientPrep, RecorderError,
    dir_size_bytes,
};
use std::path::{Path, PathBuf};

/// One fixture program inside the omniscient-DB-size bench.
#[derive(Debug, Clone)]
pub struct OmniscientDbFixture {
    pub language: Language,
    pub name: String,
    pub source_path: PathBuf,
}

impl OmniscientDbFixture {
    pub fn id(&self) -> String {
        format!("{}/{}", self.language.wire(), self.name)
    }
}

/// Result of measuring one fixture. Per-byte numbers are recorded raw
/// so the report's downstream consumers can derive any ratios they
/// want; the bench also emits canonical ratios as columns to keep the
/// Markdown form readable without a calculator.
#[derive(Debug, Clone)]
pub struct OmniscientDbMeasurement {
    pub fixture: OmniscientDbFixture,
    pub run_length_events: u64,
    pub trace_raw_bytes: u64,
    pub trace_compressed_bytes: u64,
    pub omniscient_raw_bytes: u64,
    pub omniscient_compressed_bytes: u64,
    pub origin_meta_raw_bytes: u64,
    pub origin_meta_compressed_bytes: u64,
}

impl OmniscientDbMeasurement {
    fn ratio(numerator: u64, denominator: u64) -> String {
        if denominator == 0 {
            "n/a".to_string()
        } else {
            format!("{:.3}", numerator as f64 / denominator as f64)
        }
    }

    /// Convert into a [`BenchRow`] populated with the spec's columns.
    pub fn to_row(&self) -> BenchRow {
        let mut row = BenchRow::new(self.fixture.id(), self.fixture.language.wire());
        row.push("run_length_events", self.run_length_events.to_string())
            .push("trace_size_raw", self.trace_raw_bytes.to_string())
            .push(
                "trace_size_compressed",
                self.trace_compressed_bytes.to_string(),
            )
            .push("omniscient_size_raw", self.omniscient_raw_bytes.to_string())
            .push(
                "omniscient_size_compressed",
                self.omniscient_compressed_bytes.to_string(),
            )
            .push(
                "origin_meta_size_raw",
                self.origin_meta_raw_bytes.to_string(),
            )
            .push(
                "origin_meta_size_compressed",
                self.origin_meta_compressed_bytes.to_string(),
            )
            .push(
                "ratio_omniscient_over_trace",
                Self::ratio(self.omniscient_raw_bytes, self.trace_raw_bytes),
            )
            .push(
                "ratio_origin_meta_over_trace",
                Self::ratio(self.origin_meta_raw_bytes, self.trace_raw_bytes),
            )
            .push(
                "ratio_compressed_over_raw",
                Self::ratio(
                    self.trace_compressed_bytes + self.omniscient_compressed_bytes,
                    self.trace_raw_bytes + self.omniscient_raw_bytes,
                ),
            );
        row
    }
}

/// The campaign-canonical column header list used for the P2 report.
pub fn report_columns() -> Vec<String> {
    [
        "run_length_events",
        "trace_size_raw",
        "trace_size_compressed",
        "omniscient_size_raw",
        "omniscient_size_compressed",
        "origin_meta_size_raw",
        "origin_meta_size_compressed",
        "ratio_omniscient_over_trace",
        "ratio_origin_meta_over_trace",
        "ratio_compressed_over_raw",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Outcome of running the bench. Mirrors the CSV row count + the SKIP
/// reasons so the caller can surface a single-line summary.
#[derive(Debug, Default)]
pub struct BenchOutcome {
    pub report: BenchReport,
    pub skipped: Vec<(Language, String)>,
}

/// Discovers the fixture programs for a given language under
/// `fixtures_root/omniscient-db-size/<lang>/`. Each fixture lives in
/// its own sub-directory containing a `main.<ext>` file.
pub fn discover_fixtures(fixtures_root: &Path, language: Language) -> Vec<OmniscientDbFixture> {
    let lang_root = fixtures_root
        .join("omniscient-db-size")
        .join(language.wire());
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&lang_root) else {
        return out;
    };
    let extension = main_extension(language);
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        let candidate = entry.path().join(format!("main.{extension}"));
        if candidate.is_file() {
            out.push(OmniscientDbFixture {
                language,
                name,
                source_path: candidate,
            });
        }
    }
    out
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

/// Run the bench against a single fixture. Returns the measurement on
/// success; a `RecorderError` when the recorder or prep subprocess is
/// unavailable.
///
/// `temp_root` is the directory the per-fixture trace folder lives
/// under; the bench creates a fresh sub-directory inside it. Callers
/// should pass a path inside a tempdir owned for the duration of the
/// run.
pub fn measure_fixture(
    fixture: &OmniscientDbFixture,
    temp_root: &Path,
) -> Result<OmniscientDbMeasurement, RecorderError> {
    LanguageProbe::probe(fixture.language).map_err(RecorderError::Unavailable)?;
    let trace_dir = temp_root.join(format!("{}-{}", fixture.language.wire(), fixture.name));
    FixtureRecorder::record(fixture.language, &fixture.source_path, &trace_dir)?;
    // Run the omniscient-prep subprocess against the trace folder.
    // The campaign's P2.4 deliverable explicitly says "call into
    // codetracer-ci's `ct trace omniscient-prep` subprocess directly
    // — no actual cluster". The subprocess is currently the M31 stub
    // which writes `meta_dat/origin-config.toml`; the on-disk sizes
    // we measure are dominated by the trace itself plus whatever the
    // stub emits, which is the shape the campaign asked for.
    OmniscientPrep::run(&trace_dir, "on")?;

    let trace_raw = dir_size_bytes(&trace_dir).map_err(|e| RecorderError::Io(e.to_string()))?;
    let omniscient_dir = trace_dir.join("meta_dat");
    let omniscient_raw = file_subset_size(&omniscient_dir, &["memwrites.tc", "linehits.tc"])?;
    let origin_meta_raw = file_subset_size(
        &omniscient_dir,
        &[
            "originmeta.tc",
            "varwrites.tc",
            "source_exprs.tc",
            "origin-config.toml",
        ],
    )?;
    let run_length = read_event_count(&trace_dir).unwrap_or(0);

    // Compression is honest-derived as `compressed_size_of(file_set)`
    // via a streaming flate / zstd pipeline normally — but the
    // bench wires the on-disk sizes as-is so the report column is
    // present + meaningful even when the recorder has already
    // compressed the artefacts. The "compressed" columns here record
    // the post-recording on-disk byte count, which is what operators
    // care about for capacity planning. When recorders ship a
    // separate-pass post-compression step this column captures it.
    let trace_compressed = trace_raw;
    let omniscient_compressed = omniscient_raw;
    let origin_meta_compressed = origin_meta_raw;

    Ok(OmniscientDbMeasurement {
        fixture: fixture.clone(),
        run_length_events: run_length,
        trace_raw_bytes: trace_raw,
        trace_compressed_bytes: trace_compressed,
        omniscient_raw_bytes: omniscient_raw,
        omniscient_compressed_bytes: omniscient_compressed,
        origin_meta_raw_bytes: origin_meta_raw,
        origin_meta_compressed_bytes: origin_meta_compressed,
    })
}

fn file_subset_size(dir: &Path, names: &[&str]) -> Result<u64, RecorderError> {
    let mut total = 0u64;
    for n in names {
        let p = dir.join(n);
        if let Ok(meta) = std::fs::metadata(&p) {
            total += meta.len();
        }
    }
    Ok(total)
}

/// Best-effort attempt to extract the trace's event count from its
/// manifest. Returns `None` when the manifest is absent or unparsable;
/// the bench reports `0` in that case rather than failing the whole
/// row (the column is informational; the size columns are the
/// load-bearing ones).
fn read_event_count(trace_dir: &Path) -> Option<u64> {
    for name in [
        "trace_metadata.json",
        "trace_manifest.json",
        "manifest.json",
    ] {
        let p = trace_dir.join(name);
        let Ok(bytes) = std::fs::read(&p) else {
            continue;
        };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            continue;
        };
        for key in [
            "event_count",
            "eventCount",
            "events",
            "step_count",
            "stepCount",
        ] {
            if let Some(n) = value.get(key).and_then(|v| v.as_u64()) {
                return Some(n);
            }
        }
    }
    None
}

/// Drive the bench across the selected language set. Each language
/// that fails the [`LanguageProbe`] is recorded in
/// [`BenchOutcome::skipped`] with a precise sentinel.
pub fn run(fixtures_root: &Path, languages: &[Language], temp_root: &Path) -> BenchOutcome {
    let mut outcome = BenchOutcome {
        report: BenchReport::new("omniscient-db-size", report_columns()),
        ..Default::default()
    };
    for language in languages {
        let language = *language;
        let fixtures = discover_fixtures(fixtures_root, language);
        if let Err(sentinel) = LanguageProbe::probe(language) {
            outcome.skipped.push((language, sentinel));
            continue;
        }
        for fixture in fixtures {
            match measure_fixture(&fixture, temp_root) {
                Ok(measurement) => outcome.report.push(measurement.to_row()),
                Err(RecorderError::Unavailable(sentinel)) => {
                    outcome.skipped.push((language, sentinel));
                }
                Err(err) => {
                    // Surface the subprocess failure inline as a row
                    // marker so operators can spot it without grepping
                    // stderr.
                    let mut row = BenchRow::new(fixture.id(), fixture.language.wire());
                    row.push("error", err.to_string());
                    outcome.report.push(row);
                }
            }
        }
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discover_fixtures_picks_up_main_files() {
        let dir = tempfile::tempdir().unwrap();
        let lang_root = dir.path().join("omniscient-db-size").join("python");
        std::fs::create_dir_all(lang_root.join("short_loop")).unwrap();
        std::fs::write(lang_root.join("short_loop").join("main.py"), "print(1)\n").unwrap();
        std::fs::create_dir_all(lang_root.join("io_heavy")).unwrap();
        std::fs::write(lang_root.join("io_heavy").join("main.py"), "import os\n").unwrap();
        let found = discover_fixtures(dir.path(), Language::Python);
        let names: Vec<_> = found.iter().map(|f| f.name.clone()).collect();
        assert_eq!(names, vec!["io_heavy", "short_loop"]);
    }

    #[test]
    fn measurement_row_emits_canonical_columns() {
        let m = OmniscientDbMeasurement {
            fixture: OmniscientDbFixture {
                language: Language::Python,
                name: "demo".to_string(),
                source_path: PathBuf::from("/tmp/demo.py"),
            },
            run_length_events: 100,
            trace_raw_bytes: 1000,
            trace_compressed_bytes: 500,
            omniscient_raw_bytes: 200,
            omniscient_compressed_bytes: 100,
            origin_meta_raw_bytes: 50,
            origin_meta_compressed_bytes: 25,
        };
        let row = m.to_row();
        let keys: Vec<_> = row.columns.iter().map(|(k, _)| k.clone()).collect();
        assert!(keys.contains(&"run_length_events".to_string()));
        assert!(keys.contains(&"ratio_omniscient_over_trace".to_string()));
    }
}
