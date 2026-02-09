//! Trace metadata extraction from on-disk trace directories.
//!
//! A CodeTracer trace directory contains several JSON files that describe
//! the recorded execution:
//!
//! - `trace_metadata.json` — `{"workdir":"...","program":"...","args":[...]}`
//! - `trace_paths.json` — JSON array of source file paths
//! - `trace.json` — JSON array of execution events (Path, Function, Call,
//!   Step, Value, etc.)
//!
//! This module reads those files and produces a [`TraceMetadata`] struct
//! that the daemon uses to populate session information returned by the
//! `ct/open-trace` and `ct/trace-info` MCP commands.

use std::path::Path;

use serde::Deserialize;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Metadata extracted from a trace directory's JSON files.
#[derive(Debug, Clone)]
pub struct TraceMetadata {
    /// Detected programming language of the traced program.
    ///
    /// Derived from the file extension of the `program` field in
    /// `trace_metadata.json` (e.g. `.rs` -> `"rust"`, `.nim` -> `"nim"`).
    pub language: String,

    /// Total number of execution events recorded in `trace.json`.
    pub total_events: u64,

    /// Source files involved in the trace (from `trace_paths.json`).
    pub source_files: Vec<String>,

    /// The program that was traced (from `trace_metadata.json`).
    pub program: String,

    /// Working directory at the time of recording (from `trace_metadata.json`).
    pub workdir: String,
}

// ---------------------------------------------------------------------------
// Internal deserialization helpers
// ---------------------------------------------------------------------------

/// Schema for `trace_metadata.json`.
#[derive(Deserialize)]
struct RawTraceMetadata {
    workdir: String,
    program: String,
    #[allow(dead_code)]
    args: Vec<String>,
}

// ---------------------------------------------------------------------------
// Language detection
// ---------------------------------------------------------------------------

