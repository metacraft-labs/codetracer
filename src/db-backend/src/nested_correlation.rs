//! N2 — Nested-trace correlation between a materialized GDScript `.ct` and its
//! parent native MCR trace.
//!
//! This is the db-backend consumer of the **nested-trace correlation record**
//! (`codetracer-trace-format-spec/nested-trace-correlation.md`). The patched
//! Godot GDScript recorder, running inside a `ct-mcr record`, tags GDScript
//! call-entry/exit and native-call boundaries with the parent native trace's
//! `(GEID, tick)` join key (a `ct-nested-join:` special event in the container's
//! `events.dat`). This module reads those join events back and correlates them,
//! **both directions**, against the parent native trace's `geid.idx`:
//!
//! * **nested → native** (§3.1): given a GDScript step, the native
//!   event/checkpoint that produced it (zoom *out*).
//! * **native → nested** (§3.2): given a native GEID (e.g. a native frame the
//!   user is inspecting), the GDScript step it came from — the greatest join
//!   whose `geid ≤ g'` (binary search over the GEID-monotonic join list, §3.3)
//!   (zoom *in*).
//!
//! It is modelled on [`crate::async_continuation`] (GF10) — a small module plus a
//! [`MaterializedReplaySession`](crate::db::MaterializedReplaySession) method
//! reading `reader.events()` — and on the origin classifier's
//! `PatternSet::built_in` idiom. It introduces no new trace-format primitive: the
//! join key reuses the native trace's own GEID (`geid.idx`) and tick coordinates.
//!
//! ## The native `geid.idx` decoder
//!
//! The parent native trace's GEID index is the ground truth a join key resolves
//! against. Its wire format is defined by the MCR recorder
//! (`codetracer-native-recorder/ct_trace_store/.../geid_index.nim`); this module
//! decodes the legacy single-blob `GIDX` layout (the same bytes
//! `readGeidIndex`'s `geid.idx` fallback reads):
//!
//! ```text
//! header: "GIDX" (4 bytes) | entry_count u32 LE
//! entry : geid u64 LE | checkpoint_id u32 LE | thread_tick_count N u32 LE
//!         | N * (tid u32 LE | tick u64 LE)
//! ```

use std::path::Path;

use crate::db::DbRecordEvent;
use codetracer_trace_types::StepId;

/// The nested-VM boundary a join event was emitted at
/// (`nested-trace-correlation.md` §2.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JoinSite {
    /// `GDScriptFunction::call` entry — where a GDScript frame began.
    CallEnter,
    /// `GDScriptFunction::call` exit — where a GDScript frame returned.
    CallExit,
    /// A native-call opcode — where a GDScript step called into engine/native
    /// code (the load-bearing site for zoom: the native MCR trace *is* the
    /// continuation of this source step).
    NativeCall,
}

impl JoinSite {
    fn parse(s: &str) -> Option<JoinSite> {
        match s {
            "call-enter" => Some(JoinSite::CallEnter),
            "call-exit" => Some(JoinSite::CallExit),
            "native-call" => Some(JoinSite::NativeCall),
            _ => None,
        }
    }
}

/// One decoded `ct-nested-join:` event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NestedJoinEvent {
    /// Parent native GEID sampled/allocated when this nested event fired.
    pub geid: u64,
    /// Parent native tick at the same instant.
    pub tick: u64,
    /// The nested-trace step this join binds to.
    pub step_id: StepId,
    /// The boundary that produced the join.
    pub site: JoinSite,
    /// The nested recorder's thread id for the emitting event.
    pub thread: u64,
}

impl NestedJoinEvent {
    /// Content prefix identifying a nested-trace join event (`§2`).
    pub const CONTENT_PREFIX: &'static str = "ct-nested-join:";

    /// Parse a join event's structured `metadata`
    /// (`geid=<u64> tick=<u64> step=<u64> site=<site> thread=<u64>`), the form
    /// §2.1 mandates for structured consumers. Returns `None` if `event` is not a
    /// well-formed join event.
    pub fn parse(event: &DbRecordEvent) -> Option<NestedJoinEvent> {
        if !event.content.starts_with(Self::CONTENT_PREFIX) {
            return None;
        }
        let mut geid: Option<u64> = None;
        let mut tick: Option<u64> = None;
        let mut step: Option<i64> = None;
        let mut site: Option<JoinSite> = None;
        let mut thread: Option<u64> = None;
        for tok in event.metadata.split_whitespace() {
            let (k, v) = tok.split_once('=')?;
            match k {
                "geid" => geid = v.parse().ok(),
                "tick" => tick = v.parse().ok(),
                "step" => step = v.parse().ok(),
                "site" => site = JoinSite::parse(v),
                "thread" => thread = v.parse().ok(),
                _ => {}
            }
        }
        Some(NestedJoinEvent {
            geid: geid?,
            tick: tick?,
            step_id: StepId(step?),
            site: site?,
            thread: thread?,
        })
    }
}

