//! M26 — browser-recorder receiver **host process**.
//!
//! Companion of [`crate::browser_stream_receiver`]: that module owns the
//! wire event vocabulary, the line parser, and the [`CtfsWriter`] trait
//! used by the unit tests; this module owns the **runnable** half — a
//! tokio + `tokio-tungstenite` WebSocket server that listens on
//! `ws://<host>:<port>/ct-stream`, accepts one connection per browser tab,
//! dispatches each received text frame's events to a per-connection
//! [`StreamReceiver`], and persists the resulting recording under a
//! user-chosen output directory.
//!
//! # Wire format
//!
//! The browser side
//! ([`codetracer-js-recorder/packages/runtime-browser/src/index.ts`])
//! batches `BrowserEvent`s and ships them over WebSocket as
//! newline-delimited JSON, one event per line.  The first event is always
//! `SessionStart {program, args}`; the last (on `pagehide` /
//! `__ct.stop()`) is `SessionEnd {}`.  See `Value-Origin-Tracking.md`
//! §14.4 for the full event vocabulary.  That is a transport between the
//! page and this host; it is never persisted.
//!
//! # On-disk format
//!
//! `codetracer-specs/Recording-Backends/Browser-Recording-Container.md` §2:
//! one CTFS container per connection, `<out_dir>/<program>.ct`, written by
//! the pure-Rust `CtfsTraceWriter` ([`CtfsRecordingWriter`]).  It opens in
//! the debugger like any other JavaScript recording.  Inside it, as the
//! internal file `boundary.log`, is the boundary log
//! ([`crate::boundary_log`], CTBL v1) — the same record sequence in the
//! framed binary encoding `codetracer-wasm-recorder` replays a module
//! against.
//!
//! The container is written under `<out_dir>/.record-web-partial/` while
//! the session runs and renamed into place when it ends, so a reader of
//! `<out_dir>` never meets a half-written recording.
//!
//! # Feeding the streaming consumer (opt-in)
//!
//! `WASM-Replay-Snapshots-And-Slices.md` §2 derives snapshots *during*
//! recording: "the browser streams boundary events; a replaying recorder
//! consumes that stream as it arrives and re-executes in lockstep".
//! [`StreamConsumerConfig::command`] is spawned once per recording and fed
//! the boundary log on stdin, frame by frame, as records are translated —
//! the shape `wazero run --boundary-stream - <module>` wants.  EOF is
//! unambiguous (the daemon closes stdin after the `End` frame) and
//! backpressure is real (the consumer reads only between exported calls).
//! Its absence or failure costs seek performance only — a broken tee is
//! logged and the recording continues.
//!
//! Each frame is assembled into one buffer and handed to a single
//! `write_all`, so a producer that dies leaves whole frames and no `End`:
//! a stream the consumer classifies as unterminated rather than torn.

use std::fs;
use std::io;
use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

use codetracer_trace_types::{EventLogKind, TypeKind, ValueRecord};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

use crate::boundary_log;
use crate::browser_stream_receiver::{
    BrowserEvent, CtfsWriter, EncodedValue, GlobalSet, ImportedGlobalState, ImportedMemoryState,
    MemoryWrite, StreamReceiver, default_output_path,
};

/// Default listen address.  Matches the URL the browser runtime ships to
/// (`ws://localhost:9230/ct-stream`).
pub const DEFAULT_BIND: &str = "127.0.0.1:9230";

/// Default endpoint path advertised on the server side.  Connections to
/// any other path are accepted but the server logs a warning — the path
/// is informational only.
pub const DEFAULT_ENDPOINT_PATH: &str = "/ct-stream";

/// Placeholder substituted in every [`StreamConsumerConfig::command`]
/// argument with the path the recording's `.ct` will be written to.
///
/// The daemon only knows that path once the page has announced its program
/// name, so it cannot be baked into the command line by the operator.  The
/// container itself does not exist until the session ends; a consumer uses
/// the path to name what it derives (`--slice-dir {trace}.slices`).
pub const TRACE_PLACEHOLDER: &str = "{trace}";

/// The placeholder this host used to substitute, when a recording was a
/// directory.  Refused by [`StreamConsumerConfig::validate`]: substituting
/// a file path into an argument written for a directory would hand the
/// consumer paths like `<program>.ct/slices`, inside a file.
pub const RETIRED_TRACE_DIR_PLACEHOLDER: &str = "{trace_dir}";

/// How the daemon hands the recording's boundary log to a
/// `WASM-Replay-Snapshots-And-Slices.md` §2 consumer.
///
/// Off by default: `record-web` without it spawns nothing.
#[derive(Debug, Clone, Default)]
pub struct StreamConsumerConfig {
    /// Command and arguments spawned once per recording, fed the boundary
    /// log (CTBL v1) on stdin.  Empty means "spawn nothing".
    ///
    /// Every argument has [`TRACE_PLACEHOLDER`] replaced with the
    /// recording's `.ct` path.  A typical value:
    ///
    /// ```text
    /// wazero-snapshots run --boundary-stream - \
    ///     --slice-dir {trace}.slices --slice-every 10 original.wasm
    /// ```
    pub command: Vec<String>,
}

impl StreamConsumerConfig {
    /// Refuse a command that still uses the retired `{trace_dir}`
    /// placeholder, naming the replacement.
    pub fn validate(&self) -> Result<(), String> {
        if let Some(arg) = self
            .command
            .iter()
            .find(|arg| arg.contains(RETIRED_TRACE_DIR_PLACEHOLDER))
        {
            return Err(format!(
                "--snapshot-consumer argument `{arg}` uses {RETIRED_TRACE_DIR_PLACEHOLDER}, \
                 which named the recording directory. A recording is now a single .ct \
                 file; use {TRACE_PLACEHOLDER} for its path"
            ));
        }
        Ok(())
    }
}

/// Configuration for the [`BrowserStreamHost`].
#[derive(Debug, Clone)]
pub struct BrowserStreamHostConfig {
    /// Address to bind the TCP listener to.  Defaults to [`DEFAULT_BIND`].
    pub bind: SocketAddr,
    /// Directory under which per-program `.ct` trace directories land.
    /// Created on demand if it does not exist.
    pub out_dir: PathBuf,
    /// Working directory recorded in the recording's metadata.  Defaults to
    /// the host process's CWD at start time.
    pub workdir: PathBuf,
    /// Optional §2 streaming-consumer wiring.  Defaults to
    /// [`StreamConsumerConfig::default`], which spawns nothing.
    pub stream_consumer: StreamConsumerConfig,
    /// Exit by itself once no browser has been connected for this long.
    /// `None` disables the watchdog and the host runs until signalled.
    ///
    /// This is what stops the daemon outliving whatever started it.  See
    /// [`DEFAULT_IDLE_TIMEOUT`] for why the host has to reap itself rather
    /// than trusting its launcher to do it.
    pub idle_timeout: Option<Duration>,
}

/// How long the host tolerates having no connected browser before it
/// concludes it has been abandoned and exits.
///
/// # Why the host reaps itself
///
/// Every caller detaches this process — the fixture regenerators run it
/// under `setsid(1)` so the recorded page is not in the launcher's process
/// group.  That is deliberate (the recorded server must not receive the
/// launcher's signals), but it also means the daemon is unreachable by
/// every mechanism a supervisor would normally use: it is in its own
/// session, so no terminal SIGHUP reaches it, and a `kill -- -<pgid>` of
/// the launcher's group misses it.  The launcher's `trap ... EXIT` is
/// therefore the only thing in the system that ever reaps it — and an
/// `EXIT` trap does not run when the launcher is `SIGKILL`ed, which is
/// exactly how CI step timeouts, `timeout(1)` escalation and OOM kills end
/// a run.  Measured consequence: 22 orphaned hosts on one developer box,
/// the oldest 47 hours old and one of them spinning a CPU for 34 of them.
///
/// A self-imposed deadline is the only fix that holds, because it is the
/// only one that survives its launcher dying in a way the launcher cannot
/// observe.  It is also the only one that is safe under concurrency: the
/// host reasons *solely about its own accepted connections*, so it can
/// never take down a peer that another run is legitimately using — unlike
/// an external sweep over `pgrep`-matched command lines, which cannot tell
/// a leaked host from a busy one.
///
/// # Why ten minutes
///
/// The window being bounded is "host started, browser has not connected
/// yet": the caller still has to start the recorded backend and launch
/// headless Chromium.  A whole recording run is ~40 s, so ten minutes is
/// an order of magnitude of headroom for a heavily loaded machine, while
/// still turning a two-day orphan into a ten-minute one.  The clock is
/// reset by every connection and every disconnection, so it can never
/// interrupt work in progress, however long the recording runs.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(600);

/// Longest gap between two idle checks.  The watchdog wakes at
/// `min(idle_timeout / 4, IDLE_POLL_MAX)` so a short timeout (tests use
/// hundreds of milliseconds) is still honoured promptly, while a
/// production-length one costs a handful of wakeups per minute.
const IDLE_POLL_MAX: Duration = Duration::from_secs(5);

/// Live-connection count plus the instant the host was last busy, shared
/// between the accept loop and every spawned connection task.
///
/// "Busy" deliberately means *a connection existed*, not *bytes arrived*:
/// a browser that has connected and is mid-recording may legitimately send
/// nothing for a long time while the page computes, and the host must not
/// mistake that for abandonment.  While `live > 0` the host never times
/// out at all; the timer only runs once the last connection has gone.
#[derive(Clone)]
struct IdleState {
    live: Arc<AtomicUsize>,
    last_active: Arc<Mutex<Instant>>,
}

impl IdleState {
    fn new() -> Self {
        Self {
            live: Arc::new(AtomicUsize::new(0)),
            last_active: Arc::new(Mutex::new(Instant::now())),
        }
    }

    /// Reset the abandonment clock.  A poisoned lock is recovered from
    /// rather than propagated: losing this timestamp must never take down
    /// a host that is recording.
    fn touch(&self) {
        let mut slot = self
            .last_active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *slot = Instant::now();
    }

    fn live_connections(&self) -> usize {
        self.live.load(Ordering::SeqCst)
    }

    fn idle_for(&self) -> Duration {
        self.last_active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .elapsed()
    }

    /// True when nothing is connected and nothing has been for `timeout`.
    fn abandoned_for(&self, timeout: Duration) -> bool {
        self.live_connections() == 0 && self.idle_for() >= timeout
    }
}

/// RAII counter for one accepted connection.  A guard rather than manual
/// increment/decrement so the count is still correct when
/// `handle_connection` returns early through `?`, panics, or is dropped
/// mid-await at shutdown — any of which would otherwise pin the count
/// above zero and disable the watchdog permanently.
struct ConnectionGuard {
    state: IdleState,
}

impl ConnectionGuard {
    fn enter(state: &IdleState) -> Self {
        state.live.fetch_add(1, Ordering::SeqCst);
        state.touch();
        Self {
            state: state.clone(),
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.state.live.fetch_sub(1, Ordering::SeqCst);
        // Stamp on the way out too, so the timeout is measured from the
        // end of the last recording rather than from its start.
        self.state.touch();
    }
}

impl BrowserStreamHostConfig {
    /// Create a config with `bind = DEFAULT_BIND` and `out_dir = out_dir`,
    /// resolving `workdir` from the current process working directory.
    pub fn with_defaults(out_dir: PathBuf) -> Self {
        let bind: SocketAddr = DEFAULT_BIND
            .parse()
            .expect("DEFAULT_BIND is a valid socket address");
        let workdir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        Self {
            bind,
            out_dir,
            workdir,
            stream_consumer: StreamConsumerConfig::default(),
            idle_timeout: Some(DEFAULT_IDLE_TIMEOUT),
        }
    }
}

/// Runnable WebSocket host.  Accepts connections, parses the
/// newline-delimited JSON event stream, and persists every recording to a
/// fresh `.ct` directory under [`BrowserStreamHostConfig::out_dir`].
pub struct BrowserStreamHost {
    config: BrowserStreamHostConfig,
}

impl BrowserStreamHost {
    pub fn new(config: BrowserStreamHostConfig) -> Self {
        Self { config }
    }

    /// Bind the TCP listener and return a [`RunningHost`] handle so the
    /// caller can capture the bound address (useful when `bind` is `:0`)
    /// and a shutdown signal.
    ///
    /// Spawning the accept loop is kept separate from binding so unit
    /// tests can deterministically wait for the listener to be ready
    /// before connecting.
    pub async fn bind(&self) -> io::Result<RunningHost> {
        let listener = TcpListener::bind(self.config.bind).await?;
        let local_addr = listener.local_addr()?;
        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let (idle_tx, idle_rx) = oneshot::channel::<()>();
        let config = self.config.clone();
        let join = tokio::spawn(accept_loop(listener, config, shutdown_rx, idle_tx));
        Ok(RunningHost {
            local_addr,
            shutdown_tx: Some(shutdown_tx),
            idle_rx: Some(idle_rx),
            join: Some(join),
        })
    }
}

/// Handle to a running host.  Drop or explicit `stop()` cleanly terminates
/// the accept loop; any in-flight connections finish their current frame
/// before the task exits.
pub struct RunningHost {
    pub local_addr: SocketAddr,
    shutdown_tx: Option<oneshot::Sender<()>>,
    idle_rx: Option<oneshot::Receiver<()>>,
    join: Option<tokio::task::JoinHandle<()>>,
}

impl RunningHost {
    /// Resolves when the accept loop has stopped *itself* because the host
    /// sat idle for [`BrowserStreamHostConfig::idle_timeout`].
    ///
    /// Never resolves when the watchdog is disabled, or when the loop ends
    /// for any other reason — so a caller can `select!` this against its
    /// signal handler and treat resolution as "we were abandoned", with no
    /// risk of a spurious wakeup racing the ordinary shutdown path.
    pub async fn idle_shutdown(&mut self) {
        if let Some(rx) = self.idle_rx.take()
            && rx.await.is_ok()
        {
            return;
        }
        // Sender dropped without firing (ordinary shutdown), or already
        // observed: this future must simply never complete.
        std::future::pending::<()>().await
    }

    /// Send the shutdown signal and await the accept loop's exit.
    pub async fn stop(mut self) -> io::Result<()> {
        if let Some(tx) = self.shutdown_tx.take() {
            // The receiver may already have dropped if the loop exited on
            // its own — ignore the send error in that case.
            let _ = tx.send(());
        }
        if let Some(join) = self.join.take() {
            join.await
                .map_err(|e| io::Error::other(format!("accept loop join failed: {e}")))?;
        }
        Ok(())
    }
}

impl Drop for RunningHost {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
    }
}

