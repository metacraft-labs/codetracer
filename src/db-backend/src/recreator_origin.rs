//! M11 — RR-driver origin chain implementation.
//!
//! Implements the value-origin chain algorithm for `TraceKind::Recreator`
//! (RR-backed natively-compiled) traces per spec §6.3 of
//! `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`.
//!
//! The high-level algorithm:
//!
//! ```text
//! 1. seek(replay, query_step)
//! 2. (addr, size) = replay.evaluate_with_address(query_var)
//! 3. while chain.len() < budget.max_hops:
//!    a. wp = replay.create_watchpoint_on_address(addr, size, is_write=true)
//!    b. replay.reverse_continue()
//!    c. if recording-start hit: terminator = RecordingStart; break
//!    d. if !wp.fired: terminator = OutOfBudget; break
//!    e. pc = replay.current_pc(); loc = dwarf_index::resolve_pc(pc)
//!    f. ** STACK-SLOT REUSE GUARD ** — if the writing instruction's
//!       source line does NOT target the queried variable, delete the
//!       watchpoint, re-issue reverse-continue, and repeat.
//!    g. ** CROSS-THREAD GUARD ** — if the writing thread differs from
//!       the querying thread, switch the replay session to the writing
//!       thread, tag the hop with `CrossThreadCopy` + `confidence = 0.6`,
//!       and continue inside the writing thread's frame.
//!    h. ** OPERAND RE-EXECUTION HELPER ** — for Computational hops,
//!       step forward one source line so DWARF location lists place
//!       each operand in a known register or memory location, THEN
//!       evaluate operand snapshots.
//!    i. classify(line_text, lang, patterns)
//!    j. push OriginHop
//!    k. if kind not in (TrivialCopy, ParameterPass, ReturnCapture):
//!       terminator = kind_to_terminator(kind); break
//!    l. (addr, size) = replay.evaluate_with_address(source_var)
//!    m. replay.delete_watchpoint(wp)
//! ```
//!
//! Watchpoint cleanup is defensive: the loop calls
//! [`delete_watchpoint`] on every hop transition AND on every error
//! path (via the [`WatchpointGuard`] RAII handle below). No dangling
//! watchpoints can leak across hop boundaries.
//!
//! Budget enforcement: default `max_hops` is 8 (set at the M11 dispatch
//! callsite in `dap_handler.rs`), lower than the M2 materialized default
//! (16) because each RR hop costs a reverse-continue that can take
//! hundreds of milliseconds for sparse-write addresses.
//!
//! DAP error 6103 fallback: when the language is not RR-supported (e.g.
//! Lean, D — neither has a tree-sitter grammar in `origin-classifier`),
//! the dispatcher routes back to [`OriginError::unsupported_backend`]
//! and the frontend renders the "coming soon" affordance.

use std::path::PathBuf;
use std::time::Instant;

use log::{debug, info, warn};
use serde::Deserialize;
use serde_json::Value as JsonValue;

use crate::expr_loader::ExprLoader;
use crate::expr_loader::SourceOrigin;
use crate::origin_query::{
    OriginContinuationToken, OriginError, OriginErrorCode, SourceDigest, SourceOriginKind, WallClockDeadline,
    sha256_hex,
};
use crate::query::ReplayQuery;
use crate::recreator_session::RecreatorReplaySession;
use crate::task::{
    CtOriginChainArguments, Location, OperandSnapshot, OriginBudget, OriginChain, OriginHop, OriginKind, OriginMetrics,
    Terminator, TerminatorKind,
};
use origin_classifier::{Classification, Lang as ClassifierLang, PatternSet, parse_assignment};

/// Default per-hop wall-clock cap for the RR origin loop (spec §6.3 —
/// lower than the M2 materialized default because each hop costs a
/// reverse-continue). The dispatcher applies this on top of the
/// per-request budget.
pub const RR_PER_HOP_WALL_CLOCK_MS: u32 = 1_500;
const RR_UI_TEST_PER_HOP_ENV: &str = "CT_RR_ORIGIN_PER_HOP_WALL_CLOCK_MS";
const RR_UI_TEST_PER_HOP_MAX_MS: u32 = 10_000;

/// Default `max_hops` for the RR backend (spec §6.3 — half of M2's 16).
pub const RR_DEFAULT_MAX_HOPS: u32 = 8;

/// Worker reply: address + size of a variable's storage at the current
/// tick (`EvaluateWithAddress` response).
#[derive(Debug, Clone, Deserialize)]
pub struct EvaluateAddressResponse {
    pub address: u64,
    pub size: usize,
}

/// Worker reply: numeric watchpoint id (parsed from a JSON number or an
/// envelope like `{"id": N}`).
fn parse_watchpoint_id(raw: &str) -> Result<i64, OriginError> {
    let trimmed = raw.trim();
    if let Ok(n) = trimmed.parse::<i64>() {
        return Ok(n);
    }
    if let Ok(n) = serde_json::from_str::<i64>(trimmed) {
        return Ok(n);
    }
    if let Ok(envelope) = serde_json::from_str::<JsonValue>(trimmed)
        && let Some(id) = envelope.get("id").and_then(|v| v.as_i64())
    {
        return Ok(id);
    }
    Err(OriginError::new(
        OriginErrorCode::UnsupportedBackend,
        format!("AddWatchpoint reply not parseable as id: `{trimmed}`"),
    ))
}

