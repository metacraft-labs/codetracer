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
        // `$CODETRACER_HOME/tmp`, else the historical per-OS location
        // (`ct_home::tmp_dir`, the twin of Nim's `paths.codetracerTmpPath`).
        let tmpdir: PathBuf = ct_home::tmp_dir();
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

/// Best-effort cleanup of stale `run-<pid>/` directories under the
/// per-user runtime base (typically `$XDG_RUNTIME_DIR/codetracer/`).
///
/// The db-backend (replay-server) historically created
/// `run-<pid>/` directories at startup and never removed them — each
/// dir is ~18 MB of logs + sockets, so after a few hundred invocations
/// the XDG_RUNTIME_DIR tmpfs (typ. 13 GB) fills up and subsequent
/// recording-opens fail with `ENOSPC`.  See GUI-Test-Stabilization
/// M12.
///
/// Strategy: list `run-*` entries; if the suffix parses as a `u32`
/// PID and that PID is no longer alive (POSIX `kill(pid, 0)` returns
/// `ESRCH`), delete the directory.  Anything else — non-PID suffix
/// (e.g. UUIDv7 worker dirs), live PID, parse failure, or our own
/// PID — is left untouched.
///
/// Entirely best-effort: every error is logged at debug level and
/// swallowed so a flaky filesystem can never abort spawner startup.
/// Returns the number of directories actually removed (primarily for
/// unit-testing the GC; production code ignores the count).
///
/// Safety / PID-reuse: `kill(0)` only tells us *some* process holds
/// that PID, not that it's a codetracer process.  To avoid deleting
/// a live unrelated tenant's data we treat any alive PID as "keep".
/// The worst case is therefore a stale dir lingering until the next
/// spawner start (when its PID is no longer alive), which is the
/// pre-existing behaviour for ~one extra cycle.
///
/// The caller is expected to invoke this *before* creating its own
/// run dir; we additionally hard-skip `current_pid` defensively in
/// case the caller does it the other way around.
pub fn gc_stale_run_dirs(tmp_path: &Path, current_pid: u32) -> usize {
    let base = socket_runtime_base_dir(tmp_path);
    let mut removed = gc_stale_run_dirs_in(&base, current_pid, &PosixKillProbe);
    // The short directory replay workers move to when their socket would
    // not fit under `base` (`worker_runtime_base_dir`) collects run
    // directories the same way; reclaim them too, but only from a
    // directory that is really this user's private one.
    #[cfg(unix)]
    {
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        let short = short_worker_runtime_dir(Path::new("/tmp"), euid);
        if short != base && is_private_dir(&short, euid) {
            removed += gc_stale_run_dirs_in(&short, current_pid, &PosixKillProbe);
        }
    }
    removed
}

/// Liveness probe abstraction so the GC is unit-testable without
/// forking real processes.
trait PidLivenessProbe {
    /// Returns `true` if a process with that PID currently exists.
    fn is_alive(&self, pid: u32) -> bool;
}

struct PosixKillProbe;

impl PidLivenessProbe for PosixKillProbe {
    fn is_alive(&self, pid: u32) -> bool {
        // POSIX `kill(pid, 0)`:
        //   * returns 0  → process exists and we may signal it,
        //   * returns -1 with errno == EPERM → process exists but
        //     we lack permission (so it IS alive — treat as alive),
        //   * returns -1 with errno == ESRCH → no such process.
        // See: https://pubs.opengroup.org/onlinepubs/9699919799/functions/kill.html
        #[cfg(unix)]
        {
            // SAFETY: ``kill`` with signal 0 is a stateless POSIX
            // syscall used purely to query whether ``pid`` exists --
            // it neither dereferences pointers nor mutates process
            // state.  The libc binding is unsafe only because all FFI
            // is.
            let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
            if rc == 0 {
                return true;
            }
            // ESRCH means dead, anything else (EPERM in particular)
            // means alive.  Read errno through ``io::Error`` so we
            // don't have to pick the right per-libc accessor
            // (``__errno_location`` on glibc, ``__error`` on darwin /
            // bsd, ``errno`` on musl, ...).
            let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            err != libc::ESRCH
        }
        #[cfg(not(unix))]
        {
            // Non-unix targets: be conservative and never claim a
            // PID is dead, so the GC never deletes anything.
            let _ = pid;
            true
        }
    }
}

