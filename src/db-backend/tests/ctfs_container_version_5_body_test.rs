//! Container version 5's body — the direct-block `MapBlock` form — is read,
//! and the positions it yields are checked against the source the container
//! carries rather than against the fact that `open` returned `Ok`.
//!
//! # Why opening is not the property
//!
//! Version 5's only body change is the third of `ctfs-container.md` §2's three
//! `MapBlock` forms: a member of at most one block owns no mapping block and
//! carries the direct-block tag in bit 63. A reader that accepted the version
//! WITHOUT implementing that form would take `0x8000_0000_0000_0005` as mapping
//! block 9223372036854775813 and fail its bounds check — so that failure is
//! loud, and it is not what this file is guarding against.
//!
//! The quiet failure is one layer up and on a DIFFERENT field. The container
//! version and `meta.dat`'s schema version are separate axes, and conflating
//! them is what once shipped containers written with the corrected
//! `global_position_index` packing under a stamp that still said 3: a reader
//! trusting the stamp placed every step one line high and returned success
//! while doing it (`meta_dat::LAST_SHIFTED_GLOBAL_INDEX_VERSION` and
//! `acceptShiftedGlobalIndex` are the repair artefacts that exist only because
//! of it). Nothing in the bytes catches that, because both packings address
//! positions the trace's own space can address.
//!
//! So widening a version gate obliges a measurement that the BODIES decode
//! correctly, not merely that they parse. That measurement is
//! [`version_5_steps_land_on_the_statements_the_container_carries`], and it is
//! absolute: the fixture ships its own source text, so each step is required to
//! land on the statement it recorded and never on the line above it.
//!
//! # No mocks, and no skips
//!
//! Both fixtures are committed, so every arm here always runs; a missing one
//! fails loudly rather than skipping. They are opened through
//! `CTFSTraceReader::open`, the same constructor `dap_server` uses. The
//! malformed containers of the refusal arms are built arithmetically in this
//! file, because no writer in this workspace will produce one — which is the
//! point: a reader hazard has to be constructed to be tested.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic, clippy::indexing_slicing)]

use std::fs;
use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, PathId, StepId};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// `src/db-backend/trace/trace.ct` — a committed container at container
/// version 5 with `meta.dat` schema version 6, every one of whose 18 members
/// is stored in the direct-block form.
///
/// Resolved from `CARGO_MANIFEST_DIR` (which is `src/db-backend`) so the two
/// fixtures below are named the way the rest of the tree names them.
fn repo_fixture(relative: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(relative);
    assert!(
        path.is_file(),
        "committed fixture missing at {} — this test must NOT silently skip",
        path.display()
    );
    path
}

/// The two committed version-5 containers. They are the same recording, kept
/// next to the two crates that replay it.
const VERSION_5_FIXTURES: [&str; 2] = ["trace/trace.ct", "../tui/trace/trace.ct"];

/// The recording's own source file, shipped beside each container.
const VERSION_5_SOURCE: &str = "test_code/rust_struct_test.rs";

/// `(line, the source text at that line)` for steps 0..=15 of
/// `rust_struct_test.wasm`, in step order.
///
/// Read off the container by the canonical Nim reader (`ct-print --events`,
/// built from `codetracer-trace-format-nim` at the revision that WROTE this
/// container, so writer and reader are the matched pair) and then checked
/// against `trace/files/test_code/rust_struct_test.rs`, which the container
/// ships. The second check is the one that matters: a `(path, line)` pair two
/// implementations agree on is still wrong if they are wrong together, and the
/// source text is the only thing here that is independent of both.
///
/// **A one-line-high decode is excluded by the text, not by inspection.** Every
/// function entry lands on its `fn` line and every return on its `}`; shifted
/// up by one, step 0 would leave `fn main() {` for the `let` below it, step 2
/// would leave `fn test_struct` for its body, step 3 would land on the body
/// rather than the brace, and steps 14 and 15 would move to line 27 (blank) and
/// line 29 (`}`). Lines 20, 22, 24, 25 and 27 are blank or comments and NO step
/// may land on one.
const VERSION_5_STEPS: [(i64, &str); 16] = [
    (18, "fn main() {"),
    (19, "    let test = test_struct(123);"),
    (7, "fn test_struct(a: i32) -> TestStruct {"),
    (9, "}"),
    (21, "    let dummy = test_struct(234);"),
    (7, "fn test_struct(a: i32) -> TestStruct {"),
    (9, "}"),
    (23, "    let first = number();"),
    (11, "fn number() -> usize {"),
    (13, "}"),
    // Steps 10..=13 are in the two `core` paths, which the container does not
    // ship the text of; their lines are asserted without a text check by
    // `version_5_foreign_path_steps_keep_their_recorded_paths` below.
    (114, ""),
    (234, ""),
    (103, ""),
    (100, ""),
    (26, "    println!(\"{}\", test.a);"),
    (28, "    std::process::exit(0)"),
];

