//! M0/1 — the db-backend's WASM-safe interning-table reader decodes the same
//! vocabulary the PRODUCTION Nim FFI reader does, and it finds that vocabulary
//! on a real bundle even though `meta.dat` denies carrying it.
//!
//! ## Why a second reader exists at all
//!
//! `codetracer_trace_reader::interning_tables_reader` is declared
//! `#[cfg(not(target_arch = "wasm32"))]` in that crate, so it does not exist in
//! the browser build — and that crate lives in a separate repository shared by
//! every checkout of this one, so un-gating it there is a cross-repo change.
//! `db_backend::ctfs_trace_reader::interning_tables` is therefore a local,
//! wasm32-clean reader of the same four tables, following the precedent set by
//! `ctfs_trace_reader::meta_dat` (a local `meta.dat` parser that exists for
//! exactly the same reason).
//!
//! Two parsers of one binary format is a drift risk, so the equivalence is
//! asserted rather than assumed. The comparison target is the **Nim FFI
//! reader** reached through `CTFSTraceReader::open` — the production decoder,
//! written in another language against the same spec. Agreement between those
//! two is a far stronger statement than agreement with a hand-written
//! expectation, and stronger than comparing against the upstream Rust reader
//! would be (see the next paragraph for why that one cannot be used here).
//!
//! ## The two format findings this suite pins
//!
//! **1. `meta.dat` bit 12 is clear on every production bundle.**
//! `MultiStreamTraceWriter` creates and fills all four interning tables
//! (`initTraceInterningTables`), but its `writeMetaDat` call omits
//! `hasInterningTables`, which defaults to `false`.
//!
//! **2. That is not a missing bit — it is an honest one.** The bit means "these
//! records are in the M23d STRUCTURED layout", and the Nim writer's are not:
//! `interning_table.nim`'s `ensureId` appends RAW NAME BYTES for all four
//! tables, with no `global_line_index` prefix on a function and no `TypeKind`
//! ordinal on a type. Decoding a real bundle as M23d fails outright — it did,
//! with `funcs.dat: record 0 name extends past record`, which is how this was
//! found.
//!
//! So the upstream `InterningTablesReader` cannot serve as the comparison
//! target twice over: it returns `Ok(None)` on a production bundle, and its
//! decoder expects the other layout. The local reader therefore detects
//! PRESENCE from the container and selects the LAYOUT from the flag.
//! `reader_finds_tables_a_real_bundle_does_not_advertise` and
//! `a_production_bundle_uses_the_plain_record_layout` pin both halves, so a
//! future "tidy-up" back to a flag-only presence check fails loudly instead of
//! quietly emptying the Variables pane.
//!
//! ## No skip path
//!
//! The bundle is produced at test time by the real writer. Nothing here can be
//! absent, and no case can pass without both decoders actually decoding.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{FunctionId, Line, PathId, TypeId, TypeKind, ValueRecord, VariableId};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::ctfs_trace_reader::interning_tables::InterningTables;
use db_backend::trace_reader::TraceReader;

const SRC_A: &str = "/tmp/m0_interning_a.py";
const SRC_B: &str = "/tmp/m0_interning_b.py";

/// Write a split-only production bundle carrying a non-trivial vocabulary: two
/// paths, two functions at DIFFERENT lines (so a stubbed `line` shows up),
/// several types and several variable names.
fn write_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m0_interning");
    let ct_path = dir.join("m0_interning_prog.ct");

    let mut writer = NimTraceWriter::new("m0_interning_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path_a = Path::new(SRC_A);
    let path_b = Path::new(SRC_B);

    let main_id = writer.ensure_function_id("main", path_a, Line(3));
    writer.register_function("main", path_a, Line(3));
    let helper_id = writer.ensure_function_id("helper", path_b, Line(17));
    writer.register_function("helper", path_b, Line(17));

    writer.start(path_a, Line(3));
    writer.register_step(path_a, Line(3));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    let str_type = writer.ensure_type_id(TypeKind::String, "str");
    TraceWriter::register_call(&mut writer, main_id, vec![]);

    for i in 0..64 {
        writer.register_step(path_a, Line(3 + (i % 5) as i64));
        writer.register_variable_with_full_value(
            "counter",
            ValueRecord::Int {
                i: i as i64,
                type_id: int_type,
            },
        );
        writer.register_variable_with_full_value(
            "label",
            ValueRecord::String {
                text: format!("row-{i}"),
                type_id: str_type,
            },
        );
    }

    writer.register_step(path_b, Line(17));
    TraceWriter::register_call(&mut writer, helper_id, vec![]);
    writer.register_variable_with_full_value(
        "inner",
        ValueRecord::Int {
            i: 7,
            type_id: int_type,
        },
    );
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.register_return(ValueRecord::None { type_id: TypeId(0) });

    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(ct_path.exists(), "the Nim writer must produce {}", ct_path.display());
    ct_path
}

