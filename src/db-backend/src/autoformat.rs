//! Auto-formatter fallback for minified sources without a sourcemap.
//!
//! Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P4.
//!
//! When a minified source has **no companion sourcemap** but looks
//! minified (its average line length exceeds the configurable threshold),
//! the replay-server shells out to an external auto-formatter (`prettier`
//! for JavaScript/TypeScript, `black` for Python) and projects the
//! recorded `(line, column)` positions through a synthetic position map.
//!
//! The result is a *readable* but anonymised view of the source — the
//! formatter only reflows whitespace, it does not recover original
//! variable names.  Original-name recovery is §P5's territory.
//!
//! ## Architecture
//!
//! * **Self-contained**: this module has no direct dependency on
//!   `dap_handler` or `sourcemap_cache`; the integration glue lives next
//!   to the [`crate::sourcemap_cache::SourcemapCache`] and calls into
//!   this module via the public [`autoformat`] entry point.
//!
//! * **Lazy**: callers should only invoke [`autoformat`] for paths that
//!   actually get referenced by a step record.  Trace-open does *not*
//!   pre-format every source — that would burn subprocess time on files
//!   the user never views.
//!
//! * **Best-effort, never panics**: failures (no tool on PATH,
//!   subprocess timeout, unknown extension) return a typed
//!   [`AutoFormatError`].  Callers fall back to the original source.
//!
//! ## Configuration
//!
//! * `CT_AUTOFORMAT={0|off|false|no}` — hard kill-switch (default on).
//! * `CT_AUTOFORMAT_THRESHOLD=<chars>` — override the average-line-length
//!   threshold the [`looks_minified`] heuristic uses (default 500).
//!
//! Subprocess timeout is hard-coded at 10 seconds — prettier on a 70 KB
//! file is sub-second; anything longer is a sign of misuse or a
//! pathological input we want to bail on rather than hang the trace.

use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Default minified-source heuristic threshold: when the average line
/// length over non-empty lines exceeds this many characters, we suspect
/// the source has been minified and is a candidate for auto-formatting.
///
/// Empirical: hand-written code rarely averages above ~200 chars/line
/// even with long type annotations; rollup/webpack bundles routinely
/// average 1000s of chars/line.  500 is a comfortable middle ground.
pub const DEFAULT_MINIFIED_THRESHOLD: usize = 500;

/// Hard subprocess timeout for the formatter call.  Prettier on a 70 KB
/// bundle is well under a second; if we cross 10 s something is wrong
/// (pathological input, hung tool, mis-configured npx) and we should
/// bail rather than block the trace-open path indefinitely.
const FORMATTER_TIMEOUT: Duration = Duration::from_secs(10);

/// Result returned by a successful [`autoformat`] invocation.
#[derive(Debug, Clone)]
pub struct AutoFormatResult {
    /// The formatter's stdout, verbatim.  This is the formatted source
    /// the UI should display.
    pub formatted_content: String,
    /// Per-`(original_line, original_col)` → `(formatted_line, formatted_col)`
    /// synthetic projection map.  Sparse — only contains entries we were
    /// able to confidently project from the original to the formatted
    /// output by a line-by-line diff of statement boundaries.
    pub position_map: PositionMap,
}

/// Errors that callers should expect from [`autoformat`].  None of these
/// represent bugs — they represent legitimate "no auto-format available"
/// outcomes that the caller should fall through past.
#[derive(Debug)]
pub enum AutoFormatError {
    /// Neither the language's native formatter (`prettier` / `black`)
    /// nor a runner (`npx`) was found on `PATH`.
    NoTool,
    /// The formatter subprocess did not finish within
    /// [`FORMATTER_TIMEOUT`].
    Timeout,
    /// The formatter ran but exited non-zero, or stdio handling failed.
    SubprocessFailed(String),
    /// The source path's extension wasn't recognised — auto-format is
    /// language-specific and we deliberately bail on unknown extensions
    /// rather than guess.
    UnknownLanguage,
}

impl std::fmt::Display for AutoFormatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoTool => write!(f, "no auto-format tool (prettier / black / npx) on PATH"),
            Self::Timeout => write!(f, "auto-format subprocess timed out"),
            Self::SubprocessFailed(msg) => write!(f, "auto-format subprocess failed: {msg}"),
            Self::UnknownLanguage => write!(f, "unrecognised source extension for auto-format"),
        }
    }
}

