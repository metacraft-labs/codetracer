//! M20 — MCR omniscient origin tier (consumes the M19 metadata extension).
//!
//! Implements the value-origin chain algorithm for `TraceKind::Emulator`
//! traces that ship the omniscient memory-write log (M18 — `memwrites.tc`)
//! **and** optionally the M19 origin-metadata extension (`originmeta.tc` +
//! `source_exprs.tc`).
//!
//! See:
//!
//! * `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`
//!   §6.5 (omniscient algorithm without metadata — write-log + classifier)
//!   and §6.8.2 (metadata-driven materialisation).
//! * The dispatcher in [`crate::dap_handler::Handler::emulator_origin_chain`]
//!   prefers this tier whenever both pieces are present on the trace;
//!   M17's hybrid path remains the fallback for traces without the
//!   omniscient DB.
//!
//! ## Algorithm shape
//!
//! ```text
//! fn origin_chain_mcr_omniscient(omniscient, decoder?, query_var, query_step, budget):
//!     (addr, size) = parse_watch_extent(query_var)
//!     cursor = query_step
//!     while chain.len() < budget.max_hops:
//!         write = omniscient.last_write_before(addr, size, cursor)
//!         if write is None: terminator = RecordingStart; break
//!         if decoder.is_some():
//!             meta = decoder.origin_metadata_at(Native { address: write.address, tick: write.tick })
//!             if meta is Some:
//!                 hop = build_hop_from_metadata(write, meta, decoder)
//!                 metadata_hops += 1
//!             else:
//!                 # Per spec §6.8.5 partial coverage: address falls outside
//!                 # an analysed interval. Fall back to classifier path so
//!                 # the chain remains usable.
//!                 hop = build_hop_from_write_via_classifier(write)
//!                 classifier_hops += 1
//!         else:
//!             # Mode 2: omniscient log but no metadata.
//!             hop = build_hop_from_write_via_classifier(write)
//!             classifier_hops += 1
//!         chain.push(hop)
//!         cursor = write.tick
//! ```
//!
//! Per-hop latency is dominated by:
//!
//! * a single `omniscient_db.last_write_before` call (O(log N) via the
//!   M18 binary-search FFI surface);
//! * one `decoder.origin_metadata_at` lookup (O(log N) via the M19
//!   per-address sorted index when the decoder is present);
//! * zero tree-sitter parses (the classifier output was baked into
//!   `originmeta.tc` at indexer time per spec §6.8.2).
//!
//! Per spec §12 this gives ~10 µs/hop on the production fixture; the
//! M20 latency test (`test_origin_mcr_omniscient_latency_below_threshold`)
//! pins the budget at < 100 µs to leave CI noise room.
//!
//! ## Default `max_hops`
//!
//! Raised from M17's [`crate::emulator_origin::MCR_DEFAULT_MAX_HOPS`] = 32
//! to [`MCR_OMNISCIENT_DEFAULT_MAX_HOPS`] = 64 per spec §12. The
//! per-hop work is O(log N) regardless of where the hop lives in the
//! trace, so cross-checkpoint-interval chains incur no extra cost
//! per hop and the doubled budget is safe.
//!
//! ## Cross-checkpoint-interval chains
//!
//! The M18 [`crate::omniscient_db::OmniscientDb::last_write_before`]
//! contract is **tick-domain global**: the persistent memory-write log
//! is keyed by absolute tick across the whole recording. Crossing a
//! checkpoint interval boundary in the chain is therefore transparent
//! to this algorithm — no special handling is needed, only the
//! correctness of the per-checkpoint coverage on the writer side. The
//! M20 verification test `test_origin_mcr_omniscient_cross_checkpoint_chain`
//! exercises this contract end-to-end against the synthetic fixture.

use std::time::Instant;

use log::debug;

use crate::omniscient_db::OmniscientDb;
use crate::origin_metadata_indexer::{OriginMetadataDecoder, OriginMetadataKey, OriginMetadataRecord};
use crate::origin_query::{OriginError, OriginErrorCode, WallClockDeadline};
use crate::task::{
    CtOriginChainArguments, Location, OriginBudget, OriginChain, OriginHop, OriginKind, OriginMetrics, Terminator,
    TerminatorKind,
};

