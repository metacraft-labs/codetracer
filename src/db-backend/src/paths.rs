// copied from Stan's paths.rs in src/db-backend in the public codetracer repo
//   added run_dir/recreator_socket_path (and copied to db-backend/ct-native-replay too)

use std::env;
use std::error::Error;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

pub struct Paths {
    pub tmp_path: PathBuf,
    pub client_socket_path: PathBuf,
    pub socket_path: PathBuf,
}

impl Default for Paths {
    fn default() -> Self {
        let tmpdir: PathBuf = if cfg!(target_os = "macos") {
            PathBuf::from(env::var("HOME").unwrap_or("/".to_string())).join("Library/Caches/com.codetracer.CodeTracer/")
        } else {
            env::temp_dir().join("codetracer/")
        };
        Self {
            tmp_path: PathBuf::from(&tmpdir),
            client_socket_path: PathBuf::from(&tmpdir).join("ct_client_socket"),
            socket_path: PathBuf::from(&tmpdir).join("ct_socket"),
        }
    }
}

pub static CODETRACER_PATHS: LazyLock<Mutex<Paths>> = LazyLock::new(|| Mutex::new(Paths::default()));

/// Locate the directory in which CodeTracer stores per-run Unix-domain
/// sockets and small log files for a particular `run_id`.
///
/// Base directory resolution (first match wins):
/// 1. `$CODETRACER_RUNTIME_DIR` — explicit escape hatch (tests, unusual deployments).
/// 2. **Linux**: `$XDG_RUNTIME_DIR/codetracer/` when the path exists.
///    The XDG Base Directory spec designates this for sockets and other
///    runtime files; systemd-logind sets it at login (`/run/user/<uid>`,
///    tmpfs) and the value is stable across spawned children — crucially,
///    intermediate spawn wrappers do not silently re-derive it the way
///    they can with `$TMPDIR`, which historically led to `dap-server`
///    and the `ct-native-replay` worker computing different socket
///    directories and failing handshake. It also keeps sockets off
///    `/tmp`, which routinely fills up during long debug sessions.
/// 3. Fallback: the supplied `tmp_path` (preserves historical behaviour
///    in environments without XDG / on macOS / in unit tests).
pub fn run_dir_for(tmp_path: &Path, run_id: usize) -> Result<PathBuf, Box<dyn Error>> {
    let base = socket_runtime_base_dir(tmp_path);
    let run_dir = base.join(format!("run-{run_id}"));
    std::fs::create_dir_all(&run_dir)?;
    Ok(run_dir)
}

fn socket_runtime_base_dir(fallback_tmp: &Path) -> PathBuf {
    if let Ok(explicit) = env::var("CODETRACER_RUNTIME_DIR")
        && !explicit.is_empty()
    {
        return PathBuf::from(explicit);
    }
    if !cfg!(target_os = "macos")
        && let Ok(xdg) = env::var("XDG_RUNTIME_DIR")
    {
        let candidate = PathBuf::from(&xdg);
        if !xdg.is_empty() && candidate.is_dir() {
            return candidate.join("codetracer");
        }
    }
    fallback_tmp.to_path_buf()
}

pub fn recreator_socket_path(
    from: &str,
    worker_name: &str,
    worker_index_for_kind: usize,
    run_id: usize,
) -> Result<PathBuf, Box<dyn Error>> {
    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, run_id)?;
    // eventually: TODO: unique index or better cleanup
    //  if worker with the same name started/restarted multiple times
    //  by the same backend instance
    Ok(run_dir.join(format!(
        "ct_native_replay_{worker_name}_{worker_index_for_kind}_from_{from}.sock"
    )))

    // TODO: decide if we need to check/eventually remove or the unique run folder/paths are enough:
    //
    // if std::fs::metadata(&receiving_socket_path).is_ok() {
    // let _ = std::fs::remove_file(&receiving_socket_path); // try to remove if existing: ignore error
    // }
}

pub fn log_path_for(
    name: &str,
    worker_kind: &str,
    worker_index_for_kind: usize,
    run_id: usize,
) -> Result<PathBuf, Box<dyn Error>> {
    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, run_id)?;
    Ok(run_dir.join(format!("{name}-{worker_kind}-{worker_index_for_kind}.log")))
}