/// Inner GC, separated from the public entry point so tests can
/// inject a fake liveness probe and a fake base dir.
fn gc_stale_run_dirs_in(base: &Path, current_pid: u32, probe: &dyn PidLivenessProbe) -> usize {
    let entries = match std::fs::read_dir(base) {
        Ok(e) => e,
        // Base dir doesn't exist yet on a clean machine — nothing to do.
        Err(_) => return 0,
    };
    let mut removed = 0usize;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = match name.to_str() {
            Some(s) => s,
            None => continue,
        };
        // Only consider `run-<...>` entries; everything else (the
        // `last` symlink, future siblings) is preserved.
        let suffix = match name.strip_prefix("run-") {
            Some(s) => s,
            None => continue,
        };
        // Only reclaim PID-derived dirs.  UUIDv7 worker dirs do not
        // parse as u32 and are intentionally left alone.
        let pid = match suffix.parse::<u32>() {
            Ok(p) => p,
            Err(_) => continue,
        };
        // Defensive: never reclaim our own run dir even if it
        // somehow already exists.
        if pid == current_pid {
            continue;
        }
        if probe.is_alive(pid) {
            continue;
        }
        let path = entry.path();
        // remove_dir_all on a non-empty dir is one fs op; we
        // deliberately do not crawl entry contents.
        match std::fs::remove_dir_all(&path) {
            Ok(()) => removed += 1,
            Err(e) => log::debug!("gc_stale_run_dirs: failed to remove {}: {e}", path.display()),
        }
    }
    removed
}

fn socket_runtime_base_dir(fallback_tmp: &Path) -> PathBuf {
    // The cleaner `if let Ok(x) = ... && !x.is_empty()` let-chain form
    // requires Rust edition 2024; this crate is currently on edition
    // 2021 (`Cargo.toml`), so we nest the checks manually.  Revisit
    // when the workspace bumps its edition.
    if let Ok(explicit) = env::var(CODETRACER_RUNTIME_DIR_ENV)
        && !explicit.is_empty()
    {
        return PathBuf::from(explicit);
    }
    if cfg!(target_os = "macos") {
        return PathBuf::from("/tmp/codetracer");
    }
    if !cfg!(target_os = "macos")
        && let Ok(xdg) = env::var("XDG_RUNTIME_DIR")
        && let Some(base) = xdg_runtime_base(Path::new(&xdg), &|dir| accepts_writes(dir))
    {
        return base;
    }
    fallback_tmp.to_path_buf()
}

/// `<xdg>/codetracer` when `$XDG_RUNTIME_DIR` (`xdg`) can hold it, else
/// `None` so the caller falls back to the per-user tmp directory.
///
/// The directory has to exist (as before) and also accept writes: the
/// directory that would receive the run directories is `<xdg>/codetracer`
/// when it already exists, else `<xdg>` itself, where it would be created.
/// A confined process can inherit `$XDG_RUNTIME_DIR` naming a directory it
/// sees read-only (a sandbox that bind-mounts the host's runtime directory
/// read-only while giving the process a private writable `/tmp`). Choosing
/// it there made every replay fail at startup with `EROFS` while a writable
/// fallback was available. `writable` is the probe, injectable for tests.
fn xdg_runtime_base(xdg: &Path, writable: &dyn Fn(&Path) -> bool) -> Option<PathBuf> {
    if xdg.as_os_str().is_empty() || !xdg.is_dir() {
        return None;
    }
    let base = xdg.join("codetracer");
    let receiving = if base.is_dir() { base.as_path() } else { xdg };
    if writable(receiving) { Some(base) } else { None }
}

