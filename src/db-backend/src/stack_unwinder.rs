//! M-DWARF-4: multi-frame stack unwinding via DWARF CFI / `.eh_frame`.
//!
//! ## Purpose
//!
//! `EmulatorReplaySession::load_callstack` currently returns a single
//! synthetic frame derived from `meta.program` + DWARF line resolution
//! for the current PC. Real DAP UIs want the **full call stack**, e.g.
//! `inventory_service.processRequest → asyncdispatch.runForever →
//! __libc_start_main → _start`.
//!
//! `.eh_frame` (or `.debug_frame`) carries Call Frame Information (CFI):
//! rules that — given the current PC and register state — describe how
//! to recover the caller's PC, SP, and other registers. By walking
//! those rules iteratively from the current frame, we recover the full
//! call chain.
//!
//! ## Scope
//!
//! [`StackUnwinder`] owns the parsed `.eh_frame` / `.debug_frame`
//! sections plus the reusable `UnwindContext`. Its [`unwind`](
//! StackUnwinder::unwind) method walks the stack starting from an
//! initial PC + register file, calling back to read memory bytes on
//! demand.
//!
//! The unwinder is **deliberately decoupled** from `mcrReadMemory` and
//! the rest of the emulator FFI surface: `unwind` takes a closure for
//! memory reads so we can unit-test the entire unwind path against a
//! fake stack without touching the Nim runtime. The call-site in
//! `emulator_session.rs` plugs in `mcrReadMemory` via that closure.
//!
//! ## Register numbering bridge
//!
//! Two distinct register numbering schemes appear in this module:
//!
//! * **DWARF register numbers** for x86_64 (System V ABI, Figure 3.36):
//!   `0=rax, 1=rdx, 2=rcx, 3=rbx, 4=rsi, 5=rdi, 6=rbp, 7=rsp,
//!    8..15=r8..r15, 16=RA`. Note the `rdx/rcx/rbx` order.
//! * **mcrGetRegister indices** (what the emulator FFI uses):
//!   `0=rax, 1=rbx, 2=rcx, 3=rdx, 4=rsi, 5=rdi, 6=rbp, 7=rsp,
//!    8..15=r8..r15, 16=rip, 17=rflags`.
//!
//! [`MCR_REG_COUNT`] tracks the size of the mcr-indexed register slot
//! array we pass around (18). [`dwarf_to_mcr_index`] performs the
//! mapping for any DWARF register a CFI rule may reference.
//!
//! ## Edge cases
//!
//! * **Foreign frames**: when CFI lookup fails (e.g. we walked into
//!   libc and the bundled DWARF only covers the main binary), the
//!   unwinder stops cleanly and returns the frames it has so far. It
//!   does *not* error.
//! * **Leaf functions** without a frame pointer are handled the same
//!   way as any other CFI-described function: CFI's `cfa_offset` rules
//!   describe the canonical frame address relative to `rsp`, so leaf
//!   frames unwind correctly.
//! * **Prologue / epilogue PCs**: we rely exclusively on CFI rules at
//!   the precise PC the row's address range covers, never on naive
//!   `%rbp` chasing — so a PC mid-prologue (before `%rbp` is set up)
//!   or mid-epilogue (after `%rbp` is restored) produces the correct
//!   caller via the `(cfa=rsp+8)`-style rules gcc emits there.
//! * **Signal trampolines / PLT stubs** sometimes carry no FDE; those
//!   surface as `Err(NoUnwindInfoForAddress)` from gimli, which we
//!   treat as "stop unwinding here".
//! * **Cyclic / corrupt stacks**: the caller passes a `max_frames`
//!   cap (typically 64) and the unwinder bails when a step produces
//!   the same `(pc, cfa)` it saw last iteration.
//!
//! ## DWARF spec references
//!
//! * DWARF v5 §6.4 (Call Frame Information).
//! * System V ABI x86_64, §3.6.2 (DWARF Register Number Mapping).
//! * <https://refspecs.linuxfoundation.org/elf/x86_64-abi-0.99.pdf>

use std::borrow::Cow;
use std::sync::Arc;

use gimli::{
    BaseAddresses, CfaRule, DebugFrame, EhFrame, EndianArcSlice, Register, RegisterRule, RunTimeEndian, UnwindContext,
    UnwindSection,
};
use object::{Object, ObjectSection};

/// Internal alias — mirrors the reader type used by `dwarf_index.rs`.
type Reader = EndianArcSlice<RunTimeEndian>;

/// Number of mcr-indexed register slots: 18.
///
/// Matches the `REGISTER_NAMES` table in `emulator_session.rs` and the
/// `mcrGetRegister` index range. We keep our recovered register state
/// in this layout so the call-site can hand both initial and recovered
/// registers between iterations without re-mapping.
pub const MCR_REG_COUNT: usize = 18;

