//! P0.7 — Lazy omniscient-prep trigger.
//!
//! See:
//!
//! * `codetracer-specs/Recording-Backends/Omniscient-DB-Server-Side-Prep.md`
//!   §6.4 (trigger semantics) — the lazy mode lets a sharded
//!   recording skip the per-slice + coordinator prep jobs at finalize
//!   time; the first omniscient query against such a recording fires
//!   the trigger which HTTP-POSTs the Monolith's enqueue endpoint.
//! * `codetracer-specs/Planned-Features/Performance-And-E2E-Coverage.milestones.org`
//!   P0.7 (this trigger contract).
//!
//! ## Design
//!
//! The trigger is exposed as the [`LazyOmniscientPrepTrigger`] trait
//! so the db-backend can stay HTTP-client-agnostic; the Monolith
//! provides the concrete impl server-side (codetracer-ci is a
//! sibling repo). The dispatcher in
//! `emulator_session::EmulatorReplaySession::ensure_omniscient_prep_triggered`
//! holds the trigger as `Arc<dyn LazyOmniscientPrepTrigger>` and
//! invokes [`LazyOmniscientPrepTrigger::trigger_for_recording`]
//! exactly once per session whose `omniscient_state == lazy_deferred`.
//!
//! ## Reentrancy
//!
//! A second omniscient query while the first trigger is in flight
//! must NOT re-enqueue. The session caches the trigger outcome — see
//! [`LazyTriggerLatch`] — so concurrent callers from the same session
//! coalesce on the same single round-trip.
//!
//! ## Default impl
//!
//! [`NoopLazyOmniscientPrepTrigger`] always returns
//! [`TriggerOutcome::AlreadyEnqueued`] so unit tests and the
//! standalone db-backend (no Monolith reachable) treat the trigger as
//! satisfied. The session still records that the trigger was invoked
//! via the latch so the test asserting "first query triggers, second
//! query does not re-enqueue" can observe the per-session call count.

use std::sync::Mutex;

/// P0.7 trigger contract. Implementations POST to the Monolith's
/// `POST /api/v1/storage/recordings/{recording_id}/omniscient-prep/trigger`
/// endpoint (the production path) or behave as a no-op (the unit-test
/// fixture path).
pub trait LazyOmniscientPrepTrigger: Send + Sync {
    /// Fire the trigger for `recording_id`. The implementation should
    /// be idempotent: a second call for the same recording while the
    /// first is in flight should either return
    /// [`TriggerOutcome::AlreadyEnqueued`] or block until the
    /// in-flight call resolves. The dispatcher caller is expected to
    /// also coalesce through its own [`LazyTriggerLatch`] so the
    /// implementation can stay simple.
    fn trigger_for_recording(&self, recording_id: &str) -> TriggerOutcome;
}

/// Outcome of [`LazyOmniscientPrepTrigger::trigger_for_recording`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerOutcome {
    /// The trigger HTTP POST succeeded and the per-slice + coordinator
    /// jobs were enqueued for the first time.
    Enqueued,
    /// The Monolith reported the jobs were already enqueued — a
    /// concurrent trigger fired between this caller's latch check and
    /// the POST. The session treats this as success.
    AlreadyEnqueued,
    /// The trigger failed (network error, Monolith returned 5xx). The
    /// session surfaces this through the next query's diagnostic
    /// terminator; the dispatcher does NOT retry inline.
    Failed,
}

/// P0.7 default no-op trigger. Lets the db-backend stand alone
/// without a Monolith reachable (unit tests, local replay) while
/// keeping the trait surface in place so the production impl can be
/// wired by the cluster bootstrap.
#[derive(Debug, Default)]
pub struct NoopLazyOmniscientPrepTrigger;

impl LazyOmniscientPrepTrigger for NoopLazyOmniscientPrepTrigger {
    fn trigger_for_recording(&self, _recording_id: &str) -> TriggerOutcome {
        TriggerOutcome::AlreadyEnqueued
    }
}

/// P0.7 latch ensuring a session fires the trigger at most once per
/// recording lifetime. Owned by the session; the dispatcher consults
/// it before invoking the trigger.
#[derive(Debug, Default)]
pub struct LazyTriggerLatch {
    inner: Mutex<LatchInner>,
}

#[derive(Debug, Default)]
struct LatchInner {
    fired: bool,
    last_outcome: Option<TriggerOutcome>,
}

impl LazyTriggerLatch {
    /// Construct a fresh latch.
    pub fn new() -> Self {
        LazyTriggerLatch {
            inner: Mutex::new(LatchInner::default()),
        }
    }

    /// Invoke the trigger if the latch hasn't fired yet. Returns the
    /// outcome of either the freshly-fired trigger or the cached prior
    /// outcome when the latch is already set.
    pub fn ensure_triggered(&self, recording_id: &str, trigger: &dyn LazyOmniscientPrepTrigger) -> TriggerOutcome {
        let mut inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if inner.fired {
            return inner.last_outcome.unwrap_or(TriggerOutcome::AlreadyEnqueued);
        }
        let outcome = trigger.trigger_for_recording(recording_id);
        inner.fired = true;
        inner.last_outcome = Some(outcome);
        outcome
    }

    /// Diagnostic: report whether the latch has ever fired.
    pub fn has_fired(&self) -> bool {
        let inner = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        inner.fired
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Counting trigger for the latch tests.
    #[derive(Default)]
    struct CountingTrigger {
        count: AtomicUsize,
    }

    impl LazyOmniscientPrepTrigger for CountingTrigger {
        fn trigger_for_recording(&self, _recording_id: &str) -> TriggerOutcome {
            self.count.fetch_add(1, Ordering::SeqCst);
            TriggerOutcome::Enqueued
        }
    }

    #[test]
    fn latch_fires_trigger_once_per_recording() {
        let latch = LazyTriggerLatch::new();
        let trigger = CountingTrigger::default();

        assert_eq!(latch.ensure_triggered("rec-1", &trigger), TriggerOutcome::Enqueued);
        assert_eq!(trigger.count.load(Ordering::SeqCst), 1);

        // Second call must NOT re-fire — coalesces on the cached
        // outcome.
        assert_eq!(latch.ensure_triggered("rec-1", &trigger), TriggerOutcome::Enqueued);
        assert_eq!(trigger.count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn noop_trigger_reports_already_enqueued() {
        let trigger = NoopLazyOmniscientPrepTrigger;
        assert_eq!(trigger.trigger_for_recording("rec-1"), TriggerOutcome::AlreadyEnqueued);
    }

    #[test]
    fn latch_records_fired_state() {
        let latch = LazyTriggerLatch::new();
        let trigger = NoopLazyOmniscientPrepTrigger;

        assert!(!latch.has_fired());
        latch.ensure_triggered("rec-1", &trigger);
        assert!(latch.has_fired());
    }
}
