use crate::dap_error::DapError;

use crate::dap_types::{self, OutputEventBody, SetBreakpointsArguments, StoppedEventBody};
use crate::task::{self, CtUpdatedTableResponseBody, Location};
use crate::transport::DapResult;
use serde::{Deserialize, Serialize, de::DeserializeOwned, de::Error as SerdeError};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Counter — increments once per deserialization pass over an INBOUND DAP
/// payload: the bytes a client sent us, whether the pass starts from the raw
/// text or from an already-built [`Value`].
///
/// The point of the counter is that "how many times do we deserialize each
/// request" is otherwise invisible. Issue #222 was that every inbound request
/// was decoded three times on the native path and four in the browser worker,
/// and nothing in the tree could observe it: the passes live in three
/// different functions, each of which looks like a single reasonable
/// `serde_json` call on its own. A budget assertion over this counter is what
/// turns "that looks redundant" into a check that fails.
///
/// Unconditional and public, following the two counters that already do this
/// in this crate — `dap_handler::Handler::origin_summary_chain_builds` and
/// `dap_handler::Handler::marker_decode_calls`. It is a `Relaxed` add on an
/// already cache-hot line, once per decode of a message that is about to be
/// parsed anyway; it is not measurable next to the parse it counts.
///
/// Because it is process-global and cargo runs a test binary's tests in
/// threads of ONE process, any test that resets it and asserts on it must
/// serialise against every other such test — see
/// `tests/dap_protocol.rs::test_inbound_request_deserialization_budget`.
pub static INBOUND_PARSES: AtomicUsize = AtomicUsize::new(0);

/// Read the inbound-deserialization counter.
#[inline]
pub fn inbound_parse_count() -> usize {
    INBOUND_PARSES.load(Ordering::Relaxed)
}

/// Reset the inbound-deserialization counter. Test-support: see the note on
/// [`INBOUND_PARSES`] about serialising concurrent readers.
#[inline]
pub fn reset_inbound_parse_count() {
    INBOUND_PARSES.store(0, Ordering::Relaxed);
}

/// Deserialize an inbound payload from its raw text, counting the pass.
///
/// Every deserialization of client-supplied DAP bytes goes through this or
/// one of its two siblings; `tests/dap_protocol.rs` asserts (by source scan)
/// that no bare `serde_json::from_str` / `from_value` re-appears on the
/// inbound path, because a pass the counter never sees is a pass the budget
/// cannot hold.
#[inline]
pub fn parse_inbound_str<T: DeserializeOwned>(s: &str) -> serde_json::Result<T> {
    INBOUND_PARSES.fetch_add(1, Ordering::Relaxed);
    serde_json::from_str(s)
}

/// Deserialize an inbound payload out of an owned [`Value`], counting the
/// pass. Prefer [`parse_inbound_value_ref`] when the `Value` is still needed
/// afterwards: it borrows instead of forcing a deep clone at the call site.
#[inline]
pub fn parse_inbound_value<T: DeserializeOwned>(value: Value) -> serde_json::Result<T> {
    INBOUND_PARSES.fetch_add(1, Ordering::Relaxed);
    serde_json::from_value(value)
}

/// Deserialize an inbound payload out of a borrowed [`Value`], counting the
/// pass.
///
/// `&Value` is itself a `serde_json` `Deserializer`, so this reads the tree in
/// place. It exists because the alternative at the call sites that keep their
/// `Value` — `Request::load_args` and friends — was
/// `from_value(self.arguments.clone())`, and that clone deep-copies the whole
/// arguments subtree on every single request purely to hand serde something
/// owned.
#[inline]
pub fn parse_inbound_value_ref<T: DeserializeOwned>(value: &Value) -> serde_json::Result<T> {
    INBOUND_PARSES.fetch_add(1, Ordering::Relaxed);
    T::deserialize(value)
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Clone)]
pub struct ProtocolMessage {
    pub seq: i64,
    #[serde(rename = "type")]
    pub type_: String,
}

#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Clone)]
pub struct Request {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub command: String,
    #[serde(default)]
    pub arguments: Value, //RequestArguments,
}

