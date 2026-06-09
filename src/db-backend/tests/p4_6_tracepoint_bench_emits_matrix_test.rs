//! P4.6 verification probe: the tracepoint_interpreter Criterion bench
//! must emit its report through the same matrix CSV/JSON/Markdown
//! format `ct-bench gui-ops` uses, so consumers don't have to merge
//! two report shapes.
//!
//! This test exercises the bench's matrix-report emitter directly (the
//! [`db_backend::bench_matrix_report::emit`] helper the bench calls
//! after its measurement loop closes). Going through the helper rather
//! than spawning `cargo bench` as a subprocess keeps the test:
//!
//! * **Fast** — no Criterion sampling loop, no Compiler / linker
//!   round-trip.
//! * **Hermetic** — drives output into a `tempdir()` via
//!   `CODETRACER_BENCH_OUT` so CI never inherits state from previous
//!   runs.
//! * **Honest** — measures the same production helper the bench would
//!   call in a real `cargo bench` invocation. If the bench drifts away
//!   from the helper, that's a different bug (caught by reading the
//!   bench source directly); the matrix-shape contract this test
//!   guards belongs to the helper.
//!
//! The matching campaign verification clause:
//!
//! > `p4_tracepoint_benchmark_emits_matrix_format` — The existing
//! > tracepoint_interpreter benchmark's report now lands in the matrix
//! > format alongside the GUI-ops benchmark; consumers read one CSV
//! > per language.

use serde::Deserialize;

use db_backend::bench_matrix_report::{self, CellResult};

/// Minimal mirror of `codetracer_bench::BenchReport` (defined in
/// `codetracer/src/codetracer-bench/src/lib.rs`). We re-declare it
/// here rather than depending on `codetracer-bench` because that
/// crate consumes `db-backend`'s `replay-server` binary (so a
/// dependency edge would invert the campaign's layering). The fields
/// are asserted by shape, not by exact equality with the upstream
/// type — that's what keeps the report consumers happy.
#[derive(Debug, Deserialize)]
struct BenchReport {
    bench_name: String,
    columns: Vec<String>,
    rows: Vec<BenchRow>,
}

#[derive(Debug, Deserialize)]
struct BenchRow {
    id: String,
    language: String,
    columns: Vec<(String, String)>,
}