/// The local reader and the production Nim FFI reader see the same vocabulary,
/// id for id: same counts, same paths, same function names, same type names,
/// same variable names.
#[test]
fn local_reader_and_nim_ffi_reader_agree_on_the_vocabulary() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct_path).expect("open for the local reader");
    let local = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("the local reader must not error")
        .expect("the production bundle carries binary interning tables");

    let nim = CTFSTraceReader::open(&ct_path).expect("the Nim FFI reader must open the bundle");

    // The fixture is non-trivial, so a reader that decoded nothing cannot pass.
    assert!(local.paths.len() >= 2, "the fixture interns at least two paths");
    assert!(local.functions.len() >= 2, "the fixture interns at least two functions");
    assert!(!local.types.is_empty(), "the fixture interns types");
    assert!(
        local.variable_names.len() >= 3,
        "the fixture interns at least three variable names"
    );

    assert_eq!(local.paths.len(), nim.path_count(), "path count");
    assert_eq!(local.functions.len(), nim.function_count(), "function count");
    assert_eq!(local.types.len(), nim.type_count(), "type count");
    assert!(
        nim.variable_name(VariableId(local.variable_names.len())).is_none(),
        "the Nim reader must not know MORE variable names than the local reader decoded"
    );

    for id in 0..local.paths.len() {
        assert_eq!(
            local.paths[id],
            nim.path(PathId(id)).expect("nim path"),
            "path {id} disagrees between the pure-Rust and Nim decoders"
        );
    }
    for id in 0..local.functions.len() {
        assert_eq!(
            local.functions[id].name,
            nim.function(FunctionId(id)).expect("nim function").name,
            "function {id} name"
        );
    }
    for id in 0..local.types.len() {
        assert_eq!(
            local.types[id].lang_type,
            nim.type_record(TypeId(id)).expect("nim type").lang_type,
            "type {id} lang_type"
        );
    }
    for id in 0..local.variable_names.len() {
        assert_eq!(
            local.variable_names[id],
            nim.variable_name(VariableId(id)).expect("nim varname"),
            "varname {id}"
        );
    }
}

/// A real production bundle does NOT stamp `meta.dat` bit 12, yet carries the
/// tables. This pins both halves: the flag really is clear, and the reader
/// really does find the tables anyway.
///
/// If the writer is fixed to stamp the bit, the first assertion here fails by
/// name and this test becomes the place to record that — which is the point.
/// A reader change back to flag-only detection fails the second.
#[test]
fn reader_finds_tables_a_real_bundle_does_not_advertise() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct_path).expect("open");
    let meta = ctfs.read_file("meta.dat").expect("every bundle carries meta.dat");
    let parsed = db_backend::ctfs_trace_reader::meta_dat::parse_meta_dat(&meta).expect("meta.dat parses");
    let flagged = parsed.flags & db_backend::ctfs_trace_reader::meta_dat::FLAG_HAS_INTERNING_TABLES != 0;

    assert!(
        !flagged,
        "meta.dat now stamps has_interning_tables. The writer-side omission this reader works \
         around has been fixed — update `InterningTables::open_from_ctfs`'s docs and this test."
    );
    assert!(
        ctfs.has_file("paths.dat") && ctfs.has_file("funcs.dat"),
        "the bundle must actually carry the tables, or the point above is moot"
    );

    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("no error")
        .expect("the reader must find tables the container carries even when meta.dat denies them");
    assert!(!tables.functions.is_empty(), "functions must decode");
    assert!(!tables.variable_names.is_empty(), "variable names must decode");
}

/// A production bundle's tables are in the PLAIN layout, and the reader says so.
///
/// This is the finding that made `RecordLayout` necessary. The M23d structured
/// layout — `funcs.dat` records prefixed with a packed `global_line_index`,
/// `types.dat` records prefixed with a `TypeKind` ordinal — is what the spec
/// describes and what the upstream Rust reader assumes. The Nim writer's
/// `ensureId` appends RAW NAME BYTES for all four tables, so decoding a real
/// bundle as M23d fails outright (it did: `funcs.dat: record 0 name extends
/// past record`).
///
/// Two consequences are asserted here, because both are load-bearing and
/// neither is guessable from the spec:
///
/// 1. Both source files are interned and recoverable — the paths table IS
///    usable, so the browser reader can resolve `PathId`s.
/// 2. A function's definition site is NOT on disk in this layout, so both this
///    reader and the Nim FFI reader report `(PathId(0), Line(0))`. If a writer
///    starts recording it, this fails and names the fix.
#[test]
fn a_production_bundle_uses_the_plain_record_layout() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct_path).expect("open");
    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("no error")
        .expect("tables");

    assert_eq!(
        tables.layout,
        db_backend::ctfs_trace_reader::interning_tables::RecordLayout::Plain,
        "a bundle from the production Nim writer uses the plain (name-only) record layout"
    );

    assert!(
        tables.paths.iter().any(|p| p == SRC_A),
        "the first source file must be interned; got {:?}",
        tables.paths
    );
    assert!(
        tables.paths.iter().any(|p| p == SRC_B),
        "the second source file must be interned; got {:?}",
        tables.paths
    );

    let main = tables
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`main` must be interned");
    let helper = tables
        .functions
        .iter()
        .find(|f| f.name == "helper")
        .expect("`helper` must be interned");

    assert_eq!(
        (main.path_id, main.line),
        (PathId(0), Line(0)),
        "the plain layout carries no definition site for a function"
    );
    assert_eq!(
        (helper.path_id, helper.line),
        (PathId(0), Line(0)),
        "the plain layout carries no definition site for a function"
    );
}

/// A LEGACY container with no interning tables yields `Ok(None)` rather than an
/// error, so such a bundle still opens and falls back to its own interning.
///
/// The subject is the committed `stylus-fund` fixture — a real old-format
/// `events.log` bundle. If it is missing this FAILS rather than skipping.
#[test]
fn a_legacy_container_without_tables_yields_none() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct");
    assert!(
        fixture.is_file(),
        "the legacy fixture {} is required by this case; without it there is nothing to test",
        fixture.display()
    );

    let mut ctfs = CtfsReader::open(&fixture).expect("the legacy fixture must open as a CTFS container");
    assert!(
        !ctfs.has_file("paths.dat"),
        "the fixture must genuinely lack the binary tables, or this case has no subject"
    );
    assert!(
        InterningTables::open_from_ctfs(&mut ctfs)
            .expect("no error")
            .is_none(),
        "a container without the tables must yield None, not an error"
    );
}
