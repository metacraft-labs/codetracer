//! GDScript coroutine / `await` integration test — GDScript-Recorder.md
//! milestone **GF10** (`verify_gdscript_records_await_coroutine_continuation_link`
//! and `verify_gdscript_await_signal_suspend_resume_balanced`).
//!
//! Proves that a GDScript recording produced by the **patched Godot engine**
//! (`metacraft-labs/codetracer-engine-godot`, branch
//! `codetracer/gdscript-recorder`) opens in the REAL `MaterializedReplaySession`
//! and yields async `ContinuationLink`s conforming to the CodeTracer
//! async-continuation model (HTTP-Request-Panel.md §3.2 /
//! Async-Continuation-Algorithms.md §5) — it does not invent a parallel scheme.
//!
//! # No mocks
//!
//! Per workspace policy every mock must be justified in the test header: **this
//! test uses none.** It opens a committed, real `.ct` container
//! (`tests/fixtures/gdscript/gf_coroutine/gdscript_trace.ct`) recorded by the
//! patched engine over the real reference program
//! `test-programs/gdscript/gf_coroutine.gd`, through the production
//! `CTFSTraceReader::open` + `MaterializedReplaySession::continuation_links`
//! (which runs the built-in `gdscript-coroutine` `ContinuationPattern` over the
//! container's real events stream). The reader, the pattern set and the link
//! former are all the production implementations.
//!
//! # No silent skip
//!
//! The fixture `.ct` and its source are committed, so the test always runs. If
//! either is missing it FAILS loudly — a missing fixture is a repository
//! integrity error, not an environment gap.
//!
//! # The recorded program (committed source, line numbers quoted)
//!
//! ```gdscript
//! 43 func work() -> int:
//! 44     var base := 10
//! 45     var payload: int = await go   # SUSPEND on a SIGNAL
//! 46     var kept := base              # RESUME line — surviving base == 10
//! 47     var result := kept + payload  # 42
//! 48     return result
//! 50 func _initialize() -> void:
//! 51     var r: int = await work()     # SUSPEND on a COROUTINE call
//! 52     var check := r                # RESUME line — r == 42 after the join
//! ```
//!
//! Two `await`s run, producing two links:
//!   * **A (signal await, inside `work`)** — `await go`, the crisp case:
//!     registration at the `await go` line, continuation at the first resumed
//!     line (`kept`), the coroutine's pre-await local `base` survives (== 10).
//!   * **B (coroutine-call await, inside `_initialize`)** — `await work()`:
//!     continuation at `check` with `r == 42` after the join.
//!
//! Both carry `link_type == Await` and are paired by the `CallState` pointer
//! (`context_id`) the recorder emits at suspend and resume.

use std::path::PathBuf;
use std::sync::Arc;

use codetracer_trace_types::{CallKey, StepId, ValueRecord};
use db_backend::async_continuation::{LinkType, async_links_from, async_links_to};
use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::db::MaterializedReplaySession;
use db_backend::trace_reader::TraceReader;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("gf_coroutine")
}

fn open_reader() -> Arc<dyn TraceReader> {
    let dir = fixture_dir();
    let ct = dir.join("gdscript_trace.ct");
    assert!(
        ct.is_file(),
        "GDScript coroutine fixture trace missing at {} — record it with the patched engine \
         (scripts/record-and-verify-gf10.sh in the codetracer-engine-godot fork); \
         this test must NOT silently skip",
        ct.display()
    );
    assert!(
        dir.join("gf_coroutine.gd").is_file(),
        "GDScript coroutine fixture source missing at {}/gf_coroutine.gd",
        dir.display()
    );
    Arc::new(CTFSTraceReader::open(&ct).unwrap_or_else(|e| panic!("CTFS open failed for {}: {}", ct.display(), e)))
}

/// 1-based source line recorded at `step`.
fn line_at(reader: &Arc<dyn TraceReader>, step: StepId) -> i64 {
    reader
        .step(step)
        .unwrap_or_else(|| panic!("no step at {step:?}"))
        .line
        .0
}

/// Read the integer value of local `name` recorded AT `step`.
fn local_int_at(reader: &Arc<dyn TraceReader>, step: StepId, name: &str) -> Option<i64> {
    let vars = reader.variables_at(step)?;
    for v in vars {
        if reader.variable_name(v.variable_id) == Some(name)
            && let ValueRecord::Int { i, .. } = &v.value
        {
            return Some(*i);
        }
    }
    None
}

// ---------------------------------------------------------------------------
// (1) COROUTINE-CALL await → ContinuationLink
// ---------------------------------------------------------------------------

