//! [`EmulatorReplaySession`] — `ReplaySession` impl backed by the Nim MCR
//! emulator (F5c-1 native, F5c-2 wasm32, F5c-3 trait-method bodies).
//!
//! ## Scope
//!
//! F5c-1 / F5c-2 stitched together the linking pipeline: the Nim emulator
//! is now part of the db-backend native and wasm32 builds. F5c-3
//! (this file) turns the placeholder trait impl into something the F5
//! browser-replay gateway can actually drive end-to-end — at minimum it
//! must surface ≥1 stack frame with a non-empty name and ≥1 variable
//! with a non-empty value so DAP `threads → stackTrace → scopes →
//! variables → setBreakpoints` succeeds.
//!
//! The implementation is **deliberately minimal** — it does not yet read
//! DWARF for true callstack unwinding nor evaluate complex expressions:
//! - The CTFS `meta.dat` block supplies program name, working directory,
//!   and source paths. We synthesise a single root frame from
//!   `meta.program` + `paths[0]` so the DAP client sees a meaningful
//!   stackTrace.
//! - Locals are projected from the register file. We surface every named
//!   x86_64 register as a `Variable` so the client always has at least
//!   one variable with a non-empty `rawValue`.
//! - Breakpoints are tracked in-process — `add_breakpoint` returns a
//!   `Breakpoint` whose handler shim sets `verified: true` in the DAP
//!   response (see `dap_handler::set_breakpoints` line 1294).
//!
//! Methods that F5's happy path may incidentally touch — `load_events`,
//! `load_step_events`, `load_return_value`, `run_to_entry`, `step` — are
//! implemented as graceful "empty / Default" returns so the DAP handler
//! never crashes on them when an emulator-backed session is in play.
//! Methods that F5 does NOT exercise at all (history pagination, the
//! various `jump_to`/`event_jump`/`callstack_jump`/`location_jump`/
//! `tracepoint_jump`/`toggle_breakpoint`/`evaluate_call_expression`)
//! deliberately stay as `todo!()` macros so they fail loudly if a future
//! milestone starts depending on them before the underlying machinery
//! (DWARF unwinding, snapshot-driven rewind, expression evaluator) is
//! wired up.
//!
//! ## Initialisation invariant
//!
//! Nim's exported procs require the runtime to be initialised exactly
//! once per process via `NimMain`. We guard that with [`std::sync::Once`]
//! so that constructing multiple sessions (e.g. during testing) is safe.
//! `mcrInit` itself is idempotent and is called on every `new()` so each
//! session starts from a clean emulator state.
//!
//! On wasm32 the runtime is single-threaded so the `Once` guard is
//! effectively trivial; we keep it for source-level symmetry with native.

use codetracer_trace_types::{StepId, TypeKind, TypeRecord, TypeSpecificInfo};
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::path::Path;
use std::sync::Once;

use crate::ctfs_trace_reader::ctfs_container::CtfsReader;
use crate::ctfs_trace_reader::meta_dat::{MetaDat, parse_meta_dat};
use crate::db::DbRecordEvent;
use crate::dwarf_index::{DwarfIndex, PcInfo};
use crate::emulator_ffi;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::ReplaySession;
use crate::stack_unwinder::{MCR_REG_COUNT, StackUnwinder};
use crate::task::{
    Action, Breakpoint, Call, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg,
    Location, NO_ADDRESS, NO_EVENT, NO_POSITION, ProgramEvent, RRTicks, VariableWithRecord,
};
use crate::value::ValueRecordWithType;

static NIM_RUNTIME_INIT: Once = Once::new();

/// Name of the CTFS internal file that carries the recorded binary plus its
/// DWARF sections (M-DWARF-3).
///
/// Conventions: lowercase, ≤12 chars, `.dat` extension to mirror the binary
/// `meta.dat` neighbour. We bundle the **full ELF** rather than only the
/// `.debug_*` sections so the replay backend can reuse the existing
/// `DwarfIndex::from_elf_bytes` parser without inventing a new
/// concat-of-sections format. The trade-off is ~1 MB of `.text`/`.data`
/// extra per trace; for the F5 inventory binary the full ELF is ~3 MB and
/// the DWARF subset is ~2 MB, so the overhead is acceptable. M-DWARF-4
/// will need the full binary anyway for `.eh_frame`-driven unwinding.
const BUNDLED_DEBUG_FILE: &str = "debug.dat";

/// CTFS file carrying the initial memory snapshot, written by the
/// recorder's `__libc_start_main` wrapper (see
/// `codetracer-native-recorder/ct_interpose/src/ct_interpose/full_snapshot.c`).
///
/// Wire format: a flat sequence of `(address: u64 LE, size: u64 LE, bytes[size])`
/// tuples — one per captured memory region. The recorder writes one region
/// per `/proc/self/maps` entry it deems "live" (skipping kernel-only ranges
/// and explicit `[vvar]/[vsyscall]` slots), capping the total at
/// `CT_FULL_SNAPSHOT_LIMIT_MB` (~256 MB by default). Decoding is documented
/// on the Nim side in `ct_replayer/src/ct_replayer/trace_loader.nim`'s
/// `readMemorySnapshot` proc.
const CP0_MEM_FILE: &str = "cp0.mem";

/// CTFS file carrying the initial register snapshot for checkpoint 0.
///
/// Wire format: a flat sequence of per-thread blobs
/// `(tid: u32 LE, reg_data_len: u32 LE, reg_data[reg_data_len])`. For
/// M-Checkpoint-Replay we only need the **first** thread's register file —
/// later milestones (multi-thread emulator priming) can revisit this.
///
/// The inner `reg_data` body is either:
/// * **144 bytes (18 × u64 LE)** — the compact layout written by the
///   LD_PRELOAD `__libc_start_main` wrapper. Order matches the
///   `mcrSetRegisters` argument list verbatim: rax, rbx, rcx, rdx, rsi,
///   rdi, rbp, rsp, r8, r9, r10, r11, r12, r13, r14, r15, rip, rflags.
/// * **216 bytes** — the kernel `user_regs_struct` ptrace layout (27 × u64
///   LE). Used by recorders that read state via `PTRACE_GETREGS`.
///
/// See `ct_emulator/src/ct_emulator/ctfs_bridge.nim`'s
/// `loadInitialStateFromTrace` for the canonical Nim-side decoder.
const CP0_REGS_FILE: &str = "cp0.regs";

/// Optional CTFS sidecar holding the recorded FS_BASE / GS_BASE.
///
/// Two little-endian `u64`s (`fsbase`, `gsbase`), 16 bytes total. The FS
/// base is not part of the standard 18-register `mcrSetRegisters` signature,
/// so M-Checkpoint-Replay does not install it directly — but reading the
/// file is harmless and we expose it for diagnostics. Future milestones can
/// wire a `mcrSetFsBase` shim once the emulator needs TLS access during
/// replay.
#[allow(dead_code)]
const CP0_FSBASE_FILE: &str = "cp0.fsbase";

/// CTFS sidecar carrying a snapshot of `/proc/self/maps` at cp0-capture
/// time.
///
/// Wire format: a UTF-8 text blob, one entry per line in the standard
/// kernel format:
///
/// ```text
/// <start>-<end> <perms> <offset> <dev>:<inode> <pathname>
/// ```
///
/// The replay backend consults this file at session construction to
/// recover the ASLR load base for the main executable. Without it, the
/// emulator's runtime PC (which the recorder captured verbatim from
/// `/proc/self/maps`-style addresses) does not match the static
/// addresses that DWARF encodes — every line resolves to the M-DWARF-2
/// placeholder of 1.
///
/// The file is optional. Traces produced before the M-Replay-PC-Rebase
/// milestone do not ship it and fall back to the un-rebased lookup,
/// which is still correct for static binaries with no ASLR (load base
/// equals static base).
const CP0_MAPS_FILE: &str = "cp0.maps";

/// Compact layout: 18 × u64 LE.
const CP0_REGS_COMPACT_LEN: usize = 18 * 8;

/// Full `user_regs_struct` layout: 27 × u64 LE.
const CP0_REGS_USER_STRUCT_LEN: usize = 27 * 8;

/// Per-thread blob header: `(tid: u32, reg_data_len: u32)`.
const CP0_REGS_THREAD_HEADER_LEN: usize = 8;

/// Diagnostics produced by [`EmulatorReplaySession::seed_emulator_from_cp0`].
///
/// Kept distinct from the FFI getters (`mcrGetPC`, `mcrGetRegister`) so
/// tests can assert on the *seeding action* rather than the emulator's
/// observable state — useful when a recorder writes a region the emulator
/// then refuses to expose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
struct SeedDiagnostics {
    /// Number of memory regions installed via `mcrLoadMemoryRegion`.
    regions: usize,
    /// Cumulative byte count across installed regions. May exceed 64 KB
    /// of `usize` granularity, so we use `u64`.
    total_bytes: u64,
    /// Whether `mcrSetRegisters` was invoked. False when `cp0.regs` was
    /// missing, empty, or unparseable.
    registers_installed: bool,
}

/// Decoded register file installed via `mcrSetRegisters`.
///
/// The field order matches the FFI argument order so the `install` call
/// site reads like a verbatim transcription of `mcrSetRegisters`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct InitialRegisters {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
}

/// Read a little-endian `u64` at `data[offset..offset + 8]`. Returns 0 if
/// the slice is too short — the caller already validated lengths so this
/// guard is defensive only.
fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    if offset + 8 > data.len() {
        return 0;
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(buf)
}

/// Read a little-endian `u32` at `data[offset..offset + 4]`.
fn read_u32_le(data: &[u8], offset: usize) -> u32 {
    if offset + 4 > data.len() {
        return 0;
    }
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&data[offset..offset + 4]);
    u32::from_le_bytes(buf)
}

/// Decode the first-thread register blob from a `cp0.regs` file body.
///
/// Returns `None` when the outer per-thread header is missing, the inner
/// length does not match a supported layout, or the inner bytes are
/// truncated. Callers fall back to leaving the register file zero-initialised
/// when this returns `None`.
fn decode_first_thread_registers(raw: &[u8]) -> Option<InitialRegisters> {
    if raw.len() < CP0_REGS_THREAD_HEADER_LEN {
        return None;
    }
    // First u32 is the recording tid (ignored); second is the length of
    // the per-thread register body that follows.
    let reg_data_len = read_u32_le(raw, 4) as usize;
    if reg_data_len == 0 || CP0_REGS_THREAD_HEADER_LEN + reg_data_len > raw.len() {
        return None;
    }
    let body = &raw[CP0_REGS_THREAD_HEADER_LEN..CP0_REGS_THREAD_HEADER_LEN + reg_data_len];

    if body.len() >= CP0_REGS_USER_STRUCT_LEN {
        // Full `user_regs_struct` ptrace order:
        //   r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi
        //   orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs
        // See https://elixir.bootlin.com/linux/latest/source/arch/x86/include/asm/user_64.h
        Some(InitialRegisters {
            r15: read_u64_le(body, 0),
            r14: read_u64_le(body, 8),
            r13: read_u64_le(body, 16),
            r12: read_u64_le(body, 24),
            rbp: read_u64_le(body, 32),
            rbx: read_u64_le(body, 40),
            r11: read_u64_le(body, 48),
            r10: read_u64_le(body, 56),
            r9: read_u64_le(body, 64),
            r8: read_u64_le(body, 72),
            rax: read_u64_le(body, 80),
            rcx: read_u64_le(body, 88),
            rdx: read_u64_le(body, 96),
            rsi: read_u64_le(body, 104),
            rdi: read_u64_le(body, 112),
            // orig_rax at 120 — skipped (no slot in the emulator's
            // register file).
            rip: read_u64_le(body, 128),
            // cs at 136 — skipped.
            rflags: read_u64_le(body, 144),
            rsp: read_u64_le(body, 152),
            // fs_base/gs_base at 160/168 — currently unused; future
            // milestone wires them through a dedicated FS-base setter.
        })
    } else if body.len() >= CP0_REGS_COMPACT_LEN {
        // Compact LD_PRELOAD layout — argument order of `mcrSetRegisters`.
        Some(InitialRegisters {
            rax: read_u64_le(body, 0),
            rbx: read_u64_le(body, 8),
            rcx: read_u64_le(body, 16),
            rdx: read_u64_le(body, 24),
            rsi: read_u64_le(body, 32),
            rdi: read_u64_le(body, 40),
            rbp: read_u64_le(body, 48),
            rsp: read_u64_le(body, 56),
            r8: read_u64_le(body, 64),
            r9: read_u64_le(body, 72),
            r10: read_u64_le(body, 80),
            r11: read_u64_le(body, 88),
            r12: read_u64_le(body, 96),
            r13: read_u64_le(body, 104),
            r14: read_u64_le(body, 112),
            r15: read_u64_le(body, 120),
            rip: read_u64_le(body, 128),
            rflags: read_u64_le(body, 136),
        })
    } else {
        None
    }
}

/// Iterate the `(address, length, bytes)` tuples in a `cp0.mem` blob and
/// install each region via `mcrLoadMemoryRegion`.
///
/// We deliberately slice into the caller's `Vec<u8>` rather than copying
/// each region into a fresh allocation — the recorder's snapshot can reach
/// ~256 MB on glibc-linked programs, and a copy would temporarily double
/// the memory footprint inside the WASM linear address space.
///
/// Truncated trailing data (caused by a partial recorder flush) is logged
/// and ignored; we never abort the seeding step over a corrupt tail since
/// the regions parsed so far are still correct and useful.
///
/// Returns the number of regions installed plus their cumulative size in
/// bytes, primarily for diagnostics and tests.
fn install_memory_regions(blob: &[u8]) -> (usize, u64) {
    let mut pos = 0usize;
    let mut regions: usize = 0;
    let mut total_bytes: u64 = 0;

    while pos + 16 <= blob.len() {
        let address = read_u64_le(blob, pos);
        let size = read_u64_le(blob, pos + 8) as usize;
        pos += 16;

        if size == 0 {
            // Recorder may emit zero-length placeholders for guard pages.
            continue;
        }
        if pos + size > blob.len() {
            // Truncated tail. Stop here rather than panic — the
            // already-installed regions are still authoritative.
            eprintln!(
                "warning: cp0.mem truncated at region @0x{address:x} (size={size}, \
                 remaining={remaining})",
                remaining = blob.len() - pos,
            );
            break;
        }

        let slice = &blob[pos..pos + size];
        // SAFETY: `slice.as_ptr()` lives for the duration of the FFI call;
        // the Nim side copies the bytes into its own region table before
        // returning. `size` fits in `c_int` for any single region the
        // recorder produces (regions are capped at the recorder's
        // per-region budget of 64 MB).
        let rc = unsafe { emulator_ffi::mcrLoadMemoryRegion(address, slice.as_ptr(), size as std::os::raw::c_int) };
        if rc != 0 {
            eprintln!(
                "warning: mcrLoadMemoryRegion failed (rc={rc}) for region @0x{address:x} \
                 size={size}; subsequent reads of this range will return 0",
            );
            // Continue installing later regions — a failure on one slot
            // shouldn't sabotage the rest of the snapshot.
        } else {
            regions += 1;
            total_bytes += size as u64;
        }
        pos += size;
    }

    (regions, total_bytes)
}

/// Install the decoded register file via `mcrSetRegisters`. Wrapping the
/// FFI call here keeps the unsafe surface in one place and lets unit tests
/// substitute a fake by swapping this helper for a test double.
fn install_registers(regs: &InitialRegisters) {
    // SAFETY: `mcrSetRegisters` is total — every argument is a plain u64
    // copied into the Nim-managed register file. It expects the runtime
    // to have been initialised, which `ensure_nim_runtime()` plus
    // `mcrInit()` (called by `new_from_ctfs_bytes`) have already done.
    unsafe {
        emulator_ffi::mcrSetRegisters(
            regs.rax,
            regs.rbx,
            regs.rcx,
            regs.rdx,
            regs.rsi,
            regs.rdi,
            regs.rbp,
            regs.rsp,
            regs.r8,
            regs.r9,
            regs.r10,
            regs.r11,
            regs.r12,
            regs.r13,
            regs.r14,
            regs.r15,
            regs.rip,
            regs.rflags,
        );
    }
}

/// One executable mapping entry parsed from `cp0.maps`.
///
/// Only entries with `x` (executable) permission for the main program
/// are interesting for PC rebasing — the recorder writes both read-only
/// and read/write segments to the maps file, but DWARF line addresses
/// only live in the `.text` (executable) segment.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ExecutableMapping {
    /// Runtime start address of the mapping (kernel-assigned).
    start: u64,
    /// File offset within `pathname` where this mapping begins. Used to
    /// pick the matching `PT_LOAD` segment in the ELF for accurate
    /// sub-page rebase math.
    file_offset: u64,
    /// Absolute path of the backing file. The recorder writes the path
    /// the kernel reported, which is what `meta.program` also points at,
    /// so a full-string equality check is reliable; we also fall back to
    /// a basename match for paranoia.
    pathname: String,
}

