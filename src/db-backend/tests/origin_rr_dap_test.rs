//! M11 — RR-driver origin DAP verification tests.
//!
//! Implements verification tests #2–#15 from the milestone (tests #1,
//! #16, #17, #18 live in separate files: `origin_rr_smoke.rs` for #1,
//! and the GUI / extension specs under `codetracer/src/tests/gui/` and
//! `codetracer-vscode-extension/test/wdio/` for the e2e tests).
//!
//! # Three kinds of test, and where each runs
//!
//! **Tests that need no replay backend** (fixture files committed, the RR
//! budget constants) run everywhere, unconditionally.
//!
//! **Tests with an end-to-end body** live in [`rr`]. They record a fixture
//! under rr and replay it through `ct-native-replay`, so they are compiled
//! only on Linux, the one platform rr supports. On Linux they have no skip
//! path: a missing `rr`, `ct-native-replay` or compiler FAILS the test and
//! names the remedy. A lane without an rr backend does not run them at
//! all, and says so, rather than letting them pass: it declares
//! `CODETRACER_RR_BACKEND_PRESENT=0` and excludes the `rr::` tests
//! (`just test-rust` does both and prints which tests it left out). They
//! run in `cross-repo-tests.yml`'s `rr-backend-tests` job, through the
//! `origin-rr` selector of `scripts/run-cross-repo-tests.sh`.
//!
//! **Tests whose end-to-end body was never written** are `#[ignore]`d with a
//! `pending:` reason. The test runner reports them as ignored, which is
//! what they are; they are never counted as passed. Running one anyway
//! (`--run-ignored`) reaches `unimplemented_end_to_end`, which fails and
//! says what to implement. The fixture files they would read are checked by
//! `test_origin_rr_fixture_files_committed`.
//!
//! # rr on AMD Zen hosts
//!
//! rr refuses to record on a Zen CPU unless the SpecLockMap optimisation is
//! disabled (rr's `check_for_zen_speclockmap`, see
//! <https://github.com/rr-debugger/rr/wiki/Zen>). On such a host the `rr::`
//! tests fail inside the fixture's `regenerate.sh` with rr's own message;
//! that is an environment failure, and it is reported, not skipped.

mod test_harness;

use std::path::PathBuf;

/// Return the absolute path of an M0/M11 fixture's source file under
/// `tests/fixtures/origin/<lang>/<scenario>/<file>`.
fn fixture_source(language_subdir: &str, scenario: &str, file_name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("origin")
        .join(language_subdir)
        .join(scenario)
        .join(file_name)
}

/// Assert the fixture directory ships the expected canonical files:
/// `main.<ext>`, `ANSWERS.md`, `regenerate.sh`. Returns the source
/// path; panics (a real test failure) when the fixture is missing,
/// because the fixture authoring is M11's responsibility and a missing
/// fixture would mask a real regression behind a SKIP.
fn assert_fixture_exists(language_subdir: &str, scenario: &str, file_name: &str) -> PathBuf {
    let src = fixture_source(language_subdir, scenario, file_name);
    let dir = src
        .parent()
        .expect("fixture path must have a parent directory")
        .to_path_buf();
    assert!(
        src.exists(),
        "fixture source missing: {} (M11 must ship `{}` under `tests/fixtures/origin/{}/{}/`)",
        src.display(),
        file_name,
        language_subdir,
        scenario
    );
    let answers = dir.join("ANSWERS.md");
    assert!(answers.exists(), "fixture ANSWERS.md missing: {}", answers.display());
    let regen = dir.join("regenerate.sh");
    assert!(regen.exists(), "fixture regenerate.sh missing: {}", regen.display());
    src
}

/// The body of a test whose end-to-end half was never written.
///
/// Every caller is `#[ignore]`d with a `pending:` reason, so the runner
/// reports it as ignored rather than passed. Running one anyway
/// (`--run-ignored`) reaches this and fails, naming what to implement —
/// never a quiet success for work that did not happen. See
/// `codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md`.
///
/// Diverges, so the caller cannot accidentally continue into a vacuous
/// success.
fn unimplemented_end_to_end(test_name: &str, fixture: &str) -> ! {
    panic!(
        "UNIMPLEMENTED END-TO-END BODY: `{test_name}` asserts nothing.\n\
         It is ignored as pending; it records nothing, replays nothing and checks nothing.\n\
         Implement it against `tests/fixtures/origin/{fixture}/ANSWERS.md`, using \
         `rr::test_origin_rr_cross_thread_copy_tagged` in this file as the worked template \
         (record via `record_rr_fixture_with_regenerate`, drive the DAP client, then \
         assert the chain with `send_rr_origin_chain_request`).\n\
         Tracked in `codetracer-specs/Testing/Known-Test-Failures.md`."
    );
}

