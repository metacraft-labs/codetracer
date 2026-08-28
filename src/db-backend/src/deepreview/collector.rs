//! Assemble a `DeepReviewData` dataset from materialized (CTFS) recordings.
//!
//! `DeepReview-GUI.md` §1.1: "DeepReview is **not** an rr-only feature. Every
//! language that produces a materialized trace — Python, Ruby, JavaScript,
//! Noir, and the rest — must be reviewable, and the db-backend already holds
//! the ingredients."  This module is the assembly step; it computes nothing
//! new.
//!
//! | Ingredient | Where it comes from |
//! |---|---|
//! | line coverage | `Db::steps` — every recorded step's `(path, line)` |
//! | per-invocation flow, with values and loops | `flow_preloader::FlowPreloader::load`, `FlowMode::Call` |
//! | the call tree | `Db::calls` / `Db::functions` |
//! | the diff | the patch the caller supplied, read by [`super::unified_diff`] |
//!
//! # Why `FlowMode::Call` and not `FlowMode::Diff`
//!
//! `FlowPreloader::load_diff_flow` exists and looks like the obvious entry
//! point — it takes the diff's lines directly.  It cannot be used: its
//! step walker (`CallFlowPreloader::next_diff_flow_step`) is an unimplemented
//! `todo!()` and panics on the first call, so `FlowMode::Diff` has never
//! produced a flow for anything.  (`diff::index_diff`, its only caller,
//! panics for the same reason.)
//!
//! `FlowMode::Call` is the mode the debugger itself uses on every move, so it
//! is the one that is exercised and trusted.  The collector therefore does the
//! diff-scoping itself — find the calls whose steps land on the diff's lines,
//! then ask for each of those calls' flow — which yields exactly what
//! `DeepReviewFunctionFlow` is defined as: "a single execution trace of a
//! function (one call/invocation)".
//!
//! # What "the diff's calls" includes, and what it does not
//!
//! A call is anchored when one of ITS OWN steps lands on a line the diff
//! touched.  So a function the diff changed gets flow, and a function the diff
//! merely *calls* does not — `let x = helper(y)` on an added line gets flow for
//! the caller, and `helper` gets coverage and a call count but no flow, because
//! none of `helper`'s lines changed.  That is a deliberate scoping decision and
//! not an oversight: a review is about the lines that changed, and following
//! callees would pull an arbitrary depth of untouched code into the dataset.
//! It is recorded in RV-4's milestone entry as a limitation so a reviewer who
//! expects the callee's overlay knows why it is absent.
//!
//! # Why the anchor step is the LAST diff-line step of a call
//!
//! `CallFlowPreloader::load_flow` widens any exact step to the enclosing
//! call's entry, so *which* step of the call is passed does not change the
//! window — except at step 0.  A location with `rrTicks == 0`, `event == 0`
//! and a line trips `should_seek_materialized_call_body_from_line_only_location`,
//! which treats the request as line-only, sets a breakpoint on the line and
//! continues to it; if the line's only occurrence *is* step 0 the breakpoint
//! is never hit and the flow comes back empty.  Anchoring at the last matching
//! step keeps the request off that path for every call that has more than one
//! step, which is every call worth reviewing.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::error::Error;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use codetracer_trace_types::{CallKey, NO_KEY, StepId};
use log::{info, warn};
use sha2::{Digest, Sha256};

use crate::db::MaterializedReplaySession;
use crate::expr_loader::ExprLoader;
use crate::flow_preloader::FlowPreloader;
use crate::in_memory_trace_reader::InMemoryTraceReader;
use crate::materialized_source::open_materialized_trace;
use crate::task::{CoreTrace, FlowMode, FlowViewUpdate, RRTicks, TraceKind};
use crate::trace_reader::TraceReader;

use super::json::{
    CallNodeData, CallTraceData, DeepReviewData, FileData, FileFlags, FlowStepData, FunctionCoverageData,
    FunctionFlowData, LineCoverageData, LoopData, SymbolData, TraceContextData, VariableValueData,
};
use super::unified_diff::ParsedDiff;