/// Convenient mcr-index constants for the registers we manipulate
/// directly while unwinding (RSP, RIP). All other register indices are
/// derived from DWARF register numbers via [`dwarf_to_mcr_index`].
const MCR_IDX_RBP: usize = 6;
const MCR_IDX_RSP: usize = 7;
const MCR_IDX_RIP: usize = 16;

/// DWARF register numbers we reference explicitly. The full mapping
/// lives in [`dwarf_to_mcr_index`].
const DWARF_REG_RA: u16 = 16;

/// Errors produced while constructing a [`StackUnwinder`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UnwindError {
    /// The input bytes are not a recognisable object file.
    Object(String),
    /// The binary parsed but neither `.eh_frame` nor `.debug_frame` is
    /// usable — typically a fully-stripped binary. A [`StackUnwinder`]
    /// is still constructed with empty sections; `unwind` will return
    /// only the initial frame in that case.
    #[allow(dead_code)]
    NoCfi,
}

impl std::fmt::Display for UnwindError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            UnwindError::Object(msg) => write!(f, "object parse error: {msg}"),
            UnwindError::NoCfi => write!(f, "no .eh_frame or .debug_frame in binary"),
        }
    }
}

impl std::error::Error for UnwindError {}

/// One frame recovered by the unwinder.
///
/// The runtime PC is what the user sees and what `Location.offset`
/// embeds; the static PC is what the DWARF line index expects (after
/// PC rebasing). Both are produced so the caller can avoid having to
/// know whether a rebase was applied.
#[derive(Debug, Clone, Copy)]
pub struct UnwoundFrame {
    /// Runtime PC for this frame (not rebased).
    pub pc: u64,
    /// Static PC for DWARF lookups (rebased — equal to `pc` if no
    /// rebase is in play).
    pub pc_static: u64,
    /// Canonical Frame Address — the value of `%rsp` just before the
    /// `call` that entered this frame.
    pub cfa: u64,
    /// Recovered register file in mcr index order. `None` means
    /// "register value unknown for this frame" (e.g. caller-saves not
    /// in the CFI rules).
    pub registers: [Option<u64>; MCR_REG_COUNT],
}

impl UnwoundFrame {
    /// Build the initial-frame entry from a raw register file.
    fn from_initial(pc: u64, pc_rebase: Option<u64>, regs: [u64; MCR_REG_COUNT]) -> Self {
        let pc_static = match pc_rebase {
            Some(offset) => pc.wrapping_sub(offset),
            None => pc,
        };
        let mut registers = [None; MCR_REG_COUNT];
        for (i, slot) in registers.iter_mut().enumerate() {
            *slot = Some(regs[i]);
        }
        Self {
            pc,
            pc_static,
            // We don't know the CFA of the innermost frame from CFI
            // alone — convention says it's `%rsp` at the entry of the
            // function, which is what the caller's stack pointer was
            // immediately after the `call`. For the top frame we just
            // surface the current `%rsp`.
            cfa: regs[MCR_IDX_RSP],
            registers,
        }
    }
}

/// Maps an x86_64 DWARF register number to the corresponding
/// `mcrGetRegister` index, or `None` if the register is not part of
/// the 18-slot mcr register file.
///
/// The mapping follows the System V ABI x86_64 Figure 3.36 ordering on
/// the DWARF side and the `REGISTER_NAMES` table in
/// `emulator_session.rs` on the mcr side. Note the rdx/rcx/rbx swap:
/// DWARF puts rdx at #1 / rcx at #2 / rbx at #3, while mcr puts rbx at
/// #1 / rcx at #2 / rdx at #3.
///
/// DWARF register #16 (Return Address column) maps to mcr #16 (rip)
/// because — by SysV convention on x86_64 — the return-address slot
/// shadows %rip in the CIE's `return_address_column` selection.
fn dwarf_to_mcr_index(reg: Register) -> Option<usize> {
    Some(match reg.0 {
        0 => 0,                   // rax
        1 => 3,                   // rdx (DWARF #1 -> mcr #3)
        2 => 2,                   // rcx
        3 => 1,                   // rbx (DWARF #3 -> mcr #1)
        4 => 4,                   // rsi
        5 => 5,                   // rdi
        6 => 6,                   // rbp
        7 => 7,                   // rsp
        8..=15 => reg.0 as usize, // r8..=r15 — DWARF and mcr both 8..15
        16 => 16,                 // RA / rip
        49 => 17,                 // rflags (rare in CFI rules but defined)
        _ => return None,
    })
}