/// Parse a `cp0.maps` UTF-8 blob and return every `r-xp` (executable)
/// mapping whose pathname matches `program`. The kernel can split a
/// single ELF object across multiple `r-xp` mappings (rare on x86_64
/// but possible if the binary has non-contiguous executable segments),
/// so the caller chooses the lowest-start entry from the returned list.
///
/// Format reminder (per `Documentation/filesystems/proc.rst`):
/// ```text
/// <start>-<end> <perms> <offset> <dev>:<inode> <pathname>
/// ```
/// Whitespace separators are runs of spaces or tabs; the `<pathname>`
/// field is optional (anonymous mappings, `[heap]`, `[stack]`, etc.)
/// and we skip lines that lack one.
fn parse_executable_mappings(blob: &str, program: &str) -> Vec<ExecutableMapping> {
    let program_basename = program.rsplit(['/', '\\']).next().unwrap_or(program);
    let mut out = Vec::new();
    for line in blob.lines() {
        // Skip empty lines and any comment lines a future recorder might
        // emit; the kernel format itself has neither.
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            continue;
        }
        let mut parts = trimmed.split_ascii_whitespace();
        let Some(range) = parts.next() else { continue };
        let Some(perms) = parts.next() else { continue };
        let Some(offset_str) = parts.next() else { continue };
        // Skip dev (next) and inode (the one after) to land on pathname.
        if parts.next().is_none() {
            continue;
        }
        if parts.next().is_none() {
            continue;
        }
        // Re-join the remainder so paths containing whitespace (rare,
        // but legal on Linux) are preserved verbatim.
        let pathname_rest: String = parts.collect::<Vec<_>>().join(" ");
        if pathname_rest.is_empty() {
            continue;
        }
        if !perms.contains('x') {
            continue;
        }
        // Match either by full path (recorder writes absolute paths) or
        // by basename — same defensive contract as elsewhere in this
        // module where the recorder may report a canonicalised path
        // that differs from `meta.program`.
        let matches_program = pathname_rest == program
            || pathname_rest
                .rsplit(['/', '\\'])
                .next()
                .map(|b| b == program_basename)
                .unwrap_or(false);
        if !matches_program {
            continue;
        }
        // `start-end` — we only need the start.
        let Some((start_hex, _end_hex)) = range.split_once('-') else {
            continue;
        };
        let Ok(start) = u64::from_str_radix(start_hex, 16) else {
            continue;
        };
        let Ok(file_offset) = u64::from_str_radix(offset_str, 16) else {
            continue;
        };
        out.push(ExecutableMapping {
            start,
            file_offset,
            pathname: pathname_rest,
        });
    }
    out
}

/// Compute the PC rebase offset for the main executable.
///
/// The rebase offset is `mapping.start - segment.p_vaddr` where the
/// `segment` is the ELF `PT_LOAD` whose `p_offset` matches the mapping's
/// `<offset>` field. That formula produces the correct delta even when
/// the first executable PT_LOAD has a non-zero `p_vaddr` (e.g. PIE
/// binaries linked with `--no-rosegment` whose `.text` starts at
/// `p_vaddr == 0x1000`):
///
/// ```text
/// runtime_pc - rebase_offset
///   == runtime_pc - (mapping.start - p_vaddr)
///   == (mapping.start + Δ) - mapping.start + p_vaddr
///   == p_vaddr + Δ
///   == static_pc
/// ```
///
/// If no matching segment is found we fall back to `mapping.start`,
/// which is correct whenever `p_vaddr == 0` (the common case for
/// PIE binaries that don't carry a rosegment).
fn compute_pc_rebase(elf_bytes: &[u8], mapping: &ExecutableMapping) -> u64 {
    // `object` is already a dependency from M-DWARF-1; reusing its
    // segment iterator keeps us out of hand-rolling ELF parsing.
    use object::{Object, ObjectSegment};
    match object::File::parse(elf_bytes) {
        Ok(file) => {
            for segment in file.segments() {
                // `file_range()` returns the segment's `(p_offset, p_filesz)`.
                let (seg_offset, _seg_filesz) = segment.file_range();
                if seg_offset == mapping.file_offset {
                    return mapping.start.wrapping_sub(segment.address());
                }
            }
            // Fallback: no matching segment offset (corrupt ELF, or
            // recorder wrote a non-load page-aligned offset). Assume the
            // mapping was placed at the segment's virtual base, which is
            // correct for vanilla PIE builds where `p_vaddr == 0`.
            mapping.start
        }
        Err(_) => mapping.start,
    }
}

/// Read `cp0.maps` from `ctfs` and compute the runtime → static PC
/// rebase offset for `program`. Returns `None` when:
///
/// * `cp0.maps` is absent (older traces).
/// * `program` is empty (no meta.program to match against).
/// * No executable mapping in the file matches `program`.
///
/// The returned offset is what `build_location` subtracts from the raw
/// PC before consulting the DWARF index. `elf_bytes` is the bundled
/// `debug.dat` blob; when absent we still produce a useful rebase by
/// falling back to `mapping.start` (correct when `p_vaddr == 0`, which
/// covers most PIE binaries).
fn compute_pc_rebase_from_cp0_maps(ctfs: &mut CtfsReader, program: &str, elf_bytes: Option<&[u8]>) -> Option<u64> {
    if program.is_empty() {
        return None;
    }
    let maps_bytes = match ctfs.read_file(CP0_MAPS_FILE) {
        Ok(bytes) if !bytes.is_empty() => bytes,
        _ => return None,
    };
    // The recorder writes UTF-8; non-UTF-8 paths are a recorder bug we
    // refuse to paper over silently here.
    let blob = match std::str::from_utf8(&maps_bytes) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("warning: cp0.maps is not valid UTF-8 ({e}); skipping PC rebase");
            return None;
        }
    };
    let mut mappings = parse_executable_mappings(blob, program);
    if mappings.is_empty() {
        eprintln!(
            "warning: cp0.maps did not list an executable mapping for program `{program}`; \
             PC rebase disabled (DWARF lookups will use the raw runtime PC)"
        );
        return None;
    }
    // The kernel may place multiple `r-xp` mappings for the same object
    // (uncommon on x86_64 but legal — see Linux's `mmap_region` /
    // segment-splitting paths). The lowest start address is the
    // canonical load base because it sits on the first executable
    // PT_LOAD; later mappings cover trailing executable pages whose
    // `p_offset` is already non-zero and whose rebase math is identical.
    mappings.sort_by_key(|m| m.start);
    let mapping = &mappings[0];
    let offset = match elf_bytes {
        Some(bytes) if !bytes.is_empty() => compute_pc_rebase(bytes, mapping),
        // No bundled ELF — fall back to the page-aligned base. This
        // matches the common PIE case where `p_vaddr == 0` for the
        // first PT_LOAD; non-PIE binaries with rosegments would need
        // the ELF to compute the correct delta.
        _ => mapping.start,
    };
    Some(offset)
}

/// Initialise the Nim runtime exactly once per process.
fn ensure_nim_runtime() {
    NIM_RUNTIME_INIT.call_once(|| {
        // SAFETY: NimMain is the standard Nim runtime entry point. It is
        // safe to call from a single thread once per process; the Once
        // guard guarantees that exclusivity.
        unsafe { emulator_ffi::NimMain() };
    });
}

/// Names of the 18 registers exposed via `mcrGetRegister(idx)`. The
/// order matches the `index` table documented in `emulator_ffi.rs`
/// (`mcrGetRegister`): 0..=15 are the GPRs, 16 is `rip`, 17 is `rflags`.
const REGISTER_NAMES: [&str; 18] = [
    "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "rip", "rflags",
];

/// Returned by [`EmulatorReplaySession::new_from_ctfs_bytes`] when the
/// supplied byte slice can't be parsed as an MCR-bearing CTFS container.
///
/// We surface a single string-form error rather than a typed enum
/// because every call site treats CTFS failures the same way: log and
/// fall through to a non-MCR reader.
fn ctfs_error(msg: impl Into<String>) -> Box<dyn Error> {
    msg.into().into()
}

/// M20 — attempt to load the M19 origin-metadata extension namespaces
/// (`originmeta.tc` + `source_exprs.tc`) from a CTFS container. Returns
/// the parsed [`OriginMetadataDecoder`] on success; `None` when either
/// file is absent or malformed.
///
/// The reader is deliberately tolerant: a missing `originmeta.tc` (the
/// common case today, since the recorder-side indexer integration is a
/// follow-on milestone) simply produces a Mode-2 trace (omniscient log
/// only) — origin queries still flow through the M20 algorithm but the
/// classifier-fabricated fallback is invoked per hop.
///
/// Malformed bytes are logged via `eprintln!` and the decoder is left
/// as `None` so the rest of the session continues to load cleanly.
fn load_origin_metadata_decoder(
    ctfs: &mut crate::ctfs_trace_reader::ctfs_container::CtfsReader,
) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
    let originmeta_bytes = match ctfs.read_file(crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE) {
        Ok(bytes) if !bytes.is_empty() => bytes,
        _ => return None,
    };
    let source_exprs_bytes = match ctfs.read_file(crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE) {
        Ok(bytes) if !bytes.is_empty() => bytes,
        _ => {
            eprintln!(
                "warning: EmulatorReplaySession found `{}` without `{}`; metadata decoder disabled",
                crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE,
                crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE
            );
            return None;
        }
    };
    match crate::origin_metadata_indexer::OriginMetadataDecoder::load(&originmeta_bytes, &source_exprs_bytes) {
        Some(decoder) => Some(decoder),
        None => {
            eprintln!(
                "warning: EmulatorReplaySession could not parse `{}` / `{}`; metadata decoder disabled",
                crate::origin_metadata_indexer::CTFS_ORIGINMETA_FILE,
                crate::origin_metadata_indexer::CTFS_SOURCE_EXPRS_FILE
            );
            None
        }
    }
}

/// `ReplaySession` backed by the Nim MCR emulator.
///
/// Construct with [`new`](Self::new) for an empty emulator (used by the
/// F5c-1 bring-up smoke test) or with
/// [`new_from_ctfs_bytes`](Self::new_from_ctfs_bytes) to populate the
/// session from a `.ct` container with `FLAG_HAS_MCR_FIELDS` set.
pub struct EmulatorReplaySession {
    /// Parsed `meta.dat` for the active trace.
    ///
    /// Even an empty session keeps a default `MetaDat` so callbacks that
    /// reach for the program name or path list never have to special-case
    /// `Option::None`. The default has `version = 0` which would never
    /// match a real serialised header — useful as a sentinel in tests.
    meta: MetaDat,
    /// In-process breakpoint table: maps `(path, line)` to one or more
    /// allocated [`Breakpoint`] records. We track the structure rather
    /// than just IDs so that `delete_breakpoint` can locate the entry
    /// efficiently and `delete_breakpoints` can clear the lot.
    breakpoints: HashMap<(String, i64), Vec<Breakpoint>>,
    /// Monotonic next breakpoint id. Re-assigned on `delete_breakpoints`
    /// so a fresh session starts from 1, matching the
    /// `MaterializedReplaySession` convention.
    next_breakpoint_id: i64,
    /// Whether breakpoints currently fire. `disable_breakpoints` flips
    /// this to `false` without removing entries.
    breakpoints_enabled: bool,
    /// Cached step id returned by `current_step_id`. The emulator's own
    /// step counter is the source of truth (`mcrGetStepCounter`); we
    /// keep this field so unit tests can deterministically inspect the
    /// last reported value without having to dispatch to FFI.
    current_step_id: StepId,
    /// Parsed DWARF index for the recorded program, when the `.ct`
    /// container bundled a `debug.dat` blob (M-DWARF-3). `None` when:
    ///
    /// * The recorder did not include the binary (e.g. stripped target).
    /// * The bundled bytes failed to parse as an ELF (corrupt bundle).
    ///
    /// When `None`, the session falls back to the M-DWARF-2 behaviour
    /// where `build_location` synthesises `(meta.paths[0], 1)`.
    dwarf: Option<DwarfIndex>,
    /// PC rebase offset for the main executable: the value to subtract
    /// from the runtime PC before consulting the bundled DWARF index.
    ///
    /// At record time the kernel chooses an ASLR load address for the
    /// program (e.g. `0x5580aae44000`) and instructions execute at
    /// those runtime addresses — that's what the recorder captures in
    /// `cp0.regs.rip`. DWARF, however, encodes the addresses the
    /// compiler emitted in the binary's static address space. We
    /// recover the offset by reading `cp0.maps`, finding the executable
    /// (`r-xp`) mapping that matches `meta.program`, and combining it
    /// with the matching `PT_LOAD` segment's `p_vaddr` so the math is
    /// correct even when the first executable segment has a non-zero
    /// virtual address (which it does for PIE binaries: the segment's
    /// `p_vaddr` is the *offset* of `.text` within the image, not 0).
    ///
    /// `None` means "no rebase" — either because `cp0.maps` is absent
    /// (older traces) or because the program path could not be located
    /// in the maps blob. In both cases `build_location` queries DWARF
    /// with the raw PC, which is correct for static / non-PIE builds.
    pc_rebase: Option<u64>,
    /// CFI walker for multi-frame stack unwinding (M-DWARF-4). Built
    /// from the same `debug.dat` ELF bytes as [`Self::dwarf`]. `None`
    /// when no bundle was present or the ELF failed to parse — the
    /// session then surfaces only the single synthesised root frame
    /// (the pre-M-DWARF-4 contract).
    stack_unwinder: Option<StackUnwinder>,
    /// Set of **static** PCs at which `step(Continue, …)` must halt.
    ///
    /// Populated whenever `add_breakpoint` is called: the DwarfIndex
    /// reverse lookup turns `(path, line)` into a list of PCs, all of
    /// which are added to this set. The set is cleared by
    /// `delete_breakpoints` and the per-`(path, line)` slice is removed
    /// (or attempted to be removed) on `delete_breakpoint`. Membership
    /// is checked once per emulator instruction during `Continue`, so
    /// `HashSet` (O(1) lookup) is the right shape — even at 10,000
    /// breakpoints the per-instruction overhead stays in the
    /// nanoseconds.
    ///
    /// Stored as *static* PCs (the addresses DWARF encodes); the
    /// runtime PC from `mcrGetPC` is rebased before lookup so PIE
    /// traces still hit their breakpoints after ASLR shifts.
    breakpoint_static_pcs: HashSet<u64>,
    /// M18 — whether the trace's CTFS container declared at least one
    /// of `memwrites.tc` / `linehits.tc` (the omniscient DB
    /// namespaces). When `true`, [`Self::omniscient_db`] returns the
    /// FFI-backed [`crate::omniscient_db::FfiOmniscientDb`] handle so
    /// origin queries (M20) and `db.rs::load_history` can consult the
    /// recorded write log. `false` for legacy traces; callers fall
    /// back to per-backend paths.
    omniscient_present: bool,
    /// FFI handle to the Nim-side omniscient store. Zero-cost: the
    /// store itself lives in Nim-global state and the handle is just
    /// a routing strut to it. Held by value so trait pointers stay
    /// valid as long as the session is alive. The
    /// [`crate::omniscient_db::OmniscientDb`] trait is also imported
    /// at module top-level so `is_present()` resolves here.
    omniscient_handle: crate::omniscient_db::FfiOmniscientDb,
    /// M20 — origin-metadata decoder produced by the M19 indexer (or
    /// loaded from the CTFS `originmeta.tc` + `source_exprs.tc`
    /// namespaces). `None` when the trace ships only the M18
    /// omniscient log (Mode 2); `Some(_)` when both the log and the
    /// metadata extension are present (Mode 3).
    ///
    /// The dispatcher in
    /// [`crate::dap_handler::Handler::emulator_origin_chain`] reads
    /// this through [`Self::origin_metadata_decoder`] to decide
    /// whether to route to the M20 omniscient tier (metadata-driven,
    /// no per-hop classifier) or the M17 hybrid fallback.
    origin_metadata_decoder: Option<crate::origin_metadata_indexer::OriginMetadataDecoder>,
}

use crate::omniscient_db::OmniscientDb as _;

/// Hard cap on the number of frames returned by `load_callstack`.
///
/// Protects against runaway unwind loops over a cyclic or corrupted
/// stack — at 64 frames every realistic application call chain still
/// fits comfortably (a 64-deep async stack is already extreme), while
/// keeping the worst-case CPU and memory cost bounded.
const MAX_CALLSTACK_FRAMES: usize = 64;

/// Manual `Debug` impl: [`DwarfIndex`] wraps an `addr2line::Context` that
/// does not implement `Debug`, and the parsed sections aren't useful in
/// log output anyway. Surfacing `Some/None` plus a coarse source-file
/// count is enough for diagnostics.
impl std::fmt::Debug for EmulatorReplaySession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EmulatorReplaySession")
            .field("meta", &self.meta)
            .field("breakpoints", &self.breakpoints)
            .field("next_breakpoint_id", &self.next_breakpoint_id)
            .field("breakpoints_enabled", &self.breakpoints_enabled)
            .field("current_step_id", &self.current_step_id)
            .field(
                "dwarf",
                &self
                    .dwarf
                    .as_ref()
                    .map(|d| format!("DwarfIndex({} source files)", d.source_file_count())),
            )
            .field("pc_rebase", &self.pc_rebase)
            .field("stack_unwinder", &self.stack_unwinder.as_ref().map(|_| "<present>"))
            .field("breakpoint_static_pcs_count", &self.breakpoint_static_pcs.len())
            .field("omniscient_present", &self.omniscient_present)
            .finish()
    }
}

/// Default empty type record for synthesised values.
///
/// Used wherever we surface raw scalars (e.g. registers) that don't have
/// a richer DWARF type available — the frontend only needs `kind` /
/// `lang_type` to be present for the value to render.
fn type_record(kind: TypeKind, lang_type: &str) -> TypeRecord {
    TypeRecord {
        kind,
        lang_type: lang_type.to_string(),
        specific_info: TypeSpecificInfo::None,
    }
}

impl EmulatorReplaySession {
    /// Create an empty session backed by a freshly-initialised Nim
    /// emulator. No memory or registers are loaded — primarily useful
    /// for unit tests that exercise the FFI bring-up surface.
    ///
    /// The first call also initialises the Nim runtime via `NimMain`.
    pub fn new() -> Self {
        ensure_nim_runtime();
        // SAFETY: mcrInit is safe to call after NimMain has run and is
        // idempotent — it merely resets the emulator's globals.
        unsafe { emulator_ffi::mcrInit() };
        Self {
            meta: MetaDat {
                version: 0,
                flags: 0,
                // Default-empty session before any trace is loaded; the
                // real recording_id is populated by `load_ctfs`.  An
                // empty string here intentionally fails the
                // `is_canonical_uuid_v7` check should anything try to
                // parse this as a real meta.dat payload.
                recording_id: String::new(),
                program: String::new(),
                args: Vec::new(),
                workdir: String::new(),
                recorder_id: String::new(),
                paths: Vec::new(),
                mcr: None,
                replay_launch: None,
                layout_snapshot: None,
                filter_provenance: Vec::new(),
                has_filter_provenance: false,
            },
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf: None,
            pc_rebase: None,
            stack_unwinder: None,
            breakpoint_static_pcs: HashSet::new(),
            // M18 — empty sessions never ship a `memwrites.tc` /
            // `linehits.tc` namespace; the handle stays inert until
            // the integration test driver or the recorder loader
            // pushes data into it.
            omniscient_present: false,
            omniscient_handle: crate::omniscient_db::FfiOmniscientDb::new(),
            // M20 — empty sessions never ship `originmeta.tc`; the
            // decoder slot stays empty until the test driver installs
            // one via [`Self::install_origin_metadata_decoder`] or
            // the CTFS loader populates it.
            origin_metadata_decoder: None,
        }
    }

