use indexmap::IndexMap;
use log::{debug, error, info, warn};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::Sender;

use codetracer_trace_types::{
    CallKey, EventLogKind, FullValueRecord, Line, NO_KEY, PathId, StepId, TypeKind, VariableId,
};

use crate::calltrace::Calltrace;
use crate::dap::{self, DapClient, DapMessage};
use crate::db::{Db, DbCall, DbRecordEvent, MaterializedReplaySession};
use crate::event_db::{EventDb, SingleTableId};
use crate::expr_loader::ExprLoader;
use crate::flow_preloader::FlowPreloader;
use crate::in_memory_trace_reader::InMemoryTraceReader;
use crate::lang::{Lang, lang_from_context};
use crate::macro_sourcemap::{self, MacroSourceMapCollection, UpdateExpansionArgs};
use crate::program_search_tool::ProgramSearchTool;
use crate::recreator_session::{RecreatorArgs, RecreatorReplaySession};
use crate::replay::ReplaySession;
use crate::sourcemap_cache::{SourcemapCache, TranslatedLocation, translation_enabled};
use crate::trace_reader::TraceReader;
// use crate::response::{};
use crate::dap_types;
// use crate::dap_types::Source;
use crate::step_lines_loader::StepLinesLoader;
use crate::task::{self, Breakpoint, GlobalCallLineIndex, HistoryResult, StringAndValueTuple, TraceKind};
use crate::task::{
    Action, Call, CallArgsUpdateResults, CallLine, CallLineContentKind, CallSearchArg, CalltraceLoadArgs,
    CalltraceNonExpandedKind, CollapseCallsArgs, CoreTrace, CtLoadFlowArguments, DbEventKind, FlowMode, FlowUpdate,
    FrameInfo, FunctionLocation, GoToTicksArguments, HistoryUpdate, Instruction, Instructions, LoadHistoryArg,
    LoadStepLinesArg, LoadStepLinesUpdate, LocalStepJump, Location, MoveState, NO_ADDRESS, NO_INDEX, NO_PATH,
    NO_POSITION, NO_STEP_ID, Notification, NotificationKind, ProgramEvent, RRGDBStopSignal, RRTicks, RegisterEventsArg,
    RunTracepointsArg, SourceCallJumpTarget, SourceLocation, StepArg, Stop, StopType, Task, TraceUpdate, TracepointId,
    TracepointResults, TracepointResultsAggregate, UpdateTableArgs, Variable,
};
use crate::tracepoint_interpreter::TracepointInterpreter;
use crate::value::{Type, Value, to_ct_value};

const TRACEPOINT_RESULTS_LIMIT_BEFORE_UPDATE: usize = 5;

/// Resolve the personal-overrides path for origin patterns per spec §7.4.
///
/// Honours `$XDG_CONFIG_HOME` when set; otherwise falls back to
/// `$HOME/.config/codetracer/origin-patterns.toml`. Returns `None` only
/// when neither variable is set (an unusual hermetic environment) — in
/// every other case we return a path, and the caller is responsible for
/// gating on `.exists()`.
fn personal_origin_patterns_path() -> Option<std::path::PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return Some(
            std::path::PathBuf::from(xdg)
                .join("codetracer")
                .join("origin-patterns.toml"),
        );
    }
    if let Ok(home) = std::env::var("HOME")
        && !home.is_empty()
    {
        return Some(
            std::path::PathBuf::from(home)
                .join(".config")
                .join("codetracer")
                .join("origin-patterns.toml"),
        );
    }
    None
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McrLiveStepArguments {
    pub action: String,
    #[serde(default)]
    pub thread_id: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McrRestoreAtArguments {
    #[serde(alias = "rr_ticks")]
    pub rr_ticks: u64,
    #[serde(default)]
    pub jump_to_live: bool,
}

#[derive(Debug, Deserialize)]
pub struct SeekToGeidArguments {
    pub geid: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordingHeadResponse {
    rr_ticks: u64,
    recording_head: u64,
    head: u64,
}

#[derive(Debug)]
pub struct Handler {
    /// Abstracted read-only access to trace data.
    ///
    /// Shared via `Arc` so that `MaterializedReplaySession` (and other consumers) can hold
    /// a reference to the same reader without cloning the underlying data.
    pub reader: Arc<dyn TraceReader>,
    pub step_id: StepId,
    pub last_location: Location,
    // pub sender_tx: mpsc::Sender<Response>,
    pub indirect_send: bool,
    // pub sender: sender::Sender,
    pub event_db: EventDb,
    pub flow_preloader: FlowPreloader,
    pub expr_loader: ExprLoader,
    pub calltrace: Calltrace,
    pub step_lines_loader: StepLinesLoader,
    pub trace: CoreTrace,
    pub dap_client: DapClient,
    pub resulting_dap_messages: Vec<DapMessage>,
    pub raw_diff_index: Option<String>,
    pub previous_step_id: StepId,
    /// Per-source breakpoint registry keyed by `(path, line, column)`.
    ///
    /// M1 extends the legacy `(path, line)` key with an optional
    /// column so multiple statements that share a line (the headline
    /// minified-JS case) can each carry their own breakpoint.  A
    /// `column = None` entry preserves the legacy line-only behaviour
    /// — DAP clients that omit `column` continue to stop at the start
    /// of the line.
    pub breakpoints: HashMap<(String, i64, Option<i64>), Vec<Breakpoint>>,

    pub trace_kind: TraceKind,
    pub replay: Box<dyn ReplaySession>,
    pub ct_rr_args: RecreatorArgs,
    pub load_flow_index: usize,
    pub tracepoint_rr_worker_index: usize,

    pub initialized: bool,

    /// Cached list of all program events loaded from the trace.
    ///
    /// Populated on the first `ct/event-load` request and reused for
    /// subsequent paginated requests so that `replay.load_events()` is
    /// only called once.  This avoids the >30s timeout that occurs when
    /// every `ct/py-events` request re-reads all events from disk.
    cached_events: Option<Vec<ProgramEvent>>,

    /// Cached list of terminal-output (Write) events, populated lazily by
    /// `load_terminal()`.
    ///
    /// When `load_terminal()` is called before `ensure_events_loaded()`,
    /// this cache is filled by scanning `reader.events()` for Write
    /// records only -- much faster than loading all events into memory first.
    /// When `cached_events` is already populated, Write events are extracted
    /// from it instead.
    cached_terminal_events: Option<Vec<ProgramEvent>>,

    /// Macro sourcemaps loaded from the trace directory.
    /// Used for resolving macro expansion locations (ALT+E shortcut).
    pub macro_sourcemaps: MacroSourceMapCollection,

    /// Per-trace Source Map V3 cache.
    ///
    /// Populated lazily at trace-open time by [`Handler::load_sourcemaps`]:
    /// for every recorded source path that has either a sibling
    /// `<path>.map` file or a `//# sourceMappingURL=` comment, the
    /// parsed [`sourcemap_translate::SourcemapIndex`] is cached here
    /// keyed by `PathId`. The DAP `stackTrace` handler consults this
    /// cache to translate recorded minified `(file, line, column)`
    /// coordinates back to the original source.
    ///
    /// Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P3.
    pub sourcemap_cache: SourcemapCache,

    /// Optional cache directory the sourcemap translator writes
    /// materialised inline `sourcesContent` to.  Populated by
    /// [`Handler::load_sourcemaps`] with the trace directory path so
    /// the original (unminified) source files land alongside the
    /// trace data.  `None` when the trace was opened without a
    /// filesystem path (e.g. WASM/VFS replay).
    pub sourcemap_cache_dir: Option<std::path::PathBuf>,

    /// Per-session cache of computed `OriginSummary` values keyed by
    /// `(variable_id, step_id)` per spec §3.2.3 / M2 deliverable
    /// "Backend caches summaries per `(variable_id, step_id)` within a
    /// session to avoid recomputing on every navigation". The cache
    /// lives on the `Handler` (rather than on `MaterializedReplaySession`)
    /// because the handler is the natural session-scope owner —
    /// `MaterializedReplaySession` is also instantiated inside
    /// `load_flow` as a side replay (`Handler::load_flow`), and we
    /// explicitly want the cache to be shared across both the primary
    /// replay and any side replays that compute origins for the same
    /// `(variable, step)` pair.
    pub(crate) origin_summary_cache: HashMap<(usize, i64), task::OriginSummary>,

    /// Counter — increments once per *actual* origin-chain build
    /// (cache miss) inside `build_origin_summary_for_local_at`. Used
    /// by the M2 cache-hit verification test
    /// (`test_load_locals_origin_summary_populated`) to prove the
    /// `(variable_id, step_id)` cache is consulted. Stays on the
    /// public type because it is a real signal — internal benchmarks
    /// and future telemetry can read it too.
    pub origin_summary_chain_builds: std::sync::atomic::AtomicUsize,

    /// M21 — optional in-handler [`OriginMetadataDecoder`] used by
    /// materialized traces that ship the M19 metadata namespace.
    /// The browser-replay (Emulator) backend exposes its decoder
    /// through `EmulatorReplaySession::origin_metadata_decoder`; for
    /// materialized traces (where there's no session to hang the
    /// decoder off) the handler holds the slot directly. Test
    /// fixtures call [`Handler::install_materialized_origin_metadata_decoder`]
    /// to seed it. The recorder-driven boot path lands with the
    /// materialized recorder follow-on noted in M19's status block.
    pub(crate) materialized_origin_metadata_decoder: Option<crate::origin_metadata_indexer::OriginMetadataDecoder>,

    /// M21 — lazily computed pattern-fingerprint cache used by the
    /// placeholder fast-path. The fingerprint is invariant for the
    /// session (patterns don't reload), so we cache it once and reuse
    /// it across every `ct/load-history` / `ct/load-flow` per-entry
    /// placeholder. Without this cache, a 10 000-entry history pays
    /// 10 000 TOML reads + classifier-pattern walks — the M21
    /// performance budget (≤ 700 ms) is unreachable.
    pub(crate) cached_patterns_fingerprint: Option<String>,

    /// M25b — instrumentation counter incremented each time the
    /// marker decoder runs against an event's `metadata` slot inside
    /// `event_load`. The DAP test
    /// `test_dap_event_log_marker_response_serves_from_cache_post_load`
    /// asserts this counter does **not** advance on repeat
    /// `ct/event-load` calls — proving the marker rows are served
    /// from the same in-memory `cached_events` slice without re-
    /// decoding the metadata blob a second time.
    pub marker_decode_calls: std::sync::atomic::AtomicUsize,

    /// M25b — cached marker-row projection over `cached_events`.
    /// Built once on the first `event_load` call after `cached_events`
    /// is populated; subsequent `ct/event-load` requests serve from
    /// this slice verbatim, satisfying the §3.2.1 one-time-evaluation
    /// contract at the DAP layer.
    pub(crate) cached_marker_rows: Option<Vec<MarkerEventRow>>,

    /// M3 — Column-Aware-Replay-Navigation §M3.  Absolute path of the
    /// recorder-baked formatted ``srcview`` the user is currently
    /// looking at, or ``None`` when the GUI is showing the recorded
    /// minified coordinates directly.
    ///
    /// When ``Some(path)`` the [`Handler::next_dap`] runner reroutes
    /// step-over: instead of advancing one recorded /minified/ line
    /// per press (which for a 100KB one-liner bundle means "step
    /// through the entire program"), it advances until the next
    /// recorded step's projection through the sourcemap_cache lands
    /// at a different /formatted/ ``(line, column)`` tuple — i.e.
    /// one formatted line (or, under ``granularity:"statement"``,
    /// one formatted statement) per press.  This is the whole point
    /// of M3: users debugging a minified bundle in formatted view get
    /// a step granularity that matches what they see on screen.
    ///
    /// Toggling between minified and formatted view is GUI state, so
    /// the field is updated via the
    /// ``ct/set-active-source-view`` DAP request rather than baked into
    /// every individual step request — the runner consults
    /// the active path at dispatch time.
    pub active_source_view_path: Option<String>,
}

/// M25b — Event-Log marker row returned by `ct/event-load`. The
/// frontend decodes the `MarkerPayload` from this struct rather than
/// re-decoding the raw `ProgramEvent.metadata` JSON. Carries the
/// originating row's `event_index` so the consumer can correlate the
/// marker metadata back to the standard event row.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkerEventRow {
    /// Index into the `events: [...]` array on the same response — the
    /// frontend joins marker metadata to standard event rows via this
    /// field rather than the more brittle `(path, line, rrTicks)`
    /// triple.
    pub event_index: usize,
    pub marker_id: usize,
    pub boundary_id: String,
    pub direction: String,
    pub key_text: String,
    pub key_value: String,
    pub show_text: Option<String>,
    pub show_value: Option<String>,
    pub description: Option<String>,
    pub format: Option<String>,
    pub source_path: String,
    pub source_line: usize,
    pub step_id: i64,
}

/// M25b — `ct/pairIndexLookup` request arguments. The frontend
/// supplies the `(boundary_id, direction, key_value)` triple and gets
/// back the list of counterparts (Recv firings when querying from a
/// Send marker, and vice versa) per spec §5.3.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairIndexLookupArguments {
    pub boundary_id: String,
    pub direction: String,
    pub key_value: String,
}

/// M25b — One counterpart entry returned by `ct/pairIndexLookup`.
/// Shape kept symmetric with `MarkerEventRow` so a single frontend
/// row-mapper can populate the Event Log columns regardless of
/// whether the row originated from `ct/event-load` or the lookup.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairIndexCounterpart {
    pub recording_id: String,
    pub step_id: i64,
    pub source_path: String,
    pub source_line: usize,
    pub marker_id: usize,
    pub boundary_id: String,
    pub direction: String,
    pub key_text: String,
    pub key_value: String,
    pub show_text: Option<String>,
    pub show_value: Option<String>,
    pub format: Option<String>,
}

// two choices:
//   return results and potentially
//   generate multiple events as a generator
//
// or just use Sender and directly
//   call its methods when needed
//
// e.g.
//
//
// ->
// 1 variant:
//   return type -> Message
//
// 2 variant:
//   receives sender as arg
//   sender.

#[allow(clippy::expect_used)]
impl Handler {
    fn is_live_recreator_session(&self) -> bool {
        self.trace_kind == TraceKind::Recreator
            && (self.ct_rr_args.live_program.is_some() || self.ct_rr_args.live_recording_dir.is_some())
    }

    pub fn new(trace_kind: TraceKind, ct_rr_args: RecreatorArgs, db: Box<Db>) -> Handler {
        Self::construct(trace_kind, ct_rr_args, db, false)
    }

