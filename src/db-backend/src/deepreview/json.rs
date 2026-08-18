//! The `review.json` dataset shape, as the CodeTracer GUI reads it.
//!
//! # Which shape is authoritative
//!
//! There are two producers and one consumer:
//!
//! * `codetracer-native-backend/src/deepreview/json_export.rs` — the rr/native
//!   collector's `DeepReviewData`;
//! * this module — the materialized (CTFS) collector, added by RV-4;
//! * `codetracer/src/common/common_types/codetracer_features/deepreview.nim` —
//!   the GUI-side type, reached by `cast[DeepReviewData](JSON.parse(...))` in
//!   `src/frontend/index/args.nim`.
//!
//! The two producers are **not** the same shape, and the GUI type is the
//! superset of both: it additionally declares `sessionTitle`,
//! `traceContexts`, `files[].sourceContent` and `files[].diff`, none of which
//! the native exporter writes.  RV-4's deliverable asks for output "the GUI
//! reader accepts", so this module is written against the *consumer*: it fills
//! every field the materialized path can honestly fill, including the four the
//! native exporter leaves out, and leaves the rest empty rather than zeroed.
//!
//! # What is deliberately left empty
//!
//! Recorded here as well as in the milestone, because an empty field that
//! nobody explains reads as a bug:
//!
//! * `SymbolData.type_desc` / `SymbolData.visibility` — a materialized trace
//!   records the functions that ran, not their declared type or their
//!   visibility.  Both are emitted as `""`, never as a plausible-looking
//!   `"private"`.
//! * `LineCoverageData.unreachable` — a trace can say a line was *not
//!   observed*; it cannot say the line is unreachable.  Always `false`, which
//!   is what "not determined unreachable" means in the native shape too.
//! * Test results — the GUI type documents this gap already (see its header);
//!   neither collector carries a test-result field, so there is nothing to
//!   fill and nothing is invented.
//!
//! # Field names
//!
//! `#[serde(rename_all = "camelCase")]` throughout, matching the native
//! exporter and the Nim field names one-for-one, so the GUI's `cast` over
//! `JSON.parse` works with no mapping layer.

use serde::{Deserialize, Serialize};

/// Complete DeepReview dataset in JSON-serializable form.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeepReviewData {
    /// Git commit SHA of the reviewed code, or `""` when the collection was
    /// given a patch file rather than a repository and therefore knows no
    /// commit.  Empty, not a run of zeros: a zeroed SHA is a real value in
    /// git (the null object) and would read as one.
    pub commit_sha: String,
    /// Base commit SHA for the diff, under the same rule as `commit_sha`.
    pub base_commit_sha: String,
    /// How long data collection took, in milliseconds.
    pub collection_time_ms: u64,
    /// Number of recordings actually collected from.
    pub recording_count: u32,
    /// Human-readable session title shown in the review header.  Empty unless
    /// the caller supplied one — the collector does not invent a title.
    pub session_title: String,
    /// One entry per collected recording, so the reviewer can tell which run
    /// the overlay belongs to.  The native exporter emits none; a materialized
    /// collection knows its recordings by name and can.
    pub trace_contexts: Vec<TraceContextData>,
    /// Files with DeepReview data.
    pub files: Vec<FileData>,
    /// Call trace tree (absent when no call tree was collected).
    pub call_trace: Option<CallTraceData>,
    /// RV-6 — the agent session this dataset came from, when the collecting
    /// environment identified one.
    ///
    /// `#[serde(default)]` because absence is the normal case, not an error:
    /// a dataset collected by a human names no session, and the native
    /// exporter in `codetracer-native-backend` does not write the field at
    /// all.  `skip_serializing_if` keeps it out of those datasets entirely
    /// rather than writing `"session": null`, so a reader cannot mistake an
    /// explicit null for a reference it failed to parse.
    ///
    /// The field is a **reference**: an id plus what is needed to resolve it,
    /// never a copy of the conversation.  `ct review collect` is what stamps
    /// it (it is the one process that sees the agent's environment, and it is
    /// the single path both collectors go through), so nothing in this crate
    /// populates it today — but the type carries it so a dataset that already
    /// has one survives a round-trip through here instead of being silently
    /// dropped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<SessionRefData>,
}

/// A pointer at the agent session that produced a dataset.
///
/// Mirrors `DeepReviewSessionRef` in
/// `src/common/common_types/codetracer_features/deepreview.nim` field for
/// field; see that type for why a review references a session rather than
/// embedding its transcript.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionRefData {
    /// The backend's own id for the session.
    pub session_id: String,
    /// `"acp"` or `"harbor"`.
    pub backend: String,
    /// The directory the session ran in.
    #[serde(default)]
    pub workspace_path: String,
    /// Agent Harbor's task id, when the session belongs to one.
    #[serde(default)]
    pub task_id: String,
    /// For `"acp"`: the stdio ACP binary that can replay the session.
    #[serde(default)]
    pub agent_command: String,
    /// Arguments for `agent_command`.
    #[serde(default)]
    pub agent_args: Vec<String>,
    /// For `"harbor"`: base URL of the instance holding the session.
    #[serde(default)]
    pub endpoint: String,
}

/// A selectable trace context — one recording of the reviewed change.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TraceContextData {
    /// Index of the recording within this dataset, starting at 0.
    pub id: u32,
    /// Display label; the recording directory's name.
    pub label: String,
    /// The recording's canonical id when the directory name is one (recordings
    /// live under `<id>/` in CodeTracer's own store), `""` otherwise.  Not
    /// guessed from anything else.
    pub recording_id: String,
}

