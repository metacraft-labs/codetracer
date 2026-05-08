//! Diagnostic test: dump line-step sequence and FlowUpdate.loops contents
//! for a Noir trace that contains a `for i in 0..4` loop.
//!
//! Walk-down-the-layers diagnostic for the noir-space-ship
//! `flow-multiline-value-container` failure:
//!
//! 1) Decode the raw trace events: do we observe a step at the `for`
//!    header line on each iteration?  (recorder layer)
//! 2) Drive `FlowPreloader::load(...)` directly and dump the
//!    `FlowUpdate.view_updates[].loops` array: does the loop appear
//!    with iteration > 0?  (db-backend layer)
//!
//! Prints to stdout so the maintainer can see the verdict; never panics
//! on absence so the test can run unconditionally as long as `nargo` is
//! on PATH.  Run with `cargo test --test noir_loop_diagnostic -- --nocapture`.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;

use codetracer_trace_types::{StepId, TraceLowLevelEvent, TraceMetadata};
use db_backend::db::{Db, MaterializedReplaySession};
use db_backend::flow_preloader::FlowPreloader;
use db_backend::in_memory_trace_reader::InMemoryTraceReader;
use db_backend::task::{CoreTrace, CtLoadFlowArguments, FlowMode, RRTicks, TraceKind};
use db_backend::trace_processor::{load_trace_data, load_trace_metadata, TraceProcessor};
use db_backend::trace_reader::TraceReader;

/// Load `TraceMetadata` from a recording directory, preferring the legacy
/// sidecar `trace_metadata.json` and falling back to the `meta.json`
/// block stored inside a `.ct` CTFS container.
///
/// Per the CTFS migration guide (Trace-Files/CTFS-Migration-Guide.md §3e)
/// modern bundles bake metadata into the container and stop emitting the
/// sidecar.  We keep the sidecar path as the primary so existing nargo
/// recorders (which still emit the legacy layout) keep working unchanged.
fn load_trace_metadata_either(target_dir: &std::path::Path) -> TraceMetadata {
    let legacy = target_dir.join("trace_metadata.json");
    if legacy.exists() {
        return load_trace_metadata(&legacy).expect("trace_metadata.json");
    }
    let ct_path = std::fs::read_dir(target_dir)
        .ok()
        .and_then(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .find(|p| p.extension().is_some_and(|ext| ext == "ct"))
        })
        .unwrap_or_else(|| panic!("no trace_metadata.json or *.ct found in {}", target_dir.display()));
    let mut ctfs = db_backend::ctfs_trace_reader::ctfs_container::CtfsReader::open(&ct_path)
        .unwrap_or_else(|e| panic!("open {}: {}", ct_path.display(), e));
    let meta_bytes = ctfs
        .read_file("meta.json")
        .unwrap_or_else(|e| panic!("read meta.json from {}: {}", ct_path.display(), e));
    serde_json::from_slice(&meta_bytes).unwrap_or_else(|e| panic!("parse meta.json from {}: {}", ct_path.display(), e))
}

fn find_nargo() -> bool {
    Command::new("nargo").arg("--version").output().is_ok()
}

fn record_loop_trace(target_dir: &std::path::Path) -> Result<(), String> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let project_dir = manifest_dir.join("test-programs/noir_loop");
    std::fs::create_dir_all(target_dir).map_err(|e| format!("mkdir {target_dir:?}: {e}"))?;
    let result = Command::new("nargo")
        .args(["trace", "--out-dir", target_dir.to_str().unwrap()])
        .current_dir(&project_dir)
        .output()
        .map_err(|e| format!("invoking nargo: {e}"))?;
    if !result.status.success() {
        return Err(format!(
            "nargo trace failed:\nstdout: {}\nstderr: {}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    Ok(())
}

#[test]
fn dump_noir_loop_trace_steps() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/noir_loop_diag_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&target_dir);
    record_loop_trace(&target_dir).expect("nargo trace");

    let trace_file = target_dir.join("trace.bin");
    let format = if trace_file.exists() {
        codetracer_trace_reader::TraceEventsFileFormat::Binary
    } else {
        codetracer_trace_reader::TraceEventsFileFormat::Json
    };
    let trace_path = if trace_file.exists() {
        trace_file
    } else {
        target_dir.join("trace.json")
    };
    let events = load_trace_data(&trace_path, format).expect("load_trace_data");

    let mut step_lines: Vec<i64> = Vec::new();
    let mut path_strings: Vec<String> = Vec::new();
    for ev in &events {
        match ev {
            TraceLowLevelEvent::Path(p) => path_strings.push(p.display().to_string()),
            TraceLowLevelEvent::Step(s) => {
                step_lines.push(s.line.0);
            }
            _ => {}
        }
    }

    println!("Paths registered: {path_strings:?}");
    println!("Total step events: {}", step_lines.len());
    println!("Step lines (in order): {step_lines:?}");

    let header_hits = step_lines.iter().filter(|&&l| l == 11).count();
    println!("Hits on `for` header line (11): {header_hits}");
    let body_line_12_hits = step_lines.iter().filter(|&&l| l == 12).count();
    let body_line_13_hits = step_lines.iter().filter(|&&l| l == 13).count();
    println!("Hits on body line 12: {body_line_12_hits}");
    println!("Hits on body line 13: {body_line_13_hits}");

    if header_hits < 4 {
        eprintln!(
            "DIAGNOSTIC: Noir recorder does not emit a step at the `for` header line on each iteration; \
             flow_preloader::process_loops cannot observe the iteration boundary."
        );
    } else {
        eprintln!("DIAGNOSTIC: Noir recorder emits {header_hits} steps at the `for` header line.");
    }
}