// using this custom definition, not autogenerating one, because we have custom fields for
// ct launch request (and to handle manually the rename = "__restart" case)
#[derive(Serialize, Deserialize, Debug, Default, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct LaunchRequestArguments {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub args: Option<Vec<String>>,
    #[serde(rename = "traceFolder", skip_serializing_if = "Option::is_none")]
    pub trace_folder: Option<PathBuf>,
    #[serde(rename = "liveRecording", skip_serializing_if = "Option::is_none")]
    pub live_recording: Option<bool>,
    #[serde(rename = "liveRecordingDir", skip_serializing_if = "Option::is_none")]
    pub live_recording_dir: Option<PathBuf>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_file: Option<PathBuf>,
    #[serde(rename = "rawDiffIndex", skip_serializing_if = "Option::is_none")]
    pub raw_diff_index: Option<String>,
    #[serde(rename = "ctRRWorkerExe", skip_serializing_if = "Option::is_none")]
    pub recreator_exe: Option<PathBuf>,
    #[serde(rename = "restoreLocation", skip_serializing_if = "Option::is_none")]
    pub restore_location: Option<Location>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(rename = "noDebug", skip_serializing_if = "Option::is_none")]
    pub no_debug: Option<bool>,
    #[serde(rename = "__restart", skip_serializing_if = "Option::is_none")]
    pub restart: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request: Option<String>,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub typ: Option<String>,
    #[serde(rename = "__sessionId", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Column-Aware-Tracing-And-Deminification §P5.4 — explicit path to
    /// a user-provided rename list (TOML).  When `Some(_)` the loader
    /// uses this path instead of the default sibling lookup
    /// (`<recording-dir>/renames.toml`).  When `None` the trace-open
    /// hook tries the sibling location.  See
    /// [`crate::rename_list::RenameList`].
    #[serde(rename = "renameList", skip_serializing_if = "Option::is_none")]
    pub rename_list: Option<PathBuf>,
    /// Browser trace source descriptor, as emitted by the embed SDK's
    /// `TraceSource.toLaunchArgs`
    /// (`src/frontend/viewmodel/sdk/trace_source.nim`).
    ///
    /// The field exists so the engine can **name** what it cannot honour.
    /// Before it did, `#[serde(deny_unknown_fields)]` above turned every
    /// non-`local-folder` launch into `unknown field \`traceSource\``: a
    /// parse error, which the native server loop only `error!`s (the client
    /// gets no launch response at all) and which the SDK's §6.3 classifier
    /// buckets as the least informative `BackendError`. A launch the engine
    /// cannot serve must fail by name, once, with a message that says what
    /// to do instead — see [`TraceSourceArgument::unsupported_reason`].
    #[serde(rename = "traceSource", skip_serializing_if = "Option::is_none")]
    pub trace_source: Option<TraceSourceArgument>,
}

/// The trace-source vocabulary shared with the embed SDK.
///
/// These strings are the wire contract: `TraceSourceKind` in
/// `src/frontend/viewmodel/sdk/trace_source.nim` declares the identical set
/// (`tskLocalFolder = "local-folder"`, …).  `launch_trace_source_test.rs`
/// and the Nim `test_sdk_facade` suite both pin the list, so the two cannot
/// drift apart without a test failing.
pub const TRACE_SOURCE_KINDS: &[&str] = &["local-folder", "http-range", "opfs", "bytes", "custom"];

/// A `traceSource` descriptor.
///
/// `kind` is deliberately a `String` rather than an enum: an SDK that grows
/// a sixth kind must get a message naming *that kind*, not `unknown variant`
/// from serde. Likewise the payload fields are optional and unknown ones are
/// tolerated — the engine's answer depends on the kind alone, and a stricter
/// parse could only degrade the message on a launch it was going to refuse
/// regardless.
#[derive(Serialize, Deserialize, Debug, Default, PartialEq, Clone)]
pub struct TraceSourceArgument {
    pub kind: String,
    /// `http-range`: the URL the container is served from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// `opfs`: the Origin Private File System path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// `bytes`: the payload length. The bytes themselves are never on the
    /// wire — which is precisely why this kind cannot be honoured from
    /// launch arguments alone.
    #[serde(rename = "byteLength", default, skip_serializing_if = "Option::is_none")]
    pub byte_length: Option<u64>,
    /// `custom`: the caller's name for its block source.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl TraceSourceArgument {
    /// Why this source cannot be opened, or `None` when it can.
    ///
    /// Every message contains the word "unsupported", which is what the
    /// SDK's `classifyBackendFailure` keys on to reach
    /// `dseUnsupportedTraceKind` rather than the catch-all bucket. That
    /// coupling is asserted from both sides.
    pub fn unsupported_reason(&self) -> Option<String> {
        let known = TRACE_SOURCE_KINDS.contains(&self.kind.as_str());
        if self.kind == "local-folder" {
            // The SDK never emits a `traceSource` for this kind — it sends
            // `traceFolder` directly — but accepting it here costs nothing
            // and keeps the vocabulary honest.
            return None;
        }
        let detail = if known {
            "the replay engine opens a trace that is already in its virtual file system; \
             push the container's bytes with `vfs_write_file` and launch with `traceFolder`"
        } else {
            "unrecognised kind"
        };
        Some(format!(
            "unsupported launch traceSource kind `{}` ({detail}). Known kinds: {}.",
            self.kind,
            TRACE_SOURCE_KINDS.join(", "),
        ))
    }
}

