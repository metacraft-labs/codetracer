//! `replay-server review-collect` — the materialized half of
//! `ct review collect`.
//!
//! `ct` (Nim) can only reach a collector as a subprocess, and RV-3's dispatch
//! chooses this one by inspecting the recordings
//! (`src/ct/review_cli.nim::routeReviewCollect`).  The flag set is therefore
//! deliberately the *same* as the one `ct review collect` accepts and the same
//! one the native collector's hidden `review-data collect` group accepts —
//! `--repo` / `--diff` / `--diff-file` / `--recordings` / `--output` /
//! `--preset` / `--progress` — so ct's translation is a rename of the verb and
//! nothing else, and so a user who reads `CLI-Reference.md` gets the same
//! answers whichever collector runs.
//!
//! One documented difference, and it is a fix rather than a divergence:
//! `--repo` + `--diff` work here on a stock build.  The native collector reads
//! a repository only when it was compiled with its optional `git2-support`
//! Cargo feature (RV-1 judgement call 4), so its CI templates were rewritten
//! to generate a patch and pass `--diff-file`.  This collector shells out to
//! `git`, which is already a hard requirement of `ct record --with-diff`.

use std::error::Error;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::materialized_source::is_materialized_recording;

use super::collector::{CollectOptions, CollectReport, collect};
use super::unified_diff::parse_unified_diff;

/// The file `ct review <DIR>` opens.  Mirrored on the ct side by
/// `review_cli.ReviewDatasetJsonName`.
pub const REVIEW_JSON_NAME: &str = "review.json";

/// Parsed `review-collect` arguments.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ReviewCollectArgs {
    pub repo: Option<PathBuf>,
    pub diff_spec: Option<String>,
    pub diff_file: Option<PathBuf>,
    pub recordings: PathBuf,
    pub output: PathBuf,
    /// Accepted and recorded so the flag is not silently dropped; see
    /// [`apply_preset`] for what each one changes.
    pub preset: Option<String>,
    pub progress: bool,
    pub session_title: Option<String>,
}

/// Collection detail levels, matching the native collector's names.
///
/// The knob a materialized collection actually has is how much flow it keeps:
/// coverage is exhaustive and costs nothing extra, flow is a replay per
/// function execution.  A preset that changed nothing would be a lie, and one
/// that dropped coverage would make the review useless, so the presets scale
/// the flow budget and the value-rendering cap.
pub fn apply_preset(options: &mut CollectOptions, preset: &str) -> Result<(), Box<dyn Error>> {
    match preset {
        "minimal" => {
            options.max_flows_per_function = 1;
            options.max_call_nodes = 2_000;
            options.max_value_chars = 64;
        }
        "default" => {}
        "comprehensive" => {
            options.max_flows_per_function = 128;
            options.max_call_nodes = 200_000;
            options.max_value_chars = 1_024;
        }
        other => {
            return Err(format!("unknown --preset '{other}': expected default, minimal or comprehensive").into());
        }
    }
    Ok(())
}

/// Recording directories inside `dir`, sorted, excluding anything that is not
/// a materialized recording.
///
/// Sorted so a dataset collected twice from the same directory has its
/// recordings in the same order on every filesystem — the trace-context list
/// the GUI shows is built from it.
pub fn discover_recordings(dir: &Path) -> Result<Vec<PathBuf>, Box<dyn Error>> {
    if !dir.is_dir() {
        return Err(format!("no recordings directory at '{}'", dir.display()).into());
    }
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.is_dir() && is_materialized_recording(path))
        .collect();
    // A `--recordings` pointed straight at one recording is a natural thing to
    // type and costs nothing to accept.
    if found.is_empty() && is_materialized_recording(dir) {
        found.push(dir.to_path_buf());
    }
    found.sort();
    Ok(found)
}

