//! M29 — GUI-layer E2E test stub for cross-process origin chains.
//! Honestly deferred per M5 discipline.
//!
//! ## Why the test is deferred
//!
//! The `e2e_origin_cross_process_fixture_a_python_aiohttp_renders_in_codetracer`
//! entry in the M29 verification block (per §5.4 of the Cross-
//! Process Origin E2E Test Design doc) drives a Playwright session
//! against:
//!
//! 1. A real frontend recording produced by the M26 browser
//!    recorder (Vite plugin + Playwright + Chrome).
//! 2. A real backend recording produced by the per-language
//!    recorder (Python aiohttp for the canonical fixture).
//! 3. The product Electron app launched against the `session.toml`
//!    that pairs them.
//!
//! None of the three production paths are runnable from inside
//! `cargo test`: each requires the recorder fixture infrastructure
//! described in the E2E design doc §3.4 (`record.sh` +
//! `regenerate.sh` + the per-backend cache), which is honestly
//! deferred per the M29 milestone PROPERTIES.
//!
//! Per M5 discipline (no broad SKIP heuristics — every deferred test
//! must carry a precise reason), this stub:
//!
//! - Documents the dependency chain on the recorder infrastructure.
//! - Provides a single Rust `#[test] #[ignore]` entry so the test
//!   surfaces in `cargo test --list` and CI dashboards.
//! - Leaves the per-fixture `e2e_origin_cross_process_*` Playwright
//!   tests to be authored alongside the recorder fixtures (per the
//!   E2E design doc §3.4 and the M29 deferred-deliverables list).

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

/// `e2e_origin_cross_process_fixture_a_python_aiohttp_renders_in_codetracer`
///
/// SKIP — see module-level docs. This test will be re-implemented as
/// a Playwright suite under `codetracer/src/tests/gui/tests/cross-process/`
/// once the recorder fixture infrastructure described in the E2E
/// design doc §3.4 lands. Tracked as part of the M29 deferred-
/// deliverables list.
#[test]
#[ignore = "GUI E2E test requires the recorder-driven fixture infrastructure (E2E design doc §3.4); honestly deferred per M5 discipline."]
fn e2e_origin_cross_process_fixture_a_python_aiohttp_renders_in_codetracer() {
    panic!("this test is unconditionally ignored; see module-level docs for the M5-discipline defer reason.");
}
