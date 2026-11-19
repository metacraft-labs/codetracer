//! Which `ct/load-flow` request is the newest of its `flowMode`, and how a
//! flow that a newer one supersedes while it runs is stopped.
//!
//! A client asks for the flow of every stop, so by the time a flow of an
//! earlier stop finishes, the client has usually moved on and the result is
//! wasted. A queued flow that a newer one
//! of the same mode follows is never started (`dap_server::next_task_request`);
//! this module covers the flow that is already running when the newer one
//! arrives. It is answered as superseded, like a queued one, and it ends at
//! once, even in the middle of a replay query that would otherwise run up to
//! the flow worker's read timeout: a step over a large call of an MCR
//! recording takes tens of seconds, because the replay emulates every
//! instruction of the call.
//!
//! Two parties share a [`FlowSupersession`]: the DAP dispatcher, which calls
//! [`FlowSupersession::arrived`] for each `ct/load-flow` before it forwards
//! the request to the `flow` task thread, and that thread, which calls
//! [`FlowSupersession::begin`] before it runs a flow and
//! [`FlowSupersession::finish`] after. Both take the same lock, so a newer
//! request either arrives before the older one begins (the older one is then
//! answered as superseded without running) or after (the running one is then
//! cancelled); there is no window in which it does neither.
//!
//! A running flow carries a [`FlowCancel`]. Cancelling it marks it superseded
//! and runs the interrupters its replay registered: a recreator replay
//! registers one per worker connection, which shuts the socket down, so a
//! read blocked on the worker returns at once; the replay then stops (kills
//! and reaps) its worker instead of waiting for it
//! (`recreator_session::ReplayWorker`). A flow that has started to deliver
//! its result seals its token first ([`FlowCancel::seal`]), after which a
//! cancel no longer applies: a client never receives a `ct/updated-flow` for
//! a request that is then answered as superseded.

use std::error::Error;
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

use log::info;

use crate::task::FlowMode;

/// Called once when the flow it was registered with is superseded; it must
/// make a blocked replay query return promptly (for example by shutting a
/// worker socket down) and must not block.
pub type FlowInterrupter = Box<dyn Fn() + Send>;

/// Lock `mutex`, taking the data of a poisoned one: the state here is a few
/// plain fields that a panic elsewhere cannot leave half-written, and a flow
/// thread that panicked is answered by its own poison handling.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[derive(Default)]
struct CancelState {
    /// The `seq` of the request that superseded this flow, once one has.
    superseded_by: Option<i64>,
    /// Set when the flow started to deliver its result: from then on it is
    /// not superseded.
    sealed: bool,
    interrupters: Vec<FlowInterrupter>,
}

/// The cancellation token of one running `ct/load-flow`. Clones share it.
#[derive(Clone, Default)]
pub struct FlowCancel {
    state: Arc<Mutex<CancelState>>,
}

impl fmt::Debug for FlowCancel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = lock(&self.state);
        f.debug_struct("FlowCancel")
            .field("superseded_by", &state.superseded_by)
            .field("sealed", &state.sealed)
            .field("interrupters", &state.interrupters.len())
            .finish()
    }
}

impl FlowCancel {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mark the flow superseded by request `newer_seq` and run its
    /// interrupters. `false`, and nothing happens, when it is already
    /// superseded or has started to deliver its result.
    pub fn supersede(&self, newer_seq: i64) -> bool {
        let mut state = lock(&self.state);
        if state.sealed || state.superseded_by.is_some() {
            return false;
        }
        state.superseded_by = Some(newer_seq);
        for interrupt in state.interrupters.drain(..) {
            interrupt();
        }
        true
    }

    /// The request that superseded this flow, if one has.
    pub fn superseded_by(&self) -> Option<i64> {
        lock(&self.state).superseded_by
    }

    /// Commit to delivering the flow's result: after this a newer request
    /// no longer supersedes it. `Err` with the superseding request's `seq`
    /// when one already has, and then the result must not be delivered.
    pub fn seal(&self) -> Result<(), i64> {
        let mut state = lock(&self.state);
        if let Some(newer_seq) = state.superseded_by {
            return Err(newer_seq);
        }
        state.sealed = true;
        state.interrupters.clear();
        Ok(())
    }