/// Run `git` inside `repo` and return its stdout, or an error naming the
/// command that failed.
fn git(repo: &Path, args: &[&str]) -> Result<String, Box<dyn Error>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(|e| format!("could not run git: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "git {} failed in {}: {}",
            args.join(" "),
            repo.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Resolve a `BASE..HEAD` spec into the two commit SHAs it names.
///
/// Failure is not fatal: a review whose commit SHAs are unknown is still a
/// review, and the dataset says so by carrying empty strings rather than a run
/// of zeros.
fn resolve_commits(repo: &Path, spec: &str) -> (String, String) {
    let (base, head) = match spec.split_once("..") {
        Some((base, head)) => (base, if head.is_empty() { "HEAD" } else { head }),
        None => (spec, "HEAD"),
    };
    let resolve = |rev: &str| {
        git(repo, &["rev-parse", rev])
            .map(|text| text.trim().to_string())
            .unwrap_or_default()
    };
    (resolve(head), resolve(base))
}

/// The patch a collection is over, and whatever commit identity came with it.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DiffSource {
    /// Unified diff text.
    pub patch: String,
    /// Repository root the patch's relative paths are against, when known.
    pub repo_root: Option<PathBuf>,
    /// Commit the review is of, or `""`.
    pub commit_sha: String,
    /// Commit the review is against, or `""`.
    pub base_commit_sha: String,
}

/// Read the patch a collection is over.
fn read_diff(args: &ReviewCollectArgs) -> Result<DiffSource, Box<dyn Error>> {
    if let Some(path) = &args.diff_file {
        let patch = std::fs::read_to_string(path)
            .map_err(|e| format!("could not read --diff-file '{}': {e}", path.display()))?;
        // A patch file names no commits, so the dataset carries none.  The
        // repository is still useful when one was given, because the patch's
        // paths are relative to it.
        return Ok(DiffSource {
            patch,
            repo_root: args.repo.clone(),
            ..DiffSource::default()
        });
    }
    let (Some(repo), Some(spec)) = (&args.repo, &args.diff_spec) else {
        return Err("a diff is required: pass --repo <DIR> with --diff <BASE..HEAD>, or --diff-file <PATH>".into());
    };
    let root = git(repo, &["rev-parse", "--show-toplevel"])
        .map(|text| PathBuf::from(text.trim()))
        .unwrap_or_else(|_| repo.clone());
    let patch = git(repo, &["diff", spec])?;
    let (commit_sha, base_commit_sha) = resolve_commits(repo, spec);
    Ok(DiffSource {
        patch,
        repo_root: Some(root),
        commit_sha,
        base_commit_sha,
    })
}

/// Execute a `review-collect` run: collect, then write `<output>/review.json`.
///
/// Writing the JSON here rather than in a separate export step is the same
/// property RV-1 established for the native path: one command in, one command
/// out, and `ct review <the same DIR>` opens what was just produced.
pub fn run(args: &ReviewCollectArgs) -> Result<CollectReport, Box<dyn Error>> {
    let recordings = discover_recordings(&args.recordings)?;
    if recordings.is_empty() {
        return Err(format!(
            "no materialized recordings in '{}': a recording is a directory holding a *.ct container, \
             a trace.json or a trace.bin",
            args.recordings.display()
        )
        .into());
    }

    let source = read_diff(args)?;
    let diff = parse_unified_diff(&source.patch);
    if diff.files.is_empty() {
        return Err("the diff is empty: there is nothing to review".into());
    }

    let mut options = CollectOptions {
        recordings,
        diff,
        repo_root: source.repo_root,
        commit_sha: source.commit_sha,
        base_commit_sha: source.base_commit_sha,
        session_title: args.session_title.clone().unwrap_or_default(),
        progress: args.progress,
        ..CollectOptions::default()
    };
    if let Some(preset) = &args.preset {
        apply_preset(&mut options, preset)?;
    }

    let (data, report) = collect(&options)?;
    if report.recordings_collected == 0 {
        let detail = report
            .recordings_failed
            .iter()
            .map(|(path, error)| format!("\n    {}: {error}", path.display()))
            .collect::<String>();
        return Err(format!(
            "none of the {} recordings in '{}' could be read, so no dataset was written:{detail}",
            report.recordings_failed.len(),
            args.recordings.display()
        )
        .into());
    }

    std::fs::create_dir_all(&args.output)?;
    let json_path = args.output.join(REVIEW_JSON_NAME);
    let text = serde_json::to_string_pretty(&data)?;
    std::fs::write(&json_path, text)?;

    println!(
        "DeepReview collect complete: {} recordings collected, {} files, {} with coverage, {} function executions",
        report.recordings_collected, report.files_in_diff, report.files_with_coverage, report.flow_executions
    );
    for (path, error) in &report.recordings_failed {
        eprintln!("warning: skipped recording '{}': {error}", path.display());
    }
    if report.call_tree_truncated {
        eprintln!("warning: the call tree was truncated at the node budget; raise it with --preset comprehensive");
    }
    println!("Review dataset ready: {}", json_path.display());
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_scale_the_flow_budget_and_nothing_silently() {
        let mut minimal = CollectOptions::default();
        apply_preset(&mut minimal, "minimal").expect("minimal");
        let mut default = CollectOptions::default();
        apply_preset(&mut default, "default").expect("default");
        let mut comprehensive = CollectOptions::default();
        apply_preset(&mut comprehensive, "comprehensive").expect("comprehensive");

        assert!(minimal.max_flows_per_function < default.max_flows_per_function);
        assert!(default.max_flows_per_function < comprehensive.max_flows_per_function);
        assert!(minimal.max_value_chars < comprehensive.max_value_chars);
    }

    #[test]
    fn an_unknown_preset_is_refused_by_name() {
        let mut options = CollectOptions::default();
        let error = apply_preset(&mut options, "thorough").expect_err("must refuse");
        let text = error.to_string();
        assert!(text.contains("thorough"), "{text}");
        assert!(text.contains("comprehensive"), "{text}");
    }

    #[test]
    fn a_diff_needs_a_repo_and_a_spec_or_a_patch_file() {
        let error = read_diff(&ReviewCollectArgs::default()).expect_err("must refuse");
        assert!(error.to_string().contains("--diff-file"), "{error}");
    }
}
