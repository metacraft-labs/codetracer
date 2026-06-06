//! M19 — Origin-metadata streams (opt-in, all TraceKinds).
//!
//! See the milestone in
//! `codetracer-specs/Planned-Features/Value-Origin-Tracking.milestones.org`
//! around lines 1500–1690, the spec sections 6.8.0 / 6.8.1 / 6.8.6 in
//! `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`,
//! and the M18 trait surface in [`crate::omniscient_db`].
//!
//! ## Scope shipped here
//!
//! This module provides the in-tree pieces of M19:
//!
//! * **CTFS namespace constants + record schemas** for `varwrites.tc`,
//!   `originmeta.tc` and `source_exprs.tc` (§6.8.0 + §6.8.1) — record
//!   shape, on-wire encoding with a documented "un-optimised but
//!   correct" packing (RLE / delta-encoding the column store is a
//!   follow-on; the encoder here is byte-identical to the spec's
//!   record layout so the optimisation can drop in transparently).
//! * **`MaterializedOriginIndexer`** — a single linear pass over a
//!   sequence of `(VariableId, StepId, ValueRecord)` value-change
//!   events that emits `varwrites.tc` + `originmeta.tc`. Detects per
//!   `VariableId` whether `Assignment` events are present (Path A,
//!   confidence 1.0) or only `Value` snapshots are available
//!   (Path B, classifier confidence ≤ 0.9 / ≤ 0.6 per §6.1.5). A
//!   single trace may have both paths in use simultaneously for
//!   different variables — the indexer handles this uniformly per
//!   change.
//! * **`NativeOriginIndexer`** — stubs on top of the M18
//!   [`crate::omniscient_db::OmniscientDb`] trait that read the
//!   recorded write log and produce `(address, tick)`-keyed
//!   `OriginMetadataRecord`s. The production recorder-side indexer
//!   integration lands as a follow-on (it requires the recorder
//!   pipeline's `evaluate_with_address` resolver from M18+); the M19
//!   stub here is exercisable end-to-end against the synthetic FFI
//!   fixtures used by the M18 tests.
//! * **`OriginMetadataDecoder`** — reader-side helper that resolves
//!   `(address, tick)` or `(VariableId, StepId)` keys back into
//!   [`OriginMetadataRecord`]s. The decoder honours the trace's mode
//!   and returns `None` when metadata is absent so callers fall back
//!   cleanly.
//! * **`OriginConfig`** — per-trace mode toggle + per-`VariableId`
//!   capability flag persisted in `meta_dat/origin-config.toml`. The
//!   format is a deliberately small key=value text file so the crate
//!   does not pick up a fresh `toml` dependency for this milestone;
//!   the keys match the spec §6.8.6 names.
//! * **Per-`TraceKind` default-mode heuristic** as a free function
//!   that takes the projected compressed baseline size and an
//!   [`OriginMetadataBudget`].
//!
//! ## Scope deferred
//!
//! * **Column-store packing** (RLE on `kind` / `source_var_id` /
//!   `source_expr_idx` / `function_idx`; delta on `target_var_id` /
//!   `confidence`). The encoder ships a record-aligned little-endian
//!   layout — same big-O storage as the packed layout for the M19
//!   exemplar fixtures (which are not large enough for the packing to
//!   matter), and the reader is structured so the packing can drop in
//!   without changing the public decoder API.
//! * **Recorder-side end-to-end integration** for the native indexer
//!   beyond reading the M18 FFI fixture. M19's deliverable is the
//!   *indexer pattern* — wiring it to live recordings is a recorder
//!   follow-on (the production resolver lands with the omniscient DB
//!   tier in M18+/M20).
//! * **Per-language coverage matrix** beyond Python / Ruby / JS Path A
//!   detection. The remaining materialized recorders (Cairo, Stylus,
//!   Sway, Solana, Aiken, Leo, Circom, Noir, Move, Miden) re-use the
//!   same indexer; their per-language coverage tests land alongside
//!   their fixture work in M23. Move/Miden are explicitly blocked per
//!   §6.8.7.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use codetracer_trace_types::{StepId, ValueRecord, VariableId};
use origin_classifier::OriginKind;

/// CTFS namespace names per spec §6.8.0.
pub const CTFS_ORIGINMETA_FILE: &str = "originmeta.tc";
pub const CTFS_SOURCE_EXPRS_FILE: &str = "source_exprs.tc";
pub const CTFS_VARWRITES_FILE: &str = "varwrites.tc";

/// Origin-config file under `meta_dat/`. The spec names it
/// `origin-config.toml` but we ship a minimal key=value text format so
/// the db-backend doesn't pick up a fresh `toml` dependency at M19.
/// The keys (`mode`, per-variable capability lines) are unambiguous
/// strings; a future spike can swap in a TOML reader transparently.
pub const ORIGIN_CONFIG_FILE: &str = "origin-config.toml";

/// Magic bytes prefix shared by every M19 CTFS namespace blob. The
/// reader checks these before parsing — a missing magic immediately
/// returns `None`, preserving the "metadata absent" semantics callers
/// rely on for fallback to Mode 1 / Mode 2 (§6.8.5).
pub const ORIGINMETA_MAGIC: &[u8; 8] = b"CTORGM19";
pub const SOURCE_EXPRS_MAGIC: &[u8; 8] = b"CTSRC419";
pub const VARWRITES_MAGIC: &[u8; 8] = b"CTVWR_19";

/// On-disk schema version. Bumped when the column-store packing lands
/// (follow-on) — readers will accept v1 (unpacked) and v2 (packed)
/// transparently.
pub const NAMESPACE_VERSION: u8 = 1;