#[test]
fn verify_gdscript_records_await_coroutine_continuation_link() {
    let reader = open_reader();
    let session = MaterializedReplaySession::new(Arc::clone(&reader));
    let links = session.continuation_links();

    // Dump every link with its source lines (diagnostic, always printed).
    for l in &links {
        eprintln!(
            "[GF10 link {}] type={:?} ctx=0x{:x} thread={} registration=step{}(line {}) -> continuation=step{}(line {})",
            l.id,
            l.link_type,
            l.context_id,
            l.async_thread_id,
            l.registration.step_id.0,
            line_at(&reader, l.registration.step_id),
            l.continuation.step_id.0,
            line_at(&reader, l.continuation.step_id),
        );
    }

    assert_eq!(links.len(), 2, "expected exactly two await links (signal + coroutine)");

    // Every link is an `await`, and every continuation is strictly after its
    // registration (the ContinuationLink ordering invariant).
    for l in &links {
        assert_eq!(l.link_type, LinkType::Await, "GDScript await link_type");
        assert!(
            l.continuation.step_id.0 > l.registration.step_id.0,
            "continuation must follow registration: {l:?}"
        );
    }

    // The COROUTINE-CALL link (B): `_initialize` awaited `work()`, and the join
    // resumes at `var check := r` where `r == 42`. Identify it by its
    // continuation landing on the `check` line (52) with r == 42.
    let coroutine_link = links
        .iter()
        .find(|l| line_at(&reader, l.continuation.step_id) == 52)
        .expect("a link whose continuation is the `_initialize` resume line (52)");

    // On resume, `r` (and `check`) equal 42 — the coroutine's returned value
    // survives the join.
    let r_on_resume = local_int_at(&reader, coroutine_link.continuation.step_id, "r")
        .or_else(|| local_int_at(&reader, coroutine_link.continuation.step_id, "check"))
        .expect("r/check captured on the resume step");
    assert_eq!(r_on_resume, 42, "await work() joined to r == 42");

    // async_links_from(registration) resolves to the continuation, and
    // async_links_to(continuation) resolves back — the §5.2 omniscient queries.
    let from = async_links_from(&links, coroutine_link.registration.step_id);
    assert!(
        from.iter()
            .any(|r| r.continuation_step == coroutine_link.continuation.step_id),
        "async_links_from(registration) must resolve to the resume step"
    );
    assert_eq!(from[0].link_type, 0, "AsyncLinkRecord.link_type await == 0");
    let to = async_links_to(&links, coroutine_link.continuation.step_id);
    assert!(
        to.iter()
            .any(|r| r.registration_step == coroutine_link.registration.step_id),
        "async_links_to(continuation) must resolve back to the registration step"
    );

    eprintln!(
        "[GF10 coroutine link] ctx=0x{:x} registration=step{} continuation=step{} r={}",
        coroutine_link.context_id,
        coroutine_link.registration.step_id.0,
        coroutine_link.continuation.step_id.0,
        r_on_resume
    );
}

// ---------------------------------------------------------------------------
// (2) SIGNAL await → balanced suspend/resume + surviving locals
// ---------------------------------------------------------------------------

#[test]
fn verify_gdscript_await_signal_suspend_resume_balanced() {
    let reader = open_reader();
    let session = MaterializedReplaySession::new(Arc::clone(&reader));
    let links = session.continuation_links();

    // The SIGNAL-await link (A): `work` awaited the signal `go`. Its
    // registration is the `await go` line (45) and its continuation is the
    // first resumed line `var kept := base` (46).
    let signal_link = links
        .iter()
        .find(|l| line_at(&reader, l.registration.step_id) == 45)
        .expect("a link whose registration is the `await go` line (45)");

    assert_eq!(signal_link.link_type, LinkType::Await);

    // resume step_id > suspend step_id.
    assert!(
        signal_link.continuation.step_id.0 > signal_link.registration.step_id.0,
        "resume must follow suspend: {signal_link:?}"
    );
    assert_eq!(
        line_at(&reader, signal_link.continuation.step_id),
        46,
        "continuation is the first resumed line (var kept := base)"
    );

    // The pre-await local `base` SURVIVES the suspension: on resume `kept` is
    // set from `base` and equals 10.
    let kept =
        local_int_at(&reader, signal_link.continuation.step_id, "kept").expect("kept captured on the resume step");
    assert_eq!(kept, 10, "pre-await local `base` (==10) survived the suspension");

    // Call/return stays BALANCED across the yield: every call has a matching
    // return (G3 invariant is preserved by GF10 — the suspend/resume markers add
    // events, they do not add or drop call/return records). Assert balance over
    // the whole trace via the reader's call records.
    assert_balanced_calls(&reader);

    // The context_id (CallState pointer) at registration equals the one matched
    // at continuation — that is HOW the pair was formed, so re-derive it from
    // async_links_from and confirm it is the same context on both ends.
    let from = async_links_from(&links, signal_link.registration.step_id);
    assert!(
        from.iter()
            .any(|r| r.context_id == signal_link.context_id && r.continuation_step == signal_link.continuation.step_id),
        "the registration and continuation share the same CallState context_id"
    );

    eprintln!(
        "[GF10 signal link] ctx=0x{:x} suspend=step{}(line45) < resume=step{}(line46) kept={} (base survived); calls balanced",
        signal_link.context_id, signal_link.registration.step_id.0, signal_link.continuation.step_id.0, kept
    );
}