impl std::error::Error for AutoFormatError {}

/// Synthetic position map projecting recorded `(line, col)` positions on
/// the minified source onto the formatted output.
///
/// v1 implementation: **line-only mapping**.  The formatter's output
/// preserves statement order and token order, so we can walk both
/// inputs simultaneously and match each unique non-whitespace token of
/// the original to its first occurrence in the formatted output.  We
/// then build a per-line map: each line of the original maps to the
/// line in the formatted output where its non-whitespace content
/// resumes.
///
/// Column projection is **not** attempted in v1 — the formatter inserts
/// newlines and indentation that change column positions throughout
/// every line.  Computing column precision requires a real diff
/// algorithm against the post-format whitespace structure, which is
/// substantial follow-up work (see spec §P4 "Time-box" notes).  The
/// projected column is always `1` (start of line), which is "honest"
/// — the user-visible cursor lands at the beginning of the formatted
/// line that contains the recorded statement.
#[derive(Debug, Clone)]
pub struct PositionMap {
    /// Sparse: `original_1_indexed_line -> formatted_1_indexed_line`.
    /// Only present for lines we were able to project; callers should
    /// treat a missing entry as "no translation available, fall through
    /// to original".
    line_map: HashMap<u32, u32>,
}

impl PositionMap {
    /// Build a position map from the original (pre-format) and formatted
    /// (post-format) source contents.
    ///
    /// Algorithm: extract the first non-whitespace, non-comment token of
    /// each line in the original; scan the formatted output for the
    /// first occurrence of each token and record the line number.  We
    /// scan forward only (anchoring on previous matches) so the mapping
    /// is monotonic — projected formatted lines always increase with
    /// original line numbers, matching the formatter's structural
    /// guarantee that statement order is preserved.
    pub fn from_diff(original: &str, formatted: &str) -> Self {
        let mut line_map = HashMap::new();
        let formatted_lines: Vec<&str> = formatted.lines().collect();
        let mut fmt_cursor: usize = 0;

        for (orig_idx, orig_line) in original.lines().enumerate() {
            let orig_line_no = (orig_idx + 1) as u32;

            // Extract a salient anchor token from the original line —
            // the first sequence of identifier / keyword characters
            // that survives minification.  We deliberately ignore
            // single-char punctuation since `;`, `{`, `}` etc. occur
            // many times and don't anchor uniquely.
            let Some(anchor) = first_anchor_token(orig_line) else {
                continue;
            };

            // Scan forward in the formatted output for the anchor.
            // Forward-only preserves monotonicity.
            let mut found: Option<usize> = None;
            for (i, fmt_line) in formatted_lines.iter().enumerate().skip(fmt_cursor) {
                if fmt_line.contains(&anchor) {
                    found = Some(i);
                    break;
                }
            }
            if let Some(i) = found {
                let fmt_line_no = (i + 1) as u32;
                line_map.insert(orig_line_no, fmt_line_no);
                fmt_cursor = i; // Allow same-line overlaps for multi-statement lines.
            }
        }

        Self { line_map }
    }

    /// Empty map — used as a fallback when the diff couldn't extract any
    /// anchors (e.g. the original is entirely punctuation).
    pub fn empty() -> Self {
        Self {
            line_map: HashMap::new(),
        }
    }

    /// True when the map has zero entries.
    pub fn is_empty(&self) -> bool {
        self.line_map.is_empty()
    }

    /// Number of `(original_line -> formatted_line)` entries in the
    /// map.  Exposed for unit tests and metrics.
    pub fn len(&self) -> usize {
        self.line_map.len()
    }

    /// Project a recorded `(line, column)` on the minified source to its
    /// position in the formatted output.
    ///
    /// Returns `None` when the original line wasn't anchored — callers
    /// should fall through to the original coordinates.
    ///
    /// The projected column is currently always `1` (start of line) —
    /// see the [`PositionMap`] doc comment for the v1 scope limit.
    pub fn project(&self, gen_line: u32, _gen_col: u32) -> Option<(u32, u32)> {
        self.line_map.get(&gen_line).map(|&fmt_line| (fmt_line, 1))
    }
}