/// Detects the programming language from a program filename or path.
///
/// The heuristic inspects the file extension:
///
/// | Extension | Language  |
/// |-----------|-----------|
/// | `.nim`    | nim       |
/// | `.rs`     | rust      |
/// | `.c`      | c         |
/// | `.cpp`    | cpp       |
/// | `.py`     | python    |
/// | `.go`     | go        |
/// | `.wasm`   | wasm      |
/// | `.rb`     | ruby      |
/// | `.js`     | javascript|
/// | `.ts`     | typescript|
/// | `.java`   | java      |
/// | `.pas`    | pascal    |
///
/// Falls back to `"unknown"` when the extension is not recognized.
fn detect_language(program: &str) -> String {
    // Use the Path API to extract the extension reliably.
    let ext = Path::new(program)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");

    match ext {
        "nim" => "nim",
        "rs" => "rust",
        "c" => "c",
        "cpp" | "cc" | "cxx" => "cpp",
        "py" => "python",
        "go" => "go",
        "wasm" => "wasm",
        "rb" => "ruby",
        "js" => "javascript",
        "ts" => "typescript",
        "java" => "java",
        "pas" | "pp" => "pascal",
        _ => "unknown",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Event counting
// ---------------------------------------------------------------------------

/// Counts the number of top-level elements in a JSON array file.
///
/// Rather than fully parsing every event (which could be very large), this
/// function deserializes the file as a `Vec<serde_json::Value>` and returns
/// the vector length.  For extremely large traces a streaming approach
/// would be preferable, but this is sufficient for the current use-case
/// where metadata extraction happens once per session open.
fn count_events(trace_json_path: &Path) -> Result<u64, TraceMetadataError> {
    let contents = std::fs::read_to_string(trace_json_path).map_err(|e| {
        TraceMetadataError::Io {
            file: trace_json_path.to_path_buf(),
            source: e,
        }
    })?;

    let events: Vec<serde_json::Value> =
        serde_json::from_str(&contents).map_err(|e| TraceMetadataError::Json {
            file: trace_json_path.to_path_buf(),
            source: e,
        })?;

    Ok(events.len() as u64)
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Reads metadata from a trace directory's JSON files.
///
/// The `trace_dir` must contain at minimum `trace_metadata.json`.  Missing
/// `trace_paths.json` or `trace.json` are tolerated (the corresponding
/// fields default to empty / zero), but a warning is logged.
///
/// # Errors
///
/// Returns [`TraceMetadataError`] if `trace_metadata.json` cannot be read
/// or parsed.
pub fn read_trace_metadata(trace_dir: &Path) -> Result<TraceMetadata, TraceMetadataError> {
    // --- trace_metadata.json (required) ---
    let meta_path = trace_dir.join("trace_metadata.json");
    let meta_contents =
        std::fs::read_to_string(&meta_path).map_err(|e| TraceMetadataError::Io {
            file: meta_path.clone(),
            source: e,
        })?;
    let raw: RawTraceMetadata =
        serde_json::from_str(&meta_contents).map_err(|e| TraceMetadataError::Json {
            file: meta_path.clone(),
            source: e,
        })?;

    let language = detect_language(&raw.program);

    // --- trace_paths.json (optional) ---
    let paths_path = trace_dir.join("trace_paths.json");
    let source_files = match std::fs::read_to_string(&paths_path) {
        Ok(contents) => {
            let paths: Vec<String> =
                serde_json::from_str(&contents).map_err(|e| TraceMetadataError::Json {
                    file: paths_path.clone(),
                    source: e,
                })?;
            paths
        }
        Err(e) => {
            log::warn!(
                "trace_paths.json not found or unreadable at {}: {e}",
                paths_path.display()
            );
            Vec::new()
        }
    };

    // --- trace.json (optional) ---
    let trace_path = trace_dir.join("trace.json");
    let total_events = match count_events(&trace_path) {
        Ok(n) => n,
        Err(e) => {
            log::warn!(
                "Could not count events in {}: {e}",
                trace_path.display()
            );
            0
        }
    };

    Ok(TraceMetadata {
        language,
        total_events,
        source_files,
        program: raw.program,
        workdir: raw.workdir,
    })
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors that can occur when reading trace metadata.
#[derive(Debug)]
pub enum TraceMetadataError {
    /// An I/O error reading a trace file.
    Io {
        file: std::path::PathBuf,
        source: std::io::Error,
    },
    /// A JSON parsing error in a trace file.
    Json {
        file: std::path::PathBuf,
        source: serde_json::Error,
    },
}

impl std::fmt::Display for TraceMetadataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { file, source } => {
                write!(f, "cannot read {}: {source}", file.display())
            }
            Self::Json { file, source } => {
                write!(f, "cannot parse {}: {source}", file.display())
            }
        }
    }
}

impl std::error::Error for TraceMetadataError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Json { source, .. } => Some(source),
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Helper: creates a temporary trace directory with the given files.
    fn create_test_trace_dir(
        test_name: &str,
        metadata_json: &str,
        paths_json: Option<&str>,
        trace_json: Option<&str>,
    ) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("{}-{}", test_name, std::process::id()));
        std::fs::create_dir_all(&dir).expect("create test dir");

        std::fs::write(dir.join("trace_metadata.json"), metadata_json)
            .expect("write trace_metadata.json");

        if let Some(paths) = paths_json {
            std::fs::write(dir.join("trace_paths.json"), paths).expect("write trace_paths.json");
        }

        if let Some(trace) = trace_json {
            std::fs::write(dir.join("trace.json"), trace).expect("write trace.json");
        }

        std::fs::create_dir_all(dir.join("files")).expect("create files dir");
        dir
    }

    #[test]
    fn test_detect_language_rust() {
        assert_eq!(detect_language("main.rs"), "rust");
        assert_eq!(detect_language("/path/to/program.rs"), "rust");
    }

    #[test]
    fn test_detect_language_nim() {
        assert_eq!(detect_language("main.nim"), "nim");
    }

    #[test]
    fn test_detect_language_wasm() {
        assert_eq!(detect_language("rust_struct_test.wasm"), "wasm");
    }

    #[test]
    fn test_detect_language_python() {
        assert_eq!(detect_language("script.py"), "python");
    }

    #[test]
    fn test_detect_language_go() {
        assert_eq!(detect_language("main.go"), "go");
    }

    #[test]
    fn test_detect_language_c() {
        assert_eq!(detect_language("program.c"), "c");
    }

    #[test]
    fn test_detect_language_pascal() {
        assert_eq!(detect_language("program.pas"), "pascal");
        assert_eq!(detect_language("unit.pp"), "pascal");
    }

    #[test]
    fn test_detect_language_unknown() {
        assert_eq!(detect_language("binary"), "unknown");
        assert_eq!(detect_language(""), "unknown");
    }

    #[test]
    fn test_read_trace_metadata_complete() {
        let dir = create_test_trace_dir(
            "complete",
            r#"{"workdir":"/home/user/project","program":"main.rs","args":[]}"#,
            Some(r#"["src/main.rs","src/lib.rs"]"#),
            Some(r#"[{"Step":{"path_id":0,"line":1}},{"Step":{"path_id":0,"line":2}},{"Step":{"path_id":0,"line":3}}]"#),
        );

        let meta = read_trace_metadata(&dir).expect("read metadata");
        assert_eq!(meta.language, "rust");
        assert_eq!(meta.program, "main.rs");
        assert_eq!(meta.workdir, "/home/user/project");
        assert_eq!(meta.source_files, vec!["src/main.rs", "src/lib.rs"]);
        assert_eq!(meta.total_events, 3);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_trace_metadata_minimal() {
        // Only trace_metadata.json, no trace_paths.json or trace.json.
        let dir = create_test_trace_dir(
            "minimal",
            r#"{"workdir":"/tmp","program":"test.nim","args":["--flag"]}"#,
            None,
            None,
        );

        let meta = read_trace_metadata(&dir).expect("read metadata");
        assert_eq!(meta.language, "nim");
        assert_eq!(meta.program, "test.nim");
        assert_eq!(meta.workdir, "/tmp");
        assert!(meta.source_files.is_empty());
        assert_eq!(meta.total_events, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_trace_metadata_missing_dir() {
        let result = read_trace_metadata(Path::new("/nonexistent/path"));
        assert!(result.is_err());
    }

    #[test]
    fn test_read_real_trace() {
        // Test against the actual db-backend test trace if available.
        let trace_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("parent")
            .join("db-backend")
            .join("trace");

        if !trace_dir.exists() {
            // Skip if the test trace is not available.
            return;
        }

        let meta = read_trace_metadata(&trace_dir).expect("read real trace metadata");
        assert_eq!(meta.language, "wasm");
        assert_eq!(meta.program, "rust_struct_test.wasm");
        assert_eq!(meta.workdir, "/home/alexander92/wazero");
        assert!(!meta.source_files.is_empty());
        assert!(meta.total_events > 0);
    }
}