/// Whether this process may create entries in `dir`: POSIX `access(2)`
/// with `W_OK`, which also reports `EROFS` for a read-only mount
/// (<https://pubs.opengroup.org/onlinepubs/9699919799/functions/access.html>).
#[cfg(unix)]
fn accepts_writes(dir: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(c_path) = std::ffi::CString::new(dir.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: `c_path` is a valid NUL-terminated string that outlives the call.
    unsafe { libc::access(c_path.as_ptr(), libc::W_OK) == 0 }
}

/// Non-Unix hosts never reach the `$XDG_RUNTIME_DIR` branch's callers in
/// practice; treat the directory as writable to keep the old behaviour.
#[cfg(not(unix))]
fn accepts_writes(_dir: &Path) -> bool {
    true
}

/// The file name of a replay worker's socket inside its run directory.
/// The worker names its socket the same way
/// (`native_replay_socket_file_name` in codetracer-native-backend).
pub fn recreator_socket_file_name(from: &str, worker_name: &str, worker_index_for_kind: usize) -> String {
    format!("ct_native_replay_{worker_name}_{worker_index_for_kind}_from_{from}.sock")
}

/// [`recreator_socket_path`] under an explicit runtime base directory:
/// `<base>/run-<run_id>/<socket file>`, creating the run directory.
pub fn recreator_socket_path_in(
    base: &Path,
    from: &str,
    worker_name: &str,
    worker_index_for_kind: usize,
    run_id: &str,
) -> Result<PathBuf, Box<dyn Error>> {
    let run_dir = base.join(format!("run-{run_id}"));
    std::fs::create_dir_all(&run_dir)?;
    Ok(run_dir.join(recreator_socket_file_name(from, worker_name, worker_index_for_kind)))
}

/// A worker's log file under an explicit runtime base directory, beside
/// its socket in `<base>/run-<run_id>/`.
pub fn log_path_in(
    base: &Path,
    name: &str,
    worker_kind: &str,
    worker_index_for_kind: usize,
    run_id: &str,
) -> Result<PathBuf, Box<dyn Error>> {
    let run_dir = base.join(format!("run-{run_id}"));
    std::fs::create_dir_all(&run_dir)?;
    Ok(run_dir.join(format!("{name}-{worker_kind}-{worker_index_for_kind}.log")))
}

/// The longest Unix-domain socket path, without its terminating NUL:
/// `sizeof(sockaddr_un.sun_path) - 1`, which is 107 on Linux and 103 on
/// Darwin and the BSDs (unix(7); Runtime-Paths-Strategy.md §5.1).
#[cfg(unix)]
pub fn sun_path_max() -> usize {
    // SAFETY: `sockaddr_un` is plain old data; an all-zero value is valid.
    let address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_path.len() - 1
}

/// The runtime base directory one replay worker should use: `base` when
/// the worker's socket, `<base>/run-<run_id>/<socket_file_name>`, fits in
/// `sun_path`; otherwise a short private directory, `/tmp/ct-<euid>`.
///
/// Without `$XDG_RUNTIME_DIR` (a service, such as a CI runner) the base
/// falls back to `$CODETRACER_HOME/tmp`, and a deep `CODETRACER_HOME` made
/// the socket path longer than `sun_path`, so the worker could not create
/// it and the session failed before any replay. The spawner hands the
/// chosen directory to the worker as `$CODETRACER_RUNTIME_DIR`, which
/// every worker resolves first, so the two still meet without either
/// worker's own resolution changing. Returns an error naming the path
/// when even the short directory cannot hold the socket.
#[cfg(unix)]
pub fn worker_runtime_base_dir(base: PathBuf, run_id: &str, socket_file_name: &str) -> Result<PathBuf, Box<dyn Error>> {
    // SAFETY: geteuid has no preconditions and cannot fail.
    let euid = unsafe { libc::geteuid() };
    worker_runtime_base_dir_in(base, run_id, socket_file_name, Path::new("/tmp"), euid)
}

/// [`worker_runtime_base_dir`] with the short directory's parent and the
/// owner it must have given explicitly (for tests).
#[cfg(unix)]
pub fn worker_runtime_base_dir_in(
    base: PathBuf,
    run_id: &str,
    socket_file_name: &str,
    short_parent: &Path,
    euid: u32,
) -> Result<PathBuf, Box<dyn Error>> {
    let socket_under = |dir: &Path| dir.join(format!("run-{run_id}")).join(socket_file_name);
    let wanted = socket_under(&base);
    if wanted.as_os_str().len() <= sun_path_max() {
        return Ok(base);
    }
    let short = short_worker_runtime_dir(short_parent, euid);
    ensure_private_dir(&short, euid)?;
    let fallback = socket_under(&short);
    if fallback.as_os_str().len() > sun_path_max() {
        return Err(format!(
            "socket path too long ({} bytes, max {}) even under {}: {}",
            fallback.as_os_str().len(),
            sun_path_max(),
            short.display(),
            fallback.display()
        )
        .into());
    }
    log::warn!(
        "replay worker socket {} would be {} bytes (max {}); using {} instead",
        wanted.display(),
        wanted.as_os_str().len(),
        sun_path_max(),
        short.display()
    );
    Ok(short)
}

/// Create `dir` with mode 0700, or accept an existing one only when it is
/// a real directory (not a symlink) owned by `euid` and closed to group
/// and others: it is in a world-writable parent, where another user could
/// otherwise have placed it to receive this user's sockets.
#[cfg(unix)]
fn ensure_private_dir(dir: &Path, euid: u32) -> Result<(), Box<dyn Error>> {
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(format!("cannot create {}: {error}", dir.display()).into()),
    }
    check_private_dir(dir, euid)
}

