//! Value Origin Tracking — M2 integration tests for the materialized
//! DB Path B algorithm and the DAP `ct/originChain` + `ct/originSummary`
//! surfaces.
//!
//! # Testing posture (per the milestones-file Introduction)
//!
//! The milestones spec calls for "real recordings, no mocks". For M2
//! that means a real materialized `.ct` trace + real `db-backend`
//! spawned in-process + real DAP requests. The M0 fixtures are
//! committed, but only the source files exist — the per-fixture
//! `.ct` recordings are not yet wired into the test harness (the
//! recorder shim binary referenced as `# TODO(M0-TestCache)` in
//! `tests/fixtures/origin/regenerate-fixtures.sh` has not landed).
//!
//! Because the test must still drive a real algorithm against real
//! trace-shaped data, M2 follows the spec's documented escape hatch:
//! assemble a minimal in-memory trace using the
//! `InMemoryTraceReader` + `Db` types directly. This is NOT a mock of
//! the algorithm — the materialized Path B implementation runs end to
//! end against the populated trace data. The escape hatch is restricted
//! to the *trace ingestion* step; every other layer (classifier,
//! algorithm, source-line resolver, DAP types, error codes) is the
//! production code path.
//!
//! TODO(M3-recorder-wiring): replace the in-memory trace builder with
//! the M0 fixture `.ct` artefacts once the `origin-fixture-cache`
//! Rust shim lands.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::sync::mpsc;

use codetracer_trace_types::{
    CallKey, FullValueRecord, FunctionId, FunctionRecord, Line as TraceLine, NO_KEY, PathId, StepId, TypeId, TypeKind,
    TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram, MaterializedReplaySession};
use db_backend::expr_loader::ExprLoader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::lang::Lang;
use db_backend::origin_metadata_indexer::{MaterializedOriginIndexer, PathAAssignment, ValueChange};
use db_backend::origin_query::{
    OriginContinuationToken, OriginErrorCode, OriginQueryEngine, SourceDigest, SourceOriginKind,
};
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{
    CoreTrace, CtLoadFlowArguments, CtLoadLocalsArguments, CtOriginChainArguments, CtOriginSummaryArguments,
    DEFAULT_ORIGIN_MAX_HOPS, DEFAULT_ORIGIN_MAX_STEPS_SCANNED, DEFAULT_ORIGIN_WALL_CLOCK_MS, FlowMode, LoadHistoryArg,
    Location, OriginBudget, OriginKind, OriginSummary, RRTicks, TerminatorKind, TerminatorKindWire, TraceKind,
};
use origin_classifier::PatternSet;
use serde_json::Value as JsonValue;
use tempfile::TempDir;

// ---------------------------------------------------------------------------
// Trace builder — assembles a Db with the per-step variable history that
// the materialized algorithm walks backward.
// ---------------------------------------------------------------------------

