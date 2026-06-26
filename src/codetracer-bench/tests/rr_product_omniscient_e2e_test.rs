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
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
struct WlogWrite {
    tick: u64,
    pc: u64,
    address: u64,
    size: u32,
    old_value: u64,
    new_value: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct ExpectedTransition {
    name: &'static str,
    old_value: u64,
    new_value: u64,
}

const PAGE_SIZE: usize = 4096;
const NSB_HEADER_TOTAL: usize = 61;
const NSB_KIND_LEAF: u8 = 1;
const NSB_NODE_HEADER_BYTES: usize = 8;
const NSB_RECORD_SIZE: usize = 4 + 8 + 8 + 4 + 8 + 8;

fn expected_model() -> Vec<ExpectedTransition> {
    let first = u64::from(b'r');
    let local0 = first + 7;
    let local1 = local0 * 3;
    let local2 = local1 ^ 0x44;
    let local3 = local2 + 34;
    vec![
        ExpectedTransition {
            name: "counter 5->17",
            old_value: 5,
            new_value: 17,
        },
        ExpectedTransition {
            name: "counter 17->34",
            old_value: 17,
            new_value: 34,
        },
        ExpectedTransition {
            name: "counter 34->51",
            old_value: 34,
            new_value: 51,
        },
        ExpectedTransition {
            name: "heap[0]",
            old_value: 0,
            new_value: 0x1111,
        },
        ExpectedTransition {
            name: "heap[1]",
            old_value: 0,
            new_value: 0x2222,
        },
        ExpectedTransition {
            name: "heap[2]",
            old_value: 0,
            new_value: 0x3333,
        },
        ExpectedTransition {
            name: "g_slots[0]",
            old_value: 0,
            new_value: 0x3333,
        },
        ExpectedTransition {
            name: "g_slots[1]",
            old_value: 0,
            new_value: 0x3333 ^ 0x55,
        },
        ExpectedTransition {
            name: "local[0]",
            old_value: 0,
            new_value: local0,
        },
        ExpectedTransition {
            name: "local[1]",
            old_value: 0,
            new_value: local1,
        },
        ExpectedTransition {
            name: "local[2]",
            old_value: 0,
            new_value: local2,
        },
        ExpectedTransition {
            name: "local[3]",
            old_value: 0,
            new_value: local3,
        },
        ExpectedTransition {
            name: "g_slots[2]",
            old_value: 0,
            new_value: local3,
        },
    ]
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
            size: u32::from(size),
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

fn read_u16_at(image: &[u8], off: usize, section: &str) -> Result<u16, String> {
    image
        .get(off..off + 2)
        .and_then(|s| s.try_into().ok())
        .map(u16::from_le_bytes)
        .ok_or_else(|| format!("NSB1 truncated {section} at {off}"))
}

fn read_u64_at(image: &[u8], off: usize, section: &str) -> Result<u64, String> {
    image
        .get(off..off + 8)
        .and_then(|s| s.try_into().ok())
        .map(u64::from_le_bytes)
        .ok_or_else(|| format!("NSB1 truncated {section} at {off}"))
}

fn nsb_page<'a>(image: &'a [u8], page: u64, section: &str) -> Result<&'a [u8], String> {
    let base = (page as usize)
        .checked_mul(PAGE_SIZE)
        .ok_or_else(|| format!("NSB1 {section} page overflow at {page}"))?;
    image
        .get(base..base + PAGE_SIZE)
        .ok_or_else(|| format!("NSB1 {section} page {page} out of bounds"))
}

fn nsb_node_key(page: &[u8], index: usize) -> Result<u64, String> {
    read_u64_at(page, NSB_NODE_HEADER_BYTES + index * 8, "node key")
}

fn collect_nsb_keys(image: &[u8], root: u64) -> Result<Vec<u64>, String> {
    let page_count = image.len() / PAGE_SIZE;
    let mut keys = Vec::new();
    let mut stack = vec![root];
    let mut budget = page_count + 1;
    while let Some(page_num) = stack.pop() {
        if budget == 0 {
            return Err("NSB1 key walk exceeded page budget".to_string());
        }
        budget -= 1;
        let page = nsb_page(image, page_num, "node")?;
        let count = read_u16_at(page, 2, "node count")? as usize;
        if page[0] == NSB_KIND_LEAF {
            for index in 0..count {
                keys.push(nsb_node_key(page, index)?);
            }
        } else {
            for child_index in 0..=count {
                let child_off = NSB_NODE_HEADER_BYTES + count * 8 + child_index * 8;
                let child = read_u64_at(page, child_off, "internal child")?;
                if child != 0 && (child as usize) < page_count {
                    stack.push(child);
                }
            }
        }
    }
    keys.sort_unstable();
    Ok(keys)
}

