//! M25 — Correlation pairing index (derived view over the general
//! tracepoint cache).
//!
//! Canonical spec:
//! [`codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md`] §3.3.
//!
//! # Role
//!
//! Given a stream of cached tracepoint firings whose payloads carry
//! [`crate::correlation_markers::MarkerPayload`] metadata, the
//! pairing index buckets them by `(boundary_id, direction)` so the
//! Event Log surface (M25b) and the cross-process value-origin chain
//! (M29) can both look up the counterpart of a Send marker (or a
//! Recv marker) by key in O(1).
//!
//! The index is a **derived view** rather than a primary cache (per
//! spec §3.3): every read walks the underlying tracepoint cache,
//! decodes marker payloads, and buckets them. The "lazy re-derive on
//! next read" contract from the spec is satisfied by the fact that
//! the index is built from a snapshot of cached firings and discarded
//! after each call to [`PairIndex::build`].
//!
//! # Why a separate module
//!
//! The index lives alongside [`crate::correlation_markers`] but is a
//! distinct concern: the scanner produces `MarkerDecl`s, the event_db
//! caches firings, and *this* module turns the resulting
//! `MarkerPayload`-bearing firings into a pairing index. Keeping them
//! separate means M29's cross-process consumer can depend on this
//! module without dragging in the scanner.

use std::collections::HashMap;

use crate::correlation_markers::{MarkerDirection, MarkerPayload};

/// Per-firing projection used by [`PairIndex`]. Holds the cached
/// payload alongside the originating recording id + step id so the
/// Event Log can render a clickable jump target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkerEventView {
    /// Stable id of the trace that recorded this firing — the
    /// `recording_id` from the session manifest. Empty for
    /// single-trace sessions.
    pub recording_id: String,
    /// Tick / step coordinate at which the marker tracepoint fired.
    /// Used by the jump button to seek the timeline.
    pub step_id: i64,
    /// Source-location pin for the marker. Mirrors the
    /// `MarkerDecl.location` shape so the renderer can hyperlink the
    /// source path.
    pub source_path: String,
    pub source_line: usize,
    /// The decoded marker payload.
    pub payload: MarkerPayload,
}

impl MarkerEventView {
    /// Build a view from a recorded firing. The caller owns extracting
    /// the recording id / step / source location from the underlying
    /// event store; this constructor just bundles them.
    pub fn new(
        recording_id: impl Into<String>,
        step_id: i64,
        source_path: impl Into<String>,
        source_line: usize,
        payload: MarkerPayload,
    ) -> Self {
        Self {
            recording_id: recording_id.into(),
            step_id,
            source_path: source_path.into(),
            source_line,
            payload,
        }
    }
}

/// Derived view over the tracepoint cache per spec §3.3.
///
/// Keyed by `(boundary_id, direction)` so the Event Log can look up
/// "every Send for boundary `order-processing`" in one map lookup.
/// The values are vectors of [`MarkerEventView`]s — each value's
/// `payload.key_value` is what the matcher uses to pair Send to
/// Recv.
#[derive(Debug, Default, Clone)]
pub struct PairIndex {
    bucket: HashMap<(String, MarkerDirection), Vec<MarkerEventView>>,
}

impl PairIndex {
    /// Build the index from a slice of decoded marker firings. M25's
    /// session-load integrator constructs the views from the general
    /// tracepoint cache and hands them here.
    ///
    /// Build is **idempotent** and **pure**: no internal caching. The
    /// lazy re-derive contract from spec §3.3 is satisfied by the
    /// caller discarding the previous index whenever the underlying
    /// tracepoint cache has changed.
    pub fn build(events: &[MarkerEventView]) -> Self {
        let mut bucket: HashMap<(String, MarkerDirection), Vec<MarkerEventView>> = HashMap::new();
        for event in events {
            let key = (event.payload.boundary_id.clone(), event.payload.direction);
            bucket.entry(key).or_default().push(event.clone());
        }
        Self { bucket }
    }

