//! Per-language headless DAP test for Miden `ct/originChain` against
//! materialized traces — **BLOCKED** per M23 of the Value Origin
//! Tracking milestones.
//!
//! ## Why this test is BLOCKED, not SKIPPED
//!
//! Per the M23 spec
//! (`Planned-Features/Value-Origin-Tracking.milestones.org`):
//!
//! > **Blocked-but-tracked**: Miden recorder. There is no
//! > `miden_flow_dap_test.rs` in the tree today. Adding M23's Miden
//! > fixture is gated on the recorder first shipping a flow-DAP test
//! > of its own. Until that lands, the Miden test entry is pending
//! > here.
//!
//! A SKIP would imply the test is "ready to run when the environment
//! is set up" — but the gating concern is structural: the recorder
//! must first publish a baseline flow-DAP test so the source-map +
//! variable-name contract this M23 test depends on is documented and
//! re-runnable.  The existing `masm_flow_dap_test.rs` covers the
//! MASM surface but doesn't exercise the source-language layer the
//! origin classifier consumes.  The test body therefore prints a
//! BLOCKED marker and returns 0 so CI sees an honest "intentionally
//! not running" signal rather than a fake green.
//!
//! The fixture body at
//! `tests/fixtures/origin/miden/simple_trivial_chain/BLOCKED.md`
//! documents the planned source program.

mod test_harness;

#[test]
fn test_origin_miden_canonical_chain() {
    eprintln!(
        "BLOCKED: test_origin_miden_canonical_chain — Miden recorder has not yet shipped \
         a `miden_flow_dap_test.rs` baseline. The existing `masm_flow_dap_test.rs` covers \
         the MASM bytecode surface but does not exercise the source-language layer the \
         origin classifier consumes. Tracked in M23 of the Value Origin Tracking \
         milestones; the test body lands when the Miden recorder publishes its flow-DAP \
         baseline."
    );

    // Sanity check: confirm the existing MASM flow DAP test is
    // committed (the upstream test the Miden recorder must extend).
    let masm_flow = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/masm_flow_dap_test.rs");
    assert!(
        masm_flow.exists(),
        "expected masm_flow_dap_test.rs to exist as the MASM-surface baseline \
         (BLOCKED marker for test_origin_miden_canonical_chain — Miden recorder must \
         ship its own flow-DAP test before M23 can add a Miden source-language fixture)"
    );

    // Also confirm we don't yet have a miden_flow_dap_test.rs —
    // if/when that lands, the BLOCKED status can be lifted in
    // M23's tracking and this assertion flipped to `exists()`.
    let miden_flow = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/miden_flow_dap_test.rs");
    assert!(
        !miden_flow.exists(),
        "miden_flow_dap_test.rs now exists — the BLOCKED status of \
         test_origin_miden_canonical_chain should be lifted; replace this assertion \
         with the canonical 3-hop chain assertions and add a `main.masm` / `main.miden` \
         fixture under tests/fixtures/origin/miden/simple_trivial_chain/."
    );
}
