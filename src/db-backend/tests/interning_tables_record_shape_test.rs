//! The db-backend's interning-table reader decodes the spec's record shape only,
//! and refuses anything else exactly as the trace-format library reader does.
//!
//! `codetracer-trace-format-spec/internal-files.md` ("Interning Tables") gives
//! each table ONE record shape: `funcs.dat` is `global_line_index, name_len,
//! name` and `types.dat` is `kind, lang_type_len, lang_type, specific_info`.
//! `meta.dat` bit 12 only says the tables are present. Until b891a0f the Nim
//! writer wrote bare names into both tables with bit 12 clear, and readers used
//! the bit as a switch between the two shapes; both library readers have since
//! dropped that switch and refuse a bare-name record by name.
//!
//! The db-backend keeps its own reader (`ctfs_trace_reader::interning_tables`)
//! because the library's is compiled out of wasm32 builds and reads through a
//! different container type. Three readers of one format is how they drifted,
//! so this suite pins the db-backend's to the library's on the SAME bytes:
//! same decoded records, same refusal message, and every committed recording
//! still opens, through both. The same holds for a container that carries
//! some but not all of the four tables, which both refuse in the same words
//! (`internal-files.md` §"Interning Tables": all four or none).
//!
//! No mocks: the containers are real CTFS files read back by both production
//! readers.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_reader::interning_tables_reader::open_interning_tables;
use codetracer_trace_types::{TypeKind, TypeSpecificInfo};

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
use db_backend::ctfs_trace_reader::interning_tables::InterningTables;
use db_backend::ctfs_trace_reader::meta_dat::{
    FLAG_HAS_INTERNING_TABLES, META_DAT_VERSION, MetaDat, serialize_meta_dat,
};