/// Default `max_hops` for the M20 omniscient backend (spec §12).
///
/// Doubled from the M17 [`crate::emulator_origin::MCR_DEFAULT_MAX_HOPS`]
/// because metadata-driven hops are O(log N) per hop irrespective of
/// where the write lives in the trace (no per-hop tree-sitter parse,
/// no per-hop reverse-step driver). The wider budget lets the frontend
/// surface longer chains without truncation when the user opens a
/// particularly deep origin chain.
pub const MCR_OMNISCIENT_DEFAULT_MAX_HOPS: u32 = 64;

/// Result of the M20 omniscient origin algorithm.
pub type McrOmniscientResult = Result<OriginChain, OriginError>;

/// Resolved watch extent — address + size of the variable the caller is
/// querying. The M20 algorithm walks backwards from the query tick
/// against this extent against the omniscient memory-write log.
#[derive(Debug, Clone, Copy)]
struct WatchExtent {
    address: u64,
    size: usize,
}

/// Parse the synthetic `@addr=0xHEX,size=N` watch-extent hint encoded
/// into `variable_name`. This mirrors the M17 hint discipline so the
/// M20 verification tests can drive the algorithm end-to-end without a
/// live MCR trace (which would require `evaluate_with_address` from a
/// follow-on milestone). Production callers will resolve the extent
/// through the session's address resolver once that surface lands.
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

/// Compact write-side context passed to the hop builders. Bundling
/// the four write-record fields the builders need keeps the function
/// signatures terse and within the project's `clippy::too_many_arguments`
/// threshold.
#[derive(Debug, Clone, Copy)]
struct WriteContext {
    address: u64,
    tick: u64,
    pc: u64,
    old_value: u64,
}

impl WriteContext {
    fn from_write(write: &crate::omniscient_db::WriteRecord) -> Self {
        Self {
            address: write.address,
            tick: write.tick,
            pc: write.pc,
            old_value: write.old_value,
        }
    }
}

/// Build a hop from a metadata-served write. No classifier call is
/// made — the on-disk record already carries the classifier's verdict
/// per spec §6.8.2.
fn build_hop_from_metadata(
    write: WriteContext,
    queried_var: &str,
    step_id: i64,
    meta: &OriginMetadataRecord,
    decoder: &OriginMetadataDecoder,
) -> OriginHop {
    let kind = OriginMetadataRecord::decode_kind(meta.kind)
        .map(OriginKind::from)
        .unwrap_or(OriginKind::Unknown);
    let source_expr_text = decoder.source_expr_text(meta.source_expr_idx).unwrap_or("").to_string();
    let source_variable = meta.source_var_id.map(|id| format!("VariableId({})", id));
    OriginHop {
        kind,
        target_expr: queried_var.to_string(),
        source_expr: if source_expr_text.is_empty() {
            format!(
                "0x{:x} <- 0x{:x} @ pc=0x{:x} tick={}",
                write.address, write.old_value, write.pc, write.tick
            )
        } else {
            source_expr_text.clone()
        },
        source_variable,
        location: Location::default(),
        source_text: source_expr_text,
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: OriginMetadataRecord::decode_confidence(meta.confidence),
        classification_provenance: Some("mcr-omniscient: tier-3 metadata-driven (spec §6.8.2)".to_string()),
        correlation_transition: None,
    }
}

/// Fallback hop builder used when only the omniscient log is present
/// (no `originmeta.tc`), or when the metadata namespace is loaded but
/// doesn't cover this particular `(address, tick)` (partial-coverage
/// per spec §6.8.5). The hop carries the same `TrivialCopy` placeholder
/// shape as M17 so the frontend continues to render it; this is the
/// classifier-driven path, which is why the omniscient algorithm bumps
/// the per-hop `classifier_hits` counter when it hits this branch.
fn build_hop_from_write_classifier_fallback(write: WriteContext, queried_var: &str, step_id: i64) -> OriginHop {
    OriginHop {
        kind: OriginKind::TrivialCopy,
        target_expr: queried_var.to_string(),
        source_expr: format!(
            "0x{:x} <- 0x{:x} @ pc=0x{:x} tick={}",
            write.address, write.old_value, write.pc, write.tick
        ),
        source_variable: None,
        location: Location::default(),
        source_text: String::new(),
        step_id,
        frame_transition: None,
        operand_snapshots: Vec::new(),
        truncated_operands: false,
        confidence: 0.9,
        classification_provenance: Some("mcr-omniscient: tier-3 write-log + classifier (spec §6.5)".to_string()),
        correlation_transition: None,
    }
}

