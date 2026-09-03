//! REGRESSION: a real, already-published split-stream (`steps.dat`, no
//! `events.log`) container must OPEN.
//!
//! This is the end-to-end shape of a shipping defect. Every caller in
//! `ctfs_trace_reader` resolves stream presence structurally and then passed an
//! EMPTY `meta` slice to the format-level `from_files` constructors, on the
//! documented understanding that the argument is ignored. That understanding
//! holds only for `codetracer-trace-format` at or after `9ad9454`; the revision
//! `flake.lock` pins still gated on `meta_dat_has_step_stream(meta)`, which is
//! `false` for an empty slice. Against the pinned crate the seekable step stream
//! therefore NEVER opened, and `open_new_format_rust` refused every such
//! container with
//!
//! > new-format container advertises steps.dat but no seekable step stream
//! > could be opened; the container is inconsistent
//!
//! Because only split-stream containers reach that path, the refusal landed on
//! exactly the recordings that publish source, while old-format `events.log`
//! captures kept opening — which is why it read as a product defect rather than
//! an engine one.
//!
//! The two unit tests in `ctfs_trace_reader::tests` pin the same contract
//! against a synthetically written bundle. This one pins it against containers
//! as they were actually written and shipped, so a reader that only satisfies
//! the writer we happen to drive in-process cannot pass.

use db_backend::ctfs_trace_reader::CTFSTraceReader;

/// In-repo containers that carry `steps.dat` and no `events.log`, spanning
/// several recorders so the guard is not tied to one writer's quirks.
const SPLIT_STREAM_FIXTURES: &[&str] = &[
    "tests/fixtures/gdscript_mixed/combined_trace.ct",
    "tests/fixtures/gdscript/gf_values/gdscript_trace.ct",
    "tests/fixtures/gdscript/gf_coroutine/gdscript_trace.ct",
    "tests/fixtures/span_stream/web_session.ct",
];

#[test]
fn published_split_stream_containers_open() {
    for path in SPLIT_STREAM_FIXTURES {
        let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("fixture {path} unreadable: {e}"));

        // Guard the guard: if a fixture stops being a split-stream container
        // this test would pass while checking nothing.
        let ctfs = db_backend::ctfs_trace_reader::ctfs_container::CtfsReader::from_bytes(bytes.clone())
            .unwrap_or_else(|e| panic!("{path}: {e}"));
        assert!(
            ctfs.has_file("steps.dat") && !ctfs.has_file("events.log"),
            "{path} must be a split-stream container for this test to mean anything",
        );

        CTFSTraceReader::from_bytes(bytes)
            .unwrap_or_else(|e| panic!("published split-stream container {path} must open, got: {e}"));
    }
}
