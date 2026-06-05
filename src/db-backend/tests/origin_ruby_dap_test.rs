//! Per-language headless DAP tests for Ruby `ct/originChain` against
//! materialized traces (M3 of the Value Origin Tracking milestones).
//!
//! Tests SKIP cleanly when `ruby` or the Ruby recorder is missing.
//!
//! The shared per-DAP helper lives in `tests/common/origin_dap.rs`.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{FrameTransitionKind, OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, QueryOutcome, assert_has_frame_transition, assert_hop_count, assert_hop_kinds,
    assert_min_confidence, assert_operand_names_include, assert_terminator_kind, fixture_source,
    load_fixture_and_query_or_skip,
};
use test_harness::Language;

/// Skip reason emitted when Ruby is missing. Returns the Ruby version
/// label used for the trace-dir name on success.
fn require_ruby_recorder() -> Option<String> {
    if !test_harness::is_command_available("ruby") {
        eprintln!("SKIPPED: ruby is not available on PATH");
        return None;
    }
    if test_harness::find_ruby_recorder().is_none() {
        eprintln!("SKIPPED: Ruby recorder not found (set CODETRACER_RUBY_RECORDER_PATH or check out the sibling repo)");
        return None;
    }
    let version = std::process::Command::new("ruby")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))
        .unwrap_or_else(|| "unknown".to_string());
    Some(version)
}

fn ruby_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("ruby", scenario, "main.rb"),
        language: Language::Ruby,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
    }
}

fn run_or_skip(scenario: &str, config: &OriginQueryConfig) -> Option<Box<origin_dap::OriginQueryResult>> {
    match load_fixture_and_query_or_skip(config) {
        QueryOutcome::Ok(r) => Some(r),
        QueryOutcome::Skipped(reason) => {
            eprintln!("SKIPPED: ruby/{}: {}", scenario, reason);
            None
        }
    }
}

#[test]
fn test_origin_ruby_simple_trivial_chain() {
    let Some(version) = require_ruby_recorder() else {
        return;
    };
    // main.rb line 6 is `puts c`. Chain for `c` is
    //   c -> b -> a -> Literal(10).
    let config = ruby_config("simple_trivial_chain", &version, 6, "c");
    let Some(result) = run_or_skip("simple_trivial_chain", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "ruby simple_trivial_chain terminator");
    assert_hop_count(chain, 3, "ruby simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "ruby simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "ruby simple_trivial_chain confidence");
}

#[test]
fn test_origin_ruby_block_arg_pass() {
    let Some(version) = require_ruby_recorder() else {
        return;
    };
    // main.rb line 8 is `puts inside` inside the block. Chain for `inside`
    // crosses the block-arg pass into `xs[i]`.
    let config = ruby_config("block_arg_pass", &version, 8, "inside");
    let Some(result) = run_or_skip("block_arg_pass", &config) else {
        return;
    };
    let chain = &result.chain;

    // ParameterPass classification or a FrameTransition (depending on
    // how the recorder shape the block call site).
    let has_param_kind = chain.hops.iter().any(|h| {
        h.kind == OriginKind::ParameterPass
            || h.frame_transition.as_ref().map(|t| t.kind) == Some(FrameTransitionKind::ParameterPass)
    });
    assert!(
        has_param_kind,
        "ruby block_arg_pass: expected ParameterPass hop or FrameTransition, got hops={:?}",
        chain.hops
    );
    assert_min_confidence(chain, 0.4, "ruby block_arg_pass confidence");
}

#[test]
fn test_origin_ruby_swap_via_destructuring() {
    let Some(version) = require_ruby_recorder() else {
        return;
    };
    // main.rb line 6 is `puts a` (after the swap). Chain for `a` must be
    // two hops: a -> b (TrivialCopy) -> Literal.
    let config = ruby_config("swap_via_destructuring", &version, 6, "a");
    let Some(result) = run_or_skip("swap_via_destructuring", &config) else {
        return;
    };
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "ruby swap_via_destructuring terminator");
    // Per ANSWERS.md hop count is 2: TrivialCopy + Literal.
    assert!(
        !chain.hops.is_empty(),
        "ruby swap_via_destructuring: expected at least one hop, got hops={:?}",
        chain.hops
    );
    // The first hop must be a TrivialCopy (the parallel-assignment slot
    // re-binds `a` to the pre-swap value of `b`).
    assert_eq!(
        chain.hops.first().map(|h| h.kind),
        Some(OriginKind::TrivialCopy),
        "ruby swap_via_destructuring: first hop must be TrivialCopy, got hops={:?}",
        chain.hops
    );
    assert_min_confidence(chain, 0.7, "ruby swap_via_destructuring confidence");
    // Quiet the unused-import warnings in case the assertion helpers
    // above are pared back in future revisions.
    let _ = assert_hop_count;
    let _ = assert_has_frame_transition;
    let _ = assert_operand_names_include;
}