// ---------------------------------------------------------------------------
// Test #2 — stack-slot reuse guard.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/stack_slot_reuse/ANSWERS.md"]
fn test_origin_rr_stack_slot_reuse_guard() {
    // End-to-end runs on a CI runner with the RR toolchain installed.
    // The verification will:
    //   1. Drive `regenerate.sh` to produce the RR trace.
    //   2. Spawn db-backend with the trace.
    //   3. Set a breakpoint at the printf line.
    //   4. Send `ct/originChain` for `x`.
    //   5. Assert NO hop carries target=tmp or source_text="int tmp = 7;".
    unimplemented_end_to_end("test_origin_rr_stack_slot_reuse_guard", "c/stack_slot_reuse");
}

// ---------------------------------------------------------------------------
// Test #3 — cross-thread copy tagged: see `rr::test_origin_rr_cross_thread_copy_tagged`.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test #4-#6 — per-language canonical fixtures (C).
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_c_simple_trivial_chain() {
    unimplemented_end_to_end("test_origin_rr_c_simple_trivial_chain", "c/simple_trivial_chain");
}

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/computational_origin/ANSWERS.md"]
fn test_origin_rr_c_computational_origin() {
    unimplemented_end_to_end("test_origin_rr_c_computational_origin", "c/computational_origin");
}

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/pointer_deref_chain/ANSWERS.md"]
fn test_origin_rr_c_pointer_deref_chain() {
    unimplemented_end_to_end("test_origin_rr_c_pointer_deref_chain", "c/pointer_deref_chain");
}

// ---------------------------------------------------------------------------
// Test #7 — C++ memcpy forwarder.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/cpp/memcpy_forward/ANSWERS.md"]
fn test_origin_rr_cpp_memcpy_forward() {
    unimplemented_end_to_end("test_origin_rr_cpp_memcpy_forward", "cpp/memcpy_forward");
}

// ---------------------------------------------------------------------------
// Test #8 + #9 — Rust canonical + clone forwarder.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/rust/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_rust_simple_trivial_chain() {
    unimplemented_end_to_end("test_origin_rr_rust_simple_trivial_chain", "rust/simple_trivial_chain");
}

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/rust/clone_forwarder/ANSWERS.md"]
fn test_origin_rr_rust_clone_forwarder() {
    unimplemented_end_to_end("test_origin_rr_rust_clone_forwarder", "rust/clone_forwarder");
}

// ---------------------------------------------------------------------------
// Test #10 + #11 — Nim canonical + implicit result.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/nim/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_nim_simple_trivial_chain() {
    unimplemented_end_to_end("test_origin_rr_nim_simple_trivial_chain", "nim/simple_trivial_chain");
}

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/nim/implicit_result/ANSWERS.md"]
fn test_origin_rr_nim_implicit_result() {
    unimplemented_end_to_end("test_origin_rr_nim_implicit_result", "nim/implicit_result");
}

// ---------------------------------------------------------------------------
// Test #12 + #13 — Go canonical + multi-return.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/go/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_go_simple_trivial_chain() {
    unimplemented_end_to_end("test_origin_rr_go_simple_trivial_chain", "go/simple_trivial_chain");
}

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/go/multi_return_with_err/ANSWERS.md"]
fn test_origin_rr_go_multi_return_with_err() {
    unimplemented_end_to_end("test_origin_rr_go_multi_return_with_err", "go/multi_return_with_err");
}

// ---------------------------------------------------------------------------
// Test #14 — D canonical (deferred until tree-sitter-d lands).
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/d/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_d_simple_trivial_chain() {
    // On a CI runner with ldc2 installed, this test would record the
    // fixture and then assert that the chain query returns DAP error
    // 6103 (UnsupportedBackend), because the classifier doesn't yet
    // recognise the D language. When tree-sitter-d lands, the
    // assertion will switch to the canonical TrivialCopy-chain shape.
    unimplemented_end_to_end("test_origin_rr_d_simple_trivial_chain", "d/simple_trivial_chain");
}

