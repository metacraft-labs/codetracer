//! RV-4 — the materialized-trace DeepReview collector, over a real recording.
//!
//! `codetracer-specs/DeepReview/Review-Command.milestones.org` RV-4:
//! "DeepReview for Python, Ruby, JavaScript and every other language that
//! produces a materialized trace."  This suite is the collector's own half of
//! that: a real program, recorded by a real recorder, reviewed against a real
//! git diff, and every number in the resulting dataset checked against what
//! the program actually did.
//!
//! # No mocks, and why the fixtures are Noir and Python
//!
//! Nothing here is mocked: the recordings are produced by real recorders
//! (`nargo trace` and `python -m codetracer_python_recorder`), the diff by
//! `git diff`, and the dataset by the production
//! `deepreview::collector::collect`.  The collector reads a *trace*, not a
//! language, so the language of a fixture is not load-bearing; what is
//! load-bearing is that the trace is real and that both on-disk layouts a
//! materialized recording comes in are covered:
//!
//! * Noir, unconditionally — `nargo trace` writes a legacy `runtime_tracing`
//!   `trace.json`, the layout `diff::load_and_postprocess_trace` refuses;
//! * Python, when the recorder is importable
//!   (`a_python_recording_reviews_the_way_a_noir_one_does`) — the Rust-backed
//!   `codetracer_python_recorder` writes a `*.ct` CTFS container, which is a
//!   different arm of `materialized_source::open_materialized_trace`.  It is
//!   also the milestone's own verification entry ("an end-to-end review over a
//!   Python recording"), so the Python case is run rather than argued from
//!   Noir's equivalence.
//!
//! The third layout — a legacy `trace.bin`, what the pre-CTFS recordings in
//! `codetracer-example-recordings/` are — has no case here: those recordings
//! live in a sibling repository a checkout need not have, and a case that
//! skipped when the sibling was absent would report nothing.  It is checked by
//! hand instead; see RV-4's judgement call 5.
//!
//! Requires `nargo` on PATH, like the sibling Noir suites
//! (`noir_loop_diagnostic.rs`, `noir_space_ship_calltrace_jump_flow.rs`).

use std::path::{Path, PathBuf};
use std::process::Command;

mod test_harness;

use db_backend::deepreview::cli::{ReviewCollectArgs, discover_recordings};
use db_backend::deepreview::collector::{CollectOptions, collect};
use db_backend::deepreview::json::DeepReviewData;
use db_backend::deepreview::unified_diff::parse_unified_diff;

/// The reviewed program, after the change.  Line numbers are asserted below,
/// so the layout of this literal is part of the fixture.
///
/// ```text
/// 1  fn main(x: Field) {
/// 2      let mut sum: Field = 0;
/// 3      for i in 0..4 {
/// 4          let contribution = (i as Field) * x;
/// 5          sum = sum + contribution;
/// 6      }
/// 7      let final_result = sum;
/// 8      assert(final_result == 30);
/// 9  }
/// ```
const NEW_SOURCE: &str = "fn main(x: Field) {\n    let mut sum: Field = 0;\n    for i in 0..4 {\n        let contribution = (i as Field) * x;\n        sum = sum + contribution;\n    }\n    let final_result = sum;\n    assert(final_result == 30);\n}\n";

/// The same program before the change: the loop adds `x` directly, so the two
/// added lines of the diff are the ones the review is about.
const OLD_SOURCE: &str = "fn main(x: Field) {\n    let mut sum: Field = 0;\n    for i in 0..4 {\n        sum = sum + x;\n    }\n    let final_result = sum;\n    assert(final_result == 20);\n}\n";

fn assert_nargo() {
    Command::new("nargo")
        .arg("--version")
        .output()
        .expect("nargo not found on PATH; the materialized collector fixture is recorded with it");
}