/// Result of reading the caller's value for a single register.
///
/// Returned by [`recover_register`] so the caller can distinguish
/// "register is genuinely unknown" (no rule) from "memory read failed
/// while applying a rule" (treat as fatal for that frame).
enum RecoverOutcome {
    /// Register value was recovered successfully.
    Value(u64),
    /// The CFI rule for this register was `Undefined` (caller-clobbered).
    /// The slot is left as `None` in the result frame.
    Undefined,
    /// The rule referenced memory we could not read, or used a DWARF
    /// expression we don't evaluate. The slot is left as `None`.
    Unsupported,
}

/// The CFI walker.
///
/// One [`StackUnwinder`] per binary. Cheap to construct? No — the
/// inner `Arc<[u8]>` sections are sized to the binary's `.eh_frame` /
/// `.debug_frame` (typically tens to hundreds of KB). Pass
/// `&StackUnwinder` rather than cloning. Lifetime-free so a session
/// can hold an `Option<StackUnwinder>` field without lifetime juggling.
pub struct StackUnwinder {
    eh_frame: Option<EhFrame<Reader>>,
    debug_frame: Option<DebugFrame<Reader>>,
    bases: BaseAddresses,
}

impl std::fmt::Debug for StackUnwinder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // `EhFrame` / `DebugFrame` wrap a raw `Reader` whose `Debug`
        // impl prints the entire section bytes — useless and noisy.
        // Surface only "section present / absent" plus the bases, which
        // is enough for diagnostic logs and `expect_err` test failure
        // messages.
        f.debug_struct("StackUnwinder")
            .field("eh_frame", &self.eh_frame.is_some())
            .field("debug_frame", &self.debug_frame.is_some())
            .field("bases", &self.bases)
            .finish()
    }
}

impl StackUnwinder {
    /// Parse an ELF binary's CFI sections.
    ///
    /// Returns `Err` only for unrecognisable object files. A binary
    /// with no CFI sections succeeds with empty `eh_frame` /
    /// `debug_frame` slots — `unwind` then returns just the initial
    /// frame, matching the pre-M-DWARF-4 behaviour.
    ///
    /// We currently leave [`BaseAddresses`] at default. That works for
    /// `DW_EH_PE_absptr`-encoded FDEs (the standard x86_64 layout gcc
    /// emits at `-O0 -g`). PIE binaries with `DW_EH_PE_pcrel` FDEs
    /// would need `set_eh_frame` plumbing in a follow-up — but our
    /// hello.elf fixture (and the inventory_service binary the F5 path
    /// uses) emit absolute pointers, so this is enough for the current
    /// milestone.
    pub fn from_elf_bytes(bytes: &[u8]) -> Result<Self, UnwindError> {
        let object_file = object::File::parse(bytes).map_err(|e| UnwindError::Object(e.to_string()))?;
        let endian = if object_file.is_little_endian() {
            RunTimeEndian::Little
        } else {
            RunTimeEndian::Big
        };

        let load_named = |name: &str| -> (Reader, Option<u64>) {
            match object_file.section_by_name(name) {
                Some(section) => {
                    let data = section.uncompressed_data().unwrap_or(Cow::Borrowed(&[]));
                    let arc: Arc<[u8]> = Arc::from(data.into_owned().into_boxed_slice());
                    (EndianArcSlice::new(arc, endian), Some(section.address()))
                }
                None => {
                    let arc: Arc<[u8]> = Arc::from(Vec::new().into_boxed_slice());
                    (EndianArcSlice::new(arc, endian), None)
                }
            }
        };

        let (eh_bytes, eh_addr) = load_named(".eh_frame");
        let (dbg_bytes, _dbg_addr) = load_named(".debug_frame");
        let (_, text_addr) = load_named(".text");
        let (_, got_addr) = load_named(".got");

        // We construct the EhFrame / DebugFrame unconditionally —
        // empty sections behave correctly under
        // `unwind_info_for_address` (it returns
        // `NoUnwindInfoForAddress` for every input).
        let eh_frame = Some(EhFrame::from(eh_bytes));
        let debug_frame = Some(DebugFrame::from(dbg_bytes));

        // .eh_frame FDEs typically use PC-relative encoding
        // (`DW_EH_PE_pcrel`), which gimli interprets relative to the
        // section's *static* runtime address. We therefore set
        // `set_eh_frame` to the section's `address()` so gimli can
        // resolve pcrel pointers correctly. `.text` / `.got` follow
        // the same pattern for the rarer text- and GOT-relative
        // encodings — set them when available, fall back to
        // `BaseAddresses::default()` otherwise.
        let mut bases = BaseAddresses::default();
        if let Some(addr) = eh_addr {
            bases = bases.set_eh_frame(addr);
        }
        if let Some(addr) = text_addr {
            bases = bases.set_text(addr);
        }
        if let Some(addr) = got_addr {
            bases = bases.set_got(addr);
        }

        Ok(Self {
            eh_frame,
            debug_frame,
            bases,
        })
    }

