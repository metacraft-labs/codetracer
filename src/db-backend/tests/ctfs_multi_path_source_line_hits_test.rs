//! `source_line_hits` must find the hits recorded in a trace's SECOND source
//! file.
//!
//! The writer keys `linehits.tc` by a line's address in the trace's own position
//! space — `linehits_builder.nim` `recordHit` is called with the same
//! `global_line_index` the step stream carries. A query that builds a
//! differently-shaped integer looks up a key nothing ever wrote, and the miss is
//! silent: `OwnedLinehitsNamespace::source_line_hits` ends in
//! `unwrap_or_default()`, so the caller gets `[]` and no error.
//!
//! Every key in a single-file trace is under `DEFAULT_LINES_PER_FILE` and
//! coincides under both readings, which is why no existing fixture could see
//! this. This one records in two files and asks about the second.
//!
//! `OwnedLinehitsNamespace` is queried directly rather than through
//! `CTFSTraceReader::omniscient_db`, because the `dyn OmniscientDb` return type
//! also pulls in the MCR emulator's shared object, which is not part of what
//! this test is about.
//!
//! # What is constructed here, and what is not
//!
//! The Nim writer's `enableLinehits` is not on its FFI surface, so a Rust test
//! cannot ask it for a `linehits.tc`. The namespace is therefore built here —
//! but NOT from keys this test computes. `linehits_builder.nim` `recordHit` is
//! called with exactly the `global_line_index` the step stream carries, so the
//! keys are read back OUT of the `steps.dat` the Nim writer produced, one per
//! step, and the path table is copied out of the same container. The keying
//! under test is the writer's, taken from the writer's own bytes; only the
//! container assembly is local.
//!
//! Requires the `nim-reader` feature (in the crate's default feature set).

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use codetracer_trace_reader::step_stream_reader::open_step_stream;
use codetracer_trace_writer::step_stream::StepStreamRecord;

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
use db_backend::ctfs_trace_reader::interval_tagged_map::{IntervalTaggedMap, LineHitEntry};
use db_backend::ctfs_trace_reader::linehits_namespace::{
    CTFS_LINEHITS_COW_FILE, OwnedLinehitsNamespace, encode_linehits_cow_namespace,
};
use db_backend::omniscient_db::OmniscientDb;

const MAIN_SRC: &str = "/tmp/linehits_multi_path_main.py";
const LIB_SRC: &str = "/tmp/linehits_multi_path_lib.py";

/// The line in `LIB_SRC` the assertions ask about.
const LIB_LINE: i64 = 12;
/// The line in `MAIN_SRC` the assertions ask about — the control, since path 0
/// resolves the same way under every apportionment.
const MAIN_LINE: i64 = 4;

/// Record a two-file trace through the production Nim writer and return its
/// `.ct`. The steps alternate so both files carry hits.
fn write_two_path_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("linehits_multi_path");
    let ct_path = dir.join("linehits_multi_path_main.ct");

    let mut writer = NimTraceWriter::new("linehits_multi_path_main", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let main_path = Path::new(MAIN_SRC);
    let lib_path = Path::new(LIB_SRC);
    let fid = writer.ensure_function_id("main", main_path, Line(1));
    writer.register_function("main", main_path, Line(1));

    writer.start(main_path, Line(1));
    writer.register_step(main_path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..6i64 {
        writer.register_step(main_path, Line(MAIN_LINE));
        writer.register_variable_with_full_value("var", ValueRecord::Int { i, type_id: int_type });
        writer.register_step(lib_path, Line(LIB_LINE));
        writer.register_variable_with_full_value("var", ValueRecord::Int { i, type_id: int_type });
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), ".ct should be produced at {}", ct_path.display());
    ct_path
}