    /// M20 — install an [`crate::origin_metadata_indexer::OriginMetadataDecoder`]
    /// onto the session. The M20 dispatcher consults this through
    /// [`Self::origin_metadata_decoder`] to decide whether to take the
    /// metadata-driven §6.8.2 path (when present) or the §6.5
    /// write-log + classifier fallback (when absent).
    ///
    /// Production callers populate this from the CTFS namespaces at
    /// `new_from_ctfs_bytes` time; the integration tests install a
    /// synthetic decoder produced via the M19 indexer so the algorithm
    /// is exercisable end-to-end without a recorded trace.
    pub fn install_origin_metadata_decoder(&mut self, decoder: crate::origin_metadata_indexer::OriginMetadataDecoder) {
        self.origin_metadata_decoder = Some(decoder);
    }

    /// M20 — read-only accessor for the installed origin-metadata
    /// decoder. `None` when the trace's CTFS container has no
    /// `originmeta.tc` namespace (Mode 1 or Mode 2). The dispatcher
    /// reads this together with [`Self::omniscient_db`] (the M18
    /// trait surface) to pick the highest-quality available tier.
    pub fn origin_metadata_decoder(&self) -> Option<&crate::origin_metadata_indexer::OriginMetadataDecoder> {
        self.origin_metadata_decoder.as_ref()
    }

    /// Create a session from raw CTFS bytes (typically the in-memory
    /// VFS slot for the WASM build, or `std::fs::read("trace.ct")` on
    /// native).
    ///
    /// Currently the CTFS payload only seeds the source-map side of
    /// the session — register state and memory regions stay empty
    /// because no recorder yet emits a checkpoint stream the
    /// db-backend can consume directly. The path is wired up now so
    /// that future checkpoint-decode support drops into one place.
    ///
    /// Returns `Err` if the bytes are not a valid CTFS container, if
    /// `meta.dat` is missing or unparseable, or if the trace does not
    /// declare `FLAG_HAS_MCR_FIELDS` (callers should route those to
    /// `MaterializedReplaySession` instead).
    pub fn new_from_ctfs_bytes(bytes: Vec<u8>) -> Result<Self, Box<dyn Error>> {
        let mut ctfs = CtfsReader::from_bytes(bytes).map_err(|e| ctfs_error(format!("CTFS parse failed: {e}")))?;

        // CTFS containers must carry a binary `meta.dat`. Legacy
        // `meta.json` sidecars are no longer supported (M-REC era
        // retirement of legacy formats).
        let meta_bytes = ctfs
            .read_file("meta.dat")
            .map_err(|e| ctfs_error(format!("CTFS container has no meta.dat: {e}")))?;
        let meta = parse_meta_dat(&meta_bytes).map_err(|e| ctfs_error(format!("meta.dat parse failed: {e}")))?;

        if meta.mcr.is_none() {
            return Err(ctfs_error(
                "EmulatorReplaySession requires an MCR trace (meta.dat with FLAG_HAS_MCR_FIELDS)",
            ));
        }

        // M-DWARF-3: look for the recorder-bundled binary (`debug.dat`).
        // Missing is fine — older traces predate the bundling step, and
        // stripped binaries skip the bundle on the recorder side. Parse
        // failures are tolerated identically so a corrupt bundle never
        // prevents the session from coming up at all; the session just
        // falls back to the M-DWARF-2 placeholder location.
        //
        // We hold on to `elf_bytes` past the DWARF index construction
        // because M-Replay-PC-Rebase also needs the parsed ELF segments
        // to compute the correct sub-page rebase offset.
        let elf_bytes: Option<Vec<u8>> = match ctfs.read_file(BUNDLED_DEBUG_FILE) {
            Ok(bytes) if !bytes.is_empty() => Some(bytes),
            // Either the file isn't present (older trace) or it's empty.
            _ => None,
        };
        let dwarf = match elf_bytes.as_deref() {
            Some(bytes) => match DwarfIndex::from_elf_bytes(bytes) {
                Ok(index) => Some(index),
                Err(e) => {
                    eprintln!(
                        "warning: EmulatorReplaySession could not parse bundled `{BUNDLED_DEBUG_FILE}` \
                         ({e}); falling back to placeholder line numbers"
                    );
                    None
                }
            },
            // No bundled ELF: silent fallback to the M-DWARF-2 contract.
            None => None,
        };

        // M-DWARF-4: build the CFI walker from the same ELF bytes so
        // `load_callstack` can produce multi-frame stack traces. A
        // parse failure here is non-fatal — we fall back to the
        // single-frame synthesis path. The unwinder shares no state
        // with the DWARF line index; they are independent consumers
        // of the same ELF.
        let stack_unwinder = match elf_bytes.as_deref() {
            Some(bytes) => match StackUnwinder::from_elf_bytes(bytes) {
                Ok(unwinder) => Some(unwinder),
                Err(e) => {
                    eprintln!(
                        "warning: EmulatorReplaySession could not build a CFI unwinder from \
                         `{BUNDLED_DEBUG_FILE}` ({e}); load_callstack will surface only the \
                         current frame"
                    );
                    None
                }
            },
            None => None,
        };

        // M-Replay-PC-Rebase: read the kernel's `/proc/self/maps`
        // snapshot from `cp0.maps` and compute the runtime → static PC
        // delta for the main executable. This is what turns the
        // recorded ASLR-shifted RIP (e.g. `0x5580aaec3d69`) into the
        // static address DWARF actually carries for that instruction.
        //
        // The lookup is best-effort: if `cp0.maps` is missing, the
        // program isn't found in it, or the ELF parse fails, we leave
        // `pc_rebase = None` and let the resolver query DWARF with the
        // raw PC. That preserves the M-DWARF-3 behaviour for the small
        // set of statically-linked / non-PIE traces where no rebase is
        // needed.
        let pc_rebase = compute_pc_rebase_from_cp0_maps(&mut ctfs, &meta.program, elf_bytes.as_deref());

        ensure_nim_runtime();
        // SAFETY: see `new()`.
        unsafe { emulator_ffi::mcrInit() };

        // M-Checkpoint-Replay: seed the emulator from the recorded cp0
        // checkpoint. We deliberately install memory FIRST and registers
        // SECOND so any future code that triggers PC validation against
        // installed regions (a defensive consistency check in some
        // emulator builds) sees a populated address space when RIP lands.
        //
        // Both files are *optional* — a recorder that didn't reach the
        // `__libc_start_main` wrapper (early-crash, stripped libc) won't
        // have produced them. In that case we leave the emulator in its
        // post-`mcrInit` zero state and rely on the M-DWARF-2 fallback
        // for `build_location`. This mirrors the recorder-side "best
        // effort" snapshotting contract.
        Self::seed_emulator_from_cp0(&mut ctfs);

        // M18 — surface the presence of the omniscient DB namespaces.
        // The Nim recorder writes `memwrites.tc` / `linehits.tc` per
        // `MCR-Omniscient-DB-Algorithms.md` §1; detecting either of
        // them is sufficient to signal that the trace supports the
        // omniscient query path. We do NOT eagerly stream the
        // namespace bytes into the Nim shim: the production payload
        // can be hundreds of MB. Lazy load lands when the first
        // `OmniscientDb` query trips the lazy interval analyser
        // (M18 deliverable §5).
        let omniscient_present = crate::omniscient_db::ctfs_has_omniscient_namespaces(|name| ctfs.has_file(name));

        Ok(Self {
            meta,
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf,
            pc_rebase,
            stack_unwinder,
            breakpoint_static_pcs: HashSet::new(),
            omniscient_present,
            omniscient_handle: crate::omniscient_db::FfiOmniscientDb::new(),
            // M20 — attempt to load the `originmeta.tc` +
            // `source_exprs.tc` CTFS namespaces. When both are present
            // and parse cleanly the decoder routes origin queries
            // through the metadata-driven §6.8.2 path. Missing or
            // malformed namespaces fall back to the M18-only path
            // (Mode 2 — write log + classifier at query time).
            origin_metadata_decoder: load_origin_metadata_decoder(&mut ctfs),
        })
    }

    /// Read `cp0.mem` + `cp0.regs` from a CTFS reader and install them on
    /// the active emulator instance.
    ///
    /// Returns the diagnostics tuple `(regions_installed, total_bytes,
    /// registers_installed)` so unit tests can observe the seeding
    /// outcome without dispatching to the FFI getters.
    fn seed_emulator_from_cp0(ctfs: &mut CtfsReader) -> SeedDiagnostics {
        // ---- cp0.mem -----------------------------------------------------
        //
        // Even a 90 MB blob is decoded by streaming through it tuple-by-tuple
        // (`install_memory_regions` slices into `mem_bytes` without copying).
        // The blob is dropped as soon as `seed_emulator_from_cp0` returns so
        // the peak transient memory cost is one copy of cp0.mem — not two.
        let (regions, total_bytes) = match ctfs.read_file(CP0_MEM_FILE) {
            Ok(mem_bytes) if !mem_bytes.is_empty() => install_memory_regions(&mem_bytes),
            // Missing or empty is a silent fallback — older traces lack
            // the cp0 stream entirely.
            _ => (0, 0u64),
        };

        // ---- cp0.regs ----------------------------------------------------
        //
        // We only need the first thread's blob for M-Checkpoint-Replay; the
        // emulator's `mcrSetRegisters` is a single-thread surface. Future
        // multi-thread work will iterate per-thread blobs and dispatch to a
        // forthcoming `mcrSetThreadRegisters` shim.
        let registers_installed = match ctfs.read_file(CP0_REGS_FILE) {
            Ok(reg_bytes) if !reg_bytes.is_empty() => match decode_first_thread_registers(&reg_bytes) {
                Some(regs) => {
                    install_registers(&regs);
                    true
                }
                None => {
                    eprintln!(
                        "warning: cp0.regs present but unparseable ({} bytes); leaving \
                         emulator registers zero-initialised",
                        reg_bytes.len(),
                    );
                    false
                }
            },
            _ => false,
        };

        SeedDiagnostics {
            regions,
            total_bytes,
            registers_installed,
        }
    }

    /// Allocate and store a new breakpoint record under `(path, line)`.
    ///
    /// The returned record carries `column = None`; the trait-level
    /// `add_breakpoint` overlays the actual column (when the DAP client
    /// requested one) onto the returned record before handing it back.
    fn allocate_breakpoint(&mut self, path: &str, line: i64) -> Breakpoint {
        let breakpoint = Breakpoint {
            id: self.next_breakpoint_id,
            enabled: self.breakpoints_enabled,
            column: None,
        };
        self.next_breakpoint_id += 1;
        self.breakpoints
            .entry((path.to_string(), line))
            .or_default()
            .push(breakpoint.clone());
        breakpoint
    }

    /// Resolve the active source path for synthesised locations.
    ///
    /// Prefers the first entry in `meta.paths` (the writer convention
    /// puts the program's primary source first); falls back to
    /// `meta.program` so we never emit an empty `Location.path`.
    fn primary_path(&self) -> String {
        if let Some(first) = self.meta.paths.first()
            && !first.is_empty()
        {
            return first.clone();
        }
        if !self.meta.program.is_empty() {
            return self.meta.program.clone();
        }
        "<unknown>".to_string()
    }

    /// Synthesise a function name for the root frame.
    ///
    /// We don't yet have DWARF, so the program basename is the best
    /// signal available. The F5 acceptance check only requires the name
    /// to be non-empty, so this is sufficient.
    fn root_function_name(&self) -> String {
        if !self.meta.program.is_empty() {
            // Strip any directory prefix; tolerate both Unix and Windows
            // separators so traces recorded on either host render the
            // same way.
            let mut name: &str = &self.meta.program;
            if let Some(idx) = name.rfind(['/', '\\']) {
                name = &name[idx + 1..];
            }
            if !name.is_empty() {
                return name.to_string();
            }
        }
        "<entry>".to_string()
    }

    /// Resolve the current emulator PC against the bundled DWARF, if any.
    ///
    /// Returns `None` when:
    ///
    /// * No DWARF was bundled (older trace or stripped binary).
    /// * The PC falls outside every CU range (libc, JIT page, padding).
    ///
    /// The returned `PcInfo.file` is the raw DWARF path; the caller is
    /// responsible for deciding whether to override `meta.paths[0]` with
    /// it. We deliberately don't canonicalise here — the recorder side
    /// embeds source paths exactly as the compiler emitted them, so the
    /// DWARF path matches the meta path for the same compilation unit.
    fn dwarf_pc_info(&self) -> Option<PcInfo> {
        let dwarf = self.dwarf.as_ref()?;
        // SAFETY: same rationale as `build_location` — the emulator FFI
        // getter reads from Nim-managed globals seeded by `mcrInit`.
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        // M-Replay-PC-Rebase: subtract the load-base delta so the DWARF
        // index — which speaks the binary's static address space — sees
        // the correct address. Without this step the runtime PC for any
        // PIE binary falls outside every CU range and `resolve_pc`
        // returns `None`, dropping the location back to the M-DWARF-2
        // placeholder.
        //
        // `wrapping_sub` so we never panic on a degenerate offset
        // (e.g. a misparsed cp0.maps that produces an offset > pc); a
        // wrapped address simply won't resolve and we fall through to
        // the placeholder, which is the same outcome as `None` here.
        let static_pc = match self.pc_rebase {
            Some(offset) => pc.wrapping_sub(offset),
            None => pc,
        };
        dwarf.resolve_pc(static_pc)
    }

    /// Resolve a specific (runtime, static) PC pair against the bundled
    /// DWARF. Used by the multi-frame [`load_callstack`] path so each
    /// recovered frame can carry its own (file, line, function).
    fn dwarf_pc_info_for(&self, pc_static: u64) -> Option<PcInfo> {
        self.dwarf.as_ref()?.resolve_pc(pc_static)
    }

    /// Build a [`Location`] for a frame at `(pc, pc_static)`. Mirrors
    /// the per-frame portion of [`build_location`] but is parameterised
    /// over the PC so it can be applied to each frame the CFI walker
    /// recovers. The function name falls back to
    /// [`root_function_name`] when DWARF carries no `DW_AT_name` for
    /// the function — preserving the F5 "non-empty name" acceptance bar.
    fn build_location_for(&self, pc: u64, pc_static: u64) -> Location {
        let mut path = self.primary_path();
        let mut line: i64 = 1;
        let mut function_name = self.root_function_name();

        if let Some(info) = self.dwarf_pc_info_for(pc_static) {
            let dwarf_path = info.file.to_string_lossy().into_owned();
            if !dwarf_path.is_empty() {
                path = dwarf_path;
            }
            line = info.line as i64;
            // Prefer the DWARF-supplied function name when present —
            // the per-frame names are what makes `inventory_service ->
            // runForever -> _start` legible in DAP stackTrace output.
            if let Some(name) = info.function
                && !name.is_empty()
            {
                function_name = name;
            }
        }

        Location {
            path: path.clone(),
            line,
            function_name: function_name.clone(),
            high_level_path: path.clone(),
            high_level_line: line,
            high_level_function_name: function_name,
            low_level_path: path,
            low_level_line: line,
            rr_ticks: RRTicks(self.current_step_id.0),
            function_first: NO_POSITION,
            function_last: NO_POSITION,
            event: NO_EVENT,
            expression: String::new(),
            offset: pc as i64,
            error: false,
            callstack_depth: 0,
            originating_instruction_address: pc as i64,
            key: String::new(),
            global_call_key: String::new(),
            expansion_id: -1,
            expansion_first_line: -1,
            expansion_last_line: -1,
            missing_path: self.meta.paths.is_empty() && self.meta.program.is_empty(),
            ..Location::default()
        }
    }

    /// Build a single-frame `CallLine` from the current emulator state.
    ///
    /// Shared between the M-DWARF-4 "no unwinder bundled" fallback
    /// path and the legacy single-frame contract. Centralising the
    /// frame construction here keeps the F5 acceptance invariants
    /// (non-empty `raw_name`, sensible `path`) in one place.
    fn single_frame_callstack(&self) -> CallLine {
        let location = self.build_location();
        let call = Call {
            key: "0".to_string(),
            children: Vec::new(),
            depth: 0,
            location,
            parent: None,
            raw_name: self.root_function_name(),
            args: Vec::new(),
            return_value: crate::value::Value::default(),
            with_args_and_return: false,
        };
        CallLine::call(call, /* hidden_children */ false, /* count */ 0, 0)
    }

    /// Snapshot the 18-slot register file via [`mcrGetRegister`] for
    /// the CFI walker. Reads through the FFI so no register-decode
    /// duplication is introduced.
    fn snapshot_registers(&self) -> [u64; MCR_REG_COUNT] {
        let mut regs = [0u64; MCR_REG_COUNT];
        for (idx, slot) in regs.iter_mut().enumerate() {
            // SAFETY: indices 0..=17 are total per the emulator FFI
            // contract documented in `emulator_ffi.rs`.
            *slot = unsafe { emulator_ffi::mcrGetRegister(idx as std::os::raw::c_int) };
        }
        regs
    }

