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
//! would be.
//!
//! ## The format facts this suite pins
//!
//! **1. `meta.dat` bit 12 (`has_interning_tables`) is set on a production
//! bundle**, and the tables are there.
//!
//! **2. The records are in the spec's structured shape**
//! (`codetracer-trace-format-spec/internal-files.md`): a `funcs.dat` record is
//! `global_line_index: varint, name_len: varint, name`, a `types.dat` record is
//! `kind: u8, lang_type_len: varint, lang_type, specific_info`. The Nim writer
//! once appended raw name bytes to all four tables and left bit 12 clear; every
//! reader now refuses such a record by name
//! (`interning_tables_record_shape_test.rs`).
//!
//! `a_production_bundle_advertises_its_interning_tables` and
//! `a_production_bundle_uses_the_structured_record_layout` pin both, including
//! each function's declaration site as BOTH readers report it.
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

/// A production bundle stamps `meta.dat` bit 12 (`has_interning_tables`) and
/// carries the tables, and the reader finds them through the flag.
///
/// `internal-files.md` gates the four tables on that bit. A reader that
/// detected them by presence alone would still pass here, so presence is
/// asserted separately: the flag is set AND the files are there.
#[test]
fn a_production_bundle_advertises_its_interning_tables() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct_path).expect("open");
    let meta = ctfs.read_file("meta.dat").expect("every bundle carries meta.dat");
    let parsed = db_backend::ctfs_trace_reader::meta_dat::parse_meta_dat(&meta).expect("meta.dat parses");
    let flagged = parsed.flags & db_backend::ctfs_trace_reader::meta_dat::FLAG_HAS_INTERNING_TABLES != 0;

    assert!(
        flagged,
        "meta.dat must stamp has_interning_tables on a bundle that carries the tables \
         (internal-files.md, meta.dat flags)"
    );
    assert!(
        ctfs.has_file("paths.dat") && ctfs.has_file("funcs.dat"),
        "the bundle must actually carry the tables the flag advertises"
    );

    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("no error")
        .expect("the reader must find the tables the container advertises");
    assert!(!tables.functions.is_empty(), "functions must decode");
    assert!(!tables.variable_names.is_empty(), "variable names must decode");
}

/// A production bundle's `funcs.dat` / `types.dat` records are in the spec's
/// STRUCTURED shape, and both readers recover each function's declaration site
/// from it.
///
/// `codetracer-trace-format-spec/internal-files.md` gives a `funcs.dat` record
/// as `global_line_index: varint, name_len: varint, name` and a `types.dat`
/// record as `kind: u8, lang_type_len: varint, lang_type, specific_info`. The
/// `global_line_index` is the declaration site in the trace's global position
/// space, so a reader recovers `(path_id, line)` from it. The fixture declares
/// `main` at `SRC_A:3` and `helper` at `SRC_B:17` — two different files and two
/// different lines — so a reader that stubbed either field, or resolved the
/// address against the wrong space, fails here by name.
///
/// The native reader is checked as well as the local one because the Nim FFI
/// exposes only a function's NAME; the declaration site reaches the native
/// `Db` only if the reader recovers it from the container itself.
#[test]
fn a_production_bundle_uses_the_structured_record_layout() {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_bundle(dir.path());

    let mut ctfs = CtfsReader::open(&ct_path).expect("open");
    let tables = InterningTables::open_from_ctfs(&mut ctfs)
        .expect("no error")
        .expect("tables");

    let path_a = tables
        .paths
        .iter()
        .position(|p| p == SRC_A)
        .unwrap_or_else(|| panic!("the first source file must be interned; got {:?}", tables.paths));
    let path_b = tables
        .paths
        .iter()
        .position(|p| p == SRC_B)
        .unwrap_or_else(|| panic!("the second source file must be interned; got {:?}", tables.paths));

    let site = |functions: &[(String, PathId, Line)], name: &str| -> (PathId, Line) {
        functions
            .iter()
            .find(|(n, _, _)| n == name)
            .map(|(_, p, l)| (*p, *l))
            .unwrap_or_else(|| panic!("`{name}` must be interned"))
    };

    let local: Vec<(String, PathId, Line)> = tables
        .functions
        .iter()
        .map(|f| (f.name.clone(), f.path_id, f.line))
        .collect();
    assert_eq!(
        site(&local, "main"),
        (PathId(path_a), Line(3)),
        "local reader: `main` site"
    );
    assert_eq!(
        site(&local, "helper"),
        (PathId(path_b), Line(17)),
        "local reader: `helper` site"
    );

    let nim = CTFSTraceReader::open(&ct_path).expect("the Nim FFI reader must open the bundle");
    let native: Vec<(String, PathId, Line)> = (0..nim.function_count())
        .map(|id| {
            let f = nim.function(FunctionId(id)).expect("nim function");
            (f.name.clone(), f.path_id, f.line)
        })
        .collect();
    assert_eq!(
        site(&native, "main"),
        (PathId(path_a), Line(3)),
        "native reader: `main` site"
    );
    assert_eq!(
        site(&native, "helper"),
        (PathId(path_b), Line(17)),
        "native reader: `helper` site"
    );
}

