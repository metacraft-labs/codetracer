//! P2 verification — 4 tests.
//!
//! Each test verifies the bench infrastructure, not the recorder's
//! actual on-disk size output.  When the dev shell lacks the `ct` CLI
//! (which fronts `ct record`) or the db-backend `replay-server` (which
//! provides `ct trace omniscient-prep`), the test SKIPs with a narrow
//! sentinel per the M3 SKIP-discipline review.
//!
//! Post-P9.1: language-specific recorder probes are gone.  The bench
//! routes every recording through `ct record`, which surfaces precise
//! per-language errors itself; the test layer just confirms that the
//! shared infrastructure (the CLI binaries) is reachable and lets
//! `ct record` report any deeper environment failure as a row-level
//! error.

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
    // Gate on the two binaries the bench shells out to: `ct record`
    // (the recording side) and `replay-server`-style `ct` (the
    // omniscient-prep side).  Per-language toolchain probes live
    // inside `ct record` now, not in the bench.
    if codetracer_bench::ct_cli_binary().is_none() {
        skip("ct CLI not discoverable — needed for ct record");
        return;
    }
    if codetracer_bench::ct_binary().is_none() {
        skip("ct binary not on PATH — needed for omniscient-prep subprocess");
        return;
    }
    let temp = tempfile::tempdir().expect("tempdir");
    let outcome = omniscient_db_size::run(&fixtures_root(), &Language::default_set(), temp.path());
    // The bench's contract here is wiring-correctness.  Each
    // discovered fixture produces a row in `outcome.report` (whether
    // the recording succeeded or the row carries an `error` column);
    // languages without any discovered fixtures land in
    // `outcome.skipped`.  With 3 fixtures per language × 2 languages
    // = 6 fixtures the combined count should reach 6 — or, if a
    // language's fixtures directory is missing entirely, the
    // `skipped` bucket gains an entry per language.
    let total_buckets = outcome.report.rows.len() + outcome.skipped.len();
    assert!(
        total_buckets >= 6,
        "expected >= 6 entries across the default Python (3 fixtures) + C++ \
         (3 fixtures) matrix — rows + skipped should cover every fixture; \
         got {total_buckets}; rows = {:?}, skipped = {:?}",
        outcome.report.rows.len(),
        outcome.skipped,
    );
}

#[test]
fn wider_fixture_set_via_languages_flag() {
    // Narrow to a single language.  Same gating as above — `ct record`
    // surfaces the per-language SKIP sentinel.
    let language = Language::Python;
    if codetracer_bench::ct_cli_binary().is_none() {
        skip("ct CLI not discoverable");
        return;
    }
    if codetracer_bench::ct_binary().is_none() {
        skip("ct binary not on PATH");
        return;
    }
    let temp = tempfile::tempdir().expect("tempdir");
    let outcome = omniscient_db_size::run(&fixtures_root(), &[language], temp.path());
    let total = outcome.report.rows.len() + outcome.skipped.len();
    assert!(
        total >= 3,
        "expected >= 3 entries for the Python-only matrix (3 fixtures, each \
         producing either a row or a skip); got {total}; rows = {:?}, \
         skipped = {:?}",
        outcome.report.rows.len(),
        outcome.skipped,
    );
}

#[test]
fn all_languages_flag_runs_full_matrix() {
    // The function itself runs the full matrix; per-language SKIPs
    // get collected in outcome.skipped without aborting the run.
    let temp = tempfile::tempdir().expect("tempdir");
    if codetracer_bench::ct_cli_binary().is_none() {
        skip("ct CLI not discoverable");
        return;
    }
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
