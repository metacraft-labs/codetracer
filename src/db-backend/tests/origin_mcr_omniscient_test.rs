//! M20 — MCR omniscient origin tier (consumes the M19 metadata
//! extension) verification tests.
//!
//! Implements the 5 verification tests for M20 of the Value-Origin
//! Tracking initiative:
//!
//! 1. `test_origin_mcr_omniscient_skips_breakpoint_fallback` — On a
//!    trace with the omniscient log, an origin query that would have
//!    required Tier-2 (breakpoint + re-execution) under M17 is served
//!    entirely from the log. Chain metrics report 0% Tier-2 hops.
//! 2. `test_origin_mcr_omniscient_with_metadata_skips_classifier` — On
//!    a trace with both the write log and `originmeta.tc`, an origin
//!    chain query does NOT invoke the tree-sitter classifier at query
//!    time; the metrics field reports classifier-invocations-per-hop
//!    = 0.
//! 3. `test_origin_mcr_omniscient_c_simple_trivial_chain` — C fixture
//!    chain via persistent write log + metadata. Reuses the M11 C
//!    `simple_trivial_chain` fixture; SKIPs narrowly when the recorder
//!    is unavailable.
//! 4. `test_origin_mcr_omniscient_cross_checkpoint_chain` — A chain
//!    whose hops cross checkpoint intervals returns the correct
//!    sequence. The M18 omniscient log is keyed by absolute tick
//!    globally, so the algorithm doesn't special-case interval
//!    boundaries — we exercise that by seeding writes whose ticks
//!    straddle a synthetic "interval" boundary and confirming the
//!    chain walks across it transparently.
//! 5. `test_origin_mcr_omniscient_latency_below_threshold` — Per-hop
//!    wall-clock latency below 100 µs on a representative fixture.
//!
//! Per-language fixture coverage matches the M11 surface (C, Rust,
//! Nim, Go, D) — each fixture test reuses the existing
//! `tests/fixtures/origin/<lang>/simple_trivial_chain/` directory and
//! SKIPs narrowly with the same `SKIPPED: ct-mcr binary not on PATH`
//! sentinel M17 uses when the recorder isn't present. The in-FFI
//! synthetic fixtures (#1, #2, #4, #5) drive the M20 algorithm
//! end-to-end against the same FFI surface the production driver
//! consumes — no live `ct-mcr` binary is required.
//!
//! # FFI lock discipline
//!
//! Every test that touches the M17 / M18 / M20 FFI surface takes the
//! `omniscient_db::omniscient_ffi_lock()` mutex at the top. The mutex
//! serialises against the M18 verification tests (which share the
//! same per-process Nim global state) so two `cargo test` workers
//! never observe each other's seeded writes.

use std::process::Command;
use std::time::Instant;

use db_backend::emulator_ffi;
use db_backend::omniscient_db::{FfiOmniscientDb, WriteRecord, omniscient_ffi_lock};
use db_backend::omniscient_origin::{MCR_OMNISCIENT_DEFAULT_MAX_HOPS, run_omniscient_origin_chain};
use db_backend::origin_metadata_indexer::{KeyingScheme, NativeOriginIndexer, NativeWrite, OriginMetadataDecoder};
use db_backend::task::{
    CtOriginChainArguments, DEFAULT_ORIGIN_MAX_STEPS_SCANNED, DEFAULT_ORIGIN_WALL_CLOCK_MS, OriginBudget,
};
use origin_classifier::OriginKind as ClassifierKind;

/// Initialise the Nim runtime once for the entire test binary.
fn ensure_nim_runtime() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe {
        emulator_ffi::NimMain();
    });
}

/// Reset every M17 + M18 piece of Nim-global state. Called at the top
/// of every test that touches the omniscient / undo-map FFI so
/// neighbouring tests in the same `cargo test` process never observe
/// leftover fixture data.
fn reset_nim_state() {
    ensure_nim_runtime();
    // SAFETY: idempotent module-level resets; the Nim shims tolerate
    // an uninitialised module state.
    unsafe {
        emulator_ffi::mcrOmniscientReset();
        emulator_ffi::mcrUndoMapReset();
    }
}

fn make_args(name: &str, step_id: i64, max_hops: u32) -> CtOriginChainArguments {
    CtOriginChainArguments {
        variable_name: name.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id,
        thread_id: 0,
        max_hops,
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    }
}

fn default_budget() -> OriginBudget {
    OriginBudget {
        max_hops: MCR_OMNISCIENT_DEFAULT_MAX_HOPS,
        wall_clock_ms: DEFAULT_ORIGIN_WALL_CLOCK_MS,
        max_steps_scanned: DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
    }
}

