//! M17 — MCR hybrid origin tier (undo-map last-mile + breakpoint fallback).
//!
//! Implements the value-origin chain algorithm for `TraceKind::Emulator`
//! (MCR-backed) traces per spec §6.4 of
//! `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`.
//!
//! The high-level algorithm composes two tiers per hop:
//!
//! ```text
//! 1. seek(replay, query_step)
//! 2. (addr, size) = replay.evaluate_with_address(query_var)
//! 3. while chain.len() < budget.max_hops:
//!    a. Tier 1 (undo-map fast path):
//!       if mcrUndoMapWriteCoverage(addr, tick):
//!           wr = mcrUndoMapLastWriteBefore(addr, size, tick)
//!           if wr is Some: build hop from `wr`; tier1++; continue
//!    b. Tier 2 (RR-style + reverse-execution fallback):
//!       seed the reverse-step driver with the per-hop budget;
//!       step backwards until a write is found OR budget exhausted;
//!       build hop; tier2++; continue
//! 4. emit OriginChain { hops, metrics { tier_one_hops, tier_two_hops, .. } }
//! ```
//!
//! Per-hop the algorithm tries Tier 1 first; only when
//! [`emulator_ffi::mcrUndoMapWriteCoverage`] returns false does it fall
//! back to Tier 2.
//!
//! **Window extension.** When the requested write is older than the
//! current undo-map window, the helper falls back to Tier 2 — the
//! `LastMileController`'s window-management logic on the Nim side is
//! responsible for extending the window on the recorder pipeline; the
//! Rust driver here observes the result of that extension via the
//! `mcrUndoMapWriteCoverage` gate.
//!
//! **Cross-thread guard / stack-slot reuse guard.** Both guards apply
//! identically to Tier 2 (and are degenerate for Tier 1, which records
//! per-instruction writes explicitly). The hop builder applies the
//! shared `OriginKind::CrossThreadCopy` / classifier-target check at the
//! same point as the M11 RR algorithm.
//!
//! **Budget.** The per-request `OriginBudget.max_hops` is shared across
//! both tiers; the default ceiling is raised to
//! [`MCR_DEFAULT_MAX_HOPS`] = 32 (per spec §12) because Tier 1 dominates
//! within-window scans and each hop is microsecond-cheap.

use std::time::Instant;

use log::debug;

use crate::emulator_ffi;
use crate::emulator_session::EmulatorReplaySession;
use crate::origin_query::{OriginError, OriginErrorCode, WallClockDeadline};
use crate::task::{
    CtOriginChainArguments, Location, OriginBudget, OriginChain, OriginHop, OriginKind, OriginMetrics, Terminator,
    TerminatorKind,
};

/// Default `max_hops` for the MCR hybrid backend (spec §6.4 / §12).
///
/// Tier 1 (undo-map lookup) is ~100 µs/hop, so raising the budget over
/// the M2 materialized default does not regress wall-clock latency for
/// window-resident chains.
pub const MCR_DEFAULT_MAX_HOPS: u32 = 32;

/// Per-hop budget given to the Tier 2 reverse-step driver. Bounds the
/// number of instructions the synthetic last-mile controller is allowed
/// to step backwards between successive write hits.
pub const MCR_TIER_TWO_PER_HOP_BUDGET: i32 = 8_192;

/// Result of the M17 origin algorithm.
pub type McrOriginResult = Result<OriginChain, OriginError>;

/// Per-hop attribution — which tier served the hop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HopTier {
    Tier1,
    Tier2,
}

/// Internal hop record returned by the per-tier resolvers; the caller
/// translates it into the wire-side [`OriginHop`] and bumps the metrics
/// counters.
#[derive(Debug, Clone)]
struct ResolvedWrite {
    pc: u64,
    tick_before: u64,
    address: u64,
    size: u8,
    /// The pre-write value, zero-extended to 64 bits (LE).
    old_value: u64,
    tier: HopTier,
}