/// End-to-end diagnostic: build a `Db` from the recorded events, hand it
/// to `FlowPreloader::load`, and inspect the resulting `FlowUpdate.view_updates`
/// to see whether the multi-iteration `for` loop produces a populated
/// `loops` entry with iteration > 0.
#[test]
fn dump_noir_loop_flow_update() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/noir_loop_diag_flow_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&target_dir);
    record_loop_trace(&target_dir).expect("nargo trace");

    // Auto-detect format and decode the trace.
    let (trace_file, format) = if target_dir.join("trace.bin").exists() {
        (
            target_dir.join("trace.bin"),
            codetracer_trace_reader::TraceEventsFileFormat::Binary,
        )
    } else {
        (
            target_dir.join("trace.json"),
            codetracer_trace_reader::TraceEventsFileFormat::Json,
        )
    };
    let metadata = load_trace_metadata_either(&target_dir);
    let events = load_trace_data(&trace_file, format).expect("load_trace_data");

    // Materialise the events into a Db.
    let mut db = Db::new(&metadata.workdir);
    let mut tp = TraceProcessor::new(&mut db);
    tp.postprocess(&events).expect("postprocess events");

    // Find the first step inside the loop body (line 12 or 13).
    let target_step_id = {
        let mut chosen: Option<StepId> = None;
        for step in db.step_from(StepId(0), true) {
            if step.line.0 == 12 || step.line.0 == 13 {
                chosen = Some(step.step_id);
                break;
            }
        }
        chosen.expect("expected at least one step on the loop body lines 12 / 13")
    };
    println!(
        "Inside-loop target step_id: {} (line should be 12 or 13)",
        target_step_id.0
    );

    // Build the call-flow location for that step.
    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));
    let mut tmp_expr_loader = db_backend::expr_loader::ExprLoader::new(CoreTrace::default());
    let step = *reader.step(target_step_id).expect("target step lookup");
    let mut location = reader.load_location(target_step_id, step.call_key, &mut tmp_expr_loader);
    location.rr_ticks = RRTicks(target_step_id.0);
    println!(
        "Location: path={} line={} fn={}..{} fn_name={}",
        location.path, location.line, location.function_first, location.function_last, location.function_name
    );

    // Drive FlowPreloader directly.
    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let _ = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location: location.clone(),
    };
    let flow_update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);

    println!("FlowUpdate.error: {}", flow_update.error);
    println!("FlowUpdate.view_updates: {} updates", flow_update.view_updates.len());
    for (i, vu) in flow_update.view_updates.iter().enumerate() {
        println!(
            "  view_update[{i}]: location={}:{} steps={} loops={} relevant_step_count={}",
            vu.location.path,
            vu.location.line,
            vu.steps.len(),
            vu.loops.len(),
            vu.relevant_step_count.len()
        );
        for (j, lp) in vu.loops.iter().enumerate() {
            println!(
                "    loops[{j}]: base={:?} first={} last={} registered_line={} iteration={} step_counts.len={} rr_ticks_for_iterations.len={}",
                lp.base,
                lp.first.0,
                lp.last.0,
                lp.registered_line.0,
                lp.iteration.0,
                lp.step_counts.len(),
                lp.rr_ticks_for_iterations.len()
            );
        }
        // Print a sample of step iterations to see if process_loops set them.
        for (k, step) in vu.steps.iter().enumerate().take(20) {
            println!(
                "    steps[{k}]: line={} loop={:?} iteration={} step_count={:?}",
                step.position.0, step.r#loop, step.iteration.0, step.step_count.0
            );
        }
    }

    eprintln!(
        "DIAGNOSTIC: Frontend renders a `flow-multiline-value-container` only when \
         `flow.loops[i].registered_line` matches the step position AND iteration \
         updates are emitted.  Inspect the printout above for a populated, multi-\
         iteration loops[] entry."
    );
}

