//! The backend-manager's trace-metadata reader against a container the
//! pinned trace-format writer writes, written on the fly.
//!
//! The reader here (`src/meta_dat.rs`, `src/trace_metadata.rs`) is a
//! hand-written copy of the container and `meta.dat` layouts, separate from
//! the writer, so the two can disagree about a version number or a byte
//! offset with nothing in the build to say so.  That is how the reader came
//! to refuse the very recordings `ct record` produced (container version 5,
//! `meta.dat` version 7).  The cases in `meta_dat_metadata_loading.rs` build
//! their containers with this crate's own `write_minimal_ctfs` and
//! `serialize_meta_dat`, i.e. with the reader's idea of the layout, so they
//! cannot see such a disagreement; `meta_dat_real_mcr_recording.rs` reads a
//! real container but needs `ct-mcr` on a Linux host with CPUID faulting, and
//! it covers the MCR recorder's writer, not this one.
//!
//! This file writes a recording with `codetracer_trace_writer`'s
//! `CtfsTraceWriter` — the pure-Rust writer this crate already depends on
//! for `record-web`, taken from the sibling `codetracer-trace-format`
//! checkout at the revision the lock pins — and reads it back through the
//! backend-manager's reader.  Every version it expects is the writer's own
//! constant (`codetracer_ctfs::header::VERSION`,
//! `codetracer_trace_writer::meta_dat::META_DAT_VERSION`), never a literal,
//! so a writer that moves a version fails here until the reader follows.
//!
//! No mocks: a real writer, a real container on the real filesystem and the
//! reader under test.  There is no prerequisite to skip on: the writer is a
//! path dependency, so without the sibling checkout this file does not
//! compile, and that is a failure.

#[path = "../src/meta_dat.rs"]
#[allow(dead_code)]
mod meta_dat;

#[path = "../src/trace_metadata.rs"]
#[allow(dead_code)]
mod trace_metadata;

use std::path::{Path, PathBuf};

use codetracer_trace_types::{Line, PathId, StepRecord, TraceLowLevelEvent};
use codetracer_trace_writer::ctfs_writer::CtfsTraceWriter;
use codetracer_trace_writer::trace_writer::TraceWriter;

/// What the recording is fed.  The program is a path with an extension so
/// `read_trace_metadata` reports it unchanged (it substitutes the first
/// source path for a bare interpreter name), and an argument carries a space
/// so a reader that splits or joins arguments is caught.
const PROGRAM: &str = "/work/pinned-writer/main.py";
const WORKDIR: &str = "/work/pinned-writer";
const SOURCE_PATH: &str = "/work/pinned-writer/main.py";

fn args() -> Vec<String> {
    vec!["--input".to_owned(), "data file.txt".to_owned()]
}

/// Write a small recording through the pinned writer into `dir/trace.ct`:
/// the entry call and step `start` emits, then two more steps on the same
/// path.  Returns the container's path.
fn write_recording(dir: &Path) -> PathBuf {
    let trace = dir.join("trace.ct");
    let mut writer = CtfsTraceWriter::new(PROGRAM, &args());
    TraceWriter::set_workdir(&mut writer, Path::new(WORKDIR));
    TraceWriter::begin_writing_trace_events(&mut writer, &trace)
        .unwrap_or_else(|e| panic!("could not start {}: {e}", trace.display()));

    let source = Path::new(SOURCE_PATH);
    TraceWriter::start(&mut writer, source, Line(1));
    // `start` registered the path; asking again must hand back the same id,
    // the only one in the recording.
    let path_id = TraceWriter::ensure_path_id(&mut writer, source);
    assert_eq!(path_id, PathId(0), "the one registered path is not id 0");
    for line in [2, 3] {
        TraceWriter::add_event(
            &mut writer,
            TraceLowLevelEvent::Step(StepRecord {
                path_id,
                line: Line(line),
            }),
        );
    }
    TraceWriter::finish_writing_trace_events(&mut writer)
        .unwrap_or_else(|e| panic!("could not finish {}: {e}", trace.display()));
    assert!(
        writer.refusals().is_empty(),
        "the writer refused part of the recording: {:?}",
        writer.refusals()
    );
    assert!(trace.is_file(), "the writer left no {}", trace.display());
    trace
}

