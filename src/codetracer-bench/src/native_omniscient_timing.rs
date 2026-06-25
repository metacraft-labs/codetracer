//! Native MCR/RR omniscient-prep timing benchmark.
//!
//! This benchmark complements P2/P3:
//! * P2 measures artifact sizes.
//! * P3 measures MCR slice/concurrency behavior.
//! * This module measures the product native path end to end for the
//!   same ordinary C program under MCR and RR: native run time, record
//!   time, and `trace omniscient-prep` time.

use crate::{
    BenchReport, BenchRow, Language, OmniscientPrep, RecorderError, ct_binary, ct_cli_binary,
    ct_command, dir_size_bytes,
};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct NativeOmniscientTimingRow {
    pub backend: String,
    pub native_ms: f64,
    pub record_ms: f64,
    pub prep_ms: f64,
    pub trace_size_bytes: u64,
    pub omniscient_size_bytes: u64,
    pub memwrites_size_bytes: u64,
    pub linehits_size_bytes: u64,
    pub origin_meta_size_bytes: u64,
    pub error: Option<String>,
}

impl NativeOmniscientTimingRow {
    fn ratio(numerator: f64, denominator: f64) -> String {
        if denominator <= 0.0 || numerator <= 0.0 {
            "n/a".to_string()
        } else {
            format!("{:.3}", numerator / denominator)
        }
    }

    pub fn to_row(&self) -> BenchRow {
        let mut row = BenchRow::new(self.backend.clone(), "c");
        row.push("backend", self.backend.clone())
            .push("native_ms", format!("{:.3}", self.native_ms))
            .push("record_ms", format!("{:.3}", self.record_ms))
            .push("prep_ms", format!("{:.3}", self.prep_ms))
            .push(
                "record_plus_prep_ms",
                format!("{:.3}", self.record_ms + self.prep_ms),
            )
            .push(
                "record_over_native",
                Self::ratio(self.record_ms, self.native_ms),
            )
            .push(
                "prep_over_native",
                Self::ratio(self.prep_ms, self.native_ms),
            )
            .push(
                "prep_over_record",
                Self::ratio(self.prep_ms, self.record_ms),
            )
            .push("trace_size_bytes", self.trace_size_bytes.to_string())
            .push(
                "omniscient_size_bytes",
                self.omniscient_size_bytes.to_string(),
            )
            .push(
                "memwrites_size_bytes",
                self.memwrites_size_bytes.to_string(),
            )
            .push("linehits_size_bytes", self.linehits_size_bytes.to_string())
            .push(
                "origin_meta_size_bytes",
                self.origin_meta_size_bytes.to_string(),
            )
            .push("error", self.error.clone().unwrap_or_default());
        row
    }
}

#[derive(Debug, Default)]
pub struct NativeOmniscientTimingOutcome {
    pub report: BenchReport,
    pub skipped: Vec<String>,
}