    /// Walk the stack starting from `initial_pc` + `initial_regs`,
    /// returning at most `max_frames` frames.
    ///
    /// The returned vector always contains at least one frame (the
    /// initial frame), so callers always get something to display
    /// even when CFI is absent. Subsequent frames are added only when
    /// CFI rules successfully describe the caller; the walk stops on
    /// the first frame where:
    ///
    /// * The PC has no FDE (foreign frame, signal trampoline, PLT).
    /// * The CFA cannot be computed (no rule, expression we don't
    ///   evaluate).
    /// * The recovered RA / RSP would loop on the same frame.
    /// * `max_frames` is reached.
    ///
    /// `read_mem` is the bytes-fetching callback the unwinder uses
    /// when a CFI rule says "the previous value is at memory address
    /// CFA+N". Returning `Err(())` from the callback signals "address
    /// unreadable" — the unwinder treats that as a stop condition for
    /// the current register slot.
    pub fn unwind<F>(
        &self,
        initial_pc: u64,
        pc_rebase: Option<u64>,
        initial_regs: [u64; MCR_REG_COUNT],
        mut read_mem: F,
        max_frames: usize,
    ) -> Vec<UnwoundFrame>
    where
        F: FnMut(u64, &mut [u8]) -> Result<(), ()>,
    {
        let mut frames = Vec::new();
        if max_frames == 0 {
            return frames;
        }

        let mut current = UnwoundFrame::from_initial(initial_pc, pc_rebase, initial_regs);
        frames.push(current);

        // Reuse one UnwindContext across iterations — gimli encourages
        // this for heap-allocation reuse. The Box<...> wrapper is
        // gimli's recommended layout (the default `StoreOnHeap`
        // storage keeps the rule arrays on the heap).
        let mut ctx: UnwindContext<<Reader as gimli::Reader>::Offset> = UnwindContext::new();

        while frames.len() < max_frames {
            let Some(next) = self.try_unwind_one(&current, &mut ctx, &mut read_mem) else {
                break;
            };

            // Cycle detection: if `(pc, cfa)` repeats, we're stuck
            // (corrupt CFI or a stack we can't make progress on).
            if next.pc == current.pc && next.cfa == current.cfa {
                break;
            }
            // Saturation guard: a zero RA is the standard sentinel
            // that glibc's `__libc_start_main` leaves at the top of
            // the initial stack frame to mark "end of user stack".
            if next.pc == 0 {
                break;
            }

            frames.push(next);
            current = next;
        }

        frames
    }

