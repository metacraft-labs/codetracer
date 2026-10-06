//! The backend-manager's trace-metadata reader against a container the
//! native recorder writes, recorded on the fly.
//!
//! `ct-mcr record --split` records a small C program; the reader must open
//! the recording and every slice by their own `.ct` paths and report the
//! recording id the recorder announced.  That id is checked against two
//! sources outside the code under test: the `recording_id:` line `ct-mcr`
//! prints, and the `CODETRACER_RECORDING_ID` the program itself saw in its
//! environment (the recorder exports it before launch).  A reader that
//! starts `meta.dat`'s body anywhere but byte 12 (`flags_ext` is always
//! present at version 6, `internal-files.md` §"Extended flags") reads the
//! id's length from the wrong byte and fails here; so does a reader that
//! does not accept a bare `.ct` path.
//!
//! No mocks: a real recorder, a real compiler and a real container.  The
//! byte-layout cases (every version refused but 6, unknown `flags_ext`
//! bits, short headers) are the unit tests in `src/meta_dat.rs`, built
//! from the spec's layout.
//!
//! Prerequisites, each a FAILURE when absent (never a skip): a C compiler
//! (`cc`, or `CC`), and `ct-mcr` (`CODETRACER_CT_MCR_CMD`, else the sibling
//! `codetracer-native-recorder/ct_cli/ct_cli`, else `ct-mcr` on `PATH`).
//!
//! Hermetic: the recorder runs without any `CT_*_DEBUG_*` variable from the
//! caller's environment.  `ct-mcr record` refuses a host without CPUID
//! faulting (Multi-Core-Recorder.md §8.3), so on such a host this test
//! fails at the recording step and says why; the debug knob that would
//! let it record there is stripped on purpose.

#[path = "../src/meta_dat.rs"]
#[allow(dead_code)]
mod meta_dat;

#[path = "../src/trace_metadata.rs"]
#[allow(dead_code)]
mod trace_metadata;

use std::path::{Path, PathBuf};
use std::process::Command;

/// The recorded program.  It writes the recording id it was given, then
/// does a little work so the recording has events to split.
const PROGRAM_SOURCE: &str = r#"#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  const char *out = getenv("PROBE_OUT");
  const char *id = getenv("CODETRACER_RECORDING_ID");
  FILE *f = fopen(out ? out : "probe-id.txt", "w");
  if (f == NULL) return 2;
  fprintf(f, "%s", id ? id : "");
  fclose(f);
  long sum = 0;
  for (int i = 0; i < 64; i++) {
    sum += i * argc;
    printf("step %d %ld\n", i, sum);
  }
  return sum > 0 ? 0 : 3;
}
"#;

