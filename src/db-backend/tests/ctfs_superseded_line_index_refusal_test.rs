//! A container written before the global line index correction must be
//! REFUSED, not read one line high.
//!
//! The line-only `global_position_index` encode changed from
//! `prefix_sum[file_id] + line` to `prefix_sum[file_id] + (line - 1)`, making it
//! the exact inverse of the decode the spec states. Nothing in a container's
//! bytes distinguishes the two: both address a line the trace's own space can
//! hold, so a container written under the old encode and read under the new one
//! yields a `(path, line)` pair for every step and reports each one exactly one
//! line above where it was recorded — silently, with nothing for
//! `LinePositionSpace::resolve` to refuse. That is unlike the retired
//! `(path_id << 32) | line` packing, which is catchable only because it lands
//! OUTSIDE the space.
//!
//! `meta.dat`'s schema version is therefore the sole discriminator, and this
//! test is what says the reader uses it. It runs both directions at both
//! container entry points a caller reaches — `CTFSTraceReader::open` (a path)
//! and `CTFSTraceReader::from_bytes` (the browser constructor) — and carries its
//! own mutation control: `resolving_a_superseded_container_puts_every_step_one_line_high`
//! performs, on the same fixture, exactly what accepting the container would do,
//! and asserts the result as the DEFECT rather than pinning it as correct.
//!
//! No mock. Both containers are built from this repository's own production
//! encoders — `codetracer_trace_writer`'s `encode_meta_dat` for the header,
//! `encode_step_stream` for `steps.dat`/`steps.idx`, and the same
//! `LinePositionSpace` the writer addresses steps with. The superseded fixture
//! differs from the current one in exactly two respects, both of which it
//! asserts about itself before asserting anything about the reader: its steps
//! carry `file_base + line` instead of `file_base + (line - 1)`, and its header
//! stamps the schema version those addresses were written under.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, StepId};
use codetracer_trace_writer::line_position::LinePositionSpace;
use codetracer_trace_writer::meta_dat::{FLAG_HAS_STEP_STREAM, encode_meta_dat};
use codetracer_trace_writer::step_stream::{StepStream, StepStreamRecord, encode_step_stream};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
use db_backend::ctfs_trace_reader::meta_dat::LAST_SHIFTED_GLOBAL_INDEX_VERSION;
use db_backend::trace_reader::TraceReader;

/// A canonical UUIDv7, which `meta.dat` has required since v3.
const RECORDING_ID: &str = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb";

/// Two source files, because path 0's base is 0 under every apportionment: a
/// single-file container cannot tell one encode from the other.
const SOURCES: [&str; 2] = ["/tmp/superseded_gli_main.py", "/tmp/superseded_gli_lib.py"];

/// The `(file_id, line)` each step was recorded at, in stream order. Lines
/// above 1 throughout, since line 1 sits at its file's base under both encodes
/// and would hide the difference.
const RECORDED: [(usize, i64); 6] = [(0, 7), (1, 12), (0, 8), (1, 13), (0, 9), (1, 40)];

/// An interning table with no records: no name bytes, and the single leading
/// end-offset every `.off` index starts with.
const EMPTY_TABLE_DAT: &[u8] = &[];
const EMPTY_TABLE_OFF: &[u8] = &[0, 0, 0, 0, 0, 0, 0, 0];

/// The internal files a line-only split-stream container carries.
struct Container {
    meta: Vec<u8>,
    paths_dat: Vec<u8>,
    paths_off: Vec<u8>,
    steps_dat: Vec<u8>,
    steps_idx: Vec<u8>,
}

