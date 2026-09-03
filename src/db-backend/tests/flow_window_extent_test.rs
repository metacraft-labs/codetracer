//! The flow window's declared extent is a fact ABOUT THE WINDOW.
//!
//! # The defect
//!
//! `FlowUpdate.location.function_first` / `function_last` are what the flow
//! overlay declares as the extent of the call it is showing. Measured on
//! `test-programs/noir_space_ship/src/shield.nr` before the fix:
//!
//! ```text
//! Location: path=.../shield.nr line=1 fn=0..6 fn_name=iterate_asteroids
//!   view_update[0]: steps=76
//! ```
//!
//! `iterate_asteroids` spans lines **1..20** of that file and its window covers
//! lines **1..18** over those 76 steps. The declared extent was **0..6** —
//! which describes neither. After the fix the same run reports `1..20`.
//!
//! That is worse than a wrong number, because it made a CORRECT feature look
//! broken. The window is a window over the enclosing CALL, positioned at that
//! call's ENTRY step, so an `rrTicks` of 0 is a legitimate value (the entry
//! tick) sitting next to an extent that genuinely is nonsense. One reads as
//! corroboration of the other, and a debugging effort went days down the wrong
//! hole on the pair.
//!
//! # Why the old value was structurally unobtainable, not merely off
//!
//! `flow_preloader.rs::load_view_update` built the window's location from a
//! **throwaway** `ExprLoader::new(CoreTrace::default())`. An empty loader has
//! an empty `processed_files`, so `get_first_last_fn_lines` always returned
//! `(-1, -1)` and the trace-record fallback in `trace_reader.rs` always won.
//! That fallback computes:
//!
//! * `function_first = FunctionRecord.line` — and `codetracer_trace_types`'
//!   `FunctionRecord` is `{ path_id, line, name }`. **There is no end line in
//!   the trace format at all.**
//! * `function_last  = ` the greatest line over the *contiguous run of steps
//!   carrying this call_key*. A call's steps stop being contiguous the moment
//!   it calls anything, so for `iterate_asteroids` the run ends at line 6,
//!   where `calculate_damage` is called — five lines into a twenty-line
//!   function.
//!
//! So no amount of care with the call record could produce a correct
//! `function_last`: the datum does not exist in the trace. The AST does have
//! it, and `FlowPreloader::load` has already parsed the file into its OWN
//! `expr_loader`. The fix re-derives the extent from that populated loader.
//!
//! # What this test asserts, and why it is the containment and not the number
//!
//! The headline assertion is a PROPERTY: **every source line the window draws
//! lies inside the extent the window declares.** That is what "the extent
//! describes this window" means, it is exactly what `0..6` over a window
//! covering 1..18 violates, and — unlike a hardcoded `1..20` — it stays
//! meaningful if the fixture is ever re-recorded or the program edited.
//!
//! The exact body range is pinned too, because containment alone is satisfied
//! by an absurdly wide extent (`0..593` is the value `noir_loop`'s 17-line
//! `main` used to declare, and it contains everything).
//!
//! Run with:
//!     cargo test --test flow_window_extent_test -- --nocapture

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;

use codetracer_trace_types::StepId;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::{Db, MaterializedReplaySession};
use db_backend::flow_preloader::FlowPreloader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::task::{FlowMode, Location, RRTicks, TraceKind};
use db_backend::trace_reader::TraceReader;

/// `iterate_asteroids` in `test-programs/noir_space_ship/src/shield.nr`.
///
/// Line 1 is `pub fn iterate_asteroids(...) -> bool {` and line 20 is its
/// closing brace. Asserted against the checked-in file below rather than
/// trusted, so an edit to the fixture reddens here instead of silently
/// retargeting the test.
const FN_FIRST: i64 = 1;
const FN_LAST: i64 = 20;

fn load_db_from_ctfs(target_dir: &std::path::Path) -> Option<Db> {
    let ct_path = std::fs::read_dir(target_dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| p.extension().is_some_and(|ext| ext == "ct"))?;
    let reader = CTFSTraceReader::open(&ct_path)
        .unwrap_or_else(|e| panic!("CTFSTraceReader::open({}): {}", ct_path.display(), e));
    Some(reader.db().clone())
}

/// SKIP gate: the Noir recorder needs `nargo` on PATH.
fn find_nargo() -> bool {
    Command::new("nargo").arg("--version").output().is_ok()
}

fn record_noir_space_ship_trace() -> Option<PathBuf> {
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/flow_window_extent_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&target_dir);
    std::fs::create_dir_all(&target_dir).expect("mkdir");

    let project_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-programs/noir_space_ship");
    let canonical = project_dir.canonicalize().unwrap_or(project_dir);
    let result = Command::new("nargo")
        .args(["trace", "--out-dir", target_dir.to_str().unwrap()])
        .current_dir(&canonical)
        .output()
        .ok()?;
    if !result.status.success() {
        eprintln!(
            "nargo trace failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        return None;
    }
    Some(target_dir)
}

/// The FIRST `shield.nr` step — the call entry, which is where a calltrace
/// jump lands and therefore the `rrTicks` the frontend forwards.
fn find_iterate_asteroids_first_step(db: &Db, reader: &Arc<dyn TraceReader>) -> Option<StepId> {
    for step in db.step_from(StepId(0), true) {
        let path_str = reader.path(step.path_id)?.to_string();
        if path_str.ends_with("shield.nr") {
            return Some(step.step_id);
        }
    }
    None
}

