//! Python script execution for the `ct trace query` CLI command.
//!
//! This module handles spawning a Python subprocess that connects back to the
//! daemon, opens a trace, and executes user-provided code.  The daemon calls
//! [`execute_script`] when it receives a `ct/exec-script` request.
//!
//! # Script wrapping
//!
//! User code (whether from an inline `-c` argument or a file) is embedded into
//! a wrapper that:
//!
//! 1. Removes the daemon's working directory from `sys.path` (the
//!    interpreter runs in isolated mode, so it is not there to begin with),
//!    then adds the
//!    CodeTracer Python API (found by [`resolve_python_api_path`]), or, when
//!    no copy was found, names the places searched if `codetracer` is not
//!    importable on its own.
//! 2. Sets environment variables so the API knows which daemon socket to use.
//! 3. Opens the trace via `codetracer.open_trace()`, binding it as `trace`.
//! 4. Runs the user code inside a `try/finally` so the trace is closed even on
//!    errors.
//!
//! # Timeout
//!
//! The subprocess is given a configurable timeout (default 30 seconds).  If the
//! process exceeds this limit it is killed and a timeout result is returned with
//! exit code 124 (matching the convention used by the `timeout(1)` command).
//!
//! # Error handling
//!
//! Python errors surface through stderr and a non-zero exit code.  The wrapper
//! does not swallow exceptions — they propagate normally so that the full
//! traceback is available in stderr.

use std::path::{Path, PathBuf};
use std::process::Stdio;

use tokio::process::Command;
use tokio::time::{Duration, timeout};

/// Default timeout for script execution in seconds.
///
/// 120 s is generous enough for large Python DB traces (which can be
/// 50–100 MB and require loading the full event table before answering
/// calltrace / terminal_output queries).
pub const DEFAULT_TIMEOUT_SECS: u64 = 120;

/// Exit code returned when a script exceeds its timeout.
///
/// Matches the exit code used by the `timeout(1)` coreutils command.
pub const TIMEOUT_EXIT_CODE: i32 = 124;

/// The environment variable that names the directory holding the
/// `codetracer` Python package (the `python-api` directory of a CodeTracer
/// checkout or install).  When it is set it is the only place used, and it is
/// trusted as given: the user chose it, so no ownership or permission check
/// is applied (a directory without the package is still refused).
pub const PYTHON_API_PATH_ENV: &str = "CODETRACER_PYTHON_API_PATH";

/// The checkout this binary was compiled from (`<repo>`, two levels above the
/// `src/backend-manager` crate), in debug builds only.
///
/// It lets a development build whose target directory is outside the checkout
/// (`CARGO_TARGET_DIR`) find `<repo>/python-api`.  A release build carries
/// no such path: its build directory (a Nix sandbox, a CI runner) means
/// nothing on the machine that runs it, and the binary should not name it.
#[cfg(debug_assertions)]
pub const COMPILED_CHECKOUT: Option<&str> = Some(concat!(env!("CARGO_MANIFEST_DIR"), "/../.."));
/// See the debug-build definition: a release build has no compiled checkout.
#[cfg(not(debug_assertions))]
pub const COMPILED_CHECKOUT: Option<&str> = None;

/// The outcome of looking for the `codetracer` Python package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PythonApiLookup {
    /// The directory to put on `sys.path`, when a trusted copy was found.
    pub path: Option<PathBuf>,
    /// The exact places looked at, in order, for the message a script prints
    /// when no copy was found and `codetracer` is not importable on its own.
    pub searched: Vec<String>,
    /// Copies that were present but refused by the trust rule, each with the
    /// reason (see [`resolve_python_api_path`]).
    pub refused: Vec<String>,
}

impl PythonApiLookup {
    /// A lookup that found the package at `path` (no search to report).
    pub fn found(path: impl Into<PathBuf>) -> Self {
        Self {
            path: Some(path.into()),
            searched: Vec::new(),
            refused: Vec::new(),
        }
    }
}

/// Does `dir` hold the `codetracer` package?
fn is_python_api_dir(dir: &Path) -> bool {
    dir.join("codetracer").join("__init__.py").is_file()
}

/// A place a `python-api` directory may be, derived from the executable's
/// location: `candidate` is trusted only if it, and every directory from it
/// up to `anchor`, passes the trust rule.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Candidate {
    anchor: PathBuf,
    candidate: PathBuf,
}

/// The known layouts, given `bin`, the (symlink-resolved) directory holding
/// the executable.  Only these are considered; directories further up are
/// never searched, so a shared directory such as `/tmp` above an AppImage
/// mount (`$TMPDIR/.mount_XXXX/bin`) is not a place a package is taken from.
///
/// - Install prefix: `<prefix>/bin/session-manager` with
///   `<prefix>/share/codetracer/python-api`.
/// - Cargo build inside a checkout: `<repo>/src/backend-manager/target/<profile>/`
///   or `<repo>/src/backend-manager/target/<triple>/<profile>/`, with
///   `<repo>/python-api`.
/// - Tup build inside a checkout: `<repo>/src/build-debug/bin/` or
///   `<repo>/src/build-release/bin/`, with `<repo>/python-api`.
fn layout_candidates(bin: &Path) -> Vec<Candidate> {
    let mut out = Vec::new();
    let name = |p: &Path| p.file_name().and_then(|n| n.to_str()).map(str::to_owned);
    let checkout = |repo: &Path| Candidate {
        anchor: repo.to_path_buf(),
        candidate: repo.join("python-api"),
    };

    if name(bin).as_deref() == Some("bin")
        && let Some(prefix) = bin.parent()
    {
        out.push(Candidate {
            anchor: prefix.to_path_buf(),
            candidate: prefix.join("share/codetracer/python-api"),
        });
        // <repo>/src/build-{debug,release}/bin
        if matches!(
            name(prefix).as_deref(),
            Some("build-debug" | "build-release")
        ) && let Some(src) = prefix.parent()
            && name(src).as_deref() == Some("src")
            && let Some(repo) = src.parent()
        {
            out.push(checkout(repo));
        }
    }

    // <repo>/src/backend-manager/target/<profile> and
    // <repo>/src/backend-manager/target/<triple>/<profile>
    for target in [bin.parent(), bin.parent().and_then(Path::parent)]
        .into_iter()
        .flatten()
    {
        if name(target).as_deref() == Some("target")
            && let Some(crate_dir) = target.parent()
            && crate_dir.ends_with("src/backend-manager")
            && let Some(repo) = crate_dir.parent().and_then(Path::parent)
        {
            out.push(checkout(repo));
            break;
        }
    }
    out
}

/// Ownership and permission bits of a filesystem object, as the trust rule
/// reads them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OwnerAndMode {
    /// The owning user id.
    pub uid: u32,
    /// The permission bits (`st_mode`).
    pub mode: u32,
}

/// Reads [`OwnerAndMode`] for a path (following symbolic links).  The
/// production reader is [`real_owner_and_mode`]; tests may inject another to
/// stand for an owner they cannot create without privileges.
pub type OwnerAndModeReader<'a> = &'a dyn Fn(&Path) -> std::io::Result<OwnerAndMode>;

/// The production [`OwnerAndModeReader`]: the filesystem's own metadata.
#[cfg(unix)]
pub fn real_owner_and_mode(path: &Path) -> std::io::Result<OwnerAndMode> {
    use std::os::unix::fs::MetadataExt;
    let meta = std::fs::metadata(path)?;
    Ok(OwnerAndMode {
        uid: meta.uid(),
        mode: meta.mode(),
    })
}

/// Who a trusted directory may belong to, and how its ownership is read.
pub struct TrustRule<'a> {
    /// The effective user id of this process; root (0) is always accepted.
    pub euid: u32,
    /// Reads ownership and permission bits.
    pub read: OwnerAndModeReader<'a>,
}