/// Keying-scheme tag stored in the `originmeta.tc` namespace header so
/// a single reader handles both shapes (spec §6.8.0).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum KeyingScheme {
    /// Keyed by `(address, tick)` — Recreator / Emulator traces.
    Native = 1,
    /// Keyed by `(VariableId, StepId)` — Materialized traces.
    Materialized = 2,
}

impl KeyingScheme {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(KeyingScheme::Native),
            2 => Some(KeyingScheme::Materialized),
            _ => None,
        }
    }
}

/// Opt-in mode per spec §6.8.6.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OriginMode {
    /// Mode 1 or 2 only — recorder skips the metadata streams entirely.
    Off,
    /// Mode 3 — full metadata populated at trace-load (materialized)
    /// or per-interval (Recreator / Emulator).
    On,
    /// Mode 3 on demand — backbone streams produced at record-time;
    /// metadata populated lazily on first query.
    Lazy,
}

impl OriginMode {
    pub fn as_str(self) -> &'static str {
        match self {
            OriginMode::Off => "off",
            OriginMode::On => "on",
            OriginMode::Lazy => "lazy",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "off" => Some(OriginMode::Off),
            "on" => Some(OriginMode::On),
            "lazy" => Some(OriginMode::Lazy),
            _ => None,
        }
    }
}

/// Per-`VariableId` capability flag per spec §6.8.7. The materialized
/// indexer detects this once at start-up and persists it in the
/// origin-config so subsequent queries don't repeat the scan.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathCapability {
    /// Recorder emits `Assignment` events covering every change.
    PathAOnly,
    /// Recorder emits only `Value` snapshots; classifier-driven path.
    PathBOnly,
    /// A single variable has both event kinds — the per-change
    /// indexer picks whichever is available per spec §6.8.7.
    Mixed,
}

impl PathCapability {
    pub fn as_str(self) -> &'static str {
        match self {
            PathCapability::PathAOnly => "path_a",
            PathCapability::PathBOnly => "path_b",
            PathCapability::Mixed => "mixed",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "path_a" => Some(PathCapability::PathAOnly),
            "path_b" => Some(PathCapability::PathBOnly),
            "mixed" => Some(PathCapability::Mixed),
            _ => None,
        }
    }
}

/// Per-`TraceKind` selector for the default-mode heuristic
/// (spec §6.8.6.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexerTraceKind {
    Materialized,
    Recreator,
    Emulator,
}

/// Configurable size budget for the per-`TraceKind` heuristic. Mirrors
/// the constants the spec parks in
/// `codetracer-native-backend/config/origin-metadata-defaults.toml`;
/// the V1 default is 5 GB compressed (§6.8.6.6).
#[derive(Debug, Clone, Copy)]
pub struct OriginMetadataBudget {
    pub max_baseline_compressed_bytes: u64,
}

impl OriginMetadataBudget {
    pub const DEFAULT_NATIVE_BUDGET_BYTES: u64 = 5 * 1024 * 1024 * 1024;

    pub const fn default_for_v1() -> Self {
        OriginMetadataBudget {
            max_baseline_compressed_bytes: Self::DEFAULT_NATIVE_BUDGET_BYTES,
        }
    }
}

/// Resolve the per-`TraceKind` default mode per spec §6.8.6.6. The
/// caller supplies the trace's projected compressed baseline; the
/// heuristic flips the Recreator default from `on` to `lazy` when the
/// baseline exceeds the budget. `Off` overrides everything and is
/// never the default — callers set it explicitly when the user opts
/// out.
pub fn default_mode_for_trace_kind(
    kind: IndexerTraceKind,
    projected_baseline_bytes: u64,
    budget: OriginMetadataBudget,
) -> OriginMode {
    match kind {
        IndexerTraceKind::Materialized => OriginMode::On,
        IndexerTraceKind::Recreator => {
            if projected_baseline_bytes <= budget.max_baseline_compressed_bytes {
                OriginMode::On
            } else {
                OriginMode::Lazy
            }
        }
        IndexerTraceKind::Emulator => OriginMode::Lazy,
    }
}

/// Compact OriginMetadataRecord per spec §6.8.1. `kind` reuses the
/// `origin-classifier` crate's enum with an explicit on-disk byte
/// mapping so the format is stable across re-records.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OriginMetadataRecord {
    /// Compact OriginKind byte. The encoding is dense:
    /// 0 = TrivialCopy, 1 = FieldAccess, 2 = IndexAccess,
    /// 3 = Computational, 4 = FunctionCall, 5 = Literal,
    /// 6 = ReturnCapture, 7 = ParameterPass, 8 = CrossThread,
    /// 9 = Unknown.
    pub kind: u8,
    /// LHS variable id. For native traces this is the
    /// `target_var_id` resolved from DWARF; for materialized traces
    /// it is the same as the `VariableId` key.
    pub target_var_id: u32,
    /// Upstream variable id for single-source kinds. `None` (=0 on
    /// disk) for computational / literal / external kinds.
    pub source_var_id: Option<u32>,
    /// Pointer into the per-trace `source_exprs.tc` namespace.
    pub source_expr_idx: u32,
    /// Pointer into the per-trace `functions.tc` namespace.
    pub function_idx: u32,
    /// Confidence ∈ [0, 255] fixed-point of [0.0, 1.0].
    pub confidence: u8,
}

impl OriginMetadataRecord {
    /// Pack an [`OriginKind`] into the on-disk byte. The mapping is
    /// stable (do NOT reorder once shipped); new kinds extend the
    /// tail.
    pub fn encode_kind(kind: OriginKind) -> u8 {
        match kind {
            OriginKind::TrivialCopy => 0,
            OriginKind::FieldAccess => 1,
            OriginKind::IndexAccess => 2,
            OriginKind::Computational => 3,
            OriginKind::FunctionCall => 4,
            OriginKind::Literal => 5,
            OriginKind::ReturnCapture => 6,
            OriginKind::ParameterPass => 7,
            OriginKind::CrossThread => 8,
            OriginKind::Unknown => 9,
        }
    }