/// Worker reply shape for the `ReverseContinue` query — distinguishes
/// the recording-start sentinel from a watchpoint hit. Workers that
/// only emit a bare status string (`"watchpoint"` etc.) are also
/// accepted via the `From<&str>` fallback below.
#[derive(Debug, Clone, Deserialize)]
pub struct ReverseContinueResponse {
    /// One of `"watchpoint"`, `"recording-start"`, `"breakpoint"`,
    /// `"signal"`, `"out-of-budget"`.
    pub reason: String,
    /// Watchpoint id that fired (None when reason != "watchpoint").
    #[serde(default, alias = "watchpointId")]
    pub watchpoint_id: Option<i64>,
}

impl ReverseContinueResponse {
    fn from_raw(raw: &str) -> Self {
        if let Ok(envelope) = serde_json::from_str::<ReverseContinueResponse>(raw) {
            return envelope;
        }
        // Fallback: bare reason string from older workers.
        ReverseContinueResponse {
            reason: raw.trim().trim_matches('"').to_string(),
            watchpoint_id: None,
        }
    }

    fn hit_recording_start(&self) -> bool {
        self.reason == "recording-start"
    }

    fn hit_watchpoint(&self) -> bool {
        self.reason == "watchpoint"
    }
}

/// RAII handle around a watchpoint id — drops the watchpoint on the
/// worker side when the guard goes out of scope. Critical for the
/// "watchpoint cleanup on each hop transition + on error" deliverable.
///
/// Callers MUST take the id back via [`WatchpointGuard::take`] when
/// they want to release ownership (e.g. after a successful explicit
/// delete inside the hop body). On drop the guard issues a best-effort
/// `DeleteWatchpoint` and logs (rather than panics) on failure — Drop
/// must not panic.
struct WatchpointGuard<'a> {
    id: Option<i64>,
    session: &'a mut RecreatorReplaySession,
}

impl<'a> WatchpointGuard<'a> {
    fn new(session: &'a mut RecreatorReplaySession, id: i64) -> Self {
        WatchpointGuard { id: Some(id), session }
    }

    fn id(&self) -> i64 {
        self.id.unwrap_or(-1)
    }

    /// Release ownership and return the id without issuing a delete.
    /// Used when the caller has already deleted the watchpoint via an
    /// explicit `DeleteWatchpoint` query (e.g. inside the hop body
    /// after computing the next watch address).
    fn take(mut self) -> i64 {
        self.id.take().unwrap_or(-1)
    }
}

impl Drop for WatchpointGuard<'_> {
    fn drop(&mut self) {
        if self.id.take().is_some() {
            let res = self
                .session
                .stable
                .dispatch_replay_query(ReplayQuery::DeleteWatchpoints);
            if let Err(e) = res {
                warn!("WatchpointGuard: failed to delete watchpoints: {e}");
            }
        }
    }
}

/// Result of the M11 origin algorithm.
pub type RrOriginResult = Result<OriginChain, OriginError>;

/// Map the classifier's [`Lang`] enum to a path extension. The RR
/// algorithm needs the classifier `Lang` to drive `parse_assignment`,
/// and inherits the resolver from `db.rs::classifier_lang_for_path`.
pub fn classifier_lang_for_path(path: &str) -> Option<ClassifierLang> {
    let p = PathBuf::from(path);
    let ext = p.extension().and_then(|s| s.to_str())?;
    match ext {
        "c" | "h" => Some(ClassifierLang::C),
        "cc" | "cpp" | "cxx" | "hpp" => Some(ClassifierLang::Cpp),
        "rs" => Some(ClassifierLang::Rust),
        "go" => Some(ClassifierLang::Go),
        "nim" | "nims" | "nimble" => Some(ClassifierLang::Nim),
        // Languages that the classifier does NOT yet support — the
        // dispatcher returns DAP 6103 before reaching the algorithm,
        // but we keep the path here for completeness.
        _ => None,
    }
}