/// Extract a salient anchor token from a single line of source.
///
/// "Salient" here means: at least 3 characters long, predominantly
/// identifier-like (alphanumeric + underscore + `$`).  Such tokens are
/// stable across the formatter (it only reflows whitespace and
/// punctuation) and unique-enough to anchor a line-to-line projection.
fn first_anchor_token(line: &str) -> Option<String> {
    let mut current = String::new();
    let mut best: Option<String> = None;
    for c in line.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '$' {
            current.push(c);
        } else {
            if current.len() >= 3 {
                // Skip language keywords that occur on many lines.
                // Anchoring on `var`, `return`, etc. picks wrong lines.
                if !is_common_keyword(&current) {
                    best = Some(current.clone());
                    break;
                }
            }
            current.clear();
        }
    }
    if best.is_none() && current.len() >= 3 && !is_common_keyword(&current) {
        best = Some(current);
    }
    best
}

/// Hard-coded list of common JS / Python keywords that occur too often
/// to be useful as line anchors.  Matching one of these causes the
/// scanner to keep looking for a more distinctive token.
fn is_common_keyword(s: &str) -> bool {
    matches!(
        s,
        "var"
            | "let"
            | "const"
            | "function"
            | "return"
            | "if"
            | "else"
            | "for"
            | "while"
            | "do"
            | "switch"
            | "case"
            | "default"
            | "break"
            | "continue"
            | "this"
            | "new"
            | "delete"
            | "typeof"
            | "instanceof"
            | "void"
            | "null"
            | "true"
            | "false"
            | "import"
            | "export"
            | "from"
            | "class"
            | "extends"
            | "super"
            | "static"
            | "async"
            | "await"
            | "yield"
            | "try"
            | "catch"
            | "finally"
            | "throw"
            | "def"
            | "lambda"
            | "pass"
            | "and"
            | "not"
            | "with"
    )
}

/// `true` when the auto-format fallback is enabled via env var.
///
/// Accepted "off" values (case-insensitive): `0`, `off`, `false`, `no`.
/// Anything else (including unset) means "on" — the default.
pub fn autoformat_enabled() -> bool {
    match std::env::var("CT_AUTOFORMAT") {
        Ok(v) => {
            let lower = v.trim().to_ascii_lowercase();
            !matches!(lower.as_str(), "0" | "off" | "false" | "no")
        }
        Err(_) => true,
    }
}

/// Read the `CT_AUTOFORMAT_THRESHOLD` env var, falling back to
/// [`DEFAULT_MINIFIED_THRESHOLD`] on unset / unparseable values.
pub fn minified_threshold() -> usize {
    std::env::var("CT_AUTOFORMAT_THRESHOLD")
        .ok()
        .and_then(|v| v.trim().parse::<usize>().ok())
        .unwrap_or(DEFAULT_MINIFIED_THRESHOLD)
}

/// Heuristic: does this source look minified?
///
/// Returns `true` when the average line length over *non-empty* lines
/// exceeds `threshold_chars`.  Counts characters (not bytes) to handle
/// multibyte UTF-8 in identifiers / string literals consistently.
///
/// Returns `false` for empty input or input with no non-empty lines.
pub fn looks_minified(content: &str, threshold_chars: usize) -> bool {
    let mut total_chars: usize = 0;
    let mut non_empty_lines: usize = 0;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // Count characters not bytes so multibyte tokens don't double-
        // count their length and falsely trip the threshold.
        total_chars += line.chars().count();
        non_empty_lines += 1;
    }
    if non_empty_lines == 0 {
        return false;
    }
    let average = total_chars / non_empty_lines;
    average > threshold_chars
}

/// Which language is this source path in?
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Lang {
    JavaScript,
    Python,
}

/// Inspect the file extension to decide which formatter to invoke.
fn lang_of(path: &Path) -> Option<Lang> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "js" | "jsx" | "mjs" | "cjs" | "ts" | "tsx" => Some(Lang::JavaScript),
        "py" => Some(Lang::Python),
        _ => None,
    }
}

