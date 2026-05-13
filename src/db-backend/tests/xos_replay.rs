//! M-XOS-Fixture — cross-OS replay test fixture.
//!
//! Proves that an `EmulatorReplaySession` built from a `.ct` recorded by
//! `ct_cli record` on Linux can be reopened by the same code path that
//! the WASM/browser-replay build runs. The emulator is intentionally
//! host-platform-agnostic: it interprets the captured x86_64 register
//! file, memory regions, and `/proc/self/maps`-derived load base rather
//! than touching the live host, so the same Rust → Nim → emulator stack
//! that works on Linux is the structural identity of the macOS-host or
//! browser path. A real cross-OS run (e.g. opening a Linux `.ct` on
//! macOS) requires CI infra and is out of scope for this milestone; this
//! test pins the host-independent half of the contract on Linux.
//!
//! Fixture: `tests/fixtures/xos/xos_hello.ct` is a real recording of
//! `xos_hello.elf` (a 3-function dynamically-linked C program) with
//! `cp0.mem` slimmed to the program's PIE load segments + the [stack]
//! region. See the README in that directory for how to regenerate.

use db_backend::emulator_session::EmulatorReplaySession;
use db_backend::replay::ReplaySession;
use db_backend::task::CtLoadLocalsArguments;
use db_backend::value::ValueRecordWithType;
use std::sync::Mutex;

/// Embedded fixture bytes — pulled into the test binary at build time so
/// the test never needs to find the fixture on disk.
const XOS_FIXTURE: &[u8] = include_bytes!("fixtures/xos/xos_hello.ct");

/// Tests that hit the Nim emulator FFI must run serially across the test
/// binary — `mcrInit` resets the per-process emulator globals, so two
/// sessions constructed in parallel would race for the same memory
/// regions and registers. The in-source unit tests use a private
/// `FFI_TEST_LOCK` defined inside `mod tests`; integration tests live in
/// a separate crate so they declare their own peer lock that serialises
/// every emulator-touching test in this file.
static FFI_TEST_LOCK: Mutex<()> = Mutex::new(());

/// Acceptance test: a real Linux-recorded `.ct` loaded via
/// `EmulatorReplaySession::new_from_ctfs_bytes` must surface:
///
///   * A non-zero recorded program counter (proves `cp0.regs` was
///     decoded — the constructor seeds the emulator before returning).
///   * At least one frame in `load_callstack()`.
///   * A frame whose `name` is non-empty and whose `path` resolves to a
///     real source file (proves DWARF resolution works).
///   * `load_locals()` returns ≥ 1 variable with a non-zero `Int` value
///     (proves the recorded register file actually flowed through the
///     FFI into the emulator-side state).
///   * `add_breakpoint(path, line)` returns a `verified: true`
///     breakpoint for a DWARF-known `(path, line)` pair.
#[test]
fn xos_fixture_drives_emulator_replay_session() {
    let _guard = FFI_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    let mut session = EmulatorReplaySession::new_from_ctfs_bytes(XOS_FIXTURE.to_vec())
        .expect("EmulatorReplaySession must accept a real Linux .ct recording");

    // ── 1. cp0.regs was decoded ───────────────────────────────────────
    //
    // The recorder captured RIP at `__libc_start_main`'s wrapper call
    // into `main`, which is by construction non-zero. We query
    // `mcrGetPC` directly so the assertion is independent of the
    // `current_step_id` accounting (which only advances after `step`).
    let pc = unsafe { db_backend::emulator_ffi::mcrGetPC() };
    assert!(pc != 0, "recorded RIP must be non-zero after cp0.regs seed; got 0",);

    // ── 2. callstack has ≥ 1 frame with a valid (name, path) pair ─────
    let frames = session.load_callstack().expect("load_callstack must succeed");
    assert!(
        !frames.is_empty(),
        "callstack must contain at least one frame for a real recording",
    );
    let mut found_dwarf_frame: Option<(String, i64)> = None;
    for (i, frame) in frames.iter().enumerate() {
        let loc = &frame.content.call.location;
        assert!(
            !loc.function_name.is_empty(),
            "frame {i} must have a non-empty name; got {loc:?}",
        );
        assert!(
            !loc.path.is_empty(),
            "frame {i} must have a non-empty path; got {loc:?}",
        );
        // A DWARF-resolved frame has line > 1 (line=1 is the
        // `EmulatorReplaySession::build_location_for` fallback when
        // DWARF didn't know the PC — typically the outermost
        // `__libc_start_main` frame). The innermost frame must hit
        // the program's source.
        if loc.line > 1 && loc.path.ends_with(".c") && found_dwarf_frame.is_none() {
            found_dwarf_frame = Some((loc.path.clone(), loc.line));
        }
    }
    let (dwarf_path, dwarf_line) =
        found_dwarf_frame.expect("at least one frame must DWARF-resolve to a .c source line");

    // ── 3. ≥ 1 local with a non-zero Int value ────────────────────────
    //
    // The emulator projects the 18 x86_64 registers as locals. After
    // cp0.regs is installed, RIP / RSP / RBP / RDI / RSI / ... are all
    // non-zero — a real recording would never produce 18 zeros for all
    // of them. (We assert ≥ 1 rather than a specific count because
    // CFLAGS, gcc version, and ABI quirks may zero some of the
    // callee-saved registers at the capture point.)
    let locals = session
        .load_locals(CtLoadLocalsArguments::default())
        .expect("load_locals must succeed");
    let nonzero_int = locals
        .iter()
        .filter(|v| matches!(v.value, ValueRecordWithType::Int { i, .. } if i != 0))
        .count();
    assert!(
        nonzero_int >= 1,
        "expected ≥ 1 register-local with a non-zero value; got {nonzero_int} non-zero out of {}",
        locals.len(),
    );

    // ── 4. add_breakpoint reports verified ────────────────────────────
    //
    // We use the (path, line) pair the DWARF resolver just handed us so
    // the breakpoint is guaranteed to land on a known PC. The
    // `enabled: true` flag is what the DAP shim translates into
    // `verified: true` in the `setBreakpoints` response.
    let bp = session
        .add_breakpoint(&dwarf_path, dwarf_line)
        .expect("add_breakpoint must succeed for a DWARF-known (path, line)");
    assert!(
        bp.enabled,
        "breakpoint at {dwarf_path}:{dwarf_line} must report enabled=true; got {bp:?}",
    );
}
