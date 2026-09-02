//! GF10 — Async continuation links for materialized traces.
//!
//! This module forms [`ContinuationLink`]s from suspend/resume markers a
//! recorder writes into the `.ct` container's events stream, conforming to the
//! CodeTracer async-continuation model — it does NOT invent a parallel scheme:
//!
//! * `ContinuationLink` mirrors HTTP-Request-Panel.md §3.2 (registration /
//!   continuation [`ExecutionPoint`], `context_id`, `link_type`,
//!   `async_thread_id`). For a materialized trace the `ExecutionPoint` is a
//!   `step_id` (§3.2 "For materialized traces: step_id").
//! * [`AsyncLinkRecord`] mirrors Async-Continuation-Algorithms.md §5.1
//!   (`link_type` await = 0), and [`async_links_from`] / [`async_links_to`]
//!   mirror §5.2 — the omniscient-path shape, resolvable by registration or
//!   continuation step.
//! * [`ContinuationPattern`] is the §3.4 plugin system. The built-in
//!   `gdscript-coroutine` pattern's `context_extractor` returns the GDScript
//!   `CallState` pointer (the suspended coroutine frame — analogous to Nim's
//!   `Future[T]` ptr / Python's coroutine object), and its
//!   `continuation_matcher` is the resume marker carrying that same pointer.
//!
//! ## How the GDScript recorder feeds this
//!
//! The patched Godot GDScript VM (metacraft-labs/codetracer-engine-godot,
//! `modules/gdscript/gdscript_ct_trace.cpp`) emits, per `await`:
//!
//! * a SUSPEND marker at the `await` step — an events.dat special event whose
//!   content is `ct-async-suspend:gdscript-coroutine`;
//! * a RESUME marker at the first resumed line — content
//!   `ct-async-resume:gdscript-coroutine`.
//!
//! Both carry, in the event METADATA, `"<context_id_hex> <step_id>"`:
//! `context_id` is the `CallState` pointer (identical at suspend and resume,
//! because `GDScriptFunctionState::resume` re-enters `GDScriptFunction::call`
//! with `&gdfs->state`, the same pointer the suspend recorded), and `step_id`
//! is the exec-stream step the marker refers to (`next_step_index() - 1`).
//!
//! The step id is read from the METADATA rather than the event's own
//! `step_id`, because the writer FFI buffers one "pending step" for
//! late-arriving column/value data, so the event's implicit `step_id` lags the
//! just-registered line by one. The metadata step id matches
//! `reader.step(StepId(n))` indexing exactly.

use serde::{Deserialize, Serialize};

use crate::db::DbRecordEvent;
use codetracer_trace_types::StepId;

/// Kind of async link (HTTP-Request-Panel.md §3.2 `link_type`). The `u8`
/// discriminants match Async-Continuation-Algorithms.md §5.1
/// (`await=0, callback=1, then=2, spawn=3`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LinkType {
    Await,
    Callback,
    Then,
    Spawn,
    Fork,
}

impl LinkType {
    /// The `AsyncLinkRecord.link_type` wire byte (§5.1).
    pub fn as_u8(self) -> u8 {
        match self {
            LinkType::Await => 0,
            LinkType::Callback => 1,
            LinkType::Then => 2,
            LinkType::Spawn => 3,
            LinkType::Fork => 4,
        }
    }
}

/// A point in execution a link refers to. For a materialized trace this is a
/// `step_id` (HTTP-Request-Panel.md §3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutionPoint {
    pub step_id: StepId,
}

/// A connection between where an async operation was registered (`await`
/// suspend) and where its continuation executed (resume), keyed by the async
/// `context_id`. HTTP-Request-Panel.md §3.2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContinuationLink {
    pub id: u64,
    pub registration: ExecutionPoint,
    pub continuation: ExecutionPoint,
    pub context_id: u64,
    pub link_type: LinkType,
    pub async_thread_id: u64,
}

/// The omniscient-path record shape (Async-Continuation-Algorithms.md §5.1).
/// For a materialized trace the `*_geid` coordinates are step ids.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AsyncLinkRecord {
    pub registration_step: StepId,
    pub continuation_step: StepId,
    pub context_id: u64,
    pub link_type: u8,
    pub async_thread_id: u64,
}

impl From<&ContinuationLink> for AsyncLinkRecord {
    fn from(link: &ContinuationLink) -> Self {
        AsyncLinkRecord {
            registration_step: link.registration.step_id,
            continuation_step: link.continuation.step_id,
            context_id: link.context_id,
            link_type: link.link_type.as_u8(),
            async_thread_id: link.async_thread_id,
        }
    }
}

