//! CCP-5 — peak resident memory for the largest compact container the 1 MiB
//! raw-byte threshold admits.
//!
//! # Why this re-executes its own binary
//!
//! `VmHWM` is a HIGH-WATER MARK and it never falls. Measuring it twice inside
//! one test process measures the maximum of everything the process has done,
//! so the second reading would carry the first container's allocation and the
//! comparison the control asks for — a container at the threshold against one
//! well under it — would be arithmetic on one number. Each reading is therefore
//! taken in a FRESH child process that does nothing but open one container, and
//! a third child that opens NOTHING supplies the harness baseline that is
//! subtracted. Three processes, three independent high-water marks.
//!
//! # The threshold figure
//!
//! `DefaultRawByteThreshold` is 1 MiB = 1,048,576 RAW member bytes (CCP-4). The
//! at-threshold fixture below is grown event by event to the largest payload
//! that still fits, and is asserted to be within ONE EVENT of the limit — so it
//! is a boundary container rather than merely an admissible one.
//!
//! # No mocks
//!
//! Both containers are real: genuinely RAW members (no per-member compression
//! anywhere, which is what §1d requires of a compact container and what makes
//! the raw-byte threshold the thing being measured) behind a real §1d
//! directory, opened by the production `CTFSTraceReader`.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use codetracer_trace_types::{
    CallRecord, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, StepRecord, TraceLowLevelEvent, TypeId,
    TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord, VariableId,
};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::ctfs_trace_reader::ctfs_container::{CtfsProfile, CtfsReader, write_compact_ctfs};
use db_backend::ctfs_trace_reader::meta_dat::{META_DAT_VERSION, MetaDat, serialize_meta_dat};
use db_backend::trace_reader::TraceReader;

/// `codetracer_trace_format_cbor_zstd::HEADERV1`.
const EVENTS_HEADER_V1: [u8; 8] = [0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x01, 0x00, 0x00];

/// CCP-4's `DefaultRawByteThreshold`: 1 MiB of RAW member bytes.
const RAW_BYTE_THRESHOLD: u64 = 1 << 20;

/// Env var that turns the child test below from a no-op into a measurement.
const CHILD_ENV: &str = "CCP5_PEAK_CONTAINER";

const SRC: &str = "/tmp/ccp5/peak.rs";

// ── Fixture: a compact container with genuinely RAW members ─────────────

fn preamble_events() -> Vec<TraceLowLevelEvent> {
    vec![
        TraceLowLevelEvent::Path(PathBuf::from(SRC)),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Type(TypeRecord {
            kind: TypeKind::Int,
            lang_type: "Int".to_string(),
            specific_info: TypeSpecificInfo::None,
        }),
        TraceLowLevelEvent::Function(FunctionRecord {
            path_id: PathId(0),
            line: Line(1),
            name: "main".to_string(),
        }),
        TraceLowLevelEvent::Call(CallRecord {
            function_id: FunctionId(0),
            args: vec![],
        }),
    ]
}

fn step_events(i: usize) -> Vec<TraceLowLevelEvent> {
    vec![
        TraceLowLevelEvent::Step(StepRecord {
            path_id: PathId(0),
            line: Line(10 + (i % 23) as i64),
        }),
        TraceLowLevelEvent::VariableName(format!("v{}", i % 64)),
        TraceLowLevelEvent::Value(FullValueRecord {
            variable_id: VariableId(i % 64),
            value: ValueRecord::Int {
                i: i as i64,
                type_id: TypeId(1),
            },
        }),
    ]
}

fn meta_dat_bytes(program: &str, workdir: &str) -> Vec<u8> {
    serialize_meta_dat(&MetaDat {
        version: META_DAT_VERSION,
        flags: 0,
        recording_id: "01949fcc-7d92-7e9c-bccc-dddddddddddd".to_owned(),
        program: program.to_owned(),
        args: vec![],
        workdir: workdir.to_owned(),
        recorder_id: "ccp5".to_owned(),
        paths: vec![],
        mcr: None,
        replay_launch: None,
        layout_snapshot: None,
        filter_provenance: vec![],
        has_filter_provenance: false,
    })
}

