//! `BranchState` on the flow payload — the first test this crate has ever had
//! for it.
//!
//! # Why this file exists
//!
//! `GUI/Debugging-Features/Omniscience-Flow.md` § *Branch State Highlighting*
//! specifies that the backend attaches a `BranchState`
//! (`Unknown | Taken | NotTaken`) to source lines and ships it on
//! `FlowViewUpdate.branches_taken[loop_id][iteration]`, and the frontend paints
//! each entry `flow-taken` / `flow-not-taken`. Issue #758 reports that the
//! not-taken arm never colours. Before this file there was **no test anywhere
//! in `src/db-backend/tests/` naming `branches_taken` or `BranchState`**, so
//! "the backend does not produce `NotTaken`" and "the frontend does not render
//! it" could not be told apart. That is the diagnostic this file settles, and
//! it settles it at the backend boundary — the same payload the DAP
//! `ct/flow-update` event carries.
//!
//! § *Known defect (2026-08-30)* describes a scratch test of exactly this
//! shape, driven by "a scripted `ReplaySession` whose step list *is* the ground
//! truth, over generated Rust fixtures of the shape `if … { } else { }` where
//! the recording takes the **else** arm". It was never committed. This is that
//! test, committed.
//!
//! # No mocks, and what "hermetic" costs here
//!
//! There is no mock object in this file. The production `FlowPreloader::load`
//! runs, the production `ExprLoader` parses the fixture with the real
//! tree-sitter Rust grammar off the real filesystem, and the production
//! `MaterializedReplaySession` walks the steps. What is synthesised is the
//! **recording** — an in-memory `Db` of the shape the CTFS loader produces —
//! exactly as `dap_column_flow.rs` and `dap_column_breakpoint.rs` already do,
//! because the alternative is a `rustc` + `rr` recording that skips on every
//! machine without them (`rust_flow_integration.rs` skips three different
//! ways). A synthesised step list is also the only way to state the ground
//! truth this test is about: "the run took the `else` arm" has to be a fact of
//! the fixture, not something inferred from the thing under test.
//!
//! Run with:
//!     cargo test --test flow_branch_state_test -- --nocapture

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::{
    CallKey, FunctionId, FunctionRecord, Line, PathId, StepId, TypeId, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
use db_backend::db::{Db, DbCall, DbStep, EndOfProgram, MaterializedReplaySession};
use db_backend::flow_preloader::FlowPreloader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::task::{BranchState, FlowMode, FlowUpdate, Location, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;

// ── Fixtures ────────────────────────────────────────────────────────────────

/// A conditional at the top level of `main`, with the recording taking the
/// **else** arm.
///
/// Line numbers are 1-based and load-bearing, so they are named rather than
/// counted at the call site:
///
/// * line 3 — `if n > 10 {`, the `if` header
/// * line 5 — `} else {`, the `else` header
/// * line 6 — the first line of the else BODY, which is where the walker lands
///   and therefore the key `position_branches` is built on
///   (`expr_loader.rs::process_file` maps `code_first_line -> Branch`)
const PLAIN_SOURCE: &str = r#"fn main() {
    let n: i64 = 3;
    if n > 10 {
        let big: i64 = n * 2;
    } else {
        let small: i64 = n + 1;
    }
    let done: i64 = n;
}
"#;

const PLAIN_IF_HEADER: usize = 3;
const PLAIN_ELSE_HEADER: usize = 5;
/// Steps the run executes, in order, as (step id, source line).
const PLAIN_STEPS: [(i64, i64); 4] = [(0, 2), (1, 3), (2, 6), (3, 8)];

/// THE REPORTER'S SHAPE: the same conditional, inside a loop.
///
/// #758 is reported as *"in a loop with an `if`"*, and that is not a cosmetic
/// difference — it moves the branch state out of `branches_taken[0][0]` and
/// into `branches_taken[loop][iteration]`, which is a different table, written
/// by a different call, and read by a different pass of the frontend.
///
/// * line 4 — `while i < 2 {`, the loop header
/// * line 5 — `if i > 5 {`, the `if` header (never true: the else arm runs)
/// * line 7 — `} else {`, the `else` header
/// * line 8 — first line of the else body
const LOOP_SOURCE: &str = r#"fn main() {
    let mut total: i64 = 0;
    let mut i: i64 = 0;
    while i < 2 {
        if i > 5 {
            total = total + 100;
        } else {
            total = total + 1;
        }
        i = i + 1;
    }
    let done: i64 = total;
}
"#;