/// The accept loop — runs until the shutdown signal fires or the listener
/// returns an unrecoverable error.  Per-connection work happens in
/// spawned tasks so a slow recording does not stall the listener.
async fn accept_loop(
    listener: TcpListener,
    config: BrowserStreamHostConfig,
    mut shutdown_rx: oneshot::Receiver<()>,
    idle_tx: oneshot::Sender<()>,
) {
    let idle_state = IdleState::new();
    let idle_timeout = config.idle_timeout;
    // Poll far more often than the deadline so the check is prompt for the
    // sub-second timeouts the tests use, and cheap for production ones.
    let poll_every = idle_timeout
        .map(|t| (t / 4).clamp(Duration::from_millis(10), IDLE_POLL_MAX))
        .unwrap_or(IDLE_POLL_MAX);
    let mut idle_tx = Some(idle_tx);

    loop {
        tokio::select! {
            biased;
            _ = &mut shutdown_rx => {
                log::info!("browser-stream host shutting down");
                return;
            }
            // Only armed when a timeout is configured; a disabled watchdog
            // must not even wake the loop.
            _ = tokio::time::sleep(poll_every), if idle_timeout.is_some() => {
                let timeout = match idle_timeout {
                    Some(t) => t,
                    None => continue,
                };
                if idle_state.abandoned_for(timeout) {
                    // Say why on stderr as well as in the log: the usual
                    // reader of this line is someone wondering where their
                    // recording daemon went, and the fixture scripts do not
                    // enable the logger.
                    let secs = timeout.as_secs_f64();
                    log::info!(
                        "browser-stream host: no browser connected for {secs:.1}s — exiting"
                    );
                    eprintln!(
                        "codetracer browser-stream host: no browser connected for {secs:.1}s; \
                         exiting so this daemon does not outlive whatever started it"
                    );
                    if let Some(tx) = idle_tx.take() {
                        let _ = tx.send(());
                    }
                    return;
                }
            }
            accept = listener.accept() => {
                match accept {
                    Ok((stream, peer)) => {
                        log::info!("browser-stream host: accepted connection from {peer}");
                        let cfg = config.clone();
                        // Counted *here*, before the task is spawned, so
                        // there is no window in which an accepted browser
                        // is invisible to the watchdog.
                        let guard = ConnectionGuard::enter(&idle_state);
                        tokio::spawn(async move {
                            let _guard = guard;
                            if let Err(err) = handle_connection(stream, cfg).await {
                                log::warn!("browser-stream host: connection from {peer} failed: {err}");
                            }
                        });
                    }
                    Err(err) => {
                        log::error!("browser-stream host: accept failed: {err}");
                        // Brief backoff to avoid a tight error loop if the
                        // listener is wedged (e.g. fd exhaustion).
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }
}

/// Handle a single accepted TCP connection: upgrade to WebSocket, route
/// every text frame's lines through the receiver, and persist the writer
/// on close.
async fn handle_connection(
    stream: tokio::net::TcpStream,
    config: BrowserStreamHostConfig,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let ws_stream = tokio_tungstenite::accept_async(stream).await?;
    let (_write, mut read) = ws_stream.split();

    // Each connection gets its own writer + receiver.  The writer is
    // shared with the receiver through the `CtfsWriter` trait so the
    // unit-test suite (in `browser_stream_receiver::tests`) can reuse the
    // same plumbing with `InMemoryCtfsWriter`.
    let writer_handle = Arc::new(Mutex::new(CtfsRecordingWriter::with_stream_consumer(
        config.out_dir.clone(),
        config.workdir.clone(),
        config.stream_consumer.clone(),
    )));
    let writer = shared_writer_from(writer_handle.clone());
    let mut receiver = StreamReceiver::new(writer);

    while let Some(message) = read.next().await {
        let message = message?;
        match message {
            Message::Text(text) => {
                // The browser runtime ships one event per WebSocket text
                // frame in M26 V1, but the wire format is officially
                // newline-delimited JSON — handle both shapes by
                // splitting on '\n' and feeding each non-empty line.
                let ended = receiver.feed_buffer(&text)?;
                if ended > 0 {
                    // `feed_buffer` returns the *count* of events; we do
                    // not currently early-exit per-frame.  The session-end
                    // signal is observed through the writer below.
                    log::debug!("browser-stream host: forwarded {ended} events for current frame");
                }
            }
            Message::Binary(bytes) => {
                // Browser runtimes are spec'd to ship UTF-8 text; binary
                // is reserved for forwards-compat.  Decode as UTF-8 and
                // feed through the same path so a misconfigured runtime
                // does not silently drop events.
                let text = std::str::from_utf8(&bytes)
                    .map_err(|e| format!("non-UTF-8 binary frame: {e}"))?;
                receiver.feed_buffer(text)?;
            }
            Message::Ping(_) | Message::Pong(_) => {
                // tokio-tungstenite auto-responds to pings; nothing for
                // us to do here.
            }
            Message::Close(_) => {
                log::info!("browser-stream host: peer sent Close frame");
                break;
            }
            Message::Frame(_) => {
                // Raw frames only appear in `accept_unauth` mode which we
                // do not use; ignore defensively.
            }
        }
    }

    // The session may have ended on the wire (SessionEnd event) or via a
    // raw close — both paths flush the writer if it hasn't already.
    let mut w = writer_handle
        .lock()
        .map_err(|_| "writer mutex poisoned".to_string())?;
    if !w.session_ended {
        // The peer hung up without a clean SessionEnd — finalise the
        // trace anyway so the partial recording is inspectable.
        let _ = w.session_end()?;
    }
    log::info!(
        "browser-stream host: recording persisted to {}",
        w.last_output_path
            .clone()
            .unwrap_or_else(|| PathBuf::from("<not written>"))
            .display(),
    );
    Ok(())
}

// `shared_writer` in `browser_stream_receiver` consumes a `W: CtfsWriter + 'static`
// by value, but here we have to keep an `Arc<Mutex<CtfsRecordingWriter>>` around so
// the connection handler can inspect `last_output_path` after the receiver runs.
// This helper wraps an existing `Arc<Mutex<W>>` as `Arc<Mutex<dyn CtfsWriter>>`
// without losing the typed handle.
fn shared_writer_from<W>(arc: Arc<Mutex<W>>) -> Arc<Mutex<dyn CtfsWriter>>
where
    W: CtfsWriter + 'static,
{
    arc as Arc<Mutex<dyn CtfsWriter>>
}

// ---------------------------------------------------------------------------
// The CTFS recording writer
// ---------------------------------------------------------------------------

/// A [`CtfsWriter`] that records a browser session into one CTFS `.ct`.
///
/// Every translated record goes two places at once:
///
/// * into a [`CtfsTraceWriter`] writing `<out_dir>/.record-web-partial/<program>.ct`,
///   which is renamed to `<out_dir>/<program>.ct` when the session ends; and
/// * into the CTBL v1 boundary log ([`crate::boundary_log`]), which is teed
///   live to the `--snapshot-consumer` process and stored in the finished
///   container as its `boundary.log` internal file.
///
/// The record sequence is the same in both, which is what lets the replaying
/// recorder and the debugger agree about which crossing is which.
pub struct CtfsRecordingWriter {
    out_dir: PathBuf,
    workdir: PathBuf,
    program: String,
    args: Vec<String>,
    /// The recording being written.  `None` before the first record and
    /// after `session_end` has finalised it — see [`Self::open_stream`].
    open: Option<OpenRecording>,
    /// The `.ct` path chosen when the recording opened.  Once fixed it is
    /// never recomputed, so a program name that arrives late cannot move a
    /// recording that has already started.
    output_path: Option<PathBuf>,
    /// §2 consumer wiring; see [`StreamConsumerConfig`].
    stream_consumer: StreamConsumerConfig,
    /// Path interning table, in registration order: a path's position is
    /// the `path_id` every `Step` and `Function` refers to.
    path_index: indexmap_compat::OrderedSet<PathBuf>,
    /// Function interning table, keyed by the runtime's own `fnId`, which
    /// this maps 1:1 onto the recording's dense `function_id`.
    fn_table: indexmap_compat::OrderedMap<u32, FunctionRecordOnDisk>,
    /// Variable-name interning table.  A recording identifies a variable by
    /// its position in `VariableName` registration order, so a writer that
    /// named a variable but always wrote id 0 would attribute every value to
    /// whichever name happened to be registered first.
    var_index: indexmap_compat::OrderedSet<String>,
    /// Instrumentation manifest forwarded by the page runtime.  `None` until
    /// a `Manifest` event arrives (or forever, for a runtime that does not
    /// bundle one) — in that case the writer falls back to the `<browser>`
    /// placeholder path and site-id-as-line encoding.
    manifest: Option<InstrumentationManifest>,
    /// Whether a spec §3.3 `HostInitialState` has been recorded.  The page
    /// sends it once, before the first exported call; a second one would
    /// mean two sessions were spliced together.
    host_initial_seen: bool,
    /// Whether `session_end` has run.  Set once the `.ct` is in place, so a
    /// second call is a no-op.
    pub session_ended: bool,
    /// The `.ct` the session was finalised into, for logging and tests.
    pub last_output_path: Option<PathBuf>,
}

/// The parts of a recording that only exist between its first record and
/// its finalisation.
struct OpenRecording {
    writer: CtfsTraceWriter,
    /// Where the container is written while the session runs.  Renamed onto
    /// the final path at session end, so a reader of `<out_dir>` never sees
    /// a half-written `.ct`.
    partial_path: PathBuf,
    /// The whole boundary log so far, magic and version included.  Small: a
    /// browser recording's boundary log is the page's host interactions,
    /// not its memory.
    boundary: Vec<u8>,
    tee: Option<ConsumerTee>,
    /// Records written, for the consumer's exit log line.
    records: u64,
    /// Type ids registered on first use, by kind.
    types: std::collections::HashMap<&'static str, codetracer_trace_types::TypeId>,
}

/// Name of the directory, inside `--out-dir`, recordings are written into
/// while their session runs.  Hidden, so a scan of `<out_dir>/*.ct` cannot
/// mistake an unfinished recording for a finished one.
pub const PARTIAL_DIR_NAME: &str = ".record-web-partial";

/// What the browser recording names as its producer, in the boundary log's
/// header frame.
const RECORDER_NAME: &str = "codetracer-js-recorder-browser";

/// `boundary_id` of the in-stream spec §3.3 / §3.4 records (M44b).
///
/// Deliberately not `js-wasm-realm`: a reader of the realm markers must
/// not have to tell these apart from a crossing marker, and the consumer's
/// `parseRealmMarker` rejects this one on the `boundary_id` check alone.
///
/// Must match `hostStateBoundary` in
/// `codetracer-wasm-recorder/internal/boundarylog/hoststate.go`.
const HOST_STATE_BOUNDARY_ID: &str = "wasm-host-state";

/// Schema version of the host-state records.
///
/// The consumer treats an unrecognised version as a **hard error** rather
/// than reading what it recognises, because the whole point of §3.3 is
/// that a missing input produces a divergence later, at a point unrelated
/// to the cause.  Bumping this therefore means bumping it there too.
const HOST_STATE_VERSION: u32 = 1;

/// The two in-stream record kinds.  Must match `hostStateRecordInitial` /
/// `hostStateRecordMutation` in the consumer.
const HOST_STATE_RECORD_INITIAL: &str = "initial";
const HOST_STATE_RECORD_MUTATION: &str = "mutation";

/// Render one host-state record's `metadata` document.
///
/// The payload rides in an `Event`'s `metadata`, the same carrier the realm
/// and correlation markers on this path use, so the record lives in the
/// recording itself (the source of truth) and in the boundary log, which
/// mirrors it, without a record type every reader would have to learn.
///
/// `field` is the key the payload lands under (`initial` or `mutation`),
/// so the consumer can decode straight into its own schema types rather
/// than into a variant wrapper.
fn host_state_marker_metadata<T: Serialize>(
    record: &str,
    field: &str,
    payload: &T,
) -> io::Result<String> {
    let document = serde_json::json!({
        "boundary_id": HOST_STATE_BOUNDARY_ID,
        "version": HOST_STATE_VERSION,
        "record": record,
        field: payload,
    });
    serde_json::to_string(&document)
        .map_err(|e| io::Error::other(format!("host state marker serialisation: {e}")))
}

/// Spec §3.3 initial state, as the consumer's `InitialState` decodes it.
///
/// `tables` is always empty: the producer never records imported-table
/// state, and the consumer *rejects* a recording that carries any (spec §8
/// lists host-mutated imported tables among the constructs refused rather
/// than silently degraded).  It is emitted rather than omitted so the record
/// states the fact instead of leaving it to a missing key.
#[derive(Debug, Default, Serialize)]
struct InitialStateRecord {
    memories: Vec<ImportedMemoryState>,
    globals: Vec<ImportedGlobalState>,
    tables: Vec<serde_json::Value>,
}

/// Spec §3.4 mutation, as the consumer's `HostMutation` decodes it.
#[derive(Debug, Serialize)]
struct HostMutationRecord {
    #[serde(rename = "afterCrossing")]
    after_crossing: u32,
    #[serde(rename = "memoryWrites")]
    memory_writes: Vec<MemoryWrite>,
    #[serde(rename = "globalSets")]
    global_sets: Vec<GlobalSet>,
}

/// Decoded form of the instrumenter's trace manifest.
///
/// The page-side runtime ships this verbatim as the `Manifest` browser
/// event; it is the merge of every per-module `ManifestSlice` the SWC
/// instrumenter produced (see
/// `codetracer-js-recorder/packages/instrumenter/src/index.ts`).
///
/// Without it a browser recording cannot carry real source locations:
/// the runtime's `Step` events reference a flat numeric `siteId`, and
/// only the manifest knows which `(path, line)` that id stands for.
/// Everything downstream that reasons about source — the origin
/// classifier, correlation-marker locations, the editor pane — needs
/// that resolution, so forwarding the manifest is what makes a browser
/// trace a first-class recording rather than an opaque event log.
#[derive(Debug, Clone, serde::Deserialize)]
struct InstrumentationManifest {
    /// Source paths, indexed by `pathIndex` in the tables below.
    #[serde(default)]
    paths: Vec<String>,
    #[serde(default)]
    functions: Vec<ManifestFunction>,
    #[serde(default)]
    sites: Vec<ManifestSite>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestFunction {
    #[serde(default)]
    name: String,
    #[serde(default)]
    path_index: usize,
    #[serde(default)]
    line: i64,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManifestSite {
    #[serde(default)]
    path_index: usize,
    #[serde(default)]
    line: i64,
    /// For write sites, the name of the binding being assigned.
    ///
    /// Turning an assignment event into a named variable needs this:
    /// the runtime reports only the site id and the value, because the
    /// name is static and belongs in the manifest rather than on every
    /// event.
    #[serde(default)]
    target: Option<String>,
}

impl CtfsRecordingWriter {
    pub fn new(out_dir: PathBuf, workdir: PathBuf) -> Self {
        Self::with_stream_consumer(out_dir, workdir, StreamConsumerConfig::default())
    }

    /// Same as [`Self::new`] but with the §2 streaming-consumer wiring
    /// attached.  Kept separate so the default constructor stays the
    /// "spawn nothing" one.
    pub fn with_stream_consumer(
        out_dir: PathBuf,
        workdir: PathBuf,
        stream_consumer: StreamConsumerConfig,
    ) -> Self {
        Self {
            out_dir,
            workdir,
            program: String::new(),
            args: Vec::new(),
            open: None,
            output_path: None,
            stream_consumer,
            path_index: indexmap_compat::OrderedSet::new(),
            fn_table: indexmap_compat::OrderedMap::new(),
            var_index: indexmap_compat::OrderedSet::new(),
            manifest: None,
            host_initial_seen: false,
            session_ended: false,
            last_output_path: None,
        }
    }

    /// The `.ct` this recording lands in, chosen from the program name the
    /// page announced.
    ///
    /// `default_output_path` sanitises the program name so an untrusted page
    /// title cannot traverse the output layout.
    fn resolve_output_path(&self) -> PathBuf {
        if let Some(path) = &self.output_path {
            return path.clone();
        }
        let program_name = if self.program.is_empty() {
            "browser".to_string()
        } else {
            self.program.clone()
        };
        default_output_path(&self.out_dir, &program_name)
    }

    /// Start the container and the boundary log, and spawn the §2 consumer,
    /// if any.  Idempotent.
    ///
    /// Deferred to the first record rather than done in `session_start`
    /// because the output path is derived from the program name, and only a
    /// session that produced at least one record — or ended — needs a
    /// recording at all.
    fn open_stream(&mut self) -> io::Result<()> {
        if self.open.is_some() {
            return Ok(());
        }
        let output_path = self.resolve_output_path();
        let file_name = output_path
            .file_name()
            .ok_or_else(|| io::Error::other("the recording path has no file name"))?;
        let partial_dir = self.out_dir.join(PARTIAL_DIR_NAME);
        fs::create_dir_all(&partial_dir)?;
        let partial_path = partial_dir.join(file_name);
        // A previous run's leftover at this path is a recording that never
        // finished; writing over it is right, appending to it would not be.
        if partial_path.exists() {
            fs::remove_file(&partial_path)?;
        }

        let mut writer = CtfsTraceWriter::new(&self.program, &self.args);
        TraceWriter::set_workdir(&mut writer, &self.workdir);
        TraceWriter::begin_writing_trace_events(&mut writer, &partial_path).map_err(|e| {
            io::Error::other(format!("could not start {}: {e}", partial_path.display()))
        })?;

        // `None` takes type id 0, which is `NONE_TYPE_ID` by the trace
        // format's convention; every other type is registered on first use.
        let mut types = std::collections::HashMap::new();
        types.insert("None", TraceWriter::ensure_type_id(&mut writer, TypeKind::None, "None"));

        let mut boundary = Vec::with_capacity(4096);
        boundary.extend_from_slice(&boundary_log::stream_prefix());
        boundary.extend_from_slice(&boundary_log::encode_frame(&boundary_log::Record::Header {
            program: self.program.clone(),
            args: self.args.clone(),
            workdir: self.workdir.to_string_lossy().into_owned(),
            recorder_name: RECORDER_NAME.to_string(),
            recorder_version: env!("CARGO_PKG_VERSION").to_string(),
        }));

        let mut tee = self.spawn_consumer(&output_path);
        if let Some(tee) = tee.as_mut() {
            tee.write(&boundary);
        }

        self.output_path = Some(output_path);
        self.open = Some(OpenRecording {
            writer,
            partial_path,
            boundary,
            tee,
            records: 0,
            types,
        });
        Ok(())
    }

    /// Spawn the configured §2 consumer, or return `None`.
    ///
    /// A failure to spawn is logged and swallowed: the consumer only ever
    /// makes seeking faster, so its absence must never cost the user their
    /// recording (spec §11 / `MCR-Memory-Page-CAS.md` §10 take the same
    /// line about snapshot versions).
    fn spawn_consumer(&self, output_path: &std::path::Path) -> Option<ConsumerTee> {
        let command = &self.stream_consumer.command;
        let (program, args) = command.split_first()?;
        let substitute = |arg: &String| -> String {
            arg.replace(TRACE_PLACEHOLDER, &output_path.to_string_lossy())
        };
        let program = substitute(program);
        let args: Vec<String> = args.iter().map(substitute).collect();
        let label = format!("{program} {}", args.join(" "));
        let spawned = Command::new(&program)
            .args(&args)
            .stdin(Stdio::piped())
            .spawn();
        match spawned {
            Ok(mut child) => {
                let stdin = child.stdin.take();
                if stdin.is_none() {
                    log::warn!(
                        "browser-stream writer: snapshot consumer `{label}` has no stdin; \
                         the recording continues without it"
                    );
                }
                log::info!("browser-stream writer: streaming the boundary log into `{label}`");
                Some(ConsumerTee {
                    child,
                    stdin,
                    label,
                    records: 0,
                })
            }
            Err(err) => {
                log::warn!(
                    "browser-stream writer: could not spawn the snapshot consumer `{label}`: \
                     {err}. The recording is unaffected; seeking it will be linear."
                );
                None
            }
        }
    }

    /// Append one record to the recording and the boundary log (and the
    /// tee), opening the recording on the first call.
    fn emit(&mut self, record: boundary_log::Record) -> io::Result<()> {
        if self.session_ended {
            // The recording is finalised; a record arriving after it has
            // nowhere to go.  The single-shot writers dropped these too, so
            // this is the same loss made audible.
            log::warn!(
                "browser-stream writer: dropping a record that arrived after session end: \
                 {record:?}"
            );
            return Ok(());
        }
        self.open_stream()?;
        let open = self
            .open
            .as_mut()
            .expect("open_stream leaves the recording open");
        let frame = boundary_log::encode_frame(&record);
        // The recording first, the tee second: the recording is the source
        // of truth (spec §2), snapshots are derived data, so the `.ct` must
        // never be short of a record the consumer already has.
        open.apply(&record);
        open.boundary.extend_from_slice(&frame);
        open.records += 1;
        if let Some(tee) = open.tee.as_mut() {
            tee.write(&frame);
            tee.records += 1;
        }
        Ok(())
    }

    /// Resolve a variable name to its id, registering it on first sight.
    fn intern_variable(&mut self, name: &str) -> io::Result<u32> {
        let (idx, inserted) = self.var_index.insert_full(name.to_string());
        if inserted {
            self.emit(boundary_log::Record::VariableName(name.to_string()))?;
        }
        Ok(idx as u32)
    }

    /// Resolve a manifest site id to its `(path_id, line)` pair,
    /// interning the source path on first sight.
    ///
    /// Returns `None` when no manifest was forwarded or the id is out of
    /// range, in which case callers fall back to the `<browser>`
    /// placeholder so a manifest-less runtime still produces a readable
    /// (if source-less) trace rather than failing the recording.
    fn resolve_site(&mut self, site_id: u32) -> io::Result<Option<(u32, i64)>> {
        let resolved = {
            let Some(manifest) = self.manifest.as_ref() else {
                return Ok(None);
            };
            let Some(site) = manifest.sites.get(site_id as usize) else {
                return Ok(None);
            };
            let Some(path) = manifest.paths.get(site.path_index).cloned() else {
                return Ok(None);
            };
            (path, site.line)
        };
        let (path, line) = resolved;
        Ok(Some((self.intern_path(&path)?, line)))
    }

    /// The `(path_id, line)` a `Step` / `Assignment` record carries.
    ///
    /// Falls back to the `<browser>` placeholder with the site id smuggled
    /// as the line when no manifest was forwarded, so a manifest-less
    /// runtime still records.
    fn step_position(&mut self, site_id: u32) -> io::Result<(u32, i64)> {
        match self.resolve_site(site_id)? {
            Some(position) => Ok(position),
            None => Ok((self.ensure_default_path()?, i64::from(site_id))),
        }
    }

    /// The name of the binding a write site assigns, when the manifest
    /// records one.
    fn site_target(&self, site_id: u32) -> Option<String> {
        self.manifest
            .as_ref()?
            .sites
            .get(site_id as usize)?
            .target
            .clone()
    }

    /// Resolve a manifest function id to its `(name, path_id, line)`
    /// triple. Same fallback contract as [`Self::resolve_site`].
    fn resolve_function(&mut self, fn_id: u32) -> io::Result<Option<(String, u32, i64)>> {
        let resolved = {
            let Some(manifest) = self.manifest.as_ref() else {
                return Ok(None);
            };
            let Some(function) = manifest.functions.get(fn_id as usize) else {
                return Ok(None);
            };
            let Some(path) = manifest.paths.get(function.path_index).cloned() else {
                return Ok(None);
            };
            (function.name.clone(), path, function.line)
        };
        let (name, path, line) = resolved;
        Ok(Some((name, self.intern_path(&path)?, line)))
    }

    /// Resolve a runtime-side path string to its `path_id`, interning the
    /// path if it has not been seen yet.
    fn intern_path(&mut self, path: &str) -> io::Result<u32> {
        let path_buf = PathBuf::from(path);
        let (idx, inserted) = self.path_index.insert_full(path_buf.clone());
        if inserted {
            self.emit(boundary_log::Record::Path(
                path_buf.to_string_lossy().into_owned(),
            ))?;
        }
        Ok(idx as u32)
    }

    /// Translate a [`BrowserEvent`] into one or more records.  Some browser
    /// events expand to several (e.g. a `Call` may emit a synthetic
    /// `Function` record the first time its `fnId` is seen).
    fn translate(&mut self, event: &BrowserEvent) -> io::Result<()> {
        use boundary_log::Record;
        match event {
            BrowserEvent::Path { path_id: _, path } => {
                // The runtime's path_id is opaque; we re-intern through
                // our own table so the recorded indices stay dense and
                // start at 0.
                self.intern_path(path)?;
            }
            BrowserEvent::Step { site_id } => {
                // Browser site IDs are flat; the forwarded manifest carries
                // the `(path, line)` tuple per site.  Without one we fall
                // back to the `<browser>` placeholder path, site id smuggled
                // as the line, so manifest-less runtimes still record.
                let (path_id, line) = self.step_position(*site_id)?;
                self.emit(Record::Step { path_id, line })?;
            }
            BrowserEvent::Assignment { site_id, value } => {
                // Same position resolution as Step — an assignment site is
                // a step site with write metadata attached.
                let (path_id, line) = self.step_position(*site_id)?;
                self.emit(Record::Step { path_id, line })?;
                // Bind the value to its name so the recording carries
                // variables, not just positions.
                if let (Some(target), Some(value)) = (self.site_target(*site_id), value.as_ref()) {
                    let variable_id = self.intern_variable(&target)?;
                    self.emit(Record::Value {
                        variable_id,
                        value: translate_value(value),
                    })?;
                }
            }
            BrowserEvent::Call { fn_id, args } => {
                let function_id = self.ensure_function_id(*fn_id)?;
                let args = args
                    .iter()
                    .enumerate()
                    .map(|(i, v)| (i as u32, translate_value(v)))
                    .collect();
                self.emit(Record::Call { function_id, args })?;
            }
            BrowserEvent::Return {
                fn_id: _,
                return_value,
            } => {
                self.emit(Record::Return(translate_value(return_value)))?;
            }
            BrowserEvent::Value { name, value } => {
                let variable_id = self.intern_variable(name)?;
                self.emit(Record::Value {
                    variable_id,
                    value: translate_value(value),
                })?;
            }
            BrowserEvent::Write { channel, content } => {
                self.emit(Record::Event {
                    kind: write_channel_to_kind(channel),
                    metadata: channel.clone(),
                    content: content.clone(),
                })?;
            }
            BrowserEvent::CorrelationMarker {
                direction,
                boundary,
                key,
                payload,
                show_text,
            } => {
                // Correlation markers land as Event records whose
                // `metadata` slot carries a **complete** M25
                // `MarkerPayload` document.  This shape is load-bearing,
                // not cosmetic: the db-backend's `SessionHandler::pair_index`
                // calls `MarkerPayload::decode(&event.metadata)` and
                // silently drops any firing that does not deserialise into
                // the full struct.  Field names and the
                // `key_value`-is-a-string convention therefore mirror
                // `codetracer/src/db-backend/src/correlation_markers.rs`
                // exactly.
                //
                // `key_value` is stringified because the pair index matches
                // sends to receives by string equality on
                // `(boundary_id, key_value)`; numbers and strings that
                // render identically must therefore collapse to the same
                // key.
                let key_value = match key {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                };
                let show_value = payload.as_ref().map(|p| match p {
                    serde_json::Value::String(s) => s.clone(),
                    other => other.to_string(),
                });
                let metadata = serde_json::json!({
                    "marker_id": 0,
                    "boundary_id": boundary,
                    "direction": direction,
                    "key_text": "key",
                    "key_value": key_value,
                    // `show_text` names the binding the walk resumes on
                    // after crossing this boundary.
                    "show_text": show_text,
                    "show_value": show_value,
                    "description": serde_json::Value::Null,
                    "format": serde_json::Value::Null,
                })
                .to_string();
                let content = serde_json::json!({
                    "key": key,
                    "payload": payload,
                })
                .to_string();
                self.emit(Record::Event {
                    kind: EVENT_KIND_TRACE_LOG_EVENT,
                    metadata,
                    content,
                })?;
            }
            // --- spec §3.3 / §3.4: host-supplied state ------------------
            //
            // These describe the module's *starting state* and what the
            // host did to it during a host call.  Each is one `Event`
            // record, appended the moment it arrives, so a streaming
            // consumer has it in hand before the crossing it is anchored
            // to — §3.3 is only known at the first exported call, after the
            // consumer was spawned, and its position relative to that call
            // is unambiguous only in the stream.
            //
            // `Event` is an open extension point on this path
            // (`parseRealmMarker` in `internal/boundarylog/recording.go`
            // returns "not mine" for a `boundary_id` it does not know), so
            // `ct print` and the db-backend skip these records.
            BrowserEvent::HostInitialState { memories, globals } => {
                if self.host_initial_seen {
                    // The producer emits this once, immediately before the
                    // first exported call.  A second one would mean two
                    // recordings were spliced together; keeping the first
                    // is the only reading that stays true to the calls
                    // already written.
                    log::warn!(
                        "browser-stream writer: ignoring a second HostInitialState event; \
                         spec §3.3 state is the state before the FIRST exported call"
                    );
                } else {
                    self.host_initial_seen = true;
                    let initial = InitialStateRecord {
                        memories: memories.clone(),
                        globals: globals.clone(),
                        tables: Vec::new(),
                    };
                    let metadata =
                        host_state_marker_metadata(HOST_STATE_RECORD_INITIAL, "initial", &initial)?;
                    self.emit(Record::Event {
                        kind: EVENT_KIND_TRACE_LOG_EVENT,
                        metadata,
                        content: String::new(),
                    })?;
                }
            }
            BrowserEvent::HostMutation {
                after_crossing,
                memory_writes,
                global_sets,
            } => {
                let record = HostMutationRecord {
                    after_crossing: *after_crossing,
                    memory_writes: memory_writes.clone(),
                    global_sets: global_sets.clone(),
                };
                let metadata =
                    host_state_marker_metadata(HOST_STATE_RECORD_MUTATION, "mutation", &record)?;
                // Emitted before the import's own `LEAVE` realm marker
                // reaches the stream, so a streaming consumer has the write
                // in hand at the moment it services the crossing the write
                // is anchored to.
                self.emit(Record::Event {
                    kind: EVENT_KIND_TRACE_LOG_EVENT,
                    metadata,
                    content: String::new(),
                })?;
            }
            // Lifecycle events are handled in the trait impls below.
            BrowserEvent::SessionStart { .. }
            | BrowserEvent::Manifest { .. }
            | BrowserEvent::SessionEnd {} => {}
        }
        Ok(())
    }

    /// Resolve the runtime's `fn_id` to the recording's function id.  The
    /// browser runtime does not ship a separate `Function` event before the
    /// first `Call`, so one is synthesised on first sight — from the
    /// manifest's real `(name, path, line)` when there is one, from a
    /// placeholder otherwise.
    fn ensure_function_id(&mut self, fn_id: u32) -> io::Result<u32> {
        let (name, path_id, line) = match self.resolve_function(fn_id)? {
            Some(resolved) => resolved,
            None => (format!("fn_{fn_id}"), self.ensure_default_path()?, 0),
        };
        let next_id = self.fn_table.len() as u32;
        let mut newly_inserted = false;
        let assigned = self
            .fn_table
            .entry(fn_id)
            .or_insert_with(|| {
                newly_inserted = true;
                FunctionRecordOnDisk {
                    function_id: next_id,
                }
            })
            .function_id;
        if newly_inserted {
            // The `Function` record must precede the `Call` that triggered
            // the lookup; `translate` emits the `Call` afterwards.
            self.emit(boundary_log::Record::Function {
                name,
                path_id,
                line,
            })?;
        }
        Ok(assigned)
    }

    /// The placeholder path for Step / Assignment events of a runtime that
    /// forwarded no manifest.  `<browser>` is the marker the db-backend
    /// recognises as "browser recording, manifest not forwarded".
    fn ensure_default_path(&mut self) -> io::Result<u32> {
        self.intern_path("<browser>")
    }

    /// Finalise the recording: end the boundary log, close the container,
    /// store the boundary log inside it, move it into place, and let the
    /// consumer see the end of the stream.
    ///
    /// Idempotent; subsequent calls are no-ops once `session_ended` is
    /// true.  A session that ended without ever emitting a record still
    /// lands a complete, empty recording.
    fn flush(&mut self) -> io::Result<PathBuf> {
        if self.session_ended {
            return Ok(self
                .last_output_path
                .clone()
                .unwrap_or_else(|| self.out_dir.clone()));
        }
        self.open_stream()?;
        let output_path = self
            .output_path
            .clone()
            .expect("open_stream fixes the output path");
        let mut open = self
            .open
            .take()
            .expect("open_stream leaves the recording open");

        let end = boundary_log::encode_frame(&boundary_log::Record::End);
        open.boundary.extend_from_slice(&end);
        if let Some(tee) = open.tee.as_mut() {
            tee.write(&end);
        }

        TraceWriter::finish_writing_trace_events(&mut open.writer)
            .map_err(|e| io::Error::other(format!("could not finish the recording: {e}")))?;
        store_boundary_log(&open.partial_path, &open.boundary)?;
        fs::rename(&open.partial_path, &output_path)?;

        self.session_ended = true;
        self.last_output_path = Some(output_path.clone());

        // Dropping the tee closes the consumer's stdin, which is what gives
        // `--boundary-stream -` its unambiguous end of stream, and reaps the
        // child so a long-running daemon does not accumulate zombies.  It
        // happens after the rename, so the `.ct`'s mtime is the moment the
        // recording stopped being produced, not the moment the consumer
        // finished catching up.
        drop(open);
        Ok(output_path)
    }
}

/// Add the boundary log to a finished container as its `boundary.log`
/// internal file.
///
/// The trace writer has already closed the container, so the file is
/// appended through the CTFS append path — the same one snapshots are
/// attached through (`WASM-Replay-Snapshots-And-Slices.md` §6).
fn store_boundary_log(container: &std::path::Path, boundary: &[u8]) -> io::Result<()> {
    let ctfs_err = |what: &str, e: codetracer_ctfs::CtfsError| {
        io::Error::other(format!("{what} {}: {e:?}", container.display()))
    };
    let mut writer = codetracer_ctfs::CtfsWriter::open_append(container)
        .map_err(|e| ctfs_err("could not reopen", e))?;
    let handle = writer
        .add_file(boundary_log::INTERNAL_FILE_NAME)
        .map_err(|e| ctfs_err("could not add the boundary log to", e))?;
    writer
        .write(handle, boundary)
        .map_err(|e| ctfs_err("could not write the boundary log into", e))?;
    writer.close().map_err(|e| ctfs_err("could not close", e))?;
    Ok(())
}

impl OpenRecording {
    /// The type id of `kind`, registering the type on first use.
    fn type_id(&mut self, kind: TypeKind, name: &'static str) -> codetracer_trace_types::TypeId {
        if let Some(id) = self.types.get(name) {
            return *id;
        }
        let id = TraceWriter::ensure_type_id(&mut self.writer, kind, name);
        self.types.insert(name, id);
        id
    }

    /// The recording's value for a boundary-log value.
    ///
    /// Integers and floats that do not fit `i64` / `f64` — a JS `BigInt`,
    /// a NaN-payload spelling — are recorded as `Raw` with the producer's
    /// exact text rather than truncated.
    fn value(&mut self, value: &boundary_log::Value) -> ValueRecord {
        use boundary_log::Value;
        match value {
            Value::Int(text) => match text.parse::<i64>() {
                Ok(i) => ValueRecord::Int {
                    i,
                    type_id: self.type_id(TypeKind::Int, "Int"),
                },
                Err(_) => ValueRecord::Raw {
                    r: text.clone(),
                    type_id: self.type_id(TypeKind::Raw, "Raw"),
                },
            },
            Value::Float(text) => match text.parse::<f64>() {
                Ok(f) => ValueRecord::Float {
                    f,
                    type_id: self.type_id(TypeKind::Float, "Float"),
                },
                Err(_) => ValueRecord::Raw {
                    r: text.clone(),
                    type_id: self.type_id(TypeKind::Raw, "Raw"),
                },
            },
            Value::Bool(b) => ValueRecord::Bool {
                b: *b,
                type_id: self.type_id(TypeKind::Bool, "Bool"),
            },
            Value::String(text) => ValueRecord::String {
                text: text.clone(),
                type_id: self.type_id(TypeKind::String, "String"),
            },
            Value::Raw(text) => ValueRecord::Raw {
                r: text.clone(),
                type_id: self.type_id(TypeKind::Raw, "Raw"),
            },
            Value::None => ValueRecord::None {
                type_id: self.type_id(TypeKind::None, "None"),
            },
        }
    }

    /// Write one boundary-log record into the CTFS recording.
    fn apply(&mut self, record: &boundary_log::Record) {
        use boundary_log::Record;
        use codetracer_trace_types::{
            CallRecord, FullValueRecord, FunctionId, FunctionRecord, Line, PathId, RecordEvent,
            ReturnRecord, StepRecord, TraceLowLevelEvent, VariableId,
        };
        match record {
            Record::Header { .. } | Record::End => {}
            Record::Path(path) => {
                TraceWriter::ensure_path_id(&mut self.writer, std::path::Path::new(path));
            }
            Record::Function {
                name,
                path_id,
                line,
            } => TraceWriter::add_event(
                &mut self.writer,
                TraceLowLevelEvent::Function(FunctionRecord {
                    path_id: PathId(*path_id as usize),
                    line: Line(*line),
                    name: name.clone(),
                }),
            ),
            Record::Step { path_id, line } => TraceWriter::add_event(
                &mut self.writer,
                TraceLowLevelEvent::Step(StepRecord {
                    path_id: PathId(*path_id as usize),
                    line: Line(*line),
                }),
            ),
            Record::Call { function_id, args } => {
                let args = args
                    .iter()
                    .map(|(variable_id, value)| FullValueRecord {
                        variable_id: VariableId(*variable_id as usize),
                        value: self.value(value),
                    })
                    .collect();
                TraceWriter::add_event(
                    &mut self.writer,
                    TraceLowLevelEvent::Call(CallRecord {
                        function_id: FunctionId(*function_id as usize),
                        args,
                    }),
                );
            }
            Record::Return(value) => {
                let return_value = self.value(value);
                TraceWriter::add_event(
                    &mut self.writer,
                    TraceLowLevelEvent::Return(ReturnRecord { return_value }),
                );
            }
            Record::Value { variable_id, value } => {
                let value = self.value(value);
                TraceWriter::add_event(
                    &mut self.writer,
                    TraceLowLevelEvent::Value(FullValueRecord {
                        variable_id: VariableId(*variable_id as usize),
                        value,
                    }),
                );
            }
            Record::VariableName(name) => {
                TraceWriter::ensure_variable_id(&mut self.writer, name);
            }
            Record::Event {
                kind,
                metadata,
                content,
            } => TraceWriter::add_event(
                &mut self.writer,
                TraceLowLevelEvent::Event(RecordEvent {
                    kind: event_log_kind(*kind),
                    metadata: metadata.clone(),
                    content: content.clone(),
                }),
            ),
        }
    }
}

/// The recording's event kind for a boundary-log `Event` kind.
fn event_log_kind(kind: i32) -> EventLogKind {
    match kind {
        EVENT_KIND_TRACE_LOG_EVENT => EventLogKind::TraceLogEvent,
        _ => EventLogKind::Write,
    }
}

// ---------------------------------------------------------------------------
// The live consumer
// ---------------------------------------------------------------------------

/// The spawned §2 consumer and the pipe into it.
struct ConsumerTee {
    child: Child,
    /// `None` once writing has failed or the pipe has been closed.
    stdin: Option<std::process::ChildStdin>,
    /// The resolved command line, for log messages.
    label: String,
    /// Frames handed to the consumer, for the exit log line.
    records: u64,
}

impl ConsumerTee {
    /// Hand `bytes` to the consumer.
    ///
    /// A blocking write is deliberate: it is how the consumer's
    /// backpressure reaches the browser (the WebSocket's TCP window), which
    /// keeps the replayer from accumulating an unbounded backlog of
    /// unreplayed crossings.  A failure is logged once and the tee dropped —
    /// it costs seek performance, never the recording.
    fn write(&mut self, bytes: &[u8]) {
        let Some(stdin) = self.stdin.as_mut() else {
            return;
        };
        if let Err(err) = stdin.write_all(bytes) {
            log::warn!(
                "browser-stream writer: the snapshot consumer `{}` stopped reading ({err}); \
                 continuing without it. The recording is unaffected.",
                self.label,
            );
            self.stdin = None;
        }
    }
}

/// How long a finished recording waits for its consumer to exit before
/// killing it.
///
/// Generous, because the consumer is finishing a replay it has been
/// keeping up with all session and sealing its last slice, but bounded:
/// `Child::wait` on a wedged consumer would hang the connection task for
/// the lifetime of the daemon, and the recording is already complete by
/// then, so nothing is gained by waiting forever.
const CONSUMER_EXIT_GRACE: std::time::Duration = std::time::Duration::from_secs(60);
/// Polling interval while waiting out [`CONSUMER_EXIT_GRACE`].
const CONSUMER_POLL: std::time::Duration = std::time::Duration::from_millis(20);

impl Drop for ConsumerTee {
    fn drop(&mut self) {
        let records = self.records;
        // Close the pipe first: the consumer reads until EOF, so it will not
        // exit before stdin closes and waiting on it first would deadlock.
        self.stdin = None;
        let deadline = std::time::Instant::now() + CONSUMER_EXIT_GRACE;
        loop {
            match self.child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    log::info!(
                        "browser-stream writer: snapshot consumer `{}` finished after {records} \
                         record(s)",
                        self.label,
                    );
                    return;
                }
                Ok(Some(status)) => {
                    log::warn!(
                        "browser-stream writer: snapshot consumer `{}` exited with {status}; \
                         the recording is complete but seeking it will be linear",
                        self.label,
                    );
                    return;
                }
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(CONSUMER_POLL);
                }
                Ok(None) => {
                    log::warn!(
                        "browser-stream writer: snapshot consumer `{}` did not exit within {:?} \
                         of end of stream; killing it. The recording is complete; its snapshots \
                         may be partial and can be re-derived.",
                        self.label,
                        CONSUMER_EXIT_GRACE,
                    );
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    return;
                }
                Err(err) => {
                    log::warn!(
                        "browser-stream writer: could not wait for the snapshot consumer `{}`: \
                         {err}",
                        self.label,
                    );
                    return;
                }
            }
        }
    }
}

impl CtfsWriter for CtfsRecordingWriter {
    fn session_start(&mut self, program: &str, args: &[String]) -> io::Result<()> {
        if self.output_path.is_some() && self.program != program {
            // `SessionStart` is spec'd as the very first line, so the
            // output path is normally fixed before any record arrives. If
            // a runtime announces itself late the recording stays where it
            // already is rather than splitting in two — say so instead of
            // silently choosing.
            log::warn!(
                "browser-stream writer: SessionStart named program `{program}` after the \
                 recording had already opened as `{}`; keeping the existing output path",
                self.program,
            );
            return Ok(());
        }
        self.program = program.to_string();
        self.args = args.to_vec();
        Ok(())
    }

    fn manifest(&mut self, manifest: &serde_json::Value) -> io::Result<()> {
        // Decode the instrumenter manifest so subsequent `Step` / `Call`
        // events resolve to real source locations.  A manifest that fails to
        // decode is logged and ignored rather than failing the recording — a
        // partially-understood manifest must not cost the user their trace.
        match serde_json::from_value::<InstrumentationManifest>(manifest.clone()) {
            Ok(decoded) => {
                log::info!(
                    "browser-stream writer: manifest accepted ({} path(s), {} function(s), {} site(s))",
                    decoded.paths.len(),
                    decoded.functions.len(),
                    decoded.sites.len(),
                );
                self.manifest = Some(decoded);
            }
            Err(err) => {
                log::warn!(
                    "browser-stream writer: ignoring undecodable manifest ({err}); \
                     steps will fall back to the <browser> placeholder path"
                );
            }
        }
        Ok(())
    }

    fn event(&mut self, event: &BrowserEvent) -> io::Result<()> {
        self.translate(event)
    }

    fn session_end(&mut self) -> io::Result<PathBuf> {
        self.flush()
    }
}

/// `EventLogKind::TraceLogEvent` discriminator, as the boundary log carries
/// it — mirrors `FfiEventLogKind::FFI_EVENT_TRACE_LOG_EVENT = 12` in
/// `codetracer_trace_writer.h`.
const EVENT_KIND_TRACE_LOG_EVENT: i32 = 12;
/// Stdout / stderr discriminator.
const EVENT_KIND_WRITE: i32 = 0;

fn write_channel_to_kind(channel: &str) -> i32 {
    // Stdout / stderr both map onto the generic Write kind — the channel
    // tag rides in the metadata field.
    let _ = channel;
    EVENT_KIND_WRITE
}

/// Convert a browser-side encoded value into its boundary-log value.
/// Lossless for primitives; compound payloads fall back to `Raw` with the
/// JSON value stringified verbatim.
fn translate_value(encoded: &EncodedValue) -> boundary_log::Value {
    use boundary_log::Value;
    match encoded.type_kind.as_str() {
        "Int" => Value::Int(value_to_compact_string(&encoded.value)),
        "Float" => Value::Float(value_to_compact_string(&encoded.value)),
        "Bool" => Value::Bool(encoded.value.as_bool().unwrap_or(false)),
        "String" => Value::String(encoded.value.as_str().unwrap_or("").to_string()),
        "None" => Value::None,
        _ => Value::Raw(value_to_compact_string(&encoded.value)),
    }
}

fn value_to_compact_string(value: &serde_json::Value) -> String {
    if let Some(s) = value.as_str() {
        return s.to_string();
    }
    value.to_string()
}

// ---------------------------------------------------------------------------
// indexmap-compat: drop-in tiny replacement
// ---------------------------------------------------------------------------
//
// We need ordered insertion + first-time-seen semantics for the path /
// function tables.  Pulling in `indexmap` would double the dependency
// graph for two trivial helpers — implement them inline.

mod indexmap_compat {
    use std::collections::HashMap;
    use std::hash::Hash;

    /// Tiny ordered-insertion set: tracks first insertion order and
    /// reports whether a value was newly inserted.
    pub struct OrderedSet<T: Hash + Eq + Clone> {
        index: HashMap<T, usize>,
        order: Vec<T>,
    }

    impl<T: Hash + Eq + Clone> OrderedSet<T> {
        pub fn new() -> Self {
            Self {
                index: HashMap::new(),
                order: Vec::new(),
            }
        }

        /// Insert `value` if unseen; return `(idx, inserted)`.
        pub fn insert_full(&mut self, value: T) -> (usize, bool) {
            if let Some(&idx) = self.index.get(&value) {
                return (idx, false);
            }
            let idx = self.order.len();
            self.order.push(value.clone());
            self.index.insert(value, idx);
            (idx, true)
        }
    }

    /// Tiny ordered-insertion map keyed by `K`.
    pub struct OrderedMap<K: Hash + Eq + Clone, V> {
        map: HashMap<K, V>,
        order: Vec<K>,
    }

    impl<K: Hash + Eq + Clone, V> OrderedMap<K, V> {
        pub fn new() -> Self {
            Self {
                map: HashMap::new(),
                order: Vec::new(),
            }
        }

        pub fn len(&self) -> usize {
            self.order.len()
        }

        /// Mimics `HashMap::entry(...).or_insert_with(...)` while
        /// preserving insertion order.  Returns a mutable reference to
        /// the value (whether existing or newly inserted).
        pub fn entry<F: FnOnce() -> V>(&mut self, key: K) -> EntryRef<'_, K, V, F> {
            EntryRef {
                map: &mut self.map,
                order: &mut self.order,
                key,
                _f: std::marker::PhantomData,
            }
        }
    }

    pub struct EntryRef<'a, K: Hash + Eq + Clone, V, F: FnOnce() -> V> {
        map: &'a mut HashMap<K, V>,
        order: &'a mut Vec<K>,
        key: K,
        _f: std::marker::PhantomData<F>,
    }

    impl<'a, K: Hash + Eq + Clone, V, F: FnOnce() -> V> EntryRef<'a, K, V, F> {
        pub fn or_insert_with(self, default: F) -> &'a mut V {
            if !self.map.contains_key(&self.key) {
                self.order.push(self.key.clone());
                self.map.insert(self.key.clone(), default());
            }
            self.map.get_mut(&self.key).expect("just inserted")
        }
    }
}

