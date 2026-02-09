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

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::task::JoinHandle;

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

    /// Canonical filesystem path of the trace (used as the session key).
    pub trace_path: PathBuf,

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

    /// The program that was traced (from `trace_metadata.json`).
    pub program: String,

    /// Working directory at the time of recording (from `trace_metadata.json`).
    pub workdir: String,
}

impl std::fmt::Debug for TraceSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TraceSession")
            .field("backend_id", &self.backend_id)
            .field("trace_path", &self.trace_path)
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
    /// Active sessions keyed by canonical trace path.
    sessions: HashMap<PathBuf, TraceSession>,

    /// Default TTL for new sessions (and for TTL resets).
    default_ttl: Duration,

    /// Maximum number of concurrent sessions.
    max_sessions: usize,

    /// Sender for TTL expiry notifications.
    ///
    /// When a session's idle timer fires, its `trace_path` is sent through
    /// this channel so the daemon loop can call `stop_replay` and clean up.
    ttl_expiry_tx: mpsc::UnboundedSender<PathBuf>,
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
    pub trace_path: PathBuf,
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
    /// Returns the manager and an `UnboundedReceiver<PathBuf>` that the
    /// daemon loop should poll: each received path identifies a session
    /// whose TTL has expired.
    pub fn new(
        default_ttl: Duration,
        max_sessions: usize,
    ) -> (Self, mpsc::UnboundedReceiver<PathBuf>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let mgr = Self {
            sessions: HashMap::new(),
            default_ttl,
            max_sessions,
            ttl_expiry_tx: tx,
        };
        (mgr, rx)
    }

    /// Returns the number of currently active sessions.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Returns `true` if a session for the given trace path exists.
    pub fn has_session(&self, path: &PathBuf) -> bool {
        self.sessions.contains_key(path)
    }

    /// Registers a new trace session and starts its TTL timer.
    ///
    /// Returns `Err` if the maximum number of sessions has been reached.
    /// The caller is responsible for invoking `start_replay` on the
    /// `BackendManager` *before* calling this method, so that `backend_id`
    /// is valid.
    pub fn add_session(
        &mut self,
        path: PathBuf,
        backend_id: usize,
    ) -> Result<(), SessionError> {
        if self.sessions.len() >= self.max_sessions {
            return Err(SessionError::MaxSessionsReached {
                max: self.max_sessions,
            });
        }

        if self.sessions.contains_key(&path) {
            return Err(SessionError::AlreadyLoaded {
                path: path.clone(),
            });
        }

        let ttl_handle = self.spawn_ttl_timer(path.clone());

        let session = TraceSession {
            backend_id,
            trace_path: path.clone(),
            ttl_handle: Some(ttl_handle),
            language: String::new(),
            total_events: 0,
            source_files: Vec::new(),
            program: String::new(),
            workdir: String::new(),
        };

        self.sessions.insert(path, session);
        Ok(())
    }

    /// Registers a new trace session with metadata from the trace directory.
    ///
    /// Like [`add_session`], but populates the language, event count,
    /// source files, program, and workdir fields from the provided
    /// [`TraceMetadata`](crate::trace_metadata::TraceMetadata).
    pub fn add_session_with_metadata(
        &mut self,
        path: PathBuf,
        backend_id: usize,
        metadata: &crate::trace_metadata::TraceMetadata,
    ) -> Result<(), SessionError> {
        if self.sessions.len() >= self.max_sessions {
            return Err(SessionError::MaxSessionsReached {
                max: self.max_sessions,
            });
        }

        if self.sessions.contains_key(&path) {
            return Err(SessionError::AlreadyLoaded {
                path: path.clone(),
            });
        }

        let ttl_handle = self.spawn_ttl_timer(path.clone());

        let session = TraceSession {
            backend_id,
            trace_path: path.clone(),
            ttl_handle: Some(ttl_handle),
            language: metadata.language.clone(),
            total_events: metadata.total_events,
            source_files: metadata.source_files.clone(),
            program: metadata.program.clone(),
            workdir: metadata.workdir.clone(),
        };

        self.sessions.insert(path, session);
        Ok(())
    }

    /// Removes a session, cancelling its TTL timer if still running.
    ///
    /// Returns the `backend_id` of the removed session so the caller can
    /// call `stop_replay`.
    ///
    /// Returns `None` if no session exists for the given path.
    pub fn remove_session(&mut self, path: &PathBuf) -> Option<usize> {
        if let Some(session) = self.sessions.remove(path) {
            if let Some(handle) = session.ttl_handle {
                handle.abort();
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
    pub fn reset_ttl(&mut self, path: &PathBuf) {
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
    pub fn get_session(&self, path: &PathBuf) -> Option<SessionInfo> {
        self.sessions.get(path).map(|s| SessionInfo {
            trace_path: s.trace_path.clone(),
            backend_id: s.backend_id,
            language: s.language.clone(),
            total_events: s.total_events,
            source_files: s.source_files.clone(),
            program: s.program.clone(),
            workdir: s.workdir.clone(),
        })
    }

    /// Returns the `backend_id` for a session, or `None`.
    pub fn get_session_backend_id(&self, path: &PathBuf) -> Option<usize> {
        self.sessions.get(path).map(|s| s.backend_id)
    }

    /// Returns summary information for all active sessions.
    pub fn list_sessions(&self) -> Vec<SessionInfo> {
        self.sessions
            .values()
            .map(|s| SessionInfo {
                trace_path: s.trace_path.clone(),
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
    pub fn path_for_backend_id(&self, backend_id: usize) -> Option<PathBuf> {
        self.sessions
            .values()
            .find(|s| s.backend_id == backend_id)
            .map(|s| s.trace_path.clone())
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Spawns a tokio task that sleeps for `default_ttl` and then sends the
    /// session's path through the expiry channel.
    fn spawn_ttl_timer(&self, path: PathBuf) -> JoinHandle<()> {
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
    /// A session for this trace path is already loaded.
    AlreadyLoaded { path: PathBuf },
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MaxSessionsReached { max } => {
                write!(f, "maximum number of sessions ({max}) reached")
            }
            Self::AlreadyLoaded { path } => {
                write!(f, "session already loaded for {}", path.display())
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
    ) -> (SessionManager, mpsc::UnboundedReceiver<PathBuf>) {
        SessionManager::new(Duration::from_secs(ttl_secs), max)
    }

    #[test]
    fn test_add_and_count() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            assert_eq!(mgr.session_count(), 0);

            mgr.add_session(PathBuf::from("/trace/a"), 0).unwrap();
            assert_eq!(mgr.session_count(), 1);

            mgr.add_session(PathBuf::from("/trace/b"), 1).unwrap();
            assert_eq!(mgr.session_count(), 2);
        });
    }

    #[test]
    fn test_has_session() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = PathBuf::from("/trace/x");
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
            let p = PathBuf::from("/trace/y");
            mgr.add_session(p.clone(), 42).unwrap();

            let backend_id = mgr.remove_session(&p);
            assert_eq!(backend_id, Some(42));
            assert_eq!(mgr.session_count(), 0);
            assert!(!mgr.has_session(&p));

            // Removing again returns None.
            assert_eq!(mgr.remove_session(&p), None);
        });
    }

    #[test]
    fn test_max_sessions_enforced() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 2);
            mgr.add_session(PathBuf::from("/a"), 0).unwrap();
            mgr.add_session(PathBuf::from("/b"), 1).unwrap();

            let result = mgr.add_session(PathBuf::from("/c"), 2);
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
            let p = PathBuf::from("/dup");
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
            mgr.add_session(PathBuf::from("/t1"), 0).unwrap();
            mgr.add_session(PathBuf::from("/t2"), 1).unwrap();

            let list = mgr.list_sessions();
            assert_eq!(list.len(), 2);

            let paths: Vec<_> = list.iter().map(|s| &s.trace_path).collect();
            assert!(paths.contains(&&PathBuf::from("/t1")));
            assert!(paths.contains(&&PathBuf::from("/t2")));
        });
    }

    #[test]
    fn test_path_for_backend_id() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let (mut mgr, _rx) = make_session_manager(300, 10);
            let p = PathBuf::from("/trace/z");
            mgr.add_session(p.clone(), 7).unwrap();

            assert_eq!(mgr.path_for_backend_id(7), Some(p));
            assert_eq!(mgr.path_for_backend_id(999), None);
        });
    }

    #[tokio::test]
    async fn test_ttl_expiry_fires() {
        let (mut mgr, mut rx) = make_session_manager(1, 10);
        let p = PathBuf::from("/ttl-test");
        mgr.add_session(p.clone(), 0).unwrap();

        // Wait for the TTL to fire (1 second + margin).
        let result = tokio::time::timeout(Duration::from_secs(3), rx.recv()).await;
        assert!(result.is_ok(), "expected TTL expiry notification");
        assert_eq!(result.unwrap(), Some(p));
    }

    #[tokio::test]
    async fn test_reset_ttl_postpones_expiry() {
        let (mut mgr, mut rx) = make_session_manager(2, 10);
        let p = PathBuf::from("/ttl-reset-test");
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
        let p = PathBuf::from("/ttl-cancel-test");
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
                panic!("unexpected TTL expiry for removed session: {}", path.display());
            }
        }
    }
}
