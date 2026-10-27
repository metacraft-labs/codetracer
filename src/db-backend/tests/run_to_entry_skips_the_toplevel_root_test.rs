//! Run-to-entry opens a recording in the PROGRAM's entry call, not in the
//! `<toplevel>` root the trace format wraps every recording in.
//!
//! ## The defect this pins
//!
//! The trace-format spec (`codetracer-trace-format-spec` `trace-events.md`,
//! "`<toplevel>` is the call tree's root and its id is fixed" and "The entry
//! step is part of `start`") has every writer open a `<toplevel>` call at
//! depth 0 and emit an entry step in it before the program runs. Its function
//! record sits at the entry point's `(path, line)` — in user source — so
//! `MaterializedReplaySession::first_user_call`, which chose the first call
//! whose function lives in user source, chose the ROOT for every
//! spec-conforming recording. The debugger then opened on that synthetic step,
//! and a step over from the root is a step over the whole program: the first
//! F10 on a freshly opened Python recording ran to its last step (measured on
//! the `calc` fixture: tick 0 to tick 171 of 171, in the terminal, the GPUI
//! window and the desktop alike).
//!
//! Only a root WRAPPING the program is skipped. Recorders that merge the
//! program's entry function into `<toplevel>` (Fuel, Cardano) put the body's
//! steps in the root itself; for them the root is the entry, and the
//! `MergedEntry` case pins that it still is. Two more merged shapes pin that
//! the JavaScript anchor rule below does not reach them: a body that starts
//! on the entry line, and a body line that the next call is defined at.
//!
//! ## The JavaScript shape
//!
//! A real JavaScript recording does not go straight from the entry step into
//! `<module>`. Between them the root carries two more records (decoded with
//! `ct-print` from a fresh `codetracer-js-recorder` recording of
//! `var a = 1; var b = 2;\nvar c = a + b;\n`):
//!
//! 1. a `ThreadStart` exec record: the runtime's async-context tracker
//!    announces the main thread when recording is enabled. Every exec record
//!    occupies a step slot, so the CTFS reader surfaces it as a step of the
//!    root with no source position (line 0);
//! 2. a step at the CALLEE's definition position, in the caller's frame: the
//!    recorder emits one right before every `Call` (it anchors the call's
//!    entry on the function's definition line), and `<module>` is defined at
//!    1:1, the entry step's own position.
//!
//! A rule that looked only at the step right after the entry step saw a root
//! step there (the thread record, and after it the anchor), judged the root
//! to carry the program's body, and opened the recording on `<toplevel>`.
//! From there the first statement step-over stepped over the whole `<module>`
//! call and landed on line 2 instead of on `var b` at 1:12. The `javascript`
//! cases pin that shape, columns included.
//!
//! ## No mocks
//!
//! The container is written by the production Nim writer and read by the
//! production CTFS reader; the session is the production
//! `MaterializedReplaySession`. Nothing is stubbed.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId, TypeId, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::MaterializedReplaySession;
use db_backend::replay::ReplaySession;
use db_backend::task::Action;

const SRC: &str = "/tmp/run_to_entry_root_prog.py";

/// The JavaScript program the ViewModel statement-stepping suites record
/// (`test_statement_step_over_vm.nim`): two statements on line 1, one on
/// line 2.
const JS_SRC: &str = "/tmp/run_to_entry_root_prog.js";
const JS_LINE_LENGTHS: [u32; 2] = ["var a = 1; var b = 2;".len() as u32, "var c = a + b;".len() as u32];
/// The 1-based column `var b` starts at on line 1.
const JS_COL_VAR_B: i64 = 12;

#[derive(Clone, Copy, PartialEq)]
enum Shape {
    /// `<toplevel>` (the entry step at line 1) around a module frame
    /// `<__main__>` whose lines 2..=4 run, line 3 calling `work` (lines 10,
    /// 11) — the Python and JavaScript recorders' shape.
    Wrapped,
    /// Nothing but the root.
    RootOnly,
    /// The program's entry function MERGED into `<toplevel>` (the Fuel and
    /// Cardano recorders' shape): the root's own steps are lines 2..=4, and
    /// line 3 calls `work` (lines 10, 11).
    MergedEntry,
    /// `MergedEntry` as the EVM recorder writes it around an external call:
    /// the root's body runs line 5, where it makes an external call, and the
    /// EVM recorder defines the external call's function at the CALLER's line
    /// (`external_call_depth_2` at line 5). The callee runs line 20, then
    /// the body resumes on line 6.
    ExternalCallAtCallerLine,
    /// `MergedEntry`, but the body's first statement is on the entry line
    /// itself and calls `work` (lines 10, 11) before line 2 runs, as in a
    /// one-line Aiken `test` on line 1. The root's own step at the entry line
    /// is body code, not an anchor.
    MergedEntryOnEntryLine,
}