// The recording's function id for one runtime `fnId`.
#[derive(Debug, Clone)]
struct FunctionRecordOnDisk {
    function_id: u32,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Recordings produced from the current tree for the tests below.
///
/// The demo recordings this crate's tests read are no longer committed:
/// they were written by *this* code, so a committed copy could only ever
/// confirm that the writer still agrees with its own past output, and
/// would keep confirming it after the writer changed. See
/// `scripts/materialize-recording.sh` for the cache and its key.
#[cfg(test)]
mod tests_support {
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::{Mutex, OnceLock};

    /// Files that identify a directory as the CodeTracer checkout rather
    /// than as whatever else happens to sit two levels above this crate.
    ///
    /// The materialiser is the one the tests below actually invoke; the
    /// manifest is there so a directory that merely carried a similarly
    /// named script could not pass for the repository.
    pub const REPO_ROOT_MARKERS: [&str; 2] = [
        "scripts/materialize-recording.sh",
        "src/backend-manager/Cargo.toml",
    ];

    /// The CodeTracer checkout that owns `manifest_dir`, or an
    /// explanation of why `manifest_dir` does not sit inside one.
    ///
    /// # Why this is a verified lookup rather than `join("../..")`
    ///
    /// It used to be exactly that join, followed by `canonicalize()` and
    /// nothing else, and the result was fed straight to `Command::new`.
    /// Two levels up from the crate directory is the repository root only
    /// when the crate is being tested *inside a checkout*. It is not when
    /// the crate is the whole source tree, which is precisely the shape
    /// `pkgs.rustPlatform.buildRustPackage` gives it: `nix/packages/default.nix`
    /// passes `src = ../../src/backend-manager`, so the sandbox unpacks the
    /// crate to `/build/source`, `../..` canonicalises to `/`, and the test
    /// reported
    ///
    /// ```text
    /// could not run /scripts/materialize-recording.sh: No such file or directory
    /// ```
    ///
    /// which reads as a missing file rather than as "this build has no
    /// repository" — and cost the campaign a diagnosis. It is also unsafe
    /// in the other direction: had *any* `scripts/materialize-recording.sh`
    /// existed at the misresolved root, the tests would have silently
    /// executed it and believed the recordings it printed.
    ///
    /// So the root is now *verified*, and the error names the crate
    /// directory, the directory that was derived from it, and the marker
    /// that was absent.
    pub fn locate_repo_root(manifest_dir: &Path) -> Result<PathBuf, String> {
        let candidate = manifest_dir.join("../..");
        let root = candidate.canonicalize().map_err(|e| {
            format!(
                "the CodeTracer repository root should be two directories above the \
                 backend-manager crate ({}), but {} could not be resolved: {e}",
                manifest_dir.display(),
                candidate.display(),
            )
        })?;
        for marker in REPO_ROOT_MARKERS {
            if !root.join(marker).exists() {
                return Err(format!(
                    "{} is not a CodeTracer checkout: it has no {marker}.\n\
                     It was derived as two directories above the backend-manager \
                     crate ({}).\n\
                     These tests record their fixtures from the repository, so they \
                     need the repository — a build whose source is the crate alone \
                     (for example the `backend-manager` Nix derivation, whose src is \
                     `src/backend-manager`) cannot run them, and must not run them \
                     against whatever else is at that path.",
                    root.display(),
                    manifest_dir.display(),
                ));
            }
        }
        Ok(root)
    }