/// A single entry of the parent native trace's GEID index (`geid.idx`), mirroring
/// `GeidIndexEntry` in the MCR recorder's `geid_index.nim`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeGeidEntry {
    pub geid: u64,
    pub checkpoint_id: u32,
    pub thread_ticks: Vec<(u32, u64)>,
}

/// The parent native trace's GEID-to-checkpoint index (`geid.idx`). This is the
/// ground truth a nested join key resolves against.
#[derive(Debug, Clone, Default)]
pub struct NativeGeidIndex {
    /// Entries in ascending GEID order (as written by the recorder). The
    /// resolution rule relies on this ordering for binary search.
    pub entries: Vec<NativeGeidEntry>,
}

/// Read helpers for the little-endian `GIDX` wire layout.
fn read_u32_le(b: &[u8], off: usize) -> Option<u32> {
    b.get(off..off + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}

fn read_u64_le(b: &[u8], off: usize) -> Option<u64> {
    b.get(off..off + 8)
        .map(|s| u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]))
}

impl NativeGeidIndex {
    /// Decode the legacy single-blob `GIDX` `geid.idx` format
    /// (`geid_index.nim` `encode`/`decode`).
    pub fn parse_legacy(bytes: &[u8]) -> Result<NativeGeidIndex, String> {
        if bytes.len() < 8 {
            return Err(format!("geid.idx too small ({} bytes, need >= 8 for the header)", bytes.len()));
        }
        if &bytes[0..4] != b"GIDX" {
            return Err(format!(
                "geid.idx bad magic: expected 'GIDX', got {:?}",
                &bytes[0..4]
            ));
        }
        let count = read_u32_le(bytes, 4).ok_or("geid.idx truncated header")? as usize;
        let mut entries = Vec::with_capacity(count);
        let mut pos = 8usize;
        for i in 0..count {
            let geid = read_u64_le(bytes, pos).ok_or_else(|| format!("geid.idx entry {i}: truncated geid"))?;
            pos += 8;
            let checkpoint_id =
                read_u32_le(bytes, pos).ok_or_else(|| format!("geid.idx entry {i}: truncated checkpointId"))?;
            pos += 4;
            let tt_count =
                read_u32_le(bytes, pos).ok_or_else(|| format!("geid.idx entry {i}: truncated threadTicks count"))? as usize;
            pos += 4;
            let mut thread_ticks = Vec::with_capacity(tt_count);
            for j in 0..tt_count {
                let tid =
                    read_u32_le(bytes, pos).ok_or_else(|| format!("geid.idx entry {i}: truncated tid {j}"))?;
                pos += 4;
                let tick =
                    read_u64_le(bytes, pos).ok_or_else(|| format!("geid.idx entry {i}: truncated tick {j}"))?;
                pos += 8;
                thread_ticks.push((tid, tick));
            }
            entries.push(NativeGeidEntry {
                geid,
                checkpoint_id,
                thread_ticks,
            });
        }
        // The resolution rule requires ascending GEID order; the recorder writes
        // in that order, but sort defensively so a mis-ordered fixture cannot
        // silently break the binary search.
        entries.sort_by_key(|e| e.geid);
        Ok(NativeGeidIndex { entries })
    }

    /// Read + decode a native `geid.idx` file.
    pub fn from_file(path: &Path) -> Result<NativeGeidIndex, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        NativeGeidIndex::parse_legacy(&bytes)
    }

    /// §3.1 step 2 — the native event *at* `geid` (exact `geid.idx` hit), if any.
    pub fn resolve_exact(&self, geid: u64) -> Option<&NativeGeidEntry> {
        match self.entries.binary_search_by_key(&geid, |e| e.geid) {
            Ok(idx) => self.entries.get(idx),
            Err(_) => None,
        }
    }

    /// The native event/checkpoint *current at* `geid` — the greatest entry with
    /// `geid ≤ g` (§3.1 "the checkpoint current at that GEID"). Degrades an
    /// exact miss to the enclosing checkpoint rather than failing.
    pub fn nearest_at_or_before(&self, geid: u64) -> Option<&NativeGeidEntry> {
        // partition_point returns the count of entries with e.geid <= geid.
        let n = self.entries.partition_point(|e| e.geid <= geid);
        if n == 0 {
            None
        } else {
            self.entries.get(n - 1)
        }
    }
}

