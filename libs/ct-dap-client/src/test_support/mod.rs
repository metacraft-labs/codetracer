pub mod comparison;
pub mod flow_runner;
pub mod tracepoint_runner;

use std::path::{Path, PathBuf};

pub use comparison::{
    assert_tracepoint_results_match, parse_trace_output, terminal_events_to_string, ExpectedTrace,
};
pub use flow_runner::{FlowData, FlowTestConfig, FlowTestRunner};
pub use tracepoint_runner::{TracepointSpec, TracepointTestRunner};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Prepare the trace folder for db-backend.
///
/// If `rr_trace_dir`'s parent already contains an `rr` entry pointing to it,
/// use the parent directly. Otherwise create a temporary wrapper directory
/// with an `rr` symlink.
pub(crate) fn prepare_trace_folder(
    rr_trace_dir: &Path,
) -> Result<(PathBuf, Option<PathBuf>), BoxError> {
    // Case 1: parent/rr == rr_trace_dir (uncached layout)
    if let Some(parent) = rr_trace_dir.parent() {
        let rr_child = parent.join("rr");
        if rr_child.exists() && rr_child == rr_trace_dir {
            return Ok((parent.to_path_buf(), None));
        }
    }

    // Case 2: create a wrapper directory with an rr symlink
    let wrapper = std::env::temp_dir()
        .join("codetracer")
        .join("dap-trace-wrappers")
        .join(format!("wrapper_{}", std::process::id()));
    std::fs::create_dir_all(&wrapper)?;
    let rr_link = wrapper.join("rr");
    // Remove stale symlink if present
    let _ = std::fs::remove_file(&rr_link);
    std::os::unix::fs::symlink(rr_trace_dir, &rr_link)?;
    Ok((wrapper.clone(), Some(wrapper)))
}

/// Find the ct-rr-support binary (needed by db-backend as replay-worker).
///
/// Search order:
/// 1. `CT_RR_SUPPORT_BIN` environment variable
/// 2. `CODETRACER_CT_RR_SUPPORT_CMD` environment variable
/// 3. Next to CARGO_MANIFEST_DIR's target/debug/ct-rr-support
/// 4. PATH search
pub(crate) fn find_ct_rr_support() -> Result<PathBuf, BoxError> {
    // 1. Explicit env var
    for var in &["CT_RR_SUPPORT_BIN", "CODETRACER_CT_RR_SUPPORT_CMD"] {
        if let Ok(val) = std::env::var(var) {
            let p = PathBuf::from(&val);
            if p.is_file() {
                return Ok(p);
            }
        }
    }

    // 2. Sibling rr-backend repo's build output
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let manifest = PathBuf::from(&manifest_dir);
        // When running from rr-backend: target/debug/ct-rr-support
        let candidate = manifest.join("target/debug/ct-rr-support");
        if candidate.is_file() {
            return Ok(candidate);
        }
        // When running from codetracer: ../codetracer-rr-backend/target/debug/ct-rr-support
        if let Some(ws) = manifest.parent() {
            let sibling = ws.join("codetracer-rr-backend/target/debug/ct-rr-support");
            if sibling.is_file() {
                return Ok(sibling);
            }
        }
    }

    // 3. PATH search
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join("ct-rr-support");
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }

    Err("ct-rr-support binary not found (set CT_RR_SUPPORT_BIN or build rr-backend)".into())
}
