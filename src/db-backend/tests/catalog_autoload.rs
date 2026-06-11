//! §P8.3 acceptance tests — opt-in catalog autoload.
//!
//! Drives the full Handler-level integration:
//!
//! 1. Build a tinylib-shaped catalog directory on disk in a tempdir.
//!    Hand-craft a one-liner minified bundle and a matching rename
//!    TOML so we don't depend on network access to a real CDN.
//! 2. Build a synthetic trace whose only step references the bundle
//!    (same shape the §P5 acceptance test uses).
//! 3. Drive `Handler::load_catalog_autoload` and assert the per-spec
//!    behaviour:
//!
//!    * Without `CT_CATALOG_AUTOLOAD`, the match is logged but NOT
//!      applied — assert the rename list is empty after the call.
//!    * With `CT_CATALOG_AUTOLOAD=1`, the matching entry IS applied —
//!      assert the rename list now contains the cataloged renames.
//!    * Even with the env opt-in, a SHA mismatch (corrupted entry
//!      claim) prevents application.
//!
//! Spec:
//! `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P8.3.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;

use codetracer_trace_types::{
    CallRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TypeKind, TypeRecord,
    TypeSpecificInfo,
};
use db_backend::catalog_autoload::{
    AutoloadOutcome, autoload_enabled, install_to_recording_dir, scan_single_path,
};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap_handler::Handler;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;
use mapping_catalog::{Catalog, compute_file_sha256};

/// Process-global lock for tests that mutate `CT_CATALOG_AUTOLOAD`.
/// The env vars are read at scan time; concurrent mutation would race.
fn env_lock() -> &'static Mutex<()> {
    static M: OnceLock<Mutex<()>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(()))
}

/// Set / unset an env var.  Safe under `env_lock`.
fn set_env(key: &str, val: Option<&str>) {
    // SAFETY: every caller holds `env_lock()`; we never invoke this
    // outside that critical section.
    match val {
        Some(v) => unsafe { std::env::set_var(key, v) },
        None => unsafe { std::env::remove_var(key) },
    }
}

/// Hand-crafted one-liner bundle — same shape as the §P3 lodash
/// fixture's minified source, but treated as the "tinylib" library so
/// it doesn't clash with the lodash fixture's renames.
const TINYLIB_MIN_BODY: &str =
    "function a(b,c){return b+c;}function d(e){return e*2;}var f=a(1,2);var g=d(f);\n";

/// Build a tinylib catalog directory + the matching minified bundle.
///
/// Returns `(catalog_dir_guard, catalog_root, trace_dir_guard,
/// trace_dir, bundle_path)`.
fn build_tinylib_fixture() -> (tempfile::TempDir, PathBuf, tempfile::TempDir, PathBuf, PathBuf) {
    let cat_dir = tempfile::tempdir().expect("cat tempdir");
    let cat_root = cat_dir.path().to_path_buf();
    std::fs::create_dir_all(cat_root.join("catalog/tinylib/1.0.0")).unwrap();
    std::fs::write(
        cat_root.join("catalog/tinylib/1.0.0/tinylib.min.js.toml"),
        r#"
            [[rename]]
            file = "tinylib.min.js"
            from = "a"
            to = "add"

            [[rename]]
            file = "tinylib.min.js"
            from = "d"
            to = "double"
        "#,
    )
    .unwrap();

    let trace_dir = tempfile::tempdir().expect("trace tempdir");
    let trace_path = trace_dir.path().to_path_buf();
    let bundle_path = trace_path.join("tinylib.min.js");
    std::fs::write(&bundle_path, TINYLIB_MIN_BODY).unwrap();
    let sha = compute_file_sha256(&bundle_path).unwrap();

    std::fs::write(
        cat_root.join("index.toml"),
        format!(
            r#"
            [[entry]]
            library = "tinylib"
            version = "1.0.0"
            file = "tinylib.min.js"
            sha256 = "{sha}"
            toml_path = "catalog/tinylib/1.0.0/tinylib.min.js.toml"
            provenance = "hand-curated"
            "#
        ),
    )
    .unwrap();

    (cat_dir, cat_root, trace_dir, trace_path, bundle_path)
}

/// Build a synthetic trace whose only step references the tinylib
/// bundle.  Mirrors the §P5 fixture shape so the Handler's
/// `path_entries_iter` returns the bundle's path on iteration.
fn build_trace_for_bundle(bundle_path: &Path) -> Arc<dyn TraceReader> {
    let events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(bundle_path.to_path_buf()),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "<top-level>".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
    ];
    let reader =
        CTFSTraceReader::from_events(events, bundle_path.parent().unwrap()).expect("from_events");
    Arc::new(reader)
}

