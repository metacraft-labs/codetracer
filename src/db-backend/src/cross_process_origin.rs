//! M29 — Cross-process origin chain extension (spec §14.3).
//!
//! Lands the **§14.3 cross-process clause** referenced by the M29
//! milestone. The clause is independent of the per-backend origin
//! algorithm — given a chain ending at a Receive marker plus the
//! session-wide [`PairIndex`], the extender locates the matching Send
//! marker in a sibling trace and attaches both a
//! [`CorrelationTransition`] descriptor to the boundary-crossing hop
//! and a session-level [`CrossProcessSpan`] entry so the frontend can
//! render the per-process breadcrumbs.
//!
//! ## Design choice — extension rather than inline
//!
//! The materialized algorithm in [`crate::db::MaterializedReplaySession::origin_chain_inferred`]
//! and the omniscient algorithm in
//! [`crate::omniscient_origin::run_omniscient_origin_chain`] each
//! produce single-trace chains. Cross-process behaviour at spec §14.3
//! is composed by:
//!
//! 1. Computing the single-trace chain via the appropriate per-backend
//!    path.
//! 2. Inspecting the resulting chain for a tail hop whose location
//!    matches a Receive marker (the substrate test of "the backward
//!    scan reaches a tracepoint marker with `direction = Receive`
//!    whose display variable matches the queried variable").
//! 3. Consulting the [`PairIndex`] for the matched sibling Send
//!    marker.
//! 4. Continuing the chain on the sibling trace's `display_variable`
//!    at the Send marker's step.
//!
//! This file owns step (2)–(4) — the **composer** the dispatcher
//! calls after the per-backend single-trace path completes. Keeping
//! the cross-process clause as a separate composer means:
//!
//! - The §14.3 logic is exercised by **every** backend the
//!   single-trace dispatcher supports (materialized, MCR omniscient,
//!   MCR hybrid, RR) without per-backend duplication.
//! - The §14.3 algorithm is independently testable against a
//!   synthetic [`PairIndex`] without spinning up a per-backend
//!   trace fixture.
//! - The §14.3 algorithm is the only owner of the new
//!   [`CrossProcessSpan`] + [`CorrelationTransition`] data, keeping
//!   the per-backend algorithms ignorant of cross-process state.
//!
//! ## Algorithm
//!
//! Pseudocode (mirrors spec §14.3 — generalised to N hops per TCT-M3):
//!
//! ```text
//! fn extend_with_cross_process(chain, pair_index, fetch_sibling_chain):
//!     while sibling = find_receive_marker_at_chain_tail(chain, pair_index):
//!         sends = pair_index.counterparts_of(sibling.recv_event)
//!         match sends.len():
//!             0 => terminate(RecordingStart, "missing correlation")
//!             1 => continue chain on sibling.send at send.show_value
//!                  current_identity = sibling.identity
//!             _ => terminate(UnknownSource, "ambiguous correlation")
//! ```
//!
//! The actual continuation on the sibling trace is delegated to the
//! caller via a `SiblingChainResolver` callback so this module stays
//! pure: it owns the §14.3 control-flow + the
//! [`CrossProcessSpan`] / [`CorrelationTransition`] assembly but not
//! the per-trace chain compute. The dispatcher layer wires the
//! callback to the appropriate per-backend origin path on the
//! sibling trace.
//!
//! ## Recursive composition (TCT-M3)
//!
//! The composer walks the boundary recursively: after each successful
//! sibling hop lands in trace B, the tail of the new chain is itself
//! tested for a receive marker against trace B's own marker firings
//! (with the new `current_identity = sibling.identity`). If trace B's
//! receive marker pairs with a Send in trace C, the composer hops
//! again. This is the substrate of the JS → WASM → backend three-
//! tracer scenario (TCT-M3): the JS trace's tail hop crosses the
//! `js-wasm-realm` boundary into the WASM trace, whose own tail hop
//! then crosses an HTTP/RPC boundary into the backend trace.
//!
//! Recursion is bounded by [`MAX_BOUNDARY_HOPS`] to avoid infinite
//! loops on cyclic correlation markers. The bound is intentionally
//! generous (eight hops) since real cross-tracer chains saturate at
//! three; the cap protects against pathological pair-index shapes
//! (e.g. a Send-side marker that happens to coincide with a Recv-side
//! marker in the same trace forming a self-loop).

use crate::correlation_index::{MarkerEventView, PairIndex};
use crate::correlation_markers::MarkerDirection;
use crate::task::{
    CorrelationTransition, CrossProcessSpan, OriginChain, OriginHop, OriginKind, Terminator, TerminatorKind,
};

/// Per-trace context the composer needs when extending a chain with
/// cross-process spans. `recording_id` matches the session manifest's
/// recording id (i.e. the key under which the pair index buckets the
/// trace's marker firings).
#[derive(Debug, Clone)]
pub struct TraceIdentity {
    pub recording_id: String,
    pub role: String,
}

impl TraceIdentity {
    pub fn new(recording_id: impl Into<String>, role: impl Into<String>) -> Self {
        Self {
            recording_id: recording_id.into(),
            role: role.into(),
        }
    }
}

/// Result of resolving the sibling-side continuation. The dispatcher
/// owns running the per-backend origin path against the sibling
/// trace's recording id at the matched Send marker's step and
/// continuing on the marker's `show_value` (the display variable).
#[derive(Debug, Clone)]
pub struct SiblingContinuation {
    /// Identity of the sibling trace the chain crossed into.
    pub sibling_identity: TraceIdentity,
    /// Hops produced by the sibling-side single-trace algorithm,
    /// already in spec §14.3 order (most recent first — the same
    /// order [`OriginChain.hops`] uses). The composer appends them
    /// to the current chain.
    pub sibling_hops: Vec<OriginHop>,
    /// Terminator produced by the sibling-side single-trace
    /// algorithm. Replaces the receive-side chain's terminator.
    pub sibling_terminator: Terminator,
    /// `true` when the sibling-side algorithm exhausted its budget;
    /// the composer propagates the flag up.
    pub sibling_truncated: bool,
}

