//! M50 — step-over must not stall on a FRAMELESS step.
//!
//! Spec:
//!   `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org` §M50.
//!
//! # The defect
//!
//! `TraceReader::step_over_depths_step_id` — the shared depth-filtered
//! primitive behind DAP `next` (step over) and `stepOut` for every
//! materialised (DB-trace) backend — used to bail out and return the
//! START step whenever the start step's `call_key` did not resolve to a
//! recorded `DbCall`:
//!
//! ```text
//! let Some(initial_call) = self.call(initial_step.call_key) else {
//!     return start_step_id;   // <- "no successor", forever
//! };
//! ```
//!
//! Steps with an unresolvable `call_key` are not corrupt — they are
//! FRAMELESS steps, and event-driven runtimes record them routinely.
//! The JavaScript recorder emits them for the bootstrap steps that
//! precede the `<module>` frame and, crucially, for the event-loop-level
//! steps between one callback returning and the next being entered.
//! The moment the module's top-level frame closed, the cursor landed on
//! such a step and step-over reported "nothing to step to" on every
//! subsequent press — while step-into and continue both advanced from
//! the identical position, because neither consults call depth.
//!
//! User impact: after running to entry and stepping through a Node
//! module body, pressing F10 held the cursor on the module's last
//! statement forever. Nothing scheduled by the module — which is most of
//! an event-driven program — was reachable with step-over alone.
//!
//! # What this file pins
//!
//! * `step_over_from_a_frameless_step_advances` — a synthetic,
//!   language-agnostic trace shaped like an event-driven program
//!   (top-level frame, frameless event-loop steps, then a callback
//!   frame). Step-over must walk off the end of the top-level frame,
//!   across the frameless region, and into the callback. This is the
//!   unit-level pin on the shared primitive: it fails on the old code at
//!   the FIRST step-over issued from a frameless step.
//!
//! * `step_over_skips_a_deeper_callee_from_a_frameless_step` — the
//!   control. Giving frameless steps an effective depth must not turn
//!   step-over into step-into: from a frameless step, a deeper callee
//!   frame is still stepped OVER.
//!
//! * `step_over_advances_past_the_last_top_level_statement` — the M50
//!   reproduction driven end-to-end through the real DAP server against
//!   the committed `backend.ct` recording (a real `codetracer-js-recorder`
//!   trace; no recorder needed to replay it). Run to entry, then press
//!   `next` the way the GUI's F10 does, and assert the cursor never
//!   stalls before the end of the recording — in particular that it
//!   leaves `server.js:108` (`idleTimer.unref();`, the module's last
//!   top-level statement) within one press.
//!
//! # Mocking
//!
//! None. The synthetic tests build a real `Db` and drive the production
//! `Handler::next_dap` over a real `InMemoryTraceReader`; the fixture
//! test spawns the real `replay-server` binary and speaks real DAP to it
//! over stdio.
//!
//! Compile/run:
//!   cargo test --manifest-path src/db-backend/Cargo.toml --test m50_step_over_frameless_step_test

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

mod test_harness;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;
use std::time::Duration;

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::dap::{DapMessage, ProtocolMessage, Request};
use db_backend::dap_handler::Handler;
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram};
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::TraceKind;
use db_backend::trace_reader::TraceReader;
use test_harness::DapStdioTestClient;

// ── Synthetic trace ─────────────────────────────────────────────────────────

/// `CallKey` sentinel the loaders use for a step no recorded call
/// encloses (`build_step_call_maps` initialises every slot to it and
/// only overwrites the slots covered by a call range).
const NO_CALL: CallKey = CallKey(-1);

const RECORDED_FILE: &str = "server.js";

/// Description of one recorded step in the synthetic trace.
struct StepSpec {
    line: i64,
    call: CallKey,
}