/// Run the M11 origin algorithm against a `RecreatorReplaySession`.
///
/// The dispatcher (`dap_handler::recreator_origin_chain`) supplies the
/// session, the per-request arguments, the budget (with the M11 lower
/// `max_hops` default already applied), the layered `PatternSet`, the
/// `ExprLoader` for source-line reads, and the bundled-sources root.
///
/// Returns an [`OriginChain`] on success or an [`OriginError`] carrying
/// one of the spec §5.3 codes 6101–6106.
pub fn run_rr_origin_chain(
    session: &mut RecreatorReplaySession,
    args: &CtOriginChainArguments,
    budget: &OriginBudget,
    expr_loader: &mut ExprLoader,
    patterns: &PatternSet,
    meta_dat_sources_root: Option<&std::path::Path>,
) -> RrOriginResult {
    let started_at = Instant::now();
    let deadline = WallClockDeadline::new(budget.wall_clock_ms);
    let mut metrics = OriginMetrics::default();
    let mut hops: Vec<OriginHop> = Vec::new();
    let mut source_digests: Vec<SourceDigest> = Vec::new();
    let current_worker_step = load_current_location(session, expr_loader)
        .map(|loc| loc.rr_ticks.0)
        .ok();
    let initial_query_step = if args.step_id < 0 {
        current_worker_step.unwrap_or(0)
    } else {
        args.step_id
    };
    let mut current_var_name = args.variable_name.clone();
    let query_variable = args.variable_name.clone();

    // Defensive bail-out: empty variable name = 6101 (spec §5.3).
    if current_var_name.trim().is_empty() {
        return Err(OriginError::new(
            OriginErrorCode::InvalidVariablePath,
            "origin_chain: variable_name is empty".to_string(),
        ));
    }

    // M8 gate wiring: give the live materialization cache the first chance to
    // cover the query prefix through the production replay-worker adapter. The
    // Linux rr collector still fails closed in current workers, so materialize
    // errors are logged and the existing watchpoint walk remains the fallback.
    if initial_query_step > 0 {
        match session.ensure_materialized_for_live_query(0, initial_query_step as u64 + 1) {
            Ok(outcome) => debug!("origin_chain: materialization gate outcome: {outcome:?}"),
            Err(err) => warn!("origin_chain: materialization gate unavailable, falling back to RR walk: {err}"),
        }
    }

    // Step 1: resolve the variable's address + size at the query tick.
    // Locals can lose addressable DWARF storage as soon as we move to the next
    // RR tick, so capture the real stack slot before positioning the worker for
    // reverse-watchpoint execution.
    let mut watch = evaluate_with_address(session, &current_var_name)?;

    // Step 2: position the replay worker for reverse-watchpoint execution.
    //
    // Write-origin watchpoints are installed as write-only in the native
    // backend. Starting at the exact query tick preserves addressable stack
    // storage and still avoids read self-hits on the query line.
    let watch_start_step = initial_query_step;
    if watch_start_step >= 0 && current_worker_step != Some(watch_start_step) {
        match session.stable.dispatch_replay_query(ReplayQuery::SeekToTicks {
            ticks: watch_start_step,
        }) {
            Ok(_) => {}
            Err(next_err) if args.step_id >= 0 => {
                session
                    .stable
                    .dispatch_replay_query(ReplayQuery::SeekToTicks { ticks: args.step_id })
                    .map_err(|e| {
                        OriginError::new(
                            OriginErrorCode::InvalidFrameOrStep,
                            format!("origin_chain: SeekToTicks failed: next={next_err}; original={e}"),
                        )
                    })?;
            }
            Err(e) => {
                return Err(OriginError::new(
                    OriginErrorCode::InvalidFrameOrStep,
                    format!("origin_chain: SeekToTicks failed: {e}"),
                ));
            }
        }
    }

    let mut effective_max_hops = budget.max_hops.max(1);
    if args.max_hops > 0 {
        effective_max_hops = effective_max_hops.min(args.max_hops);
    }

    // Per-request per-hop wall-clock cap (lower than M2; see
    // [`RR_PER_HOP_WALL_CLOCK_MS`]).
    let per_hop_cap_ms = rr_per_hop_wall_clock_ms();

    let mut terminator = Terminator::new(TerminatorKind::UnknownSource);
    let mut truncated = false;
    let querying_thread = current_thread(session).unwrap_or(0);

    while hops.len() < effective_max_hops as usize {
        if deadline.exceeded() {
            terminator = Terminator::new(TerminatorKind::OutOfBudget);
            terminator.expression = format!("wall-clock budget exhausted ({} ms)", budget.wall_clock_ms);
            break;
        }

        // ---- 1. Install watchpoint -------------------------------------
        let wp_id = match session.stable.dispatch_replay_query(ReplayQuery::AddWatchpoint {
            address: watch.address,
            size: watch.size,
            is_write: true,
        }) {
            Ok(raw) => parse_watchpoint_id(&raw)?,
            Err(e) => {
                return Err(OriginError::new(
                    OriginErrorCode::UnsupportedBackend,
                    format!("origin_chain: AddWatchpoint failed: {e}"),
                ));
            }
        };
        let wp_guard = WatchpointGuard::new(session, wp_id);

        // ---- 2. Reverse-continue with stack-slot reuse guard -----------
        // The guard re-issues reverse-continue when the writing
        // instruction's source line does not target `current_var_name`
        // (spec §6.3 "stack-slot reuse / aliasing guard").
        let hop_started = Instant::now();
        let validated = loop {
            let raw = match wp_guard
                .session
                .stable
                .dispatch_replay_query(ReplayQuery::ReverseContinue)
            {
                Ok(r) => r,
                Err(e) => {
                    drop(wp_guard); // defensive watchpoint cleanup on error.
                    return Err(OriginError::new(
                        OriginErrorCode::UnsupportedBackend,
                        format!("origin_chain: ReverseContinue failed: {e}"),
                    ));
                }
            };
            let rc = ReverseContinueResponse::from_raw(&raw);
            if rc.hit_recording_start() {
                break ValidatedHop::RecordingStart;
            }
            if !rc.hit_watchpoint() {
                debug!(
                    "origin_chain: reverse-continue stopped for non-watchpoint reason `{}`; re-issuing until watchpoint, recording start, or cap",
                    rc.reason
                );
                if (hop_started.elapsed().as_millis() as u32) >= per_hop_cap_ms {
                    break ValidatedHop::OutOfBudget;
                }
                continue;
            }
            // Per-hop wall-clock cap.
            if (hop_started.elapsed().as_millis() as u32) >= per_hop_cap_ms {
                break ValidatedHop::OutOfBudget;
            }

            // 3. Inspect the writing PC and decode (path, line).
            let location = match load_current_location(wp_guard.session, expr_loader) {
                Ok(loc) => loc,
                Err(_) => {
                    // Optimizer-elided or runtime-injected code:
                    // re-issue reverse-continue (spec §6.3).
                    debug!("origin_chain: unresolved PC -> re-issuing reverse-continue");
                    continue;
                }
            };

            // Read the writing thread id BEFORE we read the source line —
            // the cross-thread guard switches the replay session below.
            let writing_thread = current_thread(wp_guard.session).unwrap_or(querying_thread);
            let cross_thread = writing_thread != querying_thread;
            if cross_thread {
                info!(
                    "origin_chain: cross-thread write detected (querying={}, writing={})",
                    querying_thread, writing_thread
                );
                // Switch the replay session to the writing thread so
                // the source-line and operand reads see the right frame.
                let _ = wp_guard
                    .session
                    .stable
                    .dispatch_replay_query(ReplayQuery::SelectThread { tid: writing_thread });
            }

            // 4. Read the source line and parse with the classifier.
            let path_str = location.path.clone();
            let row = location.line.max(0) as usize;
            let probe_path = std::path::PathBuf::from(&path_str);
            let (line_text, source_origin) = expr_loader.get_source_line_v2(&probe_path, row, meta_dat_sources_root);
            if source_origin == SourceOrigin::Unavailable || line_text.is_empty() {
                // Unknown-source: keep reverse-stepping; same posture as
                // spec §6.3 "Optimizer-elided or runtime-injected code".
                debug!(
                    "origin_chain: missing source line at {}:{} — re-issuing reverse-continue",
                    path_str, row
                );
                continue;
            }

            let lang = match classifier_lang_for_path(&path_str) {
                Some(l) => l,
                None => {
                    // Language not supported by the classifier — surface
                    // 6103 to the caller so the frontend can render
                    // "coming soon" rather than a fake hop.
                    drop(wp_guard);
                    return Err(OriginError::unsupported_backend(
                        format!("rr-driver: classifier does not support language for `{path_str}`").as_str(),
                    ));
                }
            };

            let mut candidate_location = location.clone();
            let mut candidate_line_text = line_text;
            let mut candidate_source_origin = source_origin;
            let mut candidate_ast = parse_assignment(&candidate_line_text, lang);

            if !candidate_ast
                .as_ref()
                .map(|ast| ast.targets_variable(&current_var_name))
                .unwrap_or(false)
                && row > 1
            {
                // RR/LLDB reports data-watchpoint stops after the write has
                // executed. For single-line C/C++ assignments this commonly
                // places the selected PC on the following source line. Accept
                // the immediately preceding line only when it parses and its
                // LHS names the watched variable; otherwise preserve the
                // stack-slot reuse guard's rejection behavior.
                let previous_row = row - 1;
                let (previous_line_text, previous_source_origin) =
                    expr_loader.get_source_line_v2(&probe_path, previous_row, meta_dat_sources_root);
                if previous_source_origin != SourceOrigin::Unavailable
                    && !previous_line_text.is_empty()
                    && let Some(previous_ast) = parse_assignment(&previous_line_text, lang)
                    && previous_ast.targets_variable(&current_var_name)
                {
                    candidate_location.line = previous_row as i64;
                    candidate_line_text = previous_line_text;
                    candidate_source_origin = previous_source_origin;
                    candidate_ast = Some(previous_ast);
                }
            }

            let ast = match candidate_ast {
                Some(a) if a.targets_variable(&current_var_name) => a,
                Some(_) => {
                    // Stack-slot reuse: writing instruction targets a
                    // different variable that aliases our address. Skip.
                    debug!(
                        "origin_chain: stack-slot reuse — line `{candidate_line_text}` does not target `{current_var_name}`"
                    );
                    continue;
                }
                None => {
                    // Address aliasing — different variable in source
                    // happens to share the slot. Skip and continue
                    // reverse-execution (spec §6.3 guard step).
                    debug!("origin_chain: line `{candidate_line_text}` did not parse — re-issuing reverse-continue");
                    continue;
                }
            };

            // Capture source digest for continuation-token integrity.
            if !path_str.is_empty() && candidate_source_origin != SourceOrigin::Unavailable {
                track_source_digest(
                    &mut source_digests,
                    &probe_path,
                    candidate_source_origin,
                    meta_dat_sources_root,
                );
            }

            break ValidatedHop::Validated(Box::new(ValidatedHopPayload {
                location: candidate_location,
                line_text: candidate_line_text,
                ast,
                lang,
                cross_thread,
                writing_thread,
            }));
        };

        // ---- 3. Drive hop outcome --------------------------------------
        match validated {
            ValidatedHop::RecordingStart => {
                drop(wp_guard);
                terminator = Terminator::new(TerminatorKind::RecordingStart);
                terminator.expression = format!("recording start reached after {} hops", hops.len());
                break;
            }
            ValidatedHop::OutOfBudget => {
                drop(wp_guard);
                terminator = Terminator::new(TerminatorKind::OutOfBudget);
                terminator.expression = format!(
                    "rr per-hop wall-clock cap ({} ms) tripped; documentation: spec §6.3",
                    per_hop_cap_ms
                );
                terminator.source_line = Some(format!(
                    "elided assignment for `{}` — see {}",
                    current_var_name, "codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md §6.3"
                ));
                break;
            }
            ValidatedHop::Validated(payload) => {
                let ValidatedHopPayload {
                    location,
                    line_text,
                    ast,
                    lang,
                    cross_thread,
                    writing_thread: _writing_thread,
                } = *payload;
                metrics.classifier_hits += 1;
                let classification = origin_classifier::classify(&ast, &current_var_name, lang, patterns);
                let kind: OriginKind = if cross_thread {
                    // Cross-thread guard overrides the classification —
                    // the hop crosses a thread boundary regardless of
                    // the line's kind (spec §6.3).
                    OriginKind::CrossThreadCopy
                } else {
                    classification.kind.into()
                };
                let confidence: f32 = if cross_thread {
                    0.6
                } else {
                    classification_confidence(&classification)
                };

                // ---- Operand re-execution helper -----------------------
                // For Computational hops, step forward one source line
                // so DWARF location lists place each operand in a known
                // register/memory location (spec §6.3).
                let mut operand_snapshots: Vec<OperandSnapshot> = Vec::new();
                let mut truncated_operands = false;
                if matches!(kind, OriginKind::Computational) {
                    operand_re_execute(wp_guard.session);
                    let (snaps, truncated_flag) =
                        collect_operand_snapshots(wp_guard.session, &classification, args.step_id);
                    operand_snapshots = snaps;
                    truncated_operands = truncated_flag;
                }

                // Extract the target text from the classification's
                // target locator (the classifier returns the LHS
                // sub-element that matches `current_var_name`).
                let target_expr = ast.text_at(classification.target).to_string();
                let rhs_text = ast.text_at(classification.rhs).to_string();
                let source_variable = classification.source_variable.clone();
                let hop = OriginHop {
                    kind,
                    target_expr,
                    source_expr: rhs_text.clone(),
                    source_variable: source_variable.clone(),
                    location: location.clone(),
                    source_text: line_text,
                    step_id: args.step_id,
                    frame_transition: None,
                    operand_snapshots,
                    truncated_operands,
                    confidence,
                    classification_provenance: Some(classification_provenance(&classification, cross_thread)),
                    correlation_transition: None,
                };
                hops.push(hop);

                // ---- 4. Decide whether to continue ---------------------
                let continue_kinds = matches!(
                    kind,
                    OriginKind::TrivialCopy | OriginKind::ParameterPass | OriginKind::ReturnCapture
                );
                if !continue_kinds {
                    // Computational / Literal / FieldAccess / IndexAccess /
                    // FunctionCall / FunctionReturn / Unknown — terminator.
                    drop(wp_guard);
                    terminator = Terminator::new(kind_to_terminator(kind));
                    terminator.expression = rhs_text;
                    terminator.source_line = Some(location.path.clone());
                    break;
                }

                // Resolve the source variable's address at the new tick.
                let next_var_name = source_variable
                    .or_else(|| classification.source_variable.clone())
                    .unwrap_or_else(|| current_var_name.clone());

                // Explicit delete BEFORE asking the worker for the new
                // address — keeps the watchpoint count bounded at 1.
                let wp_id_taken = wp_guard.take();
                let _ = session
                    .stable
                    .dispatch_replay_query(ReplayQuery::DeleteWatchpoints)
                    .or_else(|_| {
                        session
                            .stable
                            .dispatch_replay_query(ReplayQuery::DeleteWatchpoint { id: wp_id_taken })
                    });

                match evaluate_with_address(session, &next_var_name) {
                    Ok(next) => {
                        watch = next;
                        current_var_name = next_var_name;
                    }
                    Err(_) => {
                        // Source variable went out of scope before the
                        // current tick — terminate at UnknownVariable.
                        terminator = Terminator::new(TerminatorKind::UnknownVariable);
                        terminator.expression = next_var_name;
                        break;
                    }
                }
            }
        }
    }

    if hops.len() >= effective_max_hops as usize {
        // We exhausted the per-request hop budget; surface `truncated`
        // and a continuation token so the frontend can resume.
        truncated = true;
        if matches!(terminator.kind, TerminatorKind::UnknownSource) {
            // No explicit terminator was set; fall back to OutOfBudget.
            terminator = Terminator::new(TerminatorKind::OutOfBudget);
            terminator.expression = format!("max_hops budget ({}) reached", effective_max_hops);
        }
    }

    metrics.elapsed_ms = started_at.elapsed().as_millis() as u64;
    metrics.steps_scanned = hops.len() as u64;

    let confidence: f32 = hops.iter().map(|h| h.confidence).fold(1.0_f32, f32::min);
    let continuation_token = if truncated {
        Some(build_continuation_token(
            &query_variable,
            initial_query_step,
            &current_var_name,
            hops.len() as u32,
            effective_max_hops,
            patterns,
            source_digests.clone(),
        )?)
    } else {
        None
    };

    Ok(OriginChain {
        query_variable,
        query_step_id: initial_query_step,
        hops,
        terminator,
        truncated,
        continuation_token,
        metrics,
        cross_process_spans: Vec::new(),
        confidence,
    })
}