impl TrustRule<'_> {
    /// Is `path` owned by root or by this user, and not writable by group or
    /// others?  `Err` names the path and the reason.
    fn check_one(&self, path: &Path) -> Result<(), String> {
        let facts = (self.read)(path)
            .map_err(|e| format!("cannot read the owner of {}: {e}", path.display()))?;
        if facts.uid != 0 && facts.uid != self.euid {
            return Err(format!(
                "{} is owned by uid {}, not by root or the current user (uid {})",
                path.display(),
                facts.uid,
                self.euid
            ));
        }
        if facts.mode & 0o022 != 0 {
            return Err(format!(
                "{} is writable by {} (mode {:o})",
                path.display(),
                if facts.mode & 0o002 != 0 {
                    "every user"
                } else {
                    "its group"
                },
                facts.mode & 0o7777
            ));
        }
        Ok(())
    }

    /// Check `start` (symlink-resolved) and every directory above it, up to
    /// and including `anchor` when `start` is inside it, or up to `/` when a
    /// symbolic link led outside it.
    fn check_chain(
        &self,
        start: &Path,
        anchor: &Path,
        seen: &mut std::collections::HashSet<PathBuf>,
    ) -> Result<(), String> {
        let real = std::fs::canonicalize(start)
            .map_err(|e| format!("cannot resolve {}: {e}", start.display()))?;
        let inside = real.starts_with(anchor);
        for dir in real.ancestors() {
            if seen.insert(dir.to_path_buf()) {
                self.check_one(dir)?;
            }
            if inside && dir == anchor {
                break;
            }
        }
        Ok(())
    }

    /// The trust rule for a found `candidate` under `anchor`: every entry in
    /// the tree under `candidate` (files and directories at any depth,
    /// including the `codetracer` package, its other modules and any
    /// `__pycache__` with its bytecode), `candidate` itself, and every
    /// directory between `candidate` and `anchor` must each be owned by root
    /// or the current user and be writable by neither group nor others.
    /// The whole tree is checked, not only the package, because `candidate`
    /// goes first on `sys.path`: a module beside the package would shadow
    /// the standard library module of that name.
    ///
    /// Each lexical step is resolved separately, so a symbolic link anywhere
    /// on the way, or inside the tree, is followed and its target's
    /// directories are checked too, up to `/` when it leads outside
    /// `anchor`; a link that does not resolve is refused, since whoever can
    /// create its target would choose what it imports.  Anyone who could
    /// write to one of these could replace the code that runs inside every
    /// `exec_script`.
    pub fn check_candidate(&self, anchor: &Path, candidate: &Path) -> Result<(), String> {
        let anchor = std::fs::canonicalize(anchor)
            .map_err(|e| format!("cannot resolve {}: {e}", anchor.display()))?;
        let mut steps = Vec::new();
        let mut lexical = candidate.to_path_buf();
        loop {
            steps.push(lexical.clone());
            if !lexical.pop() || std::fs::canonicalize(&lexical).ok().as_ref() == Some(&anchor) {
                break;
            }
        }
        let mut seen = std::collections::HashSet::new();
        for step in steps {
            self.check_chain(&step, &anchor, &mut seen)?;
        }
        let mut walked = std::collections::HashSet::new();
        self.check_tree(candidate, &anchor, &mut seen, &mut walked)
    }

    /// Check every entry under `dir`, recursively, with [`Self::check_chain`].
    /// A symbolic link to a directory is descended into once (`walked` holds
    /// the resolved directories already listed), so a link cycle ends.
    fn check_tree(
        &self,
        dir: &Path,
        anchor: &Path,
        seen: &mut std::collections::HashSet<PathBuf>,
        walked: &mut std::collections::HashSet<PathBuf>,
    ) -> Result<(), String> {
        let real = std::fs::canonicalize(dir)
            .map_err(|e| format!("cannot resolve {}: {e}", dir.display()))?;
        if !walked.insert(real) {
            return Ok(());
        }
        let entries =
            std::fs::read_dir(dir).map_err(|e| format!("cannot list {}: {e}", dir.display()))?;
        for entry in entries {
            let path = entry
                .map_err(|e| format!("cannot list {}: {e}", dir.display()))?
                .path();
            self.check_chain(&path, anchor, seen)?;
            if path.is_dir() {
                self.check_tree(&path, anchor, seen, walked)?;
            }
        }
        Ok(())
    }
}

/// Find the directory to put on `sys.path` so `import codetracer` resolves,
/// using the real filesystem and this process's effective user id for the
/// trust rule.  See [`resolve_python_api_path_with`].
pub fn resolve_python_api_path(
    explicit: Option<&str>,
    exe: Option<&Path>,
    compiled_checkout: Option<&Path>,
) -> Result<PythonApiLookup, String> {
    #[cfg(unix)]
    {
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        let rule = TrustRule {
            euid,
            read: &real_owner_and_mode,
        };
        resolve_python_api_path_with(explicit, exe, compiled_checkout, Some(&rule))
    }
    #[cfg(not(unix))]
    {
        // No uid/mode bits to check: Windows relies on the directory ACLs.
        resolve_python_api_path_with(explicit, exe, compiled_checkout, None)
    }
}

/// Find the directory to put on `sys.path` so `import codetracer` resolves.
///
/// In order:
///
/// 1. `explicit` (the [`PYTHON_API_PATH_ENV`] environment variable).  When it
///    is set it must hold the package: a wrong value is an error naming it,
///    not a silent fall-through to some other copy.  It is trusted as given.
/// 2. The known layouts around the executable (symbolic links resolved, so a
///    profile link finds the real install), listed in `layout_candidates`:
///    an install prefix's `share/codetracer/python-api`, or the checkout's
///    `python-api` from a cargo or tup build directory inside it.  No other
///    directory above the executable is searched.
/// 3. `compiled_checkout`'s `python-api` ([`COMPILED_CHECKOUT`], debug builds
///    only).  It covers a build whose target directory is outside the
///    checkout (`CARGO_TARGET_DIR`).
///
/// A copy found in 2 or 3 is used only if `trust` accepts it
/// ([`TrustRule::check_candidate`]); a refused copy is recorded in
/// [`PythonApiLookup::refused`] with the reason, and the search goes on.
/// `trust` is `None` only where the platform has no owner and mode bits.
///
/// A lookup with no `path` means no trusted copy was found: the script then
/// relies on `codetracer` being installed in the interpreter's own
/// site-packages (the script runs in isolated mode, so `PYTHONPATH` and the
/// user's site-packages are not consulted), and when it is not, it exits
/// with a message naming
/// [`PythonApiLookup::searched`] and [`PythonApiLookup::refused`].
pub fn resolve_python_api_path_with(
    explicit: Option<&str>,
    exe: Option<&Path>,
    compiled_checkout: Option<&Path>,
    trust: Option<&TrustRule<'_>>,
) -> Result<PythonApiLookup, String> {
    if let Some(explicit) = explicit.filter(|value| !value.is_empty()) {
        let dir = PathBuf::from(explicit);
        if is_python_api_dir(&dir) {
            return Ok(PythonApiLookup::found(dir));
        }
        return Err(format!(
            "{PYTHON_API_PATH_ENV} is {explicit:?}, which does not contain the \
             codetracer package (no codetracer/__init__.py); point it at the \
             python-api directory of a CodeTracer checkout or install"
        ));
    }

    let mut candidates = Vec::new();
    if let Some(exe) = exe {
        let exe = std::fs::canonicalize(exe).unwrap_or_else(|_| exe.to_path_buf());
        if let Some(bin) = exe.parent() {
            candidates.extend(layout_candidates(bin));
        }
    }
    if let Some(checkout) = compiled_checkout {
        candidates.push(Candidate {
            anchor: checkout.to_path_buf(),
            candidate: checkout.join("python-api"),
        });
    }

    let mut lookup = PythonApiLookup {
        path: None,
        searched: Vec::new(),
        refused: Vec::new(),
    };
    for Candidate { anchor, candidate } in candidates {
        lookup.searched.push(candidate.display().to_string());
        if !is_python_api_dir(&candidate) {
            continue;
        }
        match trust.map_or(Ok(()), |rule| rule.check_candidate(&anchor, &candidate)) {
            Ok(()) => {
                lookup.path = Some(candidate);
                return Ok(lookup);
            }
            Err(reason) => lookup
                .refused
                .push(format!("{} (not trusted: {reason})", candidate.display())),
        }
    }
    Ok(lookup)
}

/// Result of executing a Python script.
///
/// Contains the captured stdout, stderr, process exit code, and a flag
/// indicating whether the process was killed due to timeout.
#[derive(Debug, Clone)]
pub struct ScriptResult {
    /// Captured standard output from the Python subprocess.
    pub stdout: String,
    /// Captured standard error from the Python subprocess.
    pub stderr: String,
    /// Process exit code (0 for success, non-zero for errors).
    ///
    /// Set to [`TIMEOUT_EXIT_CODE`] (124) when the script is killed due to
    /// timeout.
    pub exit_code: i32,
    /// Whether the subprocess was killed because it exceeded the timeout.
    pub timed_out: bool,
}

/// The interpreter file name looked for in `PATH`.
#[cfg(windows)]
const PYTHON_EXECUTABLE: &str = "python3.exe";
/// The interpreter file name looked for in `PATH`.
#[cfg(not(windows))]
const PYTHON_EXECUTABLE: &str = "python3";

/// Whether `path` is a file the daemon could execute.
fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_file()
    }
}

/// Find the Python interpreter (`python3`, `python3.exe` on Windows) that
/// runs scripts, given the value of `PATH`.
///
/// Only absolute `PATH` entries are searched, in order.  An empty entry or a
/// relative one (such as `.`) names a directory relative to the daemon's
/// working directory, which is incidental and may be shared: an interpreter
/// planted there would run every script.  The search is done here rather
/// than left to the operating system, which treats such entries as the
/// current directory.  There is no override variable: to choose another
/// interpreter, put its directory earlier in `PATH`.
///
/// # Errors
///
/// Returns a message naming the entries that were skipped when no absolute
/// entry holds an executable interpreter.
pub fn find_python3(path: Option<&std::ffi::OsStr>) -> Result<PathBuf, String> {
    let mut skipped = Vec::new();
    for dir in path.map(std::env::split_paths).into_iter().flatten() {
        if !dir.is_absolute() {
            skipped.push(format!("{:?}", dir.display().to_string()));
            continue;
        }
        let candidate = dir.join(PYTHON_EXECUTABLE);
        if is_executable_file(&candidate) {
            return Ok(candidate);
        }
    }
    let skipped = if skipped.is_empty() {
        String::new()
    } else {
        format!(
            " (relative and empty PATH entries are not searched; skipped: {})",
            skipped.join(", ")
        )
    };
    Err(format!(
        "{PYTHON_EXECUTABLE} was not found in any absolute PATH directory{skipped}"
    ))
}

