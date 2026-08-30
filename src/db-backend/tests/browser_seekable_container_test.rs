//! M0 (BlockTracer "Browser Replay Gate") deliverables 1, 2 and 4 — the
//! BROWSER-REACHABLE constructor opens a NEW-FORMAT SEEKABLE container, attaches
//! its seekable streams, and navigates it WITHOUT materializing the step table.
//!
//! ## The hole this closes
//!
//! `CTFSTraceReader::from_bytes` is the only constructor a browser can reach:
//! `dap_server::setup_from_vfs` hands it the `.ct` bytes pushed into the WASM
//! in-memory VFS from JavaScript, and there is no filesystem to fall back on.
//! It used to do two things that together made browser replay a demo rather
//! than a product:
//!
//! 1. It **rejected new-format (split-stream) containers outright** — the
//!    production format every live recorder emits — leaving only legacy
//!    `events.log` bundles, which are whole-file postprocessed by construction.
//! 2. Even for the bundles it did accept, it **hard-coded every seekable stream
//!    to `None`**, so nothing was ever served on demand.
//!
//! Both are now closed, and this suite is the proof.
//!
//! ## Why the assertions are A/B rather than golden values
//!
//! The bundle is written by the Nim `MultiStreamTraceWriter` — the exact FFI
//! write path every live recorder drives — and then read TWICE: once through
//! `CTFSTraceReader::open`, the native production path backed by the Nim FFI
//! reader, and once through `CTFSTraceReader::from_bytes`, the browser path
//! backed by the new pure-Rust reader. These are two genuinely independent
//! decoders of the same bytes, so asserting they agree step-for-step is a much
//! stronger statement than any hand-written expectation would be: a decode bug
//! in either one shows up as a disagreement.
//!
//! ## No skip path
//!
//! The bundle is written at test time by the real writer. If the writer, the
//! reader, or the streams are absent or broken, these cases FAIL — none of them
//! can pass because its subject is missing. The `nim-reader` feature they need
//! is in the crate's default feature set, so `cargo test` runs them.

#![cfg(feature = "nim-reader")]
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use std::path::{Path, PathBuf};

use codetracer_trace_types::{CallKey, Line, StepId, TypeId, TypeKind, ValueRecord};

use codetracer_trace_writer_nim::{NimTraceWriter, TraceEventsFileFormat, trace_writer::TraceWriter};

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::trace_reader::TraceReader;

/// The single source file every step in the fixture recording lives in.
const SRC: &str = "/tmp/m0_browser_seekable_prog.py";

/// Number of user steps recorded.
///
/// `steps.dat` uses a 4096-record chunk, so this spans several chunks. That
/// matters: the whole point of the lazy path is that a point lookup inflates
/// ONE chunk, and a fixture that fits in a single chunk cannot tell a bounded
/// read from a whole-stream read.
const USER_STEPS: usize = 9000;

/// Distinct user lines the steps spread across, so the line→step map is
/// non-trivial and several steps share a line.
const DISTINCT_LINES: usize = 50;

fn line_of_user_step(i: usize) -> i64 {
    10 + (i % DISTINCT_LINES) as i64
}

/// Write a GENUINELY `events.log`-free split-only `.ct` through the Nim
/// multi-stream writer — the write path every live recorder drives — and return
/// its path.
fn write_production_bundle(dir: &Path) -> PathBuf {
    let trace_path = dir.join("m0_browser_seekable");
    let ct_path = dir.join("m0_browser_seekable_prog.ct");

    let mut writer = NimTraceWriter::new("m0_browser_seekable_prog", &[], TraceEventsFileFormat::Ctfs);
    writer.set_workdir(dir);
    writer.begin_writing_trace_metadata(&trace_path).unwrap();
    writer.finish_writing_trace_metadata().unwrap();
    writer.begin_writing_trace_events(&trace_path).unwrap();
    writer.begin_writing_trace_paths(&trace_path).unwrap();
    writer.finish_writing_trace_paths().unwrap();

    let path = Path::new(SRC);
    let fid = writer.ensure_function_id("main", path, Line(1));
    writer.register_function("main", path, Line(1));

    writer.start(path, Line(1));
    writer.register_step(path, Line(1));
    let int_type = writer.ensure_type_id(TypeKind::Int, "int");
    TraceWriter::register_call(&mut writer, fid, vec![]);

    for i in 0..USER_STEPS {
        writer.register_step(path, Line(line_of_user_step(i)));
        let value = ValueRecord::Int {
            i: i as i64,
            type_id: int_type,
        };
        writer.register_variable_with_full_value("var", value);
    }

    writer.register_return(ValueRecord::None { type_id: TypeId(0) });
    writer.finish_writing_trace_events().unwrap();
    writer.close().unwrap();

    assert!(
        ct_path.exists(),
        "the Nim writer must produce {} — without it this suite has no subject",
        ct_path.display()
    );
    ct_path
}