fn rr_per_hop_wall_clock_ms() -> u32 {
    if std::env::var("CODETRACER_IN_UI_TEST").ok().as_deref() != Some("1") {
        return RR_PER_HOP_WALL_CLOCK_MS;
    }
    std::env::var(RR_UI_TEST_PER_HOP_ENV)
        .ok()
        .and_then(|raw| raw.parse::<u32>().ok())
        .map(|ms| ms.clamp(RR_PER_HOP_WALL_CLOCK_MS, RR_UI_TEST_PER_HOP_MAX_MS))
        .unwrap_or(RR_PER_HOP_WALL_CLOCK_MS)
}

/// Per-hop validated payload. Held inside `ValidatedHop::Validated` via
/// `Box` so the enum's variant sizes stay balanced (the AST carries a
/// tree-sitter tree handle which inflates the inline size).
struct ValidatedHopPayload {
    location: Location,
    line_text: String,
    ast: origin_classifier::AssignmentAst,
    lang: ClassifierLang,
    cross_thread: bool,
    #[allow(dead_code)]
    writing_thread: u32,
}

/// Inner result of the per-hop reverse-continue loop.
enum ValidatedHop {
    Validated(Box<ValidatedHopPayload>),
    RecordingStart,
    OutOfBudget,
}

/// Map a classifier `Classification` to a confidence score. Mirrors the
/// score the materialized algorithm computes in `db.rs`; the per-hop
/// scoring is the same regardless of backend.
fn classification_confidence(c: &Classification) -> f32 {
    // Spec §6.1.5 — built-in catalogue rules ship with `0.9`; user
    // pattern matches with `0.95`; unmatched falls back to `0.7`.
    // We keep parity with the materialized algorithm so per-hop
    // confidence values look consistent between backends.
    match c.kind {
        origin_classifier::OriginKind::TrivialCopy
        | origin_classifier::OriginKind::ParameterPass
        | origin_classifier::OriginKind::ReturnCapture => 0.95,
        origin_classifier::OriginKind::Computational
        | origin_classifier::OriginKind::FieldAccess
        | origin_classifier::OriginKind::IndexAccess => 0.9,
        origin_classifier::OriginKind::Literal => 1.0,
        origin_classifier::OriginKind::FunctionCall => 0.8,
        origin_classifier::OriginKind::CrossThread => 0.6,
        origin_classifier::OriginKind::Unknown => 0.5,
    }
}