/// Everything a collection needs that is not in the recordings themselves.
#[derive(Debug, Clone)]
pub struct CollectOptions {
    /// Recording directories, in the order they were found.
    pub recordings: Vec<PathBuf>,
    /// The parsed patch the review is over.
    pub diff: ParsedDiff,
    /// Repository root, when the caller named one.  Used to resolve the
    /// patch's relative paths against the recordings' absolute ones and to
    /// read the reviewed source.
    pub repo_root: Option<PathBuf>,
    /// Commit the review is of, or `""` when unknown.
    pub commit_sha: String,
    /// Commit the review is against, or `""` when unknown.
    pub base_commit_sha: String,
    /// Display title, or `""`; never invented.
    pub session_title: String,
    /// At most this many executions of one function get flow, per recording.
    /// A hot helper called ten thousand times would otherwise make the dataset
    /// unopenable.
    pub max_flows_per_function: usize,
    /// Upper bound on call-tree nodes.  The tree is written breadth-first and
    /// truncated at this many nodes; truncation is reported, never silent.
    pub max_call_nodes: usize,
    /// Rendered values longer than this are cut and marked `truncated`.
    pub max_value_chars: usize,
    /// Emit JSON Lines progress events on stderr, in the same shape the native
    /// collector emits (`deepreview/progress.rs`), so a CI consumer does not
    /// have to know which collector ran.
    pub progress: bool,
}

impl Default for CollectOptions {
    fn default() -> Self {
        CollectOptions {
            recordings: vec![],
            diff: ParsedDiff::default(),
            repo_root: None,
            commit_sha: String::new(),
            base_commit_sha: String::new(),
            session_title: String::new(),
            max_flows_per_function: 16,
            max_call_nodes: 20_000,
            max_value_chars: 256,
            progress: true,
        }
    }
}

/// What a collection found, beside the dataset itself — reported to the user
/// so an empty dataset is never mistaken for a healthy one.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CollectReport {
    pub recordings_collected: usize,
    pub recordings_failed: Vec<(PathBuf, String)>,
    pub files_in_diff: usize,
    pub files_with_coverage: usize,
    pub files_with_flow: usize,
    pub flow_executions: usize,
    pub call_tree_truncated: bool,
}

/// Per-file accumulation across all recordings of one collection.
#[derive(Debug, Default)]
struct FileAcc {
    /// line -> total executions across recordings
    coverage: BTreeMap<u32, u32>,
    /// line -> how many recordings executed it
    recordings_per_line: BTreeMap<u32, usize>,
    /// how many recordings executed anything in this file
    recordings_touching: usize,
    /// function name -> (start, end, calls, flows)
    functions: BTreeMap<String, FunctionAcc>,
    /// (first, last) -> loop record, deduplicated across executions
    loops: BTreeMap<(u32, u32), LoopData>,
    flow: Vec<FunctionFlowData>,
}

#[derive(Debug, Default, Clone)]
struct FunctionAcc {
    start_line: u32,
    end_line: u32,
    call_count: u32,
    execution_count: u32,
}

/// Emit one JSON Lines progress event on stderr.
///
/// I/O failures are ignored deliberately: progress reporting must never be the
/// reason a collection fails.
fn emit_progress(enabled: bool, event: serde_json::Value) {
    if !enabled {
        return;
    }
    if let Ok(line) = serde_json::to_string(&event) {
        let _ = writeln!(std::io::stderr(), "{line}");
    }
}

/// Resolve a trace-recorded path to an absolute one.
fn absolute_trace_path(raw: &str, workdir: &Path) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        workdir.join(path)
    }
}

/// Match an absolute path from a recording against the review's file list.
///
/// The patch names files the way git does — repository-relative — while a
/// trace records whatever absolute path the program ran from, and the two need
/// not share a prefix (a recording made in a container, a checkout at a
/// different root).  Matching is therefore by path *suffix*, on whole
/// components, and the longest match wins so that `src/a/main.rs` is not
/// claimed by a review file called `main.rs`.
fn match_review_file(absolute: &Path, review_paths: &[String]) -> Option<usize> {
    let text = absolute.to_string_lossy().replace('\\', "/");
    let mut best: Option<(usize, usize)> = None;
    for (index, candidate) in review_paths.iter().enumerate() {
        let normalized = candidate.replace('\\', "/");
        if normalized.is_empty() {
            continue;
        }
        let matches = text == normalized || text.ends_with(&format!("/{normalized}"));
        if matches {
            let length = normalized.len();
            if best.is_none_or(|(_, best_len)| length > best_len) {
                best = Some((index, length));
            }
        }
    }
    best.map(|(index, _)| index)
}

/// The reviewed source of one file, and its hash.
///
/// Read from the working tree first (that is what the review is *of*), then
/// from the recording's own `files/` copy, which is what the program actually
/// executed.  When neither is readable both fields stay empty rather than
/// being filled with a placeholder.
fn read_source(repo_root: Option<&Path>, review_path: &str, recorded: Option<&Path>) -> (String, String) {
    let mut text: Option<String> = None;
    if let Some(root) = repo_root {
        text = std::fs::read_to_string(root.join(review_path)).ok();
    }
    if text.is_none()
        && let Some(path) = recorded
    {
        text = std::fs::read_to_string(path).ok();
    }
    match text {
        Some(source) => {
            let digest = Sha256::digest(source.as_bytes());
            let hash = digest.iter().map(|b| format!("{:02x}", b)).collect::<String>();
            (source, hash)
        }
        None => (String::new(), String::new()),
    }
}