/// A leading step at the function line plus `USER_STEPS` user steps.
fn expected_step_count() -> usize {
    USER_STEPS + 2
}

/// The bundle, plus the two readers over it: `native` via the filesystem +
/// Nim FFI path, `browser` via the in-memory + pure-Rust path.
struct Fixture {
    _dir: tempfile::TempDir,
    native: CTFSTraceReader,
    browser: CTFSTraceReader,
    bytes_len: usize,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let ct_path = write_production_bundle(dir.path());

    // The container really is the production split-stream format: a
    // `steps.dat` and NO `events.log`. If this ever stops holding, every
    // assertion below would be testing the legacy path instead, silently.
    let probe = db_backend::ctfs_trace_reader::ctfs_container::CtfsReader::open(&ct_path)
        .expect("the produced .ct must be a readable CTFS container");
    assert!(
        probe.has_file("steps.dat"),
        "fixture must be a split-stream bundle (steps.dat present)"
    );
    assert!(
        !probe.has_file("events.log"),
        "fixture must be split-ONLY (no events.log), or this suite tests the legacy path"
    );

    let native = CTFSTraceReader::open(&ct_path).expect("the native path must open the production bundle");

    let bytes = std::fs::read(&ct_path).expect("the .ct bytes must be readable");
    let bytes_len = bytes.len();
    let browser = CTFSTraceReader::from_bytes(bytes)
        .expect("from_bytes must open a NEW-FORMAT seekable container — this is the M0/1 deliverable");

    Fixture {
        _dir: dir,
        native,
        browser,
        bytes_len,
    }
}

/// M0/1, and the milestone's `test_browser_opens_new_format_container`.
///
/// The browser constructor accepts a split-stream container at all. Before M0
/// this returned `Err("CTFS new format (nim-reader) is not supported via
/// from_bytes; only old-format containers can be loaded from in-memory data")`.
#[test]
fn from_bytes_opens_a_new_format_seekable_container() {
    let f = fixture();
    assert_eq!(
        f.browser.step_count(),
        expected_step_count(),
        "the browser reader must see every recorded step"
    );
    assert_eq!(
        f.browser.step_count(),
        f.native.step_count(),
        "browser and native readers must agree on the step total"
    );
    assert!(f.bytes_len > 0);
}

/// M0/1 — the constructor ATTACHES the seekable streams rather than hard-coding
/// them to `None`, which is the second half of the deliverable and the reason a
/// container that opened would still have been fully materialized.
#[test]
fn from_bytes_attaches_every_seekable_stream() {
    let f = fixture();

    assert_eq!(
        f.browser.seekable_call_count(),
        f.native.seekable_call_count(),
        "the seekable calls.dat source must attach on the browser path"
    );
    assert!(
        f.browser.seekable_call_count().is_some(),
        "calls.dat must be attached, not None"
    );

    assert_eq!(
        f.browser.seekable_step_count(),
        Some(expected_step_count()),
        "the seekable steps.dat source must attach and span the whole trace"
    );
    assert!(
        f.browser.seekable_value_count().is_some(),
        "the seekable values.dat source must attach"
    );
    assert!(
        f.browser.seekable_event_count().is_some(),
        "the seekable events.dat source must attach (M0/4)"
    );
}

/// M0/1 — the *step lines* served through the seekable stream are the same ones
/// the native reader serves. This is the assertion that would catch a decode
/// bug in the pure-Rust path: it compares two independent decoders of the same
/// bytes over every step, not a sample.
#[test]
fn browser_and_native_readers_agree_on_every_step() {
    let f = fixture();
    let count = f.native.step_count();
    assert_eq!(count, expected_step_count());

    for i in 0..count {
        let id = StepId(i as i64);
        let native = f.native.step(id).copied();
        let browser = f.browser.step(id).copied();
        assert_eq!(
            native.map(|s| (s.path_id, s.line, s.call_key)),
            browser.map(|s| (s.path_id, s.line, s.call_key)),
            "step {i} disagrees between the native (Nim FFI) and browser (pure-Rust) readers"
        );
    }
}

