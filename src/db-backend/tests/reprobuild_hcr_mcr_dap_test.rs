#![cfg(all(target_os = "macos", target_arch = "aarch64"))]

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use ct_dap_client::client::DapStdioClient;
use ct_dap_client::test_support::{FlowData, FlowTestRunner};
use ct_dap_client::types::MoveState;
use serde_json::Value;

mod test_harness;

type TestError = Box<dyn std::error::Error + Send + Sync>;

const FIXTURE_DIR: &str = "test-programs/reprobuild_hcr_mcr_dap";
const PRE_HCR_LINE_MARKER: &str = "CODETRACER_DAP_STABLE_PRE_HCR_LINE";
const STABLE_LINE_MARKER: &str = "CODETRACER_DAP_STABLE_POST_HCR_LINE";
const STEP_START_LINE_MARKER: &str = "CODETRACER_DAP_STEP_START_LINE";
const STEP_NEXT_LINE_MARKER: &str = "CODETRACER_DAP_STEP_NEXT_LINE";

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_replay-server"))
}

fn codetracer_repo_root() -> Result<PathBuf, TestError> {
    Ok(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize()?)
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

fn require_reprobuild_source_root() -> Result<PathBuf, TestError> {
    let sibling = codetracer_repo_root()?.join("../reprobuild").canonicalize();
    if let Ok(path) = sibling
        && path.join("libs/repro_hcr_agent").is_dir()
    {
        return Ok(path);
    }

    for var_name in ["CODETRACER_REPROBUILD_REPO_PATH", "REPROBUILD_SOURCE_ROOT"] {
        if let Ok(value) = std::env::var(var_name) {
            let path = PathBuf::from(value);
            if path.join("libs/repro_hcr_agent").is_dir() {
                return Ok(path);
            }
            return Err(format!("{var_name} must point at a Reprobuild source tree: {}", path.display()).into());
        }
    }

    Err("Reprobuild source checkout is required as a workspace sibling or explicit environment override".into())
}

fn require_repro(reprobuild_source_root: &Path) -> Result<PathBuf, TestError> {
    if let Ok(value) = std::env::var("REPROBUILD_REPRO_BIN") {
        let path = PathBuf::from(value);
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!("REPROBUILD_REPRO_BIN is set but is not a file: {}", path.display()).into());
    }

    let sibling_build = reprobuild_source_root.join("build/bin/repro");
    if sibling_build.is_file() {
        return Ok(sibling_build);
    }

    require_command("repro")
}

fn clingo_lib_dir() -> Result<PathBuf, TestError> {
    if let Ok(path) = std::env::var("CODETRACER_CLINGO_LIB_DIR") {
        let dir = PathBuf::from(path);
        if dir.join("libclingo.dylib").is_file() {
            return Ok(dir);
        }
        return Err(format!(
            "CODETRACER_CLINGO_LIB_DIR does not contain libclingo.dylib: {}",
            dir.display()
        )
        .into());
    }

    if let Some(dir) = std::env::var_os("DYLD_LIBRARY_PATH")
        .into_iter()
        .flat_map(|paths| std::env::split_paths(&paths).collect::<Vec<_>>())
        .find(|dir| dir.join("libclingo.dylib").is_file())
    {
        return Ok(dir);
    }

    let output = Command::new("nix")
        .args(["build", "--no-link", "--print-out-paths", "nixpkgs#clingo"])
        .output()
        .map_err(|e| format!("failed to resolve nixpkgs#clingo for repro/libclingo: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "nixpkgs#clingo resolution failed with status {}\nstdout:\n{}\nstderr:\n{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )
        .into());
    }
    let store_path = String::from_utf8(output.stdout)?
        .lines()
        .last()
        .ok_or("nixpkgs#clingo produced no store path")?
        .trim()
        .to_string();
    let dir = PathBuf::from(store_path).join("lib");
    if dir.join("libclingo.dylib").is_file() {
        Ok(dir)
    } else {
        Err(format!(
            "nixpkgs#clingo lib dir does not contain libclingo.dylib: {}",
            dir.display()
        )
        .into())
    }
}

fn shell_quote_path(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\\''"))
}

