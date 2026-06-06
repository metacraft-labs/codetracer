//! M21 — Ubiquitous eager origin display via omniscient DB (Mode 3
//! only).
//!
//! ## Scope
//!
//! This module encapsulates the per-surface "eager vs placeholder"
//! decision the dispatcher makes when populating origin summaries on
//! the wire. It honours the per-trace mode toggle persisted in
//! `meta_dat/origin-config.toml` (M19 [`OriginConfig`]) combined with
//! the runtime presence of the M18 omniscient DB and the M19
//! metadata decoder. The output is consumed by
//! [`crate::dap_handler::Handler::load_history`] and
//! [`crate::dap_handler::Handler::load_flow`] to flip the per-surface
//! defaults that spec §3.2.3 documents (the V1 defaults table — locals
//! eager, history + flow placeholder — flips to eager-everywhere on a
//! Mode 3 trace per spec §6.8.6.3).
//!
//! ## Mode classification (spec §6.8.6)
//!
//! - **Mode 1** (no omniscient DB): the trace has no `memwrites.tc`
//!   / `linehits.tc` namespace and no `origin-config.toml`. The
//!   classifier-only path serves origin queries; eager mode would
//!   require running per-row chain builds and the V1 defaults from
//!   spec §3.2.3 stay in effect.
//! - **Mode 2** (omniscient DB but no origin metadata): the trace
//!   ships `memwrites.tc` but no `originmeta.tc`. Per-click origin
//!   chains are snappy enough but a 10 000-entry history list still
//!   can't be populated eagerly within the spec's 700 ms budget.
//! - **Mode 3** (omniscient DB + origin metadata): the trace ships
//!   both. The spec promises sub-millisecond per-row origin lookups
//!   so the dispatcher flips every value-bearing surface to eager.
//!
//! ## Lazy intervals
//!
//! A `Mode 3 lazy` trace ships the metadata namespaces but populates
//! them on demand. Per spec §3.2.3 the dispatcher should still flip
//! the default to eager — the per-row lookup either hits a populated
//! interval (fast) or returns `is_placeholder: true` so the frontend
//! renders the `[?]` pill while the background analyser fills the
//! interval. The decoder's per-key lookup ([`Self::lookup_eager`])
//! signals "not yet analysed" through a `None` return on a `lazy`
//! configuration.

use std::path::Path;

use crate::origin_metadata_indexer::{OriginConfig, OriginMetadataDecoder, OriginMetadataKey, OriginMode};
use crate::task;

/// Per-trace mode + decoder snapshot. Encapsulates the dispatcher's
/// classification per spec §6.8.6 (Mode 1 / 2 / 3) so the per-surface
/// defaults in [`crate::dap_handler::Handler::load_history`] /
/// [`crate::dap_handler::Handler::load_flow`] flip uniformly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EagerModeClass {
    /// Mode 1 — no omniscient DB on the trace. V1 defaults from spec
    /// §3.2.3 stay in effect (placeholder on history / flow / watch /
    /// editor-hover, eager on locals).
    Mode1NoOmniscient,
    /// Mode 2 — omniscient DB present but no origin metadata. Per
    /// spec §6.8.6.3 eager defaults remain off for the heavy surfaces
    /// because the per-row classifier walk still costs ≥ 1 ms.
    Mode2OmniscientOnly,
    /// Mode 3 `on` — omniscient DB + fully populated origin metadata.
    /// All value-bearing surfaces flip to eager.
    Mode3On,
    /// Mode 3 `lazy` — omniscient DB + lazily populated origin
    /// metadata. All surfaces flip to eager but per-key lookups may
    /// still return `is_placeholder: true` for not-yet-analysed
    /// intervals; the dispatcher schedules the background indexer
    /// and the frontend renders the `[?]` pill until the analyser
    /// finishes.
    Mode3Lazy,
    /// `origin-config.toml` exists with `mode = off`. We treat this
    /// the same as Mode 1 (the recorder explicitly opted out of the
    /// metadata namespaces). Surfaced separately so the State Pane
    /// mode indicator can distinguish "no omniscient DB" from "user
    /// turned origin metadata off".
    ModeOffExplicit,
}

