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
/// `run_id` is an opaque string token shared between the spawner and the
/// replay worker.  Historically a PID rendered as a base-10 integer;
/// post-M-REC-11 it is the recording's UUIDv7 (optionally suffixed with
/// `-<seq>` for concurrent replays of the same recording, see
/// [`reserve_run_id_for_recording`]).
///
/// Base directory resolution (first match wins):
/// 1. `$CODETRACER_RUNTIME_DIR` — explicit escape hatch (tests, unusual deployments).
/// 2. **macOS**: `/tmp/codetracer/`, because the normal per-user cache path
///    is too long for Unix-domain socket names once worker names and run ids
///    are appended.
/// 3. **Linux**: `$XDG_RUNTIME_DIR/codetracer/` when the path exists.
///    The XDG Base Directory spec designates this for sockets and other
///    runtime files; systemd-logind sets it at login (`/run/user/<uid>`,
///    tmpfs) and the value is stable across spawned children — crucially,
///    intermediate spawn wrappers do not silently re-derive it the way
///    they can with `$TMPDIR`, which historically led to `dap-server`
///    and the `ct-native-replay` worker computing different socket
///    directories and failing handshake. It also keeps sockets off
///    `/tmp`, which routinely fills up during long debug sessions.
/// 4. Fallback: the supplied `tmp_path` (preserves historical behaviour
///    in environments without XDG / in unit tests).
pub fn run_dir_for(tmp_path: &Path, run_id: &str) -> Result<PathBuf, Box<dyn Error>> {
    let base = socket_runtime_base_dir(tmp_path);
    let run_dir = base.join(format!("run-{run_id}"));
    std::fs::create_dir_all(&run_dir)?;
    Ok(run_dir)
}

fn socket_runtime_base_dir(fallback_tmp: &Path) -> PathBuf {
    // The cleaner `if let Ok(x) = ... && !x.is_empty()` let-chain form
    // requires Rust edition 2024; this crate is currently on edition
    // 2021 (`Cargo.toml`), so we nest the checks manually.  Revisit
    // when the workspace bumps its edition.
    if let Ok(explicit) = env::var("CODETRACER_RUNTIME_DIR") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    if cfg!(target_os = "macos") {
        return PathBuf::from("/tmp/codetracer");
    }
    if !cfg!(target_os = "macos") {
        if let Ok(xdg) = env::var("XDG_RUNTIME_DIR") {
            let candidate = PathBuf::from(&xdg);
            if !xdg.is_empty() && candidate.is_dir() {
                return candidate.join("codetracer");
            }
        }
    }
    fallback_tmp.to_path_buf()
}

pub fn recreator_socket_path(
    from: &str,
    worker_name: &str,
    worker_index_for_kind: usize,
    run_id: &str,
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
    run_id: &str,
) -> Result<PathBuf, Box<dyn Error>> {
    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    let run_dir = run_dir_for(&tmp_path, run_id)?;
    Ok(run_dir.join(format!("{name}-{worker_kind}-{worker_index_for_kind}.log")))
}

/// Environment variable carrying the per-run identifier from spawner to
/// replay worker.  See [`resolve_run_id_for_worker`] (worker side) and
/// [`reserve_run_id_for_recording`] (spawner side).  Documented in
/// `Architecture/Runtime-Paths-Strategy.md` §4.3.
pub const CODETRACER_RUN_ID_ENV: &str = "CODETRACER_RUN_ID";

/// Spawner-side: derive a unique-within-this-process `run_id` for a
/// recording about to be replayed.  Returns `<recording_id>` for the
/// first replay session of that recording in this process, and
/// `<recording_id>-<seq>` (1-based monotonic counter) for subsequent
/// concurrent replays of the *same* recording.
///
/// Concurrent callers in the same process are serialised through an
/// internal `Mutex`; the counter survives across calls for the
/// process's lifetime.  Empty `recording_id` is allowed for the
/// transitional period (M-REC-11 fallback) and produces the legacy
/// PID-derived id.
pub fn reserve_run_id_for_recording(recording_id: &str) -> String {
    use std::collections::HashMap;
    static COUNTERS: LazyLock<Mutex<HashMap<String, usize>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
    if recording_id.is_empty() {
        return std::process::id().to_string();
    }
    let mut counters = match COUNTERS.lock() {
        Ok(c) => c,
        Err(poisoned) => poisoned.into_inner(),
    };
    let entry = counters.entry(recording_id.to_string()).or_insert(0);
    let suffix = *entry;
    *entry += 1;
    if suffix == 0 {
        recording_id.to_string()
    } else {
        format!("{recording_id}-{suffix}")
    }
}