/// Replay the recorded noir-space-ship trace and dump the flow loops for
/// `iterate_asteroids` (shield.nr).  This is the exact data the failing
/// `loop iteration slider tracks remaining shield` test consumes.
#[test]
fn dump_noir_space_ship_flow_update() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/noir_space_ship_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&target_dir);
    std::fs::create_dir_all(&target_dir).expect("mkdir");

    let project_dir = PathBuf::from("/home/zahary/metacraft/codetracer/test-programs/noir_space_ship");
    let result = Command::new("nargo")
        .args(["trace", "--out-dir", target_dir.to_str().unwrap()])
        .current_dir(&project_dir)
        .output()
        .expect("run nargo trace");
    assert!(
        result.status.success(),
        "nargo trace failed: stderr={}",
        String::from_utf8_lossy(&result.stderr)
    );

    let (trace_file, format) = if target_dir.join("trace.bin").exists() {
        (
            target_dir.join("trace.bin"),
            codetracer_trace_reader::TraceEventsFileFormat::Binary,
        )
    } else {
        (
            target_dir.join("trace.json"),
            codetracer_trace_reader::TraceEventsFileFormat::Json,
        )
    };
    let metadata = load_trace_metadata_either(&target_dir);
    let events = load_trace_data(&trace_file, format).expect("load_trace_data");

    let mut db = Db::new(&metadata.workdir);
    let mut tp = TraceProcessor::new(&mut db);
    tp.postprocess(&events).expect("postprocess events");

    // Dump line steps for shield.nr only.
    let shield_path = "src/shield.nr";
    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));
    let mut total_steps = 0;
    let mut shield_steps = 0;
    let mut shield_loop_header_hits = 0;
    let mut iterate_asteroids_first_step: Option<StepId> = None;
    for step in db.step_from(StepId(0), true) {
        total_steps += 1;
        let path_str = match reader.path(step.path_id) {
            Some(p) => p.to_string(),
            None => continue,
        };
        if path_str.ends_with(shield_path) || path_str.ends_with("shield.nr") {
            shield_steps += 1;
            if step.line.0 == 4 {
                shield_loop_header_hits += 1;
            }
            // iterate_asteroids body lives on lines 1-15.
            if iterate_asteroids_first_step.is_none() && (5..=15).contains(&step.line.0) {
                iterate_asteroids_first_step = Some(step.step_id);
            }
        }
    }
    println!("Total steps: {total_steps}, shield.nr steps: {shield_steps}");
    println!("shield.nr line 4 (`for i in 0..8`) hits: {shield_loop_header_hits}");

    let target_step_id = iterate_asteroids_first_step.expect("iterate_asteroids body step in shield.nr");
    println!("Target step inside iterate_asteroids: {}", target_step_id.0);

    // Build call-flow location and run FlowPreloader.
    let mut tmp_expr_loader = db_backend::expr_loader::ExprLoader::new(CoreTrace::default());
    let step = *reader.step(target_step_id).unwrap();
    let mut location = reader.load_location(target_step_id, step.call_key, &mut tmp_expr_loader);
    location.rr_ticks = RRTicks(target_step_id.0);
    println!(
        "Location: path={} line={} fn={}..{} fn_name={}",
        location.path, location.line, location.function_first, location.function_last, location.function_name
    );

    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let _ = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location: location.clone(),
    };
    let flow_update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);

    println!("FlowUpdate.error: {}", flow_update.error);
    println!("view_updates: {}", flow_update.view_updates.len());
    for (i, vu) in flow_update.view_updates.iter().enumerate() {
        println!(
            "  view_update[{i}]: location={}:{} steps={} loops={} relevant_step_count={}",
            vu.location.path,
            vu.location.line,
            vu.steps.len(),
            vu.loops.len(),
            vu.relevant_step_count.len()
        );
        for (j, lp) in vu.loops.iter().enumerate() {
            println!(
                "    loops[{j}]: base={:?} first={} last={} registered_line={} iteration={} step_counts.len={}",
                lp.base,
                lp.first.0,
                lp.last.0,
                lp.registered_line.0,
                lp.iteration.0,
                lp.step_counts.len()
            );
        }
        // Print the first 10 steps so we can see line/loop/iteration.
        for (k, step) in vu.steps.iter().enumerate().take(10) {
            println!(
                "    steps[{k}]: line={} loop={:?} iteration={}",
                step.position.0, step.r#loop, step.iteration.0
            );
        }
    }
}