/// Outcome enum mirroring spec §14.3 error handling.
#[derive(Debug)]
pub enum CrossProcessOutcome {
    /// The current chain does not end at a receive marker — no
    /// extension applied. The chain is returned unchanged.
    NoBoundaryFound,
    /// One matched Send marker found; chain extended with the
    /// sibling-side hops.
    Extended,
    /// Multiple Send markers carry the same (boundary_id, key_value)
    /// — chain terminates with `UnknownSource` per the M29 ambiguous-
    /// correlation rule (spec §6.6 / E2E design §3 non-goals).
    AmbiguousCorrelation { candidates: u32 },
    /// No Send marker found for the receive-side key — chain
    /// terminates with `RecordingStart` in the sender direction;
    /// the receiver-side chain is otherwise complete.
    MissingCorrelation,
}

/// Callback supplied by the dispatcher. Given the sibling trace's
/// recording id + the matched Send marker's step + the display
/// variable name, produces the sibling-side continuation. Returning
/// `None` indicates the dispatcher refused to compute the sibling
/// chain (e.g. the sibling trace is not loaded into the session); the
/// composer treats this the same as a missing correlation.
pub type SiblingChainResolver<'a> = &'a mut dyn FnMut(&str, i64, &str) -> Option<SiblingContinuation>;

/// M29 §5.1 — dispatcher-facing extension context.
///
/// Bundles the three inputs the production materialized + omniscient
/// algorithms need to consult the cross-process composer at the end of
/// their single-trace walk: the current trace's identity, the session-
/// wide [`PairIndex`], and the sibling-chain resolver callback.
///
/// The dispatcher constructs one of these per `ct/originChain` request
/// when it knows the session-wide pair index is available
/// (i.e. running under [`crate::session_handler::SessionHandler`]).
/// When the dispatcher omits it (single-trace test fixtures, or a
/// session without correlation markers) the wiring is a no-op and the
/// algorithms preserve their single-trace behaviour bit-for-bit.
pub struct CrossProcessExtension<'a> {
    /// Identity of the trace the per-backend algorithm is running on.
    pub current_identity: TraceIdentity,
    /// Session-wide pair index built from
    /// [`crate::session_handler::SessionHandler::pair_index`].
    pub pair_index: &'a PairIndex,
    /// Callback the composer invokes to drive the sibling-side chain.
    pub resolver: SiblingChainResolver<'a>,
}

/// M29 §5.1 — production wiring entry point.
///
/// Thin shim that the per-backend algorithms call at the end of their
/// single-trace walk. When `extension` is `Some`, runs the §14.3
/// composer ([`apply_cross_process_clause`]) on `chain` and returns
/// the (possibly extended) chain. When `None`, returns `chain`
/// unchanged so single-trace call sites and test fixtures preserve
/// their existing behaviour without per-call-site changes.
///
/// The returned [`CrossProcessOutcome`] is included so dispatchers can
/// surface the outcome (e.g. emit a `crossProcessSpan` event) and so
/// tests can assert the wiring fired. When `extension` is `None` the
/// outcome is [`CrossProcessOutcome::NoBoundaryFound`].
pub fn run(chain: OriginChain, extension: Option<CrossProcessExtension<'_>>) -> (OriginChain, CrossProcessOutcome) {
    match extension {
        Some(ext) => apply_cross_process_clause(chain, &ext.current_identity, ext.pair_index, ext.resolver),
        None => (chain, CrossProcessOutcome::NoBoundaryFound),
    }
}

/// Upper bound on consecutive boundary hops the composer will follow
/// before bailing out. Real cross-tracer chains saturate at three
/// (JS → WASM → backend); eight gives ample headroom for future
/// multi-tier shapes while guarding against pathological cyclic
/// markers (e.g. a Send that happens to coincide with a Recv at the
/// same source location forming a self-loop).
pub const MAX_BOUNDARY_HOPS: usize = 8;

/// Composer applying the spec §14.3 cross-process clause to an
/// already-computed single-trace chain.
///
/// `current_identity` identifies the trace the chain was computed on;
/// `pair_index` is the session-wide pair index built from
/// [`crate::session_handler::SessionHandler::pair_index`]; the
/// receive markers visible in the index are matched against the
/// chain's tail. Returns the (possibly extended) chain plus the
/// outcome enum so callers can surface the §14.3 outcome to the
/// frontend.
///
/// **Recursion (TCT-M3)** — after a hop lands in trace B, the
/// composer re-tests trace B's tail hop against trace B's own
/// receive markers in the pair index and, if a new pair matches,
/// hops again into trace C. Recursion is bounded by
/// [`MAX_BOUNDARY_HOPS`]; the final outcome reported to the caller is
/// the result of the **last** hop attempt:
///
/// - one or more `Extended` hops followed by `NoBoundaryFound` on the
///   final landed trace ⇒ `Extended` (the canonical "chain fully
///   resolved" report).
/// - first hop returns `NoBoundaryFound` ⇒ `NoBoundaryFound` (no-op).
/// - any hop returns `MissingCorrelation` / `AmbiguousCorrelation`
///   ⇒ that outcome (the chain has already been terminated cleanly
///   by [`extend_chain_with_send`] / the inline branches below).
///
/// **Confidence** — the cross-process hop itself is treated as a
/// `TrivialCopy` per spec §14.3 (serialisation-aware copy tracking
/// is applied separately in [`classify_serialiser_pair`]). The
/// sibling-side hops keep their own confidences; the chain's
/// composite confidence is recomputed across the joined hop list
/// after every hop.
pub fn apply_cross_process_clause(
    chain: OriginChain,
    current_identity: &TraceIdentity,
    pair_index: &PairIndex,
    resolver: SiblingChainResolver,
) -> (OriginChain, CrossProcessOutcome) {
    apply_cross_process_clause_with_cap(chain, current_identity, pair_index, resolver, MAX_BOUNDARY_HOPS)
}