/// Produce a `classification_provenance` string for the hop. Mirrors the
/// materialized algorithm's `built-in: ...` / `cross-thread: ...` shape.
fn classification_provenance(c: &Classification, cross_thread: bool) -> String {
    if cross_thread {
        return "rr-driver: cross-thread copy (spec §6.3)".to_string();
    }
    c.source.render_provenance()
}

/// Map an `OriginKind` to a `TerminatorKind` when the kind itself
/// terminates the chain (spec §6.3 step k).
fn kind_to_terminator(kind: OriginKind) -> TerminatorKind {
    match kind {
        OriginKind::Literal => TerminatorKind::Literal,
        OriginKind::Computational => TerminatorKind::Computational,
        OriginKind::FieldAccess | OriginKind::IndexAccess | OriginKind::FunctionCall | OriginKind::FunctionReturn => {
            TerminatorKind::Computational
        }
        OriginKind::CrossThreadCopy => TerminatorKind::ReadFromExternal,
        OriginKind::Unknown => TerminatorKind::UnknownSource,
        OriginKind::TrivialCopy | OriginKind::ParameterPass | OriginKind::ReturnCapture => {
            TerminatorKind::UnknownSource
        }
    }
}

/// Call `ReplayQuery::EvaluateWithAddress` and parse the reply.
fn evaluate_with_address(
    session: &mut RecreatorReplaySession,
    expression: &str,
) -> Result<EvaluateAddressResponse, OriginError> {
    let raw = session
        .stable
        .dispatch_replay_query(ReplayQuery::EvaluateWithAddress {
            expression: expression.to_string(),
        })
        .map_err(|e| {
            OriginError::new(
                OriginErrorCode::InvalidVariablePath,
                format!("EvaluateWithAddress(`{expression}`) failed: {e}"),
            )
        })?;
    serde_json::from_str::<EvaluateAddressResponse>(&raw).map_err(|e| {
        OriginError::new(
            OriginErrorCode::InvalidVariablePath,
            format!("EvaluateWithAddress reply not parseable: {e}; raw=`{raw}`"),
        )
    })
}