/// Where a recording keeps its copy of `absolute`, if it kept one.
fn recorded_source_path(recording: &Path, absolute: &Path) -> Option<PathBuf> {
    let text = absolute.to_string_lossy().replace('\\', "/");
    let relative = text.trim_start_matches('/');
    let candidate = recording.join("files").join(relative);
    candidate.is_file().then_some(candidate)
}

/// A recording directory's name doubles as its recording id in CodeTracer's
/// own store (`~/.local/share/codetracer/<id>/`).  Report it as one only when
/// it actually is a UUID; anything else is a folder someone named.
fn recording_id_of(recording: &Path) -> String {
    let name = recording
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let is_uuid = name.len() == 36
        && name.chars().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == '-'
            } else {
                c.is_ascii_hexdigit()
            }
        });
    if is_uuid { name } else { String::new() }
}

/// The structure caps `max_value_chars` becomes once a value is carried as
/// structure rather than as a rendering (UD-3, restating RV-9's fourth
/// deliverable).
///
/// A rendered value is bounded by its own length; a structured one is bounded
/// by how deep and how wide it is allowed to be, and a dataset that did not
/// bound it would grow without limit on the first recursive data structure it
/// met. The two caps are derived from the same knob the `--preset` scaling
/// already moves, so a preset that asks for shorter values also asks for
/// shallower ones and there is still one dial rather than three.
fn structure_caps(max_value_chars: usize) -> (usize, usize) {
    // The default `max_value_chars` is in the low hundreds, so the depth lands
    // at 3-4 and the breadth at 32-64: deep enough for a struct of structs and
    // wide enough for a short vector, which is what a reviewer looks at.
    let depth = (max_value_chars / 64).clamp(2, 8);
    let breadth = (max_value_chars / 4).clamp(8, 256);
    (depth, breadth)
}

/// A copy of `value` cut to the structure caps.
///
/// Cutting rather than refusing: a value too deep or too wide keeps everything
/// above the cut, so a reviewer sees the shape and the first elements instead
/// of nothing. What is dropped is dropped silently at the leaves, which is the
/// same bargain `text_repr`'s length cap already makes — and unlike that cap,
/// the part that survives is still structure and can still be expanded.
fn pruned_value(value: &crate::value::Value, max_value_chars: usize) -> crate::value::Value {
    let (depth, breadth) = structure_caps(max_value_chars);
    prune_to(value, depth, breadth)
}

fn prune_to(value: &crate::value::Value, depth: usize, breadth: usize) -> crate::value::Value {
    let mut copy = value.clone();
    if depth == 0 {
        // At the cut: keep the scalar fields and the type, drop what hangs off
        // them. The type is what makes a cut value still render as the right
        // KIND of thing rather than as an empty one.
        copy.elements = vec![];
        copy.ref_value = None;
        copy.active_variant_value = None;
        return copy;
    }
    copy.elements = value
        .elements
        .iter()
        .take(breadth)
        .map(|element| prune_to(element, depth - 1, breadth))
        .collect();
    copy.ref_value = value
        .ref_value
        .as_ref()
        .map(|inner| Box::new(prune_to(inner, depth - 1, breadth)));
    copy.active_variant_value = value
        .active_variant_value
        .as_ref()
        .map(|inner| Box::new(prune_to(inner, depth - 1, breadth)));
    copy
}

/// Convert one `FlowViewUpdate` into the review's per-execution flow record.
fn convert_flow(
    view: &FlowViewUpdate,
    function_key: &str,
    execution_index: u32,
    max_value_chars: usize,
) -> FunctionFlowData {
    let mut steps = Vec::with_capacity(view.steps.len());
    for step in &view.steps {
        // `expr_order` is the order the debugger renders the annotations in;
        // following it keeps a review's inline values in the same order as the
        // editor's, and it is also the only place a name appears exactly once.
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut values = vec![];
        for name in &step.expr_order {
            if !seen.insert(name.as_str()) {
                continue;
            }
            // The after-value is what the editor annotates a line with; the
            // before-value is the fallback for a name the step only read.
            let Some(value) = step.after_values.get(name).or_else(|| step.before_values.get(name)) else {
                continue;
            };
            let rendered = value.text_repr();
            let truncated = rendered.chars().count() > max_value_chars;
            let rendered = if truncated {
                rendered.chars().take(max_value_chars).collect::<String>()
            } else {
                rendered
            };
            values.push(VariableValueData {
                name: name.clone(),
                value: rendered,
                kind: value.typ.lang_type.clone(),
                truncated,
                // UD-3: the structure the debugger itself holds, alongside the
                // rendering, instead of the rendering alone. This is where RV-5
                // recorded the loss ("the materialized collector *has* the
                // structured value and discards it") and it is a serialization
                // change, not a new capability: `value` is already the type the
                // frontend receives for an ordinary debugging session.
                structured: Some(pruned_value(value, max_value_chars)),
            });
        }
        steps.push(FlowStepData {
            line: step.position.0.max(0) as u32,
            step_count: step.step_count.0.max(0) as u32,
            rr_ticks: step.rr_ticks.0,
            loop_id: step.r#loop.0 as i32,
            iteration: step.iteration.0,
            values,
        });
    }
    FunctionFlowData {
        function_key: function_key.to_string(),
        execution_index,
        steps,
    }
}