/// Execute a Python script against a trace.
///
/// Spawns a `python3` subprocess (found by [`find_python3`], run in isolated
/// mode) with the CodeTracer Python API available, wrapping the user script
/// with trace initialization code.  The subprocess
/// connects back to the daemon over `socket_path` to execute trace queries.
///
/// # Arguments
///
/// * `script` - The user's Python code to execute.
/// * `trace_path` - Filesystem path to the trace directory.
/// * `socket_path` - Path to the daemon's Unix socket (passed to the Python
///   API via the `daemon_socket` parameter of `open_trace()`).
/// * `python_api` - Where the `codetracer` Python package was found (added
///   to `sys.path`), or where it was looked for (named in the script's error
///   when the package is not importable on its own).
/// * `timeout_seconds` - Maximum execution time in seconds before the
///   subprocess is killed.
///
/// # Errors
///
/// Returns `Err(String)` if the Python subprocess cannot be spawned (e.g.
/// `python3` is not found in an absolute `PATH` directory).  Script-level errors (syntax errors,
/// runtime exceptions) are represented as a successful `ScriptResult` with a
/// non-zero `exit_code` and the traceback in `stderr`.
pub async fn execute_script(
    script: &str,
    trace_path: &str,
    socket_path: &str,
    python_api: &PythonApiLookup,
    timeout_seconds: u64,
    session_id: Option<&str>,
) -> Result<ScriptResult, String> {
    let wrapper = build_wrapper_script(script, trace_path, socket_path, python_api, session_id);

    let python = find_python3(std::env::var_os("PATH").as_deref())?;
    let mut child = Command::new(&python)
        // Isolated mode (`-I`): the interpreter ignores every `PYTHON*`
        // environment variable (`PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`,
        // ...), leaves the user's site-packages out, and does not put the
        // working directory on `sys.path`.  The working directory is the
        // daemon's, which is incidental (wherever the daemon was first
        // started) and may be shared, such as `/tmp`: from there another user
        // could plant `sitecustomize.py`, `json.py` or a `codetracer/`
        // package, and a `.`, empty or relative `PYTHONPATH` element would
        // have it imported at start-up, before the wrapper's first statement
        // runs.  The directory stays the one relative file names in a script
        // resolve against.  The only directory added to `sys.path` is the
        // trusted Python API copy, by the wrapper (see `build_wrapper_script`).
        .arg("-I")
        // Never write bytecode into the Python API tree: a `__pycache__`
        // the daemon created under a group-sharing umask would make that
        // tree fail the trust rule (`TrustRule::check_candidate`) on the
        // next run.  Bytecode already in the tree is checked like any
        // other entry before it can be used.  (`-I` ignores
        // `PYTHONDONTWRITEBYTECODE`, so this is the flag form.)
        .arg("-B")
        .arg("-c")
        .arg(&wrapper)
        // Nixpkgs' interpreters read `NIX_PYTHONPATH` in their own
        // `sitecustomize`, which `-I` does not disable, and pass each entry
        // to `site.addsitedir`: a relative entry would name the working
        // directory and run any `.pth` file planted there.  A Nix
        // `python3.withPackages` wrapper sets the variable itself when it
        // starts the interpreter, so removing the inherited value only drops
        // what the daemon's environment happened to carry.
        .env_remove("NIX_PYTHONPATH")
        // Prevent the child from inheriting stdin (avoids blocking on tty reads).
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to spawn {}: {e}", python.display()))?;

    // Take ownership of the stdout/stderr handles so we can read them
    // concurrently with waiting for the process to exit.  This also lets
    // us kill the child on timeout without a borrow conflict.
    let mut stdout_handle = child.stdout.take();
    let mut stderr_handle = child.stderr.take();

    // Collect stdout and stderr concurrently while waiting for the process.
    let wait_result = timeout(Duration::from_secs(timeout_seconds), async {
        // Read stdout and stderr in background tasks.
        let stdout_task = tokio::spawn(async move {
            let mut buf = Vec::new();
            if let Some(ref mut handle) = stdout_handle {
                let _ = tokio::io::AsyncReadExt::read_to_end(handle, &mut buf).await;
            }
            buf
        });
        let stderr_task = tokio::spawn(async move {
            let mut buf = Vec::new();
            if let Some(ref mut handle) = stderr_handle {
                let _ = tokio::io::AsyncReadExt::read_to_end(handle, &mut buf).await;
            }
            buf
        });

        let status = child.wait().await;
        let stdout_bytes = stdout_task.await.unwrap_or_default();
        let stderr_bytes = stderr_task.await.unwrap_or_default();

        (status, stdout_bytes, stderr_bytes)
    })
    .await;

    match wait_result {
        Ok((Ok(status), stdout_bytes, stderr_bytes)) => Ok(ScriptResult {
            stdout: String::from_utf8_lossy(&stdout_bytes).to_string(),
            stderr: String::from_utf8_lossy(&stderr_bytes).to_string(),
            exit_code: status.code().unwrap_or(1),
            timed_out: false,
        }),
        Ok((Err(e), _, _)) => Err(format!("Script execution I/O error: {e}")),
        Err(_) => {
            // Timeout reached — kill the subprocess and return a timeout result.
            //
            // Note: `child` was moved into the async block above, but the
            // timeout means that block's future was dropped.  The drop
            // implementation of `tokio::process::Child` kills the child
            // process automatically when the handle is dropped.
            Ok(ScriptResult {
                stdout: String::new(),
                stderr: format!("Script execution timed out after {timeout_seconds} seconds"),
                exit_code: TIMEOUT_EXIT_CODE,
                timed_out: true,
            })
        }
    }
}

/// Build the Python wrapper script that initialises the trace and runs user code.
///
/// The wrapper:
/// 1. Removes any entry naming the daemon's working directory from
///    `sys.path` ([`STRIP_WORKING_DIRECTORY`]), then inserts `python_api.path` at the
///    front so `import codetracer` resolves to the local package.  Without
///    one, nothing is added, and a failed import exits naming the places
///    searched and
///    [`PYTHON_API_PATH_ENV`], instead of ending in a bare `ImportError`.
///    Copies refused by the trust rule are named on stderr in any case.
/// 2. Sets `CODETRACER_DAEMON_SOCK` and `CODETRACER_TRACE_PATH` environment
///    variables for any downstream code that needs them.
/// 3. Opens the trace via `codetracer.open_trace()`, passing the daemon socket
///    explicitly so the Python API does not need to discover it.
/// 4. Executes the user script with `trace` in scope.
/// 5. Closes the trace in a `finally` block.
fn build_wrapper_script(
    script: &str,
    trace_path: &str,
    socket_path: &str,
    python_api: &PythonApiLookup,
    session_id: Option<&str>,
) -> String {
    // Escape backslashes and quotes in the path strings so they are safe inside
    // Python string literals.  This prevents injection when paths contain
    // special characters (e.g. backslashes on Windows or quotes in file names).
    let sock_escaped = escape_for_python(socket_path);
    let trace_escaped = escape_for_python(trace_path);
    let indented = indent_script(script);

    let finally_block = if session_id.is_some() {
        // Stateful session: do NOT send ct/close-trace.
        // The socket closes when the subprocess exits, but the daemon
        // keeps the backend alive via TTL for the next call.
        "    pass  # stateful session: trace kept alive for next call"
    } else {
        "    trace.close()"
    };

    let sys_path_line = match &python_api.path {
        Some(path) => format!(
            "sys.path.insert(0, \"{}\")\n",
            escape_for_python(&path.to_string_lossy())
        ),
        None => String::new(),
    };
    let searched = if python_api.searched.is_empty() {
        "nowhere".to_string()
    } else {
        python_api.searched.join("; ")
    };
    let searched_escaped = escape_for_python(&searched);
    // A copy refused by the trust rule is reported on stderr whether or not
    // the import then succeeds from elsewhere, so it is never silent.
    let refused_line = if python_api.refused.is_empty() {
        String::new()
    } else {
        format!(
            "sys.stderr.write(\"warning: ignored an untrusted CodeTracer Python API: {}\\n\")\n",
            escape_for_python(&python_api.refused.join("; "))
        )
    };

    // `sys` is built in and `os` is loaded during interpreter start-up, so
    // neither import looks at `sys.path`; the statement after them is the
    // first that runs before any module is searched for.
    format!(
        r#"import sys, os
{STRIP_WORKING_DIRECTORY}
{sys_path_line}{refused_line}os.environ["CODETRACER_DAEMON_SOCK"] = "{sock_escaped}"
os.environ["CODETRACER_TRACE_PATH"] = "{trace_escaped}"
try:
    from codetracer import open_trace
except ImportError as _ct_import_error:
    sys.exit("the CodeTracer Python API (the codetracer package) is not importable: "
             + str(_ct_import_error)
             + "; looked for its python-api directory in: {searched_escaped}"
             + "; set {PYTHON_API_PATH_ENV} to that directory or install the package"
             + " into the site-packages of " + sys.executable)
trace = open_trace("{trace_escaped}", daemon_socket="{sock_escaped}")
try:
{indented}
finally:
{finally_block}
"#
    )
}

/// The wrapper's first statement: remove from `sys.path` the empty entry
/// (it means the working directory) and every entry naming the working
/// directory itself.  The working directory is the daemon's, which is
/// incidental and may be shared: from a world-writable directory another
/// user could plant `json.py` or a `codetracer/` package and have it run
/// inside every script.  Isolated mode (`-I`, see [`execute_script`])
/// already keeps both kinds of entry out, and `PYTHONPATH` with them (the
/// flag exists since Python 3.4; `python3 -I -c` leaves the empty entry out
/// on 3.10 as on 3.13, before 3.11 introduced safe-path mode); this is a
/// second line of defence that does not depend on the interpreter's version
/// or its site configuration.  It cannot help
/// against code that runs during start-up, before the wrapper: that is what
/// `-I` is for.
const STRIP_WORKING_DIRECTORY: &str = r#"try:
    _ct_cwd = os.path.realpath(os.getcwd())
except OSError:
    _ct_cwd = None
sys.path[:] = [_ct_p for _ct_p in sys.path
               if _ct_p and (_ct_cwd is None or os.path.realpath(_ct_p) != _ct_cwd)]"#;