fn write_bundle(dir: &Path, shape: Shape) -> PathBuf {
    let name = match shape {
        Shape::Wrapped => "root_prog",
        Shape::RootOnly => "root_only",
        Shape::MergedEntry => "root_merged",
        Shape::ExternalCallAtCallerLine => "root_external_call",
        Shape::MergedEntryOnEntryLine => "root_merged_entry_line",
    };
    let trace_path = dir.join(name);
    let ct_path = dir.join(format!("{name}.ct"));
    let mut writer = NimTraceWriter::new(name, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);
    // `start`: the `<toplevel>` function and call, and the entry step.
    writer.start(path, Line(1));
    if shape == Shape::Wrapped {
        let module = writer.ensure_function_id("<__main__>", path, Line(1));
        writer.register_function("<__main__>", path, Line(1));
        let work = writer.ensure_function_id("work", path, Line(10));
        writer.register_function("work", path, Line(10));
        TraceWriter::register_call(&mut writer, module, vec![]);
        writer.register_step(path, Line(2));
        writer.register_step(path, Line(3));
        TraceWriter::register_call(&mut writer, work, vec![]);
        writer.register_step(path, Line(10));
        writer.register_step(path, Line(11));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
        writer.register_step(path, Line(4));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    } else if shape == Shape::MergedEntry {
        let work = writer.ensure_function_id("work", path, Line(10));
        writer.register_function("work", path, Line(10));
        writer.register_step(path, Line(2));
        writer.register_step(path, Line(3));
        TraceWriter::register_call(&mut writer, work, vec![]);
        writer.register_step(path, Line(10));
        writer.register_step(path, Line(11));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
        writer.register_step(path, Line(4));
    } else if shape == Shape::ExternalCallAtCallerLine {
        let external = writer.ensure_function_id("external_call_depth_2", path, Line(5));
        writer.register_function("external_call_depth_2", path, Line(5));
        writer.register_step(path, Line(5));
        TraceWriter::register_call(&mut writer, external, vec![]);
        writer.register_step(path, Line(20));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
        writer.register_step(path, Line(6));
    } else if shape == Shape::MergedEntryOnEntryLine {
        let work = writer.ensure_function_id("work", path, Line(10));
        writer.register_function("work", path, Line(10));
        writer.register_step(path, Line(1));
        TraceWriter::register_call(&mut writer, work, vec![]);
        writer.register_step(path, Line(10));
        writer.register_step(path, Line(11));
        writer.register_return(ValueRecord::None { type_id: TypeId(0) });
        writer.register_step(path, Line(2));
    } else {
        writer.register_step(path, Line(2));
    }
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();
    assert!(ct_path.exists(), "the Nim writer must produce {}", ct_path.display());
    ct_path
}

