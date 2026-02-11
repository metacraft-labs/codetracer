//! Trace metadata extraction from on-disk trace directories.
//!
//! A CodeTracer trace directory contains several JSON files that describe
//! the recorded execution:
//!
//! - `trace_metadata.json` — simple format: `{"workdir":"...","program":"...","args":[...]}`
//! - `trace_db_metadata.json` — extended format written by `ct-rr-support record`
//!   (camelCase keys, ~20 fields including `lang`, `rrPid`, `sourceFolders`, etc.)
//! - `trace_paths.json` — JSON array of source file paths
//! - `trace.json` — JSON array of execution events (Path, Function, Call,
//!   Step, Value, etc.)
//!
//! This module reads those files and produces a [`TraceMetadata`] struct
//! that the daemon uses to populate session information returned by the
//! `ct/open-trace` and `ct/trace-info` MCP commands.
//!
//! ## Metadata format fallback
//!
//! The primary metadata source is `trace_metadata.json` (the simple format).
//! When that file is absent — which is the common case for traces produced by
//! `ct-rr-support record` — this module falls back to reading
//! `trace_db_metadata.json`.  See the spec in
//! `codetracer-specs/Trace-Files/RR-Trace-Folders.md` for full details on both
//! formats and their producers/consumers.

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

/// Schema for `trace_metadata.json` (the simple format).
#[derive(Deserialize)]
struct RawTraceMetadata {
    workdir: String,
    program: String,
    #[allow(dead_code)]
    args: Vec<String>,
}