/// Record the loops one execution observed.
///
/// `FlowViewUpdate.loops[0]` is `Loop::default()` — a sentinel with
/// `first`/`last` at `NO_POSITION` that every view update carries whether or
/// not the function has a loop — so it is skipped rather than exported as a
/// loop spanning line -1.
fn record_loops(acc: &mut FileAcc, view: &FlowViewUpdate) {
    for (index, entry) in view.loops.iter().enumerate() {
        if entry.first.0 < 0 || entry.last.0 < 0 {
            continue;
        }
        let key = (entry.first.0 as u32, entry.last.0 as u32);
        let header = if entry.registered_line.0 > 0 {
            entry.registered_line.0 as u32
        } else {
            key.0
        };
        let record = acc.loops.entry(key).or_insert(LoopData {
            loop_id: index as u32,
            header_line: header,
            start_line: key.0,
            end_line: key.1,
            total_iterations: 0,
        });
        // Several executions of the same function share one loop; the review
        // reports the total across them.
        record.total_iterations += entry.iteration.0.max(0) as u32;
    }
}

/// Build the call tree of one recording, breadth-first, up to `budget` nodes.
///
/// Returns the roots and whether the budget cut the tree short.  Breadth-first
/// so that a truncated tree is the *top* of the program's call structure —
/// which is the part a reviewer reads — rather than one arbitrarily deep spine.
fn build_call_tree(reader: &dyn TraceReader, budget: usize) -> (Vec<CallNodeData>, bool) {
    if budget == 0 || reader.call_count() == 0 {
        return (vec![], false);
    }
    let name_of = |key: CallKey| -> String {
        reader
            .call(key)
            .and_then(|call| reader.function(call.function_id))
            .map(|function| function.name.clone())
            .unwrap_or_default()
    };

    // Collect the roots first: a call with no parent, plus (defensively) any
    // call whose parent key does not resolve, so a damaged tree still exports
    // its calls rather than nothing.
    let mut roots: Vec<CallKey> = vec![];
    for index in 0..reader.call_count() {
        let key = CallKey(index as i64);
        let Some(call) = reader.call(key) else { continue };
        if call.parent_key == NO_KEY || reader.call(call.parent_key).is_none() {
            roots.push(key);
        }
    }

    let mut nodes: Vec<CallNodeData> = vec![];
    let mut spent = 0usize;
    let mut truncated = false;
    // (call key, path of indices into the tree being built)
    let mut queue: std::collections::VecDeque<(CallKey, Vec<usize>)> = std::collections::VecDeque::new();
    for key in roots {
        if spent >= budget {
            truncated = true;
            break;
        }
        spent += 1;
        nodes.push(CallNodeData {
            name: name_of(key),
            execution_count: 1,
            children: vec![],
        });
        queue.push_back((key, vec![nodes.len() - 1]));
    }

    while let Some((key, path)) = queue.pop_front() {
        let children: Vec<CallKey> = reader
            .call(key)
            .map(|call| call.children_keys.clone())
            .unwrap_or_default();
        for child in children {
            if spent >= budget {
                truncated = true;
                break;
            }
            spent += 1;
            // Walk down to the parent node the path names.
            let mut cursor = &mut nodes[path[0]];
            for index in &path[1..] {
                cursor = &mut cursor.children[*index];
            }
            cursor.children.push(CallNodeData {
                name: name_of(child),
                execution_count: 1,
                children: vec![],
            });
            let mut child_path = path.clone();
            child_path.push(cursor.children.len() - 1);
            queue.push_back((child, child_path));
        }
        if truncated {
            break;
        }
    }

    (nodes, truncated)
}