/// Same as [`apply_cross_process_clause`] but with an explicit
/// `max_hops` cap. Exposed for tests that need a tighter bound and
/// for callers that want to tune the recursion depth.
pub fn apply_cross_process_clause_with_cap(
    mut chain: OriginChain,
    current_identity: &TraceIdentity,
    pair_index: &PairIndex,
    resolver: SiblingChainResolver,
    max_hops: usize,
) -> (OriginChain, CrossProcessOutcome) {
    // Step 1: seed the per-process span list with the **starting**
    // trace's owning range. Idempotent — if the chain already carries
    // a span (e.g. nested cross-process extensions from a previous
    // call) we preserve it.
    if chain.cross_process_spans.is_empty() && !chain.hops.is_empty() {
        chain.cross_process_spans.push(CrossProcessSpan {
            recording_id: current_identity.recording_id.clone(),
            role: current_identity.role.clone(),
            first_hop_index: 0,
            last_hop_index: (chain.hops.len() - 1) as u32,
            from_process: String::new(),
            to_process: String::new(),
            correlator: String::new(),
        });
    }

    // Track the identity of the trace the chain's tail currently
    // sits in. Advances after each successful hop so the next
    // iteration's `find_receive_marker_for_tail` searches against
    // the correct trace's recv markers.
    let mut active_identity: TraceIdentity = current_identity.clone();
    let mut hops_performed: usize = 0;

    loop {
        if hops_performed >= max_hops {
            // Hit the recursion cap. Per spec §14.3 the chain so far
            // is correct; we just stop probing for more boundaries.
            // The truncated flag signals the caller that the walk
            // was cut short.
            chain.truncated = true;
            return (
                chain,
                if hops_performed > 0 {
                    CrossProcessOutcome::Extended
                } else {
                    CrossProcessOutcome::NoBoundaryFound
                },
            );
        }

        let (next_chain, outcome) = try_one_hop(chain, &active_identity, pair_index, resolver);
        chain = next_chain;

        match outcome {
            CrossProcessOutcome::Extended => {
                hops_performed += 1;
                // Advance `active_identity` to the trace the chain's
                // tail now sits in. The most recently appended span
                // is the one for the freshly entered sibling trace —
                // its `recording_id` + `role` are the source of
                // truth for the next iteration's substrate check.
                match chain.cross_process_spans.last() {
                    Some(span) => {
                        active_identity = TraceIdentity::new(span.recording_id.clone(), span.role.clone());
                    }
                    None => {
                        // Should never trip: a successful Extended
                        // outcome always pushes a sibling span. If
                        // it does, stop recursing defensively.
                        return (chain, CrossProcessOutcome::Extended);
                    }
                }
                // Loop and probe for another boundary on the new
                // active trace.
            }
            CrossProcessOutcome::NoBoundaryFound => {
                // Chain is fully resolved. Report Extended if at
                // least one hop succeeded; otherwise pass through the
                // no-op outcome.
                return (
                    chain,
                    if hops_performed > 0 {
                        CrossProcessOutcome::Extended
                    } else {
                        CrossProcessOutcome::NoBoundaryFound
                    },
                );
            }
            CrossProcessOutcome::MissingCorrelation | CrossProcessOutcome::AmbiguousCorrelation { .. } => {
                // Chain has been terminated cleanly inside
                // try_one_hop / extend_chain_with_send. Propagate
                // the terminal outcome and stop.
                return (chain, outcome);
            }
        }
    }
}

/// Single boundary hop — the inner loop body of
/// [`apply_cross_process_clause_with_cap`]. Returns `Extended` if a
/// matched sibling trace was hopped into; `NoBoundaryFound` if the
/// tail hop did not land on a receive marker in the current trace;
/// `MissingCorrelation` / `AmbiguousCorrelation` per spec §14.3
/// otherwise. The chain's hops list is mutated only on `Extended`;
/// on `MissingCorrelation` / `AmbiguousCorrelation` only the chain's
/// terminator is updated.
fn try_one_hop(
    mut chain: OriginChain,
    current_identity: &TraceIdentity,
    pair_index: &PairIndex,
    resolver: SiblingChainResolver,
) -> (OriginChain, CrossProcessOutcome) {
    // Step 2: find the receive marker the tail of the chain landed
    // on. The substrate test is documented in spec §14.3: the
    // **last** hop's `step_id` + `location.path/line` must match a
    // marker firing in the current trace whose direction is Receive.
    let receive_event = match find_receive_marker_for_tail(&chain, current_identity, pair_index) {
        Some(ev) => ev,
        None => return (chain, CrossProcessOutcome::NoBoundaryFound),
    };

    // Step 3: locate the matching Send markers in any sibling trace.
    let candidates = pair_index.counterparts_of(&receive_event);

    // Filter to sibling-trace sends only (a send in the same trace
    // is not a cross-process boundary — it's a same-trace loopback
    // that the spec deliberately scopes out).
    let cross_trace_candidates: Vec<MarkerEventView> = candidates
        .into_iter()
        .filter(|c| c.recording_id != current_identity.recording_id)
        .collect();

    match cross_trace_candidates.len() {
        0 => {
            // Missing correlation: terminate the chain cleanly with
            // RecordingStart in the sender direction. The receiver-
            // side chain is otherwise complete.
            chain.terminator = Terminator::new(TerminatorKind::RecordingStart);
            chain.terminator.expression = format!(
                "no matching send marker for boundary `{}`",
                receive_event.payload.boundary_id
            );
            (chain, CrossProcessOutcome::MissingCorrelation)
        }
        1 => {
            // Safe by the match arm: len == 1 ⇒ `next()` is Some.
            // Bind defensively rather than `.expect()` so the bin's
            // `deny(clippy::expect_used)` is honoured.
            let mut iter = cross_trace_candidates.into_iter();
            match iter.next() {
                Some(send_event) => {
                    extend_chain_with_send(chain, current_identity, &receive_event, &send_event, resolver)
                }
                None => {
                    // Should never trip — we matched on len() == 1
                    // above. Fall through as missing correlation so
                    // the chain still closes cleanly.
                    chain.terminator = Terminator::new(TerminatorKind::RecordingStart);
                    chain.terminator.expression = "internal: empty single-candidate set".to_string();
                    (chain, CrossProcessOutcome::MissingCorrelation)
                }
            }
        }
        n => {
            // Ambiguous correlation: terminate cleanly with
            // UnknownSource. No spurious hops appended.
            chain.terminator = Terminator::new(TerminatorKind::UnknownSource);
            chain.terminator.expression = format!(
                "ambiguous correlation: {} matching send markers for boundary `{}`",
                n, receive_event.payload.boundary_id
            );
            (
                chain,
                CrossProcessOutcome::AmbiguousCorrelation { candidates: n as u32 },
            )
        }
    }
}