/// Per-file DeepReview data.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileData {
    /// Path as the diff names it — repository-relative.
    pub path: String,
    /// SHA-256 of the file content the review shows, hex-encoded, or `""`
    /// when the content could not be read.
    pub content_hash: String,
    /// Full source text of the file, or `""` when it could not be read.
    pub source_content: String,
    /// The file's diff, from the patch the collection was given.
    pub diff: FileDiffData,
    /// Symbols in this file.
    pub symbols: Vec<SymbolData>,
    /// Line coverage data.
    pub coverage: Vec<LineCoverageData>,
    /// Function-level coverage.
    pub functions: Vec<FunctionCoverageData>,
    /// Loop information.
    pub loops: Vec<LoopData>,
    /// Flow data per function execution.
    pub flow: Vec<FunctionFlowData>,
    /// File flags.
    pub flags: FileFlags,
}

/// Diff metadata for one file of the review.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileDiffData {
    /// `"A"` (added), `"M"` (modified), `"D"` (deleted) or `"R"` (renamed).
    pub status: String,
    pub lines_added: u32,
    pub lines_removed: u32,
    pub hunks: Vec<HunkData>,
}

/// One contiguous hunk of a file's diff.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HunkData {
    pub old_start: u32,
    pub old_count: u32,
    pub new_start: u32,
    pub new_count: u32,
    pub lines: Vec<HunkLineData>,
}

/// One line of one hunk.  `type` is `"context"`, `"added"` or `"removed"`,
/// the spelling `ui/unified_diff.nim` and `ui/editor.nim` switch on.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HunkLineData {
    #[serde(rename = "type")]
    pub line_type: String,
    pub content: String,
    /// Line number on the base side, or 0 for an added line.
    pub old_line: u32,
    /// Line number on the new side, or 0 for a removed line.
    pub new_line: u32,
}

/// Flags describing the state of a file in the diff.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileFlags {
    pub has_symbols: bool,
    pub has_coverage: bool,
    pub has_flow: bool,
    /// No recording executed any line of this file.
    pub is_unreachable: bool,
    /// Some, but not all, collected recordings covered this file.
    pub is_partial: bool,
}

/// A symbol in a source file.  Only functions the recordings actually entered
/// are listed; see the module header for why `type_desc` and `visibility` are
/// empty.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SymbolData {
    pub name: String,
    pub type_desc: String,
    pub kind: String,
    pub visibility: String,
    pub start_line: u32,
    /// Last line of the symbol, or 0 when the recording's source could not be
    /// parsed for a range.  Source lines are 1-based, so 0 is "not known"
    /// rather than a line — the same convention `loop_id: -1` uses.
    pub end_line: u32,
}

/// Coverage information for a single source line.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LineCoverageData {
    pub line: u32,
    /// Times the line was executed across all collected recordings.
    pub execution_count: u32,
    /// Recorded samples for the line.  A materialized trace records *every*
    /// step, so this is the same number as `execution_count` rather than a
    /// sampled subset of it; it is emitted for shape compatibility with the
    /// native exporter, which samples.
    pub sample_count: u32,
    pub executed: bool,
    /// Always `false`: see the module header.
    pub unreachable: bool,
    /// The line was executed in some collected recordings and not others.
    pub partial: bool,
}

/// Function-level coverage summary.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FunctionCoverageData {
    pub name: String,
    pub start_line: u32,
    /// 0 when not known; see [`SymbolData::end_line`].
    pub end_line: u32,
    /// Calls to this function across all collected recordings.
    pub call_count: u32,
    /// Calls for which flow was collected (bounded — see the collector's
    /// `max_flows_per_function`).
    pub execution_count: u32,
}

/// A loop observed inside a collected function execution.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LoopData {
    pub loop_id: u32,
    pub header_line: u32,
    pub start_line: u32,
    pub end_line: u32,
    pub total_iterations: u32,
}

/// Flow data for a single function execution.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FunctionFlowData {
    /// The function's name, as the trace records it.
    pub function_key: String,
    /// 0-based index of this execution among the collected executions of the
    /// same function.
    pub execution_index: u32,
    pub steps: Vec<FlowStepData>,
}

/// A single step in a function's execution flow.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FlowStepData {
    pub line: u32,
    /// Index of the step within this execution.
    pub step_count: u32,
    /// The trace position this step is at.  Named `rrTicks` because the field
    /// is shared with the rr collector; on a materialized trace it carries the
    /// `StepId`, which is exactly what `task::FlowEvent` documents for the
    /// db-backend ("rr ticks for the system backend and step id for
    /// db-backend").
    pub rr_ticks: i64,
    /// -1 when the step is not inside a loop.
    pub loop_id: i32,
    /// -1 when the step is not inside a loop, mirroring `loop_id`'s sentinel.
    pub iteration: i64,
    pub values: Vec<VariableValueData>,
}

/// A variable's value at a specific execution step.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VariableValueData {
    pub name: String,
    /// Rendered by `value::Value::text_repr`, the same rendering the debugger
    /// shows.
    pub value: String,
    /// The value's language type when the trace recorded one, `""` otherwise.
    pub kind: String,
    /// Whether the rendering above was cut short by the value length cap.
    pub truncated: bool,
}

/// Call trace tree structure.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CallTraceData {
    pub nodes: Vec<CallNodeData>,
}

/// A single node in the call trace tree.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CallNodeData {
    pub name: String,
    /// Always 1: one node is one invocation.  The native exporter documents
    /// the same ("always 1 per node; included for GUI compatibility").
    pub execution_count: u32,
    pub children: Vec<CallNodeData>,
}
