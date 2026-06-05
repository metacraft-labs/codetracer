//! Trace metadata extraction from on-disk trace directories.
//!
//! A CodeTracer trace directory contains a CTFS `.ct` container that holds
//! the recorded execution data plus the canonical per-trace metadata in
//! its internal `meta.dat` file (M-REC-1, M-REC-1.5).  The historical
//! sibling JSON files (`trace_metadata.json` / `trace_db_metadata.json` /
//! `trace_paths.json`) were retired in M-REC-1.5 — pre-1.0, no
//! backcompat shim.
//!
//! This module reads `meta.dat` out of `<trace_dir>/trace.ct` and produces
//! a [`TraceMetadata`] struct that the daemon uses to populate session
//! information returned by the `ct/open-trace` and `ct/trace-info` MCP
//! commands.
//!
//! ## meta.dat → `TraceMetadata` field mapping
//!
//! | `TraceMetadata` field | source                                  |
//! |-----------------------|------------------------------------------|
//! | `recording_id`        | `meta.dat` v3+ `recording_id` (UUIDv7)   |
//! | `program`             | `meta.dat` `program`                     |
//! | `workdir`             | `meta.dat` `workdir`                     |
//! | `source_files`        | `meta.dat` `paths`                       |
//! | `language`            | derived from `program` extension         |
//! | `total_events`        | `meta.dat` MCR `total_events` if present |
//!
//! Language detection: the legacy `trace_db_metadata.json` carried an
//! integer `lang` field that disambiguated extensionless binaries (e.g.
//! `lang = 2` → Rust).  With JSON sidecars retired, we rely solely on the
//! file-extension heuristic; binaries without extensions resolve to
//! `"unknown"` and the consumer must fall back to other heuristics
//! (e.g. inspecting the recorder id once it surfaces upstream).

use std::path::Path;

use crate::meta_dat::{self, MetaDatError};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Metadata extracted from a trace directory's `meta.dat` file.
#[derive(Debug, Clone)]
pub struct TraceMetadata {
    /// Recording identifier (UUIDv7, canonical lowercase hyphenated
    /// 36-char form per RFC 9562).  Introduced in M-REC-1 and surfaced
    /// through `meta.dat` v3+.
    #[allow(dead_code)]
    pub recording_id: String,

    /// Detected programming language of the traced program.
    ///
    /// Derived from the file extension of the `program` field in
    /// `meta.dat` (e.g. `.rs` -> `"rust"`, `.nim` -> `"nim"`).
    pub language: String,

    /// Total number of execution events recorded in the trace.  Sourced
    /// from `meta.dat`'s MCR `total_events` field when the recording
    /// carries the MCR block, otherwise `0`.  M-REC-1.5 removed the
    /// legacy `trace.json` event count.
    pub total_events: u64,

    /// Source file paths referenced by the trace, as recorded in
    /// `meta.dat`'s `paths` block.
    pub source_files: Vec<String>,

    /// Program path or identifier as recorded.
    pub program: String,

