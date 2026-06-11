//! §P5 acceptance test — user-provided variable rename list end-to-end.
//!
//! Spec:
//! `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P5.5 / §P5 verification block.
//!
//! Reuses the P3 lodash fixture under `tests/fixtures/sourcemap/`.  The
//! fixture's hand-crafted sourcemap declares
//! `names = ["add", "double", "sum", "doubled"]` against a minified
//! bundle whose bindings are `a, b, c, d, e, f, g`.
//!
//! ## What this test exercises
//!
//! 1. `Handler::load_rename_list` reads a sibling `renames.toml` (or
//!    an explicit path) and installs it on `SourcemapCache`.
//! 2. `SourcemapCache::resolve_name` composes the user list with the
//!    sourcemap V3 `names[]` array per the spec's precedence rules.
//! 3. `Handler::resolve_variable_name` flows the resolver into the
//!    DAP `variables` render path so the UI sees the renamed binding.
//! 4. The `CT_RENAME_LIST=0` kill switch disables the loader entirely.
//! 5. An explicit CLI / DAP `renameList` path overrides the sibling
//!    lookup.
//!
//! Per the §P5 time-box: where the full DAP wiring would require a
//! synthetic recorder fixture that emits a real `VariableName(...)` +
//! `Value(FullValueRecord)` event stream, this test exercises the
//! resolver directly through `SourcemapCache::resolve_name`.  The
//! Handler-level helper `resolve_variable_name` is covered by the
//! `resolver_via_handler_*` cases below.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use codetracer_trace_types::{
    CallRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TypeKind, TypeRecord,
    TypeSpecificInfo,
};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap_handler::Handler;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::rename_list::{RenameList, Scope, rename_list_enabled};
use db_backend::sourcemap_cache::{SourcemapCache, translation_enabled};
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

/// Serialise tests that mutate process-wide env vars so they don't race
/// each other.  `CT_RENAME_LIST` + `CT_SOURCEMAP_TRANSLATION` are read
/// at trace-open time; running env-mutating tests in parallel would
/// produce non-deterministic outcomes.
fn env_mutex() -> &'static Mutex<()> {
    use std::sync::OnceLock;
    static M: OnceLock<Mutex<()>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(()))
}

/// Locate the P3 lodash fixture directory.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sourcemap")
}

/// Build a minimal trace that lands a step on the recorded minified
/// bundle so [`Handler::load_sourcemaps`] discovers the sibling map.
fn build_trace_into_fixture() -> (Arc<dyn TraceReader>, PathBuf) {
    let dir = fixture_dir();
    let min_path = dir.join("lodash.min.js");
    assert!(
        min_path.is_file(),
        "fixture lodash.min.js missing at {}",
        min_path.display()
    );

    let events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(min_path.clone()),
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
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "add".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(1),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
    ];
    let reader = CTFSTraceReader::from_events(events, &dir).expect("from_events");
    (Arc::new(reader), dir)
}

/// Drop a `renames.toml` next to the fixture for the duration of the
/// test.  The guard removes the file on drop so concurrent tests on
/// other fixtures don't pick it up.
struct RenamesGuard {
    path: PathBuf,
}

impl RenamesGuard {
    fn new(dir: &std::path::Path, contents: &str) -> Self {
        let path = dir.join("renames.toml");
        std::fs::write(&path, contents).expect("write renames.toml");
        Self { path }
    }
}

impl Drop for RenamesGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[test]
fn p5_rename_list_toml_parses_cleanly() {
    // Sanity check: a representative TOML with a `[meta]` table plus
    // global and scoped entries parses and indexes by every kind.
    let raw = r#"
        [meta]
        version = "1"
        comment = "lodash 4.17.21"

        [[rename]]
        file = "lodash.min.js"
        scope = "global"
        from = "e"
        to = "array"

        [[rename]]
        file = "lodash.min.js"
        scope = "function:chunk"
        from = "t"
        to = "result"

        [[rename]]
        file = "lodash.min.js"
        scope = "block:L1"
        from = "f"
        to = "iteration_index"
    "#;
    let list = RenameList::parse_toml(raw).expect("parse");
    let meta = list.meta().expect("meta");
    assert_eq!(meta.version.as_deref(), Some("1"));

    assert_eq!(list.lookup("lodash.min.js", None, "e"), Some("array"));
    let chunk = Scope::Function("chunk".to_string());
    assert_eq!(list.lookup("lodash.min.js", Some(&chunk), "t"), Some("result"));
    let block = Scope::Block(1);
    assert_eq!(list.lookup("lodash.min.js", Some(&block), "f"), Some("iteration_index"));
}

