//! M26 — browser-recorder receiver **host process**.
//!
//! Companion of [`crate::browser_stream_receiver`]: that module owns the
//! JSON event vocabulary, the line parser, and the [`CtfsWriter`] trait
//! used by the unit tests; this module owns the **runnable** half — a
//! tokio + `tokio-tungstenite` WebSocket server that listens on
//! `ws://<host>:<port>/ct-stream`, accepts one connection per browser tab,
//! dispatches each received text frame's newline-delimited JSON events to
//! a per-connection [`StreamReceiver`], and persists the resulting trace
//! to disk under a user-chosen output directory.
//!
//! # Wire format
//!
//! The browser side
//! ([`codetracer-js-recorder/packages/runtime-browser/src/index.ts`])
//! batches `BrowserEvent`s and ships them over WebSocket as
//! newline-delimited JSON, one event per line.  The first event is always
//! `SessionStart {program, args}`; the last (on `pagehide` /
//! `__ct.stop()`) is `SessionEnd {}`.  See `Value-Origin-Tracking.md`
//! §14.4 for the full event vocabulary.
//!
//! # On-disk format
//!
//! V1 lands the legacy three-file JSON trace shape — the lightest
//! container the downstream `codetracer_trace_reader` / db-backend tooling
//! understands without pulling in the Nim-backed CTFS writer (which would
//! force every backend-manager build to compile the trace-format-nim
//! static library, see `codetracer-trace-format-nim`):
//!
//!   * `<out_dir>/<program>.ct/trace.json`          — `Vec<TraceLowLevelEvent>` per spec
//!   * `<out_dir>/<program>.ct/trace_metadata.json` — `{program, args, workdir, ...}`
//!   * `<out_dir>/<program>.ct/trace_paths.json`    — `[path, ...]`
//!
//! Upgrading to the CBOR+Zstd CTFS container is a follow-on that swaps
//! this writer impl for a `NimTraceWriter`-backed one without touching the
//! WebSocket transport surface above.  The `CtfsWriter` trait keeps that
//! seam intact.
//!
//! # Why `trace.json` is written incrementally (M38c)
//!
//! `codetracer-specs/Recording-Backends/WASM-Replay-Snapshots-And-Slices.md`
//! §2 requires snapshots to be derived **during** recording: "the browser
//! streams boundary events; a replaying recorder consumes that stream as it
//! arrives and re-executes in lockstep, emitting snapshots as it goes. When
//! the page stops, the snapshots are already there."
//!
//! The original writer accumulated every record in a `Vec` and wrote
//! `trace.json` with one `fs::write` at session end, so the file did not
//! exist until the page unloaded — it could be neither followed nor teed,
//! and §2's timeline could not hold in production no matter what the
//! consumer did.  [`JsonFileCtfsWriter`] now appends each record the
//! moment it is translated: the array is opened with `[` on the first
//! record and closed with `]` at session end.
//!
//! Two properties of that rendering are load-bearing and pinned by tests:
//!
//! 1. **It is byte-for-byte what the single-shot writer produced.**
//!    `serde_json`'s compact sequence serialiser emits
//!    `[` *elem* `,` *elem* … `]` with no whitespace, so appending
//!    `"[" + first` and then `"," + next` reproduces
//!    `serde_json::to_string(&Vec<TraceLowLevelEvent>)` exactly, and `[]`
//!    for an empty recording.  This is not cosmetic: the `Function`,
//!    `VariableName` and `Path` tables in this format are **positional**,
//!    consumers resolve them by index, and `codetracer-wasm-recorder`
//!    pins the exact rendering (`TestBuilderReproducesTheCommittedBrowserRecording`)
//!    as does the committed cross-process demo fixture.
//!    `verify_incremental_writer_is_byte_identical_to_the_batch_writer`
//!    renders the same record sequence both ways and compares the bytes.
//! 2. **A recording cut off mid-session is classifiable, not corrupt.**
//!    Each record is assembled into one buffer (separator + JSON) and
//!    handed to a single `write_all`, so a producer that dies leaves whole
//!    records and an unclosed array — which
//!    `codetracer-wasm-recorder/internal/boundarylog/stream.go` classifies
//!    as the benign `TruncatedUnterminated` ("every crossing it did carry
//!    was complete") rather than `TruncatedMidRecord`.
//!
//! `trace_metadata.json` is also written when the stream opens, not only
//! at session end, because the streaming consumer calls
//! `boundarylog.LoadRecordingMetadata` on the `.ct` *before* reading a
//! single record; without it the recording it produces has no program
//! name.  Session end rewrites it, so the final bytes are unchanged.
//!
//! # Feeding the streaming consumer (opt-in)
//!
//! Nothing above changes what lands on disk, so it is unconditional.  The
//! two ways to hand the same bytes to a §2 consumer *are* opt-in, because
//! they spawn a process and add a file to the `.ct`:
//!
//! * [`StreamConsumerConfig::command`] — a command spawned
//!   once per recording, receiving the exact `trace.json` byte stream on
//!   stdin.  This is the shape
//!   `wazero-snapshots run --boundary-log <program>.ct --boundary-stream -`
//!   wants: EOF is unambiguous (the daemon closes stdin) and backpressure
//!   is real (the consumer reads only between exported calls).  Its
//!   absence or failure costs seek performance only — a broken tee is
//!   logged and the recording continues.
//! * [`StreamConsumerConfig::done_marker`] — the marker file
//!   `wazero-snapshots run --boundary-stream <file> --stream-done <marker>`
//!   waits for, created inside the `.ct` after the final flush.  A file
//!   has no end of stream, so without the marker the consumer refuses to
//!   follow one.
//!
//! # Why the legacy JSON shape (not CTFS) for M26 V1
//!
//! 1. **Zero new build deps.**  The backend-manager crate currently has a
//!    pure-Rust dependency graph; pulling in `codetracer_trace_writer_nim`
//!    would force every consumer (including the headless CI containers)
//!    to grow a Nim toolchain + libzstd + a build.rs invocation that
//!    compiles a static library.  M26's stop-condition rules that out as
//!    "new infrastructure".
//! 2. **The reader path already handles it.**  The db-backend loads both
//!    the legacy JSON and the modern CTFS containers via the same trace
//!    reader entry point (`codetracer_trace_reader::open`); the format is
//!    auto-detected from the artefact shape.
//! 3. **A follow-on upgrade is mechanical.**  Swap [`JsonFileCtfsWriter`]
//!    below for a `NimTraceWriter` instance — the WebSocket transport,
//!    the receiver, and the CLI are untouched.

use std::fs;
use std::io;
use std::io::Write;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

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
/// argument with the absolute path of the `.ct` directory the recording is
/// being written to.
///
/// The consumer needs it — `wazero-snapshots run --boundary-log <program>.ct`
/// reads the recording's metadata from that directory — but the daemon only
/// knows the path once the page has announced its program name, so it cannot
/// be baked into the command line by the operator.
pub const TRACE_DIR_PLACEHOLDER: &str = "{trace_dir}";

/// How the daemon hands the recording's byte stream to a
/// `WASM-Replay-Snapshots-And-Slices.md` §2 consumer.
///
/// Both members are **off by default**: `record-web` without them behaves
/// exactly as it always has, spawning nothing and writing nothing extra
/// into the `.ct`.
#[derive(Debug, Clone, Default)]
pub struct StreamConsumerConfig {
    /// Command and arguments spawned once per recording, fed the exact
    /// `trace.json` byte stream on stdin.  Empty means "spawn nothing".
    ///
    /// Every argument has [`TRACE_DIR_PLACEHOLDER`] replaced with the
    /// recording's `.ct` path.  A typical value:
    ///
    /// ```text
    /// wazero-snapshots run --boundary-log {trace_dir} --boundary-stream - \
    ///     --slice-dir {trace_dir}/slices --slice-every 10 original.wasm
    /// ```
    pub command: Vec<String>,
    /// Name of a marker file created inside the `.ct` once `trace.json` is
    /// complete, for the file-following consumer shape
    /// (`--boundary-stream <file> --stream-done <marker>`).  `None` means
    /// no marker is written.
    pub done_marker: Option<String>,
}