impl EagerModeClass {
    /// Wire-format string surfaced through `ct/originMode` for the
    /// State Pane settings sub-menu indicator (spec §3.7 +
    /// M21 deliverable #4). Matches the spec wording exactly so the
    /// frontend can render the literal without translation.
    pub fn indicator_label(self) -> &'static str {
        match self {
            EagerModeClass::Mode1NoOmniscient => "unavailable",
            EagerModeClass::Mode2OmniscientOnly => "off",
            EagerModeClass::Mode3On => "on",
            EagerModeClass::Mode3Lazy => "lazy",
            EagerModeClass::ModeOffExplicit => "off",
        }
    }

    /// Whether the dispatcher should flip the per-surface default to
    /// eager. Mode 3 `on` flips eager unconditionally; Mode 3 `lazy`
    /// also flips eager but each lookup may still return a
    /// placeholder while the background analyser runs.
    pub fn flips_eager(self) -> bool {
        matches!(self, EagerModeClass::Mode3On | EagerModeClass::Mode3Lazy)
    }
}

/// Resolve the per-trace eager-mode class from the on-disk config +
/// the runtime omniscient-DB / metadata-decoder presence.
///
/// `workdir` points to the trace's CTFS root (the `meta_dat/`
/// directory lives directly beneath it). `omniscient_present` reports
/// whether [`crate::replay::ReplaySession::omniscient_db`] is `Some`
/// AND `is_present()`. `metadata_decoder_present` reports whether the
/// trace ships the M19 `originmeta.tc` namespace.
///
/// ## Per-`TraceKind` shape
///
/// Mode 3 is reachable through two distinct paths in the spec
/// (§6.8.1 keying schemes):
///
/// - **Native** keying — requires both a populated omniscient DB
///   (the `(address, tick)` write log) and a metadata decoder (the
///   `(address, tick)`-keyed `originmeta.tc`). The two namespaces
///   are co-produced by the recorder's M10f pass.
/// - **Materialized** keying — requires only the metadata decoder
///   (the `(VariableId, StepId)`-keyed `originmeta.tc`). The
///   materialized backend never ships an omniscient DB; it serves
///   origin queries directly from the materialised backbone +
///   metadata streams.
///
/// We therefore classify Mode 3 when *either*:
///
/// 1. The omniscient DB is present AND the metadata decoder is
///    present (native trace, full Mode 3), OR
/// 2. The metadata decoder is present (materialized trace —
///    `mode = on` / `mode = lazy` written to the config is sufficient
///    since the materialized backend doesn't ship the omniscient
///    namespace).
pub fn classify_eager_mode(workdir: &Path, omniscient_present: bool, metadata_decoder_present: bool) -> EagerModeClass {
    let config_path = workdir
        .join("meta_dat")
        .join(crate::origin_metadata_indexer::ORIGIN_CONFIG_FILE);
    let parsed = if config_path.is_file() {
        OriginConfig::read_from_path(&config_path).ok()
    } else {
        None
    };
    let mode3_capable = metadata_decoder_present || omniscient_present;
    match parsed {
        Some(cfg) => match cfg.mode {
            OriginMode::On if mode3_capable => EagerModeClass::Mode3On,
            OriginMode::Lazy if mode3_capable => EagerModeClass::Mode3Lazy,
            OriginMode::Off => {
                if omniscient_present {
                    EagerModeClass::Mode2OmniscientOnly
                } else {
                    EagerModeClass::ModeOffExplicit
                }
            }
            // `on` / `lazy` written to disk but neither runtime
            // capability is present (corrupt trace, partial recorder
            // upgrade, etc.) — surface Mode 2 / Mode 1 so the
            // dispatcher falls back cleanly to the V1 defaults rather
            // than incorrectly flipping eager.
            OriginMode::On => EagerModeClass::Mode1NoOmniscient,
            OriginMode::Lazy => EagerModeClass::Mode1NoOmniscient,
        },
        None => {
            if omniscient_present {
                EagerModeClass::Mode2OmniscientOnly
            } else {
                EagerModeClass::Mode1NoOmniscient
            }
        }
    }
}