// TODO: for now easier to initialize those, but when we start processing client capabilities or in
// other case, use dap_types::Capabilities
#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    #[serde(rename = "supportsLoadedSourcesRequest", skip_serializing_if = "Option::is_none")]
    pub supports_loaded_sources_request: Option<bool>,
    #[serde(rename = "supportsStepBack", skip_serializing_if = "Option::is_none")]
    pub supports_step_back: Option<bool>,
    #[serde(rename = "supportsConfigurationDoneRequest", skip_serializing_if = "Option::is_none")]
    pub supports_configuration_done_request: Option<bool>,
    #[serde(rename = "supportsDisassembleRequest", skip_serializing_if = "Option::is_none")]
    pub supports_disassemble_request: Option<bool>,
    #[serde(rename = "supportsLogPoints", skip_serializing_if = "Option::is_none")]
    pub supports_log_points: Option<bool>,
    #[serde(rename = "supportsRestartRequest", skip_serializing_if = "Option::is_none")]
    pub supports_restart_request: Option<bool>,
    /// CodeTracer extension (M-capability-flags): true iff the loaded
    /// trace's recorder advertised support for per-column breakpoints
    /// via `meta.dat` bit 6 (`FLAG_SUPPORTS_COLUMN_BREAKPOINTS`).
    /// Omitted on the `initialize` response (no trace loaded yet);
    /// populated on the per-trace capability-refresh hook the GUI
    /// inspects in `services/debugger_service.nim`.  When `Some(false)`
    /// the GUI MUST hide the per-column breakpoint affordance.
    #[serde(rename = "supportsColumnBreakpoints", skip_serializing_if = "Option::is_none")]
    pub supports_column_breakpoints: Option<bool>,
    /// CodeTracer extension (M-capability-flags): true iff the loaded
    /// trace's recorder advertised support for per-column step motions
    /// via `meta.dat` bit 7 (`FLAG_SUPPORTS_COLUMN_MOTIONS`).  When
    /// `Some(false)` the GUI MUST hide column-aware step-over /
    /// step-in / step-out buttons.
    #[serde(rename = "supportsColumnMotions", skip_serializing_if = "Option::is_none")]
    pub supports_column_motions: Option<bool>,
}

pub fn new_dap_variable(name: &str, value: &str, variables_reference: i64) -> dap_types::Variable {
    dap_types::Variable {
        name: name.to_string(),
        value: value.to_string(),
        variables_reference,
        r#type: None,
        presentation_hint: None,
        evaluate_name: None,
        named_variables: None,
        indexed_variables: None,
        memory_reference: None,
        declaration_location_reference: None,
        value_location_reference: None,
    }
}

#[derive(Serialize, Deserialize, Debug, PartialEq, Default, Clone)]
pub struct DisconnectResponseBody {}

impl Request {
    /// Deserialize this request's `arguments` into the command's own
    /// arguments type.
    ///
    /// Borrows the tree rather than cloning it (#222). `arguments` is read
    /// more than once per request in places — `dap_server.rs` reaches into it
    /// directly for `threadId`, and `launch` is loaded from two separate arms
    /// — so it cannot be taken; but nothing required the deep copy that
    /// `from_value(self.arguments.clone())` made purely to hand serde
    /// something owned.
    pub fn load_args<T: DeserializeOwned>(&self) -> DapResult<T> {
        Ok(parse_inbound_value_ref::<T>(&self.arguments)?)
    }