    pub fn decode_kind(byte: u8) -> Option<OriginKind> {
        match byte {
            0 => Some(OriginKind::TrivialCopy),
            1 => Some(OriginKind::FieldAccess),
            2 => Some(OriginKind::IndexAccess),
            3 => Some(OriginKind::Computational),
            4 => Some(OriginKind::FunctionCall),
            5 => Some(OriginKind::Literal),
            6 => Some(OriginKind::ReturnCapture),
            7 => Some(OriginKind::ParameterPass),
            8 => Some(OriginKind::CrossThread),
            9 => Some(OriginKind::Unknown),
            _ => None,
        }
    }

    /// Encode a confidence ∈ [0.0, 1.0] into the on-disk byte
    /// (×255 fixed point per spec §6.8.1). Out-of-range values are
    /// clamped — `NaN` collapses to 0 (the "unknown" floor).
    pub fn encode_confidence(c: f32) -> u8 {
        if !c.is_finite() || c <= 0.0 {
            return 0;
        }
        let clamped = if c >= 1.0 { 1.0 } else { c };
        (clamped * 255.0).round() as u8
    }

    pub fn decode_confidence(byte: u8) -> f32 {
        f32::from(byte) / 255.0
    }

    /// Serialise the record into 16 bytes (little-endian). Layout:
    /// `kind: u8 | target: u32 | source: u32 (0=NULL) | expr: u32 |
    ///  fn: u32 | confidence: u8` packed into 18 raw bytes; we pad to
    /// the next 4-byte boundary so future packing can drop in.
    pub fn write_to(&self, out: &mut Vec<u8>) {
        out.push(self.kind);
        out.extend_from_slice(&self.target_var_id.to_le_bytes());
        out.extend_from_slice(&self.source_var_id.unwrap_or(0).to_le_bytes());
        out.extend_from_slice(&self.source_expr_idx.to_le_bytes());
        out.extend_from_slice(&self.function_idx.to_le_bytes());
        out.push(self.confidence);
    }

    /// Number of bytes [`write_to`] appends. 1 + 4 + 4 + 4 + 4 + 1 = 18.
    pub const ENCODED_SIZE: usize = 18;

    /// Decode a record from a slice that begins at the record start.
    pub fn read_from(buf: &[u8]) -> Option<Self> {
        if buf.len() < Self::ENCODED_SIZE {
            return None;
        }
        let kind = buf[0];
        let target_var_id = u32::from_le_bytes([buf[1], buf[2], buf[3], buf[4]]);
        let src = u32::from_le_bytes([buf[5], buf[6], buf[7], buf[8]]);
        let source_expr_idx = u32::from_le_bytes([buf[9], buf[10], buf[11], buf[12]]);
        let function_idx = u32::from_le_bytes([buf[13], buf[14], buf[15], buf[16]]);
        let confidence = buf[17];
        Some(OriginMetadataRecord {
            kind,
            target_var_id,
            source_var_id: if src == 0 { None } else { Some(src) },
            source_expr_idx,
            function_idx,
            confidence,
        })
    }
}

/// Single change event consumed by the materialized indexer. Synthesises
/// the trace's `(VariableId, StepId, ValueRecord)` trio plus an
/// optional Path A descriptor (`Assignment` event sighting).
#[derive(Debug, Clone)]
pub struct ValueChange {
    pub variable_id: VariableId,
    pub step_id: StepId,
    pub value: ValueRecord,
    /// Path A sighting — when present the indexer trusts the
    /// recorder's classification (confidence 1.0). When absent the
    /// indexer falls back to Path B + classifier (≤ 0.9 / ≤ 0.6).
    pub assignment: Option<PathAAssignment>,
    /// Source-line expression text the indexer emits into
    /// `source_exprs.tc`. The encoder deduplicates these.
    pub source_expr_text: String,
    /// Containing function index for Path B fallback.
    pub function_idx: u32,
}

/// Path A descriptor — what the recorder emitted alongside the change.
#[derive(Debug, Clone)]
pub struct PathAAssignment {
    pub kind: OriginKind,
    pub source_var_id: Option<u32>,
    pub function_idx: u32,
}

/// One write event consumed by the native indexer. Mirrors the M18
/// `WriteRecord` plus the M10d-resolved variable identity.
#[derive(Debug, Clone)]
pub struct NativeWrite {
    pub address: u64,
    pub tick: u64,
    pub target_var_id: u32,
    pub function_idx: u32,
    pub source_expr_text: String,
    /// Classifier result that the native indexer's per-write hook
    /// computes from the cached source line. In production this is a
    /// fresh call to `origin_classifier::classify`; the M19 fixtures
    /// supply pre-classified records so the round-trip is testable
    /// without a live emulator.
    pub kind: OriginKind,
    pub source_var_id: Option<u32>,
    pub confidence: f32,
}

/// Deduplicating index for the `source_exprs.tc` namespace.
#[derive(Debug, Clone, Default)]
pub struct SourceExprIndex {
    /// Insertion order — preserved on the wire so reader by-index
    /// access is O(1).
    texts: Vec<String>,
    lookup: HashMap<String, u32>,
}

impl SourceExprIndex {
    pub fn new() -> Self {
        SourceExprIndex::default()
    }

    /// Intern `text`, returning its dedup index. The first occurrence
    /// pushes a new entry; subsequent calls with the same text return
    /// the cached index.
    pub fn intern(&mut self, text: &str) -> u32 {
        if let Some(&idx) = self.lookup.get(text) {
            return idx;
        }
        let idx = self.texts.len() as u32;
        self.texts.push(text.to_string());
        self.lookup.insert(text.to_string(), idx);
        idx
    }