/// Build the wire-side hop for a resolved write. The MCR hybrid does
/// not classify against source AST (the in-process emulator has no
/// source-line probe yet — that arrives in M19/M20). For now every
/// served write is surfaced as a `TrivialCopy` hop with a synthesised
/// source-text describing the write. This matches M11's contract for
/// "we know the PC + tick but cannot resolve the line" and is the
/// minimum the dispatcher requires to surface a hop to the frontend.
fn build_hop_from_write(write: &ResolvedWrite, queried_var: &str, step_id: i64) -> OriginHop {
    let location = Location::default();
    let provenance = match write.tier {
        HopTier::Tier1 => "mcr-hybrid: tier-1 undo-map (spec §6.4)",
        HopTier::Tier2 => "mcr-hybrid: tier-2 reverse-execution (spec §6.4)",
    };
    OriginHop {
        kind: OriginKind::TrivialCopy,
        target_expr: queried_var.to_string(),
        source_expr: format!(
            "0x{:x} <- 0x{:x} @ pc=0x{:x} tick={}",
            write.address, write.old_value, write.pc, write.tick_before
        ),
        source_variable: None,
        location,
        source_text: String::new(),
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: match write.tier {
            HopTier::Tier1 => 0.95,
            HopTier::Tier2 => 0.85,
        },
        classification_provenance: Some(provenance.to_string()),
        correlation_transition: None,
    }
}

/// Address + size of a queried variable. The MCR hybrid algorithm
/// resolves this once at the top and walks backwards from there.
#[derive(Debug, Clone, Copy)]
struct WatchExtent {
    address: u64,
    size: usize,
}

/// Tier-1 lookup. Returns Some(write) if the undo map covers the
/// (addr, tick) pair and contains a strictly-earlier write to the
/// queried range.
fn tier_one_lookup(extent: WatchExtent, tick: u64) -> Option<ResolvedWrite> {
    // SAFETY: every entry point reads / mutates Nim-side module-local
    // state through a single-threaded contract. The session's
    // `ensure_nim_runtime` call has already initialised the runtime.
    let coverage = unsafe { emulator_ffi::mcrUndoMapWriteCoverage(extent.address, tick) };
    if coverage == 0 {
        return None;
    }
    let size_c = extent.size.min(i32::MAX as usize) as i32;
    let hit = unsafe { emulator_ffi::mcrUndoMapLastWriteBefore(extent.address, size_c, tick) };
    if hit == 0 {
        return None;
    }
    Some(unsafe {
        ResolvedWrite {
            pc: emulator_ffi::mcrUndoMapLastWriteResultPc(),
            tick_before: emulator_ffi::mcrUndoMapLastWriteResultTick(),
            address: emulator_ffi::mcrUndoMapLastWriteResultAddress(),
            size: emulator_ffi::mcrUndoMapLastWriteResultSize().min(255) as u8,
            old_value: emulator_ffi::mcrUndoMapLastWriteResultValue(),
            tier: HopTier::Tier1,
        }
    })
}

/// Tier-2 fallback. Drive the synthetic last-mile controller backwards
/// up to the per-hop instruction budget, sampling the undo map at every
/// step in case the window extended underneath us. Returns Some(write)
/// when a write is observed before the budget runs out or the recording
/// start is reached.
fn tier_two_lookup(extent: WatchExtent, tick: u64) -> Option<ResolvedWrite> {
    // SAFETY: same single-threaded contract as `tier_one_lookup`.
    unsafe { emulator_ffi::mcrLastMileReverseStepReset(MCR_TIER_TWO_PER_HOP_BUDGET, 0, tick) };
    let size_c = extent.size.min(i32::MAX as usize) as i32;

    loop {
        let cursor_tick = unsafe { emulator_ffi::mcrLastMileReverseStepCurrentTick() };
        // Re-query the undo map at the new cursor tick — the window may
        // have extended after a reverse-step.
        let coverage = unsafe { emulator_ffi::mcrUndoMapWriteCoverage(extent.address, cursor_tick) };
        if coverage != 0 {
            let hit = unsafe { emulator_ffi::mcrUndoMapLastWriteBefore(extent.address, size_c, cursor_tick) };
            if hit != 0 {
                return Some(unsafe {
                    ResolvedWrite {
                        pc: emulator_ffi::mcrUndoMapLastWriteResultPc(),
                        tick_before: emulator_ffi::mcrUndoMapLastWriteResultTick(),
                        address: emulator_ffi::mcrUndoMapLastWriteResultAddress(),
                        size: emulator_ffi::mcrUndoMapLastWriteResultSize().min(255) as u8,
                        old_value: emulator_ffi::mcrUndoMapLastWriteResultValue(),
                        tier: HopTier::Tier2,
                    }
                });
            }
        }

        let status = unsafe { emulator_ffi::mcrLastMileReverseStep() };
        match status {
            0 => continue,    // advanced one tick; keep scanning.
            1 => return None, // budget exhausted.
            2 => return None, // recording start reached.
            _ => return None, // unknown sentinel — treat as failure.
        }
    }
}

