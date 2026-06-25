//! Product-level RR omniscient DB acceptance test.
//!
//! This test deliberately drives the same binaries an operator uses:
//! `ct record --backend rr` followed by `trace omniscient-prep`. The debuggee is
//! a small but ordinary C program with multiple functions, heap/global/stack
//! writes, and OS interaction. The assertions decode the product-produced
//! `memwrites.tc` / `linehits.tc` artifacts and validate source-derived write
//! transitions instead of relying on backend-only proof fixtures.

use codetracer_bench::omniscient_db_size::find_ct_container;
use codetracer_bench::{
    FixtureRecorder, Language, RecorderError, ct_binary, ct_cli_binary, ct_command, which,
};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
struct WlogWrite {
    tick: u64,
    pc: u64,
    address: u64,
    size: u8,
    old_value: u64,
    new_value: u64,
}

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn skip(reason: &str) {
    eprintln!("SKIPPED: {reason}");
}

fn decode_wlog(image: &[u8]) -> Result<Vec<WlogWrite>, String> {
    if image.len() < 32 {
        return Err(format!("WLOG too small: {} bytes", image.len()));
    }
    if &image[0..4] != b"WLOG" {
        return Err("WLOG bad magic".to_string());
    }
    let version = u32::from_le_bytes(image[4..8].try_into().unwrap());
    if version != 1 {
        return Err(format!("WLOG bad version: {version}"));
    }
    let write_count = u64::from_le_bytes(image[8..16].try_into().unwrap());
    let snapshot_count = u64::from_le_bytes(image[16..24].try_into().unwrap());
    let call_count = u64::from_le_bytes(image[24..32].try_into().unwrap());
    assert_eq!(
        snapshot_count, 0,
        "collapsed product memwrites.tc must not smuggle snapshot records"
    );
    assert_eq!(
        call_count, 0,
        "collapsed product memwrites.tc must not smuggle call records"
    );

    let mut pos = 32usize;
    let mut out = Vec::with_capacity(write_count as usize);
    while pos < image.len() {
        let tag = image[pos];
        pos += 1;
        if tag != 1 {
            return Err(format!("WLOG unexpected record tag {tag}"));
        }
        let read_u64 = |at: usize| -> Result<u64, String> {
            image
                .get(at..at + 8)
                .and_then(|s| s.try_into().ok())
                .map(u64::from_le_bytes)
                .ok_or_else(|| format!("WLOG truncated at {at}"))
        };
        let tick = read_u64(pos)?;
        pos += 8;
        let pc = read_u64(pos)?;
        pos += 8;
        let address = read_u64(pos)?;
        pos += 8;
        let size = *image.get(pos).ok_or("WLOG truncated size")?;
        pos += 1;
        let old_value = read_u64(pos)?;
        pos += 8;
        let new_value = read_u64(pos)?;
        pos += 8;
        out.push(WlogWrite {
            tick,
            pc,
            address,
            size,
            old_value,
            new_value,
        });
    }
    if out.len() as u64 != write_count {
        return Err(format!(
            "WLOG write count mismatch: header={write_count} decoded={}",
            out.len()
        ));
    }
    Ok(out)
}

fn decode_lhts(image: &[u8]) -> Result<Vec<(u32, u32, Vec<u64>)>, String> {
    if image.len() < 16 {
        return Err(format!("LHTS too small: {} bytes", image.len()));
    }
    if &image[0..4] != b"LHTS" {
        return Err("LHTS bad magic".to_string());
    }
    let version = u32::from_le_bytes(image[4..8].try_into().unwrap());
    if version != 1 {
        return Err(format!("LHTS bad version: {version}"));
    }
    let entries = u64::from_le_bytes(image[8..16].try_into().unwrap());
    let mut pos = 16usize;
    let mut out = Vec::with_capacity(entries as usize);
    for _ in 0..entries {
        let file_id = u32::from_le_bytes(
            image
                .get(pos..pos + 4)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| format!("LHTS truncated file_id at {pos}"))?,
        );
        pos += 4;
        let line = u32::from_le_bytes(
            image
                .get(pos..pos + 4)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| format!("LHTS truncated line at {pos}"))?,
        );
        pos += 4;
        let count = u64::from_le_bytes(
            image
                .get(pos..pos + 8)
                .and_then(|s| s.try_into().ok())
                .ok_or_else(|| format!("LHTS truncated count at {pos}"))?,
        );
        pos += 8;
        let mut ticks = Vec::with_capacity(count as usize);
        for _ in 0..count {
            ticks.push(u64::from_le_bytes(
                image
                    .get(pos..pos + 8)
                    .and_then(|s| s.try_into().ok())
                    .ok_or_else(|| format!("LHTS truncated tick at {pos}"))?,
            ));
            pos += 8;
        }
        out.push((file_id, line, ticks));
    }
    if pos != image.len() {
        return Err(format!(
            "LHTS trailing bytes: decoded through {pos}, len={}",
            image.len()
        ));
    }
    Ok(out)
}

