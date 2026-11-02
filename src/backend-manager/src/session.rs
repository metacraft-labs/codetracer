//! Per-trace session tracking with TTL management.
//!
//! The [`SessionManager`] sits between the daemon's dispatch loop and the
//! [`BackendManager`](crate::backend_manager::BackendManager).  It tracks
//! which trace paths are currently loaded, assigns each an idle-timeout
//! (TTL) timer, and notifies the daemon when a session expires so that
//! the corresponding replay process can be stopped.
//!
//! # TTL Lifecycle
//!
//! 1. **Session added** — [`SessionManager::add_session`] registers the
//!    trace, starts a TTL timer, and returns an error if the max-sessions
//!    limit has been reached.
//! 2. **Activity** — [`SessionManager::reset_ttl`] cancels the running
//!    timer and restarts it.  Any message routed to a session counts as
//!    activity.
//! 3. **Expiry** — When the timer fires without being reset, the session's
//!    canonical path is sent through the `ttl_expiry_tx` channel so that
//!    the daemon can call `stop_replay`.
//! 4. **Removal** — [`SessionManager::remove_session`] cleans up the
//!    session entry and cancels any running timer.
//!
//! # Session identity
//!
//! A session is named by a [`SessionKey`]: the trace path AND whether the
//! replay backend behind it may read a recording's listed sources from this
//! host ([`HostSourceReads`]).  One daemon serves every client on the
//! machine, and two clients may open the same trace with different settings
//! (an MCP server started with `--allow-host-source-reads` and one started
//! without it), so the setting cannot be a property of the daemon, and a
//! backend started for one setting is never handed to a client that asked
//! for the other.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use tokio::sync::mpsc;
use tokio::task::JoinHandle;

// ---------------------------------------------------------------------------
// HostSourceReads and SessionKey
// ---------------------------------------------------------------------------

/// Whether a recording's listed sources may be read from the live host.
///
/// The source list is recording content, written by whatever program was
/// recorded, so it can name any file on the machine that replays it
/// (`/home/<user>/.ssh/id_ed25519`, a credentials file).  A copy the
/// recording carries (a trace folder's `files/`, the raw source views a
/// container bundles) is the recording's own bytes; a listed path with no
/// copy is the host's.  Host reads are therefore off unless the operator of
/// the client turned them on: `trace mcp --allow-host-source-reads` for the
/// MCP server, `hostSourceReads: true` on a daemon request.  A developer
/// reading their own recordings turns them on; an agent that reads
/// recordings someone else produced runs without them.
///
/// The setting governs the MCP server's `read_source_file` and source
/// resource, and every replay backend the daemon starts: a backend launched
/// with host reads off reads source text only from the recording's own
/// copies (see the replay server's `launch` argument `hostSourceReads`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum HostSourceReads {
    /// Only the recording's own copies are read (the default).
    #[default]
    Refused,
    /// A source-list entry with no copy in the recording is read at its
    /// recorded location on this host.
    Allowed,
}

impl HostSourceReads {
    /// The daemon request field (and replay-server `launch` argument) that
    /// carries the setting.  Only the JSON value `true` means
    /// [`HostSourceReads::Allowed`]; an absent field, `false` and any other
    /// value mean [`HostSourceReads::Refused`], so a client that does not
    /// know the field gets the safe setting.
    pub const REQUEST_FIELD: &'static str = "hostSourceReads";

    /// The setting a daemon request's `arguments` carry.
    pub fn from_request(args: Option<&Value>) -> Self {
        match args.and_then(|a| a.get(Self::REQUEST_FIELD)) {
            Some(Value::Bool(true)) => Self::Allowed,
            _ => Self::Refused,
        }
    }

    /// Whether host reads are allowed.
    pub fn is_allowed(self) -> bool {
        self == Self::Allowed
    }

    /// Marks a request's `arguments` object with this setting.  Refused is
    /// written as an explicit `false` rather than left out, so what a client
    /// asked for is visible on the wire.
    pub fn mark_request(self, args: &mut Value) {
        if let Some(object) = args.as_object_mut() {
            object.insert(
                Self::REQUEST_FIELD.to_string(),
                Value::Bool(self.is_allowed()),
            );
        }
    }
}