    /// Like `load_args`, but for commands whose arguments are entirely
    /// optional, so that a request carrying no `arguments` member at
    /// all is legitimate ("give me everything", "give me the first
    /// page").
    ///
    /// `Request::arguments` is `#[serde(default)]`, so an absent
    /// `arguments` member arrives as `Value::Null`, and
    /// `from_value::<T>(Null)` fails for a struct however optional its
    /// fields are.  Only that ONE case yields `T::default()` here.
    ///
    /// Do NOT write `load_args::<T>().unwrap_or_default()` instead: it
    /// cannot tell "no arguments were sent" from "arguments were sent
    /// and are malformed", so a client typo, a wrong type, or (once
    /// `deny_unknown_fields` is on) an unknown field is silently
    /// downgraded into the default request.  For the request-span
    /// commands that default means "no filters, no paging" — the
    /// caller asks for one page of failed requests, gets the entire
    /// recording, and is told nothing went wrong.  A parse failure is
    /// reported as a parse failure.
    pub fn load_args_or_default<T: DeserializeOwned + Default>(&self) -> DapResult<T> {
        if self.arguments.is_null() {
            return Ok(T::default());
        }
        Ok(parse_inbound_value_ref::<T>(&self.arguments)?)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Response {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub request_seq: i64,
    pub success: bool,
    pub command: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub body: Value,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Event {
    #[serde(flatten)]
    pub base: ProtocolMessage,
    pub event: String,
    #[serde(default)]
    pub body: Value,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
pub enum DapMessage {
    Request(Request),
    Response(Response),
    Event(Event),
}

#[derive(Debug, Clone)]
pub struct DapClient {
    pub seq: i64,
}

impl Default for DapClient {
    fn default() -> Self {
        DapClient { seq: 1 }
    }
}

impl DapClient {
    pub fn request(&mut self, command: &str, arguments: Value) -> DapMessage {
        DapMessage::Request(Request {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "request".to_string(),
            },
            command: command.to_string(),
            arguments,
        })
    }

    pub fn launch(&mut self, args: LaunchRequestArguments) -> DapResult<DapMessage> {
        Ok(self.request("launch", serde_json::to_value(args)?))
    }

    pub fn set_breakpoints(&mut self, args: SetBreakpointsArguments) -> DapResult<DapMessage> {
        Ok(self.request("setBreakpoints", serde_json::to_value(args)?))
    }

    pub fn updated_trace_event(&mut self, args: task::TraceUpdate) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-trace".to_string(),
            body: serde_json::to_value(args)?,
        }))
    }

    /// Emits a `ct/tracepoint-results` event carrying all tracepoint hits
    /// collected during a `ct/run-tracepoints` session.
    ///
    /// The daemon's Python bridge waits for this event to build the
    /// `ct/py-run-tracepoints` response.
    pub fn tracepoint_results_event(&mut self, args: task::TracepointResultsAggregate) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/tracepoint-results".to_string(),
            body: serde_json::to_value(args)?,
        }))
    }

    pub fn stopped_event(&mut self, reason: &str) -> DapResult<DapMessage> {
        let body = StoppedEventBody {
            reason: reason.to_string(),
            thread_id: Some(1),
            all_threads_stopped: Some(true),
            hit_breakpoint_ids: Some(vec![]),
            description: None,
            preserve_focus_hint: None,
            text: None,
        };
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "stopped".to_string(),
            body: serde_json::to_value(body)?,
        }))
    }

    pub fn updated_flow_event(&mut self, flow_update: task::FlowUpdate) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-flow".to_string(),
            body: serde_json::to_value(flow_update)?,
        }))
    }

    pub fn updated_history_event(&mut self, history_update: task::HistoryUpdate) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-history".to_string(),
            body: serde_json::to_value(history_update)?,
        }))
    }

    /// Emitted alongside the `ct/originChain` response so frontends can
    /// react to lazy continuations without re-issuing the request
    /// (spec §5.2 "ct/updated-origin-chain").
    pub fn updated_origin_chain_event(&mut self, chain: &task::OriginChain) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-origin-chain".to_string(),
            body: serde_json::to_value(chain)?,
        }))
    }

    /// RS-M3 — `ct/updated-http-requests`: a batch of HTTP Request Panel rows
    /// appended since the client's cursor.
    ///
    /// Emitted alongside the `ct/load-request-spans-since` response, following
    /// the `ct/updated-origin-chain` precedent, so an event-driven panel can
    /// consume the tail without correlating responses.
    ///
    /// The body is a [`crate::request_spans::RequestSpanDelta`]:
    /// `{ spans, cursor, reset, source }`. `spans` is settled within the batch
    /// and keyed on `id`; the client merges by that key, last wins. See the
    /// last-record-wins section in `request_spans.rs`.
    pub fn updated_http_requests_event(
        &mut self,
        delta: &crate::request_spans::RequestSpanDelta,
    ) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-http-requests".to_string(),
            body: serde_json::to_value(delta)?,
        }))
    }

    pub fn calltrace_search_event(&mut self, search_res: Vec<task::Call>) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/calltrace-search-res".to_string(),
            body: serde_json::to_value(search_res)?,
        }))
    }

    pub fn updated_events(&mut self, first_events: Vec<task::ProgramEvent>) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-events".to_string(),
            body: serde_json::to_value(first_events)?,
        }))
    }

    pub fn updated_events_content(&mut self, contents: String) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-events-content".to_string(),
            body: serde_json::to_value(contents)?,
        }))
    }

    pub fn updated_calltrace_event(&mut self, update: &task::CallArgsUpdateResults) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-calltrace".to_string(),
            body: serde_json::to_value(update)?,
        }))
    }

    pub fn updated_table_event(&mut self, update: &CtUpdatedTableResponseBody) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/updated-table".to_string(),
            body: serde_json::to_value(update)?,
        }))
    }

    pub fn tracepoint_locals_event(&mut self, values: &task::TraceValues) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "tracepoint-locals".to_string(),
            body: serde_json::to_value(values)?,
        }))
    }

    pub fn complete_move_event(&mut self, state: &task::MoveState) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/complete-move".to_string(),
            body: serde_json::to_value(state)?,
        }))
    }

    pub fn loaded_terminal_event(&mut self, events: Vec<task::ProgramEvent>) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/loaded-terminal".to_string(),
            body: serde_json::to_value(events)?,
        }))
    }

    pub fn notification_event(&mut self, notification: task::Notification) -> DapResult<DapMessage> {
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "ct/notification".to_string(),
            body: serde_json::to_value(notification)?,
        }))
    }

    pub fn output_event(&mut self, category: &str, path: &str, line: usize, output: &str) -> DapResult<DapMessage> {
        let body = OutputEventBody {
            category: Some(category.to_string()),
            output: output.to_string(),
            group: None,
            variables_reference: None,
            source: Some(dap_types::Source {
                name: Some("".to_string()),
                path: Some(path.to_string()),
                source_reference: None,
                adapter_data: None,
                checksums: None,
                origin: None,
                presentation_hint: None,
                sources: None,
            }),
            line: Some(line as i64),
            column: Some(1),
            data: None,
            location_reference: None,
        };
        Ok(DapMessage::Event(Event {
            base: ProtocolMessage {
                seq: self.next_seq(),
                type_: "event".to_string(),
            },
            event: "output".to_string(),
            body: serde_json::to_value(body)?,
        }))
    }

    fn next_seq(&mut self) -> i64 {
        let current = self.seq;
        self.seq += 1;
        current
    }

    pub fn with_seq(seq: i64) -> DapClient {
        DapClient { seq }
    }
}