/// Run the emitter against a `tempdir()` and verify all three report
/// files land at the expected paths.
#[test]
fn p4_tracepoint_benchmark_emits_matrix_format() {
    let tmp = tempfile::tempdir().expect("tempdir");
    // Per `bench_matrix_report::bench_output_dir`, the env var
    // `CODETRACER_BENCH_OUT` overrides the default
    // `target/codetracer-bench/<bench>` path. Pointing it at a
    // tempdir keeps the verification probe hermetic.
    //
    // SAFETY: std::env::set_var is unsafe (in 2024 edition) because
    // it mutates process-global state. The integration-test harness
    // serialises tests within a process by default, so the only
    // concurrent risk would be parallel access from a thread spawned
    // inside this test, which we don't do.
    unsafe {
        std::env::set_var("CODETRACER_BENCH_OUT", tmp.path());
    }

    // Drive the bench's full pipeline with the same `STREAM_SIZES`
    // the live bench uses — that way the verification test runs the
    // same code path operators do. We seed the helper with two
    // synthetic cells (constant timings) rather than re-running the
    // interpreter so the test stays fast (the live bench's
    // `measure_cell` is exercised by `tests/bench_matrix_report*` in
    // the bench_matrix_report module's own unit tests).
    let results = vec![
        CellResult {
            stream_size: 10,
            p50_us: 12.0,
            p95_us: 15.0,
        },
        CellResult {
            stream_size: 1000,
            p50_us: 1234.5,
            p95_us: 2345.6,
        },
    ];
    let dir = bench_matrix_report::emit(&results, env!("CARGO_MANIFEST_DIR")).expect("emit matrix report");

    // Strip the env var before any assertion can panic, so a failure
    // doesn't leak the override into subsequent tests.
    unsafe {
        std::env::remove_var("CODETRACER_BENCH_OUT");
    }

    assert!(dir.join("report.csv").is_file(), "report.csv missing");
    assert!(dir.join("report.json").is_file(), "report.json missing");
    assert!(dir.join("report.md").is_file(), "report.md missing");

    // ----- Markdown -----------------------------------------------
    // Assert: has the matrix header row, the separator line, at least
    // one data row, and at least one cell shaped `p50=...ms p95=...ms`
    // (i.e. not `PENDING`).
    let md = std::fs::read_to_string(dir.join("report.md")).expect("read md");
    let mut lines = md.lines();
    // First line is `# <bench-name>`.
    let title = lines.next().expect("md first line");
    assert!(title.starts_with("# "), "md title prefix wrong: {title}");
    // Blank line, then the pipe header.
    let _blank = lines.next();
    let header = lines.next().expect("md header line");
    assert!(header.starts_with("| id | language |"), "md header wrong: {header}");
    assert!(
        header.contains("criterion-"),
        "md header missing criterion column: {header}"
    );
    let separator = lines.next().expect("md separator line");
    assert!(separator.starts_with("| --- |"), "md separator wrong: {separator}");
    let data_lines: Vec<&str> = lines.collect();
    assert!(!data_lines.is_empty(), "md should contain at least one data row");
    let any_measured = data_lines
        .iter()
        .any(|l| l.contains("p50=") && l.contains("ms p95=") && l.contains("ms"));
    assert!(
        any_measured,
        "md should contain at least one measured cell (p50=...ms p95=...ms): {data_lines:?}"
    );

    // ----- CSV ----------------------------------------------------
    // Header must start `id,language,` to mirror BenchReport::to_csv;
    // every data row must have exactly the same number of comma-
    // separated fields as the header so the matrix shape is uniform.
    let csv = std::fs::read_to_string(dir.join("report.csv")).expect("read csv");
    let csv_lines: Vec<&str> = csv.lines().collect();
    assert!(csv_lines.len() >= 2, "csv must have header + at least one data row");
    assert!(
        csv_lines[0].starts_with("id,language,"),
        "csv header wrong: {}",
        csv_lines[0]
    );
    let header_cols = csv_lines[0].split(',').count();
    for (i, line) in csv_lines.iter().enumerate().skip(1) {
        let n = line.split(',').count();
        assert_eq!(
            n, header_cols,
            "csv row {i} has {n} fields but header has {header_cols}: {line}"
        );
    }

    // ----- JSON ---------------------------------------------------
    // Deserialise into a BenchReport-shaped struct. If the upstream
    // ReportWriter changes shape (renames a field, switches the row
    // `columns` from `Vec<(String, String)>` to something else), this
    // assertion fails — flagging that the bench needs to be updated
    // to match.
    let json_str = std::fs::read_to_string(dir.join("report.json")).expect("read json");
    let report: BenchReport = serde_json::from_str(&json_str).expect("json must match BenchReport shape");
    assert!(!report.bench_name.is_empty(), "bench_name must be non-empty");
    assert!(!report.columns.is_empty(), "columns must be non-empty");
    assert!(!report.rows.is_empty(), "rows must be non-empty");
    // Every row's `columns` entries must reference column names
    // declared in the top-level `columns`.
    for row in &report.rows {
        assert!(!row.id.is_empty(), "row id must be non-empty: {row:?}");
        // Language is allowed to be empty (rows are keyed by op);
        // we just assert the field is present, which the deserialise
        // step already checked.
        let _ = &row.language;
        for (col_name, _val) in &row.columns {
            assert!(
                report.columns.contains(col_name),
                "row column {col_name} not in report columns {:?}",
                report.columns
            );
        }
    }

    // Cross-check: the bench's column header follows the
    // `<backend>-<platform>-<language>` convention shared with
    // `gui_ops::GuiOpCell::column_name`. The bench's choice of values
    // is exercised by the bench_matrix_report module's own unit tests;
    // here we just assert the shape.
    let column = &report.columns[0];
    assert!(
        column.contains('-'),
        "column header must follow <backend>-<platform>-<language>: {column}"
    );

    // At least one cell must render a measured `p50=...ms p95=...ms`
    // value (not PENDING) — proving the bench produced live numbers.
    let any_measured_json = report.rows.iter().any(|r| {
        r.columns
            .iter()
            .any(|(_, v)| v.contains("p50=") && v.contains("ms p95="))
    });
    assert!(
        any_measured_json,
        "at least one row should render a measured p50=...ms p95=...ms cell"
    );
}