    /// Look up every recorded marker for `(boundary_id, direction)`.
    pub fn get(&self, boundary_id: &str, direction: MarkerDirection) -> &[MarkerEventView] {
        self.bucket
            .get(&(boundary_id.to_string(), direction))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Find every counterpart of the given Send event. Returns the
    /// (possibly empty) list of Recv firings whose `(boundary_id,
    /// key_value)` pair matches.
    pub fn counterparts_of(&self, event: &MarkerEventView) -> Vec<MarkerEventView> {
        let opposite = event.payload.direction.opposite();
        self.bucket
            .get(&(event.payload.boundary_id.clone(), opposite))
            .map(|candidates| {
                candidates
                    .iter()
                    .filter(|c| c.payload.key_value == event.payload.key_value)
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Enumerate every distinct `(boundary_id, direction)` pair
    /// represented in the index. Used by the `ct trace correlations`
    /// CLI to print a summary.
    pub fn buckets(&self) -> impl Iterator<Item = (&(String, MarkerDirection), &Vec<MarkerEventView>)> {
        self.bucket.iter()
    }

    /// Number of distinct boundary ids covered by the index.
    pub fn boundary_count(&self) -> usize {
        self.bucket
            .keys()
            .map(|(id, _)| id.as_str())
            .collect::<std::collections::HashSet<_>>()
            .len()
    }

    /// Total number of marker firings tracked.
    pub fn event_count(&self) -> usize {
        self.bucket.values().map(Vec::len).sum()
    }
}

/// Summary statistics computed from a [`PairIndex`]. Used by the
/// `ct trace correlations` CLI to print "5 matched, 2 unmatched
/// sends, 1 unmatched recv, 1 ambiguous" footers per spec.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CorrelationReport {
    pub pairs: Vec<MatchedPair>,
    pub unmatched_sends: Vec<MarkerEventView>,
    pub unmatched_recvs: Vec<MarkerEventView>,
    pub ambiguous: Vec<AmbiguousPairing>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatchedPair {
    pub send: MarkerEventView,
    pub recv: MarkerEventView,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AmbiguousPairing {
    pub boundary_id: String,
    pub key_value: String,
    pub events: Vec<MarkerEventView>,
}

impl CorrelationReport {
    /// Derive a correlation report from the index. We walk every
    /// `(boundary_id, key_value)` triple and bucket Sends / Recvs
    /// together; the resulting buckets are classified as matched
    /// (1+1), unmatched-sends (n+0), unmatched-recvs (0+n), or
    /// ambiguous (anything where one side has >1 candidate that
    /// could match another firing on the other side).
    pub fn from_index(index: &PairIndex) -> Self {
        let mut by_key: HashMap<(String, String), (Vec<MarkerEventView>, Vec<MarkerEventView>)> = HashMap::new();
        for ((boundary, direction), events) in &index.bucket {
            for event in events {
                let entry = by_key
                    .entry((boundary.clone(), event.payload.key_value.clone()))
                    .or_default();
                match direction {
                    MarkerDirection::Send => entry.0.push(event.clone()),
                    MarkerDirection::Recv => entry.1.push(event.clone()),
                }
            }
        }
        let mut report = CorrelationReport::default();
        for ((boundary, key_value), (sends, recvs)) in by_key {
            match (sends.len(), recvs.len()) {
                (0, _) => report.unmatched_recvs.extend(recvs),
                (_, 0) => report.unmatched_sends.extend(sends),
                (1, 1) => report.pairs.push(MatchedPair {
                    send: sends[0].clone(),
                    recv: recvs[0].clone(),
                }),
                _ => {
                    let mut events = sends.clone();
                    events.extend(recvs.iter().cloned());
                    report.ambiguous.push(AmbiguousPairing {
                        boundary_id: boundary,
                        key_value,
                        events,
                    });
                }
            }
        }
        // Stable ordering — important for the CLI golden-output test.
        report
            .pairs
            .sort_by(|a, b| a.send.payload.boundary_id.cmp(&b.send.payload.boundary_id));
        report.unmatched_sends.sort_by(|a, b| {
            a.payload
                .boundary_id
                .cmp(&b.payload.boundary_id)
                .then_with(|| a.payload.key_value.cmp(&b.payload.key_value))
        });
        report.unmatched_recvs.sort_by(|a, b| {
            a.payload
                .boundary_id
                .cmp(&b.payload.boundary_id)
                .then_with(|| a.payload.key_value.cmp(&b.payload.key_value))
        });
        report.ambiguous.sort_by(|a, b| a.boundary_id.cmp(&b.boundary_id));
        report
    }

    /// Render the report as plain text — one line per matched pair,
    /// one line per unmatched send, one line per unmatched recv, plus
    /// a footer with totals. This is the body of the
    /// `ct trace correlations` command per the M25 deliverable.
    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str("correlation marker report\n");
        out.push_str("--------------------------\n");
        for pair in &self.pairs {
            out.push_str(&format!(
                "MATCH boundary={} key={} send={}:{}@{} recv={}:{}@{}\n",
                pair.send.payload.boundary_id,
                pair.send.payload.key_value,
                pair.send.source_path,
                pair.send.source_line,
                pair.send.step_id,
                pair.recv.source_path,
                pair.recv.source_line,
                pair.recv.step_id,
            ));
        }
        for unmatched in &self.unmatched_sends {
            out.push_str(&format!(
                "UNMATCHED_SEND boundary={} key={} at={}:{}@{}\n",
                unmatched.payload.boundary_id,
                unmatched.payload.key_value,
                unmatched.source_path,
                unmatched.source_line,
                unmatched.step_id,
            ));
        }
        for unmatched in &self.unmatched_recvs {
            out.push_str(&format!(
                "UNMATCHED_RECV boundary={} key={} at={}:{}@{}\n",
                unmatched.payload.boundary_id,
                unmatched.payload.key_value,
                unmatched.source_path,
                unmatched.source_line,
                unmatched.step_id,
            ));
        }
        for amb in &self.ambiguous {
            out.push_str(&format!(
                "AMBIGUOUS boundary={} key={} candidates={}\n",
                amb.boundary_id,
                amb.key_value,
                amb.events.len(),
            ));
        }
        out.push_str(&format!(
            "totals: matched={} unmatched_send={} unmatched_recv={} ambiguous={}\n",
            self.pairs.len(),
            self.unmatched_sends.len(),
            self.unmatched_recvs.len(),
            self.ambiguous.len(),
        ));
        out
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::correlation_markers::{MarkerDirection, MarkerPayload};

    fn synth(
        boundary: &str,
        direction: MarkerDirection,
        key_value: &str,
        show_value: Option<&str>,
        rec_id: &str,
        step: i64,
    ) -> MarkerEventView {
        let payload = MarkerPayload {
            marker_id: 0,
            boundary_id: boundary.to_string(),
            direction,
            key_text: "k".to_string(),
            key_value: key_value.to_string(),
            show_text: show_value.map(|_| "s".to_string()),
            show_value: show_value.map(String::from),
            description: None,
            format: None,
        };
        MarkerEventView::new(rec_id, step, "src/x.py", 10, payload)
    }

    #[test]
    fn pair_index_buckets_by_boundary_and_direction() {
        let events = vec![
            synth("order", MarkerDirection::Send, "K1", None, "a", 5),
            synth("order", MarkerDirection::Recv, "K1", None, "b", 6),
            synth("order", MarkerDirection::Send, "K2", None, "a", 9),
        ];
        let idx = PairIndex::build(&events);
        assert_eq!(idx.get("order", MarkerDirection::Send).len(), 2);
        assert_eq!(idx.get("order", MarkerDirection::Recv).len(), 1);
        let cps = idx.counterparts_of(&events[0]);
        assert_eq!(cps.len(), 1);
        assert_eq!(cps[0].recording_id, "b");
    }
}