/// Everything a failure response needs from a message that could not be
/// decoded: the `seq` the client parked its continuation under, and the
/// `command` it was waiting on.
///
/// This is what [`decode_inbound`] hands back instead of the raw [`Value`].
/// The browser worker used to recover the same two fields by parsing the
/// whole payload a SECOND time, up front, on every message — including the
/// overwhelming majority that decode fine and never look at it (#222).
/// Carrying the two fields out of the parse that already happened costs one
/// short string and removes that pass entirely.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct InboundFailureIdentity {
    pub request_seq: i64,
    pub command: String,
}

impl InboundFailureIdentity {
    /// Best-effort identity from an already-parsed payload. Absent or
    /// wrong-typed members give `0` / `""`, which is what a client sees today
    /// for a message that is not JSON at all.
    fn from_raw(raw: &Value) -> Self {
        InboundFailureIdentity {
            request_seq: raw.get("seq").and_then(|v| v.as_i64()).unwrap_or(0),
            command: raw.get("command").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        }
    }
}

/// Decode one inbound DAP message from its raw text.
///
/// Ungated on purpose. The browser worker's `onmessage` closure used to do
/// its own decoding inline — a `serde_json::from_str` for the failure
/// identity, then `from_json` — and being inside a
/// `#[cfg(feature = "browser-transport")]` closure that needs a
/// `DedicatedWorkerGlobalScope`, that code could not be reached by any test
/// in this crate (there is no `wasm_bindgen_test` runner here). It was
/// therefore the one copy of the decode path that nothing measured, which is
/// why it carried a fourth parse the native path did not.
///
/// With the decode here, the closure is a caller with no `serde_json` in it,
/// and `tests/dap_protocol.rs`'s budget covers both transports.
///
/// On failure it returns the [`InboundFailureIdentity`] recovered from the
/// payload so the caller can answer the client instead of leaving the request
/// to time out — without going back to the bytes to find it.
pub fn decode_inbound(s: &str) -> Result<DapMessage, (InboundFailureIdentity, DapError)> {
    // Not JSON at all: there is no `seq` to recover, and — this is the point
    // — there is no second parse that could have recovered one either.
    let value: Value = match parse_inbound_str(s) {
        Ok(value) => value,
        Err(e) => return Err((InboundFailureIdentity::default(), e.into())),
    };

    match value.get("type").and_then(|v| v.as_str()) {
        Some("request") => request_from_value(value)
            .map(DapMessage::Request)
            .map_err(|(value, e)| (InboundFailureIdentity::from_raw(&value), e)),
        // Responses and events are the client direction, not the worker's hot
        // path, so they keep the generic serde route. The identity has to be
        // taken before the parse consumes the tree; that is one short string
        // per inbound response/event, against a whole extra parse per message
        // before.
        Some("response") => {
            let identity = InboundFailureIdentity::from_raw(&value);
            parse_inbound_value(value)
                .map(DapMessage::Response)
                .map_err(|e| (identity, e.into()))
        }
        Some("event") => {
            let identity = InboundFailureIdentity::from_raw(&value);
            parse_inbound_value(value)
                .map(DapMessage::Event)
                .map_err(|e| (identity, e.into()))
        }
        _ => Err((
            InboundFailureIdentity::from_raw(&value),
            serde_json::Error::custom("Unknown DAP message type").into(),
        )),
    }
}

