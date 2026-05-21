#![cfg(all(target_os = "macos", target_arch = "aarch64"))]

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};
use serde_json::Value;

mod test_harness;

type TestError = Box<dyn std::error::Error + Send + Sync>;

const FIXTURE_DIR: &str = "test-programs/reprobuild_hcr_mcr_dap";
const STABLE_LINE_MARKER: &str = "CODETRACER_DAP_STABLE_POST_HCR_LINE";

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

fn require_env_path(var_name: &str) -> Result<PathBuf, TestError> {
    let value = std::env::var(var_name)
        .map_err(|_| format!("{var_name} must be set for the Reprobuild HCR + MCR + DAP test"))?;
    let path = PathBuf::from(value);
    if !path.exists() {
        return Err(format!("{var_name} does not exist: {}", path.display()).into());
    }
    Ok(path)
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join(name))
            .find(|candidate| candidate.is_file())
    })
}

fn require_command(name: &str) -> Result<PathBuf, TestError> {
    find_on_path(name).ok_or_else(|| format!("{name} must be available on PATH").into())
}

fn require_ct_native_replay() -> Result<PathBuf, TestError> {
    for var_name in [
        "CT_NATIVE_REPLAY_BIN",
        "CT_NATIVE_REPLAY_PATH",
        "CODETRACER_CT_NATIVE_REPLAY_CMD",
    ] {
        if let Ok(value) = std::env::var(var_name) {
            let path = PathBuf::from(value);
            if path.is_file() {
                return Ok(path);
            }
            return Err(format!("{var_name} is set but is not a file: {}", path.display()).into());
        }
    }

    require_command("ct-native-replay")
}

fn require_ct_mcr() -> Result<PathBuf, TestError> {
    if let Ok(value) = std::env::var("CODETRACER_CT_MCR_CMD") {
        let path = PathBuf::from(value);
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!("CODETRACER_CT_MCR_CMD is set but is not a file: {}", path.display()).into());
    }

    find_on_path("ct-mcr")
        .or_else(|| find_on_path("ct_cli"))
        .ok_or_else(|| "ct-mcr must be available through CODETRACER_CT_MCR_CMD or PATH".into())
}

fn copy_dir_filtered(src: &Path, dst: &Path) -> Result<(), TestError> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let file_name = entry.file_name();
        let file_name_str = file_name.to_string_lossy();
        if matches!(
            file_name_str.as_ref(),
            ".git" | ".direnv" | "build" | "result" | "bench-results"
        ) {
            continue;
        }

        let source_path = entry.path();
        let target_path = dst.join(&file_name);
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_filtered(&source_path, &target_path)?;
        } else if file_type.is_file() {
            fs::copy(&source_path, &target_path)?;
        } else if file_type.is_symlink() {
            let link_target = fs::read_link(&source_path)?;
            std::os::unix::fs::symlink(link_target, target_path)?;
        }
    }
    Ok(())
}

fn run_command<I, S>(program: &Path, args: I, cwd: &Path) -> Result<Output, TestError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = Command::new(program).args(args).current_dir(cwd).output()?;
    Ok(output)
}