/// Assert call/return balance across the yield (GDScript-Recorder.md open
/// question #4): a coroutine that suspends records as TWO adjacent BALANCED
/// frames — one suspend-portion (which returns the coroutine state) and one
/// resume-portion. The CTFS reader only builds a `DbCall` for a call whose
/// entry/return are both present, so counting well-formed `work` / `_initialize`
/// frames proves each `call()` invocation was balanced (G3 preserved by GF10:
/// the suspend/resume markers ADD events, they do not add or drop call/return
/// records).
fn assert_balanced_calls(reader: &Arc<dyn TraceReader>) {
    let n = reader.step_count();
    let count = reader.call_count();
    assert!(count > 0, "trace has calls");

    let mut work_frames = 0usize;
    let mut init_frames = 0usize;
    for i in 0..count {
        let c = reader
            .call(CallKey(i as i64))
            .unwrap_or_else(|| panic!("call {i} resolves"));
        // Every frame is well-formed: an in-range entry step and a consistent
        // parent (an unbalanced/orphaned suspend would have failed the tree
        // build, so a resolvable DbCall IS a balanced frame).
        assert!(
            c.step_id.0 >= 0 && (c.step_id.0 as usize) <= n,
            "call {i} entry step in range: {c:?}"
        );
        assert!(c.parent_key.0 < count as i64, "call {i} parent in range");
        let name = reader.function(c.function_id).map(|f| f.name.as_str()).unwrap_or("");
        match name {
            "work" => work_frames += 1,
            "_initialize" => init_frames += 1,
            _ => {}
        }
    }
    // Each coroutine suspended exactly once, so each records as two balanced
    // frames (suspend-portion + resume-portion).
    assert_eq!(
        work_frames, 2,
        "coroutine `work` records as two balanced frames across its yield"
    );
    assert_eq!(
        init_frames, 2,
        "`_initialize` records as two balanced frames across its `await work()` yield"
    );
    eprintln!(
        "[GF10 balance] {count} calls; work frames={work_frames}, _initialize frames={init_frames} (each = suspend+resume portion, balanced)"
    );
}

// ---------------------------------------------------------------------------
// (3) NON-VACUITY — tampering the recorded pairing breaks the links
// ---------------------------------------------------------------------------

/// Prove the PASS above is not vacuous: take the REAL recorded events, tamper
/// the resume markers' `context_id` so they no longer match any suspend, and
/// confirm the former produces NO links (so the passing assertions genuinely
/// depend on the recorded suspend/resume pairing, not on the code always
/// returning something).
#[test]
fn verify_gdscript_await_tamper_breaks_pairing() {
    use db_backend::async_continuation::ContinuationPatternSet;

    let reader = open_reader();
    let patterns = ContinuationPatternSet::built_in();

    // Baseline: the untampered events form the two real links.
    let real = patterns.discover_links(reader.events());
    assert_eq!(real.len(), 2, "baseline must have the two real links");

    // Tamper: rewrite every resume marker's context to a value that matches no
    // suspend. discover_links must then pair NOTHING.
    let mut tampered: Vec<_> = reader.events().to_vec();
    for e in tampered.iter_mut() {
        if e.content.starts_with("ct-async-resume") {
            // keep the "<hex> <step>" shape, only change the context id
            let step = e.metadata.split_whitespace().nth(1).unwrap_or("0");
            e.metadata = format!("0xdeadbeef {step}");
        }
    }
    let broken = patterns.discover_links(&tampered);
    assert_eq!(
        broken.len(),
        0,
        "tampering the resume context_id must break ALL pairings (got {broken:?}) — \
         proves the real PASS depends on the recorded pairing"
    );
    eprintln!("[GF10 tamper] real links=2, links after context tamper=0 (non-vacuous)");
}

/// Guard: the fixture is present (fails clearly if the fixtures move).
#[test]
fn verify_gdscript_coroutine_fixture_is_present() {
    let dir = fixture_dir();
    assert!(
        dir.join("gdscript_trace.ct").is_file() && dir.join("gf_coroutine.gd").is_file(),
        "GDScript GF10 fixtures missing under {} — see the file header",
        dir.display()
    );
}
