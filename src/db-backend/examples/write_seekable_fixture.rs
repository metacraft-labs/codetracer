//! Write a PRODUCTION split-stream (`events.log`-free) `.ct` container for the
//! M0 browser-replay runtime probe.
//!
//! The committed fixtures under `tests/fixtures/` are legacy `events.log`
//! bundles, so none of them can exercise the M0 browser constructor — that
//! constructor's whole point is opening the NEW format. Rather than commit a
//! binary blob that nobody can regenerate, this example produces one on demand
//! through the exact Nim FFI write path every live recorder drives.
//!
//! It is deliberately an `example` rather than a `bin`: the crate's binaries
//! all require the `io-transport` feature, and this needs only `nim-reader`.
//!
//! Usage:
//!
//! ```text
//!   cargo run --example write_seekable_fixture -- <output.ct> [user_steps]
//! ```
//!
//! The trace is a single function looping over `user_steps` lines, recording one
//! integer local per step, plus stdout events — enough to span several
//! `steps.dat` chunks so a bounded read is distinguishable from a whole-stream
//! read.

use std::path::Path;
use std::process::ExitCode;

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

const SRC: &str = "/tmp/m0_seekable_fixture.py";
const DISTINCT_LINES: usize = 50;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(out) = args.next() else {
        eprintln!("usage: write_seekable_fixture <output.ct> [user_steps]");
        return ExitCode::FAILURE;
    };
    let user_steps: usize = match args.next() {
        Some(n) => match n.parse() {
            Ok(n) => n,
            Err(e) => {
                eprintln!("user_steps must be a number: {e}");
                return ExitCode::FAILURE;
            }
        },
        None => 9000,
    };

    let out = Path::new(&out);
    let Some(dir) = out.parent() else {
        eprintln!("output path {} has no parent directory", out.display());
        return ExitCode::FAILURE;
    };
    if let Err(e) = std::fs::create_dir_all(dir) {
        eprintln!("cannot create {}: {e}", dir.display());
        return ExitCode::FAILURE;
    }

    // The Nim writer derives the container name from the program name and the
    // trace prefix, so write into a scratch directory and move the result to
    // the requested path.
    let stem = out
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("m0_seekable_fixture")
        .to_string();
    let trace_prefix = dir.join(&stem);
    let produced = dir.join(format!("{stem}.ct"));

    let mut writer = NimTraceWriter::new(&stem, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    if let Err(e) = writer.begin_writing_trace_metadata(&trace_prefix) {
        eprintln!("begin_writing_trace_metadata failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.finish_writing_trace_metadata() {
        eprintln!("finish_writing_trace_metadata failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.begin_writing_trace_events(&trace_prefix) {
        eprintln!("begin_writing_trace_events failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.begin_writing_trace_paths(&trace_prefix) {
        eprintln!("begin_writing_trace_paths failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.finish_writing_trace_paths() {
        eprintln!("finish_writing_trace_paths failed: {e}");
        return ExitCode::FAILURE;
    }

    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..user_steps {
        writer.register_step(path, Line(10 + (i % DISTINCT_LINES) as i64));
        writer.register_variable_with_full_value(
            "var",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
        // A handful of I/O events, so the seekable `events.dat` path has
        // something to serve.
        if i.is_multiple_of(1000) {
            TraceWriter::register_special_event(
                &mut writer,
                codetracer_trace_types::EventLogKind::Write,
                "",
                &format!("tick {i}\n"),
            );
        }
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    if let Err(e) = writer.finish_writing_trace_events() {
        eprintln!("finish_writing_trace_events failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.close() {
        eprintln!("close failed: {e}");
        return ExitCode::FAILURE;
    }

    if !produced.exists() {
        eprintln!("the writer did not produce {}", produced.display());
        return ExitCode::FAILURE;
    }
    if produced != out
        && let Err(e) = std::fs::rename(&produced, out)
    {
        eprintln!("cannot move {} to {}: {e}", produced.display(), out.display());
        return ExitCode::FAILURE;
    }

    let size = std::fs::metadata(out).map(|m| m.len()).unwrap_or(0);
    println!("wrote {} ({size} bytes, {user_steps} user steps)", out.display());
    ExitCode::SUCCESS
}