/// The JavaScript recorder's shape, record for record as a real recording of
/// the [`JS_SRC`] program decodes (see the module docs):
///
/// ```text
/// step   1:1   <toplevel>   the entry step `start` emits
/// thread_start 1            the async-context tracker's main thread
/// step   1:1   <toplevel>   the definition-position anchor before the call
/// call   <module>           depth 1, defined at 1:1
/// step   1:1   <module>     var a = 1;
/// step   1:12  <module>     var b = 2;
/// step   2:1   <module>     var c = a + b;
/// ```
fn write_js_module_bundle(dir: &Path) -> PathBuf {
    let name = "root_js_module";
    let trace_path = dir.join(name);
    let ct_path = dir.join(format!("{name}.ct"));
    let path = Path::new(JS_SRC);
    let mut writer = NimTraceWriter::new(name, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    // Column-aware, as the JS recorder is. The opt-in precedes the path
    // registration so the path carries the line table columns resolve on.
    writer.enable_column_aware_steps();
    writer.register_path_with_line_lengths(path, &JS_LINE_LENGTHS).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    writer.start(path, Line(1));
    writer.register_thread_start(1);
    let module = writer.ensure_function_id("<module>", path, Line(1));
    writer.register_function("<module>", path, Line(1));
    writer.register_step_with_column(path, Line(1), Some(Line(1)));
    TraceWriter::register_call(&mut writer, module, vec![]);
    writer.register_step_with_column(path, Line(1), Some(Line(1)));
    writer.register_step_with_column(path, Line(1), Some(Line(JS_COL_VAR_B)));
    writer.register_step_with_column(path, Line(2), Some(Line(1)));
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();
    assert!(ct_path.exists(), "the Nim writer must produce {}", ct_path.display());
    ct_path
}

fn open(ct_path: &Path) -> MaterializedReplaySession {
    let bytes = std::fs::read(ct_path).expect("the .ct bytes must be readable");
    let reader = CTFSTraceReader::from_bytes(bytes).expect("the container must open");
    MaterializedReplaySession::new(std::sync::Arc::new(reader))
}

/// `(function name, call depth, line)` of the step the session is at.
fn at(session: &mut MaterializedReplaySession) -> (String, usize, i64) {
    let reader = session.reader.clone();
    let step = reader.step(session.current_step_id()).expect("the step exists");
    let call = reader.call(step.call_key).expect("every step is in a call");
    let function = reader.function(call.function_id).expect("the function is interned");
    (function.name.clone(), call.depth, step.line.0)
}

#[test]
fn run_to_entry_lands_in_the_programs_first_call_not_the_root() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::Wrapped));

    // The control first: the container really has the root and its entry step
    // at step 0, so the case below is about choosing past it.
    let reader = session.reader.clone();
    let root = reader.call(reader.step(StepId(0)).unwrap().call_key).unwrap();
    assert_eq!(reader.function(root.function_id).unwrap().name, "<toplevel>");
    assert_eq!(root.depth, 0);

    session.run_to_entry().expect("run to entry");
    assert_eq!(
        at(&mut session),
        ("<__main__>".to_string(), 1, 2),
        "run-to-entry must open in the program's entry call (its first line), \
         not on the `<toplevel>` root's synthetic entry step"
    );
}

#[test]
fn a_step_over_from_the_entry_steps_one_line_not_the_whole_program() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::Wrapped));
    session.run_to_entry().expect("run to entry");

    session.step(Action::Next, true).expect("step over");
    assert_eq!(at(&mut session), ("<__main__>".to_string(), 1, 3));
    // Over the call to `work`, to the module's next line — not into the end.
    session.step(Action::Next, true).expect("step over");
    assert_eq!(at(&mut session), ("<__main__>".to_string(), 1, 4));
}

#[test]
fn a_recording_with_only_the_root_still_opens_on_it() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::RootOnly));
    session.run_to_entry().expect("run to entry");
    let (name, depth, _) = at(&mut session);
    assert_eq!((name.as_str(), depth), ("<toplevel>", 0));
}

/// A root that carries the program's body is the entry: its first nested call
/// is a helper the body reaches later, and opening there would skip the
/// body's opening lines.
#[test]
fn a_root_carrying_the_programs_body_is_the_entry() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::MergedEntry));

    // The control: the root's next step is its own, and `work` is nested.
    let reader = session.reader.clone();
    assert_eq!(
        reader.step(StepId(1)).unwrap().call_key,
        reader.step(StepId(0)).unwrap().call_key
    );
    assert!(reader.call_count() >= 2, "the helper call is recorded");

    session.run_to_entry().expect("run to entry");
    let (name, depth, _) = at(&mut session);
    assert_eq!((name.as_str(), depth), ("<toplevel>", 0));
    session.step(Action::Next, true).expect("step over");
    assert_eq!(at(&mut session), ("<toplevel>".to_string(), 0, 2));
}

/// `(function name, call depth, line, column)` of the step the session is at.
fn at_column(session: &mut MaterializedReplaySession) -> (String, usize, i64, Option<i64>) {
    let reader = session.reader.clone();
    let column = reader
        .step(session.current_step_id())
        .expect("the step exists")
        .column
        .map(|column| column.0);
    let (name, depth, line) = at(session);
    (name, depth, line, column)
}