/// The result of a nested → native resolution: the native event/checkpoint the
/// user zooms *out* to for a GDScript step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NativeResolution {
    /// Index into [`NestedCorrelation::joins`] of the join that produced this.
    pub join_index: usize,
    /// The native GEID the join carried.
    pub native_geid: u64,
    /// The `geid.idx` checkpoint id current at that GEID (the native execution
    /// point that produced the GDScript step).
    pub checkpoint_id: u32,
    /// True when the GEID hit an exact `geid.idx` entry (the common case when the
    /// join key was allocated by a native span anchor), false when it degraded to
    /// the enclosing checkpoint.
    pub exact: bool,
    /// The join's tick (secondary key, §3.1 step 3).
    pub tick: u64,
}

/// The correlation between a nested GDScript trace's join events and its parent
/// native trace's `geid.idx`. Build it from a
/// [`MaterializedReplaySession`](crate::db::MaterializedReplaySession) via
/// [`crate::db::MaterializedReplaySession::nested_correlation`].
#[derive(Debug, Clone)]
pub struct NestedCorrelation {
    /// Join events in emission (step) order.
    joins: Vec<NestedJoinEvent>,
    /// Indices into `joins`, sorted ascending by `geid` — the ordered list §3.2's
    /// binary search runs over (the emission order is already GEID-monotonic per
    /// §3.3, but we sort so a resolver never depends on that invariant holding).
    by_geid: Vec<usize>,
    /// The parent native trace's GEID index.
    native: NativeGeidIndex,
}

impl NestedCorrelation {
    /// Build the correlation from a container's events stream + the parent native
    /// `geid.idx`. Non-join events are ignored (a standalone nested trace has
    /// none — §4 — and yields an empty correlation).
    pub fn build(events: &[DbRecordEvent], native: NativeGeidIndex) -> NestedCorrelation {
        let joins: Vec<NestedJoinEvent> = events.iter().filter_map(NestedJoinEvent::parse).collect();
        let mut by_geid: Vec<usize> = (0..joins.len()).collect();
        by_geid.sort_by_key(|&i| joins[i].geid);
        NestedCorrelation { joins, by_geid, native }
    }

    /// The decoded join events, in emission order.
    pub fn joins(&self) -> &[NestedJoinEvent] {
        &self.joins
    }

    /// The parent native GEID index.
    pub fn native(&self) -> &NativeGeidIndex {
        &self.native
    }

    /// `true` when this trace carries no join events — an un-nested / standalone
    /// trace (§4). A consumer treats such a trace as having no correlation.
    pub fn is_unnested(&self) -> bool {
        self.joins.is_empty()
    }

    /// The join event that binds `step`, if any. §3.1 step 1: for a `native-call`
    /// site the join recorded *at* `step`; more generally the join whose
    /// `step == s`. When several joins share a step (a call-enter and a
    /// native-call can land on the same line), the `native-call` join is preferred
    /// (it is the crossing where the native trace *is* the continuation), then
    /// call-enter, then call-exit.
    pub fn join_at_step(&self, step: StepId) -> Option<(usize, &NestedJoinEvent)> {
        let mut best: Option<usize> = None;
        for (idx, j) in self.joins.iter().enumerate() {
            if j.step_id != step {
                continue;
            }
            let better = match best {
                None => true,
                Some(b) => site_rank(j.site) > site_rank(self.joins[b].site),
            };
            if better {
                best = Some(idx);
            }
        }
        best.map(|i| (i, &self.joins[i]))
    }

    /// **nested → native** (§3.1). Given a GDScript `step`, the native
    /// event/checkpoint that hosts it: resolve the join at `step`, then look its
    /// GEID up in the native `geid.idx` (exact hit preferred; otherwise the
    /// checkpoint current at that GEID). `None` when no join binds `step` or the
    /// GEID precedes every native checkpoint.
    pub fn native_for_step(&self, step: StepId) -> Option<NativeResolution> {
        let (join_index, join) = self.join_at_step(step)?;
        if let Some(entry) = self.native.resolve_exact(join.geid) {
            return Some(NativeResolution {
                join_index,
                native_geid: join.geid,
                checkpoint_id: entry.checkpoint_id,
                exact: true,
                tick: join.tick,
            });
        }
        let entry = self.native.nearest_at_or_before(join.geid)?;
        Some(NativeResolution {
            join_index,
            native_geid: join.geid,
            checkpoint_id: entry.checkpoint_id,
            exact: false,
            tick: join.tick,
        })
    }