    /// Single unwind step: takes the current frame and tries to
    /// produce the caller's frame. Returns `None` when CFI cannot
    /// describe the caller (foreign frame, missing rule, etc.) so the
    /// caller's loop can stop cleanly.
    fn try_unwind_one<F>(
        &self,
        current: &UnwoundFrame,
        ctx: &mut UnwindContext<<Reader as gimli::Reader>::Offset>,
        read_mem: &mut F,
    ) -> Option<UnwoundFrame>
    where
        F: FnMut(u64, &mut [u8]) -> Result<(), ()>,
    {
        // Look up the FDE that covers the static PC. The CFI walker
        // is fed the static address because FDEs encode addresses in
        // the static address space of the ELF.
        let pc_static = current.pc_static;

        // We try .eh_frame first (more common on Linux), then fall
        // through to .debug_frame. Either section's
        // `unwind_info_for_address` returns `NoUnwindInfoForAddress`
        // if no FDE covers `pc_static`; that's a normal "stop"
        // condition, not an error.
        let row_outcome = if let Some(eh) = &self.eh_frame {
            eh.unwind_info_for_address(&self.bases, ctx, pc_static, EhFrame::cie_from_offset)
                .ok()
                .map(|row| (row.cfa().clone(), collect_register_rules(row)))
        } else {
            None
        };
        let (cfa_rule, register_rules) = match row_outcome {
            Some(v) => v,
            None => {
                if let Some(df) = &self.debug_frame {
                    let row = df
                        .unwind_info_for_address(&self.bases, ctx, pc_static, DebugFrame::cie_from_offset)
                        .ok()?;
                    (row.cfa().clone(), collect_register_rules(row))
                } else {
                    return None;
                }
            }
        };

        // Compute the CFA from the current frame's registers.
        let cfa = match &cfa_rule {
            CfaRule::RegisterAndOffset { register, offset } => {
                let idx = dwarf_to_mcr_index(*register)?;
                let base = current.registers[idx]?;
                if *offset >= 0 {
                    base.checked_add(*offset as u64)?
                } else {
                    base.checked_sub((-*offset) as u64)?
                }
            }
            CfaRule::Expression(_) => {
                // DWARF expression CFA rules require an expression
                // evaluator we don't ship. Stop here rather than
                // guess.
                return None;
            }
        };

        // Apply each register rule to produce the caller's register
        // file. Any register without a rule inherits "undefined" =
        // caller-saved-not-preserved (None in the result).
        let mut next_regs: [Option<u64>; MCR_REG_COUNT] = [None; MCR_REG_COUNT];
        // The CFA itself is the caller's RSP — that's how SysV defines
        // it: CFA = value of %rsp just before the `call` instruction
        // ran in the caller.
        next_regs[MCR_IDX_RSP] = Some(cfa);

        for (reg, rule) in &register_rules {
            let Some(mcr_idx) = dwarf_to_mcr_index(*reg) else {
                continue;
            };
            match recover_register(rule, cfa, current, read_mem) {
                RecoverOutcome::Value(v) => next_regs[mcr_idx] = Some(v),
                RecoverOutcome::Undefined => next_regs[mcr_idx] = None,
                RecoverOutcome::Unsupported => next_regs[mcr_idx] = None,
            }
        }

        // The caller's PC is the recovered Return Address register
        // value (DWARF column 16). If no RA rule was emitted we
        // cannot unwind further.
        let ra_idx = dwarf_to_mcr_index(Register(DWARF_REG_RA))?;
        let caller_pc = next_regs[ra_idx]?;

        // Maintain RIP slot for consistency with the mcr register file.
        next_regs[MCR_IDX_RIP] = Some(caller_pc);

        // For any register the CFI didn't specify, propagate the
        // current value through — this matches the SysV "callee-saved
        // not changed" convention for registers not mentioned in a
        // rule. We skip this when a rule explicitly said
        // `Undefined` (next_regs already None for that slot, but a
        // missing rule means "preserved"). The CFI rule iteration
        // already covered explicit rules; here we fill in the
        // omissions with the current value as the conservative
        // default.
        for (idx, slot) in next_regs.iter_mut().enumerate() {
            if slot.is_none() && !rule_was_emitted(&register_rules, idx) {
                *slot = current.registers[idx];
            }
        }

        // The MCR_IDX_RSP slot we set above to `cfa` should stay as
        // the caller's RSP — `propagate` above won't overwrite it
        // because it's already Some. Same for RIP.

        // Compute the parent frame's static PC by re-applying the same
        // rebase delta this frame already carries. `pc - pc_static`
        // recovers the rebase offset; we then subtract it from the
        // caller's runtime PC. `wrapping_sub` keeps the math safe in
        // the degenerate "no rebase" case (delta == 0).
        let rebase_delta = current.pc.wrapping_sub(current.pc_static);
        let pc_static = caller_pc.wrapping_sub(rebase_delta);

        Some(UnwoundFrame {
            pc: caller_pc,
            pc_static,
            cfa,
            registers: next_regs,
        })
    }
}

/// Collect every `(register, rule)` pair from a row into an owned
/// `Vec`. We need the owned copy because we want to release the
/// borrow of `ctx` before we start computing the next frame's
/// registers (gimli's `UnwindTableRow` borrows from the context, and
/// we re-use the context on the next iteration).
fn collect_register_rules(
    row: &gimli::UnwindTableRow<<Reader as gimli::Reader>::Offset>,
) -> Vec<(Register, RegisterRule<<Reader as gimli::Reader>::Offset>)> {
    row.registers().map(|(reg, rule)| (*reg, rule.clone())).collect()
}

/// Returns `true` when the CFI row emitted any rule for the mcr-indexed
/// register `mcr_idx` — used to decide whether to propagate the current
/// frame's value when no rule was present.
fn rule_was_emitted(rules: &[(Register, RegisterRule<<Reader as gimli::Reader>::Offset>)], mcr_idx: usize) -> bool {
    rules.iter().any(|(reg, _)| dwarf_to_mcr_index(*reg) == Some(mcr_idx))
}

