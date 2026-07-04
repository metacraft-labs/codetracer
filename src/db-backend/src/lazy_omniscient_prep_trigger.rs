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

/// P0.7 production HTTP trigger. POSTs to the Monolith's
/// `POST /api/v1/storage/recordings/{recording_id}/omniscient-prep/trigger`
/// endpoint and maps the response body's `decision` field onto a
/// [`TriggerOutcome`]. The impl is intentionally blocking — it lives
/// on the per-session dispatcher thread, which already coalesces
/// concurrent callers through [`LazyTriggerLatch`].
///
/// The Monolith URL + the auth bearer token + the tenant id are
/// supplied at construction time; the bootstrap is expected to wire
/// these from the recording-launch metadata so the trigger inherits
/// the same credentials the replay session uses.
#[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
pub struct HttpLazyOmniscientPrepTrigger {
    /// Base URL of the Monolith (e.g. `https://monolith.example.com`).
    /// The trigger appends
    /// `/api/v1/storage/recordings/{id}/omniscient-prep/trigger`.
    pub base_url: String,
    /// Bearer token for the Monolith's TestBearer-style authentication.
    /// The Monolith's `LazyOmniscientPrepTriggerEndpoints` validates
    /// the caller's tenant membership via `CurrentUser`; the token
    /// is the caller's user-id-as-bearer.
    pub bearer_token: String,
    /// Tenant the caller is operating as.
    pub tenant_id: String,
    /// Optional override of the `ureq::Agent`. The default agent has
    /// a 30s read timeout, which matches the Monolith side's job-
    /// enqueue cost ceiling.
    agent: ureq::Agent,
}

#[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
impl std::fmt::Debug for HttpLazyOmniscientPrepTrigger {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HttpLazyOmniscientPrepTrigger")
            .field("base_url", &self.base_url)
            .field("tenant_id", &self.tenant_id)
            .finish_non_exhaustive()
    }
}

#[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
impl HttpLazyOmniscientPrepTrigger {
    /// Construct an HTTP trigger.
    /// * `base_url` — Monolith base URL, no trailing slash.
    /// * `bearer_token` — caller's TestBearer credential.
    /// * `tenant_id` — tenant uuid that owns the recording.
    pub fn new(base_url: impl Into<String>, bearer_token: impl Into<String>, tenant_id: impl Into<String>) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(30))
            .build();
        HttpLazyOmniscientPrepTrigger {
            base_url: base_url.into(),
            bearer_token: bearer_token.into(),
            tenant_id: tenant_id.into(),
            agent,
        }
    }
}

