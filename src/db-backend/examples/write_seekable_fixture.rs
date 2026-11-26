//! Write a PRODUCTION split-stream `.ct` container for the M0 browser-replay
//! runtime probe.
//!
//! Rather than commit a binary blob that nobody can regenerate, this example
//! produces one on demand through the exact Nim FFI write path every live
//! recorder drives.
//!
//! It is deliberately an `example` rather than a `bin`: the crate's binaries
//! all require the `io-transport` feature, and this needs only `nim-reader`.
//!
//! Usage:
//!
//! ```text
//!   cargo run --example write_seekable_fixture -- <output.ct> [user_steps] [--column-aware]
//! ```
//!
//! The trace is a single function looping over `user_steps` lines, recording one
//! integer local per step, plus stdout events — enough to span several
//! `steps.dat` chunks so a bounded read is distinguishable from a whole-stream
//! read.
//!
//! `--column-aware` writes the shape an EVM recording has instead: the writer
//! is put in column-aware mode before any step (as codetracer-evm-recorder
//! does), two source files are registered with their line lengths, and every
//! step carries a column, all inside ONE call. Such a container has no
//! `step-map.ns`, which is what made `load_location` walk the call on every
//! step (codetracer-pm
//! `issues/2026-11-26-large-evm-recordings-cannot-be-debugged-in-the-hydrated-debug-page.md`).

use std::path::Path;
use std::process::ExitCode;

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

const SRC: &str = "/tmp/m0_seekable_fixture.py";
const DISTINCT_LINES: usize = 50;
/// The column-aware shape's two files, as an EVM contract and a library.
const CONTRACT: &str = "/tmp/m0_seekable_fixture/Token.sol";
const LIBRARY: &str = "/tmp/m0_seekable_fixture/SafeMath.sol";
/// Lines per registered file in the column-aware shape.
const FILE_LINES: usize = 500;

fn main() -> ExitCode {
    let (flags, positional): (Vec<String>, Vec<String>) = std::env::args().skip(1).partition(|a| a.starts_with("--"));
    let mut column_aware = false;
    for flag in &flags {
        match flag.as_str() {
            "--column-aware" => column_aware = true,
            other => {
                eprintln!(
                    "unknown flag {other}; usage: write_seekable_fixture <output.ct> [user_steps] [--column-aware]"
                );
                return ExitCode::FAILURE;
            }
        }
    }
    let mut args = positional.into_iter();
    let Some(out) = args.next() else {
        eprintln!("usage: write_seekable_fixture <output.ct> [user_steps] [--column-aware]");
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
    if column_aware {
        // Before the first step, as codetracer-evm-recorder does.
        writer.enable_column_aware_steps();
    }
    if let Err(e) = writer.begin_writing_trace_paths(&trace_prefix) {
        eprintln!("begin_writing_trace_paths failed: {e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = writer.finish_writing_trace_paths() {
        eprintln!("finish_writing_trace_paths failed: {e}");
        return ExitCode::FAILURE;
    }

    if column_aware {
        if let Err(e) = write_column_aware_single_call(&mut writer, user_steps) {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    } else {
        write_line_only_loop(&mut writer, user_steps);
    }
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
    let shape = if column_aware {
        "column-aware single call"
    } else {
        "line-only loop"
    };
    println!(
        "wrote {} ({size} bytes, {user_steps} user steps, {shape})",
        out.display()
    );
    ExitCode::SUCCESS
}

/// The original shape: one function looping over [`DISTINCT_LINES`] lines.
fn write_line_only_loop(writer: &mut NimTraceWriter, user_steps: usize) {
    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(writer, fid, vec![]);

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
                writer,
                codetracer_trace_types::EventLogKind::Write,
                "",
                &format!("tick {i}\n"),
            );
        }
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
}

/// The EVM shape: a column-aware trace whose steps are all in ONE call, spread
/// over two files (one step in eight in the library), each carrying a column.
fn write_column_aware_single_call(writer: &mut NimTraceWriter, user_steps: usize) -> Result<(), String> {
    let contract = Path::new(CONTRACT);
    let library = Path::new(LIBRARY);
    // Registered with their line lengths before `start`: a column-aware reader
    // maps each step's global position back to (line, column) through them.
    let line_lengths = vec![40u32; FILE_LINES];
    for path in [contract, library] {
        writer
            .register_path_with_line_lengths(path, &line_lengths)
            .map_err(|e| format!("register_path_with_line_lengths({}) failed: {e}", path.display()))?;
    }
    writer.start(contract, Line(1));
    // Defined at the entry step's position, so the `<toplevel>` root that
    // `start` opens is recognised as a wrapper and replay starts INSIDE the
    // call, as it does for an EVM recording (`first_user_call`).
    let fid = writer.ensure_function_id("transfer", contract, Line(1));
    writer.register_function("transfer", contract, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "uint256");
    writer.register_step_with_column(contract, Line(1), Some(Line(1)));
    TraceWriter::register_call(writer, fid, vec![]);
    for i in 0..user_steps {
        let path = if i % 8 == 7 { library } else { contract };
        let line = 5 + ((i * 7919) % (FILE_LINES - 10)) as i64;
        writer.register_step_with_column(path, Line(line), Some(Line(1 + (i % 30) as i64)));
        writer.register_variable_with_full_value(
            "balance",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
    }
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    Ok(())
}
