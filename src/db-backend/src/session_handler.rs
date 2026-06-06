//! M24 — `SessionHandler`: thin multiplexer over per-trace
//! single-trace `Handler`s.
//!
//! Spec reference: Value-Origin-Tracking GUI doc § 14.1 + M24 milestone.
//!
//! ## Routing model
//!
//! A multi-trace debugging session presents a **flat thread list** to
//! the DAP client. Each `[[trace]]` entry in `session.toml` contributes
//! its own threads, prefixed by the entry's `default_thread_prefix`
//! (`fe:thread-1`, `be:thread-1`, ...). Under the hood, the
//! `SessionHandler` resolves the per-thread DAP request to the
//! correct trace's single-trace [`crate::dap_handler::Handler`].
//!
//! The composed thread id is encoded as:
//!
//! ```text
//! composed_thread_id = (trace_slot << 24) | inner_thread_id
//! ```
//!
//! The high 8 bits identify the trace slot (manifest order) and the
//! low 24 bits carry the inner thread id as returned by the trace's
//! own `Handler::threads` response. This shape gives us:
//!
//! - **Backwards compat**: trace slot 0 with inner thread id 1 maps to
//!   composed id 1 — exactly what single-trace clients see today. The
//!   M24 `test_session_handler_single_trace_backcompat` verifies this.
//! - **Ample headroom**: 24 bits = 16 M inner threads per trace, and
//!   8 bits = 256 simultaneous traces per session. The spec § 14.1
//!   example pairs at most a handful of traces, so we are nowhere
//!   close to the budget.
//!
//! The encoding is bidirectional: `decompose_thread_id` extracts the
//! slot + inner id from any composed id so DAP requests can be
//! dispatched without lookups.
//!
//! ## What is NOT here
//!
//! The single-trace `Handler` code is unchanged — the M24 deliverables
//! explicitly call this out as a constraint. `SessionHandler` only
//! provides routing primitives and the `ct/listProcesses` payload;
//! every DAP request whose semantics are unchanged still flows through
//! the existing `Handler` methods on the routed trace.

use std::collections::HashMap;

use crate::dap_handler::Handler;
use crate::session_manifest::{RecordingId, SessionManifest, TraceEntry};

/// Trace slot — the position of a `[[trace]]` entry in the manifest.
/// `u8` because we encode it in the high 8 bits of the composed
/// thread id.
pub type TraceSlot = u8;

/// Maximum number of traces a single session can host before the
/// composed-id encoding wraps. Kept as a `const` so tests can pin the
/// budget against accidental shrinkage.
pub const MAX_TRACES_PER_SESSION: usize = 256;

/// Bit shift used to pack the trace slot into the high bits of the
/// composed thread id. Kept distinct so the encoder + decoder stay in
/// sync if the budget is widened later.
pub const TRACE_SLOT_SHIFT: u32 = 24;

/// Mask covering the inner-thread bits. `((1 << TRACE_SLOT_SHIFT) - 1)`.
pub const INNER_THREAD_MASK: u64 = (1u64 << TRACE_SLOT_SHIFT) - 1;

/// Compose a session-wide thread id from a trace slot + inner thread id.
///
/// Returns `None` when either component exceeds its budget, which is
/// the M24 boundary: rather than silently corrupt routing, we surface
/// the limit to the caller and the DAP server returns an error.
pub fn compose_thread_id(slot: TraceSlot, inner: u32) -> Option<i64> {
    if u64::from(inner) > INNER_THREAD_MASK {
        return None;
    }
    let composed = (u64::from(slot) << TRACE_SLOT_SHIFT) | u64::from(inner);
    i64::try_from(composed).ok()
}

/// Decompose a session-wide thread id back into `(slot, inner)`.
/// The decomposition is total — every i64 maps to some `(slot,
/// inner)` pair; the caller validates `slot` against the session's
/// trace count.
pub fn decompose_thread_id(composed: i64) -> (TraceSlot, u32) {
    // Negative thread ids should never appear in practice; clamping to 0
    // keeps the decoder total and matches the legacy `id == 1`
    // behaviour for the backwards-compat path (where the renderer
    // sometimes sends 0).
    let composed_u = composed.max(0) as u64;
    let inner = (composed_u & INNER_THREAD_MASK) as u32;
    let slot_u = composed_u >> TRACE_SLOT_SHIFT;
    let slot = if slot_u > u64::from(TraceSlot::MAX) {
        TraceSlot::MAX
    } else {
        slot_u as TraceSlot
    };
    (slot, inner)
}