/// M0/1 — the call tree decodes identically on both paths, including the tree
/// STRUCTURE (parent/children/depth), which is what the calltrace pane renders.
#[test]
fn browser_and_native_readers_agree_on_the_call_tree() {
    let f = fixture();
    assert_eq!(
        f.browser.call_count(),
        f.native.call_count(),
        "call totals must agree between the two readers"
    );
    assert!(f.browser.call_count() > 0, "the fixture records at least one call");

    for key in 0..f.native.call_count() {
        let key = CallKey(key as i64);
        let native = f.native.call(key).expect("native call");
        let browser = f.browser.call(key).expect("browser call");
        assert_eq!(native.key, browser.key);
        assert_eq!(native.function_id, browser.function_id, "function id of {key:?}");
        assert_eq!(native.parent_key, browser.parent_key, "parent of {key:?}");
        assert_eq!(native.depth, browser.depth, "depth of {key:?}");
        assert_eq!(native.children_keys, browser.children_keys, "children of {key:?}");
        assert_eq!(native.step_id, browser.step_id, "entry step of {key:?}");
    }
}

/// M0/1 + the milestone's `test_navigation_does_not_materialize_step_table`,
/// for the browser path.
///
/// Opening the container and then walking it by POINT LOOKUP — the access
/// pattern stepping produces — must never trigger the whole-table build. This
/// is the assertion a fixture small enough to fit in memory cannot make for
/// you: the reader would pass a stepping test either way.
#[test]
fn browser_navigation_does_not_materialize_the_step_table() {
    let f = fixture();

    assert_eq!(
        f.browser.lazy_full_steps_materialized(),
        Some(false),
        "the whole step table must NOT be built at open"
    );
    assert_eq!(
        f.browser.lazy_steps_populated(),
        Some(0),
        "no step slot may be filled at open"
    );

    let count = f.browser.step_count();

    // (a) LOCAL stepping — forward then reverse over a short window, which is
    //     what step-over / step-back actually produce. The fill is
    //     chunk-ALIGNED (a point lookup materializes its chunk's range), so the
    //     bound to assert is "one chunk's worth", not "one step's worth".
    for i in 0..200 {
        assert!(f.browser.step(StepId(i)).is_some(), "forward step {i}");
    }
    for i in (0..200).rev() {
        assert!(f.browser.step(StepId(i)).is_some(), "reverse step {i}");
    }
    let populated = f.browser.lazy_steps_populated().expect("on the lazy path");
    assert!(
        populated < count,
        "200 local steps filled {populated} of {count} slots — local navigation must fill only \
         the chunks it touched, not the whole trace"
    );
    let chunks = f
        .browser
        .lazy_steps_chunk_decompressions()
        .expect("on the lazy path");
    assert!(
        chunks <= 2,
        "200 contiguous steps inflated {chunks} steps.dat chunks; a local walk spans at most two"
    );

    // (b) A SWEEP across the whole trace touches every chunk — which is
    //     expected and fine — but must STILL not trigger the whole-table build,
    //     because that build is a different, much more expensive thing: it
    //     materializes a `Vec<DbStep>` plus a per-path line→steps map for every
    //     step at once.
    let mut visited = 0usize;
    for i in (0..count).step_by(97) {
        assert!(f.browser.step(StepId(i as i64)).is_some(), "swept step {i}");
        visited += 1;
    }
    assert!(visited > 50, "the sweep must be substantial, not a token read");

    assert_eq!(
        f.browser.lazy_full_steps_materialized(),
        Some(false),
        "point-lookup navigation must never trigger the whole-table build, however far it roams"
    );
}

/// M0/2 — bounded decompression on the browser path: reading a step inflates at
/// most the one `steps.dat` chunk that holds it, and re-reading within a chunk
/// inflates nothing further.
///
/// This is the property the wasm32 stubs made unobservable: they returned
/// `None` for every read and `0` for every counter, so a test like this could
/// not fail against them.
#[test]
fn a_browser_step_read_inflates_at_most_one_chunk() {
    let f = fixture();
    assert_eq!(
        f.browser.lazy_steps_chunk_decompressions(),
        Some(0),
        "nothing may be inflated at open"
    );

    f.browser.step(StepId(0)).expect("step 0");
    let after_first = f.browser.lazy_steps_chunk_decompressions().expect("on the lazy path");
    assert!(
        after_first <= 1,
        "one step read inflated {after_first} chunks; expected at most 1"
    );

    // Ten more reads clustered inside the same chunk must not inflate again.
    for i in 1..10 {
        f.browser.step(StepId(i)).expect("clustered step");
    }
    assert_eq!(
        f.browser.lazy_steps_chunk_decompressions(),
        Some(after_first),
        "reads clustered within one chunk must not re-inflate it"
    );
}