/// §P8.3 — without `CT_CATALOG_AUTOLOAD`, the catalog match is logged
/// but NOT applied.  STRICT: assert no `renames.toml` is written AND
/// the trace's rename list is empty.
#[test]
fn catalog_autoload_off_default() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let orig_on = std::env::var("CT_CATALOG_AUTOLOAD").ok();
    let orig_off = std::env::var("CT_CATALOG_AUTOLOAD_DISABLED").ok();
    set_env("CT_CATALOG_AUTOLOAD", None);
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", None);
    assert!(!autoload_enabled());

    let (_cat_guard, cat_root, _trace_guard, trace_dir, bundle_path) =
        build_tinylib_fixture();
    let reader = build_trace_for_bundle(&bundle_path);

    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        reader,
        false,
    );
    handler.load_sourcemaps(&trace_dir);
    handler.load_catalog_autoload(&trace_dir, Some(&cat_root));

    // STRICT: rename list MUST be empty (no autoload application).
    assert!(
        !handler.sourcemap_cache.has_rename_list(),
        "without CT_CATALOG_AUTOLOAD, the catalog match must NOT install a rename list"
    );
    // STRICT: no renames.toml is written.
    assert!(
        !trace_dir.join("renames.toml").exists(),
        "without CT_CATALOG_AUTOLOAD, the trace dir must not have a renames.toml written"
    );

    set_env("CT_CATALOG_AUTOLOAD", orig_on.as_deref());
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", orig_off.as_deref());
}

/// §P8.3 — with `CT_CATALOG_AUTOLOAD=1`, the matching entry IS
/// applied.  STRICT: assert the trace's rename list contains the
/// cataloged renames.
#[test]
fn catalog_autoload_on_applies_matching_entry() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let orig_on = std::env::var("CT_CATALOG_AUTOLOAD").ok();
    let orig_off = std::env::var("CT_CATALOG_AUTOLOAD_DISABLED").ok();
    set_env("CT_CATALOG_AUTOLOAD", Some("1"));
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", None);
    assert!(autoload_enabled());

    let (_cat_guard, cat_root, _trace_guard, trace_dir, bundle_path) =
        build_tinylib_fixture();
    let reader = build_trace_for_bundle(&bundle_path);

    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        reader,
        false,
    );
    handler.load_sourcemaps(&trace_dir);
    handler.load_catalog_autoload(&trace_dir, Some(&cat_root));

    // STRICT: rename list MUST be installed.
    assert!(
        handler.sourcemap_cache.has_rename_list(),
        "with CT_CATALOG_AUTOLOAD=1, the catalog match MUST install a rename list"
    );
    // STRICT: the installed list MUST contain the cataloged renames.
    let resolved =
        handler.sourcemap_cache.resolve_name("tinylib.min.js", None, "a");
    assert_eq!(
        resolved.as_deref(),
        Some("add"),
        "the cataloged `a -> add` rename MUST be applied"
    );
    let resolved = handler
        .sourcemap_cache
        .resolve_name("tinylib.min.js", None, "d");
    assert_eq!(
        resolved.as_deref(),
        Some("double"),
        "the cataloged `d -> double` rename MUST be applied"
    );

    set_env("CT_CATALOG_AUTOLOAD", orig_on.as_deref());
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", orig_off.as_deref());
}