/// Build a compact container whose RAW member payload is as close to `budget`
/// as one more recorded step would overshoot.
///
/// Returns `(path, user_step_count, raw_member_payload_bytes, bytes_one_more_step_would_add)`.
///
/// "Raw member payload" is the sum of the member payloads the compact container
/// carries — `events.log` plus `meta.dat` — which is the quantity CCP-4's
/// threshold is defined on. The 76 bytes of header and directory are container
/// overhead and are deliberately NOT counted, because the threshold answers
/// "can the streams be resident", not "how big is the file".
fn build_compact_at_budget(dir: &Path, name: &str, budget: u64) -> (PathBuf, usize, u64, u64) {
    let meta = meta_dat_bytes(name, dir.to_string_lossy().as_ref());
    let path = dir.join(format!("{name}.ct"));

    let encode = |events: Vec<TraceLowLevelEvent>| {
        let mut buf = Vec::new();
        for event in &events {
            buf = cbor4ii::serde::to_vec(buf, event).expect("a TraceLowLevelEvent always CBOR-encodes");
        }
        buf
    };

    let mut body = encode(preamble_events());
    let payload = |body_len: usize| (EVENTS_HEADER_V1.len() + body_len + meta.len()) as u64;
    assert!(
        payload(body.len()) < budget,
        "the preamble alone is {} bytes, which does not fit a {budget}-byte budget",
        payload(body.len())
    );

    let mut steps = 0usize;
    loop {
        let next = encode(step_events(steps));
        if payload(body.len() + next.len()) > budget {
            let mut log = EVENTS_HEADER_V1.to_vec();
            log.extend_from_slice(&body);
            write_compact_ctfs(&path, &[("events.log", &log), ("meta.dat", &meta)])
                .expect("the compact encoder writes");
            return (path, steps, payload(body.len()), next.len() as u64);
        }
        body.extend_from_slice(&next);
        steps += 1;
    }
}

// ── Peak measurement ────────────────────────────────────────────────────

/// This process's peak resident set size in KiB, read from the kernel.
///
/// `VmHWM` and not `VmRSS`: the question is the PEAK, and a transient copy made
/// while decoding is exactly the thing a reading taken after the load would
/// miss.
fn peak_rss_kb() -> Option<u64> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmHWM:") {
            return rest.trim().trim_end_matches(" kB").trim().parse().ok();
        }
    }
    None
}

/// The child half: opens exactly one container (or none) and prints its peak.
///
/// A no-op in an ordinary `cargo test` run — the env var is set only by the
/// parent arm below — so it costs nothing and cannot be mistaken for a passing
/// measurement.
#[test]
fn ccp5_peak_memory_child() {
    let Ok(spec) = std::env::var(CHILD_ENV) else {
        return;
    };
    let reader = if spec == "none" {
        None
    } else {
        let path = PathBuf::from(&spec);
        let reader = CTFSTraceReader::open(&path).expect("the child opens its container");
        Some(reader)
    };
    let peak = peak_rss_kb().expect("the child reads its own VmHWM");
    // Keep the reader alive across the reading: a reader dropped first would be
    // measuring a process that no longer holds the trace.
    let steps = reader.as_ref().map(TraceReader::step_count).unwrap_or(0);
    println!("CCP5_PEAK_KB={peak} CCP5_STEPS={steps}");
    drop(reader);
}