/// The path id each step was recorded in, in step order. Steps 10, 12 and 13
/// are in `core/src/fmt/rt.rs` and step 11 in `core/src/ptr/non_null.rs`.
const VERSION_5_PATH_IDS: [usize; 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1, 1, 0, 0];

/// The three paths the container registers, in `paths.dat` order.
const VERSION_5_PATH_SUFFIXES: [&str; 3] = [
    "test_code/rust_struct_test.rs",
    "library/core/src/fmt/rt.rs",
    "library/core/src/ptr/non_null.rs",
];

/// A container at version 5 opens, and every step lands on the statement the
/// container's own source text shows it recorded.
///
/// CONTROL, and it is what makes this an assertion rather than a transcript:
/// the expected line is checked against the shipped source at that line, so the
/// arm fails both if the reader shifts a position and if the table above is
/// edited to match a shifted reader.
#[test]
fn version_5_steps_land_on_the_statements_the_container_carries() {
    for relative in VERSION_5_FIXTURES {
        let ct = repo_fixture(relative);
        let reader =
            CTFSTraceReader::open(&ct).unwrap_or_else(|e| panic!("{relative}: a version-5 container must open: {e}"));

        let source = source_lines(&ct);

        for (i, (line, text)) in VERSION_5_STEPS.iter().enumerate() {
            let step = reader
                .step(StepId(i as i64))
                .unwrap_or_else(|| panic!("{relative}: step {i} must be present"));
            assert_eq!(
                step.line,
                Line(*line),
                "{relative}: step {i} was recorded at line {line} and must read back there, not at {}",
                step.line.0
            );
            assert_eq!(
                step.path_id,
                PathId(VERSION_5_PATH_IDS[i]),
                "{relative}: step {i} was recorded in path {}",
                VERSION_5_PATH_IDS[i]
            );
            if text.is_empty() {
                continue;
            }
            // The independent check: the recorded line's TEXT. `line` is
            // 1-based.
            let at = source
                .get(*line as usize - 1)
                .unwrap_or_else(|| panic!("{relative}: the shipped source has no line {line}"));
            assert_eq!(
                at.trim_end(),
                *text,
                "{relative}: step {i} claims line {line}, whose text must be the statement this \
                 table names — if the reader is right and the table is stale, the SOURCE changed \
                 and the fixture has to be re-recorded"
            );
        }
    }
}

/// The container's step count is exactly the table's length, so the arm above
/// cannot pass by checking a prefix of a longer stream.
#[test]
fn version_5_carries_exactly_the_steps_the_table_names() {
    for relative in VERSION_5_FIXTURES {
        let ct = repo_fixture(relative);
        let reader = CTFSTraceReader::open(&ct).expect("a version-5 container must open");
        assert!(
            reader.step(StepId(VERSION_5_STEPS.len() as i64)).is_none(),
            "{relative}: the container must carry exactly {} steps; a step at index {} means the \
             readback arm checked a prefix",
            VERSION_5_STEPS.len(),
            VERSION_5_STEPS.len()
        );
    }
}

