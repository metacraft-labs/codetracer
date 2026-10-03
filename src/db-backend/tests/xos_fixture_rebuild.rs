//! Helper integration test that regenerates the slimmed M-XOS-Fixture
//! `xos_hello.ct`. Gated behind `#[ignore]` so a normal `cargo test`
//! run does not touch the on-disk fixture; invoked explicitly by
//! `tests/fixtures/xos/rebuild.sh` after `ct_cli record --attach=premain`
//! produces the full-snapshot source `.ct`.
//!
//! Strategy: load the full-size source `.ct`, read the `cp0.mem` snapshot
//! payload (stored as the `cp0.mzd` + `cp0.mzi` chunked-compressed pair, or
//! raw when it fits in one block), parse it into `(address, bytes)` regions,
//! keep only the PIE program load segments (addresses in the
//! 0x550000000000..0x600000000000 range Linux mmaps PIE binaries into) plus
//! whichever region contains the recorded `cp0.regs.rsp` (= the `[stack]`
//! mapping). Re-encode the payload in the form a writer must use for its new
//! size and re-emit the container via `write_minimal_ctfs`, preserving every
//! other internal file byte-for-byte.
//!
//! Every step that could otherwise do nothing fails instead: a source with no
//! `cp0.mem` payload, no `cp0.regs`, no region holding RSP, no program region,
//! or nothing dropped all stop the regeneration, so the committed fixture can
//! never silently keep a full-size snapshot.

use db_backend::ctfs_trace_reader::ctfs_container::{CtfsReader, write_minimal_ctfs};
use db_backend::ctfs_trace_reader::snapshot_payload::{
    encode_snapshot_payload, read_snapshot_payload, snapshot_payload_names,
};

const CP0_MEM: &str = "cp0.mem";

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
        assert!(
            o + 16 + size as usize <= blob.len(),
            "cp0.mem is truncated at region @{addr:#x} (size {size}); refusing to slim a damaged snapshot"
        );
        out.push((addr, blob[o + 16..o + 16 + size as usize].to_vec()));
        o += 16 + size as usize;
    }
    assert_eq!(
        o,
        blob.len(),
        "cp0.mem has {} trailing bytes after its last region",
        blob.len() - o
    );
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

/// Environment entries that would publish the recording host's credentials
/// if they reached the committed fixture (the kept `[stack]` region carries
/// the guest's `envp` strings, and `guest.env` the whole environment).
const FORBIDDEN_MARKERS: [&[u8]; 5] = [
    b"AUTHORIZATION",
    b"GIT_CONFIG_VALUE",
    b"_TOKEN=",
    b"SECRET",
    b"PASSWORD",
];

fn assert_no_credentials(name: &str, bytes: &[u8]) {
    let upper: Vec<u8> = bytes.iter().map(|b| b.to_ascii_uppercase()).collect();
    for marker in FORBIDDEN_MARKERS {
        assert!(
            !upper.windows(marker.len()).any(|w| w == marker),
            "{name} contains `{}`: the recording inherited a credential-bearing environment; \
             record under the scrubbed environment rebuild.sh sets up",
            String::from_utf8_lossy(marker)
        );
    }
}

#[test]
#[ignore = "regeneration helper, invoked by tests/fixtures/xos/rebuild.sh"]
fn slim_xos_fixture() {
    let src = std::env::var("XOS_SLIM_SRC").expect("XOS_SLIM_SRC must point at the full .ct");
    let dst = std::env::var("XOS_SLIM_DST").expect("XOS_SLIM_DST must be the output path");

    let bytes = std::fs::read(&src).expect("read source .ct");
    let mut reader = CtfsReader::from_bytes(bytes).expect("parse source .ct");

    let full = read_snapshot_payload(&mut reader, CP0_MEM)
        .expect("read the cp0.mem snapshot payload")
        .unwrap_or_else(|| {
            panic!(
                "{src} has no cp0.mem snapshot payload (neither cp0.mem nor cp0.mzd + cp0.mzi): \
                 nothing to slim. Was it recorded with `--attach=premain`?"
            )
        });
    let regs = reader
        .read_file("cp0.regs")
        .unwrap_or_else(|e| panic!("{src} has no cp0.regs: {e}"));
    let rsp = parse_cp0_regs_rsp(&regs).expect("cp0.regs must hold the compact 144-byte register file");
    eprintln!("recorded RSP = {rsp:#x}");

    let regions = parse_cp0_mem(&full);
    let mut kept = Vec::new();
    let mut stack_kept = false;
    let mut program_kept = false;
    for (addr, data) in &regions {
        let end = addr + data.len() as u64;
        let contains_rsp = *addr <= rsp && rsp < end;
        // Linux mmaps PIE binaries into 0x55XX'XXXX'XXXX..; pick a
        // generous window that covers any ASLR slot for the
        // program text without sweeping in libc (0x7fXX..) or
        // the recorder's reserved region (0x7000..).
        let is_program_text = *addr >= 0x5500_0000_0000 && *addr < 0x6000_0000_0000;
        stack_kept |= contains_rsp;
        program_kept |= is_program_text;
        if is_program_text || contains_rsp {
            kept.push((*addr, data.clone()));
        }
    }
    assert!(stack_kept, "no cp0.mem region contains the recorded RSP {rsp:#x}");
    assert!(program_kept, "no cp0.mem region lies in the PIE program window");
    assert!(
        kept.len() < regions.len(),
        "slimming kept all {} cp0.mem regions; the fixture would not be slimmed",
        regions.len()
    );
    let slim = pack_cp0_mem(&kept);
    eprintln!(
        "cp0.mem: regions {} -> {}, bytes {} -> {}",
        regions.len(),
        kept.len(),
        full.len(),
        slim.len()
    );
    for (addr, data) in &kept {
        assert_no_credentials(&format!("cp0.mem region @{addr:#x}"), data);
    }

    let names = snapshot_payload_names(CP0_MEM).expect("cp0.mem names");
    let payload_members = [names.logical.as_str(), names.data.as_str(), names.index.as_str()];
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();
    let mut replaced = false;
    for n in reader.member_names_in_order().to_vec() {
        if payload_members.contains(&n.as_str()) {
            if !replaced {
                files.extend(encode_snapshot_payload(CP0_MEM, &slim).expect("encode the slimmed cp0.mem"));
                replaced = true;
            }
            continue;
        }
        let b = reader.read_file(&n).expect("read internal file");
        assert_no_credentials(&n, &b);
        files.push((n, b));
    }
    assert!(replaced, "the slimmed cp0.mem payload was not written back");

    let entries: Vec<(&str, &[u8])> = files.iter().map(|(n, b)| (n.as_str(), b.as_slice())).collect();
    write_minimal_ctfs(std::path::Path::new(&dst), &entries).expect("write slimmed .ct");

    let new_size = std::fs::metadata(&dst).expect("stat slimmed .ct").len();
    eprintln!("wrote {} ({} bytes)", dst, new_size);
}