// ---------------------------------------------------------------------------
// Test #15 — budget terminates long chain.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/simple_trivial_chain/ANSWERS.md"]
fn test_origin_rr_budget_terminates_long_chain() {
    // Reuse the C simple_trivial_chain fixture as the substrate for the
    // budget assertion — we don't need a per-language file; the test
    // sets `max_hops=1` on the request and expects truncated=true plus
    // a continuation token.
    unimplemented_end_to_end("test_origin_rr_budget_terminates_long_chain", "c/simple_trivial_chain");
}

// ---------------------------------------------------------------------------
// Test #16 — release-build elision -> OutOfBudget terminator.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "pending: end-to-end body not written; see tests/fixtures/origin/c/release_build_elided/ANSWERS.md"]
fn test_origin_rr_release_build_yields_out_of_budget() {
    // End-to-end on a CI runner: asserts terminator.kind == OutOfBudget
    // AND terminator.expression contains the "spec §6.3" documentation
    // pointer.
    unimplemented_end_to_end(
        "test_origin_rr_release_build_yields_out_of_budget",
        "c/release_build_elided",
    );
}

// ---------------------------------------------------------------------------
// Sanity tests — execute end-to-end regardless of the RR toolchain.
// They confirm the per-fixture files are committed and the fixture
// authoring conventions are honoured (main.<ext>, ANSWERS.md,
// regenerate.sh). A missing file here is a real M11 fixture-authoring
// regression, not an environment issue.
// ---------------------------------------------------------------------------

#[test]
fn test_origin_rr_fixture_files_committed() {
    // Per-language canonical fixtures. M0 shipped C / Rust / Nim / Go.
    // M11 added C++ and D.
    assert_fixture_exists("c", "simple_trivial_chain", "main.c");
    assert_fixture_exists("cpp", "simple_trivial_chain", "main.cpp");
    assert_fixture_exists("rust", "simple_trivial_chain", "main.rs");
    assert_fixture_exists("nim", "simple_trivial_chain", "main.nim");
    assert_fixture_exists("go", "simple_trivial_chain", "main.go");
    assert_fixture_exists("d", "simple_trivial_chain", "main.d");

    // M11 per-fixture additions.
    assert_fixture_exists("c", "computational_origin", "main.c");
    assert_fixture_exists("c", "pointer_deref_chain", "main.c");
    assert_fixture_exists("c", "cross_thread_copy", "main.c");
    assert_fixture_exists("c", "stack_slot_reuse", "main.c");
    assert_fixture_exists("c", "release_build_elided", "main.c");
    assert_fixture_exists("cpp", "memcpy_forward", "main.cpp");
    assert_fixture_exists("rust", "clone_forwarder", "main.rs");
    assert_fixture_exists("nim", "implicit_result", "main.nim");
    assert_fixture_exists("go", "multi_return_with_err", "main.go");
}

#[test]
fn test_origin_rr_default_max_hops_is_eight() {
    // Spec §6.3 numerics: the RR per-request `max_hops` default is 8
    // (half the M2 materialized default 16) because each RR hop costs
    // a reverse-continue. The constant is enforced at the dispatch
    // callsite (see `dap_handler::origin_chain`) — we pin it here so
    // future refactors can't silently regress it.
    use db_backend::recreator_origin::RR_DEFAULT_MAX_HOPS;
    assert_eq!(RR_DEFAULT_MAX_HOPS, 8);
}

#[test]
fn test_origin_rr_per_hop_wall_clock_cap_is_one_and_a_half_seconds() {
    // Spec §6.3 — per-hop wall-clock cap so the loop can't hang on a
    // sparse-write address. We pin the value here so a regression
    // can't silently push the cap to 30s and degrade UX.
    use db_backend::recreator_origin::RR_PER_HOP_WALL_CLOCK_MS;
    assert_eq!(RR_PER_HOP_WALL_CLOCK_MS, 1_500);
}

/// The tests that record and replay under rr. See the module header for
/// why they are Linux-only and how a lane without an rr backend excludes
/// them.
#[cfg(target_os = "linux")]
mod rr {
    use super::*;