/// Should the chain advance to chase the source variable on the next
/// hop? Per spec §6.8.2 only `TrivialCopy`, `ParameterPass` and
/// `ReturnCapture` kinds are "pass-through" hops whose chain continues;
/// everything else terminates the chain at the current hop. Mirrors
/// the M11 RR algorithm's terminator-kind logic.
fn is_pass_through(kind: OriginKind) -> bool {
    matches!(
        kind,
        OriginKind::TrivialCopy | OriginKind::ParameterPass | OriginKind::ReturnCapture | OriginKind::FunctionReturn
    )
}

/// Map an [`OriginKind`] to the corresponding [`TerminatorKind`] when
/// the chain stops at that hop (per spec §4.1 closure rules).
fn kind_to_terminator(kind: OriginKind) -> TerminatorKind {
    match kind {
        OriginKind::Literal => TerminatorKind::Literal,
        OriginKind::Computational => TerminatorKind::Computational,
        OriginKind::FunctionCall => TerminatorKind::Computational,
        OriginKind::CrossThreadCopy => TerminatorKind::ReadFromExternal,
        OriginKind::FieldAccess | OriginKind::IndexAccess => TerminatorKind::Computational,
        OriginKind::Unknown => TerminatorKind::UnknownSource,
        // Pass-through kinds normally don't terminate the chain — but if
        // we hit max_hops or the source variable can't be resolved we
        // fall back to the generic "depth" terminator.
        OriginKind::TrivialCopy
        | OriginKind::ParameterPass
        | OriginKind::ReturnCapture
        | OriginKind::FunctionReturn => TerminatorKind::DepthLimit,
    }
}

/// Run the M20 omniscient origin algorithm against an
/// [`EmulatorReplaySession`].
///
/// The dispatcher in
/// [`crate::dap_handler::Handler::emulator_origin_chain`] hands in the
/// session, the per-request arguments, and the budget. The session
/// must already have an omniscient log available (the dispatcher
/// checks `session.omniscient_db().is_some()` before calling here);
/// the M19 metadata decoder is optional and routes us through the
/// metadata-driven §6.8.2 path when present.
///
/// **Mode 3** (omniscient log + metadata): every hop is materialised
/// by direct metadata lookup. `metrics.classifier_hits == 0` —
/// classifier was invoked once-per-write at indexer time, not at
/// query time.
///
/// **Mode 2** (omniscient log only, no metadata): the algorithm
/// degrades to the §6.5 write-log-plus-classifier shape — every hop is
/// served from the log but the classifier verdict is fabricated at
/// query time (here as the conservative `TrivialCopy` placeholder, as
/// M17 does). `metrics.classifier_hits` then equals `hops.len()`.
pub fn run_omniscient_origin_chain(
    omniscient: &dyn OmniscientDb,
    decoder: Option<&OriginMetadataDecoder>,
    args: &CtOriginChainArguments,
    budget: &OriginBudget,
) -> McrOmniscientResult {
    // M29 §5.1 — delegate to the `_with_cross_process` variant with
    // no extension so single-trace callers (M20 unit tests,
    // production browser-replay dispatcher without a session-wide
    // pair index) keep working bit-for-bit. The production
    // dispatcher uses the `_with_cross_process` entry directly when
    // the session-wide `PairIndex` is available.
    run_omniscient_origin_chain_with_cross_process(omniscient, decoder, args, budget, None)
}

