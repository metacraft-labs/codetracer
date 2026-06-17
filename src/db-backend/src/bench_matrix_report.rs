//! Matrix-format CSV / JSON / Markdown emitter for the
//! `tracepoint_interpreter` Criterion bench (P4.6 / P9.2).
//!
//! The shape mirrors `codetracer_bench::BenchReport` (the writer
//! `ct-bench gui-ops` and `ct-bench omniscient-db-size` use) so
//! consumers don't have to merge two report shapes when comparing the
//! tracepoint hot path against the GUI-op latencies. We re-implement
//! the bytes here rather than depending on `codetracer-bench` because:
//!
//! 1. `codetracer-bench` is a standalone crate that pulls in the full
//!    DAP driver / recorder harness — a dependency edge from
//!    `db-backend` to it would invert the campaign's layering
//!    (`codetracer-bench` consumes `db-backend`'s `replay-server`
//!    binary, not the other way around).
//! 2. The writer's surface is tiny — 50 lines of CSV / JSON / Markdown
//!    — and re-implementing it here lets the bench live entirely
//!    inside the db-backend crate (matching the campaign brief, which
//!    locates the bench at `src/db-backend/benches/`).
//!
//! The format is asserted byte-for-byte against the gui-ops writer in
//! `tests/p4_6_tracepoint_bench_emits_matrix_test.rs` so any drift in
//! `codetracer_bench::BenchReport` will surface as a test failure.

use std::fmt::Write as _;
use std::path::PathBuf;

/// Per-row measurement the bench emits. `p50_us` and `p95_us` are
/// **microseconds**; the renderer converts to milliseconds (with three
/// decimal places of precision) so the cell content matches the
/// `p50=Xms p95=Yms` shape `gui_ops::GuiOpCell::render` produces.
#[derive(Debug, Clone)]
pub struct CellResult {
    pub stream_size: usize,
    pub p50_us: f64,
    pub p95_us: f64,
}

/// Bench name. Used both as the output sub-directory name (so the
/// report lands at `target/codetracer-bench/tracepoint-interpreter/`)
/// and as the Markdown report title.
pub const BENCH_NAME: &str = "tracepoint-interpreter";

/// Resolve the bench's output directory. Mirrors
/// `codetracer_bench::bench_output_dir`: honours
/// `$CODETRACER_BENCH_OUT/<bench-name>` for tests; defaults to
/// `<manifest-dir>/target/codetracer-bench/<bench-name>/`.
///
/// `manifest_dir` is intended to be `env!("CARGO_MANIFEST_DIR")` from
/// the bench or test caller (the bench file substitutes its own
/// `env!`, the integration test passes a `tempdir().path()` to keep CI
/// hermetic).
pub fn bench_output_dir(manifest_dir: &str) -> PathBuf {
    if let Some(env) = std::env::var_os("CODETRACER_BENCH_OUT") {
        PathBuf::from(env).join(BENCH_NAME)
    } else {
        PathBuf::from(manifest_dir)
            .join("target")
            .join("codetracer-bench")
            .join(BENCH_NAME)
    }
}

/// Column header for this bench's single measured column.
/// Format `<backend>-<platform>-<language>` — same shape as
/// `gui_ops::GuiOpCell::column_name` — so consumers can collate the
/// matrix rows alongside the gui-ops cells without ad-hoc parsing.
///
/// * `<backend>` is the literal `criterion`: the tracepoint
///   interpreter measurement isn't attributable to any of the
///   recording backends Backend::all() covers; this is a direct
///   evaluator microbench, not a wire round-trip through a backend.
/// * `<platform>` is `std::env::consts::OS` (`linux` / `macos` /
///   `windows`).
/// * `<language>` is the literal `(synthetic)` — the tracepoint
///   expression language is language-agnostic at the evaluator
///   surface.
pub fn matrix_column_name() -> String {
    format!("criterion-{}-(synthetic)", std::env::consts::OS)
}

/// Render a per-cell result in the same `p50=Xms p95=Yms` shape
/// `gui_ops::GuiOpCell::render` produces. Three decimal places of
/// precision because the interpreter is fast enough that millisecond
/// rounding loses signal; the gui-ops writer uses two decimal places
/// at higher absolute durations, but the format itself is still
/// `p50=...ms p95=...ms`.
pub fn render_cell(c: &CellResult) -> String {
    format!("p50={:.3}ms p95={:.3}ms", c.p50_us / 1000.0, c.p95_us / 1000.0,)
}

/// Row id for the given stream size. Format
/// `tracepoint-eval-N=<stream-size>` so the row name encodes which
/// synthetic-stream length the cell measured.
pub fn row_id(stream_size: usize) -> String {
    format!("tracepoint-eval-N={}", stream_size)
}

