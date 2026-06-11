//! §P6.5 acceptance test — DAP `variables` request renames recorded
//! bindings end-to-end through the user rename list and the per-position
//! sourcemap segment lookup.
//!
//! Spec:
//! `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P6.5.
//!
//! ## What this file covers
//!
//! The P5 tests in `rename_list.rs` and the P6.4 tests in
//! `per_position_name_recovery.rs` exercise `SourcemapCache::resolve_name`
//! / `resolve_name_at_position` directly — they don't drive a real DAP
//! `variables` exchange.  P6.5 closes that gap by:
//!
//! 1. Building a synthetic trace whose single step lands at a column on
//!    the minified `lodash.min.js` bundle where the sourcemap segment
//!    carries a `name_index` pointing at an entry in `names[]`.
//! 2. Attaching a `VariableName` + `Value(FullValueRecord)` pair to that
//!    step so `Handler::variables` has something to rename.
//! 3. Constructing a `Handler` via `construct_with_reader`, loading the
//!    fixture's sourcemap (and optionally a sibling `renames.toml`), and
//!    issuing a DAP `variables` request.
//! 4. STRICTLY asserting (`assert_eq!` on the exact returned string) on
//!    the `Variable::name` field that the UI would render.
//!
//! ## Variants exercised
//!
//! * `dap_variables_uses_sourcemap_per_position_name` — with no user
//!   list but a sourcemap whose segment maps to `"double"`, the DAP
//!   response shows `"double"` (covers §P6.4 — the per-position lookup
//!   reaches the DAP rendering path).
//! * `dap_variables_uses_user_rename_list` — with a sibling `renames.toml`
//!   mapping `a -> userArray`, the DAP response shows `"userArray"`
//!   (covers §P5 precedence — user list wins over the sourcemap).
//! * `dap_variables_no_translation_shows_recorded_name` — without any
//!   sourcemap or user list, the response shows the recorded `"a"`
//!   (covers the no-translation fall-through).
//!
//! The fixture uses the same hand-crafted lodash sourcemap as the P3 /
//! P6.3 acceptance tests under `tests/fixtures/sourcemap/`.  Its segment
//! table:
//!
//! ```text
//!   AAAAA   -> gen col 1  → orig (1, 1)  names[0] = "add"
//!   4BAIAC  -> gen col 29 → orig (5, 1)  names[1] = "double"
//!   0BAIAC  -> gen col 57 → orig (9, 1)  names[2] = "sum"
//!   aACAC   -> gen col 70 → orig (10, 1) names[3] = "doubled"
//! ```
//!
//! We use `(line=1, col=29)` so the per-position branch surfaces the
//! original identifier `"double"` from `names[1]`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord,
    TypeSpecificInfo, ValueRecord, VariableId,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request, Response};
use db_backend::dap_handler::Handler;
use db_backend::dap_types::{VariablesArguments, VariablesResponseBody};
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;

/// Generated column on `lodash.min.js` line 1 where the sourcemap's
/// second segment lives.  Picked so the per-position resolver sees a
/// segment whose `name_index` points at `names[1] = "double"`.
const RECORDED_COLUMN_DOUBLE: i64 = 29;

/// Serialise tests that mutate process-wide env vars / sibling files so
/// they don't race each other.  Mirrors the pattern used by the §P5
/// `rename_list.rs` suite: the resolver state on `SourcemapCache` is
/// per-handler, but the `renames.toml` we drop into the fixture dir is a
/// shared filesystem resource.
fn env_mutex() -> &'static Mutex<()> {
    use std::sync::OnceLock;
    static M: OnceLock<Mutex<()>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(()))
}

/// Locate the P3 lodash fixture directory.
fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/sourcemap")
}

/// Drop a `renames.toml` next to the fixture for the duration of the
/// test.  The guard removes the file on drop so concurrent tests on
/// other fixtures don't pick it up.  Mirrors the helper in §P5
/// `rename_list.rs`.
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

