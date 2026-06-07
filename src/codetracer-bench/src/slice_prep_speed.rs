//! P3 — slice generation speed + concurrent processing speedup bench.
//!
//! Records the campaign's mid-length compute fixture into K slices for
//! K ∈ {1, 2, 4, 8, 16}, invokes `ct trace omniscient-prep` per slice
//! at concurrency C ∈ {1, 2, 4, 8}, and reports the per-slice +
//! coordinator wall-clock so operators can chart the
//! "near-zero-overhead" + "linear speedup" claims from the campaign
//! spec.
//!
//! The bench also exposes a synthetic in-process measurement path the
//! P3 tests use to verify the overhead-and-speedup computation logic
//! without needing a recorder on PATH.

use crate::{
    BenchReport, BenchRow, FixtureRecorder, Language, OmniscientPrep, RecorderError, dir_size_bytes,
};
use rayon::ThreadPoolBuilder;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// One row in the K-slice × C-concurrency matrix.
#[derive(Debug, Clone)]
pub struct SlicePrepCell {
    pub slice_count: usize,
    pub prep_concurrency: usize,
    pub per_slice_wall_clock_ms: f64,
    pub coordinator_wall_clock_ms: f64,
    pub total_wall_clock_ms: f64,
    pub trace_size_bytes: u64,
}

impl SlicePrepCell {
    pub fn to_row(&self) -> BenchRow {
        let mut row = BenchRow::new(
            format!(
                "slices={} concurrency={}",
                self.slice_count, self.prep_concurrency
            ),
            "",
        );
        row.push("slice_count", self.slice_count.to_string())
            .push("prep_concurrency", self.prep_concurrency.to_string())
            .push(
                "per_slice_wall_clock_ms",
                format!("{:.3}", self.per_slice_wall_clock_ms),
            )
            .push(
                "coordinator_wall_clock_ms",
                format!("{:.3}", self.coordinator_wall_clock_ms),
            )
            .push(
                "total_wall_clock_ms",
                format!("{:.3}", self.total_wall_clock_ms),
            )
            .push("trace_size_bytes", self.trace_size_bytes.to_string());
        row
    }
}