fn monitor_shim_lib(reprobuild_source_root: &Path) -> Result<PathBuf, TestError> {
    if let Ok(path) = std::env::var("REPRO_MONITOR_SHIM_LIB") {
        let shim = PathBuf::from(path);
        if shim.is_file() {
            return Ok(shim);
        }
        return Err(format!("REPRO_MONITOR_SHIM_LIB is set but is not a file: {}", shim.display()).into());
    }

    let candidate = reprobuild_source_root
        .join("build/lib/librepro_monitor_shim.dylib")
        .canonicalize();
    if let Ok(path) = candidate
        && path.is_file()
    {
        return Ok(path);
    }

    let workspace_candidate = codetracer_repo_root()?
        .join("../io-mon/build/lib/librepro_monitor_shim.dylib")
        .canonicalize();
    if let Ok(path) = workspace_candidate
        && path.is_file()
    {
        return Ok(path);
    }

    Err(format!(
        "librepro_monitor_shim.dylib is required; checked REPRO_MONITOR_SHIM_LIB, {}, and workspace io-mon",
        reprobuild_source_root
            .join("build/lib/librepro_monitor_shim.dylib")
            .display()
    )
    .into())
}

fn repro_test_adapters_src(reprobuild_source_root: &Path) -> Result<PathBuf, TestError> {
    if let Ok(path) = std::env::var("REPRO_TEST_ADAPTERS_SRC") {
        let src = PathBuf::from(path);
        if src.join("repro_test_adapters/test_runner.nim").is_file() {
            return Ok(src);
        }
        return Err(format!(
            "REPRO_TEST_ADAPTERS_SRC does not contain repro_test_adapters/test_runner.nim: {}",
            src.display()
        )
        .into());
    }

    let candidate_roots = [
        codetracer_repo_root()?.join("../reprobuild-test-adapters/src"),
        reprobuild_source_root
            .parent()
            .ok_or("Reprobuild source root has no parent directory")?
            .join("reprobuild-test-adapters/src"),
    ];
    for src in candidate_roots {
        if src.join("repro_test_adapters/test_runner.nim").is_file() {
            return Ok(src.canonicalize()?);
        }
    }
    Err(format!(
        "reprobuild-test-adapters source package is required; checked workspace sibling and sibling of {}",
        reprobuild_source_root.display()
    )
    .into())
}

