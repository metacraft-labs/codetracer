//! Per-language headless DAP tests for JavaScript `ct/originChain`
//! against materialized traces (M3 of the Value Origin Tracking
//! milestones).
//!
//! Tests SKIP cleanly when the JS recorder is missing.
//!
//! The shared per-DAP helper lives in `tests/common/origin_dap.rs`.
//!
//! # M16a/M16b TODO
//!
//! The JavaScript recorder does not yet emit explicit `Assignment`
//! events (only per-step `Value` snapshots), so the destructuring tests
//! depend on the classifier walking the right-hand side of the source
//! line. M16a/M16b add JS Assignment events to the recorder, which
//! lets the destructuring tests assert FieldAccess / IndexAccess
//! classifications more strictly. For M3 the tests assert either
//! the FieldAccess/IndexAccess classification *or* a TrivialCopy
//! with a confidence >= 0.7; the stricter assertion lands with M16b.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_hop_count, assert_hop_kinds, assert_min_confidence, assert_terminator_kind,
    fixture_source, load_fixture_and_query_or_skip,
};
use test_harness::Language;

/// Skip reason emitted when the JS recorder is unavailable. Returns
/// the Node.js version string used as the trace-dir label on success.
fn require_js_recorder() -> Option<String> {
    if test_harness::find_js_recorder().is_none() {
        eprintln!(
            "SKIPPED: JavaScript recorder not found (set CODETRACER_JS_RECORDER_PATH or build codetracer-js-recorder)"
        );
        return None;
    }
    let version = std::process::Command::new("node")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    Some(version)
}

fn js_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("javascript", scenario, "main.js"),
        language: Language::JavaScript,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: None,
    }
}

fn run_or_skip(scenario: &str, config: &OriginQueryConfig) -> Option<Box<origin_dap::OriginQueryResult>> {
    match load_fixture_and_query_or_skip(config) {
        QueryOutcome::Ok(r) => Some(r),
        QueryOutcome::Skipped(reason) => {
            eprintln!("SKIPPED: javascript/{}: {}", scenario, reason);
            None
        }
    }
}

#[test]
fn test_origin_javascript_simple_trivial_chain() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // main.js line 7 is `console.log(c)`. Chain for `c` is
    //   c -> b -> a -> Literal(10).
    let config = js_config("simple_trivial_chain", &version, 7, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(
        chain,
        TerminatorKind::Literal,
        "javascript simple_trivial_chain terminator",
    );
    assert_hop_count(chain, 3, "javascript simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "javascript simple_trivial_chain hop kinds",
    );
    let literal_hop = chain.hops.get(2).expect("third hop must be the Literal assignment");
    assert_eq!(
        literal_hop.target_expr, "a",
        "javascript simple_trivial_chain final hop must target the original variable"
    );
    assert_eq!(
        literal_hop.source_expr, "10",
        "javascript simple_trivial_chain final hop must preserve the literal RHS"
    );
    assert_eq!(
        chain.terminator.expression, "10",
        "javascript simple_trivial_chain terminator must be Literal(10)"
    );
    assert_min_confidence(chain, 0.7, "javascript simple_trivial_chain confidence");
}

#[test]
fn test_origin_javascript_object_destructuring() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // main.js line 6 is `console.log(a, b)`. Chain for `a` is
    //   a (FieldAccess "a") -> obj -> Computational literal.
    //
    // M16a/M16b TODO: when the JS recorder emits Assignment events,
    // tighten this to require OriginKind::FieldAccess specifically.
    let config = js_config("object_destructuring", &version, 6, "a");
    let Some(result) = run_or_skip("object_destructuring", &config) else {
        return;
    };
    let chain = &result.chain;

    let first_kind = chain.hops.first().map(|h| h.kind);
    let acceptable = matches!(
        first_kind,
        Some(OriginKind::FieldAccess) | Some(OriginKind::TrivialCopy)
    );
    assert!(
        acceptable,
        "javascript object_destructuring: first hop must be FieldAccess or TrivialCopy, got {:?} (full hops={:?})",
        first_kind, chain.hops
    );
    assert_min_confidence(chain, 0.7, "javascript object_destructuring confidence");
}

#[test]
fn test_origin_javascript_array_destructuring() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // main.js line 6 is `console.log(a, b)`. Chain for `a` is
    //   a (IndexAccess [0]) -> arr -> Computational literal.
    let config = js_config("array_destructuring", &version, 6, "a");
    let Some(result) = run_or_skip("array_destructuring", &config) else {
        return;
    };
    let chain = &result.chain;

    let first_kind = chain.hops.first().map(|h| h.kind);
    let acceptable = matches!(
        first_kind,
        Some(OriginKind::IndexAccess) | Some(OriginKind::TrivialCopy)
    );
    assert!(
        acceptable,
        "javascript array_destructuring: first hop must be IndexAccess or TrivialCopy, got {:?} (full hops={:?})",
        first_kind, chain.hops
    );
    assert_min_confidence(chain, 0.7, "javascript array_destructuring confidence");
}

#[test]
fn test_origin_javascript_optional_chaining() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // main.js line 5 is `console.log(x)`. Chain for `x` is
    //   x (FieldAccess "field") -> obj -> Computational literal.
    let config = js_config("optional_chaining", &version, 5, "x");
    let Some(result) = run_or_skip("optional_chaining", &config) else {
        return;
    };
    let chain = &result.chain;

    let first_kind = chain.hops.first().map(|h| h.kind);
    let acceptable = matches!(
        first_kind,
        Some(OriginKind::FieldAccess) | Some(OriginKind::TrivialCopy)
    );
    assert!(
        acceptable,
        "javascript optional_chaining: first hop must be FieldAccess or TrivialCopy, got {:?} (full hops={:?})",
        first_kind, chain.hops
    );
    assert_min_confidence(chain, 0.7, "javascript optional_chaining confidence");
}