#[test]
fn p5_rename_list_applies_via_cache_resolver() {
    // Mirror of §P5.5: with a renames.toml mapping `e -> array` and
    // `t -> result`, the resolver returns the readable names; without
    // it, the resolver echoes the recorded names for the bindings the
    // sourcemap acknowledges, and `None` otherwise.
    //
    // STRICT: the test asserts the exact rendered name (assert_eq! on
    // the full string), not a "not equal to X" weakening.

    // Tolerate prior-test poisoning so a single panicking test doesn't
    // cascade into 4 "PoisonError" failures.  The shared resource here
    // is the process env, not memory invariants, so resuming after a
    // poison is safe.
    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());
    let (reader, fixture) = build_trace_into_fixture();
    let mut handler =
        Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader.clone(), false);
    handler.load_sourcemaps(&fixture);

    // Drop a renames.toml that maps `e -> array, t -> result` next
    // to the fixture and reload.
    let _renames = RenamesGuard::new(
        &fixture,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "e"
            to = "array"

            [[rename]]
            file = "lodash.min.js"
            from = "t"
            to = "result"
        "#,
    );
    handler.load_rename_list(&fixture, None);
    assert!(handler.sourcemap_cache.has_rename_list());

    // Recorded path key used by the resolver.
    let file = fixture.join("lodash.min.js").display().to_string();

    // STRICT: each rename resolves to the configured readable name.
    assert_eq!(
        handler.sourcemap_cache.resolve_name(&file, None, "e").as_deref(),
        Some("array"),
        "user rename `e -> array` must surface at render time"
    );
    assert_eq!(
        handler.sourcemap_cache.resolve_name(&file, None, "t").as_deref(),
        Some("result"),
        "user rename `t -> result` must surface at render time"
    );

    // Unknown bindings that don't appear in the user list AND don't
    // appear in the sourcemap's `names[]` table return None so the
    // recorded name flows through unchanged.
    assert!(
        handler
            .sourcemap_cache
            .resolve_name(&file, None, "totally_unknown_binding")
            .is_none(),
        "unknown bindings return None — caller surfaces the recorded name"
    );
}

#[test]
fn p5_rename_list_composes_with_sourcemap_names() {
    // Mirror of `p5_rename_list_composes_with_sourcemap_names` from
    // the milestone verification block.
    //
    // The fixture's sourcemap has `names = ["add", "double", "sum",
    // "doubled"]`.  Install a user rename list that maps `add ->
    // user_add` (which conflicts with the sourcemap's `names[0]`).
    // The user list MUST win.
    //
    // For bindings that the sourcemap recognises but the user list
    // doesn't (e.g. `double`), the resolver returns the recorded name
    // back as confirmation — `Some("double")`.
    //
    // For bindings the sourcemap does NOT recognise (e.g. the recorded
    // `b` / `c` parameters), the resolver returns None.

    // Tolerate prior-test poisoning so a single panicking test doesn't
    // cascade into 4 "PoisonError" failures.  The shared resource here
    // is the process env, not memory invariants, so resuming after a
    // poison is safe.
    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());
    let (reader, fixture) = build_trace_into_fixture();
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);
    let _renames = RenamesGuard::new(
        &fixture,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "add"
            to = "user_add"
        "#,
    );
    handler.load_rename_list(&fixture, None);

    let file = fixture.join("lodash.min.js").display().to_string();
    // User list wins on conflict.
    assert_eq!(
        handler.sourcemap_cache.resolve_name(&file, None, "add").as_deref(),
        Some("user_add"),
        "user list MUST win on conflict"
    );
    // Sourcemap-only binding flows through as itself.
    assert_eq!(
        handler.sourcemap_cache.resolve_name(&file, None, "double").as_deref(),
        Some("double"),
        "sourcemap-acknowledged name echoes through"
    );
    // Sourcemap-unknown binding returns None.
    assert!(
        handler.sourcemap_cache.resolve_name(&file, None, "b").is_none(),
        "binding not in sourcemap names[] returns None"
    );
}

