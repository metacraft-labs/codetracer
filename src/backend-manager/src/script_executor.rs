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
//! 1. Adds the CodeTracer Python API to `sys.path`.
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

use std::process::Stdio;

use tokio::process::Command;
use tokio::time::{Duration, timeout};

/// Default timeout for script execution in seconds.
pub const DEFAULT_TIMEOUT_SECS: u64 = 30;

/// Exit code returned when a script exceeds its timeout.
///
/// Matches the exit code used by the `timeout(1)` coreutils command.
pub const TIMEOUT_EXIT_CODE: i32 = 124;

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

/// Execute a Python script against a trace.
///
/// Spawns a `python3` subprocess with the CodeTracer Python API available,
/// wrapping the user script with trace initialization code.  The subprocess
/// connects back to the daemon over `socket_path` to execute trace queries.
///
/// # Arguments
///
/// * `script` - The user's Python code to execute.
/// * `trace_path` - Filesystem path to the trace directory.
/// * `socket_path` - Path to the daemon's Unix socket (passed to the Python
///   API via the `daemon_socket` parameter of `open_trace()`).
/// * `python_api_path` - Path to the directory containing the `codetracer`
///   Python package (added to `sys.path`).
/// * `timeout_seconds` - Maximum execution time in seconds before the
///   subprocess is killed.
///
/// # Errors
///
/// Returns `Err(String)` if the Python subprocess cannot be spawned (e.g.
/// `python3` is not found in `$PATH`).  Script-level errors (syntax errors,
/// runtime exceptions) are represented as a successful `ScriptResult` with a
/// non-zero `exit_code` and the traceback in `stderr`.
pub async fn execute_script(
    script: &str,
    trace_path: &str,
    socket_path: &str,
    python_api_path: &str,
    timeout_seconds: u64,
    session_id: Option<&str>,
) -> Result<ScriptResult, String> {
    let wrapper =
        build_wrapper_script(script, trace_path, socket_path, python_api_path, session_id);

    let mut child = Command::new("python3")
        .arg("-c")
        .arg(&wrapper)
        // Prevent the child from inheriting stdin (avoids blocking on tty reads).
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to spawn python3: {e}"))?;

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
/// 1. Inserts `python_api_path` at the front of `sys.path` so `import codetracer`
///    resolves to the local package.
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
    python_api_path: &str,
    session_id: Option<&str>,
) -> String {
    // Escape backslashes and quotes in the path strings so they are safe inside
    // Python string literals.  This prevents injection when paths contain
    // special characters (e.g. backslashes on Windows or quotes in file names).
    let api_path_escaped = escape_for_python(python_api_path);
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

    format!(
        r#"import sys, os
sys.path.insert(0, "{api_path_escaped}")
os.environ["CODETRACER_DAEMON_SOCK"] = "{sock_escaped}"
os.environ["CODETRACER_TRACE_PATH"] = "{trace_escaped}"
from codetracer import open_trace
trace = open_trace("{trace_escaped}", daemon_socket="{sock_escaped}")
try:
{indented}
finally:
{finally_block}
"#
    )
}

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
            "/tmp/api",
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
            "/tmp/api",
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
            "/tmp/api",
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
            "/tmp/api",
            Some("debug-1"),
        );
        assert!(!wrapper.contains("trace.close()"));
        assert!(wrapper.contains("stateful session"));
    }
}