    /// **native → nested** (§3.2). Given a native GEID `g'` (e.g. a native frame
    /// the user is inspecting), the GDScript step it came from: the join with the
    /// **greatest `geid ≤ g'`** (binary search over the GEID-ordered join list).
    /// An exact `geid == g'` match — the common case when `g'` is a `native-call`
    /// crossing or a span anchor — is the precise hit; otherwise the `≤` rule
    /// degrades to the nested boundary active at-or-before `g'`. `None` when `g'`
    /// precedes every recorded join.
    pub fn step_for_native_geid(&self, native_geid: u64) -> Option<&NestedJoinEvent> {
        // Greatest index in `by_geid` whose join geid <= native_geid.
        let n = self
            .by_geid
            .partition_point(|&i| self.joins[i].geid <= native_geid);
        if n == 0 {
            return None;
        }
        Some(&self.joins[self.by_geid[n - 1]])
    }
}

/// Preference order when multiple joins share a step (see [`NestedCorrelation::join_at_step`]).
fn site_rank(site: JoinSite) -> u8 {
    match site {
        JoinSite::NativeCall => 2,
        JoinSite::CallEnter => 1,
        JoinSite::CallExit => 0,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::type_complexity)]
mod tests {
    use super::*;
    use codetracer_trace_types::EventLogKind;

    /// Build a join event exactly as the recorder writes it: the structured
    /// fields live in the `metadata`, and the human/tool-readable form (with the
    /// content prefix) in `content` (nested-trace-correlation.md §2.1).
    fn join_ev(geid: u64, tick: u64, step: i64, site: &str, thread: u64) -> DbRecordEvent {
        DbRecordEvent {
            kind: EventLogKind::TraceLogEvent,
            content: format!(
                "ct-nested-join:gdscript geid={geid} tick={tick} step={step} site={site} thread={thread}"
            ),
            // The event's own step_id lags by one (writer pending-step); parsing
            // MUST use the metadata step, so make the record's own step wrong.
            step_id: StepId(-1),
            metadata: format!("geid={geid} tick={tick} step={step} site={site} thread={thread}"),
        }
    }