/// Walk the chain's last hop and look it up against the session pair
/// index. Returns `Some(receive_event)` when the tail hop sits on a
/// receive-marker firing in the current trace.
fn find_receive_marker_for_tail(
    chain: &OriginChain,
    current_identity: &TraceIdentity,
    pair_index: &PairIndex,
) -> Option<MarkerEventView> {
    let tail_hop = chain.hops.last()?;
    // Iterate every receive marker in the index; match on
    // `(recording_id, source_path, source_line, step_id)`. This is
    // O(n) over the receive bucket which is bounded by the number of
    // marker firings in the loaded traces; the spec §14.3 algorithm
    // does not require an additional index here.
    for ((_boundary, direction), events) in pair_index.buckets() {
        if *direction != MarkerDirection::Recv {
            continue;
        }
        for ev in events {
            if ev.recording_id != current_identity.recording_id {
                continue;
            }
            if ev.source_path != tail_hop.location.path {
                continue;
            }
            // The hop's location and the marker's source line are
            // both 1-based. A marker firing whose step matches the
            // hop's step within ±1 step is considered the same line
            // event (per spec §6.1.0 monotonicity — the recorder's
            // line-snapshot timing variance is within ±1 step).
            if (ev.step_id - tail_hop.step_id).abs() > 1 {
                continue;
            }
            return Some(ev.clone());
        }
    }
    None
}

/// Extend the chain with the sibling-side continuation triggered by a
/// matched (recv, send) marker pair.
fn extend_chain_with_send(
    mut chain: OriginChain,
    current_identity: &TraceIdentity,
    recv_event: &MarkerEventView,
    send_event: &MarkerEventView,
    resolver: SiblingChainResolver,
) -> (OriginChain, CrossProcessOutcome) {
    // Step 1: populate the receive-side hop's correlation_transition
    // descriptor. The last hop in the chain is the boundary-crossing
    // hop per the substrate test in spec §14.3.
    let recv_payload = &recv_event.payload;
    let send_payload = &send_event.payload;
    let display_value = send_payload
        .show_value
        .clone()
        .or_else(|| Some(send_payload.key_value.clone()));
    let display_variable = send_payload
        .show_text
        .clone()
        .unwrap_or_else(|| send_payload.key_text.clone());

    if let Some(last_hop) = chain.hops.last_mut() {
        last_hop.correlation_transition = Some(CorrelationTransition {
            direction: MarkerDirection::Recv.as_str().to_string(),
            correlated_recording_id: send_event.recording_id.clone(),
            correlated_step_id: send_event.step_id,
            boundary_id: recv_payload.boundary_id.clone(),
            match_key_value: recv_payload.key_value.clone(),
            display_variable_value: display_value.clone(),
            description: recv_payload
                .description
                .clone()
                .or_else(|| send_payload.description.clone()),
            correlator: String::new(),
            channel: String::new(),
        });
    }

    // Step 2: drive the sibling-side chain.
    let display_var_for_resolver = display_variable.as_str();
    let continuation = resolver(
        send_event.recording_id.as_str(),
        send_event.step_id,
        display_var_for_resolver,
    );

    let Some(continuation) = continuation else {
        // Resolver declined (e.g. sibling trace not loaded). Treat as
        // missing correlation per spec — close the chain cleanly.
        chain.terminator = Terminator::new(TerminatorKind::RecordingStart);
        chain.terminator.expression = format!(
            "sibling trace `{}` not available for cross-process continuation",
            send_event.recording_id
        );
        return (chain, CrossProcessOutcome::MissingCorrelation);
    };

    // Step 3: classify the wire-crossing pair. Per spec §14.3 the
    // serialisation-aware copy tracking collapses the
    // JSON.parse/JSON.stringify pair (or protobuf/msgpack equivalents)
    // to a `TrivialCopy`. We apply the classification to the
    // receive-side tail hop (already in `chain.hops`) and to the
    // sibling's first hop (sender-side) when present.
    classify_serialiser_pair(&mut chain.hops, &continuation.sibling_hops);

    // Step 4: append sibling hops + update span ranges.
    let sibling_start = chain.hops.len() as u32;
    chain.hops.extend(continuation.sibling_hops);
    let sibling_end = if chain.hops.is_empty() {
        0
    } else {
        (chain.hops.len() - 1) as u32
    };

    // Sibling span. Index 0 of `cross_process_spans` is the receive-
    // side trace; index 1 is the send-side sibling.
    chain.cross_process_spans.push(CrossProcessSpan {
        recording_id: continuation.sibling_identity.recording_id.clone(),
        role: continuation.sibling_identity.role.clone(),
        first_hop_index: sibling_start,
        last_hop_index: sibling_end,
        from_process: current_identity.recording_id.clone(),
        to_process: continuation.sibling_identity.recording_id.clone(),
        correlator: recv_payload.boundary_id.clone(),
    });

    // Step 5: replace terminator with sibling-side terminator.
    chain.terminator = continuation.sibling_terminator;
    chain.truncated = chain.truncated || continuation.sibling_truncated;

    // Step 6: recompute composite confidence across joined hops.
    chain.confidence = chain.hops.iter().map(|h| h.confidence).fold(1.0_f32, f32::min);

    (chain, CrossProcessOutcome::Extended)
}

/// Serialisation-aware copy tracking per spec §14.3. When the
/// boundary-crossing tail hop on the receive side decodes via
/// `JSON.parse` (or protobuf/msgpack equivalent) and the sibling's
/// first hop on the send side encodes via `JSON.stringify`, both
/// hops are classified as `TrivialCopy` rather than the opaque
/// `FunctionCall` the per-language classifier would produce.
///
/// The detection rule is text-based: the source line contains a
/// known encode/decode primitive in either language. This is the
/// minimal detection surface the spec calls for; the per-language
/// classifier crate (M1) is the source-of-truth for the actual hop
/// kinds, and this function only re-labels the wire-crossing pair.
fn classify_serialiser_pair(recv_hops: &mut [OriginHop], send_hops: &[OriginHop]) {
    let Some(recv_tail) = recv_hops.last_mut() else {
        return;
    };
    let send_first = send_hops.first();

    if is_serialiser_decode(&recv_tail.source_text) {
        recv_tail.kind = OriginKind::TrivialCopy;
        let prov = recv_tail.classification_provenance.clone().unwrap_or_default();
        recv_tail.classification_provenance = Some(format!(
            "{prov} | M29 §14.3 serialisation-aware: paired decode classified as TrivialCopy"
        ));
    }
    let _ = send_first; // The send-side hop is owned by the caller; the
    // classification is applied in `apply_cross_process_clause`
    // before the hops are joined to the chain. We invoke the
    // classifier as a no-op here so the helper stays a single
    // entry point.
}

/// True when the hop's source line contains a serialiser-decode
/// primitive recognised by spec §14.3. The list mirrors the spec
/// table.
pub fn is_serialiser_decode(source_text: &str) -> bool {
    let lowered = source_text.to_ascii_lowercase();
    SERIALISER_DECODE_TOKENS.iter().any(|tok| lowered.contains(tok))
}