fn varint(mut v: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

/// A Variable-Size Record Table: the concatenated records and the
/// `record_count + 1` little-endian offsets.
fn table(records: &[Vec<u8>]) -> (Vec<u8>, Vec<u8>) {
    let mut dat = Vec::new();
    let mut off = Vec::new();
    for record in records {
        off.extend_from_slice(&(dat.len() as u64).to_le_bytes());
        dat.extend_from_slice(record);
    }
    off.extend_from_slice(&(dat.len() as u64).to_le_bytes());
    (dat, off)
}

fn structured_func(global_line_index: u64, name: &str) -> Vec<u8> {
    let mut r = Vec::new();
    varint(global_line_index, &mut r);
    varint(name.len() as u64, &mut r);
    r.extend_from_slice(name.as_bytes());
    r
}

fn structured_type(kind: TypeKind, lang_type: &str) -> Vec<u8> {
    let mut r = vec![kind as u8];
    varint(lang_type.len() as u64, &mut r);
    r.extend_from_slice(lang_type.as_bytes());
    cbor4ii::serde::to_vec(r, &TypeSpecificInfo::None).expect("CBOR")
}

/// Write a container carrying the four interning tables, with `meta.dat` bit 12
/// set or clear, and return its path.
fn write_container(dir: &Path, name: &str, bit12: bool, funcs: &[Vec<u8>], types: &[Vec<u8>]) -> PathBuf {
    let meta = serialize_meta_dat(&MetaDat {
        version: META_DAT_VERSION,
        flags: if bit12 { FLAG_HAS_INTERNING_TABLES } else { 0 },
        recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
        program: name.to_owned(),
        args: vec![],
        workdir: dir.to_string_lossy().into_owned(),
        recorder_id: "test".to_owned(),
        ext_flags: 0,
        mcr: None,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: vec![],
        has_filter_provenance: false,
    });
    let (paths_dat, paths_off) = table(&[b"/src/main.nr".to_vec()]);
    let (funcs_dat, funcs_off) = table(funcs);
    let (types_dat, types_off) = table(types);
    let (varnames_dat, varnames_off) = table(&[b"x".to_vec()]);
    let ct = dir.join(format!("{name}.ct"));
    write_minimal_ctfs(
        &ct,
        &[
            ("meta.dat", &meta),
            ("paths.dat", &paths_dat),
            ("paths.off", &paths_off),
            ("funcs.dat", &funcs_dat),
            ("funcs.off", &funcs_off),
            ("types.dat", &types_dat),
            ("types.off", &types_off),
            ("varnames.dat", &varnames_dat),
            ("varnames.off", &varnames_off),
        ],
    )
    .expect("write the container");
    ct
}

fn db_backend_open(ct: &Path) -> Result<Option<InterningTables>, String> {
    let mut ctfs = CtfsReader::open(ct).expect("the container opens");
    InterningTables::open_from_ctfs(&mut ctfs)
}

/// The four interning tables are carried all four or none
/// (`internal-files.md` §"Interning Tables"). A container with any strict
/// subset of their eight members is refused by both readers with the same
/// message, naming what it carries and what it lacks; all eight and none open.
#[test]
fn a_partial_table_set_is_refused_with_the_library_readers_message() {
    const MEMBERS: [&str; 8] = codetracer_ctfs::interning_set::INTERNING_TABLE_MEMBERS;
    let dir = tempfile::tempdir().unwrap();
    let meta = serialize_meta_dat(&MetaDat {
        version: META_DAT_VERSION,
        flags: 0,
        recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
        program: "partial".to_owned(),
        args: vec![],
        workdir: String::new(),
        recorder_id: "test".to_owned(),
        ext_flags: 0,
        mcr: None,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: vec![],
        has_filter_provenance: false,
    });
    let empty_off = 0u64.to_le_bytes();
    let mut refused = 0;
    for mask in 0u32..256 {
        let mut files: Vec<(&str, &[u8])> = vec![("meta.dat", &meta)];
        for (i, name) in MEMBERS.iter().enumerate() {
            if mask & (1 << i) != 0 {
                files.push((name, if name.ends_with(".off") { &empty_off } else { &[] }));
            }
        }
        let ct = dir.path().join(format!("set-{mask:03}.ct"));
        write_minimal_ctfs(&ct, &files).expect("write the container");
        let library = open_interning_tables(&ct).map(|t| t.is_some());
        let ours = db_backend_open(&ct).map(|t| t.is_some());
        assert_eq!(
            ours, library,
            "set {mask:08b}: the db-backend verdict must be the library reader's"
        );
        let want = codetracer_ctfs::interning_set::interning_set_refusal(|n| files.iter().any(|(f, _)| *f == n));
        match want {
            Some(message) => {
                assert_eq!(ours, Err(message), "set {mask:08b}");
                refused += 1;
            }
            None => assert_eq!(ours, Ok(mask == 255), "set {mask:08b}: all eight or none opens"),
        }
    }
    assert_eq!(refused, 254);
}

/// A bare-name `funcs.dat` record in a bit-12-clear container is refused, and
/// the refusal is the library reader's, word for word.
#[test]
fn a_bare_function_name_is_refused_with_the_library_readers_message() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_container(
        dir.path(),
        "bare_func",
        false,
        &[structured_func(0, "main"), b"helper".to_vec()],
        &[structured_type(TypeKind::Int, "int")],
    );

    let library = open_interning_tables(&ct)
        .unwrap()
        .expect("the library finds the tables");
    assert_eq!(library.func(0).unwrap().name, b"main", "the structured record decodes");
    let expected = library.func(1).expect_err("the library refuses the bare name");

    let refused = match db_backend_open(&ct) {
        Err(e) => e,
        Ok(_) => panic!("the db-backend reader must refuse a bare-name funcs.dat record, not read it as a name"),
    };
    assert_eq!(refused, expected, "the db-backend refusal must be the library reader's");
    assert!(
        refused.contains("re-record it"),
        "the refusal names the remedy: {refused}"
    );
}