/// The identity of a daemon session: the trace and the host-read setting its
/// replay backend was started with (see the module documentation).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SessionKey {
    /// The trace path, as the client named it.
    pub trace_path: PathBuf,
    /// Whether the session's backend may read listed sources from the host.
    pub host_source_reads: HostSourceReads,
}

impl SessionKey {
    /// A key for `trace_path` with the given setting.
    pub fn new(trace_path: impl Into<PathBuf>, host_source_reads: HostSourceReads) -> Self {
        Self {
            trace_path: trace_path.into(),
            host_source_reads,
        }
    }

    /// The session a daemon request names: its `tracePath` (passed in, as
    /// every handler has already extracted and validated it) and its
    /// `hostSourceReads` field.
    pub fn for_request(trace_path: &str, args: Option<&Value>) -> Self {
        Self::new(trace_path, HostSourceReads::from_request(args))
    }
}

impl std::fmt::Display for SessionKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let reads = if self.host_source_reads.is_allowed() {
            "host source reads allowed"
        } else {
            "recording sources only"
        };
        write!(f, "{} ({reads})", self.trace_path.display())
    }
}

// ---------------------------------------------------------------------------
// TraceSession
// ---------------------------------------------------------------------------

/// A tracked trace session with TTL management.
///
/// Each session corresponds to exactly one child replay process managed by
/// `BackendManager` (identified by `backend_id`).
pub struct TraceSession {
    /// Index into `BackendManager.children` — used to route messages and
    /// stop the replay when the session expires.
    pub backend_id: usize,

    /// The session's identity: the trace path and its host-read setting.
    pub key: SessionKey,

    /// Handle for the currently running TTL sleep task.
    /// Aborted and respawned on every [`SessionManager::reset_ttl`] call.
    ttl_handle: Option<JoinHandle<()>>,

    /// Language of the traced program (populated by `add_session_with_metadata`
    /// after reading trace files).
    pub language: String,

    /// Total number of execution events in the trace.
    pub total_events: u64,

    /// Source files involved in the trace.
    pub source_files: Vec<String>,

    /// The program that was traced (from the CTFS `meta.dat`).
    pub program: String,

    /// Working directory at the time of recording (from the CTFS `meta.dat`).
    pub workdir: String,
}

impl std::fmt::Debug for TraceSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TraceSession")
            .field("backend_id", &self.backend_id)
            .field("key", &self.key)
            .field("language", &self.language)
            .field("total_events", &self.total_events)
            .field("has_ttl_handle", &self.ttl_handle.is_some())
            .finish()
    }
}

// ---------------------------------------------------------------------------
// SessionManager
// ---------------------------------------------------------------------------

/// Manages trace sessions on top of `BackendManager`.
///
/// Tracks trace-path to session mappings, enforces the max-sessions limit,
/// and drives per-session TTL timers that fire through a channel.
pub struct SessionManager {
    /// Active sessions keyed by trace path and host-read setting.
    sessions: HashMap<SessionKey, TraceSession>,

    /// Default TTL for new sessions (and for TTL resets).
    default_ttl: Duration,

    /// Maximum number of concurrent sessions.
    max_sessions: usize,

    /// Sender for TTL expiry notifications.
    ///
    /// When a session's idle timer fires, its key is sent through this
    /// channel so the daemon loop can call `stop_replay` and clean up.
    ttl_expiry_tx: mpsc::UnboundedSender<SessionKey>,

    /// When the last session was removed, while none has been added since:
    /// how long the daemon has had no trace loaded, after it had one. `None`
    /// before the first session and while any is loaded. Set on every way a
    /// session ends (TTL expiry, `ct/close-trace`, `ct/stop-replay`, a
    /// crashed backend), all of which remove it here.
    emptied_at: Option<std::time::Instant>,
}