/// Simulate the calltrace-jump scenario: jump to the FIRST step of
/// iterate_asteroids (the function entry, not somewhere inside the
/// loop body) and dump the resulting flow loops.  This mirrors what
/// `iterateEntry.activate()` does in the failing GUI test.
#[test]
fn dump_noir_space_ship_flow_from_call_entry() {
    if !find_nargo() {
        eprintln!("SKIPPED: nargo not on PATH");
        return;
    }
    let target_dir = PathBuf::from(format!(
        "{}/test-traces/noir_space_ship_entry_{}",
        env!("CARGO_MANIFEST_DIR"),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&target_dir);
    std::fs::create_dir_all(&target_dir).expect("mkdir");
    let project_dir = PathBuf::from("/home/zahary/metacraft/codetracer/test-programs/noir_space_ship");
    let result = Command::new("nargo")
        .args(["trace", "--out-dir", target_dir.to_str().unwrap()])
        .current_dir(&project_dir)
        .output()
        .expect("nargo trace");
    assert!(result.status.success());

    let (trace_file, format) = if target_dir.join("trace.bin").exists() {
        (
            target_dir.join("trace.bin"),
            codetracer_trace_reader::TraceEventsFileFormat::Binary,
        )
    } else {
        (
            target_dir.join("trace.json"),
            codetracer_trace_reader::TraceEventsFileFormat::Json,
        )
    };
    let metadata = load_trace_metadata_either(&target_dir);
    let events = load_trace_data(&trace_file, format).expect("events");
    let mut db = Db::new(&metadata.workdir);
    let mut tp = TraceProcessor::new(&mut db);
    tp.postprocess(&events).expect("postprocess events");

    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db.clone()));

    // Find the FIRST step in iterate_asteroids (function entry).
    let target_step_id = {
        let mut chosen: Option<StepId> = None;
        for step in db.step_from(StepId(0), true) {
            let path = match reader.path(step.path_id) {
                Some(p) => p.to_string(),
                None => continue,
            };
            if path.ends_with("shield.nr") {
                chosen = Some(step.step_id);
                break;
            }
        }
        chosen.expect("at least one shield.nr step")
    };
    println!("Function-entry target step: {}", target_step_id.0);

    let mut tmp_expr_loader = db_backend::expr_loader::ExprLoader::new(CoreTrace::default());
    let step = *reader.step(target_step_id).unwrap();
    let mut location = reader.load_location(target_step_id, step.call_key, &mut tmp_expr_loader);
    location.rr_ticks = RRTicks(target_step_id.0);
    println!(
        "Location: path={} line={} fn={}..{} fn_name={}",
        location.path, location.line, location.function_first, location.function_last, location.function_name
    );

    let mut flow_preloader = FlowPreloader::new();
    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let _ = CtLoadFlowArguments {
        flow_mode: FlowMode::Call,
        location: location.clone(),
    };
    let flow_update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);
    println!("FlowUpdate.error: {}", flow_update.error);
    println!("view_updates: {}", flow_update.view_updates.len());
    for (i, vu) in flow_update.view_updates.iter().enumerate() {
        println!(
            "  view_update[{i}]: location={}:{} steps={} loops={}",
            vu.location.path,
            vu.location.line,
            vu.steps.len(),
            vu.loops.len()
        );
        for (j, lp) in vu.loops.iter().enumerate() {
            println!(
                "    loops[{j}]: first={} last={} registered_line={} iteration={} step_counts.len={}",
                lp.first.0,
                lp.last.0,
                lp.registered_line.0,
                lp.iteration.0,
                lp.step_counts.len()
            );
        }
        for (k, step) in vu.steps.iter().enumerate().take(20) {
            println!(
                "    steps[{k}]: line={} loop={:?} iteration={}",
                step.position.0, step.r#loop, step.iteration.0
            );
        }
    }
}