/// The same for `types.dat`.
#[test]
fn a_bare_type_name_is_refused_with_the_library_readers_message() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_container(
        dir.path(),
        "bare_type",
        false,
        &[structured_func(0, "main")],
        &[structured_type(TypeKind::Int, "int"), b"String".to_vec()],
    );

    let library = open_interning_tables(&ct)
        .unwrap()
        .expect("the library finds the tables");
    let expected = library.type_record(1).expect_err("the library refuses the bare name");

    let refused = match db_backend_open(&ct) {
        Err(e) => e,
        Ok(_) => panic!("the db-backend reader must refuse a bare-name types.dat record"),
    };
    assert_eq!(refused, expected, "the db-backend refusal must be the library reader's");
}

/// With bit 12 SET a record that does not decode is plain corruption, and both
/// readers report the structured decoder's own message.
#[test]
fn an_undecodable_record_under_bit_12_is_reported_as_the_decode_error() {
    let dir = tempfile::tempdir().unwrap();
    let ct = write_container(
        dir.path(),
        "corrupt_func",
        true,
        &[structured_func(0, "main"), b"helper".to_vec()],
        &[structured_type(TypeKind::Int, "int")],
    );

    let library = open_interning_tables(&ct)
        .unwrap()
        .expect("the library finds the tables");
    let expected = library.func(1).expect_err("the library refuses the record");

    let refused = match db_backend_open(&ct) {
        Err(e) => e,
        Ok(_) => panic!("the db-backend reader must refuse an undecodable funcs.dat record"),
    };
    assert_eq!(refused, expected);
}

/// Bit 12 is not what makes a structured record readable: a spec-shaped
/// container is decoded identically by both readers with the bit set or clear.
#[test]
fn structured_records_decode_alike_whatever_bit_12_says() {
    for bit12 in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let ct = write_container(
            dir.path(),
            "structured",
            bit12,
            &[structured_func(7, "main"), structured_func(3, "helper")],
            &[
                structured_type(TypeKind::Int, "int"),
                structured_type(TypeKind::String, "String"),
            ],
        );
        let library = open_interning_tables(&ct)
            .unwrap()
            .expect("the library finds the tables");
        let ours = db_backend_open(&ct)
            .unwrap_or_else(|e| panic!("bit 12 {bit12}: a spec-shaped container must open: {e}"))
            .expect("the db-backend finds the tables");

        let library_funcs: Vec<String> = (0..library.func_count() as u64)
            .map(|i| String::from_utf8(library.func(i).unwrap().name).unwrap())
            .collect();
        let our_funcs: Vec<String> = ours.functions.iter().map(|f| f.name.clone()).collect();
        assert_eq!(our_funcs, library_funcs, "bit 12 {bit12}: function names");
        assert_eq!(our_funcs, vec!["main", "helper"]);

        let library_types: Vec<(Option<TypeKind>, String)> = (0..library.type_count() as u64)
            .map(|i| {
                let t = library.type_record(i).unwrap();
                (t.type_kind(), String::from_utf8(t.lang_type).unwrap())
            })
            .collect();
        let our_types: Vec<(Option<TypeKind>, String)> =
            ours.types.iter().map(|t| (Some(t.kind), t.lang_type.clone())).collect();
        assert_eq!(our_types, library_types, "bit 12 {bit12}: types");
    }
}

/// Committed recordings that predate the current container version and whose
/// documented producer needs a device or host this suite does not assume, with
/// the reason.
/// Each must still fail, and only with the container-version refusal; one that
/// opens fails the test so its entry is removed rather than left to hide a
/// later regression.
const NOT_YET_RE_RECORDED: &[(&str, &str)] = &[
    (
        "examples/recordings/mcr/android-arm64/trace.ct",
        "re-recorded only on a USB-connected Android device (mcr/android-arm64/regenerate.sh)",
    ),
    (
        "examples/recordings/mcr/android-arm64/trace-portable.ct",
        "exported from android-arm64/trace.ct, which must be re-recorded first",
    ),
    (
        "examples/recordings/mcr/ios-arm64/trace.ct",
        "re-recorded only on macOS with Xcode and an iOS simulator (mcr/ios-arm64/regenerate.sh)",
    ),
    (
        "examples/recordings/mcr/ios-arm64/trace-portable.ct",
        "exported from ios-arm64/trace.ct, which must be re-recorded first",
    ),
    // Not recordings to re-record: the version-4 originals the converter in
    // tools/ctfs-v4-to-v5 regenerates the eme5 fixtures from. They stay at
    // version 4, and the same container-version refusal is all they may get.
    (
        "examples/recordings/tools/ctfs-v4-to-v5/testdata/null_main.v4.ct",
        "the version-4 original of eme5/null_main.ct, kept as the converter's input",
    ),
    (
        "examples/recordings/tools/ctfs-v4-to-v5/testdata/one_puts.v4.ct",
        "the version-4 original of eme5/one_puts.ct, kept as the converter's input",
    ),
];