/// §P8.3 — even with `CT_CATALOG_AUTOLOAD=1`, a SHA mismatch prevents
/// application.
///
/// We exercise this by building a catalog whose index.toml claims a
/// SHA that doesn't match any recorded source — the scanner returns
/// `NoMatch` (the SHA-lookup misses).  The recorded source's rename
/// list stays empty.
#[test]
fn catalog_sha_mismatch_refuses_to_apply() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let orig_on = std::env::var("CT_CATALOG_AUTOLOAD").ok();
    set_env("CT_CATALOG_AUTOLOAD", Some("1"));
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", None);

    // Build the fixture correctly first ...
    let (_cat_guard, cat_root, _trace_guard, trace_dir, bundle_path) =
        build_tinylib_fixture();

    // ... then mutate the catalog's index.toml so the sha256 entry
    // doesn't match what the recording will actually contain.  We
    // overwrite the bundle file with new content so the recorded sha
    // diverges from the index.
    std::fs::write(
        &bundle_path,
        "function alpha(){return 'utterly different bundle';}\n",
    )
    .unwrap();
    let actual_sha = compute_file_sha256(&bundle_path).unwrap();
    assert_eq!(actual_sha.len(), 64, "sanity: actual sha is a real hex string");

    let reader = build_trace_for_bundle(&bundle_path);

    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        reader,
        false,
    );
    handler.load_sourcemaps(&trace_dir);
    handler.load_catalog_autoload(&trace_dir, Some(&cat_root));

    // STRICT: with the recorded sha diverging from the cataloged sha,
    // the autoload MUST NOT install a rename list.  This is the §P8.3
    // "refuses to apply" contract.
    assert!(
        !handler.sourcemap_cache.has_rename_list(),
        "sha mismatch between recorded source and catalog entry must prevent autoload"
    );

    set_env("CT_CATALOG_AUTOLOAD", orig_on.as_deref());
}

/// Defensive: the autoload module's library-level scanner returns the
/// per-path outcome the Handler relies on.  This documents the
/// contract for downstream consumers that want to bypass the Handler
/// and integrate the scanner directly.
#[test]
fn scan_single_path_surfaces_outcomes_for_library_consumers() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let orig = std::env::var("CT_CATALOG_AUTOLOAD").ok();
    set_env("CT_CATALOG_AUTOLOAD", None);
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", None);

    let (_cat_guard, cat_root, _trace_guard, _trace_dir, bundle_path) =
        build_tinylib_fixture();
    let outcome = scan_single_path(&bundle_path, &cat_root);
    assert!(matches!(outcome, AutoloadOutcome::MatchLogged { .. }));

    set_env("CT_CATALOG_AUTOLOAD", orig.as_deref());
}

/// Defensive: the install helper writes to `<recording-dir>/renames.toml`
/// without overwriting an existing file.  Used by `ct-mapping-tools
/// catalog install` and any future "apply this match permanently" GUI
/// action.
#[test]
fn install_to_recording_dir_round_trip() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let (_cat_guard, cat_root, _trace_guard, trace_dir, _bundle_path) =
        build_tinylib_fixture();
    let catalog = Catalog::load(&cat_root).unwrap();
    let entry = catalog.entries().first().unwrap().clone();
    let dst = install_to_recording_dir(&cat_root, &entry, &trace_dir).expect("install");
    assert!(dst.is_file());
    assert_eq!(dst.file_name().unwrap(), "renames.toml");
    let body = std::fs::read_to_string(&dst).unwrap();
    assert!(body.contains("to = \"add\""));
}

/// The Handler skips the catalog scan entirely when a sibling
/// `renames.toml` already exists — the explicit user list always wins.
#[test]
fn handler_skips_catalog_when_sibling_renames_exists() {
    let _g = env_lock().lock().unwrap_or_else(|p| p.into_inner());
    let orig = std::env::var("CT_CATALOG_AUTOLOAD").ok();
    set_env("CT_CATALOG_AUTOLOAD", Some("1"));
    set_env("CT_CATALOG_AUTOLOAD_DISABLED", None);

    let (_cat_guard, cat_root, _trace_guard, trace_dir, bundle_path) =
        build_tinylib_fixture();
    // Drop a sibling renames.toml that maps `a` to a DIFFERENT name
    // than the catalog does.  The sibling MUST win.
    std::fs::write(
        trace_dir.join("renames.toml"),
        r#"
            [[rename]]
            file = "tinylib.min.js"
            from = "a"
            to = "sibling_add"
        "#,
    )
    .unwrap();

    let reader = build_trace_for_bundle(&bundle_path);
    let mut handler = Handler::construct_with_reader(
        TraceKind::Materialized,
        RecreatorArgs::default(),
        reader,
        false,
    );
    handler.load_sourcemaps(&trace_dir);
    handler.load_rename_list(&trace_dir, None);
    handler.load_catalog_autoload(&trace_dir, Some(&cat_root));

    // The sibling's `a -> sibling_add` survives the catalog scan.
    assert_eq!(
        handler
            .sourcemap_cache
            .resolve_name("tinylib.min.js", None, "a")
            .as_deref(),
        Some("sibling_add"),
        "the sibling renames.toml MUST win over the catalog autoload"
    );

    set_env("CT_CATALOG_AUTOLOAD", orig.as_deref());
}