    /// Working directory at the time of recording.
    pub workdir: String,
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
        // Noir source files (https://noir-lang.org/) — needed for
        // `nargo trace` output language detection.  The Noir tracer
        // stores the package name (e.g. `noir_test`, no extension) in
        // `meta.dat::program`, so the source-path fallback in
        // `read_trace_metadata` is the only hint that surfaces.
        "nr" => "noir",
        _ => "unknown",
    }
    .to_string()
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Reads metadata from a trace directory's CTFS `.ct` container.
///
/// The directory must contain a `trace.ct` file with a v3 `meta.dat`
/// internal stream (M-REC-1).
///
/// # Errors
///
/// Returns [`TraceMetadataError`] if `trace.ct` is missing, cannot be
/// opened, or carries a malformed/legacy `meta.dat`.
pub fn read_trace_metadata(trace_dir: &Path) -> Result<TraceMetadata, TraceMetadataError> {
    let ct_path = locate_ct_file(trace_dir)?;
    let bytes = std::fs::read(&ct_path).map_err(|source| TraceMetadataError::Io {
        file: ct_path.clone(),
        source,
    })?;

    let meta_dat_bytes =
        meta_dat::read_meta_dat_from_ctfs(&bytes).map_err(|message| TraceMetadataError::Ctfs {
            file: ct_path.clone(),
            message,
        })?;

    let parsed = meta_dat::parse_meta_dat(&meta_dat_bytes).map_err(|source| {
        TraceMetadataError::MetaDat {
            file: ct_path.clone(),
            source,
        }
    })?;

    // Language detection: try the program path first.  When it does
    // not carry a recognised extension (e.g. compiled RR binaries like
    // `rust_flow_test`, or the Ruby native gem which stores the
    // interpreter name `"ruby"`), fall back to inspecting the
    // recorded source paths so we still surface a useful answer.
    let mut language = detect_language(&parsed.program);
    if language == "unknown" {
        for path in &parsed.paths {
            let candidate = detect_language(path);
            if candidate != "unknown" {
                language = candidate;
                break;
            }
        }
    }

    // `total_events` should ideally come from `meta.dat::mcr::total_events`,
    // but the current Nim multi-stream writer only fills the MCR block
    // for native MCR recordings — materialized traces (Noir, Ruby
    // native, JS, Python, …) leave it empty.  As a stand-in we probe
    // the CTFS container for the byte size of the materialized event
    // streams (`steps.dat`, then `events.log` for the old format).
    // The size is a coarse proxy for event count, but it is non-zero
    // whenever the recorder produced any events, which is enough to
    // satisfy the daemon's "has the trace got events?" contract.
    let total_events = if let Some(mcr) = parsed.mcr.as_ref() {
        mcr.total_events
    } else {
        meta_dat::ctfs_internal_file_size(&bytes, "steps.dat")
            .ok()
            .flatten()
            .or_else(|| {
                meta_dat::ctfs_internal_file_size(&bytes, "events.log")
                    .ok()
                    .flatten()
            })
            .unwrap_or(0)
    };

    // Program surfacing: recorders that store the interpreter name
    // (Ruby native gem → `"ruby"`, JS recorder → `"node"`, …) leave
    // the daemon without a usable script identity.  When the
    // `meta.dat::program` does not look like a path (no `/`, no `\`,
    // no file extension) but the trace recorded at least one source
    // file, surface that source path instead so MCP clients and
    // tests have a real script reference.  The recorder-supplied
    // value is still preserved in `meta.dat`; only the
    // user-facing `program` is rewritten.
    let program = if !parsed.paths.is_empty()
        && !parsed.program.contains('/')
        && !parsed.program.contains('\\')
        && Path::new(&parsed.program).extension().is_none()
    {
        parsed.paths[0].clone()
    } else {
        parsed.program
    };

    Ok(TraceMetadata {
        recording_id: parsed.recording_id,
        language,
        total_events,
        source_files: parsed.paths,
        program,
        workdir: parsed.workdir,
    })
}