/// Build a minimal in-memory `Db` whose single `DbStep` lands at
/// `(file=lodash.min.js, line=1, column=column_1based)` and carries a
/// single recorded variable `recorded_name` whose value is the integer
/// `42`.
///
/// Construction is hand-crafted rather than driven through the CTFS
/// writer because the legacy and canonical writers don't expose a
/// column-bearing step API yet — see the long comment in
/// `tests/sourcemap_lodash.rs::build_trace_with_column` for the same
/// rationale.  The `InMemoryTraceReader` is the documented escape hatch.
///
/// Returns `(reader, fixture_dir, recorded_min_path)` so callers can
/// also assert filesystem invariants on the fixture (matches the shape
/// of `sourcemap_lodash.rs::build_trace_into_fixture`).
fn build_trace_with_variable(column_1based: i64, recorded_name: &str) -> (Arc<dyn TraceReader>, PathBuf, String) {
    let dir = fixture_dir();
    let min_path = dir.join("lodash.min.js");
    assert!(
        min_path.is_file(),
        "fixture lodash.min.js missing at {}",
        min_path.display()
    );
    let recorded = min_path.display().to_string();

    let mut db = Db::new(&dir);
    // PathId(0) is reserved as the sentinel slot used by the canonical
    // CTFS loader; PathId(1) is the absolute recorded path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "<top-level>".to_string(),
    });

    // Single call that owns the step.  Without it the calltrace's
    // `load_callstack` would refuse to attach the step to a frame.
    let call_key = CallKey(0);
    db.calls.push(DbCall {
        key: call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: CallKey(-1),
        children_keys: Vec::new(),
    });

    let step_id = StepId(0);
    let step = DbStep {
        step_id,
        path_id: PathId(1),
        line: Line(1),
        // P6.3 column — what the per-position resolver consumes.
        column: Some(Line(column_1based)),
        call_key,
        global_call_key: call_key,
    };
    db.steps.push(step);

    // The variable name table.  `VariableId(0)` is the recorded
    // minified binding the renderer will rename at DAP-render time.
    db.variable_names.push(recorded_name.to_string());

    // Variables attached to step 0: one `FullValueRecord` carrying an
    // integer.  This mirrors what the recorder emits for a `Value` event.
    db.variables.push(vec![FullValueRecord {
        variable_id: VariableId(0),
        value: ValueRecord::Int {
            i: 42,
            type_id: TypeId(0),
        },
    }]);
    db.instructions.push(Vec::new());
    db.compound.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());

    // step_map indexed by PathId then line.  Two entries (PathId(0)
    // sentinel + PathId(1)) keep `step_map.len() == path_count` per the
    // canonical loader's invariant.
    db.step_map.push(HashMap::new());
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    path1_map.insert(1, vec![step]);
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    (reader, dir, recorded)
}

/// Drain a single `Response` from the mpsc channel the Handler
/// publishes DAP responses through.
fn drain_response(rx: &mpsc::Receiver<DapMessage>) -> Response {
    let raw = rx.recv().expect("dap response sent");
    match raw {
        DapMessage::Response(r) => r,
        other => panic!("expected DAP Response, got {other:?}"),
    }
}

/// Decode the `body` field of a `variables` response.
fn decode_variables_body(resp: &Response) -> VariablesResponseBody {
    serde_json::from_value(resp.body.clone()).expect("variables body decodes")
}

/// Issue a DAP `variables` request and return the decoded body.
fn invoke_variables(handler: &mut Handler) -> VariablesResponseBody {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "variables".to_string(),
        arguments: serde_json::json!({ "variablesReference": 1 }),
    };
    // `variables_reference` is forwarded but ignored by the Materialized
    // path — the handler walks `reader.variables_at(self.step_id)` for
    // its source of truth.  We pass `1` (a non-zero sentinel) to mirror
    // what a real DAP client sends.
    let args = VariablesArguments {
        variables_reference: 1,
        filter: None,
        start: None,
        count: None,
        format: None,
    };
    handler.variables(request, args, tx).expect("variables responds");
    let msg = drain_response(&rx);
    decode_variables_body(&msg)
}