/// The short per-user directory replay workers move to when their socket
/// would not fit under the usual base: `<parent>/ct-<euid>`.
#[cfg(unix)]
fn short_worker_runtime_dir(parent: &Path, euid: u32) -> PathBuf {
    parent.join(format!("ct-{euid}"))
}

/// Whether `dir` exists and passes [`check_private_dir`].
#[cfg(unix)]
fn is_private_dir(dir: &Path, euid: u32) -> bool {
    check_private_dir(dir, euid).is_ok()
}

/// `dir` is a real directory (not a symlink), owned by `euid`, and closed
/// to group and others.
#[cfg(unix)]
fn check_private_dir(dir: &Path, euid: u32) -> Result<(), Box<dyn Error>> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::symlink_metadata(dir)?;
    if !metadata.file_type().is_dir() {
        return Err(format!("{} is not a directory (a symlink or a file)", dir.display()).into());
    }
    if metadata.uid() != euid {
        return Err(format!(
            "{} is owned by uid {}, not by this user ({euid})",
            dir.display(),
            metadata.uid()
        )
        .into());
    }
    if metadata.mode() & 0o077 != 0 {
        return Err(format!(
            "{} is open to other users (mode {:o}); expected 0700",
            dir.display(),
            metadata.mode() & 0o7777
        )
        .into());
    }
    Ok(())
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
    Ok(run_dir.join(recreator_socket_file_name(from, worker_name, worker_index_for_kind)))

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

/// Environment variable naming the base directory of the per-run socket
/// directories ([`run_dir_for`]). An explicit value wins over every other
/// resolution, in this process and in every replay worker.
pub const CODETRACER_RUNTIME_DIR_ENV: &str = "CODETRACER_RUNTIME_DIR";