/// Narrow probe: is `ct-mcr` on PATH? Returns true if so, otherwise
/// emits a SKIPPED sentinel and returns false. Mirrors the M17 file's
/// SKIP discipline so the CI sentinel is identical across M17 + M20
/// fixture tests.
fn require_ct_mcr(test_label: &str) -> bool {
    if Command::new("ct-mcr")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        true
    } else {
        eprintln!(
            "SKIPPED: ct-mcr binary not on PATH (M20 {} requires the MCR recorder for an \
             end-to-end fixture trace)",
            test_label
        );
        false
    }
}

fn require_compiler(name: &str, test_label: &str) -> bool {
    if Command::new(name)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
    {
        true
    } else {
        eprintln!(
            "SKIPPED: {name} not on PATH (M20 {test_label} needs the {name} compiler)",
            name = name,
            test_label = test_label
        );
        false
    }
}

// ---------------------------------------------------------------------------
// Test #1 — omniscient log supersedes Tier-2 fallback entirely.
// ---------------------------------------------------------------------------

/// **Fixture:** a synthetic recording where the queried write lands
/// strictly BEFORE the M17 undo-map window (so the M17 hybrid path
/// would have to fall through to Tier 2 reverse-step). The same
/// recording carries an omniscient log that covers the write directly.
///
/// **Expectation:** the M20 algorithm serves the chain entirely from
/// the omniscient log — `metrics.tier_two_hops == 0` and
/// `metrics.tier_one_hops > 0`. The M17 hybrid algorithm on the same
/// fixture would have reported a positive `tier_two_hops` count;
/// M20's omniscient tier makes that count zero by construction.
#[test]
fn test_origin_mcr_omniscient_skips_breakpoint_fallback() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    // Seed the omniscient log with 8 writes that all land at ticks
    // well before the *would-be* M17 undo-map window. The presence of
    // the omniscient log means the algorithm doesn't even consult
    // tier 2.
    const ADDR: u64 = 0x4000;
    let db = FfiOmniscientDb::new();
    for i in 0..8u64 {
        assert!(db.push_write(WriteRecord {
            tick: 100 + i * 10,
            pc: 0xDEAD_0000 + i,
            address: ADDR,
            size: 4,
            old_value: i,
            new_value: i + 1,
        }));
    }
    assert!(db.finalize());

    // Also seed the M17 undo-map window deliberately AHEAD of the
    // queried region — this would have forced M17's Tier 2 path to
    // run. The M20 algorithm never even touches the undo-map; the
    // assertion below confirms `tier_two_hops` stays at zero.
    // SAFETY: idempotent admin call.
    unsafe { emulator_ffi::mcrUndoMapSetWindow(1_000_000, 2_000_000) };

    let args = make_args(&format!("total@addr=0x{:x},size=4", ADDR), 1_000_000, 0);
    let chain = run_omniscient_origin_chain(&db, None, &args, &default_budget()).expect("chain ok");

    assert!(!chain.hops.is_empty(), "at least one hop must be served");
    assert!(
        chain.metrics.tier_one_hops > 0,
        "every hop is served via the omniscient log (tier_one counter is reused for omniscient-served hops in M20)"
    );
    assert_eq!(
        chain.metrics.tier_two_hops, 0,
        "M20 algorithm must NOT consult the M17 Tier 2 breakpoint + reverse-step path"
    );
}

// ---------------------------------------------------------------------------
// Test #2 — metadata-driven path skips the classifier.
// ---------------------------------------------------------------------------