/// Worker-side: resolve the per-run identifier for the current process.
///
/// Resolution order (matches the Nim sibling `replay_worker_cmd.nim`):
/// 1. `$CODETRACER_RUN_ID` — set by the spawner (db-backend) for M-REC-11+.
/// 2. Fallback to `getppid()` rendered as base-10 — preserves the
///    pre-M-REC-11 rendezvous-by-pid behaviour for any spawner that has
///    not yet been migrated to set the env var.  Logged as a warning
///    so the deprecation is visible.
///
/// A future cleanup will drop the fallback and hard-error when the env
/// var is unset; see `Architecture/Runtime-Paths-Strategy.md` §4.3.
pub fn resolve_run_id_for_worker() -> String {
    if let Ok(value) = env::var(CODETRACER_RUN_ID_ENV) {
        if !value.is_empty() {
            return value;
        }
    }
    #[cfg(unix)]
    let fallback = std::os::unix::process::parent_id();
    #[cfg(not(unix))]
    let fallback = std::process::id();
    log::warn!(
        "{} not set; using transitional fallback run-id {} (will be removed post-M-REC-11)",
        CODETRACER_RUN_ID_ENV,
        fallback
    );
    fallback.to_string()
}

#[cfg(test)]
#[allow(clippy::expect_used)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::{CODETRACER_RUN_ID_ENV, reserve_run_id_for_recording, resolve_run_id_for_worker, run_dir_for};

    /// M-REC-11: run_id widens from `usize` to `&str`; the directory
    /// name still uses the `run-` prefix, but the suffix is now the
    /// recording's UUIDv7.
    #[test]
    fn run_dir_for_uses_run_id_string_in_directory_name() {
        let temp = tempfile::tempdir().expect("create temp dir");
        // SAFETY: env mutations in tests can race; ordering is
        // serialised within this binary by cargo's default thread
        // count for env-touching tests.
        unsafe {
            std::env::set_var("CODETRACER_RUNTIME_DIR", temp.path());
        }
        let run_dir = run_dir_for(temp.path(), "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb").expect("create run dir");
        unsafe {
            std::env::remove_var("CODETRACER_RUNTIME_DIR");
        }
        assert_eq!(
            run_dir.file_name().and_then(|n| n.to_str()),
            Some("run-01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb")
        );
    }

    /// M-REC-11 §4.3: first reservation returns the bare recording id;
    /// subsequent reservations append `-<seq>` (1-based).
    #[test]
    fn reserve_run_id_seq_suffix_on_collision() {
        let recording = "01949fcc-cccc-7e9c-aaaa-eeeeeeeeeeee";
        assert_eq!(reserve_run_id_for_recording(recording), recording);
        assert_eq!(reserve_run_id_for_recording(recording), format!("{recording}-1"));
    }

    /// Transitional behaviour: an empty recording id falls back to the
    /// spawner's pid (pre-M-REC-11 behaviour).
    #[test]
    fn reserve_run_id_empty_recording_falls_back_to_pid() {
        assert_eq!(reserve_run_id_for_recording(""), std::process::id().to_string());
    }

    /// Worker-side resolution honours `$CODETRACER_RUN_ID` when set.
    #[test]
    fn resolve_run_id_prefers_env_var() {
        unsafe {
            std::env::set_var(CODETRACER_RUN_ID_ENV, "01949fcc-dddd-7e9c-aaaa-ffffffffffff");
        }
        let resolved = resolve_run_id_for_worker();
        unsafe {
            std::env::remove_var(CODETRACER_RUN_ID_ENV);
        }
        assert_eq!(resolved, "01949fcc-dddd-7e9c-aaaa-ffffffffffff");
    }
}