/// Every committed recording still opens: the bare-name fixtures were
/// re-recorded, so refusing that shape must not refuse anything in the tree.
/// Submodules are included, so the example recordings are covered when checked
/// out. The recordings in [`NOT_YET_RE_RECORDED`] are the only exceptions.
#[test]
fn every_committed_recording_opens() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let listed = std::process::Command::new("git")
        .args(["ls-files", "--recurse-submodules", "-z", "--", "*.ct"])
        .current_dir(&repo)
        .output()
        .expect("git ls-files runs");
    assert!(listed.status.success(), "git ls-files failed");
    let files: Vec<PathBuf> = listed
        .stdout
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| repo.join(String::from_utf8_lossy(p).as_ref()))
        .collect();
    assert!(
        files.len() >= 20,
        "expected the committed .ct fixtures (21 when this was written), found {}",
        files.len()
    );

    let mut with_tables = 0;
    let mut not_yet_re_recorded = 0;
    for ct in &files {
        let relative = ct
            .strip_prefix(&repo)
            .unwrap_or(ct)
            .to_string_lossy()
            .replace('\\', "/");
        if let Some((_, reason)) = NOT_YET_RE_RECORDED.iter().find(|(path, _)| *path == relative) {
            match CtfsReader::open(ct) {
                Ok(_) => panic!(
                    "{relative} now opens; remove it from NOT_YET_RE_RECORDED (it was listed because it is {reason})"
                ),
                Err(e) => {
                    let message = e.to_string();
                    assert!(
                        message.contains("is not readable: this reader reads versions 5 and 6"),
                        "{relative} is listed as not yet re-recorded ({reason}), so it may fail only on its \
                         container version, but it failed with: {message}"
                    );
                }
            }
            not_yet_re_recorded += 1;
            continue;
        }
        let mut ctfs = CtfsReader::open(ct).unwrap_or_else(|e| panic!("{}: container: {e}", ct.display()));
        let ours = InterningTables::open_from_ctfs(&mut ctfs);
        let library = open_interning_tables(ct);
        assert_eq!(
            ours.as_ref().map(Option::is_some),
            library.as_ref().map(Option::is_some),
            "{}: the db-backend and the library reader disagree",
            ct.display()
        );
        if let Some(tables) = ours.unwrap_or_else(|e| panic!("{}: {e}", ct.display())) {
            assert!(
                !tables.paths.is_empty(),
                "{}: interning tables with no paths",
                ct.display()
            );
            with_tables += 1;
        }
    }
    assert!(
        with_tables > 0,
        "none of the {} committed recordings carries interning tables, so this checked nothing",
        files.len()
    );
    let examples_checked_out = files.iter().any(|f| f.starts_with(repo.join("examples/recordings")));
    if examples_checked_out {
        assert_eq!(
            not_yet_re_recorded,
            NOT_YET_RE_RECORDED.len(),
            "every recording listed in NOT_YET_RE_RECORDED must exist; a missing one was moved or removed"
        );
    }
    println!(
        "{with_tables} of {} committed recordings carry interning tables; all open except the {not_yet_re_recorded} \
         listed as not yet re-recorded",
        files.len()
    );
}