/// THE FIXTURE IS WHAT THIS TEST SAYS IT IS.
///
/// `FN_FIRST` / `FN_LAST` are line numbers in a checked-in file, and line
/// numbers drift. Reading the file and confirming the two ends is what keeps
/// the extent assertions below about `iterate_asteroids` rather than about
/// whatever happens to live at those lines now.
fn assert_fixture_shape() {
    let shield = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../test-programs/noir_space_ship/src/shield.nr");
    let source = std::fs::read_to_string(&shield).unwrap_or_else(|e| panic!("read {}: {}", shield.display(), e));
    let lines: Vec<&str> = source.lines().collect();
    assert!(
        lines.len() >= FN_LAST as usize,
        "shield.nr has {} lines, fewer than the {} this test targets",
        lines.len(),
        FN_LAST
    );
    assert!(
        lines[(FN_FIRST - 1) as usize].contains("fn iterate_asteroids"),
        "shield.nr:{} is not the iterate_asteroids declaration, it is {:?}",
        FN_FIRST,
        lines[(FN_FIRST - 1) as usize]
    );
    assert_eq!(
        lines[(FN_LAST - 1) as usize].trim(),
        "}",
        "shield.nr:{FN_LAST} is not the closing brace of iterate_asteroids"
    );
}

#[test]
fn flow_window_extent_contains_the_lines_the_window_draws() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    assert_fixture_shape();

    let Some(target_dir) = record_noir_space_ship_trace() else {
        eprintln!("SKIPPED: nargo trace unavailable");
        return;
    };
    let Some(db) = load_db_from_ctfs(&target_dir) else {
        eprintln!("SKIPPED: nargo produced no *.ct container in {}", target_dir.display());
        return;
    };

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));
    let target_step_id = find_iterate_asteroids_first_step(&db, &reader).expect("at least one shield.nr step");
    let entry_step = *reader.step(target_step_id).expect("entry step");
    let entry_line = entry_step.line.0;

    // The GUI-shaped request: path + line + rrTicks from the calltrace entry,
    // function boundaries left empty because the frontend cannot know them.
    // This is the shape `noir_space_ship_calltrace_jump_flow.rs` pins as what
    // the wire actually carries.
    let workdir_path = format!(
        "{}",
        reader
            .workdir()
            .join(reader.path(entry_step.path_id).unwrap_or(""))
            .display()
    );
    let location = Location {
        path: workdir_path.clone(),
        high_level_path: workdir_path,
        line: entry_line,
        high_level_line: entry_line,
        rr_ticks: RRTicks(target_step_id.0),
        ..Location::default()
    };

    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let flow_update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);

    assert!(
        !flow_update.error,
        "flow update reported an error: {}",
        flow_update.error_message
    );

    let declared_first = flow_update.location.function_first;
    let declared_last = flow_update.location.function_last;
    println!(
        "declared extent: {}..{}  (fn_name={} path={})",
        declared_first, declared_last, flow_update.location.function_name, flow_update.location.path
    );

    // NON-VACUITY FIRST. "every covered line is inside the extent" is trivially
    // true of a window that covers nothing, which is precisely what a broken
    // fixture or a failed recording would produce.
    assert!(
        !flow_update.view_updates.is_empty(),
        "no view updates — there is no window to have an extent"
    );
    let view = &flow_update.view_updates[0];
    assert!(
        view.steps.len() > 10,
        "only {} steps in the window; the fixture did not record",
        view.steps.len()
    );

    let covered: Vec<i64> = view.steps.iter().map(|s| s.position.0).filter(|l| *l > 0).collect();
    let covered_min = *covered.iter().min().expect("at least one covered line");
    let covered_max = *covered.iter().max().expect("at least one covered line");
    println!(
        "covered lines: {}..{} over {} steps",
        covered_min,
        covered_max,
        view.steps.len()
    );

    // THE HEADLINE ASSERTION. The extent is a claim about THIS window, so every
    // line the window draws has to be inside it. `0..6` over a window covering
    // 1..18 is the exact violation this pins, and it is stated as containment
    // rather than as two numbers so that it keeps its meaning if the fixture is
    // re-recorded.
    assert!(
        declared_first <= covered_min && covered_max <= declared_last,
        "the flow window declares extent {declared_first}..{declared_last} but draws lines \
         {covered_min}..{covered_max} — the extent describes neither the function nor its own \
         contents"
    );

    // A LINE NUMBER, NOT A SENTINEL. `function_first` was 0, which is not a
    // line in any file and is what made the field read as unfilled rather than
    // as wrong.
    assert!(
        declared_first > 0,
        "function_first is {declared_first}; source lines are 1-based, so this is not a location"
    );

    // AND THE EXACT BODY, because containment alone is satisfied by an absurdly
    // wide extent. `noir_loop`'s 17-line `main` used to declare `0..593` — a
    // range that contains every line it draws and is still nonsense.
    assert_eq!(
        (declared_first, declared_last),
        (FN_FIRST, FN_LAST),
        "the extent should be iterate_asteroids' body ({FN_FIRST}..{FN_LAST})"
    );

    // The window is still the one we asked for. An extent fix that silently
    // retargeted the window to another function would satisfy everything above.
    assert_eq!(flow_update.location.function_name, "iterate_asteroids");
    assert!(flow_update.location.path.ends_with("shield.nr"));

    let _ = std::fs::remove_dir_all(&target_dir);
}