/// M0/1 — per-step VALUES are served from the seekable `values.dat` stream and
/// match the native reader's, so the locals pane is not silently empty on the
/// browser path.
#[test]
fn browser_and_native_readers_agree_on_step_values() {
    let f = fixture();

    let mut checked = 0usize;
    let mut non_empty = 0usize;
    for i in (0..f.native.step_count()).step_by(211) {
        let id = StepId(i as i64);
        let native: Vec<_> = f.native.variables_at(id).map(|v| v.to_vec()).unwrap_or_default();
        let browser: Vec<_> = f.browser.variables_at(id).map(|v| v.to_vec()).unwrap_or_default();
        assert_eq!(
            native.len(),
            browser.len(),
            "step {i} has {} locals natively but {} in the browser",
            native.len(),
            browser.len()
        );
        for (n, b) in native.iter().zip(browser.iter()) {
            assert_eq!(n.variable_id, b.variable_id, "variable id at step {i}");
            assert_eq!(
                format!("{:?}", n.value),
                format!("{:?}", b.value),
                "variable value at step {i}"
            );
        }
        if !browser.is_empty() {
            non_empty += 1;
        }
        checked += 1;
    }
    assert!(checked > 10, "the sweep must cover the trace, not a single step");
    assert!(
        non_empty > 0,
        "every sampled step had zero locals — the value stream is not actually serving anything"
    );
}

/// M0/1 — the container-internal `step-map.ns` breakpoint index attaches on the
/// browser path too. Before M0 `from_bytes` never called the loader at all, so
/// a browser-loaded trace always fell back to the whole-table build for
/// breakpoint resolution — the single most expensive thing it could do.
#[test]
fn browser_path_attaches_the_container_internal_step_map() {
    let f = fixture();
    assert!(
        f.native.has_prepopulated_step_map(),
        "the Nim writer emits step-map.ns by default; without it this case has no subject"
    );
    assert!(
        f.browser.has_prepopulated_step_map(),
        "the browser path must attach the container-internal step-map.ns"
    );
}

/// M0/3 — BREAKPOINT resolution on the browser path is served from the index
/// and does NOT trigger the whole-table build, and it agrees with the native
/// reader line for line.
#[test]
fn browser_breakpoint_resolution_avoids_the_whole_table_build() {
    let f = fixture();
    let path_id = f
        .browser
        .path_id_for(SRC)
        .expect("the fixture's source path must be interned");
    assert_eq!(
        f.native.path_id_for(SRC),
        Some(path_id),
        "both readers must intern the source path at the same id"
    );

    for i in 0..DISTINCT_LINES {
        let line = 10 + i;
        let browser = f.browser.step_ids_on_line(path_id, line);
        let native = f.native.step_ids_on_line(path_id, line);
        assert_eq!(browser, native, "line {line} resolves differently on the two readers");
        assert!(
            browser.map(|ids| !ids.is_empty()).unwrap_or(false),
            "line {line} must resolve to at least one step in this fixture"
        );
    }

    assert_eq!(
        f.browser.lazy_full_steps_materialized(),
        Some(false),
        "breakpoint resolution through the index must not materialize the step table"
    );
}

/// M0/4 — `event_count()` is answered from the `events.dat` chunk index without
/// decoding any event, and the borrowing `events()` accessor materializes only
/// when it is actually called.
#[test]
fn browser_event_count_does_not_decode_events() {
    let f = fixture();

    let seekable = f
        .browser
        .seekable_event_count()
        .expect("the fixture's bundle carries an events.dat stream");
    assert_eq!(
        f.browser.event_count(),
        seekable,
        "event_count must come from the stream index"
    );

    // A page read is bounded and returns what it asked for (or the tail).
    let page = f
        .browser
        .seekable_event_page(0, 4)
        .expect("a reader with a stream must serve a page");
    assert!(page.len() <= 4, "a page must not exceed its requested length");
    assert_eq!(page.len(), std::cmp::min(4, seekable), "a page must be filled from the head");

    // Past-the-end is an empty page, not a panic and not a wrap-around.
    assert!(
        f.browser
            .seekable_event_page(seekable + 1000, 10)
            .expect("still a stream")
            .is_empty(),
        "a page past the end must be empty"
    );
}