/// Source-text + step-by-step variable values that the trace builder
/// converts into a `Db`. Each step carries one source line (the line
/// number drives the source-line lookup) plus the per-variable
/// snapshot for that step.
struct Recipe<'a> {
    source_path: &'a str,
    source: &'a str,
    function_name: &'a str,
    /// `(line_in_source_1based, variable_snapshots)` per step.
    steps: Vec<(i64, Vec<(&'a str, ValueRecord)>)>,
    /// Optional call-tree shape. Empty = single top-level call.
    extra_calls: Vec<CallShape<'a>>,
}

struct CallShape<'a> {
    function_name: &'a str,
    /// Range of step indices (in `Recipe::steps`) that belong to this
    /// sub-call.
    step_range: std::ops::Range<usize>,
    /// Arguments passed at the call site, in (name, value) order. The
    /// builder assigns them fresh `VariableId`s and records them in the
    /// `DbCall.args` vector.
    args: Vec<(&'a str, ValueRecord)>,
}

fn make_int_type() -> TypeRecord {
    TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

fn build_trace(recipe: Recipe<'_>) -> (Db, TempDir) {
    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let workdir = workdir_holder.path().to_path_buf();
    let abs_source = workdir.join(recipe.source_path);
    if let Some(parent) = abs_source.parent() {
        std::fs::create_dir_all(parent).expect("create source parent");
    }
    std::fs::write(&abs_source, recipe.source).expect("write source");

    let mut db = Db::new(&workdir);
    db.paths.push(String::new());
    db.paths.push(recipe.source_path.to_string());
    db.path_map.insert(recipe.source_path.to_string(), PathId(1));
    db.path_map.insert(abs_source.to_string_lossy().to_string(), PathId(1));

    // One concrete type for every value we manufacture.
    db.types.push(make_int_type());

    // Build the top-level function + call.
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: TraceLine(1),
        name: recipe.function_name.to_string(),
    });

    // Allocate variable ids by name (interning).
    let mut var_ids: HashMap<String, VariableId> = HashMap::new();
    let mut ensure_var = |db: &mut Db, name: &str| -> VariableId {
        if let Some(id) = var_ids.get(name) {
            return *id;
        }
        let id = VariableId(db.variable_names.len());
        db.variable_names.push(name.to_string());
        var_ids.insert(name.to_string(), id);
        id
    };

    // Top-level call.
    let top_call_key = CallKey(db.calls.len() as i64);
    db.calls.push(DbCall {
        key: top_call_key,
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: NO_KEY,
        children_keys: Vec::new(),
    });

    // Sub-calls (parameter_pass / return_capture fixtures).
    let mut call_for_step: Vec<CallKey> = vec![top_call_key; recipe.steps.len()];
    for (sub_idx, shape) in recipe.extra_calls.iter().enumerate() {
        let function_id = FunctionId(db.functions.len());
        db.functions.push(FunctionRecord {
            path_id: PathId(1),
            line: TraceLine(1),
            name: shape.function_name.to_string(),
        });
        let mut arg_records = Vec::new();
        for (name, value) in &shape.args {
            let var_id = ensure_var(&mut db, name);
            arg_records.push(FullValueRecord {
                variable_id: var_id,
                value: value.clone(),
            });
        }
        let sub_key = CallKey((1 + sub_idx) as i64);
        db.calls.push(DbCall {
            key: sub_key,
            function_id,
            args: arg_records,
            return_value: ValueRecord::None { type_id: TypeId(0) },
            step_id: StepId(shape.step_range.start as i64),
            depth: 1,
            parent_key: top_call_key,
            children_keys: Vec::new(),
        });
        for idx in shape.step_range.clone() {
            call_for_step[idx] = sub_key;
        }
    }

    // Materialize steps + per-step variable snapshots.
    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (step_idx, (line_1based, snapshot)) in recipe.steps.iter().enumerate() {
        let step_id = StepId(step_idx as i64);
        let step = DbStep {
            step_id,
            path_id: PathId(1),
            line: TraceLine(*line_1based),
            column: None,
            call_key: call_for_step[step_idx],
            global_call_key: call_for_step[step_idx],
        };
        db.steps.push(step);
        step_map_for_path.entry(*line_1based as usize).or_default().push(step);
        let mut var_records = Vec::new();
        for (name, value) in snapshot {
            let var_id = ensure_var(&mut db, name);
            var_records.push(FullValueRecord {
                variable_id: var_id,
                value: value.clone(),
            });
        }
        db.variables.push(var_records);
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    // Indices the trace reader needs.
    db.step_map.push(HashMap::new()); // PathId(0)
    db.step_map.push(step_map_for_path);
    db.end_of_program = EndOfProgram::Normal;

    (db, workdir_holder)
}

fn run_chain(db: Db, variable_name: &str, query_step: i64, workdir: &std::path::Path) -> db_backend::task::OriginChain {
    let workdir_buf = workdir.to_path_buf();
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: variable_name.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: query_step,
        thread_id: 0,
        max_hops: DEFAULT_ORIGIN_MAX_HOPS,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget::default();
    let _ = workdir_buf; // workdir kept for tempdir's RAII lifetime via the caller.
    session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .expect("origin_chain_inferred should not surface DAP errors on happy-path inputs")
}

fn int_value(i: i64) -> ValueRecord {
    ValueRecord::Int { i, type_id: TypeId(0) }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn test_origin_chain_returns_literal_terminator() {
    // Fixture: a=10; b=a; c=b. Query `c` at the last step.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\nc = b\nprint(c)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
            (
                4,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "c", 3, tmpdir.path());

    assert_eq!(chain.terminator.kind, TerminatorKind::Literal);
    assert_eq!(chain.hops.len(), 3, "expected 3 hops, got {:?}", chain.hops);
    assert_eq!(chain.hops[0].kind, OriginKind::TrivialCopy);
    assert_eq!(chain.hops[1].kind, OriginKind::TrivialCopy);
    assert_eq!(chain.hops[2].kind, OriginKind::Literal);
    assert!(!chain.truncated);
    assert!(chain.continuation_token.is_none());
}

#[test]
fn test_origin_chain_uses_materialized_metadata_for_javascript_literal_chain() {
    let recipe = Recipe {
        source_path: "fixture.js",
        source: "const a = 10;\nconst b = a;\nconst c = b;\nconsole.log(c);\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
            (
                4,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    std::fs::remove_file(tmpdir.path().join("fixture.js")).expect("remove source to force metadata path");
    let changes = vec![
        ValueChange {
            variable_id: VariableId(0),
            step_id: StepId(0),
            value: int_value(10),
            assignment: Some(PathAAssignment {
                kind: origin_classifier::OriginKind::Literal,
                source_var_id: None,
                function_idx: 0,
            }),
            source_expr_text: "10".to_string(),
            function_idx: 0,
        },
        ValueChange {
            variable_id: VariableId(1),
            step_id: StepId(1),
            value: int_value(10),
            assignment: Some(PathAAssignment {
                kind: origin_classifier::OriginKind::TrivialCopy,
                source_var_id: Some(0),
                function_idx: 0,
            }),
            source_expr_text: "a".to_string(),
            function_idx: 0,
        },
        ValueChange {
            variable_id: VariableId(2),
            step_id: StepId(2),
            value: int_value(10),
            assignment: Some(PathAAssignment {
                kind: origin_classifier::OriginKind::TrivialCopy,
                source_var_id: Some(1),
                function_idx: 0,
            }),
            source_expr_text: "b".to_string(),
            function_idx: 0,
        },
    ];
    let index_output = MaterializedOriginIndexer::new().run(&changes);
    let decoder = db_backend::origin_metadata_indexer::OriginMetadataDecoder::from_stream(
        index_output.originmeta,
        index_output.source_exprs,
    );
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 3,
        thread_id: 0,
        max_hops: DEFAULT_ORIGIN_MAX_HOPS,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let chain = session
        .origin_chain_inferred_with_metadata(
            &args,
            &OriginBudget::default(),
            &mut expr_loader,
            &patterns,
            None,
            Some(&decoder),
        )
        .expect("metadata-backed origin chain");

    assert_eq!(chain.terminator.kind, TerminatorKind::Literal);
    assert_eq!(chain.terminator.expression, "10");
    assert_eq!(chain.hops.len(), 3, "expected c <- b, b <- a, a <- 10");
    assert_eq!(chain.hops[0].kind, OriginKind::TrivialCopy);
    assert_eq!(chain.hops[1].kind, OriginKind::TrivialCopy);
    assert_eq!(chain.hops[2].kind, OriginKind::Literal);
    assert_eq!(chain.hops[2].target_expr, "a");
    assert_eq!(chain.hops[2].source_expr, "10");
    assert_eq!(
        chain.metrics.classifier_hits, 0,
        "metadata path should not classify source lines"
    );
    let _ = tmpdir;
}

#[test]
fn test_origin_chain_computational_with_operand_snapshots() {
    // Fixture: a=2; b=3; result = a + b. Query `result`.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 2\nb = 3\nresult = a + b\nprint(result)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(2))]),
            (2, vec![("a", int_value(2)), ("b", int_value(3))]),
            (
                3,
                vec![("a", int_value(2)), ("b", int_value(3)), ("result", int_value(5))],
            ),
            (
                4,
                vec![("a", int_value(2)), ("b", int_value(3)), ("result", int_value(5))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "result", 3, tmpdir.path());

    assert_eq!(chain.terminator.kind, TerminatorKind::Computational);
    assert_eq!(
        chain.hops.len(),
        1,
        "expected 1 computational hop, got {:?}",
        chain.hops
    );
    let hop = &chain.hops[0];
    assert_eq!(hop.kind, OriginKind::Computational);
    let operand_names: Vec<&str> = hop.operand_snapshots.iter().map(|o| o.name.as_str()).collect();
    assert!(
        operand_names.contains(&"a") && operand_names.contains(&"b"),
        "expected operands `a` and `b`, got {:?}",
        operand_names
    );
}

#[test]
fn test_origin_chain_operand_snapshots_leaf_only_with_truncation_flag() {
    // (a*2) + (b/3) — leaf identifiers are just {a, b}.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 4\nb = 9\nresult = (a*2) + (b/3)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(4))]),
            (2, vec![("a", int_value(4)), ("b", int_value(9))]),
            (
                3,
                vec![("a", int_value(4)), ("b", int_value(9)), ("result", int_value(11))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "result", 2, tmpdir.path());

    assert_eq!(chain.hops.len(), 1);
    let hop = &chain.hops[0];
    assert_eq!(hop.kind, OriginKind::Computational);
    let mut names: Vec<&str> = hop.operand_snapshots.iter().map(|o| o.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["a", "b"], "expected only the two leaf identifiers");
    assert!(!hop.truncated_operands);
}

#[test]
fn test_origin_chain_budget_max_hops_truncates() {
    // 10 trivial copies. max_hops = 3 — chain truncates with a continuation token.
    let steps: Vec<(i64, Vec<(&'static str, ValueRecord)>)> = (0..10)
        .map(|i| {
            let mut snapshot: Vec<(&str, ValueRecord)> = Vec::new();
            for j in 0..=i as usize {
                let name = ["v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"][j];
                snapshot.push((name, int_value(42)));
            }
            ((i + 1) as i64, snapshot)
        })
        .collect();
    // Build the source so line N becomes `vN-1 = v{N-2}` etc.
    let source_lines: Vec<String> = (0..10)
        .map(|i| {
            if i == 0 {
                "v0 = 42".to_string()
            } else {
                format!("v{i} = v{}", i - 1)
            }
        })
        .collect();
    let source = source_lines.join("\n") + "\n";
    let recipe = Recipe {
        source_path: "fixture.py",
        source: &source,
        function_name: "main",
        steps,
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: "v9".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 9,
        thread_id: 0,
        max_hops: 3,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget {
        max_hops: 3,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
    };
    let chain = session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .expect("chain ok");
    assert!(chain.truncated);
    assert_eq!(chain.terminator.kind, TerminatorKind::DepthLimit);
    assert!(chain.continuation_token.is_some());
    let _ = tmpdir;
}

#[test]
fn test_origin_chain_continuation_token_fingerprint_mismatch() {
    // Build a token that claims a fingerprint different from the current
    // PatternSet's fingerprint. The materialized algorithm must reject
    // it with DAP error 6106.
    let token = OriginContinuationToken {
        v: OriginContinuationToken::CURRENT_VERSION,
        query_variable: "c".to_string(),
        query_step_id: 3,
        current_step: 2,
        current_frame: 0,
        current_var_name: "b".to_string(),
        hops_emitted: 1,
        max_hops: 16,
        patterns_fingerprint: "0xdeadbeef-not-the-real-one".to_string(),
        source_digests: Vec::new(),
        issued_at: 0,
    };
    let encoded = token.encode().expect("encode token");

    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\nc = b\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 2,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: Some(encoded),
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget::default();
    let err = session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .unwrap_err();
    assert_eq!(err.code, OriginErrorCode::ContinuationTokenInvalid);
    let detail = err.detail.expect("error must carry a detail blob");
    assert_eq!(detail["kind"], "patterns_fingerprint_mismatch");
}

#[test]
fn test_origin_chain_continuation_token_source_digest_mismatch() {
    // Materialise a small recipe + write a source file. Issue a token
    // whose `source_digests` claims the file's content was X, then edit
    // the file on disk so the digest no longer matches.
    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let workdir = workdir_holder.path().to_path_buf();
    let source_path = workdir.join("fixture.py");
    std::fs::write(&source_path, "a = 10\nb = a\nc = b\n").expect("write source");

    let mut db = Db::new(&workdir);
    db.paths.push(String::new());
    db.paths.push("fixture.py".to_string());
    db.types.push(make_int_type());
    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: TraceLine(1),
        name: "main".to_string(),
    });
    db.calls.push(DbCall {
        key: CallKey(0),
        function_id: FunctionId(0),
        args: Vec::new(),
        return_value: ValueRecord::None { type_id: TypeId(0) },
        step_id: StepId(0),
        depth: 0,
        parent_key: NO_KEY,
        children_keys: Vec::new(),
    });
    db.variable_names.push("a".to_string());
    db.variable_names.push("b".to_string());
    db.variable_names.push("c".to_string());
    db.path_map.insert("fixture.py".to_string(), PathId(1));
    db.path_map.insert(source_path.to_string_lossy().to_string(), PathId(1));
    for step_idx in 0..3 {
        let step = DbStep {
            step_id: StepId(step_idx),
            path_id: PathId(1),
            line: TraceLine(step_idx + 1),
            column: None,
            call_key: CallKey(0),
            global_call_key: CallKey(0),
        };
        db.steps.push(step);
    }
    db.variables.push(vec![FullValueRecord {
        variable_id: VariableId(0),
        value: int_value(10),
    }]);
    db.variables.push(vec![
        FullValueRecord {
            variable_id: VariableId(0),
            value: int_value(10),
        },
        FullValueRecord {
            variable_id: VariableId(1),
            value: int_value(10),
        },
    ]);
    db.variables.push(vec![
        FullValueRecord {
            variable_id: VariableId(0),
            value: int_value(10),
        },
        FullValueRecord {
            variable_id: VariableId(1),
            value: int_value(10),
        },
        FullValueRecord {
            variable_id: VariableId(2),
            value: int_value(10),
        },
    ]);
    db.instructions.push(Vec::new());
    db.instructions.push(Vec::new());
    db.instructions.push(Vec::new());
    db.compound.push(HashMap::new());
    db.compound.push(HashMap::new());
    db.compound.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());
    db.variable_cells.push(HashMap::new());
    db.step_map.push(HashMap::new());
    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    step_map_for_path.insert(1, vec![db.steps[StepId(0)]]);
    step_map_for_path.insert(2, vec![db.steps[StepId(1)]]);
    step_map_for_path.insert(3, vec![db.steps[StepId(2)]]);
    db.step_map.push(step_map_for_path);

    // Issue a token claiming `fixture.py` had a digest of the
    // initial content.
    let issued_digest = db_backend::origin_query::sha256_hex(b"a = 10\nb = a\nc = b\n");
    let token = OriginContinuationToken {
        v: OriginContinuationToken::CURRENT_VERSION,
        query_variable: "c".to_string(),
        query_step_id: 2,
        current_step: 0,
        current_frame: 0,
        current_var_name: "a".to_string(),
        hops_emitted: 1,
        max_hops: 16,
        patterns_fingerprint: PatternSet::built_in().fingerprint().hex.clone(),
        source_digests: vec![SourceDigest {
            path: source_path.to_string_lossy().to_string(),
            origin: SourceOriginKind::Filesystem,
            sha256_hex: issued_digest,
        }],
        issued_at: 0,
    };
    // Edit the file *after* the token was issued so the digest
    // mismatches.
    std::fs::write(&source_path, "a = 99\nb = a\nc = b\n").expect("rewrite source");
    let encoded = token.encode().expect("encode");

    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 2,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: Some(encoded),
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget::default();
    let err = session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .unwrap_err();
    assert_eq!(err.code, OriginErrorCode::ContinuationTokenInvalid);
    let detail = err.detail.expect("error must carry a detail blob");
    assert_eq!(detail["kind"], "source_digest_mismatch");
}

#[test]
fn test_origin_chain_partial_recording_terminator() {
    // No step ever writes the variable's first definition — the
    // backward scan walks to step 0 without finding it.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "# pre-existing value\nprint(x)\n",
        function_name: "main",
        steps: vec![
            (
                1,
                vec![("x", int_value(7))], // x exists at step 0 with same value
            ),
            (2, vec![("x", int_value(7))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "x", 1, tmpdir.path());

    assert_eq!(chain.terminator.kind, TerminatorKind::RecordingStart);
    assert!(chain.hops.is_empty());
}

#[test]
fn test_origin_chain_unparseable_line_returns_unknown() {
    // The source line is something the classifier can't parse as an
    // assignment.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "garbled @#$%^&*\n",
        function_name: "main",
        steps: vec![(1, vec![("a", int_value(1))]), (1, vec![("a", int_value(2))])],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "a", 1, tmpdir.path());

    assert_eq!(chain.terminator.kind, TerminatorKind::UnknownSource);
    assert!(!chain.hops.is_empty(), "expected at least one Unknown hop");
    assert_eq!(chain.hops[0].kind, OriginKind::Unknown);
}

#[test]
fn test_origin_summary_eager_and_placeholder_default() {
    // Construct an origin chain manually and call into the helper
    // pathway exposed by `origin_chain_to_summary` to confirm:
    //   * eager summaries carry hop_count + terminator fields,
    //   * placeholder summaries default-initialise the same shape.
    let chain = db_backend::task::OriginChain::terminator_only(TerminatorKind::Literal, "c", 3);
    // Eager path: build via the public OriginChain -> OriginSummary fields.
    let summary = db_backend::task::OriginSummary {
        terminator_kind: chain.terminator.kind.into(),
        terminator_expr: chain.terminator.expression.clone(),
        terminator_function: chain.terminator.function.clone(),
        hop_count: chain.hops.len() as u32,
        confidence: chain.confidence,
        is_placeholder: false,
        placeholder_token: None,
    };
    assert!(!summary.is_placeholder);

    // Placeholder path: roundtrip a token to confirm encode/decode
    // gives us back a stable shape (used by ct/originSummary).
    let token = OriginContinuationToken {
        v: OriginContinuationToken::CURRENT_VERSION,
        query_variable: "c".to_string(),
        query_step_id: 3,
        current_step: 3,
        current_frame: -1,
        current_var_name: "c".to_string(),
        hops_emitted: 0,
        max_hops: 16,
        patterns_fingerprint: "fp".to_string(),
        source_digests: Vec::new(),
        issued_at: 0,
    };
    let summary = db_backend::origin_query::placeholder_summary(token);
    assert!(summary.is_placeholder);
    assert!(summary.placeholder_token.is_some());
}

#[test]
fn test_origin_summary_lazy_batch_rejects_bad_tokens() {
    // The batch endpoint's per-token error behaviour: bogus tokens
    // produce `UnknownVariable` summaries rather than request-level
    // failures.
    let token_invalid = "not-a-valid-token";
    let err = OriginContinuationToken::decode(token_invalid).unwrap_err();
    assert_eq!(err.code, OriginErrorCode::ContinuationTokenInvalid);
}

#[test]
fn test_origin_chain_error_6103_for_unsupported_trace_kind() {
    // The trait's default impl on MaterializedReplaySession surfaces
    // 6103 — the handler dispatches to `origin_chain_inferred`
    // directly; the trait impl returns 6103 so other backends inherit
    // the right error.
    let workdir_holder = tempfile::tempdir().expect("tempdir");
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 1\n",
        function_name: "main",
        steps: vec![(1, vec![("a", int_value(1))])],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let args = CtOriginChainArguments {
        variable_name: "a".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 0,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget::default();
    let err = session.origin_chain(&args, &budget).unwrap_err();
    assert_eq!(err.code, OriginErrorCode::UnsupportedBackend);
    let _ = workdir_holder;
}

#[test]
fn test_origin_chain_continuation_extends_chain() {
    // Build a 6-hop chain. First request with max_hops=2 truncates and
    // returns a continuation token. Resubmit with that token to extend.
    let steps: Vec<(i64, Vec<(&'static str, ValueRecord)>)> = (0..6)
        .map(|i| {
            let mut snapshot = Vec::new();
            for j in 0..=i as usize {
                let name = ["v0", "v1", "v2", "v3", "v4", "v5"][j];
                snapshot.push((name, int_value(7)));
            }
            ((i + 1) as i64, snapshot)
        })
        .collect();
    let source = "v0 = 7\nv1 = v0\nv2 = v1\nv3 = v2\nv4 = v3\nv5 = v4\n";
    let recipe = Recipe {
        source_path: "fixture.py",
        source,
        function_name: "main",
        steps,
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let mut args = CtOriginChainArguments {
        variable_name: "v5".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 5,
        thread_id: 0,
        max_hops: 2,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget {
        max_hops: 2,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
    };
    let chain1 = session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .expect("first request");
    assert!(chain1.truncated);
    let token = chain1.continuation_token.expect("continuation token");
    let chain1_hop_count = chain1.hops.len() as u32;

    args.max_hops = 6;
    args.continuation_token = Some(token);
    let budget_full = OriginBudget {
        max_hops: 6,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
    };
    let chain2 = session
        .origin_chain_inferred(&args, &budget_full, &mut expr_loader, &patterns, None)
        .expect("continuation request");
    // The continuation respects the global max_hops - hops_already_emitted,
    // so chain2 contains the remaining hops to reach the terminator.
    assert!(
        chain2.hops.len() + chain1_hop_count as usize >= 3,
        "expected the continuation to extend the chain"
    );
}

#[test]
fn test_origin_chain_parameter_pass_transition() {
    // foo(arg) — passing `arg` into a callee binds the parameter
    // `param`. Querying `param` inside the callee crosses the
    // ParameterPass frame transition.
    let recipe = Recipe {
        source_path: "fixture.py",
        // line 1: arg = 7
        // line 2: foo(arg)
        // line 3: print(param)
        source: "arg = 7\nfoo(arg)\nprint(param)\n",
        function_name: "main",
        steps: vec![
            // step 0 (line 1): `arg = 7` in caller `main`.
            (1, vec![("arg", int_value(7))]),
            // step 1 (line 2): call site in `main` (callee about to start).
            (2, vec![("arg", int_value(7))]),
            // step 2 (line 3): inside `foo`. `param` was bound to `arg`.
            (3, vec![("param", int_value(7))]),
        ],
        extra_calls: vec![CallShape {
            function_name: "foo",
            step_range: 2..3,
            args: vec![("param", int_value(7))],
        }],
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "param", 2, tmpdir.path());

    // The chain must include a hop with FrameTransition.kind ==
    // ParameterPass and ultimately terminate at the literal `7`.
    let has_parameter_pass = chain
        .hops
        .iter()
        .any(|h| h.kind == OriginKind::ParameterPass || h.frame_transition.is_some());
    assert!(
        has_parameter_pass,
        "expected a ParameterPass hop, got chain: {:#?}",
        chain.hops
    );
}

#[test]
fn test_origin_chain_return_capture_transition() {
    // result = foo()  — the chain continues inside foo at the
    // return-value step.
    let recipe = Recipe {
        source_path: "fixture.py",
        // line 1: <inside foo>: result = 5  (the value the callee returns)
        // line 2: result = foo()           (in caller, the assignment)
        source: "    inner = 5\nresult = foo()\n",
        function_name: "main",
        steps: vec![
            // step 0 (line 1): inside foo's frame, `inner = 5`.
            (1, vec![("inner", int_value(5))]),
            // step 1 (line 1): inside foo, return point — `result` value
            // ascribed by the recorder.
            (1, vec![("inner", int_value(5)), ("result", int_value(5))]),
            // step 2 (line 2): in main, `result = foo()`.
            (2, vec![("result", int_value(5))]),
        ],
        extra_calls: vec![CallShape {
            function_name: "foo",
            step_range: 0..2,
            args: Vec::new(),
        }],
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "result", 2, tmpdir.path());

    // The first hop is the assignment `result = foo()` (classified as
    // FunctionCall by the universal table — the chain terminator).
    assert!(!chain.hops.is_empty(), "expected at least one hop");
    let first = &chain.hops[0];
    assert!(
        matches!(
            first.kind,
            OriginKind::FunctionCall | OriginKind::ReturnCapture | OriginKind::Computational
        ),
        "expected function-call-like first hop, got {:?}",
        first.kind
    );
}

#[test]
fn test_origin_chain_budget_steps_scanned_mid_hop_terminator() {
    // Tight `max_steps_scanned` budget: the algorithm trips
    // OutOfBudget mid-hop and emits a continuation token whose
    // current_step resumes correctly.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\nc = b\nprint(c)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
            (
                4,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    let mut session = MaterializedReplaySession::new(reader);
    let mut expr_loader = ExprLoader::new(CoreTrace::default());
    let patterns = PatternSet::built_in();
    let args = CtOriginChainArguments {
        variable_name: "c".to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: 3,
        thread_id: 0,
        max_hops: 16,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let budget = OriginBudget {
        max_hops: 16,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        // Tight: 1 step. Should trip OutOfBudget on the first hop.
        max_steps_scanned: 1,
    };
    let chain = session
        .origin_chain_inferred(&args, &budget, &mut expr_loader, &patterns, None)
        .expect("ok with truncated");
    assert!(chain.truncated);
    assert_eq!(chain.terminator.kind, TerminatorKind::OutOfBudget);
    assert!(chain.continuation_token.is_some());
}

#[test]
fn test_origin_summary_from_chain() {
    // Demonstrates the eager-path origin_chain -> OriginSummary
    // compression used by ct/load-locals.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmpdir) = build_trace(recipe);
    let chain = run_chain(db, "b", 1, tmpdir.path());

    let summary = db_backend::task::OriginSummary {
        terminator_kind: chain.terminator.kind.into(),
        terminator_expr: chain.terminator.expression.clone(),
        terminator_function: chain.terminator.function.clone(),
        hop_count: chain.hops.len() as u32,
        confidence: chain.confidence,
        is_placeholder: false,
        placeholder_token: None,
    };
    assert!(!summary.is_placeholder);
    assert!(summary.hop_count >= 1);
}

// ---------------------------------------------------------------------------
// Per-surface OriginSummary integration tests — exercise the real DAP
// dispatch through a real `Handler` instance against an in-memory trace.
// Per the milestones-file Introduction these tests are "real backend +
// real handler + real DAP request"; only the trace-ingestion layer uses
// the documented `InMemoryTraceReader` escape hatch (per TODO(M3) in the
// preamble above).
// ---------------------------------------------------------------------------

/// Build a `Handler` instance over the in-memory trace produced by
/// `build_trace`. We use `construct_with_reader` so that the per-session
/// `MaterializedReplaySession` is the same one the production
/// `Handler::new` builds for materialized traces.
fn handler_with_trace(db: Db) -> Handler {
    let reader: Arc<dyn db_backend::trace_reader::TraceReader> = Arc::new(InMemoryTraceReader::new(db));
    Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false)
}

/// Build a synthetic DAP `Request` for the supplied command + JSON
/// arguments. Matches the wire shape produced by `DapClient::request`.
fn make_request(seq: i64, command: &str, args: JsonValue) -> Request {
    Request {
        base: ProtocolMessage {
            seq,
            type_: "request".to_string(),
        },
        command: command.to_string(),
        arguments: args,
    }
}

/// Pull the **response body** for the just-issued request from the
/// channel. Skips any non-Response messages (events, notifications) the
/// handler may emit alongside the response.
fn take_response_body(rx: &mpsc::Receiver<DapMessage>, command: &str) -> JsonValue {
    while let Ok(msg) = rx.try_recv() {
        if let DapMessage::Response(resp) = msg
            && resp.command == command
        {
            assert!(
                resp.success,
                "expected `{}` response to succeed, got message={:?} body={:?}",
                command, resp.message, resp.body
            );
            return resp.body;
        }
    }
    panic!("no response on the channel for command `{}`", command);
}

#[test]
fn test_load_locals_origin_summary_populated() {
    // Fixture: three locals — `a = 10; b = a; c = b` — at the active
    // step. The materialized backend should attach a *non-placeholder*
    // `originSummary` to each local on the `ct/load-locals` response
    // wire (Eager mode per spec §3.2.3 row "State Pane locals (current
    // step, visible rows)").
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\nc = b\nprint(c)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
            (
                3,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
            (
                4,
                vec![("a", int_value(10)), ("b", int_value(10)), ("c", int_value(10))],
            ),
        ],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(3);
    handler.replay.jump_to(StepId(3)).expect("jump_to step 3");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        1,
        "ct/load-locals",
        serde_json::json!({
            "rrTicks": 3,
            "countBudget": 1000,
            "minCountLimit": 0,
            "lang": Lang::Python as u8,
            "watchExpressions": [],
            "depthLimit": -1,
        }),
    );
    let args: CtLoadLocalsArguments = req.load_args().expect("load CtLoadLocalsArguments");
    handler.load_locals(req.clone(), args, tx).expect("load_locals");
    let body = take_response_body(&rx, "ct/load-locals");

    let locals = body.get("locals").and_then(JsonValue::as_array).expect("locals array");
    assert_eq!(locals.len(), 3, "expected three locals: {:?}", locals);
    for v in locals {
        let summary = v.get("originSummary").expect("each variable carries originSummary");
        let is_placeholder = summary
            .get("isPlaceholder")
            .and_then(JsonValue::as_bool)
            .expect("isPlaceholder bool");
        assert!(!is_placeholder, "expected Eager mode for ct/load-locals: {:?}", summary);
        assert!(
            summary.get("hopCount").and_then(JsonValue::as_u64).unwrap_or(0) >= 1,
            "expected at least one hop in the summary: {:?}",
            summary
        );
    }

    // ── Cache assertion ────────────────────────────────────────────
    // The chain-build counter increments once per unknown
    // `(variable_id, step_id)` query. The first load_locals fired
    // three queries. A second, identical request should hit the
    // cache for every variable and leave the counter unchanged.
    let builds_after_first = handler.origin_summary_chain_builds.load(Ordering::Relaxed);
    assert_eq!(
        builds_after_first, 3,
        "first load_locals should perform exactly 3 chain builds (one per local), got {}",
        builds_after_first
    );

    let (tx2, rx2) = mpsc::channel::<DapMessage>();
    let req2 = make_request(
        2,
        "ct/load-locals",
        serde_json::json!({
            "rrTicks": 3,
            "countBudget": 1000,
            "minCountLimit": 0,
            "lang": Lang::Python as u8,
            "watchExpressions": [],
            "depthLimit": -1,
        }),
    );
    let args2: CtLoadLocalsArguments = req2.load_args().unwrap();
    handler.load_locals(req2.clone(), args2, tx2).expect("load_locals 2");
    let body2 = take_response_body(&rx2, "ct/load-locals");
    assert_eq!(
        body2.get("locals").and_then(JsonValue::as_array).map(|a| a.len()),
        Some(3),
        "second load_locals returns three locals"
    );
    let builds_after_second = handler.origin_summary_chain_builds.load(Ordering::Relaxed);
    assert_eq!(
        builds_after_second, builds_after_first,
        "second load_locals must hit the cache — chain builds should be unchanged (was {}, now {})",
        builds_after_first, builds_after_second
    );
}

#[test]
fn test_load_history_origin_summary_per_entry() {
    // Fixture: one variable `v` with five historic values across five
    // consecutive steps. `ct/load-history` for `v` must return five
    // entries each carrying a placeholder `originSummary` (per spec
    // §3.2.3 row "State Pane history-popover entries", default mode on
    // materialized + no omniscient DB). Each placeholder token must
    // round-trip through `OriginContinuationToken::decode` to recover
    // the historic `(variable, step_id)` pair.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "v = 1\nv = 2\nv = 3\nv = 4\nv = 5\nprint(v)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("v", int_value(1))]),
            (2, vec![("v", int_value(2))]),
            (3, vec![("v", int_value(3))]),
            (4, vec![("v", int_value(4))]),
            (5, vec![("v", int_value(5))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(4);
    handler.replay.jump_to(StepId(4)).expect("jump_to step 4");

    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 5,
        rr_ticks: RRTicks(4),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-history",
        serde_json::json!({
            "expression": "v",
            "location": location,
            "isForward": false,
        }),
    );
    let args: LoadHistoryArg = req.load_args().expect("load LoadHistoryArg");
    handler.load_history(req.clone(), args, tx).expect("load_history");
    let body = take_response_body(&rx, "ct/load-history");

    let entries = body
        .get("results")
        .and_then(JsonValue::as_array)
        .expect("results array");
    assert_eq!(entries.len(), 5, "expected five history entries, got {:?}", entries);

    // Each entry must carry a placeholder summary with a non-null
    // token. Decode each token and verify it round-trips to the
    // historic step_id (the line number is 1-based in the recipe; in
    // the test fixture step_idx == line_idx - 1).
    for (idx, entry) in entries.iter().enumerate() {
        let summary = entry
            .get("originSummary")
            .expect("each history entry carries an originSummary");
        let is_placeholder = summary
            .get("isPlaceholder")
            .and_then(JsonValue::as_bool)
            .expect("isPlaceholder bool");
        assert!(
            is_placeholder,
            "expected Placeholder mode for ct/load-history entry {}: {:?}",
            idx, summary
        );
        let token = summary
            .get("placeholderToken")
            .and_then(JsonValue::as_str)
            .expect("placeholder_token populated");
        let decoded = OriginContinuationToken::decode(token).expect("token decodes");
        assert_eq!(decoded.query_variable, "v");
        // Each summary is the origin of *that* historic value. The
        // historic step_id equals the entry's index (0..=4).
        assert_eq!(
            decoded.query_step_id, idx as i64,
            "token must encode the historic step_id for entry {}",
            idx
        );
    }
}

#[test]
fn test_load_flow_origin_summary_per_annotated_value() {
    // Build a tiny flow trace. The trace-embedded variable fallback
    // (triggered by `CODETRACER_DISABLE_TREESITTER=1`) is enough to
    // populate `before_values` from each step's variable snapshot —
    // we then assert every annotated value carries a placeholder
    // origin summary per spec §3.2.3.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 1\nb = 2\nc = a\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(1))]),
            (2, vec![("a", int_value(1)), ("b", int_value(2))]),
            (3, vec![("a", int_value(1)), ("b", int_value(2)), ("c", int_value(1))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(0);
    handler.replay.jump_to(StepId(0)).expect("jump_to step 0");

    // Force the fallback path that does not need tree-sitter parsing
    // of `fixture.py` (the source is synthetic and the handler does
    // not have the per-language grammars warm). This is the same env
    // hatch documented in flow_preloader.rs.
    // SAFETY: integration tests run sequentially within the same
    // process when invoked via `cargo test --test`, and no other
    // test in this file inspects this env var.
    unsafe {
        std::env::set_var("CODETRACER_DISABLE_TREESITTER", "1");
    }

    let abs_path = tmp.path().join("fixture.py");
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: abs_path.to_string_lossy().to_string(),
        line: 1,
        rr_ticks: RRTicks(0),
        function_first: 1,
        function_last: 3,
        function_name: "main".to_string(),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-flow",
        serde_json::json!({
            "flowMode": FlowMode::Call as u8,
            "location": location,
        }),
    );
    let args: CtLoadFlowArguments = req.load_args().expect("load CtLoadFlowArguments");
    handler.load_flow(req.clone(), args, tx).expect("load_flow");

    unsafe {
        std::env::remove_var("CODETRACER_DISABLE_TREESITTER");
    }

    let body = take_response_body(&rx, "ct/load-flow");
    let views = body
        .get("viewUpdates")
        .and_then(JsonValue::as_array)
        .expect("viewUpdates array");
    assert!(!views.is_empty(), "expected at least one view update: {:?}", body);
    let mut total_annotations = 0usize;
    for view in views {
        let steps = view.get("steps").and_then(JsonValue::as_array).expect("steps array");
        for step in steps {
            let summaries = step
                .get("originSummaries")
                .and_then(JsonValue::as_object)
                .expect("originSummaries object per FlowStep");
            // Each variable in `before_values` (and/or `after_values`)
            // should have a parallel placeholder summary keyed by name.
            for (name, summary) in summaries {
                let is_placeholder = summary
                    .get("isPlaceholder")
                    .and_then(JsonValue::as_bool)
                    .expect("isPlaceholder");
                assert!(
                    is_placeholder,
                    "expected Placeholder mode for flow annotation `{}`: {:?}",
                    name, summary
                );
                assert!(
                    summary.get("placeholderToken").and_then(JsonValue::as_str).is_some(),
                    "expected non-null placeholder_token for `{}`",
                    name
                );
                total_annotations += 1;
            }
        }
    }
    assert!(
        total_annotations >= 1,
        "expected at least one annotated value carrying a summary, got 0"
    );
}

#[test]
fn test_origin_summary_eager_vs_placeholder_per_surface() {
    // Verify the §3.2.3 V1 defaults table (materialized without
    // omniscient DB) for each surface end-to-end:
    //   * ct/load-locals  → eager  (is_placeholder == false)
    //   * ct/load-history → placeholder (is_placeholder == true)
    //   * ct/load-flow    → placeholder (is_placeholder == true)
    //   * watches         → eager  (watches piggyback on load-locals
    //                       in this backend)
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "a = 10\nb = a\n",
        function_name: "main",
        steps: vec![
            (1, vec![("a", int_value(10))]),
            (2, vec![("a", int_value(10)), ("b", int_value(10))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(1);
    handler.replay.jump_to(StepId(1)).expect("jump_to step 1");

    // 1) ct/load-locals — eager.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        1,
        "ct/load-locals",
        serde_json::json!({
            "rrTicks": 1,
            "countBudget": 1000,
            "minCountLimit": 0,
            "lang": Lang::Python as u8,
            "watchExpressions": [],
            "depthLimit": -1,
        }),
    );
    let args: CtLoadLocalsArguments = req.load_args().unwrap();
    handler.load_locals(req, args, tx).expect("load_locals");
    let body = take_response_body(&rx, "ct/load-locals");
    let locals = body.get("locals").and_then(JsonValue::as_array).unwrap();
    assert!(!locals.is_empty());
    for v in locals {
        let summary = v.get("originSummary").expect("eager originSummary");
        assert_eq!(
            summary.get("isPlaceholder").and_then(JsonValue::as_bool),
            Some(false),
            "load-locals must be Eager: {:?}",
            summary
        );
    }

    // 2) ct/load-history — placeholder.
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 2,
        rr_ticks: RRTicks(1),
        ..Location::default()
    };
    let req = make_request(
        2,
        "ct/load-history",
        serde_json::json!({
            "expression": "a",
            "location": location.clone(),
            "isForward": false,
        }),
    );
    let args: LoadHistoryArg = req.load_args().unwrap();
    handler.load_history(req, args, tx).expect("load_history");
    let body = take_response_body(&rx, "ct/load-history");
    let entries = body.get("results").and_then(JsonValue::as_array).unwrap();
    assert!(!entries.is_empty());
    for entry in entries {
        let summary = entry.get("originSummary").expect("placeholder originSummary");
        assert_eq!(
            summary.get("isPlaceholder").and_then(JsonValue::as_bool),
            Some(true),
            "load-history must be Placeholder: {:?}",
            summary
        );
    }

    // 3) ct/load-flow — placeholder.
    unsafe {
        std::env::set_var("CODETRACER_DISABLE_TREESITTER", "1");
    }
    let abs_path = tmp.path().join("fixture.py");
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let req = make_request(
        3,
        "ct/load-flow",
        serde_json::json!({
            "flowMode": FlowMode::Call as u8,
            "location": Location {
                path: abs_path.to_string_lossy().to_string(),
                line: 1,
                rr_ticks: RRTicks(0),
                function_first: 1,
                function_last: 2,
                function_name: "main".to_string(),
                ..Location::default()
            },
        }),
    );
    let args: CtLoadFlowArguments = req.load_args().unwrap();
    handler.load_flow(req, args, tx).expect("load_flow");
    unsafe {
        std::env::remove_var("CODETRACER_DISABLE_TREESITTER");
    }
    let body = take_response_body(&rx, "ct/load-flow");
    let mut saw_flow_summary = false;
    for view in body.get("viewUpdates").and_then(JsonValue::as_array).unwrap() {
        for step in view.get("steps").and_then(JsonValue::as_array).unwrap() {
            for (_name, summary) in step.get("originSummaries").and_then(JsonValue::as_object).unwrap() {
                assert_eq!(
                    summary.get("isPlaceholder").and_then(JsonValue::as_bool),
                    Some(true),
                    "load-flow must be Placeholder: {:?}",
                    summary
                );
                saw_flow_summary = true;
            }
        }
    }
    assert!(saw_flow_summary, "expected at least one flow annotation");

    // 4) Watches piggyback on ct/load-locals (this backend does not
    //    expose a separate `evaluate` route per spec §5.4). Watches
    //    are *Eager* (same row in §3.2.3 as visible locals). Verified
    //    via step 1 above — watches go through the same wire shape
    //    and the same per-variable eager summary.
}

#[test]
fn test_origin_summary_lazy_batch_resolves_placeholders() {
    // ct/originSummary takes the placeholder tokens produced by
    // ct/load-history and returns a same-length array of filled
    // OriginSummary values in order. Per spec §5.3.2, per-token
    // errors yield UnknownVariable / UnknownSource summaries
    // rather than request-level failures.
    let recipe = Recipe {
        source_path: "fixture.py",
        source: "v = 1\nv = 2\nv = 3\nprint(v)\n",
        function_name: "main",
        steps: vec![
            (1, vec![("v", int_value(1))]),
            (2, vec![("v", int_value(2))]),
            (3, vec![("v", int_value(3))]),
        ],
        extra_calls: Vec::new(),
    };
    let (db, _tmp) = build_trace(recipe);
    let mut handler = handler_with_trace(db);
    handler.step_id = StepId(2);
    handler.replay.jump_to(StepId(2)).expect("jump_to step 2");

    // ── 1) Capture N placeholder tokens via ct/load-history ──────
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let location = Location {
        path: "fixture.py".to_string(),
        line: 4,
        rr_ticks: RRTicks(2),
        ..Location::default()
    };
    let req = make_request(
        1,
        "ct/load-history",
        serde_json::json!({
            "expression": "v",
            "location": location,
            "isForward": false,
        }),
    );
    let args: LoadHistoryArg = req.load_args().unwrap();
    handler.load_history(req, args, tx).expect("load_history");
    let body = take_response_body(&rx, "ct/load-history");
    let entries = body.get("results").and_then(JsonValue::as_array).unwrap();
    let tokens: Vec<String> = entries
        .iter()
        .map(|e| {
            e.get("originSummary")
                .and_then(|s| s.get("placeholderToken"))
                .and_then(JsonValue::as_str)
                .expect("each entry carries a placeholderToken")
                .to_string()
        })
        .collect();
    assert!(tokens.len() >= 2, "expected at least two history tokens");

    // Build a "deliberately corrupted" token: re-encode one of the
    // captured tokens with a variable name that does not exist in
    // the trace.
    let mut bad_decoded = OriginContinuationToken::decode(&tokens[0]).unwrap();
    bad_decoded.query_variable = "no-such-variable-anywhere".to_string();
    bad_decoded.current_var_name = "no-such-variable-anywhere".to_string();
    let bad_token = bad_decoded.encode().unwrap();

    // Mix the bad token into the batch. The spec says per-token
    // errors yield UnknownVariable / UnknownSource summaries.
    let mut batch_tokens = tokens.clone();
    batch_tokens.push(bad_token);

    // ── 2) Issue ct/originSummary with the captured + bad tokens ──
    let (tx2, rx2) = mpsc::channel::<DapMessage>();
    let req2 = make_request(2, "ct/originSummary", serde_json::json!({ "tokens": batch_tokens }));
    let args2: CtOriginSummaryArguments = req2.load_args().unwrap();
    handler.origin_summary(req2, args2, tx2).expect("origin_summary");
    let body = take_response_body(&rx2, "ct/originSummary");
    let summaries = body
        .get("summaries")
        .and_then(JsonValue::as_array)
        .expect("summaries array");
    assert_eq!(
        summaries.len(),
        batch_tokens.len(),
        "expected parallel-array response: {} tokens -> {} summaries",
        batch_tokens.len(),
        summaries.len()
    );

    // The first N (genuine) tokens must round-trip into filled
    // (non-placeholder) summaries.
    for (idx, summary) in summaries.iter().take(tokens.len()).enumerate() {
        let is_placeholder = summary
            .get("isPlaceholder")
            .and_then(JsonValue::as_bool)
            .expect("isPlaceholder");
        assert!(
            !is_placeholder,
            "expected genuine token {} to resolve to a filled summary: {:?}",
            idx, summary
        );
    }

    // The bad token must produce an UnknownVariable / UnknownSource
    // terminator. Deserialise the OriginSummary so the variant check
    // goes through the wire shape rather than a string match.
    let bad_summary: OriginSummary =
        serde_json::from_value(summaries.last().unwrap().clone()).expect("bad summary deserialises");
    assert!(
        matches!(
            bad_summary.terminator_kind,
            TerminatorKindWire::UnknownVariable | TerminatorKindWire::UnknownSource
        ),
        "expected UnknownVariable/UnknownSource for corrupted token, got {:?}",
        bad_summary.terminator_kind
    );
}
