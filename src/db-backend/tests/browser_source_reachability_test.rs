//! Source reachability on the browser path: the origin chain's probe, and the
//! bundled sources a container ships.
//!
//! ## Why these are host tests, and why that is not the `-d:nodejs` mistake
//!
//! The defects here are both invisible natively for the same reason: on
//! `wasm32-unknown-unknown` `Path::exists()` is hardwired `false` and
//! `fs::read_to_string` is `Unsupported`, so a native run takes the *other*
//! branch of every probe and never reaches the code under test.
//!
//! A test that merely runs on the host repeats that mistake. These do not:
//! every fixture path is asserted `!exists()` on the filesystem BEFORE it is
//! used, which forces `Path::exists()` to answer `false` — the same answer it
//! gives unconditionally in a browser. The branch taken here is therefore the
//! branch the wasm build takes, and the VFS store is a plain `HashMap` with no
//! `cfg` on it, so the code executing is byte-for-byte the shipped code.
//!
//! This is the shape `browser_vfs_source_test.rs` established, extended one
//! layer down to the probe that feeds the classifier.
//!
//! ## Mutation arms (each reddens its own assertion)
//!
//! * `db::source_probe_path` reverted to `workdir_path.exists()`
//!   → reds `the_probe_picks_the_spelling_the_vfs_can_serve` and
//!     `both_spellings_a_host_may_have_written_resolve`, ONLY.
//! * `expr_loader::get_source_line_v2`'s bundled branch reverted to
//!   `candidate.exists() && fs::read_to_string(..)`
//!   → reds `a_bundled_source_in_the_vfs_reads_back_with_bundled_origin`, ONLY.
//! * `Handler::load_bundled_sources_from_vfs` made to return 0 without writing
//!   → reds `the_vfs_loader_extracts_every_raw_view_a_container_ships`, ONLY.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use db_backend::ctfs_trace_reader::CTFSTraceReader;
use db_backend::dap_handler::Handler;
use db_backend::db::source_probe_path;
use db_backend::expr_loader::{ExprLoader, SourceOrigin, bundled_source_path};
use db_backend::recreator_session::RecreatorArgs;
use db_backend::task::{CoreTrace, TraceKind};
use db_backend::trace_reader::TraceReader;
use db_backend::vfs;

// ---------------------------------------------------------------------------
// Defect 1 — the origin chain's probe path.
// ---------------------------------------------------------------------------

/// The recorded path spelling that produced the measurement: the browser Noir
/// compiler records a RELATIVE path. For an ABSOLUTE recorded path
/// `workdir.join(recorded)` discards the workdir and both arms of the probe
/// collapse onto one string, so an absolute fixture could not fail and would
/// prove nothing.
const RECORDED_RELATIVE: &str = "src/main.nr";

const SOURCE: &str = "// a_1_mul\nfn main(x: Field, y: pub Field) {\n    let z = x * y;\n    assert(z == 6);\n}\n";

/// Row 3 under the loader's 1-indexed convention is `let z = x * y;` — the
/// assignment the §6.1 classifier parses. Asserting the text pins that the
/// probe resolved the *right file at the right offset*, not merely something.
const ROW: usize = 3;
const EXPECTED_LINE: &str = "    let z = x * y;";

/// A workdir that is certain not to exist, so `Path::exists()` answers `false`
/// for it and for everything under it — which is what a browser sees for every
/// path, always.
fn workdir(case: &str) -> PathBuf {
    PathBuf::from(format!("/virtual/browser-produced/{case}/workdir"))
}

fn loader() -> ExprLoader {
    ExprLoader::new(CoreTrace::default())
}