fn child_peak_kb(container: &str) -> (u64, usize) {
    let exe = std::env::current_exe().expect("this test binary's own path");
    let output = Command::new(exe)
        .args(["--exact", "ccp5_peak_memory_child", "--nocapture"])
        .env(CHILD_ENV, container)
        .output()
        .expect("the child runs");
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    assert!(
        output.status.success(),
        "the child failed (rc {:?}) for {container}:\n{stdout}\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    let line = stdout
        .lines()
        .find(|l| l.contains("CCP5_PEAK_KB="))
        .unwrap_or_else(|| panic!("the child printed no peak for {container}:\n{stdout}"));
    let mut peak = 0u64;
    let mut steps = 0usize;
    for token in line.split_whitespace() {
        if let Some(v) = token.strip_prefix("CCP5_PEAK_KB=") {
            peak = v.parse().expect("peak is a number");
        }
        if let Some(v) = token.strip_prefix("CCP5_STEPS=") {
            steps = v.parse().expect("step count is a number");
        }
    }
    (peak, steps)
}

#[test]
fn test_peak_memory_is_bounded_by_the_threshold() {
    if !cfg!(target_os = "linux") || peak_rss_kb().is_none() {
        panic!(
            "this arm reads VmHWM from /proc/self/status and the kernel does not offer it here; \
             the figure is NOT MEASURED on this platform rather than defaulted"
        );
    }

    let dir = tempfile::tempdir().expect("tempdir");

    // (1) AT the threshold: the largest payload 1 MiB admits.
    let (at_path, at_steps, at_payload, next_event_bytes) =
        build_compact_at_budget(dir.path(), "ccp5_at_threshold", RAW_BYTE_THRESHOLD);
    let at_rest = fs::metadata(&at_path).expect("size").len();
    assert!(
        at_payload <= RAW_BYTE_THRESHOLD,
        "the at-threshold container's payload {at_payload} exceeds the {RAW_BYTE_THRESHOLD}-byte \
         threshold, so it is not admissible"
    );
    assert!(
        at_payload + next_event_bytes > RAW_BYTE_THRESHOLD,
        "the at-threshold container is {} bytes short of the threshold and one more event would \
         add only {next_event_bytes} — this is an admissible container, not a BOUNDARY one",
        RAW_BYTE_THRESHOLD - at_payload
    );

    // (2) WELL UNDER it: 1/64th of the budget. The control exists because a
    //     harness that reported a constant would report the same figure for
    //     both, and only two readings can show that.
    let (under_path, under_steps, under_payload, _) =
        build_compact_at_budget(dir.path(), "ccp5_well_under", RAW_BYTE_THRESHOLD / 16);
    let under_rest = fs::metadata(&under_path).expect("size").len();

    for (label, path) in [("at-threshold", &at_path), ("well-under", &under_path)] {
        let ctfs = CtfsReader::open(path).expect("it opens");
        assert_eq!(ctfs.profile(), CtfsProfile::Compact, "{label} is not compact");
        // §1d requires raw members, and the fixture's own claim to be measuring
        // RAW bytes rests on it. Checked against the bytes: a zstd frame magic
        // (0x28 0xB5 0x2F 0xFD) appears nowhere in the image.
        let image = fs::read(path).expect("read back");
        let frames = image.windows(4).filter(|w| *w == [0x28, 0xB5, 0x2F, 0xFD]).count();
        assert_eq!(
            frames, 0,
            "{label} carries {frames} zstd frame magic(s); its members are not raw and the \
             raw-byte figure would be measuring something else"
        );
    }

    // (3) Three independent peaks.
    let (baseline_kb, baseline_steps) = child_peak_kb("none");
    assert_eq!(baseline_steps, 0, "the baseline child must open nothing");
    let (under_kb, under_loaded) = child_peak_kb(under_path.to_string_lossy().as_ref());
    let (at_kb, at_loaded) = child_peak_kb(at_path.to_string_lossy().as_ref());

    assert!(
        at_loaded > under_loaded && under_loaded > 0,
        "the two children loaded {at_loaded} and {under_loaded} steps; a measurement where the \
         bigger container did not load more of the trace is not measuring the trace"
    );

    let at_delta = at_kb.saturating_sub(baseline_kb);
    let under_delta = under_kb.saturating_sub(baseline_kb);

    println!("CCP-5 deliverable 4 — peak resident memory, three fresh processes:");
    println!("| container | user steps | raw member bytes | at rest | child VmHWM | minus baseline |");
    println!("|---+---+---+---+---+---|");
    println!("| baseline (opens nothing) | - | - | - | {baseline_kb} KiB | 0 |");
    println!(
        "| well under threshold | {under_steps} | {under_payload} | {under_rest} B | \
         {under_kb} KiB | {under_delta} KiB |"
    );
    println!("| AT threshold | {at_steps} | {at_payload} | {at_rest} B | {at_kb} KiB | {at_delta} KiB |");
    println!(
        "steps materialised: {under_loaded} (well under) vs {at_loaded} (at threshold); \
         threshold = {RAW_BYTE_THRESHOLD} raw bytes, at-threshold container is {} bytes short and \
         one more event would add {next_event_bytes}",
        RAW_BYTE_THRESHOLD - at_payload
    );

    // (4) THE CONTROL: the figure must SCALE with content. If the at-threshold
    //     reading is not materially above the well-under one, the harness is
    //     reporting a constant and the number means nothing.
    assert!(
        at_delta > under_delta,
        "peak memory did not grow with content: {at_delta} KiB at the threshold against \
         {under_delta} KiB well under it, on containers of {at_payload} and {under_payload} raw \
         bytes. A figure that does not move with the payload is not a measurement of the payload."
    );
    // And it must scale by at least the content it gained: the at-threshold
    // container carries ~1 MiB more raw payload than the well-under one, and a
    // whole-file load that did not cost at least that much more memory would
    // not have loaded it.
    let extra_payload_kb = (at_payload - under_payload) / 1024;
    assert!(
        at_delta - under_delta >= extra_payload_kb,
        "the at-threshold container carries {extra_payload_kb} KiB more raw payload than the \
         well-under one, but its peak is only {} KiB higher ({at_delta} against {under_delta}) — \
         too flat to attribute to the container",
        at_delta - under_delta
    );

    // (5) THE BOUND. A whole-file load of a 1 MiB container materialises a Db
    //     whose arrays are several times the wire bytes — that is the trade the
    //     profile makes, and the figure is here to size it rather than to be
    //     zero. The bound is deliberately generous and is a bound on the ORDER:
    //     a threshold-admissible container must not cost hundreds of megabytes,
    //     which is the only way the 1 MiB default could be indefensible.
    const BOUND_KB: u64 = 512 * 1024;
    assert!(
        at_delta < BOUND_KB,
        "peak resident memory for the largest threshold-admissible compact container is \
         {at_delta} KiB, above the {BOUND_KB} KiB bound. The 1 MiB default is not defensible at \
         that cost and the threshold, not this assertion, is what should move."
    );
    println!(
        "bound: {at_delta} KiB < {BOUND_KB} KiB — the 1 MiB raw-byte default costs {:.1}x the \
         container's own bytes in resident memory",
        (at_delta * 1024) as f64 / at_rest as f64
    );
}