/// One extensible async pattern (HTTP-Request-Panel.md §3.4). It recognises a
/// recorder's suspend/resume markers by their event content prefix and extracts
/// the `context_id` (+ the marker's step) from the event metadata.
///
/// Kept deliberately small: the marker vocabulary is a stable string contract
/// between recorder and loader, so a new language's pattern is one more entry in
/// [`ContinuationPatternSet::built_in`] with its own tags and `link_type`.
#[derive(Debug, Clone)]
pub struct ContinuationPattern {
    /// Pattern name, e.g. `"gdscript-coroutine"` (mirrors the built-in
    /// `nim-async` / `python-asyncio` / `js-promise` names).
    pub name: &'static str,
    /// Event content prefix marking a registration (suspend).
    suspend_tag: &'static str,
    /// Event content prefix marking a continuation (resume).
    resume_tag: &'static str,
    /// The link kind this pattern produces.
    link_type: LinkType,
}

/// A parsed marker: which pattern, whether it is a suspend or resume, the async
/// context id, and the step the marker refers to.
#[derive(Debug, Clone, Copy)]
struct ParsedMarker {
    pattern_index: usize,
    is_suspend: bool,
    context_id: u64,
    step_id: StepId,
}

impl ContinuationPattern {
    /// The GDScript coroutine/`await` pattern (GF10). `context_extractor` = the
    /// `CallState` pointer carried in the marker metadata.
    pub fn gdscript_coroutine() -> ContinuationPattern {
        ContinuationPattern {
            name: "gdscript-coroutine",
            suspend_tag: "ct-async-suspend:gdscript-coroutine",
            resume_tag: "ct-async-resume:gdscript-coroutine",
            link_type: LinkType::Await,
        }
    }

    /// Parse `metadata` == `"<context_id_hex> <step_id>"` into (context_id,
    /// step_id). Returns `None` if the shape is not recognised.
    fn extract_context(metadata: &str) -> Option<(u64, StepId)> {
        let mut it = metadata.split_whitespace();
        let ctx_tok = it.next()?;
        let step_tok = it.next()?;
        let ctx_hex = ctx_tok.strip_prefix("0x").unwrap_or(ctx_tok);
        let context_id = u64::from_str_radix(ctx_hex, 16).ok()?;
        let step = step_tok.parse::<i64>().ok()?;
        Some((context_id, StepId(step)))
    }
}

/// The registered set of continuation patterns. [`built_in`] mirrors the
/// PatternSet::built_in convention used elsewhere (origin classifier).
#[derive(Debug, Clone)]
pub struct ContinuationPatternSet {
    patterns: Vec<ContinuationPattern>,
}

impl Default for ContinuationPatternSet {
    fn default() -> Self {
        ContinuationPatternSet::built_in()
    }
}

impl ContinuationPatternSet {
    /// All built-in patterns. Today: `gdscript-coroutine` (GF10). The Nim /
    /// Python / JS built-ins named in HTTP-Request-Panel.md §3.4 attach to
    /// continuous (MCR/RR) traces via register/continuation function matching
    /// and are not part of this materialized-trace marker path.
    pub fn built_in() -> ContinuationPatternSet {
        ContinuationPatternSet {
            patterns: vec![ContinuationPattern::gdscript_coroutine()],
        }
    }

    /// The patterns in this set.
    pub fn patterns(&self) -> &[ContinuationPattern] {
        &self.patterns
    }

    /// Classify one event against the registered patterns.
    fn parse_event(&self, event: &DbRecordEvent) -> Option<ParsedMarker> {
        for (idx, pat) in self.patterns.iter().enumerate() {
            let is_suspend = event.content.starts_with(pat.suspend_tag);
            let is_resume = event.content.starts_with(pat.resume_tag);
            if !is_suspend && !is_resume {
                continue;
            }
            let (context_id, step_id) = ContinuationPattern::extract_context(&event.metadata)?;
            return Some(ParsedMarker {
                pattern_index: idx,
                is_suspend,
                context_id,
                step_id,
            });
        }
        None
    }