fn write_repro_wrapper(temp_root: &Path, repro: &Path, reprobuild_source_root: &Path) -> Result<PathBuf, TestError> {
    let clingo_lib = clingo_lib_dir()?;
    let test_adapters_src = repro_test_adapters_src(reprobuild_source_root)?;
    let shim = monitor_shim_lib(reprobuild_source_root)?;
    let wrapper = temp_root.join("repro-with-clingo");
    let body = format!(
        "#!/bin/sh\nexport DYLD_LIBRARY_PATH={}${{DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}}\nexport REPRO_TEST_ADAPTERS_SRC={}\nexport REPRO_MONITOR_SHIM_LIB={}\nexec {} \"$@\"\n",
        shell_quote_path(&clingo_lib),
        shell_quote_path(&test_adapters_src),
        shell_quote_path(&shim),
        shell_quote_path(repro)
    );
    fs::write(&wrapper, body)?;
    let mut perms = fs::metadata(&wrapper)?.permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&wrapper, perms)?;
    Ok(wrapper)
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

    let sibling = codetracer_repo_root()?
        .join("../codetracer-native-backend/target/debug/ct-native-replay")
        .canonicalize();
    if let Ok(path) = sibling
        && path.is_file()
    {
        return Ok(path);
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

    let sibling = codetracer_repo_root()?
        .join("../codetracer-native-recorder/ct_cli/ct_cli")
        .canonicalize();
    if let Ok(path) = sibling
        && path.is_file()
    {
        return Ok(path);
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

fn command_output_text(program: &Path, args: &[&str], cwd: &Path) -> String {
    match Command::new(program).args(args).current_dir(cwd).output() {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            if output.status.success() {
                if stdout.is_empty() { stderr } else { stdout }
            } else {
                format!("unavailable (status {}; stderr: {stderr})", output.status)
            }
        }
        Err(e) => format!("unavailable ({e})"),
    }
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

fn parse_dap_int(value: &Value) -> Option<i64> {
    FlowData::extract_int_value(value).or_else(|| {
        let text = value.to_string();
        let trimmed = text.trim().trim_matches('"');
        if let Ok(parsed) = trimmed.parse::<i64>() {
            return Some(parsed);
        }

        let start = trimmed.char_indices().find_map(|(index, ch)| {
            if ch == '-' || ch.is_ascii_digit() {
                Some(index)
            } else {
                None
            }
        })?;
        let end = trimmed[start..]
            .char_indices()
            .find_map(|(offset, ch)| {
                if offset > 0 && !ch.is_ascii_digit() {
                    Some(start + offset)
                } else {
                    None
                }
            })
            .unwrap_or(trimmed.len());
        trimmed[start..end].parse::<i64>().ok()
    })
}

fn normalize_dap_source_name(name: &str) -> String {
    if let Some((base, suffix)) = name.rsplit_once("_p")
        && !base.is_empty()
        && suffix.chars().all(|ch| ch.is_ascii_digit())
    {
        return base.to_string();
    }

    let Some((base, suffix)) = name.rsplit_once('_') else {
        return name.to_string();
    };
    if !base.is_empty() && suffix.chars().all(|ch| ch.is_ascii_digit()) {
        base.to_string()
    } else {
        name.to_string()
    }
}

fn dap_locals(client: &mut DapStdioClient) -> Result<HashMap<String, Value>, TestError> {
    let locals = client.load_locals()?;
    let local_list = locals
        .get("locals")
        .and_then(Value::as_array)
        .ok_or("ct/load-locals response did not contain a locals array")?;

    let mut values = HashMap::new();
    for local in local_list {
        let Some(name) = local.get("expression").and_then(Value::as_str) else {
            continue;
        };
        let value = local.get("value").cloned().unwrap_or(Value::Null);
        values.insert(name.to_string(), value.clone());
        values.entry(normalize_dap_source_name(name)).or_insert(value);
    }
    Ok(values)
}

fn assert_dap_variables(client: &mut DapStdioClient, context: &str, expected: &[(&str, i64)]) -> Result<(), TestError> {
    let values = dap_locals(client)?;
    for (name, expected_value) in expected {
        let actual = values.get(*name).ok_or_else(|| {
            format!(
                "{context}: DAP variables did not include expected variable {name:?}; got {:?}",
                values.keys().collect::<Vec<_>>()
            )
        })?;
        let actual_int = parse_dap_int(actual)
            .ok_or_else(|| format!("{context}: DAP variable {name:?} value {actual:?} was not an integer"))?;
        if actual_int != *expected_value {
            return Err(format!(
                "{context}: DAP variable {name:?} value mismatch: expected {expected_value}, got {actual_int} ({actual:?})"
            )
            .into());
        }
    }
    println!("{context}: verified DAP locals {expected:?}");
    Ok(())
}

fn assert_stop_line(move_state: &MoveState, expected_line: usize, context: &str) -> Result<(), TestError> {
    let actual_line = move_state.location.line;
    if actual_line != expected_line as i64 {
        return Err(format!(
            "{context}: expected DAP stop at line {expected_line}, got line {actual_line} ({:?})",
            move_state.location
        )
        .into());
    }
    println!(
        "{context}: stopped at {}:{} ticks={}",
        move_state.location.path, move_state.location.line, move_state.location.rr_ticks.0
    );
    Ok(())
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
    let reprobuild_source_root = require_reprobuild_source_root()?;
    let repro = require_repro(&reprobuild_source_root)?;
    let ct_native_replay = require_ct_native_replay()?;
    let ct_mcr = require_ct_mcr()?;
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
    println!(
        "host: os={} arch={} uname={}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        command_output_text(Path::new("/usr/bin/uname"), &["-a"], Path::new("/"))
    );
    let temp_dir = tempfile::tempdir()?;
    let repro_wrapper = write_repro_wrapper(temp_dir.path(), &repro, &reprobuild_source_root)?;
    let project_dir = temp_dir.path().join("project");
    let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_DIR);
    copy_dir_filtered(&fixture_dir, &project_dir)?;

    let writable_reprobuild_source = temp_dir.path().join("reprobuild-source");
    copy_dir_filtered(&reprobuild_source_root, &writable_reprobuild_source)?;

    println!(
        "repro revision/capabilities: {}",
        command_output_text(&repro_wrapper, &["--version"], &reprobuild_source_root)
    );

    let repro_output = Command::new(&repro_wrapper)
        .args([
            "build",
            project_dir.to_str().unwrap(),
            "--daemon=off",
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
    assert_json_i64(&hcr_output, "preHcrAnchorState", 22);
    assert_json_i64(&hcr_output, "postHcrAnchorState", 88);
    assert_json_i64(&hcr_output, "stepAnchorState", 80);
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
    let record_output = Command::new(&ct_native_replay)
        .args([
            OsStr::new("record"),
            OsStr::new("--backend"),
            OsStr::new("mcr"),
            OsStr::new("-o"),
            trace_base.as_os_str(),
            binary_path.as_os_str(),
        ])
        .env("CODETRACER_CT_MCR_CMD", &ct_mcr)
        .current_dir(&project_dir)
        .output()?;
    require_success(record_output, "ct-native-replay record --backend mcr")?;

    let trace_ct = trace_base.with_extension("ct");
    assert!(
        trace_ct.is_file(),
        "MCR recording did not produce {}",
        trace_ct.display()
    );
    println!("MCR trace: {}", trace_ct.display());

    let source_path = fs::canonicalize(project_dir.join("hcr_target.nim"))?;
    let source_file = source_path.to_str().unwrap().to_string();
    let pre_hcr_line = find_marker_line(&source_path, PRE_HCR_LINE_MARKER)?;
    let post_hcr_line = find_marker_line(&source_path, STABLE_LINE_MARKER)?;
    let step_start_line = find_marker_line(&source_path, STEP_START_LINE_MARKER)?;
    let step_next_line = find_marker_line(&source_path, STEP_NEXT_LINE_MARKER)?;
    println!(
        "DAP anchors: pre_hcr_line={pre_hcr_line}, post_hcr_line={post_hcr_line}, step_start_line={step_start_line}, step_next_line={step_next_line}"
    );

    let ct_native_replay_env = ct_native_replay.to_string_lossy().to_string();
    let ct_mcr_env = ct_mcr.to_string_lossy().to_string();
    let dap_envs = [
        ("CT_NATIVE_REPLAY_BIN", ct_native_replay_env.as_str()),
        ("CODETRACER_CT_MCR_CMD", ct_mcr_env.as_str()),
    ];

    let mut runner = FlowTestRunner::new_with_envs(&db_backend, &trace_ct, &dap_envs)?;
    runner
        .client()
        .set_breakpoints(&source_file, &[pre_hcr_line, post_hcr_line])?;

    let pre_stop = runner.client().dap_continue()?;
    assert_stop_line(&pre_stop, pre_hcr_line, "pre-HCR")?;
    assert_dap_variables(runner.client(), "pre-HCR", &[("before", 11), ("expectedBefore", 11)])?;

    let post_stop = runner.client().dap_continue()?;
    assert_stop_line(&post_stop, post_hcr_line, "post-HCR")?;
    assert!(
        post_stop.location.line != pre_stop.location.line,
        "post-HCR stop should be distinct from pre-HCR stop in the MCR trace: pre={:?}, post={:?}",
        pre_stop.location,
        post_stop.location
    );
    assert_dap_variables(runner.client(), "post-HCR", &[("before", 11), ("after", 77)])?;

    let reverse_stop = runner.client().dap_reverse_continue()?;
    assert_stop_line(&reverse_stop, pre_hcr_line, "reverse-to-pre-HCR")?;
    assert!(
        reverse_stop.location.line != post_stop.location.line,
        "reverse navigation should move away from the post-HCR stop: reverse={:?}, post={:?}",
        reverse_stop.location,
        post_stop.location
    );
    runner.finish()?;

    let mut stepping_runner = FlowTestRunner::new_with_envs(&db_backend, &trace_ct, &dap_envs)?;
    stepping_runner
        .client()
        .set_breakpoints(&source_file, &[step_start_line, step_next_line])?;
    let step_start = stepping_runner.client().dap_continue()?;
    assert_stop_line(&step_start, step_start_line, "step-start")?;
    let step_next = stepping_runner.client().dap_step("next")?;
    assert_stop_line(&step_next, step_next_line, "step-next")?;
    assert!(
        step_next.location.line != step_start.location.line,
        "DAP next should advance to a different source line in the MCR trace: start={:?}, next={:?}",
        step_start.location,
        step_next.location
    );
    stepping_runner.finish()?;

    Ok(())
}