/// Assert the fixture really is in the browser condition. Without this the
/// tests below would silently become native tests the moment someone ran them
/// on a machine where `/virtual/...` happened to exist.
fn assert_nothing_is_on_disk(paths: &[&Path]) {
    let mut checked = 0usize;
    for p in paths {
        assert!(
            !p.exists(),
            "fixture path {} exists on disk; this test would then take the native \
             branch and prove nothing about a browser",
            p.display()
        );
        checked += 1;
    }
    assert_eq!(checked, paths.len(), "every fixture path must have been checked");
    assert!(checked > 0, "an empty fixture set would pass this vacuously");
}

/// The measured defect: 105 failed reads of `src/main.nr` while the joined
/// spelling sat loaded in the same session.
///
/// The host wrote the source into the VFS under `workdir/src/main.nr`. The
/// probe asked `workdir_path.exists()`, got the browser's unconditional
/// `false`, and handed the classifier the bare `src/main.nr` — a key the store
/// does not hold. Every read missed.
#[test]
fn the_probe_picks_the_spelling_the_vfs_can_serve() {
    let wd = workdir("probe-picks");
    let joined = wd.join(RECORDED_RELATIVE);
    let bare = PathBuf::from(RECORDED_RELATIVE);
    assert_nothing_is_on_disk(&[&wd, &joined, &bare]);
    assert_ne!(
        joined,
        bare,
        "the two spellings must be different keys, or this test cannot distinguish them"
    );

    // The negative half FIRST and asserted: with nothing in the store the
    // probe must fall through to the bare spelling exactly as it always did.
    assert_eq!(
        source_probe_path(&wd, RECORDED_RELATIVE),
        bare,
        "with no source anywhere the fallback order is unchanged"
    );

    // The host writes the joined spelling — the case that was broken.
    vfs::vfs_write(&joined.to_string_lossy(), SOURCE.as_bytes().to_vec());

    let probe = source_probe_path(&wd, RECORDED_RELATIVE);
    assert_eq!(
        probe, joined,
        "the probe must choose the spelling the engine can actually read, not the \
         one `Path::exists()` is able to answer for"
    );

    // Resolution and classification are separate claims, so they are separate
    // assertions: a probe that returned the right path but yielded no line
    // would still leave the origin chain with nothing to parse.
    let (line, origin) = loader().get_source_line_v2(&probe, ROW, None);
    assert_ne!(
        origin,
        SourceOrigin::Unavailable,
        "the classifier must see a resolved line, not an absent one"
    );
    assert_eq!(
        line, EXPECTED_LINE,
        "the line handed to `parse_assignment` must be the recorded text at that row"
    );
}

/// The property the fix had to preserve.
///
/// blocktracer writes source at the RELATIVE path deliberately, because that
/// is the only spelling the broken probe could ever reach. Making the probe
/// VFS-aware must not invert that: the fallback ORDER is unchanged, so when
/// the store holds only the bare spelling the joined one is simply unreachable
/// and the probe falls through to it, as before.
#[test]
fn the_bare_spelling_still_wins_when_that_is_what_the_host_wrote() {
    let wd = workdir("bare-wins");
    let joined = wd.join(RECORDED_RELATIVE);
    let bare = PathBuf::from("relative-only/src/main.nr");
    assert_nothing_is_on_disk(&[&wd, &joined, &bare]);

    vfs::vfs_write(&bare.to_string_lossy(), SOURCE.as_bytes().to_vec());

    let probe = source_probe_path(&wd, &bare.to_string_lossy());
    assert_eq!(
        probe, bare,
        "the joined spelling is not in the store, so the probe must still fall \
         through to the bare one — the downstream work-around stays correct"
    );
    let (line, origin) = loader().get_source_line_v2(&probe, ROW, None);
    assert_ne!(origin, SourceOrigin::Unavailable);
    assert_eq!(line, EXPECTED_LINE);
}