#[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
impl LazyOmniscientPrepTrigger for HttpLazyOmniscientPrepTrigger {
    fn trigger_for_recording(&self, recording_id: &str) -> TriggerOutcome {
        let url = format!(
            "{}/api/v1/storage/recordings/{}/omniscient-prep/trigger",
            self.base_url.trim_end_matches('/'),
            recording_id,
        );
        let body = serde_json::json!({ "tenantId": self.tenant_id });
        match self
            .agent
            .post(&url)
            .set("Authorization", &format!("Bearer {}", self.bearer_token))
            .set("Content-Type", "application/json")
            .send_json(body)
        {
            Ok(resp) => {
                // The Monolith returns 200 for both Enqueued and
                // AlreadyEnqueued; the decision discriminator is in
                // the JSON body's `decision` field.
                if resp.status() != 200 {
                    return TriggerOutcome::Failed;
                }
                let json: serde_json::Value = match resp.into_json() {
                    Ok(j) => j,
                    Err(_) => return TriggerOutcome::Failed,
                };
                match json.get("decision").and_then(serde_json::Value::as_str) {
                    Some("enqueued") => TriggerOutcome::Enqueued,
                    Some("already_enqueued") => TriggerOutcome::AlreadyEnqueued,
                    // Any other decision string (or missing) is
                    // treated as a permanent failure so the next
                    // origin query surfaces the diagnostic
                    // terminator.
                    _ => TriggerOutcome::Failed,
                }
            }
            Err(_e) => TriggerOutcome::Failed,
        }
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

    /// Minimal stub HTTP server that accepts exactly one connection,
    /// records the request line + body, and replies with `body`. Used
    /// by the `HttpLazyOmniscientPrepTrigger` tests so we don't pull
    /// in an http-mock crate for a single round-trip assertion.
    fn run_stub_server(body: &'static str) -> (String, std::sync::Arc<std::sync::Mutex<Option<String>>>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let port = listener.local_addr().expect("local_addr").port();
        let captured = std::sync::Arc::new(std::sync::Mutex::new(None));
        let captured_clone = captured.clone();
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 4096];
                let mut total = Vec::new();
                // Read headers + body. We loop until we see headers
                // end (\r\n\r\n), parse Content-Length, then keep
                // reading until we have that many body bytes.
                let mut content_length: Option<usize> = None;
                let mut header_end: Option<usize> = None;
                while let Ok(n) = stream.read(&mut buf) {
                    if n == 0 {
                        break;
                    }
                    total.extend_from_slice(&buf[..n]);
                    if header_end.is_none()
                        && let Some(pos) = total.windows(4).position(|w| w == b"\r\n\r\n")
                    {
                        header_end = Some(pos + 4);
                        let headers = String::from_utf8_lossy(&total[..pos]).to_string();
                        for line in headers.split("\r\n") {
                            if let Some(rest) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                                content_length = rest.trim().parse().ok();
                            }
                        }
                    }
                    if let (Some(end), Some(cl)) = (header_end, content_length) {
                        if total.len() >= end + cl {
                            break;
                        }
                    } else if header_end.is_some() {
                        // No content length advertised; assume done.
                        break;
                    }
                }
                let request_text = String::from_utf8_lossy(&total).to_string();
                *captured_clone.lock().unwrap_or_else(|p| p.into_inner()) = Some(request_text);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://127.0.0.1:{port}"), captured)
    }

    #[test]
    #[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
    fn http_trigger_posts_enqueued_decision() {
        let body = r#"{"decision":"enqueued","state":"pending","enqueuedJobId":42}"#;
        let (base_url, captured) = run_stub_server(body);
        let trigger = HttpLazyOmniscientPrepTrigger::new(base_url, "test-token", "tenant-abc");
        let outcome = trigger.trigger_for_recording("rec-1");
        assert_eq!(outcome, TriggerOutcome::Enqueued);
        // Verify the request was actually issued: path matches the
        // documented contract + the bearer + tenant id flow through.
        let request = captured
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
            .expect("captured request");
        assert!(
            request.contains("POST /api/v1/storage/recordings/rec-1/omniscient-prep/trigger"),
            "expected POST to trigger endpoint; got: {}",
            request
        );
        assert!(
            request.contains("Authorization: Bearer test-token"),
            "expected Authorization header; got: {}",
            request
        );
        assert!(
            request.contains("\"tenantId\":\"tenant-abc\""),
            "expected tenantId in body; got: {}",
            request
        );
    }

    #[test]
    #[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
    fn http_trigger_maps_already_enqueued() {
        let body = r#"{"decision":"already_enqueued","state":"pending","enqueuedJobId":null}"#;
        let (base_url, _) = run_stub_server(body);
        let trigger = HttpLazyOmniscientPrepTrigger::new(base_url, "tok", "tenant-x");
        assert_eq!(trigger.trigger_for_recording("rec-2"), TriggerOutcome::AlreadyEnqueued);
    }

    #[test]
    #[cfg(all(feature = "io-transport", not(target_arch = "wasm32")))]
    fn http_trigger_maps_unknown_decision_to_failed() {
        let body = r#"{"decision":"unexpected","state":"failed","enqueuedJobId":null}"#;
        let (base_url, _) = run_stub_server(body);
        let trigger = HttpLazyOmniscientPrepTrigger::new(base_url, "tok", "tenant-x");
        assert_eq!(trigger.trigger_for_recording("rec-3"), TriggerOutcome::Failed);
    }
}
