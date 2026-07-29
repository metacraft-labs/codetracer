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
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;
use serde::Serialize;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;

use crate::browser_stream_receiver::{
    BrowserEvent, CtfsWriter, EncodedValue, StreamReceiver, default_output_path,
};

/// Default listen address.  Matches the URL the browser runtime ships to
/// (`ws://localhost:9230/ct-stream`).
pub const DEFAULT_BIND: &str = "127.0.0.1:9230";

/// Default endpoint path advertised on the server side.  Connections to
/// any other path are accepted but the server logs a warning — the path
/// is informational only.
pub const DEFAULT_ENDPOINT_PATH: &str = "/ct-stream";

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
    let writer_handle = Arc::new(Mutex::new(JsonFileCtfsWriter::new(
        config.out_dir.clone(),
        config.workdir.clone(),
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
    /// Events accumulated since `session_start`.  Held in memory until
    /// `session_end` because the legacy JSON format is the JSON
    /// serialisation of a single `Vec` (not a stream of NDJSON lines).
    /// The Nim multi-stream / CTFS writer streams; a follow-on can swap
    /// in that writer to reclaim constant-memory behaviour.
    events: Vec<TraceLowLevelEvent>,
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
        Self {
            out_dir,
            workdir,
            program: String::new(),
            args: Vec::new(),
            events: Vec::new(),
            path_index: indexmap_compat::OrderedSet::new(),
            fn_table: indexmap_compat::OrderedMap::new(),
            session_ended: false,
            last_output_path: None,
            var_index: indexmap_compat::OrderedSet::new(),
            manifest: None,
        }
    }

    /// Resolve a variable name to its on-disk id, registering it on
    /// first sight.
    fn intern_variable(&mut self, name: &str) -> u32 {
        let (idx, inserted) = self.var_index.insert_full(name.to_string());
        if inserted {
            self.events
                .push(TraceLowLevelEvent::VariableName(name.to_string()));
        }
        idx as u32
    }

    /// Resolve a manifest site id to its `(path_id, line)` pair,
    /// interning the source path on first sight.
    ///
    /// Returns `None` when no manifest was forwarded or the id is out of
    /// range, in which case callers fall back to the `<browser>`
    /// placeholder so a manifest-less runtime still produces a readable
    /// (if source-less) trace rather than failing the recording.
    fn resolve_site(&mut self, site_id: u32) -> Option<(u32, i64)> {
        let (path, line) = {
            let manifest = self.manifest.as_ref()?;
            let site = manifest.sites.get(site_id as usize)?;
            let path = manifest.paths.get(site.path_index)?.clone();
            (path, site.line)
        };
        Some((self.intern_path(&path), line))
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
    fn resolve_function(&mut self, fn_id: u32) -> Option<(String, u32, i64)> {
        let (name, path, line) = {
            let manifest = self.manifest.as_ref()?;
            let function = manifest.functions.get(fn_id as usize)?;
            let path = manifest.paths.get(function.path_index)?.clone();
            (function.name.clone(), path, function.line)
        };
        Some((name, self.intern_path(&path), line))
    }

    /// Resolve a runtime-side path string to a canonical `path_id`,
    /// interning the path if it has not been seen yet.  Mirrors
    /// `NonStreamingTraceWriter::ensure_path_id`.
    fn intern_path(&mut self, path: &str) -> u32 {
        let path_buf = PathBuf::from(path);
        let (idx, inserted) = self.path_index.insert_full(path_buf.clone());
        if inserted {
            self.events.push(TraceLowLevelEvent::Path(
                path_buf.to_string_lossy().into_owned(),
            ));
        }
        idx as u32
    }

    /// Translate a [`BrowserEvent`] into one or more on-disk
    /// `TraceLowLevelEvent`s.  Some browser events expand to multiple
    /// disk events (e.g. a `Call` may emit a synthetic `Function` record
    /// the first time its `fnId` is seen).
    fn translate(&mut self, event: &BrowserEvent) {
        match event {
            BrowserEvent::Path { path_id: _, path } => {
                // The runtime's path_id is opaque; we re-intern through
                // our own table so the on-disk indices stay dense and
                // start at 0.  The runtime's path_id is dropped (it has
                // no consumer on the disk side).
                self.intern_path(path);
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
                let (path_id, line) = self
                    .resolve_site(*site_id)
                    .unwrap_or_else(|| (self.ensure_default_path(), i64::from(*site_id)));
                self.events
                    .push(TraceLowLevelEvent::Step(StepRecord { path_id, line }));
            }
            BrowserEvent::Assignment { site_id, value } => {
                // Same position resolution as Step — an assignment site is
                // a step site with write metadata attached.
                let (path_id, line) = self
                    .resolve_site(*site_id)
                    .unwrap_or_else(|| (self.ensure_default_path(), i64::from(*site_id)));
                self.events
                    .push(TraceLowLevelEvent::Step(StepRecord { path_id, line }));
                // Bind the value to its name so the recording carries
                // variables, not just positions. A trace that records
                // where execution went but not what it produced cannot
                // answer any question about a value — including where it
                // came from.
                if let (Some(target), Some(value)) = (self.site_target(*site_id), value.as_ref()) {
                    let variable_id = self.intern_variable(&target);
                    self.events
                        .push(TraceLowLevelEvent::Value(FullValueRecordOnDisk {
                            variable_id,
                            value: translate_value(value),
                        }));
                }
            }
            BrowserEvent::Call { fn_id, args } => {
                let function_id = self.ensure_function_id(*fn_id);
                let translated_args: Vec<FullValueRecordOnDisk> = args
                    .iter()
                    .enumerate()
                    .map(|(i, v)| FullValueRecordOnDisk {
                        variable_id: i as u32,
                        value: translate_value(v),
                    })
                    .collect();
                self.events.push(TraceLowLevelEvent::Call(CallRecord {
                    function_id,
                    args: translated_args,
                }));
            }
            BrowserEvent::Return {
                fn_id: _,
                return_value,
            } => {
                self.events.push(TraceLowLevelEvent::Return(ReturnRecord {
                    return_value: translate_value(return_value),
                }));
            }
            BrowserEvent::Value { name, value } => {
                let variable_id = self.intern_variable(name);
                self.events
                    .push(TraceLowLevelEvent::Value(FullValueRecordOnDisk {
                        variable_id,
                        value: translate_value(value),
                    }));
            }
            BrowserEvent::Write { channel, content } => {
                self.events.push(TraceLowLevelEvent::Event(RecordEvent {
                    kind: write_channel_to_kind(channel),
                    metadata: channel.clone(),
                    content: content.clone(),
                }));
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
                self.events.push(TraceLowLevelEvent::Event(RecordEvent {
                    kind: EVENT_KIND_TRACE_LOG_EVENT,
                    metadata,
                    content,
                }));
            }
            // Lifecycle events are handled in the trait impls below.
            BrowserEvent::SessionStart { .. }
            | BrowserEvent::Manifest { .. }
            | BrowserEvent::SessionEnd {} => {}
        }
    }

    /// Resolve the runtime's `fn_id` to a canonical on-disk function id.
    /// The browser runtime currently does not ship a separate `Function`
    /// event before the first `Call`, so we synthesise one on first
    /// sight with placeholder name / path / line — the manifest carries
    /// the real values in V1+ and the synthesised record is overwritten
    /// at trace open time.
    fn ensure_function_id(&mut self, fn_id: u32) -> u32 {
        // Prefer the manifest's real `(name, path, line)`; fall back to
        // a synthesised record when no manifest was forwarded.
        let (name, path_id, line) = self
            .resolve_function(fn_id)
            .unwrap_or_else(|| (format!("fn_{fn_id}"), self.ensure_default_path(), 0));
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
            // caller `translate` pushes the Call afterwards.
            self.events
                .push(TraceLowLevelEvent::Function(FunctionRecord {
                    name,
                    path_id,
                    line,
                }));
        }
        assigned
    }

    /// Lazily register the placeholder path used for Step / Assignment
    /// events until the manifest forwarding lands.  Returns the canonical
    /// path_id.
    fn ensure_default_path(&mut self) -> u32 {
        // `<browser>` is the marker the db-backend recognises as
        // "browser recording, manifest not yet forwarded" — same string
        // convention as the existing `<unknown>` sentinel for the JS
        // recorder.  Lives in path index 0 by construction.
        self.intern_path("<browser>")
    }

    /// Materialise the buffered events to disk.  Idempotent; subsequent
    /// calls are no-ops once `session_ended` is true.
    fn flush(&mut self) -> io::Result<PathBuf> {
        if self.session_ended {
            return Ok(self
                .last_output_path
                .clone()
                .unwrap_or_else(|| self.out_dir.clone()));
        }
        let program_name = if self.program.is_empty() {
            "browser".to_string()
        } else {
            self.program.clone()
        };
        // `default_output_path` returns `<out_dir>/<safe-program>.ct` —
        // sanitises the program name so untrusted page titles cannot
        // traverse the directory layout.
        let trace_file = default_output_path(&self.out_dir, &program_name);
        // The .ct artefact in M26 V1 is a *directory* (legacy JSON
        // shape), so `.ct` here is the directory name.
        let trace_dir = trace_file;
        fs::create_dir_all(&trace_dir)?;

        let events_path = trace_dir.join("trace.json");
        let metadata_path = trace_dir.join("trace_metadata.json");
        let paths_path = trace_dir.join("trace_paths.json");

        let events_json = serde_json::to_string(&self.events)
            .map_err(|e| io::Error::other(format!("events serialisation: {e}")))?;
        fs::write(&events_path, events_json)?;

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
        fs::write(&metadata_path, metadata_json)?;

        // The paths file is the registration-order list of source paths.
        let paths: Vec<String> = self
            .path_index
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let paths_json = serde_json::to_string(&paths)
            .map_err(|e| io::Error::other(format!("paths serialisation: {e}")))?;
        fs::write(&paths_path, paths_json)?;

        self.session_ended = true;
        self.last_output_path = Some(trace_dir.clone());
        Ok(trace_dir)
    }
}

impl CtfsWriter for JsonFileCtfsWriter {
    fn session_start(&mut self, program: &str, args: &[String]) -> io::Result<()> {
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
        self.translate(event);
        Ok(())
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