/// Read the current PC's (path, line) by re-using the existing
/// `LoadLocation` query. The native-backend worker's
/// `LoadLocation` already returns a `Location` derived from the PC
/// (it walks DWARF internally).
fn load_current_location(
    session: &mut RecreatorReplaySession,
    _expr_loader: &mut ExprLoader,
) -> Result<Location, OriginError> {
    let raw = session
        .stable
        .dispatch_replay_query(ReplayQuery::LoadLocation)
        .map_err(|e| OriginError::new(OriginErrorCode::UnsupportedBackend, format!("LoadLocation failed: {e}")))?;
    serde_json::from_str::<Location>(&raw).map_err(|e| {
        OriginError::new(
            OriginErrorCode::UnsupportedBackend,
            format!("LoadLocation reply not parseable: {e}"),
        )
    })
}

/// Read the currently-selected thread id from the worker.
fn current_thread(session: &mut RecreatorReplaySession) -> Result<u32, OriginError> {
    let raw = session
        .stable
        .dispatch_replay_query(ReplayQuery::CurrentThread)
        .map_err(|e| {
            OriginError::new(
                OriginErrorCode::UnsupportedBackend,
                format!("CurrentThread failed: {e}"),
            )
        })?;
    let trimmed = raw.trim();
    // Accept either a bare number or `{"tid": N}`.
    if let Ok(n) = trimmed.parse::<u32>() {
        return Ok(n);
    }
    serde_json::from_str::<JsonValue>(trimmed)
        .ok()
        .and_then(|v| v.get("tid").and_then(|n| n.as_u64()).map(|n| n as u32))
        .ok_or_else(|| {
            OriginError::new(
                OriginErrorCode::UnsupportedBackend,
                format!("CurrentThread reply not parseable: `{trimmed}`"),
            )
        })
}

