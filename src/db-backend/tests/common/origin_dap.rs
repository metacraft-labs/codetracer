//! Shared helper for the per-language `ct/originChain` DAP tests
//! (M3 of the Value Origin Tracking milestones).
//!
//! Each per-language test file (`origin_python_dap_test.rs`,
//! `origin_ruby_dap_test.rs`, `origin_javascript_dap_test.rs`) drives a
//! real recorder against the M0 fixture programs and asserts the per-hop
//! shape against the per-fixture `ANSWERS.md`.
//!
//! The helper in this module factors out:
//!
//! - Recording the fixture via [`super::super::test_harness::TestRecording::create_db_trace`]
//! - Spawning the `replay-server dap-server --stdio` process via
//!   [`super::super::test_harness::DapStdioTestClient`]
//! - Setting a breakpoint at the fixture's query line, continuing to it,
//!   and issuing a `ct/originChain` request with the supplied arguments
//! - Decoding the response body into an [`OriginChain`]
//!
//! The trio of language test files share this module via `#[path]`
//! includes (each test crate is its own Cargo target and can't `mod
//! common;` portably unless every file inside the module compiles in
//! every test crate). See [`MODULE_USAGE`] for the exact include shape.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::time::Duration;

use db_backend::dap::DapMessage;
use db_backend::task::{
    CtOriginChainArguments, DEFAULT_ORIGIN_MAX_HOPS, Location, OriginChain, OriginKind, TerminatorKind,
};
use serde_json::json;

// The per-language origin DAP test files include this module via
// `#[path = "common/origin_dap.rs"] mod origin_dap;`. Each test file
// must ALSO declare `mod test_harness;` so that the `crate::test_harness`
// path used here resolves inside the test crate.
use crate::test_harness::{DapStdioTestClient, Language, TestRecording};

/// Documentation-only constant describing the recommended include shape.
///
/// Test files cannot `mod common;` because each integration test is its
/// own Cargo crate and `tests/common/mod.rs` would have to compile
/// uniformly across every test target. Instead, each language test
/// uses two `#[path]` includes to pull in the test harness and this
/// helper:
///
/// ```ignore
/// #[path = "test_harness/mod.rs"]
/// mod test_harness;
///
/// #[path = "common/origin_dap.rs"]
/// mod origin_dap;
/// ```
pub const MODULE_USAGE: &str = "see top-of-file include pattern in origin_python_dap_test.rs";

/// Configuration for one origin-chain DAP query against a recorded fixture.
pub struct OriginQueryConfig {
    /// Absolute path the recorder is invoked against.  For most
    /// languages this is the source file (`main.py` / `main.rb` /
    /// `main.js`); for build-system-based recorders (Noir's
    /// `nargo trace`, Sway's `forc build`) it is the project
    /// directory containing the manifest.
    pub source_path: PathBuf,
    /// Language label for the recorder.
    pub language: Language,
    /// Free-form version label (Python version, Ruby version, Node
    /// version, etc.) - included in the temp-dir name so concurrent
    /// runs don't clobber each other.
    pub version_label: String,
    /// 1-based source line at which to set the breakpoint. The query
    /// happens at the step where the program stops.
    pub breakpoint_line: u32,
    /// Variable to ask about. Spec V1 is identifier-only.
    pub variable_name: String,
    /// Optional maximum hops (defaults to [`DEFAULT_ORIGIN_MAX_HOPS`]).
    pub max_hops: Option<u32>,
    /// Optional source-file override for the breakpoint.  When set,
    /// the breakpoint is placed at this path rather than at the
    /// `source_path` (used by recorders whose `source_path` is a
    /// project directory — e.g. Noir / Sway — but whose breakpoints
    /// must address the actual `.nr` / `.sw` file inside the
    /// project).
    pub breakpoint_source_path: Option<PathBuf>,
}

/// Result of a successful query: the recorded trace + the resolved chain.
///
/// We carry both `recording` and `chain` so callers can inspect raw
/// trace metadata for diagnostics on assertion failures (e.g. dumping
/// `recording.trace_dir`).
pub struct OriginQueryResult {
    pub recording: TestRecording,
    pub chain: OriginChain,
}

/// Outcome of [`load_fixture_and_query`] - either a usable chain or a
/// skip reason that the caller should report via `eprintln!`.
///
/// `Ok` carries a `Box<_>` so the `Skipped(String)` variant doesn't
/// inflate every call frame with an unused trace handle - the test
/// crates compile with `-D clippy::large_enum_variant`.
pub enum QueryOutcome {
    Ok(Box<OriginQueryResult>),
    /// A clear environment problem (recorder native extension missing,
    /// language interpreter version too old, etc.) - the caller should
    /// `eprintln!("SKIPPED: ...")` and return without failing the test.
    Skipped(String),
}

