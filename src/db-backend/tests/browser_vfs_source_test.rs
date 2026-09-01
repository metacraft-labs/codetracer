//! Source text pushed into the in-memory VFS is the source the engine reads.
//!
//! ## What this is for
//!
//! A trace produced inside a browser tab carries its own source text — the
//! Noir wasm tracer records `MemoryTrace::source_views[].content` for every
//! path it interns — but `trace.json` is a bare `Vec<TraceLowLevelEvent>` and
//! has nowhere to put it. The host therefore writes each view into the
//! engine's VFS at the recorded path, beside `trace.json`.
//!
//! Before this test's subject existed that write reached nothing. The VFS was
//! consulted at seven call sites, all of them in `dap_server`'s trace-container
//! discovery and all of them before a `Handler` exists; every consumer of
//! source *text* went through `ExprLoader`, which read `std::fs`
//! unconditionally. On `wasm32-unknown-unknown` `fs::read_to_string` is
//! `Unsupported` and `Path::exists()` is hardwired `false`, so in a browser
//! every recorded path was the missing-source case whether or not its text was
//! in memory.
//!
//! ## Why these three assertions and not one
//!
//! It was an open question whether getting source into the container serves
//! *position resolution* (`Location::missing_path`, which gates the editor
//! pane) or the *origin-chain classifier* (spec §6.1, which parses a source
//! line with the `origin-classifier` crate) — they were assumed to be separate
//! consumers needing separate work. They are not: `missing_path` and
//! `get_source_line_v2` are both `ExprLoader` members and both key on the same
//! recorded path, so one read serves both. The three cases below assert that
//! as a measured fact rather than leaving it as a reading of the code.
//!
//! Run with the default feature set — the store is target-independent, so this
//! exercises on the host exactly the code the wasm build runs.

use std::path::PathBuf;

use codetracer_trace_types::Line;
use db_backend::expr_loader::{ExprLoader, SourceOrigin};
use db_backend::task::Location;
use db_backend::vfs;

/// A path that is certain not to exist on this machine's filesystem, so a
/// success can only have come from the VFS.
fn virtual_path(case: &str) -> String {
    format!("/virtual/browser-produced/{case}/src/main.nr")
}

const SOURCE: &str = "// a_1_mul\nfn main(x: Field, y: pub Field) {\n    let z = x * y;\n    assert(z == 6);\n}\n";

fn loader() -> ExprLoader {
    ExprLoader::new(db_backend::task::CoreTrace::default())
}

fn location_for(path: &str) -> Location {
    Location {
        path: path.to_string(),
        ..Default::default()
    }
}

#[test]
fn source_written_into_the_vfs_is_readable_by_the_expr_loader() {
    let path = virtual_path("readable");
    assert!(
        !PathBuf::from(&path).exists(),
        "the fixture path must not exist on disk, or this test proves nothing"
    );

    let loader = loader();
    // The negative half FIRST, and asserted, because the whole test is a
    // claim about a difference: without the VFS entry the read must fail.
    assert!(
        loader.file_source_code(&PathBuf::from(&path)).is_err(),
        "a path with neither a file nor a VFS entry must not resolve"
    );

    vfs::vfs_write(&path, SOURCE.as_bytes().to_vec());
    let text = loader
        .file_source_code(&PathBuf::from(&path))
        .expect("the VFS entry is the recording's own copy of the file");
    assert_eq!(text, SOURCE);
}

#[test]
fn the_origin_chain_classifier_gets_its_line_from_the_vfs() {
    // `get_source_line_v2` is the sole source-line acquisition point for the
    // §6.1 origin chain: `MaterializedReplaySession::origin_chain_inferred`
    // hands its result to `origin_classifier::parse_assignment`, and treats
    // `SourceOrigin::Unavailable` or an empty string as "no source" and stops
    // the hop. So the assertion is on BOTH halves of the returned pair.
    let path = virtual_path("classifier");
    let mut loader = loader();

    let (before, origin_before) = loader.get_source_line_v2(&PathBuf::from(&path), 3, None);
    assert_eq!(
        origin_before,
        SourceOrigin::Unavailable,
        "without a VFS entry the classifier has no line to parse"
    );
    assert!(before.is_empty());

    vfs::vfs_write(&path, SOURCE.as_bytes().to_vec());

    // A fresh loader: `processed_files` caches per path, and a cache hit from
    // the call above would make this pass without reading anything.
    let mut loader = self::loader();
    let (line, origin) = loader.get_source_line_v2(&PathBuf::from(&path), 3, None);
    assert_ne!(
        origin,
        SourceOrigin::Unavailable,
        "the classifier must see a resolved line, not an absent one"
    );
    assert_eq!(
        line, "    let z = x * y;",
        "the line handed to `parse_assignment` must be the recorded text at that row"
    );
}

#[test]
fn missing_path_is_false_for_a_path_the_vfs_can_serve() {
    // `Location::missing_path` is what `editor_service.nim` reads to decide
    // between opening the editor and opening the NO SOURCE view. Both arms are
    // asserted here: a session that reported every position as resolved would
    // pass a one-sided check while displaying nothing.
    let served = virtual_path("served");
    let unserved = virtual_path("unserved");
    vfs::vfs_write(&served, SOURCE.as_bytes().to_vec());

    let loader = loader();
    let resolved = loader.find_function_location(&location_for(&served), &Line(3));
    assert!(
        !resolved.missing_path,
        "the recording carries this file's text, so its position is not missing a path"
    );

    let absent = loader.find_function_location(&location_for(&unserved), &Line(3));
    assert!(
        absent.missing_path,
        "a path with no file and no VFS entry is still missing; a `missing_path` \
         that is false for everything is not a resolution, it is a broken check"
    );
    // Guard against the two arms silently becoming the same query.
    assert_ne!(resolved.path, absent.path);
}

/// The recorded path is the key, and nothing normalises it.
///
/// The store is a flat `HashMap<String, Vec<u8>>` with no path handling at
/// all, and three separate probes in the engine spell a source path three
/// ways (`find_real_path`, `workdir.join(path)` in `StepLinesLoader`, and the
/// origin chain's `workdir.join(path)`-or-bare ternary). For an ABSOLUTE
/// recorded path — which is what the Noir tracer emits — `PathBuf::join`
/// discards the workdir and all three collapse onto the same string. This
/// pins that, because a host that wrote relative keys would produce a session
/// that loads, reports success, and resolves nothing.
#[test]
fn an_absolute_recorded_path_is_the_same_key_under_every_probe() {
    let recorded = virtual_path("absolute");
    assert!(PathBuf::from(&recorded).is_absolute());
    let workdir = PathBuf::from("/some/other/workdir");
    assert_eq!(
        workdir.join(&recorded).to_string_lossy(),
        recorded,
        "joining an absolute recorded path onto a workdir must yield the path itself"
    );

    vfs::vfs_write(&recorded, SOURCE.as_bytes().to_vec());
    let loader = loader();
    assert_eq!(
        loader
            .file_source_code(&workdir.join(&recorded))
            .expect("the joined form resolves to the same VFS key"),
        SOURCE
    );
}