/// Step the replay session forward one source line so DWARF location
/// lists place each operand variable in a known register/memory
/// location (spec §6.3 "Operand snapshots on RR backend"). On worker
/// failure we log and proceed; the operand snapshots will simply be
/// empty for this hop.
fn operand_re_execute(session: &mut RecreatorReplaySession) {
    // `Next` (DAP "step over") is the closest analogue to "one source
    // line forward step". For a Computational hop the assignment
    // statement spans the rest of the current source line; one
    // `Next` puts us past the end of the statement, where DWARF
    // location lists place each operand in a known register/memory
    // location.
    let _ = session.stable.dispatch_replay_query(ReplayQuery::Step {
        action: crate::task::Action::Next,
        forward: true,
    });
}

/// Collect operand snapshots for a Computational hop. The classifier
/// returns the operand identifiers in `Classification::operand_snapshots`;
/// we evaluate each one against the worker via `LoadValue`. The result
/// is capped at `ORIGIN_OPERAND_SNAPSHOT_CAP` per spec §6.1.
fn collect_operand_snapshots(
    session: &mut RecreatorReplaySession,
    classification: &Classification,
    step_id: i64,
) -> (Vec<OperandSnapshot>, bool) {
    let mut out: Vec<OperandSnapshot> = Vec::new();
    let cap = crate::task::ORIGIN_OPERAND_SNAPSHOT_CAP;
    let operands = &classification.operand_snapshots;
    let mut truncated = false;
    for name in operands {
        if out.len() >= cap {
            truncated = true;
            break;
        }
        let raw = match session.stable.dispatch_replay_query(ReplayQuery::LoadValue {
            expression: name.to_string(),
            lang: crate::lang::Lang::C,
            depth_limit: Some(3),
        }) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let value = match serde_json::from_str::<crate::value::ValueRecordWithType>(&raw) {
            Ok(v) => v,
            Err(_) => continue,
        };
        out.push(OperandSnapshot {
            name: name.to_string(),
            value,
            source_step: step_id,
        });
    }
    (out, truncated)
}