    /// Absolute path of a directory holding `frontend.ct`,
    /// `frontend-wasm.ct` and `backend.ct`, recording them first if this
    /// tree has not produced them yet.
    ///
    /// Panics — never returns an "unavailable" the caller could turn
    /// into a skip — if the pipeline cannot run. A framing test with no
    /// real records to frame has nothing to say.
    pub fn materialized_three_trace_recordings() -> PathBuf {
        static CACHE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
        let cache = CACHE.get_or_init(|| Mutex::new(None));
        let mut guard = cache.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(path) = guard.as_ref() {
            return path.clone();
        }

        let repo_root = locate_repo_root(Path::new(env!("CARGO_MANIFEST_DIR")))
            .unwrap_or_else(|reason| panic!("{reason}"));
        let script = repo_root.join("scripts/materialize-recording.sh");
        let output = Command::new(&script)
            .arg("cross-process-three-trace")
            .current_dir(&repo_root)
            .stderr(Stdio::inherit())
            .output()
            .unwrap_or_else(|e| panic!("could not run {}: {e}", script.display()));
        assert!(
            output.status.success(),
            "could not record the cross-process demo from this tree ({}); the \
             diagnostic above says what is missing",
            output.status
        );
        let path = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        assert!(
            path.is_dir(),
            "materialiser reported a non-directory: {}",
            path.display()
        );
        *guard = Some(path.clone());
        path
    }
}

/// Contracts for [`tests_support::locate_repo_root`].
///
/// These need nothing but a temporary directory, so unlike the recording
/// tests they run in *every* lane that compiles this crate — including the
/// `backend-manager` Nix derivation, whose sandbox is exactly the
/// environment the misresolution used to go unnoticed in.
#[cfg(test)]
mod repo_root_tests {
    use super::tests_support::{REPO_ROOT_MARKERS, locate_repo_root};
    use tempfile::TempDir;