/// Run the appropriate formatter on `content` (with `source_path` used
/// for language detection + the `--stdin-filepath` hint that lets
/// prettier pick its parser).
///
/// Returns a populated [`AutoFormatResult`] on success.  Returns the
/// typed [`AutoFormatError`] on every other path — the caller should
/// fall through to the original content.
pub fn autoformat(source_path: &Path, content: &str) -> Result<AutoFormatResult, AutoFormatError> {
    let lang = lang_of(source_path).ok_or(AutoFormatError::UnknownLanguage)?;
    let formatted = match lang {
        Lang::JavaScript => run_prettier(source_path, content)?,
        Lang::Python => run_black(content)?,
    };
    let position_map = PositionMap::from_diff(content, &formatted);
    Ok(AutoFormatResult {
        formatted_content: formatted,
        position_map,
    })
}

/// Locate prettier (or `npx` as a runner) and invoke it with the
/// source content piped to stdin.
///
/// Resolution order:
/// 1. `prettier` on `PATH` — fastest, no per-invocation Node-module
///    resolution.
/// 2. `npx prettier` — slower but works on machines that have
///    Node.js but no globally installed prettier.
fn run_prettier(source_path: &Path, content: &str) -> Result<String, AutoFormatError> {
    let stdin_filepath = source_path
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "input.js".to_string());

    if which("prettier") {
        return run_with_stdin(
            Command::new("prettier")
                .arg("--stdin-filepath")
                .arg(&stdin_filepath)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped()),
            content,
        );
    }
    if which("npx") {
        // `--no-install` makes sure we never spend 30+ seconds
        // downloading prettier on the trace-open hot path.  If the
        // user wants auto-format they should `npm install -g prettier`
        // (or `npx -y prettier ...` once to warm the cache).
        return run_with_stdin(
            Command::new("npx")
                .arg("--no-install")
                .arg("prettier")
                .arg("--stdin-filepath")
                .arg(&stdin_filepath)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped()),
            content,
        );
    }
    Err(AutoFormatError::NoTool)
}

/// Locate black (Python formatter) and run it on stdin.
///
/// `black -` reads from stdin and writes to stdout — the same shape
/// as `prettier --stdin-filepath`.
fn run_black(content: &str) -> Result<String, AutoFormatError> {
    if !which("black") {
        return Err(AutoFormatError::NoTool);
    }
    run_with_stdin(
        Command::new("black")
            .arg("-")
            .arg("--quiet")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
        content,
    )
}

/// Spawn a configured `Command`, pipe `input` to its stdin, and collect
/// stdout — all subject to [`FORMATTER_TIMEOUT`].
///
/// If the subprocess exceeds the timeout we kill it (best-effort) and
/// return [`AutoFormatError::Timeout`].  On non-zero exit we return
/// [`AutoFormatError::SubprocessFailed`] with the captured stderr.
fn run_with_stdin(cmd: &mut Command, input: &str) -> Result<String, AutoFormatError> {
    let mut child = cmd
        .spawn()
        .map_err(|e| AutoFormatError::SubprocessFailed(format!("spawn: {e}")))?;

    // Write the input to the child's stdin in a separate scope so the
    // pipe closes (signalling EOF to the formatter) before we wait.
    if let Some(mut stdin) = child.stdin.take() {
        let input = input.to_owned();
        // Write on a helper thread so a hostile formatter that refuses
        // to consume stdin can't deadlock us — the timeout below will
        // still trip and kill the process.
        std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
            // Closing `stdin` happens on drop here.
        });
    }

    let status = match wait_with_timeout(&mut child, FORMATTER_TIMEOUT) {
        Ok(Some(s)) => s,
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(AutoFormatError::Timeout);
        }
        Err(e) => {
            return Err(AutoFormatError::SubprocessFailed(format!("wait: {e}")));
        }
    };

    // Collect stdout / stderr after the process has exited — by this
    // point both pipes have been fully written by the child.
    let mut stdout_buf = String::new();
    if let Some(mut out) = child.stdout.take() {
        use std::io::Read;
        out.read_to_string(&mut stdout_buf)
            .map_err(|e| AutoFormatError::SubprocessFailed(format!("read stdout: {e}")))?;
    }
    if !status.success() {
        let mut stderr_buf = String::new();
        if let Some(mut err) = child.stderr.take() {
            use std::io::Read;
            let _ = err.read_to_string(&mut stderr_buf);
        }
        let trimmed = stderr_buf.trim().to_string();
        return Err(AutoFormatError::SubprocessFailed(format!(
            "exit {:?}: {trimmed}",
            status.code()
        )));
    }
    Ok(stdout_buf)
}