/// Locate `ct-mcr`, or fail naming every place looked at.
fn find_ct_mcr() -> PathBuf {
    if let Ok(cmd) = std::env::var("CODETRACER_CT_MCR_CMD")
        && !cmd.is_empty()
    {
        return PathBuf::from(cmd);
    }
    let sibling = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../codetracer-native-recorder/ct_cli/ct_cli");
    if sibling.is_file() {
        return sibling;
    }
    if let Ok(output) = Command::new("which").arg("ct-mcr").output()
        && output.status.success()
    {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    panic!(
        "MISSING PREREQUISITE: ct-mcr was not found (CODETRACER_CT_MCR_CMD is unset, \
         {} does not exist, and ct-mcr is not on PATH).  Build it with \
         `just build-ct-mcr` in codetracer-native-recorder.  This test reads a \
         recording made on the fly; without the recorder it has nothing to read.",
        sibling.display()
    );
}

/// A command whose environment carries no `CT_*_DEBUG_*` variable.
fn hermetic(program: &Path) -> Command {
    let mut command = Command::new(program);
    for (key, _) in std::env::vars_os() {
        let key = key.to_string_lossy().into_owned();
        if key.starts_with("CT_") && key.contains("_DEBUG_") {
            command.env_remove(&key);
        }
    }
    command
}

/// The value of the `recording_id: <id>` line `ct-mcr record` prints.
fn printed_recording_id(stdout: &str) -> Option<String> {
    stdout
        .lines()
        .find_map(|line| line.strip_prefix("recording_id: "))
        .map(|id| id.trim().to_owned())
}

#[test]
fn a_native_recording_and_each_of_its_slices_name_the_recording() {
    let dir = tempfile::tempdir().expect("tempdir");
    let source = dir.path().join("meta_probe.c");
    std::fs::write(&source, PROGRAM_SOURCE).expect("write program source");
    let program = dir.path().join("meta_probe");
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let compiled = Command::new(&cc)
        .args(["-g", "-O0", "-o"])
        .arg(&program)
        .arg(&source)
        .output()
        .unwrap_or_else(|e| panic!("MISSING PREREQUISITE: cannot run the C compiler {cc:?}: {e}"));
    assert!(
        compiled.status.success(),
        "compiling the recorded program failed: {}",
        String::from_utf8_lossy(&compiled.stderr)
    );

    let ct_mcr = find_ct_mcr();
    let trace = dir.path().join("meta_probe.ct");
    let observed_id_file = dir.path().join("observed-id.txt");
    let recorded = hermetic(&ct_mcr)
        .current_dir(dir.path())
        .env("PROBE_OUT", &observed_id_file)
        .args(["record", "--split", "-o"])
        .arg(&trace)
        .arg("--")
        .arg(&program)
        .output()
        .expect("spawn ct-mcr record");
    let stdout = String::from_utf8_lossy(&recorded.stdout);
    let stderr = String::from_utf8_lossy(&recorded.stderr);
    assert!(
        recorded.status.success(),
        "ct-mcr record failed ({}); a host without CPUID faulting is refused \
         by design (Multi-Core-Recorder.md §8.3).\nstdout:\n{stdout}\nstderr:\n{stderr}",
        recorded.status
    );

    let printed = printed_recording_id(&stdout)
        .unwrap_or_else(|| panic!("ct-mcr printed no recording_id line:\n{stdout}"));
    let observed = std::fs::read_to_string(&observed_id_file).expect("the program wrote its id");
    assert_eq!(
        observed, printed,
        "the program saw a different recording id than ct-mcr printed"
    );

    // The recording, read by its own `.ct` path.
    let meta = trace_metadata::read_trace_metadata(&trace)
        .unwrap_or_else(|e| panic!("reading {}: {e}", trace.display()));
    assert_eq!(meta.recording_id, printed);
    assert_eq!(meta.program, program.to_string_lossy());
    assert_eq!(meta.workdir, dir.path().to_string_lossy());
    assert_eq!(meta.language, "c");
    assert!(
        meta.source_files.iter().any(|p| Path::new(p) == source),
        "paths.dat does not name the recorded source {}: {:?}",
        source.display(),
        meta.source_files
    );

    // Its meta.dat, parsed directly: version 6, the flag word and the
    // extended word that precede the id.
    let bytes = std::fs::read(&trace).expect("read container");
    let raw = meta_dat::read_meta_dat_from_ctfs(&bytes).expect("meta.dat member");
    let parsed = meta_dat::parse_meta_dat(&raw).expect("parse meta.dat");
    assert_eq!(parsed.version, 6);
    assert_eq!(parsed.recording_id, printed);
    assert!(
        parsed.mcr.is_some(),
        "a native recording carries the MCR block (flag bit 0)"
    );

    // Every slice names the same recording.
    let slices_dir = dir.path().join("meta_probe.ct_slices");
    let mut slices: Vec<PathBuf> = std::fs::read_dir(&slices_dir)
        .unwrap_or_else(|e| panic!("--split wrote no {}: {e}", slices_dir.display()))
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "ct"))
        .collect();
    slices.sort();
    assert!(!slices.is_empty(), "--split wrote no slice");
    for slice in &slices {
        let slice_meta = trace_metadata::read_trace_metadata(slice)
            .unwrap_or_else(|e| panic!("reading slice {}: {e}", slice.display()));
        assert_eq!(
            slice_meta.recording_id,
            printed,
            "slice {} names another recording",
            slice.display()
        );
        assert_eq!(slice_meta.program, program.to_string_lossy());
    }
}