/// Build a [`Request`] out of a payload that has already been parsed, without
/// handing the tree back to serde.
///
/// This is the second of the three passes #222 is about. `from_value::<Request>`
/// re-walks the whole message and, because `arguments` is itself a `Value`,
/// DEEP-COPIES the entire arguments subtree into a fresh one — for a
/// `setBreakpoints` with a hundred breakpoints, or a `launch` carrying a
/// restore location, that copy is the bulk of the request. `Request` has three
/// members and no `deny_unknown_fields`, so reading them out of the map we
/// already own is the same decode with the copy removed: `arguments` is
/// *moved*.
///
/// The struct literal at the end is the guard against drift — add a member to
/// `Request` and this function stops compiling until it is handled here too.
///
/// On failure the payload is handed back intact, so the caller can still
/// recover the client's `seq`. Nothing is removed from the map until every
/// check has passed, which is what makes that possible.
fn request_from_value(value: Value) -> Result<Request, (Value, DapError)> {
    let invalid = |value: Value, message: String| (value, DapError::from(serde_json::Error::custom(message)));

    let Some(object) = value.as_object() else {
        return Err(invalid(value, "a DAP request must be a JSON object".to_string()));
    };

    // `seq` and `command` are required (no `#[serde(default)]` on either),
    // and `arguments` is `#[serde(default)]`, so an absent one is `Null`.
    let Some(seq) = object.get("seq").and_then(Value::as_i64) else {
        return Err(invalid(
            value,
            "a DAP request needs an integer `seq`; the client's continuation is parked under it".to_string(),
        ));
    };
    if !object.get("command").is_some_and(Value::is_string) {
        return Err(invalid(value, "a DAP request needs a string `command`".to_string()));
    }

    let Value::Object(mut object) = value else {
        unreachable!("checked above that the payload is an object")
    };
    let command = match object.remove("command") {
        Some(Value::String(command)) => command,
        _ => unreachable!("checked above that `command` is a string"),
    };
    let arguments = object.remove("arguments").unwrap_or(Value::Null);

    Ok(Request {
        base: ProtocolMessage {
            seq,
            type_: "request".to_string(),
        },
        command,
        arguments,
    })
}

pub fn from_json(s: &str) -> DapResult<DapMessage> {
    decode_inbound(s).map_err(|(_, e)| e)
}

pub fn to_json(message: &DapMessage) -> DapResult<String> {
    Ok(serde_json::to_string(message)?)
}

#[cfg(feature = "io-transport")]
pub fn read_dap_message_from_reader<R: std::io::BufRead>(reader: &mut R) -> DapResult<DapMessage> {
    use log::info;

    info!("read_dap_message_from_reader");
    let mut header = String::new();
    reader.read_line(&mut header).map_err(|e| {
        use log::error;

        error!("Read Line: {:?}", e);
        serde_json::Error::custom(e.to_string())
    })?;
    info!("line read");
    if !header.to_ascii_lowercase().starts_with("content-length:") {
        // println!("no content-length!");
        return Err(serde_json::Error::custom("Missing Content-Length header").into());
    }
    let len_part = header
        .split(':')
        .nth(1)
        .ok_or_else(|| serde_json::Error::custom("Invalid Content-Length"))?;
    let len: usize = len_part
        .trim()
        .parse::<usize>()
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    let mut blank = String::new();
    reader
        .read_line(&mut blank)
        .map_err(|e| serde_json::Error::custom(e.to_string()))?; // consume blank line
    let mut buf = vec![0u8; len];
    reader
        .read_exact(&mut buf)
        .map_err(|e| serde_json::Error::custom(e.to_string()))?;
    let json_text = std::str::from_utf8(&buf).map_err(|e| serde_json::Error::custom(e.to_string()))?;
    info!("DAP raw <- {json_text}");
    from_json(json_text)
}

/// Answer a message the worker could not decode with a DAP failure response.
///
/// See the call sites in [`setup_onmessage_callback`]: the alternative is
/// `unwrap_throw`, which traps and kills the worker, and a killed worker is
/// indistinguishable from a slow one until every pending request times out.
///
/// `request_seq` and `command` are recovered from the raw JSON when they are
/// there, because that is what lets the client settle the continuation it
/// parked rather than merely learn that something went wrong. They arrive as
/// an [`InboundFailureIdentity`] out of [`decode_inbound`]'s own parse — this
/// function used to be handed the whole payload, which the closure had parsed
/// a second time purely to have it (#222).
#[cfg(feature = "browser-transport")]
fn post_decode_failure(scope: &web_sys::DedicatedWorkerGlobalScope, identity: &InboundFailureIdentity, reason: &str) {
    use wasm_bindgen::JsValue;

    let response = DapMessage::Response(Response {
        base: ProtocolMessage {
            seq: 0,
            type_: "response".to_string(),
        },
        request_seq: identity.request_seq,
        success: false,
        command: identity.command.clone(),
        message: Some(format!("the replay engine could not decode this message: {reason}")),
        body: serde_json::json!({}),
    });
    if let Ok(json) = serde_json::to_string(&response) {
        let _ = scope.post_message(&JsValue::from_str(&json));
    }
    web_sys::console::error_1(&JsValue::from_str(&format!(
        "replay engine: undecodable message rejected: {reason}"
    )));
}

