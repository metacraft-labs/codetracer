//! M-REC-1.5 acceptance test: end-to-end metadata loading through the
//! backend-manager's CTFS `meta.dat` reader.
//!
//! Builds a minimal `trace.ct` CTFS container with only `meta.dat` (no
//! legacy `trace_metadata.json` / `trace_db_metadata.json` /
//! `trace_paths.json` sidecars), points the backend-manager metadata
//! reader at the trace directory, and asserts that every field
//! round-trips.
//!
//! This is the "no legacy reads" guarantee: a fresh recording with only
//! `meta.dat` must load through every backend-manager code path that
//! previously needed JSON sidecars.

// Re-import the meta_dat module from the binary crate.  Tests under
// `tests/` link against the crate as a library, but session-manager is a
// bin crate so we use the same trick as the in-crate unit tests: cargo
// builds an extra integration-test executable that includes the bin's
// source.  Here we re-declare the modules we need via `#[path]` so the
// integration test can call into them without going through the daemon.
//
// The simpler alternative — running the actual daemon and querying via
// DAP — is exercised by the surrounding RR-based tests; this file
// targets the lower-level metadata-loading layer directly so we can
// assert field-by-field equality without depending on a real recorder.
#[path = "../src/meta_dat.rs"]
mod meta_dat;

#[path = "../src/trace_metadata.rs"]
mod trace_metadata;

use std::path::PathBuf;

/// Canonical pinned UUIDv7 used for tests.  Embedded ms timestamp is
/// fictional; byte layout passes `is_canonical_uuid_v7`.
const TEST_RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

/// Build a CTFS container with a single `meta.dat` internal file under
/// `dir/trace.ct`, populated with the given metadata.  Returns the
/// trace directory.
fn make_recording(test_name: &str, mcr_total_events: Option<u64>) -> PathBuf {
    let dir = std::env::temp_dir()
        .join("ct-meta-dat-integration")
        .join(format!("{}-{}", test_name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create test dir");

    let mcr = mcr_total_events.map(|total_events| meta_dat::McrFields {
        tick_source: 1,
        total_threads: 1,
        atomic_mode: 0,
        total_events,
        total_checkpoints: 0,
        start_time_unix_us: 1_715_000_000_000_000,
        platform: "linux-x86_64".to_owned(),
        tick_granularity: "instruction".to_owned(),
        tick_source_str: "rdtsc".to_owned(),
        atomic_mode_str: "seq_cst".to_owned(),
        start_time_str: "2026-05-18T00:00:00Z".to_owned(),
        hook_profile: "default".to_owned(),
        hook_strategies: vec!["ldpreload".to_owned()],
    });

    let meta = meta_dat::MetaDat {
        version: meta_dat::META_DAT_VERSION,
        flags: 0, // serializer derives flags from `mcr.is_some()`
        recording_id: TEST_RECORDING_ID.to_owned(),
        program: "/home/user/project/main.rs".to_owned(),
        args: vec!["--input".to_owned(), "data.txt".to_owned()],
        workdir: "/home/user/project".to_owned(),
        recorder_id: "test".to_owned(),
        paths: vec!["src/main.rs".to_owned(), "src/lib.rs".to_owned()],
        mcr,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: Vec::new(),
        has_filter_provenance: false,
    };
    let dat_bytes = meta_dat::serialize_meta_dat(&meta);
    meta_dat::write_minimal_ctfs(&dir.join("trace.ct"), &[("meta.dat", &dat_bytes)])
        .expect("write minimal ctfs");
    dir
}

#[test]
fn loads_meta_dat_only_trace_end_to_end() {
    let dir = make_recording("loads-meta-dat-only", Some(424242));

    // Defensive check that the directory genuinely has no legacy sidecar
    // files — this test exists specifically to demonstrate the
    // post-M-REC-1.5 behaviour where meta.dat is the *only* metadata
    // source.
    for sidecar in [
        "trace_metadata.json",
        "trace_db_metadata.json",
        "trace_paths.json",
    ] {
        assert!(
            !dir.join(sidecar).exists(),
            "unexpected legacy sidecar {sidecar} present in fixture",
        );
    }

    let meta = trace_metadata::read_trace_metadata(&dir).expect("read metadata");

    assert_eq!(meta.recording_id, TEST_RECORDING_ID);
    assert_eq!(meta.program, "/home/user/project/main.rs");
    assert_eq!(meta.workdir, "/home/user/project");
    assert_eq!(meta.source_files, vec!["src/main.rs", "src/lib.rs"]);
    // Language derived from the program extension.
    assert_eq!(meta.language, "rust");
    // total_events comes from the MCR block.
    assert_eq!(meta.total_events, 424242);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn loads_meta_dat_only_trace_without_mcr_block() {
    let dir = make_recording("loads-meta-dat-no-mcr", None);

    let meta = trace_metadata::read_trace_metadata(&dir).expect("read metadata");

    assert_eq!(meta.recording_id, TEST_RECORDING_ID);
    // No MCR block → total_events defaults to 0.
    assert_eq!(meta.total_events, 0);
    assert_eq!(meta.language, "rust");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn rejects_trace_dir_missing_ct_file() {
    let dir = std::env::temp_dir()
        .join("ct-meta-dat-integration")
        .join(format!("no-ct-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    match trace_metadata::read_trace_metadata(&dir) {
        Err(trace_metadata::TraceMetadataError::MissingCtFile { .. }) => {}
        other => panic!("expected MissingCtFile, got {other:?}"),
    }

    let _ = std::fs::remove_dir_all(&dir);
}