/// Spawner-side: the base directory this process resolves its per-run
/// socket directories under, which it hands to every replay worker it
/// spawns as `$CODETRACER_RUNTIME_DIR`.
///
/// The worker (`ct-native-replay`, a separate program) resolves the same
/// directory by its own copy of this logic, and the two copies' fallbacks
/// differ: this one falls back to `$CODETRACER_HOME/tmp`
/// (`ct_home::tmp_dir`), the worker's to `$TMPDIR/codetracer`. On a host
/// with `$XDG_RUNTIME_DIR` both use that and agree; without it (a CI
/// runner's service, which has no login session) a test that set
/// `CODETRACER_HOME` had the worker listen in one directory while this
/// process waited for its socket in another, until the test's own
/// timeout. Naming the directory to the worker makes the rendezvous not
/// depend on the two resolutions agreeing.
pub fn runtime_base_dir() -> Result<PathBuf, Box<dyn Error>> {
    let tmp_path: PathBuf = { CODETRACER_PATHS.lock()?.tmp_path.clone() };
    Ok(socket_runtime_base_dir(&tmp_path))
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

/// Spawner-side: reserve an index for a new replay worker named
/// `worker_name`, unique among the workers of that name this process creates.
///
/// A worker's socket and log are named by `(worker_name, index)` inside the
/// run directory ([`recreator_socket_file_name`]), and the run directory is
/// shared by every worker of this process when no recording id is plumbed
/// (`reserve_run_id_for_recording("")` is the pid). Each handler used to
/// count indices on its own, from 0: the `flow` task thread's handler gives
/// its own replay `("flow", 0)` and so did the first `ct/load-flow` worker,
/// and the `tracepoint` thread's handler and the first history/tracepoint
/// worker collided the same way — two workers on one socket. Reserving every
/// index here makes the pair unique for the process's lifetime, whichever
/// handler or thread creates the worker. Indices start at 0 and increase by
/// one per name.
pub fn reserve_worker_index(worker_name: &str) -> usize {
    use std::collections::HashMap;
    static NEXT: LazyLock<Mutex<HashMap<String, usize>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
    let mut next = match NEXT.lock() {
        Ok(next) => next,
        Err(poisoned) => poisoned.into_inner(),
    };
    let entry = next.entry(worker_name.to_string()).or_insert(0);
    let index = *entry;
    *entry += 1;
    index
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
    if let Ok(value) = env::var(CODETRACER_RUN_ID_ENV)
        && !value.is_empty()
    {
        return value;
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
    use super::{
        CODETRACER_RUN_ID_ENV, PidLivenessProbe, gc_stale_run_dirs_in, reserve_run_id_for_recording,
        reserve_worker_index, resolve_run_id_for_worker, run_dir_for,
    };
    use std::collections::HashSet;
    use std::fs;
    use std::path::Path;

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

    /// A runtime directory that does not accept writes is passed over, so
    /// the caller falls back to its writable tmp directory instead of
    /// failing every replay at startup. The probe is the real `access(2)`
    /// against a directory made read-only on the real filesystem, so it
    /// must run as a user other than root (root ignores the mode; the test
    /// fails there instead of passing unchecked).
    #[cfg(unix)]
    #[test]
    fn a_runtime_directory_that_refuses_writes_is_passed_over() {
        use std::os::unix::fs::PermissionsExt;
        // Root bypasses mode bits, so on a root run the probe below would be
        // measured against nothing. Fail rather than pass without checking.
        assert_ne!(
            unsafe { libc::geteuid() },
            0,
            "this test needs a non-root user: root ignores the 0500 mode it relies on"
        );
        let temp = tempfile::tempdir().expect("create temp dir");
        let xdg = temp.path().join("runtime");
        fs::create_dir(&xdg).expect("create runtime dir");
        assert_eq!(
            super::xdg_runtime_base(&xdg, &|dir| super::accepts_writes(dir)),
            Some(xdg.join("codetracer")),
            "a writable runtime directory is used"
        );
        fs::set_permissions(&xdg, fs::Permissions::from_mode(0o500)).expect("make it read-only");
        let refused = super::accepts_writes(&xdg);
        let chosen = super::xdg_runtime_base(&xdg, &|dir| super::accepts_writes(dir));
        fs::set_permissions(&xdg, fs::Permissions::from_mode(0o700)).expect("restore");
        assert!(!refused, "access(W_OK) must refuse a 0500 directory");
        assert_eq!(chosen, None, "a read-only runtime directory must not be chosen");
    }

    /// The probe is asked about the directory that would receive the run
    /// directories: `<xdg>/codetracer` once it exists, `<xdg>` before.
    #[test]
    fn the_runtime_directory_probe_asks_about_the_receiving_directory() {
        let temp = tempfile::tempdir().expect("create temp dir");
        let xdg = temp.path().join("runtime");
        fs::create_dir(&xdg).expect("create runtime dir");
        let only_codetracer = xdg.join("codetracer");
        let probe = |dir: &Path| dir == only_codetracer.as_path();
        assert_eq!(
            super::xdg_runtime_base(&xdg, &probe),
            None,
            "before it exists, <xdg> is asked"
        );
        fs::create_dir(&only_codetracer).expect("create codetracer dir");
        assert_eq!(
            super::xdg_runtime_base(&xdg, &probe),
            Some(only_codetracer.clone()),
            "once it exists, <xdg>/codetracer is asked"
        );
        assert_eq!(
            super::xdg_runtime_base(Path::new(""), &|_| true),
            None,
            "an empty value is unset"
        );
        assert_eq!(
            super::xdg_runtime_base(&temp.path().join("missing"), &|_| true),
            None,
            "a missing directory is not used"
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

    /// Every worker index reserved for a name is distinct, and names count
    /// independently. A name unique to this test keeps it independent of other
    /// tests reserving in the same process.
    #[test]
    fn reserve_worker_index_never_hands_out_a_name_index_pair_twice() {
        let name = "reserve-worker-index-test";
        let reserved: Vec<usize> = (0..5).map(|_| reserve_worker_index(name)).collect();
        assert_eq!(reserved, vec![0, 1, 2, 3, 4]);
        assert_eq!(reserve_worker_index("reserve-worker-index-test-other"), 0);
        assert_eq!(reserve_worker_index(name), 5);
    }

    /// Fake liveness probe driven by an explicit set of "alive" PIDs.
    struct FakeProbe {
        alive: HashSet<u32>,
    }
    impl PidLivenessProbe for FakeProbe {
        fn is_alive(&self, pid: u32) -> bool {
            self.alive.contains(&pid)
        }
    }

    fn seed_run_dir(base: &Path, name: &str) {
        let p = base.join(name);
        fs::create_dir_all(&p).expect("seed run dir");
        // Drop a tiny file inside so we exercise the recursive remove path.
        fs::write(p.join("replay-server.log"), b"junk").expect("seed log");
    }

    /// GC removes dirs for dead PIDs, keeps dirs for live PIDs, and
    /// never touches non-`run-<pid>` entries (UUIDv7 worker dirs, the
    /// `last` symlink, unrelated files).
    #[test]
    fn gc_stale_run_dirs_in_removes_only_dead_pid_dirs() {
        let temp = tempfile::tempdir().expect("create temp base");
        let base = temp.path();
        // Dead PIDs: should be removed.
        seed_run_dir(base, "run-99999990");
        seed_run_dir(base, "run-99999991");
        // Live PID: must be preserved.
        seed_run_dir(base, "run-4242");
        // UUIDv7 worker dir (non-numeric suffix): must be preserved.
        seed_run_dir(base, "run-01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb");
        // Unrelated entry: must be preserved.
        fs::create_dir_all(base.join("scratch")).expect("seed scratch");
        // `last` symlink-style preserved (we just create a plain file
        // here; the GC only inspects entries whose name starts with
        // `run-`).
        fs::write(base.join("last"), b"").expect("seed last marker");

        let probe = FakeProbe {
            alive: [4242u32].iter().copied().collect(),
        };
        // Our own pid is some arbitrary number that's NOT in the seed set.
        let removed = gc_stale_run_dirs_in(base, 12345, &probe);
        assert_eq!(removed, 2, "should have removed exactly the two dead-PID dirs");

        assert!(!base.join("run-99999990").exists());
        assert!(!base.join("run-99999991").exists());
        assert!(base.join("run-4242").is_dir());
        assert!(base.join("run-01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb").is_dir());
        assert!(base.join("scratch").is_dir());
        assert!(base.join("last").exists());
    }

    /// Defensive: even if a `run-<current_pid>` dir somehow exists at
    /// GC time (it shouldn't, but startup ordering bugs are easy), the
    /// GC must never reclaim it.
    #[test]
    fn gc_stale_run_dirs_in_skips_current_pid() {
        let temp = tempfile::tempdir().expect("create temp base");
        let base = temp.path();
        seed_run_dir(base, "run-77");
        // Probe says dead — but we own this PID.
        let probe = FakeProbe { alive: HashSet::new() };
        let removed = gc_stale_run_dirs_in(base, 77, &probe);
        assert_eq!(removed, 0);
        assert!(base.join("run-77").is_dir());
    }

    /// Missing base dir is a no-op (clean machine, never started yet).
    #[test]
    fn gc_stale_run_dirs_in_missing_base_is_noop() {
        let temp = tempfile::tempdir().expect("create temp base");
        let missing = temp.path().join("does-not-exist");
        let probe = FakeProbe { alive: HashSet::new() };
        let removed = gc_stale_run_dirs_in(&missing, 12345, &probe);
        assert_eq!(removed, 0);
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

    // `worker_runtime_base_dir_in`: the replay worker's socket must fit in
    // `sun_path`.  No mocks: real directories under a temporary parent
    // stand in for `/tmp`, with this process's own uid.
    #[cfg(unix)]
    mod worker_runtime_base_dir {
        use super::super::{recreator_socket_file_name, sun_path_max, worker_runtime_base_dir_in};
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        use std::path::PathBuf;

        // The shape of the run ids db-backend reserves: a recording's
        // UUIDv7, or the legacy pid.
        const RUN_ID: &str = "01949fcc-dddd-7e9c-aaaa-ffffffffffff";

        fn euid() -> u32 {
            // SAFETY: geteuid has no preconditions and cannot fail.
            unsafe { libc::geteuid() }
        }

        fn socket() -> String {
            recreator_socket_file_name("", "tracepoint", 0)
        }

        fn long_base(parent: &std::path::Path) -> PathBuf {
            // As in the CPUID gate runs: a per-test CODETRACER_HOME under
            // TMPDIR, `<home>/tmp` being the base without XDG_RUNTIME_DIR.
            parent.join("ct-test-home-1641136-1792316085048152539").join("tmp")
        }

        #[test]
        fn a_base_whose_socket_fits_is_kept() {
            let parent = tempfile::tempdir().unwrap();
            let base = PathBuf::from("/tmp/x");
            let chosen = worker_runtime_base_dir_in(base.clone(), RUN_ID, &socket(), parent.path(), euid()).unwrap();
            assert_eq!(chosen, base);
            assert!(!parent.path().join(format!("ct-{}", euid())).exists());
        }

        #[test]
        fn a_base_whose_socket_does_not_fit_moves_to_a_private_short_directory() {
            // A short parent, as `/tmp` is in production: under a deep
            // TMPDIR the short directory itself would not fit.
            let parent = tempfile::Builder::new().prefix("ctw").tempdir_in("/tmp").unwrap();
            let base = long_base(parent.path());
            let wanted = base.join(format!("run-{RUN_ID}")).join(socket());
            assert!(
                wanted.as_os_str().len() > sun_path_max(),
                "the control must not fit: {}",
                wanted.display()
            );

            let chosen = worker_runtime_base_dir_in(base, RUN_ID, &socket(), parent.path(), euid()).unwrap();
            assert_eq!(chosen, parent.path().join(format!("ct-{}", euid())));
            let metadata = std::fs::symlink_metadata(&chosen).unwrap();
            assert!(metadata.is_dir());
            assert_eq!(metadata.mode() & 0o777, 0o700);
            assert_eq!(metadata.uid(), euid());
            let socket_path = chosen.join(format!("run-{RUN_ID}")).join(socket());
            assert!(socket_path.as_os_str().len() <= sun_path_max());
            // A real socket binds there.
            std::fs::create_dir_all(socket_path.parent().unwrap()).unwrap();
            std::os::unix::net::UnixListener::bind(&socket_path).unwrap();
        }

        #[test]
        fn an_existing_short_directory_open_to_others_is_refused() {
            let parent = tempfile::tempdir().unwrap();
            let short = parent.path().join(format!("ct-{}", euid()));
            std::fs::create_dir(&short).unwrap();
            std::fs::set_permissions(&short, std::fs::Permissions::from_mode(0o777)).unwrap();
            let error = worker_runtime_base_dir_in(long_base(parent.path()), RUN_ID, &socket(), parent.path(), euid())
                .unwrap_err()
                .to_string();
            assert!(error.contains("open to other users"), "{error}");
        }

        #[test]
        fn an_existing_short_directory_owned_by_another_user_is_refused() {
            let parent = tempfile::tempdir().unwrap();
            // The directory is ours; claim to be someone else.
            let other = euid().wrapping_add(1);
            std::fs::create_dir(parent.path().join(format!("ct-{other}"))).unwrap();
            let error = worker_runtime_base_dir_in(long_base(parent.path()), RUN_ID, &socket(), parent.path(), other)
                .unwrap_err()
                .to_string();
            assert!(error.contains("is owned by uid"), "{error}");
        }

        #[test]
        fn a_symlink_in_place_of_the_short_directory_is_refused() {
            let parent = tempfile::tempdir().unwrap();
            let target = parent.path().join("elsewhere");
            std::fs::create_dir(&target).unwrap();
            std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700)).unwrap();
            std::os::unix::fs::symlink(&target, parent.path().join(format!("ct-{}", euid()))).unwrap();
            let error = worker_runtime_base_dir_in(long_base(parent.path()), RUN_ID, &socket(), parent.path(), euid())
                .unwrap_err()
                .to_string();
            assert!(error.contains("not a directory"), "{error}");
        }

        #[test]
        fn a_socket_too_long_even_in_the_short_directory_is_an_error_naming_it() {
            let parent = tempfile::tempdir().unwrap();
            let run_id = "r".repeat(120);
            let error = worker_runtime_base_dir_in(long_base(parent.path()), &run_id, &socket(), parent.path(), euid())
                .unwrap_err()
                .to_string();
            assert!(
                error.contains("socket path too long") && error.contains(&run_id),
                "{error}"
            );
        }
    }
}