/// Escape a string for inclusion inside a Python double-quoted string literal.
///
/// Handles backslashes, double quotes, newlines, and carriage returns.
fn escape_for_python(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

/// Indent every line of `script` by 4 spaces so it sits inside a `try:` block.
///
/// Empty scripts are replaced with `pass` to avoid a SyntaxError.
fn indent_script(script: &str) -> String {
    if script.trim().is_empty() {
        return "    pass".to_string();
    }
    script
        .lines()
        .map(|line| format!("    {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_indent_script_single_line() {
        let result = indent_script("print('hello')");
        assert_eq!(result, "    print('hello')");
    }

    #[test]
    fn test_indent_script_multi_line() {
        let result = indent_script("a = 1\nb = 2\nprint(a + b)");
        assert_eq!(result, "    a = 1\n    b = 2\n    print(a + b)");
    }

    #[test]
    fn test_indent_script_empty() {
        let result = indent_script("");
        assert_eq!(result, "    pass");
    }

    #[test]
    fn test_indent_script_whitespace_only() {
        let result = indent_script("   \n  ");
        assert_eq!(result, "    pass");
    }

    #[test]
    fn test_escape_for_python_basic() {
        assert_eq!(escape_for_python("hello"), "hello");
    }

    #[test]
    fn test_escape_for_python_quotes() {
        assert_eq!(escape_for_python(r#"say "hi""#), r#"say \"hi\""#);
    }

    #[test]
    fn test_escape_for_python_backslash() {
        assert_eq!(escape_for_python(r"C:\path"), r"C:\\path");
    }

    #[test]
    fn test_escape_for_python_newline() {
        assert_eq!(escape_for_python("a\nb"), "a\\nb");
    }

    #[test]
    fn test_build_wrapper_contains_imports() {
        let wrapper = build_wrapper_script(
            "print('hello')",
            "/tmp/trace",
            "/tmp/sock",
            &PythonApiLookup::found("/tmp/api"),
            None,
        );
        assert!(wrapper.contains("import sys, os"));
        assert!(wrapper.contains("from codetracer import open_trace"));
        assert!(wrapper.contains("trace = open_trace("));
        assert!(wrapper.contains("trace.close()"));
        assert!(wrapper.contains("    print('hello')"));
    }

    #[test]
    fn test_build_wrapper_escapes_paths() {
        let wrapper = build_wrapper_script(
            "pass",
            "/tmp/trace with \"quotes\"",
            "/tmp/sock",
            &PythonApiLookup::found("/tmp/api"),
            None,
        );
        assert!(wrapper.contains(r#"/tmp/trace with \"quotes\""#));
    }

    #[test]
    fn test_build_wrapper_stateless_closes_trace() {
        let wrapper = build_wrapper_script(
            "print('hello')",
            "/tmp/trace",
            "/tmp/sock",
            &PythonApiLookup::found("/tmp/api"),
            None,
        );
        assert!(wrapper.contains("trace.close()"));
        assert!(!wrapper.contains("stateful session"));
    }

    #[test]
    fn test_build_wrapper_session_keeps_trace_alive() {
        let wrapper = build_wrapper_script(
            "print('hello')",
            "/tmp/trace",
            "/tmp/sock",
            &PythonApiLookup::found("/tmp/api"),
            Some("debug-1"),
        );
        assert!(!wrapper.contains("trace.close()"));
        assert!(wrapper.contains("stateful session"));
    }

    /// With no package found, nothing is put on `sys.path` (an empty entry
    /// would be the daemon's working directory); with one, it is inserted.
    #[test]
    fn test_build_wrapper_adds_sys_path_only_for_a_found_package() {
        let missing = PythonApiLookup {
            path: None,
            searched: vec!["/x/python-api".to_string()],
            refused: Vec::new(),
        };
        let wrapper = build_wrapper_script("pass", "/tmp/trace", "/tmp/sock", &missing, None);
        assert!(!wrapper.contains("sys.path.insert"), "{wrapper}");
        assert!(!wrapper.contains("untrusted"), "{wrapper}");
        let found = PythonApiLookup::found("/opt/api");
        let wrapper = build_wrapper_script("pass", "/tmp/trace", "/tmp/sock", &found, None);
        assert!(
            wrapper.contains("sys.path.insert(0, \"/opt/api\")"),
            "{wrapper}"
        );
    }

    // --- resolve_python_api_path ---------------------------------------
    //
    // These run against real directory trees in a temporary directory: the
    // function's whole job is to look at the filesystem, so a stubbed
    // filesystem would test nothing.  The one injected seam is the
    // owner-and-mode reader in `test_resolve_python_api_refuses_a_directory_owned_by_another_user`
    // and `test_resolve_python_api_accepts_a_root_owned_directory`: an
    // unprivileged test cannot chown a directory to another user or to root,
    // so the reader reports a different owner for one named directory and
    // reads the real filesystem for every other path.  Group- and
    // world-writable directories need no privileges and are tested on the
    // real filesystem through the production reader.

    use std::os::unix::fs::PermissionsExt;

    /// Set `path`'s permission bits.
    fn chmod(path: &Path, mode: u32) {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).expect("chmod");
    }

    /// Give every directory under `root` mode 0755 and every file 0644, so a
    /// test's tree does not depend on the umask it runs under.
    fn tighten(root: &Path) {
        for entry in std::fs::read_dir(root).expect("read dir") {
            let path = entry.expect("dir entry").path();
            let meta = std::fs::symlink_metadata(&path).expect("metadata");
            if meta.is_dir() {
                chmod(&path, 0o755);
                tighten(&path);
            } else if meta.is_file() {
                chmod(&path, 0o644);
            }
        }
    }

    /// Create `<dir>/codetracer/__init__.py`, making `dir` a python-api
    /// directory, and return `dir`.
    fn make_api_dir(dir: &Path) -> PathBuf {
        std::fs::create_dir_all(dir.join("codetracer")).expect("create package dir");
        std::fs::write(dir.join("codetracer").join("__init__.py"), "").expect("write __init__");
        dir.to_path_buf()
    }

    /// Create an empty file at `path` standing for the binary being located.
    fn make_exe(path: &Path) -> PathBuf {
        std::fs::create_dir_all(path.parent().expect("exe has a parent")).expect("create bin dir");
        std::fs::write(path, "").expect("write exe");
        path.to_path_buf()
    }

    fn canonical(path: &Path) -> PathBuf {
        std::fs::canonicalize(path).expect("canonical path")
    }

    /// Resolve with the production trust rule (real filesystem, real euid).
    fn resolve(exe: Option<&Path>, checkout: Option<&Path>) -> PythonApiLookup {
        resolve_python_api_path(None, exe, checkout).expect("resolves")
    }

    fn found_path(lookup: &PythonApiLookup) -> Option<PathBuf> {
        lookup.path.as_deref().map(canonical)
    }

    #[test]
    fn test_resolve_python_api_explicit_path_wins() {
        let root = tempfile::tempdir().expect("tempdir");
        let explicit = make_api_dir(&root.path().join("explicit"));
        let checkout = root.path().join("repo");
        make_api_dir(&checkout.join("python-api"));
        let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
        tighten(root.path());
        let found =
            resolve_python_api_path(explicit.to_str(), Some(&exe), Some(&checkout)).expect("ok");
        assert_eq!(found.path, Some(explicit));
    }

    /// The explicit directory is trusted as given: a group-writable one is
    /// still used, because the user chose it.
    #[test]
    fn test_resolve_python_api_explicit_path_is_trusted_as_given() {
        let root = tempfile::tempdir().expect("tempdir");
        let explicit = make_api_dir(&root.path().join("explicit"));
        tighten(root.path());
        chmod(&explicit, 0o775);
        let found = resolve_python_api_path(explicit.to_str(), None, None).expect("ok");
        assert_eq!(found.path, Some(explicit));
    }

    #[test]
    fn test_resolve_python_api_explicit_path_without_package_is_refused() {
        let root = tempfile::tempdir().expect("tempdir");
        let empty = root.path().join("not-an-api");
        std::fs::create_dir_all(&empty).expect("create dir");
        // A checkout copy exists, and must not be used in its place.
        let checkout = root.path().join("repo");
        make_api_dir(&checkout.join("python-api"));
        let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
        tighten(root.path());
        let err = resolve_python_api_path(empty.to_str(), Some(&exe), Some(&checkout))
            .expect_err("refused");
        assert!(err.contains(PYTHON_API_PATH_ENV), "{err}");
        assert!(err.contains("not-an-api"), "{err}");
    }

    /// An empty explicit value counts as unset, as an exported-but-blank
    /// variable does in a shell.
    #[test]
    fn test_resolve_python_api_empty_explicit_value_is_unset() {
        let root = tempfile::tempdir().expect("tempdir");
        let api = make_api_dir(&root.path().join("repo/python-api"));
        let exe = make_exe(&root.path().join("repo/src/build-debug/bin/session-manager"));
        tighten(root.path());
        let found = resolve_python_api_path(Some(""), Some(&exe), None).expect("ok");
        assert_eq!(found_path(&found), Some(canonical(&api)));
    }

    /// Every accepted checkout layout finds `<repo>/python-api`.
    #[test]
    fn test_resolve_python_api_from_each_build_dir_layout_in_the_checkout() {
        let root = tempfile::tempdir().expect("tempdir");
        let api = make_api_dir(&root.path().join("repo/python-api"));
        let exes = [
            "repo/src/backend-manager/target/debug/session-manager",
            "repo/src/backend-manager/target/release/session-manager",
            "repo/src/backend-manager/target/x86_64-unknown-linux-gnu/release/session-manager",
            "repo/src/build-debug/bin/session-manager",
            "repo/src/build-release/bin/session-manager",
        ]
        .map(|exe| make_exe(&root.path().join(exe)));
        tighten(root.path());
        for exe in exes {
            let found = resolve(Some(&exe), None);
            assert_eq!(
                found_path(&found),
                Some(canonical(&api)),
                "from {}: {found:?}",
                exe.display()
            );
        }
    }

    /// A build directory that matches no layout finds nothing, even with a
    /// python-api directory in a parent: there is no ancestor walk.
    #[test]
    fn test_resolve_python_api_does_not_walk_up_from_an_unknown_layout() {
        let root = tempfile::tempdir().expect("tempdir");
        make_api_dir(&root.path().join("repo/python-api"));
        let exe = make_exe(&root.path().join("repo/some/other/dir/session-manager"));
        tighten(root.path());
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        assert!(found.searched.is_empty(), "{found:?}");
    }

    #[test]
    fn test_resolve_python_api_from_an_install_prefix_through_a_symlink() {
        let root = tempfile::tempdir().expect("tempdir");
        let api = make_api_dir(&root.path().join("prefix/share/codetracer/python-api"));
        let exe = make_exe(&root.path().join("prefix/bin/session-manager"));
        // A profile directory linking to the install, as a package manager
        // does: the link's own parent holds no python-api.
        let profile_bin = root.path().join("profile/bin");
        std::fs::create_dir_all(&profile_bin).expect("create profile");
        let link = profile_bin.join("session-manager");
        std::os::unix::fs::symlink(&exe, &link).expect("symlink");
        tighten(root.path());
        let found = resolve(Some(&link), None);
        assert_eq!(found_path(&found), Some(canonical(&api)));
    }

    /// A target directory outside the checkout (`CARGO_TARGET_DIR`): no
    /// layout matches and the compiled-from checkout is used.
    #[test]
    fn test_resolve_python_api_cargo_target_dir_falls_back_to_the_checkout() {
        let root = tempfile::tempdir().expect("tempdir");
        let exe = make_exe(&root.path().join("cache/target/debug/session-manager"));
        let checkout = root.path().join("repo");
        let api = make_api_dir(&checkout.join("python-api"));
        tighten(root.path());
        let found = resolve(Some(&exe), Some(&checkout));
        assert_eq!(found.path, Some(api));
    }

    /// Nothing holds the package: no path, and the exact places searched are
    /// reported.  A `python-api` directory without the package does not count.
    #[test]
    fn test_resolve_python_api_reports_the_places_searched_when_nothing_holds_it() {
        let root = tempfile::tempdir().expect("tempdir");
        let exe = make_exe(&root.path().join("prefix/bin/session-manager"));
        std::fs::create_dir_all(root.path().join("prefix/share/codetracer/python-api"))
            .expect("create dir");
        let checkout = root.path().join("gone");
        tighten(root.path());
        let found = resolve(Some(&exe), Some(&checkout));
        assert_eq!(found.path, None);
        assert_eq!(
            found.searched,
            vec![
                canonical(&root.path().join("prefix"))
                    .join("share/codetracer/python-api")
                    .display()
                    .to_string(),
                checkout.join("python-api").display().to_string(),
            ]
        );
        assert!(found.refused.is_empty(), "{found:?}");
    }

    /// The reviewed attack: an AppImage runs from `$TMPDIR/.mount_XXXX/bin`,
    /// no python-api ships inside it, and another local user plants
    /// `$TMPDIR/python-api/codetracer/__init__.py` in the shared, sticky,
    /// world-writable temporary directory.  The planted package must not be
    /// used, nor even looked at.
    #[test]
    fn test_resolve_python_api_ignores_a_package_planted_above_an_appimage_mount() {
        let root = tempfile::tempdir().expect("tempdir");
        let shared_tmp = root.path().join("tmp");
        let exe = make_exe(&shared_tmp.join(".mount_ctAbC/bin/session-manager"));
        let planted = make_api_dir(&shared_tmp.join("python-api"));
        tighten(root.path());
        chmod(&shared_tmp, 0o1777);
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        let planted = canonical(&planted).display().to_string();
        assert!(
            !found.searched.iter().any(|s| s.starts_with(&planted)),
            "{found:?}"
        );
    }

    /// A package at a known layout, but with a world-writable directory
    /// between it and the install prefix, is refused with the reason, on the
    /// real filesystem.
    #[test]
    fn test_resolve_python_api_refuses_a_world_writable_directory_on_the_way() {
        let root = tempfile::tempdir().expect("tempdir");
        let api = make_api_dir(&root.path().join("prefix/share/codetracer/python-api"));
        let exe = make_exe(&root.path().join("prefix/bin/session-manager"));
        tighten(root.path());
        let share = root.path().join("prefix/share");
        chmod(&share, 0o1777);
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        assert_eq!(found.refused.len(), 1, "{found:?}");
        let reason = &found.refused[0];
        assert!(
            reason.contains(&canonical(&api).display().to_string()),
            "{reason}"
        );
        assert!(
            reason.contains(&canonical(&share).display().to_string()),
            "{reason}"
        );
        assert!(reason.contains("writable by every user"), "{reason}");
    }

    /// A group-writable candidate, and separately a group-writable package
    /// directory inside a trusted candidate, are each refused.
    #[test]
    fn test_resolve_python_api_refuses_a_group_writable_directory() {
        for writable in ["python-api", "python-api/codetracer"] {
            let root = tempfile::tempdir().expect("tempdir");
            let checkout = root.path().join("repo");
            make_api_dir(&checkout.join("python-api"));
            let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
            tighten(root.path());
            chmod(&checkout.join(writable), 0o775);
            let found = resolve(Some(&exe), None);
            assert_eq!(found.path, None, "{writable}: {found:?}");
            assert_eq!(found.refused.len(), 1, "{writable}: {found:?}");
            assert!(
                found.refused[0].contains("writable by its group"),
                "{writable}: {found:?}"
            );
        }
    }

    /// A symbolic link from a trusted checkout into a world-writable
    /// directory is followed, and the target's directories are checked.
    #[test]
    fn test_resolve_python_api_refuses_a_symlink_into_a_world_writable_directory() {
        let root = tempfile::tempdir().expect("tempdir");
        let shared = root.path().join("shared");
        make_api_dir(&shared.join("api"));
        let checkout = root.path().join("repo");
        let exe = make_exe(&checkout.join("src/build-debug/bin/session-manager"));
        std::os::unix::fs::symlink(shared.join("api"), checkout.join("python-api"))
            .expect("symlink");
        tighten(root.path());
        chmod(&shared, 0o777);
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        assert_eq!(found.refused.len(), 1, "{found:?}");
        assert!(
            found.refused[0].contains(&canonical(&shared).display().to_string()),
            "{found:?}"
        );
    }

    /// An untrusted copy is skipped, not fatal: a trusted copy later in the
    /// order is still used, and the refusal is still reported.
    #[test]
    fn test_resolve_python_api_uses_a_later_trusted_copy_after_a_refusal() {
        let root = tempfile::tempdir().expect("tempdir");
        make_api_dir(&root.path().join("prefix/share/codetracer/python-api"));
        let exe = make_exe(&root.path().join("prefix/bin/session-manager"));
        let checkout = root.path().join("repo");
        let api = make_api_dir(&checkout.join("python-api"));
        tighten(root.path());
        chmod(&root.path().join("prefix/share"), 0o777);
        let found = resolve(Some(&exe), Some(&checkout));
        assert_eq!(found.path, Some(api));
        assert_eq!(found.refused.len(), 1, "{found:?}");
    }

    /// A reader that reports `owner` for `path` (canonical) and reads the
    /// real filesystem for everything else.  See the section comment for why
    /// this seam exists.
    fn reader_with_owner(
        path: PathBuf,
        owner: u32,
    ) -> impl Fn(&Path) -> std::io::Result<OwnerAndMode> {
        move |p: &Path| {
            let mut facts = real_owner_and_mode(p)?;
            if p == path {
                facts.uid = owner;
            }
            Ok(facts)
        }
    }

    /// This process's effective user id.
    fn euid() -> u32 {
        // SAFETY: geteuid has no preconditions and cannot fail.
        unsafe { libc::geteuid() }
    }

    #[test]
    fn test_resolve_python_api_refuses_a_directory_owned_by_another_user() {
        let root = tempfile::tempdir().expect("tempdir");
        let checkout = root.path().join("repo");
        let api = make_api_dir(&checkout.join("python-api"));
        let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
        tighten(root.path());
        let other = euid().wrapping_add(4242).max(1);
        let read = reader_with_owner(canonical(&api.join("codetracer")), other);
        let rule = TrustRule {
            euid: euid(),
            read: &read,
        };
        let found = resolve_python_api_path_with(None, Some(&exe), None, Some(&rule)).expect("ok");
        assert_eq!(found.path, None, "{found:?}");
        assert_eq!(found.refused.len(), 1, "{found:?}");
        assert!(
            found.refused[0].contains(&format!("owned by uid {other}")),
            "{found:?}"
        );
    }

    #[test]
    fn test_resolve_python_api_accepts_a_root_owned_directory() {
        let root = tempfile::tempdir().expect("tempdir");
        let checkout = root.path().join("repo");
        let api = make_api_dir(&checkout.join("python-api"));
        let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
        tighten(root.path());
        let read = reader_with_owner(canonical(&api), 0);
        let rule = TrustRule {
            euid: euid(),
            read: &read,
        };
        let found = resolve_python_api_path_with(None, Some(&exe), None, Some(&rule)).expect("ok");
        assert_eq!(found_path(&found), Some(canonical(&api)));
    }

    /// The compiled-from checkout is subject to the trust rule too.
    #[test]
    fn test_resolve_python_api_refuses_an_untrusted_compiled_checkout() {
        let root = tempfile::tempdir().expect("tempdir");
        let checkout = root.path().join("repo");
        make_api_dir(&checkout.join("python-api"));
        tighten(root.path());
        chmod(&checkout, 0o777);
        let found = resolve(None, Some(&checkout));
        assert_eq!(found.path, None, "{found:?}");
        assert_eq!(found.refused.len(), 1, "{found:?}");
    }

    /// A debug build knows the checkout it was compiled from, and that
    /// checkout holds the Python API.
    #[cfg(debug_assertions)]
    #[test]
    fn test_debug_build_has_the_compiled_checkout() {
        let checkout = COMPILED_CHECKOUT.expect("debug build names its checkout");
        assert!(
            is_python_api_dir(&Path::new(checkout).join("python-api")),
            "{checkout}"
        );
    }

    /// A release build carries no build-machine path, so its lookup can only
    /// use the layouts around the executable (`cargo test --release`).
    #[cfg(not(debug_assertions))]
    #[test]
    fn test_release_build_has_no_compiled_checkout() {
        assert_eq!(COMPILED_CHECKOUT, None);
    }

    /// When no copy was found and `codetracer` is not importable on its own,
    /// the script exits with a message naming every place searched, the
    /// refused copy with its reason, and the variable to set.  Runs the real
    /// wrapper under the real interpreter; `-I -S` keeps the user's
    /// site-packages and `PYTHONPATH` out, so the import fails the way it
    /// does on a host without the package installed.  This checks the
    /// message only: what the production spawn imports, from which
    /// directory, is checked through `execute_script` itself by the
    /// `test_exec_script_*_working_directory` tests below.
    #[test]
    fn test_wrapper_names_the_places_searched_when_the_package_is_missing() {
        let root = tempfile::tempdir().expect("tempdir");
        let exe = make_exe(&root.path().join("prefix/bin/session-manager"));
        make_api_dir(&root.path().join("prefix/share/codetracer/python-api"));
        tighten(root.path());
        chmod(&root.path().join("prefix/share"), 0o777);
        let checkout = root.path().join("checkout");
        let lookup = resolve(Some(&exe), Some(&checkout));
        assert_eq!(lookup.path, None);
        let wrapper =
            build_wrapper_script("print('ran')", "/tmp/trace", "/tmp/sock", &lookup, None);
        let output = std::process::Command::new("python3")
            .args(["-I", "-S", "-c", &wrapper])
            .current_dir(root.path())
            .output()
            .expect("python3 runs");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "stderr: {stderr}");
        assert!(!String::from_utf8_lossy(&output.stdout).contains("ran"));
        assert!(
            stderr.contains("codetracer package) is not importable"),
            "{stderr}"
        );
        let prefix_api = canonical(&root.path().join("prefix/share/codetracer/python-api"));
        assert!(
            stderr.contains(&prefix_api.display().to_string()),
            "{stderr}"
        );
        assert!(
            stderr.contains("warning: ignored an untrusted CodeTracer Python API"),
            "{stderr}"
        );
        assert!(stderr.contains("writable by every user"), "{stderr}");
        let checkout_api = checkout.join("python-api");
        assert!(
            stderr.contains(&checkout_api.display().to_string()),
            "{stderr}"
        );
        assert!(stderr.contains(PYTHON_API_PATH_ENV), "{stderr}");
    }

    // --- The whole python-api tree is checked -------------------------

    /// A trusted checkout layout with a real-looking package: `trace.py`
    /// beside `__init__.py`, and a `__pycache__` holding bytecode.  Returns
    /// (executable, python-api directory).
    fn make_checkout_with_bytecode(root: &Path) -> (PathBuf, PathBuf) {
        let checkout = root.join("repo");
        let api = make_api_dir(&checkout.join("python-api"));
        std::fs::write(api.join("codetracer/trace.py"), "X = 1\n").expect("write trace.py");
        let cache = api.join("codetracer/__pycache__");
        std::fs::create_dir_all(&cache).expect("create __pycache__");
        std::fs::write(cache.join("trace.cpython-312.pyc"), b"\x00").expect("write pyc");
        let exe = make_exe(&checkout.join("src/backend-manager/target/debug/session-manager"));
        tighten(root);
        (exe, api)
    }

    /// The positive control for the tree walk: a package with modules,
    /// bytecode, a subpackage, a symbolic link to a file inside the tree and
    /// a link cycle, none of it writable by others, is accepted.
    #[test]
    fn test_resolve_python_api_accepts_a_trusted_tree_with_bytecode() {
        let root = tempfile::tempdir().expect("tempdir");
        let (exe, api) = make_checkout_with_bytecode(root.path());
        std::fs::create_dir_all(api.join("codetracer/sub")).expect("create subpackage");
        std::fs::write(api.join("codetracer/sub/__init__.py"), "").expect("write sub");
        tighten(root.path());
        std::os::unix::fs::symlink(
            api.join("codetracer/trace.py"),
            api.join("codetracer/sub/alias.py"),
        )
        .expect("symlink");
        std::os::unix::fs::symlink(api.join("codetracer"), api.join("codetracer/sub/loop"))
            .expect("symlink");
        let found = resolve(Some(&exe), None);
        assert_eq!(found_path(&found), Some(canonical(&api)), "{found:?}");
        assert!(found.refused.is_empty(), "{found:?}");
    }

    /// Each of these, made writable by others in an otherwise trusted tree,
    /// gets the whole copy refused, with the entry and the reason named: a
    /// module other than `__init__.py`; the `__pycache__` directory holding
    /// planted bytecode; a bytecode file; and a module beside the package,
    /// which would shadow the standard library module of its name.
    #[test]
    fn test_resolve_python_api_refuses_any_writable_entry_in_the_tree() {
        let cases: [(&str, u32, &str); 5] = [
            ("codetracer/trace.py", 0o666, "writable by every user"),
            ("codetracer/trace.py", 0o664, "writable by its group"),
            ("codetracer/__pycache__", 0o777, "writable by every user"),
            (
                "codetracer/__pycache__/trace.cpython-312.pyc",
                0o666,
                "writable by every user",
            ),
            ("json.py", 0o666, "writable by every user"),
        ];
        for (entry, mode, reason) in cases {
            let root = tempfile::tempdir().expect("tempdir");
            let (exe, api) = make_checkout_with_bytecode(root.path());
            std::fs::write(api.join("json.py"), "").expect("write json.py");
            tighten(root.path());
            chmod(&api.join(entry), mode);
            let found = resolve(Some(&exe), None);
            assert_eq!(found.path, None, "{entry}: {found:?}");
            assert_eq!(found.refused.len(), 1, "{entry}: {found:?}");
            let named = canonical(&api.join(entry)).display().to_string();
            assert!(found.refused[0].contains(&named), "{entry}: {found:?}");
            assert!(found.refused[0].contains(reason), "{entry}: {found:?}");
        }
    }

    /// A symbolic link inside the tree is followed: one into a world-writable
    /// directory is refused, and so is one that does not resolve (whoever
    /// creates its target would choose what is imported).
    #[test]
    fn test_resolve_python_api_refuses_links_in_the_tree_that_leave_trust() {
        let root = tempfile::tempdir().expect("tempdir");
        let (exe, api) = make_checkout_with_bytecode(root.path());
        let shared = root.path().join("shared");
        std::fs::create_dir_all(&shared).expect("create shared");
        std::fs::write(shared.join("helper.py"), "").expect("write helper");
        tighten(root.path());
        chmod(&shared, 0o1777);
        let link = api.join("codetracer/helper.py");
        std::os::unix::fs::symlink(shared.join("helper.py"), &link).expect("symlink");
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        assert!(
            found.refused[0].contains(&canonical(&shared).display().to_string()),
            "{found:?}"
        );

        std::fs::remove_file(&link).expect("remove link");
        std::os::unix::fs::symlink(root.path().join("not-yet"), &link).expect("symlink");
        let found = resolve(Some(&exe), None);
        assert_eq!(found.path, None, "{found:?}");
        assert!(found.refused[0].contains("cannot resolve"), "{found:?}");
    }

    // --- The working directory is never an import location ------------
    //
    // These go through `execute_script`, the daemon's own spawn path, with
    // the real interpreter and the real `codetracer` package.  The child
    // inherits the daemon's working directory, and a test cannot change its
    // own process's directory without racing the tests beside it, so each
    // case re-runs this test binary, filtered to one test, in a fresh
    // sticky world-writable directory standing for a shared `/tmp`; there
    // the test sees `CWD_PROBE_ENV` and calls `execute_script` once,
    // printing the result for the parent to check.  The daemon socket does
    // not exist, so `open_trace` fails after `codetracer` (and the `json`
    // module it imports) has been imported: the import is what is tested.
    //
    // Two tests need the user's code itself to run, which the real package
    // only allows with a live daemon.  They use a stand-in `codetracer`
    // package whose `open_trace` returns an object with a no-op `close`:
    // what they check is the interpreter state the wrapper and the spawn
    // leave for user code, and which interpreter ran it, neither of which
    // depends on the daemon.
    //
    // The environment variables a case sets (`PYTHONPATH`, `PATH`, `HOME`,
    // ...) are set on the re-run test binary, which is the daemon's stand-in:
    // `execute_script` passes them on to the child as the daemon would.

    const CWD_PROBE_ENV: &str = "CT_TEST_EXEC_SCRIPT_CWD_PROBE";
    const PLANTED: &str = "PLANTED-MODULE-RAN";

    /// A copy of this checkout's `python-api/codetracer` (without bytecode)
    /// under `dir`, so a test can check what the run wrote into it.
    fn copy_real_api(dir: &Path) -> PathBuf {
        fn copy(from: &Path, to: &Path) {
            std::fs::create_dir_all(to).expect("create dir");
            for entry in std::fs::read_dir(from).expect("read dir") {
                let entry = entry.expect("dir entry");
                let name = entry.file_name();
                if name == "__pycache__" {
                    continue;
                }
                if entry.file_type().expect("file type").is_dir() {
                    copy(&entry.path(), &to.join(&name));
                } else {
                    std::fs::copy(entry.path(), to.join(&name)).expect("copy file");
                }
            }
        }
        let real = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../python-api/codetracer");
        copy(&real, &dir.join("codetracer"));
        tighten(dir);
        dir.to_path_buf()
    }

    /// In the probe process: run one script through `execute_script` with
    /// the lookup described by the environment, and print the result.
    async fn cwd_probe() {
        let script = std::env::var("CT_TEST_PROBE_SCRIPT")
            .unwrap_or_else(|_| "print('user script ran')".to_string());
        let lookup = match std::env::var("CT_TEST_PROBE_API")
            .ok()
            .filter(|v| !v.is_empty())
        {
            Some(path) => PythonApiLookup::found(path),
            None => PythonApiLookup {
                path: None,
                searched: vec!["/nonexistent/python-api".to_string()],
                refused: Vec::new(),
            },
        };
        let result = execute_script(
            &script,
            "/nonexistent/trace",
            "/nonexistent/daemon.sock",
            &lookup,
            60,
            None,
        )
        .await
        .expect("python3 spawns");
        println!(
            "PROBE-RESULT {}",
            serde_json::json!({
                "exit": result.exit_code,
                "stdout": result.stdout,
                "stderr": result.stderr,
            })
        );
    }

    /// The result of one probe run: (exit code, stdout, stderr).
    fn run_cwd_probe(test: &str, cwd: &Path, envs: &[(&str, String)]) -> (i64, String, String) {
        let module = module_path!().split_once("::").map_or("", |(_, rest)| rest);
        let output = std::process::Command::new(std::env::current_exe().expect("test binary"))
            .args([&format!("{module}::{test}"), "--exact", "--nocapture"])
            .current_dir(cwd)
            .env(CWD_PROBE_ENV, "1")
            .envs(envs.iter().map(|(k, v)| (*k, v.as_str())))
            .output()
            .expect("probe runs");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout
            .lines()
            .find_map(|l| l.strip_prefix("PROBE-RESULT "))
            .unwrap_or_else(|| panic!("no probe result: {stdout} {:?}", output.stderr));
        let value: serde_json::Value = serde_json::from_str(line).expect("probe json");
        (
            value["exit"].as_i64().expect("exit"),
            value["stdout"].as_str().expect("stdout").to_string(),
            value["stderr"].as_str().expect("stderr").to_string(),
        )
    }

    /// A file that announces itself on stderr, with `tag`, when Python runs
    /// it.
    fn announce(tag: &str) -> String {
        format!("import sys\nsys.stderr.write('{PLANTED} {tag}\\n')\n")
    }

    /// A sticky, world-writable directory standing for a shared `/tmp`, with
    /// something planted for each way the working directory could reach the
    /// script process: `json.py` and a `codetracer/` package (imported from
    /// the working directory), `sitecustomize.py` (run at start-up from a
    /// `PYTHONPATH` entry naming it), `lib/json.py` (imported from a relative
    /// `PYTHONPATH` entry), a `.pth` file (run by `site.addsitedir` for a
    /// `NIX_PYTHONPATH` entry naming it), and a `python3` there and in
    /// `bin/` (run from a relative `PATH` entry).  Each plant announces
    /// itself with its own tag.
    ///
    /// As the vacuity guard, checks that each one does run when the
    /// interpreter, or the shell looking `python3` up, is started there the
    /// ordinary way: what the tests then see not running is held back by
    /// `execute_script`, not inert.  The `NIX_PYTHONPATH` control needs a
    /// Nixpkgs interpreter on `PATH`, as the development shell provides.
    fn make_planted_shared_dir(root: &Path) -> PathBuf {
        let shared = root.join("shared");
        std::fs::create_dir_all(shared.join("codetracer")).expect("create planted package");
        std::fs::create_dir_all(shared.join("lib")).expect("create planted lib");
        std::fs::create_dir_all(shared.join("bin")).expect("create planted bin");
        let plants = [
            ("json.py", announce("cwd-json")),
            ("codetracer/__init__.py", announce("codetracer")),
            ("sitecustomize.py", announce("sitecustomize")),
            ("lib/json.py", announce("lib-json")),
            (
                "planted.pth",
                format!("import sys; sys.stderr.write('{PLANTED} pth\\n')\n"),
            ),
            (
                "python3",
                format!("#!/bin/sh\necho '{PLANTED} cwd-python3' >&2\n"),
            ),
            (
                "bin/python3",
                format!("#!/bin/sh\necho '{PLANTED} bin-python3' >&2\n"),
            ),
        ];
        for (name, body) in plants {
            std::fs::write(shared.join(name), body).expect("plant");
        }
        chmod(&shared.join("python3"), 0o755);
        chmod(&shared.join("bin/python3"), 0o755);
        chmod(&shared, 0o1777);

        let control = |args: &[&str], envs: &[(&str, String)], tag: &str| {
            let output = std::process::Command::new("python3")
                .args(args)
                .current_dir(&shared)
                .envs(envs.iter().map(|(k, v)| (*k, v.as_str())))
                .output()
                .expect("python3 runs");
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains(&format!("{PLANTED} {tag}")),
                "control {args:?} {envs:?} did not run the planted {tag}: {stderr}"
            );
        };
        control(&["-c", "import json"], &[], "cwd-json");
        control(&["-c", "import codetracer"], &[], "codetracer");
        for entry in [
            ".".to_string(),
            ":".to_string(),
            shared.display().to_string(),
        ] {
            control(&["-c", "pass"], &[("PYTHONPATH", entry)], "sitecustomize");
        }
        control(
            &["-P", "-c", "import json"],
            &[("PYTHONPATH", "lib".to_string())],
            "lib-json",
        );
        control(
            &["-c", "pass"],
            &[("NIX_PYTHONPATH", ".".to_string())],
            "pth",
        );

        let inherited = std::env::var("PATH").expect("PATH is set");
        for (prefix, tag) in [
            (".:", "cwd-python3"),
            (":", "cwd-python3"),
            ("bin:", "bin-python3"),
        ] {
            let output = std::process::Command::new("/bin/sh")
                .args(["-c", "python3 -c pass"])
                .current_dir(&shared)
                .env("PATH", format!("{prefix}{inherited}"))
                .output()
                .expect("sh runs");
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains(&format!("{PLANTED} {tag}")),
                "PATH={prefix}... did not run the planted {tag}: {stderr}"
            );
        }
        shared
    }

    /// A trusted stand-in `codetracer` package whose `open_trace` needs no
    /// daemon, for the tests that need the user's code itself to run.
    fn make_stand_in_api(root: &Path) -> PathBuf {
        let stand_in = root.join("stand-in");
        std::fs::create_dir_all(stand_in.join("codetracer")).expect("create stand-in");
        std::fs::write(
            stand_in.join("codetracer/__init__.py"),
            "class _Trace:\n    def close(self):\n        pass\n\n\
             def open_trace(path, daemon_socket=None):\n    return _Trace()\n",
        )
        .expect("write stand-in");
        tighten(&stand_in);
        stand_in
    }

    /// From a shared working directory with a planted `json.py`, a script
    /// run against a trusted package imports the real `json`: the package
    /// is imported from the trusted copy (its files appear in the
    /// traceback of the failed connection), the planted module never runs,
    /// and no bytecode is written into the copy.
    #[tokio::test]
    async fn test_exec_script_does_not_import_a_json_module_planted_in_the_working_directory() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let api = copy_real_api(&root.path().join("api"));
        let (exit, stdout, stderr) = run_cwd_probe(
            "test_exec_script_does_not_import_a_json_module_planted_in_the_working_directory",
            &shared,
            &[("CT_TEST_PROBE_API", api.display().to_string())],
        );
        assert!(!stderr.contains(PLANTED), "{stderr}");
        assert_ne!(exit, 0, "{stdout} {stderr}");
        assert!(!stdout.contains("user script ran"), "{stdout}");
        assert!(
            stderr.contains(&api.join("codetracer").display().to_string()),
            "the trusted package was not the one imported: {stderr}"
        );
        assert!(stderr.contains("/nonexistent/daemon.sock"), "{stderr}");
        assert!(
            !api.join("codetracer/__pycache__").exists(),
            "bytecode was written into the Python API tree"
        );
    }

    /// `PYTHONPATH` is ignored: an entry of `.`, an empty one, the working
    /// directory's absolute path (each of which would run the planted
    /// `sitecustomize.py` at start-up, before the wrapper), or a relative
    /// `lib` (which would import the planted `lib/json.py`) has no effect.
    /// So is `NIX_PYTHONPATH`, whose `.` would run the planted `.pth` file.
    /// Each run still imports the trusted package and fails only on the
    /// missing daemon socket.
    #[tokio::test]
    async fn test_exec_script_ignores_python_path_variables_naming_the_working_directory() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let api = copy_real_api(&root.path().join("api"));
        let cases = [
            ("PYTHONPATH", ".".to_string()),
            ("PYTHONPATH", ":".to_string()),
            ("PYTHONPATH", shared.display().to_string()),
            ("PYTHONPATH", "lib".to_string()),
            ("NIX_PYTHONPATH", ".".to_string()),
        ];
        for (name, value) in cases {
            let (exit, stdout, stderr) = run_cwd_probe(
                "test_exec_script_ignores_python_path_variables_naming_the_working_directory",
                &shared,
                &[
                    ("CT_TEST_PROBE_API", api.display().to_string()),
                    (name, value.clone()),
                ],
            );
            assert!(!stderr.contains(PLANTED), "{name}={value}: {stderr}");
            assert_ne!(exit, 0, "{name}={value}: {stdout} {stderr}");
            assert!(
                stderr.contains(&api.join("codetracer").display().to_string()),
                "{name}={value}: the trusted package was not the one imported: {stderr}"
            );
            assert!(
                stderr.contains("/nonexistent/daemon.sock"),
                "{name}={value}: {stderr}"
            );
        }
    }

    /// A `python3` planted in the working directory, or in a directory a
    /// relative `PATH` entry names, is not run for a `PATH` starting with
    /// `.`, an empty entry or `bin`: the interpreter is looked up in the
    /// absolute entries only, and the one that runs the script is an
    /// absolute path outside the shared directory.
    #[tokio::test]
    async fn test_exec_script_does_not_run_a_python3_found_through_a_relative_path_entry() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let stand_in = make_stand_in_api(root.path());
        let inherited = std::env::var("PATH").expect("PATH is set");
        let script = "print('executable', sys.executable)\nprint('user script ran')";
        for prefix in [".:", ":", "bin:"] {
            let (exit, stdout, stderr) = run_cwd_probe(
                "test_exec_script_does_not_run_a_python3_found_through_a_relative_path_entry",
                &shared,
                &[
                    ("CT_TEST_PROBE_API", stand_in.display().to_string()),
                    ("CT_TEST_PROBE_SCRIPT", script.to_string()),
                    ("PATH", format!("{prefix}{inherited}")),
                ],
            );
            assert!(!stderr.contains(PLANTED), "PATH={prefix}...: {stderr}");
            assert_eq!(exit, 0, "PATH={prefix}...: {stdout} {stderr}");
            assert!(stdout.contains("user script ran"), "{stdout}");
            let executable = stdout
                .lines()
                .find_map(|l| l.strip_prefix("executable "))
                .unwrap_or_else(|| panic!("no executable line: {stdout}"));
            assert!(Path::new(executable).is_absolute(), "{executable}");
            assert!(!Path::new(executable).starts_with(&shared), "{executable}");
        }
    }

    /// The user's own site-packages are not used: a `usercustomize.py` in
    /// the site-packages directory of a `HOME` the test controls runs for a
    /// plain `python3` (the control), and not for a script.
    ///
    /// The `python3` first on the development shell's `PATH` belongs to a
    /// virtual environment over a Nix Python environment, both of which
    /// disable the user site by themselves and would make both runs vacuous,
    /// so the test puts the directory the interpreter was built for
    /// (`sysconfig`'s `BINDIR`, asked in isolated mode so the shell's
    /// `PYTHONPATH` does not substitute another version's build data) first
    /// on `PATH` for both.  The shell also sets
    /// `PYTHONNOUSERSITE`; an empty value counts as unset, so both runs
    /// clear it.
    #[tokio::test]
    async fn test_exec_script_does_not_use_the_user_site_packages() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let api = copy_real_api(&root.path().join("api"));
        let home = root.path().join("home");
        let base = std::process::Command::new("python3")
            .args([
                "-I",
                "-c",
                "import sysconfig; print(sysconfig.get_config_var('BINDIR'))",
            ])
            .output()
            .expect("python3 runs");
        let base_bin = PathBuf::from(String::from_utf8_lossy(&base.stdout).trim());
        let python = base_bin.join("python3");
        assert!(is_executable_file(&python), "{}", python.display());
        let path = format!(
            "{}:{}",
            base_bin.display(),
            std::env::var("PATH").expect("PATH is set")
        );
        let run_python = |code: &str| {
            std::process::Command::new(&python)
                .args(["-c", code])
                .env("HOME", &home)
                .env("PYTHONNOUSERSITE", "")
                .output()
                .expect("python3 runs")
        };
        let user_site = run_python("import site; print(site.getusersitepackages())");
        let user_site = PathBuf::from(String::from_utf8_lossy(&user_site.stdout).trim());
        assert!(user_site.starts_with(&home), "{}", user_site.display());
        std::fs::create_dir_all(&user_site).expect("create user site");
        std::fs::write(
            user_site.join("usercustomize.py"),
            announce("usercustomize"),
        )
        .expect("plant usercustomize");
        let control = run_python("pass");
        let control = String::from_utf8_lossy(&control.stderr);
        assert!(
            control.contains(&format!("{PLANTED} usercustomize")),
            "{}: {control}",
            python.display()
        );

        let (exit, _, stderr) = run_cwd_probe(
            "test_exec_script_does_not_use_the_user_site_packages",
            &shared,
            &[
                ("CT_TEST_PROBE_API", api.display().to_string()),
                ("HOME", home.display().to_string()),
                ("PYTHONNOUSERSITE", String::new()),
                ("PATH", path),
            ],
        );
        assert!(!stderr.contains(PLANTED), "{stderr}");
        assert_ne!(exit, 0, "{stderr}");
        assert!(stderr.contains("/nonexistent/daemon.sock"), "{stderr}");
    }

    /// With no trusted copy found, a `codetracer/` package planted in the
    /// shared working directory is not imported: the script exits naming
    /// the places searched.
    #[tokio::test]
    async fn test_exec_script_does_not_import_a_package_planted_in_the_working_directory() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let (exit, stdout, stderr) = run_cwd_probe(
            "test_exec_script_does_not_import_a_package_planted_in_the_working_directory",
            &shared,
            &[("CT_TEST_PROBE_API", String::new())],
        );
        assert!(!stderr.contains(PLANTED), "{stderr}");
        assert_eq!(exit, 1, "{stdout} {stderr}");
        assert!(
            stderr.contains("codetracer package) is not importable"),
            "{stderr}"
        );
        assert!(stderr.contains("/nonexistent/python-api"), "{stderr}");
    }

    /// The wrapper's own removal of the working directory from `sys.path`
    /// ([`STRIP_WORKING_DIRECTORY`]), checked without isolated mode, as on
    /// an interpreter or site configuration that put the entries there: with
    /// `PYTHONPATH` naming the working directory both as `.` and as an empty
    /// element, user code sees neither the empty entry nor the directory, and
    /// imports the real `json`.  (A planted `sitecustomize.py` would still
    /// run at start-up here, before the wrapper; that is what `-I` covers.)
    #[test]
    fn test_wrapper_removes_working_directory_entries_without_isolated_mode() {
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let stand_in = make_stand_in_api(root.path());
        let script = "import json, os\n\
                      print('cwd-entries', [p for p in sys.path if p == '' or \
                      os.path.realpath(p) == os.path.realpath(os.getcwd())])\n\
                      print('json-from', json.__file__)";
        let wrapper = build_wrapper_script(
            script,
            "/tmp/trace",
            "/tmp/sock",
            &PythonApiLookup::found(&stand_in),
            None,
        );
        let output = std::process::Command::new("python3")
            .args(["-B", "-c", &wrapper])
            .current_dir(&shared)
            .env("PYTHONPATH", ".:")
            .output()
            .expect("python3 runs");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(0), "{stdout} {stderr}");
        assert!(stdout.contains("cwd-entries []"), "{stdout}");
        assert!(!stderr.contains(&format!("{PLANTED} cwd-json")), "{stderr}");
        assert!(
            !stderr.contains(&format!("{PLANTED} codetracer")),
            "{stderr}"
        );
        let json_from = stdout
            .lines()
            .find_map(|l| l.strip_prefix("json-from "))
            .unwrap_or_else(|| panic!("no json line: {stdout}"));
        assert!(
            !Path::new(json_from).starts_with(&shared),
            "{json_from} {stderr}"
        );
    }

    /// The user's code runs in isolated mode, with neither the empty entry
    /// nor the working directory on `sys.path`, and without writing
    /// bytecode; the working directory itself is still the daemon's, so a
    /// relative file name in a script resolves where it did before.
    #[tokio::test]
    async fn test_exec_script_user_code_sees_no_working_directory_on_sys_path() {
        if std::env::var_os(CWD_PROBE_ENV).is_some() {
            return cwd_probe().await;
        }
        let root = tempfile::tempdir().expect("tempdir");
        let shared = make_planted_shared_dir(root.path());
        let stand_in = make_stand_in_api(root.path());
        let script = "import json, os\n\
                      print('cwd-entries', [p for p in sys.path if p == '' or \
                      os.path.realpath(p) == os.path.realpath(os.getcwd())])\n\
                      print('isolated', sys.flags.isolated, sys.flags.ignore_environment, \
                      sys.flags.no_user_site)\n\
                      print('no-bytecode', sys.dont_write_bytecode)\n\
                      print('cwd', os.getcwd())";
        let (exit, stdout, stderr) = run_cwd_probe(
            "test_exec_script_user_code_sees_no_working_directory_on_sys_path",
            &shared,
            &[
                ("CT_TEST_PROBE_API", stand_in.display().to_string()),
                ("CT_TEST_PROBE_SCRIPT", script.to_string()),
            ],
        );
        assert_eq!(exit, 0, "{stdout} {stderr}");
        assert!(!stderr.contains(PLANTED), "{stderr}");
        assert!(stdout.contains("cwd-entries []"), "{stdout}");
        assert!(stdout.contains("isolated 1 1 1"), "{stdout}");
        assert!(stdout.contains("no-bytecode True"), "{stdout}");
        assert!(
            stdout.contains(&format!("cwd {}", shared.display())),
            "{stdout}"
        );
    }

    // --- The interpreter is looked up in absolute PATH entries ---------

    /// An executable `python3` in a fresh directory under `root`.
    fn make_interpreter(root: &Path, dir: &str, mode: u32) -> PathBuf {
        let dir = root.join(dir);
        std::fs::create_dir_all(&dir).expect("create dir");
        let exe = dir.join("python3");
        std::fs::write(&exe, "#!/bin/sh\n").expect("write python3");
        chmod(&exe, mode);
        dir
    }

    /// Relative and empty entries are skipped even when they come first, a
    /// file that is not executable is passed over, and the first absolute
    /// directory with an executable `python3` is the one used.
    #[test]
    fn test_find_python3_uses_the_first_absolute_entry_with_an_executable() {
        let root = tempfile::tempdir().expect("tempdir");
        let not_executable = make_interpreter(root.path(), "not-executable", 0o644);
        let first = make_interpreter(root.path(), "first", 0o755);
        let second = make_interpreter(root.path(), "second", 0o755);
        let path = std::env::join_paths([
            PathBuf::from("."),
            PathBuf::new(),
            PathBuf::from("relative/bin"),
            root.path().join("missing"),
            not_executable,
            first.clone(),
            second,
        ])
        .expect("join PATH");
        assert_eq!(find_python3(Some(&path)), Ok(first.join("python3")));
    }

    /// With only relative and empty entries, or no `PATH`, nothing is found,
    /// and the message names the skipped entries.
    #[test]
    fn test_find_python3_refuses_relative_entries_only() {
        let err = find_python3(Some(std::ffi::OsStr::new(".::bin"))).expect_err("refused");
        assert!(
            err.contains("not found in any absolute PATH directory"),
            "{err}"
        );
        assert!(err.contains(r#"skipped: ".", "", "bin""#), "{err}");
        let err = find_python3(None).expect_err("refused");
        assert!(!err.contains("skipped"), "{err}");
    }
}