/// The two `core` paths are registered and the steps in them keep them.
///
/// Stated separately because those four steps have no shipped text to check,
/// so the claim their lines support is weaker and should not be smuggled in
/// beside a claim that is absolute.
#[test]
fn version_5_foreign_path_steps_keep_their_recorded_paths() {
    for relative in VERSION_5_FIXTURES {
        let ct = repo_fixture(relative);
        let reader = CTFSTraceReader::open(&ct).expect("a version-5 container must open");
        let paths = &reader.db().paths;
        assert_eq!(paths.len(), VERSION_5_PATH_SUFFIXES.len(), "{relative}: path count");
        for (i, suffix) in VERSION_5_PATH_SUFFIXES.iter().enumerate() {
            let got = &paths[PathId(i)];
            assert!(
                got.ends_with(suffix),
                "{relative}: path {i} is {got:?} and must end with {suffix}"
            );
        }
    }
}

/// Every member of the committed version-5 containers that CAN be in the
/// direct-block form is in it, asserted against the bytes, with
/// `ctfs-container.md` §2's THREE forms kept apart.
///
/// Without this the readback arms above would pass on a version-5 container
/// whose members all happened to carry mapping blocks, and would then be
/// measuring the pre-existing path while claiming to measure the new one.
///
/// **This arm was first written as a two-way split — tagged against "mapped" —
/// and went red on `events.dat`, correctly.** `events.dat` has `size = 0` and
/// `MapBlock = 0`, which is §2's FIRST form (an EMPTY member), not its third.
/// A two-way test on the tag bit cannot tell an empty member from a mapped one,
/// because `0 & DIRECT_TAG` and `mapping_block & DIRECT_TAG` are both zero. The
/// expectation was stale, not the reader, and the fix is to classify the way the
/// format does: `0` is empty, the tag is direct, anything else is a mapping
/// block.
#[test]
fn every_member_of_the_version_5_fixtures_is_direct_tagged() {
    const DIRECT_TAG: u64 = 1 << 63;
    for relative in VERSION_5_FIXTURES {
        let ct = repo_fixture(relative);
        let bytes = fs::read(&ct).expect("read the committed container");
        assert_eq!(bytes[5], 5, "{relative}: fixture must be at container version 5");
        let block_size = u64::from(u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]));
        let max_root_entries = u32::from_le_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]) as usize;
        let mut direct = 0usize;
        let mut empty = 0usize;
        let mut mapped: Vec<(String, u64)> = Vec::new();
        for i in 0..max_root_entries {
            let off = 16 + 24 * i;
            let size = u64::from_le_bytes(bytes[off..off + 8].try_into().expect("8 bytes"));
            let map_block = u64::from_le_bytes(bytes[off + 8..off + 16].try_into().expect("8 bytes"));
            let name = u64::from_le_bytes(bytes[off + 16..off + 24].try_into().expect("8 bytes"));
            if name == 0 {
                continue;
            }
            if map_block == 0 {
                // §2's first form. An empty member is `(0, 0)` with its name.
                assert_eq!(
                    size, 0,
                    "{relative}: a member with MapBlock 0 declares {size} bytes, which is neither \
                     of §2's forms"
                );
                empty += 1;
            } else if map_block & DIRECT_TAG != 0 {
                direct += 1;
            } else {
                mapped.push((format!("entry {i}"), size));
            }
        }
        assert!(
            direct > 0,
            "{relative}: no member is direct-tagged, so this fixture does not exercise version 5's body"
        );
        // A member LARGER than one block must be mapped — that is the form's
        // own precondition, not a writer lapse. What would make the readback
        // arms measure the old path is a member that FITS one block and is
        // mapped anyway, which is what this asserts against.
        for (which, size) in &mapped {
            assert!(
                *size > block_size,
                "{relative}: {which} fits in one {block_size}-byte block ({size} bytes) and still \
                 carries a mapping block, so the readback arms are measuring the version-4 path \
                 for it"
            );
        }
        eprintln!("{relative}: {direct} direct, {empty} empty, {} mapped", mapped.len());
    }
}

