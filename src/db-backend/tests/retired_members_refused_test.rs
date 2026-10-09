//! `events.log` and `events.fmt` are not part of the trace format. A container
//! carrying either is refused by name when the db-backend opens it, with the
//! sentence the format library's own readers use, whichever way it is opened
//! and whatever else the container holds.
//!
//! The containers are real recordings written by the Nim multi-stream writer
//! (the path every live recorder drives), with the retired member added beside
//! their streams. Without it the db-backend reads them, which the control
//! asserts. No mocks.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_ctfs::{CompressionMethod, CtfsWriter};
use codetracer_trace_reader::retired_streams::{RETIRED_MEMBERS, refuse_retired_members};
use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};
use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

const PROGRAM: &str = "retired_members_prog";

fn recording(dir: &Path) -> PathBuf {
    let trace_path = dir.join(PROGRAM);
    let mut writer = NimTraceWriter::new(PROGRAM, &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new("/tmp/retired_members_prog.py");
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);
    for i in 0..3 {
        writer.register_step(path, Line(2 + i));
        writer.register_variable_with_full_value("x", ValueRecord::Int { i, type_id: int_type });
    }
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();
    dir.join(format!("{PROGRAM}.ct"))
}

/// The members of the container at `ct`, minus `drop`, plus `(name, content)`
/// when given, written to `out`.
fn rewrite(ct: &Path, drop: &[&str], add: Option<(&str, &[u8])>, out: &Path) {
    let mut reader = codetracer_ctfs::CtfsReader::open(ct).expect("open");
    let mut w = CtfsWriter::create_in_memory(4096, 31, CompressionMethod::None).expect("create");
    for (member, data) in reader.members().expect("members") {
        if drop.contains(&member.as_str()) {
            continue;
        }
        let h = w.add_file(&member).expect("add");
        w.write(h, &data).expect("write");
    }
    if let Some((name, content)) = add {
        let h = w.add_file(name).expect("add retired");
        w.write(h, content).expect("write retired");
    }
    std::fs::write(out, w.finish_to_bytes().expect("finish")).expect("write file");
}

/// The format library's refusal of the container at `ct`.
fn library_refusal(ct: &Path) -> String {
    let reader = codetracer_ctfs::CtfsReader::open(ct).expect("the library opens the container");
    refuse_retired_members(&reader).expect_err("the library refuses the container")
}

fn assert_refused(ct: &Path, member: &str, case: &str) {
    let expected = library_refusal(ct);
    assert!(
        expected.contains(member),
        "{case}: the library refusal does not name {member}: {expected}"
    );

    let by_path = match CTFSTraceReader::open(ct) {
        Ok(reader) => panic!("{case}: open read it ({} steps)", reader.step_count()),
        Err(e) => e.to_string(),
    };
    assert_eq!(
        by_path, expected,
        "{case}: open does not refuse with the library's sentence"
    );

    let by_bytes = match CTFSTraceReader::from_bytes(std::fs::read(ct).unwrap()) {
        Ok(reader) => panic!("{case}: from_bytes read it ({} steps)", reader.step_count()),
        Err(e) => e.to_string(),
    };
    assert_eq!(
        by_bytes, expected,
        "{case}: from_bytes does not refuse with the library's sentence"
    );

    let by_follow = match CTFSTraceReader::open_follow(ct) {
        Ok(reader) => panic!("{case}: open_follow read it ({} steps)", reader.step_count()),
        Err(e) => e.to_string(),
    };
    assert_eq!(
        by_follow, expected,
        "{case}: open_follow does not refuse with the library's sentence"
    );
}

#[test]
fn a_container_carrying_a_retired_member_is_refused_by_name() {
    let dir = tempfile::tempdir().unwrap();
    let ct = recording(dir.path());

    // The control: as written, the db-backend reads it, through every opener.
    let reader = CTFSTraceReader::open(&ct).unwrap_or_else(|e| panic!("the recording does not open: {e}"));
    assert!(reader.step_count() > 0, "the control recording has no steps");
    CTFSTraceReader::from_bytes(std::fs::read(&ct).unwrap()).unwrap_or_else(|e| panic!("from_bytes: {e}"));
    CTFSTraceReader::open_follow(&ct).unwrap_or_else(|e| panic!("open_follow: {e}"));

    for member in RETIRED_MEMBERS {
        for content in [&b"\0"[..], &b""[..], &b"split-binary"[..]] {
            // Beside the split streams.
            let beside = dir.path().join(format!("beside-{member}-{}.ct", content.len()));
            rewrite(&ct, &[], Some((member, content)), &beside);
            assert_refused(
                &beside,
                member,
                &format!("{member} ({} bytes) beside the streams", content.len()),
            );

            // In place of the split streams: only `meta.dat` and the member.
            let streams: Vec<String> = codetracer_ctfs::CtfsReader::open(&ct)
                .unwrap()
                .list_files()
                .into_iter()
                .filter(|n| n != "meta.dat")
                .collect();
            let streams: Vec<&str> = streams.iter().map(String::as_str).collect();
            let alone = dir.path().join(format!("alone-{member}-{}.ct", content.len()));
            rewrite(&ct, &streams, Some((member, content)), &alone);
            assert_refused(
                &alone,
                member,
                &format!("{member} ({} bytes) with only meta.dat", content.len()),
            );
        }
    }
}