/// Record the fixture, spawn db-backend, set a breakpoint at the
/// configured line, send `ct/originChain` for the configured variable,
/// and return the decoded [`OriginChain`].
///
/// Errors are returned as `String` to match the rest of the test
/// harness (which avoids the `Result<_, Box<dyn Error>>` complexity in
/// tests).
pub fn load_fixture_and_query(config: &OriginQueryConfig) -> Result<OriginQueryResult, String> {
    let recording = TestRecording::create_db_trace(&config.source_path, config.language, &config.version_label)
        .map_err(|e| format!("recording failed for {}: {}", config.source_path.display(), e))?;

    let chain = query_recording_at_breakpoint(&recording, config)?;

    Ok(OriginQueryResult { recording, chain })
}

/// Spawn db-backend for an existing recording, set the configured
/// breakpoint, and issue `ct/originChain`.
///
/// This is used by regression tests that need to alter the recorder-time
/// filesystem after trace creation. The returned chain must be answerable from
/// the trace plus the debugger's breakpoint/source mapping, not from an
/// accidental still-present original source path.
pub fn query_recording_at_breakpoint(
    recording: &TestRecording,
    config: &OriginQueryConfig,
) -> Result<OriginChain, String> {
    // When `breakpoint_source_path` is explicit (Noir / Sway / any
    // recorder whose `source_path` is a project directory), use it
    // verbatim; otherwise derive the breakpoint source from
    // `source_path` via the per-language rules.
    let breakpoint_source = if let Some(p) = &config.breakpoint_source_path {
        p.clone()
    } else {
        resolve_breakpoint_source(recording, &config.source_path, config.language)
    };

    let mut client = DapStdioTestClient::start().map_err(|e| format!("failed to start DAP stdio client: {}", e))?;
    client
        .initialize_and_launch(recording)
        .map_err(|e| format!("failed to initialize DAP session: {}", e))?;
    client
        .set_breakpoint(&breakpoint_source, config.breakpoint_line)
        .map_err(|e| {
            format!(
                "failed to set breakpoint at {}:{} - {}",
                breakpoint_source.display(),
                config.breakpoint_line,
                e
            )
        })?;
    let location = client
        .continue_to_breakpoint()
        .map_err(|e| format!("failed to continue to breakpoint: {}", e))?;

    let chain = send_origin_chain_request(&mut client, &config.variable_name, &location, config.max_hops)
        .map_err(|e| format!("ct/originChain request failed: {}", e))?;

    Ok(chain)
}

/// Same as [`load_fixture_and_query`] but folds clear environment
/// failures (recorder native extension missing, recorder produced no
/// `.ct`, recorder couldn't load) into a [`QueryOutcome::Skipped`]
/// result.
///
/// The classification heuristic looks for the exact sentinel strings
/// emitted by the test harness and the recorders themselves; anything
/// else surfaces as a hard failure so genuine M3 bugs aren't hidden.
pub fn load_fixture_and_query_or_skip(config: &OriginQueryConfig) -> QueryOutcome {
    match load_fixture_and_query(config) {
        Ok(r) => QueryOutcome::Ok(Box::new(r)),
        Err(msg) => {
            if is_environment_failure(&msg) {
                QueryOutcome::Skipped(msg)
            } else {
                panic!(
                    "load_fixture_and_query failed with a non-environment error - investigate as an M3 bug: {}",
                    msg
                );
            }
        }
    }
}