const LOOP_IF_HEADER: usize = 5;
const LOOP_ELSE_HEADER: usize = 7;
/// Two passes of the loop body, each taking the `else` arm.
const LOOP_STEPS: [(i64, i64); 12] = [
    (0, 2),
    (1, 3),
    (2, 4),
    (3, 5),
    (4, 8),
    (5, 10),
    (6, 4),
    (7, 5),
    (8, 8),
    (9, 10),
    (10, 4),
    (11, 12),
];

/// THE ISSUE'S OWN PROGRAM. #758 pastes it:
///
/// ```text
/// for i in 0..10 {
///   if i % 3 == 0 {        <- Shows GREEN when condition is true
///     result = result + y;
///   }
///   // But when i % 3 != 0, no RED indicator appears
/// }
/// ```
///
/// The `if` has **no `else`**, and that is the whole difference from the
/// fixture above. `extract_branches` links `Branch.opposite` only between an
/// arm and its siblings, so a lone `if` has an empty `opposite` — and
/// `load_branch_for_position`, the only SOUND producer of `NotTaken`, derives
/// every `NotTaken` it emits from `opposite`. A conditional with one arm can
/// therefore never be proved declined by the walk, only by the sweep.
///
/// * line 4 — `while i < 4 {`, the loop header
/// * line 5 — `if i % 3 == 0 {`, the only arm
/// * line 6 — its body, entered on iterations 0 and 3 and skipped on 1 and 2
const LONE_IF_SOURCE: &str = r#"fn main() {
    let mut result: i64 = 0;
    let mut i: i64 = 0;
    while i < 4 {
        if i % 3 == 0 {
            result = result + 1;
        }
        i = i + 1;
    }
    let done: i64 = result;
}
"#;

const LONE_IF_HEADER: usize = 5;
/// Four passes: the body runs on iteration 0 and 3, and is skipped on 1 and 2.
const LONE_IF_STEPS: [(i64, i64); 18] = [
    (0, 2),
    (1, 3),
    // i = 0 — taken
    (2, 4),
    (3, 5),
    (4, 6),
    (5, 8),
    // i = 1 — declined
    (6, 4),
    (7, 5),
    (8, 8),
    // i = 2 — declined
    (9, 4),
    (10, 5),
    (11, 8),
    // i = 3 — taken
    (12, 4),
    (13, 5),
    (14, 6),
    (15, 8),
    // loop exit
    (16, 4),
    (17, 10),
];

/// A lone `if` the run ENTERS, whose header line the walk then reports a second
/// time — the shape that makes the per-step rule's inference unsound if it is
/// allowed to outvote a sighting.
///
/// * line 3 — `if a == 1 {`, the header
/// * line 4 — the arm's body, which the run enters
const REVISITED_SOURCE: &str = r#"fn main() {
    let a: i64 = 1;
    if a == 1 {
        let inner: i64 = 5;
    }
    let done: i64 = a;
}
"#;

const REVISITED_IF_HEADER: usize = 3;
/// The header is stepped, the arm runs, and the header is reported AGAIN before
/// the walk moves past the conditional.
const REVISITED_STEPS: [(i64, i64); 5] = [(0, 2), (1, 3), (2, 4), (3, 3), (4, 6)];

// ── Fixture construction ────────────────────────────────────────────────────

/// THE FIXTURE IS WHAT THIS TEST SAYS IT IS.
///
/// The header-line constants above are the whole content of the assertions, so
/// they are checked against the source text rather than trusted. An edit to a
/// fixture string reddens here instead of silently retargeting the test at
/// whatever now lives on those lines.
fn assert_fixture_shape(source: &str, if_header: usize, else_header: usize) {
    let lines: Vec<&str> = source.lines().collect();
    assert!(
        lines.len() >= else_header,
        "fixture has {} lines, fewer than the {} this test targets",
        lines.len(),
        else_header
    );
    assert!(
        lines[if_header - 1].trim_start().starts_with("if "),
        "line {} is not the `if` header, it is {:?}",
        if_header,
        lines[if_header - 1]
    );
    assert!(
        lines[else_header - 1].trim() == "} else {",
        "line {} is not the `else` header, it is {:?}",
        else_header,
        lines[else_header - 1]
    );
}