pub fn report_columns() -> Vec<String> {
    [
        "slice_count",
        "prep_concurrency",
        "per_slice_wall_clock_ms",
        "coordinator_wall_clock_ms",
        "total_wall_clock_ms",
        "trace_size_bytes",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Result of running the bench against a recorded fixture.
#[derive(Debug, Default)]
pub struct SlicePrepOutcome {
    pub report: BenchReport,
    pub cells: Vec<SlicePrepCell>,
    pub skip_reason: Option<String>,
}

/// Run the bench against a real recorder. The recorder's split-trace
/// surface isn't standardised across languages yet, so the driver
/// records the program N times (one trace per slice), invokes the
/// prep subprocess against each trace with the configured concurrency,
/// and times the per-slice + coordinator wall-clock independently.
///
/// When the recorder or the `ct` binary is missing the function
/// returns an outcome with [`SlicePrepOutcome::skip_reason`] set; the
/// tests SKIP narrowly off that signal.
pub fn run(
    language: Language,
    program_path: &Path,
    slice_counts: &[usize],
    prep_concurrencies: &[usize],
    temp_root: &Path,
) -> SlicePrepOutcome {
    let mut outcome = SlicePrepOutcome {
        report: BenchReport::new("slice-prep-speed", report_columns()),
        ..Default::default()
    };
    if let Err(sentinel) = crate::LanguageProbe::probe(language) {
        outcome.skip_reason = Some(sentinel);
        return outcome;
    }
    if crate::ct_binary().is_none() {
        outcome.skip_reason = Some("ct binary not on PATH".to_string());
        return outcome;
    }
    for &k in slice_counts {
        // Record the fixture k times, each into its own trace dir, to
        // simulate a K-slice recording.
        let mut slice_dirs: Vec<PathBuf> = Vec::with_capacity(k);
        for slice_idx in 0..k {
            let slice_dir = temp_root.join(format!("k{k}/slice-{slice_idx}"));
            match FixtureRecorder::record(language, program_path, &slice_dir) {
                Ok(p) => slice_dirs.push(p),
                Err(RecorderError::Unavailable(sentinel)) => {
                    outcome.skip_reason = Some(sentinel);
                    return outcome;
                }
                Err(err) => {
                    outcome.skip_reason = Some(format!("recorder failed: {err}"));
                    return outcome;
                }
            }
        }

        // Aggregate trace size across the slices.
        let trace_size = slice_dirs
            .iter()
            .map(|p| dir_size_bytes(p).unwrap_or(0))
            .sum::<u64>();

        for &concurrency in prep_concurrencies {
            // Skip the cell when concurrency exceeds k (no point
            // running 8 threads against 2 slices).
            let effective_concurrency = concurrency.min(k).max(1);
            let pool = ThreadPoolBuilder::new()
                .num_threads(effective_concurrency)
                .build()
                .expect("rayon thread pool");
            let per_slice_durations = Mutex::new(Vec::<Duration>::with_capacity(k));
            let started = Instant::now();
            pool.scope(|s| {
                for dir in &slice_dirs {
                    let per = &per_slice_durations;
                    s.spawn(move |_| {
                        let started = Instant::now();
                        let _ = OmniscientPrep::run(dir, "on");
                        per.lock().expect("mutex").push(started.elapsed());
                    });
                }
            });
            let total = started.elapsed();
            let per_slice = per_slice_durations
                .into_inner()
                .expect("mutex")
                .into_iter()
                .map(|d| d.as_secs_f64() * 1000.0)
                .sum::<f64>()
                / k.max(1) as f64;
            // Coordinator wall-clock is the post-fan-in reduce time —
            // here we approximate it as `total - max(per_slice)` to
            // mirror the OTel histogram shape the M19 worker emits.
            let coordinator = (total.as_secs_f64() * 1000.0 - per_slice).max(0.0);
            let cell = SlicePrepCell {
                slice_count: k,
                prep_concurrency: effective_concurrency,
                per_slice_wall_clock_ms: per_slice,
                coordinator_wall_clock_ms: coordinator,
                total_wall_clock_ms: total.as_secs_f64() * 1000.0,
                trace_size_bytes: trace_size,
            };
            outcome.report.push(cell.to_row());
            outcome.cells.push(cell);
        }
    }
    outcome
}

/// Compute the trace-size overhead at K-slices vs. the K=1 baseline,
/// as a fraction (0.10 = 10 %). Returns `None` when the matrix lacks
/// the required cells.
///
/// **What this verifies.** The function operates against measurement
/// rows the caller supplies; the test path feeds synthetic rows so the
/// assertion verifies the computation logic, not the recorder's
/// actual behaviour. Operators running the full bench observe the
/// number against real recorder output.
pub fn trace_size_overhead_fraction(cells: &[SlicePrepCell], k_target: usize) -> Option<f64> {
    let baseline = cells.iter().find(|c| c.slice_count == 1)?.trace_size_bytes;
    let target = cells
        .iter()
        .find(|c| c.slice_count == k_target)?
        .trace_size_bytes;
    if baseline == 0 {
        return None;
    }
    Some((target as f64 - baseline as f64) / baseline as f64)
}

/// Compute the concurrent speedup ratio relative to a perfectly linear
/// scaling at the given (slice_count, concurrency). Returns a
/// fraction in [0, 1] where 1.0 means perfect linear scaling.
///
/// **What this verifies.** Same caveat as
/// [`trace_size_overhead_fraction`] — the test path feeds synthetic
/// cells so the assertion verifies the computation logic. The
/// "at least 70% of linear" threshold lives in the verification
/// test, not here, so callers can pick their own bar.
pub fn linear_speedup_ratio(
    cells: &[SlicePrepCell],
    slice_count: usize,
    concurrency: usize,
) -> Option<f64> {
    let baseline = cells
        .iter()
        .find(|c| c.slice_count == slice_count && c.prep_concurrency == 1)?
        .total_wall_clock_ms;
    let scaled = cells
        .iter()
        .find(|c| c.slice_count == slice_count && c.prep_concurrency == concurrency)?
        .total_wall_clock_ms;
    if scaled == 0.0 {
        return None;
    }
    let ideal = baseline / concurrency as f64;
    Some(ideal / scaled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cell(
        slice_count: usize,
        prep_concurrency: usize,
        total_ms: f64,
        trace_size_bytes: u64,
    ) -> SlicePrepCell {
        SlicePrepCell {
            slice_count,
            prep_concurrency,
            per_slice_wall_clock_ms: total_ms,
            coordinator_wall_clock_ms: 0.0,
            total_wall_clock_ms: total_ms,
            trace_size_bytes,
        }
    }

    #[test]
    fn overhead_computation_within_10_percent_under_synthetic_load() {
        // 1024 -> 1100 = ~7.4 % overhead; under the 10 % bar.
        let cells = vec![cell(1, 1, 100.0, 1024), cell(16, 1, 100.0, 1100)];
        let overhead = trace_size_overhead_fraction(&cells, 16).unwrap();
        assert!(overhead < 0.10, "overhead {overhead} should be < 10 %");
    }

    #[test]
    fn speedup_ratio_above_70_percent_under_synthetic_load() {
        // 800 ms baseline, 140 ms at concurrency=8: ratio = (800/8) / 140 = 0.714
        let cells = vec![cell(8, 1, 800.0, 1024), cell(8, 8, 140.0, 1024)];
        let ratio = linear_speedup_ratio(&cells, 8, 8).unwrap();
        assert!(ratio >= 0.70, "ratio {ratio} should be >= 0.70");
    }
}
