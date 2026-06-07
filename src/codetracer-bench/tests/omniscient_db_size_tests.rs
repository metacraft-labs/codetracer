//! P2 verification — 4 tests.
//!
//! Each test verifies the bench infrastructure, not the recorder's
//! actual on-disk size output. The recorder is invoked when on PATH;
//! otherwise the test SKIPs with a narrow sentinel per the M3
//! SKIP-discipline review.

use codetracer_bench::{Language, omniscient_db_size};
use std::path::PathBuf;

fn fixtures_root() -> PathBuf {
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.join("fixtures")
}

fn skip(reason: &str) {
    // Inconclusive-style SKIP: print + return so `cargo test` records
    // the test as passing while the message names the missing
    // dependency. Mirrors the M3 / M5 / M11 SKIP discipline.
    eprintln!("SKIPPED: {reason}");
}

#[test]
fn default_python_cpp_fixtures_run_to_completion() {
    // Probe both recorders; SKIP narrowly when either is missing.
    let python = codetracer_bench::LanguageProbe::probe(Language::Python);
    let cpp = codetracer_bench::LanguageProbe::probe(Language::CPlusPlus);
    if let Err(s) = &python {
        skip(&format!("Python recorder unavailable — {s}"));
        return;
    }
    if let Err(s) = &cpp {
        skip(&format!("C++ recorder unavailable — {s}"));
        return;
    }
    if codetracer_bench::ct_binary().is_none() {
        skip("ct binary not on PATH — needed for omniscient-prep subprocess");
        return;
    }
    let temp = tempfile::tempdir().expect("tempdir");
    let outcome = omniscient_db_size::run(&fixtures_root(), &Language::default_set(), temp.path());
    // Expect 6 rows (3 fixtures × 2 languages). Surface SKIP cleanly
    // when fewer rows land — e.g. one fixture failed to record.
    assert!(
        outcome.report.rows.len() >= 6,
        "expected >= 6 rows, got {}",
        outcome.report.rows.len(),
    );
}

#[test]
fn wider_fixture_set_via_languages_flag() {
    // Narrow to a single language. SKIPs per-language when missing.
    let language = Language::Python;
    if let Err(s) = codetracer_bench::LanguageProbe::probe(language) {
        skip(&format!("Python recorder unavailable — {s}"));
        return;
    }
    if codetracer_bench::ct_binary().is_none() {
        skip("ct binary not on PATH");
        return;
    }
    let temp = tempfile::tempdir().expect("tempdir");
    let outcome = omniscient_db_size::run(&fixtures_root(), &[language], temp.path());
    assert!(
        outcome.report.rows.len() >= 3,
        "expected >= 3 Python rows, got {}",
        outcome.report.rows.len(),
    );
}

#[test]
fn all_languages_flag_runs_full_matrix() {
    // The function itself runs the full matrix; per-language SKIPs
    // get collected in outcome.skipped without aborting the run.
    let temp = tempfile::tempdir().expect("tempdir");
    if codetracer_bench::ct_binary().is_none() {
        skip("ct binary not on PATH");
        return;
    }
    let outcome = omniscient_db_size::run(&fixtures_root(), &Language::all(), temp.path());
    // Every language is either represented in the report or recorded
    // as skipped. There must be no language that was silently dropped.
    let mut represented: std::collections::HashSet<String> = Default::default();
    for row in &outcome.report.rows {
        represented.insert(row.language.clone());
    }
    for (lang, _) in &outcome.skipped {
        represented.insert(lang.wire().to_string());
    }
    for lang in Language::all() {
        assert!(
            represented.contains(lang.wire()),
            "language {} was neither measured nor skipped",
            lang.wire(),
        );
    }
}

#[test]
fn report_emitted_in_csv_json_markdown() {
    // Synthetic report — verifies the three formats land under the
    // bench output directory regardless of recorder availability.
    let temp = tempfile::tempdir().expect("tempdir");
    // Safety: this test is the only writer of the env var inside its
    // own lifetime; cargo runs tests on multiple threads but each
    // test owns a unique tempdir, so the env var read by
    // bench_output_dir is mirrored by the writer here.
    let out_root = temp.path().join("out");
    unsafe {
        std::env::set_var("CODETRACER_BENCH_OUT", &out_root);
    }
    let mut report = codetracer_bench::BenchReport::new(
        "omniscient-db-size",
        omniscient_db_size::report_columns(),
    );
    let mut row = codetracer_bench::BenchRow::new("python/demo", "python");
    row.push("run_length_events", "100")
        .push("trace_size_raw", "1024");
    report.push(row);
    let dir = codetracer_bench::write_report(&report).expect("write");
    assert!(dir.join("report.csv").exists(), "csv missing");
    assert!(dir.join("report.json").exists(), "json missing");
    assert!(dir.join("report.md").exists(), "md missing");
    let md = std::fs::read_to_string(dir.join("report.md")).expect("read md");
    assert!(md.contains("# omniscient-db-size"));
    assert!(md.contains("python/demo"));
    unsafe {
        std::env::remove_var("CODETRACER_BENCH_OUT");
    }
}
