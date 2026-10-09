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
//! | `source_files`        | `paths.dat` records, in id order          |
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

    /// Source file paths referenced by the trace: the records of the
    /// container's `paths.dat`, its only list of source paths.
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

/// Members that are not part of the trace format; a container carrying
/// either is not a recording.
const RETIRED_MEMBERS: [&str; 2] = ["events.log", "events.fmt"];

/// Reads metadata from a trace's CTFS `.ct` container.
///
/// `trace_dir` is either a `.ct` container itself (a native recording or
/// one of its `--split` slices) or a directory holding a `trace.ct` (or
/// exactly one other `.ct`).  The container's `meta.dat` internal stream
/// must be a version this parser accepts (M-REC-1; see
/// `meta_dat::SUPPORTED_META_DAT_VERSIONS`).
///
/// # Errors
///
/// Returns [`TraceMetadataError`] if `trace.ct` is missing, cannot be
/// opened, carries a malformed/legacy `meta.dat`, or carries a member that
/// is not part of the trace format (`events.log`, `events.fmt`).
pub fn read_trace_metadata(trace_dir: &Path) -> Result<TraceMetadata, TraceMetadataError> {
    let ct_path = locate_ct_file(trace_dir)?;
    let bytes = std::fs::read(&ct_path).map_err(|source| TraceMetadataError::Io {
        file: ct_path.clone(),
        source,
    })?;

    for name in RETIRED_MEMBERS {
        let present = meta_dat::ctfs_has_member(&bytes, name).map_err(|message| {
            TraceMetadataError::Ctfs {
                file: ct_path.clone(),
                message,
            }
        })?;
        if present {
            return Err(TraceMetadataError::RetiredMember {
                file: ct_path.clone(),
                name,
            });
        }
    }

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

    // `paths.dat` is the trace's only list of source paths; `meta.dat`
    // carries none (internal-files.md §"`meta.dat` carries no path list").
    let source_files =
        meta_dat::read_source_paths_from_ctfs(&bytes, parsed.flags).map_err(|message| {
            TraceMetadataError::Ctfs {
                file: ct_path.clone(),
                message,
            }
        })?;

    // Language detection: try the program path first.  When it does
    // not carry a recognised extension (e.g. compiled RR binaries like
    // `rust_flow_test`, or the Ruby native gem which stores the
    // interpreter name `"ruby"`), fall back to inspecting the
    // recorded source paths so we still surface a useful answer.
    let mut language = detect_language(&parsed.program);
    if language == "unknown" {
        for path in &source_files {
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
    // the CTFS container for the byte size of its step stream
    // (`steps.dat`).  The size is a coarse proxy for event count, but it
    // is non-zero whenever the recorder produced any events, which is
    // enough to satisfy the daemon's "has the trace got events?" contract.
    let total_events = if let Some(mcr) = parsed.mcr.as_ref() {
        mcr.total_events
    } else {
        meta_dat::ctfs_internal_file_size(&bytes, "steps.dat")
            .ok()
            .flatten()
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
    let program = if !source_files.is_empty()
        && !parsed.program.contains('/')
        && !parsed.program.contains('\\')
        && Path::new(&parsed.program).extension().is_none()
    {
        source_files[0].clone()
    } else {
        parsed.program
    };

    Ok(TraceMetadata {
        recording_id: parsed.recording_id,
        language,
        total_events,
        source_files,
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
    // A bare container is its own trace: `ct-mcr record` writes
    // `<name>.ct` (and `--split` writes `<name>.ct_slices/slice_NNNN.ct`)
    // with no enclosing trace directory, and the replay server accepts the
    // file itself as its trace folder.  Whether it is a valid container is
    // decided by the CTFS reader, which names what is wrong with it.
    if trace_dir.is_file() {
        return Ok(trace_dir.to_path_buf());
    }
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
    /// The container carries a member that is not part of the trace format
    /// (`events.log`, `events.fmt`); it is not a recording.
    RetiredMember {
        file: std::path::PathBuf,
        name: &'static str,
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
            Self::RetiredMember { file, name } => write!(
                f,
                "{} carries `{name}`, which is not part of the trace format; it is refused",
                file.display()
            ),
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

    /// `paths.dat` + `paths.off` interning `paths` in id order.
    fn paths_table(paths: &[&str]) -> (Vec<u8>, Vec<u8>) {
        let mut dat = Vec::new();
        let mut off = 0u64.to_le_bytes().to_vec();
        for p in paths {
            dat.extend_from_slice(p.as_bytes());
            off.extend_from_slice(&(dat.len() as u64).to_le_bytes());
        }
        (dat, off)
    }

    /// Build a `trace_dir/trace.ct` containing the given metadata, and
    /// `paths` as its `paths.dat`, for tests.
    fn make_trace_dir(
        test_name: &str,
        program: &str,
        workdir: &str,
        args: &[&str],
        paths: &[&str],
    ) -> PathBuf {
        make_trace_dir_with_members(test_name, program, workdir, args, paths, &[])
    }

    /// [`make_trace_dir`], with `extra` members stored in the container
    /// after `meta.dat` and the paths table.
    fn make_trace_dir_with_members(
        test_name: &str,
        program: &str,
        workdir: &str,
        args: &[&str],
        paths: &[&str],
        extra: &[(&str, &[u8])],
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
            ext_flags: 0,
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = meta_dat::serialize_meta_dat(&meta);
        let (paths_dat, paths_off) = paths_table(paths);
        let ct_path = dir.join("trace.ct");
        let mut members: Vec<(&str, &[u8])> =
            vec![("meta.dat", &dat), ("paths.dat", &paths_dat), ("paths.off", &paths_off)];
        members.extend_from_slice(extra);
        meta_dat::write_minimal_ctfs(&ct_path, &members).expect("write minimal ctfs");

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

    /// A `.ct` path is read as the container itself, the shape `ct-mcr
    /// record` writes (`<name>.ct`, and `<name>.ct_slices/slice_NNNN.ct`
    /// with `--split`).  Two slices sit in one directory here, which a
    /// directory lookup refuses as ambiguous, so each file must be read by
    /// its own path and yield its own fields.
    #[test]
    fn test_read_trace_metadata_from_a_bare_container_file() {
        let first = make_trace_dir("bare-a", "first.c", "/w/a", &[], &["a.c"]);
        let second = make_trace_dir("bare-b", "second.nim", "/w/b", &[], &["b.nim"]);
        let slices = std::env::temp_dir()
            .join("ct-trace-meta-test")
            .join(format!("bare-{}", std::process::id()))
            .join("rec.ct_slices");
        let _ = std::fs::remove_dir_all(&slices);
        std::fs::create_dir_all(&slices).expect("create slices dir");
        std::fs::copy(first.join("trace.ct"), slices.join("slice_0000.ct")).expect("copy");
        std::fs::copy(second.join("trace.ct"), slices.join("slice_0001.ct")).expect("copy");

        let a = read_trace_metadata(&slices.join("slice_0000.ct")).expect("read slice 0");
        assert_eq!(
            (a.program.as_str(), a.workdir.as_str()),
            ("first.c", "/w/a")
        );
        assert_eq!(
            (a.language.as_str(), a.source_files.clone()),
            ("c", vec!["a.c".to_owned()])
        );
        let b = read_trace_metadata(&slices.join("slice_0001.ct")).expect("read slice 1");
        assert_eq!(
            (b.program.as_str(), b.workdir.as_str()),
            ("second.nim", "/w/b")
        );
        assert_eq!(b.source_files, vec!["b.nim".to_owned()]);
        assert!(matches!(
            read_trace_metadata(&slices),
            Err(TraceMetadataError::AmbiguousCtFile { count: 2, .. })
        ));

        // A file that is not a container is refused by the CTFS reader,
        // not reported as a directory without a `trace.ct`.
        let not_a_container = slices.join("notes.ct");
        std::fs::write(&not_a_container, b"not a container").expect("write");
        assert!(matches!(
            read_trace_metadata(&not_a_container),
            Err(TraceMetadataError::Ctfs { .. })
        ));

        for dir in [
            first,
            second,
            slices.parent().expect("parent").to_path_buf(),
        ] {
            let _ = std::fs::remove_dir_all(dir);
        }
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

    /// A container carrying `events.log` or `events.fmt` is not a recording:
    /// neither member is part of the trace format, so its metadata is refused,
    /// naming the member, rather than reported with an event count.
    #[test]
    fn test_container_with_a_retired_member_is_refused_by_name() {
        for (i, name) in ["events.log", "events.fmt"].into_iter().enumerate() {
            let dir = make_trace_dir_with_members(
                &format!("retired-{i}"),
                "app.py",
                "/w",
                &[],
                &["/w/app.py"],
                &[(name, b"payload")],
            );
            match read_trace_metadata(&dir) {
                Err(err @ TraceMetadataError::RetiredMember { .. }) => {
                    assert!(err.to_string().contains(name), "{name}: {err}");
                }
                other => panic!("{name}: expected RetiredMember, got {other:?}"),
            }
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// A program name with no extension falls back to the first `paths.dat`
    /// record, for both the language and the program surfaced.
    #[test]
    fn test_extensionless_program_falls_back_to_paths_dat() {
        let dir = make_trace_dir("fallback", "ruby", "/w", &[], &["/w/app.rb", "/w/lib.rb"]);
        let meta = read_trace_metadata(&dir).expect("read metadata");
        assert_eq!(meta.language, "ruby");
        assert_eq!(meta.program, "/w/app.rb");
        assert_eq!(meta.source_files, vec!["/w/app.rb", "/w/lib.rb"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
