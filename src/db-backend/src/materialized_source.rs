//! Opening a *materialized* recording directory as a trace reader.
//!
//! A materialized recording reaches the db-backend in one of two on-disk
//! layouts:
//!
//! 1. a `*.ct` CTFS container — what the production recorders write;
//! 2. a legacy `runtime_tracing` `trace.bin` capnp event stream — what the
//!    pre-CTFS recordings in `codetracer-example-recordings` are.
//!
//! A directory holding only a `trace.json` event stream is not a recording.
//! That layout is the output of the pure-Python and pure-Ruby test oracles,
//! which exists to be compared against `ct print` of a production `.ct`
//! recording; it is refused by name ([`TEST_ORACLE_OUTPUT_ERROR`]) rather
//! than reviewed.
//!
//! `dap_server::setup` interleaves the recording layouts with DAP handler
//! construction, so a second consumer cannot call it.  This module is the
//! reader-opening half on its own, so the DeepReview collector
//! (`crate::deepreview`) reads exactly the recordings the debugger reads
//! rather than growing a fourth, subtly different, notion of "a materialized
//! recording".
//!
//! `crate::diff::load_and_postprocess_trace` is deliberately *not* reused:
//! it is CTFS-only ("legacy … sidecars are no longer accepted"), which would
//! have made the collector refuse the `trace.bin` recordings that
//! `ct replay` opens without complaint.

use std::error::Error;
use std::path::{Path, PathBuf};

use log::info;

use crate::ctfs_trace_reader::CTFSTraceReader;

/// The legacy event-stream file name of a materialized recording.  A `*.ct`
/// container wins over it when a directory somehow holds both, because the
/// container is the newer artefact.
pub const LEGACY_BINARY_TRACE_FILE: &str = "trace.bin";

/// The file name the pure-Python and pure-Ruby test oracles write.
pub const TEST_ORACLE_TRACE_FILE: &str = "trace.json";

/// Why a directory holding only [`TEST_ORACLE_TRACE_FILE`] is refused.
pub const TEST_ORACLE_OUTPUT_ERROR: &str = "is a trace.json event stream: test-oracle output written by \
     the pure-Python or pure-Ruby recorder to be compared against `ct print` of a production \
     recording. It is not a recording and CodeTracer does not open it; record the program with \
     the production recorder to get a .ct recording";

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

/// Whether `dir` looks like a materialized recording, or like test-oracle
/// output that `open_materialized_trace` refuses by name.
///
/// Cheap and filesystem-only: it names files, it does not decode them.  The
/// ct-side survey (`src/ct/trace/trace_kind.nim`) applies the same rules.
/// Oracle output is included so that `ct review collect` reports the refusal
/// against the directory instead of claiming the folder holds nothing.
pub fn is_materialized_recording(dir: &Path) -> bool {
    find_ct_container(dir).is_some()
        || dir.join(TEST_ORACLE_TRACE_FILE).is_file()
        || dir.join(LEGACY_BINARY_TRACE_FILE).is_file()
}

/// Open a materialized recording directory as a `CTFSTraceReader`.
///
/// Both layouts converge on `CTFSTraceReader::from_events` /
/// `CTFSTraceReader::open`, which is the same postprocessing pipeline the
/// debugger runs, so the `Db` a collector sees is the `Db` a replay session
/// sees.
pub fn open_materialized_trace(dir: &Path) -> Result<CTFSTraceReader, Box<dyn Error>> {
    if let Some(ct_path) = find_ct_container(dir) {
        info!("deepreview: opening CTFS container {}", ct_path.display());
        return CTFSTraceReader::open(&ct_path);
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

    if dir.join(TEST_ORACLE_TRACE_FILE).is_file() {
        return Err(format!("'{}' {TEST_ORACLE_OUTPUT_ERROR}", dir.display()).into());
    }

    Err(format!(
        "'{}' is not a materialized recording: it holds no *.ct container and no {}",
        dir.display(),
        LEGACY_BINARY_TRACE_FILE
    )
    .into())
}
