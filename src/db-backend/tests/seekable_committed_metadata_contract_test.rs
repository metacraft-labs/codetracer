//! Real shipping encoder/container and owning seekable metadata boundaries.
//! No mock reader or recorder: shipping APIs write genuine current containers.
//! Negative inputs deliberately corrupt committed metadata or truncate that
//! real container, exercising actual filesystem/byte-source refusal boundaries.
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
use codetracer_ctfs::writer::CtfsWriter;
use codetracer_trace_reader::step_stream_reader::StepStreamReader;
use codetracer_trace_types::{Line, PathId, StepId};
use codetracer_trace_writer::line_position::LinePositionSpace;
use codetracer_trace_writer::meta_dat::{FLAG_EXT_HAS_SOURCE_RELOAD, encode_meta_dat_ext};
use codetracer_trace_writer::step_stream::{SourceReloadChange, StepStream, StepStreamRecord, encode_step_stream};
use db_backend::ctfs_trace_reader::ctfs_container::CtfsReader;
use db_backend::ctfs_trace_reader::step_value_stream_source::SeekableStepStream;
use std::path::{Path, PathBuf};

fn metadata(ext: u32) -> Vec<u8> {
    encode_meta_dat_ext(
        "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb",
        "metadata-control",
        &[],
        "/actual",
        "real-control",
        0,
        ext,
    )
}
fn bundle(root: &Path, name: &str, meta: Option<&[u8]>, reload: bool) -> PathBuf {
    let mut space = LinePositionSpace::new();
    let mut records = vec![StepStreamRecord::Step {
        global_line_index: space.global_index(0, 3),
    }];
    if reload {
        records.push(StepStreamRecord::SourceReload {
            reload_ordinal: 1,
            changed: vec![SourceReloadChange {
                old_path_id: 0,
                new_path_id: 1,
                generation: 2,
            }],
            in_flight_frames: 0,
        });
    }
    records.push(StepStreamRecord::Step {
        global_line_index: space.global_index(0, 4),
    });
    let encoded = encode_step_stream(&StepStream { records }, 8, 3).unwrap();
    let path = root.join(format!("{name}.ct"));
    let mut writer = CtfsWriter::create(&path, 4096, 31).unwrap();
    let first = b"/actual/source.rs";
    let mut paths = first.to_vec();
    let mut offsets = 0u64.to_le_bytes().to_vec();
    offsets.extend_from_slice(&(paths.len() as u64).to_le_bytes());
    paths.extend_from_slice(b"/actual/source-reload.rs");
    offsets.extend_from_slice(&(paths.len() as u64).to_le_bytes());
    for (name, bytes) in [
        ("steps.dat", encoded.dat.as_slice()),
        ("steps.idx", encoded.idx.as_slice()),
        ("paths.dat", paths.as_slice()),
        ("paths.off", offsets.as_slice()),
    ] {
        let handle = writer.add_file(name).unwrap();
        writer.write(handle, bytes).unwrap();
    }
    if let Some(bytes) = meta {
        let handle = writer.add_file("meta.dat").unwrap();
        writer.write(handle, bytes).unwrap();
    }
    writer.close().unwrap();
    path
}
#[test]
fn actual_declared_reload_survives_same_container_metadata_and_undeclared_reload_fails() {
    let root = tempfile::tempdir().unwrap();
    let good = bundle(
        root.path(),
        "declared",
        Some(&metadata(FLAG_EXT_HAS_SOURCE_RELOAD)),
        true,
    );
    let mut ctfs = CtfsReader::open(&good).unwrap();
    let actual_meta = ctfs.read_file("meta.dat").unwrap();
    let actual_dat = ctfs.read_file("steps.dat").unwrap();
    let actual_idx = ctfs.read_file("steps.idx").unwrap();
    let mut decoder = StepStreamReader::from_files(&actual_meta, actual_dat, actual_idx)
        .unwrap()
        .unwrap();
    match decoder.read(1).unwrap() {
        StepStreamRecord::SourceReload {
            reload_ordinal,
            changed,
            in_flight_frames,
        } => {
            assert_eq!(reload_ordinal, 1);
            assert_eq!(
                changed,
                vec![SourceReloadChange {
                    old_path_id: 0,
                    new_path_id: 1,
                    generation: 2
                }]
            );
            assert_eq!(in_flight_frames, 0);
        }
        other => panic!("actual source-reload payload was replaced: {other:?}"),
    }
    let stream = SeekableStepStream::open_from_ctfs(&mut ctfs).unwrap().unwrap();
    assert_eq!(stream.step_count(), 3);
    assert_eq!(stream.step_position(StepId(0)), Some((PathId(0), Line(3), None)));
    assert_eq!(stream.step_position(StepId(2)), Some((PathId(0), Line(4), None)));
    let bad = bundle(root.path(), "undeclared", Some(&metadata(0)), true);
    let mut ctfs = CtfsReader::open(&bad).unwrap();
    let error = match SeekableStepStream::open_from_ctfs(&mut ctfs) {
        Err(error) => error,
        Ok(_) => panic!("undeclared reload must fail"),
    };
    assert!(error.contains("SourceReload"), "{error}");
}
#[test]
fn unknown_and_truncated_committed_metadata_fail_without_inventing_capability() {
    let root = tempfile::tempdir().unwrap();
    let mut unknown = metadata(0);
    unknown[8..12].copy_from_slice(&2u32.to_le_bytes());
    for (name, bytes) in [("unknown", unknown), ("short", metadata(0)[..11].to_vec())] {
        let path = bundle(root.path(), name, Some(&bytes), false);
        let mut ctfs = CtfsReader::open(&path).unwrap();
        let error = match SeekableStepStream::open_from_ctfs(&mut ctfs) {
            Err(error) => error,
            Ok(_) => panic!("malformed committed metadata must fail"),
        };
        assert!(error.contains("meta.dat"), "{error}");
    }
}
#[test]
fn absent_and_uncommitted_zero_metadata_preserve_ordinary_structural_steps() {
    let root = tempfile::tempdir().unwrap();
    for (name, meta) in [("absent", None), ("zero", Some([].as_slice()))] {
        let path = bundle(root.path(), name, meta, false);
        let mut ctfs = CtfsReader::open(&path).unwrap();
        let stream = SeekableStepStream::open_from_ctfs(&mut ctfs).unwrap().unwrap();
        assert_eq!(stream.step_count(), 2);
        assert_eq!(stream.step_position(StepId(1)), Some((PathId(0), Line(4), None)));
    }
}
#[test]
fn genuinely_truncated_committed_member_is_a_byte_source_read_failure() {
    let root = tempfile::tempdir().unwrap();
    let path = bundle(root.path(), "truncated", Some(&metadata(0)), false);
    let bytes = std::fs::read(&path).unwrap();
    let mut original = CtfsReader::from_bytes(bytes.clone()).unwrap();
    let names = ["steps.dat", "steps.idx", "paths.dat", "paths.off"];
    let original_members: Vec<_> = names.iter().map(|name| original.read_file(name).unwrap()).collect();
    let committed_size = original.file_size("meta.dat").unwrap();
    assert!(committed_size > 0);
    let truncated = bytes[..bytes.len() - 4096].to_vec();
    let mut ctfs = CtfsReader::from_bytes(truncated).expect("retained real directory and stream blocks");
    assert_eq!(ctfs.file_size("meta.dat"), Some(committed_size));
    for (name, expected) in names.iter().zip(original_members) {
        assert_eq!(ctfs.read_file(name).unwrap(), expected, "remaining member {name}");
    }
    assert!(
        ctfs.read_file("meta.dat").is_err(),
        "real removed metadata block must not read"
    );
    println!(
        "actual full container {} bytes; removed final4096 metadata block; committed metadata {} bytes; all4 stream/path members unchanged",
        bytes.len(),
        committed_size
    );
    let error = match SeekableStepStream::open_from_ctfs(&mut ctfs) {
        Err(error) => error,
        Ok(_) => panic!("committed metadata read failure must fail"),
    };
    assert!(error.contains("meta.dat"), "{error}");
}
