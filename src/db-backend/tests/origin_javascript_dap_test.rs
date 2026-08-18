//! Per-language headless DAP tests for JavaScript `ct/originChain`
//! against materialized traces (M3 of the Value Origin Tracking
//! milestones).
//!
//! Tests SKIP cleanly when the JS recorder is missing.
//!
//! The shared per-DAP helper lives in `tests/common/origin_dap.rs`.
//!
//! # Assertion contract
//!
//! Every assertion below is grounded in
//! `codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md`
//! (§7.1 universal classifier table, §7.2 JavaScript / TypeScript
//! per-language overrides) plus the per-fixture `ANSWERS.md` that
//! accompanies each program under `tests/fixtures/origin/javascript/`.
//! The chain shape is asserted exactly — hop count, per-hop
//! `OriginKind`, the source variable each hop continues into, and the
//! terminator — because a test that only checks "the first hop is one
//! of two acceptable kinds" cannot distinguish a correct chain from a
//! chain that was silently truncated after its first hop.
//!
//! The one property from `ANSWERS.md` that is deliberately *not*
//! asserted is `operand_snapshots` on the terminating `Computational`
//! hop. Spec §7.1 defines a `Computational` hop's continuation as "the
//! set of identifier leaves under the RHS"; `[11, 22]` and
//! `{ a: 11, b: 22 }` contain no identifier leaves, so an empty
//! operand set is what §7.1 prescribes. The `ANSWERS.md` wording that
//! lists literal element values as operand snapshots describes a
//! richer capture that §7.1 does not currently require.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{OriginChain, OriginKind, TerminatorKind};
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

/// Assert a hop continues the chain into `expected_source_variable`.
///
/// The source variable is the load-bearing half of a `FieldAccess` /
/// `IndexAccess` hop: it names the value the chain walks back into.
/// Asserting only the `OriginKind` would accept a hop that classified
/// correctly but pointed at the wrong receiver.
fn assert_hop_source_variable(chain: &OriginChain, index: usize, expected: &str, context: &str) {
    let hop = chain.hops.get(index).unwrap_or_else(|| {
        panic!(
            "[{}] expected at least {} hops, got {:?}",
            context,
            index + 1,
            chain.hops
        )
    });
    assert_eq!(
        hop.source_variable.as_deref(),
        Some(expected),
        "[{}] hop {} must continue into {:?} (hop={:?})",
        context,
        index,
        expected,
        hop
    );
}

#[test]
fn test_origin_javascript_object_destructuring() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // `main.js` line 8 is `console.log(a, b)` — the query point named by
    // the fixture's ANSWERS.md ("Query targets: `a` and `b` at the
    // `console.log(a, b)` line").
    //
    // Expected chain, per ANSWERS.md and spec §7.2 JavaScript row
    // ("`const { a, b } = obj` -> two hops, kind=FieldAccess,
    // source_variable=`obj`"):
    //
    //   hop 0: a   <- obj              FieldAccess    (confidence >= 0.7)
    //   hop 1: obj <- { a: 11, b: 22 } Computational
    //   terminator: Computational("{ a: 11, b: 22 }")
    let config = js_config("object_destructuring", &version, 8, "a");
    let Some(result) = run_or_skip("object_destructuring", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_hop_count(chain, 2, "javascript object_destructuring hops");
    // Spec §7.2 JS row: a destructuring binding is observationally
    // equivalent to `const a = obj.a`, so the first hop is FieldAccess —
    // NOT the weaker TrivialCopy the pre-M16 tests also accepted.
    assert_hop_kinds(
        chain,
        &[OriginKind::FieldAccess, OriginKind::Computational],
        "javascript object_destructuring hop kinds",
    );
    assert_hop_source_variable(chain, 0, "obj", "javascript object_destructuring");
    // Spec §6.1.6 / §7.1: the object literal is the computational
    // origin, so the chain must reach it rather than terminating early.
    assert_terminator_kind(
        chain,
        TerminatorKind::Computational,
        "javascript object_destructuring terminator",
    );
    assert_eq!(
        chain.terminator.expression, "{ a: 11, b: 22 }",
        "javascript object_destructuring terminator must be the object literal"
    );
    assert_min_confidence(chain, 0.7, "javascript object_destructuring confidence");
}

#[test]
fn test_origin_javascript_array_destructuring() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // `main.js` line 8 is `console.log(a, b)` — the query point named by
    // the fixture's ANSWERS.md.
    //
    // Expected chain, per ANSWERS.md and spec §7.2 JavaScript row
    // ("`const [a, b] = arr` -> two hops, kind=IndexAccess,
    // source_variable=`arr`"):
    //
    //   hop 0: a   <- arr       IndexAccess    (confidence >= 0.7)
    //   hop 1: arr <- [11, 22]  Computational
    //   terminator: Computational("[11, 22]")
    let config = js_config("array_destructuring", &version, 8, "a");
    let Some(result) = run_or_skip("array_destructuring", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_hop_count(chain, 2, "javascript array_destructuring hops");
    // Spec §7.2 JS row: array destructuring is observationally
    // equivalent to `const a = arr[0]`, so the first hop is IndexAccess.
    assert_hop_kinds(
        chain,
        &[OriginKind::IndexAccess, OriginKind::Computational],
        "javascript array_destructuring hop kinds",
    );
    assert_hop_source_variable(chain, 0, "arr", "javascript array_destructuring");
    assert_terminator_kind(
        chain,
        TerminatorKind::Computational,
        "javascript array_destructuring terminator",
    );
    assert_eq!(
        chain.terminator.expression, "[11, 22]",
        "javascript array_destructuring terminator must be the array literal"
    );
    assert_min_confidence(chain, 0.7, "javascript array_destructuring confidence");
}

#[test]
fn test_origin_javascript_optional_chaining() {
    let Some(version) = require_js_recorder() else {
        return;
    };
    // `main.js` line 9 is `console.log(x)` — the query point named by
    // the fixture's ANSWERS.md ("Query target: local `x` at the
    // `console.log(x)` line").
    //
    // Expected chain, per ANSWERS.md and spec §7.1's
    // `member_expression` row (an optional chain `obj?.field` is a
    // member expression, so it classifies as FieldAccess and continues
    // into the receiver):
    //
    //   hop 0: x   <- obj?.field    FieldAccess    (confidence >= 0.7)
    //   hop 1: obj <- { field: 42 } Computational
    //   terminator: Computational("{ field: 42 }")
    let config = js_config("optional_chaining", &version, 9, "x");
    let Some(result) = run_or_skip("optional_chaining", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_hop_count(chain, 2, "javascript optional_chaining hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::FieldAccess, OriginKind::Computational],
        "javascript optional_chaining hop kinds",
    );
    assert_hop_source_variable(chain, 0, "obj", "javascript optional_chaining");
    assert_terminator_kind(
        chain,
        TerminatorKind::Computational,
        "javascript optional_chaining terminator",
    );
    assert_eq!(
        chain.terminator.expression, "{ field: 42 }",
        "javascript optional_chaining terminator must be the object literal"
    );
    assert_min_confidence(chain, 0.7, "javascript optional_chaining confidence");
}