/// Build a materialised trace shaped like a recorded Node module.
///
/// ```text
///   step  line  frame            what it models
///   ----  ----  ---------------  ------------------------------------------
///     0     1   <module>  d=0    first top-level statement
///     1     2   <module>  d=0    second top-level statement
///     2     3   <module>  d=0    LAST top-level statement
///     3     3   (none)           module frame closed; event loop resumes
///     4     5   (none)           event loop about to enter the callback
///     5     6   <callback> d=0   callback body
///     6     7   <callback> d=0   callback body
/// ```
///
/// When `with_nested_callee` is set, a DEEPER frame (`depth = 1`) is
/// spliced in between the two frameless steps, so the control test can
/// assert that step-over from a frameless step still steps OVER a
/// deeper call rather than into it.
fn build_event_loop_trace(trace_dir: &PathBuf, with_nested_callee: bool) -> Arc<dyn TraceReader> {
    let recorded = trace_dir.join(RECORDED_FILE).display().to_string();
    let mut db = Db::new(trace_dir);

    // PathId(0) is the reserved sentinel slot used by the canonical CTFS
    // loader; PathId(1) is the absolute recorded path.
    db.paths.push(String::new());
    db.paths.push(recorded.clone());
    db.path_map.insert(recorded.clone(), PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "int".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    // FunctionId(0) `<module>`, FunctionId(1) `<callback>`, FunctionId(2) the
    // nested callee used only by the control test.
    for (name, line) in [("<module>", 1), ("<callback>", 6), ("<nested>", 20)] {
        db.functions.push(FunctionRecord {
            path_id: PathId(1),
            line: Line(line),
            name: name.to_string(),
        });
    }

    // Both the module frame and the callback frame are recorded at depth
    // 0 with no parent: the event loop drives them, and the loop itself
    // is not a recorded call. This mirrors the real JS recorder shape.
    let push_call = |db: &mut Db, key: i64, function_id: usize, step_id: i64, depth: usize, parent: CallKey| {
        db.calls.push(DbCall {
            key: CallKey(key),
            function_id: FunctionId(function_id),
            args: Vec::new(),
            return_value: ValueRecord::None { type_id: TypeId(0) },
            step_id: StepId(step_id),
            depth,
            parent_key: parent,
            children_keys: Vec::new(),
        });
    };
    push_call(&mut db, 0, 0, 0, 0, NO_CALL); // <module>
    push_call(&mut db, 1, 1, 5, 0, NO_CALL); // <callback>
    if with_nested_callee {
        push_call(&mut db, 2, 2, 4, 1, CallKey(1)); // <nested>, one level deeper
    }

    // The control variant splices the deeper callee's steps in where the
    // second frameless step would otherwise be, so that the first
    // same-or-shallower candidate after the frameless step at index 3 is
    // reached only by skipping a deeper frame.
    let specs: Vec<StepSpec> = if with_nested_callee {
        vec![
            StepSpec {
                line: 1,
                call: CallKey(0),
            },
            StepSpec {
                line: 2,
                call: CallKey(0),
            },
            StepSpec {
                line: 3,
                call: CallKey(0),
            },
            StepSpec { line: 3, call: NO_CALL },
            StepSpec {
                line: 20,
                call: CallKey(2),
            },
            StepSpec {
                line: 21,
                call: CallKey(2),
            },
            StepSpec {
                line: 6,
                call: CallKey(1),
            },
            StepSpec {
                line: 7,
                call: CallKey(1),
            },
        ]
    } else {
        vec![
            StepSpec {
                line: 1,
                call: CallKey(0),
            },
            StepSpec {
                line: 2,
                call: CallKey(0),
            },
            StepSpec {
                line: 3,
                call: CallKey(0),
            },
            StepSpec { line: 3, call: NO_CALL },
            StepSpec { line: 5, call: NO_CALL },
            StepSpec {
                line: 6,
                call: CallKey(1),
            },
            StepSpec {
                line: 7,
                call: CallKey(1),
            },
        ]
    };

    let mut step_map_for_path: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for (index, spec) in specs.iter().enumerate() {
        let step = DbStep {
            step_id: StepId(index as i64),
            path_id: PathId(1),
            line: Line(spec.line),
            // The recorder anchors every one of these at the statement's
            // start column; the value is irrelevant to line-granularity
            // `next` and is kept uniform so the test isolates the frame
            // handling under test.
            column: Some(Line(1)),
            call_key: spec.call,
            global_call_key: spec.call,
        };
        db.steps.push(step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
        step_map_for_path.entry(spec.line as usize).or_default().push(step);
    }

    db.step_map.push(HashMap::new()); // PathId(0) sentinel
    db.step_map.push(step_map_for_path);
    db.end_of_program = EndOfProgram::Normal;

    Arc::new(InMemoryTraceReader::new(db))
}

/// Issue a DAP `next` (line granularity — what the GUI's F10 sends)
/// through the production handler and return where the cursor landed.
fn dap_next(handler: &mut Handler) -> StepId {
    let (tx, rx) = mpsc::channel::<DapMessage>();
    let request = Request {
        base: ProtocolMessage {
            seq: 1,
            type_: "request".to_string(),
        },
        command: "next".to_string(),
        arguments: serde_json::json!({ "threadId": 1 }),
    };
    handler.next_dap(request, None, tx).expect("dap next succeeds");
    while rx.try_recv().is_ok() {}
    handler.step_id
}

/// Walk the trace with `presses` successive DAP `next` requests from
/// the trace's entry (step 0) and return the step the cursor landed on
/// after each one.
///
/// Starting from step 0 rather than seeking is deliberate: the handler
/// and the replay session each carry their own cursor, and only the
/// production request path keeps them in sync. Walking from the entry
/// exercises exactly what the GUI does — run to entry, then F10.
fn step_over_trail(reader: Arc<dyn TraceReader>, presses: usize) -> Vec<StepId> {
    let mut handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    handler.step_id = StepId(0);
    (0..presses).map(|_| dap_next(&mut handler)).collect()
}

fn temp_trace_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("m50_{tag}_{}", std::process::id()));
    if !dir.exists() {
        std::fs::create_dir_all(&dir).expect("create trace dir");
    }
    dir
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// STRICT — step-over must cross the end of the top-level frame.
///
/// Five successive `next` requests from the entry must walk
/// 0 → 1 → 2 → 3 → 4 → 5: through the module's top-level statements,
/// onto the frameless event-loop steps that follow the module frame's
/// close, and into the callback frame the module scheduled.
///
/// Against the pre-M50 code the walk dies at step 3: the first `next`
/// issued FROM a frameless step returned step 3 again, and so did every
/// subsequent one — the trail was `[1, 2, 3, 3, 3]`.
#[test]
fn step_over_from_a_frameless_step_advances() {
    let reader = build_event_loop_trace(&temp_trace_dir("frameless"), false);

    // Sanity — step 3 really is frameless, otherwise this test would
    // pass for the wrong reason.
    {
        let step = reader.step(StepId(3)).expect("step 3 exists");
        assert_eq!(step.call_key, NO_CALL, "step 3 must model a frameless step");
        assert!(
            reader.call(step.call_key).is_none(),
            "a frameless step's call_key must not resolve to a recorded call"
        );
        let callback_step = reader.step(StepId(5)).expect("step 5 exists");
        assert_eq!(
            callback_step.call_key,
            CallKey(1),
            "step 5 must model the scheduled callback's frame"
        );
    }

    let trail = step_over_trail(reader, 5);
    assert_eq!(
        trail,
        vec![StepId(1), StepId(2), StepId(3), StepId(4), StepId(5)],
        "step-over must walk off the end of the module frame, across the \
         frameless event-loop steps, and into the callback the module \
         scheduled; got {trail:?}"
    );
}

/// STRICT (control) — a frameless step is the OUTERMOST level, not a
/// bypass of the depth filter.
///
/// After reaching the frameless step at index 3 the next `next` must
/// step OVER the `depth = 1` callee occupying steps 4-5 and land on
/// step 6, the next step at the outermost level. If frameless steps
/// were treated as "match anything", step-over would degenerate into
/// step-into here.
#[test]
fn step_over_skips_a_deeper_callee_from_a_frameless_step() {
    let reader = build_event_loop_trace(&temp_trace_dir("frameless_nested"), true);
    {
        let step = reader.step(StepId(4)).expect("step 4 exists");
        let call = reader.call(step.call_key).expect("step 4 has a call");
        assert_eq!(call.depth, 1, "steps 4-5 must model a deeper frame");
    }

    let trail = step_over_trail(reader, 5);
    assert_eq!(
        trail,
        vec![StepId(1), StepId(2), StepId(3), StepId(6), StepId(7)],
        "step-over from a frameless step must skip the deeper callee, not \
         descend into it; got {trail:?}"
    );
}

/// STRICT — `stepOut` shares the primitive, so its behaviour at a
/// frameless step is part of this change and is pinned here.
///
/// `step_out_step_id_relative_to` is `step_over_depths_step_id(.., delta = 1)`,
/// so giving a frameless START step an effective depth necessarily moves
/// `stepOut` too: it used to be a dead button at a frameless step
/// (`moved = false`), and now it behaves exactly as it already did at an
/// OUTERMOST recorded frame.  That equivalence is the whole point of the
/// chosen semantics, and it is asserted rather than assumed:
///
/// * from inside `<module>` (depth 0, steps 0-2) `stepOut` leaves the
///   frame and lands on the first frameless step, 3 — unchanged by M50;
/// * from the frameless step 3 it now behaves the same way, advancing to
///   the next step at the outermost level instead of refusing to move.
///
/// A `stepOut` at the outermost level has no caller to return to, so
/// "scan forward until the enclosing context ends" is the pre-existing
/// meaning this test locks in for frameless steps as well.  Without this
/// case, a future reader could restrict the fix to `delta == 0` and
/// reintroduce the asymmetry silently.
#[test]
fn step_out_from_a_frameless_step_matches_step_out_from_an_outermost_frame() {
    let reader = build_event_loop_trace(&temp_trace_dir("frameless_step_out"), false);

    let (from_module, module_moved) = reader.step_out_step_id_relative_to(StepId(2), true);
    assert_eq!(
        (from_module, module_moved),
        (StepId(3), true),
        "step-out from the outermost recorded frame must leave it (pre-M50 behaviour)"
    );

    let (from_frameless, frameless_moved) = reader.step_out_step_id_relative_to(StepId(3), true);
    assert!(
        frameless_moved,
        "step-out from a frameless step must not be a dead button; it is at the \
         same level as the outermost frame and must behave the same way"
    );
    assert_eq!(
        from_frameless,
        StepId(4),
        "step-out from a frameless step advances to the next step at the \
         outermost level, as it already did from an outermost frame"
    );
}

// ── End-to-end reproduction against a freshly recorded server ───────────────

/// A real `codetracer-js-recorder` trace of the demo's
/// `backend/server.js`, recorded from this tree when the test runs.
///
/// It used to be committed. That made this reproduction a check that
/// today's stepper agrees with a recorder that might have been replaced
/// since — and the stall this test pins lives at the seam between what
/// the recorder emits for a module's top level and what the stepper
/// does with it, which is exactly the seam a frozen recording hides.
/// `scripts/materialize-recording.sh` produces it once per build and
/// re-produces it whenever the recorder's bytes change.
fn backend_recording() -> PathBuf {
    test_harness::three_trace_recordings().join("backend.ct")
}

/// `server.js:108` is `idleTimer.unref();` — the last top-level
/// statement of the module, and where the M50 report saw the cursor
/// stall.
const LAST_TOP_LEVEL_LINE: i64 = 108;

/// Press DAP `next` and read the resulting `(line, step)` off the
/// `ct/complete-move` event — the only message carrying the post-step
/// location.
fn next_location(client: &mut DapStdioTestClient) -> (i64, i64) {
    let request = client
        .dap_client_mut()
        .request("next", serde_json::json!({ "threadId": 1 }));
    client.send_message(&request).expect("send next");
    let event = client
        .read_until_event_msg("ct/complete-move", Duration::from_secs(30))
        .expect("ct/complete-move after next");
    match event {
        DapMessage::Event(e) => {
            let location = &e.body["location"];
            (
                location["line"].as_i64().expect("location.line"),
                location["rrTicks"].as_i64().expect("location.rrTicks"),
            )
        }
        other => panic!("expected ct/complete-move event, got {other:?}"),
    }
}

/// STRICT — the M50 reproduction, end to end through the real DAP
/// server: run to entry on `backend.ct`, then press step-over the way
/// the GUI's F10 does.
///
/// The recorded trail before the fix was
/// `19 → 22 → 24 → 27 → 35 → 57 → 77 → 93 → 101 → 102 → 108 → 108`
/// and then `108` for ever. The assertions below are deliberately shaped
/// as invariants rather than a pinned trail, so recorder changes that
/// alter the exact statement sequence do not turn this into a
/// change-detector:
///
///   1. the cursor must leave line 108 within a single press, and
///   2. the walk must never stall — every press must either advance the
///      step id or have reached the final recorded step.
#[test]
fn step_over_advances_past_the_last_top_level_statement() {
    let recording = backend_recording();
    assert!(
        recording.join("server.ct").exists(),
        "the recorder produced {} without a CTFS container — the JS recorder \
         changed shape and this test no longer has an input",
        recording.display()
    );

    let mut client = DapStdioTestClient::start().expect("start db-backend dap-server");
    client
        .initialize_and_launch_trace(&recording)
        .expect("launch backend.ct");

    // Generous cap: the recording is ~57 steps, so a healthy walk ends
    // well inside it, and a stalled walk is detected on the press after
    // the first repeat rather than by exhausting the budget.
    const MAX_PRESSES: usize = 60;
    let mut trail: Vec<(i64, i64)> = Vec::new();
    let mut previous: Option<(i64, i64)> = None;
    let mut left_last_top_level_line = false;

    for press in 0..MAX_PRESSES {
        let landed = next_location(&mut client);
        if let Some((prev_line, prev_step)) = previous {
            if prev_line == LAST_TOP_LEVEL_LINE {
                assert_ne!(
                    landed.1, prev_step,
                    "press {press}: step-over at server.js:{LAST_TOP_LEVEL_LINE} (the module's \
                     last top-level statement, step #{prev_step}) did not move — this is the M50 \
                     stall. Trail so far: {trail:?}"
                );
                left_last_top_level_line = true;
            }
            if landed == (prev_line, prev_step) {
                // Reaching the end of the recording is the only legitimate
                // way for step-over to stop moving.
                break;
            }
        }
        trail.push(landed);
        previous = Some(landed);
    }

    assert!(
        trail.iter().any(|(line, _)| *line == LAST_TOP_LEVEL_LINE),
        "the walk never reached server.js:{LAST_TOP_LEVEL_LINE}; the fixture or the entry point \
         changed. Trail: {trail:?}"
    );
    assert!(
        left_last_top_level_line,
        "step-over never left server.js:{LAST_TOP_LEVEL_LINE}. Trail: {trail:?}"
    );

    // Beyond simply moving: the walk must actually enter the event-loop
    // turns the module scheduled. Every line the module's top-level body
    // occupies is <= 108, so a strictly-later portion of the trace can
    // only be reached by crossing out of the module frame — and the
    // callback bodies the module registered all live on earlier lines,
    // so we assert on the recorded step id, which is monotonic in
    // execution order.
    let final_step = trail.last().expect("at least one step-over").1;
    let last_top_level_step = trail
        .iter()
        .find(|(line, _)| *line == LAST_TOP_LEVEL_LINE)
        .expect("the walk reached line 108")
        .1;
    assert!(
        final_step > last_top_level_step,
        "step-over must reach recorded steps AFTER the module body (step #{last_top_level_step}); \
         it stopped at step #{final_step}. Trail: {trail:?}"
    );
}