/// Collect a review dataset from materialized recordings.
///
/// A recording that cannot be opened or read is recorded in the report and
/// skipped, not fatal: a review over five recordings should not be lost
/// because the third is corrupt.  The caller decides what to do when *every*
/// recording failed.
pub fn collect(options: &CollectOptions) -> Result<(DeepReviewData, CollectReport), Box<dyn Error>> {
    // `crate::wall_clock`, not `Instant::now()` — this module is compiled
    // into the wasm build, where `Instant::now()` traps.
    let started_ms = crate::wall_clock::monotonic_ms();
    let mut report = CollectReport {
        files_in_diff: options.diff.files.len(),
        ..CollectReport::default()
    };

    let review_paths: Vec<String> = options.diff.files.iter().map(|f| f.review_path().to_string()).collect();
    let mut accumulators: Vec<FileAcc> = (0..review_paths.len()).map(|_| FileAcc::default()).collect();
    // Where each file's source was found in a recording, so the source text can
    // fall back to the recorded copy when the working tree has moved on.
    let mut recorded_sources: Vec<Option<PathBuf>> = vec![None; review_paths.len()];
    let mut trace_contexts: Vec<TraceContextData> = vec![];
    let mut call_nodes: Vec<CallNodeData> = vec![];

    emit_progress(
        options.progress,
        serde_json::json!({
            "type": "collection_started",
            "recordingCount": options.recordings.len(),
            "fileCount": review_paths.len(),
        }),
    );

    for (recording_index, recording) in options.recordings.iter().enumerate() {
        emit_progress(
            options.progress,
            serde_json::json!({
                "type": "recording_progress",
                "recordingIndex": recording_index,
                "recordingTotal": options.recordings.len(),
                "percentage": if options.recordings.is_empty() {
                    0.0
                } else {
                    (recording_index as f64) * 100.0 / (options.recordings.len() as f64)
                },
            }),
        );

        match collect_one(
            recording,
            options,
            &review_paths,
            &mut accumulators,
            &mut recorded_sources,
            &mut call_nodes,
            &mut report,
        ) {
            Ok(()) => {
                trace_contexts.push(TraceContextData {
                    id: trace_contexts.len() as u32,
                    label: recording
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| recording.display().to_string()),
                    recording_id: recording_id_of(recording),
                });
                report.recordings_collected += 1;
            }
            Err(error) => {
                warn!("deepreview: skipping {}: {error}", recording.display());
                report.recordings_failed.push((recording.clone(), error.to_string()));
            }
        }
    }

    // ---- turn the accumulators into the dataset -------------------------
    let collected = report.recordings_collected;
    let mut files = Vec::with_capacity(review_paths.len());
    for (index, parsed) in options.diff.files.iter().enumerate() {
        let acc = &accumulators[index];
        let review_path = &review_paths[index];
        let (source_content, content_hash) = read_source(
            options.repo_root.as_deref(),
            review_path,
            recorded_sources[index].as_deref(),
        );

        let coverage: Vec<LineCoverageData> = acc
            .coverage
            .iter()
            .map(|(line, count)| {
                let in_recordings = acc.recordings_per_line.get(line).copied().unwrap_or(0);
                LineCoverageData {
                    line: *line,
                    execution_count: *count,
                    // A materialized trace records every step, so the number of
                    // recorded samples for a line IS its execution count.
                    sample_count: *count,
                    executed: *count > 0,
                    // A trace can say "not observed"; it cannot say
                    // "unreachable".  See the json module header.
                    unreachable: false,
                    partial: collected > 1 && in_recordings > 0 && in_recordings < collected,
                }
            })
            .collect();

        let mut symbols = vec![];
        let mut functions = vec![];
        for (name, function) in &acc.functions {
            symbols.push(SymbolData {
                name: name.clone(),
                // A materialized trace records that a function ran, not its
                // declared type or visibility.  Empty, not guessed.
                type_desc: String::new(),
                kind: "function".to_string(),
                visibility: String::new(),
                start_line: function.start_line,
                end_line: function.end_line,
            });
            functions.push(FunctionCoverageData {
                name: name.clone(),
                start_line: function.start_line,
                end_line: function.end_line,
                call_count: function.call_count,
                execution_count: function.execution_count,
            });
        }

        let has_coverage = !coverage.is_empty();
        let has_flow = !acc.flow.is_empty();
        if has_coverage {
            report.files_with_coverage += 1;
        }
        if has_flow {
            report.files_with_flow += 1;
        }
        report.flow_executions += acc.flow.len();

        emit_progress(
            options.progress,
            serde_json::json!({
                "type": "file_collected",
                "path": review_path,
                "symbols": symbols.len(),
                "coverageLines": coverage.len(),
                "flowSteps": acc.flow.iter().map(|f| f.steps.len()).sum::<usize>(),
            }),
        );

        files.push(FileData {
            path: review_path.clone(),
            content_hash,
            source_content,
            diff: parsed.diff.clone(),
            symbols,
            coverage,
            functions,
            loops: acc.loops.values().cloned().collect(),
            flow: acc.flow.clone(),
            flags: FileFlags {
                has_symbols: !acc.functions.is_empty(),
                has_coverage,
                has_flow,
                // A file no recording executed a line of.  A file the patch
                // only deletes is unreachable by construction, and saying so
                // is accurate.
                is_unreachable: !has_coverage,
                is_partial: collected > 1 && acc.recordings_touching > 0 && acc.recordings_touching < collected,
            },
        });
    }

    let elapsed = crate::wall_clock::monotonic_ms().saturating_sub(started_ms);
    emit_progress(
        options.progress,
        serde_json::json!({
            "type": "collection_completed",
            "elapsedMs": elapsed,
            "fileCount": files.len(),
            "totalFlowSteps": files.iter().flat_map(|f| f.flow.iter()).map(|f| f.steps.len()).sum::<usize>(),
        }),
    );

    let data = DeepReviewData {
        commit_sha: options.commit_sha.clone(),
        base_commit_sha: options.base_commit_sha.clone(),
        collection_time_ms: elapsed,
        recording_count: report.recordings_collected as u32,
        session_title: options.session_title.clone(),
        trace_contexts,
        files,
        call_trace: if call_nodes.is_empty() {
            None
        } else {
            Some(CallTraceData { nodes: call_nodes })
        },
        // RV-6: the collector knows nothing about agent sessions, and should
        // not.  The reference is a fact about the *environment the collection
        // ran in*, which only `ct review collect` sees; it stamps the field
        // onto the written `review.json` (`src/ct/review_session.nim`), for
        // both collector routes at once.
        session: None,
    };
    Ok((data, report))
}