#[cfg(feature = "browser-transport")]
pub fn setup_onmessage_callback() -> Result<(), DapError> {
    use std::rc::Rc;

    use wasm_bindgen::{JsCast, JsValue, prelude::Closure};
    use web_sys::{
        MessageEvent,
        js_sys::{self, Function},
    };

    use crate::dap_server::Ctx;

    let global = js_sys::global();

    let scope: web_sys::DedicatedWorkerGlobalScope = global
        .dyn_into()
        .map_err(|_| wasm_bindgen::JsValue::from_str("Not running inside a DedicatedWorkerGlobalScope"))?;

    // NOTE: This does not have to be wrapped in a lock.
    // This will run in the browser and JS callback code blocks are "critical sections".
    let mut ctx = Ctx::default();

    // The Handler is created lazily when configurationDone triggers VFS-based
    // trace setup. It lives alongside ctx for the lifetime of the worker.
    let mut handler: Option<crate::dap_handler::Handler> = None;

    let t = Rc::new(scope);

    let t_clone = t.clone();

    let callback = Closure::wrap(Box::new(move |event: MessageEvent| {
        use wasm_bindgen::UnwrapThrowExt;
        use web_sys::js_sys::JSON;

        use crate::dap_server::handle_message_browser;

        let dap_message_raw = event.data();

        // A MESSAGE THIS FUNCTION CANNOT READ IS ANSWERED, NOT DROPPED.
        //
        // Both steps below used to end in `unwrap_throw`, which trips
        // wasm32's `unreachable` trap and kills the worker mid-session — the
        // exact failure the comment further down already refuses for a
        // handler error ("would leave the browser replay client hanging on
        // configurationDone"). The decode step above it had no such
        // protection, so a client that mis-shaped one packet got a dead
        // worker and no reply, and every pending request sat unresolved
        // until its timeout with nothing on either side saying why. That
        // cost a full debugging session to diagnose from the outside.
        //
        // It also accepts a STRING as well as an object now, and that is not
        // generosity — it is symmetry with what this same function POSTS.
        // Responses go out as `JsValue::from_str(&json)`, so a client that
        // echoes a frame back, or a transport that normalises everything to
        // text, was sending something `JSON::stringify` would QUOTE rather
        // than decode. One worker should not read one encoding and write
        // another.
        let dap_message_str = match dap_message_raw.as_string() {
            Some(text) => text,
            None => match JSON::stringify(&dap_message_raw).ok().and_then(|s| s.as_string()) {
                Some(text) => text,
                None => {
                    post_decode_failure(
                        &t_clone,
                        &InboundFailureIdentity::default(),
                        "the message is neither a string nor JSON-serialisable",
                    );
                    return;
                }
            },
        };

        // Best-effort `seq` and `command` for the failure response, read from
        // the raw JSON rather than from the decoded message there is none of.
        // A client whose request cannot be decoded still has a continuation
        // parked under that `seq`; answering with it settles the request
        // instead of leaving it to time out.
        //
        // They come back OUT of the decode now. This used to be an
        // unconditional `serde_json::from_str::<Value>` right here — a whole
        // extra parse of every message that arrives, kept only for the rare
        // one that fails, on the one code path in this file that no test in
        // this crate can reach (#222).
        let dap_message = match decode_inbound(&dap_message_str) {
            Ok(message) => message,
            Err((identity, e)) => {
                post_decode_failure(&t_clone, &identity, &format!("{e}"));
                return;
            }
        };

        // Create a channel pair. handle_message_browser sends responses via
        // the Sender. After it returns, we drain the Receiver and post each
        // message to the main thread via the worker scope. This works because
        // WASM is single-threaded, so the drain happens synchronously.
        let (sender, receiver) = std::sync::mpsc::channel::<DapMessage>();

        let handler_result = handle_message_browser(&dap_message, sender, &mut ctx, &mut handler);

        // Drain whatever messages handle_message_browser already produced
        // before failing — e.g. a partial responses sequence — so the
        // main thread sees them in order, then surface the error as a
        // structured DAP failure response instead of unwinding the
        // worker. Panicking here trips wasm32's `unreachable` trap which
        // would kill the worker mid-session and leave the browser
        // replay client hanging on configurationDone.
        while let Ok(msg) = receiver.try_recv() {
            let json = serde_json::to_string(&msg).unwrap_throw();
            t_clone.post_message(&JsValue::from_str(&json)).unwrap_throw();
        }

        if let Err(e) = handler_result {
            let err_text = format!("handle_message_browser failed: {e}");
            web_sys::console::error_1(&JsValue::from_str(&err_text));

            // Build a synthetic error response so the JS side observes a
            // proper DAP failure for whichever request triggered the
            // error.  We default to seq=0 / command="" if the incoming
            // payload was not a Request — events and responses don't
            // expect a reply, so an empty stub is harmless.
            let (request_seq, command) = match &dap_message {
                DapMessage::Request(r) => (r.base.seq, r.command.clone()),
                _ => (0, String::new()),
            };
            let error_response = DapMessage::Response(Response {
                base: ProtocolMessage {
                    seq: 0,
                    type_: "response".to_string(),
                },
                request_seq,
                success: false,
                command,
                message: Some(err_text),
                body: serde_json::json!({}),
            });
            if let Ok(json) = serde_json::to_string(&error_response) {
                let _ = t_clone.post_message(&JsValue::from_str(&json));
            }
        }
    }) as Box<dyn FnMut(_)>)
    .into_js_value()
    .unchecked_into::<Function>();

    t.set_onmessage(Some(&callback));

    Ok(())
}