/// `meta.dat` in the version-5 fixtures is at schema version 6 — the OTHER
/// axis, named here so the two cannot be confused again.
///
/// The container version and the schema version moved together in the 2026-10
/// revision, and this arm is what records that they are nevertheless two
/// fields: if a container ever appears at version 5 with a schema below 6, or
/// at 6 with a container below 5, the reasoning that admitted either version
/// has to be re-taken rather than assumed.
#[test]
fn the_version_5_fixtures_carry_meta_dat_schema_version_6() {
    for relative in VERSION_5_FIXTURES {
        let ct = repo_fixture(relative);
        let bytes = fs::read(&ct).expect("read the committed container");
        let ctmd = find_subslice(&bytes, b"CTMD").unwrap_or_else(|| panic!("{relative}: no meta.dat in the container"));
        let schema = u16::from_le_bytes([bytes[ctmd + 4], bytes[ctmd + 5]]);
        assert_eq!(
            schema, 6,
            "{relative}: container version 5 and meta.dat schema 6 are the 2026-10 pair; a \
             container at 5 carrying schema {schema} is a combination nothing has measured"
        );
    }
}

// ── The refusals ─────────────────────────────────────────────────────────────
//
// Each of these constructs a container the direct-block form makes possible and
// requires the reader to refuse it. They are built here rather than committed
// because no writer in this workspace emits one.

/// Build a one-member version-5 container whose single member is direct-tagged
/// at `direct_block`, with a declared `size`, over `block_count` whole blocks.
///
/// The member is named `meta.dat` deliberately: it is the first member
/// `CTFSTraceReader::open` reads, so the refusal that comes back is the one the
/// direct-block path produced and not a later "member not found". Naming it
/// anything else was the first version of this helper and it made three arms
/// report `internal file not found in CTFS container: meta.dat` instead.
fn write_direct_container(path: &Path, direct_block: u64, size: u64, block_count: usize, payload: &[u8]) {
    const BLOCK_SIZE: usize = 4096;
    let mut buf = vec![0u8; BLOCK_SIZE * block_count];
    buf[0..5].copy_from_slice(&[0xC0, 0xDE, 0x72, 0xAC, 0xE2]);
    buf[5] = 5;
    buf[8..12].copy_from_slice(&(BLOCK_SIZE as u32).to_le_bytes());
    buf[12..16].copy_from_slice(&31u32.to_le_bytes());
    // One entry: (size, map_block, name).
    buf[16..24].copy_from_slice(&size.to_le_bytes());
    buf[24..32].copy_from_slice(&((1u64 << 63) | direct_block).to_le_bytes());
    buf[32..40].copy_from_slice(&base40("meta.dat").to_le_bytes());
    // Block 0 is the header and the entry array, so a payload written there
    // would overwrite the magic and the arm would measure a bad-magic refusal
    // instead of the block-0 one. That is what the first version of this helper
    // did, and `a_direct_tag_naming_block_0_is_refused` reported
    // "not a valid CTFS file (bad magic bytes)" because of it.
    let at = direct_block as usize * BLOCK_SIZE;
    if direct_block != 0 && at + payload.len() <= buf.len() {
        buf[at..at + payload.len()].copy_from_slice(payload);
    }
    fs::write(path, &buf).expect("write the constructed container");
}

