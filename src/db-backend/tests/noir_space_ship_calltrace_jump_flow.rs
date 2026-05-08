//! §1.66 contract test (corrects the §1.64 hypothesis).
//!
//! Background.  In the noir-space-ship GUI tests
//! (`tests/noir-space-ship/noir-space-ship.spec.ts:278` and `:393`),
//! the user clicks the `iterate_asteroids` entry in the calltrace and
//! the editor for `shield.nr` requests a flow update via `ct/load-flow`.
//! The frontend can only fill in the fields it knows from the
//! `complete_move` event:
//!
//!   - `path`             : the file the calltrace surfaced (shield.nr)
//!   - `line`             : the active line after the jump
//!   - `rr_ticks`         : the call-entry step
//!   - `function_first`   : 0 (frontend doesn't know yet)
//!   - `function_last`    : 0 (frontend doesn't know yet)
//!   - `function_name`    : "" (frontend doesn't know yet)
//!
//! §1.64 hypothesised that `flow_preloader::load_flow` would rewrite
//! `self.location` (via `find_function_location` on the parent macro-
//! sourcemapped Noir file) so the eventual `FlowUpdate` would carry
//! `main.nr`/`main` instead of `shield.nr`/`iterate_asteroids`.
//!
//! THIS TEST EMPIRICALLY FALSIFIES THAT HYPOTHESIS.  The data layer,
//! when called with a Location shaped like the GUI's calltrace-jump
//! load-flow request, returns:
//!
//!   1. `flow_update.location.path`       ends with `shield.nr`        OK
//!   2. `flow_update.location.function_name` == "iterate_asteroids"    OK
//!   3. `view_updates[0].location.path`   ends with `shield.nr`        OK
//!   4. at least one `Loop` with `iteration > 0` (lines 4..15)         OK
//!   5. at least one `FlowStep` whose `r#loop` matches that loop's id  OK
//!
//! That is: `find_function_location` only changes function_name and
//! function_first/last; it does not touch `path` or `high_level_path`
//! (see `expr_loader.rs::find_function_location`, which only writes
//! the function-name/range fields).  And when the GUI-shaped Location
//! (function_first == 0) hits the preloader, the preloader's fallback
//! correctly preserves the incoming path/line.
//!
//! Therefore the noir-space-ship loop-iteration GUI blocker is NOT in
//! the data layer.  This test pins the data-layer contract going
//! forward; the actual GUI failure must be elsewhere (frontend
//! plumbing: cached complete_move replay, FlowComponent path guard,
//! loadFlow gating in `editor.nim::onCompleteMove`).
//!
//! Run with:
//!     cargo test --test noir_space_ship_calltrace_jump_flow -- --nocapture

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

/// Load the in-memory `Db` from the unique `*.ct` CTFS container in
/// `target_dir`.
///
/// Returns `None` if `target_dir` does not contain a `.ct` file so the
/// caller can skip cleanly when the recorder hasn't yet migrated to
/// CTFS — the diagnostic test must not fail the suite when its input
/// can't be produced.  Per `Trace-Files/CTFS-Migration-Guide.md` §3e the
/// `.ct` bundle is the only supported materialized-trace format; legacy
/// sidecars (`trace_metadata.json` / `trace.json` / `trace.bin`) are no
/// longer accepted.
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

/// SKIP gate: every Noir-recorder test requires `nargo` on PATH.
fn find_nargo() -> bool {
    Command::new("nargo").arg("--version").output().is_ok()
}