impl Container {
    fn write(&self, path: &Path) {
        write_minimal_ctfs(
            path,
            &[
                ("steps.dat", &self.steps_dat),
                ("steps.idx", &self.steps_idx),
                ("paths.dat", &self.paths_dat),
                ("paths.off", &self.paths_off),
                // The pure-Rust reader builds ALL FOUR interning tables from a
                // container that carries any of them, so the three this fixture
                // has no vocabulary for are present and empty rather than
                // absent. Without them the container is refused for a missing
                // `funcs.dat` — a refusal that would mask the one under test.
                ("funcs.dat", EMPTY_TABLE_DAT),
                ("funcs.off", EMPTY_TABLE_OFF),
                ("types.dat", EMPTY_TABLE_DAT),
                ("types.off", EMPTY_TABLE_OFF),
                ("varnames.dat", EMPTY_TABLE_DAT),
                ("varnames.off", EMPTY_TABLE_OFF),
                ("meta.dat", &self.meta),
            ],
        )
        .expect("write container");
    }
}

/// The address space `SOURCES` defines — the same one the reader rebuilds from
/// the container's own `paths.off`.
fn space() -> LinePositionSpace {
    LinePositionSpace::uniform(SOURCES.len())
}

/// `paths.dat` (concatenated raw path bytes) and `paths.off` (`count + 1`
/// cumulative little-endian end-offsets), as the production writers emit a
/// line-only path interning table.
fn path_table() -> (Vec<u8>, Vec<u8>) {
    let mut dat = Vec::new();
    let mut off = 0u64.to_le_bytes().to_vec();
    for src in SOURCES {
        dat.extend_from_slice(src.as_bytes());
        off.extend_from_slice(&(dat.len() as u64).to_le_bytes());
    }
    (dat, off)
}

/// Build a container whose steps carry `addresses`, with `version` stamped over
/// the header the current writer emits.
fn container(addresses: &[u64], version: u16) -> Container {
    let stream = StepStream {
        records: addresses
            .iter()
            .map(|a| StepStreamRecord::Step { global_line_index: *a })
            .collect(),
        // Every step absolute, so each address is on the wire as written rather
        // than as a delta from its predecessor. The fixture is about which
        // integers the steps carry.
        forced_absolute: vec![true; addresses.len()],
    };
    let encoded = encode_step_stream(&stream, 4, 3).expect("encode steps.dat");

    let mut meta = encode_meta_dat(
        RECORDING_ID,
        "superseded_gli",
        &[],
        "/tmp",
        "test-recorder",
        &SOURCES.map(str::to_owned),
        FLAG_HAS_STEP_STREAM,
    );
    // The current writer can no longer stamp a superseded version — that is
    // what the bump means — so the fixture sets the field back over a header it
    // did produce. Every other byte is what a writer at that version wrote.
    meta[4..6].copy_from_slice(&version.to_le_bytes());

    let (paths_dat, paths_off) = path_table();
    Container {
        meta,
        paths_dat,
        paths_off,
        steps_dat: encoded.dat,
        steps_idx: encoded.idx,
    }
}

/// The addresses the CURRENT writer gives `RECORDED`: the file's base plus the
/// line's 0-based in-file offset.
fn current_addresses() -> Vec<u64> {
    let space = space();
    RECORDED
        .iter()
        .map(|(file, line)| space.global_index_of(*file, *line).expect("file registered"))
        .collect()
}

/// The addresses a writer BEFORE the correction gave `RECORDED`: the file's base
/// plus the 1-based line, one above the current encode at every line.
fn superseded_addresses() -> Vec<u64> {
    let space = space();
    let addresses: Vec<u64> = RECORDED
        .iter()
        .map(|(file, line)| space.file_base(*file).expect("file registered") + *line as u64)
        .collect();

    // Guard the fixture: if these ever stopped being the superseded encode, the
    // tests below would be about a container no writer ever produced.
    for (address, current) in addresses.iter().zip(current_addresses()) {
        assert_eq!(
            *address,
            current + 1,
            "the superseded encode is exactly one above the current one at every line"
        );
    }
    addresses
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("ct-superseded-gli-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create test dir");
    dir
}