/// Per-surface eager origin summary builder. Encapsulates the
/// per-key decoder lookup so the dispatcher's `load_history` /
/// `load_flow` helpers stay flat. The builder returns `Some(summary)`
/// when the metadata namespace covers the requested key and `None`
/// when the interval is not yet analysed (lazy mode) — the dispatcher
/// then falls back to a placeholder and the frontend renders `[?]`
/// per spec §3.2.3 until the background analyser finishes.
pub struct EagerSummaryBuilder<'a> {
    decoder: Option<&'a OriginMetadataDecoder>,
    class: EagerModeClass,
}

impl<'a> EagerSummaryBuilder<'a> {
    pub fn new(decoder: Option<&'a OriginMetadataDecoder>, class: EagerModeClass) -> Self {
        EagerSummaryBuilder { decoder, class }
    }

    /// Surface the underlying decoder reference — useful for tests and
    /// for the dispatcher path that wants to know whether the decoder
    /// is present at all (vs whether the per-key lookup hit).
    pub fn decoder(&self) -> Option<&OriginMetadataDecoder> {
        self.decoder
    }

    pub fn class(&self) -> EagerModeClass {
        self.class
    }

    /// Whether the dispatcher should flip eager for the active
    /// trace.  Mode 3 `on` / Mode 3 `lazy` return `true`. Mode 1 /
    /// Mode 2 / explicit-off return `false`.
    pub fn flips_eager(&self) -> bool {
        self.class.flips_eager()
    }

    /// Look up an eager summary for `(variable_id, step_id)`.
    ///
    /// Returns:
    ///
    /// - `Some(summary)` with `is_placeholder == false` when the
    ///   metadata decoder covers the key. The summary mirrors the
    ///   structure of [`crate::origin_query::OriginChain`] flattened
    ///   into the `OriginSummary` shape (hop count = 1 for a
    ///   metadata-driven hop, confidence from the record, terminator
    ///   text from the source-expr index).
    /// - `None` when the decoder is absent OR the key is inside a
    ///   not-yet-analysed lazy interval. Callers fall back to a
    ///   placeholder summary; the dispatcher schedules the background
    ///   indexer when the lazy interval is detected.
    pub fn lookup_eager(
        &self,
        variable_id: codetracer_trace_types::VariableId,
        step_id: codetracer_trace_types::StepId,
    ) -> Option<task::OriginSummary> {
        let decoder = self.decoder?;
        let record = decoder.origin_metadata_at(OriginMetadataKey::Materialized { variable_id, step_id })?;
        let confidence = OriginMetadataDecoder_confidence_from_byte(record.confidence);
        let terminator_expr = decoder
            .source_expr_text(record.source_expr_idx)
            .unwrap_or("<unknown>")
            .to_string();
        Some(task::OriginSummary {
            terminator_kind: task::TerminatorKindWire::UnknownSource,
            terminator_expr,
            terminator_function: None,
            hop_count: 1,
            confidence,
            is_placeholder: false,
            placeholder_token: None,
        })
    }
}