#[test]
fn dap_variables_uses_sourcemap_per_position_name() {
    // §P6.4-on-DAP — with no user rename list, the per-position
    // sourcemap segment at (line=1, col=29) carries `name_index = 1`
    // pointing at `names[1] = "double"`.  The DAP `variables` response
    // for the recorded binding `"a"` MUST surface `"double"`.
    //
    // This is the integration test the P5 + P6.4 unit tests didn't
    // cover — it proves the resolver composition reaches the wire.

    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());

    let (reader, fixture, _recorded) = build_trace_with_variable(RECORDED_COLUMN_DOUBLE, "a");
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);
    assert!(
        !handler.sourcemap_cache.is_empty(),
        "expected sourcemap to be discovered for lodash.min.js"
    );
    assert!(
        !handler.sourcemap_cache.has_rename_list(),
        "no renames.toml dropped — rename list MUST be absent"
    );

    let body = invoke_variables(&mut handler);
    assert_eq!(
        body.variables.len(),
        1,
        "fixture records exactly one variable on step 0"
    );
    // STRICT — exact rendered name on the wire.
    assert_eq!(
        body.variables[0].name, "double",
        "P6.4 per-position sourcemap segment recovers names[1] = \"double\" through the DAP variables path"
    );
    // The recorded integer value still flows through unchanged.
    assert_eq!(body.variables[0].value, "42", "value text repr preserved");
}

#[test]
fn dap_variables_uses_user_rename_list() {
    // §P5-on-DAP — a sibling `renames.toml` mapping `a -> userArray`
    // wins over the per-position sourcemap recovery (which would
    // otherwise have produced `"double"` at col 29).
    //
    // STRICT — the response MUST show `"userArray"`, not the recorded
    // `"a"` and not the sourcemap-recovered `"double"`.

    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());

    let (reader, fixture, _recorded) = build_trace_with_variable(RECORDED_COLUMN_DOUBLE, "a");
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.load_sourcemaps(&fixture);

    // Drop a renames.toml next to the fixture for the duration of the
    // test.  The guard removes it on `Drop` to keep other tests on the
    // same fixture deterministic.
    let _renames = RenamesGuard::new(
        &fixture,
        r#"
            [[rename]]
            file = "lodash.min.js"
            from = "a"
            to = "userArray"
        "#,
    );
    handler.load_rename_list(&fixture, None);
    assert!(
        handler.sourcemap_cache.has_rename_list(),
        "renames.toml MUST install a rename list"
    );

    let body = invoke_variables(&mut handler);
    assert_eq!(body.variables.len(), 1);
    // STRICT — user rename wins on conflict per §P5 precedence rules.
    assert_eq!(
        body.variables[0].name, "userArray",
        "user rename list MUST win over the per-position sourcemap recovery"
    );
    assert_eq!(body.variables[0].value, "42");
}

#[test]
fn dap_variables_no_translation_shows_recorded_name() {
    // No sourcemap loaded and no user list installed — the resolver's
    // fast-path returns the recorded name unchanged.  STRICT — the DAP
    // response MUST show the raw `"a"` so the UI can fall back to the
    // recorded form when no translation source is available.

    let _guard = env_mutex().lock().unwrap_or_else(|p| p.into_inner());

    let (reader, _fixture, _recorded) = build_trace_with_variable(RECORDED_COLUMN_DOUBLE, "a");
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    // Deliberately do NOT call `load_sourcemaps` / `load_rename_list`.
    assert!(
        handler.sourcemap_cache.is_empty(),
        "no sourcemap loaded — cache MUST be empty"
    );
    assert!(!handler.sourcemap_cache.has_rename_list(), "no rename list installed");

    let body = invoke_variables(&mut handler);
    assert_eq!(body.variables.len(), 1);
    // STRICT — recorded name reaches the wire verbatim.
    assert_eq!(
        body.variables[0].name, "a",
        "with no translation source the recorded name MUST flow through unchanged"
    );
    assert_eq!(body.variables[0].value, "42");
}