/// A LEGACY container with no interning tables yields `Ok(None)` rather than an
/// error, so such a bundle still opens and falls back to its own interning.
///
/// The subject is the committed `stylus-fund` fixture — a real old-format
/// `events.log` bundle. If it is missing this FAILS rather than skipping.
#[test]
fn a_legacy_container_without_tables_yields_none() {
    let fixture =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct");
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
        InterningTables::open_from_ctfs(&mut ctfs).expect("no error").is_none(),
        "a container without the tables must yield None, not an error"
    );
}

/// The native reader keeps a struct type's KIND and FIELD NAMES, not only its
/// name.
///
/// The Nim FFI exposes a type's name alone; the `types.dat` record also carries
/// `kind` and `specific_info`. The native reader once built every type from the
/// FFI name as `Raw` with no fields, so a struct value's members reached every
/// front-end unnamed — `[0]` in the locals pane where the recording says `a`.
///
/// The subject is the committed in-repo fixture recording
/// (`trace/trace.ct`, `struct TestStruct { a: i32 }`): the Rust wrapper over
/// the Nim writer cannot write a struct's fields (`ensure_raw_type_id` keeps
/// only kind and name), so a bundle written here would have no fields to
/// lose. If the fixture is missing this FAILS rather than skipping.
#[test]
fn the_native_reader_keeps_a_struct_types_kind_and_field_names() {
    use codetracer_trace_types::TypeSpecificInfo;

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("trace/trace.ct");
    assert!(
        fixture.is_file(),
        "the fixture {} is required by this case",
        fixture.display()
    );

    // The control: the container itself carries the struct and its field.
    let mut ctfs = CtfsReader::open(&fixture).expect("open");
    let tables = InterningTables::open_from_ctfs(&mut ctfs).unwrap().unwrap();
    let id = tables
        .types
        .iter()
        .position(|t| t.lang_type == "struct TestStruct")
        .expect("the fixture interns `struct TestStruct`");
    let local = &tables.types[id];
    assert!(
        matches!(&local.specific_info, TypeSpecificInfo::Struct { fields } if fields.iter().any(|f| f.name == "a")),
        "types.dat records the field `a`; got {local:?}"
    );

    let nim = CTFSTraceReader::open(&fixture).expect("the Nim FFI reader must open the fixture");
    let native = nim.type_record(TypeId(id)).expect("the struct type is interned");
    assert_eq!(
        native.kind,
        TypeKind::Struct,
        "the native reader must keep the type's kind"
    );
    let fields: Vec<&str> = match &native.specific_info {
        TypeSpecificInfo::Struct { fields } => fields.iter().map(|f| f.name.as_str()).collect(),
        other => panic!("the native reader must keep the struct's fields; got {other:?}"),
    };
    assert_eq!(fields, ["a"]);
    assert_eq!(native, local, "the native and pure-Rust readers decode the same record");
}