/// Locate the CTFS container inside the trace directory.
///
/// Recorders write a `trace.ct` file by convention.  If the directory
/// happens to contain a single `.ct` file under a different name, that
/// file is used as a fallback.
fn locate_ct_file(trace_dir: &Path) -> Result<std::path::PathBuf, TraceMetadataError> {
    let canonical = trace_dir.join("trace.ct");
    if canonical.exists() {
        return Ok(canonical);
    }

    // Fallback: scan the directory for any `.ct` file so users who pass a
    // standalone-named container (e.g. `helloworld.ct`) still get a
    // helpful experience.  We require exactly one match to avoid
    // ambiguity.
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(read_dir) = std::fs::read_dir(trace_dir) {
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) == Some("ct") {
                candidates.push(path);
            }
        }
    }

    match candidates.len() {
        0 => Err(TraceMetadataError::MissingCtFile {
            dir: trace_dir.to_path_buf(),
        }),
        1 => Ok(candidates.remove(0)),
        _ => Err(TraceMetadataError::AmbiguousCtFile {
            dir: trace_dir.to_path_buf(),
            count: candidates.len(),
        }),
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors that can occur when reading trace metadata.
#[derive(Debug)]
pub enum TraceMetadataError {
    /// An I/O error reading the CTFS container.
    Io {
        file: std::path::PathBuf,
        source: std::io::Error,
    },
    /// The trace directory does not contain a `trace.ct` file.
    MissingCtFile { dir: std::path::PathBuf },
    /// The trace directory contains multiple `.ct` files; cannot
    /// disambiguate without an explicit choice.
    AmbiguousCtFile {
        dir: std::path::PathBuf,
        count: usize,
    },
    /// The CTFS container is malformed or does not carry `meta.dat`.
    Ctfs {
        file: std::path::PathBuf,
        message: String,
    },
    /// `meta.dat` is present but cannot be parsed (e.g. wrong version,
    /// missing `recording_id`).
    MetaDat {
        file: std::path::PathBuf,
        source: MetaDatError,
    },
}

impl std::fmt::Display for TraceMetadataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { file, source } => {
                write!(f, "cannot read {}: {source}", file.display())
            }
            Self::MissingCtFile { dir } => write!(
                f,
                "no `trace.ct` (or other `.ct` file) found in {} — legacy \
                 trace_metadata.json/trace_db_metadata.json sidecars are no \
                 longer accepted (M-REC-1.5)",
                dir.display(),
            ),
            Self::AmbiguousCtFile { dir, count } => write!(
                f,
                "found {count} `.ct` files in {} — cannot pick a canonical \
                 trace container without an explicit `trace.ct` named match",
                dir.display(),
            ),
            Self::Ctfs { file, message } => {
                write!(f, "cannot read meta.dat from {}: {message}", file.display())
            }
            Self::MetaDat { file, source } => {
                write!(f, "cannot parse meta.dat in {}: {source}", file.display())
            }
        }
    }
}

impl std::error::Error for TraceMetadataError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::MetaDat { source, .. } => Some(source),
            _ => None,
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

    /// Canonical pinned test UUIDv7 used to build meta.dat fixtures.
    const TEST_RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

    /// Build a `trace_dir/trace.ct` containing the given metadata for tests.
    fn make_trace_dir(
        test_name: &str,
        program: &str,
        workdir: &str,
        args: &[&str],
        paths: &[&str],
    ) -> PathBuf {
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("{}-{}", test_name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create test dir");

        let meta = meta_dat::MetaDat {
            version: meta_dat::META_DAT_VERSION,
            flags: 0,
            recording_id: TEST_RECORDING_ID.to_owned(),
            program: program.to_owned(),
            args: args.iter().map(|s| (*s).to_owned()).collect(),
            workdir: workdir.to_owned(),
            recorder_id: "test".to_owned(),
            paths: paths.iter().map(|s| (*s).to_owned()).collect(),
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = meta_dat::serialize_meta_dat(&meta);
        let ct_path = dir.join("trace.ct");
        meta_dat::write_minimal_ctfs(&ct_path, &[("meta.dat", &dat)]).expect("write minimal ctfs");

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
        let dir = make_trace_dir(
            "complete",
            "main.rs",
            "/home/user/project",
            &[],
            &["src/main.rs", "src/lib.rs"],
        );

        let meta = read_trace_metadata(&dir).expect("read metadata");
        assert_eq!(meta.recording_id, TEST_RECORDING_ID);
        assert_eq!(meta.language, "rust");
        assert_eq!(meta.program, "main.rs");
        assert_eq!(meta.workdir, "/home/user/project");
        assert_eq!(meta.source_files, vec!["src/main.rs", "src/lib.rs"]);
        // No MCR block in the fixture so total_events stays at 0.
        assert_eq!(meta.total_events, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_trace_metadata_minimal() {
        let dir = make_trace_dir("minimal", "test.nim", "/tmp", &["--flag"], &[]);

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
    fn test_missing_ct_file_returns_error() {
        let dir = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("no-ct-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create test dir");

        let result = read_trace_metadata(&dir);
        match result {
            Err(TraceMetadataError::MissingCtFile { .. }) => {}
            other => panic!("expected MissingCtFile, got {other:?}"),
        }

        let _ = std::fs::remove_dir_all(&dir);
    }
}