    /// Build `<tmp>/src/backend-manager` and whichever markers are asked
    /// for, and return the tempdir plus that crate directory.
    fn checkout_with(markers: &[&str]) -> (TempDir, std::path::PathBuf) {
        let tmp = TempDir::new().expect("create tempdir");
        let crate_dir = tmp.path().join("src/backend-manager");
        std::fs::create_dir_all(&crate_dir).unwrap();
        for marker in markers {
            let path = tmp.path().join(marker);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"").unwrap();
        }
        (tmp, crate_dir)
    }

    #[test]
    fn a_real_checkout_resolves_to_its_root() {
        let (tmp, crate_dir) = checkout_with(&REPO_ROOT_MARKERS);
        let root = locate_repo_root(&crate_dir).expect("a marked checkout must resolve");
        assert_eq!(
            root,
            tmp.path().canonicalize().unwrap(),
            "the root two levels above the crate is the checkout"
        );
    }

    /// The regression: a crate built as its own source tree.
    ///
    /// `../..` from `<tmp>/src/backend-manager` is `<tmp>`, which exists
    /// and canonicalises fine — so the old code accepted it and went on to
    /// run `<tmp>/scripts/materialize-recording.sh`. The failure must name
    /// what is missing, not merely fail to spawn a file.
    #[test]
    fn a_directory_that_is_not_a_checkout_is_refused_by_name() {
        let (_tmp, crate_dir) = checkout_with(&[]);
        let err = locate_repo_root(&crate_dir)
            .expect_err("a directory with no CodeTracer markers must not pass as the repo root");
        assert!(
            err.contains("scripts/materialize-recording.sh"),
            "the diagnostic must name the missing marker; got: {err}"
        );
        assert!(
            err.contains("is not a CodeTracer checkout"),
            "the diagnostic must say what the directory failed to be; got: {err}"
        );
        assert!(
            err.contains(&crate_dir.display().to_string()),
            "the diagnostic must name the crate directory it started from; got: {err}"
        );
    }

    /// A lookalike is not a checkout.
    ///
    /// Every marker is required, so a directory that merely happens to
    /// carry a `scripts/materialize-recording.sh` cannot be mistaken for
    /// the repository and have that script executed.
    #[test]
    fn one_marker_is_not_enough_to_pass_for_a_checkout() {
        let (_tmp, crate_dir) = checkout_with(&["scripts/materialize-recording.sh"]);
        let err = locate_repo_root(&crate_dir)
            .expect_err("a partially marked directory must not pass as the repo root");
        assert!(
            err.contains("src/backend-manager/Cargo.toml"),
            "the diagnostic must name the marker that was missing; got: {err}"
        );
    }