/// Emit the matrix report (CSV + JSON + Markdown) under
/// [`bench_output_dir`].  Returns the directory the files landed in
/// so callers can surface it to the user (the bench prints this on
/// completion).
pub fn emit(results: &[CellResult], manifest_dir: &str) -> std::io::Result<PathBuf> {
    let dir = bench_output_dir(manifest_dir);
    std::fs::create_dir_all(&dir)?;
    let column = matrix_column_name();

    // CSV — `id,language,<column>` header + one row per cell.
    // Matches `BenchReport::to_csv` byte-for-byte (header columns,
    // empty language column, escape rules).
    let mut csv = String::new();
    csv.push_str("id,language");
    csv.push(',');
    csv.push_str(&csv_escape(&column));
    csv.push('\n');
    for r in results {
        csv.push_str(&csv_escape(&row_id(r.stream_size)));
        csv.push(',');
        // Empty language column — same convention as gui-ops, where
        // the row id encodes the operation and the language is folded
        // into the column header so the rows stay language-agnostic.
        csv.push(',');
        csv.push_str(&csv_escape(&render_cell(r)));
        csv.push('\n');
    }
    std::fs::write(dir.join("report.csv"), csv)?;

    // JSON — same shape as `BenchReport`: bench_name, columns,
    // rows: [{ id, language, columns: [[<col>, <val>], ...] }, ...].
    // We use plain `serde_json::json!` rather than pulling in the
    // codetracer_bench crate (see module doc-comment for the
    // rationale).
    let json = serde_json::json!({
        "bench_name": BENCH_NAME,
        "columns": [column.clone()],
        "rows": results.iter().map(|r| serde_json::json!({
            "id": row_id(r.stream_size),
            "language": "",
            "columns": [[column.clone(), render_cell(r)]],
        })).collect::<Vec<_>>(),
    });
    std::fs::write(dir.join("report.json"), serde_json::to_string_pretty(&json)?)?;

    // Markdown — header / separator / row format matches
    // `BenchReport::to_markdown`. Title prefix `# ` + blank line +
    // pipe-separated header + `| --- | --- | --- |` separator +
    // pipe-separated rows.
    let mut md = String::new();
    writeln!(md, "# {}", BENCH_NAME).ok();
    md.push('\n');
    md.push_str("| id | language | ");
    md.push_str(&md_escape(&column));
    md.push_str(" |\n");
    md.push_str("| --- | --- | --- |\n");
    for r in results {
        md.push_str("| ");
        md.push_str(&md_escape(&row_id(r.stream_size)));
        md.push_str(" |  | ");
        md.push_str(&md_escape(&render_cell(r)));
        md.push_str(" |\n");
    }
    std::fs::write(dir.join("report.md"), md)?;

    Ok(dir)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // ``emit_writes_csv_json_md`` and ``csv_header_matches_gui_ops_shape``
    // both mutate the process-global ``CODETRACER_BENCH_OUT`` env var,
    // and Rust's default test harness runs ``#[test]`` functions in
    // parallel — when both grab the lock at once, one test's
    // ``remove_var`` clears the other's ``set_var`` mid-emit, the
    // fallback path ``manifest_dir/target/codetracer-bench/...`` is
    // read-only under the Nix build sandbox, ``fs::write`` returns
    // ``NotFound``, and ``.expect("emit")`` panics (observed
    // intermittently against codetracer dev's cross-repo CI, e.g.
    // cross-repo run 27658362322).  Serialise the env-var-touching
    // tests with a module-local mutex so they take the variable
    // turn-by-turn.
    static BENCH_OUT_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn column_name_has_three_dash_separated_segments() {
        let name = matrix_column_name();
        // The matrix column convention is <backend>-<platform>-<language>.
        // The synthetic language is wrapped in parens so the segment
        // count is exactly three even though "(synthetic)" contains
        // no dashes.
        assert!(name.starts_with("criterion-"));
        assert!(name.ends_with("-(synthetic)"));
    }

    #[test]
    fn render_cell_uses_p50_p95_ms_shape() {
        let cell = CellResult {
            stream_size: 100,
            p50_us: 1234.0,
            p95_us: 5678.0,
        };
        let rendered = render_cell(&cell);
        assert!(rendered.starts_with("p50="));
        assert!(rendered.contains("ms p95="));
        assert!(rendered.ends_with("ms"));
    }

    #[test]
    fn emit_writes_csv_json_md() {
        let _guard = BENCH_OUT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().expect("tempdir");
        unsafe {
            std::env::set_var("CODETRACER_BENCH_OUT", tmp.path());
        }
        let results = vec![CellResult {
            stream_size: 10,
            p50_us: 100.0,
            p95_us: 200.0,
        }];
        let dir = emit(&results, env!("CARGO_MANIFEST_DIR")).expect("emit");
        assert!(dir.join("report.csv").is_file());
        assert!(dir.join("report.json").is_file());
        assert!(dir.join("report.md").is_file());
        unsafe {
            std::env::remove_var("CODETRACER_BENCH_OUT");
        }
    }

    #[test]
    fn csv_header_matches_gui_ops_shape() {
        // Cross-check against codetracer_bench::BenchReport::to_csv,
        // which emits `id,language,<col1>,<col2>,...` as the first
        // line.  The tracepoint bench has a single measured column
        // so the header is `id,language,<column>` — verifying the
        // prefix here keeps the two writers byte-compatible.
        let _guard = BENCH_OUT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempfile::tempdir().expect("tempdir");
        unsafe {
            std::env::set_var("CODETRACER_BENCH_OUT", tmp.path());
        }
        let results = vec![CellResult {
            stream_size: 42,
            p50_us: 1.0,
            p95_us: 2.0,
        }];
        let dir = emit(&results, env!("CARGO_MANIFEST_DIR")).expect("emit");
        let csv = std::fs::read_to_string(dir.join("report.csv")).expect("read csv");
        let first_line = csv.lines().next().expect("at least one line");
        assert!(first_line.starts_with("id,language,"));
        unsafe {
            std::env::remove_var("CODETRACER_BENCH_OUT");
        }
    }
}