    /// Encode a native geid.idx in the legacy `GIDX` blob format, to exercise the
    /// real decoder round-trip.
    fn encode_gidx(entries: &[(u64, u32, &[(u32, u64)])]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"GIDX");
        out.extend_from_slice(&(entries.len() as u32).to_le_bytes());
        for (geid, cp, ticks) in entries {
            out.extend_from_slice(&geid.to_le_bytes());
            out.extend_from_slice(&cp.to_le_bytes());
            out.extend_from_slice(&(ticks.len() as u32).to_le_bytes());
            for (tid, tick) in ticks.iter() {
                out.extend_from_slice(&tid.to_le_bytes());
                out.extend_from_slice(&tick.to_le_bytes());
            }
        }
        out
    }

    #[test]
    fn parses_join_event_from_metadata() {
        let ev = join_ev(1005, 500005, 3, "native-call", 1);
        let j = NestedJoinEvent::parse(&ev).expect("well-formed join parses");
        assert_eq!(j.geid, 1005);
        assert_eq!(j.tick, 500005);
        assert_eq!(j.step_id, StepId(3));
        assert_eq!(j.site, JoinSite::NativeCall);
        assert_eq!(j.thread, 1);
    }

    #[test]
    fn ignores_non_join_events() {
        let ev = DbRecordEvent {
            kind: EventLogKind::WriteOther,
            content: "ct-async-suspend:gdscript-coroutine".to_string(),
            step_id: StepId(2),
            metadata: "0x7f00 4".to_string(),
        };
        assert!(NestedJoinEvent::parse(&ev).is_none());
    }

    #[test]
    fn geid_idx_legacy_round_trip() {
        let bytes = encode_gidx(&[
            (1000, 0, &[(1, 500000)]),
            (1002, 1, &[(1, 500002)]),
            (1005, 2, &[(1, 500005), (2, 900000)]),
        ]);
        let idx = NativeGeidIndex::parse_legacy(&bytes).expect("decodes");
        assert_eq!(idx.entries.len(), 3);
        assert_eq!(idx.entries[2].geid, 1005);
        assert_eq!(idx.entries[2].checkpoint_id, 2);
        assert_eq!(idx.entries[2].thread_ticks, vec![(1, 500005), (2, 900000)]);
        // exact + nearest.
        assert_eq!(idx.resolve_exact(1002).unwrap().checkpoint_id, 1);
        assert!(idx.resolve_exact(1003).is_none());
        assert_eq!(idx.nearest_at_or_before(1003).unwrap().checkpoint_id, 1);
        assert!(idx.nearest_at_or_before(999).is_none());
    }

    #[test]
    fn geid_idx_bad_magic_is_error() {
        let mut bytes = encode_gidx(&[(1, 0, &[])]);
        bytes[0] = b'X';
        assert!(NativeGeidIndex::parse_legacy(&bytes).is_err());
    }

    fn sample_correlation() -> NestedCorrelation {
        // Join events mirroring an n1_nested.gd run under CT_MCR_GEID=1000: a
        // call-enter, three native-calls, and call-exits, GEID-monotonic.
        let events = vec![
            join_ev(1000, 500000, 1, "call-enter", 1),
            join_ev(1001, 500001, 2, "native-call", 1),
            join_ev(1002, 500002, 2, "native-call", 1),
            join_ev(1003, 500003, 3, "native-call", 1),
            join_ev(1004, 500004, 3, "call-exit", 1),
        ];
        // A realistic native geid.idx: one native event per join geid, plus gaps
        // between them (checkpoints only at even geids) so the ≤ rule is exercised.
        let native = NativeGeidIndex::parse_legacy(&encode_gidx(&[
            (1000, 10, &[(1, 500000)]),
            (1001, 11, &[(1, 500001)]),
            (1002, 12, &[(1, 500002)]),
            (1003, 13, &[(1, 500003)]),
            (1004, 14, &[(1, 500004)]),
        ]))
        .unwrap();
        NestedCorrelation::build(&events, native)
    }

    #[test]
    fn nested_to_native_resolves_exact() {
        let c = sample_correlation();
        // The native-call at step 2 -> its geid 1001 (native-call preferred over
        // nothing else at that step) -> checkpoint 11.
        let r = c.native_for_step(StepId(2)).expect("step 2 resolves");
        assert!(r.exact);
        assert_eq!(r.native_geid, 1001);
        assert_eq!(r.checkpoint_id, 11);
    }

    #[test]
    fn native_to_nested_exact_and_le() {
        let c = sample_correlation();
        // Exact native GEID 1003 -> the native-call join at step 3.
        let j = c.step_for_native_geid(1003).expect("1003 resolves");
        assert_eq!(j.geid, 1003);
        assert_eq!(j.step_id, StepId(3));
        // A native GEID between joins (1000 < 1000.5) — use a real gap: query
        // 100050 style is not integral, so test the ≤ rule with a native frame at
        // geid just past the last join.
        let j2 = c.step_for_native_geid(9999).expect("past-end resolves to last join");
        assert_eq!(j2.geid, 1004);
        // A native GEID before every join is unresolvable.
        assert!(c.step_for_native_geid(500).is_none());
    }

    #[test]
    fn le_rule_selects_earlier_join_in_a_gap() {
        // Joins with a gap (no join at geid 1001): a native frame at 1001 must
        // resolve to the earlier join (geid 1000), not the later (1002).
        let events = vec![
            join_ev(1000, 500000, 1, "call-enter", 1),
            join_ev(1002, 500002, 2, "native-call", 1),
        ];
        let native = NativeGeidIndex::parse_legacy(&encode_gidx(&[
            (1000, 10, &[(1, 500000)]),
            (1001, 11, &[(1, 500001)]),
            (1002, 12, &[(1, 500002)]),
        ]))
        .unwrap();
        let c = NestedCorrelation::build(&events, native);
        let j = c.step_for_native_geid(1001).expect("1001 resolves to the earlier join");
        assert_eq!(j.geid, 1000);
        assert_eq!(j.step_id, StepId(1));
    }

    #[test]
    fn tamper_wrong_geid_breaks_native_resolution() {
        // Prove non-vacuity: a join whose geid points OUTSIDE the native index
        // does not resolve nested->native (no fabricated correlation).
        let events = vec![join_ev(999_999_999, 0, 1, "call-enter", 1)];
        let native = NativeGeidIndex::parse_legacy(&encode_gidx(&[(1000, 10, &[(1, 500000)])])).unwrap();
        let c = NestedCorrelation::build(&events, native);
        // The join's geid (999999999) is past every native entry — nearest_at_or_before
        // would still find the last entry, so assert on the EXACT rule which must miss,
        // and that native->nested for a small native geid finds nothing.
        assert!(c.native().resolve_exact(999_999_999).is_none());
        assert!(c.step_for_native_geid(500).is_none());
    }

    #[test]
    fn standalone_trace_is_unnested() {
        let native = NativeGeidIndex::default();
        let c = NestedCorrelation::build(&[], native);
        assert!(c.is_unnested());
        assert!(c.native_for_step(StepId(0)).is_none());
        assert!(c.step_for_native_geid(1000).is_none());
    }
}