/// Configuration for the [`BrowserStreamHost`].
#[derive(Debug, Clone)]
pub struct BrowserStreamHostConfig {
    /// Address to bind the TCP listener to.  Defaults to [`DEFAULT_BIND`].
    pub bind: SocketAddr,
    /// Directory under which per-program `.ct` trace directories land.
    /// Created on demand if it does not exist.
    pub out_dir: PathBuf,
    /// Working directory recorded in `trace_metadata.json`.  Defaults to
    /// the host process's CWD at start time.
    pub workdir: PathBuf,
    /// Optional §2 streaming-consumer wiring.  Defaults to
    /// [`StreamConsumerConfig::default`], which spawns nothing.
    pub stream_consumer: StreamConsumerConfig,
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
        let config = self.config.clone();
        let join = tokio::spawn(accept_loop(listener, config, shutdown_rx));
        Ok(RunningHost {
            local_addr,
            shutdown_tx: Some(shutdown_tx),
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
    join: Option<tokio::task::JoinHandle<()>>,
}

impl RunningHost {
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
) {
    loop {
        tokio::select! {
            biased;
            _ = &mut shutdown_rx => {
                log::info!("browser-stream host shutting down");
                return;
            }
            accept = listener.accept() => {
                match accept {
                    Ok((stream, peer)) => {
                        log::info!("browser-stream host: accepted connection from {peer}");
                        let cfg = config.clone();
                        tokio::spawn(async move {
                            if let Err(err) = handle_connection(stream, cfg).await {
                                log::warn!("browser-stream host: connection from {peer} failed: {err}");
                            }
                        });
                    }
                    Err(err) => {
                        log::error!("browser-stream host: accept failed: {err}");
                        // Brief backoff to avoid a tight error loop if the
                        // listener is wedged (e.g. fd exhaustion).
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
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
    let writer_handle = Arc::new(Mutex::new(JsonFileCtfsWriter::with_stream_consumer(
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
// by value, but here we have to keep an `Arc<Mutex<JsonFileCtfsWriter>>` around so
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
// On-disk JSON CTFS writer
// ---------------------------------------------------------------------------

/// A [`CtfsWriter`] that emits the legacy three-file JSON trace shape.
///
/// The format is the same one `NonStreamingTraceWriter` writes in
/// `codetracer-trace-format/codetracer_trace_writer_nim/src/lib.rs`
/// (`fn flush_events_to_disk`): a directory containing `trace.json` (a
/// `Vec<TraceLowLevelEvent>`), `trace_metadata.json`
/// (`{program, args, workdir}`), and `trace_paths.json` (`Vec<String>`).
/// The db-backend / `codetracer_trace_reader` reader path auto-detects
/// this format from the directory shape.
pub struct JsonFileCtfsWriter {
    out_dir: PathBuf,
    workdir: PathBuf,
    program: String,
    args: Vec<String>,
    /// The open `trace.json`, plus the optional tee into the spawned §2
    /// consumer.  `None` before the first record and after `session_end`
    /// has closed the array — see [`Self::open_stream`].
    stream: Option<RecordStream>,
    /// The `.ct` directory chosen when the stream opened.  Once fixed it
    /// is never recomputed, so metadata and the events file cannot land in
    /// different directories if the program name arrives late.
    trace_dir: Option<PathBuf>,
    /// §2 consumer wiring; see [`StreamConsumerConfig`].
    stream_consumer: StreamConsumerConfig,
    /// Test-only mirror of every emitted record.
    ///
    /// The whole point of the incremental writer is *not* to hold the
    /// recording in memory, so this is `None` in production.  A test
    /// enables it to render the same record sequence the way the original
    /// single-shot writer did — `serde_json::to_string` of one `Vec` — and
    /// compare those bytes against the file the incremental path produced.
    /// Comparing against serde's own sequence serialiser (rather than
    /// against a second hand-rolled join) is what makes that check worth
    /// anything.
    batch_mirror: Option<Vec<TraceLowLevelEvent>>,
    /// Path interning table: maps the path's first-seen index to the
    /// canonical `path_id`.  Mirrors `NonStreamingTraceWriter`'s
    /// `ensure_path_id` so paths land in `trace_paths.json` in
    /// registration order.
    path_index: indexmap_compat::OrderedSet<PathBuf>,
    /// Function interning table: keyed by `(fn_id_from_runtime,
    /// path_id_at_first_sight)`.  The browser runtime mints its own
    /// `fnId` namespace which we map 1:1 onto the canonical
    /// `function_id` for the on-disk format.  Subsequent `Call` events
    /// referencing the same `fnId` resolve to the registered function.
    fn_table: indexmap_compat::OrderedMap<u32, FunctionRecordOnDisk>,
    /// Whether `session_end` has run.  Set to true after the JSON files
    /// land on disk so a second call is a no-op.
    pub session_ended: bool,
    /// The path the writer chose for the events file — captured for
    /// logging and for the smoke test.
    pub last_output_path: Option<PathBuf>,
    /// Variable-name interning table.  The on-disk format identifies a
    /// variable by its index in `VariableName` registration order, so a
    /// writer that emits the name but always writes id 0 attributes
    /// every value in the recording to whichever name happened to be
    /// registered first — the trace looks populated but every lookup
    /// returns the wrong variable.
    var_index: indexmap_compat::OrderedSet<String>,
    /// Instrumentation manifest forwarded by the page runtime, decoded
    /// into the site / function lookup tables below.  `None` until a
    /// `Manifest` event arrives (or forever, for a runtime that does not
    /// bundle one) — in that case the writer falls back to the
    /// `<browser>` placeholder path and site-id-as-line encoding.
    manifest: Option<InstrumentationManifest>,
    /// Accumulated spec §3.3 / §3.4 host state, rendered to
    /// `boundary_state.json`.  Empty (and no file written) for every
    /// recording whose module defines its own memory and globals.
    host_state: HostStateSidecar,
}

/// Name of the spec §3.3 / §3.4 sidecar inside the `.ct` directory.
///
/// Must match `HostStateFileName` in
/// `codetracer-wasm-recorder/internal/boundarylog/hoststate.go`.
const HOST_STATE_FILE_NAME: &str = "boundary_state.json";

/// Schema version of the sidecar.
///
/// The consumer treats an unrecognised version as a **hard error** rather
/// than reading what it recognises, because the whole point of §3.3 is
/// that a missing input produces a divergence later, at a point unrelated
/// to the cause.  Bumping this therefore means bumping it there too.
const HOST_STATE_VERSION: u32 = 1;

/// `boundary_state.json` as it is written.
///
/// Mirrors `HostState` in the consumer, field for field.  `tables` is
/// always empty: the producer never records imported-table state, and the
/// consumer *rejects* a recording that carries any (spec §8 lists
/// host-mutated imported tables among the constructs refused rather than
/// silently degraded).  It is emitted rather than omitted so the file
/// states the fact instead of leaving it to a missing key.
#[derive(Debug, Serialize)]
struct HostStateSidecar {
    version: u32,
    initial: InitialStateSidecar,
    mutations: Vec<HostMutationRecord>,
    /// Not serialised: whether a `HostInitialState` event has been seen,
    /// which is what distinguishes "the host supplied nothing" from "the
    /// host supplied an empty set of regions".
    #[serde(skip)]
    initial_seen: bool,
}

impl Default for HostStateSidecar {
    fn default() -> Self {
        Self {
            version: HOST_STATE_VERSION,
            initial: InitialStateSidecar::default(),
            mutations: Vec::new(),
            initial_seen: false,
        }
    }
}

#[derive(Debug, Default, Serialize)]
struct InitialStateSidecar {
    memories: Vec<ImportedMemoryState>,
    globals: Vec<ImportedGlobalState>,
    tables: Vec<serde_json::Value>,
}

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

impl JsonFileCtfsWriter {
    pub fn new(out_dir: PathBuf, workdir: PathBuf) -> Self {
        Self::with_stream_consumer(out_dir, workdir, StreamConsumerConfig::default())
    }

    /// Same as [`Self::new`] but with the §2 streaming-consumer wiring
    /// attached.  Kept separate so the default constructor stays the
    /// "spawn nothing, write nothing extra" one.
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
            stream: None,
            trace_dir: None,
            stream_consumer,
            batch_mirror: None,
            path_index: indexmap_compat::OrderedSet::new(),
            fn_table: indexmap_compat::OrderedMap::new(),
            session_ended: false,
            last_output_path: None,
            var_index: indexmap_compat::OrderedSet::new(),
            manifest: None,
            host_state: HostStateSidecar::default(),
        }
    }

    /// Retain every emitted record so a test can re-render the recording
    /// the way the original single-shot writer did.  See
    /// [`Self::batch_mirror`].
    #[cfg(test)]
    fn enable_batch_mirror(&mut self) {
        self.batch_mirror = Some(Vec::new());
    }

    /// The `.ct` directory this recording is being written to, chosen from
    /// the program name the page announced.
    ///
    /// `default_output_path` sanitises the program name so an untrusted
    /// page title cannot traverse the output layout.
    fn resolve_trace_dir(&self) -> PathBuf {
        if let Some(dir) = &self.trace_dir {
            return dir.clone();
        }
        let program_name = if self.program.is_empty() {
            "browser".to_string()
        } else {
            self.program.clone()
        };
        // The .ct artefact in M26 V1 is a *directory* (legacy JSON shape),
        // so `.ct` here is the directory name.
        default_output_path(&self.out_dir, &program_name)
    }

    /// Render `trace_metadata.json`.  Written both when the stream opens
    /// (so a concurrently-spawned consumer's
    /// `boundarylog.LoadRecordingMetadata` finds a program name) and again
    /// at session end, which is what fixes the final bytes.
    fn write_metadata(&self, trace_dir: &std::path::Path) -> io::Result<()> {
        let metadata = TraceMetadata {
            program: self.program.clone(),
            args: self.args.clone(),
            workdir: self.workdir.to_string_lossy().into_owned(),
            recorder: TraceMetadataRecorder {
                name: "codetracer-js-recorder-browser".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        };
        let metadata_json = serde_json::to_string(&metadata)
            .map_err(|e| io::Error::other(format!("metadata serialisation: {e}")))?;
        fs::write(trace_dir.join("trace_metadata.json"), metadata_json)
    }

    /// Render `trace_paths.json` — the registration-order list of source
    /// paths, whose *position* is the `path_id` every `Step` refers to.
    fn write_paths(&self, trace_dir: &std::path::Path) -> io::Result<()> {
        let paths: Vec<String> = self
            .path_index
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let paths_json = serde_json::to_string(&paths)
            .map_err(|e| io::Error::other(format!("paths serialisation: {e}")))?;
        fs::write(trace_dir.join("trace_paths.json"), paths_json)
    }

    /// Create the `.ct` directory, open `trace.json` for appending and
    /// spawn the §2 consumer, if any.  Idempotent.
    ///
    /// Deferred to the first record rather than done in `session_start`
    /// because the output path is derived from the program name, and only
    /// a session that produced at least one record — or ended — needs a
    /// directory at all.
    fn open_stream(&mut self) -> io::Result<()> {
        if self.stream.is_some() {
            return Ok(());
        }
        let trace_dir = self.resolve_trace_dir();
        fs::create_dir_all(&trace_dir)?;
        // Truncating is right: a `JsonFileCtfsWriter` is created per
        // connection and owns its recording, so anything already at this
        // path is a previous run's, and appending to it would splice two
        // recordings into one malformed array.
        let file = fs::File::create(trace_dir.join("trace.json"))?;
        // Before the consumer starts: it reads the recording's metadata
        // from the `.ct` at startup, not from the stream.
        self.write_metadata(&trace_dir)?;
        self.write_paths(&trace_dir)?;
        let tee = self.spawn_consumer(&trace_dir);
        self.trace_dir = Some(trace_dir);
        self.stream = Some(RecordStream::new(file, tee));
        Ok(())
    }

    /// Spawn the configured §2 consumer, or return `None`.
    ///
    /// A failure to spawn is logged and swallowed: the consumer only ever
    /// makes seeking faster, so its absence must never cost the user their
    /// recording (spec §11 / `MCR-Memory-Page-CAS.md` §10 take the same
    /// line about snapshot versions).
    fn spawn_consumer(&self, trace_dir: &std::path::Path) -> Option<ConsumerTee> {
        let command = &self.stream_consumer.command;
        let (program, args) = command.split_first()?;
        let substitute = |arg: &String| -> String {
            arg.replace(TRACE_DIR_PLACEHOLDER, &trace_dir.to_string_lossy())
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
                log::info!("browser-stream writer: streaming the recording into `{label}`");
                Some(ConsumerTee {
                    child,
                    stdin,
                    label,
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

    /// Append one record to `trace.json` (and the tee), opening the array
    /// on the first call.
    fn emit(&mut self, event: TraceLowLevelEvent) -> io::Result<()> {
        if self.session_ended {
            // The array has been closed; a record appended after it would
            // make the document unparseable for every consumer. The
            // single-shot writer dropped these too (its `flush` was
            // one-shot), so this is the same loss made audible.
            log::warn!(
                "browser-stream writer: dropping a record that arrived after session end: \
                 {event:?}"
            );
            return Ok(());
        }
        let json = serde_json::to_string(&event)
            .map_err(|e| io::Error::other(format!("event serialisation: {e}")))?;
        if let Some(mirror) = self.batch_mirror.as_mut() {
            mirror.push(event);
        }
        self.open_stream()?;
        self.stream
            .as_mut()
            .expect("open_stream leaves the stream open")
            .write_record(json.as_bytes())
    }

    /// Resolve a variable name to its on-disk id, registering it on
    /// first sight.
    fn intern_variable(&mut self, name: &str) -> io::Result<u32> {
        let (idx, inserted) = self.var_index.insert_full(name.to_string());
        if inserted {
            self.emit(TraceLowLevelEvent::VariableName(name.to_string()))?;
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

    /// Resolve a runtime-side path string to a canonical `path_id`,
    /// interning the path if it has not been seen yet.  Mirrors
    /// `NonStreamingTraceWriter::ensure_path_id`.
    fn intern_path(&mut self, path: &str) -> io::Result<u32> {
        let path_buf = PathBuf::from(path);
        let (idx, inserted) = self.path_index.insert_full(path_buf.clone());
        if inserted {
            self.emit(TraceLowLevelEvent::Path(
                path_buf.to_string_lossy().into_owned(),
            ))?;
        }
        Ok(idx as u32)
    }

    /// Translate a [`BrowserEvent`] into one or more on-disk
    /// `TraceLowLevelEvent`s.  Some browser events expand to multiple
    /// disk events (e.g. a `Call` may emit a synthetic `Function` record
    /// the first time its `fnId` is seen).
    fn translate(&mut self, event: &BrowserEvent) -> io::Result<()> {
        match event {
            BrowserEvent::Path { path_id: _, path } => {
                // The runtime's path_id is opaque; we re-intern through
                // our own table so the on-disk indices stay dense and
                // start at 0.  The runtime's path_id is dropped (it has
                // no consumer on the disk side).
                self.intern_path(path)?;
            }
            BrowserEvent::Step { site_id } => {
                // Browser site IDs are flat; the forwarded manifest
                // carries the `(path, line)` tuple per site.  When the
                // runtime bundled a manifest we resolve to the real
                // source location — that is what lets the origin
                // classifier read the source line behind each hop.
                // Without one we fall back to the historical placeholder
                // (`<browser>` path, site id smuggled as the line) so
                // manifest-less runtimes still record.
                let (path_id, line) = self.step_position(*site_id)?;
                self.emit(TraceLowLevelEvent::Step(StepRecord { path_id, line }))?;
            }
            BrowserEvent::Assignment { site_id, value } => {
                // Same position resolution as Step — an assignment site is
                // a step site with write metadata attached.
                let (path_id, line) = self.step_position(*site_id)?;
                self.emit(TraceLowLevelEvent::Step(StepRecord { path_id, line }))?;
                // Bind the value to its name so the recording carries
                // variables, not just positions. A trace that records
                // where execution went but not what it produced cannot
                // answer any question about a value — including where it
                // came from.
                if let (Some(target), Some(value)) = (self.site_target(*site_id), value.as_ref()) {
                    let variable_id = self.intern_variable(&target)?;
                    self.emit(TraceLowLevelEvent::Value(FullValueRecordOnDisk {
                        variable_id,
                        value: translate_value(value),
                    }))?;
                }
            }
            BrowserEvent::Call { fn_id, args } => {
                let function_id = self.ensure_function_id(*fn_id)?;
                let translated_args: Vec<FullValueRecordOnDisk> = args
                    .iter()
                    .enumerate()
                    .map(|(i, v)| FullValueRecordOnDisk {
                        variable_id: i as u32,
                        value: translate_value(v),
                    })
                    .collect();
                self.emit(TraceLowLevelEvent::Call(CallRecord {
                    function_id,
                    args: translated_args,
                }))?;
            }
            BrowserEvent::Return {
                fn_id: _,
                return_value,
            } => {
                self.emit(TraceLowLevelEvent::Return(ReturnRecord {
                    return_value: translate_value(return_value),
                }))?;
            }
            BrowserEvent::Value { name, value } => {
                let variable_id = self.intern_variable(name)?;
                self.emit(TraceLowLevelEvent::Value(FullValueRecordOnDisk {
                    variable_id,
                    value: translate_value(value),
                }))?;
            }
            BrowserEvent::Write { channel, content } => {
                self.emit(TraceLowLevelEvent::Event(RecordEvent {
                    kind: write_channel_to_kind(channel),
                    metadata: channel.clone(),
                    content: content.clone(),
                }))?;
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
                // `MarkerPayload` JSON document.  This shape is
                // load-bearing, not cosmetic: the db-backend's
                // `SessionHandler::pair_index` calls
                // `MarkerPayload::decode(&event.metadata)` and silently
                // drops any firing that does not deserialise into the
                // full struct.  An abbreviated `{direction, boundary}`
                // object decodes to `None`, which means the marker never
                // enters the pair index and no cross-process chain can
                // ever cross this boundary.  Field names and the
                // `key_value`-is-a-string convention therefore mirror
                // `codetracer/src/db-backend/src/correlation_markers.rs`
                // exactly.
                //
                // `key_value` is stringified because the pair index
                // matches sends to receives by string equality on
                // `(boundary_id, key_value)`; JSON numbers and strings
                // that render identically must therefore collapse to the
                // same key.
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
                self.emit(TraceLowLevelEvent::Event(RecordEvent {
                    kind: EVENT_KIND_TRACE_LOG_EVENT,
                    metadata,
                    content,
                }))?;
            }
            // --- spec §3.3 / §3.4: host-supplied state ------------------
            //
            // These describe the module's *starting state* and what the
            // host did to it during a host call.  Neither is something
            // that happened at a step, so neither becomes a
            // `TraceLowLevelEvent`: emitting one would put a record into
            // `trace.json` that the boundary-log assembler would then have
            // to learn to skip, and would shift nothing but risk.  They go
            // into the `boundary_state.json` sidecar instead.
            BrowserEvent::HostInitialState { memories, globals } => {
                if self.host_state.initial_seen {
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
                    self.host_state.initial_seen = true;
                    self.host_state.initial.memories = memories.clone();
                    self.host_state.initial.globals = globals.clone();
                }
                self.write_host_state()?;
            }
            BrowserEvent::HostMutation {
                after_crossing,
                memory_writes,
                global_sets,
            } => {
                self.host_state.mutations.push(HostMutationRecord {
                    after_crossing: *after_crossing,
                    memory_writes: memory_writes.clone(),
                    global_sets: global_sets.clone(),
                });
                self.write_host_state()?;
            }
            // Lifecycle events are handled in the trait impls below.
            BrowserEvent::SessionStart { .. }
            | BrowserEvent::Manifest { .. }
            | BrowserEvent::SessionEnd {} => {}
        }
        Ok(())
    }

    /// Render `boundary_state.json`, the spec §3.3 / §3.4 sidecar.
    ///
    /// Written every time it changes rather than once at session end, for
    /// the same reason `trace.json` is appended to rather than buffered
    /// (M38c): a `.ct` that is being consumed while it is still being
    /// produced must not have to wait for the page to close.  It is
    /// rewritten whole each time because it is small — a boundary
    /// recording's host state is the calldata a page supplied, not the
    /// memory image — and because a partially-written array is not a
    /// document any consumer could read.
    ///
    /// Nothing is written when the page supplied no host state at all,
    /// which is the common case: the consumer treats a missing file as
    /// "this module defines its own memory and globals", and an empty
    /// sidecar would say the same thing more confusingly.
    fn write_host_state(&mut self) -> io::Result<()> {
        if !self.host_state.initial_seen && self.host_state.mutations.is_empty() {
            return Ok(());
        }
        self.open_stream()?;
        let trace_dir = self
            .trace_dir
            .clone()
            .expect("open_stream fixes the trace dir");
        let json = serde_json::to_string(&self.host_state)
            .map_err(|e| io::Error::other(format!("host state serialisation: {e}")))?;
        fs::write(trace_dir.join(HOST_STATE_FILE_NAME), json)
    }

    /// Resolve the runtime's `fn_id` to a canonical on-disk function id.
    /// The browser runtime currently does not ship a separate `Function`
    /// event before the first `Call`, so we synthesise one on first
    /// sight with placeholder name / path / line — the manifest carries
    /// the real values in V1+ and the synthesised record is overwritten
    /// at trace open time.
    fn ensure_function_id(&mut self, fn_id: u32) -> io::Result<u32> {
        // Prefer the manifest's real `(name, path, line)`; fall back to
        // a synthesised record when no manifest was forwarded.
        let (name, path_id, line) = match self.resolve_function(fn_id)? {
            Some(resolved) => resolved,
            None => (format!("fn_{fn_id}"), self.ensure_default_path()?, 0),
        };
        let next_id = self.fn_table.len() as u32;
        let mut newly_inserted = false;
        let record_name = name.clone();
        let assigned = self
            .fn_table
            .entry(fn_id)
            .or_insert_with(|| {
                newly_inserted = true;
                FunctionRecordOnDisk {
                    function_id: next_id,
                    name: record_name,
                    path_id,
                    line,
                }
            })
            .function_id;
        if newly_inserted {
            // Insertion order matters — we must emit the Function event
            // before the Call event that triggered the lookup.  The
            // caller `translate` emits the Call afterwards.
            self.emit(TraceLowLevelEvent::Function(FunctionRecord {
                name,
                path_id,
                line,
            }))?;
        }
        Ok(assigned)
    }

    /// Lazily register the placeholder path used for Step / Assignment
    /// events until the manifest forwarding lands.  Returns the canonical
    /// path_id.
    fn ensure_default_path(&mut self) -> io::Result<u32> {
        // `<browser>` is the marker the db-backend recognises as
        // "browser recording, manifest not yet forwarded" — same string
        // convention as the existing `<unknown>` sentinel for the JS
        // recorder.  Lives in path index 0 by construction.
        self.intern_path("<browser>")
    }

    /// Finalise the recording: close `trace.json`'s array, rewrite the
    /// metadata and paths files, let the consumer see end of stream.
    ///
    /// Idempotent; subsequent calls are no-ops once `session_ended` is
    /// true.  A session that ended without ever emitting a record still
    /// lands a complete three-file trace, whose `trace.json` is `[]` —
    /// exactly what the single-shot writer produced for that case.
    fn flush(&mut self) -> io::Result<PathBuf> {
        if self.session_ended {
            return Ok(self
                .last_output_path
                .clone()
                .unwrap_or_else(|| self.out_dir.clone()));
        }
        // Opens the `.ct` if no record ever arrived, so the "session ended
        // without streaming anything" path still produces a valid trace.
        self.open_stream()?;
        let trace_dir = self
            .trace_dir
            .clone()
            .expect("open_stream fixes the trace dir");

        self.stream
            .as_mut()
            .expect("open_stream leaves the stream open")
            .close()?;

        self.write_metadata(&trace_dir)?;
        self.write_paths(&trace_dir)?;
        // Idempotent: the sidecar is already current, since it is
        // rewritten on every host-state event.  Repeating it here means
        // the "recording is final" guarantee covers it too, without the
        // caller having to know it was written earlier.
        self.write_host_state()?;

        self.session_ended = true;
        self.last_output_path = Some(trace_dir.clone());

        // Dropping the stream closes the tee's stdin, which is what gives
        // `--boundary-stream -` its unambiguous end of stream, and reaps
        // the child so a long-running daemon does not accumulate zombies.
        // It happens before the marker so that by the time a
        // file-following consumer starts, the piped one is already done.
        self.stream = None;

        // The marker is created last: its whole meaning is "`trace.json`
        // is final", so everything a consumer might then read must already
        // be on disk.
        //
        // Because of the reap above, the marker's mtime is *after the
        // piped consumer exited*, not when the recording stopped being
        // produced. It is therefore useless as a reference point for "was
        // this derived during the recording?" — measuring against it makes
        // the answer trivially yes. `trace.json`'s own mtime is that
        // instant, since the `]` written by `close()` is its last write.
        // `stream-snapshots-demo.sh` uses that, and says why.
        if let Some(marker) = self.stream_consumer.done_marker.clone() {
            let marker_path = trace_dir.join(&marker);
            if let Err(err) = fs::write(&marker_path, b"") {
                // A missing marker only means a file-following consumer
                // waits; it must not fail the recording.
                log::warn!(
                    "browser-stream writer: could not create the stream-done marker {}: {err}",
                    marker_path.display(),
                );
            }
        }
        Ok(trace_dir)
    }
}

// ---------------------------------------------------------------------------
// The incremental record stream
// ---------------------------------------------------------------------------

/// The spawned §2 consumer and the pipe into it.
struct ConsumerTee {
    child: Child,
    /// `None` once writing has failed or the pipe has been closed.
    stdin: Option<std::process::ChildStdin>,
    /// The resolved command line, for log messages.
    label: String,
}

/// `trace.json` as it is being written, plus the optional tee.
///
/// The array framing lives here and nowhere else: `[` before the first
/// record, `,` before every later one, `]` at the end (or `[]` for a
/// recording with no records).  That is precisely `serde_json`'s compact
/// rendering of a `Vec`, which is what makes the incremental output
/// byte-identical to the single-shot writer's.
struct RecordStream {
    file: fs::File,
    tee: Option<ConsumerTee>,
    /// Whether the opening `[` has been written.
    opened: bool,
    records: u64,
}

impl RecordStream {
    fn new(file: fs::File, tee: Option<ConsumerTee>) -> Self {
        Self {
            file,
            tee,
            opened: false,
            records: 0,
        }
    }

    /// Append one already-serialised record.
    ///
    /// The separator and the record body go out in a **single**
    /// `write_all`.  That is what keeps a crashed producer's file
    /// classifiable: `boundarylog.StreamReader` distinguishes
    /// `TruncatedMidRecord` (unusable trailing bytes) from the benign
    /// `TruncatedUnterminated` (whole records, no closing `]`), and only
    /// one write per record can land in the latter.
    fn write_record(&mut self, json: &[u8]) -> io::Result<()> {
        let mut buf = Vec::with_capacity(json.len() + 1);
        buf.push(if self.opened { b',' } else { b'[' });
        buf.extend_from_slice(json);
        self.opened = true;
        self.records += 1;
        self.write_bytes(&buf)
    }

    /// Close the array.  `[]` when no record was ever written, which is
    /// what `serde_json::to_string(&Vec::<T>::new())` renders.
    fn close(&mut self) -> io::Result<()> {
        let tail: &[u8] = if self.opened { b"]" } else { b"[]" };
        self.opened = true;
        self.write_bytes(tail)
    }

    /// Write to the recording, then to the tee.
    ///
    /// The order matters: the recording is the source of truth (spec §2),
    /// snapshots are derived data, so the `.ct` must never be short of a
    /// record the consumer already has.  A tee failure is logged once and
    /// the tee dropped — it costs seek performance, never the recording.
    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.file.write_all(bytes)?;
        let Some(tee) = self.tee.as_mut() else {
            return Ok(());
        };
        let Some(stdin) = tee.stdin.as_mut() else {
            return Ok(());
        };
        // A blocking write is deliberate: it is how the consumer's
        // backpressure reaches the browser (the WebSocket's TCP window),
        // which is what keeps the replayer from accumulating an unbounded
        // backlog of unreplayed crossings. See
        // `codetracer-wasm-recorder/internal/boundarylog/stream.go`.
        if let Err(err) = stdin.write_all(bytes) {
            log::warn!(
                "browser-stream writer: the snapshot consumer `{}` stopped reading ({err}); \
                 continuing without it. The recording is unaffected.",
                tee.label,
            );
            tee.stdin = None;
        }
        Ok(())
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

impl Drop for RecordStream {
    fn drop(&mut self) {
        let records = self.records;
        let Some(tee) = self.tee.as_mut() else {
            return;
        };
        // Close the pipe first: the consumer reads until EOF, so it will
        // not exit before stdin closes and waiting on it first would
        // deadlock.
        tee.stdin = None;
        let deadline = std::time::Instant::now() + CONSUMER_EXIT_GRACE;
        loop {
            match tee.child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    log::info!(
                        "browser-stream writer: snapshot consumer `{}` finished after {records} \
                         record(s)",
                        tee.label,
                    );
                    return;
                }
                Ok(Some(status)) => {
                    log::warn!(
                        "browser-stream writer: snapshot consumer `{}` exited with {status}; \
                         the recording is complete but seeking it will be linear",
                        tee.label,
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
                        tee.label,
                        CONSUMER_EXIT_GRACE,
                    );
                    let _ = tee.child.kill();
                    let _ = tee.child.wait();
                    return;
                }
                Err(err) => {
                    log::warn!(
                        "browser-stream writer: could not wait for the snapshot consumer `{}`: \
                         {err}",
                        tee.label,
                    );
                    return;
                }
            }
        }
    }
}

impl CtfsWriter for JsonFileCtfsWriter {
    fn session_start(&mut self, program: &str, args: &[String]) -> io::Result<()> {
        if self.trace_dir.is_some() && self.program != program {
            // `SessionStart` is spec'd as the very first line, so the
            // output path is normally fixed before any record arrives. If
            // a runtime announces itself late the recording stays where it
            // already is rather than splitting across two directories —
            // say so instead of silently choosing.
            log::warn!(
                "browser-stream writer: SessionStart named program `{program}` after the \
                 recording had already opened as `{}`; keeping the existing output path",
                self.program,
            );
        }
        self.program = program.to_string();
        self.args = args.to_vec();
        Ok(())
    }

    fn manifest(&mut self, manifest: &serde_json::Value) -> io::Result<()> {
        // Decode the instrumenter manifest so subsequent `Step` /
        // `Call` events resolve to real source locations.  A manifest
        // that fails to decode is logged and ignored rather than
        // failing the recording — a partially-understood manifest must
        // not cost the user their trace.
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

// ---------------------------------------------------------------------------
// On-disk serialisation types
// ---------------------------------------------------------------------------
//
// These shapes match `codetracer_trace_types::TraceLowLevelEvent` and its
// nested records.  We re-declare them here so backend-manager does NOT
// have to take a hard build-time dependency on the trace-format workspace
// (which would force a sibling repo into every build).  The downstream
// reader path uses serde's externally-tagged enum representation, so the
// names below must match the upstream variant names exactly.

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "PascalCase")]
enum TraceLowLevelEvent {
    Path(String),
    Function(FunctionRecord),
    Step(StepRecord),
    Call(CallRecord),
    Return(ReturnRecord),
    Value(FullValueRecordOnDisk),
    VariableName(String),
    Event(RecordEvent),
}

#[derive(Debug, Clone, Serialize)]
struct StepRecord {
    path_id: u32,
    line: i64,
}

#[derive(Debug, Clone, Serialize)]
struct FunctionRecord {
    name: String,
    path_id: u32,
    line: i64,
}

#[derive(Debug, Clone, Serialize)]
struct CallRecord {
    function_id: u32,
    args: Vec<FullValueRecordOnDisk>,
}

#[derive(Debug, Clone, Serialize)]
struct ReturnRecord {
    return_value: ValueRecordOnDisk,
}

#[derive(Debug, Clone, Serialize)]
struct FullValueRecordOnDisk {
    variable_id: u32,
    value: ValueRecordOnDisk,
}

/// On-disk projection of the browser-side `EncodedValue`.  Mirrors the
/// `ValueRecord` external-tagging used by
/// `codetracer_trace_types::ValueRecord` so the reader-side
/// `kind`-dispatched decode lands on the right variant.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "PascalCase")]
enum ValueRecordOnDisk {
    Int { i: String, type_id: u32 },
    Float { f: String, type_id: u32 },
    Bool { b: bool, type_id: u32 },
    String { text: String, type_id: u32 },
    Raw { r: String, type_id: u32 },
    None { type_id: u32 },
}

#[derive(Debug, Clone, Serialize)]
struct RecordEvent {
    kind: i32,
    metadata: String,
    content: String,
}

/// `EventLogKind::TraceLogEvent` discriminator — mirrors
/// `FfiEventLogKind::FFI_EVENT_TRACE_LOG_EVENT = 12` in
/// `codetracer_trace_writer.h`.
const EVENT_KIND_TRACE_LOG_EVENT: i32 = 12;
/// Stdout / stderr discriminators.
const EVENT_KIND_WRITE: i32 = 0;

fn write_channel_to_kind(channel: &str) -> i32 {
    // Stdout / stderr both map onto the generic Write kind — the channel
    // tag rides in the metadata field.
    let _ = channel;
    EVENT_KIND_WRITE
}

/// Convert a browser-side encoded value into the on-disk `ValueRecord`
/// shape.  V1 keeps it lossless for primitives and falls back to `Raw`
/// for compound payloads (the JSON value is stringified verbatim).
fn translate_value(encoded: &EncodedValue) -> ValueRecordOnDisk {
    match encoded.type_kind.as_str() {
        "Int" => ValueRecordOnDisk::Int {
            i: value_to_compact_string(&encoded.value),
            type_id: 0,
        },
        "Float" => ValueRecordOnDisk::Float {
            f: value_to_compact_string(&encoded.value),
            type_id: 0,
        },
        "Bool" => ValueRecordOnDisk::Bool {
            b: encoded.value.as_bool().unwrap_or(false),
            type_id: 0,
        },
        "String" => ValueRecordOnDisk::String {
            text: encoded.value.as_str().unwrap_or("").to_string(),
            type_id: 0,
        },
        "None" => ValueRecordOnDisk::None { type_id: 0 },
        _ => ValueRecordOnDisk::Raw {
            r: value_to_compact_string(&encoded.value),
            type_id: 0,
        },
    }
}

fn value_to_compact_string(value: &serde_json::Value) -> String {
    if let Some(s) = value.as_str() {
        return s.to_string();
    }
    value.to_string()
}

#[derive(Debug, Serialize)]
struct TraceMetadata {
    program: String,
    args: Vec<String>,
    workdir: String,
    recorder: TraceMetadataRecorder,
}

#[derive(Debug, Serialize)]
struct TraceMetadataRecorder {
    name: String,
    version: String,
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

        pub fn iter(&self) -> std::slice::Iter<'_, T> {
            self.order.iter()
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

// `FunctionRecordOnDisk` shadows the FFI shape — same fields as
// `codetracer_trace_types::FunctionRecord` but local to this module.
#[derive(Debug, Clone)]
struct FunctionRecordOnDisk {
    function_id: u32,
    #[allow(dead_code)]
    name: String,
    #[allow(dead_code)]
    path_id: u32,
    #[allow(dead_code)]
    line: i64,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser_stream_receiver::{BrowserEvent, EncodedValue};
    use std::time::Duration;
    use tempfile::TempDir;

    #[test]
    fn json_writer_lands_three_file_legacy_layout() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer
            .session_start("smoke-app", &["--demo".to_string()])
            .unwrap();
        writer.event(&BrowserEvent::Step { site_id: 1 }).unwrap();
        writer
            .event(&BrowserEvent::Value {
                name: "x".to_string(),
                value: EncodedValue {
                    value: serde_json::json!(42),
                    type_kind: "Int".to_string(),
                },
            })
            .unwrap();
        writer.event(&BrowserEvent::Step { site_id: 2 }).unwrap();
        let trace_dir = writer.session_end().unwrap();
        assert!(trace_dir.is_dir(), "trace dir should exist: {trace_dir:?}");
        let trace_json = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
        let metadata_json = std::fs::read_to_string(trace_dir.join("trace_metadata.json")).unwrap();
        let paths_json = std::fs::read_to_string(trace_dir.join("trace_paths.json")).unwrap();
        let events: serde_json::Value = serde_json::from_str(&trace_json).unwrap();
        let arr = events.as_array().expect("trace.json must be an array");
        // Path/Step/VariableName/Value/Step — five entries minimum.
        assert!(arr.len() >= 5, "events: {arr:?}");
        let metadata: serde_json::Value = serde_json::from_str(&metadata_json).unwrap();
        assert_eq!(metadata["program"], "smoke-app");
        assert_eq!(metadata["args"][0], "--demo");
        let paths: serde_json::Value = serde_json::from_str(&paths_json).unwrap();
        assert_eq!(paths[0], "<browser>");
    }

    #[test]
    fn json_writer_is_idempotent_on_double_session_end() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer.session_start("x", &[]).unwrap();
        let first = writer.session_end().unwrap();
        let second = writer.session_end().unwrap();
        assert_eq!(first, second);
        // A session that ended without ever streaming a record must still
        // leave a valid three-file trace, and its events file must be the
        // empty array — what `serde_json::to_string(&Vec::new())` renders,
        // so the reader path is unchanged. The second `session_end` must
        // not append a second `]`.
        let trace_json = std::fs::read_to_string(first.join("trace.json")).unwrap();
        assert_eq!(trace_json, "[]");
        assert!(first.join("trace_metadata.json").is_file());
        assert!(first.join("trace_paths.json").is_file());
    }

    /// The record sequence the byte-identity and truncation tests run on.
    ///
    /// It is deliberately the widest one available: a forwarded manifest
    /// (so `Step` / `Assignment` / `Call` resolve to real
    /// `Path` + `Function` records rather than the `<browser>` fallback),
    /// every `BrowserEvent` variant that produces a record, and every
    /// `ValueRecordOnDisk` arm — `Int`, `Float`, `Bool`, `String`, `None`
    /// and the `Raw` fallback. Between them these cover all eight
    /// `TraceLowLevelEvent` variants the writer can emit, which is what
    /// makes "byte-identical" a statement about the format rather than
    /// about one record type.
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

    /// Drive `events` through a writer, returning it plus the `.ct` path.
    /// `SessionStart` / `Manifest` / `SessionEnd` are dispatched to the
    /// lifecycle methods exactly as `StreamReceiver` does.
    fn drive(writer: &mut JsonFileCtfsWriter, events: &[BrowserEvent]) -> Option<PathBuf> {
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

    /// M38c's primary correctness test.
    ///
    /// The `Function`, `VariableName` and `Path` tables in this format are
    /// **positional** — consumers resolve them by index — so the
    /// incremental writer is pinned to the single-shot writer's exact
    /// rendering, not merely to an equivalent JSON document.
    /// `codetracer-wasm-recorder`'s
    /// `TestBuilderReproducesTheCommittedBrowserRecording`, the committed
    /// cross-process demo fixture and the db-backend's CTFS reader all
    /// depend on it.
    ///
    /// The reference side is `serde_json`'s own `Vec` serialiser — the
    /// literal expression the removed `flush` used
    /// (`serde_json::to_string(&self.events)`) — fed the very records the
    /// incremental path emitted. Comparing against a second hand-rolled
    /// join would prove nothing.
    #[test]
    fn verify_incremental_writer_is_byte_identical_to_the_batch_writer() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer.enable_batch_mirror();
        let events = wide_event_sequence();
        let trace_dir = drive(&mut writer, &events).expect("the sequence ends the session");

        let incremental = std::fs::read(trace_dir.join("trace.json")).unwrap();
        let batch = serde_json::to_string(
            writer
                .batch_mirror
                .as_ref()
                .expect("the mirror was enabled"),
        )
        .unwrap();

        assert_eq!(
            String::from_utf8_lossy(&incremental),
            batch,
            "the incrementally appended trace.json must be byte-for-byte what \
             serde_json renders for the same Vec<TraceLowLevelEvent>",
        );

        // Guard against the comparison passing vacuously: the sequence has
        // to have exercised every record variant.
        let records: Vec<serde_json::Value> = serde_json::from_slice(&incremental).unwrap();
        let kinds: std::collections::BTreeSet<String> = records
            .iter()
            .filter_map(|r| r.as_object())
            .flat_map(|o| o.keys().cloned())
            .collect();
        for expected in [
            "Path",
            "Function",
            "Step",
            "Call",
            "Return",
            "Value",
            "VariableName",
            "Event",
        ] {
            assert!(
                kinds.contains(expected),
                "the byte-identity input must exercise a {expected} record; got {kinds:?}",
            );
        }
    }

    /// The same comparison for the two degenerate lengths, where a
    /// hand-rolled array framing is easiest to get wrong: an empty
    /// recording must render `[]` and a one-record one must carry no
    /// separator.
    #[test]
    fn verify_incremental_framing_matches_serde_for_zero_and_one_records() {
        for take in [0usize, 1] {
            let tmp = TempDir::new().expect("create tempdir");
            let mut writer =
                JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
            writer.enable_batch_mirror();
            writer.session_start("tiny", &[]).unwrap();
            // One `Step` with no manifest emits a `Path` then a `Step`; to
            // land exactly one record, emit the `Path` alone.
            if take == 1 {
                writer
                    .event(&BrowserEvent::Path {
                        path_id: 0,
                        path: "only.js".to_string(),
                    })
                    .unwrap();
            }
            let trace_dir = writer.session_end().unwrap();
            let incremental = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
            let mirror = writer.batch_mirror.as_ref().unwrap();
            assert_eq!(mirror.len(), take, "expected {take} record(s)");
            assert_eq!(incremental, serde_json::to_string(mirror).unwrap());
        }
    }

    /// The committed browser recording, reframed record by record, must
    /// come back byte-for-byte.
    ///
    /// The two tests above compare the incremental writer against
    /// `serde_json`'s renderer on records the writer itself produced. That
    /// is the right oracle for the framing, but both sides of it are
    /// generated by the code under test, so neither is evidence about the
    /// bytes any *committed* consumer actually reads.
    ///
    /// This one takes the real `frontend-wasm.ct/trace.json` from the
    /// cross-process demo fixture — produced by the single-shot writer,
    /// committed, and pinned by `codetracer-wasm-recorder`'s
    /// `TestBuilderReproducesTheCommittedBrowserRecording` — splits it into
    /// its top-level records *as literal byte ranges of that file* (no
    /// re-serialisation anywhere), and pushes each through
    /// [`RecordStream`]. The result must equal the committed file exactly.
    /// Real records, real escapes, and an oracle that predates the change.
    #[test]
    fn verify_reframing_the_committed_browser_recording_reproduces_it_byte_for_byte() {
        for fixture in ["frontend-wasm.ct", "frontend.ct"] {
            let committed = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../db-backend/tests/fixtures/cross_process/account-balance-with-wasm")
                .join(fixture)
                .join("trace.json");
            let original = std::fs::read(&committed)
                .unwrap_or_else(|e| panic!("read {}: {e}", committed.display()));

            let records = split_top_level_records(&original);
            assert!(
                records.len() >= 15,
                "{fixture} should be a substantial recording; got {} records",
                records.len(),
            );

            let tmp = TempDir::new().expect("create tempdir");
            let out = tmp.path().join("reframed.json");
            {
                let mut stream = RecordStream::new(fs::File::create(&out).unwrap(), None);
                for record in &records {
                    stream.write_record(record).unwrap();
                }
                stream.close().unwrap();
            }
            let reframed = std::fs::read(&out).unwrap();
            assert_eq!(
                String::from_utf8_lossy(&reframed),
                String::from_utf8_lossy(&original),
                "reframing {fixture}'s records one at a time must reproduce the \
                 committed bytes exactly",
            );
        }
    }

    /// Split a compact JSON array into the byte ranges of its top-level
    /// elements, tracking string state so a `{`, `}` or `,` inside a string
    /// literal is not mistaken for structure.
    ///
    /// Deliberately dumb and self-contained: its whole job is to hand
    /// [`RecordStream`] the *original file's* bytes rather than anything
    /// this crate re-rendered.
    fn split_top_level_records(bytes: &[u8]) -> Vec<&[u8]> {
        assert_eq!(bytes.first(), Some(&b'['), "not a JSON array");
        assert_eq!(bytes.last(), Some(&b']'), "unterminated JSON array");
        let mut records = Vec::new();
        let mut depth = 0usize;
        let mut start = None;
        let mut in_string = false;
        let mut escaped = false;
        for (i, &b) in bytes.iter().enumerate().skip(1) {
            if in_string {
                match b {
                    _ if escaped => escaped = false,
                    b'\\' => escaped = true,
                    b'"' => in_string = false,
                    _ => {}
                }
                continue;
            }
            match b {
                b'"' => in_string = true,
                b'{' | b'[' => {
                    if depth == 0 {
                        start = Some(i);
                    }
                    depth += 1;
                }
                b'}' | b']' => {
                    if depth == 0 {
                        // The array's own closing bracket.
                        break;
                    }
                    depth -= 1;
                    if depth == 0 {
                        records.push(&bytes[start.take().unwrap()..=i]);
                    }
                }
                _ => {}
            }
        }
        assert_eq!(depth, 0, "unbalanced JSON");
        records
    }

    /// Byte identity across the *whole* writer for payloads whose JSON
    /// rendering is not the identity: quotes, backslashes, control
    /// characters, non-BMP text, and an unpaired surrogate.
    ///
    /// A record body that grows an escape is exactly where a hand-rolled
    /// framing could disagree with `serde_json` — the separator is written
    /// before a body whose length the writer never inspects — and it is
    /// also where a byte-count-based framing (which this deliberately is
    /// not) would go wrong.
    #[test]
    fn verify_byte_identity_survives_values_that_json_must_escape() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer.enable_batch_mirror();
        writer.session_start("escapes\"and\\slashes", &[]).unwrap();

        let hostile = [
            "a\"quoted\"name",
            "back\\slash",
            "line\nbreak\ttab\r\u{0}nul",
            "hé—日本語🎉",
            // A lone high surrogate: legal in a Rust string only as its
            // replacement, which is what a browser would deliver too, so
            // this pins the escape of U+FFFD rather than of \ud800.
            "lone\u{fffd}surrogate",
            "\u{7f}\u{1b}[0m",
        ];
        for (i, text) in hostile.iter().enumerate() {
            // Through a name (VariableName + Value), a String payload, a
            // Raw payload, a path, and an Event's metadata + content, so
            // every place a string reaches disk is covered.
            writer
                .event(&BrowserEvent::Path {
                    path_id: i as u32,
                    path: format!("src/{text}.js"),
                })
                .unwrap();
            writer
                .event(&BrowserEvent::Value {
                    name: (*text).to_string(),
                    value: EncodedValue {
                        value: serde_json::json!(text),
                        type_kind: "String".to_string(),
                    },
                })
                .unwrap();
            writer
                .event(&BrowserEvent::Value {
                    name: (*text).to_string(),
                    value: EncodedValue {
                        value: serde_json::json!({ *text: [text, 1] }),
                        type_kind: "Object".to_string(),
                    },
                })
                .unwrap();
            writer
                .event(&BrowserEvent::Write {
                    channel: (*text).to_string(),
                    content: (*text).to_string(),
                })
                .unwrap();
        }
        let trace_dir = writer.session_end().unwrap();

        let incremental = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
        let batch = serde_json::to_string(writer.batch_mirror.as_ref().unwrap()).unwrap();
        assert_eq!(incremental, batch);
        // The escapes really did reach the file, so the comparison is not
        // vacuous.
        assert!(incremental.contains("\\\""), "{incremental}");
        assert!(incremental.contains("\\\\"), "{incremental}");
        assert!(incremental.contains("\\n"), "{incremental}");
        assert!(incremental.contains("\\t"), "{incremental}");
        assert!(incremental.contains("\\u0000"), "{incremental}");
        assert!(incremental.contains("\\u001b"), "{incremental}");
        assert!(incremental.contains('\u{1F389}'), "{incremental}");
        // And the second sighting of each name minted no second
        // `VariableName`, so the positional table stayed put.
        let records: Vec<serde_json::Value> = serde_json::from_str(&incremental).unwrap();
        let names = records
            .iter()
            .filter(|r| r.get("VariableName").is_some())
            .count();
        assert_eq!(names, hostile.len(), "one VariableName per distinct name");
    }

    /// A session whose paths, variables and functions are all re-seen many
    /// times must intern each exactly once, in first-seen order, and still
    /// render byte-identically.
    ///
    /// The interning tables are what the format's positional lookups
    /// resolve against, so a duplicate — or a reordering — silently
    /// renumbers every later reference. The batch comparison alone cannot
    /// catch that (both sides see the same records), so the counts are
    /// asserted directly.
    #[test]
    fn verify_repeated_interning_emits_one_record_each_in_first_seen_order() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer.enable_batch_mirror();
        writer
            .manifest(&serde_json::json!({
                "paths": ["a.js", "b.js"],
                "functions": [
                    {"name": "f", "pathIndex": 0, "line": 1},
                    {"name": "g", "pathIndex": 1, "line": 2},
                ],
                "sites": [
                    {"pathIndex": 0, "line": 3, "target": "x"},
                    {"pathIndex": 1, "line": 4, "target": "y"},
                ],
            }))
            .unwrap();
        writer.session_start("repeats", &[]).unwrap();
        for _ in 0..25 {
            for site in 0..2u32 {
                writer
                    .event(&BrowserEvent::Assignment {
                        site_id: site,
                        value: Some(EncodedValue {
                            value: serde_json::json!(site),
                            type_kind: "Int".to_string(),
                        }),
                    })
                    .unwrap();
            }
            for fn_id in 0..2u32 {
                writer
                    .event(&BrowserEvent::Call {
                        fn_id,
                        args: vec![],
                    })
                    .unwrap();
            }
        }
        let trace_dir = writer.session_end().unwrap();

        let incremental = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
        assert_eq!(
            incremental,
            serde_json::to_string(writer.batch_mirror.as_ref().unwrap()).unwrap(),
        );

        let records: Vec<serde_json::Value> = serde_json::from_str(&incremental).unwrap();
        let of_kind = |kind: &str| -> Vec<serde_json::Value> {
            records
                .iter()
                .filter_map(|r| r.get(kind).cloned())
                .collect()
        };
        assert_eq!(
            of_kind("Path"),
            vec![serde_json::json!("a.js"), serde_json::json!("b.js")],
            "each path interned once, in first-seen order",
        );
        assert_eq!(
            of_kind("VariableName"),
            vec![serde_json::json!("x"), serde_json::json!("y")],
        );
        assert_eq!(of_kind("Function").len(), 2, "one Function record each");
        // And the paths file agrees with the Path records' positions,
        // because a Step's `path_id` indexes it.
        let paths: Vec<String> =
            serde_json::from_str(&std::fs::read_to_string(trace_dir.join("trace_paths.json")).unwrap())
                .unwrap();
        assert_eq!(paths, vec!["a.js".to_string(), "b.js".to_string()]);
    }

    /// `trace_metadata.json` and `trace_paths.json` are written twice — once
    /// when the stream opens, so a concurrently-spawned consumer finds a
    /// program name, and again at session end. Their *final* bytes must be
    /// what a single write at session end would have produced, or the early
    /// write is a regression rather than an addition.
    #[test]
    fn verify_the_metadata_and_paths_files_end_where_the_single_write_left_them() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        let workdir = tmp.path().to_path_buf();
        writer
            .session_start("meta", &["--a".to_string(), "b c".to_string()])
            .unwrap();
        let trace_dir = drive(
            &mut writer,
            &wide_event_sequence()
                .into_iter()
                .filter(|e| !matches!(e, BrowserEvent::SessionStart { .. }))
                .collect::<Vec<_>>(),
        )
        .expect("session ends");

        // Reference side: rendered exactly as the removed `flush` did.
        #[derive(Serialize)]
        struct Reference {
            program: String,
            args: Vec<String>,
            workdir: String,
            recorder: TraceMetadataRecorder,
        }
        let expected_metadata = serde_json::to_string(&Reference {
            program: "meta".to_string(),
            args: vec!["--a".to_string(), "b c".to_string()],
            workdir: workdir.to_string_lossy().into_owned(),
            recorder: TraceMetadataRecorder {
                name: "codetracer-js-recorder-browser".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
        })
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(trace_dir.join("trace_metadata.json")).unwrap(),
            expected_metadata,
        );

        // The paths file must list every interned path, in order, and
        // nothing else — the early write must not have left a short list.
        let recorded: Vec<serde_json::Value> = serde_json::from_str(
            &std::fs::read_to_string(trace_dir.join("trace.json")).unwrap(),
        )
        .unwrap();
        let path_records: Vec<String> = recorded
            .iter()
            .filter_map(|r| r.get("Path")?.as_str().map(str::to_string))
            .collect();
        let paths_file: Vec<String> = serde_json::from_str(
            &std::fs::read_to_string(trace_dir.join("trace_paths.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(paths_file, path_records);
        assert_eq!(
            paths_file,
            serde_json::from_str::<Vec<String>>(
                &serde_json::to_string(&path_records).unwrap()
            )
            .unwrap(),
        );
    }

    /// `trace.json` must be readable *while* the session is still open —
    /// that is the whole point of M38c, and it is what
    /// `boundarylog.FollowFile` and the `--boundary-stream -` tee both
    /// need. Before the change the file did not exist until the page
    /// unloaded.
    #[test]
    fn verify_records_are_on_disk_before_session_end() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut writer =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        writer.session_start("live", &[]).unwrap();
        let trace_json = tmp.path().join("live.ct").join("trace.json");
        assert!(
            !trace_json.exists(),
            "no record has arrived yet, so nothing should be on disk",
        );

        let mut seen = Vec::new();
        for site_id in 0..5u32 {
            writer.event(&BrowserEvent::Step { site_id }).unwrap();
            let bytes = std::fs::read_to_string(&trace_json)
                .expect("trace.json must exist and be readable mid-session");
            // The array is still open, so the prefix cannot be parsed as
            // one; closing it must yield exactly the records so far.
            let records: Vec<serde_json::Value> =
                serde_json::from_str(&format!("{bytes}]")).expect("a complete record prefix");
            seen.push(records.len());
        }
        // The `<browser>` Path record precedes the first Step, so the
        // counts are 2,3,4,5,6 — strictly growing with every event, which
        // is what "the consumer can act on record k before record k+1 is
        // produced" requires.
        assert_eq!(seen, vec![2, 3, 4, 5, 6], "records must land one by one");
        assert!(!writer.session_ended);
    }

    /// A recording cut off mid-session must be *classifiable* by
    /// `codetracer-wasm-recorder/internal/boundarylog/stream.go`'s
    /// three-way truncation logic, not corrupt.
    ///
    /// The benign classification, `TruncatedUnterminated`, requires the
    /// file to hold whole records and no closing `]` — i.e. zero pending
    /// bytes of a partial object, which is what `RecordStream`'s
    /// one-`write_all`-per-record buys. `TruncatedMidRecord` is the
    /// outcome this test exists to rule out.
    #[test]
    fn verify_a_killed_session_leaves_a_stream_the_consumer_can_classify() {
        let tmp = TempDir::new().expect("create tempdir");
        let trace_json = tmp.path().join("frontend.ct").join("trace.json");
        {
            let mut writer =
                JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
            // Stop short of `SessionEnd`: the page was killed, not unloaded.
            let events = wide_event_sequence();
            let truncated: Vec<BrowserEvent> = events
                .into_iter()
                .filter(|e| !matches!(e, BrowserEvent::SessionEnd {}))
                .collect();
            assert!(drive(&mut writer, &truncated).is_none());
            assert!(!writer.session_ended, "the session never ended cleanly");
            // Dropping the writer without `session_end` is the crash.
        }

        let bytes = std::fs::read_to_string(&trace_json).expect("a partial recording on disk");
        assert!(
            bytes.starts_with('['),
            "the array must have been opened: {bytes}",
        );
        assert!(
            !bytes.ends_with(']'),
            "an interrupted recording must NOT look complete: {bytes}",
        );
        // `stream.go`'s scanner tracks brace depth: it reports pending
        // bytes unless the last thing in the file is a finished object.
        assert!(
            bytes.ends_with('}'),
            "the last bytes must be a whole record, or the consumer classifies \
             this TruncatedMidRecord instead of the benign TruncatedUnterminated: {bytes}",
        );
        let records: Vec<serde_json::Value> = serde_json::from_str(&format!("{bytes}]"))
            .expect("every record present must be complete");
        assert!(records.len() > 10, "expected a substantial prefix");
    }

    /// The `--stream-done` marker: created at session end, and only when
    /// asked for. It must not appear in a default recording, because it
    /// would then land in every committed `.ct` fixture.
    #[test]
    fn verify_the_stream_done_marker_is_opt_in_and_lands_last() {
        let tmp = TempDir::new().expect("create tempdir");
        let mut plain =
            JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf());
        plain.session_start("plain", &[]).unwrap();
        let plain_dir = plain.session_end().unwrap();
        assert!(!plain_dir.join(".complete").exists(), "marker is opt-in");

        let marked_tmp = TempDir::new().expect("create tempdir");
        let mut marked = JsonFileCtfsWriter::with_stream_consumer(
            marked_tmp.path().to_path_buf(),
            marked_tmp.path().to_path_buf(),
            StreamConsumerConfig {
                command: Vec::new(),
                done_marker: Some(".complete".to_string()),
            },
        );
        marked.session_start("marked", &[]).unwrap();
        marked.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let marked_dir = marked_tmp.path().join("marked.ct");
        assert!(
            !marked_dir.join(".complete").exists(),
            "the marker means `trace.json` is final; it must not exist mid-session",
        );
        assert_eq!(marked.session_end().unwrap(), marked_dir);
        assert!(marked_dir.join(".complete").is_file());
        // The marker's promise: by the time it exists, the array is closed.
        let bytes = std::fs::read_to_string(marked_dir.join("trace.json")).unwrap();
        assert!(bytes.ends_with(']'), "{bytes}");
    }

    /// The tee: a real spawned child process receives the exact
    /// `trace.json` bytes, and receives them *during* the session rather
    /// than in a dump at the end.
    ///
    /// The stand-in consumer is `sh -c 'cat > <file>'` rather than
    /// `wazero-snapshots`: what the daemon owes the §2 consumer is the
    /// byte stream on stdin, live, and that is exactly what this measures.
    /// The consumer's own half — turning those bytes into snapshots and
    /// slices while the stream is still arriving — is pinned in
    /// `codetracer-wasm-recorder` by
    /// `TestSnapshotsAreEmittedWhileTheStreamIsStillArriving`.
    #[test]
    fn verify_the_tee_feeds_a_real_child_process_during_the_session() {
        let tmp = TempDir::new().expect("create tempdir");
        let sink = tmp.path().join("teed.json");
        let mut writer = JsonFileCtfsWriter::with_stream_consumer(
            tmp.path().to_path_buf(),
            tmp.path().to_path_buf(),
            StreamConsumerConfig {
                command: vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    // `{trace_dir}` substitution is exercised too: the
                    // consumer is told which recording it is reading.
                    format!(
                        "test -d '{}' && exec cat > '{}'",
                        TRACE_DIR_PLACEHOLDER,
                        sink.display()
                    ),
                ],
                done_marker: None,
            },
        );
        writer.session_start("teed", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();

        // Mid-session: the child must already hold the bytes. `cat` is
        // block-buffered on a pipe, so wait for it to flush rather than
        // assuming a size.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let mut teed = String::new();
        while std::time::Instant::now() < deadline {
            teed = std::fs::read_to_string(&sink).unwrap_or_default();
            if !teed.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            teed.starts_with('['),
            "the tee must reach a real child process while the session is live; got {teed:?}",
        );
        assert!(!writer.session_ended, "the session is still open");

        let trace_dir = writer.session_end().unwrap();
        // `session_end` closes the pipe and reaps the child, so the sink is
        // complete by the time it returns — no polling needed here.
        let teed = std::fs::read_to_string(&sink).unwrap();
        let recorded = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
        assert_eq!(
            teed, recorded,
            "the consumer must see exactly the recording's bytes",
        );
    }

    /// A consumer that cannot be spawned, or that dies early, costs seek
    /// performance and nothing else — the recording must be complete and
    /// correct either way (spec §2: the recording is the source of truth,
    /// snapshots are derived data).
    #[test]
    fn verify_a_broken_consumer_does_not_cost_the_recording() {
        for command in [
            vec!["definitely-not-a-real-binary-38c".to_string()],
            // Exits immediately, so every write after the first hits a
            // closed pipe (EPIPE).
            vec!["sh".to_string(), "-c".to_string(), "exit 0".to_string()],
        ] {
            let tmp = TempDir::new().expect("create tempdir");
            let mut writer = JsonFileCtfsWriter::with_stream_consumer(
                tmp.path().to_path_buf(),
                tmp.path().to_path_buf(),
                StreamConsumerConfig {
                    command,
                    done_marker: None,
                },
            );
            writer.enable_batch_mirror();
            let trace_dir = drive(&mut writer, &wide_event_sequence()).expect("session ends");
            let recorded = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
            assert_eq!(
                recorded,
                serde_json::to_string(writer.batch_mirror.as_ref().unwrap()).unwrap(),
                "a broken consumer must not perturb the recording",
            );
        }
    }

    /// End-to-end smoke: spin up the host, connect a real WebSocket
    /// client, ship a 5-event session, observe the `.ct` directory on
    /// disk.  This is the M26 acceptance criterion the milestone called
    /// out (5 dummy events → valid `.ct` file lands).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn smoke_end_to_end_records_five_events_to_ct_file() {
        use futures_util::SinkExt;

        let tmp = TempDir::new().expect("create tempdir");
        let config = BrowserStreamHostConfig {
            bind: "127.0.0.1:0".parse().unwrap(),
            out_dir: tmp.path().to_path_buf(),
            workdir: tmp.path().to_path_buf(),
            stream_consumer: StreamConsumerConfig::default(),
        };
        let host = BrowserStreamHost::new(config);
        let running = host.bind().await.expect("bind");
        let url = format!("ws://{}/ct-stream", running.local_addr);
        let (mut ws, _resp) = tokio_tungstenite::connect_async(&url)
            .await
            .expect("connect");
        // Ship the session in one batch — newline-delimited JSON.
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
        tokio::time::sleep(Duration::from_millis(150)).await;
        running.stop().await.expect("stop");

        let trace_dir = tmp.path().join("smoke.ct");
        assert!(
            trace_dir.is_dir(),
            "expected trace directory at {trace_dir:?}; entries: {:?}",
            std::fs::read_dir(tmp.path())
                .unwrap()
                .filter_map(|e| e.ok().map(|e| e.path()))
                .collect::<Vec<_>>(),
        );
        let trace_json = std::fs::read_to_string(trace_dir.join("trace.json")).unwrap();
        let arr: Vec<serde_json::Value> = serde_json::from_str(&trace_json).unwrap();
        assert!(
            arr.iter().any(|e| e.get("Step").is_some()),
            "expected at least one Step event in trace.json: {arr:?}",
        );
        assert!(
            arr.iter().any(|e| e.get("Value").is_some()),
            "expected at least one Value event in trace.json: {arr:?}",
        );
        let metadata_json = std::fs::read_to_string(trace_dir.join("trace_metadata.json")).unwrap();
        let metadata: serde_json::Value = serde_json::from_str(&metadata_json).unwrap();
        assert_eq!(metadata["program"], "smoke");
    }
}

// ---------------------------------------------------------------------------
// Host-supplied state sidecar (spec §§3.3, 3.4)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod host_state_tests {
    use super::*;
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

    fn writer_in(tmp: &TempDir) -> JsonFileCtfsWriter {
        JsonFileCtfsWriter::new(tmp.path().to_path_buf(), tmp.path().to_path_buf())
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

    #[test]
    fn host_state_events_land_in_the_sidecar_in_the_consumers_schema() {
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
        let dir = writer.session_end().unwrap();

        let raw = std::fs::read_to_string(dir.join("boundary_state.json"))
            .expect("boundary_state.json must be written");
        let doc: serde_json::Value = serde_json::from_str(&raw).unwrap();

        // Field-for-field against `hoststate.go`'s `HostState`.
        assert_eq!(doc["version"], 1);
        assert_eq!(doc["initial"]["tables"], serde_json::json!([]));
        let mem = &doc["initial"]["memories"][0];
        assert_eq!(mem["module"], "env");
        assert_eq!(mem["name"], "memory");
        assert_eq!(mem["minPages"], 17);
        assert_eq!(mem["maxPages"], serde_json::Value::Null);
        assert_eq!(mem["data"][0]["offset"], 1_048_576);
        assert_eq!(mem["data"][0]["bytesB64"], "BwAAAGQ=");
        let g = &doc["initial"]["globals"][0];
        assert_eq!(g["type"], "i32");
        assert_eq!(g["mutable"], true);
        assert_eq!(g["value"], "25");
        let mu = &doc["mutations"][0];
        assert_eq!(mu["afterCrossing"], 1);
        assert_eq!(mu["memoryWrites"][0]["offset"], 1_048_584);
        assert_eq!(mu["memoryWrites"][0]["bytesB64"], "+g==");
        assert_eq!(mu["globalSets"][0]["value"], "250");
    }

    #[test]
    fn host_state_events_add_nothing_to_the_trace_stream() {
        // The sidecar describes the module's starting state, not a step.
        // A record in `trace.json` would have to be skipped by the
        // boundary-log assembler, and every `Function` / `VariableName` /
        // `Path` index downstream of it is positional.
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let dir = {
            writer
                .event(&parse_event_line(INITIAL_LINE).unwrap())
                .unwrap();
            writer
                .event(&parse_event_line(MUTATION_LINE).unwrap())
                .unwrap();
            writer.session_end().unwrap()
        };
        let with_state = std::fs::read_to_string(dir.join("trace.json")).unwrap();

        let tmp2 = TempDir::new().unwrap();
        let mut plain = writer_in(&tmp2);
        plain.session_start("frontend-wasm", &[]).unwrap();
        plain.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let dir2 = plain.session_end().unwrap();
        let without_state = std::fs::read_to_string(dir2.join("trace.json")).unwrap();

        assert_eq!(
            with_state, without_state,
            "host-state events must not change trace.json by one byte"
        );
    }

    #[test]
    fn a_recording_with_no_host_state_writes_no_sidecar() {
        // The consumer reads a missing file as "this module defines its
        // own memory and globals", which is the truth for almost every
        // module; an empty sidecar would say the same thing less clearly.
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        let dir = writer.session_end().unwrap();
        assert!(!dir.join("boundary_state.json").exists());
    }

    #[test]
    fn the_sidecar_is_readable_while_the_recording_is_still_running() {
        // M38c made `trace.json` incremental so a consumer can replay a
        // recording as it arrives.  A sidecar that only appeared at
        // session end would be useless to that consumer, since §3.3 state
        // has to be applied *before* the first exported call.
        let tmp = TempDir::new().unwrap();
        let mut writer = writer_in(&tmp);
        writer.session_start("frontend-wasm", &[]).unwrap();
        writer.event(&BrowserEvent::Step { site_id: 0 }).unwrap();
        writer
            .event(&parse_event_line(INITIAL_LINE).unwrap())
            .unwrap();

        let dir = tmp.path().join("frontend-wasm.ct");
        let raw = std::fs::read_to_string(dir.join("boundary_state.json"))
            .expect("the sidecar must exist before session_end");
        let doc: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(doc["initial"]["memories"][0]["minPages"], 17);
        assert_eq!(doc["mutations"], serde_json::json!([]));

        writer.session_end().unwrap();
    }

    #[test]
    fn mutations_keep_the_order_the_page_reported_them_in() {
        // `MutationsFor(seq)` selects by anchor, but two mutations
        // anchored to the same crossing are applied in file order, so the
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
        let dir = writer.session_end().unwrap();
        let doc: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("boundary_state.json")).unwrap(),
        )
        .unwrap();
        let anchors: Vec<u64> = doc["mutations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["afterCrossing"].as_u64().unwrap())
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
        let dir = writer.session_end().unwrap();
        let doc: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(dir.join("boundary_state.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(doc["initial"]["memories"][0]["minPages"], 17);
    }
}