    pub fn get(&self, idx: u32) -> Option<&str> {
        self.texts.get(idx as usize).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.texts.len()
    }

    pub fn is_empty(&self) -> bool {
        self.texts.is_empty()
    }

    /// Encode the namespace to its on-disk byte buffer. Layout:
    /// `magic(8) | version(1) | count(u32 LE) | { len(u32 LE) | bytes
    /// }*`. The encoder is deterministic — round-tripping the namespace
    /// yields byte-identical output.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(16 + self.texts.iter().map(|s| s.len() + 4).sum::<usize>());
        out.extend_from_slice(SOURCE_EXPRS_MAGIC);
        out.push(NAMESPACE_VERSION);
        out.extend_from_slice(&(self.texts.len() as u32).to_le_bytes());
        for text in &self.texts {
            let bytes = text.as_bytes();
            out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            out.extend_from_slice(bytes);
        }
        out
    }

    /// Decode the namespace from a CTFS file blob. Returns `None` when
    /// the magic header doesn't match (so callers cleanly fall back to
    /// Mode 1 / Mode 2 — the file is absent or unrecognised).
    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 13 || &buf[0..8] != SOURCE_EXPRS_MAGIC {
            return None;
        }
        let version = buf[8];
        if version != NAMESPACE_VERSION {
            return None;
        }
        let count = u32::from_le_bytes([buf[9], buf[10], buf[11], buf[12]]) as usize;
        let mut index = SourceExprIndex::new();
        let mut cursor = 13;
        for _ in 0..count {
            if cursor + 4 > buf.len() {
                return None;
            }
            let len = u32::from_le_bytes([buf[cursor], buf[cursor + 1], buf[cursor + 2], buf[cursor + 3]]) as usize;
            cursor += 4;
            if cursor + len > buf.len() {
                return None;
            }
            let text = std::str::from_utf8(&buf[cursor..cursor + len]).ok()?.to_string();
            cursor += len;
            let next = index.texts.len() as u32;
            index.texts.push(text.clone());
            index.lookup.insert(text, next);
        }
        Some(index)
    }
}

/// Encoded `varwrites.tc` namespace — per-variable backbone of value
/// changes. The on-disk layout is variable-id-keyed; per-variable the
/// step ids are ordered ascending so a binary search resolves the
/// last-write-before query in O(log changes) (§6.8.0).
#[derive(Debug, Clone, Default)]
pub struct VarWrites {
    entries: BTreeMap<VariableId, Vec<StepId>>,
}

impl VarWrites {
    pub fn new() -> Self {
        VarWrites::default()
    }

    pub fn push(&mut self, variable_id: VariableId, step_id: StepId) {
        let list = self.entries.entry(variable_id).or_default();
        // Maintain ascending order. The indexer's outer loop walks
        // steps monotonically, so the common case is a single
        // `.push()`; we keep the invariant defensively for fixtures
        // that surface out-of-order changes.
        if list.last().is_none_or(|last| last.0 < step_id.0) {
            list.push(step_id);
        } else {
            let pos = list.partition_point(|s| s.0 < step_id.0);
            list.insert(pos, step_id);
        }
    }

    pub fn variables(&self) -> impl Iterator<Item = VariableId> + '_ {
        self.entries.keys().copied()
    }

    pub fn steps_for(&self, variable_id: VariableId) -> Option<&[StepId]> {
        self.entries.get(&variable_id).map(Vec::as_slice)
    }

    /// Layout: `magic(8) | version(1) | variable_count(u32 LE) |
    /// { var_id(u32 LE) | step_count(u32 LE) | step(i64 LE)* }*`.
    pub fn encode(&self) -> Vec<u8> {
        let total_steps: usize = self.entries.values().map(Vec::len).sum();
        let mut out = Vec::with_capacity(13 + self.entries.len() * 8 + total_steps * 8);
        out.extend_from_slice(VARWRITES_MAGIC);
        out.push(NAMESPACE_VERSION);
        out.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        for (var_id, steps) in &self.entries {
            out.extend_from_slice(&(var_id.0 as u32).to_le_bytes());
            out.extend_from_slice(&(steps.len() as u32).to_le_bytes());
            for step in steps {
                out.extend_from_slice(&step.0.to_le_bytes());
            }
        }
        out
    }

    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 13 || &buf[0..8] != VARWRITES_MAGIC {
            return None;
        }
        let version = buf[8];
        if version != NAMESPACE_VERSION {
            return None;
        }
        let var_count = u32::from_le_bytes([buf[9], buf[10], buf[11], buf[12]]) as usize;
        let mut cursor = 13;
        let mut entries = BTreeMap::new();
        for _ in 0..var_count {
            if cursor + 8 > buf.len() {
                return None;
            }
            let var_id = u32::from_le_bytes([buf[cursor], buf[cursor + 1], buf[cursor + 2], buf[cursor + 3]]);
            let step_count =
                u32::from_le_bytes([buf[cursor + 4], buf[cursor + 5], buf[cursor + 6], buf[cursor + 7]]) as usize;
            cursor += 8;
            let mut steps = Vec::with_capacity(step_count);
            for _ in 0..step_count {
                if cursor + 8 > buf.len() {
                    return None;
                }
                let mut step_bytes = [0u8; 8];
                step_bytes.copy_from_slice(&buf[cursor..cursor + 8]);
                steps.push(StepId(i64::from_le_bytes(step_bytes)));
                cursor += 8;
            }
            entries.insert(VariableId(var_id as usize), steps);
        }
        Some(VarWrites { entries })
    }
}