/// Schema for `trace_db_metadata.json` (the extended format written by
/// `ct-rr-support record`).  Only the fields needed by backend-manager are
/// deserialized; the rest are ignored via `deny_unknown_fields = false`
/// (the serde default).
///
/// The full schema is defined in `codetracer-rr-backend/src/trace.rs` as the
/// `Trace` struct.  See also:
/// `codetracer-specs/Trace-Files/RR-Trace-Folders.md#trace_db_metadatajson`
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTraceDbMetadata {
    /// Absolute path to the recorded executable.
    program: String,
    /// Working directory at recording time.
    workdir: String,
    /// Command-line arguments (may be absent in older traces).
    #[serde(default)]
    #[allow(dead_code)]
    args: Vec<String>,
    /// Language enum value as defined in `codetracer-rr-backend/src/lang.rs`.
    /// Serialized as an integer by `serde_repr` (0=C, 1=Cpp, 2=Rust, 3=Nim,
    /// 4=Go, 5=Pascal, …).  Used as a fallback when `detect_language` cannot
    /// determine the language from the program's file extension (e.g. for
    /// compiled binaries without an extension).
    #[serde(default)]
    lang: u8,
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

/// Converts a `Lang` enum integer (as serialized by `ct-rr-support` via
/// `serde_repr`) to a language name string.
///
/// This must stay in sync with the `Lang` enum defined in
/// `codetracer-rr-backend/src/lang.rs`.  Only languages that can appear in
/// RR-recorded traces are mapped; the rest fall through to `"unknown"`.
fn lang_id_to_name(id: u8) -> &'static str {
    match id {
        0 => "c",
        1 => "cpp",
        2 => "rust",
        3 => "nim",
        4 => "go",
        5 => "pascal",
        6 => "fortran",
        7 => "d",
        8 => "crystal",
        9 => "lean",
        10 => "julia",
        11 => "ada",
        12 => "python",
        13 => "ruby",
        // 14 = RubyDb (internal, same language as Ruby)
        15 => "javascript",
        16 => "lua",
        17 => "asm",
        18 => "noir",
        19 => "wasm", // RustWasm
        20 => "wasm", // CppWasm
        // 21 = Small, 22 = PythonDb, 23 = Unknown
        _ => "unknown",
    }
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
    let contents =
        std::fs::read_to_string(trace_json_path).map_err(|e| TraceMetadataError::Io {
            file: trace_json_path.to_path_buf(),
            source: e,
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
/// The directory must contain at least one of:
///
/// 1. `trace_metadata.json` — the simple format (preferred)
/// 2. `trace_db_metadata.json` — the extended format written by `ct-rr-support record`
///
/// When `trace_metadata.json` is present, it is used.  Otherwise the function
/// falls back to `trace_db_metadata.json`.  If neither file exists the
/// function returns an error.
///
/// Missing `trace_paths.json` or `trace.json` are tolerated (the
/// corresponding fields default to empty / zero), but a warning is logged.
///
/// # Errors
///
/// Returns [`TraceMetadataError`] if neither metadata file can be read or
/// parsed.
pub fn read_trace_metadata(trace_dir: &Path) -> Result<TraceMetadata, TraceMetadataError> {
    // --- Primary: trace_metadata.json / Fallback: trace_db_metadata.json ---
    let (program, workdir, lang_hint) = read_primary_metadata(trace_dir)?;

    // Detect language from the program's file extension.  When the extension
    // is unrecognized (compiled binaries often have no extension), use the
    // integer `lang` field from `trace_db_metadata.json` as a fallback.
    let language = {
        let from_ext = detect_language(&program);
        if from_ext == "unknown" {
            lang_hint.unwrap_or(from_ext)
        } else {
            from_ext
        }
    };

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
            log::warn!("Could not count events in {}: {e}", trace_path.display());
            0
        }
    };

    Ok(TraceMetadata {
        language,
        total_events,
        source_files,
        program,
        workdir,
    })
}

/// Reads the primary metadata (program path, workdir, optional language hint)
/// from whichever metadata file is available in the trace directory.
///
/// Resolution order:
/// 1. `trace_metadata.json` (simple format)
/// 2. `trace_db_metadata.json` (extended format from `ct-rr-support record`)
///
/// Returns `(program, workdir, lang_hint)` where `lang_hint` is `Some` only
/// when the metadata came from `trace_db_metadata.json` and contained a
/// recognized `lang` integer.
fn read_primary_metadata(
    trace_dir: &Path,
) -> Result<(String, String, Option<String>), TraceMetadataError> {
    let simple_path = trace_dir.join("trace_metadata.json");

    match std::fs::read_to_string(&simple_path) {
        Ok(contents) => {
            // Successfully read trace_metadata.json — use it.
            let raw: RawTraceMetadata =
                serde_json::from_str(&contents).map_err(|e| TraceMetadataError::Json {
                    file: simple_path,
                    source: e,
                })?;
            Ok((raw.program, raw.workdir, None))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // trace_metadata.json missing — fall back to trace_db_metadata.json.
            log::info!(
                "trace_metadata.json not found, trying trace_db_metadata.json in {}",
                trace_dir.display()
            );
            let db_path = trace_dir.join("trace_db_metadata.json");
            let contents =
                std::fs::read_to_string(&db_path).map_err(|e| TraceMetadataError::Io {
                    file: db_path.clone(),
                    source: e,
                })?;
            let raw: RawTraceDbMetadata =
                serde_json::from_str(&contents).map_err(|e| TraceMetadataError::Json {
                    file: db_path,
                    source: e,
                })?;

            // Convert the integer lang field to a language name string.
            let lang_name = lang_id_to_name(raw.lang);
            let lang_hint = if lang_name != "unknown" {
                Some(lang_name.to_string())
            } else {
                None
            };

            Ok((raw.program, raw.workdir, lang_hint))
        }
        Err(e) => {
            // Some other I/O error (permission denied, etc.) — propagate it.
            Err(TraceMetadataError::Io {
                file: simple_path,
                source: e,
            })
        }
    }
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

    /// Helper: creates a temporary trace directory with `trace_metadata.json`
    /// (the simple format) and optional supplementary files.
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

    /// Helper: creates a temporary trace directory with only
    /// `trace_db_metadata.json` (the extended format from `ct-rr-support
    /// record`), without a `trace_metadata.json`.  This simulates the
    /// common case for real RR-recorded traces.
    fn create_test_trace_dir_db_format(
        test_name: &str,
        db_metadata_json: &str,
        paths_json: Option<&str>,
    ) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("{}-{}", test_name, std::process::id()));
        std::fs::create_dir_all(&dir).expect("create test dir");

        std::fs::write(dir.join("trace_db_metadata.json"), db_metadata_json)
            .expect("write trace_db_metadata.json");

        if let Some(paths) = paths_json {
            std::fs::write(dir.join("trace_paths.json"), paths).expect("write trace_paths.json");
        }

        std::fs::create_dir_all(dir.join("files")).expect("create files dir");
        dir
    }

    // -----------------------------------------------------------------------
    // detect_language tests
    // -----------------------------------------------------------------------

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

    // -----------------------------------------------------------------------
    // lang_id_to_name tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_lang_id_to_name_known_languages() {
        assert_eq!(lang_id_to_name(0), "c");
        assert_eq!(lang_id_to_name(1), "cpp");
        assert_eq!(lang_id_to_name(2), "rust");
        assert_eq!(lang_id_to_name(3), "nim");
        assert_eq!(lang_id_to_name(4), "go");
        assert_eq!(lang_id_to_name(5), "pascal");
        assert_eq!(lang_id_to_name(12), "python");
        assert_eq!(lang_id_to_name(13), "ruby");
        assert_eq!(lang_id_to_name(15), "javascript");
        assert_eq!(lang_id_to_name(18), "noir");
    }

    #[test]
    fn test_lang_id_to_name_unknown() {
        assert_eq!(lang_id_to_name(255), "unknown");
        assert_eq!(lang_id_to_name(23), "unknown"); // Lang::Unknown in the enum
    }

    // -----------------------------------------------------------------------
    // read_trace_metadata with trace_metadata.json (simple format)
    // -----------------------------------------------------------------------

    #[test]
    fn test_read_trace_metadata_complete() {
        let dir = create_test_trace_dir(
            "complete",
            r#"{"workdir":"/home/user/project","program":"main.rs","args":[]}"#,
            Some(r#"["src/main.rs","src/lib.rs"]"#),
            Some(
                r#"[{"Step":{"path_id":0,"line":1}},{"Step":{"path_id":0,"line":2}},{"Step":{"path_id":0,"line":3}}]"#,
            ),
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

    // -----------------------------------------------------------------------
    // read_trace_metadata fallback to trace_db_metadata.json
    // -----------------------------------------------------------------------

    #[test]
    fn test_fallback_to_trace_db_metadata() {
        // Simulate a trace produced by `ct-rr-support record` which writes
        // only `trace_db_metadata.json` (the extended format).  The binary
        // has no extension, so detect_language would return "unknown" — the
        // integer `lang` field (0 = C) should be used instead.
        let dir = create_test_trace_dir_db_format(
            "fallback-c",
            r#"{
                "id": 0,
                "program": "/tmp/build/config-parser",
                "args": [],
                "env": "",
                "workdir": "/home/user/project",
                "output": "",
                "sourceFolders": ["/home/user/project/src"],
                "lowLevelFolder": "",
                "compileCommand": "",
                "outputFolder": "/tmp/trace-42",
                "date": "",
                "duration": "",
                "lang": 0,
                "imported": false,
                "calltrace": true,
                "events": true,
                "test": false,
                "archiveServerID": -1,
                "shellID": -1,
                "teamID": -1,
                "rrPid": 12345,
                "exitCode": 0,
                "calltraceMode": 0,
                "downloadKey": "",
                "controlId": "",
                "onlineExpireTime": -1
            }"#,
            Some(r#"["src/config_parser.c"]"#),
        );

        let meta = read_trace_metadata(&dir).expect("read metadata via fallback");
        assert_eq!(meta.language, "c", "lang=0 should resolve to 'c'");
        assert_eq!(meta.program, "/tmp/build/config-parser");
        assert_eq!(meta.workdir, "/home/user/project");
        assert_eq!(meta.source_files, vec!["src/config_parser.c"]);
        assert_eq!(meta.total_events, 0); // no trace.json

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_fallback_rust_binary_no_extension() {
        // Rust binary without extension, lang=2 (Rust).
        let dir = create_test_trace_dir_db_format(
            "fallback-rust",
            r#"{
                "id": 0,
                "program": "/home/user/target/debug/myapp",
                "args": ["--test"],
                "workdir": "/home/user/myapp",
                "sourceFolders": [],
                "outputFolder": "/tmp/trace-99",
                "lang": 2,
                "rrPid": 99999,
                "exitCode": 0,
                "calltraceMode": 0
            }"#,
            None,
        );

        let meta = read_trace_metadata(&dir).expect("read metadata via fallback");
        assert_eq!(meta.language, "rust", "lang=2 should resolve to 'rust'");
        assert_eq!(meta.program, "/home/user/target/debug/myapp");
        assert_eq!(meta.workdir, "/home/user/myapp");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_fallback_with_extension_overrides_lang_field() {
        // Program has a .nim extension — detect_language should take
        // priority over the lang integer, even in the fallback path.
        let dir = create_test_trace_dir_db_format(
            "fallback-ext-wins",
            r#"{
                "id": 0,
                "program": "/home/user/test.nim",
                "args": [],
                "workdir": "/home/user",
                "sourceFolders": [],
                "outputFolder": "/tmp/trace-77",
                "lang": 3,
                "rrPid": 55555,
                "exitCode": 0,
                "calltraceMode": 0
            }"#,
            None,
        );

        let meta = read_trace_metadata(&dir).expect("read metadata via fallback");
        assert_eq!(
            meta.language, "nim",
            "file extension should take priority over lang field"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_neither_metadata_file_exists() {
        // A directory with no metadata files at all should produce an error.
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("no-meta-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create test dir");

        let result = read_trace_metadata(&dir);
        assert!(
            result.is_err(),
            "should error when neither metadata file exists"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_simple_format_preferred_over_db_format() {
        // When both files exist, trace_metadata.json should be used.
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("both-meta-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create test dir");

        // trace_metadata.json says program is "main.rs" (detects as Rust)
        std::fs::write(
            dir.join("trace_metadata.json"),
            r#"{"workdir":"/tmp","program":"main.rs","args":[]}"#,
        )
        .expect("write trace_metadata.json");

        // trace_db_metadata.json says program is a binary, lang=0 (C)
        std::fs::write(
            dir.join("trace_db_metadata.json"),
            r#"{"id":0,"program":"/tmp/binary","args":[],"workdir":"/other","sourceFolders":[],"outputFolder":"/tmp","lang":0,"rrPid":1,"exitCode":0,"calltraceMode":0}"#,
        )
        .expect("write trace_db_metadata.json");

        let meta = read_trace_metadata(&dir).expect("read metadata");
        assert_eq!(
            meta.program, "main.rs",
            "trace_metadata.json should be preferred"
        );
        assert_eq!(meta.language, "rust");
        assert_eq!(meta.workdir, "/tmp");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // -----------------------------------------------------------------------
    // Real trace test (only runs when the test trace directory is available)
    // -----------------------------------------------------------------------

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