fn lookup_nsb_descriptor<'a>(image: &'a [u8], root: u64, key: u64) -> Result<&'a [u8], String> {
    let page_count = image.len() / PAGE_SIZE;
    let mut page_num = root;
    for _ in 0..=page_count {
        let page = nsb_page(image, page_num, "lookup node")?;
        let count = read_u16_at(page, 2, "lookup count")? as usize;
        let mut lo = 0usize;
        let mut hi = count;
        while lo < hi {
            let mid = (lo + hi) >> 1;
            if nsb_node_key(page, mid)? < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if page[0] == NSB_KIND_LEAF {
            if lo < count && nsb_node_key(page, lo)? == key {
                let desc_base = NSB_NODE_HEADER_BYTES + count * 8 + lo * 16;
                return page
                    .get(desc_base..desc_base + 16)
                    .ok_or_else(|| "NSB1 leaf descriptor out of bounds".to_string());
            }
            return Err(format!("NSB1 key {key:#x} not found"));
        }
        let child_index = if lo < count && nsb_node_key(page, lo)? == key {
            lo + 1
        } else {
            lo
        };
        let child_off = NSB_NODE_HEADER_BYTES + count * 8 + child_index * 8;
        page_num = read_u64_at(page, child_off, "lookup child")?;
        if page_num == 0 || (page_num as usize) >= page_count {
            return Err(format!("NSB1 child page {page_num} out of bounds"));
        }
    }
    Err("NSB1 lookup exceeded page budget".to_string())
}