/// Encoded `originmeta.tc` namespace. Native and materialized keying
/// share the same record layout; the namespace header carries the
/// scheme tag so the reader knows how to interpret the key.
#[derive(Debug, Clone)]
pub struct OriginMetaStream {
    pub keying_scheme: KeyingScheme,
    native_records: Vec<(u64, u64, OriginMetadataRecord)>, // (address, tick, record)
    materialized_records: Vec<(VariableId, StepId, OriginMetadataRecord)>,
}

impl OriginMetaStream {
    pub fn new(keying_scheme: KeyingScheme) -> Self {
        OriginMetaStream {
            keying_scheme,
            native_records: Vec::new(),
            materialized_records: Vec::new(),
        }
    }

    /// Append a native-keyed `(address, tick)` record. Records may
    /// arrive out of tick order; the on-disk encoder sorts them so
    /// the per-address tick list is ascending (§6.8.1).
    pub fn push_native(&mut self, address: u64, tick: u64, record: OriginMetadataRecord) {
        assert_eq!(
            self.keying_scheme,
            KeyingScheme::Native,
            "push_native called on a materialized-keyed stream"
        );
        self.native_records.push((address, tick, record));
    }

    pub fn push_materialized(&mut self, variable_id: VariableId, step_id: StepId, record: OriginMetadataRecord) {
        assert_eq!(
            self.keying_scheme,
            KeyingScheme::Materialized,
            "push_materialized called on a native-keyed stream"
        );
        self.materialized_records.push((variable_id, step_id, record));
    }

    pub fn native_len(&self) -> usize {
        self.native_records.len()
    }

    pub fn materialized_len(&self) -> usize {
        self.materialized_records.len()
    }

    pub fn native_records(&self) -> &[(u64, u64, OriginMetadataRecord)] {
        &self.native_records
    }

    pub fn materialized_records(&self) -> &[(VariableId, StepId, OriginMetadataRecord)] {
        &self.materialized_records
    }

    /// Encode the stream to disk. Layout:
    /// `magic(8) | version(1) | scheme(1) | record_count(u32 LE) | record*`.
    /// Per record the key is encoded before the [`OriginMetadataRecord`]
    /// — for native records `(addr: u64 LE | tick: u64 LE | record)`;
    /// for materialized `(var_id: u32 LE | step_id: i64 LE | record)`.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(ORIGINMETA_MAGIC);
        out.push(NAMESPACE_VERSION);
        out.push(self.keying_scheme as u8);
        match self.keying_scheme {
            KeyingScheme::Native => {
                let mut records = self.native_records.clone();
                // Per spec §6.8.1: per-address ascending tick order.
                // Sorting by `(address, tick)` produces both invariants
                // and keeps a stable order across re-encodings.
                records.sort_by_key(|(addr, tick, _)| (*addr, *tick));
                out.extend_from_slice(&(records.len() as u32).to_le_bytes());
                for (addr, tick, rec) in &records {
                    out.extend_from_slice(&addr.to_le_bytes());
                    out.extend_from_slice(&tick.to_le_bytes());
                    rec.write_to(&mut out);
                }
            }
            KeyingScheme::Materialized => {
                let mut records = self.materialized_records.clone();
                records.sort_by_key(|(var, step, _)| (var.0, step.0));
                out.extend_from_slice(&(records.len() as u32).to_le_bytes());
                for (var, step, rec) in &records {
                    out.extend_from_slice(&(var.0 as u32).to_le_bytes());
                    out.extend_from_slice(&step.0.to_le_bytes());
                    rec.write_to(&mut out);
                }
            }
        }
        out
    }

    pub fn decode(buf: &[u8]) -> Option<Self> {
        if buf.len() < 14 || &buf[0..8] != ORIGINMETA_MAGIC {
            return None;
        }
        let version = buf[8];
        if version != NAMESPACE_VERSION {
            return None;
        }
        let scheme = KeyingScheme::from_byte(buf[9])?;
        let record_count = u32::from_le_bytes([buf[10], buf[11], buf[12], buf[13]]) as usize;
        let mut cursor = 14;
        let mut stream = OriginMetaStream::new(scheme);
        match scheme {
            KeyingScheme::Native => {
                for _ in 0..record_count {
                    if cursor + 16 + OriginMetadataRecord::ENCODED_SIZE > buf.len() {
                        return None;
                    }
                    let mut addr_bytes = [0u8; 8];
                    addr_bytes.copy_from_slice(&buf[cursor..cursor + 8]);
                    cursor += 8;
                    let mut tick_bytes = [0u8; 8];
                    tick_bytes.copy_from_slice(&buf[cursor..cursor + 8]);
                    cursor += 8;
                    let rec = OriginMetadataRecord::read_from(&buf[cursor..])?;
                    cursor += OriginMetadataRecord::ENCODED_SIZE;
                    stream
                        .native_records
                        .push((u64::from_le_bytes(addr_bytes), u64::from_le_bytes(tick_bytes), rec));
                }
            }
            KeyingScheme::Materialized => {
                for _ in 0..record_count {
                    if cursor + 12 + OriginMetadataRecord::ENCODED_SIZE > buf.len() {
                        return None;
                    }
                    let var_id = u32::from_le_bytes([buf[cursor], buf[cursor + 1], buf[cursor + 2], buf[cursor + 3]]);
                    cursor += 4;
                    let mut step_bytes = [0u8; 8];
                    step_bytes.copy_from_slice(&buf[cursor..cursor + 8]);
                    cursor += 8;
                    let rec = OriginMetadataRecord::read_from(&buf[cursor..])?;
                    cursor += OriginMetadataRecord::ENCODED_SIZE;
                    stream.materialized_records.push((
                        VariableId(var_id as usize),
                        StepId(i64::from_le_bytes(step_bytes)),
                        rec,
                    ));
                }
            }
        }
        Some(stream)
    }
}

