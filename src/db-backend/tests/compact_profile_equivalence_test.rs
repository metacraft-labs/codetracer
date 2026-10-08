//! CCP-5 — a COMPACT container and a FULL container of one recording answer
//! every query in the backend's own API surface identically.
//!
//! # Why the enumeration is derived and not written down
//!
//! The deliverable is equivalence across the WHOLE query surface, and the
//! failure mode of a hand-listed surface is that it quietly becomes a
//! convenient subset: a method added to `TraceReader` is not covered, nothing
//! says so, and the arm keeps passing. So the surface is read out of
//! `src/trace_reader.rs` at test time — the trait IS the backend's query API,
//! and its 4-space `fn` declarations are the methods a caller can reach — and
//! the set of methods this file probes is asserted EQUAL to it, in both
//! directions. Adding a method to the trait fails this arm by name until it is
//! probed; probing a method the trait does not declare fails it too.
//!
//! # No mocks
//!
//! Every container here is produced by a real writer and read by the
//! production `CTFSTraceReader`. The two legacy-`events.log` bundles are
//! written by `common::legacy_events_log` (the retired writer's own bytes) and
//! the compact ones by `ctfs_container::write_compact_ctfs`, which is the §1d
//! encoder. Nothing is stubbed, and the only injected behaviour is the
//! deliberately-broken conversion the control requires, which is applied to
//! MEMBER BYTES in this file and touches no production code path.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};

use codetracer_trace_types::{
    CallKey, CallRecord, EventLogKind, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, Place, RecordEvent,
    ReturnRecord, StepId, StepRecord, TraceLowLevelEvent, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord,
    VariableId,
};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::{CtfsProfile, CtfsReader, write_compact_ctfs, write_minimal_ctfs};
use db_backend::db::CellChange;
use db_backend::expr_loader::ExprLoader;
use db_backend::task::CoreTrace;
use db_backend::trace_reader::TraceReader;

mod common;

/// The source file every fixture recording registers.
const SRC: &str = "/tmp/ccp5/program.rs";

/// User steps in the equivalence fixture. Large enough that the legacy
/// `events.log` spans several zstd chunks (the helper chunks every 4 events),
/// so the compact container carries a multi-chunk member rather than a single
/// one.
const USER_STEPS: usize = 40;

// ── The query surface, enumerated FROM the API ──────────────────────────

/// `src/trace_reader.rs`, compiled into this test so the enumeration cannot
/// drift from the trait it is enumerating.
const TRACE_READER_SRC: &str = include_str!("../src/trace_reader.rs");

/// Every method `pub trait TraceReader` declares.
///
/// The parse is pinned to the file's shape rather than being tolerant of it:
/// the file must contain exactly one `pub trait`, and the trait must run to the
/// end of the file. A tolerant parser that silently found zero methods is the
/// one way this whole arm could pass by covering nothing.
fn declared_query_surface() -> BTreeSet<String> {
    assert_eq!(
        TRACE_READER_SRC.matches("\npub trait ").count() + usize::from(TRACE_READER_SRC.starts_with("pub trait ")),
        1,
        "src/trace_reader.rs no longer contains exactly one top-level trait; the enumeration \
         below assumes the whole file is the TraceReader trait and must be re-pinned"
    );
    assert!(
        TRACE_READER_SRC.contains("pub trait TraceReader"),
        "src/trace_reader.rs does not declare TraceReader"
    );

    let mut names = BTreeSet::new();
    let mut seen_trait = false;
    for line in TRACE_READER_SRC.lines() {
        if line.starts_with("pub trait TraceReader") {
            seen_trait = true;
            continue;
        }
        if !seen_trait {
            continue;
        }
        // Trait-level declarations sit at exactly four spaces. Anything inside
        // a default body is indented further, and this file holds nothing but
        // the trait.
        if let Some(rest) = line.strip_prefix("    fn ") {
            let name: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            assert!(!name.is_empty(), "could not read a method name out of {line:?}");
            names.insert(name);
        }
    }
    assert!(
        names.len() > 50,
        "the enumeration found only {} methods, which is not a query surface — the parse is \
         broken and every comparison below would be vacuous",
        names.len()
    );
    names
}

// ── Probes: one per trait method, each reducing a reader to a String ─────