    use std::process::Command;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    use db_backend::dap::DapMessage;
    use db_backend::expr_loader::ExprLoader;
    use db_backend::query::ReplayQuery;
    use db_backend::recreator_session::{RecreatorArgs, RecreatorReplaySession};
    use db_backend::replay::ReplaySession;
    use db_backend::task::{
        Action, CoreTrace, CtOriginChainArguments, DEFAULT_ORIGIN_MAX_HOPS, Location, OriginBudget, OriginChain,
        OriginKind, TerminatorKind,
    };
    use origin_classifier::PatternSet;
    use serde::Deserialize;

    /// The rr replay backend this test records and replays with: `rr` on
    /// PATH and the `ct-native-replay` worker. Returns the worker's path.
    ///
    /// There is no skip path. A lane that has no rr backend declares
    /// `CODETRACER_RR_BACKEND_PRESENT=0` and must exclude these tests; if one
    /// runs there anyway, that is a lane misconfiguration and it fails here
    /// by name. Anywhere else a missing piece is a missing prerequisite and
    /// fails with its remedy.
    fn rr_backend(test_label: &str) -> PathBuf {
        if std::env::var("CODETRACER_RR_BACKEND_PRESENT").is_ok_and(|v| v.trim() == "0") {
            panic!(
                "{test_label}: this environment declares no rr backend \
                 (CODETRACER_RR_BACKEND_PRESENT=0), so this rr test cannot run here. A lane that \
                 sets the flag must exclude the `rr::` tests of origin_rr_dap_test, as \
                 `just test-rust` does; they run in cross-repo-tests.yml's rr-backend-tests job."
            );
        }
        assert!(
            test_harness::is_rr_available(),
            "{test_label}: MISSING PREREQUISITE: `rr` is not on PATH. Run inside the codetracer \
             dev shell, which provides it."
        );
        test_harness::find_ct_native_replay().unwrap_or_else(|| {
            panic!(
                "{test_label}: MISSING PREREQUISITE: ct-native-replay was not found (PATH, \
                 CT_NATIVE_REPLAY_PATH, or the codetracer-native-backend sibling). Build it with \
                 `just ensure-ct-native-replay`, or point CT_NATIVE_REPLAY_PATH at a build."
            )
        })
    }

    /// A compiler the fixture's `regenerate.sh` builds with. Missing fails
    /// the test, like every other prerequisite of these tests.
    fn require_tool(tool: &str, version_flag: &str, test_label: &str) {
        let works = Command::new(tool)
            .arg(version_flag)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        assert!(
            works,
            "{test_label}: MISSING PREREQUISITE: `{tool}` is not on PATH; the fixture is built with it. \
             Run inside the codetracer dev shell."
        );
    }

    fn fixture_line_containing(language_subdir: &str, scenario: &str, file_name: &str, needle: &str) -> u32 {
        let src = fixture_source(language_subdir, scenario, file_name);
        let contents = std::fs::read_to_string(&src)
            .unwrap_or_else(|e| panic!("failed to read fixture source {}: {e}", src.display()));
        contents
            .lines()
            .position(|line| line.contains(needle))
            .map(|index| index as u32 + 1)
            .unwrap_or_else(|| panic!("fixture {} does not contain `{needle}`", src.display()))
    }