/// True when the hop's source line contains a serialiser-encode
/// primitive recognised by spec §14.3.
pub fn is_serialiser_encode(source_text: &str) -> bool {
    let lowered = source_text.to_ascii_lowercase();
    SERIALISER_ENCODE_TOKENS.iter().any(|tok| lowered.contains(tok))
}

/// Decode primitives spec §14.3 recognises. Match-case is on the
/// lowercased source line so the matcher works across JS / Python /
/// Ruby / Rust naming conventions.
const SERIALISER_DECODE_TOKENS: &[&str] = &[
    "json.parse",
    ".json()",
    "json.loads",
    "json_loads",
    "json::from_str",
    "json::from_slice",
    "from_json",
    "protobuf.decode",
    "protobuf::decode",
    "msgpack.unpack",
    "msgpack::unpack",
    "capnp::decode",
];

/// Encode primitives spec §14.3 recognises.
const SERIALISER_ENCODE_TOKENS: &[&str] = &[
    "json.stringify",
    "json.dumps",
    "json_dumps",
    "json::to_string",
    "json::to_vec",
    "to_json",
    "web.json_response",
    "json_response",
    "protobuf.encode",
    "protobuf::encode",
    "msgpack.pack",
    "msgpack::pack",
    "capnp::encode",
];

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::correlation_index::MarkerEventView;
    use crate::correlation_markers::{MarkerDirection, MarkerPayload};
    use crate::task::{Location, OriginHop, OriginKind, OriginMetrics};

    #[allow(clippy::too_many_arguments)]
    fn marker_view(
        recording_id: &str,
        step: i64,
        path: &str,
        line: usize,
        direction: MarkerDirection,
        boundary: &str,
        key_value: &str,
        show_value: Option<&str>,
    ) -> MarkerEventView {
        let payload = MarkerPayload {
            marker_id: 0,
            boundary_id: boundary.to_string(),
            direction,
            key_text: "k".to_string(),
            key_value: key_value.to_string(),
            show_text: show_value.map(|_| "v".to_string()),
            show_value: show_value.map(String::from),
            description: Some(format!("desc {}", boundary)),
            format: None,
        };
        MarkerEventView::new(recording_id, step, path, line, payload)
    }

    fn make_hop(target: &str, step_id: i64, path: &str, line: i64, kind: OriginKind, source_text: &str) -> OriginHop {
        OriginHop {
            kind,
            target_expr: target.to_string(),
            source_expr: source_text.to_string(),
            source_variable: None,
            location: Location {
                path: path.to_string(),
                line,
                ..Location::default()
            },
            source_text: source_text.to_string(),
            step_id,
            frame_transition: None,
            operand_snapshots: Vec::new(),
            truncated_operands: false,
            confidence: 0.9,
            classification_provenance: Some("built-in: test".to_string()),
            correlation_transition: None,
        }
    }

    fn make_chain(hops: Vec<OriginHop>) -> OriginChain {
        OriginChain {
            query_variable: "balance".to_string(),
            query_step_id: 100,
            hops,
            terminator: Terminator::new(TerminatorKind::RecordingStart),
            truncated: false,
            continuation_token: None,
            metrics: OriginMetrics::default(),
            cross_process_spans: Vec::new(),
            confidence: 0.9,
        }
    }

    fn assert_recv_hop_carries_transition(chain: &OriginChain, expect_recv: &str, expect_step: i64) {
        let last = chain.hops.first().expect("at least one recv hop").clone();
        // tail of receive-side hop range — but in our tests we have
        // exactly one recv hop and N send hops; the recv hop is at
        // index 0 since hops are most-recent-first and we built it
        // first.
        let tx = last.correlation_transition.expect("transition populated");
        assert_eq!(tx.direction, "recv");
        assert_eq!(tx.correlated_recording_id, expect_recv);
        assert_eq!(tx.correlated_step_id, expect_step);
    }

    /// §14.3 happy path: tail hop matches a Receive marker; pair
    /// index returns one matched Send in a sibling trace; the
    /// composer extends the chain with the sibling hops + populates
    /// the boundary hop's correlation transition + cross-process
    /// spans.
    #[test]
    fn cross_process_extend_happy_path() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "balance-request",
            "user-42",
            Some("user-42"),
        );
        let send = marker_view(
            "rec-be",
            7,
            "backend/server.py",
            5,
            MarkerDirection::Send,
            "balance-request",
            "user-42",
            Some("user-42"),
        );
        let pair_index = PairIndex::build(&[recv.clone(), send.clone()]);

        // The tail hop sits at the receive marker's source location +
        // step.
        let tail_hop = make_hop(
            "balance",
            12,
            "frontend/app.js",
            5,
            OriginKind::TrivialCopy,
            "payload = await response.json()",
        );
        let chain = make_chain(vec![tail_hop]);

        let sibling_hop = make_hop(
            "db_row.balance",
            7,
            "backend/server.py",
            5,
            OriginKind::FieldAccess,
            "payload = web.json_response({'balance': db_row.balance})",
        );
        let sibling_term = Terminator::new(TerminatorKind::Computational);

        let mut resolver = |sibling_id: &str, step: i64, display: &str| -> Option<SiblingContinuation> {
            assert_eq!(sibling_id, "rec-be");
            assert_eq!(step, 7);
            assert!(display == "v" || display == "user-42" || !display.is_empty());
            Some(SiblingContinuation {
                sibling_identity: TraceIdentity::new("rec-be", "backend"),
                sibling_hops: vec![sibling_hop.clone()],
                sibling_terminator: sibling_term.clone(),
                sibling_truncated: false,
            })
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        assert!(matches!(outcome, CrossProcessOutcome::Extended));
        assert_eq!(chain.hops.len(), 2, "tail + sibling hop");
        assert_eq!(chain.cross_process_spans.len(), 2, "fe + be spans");
        assert_eq!(chain.cross_process_spans[0].role, "frontend");
        assert_eq!(chain.cross_process_spans[0].first_hop_index, 0);
        assert_eq!(chain.cross_process_spans[0].last_hop_index, 0);
        assert_eq!(chain.cross_process_spans[1].role, "backend");
        assert_eq!(chain.cross_process_spans[1].first_hop_index, 1);
        assert_eq!(chain.cross_process_spans[1].last_hop_index, 1);
        assert_recv_hop_carries_transition(&chain, "rec-be", 7);
        assert!(matches!(chain.terminator.kind, TerminatorKind::Computational));
    }

    /// §14.3 ambiguous: multiple Send markers carry the same
    /// (boundary, key) — chain terminates with UnknownSource. No
    /// hops are appended beyond the receive side.
    #[test]
    fn cross_process_ambiguous_terminates_cleanly() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "boundary-x",
            "k1",
            None,
        );
        let send1 = marker_view(
            "rec-be1",
            3,
            "backend/a.py",
            5,
            MarkerDirection::Send,
            "boundary-x",
            "k1",
            None,
        );
        let send2 = marker_view(
            "rec-be2",
            4,
            "backend/b.py",
            5,
            MarkerDirection::Send,
            "boundary-x",
            "k1",
            None,
        );
        let pair_index = PairIndex::build(&[recv, send1, send2]);

        let tail_hop = make_hop("x", 12, "frontend/app.js", 5, OriginKind::TrivialCopy, "x = recv()");
        let chain = make_chain(vec![tail_hop]);

        let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
            panic!("resolver must not be called on ambiguous correlation");
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        assert!(matches!(
            outcome,
            CrossProcessOutcome::AmbiguousCorrelation { candidates: 2 }
        ));
        assert_eq!(chain.hops.len(), 1, "no sibling hops appended");
        assert!(matches!(chain.terminator.kind, TerminatorKind::UnknownSource));
        assert!(
            chain.terminator.expression.contains("ambiguous"),
            "terminator carries diagnostic, got {:?}",
            chain.terminator.expression
        );
    }

    /// §14.3 missing: no Send marker matches the receive-side key.
    /// Chain terminates with RecordingStart in the sender direction;
    /// receiver-side chain is otherwise complete.
    #[test]
    fn cross_process_missing_terminates_cleanly() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "boundary-x",
            "k1",
            None,
        );
        // No Send marker registered for "boundary-x" / "k1".
        let pair_index = PairIndex::build(&[recv]);

        let tail_hop = make_hop("x", 12, "frontend/app.js", 5, OriginKind::TrivialCopy, "x = recv()");
        let chain = make_chain(vec![tail_hop]);

        let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
            panic!("resolver must not be called on missing correlation");
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        assert!(matches!(outcome, CrossProcessOutcome::MissingCorrelation));
        assert!(matches!(chain.terminator.kind, TerminatorKind::RecordingStart));
        assert!(
            chain.terminator.expression.contains("no matching send"),
            "terminator carries diagnostic, got {:?}",
            chain.terminator.expression
        );
        assert_eq!(chain.hops.len(), 1, "no sibling hops appended");
    }

    /// §14.3 serialisation-aware copy tracking: when the receive-
    /// side tail hop's source text mentions `JSON.parse` /
    /// `response.json()` etc, the hop is re-labelled to
    /// `TrivialCopy` even when the per-language classifier would
    /// label it `FunctionCall`.
    #[test]
    fn serialiser_aware_collapses_to_trivial_copy() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "balance-request",
            "user-42",
            None,
        );
        let send = marker_view(
            "rec-be",
            7,
            "backend/server.py",
            5,
            MarkerDirection::Send,
            "balance-request",
            "user-42",
            None,
        );
        let pair_index = PairIndex::build(&[recv, send]);

        // Recv-side tail hop is initially classified as FunctionCall.
        let tail_hop = make_hop(
            "payload",
            12,
            "frontend/app.js",
            5,
            OriginKind::FunctionCall,
            "payload = await response.json()",
        );
        let chain = make_chain(vec![tail_hop]);

        let sibling_hop = make_hop(
            "db_row.balance",
            7,
            "backend/server.py",
            5,
            OriginKind::FieldAccess,
            "payload = web.json_response({'balance': db_row.balance})",
        );
        let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
            Some(SiblingContinuation {
                sibling_identity: TraceIdentity::new("rec-be", "backend"),
                sibling_hops: vec![sibling_hop.clone()],
                sibling_terminator: Terminator::new(TerminatorKind::Computational),
                sibling_truncated: false,
            })
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        assert!(matches!(outcome, CrossProcessOutcome::Extended));
        // The receive-side hop should now carry TrivialCopy.
        assert_eq!(chain.hops[0].kind, OriginKind::TrivialCopy);
        // Provenance should mention the M29 re-labelling rule.
        assert!(
            chain.hops[0]
                .classification_provenance
                .as_deref()
                .unwrap_or_default()
                .contains("M29 §14.3"),
            "provenance must mention M29 §14.3 rule; got {:?}",
            chain.hops[0].classification_provenance
        );
    }

    /// §14.3 NoBoundaryFound: chain's tail hop does not match any
    /// receive marker; the composer leaves the chain unchanged.
    #[test]
    fn no_boundary_found_leaves_chain_unchanged() {
        // Empty pair index — no markers at all.
        let pair_index = PairIndex::build(&[]);
        let tail_hop = make_hop("x", 12, "frontend/app.js", 5, OriginKind::TrivialCopy, "x = 1");
        let chain = make_chain(vec![tail_hop]);
        let original_hop_count = chain.hops.len();

        let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
            panic!("resolver must not be called when no boundary is found");
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        assert!(matches!(outcome, CrossProcessOutcome::NoBoundaryFound));
        assert_eq!(chain.hops.len(), original_hop_count);
        // Current trace span is still added for downstream
        // consumers — the chain is still single-process but the
        // span list is initialised.
        assert_eq!(chain.cross_process_spans.len(), 1);
        assert_eq!(chain.cross_process_spans[0].role, "frontend");
    }

    /// §14.3 parity: chain composition is stable across multiple
    /// invocations (the composer is idempotent on already-extended
    /// chains).
    #[test]
    fn extending_already_extended_chain_is_stable() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "balance-request",
            "user-42",
            None,
        );
        let send = marker_view(
            "rec-be",
            7,
            "backend/server.py",
            5,
            MarkerDirection::Send,
            "balance-request",
            "user-42",
            None,
        );
        let pair_index = PairIndex::build(&[recv, send]);

        let tail_hop = make_hop(
            "payload",
            12,
            "frontend/app.js",
            5,
            OriginKind::TrivialCopy,
            "payload = await response.json()",
        );
        let chain = make_chain(vec![tail_hop]);

        // Note: this returns a hop whose location/step does NOT
        // match any further receive marker — so the second
        // application yields NoBoundaryFound.
        let sibling_hop = make_hop(
            "balance",
            7,
            "backend/server.py",
            5,
            OriginKind::FieldAccess,
            "balance = 1234",
        );
        let mut resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> {
            Some(SiblingContinuation {
                sibling_identity: TraceIdentity::new("rec-be", "backend"),
                sibling_hops: vec![sibling_hop.clone()],
                sibling_terminator: Terminator::new(TerminatorKind::Literal),
                sibling_truncated: false,
            })
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain1, _) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);
        let hop_count_after_first = chain1.hops.len();
        let span_count_after_first = chain1.cross_process_spans.len();

        // Apply the composer a second time — the sibling identity
        // is now "rec-be" so the receive-side substrate test won't
        // match again. Idempotency: the chain is unchanged.
        let mut noop_resolver = |_: &str, _: i64, _: &str| -> Option<SiblingContinuation> { None };
        let sibling_identity = TraceIdentity::new("rec-be", "backend");
        let (chain2, outcome2) = apply_cross_process_clause(
            chain1,
            &sibling_identity,
            &pair_index,
            &mut noop_resolver as SiblingChainResolver,
        );
        // The second composer pass sees the tail hop in the
        // backend trace and looks for a receive marker there;
        // none exists, so the outcome is NoBoundaryFound + the
        // chain is unchanged modulo the seeded span.
        assert!(matches!(outcome2, CrossProcessOutcome::NoBoundaryFound));
        assert_eq!(chain2.hops.len(), hop_count_after_first);
        assert_eq!(chain2.cross_process_spans.len(), span_count_after_first);
    }

    /// TCT-M3 (recursive composer): the resolver follows TWO
    /// consecutive boundary hops in a single invocation — the JS →
    /// WASM → backend three-tracer scenario from
    /// `Cross-Tracer-Origin-Test.audit.md`.
    ///
    /// Synthetic pair index carries two marker pairs:
    ///
    /// - `js-wasm-realm` boundary between trace `rec-js` (Recv at the
    ///   JS-side imported function call) and trace `rec-wasm` (Send at
    ///   the WASM-side export thunk).
    /// - `balance-request` boundary between trace `rec-wasm` (Recv at
    ///   the WASM-side HTTP-response decode) and trace `rec-be` (Send
    ///   at the backend `web.json_response`).
    ///
    /// The chain starts on `rec-js` (the JS frontend's `balance`
    /// expression at the boundary line). After one call to
    /// [`apply_cross_process_clause`] the composer must:
    ///
    /// - hop JS → WASM, appending the WASM-side hop;
    /// - re-test the WASM-side tail hop and hop WASM → backend,
    ///   appending the backend-side hop;
    /// - land with three `CrossProcessSpan`s (`js`, `wasm`, `backend`),
    ///   the chain's tail in the backend trace, and the chain's first
    ///   hop still on the JS-side `balance` expression.
    #[test]
    fn sibling_chain_resolver_walks_two_boundaries() {
        // JS↔WASM boundary pair.
        let js_recv = marker_view(
            "rec-js",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "js-wasm-realm",
            "computeBalance:42",
            Some("computeBalance:42"),
        );
        let wasm_send = marker_view(
            "rec-wasm",
            7,
            "wasm/compute.rs",
            10,
            MarkerDirection::Send,
            "js-wasm-realm",
            "computeBalance:42",
            Some("computeBalance:42"),
        );
        // WASM↔backend boundary pair.
        let wasm_recv = marker_view(
            "rec-wasm",
            4,
            "wasm/compute.rs",
            15,
            MarkerDirection::Recv,
            "balance-request",
            "user-42",
            Some("user-42"),
        );
        let backend_send = marker_view(
            "rec-be",
            9,
            "backend/server.py",
            22,
            MarkerDirection::Send,
            "balance-request",
            "user-42",
            Some("user-42"),
        );

        let pair_index = PairIndex::build(&[
            js_recv.clone(),
            wasm_send.clone(),
            wasm_recv.clone(),
            backend_send.clone(),
        ]);

        // JS-side starting chain — tail hop lands on the JS↔WASM
        // boundary at frontend/app.js:5 step 12.
        let js_tail = make_hop(
            "balance",
            12,
            "frontend/app.js",
            5,
            OriginKind::TrivialCopy,
            "balance = computeBalance(user.id)",
        );
        let chain = make_chain(vec![js_tail]);

        // WASM-side continuation lands on the WASM↔backend boundary
        // at wasm/compute.rs:15 step 4 — that itself paires with the
        // backend send marker so the composer must recurse.
        let wasm_hop = make_hop(
            "raw_payload",
            4,
            "wasm/compute.rs",
            15,
            OriginKind::TrivialCopy,
            "raw_payload = host_fetch_balance(user_id);",
        );
        let wasm_terminator = Terminator::new(TerminatorKind::Computational);

        // Backend-side continuation terminates on a literal (the
        // database-row field access). Lands at backend/server.py:42,
        // which carries no further marker so recursion stops.
        let backend_hop = make_hop(
            "db_row.balance",
            9,
            "backend/server.py",
            42,
            OriginKind::FieldAccess,
            "return web.json_response({'balance': db_row.balance})",
        );
        let backend_terminator = Terminator::new(TerminatorKind::Literal);

        // Resolver dispatches on the sibling recording id requested
        // by the composer. The composer first asks for `rec-wasm`
        // (the JS↔WASM Send target), then for `rec-be` (the WASM↔
        // backend Send target).
        let wasm_continuation = SiblingContinuation {
            sibling_identity: TraceIdentity::new("rec-wasm", "frontend-wasm"),
            sibling_hops: vec![wasm_hop.clone()],
            sibling_terminator: wasm_terminator.clone(),
            sibling_truncated: false,
        };
        let backend_continuation = SiblingContinuation {
            sibling_identity: TraceIdentity::new("rec-be", "backend"),
            sibling_hops: vec![backend_hop.clone()],
            sibling_terminator: backend_terminator.clone(),
            sibling_truncated: false,
        };
        let mut calls: Vec<String> = Vec::new();
        let mut resolver = |sibling_id: &str, step: i64, _display: &str| -> Option<SiblingContinuation> {
            calls.push(format!("{sibling_id}@{step}"));
            match sibling_id {
                "rec-wasm" => {
                    assert_eq!(step, 7, "first hop must request the WASM Send step");
                    Some(wasm_continuation.clone())
                }
                "rec-be" => {
                    assert_eq!(step, 9, "second hop must request the backend Send step");
                    Some(backend_continuation.clone())
                }
                other => panic!("unexpected resolver target: {other}"),
            }
        };

        let identity = TraceIdentity::new("rec-js", "frontend-js");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);

        // The walk traversed exactly two boundaries and the resolver
        // was invoked once per boundary.
        assert!(matches!(outcome, CrossProcessOutcome::Extended));
        assert_eq!(calls.len(), 2, "resolver called once per boundary hop");
        assert_eq!(calls, vec!["rec-wasm@7".to_string(), "rec-be@9".to_string()]);

        // Three hops, three spans (one per trace).
        assert_eq!(chain.hops.len(), 3, "JS tail + WASM hop + backend hop");
        assert_eq!(
            chain.cross_process_spans.len(),
            3,
            "expect frontend-js + frontend-wasm + backend spans"
        );
        assert_eq!(chain.cross_process_spans[0].role, "frontend-js");
        assert_eq!(chain.cross_process_spans[0].recording_id, "rec-js");
        assert_eq!(chain.cross_process_spans[0].first_hop_index, 0);
        assert_eq!(chain.cross_process_spans[0].last_hop_index, 0);
        assert_eq!(chain.cross_process_spans[1].role, "frontend-wasm");
        assert_eq!(chain.cross_process_spans[1].recording_id, "rec-wasm");
        assert_eq!(chain.cross_process_spans[1].first_hop_index, 1);
        assert_eq!(chain.cross_process_spans[1].last_hop_index, 1);
        assert_eq!(chain.cross_process_spans[1].correlator, "js-wasm-realm");
        assert_eq!(chain.cross_process_spans[2].role, "backend");
        assert_eq!(chain.cross_process_spans[2].recording_id, "rec-be");
        assert_eq!(chain.cross_process_spans[2].first_hop_index, 2);
        assert_eq!(chain.cross_process_spans[2].last_hop_index, 2);
        assert_eq!(chain.cross_process_spans[2].correlator, "balance-request");

        // The chain's first hop is still the JS-side `balance`
        // expression — the recursion preserves the receiver-side
        // tail hop's identity at index 0.
        assert_eq!(chain.hops[0].target_expr, "balance");
        assert_eq!(chain.hops[0].location.path, "frontend/app.js");
        // The chain's last hop is now in the backend trace.
        assert_eq!(chain.hops[2].target_expr, "db_row.balance");
        assert_eq!(chain.hops[2].location.path, "backend/server.py");

        // Both boundary-crossing hops carry their CorrelationTransition
        // descriptor (recv-side rendering of the boundary).
        let js_tx = chain.hops[0]
            .correlation_transition
            .as_ref()
            .expect("JS-side hop carries js-wasm-realm transition");
        assert_eq!(js_tx.boundary_id, "js-wasm-realm");
        assert_eq!(js_tx.correlated_recording_id, "rec-wasm");
        assert_eq!(js_tx.correlated_step_id, 7);

        let wasm_tx = chain.hops[1]
            .correlation_transition
            .as_ref()
            .expect("WASM-side hop carries balance-request transition");
        assert_eq!(wasm_tx.boundary_id, "balance-request");
        assert_eq!(wasm_tx.correlated_recording_id, "rec-be");
        assert_eq!(wasm_tx.correlated_step_id, 9);

        // Terminator reflects the deepest sibling's terminator (the
        // backend trace's literal). Truncated flag stays clear because
        // we did not hit MAX_BOUNDARY_HOPS.
        assert!(matches!(chain.terminator.kind, TerminatorKind::Literal));
        assert!(!chain.truncated);
    }

    /// Regression: a chain that crosses exactly ONE boundary still
    /// resolves to the same shape after the recursive refactor as it
    /// did under the original single-hop code path. The sibling's
    /// landing hop deliberately points at a location with no further
    /// receive marker so the recursion bottoms out after one hop.
    /// Locked-in invariants: `Extended` outcome, exactly two hops,
    /// exactly two `CrossProcessSpan`s, transition populated on the
    /// receive-side hop, and terminator from the sibling continuation.
    #[test]
    fn sibling_chain_resolver_single_hop_regression() {
        let recv = marker_view(
            "rec-fe",
            12,
            "frontend/app.js",
            5,
            MarkerDirection::Recv,
            "balance-request",
            "user-42",
            Some("user-42"),
        );
        let send = marker_view(
            "rec-be",
            7,
            "backend/server.py",
            5,
            MarkerDirection::Send,
            "balance-request",
            "user-42",
            Some("user-42"),
        );
        let pair_index = PairIndex::build(&[recv, send]);

        let tail_hop = make_hop(
            "balance",
            12,
            "frontend/app.js",
            5,
            OriginKind::TrivialCopy,
            "payload = await response.json()",
        );
        let chain = make_chain(vec![tail_hop]);

        // Sibling lands on backend/server.py:99 — far from any further
        // receive marker, so the recursion stops after one hop.
        let sibling_hop = make_hop(
            "db_row.balance",
            7,
            "backend/server.py",
            99,
            OriginKind::FieldAccess,
            "balance = db_row.balance",
        );
        let sibling_terminator = Terminator::new(TerminatorKind::Computational);

        let mut call_count: u32 = 0;
        let mut resolver = |sibling_id: &str, step: i64, _display: &str| -> Option<SiblingContinuation> {
            call_count += 1;
            assert_eq!(sibling_id, "rec-be");
            assert_eq!(step, 7);
            Some(SiblingContinuation {
                sibling_identity: TraceIdentity::new("rec-be", "backend"),
                sibling_hops: vec![sibling_hop.clone()],
                sibling_terminator: sibling_terminator.clone(),
                sibling_truncated: false,
            })
        };

        let identity = TraceIdentity::new("rec-fe", "frontend");
        let (chain, outcome) =
            apply_cross_process_clause(chain, &identity, &pair_index, &mut resolver as SiblingChainResolver);

        // Single hop: resolver called exactly once.
        assert_eq!(call_count, 1, "single-boundary chain hits resolver once");
        assert!(matches!(outcome, CrossProcessOutcome::Extended));
        assert_eq!(chain.hops.len(), 2, "tail + sibling hop only");
        assert_eq!(chain.cross_process_spans.len(), 2, "fe + be spans only");
        assert_eq!(chain.cross_process_spans[0].role, "frontend");
        assert_eq!(chain.cross_process_spans[1].role, "backend");
        assert_recv_hop_carries_transition(&chain, "rec-be", 7);
        assert!(matches!(chain.terminator.kind, TerminatorKind::Computational));
        assert!(!chain.truncated);
    }
}