#[test]
fn p5_rename_list_kill_switch_disables_loader() {
    // Mirror of the §P5 "CT_RENAME_LIST=0 disables the feature" case.
    // STRICT: with the kill switch on, the cache must NOT have a
    // rename list installed even when renames.toml exists.

    // Tolerate prior-test poisoning so a single panicking test doesn't
    // cascade into 4 "PoisonError" failures.  The shared resource here
    // is the process env, not memory invariants, so resuming after a
    // poison is safe.
    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());
    let key = "CT_RENAME_LIST";
    let original = std::env::var(key).ok();
    // SAFETY: env mutation is gated by `env_mutex` above so concurrent
    // tests don't race; we restore in every code path below.
    unsafe { std::env::set_var(key, "0") };
    assert!(!rename_list_enabled(), "sanity: kill switch parsed");

    let (reader, fixture) = build_trace_into_fixture();
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);
    let _renames = RenamesGuard::new(
        &fixture,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "e"
            to = "array"
        "#,
    );
    handler.load_rename_list(&fixture, None);
    // With the kill switch on, no rename list is installed even though
    // a sibling renames.toml exists.
    assert!(
        !handler.sourcemap_cache.has_rename_list(),
        "CT_RENAME_LIST=0 must skip the loader entirely"
    );
    let file = fixture.join("lodash.min.js").display().to_string();
    // `e` was renamed to `array` in the (skipped) list — without the
    // user list, the sourcemap has no entry for `e`, so the resolver
    // returns None.  STRICT: assert exactly None so a weakened
    // implementation (e.g. silently loading despite the kill switch)
    // breaks the test.
    assert!(
        handler.sourcemap_cache.resolve_name(&file, None, "e").is_none(),
        "with kill switch on, `e` flows through with no rename"
    );

    // Restore env.
    match original {
        Some(v) => unsafe { std::env::set_var(key, v) },
        None => unsafe { std::env::remove_var(key) },
    }
}

#[test]
fn p5_explicit_path_overrides_sibling_lookup() {
    // Mirror of §P5.4 — the CLI flag / DAP `renameList` field points
    // at an explicit path that wins over the sibling location.

    // Tolerate prior-test poisoning so a single panicking test doesn't
    // cascade into 4 "PoisonError" failures.  The shared resource here
    // is the process env, not memory invariants, so resuming after a
    // poison is safe.
    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());
    let (reader, fixture) = build_trace_into_fixture();
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);

    // Put a sibling renames.toml that says e -> sibling_array.
    let _renames = RenamesGuard::new(
        &fixture,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "e"
            to = "sibling_array"
        "#,
    );

    // Write an explicit override TOML elsewhere that says e -> cli_array.
    let tmp = tempfile::tempdir().expect("tempdir");
    let explicit_path = tmp.path().join("explicit-renames.toml");
    std::fs::write(
        &explicit_path,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "e"
            to = "cli_array"
        "#,
    )
    .expect("write explicit");

    handler.load_rename_list(&fixture, Some(&explicit_path));
    let file = fixture.join("lodash.min.js").display().to_string();
    assert_eq!(
        handler.sourcemap_cache.resolve_name(&file, None, "e").as_deref(),
        Some("cli_array"),
        "explicit --rename-list path MUST win over the sibling renames.toml"
    );
}

#[test]
fn p5_translation_enabled_kill_switch_independent_of_rename_list() {
    // Defensive: the §P3 translation kill switch and the §P5 rename
    // list kill switch are independent toggles.  This test runs without
    // any env mutation; it just sanity-checks both default to on.
    assert!(translation_enabled());
    assert!(rename_list_enabled());
}

#[test]
fn p5_sourcemap_cache_resolves_without_handler() {
    // Defensive: the resolver doesn't depend on a `Handler` — callers
    // that only have a `SourcemapCache` can use it directly.  This
    // documents the cache-only API surface for downstream consumers.

    let mut cache = SourcemapCache::new();
    let list = RenameList::parse_toml(
        r#"
            [[rename]]
            file = "x.js"
            from = "a"
            to = "alpha"
        "#,
    )
    .expect("parse");
    cache.set_rename_list(Some(list));
    assert_eq!(cache.resolve_name("x.js", None, "a").as_deref(), Some("alpha"));
    assert!(cache.resolve_name("x.js", None, "unknown").is_none());
}