fn require_success(output: Output, context: &str) -> Result<(), TestError> {
    if output.status.success() {
        return Ok(());
    }

    Err(format!(
        "{context} failed with status {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
    .into())
}

fn find_marker_line(path: &Path, marker: &str) -> Result<usize, TestError> {
    let text = fs::read_to_string(path)?;
    for (index, line) in text.lines().enumerate() {
        if line.contains(marker) {
            return Ok(index + 1);
        }
    }
    Err(format!("marker {marker:?} not found in {}", path.display()).into())
}

fn parse_hcr_output(path: &Path) -> Result<Value, TestError> {
    let text = fs::read_to_string(path)?;
    let value: Value = serde_json::from_str(text.trim())?;
    Ok(value)
}

fn assert_json_i64(value: &Value, field: &str, expected: i64) {
    assert_eq!(
        value.get(field).and_then(Value::as_i64),
        Some(expected),
        "{field} should be {expected} in HCR output: {value}"
    );
}

#[test]
fn reprobuild_hcr_binary_records_with_mcr_and_exposes_dap_flow_values() -> Result<(), TestError> {
    let repro = require_command("repro")?;
    let ct_native_replay = require_ct_native_replay()?;
    let ct_mcr = require_ct_mcr()?;
    let reprobuild_source_root = require_env_path("REPROBUILD_SOURCE_ROOT")?;
    let db_backend = find_db_backend();

    assert!(
        db_backend.is_file(),
        "replay-server test binary is unavailable at {}",
        db_backend.display()
    );

    println!("repro: {}", repro.display());
    println!("ct-native-replay: {}", ct_native_replay.display());
    println!("ct-mcr: {}", ct_mcr.display());
    println!("REPROBUILD_SOURCE_ROOT: {}", reprobuild_source_root.display());
    println!("db-backend: {}", db_backend.display());

    let temp_dir = tempfile::tempdir()?;
    let project_dir = temp_dir.path().join("project");
    let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_DIR);
    copy_dir_filtered(&fixture_dir, &project_dir)?;

    let writable_reprobuild_source = temp_dir.path().join("reprobuild-source");
    copy_dir_filtered(&reprobuild_source_root, &writable_reprobuild_source)?;

    let repro_output = Command::new(&repro)
        .args([
            "build",
            project_dir.to_str().unwrap(),
            "--tool-provisioning=path",
            "--progress=none",
            "--log=actions",
        ])
        .env("REPROBUILD_SOURCE_ROOT", &writable_reprobuild_source)
        .current_dir(&project_dir)
        .output()?;
    require_success(repro_output, "repro build")?;

    let binary_path = project_dir.join("build/hcr_target");
    assert!(
        binary_path.is_file(),
        "repro build did not produce {}",
        binary_path.display()
    );

    let hcr_output_path = project_dir.join("build/hcr-output.json");
    let hcr_output = parse_hcr_output(&hcr_output_path)?;
    assert_eq!(
        hcr_output.get("schemaId").and_then(Value::as_str),
        Some("codetracer.reprobuild-hcr-mcr-dap/v1"),
        "unexpected HCR output schema: {hcr_output}"
    );
    assert_json_i64(&hcr_output, "before", 11);
    assert_json_i64(&hcr_output, "after", 77);
    assert_eq!(
        hcr_output.get("sharedLibraryPositivePath").and_then(Value::as_bool),
        Some(false),
        "M3 fixture must use the direct HCR target, not shared-library fallback: {hcr_output}"
    );
    assert!(
        hcr_output.get("patchPlan").is_some() && hcr_output.get("evidence").is_some(),
        "HCR output must include patch plan and transaction evidence: {hcr_output}"
    );

    let trace_base = temp_dir.path().join("trace");
    let record_output = run_command(
        &ct_native_replay,
        [
            OsStr::new("record"),
            OsStr::new("--backend"),
            OsStr::new("mcr"),
            OsStr::new("-o"),
            trace_base.as_os_str(),
            binary_path.as_os_str(),
        ],
        &project_dir,
    )?;
    require_success(record_output, "ct-native-replay record --backend mcr")?;

    let trace_ct = trace_base.with_extension("ct");
    assert!(
        trace_ct.is_file(),
        "MCR recording did not produce {}",
        trace_ct.display()
    );

    let source_path = fs::canonicalize(project_dir.join("hcr_target.nim"))?;
    let breakpoint_line = find_marker_line(&source_path, STABLE_LINE_MARKER)?;
    let mut expected_values = HashMap::new();
    expected_values.insert("before".to_string(), 11);
    expected_values.insert("after".to_string(), 77);

    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: vec!["before".to_string(), "after".to_string()],
        excluded_identifiers: vec![
            "target.callOriginalPointer".to_string(),
            "applyPatchTransaction".to_string(),
        ],
        expected_values,
    };

    let mut runner = FlowTestRunner::new(&db_backend, &trace_ct)?;
    runner.run_and_verify_dap_variables(&config)?;
    runner.finish()?;

    Ok(())
}