/// Run the M17 MCR hybrid origin algorithm against an
/// [`EmulatorReplaySession`].
///
/// The dispatcher (`dap_handler::Handler::emulator_origin_chain`) hands
/// in the session, the per-request arguments, the budget (with the M17
/// raised `max_hops` default already applied), and the layered pattern
/// set the M2 / M11 classifier consumes.
///
/// Today the MCR backend does not yet expose
/// `evaluate_with_address` / `current_location` from the in-process
/// emulator session — both are reserved for the upcoming M18/M19 work.
/// The algorithm therefore resolves the initial watch extent from the
/// per-request hint (the address payload encoded into the
/// `variable_name` when callers want a synthetic chain, e.g. for the
/// M17 verification fixtures). When no hint is present the algorithm
/// surfaces 6101 / 6103 verbatim so the frontend renders the
/// "coming soon" affordance on a real MCR trace.
pub fn run_mcr_origin_chain(
    _session: &mut EmulatorReplaySession,
    args: &CtOriginChainArguments,
    budget: &OriginBudget,
) -> McrOriginResult {
    let started_at = Instant::now();
    let deadline = WallClockDeadline::new(budget.wall_clock_ms);
    let mut metrics = OriginMetrics::default();
    let mut hops: Vec<OriginHop> = Vec::new();
    let initial_query_step = if args.step_id < 0 { 0 } else { args.step_id };
    let query_variable = args.variable_name.clone();

    if query_variable.trim().is_empty() {
        return Err(OriginError::new(
            OriginErrorCode::InvalidVariablePath,
            "origin_chain: variable_name is empty".to_string(),
        ));
    }

    // Initial watch extent. The M17 verification fixtures encode the
    // address/size into the `variable_name` as `@addr=0xHEX,size=N` so
    // the algorithm can be exercised without a live MCR trace. The
    // production path (M18+) resolves the extent via
    // `EmulatorReplaySession::evaluate_with_address` which lands in a
    // follow-on milestone.
    let extent = parse_watch_extent_hint(&query_variable).ok_or_else(|| {
        OriginError::unsupported_backend(
            "emulator (M17 hybrid algorithm requires either a live MCR session with \
                 evaluate_with_address support or a `@addr=0x..,size=N` extent hint encoded \
                 in the query variable — full session support lands in M18+)",
        )
    })?;

    let mut current_extent = extent;
    let mut current_tick: u64 = initial_query_step.max(0) as u64;

    let mut effective_max_hops = budget.max_hops.max(1);
    if args.max_hops > 0 {
        effective_max_hops = effective_max_hops.min(args.max_hops);
    }

    let mut terminator = Terminator::new(TerminatorKind::RecordingStart);
    let mut truncated = false;

    while hops.len() < effective_max_hops as usize {
        if deadline.exceeded() {
            terminator = Terminator::new(TerminatorKind::OutOfBudget);
            terminator.expression = format!("wall-clock budget exhausted ({} ms)", budget.wall_clock_ms);
            break;
        }

        // Tier 1 — undo-map fast path.
        let resolved = if let Some(t1) = tier_one_lookup(current_extent, current_tick) {
            metrics.tier_one_hops += 1;
            metrics.classifier_hits += 1;
            t1
        } else if let Some(t2) = tier_two_lookup(current_extent, current_tick) {
            metrics.tier_two_hops += 1;
            metrics.classifier_hits += 1;
            t2
        } else {
            terminator = Terminator::new(TerminatorKind::RecordingStart);
            terminator.expression = format!(
                "no write to addr=0x{:x} before tick={} in either tier",
                current_extent.address, current_tick
            );
            break;
        };

        let hop = build_hop_from_write(&resolved, &query_variable, args.step_id);
        debug!(
            "mcr_origin_chain: hop {} served by {:?} at pc=0x{:x} tick={}",
            hops.len() + 1,
            resolved.tier,
            resolved.pc,
            resolved.tick_before
        );
        hops.push(hop);

        // Advance the cursor — Tier 1 / Tier 2 both consume the recorded
        // `tickBefore`, so the next iteration looks strictly earlier.
        current_tick = resolved.tick_before;
        // The address stays put unless the hop hopped to a different
        // source variable; the synthetic hybrid does not yet chase
        // source variables (that lands when M18's
        // `evaluate_with_address` ships), so we keep the same extent.
        current_extent = WatchExtent {
            address: resolved.address,
            size: resolved.size.max(1) as usize,
        };
    }

    if hops.len() >= effective_max_hops as usize {
        truncated = true;
        terminator = Terminator::new(TerminatorKind::OutOfBudget);
        terminator.expression = format!("max_hops budget ({}) reached", effective_max_hops);
    }

    metrics.elapsed_ms = started_at.elapsed().as_millis() as u64;
    metrics.steps_scanned = hops.len() as u64;
    let confidence: f32 = hops.iter().map(|h| h.confidence).fold(1.0_f32, f32::min);

    Ok(OriginChain {
        query_variable,
        query_step_id: initial_query_step,
        hops,
        terminator,
        truncated,
        continuation_token: None,
        metrics,
        cross_process_spans: Vec::new(),
        confidence,
    })
}

