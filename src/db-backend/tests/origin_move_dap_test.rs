//! Per-language headless DAP test for Move (Sui / Aptos)
//! `ct/originChain` against materialized traces — **BLOCKED** per
//! M23 of the Value Origin Tracking milestones.
//!
//! ## Why this test is BLOCKED, not SKIPPED
//!
//! Per the M23 spec
//! (`Planned-Features/Value-Origin-Tracking.milestones.org`):
//!
//! > **Blocked-but-tracked**: Move recorder. The current
//! > `move_flow_dap_test.rs` notes "All steps are recorded at line 1;
//! > variable names use bytecode indices." Origin queries on Move
//! > traces today would return `OriginKind::Unknown` with confidence
//! > 0. Adding M23's Move fixture is gated on the recorder shipping
//! > source-map support; until then, the Move test is documented as
//! > `status: pending` with a blocker note in this file.
//!
//! A SKIP would imply the test is "ready to run when the environment
//! is set up" — but here even with a working Move recorder, the
//! recorder's variable-name + line-number contract is structurally
//! incompatible with the classifier's source-line lookup, so no
//! amount of environment setup makes the test pass.  The test body
//! therefore prints a BLOCKED marker and returns 0 so CI sees an
//! honest "intentionally not running" signal rather than a fake
//! green.
//!
//! The fixture body at
//! `tests/fixtures/origin/move/simple_trivial_chain/BLOCKED.md`
//! documents the planned source program; the matching `main.move`
//! lands together with the recorder source-map work.

mod test_harness;

#[test]
fn test_origin_move_canonical_chain() {
    eprintln!(
        "BLOCKED: test_origin_move_canonical_chain — Move recorder lacks source-map support. \
         Origin queries on today's Move traces return OriginKind::Unknown with confidence 0 \
         because the recorder records all steps at line 1 and uses bytecode indices for \
         variable names. Tracked in M23 of the Value Origin Tracking milestones; the test \
         body lands when the Move recorder ships source-map support upstream."
    );

    // Sanity check: a real Move flow DAP test exists in-tree, which
    // is the upstream test the recorder must extend to source-map
    // support before this M23 test can land its fixture body.  We
    // assert the file is committed so the BLOCKED status stays
    // honest — if the upstream test gets renamed, this file flags
    // the breakage at test time.
    let move_flow = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/move_flow_dap_test.rs");
    assert!(
        move_flow.exists(),
        "expected the upstream move_flow_dap_test.rs to exist as the source-map gate \
         (BLOCKED marker for test_origin_move_canonical_chain)"
    );

    // BLOCKED status is observable through the eprintln above; the
    // test passes (exit 0) so CI doesn't burn red on intentionally
    // pending work.
}