    /// Form [`ContinuationLink`]s from the recorded events.
    ///
    /// Algorithm (Async-Continuation-Algorithms.md §4.2, adapted to a
    /// materialized trace whose markers are already recorded): scan events in
    /// order; each suspend marker opens a pending registration keyed by
    /// `context_id`; the next resume marker with the same `context_id` closes it
    /// into a link. Pairing is FIFO per context so re-`await` (a coroutine that
    /// suspends more than once) chains correctly.
    ///
    /// `async_thread_id` groups links that share a `context_id` into one logical
    /// async thread (a coroutine's re-awaits), assigned in first-seen order.
    pub fn discover_links(&self, events: &[DbRecordEvent]) -> Vec<ContinuationLink> {
        use std::collections::HashMap;
        use std::collections::VecDeque;

        // Pending suspends per context, FIFO.
        let mut pending: HashMap<u64, VecDeque<StepId>> = HashMap::new();
        // Stable async_thread_id per context (first-seen order).
        let mut thread_ids: HashMap<u64, u64> = HashMap::new();
        let mut next_thread_id: u64 = 0;
        let mut links: Vec<ContinuationLink> = Vec::new();

        for event in events {
            let Some(marker) = self.parse_event(event) else {
                continue;
            };
            let async_thread_id = *thread_ids.entry(marker.context_id).or_insert_with(|| {
                let id = next_thread_id;
                next_thread_id += 1;
                id
            });
            if marker.is_suspend {
                pending.entry(marker.context_id).or_default().push_back(marker.step_id);
            } else if let Some(reg_step) = pending.get_mut(&marker.context_id).and_then(|q| q.pop_front()) {
                let link_type = self.patterns[marker.pattern_index].link_type;
                links.push(ContinuationLink {
                    id: links.len() as u64,
                    registration: ExecutionPoint { step_id: reg_step },
                    continuation: ExecutionPoint {
                        step_id: marker.step_id,
                    },
                    context_id: marker.context_id,
                    link_type,
                    async_thread_id,
                });
            }
            // A resume with no matching pending suspend is dropped (an
            // unresolved / cross-trace continuation — §4.2 step 6).
        }

        links
    }
}

/// All continuations registered at `step` (registration.step_id == step).
/// Async-Continuation-Algorithms.md §5.2 `async_links_from`.
pub fn async_links_from(links: &[ContinuationLink], step: StepId) -> Vec<AsyncLinkRecord> {
    links
        .iter()
        .filter(|l| l.registration.step_id == step)
        .map(AsyncLinkRecord::from)
        .collect()
}

/// All registrations that led to the continuation at `step`
/// (continuation.step_id == step). §5.2 `async_links_to`.
pub fn async_links_to(links: &[ContinuationLink], step: StepId) -> Vec<AsyncLinkRecord> {
    links
        .iter()
        .filter(|l| l.continuation.step_id == step)
        .map(AsyncLinkRecord::from)
        .collect()
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use codetracer_trace_types::EventLogKind;

    fn ev(content: &str, metadata: &str) -> DbRecordEvent {
        DbRecordEvent {
            kind: EventLogKind::WriteOther,
            content: content.to_string(),
            // The event's own step_id is intentionally WRONG (the writer's
            // pending-step lag); discover_links must use the metadata step.
            step_id: StepId(-1),
            metadata: metadata.to_string(),
        }
    }

    #[test]
    fn pairs_suspend_and_resume_by_context() {
        let patterns = ContinuationPatternSet::built_in();
        let events = vec![
            ev("ct-async-suspend:gdscript-coroutine", "0x7f00 4"),
            ev("ct-async-resume:gdscript-coroutine", "0x7f00 12"),
        ];
        let links = patterns.discover_links(&events);
        assert_eq!(links.len(), 1);
        let l = links[0];
        assert_eq!(l.registration.step_id, StepId(4));
        assert_eq!(l.continuation.step_id, StepId(12));
        assert_eq!(l.context_id, 0x7f00);
        assert_eq!(l.link_type, LinkType::Await);
        assert_eq!(async_links_from(&links, StepId(4)).len(), 1);
        assert_eq!(async_links_to(&links, StepId(12)).len(), 1);
        assert_eq!(async_links_from(&links, StepId(999)).len(), 0);
    }

    #[test]
    fn two_contexts_form_two_independent_links() {
        let patterns = ContinuationPatternSet::built_in();
        // Two suspends on the SAME step (a nested `await coroutine()`), distinct
        // contexts — must not cross-pair.
        let events = vec![
            ev("ct-async-suspend:gdscript-coroutine", "0xaa 4"),
            ev("ct-async-suspend:gdscript-coroutine", "0xbb 4"),
            ev("ct-async-resume:gdscript-coroutine", "0xaa 12"),
            ev("ct-async-resume:gdscript-coroutine", "0xbb 15"),
        ];
        let links = patterns.discover_links(&events);
        assert_eq!(links.len(), 2);
        let aa = links.iter().find(|l| l.context_id == 0xaa).unwrap();
        let bb = links.iter().find(|l| l.context_id == 0xbb).unwrap();
        assert_eq!(aa.continuation.step_id, StepId(12));
        assert_eq!(bb.continuation.step_id, StepId(15));
        assert_ne!(aa.async_thread_id, bb.async_thread_id);
    }

    #[test]
    fn resume_without_suspend_is_dropped() {
        let patterns = ContinuationPatternSet::built_in();
        let events = vec![ev("ct-async-resume:gdscript-coroutine", "0x1 9")];
        assert!(patterns.discover_links(&events).is_empty());
    }
}