/// Collect one recording into the shared accumulators.
fn collect_one(
    recording: &Path,
    options: &CollectOptions,
    review_paths: &[String],
    accumulators: &mut [FileAcc],
    recorded_sources: &mut [Option<PathBuf>],
    call_nodes: &mut Vec<CallNodeData>,
    report: &mut CollectReport,
) -> Result<(), Box<dyn Error>> {
    let ctfs = open_materialized_trace(recording)?;
    let db = ctfs.materialized_db();
    let workdir = ctfs.workdir().to_path_buf();
    let reader: Arc<dyn TraceReader> = Arc::new(InMemoryTraceReader::new(db));

    // --- coverage, and which call touches which review file --------------
    // `anchors` maps a call to the last step of it that lands on a diff line
    // (see the module header for why the last one).
    let mut anchors: BTreeMap<i64, (StepId, usize)> = BTreeMap::new();
    let mut touched_files: BTreeSet<usize> = BTreeSet::new();
    let mut lines_this_recording: Vec<BTreeSet<u32>> = vec![BTreeSet::new(); review_paths.len()];
    // Path resolution is per `PathId`, not per step: a trace has a handful of
    // paths and can have millions of steps.
    let mut path_match: HashMap<usize, Option<usize>> = HashMap::new();
    let mut path_absolute: HashMap<usize, PathBuf> = HashMap::new();

    let touched_lines: Vec<BTreeSet<u32>> = options
        .diff
        .files
        .iter()
        .map(|file| file.touched_new_lines().into_iter().collect())
        .collect();

    for index in 0..reader.step_count() {
        let step_id = StepId(index as i64);
        let Some(step) = reader.step(step_id) else { continue };
        let path_id = step.path_id.0;
        let matched = *path_match.entry(path_id).or_insert_with(|| {
            let raw = reader.path(step.path_id).unwrap_or("");
            let absolute = absolute_trace_path(raw, &workdir);
            let matched = match_review_file(&absolute, review_paths);
            path_absolute.insert(path_id, absolute);
            matched
        });
        let Some(file_index) = matched else { continue };
        let line = step.line.0;
        if line <= 0 {
            continue;
        }
        let line = line as u32;
        touched_files.insert(file_index);
        lines_this_recording[file_index].insert(line);
        *accumulators[file_index].coverage.entry(line).or_insert(0) += 1;
        if touched_lines[file_index].contains(&line) {
            anchors.insert(step.call_key.0, (step_id, file_index));
        }
    }

    for file_index in 0..review_paths.len() {
        if recorded_sources[file_index].is_none()
            && let Some(absolute) = path_match
                .iter()
                .find(|(_, matched)| **matched == Some(file_index))
                .and_then(|(path_id, _)| path_absolute.get(path_id))
            && let Some(copy) = recorded_source_path(recording, absolute)
        {
            recorded_sources[file_index] = Some(copy);
        }
        for line in &lines_this_recording[file_index] {
            *accumulators[file_index].recordings_per_line.entry(*line).or_insert(0) += 1;
        }
    }
    for file_index in &touched_files {
        accumulators[*file_index].recordings_touching += 1;
    }

    // --- flow, one execution per anchored call ---------------------------
    let mut flow_preloader = FlowPreloader::new();
    // Resolve source files through the recording's own `files/` copy first: a
    // review is read after the fact, and the working tree may no longer hold
    // the file the program ran (a /tmp script, a container path).  The loader
    // falls back to the original path when the copy is absent, so this is
    // strictly more likely to find the source than the default.
    flow_preloader.expr_loader = ExprLoader::new(CoreTrace {
        imported: true,
        trace_output_folder: recording.display().to_string(),
        ..CoreTrace::default()
    });

    // --- per-function call counts ---------------------------------------
    for index in 0..reader.call_count() {
        let Some(call) = reader.call(CallKey(index as i64)) else {
            continue;
        };
        let (function_name, function_line, call_step) = {
            let Some(function) = reader.function(call.function_id) else {
                continue;
            };
            (function.name.clone(), function.line.0, call.step_id)
        };
        let Some(function) = reader.function(call.function_id) else {
            continue;
        };
        let path_id = function.path_id.0;
        let matched = match path_match.get(&path_id) {
            Some(matched) => *matched,
            None => {
                let raw = reader.path(function.path_id).unwrap_or("");
                let absolute = absolute_trace_path(raw, &workdir);
                let matched = match_review_file(&absolute, review_paths);
                path_absolute.insert(path_id, absolute);
                path_match.insert(path_id, matched);
                matched
            }
        };
        let Some(file_index) = matched else { continue };
        let known = accumulators[file_index].functions.contains_key(&function_name);
        let entry = accumulators[file_index]
            .functions
            .entry(function_name.clone())
            .or_default();
        entry.call_count += 1;
        if !known {
            // First call of this function: resolve its source range once, from
            // the same `load_location` the DAP handler uses to enrich a flow
            // request.  Doing it here rather than only for functions that get
            // flow is what keeps a called-but-not-reviewed function out of the
            // dataset with an `endLine` of 0 — a zero that would read as line
            // zero rather than as "not known".
            if function_line > 0 {
                entry.start_line = function_line as u32;
            }
            let bounds = reader.load_location(call_step, CallKey(index as i64), &mut flow_preloader.expr_loader);
            if bounds.function_first > 0 {
                entry.start_line = bounds.function_first as u32;
            }
            if bounds.function_last > 0 {
                entry.end_line = bounds.function_last as u32;
            }
        }
    }

    let mut replay = MaterializedReplaySession::new(Arc::clone(&reader));
    let mut per_function: HashMap<(usize, String), u32> = HashMap::new();

    for (call_key, (anchor, file_index)) in anchors {
        let mut location = reader.load_location(anchor, CallKey(call_key), &mut flow_preloader.expr_loader);
        location.rr_ticks = RRTicks(anchor.0);
        let function_key = if location.function_name.is_empty() {
            reader
                .call(CallKey(call_key))
                .and_then(|call| reader.function(call.function_id))
                .map(|function| function.name.clone())
                .unwrap_or_default()
        } else {
            location.function_name.clone()
        };
        // The budget is per recording — a hot function is hot in each of them
        // — but the index a flow is filed under is global to the dataset.  The
        // GUI's invocation selector keys on `(functionKey, executionIndex)`,
        // so restarting the count for every recording would give two different
        // executions the same identity.
        let seen = per_function.entry((file_index, function_key.clone())).or_insert(0);
        if *seen as usize >= options.max_flows_per_function {
            continue;
        }
        *seen += 1;
        let execution_index = accumulators[file_index]
            .flow
            .iter()
            .filter(|flow| flow.function_key == function_key)
            .count() as u32;

        let update = flow_preloader.load(location, FlowMode::Call, TraceKind::Materialized, &mut replay);
        if update.error {
            warn!(
                "deepreview: flow for {} in {} failed: {}",
                function_key,
                recording.display(),
                update.error_message
            );
            continue;
        }
        let Some(view) = update.view_updates.first() else {
            continue;
        };
        if view.steps.is_empty() {
            // A flow with no steps carries nothing a reviewer can read, and
            // exporting it would report the function as traced when the
            // overlay would be blank.
            continue;
        }
        let acc = &mut accumulators[file_index];
        record_loops(acc, view);
        acc.flow.push(convert_flow(
            view,
            &function_key,
            execution_index,
            options.max_value_chars,
        ));
        let entry = acc.functions.entry(function_key).or_default();
        entry.execution_count += 1;
        if view.location.function_first > 0 {
            entry.start_line = view.location.function_first as u32;
        }
        if view.location.function_last > 0 {
            entry.end_line = view.location.function_last as u32;
        }
    }

    // --- the call tree ---------------------------------------------------
    let budget = options.max_call_nodes.saturating_sub(count_nodes(call_nodes));
    let (nodes, truncated) = build_call_tree(reader.as_ref(), budget);
    report.call_tree_truncated |= truncated;
    call_nodes.extend(nodes);

    info!("deepreview: collected {}", recording.display());
    Ok(())
}