fn decode_nsb_memwrites(image: &[u8]) -> Result<Vec<WlogWrite>, String> {
    if image.len() < NSB_HEADER_TOTAL {
        return Err(format!("NSB1 too small: {} bytes", image.len()));
    }
    if &image[0..4] != b"NSB1" {
        return Err("NSB1 bad magic".to_string());
    }
    if !image.len().is_multiple_of(PAGE_SIZE) {
        return Err(format!("NSB1 image is not page-aligned: {}", image.len()));
    }
    if image[36] & 0b1 == 0 {
        return Err("NSB1 memwrites must use Type-B descriptors".to_string());
    }
    let root0 = read_u64_at(image, 4, "root0")?;
    let root1 = read_u64_at(image, 12, "root1")?;
    let commit0 = read_u64_at(image, 20, "commit0")?;
    let commit1 = read_u64_at(image, 28, "commit1")?;
    let root = if commit1 > commit0 { root1 } else { root0 };
    if root == 0 || commit0 == 0 && commit1 == 0 {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();
    for address in collect_nsb_keys(image, root)? {
        let desc = lookup_nsb_descriptor(image, root, address)?;
        let payload_offset = read_u64_at(desc, 0, "payload offset")? as usize;
        let payload_len = read_u64_at(desc, 8, "payload len")? as usize;
        let payload = image
            .get(payload_offset..payload_offset.saturating_add(payload_len))
            .ok_or_else(|| {
                format!(
                    "NSB1 payload [{payload_offset}, {}) out of bounds",
                    payload_offset + payload_len
                )
            })?;
        if !payload.len().is_multiple_of(NSB_RECORD_SIZE) {
            return Err(format!("NSB1 bad memwrite payload len {}", payload.len()));
        }
        for record in payload.chunks_exact(NSB_RECORD_SIZE) {
            let tick = read_u64_at(record, 4, "record tick")?;
            let pc = read_u64_at(record, 12, "record pc")?;
            let size = u32::from_le_bytes(record[20..24].try_into().unwrap());
            let old_value = read_u64_at(record, 24, "record old")?;
            let new_value = read_u64_at(record, 32, "record new")?;
            out.push(WlogWrite {
                tick,
                pc,
                address,
                size,
                old_value,
                new_value,
            });
        }
    }
    out.sort_by_key(|w| (w.tick, w.address, w.pc));
    Ok(out)
}

fn decode_memwrites(image: &[u8]) -> Result<Vec<WlogWrite>, String> {
    match image.get(0..4) {
        Some(b"WLOG") => decode_wlog(image),
        Some(b"NSB1") => decode_nsb_memwrites(image),
        _ => Err("memwrites bad magic".to_string()),
    }
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

fn compile_c_fixture(source: &Path, binary: &Path) -> Result<(), String> {
    let output = Command::new("gcc")
        .arg("-g")
        .arg("-O0")
        .arg("-fno-omit-frame-pointer")
        .arg("-o")
        .arg(binary)
        .arg(source)
        .output()
        .map_err(|e| format!("failed to spawn gcc: {e}"))?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "gcc failed with {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
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

fn model_line_numbers(program: &Path) -> HashMap<String, u32> {
    let source = std::fs::read_to_string(program)
        .unwrap_or_else(|e| panic!("failed to read model source {}: {e}", program.display()));
    let mut out = HashMap::new();
    for (index, line) in source.lines().enumerate() {
        let Some(marker_start) = line.find("MODEL:") else {
            continue;
        };
        let marker = line[marker_start + "MODEL:".len()..]
            .chars()
            .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_')
            .collect::<String>();
        assert!(
            !marker.is_empty(),
            "empty MODEL marker on source line {}",
            index + 1
        );
        assert!(
            out.insert(marker.clone(), (index + 1) as u32).is_none(),
            "duplicate MODEL marker {marker}"
        );
    }
    out
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
    let binary = temp.path().join("rr-product-omniscient-fixture");
    compile_c_fixture(&program, &binary).expect("fixture C binary must compile with debug info");
    let trace_dir = temp.path().join("rr-product-omniscient");
    match FixtureRecorder::record_via_ct(Language::C, Some("rr"), &binary, &trace_dir) {
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
    assert!(
        contains_bytes(&write_events_bytes, b"51 13107 13158 337"),
        "RR write_events.txt must include model-predicted final stdout values; got: {}",
        String::from_utf8_lossy(&write_events_bytes)
    );

    run_native_omniscient_prep(slice_folder).expect("native product omniscient-prep must succeed");

    let meta_dat = slice_folder.join("meta_dat");
    let memwrites_path = meta_dat.join("memwrites.tc");
    let linehits_path = meta_dat.join("linehits.tc");
    let path_marker = meta_dat.join("omniscient-prep-path.txt");
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
    let producer_path = std::fs::read_to_string(&path_marker)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path_marker.display()));
    assert!(
        producer_path.trim().starts_with("rr-emulator-lazy"),
        "RR omniscient-prep must use the lazy emulator producer, not the GDB \
         snapshot-diff collector; marker was {producer_path:?}"
    );

    let memwrites_image = std::fs::read(&memwrites_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", memwrites_path.display()));
    assert_eq!(
        memwrites_image.get(0..4),
        Some(&b"NSB1"[..]),
        "product memwrites.tc must use the production NSB1 namespace"
    );
    let writes = decode_memwrites(&memwrites_image).expect("memwrites.tc must decode");
    assert!(
        writes.len() >= expected_model().len(),
        "expected product memwrites.tc to contain at least the source-model writes; got {}",
        writes.len()
    );
    let transitions: HashSet<(u64, u64)> =
        writes.iter().map(|w| (w.old_value, w.new_value)).collect();
    for expected in expected_model() {
        assert!(
            transitions.contains(&(expected.old_value, expected.new_value)),
            "memwrites.tc missing model transition {}: {} -> {}; decoded writes: {writes:?}",
            expected.name,
            expected.old_value,
            expected.new_value
        );
    }
    assert!(
        writes.windows(2).all(|pair| pair[0].tick <= pair[1].tick),
        "decoded memwrites must be sorted by tick for stable queries: {writes:?}"
    );
    assert!(
        writes.iter().all(|w| (1..=8).contains(&w.size)),
        "memwrites must use supported <=8-byte write runs: {writes:?}"
    );

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
    let hit_lines: HashSet<u32> = linehits.iter().map(|(_, line, _)| *line).collect();
    let model_lines = model_line_numbers(&program);
    for marker in [
        "counter", "heap0", "heap1", "heap2", "slot0", "slot1", "local0", "local1", "local2",
        "local3", "slot2",
    ] {
        let line = *model_lines
            .get(marker)
            .unwrap_or_else(|| panic!("fixture missing MODEL marker {marker}"));
        assert!(
            hit_lines.contains(&line),
            "linehits.tc missing source-model line {line} for marker {marker}; decoded linehits: {linehits:?}"
        );
    }
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
