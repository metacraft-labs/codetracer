//! Smoke test for the shared fixture-id constants module.
//!
//! Integration-test modules under `tests/common/` are only compiled when
//! at least one test target declares `mod common;`. This tiny target
//! pulls the module in so:
//!
//! 1. `cargo test` validates the constants at compile time, and
//! 2. the canonical-UUIDv7 and uniqueness assertions in
//!    `common::fixture_ids` run on every full test invocation.
//!
//! New tests that consume fixture ids do the same `mod common;` dance
//! at the top of their `.rs` file (see the pattern used by
//! `aiken_flow_dap_test.rs` and friends with `test_harness`).
//!
//! See M-REC-12 in `codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md`.

mod common;

use common::fixture_ids;

#[test]
fn fixture_id_table_is_non_empty_and_unique() {
    // The two `#[cfg(test)]` checks inside `fixture_ids` (canonical-UUIDv7
    // validation and dup detection) run automatically when cargo descends
    // into the module under `--test fixture_ids_smoke`. We re-assert the
    // gross invariants here so a failure shows up as a *named* failing
    // test (not just a panic deep inside the module's test harness).

    let ids = fixture_ids::ALL_FIXTURE_RECORDING_IDS;

    // 7 language fixtures + 12 MCR fixtures (5 platforms × 2 variants + linux-arm64 placeholder × 2) = 19.
    // `is_empty()` would be a tautology here (it's a const slice) — the
    // exact-length check below is the actual guard against accidental
    // table truncation.
    assert_eq!(
        ids.len(),
        19,
        "fixture id table size changed — update this smoke test and the FIXTURE_IDS.md manifest in lockstep"
    );

    // Cross-check a couple of representative entries to catch accidental
    // table reordering or copy/paste mistakes.
    assert_eq!(
        fixture_ids::PYTHON_FLOW_TEST_RECORDING_ID,
        "019e3a35-2534-7000-8aaa-43ff10050001",
        "python/flow_test fixture id drifted — update the FIXTURE_IDS.md authority too"
    );
    assert_eq!(
        fixture_ids::MCR_LINUX_X86_64_PORTABLE_RECORDING_ID,
        "019e3a35-2540-7a00-8aaa-43ff20010002",
        "mcr/linux-x86_64/trace-portable.ct fixture id drifted — update FIXTURE_IDS.md"
    );
}