    /// A path that does not exist is a returned error, not a panic inside
    /// the resolver: the caller owns the message.
    #[test]
    fn an_unresolvable_path_is_reported_rather_than_unwrapped() {
        let (tmp, _crate_dir) = checkout_with(&REPO_ROOT_MARKERS);
        let absent = tmp.path().join("no/such/crate/dir");
        let err = locate_repo_root(&absent).expect_err("a non-existent crate dir cannot resolve");
        assert!(
            err.contains("could not be resolved"),
            "the diagnostic must distinguish an unresolvable path from an unmarked \
             one; got: {err}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::boundary_log::{Record, Value};
    use crate::browser_stream_receiver::{BrowserEvent, EncodedValue};
    use std::path::Path;
    use std::time::Duration;
    use tempfile::TempDir;

    /// A boundary log decoded for assertions: its records, and whether it
    /// ended with `End` (complete) or simply stopped (unterminated).
    ///
    /// CodeTracer has no CTBL reader — the only product decoder is
    /// `codetracer-wasm-recorder/internal/boundarylog`. This one exists so
    /// the tests here can state what the writer emitted in terms of
    /// records rather than bytes; the byte layout itself is pinned by
    /// `boundary_log::tests`.
    pub(super) struct DecodedLog {
        pub records: Vec<Record>,
        pub complete: bool,
        /// Bytes after the last whole frame. Non-zero means the stream was
        /// torn mid-frame.
        pub torn_bytes: usize,
    }

    pub(super) fn decode_log(bytes: &[u8]) -> DecodedLog {
        assert!(bytes.len() >= 5, "shorter than the CTBL prefix: {bytes:?}");
        assert_eq!(&bytes[..4], b"CTBL", "missing magic");
        assert_eq!(bytes[4], 1, "unexpected version");
        let mut pos = 5;
        let mut records = Vec::new();
        let mut complete = false;
        while pos + 4 <= bytes.len() {
            let len = u32::from_le_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
            if pos + 4 + len > bytes.len() {
                break;
            }
            let mut r = Cursor {
                b: &bytes[pos + 4..pos + 4 + len],
                i: 0,
            };
            let record = r.record();
            assert_eq!(r.i, len, "a frame must be consumed exactly");
            pos += 4 + len;
            if record == Record::End {
                complete = true;
                assert_eq!(pos, bytes.len(), "nothing may follow End");
            }
            records.push(record);
        }
        DecodedLog {
            records,
            complete,
            torn_bytes: bytes.len() - pos,
        }
    }

    struct Cursor<'a> {
        b: &'a [u8],
        i: usize,
    }

    impl Cursor<'_> {
        fn u8(&mut self) -> u8 {
            self.i += 1;
            self.b[self.i - 1]
        }
        fn u32(&mut self) -> u32 {
            self.i += 4;
            u32::from_le_bytes(self.b[self.i - 4..self.i].try_into().unwrap())
        }
        fn i32(&mut self) -> i32 {
            self.i += 4;
            i32::from_le_bytes(self.b[self.i - 4..self.i].try_into().unwrap())
        }
        fn i64(&mut self) -> i64 {
            self.i += 8;
            i64::from_le_bytes(self.b[self.i - 8..self.i].try_into().unwrap())
        }
        fn str(&mut self) -> String {
            let n = self.u32() as usize;
            self.i += n;
            String::from_utf8(self.b[self.i - n..self.i].to_vec()).unwrap()
        }
        fn value(&mut self) -> Value {
            match self.u8() {
                1 => Value::Int(self.str()),
                2 => Value::Float(self.str()),
                3 => Value::Bool(self.u8() != 0),
                4 => Value::String(self.str()),
                5 => Value::Raw(self.str()),
                6 => Value::None,
                other => panic!("unknown vtag {other}"),
            }
        }
        fn record(&mut self) -> Record {
            match self.u8() {
                1 => {
                    let program = self.str();
                    let argc = self.u32();
                    let args = (0..argc).map(|_| self.str()).collect();
                    Record::Header {
                        program,
                        args,
                        workdir: self.str(),
                        recorder_name: self.str(),
                        recorder_version: self.str(),
                    }
                }
                2 => Record::Path(self.str()),
                3 => Record::Function {
                    name: self.str(),
                    path_id: self.u32(),
                    line: self.i64(),
                },
                4 => Record::Step {
                    path_id: self.u32(),
                    line: self.i64(),
                },
                5 => {
                    let function_id = self.u32();
                    let argc = self.u32();
                    let args = (0..argc).map(|_| (self.u32(), self.value())).collect();
                    Record::Call { function_id, args }
                }
                6 => Record::Return(self.value()),
                7 => Record::Value {
                    variable_id: self.u32(),
                    value: self.value(),
                },
                8 => Record::VariableName(self.str()),
                9 => Record::Event {
                    kind: self.i32(),
                    metadata: self.str(),
                    content: self.str(),
                },
                10 => Record::End,
                other => panic!("unknown tag {other}"),
            }
        }
    }

    /// The `boundary.log` stored inside a finished `.ct`.
    pub(super) fn stored_boundary_log(ct: &Path) -> Vec<u8> {
        let mut reader = codetracer_ctfs::CtfsReader::open(ct)
            .unwrap_or_else(|e| panic!("open {} as CTFS: {e:?}", ct.display()));
        reader
            .read_file(boundary_log::INTERNAL_FILE_NAME)
            .unwrap_or_else(|e| panic!("{} has no boundary.log: {e:?}", ct.display()))
    }

    /// The recording's events, read back with the trace-format reader the
    /// way any CTFS consumer reads them.
    fn recorded_events(ct: &Path) -> Vec<codetracer_trace_types::TraceLowLevelEvent> {
        codetracer_trace_reader::ctfs_reader::read_trace_from_ctfs(ct)
            .unwrap_or_else(|e| panic!("read {} as a CTFS recording: {e}", ct.display()))
    }