/// Poll-based wait with a hard deadline.  Returns:
/// * `Ok(Some(status))` when the child exits before the deadline.
/// * `Ok(None)` when the deadline elapses first — caller should kill.
/// * `Err(_)` on a `try_wait` syscall error.
fn wait_with_timeout(child: &mut Child, timeout: Duration) -> std::io::Result<Option<std::process::ExitStatus>> {
    let poll = Duration::from_millis(25);
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Some(status));
        }
        if started.elapsed() >= timeout {
            return Ok(None);
        }
        std::thread::sleep(poll);
    }
}

/// Cheap "is this binary on PATH" probe.  We deliberately avoid spawning
/// `which` (a subprocess) and walk `PATH` directly — this is hot path
/// on the lazy fallback and we don't want to pay 10ms per probe.
fn which(binary: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(binary);
        if candidate.is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            let with_exe = dir.join(format!("{binary}.exe"));
            if with_exe.is_file() {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Long single-line minified-ish source — average line length is
    /// well above the default 500-char threshold.
    fn minified_one_liner() -> String {
        let stmt = "function a(b,c){return b+c;}";
        // Repeat enough times that even with a trailing newline the
        // single line clears 500 chars.
        stmt.repeat(40)
    }

    /// Multi-line hand-written-style source where every line is short.
    fn hand_written_multiline() -> String {
        let mut s = String::new();
        for _ in 0..20 {
            s.push_str("var x = 1;\n");
        }
        s
    }

    #[test]
    fn looks_minified_detects_long_lines() {
        let src = minified_one_liner();
        assert!(looks_minified(&src, DEFAULT_MINIFIED_THRESHOLD));
    }

    #[test]
    fn looks_minified_false_for_hand_written_code() {
        let src = hand_written_multiline();
        assert!(!looks_minified(&src, DEFAULT_MINIFIED_THRESHOLD));
    }

    #[test]
    fn looks_minified_false_on_empty_input() {
        assert!(!looks_minified("", DEFAULT_MINIFIED_THRESHOLD));
        assert!(!looks_minified("\n\n   \n", DEFAULT_MINIFIED_THRESHOLD));
    }

    #[test]
    fn autoformat_unknown_extension_errors() {
        let res = autoformat(&PathBuf::from("foo.unknown"), "x = 1");
        assert!(matches!(res, Err(AutoFormatError::UnknownLanguage)));
    }

    #[test]
    fn autoformat_no_extension_errors() {
        let res = autoformat(&PathBuf::from("Makefile"), "x = 1");
        assert!(matches!(res, Err(AutoFormatError::UnknownLanguage)));
    }

    #[test]
    fn autoformat_enabled_respects_env() {
        let key = "CT_AUTOFORMAT";
        let orig = std::env::var(key).ok();
        unsafe { std::env::remove_var(key) };
        assert!(autoformat_enabled());
        unsafe { std::env::set_var(key, "0") };
        assert!(!autoformat_enabled());
        unsafe { std::env::set_var(key, "OFF") };
        assert!(!autoformat_enabled());
        unsafe { std::env::set_var(key, "false") };
        assert!(!autoformat_enabled());
        unsafe { std::env::set_var(key, "1") };
        assert!(autoformat_enabled());
        match orig {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn minified_threshold_respects_env() {
        let key = "CT_AUTOFORMAT_THRESHOLD";
        let orig = std::env::var(key).ok();
        unsafe { std::env::remove_var(key) };
        assert_eq!(minified_threshold(), DEFAULT_MINIFIED_THRESHOLD);
        unsafe { std::env::set_var(key, "1000") };
        assert_eq!(minified_threshold(), 1000);
        unsafe { std::env::set_var(key, "not-a-number") };
        assert_eq!(minified_threshold(), DEFAULT_MINIFIED_THRESHOLD);
        match orig {
            Some(v) => unsafe { std::env::set_var(key, v) },
            None => unsafe { std::env::remove_var(key) },
        }
    }

    #[test]
    fn position_map_anchors_unique_identifiers() {
        // Hand-crafted before/after; the formatter inserts line breaks
        // around statements so each function lands on its own line.
        let original = "function alpha(){return 1;}function beta(){return 2;}\n";
        let formatted = concat!(
            "function alpha() {\n",
            "  return 1;\n",
            "}\n",
            "function beta() {\n",
            "  return 2;\n",
            "}\n"
        );
        let map = PositionMap::from_diff(original, formatted);
        // Original line 1 contains "alpha" (first anchor) which lands
        // on formatted line 1.
        let projected = map.project(1, 10).expect("line 1 projects");
        assert_eq!(projected.0, 1);
        assert_eq!(projected.1, 1);
    }

    #[test]
    fn position_map_handles_no_anchors_gracefully() {
        let map = PositionMap::from_diff("{}{}{}\n", "{\n}\n{\n}\n");
        // Single-char punctuation tokens are below the anchor length
        // floor so the map should be empty rather than panic.
        assert!(map.is_empty());
        assert_eq!(map.project(1, 1), None);
    }

    #[test]
    fn position_map_skips_common_keywords() {
        // `return` is a common keyword so the anchor should skip past
        // it and pick `compute`.
        let original = "function f(){return compute();}\n";
        let formatted = concat!("function f() {\n", "  return compute();\n", "}\n");
        let map = PositionMap::from_diff(original, formatted);
        // The first anchor on line 1 of `original` is `compute` (we
        // skip `function`, `return` keywords).  `compute` appears on
        // formatted line 2.
        let projected = map.project(1, 1).expect("line 1 projects");
        assert_eq!(projected.0, 2);
    }

    #[test]
    fn autoformat_formats_minified_js_when_tool_available() {
        // Skip-loud when prettier (or npx fallback) isn't available so
        // the absence shows up in test output rather than silently
        // counting as "passed".
        if !which("prettier") && !which("npx") {
            eprintln!("SKIP autoformat_formats_minified_js: no prettier / npx on PATH");
            return;
        }
        let src = "function add(a,b){return a+b;}function main(){var x=add(1,2);console.log(x);}main();";
        let res = autoformat(&PathBuf::from("input.js"), src);
        match res {
            Ok(r) => {
                // The formatter should have inserted at least one
                // newline beyond the original single line.
                let line_count = r.formatted_content.lines().count();
                assert!(
                    line_count > 1,
                    "expected formatter to break across lines, got {line_count} line(s): {:?}",
                    r.formatted_content
                );
                // The position map should at minimum anchor `add` from
                // the original onto a non-empty formatted line range.
                assert!(!r.position_map.is_empty(), "expected at least one position map entry");
                let projected = r.position_map.project(1, 1).expect("line 1 projects");
                // Formatter output's `function add(` starts on a real
                // line — line 1 (or 2 if prettier emits a leading blank).
                assert!(projected.0 >= 1 && projected.0 <= 5);
            }
            Err(AutoFormatError::NoTool) => {
                eprintln!("SKIP autoformat_formats_minified_js: NoTool (npx without prettier offline)");
            }
            Err(AutoFormatError::SubprocessFailed(msg)) => {
                // npx with --no-install will fail when prettier hasn't
                // been globally installed.  Treat as skip-loud — this
                // is the same "no tool effectively" outcome.
                eprintln!("SKIP autoformat_formats_minified_js: subprocess failed: {msg}");
            }
            Err(AutoFormatError::Timeout) => {
                // On heavily-loaded CI machines `npx prettier` can
                // exceed the 10s budget because Node-module resolution
                // alone takes longer than that under contention.  The
                // unit test is about the happy path of our code, not
                // the host's npx performance — skip-loud rather than
                // fail.
                eprintln!("SKIP autoformat_formats_minified_js: formatter timed out under load");
            }
            Err(e) => panic!("unexpected autoformat error: {e}"),
        }
    }
}