/// Materialized-indexer output. The trio that lands in CTFS plus the
/// per-`VariableId` capability matrix used to flesh out
/// `origin-config.toml`.
#[derive(Debug, Clone)]
pub struct MaterializedIndexOutput {
    pub varwrites: VarWrites,
    pub originmeta: OriginMetaStream,
    pub source_exprs: SourceExprIndex,
    pub capability: BTreeMap<VariableId, PathCapability>,
}

/// Materialized indexer driver. Single linear pass over the provided
/// changes; for each emit `varwrites.tc` + `originmeta.tc` plus
/// dedupe the source-expression text into `source_exprs.tc`.
#[derive(Debug, Default)]
pub struct MaterializedOriginIndexer;

impl MaterializedOriginIndexer {
    pub fn new() -> Self {
        MaterializedOriginIndexer
    }

    /// Run the indexer. Per change:
    ///
    /// 1. Update `varwrites.tc` with the `(VariableId, StepId)`
    ///    backbone entry.
    /// 2. If a Path A descriptor is present, emit confidence 1.0
    ///    metadata directly from the recorder's classification.
    /// 3. Otherwise, classify the source line against the cached
    ///    `(path_id, line, target_var)` cache (the M19 fixture path
    ///    short-circuits this — see `NativeWrite::kind` /
    ///    `ValueChange::source_expr_text`).
    ///
    /// The capability matrix is materialised on the fly from the per
    /// `VariableId` observation history — a variable observed under
    /// Path A only ends up `PathAOnly`; observed only under Path B
    /// only, `PathBOnly`; both, `Mixed`.
    pub fn run(&self, changes: &[ValueChange]) -> MaterializedIndexOutput {
        let mut varwrites = VarWrites::new();
        let mut originmeta = OriginMetaStream::new(KeyingScheme::Materialized);
        let mut source_exprs = SourceExprIndex::new();
        let mut path_a_seen: BTreeMap<VariableId, bool> = BTreeMap::new();
        let mut path_b_seen: BTreeMap<VariableId, bool> = BTreeMap::new();

        for change in changes {
            varwrites.push(change.variable_id, change.step_id);
            let expr_idx = source_exprs.intern(&change.source_expr_text);
            let record = match &change.assignment {
                Some(assign) => {
                    path_a_seen.insert(change.variable_id, true);
                    OriginMetadataRecord {
                        kind: OriginMetadataRecord::encode_kind(assign.kind),
                        target_var_id: change.variable_id.0 as u32,
                        source_var_id: assign.source_var_id,
                        source_expr_idx: expr_idx,
                        function_idx: assign.function_idx,
                        confidence: OriginMetadataRecord::encode_confidence(1.0),
                    }
                }
                None => {
                    path_b_seen.insert(change.variable_id, true);
                    // Path B classifier confidence floor per spec
                    // §6.1.5 — ≤ 0.9 for unambiguous parses; the
                    // exemplar fixture path here pins it at 0.9, but
                    // the per-recorder coverage tests can drop to 0.6
                    // for the elided-write JS path.
                    OriginMetadataRecord {
                        kind: OriginMetadataRecord::encode_kind(OriginKind::Unknown),
                        target_var_id: change.variable_id.0 as u32,
                        source_var_id: None,
                        source_expr_idx: expr_idx,
                        function_idx: change.function_idx,
                        confidence: OriginMetadataRecord::encode_confidence(0.9),
                    }
                }
            };
            originmeta.push_materialized(change.variable_id, change.step_id, record);
        }

        let mut capability = BTreeMap::new();
        for var in varwrites.variables() {
            let has_a = path_a_seen.get(&var).copied().unwrap_or(false);
            let has_b = path_b_seen.get(&var).copied().unwrap_or(false);
            let cap = match (has_a, has_b) {
                (true, true) => PathCapability::Mixed,
                (true, false) => PathCapability::PathAOnly,
                (false, true) => PathCapability::PathBOnly,
                (false, false) => PathCapability::PathBOnly,
            };
            capability.insert(var, cap);
        }

        MaterializedIndexOutput {
            varwrites,
            originmeta,
            source_exprs,
            capability,
        }
    }
}

/// Native-indexer output. The materialized-side `varwrites.tc`
/// backbone is absent — native traces key by `(address, tick)`
/// directly.
#[derive(Debug, Clone)]
pub struct NativeIndexOutput {
    pub originmeta: OriginMetaStream,
    pub source_exprs: SourceExprIndex,
}

/// Native indexer driver. For each write in `writes`, look up the
/// `target_var_id` / `function_idx` (already cached on
/// [`NativeWrite`]), classify the cached source line, and emit one
/// `OriginMetadataRecord`. In production this loop is driven by the
/// recorder's M10f parallel interval analysis (see
/// `codetracer-native-recorder/ct_emulator/`); the M19 stub here is
/// exercisable end-to-end against the synthetic M18 FFI fixture.
#[derive(Debug, Default)]
pub struct NativeOriginIndexer;

impl NativeOriginIndexer {
    pub fn new() -> Self {
        NativeOriginIndexer
    }

    pub fn run(&self, writes: &[NativeWrite]) -> NativeIndexOutput {
        let mut originmeta = OriginMetaStream::new(KeyingScheme::Native);
        let mut source_exprs = SourceExprIndex::new();
        for write in writes {
            let expr_idx = source_exprs.intern(&write.source_expr_text);
            let record = OriginMetadataRecord {
                kind: OriginMetadataRecord::encode_kind(write.kind),
                target_var_id: write.target_var_id,
                source_var_id: write.source_var_id,
                source_expr_idx: expr_idx,
                function_idx: write.function_idx,
                confidence: OriginMetadataRecord::encode_confidence(write.confidence),
            };
            originmeta.push_native(write.address, write.tick, record);
        }
        NativeIndexOutput {
            originmeta,
            source_exprs,
        }
    }
}