#[test]
fn a_recording_the_pinned_writer_wrote_is_read_field_by_field() {
    let dir = tempfile::tempdir().expect("tempdir");
    let trace = write_recording(dir.path());
    let bytes = std::fs::read(&trace).expect("read the container");

    // The container version byte follows the five-byte magic
    // (`ctfs-container.md` §1).  It must be the writer's, and the reader must
    // get past its header check for it, which every read below depends on.
    assert!(bytes.len() > 5, "container is {} bytes", bytes.len());
    assert_eq!(&bytes[0..5], &codetracer_ctfs::header::MAGIC[..]);
    assert_eq!(
        bytes[5],
        codetracer_ctfs::header::VERSION,
        "the container does not carry the version its writer declares"
    );

    // meta.dat, through the reader's own CTFS walk.
    let dat = meta_dat::read_meta_dat_from_ctfs(&bytes)
        .unwrap_or_else(|e| panic!("the reader cannot find meta.dat in the container: {e}"));
    let written_version = u16::from_le_bytes([dat[4], dat[5]]);
    assert_eq!(
        written_version,
        codetracer_trace_writer::meta_dat::META_DAT_VERSION,
        "meta.dat does not carry the version its writer declares"
    );
    assert!(
        meta_dat::SUPPORTED_META_DAT_VERSIONS.contains(&written_version),
        "the reader does not admit meta.dat version {written_version}, the one the pinned \
         writer writes (it admits {:?})",
        meta_dat::SUPPORTED_META_DAT_VERSIONS
    );

    let parsed = meta_dat::parse_meta_dat(&dat)
        .unwrap_or_else(|e| panic!("the reader refuses the meta.dat the pinned writer wrote: {e}"));
    assert_eq!(parsed.version, written_version);
    assert_eq!(parsed.program, PROGRAM);
    assert_eq!(parsed.args, args());
    assert_eq!(parsed.workdir, WORKDIR);
    assert!(
        meta_dat::is_canonical_uuid_v7(&parsed.recording_id),
        "recording id {:?} is not a canonical UUIDv7",
        parsed.recording_id
    );

    // The writer mints the id itself and has no accessor for it, so its own
    // decoder is the second witness: a reader that starts the body at the
    // wrong offset, or reads a field the writer does not write, disagrees
    // with it here.
    let witness = codetracer_trace_writer::meta_dat::decode_meta_dat(&dat)
        .unwrap_or_else(|e| panic!("the writer's own decoder refuses its meta.dat: {e}"));
    assert_eq!(parsed.recording_id, witness.recording_id);
    assert_eq!(parsed.flags, witness.flags);
    assert_eq!(parsed.ext_flags, witness.ext_flags);
    assert_eq!(parsed.recorder_id, witness.recorder_id);

    // `paths.dat` is the recording's only list of source paths.
    let paths = meta_dat::read_source_paths_from_ctfs(&bytes, parsed.flags)
        .unwrap_or_else(|e| panic!("the reader cannot read paths.dat: {e}"));
    assert_eq!(paths, vec![SOURCE_PATH.to_owned()]);

    // The entry point the daemon uses, on the folder and on the bare `.ct`.
    for target in [dir.path(), trace.as_path()] {
        let meta = trace_metadata::read_trace_metadata(target).unwrap_or_else(|e| {
            panic!(
                "read_trace_metadata({}) refuses the recording: {e}",
                target.display()
            )
        });
        assert_eq!(meta.recording_id, parsed.recording_id);
        assert_eq!(meta.program, PROGRAM);
        assert_eq!(meta.workdir, WORKDIR);
        assert_eq!(meta.source_files, vec![SOURCE_PATH.to_owned()]);
        assert_eq!(meta.language, "python");
        // No MCR block, so this is the size of `steps.dat`; three steps were
        // written, so it cannot be empty.
        assert!(meta.total_events > 0, "the recording reports no events");
    }
}
