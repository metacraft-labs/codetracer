//! M0/2 — a GUARD, in the shape of `wall_clock_sweep_test.rs`: the seekable
//! call / step / value / event sources must stay compiled for
//! `wasm32-unknown-unknown`, and must not be replaced by stubs again.
//!
//! ## Why a source-scanning test rather than a behavioural one
//!
//! The defect this guards against is invisible to every behavioural test that
//! can run on the host. Before M0, `src/ctfs_trace_reader/mod.rs` selected
//! `call_stream_source_wasm.rs` and `step_value_stream_source_wasm.rs` under
//! `cfg(target_arch = "wasm32")`, and those stubs returned `Ok(None)` from
//! every `open_from_ctfs`, `None` from every read, and `0` from every counter.
//! A native `cargo test` compiles the REAL modules, so it passes either way —
//! the stubs are unreachable from it. The regression can only be caught by
//! looking at what the wasm build would select, which is what this does.
//!
//! ## What it asserts, and how it fails
//!
//! 1. `mod.rs` declares each seekable source module WITHOUT a
//!    `cfg(not(target_arch = "wasm32"))` gate and without a `#[path = "…_wasm.rs"]`
//!    redirect.
//! 2. No stub file for those modules exists on disk.
//! 3. The one legitimately host-specific construct — `std::thread` in the
//!    parallel whole-table build — stays behind a `cfg(not(target_arch =
//!    "wasm32"))` in `step_value_stream_source.rs`, since wasm32 has no threads
//!    and an ungated `std::thread::scope` there would fail the wasm build.
//!
//! Re-introducing a stub, or re-gating a module, fails this by name.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

fn reader_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/ctfs_trace_reader")
}

fn mod_rs() -> String {
    let path = reader_dir().join("mod.rs");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

/// The declaration line for `pub mod <name>;` in `mod.rs`, and the line
/// immediately before it (where a `cfg` / `#[path]` attribute would sit).
fn declaration_context(source: &str, module: &str) -> (usize, Vec<String>) {
    let needle = format!("pub mod {module};");
    let lines: Vec<&str> = source.lines().collect();
    let mut occurrences = 0usize;
    let mut context = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        if line.trim() == needle {
            occurrences += 1;
            let start = i.saturating_sub(2);
            for line in lines.iter().take(i).skip(start) {
                context.push((*line).to_string());
            }
        }
    }
    (occurrences, context)
}

/// The four seekable sources are declared exactly once each, unconditionally.
///
/// Exactly once matters: the stubbed arrangement declared each module TWICE —
/// once under `cfg(not(wasm32))` and once under `cfg(wasm32)` with a `#[path]`
/// redirect — so a count of one is itself the proof that no wasm arm exists.
#[test]
fn seekable_sources_are_declared_once_and_unconditionally() {
    let source = mod_rs();
    for module in [
        "call_stream_source",
        "step_value_stream_source",
        "event_stream_source",
        "interning_tables",
    ] {
        let (occurrences, context) = declaration_context(&source, module);
        assert_eq!(
            occurrences, 1,
            "`pub mod {module};` appears {occurrences} times in ctfs_trace_reader/mod.rs; \
             more than one declaration means a per-target arm is back, and the wasm32 arm \
             was a stub that could not fail"
        );
        for line in &context {
            assert!(
                !line.contains("target_arch = \"wasm32\""),
                "`{module}` is declared under a target gate ({line:?}); it must build for wasm32 too"
            );
            assert!(
                !line.contains("#[path"),
                "`{module}` is declared with a `#[path]` redirect ({line:?}); that is how the \
                 stub was substituted before M0"
            );
        }
    }
}

/// The stub files themselves are gone, so nothing can quietly re-point at them.
#[test]
fn no_stub_files_remain_for_the_seekable_sources() {
    for stub in ["call_stream_source_wasm.rs", "step_value_stream_source_wasm.rs"] {
        let path = reader_dir().join(stub);
        assert!(
            !path.exists(),
            "{} still exists. It is the stub whose `open_from_ctfs` returned Ok(None) and whose \
             `call()` returned None on wasm32 — the reason browser replay could never serve a \
             seekable container. Delete it rather than keeping it as a fallback.",
            path.display()
        );
    }
}

/// Follow-mode streams are a DELIBERATE exception: they tail a growing file on
/// a local filesystem, which is not a browser concern, and their stub returns a
/// named error rather than a silent empty result. This asserts that exception
/// stays explicit, so nobody reads the rule above as "no stubs anywhere".
#[test]
fn the_follow_stream_stub_is_the_one_intended_exception() {
    let stub = reader_dir().join("follow_stream_source_wasm.rs");
    assert!(
        stub.exists(),
        "follow_stream_source_wasm.rs is expected to exist; if follow mode became \
         browser-reachable, update this test rather than deleting the assertion"
    );
    let text = std::fs::read_to_string(&stub).expect("read follow stub");
    assert!(
        text.contains("not supported on wasm32"),
        "the follow stub must REFUSE by name on wasm32, not return an empty success — a stub \
         that silently succeeds is exactly the failure mode this suite exists for"
    );
}

/// The parallel whole-table build stays gated. `wasm32-unknown-unknown` has no
/// threads, so an ungated `std::thread::scope` would break the wasm build — and
/// an ungated `available_parallelism` would silently pick the sequential path
/// anyway. Both must be explicit.
#[test]
fn the_threaded_build_path_stays_gated_for_wasm32() {
    let path = reader_dir().join("step_value_stream_source.rs");
    let text = std::fs::read_to_string(&path).expect("read step_value_stream_source.rs");

    for (marker, what) in [
        ("fn build_partials_parallel", "the parallel shard builder"),
        ("fn default_build_threads", "the default thread count"),
    ] {
        let index = text
            .find(marker)
            .unwrap_or_else(|| panic!("{what} ({marker}) not found in {}", path.display()));
        let preceding = &text[index.saturating_sub(400)..index];
        assert!(
            preceding.contains("cfg(not(target_arch = \"wasm32\"))") || preceding.contains("cfg(target_arch = \"wasm32\")"),
            "{what} is not target-gated; wasm32 has no threads, so it must be"
        );
    }

    assert!(
        text.contains("#[cfg(target_arch = \"wasm32\")]"),
        "step_value_stream_source.rs must carry an explicit wasm32 arm for the build strategy, \
         so the browser path's sequential build is a decision rather than an accident"
    );
}