/// Track a per-source-file digest for the continuation-token integrity
/// check (spec §5.3.1 step 3). Mirrors the helper in `db.rs`.
fn track_source_digest(
    digests: &mut Vec<SourceDigest>,
    probe_path: &std::path::Path,
    origin: SourceOrigin,
    meta_dat_sources_root: Option<&std::path::Path>,
) {
    let path_str = probe_path.to_string_lossy().to_string();
    if digests.iter().any(|d| d.path == path_str) {
        return;
    }
    let (origin_kind, digest_path) = match origin {
        SourceOrigin::BundledMetaData => match meta_dat_sources_root {
            Some(root) => (
                SourceOriginKind::BundledMetaData,
                root.join(probe_path.strip_prefix("/").unwrap_or(probe_path)),
            ),
            None => (SourceOriginKind::BundledMetaData, probe_path.to_path_buf()),
        },
        SourceOrigin::Filesystem => (SourceOriginKind::Filesystem, probe_path.to_path_buf()),
        SourceOrigin::Unavailable => return,
    };
    let bytes = match std::fs::read(&digest_path) {
        Ok(b) => b,
        Err(_) => return,
    };
    digests.push(SourceDigest {
        path: path_str,
        origin: origin_kind,
        sha256_hex: sha256_hex(&bytes),
    });
}

/// Build an opaque continuation token for the chain (spec §5.3.1).
#[allow(clippy::too_many_arguments)]
fn build_continuation_token(
    query_variable: &str,
    query_step_id: i64,
    current_var_name: &str,
    hops_emitted: u32,
    max_hops: u32,
    patterns: &PatternSet,
    source_digests: Vec<SourceDigest>,
) -> Result<String, OriginError> {
    let token = OriginContinuationToken {
        v: OriginContinuationToken::CURRENT_VERSION,
        query_variable: query_variable.to_string(),
        query_step_id,
        current_step: query_step_id,
        current_frame: -1,
        current_var_name: current_var_name.to_string(),
        hops_emitted,
        max_hops,
        patterns_fingerprint: patterns.fingerprint().hex.clone(),
        source_digests,
        issued_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
    };
    token.encode()
}

#[cfg(test)]
#[allow(
    clippy::assertions_on_constants,
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic
)]
mod tests {
    use super::*;

    #[test]
    fn rr_default_max_hops_is_below_materialized() {
        // Sanity: the M11 default must be strictly lower than the M2
        // materialized default (16). Spec §6.3 motivates this — each
        // RR hop costs a reverse-continue. The assert intentionally
        // uses a constant comparison; `assertions_on_constants` is
        // suppressed because the goal is to wedge a compile-time
        // contract between the two constants (so a refactor that
        // pushes the RR default up to 16 trips this test).
        const _ASSERT_DEFAULTS_DIFFER: () = assert!(RR_DEFAULT_MAX_HOPS < crate::task::DEFAULT_ORIGIN_MAX_HOPS);
        assert!(RR_DEFAULT_MAX_HOPS < crate::task::DEFAULT_ORIGIN_MAX_HOPS);
    }

    #[test]
    fn rr_per_hop_wall_clock_cap_is_finite() {
        // We must have a non-zero wall-clock cap so the loop can't hang
        // forever on a sparse-write address.
        assert!(RR_PER_HOP_WALL_CLOCK_MS > 0);
    }

    #[test]
    fn reverse_continue_response_parses_bare_string() {
        let r = ReverseContinueResponse::from_raw("\"watchpoint\"");
        assert_eq!(r.reason, "watchpoint");
        assert!(r.hit_watchpoint());
        assert!(!r.hit_recording_start());
    }

    #[test]
    fn reverse_continue_response_parses_envelope() {
        let r = ReverseContinueResponse::from_raw("{\"reason\":\"recording-start\"}");
        assert_eq!(r.reason, "recording-start");
        assert!(r.hit_recording_start());
        assert!(!r.hit_watchpoint());
    }

    #[test]
    fn parse_watchpoint_id_accepts_bare_number() {
        let id = parse_watchpoint_id("7").expect("parses bare number");
        assert_eq!(id, 7);
    }

    #[test]
    fn parse_watchpoint_id_accepts_object_with_id() {
        let id = parse_watchpoint_id("{\"id\": 9}").expect("parses envelope");
        assert_eq!(id, 9);
    }

    #[test]
    fn classifier_lang_for_path_handles_c_cpp_rust_nim_go() {
        assert!(matches!(classifier_lang_for_path("main.c"), Some(ClassifierLang::C)));
        assert!(matches!(
            classifier_lang_for_path("main.cpp"),
            Some(ClassifierLang::Cpp)
        ));
        assert!(matches!(
            classifier_lang_for_path("main.rs"),
            Some(ClassifierLang::Rust)
        ));
        assert!(matches!(
            classifier_lang_for_path("main.nim"),
            Some(ClassifierLang::Nim)
        ));
        assert!(matches!(classifier_lang_for_path("main.go"), Some(ClassifierLang::Go)));
        assert!(classifier_lang_for_path("main.d").is_none());
        assert!(classifier_lang_for_path("main.lean").is_none());
    }

    #[test]
    fn kind_to_terminator_round_trip() {
        assert!(matches!(
            kind_to_terminator(OriginKind::Literal),
            TerminatorKind::Literal
        ));
        assert!(matches!(
            kind_to_terminator(OriginKind::Computational),
            TerminatorKind::Computational
        ));
        assert!(matches!(
            kind_to_terminator(OriginKind::FieldAccess),
            TerminatorKind::Computational
        ));
    }
}