/// Per-slot snapshot for the `ct/listProcesses` response. The
/// frontend renders one process-tree row per entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessListEntry {
    pub recording_id: String,
    pub role: String,
    pub default_thread_prefix: String,
    pub thread_count: u32,
    pub thread_ids: Vec<i64>,
}

/// Per-slot pairing of a trace manifest entry with its loaded
/// [`Handler`]. Kept separate from the manifest's [`TraceEntry`] so
/// the manifest stays a pure data type and tests can construct
/// session handlers with synthetic handlers without touching disk.
pub struct LoadedTrace {
    pub entry: TraceEntry,
    pub handler: Handler,
}

/// Multi-trace DAP session handler.
///
/// Owns one [`Handler`] per trace and exposes routing primitives the
/// DAP server uses to dispatch requests. The `SessionHandler` itself
/// does not implement the DAP commands — that work lives on
/// [`Handler`] and stays untouched per the M24 deliverables.
pub struct SessionHandler {
    /// Loaded traces in manifest order. Index = trace slot.
    traces: Vec<LoadedTrace>,
    /// Lookup table from `RecordingId` to slot index, built at
    /// construction time. Used by `slot_for_recording_id`.
    by_recording_id: HashMap<RecordingId, TraceSlot>,
    /// Original manifest. Retained so the `ct/listProcesses` response
    /// can surface manifest-level metadata (correlation mode, etc.).
    manifest: SessionManifest,
}

impl SessionHandler {
    /// Build a `SessionHandler` from a fully parsed manifest and a
    /// vector of loaded handlers, one per manifest entry in order.
    pub fn new(manifest: SessionManifest, handlers: Vec<Handler>) -> Result<Self, SessionHandlerError> {
        if handlers.len() != manifest.traces.len() {
            return Err(SessionHandlerError::HandlerCountMismatch {
                manifest_traces: manifest.traces.len(),
                handlers_supplied: handlers.len(),
            });
        }
        if handlers.len() > MAX_TRACES_PER_SESSION {
            return Err(SessionHandlerError::TooManyTraces { traces: handlers.len() });
        }
        let mut traces: Vec<LoadedTrace> = Vec::with_capacity(handlers.len());
        let mut by_recording_id: HashMap<RecordingId, TraceSlot> = HashMap::new();
        for (slot, (entry, handler)) in manifest.traces.iter().zip(handlers.into_iter()).enumerate() {
            // Slot fits in TraceSlot because of the MAX_TRACES check.
            let slot = slot as TraceSlot;
            by_recording_id.insert(entry.recording_id.clone(), slot);
            traces.push(LoadedTrace {
                entry: entry.clone(),
                handler,
            });
        }
        Ok(SessionHandler {
            traces,
            by_recording_id,
            manifest,
        })
    }

    /// Number of traces in the session.
    pub fn trace_count(&self) -> usize {
        self.traces.len()
    }

    /// Return the manifest the session was built from.
    pub fn manifest(&self) -> &SessionManifest {
        &self.manifest
    }

    /// Borrow the per-slot loaded-trace snapshot.
    pub fn trace(&self, slot: TraceSlot) -> Option<&LoadedTrace> {
        self.traces.get(slot as usize)
    }

    /// Mutably borrow the [`Handler`] for a slot. The lookup is direct
    /// (vector index) — no hashing — so the hot DAP dispatch path
    /// stays branchless beyond a bounds check.
    pub fn handler_for_slot_mut(&mut self, slot: TraceSlot) -> Option<&mut Handler> {
        self.traces.get_mut(slot as usize).map(|loaded| &mut loaded.handler)
    }

    /// Mutably borrow the [`Handler`] for a composed thread id.
    ///
    /// Used by the DAP request dispatcher to route requests to the
    /// owning trace. Returns `None` when the high bits of the thread
    /// id name a slot that does not exist; the caller surfaces this
    /// as a DAP error.
    pub fn handler_for_thread_id_mut(&mut self, composed: i64) -> Option<&mut Handler> {
        let (slot, _) = decompose_thread_id(composed);
        self.handler_for_slot_mut(slot)
    }

    /// Look up the slot index that owns a given recording-id. Used
    /// internally by the `ct/listProcesses` response builder.
    pub fn slot_for_recording_id(&self, id: &RecordingId) -> Option<TraceSlot> {
        self.by_recording_id.get(id).copied()
    }