/// The path id each source file interned to, read from the container's own path
/// table so the test asks about the ids the writer actually assigned.
fn path_ids(ctfs: &mut CtfsReader) -> (usize, usize) {
    let dat = ctfs.read_file("paths.dat").expect("paths.dat");
    let off = ctfs.read_file("paths.off").expect("paths.off");
    let count = off.len() / 8 - 1;
    let mut main_id = None;
    let mut lib_id = None;
    for id in 0..count {
        let lo = u64::from_le_bytes(off[id * 8..id * 8 + 8].try_into().unwrap()) as usize;
        let hi = u64::from_le_bytes(off[(id + 1) * 8..(id + 1) * 8 + 8].try_into().unwrap()) as usize;
        let name = String::from_utf8_lossy(&dat[lo..hi]).into_owned();
        if name == MAIN_SRC {
            main_id = Some(id);
        } else if name == LIB_SRC {
            lib_id = Some(id);
        }
    }
    (
        main_id.expect("main source interned"),
        lib_id.expect("lib source interned"),
    )
}

/// Rebuild the container the writer would have produced with linehits enabled:
/// the SAME path table, plus a `linehits.tc` keyed by the addresses the writer
/// put in `steps.dat` — which is what `linehits_builder.nim` keys it by.
fn container_with_linehits_from_its_own_steps(source_ct: &Path, dest: &Path) {
    let mut stream = open_step_stream(source_ct)
        .expect("read the Nim-written steps.dat")
        .expect("the Nim writer stamps has_step_stream");
    let mut map: IntervalTaggedMap<LineHitEntry> = IntervalTaggedMap::new();
    for (step_id, record) in stream.read_all().expect("decode steps.dat").iter().enumerate() {
        if let StepStreamRecord::Step { global_line_index } = record {
            map.append(*global_line_index, 0, LineHitEntry { tick: step_id as u64 });
        }
    }
    let image = encode_linehits_cow_namespace(&map)
        .expect("encode linehits.tc")
        .expect("the trace has steps, so the namespace is non-empty");

    let mut ctfs = CtfsReader::open(source_ct).expect("open the Nim-written container");
    let meta = ctfs.read_file("meta.dat").expect("meta.dat");
    let paths_dat = ctfs.read_file("paths.dat").expect("paths.dat");
    let paths_off = ctfs.read_file("paths.off").expect("paths.off");
    write_minimal_ctfs(
        dest,
        &[
            ("meta.dat", meta.as_slice()),
            ("paths.dat", paths_dat.as_slice()),
            ("paths.off", paths_off.as_slice()),
            (CTFS_LINEHITS_COW_FILE, image.as_slice()),
        ],
    )
    .expect("assemble the linehits container");
}

/// THE REPRODUCER. A `source_line_hits` query for the second file's line finds
/// the steps recorded there.
#[test]
fn source_line_hits_finds_the_second_files_hits() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_two_path_bundle(dir.path());
    let with_hits = dir.path().join("with_linehits.ct");
    container_with_linehits_from_its_own_steps(&ct, &with_hits);

    let mut ctfs = CtfsReader::open(&with_hits).expect("open the assembled container");
    let (main_id, lib_id) = path_ids(&mut ctfs);
    assert_ne!(main_id, lib_id, "the two sources must intern to different ids");
    assert!(
        lib_id > 0,
        "the second file must not be path 0, where every reading agrees"
    );

    let ns = OwnedLinehitsNamespace::open_from_ctfs(&mut ctfs).expect("open linehits.tc");

    let main_hits = ns.source_line_hits(main_id as u32, MAIN_LINE as u32);
    assert!(
        !main_hits.is_empty(),
        "the FIRST file's line {MAIN_LINE} must have hits — if this is empty the fixture, \
         not the keying, is wrong"
    );

    let lib_hits = ns.source_line_hits(lib_id as u32, LIB_LINE as u32);
    assert!(
        !lib_hits.is_empty(),
        "a source_line_hits query for {LIB_SRC}:{LIB_LINE} (path {lib_id}) must find the steps \
         recorded there; an empty answer is the silent miss this test exists for"
    );
    assert_eq!(
        lib_hits.len(),
        main_hits.len(),
        "the fixture records the same number of steps in each file"
    );

    // A line nothing executed has no hits — so the assertions above are about
    // finding the right key, not about the namespace answering everything.
    assert!(
        ns.source_line_hits(lib_id as u32, LIB_LINE as u32 + 500).is_empty(),
        "a line the trace never executed must have no hits"
    );
}