/// Universal quantification with the count asserted, so an empty or shrunken
/// case list cannot pass vacuously.
///
/// Both spellings a host may plausibly have written must resolve — that is the
/// whole point of making the probe ask about reachability instead of about the
/// filesystem.
#[test]
fn both_spellings_a_host_may_have_written_resolve() {
    let wd = workdir("both-spellings");

    // (case name, the key the host wrote into the VFS)
    let cases: [(&str, PathBuf); 2] = [
        ("host wrote the workdir-joined spelling", wd.join(RECORDED_RELATIVE)),
        ("host wrote the bare recorded spelling", PathBuf::from(RECORDED_RELATIVE)),
    ];
    assert_eq!(cases.len(), 2, "both spellings must be covered");

    let mut resolved = 0usize;
    for (name, written_key) in &cases {
        // A fresh workdir per case so the two cases cannot serve each other,
        // and a fresh loader so `processed_files` cannot cache across them.
        let case_wd = wd.join(name.replace(' ', "-"));
        let case_key = if written_key.is_absolute() {
            case_wd.join(RECORDED_RELATIVE)
        } else {
            PathBuf::from(format!("{}/{}", name.replace(' ', "-"), RECORDED_RELATIVE))
        };
        let recorded = if written_key.is_absolute() {
            RECORDED_RELATIVE.to_string()
        } else {
            case_key.to_string_lossy().to_string()
        };
        assert_nothing_is_on_disk(&[&case_key]);

        vfs::vfs_write(&case_key.to_string_lossy(), SOURCE.as_bytes().to_vec());
        let probe = source_probe_path(&case_wd, &recorded);
        let (line, origin) = loader().get_source_line_v2(&probe, ROW, None);
        assert_ne!(origin, SourceOrigin::Unavailable, "{name}: origin must be resolved");
        assert_eq!(line, EXPECTED_LINE, "{name}: wrong line text");
        resolved += 1;
    }
    assert_eq!(
        resolved,
        cases.len(),
        "every spelling must have been exercised — a loop that ran zero times \
         would otherwise pass"
    );
}

// ---------------------------------------------------------------------------
// Defect 2 — bundled sources a container ships.
// ---------------------------------------------------------------------------

/// A committed CTFS container that really does ship `srcviews.dat`: the
/// GDScript fixture, whose `res://gf_values.gd` path never exists on any
/// replay host. It is the reason §5.2 exists.
fn fixture_ct() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("gdscript")
        .join("gf_values")
        .join("gdscript_trace.ct")
}

const RECORDED_GD: &str = "res://gf_values.gd";
/// Line 30 of `gf_values.gd`, tab-indented as the recorder bundled it.
const GD_ROW: usize = 30;
const GD_EXPECTED_LINE: &str = "\tvar received = factor";

/// Build the handler `setup_from_vfs` builds: reader from the container BYTES,
/// never from a path. Returns the bytes too, since the VFS loader consumes the
/// same buffer the caller already holds.
fn handler_from_container_bytes() -> (Handler, Vec<u8>) {
    let ct = fixture_ct();
    assert!(
        ct.is_file(),
        "GDScript fixture missing at {} — this test must NOT silently skip",
        ct.display()
    );
    let bytes = std::fs::read(&ct).expect("fixture container must be readable");
    let reader: Arc<dyn TraceReader> =
        Arc::new(CTFSTraceReader::from_bytes(bytes.clone()).expect("fixture must parse as CTFS"));
    let handler = Handler::construct_with_reader(TraceKind::Materialized, RecreatorArgs::default(), reader, false);
    (handler, bytes)
}

/// The measurement behind the judgement: `load_bundled_sources` cannot reach a
/// browser session, so wiring it into `setup_from_vfs` would have been three
/// no-ops in a row.
///
/// It discovers the container with `is_file()`/`is_dir()`/`read_dir` and
/// extracts with `fs::write` — all of which answer `false`/`Err` on wasm32.
/// Here it is handed a directory that does not exist, which is exactly what it
/// would see in a browser, where nothing does.
#[test]
fn the_native_bundled_loader_reaches_nothing_without_a_filesystem() {
    let (mut handler, _bytes) = handler_from_container_bytes();
    let no_such_dir = PathBuf::from("/virtual/browser-produced/no-disk-here/trace");
    assert_nothing_is_on_disk(&[&no_such_dir]);

    handler.load_bundled_sources(&no_such_dir);
    assert!(
        handler.bundled_sources_root.is_none(),
        "the native loader is filesystem-bound end to end; with no filesystem it \
         must extract nothing — this is why it is not wired into the browser path"
    );
}