/// Total nodes in a call forest.
fn count_nodes(nodes: &[CallNodeData]) -> usize {
    nodes.iter().map(|node| 1 + count_nodes(&node.children)).sum()
}

#[cfg(test)]
mod structure_cap_tests {
    //! UD-3 / RV-9's fourth deliverable: "the value-cap knobs restated in terms
    //! of structure depth rather than rendered length".
    //!
    //! Mock objects: none. `crate::value::Value` is the real type the replay
    //! backend builds and ships; these cases construct one and read the copy
    //! `pruned_value` makes of it.
    use super::{prune_to, pruned_value, structure_caps};
    use crate::value::{Type, Value};
    use codetracer_trace_types::TypeKind;

    /// A chain of `depth` nested one-element sequences with an int at the leaf.
    fn nest(depth: usize) -> Value {
        let mut value = Value {
            kind: TypeKind::Int,
            i: "7".to_string(),
            typ: Type {
                kind: TypeKind::Int,
                lang_type: "i32".to_string(),
                ..Default::default()
            },
            ..Default::default()
        };
        for _ in 0..depth {
            value = Value {
                kind: TypeKind::Seq,
                elements: vec![value],
                typ: Type {
                    kind: TypeKind::Seq,
                    lang_type: "Vec<i32>".to_string(),
                    ..Default::default()
                },
                ..Default::default()
            };
        }
        value
    }