fn run(program: &str, args: &[&str], cwd: &Path) {
    let output = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap_or_else(|e| panic!("running {program} {args:?}: {e}"));
    assert!(
        output.status.success(),
        "{program} {args:?} failed in {}:\nstdout: {}\nstderr: {}",
        cwd.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A scratch git repository holding the Noir program at two commits, plus one
/// recording of the newer one.
struct Fixture {
    root: PathBuf,
    repo: PathBuf,
    recordings: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn build_fixture(tag: &str) -> Fixture {
    assert_nargo();
    let root = std::env::temp_dir().join(format!("rv4-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let repo = root.join("repo");
    let recordings = root.join("recordings");
    std::fs::create_dir_all(repo.join("src")).expect("mkdir repo/src");
    std::fs::create_dir_all(&recordings).expect("mkdir recordings");

    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test-programs/noir_loop");
    for name in ["Nargo.toml", "Prover.toml"] {
        std::fs::copy(manifest.join(name), repo.join(name)).unwrap_or_else(|e| panic!("copy {name}: {e}"));
    }

    run("git", &["init", "-q"], &repo);
    run("git", &["config", "user.email", "rv4@test"], &repo);
    run("git", &["config", "user.name", "rv4"], &repo);
    std::fs::write(repo.join("src/main.nr"), OLD_SOURCE).expect("write old source");
    run("git", &["add", "-A"], &repo);
    run("git", &["commit", "-qm", "base"], &repo);
    std::fs::write(repo.join("src/main.nr"), NEW_SOURCE).expect("write new source");
    run("git", &["add", "-A"], &repo);
    run("git", &["commit", "-qm", "change"], &repo);

    let out = recordings.join("run-1");
    std::fs::create_dir_all(&out).expect("mkdir run-1");
    run("nargo", &["trace", "--out-dir", out.to_str().expect("utf8")], &repo);

    Fixture { root, repo, recordings }
}

/// Collect the fixture through the CLI entry point `ct review collect`
/// invokes, and read back the `review.json` it wrote.
fn collect_fixture(fixture: &Fixture, output_name: &str) -> DeepReviewData {
    let output = fixture.root.join(output_name);
    let args = ReviewCollectArgs {
        repo: Some(fixture.repo.clone()),
        diff_spec: Some("HEAD~..HEAD".to_string()),
        recordings: fixture.recordings.clone(),
        output: output.clone(),
        progress: false,
        ..ReviewCollectArgs::default()
    };
    let report = db_backend::deepreview::cli::run(&args).expect("collection");
    assert_eq!(report.recordings_collected, 1, "the fixture has one recording");
    let text = std::fs::read_to_string(output.join("review.json")).expect("review.json");
    serde_json::from_str(&text).expect("review.json is the dataset shape")
}

/// The patch `git` produces for the fixture's one change.
fn fixture_patch(fixture: &Fixture) -> String {
    let output = Command::new("git")
        .args(["-C", fixture.repo.to_str().expect("utf8"), "diff", "HEAD~..HEAD"])
        .output()
        .expect("git diff");
    assert!(output.status.success(), "git diff failed");
    String::from_utf8_lossy(&output.stdout).to_string()
}

/// Collect an explicit list of recordings, so a test can compare one against
/// several without going back through the CLI's discovery.
fn collect_recordings(fixture: &Fixture, recordings: &[PathBuf]) -> DeepReviewData {
    let options = CollectOptions {
        recordings: recordings.to_vec(),
        diff: parse_unified_diff(&fixture_patch(fixture)),
        repo_root: Some(fixture.repo.clone()),
        progress: false,
        ..CollectOptions::default()
    };
    let (data, report) = collect(&options).expect("collection");
    assert_eq!(report.recordings_collected, recordings.len());
    data
}

#[test]
fn a_materialized_recording_yields_a_dataset_with_the_diff_in_it() {
    let fixture = build_fixture("diff");
    let data = collect_fixture(&fixture, "out");

    assert_eq!(data.recording_count, 1);
    // Real commits, resolved from the repository — not a run of zeros.
    assert_eq!(data.commit_sha.len(), 40, "commitSha: {}", data.commit_sha);
    assert_eq!(
        data.base_commit_sha.len(),
        40,
        "baseCommitSha: {}",
        data.base_commit_sha
    );
    assert_ne!(data.commit_sha, data.base_commit_sha);

    assert_eq!(data.files.len(), 1);
    let file = &data.files[0];
    // The path is the one the patch names — repository-relative, as the GUI's
    // changed-files list shows it.
    assert_eq!(file.path, "src/main.nr");
    assert_eq!(file.diff.status, "M");
    assert_eq!(file.diff.lines_added, 3, "two loop-body lines plus the changed assert");
    assert_eq!(file.diff.lines_removed, 2);
    assert_eq!(file.diff.hunks.len(), 1);
    let kinds: Vec<&str> = file.diff.hunks[0].lines.iter().map(|l| l.line_type.as_str()).collect();
    assert!(kinds.contains(&"added") && kinds.contains(&"removed") && kinds.contains(&"context"));

    // The reviewed source travels with the dataset, so the editor can expand
    // context around a hunk without the repository.
    assert_eq!(file.source_content, NEW_SOURCE);
    assert_eq!(file.content_hash.len(), 64, "sha-256 hex");
}

#[test]
fn coverage_is_the_recordings_real_per_line_execution_counts() {
    let fixture = build_fixture("coverage");
    let data = collect_fixture(&fixture, "out");
    let file = &data.files[0];

    let count_for = |line: u32| -> u32 {
        file.coverage
            .iter()
            .find(|entry| entry.line == line)
            .map(|entry| entry.execution_count)
            .unwrap_or_else(|| panic!("no coverage for line {line}: {:?}", file.coverage))
    };

    // `for i in 0..4` runs its header five times (four iterations plus the
    // exit test) and its two body lines four times each.  These are the
    // recording's numbers, not a plausible-looking shape.
    assert_eq!(count_for(2), 1, "let mut sum");
    assert_eq!(count_for(3), 5, "for header");
    assert_eq!(count_for(4), 4, "let contribution");
    assert_eq!(count_for(5), 4, "sum = sum + contribution");
    assert_eq!(count_for(7), 1, "let final_result");
    assert_eq!(count_for(8), 1, "assert");

    for entry in &file.coverage {
        assert!(entry.executed, "only executed lines are reported: {entry:?}");
        // A materialized trace records every step, so samples == executions.
        assert_eq!(entry.sample_count, entry.execution_count);
        // A trace can say "not observed"; it cannot say "unreachable".
        assert!(!entry.unreachable);
        // One recording cannot make anything partial.
        assert!(!entry.partial);
    }
    // The covered set is exactly what the recorder emitted steps for.  Line 1
    // (`fn main(x: Field) {`) has no step of its own and the collector does
    // not invent one for it; line 6 (the loop's closing brace) does have one,
    // four times, and the collector does not drop it for looking odd.
    let covered: Vec<(u32, u32)> = file
        .coverage
        .iter()
        .map(|entry| (entry.line, entry.execution_count))
        .collect();
    assert_eq!(
        covered,
        vec![(2, 1), (3, 5), (4, 4), (5, 4), (6, 4), (7, 1), (8, 1), (9, 1)]
    );

    assert!(file.flags.has_coverage);
    assert!(!file.flags.is_unreachable);
    assert!(!file.flags.is_partial);
}

#[test]
fn flow_carries_the_functions_steps_values_and_loop_iterations() {
    let fixture = build_fixture("flow");
    let data = collect_fixture(&fixture, "out");
    let file = &data.files[0];

    assert_eq!(file.flow.len(), 1, "one invocation of main");
    let flow = &file.flow[0];
    assert_eq!(flow.function_key, "main");
    assert_eq!(flow.execution_index, 0);
    // 21 steps: the whole call, not the window from the diff line onward.
    assert_eq!(flow.steps.len(), 21, "steps: {:?}", flow.steps.len());

    // The loop body's steps are attributed to the loop and numbered by
    // iteration, which is what the overlay's iteration slider reads.
    let body: Vec<&db_backend::deepreview::json::FlowStepData> =
        flow.steps.iter().filter(|step| step.line == 4).collect();
    assert_eq!(body.len(), 4, "four iterations of the loop body");
    let iterations: Vec<i64> = body.iter().map(|step| step.iteration).collect();
    assert_eq!(iterations, vec![0, 1, 2, 3]);
    assert!(body.iter().all(|step| step.loop_id >= 0));

    // Real values, rendered the way the debugger renders them.
    let contribution: Vec<String> = body
        .iter()
        .filter_map(|step| step.values.iter().find(|value| value.name == "contribution"))
        .map(|value| value.value.clone())
        .collect();
    assert_eq!(contribution, vec!["0", "5", "10", "15"], "i * x for x = 5");
    assert!(body.iter().all(|step| step.values.iter().all(|value| !value.truncated)));

    // Steps carry the trace position, so a reviewer can jump from the overlay
    // into the recording.  On a materialized trace that is the step id.
    let positions: Vec<i64> = flow.steps.iter().map(|step| step.rr_ticks).collect();
    assert_eq!(positions.first(), Some(&0));
    assert!(
        positions.windows(2).all(|pair| pair[0] < pair[1]),
        "monotonic: {positions:?}"
    );

    // The loop itself is reported once, with its total iteration count.
    assert_eq!(file.loops.len(), 1);
    assert_eq!(file.loops[0].start_line, 3);
    assert_eq!(file.loops[0].end_line, 6);
    assert_eq!(file.loops[0].total_iterations, 4);
    assert!(file.flags.has_flow);
}

#[test]
fn symbols_and_function_coverage_come_from_the_recording() {
    let fixture = build_fixture("symbols");
    let data = collect_fixture(&fixture, "out");
    let file = &data.files[0];

    assert_eq!(file.symbols.len(), 1);
    let symbol = &file.symbols[0];
    assert_eq!(symbol.name, "main");
    assert_eq!(symbol.kind, "function");
    assert_eq!(symbol.start_line, 1);
    assert_eq!(symbol.end_line, 9);
    // RV-4 deliverable 4 — a materialized trace records that a function ran,
    // not its declared type or its visibility.  Empty, never a plausible
    // "private".
    assert_eq!(symbol.type_desc, "");
    assert_eq!(symbol.visibility, "");
    assert!(file.flags.has_symbols);

    assert_eq!(file.functions.len(), 1);
    assert_eq!(file.functions[0].name, "main");
    assert_eq!(file.functions[0].call_count, 1);
    assert_eq!(file.functions[0].execution_count, 1);
}

#[test]
fn the_dataset_names_the_recording_it_came_from() {
    let fixture = build_fixture("contexts");
    let data = collect_fixture(&fixture, "out");

    assert_eq!(data.trace_contexts.len(), 1);
    assert_eq!(data.trace_contexts[0].id, 0);
    assert_eq!(data.trace_contexts[0].label, "run-1");
    // The directory is not a UUID, so no recording id is claimed for it.
    assert_eq!(data.trace_contexts[0].recording_id, "");

    // Nothing supplied a title, so the dataset carries none rather than one
    // the collector made up.
    assert_eq!(data.session_title, "");

    let call_trace = data.call_trace.expect("a recording has a call tree");
    assert_eq!(call_trace.nodes.len(), 1);
    assert_eq!(call_trace.nodes[0].name, "main");
    assert_eq!(call_trace.nodes[0].execution_count, 1);
}

#[test]
fn a_legacy_trace_json_recording_is_read_the_way_the_debugger_reads_it() {
    // `nargo trace` writes the legacy runtime_tracing layout, which
    // `diff::load_and_postprocess_trace` refuses outright ("legacy
    // trace_metadata.json + trace.bin/trace.json sidecars are no longer
    // accepted").  The collector must not inherit that refusal: it is the
    // shape a Python recording has.
    let fixture = build_fixture("legacy");
    let recording = fixture.recordings.join("run-1");
    assert!(
        recording.join("trace.json").is_file(),
        "the fixture is the legacy layout"
    );
    assert!(
        !recording.join("trace.ct").exists(),
        "the fixture is not a CTFS container"
    );
    assert!(
        db_backend::diff::load_and_postprocess_trace(&recording).is_err(),
        "the CTFS-only loader still refuses it, which is why this path exists"
    );

    let found = discover_recordings(&fixture.recordings).expect("discovery");
    assert_eq!(found, vec![recording]);

    let data = collect_fixture(&fixture, "out");
    assert_eq!(data.recording_count, 1);
    assert!(!data.files[0].coverage.is_empty());
}

#[test]
fn a_recording_that_cannot_be_read_is_reported_and_skipped() {
    let fixture = build_fixture("broken");
    // A second "recording" that names itself one and is not readable.
    let broken = fixture.recordings.join("run-2");
    std::fs::create_dir_all(&broken).expect("mkdir run-2");
    std::fs::write(broken.join("trace.json"), "{not json").expect("write junk");

    let patch = "\
diff --git a/src/main.nr b/src/main.nr
--- a/src/main.nr
+++ b/src/main.nr
@@ -3,3 +3,4 @@
     for i in 0..4 {
+        let contribution = (i as Field) * x;
         sum = sum + contribution;
     }
";
    let options = CollectOptions {
        recordings: discover_recordings(&fixture.recordings).expect("discovery"),
        diff: parse_unified_diff(patch),
        repo_root: Some(fixture.repo.clone()),
        progress: false,
        ..CollectOptions::default()
    };
    assert_eq!(options.recordings.len(), 2, "both directories look like recordings");

    let (data, report) = collect(&options).expect("collection");
    // The good recording is still collected; the broken one is named.
    assert_eq!(report.recordings_collected, 1);
    assert_eq!(report.recordings_failed.len(), 1);
    assert_eq!(report.recordings_failed[0].0, broken);
    assert_eq!(data.recording_count, 1);
    assert_eq!(data.trace_contexts.len(), 1, "only readable recordings become contexts");
    assert!(!data.files[0].coverage.is_empty());
}

#[test]
fn a_file_no_recording_executed_is_reported_as_unreachable_not_dropped() {
    let fixture = build_fixture("unreachable");
    let patch = "\
diff --git a/src/main.nr b/src/main.nr
--- a/src/main.nr
+++ b/src/main.nr
@@ -8,1 +8,1 @@
-    assert(final_result == 20);
+    assert(final_result == 30);
diff --git a/src/never_run.nr b/src/never_run.nr
new file mode 100644
--- /dev/null
+++ b/src/never_run.nr
@@ -0,0 +1,1 @@
+fn unused() {}
";
    let options = CollectOptions {
        recordings: discover_recordings(&fixture.recordings).expect("discovery"),
        diff: parse_unified_diff(patch),
        repo_root: Some(fixture.repo.clone()),
        progress: false,
        ..CollectOptions::default()
    };
    let (data, _) = collect(&options).expect("collection");
    assert_eq!(
        data.files.len(),
        2,
        "a file with no coverage keeps its place in the changeset"
    );

    let never = data
        .files
        .iter()
        .find(|file| file.path == "src/never_run.nr")
        .expect("file");
    assert!(never.coverage.is_empty());
    assert!(never.flow.is_empty());
    assert!(never.flags.is_unreachable);
    assert!(!never.flags.has_coverage);
    assert_eq!(never.diff.status, "A");
    // The file is not in the repository, so no source travels with it — and
    // the hash is empty rather than the hash of an empty string.
    assert_eq!(never.source_content, "");
    assert_eq!(never.content_hash, "");
}

#[test]
fn two_recordings_of_the_same_change_are_merged_into_one_dataset() {
    // A review of a change is normally a review of several runs of it, and the
    // merge is where a dataset can quietly lie: double-counting, restarting an
    // execution index, or marking every line partial because more than one
    // recording exists.
    let fixture = build_fixture("merge");
    let second = fixture.recordings.join("run-2");
    std::fs::create_dir_all(&second).expect("mkdir run-2");
    run(
        "nargo",
        &["trace", "--out-dir", second.to_str().expect("utf8")],
        &fixture.repo,
    );

    let one = collect_recordings(&fixture, &[fixture.recordings.join("run-1")]);
    let both = collect_recordings(&fixture, &discover_recordings(&fixture.recordings).expect("discovery"));

    assert_eq!(one.recording_count, 1);
    assert_eq!(both.recording_count, 2);
    assert_eq!(both.trace_contexts.len(), 2);
    assert_eq!(
        both.trace_contexts.iter().map(|c| c.label.as_str()).collect::<Vec<_>>(),
        vec!["run-1", "run-2"],
        "contexts are in a stable, sorted order"
    );
    assert_eq!(both.trace_contexts.iter().map(|c| c.id).collect::<Vec<_>>(), vec![0, 1]);

    let single = &one.files[0];
    let merged = &both.files[0];
    // Coverage adds up, line for line.
    assert_eq!(merged.coverage.len(), single.coverage.len());
    for (a, b) in single.coverage.iter().zip(merged.coverage.iter()) {
        assert_eq!(a.line, b.line);
        assert_eq!(b.execution_count, a.execution_count * 2, "line {}", a.line);
        // Both recordings ran the same revision with the same input, so no
        // line is covered by only some of them.
        assert!(!b.partial, "line {} must not be partial", a.line);
    }
    assert!(!merged.flags.is_partial);

    // Two invocations, and they are DISTINCT invocations: the execution index
    // is the dataset's, not each recording's, because the GUI's invocation
    // selector keys on `(functionKey, executionIndex)`.
    assert_eq!(merged.flow.len(), 2);
    assert_eq!(
        merged.flow.iter().map(|f| f.execution_index).collect::<Vec<_>>(),
        vec![0, 1]
    );
    assert!(merged.flow.iter().all(|f| f.function_key == "main"));

    // Call counts and the call forest carry both recordings.
    let main = merged.functions.iter().find(|f| f.name == "main").expect("main");
    assert_eq!(main.call_count, 2);
    assert_eq!(main.execution_count, 2);
    assert_eq!(both.call_trace.expect("call tree").nodes.len(), 2);
}

#[test]
fn a_patch_file_names_no_commits_so_the_dataset_carries_none() {
    // RV-4 deliverable 4, item 5.  `--diff-file` hands the collection a patch
    // and nothing else, so there is no commit to name.  The dataset must say so
    // with EMPTY strings: a run of forty zeros is a real git object (the null
    // blob) and a reviewer reading it in the header would take it for one.
    let fixture = build_fixture("patchfile");
    let patch_path = fixture.root.join("change.patch");
    std::fs::write(&patch_path, fixture_patch(&fixture)).expect("write patch");

    let output = fixture.root.join("out-patch");
    let args = ReviewCollectArgs {
        // The repository is still given, because the patch's paths are relative
        // to it — this is exactly the case where a collector could be tempted
        // to resolve `HEAD` anyway and report a commit nobody asked about.
        repo: Some(fixture.repo.clone()),
        diff_file: Some(patch_path),
        recordings: fixture.recordings.clone(),
        output: output.clone(),
        progress: false,
        ..ReviewCollectArgs::default()
    };
    db_backend::deepreview::cli::run(&args).expect("collection");
    let text = std::fs::read_to_string(output.join("review.json")).expect("review.json");
    let data: DeepReviewData = serde_json::from_str(&text).expect("review.json is the dataset shape");

    assert_eq!(data.commit_sha, "", "a patch file names no commit");
    assert_eq!(data.base_commit_sha, "", "a patch file names no base commit");
    assert_ne!(data.commit_sha, "0".repeat(40));
    assert_ne!(data.base_commit_sha, "0".repeat(40));
    // The rest of the dataset is unaffected: the collection still happened.
    assert_eq!(data.recording_count, 1);
    assert!(!data.files[0].coverage.is_empty());
}

/// The Python program the end-to-end case reviews, after the change.
///
/// ```text
///  1  def scale(i, x):
///  2      scaled = i * x
///  3      return scaled
///  6  def main():
///  7      total = 0
///  8      for i in range(4):
///  9          contribution = scale(i, 5)
/// 10          total = total + contribution
/// 11      print(total)
/// 14  main()
/// ```
const PYTHON_NEW_SOURCE: &str = "def scale(i, x):\n    scaled = i * x\n    return scaled\n\n\ndef main():\n    total = 0\n    for i in range(4):\n        contribution = scale(i, 5)\n        total = total + contribution\n    print(total)\n\n\nmain()\n";

/// The same program before the change: the loop multiplies inline, so the
/// changed line is the one that introduces the call to `scale`.
const PYTHON_OLD_SOURCE: &str = "def scale(i, x):\n    scaled = i * x\n    return scaled\n\n\ndef main():\n    total = 0\n    for i in range(4):\n        contribution = i * 5\n        total = total + contribution\n    print(total)\n\n\nmain()\n";

#[test]
fn a_python_recording_reviews_the_way_a_noir_one_does() {
    // RV-4's third verification entry is "an end-to-end review over a Python
    // recording", and the rest of this suite substitutes Noir for it. Noir is
    // not a full stand-in: `nargo trace` writes a legacy `trace.json`, whereas
    // `codetracer_python_recorder` writes a `*.ct` CTFS container by default —
    // a DIFFERENT arm of `materialized_source::open_materialized_trace`. This
    // case runs the real recorder so the arm a Python review actually takes is
    // exercised, rather than argued to be equivalent.
    //
    // Skipped rather than failed when the recorder is not importable, following
    // `python_flow_dap_test.rs`: the recorder is an optional sibling toolchain.
    // The Noir cases above are the unconditional ones, so a skip here cannot
    // leave the collector untested.
    let Some(recorder) = test_harness::find_python_recorder() else {
        eprintln!("SKIPPED: `codetracer_python_recorder` is not importable from the active interpreter");
        return;
    };
    let Some((python, _version)) = test_harness::find_suitable_python() else {
        eprintln!("SKIPPED: no Python 3.10+ interpreter for the recorder");
        return;
    };
    assert!(
        recorder.exists() || recorder.to_str() == Some(test_harness::RUST_PYTHON_RECORDER_MODULE_SENTINEL),
        "the recorder is either an importable module or a file: {}",
        recorder.display()
    );

    let root = std::env::temp_dir().join(format!("rv4-python-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let repo = root.join("repo");
    let recordings = root.join("recordings");
    let recording = recordings.join("py-1");
    std::fs::create_dir_all(&repo).expect("mkdir repo");
    std::fs::create_dir_all(&recording).expect("mkdir recording");

    run("git", &["init", "-q"], &repo);
    run("git", &["config", "user.email", "rv4@test"], &repo);
    run("git", &["config", "user.name", "rv4"], &repo);
    std::fs::write(repo.join("prog.py"), PYTHON_OLD_SOURCE).expect("write old source");
    run("git", &["add", "-A"], &repo);
    run("git", &["commit", "-qm", "base"], &repo);
    std::fs::write(repo.join("prog.py"), PYTHON_NEW_SOURCE).expect("write new source");
    run("git", &["add", "-A"], &repo);
    run("git", &["commit", "-qm", "change"], &repo);

    let output = Command::new(&python)
        .args([
            "-m",
            "codetracer_python_recorder",
            "--out-dir",
            recording.to_str().expect("utf8"),
            repo.join("prog.py").to_str().expect("utf8"),
        ])
        .current_dir(&recording)
        .env("CODETRACER_TRACE_FORMAT", "ctfs")
        .output()
        .expect("run the Python recorder");
    assert!(
        output.status.success(),
        "the Python recorder failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // The arm this case exists for: a CTFS container, not a legacy sidecar.
    assert!(
        std::fs::read_dir(&recording)
            .expect("read the recording")
            .filter_map(|entry| entry.ok())
            .any(|entry| entry.path().extension().is_some_and(|ext| ext == "ct")),
        "the Python recorder wrote no *.ct container into {}",
        recording.display()
    );

    let out_dir = root.join("out");
    let args = ReviewCollectArgs {
        repo: Some(repo.clone()),
        diff_spec: Some("HEAD~..HEAD".to_string()),
        recordings: recordings.clone(),
        output: out_dir.clone(),
        progress: false,
        ..ReviewCollectArgs::default()
    };
    let report = db_backend::deepreview::cli::run(&args).expect("collection");
    assert_eq!(report.recordings_collected, 1);
    let text = std::fs::read_to_string(out_dir.join("review.json")).expect("review.json");
    let data: DeepReviewData = serde_json::from_str(&text).expect("review.json is the dataset shape");

    assert_eq!(data.files.len(), 1);
    let file = &data.files[0];
    assert_eq!(file.path, "prog.py");
    assert_eq!(file.diff.status, "M");

    // Coverage is the program's own: `scale`'s two body lines run once per
    // loop iteration, the `for` header runs five times (four iterations plus
    // the exit test), and the call site runs four times.
    let count_for = |line: u32| -> u32 {
        file.coverage
            .iter()
            .find(|entry| entry.line == line)
            .map(|entry| entry.execution_count)
            .unwrap_or_else(|| panic!("no coverage for line {line}: {:?}", file.coverage))
    };
    assert_eq!(count_for(2), 4, "scaled = i * x");
    assert_eq!(count_for(3), 4, "return scaled");
    assert_eq!(count_for(7), 1, "total = 0");
    assert_eq!(count_for(8), 5, "for header");
    assert_eq!(count_for(9), 4, "the changed line, calling scale");
    assert_eq!(count_for(10), 4, "total = total + contribution");
    for entry in &file.coverage {
        assert!(entry.executed, "only executed lines are reported: {entry:?}");
        assert!(!entry.unreachable, "a trace cannot say a line is unreachable");
    }

    // Flow for the function the diff changed, with the values the debugger
    // would annotate the line with.
    let main_flow = file
        .flow
        .iter()
        .find(|flow| flow.function_key == "main")
        .expect("flow for main");
    let contributions: Vec<String> = main_flow
        .steps
        .iter()
        .filter(|step| step.line == 9)
        .filter_map(|step| step.values.iter().find(|value| value.name == "contribution"))
        .map(|value| value.value.clone())
        .collect();
    assert_eq!(contributions, vec!["0", "5", "10", "15"], "i * 5 for i in 0..4");

    // RV-4 deliverable 4, items 1 and 8, in Python: no invented metadata, and
    // the helper the diff only CALLS has a real call count and no flow.
    for symbol in &file.symbols {
        assert_eq!(symbol.type_desc, "", "{}", symbol.name);
        assert_eq!(symbol.visibility, "", "{}", symbol.name);
    }
    let scale = file
        .functions
        .iter()
        .find(|function| function.name == "scale")
        .expect("scale is in the dataset");
    assert_eq!(scale.call_count, 4);
    assert_eq!(scale.execution_count, 0, "a called-but-unchanged function gets no flow");
    assert_eq!(scale.start_line, 1);
    // The bounds pass: a function that gets no flow still knows where it ends,
    // rather than reporting line 0 as if it were a measurement.
    assert_eq!(scale.end_line, 3);
    assert!(!file.flow.iter().any(|flow| flow.function_key == "scale"));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn the_flow_budget_bounds_a_hot_function() {
    let fixture = build_fixture("budget");
    let patch = "\
diff --git a/src/main.nr b/src/main.nr
--- a/src/main.nr
+++ b/src/main.nr
@@ -4,2 +4,2 @@
-        sum = sum + x;
+        let contribution = (i as Field) * x;
+        sum = sum + contribution;
";
    let mut options = CollectOptions {
        recordings: discover_recordings(&fixture.recordings).expect("discovery"),
        diff: parse_unified_diff(patch),
        repo_root: Some(fixture.repo.clone()),
        progress: false,
        max_flows_per_function: 0,
        ..CollectOptions::default()
    };
    let (bounded, _) = collect(&options).expect("collection");
    assert!(bounded.files[0].flow.is_empty(), "a zero budget collects no flow");
    // …and the coverage is unaffected, because coverage costs no replay.
    assert!(!bounded.files[0].coverage.is_empty());

    options.max_flows_per_function = 16;
    let (full, _) = collect(&options).expect("collection");
    assert_eq!(full.files[0].flow.len(), 1);
}
