//! Opening a *materialized* recording directory as a trace reader.
//!
//! A materialized (CTFS) recording reaches the db-backend in one of three
//! on-disk layouts, and the debugger already reads all three
//! (`dap_server::setup`):
//!
//! 1. a `*.ct` CTFS container — what the current recorders write;
//! 2. a legacy `runtime_tracing` `trace.json` event stream — what external
//!    recorders that have not adopted the CTFS writer still emit, `nargo
//!    trace` being the live example;
//! 3. a legacy `runtime_tracing` `trace.bin` capnp event stream — what the
//!    Python recorder emits.
//!
//! `dap_server::setup` interleaves those three arms with DAP handler
//! construction, so a second consumer cannot call it.  This module is the
//! reader-opening half on its own, so the DeepReview collector
//! (`crate::deepreview`) reads exactly the recordings the debugger reads
//! rather than growing a fourth, subtly different, notion of "a materialized
//! recording".
//!
//! `crate::diff::load_and_postprocess_trace` is deliberately *not* reused:
//! it is CTFS-only ("legacy … sidecars are no longer accepted"), which would
//! have made the collector refuse the Noir and Python recordings that
//! `ct replay` opens without complaint.

use std::error::Error;
use std::path::{Path, PathBuf};

use log::info;

use crate::ctfs_trace_reader::CTFSTraceReader;

/// The three file names that identify a materialized recording, in the order
/// they are tried.  A `*.ct` container wins over a legacy sidecar when a
/// directory somehow holds both, because the container is the newer artefact.
pub const LEGACY_JSON_TRACE_FILE: &str = "trace.json";
pub const LEGACY_BINARY_TRACE_FILE: &str = "trace.bin";

/// Locate the unique `*.ct` CTFS container inside `dir`, if there is one.
fn find_ct_container(dir: &Path) -> Option<PathBuf> {
    if dir.is_file() && dir.extension().is_some_and(|ext| ext == "ct") {
        return Some(dir.to_path_buf());
    }
    std::fs::read_dir(dir)
        .ok()?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .find(|path| path.is_file() && path.extension().is_some_and(|ext| ext == "ct"))
}

/// Read the `workdir` a legacy sidecar layout recorded next to its event
/// stream, falling back to the directory holding the stream.
///
/// The workdir matters because every path in a legacy event stream is
/// relative to it; getting it wrong makes every source file unreadable and
/// every flow request silently empty.
fn legacy_workdir(stream_path: &Path) -> PathBuf {
    stream_path
        .parent()
        .map(|dir| dir.join("trace_metadata.json"))
        .filter(|path| path.is_file())
        .and_then(|path| std::fs::read(&path).ok())
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|value| value.get("workdir").and_then(|w| w.as_str()).map(PathBuf::from))
        .unwrap_or_else(|| {
            stream_path
                .parent()
                .map(|dir| dir.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."))
        })
}

/// Whether `dir` looks like a materialized recording this module can open.
///
/// Cheap and filesystem-only: it names files, it does not decode them.  The
/// ct-side survey (`src/ct/trace/trace_kind.nim`) applies the same rules, and
/// the two must agree or `ct review collect` routes a recording here that
/// this module then refuses.
pub fn is_materialized_recording(dir: &Path) -> bool {
    find_ct_container(dir).is_some()
        || dir.join(LEGACY_JSON_TRACE_FILE).is_file()
        || dir.join(LEGACY_BINARY_TRACE_FILE).is_file()
}

/// Open a materialized recording directory as a `CTFSTraceReader`.
///
/// All three layouts converge on `CTFSTraceReader::from_events` /
/// `CTFSTraceReader::open`, which is the same postprocessing pipeline the
/// debugger runs, so the `Db` a collector sees is the `Db` a replay session
/// sees.
pub fn open_materialized_trace(dir: &Path) -> Result<CTFSTraceReader, Box<dyn Error>> {
    if let Some(ct_path) = find_ct_container(dir) {
        info!("deepreview: opening CTFS container {}", ct_path.display());
        return CTFSTraceReader::open(&ct_path);
    }

    let json_path = dir.join(LEGACY_JSON_TRACE_FILE);
    if json_path.is_file() {
        info!("deepreview: opening legacy trace.json at {}", json_path.display());
        let json_bytes = std::fs::read(&json_path)?;
        let mut json_value: serde_json::Value = serde_json::from_slice(&json_bytes)
            .map_err(|e| format!("failed to parse legacy trace.json at {}: {e}", json_path.display()))?;
        // Shared with `dap_server`: the same stream needs the same repair, and
        // two copies of it would diverge silently.
        crate::dap_server::normalize_legacy_trace_json_values(&mut json_value);
        let events: Vec<codetracer_trace_types::TraceLowLevelEvent> = serde_json::from_value(json_value)
            .map_err(|e| format!("failed to decode legacy trace.json at {}: {e}", json_path.display()))?;
        let workdir = legacy_workdir(&json_path);
        return CTFSTraceReader::from_events(events, &workdir);
    }

    let bin_path = dir.join(LEGACY_BINARY_TRACE_FILE);
    if bin_path.is_file() {
        info!("deepreview: opening legacy trace.bin at {}", bin_path.display());
        use codetracer_trace_reader::trace_readers::TraceReader as _;
        let mut bin_reader = codetracer_trace_reader::trace_readers::BinaryTraceReader {};
        let events = bin_reader
            .load_trace_events(&bin_path)
            .map_err(|e| format!("failed to parse legacy trace.bin at {}: {e}", bin_path.display()))?;
        let workdir = legacy_workdir(&bin_path);
        return CTFSTraceReader::from_events(events, &workdir);
    }

    Err(format!(
        "'{}' is not a materialized recording: it holds no *.ct container, no {} and no {}",
        dir.display(),
        LEGACY_JSON_TRACE_FILE,
        LEGACY_BINARY_TRACE_FILE
    )
    .into())
}