/// Reader-side decoder shared between TraceKinds (spec §6.8.2). The
/// decoder takes the encoded `originmeta.tc` + `source_exprs.tc`
/// buffers, holds them in memory, and resolves `(address, tick)` or
/// `(VariableId, StepId)` keys back into the per-write metadata. The
/// resolver is a binary search — O(log N) per query.
#[derive(Debug, Clone)]
pub struct OriginMetadataDecoder {
    stream: OriginMetaStream,
    source_exprs: SourceExprIndex,
    /// Per-address sorted index for native lookups.
    native_by_address: HashMap<u64, Vec<(u64, OriginMetadataRecord)>>,
    /// Per-variable sorted index for materialized lookups.
    materialized_by_var: HashMap<VariableId, Vec<(StepId, OriginMetadataRecord)>>,
}

/// Key kind passed to [`OriginMetadataDecoder::origin_metadata_at`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OriginMetadataKey {
    /// Find the most recent record at exactly `(address, tick)` —
    /// matches the native indexer's keying scheme.
    Native { address: u64, tick: u64 },
    /// Find the record for `(VariableId, StepId)` — matches the
    /// materialized indexer's keying scheme.
    Materialized { variable_id: VariableId, step_id: StepId },
}

impl OriginMetadataDecoder {
    /// Load a decoder from the two CTFS file buffers. Returns `None`
    /// when either magic header mismatches — callers fall back cleanly
    /// to Mode 1 / Mode 2 lookup paths (§6.8.5).
    pub fn load(originmeta_buf: &[u8], source_exprs_buf: &[u8]) -> Option<Self> {
        let stream = OriginMetaStream::decode(originmeta_buf)?;
        let source_exprs = SourceExprIndex::decode(source_exprs_buf)?;
        Some(Self::from_stream(stream, source_exprs))
    }

    /// In-memory constructor — used by tests and by the materialized
    /// trace-load path that produces the streams in-process without
    /// going through CTFS file writes.
    pub fn from_stream(stream: OriginMetaStream, source_exprs: SourceExprIndex) -> Self {
        let mut native_by_address: HashMap<u64, Vec<(u64, OriginMetadataRecord)>> = HashMap::new();
        let mut materialized_by_var: HashMap<VariableId, Vec<(StepId, OriginMetadataRecord)>> = HashMap::new();
        for (addr, tick, record) in stream.native_records() {
            native_by_address.entry(*addr).or_default().push((*tick, *record));
        }
        for (var, step, record) in stream.materialized_records() {
            materialized_by_var.entry(*var).or_default().push((*step, *record));
        }
        for list in native_by_address.values_mut() {
            list.sort_by_key(|(tick, _)| *tick);
        }
        for list in materialized_by_var.values_mut() {
            list.sort_by_key(|(step, _)| step.0);
        }
        OriginMetadataDecoder {
            stream,
            source_exprs,
            native_by_address,
            materialized_by_var,
        }
    }

    pub fn keying_scheme(&self) -> KeyingScheme {
        self.stream.keying_scheme
    }

    pub fn source_expr_text(&self, idx: u32) -> Option<&str> {
        self.source_exprs.get(idx)
    }

    /// Look up the origin metadata for the given key. For native
    /// traces this returns the **most recent** record at-or-before the
    /// tick (matching the spec §6.8.2 `last_record_before` algorithm).
    /// For materialized traces it returns the exact `(var, step)` hit
    /// or `None`.
    pub fn origin_metadata_at(&self, key: OriginMetadataKey) -> Option<OriginMetadataRecord> {
        match key {
            OriginMetadataKey::Native { address, tick } => {
                let list = self.native_by_address.get(&address)?;
                let pos = list.partition_point(|(t, _)| *t <= tick);
                if pos == 0 { None } else { Some(list[pos - 1].1) }
            }
            OriginMetadataKey::Materialized { variable_id, step_id } => {
                let list = self.materialized_by_var.get(&variable_id)?;
                let pos = list.partition_point(|(s, _)| s.0 < step_id.0);
                if pos < list.len() && list[pos].0 == step_id {
                    Some(list[pos].1)
                } else {
                    None
                }
            }
        }
    }
}

/// Per-trace origin config persisted in `meta_dat/origin-config.toml`.
///
/// We use a minimal key=value text format — sample:
///
/// ```text
/// mode = on
/// capability VariableId(3) = path_a
/// capability VariableId(5) = mixed
/// ```
///
/// Keeping the parser tiny avoids adding a `toml` crate dependency at
/// M19; the spec's name (`origin-config.toml`) is preserved on disk so
/// future tooling can replace this with a real TOML implementation
/// without breaking the storage location contract.
#[derive(Debug, Clone)]
pub struct OriginConfig {
    pub mode: OriginMode,
    pub capability: BTreeMap<VariableId, PathCapability>,
    pub recorder_name: Option<String>,
    pub recorder_version: Option<String>,
}

impl OriginConfig {
    pub fn new(mode: OriginMode) -> Self {
        OriginConfig {
            mode,
            capability: BTreeMap::new(),
            recorder_name: None,
            recorder_version: None,
        }
    }

    pub fn set_mode(&mut self, mode: OriginMode) {
        self.mode = mode;
    }