/// M0/1 — the browser reader resolves the same function VOCABULARY the native
/// reader does.
///
/// It also pins a limitation rather than papering over it. The production Nim
/// writer interns a function as its NAME ONLY (`interning_table.nim`'s
/// `ensureId` appends raw name bytes), so neither reader can report where a
/// function was defined: both give `PathId(0)` / `Line(0)`. The stub is in the
/// FORMAT, not in either reader, and asserting it here means the day a writer
/// starts recording definition sites this test fails and says so, instead of
/// the limitation quietly persisting because nothing looked at it.
#[test]
fn browser_and_native_readers_agree_on_the_function_table() {
    let f = fixture();
    assert!(
        f.browser.function_count() > 0,
        "the fixture registers at least one function"
    );
    assert_eq!(
        f.browser.function_count(),
        f.native.function_count(),
        "function totals must agree"
    );

    for id in 0..f.native.function_count() {
        let id = codetracer_trace_types::FunctionId(id);
        let native = f.native.function(id).expect("native function");
        let browser = f.browser.function(id).expect("browser function");
        assert_eq!(native.name, browser.name, "function {id:?} name");
        assert_eq!(native.path_id, browser.path_id, "function {id:?} path");
        assert_eq!(native.line, browser.line, "function {id:?} line");
    }

    let main = f
        .browser
        .function(codetracer_trace_types::FunctionId(0))
        .expect("the fixture's function");
    assert_eq!(main.name, "main");
    assert_eq!(
        main.line,
        Line(0),
        "the production writer does not record a function's definition line in funcs.dat, so both \
         readers report 0. If this now fails, a writer started recording it — propagate that \
         through `interning_tables::RecordLayout` rather than deleting the assertion."
    );
}

/// M0/3 — the LINE-MAP accessors answer exactly what the step-by-step walk
/// they replace would have answered.
///
/// This is the acceptance condition for routing `load_location` through them.
/// The walk is `max(step.line)` over the steps from `start` up to the first one
/// whose `call_key` differs; the accessors get the run's end from the resident
/// call-key array and the run's greatest line from `step-map.ns`. Here the two
/// are computed independently over the whole trace and compared at every step —
/// including the leading steps that sit outside the recorded call, where the run
/// is EMPTY and the walk stops on its first iteration.
#[test]
fn line_map_accessors_agree_with_the_walk_they_replace() {
    let f = fixture();
    let steps_len = f.browser.step_count() as i64;
    assert!(steps_len > 0, "the fixture must record steps");

    // The walk, verbatim from the pre-M0/3 `use_trace_function_boundaries`.
    let walk = |start: i64, call_key: CallKey| -> (i64, i64) {
        let mut max_line = 0i64;
        let mut end = steps_len;
        for i in start..steps_len {
            let step = f.browser.step(StepId(i)).expect("step in range");
            if step.call_key == call_key {
                if step.line.0 > max_line {
                    max_line = step.line.0;
                }
            } else {
                end = i;
                break;
            }
        }
        (end, max_line)
    };

    // Every step, against its OWN call key — the case `load_location` hits on
    // the browser path — sampled densely enough to cross the run boundaries and
    // cheaply enough that the O(n^2) reference walk stays a test.
    let stride = std::cmp::max(1, steps_len / 400);
    let mut checked_empty_runs = 0;
    let mut checked_nonempty_runs = 0;
    for start in (0..steps_len).step_by(stride as usize) {
        let own_key = f.browser.step(StepId(start)).expect("step in range").call_key;
        for call_key in [own_key, CallKey(own_key.0 + 1)] {
            let (want_end, want_max) = walk(start, call_key);
            let got_end = f
                .browser
                .call_run_end(StepId(start), call_key)
                .expect("the browser reader must serve the call-run end from its call-key index");
            assert_eq!(
                got_end,
                StepId(want_end),
                "call-run end disagrees at step {start} for call key {call_key:?}"
            );
            let got_max = f
                .browser
                .max_line_over_steps(StepId(start), got_end)
                .expect("the browser reader must serve the range maximum from step-map.ns");
            assert_eq!(
                got_max, want_max,
                "range maximum disagrees over [{start}, {want_end}) for call key {call_key:?}"
            );
            if want_end == start {
                checked_empty_runs += 1;
            } else {
                checked_nonempty_runs += 1;
            }
        }
    }
    assert!(
        checked_empty_runs > 0 && checked_nonempty_runs > 0,
        "the case must exercise both an empty run and a real one \
         (saw {checked_empty_runs} empty / {checked_nonempty_runs} non-empty)"
    );
}