/// The browser sibling does reach the views, and the count is asserted so a
/// loader that quietly extracted nothing cannot pass.
#[test]
fn the_vfs_loader_extracts_every_raw_view_a_container_ships() {
    let (mut handler, bytes) = handler_from_container_bytes();
    assert!(
        handler.bundled_sources_root.is_none(),
        "nothing may be extracted before the loader runs"
    );

    let extracted = handler.load_bundled_sources_from_vfs("/vfs/case/extracts/recording.ct", bytes);
    assert_eq!(
        extracted, 1,
        "the GDScript fixture bundles exactly one raw (kind 0) view — its \
         `res://gf_values.gd` source"
    );

    let root = handler
        .bundled_sources_root
        .clone()
        .expect("a successful extraction must publish its root");
    // The write must land on the key the read side derives. Deriving it here
    // with the same function is deliberate: spelling it by hand would keep
    // passing if the two sides drifted apart.
    let dest = bundled_source_path(&root, Path::new(RECORDED_GD));
    assert_nothing_is_on_disk(&[&dest]);
    let stored = vfs::vfs_read(&dest.to_string_lossy()).expect("the extracted view must be in the VFS at that key");
    let text = String::from_utf8(stored).expect("the bundled GDScript view is UTF-8");
    assert!(
        text.contains(GD_EXPECTED_LINE),
        "the stored bytes must be the recorder's own copy of the source"
    );
}

/// The read half, isolated: given a bundled source that exists ONLY in the
/// VFS, `get_source_line_v2`'s bundled branch must resolve it and must report
/// `BundledMetaData` — not `Filesystem`, and not `Unavailable`.
///
/// Separate from the extraction test on purpose. The branch used to be
/// `candidate.exists() && fs::read_to_string(..)`, two filesystem calls that
/// are `false` and `Unsupported` on wasm32; a container could then be
/// extracted perfectly and still read back as absent.
#[test]
fn a_bundled_source_in_the_vfs_reads_back_with_bundled_origin() {
    let root = PathBuf::from("/virtual/browser-produced/bundled-read/sources");
    let recorded = Path::new(RECORDED_GD);
    let dest = bundled_source_path(&root, recorded);
    assert_nothing_is_on_disk(&[&root, &dest]);

    let gd_source = std::fs::read_to_string(fixture_ct().with_file_name("gf_values.gd"))
        .expect("the fixture's plain-text source sits beside the container");
    assert!(
        gd_source.lines().count() >= GD_ROW,
        "the fixture must actually have line {GD_ROW}"
    );

    // Negative half first, and asserted: without the VFS entry the bundled
    // branch has nothing, so the pair is the absent one.
    let (before, origin_before) = loader().get_source_line_v2(&recorded.to_path_buf(), GD_ROW, Some(&root));
    assert_eq!(
        origin_before,
        SourceOrigin::Unavailable,
        "a `res://` path resolves nowhere until the bundle is reachable"
    );
    assert!(before.is_empty());

    vfs::vfs_write(&dest.to_string_lossy(), gd_source.into_bytes());

    let (line, origin) = loader().get_source_line_v2(&recorded.to_path_buf(), GD_ROW, Some(&root));
    assert_eq!(
        origin,
        SourceOrigin::BundledMetaData,
        "the line came from the container's own bundle, and the origin must say so \
         — reporting `Filesystem` here would misattribute provenance"
    );
    assert_eq!(
        line, GD_EXPECTED_LINE,
        "the bundled branch must return the exact recorded line at that row"
    );
}