/// The positive half, at both entry points: a container at the current version
/// opens, and every step reads back at the file and line it was recorded at.
/// Without this the refusal below could be passing because the fixture is
/// unopenable for some unrelated reason.
#[test]
fn a_current_container_opens_and_its_steps_read_back_where_they_were_recorded() {
    let dir = temp_dir("current");
    let ct = dir.join("current.ct");
    container(
        &current_addresses(),
        db_backend::ctfs_trace_reader::meta_dat::META_DAT_VERSION,
    )
    .write(&ct);
    let bytes = std::fs::read(&ct).expect("read container");

    let readers = [
        (
            "open",
            CTFSTraceReader::open(&ct).expect("open() must accept a current container"),
        ),
        (
            "from_bytes",
            CTFSTraceReader::from_bytes(bytes).expect("from_bytes() must accept a current container"),
        ),
    ];
    for (surface, reader) in &readers {
        for (i, (file, line)) in RECORDED.iter().enumerate() {
            let step = reader
                .step(StepId(i as i64))
                .unwrap_or_else(|| panic!("{surface}: step {i} present"));
            assert_eq!(
                reader.db().paths[step.path_id],
                SOURCES[*file],
                "{surface}: step {i} was recorded in {}",
                SOURCES[*file]
            );
            assert_eq!(
                step.line,
                Line(*line),
                "{surface}: step {i} was recorded at line {line}"
            );
        }
    }
}

/// THE REFUSAL, at both entry points a caller reaches. A container at the last
/// pre-correction schema version is refused, and the refusal names what reading
/// it anyway would do — the only fact that tells a caller the remedy is to
/// re-record rather than to wait for a newer reader.
///
/// The two surfaces are refused by DIFFERENT gates and both are needed.
/// `open` routes a native build through the Nim FFI reader, which refuses on
/// its own `LastShiftedGlobalIndexVersion`; `from_bytes` is the pure-Rust
/// constructor the browser takes, and only this crate's
/// [`db_backend::ctfs_trace_reader::meta_dat::SUPPORTED_VERSIONS`] stands in
/// front of it. Widening either set alone leaves that surface reading the
/// container one line high while the other still refuses it, which is why the
/// assertion is written per surface rather than over one of them.
#[test]
fn a_superseded_container_is_refused_at_every_entry_point() {
    let dir = temp_dir("refused");
    let ct = dir.join("superseded.ct");
    container(&superseded_addresses(), LAST_SHIFTED_GLOBAL_INDEX_VERSION).write(&ct);
    let bytes = std::fs::read(&ct).expect("read container");

    let from_path = CTFSTraceReader::open(&ct)
        .err()
        .expect("open() must refuse a pre-correction container")
        .to_string();
    let from_bytes = CTFSTraceReader::from_bytes(bytes)
        .err()
        .expect("from_bytes() must refuse a pre-correction container")
        .to_string();

    for (surface, err) in [("open", &from_path), ("from_bytes", &from_bytes)] {
        assert!(
            err.contains(&format!("schema version {LAST_SHIFTED_GLOBAL_INDEX_VERSION}")),
            "{surface} must name the version it refused: {err}"
        );
        assert!(
            err.contains("one line high"),
            "{surface} must name the consequence: {err}"
        );
        assert!(err.contains("Re-record"), "{surface} must name the remedy: {err}");
    }
}

/// THE MUTATION CONTROL. What the reader would do if the version gate were
/// removed, performed here on the same fixture: resolve the superseded
/// container's own addresses in the space its own path table defines.
///
/// Every step comes back at a real file and a real line, one line above where
/// it was recorded, and `resolve` reports no error at any of them — which is
/// why the schema version has to carry the distinction. This is asserted as the
/// defect the gate prevents; it is not the reading anything is expected to
/// produce.
#[test]
fn resolving_a_superseded_container_puts_every_step_one_line_high() {
    let space = space();
    for (address, (file, line)) in superseded_addresses().iter().zip(RECORDED) {
        let resolved = space
            .resolve(*address)
            .unwrap_or_else(|e| panic!("a superseded address is INSIDE the space, which is the problem: {e}"));
        assert_eq!(
            resolved,
            (file, line + 1),
            "reading a pre-correction address under the current decode reports line {} as {}",
            line,
            line + 1
        );
    }
}