#[test]
fn a_javascript_recording_opens_in_module_past_the_roots_anchor_steps() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_js_module_bundle(dir.path()));

    // The controls: the container really has the shape that defeated the
    // next-step rule. The root's entry step is at 1:1; the `ThreadStart`
    // occupies the next step slot, in the root, with no source position; and
    // the slot after that is the root's definition-position anchor at 1:1 —
    // so `<module>`'s first step is three slots past the entry. The columns
    // survive the round trip, so the statement case below tests statement
    // stepping and not a line-only fallback.
    let reader = session.reader.clone();
    let position = |id: i64| {
        let step = reader.step(StepId(id)).unwrap();
        (step.call_key, step.line.0, step.column.map(|c| c.0))
    };
    let root = reader.call(reader.step(StepId(0)).unwrap().call_key).unwrap();
    assert_eq!(reader.function(root.function_id).unwrap().name, "<toplevel>");
    assert_eq!(position(0), (root.key, 1, Some(1)), "the entry step");
    let (thread_call, thread_line, _) = position(1);
    assert_eq!(thread_call, root.key, "the thread record is in the root");
    assert!(thread_line < 1, "the thread record has no source position");
    assert_eq!(position(2), (root.key, 1, Some(1)), "the anchor before the call");
    assert_ne!(position(3).0, root.key, "`<module>` opens at the fourth slot");
    assert!(
        (0..reader.step_count()).any(|i| reader.step(StepId(i as i64)).unwrap().column == Some(Line(JS_COL_VAR_B))),
        "the `var b` step must carry its column"
    );

    session.run_to_entry().expect("run to entry");
    assert_eq!(
        at_column(&mut session),
        ("<module>".to_string(), 1, 1, Some(1)),
        "run-to-entry must open on `var a` in `<module>`, not on the root's entry step"
    );
}

#[test]
fn a_statement_step_over_from_the_javascript_entry_lands_on_the_same_lines_next_statement() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_js_module_bundle(dir.path()));
    session.run_to_entry().expect("run to entry");

    session.step_over_statement(true).expect("statement step over");
    assert_eq!(
        at_column(&mut session),
        ("<module>".to_string(), 1, 1, Some(JS_COL_VAR_B)),
        "the first statement step from `var a` lands on `var b`, not past the whole module"
    );
    session.step_over_statement(true).expect("statement step over");
    assert_eq!(at_column(&mut session), ("<module>".to_string(), 1, 2, Some(1)));
}

#[test]
fn a_line_step_over_from_the_javascript_entry_steps_one_line_not_the_whole_program() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_js_module_bundle(dir.path()));
    session.run_to_entry().expect("run to entry");

    session.step(Action::Next, true).expect("step over");
    assert_eq!(at_column(&mut session), ("<module>".to_string(), 1, 2, Some(1)));
}

/// A root step at the definition position of the call that opens next is not
/// enough to make it an anchor. The EVM recorder defines each external call's
/// function at the caller's line, so a merged body that ran one line before
/// an external call stands exactly there. Only a step that also repeats the
/// entry position, as the JavaScript anchor does, is positioning.
#[test]
fn a_root_body_line_that_a_call_is_defined_at_is_not_an_anchor() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::ExternalCallAtCallerLine));

    // The control: the root's own step is at line 5, away from the entry
    // line, and the call that opens right after it is defined at line 5.
    let reader = session.reader.clone();
    let root_key = reader.step(StepId(0)).unwrap().call_key;
    let body = reader.step(StepId(1)).unwrap();
    assert_eq!((body.call_key, body.line.0), (root_key, 5));
    let external = reader.call(reader.step(StepId(2)).unwrap().call_key).unwrap();
    assert_ne!(external.key, root_key, "the external call opens at the third slot");
    assert_eq!(reader.function(external.function_id).unwrap().line.0, 5);

    session.run_to_entry().expect("run to entry");
    let (name, depth, _) = at(&mut session);
    assert_eq!((name.as_str(), depth), ("<toplevel>", 0));
}

/// A root whose body starts on the entry line still carries the body. Its
/// step at the entry position is the body's first statement, and the call
/// that follows is a helper defined elsewhere, so that step is no anchor.
/// Treating every step at the entry position as positioning would skip this
/// root and open the recording inside `work`, past the body's line 1.
#[test]
fn a_root_whose_body_starts_on_the_entry_line_is_the_entry() {
    let dir = tempfile::tempdir().unwrap();
    let mut session = open(&write_bundle(dir.path(), Shape::MergedEntryOnEntryLine));

    // The control: the root's own next step is at the entry line, and the
    // helper, defined at line 10, opens right after it.
    let reader = session.reader.clone();
    let root_key = reader.step(StepId(0)).unwrap().call_key;
    let body = reader.step(StepId(1)).unwrap();
    assert_eq!((body.call_key, body.line.0), (root_key, 1));
    let helper = reader.call(reader.step(StepId(2)).unwrap().call_key).unwrap();
    assert_ne!(helper.key, root_key, "`work` opens at the third slot");
    let helper_function = reader.function(helper.function_id).unwrap();
    assert_eq!((helper_function.name.as_str(), helper_function.line.0), ("work", 10));

    session.run_to_entry().expect("run to entry");
    let (name, depth, _) = at(&mut session);
    assert_eq!((name.as_str(), depth), ("<toplevel>", 0));
}