    fn record_rr_fixture_with_regenerate(
        language_subdir: &str,
        scenario: &str,
        file_name: &str,
        ct_native_replay: &std::path::Path,
    ) -> test_harness::TestRecording {
        let source_path = assert_fixture_exists(language_subdir, scenario, file_name);
        assert!(
            test_harness::is_rr_available(),
            "rr binary not on PATH; RR origin DAP tests must run in the dev shell/CI image that provides rr"
        );
        assert!(
            ct_native_replay.exists(),
            "ct-native-replay path does not exist: {}",
            ct_native_replay.display()
        );

        // Two tests record the same fixture (`c/cross_thread_copy`), and tests
        // in one binary run concurrently in one process. Naming the directory
        // after the fixture and the pid alone sent both recordings to the
        // same place, where rr refuses to start ("Trace directory ...
        // already exists"). The per-process call sequence separates them.
        static CALL_SEQUENCE: AtomicUsize = AtomicUsize::new(0);
        let temp_dir = std::env::temp_dir().join(format!(
            "origin_rr_dap_{}_{}_{}_{}",
            language_subdir,
            scenario,
            std::process::id(),
            CALL_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        if temp_dir.exists() {
            std::fs::remove_dir_all(&temp_dir)
                .unwrap_or_else(|e| panic!("failed to clear temp dir {}: {e}", temp_dir.display()));
        }
        std::fs::create_dir_all(&temp_dir)
            .unwrap_or_else(|e| panic!("failed to create temp dir {}: {e}", temp_dir.display()));

        let trace_dir = temp_dir.join("trace");
        let build_dir = temp_dir.join("build");
        let regen = regen_script(language_subdir, scenario);
        let output = Command::new("bash")
            .arg(&regen)
            .env("CT_NATIVE_REPLAY", ct_native_replay)
            .env("OUT_DIR", &trace_dir)
            .env("BUILD_DIR", &build_dir)
            .output()
            .unwrap_or_else(|e| panic!("failed to run {}: {e}", regen.display()));
        assert!(
            output.status.success(),
            "regenerate failed for {language_subdir}/{scenario}\nstatus={}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            trace_dir.exists(),
            "regenerate did not create trace dir {}",
            trace_dir.display()
        );

        test_harness::TestRecording {
            trace_dir,
            source_path,
            binary_path: build_dir.join("main"),
            temp_dir,
            language: test_harness::Language::C,
            version_label: "rr-regenerate".to_string(),
        }
    }

    fn send_rr_origin_chain_request(
        client: &mut test_harness::DapStdioTestClient,
        variable_name: &str,
        step_id: i64,
        max_hops: u32,
    ) -> OriginChain {
        let args = CtOriginChainArguments {
            variable_name: variable_name.to_string(),
            variable_path: Vec::new(),
            frame_id: -1,
            step_id,
            thread_id: 0,
            max_hops,
            lazy: false,
            continuation_token: None,
            session_id: String::new(),
            classify_source: true,
        };
        let req = client.dap_client_mut().request(
            "ct/originChain",
            serde_json::to_value(args).expect("origin args serialize"),
        );
        client.send_message(&req).expect("send ct/originChain");
        let response = client
            .read_until_response_msg("ct/originChain", Duration::from_secs(60))
            .expect("read ct/originChain response");
        match response {
            DapMessage::Response(response) => {
                assert!(
                    response.success,
                    "ct/originChain failed: message={:?} body={}",
                    response.message, response.body
                );
                serde_json::from_value(response.body).unwrap_or_else(|e| panic!("failed to decode OriginChain: {e}"))
            }
            other => panic!("expected ct/originChain response, got {other:?}"),
        }
    }

    #[derive(Debug, Deserialize)]
    struct ProtocolEvaluateAddress {
        address: u64,
        size: usize,
    }

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ProtocolReverseContinue {
        reason: String,
        #[allow(dead_code)]
        watchpoint_id: Option<i64>,
    }

    /// Confirm the regenerate.sh script produces a non-empty trace OR
    /// emits its precise SKIPPED sentinel. We never run the script end-to-end
    /// inside the test (it spawns the recorder + RR) — instead we rely on
    /// the SKIP probes above and just sanity-check the script file is
    /// well-formed.
    fn regen_script(language_subdir: &str, scenario: &str) -> PathBuf {
        fixture_source(language_subdir, scenario, "regenerate.sh")
    }

    #[test]
    fn test_origin_rr_cross_thread_copy_tagged() {
        let ct_native_replay = rr_backend("cross_thread_copy_tagged");
        require_tool("gcc", "--version", "cross_thread_copy_tagged");
        let recording = record_rr_fixture_with_regenerate("c", "cross_thread_copy", "main.c", &ct_native_replay);
        let breakpoint_line = fixture_line_containing("c", "cross_thread_copy", "main.c", "printf(\"%d\\n\", local)");

        let mut client = test_harness::DapStdioTestClient::start().expect("DAP stdio client should start");
        client
            .initialize_and_launch_rr(&recording, &ct_native_replay)
            .expect("RR DAP launch should succeed");
        client
            .set_breakpoint(&recording.source_path, breakpoint_line)
            .expect("set breakpoint at cross_thread_copy printf");
        let location = client
            .continue_to_breakpoint()
            .expect("continue to cross_thread_copy printf breakpoint");
        assert_eq!(
            location.line, breakpoint_line as i64,
            "continue stopped at the wrong line before origin query: {location:?}"
        );
        assert!(
            location.rr_ticks.0 > 0,
            "breakpoint location must carry rr ticks for an RR origin query: {location:?}"
        );

        let chain = send_rr_origin_chain_request(&mut client, "local", location.rr_ticks.0, DEFAULT_ORIGIN_MAX_HOPS);
        assert!(
            !chain.hops.is_empty(),
            "cross_thread_copy origin chain returned no hops: terminator={:?} expression={:?}",
            chain.terminator.kind,
            chain.terminator.expression
        );
        assert_ne!(
            chain.terminator.kind,
            TerminatorKind::RecordingStart,
            "cross_thread_copy origin chain hit recording start without finding the write: {:?}",
            chain.hops
        );
        assert_eq!(
            chain.terminator.kind,
            TerminatorKind::ReadFromExternal,
            "cross_thread_copy should terminate at the writer thread boundary: {chain:?}"
        );
        let cross_thread_hop = chain
            .hops
            .iter()
            .find(|hop| hop.kind == OriginKind::CrossThreadCopy)
            .unwrap_or_else(|| panic!("expected a CrossThreadCopy hop, got chain: {chain:?}"));
        assert!(
            (cross_thread_hop.confidence - 0.6).abs() < f32::EPSILON,
            "CrossThreadCopy confidence must be exactly 0.6 per the RR guard: hop={cross_thread_hop:?}"
        );
    }

    #[test]
    fn test_origin_rr_cross_thread_copy_worker_protocol_hits_previous_write() {
        let ct_native_replay = rr_backend("cross_thread_copy_worker_protocol");
        require_tool("gcc", "--version", "cross_thread_copy_worker_protocol");
        let recording = record_rr_fixture_with_regenerate("c", "cross_thread_copy", "main.c", &ct_native_replay);
        let breakpoint_line = fixture_line_containing("c", "cross_thread_copy", "main.c", "printf(\"%d\\n\", local)");
        let rr_trace_folder = if recording.trace_dir.join("rr").is_dir() {
            recording.trace_dir.join("rr")
        } else {
            recording.trace_dir.clone()
        };

        let mut session = RecreatorReplaySession::new(
            "origin-protocol",
            0,
            RecreatorArgs {
                worker_exe: ct_native_replay.clone(),
                rr_trace_folder,
                name: "origin-protocol".to_string(),
                ..RecreatorArgs::default()
            },
        );
        session.run_to_entry().expect("worker protocol probe: run_to_entry");
        session
            .add_breakpoint(
                &recording.source_path.display().to_string(),
                breakpoint_line as i64,
                None,
                None,
            )
            .expect("worker protocol probe: add breakpoint");

        let mut query_location = None;
        for attempt in 1..=16 {
            let hit_breakpoint = session
                .step(Action::Continue, true)
                .unwrap_or_else(|e| panic!("worker protocol probe: continue attempt {attempt}: {e}"));
            let raw_location = session
                .stable
                .dispatch_replay_query(ReplayQuery::LoadLocation)
                .expect("worker protocol probe: LoadLocation while reaching breakpoint");
            let location: Location =
                serde_json::from_str(&raw_location).expect("worker protocol probe: parse LoadLocation");
            if location.line == breakpoint_line as i64 {
                query_location = Some(location);
                break;
            }
            assert!(
                hit_breakpoint,
                "worker protocol probe stopped before printf without a breakpoint: {location:?}"
            );
        }
        let query_location = query_location.expect("worker protocol probe should reach printf breakpoint");
        assert!(
            query_location.rr_ticks.0 > 0,
            "worker protocol probe breakpoint location must carry rr ticks: {query_location:?}"
        );

        let load_location_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::LoadLocation)
            .expect("worker protocol probe: LoadLocation at query");
        let load_location: Location =
            serde_json::from_str(&load_location_raw).expect("worker protocol probe: parse LoadLocation at query");
        assert_eq!(
            load_location.line, breakpoint_line as i64,
            "worker protocol probe LoadLocation must remain at printf"
        );

        let eval_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::EvaluateWithAddress {
                expression: "local".to_string(),
            })
            .expect("worker protocol probe: EvaluateWithAddress(local)");
        let local: ProtocolEvaluateAddress =
            serde_json::from_str(&eval_raw).expect("worker protocol probe: parse EvaluateWithAddress");
        assert!(
            local.address > 0,
            "local must resolve to a watchable address: {local:?}"
        );
        assert!(local.size > 0, "local must resolve to a non-zero size: {local:?}");

        let current_thread_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::CurrentThread)
            .expect("worker protocol probe: CurrentThread");
        let current_thread = serde_json::from_str::<serde_json::Value>(&current_thread_raw)
            .ok()
            .and_then(|value| value.get("tid").and_then(|tid| tid.as_u64()))
            .or_else(|| current_thread_raw.trim().parse::<u64>().ok())
            .expect("worker protocol probe: parse CurrentThread");
        assert!(current_thread > 0, "CurrentThread must return a real thread id");

