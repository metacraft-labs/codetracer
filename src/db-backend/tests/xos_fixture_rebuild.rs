//! Helper integration test that regenerates the slimmed M-XOS-Fixture
//! `xos_hello.ct`. Gated behind `#[ignore]` so a normal `cargo test`
//! run does not touch the on-disk fixture; invoked explicitly by
//! `tests/fixtures/xos/rebuild.sh` after `ct_cli record` produces the
//! full-snapshot source `.ct`.
//!
//! Strategy: load the full-size source `.ct`, parse `cp0.mem` into
//! `(address, bytes)` regions, keep only the PIE program load segments
//! (addresses in the 0x550000000000..0x600000000000 range Linux mmaps
//! PIE binaries into) plus whichever region contains the recorded
//! `cp0.regs.rsp` (= the `[stack]` mapping). Re-pack `cp0.mem` and
//! re-emit the container via `write_minimal_ctfs`, preserving every
//! other internal file byte-for-byte.

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};

/// Decode `cp0.mem` into a flat list of `(address, bytes)` regions.
/// Mirrors the layout `_ct_full_snapshot_walk` writes in
/// `codetracer-native-recorder/ct_interpose/src/ct_interpose/full_snapshot.c`:
/// each region is `u64 address LE | u64 size LE | size bytes`.
fn parse_cp0_mem(blob: &[u8]) -> Vec<(u64, Vec<u8>)> {
    let mut out = Vec::new();
    let mut o = 0usize;
    while o + 16 <= blob.len() {
        let addr = u64::from_le_bytes(blob[o..o + 8].try_into().expect("8 bytes"));
        let size = u64::from_le_bytes(blob[o + 8..o + 16].try_into().expect("8 bytes"));
        if o + 16 + size as usize > blob.len() {
            // Truncated tail — bail out cleanly rather than panic.
            break;
        }
        out.push((addr, blob[o + 16..o + 16 + size as usize].to_vec()));
        o += 16 + size as usize;
    }
    out
}

/// Pack a list of regions back into the `cp0.mem` on-disk layout.
fn pack_cp0_mem(regs: &[(u64, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (a, b) in regs {
        out.extend_from_slice(&a.to_le_bytes());
        out.extend_from_slice(&(b.len() as u64).to_le_bytes());
        out.extend_from_slice(b);
    }
    out
}

/// Extract RSP from a compact 144-byte `cp0.regs` payload (`tid:u32 |
/// len:u32 = 144 | 18 × u64 GPRs`). RSP sits at GPR index 7 — see
/// `pack_cp0_regs_compact` in `src/emulator_session.rs`.
fn parse_cp0_regs_rsp(blob: &[u8]) -> Option<u64> {
    const HEADER: usize = 8;
    const RSP_INDEX: usize = 7;
    if blob.len() < HEADER + 144 {
        return None;
    }
    let base = HEADER + RSP_INDEX * 8;
    Some(u64::from_le_bytes(blob[base..base + 8].try_into().ok()?))
}

#[test]
#[ignore = "regeneration helper, invoked by tests/fixtures/xos/rebuild.sh"]
fn slim_xos_fixture() {
    let src = std::env::var("XOS_SLIM_SRC").expect("XOS_SLIM_SRC must point at the full .ct");
    let dst = std::env::var("XOS_SLIM_DST").expect("XOS_SLIM_DST must be the output path");

    let bytes = std::fs::read(&src).expect("read source .ct");
    let mut reader = CtfsReader::from_bytes(bytes).expect("parse source .ct");

    let names: Vec<String> = reader.file_names().iter().map(|s| s.to_string()).collect();
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();
    for n in &names {
        let b = reader.read_file(n).expect("read internal file");
        files.push((n.clone(), b));
    }

    let rsp = files
        .iter()
        .find(|(n, _)| n == "cp0.regs")
        .and_then(|(_, b)| parse_cp0_regs_rsp(b));
    eprintln!("recorded RSP = {:?}", rsp.map(|x| format!("{x:#x}")));

    for (name, body) in files.iter_mut() {
        if name == "cp0.mem" {
            let regions = parse_cp0_mem(body);
            let mut kept = Vec::new();
            for (addr, data) in &regions {
                let end = addr + data.len() as u64;
                let contains_rsp = rsp.map(|s| *addr <= s && s < end).unwrap_or(false);
                // Linux mmaps PIE binaries into 0x55XX'XXXX'XXXX..; pick a
                // generous window that covers any ASLR slot for the
                // program text without sweeping in libc (0x7fXX..) or
                // the recorder's reserved region (0x7000..).
                let is_program_text = *addr >= 0x5500_0000_0000 && *addr < 0x6000_0000_0000;
                if is_program_text || contains_rsp {
                    kept.push((*addr, data.clone()));
                }
            }
            let total: u64 = kept.iter().map(|(_, d)| d.len() as u64).sum();
            eprintln!(
                "cp0.mem: regions {} -> {}, bytes -> {}",
                regions.len(),
                kept.len(),
                total
            );
            *body = pack_cp0_mem(&kept);
        }
    }

    let entries: Vec<(&str, &[u8])> = files.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
    write_minimal_ctfs(std::path::Path::new(&dst), &entries).expect("write slimmed .ct");

    let new_size = std::fs::metadata(&dst).expect("stat slimmed .ct").len();
    eprintln!("wrote {} ({} bytes)", dst, new_size);
}