    /// Build the aggregated thread list returned by the DAP `threads`
    /// request. Each trace's threads are prefixed with the manifest's
    /// `default_thread_prefix` so the user sees a flat list with
    /// clear ownership markers.
    ///
    /// `inner_threads_provider` is a closure that, given a trace
    /// slot, returns the trace's own list of `(inner_thread_id,
    /// inner_name)` pairs. This shape keeps the function pure —
    /// callers can either drive it against live `Handler::threads`
    /// responses or against test fixtures.
    pub fn aggregated_thread_list<F>(
        &self,
        mut inner_threads_provider: F,
    ) -> Result<Vec<AggregatedThread>, SessionHandlerError>
    where
        F: FnMut(TraceSlot) -> Result<Vec<(u32, String)>, SessionHandlerError>,
    {
        let mut out: Vec<AggregatedThread> = Vec::new();
        for (slot_idx, loaded) in self.traces.iter().enumerate() {
            let slot = slot_idx as TraceSlot;
            let inner_threads = inner_threads_provider(slot)?;
            for (inner_id, inner_name) in inner_threads {
                let composed = compose_thread_id(slot, inner_id)
                    .ok_or(SessionHandlerError::ThreadIdOverflow { slot, inner: inner_id })?;
                let name = if loaded.entry.default_thread_prefix.is_empty() {
                    inner_name
                } else {
                    format!("{}:{}", loaded.entry.default_thread_prefix, inner_name)
                };
                out.push(AggregatedThread {
                    composed_thread_id: composed,
                    name,
                    slot,
                    inner_thread_id: inner_id,
                });
            }
        }
        Ok(out)
    }

    /// Build the `ct/listProcesses` response payload. Each entry
    /// carries the manifest role, thread count, and composed thread
    /// ids so the frontend can wire the process tree without needing
    /// a second `threads` round-trip.
    pub fn list_processes<F>(&self, mut inner_threads_provider: F) -> Result<Vec<ProcessListEntry>, SessionHandlerError>
    where
        F: FnMut(TraceSlot) -> Result<Vec<(u32, String)>, SessionHandlerError>,
    {
        let mut out: Vec<ProcessListEntry> = Vec::with_capacity(self.traces.len());
        for (slot_idx, loaded) in self.traces.iter().enumerate() {
            let slot = slot_idx as TraceSlot;
            let inner_threads = inner_threads_provider(slot)?;
            let mut thread_ids: Vec<i64> = Vec::with_capacity(inner_threads.len());
            for (inner_id, _) in &inner_threads {
                let composed = compose_thread_id(slot, *inner_id)
                    .ok_or(SessionHandlerError::ThreadIdOverflow { slot, inner: *inner_id })?;
                thread_ids.push(composed);
            }
            out.push(ProcessListEntry {
                recording_id: loaded.entry.recording_id.0.clone(),
                role: loaded.entry.role.clone(),
                default_thread_prefix: loaded.entry.default_thread_prefix.clone(),
                thread_count: u32::try_from(inner_threads.len()).unwrap_or(u32::MAX),
                thread_ids,
            });
        }
        Ok(out)
    }
}

/// One row of the aggregated thread list. Equivalent to
/// [`crate::dap_types::Thread`] but enriched with the routing
/// metadata so internal consumers don't lose the slot association.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AggregatedThread {
    pub composed_thread_id: i64,
    pub name: String,
    pub slot: TraceSlot,
    pub inner_thread_id: u32,
}

#[derive(Debug)]
pub enum SessionHandlerError {
    HandlerCountMismatch {
        manifest_traces: usize,
        handlers_supplied: usize,
    },
    TooManyTraces {
        traces: usize,
    },
    ThreadIdOverflow {
        slot: TraceSlot,
        inner: u32,
    },
    UnknownSlot {
        slot: TraceSlot,
    },
    InnerThreadsProvider(String),
}

