#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
#[test]
fn reprobuild_hcr_in_codetracer_unsupported_platform_profile() {
    eprintln!(
        "SKIPPED: reprobuild_hcr_in_codetracer requires the macOS arm64 direct-HCR support profile; got {} {}",
        std::env::consts::OS,
        std::env::consts::ARCH
    );
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
mod macos_arm64_gate {
    use std::collections::{BTreeSet, HashMap};
    use std::ffi::OsStr;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::time::Duration;

    use ct_dap_client::client::{DapStdioClient, scaled};
    use ct_dap_client::test_support::FlowData;
    use ct_dap_client::types::MoveState;
    use ct_dap_client::types::launch::LaunchRequestArguments;
    use serde_json::{Value, json};

    type TestError = Box<dyn std::error::Error + Send + Sync>;

    const FIXTURE_DIR: &str = "test-programs/reprobuild_hcr_in_codetracer";
    const SUPPORT_PROFILE: &str = "macos-arm64-direct-hcr-in-codetracer-v1";
    const EVIDENCE_SCHEMA: &str = "codetracer.reprobuild-hcr-in-codetracer.evidence.v1";
    const PATCHABLE_FUNCTION: &str = "reprobuild_hcr_patchable_value";

    const GEN0_BREAKPOINT_MARKER: &str = "REPROBUILD_HCR_GEN0_BREAKPOINT";
    const GEN0_STEP_START_MARKER: &str = "REPROBUILD_HCR_GEN0_STEP_START";
    const GEN0_STEP_NEXT_MARKER: &str = "REPROBUILD_HCR_GEN0_STEP_NEXT";
    const GEN1_BREAKPOINT_MARKER: &str = "REPROBUILD_HCR_GEN1_BREAKPOINT";
    const GEN1_STEP_START_MARKER: &str = "REPROBUILD_HCR_GEN1_STEP_START";
    const GEN1_STEP_NEXT_MARKER: &str = "REPROBUILD_HCR_GEN1_STEP_NEXT";
    const REPLAY_AGENT_SOCKET: &str = "/tmp/codetracer-reprobuild-hcr-replay.sock";

    const FORBIDDEN_FIXTURE_SHORTCUTS: &[&str] = &[
        "applyPatchTransaction",
        "directPatchPlanFromBytes",
        "patchTransactionFromPlan",
        "initMinimalAarch64Target",
        "repro_hcr_test",
        "stdin-pipe",
        "dlopen",
        "dlsym",
        "LoadLibrary",
        "GetProcAddress",
        "REPRO_HCR_AGENT_MCR_COMPAT",
        "REPROBUILD_HCR_MCR_COMPAT",
        "MCR_COMPAT_PRELOAD",
        "dispatchSlot",
        "codeSlot",
        "mcrCodeSlot",
        "hcr_slot",
        "reprobuild_hcr_generation_id",
        "patchable_gen1_preload",
    ];

    const REQUIRED_REPROBUILD_PROFILE_REQUIRES: &[&str] = &[
        "hcr-agent-protocol",
        "coordinator-agent-negotiation",
        "direct-patch-injection",
        "debug-object-payloads",
        "unwind-metadata-payloads",
        "source-generation-metadata",
        "codetracer-owned-launch",
        "mcr-recorded-agent-ipc",
    ];

    const REQUIRED_DEBUGGER_MECHANISMS: &[&str] = &[
        "Debugger-Integration.md#1-gdb-jit-interface",
        "Debugger-Integration.md#2-lldb-jit-support",
        "Debugger-Integration.md#4-add-symbol-file-and-targetsource-map",
        "Debugger-Integration.md#5-stack-unwinding-eh_frame-registration",
        "Debugger-Integration.md#8-normative-specification",
    ];

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

    fn require_reprobuild_source_root() -> Result<PathBuf, TestError> {
        for var_name in ["CODETRACER_REPROBUILD_REPO_PATH", "REPROBUILD_SOURCE_ROOT"] {
            if let Ok(value) = std::env::var(var_name) {
                let path = PathBuf::from(value);
                if path.join("libs/repro_hcr_agent").is_dir() {
                    return Ok(path);
                }
                return Err(format!("{var_name} must point at a Reprobuild source tree: {}", path.display()).into());
            }
        }

        let sibling = codetracer_repo_root()?.join("../reprobuild").canonicalize()?;
        if sibling.join("libs/repro_hcr_agent").is_dir() {
            return Ok(sibling);
        }
        Err("REPROBUILD_SOURCE_ROOT or CODETRACER_REPROBUILD_REPO_PATH must point at Reprobuild".into())
    }

    fn copy_dir_filtered(src: &Path, dst: &Path) -> Result<(), TestError> {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            let file_name = entry.file_name();
            let file_name_str = file_name.to_string_lossy();
            if matches!(file_name_str.as_ref(), ".git" | ".direnv" | "build" | "result") {
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

    fn read_json(path: &Path) -> Result<Value, TestError> {
        let text = fs::read_to_string(path)?;
        Ok(serde_json::from_str(&text)?)
    }

    fn command_json(program: &Path, args: &[&str], cwd: &Path, context: &str) -> Result<Value, TestError> {
        let output = Command::new(program).args(args).current_dir(cwd).output()?;
        if !output.status.success() {
            return Err(format!(
                "{context} failed with status {}\nstdout:\n{}\nstderr:\n{}",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
            .into());
        }
        Ok(serde_json::from_slice(&output.stdout)?)
    }

    fn line_for_marker(path: &Path, marker: &str) -> Result<usize, TestError> {
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
        if let Some((base, suffix)) = name.rsplit_once("_p") {
            if !base.is_empty() && suffix.chars().all(|ch| ch.is_ascii_digit()) {
                return base.to_string();
            }
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

    fn require_local_int(locals: &HashMap<String, Value>, name: &str, context: &str) -> Result<i64, TestError> {
        let value = locals.get(name).ok_or_else(|| {
            format!(
                "{context}: DAP locals did not include {name:?}; got {:?}",
                locals.keys().collect::<Vec<_>>()
            )
        })?;
        parse_dap_int(value)
            .ok_or_else(|| format!("{context}: DAP local {name:?} value {value:?} was not an integer").into())
    }

    fn assert_stop_line_and_path(
        move_state: &MoveState,
        expected_line: usize,
        expected_path_suffix: &str,
        context: &str,
    ) -> Result<(), TestError> {
        let actual_line = move_state.location.line;
        if actual_line != expected_line as i64 {
            return Err(format!(
                "{context}: expected DAP stop at line {expected_line}, got line {actual_line} ({:?})",
                move_state.location
            )
            .into());
        }
        let normalized_path = move_state.location.path.replace('\\', "/");
        if !normalized_path.ends_with(expected_path_suffix) {
            return Err(format!(
                "{context}: expected DAP source path ending in {expected_path_suffix:?}, got {:?}",
                move_state.location.path
            )
            .into());
        }
        Ok(())
    }

    fn scan_fixture_file(path: &Path, violations: &mut Vec<String>) -> Result<(), TestError> {
        let text = fs::read_to_string(path)?;
        for forbidden in FORBIDDEN_FIXTURE_SHORTCUTS {
            if text.contains(forbidden) {
                violations.push(format!("{} contains forbidden shortcut {forbidden:?}", path.display()));
            }
        }
        Ok(())
    }

    fn scan_fixture_tree(path: &Path, violations: &mut Vec<String>) -> Result<(), TestError> {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let entry_path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                scan_fixture_tree(&entry_path, violations)?;
            } else if file_type.is_file() {
                let should_scan = entry_path
                    .extension()
                    .and_then(OsStr::to_str)
                    .map(|ext| matches!(ext, "c" | "h" | "nim" | "sh" | "md"))
                    .unwrap_or(false);
                if should_scan {
                    scan_fixture_file(&entry_path, violations)?;
                }
            }
        }
        Ok(())
    }

    fn assert_fixture_contract(project_dir: &Path) -> Result<(), TestError> {
        let mut violations = Vec::new();
        scan_fixture_tree(project_dir, &mut violations)?;
        if !violations.is_empty() {
            return Err(format!(
                "fixture violates accepted HCR gate boundaries:\n{}",
                violations.join("\n")
            )
            .into());
        }

        let gen0 = project_dir.join("src/patchable.c");
        let gen1 = project_dir.join("generations/patchable_gen1.c");
        for (path, marker) in [
            (&gen0, GEN0_BREAKPOINT_MARKER),
            (&gen0, GEN0_STEP_START_MARKER),
            (&gen0, GEN0_STEP_NEXT_MARKER),
            (&gen1, GEN1_BREAKPOINT_MARKER),
            (&gen1, GEN1_STEP_START_MARKER),
            (&gen1, GEN1_STEP_NEXT_MARKER),
        ] {
            let _ = line_for_marker(path, marker)?;
        }

        Ok(())
    }

    fn json_string_set(node: &Value, field: &str) -> BTreeSet<String> {
        node.get(field)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect()
    }

    fn require_reprobuild_full_hcr_profile(repro: &Path, reprobuild_root: &Path) -> Result<(), TestError> {
        let caps = command_json(repro, &["capabilities"], reprobuild_root, "repro capabilities")?;
        let profiles = caps
            .pointer("/interfaces/hcr/profiles")
            .and_then(Value::as_array)
            .ok_or("repro capabilities did not contain interfaces.hcr.profiles")?;

        let profile_ids = profiles
            .iter()
            .filter_map(|profile| profile.get("id").and_then(Value::as_str))
            .collect::<Vec<_>>();
        let profile = profiles
            .iter()
            .find(|profile| profile.get("id").and_then(Value::as_str) == Some(SUPPORT_PROFILE))
            .ok_or_else(|| {
                format!(
                    "Reprobuild does not advertise required HCR support profile {SUPPORT_PROFILE:?}. \
                     Current profiles: {profile_ids:?}. This is a hard failure for the \
                     Reprobuild HCR in CodeTracer gate, not a test skip."
                )
            })?;

        let status = profile.get("status").and_then(Value::as_str).unwrap_or("unknown");
        if matches!(status, "unsupported" | "unavailable" | "planned") {
            let missing_components = json_string_set(profile, "missingComponents");
            return Err(format!(
                "Reprobuild profile {SUPPORT_PROFILE} is not runnable: status={status}; missingComponents={missing_components:?}"
            )
            .into());
        }

        let advertised = json_string_set(profile, "requires")
            .union(&json_string_set(profile, "features"))
            .cloned()
            .collect::<BTreeSet<_>>();
        for required in REQUIRED_REPROBUILD_PROFILE_REQUIRES {
            if !advertised.contains(*required) {
                return Err(format!(
                    "Reprobuild profile {SUPPORT_PROFILE} is missing required production capability {required:?}; advertised={advertised:?}"
                )
                .into());
            }
        }
        Ok(())
    }

    fn run_codetracer_hcr_gate_driver(
        project_dir: &Path,
        binary_path: &Path,
        artifacts_dir: &Path,
        repro: &Path,
        ct_native_replay: &Path,
        ct_mcr: &Path,
        db_backend: &Path,
        reprobuild_source_root: &Path,
    ) -> Result<(), TestError> {
        fs::create_dir_all(artifacts_dir)?;
        let ct = require_command("ct")?;
        let edit_driver = project_dir.join("edit-driver.sh");
        let output = Command::new(&ct)
            .args([
                OsStr::new("test"),
                OsStr::new("e2e"),
                OsStr::new("reprobuild-hcr-in-codetracer"),
                OsStr::new("--project"),
                project_dir.as_os_str(),
                OsStr::new("--target"),
                OsStr::new("hcr-target"),
                OsStr::new("--binary"),
                binary_path.as_os_str(),
                OsStr::new("--source-edit-driver"),
                edit_driver.as_os_str(),
                OsStr::new("--artifacts"),
                artifacts_dir.as_os_str(),
            ])
            .env("REPROBUILD_SOURCE_ROOT", reprobuild_source_root)
            .env("CODETRACER_REPROBUILD_REPO_PATH", reprobuild_source_root)
            .env("CODETRACER_REPROBUILD_REPRO", repro)
            .env("CT_NATIVE_REPLAY_PATH", ct_native_replay)
            .env("CT_NATIVE_REPLAY_BIN", ct_native_replay)
            .env("CODETRACER_CT_NATIVE_REPLAY_CMD", ct_native_replay)
            .env("CODETRACER_CT_MCR_CMD", ct_mcr)
            .env("CODETRACER_DB_BACKEND", db_backend)
            .current_dir(project_dir)
            .output()?;
        require_success(output, "ct test e2e reprobuild-hcr-in-codetracer")
    }

    fn require_object<'a>(node: &'a Value, pointer: &str) -> Result<&'a Value, TestError> {
        let value = node
            .pointer(pointer)
            .ok_or_else(|| format!("evidence missing {pointer}"))?;
        if !value.is_object() {
            return Err(format!("evidence {pointer} must be an object; got {value}").into());
        }
        Ok(value)
    }

    fn require_array<'a>(node: &'a Value, pointer: &str) -> Result<&'a Vec<Value>, TestError> {
        node.pointer(pointer)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("evidence {pointer} must be an array"))
            .map_err(Into::into)
    }

    fn require_nonempty_str<'a>(node: &'a Value, pointer: &str) -> Result<&'a str, TestError> {
        let value = node
            .pointer(pointer)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("evidence {pointer} must be a string"))?;
        if value.is_empty() {
            return Err(format!("evidence {pointer} must be non-empty").into());
        }
        Ok(value)
    }

    fn assert_bool(node: &Value, pointer: &str, expected: bool) -> Result<(), TestError> {
        let actual = node
            .pointer(pointer)
            .and_then(Value::as_bool)
            .ok_or_else(|| format!("evidence {pointer} must be a bool"))?;
        if actual != expected {
            return Err(format!("evidence {pointer} expected {expected}, got {actual}").into());
        }
        Ok(())
    }

    fn require_i64(node: &Value, pointer: &str) -> Result<i64, TestError> {
        node.pointer(pointer)
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("evidence {pointer} must be an integer").into())
    }

    fn assert_str(node: &Value, pointer: &str, expected: &str) -> Result<(), TestError> {
        let actual = node
            .pointer(pointer)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("evidence {pointer} must be a string"))?;
        if actual != expected {
            return Err(format!("evidence {pointer} expected {expected:?}, got {actual:?}").into());
        }
        Ok(())
    }

    fn assert_array_contains(node: &Value, pointer: &str, expected: &str) -> Result<(), TestError> {
        let values = require_array(node, pointer)?;
        if values.iter().any(|value| value.as_str() == Some(expected)) {
            return Ok(());
        }
        Err(format!("evidence {pointer} must contain {expected:?}; got {values:?}").into())
    }

    fn assert_artifact_exists(artifacts_dir: &Path, node: &Value, pointer: &str) -> Result<PathBuf, TestError> {
        let raw = require_nonempty_str(node, pointer)?;
        let path = PathBuf::from(raw);
        let path = if path.is_absolute() {
            path
        } else {
            artifacts_dir.join(path)
        };
        if !path.exists() {
            return Err(format!("evidence artifact {pointer} does not exist: {}", path.display()).into());
        }
        Ok(path)
    }

    fn launch_replay_dap(
        db_backend: &Path,
        trace: &Path,
        ct_native_replay: &Path,
        ct_mcr: &Path,
    ) -> Result<DapStdioClient, TestError> {
        let ct_native_replay_env = ct_native_replay.to_string_lossy().into_owned();
        let ct_mcr_env = ct_mcr.to_string_lossy().into_owned();
        let envs = [
            ("CODETRACER_CT_NATIVE_REPLAY_CMD", ct_native_replay_env.as_str()),
            ("CT_NATIVE_REPLAY_BIN", ct_native_replay_env.as_str()),
            ("CODETRACER_CT_MCR_CMD", ct_mcr_env.as_str()),
            ("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", "60"),
            ("REPRO_HCR_AGENT_SOCKET", REPLAY_AGENT_SOCKET),
            ("RB_HCR_FIXTURE_ITERATIONS", "900"),
        ];
        let mut client = DapStdioClient::spawn_with_envs(db_backend, &envs)?;
        client.initialize()?;
        client.launch(LaunchRequestArguments {
            trace_folder: Some(trace.to_path_buf()),
            ct_rr_worker_exe: Some(ct_native_replay.to_path_buf()),
            ..Default::default()
        })?;
        client.configuration_done()?;
        client.wait_for_stopped(scaled(Duration::from_secs(20)))?;
        Ok(client)
    }

    fn local_values_json(locals: &HashMap<String, Value>) -> Value {
        let mut object = serde_json::Map::new();
        for (name, value) in locals {
            if let Some(parsed) = parse_dap_int(value) {
                object.insert(name.clone(), json!(parsed));
            }
        }
        Value::Object(object)
    }

    fn stack_json(client: &mut DapStdioClient) -> Result<Value, TestError> {
        let stack = client.stack_trace()?;
        Ok(Value::Array(
            stack
                .stack_frames
                .into_iter()
                .map(|frame| {
                    json!({
                        "function": frame.name,
                        "line": frame.line,
                        "source": frame.source.and_then(|source| source.path)
                    })
                })
                .collect(),
        ))
    }

    fn stop_evidence(
        client: &mut DapStdioClient,
        move_state: &MoveState,
        logical_function: &str,
        line_marker: &str,
        source_generation: i64,
    ) -> Result<Value, TestError> {
        let locals = dap_locals(client)?;
        let _ = require_local_int(&locals, "iteration", line_marker)?;
        Ok(json!({
            "sourceLevel": true,
            "disassemblyFallback": false,
            "function": logical_function,
            "dapFunction": move_state.location.function_name,
            "lineMarker": line_marker,
            "sourceGeneration": source_generation,
            "path": move_state.location.path,
            "line": move_state.location.line,
            "locals": local_values_json(&locals),
            "callStack": stack_json(client)?
        }))
    }

    fn step_evidence(
        start: &MoveState,
        next: &MoveState,
        start_marker: &str,
        next_marker: &str,
        generation: i64,
    ) -> Value {
        json!({
            "sourceLevel": true,
            "staysInSourceGeneration": true,
            "sourceGeneration": generation,
            "startLineMarker": start_marker,
            "nextLineMarker": next_marker,
            "startPath": start.location.path,
            "startLine": start.location.line,
            "nextPath": next.location.path,
            "nextLine": next.location.line
        })
    }

    fn run_real_replay_dap_assertions(
        artifacts_dir: &Path,
        project_dir: &Path,
        db_backend: &Path,
        ct_native_replay: &Path,
        ct_mcr: &Path,
    ) -> Result<(), TestError> {
        let evidence_path = artifacts_dir.join("reprobuild-hcr-in-codetracer-evidence.json");
        let mut evidence = read_json(&evidence_path)?;
        let trace = assert_artifact_exists(artifacts_dir, &evidence, "/artifacts/mcrTrace")?;
        let replay_dap_transcript = assert_artifact_exists(artifacts_dir, &evidence, "/artifacts/replayDapTranscript")?;

        let edited_source = project_dir.join("src/patchable.c");
        let old_source_file = edited_source.to_string_lossy().into_owned();
        let new_source_file = edited_source.to_string_lossy().into_owned();
        let old_path_suffix = "/src/patchable.c";
        let new_path_suffix = "/src/patchable.c";
        let old_breakpoint_line = line_for_marker(
            &artifacts_dir.join("source-generation0-patchable.c"),
            GEN0_BREAKPOINT_MARKER,
        )?;
        let old_step_start_line = line_for_marker(
            &artifacts_dir.join("source-generation0-patchable.c"),
            GEN0_STEP_START_MARKER,
        )?;
        let old_step_next_line = line_for_marker(
            &artifacts_dir.join("source-generation0-patchable.c"),
            GEN0_STEP_NEXT_MARKER,
        )?;
        let new_breakpoint_line = line_for_marker(
            &artifacts_dir.join("source-generation1-patchable.c"),
            GEN1_BREAKPOINT_MARKER,
        )?;
        let new_step_start_line = line_for_marker(
            &artifacts_dir.join("source-generation1-patchable.c"),
            GEN1_STEP_START_MARKER,
        )?;
        let new_step_next_line = line_for_marker(
            &artifacts_dir.join("source-generation1-patchable.c"),
            GEN1_STEP_NEXT_MARKER,
        )?;

        let mut client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        client.set_breakpoints(&old_source_file, &[old_breakpoint_line])?;
        let old_stop = client.dap_continue()?;
        assert_stop_line_and_path(
            &old_stop,
            old_breakpoint_line,
            old_path_suffix,
            "old-generation replay DAP",
        )?;
        let old_stop_evidence = stop_evidence(&mut client, &old_stop, PATCHABLE_FUNCTION, GEN0_BREAKPOINT_MARKER, 0)?;
        client.disconnect()?;

        let mut client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        client.set_breakpoints(&new_source_file, &[new_breakpoint_line])?;
        let new_stop = client.dap_continue()?;
        assert_stop_line_and_path(
            &new_stop,
            new_breakpoint_line,
            new_path_suffix,
            "new-generation replay DAP",
        )?;
        let new_stop_evidence = stop_evidence(&mut client, &new_stop, PATCHABLE_FUNCTION, GEN1_BREAKPOINT_MARKER, 1)?;
        client.set_breakpoints(&old_source_file, &[old_breakpoint_line])?;
        let reverse_stop = client.dap_reverse_continue()?;
        assert_stop_line_and_path(
            &reverse_stop,
            old_breakpoint_line,
            old_path_suffix,
            "reverse replay DAP",
        )?;
        client.set_breakpoints(&old_source_file, &[])?;
        client.set_breakpoints(&new_source_file, &[new_breakpoint_line])?;
        let forward_stop = client.dap_continue()?;
        assert_stop_line_and_path(
            &forward_stop,
            new_breakpoint_line,
            new_path_suffix,
            "forward replay DAP",
        )?;
        client.disconnect()?;

        let mut old_step_client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        old_step_client.set_breakpoints(&old_source_file, &[old_step_start_line])?;
        let old_step_start = old_step_client.dap_continue()?;
        assert_stop_line_and_path(
            &old_step_start,
            old_step_start_line,
            old_path_suffix,
            "old-generation replay DAP step start",
        )?;
        let old_step_next = old_step_client.dap_step("next")?;
        assert_stop_line_and_path(
            &old_step_next,
            old_step_next_line,
            old_path_suffix,
            "old-generation replay DAP step next",
        )?;
        old_step_client.disconnect()?;

        let mut new_step_client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        new_step_client.set_breakpoints(&new_source_file, &[new_step_start_line])?;
        let new_step_start = new_step_client.dap_continue()?;
        assert_stop_line_and_path(
            &new_step_start,
            new_step_start_line,
            new_path_suffix,
            "new-generation replay DAP step start",
        )?;
        let new_step_next = new_step_client.dap_step("next")?;
        assert_stop_line_and_path(
            &new_step_next,
            new_step_next_line,
            new_path_suffix,
            "new-generation replay DAP step next",
        )?;
        new_step_client.disconnect()?;

        let replay_evidence = json!({
            "evidenceSource": "replay-server-dap",
            "oldGenerationStop": old_stop_evidence,
            "newGenerationStop": new_stop_evidence,
            "oldGenerationStep": step_evidence(
                &old_step_start,
                &old_step_next,
                GEN0_STEP_START_MARKER,
                GEN0_STEP_NEXT_MARKER,
                0,
            ),
            "newGenerationStep": step_evidence(
                &new_step_start,
                &new_step_next,
                GEN1_STEP_START_MARKER,
                GEN1_STEP_NEXT_MARKER,
                1,
            ),
            "reverseAcrossPatchBoundary": {
                "sourceIdentityPreserved": true,
                "path": reverse_stop.location.path,
                "line": reverse_stop.location.line
            },
            "forwardAcrossPatchBoundary": {
                "sourceIdentityPreserved": true,
                "path": forward_stop.location.path,
                "line": forward_stop.location.line
            }
        });
        evidence["dap"]["replay"] = replay_evidence.clone();
        fs::write(&evidence_path, serde_json::to_string_pretty(&evidence)?)?;
        fs::write(
            replay_dap_transcript,
            serde_json::to_string_pretty(&json!({
                "schemaId": "codetracer.reprobuild-hcr-in-codetracer.dap-transcript.v1",
                "mode": "replay",
                "evidenceSource": "replay-server-dap",
                "trace": trace,
                "assertions": replay_evidence
            }))?,
        )?;
        Ok(())
    }

    fn assert_generation_stop(
        evidence: &Value,
        pointer: &str,
        generation: i64,
        line_marker: &str,
    ) -> Result<(), TestError> {
        let stop = require_object(evidence, pointer)?;
        assert_bool(stop, "/sourceLevel", true)?;
        assert_bool(stop, "/disassemblyFallback", false)?;
        assert_str(stop, "/function", PATCHABLE_FUNCTION)?;
        assert_str(stop, "/lineMarker", line_marker)?;

        let actual_generation = stop
            .pointer("/sourceGeneration")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("evidence {pointer}/sourceGeneration must be an integer"))?;
        if actual_generation != generation {
            return Err(format!("{pointer}: expected source generation {generation}, got {actual_generation}").into());
        }

        let locals = require_object(stop, "/locals")?;
        if locals.as_object().map(|obj| obj.is_empty()).unwrap_or(true) {
            return Err(format!("{pointer}: locals must not be empty").into());
        }

        let stack = require_array(stop, "/callStack")?;
        if stack.is_empty() {
            return Err(format!("{pointer}: callStack must contain at least one frame").into());
        }
        Ok(())
    }

    fn assert_generation_step(
        evidence: &Value,
        pointer: &str,
        generation: i64,
        start_marker: &str,
        next_marker: &str,
    ) -> Result<(), TestError> {
        let step = require_object(evidence, pointer)?;
        assert_bool(step, "/sourceLevel", true)?;
        assert_bool(step, "/staysInSourceGeneration", true)?;
        assert_str(step, "/startLineMarker", start_marker)?;
        assert_str(step, "/nextLineMarker", next_marker)?;
        let actual_generation = step
            .pointer("/sourceGeneration")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("evidence {pointer}/sourceGeneration must be an integer"))?;
        if actual_generation != generation {
            return Err(format!("{pointer}: expected source generation {generation}, got {actual_generation}").into());
        }
        Ok(())
    }

    fn assert_gate_evidence(artifacts_dir: &Path) -> Result<(), TestError> {
        let evidence_path = artifacts_dir.join("reprobuild-hcr-in-codetracer-evidence.json");
        let evidence = read_json(&evidence_path)?;
        assert_str(&evidence, "/schemaId", EVIDENCE_SCHEMA)?;
        assert_str(&evidence, "/supportProfile", SUPPORT_PROFILE)?;

        assert_str(&evidence, "/launch/owner", "CodeTracer")?;
        assert_bool(&evidence, "/launch/postLaunchAttach", false)?;
        assert_bool(&evidence, "/launch/recordingActiveBeforeUserCode", true)?;

        assert_bool(&evidence, "/protocol/coordinatorDiscoveredAgent", true)?;
        assert_bool(&evidence, "/protocol/capabilityNegotiation", true)?;
        assert_bool(&evidence, "/protocol/patchRequestSent", true)?;
        assert_bool(&evidence, "/protocol/patchAppliedResponse", true)?;
        assert_str(&evidence, "/protocol/transportScope", "hcr-agent-protocol")?;
        assert_array_contains(&evidence, "/protocol/lifecycleEvents", "hcr/patchApplied")?;
        for pointer in [
            "/protocol/patchId",
            "/protocol/debugObjectDigest",
            "/protocol/unwindMetadataDigest",
            "/protocol/sourceGenerationMapDigest",
        ] {
            let _ = require_nonempty_str(&evidence, pointer)?;
        }

        assert_bool(&evidence, "/watch/reproWatchDroveInitialBuild", true)?;
        assert_bool(&evidence, "/watch/reproWatchDroveRebuild", true)?;
        assert_bool(&evidence, "/watch/sourceEditDriverRanOutsideReproWatch", true)?;
        assert_bool(&evidence, "/watch/sourceEditObservedByFilesystemWatcher", true)?;
        assert_str(&evidence, "/patch/mode", "direct")?;
        assert_bool(&evidence, "/patch/sharedLibraryPositivePath", false)?;
        assert_bool(&evidence, "/patch/inFixtureDirectTransactionCall", false)?;
        assert_bool(&evidence, "/patch/preloadedCodeSlotUsed", false)?;
        assert_bool(&evidence, "/patch/fixtureExposesHcrSlots", false)?;
        assert_bool(&evidence, "/patch/directEntryPatchUsed", true)?;
        assert_array_contains(&evidence, "/patch/changedFunctions", PATCHABLE_FUNCTION)?;
        assert_bool(&evidence, "/patch/oldCodeRetained", true)?;
        assert_bool(&evidence, "/symbols/generation0Registered", true)?;
        assert_bool(&evidence, "/symbols/generation1Registered", true)?;
        assert_bool(&evidence, "/symbols/unwindMetadataRegistered", true)?;
        for mechanism in REQUIRED_DEBUGGER_MECHANISMS {
            assert_array_contains(&evidence, "/symbols/debuggerMechanisms", mechanism)?;
        }

        assert_bool(&evidence, "/mcr/recordedAgentProtocolBytes", true)?;
        assert_bool(&evidence, "/mcr/codePatchEventRecorded", true)?;
        assert_bool(&evidence, "/replay/nativeReplayPath", true)?;
        assert_bool(&evidence, "/replay/coordinatorResentPatches", false)?;
        assert_bool(&evidence, "/replay/patchReconstructedFromRecordedEffects", true)?;
        assert_bool(&evidence, "/replay/beforeAfterBehaviorMatchesLive", true)?;
        assert_bool(&evidence, "/behavior/valueChangedOnlyAfterPatch", true)?;
        let pre_patch_value = require_i64(&evidence, "/behavior/prePatchObservedValue")?;
        let post_patch_value = require_i64(&evidence, "/behavior/postPatchObservedValue")?;
        if pre_patch_value == post_patch_value {
            return Err("evidence behavior values must differ across the applied patch".into());
        }

        assert_str(&evidence, "/dap/live/evidenceSource", "not-collected-by-e2e-driver")?;
        assert_str(&evidence, "/dap/replay/evidenceSource", "replay-server-dap")?;
        assert_generation_stop(&evidence, "/dap/replay/oldGenerationStop", 0, GEN0_BREAKPOINT_MARKER)?;
        assert_generation_stop(&evidence, "/dap/replay/newGenerationStop", 1, GEN1_BREAKPOINT_MARKER)?;
        assert_generation_step(
            &evidence,
            "/dap/replay/oldGenerationStep",
            0,
            GEN0_STEP_START_MARKER,
            GEN0_STEP_NEXT_MARKER,
        )?;
        assert_generation_step(
            &evidence,
            "/dap/replay/newGenerationStep",
            1,
            GEN1_STEP_START_MARKER,
            GEN1_STEP_NEXT_MARKER,
        )?;
        assert_bool(
            &evidence,
            "/dap/replay/reverseAcrossPatchBoundary/sourceIdentityPreserved",
            true,
        )?;
        assert_bool(
            &evidence,
            "/dap/replay/forwardAcrossPatchBoundary/sourceIdentityPreserved",
            true,
        )?;

        let trace = assert_artifact_exists(artifacts_dir, &evidence, "/artifacts/mcrTrace")?;
        if trace.extension().and_then(OsStr::to_str) != Some("ct") {
            return Err(format!("MCR trace artifact must be a .ct file: {}", trace.display()).into());
        }
        for pointer in [
            "/artifacts/reprobuildBuildReport",
            "/artifacts/hcrCoordinatorReport",
            "/artifacts/agentProtocolTranscript",
            "/artifacts/patchBundleMetadata",
            "/artifacts/liveDapTranscript",
            "/artifacts/replayDapTranscript",
            "/artifacts/sourceGeneration0Snapshot",
            "/artifacts/sourceGeneration1Snapshot",
            "/artifacts/symbolRegistrationEvidence",
        ] {
            let _ = assert_artifact_exists(artifacts_dir, &evidence, pointer)?;
        }

        Ok(())
    }

    #[test]
    fn reprobuild_hcr_in_codetracer_uses_full_agent_protocol_and_source_generations() -> Result<(), TestError> {
        let repro = require_command("repro")?;
        let ct_native_replay = require_ct_native_replay()?;
        let ct_mcr = require_ct_mcr()?;
        let reprobuild_source_root = require_reprobuild_source_root()?;
        let db_backend = find_db_backend();
        if !db_backend.is_file() {
            return Err(format!("replay-server test binary is unavailable at {}", db_backend.display()).into());
        }

        let temp_dir = tempfile::tempdir()?;
        let temp_root = temp_dir.path().to_path_buf();
        if std::env::var_os("CODETRACER_REPROBUILD_HCR_KEEP_TEMP").is_some() {
            println!("preserving HCR test temp root: {}", temp_root.display());
            std::mem::forget(temp_dir);
        }
        let project_dir = temp_root.join("project");
        let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_DIR);
        copy_dir_filtered(&fixture_dir, &project_dir)?;
        assert_fixture_contract(&project_dir)?;

        require_reprobuild_full_hcr_profile(&repro, &reprobuild_source_root)?;

        let binary_path = project_dir.join("build/hcr_target");
        let artifacts_dir = temp_root.join("artifacts");
        run_codetracer_hcr_gate_driver(
            &project_dir,
            &binary_path,
            &artifacts_dir,
            &repro,
            &ct_native_replay,
            &ct_mcr,
            &db_backend,
            &reprobuild_source_root,
        )?;
        run_real_replay_dap_assertions(&artifacts_dir, &project_dir, &db_backend, &ct_native_replay, &ct_mcr)?;
        assert_gate_evidence(&artifacts_dir)?;

        Ok(())
    }
}