fn write_fixture(dir: &Path, name: &str, source: &str) -> PathBuf {
    std::fs::create_dir_all(dir).expect("mkdir fixture dir");
    let path = dir.join(name);
    std::fs::write(&path, source).expect("write fixture");
    path
}

/// Build the in-memory materialised recording for `steps`.
///
/// Mirrors `dap_column_flow.rs::build_trace`: `PathId(0)` is the reserved
/// sentinel the CTFS loader leaves empty, `PathId(1)` is the recorded absolute
/// path. Every step belongs to one call, which is what makes the flow walker's
/// call-key delimiter end the walk at the end of the step list.
fn build_reader(trace_dir: &Path, recorded: &Path, steps: &[(i64, i64)]) -> Arc<dyn TraceReader> {
    let recorded_str = recorded.display().to_string();
    let mut db = Db::new(&trace_dir.to_path_buf());

    db.paths.push(String::new());
    db.paths.push(recorded_str.clone());
    db.register_path_version(recorded_str, PathId(1));

    db.types.push(TypeRecord {
        kind: TypeKind::Int,
        lang_type: "i64".to_string(),
        specific_info: TypeSpecificInfo::None,
    });

    db.functions.push(FunctionRecord {
        path_id: PathId(1),
        line: Line(1),
        name: "main".to_string(),
    });

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

    let db_steps: Vec<DbStep> = steps
        .iter()
        .map(|(id, line)| DbStep {
            step_id: StepId(*id),
            path_id: PathId(1),
            line: Line(*line),
            column: None,
            call_key,
            global_call_key: call_key,
        })
        .collect();

    for step in &db_steps {
        db.steps.push(*step);
        db.variables.push(Vec::new());
        db.instructions.push(Vec::new());
        db.compound.push(HashMap::new());
        db.cells.push(HashMap::new());
        db.variable_cells.push(HashMap::new());
    }

    db.step_map.push(HashMap::new());
    let mut path1_map: HashMap<usize, Vec<DbStep>> = HashMap::new();
    for step in &db_steps {
        path1_map.entry(step.line.0 as usize).or_default().push(*step);
    }
    db.step_map.push(path1_map);

    db.end_of_program = EndOfProgram::Normal;

    Arc::new(InMemoryTraceReader::new(db))
}

/// Drive the production flow load over the fixture, entering at its first step.
fn load_flow(recorded: &Path, reader: Arc<dyn TraceReader>, entry_line: i64) -> FlowUpdate {
    let path = recorded.display().to_string();
    let location = Location {
        path: path.clone(),
        high_level_path: path,
        line: entry_line,
        high_level_line: entry_line,
        rr_ticks: RRTicks(0),
        ..Location::default()
    };
    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay)
}

/// Every `(loop, iteration, line) -> state` the payload carries, printed and
/// returned flat. The diagnostic wants the whole table, not one lookup: "the
/// state is in a different cell of `branches_taken` than the reader looks in"
/// and "the state was never produced" are different defects with different
/// owners, and only the whole table tells them apart.
fn dump_branches(update: &FlowUpdate) -> Vec<(usize, usize, usize, BranchState)> {
    let mut out = Vec::new();
    assert!(!update.view_updates.is_empty(), "no view updates: there is no window");
    let view = &update.view_updates[0];
    println!(
        "  window: {}..{} ({} steps, {} loops, branches_taken dims {})",
        view.location.function_first,
        view.location.function_last,
        view.steps.len(),
        view.loops.len(),
        view.branches_taken.len()
    );
    for (loop_id, iterations) in view.branches_taken.iter().enumerate() {
        for (iteration, taken) in iterations.iter().enumerate() {
            let mut entries: Vec<(&usize, &BranchState)> = taken.table.iter().collect();
            entries.sort_by_key(|(line, _)| **line);
            println!("  branches_taken[{loop_id}][{iteration}] = {entries:?}");
            let mut extents: Vec<_> = taken.extents.iter().collect();
            extents.sort_by_key(|(line, _)| **line);
            println!("  extents[{loop_id}][{iteration}]        = {extents:?}");
            for (line, state) in entries {
                out.push((loop_id, iteration, *line, *state));
            }
        }
    }
    out
}