/// Return true when an error string from [`load_fixture_and_query`]
/// looks like a recorder/environment problem rather than a genuine
/// code bug.
///
/// **Policy (M3 fix-up)**: keep the matcher **strictly narrow**. Only
/// errors that we can prove are environmental (the recorder is not
/// installed, the language interpreter is too old, a native extension
/// is missing) are folded into a SKIPPED outcome. Broad matchers like
/// "recording failed:" used to mask genuine recorder bugs as SKIPs and
/// silently passed the test suite — they are removed.
///
/// To add a new sentinel: make sure the failure message string is
/// emitted from a code path that is GUARANTEED to be an environment
/// gap (recorder lookup failure, missing native library) and not
/// merely a recorder runtime error. When in doubt, propagate the
/// error as a real test failure.
fn is_environment_failure(msg: &str) -> bool {
    let lower = msg.to_ascii_lowercase();

    // Harness-side sentinels — emitted by `test_harness::find_*_recorder`
    // and `record_*_trace` when the recorder binary / native extension
    // isn't available on this machine.
    const ENV_SENTINELS: &[&str] = &[
        // `find_<lang>_recorder` returned None.
        "recorder not found",
        // `find_<lang>_recorder` resolved to a binary missing from PATH.
        "is not available on path",
        // CTFS recorder ran but produced no native trace (e.g. native
        // tracer .so failed to load).
        "native tracer unavailable",
        // The harness ran the recorder but no `.ct` container was
        // produced — this is the standard "native extension not
        // installed" sentinel emitted by Ruby / JS test harnesses
        // when their CTFS writers aren't built. The exact harness
        // message is "no *.ct container produced in <dir>".
        "no *.ct container produced",
        // Python `import codetracer_python_recorder` failed.
        "module not importable",
        // Per-language interpreter version gates.
        "version too old",
        "requires python 3.10",
        "requires node",
        "requires ruby",
        // Environment-variable sentinels surfaced by the harness when
        // an explicit override path doesn't exist. Match the
        // upper-case env-var form specifically so that random
        // mentions of the recorder module path (e.g. inside a
        // recorder traceback) don't get folded into SKIPPED.
        "codetracer_python_recorder_path",
        "codetracer_ruby_recorder_path",
        "codetracer_js_recorder_path",
    ];

    ENV_SENTINELS.iter().any(|s| lower.contains(s))
}

/// Match the breakpoint source path to how the recorder stores paths
/// (mirrors the per-language switch in [`super::super::test_harness::run_db_flow_test_with_format`]).
fn resolve_breakpoint_source(recording: &TestRecording, source_path: &Path, language: Language) -> PathBuf {
    match language {
        // Python recorder stores bare filenames relative to its CWD
        // (= trace_dir); use the trace-dir copy.
        Language::Python => {
            if let Some(filename) = source_path.file_name() {
                recording.trace_dir.join(filename)
            } else {
                source_path.to_path_buf()
            }
        }
        // Ruby and JavaScript record absolute paths and the DAP server
        // matches by suffix; the original source path works directly.
        _ => source_path.to_path_buf(),
    }
}

/// Send a `ct/originChain` DAP request and return the decoded chain.
///
/// The request payload mirrors the M2 wire shape - `variable_name`,
/// `step_id`, and `frame_id` come from the breakpoint's [`Location`]
/// (we use `step_id` from the location and `frame_id = -1` to mean
/// "topmost frame", which is exactly what the spec calls out for V1).
fn send_origin_chain_request(
    client: &mut DapStdioTestClient,
    variable_name: &str,
    location: &Location,
    max_hops: Option<u32>,
) -> Result<OriginChain, String> {
    let args = CtOriginChainArguments {
        variable_name: variable_name.to_string(),
        variable_path: Vec::new(),
        frame_id: -1,
        step_id: location.rr_ticks.0,
        thread_id: 0,
        max_hops: max_hops.unwrap_or(DEFAULT_ORIGIN_MAX_HOPS),
        lazy: false,
        continuation_token: None,
        session_id: String::new(),
        classify_source: true,
    };
    let arg_value = serde_json::to_value(&args).map_err(|e| format!("failed to serialise args: {}", e))?;
    let req = client.dap_client_mut().request("ct/originChain", arg_value);
    client.send_message(&req)?;
    let response = client.read_until_response_msg("ct/originChain", Duration::from_secs(30))?;
    decode_origin_chain_response(&response)
}

/// Extract an [`OriginChain`] from the DAP response payload, surfacing
/// the per-spec error codes (6101-6106) as informative `String` errors
/// when the request returned `success: false`.
fn decode_origin_chain_response(response: &DapMessage) -> Result<OriginChain, String> {
    match response {
        DapMessage::Response(r) => {
            if !r.success {
                let detail = r.body.get("detail").cloned().unwrap_or(json!(null));
                let code = r.body.get("originErrorCode").and_then(|v| v.as_u64()).unwrap_or(0);
                return Err(format!(
                    "ct/originChain returned error code {} message={:?} detail={}",
                    code, r.message, detail
                ));
            }
            serde_json::from_value::<OriginChain>(r.body.clone()).map_err(|e| {
                format!(
                    "failed to decode OriginChain from response body: {} (body={})",
                    e, r.body
                )
            })
        }
        other => Err(format!("expected ct/originChain response, got {:?}", other)),
    }
}

// ---------------------------------------------------------------------------
// Per-fixture assertion helpers - each one focuses on a single property
// the per-fixture ANSWERS.md cares about, so failures point at exactly
// the property that broke rather than a giant `assert_eq!` on the whole
// chain.
// ---------------------------------------------------------------------------