#[cfg(test)]
mod load_args_tests {
    use super::*;

    /// Stand-in for the request-span argument types: every field
    /// optional, so "no arguments at all" is a legitimate request.
    #[derive(Debug, Default, Deserialize, PartialEq)]
    #[serde(default, rename_all = "camelCase", deny_unknown_fields)]
    struct OptionalArgs {
        limit: Option<i64>,
        method: Option<String>,
    }

    fn request_with(arguments: Value) -> Request {
        Request {
            base: ProtocolMessage {
                seq: 1,
                type_: "request".to_string(),
            },
            command: "ct/load-request-spans".to_string(),
            arguments,
        }
    }

    #[test]
    fn absent_arguments_yield_the_default_request() {
        // `Request::arguments` is `#[serde(default)]`, so a request with
        // no `arguments` member at all arrives as `Value::Null`.  This is
        // the ONE case that may fall back to the default.
        let req = request_with(Value::Null);
        assert_eq!(
            req.load_args_or_default::<OptionalArgs>().map_err(|e| e.to_string()),
            Ok(OptionalArgs::default())
        );
    }

    #[test]
    fn well_formed_arguments_are_parsed() {
        let req = request_with(serde_json::json!({ "limit": 5, "method": "GET" }));
        assert_eq!(
            req.load_args_or_default::<OptionalArgs>().map_err(|e| e.to_string()),
            Ok(OptionalArgs {
                limit: Some(5),
                method: Some("GET".to_string()),
            })
        );
    }

    #[test]
    fn malformed_arguments_are_an_error_not_the_default_request() {
        // The defect this replaces: `load_args().unwrap_or_default()`
        // could not tell "nothing was sent" from "something broken was
        // sent", so a wrong-typed filter became the default request —
        // for `ct/load-request-spans` that default is "no filters, no
        // paging", i.e. the entire recording, reported as success.
        let req = request_with(serde_json::json!({ "limit": "not a number" }));
        assert!(
            req.load_args_or_default::<OptionalArgs>().is_err(),
            "a malformed argument must surface as a parse error, not silently widen the query"
        );
    }

    #[test]
    fn unknown_field_is_an_error_not_the_default_request() {
        // Guards the interaction with `deny_unknown_fields`: once the
        // argument types deny unknown fields, `unwrap_or_default` would
        // have converted every client typo into a full-recording scan.
        let req = request_with(serde_json::json!({ "limitt": 5 }));
        assert!(
            req.load_args_or_default::<OptionalArgs>().is_err(),
            "a misspelled argument must not be downgraded into the default request"
        );
    }

    #[test]
    fn real_load_request_spans_arguments_reject_a_malformed_filter() {
        // Binds the fix to the actual type behind `ct/load-request-spans`,
        // not just the stand-in above.
        let req = request_with(serde_json::json!({ "limit": "twenty" }));
        assert!(
            req.load_args_or_default::<crate::request_spans::LoadRequestSpansArguments>()
                .is_err(),
            "a malformed `limit` must not be answered with the whole span stream"
        );
        // ...while a genuinely empty request still works.
        assert!(
            request_with(Value::Null)
                .load_args_or_default::<crate::request_spans::LoadRequestSpansArguments>()
                .is_ok(),
            "a request with no arguments at all is a valid 'give me everything'"
        );
    }
}