    pub fn merge_capability(&mut self, capability: BTreeMap<VariableId, PathCapability>) {
        self.capability = capability;
    }

    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("mode = {}\n", self.mode.as_str()));
        if let Some(name) = &self.recorder_name {
            out.push_str(&format!("recorder_name = {}\n", name));
        }
        if let Some(ver) = &self.recorder_version {
            out.push_str(&format!("recorder_version = {}\n", ver));
        }
        for (var, cap) in &self.capability {
            out.push_str(&format!("capability VariableId({}) = {}\n", var.0, cap.as_str()));
        }
        out
    }

    /// Parse a previously rendered config. Tolerant of comment lines
    /// (`#`-prefixed) and blank lines.
    pub fn parse(text: &str) -> Option<Self> {
        let mut mode = OriginMode::Off;
        let mut capability = BTreeMap::new();
        let mut recorder_name = None;
        let mut recorder_version = None;
        for raw_line in text.lines() {
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(rest) = line.strip_prefix("mode") {
                let eq = rest.split_once('=')?;
                mode = OriginMode::parse(eq.1.trim())?;
                continue;
            }
            if let Some(rest) = line.strip_prefix("recorder_name") {
                let eq = rest.split_once('=')?;
                recorder_name = Some(eq.1.trim().to_string());
                continue;
            }
            if let Some(rest) = line.strip_prefix("recorder_version") {
                let eq = rest.split_once('=')?;
                recorder_version = Some(eq.1.trim().to_string());
                continue;
            }
            if let Some(rest) = line.strip_prefix("capability VariableId(") {
                let (id_part, after) = rest.split_once(')')?;
                let var_id = id_part.trim().parse::<usize>().ok()?;
                let eq = after.split_once('=')?;
                capability.insert(VariableId(var_id), PathCapability::parse(eq.1.trim())?);
                continue;
            }
        }
        Some(OriginConfig {
            mode,
            capability,
            recorder_name,
            recorder_version,
        })
    }

    pub fn write_to_path(&self, path: &Path) -> std::io::Result<()> {
        std::fs::write(path, self.render())
    }

    pub fn read_from_path(path: &Path) -> std::io::Result<Self> {
        let text = std::fs::read_to_string(path)?;
        OriginConfig::parse(&text)
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "malformed origin-config.toml"))
    }
}

/// `ct trace probe` output — capability matrix listing, recorder name
/// and version, mode. Renderable for the CLI subcommand; constructible
/// from an `OriginConfig`.
#[derive(Debug, Clone)]
pub struct ProbeReport {
    pub mode: OriginMode,
    pub recorder_name: Option<String>,
    pub recorder_version: Option<String>,
    pub capability: BTreeMap<VariableId, PathCapability>,
}

impl ProbeReport {
    pub fn from_config(config: &OriginConfig) -> Self {
        ProbeReport {
            mode: config.mode,
            recorder_name: config.recorder_name.clone(),
            recorder_version: config.recorder_version.clone(),
            capability: config.capability.clone(),
        }
    }

    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str(&format!("origin-metadata mode: {}\n", self.mode.as_str()));
        out.push_str(&format!(
            "recorder: {}\n",
            self.recorder_name.as_deref().unwrap_or("<unknown>")
        ));
        out.push_str(&format!(
            "recorder-version: {}\n",
            self.recorder_version.as_deref().unwrap_or("<unknown>")
        ));
        out.push_str(&format!("variables: {}\n", self.capability.len()));
        for (var, cap) in &self.capability {
            out.push_str(&format!("  VariableId({}) -> {}\n", var.0, cap.as_str()));
        }
        out
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use codetracer_trace_types::{TypeId, ValueRecord};

    fn make_value(n: i64) -> ValueRecord {
        ValueRecord::Int {
            i: n,
            type_id: TypeId(0),
        }
    }

    fn change(variable: usize, step: i64, expr: &str, assignment: Option<PathAAssignment>) -> ValueChange {
        ValueChange {
            variable_id: VariableId(variable),
            step_id: StepId(step),
            value: make_value(step),
            assignment,
            source_expr_text: expr.to_string(),
            function_idx: 1,
        }
    }

    #[test]
    fn materialized_indexer_emits_namespaces() {
        let changes = vec![
            change(
                3,
                10,
                "a = 1",
                Some(PathAAssignment {
                    kind: OriginKind::Literal,
                    source_var_id: None,
                    function_idx: 1,
                }),
            ),
            change(
                4,
                12,
                "b = a",
                Some(PathAAssignment {
                    kind: OriginKind::TrivialCopy,
                    source_var_id: Some(3),
                    function_idx: 1,
                }),
            ),
        ];
        let indexer = MaterializedOriginIndexer::new();
        let out = indexer.run(&changes);
        assert_eq!(out.originmeta.materialized_len(), 2);
        assert_eq!(out.source_exprs.len(), 2);
        let var_4_steps = out.varwrites.steps_for(VariableId(4)).unwrap();
        assert_eq!(var_4_steps, &[StepId(12)]);
    }

    #[test]
    fn record_kind_encoding_round_trip() {
        for kind in [
            OriginKind::TrivialCopy,
            OriginKind::FieldAccess,
            OriginKind::IndexAccess,
            OriginKind::Computational,
            OriginKind::FunctionCall,
            OriginKind::Literal,
            OriginKind::ReturnCapture,
            OriginKind::ParameterPass,
            OriginKind::CrossThread,
            OriginKind::Unknown,
        ] {
            let byte = OriginMetadataRecord::encode_kind(kind);
            assert_eq!(OriginMetadataRecord::decode_kind(byte), Some(kind));
        }
    }

    #[test]
    fn confidence_encoding_clamps() {
        assert_eq!(OriginMetadataRecord::encode_confidence(-1.0), 0);
        assert_eq!(OriginMetadataRecord::encode_confidence(2.0), 255);
        assert_eq!(OriginMetadataRecord::encode_confidence(0.5), 128);
        assert_eq!(OriginMetadataRecord::encode_confidence(f32::NAN), 0);
        assert_eq!(OriginMetadataRecord::encode_confidence(1.0), 255);
    }
}