impl std::fmt::Debug for SessionManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionManager")
            .field("session_count", &self.sessions.len())
            .field("default_ttl", &self.default_ttl)
            .field("max_sessions", &self.max_sessions)
            .finish()
    }
}

/// Information about a session returned by [`SessionManager::list_sessions`].
#[derive(Debug, Clone)]
pub struct SessionInfo {
    pub key: SessionKey,
    pub backend_id: usize,
    pub language: String,
    pub total_events: u64,
    pub source_files: Vec<String>,
    pub program: String,
    pub workdir: String,
}

impl SessionManager {
    /// Creates a new `SessionManager`.
    ///
    /// Returns the manager and an `UnboundedReceiver<SessionKey>` that the
    /// daemon loop should poll: each received key identifies a session
    /// whose TTL has expired.
    pub fn new(
        default_ttl: Duration,
        max_sessions: usize,
    ) -> (Self, mpsc::UnboundedReceiver<SessionKey>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let mgr = Self {
            sessions: HashMap::new(),
            default_ttl,
            max_sessions,
            ttl_expiry_tx: tx,
            emptied_at: None,
        };
        (mgr, rx)
    }

    /// Returns the number of currently active sessions.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Since when no session has been loaded, after at least one was: see
    /// the `emptied_at` field.
    pub fn emptied_at(&self) -> Option<std::time::Instant> {
        self.emptied_at
    }

    /// Returns the default TTL duration for new sessions.
    ///
    /// This is used in error messages to inform callers how long idle
    /// sessions are kept alive before automatic expiry.
    pub fn default_ttl(&self) -> Duration {
        self.default_ttl
    }

    /// Returns `true` if a session with the given key exists.
    pub fn has_session(&self, path: &SessionKey) -> bool {
        self.sessions.contains_key(path)
    }

    /// Registers a new trace session and starts its TTL timer.
    ///
    /// Returns `Err` if the maximum number of sessions has been reached.
    /// The caller is responsible for invoking `start_replay` on the
    /// `BackendManager` *before* calling this method, so that `backend_id`
    /// is valid.
    pub fn add_session(&mut self, path: SessionKey, backend_id: usize) -> Result<(), SessionError> {
        if self.sessions.len() >= self.max_sessions {
            return Err(SessionError::MaxSessionsReached {
                max: self.max_sessions,
            });
        }

        if self.sessions.contains_key(&path) {
            return Err(SessionError::AlreadyLoaded { key: path.clone() });
        }

        let ttl_handle = self.spawn_ttl_timer(path.clone());

        let session = TraceSession {
            backend_id,
            key: path.clone(),
            ttl_handle: Some(ttl_handle),
            language: String::new(),
            total_events: 0,
            source_files: Vec::new(),
            program: String::new(),
            workdir: String::new(),
        };

        self.sessions.insert(path, session);
        self.emptied_at = None;
        Ok(())
    }

    /// Registers a new trace session with metadata from the trace directory.
    ///
    /// Like [`add_session`], but populates the language, event count,
    /// source files, program, and workdir fields from the provided
    /// [`TraceMetadata`](crate::trace_metadata::TraceMetadata).
    pub fn add_session_with_metadata(
        &mut self,
        path: SessionKey,
        backend_id: usize,
        metadata: &crate::trace_metadata::TraceMetadata,
    ) -> Result<(), SessionError> {
        if self.sessions.len() >= self.max_sessions {
            return Err(SessionError::MaxSessionsReached {
                max: self.max_sessions,
            });
        }

        if self.sessions.contains_key(&path) {
            return Err(SessionError::AlreadyLoaded { key: path.clone() });
        }

        let ttl_handle = self.spawn_ttl_timer(path.clone());

        let session = TraceSession {
            backend_id,
            key: path.clone(),
            ttl_handle: Some(ttl_handle),
            language: metadata.language.clone(),
            total_events: metadata.total_events,
            source_files: metadata.source_files.clone(),
            program: metadata.program.clone(),
            workdir: metadata.workdir.clone(),
        };

        self.sessions.insert(path, session);
        self.emptied_at = None;
        Ok(())
    }