fn run_native_omniscient_prep(slice_folder: &Path) -> Result<(), String> {
    let bin = ct_binary().ok_or_else(|| "ct binary not on PATH".to_string())?;
    let output = ct_command(&bin)
        .arg("trace")
        .arg("omniscient-prep")
        .arg(slice_folder)
        .arg("--mode")
        .arg("on")
        .output()
        .map_err(|e| format!("failed to spawn {}: {e}", bin.display()))?;
    if output.status.success() {
        return Ok(());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(format!(
        "native omniscient-prep failed with {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        stdout.lines().take(40).collect::<Vec<_>>().join("\n"),
        stderr.lines().take(40).collect::<Vec<_>>().join("\n")
    ))
}

fn find_write_events(root: &Path) -> Option<PathBuf> {
    for entry in walkdir::WalkDir::new(root) {
        let entry = entry.ok()?;
        if entry.file_type().is_file() && entry.file_name() == "write_events.txt" {
            return Some(entry.path().to_path_buf());
        }
    }
    None
}

#[test]
fn rr_product_path_builds_native_omniscient_artifacts_for_plain_c_program() {
    if !cfg!(target_os = "linux") {
        skip("rr product omniscient acceptance test is Linux-only");
        return;
    }
    expose_sibling_ct_native_replay_on_path();
    if ct_cli_binary().is_none() {
        skip("ct CLI not discoverable; run `just build-once` or set CT_CLI_BIN");
        return;
    }
    if ct_binary().is_none() {
        skip("ct launcher with `trace omniscient-prep` not discoverable; set CT_BIN or build ct");
        return;
    }
    if which("rr").is_none() {
        skip("rr binary not on PATH");
        return;
    }
    if which("gcc").is_none() {
        skip("gcc binary not on PATH");
        return;
    }

    let program = fixtures_root()
        .join("product-omniscient")
        .join("rr_c_arbitrary")
        .join("main.c");
    assert!(
        program.is_file(),
        "product omniscient C fixture missing at {}",
        program.display()
    );

    let temp = tempfile::tempdir().expect("tempdir");
    let trace_dir = temp.path().join("rr-product-omniscient");
    match FixtureRecorder::record_via_ct(Language::C, Some("rr"), &program, &trace_dir) {
        Ok(_) => {}
        Err(RecorderError::Unavailable(reason)) => {
            skip(&format!("ct record unavailable: {reason}"));
            return;
        }
        Err(err) => panic!("ct record --backend rr must succeed for product E2E fixture: {err}"),
    }

    let ct_path = find_ct_container(&trace_dir).unwrap_or_else(|| {
        panic!(
            "ct record --backend rr produced no *.ct container under {}",
            trace_dir.display()
        )
    });
    let slice_folder = ct_path.parent().unwrap_or(&trace_dir);

    let write_events = find_write_events(&trace_dir).unwrap_or_else(|| {
        panic!(
            "recorded RR trace under {} did not include write_events.txt; \
             fixture must exercise real OS write events",
            trace_dir.display()
        )
    });
    let write_events_bytes = std::fs::read(&write_events)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", write_events.display()));
    assert!(
        contains_bytes(&write_events_bytes, b"BEGIN")
            && contains_bytes(&write_events_bytes, b"END"),
        "RR write_events.txt must include fixture stdout boundaries; got {} bytes",
        write_events_bytes.len()
    );

    run_native_omniscient_prep(slice_folder).expect("native product omniscient-prep must succeed");

    let meta_dat = slice_folder.join("meta_dat");
    let memwrites_path = meta_dat.join("memwrites.tc");
    let linehits_path = meta_dat.join("linehits.tc");
    assert!(
        memwrites_path.is_file(),
        "native product omniscient-prep must emit memwrites.tc at {}",
        memwrites_path.display()
    );
    assert!(
        linehits_path.is_file(),
        "native product omniscient-prep must emit linehits.tc at {}",
        linehits_path.display()
    );

    let writes = decode_wlog(
        &std::fs::read(&memwrites_path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", memwrites_path.display())),
    )
    .expect("memwrites.tc must decode as WLOG");
    assert!(
        writes.len() >= 16,
        "expected product memwrites.tc to contain enough writes for globals, heap, stack, and libc-visible setup; got {}",
        writes.len()
    );
    let transitions: HashSet<(u64, u64)> =
        writes.iter().map(|w| (w.old_value, w.new_value)).collect();
    for expected in [
        (5, 17),
        (17, 34),
        (34, 51),
        (0, 0x1111),
        (0, 0x2222),
        (0, 0x3333),
    ] {
        assert!(
            transitions.contains(&expected),
            "memwrites.tc missing source-derived transition {expected:?}; decoded writes: {writes:?}"
        );
    }

    let linehits = decode_lhts(
        &std::fs::read(&linehits_path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", linehits_path.display())),
    )
    .expect("linehits.tc must decode as LHTS");
    assert!(
        linehits.len() >= 6,
        "expected linehits for multiple fixture source lines/functions, got {linehits:?}"
    );
    let total_hits: usize = linehits.iter().map(|(_, _, ticks)| ticks.len()).sum();
    assert!(
        total_hits >= 20,
        "expected repeated line hits across function calls and loops, got {total_hits}: {linehits:?}"
    );
    for (_, _, ticks) in &linehits {
        assert!(
            ticks.windows(2).all(|pair| pair[0] <= pair[1]),
            "linehits ticks must be sorted per source line: {linehits:?}"
        );
    }
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|candidate| candidate == needle)
}

fn expose_sibling_ct_native_replay_on_path() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidates = [
        manifest_dir
            .join("../../..")
            .join("codetracer-native-backend")
            .join("target")
            .join("debug"),
        manifest_dir
            .join("../..")
            .join("codetracer-native-backend")
            .join("target")
            .join("debug"),
    ];
    for dir in candidates {
        if !dir.join("ct-native-replay").is_file() {
            continue;
        }
        let mut paths = vec![dir];
        if let Some(path) = std::env::var_os("PATH") {
            paths.extend(std::env::split_paths(&path));
        }
        let joined = std::env::join_paths(paths).expect("join PATH entries");
        unsafe {
            std::env::set_var("PATH", joined);
        }
        return;
    }
}