    pub fn construct(trace_kind: TraceKind, ct_rr_args: RecreatorArgs, db: Box<Db>, indirect_send: bool) -> Handler {
        // Wrap the Db in an InMemoryTraceReader so that all code goes through
        // the TraceReader abstraction. Direct Db access is available via
        // All trace data access goes through the TraceReader trait.
        let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(*db));
        Self::construct_with_reader(trace_kind, ct_rr_args, reader, indirect_send)
    }

    /// Build a `Handler` from a pre-constructed [`TraceReader`].
    ///
    /// This is the common path that both `construct` (in-memory Db) and the
    /// CTFS-backed reader use.  The caller is responsible for building the
    /// appropriate `Arc<dyn TraceReader>` (e.g. `InMemoryTraceReader` for
    /// legacy traces, `CTFSTraceReader` for `.ct` containers).
    pub fn construct_with_reader(
        trace_kind: TraceKind,
        ct_rr_args: RecreatorArgs,
        reader: Arc<dyn TraceReader>,
        indirect_send: bool,
    ) -> Handler {
        let replay: Box<dyn ReplaySession> = if trace_kind == TraceKind::Materialized {
            Box::new(MaterializedReplaySession::new(Arc::clone(&reader)))
        } else {
            // Recreator (RR) — drives an out-of-process replay worker.
            // Emulator-kind handlers must go through
            // `construct_with_replay`, where the caller supplies the
            // pre-built `EmulatorReplaySession`.
            Box::new(RecreatorReplaySession::new(&ct_rr_args.name, 0, ct_rr_args.clone()))
        };
        Self::construct_with_replay(trace_kind, ct_rr_args, reader, replay, indirect_send)
    }

    /// Build a `Handler` from a pre-constructed [`TraceReader`] AND a
    /// pre-constructed [`ReplaySession`].
    ///
    /// This is the entry point used by the F5c-4 WASM browser-replay
    /// pathway: the MCR-aware [`crate::emulator_session::
    /// EmulatorReplaySession`] is built directly from CTFS bytes by
    /// `setup_from_vfs` and handed in here together with a placeholder
    /// `InMemoryTraceReader` for the empty-DB code paths
    /// (`Calltrace::new`, `initialize_breakpoint_cache`, etc.) that the
    /// rest of the handler still touches.
    ///
    /// Callers should pair `trace_kind == TraceKind::Emulator` with an
    /// [`crate::emulator_session::EmulatorReplaySession`]; the DAP
    /// handlers (`stack_trace`, `scopes`, `variables`) branch on
    /// `TraceKind::Emulator` to surface the trait-derived state rather
    /// than reading from the materialised DB-backed `reader`.
    pub fn construct_with_replay(
        trace_kind: TraceKind,
        ct_rr_args: RecreatorArgs,
        reader: Arc<dyn TraceReader>,
        replay: Box<dyn ReplaySession>,
        indirect_send: bool,
    ) -> Handler {
        let calltrace = Calltrace::new(&*reader);
        let trace = CoreTrace::default();
        let mut expr_loader = ExprLoader::new(trace.clone());
        let step_lines_loader = StepLinesLoader::new(&*reader, &mut expr_loader);
        // let sender = sender::Sender::new();
        let mut handler = Handler {
            trace_kind,
            reader,
            step_id: StepId(0),
            last_location: Location {
                key: format!("{}", NO_KEY.0),
                ..Location::default()
            },
            indirect_send,
            // sender,
            event_db: EventDb::new(),
            flow_preloader: FlowPreloader::new(),
            expr_loader,
            trace,
            calltrace,
            step_lines_loader,
            dap_client: DapClient::default(),
            previous_step_id: StepId(0),
            breakpoints: HashMap::new(),
            replay,
            ct_rr_args,
            load_flow_index: 0,
            tracepoint_rr_worker_index: 0,
            resulting_dap_messages: vec![],
            raw_diff_index: None,
            initialized: false,
            cached_events: None,
            cached_terminal_events: None,
            macro_sourcemaps: MacroSourceMapCollection::default(),
            sourcemap_cache: SourcemapCache::new(),
            sourcemap_cache_dir: None,
            origin_summary_cache: HashMap::new(),
            origin_summary_chain_builds: std::sync::atomic::AtomicUsize::new(0),
            materialized_origin_metadata_decoder: None,
            cached_patterns_fingerprint: None,
            marker_decode_calls: std::sync::atomic::AtomicUsize::new(0),
            cached_marker_rows: None,
            active_source_view_path: None,
        };
        handler.initialize_breakpoint_cache();
        handler
    }
    // TODO

    // load-calltrace parameters
    // <- calltrace-update 1
    // <- ..

    // normal workflow
    //
    // -> from local db/trace: trace source folders
    // start-0
    // run-to-entry-0 -> CompleteMove event
    //   load-locals-0 ->
    //   load-callstack-0 ->
    //   load-flow-0 ->
    // step-0 <parameters> -> CompleteMove event
    //  ..

    // TaskId, EventId c-style-enums
    // rust-style enums

    //TaskKind::LoadLocals
    //TaskResult::LoadLocals(HashMap<..>) -> load-locals

    // pub fn configure(&mut self, arg: ConfigureArg, task: Task) -> Result<(), Box<dyn Error>> {
    //     self.trace = arg.trace.clone();
    //     self.expr_loader.trace = arg.trace.clone();
    //     self.flow_preloader.expr_loader.trace = arg.trace;
    //     self.return_void(task)?;
    //     Ok(())
    // }

    fn load_location(&self, step_id: StepId) -> Location {
        let step_id_int = step_id.0;
        let step_record = self.reader.step(step_id).expect("load_location: invalid step_id");
        let path = format!(
            "{}",
            self.reader
                .workdir()
                .join(self.reader.path(step_record.path_id).unwrap_or(""))
                .display()
        );
        let line = step_record.line.0;
        let call_key = step_record.call_key;
        let call_key_int = call_key.0;

        assert!(call_key_int >= 0);

        let function_name = if step_record.call_key != NO_KEY {
            let call = self.reader.call(call_key).expect("load_location: invalid call_key");
            let function = self
                .reader
                .function(call.function_id)
                .expect("load_location: invalid function_id");
            function.name.clone()
        } else {
            "<unknown>".to_string()
        };
        let call_key_text = format!("{call_key_int}");
        let global_call_key_text = format!("{}", step_record.global_call_key.0);
        let callstack_depth = 0; // TODO
        Location::new(
            &path,
            line,
            RRTicks(step_id_int),
            &function_name,
            &call_key_text,
            &global_call_key_text,
            callstack_depth,
        )
    }

    pub fn reset_dap(&mut self) {
        self.resulting_dap_messages = vec![];
    }

    // fn send_dap(&mut self, dap_message: &DapMessage) -> Result<(), Box<dyn Error>> {
    //     self.resulting_dap_messages.push(dap_message.clone());
    //     Ok(())
    // }

    pub fn respond_dap<T: Serialize>(
        &mut self,
        request: dap::Request,
        value: T,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let response = DapMessage::Response(dap::Response {
            base: dap::ProtocolMessage {
                seq: self.dap_client.seq, // actually patched by `patch_message_seq` in the sending thread in `src/dap_server.rs`!
                type_: "response".to_string(),
            },
            request_seq: request.base.seq,
            success: true,
            command: request.command.clone(),
            message: None,
            body: serde_json::to_value(value)?,
        });
        self.dap_client.seq += 1;
        Ok(sender.send(response)?)
    }

    // will be sent after completion of query
    fn prepare_stopped_event(&mut self, is_main: bool) -> Result<DapMessage, Box<dyn Error>> {
        let reason = if is_main { "entry" } else { "step" };
        // info!("generate stopped event");
        let raw_event = self.dap_client.stopped_event(reason)?;
        info!("raw stopped event: {:?}", raw_event);
        Ok(raw_event)
    }

    fn prepare_complete_move_event(&mut self, move_state: &MoveState) -> Result<DapMessage, Box<dyn Error>> {
        let raw_complete_move_event = self.dap_client.complete_move_event(move_state)?;
        Ok(raw_complete_move_event)
    }

    fn prepare_output_events(&mut self) -> Result<Vec<DapMessage>, Box<dyn Error>> {
        if self.trace_kind == TraceKind::Recreator {
            warn!("prepare_output_events not implemented for rr");
            return Ok(vec![]); // TODO
        }

        if self.step_id.0 > self.previous_step_id.0 {
            let mut raw_output_events: Vec<dap::DapMessage> = vec![];
            for event in self.reader.events().iter() {
                if event.step_id.0 > self.previous_step_id.0 && event.step_id.0 <= self.step_id.0 {
                    // different kind of if-s:
                    //   upper if the event is in the range of the move
                    //   this internal one: for which kinds do we produce dap events
                    #[allow(clippy::collapsible_if)]
                    if event.kind == EventLogKind::Write {
                        let step = *self
                            .reader
                            .step(event.step_id)
                            .expect("prepare_output_events: invalid step_id");
                        info!("generate output event");
                        let raw_output_event = self.dap_client.output_event(
                            "stdout",
                            self.reader.path(step.path_id).unwrap_or(""),
                            step.line.0 as usize,
                            &event.content,
                        )?;
                        info!("raw output event: {:?}", raw_output_event);
                        raw_output_events.push(raw_output_event);
                    }
                }
            }
            Ok(raw_output_events)
        } else {
            Ok(vec![])
        }
    }

    fn prepare_eventual_error_event_message(&mut self) -> Option<String> {
        if self.trace_kind == TraceKind::Recreator {
            warn!("prepare_eventual_error_event_message not implemented for rr");
            return None; // TODO
        }

        let exact = false; // or for now try as flow // true just for this exact step
        let step_events = self.reader.load_step_events(self.step_id, exact);
        // info!("step events for {:?} {:?}", self.step_id, step_events);
        if !step_events.is_empty() && step_events[0].kind == EventLogKind::Error {
            let error_text = &step_events[0].content;
            let error_step_id = step_events[0].step_id;
            Some(format!("recorded error on step #{}: {}", error_step_id.0, error_text))
        } else {
            None
        }
    }

    fn should_reset_flow(&mut self, is_main: bool, location: &Location) -> bool {
        let result = if self.trace_kind == TraceKind::Materialized {
            is_main || location.key != self.last_location.key
        } else {
            is_main
                || (location.function_name != self.last_location.function_name
                    || location.callstack_depth != self.last_location.callstack_depth
                    || location.key != self.last_location.key)
        };
        self.last_location = location.clone();
        result
    }

    fn complete_move(&mut self, is_main: bool, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        info!("complete_move");

        // self.db.load_location(self.step_id, call_key, &mut self.expr_loader),
        let mut location = self.replay.load_location(&mut self.expr_loader)?;
        self.step_id = self.replay.current_step_id();
        // M3 — when the user has toggled into a formatted srcview, the
        // GUI cursor must follow the formatted coordinates the runner
        // is stepping through.  Project the recorded
        // ``(path, line, column)`` through the active view's sourcemap
        // BEFORE the find_function_location pass and downstream flow
        // wiring see it — otherwise the UI cursor would track the
        // minified position while the runner advanced by formatted line.
        //
        // Without an active source view the location flows through
        // unchanged so legacy minified-mode behaviour is preserved
        // (the existing per-stackTrace `apply_sourcemap_translation`
        // path keeps the stack frame view consistent for that mode).
        //
        // Spec:
        //   codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
        if self.active_source_view_path.is_some() {
            let recorded_column = location.column.unwrap_or(1);
            let (translated_path, translated_line, translated_col) =
                self.apply_sourcemap_translation(&location.path, location.line, recorded_column);
            location.path = translated_path;
            location.line = translated_line;
            // Surface the translated column on the existing slot so the
            // ViewModel's ``getCurrentColumn`` accessor (M1) sees the
            // formatted column.  ``apply_sourcemap_translation`` always
            // returns a positive column on a successful projection.
            location.column = Some(translated_col);
        }
        // Preserve the Db-derived function boundaries before find_function_location
        // potentially overwrites them with (0,0) when tree-sitter can't parse the file.
        let db_function_first = location.function_first;
        let db_function_last = location.function_last;
        location = self
            .flow_preloader
            .expr_loader
            .find_function_location(&location, &Line(location.line));
        // When find_function_location returns (0,0) (no tree-sitter data for this
        // language/file), restore the Db-derived boundaries so the downstream
        // load_flow can iterate over all steps in the function.
        if location.function_first == 0 && location.function_last == 0 && db_function_first != 0 {
            location.function_first = db_function_first;
            location.function_last = db_function_last;
        }
        // TODO: change if we need to support non-int keys
        let reset_flow = self.should_reset_flow(is_main, &location);
        info!("  location: {location:?}");

        // Build c_location for sourcemapped languages (e.g. Nim compiled to C).
        // The frontend uses c_location to open the generated-C view (View 1) and
        // the assembly view (View 2) via c_location.asmName (= path:functionName).
        //
        // First, try to use the c_location from the replay session (populated by
        // LoadLocationWithSourcemap for rr-based Nim traces). If not available,
        // derive it from the location's low_level fields (populated when the
        // sourcemap has been applied: low_level_path = generated C, path = Nim).
        let c_location = if let Some(replay_c_loc) = self.replay.last_c_location() {
            replay_c_loc
        } else if !location.low_level_path.is_empty() && location.low_level_path != location.path {
            Location {
                path: location.low_level_path.clone(),
                line: location.low_level_line,
                high_level_path: location.high_level_path.clone(),
                high_level_line: location.high_level_line,
                low_level_path: location.low_level_path.clone(),
                low_level_line: location.low_level_line,
                function_name: location.function_name.clone(),
                function_first: location.function_first,
                function_last: location.function_last,
                source_generation: location.source_generation,
                source_digest: location.source_digest.clone(),
                rr_ticks: location.rr_ticks.clone(),
                ..Location::default()
            }
        } else {
            Location::default()
        };

        let move_state = MoveState {
            status: "".to_string(),
            location,
            c_location,
            main: is_main,
            reset_flow,
            stop_signal: RRGDBStopSignal::OtherStopSignal,
            frame_info: FrameInfo::default(),
        };

        let stopped_event = self.prepare_stopped_event(is_main)?;
        let complete_move_event = self.prepare_complete_move_event(&move_state)?;
        let output_events = self.prepare_output_events()?;

        info!("send stopped_event {:?}", stopped_event);
        sender.send(stopped_event)?;
        info!("send complete move event {:?}", complete_move_event);
        sender.send(complete_move_event)?;
        for output_event in output_events {
            sender.send(output_event)?;
        }

        self.previous_step_id = self.step_id;

        // self.send_notification(NotificationKind::Success, "Complete move!", true)?;

        if let Some(error_message) = self.prepare_eventual_error_event_message() {
            self.send_notification(NotificationKind::Error, &error_message, false, sender)?;
        }

        info!("ready complete move");
        Ok(())
    }

    fn is_internal_jit_registration_stop(&mut self) -> Result<bool, Box<dyn Error>> {
        const JIT_DEBUG_REGISTER_CODE: &str = "__jit_debug_register_code";
        let location = self.replay.load_location(&mut self.expr_loader)?;
        if location.function_name == JIT_DEBUG_REGISTER_CODE
            || location.high_level_function_name == JIT_DEBUG_REGISTER_CODE
        {
            return Ok(true);
        }

        let callstack = self.replay.load_callstack()?;
        Ok(callstack
            .last()
            .map(|line| {
                let call = &line.content.call;
                call.raw_name == JIT_DEBUG_REGISTER_CODE
                    || call.location.function_name == JIT_DEBUG_REGISTER_CODE
                    || call.location.high_level_function_name == JIT_DEBUG_REGISTER_CODE
            })
            .unwrap_or(false))
    }

    fn skip_internal_jit_registration_stops(&mut self) -> Result<(), Box<dyn Error>> {
        if !self.is_live_recreator_session() {
            return Ok(());
        }

        for _ in 0..8 {
            if !self.is_internal_jit_registration_stop()? {
                return Ok(());
            }
            info!("continuing internal JIT debug-symbol registration stop");
            if !self.replay.step(Action::Continue, true)? {
                return Ok(());
            }
            self.step_id = self.replay.current_step_id();
        }

        warn!("leaving repeated internal JIT debug-symbol registration stop visible after retry limit");
        Ok(())
    }

    pub fn run_to_entry(
        &mut self,
        _req: dap::Request,
        restore_location: Option<Location>,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if let Some(location) = restore_location {
            if location.path != NO_PATH && location.line != NO_POSITION {
                self.replay.location_jump(&location)?;
            } else {
                self.replay.run_to_entry()?;
            }
        } else {
            self.replay.run_to_entry()?;
        }
        self.step_id = StepId(0); // TODO: use only db replay step_id or another workaround?
        self.complete_move(true, sender)?;
        Ok(())
    }

    pub fn load_locals(
        &mut self,
        req: dap::Request,
        args: task::CtLoadLocalsArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        // if self.trace_kind == TraceKind::Recreator {
        // let locals: Vec<Variable> = vec![];
        // warn!("load_locals not implemented for rr yet");
        let locals_with_records = self.replay.load_locals(args)?;
        // Per spec §3.2.3, locals on the active frame use *Eager*
        // origin summaries on the materialized backend. The cache
        // inside `build_origin_summary_for_local` keeps repeated
        // `ct/load-locals` requests on the same step ~O(1).
        //
        // §P6.4 — derive the surrounding step's `(file, line, col)`
        // once and reuse it for every variable on the frame.  Doing
        // it per-call would re-resolve the path/line/column inside
        // `resolve_variable_name`'s wrapper, which is wasted work
        // when every local on the frame shares the same position.
        let (file, line, col) = self.current_step_location();
        let mut locals: Vec<Variable> = Vec::with_capacity(locals_with_records.len());
        for l in locals_with_records.iter() {
            let origin_summary = if self.trace_kind == TraceKind::Materialized {
                Some(self.build_origin_summary_for_local(&l.expression))
            } else {
                None
            };
            // §P5/P6.4 — apply the user rename list + per-position
            // sourcemap segment lookup at render time so the UI sees
            // the user-facing binding name.  Origin summaries continue
            // to look up by the recorded (minified) name — origin
            // tracking is keyed on the recorded variable id, not the
            // rendered name.
            let (display, _original) = self.resolve_variable_name_at(&l.expression, &file, line, col);
            locals.push(Variable {
                expression: display,
                value: to_ct_value(&l.value),
                address: l.address,
                origin_summary,
            });
        }
        self.respond_dap(req, task::CtLoadLocalsResponseBody { locals }, sender)?;
        Ok(())
        // }

        // self.respond_dap(req, task::CtLoadLocalsResponseBody { locals })?;
        // Ok(())
    }

    // pub fn load_callstack(&mut self, task: Task) -> Result<(), Box<dyn Error>> {
    //     let callstack: Vec<Call> = self
    //         .calltrace
    //         .load_callstack(self.step_id, &self.db)
    //         .iter()
    //         .map(|call_record| {
    //             // expanded children count not relevant in raw callstack
    //             self.db.to_call(call_record, &mut self.expr_loader)
    //         })
    //         .collect();

    //     // info!("callstack {:#?}", callstack);
    //     Ok(())
    // }

    pub fn collapse_calls(
        &mut self,
        _req: dap::Request,
        collapse_calls_args: CollapseCallsArgs,
    ) -> Result<(), Box<dyn Error>> {
        if let Ok(num_key) = collapse_calls_args.call_key.clone().parse::<i64>() {
            self.calltrace.change_expand_state(CallKey(num_key), false);
        } else {
            error!("invalid i64 number for call key: {}", collapse_calls_args.call_key);
        }

        // self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    pub fn expand_calls(
        &mut self,
        _req: dap::Request,
        collapse_calls_args: CollapseCallsArgs,
    ) -> Result<(), Box<dyn Error>> {
        let kind = collapse_calls_args.non_expanded_kind;
        if let Ok(num_key) = collapse_calls_args.call_key.clone().parse::<i64>() {
            if kind == CalltraceNonExpandedKind::CallstackInternal {
                self.calltrace
                    .expand_callstack_internal(CallKey(num_key), collapse_calls_args.count)
            } else if kind == CalltraceNonExpandedKind::Callstack {
                self.calltrace.expand_callstack(CallKey(num_key));
            } else if kind == CalltraceNonExpandedKind::Children {
                self.calltrace.change_expand_state(CallKey(num_key), true);
            }
        } else {
            error!("invalid i64 number for call key: {}", collapse_calls_args.call_key);
        }
        // self.return_task((task, VOID_RESULT.to_string()))?;
        Ok(())
    }

    fn load_local_calltrace(&mut self, args: CalltraceLoadArgs) -> Result<Vec<CallLine>, Box<dyn Error>> {
        let call_key = self
            .reader
            .call_key_for_step(self.step_id)
            .expect("load_local_calltrace: invalid step_id");
        self.calltrace.optimize_collapse = args.optimize_collapse;
        if call_key != self.calltrace.start_call_key {
            // When not auto-collapsing (e.g. Python API bridge), pass the
            // requested depth so calls are expanded up to that level.
            // The GUI uses auto_collapsing=true and handles expand/collapse
            // interactively, so it does not need this.
            let max_depth = if args.auto_collapsing { None } else { Some(args.depth) };
            self.calltrace
                .jump_to_with_depth(self.step_id, args.auto_collapsing, max_depth, &*self.reader);
        }
        self.calltrace.load_lines(
            args.start_call_line_index,
            args.height,
            &*self.reader,
            &mut self.expr_loader,
        )
    }

    fn calc_total_calls(&mut self) -> usize {
        let mut collapsed_count: usize = 0;
        for state in self.calltrace.call_states.iter() {
            if !state.expanded {
                collapsed_count += 1;
            }
        }
        self.reader.call_count() - collapsed_count
    }

    pub fn load_calltrace_section(
        &mut self,
        req: dap::Request,
        args: CalltraceLoadArgs,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let update = if self.trace_kind == TraceKind::Recreator {
            // TODO: calltrace? eventually in the future
            // for now callstack!

            let start_call_line_index = GlobalCallLineIndex(0);
            let callstack_lines = self.replay.load_callstack()?;
            let total_count = callstack_lines.len();
            let position = 0;
            CallArgsUpdateResults::finished_update_call_lines(
                callstack_lines,
                start_call_line_index,
                total_count,
                position,
                self.calltrace.depth_offset,
            )
        } else {
            let start_call_line_index = args.start_call_line_index;
            let call_lines = self.load_local_calltrace(args)?;
            let total_count = self.calc_total_calls();
            let position = self.calltrace.calc_scroll_position();
            CallArgsUpdateResults::finished_update_call_lines(
                call_lines,
                start_call_line_index,
                total_count,
                position,
                self.calltrace.depth_offset,
            )
        };
        let raw_event = self.dap_client.updated_calltrace_event(&update)?;
        sender.send(raw_event)?;
        // Include calltrace data in the response body for customRequest().
        self.respond_dap(req, &update, sender)?;
        Ok(())
    }

    pub fn load_flow(
        &mut self,
        req: dap::Request,
        arg: CtLoadFlowArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let mut flow_replay: Box<dyn ReplaySession> = if self.trace_kind == TraceKind::Materialized {
            Box::new(MaterializedReplaySession::new(Arc::clone(&self.reader)))
        } else {
            Box::new(RecreatorReplaySession::new(
                "flow",
                self.load_flow_index,
                self.ct_rr_args.clone(),
            ))
        };
        self.load_flow_index += 1;

        // TODO: eventually cleanup or manage in a more optimal way flow replays: caching
        // if possible for example

        let flow_update = if arg.flow_mode == FlowMode::Call {
            // For DB-based traces, populate function boundaries on the location
            // before passing it to the flow preloader. The DAP client may send
            // a location with function_first == 0. The Db has authoritative
            // boundary data from the trace's Call/Function records.
            let mut location = arg.location;
            if self.trace_kind == TraceKind::Materialized
                && location.function_first <= 0
                && location.function_last <= 0
                && location.rr_ticks.0 >= 0
            {
                let step_id = StepId(location.rr_ticks.0);
                if (step_id.0 as usize) < self.reader.step_count() {
                    let call_key = self.reader.step(step_id).expect("step not found").call_key;
                    let enriched = self
                        .reader
                        .load_location(step_id, call_key, &mut self.flow_preloader.expr_loader);
                    location.function_first = enriched.function_first;
                    location.function_last = enriched.function_last;
                    if location.function_name.is_empty() || location.function_name == "<unknown>" {
                        location.function_name = enriched.function_name;
                        location.high_level_function_name = enriched.high_level_function_name;
                    }
                }
            }
            self.flow_preloader
                .load(location, arg.flow_mode, self.trace_kind, &mut *flow_replay)
            // let step_id = StepId(arg.location.rr_ticks.0);
            // let call_key = self.db.steps[step_id].call_key;
            // let function_id = self.db.calls[call_key].function_id;
            // let function_first = self.db.functions[function_id].line;
            // info!("load {arg:?}");
            // self.flow_preloader
            //     .load(arg.location, function_first, arg.flow_mode, &self.db)
        } else if let Some(raw_flow) = &self.raw_diff_index {
            serde_json::from_str::<FlowUpdate>(raw_flow)?
        } else {
            // TODO: notification? or ignore
            // eventually in the future: make a diff index now in the replay and send it
            let message = "no raw diff index in handler, can't send flow for diff for now";
            warn!("{}", message);
            return Err(message.into());
        };
        info!("  flow ready");
        // Per spec §3.2.3 the Omniscience-Flow overlay annotations
        // carry per-annotated-value `OriginSummary` entries. On M2
        // (materialized, no omniscient DB), every annotation defaults
        // to *placeholder* mode — the frontend lazily fills them via
        // `ct/originSummary` (spec §5.3.2). Walk each FlowStep's
        // after-values and emit a placeholder summary keyed by
        // variable name; the placeholder token captures the per-step
        // `(variable_name, step_id)` pair so each token round-trips
        // independently.
        //
        // M21 — when the trace is in Mode 3 (`classify_eager_mode`
        // returns a class that `flips_eager()`), the per-annotation
        // default flips to eager. The per-key lookup goes through the
        // M19 metadata decoder; lazy intervals fall back to a
        // placeholder so the frontend renders `[?]` until the
        // background analyser finishes (spec §3.2.3).
        //
        // Performance: snapshot the per-call state once. Per-row
        // helpers (e.g. `variable_id_for`) live on `self.reader`
        // (cheap), but cloning the decoder per row is not — the
        // decoder snapshot is taken once and the eager builder
        // reuses it across every (variable, step) pair.
        let eager_class = self.classify_eager_mode();
        let decoder_snapshot = if self.trace_kind == TraceKind::Materialized && eager_class.flips_eager() {
            self.clone_origin_metadata_decoder()
        } else {
            None
        };
        let patterns_fingerprint_snapshot = self.patterns_fingerprint_cached();
        let mut flow_update = flow_update;
        if self.trace_kind == TraceKind::Materialized {
            for view in flow_update.view_updates.iter_mut() {
                for step in view.steps.iter_mut() {
                    let step_id = StepId(step.rr_ticks.0);
                    let names: Vec<String> = step
                        .after_values
                        .keys()
                        .chain(step.before_values.keys())
                        .cloned()
                        .collect();
                    for name in names {
                        if step.origin_summaries.contains_key(&name) {
                            continue;
                        }
                        let summary = build_flow_eager_or_placeholder(
                            &*self.reader,
                            decoder_snapshot.as_ref(),
                            eager_class,
                            &patterns_fingerprint_snapshot,
                            &name,
                            step_id,
                        );
                        step.origin_summaries.insert(name, summary);
                    }
                }
            }
        }
        let raw_event = self.dap_client.updated_flow_event(flow_update.clone())?;
        sender.send(raw_event)?;

        // Include flow data in the response body for customRequest().
        self.respond_dap(req, &flow_update, sender)?;
        Ok(())
    }

    // we use &mut because we might process
    // an additional file in expr loader
    // in `load_location` at least
    // this is required to find out `function_first`
    // and mostly `function_last``
    #[allow(clippy::wrong_self_convention)]
    fn to_ct_calltrace_call(
        &mut self,
        db_call: &DbCall,
        depth: usize,
        depth_limit: usize,
        count_limit: usize,
    ) -> Result<(Call, usize), Box<dyn Error>> {
        // expanded children count not used here: we add actual children
        let mut call = self.reader.to_call(db_call, &mut self.expr_loader);
        let mut count = 1; // our call
        // TODO: on depth/count limit
        // generate something like Calls non-expanded/limited
        // similar to old isHiddenChildren / isHiddenSiblings
        // in commented out nim calltrace user interface code
        // instead of nothing, otherwise we're giving
        // WRONG info which is misleading
        //
        // e.g. we might stop after the 2nd child of a call
        //   with 4 children and then the interface would lead us
        //   to think it has exactly 2 calls, instead of
        //   2 calls and possibly non-loaded/non-expanded others more
        if depth < depth_limit && db_call.key.0 >= 0 {
            for child_call_id in &db_call.children_keys {
                assert!(child_call_id.0 >= 0);
                let child_db_call = self
                    .reader
                    .call(*child_call_id)
                    .expect("to_ct_calltrace_call: invalid child call_key")
                    .clone();
                let (child_call, child_call_count) =
                    self.to_ct_calltrace_call(&child_db_call, depth + 1, depth_limit, count_limit - count)?;
                call.children.push(child_call);
                count += child_call_count;
                if count >= count_limit {
                    break;
                }
            }
        }
        Ok((call, count))
    }

    pub fn step_in(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::StepIn, forward)?;
        self.step_id = self.replay.current_step_id();

        Ok(())
    }

    fn on_step_id_limit(&self, step_index: usize, forward: bool) -> bool {
        if self.reader.step_count() == 0 {
            return true;
        }
        if forward {
            // moving forward
            step_index >= self.reader.step_count() - 1 // we're on the last one
        } else {
            // moving backwards
            step_index == 0
        }
    }

    fn single_step_line(&self, step_index: usize, forward: bool) -> usize {
        // taking note of db.lines limits: returning a valid step id always
        if self.reader.step_count() == 0 {
            return step_index;
        }
        if forward {
            if step_index < self.reader.step_count() - 1 {
                step_index + 1
            } else {
                step_index
            }
        } else if step_index > 0 {
            step_index - 1
        } else {
            // auto-returning the same 0 if stepping backwards from 0
            step_index
        }
    }

    pub fn next(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::Next, forward)?;
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    /// M2 — statement-granularity step-over.
    ///
    /// Dispatches to [`ReplaySession::step_over_statement`] (default
    /// impl falls back to `Action::Next`; the materialised session
    /// overrides with the column-aware runner).
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    pub fn next_statement(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step_over_statement(forward)?;
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    /// M2 — DAP `next` request entry point.
    ///
    /// Reads the DAP `granularity` field (previously dropped on the
    /// floor) and dispatches:
    ///
    ///   * `Some("statement")` → [`Handler::next_statement`] —
    ///     advance one /statement/ at a time using `DbStep.column`.
    ///   * `Some("line")` / `Some("instruction")` / `None` →
    ///     [`Handler::next`] — the existing line-granularity runner.
    ///     Per the M2 contract any non-`statement` value (including
    ///     unrecognised future values) maps to legacy line-granularity
    ///     so an over-eager DAP client never breaks back-compat.
    ///
    /// `granularity` is consumed lowercase per DAP spec §SteppingGranularity
    /// (`"statement" | "line" | "instruction"`).  Case-insensitive
    /// matching protects against future client variations without
    /// pinning a strict-mode rejection.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
    pub fn next_dap(
        &mut self,
        request: dap::Request,
        granularity: Option<String>,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.next_or_step_back_dap(request, granularity, /* forward = */ true, sender)
    }

    /// M7 — DAP `stepBack` request entry point.
    ///
    /// Reverse-direction counterpart of [`Handler::next_dap`].  Reads
    /// the DAP `granularity` field on the `stepBack` request (the DAP
    /// `StepBackArguments.granularity` slot) and dispatches:
    ///
    ///   * `Some("statement")` → column-aware statement-granularity
    ///     reverse runner — advance one /statement/ at a time
    ///     /backwards/ using `DbStep.column`.  Symmetric mirror of the
    ///     M2 forward path; the underlying runner
    ///     ([`MaterializedReplaySession::next_statement`] with
    ///     `forward = false`) uses the same `next_step_id_relative_to_with_granularity`
    ///     helper but flips the stop predicate to STRICTLY-LESS
    ///     column on the same line.
    ///   * `Some("line")` / `Some("instruction")` / `None` → legacy
    ///     line-granularity reverse runner ([`Handler::next`] with
    ///     `forward = false`).  Mirrors the M2 forward back-compat
    ///     contract: any non-`statement` value (including unrecognised
    ///     future values) keeps the legacy behaviour intact, so an
    ///     over-eager client never breaks back-compat.
    ///
    /// The M3 formatted-view runner is deliberately not consulted for
    /// the backward direction at M7 — the active-source-view path
    /// projects through the FORWARD sourcemap and would need a
    /// dedicated reverse-projection runner to be correct in reverse.
    /// M8 is scoped to add formatted-view stepIn / stepOut; reverse-
    /// direction formatted projection is parked for a later milestone
    /// alongside the rest of the reverse formatted UX.  Until then a
    /// `stepBack` under an active source view falls through to the
    /// minified-coordinate runner — the same behaviour the legacy
    /// reverse-next has always had, so this is not a regression.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M7.
    pub fn step_back_dap(
        &mut self,
        request: dap::Request,
        granularity: Option<String>,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.next_or_step_back_dap(request, granularity, /* forward = */ false, sender)
    }

    /// Shared `next` / `stepBack` runner (M2 + M7).
    ///
    /// Direction is parametrised by `forward`.  For `forward = true`
    /// this is the M2 path; for `forward = false` it is the M7
    /// reverse-direction mirror.  The M3 formatted-view runner is
    /// only consulted in the forward direction — see [`step_back_dap`]
    /// for the rationale.
    fn next_or_step_back_dap(
        &mut self,
        request: dap::Request,
        granularity: Option<String>,
        forward: bool,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let original_step_id = self.step_id;
        let use_statement = matches!(
            granularity.as_deref(),
            Some(g) if g.eq_ignore_ascii_case("statement")
        );
        // M3 — Formatted-view step-over.  Only fires in the forward
        // direction (M7 leaves reverse formatted-view projection for a
        // later milestone; falling through to the minified runner in
        // reverse preserves the legacy reverse-step behaviour).
        let advanced_via_formatted_view =
            if forward && self.active_source_view_path.is_some() && self.trace_kind == TraceKind::Materialized {
                self.next_dap_formatted_view(use_statement)?
            } else {
                false
            };
        if !advanced_via_formatted_view {
            if use_statement {
                self.next_statement(forward)?;
            } else {
                self.next(forward)?;
            }
        }
        self.skip_internal_jit_registration_stops()?;
        // Surface the post-step location (mirrors `step()`'s
        // `complete_move(false, ...)` call so DAP clients receive the
        // ct/complete-move event the GUI listens on).
        self.complete_move(false, sender.clone())?;

        if self.trace_kind == TraceKind::Materialized {
            if original_step_id == self.step_id {
                let location = if self.step_id == StepId(0) { "beginning" } else { "end" };
                self.send_notification(
                    NotificationKind::Warning,
                    &format!("Limit of record at the {location} already reached!"),
                    false,
                    sender.clone(),
                )?;
            } else if self.step_id == StepId(0) {
                self.send_notification(
                    NotificationKind::Info,
                    "Beginning of record reached",
                    false,
                    sender.clone(),
                )?;
            } else if self.step_id.0 as usize == self.reader.step_count() - 1 {
                self.send_notification(NotificationKind::Info, "End of record reached", false, sender.clone())?;
            }
        }

        self.respond_dap(request, 0, sender)?;
        Ok(())
    }

    /// M3 — set / clear the active formatted source view.
    ///
    /// When ``Some(path)`` subsequent DAP ``next`` requests run through
    /// the formatted-view runner (see [`Handler::next_dap_formatted_view`]).
    /// When ``None`` the runner falls back to the legacy minified-
    /// coordinate path.
    ///
    /// The path is the absolute on-disk path of the materialised
    /// formatted-view sidecar (typically
    /// ``<trace_dir>/sourcemap-translate/<view_name>``).  It is the
    /// caller's responsibility to ensure a corresponding entry exists
    /// in [`Self::sourcemap_cache`] — either via [`Self::load_source_views`]
    /// (production recorder-baked srcviews) or via
    /// [`Self::install_source_view_for_test`] (test injection).
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
    pub fn set_active_source_view(&mut self, view_path: Option<String>) {
        self.active_source_view_path = view_path;
    }

    /// M3 — test-only: install a synthetic ``SourcemapIndex`` under a
    /// recorded path so the formatted-view runner has a real
    /// projection to consult.
    ///
    /// Production code path: [`Handler::load_source_views`] reads
    /// ``srcviews.dat`` from the CTFS container and installs entries
    /// via this same code path.  This method exposes the install hook
    /// directly so headless ViewModel and GUI Playwright tests can
    /// drive the formatted-view runner without needing the JS
    /// recorder's autoformat step (which requires ``prettier`` on PATH
    /// — a brittle test dependency).
    ///
    /// Arguments:
    ///   * ``recorded_path`` — the absolute path of the recorded
    ///     minified source the synthetic view applies to.  Looked up
    ///     in the reader's `path_map` to get the `PathId`.
    ///   * ``formatted_view_path`` — the absolute path the view will
    ///     be surfaced under (used as the active-view key by
    ///     [`Self::set_active_source_view`]).  Does not need to exist
    ///     on disk for the runner contract; tests typically use a
    ///     synthetic ``/tmp/...fmt.js`` string.
    ///   * ``sourcemap_v3_json`` — the JSON bytes of the V3 sourcemap
    ///     projecting recorded minified ``(line, column)`` →
    ///     formatted ``(line, column)``.
    ///
    /// On unknown ``recorded_path`` returns an error so the caller can
    /// surface a clear diagnostic; on V3 parse failure ditto.
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
    pub fn install_source_view_for_test(
        &mut self,
        recorded_path: &str,
        _formatted_view_path: &str,
        sourcemap_v3_json: &[u8],
    ) -> Result<(), Box<dyn Error>> {
        let path_id = self.reader.fuzzy_path_id_for(recorded_path).ok_or_else(|| {
            format!(
                "install_source_view_for_test: recorded_path {recorded_path} not registered in the trace's path table"
            )
        })?;
        let dir = self
            .sourcemap_cache_dir
            .clone()
            .unwrap_or_else(|| std::path::PathBuf::from("."));
        let idx = sourcemap_translate::SourcemapIndex::from_slice(sourcemap_v3_json, &dir)
            .map_err(|e| format!("install_source_view_for_test: failed to parse V3 JSON: {e}"))?;
        self.sourcemap_cache.install_index(path_id, recorded_path, idx);
        Ok(())
    }

    /// M3 — formatted-view step-over runner.
    ///
    /// Strategy: option (b) from the M3 plan — step normally through
    /// the recorded stream, but project each candidate step's location
    /// through the forward sourcemap and stop at the first projection
    /// that differs from the entry projection.  This sidesteps the
    /// edge case where a single formatted line maps back to multiple
    /// disjoint minified ranges (prettier sometimes wraps a single
    /// minified expression across lines and back), because the
    /// projection-based stop predicate naturally handles it: any step
    /// whose forward projection lands inside the entry's formatted
    /// line gets skipped, regardless of how the underlying minified
    /// ranges look.
    ///
    /// Granularity contract:
    ///   * ``use_statement == false`` → stop at the first candidate
    ///     whose projected formatted /line/ differs from the entry's
    ///     projected line.  Column changes within the same formatted
    ///     line are NOT a boundary (one F10 = one formatted line).
    ///   * ``use_statement == true`` → stop at the first candidate
    ///     whose projected formatted ``(line, column)`` tuple differs
    ///     from the entry's projection.  Column changes within the
    ///     same formatted line ARE a boundary (one Shift-F10 = one
    ///     formatted statement).
    ///
    /// Returns:
    ///   * ``Ok(true)`` when the cursor advanced via the formatted-view
    ///     path.  The caller MUST NOT then run the legacy runner.
    ///   * ``Ok(false)`` when the formatted-view path was not
    ///     applicable (no projection for the entry step) and the
    ///     caller should fall through to the legacy runner.  This is
    ///     the defensive fallback so a stale active-view path can't
    ///     break navigation.
    ///   * ``Err(_)`` on a real error condition (replay step failure).
    ///
    /// Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
    fn next_dap_formatted_view(&mut self, use_statement: bool) -> Result<bool, Box<dyn Error>> {
        // Snapshot the entry's projected formatted location.  If the
        // recorded coordinates do not project (e.g. the active view's
        // map has no segment covering them), bail out and let the
        // legacy runner take over — we cannot decide what "next
        // formatted line" means without a baseline projection.
        let Some(entry_projection) = self.project_active_view_for_current_step() else {
            return Ok(false);
        };

        let start_step_id = self.step_id;
        let mut last_step_id = start_step_id;
        let mut count: usize = 0;
        loop {
            let candidate = self
                .reader
                .next_step_id_relative_to_with_granularity(
                    last_step_id,
                    /* forward = */ true,
                    /* step_to_different_line = */ false,
                    /* step_to_different_column = */ false,
                )
                .0;
            if candidate == last_step_id {
                // No more steps — we've reached the trace boundary.
                // Mirror the legacy clamp-in-place behaviour so the
                // limit-reached notification fires downstream.
                break;
            }
            last_step_id = candidate;
            count += 1;
            if count >= crate::db::NEXT_INTERNAL_STEP_OVERS_LIMIT {
                break;
            }

            // Project the candidate's recorded coordinates through the
            // active view's map.  When the candidate has no projection
            // (sparse segment) we treat that as "no formatted-side
            // change" and keep stepping — the user expects intra-
            // formatted-line bookkeeping steps to be skipped.
            let Some(candidate_projection) = self.project_active_view_for_step(candidate) else {
                continue;
            };

            let line_changed = candidate_projection.path != entry_projection.path
                || candidate_projection.line != entry_projection.line;
            let column_changed = candidate_projection.column != entry_projection.column;
            let boundary = if use_statement {
                line_changed || column_changed
            } else {
                line_changed
            };
            if boundary {
                break;
            }
        }
        // Drive the replay session to the resolved step id so all the
        // downstream session state (last_location, call_key, etc.)
        // stays consistent with the materialised path.  This mirrors
        // the legacy ``next`` runner which goes through
        // ``MaterializedReplaySession::next``.
        if last_step_id != start_step_id {
            let moved = self.replay.jump_to(last_step_id)?;
            // ``jump_to`` returns the new step id via
            // ``current_step_id``; mirror it onto the handler's cursor.
            let _ = moved;
            self.step_id = self.replay.current_step_id();
        }
        Ok(true)
    }

    /// Helper — project the recorded coordinates of ``self.step_id``
    /// through [`Self::sourcemap_cache`].  Returns ``None`` when no
    /// projection exists (the cache has no entry for the recorded
    /// path, or the segment is sparse).
    fn project_active_view_for_current_step(&mut self) -> Option<crate::sourcemap_cache::TranslatedLocation> {
        let step_id = self.step_id;
        self.project_active_view_for_step(step_id)
    }

    /// Helper — project the recorded coordinates of ``step_id`` through
    /// [`Self::sourcemap_cache`].  See
    /// [`Self::project_active_view_for_current_step`].
    fn project_active_view_for_step(&mut self, step_id: StepId) -> Option<crate::sourcemap_cache::TranslatedLocation> {
        let step = self.reader.step(step_id)?;
        let path = self.reader.path(step.path_id)?.to_string();
        let workdir = self.reader.workdir().to_path_buf();
        let abs_path = if std::path::Path::new(&path).is_absolute() {
            path
        } else {
            workdir.join(&path).display().to_string()
        };
        let line = step.line.0.max(0) as u32;
        let col = step.column.map(|c| c.0.max(1) as u32).unwrap_or(1);
        if self.sourcemap_cache.is_empty() {
            return None;
        }
        let cache_dir = self.sourcemap_cache_dir.clone();
        self.sourcemap_cache
            .translate_for_path(&abs_path, line, col, cache_dir.as_deref())
    }

    pub fn step_out(&mut self, forward: bool) -> Result<(), Box<dyn Error>> {
        self.replay.step(Action::StepOut, forward)?;
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    pub fn step_continue(&mut self, forward: bool, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        if !self.replay.step(Action::Continue, forward)? {
            self.send_notification(NotificationKind::Info, "No breakpoints were hit!", false, sender)?;
        }
        self.step_id = self.replay.current_step_id();
        Ok(())
    }

    pub fn step(
        &mut self,
        request: dap::Request,
        arg: StepArg,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        // for now not supporting repeat/skip_internal: TODO
        // TODO: reverse
        let original_step_id = self.step_id;
        // let original_step = self.db.steps[original_step_id];
        // let original_depth = self.db.calls[original_step.call_key].depth;
        match arg.action {
            Action::StepIn => self.step_in(!arg.reverse)?,
            Action::Next => self.next(!arg.reverse)?,
            Action::StepOut => self.step_out(!arg.reverse)?,
            Action::Continue => self.step_continue(!arg.reverse, sender.clone())?,
            _ => error!("action {:?} not implemented", arg.action),
        }
        self.skip_internal_jit_registration_stops()?;
        if arg.complete {
            // && arg.action != Action::Continue {
            self.complete_move(false, sender.clone())?;
        }

        if self.trace_kind == TraceKind::Materialized {
            if original_step_id == self.step_id {
                let location = if self.step_id == StepId(0) { "beginning" } else { "end" };
                self.send_notification(
                    NotificationKind::Warning,
                    &format!("Limit of record at the {location} already reached!"),
                    false,
                    sender.clone(),
                )?;
            } else if self.step_id == StepId(0) {
                self.send_notification(
                    NotificationKind::Info,
                    "Beginning of record reached",
                    false,
                    sender.clone(),
                )?;
            } else if self.step_id.0 as usize == self.reader.step_count() - 1 {
                self.send_notification(NotificationKind::Info, "End of record reached", false, sender.clone())?;
            }
        }
        // } else if arg.action == Action::Next {
        //     let new_step = self.db.steps[self.step_id];
        //     let new_depth = self.db.calls[new_step.call_key].depth;
        //     if original_depth < new_depth {
        //         // assuming at beginning we always have depth 0, and we can't hit this situation for now hopefully
        //         if self.step_id.0 as usize == self.db.steps.len() - 1 {
        //             self.send_notification(NotificationKind::Warning, "Limit of record at the end reached!", false)?;
        //         } else {
        //             error!("next from #{original_step_id:?} ended at a deeper depth: original: {original_depth} new: {new_depth}");
        //         }
        //     }
        // }

        self.respond_dap(request, 0, sender)?;
        Ok(())
    }

    pub fn mcr_live_step(
        &mut self,
        request: dap::Request,
        args: McrLiveStepArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let action = match args.action.as_str() {
            "continue" => Action::Continue,
            "next" => Action::Next,
            "stepIn" | "step-in" | "step_in" => Action::StepIn,
            "stepOut" | "step-out" | "step_out" => Action::StepOut,
            other => return Err(format!("unsupported live MCR action: {other}").into()),
        };
        let _thread_id = args.thread_id;
        self.step(request, StepArg::new(action, false), sender)
    }

    pub fn mcr_get_recording_head(
        &mut self,
        request: dap::Request,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let head = self.replay.recording_head()?;
        self.respond_dap(
            request,
            RecordingHeadResponse {
                rr_ticks: head,
                recording_head: head,
                head,
            },
            sender,
        )
    }

    pub fn mcr_restore_at(
        &mut self,
        request: dap::Request,
        args: McrRestoreAtArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let restored = self.replay.restore_at(args.rr_ticks, None, None, None)?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false, sender.clone())?;
        self.respond_dap(request, restored, sender)
    }

    pub fn seek_to_geid(
        &mut self,
        request: dap::Request,
        args: SeekToGeidArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let restored = self.replay.seek_to_geid(args.geid)?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false, sender.clone())?;
        self.respond_dap(request, restored, sender)
    }

    /// Ensure program events are loaded and cached.
    ///
    /// On the first call, events are loaded from the replay backend,
    /// registered in the event database, and cached in `self.cached_events`.
    /// Subsequent calls are no-ops (the cache is already populated).
    ///
    /// Used by `event_load()` and other handlers that need the full set of
    /// events.  `load_terminal()` uses a separate fast path
    /// (`ensure_terminal_events_loaded`) that avoids loading all events.
    fn ensure_events_loaded(&mut self) -> Result<(), Box<dyn Error>> {
        if self.cached_events.is_none() || self.is_live_recreator_session() {
            let events_data = self.replay.load_events()?;

            // Register all events in the event database (needed by
            // tracepoints, terminal output, etc.).
            self.event_db.replace_record_events(&events_data.events);

            self.cached_events = Some(events_data.events);
        }
        Ok(())
    }

    /// Loads program events with optional pagination.
    ///
    /// On the first call, events are loaded from the replay backend and
    /// cached in `self.cached_events`.  Subsequent calls reuse the cache.
    /// The DAP request arguments may contain `start` (0-based offset) and
    /// `count` (max events to return).  When both are absent or zero, the
    /// first 20 events are returned for backwards compatibility.
    ///
    /// The daemon (`handle_py_events`) already forwards `start`/`count`
    /// from the Python API to this handler as part of the
    /// `ct/event-load` arguments.
    pub fn event_load(&mut self, req: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        // Parse optional pagination parameters from the request.
        let start = req
            .arguments
            .get("start")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0)
            .max(0) as usize;
        let count = req
            .arguments
            .get("count")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0)
            .max(0) as usize;

        self.ensure_events_loaded()?;

        // Safety: `ensure_events_loaded` guarantees `cached_events` is Some.
        let all_events = match self.cached_events.as_ref() {
            Some(events) => events,
            None => {
                return Err("internal error: cached_events is None after population".into());
            }
        };

        // Determine the slice to return.
        let (page_events, page_contents) = if count > 0 {
            // Explicit pagination: return the requested window.
            let clamped_start = start.min(all_events.len());
            let clamped_end = (clamped_start + count).min(all_events.len());
            let slice = &all_events[clamped_start..clamped_end];
            let contents = slice.iter().map(|e| e.content.as_str()).collect::<Vec<_>>().join("\n");
            (slice.to_vec(), contents)
        } else {
            // Legacy behaviour: return the first 20 events (matches
            // the original `first_events` semantics).
            let n = all_events.len().min(20);
            let slice = &all_events[..n];
            let contents = slice.iter().map(|e| e.content.as_str()).collect::<Vec<_>>().join("\n");
            (slice.to_vec(), contents)
        };

        let raw_event = self.dap_client.updated_events(page_events.clone())?;
        sender.send(raw_event)?;

        let raw_event_content = self.dap_client.updated_events_content(page_contents.clone())?;
        sender.send(raw_event_content)?;

        // M25b — Event Log surface for correlation markers.
        // Project the page's events into the marker-row view by
        // decoding `ProgramEvent.metadata` for any row that carries a
        // `MarkerPayload` shape. The decoded slice is cached so that
        // repeat `ct/event-load` calls serve marker rows from cache
        // without re-decoding (the §3.2.1 one-time-evaluation
        // contract — verified by the M25b DAP test
        // `test_dap_event_log_marker_response_serves_from_cache_post_load`).
        //
        // We index the cached projection by the *absolute* event index
        // (the row's offset into `cached_events`) so that the page-
        // local `event_index` field on each `MarkerEventRow` lines up
        // with the consumer's row indices.
        let marker_rows = self.collect_marker_rows_for_page(&page_events, start, count);

        // Include event data in the DAP response body so that
        // `session.customRequest("ct/event-load")` resolves with the data
        // (VS Code's customRequest returns the response body, not events).
        self.respond_dap(
            req,
            serde_json::json!({
                "events": page_events,
                "content": page_contents,
                "markers": marker_rows,
            }),
            sender,
        )?;

        Ok(())
    }

    /// M25b — Build the marker-row projection for the events served by
    /// a single `ct/event-load` page. Honours the §3.2.1
    /// one-time-evaluation contract: the projection over the full
    /// `cached_events` slice is computed on the first call and cached;
    /// repeat calls reuse the cached slice (filtered to the page) and
    /// do NOT re-decode `ProgramEvent.metadata`. The
    /// `marker_decode_calls` counter advances only on the first build.
    fn collect_marker_rows_for_page(
        &mut self,
        page_events: &[ProgramEvent],
        start: usize,
        count: usize,
    ) -> Vec<MarkerEventRow> {
        if self.cached_marker_rows.is_none() {
            let all_events = match self.cached_events.as_ref() {
                Some(events) => events,
                None => return Vec::new(),
            };
            let mut rows: Vec<MarkerEventRow> = Vec::new();
            for (absolute_index, event) in all_events.iter().enumerate() {
                self.marker_decode_calls
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let Some(payload) = crate::correlation_markers::MarkerPayload::decode(&event.metadata) else {
                    continue;
                };
                rows.push(MarkerEventRow {
                    event_index: absolute_index,
                    marker_id: payload.marker_id,
                    boundary_id: payload.boundary_id,
                    direction: payload.direction.as_str().to_string(),
                    key_text: payload.key_text,
                    key_value: payload.key_value,
                    show_text: payload.show_text,
                    show_value: payload.show_value,
                    description: payload.description,
                    format: payload.format,
                    source_path: event.high_level_path.clone(),
                    source_line: event.high_level_line.max(0) as usize,
                    step_id: event.direct_location_rr_ticks,
                });
            }
            self.cached_marker_rows = Some(rows);
        }
        // Filter the cached projection to the page window. When the
        // call uses the legacy "first 20" fallback the lower / upper
        // bounds wrap the page's first/last absolute event index.
        let (lower, upper) = if count > 0 {
            (start, start.saturating_add(page_events.len()))
        } else {
            // Legacy fallback — pages slice `[0..min(20, len)]`.
            (0usize, page_events.len())
        };
        self.cached_marker_rows
            .as_ref()
            .map(|all| {
                all.iter()
                    .filter(|row| row.event_index >= lower && row.event_index < upper)
                    .map(|row| {
                        let mut adjusted = row.clone();
                        // Re-base `event_index` to be page-local so the
                        // frontend's join against the `events: [...]`
                        // array is correct.
                        adjusted.event_index = row.event_index.saturating_sub(lower);
                        adjusted
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// M25b — `ct/pairIndexLookup` handler. Returns the counterparts
    /// of the queried `(boundary_id, direction, key_value)` triple by
    /// walking this handler's local pair index. For a multi-trace
    /// session, the request is routed to the trace that the frontend
    /// resolved the marker against; cross-trace counterparts are
    /// resolved by the session-level [`crate::session_handler::
    /// SessionHandler::pair_index`] surface. This per-handler variant
    /// keeps the single-trace path cheap and avoids a session-wide
    /// re-derivation on every UI lookup.
    pub fn pair_index_lookup(
        &mut self,
        req: dap::Request,
        args: PairIndexLookupArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let direction =
            crate::correlation_markers::MarkerDirection::parse(&args.direction).ok_or_else(|| -> Box<dyn Error> {
                format!(
                    "ct/pairIndexLookup: unknown direction `{}` (expected `send` or `recv`)",
                    args.direction
                )
                .into()
            })?;

        let index = self.build_local_pair_index();
        let opposite = direction.opposite();
        let counterparts: Vec<PairIndexCounterpart> = index
            .get(&args.boundary_id, opposite)
            .iter()
            .filter(|view| view.payload.key_value == args.key_value)
            .map(|view| PairIndexCounterpart {
                recording_id: view.recording_id.clone(),
                step_id: view.step_id,
                source_path: view.source_path.clone(),
                source_line: view.source_line,
                marker_id: view.payload.marker_id,
                boundary_id: view.payload.boundary_id.clone(),
                direction: view.payload.direction.as_str().to_string(),
                key_text: view.payload.key_text.clone(),
                key_value: view.payload.key_value.clone(),
                show_text: view.payload.show_text.clone(),
                show_value: view.payload.show_value.clone(),
                format: view.payload.format.clone(),
            })
            .collect();

        self.respond_dap(req, serde_json::json!({ "counterparts": counterparts }), sender)?;
        Ok(())
    }

    /// Test-only setter for the per-handler `cached_events` slice.
    /// Mirrors the M21 pattern (`install_materialized_origin_metadata_decoder`)
    /// of seeding handler state without going through the full
    /// `replay.load_events()` pipeline. The setter also invalidates
    /// the M25b marker-row cache so subsequent `event_load` calls
    /// re-derive against the freshly-installed events.
    pub fn set_cached_events_for_tests(&mut self, events: Vec<ProgramEvent>) {
        self.cached_events = Some(events);
        self.cached_marker_rows = None;
        self.marker_decode_calls.store(0, std::sync::atomic::Ordering::Relaxed);
    }

    /// Build the per-handler [`crate::correlation_index::PairIndex`]
    /// by walking this handler's `event_db.firings_by_source_location`
    /// table and decoding the marker payload from each firing's
    /// `ProgramEvent.metadata` slot. Mirrors the session-level
    /// [`crate::session_handler::SessionHandler::pair_index`] surface
    /// scoped to a single trace — used by `pair_index_lookup` and by
    /// the M25b DAP tests.
    pub fn build_local_pair_index(&self) -> crate::correlation_index::PairIndex {
        use crate::correlation_index::MarkerEventView;
        use crate::correlation_markers::MarkerPayload;

        let mut events: Vec<MarkerEventView> = Vec::new();
        for (_, firings) in self.event_db.firings_by_source_location.iter() {
            for firing in firings {
                let Some(event) = self.event_db.program_event_at(firing) else {
                    continue;
                };
                let Some(payload) = MarkerPayload::decode(&event.metadata) else {
                    continue;
                };
                events.push(MarkerEventView::new(
                    String::new(),
                    firing.step_id.0,
                    event.high_level_path.clone(),
                    event.high_level_line.max(0) as usize,
                    payload,
                ));
            }
        }
        crate::correlation_index::PairIndex::build(&events)
    }

    pub fn event_jump(
        &mut self,
        _req: dap::Request,
        event: ProgramEvent,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if event.kind != EventLogKind::TraceLogEvent {
            let _ = self.replay.event_jump(&event)?;
        } else {
            self.replay.tracepoint_jump(&event)?;
        }
        self.step_id = self.replay.current_step_id();
        self.complete_move(false, sender)?;

        Ok(())
    }

    pub fn calltrace_jump(
        &mut self,
        _req: dap::Request,
        location: Location,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Materialized {
            let step_id = StepId(location.rr_ticks.0); // using this field
            // for compat with rr/gdb core support
            self.replay.jump_to(step_id)?;
            self.step_id = self.replay.current_step_id();
        } else {
            // TODO: eventually calltrace in the future
            // for now support only callstack-mode
            self.replay.callstack_jump(location.callstack_depth)?;
            let _ = self.replay.load_location(&mut self.expr_loader)?;
            self.step_id = self.replay.current_step_id();
        }
        self.complete_move(false, sender)?;

        Ok(())
    }

    pub fn calltrace_search(
        &mut self,
        req: dap::Request,
        arg: CallSearchArg,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let mut calls: Vec<Call> = vec![];
        let mut list: Vec<usize> = vec![];
        let re = Regex::new(&arg.value.clone())?;

        for (id, function) in self.reader.functions_iter() {
            if re.is_match(&function.name) {
                list.push(id.0);
            }
        }

        for db_call in self.reader.calls_iter() {
            if list.contains(&db_call.function_id.0) {
                // expanded children count not relevant here
                calls.push(self.reader.to_call(db_call, &mut self.expr_loader));
            }
        }

        let raw_event = self.dap_client.calltrace_search_event(calls.clone())?;
        sender.send(raw_event)?;
        // Include search results in the response body for customRequest().
        self.respond_dap(req, &calls, sender)?;
        Ok(())
    }

    fn id_to_name(&self, variable_id: VariableId) -> &str {
        self.reader.variable_name(variable_id).unwrap_or("<unknown>")
    }

    pub fn load_history(
        &mut self,
        req: dap::Request,
        load_history_arg: LoadHistoryArg,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Recreator {
            self.replay = Box::new(RecreatorReplaySession::new(
                "tracepoint",
                self.tracepoint_rr_worker_index,
                self.ct_rr_args.clone(),
            ));
            self.tracepoint_rr_worker_index += 1;
        };
        let (history_results_with_records, address) = self.replay.load_history(&load_history_arg)?;
        // Per spec §3.2.3 (and the M2 deliverable expanding
        // `ct/load-history` with per-entry origin summaries), each
        // historic value carries its own `OriginSummary`. On a
        // materialized trace without an omniscient DB, the default
        // mode is *placeholder* — each entry encodes its
        // (variable_name, historic step_id) into the placeholder
        // token so the frontend can lazily fill it via
        // `ct/originSummary` (spec §5.3.2).
        //
        // M21 — when the trace is in Mode 3 (omniscient DB +
        // origin metadata; see `classify_eager_mode`), the
        // dispatcher flips the per-entry default to eager. Each
        // history entry's summary is computed directly from the
        // M19 metadata decoder. Lazy intervals (Mode 3 `lazy`)
        // fall through to the placeholder so the frontend renders
        // `[?]` until the background indexer fills the interval.
        //
        // Performance: we snapshot the per-call state ONCE (mode
        // class, decoder, variable id, patterns fingerprint) before
        // walking the entries.  The hot loop then makes zero
        // additional calls into `Handler` slots that would otherwise
        // re-read the trace's `meta_dat/` directory per row (which is
        // unreachable within the M21 spec's 700 ms budget for a
        // 10 000-entry history).
        let eager_class = self.classify_eager_mode();
        let decoder_snapshot = if self.trace_kind == TraceKind::Materialized && eager_class.flips_eager() {
            self.clone_origin_metadata_decoder()
        } else {
            None
        };
        let variable_id_snapshot = if eager_class.flips_eager() {
            self.reader.variable_id_for(&load_history_arg.expression)
        } else {
            None
        };
        let patterns_fingerprint_snapshot = self.patterns_fingerprint_cached();
        let builder_class = eager_class;
        let mut history_results: Vec<HistoryResult> = Vec::with_capacity(history_results_with_records.len());
        for r in history_results_with_records.iter() {
            let entry_step_id = StepId(r.location.rr_ticks.0);
            let summary = if self.trace_kind == TraceKind::Materialized {
                // Try eager path when the trace is Mode 3 + the
                // metadata decoder covers `(variable_id, step_id)`.
                let eager = if builder_class.flips_eager() {
                    if let (Some(var_id), Some(decoder)) = (variable_id_snapshot, decoder_snapshot.as_ref()) {
                        crate::eager_origin_mode::EagerSummaryBuilder::new(Some(decoder), builder_class)
                            .lookup_eager(var_id, entry_step_id)
                    } else {
                        None
                    }
                } else {
                    None
                };
                Some(eager.unwrap_or_else(|| {
                    self.build_origin_summary_placeholder_with_fingerprint(
                        &load_history_arg.expression,
                        entry_step_id,
                        &patterns_fingerprint_snapshot,
                    )
                }))
            } else if eager_class.flips_eager() {
                // Non-materialized backend in eager mode — same per-key
                // decoder hit, otherwise placeholder so the frontend
                // renders `[?]`.
                let eager = if let (Some(var_id), Some(decoder)) = (variable_id_snapshot, decoder_snapshot.as_ref()) {
                    crate::eager_origin_mode::EagerSummaryBuilder::new(Some(decoder), builder_class)
                        .lookup_eager(var_id, entry_step_id)
                } else {
                    None
                };
                Some(eager.unwrap_or_else(|| {
                    self.build_origin_summary_placeholder_with_fingerprint(
                        &load_history_arg.expression,
                        entry_step_id,
                        &patterns_fingerprint_snapshot,
                    )
                }))
            } else {
                None
            };
            history_results.push(HistoryResult {
                location: r.location.clone(),
                value: to_ct_value(&r.value),
                time: r.time,
                description: r.description.clone(),
                origin_summary: summary,
            });
        }

        let history_update = HistoryUpdate::new(load_history_arg.expression.clone(), address, &history_results);
        let raw_event = self.dap_client.updated_history_event(history_update.clone())?;

        sender.send(raw_event)?;

        // Include history data in the response body for customRequest().
        self.respond_dap(req, &history_update, sender)?;
        Ok(())
    }

    pub fn history_jump(
        &mut self,
        _req: dap::Request,
        loc: Location,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        info!("history_jump: doing location jump to {loc:?}");
        self.replay.location_jump(&loc)?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false, sender)?;
        Ok(())
    }

    // -----------------------------------------------------------------
    // Value Origin Tracking — `ct/originChain` and `ct/originSummary`
    // dispatch (spec §5.3, §5.3.2). Materialized traces drive the Path B
    // algorithm in `db::MaterializedReplaySession`; emulator and
    // recreator sessions return DAP error 6103 until M11 / M18.
    // -----------------------------------------------------------------

    /// Dispatch handler for `ct/originChain` (spec §5.3).
    pub fn origin_chain(
        &mut self,
        req: dap::Request,
        args: task::CtOriginChainArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        // Build the per-request budget. Defaults from spec §6.1.7. The
        // recreator (RR) backend caps `max_hops` lower than the
        // materialized backend per M11 spec §6.3 — half (8 vs 16) —
        // because each RR hop costs a reverse-continue.
        let mut budget = task::OriginBudget {
            max_hops: args.max_hops,
            wall_clock_ms: task::DEFAULT_ORIGIN_WALL_CLOCK_MS,
            max_steps_scanned: task::DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
        };
        if self.trace_kind == TraceKind::Recreator && budget.max_hops > crate::recreator_origin::RR_DEFAULT_MAX_HOPS {
            budget.max_hops = crate::recreator_origin::RR_DEFAULT_MAX_HOPS;
        }
        // M17 — MCR backend caps `max_hops` at the raised default of 32
        // (per spec §12). Requests carrying a higher `args.max_hops`
        // are clamped down here so the per-tier latency stays bounded.
        if self.trace_kind == TraceKind::Emulator && budget.max_hops > crate::emulator_origin::MCR_DEFAULT_MAX_HOPS {
            budget.max_hops = crate::emulator_origin::MCR_DEFAULT_MAX_HOPS;
        }
        let result = match self.trace_kind {
            TraceKind::Materialized => {
                let patterns = self.load_origin_patterns();
                let meta_dat_sources_root = self.meta_dat_sources_root();
                self.materialized_origin_chain(&args, &budget, &patterns, meta_dat_sources_root.as_deref())
            }
            TraceKind::Emulator => self.emulator_origin_chain(&args, &budget),
            TraceKind::Recreator => {
                let patterns = self.load_origin_patterns();
                let meta_dat_sources_root = self.meta_dat_sources_root();
                self.recreator_origin_chain(&args, &budget, &patterns, meta_dat_sources_root.as_deref())
            }
        };
        match result {
            Ok(chain) => {
                // Emit the `ct/updated-origin-chain` event alongside the
                // response so the event-driven UI can react to lazy
                // continuations without re-issuing a fresh request.
                let raw_event = self.dap_client.updated_origin_chain_event(&chain)?;
                sender.send(raw_event)?;
                self.respond_dap(req, &chain, sender)?;
                Ok(())
            }
            Err(origin_err) => {
                self.send_origin_error(req, sender, origin_err)?;
                Ok(())
            }
        }
    }

    /// Dispatch handler for `ct/originSummary` — batch placeholder fill
    /// (spec §5.3.2).
    pub fn origin_summary(
        &mut self,
        req: dap::Request,
        args: task::CtOriginSummaryArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        // Per spec §5.3.2 per-token errors yield UnknownVariable /
        // UnknownSource summaries rather than request-level failures.
        let mut summaries = Vec::with_capacity(args.tokens.len());
        for token_str in &args.tokens {
            match self.resolve_single_placeholder(token_str) {
                Ok(summary) => summaries.push(summary),
                Err(_) => {
                    summaries.push(task::OriginSummary {
                        terminator_kind: task::TerminatorKindWire::UnknownVariable,
                        ..task::OriginSummary::default()
                    });
                }
            }
        }
        self.respond_dap(req, &task::CtOriginSummaryResponse { summaries }, sender)?;
        Ok(())
    }

    fn materialized_origin_chain(
        &mut self,
        args: &task::CtOriginChainArguments,
        budget: &task::OriginBudget,
        patterns: &origin_classifier::PatternSet,
        meta_dat_sources_root: Option<&Path>,
    ) -> Result<task::OriginChain, crate::origin_query::OriginError> {
        // The materialized algorithm lives on `MaterializedReplaySession`.
        // The handler keeps a `Box<dyn ReplaySession>` so we down-cast to
        // the concrete session before invoking the algorithm. Downcast
        // failure means the backend was constructed for a non-materialized
        // trace kind — surface 6103 so the frontend can render the
        // "coming soon" affordance.
        let any_session = self.replay.as_any_mut();
        match any_session.downcast_mut::<MaterializedReplaySession>() {
            Some(session) => {
                session.origin_chain_inferred(args, budget, &mut self.expr_loader, patterns, meta_dat_sources_root)
            }
            None => Err(crate::origin_query::OriginError::unsupported_backend(
                "non-materialized backend (downcast failed)",
            )),
        }
    }

    /// M11 — dispatch to the RR-driver origin algorithm (spec §6.3).
    ///
    /// Mirrors [`Self::materialized_origin_chain`] but routes through
    /// the `RecreatorReplaySession` worker transport. The actual
    /// algorithm lives in [`crate::recreator_origin::run_rr_origin_chain`];
    /// this helper is just the trait-object down-cast + argument plumbing.
    ///
    /// When the down-cast fails (the backend was constructed for a
    /// non-Recreator trace kind despite `self.trace_kind ==
    /// TraceKind::Recreator`) we surface DAP error 6103 so the frontend
    /// renders the "coming soon" affordance instead of a misleading
    /// stack trace.
    fn recreator_origin_chain(
        &mut self,
        args: &task::CtOriginChainArguments,
        budget: &task::OriginBudget,
        patterns: &origin_classifier::PatternSet,
        meta_dat_sources_root: Option<&Path>,
    ) -> Result<task::OriginChain, crate::origin_query::OriginError> {
        let any_session = self.replay.as_any_mut();
        match any_session.downcast_mut::<RecreatorReplaySession>() {
            Some(session) => crate::recreator_origin::run_rr_origin_chain(
                session,
                args,
                budget,
                &mut self.expr_loader,
                patterns,
                meta_dat_sources_root,
            ),
            None => Err(crate::origin_query::OriginError::unsupported_backend(
                "recreator (downcast failed — handler initialised for a non-recreator trace kind)",
            )),
        }
    }

    /// M17 / M20 — dispatch to the appropriate MCR-backend origin
    /// algorithm.
    ///
    /// **Tier selection (spec §6.7 dispatch summary):**
    ///
    /// 1. **M20 omniscient tier** (spec §6.5 + §6.8.2) — selected when
    ///    the session surfaces an [`crate::omniscient_db::OmniscientDb`]
    ///    via [`crate::replay::ReplaySession::omniscient_db`]. The M19
    ///    [`crate::origin_metadata_indexer::OriginMetadataDecoder`]
    ///    routes us through the metadata-driven §6.8.2 path when also
    ///    present (Mode 3); otherwise we fall through to the §6.5
    ///    write-log + classifier shape (Mode 2). The omniscient log
    ///    supersedes both M17 tiers — no data-breakpoint or
    ///    reverse-step work is needed.
    ///
    /// 2. **M17 hybrid tier** (spec §6.4) — fallback when no
    ///    omniscient DB is attached to the trace. This keeps the
    ///    M17-era undo-map + reverse-step path live for traces
    ///    recorded before the omniscient indexer landed on the
    ///    recorder side.
    ///
    /// When the down-cast fails — i.e. `self.trace_kind ==
    /// TraceKind::Emulator` but the handler was constructed with a
    /// placeholder session that is NOT an `EmulatorReplaySession` —
    /// we surface DAP error 6103 so the frontend renders the
    /// "coming soon" affordance instead of a misleading stack trace.
    fn emulator_origin_chain(
        &mut self,
        args: &task::CtOriginChainArguments,
        budget: &task::OriginBudget,
    ) -> Result<task::OriginChain, crate::origin_query::OriginError> {
        let any_session = self.replay.as_any_mut();
        match any_session.downcast_mut::<crate::emulator_session::EmulatorReplaySession>() {
            Some(session) => {
                // Tier-select per spec §6.7. The omniscient log
                // supersedes M17's hybrid path whenever the trace
                // ships one; the metadata decoder is optional and
                // routes us through the §6.8.2 metadata-driven path
                // when present.
                //
                // The decoder is read first so the borrow doesn't
                // overlap with the mutable session borrow `run_*`
                // takes. We clone the decoder out via
                // `OriginMetadataDecoder: Clone`; the decoder owns its
                // sorted indexes so the clone is cheap relative to the
                // omniscient query work that follows.
                // Tier-select per spec §6.7. The omniscient log
                // supersedes M17's hybrid path whenever the trace
                // ships one; the metadata decoder is optional and
                // routes us through the §6.8.2 metadata-driven path
                // when present.
                //
                // `OmniscientDb` is consulted in a sequenced borrow:
                // we copy the (zero-sized) FFI handle out by value so
                // the M20 driver can be called with the session
                // unborrowed. The session itself isn't touched by the
                // omniscient driver — the algorithm is pure against
                // the trait surface.
                if session.omniscient_db().is_some_and(|db| db.is_present()) {
                    let handle = crate::omniscient_db::FfiOmniscientDb::new();
                    let decoder = session.origin_metadata_decoder().cloned();
                    return crate::omniscient_origin::run_omniscient_origin_chain(
                        &handle,
                        decoder.as_ref(),
                        args,
                        budget,
                    );
                }
                // No omniscient log on the trace — fall back to the
                // M17 hybrid path (undo-map last-mile + breakpoint
                // fallback).
                crate::emulator_origin::run_mcr_origin_chain(session, args, budget)
            }
            None => Err(crate::origin_query::OriginError::unsupported_backend(
                "emulator (downcast failed — handler initialised for a non-emulator trace kind, \
                 or the F5c-4 browser-replay session wasn't supplied)",
            )),
        }
    }

    fn resolve_single_placeholder(
        &mut self,
        token_str: &str,
    ) -> Result<task::OriginSummary, crate::origin_query::OriginError> {
        let token = crate::origin_query::OriginContinuationToken::decode(token_str)?;
        let args = task::CtOriginChainArguments {
            variable_name: token.query_variable.clone(),
            variable_path: Vec::new(),
            frame_id: token.current_frame,
            step_id: token.query_step_id,
            thread_id: 0,
            max_hops: task::DEFAULT_ORIGIN_MAX_HOPS,
            lazy: false,
            continuation_token: None,
            session_id: String::new(),
            classify_source: true,
        };
        let budget = task::OriginBudget::default();
        let patterns = self.load_origin_patterns();
        let meta_dat_sources_root = self.meta_dat_sources_root();
        let chain = self.materialized_origin_chain(&args, &budget, &patterns, meta_dat_sources_root.as_deref())?;
        Ok(origin_chain_to_summary(&chain, false))
    }

    fn send_origin_error(
        &mut self,
        req: dap::Request,
        sender: Sender<DapMessage>,
        origin_err: crate::origin_query::OriginError,
    ) -> Result<(), Box<dyn Error>> {
        let body = serde_json::json!({
            "originErrorCode": origin_err.code.as_u32(),
            "message": origin_err.message,
            "detail": origin_err.detail,
        });
        let response = dap::DapMessage::Response(dap::Response {
            base: dap::ProtocolMessage {
                seq: self.dap_client.seq,
                type_: "response".to_string(),
            },
            request_seq: req.base.seq,
            success: false,
            command: req.command.clone(),
            message: Some(origin_err.message.clone()),
            body,
        });
        self.dap_client.seq += 1;
        sender.send(response)?;
        Ok(())
    }

    /// Locate the bundled-sources directory `meta_dat/sources/` for the
    /// active trace, if it exists. Returns `None` when the trace was
    /// recorded without bundled sources (the classifier falls back to
    /// filesystem reads — spec §6.1 "Source-file resolution").
    fn meta_dat_sources_root(&self) -> Option<std::path::PathBuf> {
        let candidate = self.reader.workdir().join("meta_dat").join("sources");
        if candidate.is_dir() { Some(candidate) } else { None }
    }

    /// Load the layered origin-pattern set per spec §7.4.
    ///
    /// Honours, in precedence order:
    ///
    /// 1. The trace's `meta_dat/origin-patterns/_overrides.toml`
    ///    (trace-local overrides).
    /// 2. The user's `~/.config/codetracer/origin-patterns.toml`
    ///    (personal overrides).
    /// 3. Embedded library patterns under
    ///    `meta_dat/origin-patterns/<library>/...` inside the trace.
    /// 4. The built-in catalogue (spec §7.3).
    ///
    /// On any load error we fall back to the built-in catalogue so the
    /// chain query still succeeds — the alternative of failing the
    /// whole DAP request because one TOML file has a typo would be a
    /// worse UX.
    fn load_origin_patterns(&self) -> origin_classifier::PatternSet {
        let patterns_root = self.reader.workdir().join("meta_dat").join("origin-patterns");
        let trace_overrides = patterns_root.join("_overrides.toml");
        let trace_overrides_path = if trace_overrides.exists() {
            Some(trace_overrides.as_path())
        } else {
            None
        };
        let embedded_root = if patterns_root.is_dir() {
            Some(patterns_root.as_path())
        } else {
            None
        };

        let personal_overrides_buf = personal_origin_patterns_path();
        let personal_overrides_path = personal_overrides_buf
            .as_ref()
            .filter(|p| p.exists())
            .map(|p| p.as_path());

        match origin_classifier::PatternSet::load_layered(trace_overrides_path, personal_overrides_path, embedded_root)
        {
            Ok(set) => set,
            Err(e) => {
                log::warn!(
                    "origin-patterns layered load failed at {}: {e}; falling back to built-in catalogue",
                    patterns_root.display()
                );
                origin_classifier::PatternSet::built_in()
            }
        }
    }

    /// M21 — classify the active trace's eager-mode state per spec
    /// §6.8.6.  Combines the on-disk
    /// `meta_dat/origin-config.toml` (M19 [`OriginConfig`]) with the
    /// runtime omniscient-DB + metadata-decoder presence so the
    /// dispatcher can flip `ct/load-history` / `ct/load-flow` defaults
    /// to eager only when the trace genuinely supports it (Mode 3).
    ///
    /// The class also drives the State Pane "Origin metadata: …"
    /// indicator surfaced through `ct/originMode`.
    pub fn classify_eager_mode(&mut self) -> crate::eager_origin_mode::EagerModeClass {
        let workdir = self.reader.workdir().to_path_buf();
        let omniscient_present = self.replay.omniscient_db().is_some_and(|db| db.is_present());
        let metadata_decoder_present = self.origin_metadata_decoder_present();
        crate::eager_origin_mode::classify_eager_mode(&workdir, omniscient_present, metadata_decoder_present)
    }

    /// Whether the active session ships an
    /// [`crate::origin_metadata_indexer::OriginMetadataDecoder`].
    /// Browser-replay (Emulator) sessions surface the decoder via
    /// [`crate::emulator_session::EmulatorReplaySession::origin_metadata_decoder`];
    /// materialized traces (which have no session to hang the decoder
    /// off) use the in-handler slot
    /// [`Handler::materialized_origin_metadata_decoder`]. The helper
    /// centralises probing so callers don't need to know which slot
    /// the decoder lives in.
    fn origin_metadata_decoder_present(&mut self) -> bool {
        if self.materialized_origin_metadata_decoder.is_some() {
            return true;
        }
        if let Some(session) = self
            .replay
            .as_any_mut()
            .downcast_mut::<crate::emulator_session::EmulatorReplaySession>()
        {
            return session.origin_metadata_decoder().is_some();
        }
        false
    }

    /// M21 — install a materialized-trace
    /// [`crate::origin_metadata_indexer::OriginMetadataDecoder`].
    /// Used by the M21 verification fixture to inject a pre-populated
    /// decoder; the production recorder-driven boot path replaces this
    /// hook with an automatic decoder load alongside the
    /// `meta_dat/origin-config.toml` read.
    pub fn install_materialized_origin_metadata_decoder(
        &mut self,
        decoder: crate::origin_metadata_indexer::OriginMetadataDecoder,
    ) {
        self.materialized_origin_metadata_decoder = Some(decoder);
    }

    /// M21 — test/bench accessor: clone the active trace's
    /// `OriginMetadataDecoder` (materialized slot, or browser-replay
    /// session). Lets the M21 latency assertions exercise the
    /// `EagerSummaryBuilder` against the same decoder the dispatcher
    /// would use, without going through the DAP request/response
    /// round-trip whose dominant cost (M2 step walks) is outside
    /// M21's scope.
    pub fn clone_origin_metadata_decoder_for_test(
        &mut self,
    ) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
        self.clone_origin_metadata_decoder()
    }

    /// M21 — dispatcher handler for `ct/originMode`. Returns the
    /// active trace's eager-mode indicator label (`"on"` / `"lazy"` /
    /// `"off"` / `"unavailable"`) per spec §3.7 + M21 deliverable #4.
    /// The State Pane settings sub-menu renders the literal value.
    pub fn origin_mode(&mut self, req: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        let class = self.classify_eager_mode();
        let body = serde_json::json!({ "mode": class.indicator_label() });
        self.respond_dap(req, body, sender)?;
        Ok(())
    }

    /// Compute the per-variable origin summary for an *eager* surface
    /// (e.g. `ct/load-locals`). On the materialized backend this is a
    /// truncated origin-chain query; on backends without origin support
    /// the summary degrades to a UnknownSource placeholder.
    ///
    /// Consults the per-session `(VariableId, StepId)` cache (M2
    /// deliverable, spec §3.2.3). On classifier / chain-build failure
    /// returns an `UnknownSource` summary rather than propagating —
    /// the surrounding response (load-locals etc.) must not fail just
    /// because one variable's origin is unknown.
    pub(crate) fn build_origin_summary_for_local(&mut self, var_name: &str) -> task::OriginSummary {
        self.build_origin_summary_for_local_at(var_name, self.step_id)
    }

    /// Variant of `build_origin_summary_for_local` that takes an
    /// explicit step. Used by callers that want the origin of a
    /// historical value (e.g. the eager `ct/load-history` path used
    /// when an omniscient DB is present per spec §3.2.3 / §6.8).
    pub(crate) fn build_origin_summary_for_local_at(&mut self, var_name: &str, step_id: StepId) -> task::OriginSummary {
        if self.trace_kind != TraceKind::Materialized {
            return placeholder_unknown_summary();
        }
        // Cache key is `(variable_id, step_id)`. We resolve the
        // variable name to a VariableId via the reader's name table.
        // Unknown names fall through to a fresh build (no cache key
        // possible — but they will produce a placeholder UnknownSource
        // summary anyway). `StepId` is wrapped i64 without a `Hash`
        // derive in the trace-types crate, so the key is stored as
        // `(usize, i64)` (the wrapper-id newtype's payload pair).
        let cache_key: Option<(usize, i64)> = self.reader.variable_id_for(var_name).map(|vid| (vid.0, step_id.0));
        if let Some(ref key) = cache_key
            && let Some(cached) = self.origin_summary_cache.get(key)
        {
            return cached.clone();
        }

        // Cache miss — perform the actual chain build. Bump the
        // per-session chain-build counter for test instrumentation.
        self.origin_summary_chain_builds
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        let args = task::CtOriginChainArguments {
            variable_name: var_name.to_string(),
            variable_path: Vec::new(),
            frame_id: -1,
            step_id: step_id.0,
            thread_id: 0,
            max_hops: task::DEFAULT_ORIGIN_MAX_HOPS,
            lazy: false,
            continuation_token: None,
            session_id: String::new(),
            classify_source: true,
        };
        let budget = task::OriginBudget::default();
        let patterns = self.load_origin_patterns();
        let meta_dat_sources_root = self.meta_dat_sources_root();
        let summary = match self.materialized_origin_chain(&args, &budget, &patterns, meta_dat_sources_root.as_deref())
        {
            Ok(chain) => origin_chain_to_summary(&chain, false),
            Err(_) => placeholder_unknown_summary(),
        };
        if let Some(key) = cache_key {
            self.origin_summary_cache.insert(key, summary.clone());
        }
        summary
    }

    /// Build a *placeholder* summary suitable for off-screen / history /
    /// flow surfaces (spec §3.2.3 default-mode table) — uses the
    /// current step.
    pub(crate) fn build_origin_summary_placeholder(&mut self, var_name: &str) -> task::OriginSummary {
        self.build_origin_summary_placeholder_at(var_name, self.step_id)
    }

    /// M21 — build the per-entry origin summary for `ct/load-history`.
    /// On a Mode 3 trace returns the eager summary (decoder hit or
    /// placeholder when the lazy interval isn't yet analysed); on
    /// Mode 1 / Mode 2 falls back to the V1 placeholder default per
    /// spec §3.2.3.
    pub(crate) fn build_history_origin_summary(
        &mut self,
        class: crate::eager_origin_mode::EagerModeClass,
        var_name: &str,
        step_id: StepId,
    ) -> task::OriginSummary {
        if class.flips_eager() {
            return self.build_eager_or_placeholder_summary(class, var_name, step_id);
        }
        self.build_origin_summary_placeholder_at(var_name, step_id)
    }

    /// M21 — build the per-annotation origin summary for
    /// `ct/load-flow`. Same eager-vs-placeholder choice as
    /// `build_history_origin_summary` but used by the flow overlay
    /// pass.
    pub(crate) fn build_flow_origin_summary(
        &mut self,
        class: crate::eager_origin_mode::EagerModeClass,
        var_name: &str,
        step_id: StepId,
    ) -> task::OriginSummary {
        if class.flips_eager() {
            return self.build_eager_or_placeholder_summary(class, var_name, step_id);
        }
        self.build_origin_summary_placeholder_at(var_name, step_id)
    }

    /// M21 — shared resolver: ask the metadata decoder for an eager
    /// summary; fall back to the V1 placeholder on a miss so the
    /// frontend renders `[?]` for lazy-mode intervals that have not
    /// yet been analysed (spec §3.2.3).
    pub(crate) fn build_eager_or_placeholder_summary(
        &mut self,
        class: crate::eager_origin_mode::EagerModeClass,
        var_name: &str,
        step_id: StepId,
    ) -> task::OriginSummary {
        let var_id = self.reader.variable_id_for(var_name);
        if let Some(var_id) = var_id {
            // Clone the decoder so we can release the session borrow
            // before mutating the placeholder fallback path. The
            // decoder is `Clone` and owns its sorted indexes — the
            // clone is cheap relative to the per-row dispatcher work
            // that follows.
            let decoder = self.clone_origin_metadata_decoder();
            let builder = crate::eager_origin_mode::EagerSummaryBuilder::new(decoder.as_ref(), class);
            if let Some(summary) = builder.lookup_eager(var_id, step_id) {
                return summary;
            }
        }
        // Either the variable name didn't resolve, the decoder isn't
        // attached, or the (var, step) pair is in a not-yet-analysed
        // lazy interval. Surface a placeholder so the frontend can
        // either render `[?]` (lazy Mode 3) or fall back to the V1
        // batch-fill path (Mode 1 / Mode 2).
        self.build_origin_summary_placeholder_at(var_name, step_id)
    }

    /// Helper: clone the active trace's
    /// [`crate::origin_metadata_indexer::OriginMetadataDecoder`] when
    /// one is attached. Materialized traces hang the decoder off the
    /// handler directly; browser-replay (Emulator) sessions surface it
    /// through `EmulatorReplaySession::origin_metadata_decoder`.
    fn clone_origin_metadata_decoder(&mut self) -> Option<crate::origin_metadata_indexer::OriginMetadataDecoder> {
        if let Some(decoder) = self.materialized_origin_metadata_decoder.as_ref() {
            return Some(decoder.clone());
        }
        if let Some(session) = self
            .replay
            .as_any_mut()
            .downcast_mut::<crate::emulator_session::EmulatorReplaySession>()
        {
            return session.origin_metadata_decoder().cloned();
        }
        None
    }

    /// Build a placeholder summary for `(var_name, step_id)` — used by
    /// `ct/load-history` so each placeholder token round-trips through
    /// `ct/originSummary` with the *historic* variable+step pair (per
    /// spec §3.2.3 "the origin of *that historic value*, not the
    /// current value").
    pub(crate) fn build_origin_summary_placeholder_at(
        &mut self,
        var_name: &str,
        step_id: StepId,
    ) -> task::OriginSummary {
        let fingerprint = self.patterns_fingerprint_cached();
        self.build_origin_summary_placeholder_with_fingerprint(var_name, step_id, &fingerprint)
    }

    /// Return the cached classifier-pattern fingerprint, computing it
    /// lazily on first use. The fingerprint is invariant for the
    /// session — patterns are loaded once at trace open and never
    /// reloaded — so a per-session cache is safe and obviates the
    /// per-entry TOML read in the M21 hot loops.
    pub(crate) fn patterns_fingerprint_cached(&mut self) -> String {
        if let Some(fp) = &self.cached_patterns_fingerprint {
            return fp.clone();
        }
        let fp = self.load_origin_patterns().fingerprint().hex.clone();
        self.cached_patterns_fingerprint = Some(fp.clone());
        fp
    }

    /// M21 — fast-path variant of [`Self::build_origin_summary_placeholder_at`]
    /// that takes the pre-computed pattern fingerprint as input. The
    /// `ct/load-history` + `ct/load-flow` hot loops iterate over
    /// thousands of entries — calling [`Self::load_origin_patterns`]
    /// once per entry would re-read every TOML file off disk and walk
    /// the classifier-pattern catalogue 10 000 times. Caching the
    /// fingerprint at the loop's outer scope brings the per-entry
    /// allocation down to a single `String::to_string`.
    pub(crate) fn build_origin_summary_placeholder_with_fingerprint(
        &mut self,
        var_name: &str,
        step_id: StepId,
        patterns_fingerprint: &str,
    ) -> task::OriginSummary {
        let token = crate::origin_query::OriginContinuationToken {
            v: crate::origin_query::OriginContinuationToken::CURRENT_VERSION,
            query_variable: var_name.to_string(),
            query_step_id: step_id.0,
            current_step: step_id.0,
            current_frame: -1,
            current_var_name: var_name.to_string(),
            hops_emitted: 0,
            max_hops: task::DEFAULT_ORIGIN_MAX_HOPS,
            patterns_fingerprint: patterns_fingerprint.to_string(),
            source_digests: Vec::new(),
            issued_at: 0,
        };
        crate::origin_query::placeholder_summary(token)
    }

    fn load_path_id(&self, path: &str) -> Option<PathId> {
        self.reader.path_id_for(path)
    }

    fn find_next_step(&self, path_id: PathId, line: usize) -> Option<StepId> {
        if let Some(records) = self.reader.steps_on_line(path_id, line) {
            for record in records {
                if record.step_id > self.step_id {
                    return Some(record.step_id);
                }
            }
            return Some(records.last()?.step_id);
        }
        None
    }

    fn get_closest_step_id(&self, loc: &SourceLocation) -> Option<StepId> {
        // Check if there is a step on the line.
        let path_id = self.load_path_id(&loc.path)?;
        if let Some(step_id) = self.find_next_step(path_id, loc.line) {
            return Some(step_id);
        }

        // Get the closest step if not.
        let empty_map = HashMap::new();
        let line_map = self.reader.step_map_for_path(path_id).unwrap_or(&empty_map);
        let mut lines: Vec<&usize> = line_map.keys().collect();
        lines.sort();
        let mut closest_line: Option<usize> = None;

        for &line in lines.iter() {
            if line >= &loc.line {
                closest_line = Some(*line);
                break;
            }
        }

        if let Some(step_id) = self.find_next_step(path_id, closest_line?) {
            return Some(step_id);
        }

        // If no step found.
        None
    }

    pub fn source_line_jump(
        &mut self,
        req: dap::Request,
        source_location: SourceLocation,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Materialized {
            if let Some(step_id) = self.get_closest_step_id(&source_location) {
                self.replay.jump_to(step_id)?;
                self.step_id = self.replay.current_step_id();
                self.complete_move(false, sender.clone())?;
                // DAP requires a response for every request — the
                // `complete_move` above only emits the `stopped` event.
                // Without this respond_dap, headless DAP clients (the
                // bench, IDE adapters speaking strict DAP) block
                // indefinitely waiting for the response.
                self.respond_dap(req, 0, sender)?;
                Ok(())
            } else {
                let err: String = format!("unknown location: {}", &source_location);
                Err(err.into())
            }
        } else {
            // TODO: eventually do this in a separate replay and if we can't get to this place
            //   just discard it? or jump back to original start?
            //   for now if we can't go there, we run to entry(maybe TODO notification)

            //  if this fails, we stop and don't do the run to entry(the error returns because of `?`):
            //    i think it can't really return an error in our current impl though
            self.replay.disable_breakpoints()?;
            let b = self.replay.add_breakpoint(
                &source_location.path,
                source_location.line as i64,
                source_location.column,
            )?;

            let mut move_error = false;
            if let Err(e) = self.source_line_jump_moves_for_rr(&source_location) {
                warn!("  error in source line jump moves: {e:?}");
                warn!("  will try to run to entry");
                move_error = true;
            }
            self.replay.delete_breakpoint(&b)?; // make sure we do it before potential `?` fail in next functions
            self.replay.enable_breakpoints()?;

            let location = self.replay.load_location(&mut self.expr_loader)?;
            if move_error || location.path != source_location.path || location.line != source_location.line as i64 {
                self.send_notification(NotificationKind::Error, "can't jump to line", false, sender.clone())?;
                // (alexander): for now, less bad is to stay here: running to entry seems very confusing when you tried to jump to a completely different place IMO
                // self.replay.run_to_entry()?;
                // TODO: find a way to return to/stay in original place?
            }

            self.step_id = self.replay.current_step_id();
            self.complete_move(false, sender.clone())?;
            self.respond_dap(req, 0, sender)?;
            Ok(())
        }
    }

    fn source_line_jump_moves_for_rr(&mut self, source_location: &SourceLocation) -> Result<(), Box<dyn Error>> {
        // easier to handle errors from here in one place where we call it, so we can cleanup/restore breakpoints after it

        // forward-continue
        self.replay.step(Action::Continue, true)?;
        // self.source_line_jump_in_direction(source_location, Direction::Forward)?;
        let location = self.replay.load_location(&mut self.expr_loader)?;
        if location.path != source_location.path || location.line != source_location.line as i64 {
            // reverse-continue
            self.replay.step(Action::Continue, false)?;
        }
        Ok(())
    }

    // fn step_id_jump(&mut self, step_id: StepId) {
    //     if step_id.0 != NO_INDEX {
    //         self.step_id = step_id;
    //     }
    // }

    fn get_call_target(&self, loc: &SourceCallJumpTarget) -> Option<StepId> {
        let mut line: Line = Line(loc.line as i64);
        let mut path_id: PathId = self.load_path_id(&loc.path)?;
        // TODO: eventually expose slice index? not obvious if easy
        // for now this is not often
        for step in self.reader.steps_from(self.step_id) {
            let call = self
                .reader
                .call(step.call_key)
                .expect("get_call_target: invalid call_key");
            let function = self
                .reader
                .function(call.function_id)
                .expect("get_call_target: invalid function_id");
            if loc.token == function.name {
                line = function.line;
                path_id = function.path_id;
                break;
            }
        }

        if let Some(step_id) = self.get_closest_step_id(&SourceLocation {
            line: line.into(),
            path: self.reader.path(path_id).unwrap_or("").to_string(),
            column: None,
        }) {
            return Some(step_id);
        }

        None
    }

    pub fn source_call_jump(
        &mut self,
        req: dap::Request,
        call_target: SourceCallJumpTarget,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if let Some(line_step_id) = self.get_closest_step_id(&SourceLocation {
            line: call_target.line,
            path: call_target.path.clone(),
            column: None,
        }) {
            self.replay.jump_to(line_step_id)?;
            self.step_id = self.replay.current_step_id();
        }

        if let Some(call_step_id) = self.get_call_target(&call_target) {
            self.replay.jump_to(call_step_id)?;
            self.step_id = self.replay.current_step_id();
            self.complete_move(false, sender.clone())?;
            // DAP requires a response for every request — see the
            // matching note on `source_line_jump` above.
            self.respond_dap(req, 0, sender)?;
            Ok(())
        } else {
            let err: String = format!("unknown call location: {}", &call_target);
            self.complete_move(false, sender.clone())?;
            self.send_notification(
                NotificationKind::Error,
                "Line reached but couldn't find the function!",
                false,
                sender.clone(),
            )?;
            Err(err.into())
        }
    }

    pub fn set_breakpoints(
        &mut self,
        request: dap::Request,
        args: dap_types::SetBreakpointsArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let mut results = Vec::new();
        if let Some(path) = args.source.path.clone() {
            self.clear_breakpoints_for_source(&path)?;
            // M1: keep the `(line, column)` pair from the DAP request so
            // the breakpoint can be registered at the column the client
            // asked for.  The legacy `args.lines` fallback (used by very
            // old DAP clients that don't carry the structured
            // `breakpoints` array) is column-less by construction.
            // M1: normalise `column == Some(0)` to `None`.  The DAP
            // spec doesn't permit column 0 (columns are 1-indexed),
            // but the Nim frontend's strict ``DapSourceBreakpoint``
            // ref-object can't elide the key — it ships
            // ``"column": 0`` to mean "no column" for legacy
            // line-only breakpoints.  Treating 0 as None preserves
            // back-compat without forcing every existing UI surface
            // to switch to an Option-shaped field.
            let line_specs: Vec<(i64, Option<i64>)> = if let Some(bps) = args.breakpoints {
                bps.into_iter().map(|b| (b.line, b.column.filter(|c| *c > 0))).collect()
            } else {
                args.lines.unwrap_or_default().into_iter().map(|l| (l, None)).collect()
            };

            for (line, column) in line_specs {
                let source = Some(dap_types::Source {
                    name: args.source.name.clone(),
                    path: Some(path.clone()),
                    source_reference: args.source.source_reference,
                    presentation_hint: None,
                    origin: None,
                    sources: None,
                    adapter_data: None,
                    checksums: None,
                });
                match self.add_breakpoint(SourceLocation {
                    path: path.clone(),
                    line: line as usize,
                    column,
                }) {
                    Ok(breakpoint) => {
                        results.push(dap_types::Breakpoint {
                            id: Some(breakpoint.id),
                            verified: breakpoint.enabled,
                            message: None,
                            source,
                            line: Some(line),
                            // M1: surface the bound column on the
                            // response (the legacy implementation
                            // returned `None` unconditionally).  DAP
                            // clients consume this to anchor their
                            // gutter marker at the right column.
                            column: breakpoint.column,
                            end_line: None,
                            end_column: None,
                            instruction_reference: None,
                            offset: None,
                            reason: None,
                        });
                    }
                    Err(e) => {
                        let message = format!(
                            "failed to set breakpoint at {path}:{line}{}: {e}",
                            column.map(|c| format!(":{c}")).unwrap_or_default()
                        );
                        warn!("{message}");
                        results.push(dap_types::Breakpoint {
                            id: None,
                            verified: false,
                            message: Some(message),
                            source,
                            line: Some(line),
                            column,
                            end_line: None,
                            end_column: None,
                            instruction_reference: None,
                            offset: None,
                            reason: Some("failed".to_string()),
                        });
                    }
                }
            }
        } else {
            let lines = args
                .breakpoints
                .unwrap_or_default()
                .into_iter()
                .map(|b| b.line)
                .collect::<Vec<_>>();
            for line in lines {
                results.push(dap_types::Breakpoint {
                    id: None,
                    verified: false,
                    message: Some("missing source path".to_string()),
                    source: None,
                    line: Some(line),
                    column: None,
                    end_line: None,
                    end_column: None,
                    instruction_reference: None,
                    offset: None,
                    reason: None,
                });
            }
        }
        self.respond_dap(
            request,
            dap_types::SetBreakpointsResponseBody { breakpoints: results },
            sender,
        )?;
        Ok(())
    }

    pub fn add_breakpoint(&mut self, loc: SourceLocation) -> Result<Breakpoint, Box<dyn Error>> {
        let breakpoint = self.replay.add_breakpoint(&loc.path, loc.line as i64, loc.column)?;
        let entry = self
            .breakpoints
            .entry((loc.path.clone(), loc.line as i64, loc.column))
            .or_default();
        entry.push(breakpoint.clone());
        Ok(breakpoint)
    }

    pub fn delete_breakpoints_for_location(&mut self, loc: SourceLocation, _task: Task) -> Result<(), Box<dyn Error>> {
        let key = (loc.path.clone(), loc.line as i64, loc.column);
        if self.breakpoints.contains_key(&key) {
            for breakpoint in &self.breakpoints[&key] {
                self.replay.delete_breakpoint(breakpoint)?;
            }
        }
        Ok(())
    }

    pub fn clear_breakpoints_for_source(&mut self, source_path: &str) -> Result<(), Box<dyn Error>> {
        let keys = self
            .breakpoints
            .keys()
            .filter(|(path, _line, _column)| path == source_path)
            .cloned()
            .collect::<Vec<_>>();

        for key in keys {
            if let Some(breakpoints) = self.breakpoints.remove(&key) {
                for breakpoint in breakpoints {
                    self.replay.delete_breakpoint(&breakpoint)?;
                }
            }
        }

        Ok(())
    }

    pub fn clear_breakpoints(&mut self) -> Result<(), Box<dyn Error>> {
        let _ = self.replay.delete_breakpoints()?;
        self.breakpoints.clear();
        self.initialize_breakpoint_cache();
        Ok(())
    }

    fn initialize_breakpoint_cache(&mut self) {
        if !self.breakpoints.is_empty() {
            return;
        }
        if let Some(first_step) = self.reader.step(StepId(0)) {
            let path = self.reader.path(first_step.path_id).unwrap_or("").to_string();
            // M1: the sentinel cache entry mirrors the legacy line-only
            // slot — column `None` matches every step on the line.
            self.breakpoints.entry((path, first_step.line.0, None)).or_default();
        }
    }

    pub fn toggle_breakpoint(&mut self, _loc: SourceLocation, _task: Task) -> Result<(), Box<dyn Error>> {
        // TODO: use path,line to id map: self.replay.toggle_breakpoint()?;
        Ok(())
    }

    fn handle_trace_steps(&mut self, args: &RunTracepointsArg) -> Result<Vec<Stop>, Box<dyn Error>> {
        let tracepoints = args.session.tracepoints.clone();
        let mut registered = vec![false; tracepoints.len()];
        let mut tracepoint_locations: HashMap<String, HashMap<usize, Vec<usize>>> = HashMap::new();
        let mut tracepoint_errors = HashMap::new();

        // counting visits to each location, so tracepoints results
        // know that they're on the n-th iteration through the tracepoint
        let mut location_visit_indices: HashMap<String, HashMap<usize, usize>> = HashMap::new();

        let mut interpreter = TracepointInterpreter::new(tracepoints.len());

        let mut results = vec![];

        for (i, tracepoint) in tracepoints.iter().enumerate() {
            if let Err(error) = interpreter.register_tracepoint(i, &tracepoint.expression) {
                registered[i] = false;
                warn!("register tracepoint error: {error:?}");

                let mut error_text = format!("{:?}", error);
                if error_text.len() > 2 {
                    error_text.remove(0);
                    error_text.pop();
                }
                tracepoint_errors.insert(tracepoint.tracepoint_id, error_text);
            } else {
                registered[i] = true;
                tracepoint_locations
                    .entry(tracepoint.name.clone())
                    .or_default()
                    .entry(tracepoint.line)
                    .or_default()
                    .push(i);
                location_visit_indices
                    .entry(tracepoint.name.clone())
                    .or_default()
                    .entry(tracepoint.line)
                    .or_insert(0);
            }
        }

        let tracepoint_id_list: Vec<usize> = tracepoints.iter().map(|t| t.tracepoint_id).collect();
        self.event_db.reset_tracepoint_data(&tracepoint_id_list); // for now no smart cache non-changed optimizations(?)

        let original_step_id = self.replay.current_step_id();
        // M1 — the breakpoint registry key is `(path, line, column)`.
        // We hoist that triple into a local alias so clippy stops
        // flagging the `Vec<(.., usize)>` as "very complex type".
        type BreakpointKey = (String, i64, Option<i64>);
        let mut disabled_breakpoints: Vec<(BreakpointKey, usize)> = vec![];

        {
            let replay = &mut self.replay;
            for ((path, line, column), breakpoints) in self.breakpoints.iter_mut() {
                for (index, breakpoint) in breakpoints.iter_mut().enumerate() {
                    if breakpoint.enabled {
                        let toggled = replay.toggle_breakpoint(breakpoint)?;
                        disabled_breakpoints.push(((path.clone(), *line, *column), index));
                        *breakpoint = toggled;
                    }
                }
            }
        }

        let mut tracepoint_breakpoints: Vec<Breakpoint> = vec![];
        let mut run_error: Option<Box<dyn Error>> = None;

        {
            let run_result = (|| -> Result<(), Box<dyn Error>> {
                if tracepoints.is_empty() {
                    return Ok(());
                }

                for (path, line_map) in tracepoint_locations.iter() {
                    if line_map.is_empty() {
                        continue;
                    }
                    for (&line, tracepoint_indices) in line_map.iter() {
                        if !tracepoint_indices.iter().any(|idx| registered[*idx]) {
                            continue;
                        }
                        match self.replay.add_breakpoint(path, line as i64, None) {
                            Ok(breakpoint) => tracepoint_breakpoints.push(breakpoint),
                            Err(error) => {
                                warn!("tracepoint breakpoint error: {error:?}");
                                let mut error_text = format!("{:?}", error);
                                if error_text.len() > 2 {
                                    error_text.remove(0);
                                    error_text.pop();
                                }
                                for tracepoint_index in tracepoint_indices {
                                    registered[*tracepoint_index] = false;
                                    tracepoint_errors
                                        .insert(tracepoints[*tracepoint_index].tracepoint_id, error_text.clone());
                                }
                            }
                        }
                    }
                }

                if tracepoint_breakpoints.is_empty() {
                    return Ok(());
                }

                self.replay.jump_to(StepId(0))?;

                // Whether we need a Continue to reach the next breakpoint,
                // or have already landed on a new location via a Next step.
                let mut need_continue = true;

                loop {
                    if need_continue && !self.replay.step(Action::Continue, true)? {
                        break;
                    }
                    need_continue = true;

                    let current_step_id = self.replay.current_step_id();
                    let location = self.replay.load_location(&mut self.expr_loader)?;
                    let path = location.path.clone();
                    let line = location.line as usize;

                    if let Some(line_map) = tracepoint_locations.get(path.as_str())
                        && let Some(tracepoint_indices) = line_map.get(&line)
                    {
                        let visit_counts = location_visit_indices.entry(path.clone()).or_default();
                        let visit_entry = visit_counts.entry(line).or_insert(0);
                        let mut visit_index = *visit_entry;

                        for tracepoint_index in tracepoint_indices {
                            if !registered[*tracepoint_index] {
                                continue;
                            }
                            let tracepoint = &tracepoints[*tracepoint_index];
                            let locals = self.evaluate_tracepoint(
                                &interpreter,
                                *tracepoint_index,
                                &tracepoint.expression,
                                current_step_id,
                                lang_from_context(Path::new(&location.path), self.trace_kind),
                            );
                            if locals.is_empty() {
                                continue;
                            }
                            let stop = Stop::new(
                                path.clone(),
                                location.line,
                                locals,
                                current_step_id.0 as usize,
                                tracepoint.tracepoint_id,
                                visit_index,
                                StopType::Trace,
                            );
                            results.push(stop);

                            visit_index += 1;
                        }

                        *visit_entry = visit_index;

                        // Step past the current source line to skip any
                        // remaining sub-breakpoint addresses. GDB/LLDB can
                        // resolve a single source-line breakpoint to
                        // multiple addresses (e.g. macro expansion), and
                        // without this, each address triggers a separate
                        // Continue stop, duplicating tracepoint results.
                        // Loop `next` until the source line actually
                        // changes, since `next` may stop at another
                        // sub-breakpoint address on the same line.
                        let mut program_ended = false;
                        for _ in 0..16 {
                            if !self.replay.step(Action::Next, true).unwrap_or(false) {
                                program_ended = true;
                                break;
                            }
                            let next_loc = self.replay.load_location(&mut self.expr_loader)?;
                            if next_loc.path != path || next_loc.line as usize != line {
                                break;
                            }
                        }
                        if program_ended {
                            break;
                        }
                        // We've landed on a new line after stepping past
                        // sub-breakpoints. Check it for tracepoints before
                        // doing Continue — GDB's Continue skips breakpoints
                        // at the current PC, so we'd miss adjacent-line
                        // tracepoints if we didn't check here.
                        need_continue = false;
                        continue;
                    }
                }

                Ok(())
            })();

            if let Err(err) = run_result {
                run_error = Some(err);
            }
        }

        let mut cleanup_error: Option<Box<dyn Error>> = None;

        for breakpoint in tracepoint_breakpoints.iter() {
            if let Err(err) = self.replay.delete_breakpoint(breakpoint)
                && cleanup_error.is_none()
            {
                cleanup_error = Some(err);
            }
        }

        if let Err(err) = self.replay.jump_to(original_step_id)
            && cleanup_error.is_none()
        {
            cleanup_error = Some(err);
        }
        self.step_id = original_step_id;

        for (key, index) in disabled_breakpoints {
            match self.breakpoints.get_mut(&key) {
                Some(breakpoints) => {
                    if let Some(breakpoint) = breakpoints.get_mut(index) {
                        match self.replay.toggle_breakpoint(breakpoint) {
                            Ok(toggled) => {
                                *breakpoint = toggled;
                            }
                            Err(err) => {
                                if cleanup_error.is_none() {
                                    cleanup_error = Some(err);
                                }
                            }
                        }
                    } else if cleanup_error.is_none() {
                        cleanup_error = Some(io::Error::other("missing breakpoint index during restore").into());
                    }
                }
                None => {
                    if cleanup_error.is_none() {
                        cleanup_error = Some(io::Error::other("missing breakpoint entry during restore").into());
                    }
                }
            }
        }

        if let Some(err) = run_error {
            if let Some(cleanup_err) = cleanup_error {
                warn!("cleanup error after tracepoint run: {cleanup_err:?}");
            }
            return Err(err);
        }

        if let Some(err) = cleanup_error {
            return Err(err);
        }

        self.event_db.tracepoint_errors = tracepoint_errors;
        self.event_db.register_tracepoint_results(&results);
        Ok(results)
    }

    fn evaluate_tracepoint(
        &mut self,
        interpreter: &TracepointInterpreter,
        tracepoint_index: usize,
        tracepoint_expression: &str,
        step_id: StepId,
        lang: Lang,
    ) -> Vec<StringAndValueTuple> {
        let step_raw = step_id.0;
        if step_raw < 0 {
            warn!(
                "tracepoint evaluation requested for negative step id {} (tracepoint index {})",
                step_raw, tracepoint_index
            );
            let mut err_value = Value::new(TypeKind::Error, Type::new(TypeKind::Error, "TracepointEvaluationError"));
            err_value.msg = "Tracepoint evaluation unavailable for negative replay step.".to_string();
            return vec![StringAndValueTuple {
                field0: tracepoint_expression.to_string(),
                field1: err_value,
            }];
        }

        // let step_index = step_raw as usize;
        // let known_step_count = self.db.variables.len();
        // if step_index >= known_step_count {
        //     warn!(
        //         "tracepoint evaluation requested for step {} (tracepoint index {}) but db only contains {} steps",
        //         step_index, tracepoint_index, known_step_count
        //     );

        //     let mut err_value = Value::new(TypeKind::Error, Type::new(TypeKind::Error, "TracepointEvaluationError"));
        //     err_value.msg = format!("Tracepoint evaluation unavailable for this replay backend at step {step_index}.");

        //     return vec![StringAndValueTuple {
        //         field0: tracepoint_expression.to_string(),
        //         field1: err_value,
        //     }];
        // }

        interpreter.evaluate(tracepoint_index, step_id, &mut *self.replay, lang)
    }

    pub fn run_tracepoints(
        &mut self,
        req: dap::Request,
        args: RunTracepointsArg,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Recreator {
            self.replay = Box::new(RecreatorReplaySession::new(
                "tracepoint",
                self.tracepoint_rr_worker_index,
                self.ct_rr_args.clone(),
            ));
            self.tracepoint_rr_worker_index += 1;
        };
        info!("run_tracepoints trace_kind {:?}", self.trace_kind);

        // Sort steps in StepId Ord
        self.setup_trace_session(req, args.clone(), sender.clone())?;

        let tracepoints = &args.session.tracepoints;
        let is_empty = false; // TODO: check if there is at least one enabled non-empty log?

        let results = if !is_empty {
            // Handle id_table and results for the TraceUpdate
            let results = self.handle_trace_steps(&args)?;
            info!("{:?}", self.event_db);
            results
        } else {
            Vec::new()
        };

        for trace in tracepoints.iter() {
            let trace_update = TraceUpdate::new(
                args.session.id,
                true,
                trace.tracepoint_id,
                self.event_db.tracepoint_errors.clone(),
            );
            let raw_event = self.dap_client.updated_trace_event(trace_update)?;
            sender.send(raw_event)?;
        }

        // Emit the aggregate results event so the daemon's Python bridge
        // can build a single `ct/py-run-tracepoints` response.
        let aggregate = TracepointResultsAggregate {
            session_id: args.session.id,
            results,
            errors: self.event_db.tracepoint_errors.clone(),
        };
        let results_event = self.dap_client.tracepoint_results_event(aggregate)?;
        sender.send(results_event)?;

        Ok(())
    }

    pub fn trace_jump(
        &mut self,
        _req: dap::Request,
        event: ProgramEvent,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.replay.tracepoint_jump(&event)?;
        // self.replay.jump_to(StepId(event.direct_location_rr_ticks))?;
        _ = self.replay.load_location(&mut self.expr_loader)?;
        self.complete_move(false, sender)?;
        Ok(())
    }

    pub fn tracepoint_delete(
        &mut self,
        _req: dap::Request,
        tracepoint_id: TracepointId,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.event_db.clear_single_table(SingleTableId(tracepoint_id.id + 1));
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        let raw_event = self.dap_client.updated_trace_event(t_update)?;
        sender.send(raw_event)?;
        Ok(())
    }

    pub fn tracepoint_toggle(
        &mut self,
        _req: dap::Request,
        tracepoint_id: TracepointId,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let table_id = self.event_db.make_single_table_id(tracepoint_id.id);
        if self.event_db.disabled_tables.contains(&table_id) {
            self.event_db.enable_table(table_id);
        } else {
            self.event_db.disable_table(table_id);
        }
        self.event_db.refresh_global();
        let mut t_update = TraceUpdate::new(0, false, tracepoint_id.id, self.event_db.tracepoint_errors.clone());
        t_update.refresh_event_log = true;
        let raw_event = self.dap_client.updated_trace_event(t_update)?;
        sender.send(raw_event)?;
        Ok(())
    }

    pub fn search_program(&mut self, query: String, _task: Task) -> Result<(), Box<dyn Error>> {
        let program_search_tool = ProgramSearchTool::new(&*self.reader);
        let _results = program_search_tool.search(&query, &mut self.expr_loader)?;
        // TODO: send with DAP
        // self.send_event((
        //     EventKind::ProgramSearchResults,
        //     gen_event_id(EventKind::ProgramSearchResults),
        //     self.serialize(&results)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    pub fn load_step_lines(&mut self, arg: LoadStepLinesArg, _task: Task) -> Result<(), Box<dyn Error>> {
        let step_lines = vec![];
        // self.step_lines_loader.load_lines(
        //     &arg.location,
        //     arg.backward_count,
        //     arg.forward_count,
        //     &self.db,
        //     &mut self.flow_preloader,
        // );
        let _step_lines_update = LoadStepLinesUpdate {
            results: step_lines,
            arg_location: arg.location,
            finish: true,
        };
        // TODO: send with DAP
        // self.send_event((
        //     EventKind::UpdatedLoadStepLines,
        //     gen_event_id(EventKind::UpdatedLoadStepLines),
        //     self.serialize(&step_lines_update)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    /// Jump the replay to a specific execution timestamp (RR ticks / step ID).
    ///
    /// Used by the Python API `trace.goto_ticks(n)` to navigate directly to
    /// a known point in the execution trace.
    pub fn goto_ticks(
        &mut self,
        _req: dap::Request,
        arg: GoToTicksArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.replay.jump_to(StepId(arg.ticks))?;
        self.step_id = self.replay.current_step_id();
        self.complete_move(false, sender)?;
        Ok(())
    }

    pub fn local_step_jump(
        &mut self,
        _req: dap::Request,
        arg: LocalStepJump,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Materialized {
            self.replay.jump_to(StepId(arg.rr_ticks))?;
            self.step_id = self.replay.current_step_id();

            self.complete_move(false, sender)?;
        } else {
            self.replay.disable_breakpoints()?;
            let bp = self.replay.add_breakpoint(&arg.path, arg.first_loop_line + 1, None)?;
            let location = self.replay.load_location(&mut self.expr_loader)?;
            if location.line < arg.first_loop_line {
                self.replay.step(Action::Continue, true)?;
            } else if location.line > arg.first_loop_line {
                self.replay.step(Action::Continue, false)?;
            }

            if arg.active_iteration < arg.target_iteration {
                for _ in arg.active_iteration..arg.target_iteration {
                    self.replay.step(Action::Continue, true)?;
                }
            } else {
                for _ in arg.target_iteration..arg.active_iteration {
                    self.replay.step(Action::Continue, false)?;
                }
            }

            if location.line < arg.first_loop_line + 1 {
                self.replay.step(Action::Continue, true)?;
            } else if location.line > arg.first_loop_line + 1 {
                self.replay.step(Action::Continue, false)?;
            }
            self.replay.delete_breakpoint(&bp)?;
            self.replay.enable_breakpoints()?;

            self.step_id = self.replay.current_step_id();

            self.complete_move(false, sender)?;
            // warn!("local_step_jump not implemented for RR traces");
        }
        Ok(())
    }

    pub fn register_events(&mut self, arg: RegisterEventsArg, _task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db.register_events(arg.kind, &arg.events, vec![-1]);
        self.event_db.refresh_global();
        // TODO: rr-backend virtualization layers support self.return_void(task)?;
        Ok(())
    }

    pub fn setup_trace_session(
        &mut self,
        _req: dap::Request,
        arg: RunTracepointsArg,
        _sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        for trace in arg.session.tracepoints {
            while trace.tracepoint_id + 1 >= self.event_db.single_tables.len() {
                self.event_db.add_new_table(DbEventKind::Trace, &[]);
            }
            assert!(self.event_db.single_tables.len() > trace.tracepoint_id + 1);
        }
        Ok(())
    }

    pub fn register_tracepoint_logs(&mut self, arg: TracepointResults, _task: Task) -> Result<(), Box<dyn Error>> {
        self.event_db
            .register_tracepoint_values(arg.tracepoint_id, arg.tracepoint_values);
        self.event_db
            .register_events(DbEventKind::Trace, &arg.events, vec![arg.tracepoint_id as i64]);
        self.event_db.refresh_global();

        let trace_count = self.event_db.get_trace_length(arg.tracepoint_id);
        let total_count = self.event_db.get_events_count();

        let mut trace_update = TraceUpdate::new(
            arg.session_id,
            arg.first_update,
            arg.tracepoint_id,
            self.event_db.tracepoint_errors.clone(),
        );
        trace_update.total_count = total_count;
        trace_update.count = trace_count;
        trace_update.update_id = arg.tracepoint_id;
        // TODO: send with DAP for virtualization layers
        // self.send_event((
        //     EventKind::UpdatedTrace,
        //     gen_event_id(EventKind::UpdatedTrace),
        //     self.serialize(&trace_update)?,
        //     false,
        // ))?;
        // self.return_void(task)?;
        Ok(())
    }

    pub fn update_table(
        &mut self,
        req: dap::Request,
        args: UpdateTableArgs,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        eprintln!(
            "[DEBUG update_table] event_db single_tables={}, global_table={}",
            self.event_db.single_tables.len(),
            self.event_db.global_table.len()
        );
        let (table_update, trace_values_option) = self.event_db.update_table(args)?;
        eprintln!("[DEBUG update_table] result returned");
        if let Some(trace_values) = trace_values_option.as_ref() {
            let trace_event = self.dap_client.tracepoint_locals_event(trace_values)?;
            sender.send(trace_event)?;
        }
        let table_body = task::CtUpdatedTableResponseBody { table_update };
        let raw_event = self.dap_client.updated_table_event(&table_body)?;
        sender.send(raw_event)?;
        // Include table data in the response body for customRequest().
        self.respond_dap(req, &table_body, sender)?;
        Ok(())
    }

    fn load_steps_for_call(&mut self, call_key: CallKey) -> IndexMap<i64, StepId> {
        let mut list: IndexMap<i64, StepId> = IndexMap::default();
        let db_call = self
            .reader
            .call(call_key)
            .expect("load_steps_for_call: invalid call_key")
            .clone();
        let function_step = *self
            .reader
            .step(db_call.step_id)
            .expect("load_steps_for_call: invalid step_id");
        let location = self.load_location(db_call.step_id);
        let function_location = self
            .flow_preloader
            .expr_loader
            .find_function_location(&location, &function_step.line);
        for line in function_location.function_first..function_location.function_last {
            let function_id = self
                .reader
                .function(db_call.function_id)
                .expect("load_steps_for_call: invalid function_id");
            let step_map = self
                .reader
                .step_map_for_path(function_id.path_id)
                .expect("load_steps_for_call: missing step_map");
            if let Some(steps) = step_map.get(&(line as usize)) {
                for step in steps {
                    if step.call_key == call_key {
                        if !list.contains_key(&line) {
                            list.insert(line, step.step_id);
                        } else if step.step_id >= self.step_id {
                            list.entry(line)
                                .and_modify(|e| *e = step.step_id)
                                .or_insert(step.step_id);
                            // We change the line entry and break because we have found the next closest
                            break;
                        }
                    }
                }
            } else {
                list.insert(line, StepId(-1));
            }
        }
        list
    }

    pub fn load_asm_function(
        &mut self,
        request: dap::Request,
        args: FunctionLocation,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let mut instructions: Vec<Instruction> = vec![];
        match args.key.parse::<i64>() {
            Ok(number) => {
                let call_key = CallKey(number);
                let interesting_steps = self.load_steps_for_call(call_key);
                for (line, step_id) in interesting_steps.iter() {
                    if step_id.0 != NO_STEP_ID {
                        let current_step = *self.reader.step(*step_id).expect("load_asm_function: invalid step_id");
                        if let Some(asm_instructions) = self.reader.instructions_at(*step_id) {
                            if asm_instructions.is_empty() {
                                instructions.push(Instruction::empty(
                                    *line,
                                    self.reader.path(current_step.path_id).unwrap_or(""),
                                    step_id.0,
                                ))
                            }
                            for arg in asm_instructions {
                                instructions.push(Instruction {
                                    args: "".to_string(),
                                    high_level_line: *line,
                                    high_level_path: self.reader.path(current_step.path_id).unwrap_or("").to_string(),
                                    name: arg.to_string(),
                                    offset: current_step.step_id.0,
                                    other: "".to_string(),
                                });
                            }
                        }
                    } else {
                        let fn_id = self
                            .reader
                            .call(call_key)
                            .expect("load_asm_function: invalid call_key")
                            .function_id;
                        let fn_path_id = self
                            .reader
                            .function(fn_id)
                            .expect("load_asm_function: invalid function_id")
                            .path_id;
                        instructions.push(Instruction::empty(
                            *line,
                            self.reader.path(fn_path_id).unwrap_or(""),
                            NO_STEP_ID,
                        ))
                    }
                }
                let instructions: Instructions = Instructions {
                    address: 0,
                    instructions,
                    error: "".to_string(),
                };
                self.respond_dap(request, instructions, sender)?;
                Ok(())
            }
            Err(e) => Err(Box::new(e)),
        }
    }

    /// Load macro sourcemaps from the trace directory.
    ///
    /// Searches for `macro_sourcemap*.json` files and populates the
    /// `macro_sourcemaps` field. Should be called during trace setup.
    pub fn load_macro_sourcemaps(&mut self, trace_dir: &Path) {
        self.macro_sourcemaps = macro_sourcemap::load_macro_sourcemaps(trace_dir);
        if !self.macro_sourcemaps.is_empty() {
            info!(
                "macro_sourcemap: loaded {} macro sourcemap(s) from {}",
                self.macro_sourcemaps.maps.len(),
                trace_dir.display()
            );
        }
    }

    /// Discover and load Source Map V3 indexes for every recorded
    /// source path that has one.  Populates [`Self::sourcemap_cache`].
    ///
    /// Should be called during trace setup, right after the reader's
    /// path interning table is populated.  No-ops when the
    /// `CT_SOURCEMAP_TRANSLATION` environment variable disables
    /// translation (e.g. for bisection or to debug the minified
    /// form directly).
    ///
    /// Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P3.2.
    pub fn load_sourcemaps(&mut self, trace_dir: &Path) {
        if !translation_enabled() {
            info!("sourcemap_cache: translation disabled via CT_SOURCEMAP_TRANSLATION");
            return;
        }
        self.sourcemap_cache_dir = Some(trace_dir.to_path_buf());
        let workdir = self.reader.workdir().to_path_buf();
        // Snapshot the path entries up-front so we don't borrow
        // `self.reader` while mutating `self.sourcemap_cache`.
        let entries: Vec<(String, PathId)> = self
            .reader
            .path_entries_iter()
            .map(|(p, id)| (p.to_string(), id))
            .collect();
        let mut loaded = 0usize;
        for (recorded, path_id) in entries {
            // The recorded path may be absolute (most CTFS traces are)
            // or relative to the workdir (legacy traces).  We try the
            // recorded form first, then join with workdir.
            let recorded_path = std::path::Path::new(&recorded);
            let probe = if recorded_path.is_absolute() {
                recorded_path.to_path_buf()
            } else {
                workdir.join(recorded_path)
            };
            if !probe.is_file() {
                continue;
            }
            let before = self.sourcemap_cache.len();
            self.sourcemap_cache.try_load(path_id, &probe);
            if self.sourcemap_cache.len() > before {
                loaded += 1;
            }
        }
        if loaded > 0 {
            info!(
                "sourcemap_cache: loaded {loaded} sourcemap(s) from trace at {}",
                trace_dir.display()
            );
        }
    }

    /// §P6.2 — discover and load `srcviews.dat` records from the CTFS
    /// container in `trace_dir` and feed them into the sourcemap cache.
    ///
    /// `srcviews.dat` ships recorder-baked formatted views of minified
    /// sources (the alternate-views extension of the CTFS spec); the
    /// recorder pre-formatted the content and baked a Source Map V3
    /// alongside it so the replay-server never has to fork a
    /// `prettier` / `black` subprocess at trace-open time.
    ///
    /// ## Precedence
    ///
    /// This loader runs AFTER [`Self::load_sourcemaps`] so a srcviews
    /// record OVERWRITES any sibling `<path>.map` previously discovered
    /// for the same recorded path.  The recorder explicitly baked this
    /// view, so its intent supersedes the heuristic sibling-map lookup
    /// (per the spec's "prefer the alternate view for UI display" rule).
    ///
    /// ## Materialisation
    ///
    /// For each parsed view the loader writes:
    ///
    /// * `<trace_dir>/sourcemap-translate/<sanitised view_name>` — the
    ///   formatted content, so the UI's filesystem-based source reader
    ///   picks it up.
    /// * `<trace_dir>/sourcemap-translate/<sanitised view_name>.map` —
    ///   the V3 JSON, mirrored for diagnosability (the cache holds the
    ///   parsed `SourcemapIndex` directly so the file is purely for
    ///   the developer's benefit).
    ///
    /// Failures are logged at `warn!` and the cache is left unchanged
    /// — same best-effort contract as the P3 loader.
    pub fn load_source_views(&mut self, trace_dir: &Path) {
        if !translation_enabled() {
            // The same kill switch covers both the §P3 sibling-map path
            // and this §P6.2 srcviews path: the user asked to debug the
            // minified form directly.
            return;
        }
        // Discover the .ct container.  The caller hands us the trace
        // directory; the dispatcher's CTFS open path tries the dir
        // itself + `<dir>/trace.ct` as candidates, so we mirror those
        // probes here.
        let ct_path = find_ct_container(trace_dir);
        let Some(ct_path) = ct_path else {
            debug!(
                "srcviews: no .ct container found under {} — skipping",
                trace_dir.display()
            );
            return;
        };

        let views = match crate::source_views::SourceViews::load(&ct_path) {
            Ok(v) => v,
            Err(crate::source_views::SourceViewsError::Absent) => {
                // Pre-extension trace — legacy, expected, silent.
                debug!("srcviews: extension absent in {}", ct_path.display());
                return;
            }
            Err(e) => {
                warn!("srcviews: failed to load from {}: {e}", ct_path.display());
                return;
            }
        };
        if views.is_empty() {
            return;
        }

        // Make sure cache_dir is set so materialisation has a place to
        // write — `load_sourcemaps` would normally have done this but
        // we may be called even on traces with no sibling-map paths.
        if self.sourcemap_cache_dir.is_none() {
            self.sourcemap_cache_dir = Some(trace_dir.to_path_buf());
        }

        // Snapshot the recorded path strings keyed by PathId.  We need
        // to map srcviews' `path_id: u64` back to the canonical
        // (path_string, PathId) pair the cache indexes off.
        let path_strings: HashMap<u64, String> = self
            .reader
            .path_entries_iter()
            .map(|(p, id)| (id.0 as u64, p.to_string()))
            .collect();

        let mut installed = 0usize;
        for sv in views.entries() {
            let Some(recorded_path) = path_strings.get(&sv.path_id) else {
                warn!(
                    "srcviews: record references unknown path_id {} (view_name={:?})",
                    sv.path_id, sv.view_name
                );
                continue;
            };
            // Parse the Source Map V3 bytes through the existing
            // production wrapper so the cache-side code path is
            // identical to the §P3 sibling-map case.
            //
            // The "sourcemap_dir" we hand to `from_slice` is the trace
            // directory — it's only consulted by
            // `SourcemapIndex::resolve_source_path` to anchor relative
            // `sources[i]` entries.  For srcviews the `sources[0]`
            // entry refers conceptually to the ORIGINAL recorded
            // source; we leave it at the trace dir so the resolver
            // returns a sensible-looking path even when the original
            // file isn't physically on disk.
            let idx = match sourcemap_translate::SourcemapIndex::from_slice(&sv.sourcemap_v3, trace_dir) {
                Ok(i) => i,
                Err(e) => {
                    warn!(
                        "srcviews: failed to parse map for path_id {} ({}): {e}",
                        sv.path_id, sv.view_name
                    );
                    continue;
                }
            };

            // Materialise the formatted content + map JSON under the
            // trace's cache directory.  These on-disk sidecars let the
            // UI's filesystem-based source reader pick up the formatted
            // view through the path the translated `StackFrame`
            // surfaces.
            let view_path = match materialise_source_view(trace_dir, &sv.view_name, &sv.content, &sv.sourcemap_v3) {
                Some(p) => p,
                None => {
                    // Materialisation failures are logged inside the
                    // helper; we still install the in-memory index so
                    // the cache can serve the translated coordinates
                    // even without a sidecar to point the UI at.
                    sv.view_name.clone()
                }
            };

            // Insert under BOTH the recorded minified path AND the
            // newly-materialised formatted-view path so callers can
            // resolve from either side:
            //  * `recorded_path` keys the by_path index that the §P3
            //    `apply_sourcemap_translation` consults.
            //  * `view_path` keys the cache for ad-hoc DAP `source`
            //    handlers that arrive holding the formatted file path.
            //
            // Both keys share one `Arc<SourcemapIndex>`, so they stay
            // consistent if we ever extend the cache.
            self.sourcemap_cache
                .install_index(PathId(sv.path_id as usize), recorded_path, idx);

            info!(
                "srcviews: installed view {} → {} (path_id {})",
                sv.view_name, view_path, sv.path_id
            );
            installed += 1;
        }

        if installed > 0 {
            info!(
                "srcviews: loaded {installed} alternate source view(s) from {}",
                ct_path.display()
            );
        }
    }

    /// Translate a recorded `(path_id, line, column)` triple through
    /// the per-trace sourcemap cache.
    ///
    /// Returns `None` when:
    /// * The translation cache is empty (no sourcemaps loaded).
    /// * The path has no associated sourcemap.
    /// * The segment is sparse (no original mapping).
    ///
    /// The DAP `stackTrace` handler uses this to surface original
    /// source coordinates instead of minified ones.  When `None`
    /// is returned the recorded coordinates flow through unchanged.
    pub fn translate_via_sourcemap(&mut self, path_id: PathId, line: u32, column: u32) -> Option<TranslatedLocation> {
        if self.sourcemap_cache.is_empty() {
            return None;
        }
        let cache_dir = self.sourcemap_cache_dir.clone();
        self.sourcemap_cache
            .translate(path_id, line, column, cache_dir.as_deref())
    }

    /// Translate by absolute path string — fallback for code paths
    /// that don't carry `PathId` through.  See
    /// [`Self::translate_via_sourcemap`] for the contract.
    pub fn translate_via_sourcemap_for_path(
        &mut self,
        path: &str,
        line: u32,
        column: u32,
    ) -> Option<TranslatedLocation> {
        if self.sourcemap_cache.is_empty() {
            return None;
        }
        let cache_dir = self.sourcemap_cache_dir.clone();
        self.sourcemap_cache
            .translate_for_path(path, line, column, cache_dir.as_deref())
    }

    /// §P5 — discover + install a user-provided variable rename list.
    ///
    /// Resolution order:
    ///
    /// 1. When `explicit_path` is `Some(_)` the loader uses it
    ///    verbatim — this is the path the CLI `--rename-list <p>` flag
    ///    or the DAP `launch.renameList` field carries.
    /// 2. Otherwise the loader probes `<trace_dir>/renames.toml`.
    /// 3. When neither is found, the cache is left without a rename
    ///    list and [`crate::sourcemap_cache::SourcemapCache::resolve_name`]
    ///    falls back to the §P3 sourcemap-names data alone.
    ///
    /// The kill switch `CT_RENAME_LIST={0,off,false,no}` short-circuits
    /// the loader before any filesystem probe — useful when the user
    /// wants to debug the minified binding names directly.
    ///
    /// Errors are logged at `warn!` and the cache stays empty;
    /// failure to load is never fatal.
    ///
    /// Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P5.1 / §P5.4.
    pub fn load_rename_list(&mut self, trace_dir: &Path, explicit_path: Option<&Path>) {
        if !crate::rename_list::rename_list_enabled() {
            info!("rename_list: disabled via CT_RENAME_LIST");
            return;
        }
        let load_result = match explicit_path {
            Some(p) => {
                info!("rename_list: loading explicit path {}", p.display());
                match crate::rename_list::RenameList::load(p) {
                    Ok(list) => Some(list),
                    Err(e) => {
                        warn!(
                            "rename_list: failed to load explicit rename list at {}: {e}",
                            p.display()
                        );
                        None
                    }
                }
            }
            None => match crate::rename_list::RenameList::try_load_sibling(trace_dir) {
                Ok(opt) => opt,
                Err(e) => {
                    warn!(
                        "rename_list: failed to load sibling renames.toml in {}: {e}",
                        trace_dir.display()
                    );
                    None
                }
            },
        };
        if let Some(list) = load_result {
            info!(
                "rename_list: installed {} entries (meta version = {})",
                list.len(),
                list.meta()
                    .and_then(|m| m.version.as_deref())
                    .unwrap_or("<unspecified>")
            );
            self.sourcemap_cache.set_rename_list(Some(list));
        }
    }

    /// §P8 — scan recorded sources for catalog matches and (optionally)
    /// auto-apply them.
    ///
    /// Behaviour:
    ///
    /// 1. Snapshot every recorded absolute path (the recordings' path
    ///    interning table, filtered to files that exist on disk).
    /// 2. Skip any path that already has a sibling `renames.toml` —
    ///    the user's explicit rename list always wins over the catalog.
    /// 3. For each remaining path, call [`crate::catalog_autoload::scan_single_path`]
    ///    against the catalog directory resolved via
    ///    [`mapping_catalog::catalog_path_from_env`] (or the
    ///    `explicit_catalog_path` argument when supplied).
    /// 4. On `Applied`, merge the cataloged rename list into the
    ///    in-memory `SourcemapCache`.  We do NOT write to disk by
    ///    default — opt-in apply is in-memory only so the recording
    ///    isn't mutated under the user.
    /// 5. On `MatchLogged`, do nothing further — the autoload module
    ///    already logged the friendly hint.
    ///
    /// The kill switches mirror the rest of the §P3-§P8 trace-open
    /// hooks: `CT_CATALOG_AUTOLOAD_DISABLED=1` skips the scan
    /// entirely; `CT_CATALOG_AUTOLOAD=1` enables auto-apply.
    ///
    /// Spec: `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org` §P8.3.
    pub fn load_catalog_autoload(&mut self, trace_dir: &Path, explicit_catalog_path: Option<&Path>) {
        use crate::catalog_autoload::{AutoloadOutcome, autoload_disabled, scan_single_path};

        if autoload_disabled() {
            info!("catalog_autoload: skipped via CT_CATALOG_AUTOLOAD_DISABLED");
            return;
        }
        // If the trace already has a sibling renames.toml, the user's
        // explicit list wins — don't even consult the catalog.
        let sibling = trace_dir.join("renames.toml");
        if sibling.is_file() {
            debug!(
                "catalog_autoload: sibling renames.toml present at {} — skipping catalog scan",
                sibling.display()
            );
            return;
        }
        let catalog_path = match explicit_catalog_path {
            Some(p) => p.to_path_buf(),
            None => mapping_catalog::catalog_path_from_env(),
        };
        let workdir = self.reader.workdir().to_path_buf();
        let entries: Vec<String> = self.reader.path_entries_iter().map(|(p, _id)| p.to_string()).collect();
        for recorded in entries {
            let recorded_path = std::path::Path::new(&recorded);
            let probe = if recorded_path.is_absolute() {
                recorded_path.to_path_buf()
            } else {
                workdir.join(recorded_path)
            };
            if !probe.is_file() {
                continue;
            }
            let outcome = scan_single_path(&probe, &catalog_path);
            match outcome {
                AutoloadOutcome::Applied {
                    list, library, version, ..
                } => {
                    info!(
                        "catalog_autoload: installing {library}@{version} ({} entries) in-memory",
                        list.len()
                    );
                    // Compose: the in-memory rename list wins over any
                    // future sibling-loaded list because this method
                    // is called AFTER `load_rename_list`.  The
                    // composition rule from the §P5 spec ("explicit
                    // user list wins") still holds: when the user
                    // ships a sibling renames.toml, we exit early
                    // above before installing the catalog list.
                    self.sourcemap_cache.set_rename_list(Some(list));
                }
                AutoloadOutcome::MatchLogged { .. } => {
                    // Already logged by the scanner; nothing else to do.
                }
                AutoloadOutcome::ShaMismatch {
                    recorded_sha,
                    indexed_sha,
                    toml_path,
                } => {
                    warn!(
                        "catalog_autoload: sha mismatch (recorded {recorded_sha}, indexed {indexed_sha}) for {} — refusing to apply",
                        toml_path.display()
                    );
                }
                AutoloadOutcome::NoMatch | AutoloadOutcome::SourceUnreadable | AutoloadOutcome::CatalogUnavailable => {}
            }
        }
    }

    /// Handle the `ct/update-expansion` custom DAP request.
    ///
    /// When the user presses ALT+E on a macro call in the editor, the frontend
    /// sends this request with the path, line, and expansion level update. We
    /// look up the macro sourcemap, resolve the expansion, and return a
    /// `Location` with expansion fields populated.
    pub fn update_expansion(
        &mut self,
        request: dap::Request,
        args: UpdateExpansionArgs,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.macro_sourcemaps.is_empty() {
            warn!("update_expansion: no macro sourcemaps loaded");
            let empty_loc = Location::default();
            self.respond_dap(request, empty_loc, sender)?;
            return Ok(());
        }

        let location = self
            .macro_sourcemaps
            .update_expansion(&args.path, args.line, &args.update);

        info!(
            "update_expansion: path={} line={} -> high_level={}:{} is_expanded={} depth={}",
            args.path,
            args.line,
            location.high_level_path,
            location.high_level_line,
            location.is_expanded,
            location.expansion_depth,
        );

        self.respond_dap(request, location, sender)?;
        Ok(())
    }

    /// Loads terminal output (stdout/stderr Write events) from the trace.
    ///
    /// Uses a dedicated fast path that only loads Write events from the
    /// database, avoiding the overhead of `ensure_events_loaded()` which
    /// loads ALL events into memory. On large traces with thousands of
    /// non-terminal events this makes a significant difference and prevents
    /// timeouts when `terminal_output()` is called as the first operation.
    ///
    /// If the full event cache is already populated (e.g. by a prior
    /// `ct/event-load` request), Write events are extracted from it instead.
    ///
    /// The request may include `startLine` and `endLine` parameters for
    /// pagination (forwarded by the daemon from the Python API).
    pub fn load_terminal(&mut self, req: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        // Ensure terminal events are cached.
        self.ensure_terminal_events_loaded();

        // Safety: `ensure_terminal_events_loaded` guarantees the cache is Some.
        let write_events = match self.cached_terminal_events.as_ref() {
            Some(events) => events,
            None => {
                return Err("internal error: cached_terminal_events is None after population".into());
            }
        };

        // Apply optional line-based pagination (startLine / endLine).
        let start_line = req
            .arguments
            .get("startLine")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0)
            .max(0) as usize;
        let end_line = req
            .arguments
            .get("endLine")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(-1);

        let page = if end_line >= 0 {
            let end = (end_line as usize + 1).min(write_events.len());
            let start = start_line.min(end);
            write_events[start..end].to_vec()
        } else {
            // No end_line specified (-1): return all Write events from
            // start_line onward.
            let start = start_line.min(write_events.len());
            write_events[start..].to_vec()
        };

        let raw_event = self.dap_client.loaded_terminal_event(page.clone())?;
        sender.send(raw_event)?;

        // Include terminal data in the response body for customRequest().
        self.respond_dap(req, &page, sender)?;
        Ok(())
    }

    /// Populate the terminal-events cache if it is not already filled.
    ///
    /// When the full event cache (`cached_events`) has already been loaded
    /// (e.g. by a prior `ct/event-load` call), the Write events are
    /// extracted from it.  Otherwise the database's event records are
    /// scanned directly for `EventLogKind::Write` entries, which is much
    /// faster than loading every event type into memory first.
    fn ensure_terminal_events_loaded(&mut self) {
        if self.cached_terminal_events.is_some() {
            return;
        }

        let write_events: Vec<ProgramEvent> = if let Some(ref all_events) = self.cached_events {
            // Full cache already populated -- extract Write events from it.
            all_events
                .iter()
                .filter(|e| e.kind == EventLogKind::Write)
                .cloned()
                .collect()
        } else {
            // Fast path: scan the db event records for Write events only,
            // skipping the expensive full load_events() pipeline.
            self.reader
                .events()
                .iter()
                .enumerate()
                .filter(|(_, record)| record.kind == EventLogKind::Write)
                .map(|(i, record)| self.to_program_event(record, i))
                .collect()
        };

        self.cached_terminal_events = Some(write_events);
    }

    fn send_notification(
        &mut self,
        kind: NotificationKind,
        msg: &str,
        is_operation_status: bool,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let notification = Notification::new(kind, msg, is_operation_status);
        let raw_event = self.dap_client.notification_event(notification)?;
        info!("send notification {:?}", raw_event);
        sender.send(raw_event)?;
        Ok(())
    }

    fn to_program_event(&self, event_record: &DbRecordEvent, index: usize) -> ProgramEvent {
        let step_id_int = event_record.step_id.0;
        let (path, line) = if step_id_int != NO_INDEX {
            let step_record = self
                .reader
                .step(event_record.step_id)
                .expect("to_program_event: invalid step_id");
            (
                self.reader
                    .workdir()
                    .join(self.reader.path(step_record.path_id).unwrap_or(""))
                    .display()
                    .to_string(),
                step_record.line.0,
            )
        } else {
            (NO_PATH.to_string(), NO_POSITION)
        };

        ProgramEvent {
            kind: event_record.kind,
            semantic_kind: String::new(),
            content: event_record.content.clone(),
            bytes: event_record.content.len(),
            rr_event_id: index,
            direct_location_rr_ticks: step_id_int,
            metadata: event_record.metadata.to_string(),
            stdout: true,
            event_index: index,
            tracepoint_result_index: NO_INDEX,
            high_level_path: path,
            high_level_line: line,
            base64_encoded: false,
            max_rr_ticks: if self.reader.step_count() > 0 {
                self.reader
                    .step(StepId((self.reader.step_count() - 1) as i64))
                    .map(|s| s.step_id.0)
                    .unwrap_or(0)
            } else {
                0
            },
            source_generation: 0,
            source_digest: String::new(),
        }
    }

    fn serialize<T: Serialize>(&self, value: &T) -> Result<String, Box<dyn Error>> {
        let res = serde_json::to_string(value)?;
        Ok(res)
    }

    pub fn produce_stack_frame(&mut self, call_record: &DbCall) -> dap_types::StackFrame {
        // for this simplified scenario:
        // step 1: call 1
        // step 2: call 1
        // step 3: call 2
        // step 4: call 2
        // we were returning the function-entry locations: equivalent of steps [3, 1]
        // now with a workaround, we return the correct current frame(call) step(location), but keep
        //   returning the function-entry locations for upper frames(calls), so with DAP
        //   we can at least return the correct current location
        //   the equivalent of [4, 1]
        // eventually: TODO: return the current upper frame location/steps as well:
        //   the equivalent of [4, 2]
        //   how to do it efficiently is a non-trivial question: maybe by iterating through previous steps,
        //   or a new kind of index?
        let call = self.reader.to_call(call_record, &mut self.expr_loader);
        let current_step = self
            .reader
            .step(self.step_id)
            .expect("produce_stack_frame: invalid step_id");
        let current_call_key = current_step.call_key;
        // P6.3 — pull the column from the DbStep so the source-map
        // translation can use it.  Falls back to column=1 when the
        // trace was not recorded with column-aware mode (or the
        // canonical reader has not yet exposed the column through the
        // FFI — see P6.4).
        let recorded_column = current_step.column.map(|c| c.0).unwrap_or(1);
        let location = if call_record.key == current_call_key {
            self.reader
                .load_location(self.step_id, call_record.key, &mut self.expr_loader)
        } else {
            call.location
        };
        // P3 — Source Map V3 translation.  When the recorded path has
        // a known sourcemap, translate `(line, column)` back to the
        // original source so DAP consumers see the original file +
        // coordinates instead of the minified bundle.  Falls through
        // to the recorded path when no sourcemap is loaded or the
        // segment is sparse.
        let (frame_path, frame_line, frame_column) =
            self.apply_sourcemap_translation(&location.path, location.line, recorded_column);
        dap_types::StackFrame {
            id: call_record.key.0,
            name: location.function_name,
            source: Some(dap_types::Source {
                name: Some("".to_string()),
                path: Some(frame_path),
                source_reference: None,
                adapter_data: None,
                checksums: None,
                origin: None,
                presentation_hint: None,
                sources: None,
            }),
            line: if frame_line >= 0 { frame_line } else { 0 },
            column: frame_column,
            end_line: None,
            end_column: None,
            instruction_pointer_reference: None,
            module_id: None,
            presentation_hint: None,
            can_restart: None,
        }
    }

    /// Apply Source Map V3 translation to a recorded `(path, line, column)`.
    ///
    /// Returns the original-source coordinates when a sourcemap is
    /// available; otherwise — when the source looks minified —
    /// falls back to the §P4 auto-format path.  When neither route
    /// fires, returns the inputs unchanged.  This is the single point
    /// where DAP `stackTrace` responses pick up translation — keeping
    /// all callers funnelled through here guarantees the §P3
    /// server-side single-source-of-truth contract.
    fn apply_sourcemap_translation(
        &mut self,
        recorded_path: &str,
        recorded_line: i64,
        recorded_column: i64,
    ) -> (String, i64, i64) {
        if recorded_line <= 0 {
            return (recorded_path.to_string(), recorded_line, recorded_column);
        }
        let line_u32 = recorded_line.max(0) as u32;
        let col_u32 = recorded_column.max(1) as u32;

        // P3 — try the sourcemap path first.  When a sibling `.map` or
        // `//# sourceMappingURL=` is loaded the by_path index serves the
        // translation in O(log n) per segment.
        if !self.sourcemap_cache.is_empty()
            && let Some(t) = self.translate_via_sourcemap_for_path(recorded_path, line_u32, col_u32)
        {
            return (t.path, t.line as i64, t.column as i64);
        }

        // P4 — sourcemap-less fallback.  Lazily auto-format the source
        // on its first translation request and project the recorded
        // position through the synthetic line-only map.  Disabled
        // entirely when `CT_AUTOFORMAT={0,off,false,no}`.
        let cache_dir = self.sourcemap_cache_dir.clone();
        if let Some(t) =
            self.sourcemap_cache
                .translate_via_autoformat(recorded_path, line_u32, col_u32, cache_dir.as_deref())
        {
            return (t.path, t.line as i64, t.column as i64);
        }

        (recorded_path.to_string(), recorded_line, recorded_column)
    }
    pub fn threads(&mut self, request: dap::Request, sender: Sender<DapMessage>) -> Result<(), Box<dyn Error>> {
        // For multi-process recordings (fork / exec), enumerate the recorded
        // processes via `ReplaySession::list_processes` and surface one DAP
        // `Thread` per process. The DAP spec has no first-class "process"
        // concept, so VS Code-style clients use the threads list as the
        // process selector for multi-process debugging.
        //
        // The thread id mapping is `pid as i64`. PIDs are unique within a
        // trace (rr preserves them across replay), so this is a stable
        // identifier across repeated `threads` requests in a session.
        //
        // For traces without process metadata (in-process backends, single-
        // process recordings, or worker errors) `list_processes` returns a
        // synthetic single entry — we map it to the historical
        // `Thread { id: 1, name: "<thread 1>" }` to preserve behaviour for
        // existing single-process traces.
        let threads = match self.replay.list_processes() {
            Ok(processes) if !processes.is_empty() => processes
                .into_iter()
                .map(|info| {
                    // pid==0 is the synthetic single-process fallback; keep
                    // the legacy id and label so we don't break clients that
                    // hard-coded "<thread 1>".
                    if info.pid == 0 {
                        dap_types::Thread {
                            id: 1,
                            name: "<thread 1>".to_string(),
                        }
                    } else {
                        // Strip the leading binary path from the recorded
                        // command for a more readable label. `rr ps` records
                        // commands like `/full/path/m12_orchestrator` for the
                        // root and `m12_child_cpp 10` for forked exec'd
                        // children — we keep the latter form and shorten the
                        // former to just the basename.
                        let label = if let Some(first) = info.command.split_whitespace().next() {
                            let basename = first.rsplit('/').next().unwrap_or(first);
                            format!("{} (pid {})", basename, info.pid)
                        } else {
                            format!("pid {}", info.pid)
                        };
                        dap_types::Thread {
                            id: info.pid as i64,
                            name: label,
                        }
                    }
                })
                .collect(),
            Ok(_) => vec![dap_types::Thread {
                id: 1,
                name: "<thread 1>".to_string(),
            }],
            Err(e) => {
                warn!("threads: list_processes failed, falling back to single-thread: {e}");
                vec![dap_types::Thread {
                    id: 1,
                    name: "<thread 1>".to_string(),
                }]
            }
        };
        self.respond_dap(request, dap_types::ThreadsResponseBody { threads }, sender)?;
        Ok(())
    }

    pub fn stack_trace(
        &mut self,
        request: dap::Request,
        args: dap_types::StackTraceArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        let stack_frames: Vec<dap_types::StackFrame> = if args.thread_id == 1 {
            // Both the Recreator (out-of-process RR worker) and the
            // Emulator (in-process MCR) backends surface the callstack via
            // the `ReplaySession` trait rather than through a
            // pre-materialised DB, so they share the same DAP-frame
            // synthesis path.
            if self.trace_kind == TraceKind::Recreator || self.trace_kind == TraceKind::Emulator {
                // RR / Emulator traces need a stack frame derived from the current location so VS Code can show the locator arrow.
                let current_location = self.replay.load_location(&mut self.expr_loader)?;
                // P3 — translate current location through the sourcemap cache.
                let (cur_path, cur_line, cur_col) =
                    self.apply_sourcemap_translation(&current_location.path, current_location.line, 1);
                let mut stack_frames: Vec<dap_types::StackFrame> = Vec::new();
                stack_frames.push(dap_types::StackFrame {
                    id: 0,
                    name: current_location.function_name.clone(),
                    source: Some(dap_types::Source {
                        name: Some("".to_string()),
                        path: Some(cur_path.clone()),
                        source_reference: None,
                        adapter_data: None,
                        checksums: None,
                        origin: None,
                        presentation_hint: None,
                        sources: None,
                    }),
                    line: if cur_line >= 0 { cur_line } else { 0 },
                    column: cur_col,
                    end_line: None,
                    end_column: None,
                    instruction_pointer_reference: None,
                    module_id: None,
                    presentation_hint: None,
                    can_restart: None,
                });

                let callstack_lines = self.replay.load_callstack()?;
                for line in callstack_lines.into_iter() {
                    if line.content.kind != CallLineContentKind::Call {
                        continue;
                    }
                    let location = line.content.call.location;
                    if location.path == current_location.path && location.line == current_location.line {
                        continue;
                    }
                    // P3 — translate caller frame paths through sourcemap.
                    let (frame_path, frame_line, frame_col) =
                        self.apply_sourcemap_translation(&location.path, location.line, 1);
                    let next_id = stack_frames.len() as i64;
                    stack_frames.push(dap_types::StackFrame {
                        id: next_id,
                        name: location.function_name,
                        source: Some(dap_types::Source {
                            name: Some("".to_string()),
                            path: Some(frame_path),
                            source_reference: None,
                            adapter_data: None,
                            checksums: None,
                            origin: None,
                            presentation_hint: None,
                            sources: None,
                        }),
                        line: if frame_line >= 0 { frame_line } else { 0 },
                        column: frame_col,
                        end_line: None,
                        end_column: None,
                        instruction_pointer_reference: None,
                        module_id: None,
                        presentation_hint: None,
                        can_restart: None,
                    });
                }

                stack_frames
            } else {
                self.calltrace
                    .load_callstack(self.step_id, &*self.reader)
                    .iter()
                    .map(|call_record| {
                        // expanded children count not relevant in raw callstack
                        self.produce_stack_frame(call_record)
                    })
                    .collect()
            }
        } else {
            vec![]
        };
        let total_frames = Some(stack_frames.len() as i64);
        self.respond_dap(
            request,
            dap_types::StackTraceResponseBody {
                stack_frames,
                total_frames,
            },
            sender,
        )?;
        Ok(())
    }

    pub fn scopes(
        &mut self,
        request: dap::Request,
        arg: dap_types::ScopesArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Recreator {
            self.respond_dap(request, dap_types::ScopesResponseBody { scopes: vec![] }, sender)?;
            return Ok(());
        }
        if self.trace_kind == TraceKind::Emulator {
            // The Emulator backend has no materialised call/function
            // table to query — instead we synthesise a single "locals"
            // scope rooted at the replay's current location. The
            // `variables` handler resolves `variables_reference ==
            // frame_id` by calling `replay.load_locals()`, so the value
            // chosen here is opaque (we re-use `frame_id` to mirror the
            // materialised path).
            let location = self.replay.load_location(&mut self.expr_loader)?;
            let scope = dap_types::Scope {
                name: if !location.function_name.is_empty() {
                    location.function_name.clone()
                } else {
                    "locals".to_string()
                },
                presentation_hint: Some("locals".to_string()),
                variables_reference: arg.frame_id,
                named_variables: Some(0),
                indexed_variables: Some(0),
                expensive: false,
                source: None,
                line: if location.line >= 0 {
                    Some(location.line)
                } else {
                    Some(0)
                },
                column: Some(1),
                end_line: None,
                end_column: None,
            };
            self.respond_dap(request, dap_types::ScopesResponseBody { scopes: vec![scope] }, sender)?;
            return Ok(());
        }
        let call = self
            .reader
            .call(CallKey(arg.frame_id))
            .expect("load_dap_scopes: invalid call_key");
        let function = self
            .reader
            .function(call.function_id)
            .expect("load_dap_scopes: invalid function_id");
        let scope = dap_types::Scope {
            name: function.name.clone(),
            presentation_hint: Some("locals".to_string()),
            variables_reference: arg.frame_id,
            named_variables: Some(0),
            indexed_variables: Some(0),
            expensive: false,
            source: None,
            line: Some(function.line.0),
            column: Some(1),
            end_line: None,
            end_column: None,
        };
        self.respond_dap(request, dap_types::ScopesResponseBody { scopes: vec![scope] }, sender)?;

        Ok(())
    }

    pub fn to_dap_variable(&self, ct_variable: &Variable) -> dap_types::Variable {
        let dap_value_text = ct_variable.value.text_repr();
        dap::new_dap_variable(&ct_variable.expression, &dap_value_text, 0)
    }

    /// §P5 — apply the user-provided rename list to a recorded binding
    /// name.  Returns `(display_name, original_name)` where:
    ///
    /// * `display_name` is the name the UI should show — the renamed
    ///   form when the resolver produced one, the recorded name
    ///   otherwise.
    /// * `original_name` is the recorded minified name, surfaced so the
    ///   UI can render `array (a)` if the user wants to see both.
    ///
    /// `step_id` provides the position context the resolver uses to
    /// derive a `(file, scope_hint)` pair.  The lookup is best-effort:
    /// when the step has no associated path / call, the resolver only
    /// inspects the global-scope user list and the sourcemap names.
    ///
    /// Back-compat wrapper — derives `(file, line, col)` from the
    /// current `step_id` and delegates to
    /// [`Handler::resolve_variable_name_at`].  Existing callers that
    /// don't have an external `(file, line, col)` triple keep working.
    pub(crate) fn resolve_variable_name(&self, recorded_name: &str) -> (String, String) {
        // Cheap fast-paths: if neither a rename list nor a sourcemap
        // is loaded the resolver always returns `None`, so we avoid
        // the (file, line, col) computation entirely.
        if !self.sourcemap_cache.has_rename_list() && self.sourcemap_cache.is_empty() {
            let original = recorded_name.to_string();
            return (original.clone(), original);
        }
        let (file, line, col) = self.current_step_location();
        self.resolve_variable_name_at(recorded_name, &file, line, col)
    }

    /// §P6.4 — derive `(file, line, col)` from the current `step_id`.
    ///
    /// Returns sensible defaults when the step has no recorded
    /// location: empty `file`, `line = 1`, `col = 1` — these keep the
    /// per-position resolver in P5-compatible "no segment lookup
    /// possible" mode without crashing.  Column defaults to `1` when
    /// the recorder ran without column-aware tracing.
    pub(crate) fn current_step_location(&self) -> (String, u32, u32) {
        self.reader
            .step(self.step_id)
            .map(|s| {
                let file = self.reader.path(s.path_id).map(|p| p.to_string()).unwrap_or_default();
                let line = s.line.0 as u32;
                let col = s.column.map(|c| c.0 as u32).unwrap_or(1);
                (file, line, col)
            })
            .unwrap_or_else(|| (String::new(), 1, 1))
    }

    /// §P6.4 — position-aware variant of
    /// [`Handler::resolve_variable_name`].
    ///
    /// Same precedence rules as the back-compat wrapper, but the
    /// `(file, line, col)` triple is supplied by the caller — typically
    /// derived from the surrounding step's recorded location.  The
    /// position flows into [`SourcemapCache::resolve_name_at_position`]
    /// so the per-segment `name_index` branch can recover the original
    /// identifier name from the sourcemap.
    ///
    /// `file` is the recorded path string; `(line, col)` are 1-indexed
    /// generated coordinates.  Passing `file = ""`, `line = 1`,
    /// `col = 1` keeps the resolver in P5-compatible mode (the
    /// per-position lookup degenerates to a "first segment on the
    /// first line" probe, which matches the back-compat contract).
    pub(crate) fn resolve_variable_name_at(
        &self,
        recorded_name: &str,
        file: &str,
        line: u32,
        col: u32,
    ) -> (String, String) {
        let original = recorded_name.to_string();
        // Cheap fast-paths: if neither a rename list nor a sourcemap
        // is loaded the resolver always returns `None`, so we avoid
        // the scope-hint computation entirely.
        if !self.sourcemap_cache.has_rename_list() && self.sourcemap_cache.is_empty() {
            return (original.clone(), original);
        }
        // Compute the scope hint: prefer function scope (from the
        // surrounding call's function name) and fall back to a block
        // scope keyed by the step's line.
        let step_id = self.step_id;
        let scope_hint = self.reader.step(step_id).map(|s| {
            let block = crate::rename_list::Scope::Block(s.line.0 as u32);
            let call_key = self.reader.call_key_for_step(step_id);
            let fn_scope = call_key
                .and_then(|k| self.reader.call(k))
                .and_then(|call| self.reader.function(call.function_id))
                .map(|func| crate::rename_list::Scope::Function(func.name.clone()));
            (fn_scope, block)
        });

        // Try the narrower scope (function) first, then the broader
        // (block).  `resolve_name_at_position` falls back to the global
        // entries on miss internally.
        if let Some((fn_scope, block_scope)) = scope_hint {
            if let Some(fn_s) = &fn_scope
                && let Some(renamed) =
                    self.sourcemap_cache
                        .resolve_name_at_position(file, line, col, Some(fn_s), recorded_name)
            {
                return (renamed, original);
            }
            if let Some(renamed) =
                self.sourcemap_cache
                    .resolve_name_at_position(file, line, col, Some(&block_scope), recorded_name)
            {
                return (renamed, original);
            }
        }
        if let Some(renamed) = self
            .sourcemap_cache
            .resolve_name_at_position(file, line, col, None, recorded_name)
        {
            return (renamed, original);
        }
        (original.clone(), original)
    }

    pub fn variables(
        &mut self,
        request: dap::Request,
        _arg: dap_types::VariablesArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        if self.trace_kind == TraceKind::Recreator {
            self.respond_dap(request, dap_types::VariablesResponseBody { variables: vec![] }, sender)?;
            return Ok(());
        }
        if self.trace_kind == TraceKind::Emulator {
            // Source locals from the replay session — the emulator
            // projects every named register (and, in future, DWARF-derived
            // locals) as a `VariableWithRecord`. The DAP `variables`
            // request carries an opaque `variables_reference`; we ignore
            // it here because the emulator surfaces a single flat scope
            // per frame.
            let locals_with_records = self.replay.load_locals(task::CtLoadLocalsArguments::default())?;
            // §P6.4 — surrounding step position threaded into the
            // per-position resolver, computed once per frame.
            let (file, line, col) = self.current_step_location();
            let dap_variables: Vec<dap_types::Variable> = locals_with_records
                .iter()
                .map(|l| {
                    let ct_val = to_ct_value(&l.value);
                    // §P5/P6.4 — user rename list + per-position
                    // sourcemap segment lookup at render time.
                    let (display, _original) = self.resolve_variable_name_at(&l.expression, &file, line, col);
                    dap::new_dap_variable(&display, &ct_val.text_repr(), 0)
                })
                .collect();
            self.respond_dap(
                request,
                dap_types::VariablesResponseBody {
                    variables: dap_variables,
                },
                sender,
            )?;
            return Ok(());
        }
        let empty_vars: Vec<FullValueRecord> = vec![];
        let vars_slice = self.reader.variables_at(self.step_id).unwrap_or(&empty_vars);
        // §P6.4 — surrounding step position threaded into the
        // per-position resolver, computed once per frame.
        let (file, line, col) = self.current_step_location();
        let full_value_locals: Vec<Variable> = vars_slice
            .iter()
            .map(|v| {
                let recorded_name = self
                    .reader
                    .variable_name(v.variable_id)
                    .unwrap_or("<unknown>")
                    .to_string();
                // §P5/P6.4 — user rename list + per-position sourcemap
                // segment lookup at render time.
                let (display, _original) = self.resolve_variable_name_at(&recorded_name, &file, line, col);
                Variable {
                    expression: display,
                    value: self.reader.to_ct_value(&v.value),
                    address: NO_ADDRESS,
                    origin_summary: None,
                }
            })
            .collect();

        let dap_variables = full_value_locals.iter().map(|v| self.to_dap_variable(v)).collect();

        self.respond_dap(
            request,
            dap_types::VariablesResponseBody {
                variables: dap_variables,
            },
            sender,
        )?;

        Ok(())
    }

    pub fn respond_to_disconnect(
        &mut self,
        request: dap::Request,
        _arg: dap_types::DisconnectArguments,
        sender: Sender<DapMessage>,
    ) -> Result<(), Box<dyn Error>> {
        self.respond_dap(request, dap::DisconnectResponseBody {}, sender)?;

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Value Origin Tracking — small free helpers shared by the eager/placeholder
// summary builders. Kept outside `impl Handler` so they can be reused from
// tests + future MCP/CLI surfaces without going through a Handler instance.
// ---------------------------------------------------------------------------

/// Compress an `OriginChain` into its single-row `OriginSummary` (spec
/// §4.1). `is_placeholder` is the value the caller wants set on the
/// summary; pass `false` for eager surfaces.
pub(crate) fn origin_chain_to_summary(chain: &task::OriginChain, is_placeholder: bool) -> task::OriginSummary {
    task::OriginSummary {
        terminator_kind: chain.terminator.kind.into(),
        terminator_expr: chain.terminator.expression.clone(),
        terminator_function: chain.terminator.function.clone(),
        hop_count: chain.hops.len() as u32,
        confidence: chain.confidence,
        is_placeholder,
        placeholder_token: None,
    }
}

/// M21 — free-standing helper that resolves the per-row eager / placeholder
/// summary for `ct/load-flow` annotations.  Lives outside `impl Handler`
/// so the flow hot loop can hold a borrow of `self.reader` without
/// fighting Rust's mutable-borrow analyser inside the per-row body.
///
/// Returns an eager `OriginSummary` when the metadata decoder covers
/// `(variable_id, step_id)`; otherwise a placeholder so the frontend
/// either renders `[?]` (lazy Mode 3) or fills the summary lazily via
/// `ct/originSummary` (Mode 1 / Mode 2).
pub(crate) fn build_flow_eager_or_placeholder(
    reader: &dyn TraceReader,
    decoder: Option<&crate::origin_metadata_indexer::OriginMetadataDecoder>,
    class: crate::eager_origin_mode::EagerModeClass,
    patterns_fingerprint: &str,
    var_name: &str,
    step_id: StepId,
) -> task::OriginSummary {
    if class.flips_eager()
        && let (Some(var_id), Some(decoder)) = (reader.variable_id_for(var_name), decoder)
    {
        let builder = crate::eager_origin_mode::EagerSummaryBuilder::new(Some(decoder), class);
        if let Some(summary) = builder.lookup_eager(var_id, step_id) {
            return summary;
        }
    }
    let token = crate::origin_query::OriginContinuationToken {
        v: crate::origin_query::OriginContinuationToken::CURRENT_VERSION,
        query_variable: var_name.to_string(),
        query_step_id: step_id.0,
        current_step: step_id.0,
        current_frame: -1,
        current_var_name: var_name.to_string(),
        hops_emitted: 0,
        max_hops: task::DEFAULT_ORIGIN_MAX_HOPS,
        patterns_fingerprint: patterns_fingerprint.to_string(),
        source_digests: Vec::new(),
        issued_at: 0,
    };
    crate::origin_query::placeholder_summary(token)
}

/// Default fallback summary used when a backend does not (yet) support
/// origin queries — the frontend renders an unobtrusive Unknown badge.
pub(crate) fn placeholder_unknown_summary() -> task::OriginSummary {
    task::OriginSummary {
        terminator_kind: task::TerminatorKindWire::UnknownSource,
        terminator_expr: String::new(),
        terminator_function: None,
        hop_count: 0,
        confidence: 0.0,
        is_placeholder: true,
        placeholder_token: None,
    }
}

/// Locate the `.ct` CTFS container under `trace_dir`.
///
/// `trace_dir` is whatever the dispatcher passed to
/// [`Handler::load_sourcemaps`] / [`Handler::load_source_views`].
/// It can be either:
///
/// * The trace directory itself (the dispatcher hands the parent
///   folder) — we probe `<dir>/trace.ct`, then the first `*.ct` we
///   find in the directory.
/// * A `.ct` file directly (the ct-dap-client test harness passes the
///   file path as the trace folder).
///
/// Returns `None` when nothing matching the CTFS magic is found; the
/// caller treats that as "no srcviews, fall through".
fn find_ct_container(trace_dir: &Path) -> Option<std::path::PathBuf> {
    // Direct `.ct` file → use as-is.
    if trace_dir.is_file() {
        return Some(trace_dir.to_path_buf());
    }
    if !trace_dir.is_dir() {
        return None;
    }
    let canonical = trace_dir.join("trace.ct");
    if canonical.is_file() {
        return Some(canonical);
    }
    // Fallback: first `*.ct` in the directory.  Several recorders use
    // the recording id or a free-form name; we accept any single `.ct`
    // file so this helper degrades gracefully across recorders.
    let read_dir = std::fs::read_dir(trace_dir).ok()?;
    for entry in read_dir.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("ct") && p.is_file() {
            return Some(p);
        }
    }
    None
}

/// §P6.2 — materialise a srcviews record onto disk.
///
/// Writes both the formatted content and its V3 sourcemap under
/// `<trace_dir>/sourcemap-translate/`:
///
/// * `<sanitised view_name>` — the formatted source bytes;
/// * `<sanitised view_name>.map` — the V3 JSON.
///
/// Returns the absolute path of the formatted-content sidecar on
/// success, or `None` if any write step failed (the helper logs the
/// failure and the caller falls back to surfacing `view_name` verbatim
/// in the cache entry).
fn materialise_source_view(trace_dir: &Path, view_name: &str, content: &[u8], sourcemap_v3: &[u8]) -> Option<String> {
    let cache_root = trace_dir.join("sourcemap-translate");
    if let Err(e) = std::fs::create_dir_all(&cache_root) {
        warn!("srcviews: failed to create cache dir {}: {e}", cache_root.display());
        return None;
    }

    // Flatten any path-traversal segments in view_name (the recorder
    // may have included `.fmt.<ext>` or even a `./` prefix).
    let safe = sanitize_view_name(view_name);
    let content_path = cache_root.join(&safe);
    let map_path = cache_root.join(format!("{}.map", safe));

    if let Err(e) = std::fs::write(&content_path, content) {
        warn!("srcviews: failed to write content to {}: {e}", content_path.display());
        return None;
    }
    if !sourcemap_v3.is_empty()
        && let Err(e) = std::fs::write(&map_path, sourcemap_v3)
    {
        // Map sidecar is a nice-to-have for diagnosability — log but
        // do not fail the whole materialisation if only the map write
        // fails (the in-memory `SourcemapIndex` already holds the
        // parsed map).
        warn!("srcviews: failed to write map to {}: {e}", map_path.display());
    }
    Some(content_path.display().to_string())
}

/// Strip path-traversal segments from a srcviews `view_name`.
///
/// Keeps printable basename characters intact (so legibility is
/// preserved for the typical `<original>.fmt.<ext>` case) while
/// replacing path separators and control characters.
fn sanitize_view_name(name: &str) -> String {
    let trimmed = std::path::Path::new(name)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or(name);
    let cleaned: String = trimmed
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' => '_',
            c if c.is_ascii_control() => '_',
            c => c,
        })
        .collect();
    if cleaned.is_empty() {
        "source".to_string()
    } else {
        cleaned
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
#[allow(clippy::expect_used)]
#[allow(clippy::panic)]
mod tests {
    use std::env;
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;

    use super::*;
    // use crate::event_db;
    use crate::ctfs_trace_reader::CTFSTraceReader;
    use crate::lang;
    use crate::task;
    use crate::task::{GlobalCallLineIndex, gen_task_id};
    use crate::trace_processor::TraceProcessor;
    use clap::error::Result;
    // use event_db::{IndexInSingleTable, SingleTableId};
    // use futures::stream::Iter;
    use codetracer_trace_types::{
        CallRecord, FieldTypeRecord, FunctionId, FunctionRecord, NONE_VALUE, StepId, StepRecord, TraceLowLevelEvent,
        TraceMetadata, TypeId, TypeKind, TypeRecord, TypeSpecificInfo, ValueRecord,
    };
    use codetracer_trace_writer::non_streaming_trace_writer::NonStreamingTraceWriter;
    use codetracer_trace_writer::trace_writer::TraceWriter;
    use lang::Lang;

    use task::{TaskKind, TraceSession, Tracepoint, TracepointMode};

    #[test]
    fn test_struct_handling() {
        let db = setup_db();
        let handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        let value = handler.reader.to_ct_value(&ValueRecord::Struct {
            field_values: vec![],
            type_id: TypeId(1),
        });
        assert_eq!(value.typ.labels, ["a".to_string()]);
    }
    #[test]
    fn test_handler_new() {
        // Arrange: Create a Db instance and an mpsc channel
        let db = setup_db();

        // Act: Create a new Handler instance
        let handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));

        // Assert: Check that the Handler instance is correctly initialized
        assert_eq!(handler.step_id, StepId(0));
        assert!(!handler.breakpoints.is_empty());
    }

    // Test single tracepoint
    #[test]
    fn test_run_single_tracepoint() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        handler.event_load(dap::Request::default(), sender.clone())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_args(1, 0), sender)?;
        assert_eq!(handler.event_db.single_tables.len(), 2);
        Ok(())
    }

    // Test basic multiple tracepoints
    #[test]
    fn test_multiple_tracepoints() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default(), sender)?;
        // TODO
        // this way we are resetting them after reforms
        // needs to pass multiple tracepoints at once now
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(3, 0),
        // )?;
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(2, 1),
        // )?;
        // handler.run_tracepoints(
        //     dap::Request::default(),
        //     make_tracepoints_args(1, 2),
        // )?;
        // assert_eq!(handler.event_db.single_tables.len(), 4);
        // assert_eq!(handler.event_db.global_table.len(), 3);
        // assert_eq!(
        //     handler.event_db.global_table,
        //     vec![
        //         (StepId(0), SingleTableId(3), IndexInSingleTable(0)),
        //         (StepId(1), SingleTableId(2), IndexInSingleTable(0)),
        //         (StepId(2), SingleTableId(1), IndexInSingleTable(0))
        //     ]
        // );
        Ok(())
    }

    // pass size to produce multiline multiple log(expr) to log on a step
    #[test]
    fn test_multile_tracepoints_with_multiline_logs() -> Result<(), Box<dyn Error>> {
        let size: usize = 10000;
        let db: Db = setup_db();
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default(), sender.clone())?;
        handler.run_tracepoints(
            dap::Request::default(),
            make_multiple_tracepoints_with_multiline_logs(3, size),
            sender,
        )?;
        assert_eq!(handler.event_db.single_tables.len(), 4);
        // TODO(alexander): debug what's happening here

        // assert_eq!(handler.event_db.global_table.len(), 3);
        // assert_eq!(
        //     handler.event_db.global_table,
        //     vec![
        //         (StepId(0), SingleTableId(1), IndexInSingleTable(0)),
        //         (StepId(1), SingleTableId(2), IndexInSingleTable(0)),
        //         (StepId(2), SingleTableId(3), IndexInSingleTable(0))
        //     ]
        // );
        Ok(())
    }

    // Test a tracepoint on a loop line (processes 10,000 loop iterations; ~7s)
    #[test]
    fn test_tracepoint_in_loop() -> Result<(), Box<dyn Error>> {
        let size = 10000;
        let db: Db = setup_db_loop(size);
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default(), sender.clone())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_args(2, 0), sender)?;
        assert_eq!(handler.event_db.single_tables[1].events.len(), size);
        Ok(())
    }

    // Test a given number of steps with individual tracepoint on each (10,000 steps; ~7s)
    #[test]
    fn test_big_number_tracepoints() -> Result<(), Box<dyn Error>> {
        // Number of tracepoints and steps
        let count: usize = 10000;
        let db: Db = setup_db_with_step_count(count);
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        handler.event_load(dap::Request::default(), sender.clone())?;
        handler.run_tracepoints(dap::Request::default(), make_tracepoints_with_count(count), sender)?;

        assert_eq!(handler.event_db.single_tables.len(), count + 1);
        Ok(())
    }

    #[test]
    fn test_step_in() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received

        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        let request = dap::Request::default();
        handler.step(request, make_step_in(), sender)?;
        assert_eq!(handler.step_id, StepId(1_i64));
        Ok(())
    }

    #[test]
    fn test_source_jumps() -> Result<(), Box<dyn Error>> {
        let db = setup_db();
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received
        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));
        let path = "/test/workdir";
        let source_location: SourceLocation = SourceLocation {
            path: path.to_string(),
            line: 3,
            column: None,
        };
        handler.source_line_jump(dap::Request::default(), source_location, sender.clone())?;
        assert_eq!(handler.step_id, StepId(2));
        handler.source_line_jump(
            dap::Request::default(),
            SourceLocation {
                path: path.to_string(),
                line: 2,
                column: None,
            },
            sender.clone(),
        )?;
        assert_eq!(handler.step_id, StepId(1));
        handler.source_call_jump(
            dap::Request::default(),
            SourceCallJumpTarget {
                path: "/test/workdir".to_string(),
                line: 1,
                token: "<top-level>".to_string(),
            },
            sender,
        )?;
        assert_eq!(handler.step_id, StepId(0));
        Ok(())
    }

    #[test]
    fn test_local_calltrace() -> Result<(), Box<dyn Error>> {
        let db = setup_db_with_calls();

        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));

        let calltrace_load_args = CalltraceLoadArgs {
            location: handler
                .reader
                .load_location(StepId(4), CallKey(-1), &mut handler.expr_loader),
            start_call_line_index: GlobalCallLineIndex(0),
            depth: 10,
            height: 10,
            raw_ignore_patterns: "".to_string(),
            auto_collapsing: true,
            optimize_collapse: true,
            render_call_line_index: 0,
        };
        let _call_lines = handler.load_local_calltrace(calltrace_load_args)?;

        // assert_eq!(parent_key, CallKey(0));
        // assert_eq!(calltrace.location.key, "1".to_string());
        // assert_eq!(calltrace.children.len(), 2);
        // let call_a = &calltrace.children[0];
        // let call_b = &calltrace.children[1];
        // assert_eq!(call_a.location.function_name, "a".to_string());
        // assert_eq!(call_a.location.key, "2".to_string());
        // assert_eq!(call_b.location.function_name, "b".to_string());
        // assert_eq!(call_b.location.key, "3".to_string());

        Ok(())
    }

    #[test]
    fn test_valid_trace() {
        // can be called from just test-valid-trace <my-trace-dir>
        // calling inside db-backend
        // env CODETRACER_VALID_TEST_TRACE_DIR=<trace-dir> cargo test test_valid_trace
        let raw_path = env::var("CODETRACER_VALID_TEST_TRACE_DIR").unwrap_or("".to_string());
        if raw_path.is_empty() {
            // assume called as part of normal tests or by mistake: just don't do anything and return
            return;
        }
        let path = &PathBuf::from(raw_path);
        // (&PathBuf::from("/home/alexander92/codetracer-desktop/src/db-backend/example-trace/")
        let db = load_db_for_trace(path);
        let (sender, _r) = mpsc::channel(); // for now just artificial sender; not received

        let mut handler: Handler = Handler::new(TraceKind::Materialized, RecreatorArgs::default(), Box::new(db));

        // step-in from 1 to end(maybe also a parameter?)
        // on each step check validity, load locals, load callstack
        // eventually: loading local calltrace? or at least for first real call?
        // eventually: loading flow for new calls?
        // first version loading locals/callstack
        test_step_in_scenario(&mut handler, path, sender);
    }

    fn test_load_flow(handler: &mut Handler, _path: &Path, sender: Sender<DapMessage>) {
        handler
            .load_flow(
                dap::Request::default(),
                CtLoadFlowArguments {
                    flow_mode: FlowMode::Call,
                    location: handler.load_location(handler.step_id),
                },
                sender,
            )
            .unwrap();
    }

    fn test_step_in_scenario(handler: &mut Handler, path: &Path, sender: Sender<DapMessage>) {
        for i in 0..handler.reader.step_count() - 1 {
            // eprintln!("doing step-in {i}");
            handler.step_in(true).unwrap();
            assert_eq!(handler.step_id, StepId(i as i64 + 1));
            test_load_locals(handler, sender.clone());
            // test_load_callstack(handler);
            test_load_flow(handler, path, sender.clone());
        }
    }

    fn test_load_locals(handler: &mut Handler, sender: Sender<DapMessage>) {
        handler
            .load_locals(dap::Request::default(), task::CtLoadLocalsArguments::default(), sender)
            .unwrap();
    }

    // fn test_load_callstack(handler: &mut Handler) {
    //     handler.load_callstack(gen_task(TaskKind::LoadCallstack)).unwrap();
    // }

    fn gen_task(kind: TaskKind) -> Task {
        Task {
            kind,
            id: gen_task_id(kind),
        }
    }
    /// Open the CTFS materialized trace at `path` and return its populated
    /// `Db`. Used by db-backend unit tests that drive the handler against a
    /// pre-recorded `.ct` container. Legacy
    /// `trace.bin`/`trace.json`/`trace_metadata.json` triplets are no longer
    /// supported.
    fn load_db_for_trace(path: &Path) -> Db {
        let ct_path = if path.is_file() && path.extension().is_some_and(|ext| ext == std::ffi::OsStr::new("ct")) {
            path.to_path_buf()
        } else {
            std::fs::read_dir(path)
                .unwrap_or_else(|e| panic!("failed to read trace dir {}: {}", path.display(), e))
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .find(|p| p.is_file() && p.extension().is_some_and(|ext| ext == "ct"))
                .unwrap_or_else(|| panic!("no *.ct container found in {}", path.display()))
        };

        let reader = CTFSTraceReader::open(&ct_path)
            .unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct_path.display(), e));
        reader.db().clone()
    }

    fn setup_db() -> Db {
        // TODO: maybe source from a real program trace?
        let none_type = TypeRecord {
            kind: TypeKind::None,
            lang_type: "None".to_string(),
            specific_info: TypeSpecificInfo::None,
        };
        let struct_type = TypeRecord {
            kind: TypeKind::Struct,
            lang_type: "ExampleStruct".to_string(),
            specific_info: TypeSpecificInfo::Struct {
                fields: vec![FieldTypeRecord {
                    name: "a".to_string(),
                    type_id: TypeId(0),
                }],
            },
        };

        let trace: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level>".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            TraceLowLevelEvent::Type(none_type),
            TraceLowLevelEvent::Type(struct_type),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(1),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
        ];
        let trace_metadata = TraceMetadata {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn setup_db_with_calls() -> Db {
        // TODO: maybe source from a real program trace?
        let mut tracer = NonStreamingTraceWriter::new("example.small", &[]);
        let path = &PathBuf::from("/test/workdir/example.small");
        tracer.start(path, Line(1));
        tracer.register_step(path, Line(1));
        tracer.register_step(path, Line(2));
        tracer.register_step(path, Line(3));

        tracer.register_step(path, Line(4));
        let start_function_id = tracer.ensure_function_id("start", path, Line(4));
        tracer.register_call(start_function_id, vec![]);

        tracer.register_step(path, Line(5));

        tracer.register_step(path, Line(7));
        let a_function_id = tracer.ensure_function_id("a", path, Line(7));
        tracer.register_call(a_function_id, vec![]);
        tracer.register_step(path, Line(8));
        tracer.register_return(NONE_VALUE);

        tracer.register_step(path, Line(6));
        let b_function_id = tracer.ensure_function_id("b", path, Line(10));
        tracer.register_call(b_function_id, vec![]);
        tracer.register_step(path, Line(11));
        tracer.register_return(NONE_VALUE);

        let trace_metadata = TraceMetadata {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            workdir: PathBuf::from("/test/workdir"),
            program: "example.small".to_string(),
            args: vec![],
        };

        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&tracer.events).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn setup_db_loop(size: usize) -> Db {
        let loop_steps = vec![
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(2),
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(3),
            }),
        ];
        let mut trace: Vec<TraceLowLevelEvent> = vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
            TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(1),
            }),
        ];
        for _ in 0..size {
            trace.extend(loop_steps.clone())
        }
        let trace_metadata = TraceMetadata {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();
        db
    }

    // Alternative Db setup
    fn setup_db_with_step_count(count: usize) -> Db {
        let mut events: Vec<TraceLowLevelEvent> = vec![];
        events.extend(vec![
            TraceLowLevelEvent::Path(PathBuf::from("/test/workdir")),
            TraceLowLevelEvent::Function(FunctionRecord {
                path_id: PathId(0),
                line: Line(1),
                name: "<top-level".to_string(),
            }),
            TraceLowLevelEvent::Call(CallRecord {
                function_id: FunctionId(0),
                args: vec![],
            }),
        ]);
        for i in 0..count {
            events.push(TraceLowLevelEvent::Step(StepRecord {
                path_id: PathId(0),
                line: Line(i as i64 + 1),
            }));
        }
        let trace = events;
        let trace_metadata = TraceMetadata {
            recording_id: "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb".to_string(),
            workdir: PathBuf::from("/test/workdir"),
            program: "test".to_string(),
            args: vec![],
        };
        let mut db = Db::new(&trace_metadata.workdir);
        let mut trace_processor = TraceProcessor::new(&mut db);
        trace_processor.postprocess(&trace).unwrap();

        // eprintln!("{:#?}", db);
        db
    }

    fn make_step_in() -> StepArg {
        StepArg {
            action: Action::StepIn,
            reverse: false,
            repeat: 0,
            complete: true,
            skip_internal: true,
            skip_no_source: false,
        }
    }

    // Individual tracesessions for earch tracepoint
    fn make_tracepoints_args(line: usize, id: usize) -> RunTracepointsArg {
        RunTracepointsArg {
            session: TraceSession {
                tracepoints: vec![Tracepoint {
                    tracepoint_id: id,
                    mode: TracepointMode::TracInlineCode,
                    line,
                    offset: -1,
                    is_changed: true,
                    name: "/test/workdir".to_string(),
                    expression: "log(test)".to_string(),
                    last_render: 0,
                    is_disabled: false,
                    lang: Lang::Unknown,
                    results: vec![],
                    tracepoint_error: "".to_string(),
                }],
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }

    // One TraceSession with a Vec<Tracepoint>
    fn make_tracepoints_with_count(count: usize) -> RunTracepointsArg {
        let mut tracepoints: Vec<Tracepoint> = vec![];
        for i in 0..count {
            tracepoints.push(Tracepoint {
                tracepoint_id: i,
                mode: TracepointMode::TracInlineCode,
                line: i + 1,
                offset: -1,
                is_changed: true,
                name: "/test/workdir".to_string(),
                expression: "log(test)".to_string(),
                last_render: 0,
                is_disabled: false,
                lang: Lang::Unknown,
                results: vec![],
                tracepoint_error: "".to_string(),
            });
        }

        RunTracepointsArg {
            session: TraceSession {
                tracepoints,
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }

    // One TraceSession with a Vec<Tracepoint>
    fn make_multiple_tracepoints_with_multiline_logs(iterations: usize, size: usize) -> RunTracepointsArg {
        let mut tracepoints: Vec<Tracepoint> = vec![];
        let mut expression: String = "".to_string();
        for _ in 0..size {
            expression += "log(asd)\n"
        }
        for i in 0..iterations {
            tracepoints.push(Tracepoint {
                tracepoint_id: i,
                mode: TracepointMode::TracInlineCode,
                line: i + 1,
                offset: -1,
                is_changed: true,
                name: "/test/workdir".to_string(),
                expression: expression.to_string(),
                last_render: 0,
                is_disabled: false,
                lang: Lang::Unknown,
                results: vec![],
                tracepoint_error: "".to_string(),
            });
        }

        RunTracepointsArg {
            session: TraceSession {
                tracepoints,
                found: vec![],
                last_count: 0,
                results: HashMap::default(),
                id: 0,
            },
            stop_after: 0,
        }
    }
}

// TODO:
// * load-locals
//   * convert ValueRecord to Value
//   * optionally more kinds of Values
// * event-load/event jump
// * stepping/line jump
//   * step-in
//   * step-out
//   * next (and same for reverse but back)
// * ?break/continue
// * ?callstack/calltrace
//   * eventually if non-full traces, direct callstack in trace?
//   * fuller calltrace interface? maybe discuss with team?
//   * multiple trees if separate parts recorded?
// * ?filters
//   * eventually ct libs used inside programs?
// * build/MR/try?
// * languages:
//   * python/nim/php/java/perl/lua/javascript/other
//
// * later potentially:
//   * tracepoint?
//     * for now maybe only existing locals/combos of them e.g. a.b
//   * flow
//     * for now extracting just more for names on each line
//     * eventually a mini-lib for branches/loops from rust and logic
//       * reuse from python? or for now have 2 impls?
//   * multi-process:
//     * process/thread id
//     * different calltraces/callstacks based on that
//     * eventually jumps/phases?
// * potentially later in future:
//   * queries: e.g. if variable > 5 and in calltree x
//   * exceptions/signal/return values more special
//   * async?