    /// Register `interrupt` to run when the flow is superseded. It runs at
    /// once when the flow already is (a worker connected after the cancel),
    /// and never once the flow is sealed.
    pub fn on_supersede(&self, interrupt: FlowInterrupter) {
        let mut state = lock(&self.state);
        if state.superseded_by.is_some() {
            drop(state);
            interrupt();
        } else if !state.sealed {
            state.interrupters.push(interrupt);
        }
    }
}

/// The answer to a superseded `ct/load-flow`: its `Display` is the response's
/// `message`, which starts with `superseded`: clients recognise the answer by
/// that prefix and do not treat it as a failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlowSuperseded {
    /// The `seq` of the newer request.
    pub newer_seq: i64,
    /// Whether the superseded flow had started running.
    pub started: bool,
}

impl fmt::Display for FlowSuperseded {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let when = if self.started {
            "while this one was running"
        } else {
            "before this one started"
        };
        write!(
            f,
            "superseded: a newer ct/load-flow (request {}) for the same flow mode arrived {when}",
            self.newer_seq
        )
    }
}

impl Error for FlowSuperseded {}

struct RunningFlow {
    seq: i64,
    mode: FlowMode,
    cancel: FlowCancel,
}

#[derive(Default)]
struct SupersessionState {
    /// The newest `ct/load-flow` the dispatcher forwarded, per mode.
    latest: Vec<(FlowMode, i64)>,
    running: Option<RunningFlow>,
}

/// The newest `ct/load-flow` of each mode and the flow that is running; see
/// the module documentation. Shared (`Arc`) by the dispatcher and the `flow`
/// task thread.
#[derive(Default)]
pub struct FlowSupersession {
    state: Mutex<SupersessionState>,
}

impl fmt::Debug for FlowSupersession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let state = lock(&self.state);
        f.debug_struct("FlowSupersession")
            .field("latest", &state.latest)
            .field("running", &state.running.as_ref().map(|running| running.seq))
            .finish()
    }
}

impl FlowSupersession {
    /// The dispatcher received `ct/load-flow` request `seq` of `mode`: it is
    /// now the newest of its mode, and a running flow of that mode is
    /// superseded by it. Returns the `seq` of the flow it superseded, if any.
    /// Called before the request is forwarded to the flow thread.
    pub fn arrived(&self, seq: i64, mode: FlowMode) -> Option<i64> {
        let mut state = lock(&self.state);
        match state.latest.iter_mut().find(|(m, _)| *m == mode) {
            Some(entry) => entry.1 = seq,
            None => state.latest.push((mode, seq)),
        }
        let running = state.running.as_ref()?;
        if running.mode != mode || running.seq == seq || !running.cancel.supersede(seq) {
            return None;
        }
        info!(
            "ct/load-flow {} superseded while running by ct/load-flow {seq}",
            running.seq
        );
        Some(running.seq)
    }

    /// The flow thread is about to run request `seq` of `mode`. `Ok` with the
    /// token the flow runs under, or `Err` with the `seq` of the newer request
    /// of the same mode that supersedes it before it started. A request the
    /// dispatcher never announced (`arrived`) is treated as the newest.
    pub fn begin(&self, seq: i64, mode: FlowMode) -> Result<FlowCancel, i64> {
        let mut state = lock(&self.state);
        if let Some(&(_, newest)) = state.latest.iter().find(|(m, _)| *m == mode)
            && newest != seq
        {
            return Err(newest);
        }
        let cancel = FlowCancel::new();
        state.running = Some(RunningFlow {
            seq,
            mode,
            cancel: cancel.clone(),
        });
        Ok(cancel)
    }