    fn writer_in(tmp: &TempDir) -> CtfsRecordingWriter {
        CtfsRecordingWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf())
    }

    /// Everything in `dir` except the (hidden) partial-recordings directory.
    fn visible_entries(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n != PARTIAL_DIR_NAME)
            .collect();
        names.sort();
        names
    }

    /// The record sequence most tests below run on.
    ///
    /// It is deliberately the widest one available: a forwarded manifest
    /// (so `Step` / `Assignment` / `Call` resolve to real
    /// `Path` + `Function` records rather than the `<browser>` fallback),
    /// every `BrowserEvent` variant that produces a record, and every
    /// value arm — `Int`, `Float`, `Bool`, `String`, `None` and the `Raw`
    /// fallback.
    fn wide_event_sequence() -> Vec<BrowserEvent> {
        let manifest = serde_json::json!({
            "paths": ["src/app.js", "src/util.js"],
            "functions": [
                {"name": "renderBalance", "pathIndex": 0, "line": 12},
                {"name": "formatCents", "pathIndex": 1, "line": 3},
            ],
            "sites": [
                {"pathIndex": 0, "line": 13, "target": "total"},
                {"pathIndex": 1, "line": 4, "target": "cents"},
                {"pathIndex": 0, "line": 20},
                {"pathIndex": 1, "line": 7, "target": "label"},
            ],
        });
        let value = |json: serde_json::Value, kind: &str| EncodedValue {
            value: json,
            type_kind: kind.to_string(),
        };
        vec![
            BrowserEvent::SessionStart {
                program: "frontend".to_string(),
                args: vec!["--demo".to_string()],
            },
            BrowserEvent::Manifest { manifest },
            // An explicit Path event: interned through our own table.
            BrowserEvent::Path {
                path_id: 7,
                path: "src/vendor.js".to_string(),
            },
            BrowserEvent::Step { site_id: 2 },
            // First Call mints a Function record before the Call.
            BrowserEvent::Call {
                fn_id: 0,
                args: vec![value(serde_json::json!(42), "Int")],
            },
            BrowserEvent::Assignment {
                site_id: 0,
                value: Some(value(serde_json::json!("1234"), "Int")),
            },
            BrowserEvent::Call {
                fn_id: 1,
                args: vec![
                    value(serde_json::json!(1.5), "Float"),
                    value(serde_json::json!(true), "Bool"),
                ],
            },
            BrowserEvent::Assignment {
                site_id: 1,
                value: Some(value(serde_json::json!(7), "Int")),
            },
            BrowserEvent::Return {
                fn_id: 1,
                return_value: value(serde_json::json!("12.34"), "String"),
            },
            // A site with no `target` in the manifest: a Step, no Value.
            BrowserEvent::Assignment {
                site_id: 2,
                value: Some(value(serde_json::json!(0), "Int")),
            },
            // The Raw fallback — a compound payload, stringified verbatim.
            BrowserEvent::Value {
                name: "rows".to_string(),
                value: value(serde_json::json!({"a": [1, 2], "b": "x\"y"}), "Object"),
            },
            BrowserEvent::Value {
                name: "missing".to_string(),
                value: value(serde_json::Value::Null, "None"),
            },
            // A repeat of an already-interned variable: no second
            // VariableName record, so the positional table stays stable.
            BrowserEvent::Value {
                name: "rows".to_string(),
                value: value(serde_json::json!(3), "Int"),
            },
            BrowserEvent::Write {
                channel: "stdout".to_string(),
                content: "balance: 12.34\n".to_string(),
            },
            BrowserEvent::CorrelationMarker {
                direction: crate::browser_stream_receiver::MarkerDirection::Send,
                boundary: "http:/api/balance".to_string(),
                key: serde_json::json!("user-42"),
                payload: Some(serde_json::json!(1234)),
                show_text: Some("total".to_string()),
            },
            BrowserEvent::CorrelationMarker {
                direction: crate::browser_stream_receiver::MarkerDirection::Recv,
                boundary: "http:/api/balance".to_string(),
                key: serde_json::json!(42),
                payload: None,
                show_text: None,
            },
            // A second Call on an already-registered fnId: resolves to the
            // existing function, emits no second Function record.
            BrowserEvent::Call {
                fn_id: 0,
                args: vec![],
            },
            BrowserEvent::Return {
                fn_id: 0,
                return_value: value(serde_json::Value::Null, "None"),
            },
            BrowserEvent::Step { site_id: 3 },
            BrowserEvent::SessionEnd {},
        ]
    }

    /// Drive `events` through a writer, returning the `.ct` path if the
    /// sequence ended the session.  `SessionStart` / `Manifest` /
    /// `SessionEnd` are dispatched to the lifecycle methods exactly as
    /// `StreamReceiver` does.
    fn drive(writer: &mut CtfsRecordingWriter, events: &[BrowserEvent]) -> Option<PathBuf> {
        let mut out = None;
        for event in events {
            match event {
                BrowserEvent::SessionStart { program, args } => {
                    writer.session_start(program, args).unwrap();
                }
                BrowserEvent::Manifest { manifest } => {
                    writer.manifest(manifest).unwrap();
                }
                BrowserEvent::SessionEnd {} => {
                    out = Some(writer.session_end().unwrap());
                }
                other => writer.event(other).unwrap(),
            }
        }
        out
    }

    /// A browser session lands as ONE file, `<program>.ct`, and nothing
    /// else: no `trace.json`, no `trace_metadata.json`, no
    /// `trace_paths.json`, no `boundary_state.json`.
    #[test]
    fn a_session_lands_as_one_ct_file_and_nothing_else() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        let ct = drive(&mut writer, &wide_event_sequence()).expect("the sequence ends the session");

        assert_eq!(ct, tmp.path().join("frontend.ct"));
        assert!(ct.is_file(), "a recording is a single CTFS file: {}", ct.display());
        assert_eq!(visible_entries(tmp.path()), vec!["frontend.ct".to_string()]);
        let partial = tmp.path().join(PARTIAL_DIR_NAME);
        assert!(
            !partial.exists() || std::fs::read_dir(&partial).unwrap().next().is_none(),
            "a finished recording leaves nothing behind in {}",
            partial.display(),
        );
    }

    /// The `.ct` is a recording any CTFS reader opens, carrying the
    /// translated records with their real values and types.
    #[test]
    fn the_recording_reads_back_through_the_trace_format_reader() {
        use codetracer_trace_types::TraceLowLevelEvent as E;
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        let ct = drive(&mut writer, &wide_event_sequence()).unwrap();
        let events = recorded_events(&ct);

        let count = |pred: &dyn Fn(&E) -> bool| events.iter().filter(|e| pred(e)).count();
        assert_eq!(count(&|e| matches!(e, E::Step(_))), 5, "{events:#?}");
        assert_eq!(count(&|e| matches!(e, E::Call(_))), 3, "{events:#?}");
        let returned: Vec<&ValueRecord> = events
            .iter()
            .filter_map(|e| match e {
                E::Return(r) => Some(&r.return_value),
                _ => None,
            })
            .collect();
        assert!(
            matches!(returned.first(), Some(ValueRecord::String { text, .. }) if text == "12.34"),
            "the first recorded return carries its value: {returned:#?}",
        );
        assert_eq!(count(&|e| matches!(e, E::Value(_))), 5, "{events:#?}");

        let functions: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                E::Function(f) => Some(f.name.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(functions, vec!["renderBalance", "formatCents"]);

        let paths: Vec<String> = events
            .iter()
            .filter_map(|e| match e {
                E::Path(p) => Some(p.to_string_lossy().into_owned()),
                _ => None,
            })
            .collect();
        assert_eq!(paths, vec!["src/vendor.js", "src/app.js", "src/util.js"]);

        let ints: Vec<i64> = events
            .iter()
            .filter_map(|e| match e {
                E::Value(v) => match v.value {
                    ValueRecord::Int { i, .. } => Some(i),
                    _ => None,
                },
                _ => None,
            })
            .collect();
        assert_eq!(ints, vec![1234, 7, 3], "integers are recorded as integers");

        assert!(
            events.iter().any(|e| matches!(e, E::Event(ev)
                if ev.content == "balance: 12.34\n" && matches!(ev.kind, EventLogKind::Write))),
            "the page's output is recorded: {events:#?}",
        );
    }

    /// `boundary.log` inside the container is the record sequence, in
    /// order, with the tables positional — the replaying recorder
    /// resolves `path_id`, `function_id` and `variable_id` by index, so a
    /// renumbering would silently attribute every value to the wrong name.
    #[test]
    fn the_boundary_log_carries_the_record_sequence_in_order() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        let ct = drive(&mut writer, &wide_event_sequence()).unwrap();
        let log = decode_log(&stored_boundary_log(&ct));
        assert!(log.complete, "a finished recording's log ends with End");
        assert_eq!(log.torn_bytes, 0);

        let mut records = log.records.into_iter();
        assert_eq!(
            records.next().unwrap(),
            Record::Header {
                program: "frontend".into(),
                args: vec!["--demo".into()],
                workdir: tmp.path().to_string_lossy().into_owned(),
                recorder_name: "codetracer-js-recorder-browser".into(),
                recorder_version: env!("CARGO_PKG_VERSION").into(),
            }
        );
        let records: Vec<Record> = records.collect();
        let (markers, rest): (Vec<Record>, Vec<Record>) = records
            .into_iter()
            .partition(|r| matches!(r, Record::Event { kind: 12, .. }));
        assert_eq!(markers.len(), 2, "one Event per correlation marker");
        for marker in &markers {
            let Record::Event { metadata, .. } = marker else {
                unreachable!()
            };
            let doc: serde_json::Value = serde_json::from_str(metadata).unwrap();
            assert_eq!(doc["boundary_id"], "http:/api/balance");
        }
        let int = |s: &str| Value::Int(s.into());
        assert_eq!(
            rest,
            vec![
                Record::Path("src/vendor.js".into()),
                Record::Path("src/app.js".into()),
                Record::Step { path_id: 1, line: 20 },
                Record::Function {
                    name: "renderBalance".into(),
                    path_id: 1,
                    line: 12,
                },
                Record::Call {
                    function_id: 0,
                    args: vec![(0, int("42"))],
                },
                Record::Step { path_id: 1, line: 13 },
                Record::VariableName("total".into()),
                Record::Value {
                    variable_id: 0,
                    value: int("1234"),
                },
                Record::Path("src/util.js".into()),
                Record::Function {
                    name: "formatCents".into(),
                    path_id: 2,
                    line: 3,
                },
                Record::Call {
                    function_id: 1,
                    args: vec![(0, Value::Float("1.5".into())), (1, Value::Bool(true))],
                },
                Record::Step { path_id: 2, line: 4 },
                Record::VariableName("cents".into()),
                Record::Value {
                    variable_id: 1,
                    value: int("7"),
                },
                Record::Return(Value::String("12.34".into())),
                Record::Step { path_id: 1, line: 20 },
                Record::VariableName("rows".into()),
                Record::Value {
                    variable_id: 2,
                    value: Value::Raw(r#"{"a":[1,2],"b":"x\"y"}"#.into()),
                },
                Record::VariableName("missing".into()),
                Record::Value {
                    variable_id: 3,
                    value: Value::None,
                },
                Record::Value {
                    variable_id: 2,
                    value: int("3"),
                },
                Record::Event {
                    kind: 0,
                    metadata: "stdout".into(),
                    content: "balance: 12.34\n".into(),
                },
                Record::Call {
                    function_id: 0,
                    args: vec![],
                },
                Record::Return(Value::None),
                Record::Step { path_id: 2, line: 7 },
                Record::End,
            ]
        );
    }

    /// A value that does not fit its CTFS type keeps the producer's exact
    /// text: as `Raw` in the recording, as the original kind in the
    /// boundary log.  A JS `BigInt` past `i64` and a NaN-payload spelling
    /// are the two shapes that occur.
    #[test]
    fn values_that_do_not_fit_their_type_are_recorded_exactly() {
        use codetracer_trace_types::TraceLowLevelEvent as E;
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        writer.session_start("wide", &[]).unwrap();
        // A value is attached to the step it was observed at.
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let big = "123456789012345678901234567890";
        let nan = "NaN:0x7ff4000000000001";
        for (name, text, kind) in [("big", big, "Int"), ("nan", nan, "Float")] {
            writer
                .event(&BrowserEvent::Value {
                    name: name.into(),
                    value: EncodedValue {
                        value: serde_json::json!(text),
                        type_kind: kind.into(),
                    },
                })
                .unwrap();
        }
        let ct = writer.session_end().unwrap();

        let raws: Vec<String> = recorded_events(&ct)
            .into_iter()
            .filter_map(|e| match e {
                E::Value(v) => match v.value {
                    ValueRecord::Raw { r, .. } => Some(r),
                    _ => None,
                },
                _ => None,
            })
            .collect();
        assert_eq!(raws, vec![big.to_string(), nan.to_string()]);

        let logged: Vec<Value> = decode_log(&stored_boundary_log(&ct))
            .records
            .into_iter()
            .filter_map(|r| match r {
                Record::Value { value, .. } => Some(value),
                _ => None,
            })
            .collect();
        assert_eq!(
            logged,
            vec![Value::Int(big.into()), Value::Float(nan.into())]
        );
    }

    #[test]
    fn a_second_session_end_is_a_no_op() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        writer.session_start("twice", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let first = writer.session_end().unwrap();
        let bytes = std::fs::read(&first).unwrap();
        let second = writer.session_end().unwrap();
        assert_eq!(first, second);
        assert_eq!(std::fs::read(&second).unwrap(), bytes);
        // A record after the end has nowhere to go and changes nothing.
        writer.event(&BrowserEvent::Step { site_id: 1 }).unwrap();
        assert_eq!(std::fs::read(&second).unwrap(), bytes);
    }

    /// A session that ends without a single record still lands a complete
    /// recording, rather than nothing a user could open.
    #[test]
    fn an_empty_session_still_lands_a_recording() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        writer.session_start("empty", &[]).unwrap();
        let ct = writer.session_end().unwrap();
        recorded_events(&ct);
        let log = decode_log(&stored_boundary_log(&ct));
        assert!(log.complete);
        assert!(matches!(log.records[0], Record::Header { .. }));
        assert_eq!(log.records.len(), 2, "Header and End only");
    }

    /// Until the session ends there is no `<program>.ct` in the output
    /// directory — a reader can never open a half-written recording.
    #[test]
    fn the_recording_appears_only_when_the_session_ends() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer = writer_in(&tmp);
        writer.session_start("pending", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        assert!(
            visible_entries(tmp.path()).is_empty(),
            "mid-session the output directory shows nothing: {:?}",
            visible_entries(tmp.path()),
        );
        assert!(tmp.path().join(PARTIAL_DIR_NAME).join("pending.ct").is_file());
        writer.session_end().unwrap();
        assert_eq!(visible_entries(tmp.path()), vec!["pending.ct".to_string()]);
    }

    /// A consumer that writes stdin to `sink`, and records the argument it
    /// was given in `arg` — so a test can check the `{trace}` substitution
    /// too.
    fn cat_consumer(sink: &Path, arg: &Path) -> StreamConsumerConfig {
        StreamConsumerConfig {
            command: vec![
                "sh".to_string(),
                "-c".to_string(),
                format!(
                    "printf '%s' \"$0\" > '{}' && exec cat > '{}'",
                    arg.display(),
                    sink.display()
                ),
                TRACE_PLACEHOLDER.to_string(),
            ],
        }
    }

    fn wait_for_nonempty(path: &Path) -> Vec<u8> {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while std::time::Instant::now() < deadline {
            let bytes = std::fs::read(path).unwrap_or_default();
            if bytes.len() > 5 {
                return bytes;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        std::fs::read(path).unwrap_or_default()
    }

    /// The tee: a real spawned child receives the boundary log *during* the
    /// session, and at the end has exactly the bytes the container stores.
    ///
    /// The stand-in consumer is `sh -c 'cat > <file>'` rather than
    /// `wazero`: what the daemon owes the §2 consumer is the byte stream on
    /// stdin, live, and that is exactly what this measures.  The consumer's
    /// own half is pinned in `codetracer-wasm-recorder`.
    #[test]
    fn the_tee_feeds_a_real_child_process_during_the_session() {
        let tmp = TempDir::new().expect("create tempdir");
        let out = tmp.path().join("out");
        let sink = tmp.path().join("teed.ctbl");
        let arg = tmp.path().join("arg");
        let mut writer = CtfsRecordingWriter::with_stream_consumer(
            out.clone(),
            tmp.path().to_path_buf(),
            cat_consumer(&sink, &arg),
        );
        writer.session_start("teed", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();

        // Mid-session: the child already holds the header and the step.
        let teed = wait_for_nonempty(&sink);
        let live = decode_log(&teed);
        assert!(!live.complete, "the session is still open");
        assert_eq!(live.records.len(), 3, "Header, Path, Step: {:?}", live.records);
        assert!(!writer.session_ended);

        let ct = writer.session_end().unwrap();
        // `session_end` closes the pipe and reaps the child, so the sink is
        // complete by the time it returns.
        assert_eq!(
            std::fs::read(&sink).unwrap(),
            stored_boundary_log(&ct),
            "the consumer sees exactly the boundary log the recording stores",
        );
        assert_eq!(
            std::fs::read_to_string(&arg).unwrap(),
            ct.to_string_lossy(),
            "{{trace}} is the path the recording lands at",
        );
    }

    /// A page killed mid-session leaves the consumer a stream of whole
    /// frames with no `End` — unterminated, not torn — and leaves no
    /// recording in the output directory.
    #[test]
    fn a_killed_session_leaves_a_stream_the_consumer_can_classify() {
        let tmp = TempDir::new().expect("create tempdir");
        let out = tmp.path().join("out");
        let sink = tmp.path().join("teed.ctbl");
        let arg = tmp.path().join("arg");
        {
            let mut writer = CtfsRecordingWriter::with_stream_consumer(
                out.clone(),
                tmp.path().to_path_buf(),
                cat_consumer(&sink, &arg),
            );
            let truncated: Vec<BrowserEvent> = wide_event_sequence()
                .into_iter()
                .filter(|e| !matches!(e, BrowserEvent::SessionEnd {}))
                .collect();
            assert!(drive(&mut writer, &truncated).is_none());
            assert!(!writer.session_ended, "the session never ended cleanly");
            // Dropping the writer without `session_end` is the crash.
        }
        let log = decode_log(&std::fs::read(&sink).unwrap());
        assert!(!log.complete, "an interrupted stream must NOT look complete");
        assert_eq!(log.torn_bytes, 0, "every frame the consumer got is whole");
        assert!(log.records.len() > 10, "expected a substantial prefix");
        assert!(visible_entries(&out).is_empty(), "no recording for a killed session");
    }

    /// A consumer that cannot be spawned, or that dies early, costs seek
    /// performance and nothing else — the recording is complete and
    /// identical either way (spec §2: the recording is the source of truth,
    /// snapshots are derived data).
    #[test]
    fn a_broken_consumer_does_not_cost_the_recording() {
        // One workdir for every run, so the header frames agree.
        let workdir = PathBuf::from("/workdir");
        let reference = {
            let tmp = TempDir::new().expect("create tempdir");
            let mut writer = CtfsRecordingWriter::new(tmp.path().to_path_buf(), workdir.clone());
            let ct = drive(&mut writer, &wide_event_sequence()).unwrap();
            stored_boundary_log(&ct)
        };
        for command in [
            vec!["definitely-not-a-real-binary-38c".to_string()],
            // Exits immediately, so every write after the first hits a
            // closed pipe (EPIPE).
            vec!["sh".to_string(), "-c".to_string(), "exit 0".to_string()],
        ] {
            let tmp = TempDir::new().expect("create tempdir");
            let mut writer = CtfsRecordingWriter::with_stream_consumer(
                tmp.path().to_path_buf(),
                workdir.clone(),
                StreamConsumerConfig { command },
            );
            let ct = drive(&mut writer, &wide_event_sequence()).expect("session ends");
            recorded_events(&ct);
            assert_eq!(stored_boundary_log(&ct), reference);
        }
    }

    /// `{trace_dir}` named the recording DIRECTORY.  Substituting a file
    /// path into an argument written for a directory would hand the
    /// consumer `<program>.ct/slices`, a path inside a file — so it is
    /// refused up front, naming the replacement.
    #[test]
    fn the_retired_trace_dir_placeholder_is_refused() {
        let config = StreamConsumerConfig {
            command: vec![
                "wazero".to_string(),
                "--slice-dir".to_string(),
                "{trace_dir}/slices".to_string(),
            ],
        };
        let err = config.validate().unwrap_err();
        assert!(err.contains("{trace_dir}") && err.contains("{trace}"), "{err}");
        assert!(StreamConsumerConfig::default().validate().is_ok());
    }

    /// Recordings produced by the real browser pipeline from this tree:
    /// both browser-side recordings of the three-trace demo are single
    /// `.ct` files whose boundary log is complete and whose events read
    /// back.
    ///
    /// The recordings are produced rather than committed: a committed one
    /// was made by an earlier version of the writer under test, and would
    /// go on passing after the writer changed.
    #[test]
    fn a_real_browser_recording_is_a_ct_with_a_complete_boundary_log() {
        let recordings = super::tests_support::materialized_three_trace_recordings();
        for fixture in ["frontend-wasm.ct", "frontend.ct"] {
            let ct = recordings.join(fixture);
            assert!(ct.is_file(), "{} must be a CTFS file", ct.display());
            let log = decode_log(&stored_boundary_log(&ct));
            assert!(log.complete, "{fixture}: the page ended its session cleanly");
            assert!(
                log.records.len() >= 15,
                "{fixture} should be a substantial recording; got {} records",
                log.records.len(),
            );
            let steps_logged = log
                .records
                .iter()
                .filter(|r| matches!(r, Record::Step { .. }))
                .count();
            let steps_recorded = recorded_events(&ct)
                .iter()
                .filter(|e| matches!(e, codetracer_trace_types::TraceLowLevelEvent::Step(_)))
                .count();
            assert_eq!(
                steps_logged, steps_recorded,
                "{fixture}: the boundary log and the recording carry the same steps",
            );
        }
    }

    /// End-to-end smoke: spin up the host, connect a real WebSocket
    /// client, ship a 5-event session, observe the `.ct` file on disk.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn smoke_end_to_end_records_five_events_to_ct_file() {
        use futures_util::SinkExt;

        let tmp = TempDir::new().expect("create tempdir");
        let config = BrowserStreamHostConfig {
            bind: "127.0.0.1:0".parse().unwrap(),
            out_dir: tmp.path().to_path_buf(),
            workdir: tmp.path().to_path_buf(),
            stream_consumer: StreamConsumerConfig::default(),
            // Not under test here, and a watchdog firing mid-handshake
            // would make this smoke test flaky for an unrelated reason.
            idle_timeout: None,
        };
        let host = BrowserStreamHost::new(config);
        let running = host.bind().await.expect("bind");
        let url = format!("ws://{}/ct-stream", running.local_addr);
        let (mut ws, _resp) = tokio_tungstenite::connect_async(&url)
            .await
            .expect("connect");
        let batch = [
            r#"{"kind":"SessionStart","program":"smoke","args":[]}"#,
            r#"{"kind":"Step","siteId":0}"#,
            r#"{"kind":"Value","name":"x","value":{"value":42,"typeKind":"Int"}}"#,
            r#"{"kind":"Step","siteId":1}"#,
            r#"{"kind":"Value","name":"y","value":{"value":100,"typeKind":"Int"}}"#,
            r#"{"kind":"Step","siteId":2}"#,
            r#"{"kind":"SessionEnd"}"#,
        ]
        .join("\n");
        ws.send(Message::Text(batch)).await.expect("send");
        ws.close(None).await.ok();
        // Allow the spawned connection handler to flush.
        tokio::time::sleep(Duration::from_millis(300)).await;
        running.stop().await.expect("stop");

        let ct = tmp.path().join("smoke.ct");
        assert!(
            ct.is_file(),
            "expected a recording at {ct:?}; entries: {:?}",
            visible_entries(tmp.path()),
        );
        use codetracer_trace_types::TraceLowLevelEvent as E;
        let events = recorded_events(&ct);
        assert_eq!(events.iter().filter(|e| matches!(e, E::Step(_))).count(), 3);
        assert_eq!(events.iter().filter(|e| matches!(e, E::Value(_))).count(), 2);
        let log = decode_log(&stored_boundary_log(&ct));
        assert!(matches!(&log.records[0], Record::Header { program, .. } if program == "smoke"));
    }
}

// ---------------------------------------------------------------------------
// Host-supplied state (spec §§3.3, 3.4)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod host_state_tests {
    use super::tests::{decode_log, stored_boundary_log};
    use super::*;
    use crate::boundary_log::Record;
    use crate::browser_stream_receiver::{
        BrowserEvent, GlobalSet, ImportedGlobalState, ImportedMemoryState, MemoryRegion,
        MemoryWrite, parse_event_line,
    };
    use tempfile::TempDir;

    /// The exact line `browser_session.js` puts on the wire for a §3.3
    /// record.  Parsed through the real `parse_event_line`, so the test
    /// pins the wire contract and not just this file's structs — a rename
    /// on either side breaks it.
    const INITIAL_LINE: &str = concat!(
        r#"{"kind":"HostInitialState","memories":[{"module":"env","name":"memory","#,
        r#""minPages":17,"maxPages":null,"data":[{"offset":1048576,"bytesB64":"BwAAAGQ="}]}],"#,
        r#""globals":[{"module":"env","name":"fee_bps","type":"i32","mutable":true,"value":"25"}]}"#
    );

    /// The exact line for a §3.4 record.
    const MUTATION_LINE: &str = concat!(
        r#"{"kind":"HostMutation","afterCrossing":1,"#,
        r#""memoryWrites":[{"module":"env","name":"memory","offset":1048584,"bytesB64":"+g=="}],"#,
        r#""globalSets":[{"module":"env","name":"fee_bps","type":"i32","value":"250"}]}"#
    );

    fn writer_in(tmp: &TempDir) -> CtfsRecordingWriter {
        CtfsRecordingWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf())
    }

    /// The host-state documents a finished recording's boundary log
    /// carries, in order.
    fn host_state_documents(ct: &std::path::Path) -> Vec<serde_json::Value> {
        decode_log(&stored_boundary_log(ct))
            .records
            .into_iter()
            .filter_map(|r| match r {
                Record::Event { metadata, .. } if metadata.contains(HOST_STATE_BOUNDARY_ID) => {
                    Some(serde_json::from_str(&metadata).unwrap())
                }
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_producers_wire_lines_deserialise_into_the_host_state_events() {
        match parse_event_line(INITIAL_LINE).expect("HostInitialState must parse") {
            BrowserEvent::HostInitialState { memories, globals } => {
                assert_eq!(
                    memories,
                    vec![ImportedMemoryState {
                        module: "env".to_string(),
                        name: "memory".to_string(),
                        min_pages: 17,
                        max_pages: None,
                        data: vec![MemoryRegion {
                            offset: 1_048_576,
                            bytes_b64: "BwAAAGQ=".to_string(),
                        }],
                    }]
                );
                assert_eq!(
                    globals,
                    vec![ImportedGlobalState {
                        module: "env".to_string(),
                        name: "fee_bps".to_string(),
                        value_type: "i32".to_string(),
                        mutable: true,
                        value: "25".to_string(),
                    }]
                );
            }
            other => panic!("wrong variant: {other:?}"),
        }
        match parse_event_line(MUTATION_LINE).expect("HostMutation must parse") {
            BrowserEvent::HostMutation {
                after_crossing,
                memory_writes,
                global_sets,
            } => {
                assert_eq!(after_crossing, 1);
                assert_eq!(
                    memory_writes,
                    vec![MemoryWrite {
                        module: "env".to_string(),
                        name: "memory".to_string(),
                        offset: 1_048_584,
                        bytes_b64: "+g==".to_string(),
                    }]
                );
                assert_eq!(
                    global_sets,
                    vec![GlobalSet {
                        module: "env".to_string(),
                        name: "fee_bps".to_string(),
                        value_type: "i32".to_string(),
                        value: "250".to_string(),
                    }]
                );
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    /// Host state rides in the record stream, one `Event` per message, in
    /// the consumer's schema (`hoststate.go`'s `InitialState` /
    /// `HostMutation`, field for field).  It is the only carrier: there is
    /// no sidecar file to fall out of step with it.
    #[test]
    fn host_state_rides_in_the_stream_in_the_consumers_schema() {
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        writer
            .event(&parse_event_line(INITIAL_LINE).unwrap())
            .unwrap();
        writer
            .event(&parse_event_line(MUTATION_LINE).unwrap())
            .unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let ct = writer.session_end().unwrap();

        let docs = host_state_documents(&ct);
        assert_eq!(docs.len(), 2, "one Event per host-state message");

        let initial = &docs[0];
        assert_eq!(initial["boundary_id"], HOST_STATE_BOUNDARY_ID);
        assert_eq!(initial["version"], HOST_STATE_VERSION);
        assert_eq!(initial["record"], HOST_STATE_RECORD_INITIAL);
        let mem = &initial["initial"]["memories"][0];
        assert_eq!(mem["module"], "env");
        assert_eq!(mem["name"], "memory");
        assert_eq!(mem["minPages"], 17);
        assert_eq!(mem["maxPages"], serde_json::Value::Null);
        assert_eq!(mem["data"][0]["offset"], 1_048_576);
        assert_eq!(mem["data"][0]["bytesB64"], "BwAAAGQ=");
        let g = &initial["initial"]["globals"][0];
        assert_eq!(g["type"], "i32");
        assert_eq!(g["mutable"], true);
        assert_eq!(g["value"], "25");
        assert_eq!(initial["initial"]["tables"], serde_json::json!([]));

        let mutation = &docs[1];
        assert_eq!(mutation["record"], HOST_STATE_RECORD_MUTATION);
        assert_eq!(mutation["mutation"]["afterCrossing"], 1);
        assert_eq!(mutation["mutation"]["memoryWrites"][0]["offset"], 1_048_584);
        assert_eq!(mutation["mutation"]["memoryWrites"][0]["bytesB64"], "+g==");
        assert_eq!(mutation["mutation"]["globalSets"][0]["value"], "250");

        let entries: Vec<_> = std::fs::read_dir(tmp.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n != PARTIAL_DIR_NAME)
            .collect();
        assert_eq!(entries, vec!["frontend-wasm.ct".to_string()], "no sidecar");
    }

    /// Host-state records join none of the positional tables: removing
    /// them leaves exactly the record sequence of the same session without
    /// host state.  `Function` / `VariableName` / `Path` are resolved by
    /// index downstream, so a record that renumbered them would silently
    /// break every lookup.
    #[test]
    fn host_state_records_disturb_nothing_else() {
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        writer
            .event(&parse_event_line(INITIAL_LINE).unwrap())
            .unwrap();
        writer
            .event(&parse_event_line(MUTATION_LINE).unwrap())
            .unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let with_state = decode_log(&stored_boundary_log(&writer.session_end().unwrap()));

        let tmp2 = TempDir::new().unwrap();
        let mut plain = writer_in(&tmp2);
        plain.session_start("frontend-wasm", &[]).unwrap();
        plain.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        plain.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let without_state = decode_log(&stored_boundary_log(&plain.session_end().unwrap()));

        let kept: Vec<Record> = with_state
            .records
            .into_iter()
            .filter(|r| !matches!(r, Record::Event { metadata, .. } if metadata.contains(HOST_STATE_BOUNDARY_ID)))
            .map(|r| match r {
                // The two sessions ran in different directories.
                Record::Header { .. } => Record::End,
                other => other,
            })
            .collect();
        let plain: Vec<Record> = without_state
            .records
            .into_iter()
            .map(|r| match r {
                Record::Header { .. } => Record::End,
                other => other,
            })
            .collect();
        assert_eq!(kept, plain);
    }

    #[test]
    fn a_recording_with_no_host_state_carries_no_host_state_records() {
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let ct = writer.session_end().unwrap();
        assert!(host_state_documents(&ct).is_empty());
    }

    #[test]
    fn mutations_keep_the_order_the_page_reported_them_in() {
        // `MutationsFor(seq)` selects by anchor, but two mutations
        // anchored to the same crossing are applied in stream order, so the
        // later write must win exactly as it did in the browser.
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        for seq in [3u32, 1, 3] {
            writer
                .event(&BrowserEvent::HostMutation {
                    after_crossing: seq,
                    memory_writes: vec![MemoryWrite {
                        module: "env".to_string(),
                        name: "memory".to_string(),
                        offset: seq,
                        bytes_b64: "AA==".to_string(),
                    }],
                    global_sets: vec![],
                })
                .unwrap();
        }
        let ct = writer.session_end().unwrap();
        let anchors: Vec<u64> = host_state_documents(&ct)
            .iter()
            .map(|m| m["mutation"]["afterCrossing"].as_u64().unwrap())
            .collect();
        assert_eq!(anchors, vec![3, 1, 3]);
    }

    #[test]
    fn a_second_initial_state_event_does_not_overwrite_the_first() {
        // §3.3 is the state before the FIRST exported call.  A second
        // record can only mean two recordings were spliced; keeping the
        // first is the only reading that stays true to the calls already
        // written.
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer
            .event(&parse_event_line(INITIAL_LINE).unwrap())
            .unwrap();
        writer
            .event(&BrowserEvent::HostInitialState {
                memories: vec![ImportedMemoryState {
                    module: "env".to_string(),
                    name: "memory".to_string(),
                    min_pages: 99,
                    max_pages: None,
                    data: vec![],
                }],
                globals: vec![],
            })
            .unwrap();
        let ct = writer.session_end().unwrap();
        let docs = host_state_documents(&ct);
        assert_eq!(docs.len(), 1);
        assert_eq!(docs[0]["initial"]["memories"][0]["minPages"], 17);
    }
}

/// Idle-watchdog tests.
///
/// These pin the property the watchdog exists for: a `record-web` host
/// must outlive its work but never outlive its usefulness.  Every caller
/// detaches it with `setsid(1)`, so when the launcher is `SIGKILL`ed there
/// is nothing left in the system able to reap it — the measured result was
/// 22 orphans on one machine, the oldest 47 hours old.  The host therefore
/// has to notice by itself.
///
/// No mocking: these bind a real listener on `127.0.0.1:0` and drive it
/// with a real WebSocket client, because the thing under test is precisely
/// the interaction between the accept loop and live connections.  Only the
/// timeout is scaled down, from ten minutes to a few hundred milliseconds.
#[cfg(test)]
mod idle_watchdog_tests {
    use super::*;
    use tempfile::TempDir;

    /// Short enough to keep the suite fast, long enough that a loaded CI
    /// machine does not trip the "stays alive" assertions spuriously.
    const TEST_IDLE: Duration = Duration::from_millis(400);

    fn config(tmp: &TempDir, idle_timeout: Option<Duration>) -> BrowserStreamHostConfig {
        BrowserStreamHostConfig {
            bind: "127.0.0.1:0".parse().unwrap(),
            out_dir: tmp.path().to_path_buf(),
            workdir: tmp.path().to_path_buf(),
            stream_consumer: StreamConsumerConfig::default(),
            idle_timeout,
        }
    }

    /// The leak, reproduced at the level of the daemon: the launcher dies
    /// without ever driving a page, and nothing connects.  The host must
    /// stand itself down.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_host_nobody_ever_connects_to_exits_by_itself() {
        let tmp = TempDir::new().expect("create tempdir");
        let host = BrowserStreamHost::new(config(&tmp, Some(TEST_IDLE)));
        let mut running = host.bind().await.expect("bind");

        tokio::time::timeout(TEST_IDLE * 8, running.idle_shutdown())
            .await
            .expect("an abandoned host must exit on its own, not run forever");
    }

    /// The property that makes the watchdog safe to enable by default: a
    /// recording in progress is never interrupted, however quiet it is.
    /// A page that connects and then computes for a long time without
    /// sending anything must not be mistaken for an abandoned daemon.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_connected_browser_keeps_the_host_alive_past_the_deadline() {
        let tmp = TempDir::new().expect("create tempdir");
        let host = BrowserStreamHost::new(config(&tmp, Some(TEST_IDLE)));
        let mut running = host.bind().await.expect("bind");
        let url = format!("ws://{}/ct-stream", running.local_addr);

        let (_ws, _resp) = tokio_tungstenite::connect_async(&url)
            .await
            .expect("connect");

        // Hold the socket open across several deadlines while sending
        // nothing at all.
        let verdict = tokio::time::timeout(TEST_IDLE * 4, running.idle_shutdown()).await;
        assert!(
            verdict.is_err(),
            "the host timed out while a browser was still connected — a long, \
             quiet recording would be killed mid-flight"
        );
    }

    /// Once the last browser has gone the clock starts again, so a host
    /// that finished its work and was then never signalled still exits.
    /// This is the shape a `SIGKILL`ed launcher leaves behind *after* a
    /// successful recording.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_host_exits_after_the_last_browser_disconnects() {
        let tmp = TempDir::new().expect("create tempdir");
        let host = BrowserStreamHost::new(config(&tmp, Some(TEST_IDLE)));
        let mut running = host.bind().await.expect("bind");
        let url = format!("ws://{}/ct-stream", running.local_addr);

        {
            let (ws, _resp) = tokio_tungstenite::connect_async(&url)
                .await
                .expect("connect");
            drop(ws);
        }

        tokio::time::timeout(TEST_IDLE * 8, running.idle_shutdown())
            .await
            .expect("the host must exit once its last browser has disconnected");
    }

    /// `--idle-timeout off` genuinely disables the watchdog, so a human
    /// supervising a host by hand is not stood down underneath them.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_disabled_watchdog_never_fires() {
        let tmp = TempDir::new().expect("create tempdir");
        let host = BrowserStreamHost::new(config(&tmp, None));
        let mut running = host.bind().await.expect("bind");

        let verdict = tokio::time::timeout(TEST_IDLE * 4, running.idle_shutdown()).await;
        assert!(
            verdict.is_err(),
            "a host configured with no idle timeout must never stand itself down"
        );
    }

    /// The counter has to survive a connection ending abnormally, or one
    /// failed handshake would pin it above zero and silently disable the
    /// watchdog for the life of the process — reintroducing the leak in a
    /// form that looks like the fix is present.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_connection_that_never_completes_the_handshake_still_releases_its_slot() {
        let tmp = TempDir::new().expect("create tempdir");
        let host = BrowserStreamHost::new(config(&tmp, Some(TEST_IDLE)));
        let mut running = host.bind().await.expect("bind");

        // A raw TCP connect that never speaks WebSocket: `accept_async`
        // fails, so `handle_connection` returns `Err`.
        {
            let stream = tokio::net::TcpStream::connect(running.local_addr)
                .await
                .expect("tcp connect");
            drop(stream);
        }

        tokio::time::timeout(TEST_IDLE * 8, running.idle_shutdown())
            .await
            .expect("a failed handshake must not leak a connection slot");
    }
}
