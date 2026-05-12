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
use std::collections::HashMap;
use std::error::Error;
use std::sync::Once;

use crate::ctfs_trace_reader::ctfs_container::CtfsReader;
use crate::ctfs_trace_reader::meta_dat::{parse_meta_dat, MetaDat};
use crate::db::DbRecordEvent;
use crate::dwarf_index::{DwarfIndex, PcInfo};
use crate::emulator_ffi;
use crate::expr_loader::ExprLoader;
use crate::lang::Lang;
use crate::replay::ReplaySession;
use crate::task::{
    Action, Breakpoint, Call, CallLine, CtLoadLocalsArguments, Events, HistoryResultWithRecord, LoadHistoryArg,
    Location, ProgramEvent, RRTicks, VariableWithRecord, NO_ADDRESS, NO_EVENT, NO_POSITION,
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
}

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
                program: String::new(),
                args: Vec::new(),
                workdir: String::new(),
                recorder_id: String::new(),
                paths: Vec::new(),
                mcr: None,
            },
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf: None,
        }
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

        let meta_bytes = ctfs
            .read_file("meta.dat")
            .map_err(|e| ctfs_error(format!("meta.dat missing from CTFS container: {e}")))?;
        let meta = parse_meta_dat(&meta_bytes).map_err(|e| ctfs_error(format!("meta.dat parse failed: {e}")))?;

        if meta.mcr.is_none() {
            return Err(ctfs_error(
                "EmulatorReplaySession requires meta.dat with FLAG_HAS_MCR_FIELDS set",
            ));
        }

        // M-DWARF-3: look for the recorder-bundled binary (`debug.dat`).
        // Missing is fine — older traces predate the bundling step, and
        // stripped binaries skip the bundle on the recorder side. Parse
        // failures are tolerated identically so a corrupt bundle never
        // prevents the session from coming up at all; the session just
        // falls back to the M-DWARF-2 placeholder location.
        let dwarf = match ctfs.read_file(BUNDLED_DEBUG_FILE) {
            Ok(elf_bytes) if !elf_bytes.is_empty() => match DwarfIndex::from_elf_bytes(&elf_bytes) {
                Ok(index) => Some(index),
                Err(e) => {
                    eprintln!(
                        "warning: EmulatorReplaySession could not parse bundled `{BUNDLED_DEBUG_FILE}` \
                         ({e}); falling back to placeholder line numbers"
                    );
                    None
                }
            },
            // Either the file isn't present (older trace) or it's empty.
            // Both are silent fallbacks — they are the documented
            // graceful-degradation contract for M-DWARF-3.
            _ => None,
        };

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

        Ok(Self {
            meta,
            breakpoints: HashMap::new(),
            next_breakpoint_id: 1,
            breakpoints_enabled: true,
            current_step_id: StepId(0),
            dwarf,
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
    fn allocate_breakpoint(&mut self, path: &str, line: i64) -> Breakpoint {
        let breakpoint = Breakpoint {
            id: self.next_breakpoint_id,
            enabled: self.breakpoints_enabled,
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
        if let Some(first) = self.meta.paths.first() {
            if !first.is_empty() {
                return first.clone();
            }
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
        dwarf.resolve_pc(pc)
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

    fn step(&mut self, _action: Action, _forward: bool) -> Result<bool, Box<dyn Error>> {
        // Drive one instruction. The emulator only steps forward; reverse
        // execution requires snapshots that this build does not yet have.
        // We swallow non-zero return codes because the F5 happy-path
        // never actually loads code to step over — the call exists so
        // that the DAP `next`/`stepIn` handlers don't blow up on an
        // unhandled `todo!()` when the user presses a step button on an
        // emulator-backed trace.
        //
        // SAFETY: `mcrStep` only reads/writes the Nim-managed emulator
        // globals seeded by `mcrInit` (and optionally `mcrSetRegisters`).
        let _ = unsafe { emulator_ffi::mcrStep() };
        // Mirror the emulator counter so subsequent `current_step_id`
        // calls return the updated value.
        // SAFETY: same as above.
        let counter = unsafe { emulator_ffi::mcrGetStepCounter() };
        self.current_step_id = StepId(counter as i64);
        Ok(true)
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
        // Synthesise a single root frame. `load_callstack` is what feeds
        // DAP `stackTrace`, so producing one frame with a non-empty
        // function name (and a sensible source path) is the F5
        // acceptance bar.
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
        Ok(vec![CallLine::call(
            call, /* hidden_children */ false, /* count */ 0, 0,
        )])
    }

    fn load_history(&mut self, _arg: &LoadHistoryArg) -> Result<(Vec<HistoryResultWithRecord>, i64), Box<dyn Error>> {
        todo!("F5c-3: build per-line history from emulator trace")
    }

    fn add_breakpoint(&mut self, path: &str, line: i64) -> Result<Breakpoint, Box<dyn Error>> {
        // The dap_handler shim (`dap_handler::set_breakpoints`, around
        // line 1294) reports `verified: true` whenever `add_breakpoint`
        // returns `Ok`. So all we need to do here is mint a new id and
        // remember the entry so `delete_breakpoint` can find it.
        Ok(self.allocate_breakpoint(path, line))
    }

    fn delete_breakpoint(&mut self, breakpoint: &Breakpoint) -> Result<bool, Box<dyn Error>> {
        for entries in self.breakpoints.values_mut() {
            if let Some(pos) = entries.iter().position(|b| b.id == breakpoint.id) {
                entries.remove(pos);
                return Ok(true);
            }
        }
        // Mirror MaterializedReplaySession: unknown id is an error so the
        // GUI can surface a diagnostic instead of silently no-ooping.
        Err(format!("breakpoint id {} not found", breakpoint.id).into())
    }

    fn delete_breakpoints(&mut self) -> Result<bool, Box<dyn Error>> {
        self.breakpoints.clear();
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
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::ctfs_trace_reader::ctfs_container::write_minimal_ctfs;
    use crate::ctfs_trace_reader::meta_dat::{serialize_meta_dat, McrFields, FLAG_HAS_MCR_FIELDS, META_DAT_VERSION};

    /// Build a synthetic CTFS payload with the `FlagHasMcrFields` bit set
    /// and a plausible meta block. We don't need real checkpoint streams
    /// to exercise the F5c-3 trait surface — the meta block alone is
    /// enough for `load_location` / `load_callstack` to synthesise a
    /// non-empty frame.
    fn synthetic_mcr_ctfs_bytes() -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: 0,
            program: "/usr/bin/ruby".to_owned(),
            args: vec!["script.rb".to_owned()],
            workdir: "/srv/proj".to_owned(),
            recorder_id: "ruby".to_owned(),
            paths: vec!["script.rb".to_owned()],
            mcr: None,
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
        let bytes = synthetic_mcr_ctfs_bytes();
        let mut session = EmulatorReplaySession::new_from_ctfs_bytes(bytes).unwrap();

        let bp = session
            .add_breakpoint("src/main.c", 42)
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
    fn synthetic_mcr_ctfs_bytes_with_cp0(
        cp0_regs: Option<&[u8]>,
        cp0_mem_regions: &[(u64, Vec<u8>)],
        include_dwarf: bool,
    ) -> Vec<u8> {
        let meta = MetaDat {
            version: META_DAT_VERSION,
            flags: FLAG_HAS_MCR_FIELDS,
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
        let _guard = FFI_TEST_LOCK.lock().unwrap();
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
}