    /// Request `seq` finished, whatever its outcome.
    pub fn finish(&self, seq: i64) {
        let mut state = lock(&self.state);
        if state.running.as_ref().is_some_and(|running| running.seq == seq) {
            state.running = None;
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn counter() -> (Arc<AtomicUsize>, FlowInterrupter) {
        let count = Arc::new(AtomicUsize::new(0));
        let inner = Arc::clone(&count);
        (
            count,
            Box::new(move || {
                inner.fetch_add(1, Ordering::SeqCst);
            }),
        )
    }

    #[test]
    fn a_newer_flow_of_the_same_mode_cancels_the_running_one_and_interrupts_its_replay() {
        let registry = FlowSupersession::default();
        assert_eq!(registry.arrived(10, FlowMode::Call), None);
        let cancel = registry.begin(10, FlowMode::Call).expect("the newest flow runs");
        let (interrupted, interrupter) = counter();
        cancel.on_supersede(interrupter);

        assert_eq!(registry.arrived(11, FlowMode::Call), Some(10));
        assert_eq!(cancel.superseded_by(), Some(11));
        assert_eq!(interrupted.load(Ordering::SeqCst), 1, "the replay is interrupted once");
        assert_eq!(cancel.seal(), Err(11), "a superseded flow delivers nothing");

        // A third request does not interrupt it again.
        assert_eq!(registry.arrived(12, FlowMode::Call), None);
        assert_eq!(interrupted.load(Ordering::SeqCst), 1);
        assert_eq!(cancel.superseded_by(), Some(11));
    }

    #[test]
    fn a_flow_of_the_other_mode_does_not_cancel_the_running_one() {
        let registry = FlowSupersession::default();
        registry.arrived(10, FlowMode::Call);
        let cancel = registry.begin(10, FlowMode::Call).unwrap();
        assert_eq!(registry.arrived(11, FlowMode::Diff), None);
        assert_eq!(cancel.superseded_by(), None);
        assert_eq!(cancel.seal(), Ok(()));
    }

    #[test]
    fn a_flow_that_started_to_deliver_is_not_superseded() {
        let registry = FlowSupersession::default();
        registry.arrived(10, FlowMode::Call);
        let cancel = registry.begin(10, FlowMode::Call).unwrap();
        let (interrupted, interrupter) = counter();
        cancel.on_supersede(interrupter);
        assert_eq!(cancel.seal(), Ok(()));
        assert_eq!(registry.arrived(11, FlowMode::Call), None);
        assert_eq!(cancel.superseded_by(), None);
        assert_eq!(interrupted.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_request_that_a_newer_one_overtook_before_it_began_does_not_run() {
        let registry = FlowSupersession::default();
        registry.arrived(10, FlowMode::Call);
        registry.arrived(11, FlowMode::Call);
        assert_eq!(registry.begin(10, FlowMode::Call).err(), Some(11));
        assert!(registry.begin(11, FlowMode::Call).is_ok());
    }

    #[test]
    fn an_interrupter_registered_after_the_cancel_runs_at_once() {
        // A worker that connects after its flow was superseded must not be
        // waited on either.
        let registry = FlowSupersession::default();
        registry.arrived(10, FlowMode::Call);
        let cancel = registry.begin(10, FlowMode::Call).unwrap();
        registry.arrived(11, FlowMode::Call);
        let (interrupted, interrupter) = counter();
        cancel.on_supersede(interrupter);
        assert_eq!(interrupted.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_finished_flow_is_not_cancelled_by_a_later_request() {
        let registry = FlowSupersession::default();
        registry.arrived(10, FlowMode::Call);
        let cancel = registry.begin(10, FlowMode::Call).unwrap();
        registry.finish(10);
        assert_eq!(registry.arrived(11, FlowMode::Call), None);
        assert_eq!(cancel.superseded_by(), None);
    }

    #[test]
    fn an_unannounced_request_runs() {
        let registry = FlowSupersession::default();
        assert!(registry.begin(5, FlowMode::Diff).is_ok());
    }

    #[test]
    fn the_answers_name_the_newer_request_and_start_with_superseded() {
        let queued = FlowSuperseded {
            newer_seq: 13,
            started: false,
        }
        .to_string();
        let running = FlowSuperseded {
            newer_seq: 14,
            started: true,
        }
        .to_string();
        assert_eq!(
            queued,
            "superseded: a newer ct/load-flow (request 13) for the same flow mode arrived before this one started"
        );
        assert_eq!(
            running,
            "superseded: a newer ct/load-flow (request 14) for the same flow mode arrived while this one was running"
        );
    }
}