pub fn report_columns() -> Vec<String> {
    [
        "backend",
        "native_ms",
        "record_ms",
        "prep_ms",
        "record_plus_prep_ms",
        "record_over_native",
        "prep_over_native",
        "prep_over_record",
        "trace_size_bytes",
        "omniscient_size_bytes",
        "memwrites_size_bytes",
        "linehits_size_bytes",
        "origin_meta_size_bytes",
        "error",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

pub fn run(
    program: &Path,
    backends: &[String],
    runs: usize,
    temp_root: &Path,
) -> NativeOmniscientTimingOutcome {
    let mut outcome = NativeOmniscientTimingOutcome {
        report: BenchReport::new("native-omniscient-timing", report_columns()),
        ..Default::default()
    };

    if ct_cli_binary().is_none() {
        outcome
            .skipped
            .push("ct CLI not on PATH and not discoverable at src/build-debug/bin/ct".to_string());
        return outcome;
    }
    if ct_binary().is_none() {
        outcome
            .skipped
            .push("ct launcher with trace omniscient-prep not found".to_string());
        return outcome;
    }
    if crate::which("gcc").is_none() {
        outcome.skipped.push("gcc binary not on PATH".to_string());
        return outcome;
    }

    let bin_path = temp_root.join("native-omniscient-fixture");
    if let Err(err) = compile_c(program, &bin_path) {
        outcome
            .skipped
            .push(format!("fixture compile failed: {err}"));
        return outcome;
    }

    let runs = runs.max(1);
    let native_ms = match median_success_time(|| Ok(Command::new(&bin_path)), runs) {
        Ok(d) => duration_ms(d),
        Err(err) => {
            outcome
                .skipped
                .push(format!("native fixture failed: {err}"));
            return outcome;
        }
    };

    for backend in backends {
        let row = match measure_backend(backend, &bin_path, native_ms, runs, temp_root) {
            Ok(row) => row.to_row(),
            Err(err) => NativeOmniscientTimingRow {
                backend: backend.clone(),
                native_ms,
                record_ms: 0.0,
                prep_ms: 0.0,
                trace_size_bytes: 0,
                omniscient_size_bytes: 0,
                memwrites_size_bytes: 0,
                linehits_size_bytes: 0,
                origin_meta_size_bytes: 0,
                error: Some(err.to_string()),
            }
            .to_row(),
        };
        outcome.report.push(row);
    }

    outcome
}

fn measure_backend(
    backend: &str,
    binary_path: &Path,
    native_ms: f64,
    runs: usize,
    temp_root: &Path,
) -> Result<NativeOmniscientTimingRow, RecorderError> {
    let trace_dir = temp_root.join(format!("trace-{backend}"));
    let record_ms = duration_ms(median_success_time(
        || {
            if trace_dir.exists() {
                std::fs::remove_dir_all(&trace_dir)
                    .map_err(|e| format!("remove {}: {e}", trace_dir.display()))?;
            }
            record_command(backend, binary_path, &trace_dir)
        },
        runs,
    )?);

    if trace_dir.exists() {
        std::fs::remove_dir_all(&trace_dir)
            .map_err(|e| RecorderError::Io(format!("remove {}: {e}", trace_dir.display())))?;
    }
    let record = record_command(backend, binary_path, &trace_dir).map_err(RecorderError::Io)?;
    run_command(record).map_err(|stderr_tail| RecorderError::RecordingFailed {
        exit_code: None,
        stderr_tail,
    })?;

    let ct_path = crate::omniscient_db_size::find_ct_container(&trace_dir).ok_or_else(|| {
        RecorderError::RecordingFailed {
            exit_code: None,
            stderr_tail: format!(
                "ct record --backend {backend} produced no *.ct under {}",
                trace_dir.display()
            ),
        }
    })?;
    let slice_folder = ct_path.parent().unwrap_or(&trace_dir);
    let mut error = None;
    let prep_ms = match median_success_prep_time(slice_folder, runs) {
        Ok(duration) => duration_ms(duration),
        Err(err) => {
            error = Some(err.to_string());
            0.0
        }
    };

    let meta_dat = slice_folder.join("meta_dat");
    let memwrites_size_bytes = file_size(&meta_dat.join("memwrites.tc"))?;
    let linehits_size_bytes = file_size(&meta_dat.join("linehits.tc"))?;
    let origin_meta_size_bytes = ["originmeta.tc", "varwrites.tc", "source_exprs.tc"]
        .iter()
        .map(|name| file_size(&meta_dat.join(name)))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .sum();

    Ok(NativeOmniscientTimingRow {
        backend: backend.to_string(),
        native_ms,
        record_ms,
        prep_ms,
        trace_size_bytes: dir_size_bytes(&trace_dir)
            .map_err(|e| RecorderError::Io(e.to_string()))?,
        omniscient_size_bytes: dir_size_bytes(&meta_dat)
            .map_err(|e| RecorderError::Io(e.to_string()))?,
        memwrites_size_bytes,
        linehits_size_bytes,
        origin_meta_size_bytes,
        error,
    })
}

fn file_size(path: &Path) -> Result<u64, RecorderError> {
    match std::fs::metadata(path) {
        Ok(meta) if meta.is_file() => Ok(meta.len()),
        Ok(_) => Ok(0),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(err) => Err(RecorderError::Io(format!(
            "metadata {}: {err}",
            path.display()
        ))),
    }
}

fn compile_c(src: &Path, bin: &Path) -> Result<(), String> {
    let mut cmd = Command::new("gcc");
    cmd.arg("-O2").arg("-g").arg("-o").arg(bin).arg(src);
    run_command(cmd)
}

fn record_command(backend: &str, program_path: &Path, trace_dir: &Path) -> Result<Command, String> {
    std::fs::create_dir_all(trace_dir).map_err(|e| format!("create trace dir: {e}"))?;
    let ct = ct_cli_binary().ok_or_else(|| "ct CLI not found".to_string())?;
    let mut cmd = ct_command(&ct);
    cmd.arg("record")
        .arg("--lang")
        .arg(Language::C.ct_record_lang())
        .arg("--backend")
        .arg(backend)
        .arg("-o")
        .arg(trace_dir)
        .arg(program_path);
    Ok(cmd)
}

fn median_success_time<F>(mut command_factory: F, runs: usize) -> Result<Duration, RecorderError>
where
    F: FnMut() -> Result<Command, String>,
{
    let mut times = Vec::with_capacity(runs);
    for _ in 0..runs {
        let mut command = command_factory().map_err(RecorderError::Io)?;
        let started = Instant::now();
        run_command_ref(&mut command)?;
        times.push(started.elapsed());
    }
    times.sort();
    Ok(times[times.len() / 2])
}

fn median_success_prep_time(slice_folder: &Path, runs: usize) -> Result<Duration, RecorderError> {
    let mut times = Vec::with_capacity(runs);
    for _ in 0..runs {
        times.push(OmniscientPrep::run(slice_folder, "on")?);
    }
    times.sort();
    Ok(times[times.len() / 2])
}

fn run_command(mut command: Command) -> Result<(), String> {
    run_command_ref_string(&mut command)
}

fn run_command_ref(command: &mut Command) -> Result<(), RecorderError> {
    run_command_ref_string(command).map_err(|stderr_tail| RecorderError::RecordingFailed {
        exit_code: None,
        stderr_tail,
    })
}

fn run_command_ref_string(command: &mut Command) -> Result<(), String> {
    let output = command
        .output()
        .map_err(|e| format!("failed to spawn {:?}: {e}", command))?;
    if output.status.success() {
        return Ok(());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = if stderr.trim().is_empty() {
        stdout.into_owned()
    } else if stdout.trim().is_empty() {
        stderr.into_owned()
    } else {
        format!("{stdout}\n{stderr}")
    };
    Err(format!(
        "command {:?} failed with {:?}:\n{}",
        command,
        output.status.code(),
        combined.lines().take(30).collect::<Vec<_>>().join("\n")
    ))
}

fn duration_ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

pub fn default_program(fixtures_root: &Path) -> PathBuf {
    fixtures_root
        .join("product-omniscient")
        .join("rr_c_arbitrary")
        .join("main.c")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_reports_ratios_against_native_and_record_time() {
        let row = NativeOmniscientTimingRow {
            backend: "rr".to_string(),
            native_ms: 10.0,
            record_ms: 100.0,
            prep_ms: 25.0,
            trace_size_bytes: 123,
            omniscient_size_bytes: 45,
            memwrites_size_bytes: 30,
            linehits_size_bytes: 15,
            origin_meta_size_bytes: 0,
            error: None,
        }
        .to_row();
        assert!(
            row.columns
                .contains(&("record_over_native".to_string(), "10.000".to_string()))
        );
        assert!(
            row.columns
                .contains(&("prep_over_record".to_string(), "0.250".to_string()))
        );
    }
}