/// M29 §5.1 — production wiring entry point for the omniscient
/// algorithm.
///
/// Mirrors the M2 materialized
/// [`crate::db::MaterializedReplaySession::origin_chain_inferred_with_cross_process`]
/// shape: runs the single-trace algorithm exactly as
/// [`run_omniscient_origin_chain`] does, then consults
/// [`crate::cross_process_origin::run`] when `extension` is `Some`.
/// The dispatcher wires the extension in
/// [`crate::dap_handler::Handler::emulator_origin_chain`] when the
/// session-wide pair index is available.
pub fn run_omniscient_origin_chain_with_cross_process(
    omniscient: &dyn OmniscientDb,
    decoder: Option<&OriginMetadataDecoder>,
    args: &CtOriginChainArguments,
    budget: &OriginBudget,
    extension: Option<crate::cross_process_origin::CrossProcessExtension<'_>>,
) -> McrOmniscientResult {
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

    // Initial watch extent — same `@addr=0xHEX,size=N` hint discipline
    // as M17's emulator_origin so the M20 verification tests can drive
    // the algorithm against synthetic in-FFI fixtures without needing
    // the production `evaluate_with_address` resolver to land first.
    let extent = parse_watch_extent_hint(&query_variable).ok_or_else(|| {
        OriginError::unsupported_backend(
            "emulator (M20 omniscient algorithm requires either a live MCR session with \
                 evaluate_with_address support or a `@addr=0x..,size=N` extent hint encoded \
                 in the query variable — full session support lands as a follow-on milestone)",
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

        // Omniscient log lookup — strictly-earlier write to the queried
        // extent. The M18 contract uses *strictly less than* `tick` so
        // the chain naturally walks backwards across checkpoint
        // interval boundaries without special casing.
        let size_u32 = current_extent.size.min(u32::MAX as usize) as u32;
        let write = match omniscient.last_write_before(current_extent.address, size_u32, current_tick) {
            Some(w) => w,
            None => {
                terminator = Terminator::new(TerminatorKind::RecordingStart);
                terminator.expression = format!(
                    "no write to addr=0x{:x} before tick={} in omniscient log",
                    current_extent.address, current_tick
                );
                break;
            }
        };

        // Try the metadata-driven path first. When the decoder is
        // present AND covers this **exact** `(address, tick)` we
        // materialise the hop from the on-disk record — no classifier
        // call. The exact-key lookup distinguishes "no metadata for
        // this write" (partial coverage per spec §6.8.5) from "metadata
        // exists for an earlier write at the same address" (which the
        // §6.8.2 walk uses, but isn't what we want here — we already
        // have the omniscient log's write record in hand).
        let (hop, kind_for_chain, served_by_metadata) = match decoder {
            Some(dec) => match dec.origin_metadata_exact(OriginMetadataKey::Native {
                address: write.address,
                tick: write.tick,
            }) {
                Some(meta) => {
                    let kind = OriginMetadataRecord::decode_kind(meta.kind)
                        .map(OriginKind::from)
                        .unwrap_or(OriginKind::Unknown);
                    let hop = build_hop_from_metadata(
                        WriteContext::from_write(&write),
                        &query_variable,
                        args.step_id,
                        &meta,
                        dec,
                    );
                    (hop, kind, true)
                }
                None => {
                    // Partial coverage (spec §6.8.5): the metadata
                    // namespace is loaded but this address isn't yet
                    // analysed. Fall back to the §6.5 form.
                    let hop = build_hop_from_write_classifier_fallback(
                        WriteContext::from_write(&write),
                        &query_variable,
                        args.step_id,
                    );
                    (hop, OriginKind::TrivialCopy, false)
                }
            },
            None => {
                // Mode 2: no metadata namespace — every hop goes through
                // the classifier-fabricated path.
                let hop = build_hop_from_write_classifier_fallback(
                    WriteContext::from_write(&write),
                    &query_variable,
                    args.step_id,
                );
                (hop, OriginKind::TrivialCopy, false)
            }
        };

        debug!(
            "omniscient_origin_chain: hop {} kind={:?} served_by_metadata={} pc=0x{:x} tick={}",
            hops.len() + 1,
            kind_for_chain,
            served_by_metadata,
            write.pc,
            write.tick
        );

        // Per spec §6.5 every hop counts toward `tier_one_hops` (the
        // omniscient log served the underlying write). The
        // `classifier_hits` counter is incremented ONLY on the
        // classifier-fabricated fallback so callers can distinguish
        // the Mode 3 zero-classifier path from the Mode 2 path purely
        // from the metrics.
        metrics.tier_one_hops += 1;
        if !served_by_metadata {
            metrics.classifier_hits += 1;
        }
        hops.push(hop);

        // Pass-through kinds (TrivialCopy / ParameterPass /
        // ReturnCapture) keep the chain going; anything else
        // terminates at this hop.
        if !is_pass_through(kind_for_chain) {
            terminator = Terminator::new(kind_to_terminator(kind_for_chain));
            break;
        }

        // Advance the cursor. Address stays put — the M19 indexer
        // doesn't yet expose `address_of_var(source_var_id)` (that
        // resolver lands with the recorder's `evaluate_with_address`
        // surface), so the omniscient algorithm walks the same address
        // backwards until the chain terminates or `max_hops` is hit.
        // This mirrors the M17 contract and is the spec's safe
        // default for the partial-coverage scenario where source
        // variable IDs aren't materialisable.
        current_tick = write.tick;
        current_extent = WatchExtent {
            address: write.address,
            size: write.size.max(1) as usize,
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

    let chain = OriginChain {
        query_variable,
        query_step_id: initial_query_step,
        hops,
        terminator,
        truncated,
        continuation_token: None,
        metrics,
        cross_process_spans: Vec::new(),
        confidence,
    };
    // M29 §5.1 — splice cross-process hops when the chain's tail
    // lands on a receive marker. Passthrough when `extension` is
    // `None`.
    let (chain, _outcome) = crate::cross_process_origin::run(chain, extension);
    Ok(chain)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::emulator_ffi;
    use crate::omniscient_db::{FfiOmniscientDb, WriteRecord, omniscient_ffi_lock};
    use crate::origin_metadata_indexer::{KeyingScheme, NativeOriginIndexer, NativeWrite, OriginMetadataDecoder};
    use origin_classifier::OriginKind as ClassifierKind;
    use std::sync::Once;

    static NIM_MAIN: Once = Once::new();

    fn ensure_nim() {
        NIM_MAIN.call_once(|| unsafe {
            emulator_ffi::NimMain();
        });
    }

    fn reset_state() {
        ensure_nim();
        unsafe {
            emulator_ffi::mcrOmniscientReset();
            emulator_ffi::mcrUndoMapReset();
        }
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
            max_hops: MCR_OMNISCIENT_DEFAULT_MAX_HOPS,
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
    fn mcr_omniscient_default_max_hops_doubled_relative_to_m17() {
        #[allow(clippy::assertions_on_constants)]
        const _ASSERT: () = {
            assert!(MCR_OMNISCIENT_DEFAULT_MAX_HOPS == 64);
            assert!(MCR_OMNISCIENT_DEFAULT_MAX_HOPS > crate::emulator_origin::MCR_DEFAULT_MAX_HOPS);
        };
        assert_eq!(MCR_OMNISCIENT_DEFAULT_MAX_HOPS, 64);
    }

    #[test]
    fn empty_variable_name_returns_6101() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_state();
        let db = FfiOmniscientDb::new();
        let args = make_args("", 100, 0);
        let err = run_omniscient_origin_chain(&db, None, &args, &default_budget()).unwrap_err();
        assert_eq!(err.code, OriginErrorCode::InvalidVariablePath);
    }

    #[test]
    fn missing_hint_returns_6103() {
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_state();
        let db = FfiOmniscientDb::new();
        let args = make_args("plain_var", 100, 0);
        let err = run_omniscient_origin_chain(&db, None, &args, &default_budget()).unwrap_err();
        assert_eq!(err.code, OriginErrorCode::UnsupportedBackend);
    }

    #[test]
    fn mode_2_chain_increments_classifier_hits_per_hop() {
        // Mode 2: omniscient log present, no metadata decoder.
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_state();
        let db = FfiOmniscientDb::new();
        // Seed 4 synthetic writes to 0x4000 — all literal placeholder
        // hops since no metadata is provided.
        for i in 0..4u64 {
            assert!(db.push_write(WriteRecord {
                tick: 10 + i * 5,
                pc: 0x1000 + i,
                address: 0x4000,
                size: 4,
                old_value: i,
                new_value: i + 1,
            }));
        }
        assert!(db.finalize());

        let args = make_args("total@addr=0x4000,size=4", 1_000, 0);
        let chain = run_omniscient_origin_chain(&db, None, &args, &default_budget()).unwrap();
        assert_eq!(chain.hops.len(), 4, "all four writes surface as hops");
        assert_eq!(chain.metrics.tier_one_hops, 4, "every hop served by the omniscient log");
        assert_eq!(
            chain.metrics.classifier_hits, 4,
            "Mode 2 falls back to classifier per hop"
        );
    }

    #[test]
    fn mode_3_chain_skips_classifier_when_metadata_present() {
        // Mode 3: omniscient log + originmeta.tc. Every hop is served
        // by the metadata path; classifier_hits stays at zero.
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_state();
        let db = FfiOmniscientDb::new();

        let mut native_writes = Vec::new();
        for i in 0..4u64 {
            let tick = 10 + i * 5;
            let address = 0x4000;
            assert!(db.push_write(WriteRecord {
                tick,
                pc: 0x1000 + i,
                address,
                size: 4,
                old_value: i,
                new_value: i + 1,
            }));
            native_writes.push(NativeWrite {
                address,
                tick,
                target_var_id: 11,
                function_idx: 7,
                source_expr_text: format!("total += step{i}"),
                kind: ClassifierKind::TrivialCopy,
                source_var_id: Some(12),
                confidence: 0.95,
            });
        }
        assert!(db.finalize());

        let indexer_output = NativeOriginIndexer::new().run(&native_writes);
        let decoder = OriginMetadataDecoder::from_stream(indexer_output.originmeta, indexer_output.source_exprs);
        assert_eq!(decoder.keying_scheme(), KeyingScheme::Native);

        let args = make_args("total@addr=0x4000,size=4", 1_000, 0);
        let chain = run_omniscient_origin_chain(&db, Some(&decoder), &args, &default_budget()).unwrap();
        assert_eq!(chain.hops.len(), 4, "all four writes surface as hops");
        assert_eq!(chain.metrics.tier_one_hops, 4);
        assert_eq!(
            chain.metrics.classifier_hits, 0,
            "Mode 3 metadata path must not invoke the classifier per hop"
        );
        // Source-expression text from the indexer must surface in the
        // hop body — proves the round-trip through the decoder.
        for (i, hop) in chain.hops.iter().enumerate() {
            // Chain walks backwards from the latest write; hop[0] is
            // the most recent write.
            let expected = format!("total += step{}", 3 - i);
            assert!(
                hop.source_expr.contains(&expected),
                "hop {} source_expr={:?} must reuse the indexer's text {:?}",
                i,
                hop.source_expr,
                expected
            );
        }
    }

    #[test]
    fn metadata_partial_coverage_falls_back_to_classifier() {
        // Mode 3 with partial coverage (spec §6.8.5): the decoder is
        // present but doesn't carry a record for the queried (addr,
        // tick). The algorithm degrades to the classifier path for the
        // uncovered hops; coverage proportion shows in the metrics.
        let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
        reset_state();
        let db = FfiOmniscientDb::new();

        // Write A: covered by metadata; Write B: not covered.
        let covered = WriteRecord {
            tick: 10,
            pc: 0x1000,
            address: 0x4000,
            size: 4,
            old_value: 1,
            new_value: 2,
        };
        let uncovered = WriteRecord {
            tick: 20,
            pc: 0x1100,
            address: 0x4000,
            size: 4,
            old_value: 2,
            new_value: 3,
        };
        assert!(db.push_write(covered));
        assert!(db.push_write(uncovered));
        assert!(db.finalize());

        // Indexer only learns about `covered` — `uncovered` falls
        // outside the analysed interval.
        let indexer_output = NativeOriginIndexer::new().run(&[NativeWrite {
            address: covered.address,
            tick: covered.tick,
            target_var_id: 11,
            function_idx: 7,
            source_expr_text: "covered = literal".to_string(),
            kind: ClassifierKind::Literal,
            source_var_id: None,
            confidence: 1.0,
        }]);
        let decoder = OriginMetadataDecoder::from_stream(indexer_output.originmeta, indexer_output.source_exprs);

        let args = make_args("total@addr=0x4000,size=4", 1_000, 0);
        let chain = run_omniscient_origin_chain(&db, Some(&decoder), &args, &default_budget()).unwrap();
        // Chain walks backwards from the latest write (uncovered).
        // The uncovered hop falls back to the classifier path; the
        // covered hop terminates the chain because Literal isn't a
        // pass-through kind.
        assert_eq!(chain.hops.len(), 2);
        assert_eq!(chain.metrics.tier_one_hops, 2);
        assert_eq!(chain.metrics.classifier_hits, 1, "exactly one fallback hop");
    }
}