    /// Removes a session, cancelling its TTL timer if still running.
    ///
    /// Returns the `backend_id` of the removed session so the caller can
    /// call `stop_replay`.
    ///
    /// Returns `None` if no session exists for the given path.
    pub fn remove_session(&mut self, path: &SessionKey) -> Option<usize> {
        if let Some(session) = self.sessions.remove(path) {
            if let Some(handle) = session.ttl_handle {
                handle.abort();
            }
            if self.sessions.is_empty() {
                self.emptied_at = Some(std::time::Instant::now());
            }
            Some(session.backend_id)
        } else {
            None
        }
    }

    /// Resets the TTL timer for an active session.
    ///
    /// The old timer is aborted and a fresh one is spawned with the full
    /// `default_ttl` duration.  Does nothing if the session does not exist.
    pub fn reset_ttl(&mut self, path: &SessionKey) {
        if let Some(session) = self.sessions.get_mut(path) {
            // Cancel the old timer.
            if let Some(handle) = session.ttl_handle.take() {
                handle.abort();
            }
            // Spawn a new timer.  We inline the timer creation here to avoid
            // a borrow conflict (self.sessions is borrowed mutably above).
            let ttl = self.default_ttl;
            let tx = self.ttl_expiry_tx.clone();
            let timer_path = path.clone();
            session.ttl_handle = Some(tokio::spawn(async move {
                tokio::time::sleep(ttl).await;
                let _ = tx.send(timer_path);
            }));
        }
    }

    /// Returns information about a session, or `None` if not loaded.
    pub fn get_session(&self, path: &SessionKey) -> Option<SessionInfo> {
        self.sessions.get(path).map(|s| SessionInfo {
            key: s.key.clone(),
            backend_id: s.backend_id,
            language: s.language.clone(),
            total_events: s.total_events,
            source_files: s.source_files.clone(),
            program: s.program.clone(),
            workdir: s.workdir.clone(),
        })
    }

    /// Returns the `backend_id` for a session, or `None`.
    pub fn get_session_backend_id(&self, path: &SessionKey) -> Option<usize> {
        self.sessions.get(path).map(|s| s.backend_id)
    }

    /// Returns summary information for all active sessions.
    pub fn list_sessions(&self) -> Vec<SessionInfo> {
        self.sessions
            .values()
            .map(|s| SessionInfo {
                key: s.key.clone(),
                backend_id: s.backend_id,
                language: s.language.clone(),
                total_events: s.total_events,
                source_files: s.source_files.clone(),
                program: s.program.clone(),
                workdir: s.workdir.clone(),
            })
            .collect()
    }

    /// Looks up a session by its `backend_id`.
    ///
    /// This is used by the dispatch loop to reset the TTL when a message is
    /// routed to a particular replay.
    pub fn path_for_backend_id(&self, backend_id: usize) -> Option<SessionKey> {
        self.sessions
            .values()
            .find(|s| s.backend_id == backend_id)
            .map(|s| s.key.clone())
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Spawns a tokio task that sleeps for `default_ttl` and then sends the
    /// session's path through the expiry channel.
    fn spawn_ttl_timer(&self, path: SessionKey) -> JoinHandle<()> {
        let ttl = self.default_ttl;
        let tx = self.ttl_expiry_tx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(ttl).await;
            // If the channel is closed (daemon shutting down), that is fine —
            // we just silently drop the notification.
            let _ = tx.send(path);
        })
    }
}

// ---------------------------------------------------------------------------
// SessionError
// ---------------------------------------------------------------------------

/// Errors that can occur during session management.
#[derive(Debug)]
pub enum SessionError {
    /// The daemon has reached its configured maximum number of sessions.
    MaxSessionsReached { max: usize },
    /// A session with this key is already loaded.
    AlreadyLoaded { key: SessionKey },
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MaxSessionsReached { max } => {
                write!(f, "maximum number of sessions ({max}) reached")
            }
            Self::AlreadyLoaded { key } => {
                write!(f, "session already loaded for {key}")
            }
        }
    }
}