    /// Build a [`Location`] from the current emulator state.
    ///
    /// When a bundled DWARF index is available and resolves the current
    /// PC, the returned location carries the real `(file, line)` from
    /// the binary's `.debug_line` table. Otherwise it falls back to the
    /// M-DWARF-2 placeholder of `(meta.paths[0], 1)` — F5 still passes
    /// against that fallback, just with a less informative breakpoint
    /// line.
    fn build_location(&self) -> Location {
        // SAFETY: getters never read uninitialised memory; they read
        // from the Nim-managed emulator globals which `mcrInit` reset.
        let pc = unsafe { emulator_ffi::mcrGetPC() };

        // Default to the M-DWARF-2 fallback so missing/incomplete DWARF
        // always produces a well-formed location.
        let mut path = self.primary_path();
        let mut line: i64 = 1;
        let function_name = self.root_function_name();

        if let Some(info) = self.dwarf_pc_info() {
            // Adopt the DWARF-reported source file when it disagrees
            // with `meta.paths[0]` — the DWARF line table is the
            // authoritative answer for "which source file does this PC
            // belong to". `meta.paths[0]` is a useful default but is
            // chosen by recorder-side heuristics, not by the PC.
            let dwarf_path = info.file.to_string_lossy().into_owned();
            if !dwarf_path.is_empty() {
                path = dwarf_path;
            }
            line = info.line as i64;
        }

        Location {
            path: path.clone(),
            line,
            function_name: function_name.clone(),
            high_level_path: path.clone(),
            high_level_line: line,
            high_level_function_name: function_name,
            low_level_path: path,
            low_level_line: line,
            rr_ticks: RRTicks(self.current_step_id.0),
            function_first: NO_POSITION,
            function_last: NO_POSITION,
            event: NO_EVENT,
            expression: String::new(),
            offset: pc as i64,
            error: false,
            callstack_depth: 0,
            originating_instruction_address: pc as i64,
            key: String::new(),
            global_call_key: String::new(),
            expansion_id: -1,
            expansion_first_line: -1,
            expansion_last_line: -1,
            missing_path: self.meta.paths.is_empty() && self.meta.program.is_empty(),
            ..Location::default()
        }
    }
}

/// Hard cap on the number of `mcrStep` iterations a single
/// `step(Action::*, true)` call is allowed to drive.
///
/// Set high enough that any realistic source-line step (which typically
/// covers a handful of x86_64 instructions, but may span hundreds when
/// stepping over an inlined function) succeeds, while still bounding
/// the worst-case CPU cost of a malformed line table or a runaway
/// JIT-emitted page that never advances to a new line.
///
/// 10,000 instructions is comfortably above the 99th-percentile
/// "instructions per source line" we see in production traces (peak
/// observed ≈400 for heavy Nim async dispatch).
const MAX_STEP_INSTRUCTIONS: usize = 10_000;

impl EmulatorReplaySession {
    /// Re-resolve every registered breakpoint to its static PC set.
    ///
    /// Called after `delete_breakpoint` removes one entry — there may
    /// still be other `(path, line)` slots referring to the same PC
    /// (e.g. the same line was reached by two CUs for inlined code),
    /// so we can't just remove the deleted breakpoint's PCs from the
    /// set. Rebuilding from scratch is O(N · DWARF lookup); N is
    /// the number of active breakpoints which is rarely above a
    /// dozen in practice, so the cost is negligible compared to the
    /// `Continue` loop that uses the set.
    fn rebuild_breakpoint_static_pcs(&mut self) {
        self.breakpoint_static_pcs.clear();
        let Some(dwarf) = self.dwarf.as_ref() else {
            return;
        };
        // Collect (path, line) keys first so we don't hold a borrow on
        // `self.breakpoints` while mutating `self.breakpoint_static_pcs`.
        let keys: Vec<(String, i64)> = self.breakpoints.keys().cloned().collect();
        for (path, line) in keys {
            let Ok(line_u32) = u32::try_from(line) else {
                continue;
            };
            for pc in dwarf.pcs_for_line(Path::new(&path), line_u32) {
                self.breakpoint_static_pcs.insert(pc);
            }
        }
    }

    /// Read the current PC's static address (post-rebase) for breakpoint
    /// comparison and DWARF queries. The runtime PC is what
    /// `mcrGetPC` reports; we subtract the rebase offset (computed at
    /// session construction from `cp0.maps`) so the result matches the
    /// addresses bundled in `debug.dat`.
    fn current_static_pc(&self) -> u64 {
        // SAFETY: `mcrGetPC` reads from Nim-managed globals seeded by
        // `mcrInit` and is total.
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        match self.pc_rebase {
            Some(offset) => pc.wrapping_sub(offset),
            None => pc,
        }
    }

    /// Resolve the current PC to `(file, line)` via the bundled DWARF
    /// index. Returns `None` when no DWARF is available or the PC
    /// falls outside every CU range — both are signals that
    /// source-line stepping cannot proceed and the caller should fall
    /// back to a single instruction step.
    fn current_file_line(&self) -> Option<(String, u32)> {
        let info = self.dwarf_pc_info()?;
        let path = info.file.to_string_lossy().into_owned();
        if path.is_empty() {
            return None;
        }
        Some((path, info.line))
    }

    /// Drive the emulator with `mcrStep` until `predicate` returns
    /// `true` or one of the loop guards fires:
    ///
    /// * `MAX_STEP_INSTRUCTIONS` instructions were executed (hard cap).
    /// * `mcrStep` reported exit (`1`) — typically `_start`'s exit
    ///   syscall on the hello.elf fixture.
    /// * `mcrStep` reported error (`-1`) — invalid instruction,
    ///   memory fault, or registers not seeded.
    ///
    /// Returns `true` when the predicate stopped the loop, `false` on
    /// exit / error / cap. Callers translate the boolean into their
    /// own contract (e.g. `Continue` reports "did we hit a
    /// breakpoint?", source-line stepping reports "did the line
    /// change?").
    fn step_until<F: FnMut(&mut Self) -> bool>(&mut self, mut predicate: F) -> bool {
        for _ in 0..MAX_STEP_INSTRUCTIONS {
            // SAFETY: see `step()` — `mcrStep` only reads/writes the
            // Nim-managed emulator globals seeded by `mcrInit`.
            let rc = unsafe { emulator_ffi::mcrStep() };
            if rc != 0 {
                // Exit (1) or error (-1): we cannot continue. The
                // bounded loop exit ensures the caller sees a finite
                // step count even when the recorded program ends mid
                // source line.
                return false;
            }
            if predicate(self) {
                return true;
            }
        }
        false
    }

    /// `step(Action::StepIn, true)` body.
    ///
    /// Continue executing single instructions until the source line
    /// (per the bundled DWARF) changes from the line we were on at
    /// entry. If a CALL is executed, the resulting line change lands
    /// inside the callee — which is exactly the "step in" semantic.
    ///
    /// Falls back to a single `mcrStep` when no DWARF is available
    /// (so the DAP client at least sees the step counter increment).
    fn run_step_in(&mut self) -> Result<bool, Box<dyn Error>> {
        let Some(initial) = self.current_file_line() else {
            // No DWARF: a single instruction step is the best we can do.
            // SAFETY: see `step_until`.
            let _ = unsafe { emulator_ffi::mcrStep() };
            return Ok(true);
        };
        let advanced = self.step_until(|sess| match sess.current_file_line() {
            Some((path, line)) => path != initial.0 || line != initial.1,
            // PC walked off the DWARF map (libc, JIT, padding). Stop
            // here — the user probably wants to inspect this state
            // rather than blindly keep stepping.
            None => true,
        });
        Ok(advanced)
    }

    /// `step(Action::Next, true)` body — source-line step-over.
    ///
    /// Heuristic per the M-Step-Stress spec: record initial RSP and
    /// initial `(file, line)`. Single-step until BOTH:
    ///
    /// 1. The current `(file, line)` differs from the initial.
    /// 2. The current RSP is at or above the initial RSP — i.e. we
    ///    are back to the original frame (or shallower).
    ///
    /// The RSP check is what makes step-over different from step-in:
    /// inside a CALL, RSP drops by 8 (return address pushed) and stays
    /// below the entry RSP until the matching RET pops it back. We
    /// don't need to detect the CALL instruction directly — the RSP
    /// comparison handles it transparently.
    fn run_step_over(&mut self) -> Result<bool, Box<dyn Error>> {
        let Some(initial) = self.current_file_line() else {
            // SAFETY: see `step_until`.
            let _ = unsafe { emulator_ffi::mcrStep() };
            return Ok(true);
        };
        // SAFETY: `mcrGetSP` reads from Nim-managed globals and is total.
        let initial_sp = unsafe { emulator_ffi::mcrGetSP() };
        let advanced = self.step_until(|sess| {
            // SAFETY: same as above.
            let sp = unsafe { emulator_ffi::mcrGetSP() };
            if sp < initial_sp {
                // Still inside a callee — keep stepping.
                return false;
            }
            match sess.current_file_line() {
                Some((path, line)) => path != initial.0 || line != initial.1,
                None => true,
            }
        });
        Ok(advanced)
    }

    /// `step(Action::StepOut, true)` body — run until the current
    /// function returns.
    ///
    /// We capture the DWARF function name at entry and step until the
    /// resolved function changes (or DWARF stops resolving the PC).
    /// This is more robust than an RSP-only heuristic because the
    /// emit pattern for a function's epilogue varies (e.g. `pop rbp`
    /// vs `leave`, multiple intermediate xors before the `ret`), and
    /// because the epilogue itself moves RSP without leaving the
    /// function. Function-name comparison is the cleanest "have I
    /// returned to a different frame yet?" signal DWARF gives us.
    ///
    /// Falls back to a single instruction step when no DWARF is
    /// available — better than spinning forever on a stripped trace.
    fn run_step_out(&mut self) -> Result<bool, Box<dyn Error>> {
        let Some(initial_fn) = self.current_function_name() else {
            // SAFETY: same rationale as `run_step_over`.
            let _ = unsafe { emulator_ffi::mcrStep() };
            return Ok(true);
        };
        let advanced = self.step_until(|sess| match sess.current_function_name() {
            // Same function → still inside it; keep stepping.
            Some(name) => name != initial_fn,
            // Lost DWARF resolution — we've returned past any CU
            // (e.g. into the `_start` runtime stub). Stop.
            None => true,
        });
        Ok(advanced)
    }

    /// Resolve the current PC to a DWARF function name. Returns
    /// `None` when no DWARF is bundled or the PC falls outside every
    /// CU's address ranges.
    fn current_function_name(&self) -> Option<String> {
        let info = self.dwarf_pc_info()?;
        info.function
    }

    /// `step(Action::Continue, true)` body — run until a breakpoint
    /// hits or the emulator exits / errors.
    ///
    /// Compares the post-step *static* PC against `breakpoint_static_pcs`.
    /// When the set is empty (no breakpoints currently registered, or
    /// no DWARF to resolve them with), the emulator runs to the
    /// `MAX_STEP_INSTRUCTIONS` cap and reports "no breakpoint hit"
    /// — matching the contract that `Continue` returns `false` when
    /// nothing stopped it.
    fn run_continue(&mut self) -> Result<bool, Box<dyn Error>> {
        if self.breakpoint_static_pcs.is_empty() {
            // No breakpoints to hit. Step the cap and report "miss".
            // This is the production "user pressed Continue with no
            // breakpoints set" path — the DAP client surfaces a
            // notification.
            let _ = self.step_until(|_| false);
            return Ok(false);
        }
        let hit = self.step_until(|sess| sess.breakpoint_static_pcs.contains(&sess.current_static_pc()));
        Ok(hit)
    }
}

impl Default for EmulatorReplaySession {
    fn default() -> Self {
        Self::new()
    }
}

impl ReplaySession for EmulatorReplaySession {
    fn load_location(&mut self, _expr_loader: &mut ExprLoader) -> Result<Location, Box<dyn Error>> {
        Ok(self.build_location())
    }

    fn run_to_entry(&mut self) -> Result<(), Box<dyn Error>> {
        // The emulator's entry state is whatever `mcrSetRegisters` left
        // behind; we have no separate "rewind" because no recorder yet
        // emits checkpoint snapshots for the db-backend to restore.
        // Resetting the step counter view keeps `current_step_id` honest
        // for clients that call `run_to_entry` mid-session.
        self.current_step_id = StepId(0);
        Ok(())
    }

    fn load_events(&mut self) -> Result<Events, Box<dyn Error>> {
        // F5 paginates `Events` for the GUI events sidebar. Returning an
        // empty stream is correct for the emulator path until syscall
        // projection (`mcrAddSyscallEvent` -> `ProgramEvent`) is wired
        // up in a follow-up.
        Ok(Events {
            events: Vec::new(),
            first_events: Vec::new(),
            contents: String::new(),
        })
    }

    fn step(&mut self, action: Action, forward: bool) -> Result<bool, Box<dyn Error>> {
        // ── Reverse stepping is not yet implemented ────────────────────
        //
        // The Nim emulator only exposes `mcrStep` / `mcrRun`, which
        // advance forward. Reverse execution requires snapshot-based
        // rewind that no recorder yet emits for the db-backend. Rather
        // than silently treating reverse requests as forward steps
        // (which would confuse the DAP client), surface a typed error.
        if !forward {
            return Err("reverse stepping is not yet implemented for MCR".into());
        }

        // Dispatch to the per-Action helper. Each helper drives the
        // emulator with a bounded `mcrStep` loop and returns the same
        // boolean contract: `true` on a "stepped to a useful place"
        // outcome, `false` on "no breakpoint hit / exit" (only
        // meaningful for `Continue`).
        let hit = match action {
            Action::StepIn => self.run_step_in()?,
            Action::Next => self.run_step_over()?,
            Action::StepOut => self.run_step_out()?,
            Action::Continue => self.run_continue()?,
            other => {
                // The remaining variants (`StepC`, `NextC`, `StepI`,
                // `NextI`, `CoStepIn`, `CoNext`, `NonAction`) are not
                // exercised by the F5 / M-Step-Stress happy path. The
                // DAP `step` handler routes them to one of the four
                // covered actions for materialised sessions and never
                // reaches us with anything else; surfacing an error if
                // it ever does means a future feature gets a clear
                // diagnostic instead of a silent single instruction.
                return Err(format!("EmulatorReplaySession: action {other:?} is not implemented for MCR").into());
            }
        };

        // Mirror the emulator counter so subsequent `current_step_id`
        // calls return the updated value. The helpers may run many
        // emulator instructions per call, so we sync once at the end.
        //
        // SAFETY: `mcrGetStepCounter` is total — it returns 0 before
        // any instructions have executed and a monotonic value after.
        let counter = unsafe { emulator_ffi::mcrGetStepCounter() };
        self.current_step_id = StepId(counter as i64);
        Ok(hit)
    }

    fn load_locals(&mut self, _arg: CtLoadLocalsArguments) -> Result<Vec<VariableWithRecord>, Box<dyn Error>> {
        // Project every named x86_64 register as a local. This is enough
        // for F5's variables-view sanity assertion (≥1 variable with a
        // non-empty value) and is also a useful default debugging view
        // for emulator-backed traces — DWARF locals can stack on top
        // later.
        let mut out = Vec::with_capacity(REGISTER_NAMES.len());
        let int_type = type_record(TypeKind::Int, "u64");
        for (idx, name) in REGISTER_NAMES.iter().enumerate() {
            // SAFETY: `mcrGetRegister` is total and bounded by the index
            // table documented on the FFI. Indices 0..=17 always return
            // a defined `u64`.
            let value = unsafe { emulator_ffi::mcrGetRegister(idx as std::os::raw::c_int) };
            out.push(VariableWithRecord {
                expression: (*name).to_string(),
                value: ValueRecordWithType::Int {
                    i: value as i64,
                    typ: int_type.clone(),
                },
                address: NO_ADDRESS,
            });
        }
        Ok(out)
    }

    fn load_value(
        &mut self,
        expression: &str,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // Look up the expression as a register name. Anything else
        // currently surfaces as a typed error so the frontend renders a
        // legible "not found" rather than crashing on a `todo!()`.
        let int_type = type_record(TypeKind::Int, "u64");
        if let Some(idx) = REGISTER_NAMES.iter().position(|name| *name == expression) {
            // SAFETY: indices 0..=17 are always valid for `mcrGetRegister`.
            let value = unsafe { emulator_ffi::mcrGetRegister(idx as std::os::raw::c_int) };
            return Ok(ValueRecordWithType::Int {
                i: value as i64,
                typ: int_type,
            });
        }
        Err(format!("EmulatorReplaySession: unknown variable `{expression}`").into())
    }

    fn load_return_value(
        &mut self,
        _depth_limit: Option<usize>,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        // Return-value introspection requires DWARF + ABI knowledge we
        // don't have yet. Returning a typed `None` keeps the DAP handler
        // happy if it ever reaches this branch on the emulator path.
        Ok(ValueRecordWithType::None {
            typ: type_record(TypeKind::None, "none"),
        })
    }

    fn load_step_events(&mut self, _step_id: StepId, _exact: bool) -> Vec<DbRecordEvent> {
        // The emulator has no per-step event log yet. F5 only consults
        // this for the events sidebar, so returning an empty vector is
        // benign.
        Vec::new()
    }