/// A probe is a method name plus a function that reduces the reader's answers
/// for that method to a string.
///
/// A STRING, and not a typed comparison, on purpose: the comparison has to work
/// for 64 unrelated return types including three iterators, two tuples and four
/// `HashMap`s, and the one thing every answer has in common is that it can be
/// rendered. Every `HashMap` is rendered through a `BTreeMap` first, because a
/// `HashMap`'s `Debug` order is not stable and a difference in iteration order
/// is not a difference in the answer.
type Probe = (&'static str, fn(&CTFSTraceReader) -> String);

fn sorted_map<K: std::fmt::Debug, V: std::fmt::Debug>(map: &HashMap<K, V>) -> String {
    let ordered: BTreeMap<String, String> = map.iter().map(|(k, v)| (format!("{k:?}"), format!("{v:?}"))).collect();
    format!("{ordered:?}")
}

/// Step ids to probe: the ends and a spread through the middle, so a defect
/// confined to one region of the trace is reachable.
fn probe_steps(reader: &CTFSTraceReader) -> Vec<StepId> {
    let n = reader.step_count() as i64;
    let mut ids: Vec<i64> = vec![0, 1, 2, n / 3, n / 2, (2 * n) / 3, n - 2, n - 1, n, n + 5];
    ids.retain(|i| *i >= 0);
    ids.sort_unstable();
    ids.dedup();
    ids.into_iter().map(StepId).collect()
}

fn probe_calls(reader: &CTFSTraceReader) -> Vec<CallKey> {
    let n = reader.call_count() as i64;
    (-1..=n.max(1)).map(CallKey).collect()
}

/// Call keys INSIDE the trait's documented contract: `NO_KEY` (-1) or a key
/// that exists.
///
/// `load_location` asserts exactly that and panics otherwise — "some traces
/// have steps that are not inside any call" is the NO_KEY case it allows, and
/// an out-of-range key is a caller bug it refuses to paper over. MEASURED
/// rather than assumed: the first version of this probe reused
/// `probe_calls`, which includes `call_count` itself, and the arm died with
/// `load_location: invalid call_key`. That is the method keeping its contract,
/// not a loader defect, so the PROBE was wrong and was narrowed — the
/// out-of-range keys are still probed through every method whose contract
/// admits them.
fn probe_valid_calls(reader: &CTFSTraceReader) -> Vec<CallKey> {
    let mut keys = vec![CallKey(-1)];
    keys.extend((0..reader.call_count() as i64).map(CallKey));
    keys
}

/// Every probe, keyed by the trait method it exercises.
#[allow(clippy::too_many_lines)]
fn probes() -> Vec<Probe> {
    vec![
        ("path", |r| {
            (0..r.path_count() + 2)
                .map(|i| format!("{:?}", r.path(PathId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("function", |r| {
            (0..r.function_count() + 2)
                .map(|i| format!("{:?}", r.function(FunctionId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("type_record", |r| {
            (0..r.type_count() + 2)
                .map(|i| format!("{:?}", r.type_record(TypeId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("variable_name", |r| {
            (0..USER_STEPS + 4)
                .map(|i| format!("{:?}", r.variable_name(VariableId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("variable_id_for", |r| {
            (0..USER_STEPS + 2)
                .map(|i| format!("{:?}", r.variable_id_for(&format!("var_{i}"))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("path_count", |r| r.path_count().to_string()),
        ("function_count", |r| r.function_count().to_string()),
        ("type_count", |r| r.type_count().to_string()),
        ("step", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.step(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("step_count", |r| r.step_count().to_string()),
        ("variables_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.variables_at(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("compound_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| r.compound_at(id).map(sorted_map).unwrap_or_default())
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("cells_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| r.cells_at(id).map(sorted_map).unwrap_or_default())
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("cell_changes_for", |r| {
            (0i64..6)
                .map(|i| format!("{:?}", r.cell_changes_for(&Place(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("variable_cells_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| r.variable_cells_at(id).map(sorted_map).unwrap_or_default())
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("call", |r| {
            probe_calls(r)
                .into_iter()
                .map(|k| format!("{:?}", r.call(k)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("call_count", |r| r.call_count().to_string()),
        ("seekable_call_count", |r| format!("{:?}", r.seekable_call_count())),
        ("seekable_call", |r| {
            probe_calls(r)
                .into_iter()
                .map(|k| format!("{:?}", r.seekable_call(k)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("seekable_step_count", |r| format!("{:?}", r.seekable_step_count())),
        ("seekable_step_line", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.seekable_step_line(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("seekable_value_count", |r| format!("{:?}", r.seekable_value_count())),
        ("seekable_variables_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.seekable_variables_at(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("variables_at_owned", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.variables_at_owned(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("events", |r| format!("{:?}", r.events())),
        ("event_count", |r| r.event_count().to_string()),
        ("seekable_event_count", |r| format!("{:?}", r.seekable_event_count())),
        ("seekable_event_page", |r| {
            [(0usize, 1usize), (0, 8), (3, 5), (0, 1 << 20)]
                .into_iter()
                .map(|(s, l)| format!("{:?}", r.seekable_event_page(s, l)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("path_ids_for", |r| {
            [SRC, "program.rs", "/nope.rs", ""]
                .into_iter()
                .map(|p| format!("{:?}", r.path_ids_for(p)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("path_version_ordinal", |r| {
            (0..r.path_count() + 2)
                .map(|i| r.path_version_ordinal(PathId(i)).to_string())
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("source_digest_for_path", |r| {
            (0..r.path_count() + 2)
                .map(|i| r.source_digest_for_path(PathId(i)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("path_id_for_first_version", |r| {
            [SRC, "program.rs", "/nope.rs"]
                .into_iter()
                .map(|p| format!("{:?}", r.path_id_for_first_version(p)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("path_id_for_latest_version", |r| {
            [SRC, "program.rs", "/nope.rs"]
                .into_iter()
                .map(|p| format!("{:?}", r.path_id_for_latest_version(p)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("steps_on_line", |r| {
            let mut out = Vec::new();
            for p in 0..r.path_count() + 1 {
                for line in 0..20 + USER_STEPS {
                    out.push(format!("{:?}", r.steps_on_line(PathId(p), line)));
                }
            }
            out.join("|")
        }),
        ("step_map_for_path", |r| {
            (0..r.path_count() + 1)
                .map(|p| r.step_map_for_path(PathId(p)).map(sorted_map).unwrap_or_default())
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("step_ids_on_line", |r| {
            let mut out = Vec::new();
            for p in 0..r.path_count() + 1 {
                for line in 0..20 + USER_STEPS {
                    out.push(format!("{:?}", r.step_ids_on_line(PathId(p), line)));
                }
            }
            out.join("|")
        }),
        ("call_run_end", |r| {
            let mut out = Vec::new();
            for step in probe_steps(r) {
                for key in probe_calls(r) {
                    out.push(format!("{:?}", r.call_run_end(step, key)));
                }
            }
            out.join("|")
        }),
        ("max_line_over_steps", |r| {
            let steps = probe_steps(r);
            let mut out = Vec::new();
            for a in &steps {
                for b in &steps {
                    out.push(format!("{:?}", r.max_line_over_steps(*a, *b)));
                }
            }
            out.join("|")
        }),
        ("functions_iter", |r| {
            format!("{:?}", r.functions_iter().collect::<Vec<_>>())
        }),
        ("calls_iter", |r| format!("{:?}", r.calls_iter().collect::<Vec<_>>())),
        ("steps_from", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.steps_from(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("scan_steps_from", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for forward in [true, false] {
                    let mut seen = Vec::new();
                    r.scan_steps_from(id, forward, &mut |s| {
                        seen.push(s.step_id.0);
                        seen.len() < 12
                    });
                    out.push(format!("{id:?}/{forward}:{seen:?}"));
                }
            }
            out.join("|")
        }),
        ("path_entries_iter", |r| {
            let mut entries: Vec<String> = r.path_entries_iter().map(|(p, id)| format!("{p}={}", id.0)).collect();
            entries.sort();
            entries.join("|")
        }),
        ("instructions_at", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.instructions_at(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("call_key_for_step", |r| {
            probe_steps(r)
                .into_iter()
                .map(|id| format!("{:?}", r.call_key_for_step(id)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("load_step_events", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for exact in [true, false] {
                    out.push(format!("{:?}", r.load_step_events(id, exact)));
                }
            }
            out.join("|")
        }),
        // Compared WHOLE, not as a basename, and that is safe for a specific
        // reason: the compact container carries the full container's own
        // `meta.dat` bytes verbatim, so the recorded workdir is the same
        // string in both. A probe that weakened this to a basename would be
        // throwing away a comparison it is entitled to make.
        ("workdir", |r| format!("{:?}", r.workdir())),
        ("end_of_program", |r| format!("{:?}", r.end_of_program())),
        ("omniscient_db", |r| format!("present={}", r.omniscient_db().is_some())),
        ("to_ct_type", |r| {
            (0..r.type_count() + 2)
                .map(|i| format!("{:?}", r.to_ct_type(&TypeId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("get_field_names", |r| {
            (0..r.type_count() + 2)
                .map(|i| format!("{:?}", r.get_field_names(&TypeId(i))))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("to_ct_value", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                if let Some(vars) = r.variables_at_owned(id) {
                    for v in vars {
                        out.push(format!("{:?}", r.to_ct_value(&v.value)));
                    }
                }
            }
            out.join("|")
        }),
        ("to_call_arg", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                if let Some(vars) = r.variables_at_owned(id) {
                    for v in vars {
                        out.push(format!("{:?}", r.to_call_arg(&v)));
                    }
                }
            }
            out.join("|")
        }),
        ("to_call", |r| {
            let mut loader = ExprLoader::new(CoreTrace::default());
            let mut out = Vec::new();
            for call in r.calls_iter().cloned().collect::<Vec<_>>() {
                out.push(format!("{:?}", r.to_call(&call, &mut loader)));
            }
            out.join("|")
        }),
        // Every field of every Location, for every (step, call) pair probed.
        // Whole-struct `Debug` rather than a chosen projection: a field this
        // test did not think of is exactly the one a loader defect would move,
        // and the paths are identical in both containers for the reason given
        // on `workdir` above.
        ("load_location", |r| {
            let mut loader = ExprLoader::new(CoreTrace::default());
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for key in probe_valid_calls(r) {
                    out.push(format!("{:?}", r.load_location(id, key, &mut loader)));
                }
            }
            out.join("|")
        }),
        ("step_over_depths_step_id", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for forward in [true, false] {
                    for delta in [0usize, 1, 3] {
                        out.push(format!("{:?}", r.step_over_depths_step_id(id, forward, delta)));
                    }
                }
            }
            out.join("|")
        }),
        ("step_out_step_id_relative_to", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for forward in [true, false] {
                    out.push(format!("{:?}", r.step_out_step_id_relative_to(id, forward)));
                }
            }
            out.join("|")
        }),
        ("next_step_id_relative_to", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for forward in [true, false] {
                    for different_line in [true, false] {
                        out.push(format!("{:?}", r.next_step_id_relative_to(id, forward, different_line)));
                    }
                }
            }
            out.join("|")
        }),
        ("next_step_id_relative_to_with_granularity", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for forward in [true, false] {
                    for line in [true, false] {
                        for column in [true, false] {
                            out.push(format!(
                                "{:?}",
                                r.next_step_id_relative_to_with_granularity(id, forward, line, column)
                            ));
                        }
                    }
                }
            }
            out.join("|")
        }),
        ("load_value_for_place", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r) {
                for place in 0i64..4 {
                    out.push(format!("{:?}", r.load_value_for_place(Place(place), id)));
                }
            }
            out.join("|")
        }),
        ("load_compound_value_for_place", |r| {
            let mut out = Vec::new();
            for place in 0i64..4 {
                for step in probe_steps(r).into_iter().take(3) {
                    let change = CellChange {
                        step_id: step,
                        item_count: 2,
                        type_id: Some(TypeId(1)),
                        index: Some(0),
                        item_place: Some(Place(place)),
                    };
                    out.push(format!("{:?}", r.load_compound_value_for_place(Place(place), change)));
                }
            }
            out.join("|")
        }),
        ("load_value_item_by_index", |r| {
            let mut out = Vec::new();
            for id in probe_steps(r).into_iter().take(4) {
                for place in 0i64..3 {
                    for index in 0..3 {
                        out.push(format!("{:?}", r.load_value_item_by_index(Place(place), index, id)));
                    }
                }
            }
            out.join("|")
        }),
        ("fuzzy_path_ids_for", |r| {
            ["program.rs", SRC, "ccp5/program.rs", "nope.rs", ""]
                .into_iter()
                .map(|p| format!("{:?}", r.fuzzy_path_ids_for(p)))
                .collect::<Vec<_>>()
                .join("|")
        }),
        ("fuzzy_path_id_for", |r| {
            ["program.rs", SRC, "ccp5/program.rs", "nope.rs", ""]
                .into_iter()
                .map(|p| format!("{:?}", r.fuzzy_path_id_for(p)))
                .collect::<Vec<_>>()
                .join("|")
        }),
    ]
}

// ── Fixtures ────────────────────────────────────────────────────────────

/// A named recording shape. The equivalence arm runs over ALL of them, because
/// the verification text says "for every recording in the corpus" and one
/// recording is not a corpus: a loader defect confined to a record shape the
/// single fixture happens not to contain is exactly what one fixture misses.
struct Recording {
    name: &'static str,
    events: Vec<TraceLowLevelEvent>,
}

/// The second source file shape 2 and 3 register, so path resolution has more
/// than one answer to get wrong.
const SRC2: &str = "/tmp/ccp5/other.rs";

/// Shape 1 — one path, one call, `USER_STEPS` steps with repeating lines and
/// one integer local each. The baseline.
fn one_path_recording() -> Vec<TraceLowLevelEvent> {
    let int_type = TypeId(1);
    let mut events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(PathBuf::from(SRC)),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "Int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".to_string(),
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
    for i in 0..USER_STEPS {
        events.push(TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            // Lines repeat on purpose (modulo 7): a line with SEVERAL steps on
            // it is what `steps_on_line` / `step_ids_on_line` — the
            // omniscience index — are for, and a fixture where every line has
            // exactly one step would not exercise them.
            line: Line(10 + (i % 7) as i64),
        }));
        events.push(TraceLowLevelEvent::VariableName(format!("var_{i}")));
        events.push(TraceLowLevelEvent::Value(FullValueRecord {
            variable_id: VariableId(i),
            value: ValueRecord::Int {
                i: (i * 100) as i64,
                type_id: int_type,
            },
        }));
    }
    events.push(TraceLowLevelEvent::Return(ReturnRecord {
        return_value: ValueRecord::None { type_id: TypeId(0) },
    }));
    events
}

/// Shape 2 — TWO paths, TWO nested calls and `Event` records, so `db.events`,
/// `load_step_events`, `path_ids_for` and the step-out / step-over walks have
/// content rather than an empty answer. An equivalence that only ever compared
/// `None` to `None` would be worth very little.
fn two_path_recording() -> Vec<TraceLowLevelEvent> {
    let int_type = TypeId(1);
    let mut events: Vec<TraceLowLevelEvent> = vec![
        TraceLowLevelEvent::Path(PathBuf::from(SRC)),
        TraceLowLevelEvent::Path(PathBuf::from(SRC2)),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "Int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "outer".to_string(),
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(1),
            line: Line(5),
            name: "inner".to_string(),
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
    for i in 0..USER_STEPS {
        let in_inner = (8..24).contains(&i);
        if i == 8 {
            events.push(TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(1),
                args: vec![],
            }));
        }
        events.push(TraceLowLevelEvent::Step(StepRecord {
            path_id: if in_inner { PathId(1) } else { PathId(0) },
            line: Line(if in_inner {
                5 + (i % 3) as i64
            } else {
                10 + (i % 7) as i64
            }),
        }));
        events.push(TraceLowLevelEvent::VariableName(format!("v{i}")));
        events.push(TraceLowLevelEvent::Value(FullValueRecord {
            variable_id: VariableId(i),
            value: ValueRecord::Int {
                i: (i * 7) as i64,
                type_id: int_type,
            },
        }));
        if i % 5 == 0 {
            events.push(TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Write,
                metadata: format!("meta-{i}"),
                content: format!("line {i}\n"),
            }));
        }
        if i == 23 {
            events.push(TraceLowLevelEvent::Return(ReturnRecord {
                return_value: ValueRecord::Int {
                    i: 99,
                    type_id: int_type,
                },
            }));
        }
    }
    events.push(TraceLowLevelEvent::Return(ReturnRecord {
        return_value: ValueRecord::None { type_id: TypeId(0) },
    }));
    events
}

/// Shape 3 — the SMALLEST well-formed recording: one path, one call, one step
/// and nothing else. It is in the corpus because the empty and near-empty
/// answers are where an off-by-one in a directory read shows up, and because a
/// compact container of it is 28 + 48 + payload with two tiny members.
fn minimal_recording() -> Vec<TraceLowLevelEvent> {
    vec![
        TraceLowLevelEvent::Path(PathBuf::from(SRC)),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "only".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(1),
        }),
        TraceLowLevelEvent::Return(ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }),
    ]
}

fn corpus() -> Vec<Recording> {
    vec![
        Recording {
            name: "one_path",
            events: one_path_recording(),
        },
        Recording {
            name: "two_paths_calls_events",
            events: two_path_recording(),
        },
        Recording {
            name: "minimal",
            events: minimal_recording(),
        },
    ]
}

/// The baseline recording the non-corpus arms use.
fn fixture_events() -> Vec<TraceLowLevelEvent> {
    one_path_recording()
}

/// Read every member of a FULL container, in its own directory order.
fn members_of(path: &Path) -> Vec<(String, Vec<u8>)> {
    let mut ctfs = CtfsReader::open(path).expect("the full container opens");
    assert_eq!(
        ctfs.profile(),
        CtfsProfile::Full,
        "the source of the conversion must be a full container"
    );
    let order: Vec<String> = ctfs.member_names_in_order().to_vec();
    assert!(!order.is_empty(), "the full container declares no members");
    order
        .into_iter()
        .map(|name| {
            let bytes = ctfs
                .read_file(&name)
                .unwrap_or_else(|e| panic!("member {name} is unreadable in the full container: {e}"));
            (name, bytes)
        })
        .collect()
}

/// Write a COMPACT container carrying `members` verbatim.
fn write_compact(dir: &Path, name: &str, members: &[(String, Vec<u8>)]) -> PathBuf {
    let path = dir.join(format!("{name}.ct"));
    let refs: Vec<(&str, &[u8])> = members.iter().map(|(n, d)| (n.as_str(), d.as_slice())).collect();
    write_compact_ctfs(&path, &refs).expect("the compact encoder writes");
    path
}

/// Compare two readers over the whole enumerated surface, returning one line
/// per method that disagrees.
fn surface_differences(compact: &CTFSTraceReader, full: &CTFSTraceReader) -> Vec<String> {
    let mut diffs = Vec::new();
    for (name, probe) in probes() {
        let a = probe(compact);
        let b = probe(full);
        if a != b {
            let at = a
                .chars()
                .zip(b.chars())
                .position(|(x, y)| x != y)
                .unwrap_or_else(|| a.chars().count().min(b.chars().count()));
            // Sliced by CHARACTER and not by byte: a path or a value rendered
            // with a non-ASCII byte would make byte slicing panic, and a
            // comparison that panics instead of reporting is not a report.
            let window = |s: &str| -> String { s.chars().skip(at.saturating_sub(40)).take(120).collect() };
            diffs.push(format!(
                "{name}: compact and full disagree at character {at} (compact {} chars, full {} \
                 chars)\n    compact: {}\n    full:    {}",
                a.chars().count(),
                b.chars().count(),
                window(&a),
                window(&b),
            ));
        }
    }
    diffs
}

// ── The arms ────────────────────────────────────────────────────────────

#[test]
fn test_compact_and_full_answer_every_query_identically() {
    // (1) The enumeration is derived from the API, and the probe set must equal
    //     it in BOTH directions.
    let declared = declared_query_surface();
    let probed: BTreeSet<String> = probes().into_iter().map(|(n, _)| n.to_owned()).collect();
    assert_eq!(probes().len(), probed.len(), "a method is probed twice");
    let unprobed: Vec<&String> = declared.difference(&probed).collect();
    let stale: Vec<&String> = probed.difference(&declared).collect();
    assert!(
        unprobed.is_empty() && stale.is_empty(),
        "the probe set is not the query surface.\n  declared by TraceReader but NOT probed: \
         {unprobed:?}\n  probed but NOT declared by TraceReader: {stale:?}\nThe enumeration is \
         read from src/trace_reader.rs at test time precisely so this cannot be papered over by \
         editing a list."
    );
    println!(
        "query surface: {} methods, enumerated from src/trace_reader.rs, all probed",
        declared.len()
    );

    let dir = tempfile::tempdir().expect("tempdir");
    let mut total_controls = 0usize;

    for recording in corpus() {
        let label = recording.name;
        // (2) One recording, two containers. The FULL one is written by the
        //     retired writer's own bytes; the COMPACT one carries the SAME
        //     member bytes behind a §1d directory, so a difference below is a
        //     difference in the LOADER and not in the recording.
        let full_path = common::legacy_events_log::write_legacy_events_log_bundle(
            dir.path(),
            &format!("ccp5_{label}_full"),
            &recording.events,
        );
        let members = members_of(&full_path);
        let compact_path = write_compact(dir.path(), &format!("ccp5_{label}_compact"), &members);

        let full_len = std::fs::metadata(&full_path).expect("full size").len();
        let compact_len = std::fs::metadata(&compact_path).expect("compact size").len();
        let payload: u64 = members.iter().map(|(_, d)| d.len() as u64).sum();
        let identity = 28 + 24 * members.len() as u64 + payload;
        assert_eq!(
            compact_len, identity,
            "{label}: the compact container is not exactly header + directory + members"
        );

        // (3) The compact container opens through the COMPACT loader, and its
        //     member sequence is the full container's own — read from the
        //     container, not from a list this test wrote down.
        let compact_ctfs = CtfsReader::open(&compact_path).expect("the compact container opens");
        assert_eq!(compact_ctfs.profile(), CtfsProfile::Compact);
        let full_ctfs = CtfsReader::open(&full_path).expect("the full container opens");
        assert_eq!(
            compact_ctfs.member_names_in_order(),
            full_ctfs.member_names_in_order(),
            "{label}: a compact and a full container of one recording must name the same members \
             identically"
        );

        // (4) THE EQUIVALENCE.
        let compact_reader = CTFSTraceReader::open(&compact_path).expect("the compact trace reader opens");
        let full_reader = CTFSTraceReader::open(&full_path).expect("the full trace reader opens");
        let diffs = surface_differences(&compact_reader, &full_reader);
        assert!(
            diffs.is_empty(),
            "{label}: a compact load and a full load of one recording disagree on {} of {} \
             methods:\n{}",
            diffs.len(),
            declared.len(),
            diffs.join("\n")
        );
        println!(
            "| {label} | {} members | {} steps | {} calls | {} paths | {} events | FULL {full_len} B | \
             COMPACT {compact_len} B (= 28 + 24*{} + {payload}) | 0 differences over {} methods |",
            members.len(),
            full_reader.step_count(),
            full_reader.call_count(),
            full_reader.path_count(),
            full_reader.event_count(),
            members.len(),
            declared.len(),
        );

        // (5) THE OMNISCIENCE HALF, measured rather than assumed. CCP-3 is
        //     deferred, so a compact container may carry its derived indexes;
        //     these carry none, so the breakpoint index is MATERIALISED in
        //     memory by the load. The other branch — a container that DOES
        //     carry it — is the arm below.
        assert!(
            !compact_ctfs.has_file("step-map.ns"),
            "{label} is the materialise-it branch and must not carry step-map.ns"
        );
        assert!(
            !compact_reader.has_prepopulated_step_map(),
            "{label}: no step-map.ns is present, so no prepopulated index may be reported"
        );
        let materialised: usize = (0..compact_reader.path_count())
            .filter_map(|p| compact_reader.step_map_for_path(PathId(p)))
            .map(HashMap::len)
            .sum();
        assert!(
            materialised > 0,
            "{label}: the compact load materialised no line -> steps entries at all, so the \
             omniscience data is not in memory"
        );
        println!(
            "  omniscience: {materialised} line -> steps entries materialised in memory from the \
             compact load of {label}"
        );

        // (6) THE CONTROL — a deliberately broken conversion must be CAUGHT.
        //
        //     The fault is chosen to be the SILENT one: `events.log` is cut at
        //     a CHUNK BOUNDARY, so the container is well-formed under every
        //     §1d check, the chunked reader walks the surviving chunks without
        //     complaint, and the trace opens cleanly carrying fewer events.
        //     Only the equivalence comparison can tell. A cut in the MIDDLE of
        //     a chunk would be refused by the chunk reader and would prove
        //     nothing about the comparison — it would be testing the chunk
        //     reader.
        let full_log = members
            .iter()
            .find(|(n, _)| n == "events.log")
            .map(|(_, d)| d.clone())
            .expect("the fixture carries events.log");
        let cut = chunk_boundary_near(&full_log, full_log.len() * 2 / 3);
        if cut >= full_log.len() {
            // The `minimal` shape fits in ONE chunk, so there is no interior
            // boundary and no silent cut to make. Said out loud rather than
            // skipped quietly, and the other shapes carry the control.
            println!("  control: {label} spans a single chunk — no interior boundary, control not applicable");
            continue;
        }
        let mut broken = members.clone();
        broken
            .iter_mut()
            .find(|(n, _)| n == "events.log")
            .expect("the fixture carries events.log")
            .1
            .truncate(cut);
        let broken_path = write_compact(dir.path(), &format!("ccp5_{label}_broken"), &broken);
        let broken_ctfs = CtfsReader::open(&broken_path).expect("the broken container is still well-formed §1d");
        assert_eq!(broken_ctfs.profile(), CtfsProfile::Compact);
        assert_eq!(
            broken_ctfs.member_names_in_order(),
            full_ctfs.member_names_in_order(),
            "{label}: the fault must not change the member set — that is what makes it silent"
        );
        let broken_reader =
            CTFSTraceReader::open(&broken_path).expect("the broken container OPENS; that is the whole point of it");
        assert!(
            broken_reader.step_count() < full_reader.step_count(),
            "{label}: the fault left all {} steps, so it removed nothing and the control is \
             vacuous",
            broken_reader.step_count()
        );
        if broken_reader.step_count() == 0 {
            // MEASURED, and stated rather than papered over: the `minimal`
            // shape is six events in two chunks, and its only interior chunk
            // boundary falls BEFORE its single Step — so there is no cut that
            // removes some steps and keeps some. A one-step recording cannot
            // carry a "silently lost part of the trace" fault, which is a
            // property of the recording and not a gap in the control. The two
            // larger shapes carry it, and the assertion at the end of this arm
            // requires at least two of them to.
            println!(
                "  control: {label} has {} step(s) and its only chunk boundary precedes them — no \
                 cut both removes and keeps steps, control not applicable",
                full_reader.step_count()
            );
            continue;
        }
        let broken_diffs = surface_differences(&broken_reader, &full_reader);
        assert!(
            !broken_diffs.is_empty(),
            "{label}: a compact container missing part of its event stream compared EQUAL to the \
             full one over all {} methods — the comparison cannot fail and is therefore not \
             evidence",
            declared.len()
        );
        total_controls += 1;
        println!(
            "  control: cutting events.log from {} to {cut} bytes at a chunk boundary leaves {} of \
             {} steps and is caught on {} of {} methods (first: {})",
            full_log.len(),
            broken_reader.step_count(),
            full_reader.step_count(),
            broken_diffs.len(),
            declared.len(),
            broken_diffs[0].lines().next().unwrap_or_default()
        );
    }

    assert!(
        total_controls >= 2,
        "only {total_controls} recording(s) in the corpus exercised the silent-fault control; a \
         corpus where the control never runs is a corpus with no control"
    );
}

/// The 8-byte `events.log` magic the legacy writer emits before the chunks.
const EVENTS_HEADER_V1: [u8; 8] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];

/// The largest chunk boundary in `log` at or below `target` bytes.
///
/// A chunked stream is a sequence of `[compressed_size: u32][events: u32]
/// [first_geid: u64]` headers each followed by `compressed_size` bytes, so the
/// boundaries are walked rather than guessed. Returns `log.len()` if no
/// interior boundary is below `target`.
fn chunk_boundary_near(log: &[u8], target: usize) -> usize {
    let header = EVENTS_HEADER_V1.len();
    assert_eq!(
        &log[..header],
        &EVENTS_HEADER_V1,
        "the fixture's events.log lost its magic"
    );
    let mut offset = header;
    let mut best = log.len();
    while offset + 16 <= log.len() {
        let size = u32::from_le_bytes([log[offset], log[offset + 1], log[offset + 2], log[offset + 3]]) as usize;
        let end = offset + 16 + size;
        if end > log.len() {
            break;
        }
        if end <= target && end < log.len() {
            best = end;
        }
        offset = end;
    }
    best
}

/// CCP-5 deliverable 2, the OTHER branch: CCP-3 (store nothing derivable) is
/// DEFERRED, so a compact container may legitimately CARRY a derived index.
/// When it does, the loader must LOAD it rather than rebuild it — and the
/// compact and full containers of that recording must still agree.
///
/// Both branches are needed because "load what is there, materialise what is
/// absent" is a CHOICE, and a test that only ever saw the absent branch would
/// not have seen the choice being made. The arm above covers the absent branch.
///
/// # A capability difference this arm had to be rebuilt around, recorded
/// because it looks like a defect and is not
///
/// The pair compared here is a compact container and a full container carrying
/// the SAME members — INCLUDING `step-map.ns`. The first version of this arm
/// compared the index-carrying compact container against the index-free full
/// one and went red on `max_line_over_steps`, which answers `None` without a
/// complete `step-map.ns` and `Some` with one. That is correct behaviour on
/// both sides: a range maximum cannot be answered from a partial index, so the
/// reader refuses rather than returning a wrong number. What the red arm had
/// actually found is that ADDING a member changes what a container can answer,
/// so "of the same recording" has to mean the same MEMBERS and not merely the
/// same events. The expectation was stale, not the code.
#[test]
fn test_a_compact_container_that_carries_its_derived_index_is_loaded_not_rebuilt() {
    let dir = tempfile::tempdir().expect("tempdir");
    let events = fixture_events();
    let oracle_path = common::legacy_events_log::write_legacy_events_log_bundle(dir.path(), "ccp5_idx_src", &events);
    let oracle = CTFSTraceReader::open(&oracle_path).expect("the oracle opens");
    assert!(
        !oracle.has_prepopulated_step_map(),
        "the source fixture must NOT carry step-map.ns; it is the oracle for the index \
         content, not a second copy of it"
    );
    assert_eq!(
        oracle.max_line_over_steps(StepId(0), StepId(oracle.step_count() as i64)),
        None,
        "without a complete step-map.ns a range maximum must be refused, not guessed — this \
         is the capability the member below adds"
    );

    // The index the full load MATERIALISED, serialised into the very format a
    // writer would have stored. Taken from the oracle rather than written by
    // hand: a stored index that disagrees with the streams it indexes is the
    // defect, and this one agrees by construction.
    let mut entries: Vec<(PathId, usize, Vec<StepId>)> = Vec::new();
    for p in 0..oracle.path_count() {
        if let Some(by_line) = oracle.step_map_for_path(PathId(p)) {
            for (line, steps) in by_line {
                entries.push((PathId(p), *line, steps.iter().map(|s| s.step_id).collect()));
            }
        }
    }
    assert!(
        entries.len() > 3,
        "the fixture materialised only {} (path, line) entries; an index with nothing in it \
         cannot be shown to be used",
        entries.len()
    );
    let index = db_backend::ctfs_trace_reader::step_map_namespace::serialize_step_map(&entries);

    // One member list, two containers.
    let mut members = members_of(&oracle_path);
    members.push(("step-map.ns".to_owned(), index.clone()));
    let compact_path = write_compact(dir.path(), "ccp5_idx_compact", &members);
    let full_path = dir.path().join("ccp5_idx_full.ct");
    {
        let refs: Vec<(&str, &[u8])> = members.iter().map(|(n, d)| (n.as_str(), d.as_slice())).collect();
        write_minimal_ctfs(&full_path, &refs).expect("the full writer writes");
    }

    let ctfs = CtfsReader::open(&compact_path).expect("it opens");
    assert_eq!(ctfs.profile(), CtfsProfile::Compact);
    assert!(ctfs.has_file("step-map.ns"), "the member did not land in the directory");

    let compact_reader = CTFSTraceReader::open(&compact_path).expect("the compact reader opens");
    let full_reader = CTFSTraceReader::open(&full_path).expect("the full reader opens");
    for (label, reader) in [("compact", &compact_reader), ("full", &full_reader)] {
        assert!(
            reader.has_prepopulated_step_map(),
            "the {label} container carries step-map.ns but was loaded WITHOUT its index: the \
             derived data it ships was rebuilt instead of read, which is the half of deliverable \
             2 that is about loading what is there"
        );
        assert_eq!(
            reader.step_map().map(|ns| ns.entry_count()),
            Some(entries.len()),
            "the {label} container's loaded index does not carry the entries it was built from"
        );
        assert!(
            reader
                .max_line_over_steps(StepId(0), StepId(reader.step_count() as i64))
                .is_some(),
            "the {label} container's index is reported present but answers no range maximum, so \
             it is a flag rather than a read path"
        );
    }

    let diffs = surface_differences(&compact_reader, &full_reader);
    assert!(
        diffs.is_empty(),
        "a compact container and a full container carrying the SAME members (derived index \
         included) disagree on {} methods:\n{}",
        diffs.len(),
        diffs.join("\n")
    );
    println!(
        "load-what-is-there: step-map.ns ({} bytes, {} entries) loaded from the compact \
         directory; zero differences against the full container of the same members",
        index.len(),
        entries.len()
    );

    // CONTROL — the stored index must actually be CONSULTED. Drop one step id
    // from one line and the answers must change; otherwise the loader reported
    // the index as present while answering from the rebuild, and every
    // assertion above would have been measuring a flag.
    let victim = entries
        .iter()
        .position(|(_, _, ids)| ids.len() > 1)
        .expect("the fixture has a line with several steps on it — that is why its lines repeat");
    let mut perturbed = entries.clone();
    let dropped = perturbed[victim].2.pop().expect("the victim line has a step to drop");
    let bad_index = db_backend::ctfs_trace_reader::step_map_namespace::serialize_step_map(&perturbed);
    let mut bad_members = members_of(&oracle_path);
    bad_members.push(("step-map.ns".to_owned(), bad_index));
    let bad_path = write_compact(dir.path(), "ccp5_idx_bad", &bad_members);

    let bad = CTFSTraceReader::open(&bad_path).expect("the perturbed container opens cleanly");
    assert!(bad.has_prepopulated_step_map(), "the perturbed index is still an index");
    let (victim_path, victim_line, _) = &entries[victim];
    assert_ne!(
        bad.step_ids_on_line(*victim_path, *victim_line),
        full_reader.step_ids_on_line(*victim_path, *victim_line),
        "dropping step {dropped:?} from the stored index changed nothing, so the stored index is \
         not being consulted"
    );
    let bad_diffs = surface_differences(&bad, &full_reader);
    assert!(
        !bad_diffs.is_empty(),
        "a compact container carrying a WRONG derived index compared equal to the full one; the \
         comparison cannot see the index at all"
    );
    println!(
        "control: dropping one step id from the stored step-map.ns is caught on {} method(s) \
         (first: {})",
        bad_diffs.len(),
        bad_diffs[0].lines().next().unwrap_or_default()
    );
}

/// The BROWSER door, which is the one CCP-6 will actually use: a compact
/// container handed to the reader as BYTES, with no filesystem path at all.
///
/// `CTFSTraceReader::from_bytes` is the only browser-reachable constructor, and
/// a compact archive arrives there decompressed by the browser and never
/// touches a path. So it is worth checking separately rather than assuming the
/// path-based arm covers it: the two constructors differ in exactly one thing
/// (the `<ct>.step-map.ns` SIDECAR, which only a filesystem caller can see),
/// and a loader that resolved members relative to a path rather than to the
/// image would have passed every other arm in this file.
#[test]
fn test_a_compact_container_loads_from_bytes_with_no_path() {
    let dir = tempfile::tempdir().expect("tempdir");
    let events = fixture_events();
    let full_path = common::legacy_events_log::write_legacy_events_log_bundle(dir.path(), "ccp5_bytes", &events);
    let members = members_of(&full_path);
    let compact_path = write_compact(dir.path(), "ccp5_bytes_compact", &members);

    let image = std::fs::read(&compact_path).expect("read the compact image");
    let from_bytes = CTFSTraceReader::from_bytes(image.clone()).expect("the browser door opens a compact container");
    let from_path = CTFSTraceReader::open(&compact_path).expect("the filesystem door opens it too");

    let diffs = surface_differences(&from_bytes, &from_path);
    assert!(
        diffs.is_empty(),
        "the same compact image answers differently through from_bytes and through open on {} \
         methods:\n{}",
        diffs.len(),
        diffs.join("\n")
    );

    // CONTROL: the bytes are what is being read. One byte of the LAST member's
    // payload flipped must change an answer — and must not change the
    // directory, so the container still opens.
    let mut flipped = image;
    let last = flipped.len() - 1;
    flipped[last] ^= 0xFF;
    match CTFSTraceReader::from_bytes(flipped) {
        Ok(reader) => {
            let flipped_diffs = surface_differences(&reader, &from_path);
            assert!(
                !flipped_diffs.is_empty(),
                "flipping the last byte of the last member changed nothing the whole query \
                 surface can see, so from_bytes is not reading the bytes it was given"
            );
            println!(
                "from_bytes: {} bytes, zero differences against open; flipping the last payload \
                 byte is caught on {} method(s)",
                last + 1,
                flipped_diffs.len()
            );
        }
        Err(e) => {
            // Also an acceptable outcome, and a visible one: the flip landed
            // inside a structure the loader validates.
            println!("from_bytes: flipping the last payload byte is REFUSED at open: {e}");
        }
    }
}
