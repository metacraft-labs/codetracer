//! A failing test in this crate must PRINT the assertion that failed.
//!
//! ## Why this guard exists
//!
//! For a while it did not. Every failing test in `src/db-backend` died with
//!
//! ```text
//! fatal runtime error: failed to initiate panic, error 5, aborting
//! (signal: 6, SIGABRT)
//! ```
//!
//! and printed NEITHER the assertion message NOR the values it compared. A
//! red told you that something failed and nothing else — which defeats both
//! of the things this repo's testing method rests on: mutation testing (break
//! it, watch the check go red, restore) and assertions that report the value
//! they measured.
//!
//! The cause was the linker, not any test and not any dependency. rustc's
//! default linker driver on Darwin is `cc`; in this repo's Nix dev shell `cc`
//! is nixpkgs' gcc-wrapper (GCC 14.3.0), and GCC's Darwin driver passes
//! `-no_compact_unwind`. The resulting Mach-O carries no
//! `__TEXT,__unwind_info`, Apple's libunwind cannot find unwind info without
//! that compact index, and `_Unwind_RaiseException` returns
//! `_URC_END_OF_STACK` (5). Rust's runtime has nowhere to go from there and
//! aborts — before libtest has printed a thing.
//!
//! The remedy is two lines in `src/.cargo/config.toml`
//! (`[target.aarch64-apple-darwin] linker = "clang"`). This file is what
//! keeps them there: revert them and the test below goes red.
//!
//! ## How it works
//!
//! `panic_message_reaches_the_test_output` re-invokes THIS test binary as a
//! child process, asking it to run the `#[ignore]`d helper that fails on
//! purpose, and then asserts on what the child actually wrote. Running it in
//! a child is the whole point: a test cannot observe its own abort.
//!
//! ## What this looks like when it goes red
//!
//! Not like a normal assertion failure. Verified by removing the linker
//! entries and re-running: the child aborts, this test's own assertion about
//! that then fails — and *that* panic cannot unwind either, so the whole test
//! binary dies the same way:
//!
//! ```text
//! running 2 tests
//! test deliberately_failing_helper ... ignored, fails by design
//! fatal runtime error: failed to initiate panic, error 5, aborting
//! error: test failed, to rerun pass `--test panic_message_visibility`
//! ```
//!
//! That is unavoidable — the guard lives inside the binary it is checking —
//! and it is not a defect in the guard. The abort IS the finding: if you see
//! it, the linker configuration is gone, and no red anywhere else in this
//! crate can be trusted until it is back.

use std::process::Command;

/// Carried by the helper's assertion message so the guard can look for
/// something that could only have come from the assertion itself.
const MARKER: &str = "PANIC-VISIBILITY-PROBE";

/// The exit code libtest uses when a test fails but the process survives to
/// report it. A runtime abort produces no exit code at all (the process dies
/// by SIGABRT), which is exactly the distinction this guard is drawing.
const LIBTEST_FAILURE_EXIT_CODE: i32 = 101;

/// Fails on purpose. Driven as a child process by
/// `panic_message_reaches_the_test_output`; `#[ignore]` keeps it out of
/// ordinary `cargo test` runs.
#[test]
#[ignore = "fails by design; driven as a child process by panic_message_reaches_the_test_output"]
fn deliberately_failing_helper() {
    let measured = 41_u32;
    let expected = 42_u32;
    assert_eq!(measured, expected, "{MARKER} measured={measured} expected={expected}");
}

#[test]
fn panic_message_reaches_the_test_output() {
    let exe = std::env::current_exe().expect("current_exe must resolve for the running test binary");

    let output = Command::new(&exe)
        .args([
            "--exact",
            "deliberately_failing_helper",
            "--ignored",
            "--test-threads=1",
        ])
        .output()
        .unwrap_or_else(|e| panic!("could not re-invoke the test binary at {}: {e}", exe.display()));

    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let combined = format!("{stdout}{stderr}");

    // 1. The child must have died as a REPORTED test failure, not as an
    //    abort. `code()` is `None` when the process was killed by a signal,
    //    which is what the unwinder failure looks like from out here.
    assert_eq!(
        output.status.code(),
        Some(LIBTEST_FAILURE_EXIT_CODE),
        "the deliberately-failing child must exit {LIBTEST_FAILURE_EXIT_CODE} (a reported test \
         failure); got status {:?}.\n\
         `code() == None` means it was killed by a signal — i.e. the runtime aborted instead of \
         unwinding, and no assertion was printed.\n\
         Child output was:\n{combined}",
        output.status,
    );

    // 2. The runtime must not have failed to start the panic at all.
    assert!(
        !combined.contains("failed to initiate panic"),
        "the child hit `fatal runtime error: failed to initiate panic` — Rust's unwinder could \
         not walk the stack, which on macOS means the binary was linked without \
         `__TEXT,__unwind_info`. Check the `[target.*-apple-darwin] linker` entries in \
         src/.cargo/config.toml.\n\
         Child output was:\n{combined}",
    );

    // 3. The assertion's own message must have reached the output.
    assert!(
        combined.contains(MARKER),
        "the failing assertion's message ({MARKER:?}) never reached the child's output — a red in \
         this crate would carry no information about what failed.\n\
         Child output was:\n{combined}",
    );

    // 4. And so must the VALUES it compared. A message without its values is
    //    still a verdict rather than a measurement.
    assert!(
        combined.contains("measured=41 expected=42"),
        "the assertion message reached the output but its values did not; expected to find \
         \"measured=41 expected=42\".\n\
         Child output was:\n{combined}",
    );

    // 5. libtest's own rendering of `assert_eq!` must survive too, so
    //    left/right diffs stay readable.
    assert!(
        combined.contains("left: 41") && combined.contains("right: 42"),
        "libtest's `assert_eq!` left/right rendering did not reach the output; expected both \
         \"left: 41\" and \"right: 42\".\n\
         Child output was:\n{combined}",
    );
}