    fn depth_of(value: &Value) -> usize {
        value.elements.iter().map(|e| 1 + depth_of(e)).max().unwrap_or(0)
    }

    #[test]
    fn a_value_within_the_caps_survives_unchanged() {
        let value = nest(2);
        assert_eq!(pruned_value(&value, 256), value);
    }

    #[test]
    fn a_value_deeper_than_the_cap_keeps_its_shape_down_to_the_cut() {
        // Cut, not refused: a reviewer sees the shape and the first levels
        // rather than nothing, and what survives is still structure.
        let pruned = prune_to(&nest(9), 3, 32);
        assert_eq!(depth_of(&pruned), 3);
        // The type survives the cut, so a cut value still renders as the right
        // KIND of thing rather than as an empty one.
        assert_eq!(pruned.typ.lang_type, "Vec<i32>");
        assert_eq!(pruned.kind, TypeKind::Seq);
    }

    #[test]
    fn a_value_wider_than_the_cap_keeps_its_first_elements() {
        let wide = Value {
            kind: TypeKind::Seq,
            elements: (0..100)
                .map(|i| Value {
                    kind: TypeKind::Int,
                    i: i.to_string(),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        };
        let pruned = prune_to(&wide, 4, 8);
        assert_eq!(pruned.elements.len(), 8);
        assert_eq!(pruned.elements[0].i, "0");
        assert_eq!(pruned.elements[7].i, "7");
    }

    #[test]
    fn a_reference_and_a_variant_are_cut_the_same_way_as_elements() {
        // Both are edges out of a value, so both are places a cycle can hide.
        let inner = nest(5);
        let value = Value {
            kind: TypeKind::Ref,
            ref_value: Some(Box::new(inner.clone())),
            active_variant_value: Some(Box::new(inner)),
            ..Default::default()
        };
        let pruned = prune_to(&value, 2, 32);
        assert_eq!(depth_of(pruned.ref_value.as_ref().unwrap()), 1);
        assert_eq!(depth_of(pruned.active_variant_value.as_ref().unwrap()), 1);
    }

    #[test]
    fn the_caps_move_with_the_knob_the_presets_already_scale() {
        // One dial, not three: `--preset`'s scaling of `max_value_chars` is
        // what changes the structure budget too.
        assert!(structure_caps(1024) > structure_caps(64));
        // …and it is bounded at both ends, so neither a tiny preset nor a huge
        // one produces a degenerate budget.
        assert_eq!(structure_caps(0), (2, 8));
        assert_eq!(structure_caps(usize::MAX), (8, 256));
    }
}