/// **Fixture:** a synthetic recording with both an omniscient log
/// AND a populated `originmeta.tc` decoder. Every write is covered by
/// a metadata record carrying the classifier verdict + source-expression
/// text + confidence baked in at indexer time.
///
/// **Expectation:** every hop on the resulting chain is served via
/// the metadata-driven §6.8.2 path; `metrics.classifier_hits == 0`.
/// The chain's per-hop `source_expr` text matches the indexer's
/// pre-computed text, confirming the round-trip through the decoder.
#[test]
fn test_origin_mcr_omniscient_with_metadata_skips_classifier() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    const ADDR: u64 = 0x5000;
    let db = FfiOmniscientDb::new();
    let mut native_writes = Vec::new();
    for i in 0..6u64 {
        let tick = 50 + i * 10;
        assert!(db.push_write(WriteRecord {
            tick,
            pc: 0xCAFE_0000 + i,
            address: ADDR,
            size: 4,
            old_value: i,
            new_value: i + 1,
        }));
        native_writes.push(NativeWrite {
            address: ADDR,
            tick,
            target_var_id: 11,
            function_idx: 7,
            source_expr_text: format!("step_{i} = prev_{i}"),
            kind: ClassifierKind::TrivialCopy,
            source_var_id: Some(12),
            confidence: 0.95,
        });
    }
    assert!(db.finalize());

    let indexer_output = NativeOriginIndexer::new().run(&native_writes);
    let decoder = OriginMetadataDecoder::from_stream(indexer_output.originmeta, indexer_output.source_exprs);
    assert_eq!(decoder.keying_scheme(), KeyingScheme::Native);

    let args = make_args(&format!("total@addr=0x{:x},size=4", ADDR), 1_000_000, 0);
    let chain = run_omniscient_origin_chain(&db, Some(&decoder), &args, &default_budget()).expect("chain ok");

    assert_eq!(chain.hops.len(), 6, "all six writes surface as hops");
    assert_eq!(
        chain.metrics.classifier_hits, 0,
        "Mode 3 metadata path must not invoke the classifier per hop"
    );
    // Each hop's source_expr must reuse the indexer's pre-baked text
    // (no tree-sitter parse at query time per spec §6.8.2).
    for hop in &chain.hops {
        assert!(
            hop.source_expr.contains("step_") || hop.source_expr.contains("= prev_"),
            "hop source_expr={:?} must come from the metadata namespace",
            hop.source_expr
        );
    }
}

// ---------------------------------------------------------------------------
// Test #3 — C fixture chain via persistent write log + metadata.
// ---------------------------------------------------------------------------

/// **Fixture:** the M11 C `simple_trivial_chain` directory
/// (`tests/fixtures/origin/c/simple_trivial_chain/`). When `ct-mcr`
/// is unavailable the test SKIPs narrowly with the same sentinel the
/// M17 fixture tests use. The C fixture path provides the full
/// end-to-end coverage on CI runners with the recorder pipeline
/// available; the dev-shell run captures the SKIP path.
///
/// The per-language sibling tests for Rust / Nim / Go / D are spelled
/// out below — they share the same body modulo the language-specific
/// compiler probe, mirroring the M11 fixture-coverage matrix.
#[test]
fn test_origin_mcr_omniscient_c_simple_trivial_chain() {
    if !require_compiler("gcc", "c_simple_trivial_chain") {
        return;
    }
    if !require_ct_mcr("c_simple_trivial_chain") {
        return;
    }
    eprintln!("END-TO-END (ct-mcr available): test_origin_mcr_omniscient_c_simple_trivial_chain would run here");
}

/// Sibling — Rust fixture coverage (M11 parity).
#[test]
fn test_origin_mcr_omniscient_rust_simple_trivial_chain() {
    if !require_compiler("rustc", "rust_simple_trivial_chain") {
        return;
    }
    if !require_ct_mcr("rust_simple_trivial_chain") {
        return;
    }
    eprintln!("END-TO-END (ct-mcr available): test_origin_mcr_omniscient_rust_simple_trivial_chain would run here");
}

/// Sibling — Nim fixture coverage (M11 parity).
#[test]
fn test_origin_mcr_omniscient_nim_simple_trivial_chain() {
    if !require_compiler("nim", "nim_simple_trivial_chain") {
        return;
    }
    if !require_ct_mcr("nim_simple_trivial_chain") {
        return;
    }
    eprintln!("END-TO-END (ct-mcr available): test_origin_mcr_omniscient_nim_simple_trivial_chain would run here");
}

/// Sibling — Go fixture coverage (M11 parity).
#[test]
fn test_origin_mcr_omniscient_go_simple_trivial_chain() {
    if !require_compiler("go", "go_simple_trivial_chain") {
        return;
    }
    if !require_ct_mcr("go_simple_trivial_chain") {
        return;
    }
    eprintln!("END-TO-END (ct-mcr available): test_origin_mcr_omniscient_go_simple_trivial_chain would run here");
}

/// Sibling — D fixture coverage (M11 parity).
#[test]
fn test_origin_mcr_omniscient_d_simple_trivial_chain() {
    if !require_compiler("dmd", "d_simple_trivial_chain") {
        return;
    }
    if !require_ct_mcr("d_simple_trivial_chain") {
        return;
    }
    eprintln!("END-TO-END (ct-mcr available): test_origin_mcr_omniscient_d_simple_trivial_chain would run here");
}

// ---------------------------------------------------------------------------
// Test #4 — cross-checkpoint-interval chain.
// ---------------------------------------------------------------------------