/// Apply a single [`RegisterRule`] using `cfa` plus the current
/// frame's register file. Memory-reading rules dispatch to
/// `read_mem`. Returns `RecoverOutcome::Value(_)` on success and
/// `Undefined` / `Unsupported` on the well-defined fallback paths.
fn recover_register<F>(
    rule: &RegisterRule<<Reader as gimli::Reader>::Offset>,
    cfa: u64,
    current: &UnwoundFrame,
    read_mem: &mut F,
) -> RecoverOutcome
where
    F: FnMut(u64, &mut [u8]) -> Result<(), ()>,
{
    match rule {
        RegisterRule::Undefined => RecoverOutcome::Undefined,
        RegisterRule::SameValue => {
            // "Same as in the current frame" — caller-preserved.
            // We don't know which mcr slot this rule belongs to from
            // here; the caller will overwrite it in the propagation
            // pass. Return Unsupported so the next_regs slot stays
            // None and the propagation pass picks up the current
            // value (which is the SameValue contract anyway).
            RecoverOutcome::Unsupported
        }
        RegisterRule::Offset(off) => {
            let addr = if *off >= 0 {
                cfa.checked_add(*off as u64)
            } else {
                cfa.checked_sub((-*off) as u64)
            };
            let Some(addr) = addr else {
                return RecoverOutcome::Unsupported;
            };
            let mut buf = [0u8; 8];
            if read_mem(addr, &mut buf).is_err() {
                return RecoverOutcome::Unsupported;
            }
            RecoverOutcome::Value(u64::from_le_bytes(buf))
        }
        RegisterRule::ValOffset(off) => {
            // The value (not the address) is `CFA + offset`.
            let v = if *off >= 0 {
                cfa.checked_add(*off as u64)
            } else {
                cfa.checked_sub((-*off) as u64)
            };
            match v {
                Some(v) => RecoverOutcome::Value(v),
                None => RecoverOutcome::Unsupported,
            }
        }
        RegisterRule::Register(other) => {
            // "Previous value lives in register R."
            match dwarf_to_mcr_index(*other).and_then(|i| current.registers[i]) {
                Some(v) => RecoverOutcome::Value(v),
                None => RecoverOutcome::Unsupported,
            }
        }
        // The remaining rule variants (Expression, ValExpression,
        // Architectural, Constant) are either expression-driven or
        // ABI-specific. Surface them as unsupported and let the
        // propagation pass apply the conservative fallback.
        _ => RecoverOutcome::Unsupported,
    }
}

