//! Real legacy logical-stream compatibility in a shipping container.
//! No reader/compiler mock: genuine production encoders and both reader APIs
//! consume real files. The independently retained retired fixture constructor
//! supplies the exact legacy member-byte baseline; malformed members below
//! are explicit corrupt-input fault controls, not synthetic recorder claims.
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
mod common;
use codetracer_ctfs::{ChunkedWriter, CompressionMethod, CtfsWriter};
use codetracer_trace_types::*;
use db_backend::ctfs_trace_reader::{
    CTFSTraceReader,
    ctfs_container::{CtfsReader, write_minimal_ctfs},
    meta_dat::{MetaDat, parse_meta_dat, serialize_meta_dat},
};

fn events() -> Vec<TraceLowLevelEvent> {
    vec![
        TraceLowLevelEvent::Path("/actual/legacy.rs".into()),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".into(),
            specific_info: TypeSpecificInfo::None,
        }),
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
    ]
}
fn publish(path: &std::path::Path, meta: &[u8], events: Option<&[u8]>) {
    let mut writer = CtfsWriter::create(path, 4096, 31).unwrap();
    let handle = writer.add_file("meta.dat").unwrap();
    writer.write(handle, meta).unwrap();
    if let Some(bytes) = events {
        let handle = writer.add_file("events.log").unwrap();
        writer.write(handle, bytes).unwrap();
    }
    writer.close().unwrap();
}
#[test]
fn current_container_preserves_exact_retired_logical_member_and_metadata_fields() {
    let root = tempfile::tempdir().unwrap();
    let events = events();
    let path = common::legacy_events_log::write_legacy_events_log_bundle(root.path(), "legacy", &events);
    let mut current = CtfsReader::open(&path).unwrap();
    let actual_events = current.read_file("events.log").unwrap();
    let current_meta = parse_meta_dat(&current.read_file("meta.dat").unwrap()).unwrap();
    // Exact independently retained pre-change CBOR/chunk constructor, including
    // HEADERV1, four events/chunk and every monotonic global event identifier.
    let mut raw = Vec::new();
    let mut sizes = Vec::new();
    for event in &events {
        let before = raw.len();
        raw = cbor4ii::serde::to_vec(raw, event).unwrap();
        sizes.push(raw.len() - before);
    }
    let geids: Vec<u64> = (0..events.len() as u64).collect();
    let mut old_events = vec![0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];
    old_events.extend(
        ChunkedWriter::new(CompressionMethod::Zstd, 4)
            .write_chunked(&raw, &sizes, &geids)
            .unwrap(),
    );
    let independently_expected_meta = MetaDat {
        version: 4,
        flags: 0,
        recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
        program: "legacy".to_owned(),
        args: vec![],
        workdir: root.path().to_string_lossy().into_owned(),
        recorder_id: "test".to_owned(),
        paths: vec![],
        mcr: None,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: vec![],
        has_filter_provenance: false,
    };
    let old_meta_bytes = serialize_meta_dat(&independently_expected_meta);
    let old_path = root.path().join("retained-old-container.ct");
    write_minimal_ctfs(&old_path, &[("meta.dat", &old_meta_bytes), ("events.log", &old_events)]).unwrap();
    let mut old = CtfsReader::open(&old_path).unwrap();
    assert_eq!(actual_events, old.read_file("events.log").unwrap());
    let mut parsed_old = parse_meta_dat(&old.read_file("meta.dat").unwrap()).unwrap();
    assert_eq!(parsed_old.version, 4);
    assert_eq!(current_meta.version, 6);
    parsed_old.version = current_meta.version;
    assert_eq!(parsed_old, current_meta);
    for reader in [
        CTFSTraceReader::open(&path).unwrap(),
        CTFSTraceReader::from_bytes(std::fs::read(&path).unwrap()).unwrap(),
    ] {
        require_original_fixture_content(&reader).expect("complete original legacy fixture");
    }
}
fn require_original_fixture_content(reader: &CTFSTraceReader) -> Result<(), &'static str> {
    if reader.db().paths.len() != 1 || reader.db().paths[PathId(0)] != "/actual/legacy.rs" {
        return Err("required original path missing or changed");
    }
    if reader.db().functions.len() != 1 || reader.db().functions[FunctionId(0)].name != "main" {
        return Err("required original function missing or changed");
    }
    if reader.db().steps.len() != 1 {
        return Err("required original step missing or changed");
    }
    Ok(())
}
#[test]
fn metadata_only_is_valid_but_missing_fixture_content_fails_completeness_and_malformed_cbor_fails_readers() {
    let root = tempfile::tempdir().unwrap();
    let original = common::legacy_events_log::write_legacy_events_log_bundle(root.path(), "positive", &events());
    let mut ctfs = CtfsReader::open(&original).unwrap();
    let meta = ctfs.read_file("meta.dat").unwrap();
    let missing = root.path().join("missing.ct");
    publish(&missing, &meta, None);
    for reader in [
        CTFSTraceReader::open(&missing).expect("metadata-only remains valid"),
        CTFSTraceReader::from_bytes(std::fs::read(&missing).unwrap()).expect("metadata-only remains valid"),
    ] {
        assert_eq!(reader.db().steps.len(), 0);
        assert!(
            require_original_fixture_content(&reader).is_err(),
            "missing original fixture must fail the same completeness oracle"
        );
    }
    // A complete compressed chunk containing invalid CBOR, unlike a partial
    // eight-byte streaming prefix which may legitimately expose no events yet.
    let mut malformed = vec![0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];
    malformed.extend(
        ChunkedWriter::new(CompressionMethod::Zstd, 4)
            .write_chunked(&[0xff], &[1], &[0])
            .unwrap(),
    );
    let broken = root.path().join("malformed.ct");
    publish(&broken, &meta, Some(&malformed));
    assert!(
        CTFSTraceReader::open(&broken).is_err(),
        "native must refuse complete malformed CBOR"
    );
    assert!(
        CTFSTraceReader::from_bytes(std::fs::read(&broken).unwrap()).is_err(),
        "materialized must refuse complete malformed CBOR"
    );
    for reader in [
        CTFSTraceReader::open(&original).unwrap(),
        CTFSTraceReader::from_bytes(std::fs::read(&original).unwrap()).unwrap(),
    ] {
        require_original_fixture_content(&reader).expect("byte-preserved positive fixture restored");
    }
}