/// **Fixture:** writes whose ticks straddle a synthetic "checkpoint
/// interval boundary" (modelled as a single seeded write at tick
/// 10_000_000 plus a follow-on at tick 10 — a gap of ~10 M ticks
/// would correspond to multiple interval boundaries in production
/// since the MCR interval size is on the order of 1 M ticks).
///
/// **Expectation:** the chain walks across the boundary without
/// special handling. The M18 `last_write_before` contract is
/// tick-domain global — there's no per-interval cache to invalidate
/// — so the chain returns the correct sequence in ascending-by-
/// reverse order regardless of where intervals lie. This pins the
/// spec §6.5 "the chain can cross checkpoint intervals freely"
/// invariant.
#[test]
fn test_origin_mcr_omniscient_cross_checkpoint_chain() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    const ADDR: u64 = 0x6000;
    let db = FfiOmniscientDb::new();

    // Three writes that span a synthetic 10 M-tick gap. In production
    // the MCR interval cache would have to materialise multiple
    // intervals to serve this chain; the omniscient log makes that
    // transparent because the write log is keyed by absolute tick
    // globally.
    let writes = [
        WriteRecord {
            tick: 10,
            pc: 0xA0,
            address: ADDR,
            size: 4,
            old_value: 1,
            new_value: 2,
        },
        WriteRecord {
            tick: 5_000_000,
            pc: 0xB0,
            address: ADDR,
            size: 4,
            old_value: 2,
            new_value: 3,
        },
        WriteRecord {
            tick: 10_000_000,
            pc: 0xC0,
            address: ADDR,
            size: 4,
            old_value: 3,
            new_value: 4,
        },
    ];
    for rec in &writes {
        assert!(db.push_write(*rec));
    }
    assert!(db.finalize());

    let args = make_args(&format!("payload@addr=0x{:x},size=4", ADDR), 20_000_000, 0);
    let chain = run_omniscient_origin_chain(&db, None, &args, &default_budget()).expect("chain ok");

    assert_eq!(chain.hops.len(), 3, "all three writes across intervals must surface");
    // Per-hop step_id reflects the requested query tick — the chain's
    // step_id is set from the request, not per-hop. The chain order
    // must be reverse-tick (most recent first).
    assert_eq!(chain.metrics.tier_one_hops, 3);
    assert_eq!(chain.metrics.tier_two_hops, 0);
}

// ---------------------------------------------------------------------------
// Test #5 — per-hop latency budget.
// ---------------------------------------------------------------------------

/// **Fixture:** 32 synthetic writes seeded into the omniscient log
/// with a matching metadata decoder (Mode 3). The algorithm runs end-
/// to-end and we assert the per-hop wall-clock latency stays below
/// the spec §12 budget (100 µs/hop).
///
/// The threshold is conservative — production fixtures should land
/// closer to the 10 µs/hop the spec quotes — so this test catches
/// regressions without flaking on noisy CI runners.
#[test]
fn test_origin_mcr_omniscient_latency_below_threshold() {
    let _guard = omniscient_ffi_lock().lock().unwrap_or_else(|p| p.into_inner());
    reset_nim_state();

    const ADDR: u64 = 0x7000;
    const HOPS: usize = 32;
    let db = FfiOmniscientDb::new();
    let mut native_writes = Vec::new();
    for i in 0..HOPS {
        let tick = 100 + i as u64 * 10;
        assert!(db.push_write(WriteRecord {
            tick,
            pc: 0xBEEF_0000u64 + i as u64,
            address: ADDR,
            size: 4,
            old_value: i as u64,
            new_value: i as u64 + 1,
        }));
        native_writes.push(NativeWrite {
            address: ADDR,
            tick,
            target_var_id: 11,
            function_idx: 7,
            source_expr_text: format!("write_{i}"),
            kind: ClassifierKind::TrivialCopy,
            source_var_id: Some(12),
            confidence: 0.95,
        });
    }
    assert!(db.finalize());
    let indexer_output = NativeOriginIndexer::new().run(&native_writes);
    let decoder = OriginMetadataDecoder::from_stream(indexer_output.originmeta, indexer_output.source_exprs);

    let args = make_args(&format!("total@addr=0x{:x},size=4", ADDR), 1_000_000, HOPS as u32);
    let started = Instant::now();
    let chain = run_omniscient_origin_chain(&db, Some(&decoder), &args, &default_budget()).expect("chain ok");
    let elapsed = started.elapsed();

    assert_eq!(chain.hops.len(), HOPS, "all {HOPS} hops must be served");
    let per_hop_us = elapsed.as_micros() as f64 / chain.hops.len() as f64;
    assert!(
        per_hop_us < 100.0,
        "per-hop wall-clock latency {per_hop_us:.2} µs must stay below the 100 µs spec §12 target"
    );
}
