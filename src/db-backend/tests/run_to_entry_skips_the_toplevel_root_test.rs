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
//! steps in the root itself; for them the root is the entry, and the last
//! case pins that it still is.
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
}

fn write_bundle(dir: &Path, shape: Shape) -> PathBuf {
    let name = match shape {
        Shape::Wrapped => "root_prog",
        Shape::RootOnly => "root_only",
        Shape::MergedEntry => "root_merged",
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
    } else {
        writer.register_step(path, Line(2));
    }
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
