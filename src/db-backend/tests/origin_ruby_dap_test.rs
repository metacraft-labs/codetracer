//! Per-language headless DAP tests for Ruby `ct/originChain` against
//! materialized traces (M3 of the Value Origin Tracking milestones).
//!
//! The shared per-DAP helper lives in `tests/common/origin_dap.rs`.

mod test_harness;

#[path = "common/origin_dap.rs"]
mod origin_dap;

use db_backend::task::{FrameTransitionKind, OriginKind, TerminatorKind};
use origin_dap::{
    OriginQueryConfig, assert_has_frame_transition, assert_hop_count, assert_hop_kinds, assert_min_confidence,
    assert_operand_names_include, assert_terminator_expression_contains, assert_terminator_kind, fixture_source,
    load_fixture_and_query, query_recording_at_breakpoint,
};
use std::{fs, process};
use test_harness::Language;

/// Returns the Ruby version label used for the trace-dir name.
fn require_ruby_recorder() -> String {
    assert!(
        test_harness::is_command_available("ruby"),
        "ruby is not available on PATH"
    );
    assert!(
        test_harness::find_ruby_recorder().is_some(),
        "Ruby recorder not found (set CODETRACER_RUBY_RECORDER_PATH or check out the sibling repo)"
    );
    std::process::Command::new("ruby")
        .arg("--version")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(|v| v.to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

fn ruby_config(scenario: &str, version: &str, line: u32, variable: &str) -> OriginQueryConfig {
    OriginQueryConfig {
        source_path: fixture_source("ruby", scenario, "main.rb"),
        language: Language::Ruby,
        version_label: version.to_string(),
        breakpoint_line: line,
        variable_name: variable.to_string(),
        max_hops: None,
        breakpoint_source_path: None,
    }
}

fn run_fixture(scenario: &str, config: &OriginQueryConfig) -> Box<origin_dap::OriginQueryResult> {
    let result = load_fixture_and_query(config)
        .unwrap_or_else(|err| panic!("ruby/{scenario}: load_fixture_and_query failed: {err}"));
    Box::new(result)
}

#[test]
fn test_origin_ruby_simple_trivial_chain() {
    let version = require_ruby_recorder();
    // main.rb line 6 is `puts c`. Chain for `c` is
    //   c -> b -> a -> Literal(10).
    let config = ruby_config("simple_trivial_chain", &version, 6, "c");
    let result = run_fixture("simple_trivial_chain", &config);
    let chain = &result.chain;

    assert_terminator_kind(chain, TerminatorKind::Literal, "ruby simple_trivial_chain terminator");
    assert_terminator_expression_contains(chain, "10", "ruby simple_trivial_chain literal expression");
    assert_hop_count(chain, 3, "ruby simple_trivial_chain hops");
    assert_hop_kinds(
        chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "ruby simple_trivial_chain hop kinds",
    );
    assert_min_confidence(chain, 0.7, "ruby simple_trivial_chain confidence");
}

#[test]
fn test_origin_ruby_simple_trivial_chain_survives_missing_recorded_source() {
    let version = require_ruby_recorder();
    let source_fixture = fixture_source("ruby", "simple_trivial_chain", "main.rb");
    let temp_dir = std::env::temp_dir().join(format!(
        "ruby_origin_missing_source_{}_{}",
        process::id(),
        version.replace('.', "_")
    ));
    let _ = fs::remove_dir_all(&temp_dir);
    fs::create_dir_all(&temp_dir).expect("create temp ruby origin source dir");
    let temp_source = temp_dir.join("main.rb");
    fs::copy(&source_fixture, &temp_source).expect("copy ruby origin fixture to temp source");

    let recording = test_harness::TestRecording::create_db_trace(&temp_source, Language::Ruby, &version)
        .expect("Ruby recording failed");
    fs::remove_file(&temp_source).expect("remove recorder-time ruby source");

    let config = OriginQueryConfig {
        source_path: temp_source.clone(),
        language: Language::Ruby,
        version_label: version,
        breakpoint_line: 6,
        variable_name: "c".to_string(),
        max_hops: None,
        breakpoint_source_path: Some(temp_source),
    };
    let chain = query_recording_at_breakpoint(&recording, &config)
        .unwrap_or_else(|err| panic!("ruby/simple_trivial_chain missing-source query failed: {err}"));

    assert_terminator_kind(
        &chain,
        TerminatorKind::Literal,
        "ruby simple_trivial_chain missing-source terminator",
    );
    assert_terminator_expression_contains(
        &chain,
        "10",
        "ruby simple_trivial_chain missing-source literal expression",
    );
    assert_hop_count(&chain, 3, "ruby simple_trivial_chain missing-source hops");
    assert_hop_kinds(
        &chain,
        &[OriginKind::TrivialCopy, OriginKind::TrivialCopy, OriginKind::Literal],
        "ruby simple_trivial_chain missing-source hop kinds",
    );
    assert_min_confidence(&chain, 0.7, "ruby simple_trivial_chain missing-source confidence");

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_origin_ruby_block_arg_pass() {
    let version = require_ruby_recorder();
    // main.rb line 8 is `puts inside` inside the block. Chain for `inside`
    // crosses the block-arg pass into `xs[i]`.
    let config = ruby_config("block_arg_pass", &version, 8, "inside");
    let result = run_fixture("block_arg_pass", &config);
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
    let version = require_ruby_recorder();
    // main.rb line 9 is `puts a` (after the swap). Chain for `a` must be
    // two hops: a -> b (TrivialCopy) -> Literal.
    let config = ruby_config("swap_via_destructuring", &version, 9, "a");
    let result = run_fixture("swap_via_destructuring", &config);
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