        let wp_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::AddWatchpoint {
                address: local.address,
                size: local.size,
                is_write: true,
            })
            .expect("worker protocol probe: AddWatchpoint");
        let watchpoint_id: i64 = serde_json::from_str(&wp_raw)
            .or_else(|_| wp_raw.trim().parse::<i64>())
            .expect("worker protocol probe: parse AddWatchpoint");
        assert!(watchpoint_id > 0, "AddWatchpoint must return a real id");

        let reverse_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::ReverseContinue)
            .expect("worker protocol probe: ReverseContinue");
        let reverse: ProtocolReverseContinue =
            serde_json::from_str(&reverse_raw).expect("worker protocol probe: parse ReverseContinue");
        assert_ne!(
            reverse.reason, "recording-start",
            "worker protocol probe reproduced recording-start for local @ 0x{:x} ({}B) from tick {}",
            local.address, local.size, query_location.rr_ticks.0
        );
        assert_eq!(
            reverse.reason, "watchpoint",
            "worker protocol probe expected watchpoint stop, got raw={reverse_raw}"
        );
        drop(session);

        let mut origin_session = RecreatorReplaySession::new(
            "origin-direct",
            0,
            RecreatorArgs {
                worker_exe: ct_native_replay,
                rr_trace_folder: if recording.trace_dir.join("rr").is_dir() {
                    recording.trace_dir.join("rr")
                } else {
                    recording.trace_dir.clone()
                },
                name: "origin-direct".to_string(),
                ..RecreatorArgs::default()
            },
        );
        origin_session
            .run_to_entry()
            .expect("direct origin probe: run_to_entry");
        origin_session
            .add_breakpoint(
                &recording.source_path.display().to_string(),
                breakpoint_line as i64,
                None,
                None,
            )
            .expect("direct origin probe: add breakpoint");
        let mut origin_query_location = None;
        for attempt in 1..=16 {
            let hit_breakpoint = origin_session
                .step(Action::Continue, true)
                .unwrap_or_else(|e| panic!("direct origin probe: continue attempt {attempt}: {e}"));
            let raw_location = origin_session
                .stable
                .dispatch_replay_query(ReplayQuery::LoadLocation)
                .expect("direct origin probe: LoadLocation while reaching breakpoint");
            let location: Location =
                serde_json::from_str(&raw_location).expect("direct origin probe: parse LoadLocation");
            if location.line == breakpoint_line as i64 {
                origin_query_location = Some(location);
                break;
            }
            assert!(
                hit_breakpoint,
                "direct origin probe stopped before printf without a breakpoint: {location:?}"
            );
        }
        let origin_query_location = origin_query_location.expect("direct origin probe should reach printf breakpoint");
        let mut expr_loader = ExprLoader::new(CoreTrace::default());
        let patterns = PatternSet::built_in();
        let args = CtOriginChainArguments {
            variable_name: "local".to_string(),
            variable_path: Vec::new(),
            frame_id: -1,
            step_id: origin_query_location.rr_ticks.0,
            thread_id: 0,
            max_hops: DEFAULT_ORIGIN_MAX_HOPS,
            lazy: false,
            continuation_token: None,
            session_id: String::new(),
            classify_source: true,
        };
        let budget = OriginBudget {
            max_hops: DEFAULT_ORIGIN_MAX_HOPS,
            wall_clock_ms: db_backend::task::DEFAULT_ORIGIN_WALL_CLOCK_MS,
            max_steps_scanned: db_backend::task::DEFAULT_ORIGIN_MAX_STEPS_SCANNED,
        };
        let chain = db_backend::recreator_origin::run_rr_origin_chain(
            &mut origin_session,
            &args,
            &budget,
            &mut expr_loader,
            &patterns,
            None,
        )
        .expect("direct origin probe: run_rr_origin_chain");
        assert!(
            !chain.hops.is_empty(),
            "direct origin probe returned no hops: terminator={:?} expression={:?}",
            chain.terminator.kind,
            chain.terminator.expression
        );
        assert_ne!(
            chain.terminator.kind,
            TerminatorKind::RecordingStart,
            "direct origin probe hit recording start without finding the write: {chain:?}"
        );
        assert_eq!(
            chain.terminator.kind,
            TerminatorKind::ReadFromExternal,
            "direct origin probe should terminate at the writer thread boundary: {chain:?}"
        );
    }

    #[test]
    fn test_origin_rr_rust_simple_trivial_chain_evaluate_c_address() {
        let ct_native_replay = rr_backend("rust_simple_trivial_chain_evaluate_c");
        require_tool("rustc", "--version", "rust_simple_trivial_chain_evaluate_c");

        let recording = record_rr_fixture_with_regenerate("rust", "simple_trivial_chain", "main.rs", &ct_native_replay);
        let breakpoint_line = fixture_line_containing("rust", "simple_trivial_chain", "main.rs", "println!");
        let rr_trace_folder = if recording.trace_dir.join("rr").is_dir() {
            recording.trace_dir.join("rr")
        } else {
            recording.trace_dir.clone()
        };

        let mut session = RecreatorReplaySession::new(
            "rust-simple-trivial-evaluate-c",
            0,
            RecreatorArgs {
                worker_exe: ct_native_replay,
                rr_trace_folder,
                name: "rust-simple-trivial-evaluate-c".to_string(),
                ..RecreatorArgs::default()
            },
        );
        session
            .run_to_entry()
            .expect("rust simple_trivial_chain primitive: run_to_entry");
        session
            .add_breakpoint(
                &recording.source_path.display().to_string(),
                breakpoint_line as i64,
                None,
                None,
            )
            .expect("rust simple_trivial_chain primitive: add breakpoint");

        let mut query_location = None;
        for attempt in 1..=16 {
            let hit_breakpoint = session
                .step(Action::Continue, true)
                .unwrap_or_else(|e| panic!("rust simple_trivial_chain primitive: continue attempt {attempt}: {e}"));
            let raw_location = session
                .stable
                .dispatch_replay_query(ReplayQuery::LoadLocation)
                .expect("rust simple_trivial_chain primitive: LoadLocation while reaching breakpoint");
            let location: Location =
                serde_json::from_str(&raw_location).expect("rust simple_trivial_chain primitive: parse LoadLocation");
            if location.line == breakpoint_line as i64 {
                query_location = Some(location);
                break;
            }
            assert!(
                hit_breakpoint,
                "rust simple_trivial_chain primitive stopped before println without a breakpoint: {location:?}"
            );
        }
        let query_location = query_location.expect("rust simple_trivial_chain primitive should reach println");
        assert!(
            query_location.rr_ticks.0 > 0,
            "rust simple_trivial_chain primitive location must carry rr ticks: {query_location:?}"
        );

        let eval_raw = session
            .stable
            .dispatch_replay_query(ReplayQuery::EvaluateWithAddress {
                expression: "c".to_string(),
            })
            .expect("rust simple_trivial_chain primitive: EvaluateWithAddress(c)");
        let c: ProtocolEvaluateAddress =
            serde_json::from_str(&eval_raw).expect("rust simple_trivial_chain primitive: parse EvaluateWithAddress(c)");
        assert!(
            c.address > 0x1000,
            "Rust fixture variable `c` must resolve to a watchable storage address at tick {}: {c:?}",
            query_location.rr_ticks.0
        );
        assert_eq!(c.size, 4, "Rust fixture variable `c: i32` must be 4 bytes: {c:?}");
    }
}