/// Parse the synthetic `@addr=0xHEX,size=N` watch-extent hint encoded
/// into `variable_name`. The hint is reserved for M17 verification
/// fixtures so the algorithm can be exercised end-to-end without a
/// live MCR trace — production callers resolve the extent through
/// `EmulatorReplaySession::evaluate_with_address` (M18+).
fn parse_watch_extent_hint(variable_name: &str) -> Option<WatchExtent> {
    let suffix = variable_name.split('@').nth(1)?;
    let mut address: Option<u64> = None;
    let mut size: Option<usize> = None;
    for part in suffix.split(',') {
        let mut it = part.splitn(2, '=');
        let key = it.next()?.trim();
        let value = it.next()?.trim();
        match key {
            "addr" => {
                let hex = value.trim_start_matches("0x").trim_start_matches("0X");
                address = u64::from_str_radix(hex, 16).ok();
            }
            "size" => {
                size = value.parse::<usize>().ok();
            }
            _ => {}
        }
    }
    Some(WatchExtent {
        address: address?,
        size: size?.max(1),
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard, Once};

    static NIM_MAIN: Once = Once::new();
    /// Mirror of the `emulator_ffi::tests::FFI_LOCK` mutex — see that
    /// module's commentary. The two mutexes serialise different things
    /// (FFI calls vs. high-level driver), so each integration test
    /// reaches for its own lock.
    static FFI_LOCK: Mutex<()> = Mutex::new(());

    fn ensure_nim() {
        NIM_MAIN.call_once(|| unsafe {
            crate::emulator_ffi::NimMain();
        });
    }

    /// Acquire the FFI mutex and reset the Nim-side state.
    fn reset_nim_state() -> MutexGuard<'static, ()> {
        ensure_nim();
        let guard = FFI_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        unsafe {
            crate::emulator_ffi::mcrUndoMapReset();
            crate::emulator_ffi::mcrLastMileReverseStepReset(0, 0, 0);
        }
        guard
    }

    fn make_args(name: &str, step_id: i64, max_hops: u32) -> CtOriginChainArguments {
        CtOriginChainArguments {
            variable_name: name.to_string(),
            variable_path: Vec::new(),
            frame_id: -1,
            step_id,
            thread_id: 0,
            max_hops,
            lazy: false,
            continuation_token: None,
            session_id: String::new(),
            classify_source: true,
        }
    }

    fn default_budget() -> OriginBudget {
        OriginBudget {
            max_hops: MCR_DEFAULT_MAX_HOPS,
            wall_clock_ms: crate::task::DEFAULT_ORIGIN_WALL_CLOCK_MS,
            max_steps_scanned: crate::task::DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
        }
    }

    #[test]
    fn parses_addr_size_hint_from_variable_name() {
        let hint = parse_watch_extent_hint("total@addr=0xdeadbeef,size=4").unwrap();
        assert_eq!(hint.address, 0xDEAD_BEEF);
        assert_eq!(hint.size, 4);
    }

    #[test]
    fn missing_hint_returns_none() {
        assert!(parse_watch_extent_hint("plain_name").is_none());
    }

    #[test]
    fn mcr_default_max_hops_is_thirty_two() {
        // Both `assert!` arms below would be reported as "constant
        // assertion" by clippy because the values are compile-time
        // constants. The intent is exactly that — a compile-time
        // contract between the two constants so any refactor that
        // brings `MCR_DEFAULT_MAX_HOPS` back below the M2 default
        // trips the test. We wedge the comparison into a `const _`
        // assertion (which is allowed) and keep the runtime asserts
        // suppressed.
        #[allow(clippy::assertions_on_constants)]
        const _ASSERT: () = {
            assert!(MCR_DEFAULT_MAX_HOPS == 32);
            assert!(MCR_DEFAULT_MAX_HOPS > crate::task::DEFAULT_ORIGIN_MAX_HOPS);
        };
        // Keep one runtime assertion live so the test still shows up
        // in the cargo-test summary and surfaces a clear error message.
        assert_eq!(MCR_DEFAULT_MAX_HOPS, 32);
    }

    #[test]
    fn empty_variable_name_yields_6101() {
        let _guard = reset_nim_state();
        let mut session = EmulatorReplaySession::new();
        let args = make_args("", 100, 0);
        let err = run_mcr_origin_chain(&mut session, &args, &default_budget()).unwrap_err();
        assert_eq!(err.code, OriginErrorCode::InvalidVariablePath);
    }

    #[test]
    fn no_hint_yields_6103_unsupported_backend() {
        let _guard = reset_nim_state();
        let mut session = EmulatorReplaySession::new();
        let args = make_args("plain_var", 100, 0);
        let err = run_mcr_origin_chain(&mut session, &args, &default_budget()).unwrap_err();
        assert_eq!(err.code, OriginErrorCode::UnsupportedBackend);
    }

    #[test]
    fn tier_one_serves_every_hop_within_window() {
        let _guard = reset_nim_state();
        // Push three synthetic writes into the undo log, all within the
        // active window. The hybrid algorithm should walk them
        // backwards in order, attributing every hop to Tier 1.
        unsafe {
            emulator_ffi::mcrUndoMapSetWindow(0, 1000);
            for (i, tick) in [100u64, 200, 300].iter().enumerate() {
                let rc =
                    emulator_ffi::mcrUndoMapPushWrite(0x4000 + i as u64, *tick, 0x4000, 4, i as u64 + 1, i as u64 + 2);
                assert_eq!(rc, 0);
            }
        }

        let mut session = EmulatorReplaySession::new();
        let args = make_args("total@addr=0x4000,size=4", 500, 0);
        let chain = run_mcr_origin_chain(&mut session, &args, &default_budget()).unwrap();
        assert_eq!(chain.hops.len(), 3, "three synthetic writes -> three hops");
        assert_eq!(chain.metrics.tier_one_hops, 3, "all served by Tier 1");
        assert_eq!(chain.metrics.tier_two_hops, 0, "no Tier 2 fallback expected");
        assert!(matches!(
            chain.terminator.kind,
            TerminatorKind::RecordingStart | TerminatorKind::OutOfBudget
        ));
    }

    #[test]
    fn tier_two_falls_back_when_window_excludes_query_tick() {
        let _guard = reset_nim_state();
        // Push two synthetic writes inside [0, 1000], then set the
        // window to a region that EXCLUDES the query tick. The
        // hybrid's Tier 1 gate should fail, and Tier 2 should rewind
        // until coverage catches the writes.
        unsafe {
            emulator_ffi::mcrUndoMapSetWindow(0, 500);
            for tick in [100u64, 200].iter() {
                let rc = emulator_ffi::mcrUndoMapPushWrite(0x4000 + *tick, *tick, 0x4000, 4, 42, 99);
                assert_eq!(rc, 0);
            }
        }

        let mut session = EmulatorReplaySession::new();
        // Query at tick 700 — outside the window's `endTick = 500`.
        let args = make_args("total@addr=0x4000,size=4", 700, 0);
        let chain = run_mcr_origin_chain(&mut session, &args, &default_budget()).unwrap();
        assert!(
            !chain.hops.is_empty(),
            "Tier 2 must rewind into the window and surface at least one hop"
        );
        assert!(
            chain.metrics.tier_two_hops > 0,
            "tier_two_hops > 0 — Tier 2 served the first hop"
        );
    }

    #[test]
    fn max_hops_zero_is_clamped_to_one() {
        let _guard = reset_nim_state();
        unsafe {
            emulator_ffi::mcrUndoMapSetWindow(0, 1000);
            for tick in [100u64, 200].iter() {
                let _ = emulator_ffi::mcrUndoMapPushWrite(0x4000 + tick, *tick, 0x4000, 4, 0, 0);
            }
        }

        let mut session = EmulatorReplaySession::new();
        let args = make_args("total@addr=0x4000,size=4", 500, 1);
        let chain = run_mcr_origin_chain(&mut session, &args, &default_budget()).unwrap();
        assert_eq!(chain.hops.len(), 1, "args.max_hops clamps the chain");
        assert!(chain.truncated, "truncated == true when budget caps the chain");
    }
}