fn state_at(entries: &[(usize, usize, usize, BranchState)], line: usize) -> Vec<(usize, usize, BranchState)> {
    entries
        .iter()
        .filter(|(_, _, l, _)| *l == line)
        .map(|(lp, it, _, s)| (*lp, *it, *s))
        .collect()
}

fn temp_dir(tag: &str) -> PathBuf {
    let dir = PathBuf::from(format!(
        "{}/test-traces/flow_branch_state_{}_{}",
        env!("CARGO_MANIFEST_DIR"),
        tag,
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// The sound producer: a run that took the `else` arm must report the `if`
/// header `NotTaken`.
///
/// This is `load_branch_for_position`'s claim and it is a proof, not a
/// heuristic: exactly one arm of a conditional runs per evaluation, so
/// observing the `else` body run settles the `if`.
#[test]
fn a_declined_if_arm_is_reported_not_taken() {
    assert_fixture_shape(PLAIN_SOURCE, PLAIN_IF_HEADER, PLAIN_ELSE_HEADER);
    let dir = temp_dir("plain");
    let recorded = write_fixture(&dir, "branch_plain.rs", PLAIN_SOURCE);
    let reader = build_reader(&dir, &recorded, &PLAIN_STEPS);
    let update = load_flow(&recorded, reader, PLAIN_STEPS[0].1);
    assert!(!update.error, "flow update errored: {}", update.error_message);

    println!("plain if/else, run takes the else arm:");
    let entries = dump_branches(&update);

    // NON-VACUITY FIRST. An empty table satisfies every "is not Taken"
    // assertion, and an empty table is exactly the failure mode being
    // diagnosed.
    assert!(
        !entries.is_empty(),
        "branches_taken is empty for a Rust file with an if/else — the backend produced NO branch \
         state at all, so nothing downstream could render it"
    );

    let if_states = state_at(&entries, PLAIN_IF_HEADER);
    let else_states = state_at(&entries, PLAIN_ELSE_HEADER);
    assert!(
        !if_states.is_empty(),
        "no state recorded for the `if` header (line {PLAIN_IF_HEADER}); recorded lines: {entries:?}"
    );
    assert!(
        if_states.iter().all(|(_, _, s)| *s == BranchState::NotTaken),
        "the run took the `else` arm, so the `if` header (line {PLAIN_IF_HEADER}) must be NotTaken; got {if_states:?}"
    );
    assert!(
        else_states.iter().any(|(_, _, s)| *s == BranchState::Taken),
        "the run took the `else` arm, so its header (line {PLAIN_ELSE_HEADER}) must be Taken; got {else_states:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// THE REPORTER'S SHAPE. The same conditional inside a loop, with the `else`
/// arm taken on every pass.
///
/// Two things must hold, and the second is what #758 is about:
///
/// 1. the declined `if` header is `NotTaken` **somewhere** in the payload, and
/// 2. it is `NotTaken` in the table the frontend's outer pass reads —
///    `branches_taken[0][0]`, the only cell `conditionStyleLines` consults
///    unconditionally.
///
/// A state that exists only in `branches_taken[loop][iteration]` is a state the
/// renderer reaches only when the loop pass runs, which is gated on the loop
/// slider widget existing.
#[test]
fn a_declined_arm_inside_a_loop_is_reported_not_taken() {
    assert_fixture_shape(LOOP_SOURCE, LOOP_IF_HEADER, LOOP_ELSE_HEADER);
    let dir = temp_dir("loop");
    let recorded = write_fixture(&dir, "branch_loop.rs", LOOP_SOURCE);
    let reader = build_reader(&dir, &recorded, &LOOP_STEPS);
    let update = load_flow(&recorded, reader, LOOP_STEPS[0].1);
    assert!(!update.error, "flow update errored: {}", update.error_message);

    println!("loop containing if/else, every pass takes the else arm:");
    let entries = dump_branches(&update);

    assert!(
        !entries.is_empty(),
        "branches_taken is empty for a Rust loop containing an if/else — the backend produced NO \
         branch state at all"
    );

    let if_states = state_at(&entries, LOOP_IF_HEADER);
    assert!(
        !if_states.is_empty(),
        "no state recorded anywhere for the `if` header (line {LOOP_IF_HEADER}); recorded: {entries:?}"
    );
    assert!(
        if_states.iter().all(|(_, _, s)| *s == BranchState::NotTaken),
        "the run took the `else` arm on every pass, so the `if` header (line {LOOP_IF_HEADER}) must be \
         NotTaken wherever it appears; got {if_states:?}"
    );

    // The taken arm must not be slandered. `final_branch_load` sweeps the whole
    // file against `branches_taken[0][0]` alone, so an arm proved `Taken` in a
    // LOOP table is invisible to the sweep's check list — and the sweep's
    // `status == Unknown` guard is always true, because the sound producer
    // marks `Taken` on a clone and never writes back. The arm the run entered
    // on every pass then appears as NotTaken in the outer table.
    let else_states = state_at(&entries, LOOP_ELSE_HEADER);
    assert!(
        else_states.iter().any(|(_, _, s)| *s == BranchState::Taken),
        "the run entered the `else` arm on every pass, so its header (line {LOOP_ELSE_HEADER}) must be \
         Taken; got {else_states:?}"
    );
    assert!(
        !else_states.iter().any(|(_, _, s)| *s == BranchState::NotTaken),
        "the `else` arm ran on every pass and is reported NotTaken in {else_states:?} — a line the run \
         entered, claimed as a branch the program declined"
    );

    // THE CELL THE RENDERER READS. `conditionStyleLines` paints
    // `branches_taken[0][0]` on every flow update and reaches the per-loop
    // tables only when the loop slider widget exists.
    let outer: Vec<(usize, BranchState)> = entries
        .iter()
        .filter(|(lp, it, _, _)| *lp == 0 && *it == 0)
        .map(|(_, _, l, s)| (*l, *s))
        .collect();
    assert!(
        outer.contains(&(LOOP_IF_HEADER, BranchState::NotTaken)),
        "the declined `if` header (line {LOOP_IF_HEADER}) is absent from branches_taken[0][0], the \
         table the renderer's unconditional pass reads; that cell holds {outer:?}"
    );
    assert!(
        !outer.contains(&(LOOP_ELSE_HEADER, BranchState::NotTaken)),
        "the `else` arm the run entered is stamped NotTaken in branches_taken[0][0]: {outer:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// THE ISSUE'S OWN PROGRAM: a lone `if` inside a loop, entered on some passes
/// and declined on others.
///
/// This is where #758 actually bites, and the fixture above does not reach it:
/// a conditional with a single arm has an empty `Branch.opposite`, so the sound
/// producer can only ever report `Taken`. The declined passes are reported by
/// nothing at all.
#[test]
fn a_lone_if_declined_on_some_passes_is_reported_not_taken_on_those_passes() {
    assert_fixture_shape_lone_if();
    let dir = temp_dir("loneif");
    let recorded = write_fixture(&dir, "branch_lone_if.rs", LONE_IF_SOURCE);
    let reader = build_reader(&dir, &recorded, &LONE_IF_STEPS);
    let update = load_flow(&recorded, reader, LONE_IF_STEPS[0].1);
    assert!(!update.error, "flow update errored: {}", update.error_message);

    println!("#758's program: lone `if` in a loop, taken on passes 0 and 3:");
    let entries = dump_branches(&update);

    assert!(!entries.is_empty(), "branches_taken is empty — no branch state at all");

    // The taken passes. Non-vacuity for everything below: if these are absent
    // the fixture never reached the conditional and the rest is meaningless.
    let per_pass = state_at(&entries, LONE_IF_HEADER);
    assert!(
        per_pass.contains(&(1, 0, BranchState::Taken)),
        "pass 0 entered the arm, so branches_taken[1][0] must report it Taken; got {per_pass:?}"
    );
    assert!(
        per_pass.contains(&(1, 3, BranchState::Taken)),
        "pass 3 entered the arm, so branches_taken[1][3] must report it Taken; got {per_pass:?}"
    );

    // THE REPORT. Passes 1 and 2 did not enter the arm, and #758 is that
    // nothing says so.
    assert!(
        per_pass.contains(&(1, 1, BranchState::NotTaken)),
        "pass 1 DECLINED the arm and nothing in the payload says so — branches_taken[1][1] must \
         report line {LONE_IF_HEADER} NotTaken; got {per_pass:?}"
    );
    assert!(
        per_pass.contains(&(1, 2, BranchState::NotTaken)),
        "pass 2 DECLINED the arm and nothing in the payload says so — branches_taken[1][2] must \
         report line {LONE_IF_HEADER} NotTaken; got {per_pass:?}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// THE NEXT-STEP RULE MUST NOT OUTVOTE A SIGHTING.
///
/// The per-step rule infers `NotTaken` from where the step after a header
/// landed. That inference is sound only for the FIRST evaluation of the test,
/// and line-granularity replay hands the walk a second step on the same source
/// line routinely — `MAX_NONPROGRESSING_STEPS` in `flow_preloader.rs` exists
/// because a native trace can report a run of steps against one line. When that
/// happens after the arm has already run, the re-registered pending resolves
/// against whatever follows, which is outside the arm.
///
/// Without the guard this reddens: line 3 is reported `Taken` by
/// `load_branch_for_position` from the step at line 4 and then rewritten to
/// `NotTaken` — red painted over an arm the walk was SEEN to enter, which is
/// strictly worse than the under-reporting this milestone set out to fix.
/// Measured before the guard: `branches_taken[0][0] = [(3, NotTaken)]`, where
/// the unmodified backend at `dev` `34581010a` produced `[(3, Taken)]`.
#[test]
fn a_header_revisited_after_its_arm_ran_keeps_taken() {
    let lines: Vec<&str> = REVISITED_SOURCE.lines().collect();
    assert!(
        lines[REVISITED_IF_HEADER - 1].trim_start().starts_with("if "),
        "line {} is not the `if` header, it is {:?}",
        REVISITED_IF_HEADER,
        lines[REVISITED_IF_HEADER - 1]
    );
    let dir = temp_dir("revisited");
    let recorded = write_fixture(&dir, "branch_revisited.rs", REVISITED_SOURCE);
    let reader = build_reader(&dir, &recorded, &REVISITED_STEPS);
    let update = load_flow(&recorded, reader, REVISITED_STEPS[0].1);
    assert!(!update.error, "flow update errored: {}", update.error_message);

    println!("a header line the walk revisits after its arm ran:");
    let entries = dump_branches(&update);

    let states = state_at(&entries, REVISITED_IF_HEADER);
    assert!(
        !states.is_empty(),
        "no state recorded for the `if` header (line {REVISITED_IF_HEADER}); recorded: {entries:?}"
    );
    assert!(
        states.iter().any(|(_, _, s)| *s == BranchState::Taken),
        "the walk stepped INSIDE the arm (line {}), so line {REVISITED_IF_HEADER} must be Taken; got {states:?}",
        REVISITED_STEPS[2].1
    );
    assert!(
        !states.iter().any(|(_, _, s)| *s == BranchState::NotTaken),
        "the walk stepped inside the arm and line {REVISITED_IF_HEADER} is reported NotTaken in \
         {states:?} — an inference from the second step on the header line has overwritten a sighting"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

fn assert_fixture_shape_lone_if() {
    let lines: Vec<&str> = LONE_IF_SOURCE.lines().collect();
    assert!(
        lines[LONE_IF_HEADER - 1].trim_start().starts_with("if "),
        "line {} is not the `if` header, it is {:?}",
        LONE_IF_HEADER,
        lines[LONE_IF_HEADER - 1]
    );
    assert!(
        !LONE_IF_SOURCE.contains("else"),
        "the point of this fixture is that the conditional has NO else arm"
    );
}