impl std::error::Error for SessionError {}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: creates a SessionManager with a short TTL and returns it
    /// together with the expiry receiver.
    fn make_session_manager(
        ttl_secs: u64,
        max: usize,
    ) -> (SessionManager, mpsc::UnboundedReceiver<SessionKey>) {
        SessionManager::new(Duration::from_secs(ttl_secs), max)
    }

    /// The default-setting key for a trace path.
    fn key(path: &str) -> SessionKey {
        SessionKey::new(path, HostSourceReads::Refused)
    }

    #[test]
    fn test_add_and_count() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            assert_eq!(mgr.session_count(), 0);

            mgr.add_session(key("/trace/a"), 0).unwrap();
            assert_eq!(mgr.session_count(), 1);

            mgr.add_session(key("/trace/b"), 1).unwrap();
            assert_eq!(mgr.session_count(), 2);
        });
    }

    #[test]
    fn test_has_session() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = key("/trace/x");
            assert!(!mgr.has_session(&p));

            mgr.add_session(p.clone(), 0).unwrap();
            assert!(mgr.has_session(&p));
        });
    }

    #[test]
    fn test_remove_session() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = key("/trace/y");
            mgr.add_session(p.clone(), 42).unwrap();

            let backend_id = mgr.remove_session(&p);
            assert_eq!(backend_id, Some(42));
            assert_eq!(mgr.session_count(), 0);
            assert!(!mgr.has_session(&p));

            // Removing again returns None.
            assert_eq!(mgr.remove_session(&p), None);
        });
    }

    /// One trace opened with each host-read setting is two sessions, each
    /// with its own backend: a client that asked for recording sources only
    /// is never routed to a backend that reads the host.
    #[test]
    fn test_same_trace_with_each_host_read_setting_is_two_sessions() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let refused = SessionKey::new("/trace/shared", HostSourceReads::Refused);
            let allowed = SessionKey::new("/trace/shared", HostSourceReads::Allowed);
            mgr.add_session(refused.clone(), 3).unwrap();
            assert!(!mgr.has_session(&allowed));
            mgr.add_session(allowed.clone(), 4).unwrap();
            assert_eq!(mgr.get_session_backend_id(&refused), Some(3));
            assert_eq!(mgr.get_session_backend_id(&allowed), Some(4));
            assert_eq!(mgr.remove_session(&allowed), Some(4));
            assert_eq!(mgr.get_session_backend_id(&refused), Some(3));
        });
    }

    /// Only a JSON `true` allows host reads; every other value, and an
    /// absent field, is the safe default.
    #[test]
    fn test_host_source_reads_from_request() {
        use serde_json::json;
        assert_eq!(
            HostSourceReads::from_request(Some(&json!({"hostSourceReads": true}))),
            HostSourceReads::Allowed
        );
        for args in [
            json!({}),
            json!({"hostSourceReads": false}),
            json!({"hostSourceReads": "true"}),
            json!({"hostSourceReads": 1}),
            json!({"hostSourceReads": null}),
        ] {
            assert_eq!(
                HostSourceReads::from_request(Some(&args)),
                HostSourceReads::Refused,
                "{args}"
            );
        }
        assert_eq!(
            HostSourceReads::from_request(None),
            HostSourceReads::Refused
        );
        let mut args = json!({"tracePath": "/t"});
        HostSourceReads::Refused.mark_request(&mut args);
        assert_eq!(args["hostSourceReads"], json!(false));
        HostSourceReads::Allowed.mark_request(&mut args);
        assert_eq!(args["hostSourceReads"], json!(true));
    }

    #[test]
    fn emptied_at_marks_when_the_last_loaded_session_went_away() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 4);
            assert_eq!(mgr.emptied_at(), None, "nothing was ever loaded");

            mgr.add_session(key("/a"), 0).unwrap();
            mgr.add_session(key("/b"), 1).unwrap();
            assert_eq!(mgr.emptied_at(), None, "sessions are loaded");
            mgr.remove_session(&key("/a"));
            assert_eq!(mgr.emptied_at(), None, "one session is still loaded");

            let before = std::time::Instant::now();
            mgr.remove_session(&key("/b"));
            let emptied = mgr.emptied_at().expect("the last session went away");
            assert!(emptied >= before, "it records when the last one went away");

            // Removing what is not there changes nothing.
            mgr.remove_session(&key("/b"));
            assert_eq!(mgr.emptied_at(), Some(emptied));

            mgr.add_session(key("/c"), 2).unwrap();
            assert_eq!(mgr.emptied_at(), None, "a session is loaded again");
        });
    }

    #[test]
    fn test_max_sessions_enforced() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 2);
            mgr.add_session(key("/a"), 0).unwrap();
            mgr.add_session(key("/b"), 1).unwrap();

            let result = mgr.add_session(key("/c"), 2);
            assert!(result.is_err());
            assert!(matches!(
                result.unwrap_err(),
                SessionError::MaxSessionsReached { max: 2 }
            ));
        });
    }

    #[test]
    fn test_duplicate_session_rejected() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = key("/dup");
            mgr.add_session(p.clone(), 0).unwrap();

            let result = mgr.add_session(p.clone(), 1);
            assert!(result.is_err());
            assert!(matches!(
                result.unwrap_err(),
                SessionError::AlreadyLoaded { .. }
            ));
        });
    }

    #[test]
    fn test_list_sessions() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            mgr.add_session(key("/t1"), 0).unwrap();
            mgr.add_session(key("/t2"), 1).unwrap();

            let list = mgr.list_sessions();
            assert_eq!(list.len(), 2);

            let keys: Vec<_> = list.iter().map(|s| &s.key).collect();
            assert!(keys.contains(&&key("/t1")));
            assert!(keys.contains(&&key("/t2")));
        });
    }

    #[test]
    fn test_path_for_backend_id() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = key("/trace/z");
            mgr.add_session(p.clone(), 7).unwrap();

            assert_eq!(mgr.path_for_backend_id(7), Some(p));
            assert_eq!(mgr.path_for_backend_id(999), None);
        });
    }

    #[tokio::test]
    async fn test_ttl_expiry_fires() {
        let (mut mgr, mut rx) = make_session_manager(1, 10);
        let p = key("/ttl-test");
        mgr.add_session(p.clone(), 0).unwrap();

        // Wait for the TTL to fire (1 second + margin).
        let result = tokio::time::timeout(Duration::from_secs(3), rx.recv()).await;
        assert!(result.is_ok(), "expected TTL expiry notification");
        assert_eq!(result.unwrap(), Some(p));
    }

    #[tokio::test]
    async fn test_reset_ttl_postpones_expiry() {
        let (mut mgr, mut rx) = make_session_manager(2, 10);
        let p = key("/ttl-reset-test");
        mgr.add_session(p.clone(), 0).unwrap();

        // Wait 1 second (less than TTL), then reset.
        tokio::time::sleep(Duration::from_secs(1)).await;
        mgr.reset_ttl(&p);

        // After 1.5 more seconds (2.5 total, but only 1.5 since reset),
        // the session should NOT have expired yet.
        let result = tokio::time::timeout(Duration::from_millis(1500), rx.recv()).await;
        assert!(result.is_err(), "session should not have expired yet");

        // But after another full TTL, it should.
        let result = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
        assert!(result.is_ok(), "expected TTL expiry after reset");
    }

    #[tokio::test]
    async fn test_remove_cancels_ttl() {
        let (mut mgr, mut rx) = make_session_manager(1, 10);
        let p = key("/ttl-cancel-test");
        mgr.add_session(p.clone(), 0).unwrap();

        // Remove immediately (before TTL fires).
        mgr.remove_session(&p);

        // No expiry notification should arrive.
        let result = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
        // The channel should either timeout or return None (closed).
        match result {
            Err(_) => { /* timeout — expected */ }
            Ok(None) => { /* channel closed — also fine */ }
            Ok(Some(path)) => {
                panic!("unexpected TTL expiry for removed session: {path}");
            }
        }
    }
}
