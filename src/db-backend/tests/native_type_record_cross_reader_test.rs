//! Real shipping-writer/native/materialized type-record equivalence.
//! No recorder/compiler/reader mock is used: the production Rust writer emits
//! the .ct, and both production reader entry points decode those exact bytes.
//! This file currently covers genuine positive cross-reader equivalence only;
//! it does not replace malformed/follow controls or the full language suites.
#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use codetracer_trace_types::*;
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use std::path::Path;

fn expected_types() -> Vec<TypeRecord> {
    vec![
        TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".into(),
            specific_info: TypeSpecificInfo::None,
        },
        TypeRecord {
            kind: TypeKind::Int,
            lang_type: "Field".into(),
            specific_info: TypeSpecificInfo::None,
        },
        TypeRecord {
            kind: TypeKind::Struct,
            lang_type: "ActualStruct".into(),
            specific_info: TypeSpecificInfo::Struct {
                fields: vec![FieldTypeRecord {
                    name: "field".into(),
                    type_id: TypeId(1),
                }],
            },
        },
        TypeRecord {
            kind: TypeKind::Pointer,
            lang_type: "ActualPointer".into(),
            specific_info: TypeSpecificInfo::Pointer {
                dereference_type_id: TypeId(2),
            },
        },
    ]
}

fn write_bundle(root: &Path, records: &[TypeRecord]) -> std::path::PathBuf {
    let stem = root.join("typed");
    let mut writer = CtfsTraceWriter::new("typed_projection", &[]);
    TraceWriter::begin_writing_trace_events(&mut writer, &stem).expect("real writer begin");
    let mut events = vec![TraceLowLevelEvent::Path("/actual/typed.rs".into())];
    events.extend(records.iter().cloned().map(TraceLowLevelEvent::Type));
    events.extend([
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".into(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(2),
        }),
        TraceLowLevelEvent::Return(ReturnRecord {
            return_value: ValueRecord::None { type_id: TypeId(0) },
        }),
    ]);
    TraceWriter::append_events(&mut writer, &mut events);
    TraceWriter::finish_writing_trace_events(&mut writer).expect("real writer finish");
    stem.with_extension("ct")
}

#[test]
fn native_and_materialized_readers_preserve_every_complete_type_record() {
    let dir = tempfile::tempdir().unwrap();
    let expected = expected_types();
    let ct = write_bundle(dir.path(), &expected);
    let native = CTFSTraceReader::open(&ct).expect("actual Nim-backed open");
    let materialized = CTFSTraceReader::from_bytes(std::fs::read(&ct).unwrap()).expect("actual Rust-backed open");
    assert_eq!(native.db().types.items, expected);
    assert_eq!(materialized.db().types.items, expected);
    assert_eq!(native.db().types.items, materialized.db().types.items);
    // The same genuine function-site path/line remains attached after the
    // shared interning-table decode; type reuse must not drop site identity.
    for reader in [&native, &materialized] {
        assert_eq!(reader.db().functions.len(), 1);
        let function = &reader.db().functions[FunctionId(0)];
        assert_eq!(function.name, "main");
        assert_eq!(function.path_id, PathId(0));
        assert_eq!(function.line, Line(1));
        assert_eq!(reader.db().paths[PathId(0)], "/actual/typed.rs");
    }
}