/// Record the noir-space-ship trace into a temporary directory.
///
/// Mirrors the helper in `noir_loop_diagnostic.rs` but uses the
/// `noir_space_ship` test program (which has the iterate_asteroids
/// loop the GUI tests exercise).
fn record_noir_space_ship_trace() -> Option<PathBuf> {
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/nss_calltrace_jump_{}",
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

/// Find the first step inside `iterate_asteroids` (the function body).
///
/// We use the FIRST step because that's exactly what the GUI's
/// calltrace-jump lands on — the call entry — and that's the rrTicks
/// the frontend forwards in the subsequent `ct/load-flow` request.
fn find_iterate_asteroids_first_step(db: &Db, reader: &Arc<dyn TraceReader>) -> Option<(StepId, String)> {
    for step in db.step_from(StepId(0), true) {
        let path_str = reader.path(step.path_id)?.to_string();
        if path_str.ends_with("shield.nr") {
            return Some((step.step_id, path_str));
        }
    }
    None
}

/// §1.66: drive `flow_preloader::load` with a Location shaped exactly
/// like the one the frontend sends after a calltrace-jump into
/// `iterate_asteroids` (path + line + rrTicks populated, function
/// boundaries empty).  Assert that the response carries the
/// shield.nr/iterate_asteroids loop data, NOT main.nr's body.
///
/// This test PASSES with the current data layer, refuting the
/// §1.64 hypothesis that the preloader rewrites the request location
/// to main.nr.  The pre-existing diagnostic
/// `dump_noir_space_ship_flow_from_call_entry` in
/// `noir_loop_diagnostic.rs` corroborates: `path=src/shield.nr`,
/// `fn_name=iterate_asteroids`, real loop `(4, 15, 8)` matched.
/// Pin the contract here so any future refactor that breaks it
/// (e.g. tighter use of `find_function_location` on macro-mapped
/// paths) fails loudly instead of silently regressing the GUI flow
/// renderer.
#[test]
fn flow_request_for_iterate_asteroids_returns_shield_nr_loops() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    let Some(target_dir) = record_noir_space_ship_trace() else {
        eprintln!("SKIPPED: nargo trace unavailable");
        return;
    };

    // CTFS-only: pull the materialised `Db` directly from the `.ct`
    // container.  The reader runs `TraceProcessor::postprocess` for us, so
    // we no longer need to drive event decode + postprocess by hand.
    let Some(db) = load_db_from_ctfs(&target_dir) else {
        eprintln!(
            "SKIPPED: nargo did not produce a *.ct CTFS container in {} — \
             the Noir recorder still emits the legacy layout, which is no \
             longer supported by this diagnostic.",
            target_dir.display()
        );
        return;
    };

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));
    let (target_step_id, shield_path) =
        find_iterate_asteroids_first_step(&db, &reader).expect("at least one shield.nr step");

    println!(
        "Function-entry target step: {} (path={})",
        target_step_id.0, shield_path
    );

    // Determine the call-entry line by reading the step's actual line.
    // This is what the calltrace-jump flow lands on -- exactly what
    // the GUI's `complete_move` event will surface.
    let entry_step = *reader.step(target_step_id).expect("entry step");
    let entry_line = entry_step.line.0;
    println!("entry_line = {entry_line}");

    // Build the GUI-shaped Location: path + line + rrTicks populated
    // by the frontend from the calltrace entry; function boundaries
    // and function_name left at their default (empty / 0) because the
    // frontend cannot derive them without already knowing the function
    // it is requesting flow for.
    //
    // This is the exact shape the headless DAP test in
    // `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim`
    // ("ct/load-flow after iterate_asteroids jump returns loop steps")
    // sends over the wire.
    //
    // The path uses the workdir-prefixed form because that's what the
    // frontend sees in `complete_move.location.path` (the trace reader
    // joins workdir + path_id).
    let workdir_path = format!(
        "{}",
        reader
            .workdir()
            .join(reader.path(entry_step.path_id).unwrap_or(""))
            .display()
    );
    // Intentionally leave function_first / function_last at 0 and
    // function_name empty -- mirrors what the frontend sends.
    let location = Location {
        path: workdir_path.clone(),
        high_level_path: workdir_path,
        line: entry_line,
        high_level_line: entry_line,
        rr_ticks: RRTicks(target_step_id.0),
        ..Location::default()
    };
    assert_eq!(location.function_first, 0);
    assert_eq!(location.function_last, 0);
    assert!(location.function_name.is_empty());

    // Drive the FlowPreloader (the same object the DAP handler
    // uses, just without the Db-boundary enrichment the handler does
    // pre-call -- we want to test the preloader's own behaviour for
    // an under-populated request, since the enrichment can also be
    // wrong on macro-sourcemapped traces).
    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let flow_update = flow_preloader.load(location.clone(), FlowMode::Call, TraceKind::Materialized, &mut replay);

    println!("FlowUpdate.error: {}", flow_update.error);
    println!(
        "FlowUpdate.location: path={} line={} fn={}..{} fn_name={}",
        flow_update.location.path,
        flow_update.location.line,
        flow_update.location.function_first,
        flow_update.location.function_last,
        flow_update.location.function_name,
    );
    println!("view_updates: {}", flow_update.view_updates.len());

    assert!(
        !flow_update.error,
        "flow update reported an error: {}",
        flow_update.error_message
    );

    // Assertion 1: the response location's path stays in shield.nr.
    // §1.64 root cause: this is currently main.nr after the preloader
    // resolves the call to the parent macro-sourcemapped function.
    assert!(
        flow_update.location.path.ends_with("shield.nr"),
        "FlowUpdate.location.path was rewritten away from the requested file: \
         expected ends-with shield.nr, got {}",
        flow_update.location.path
    );

    // Assertion 2: the response location's function_name resolves to
    // iterate_asteroids (the function the user actually clicked in
    // the calltrace).  This is what the FlowComponent.onUpdatedFlow
    // path-name guard (`flow.nim:onUpdatedFlow`) compares editorUI.name
    // against.
    assert_eq!(
        flow_update.location.function_name, "iterate_asteroids",
        "FlowUpdate.location.function_name expected iterate_asteroids, got {}",
        flow_update.location.function_name
    );

    // Assertion 3: at least one view_update is present and its location
    // also stays in shield.nr (the view_updates body is what the
    // frontend's flow renderer iterates over).
    assert!(
        !flow_update.view_updates.is_empty(),
        "expected at least one view_update; FlowUpdate.error={} message={}",
        flow_update.error,
        flow_update.error_message
    );
    let vu = &flow_update.view_updates[0];
    println!(
        "  view_update[0]: location={}:{} steps={} loops={}",
        vu.location.path,
        vu.location.line,
        vu.steps.len(),
        vu.loops.len()
    );
    assert!(
        vu.location.path.ends_with("shield.nr"),
        "view_updates[0].location.path was rewritten away from shield.nr: got {}",
        vu.location.path
    );

    // Assertion 4: at least one Loop in the iterate_asteroids range
    // (lines 4-15).  loops[0] is the implicit base loop with first=-1
    // (function-level scope), so we need at least one MORE entry that
    // covers the for-body.
    let real_loop = vu
        .loops
        .iter()
        .find(|lp| lp.first.0 >= 1 && lp.last.0 >= lp.first.0 && lp.iteration.0 > 0);
    println!(
        "  loops summary: {} entries; matched real loop: {:?}",
        vu.loops.len(),
        real_loop.map(|lp| (lp.first.0, lp.last.0, lp.iteration.0)),
    );
    assert!(
        real_loop.is_some(),
        "expected at least one loop with iteration > 0 inside iterate_asteroids; \
         got {} loops: {:?}",
        vu.loops.len(),
        vu.loops
            .iter()
            .map(|lp| (lp.first.0, lp.last.0, lp.iteration.0))
            .collect::<Vec<_>>()
    );

    // Assertion 5: at least one FlowStep participates in the loop
    // (its `r#loop` matches the real loop's `base`).  This is the
    // input the GUI's per-iteration value rendering needs.
    let real_loop_id = real_loop.unwrap().base.clone();
    let in_loop_step = vu.steps.iter().find(|st| st.r#loop == real_loop_id);
    assert!(
        in_loop_step.is_some(),
        "expected at least one step with loop=={:?} (the iterate_asteroids \
         for-loop); got {} steps with loop ids {:?}",
        real_loop_id,
        vu.steps.len(),
        vu.steps.iter().map(|st| st.r#loop.clone()).collect::<Vec<_>>(),
    );
}