/// §3's base40 packing, enough of it for the member names above.
fn base40(name: &str) -> u64 {
    let mut out: u64 = 0;
    for (i, c) in name.chars().enumerate() {
        let idx: u64 = match c {
            '0'..='9' => 1 + (c as u64 - '0' as u64),
            'a'..='z' => 11 + (c as u64 - 'a' as u64),
            '.' => 37,
            '/' => 38,
            '-' => 39,
            _ => panic!("base40: {c:?} is outside the alphabet"),
        };
        out += idx * 40u64.pow(i as u32);
    }
    out
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn source_lines(ct: &Path) -> Vec<String> {
    let source = ct
        .parent()
        .expect("the container has a parent directory")
        .join("files")
        .join(VERSION_5_SOURCE);
    assert!(
        source.is_file(),
        "the version-5 fixture must ship its source at {} — the absolute check depends on it and \
         must NOT be skipped",
        source.display()
    );
    fs::read_to_string(&source)
        .expect("read the shipped source")
        .lines()
        .map(str::to_owned)
        .collect()
}

/// A direct tag naming block 0 is refused, naming the block.
///
/// Block 0 is the container's own header and `FileEntry` array. An unrefused 0
/// would serve the directory back as the member's content and report success —
/// which is the same shape of defect as a null mapping root, and the reason the
/// Nim reader refuses both separately.
#[test]
fn a_direct_tag_naming_block_0_is_refused() {
    let dir = tempdir();
    let ct = dir.join("direct_block_zero.ct");
    write_direct_container(&ct, 0, 16, 4, b"not the directory");
    let err = open_and_read(&ct).expect_err("a direct tag naming block 0 must be refused");
    assert!(
        err.contains("block 0") && err.contains("root directory"),
        "the refusal must name block 0 and say why: got {err:?}"
    );
    assert!(
        !err.contains("bad magic"),
        "the refusal must come from the direct-block path, not from a clobbered header: got {err:?}"
    );
}

/// A direct member declaring more than one block is refused, naming the size.
///
/// The form's whole claim is that the member fits one block, so a declared size
/// past one block is an entry contradicting its own tag. Refusing beats reading
/// the first block and reporting a short member, which is a wrong answer the
/// caller cannot detect.
#[test]
fn a_direct_member_larger_than_one_block_is_refused() {
    let dir = tempdir();
    let ct = dir.join("direct_oversize.ct");
    write_direct_container(&ct, 1, 4097, 4, b"payload");
    let err = open_and_read(&ct).expect_err("a direct member larger than one block must be refused");
    assert!(
        err.contains("4097") && err.contains("one direct block"),
        "the refusal must name the declared size: got {err:?}"
    );
}

/// A direct tag naming a block past the container's whole blocks is refused.
///
/// `CTFS-Binary-Format.md` §5d's bound, applied to the direct path. It is the
/// easy one to miss here for the same reason it was missed on the mapped path:
/// the read is clamped to the entry's size, so a short read out of the partial
/// region SUCCEEDS unless the block number is checked first.
#[test]
fn a_direct_tag_past_the_whole_blocks_is_refused() {
    let dir = tempdir();
    let ct = dir.join("direct_out_of_bounds.ct");
    // Four whole blocks, a tag naming block 9.
    write_direct_container(&ct, 9, 16, 4, b"");
    let err = open_and_read(&ct).expect_err("a direct tag past the whole blocks must be refused");
    assert!(
        err.contains("direct data block 9") || err.contains("block 9"),
        "the refusal must name the offending block: got {err:?}"
    );
}

/// An unknown container version is still refused BY NAME, which is the property
/// CCP-1 landed and which widening the set to 5 must not spend.
///
/// 7 rather than 6: 6 is a version this reader DOES implement for the compact
/// profile, so it would prove nothing about unknown versions.
#[test]
fn an_unknown_container_version_is_still_refused_by_name() {
    let dir = tempdir();
    let ct = dir.join("version_seven.ct");
    write_direct_container(&ct, 1, 16, 4, b"payload");
    let mut bytes = fs::read(&ct).expect("read back");
    bytes[5] = 7;
    fs::write(&ct, &bytes).expect("stamp version 7");
    let err = open_and_read(&ct).expect_err("an unimplemented container version must be refused");
    assert!(
        err.contains('7'),
        "the refusal must NAME the version found, not merely fail: got {err:?}"
    );
}

/// Open a constructed container far enough to resolve its member, and return
/// the error text if it refuses.
///
/// `CTFSTraceReader::open` is the production door, and it is what these arms
/// use: a lower-level helper would prove the container reader refuses while
/// leaving open whether the door does.
fn open_and_read(ct: &Path) -> Result<(), String> {
    match CTFSTraceReader::open(ct) {
        Ok(_) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

fn tempdir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ctfs_v5_body_test_{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    fs::create_dir_all(&dir).expect("create the test directory");
    dir
}