    fn load_callstack(&mut self) -> Result<Vec<CallLine>, Box<dyn Error>> {
        // M-DWARF-4: drive the CFI walker for multi-frame stack
        // traces. We always synthesise the innermost frame from
        // `build_location` to preserve the F5 "non-empty name" /
        // "sensible source path" acceptance bar; the unwinder layers
        // any recoverable parent frames on top.
        //
        // When no unwinder is available (no bundled debug.dat, or the
        // ELF failed to parse), we surface just the single innermost
        // frame — matching the pre-M-DWARF-4 contract.
        let Some(unwinder) = self.stack_unwinder.as_ref() else {
            return Ok(vec![self.single_frame_callstack()]);
        };

        // SAFETY: same rationale as elsewhere — the emulator FFI
        // getters read from Nim-managed globals seeded by `mcrInit` /
        // `mcrSetRegisters`.
        let initial_pc = unsafe { emulator_ffi::mcrGetPC() };
        let registers = self.snapshot_registers();

        // The unwinder uses the `static` PC for FDE lookups but
        // reports the runtime PC back so DAP frames keep their ASLR
        // address. The rebase delta is the same one
        // `dwarf_pc_info_for` uses (set once during construction).
        let frames = unwinder.unwind(
            initial_pc,
            self.pc_rebase,
            registers,
            // Memory-reading closure: the unwinder may need to dereference
            // CFA-relative addresses (saved RA, saved RBP, etc.) to
            // recover caller registers. `mcrReadMemory` returns 0 on
            // success and -1 when the address is not covered by any
            // installed region — translate that into the `Result<(), ()>`
            // shape the unwinder expects.
            |addr, buf| {
                // SAFETY: `buf.as_mut_ptr()` is valid for `buf.len()`
                // bytes; `mcrReadMemory` copies into it without
                // retaining the pointer.
                let rc =
                    unsafe { emulator_ffi::mcrReadMemory(addr, buf.as_mut_ptr(), buf.len() as std::os::raw::c_int) };
                if rc == 0 { Ok(()) } else { Err(()) }
            },
            MAX_CALLSTACK_FRAMES,
        );

        if frames.is_empty() {
            // Degenerate case (max_frames = 0 was passed somehow); fall
            // back to the single-frame synthesis to preserve the F5
            // acceptance contract.
            return Ok(vec![self.single_frame_callstack()]);
        }

        let mut out = Vec::with_capacity(frames.len());
        for (depth, frame) in frames.iter().enumerate() {
            let location = self.build_location_for(frame.pc, frame.pc_static);
            // Use the DWARF-resolved function name for the call's
            // `raw_name` when available — falling back to the
            // synthesised root name preserves the F5 "non-empty name"
            // bar for the innermost frame when its DWARF is missing.
            let raw_name = if location.function_name.is_empty() {
                self.root_function_name()
            } else {
                location.function_name.clone()
            };
            let call = Call {
                key: depth.to_string(),
                children: Vec::new(),
                depth,
                location,
                parent: None,
                raw_name,
                args: Vec::new(),
                return_value: crate::value::Value::default(),
                with_args_and_return: false,
            };
            out.push(CallLine::call(
                call, /* hidden_children */ false, /* count */ 0, depth,
            ));
        }
        Ok(out)
    }

    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        todo!("F5c-3: build per-line history from emulator trace")
    }

    fn add_breakpoint(&mut self, path: &str, line: i64, column: Option<i64>) -> Result<Breakpoint, Box<dyn Error>> {
        // The dap_handler shim (`dap_handler::set_breakpoints`, around
        // line 1294) reports `verified: true` whenever `add_breakpoint`
        // returns `Ok`. So all we need to do here is mint a new id and
        // remember the entry so `delete_breakpoint` can find it.
        //
        // The emulator session is DWARF-driven: it resolves a `(path,
        // line)` to static PCs for the Continue hot-path check.  Column
        // is currently ignored at that resolution stage (DWARF line
        // tables are line-granular) — we still thread it onto the
        // returned `Breakpoint` so the DAP response and GUI gutter
        // marker carry the bound column even on emulator-backed traces.
        let mut breakpoint = self.allocate_breakpoint(path, line);
        breakpoint.column = column;
        // M-Step-Stress: resolve the (path, line) to static PCs via the
        // bundled DWARF reverse index and populate the `Continue` hot
        // path's lookup set. A missing DWARF index, an unknown line, or
        // a path that doesn't match any CU are all silent — we still
        // mint the breakpoint so the GUI's breakpoint marker shows up,
        // but `Continue` won't halt on it.
        if let Some(dwarf) = self.dwarf.as_ref()
            && let Ok(line_u32) = u32::try_from(line)
        {
            for pc in dwarf.pcs_for_line(Path::new(path), line_u32) {
                self.breakpoint_static_pcs.insert(pc);
            }
        }
        Ok(breakpoint)
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        for (key, entries) in self.breakpoints.iter_mut() {
            if let Some(pos) = entries.iter().position(|b| b.id == breakpoint.id) {
                entries.remove(pos);
                let key = key.clone();
                let no_more = entries.is_empty();
                if no_more {
                    // Drop the resolved PCs *only* if no other breakpoint
                    // (different id, same path/line) refers to them. The
                    // bookkeeping is simple because we re-resolve from
                    // scratch — see below.
                    self.breakpoints.remove(&key);
                }
                self.rebuild_breakpoint_static_pcs();
                return Ok(true);
            }
        }
        // Mirror MaterializedReplaySession: unknown id is an error so the
        // GUI can surface a diagnostic instead of silently no-ooping.
        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.breakpoints.clear();
        self.breakpoint_static_pcs.clear();
        Ok(true)
    }

    fn toggle_breakpoint(&mut self, _breakpoint: &Breakpoint) -> Result<Breakpoint, Box<dyn Error>> {
        todo!("F5c-3: flip emulator breakpoint state")
    }

    fn enable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.breakpoints_enabled = true;
        for entries in self.breakpoints.values_mut() {
            for b in entries.iter_mut() {
                b.enabled = true;
            }
        }
        Ok(())
    }

    fn disable_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        self.breakpoints_enabled = false;
        for entries in self.breakpoints.values_mut() {
            for b in entries.iter_mut() {
                b.enabled = false;
            }
        }
        Ok(())
    }

    fn jump_to(&mut self, _step_id: StepId) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: rewind/fast-forward emulator to step_id")
    }

    fn jump_to_call(&mut self, _location: &Location) -> Result<Location, Box<dyn Error>> {
        todo!("F5c-3: jump to enclosing call entry")
    }

    fn event_jump(&mut self, _event: &ProgramEvent) -> Result<bool, Box<dyn Error>> {
        todo!("F5c-3: replay to the step that produced `event`")
    }

    fn callstack_jump(&mut self, _depth: usize) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: pop to caller at `depth`")
    }

    fn location_jump(&mut self, _location: &Location) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a specific source location")
    }

    fn tracepoint_jump(&mut self, _event: &ProgramEvent) -> Result<(), Box<dyn Error>> {
        todo!("F5c-3: jump to a tracepoint event")
    }

    fn evaluate_call_expression(
        &mut self,
        _call_expression: &str,
        _lang: Lang,
    ) -> Result<ValueRecordWithType, Box<dyn Error>> {
        todo!("F5c-3: evaluate a `func(args)` expression via the emulator")
    }

    fn current_step_id(&mut self) -> StepId {
        self.current_step_id
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    /// M18 — expose the omniscient DB when the trace's CTFS container
    /// declared at least one of `memwrites.tc` / `linehits.tc`. The
    /// FFI handle itself is zero-cost; we only surface it when the
    /// presence flag is set so callers don't accidentally query an
    /// empty omniscient store on legacy traces.
    fn omniscient_db(&self) -> Option<&dyn crate::omniscient_db::OmniscientDb> {
        if self.omniscient_present || self.omniscient_handle.is_present() {
            Some(&self.omniscient_handle)
        } else {
            None
        }
    }

    /// M22 — arm a per-write data breakpoint on the WASM emulator. The
    /// origin algorithm's §6.6 hybrid path consumes this to resolve
    /// pre-window queries that would otherwise have to leave the
    /// browser. Forwards to the typed [`crate::data_watch::install_data_watch`]
    /// wrapper which carries the failure-mode discipline (slots
    /// exhausted, invalid size).
    fn data_watch_install(
        &mut self,
        address: u64,
        size: u32,
    ) -> Result<crate::data_watch::DataWatchHandle, crate::data_watch::DataWatchError> {
        crate::data_watch::install_data_watch(address, size)
    }

    /// M22 — tear down a previously-installed data watch.
    fn data_watch_clear(
        &mut self,
        handle: crate::data_watch::DataWatchHandle,
    ) -> Result<(), crate::data_watch::DataWatchError> {
        crate::data_watch::clear_data_watch(handle)
    }

    /// M22 — session-scoped reset: tear down every armed watch and
    /// reset the per-session diagnostic counters. The origin algorithm
    /// calls this at the top of an origin-chain build per spec §6.6 to
    /// guarantee that watches leaked by an earlier query never
    /// cross-talk into this query's fire stream.
    fn data_watch_reset(&mut self) {
        crate::data_watch::reset_data_watches();
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
    use crate::ctfs_trace_reader::meta_dat::{FLAG_HAS_MCR_FIELDS, META_DAT_VERSION, McrFields, serialize_meta_dat};

    /// Build a synthetic CTFS payload with the `FlagHasMcrFields` bit set
    /// and a plausible meta block. We don't need real checkpoint streams
    /// to exercise the F5c-3 trait surface — the meta block alone is
    /// enough for `load_location` / `load_callstack` to synthesise a
    /// non-empty frame.
    fn synthetic_mcr_ctfs_bytes() -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/local/bin/example".to_owned(),
            args: vec!["arg0".to_owned()],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned(), "src/util.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = serialize_meta_dat(&meta);

        // Wrap meta.dat into a minimal CTFS container. The `t00000000000`
        // file is a placeholder thread stream — real MCR traces ship
        // per-thread streams, and including it here makes the fixture
        // resemble the production layout even though we don't yet read it.
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic.ct");
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("t00000000000", b"")]).unwrap();
        std::fs::read(&ct_path).unwrap()
    }

    /// F5c-1 bring-up: constructing the session must succeed (NimMain
    /// plus mcrInit linked and callable). Probing the emulator state
    /// via the FFI should report zeros, since we have not loaded a
    /// program.
    #[test]
    fn new_session_initialises_nim_runtime_and_resets_state() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let mut session = EmulatorReplaySession::new();

        // SAFETY: After `new()` the Nim runtime is initialised and
        // mcrInit has been called; these getters are safe to invoke
        // and return 0 because no register file has been loaded yet.
        unsafe {
            assert_eq!(emulator_ffi::mcrGetPC(), 0);
            assert_eq!(emulator_ffi::mcrGetSP(), 0);
            assert_eq!(emulator_ffi::mcrGetRegister(0), 0);
            assert_eq!(emulator_ffi::mcrGetStepCounter(), 0);
        }

        // current_step_id is the only trait method that already had a
        // non-`todo!()` body before F5c-3; sanity-check that it still
        // returns the initial value.
        assert_eq!(session.current_step_id(), StepId(0));
    }

    /// F5c-3 acceptance: constructing a session from a synthetic MCR
    /// CTFS payload must (a) succeed and (b) carry through the
    /// meta-derived source path and program name.
    #[test]
    fn new_from_ctfs_bytes_populates_meta() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes();
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        assert_eq!(session.meta.program, "/usr/local/bin/example");
        assert_eq!(
            session.meta.paths,
            vec!["src/main.c".to_owned(), "src/util.c".to_owned()]
        );
        assert!(
            session.meta.mcr.is_some(),
            "MCR meta block must round-trip through new_from_ctfs_bytes",
        );
    }

    /// `new_from_ctfs_bytes` must reject CTFS containers that lack the
    /// FlagHasMcrFields bit — otherwise we would silently route
    /// materialised traces (which need DB-backed playback) through the
    /// emulator path.
    #[test]
    fn new_from_ctfs_bytes_rejects_non_mcr_traces() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned()],
            workdir: "/srv/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            paths: vec!["script.rb".to_owned()],
            mcr: None,
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("non_mcr.ct");
        write_minimal_ctfs(&ct_path, &[("meta.dat", &dat), ("events.log", b"placeholder")]).unwrap();
        let bytes = std::fs::read(&ct_path).unwrap();

        let err = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect_err("non-MCR CTFS must be rejected");
        assert!(
            err.to_string().contains("FLAG_HAS_MCR_FIELDS"),
            "error should mention the missing MCR flag, got: {err}",
        );
    }

    /// F5c-3 acceptance: `load_callstack` must surface at least one
    /// frame and that frame's function name must be non-empty. This
    /// mirrors what the F5 gateway-client checks via DAP `stackTrace`.
    #[test]
    fn load_callstack_returns_frame_with_non_empty_name() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty(), "expected at least one frame");
        let raw_name = &frames[0].content.call.raw_name;
        assert!(
            !raw_name.is_empty(),
            "frame function name must be non-empty, got `{raw_name}`"
        );
        // The synthetic fixture's program is `/usr/local/bin/example`,
        // so the basename — and therefore the frame name — must contain
        // "example". Asserting on the substring rather than the full
        // string keeps the test robust to future tweaks of the
        // root-name synthesis (e.g. appending an entry-point suffix).
        assert!(
            raw_name.contains("example"),
            "frame name should reflect program basename, got `{raw_name}`"
        );

        let path = &frames[0].content.call.location.path;
        assert!(!path.is_empty(), "frame source path must be non-empty");
        assert_eq!(path, "src/main.c", "frame path should pick the first meta.paths entry");
    }

    /// F5c-3 acceptance: `add_breakpoint` must report success so the
    /// DAP handler can surface `verified: true` to the client. Negative
    /// path: `delete_breakpoint` with an unknown id must error.
    #[test]
    fn add_breakpoint_returns_enabled_record() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let bp = session
            .add_breakpoint("src/main.c", 42, None)
            .expect("breakpoint must register");
        assert!(bp.enabled, "freshly-added breakpoint must be enabled");
        assert!(bp.id >= 1, "breakpoint id must be a positive monotonic counter");

        // Round-trip: deletion must succeed; second deletion must fail
        // with a typed error so the caller can surface a diagnostic.
        assert!(session.delete_breakpoint(&bp).expect("delete must succeed"));
        let err = session
            .delete_breakpoint(&bp)
            .expect_err("second delete of same id must fail");
        assert!(err.to_string().contains("not found"));
    }

    /// `load_locals` must project all 18 named x86_64 registers as
    /// variables. F5 needs at least one variable with a non-empty
    /// expression so the variables view renders something.
    #[test]
    fn load_locals_returns_register_variables() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let locals = session
            .load_locals(CtLoadLocalsArguments::default())
            .expect("locals must succeed");
        assert_eq!(locals.len(), REGISTER_NAMES.len());

        // Spot-check that the first variable has a non-empty name —
        // the variables view's headline acceptance bar.
        assert_eq!(locals[0].expression, "rax");
        match locals[0].value {
            ValueRecordWithType::Int { i, .. } => {
                assert_eq!(i, 0, "uninitialised registers must read as zero");
            }
            ref other => panic!("expected Int value, got {other:?}"),
        }
    }

    /// `load_value` must resolve register names to their u64 values
    /// and surface a typed error for unknown expressions.
    #[test]
    fn load_value_resolves_registers_and_errors_for_unknown() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let rax = session
            .load_value("rax", None, Lang::Unknown)
            .expect("rax must resolve");
        match rax {
            ValueRecordWithType::Int { i, .. } => assert_eq!(i, 0),
            other => panic!("expected Int value, got {other:?}"),
        }

        let err = session
            .load_value("not_a_register", None, Lang::Unknown)
            .expect_err("unknown variable must error");
        assert!(err.to_string().contains("not_a_register"));
    }

    /// `step` must not error out on the no-program path that F5's
    /// happy flow exercises (the DAP handler issues `step` actions on
    /// `next`/`stepIn` even when the emulator has no code loaded).
    ///
    /// The Nim implementation returns -1 without advancing
    /// `gStepCounter` when registers have not been seeded, so we only
    /// assert that the call succeeds and that the cached step id stays
    /// consistent with the emulator-reported counter.
    #[test]
    fn step_does_not_error_without_a_loaded_program() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let mut session = EmulatorReplaySession::new();
        session.step(Action::Next, true).expect("step must succeed");
        // SAFETY: the FFI getter is total; it returns 0 before any
        // instructions have executed and matches our cached id.
        let counter = unsafe { emulator_ffi::mcrGetStepCounter() };
        assert_eq!(session.current_step_id().0, counter as i64);
    }

    /// `load_events` / `load_step_events` / `load_return_value` are
    /// stub-OK on F5: they return empty/None values rather than
    /// `todo!()` so the DAP handler can survive an emulator-backed
    /// session that exercises them incidentally (e.g. during the events
    /// pagination warm-up).
    #[test]
    fn empty_returns_for_stub_paths() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let mut session = EmulatorReplaySession::new();
        let events = session.load_events().expect("load_events must succeed");
        assert!(events.events.is_empty());
        assert!(events.first_events.is_empty());

        let step_events = session.load_step_events(StepId(0), false);
        assert!(step_events.is_empty());

        let rv = session
            .load_return_value(None, Lang::Unknown)
            .expect("load_return_value must succeed");
        assert!(matches!(rv, ValueRecordWithType::None { .. }));
    }

    // ── M-DWARF-3 fixtures ──────────────────────────────────────────────
    //
    // The DWARF-bundling tests reuse the same small ELF fixture as the
    // `dwarf_index` module (built from `tests/fixtures/dwarf/hello.c` by
    // `rebuild.sh`). The file is ~11 KB and contains three functions
    // (`add`, `compute`, `main`) compiled with `-O0 -g` so its line
    // numbers stay stable across rebuilds.
    //
    // PC constants here mirror `dwarf_index::tests`: `PC_ADD_BODY`
    // (0x40100a) sits on hello.c line 24 — the `int sum = a + b;`
    // statement, which is the same line every gcc since 11 has emitted
    // for that source. The DWARF resolver is the authoritative source of
    // the expected number; we re-state it as a constant only so the test
    // failure message includes the expected value alongside the actual
    // one.

    const HELLO_ELF_FIXTURE: &[u8] = include_bytes!("../tests/fixtures/dwarf/hello.elf");
    const PC_ADD_BODY: u64 = 0x40100a;
    const PC_ADD_BODY_LINE: i64 = 24;

    /// Build a synthetic CTFS payload like `synthetic_mcr_ctfs_bytes()`
    /// but **with** a bundled `debug.dat` file carrying the hello.elf
    /// fixture. The resulting session's `dwarf` field should round-trip
    /// the parsed DWARF index so `build_location` can resolve PCs.
    fn synthetic_mcr_ctfs_bytes_with_dwarf() -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/local/bin/hello".to_owned(),
            args: vec![],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic_with_dwarf.ct");
        write_minimal_ctfs(
            &ct_path,
            &[
                ("meta.dat", &dat),
                ("t00000000000", b""),
                (BUNDLED_DEBUG_FILE, HELLO_ELF_FIXTURE),
            ],
        )
        .unwrap();
        std::fs::read(&ct_path).unwrap()
    }

    /// M-DWARF-3 acceptance: when the CTFS container bundles a
    /// `debug.dat` ELF, `new_from_ctfs_bytes` must parse it into a
    /// `DwarfIndex` accessible via the session's `dwarf` field.
    #[test]
    fn new_from_ctfs_bytes_with_debug_populates_dwarf_index() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_with_dwarf();
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        let dwarf = session.dwarf.as_ref().expect("debug.dat must produce a DwarfIndex");
        // hello.c is the primary source; the fixture also references
        // hello_start.S so we expect at least 1 source file.
        assert!(
            dwarf.source_file_count() >= 1,
            "DwarfIndex should know about at least one source file"
        );
        // Spot-check that a known PC inside the fixture resolves — this
        // exercises the full end-to-end "CTFS file → ELF bytes → gimli
        // sections → addr2line context" pipeline rather than just
        // confirming the bytes survived the bundle round-trip.
        let info = dwarf
            .resolve_pc(PC_ADD_BODY)
            .expect("PC_ADD_BODY must resolve through the bundled DWARF");
        assert_eq!(
            info.line, PC_ADD_BODY_LINE as u32,
            "expected line {PC_ADD_BODY_LINE}, got {info:?}"
        );
    }

    /// M-DWARF-3 acceptance: a corrupt or unrecognisable `debug.dat`
    /// must not prevent the session from coming up — it must fall back
    /// to the M-DWARF-2 placeholder location behaviour silently.
    #[test]
    fn new_from_ctfs_bytes_with_bad_debug_falls_back() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/local/bin/hello".to_owned(),
            args: vec![],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic_bad_dwarf.ct");
        write_minimal_ctfs(
            &ct_path,
            &[
                ("meta.dat", &dat),
                ("t00000000000", b""),
                // Not an ELF — DwarfIndex::from_elf_bytes will return
                // DwarfError::Object("File magic is not …"), which the
                // M-DWARF-3 constructor must collapse to `dwarf: None`.
                (BUNDLED_DEBUG_FILE, b"this is definitely not ELF bytes"),
            ],
        )
        .unwrap();
        let bytes = std::fs::read(&ct_path).unwrap();

        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes)
            .expect("CTFS load must succeed even with a malformed debug.dat");
        assert!(
            session.dwarf.is_none(),
            "malformed debug.dat must collapse to None, not crash the session"
        );
    }

    /// M-DWARF-3 acceptance: with a bundled `debug.dat` AND a non-zero
    /// PC matching a real instruction, `load_callstack` must surface a
    /// frame whose `line` is the DWARF-resolved line (not the M-DWARF-2
    /// `1` placeholder) and whose `path` matches the DWARF-emitted file
    /// (overriding `meta.paths[0]` when they disagree).
    ///
    /// This is the headline test for M-DWARF-3: it walks the full
    /// recorder → bundle → replay → DAP `stackTrace` data path inside a
    /// single test process.
    #[test]
    fn load_callstack_uses_dwarf_resolved_line() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_with_dwarf();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        // SAFETY: mcrSetRegisters is the canonical way to seed the
        // emulator program counter; `new_from_ctfs_bytes` has just
        // called `mcrInit` so the register file is in a clean,
        // uninitialised state.
        //
        // We set every GPR to 0 and only RIP to PC_ADD_BODY so the
        // location calculation has a deterministic input. RFLAGS is set
        // to 0x202 (the x86_64 reset value: bit 1 must be set, plus IF
        // typically set) but its value does not affect PC resolution.
        unsafe {
            emulator_ffi::mcrSetRegisters(
                /* rax */ 0,
                /* rbx */ 0,
                /* rcx */ 0,
                /* rdx */ 0,
                /* rsi */ 0,
                /* rdi */ 0,
                /* rbp */ 0,
                /* rsp */ 0,
                /* r8  */ 0,
                /* r9  */ 0,
                /* r10 */ 0,
                /* r11 */ 0,
                /* r12 */ 0,
                /* r13 */ 0,
                /* r14 */ 0,
                /* r15 */ 0,
                /* rip */ PC_ADD_BODY,
                /* rflags */ 0x202,
            );
        }

        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty(), "expected at least one frame");
        let loc = &frames[0].content.call.location;

        assert_eq!(
            loc.line, PC_ADD_BODY_LINE,
            "DWARF-resolved line must override the M-DWARF-2 placeholder; got loc = {loc:?}",
        );
        assert!(
            loc.path.ends_with("hello.c"),
            "DWARF-resolved path must override meta.paths[0] (= src/main.c); got loc.path = {}",
            loc.path,
        );
        // The emulator FFI surfaces the raw PC via `Location.offset` —
        // sanity-check that the test actually set it (otherwise we'd be
        // resolving PC 0 from leftover state, which would silently fail
        // the line assertion above too).
        assert_eq!(loc.offset, PC_ADD_BODY as i64);
    }

    // ── FFI test serialisation ───────────────────────────────────────────
    //
    // Tests that mutate the Nim-managed emulator globals (`mcrInit`,
    // `mcrLoadMemoryRegion`, `mcrSetRegisters`) must run serially —
    // otherwise a sibling test's `mcrInit` can wipe state between our
    // own write and its subsequent read. Cargo runs unit tests in
    // parallel by default, so we guard the FFI block with a per-process
    // `Mutex`. Tests that only inspect FFI state from inside a freshly
    // constructed session (e.g. assertions on `mcrGetPC` right after
    // `new_from_ctfs_bytes`) also acquire this lock so they don't race
    // against memory-installing tests.
    use std::sync::Mutex;
    static FFI_TEST_LOCK: Mutex<()> = Mutex::new(());

    // ── M-Checkpoint-Replay fixtures ────────────────────────────────────
    //
    // `cp0.regs` and `cp0.mem` carry the recorded initial state from the
    // LD_PRELOAD `__libc_start_main` wrapper. The on-disk format is the
    // same one the Nim emulator side already decodes in
    // `ct_emulator/src/ct_emulator/ctfs_bridge.nim::loadInitialStateFromTrace`
    // (cross-checked against the C writer at
    // `ct_interpose/src/ct_interpose/full_snapshot.c` lines 480–506).
    //
    // We hand-build minimal fixtures rather than depending on a recorded
    // trace, so the tests run in seconds and don't pull in the full
    // recorder toolchain.

    /// Serialise an `(address, size, bytes[size])` tuple into a `cp0.mem`
    /// blob. Multiple regions are concatenated by the caller.
    fn pack_cp0_mem_region(address: u64, bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(16 + bytes.len());
        out.extend_from_slice(&address.to_le_bytes());
        out.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
        out.extend_from_slice(bytes);
        out
    }

    /// Build a `cp0.regs` blob for the compact 18 × u64 LE layout
    /// (`tid = 0, reg_data_len = 144`, then the GPRs in `mcrSetRegisters`
    /// argument order).
    #[allow(clippy::too_many_arguments)]
    fn pack_cp0_regs_compact(regs: &InitialRegisters) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + CP0_REGS_COMPACT_LEN);
        out.extend_from_slice(&0u32.to_le_bytes()); // tid = 0
        out.extend_from_slice(&(CP0_REGS_COMPACT_LEN as u32).to_le_bytes());
        for &v in &[
            regs.rax,
            regs.rbx,
            regs.rcx,
            regs.rdx,
            regs.rsi,
            regs.rdi,
            regs.rbp,
            regs.rsp,
            regs.r8,
            regs.r9,
            regs.r10,
            regs.r11,
            regs.r12,
            regs.r13,
            regs.r14,
            regs.r15,
            regs.rip,
            regs.rflags,
        ] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// Build a `cp0.regs` blob for the ptrace `user_regs_struct` layout
    /// (27 × u64 LE). Only RIP / RSP / RFLAGS need to be set explicitly
    /// for our decoder path; everything else can be zero.
    fn pack_cp0_regs_user_struct(rip: u64, rsp: u64, rflags: u64, rax: u64) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + CP0_REGS_USER_STRUCT_LEN);
        out.extend_from_slice(&0u32.to_le_bytes()); // tid
        out.extend_from_slice(&(CP0_REGS_USER_STRUCT_LEN as u32).to_le_bytes());
        // r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi
        // orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs
        let mut regs = [0u64; 27];
        regs[10] = rax; // rax slot in user_regs_struct
        regs[16] = rip;
        regs[18] = rflags;
        regs[19] = rsp;
        for v in regs.iter() {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// Serialise a CTFS container with the M-Checkpoint-Replay seeds, a
    /// bundled `debug.dat` ELF, and the meta-block flags the emulator
    /// session requires. Returns the in-memory `.ct` bytes ready to feed
    /// into `EmulatorReplaySession::new_from_ctfs_bytes`.
    ///
    /// `cp0_maps` lets the M-Replay-PC-Rebase tests bake in a synthetic
    /// `/proc/self/maps` blob alongside the other cp0 sidecars; when
    /// `None`, no `cp0.maps` is written and PC rebasing falls back to
    /// `None` (no rebase, raw PC for DWARF lookup).
    #[allow(clippy::too_many_arguments)]
    fn synthetic_mcr_ctfs_bytes_with_cp0(
        cp0_regs: Option<&[u8]>,
        cp0_mem_regions: &[(u64, Vec<u8>)],
        include_dwarf: bool,
    ) -> Vec<u8> {
        synthetic_mcr_ctfs_bytes_with_cp0_maps(cp0_regs, cp0_mem_regions, include_dwarf, None)
    }

    /// Extended fixture builder that also writes a `cp0.maps` blob.
    /// Kept as a separate helper so the existing M-Checkpoint-Replay
    /// callers don't have to thread `None` arguments through.
    fn synthetic_mcr_ctfs_bytes_with_cp0_maps(
        cp0_regs: Option<&[u8]>,
        cp0_mem_regions: &[(u64, Vec<u8>)],
        include_dwarf: bool,
        cp0_maps: Option<&str>,
    ) -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_owned(),
            program: "/usr/local/bin/hello".to_owned(),
            args: vec![],
            workdir: "/tmp/run".to_owned(),
            recorder_id: "mcr".to_owned(),
            paths: vec!["src/main.c".to_owned()],
            mcr: Some(McrFields {
                tick_source: 1,
                total_threads: 1,
                atomic_mode: 0,
                total_events: 0,
                total_checkpoints: 0,
                start_time_unix_us: 0,
                platform: "linux-x86_64".to_owned(),
                tick_granularity: "instruction".to_owned(),
                tick_source_str: "rdtsc".to_owned(),
                atomic_mode_str: "seq_cst".to_owned(),
                start_time_str: "1970-01-01T00:00:00Z".to_owned(),
                hook_profile: String::new(),
                hook_strategies: Vec::new(),
            }),
            replay_launch: None,
            layout_snapshot: None,
            filter_provenance: Vec::new(),
            has_filter_provenance: false,
        };
        let dat = serialize_meta_dat(&meta);
        let dir = tempfile::tempdir().unwrap();
        let ct_path = dir.path().join("synthetic_with_cp0.ct");

        let mut mem_blob: Vec<u8> = Vec::new();
        for (addr, bytes) in cp0_mem_regions {
            mem_blob.extend(pack_cp0_mem_region(*addr, bytes));
        }

        let mut entries: Vec<(&str, &[u8])> = vec![("meta.dat", &dat), ("t00000000000", b"")];
        if include_dwarf {
            entries.push((BUNDLED_DEBUG_FILE, HELLO_ELF_FIXTURE));
        }
        if !mem_blob.is_empty() {
            entries.push((CP0_MEM_FILE, &mem_blob));
        }
        if let Some(regs) = cp0_regs {
            entries.push((CP0_REGS_FILE, regs));
        }
        let cp0_maps_bytes: Option<&[u8]> = cp0_maps.map(|s| s.as_bytes());
        if let Some(bytes) = cp0_maps_bytes {
            entries.push((CP0_MAPS_FILE, bytes));
        }

        write_minimal_ctfs(&ct_path, &entries).unwrap();
        std::fs::read(&ct_path).unwrap()
    }

    /// Pure-function: decoding a compact 144-byte register payload must
    /// produce an `InitialRegisters` whose RIP matches the payload's
    /// 17th u64 (offset 128 inside the body).
    #[test]
    fn decode_first_thread_registers_compact_layout() {
        let expected = InitialRegisters {
            rax: 0x1111_1111_1111_1111,
            rbx: 0x2222_2222_2222_2222,
            rcx: 0x3333_3333_3333_3333,
            rdx: 0x4444_4444_4444_4444,
            rsi: 0x5555_5555_5555_5555,
            rdi: 0x6666_6666_6666_6666,
            rbp: 0x7777_7777_7777_7777,
            rsp: 0x8888_8888_8888_8888,
            r8: 0x9999_9999_9999_9999,
            r9: 0xaaaa_aaaa_aaaa_aaaa,
            r10: 0xbbbb_bbbb_bbbb_bbbb,
            r11: 0xcccc_cccc_cccc_cccc,
            r12: 0xdddd_dddd_dddd_dddd,
            r13: 0xeeee_eeee_eeee_eeee_u64,
            r14: 0x1234_5678_9abc_def0,
            r15: 0x0fed_cba9_8765_4321,
            rip: PC_ADD_BODY,
            rflags: 0x202,
        };
        let blob = pack_cp0_regs_compact(&expected);
        let decoded = decode_first_thread_registers(&blob).expect("compact layout must decode");
        assert_eq!(decoded, expected);
    }

    /// Pure-function: decoding the ptrace `user_regs_struct` layout must
    /// pick up RIP/RSP/RFLAGS/RAX from the right offsets.
    #[test]
    fn decode_first_thread_registers_user_struct_layout() {
        let blob = pack_cp0_regs_user_struct(
            /* rip */ PC_ADD_BODY,
            /* rsp */ 0xdead_beef,
            /* rflags */ 0x202,
            /* rax */ 0xfeed_face,
        );
        let decoded = decode_first_thread_registers(&blob).expect("user_regs_struct layout must decode");
        assert_eq!(decoded.rip, PC_ADD_BODY);
        assert_eq!(decoded.rsp, 0xdead_beef);
        assert_eq!(decoded.rflags, 0x202);
        assert_eq!(decoded.rax, 0xfeed_face);
    }

    /// Defensive: a truncated `cp0.regs` body returns `None` rather than
    /// reading past the end of the slice. Mirrors the recorder-side
    /// guard against partially-flushed sidecar files.
    #[test]
    fn decode_first_thread_registers_rejects_truncation() {
        // Outer header says 144 bytes follow but we only provide 16.
        let mut blob = vec![0u8; 8];
        blob[4..8].copy_from_slice(&144u32.to_le_bytes());
        blob.extend_from_slice(&[0u8; 16]);
        assert!(decode_first_thread_registers(&blob).is_none());

        // Empty input must also return None without panicking.
        assert!(decode_first_thread_registers(&[]).is_none());

        // Inner length = 0 means "no register data" — must also be None.
        let mut empty_inner = vec![0u8; 8];
        empty_inner[4..8].copy_from_slice(&0u32.to_le_bytes());
        assert!(decode_first_thread_registers(&empty_inner).is_none());
    }

    /// `install_memory_regions` must walk every well-formed
    /// `(address, size, bytes)` tuple, return a region count + total
    /// byte tally that matches the input, and tolerate a truncated tail
    /// rather than panic.
    #[test]
    fn install_memory_regions_parses_well_formed_tuples() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Reset the emulator before we install regions so this test's
        // diagnostics aren't polluted by leftover state from a sibling.
        // We also have to seed registers via `mcrSetRegisters` — the Nim
        // emulator's `mcrReadMemory` gates on `gInitialized` which only
        // flips true once registers are installed (see
        // `ct_emulator/src/ct_emulator/emulator_wasm_api.nim`).
        ensure_nim_runtime();
        unsafe { emulator_ffi::mcrInit() };

        let mut blob = pack_cp0_mem_region(0x4000_0000, &[0xab; 64]);
        blob.extend(pack_cp0_mem_region(0x5000_0000, &[0xcd; 32]));
        let (regions, bytes) = install_memory_regions(&blob);
        assert_eq!(regions, 2);
        assert_eq!(bytes, 96);

        // Flip `gInitialized` to true so the memory readback below is
        // permitted. The actual register values don't matter for the
        // assertion — we only need the gate flipped.
        unsafe {
            emulator_ffi::mcrSetRegisters(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        }

        // Reading back via `mcrReadMemory` should produce the original
        // bytes — proves the FFI handoff worked end-to-end.
        let mut read_back = [0u8; 64];
        let rc = unsafe {
            emulator_ffi::mcrReadMemory(
                0x4000_0000,
                read_back.as_mut_ptr(),
                read_back.len() as std::os::raw::c_int,
            )
        };
        assert_eq!(rc, 0, "mcrReadMemory must succeed for an installed region");
        assert!(
            read_back.iter().all(|&b| b == 0xab),
            "memory contents must round-trip verbatim"
        );
    }

    /// A truncated trailing tuple (size > bytes available) must not
    /// panic or claim the missing region; only the regions installed
    /// before the corrupt tail count.
    #[test]
    fn install_memory_regions_tolerates_truncated_tail() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        ensure_nim_runtime();
        unsafe { emulator_ffi::mcrInit() };

        let mut blob = pack_cp0_mem_region(0x6000_0000, &[0x11; 16]);
        // Append a header that claims 128 bytes but provide only 8.
        blob.extend_from_slice(&0x7000_0000u64.to_le_bytes());
        blob.extend_from_slice(&128u64.to_le_bytes());
        blob.extend_from_slice(&[0u8; 8]);
        let (regions, bytes) = install_memory_regions(&blob);
        assert_eq!(regions, 1, "only the well-formed leading region counts");
        assert_eq!(bytes, 16);
    }

    /// Headline acceptance: a CTFS container with cp0.regs + cp0.mem +
    /// debug.dat must seed the emulator so that `mcrGetPC` reflects the
    /// captured RIP and `load_callstack` returns a frame whose line was
    /// resolved by DWARF — not the M-DWARF-2 placeholder of 1.
    ///
    /// This is the milestone's end-to-end test: it covers the full
    /// "recorder → CTFS → replay → DAP stackTrace" data path.
    #[test]
    fn new_from_ctfs_bytes_seeds_pc_and_resolves_via_dwarf() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let regs = InitialRegisters {
            rax: 0xdeadbeef,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: 0,
            rsp: 0x7fff_0000_0000,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: PC_ADD_BODY,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        // A trivial 64-byte mock memory region at PC_ADD_BODY so the
        // installation path is exercised end-to-end. The DWARF resolver
        // never touches emulator memory — it works purely off the
        // bundled ELF — so the exact contents don't matter.
        let mem_regions = vec![(PC_ADD_BODY & !0xFFF, vec![0xCC; 4096])];
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &mem_regions, /* include_dwarf */ true);

        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        // After construction the emulator's PC must reflect the recorded
        // RIP (not the post-mcrInit zero).
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        assert_eq!(pc, PC_ADD_BODY, "mcrGetPC must report the recorded RIP");

        // RAX should round-trip — proves we installed all 18 GPRs, not
        // just RIP/RSP.
        let rax = unsafe { emulator_ffi::mcrGetRegister(0) };
        assert_eq!(rax, 0xdeadbeef);

        // load_callstack must walk the DWARF path: line ≠ 1.
        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty());
        let loc = &frames[0].content.call.location;
        assert_eq!(
            loc.line, PC_ADD_BODY_LINE,
            "DWARF resolver must override the M-DWARF-2 placeholder line=1 \
             once cp0.regs seeds the PC; got {loc:?}",
        );
        assert!(
            loc.path.ends_with("hello.c"),
            "DWARF-resolved file should override meta.paths[0]; got path={}",
            loc.path,
        );
        assert_eq!(loc.offset, PC_ADD_BODY as i64);
    }

    /// Missing cp0 files must not block session construction — older
    /// traces predate the M-Checkpoint-Replay milestone and must still
    /// come up (falling back to the M-DWARF-2 line=1 placeholder when
    /// the recorder didn't seed a PC).
    #[test]
    fn new_from_ctfs_bytes_without_cp0_falls_back() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(
            /* cp0_regs */ None,
            /* cp0_mem  */ &[],
            /* include_dwarf */ false,
        );
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        // No dwarf bundled either: location falls back to meta.paths[0]
        // / line=1.
        assert!(session.dwarf.is_none());
    }

    /// A corrupt cp0.regs must not abort session construction — the
    /// emulator should come up with zeroed registers and the M-DWARF-2
    /// fallback should still produce a well-formed location.
    #[test]
    fn new_from_ctfs_bytes_with_corrupt_cp0_regs_falls_back() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // 16 bytes of garbage: outer header reads tid=0xDEADBEEF /
        // reg_data_len=0xCAFEBABE but the body is empty. decode must
        // return None and the constructor must still succeed.
        let regs_blob = vec![
            0xef, 0xbe, 0xad, 0xde, 0xbe, 0xba, 0xfe, 0xca, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        ];
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &[], /* include_dwarf */ false);
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes)
            .expect("corrupt cp0.regs must not abort session construction");
        assert!(session.dwarf.is_none(), "no DWARF was bundled in this fixture");
    }

    // ── M-Replay-PC-Rebase fixtures ─────────────────────────────────────
    //
    // hello.elf's executable PT_LOAD lives at p_offset=0x1000, p_vaddr=
    // 0x401000, p_filesz=0x73. PC_ADD_BODY = 0x40100a sits in that
    // segment. Simulating ASLR is just a matter of picking a fake
    // runtime base address for the segment and constructing a
    // /proc/self/maps-style line that matches.
    //
    // We pick `0x5580aae45000` for the executable mapping start —
    // chosen to look like a real Linux ASLR-shifted address (the upper
    // half is in the 47-bit user space the kernel uses, the low nibble
    // is page-aligned).
    const FAKE_ASLR_EXEC_BASE: u64 = 0x5580_aae4_5000;
    /// `mapping.start - segment.p_vaddr` = 0x5580aae45000 - 0x401000.
    const FAKE_ASLR_REBASE_OFFSET: u64 = FAKE_ASLR_EXEC_BASE - 0x0040_1000;
    /// Runtime equivalent of `PC_ADD_BODY` after ASLR.
    const FAKE_ASLR_RUNTIME_PC: u64 = PC_ADD_BODY + FAKE_ASLR_REBASE_OFFSET;

    /// Build a synthetic `cp0.maps` blob that mimics what the recorder
    /// would emit for `/usr/local/bin/hello` after the kernel placed it
    /// at `FAKE_ASLR_EXEC_BASE`. Includes a leading r--p mapping at file
    /// offset 0 (the read-only PT_LOAD) and the r-xp mapping at file
    /// offset 0x1000 (the executable PT_LOAD), so the parser has to
    /// correctly pick the executable one.
    fn fake_cp0_maps_for_hello() -> String {
        // Lines are intentionally formatted like real `/proc/self/maps`
        // output, including a libc-like decoy entry to exercise the
        // "filter by pathname" logic.
        let ro_base = FAKE_ASLR_EXEC_BASE - 0x1000; // r--p PT_LOAD #0
        let mut s = String::new();
        s.push_str(&format!(
            "{ro_base:x}-{end:x} r--p 00000000 fe:01 12345 /usr/local/bin/hello\n",
            end = ro_base + 0x1000,
        ));
        s.push_str(&format!(
            "{exec:x}-{end:x} r-xp 00001000 fe:01 12345 /usr/local/bin/hello\n",
            exec = FAKE_ASLR_EXEC_BASE,
            end = FAKE_ASLR_EXEC_BASE + 0x1000,
        ));
        // Decoy libc-like entry — the parser must ignore it.
        s.push_str("7fa8b1a00000-7fa8b1a22000 r-xp 00010000 fe:01 67890 /nix/store/xyz/lib/libc.so.6\n");
        s
    }

    /// Pure-function: the parser must keep only r-xp entries that
    /// match the program path (or its basename).
    #[test]
    fn parse_executable_mappings_filters_by_program_and_perms() {
        let blob = fake_cp0_maps_for_hello();
        let mappings = parse_executable_mappings(&blob, "/usr/local/bin/hello");
        assert_eq!(mappings.len(), 1, "exactly one r-xp entry should match");
        assert_eq!(mappings[0].start, FAKE_ASLR_EXEC_BASE);
        assert_eq!(mappings[0].file_offset, 0x1000);
        assert_eq!(mappings[0].pathname, "/usr/local/bin/hello");

        // Empty program -> no match.
        let mappings = parse_executable_mappings(&blob, "/usr/local/bin/different");
        assert!(mappings.is_empty(), "non-matching program must yield no mappings");

        // Basename match still works when the recorder reported a
        // canonicalised path that differs from `meta.program`.
        let mappings = parse_executable_mappings(&blob, "hello");
        assert_eq!(mappings.len(), 1);
    }

    /// Pure-function: multiple r-xp mappings for the same program must
    /// sort so the lowest-start entry is the canonical load base.
    #[test]
    fn parse_executable_mappings_picks_lowest_start() {
        // Two r-xp entries for the same program with different start
        // addresses; the lower one is the canonical first PT_LOAD.
        let blob = "\
6000000000-6000001000 r-xp 00002000 fe:01 1 /opt/proggy\n\
5000000000-5000001000 r-xp 00001000 fe:01 1 /opt/proggy\n\
";
        let mut mappings = parse_executable_mappings(blob, "/opt/proggy");
        mappings.sort_by_key(|m| m.start);
        assert_eq!(mappings.len(), 2);
        assert_eq!(mappings[0].start, 0x50_0000_0000);
        assert_eq!(mappings[0].file_offset, 0x1000);
    }

    /// Pure-function: `compute_pc_rebase` must use
    /// `mapping.start - segment.p_vaddr` (with the segment selected by
    /// matching `p_offset` against the mapping's file offset).
    #[test]
    fn compute_pc_rebase_uses_segment_p_vaddr() {
        let mapping = ExecutableMapping {
            start: FAKE_ASLR_EXEC_BASE,
            file_offset: 0x1000,
            pathname: "/usr/local/bin/hello".to_owned(),
        };
        let offset = compute_pc_rebase(HELLO_ELF_FIXTURE, &mapping);
        // hello.elf's executable PT_LOAD has p_vaddr=0x401000, so
        // the rebase offset must be FAKE_ASLR_EXEC_BASE - 0x401000.
        assert_eq!(offset, FAKE_ASLR_REBASE_OFFSET);
        // Sanity: rebasing the fake runtime PC must land exactly on the
        // static PC_ADD_BODY — that's the whole point of this milestone.
        assert_eq!(FAKE_ASLR_RUNTIME_PC.wrapping_sub(offset), PC_ADD_BODY);
    }

    /// Headline acceptance: a CTFS container with cp0.maps simulating
    /// an ASLR-shifted load address must seed `pc_rebase` correctly so
    /// that `load_callstack` resolves the runtime PC via DWARF (line ≠ 1,
    /// path = hello.c) — proving the rebase path works end-to-end.
    #[test]
    fn new_from_ctfs_bytes_with_cp0_maps_rebases_pc_to_dwarf_line() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let regs = InitialRegisters {
            rax: 0xdeadbeef,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: 0,
            rsp: 0x7fff_0000_0000,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            // RIP is the ASLR-shifted runtime address — DWARF won't
            // resolve this directly. The rebase logic is the only
            // reason the assertion below can pass.
            rip: FAKE_ASLR_RUNTIME_PC,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        let maps_blob = fake_cp0_maps_for_hello();
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0_maps(
            Some(&regs_blob),
            &[],
            /* include_dwarf */ true,
            Some(&maps_blob),
        );

        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        assert_eq!(
            session.pc_rebase,
            Some(FAKE_ASLR_REBASE_OFFSET),
            "cp0.maps + bundled ELF should compute the rebase as mapping.start - segment.p_vaddr",
        );

        // mcrGetPC must reflect the raw runtime RIP — we do NOT rebase
        // inside the FFI surface, only at the DWARF query boundary.
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        assert_eq!(pc, FAKE_ASLR_RUNTIME_PC);

        // load_callstack must DWARF-resolve the rebased PC and surface
        // the recorded line (24 for PC_ADD_BODY in hello.c).
        let frames = session.load_callstack().expect("callstack must succeed");
        assert!(!frames.is_empty(), "expected at least one frame");
        let loc = &frames[0].content.call.location;
        assert_eq!(
            loc.line, PC_ADD_BODY_LINE,
            "DWARF must resolve the rebased PC to the recorded line; got loc = {loc:?}",
        );
        assert!(
            loc.path.ends_with("hello.c"),
            "DWARF-resolved file should override meta.paths[0]; got path={}",
            loc.path,
        );
        // The raw runtime PC must still flow through `Location.offset`
        // for diagnostics — the rebase only affects the DWARF lookup,
        // not the user-visible PC.
        assert_eq!(loc.offset, FAKE_ASLR_RUNTIME_PC as i64);
    }

    /// Without cp0.maps, the session must leave `pc_rebase = None` and
    /// the headline `seeds_pc_and_resolves_via_dwarf` test (which uses
    /// the static `PC_ADD_BODY` as the RIP) must still resolve — i.e.
    /// the absence of `cp0.maps` preserves the pre-M-Replay-PC-Rebase
    /// behaviour for traces that don't need rebasing.
    #[test]
    fn new_from_ctfs_bytes_without_cp0_maps_leaves_rebase_none() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: 0,
            rsp: 0x7fff_0000_0000,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: PC_ADD_BODY,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        // No cp0.maps argument: `synthetic_mcr_ctfs_bytes_with_cp0`
        // dispatches to the variant that writes none.
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &[], /* include_dwarf */ true);
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        assert!(
            session.pc_rebase.is_none(),
            "missing cp0.maps must leave pc_rebase = None"
        );
    }

    /// A cp0.maps that does not contain an entry for `meta.program`
    /// must collapse to `pc_rebase = None` (and emit a warning, which
    /// we do not assert on here — eprintln! is verified by reviewing
    /// logs, not test fixtures).
    #[test]
    fn new_from_ctfs_bytes_with_cp0_maps_missing_program_falls_back() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: 0,
            rsp: 0x7fff_0000_0000,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: PC_ADD_BODY,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        // Only a libc-like entry — none for /usr/local/bin/hello (which
        // is the program path baked into the fixture's meta).
        let maps_blob = "7fa8b1a00000-7fa8b1a22000 r-xp 00010000 fe:01 67890 /nix/store/xyz/lib/libc.so.6\n";
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0_maps(
            Some(&regs_blob),
            &[],
            /* include_dwarf */ true,
            Some(maps_blob),
        );
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        assert!(
            session.pc_rebase.is_none(),
            "cp0.maps without the program must leave pc_rebase = None"
        );
    }

    /// When the bundled ELF is missing but cp0.maps is present, the
    /// rebase falls back to `mapping.start` — correct for the common
    /// PIE case where the first executable PT_LOAD has `p_vaddr == 0`.
    #[test]
    fn compute_pc_rebase_falls_back_to_mapping_start_without_elf() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let maps_blob = fake_cp0_maps_for_hello();
        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: 0,
            rsp: 0x7fff_0000_0000,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: FAKE_ASLR_RUNTIME_PC,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0_maps(
            Some(&regs_blob),
            &[],
            /* include_dwarf */ false,
            Some(&maps_blob),
        );
        let session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        // Without the ELF we can't read p_vaddr, so the rebase collapses
        // to `mapping.start` — Some(FAKE_ASLR_EXEC_BASE).
        assert_eq!(session.pc_rebase, Some(FAKE_ASLR_EXEC_BASE));
    }

    // ── M-DWARF-4 fixtures ──────────────────────────────────────────────
    //
    // The CFI walker is exercised end-to-end against the same hello.elf
    // fixture by hand-crafting a synthetic stack inside `cp0.mem` so
    // the recorded RIP / RBP / stack contents represent
    // `add -> compute -> main` mid-execution.

    /// M-DWARF-4 acceptance: with a bundled `debug.dat` and a synthetic
    /// stack laid out per the hello.elf CFI rules, `load_callstack`
    /// must return three frames (add, compute, main) instead of just
    /// the innermost one.
    #[test]
    fn load_callstack_returns_multiple_frames_via_cfi_walk() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Synthetic stack layout — matches the same `a/b/c` chain used
        // by the unit test in `stack_unwinder.rs`. The stack lives in
        // a single 4 KB page so cp0.mem only needs one region.
        let stack_page_base: u64 = 0x7fff_ffff_0000;
        let a: u64 = stack_page_base + 0x100; // main's rbp
        let b: u64 = stack_page_base + 0x080; // compute's rbp
        let c: u64 = stack_page_base + 0x040; // add's rbp

        // Build a 4 KB buffer with the saved (rbp, ra) pairs at the
        // right offsets. Everything else stays zero.
        let mut page = vec![0u8; 4096];
        let put = |page: &mut Vec<u8>, addr: u64, val: u64| {
            let off = (addr - stack_page_base) as usize;
            page[off..off + 8].copy_from_slice(&val.to_le_bytes());
        };
        // main's frame: saved_rbp=0, ra=0 (top sentinel, walk stops).
        put(&mut page, a, 0);
        put(&mut page, a + 8, 0);
        // compute's frame: saved_rbp = main's rbp, ra back into main.
        put(&mut page, b, a);
        put(&mut page, b + 8, 0x40_105a);
        // add's frame: saved_rbp = compute's rbp, ra back into compute.
        put(&mut page, c, b);
        put(&mut page, c + 8, 0x40_103a);

        // RIP inside `add`'s body. RBP = c, RSP somewhere below c.
        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp: c,
            rsp: c - 0x20,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: PC_ADD_BODY,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        let mem_regions = vec![(stack_page_base, page)];
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &mem_regions, /* include_dwarf */ true);

        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");
        assert!(
            session.stack_unwinder.is_some(),
            "bundled debug.dat must populate the stack unwinder"
        );

        let frames = session.load_callstack().expect("callstack must succeed");
        // Expected chain: add -> compute -> main.
        assert!(
            frames.len() >= 3,
            "expected at least 3 frames from CFI walk, got {}: {:?}",
            frames.len(),
            frames.iter().map(|f| &f.content.call.raw_name).collect::<Vec<_>>(),
        );

        // Innermost frame: add at line 24.
        let f0 = &frames[0].content.call;
        assert_eq!(f0.location.line, PC_ADD_BODY_LINE, "frame 0 should be inside add()");
        assert_eq!(
            f0.raw_name, "add",
            "DWARF-resolved function name must surface as raw_name on the innermost frame",
        );

        // Frame 1: compute (RA = 0x40103a, which lives inside compute's body).
        let f1 = &frames[1].content.call;
        assert_eq!(
            f1.raw_name, "compute",
            "DWARF should name frame 1 `compute` (RA 0x40103a lies in compute)",
        );
        assert!(f1.location.path.ends_with("hello.c"));

        // Frame 2: main (RA = 0x40105a, inside main's body).
        let f2 = &frames[2].content.call;
        assert_eq!(
            f2.raw_name, "main",
            "DWARF should name frame 2 `main` (RA 0x40105a lies in main)",
        );
    }

    // ── M-Step-Stress fixtures ──────────────────────────────────────────
    //
    // The step-action tests reuse the hello.elf fixture but additionally
    // need the executable PT_LOAD bytes installed into the emulator so
    // `mcrStep` can actually decode and execute instructions.
    //
    // hello.elf layout (from `readelf -l`):
    //   PT_LOAD #0: file 0x0000..0x01c0 → vaddr 0x400000 (read-only)
    //   PT_LOAD #1: file 0x1000..0x1073 → vaddr 0x401000 (R+X, the .text)
    //   PT_LOAD #2: file 0x2000..0x2078 → vaddr 0x402000 (read-only data)
    //
    // For step-action tests we only need #1 — `add`, `compute`, `main`,
    // and `_start` all live there.

    const HELLO_TEXT_FILE_OFFSET: usize = 0x1000;
    const HELLO_TEXT_VADDR: u64 = 0x0040_1000;
    const HELLO_TEXT_SIZE: usize = 0x0073;

    /// PC at the function-entry of `compute` (hello.c line 28).
    const PC_COMPUTE_ENTRY: u64 = 0x0040_1020;
    /// PC at the `call <add>` instruction inside `compute` (line 29).
    const PC_COMPUTE_CALL_ADD: u64 = 0x0040_1035;
    /// PC at the start of hello.c line 30 (`return doubled;`) — the
    /// first source-line row after `compute`'s call to `add`. Per the
    /// `.debug_line` table, line 30 starts at PC 0x40103d, NOT
    /// 0x40103a (which is `mov [rbp-0x4], eax` — still part of line 29's
    /// "store the call return into the local").
    const PC_COMPUTE_LINE_30: u64 = 0x0040_103d;
    /// PC right after the `call <add>` instruction completes (the
    /// return address pushed by the call). Used by step-out fixtures
    /// to lay down a believable return address on the stack.
    const PC_COMPUTE_AFTER_CALL: u64 = 0x0040_103a;
    /// PC at the function-entry of `add` (hello.c line 23 prologue).
    const PC_ADD_ENTRY: u64 = 0x0040_1000;
    /// PC for hello.c line 25 (`return sum;`).
    const PC_ADD_RETURN_LINE: u64 = 0x0040_1015;
    /// Hello.c line 30: `return doubled;` — the line execution reaches
    /// when stepping over the `int doubled = add(...)` call.
    const HELLO_LINE_AFTER_CALL: i64 = 30;
    /// Hello.c line 29: `int doubled = add(x, x);` pre-call source.
    const HELLO_LINE_COMPUTE_CALL: i64 = 29;

    /// Stack page used by the M-Step-Stress fixtures.
    const STACK_PAGE_BASE: u64 = 0x7fff_0000_0000;
    const STACK_PAGE_SIZE: usize = 4096;
    /// Initial RSP: top of the stack page minus a small safety margin.
    /// The emulator only needs ~16 bytes for a CALL (8-byte return
    /// address) — we leave 0x100 to be safe in case future tests push
    /// locals.
    const STACK_INIT_RSP: u64 = STACK_PAGE_BASE + (STACK_PAGE_SIZE as u64) - 0x100;

    /// Install the hello.elf executable PT_LOAD into the emulator and
    /// allocate a 4 KB stack page at [`STACK_PAGE_BASE`].
    ///
    /// Returns the bytes of `cp0.mem` we'd ship inside the CTFS
    /// container so the same fixture works whether the test seeds via
    /// `new_from_ctfs_bytes` (production path) or directly via the FFI
    /// (faster, no temp-file dance).
    fn install_hello_text_and_stack() -> Vec<(u64, Vec<u8>)> {
        // Carve out the executable PT_LOAD bytes from the embedded ELF.
        let text = HELLO_ELF_FIXTURE[HELLO_TEXT_FILE_OFFSET..HELLO_TEXT_FILE_OFFSET + HELLO_TEXT_SIZE].to_vec();
        // Pad up to a page boundary so the emulator's page-aligned
        // bookkeeping has the full 4 KB to play with.
        let mut text_page = vec![0u8; 0x1000];
        text_page[..text.len()].copy_from_slice(&text);
        // Stack page is zeroed.
        let stack_page = vec![0u8; STACK_PAGE_SIZE];
        vec![(HELLO_TEXT_VADDR, text_page), (STACK_PAGE_BASE, stack_page)]
    }

    /// Build a CTFS payload that bundles hello.elf as `debug.dat`,
    /// installs the .text + stack via `cp0.mem`, and seeds the
    /// registers via `cp0.regs` with `rip`, `rsp`, and `rbp` taken
    /// from the caller. No `cp0.maps` — we want `pc_rebase = None`
    /// so the recorded PCs are already in the static address space
    /// (the fixture is non-PIE).
    fn synthetic_mcr_ctfs_bytes_for_step(rip: u64, rsp: u64, rbp: u64) -> Vec<u8> {
        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            // Pass `0x15` (21) as the first integer arg, matching what
            // `main` would have done — useful for the step-in test
            // where we land inside `add` after `compute` set up its
            // arguments.
            rdi: 0x15,
            rbp,
            rsp,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        let mem_regions = install_hello_text_and_stack();
        synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &mem_regions, /* include_dwarf */ true)
    }

    /// Convenience: a sane RBP somewhere in the stack page so that
    /// `compute`'s `[rbp-0x4]` / `[rbp-0x14]` accesses land on
    /// writable memory. Placed 0x100 below STACK_INIT_RSP so the
    /// red-zone and call-pushed return address can both fit.
    const STACK_INIT_RBP: u64 = STACK_INIT_RSP + 0x100;

    /// `step(_, false)` must surface a clear "reverse not supported"
    /// error so the DAP client can show a useful diagnostic.
    #[test]
    fn step_reverse_returns_err() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let mut session = EmulatorReplaySession::new();
        for action in [Action::StepIn, Action::Next, Action::StepOut, Action::Continue] {
            let err = session
                .step(action, false)
                .expect_err("reverse step must surface an error");
            let msg = err.to_string();
            assert!(
                msg.contains("reverse"),
                "error must mention reverse stepping; got `{msg}` for action {action:?}",
            );
        }
    }

    /// `add_breakpoint(hello.c, 24)` against a session with a bundled
    /// DWARF index must resolve to ≥1 static PC and stage it for the
    /// `Continue` action's hot path.
    #[test]
    fn add_breakpoint_resolves_to_known_pcs() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_with_dwarf();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let bp = session
            .add_breakpoint("hello.c", PC_ADD_BODY_LINE, None)
            .expect("add_breakpoint must succeed");
        assert!(bp.enabled, "freshly-added breakpoint must be enabled");
        assert!(
            session.breakpoint_static_pcs.contains(&PC_ADD_BODY),
            "breakpoint at hello.c:{PC_ADD_BODY_LINE} must resolve to PC_ADD_BODY ({:#x}); got set: {:?}",
            PC_ADD_BODY,
            session.breakpoint_static_pcs,
        );

        // Deleting the only breakpoint at this line must clear the PC
        // from the resolved set.
        session.delete_breakpoint(&bp).expect("delete_breakpoint must succeed");
        assert!(
            !session.breakpoint_static_pcs.contains(&PC_ADD_BODY),
            "after delete_breakpoint the PC must drop out of the resolved set",
        );

        // delete_breakpoints (plural) on a fresh, re-added breakpoint
        // must also empty the set.
        let _bp = session.add_breakpoint("hello.c", PC_ADD_BODY_LINE, None).unwrap();
        assert!(!session.breakpoint_static_pcs.is_empty());
        session.delete_breakpoints().unwrap();
        assert!(session.breakpoint_static_pcs.is_empty());
    }

    /// `step(Action::Next, true)` from PC_COMPUTE_CALL_ADD (line 29,
    /// the `call <add>` instruction) must land on line 30 — i.e. it
    /// must step **over** the call, not into `add`.
    ///
    /// The RSP heuristic is what makes this work: after `CALL` RSP
    /// drops by 8, so the step loop keeps stepping; only when the
    /// matching `RET` pops RSP back to its initial value does the
    /// loop allow itself to stop, and by then we are at line 30.
    #[test]
    fn step_over_advances_past_call_to_next_line() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_for_step(PC_COMPUTE_CALL_ADD, STACK_INIT_RSP, STACK_INIT_RBP);
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        // Sanity: we really are on line 29 before the step.
        let loc_before = session.build_location();
        assert_eq!(
            loc_before.line, HELLO_LINE_COMPUTE_CALL,
            "step-over precondition: must start on line {HELLO_LINE_COMPUTE_CALL}; got {loc_before:?}",
        );

        let advanced = session.step(Action::Next, true).expect("step must succeed");
        assert!(advanced, "step-over should report advancement");

        let loc_after = session.build_location();
        assert_eq!(
            loc_after.line, HELLO_LINE_AFTER_CALL,
            "step-over must skip past the call into hello.c:{HELLO_LINE_AFTER_CALL}; got {loc_after:?}",
        );
        // The step counter must have advanced (proves we ran real
        // instructions, not just shuffled state).
        assert!(
            session.current_step_id().0 > 0,
            "step counter must advance: got {:?}",
            session.current_step_id(),
        );
    }

    /// `step(Action::StepIn, true)` from PC_COMPUTE_CALL_ADD must end
    /// up inside `add()` — i.e. on a line within hello.c that is part
    /// of the `add` function (line 23..=25 depending on the prologue
    /// layout).
    #[test]
    fn step_in_enters_callee() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_for_step(PC_COMPUTE_CALL_ADD, STACK_INIT_RSP, STACK_INIT_RBP);
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let advanced = session.step(Action::StepIn, true).expect("step must succeed");
        assert!(advanced, "step-in should report advancement");

        // After step-in we must be inside `add` — function entry is
        // line 23 (declaration) or 24 (body) depending on which line
        // table row the prologue's first instruction maps to. Either
        // way the PC must lie inside `add`'s static range
        // [PC_ADD_ENTRY, PC_COMPUTE_ENTRY).
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        assert!(
            (PC_ADD_ENTRY..PC_COMPUTE_ENTRY).contains(&pc),
            "step-in must land inside add()'s static range; got pc={pc:#x}",
        );
        let loc = session.build_location();
        assert!(
            (23..=25).contains(&loc.line),
            "step-in target line must be inside add() (23..=25); got loc={loc:?}",
        );
    }

    /// `step(Action::StepOut, true)` from inside `add()` must return
    /// to `compute()` — RSP after the matching RET is strictly higher
    /// than at entry, and the line index lands inside `compute`'s
    /// static range.
    ///
    /// add()'s epilogue (from the objdump):
    ///   401015: mov  eax,DWORD PTR [rbp-0x4]   ; line 25 (uses rbp)
    ///   401018: pop  rbp                       ; line 26 (RSP += 8)
    ///   401019: xor  edx,edx                   ; (no source row)
    ///   40101b: xor  esi,esi
    ///   40101d: xor  edi,edi
    ///   40101f: ret                            ; pops return addr
    ///
    /// `add()` has no local-frame `sub rsp`, so at the post-prologue
    /// point (which is where line 25 lives) we have `RSP == RBP`. The
    /// layout that makes `pop rbp` + `ret` execute cleanly is:
    ///
    ///     [RBP - 0x18 .. RBP - 0x04]   ← red-zone locals (zeros OK)
    ///     [RBP]                        ← saved rbp pushed by prologue
    ///     [RBP + 0x08]                 ← return address pushed by CALL
    ///
    /// We seed RSP = RBP, lay sentinel saved-rbp + the real
    /// `PC_COMPUTE_AFTER_CALL` return address into the page (baked
    /// into the `cp0.mem` blob before the CTFS bundle is built — the
    /// emulator's region table does not support overwriting an
    /// already-installed page), and let the emulator execute through
    /// the epilogue.
    #[test]
    fn step_out_returns_to_caller() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Pick a comfortable rbp/rsp in the middle of the stack page
        // so the red-zone locals fit below and the saved-rbp+ra pair
        // fits above.
        let rbp: u64 = STACK_PAGE_BASE + 0x800;
        let rsp_entry: u64 = rbp; // add() has no `sub rsp` in its prologue.
        let saved_rbp: u64 = 0xdead_beef_cafe_babe;
        let return_addr: u64 = PC_COMPUTE_AFTER_CALL;

        // Build a stack page with the saved-rbp + return-address pair
        // baked in at the right offsets.
        let mut stack_page = vec![0u8; STACK_PAGE_SIZE];
        let rbp_off = (rbp - STACK_PAGE_BASE) as usize;
        stack_page[rbp_off..rbp_off + 8].copy_from_slice(&saved_rbp.to_le_bytes());
        stack_page[rbp_off + 8..rbp_off + 16].copy_from_slice(&return_addr.to_le_bytes());

        // Reuse `install_hello_text_and_stack` for the .text and then
        // swap in our pre-populated stack page.
        let mut mem = install_hello_text_and_stack();
        for entry in mem.iter_mut() {
            if entry.0 == STACK_PAGE_BASE {
                entry.1 = stack_page.clone();
            }
        }

        let regs = InitialRegisters {
            rax: 0,
            rbx: 0,
            rcx: 0,
            rdx: 0,
            rsi: 0,
            rdi: 0,
            rbp,
            rsp: rsp_entry,
            r8: 0,
            r9: 0,
            r10: 0,
            r11: 0,
            r12: 0,
            r13: 0,
            r14: 0,
            r15: 0,
            rip: PC_ADD_RETURN_LINE,
            rflags: 0x202,
        };
        let regs_blob = pack_cp0_regs_compact(&regs);
        let bytes = synthetic_mcr_ctfs_bytes_with_cp0(Some(&regs_blob), &mem, /* include_dwarf */ true);
        let mut sess = EmulatorReplaySession::new_from_ctfs_bytes(bytes).expect("CTFS load must succeed");

        let advanced = sess.step(Action::StepOut, true).expect("step must succeed");
        assert!(advanced, "step-out should report advancement");

        // Post-RET we must be inside `compute`'s static range
        // [PC_COMPUTE_ENTRY, PC_MAIN_ENTRY_HELLO).
        let pc = unsafe { emulator_ffi::mcrGetPC() };
        const PC_MAIN_ENTRY_HELLO: u64 = 0x0040_1048;
        assert!(
            (PC_COMPUTE_ENTRY..PC_MAIN_ENTRY_HELLO).contains(&pc),
            "step-out must return into compute()'s static range; got pc={pc:#x}",
        );
        let sp_after = unsafe { emulator_ffi::mcrGetSP() };
        assert!(
            sp_after > rsp_entry,
            "step-out must leave RSP strictly above the entry value (RET pops the return addr)",
        );
    }

    /// `step(Action::Continue, true)` must run until a breakpoint at a
    /// later line halts execution. We set a breakpoint at hello.c:30
    /// (PC_COMPUTE_AFTER_CALL), seed RIP at PC_COMPUTE_CALL_ADD (line
    /// 29), and continue. The emulator should execute the CALL, the
    /// callee's body, the RET, and stop at line 30.
    #[test]
    fn continue_halts_at_breakpoint() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_for_step(PC_COMPUTE_CALL_ADD, STACK_INIT_RSP, STACK_INIT_RBP);
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        // Set a breakpoint at hello.c:30 and confirm at least one PC
        // was resolved for it. The DWARF line table maps line 30 to
        // PC 0x40103d (the start of `return doubled;` after the
        // assignment to `doubled` is complete).
        let _bp = session
            .add_breakpoint("hello.c", HELLO_LINE_AFTER_CALL, None)
            .expect("breakpoint must register");
        assert!(
            session.breakpoint_static_pcs.contains(&PC_COMPUTE_LINE_30),
            "breakpoint at hello.c:{HELLO_LINE_AFTER_CALL} must resolve to PC_COMPUTE_LINE_30 ({:#x}); got set: {:?}",
            PC_COMPUTE_LINE_30,
            session.breakpoint_static_pcs,
        );

        let hit = session.step(Action::Continue, true).expect("continue must succeed");
        assert!(hit, "continue must report breakpoint hit");

        let pc = unsafe { emulator_ffi::mcrGetPC() };
        assert_eq!(
            pc, PC_COMPUTE_LINE_30,
            "continue must halt at PC_COMPUTE_LINE_30 ({:#x}); got pc={pc:#x}",
            PC_COMPUTE_LINE_30,
        );
        let loc = session.build_location();
        assert_eq!(
            loc.line, HELLO_LINE_AFTER_CALL,
            "continue's halt location must be hello.c:{HELLO_LINE_AFTER_CALL}; got loc={loc:?}",
        );
    }

    /// With no breakpoints registered, `Continue` must report
    /// `Ok(false)` (no breakpoint hit) rather than spinning forever.
    /// The bounded `MAX_STEP_INSTRUCTIONS` loop is what makes this
    /// safe.
    #[test]
    fn continue_with_no_breakpoints_reports_miss() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes_for_step(PC_COMPUTE_ENTRY, STACK_INIT_RSP, STACK_INIT_RBP);
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        // No add_breakpoint call: the resolved set is empty.
        let hit = session.step(Action::Continue, true).expect("continue must succeed");
        assert!(!hit, "continue with no breakpoints must report miss");
    }

    /// Without a bundled ELF, `load_callstack` must fall back to the
    /// pre-M-DWARF-4 single-frame contract — important so older traces
    /// that didn't ship a debug.dat still produce a frame the F5
    /// gateway-client can render.
    #[test]
    fn load_callstack_falls_back_to_single_frame_without_unwinder() {
        let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let bytes = synthetic_mcr_ctfs_bytes(); // no debug.dat, no cp0.regs
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();
        assert!(session.stack_unwinder.is_none(), "no debug.dat -> no CFI unwinder",);
        let frames = session.load_callstack().expect("callstack must succeed");
        assert_eq!(
            frames.len(),
            1,
            "without an unwinder we must surface the synthesised root frame only",
        );
        let raw_name = &frames[0].content.call.raw_name;
        assert!(
            !raw_name.is_empty(),
            "single-frame fallback must keep the F5 non-empty-name bar"
        );
    }
}