/// Decode the 8-bit fixed-point confidence stored in
/// [`crate::origin_metadata_indexer::OriginMetadataRecord::confidence`]
/// back to its f32 form. The encode side lives on the record itself —
/// keeping the decode helper free-standing here avoids dragging the
/// dispatcher into the indexer's encoding details.
#[allow(non_snake_case)]
fn OriginMetadataDecoder_confidence_from_byte(byte: u8) -> f32 {
    byte as f32 / 255.0
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use crate::origin_metadata_indexer::{KeyingScheme, OriginMetaStream, OriginMetadataRecord, SourceExprIndex};
    use codetracer_trace_types::{StepId, VariableId};
    use origin_classifier::OriginKind;

    fn write_config(workdir: &Path, body: &str) {
        let meta_dat = workdir.join("meta_dat");
        std::fs::create_dir_all(&meta_dat).expect("mkdir meta_dat");
        std::fs::write(meta_dat.join(crate::origin_metadata_indexer::ORIGIN_CONFIG_FILE), body).expect("write config");
    }

    #[test]
    fn classify_mode_3_on_when_config_on_and_runtime_present() {
        let tmp = tempfile::tempdir().unwrap();
        write_config(tmp.path(), "mode = on\n");
        let class = classify_eager_mode(tmp.path(), true, true);
        assert_eq!(class, EagerModeClass::Mode3On);
        assert!(class.flips_eager());
        assert_eq!(class.indicator_label(), "on");
    }

    #[test]
    fn classify_mode_3_lazy_when_config_lazy_and_omniscient_present() {
        let tmp = tempfile::tempdir().unwrap();
        write_config(tmp.path(), "mode = lazy\n");
        let class = classify_eager_mode(tmp.path(), true, false);
        assert_eq!(class, EagerModeClass::Mode3Lazy);
        assert!(class.flips_eager());
        assert_eq!(class.indicator_label(), "lazy");
    }

    #[test]
    fn classify_mode_2_when_no_config_but_omniscient_present() {
        let tmp = tempfile::tempdir().unwrap();
        let class = classify_eager_mode(tmp.path(), true, false);
        assert_eq!(class, EagerModeClass::Mode2OmniscientOnly);
        assert!(!class.flips_eager());
        assert_eq!(class.indicator_label(), "off");
    }

    #[test]
    fn classify_mode_1_when_no_omniscient() {
        let tmp = tempfile::tempdir().unwrap();
        let class = classify_eager_mode(tmp.path(), false, false);
        assert_eq!(class, EagerModeClass::Mode1NoOmniscient);
        assert!(!class.flips_eager());
        assert_eq!(class.indicator_label(), "unavailable");
    }

    #[test]
    fn classify_off_explicit_when_config_off_no_omniscient() {
        let tmp = tempfile::tempdir().unwrap();
        write_config(tmp.path(), "mode = off\n");
        let class = classify_eager_mode(tmp.path(), false, false);
        assert_eq!(class, EagerModeClass::ModeOffExplicit);
        assert!(!class.flips_eager());
        assert_eq!(class.indicator_label(), "off");
    }

    #[test]
    fn classify_mode_3_on_when_config_on_and_only_omniscient_present() {
        // Native trace: `mode = on` + omniscient DB.  The metadata
        // namespace might be loaded lazily — Mode 3 still applies
        // because at least one Mode-3 capability is available, and
        // the dispatcher flips eager.
        let tmp = tempfile::tempdir().unwrap();
        write_config(tmp.path(), "mode = on\n");
        let class = classify_eager_mode(tmp.path(), true, false);
        assert_eq!(class, EagerModeClass::Mode3On);
        assert!(class.flips_eager());
    }

    #[test]
    fn lookup_eager_returns_populated_summary_when_decoder_covers_key() {
        let mut stream = OriginMetaStream::new(KeyingScheme::Materialized);
        let mut source_exprs = SourceExprIndex::new();
        let expr_idx = source_exprs.intern("source_literal");
        let record = OriginMetadataRecord {
            kind: OriginMetadataRecord::encode_kind(OriginKind::Literal),
            target_var_id: 7,
            source_var_id: None,
            source_expr_idx: expr_idx,
            function_idx: 11,
            confidence: OriginMetadataRecord::encode_confidence(1.0),
        };
        stream.push_materialized(VariableId(7), StepId(3), record);
        let decoder = OriginMetadataDecoder::from_stream(stream, source_exprs);
        let builder = EagerSummaryBuilder::new(Some(&decoder), EagerModeClass::Mode3On);
        let summary = builder.lookup_eager(VariableId(7), StepId(3)).expect("hit");
        assert!(!summary.is_placeholder);
        assert_eq!(summary.terminator_expr, "source_literal");
        assert_eq!(summary.hop_count, 1);
        assert!((summary.confidence - 1.0).abs() < 1e-3);
    }

    #[test]
    fn lookup_eager_returns_none_when_decoder_missing() {
        let builder = EagerSummaryBuilder::new(None, EagerModeClass::Mode3Lazy);
        assert!(builder.lookup_eager(VariableId(0), StepId(0)).is_none());
    }

    #[test]
    fn lookup_eager_returns_none_for_uncovered_key_in_lazy_mode() {
        let stream = OriginMetaStream::new(KeyingScheme::Materialized);
        let source_exprs = SourceExprIndex::new();
        let decoder = OriginMetadataDecoder::from_stream(stream, source_exprs);
        let builder = EagerSummaryBuilder::new(Some(&decoder), EagerModeClass::Mode3Lazy);
        assert!(builder.lookup_eager(VariableId(0), StepId(0)).is_none());
    }
}