/// M0/3 — the accessors are served from the INDICES, not from the step stream:
/// answering them neither materializes the whole step table nor inflates a
/// single `steps.dat` chunk.
///
/// This is the property that removes the cubic. If either assertion fails the
/// accessors are reading steps after all, and `load_location` is back to paying
/// per-step costs on every call.
#[test]
fn line_map_accessors_do_not_touch_the_step_stream() {
    let f = fixture();
    let before = f
        .browser
        .lazy_steps_chunk_decompressions()
        .expect("the browser reader must be on the lazy step path");

    let steps_len = f.browser.step_count() as i64;
    for start in (0..steps_len).step_by(97) {
        let end = f
            .browser
            .call_run_end(StepId(start), CallKey(0))
            .expect("call-run end must be served");
        f.browser
            .max_line_over_steps(StepId(start), end)
            .expect("range maximum must be served");
    }

    assert_eq!(
        f.browser.lazy_steps_chunk_decompressions(),
        Some(before),
        "the line-map accessors must not inflate a steps.dat chunk"
    );
    assert_eq!(
        f.browser.lazy_full_steps_materialized(),
        Some(false),
        "the line-map accessors must not trigger the whole-table build"
    );
}

/// M0/3 — the NATIVE reader answers the accessors identically to the browser
/// reader.
///
/// The native path normally never reaches this code (tree-sitter supplies the
/// boundaries from the readable source), but it does for languages with no
/// grammar and for BEAM traces, and the two readers are independent decoders of
/// the same bytes. If they ever disagree, `load_location` would return a
/// different `function_last` depending on which constructor opened the trace.
#[test]
fn native_and_browser_readers_agree_on_the_line_map_accessors() {
    let f = fixture();
    let steps_len = f.browser.step_count() as i64;
    for start in (0..steps_len).step_by(89) {
        for call_key in [CallKey(0), CallKey(-1), CallKey(1)] {
            let browser_end = f.browser.call_run_end(StepId(start), call_key);
            assert_eq!(
                f.native.call_run_end(StepId(start), call_key),
                browser_end,
                "readers disagree on the call-run end at step {start} for {call_key:?}"
            );
            let end = browser_end.expect("call-run end must be served");
            assert_eq!(
                f.native.max_line_over_steps(StepId(start), end),
                f.browser.max_line_over_steps(StepId(start), end),
                "readers disagree on the range maximum over [{start}, {end:?})"
            );
        }
    }
}

/// M0/3 — a reader with NO prepopulated line index refuses the range maximum
/// rather than answering from a partial table, so its caller keeps the walk.
///
/// The guard is `covers_all_steps`: only a table that records every step id
/// exactly once can serve a range maximum, because a table missing a step would
/// silently drop that step's line out of the maximum — a wrong answer, not a
/// slow one.
#[test]
fn an_incomplete_line_index_refuses_to_serve_the_range_maximum() {
    let f = fixture();
    let step_map = f
        .browser
        .step_map()
        .expect("the fixture's container carries step-map.ns");
    assert!(
        step_map.covers_all_steps(f.browser.step_count()),
        "the fixture's table records every step, which is why the accessor may serve it \
         ({} ids for {} steps)",
        step_map.total_step_ids(),
        f.browser.step_count()
    );
    assert!(
        !step_map.covers_all_steps(f.browser.step_count() + 1),
        "a table that does not account for every step must be refused"
    );
    assert!(
        !step_map.covers_all_steps(0),
        "a non-empty table cannot cover an empty trace"
    );
}

/// A container that is NOT a CTFS bundle still fails with a typed, named error
/// rather than opening an empty trace — the failure mode `setup_from_vfs`'s
/// comment calls out as worse than an error, because a user reads it as "the
/// program did nothing".
#[test]
fn from_bytes_rejects_non_ctfs_bytes_by_name() {
    let err = CTFSTraceReader::from_bytes(b"this is not a .ct container at all".to_vec())
        .expect_err("garbage bytes must not open");
    let message = err.to_string();
    assert!(
        !message.is_empty(),
        "the error must say something the transport can propagate"
    );
}