// Silence unused-warning for MCR_IDX_RBP — it's exported as a constant
// to make the rdx/rcx/rbx mapping documentation self-contained, but
// the unwinder itself doesn't reference it directly (rbp is handled
// generically by `dwarf_to_mcr_index`).
const _: usize = MCR_IDX_RBP;

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    /// Pre-built ELF fixture; see `tests/fixtures/dwarf/hello.c` and
    /// `tests/fixtures/dwarf/rebuild.sh` for the source and build
    /// recipe. Contains three functions (`add`, `compute`, `main`)
    /// compiled with `-O0 -g`, each with the standard gcc CFI
    /// prologue/epilogue rules.
    const FIXTURE_ELF: &[u8] = include_bytes!("../tests/fixtures/dwarf/hello.elf");

    /// PC inside `add`'s body — past the prologue, so CFI says
    /// `cfa = rbp + 16` and RA lives at `[cfa-8]`.
    const PC_ADD_BODY: u64 = 0x40100a;

    /// PC inside `compute`'s body — same rule shape as `add`.
    const PC_COMPUTE_BODY: u64 = 0x40102b;

    /// PC inside `main`'s body — top of the user-visible call chain.
    const PC_MAIN_BODY: u64 = 0x401050;

    /// Verify the DWARF↔mcr register mapping table.
    ///
    /// This is the most failure-prone part of the milestone (the
    /// rdx/rcx/rbx swap is easy to get wrong); a dedicated unit test
    /// is cheap insurance.
    #[test]
    fn dwarf_to_mcr_index_handles_swap() {
        // GPRs in DWARF order: rax, rdx, rcx, rbx
        assert_eq!(dwarf_to_mcr_index(Register(0)), Some(0)); // rax
        assert_eq!(dwarf_to_mcr_index(Register(1)), Some(3)); // rdx (note swap)
        assert_eq!(dwarf_to_mcr_index(Register(2)), Some(2)); // rcx
        assert_eq!(dwarf_to_mcr_index(Register(3)), Some(1)); // rbx (note swap)
        // rsi/rdi/rbp/rsp
        assert_eq!(dwarf_to_mcr_index(Register(4)), Some(4)); // rsi
        assert_eq!(dwarf_to_mcr_index(Register(5)), Some(5)); // rdi
        assert_eq!(dwarf_to_mcr_index(Register(6)), Some(6)); // rbp
        assert_eq!(dwarf_to_mcr_index(Register(7)), Some(7)); // rsp
        // r8..=r15 pass-through.
        assert_eq!(dwarf_to_mcr_index(Register(8)), Some(8));
        assert_eq!(dwarf_to_mcr_index(Register(15)), Some(15));
        // Return address column = 16 -> rip slot 16.
        assert_eq!(dwarf_to_mcr_index(Register(16)), Some(16));
        // Vector and segment registers — not in our 18-slot file.
        assert_eq!(dwarf_to_mcr_index(Register(17)), None); // xmm0
        assert_eq!(dwarf_to_mcr_index(Register(54)), None); // %fs
    }

    /// A fresh unwinder must parse the hello.elf fixture without error.
    #[test]
    fn unwinder_constructs_from_fixture() {
        let _ = StackUnwinder::from_elf_bytes(FIXTURE_ELF).expect("hello.elf must parse");
    }

    /// Garbage bytes must surface as `UnwindError::Object`. We don't
    /// silently downgrade to an empty unwinder in the public API;
    /// `from_elf_bytes_lossy`-style fallback lives in the call site
    /// (`emulator_session.rs`).
    #[test]
    fn unwinder_rejects_garbage_input() {
        let err = StackUnwinder::from_elf_bytes(b"not an ELF").expect_err("must reject garbage");
        assert!(matches!(err, UnwindError::Object(_)));
    }

    /// With a PC outside any FDE, `unwind` must return just the
    /// initial frame — no crash, no extra frames synthesised.
    #[test]
    fn unwind_with_pc_outside_fdes_returns_only_initial_frame() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();
        let mut regs = [0u64; MCR_REG_COUNT];
        regs[MCR_IDX_RSP] = 0x7fff_0000_0000;
        let frames = unwinder.unwind(0xdead_beef_cafe_babe, None, regs, |_, _| Err(()), 64);
        assert_eq!(frames.len(), 1, "no FDE coverage: only the seed frame survives");
        assert_eq!(frames[0].pc, 0xdead_beef_cafe_babe);
    }

    /// `max_frames = 0` must return an empty vector without crashing.
    #[test]
    fn unwind_with_zero_max_frames_returns_empty() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();
        let regs = [0u64; MCR_REG_COUNT];
        let frames = unwinder.unwind(PC_ADD_BODY, None, regs, |_, _| Err(()), 0);
        assert!(frames.is_empty());
    }

    /// Headline test: hand-craft a synthetic stack that looks like
    /// `_start -> main -> compute -> add` and prove the unwinder
    /// recovers all three caller frames.
    ///
    /// The trick is to seed the emulator's memory and registers such
    /// that the CFI rules for hello.elf's `.eh_frame` produce the
    /// expected chain when applied iteratively.
    ///
    /// Stack layout (high → low addresses, x86_64 calls push the RA
    /// then the caller's saved RBP):
    ///
    /// ```text
    ///   stack_top   <- _start_ra (synthetic; CFI lookup will fail
    ///                  here, ending the walk cleanly)
    ///   stack_top-8 <- saved_rbp_of_main (we set 0 — irrelevant
    ///                  because we never unwind past _start)
    ///   ...
    /// ```
    ///
    /// We don't actually need to model `_start`'s frame explicitly:
    /// the unwinder will hit a PC of zero (the canonical "end of
    /// user stack" sentinel glibc plants there) and stop.
    #[test]
    fn unwind_recovers_three_caller_frames_through_synthetic_stack() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();

        // We pick a 64 KB synthetic stack region. The CFI rules in
        // hello.elf reference `[cfa-8]` for the saved RA and
        // `[cfa-16]` for the saved RBP, where `cfa` is `rbp + 16`
        // (after the standard prologue sequence). So the stack
        // layout we want is:
        //
        //   higher addresses
        //     [stack_base + 56]  : 0  (RA from _start to libc — stops walk)
        //     [stack_base + 48]  : 0  (saved rbp at main level — irrelevant)
        //   main's CFA = stack_base + 56
        //   main's RBP = stack_base + 40  (so [rbp+8] == RA == 0)
        //     [stack_base + 40]  : stack_base + 48     (saved rbp from compute)
        //   compute's CFA = main's RBP + 16 = stack_base + 56  WRONG
        //
        // Wait — that's wrong. Let me reconsider: when a function is
        // called, the call pushes the RA so the callee's initial
        // %rsp points to the RA. After `push %rbp; mov %rsp, %rbp`
        // the callee's RBP = its own initial RSP - 8. So in the
        // callee's body:
        //
        //   [rbp+8] = RA   (cfa-8 for cfa = rbp+16)
        //   [rbp+0] = saved RBP of caller   (cfa-16)
        //
        // The caller's RBP and the callee's RBP are linked through
        // the [rbp+0] slot. Chain:
        //
        //   main's RBP    = A
        //   At [A]:       saved RBP of _start  (= 0 — top of stack)
        //   At [A+8]:     RA from main back to _start
        //
        //   compute's RBP = B
        //   At [B]:       A        (saved RBP of main)
        //   At [B+8]:     RA back to main = 0x40105a (after `call compute`)
        //
        //   add's RBP     = C
        //   At [C]:       B        (saved RBP of compute)
        //   At [C+8]:     RA back to compute = 0x40103a (after `call add`)
        //
        // We pick addresses in a high-stack-like region:
        let stack_base: u64 = 0x7fff_0000_0000;
        let a: u64 = stack_base + 0x100; // main's rbp
        let b: u64 = stack_base + 0x80; // compute's rbp
        let c: u64 = stack_base + 0x40; // add's rbp

        // Build the synthetic memory image. We store as a HashMap
        // keyed on 8-byte-aligned addresses so the read closure can
        // service arbitrary reads.
        use std::collections::HashMap;
        let mut mem: HashMap<u64, u64> = HashMap::new();
        // main's frame
        mem.insert(a, 0); // saved RBP = 0 (top sentinel)
        mem.insert(a + 8, 0); // RA = 0 (top sentinel) — walk stops
        // here cleanly.
        // compute's frame
        mem.insert(b, a); // saved RBP = main's rbp
        mem.insert(b + 8, 0x40105a); // RA back into main (after `call compute`)
        // add's frame
        mem.insert(c, b); // saved RBP = compute's rbp
        mem.insert(c + 8, 0x40103a); // RA back into compute (after `call add`)

        // Innermost frame: we are paused inside `add`'s body. CFI
        // says cfa = rbp + 16, so the innermost RBP = C, RSP =
        // anywhere below C (doesn't matter for CFI-based unwind
        // since `cfa` is computed from rbp).
        let mut regs = [0u64; MCR_REG_COUNT];
        regs[MCR_IDX_RBP] = c;
        regs[MCR_IDX_RSP] = c - 0x20; // some room below saved RBP

        let frames = unwinder.unwind(
            PC_ADD_BODY,
            None,
            regs,
            |addr, buf| {
                // Service only 8-byte aligned reads to the addresses
                // we populated. Any other address: error.
                if buf.len() != 8 {
                    return Err(());
                }
                match mem.get(&addr) {
                    Some(&v) => {
                        buf.copy_from_slice(&v.to_le_bytes());
                        Ok(())
                    }
                    None => Err(()),
                }
            },
            16,
        );

        // Expected chain: add (initial) -> compute -> main -> (stop
        // because RA=0). That's three frames in the result vec.
        assert_eq!(
            frames.len(),
            3,
            "expected add -> compute -> main, got {} frames: {:?}",
            frames.len(),
            frames.iter().map(|f| f.pc).collect::<Vec<_>>(),
        );
        assert_eq!(frames[0].pc, PC_ADD_BODY, "frame 0 must be the seed (add)");
        assert_eq!(frames[1].pc, 0x40103a, "frame 1 must be the caller of add (compute)");
        assert_eq!(frames[2].pc, 0x40105a, "frame 2 must be the caller of compute (main)");
        // PC_COMPUTE_BODY and PC_MAIN_BODY are nearby — sanity check
        // that they're in the same function as the recovered RAs.
        assert!(frames[1].pc < PC_COMPUTE_BODY + 0x100);
        assert!(frames[2].pc < PC_MAIN_BODY + 0x100);
    }

    /// `pc_rebase = Some(delta)` must shift the static PC of every
    /// frame by the same amount. Important because the live emulator
    /// path always sets a rebase offset for PIE binaries.
    #[test]
    fn unwind_applies_pc_rebase_to_initial_frame() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();
        let rebase = 0x5580_0000_0000;
        let runtime_pc = PC_ADD_BODY + rebase;
        let mut regs = [0u64; MCR_REG_COUNT];
        regs[MCR_IDX_RBP] = 0x7000;
        regs[MCR_IDX_RSP] = 0x6000;

        let frames = unwinder.unwind(
            runtime_pc,
            Some(rebase),
            regs,
            // No memory reads expected to succeed past frame 0
            // because RBP -> [rbp+0..8] returns Err — so the result
            // collapses to just the seed frame.
            |_, _| Err(()),
            8,
        );
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].pc, runtime_pc);
        assert_eq!(frames[0].pc_static, PC_ADD_BODY);
    }

    /// When the memory-read callback rejects every address (e.g. the
    /// synthetic stack memory is not installed), unwind must still
    /// return the initial frame and not panic.
    #[test]
    fn unwind_handles_memory_read_failure_gracefully() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();
        let mut regs = [0u64; MCR_REG_COUNT];
        regs[MCR_IDX_RBP] = 0x7000;
        regs[MCR_IDX_RSP] = 0x6000;
        let frames = unwinder.unwind(PC_ADD_BODY, None, regs, |_, _| Err(()), 4);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].pc, PC_ADD_BODY);
    }

    /// A PC that lands inside `_start` (which hello.elf does NOT emit
    /// CFI for — see the `readelf --debug-dump=frames` output) must
    /// terminate the walk with just the seed frame. This mirrors the
    /// "foreign frame" case where we walk off the binary into libc.
    #[test]
    fn unwind_pc_in_uncovered_region_returns_only_seed() {
        let unwinder = StackUnwinder::from_elf_bytes(FIXTURE_ELF).unwrap();
        // 0x401062 = _start, which has no FDE in hello.elf.
        let mut regs = [0u64; MCR_REG_COUNT];
        regs[MCR_IDX_RBP] = 0x7000;
        regs[MCR_IDX_RSP] = 0x6000;
        let frames = unwinder.unwind(0x401062, None, regs, |_, _| Err(()), 8);
        assert_eq!(frames.len(), 1);
    }
}