impl std::fmt::Display for SessionHandlerError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            SessionHandlerError::HandlerCountMismatch {
                manifest_traces,
                handlers_supplied,
            } => write!(
                f,
                "session handler: manifest has {manifest_traces} trace(s) but {handlers_supplied} handler(s) were supplied"
            ),
            SessionHandlerError::TooManyTraces { traces } => write!(
                f,
                "session handler: {traces} traces exceeds the per-session budget of {MAX_TRACES_PER_SESSION}"
            ),
            SessionHandlerError::ThreadIdOverflow { slot, inner } => write!(
                f,
                "session handler: composed thread id overflowed for slot={slot}, inner={inner}"
            ),
            SessionHandlerError::UnknownSlot { slot } => {
                write!(f, "session handler: thread id references unknown trace slot {slot}")
            }
            SessionHandlerError::InnerThreadsProvider(detail) => {
                write!(f, "session handler: inner-threads provider failed: {detail}")
            }
        }
    }
}

impl std::error::Error for SessionHandlerError {}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::db::Db;
    use crate::recreator_session::RecreatorArgs;
    use crate::session_manifest::{CorrelationConfig, RecordingId, SessionManifest, TraceEntry};
    use crate::task::TraceKind;
    use std::path::PathBuf;

    /// Build a minimal in-memory `Handler` so the session-handler
    /// routing tests can run without touching disk. The handler does
    /// not need any trace data — the tests below assert only on the
    /// routing surface, not on DAP request execution.
    fn make_synthetic_handler(name: &str) -> Handler {
        let args = RecreatorArgs {
            name: name.to_string(),
            ..RecreatorArgs::default()
        };
        Handler::new(TraceKind::Materialized, args, Box::new(Db::new(&PathBuf::from(""))))
    }

    fn make_two_trace_manifest() -> SessionManifest {
        SessionManifest {
            version: 1,
            traces: vec![
                TraceEntry {
                    recording_id: RecordingId("rec-A".to_string()),
                    path: PathBuf::from("a.ct"),
                    role: "frontend".to_string(),
                    default_thread_prefix: "fe".to_string(),
                },
                TraceEntry {
                    recording_id: RecordingId("rec-B".to_string()),
                    path: PathBuf::from("b.ct"),
                    role: "backend".to_string(),
                    default_thread_prefix: "be".to_string(),
                },
            ],
            correlation: CorrelationConfig::default(),
            base_dir: PathBuf::from("."),
        }
    }

    /// M24 verification: a DAP request whose composed `threadId` is
    /// owned by trace B routes to trace B's `Handler` and does not
    /// touch trace A.
    #[test]
    fn test_session_handler_routes_dap_request_to_owning_trace() {
        let manifest = make_two_trace_manifest();
        let handler_a = make_synthetic_handler("trace-A");
        let handler_b = make_synthetic_handler("trace-B");
        let mut session = SessionHandler::new(manifest, vec![handler_a, handler_b]).unwrap();

        // Compose a thread id owned by slot 1 (trace B).
        let thread_id_b = compose_thread_id(1, 1).unwrap();
        let routed = session.handler_for_thread_id_mut(thread_id_b).unwrap();
        assert_eq!(routed.ct_rr_args.name, "trace-B");

        // Compose a thread id owned by slot 0 (trace A).
        let thread_id_a = compose_thread_id(0, 1).unwrap();
        let routed = session.handler_for_thread_id_mut(thread_id_a).unwrap();
        assert_eq!(routed.ct_rr_args.name, "trace-A");
    }

    /// M24 verification: `threads` aggregates across traces and
    /// applies each trace's manifest prefix.
    #[test]
    fn test_dap_thread_list_aggregates_across_traces_with_prefixes() {
        let manifest = make_two_trace_manifest();
        let handler_a = make_synthetic_handler("trace-A");
        let handler_b = make_synthetic_handler("trace-B");
        let session = SessionHandler::new(manifest, vec![handler_a, handler_b]).unwrap();

        let inner_lookup = |slot: TraceSlot| -> Result<Vec<(u32, String)>, SessionHandlerError> {
            match slot {
                0 => Ok(vec![(1, "thread-1".to_string())]),
                1 => Ok(vec![(1, "thread-1".to_string()), (2, "thread-2".to_string())]),
                other => Err(SessionHandlerError::UnknownSlot { slot: other }),
            }
        };
        let aggregated = session.aggregated_thread_list(inner_lookup).unwrap();
        assert_eq!(aggregated.len(), 3);
        assert_eq!(aggregated[0].name, "fe:thread-1");
        assert_eq!(aggregated[0].slot, 0);
        assert_eq!(aggregated[0].composed_thread_id, compose_thread_id(0, 1).unwrap());
        assert_eq!(aggregated[1].name, "be:thread-1");
        assert_eq!(aggregated[1].slot, 1);
        assert_eq!(aggregated[1].composed_thread_id, compose_thread_id(1, 1).unwrap());
        assert_eq!(aggregated[2].name, "be:thread-2");
        assert_eq!(aggregated[2].composed_thread_id, compose_thread_id(1, 2).unwrap());
    }

    /// M24 verification: `ct/listProcesses` returns every manifest
    /// trace with its role + thread count.
    #[test]
    fn test_ct_list_processes_returns_manifest_roles() {
        let manifest = make_two_trace_manifest();
        let handler_a = make_synthetic_handler("trace-A");
        let handler_b = make_synthetic_handler("trace-B");
        let session = SessionHandler::new(manifest, vec![handler_a, handler_b]).unwrap();
        let inner_lookup = |slot: TraceSlot| -> Result<Vec<(u32, String)>, SessionHandlerError> {
            match slot {
                0 => Ok(vec![(1, "thread-1".to_string())]),
                1 => Ok(vec![(1, "thread-1".to_string()), (2, "thread-2".to_string())]),
                other => Err(SessionHandlerError::UnknownSlot { slot: other }),
            }
        };
        let processes = session.list_processes(inner_lookup).unwrap();
        assert_eq!(processes.len(), 2);

        assert_eq!(processes[0].recording_id, "rec-A");
        assert_eq!(processes[0].role, "frontend");
        assert_eq!(processes[0].default_thread_prefix, "fe");
        assert_eq!(processes[0].thread_count, 1);
        assert_eq!(processes[0].thread_ids, vec![compose_thread_id(0, 1).unwrap()]);

        assert_eq!(processes[1].recording_id, "rec-B");
        assert_eq!(processes[1].role, "backend");
        assert_eq!(processes[1].default_thread_prefix, "be");
        assert_eq!(processes[1].thread_count, 2);
        assert_eq!(
            processes[1].thread_ids,
            vec![compose_thread_id(1, 1).unwrap(), compose_thread_id(1, 2).unwrap()]
        );
    }

    /// M24 verification: a single `.ct` produces a single-trace
    /// `SessionHandler`; the composed thread id for the default
    /// thread is identical to the legacy id (1), so every existing
    /// single-trace DAP test routes unchanged through it.
    #[test]
    fn test_session_handler_single_trace_backcompat() {
        let manifest = SessionManifest::single_trace(PathBuf::from("/tmp/example.ct"));
        let handler = make_synthetic_handler("single");
        let mut session = SessionHandler::new(manifest, vec![handler]).unwrap();
        assert_eq!(session.trace_count(), 1);

        // The legacy single-trace handler returns thread id 1 — the
        // composed id with slot=0 + inner=1 must equal 1 so the
        // backwards-compat surface matches byte-for-byte.
        let composed = compose_thread_id(0, 1).unwrap();
        assert_eq!(composed, 1);

        let routed = session.handler_for_thread_id_mut(composed).unwrap();
        assert_eq!(routed.ct_rr_args.name, "single");

        // No prefix → no prefix in the aggregated name; matches what a
        // single-trace client would see today.
        let aggregated = session
            .aggregated_thread_list(|_| Ok(vec![(1, "<thread 1>".to_string())]))
            .unwrap();
        assert_eq!(aggregated.len(), 1);
        assert_eq!(aggregated[0].name, "<thread 1>");
        assert_eq!(aggregated[0].composed_thread_id, 1);
    }

    #[test]
    fn compose_decompose_round_trip() {
        for slot in [0u8, 1, 2, 50, 255] {
            for inner in [0u32, 1, 7, 1024, 0x00FF_FFFF] {
                let composed = compose_thread_id(slot, inner).unwrap();
                let (got_slot, got_inner) = decompose_thread_id(composed);
                assert_eq!(got_slot, slot);
                assert_eq!(got_inner, inner);
            }
        }
    }

    #[test]
    fn compose_thread_id_rejects_overflowed_inner() {
        // 25 bits — exceeds the 24-bit budget by one.
        assert!(compose_thread_id(0, 1u32 << 24).is_none());
    }

    #[test]
    fn handler_count_mismatch_is_reported() {
        let manifest = make_two_trace_manifest();
        match SessionHandler::new(manifest, vec![make_synthetic_handler("only-one")]) {
            Ok(_) => panic!("expected HandlerCountMismatch"),
            Err(SessionHandlerError::HandlerCountMismatch { .. }) => {}
            Err(other) => panic!("unexpected error: {other}"),
        }
    }
}