/// Assert the chain terminated at the expected kind, with a helpful
/// diff message when it didn't.
pub fn assert_terminator_kind(chain: &OriginChain, expected: TerminatorKind, context: &str) {
    if chain.terminator.kind != expected {
        panic!(
            "[{}] expected terminator kind {:?}, got {:?} (terminator.expression={:?}, hops={:?})",
            context, expected, chain.terminator.kind, chain.terminator.expression, chain.hops
        );
    }
}

/// Assert the terminator expression contains the expected literal text.
pub fn assert_terminator_expression_contains(chain: &OriginChain, expected: &str, context: &str) {
    if !chain.terminator.expression.contains(expected) {
        panic!(
            "[{}] expected terminator expression to contain {:?}, got {:?} (terminator={:?}, hops={:?})",
            context, expected, chain.terminator.expression, chain.terminator, chain.hops
        );
    }
}

/// Assert the chain has exactly `expected` hops.
pub fn assert_hop_count(chain: &OriginChain, expected: usize, context: &str) {
    if chain.hops.len() != expected {
        panic!(
            "[{}] expected {} hops, got {} (kinds={:?})",
            context,
            expected,
            chain.hops.len(),
            chain.hops.iter().map(|h| h.kind).collect::<Vec<_>>()
        );
    }
}

/// Assert the per-hop OriginKind sequence matches `expected_kinds`.
pub fn assert_hop_kinds(chain: &OriginChain, expected_kinds: &[OriginKind], context: &str) {
    let actual: Vec<OriginKind> = chain.hops.iter().map(|h| h.kind).collect();
    if actual != expected_kinds {
        panic!(
            "[{}] expected hop kinds {:?}, got {:?}",
            context, expected_kinds, actual
        );
    }
}

/// Assert at least one hop has a [`db_backend::task::FrameTransition`]
/// whose kind matches `expected_kind`.
pub fn assert_has_frame_transition(
    chain: &OriginChain,
    expected_kind: db_backend::task::FrameTransitionKind,
    context: &str,
) {
    let found = chain
        .hops
        .iter()
        .any(|h| h.frame_transition.as_ref().map(|t| t.kind) == Some(expected_kind));
    if !found {
        panic!(
            "[{}] expected at least one hop with FrameTransitionKind::{:?}, got hops={:?}",
            context, expected_kind, chain.hops
        );
    }
}

/// Assert every hop's `confidence` is >= `min_confidence`.
pub fn assert_min_confidence(chain: &OriginChain, min_confidence: f32, context: &str) {
    for (idx, hop) in chain.hops.iter().enumerate() {
        if hop.confidence < min_confidence {
            panic!(
                "[{}] hop {} has confidence {} < expected minimum {} (kind={:?})",
                context, idx, hop.confidence, min_confidence, hop.kind
            );
        }
    }
}

/// Assert at least one Computational hop carries operand snapshots whose
/// names contain *all* of `expected_names` (order-insensitive).
///
/// The per-language regenerated chains may pad operand snapshots with
/// extras (e.g. leaf identifiers introduced by classifier-time
/// rewrites). The assertion is "must include" rather than "must equal".
pub fn assert_operand_names_include(chain: &OriginChain, expected_names: &[&str], context: &str) {
    let computational_hop = chain.hops.iter().find(|h| h.kind == OriginKind::Computational);
    let Some(hop) = computational_hop else {
        panic!(
            "[{}] expected a Computational hop with operand snapshots, got hops={:?}",
            context, chain.hops
        );
    };
    let actual_names: Vec<&str> = hop.operand_snapshots.iter().map(|o| o.name.as_str()).collect();
    for expected in expected_names {
        if !actual_names.iter().any(|n| n == expected) {
            panic!(
                "[{}] Computational hop missing operand {:?} (operands={:?})",
                context, expected, actual_names
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Public adapter on DapStdioTestClient
//
// The test_harness module exposes a `send` / `read_until_response` API
// only through the public flow helpers. Origin-chain testing needs to
// send a custom request and read its bespoke response, so the helper
// adds two adapter functions on the harness's stdio client.
// ---------------------------------------------------------------------------
//
// (Implemented as inherent helpers via `impl` block in
// `test_harness::DapStdioTestClient` - see `dap_client_mut`,
// `send_message`, and `read_until_response_msg` there.)

/// Path to the fixtures directory under
/// `codetracer/src/db-backend/tests/fixtures/origin/<lang>/<scenario>/`.
pub fn fixture_dir(language_subdir: &str, scenario: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("origin")
        .join(language_subdir)
        .join(scenario)
}

/// Returns the standard `main.<ext>` file inside a fixture directory.
pub fn fixture_source(language_subdir: &str, scenario: &str, file_name: &str) -> PathBuf {
    fixture_dir(language_subdir, scenario).join(file_name)
}
