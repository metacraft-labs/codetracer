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
    use std::fs::{self, File, OpenOptions};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Output, Stdio};
    use std::sync::{Arc, Mutex, mpsc};
    use std::thread;
    use std::time::{Duration, Instant};

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
        "write-hcr-fixture-metadata",
        "hcr-fixture-metadata",
        "REPROBUILD_REPRO_BIN",
        "REPROBUILD_HCR_PATCHABLE",
        "section(\"__HCR",
        "repro_hcr_agent_symbol",
        "&reprobuild_hcr_patchable_value",
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

    fn require_lldb() -> Result<PathBuf, TestError> {
        if let Ok(value) = std::env::var("CODETRACER_LLDB") {
            let path = PathBuf::from(value);
            if path.is_file() {
                return Ok(path);
            }
            return Err(format!("CODETRACER_LLDB is set but is not a file: {}", path.display()).into());
        }

        for path in [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb",
            "/Library/Developer/CommandLineTools/usr/bin/lldb",
        ] {
            let candidate = PathBuf::from(path);
            if candidate.is_file() {
                return Ok(candidate);
            }
        }

        require_command("lldb")
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

    fn copy_dir_all(src: &Path, dst: &Path) -> Result<(), TestError> {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            let source_path = entry.path();
            let target_path = dst.join(entry.file_name());
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                copy_dir_all(&source_path, &target_path)?;
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

    fn read_text(path: &Path) -> String {
        fs::read_to_string(path).unwrap_or_else(|_| String::new())
    }

    fn terminate_child(child: &mut Child) {
        if child.try_wait().ok().flatten().is_none() {
            let _ = child.kill();
        }
        let _ = child.wait();
    }

    fn wait_for_file_contains(path: &Path, needle: &str, timeout: Duration, context: &str) -> Result<(), TestError> {
        let deadline = Instant::now() + timeout;
        loop {
            let text = read_text(path);
            if text.contains(needle) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "timed out waiting for {context}: expected {needle:?} in {}\n--- log ---\n{}",
                    path.display(),
                    text
                )
                .into());
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    fn wait_for_file_contains_while_process(
        path: &Path,
        needle: &str,
        timeout: Duration,
        context: &str,
        child: &mut Child,
        child_name: &str,
    ) -> Result<(), TestError> {
        let deadline = Instant::now() + timeout;
        loop {
            let text = read_text(path);
            if text.contains(needle) {
                return Ok(());
            }
            if let Some(status) = child.try_wait()? {
                return Err(format!(
                    "{child_name} exited with {status} while waiting for {context}: expected {needle:?} in {}\n--- log ---\n{}",
                    path.display(),
                    text
                )
                .into());
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "timed out waiting for {context}: expected {needle:?} in {}\n--- log ---\n{}",
                    path.display(),
                    text
                )
                .into());
            }
            thread::sleep(Duration::from_millis(50));
        }
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
            "reprobuild-test-adapters source package is required for Reprobuild interface extraction; checked workspace sibling and sibling of {}",
            reprobuild_source_root.display()
        )
        .into())
    }

    fn write_repro_wrapper(
        temp_root: &Path,
        repro: &Path,
        reprobuild_source_root: &Path,
    ) -> Result<PathBuf, TestError> {
        let clingo_lib = clingo_lib_dir()?;
        let test_adapters_src = repro_test_adapters_src(reprobuild_source_root)?;
        let wrapper = temp_root.join("repro-with-clingo");
        let body = format!(
            "#!/bin/sh\nexport DYLD_LIBRARY_PATH={}{}${{DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}}\nexport REPRO_TEST_ADAPTERS_SRC={}\nexec {} \"$@\"\n",
            shell_quote_path(&clingo_lib),
            "",
            shell_quote_path(&test_adapters_src),
            shell_quote_path(repro)
        );
        fs::write(&wrapper, body)?;
        let mut perms = fs::metadata(&wrapper)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&wrapper, perms)?;
        Ok(wrapper)
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

    struct GateDriverConfig<'a> {
        project_dir: &'a Path,
        binary_path: &'a Path,
        artifacts_dir: &'a Path,
        repro: &'a Path,
        ct_native_replay: &'a Path,
        ct_mcr: &'a Path,
        db_backend: &'a Path,
        reprobuild_source_root: &'a Path,
    }

    fn run_codetracer_hcr_gate_driver(config: GateDriverConfig<'_>) -> Result<(), TestError> {
        fs::create_dir_all(config.artifacts_dir)?;
        let ct = require_command("ct")?;
        let edit_driver = config.project_dir.join("edit-driver.sh");
        let output = Command::new(&ct)
            .args([
                OsStr::new("test"),
                OsStr::new("e2e"),
                OsStr::new("reprobuild-hcr-in-codetracer"),
                OsStr::new("--project"),
                config.project_dir.as_os_str(),
                OsStr::new("--target"),
                OsStr::new("hcr-target"),
                OsStr::new("--binary"),
                config.binary_path.as_os_str(),
                OsStr::new("--source-edit-driver"),
                edit_driver.as_os_str(),
                OsStr::new("--artifacts"),
                config.artifacts_dir.as_os_str(),
            ])
            .env("REPROBUILD_SOURCE_ROOT", config.reprobuild_source_root)
            .env("CODETRACER_REPROBUILD_REPO_PATH", config.reprobuild_source_root)
            .env("CODETRACER_REPROBUILD_REPRO", config.repro)
            .env("CT_NATIVE_REPLAY_PATH", config.ct_native_replay)
            .env("CT_NATIVE_REPLAY_BIN", config.ct_native_replay)
            .env("CODETRACER_CT_NATIVE_REPLAY_CMD", config.ct_native_replay)
            .env("CODETRACER_CT_MCR_CMD", config.ct_mcr)
            .env("CODETRACER_DB_BACKEND", config.db_backend)
            .current_dir(config.project_dir)
            .output()?;
        require_success(output, "ct test e2e reprobuild-hcr-in-codetracer")
    }

    struct LiveDebugserver {
        child: Child,
        port: u16,
    }

    fn append_line(log: &Arc<Mutex<File>>, prefix: &str, line: &str) {
        if let Ok(mut file) = log.lock() {
            let _ = writeln!(file, "{prefix}{line}");
        }
    }

    // P7.4: this helper drives `ct-mcr debugserver` directly rather than
    // going through `ct` because the HCR repro-build test needs to wire
    // a custom socket / ready-file pair via env vars
    // (`REPRO_HCR_AGENT_SOCKET`, `RB_HCR_FIXTURE_READY_FILE`) and capture
    // raw stdout/stderr line-by-line for the live-debugserver assertion.
    // Routing through `ct` would add a wrapper process that owns stdio
    // and would not propagate the test-only env contract.  A slower
    // user-facing variant is tracked as the P7.4 slow-but-true-to-end-
    // user smoke variant follow-up.
    fn start_live_debugserver(
        ct_mcr: &Path,
        program: &Path,
        project_dir: &Path,
        socket_path: &Path,
        ready_file: &Path,
        log_path: &Path,
    ) -> Result<LiveDebugserver, TestError> {
        let mut child = Command::new(ct_mcr)
            .args([
                OsStr::new("debugserver"),
                OsStr::new("--port"),
                OsStr::new("0"),
                OsStr::new("--live-recording-dir"),
                log_path
                    .parent()
                    .ok_or("debugserver log path has no parent")?
                    .as_os_str(),
                OsStr::new("--program"),
            ])
            .arg(program)
            .env("REPRO_HCR_AGENT_SOCKET", socket_path)
            .env("RB_HCR_FIXTURE_READY_FILE", ready_file)
            .env("RB_HCR_FIXTURE_ITERATIONS", "1200")
            .current_dir(project_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        let stdout = child
            .stdout
            .take()
            .ok_or("failed to capture ct-mcr debugserver stdout")?;
        let stderr = child
            .stderr
            .take()
            .ok_or("failed to capture ct-mcr debugserver stderr")?;
        let log = Arc::new(Mutex::new(
            OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .open(log_path)?,
        ));
        let (port_sender, port_receiver) = mpsc::channel::<u16>();

        {
            let log = Arc::clone(&log);
            let port_sender = port_sender.clone();
            thread::spawn(move || {
                let reader = BufReader::new(stdout);
                for line in reader.lines() {
                    let line = match line {
                        Ok(line) => line,
                        Err(err) => {
                            append_line(&log, "stdout: ", &format!("read error: {err}"));
                            break;
                        }
                    };
                    if let Some(rest) = line.strip_prefix("Listening on :")
                        && let Ok(port) = rest.trim().parse::<u16>()
                    {
                        let _ = port_sender.send(port);
                    }
                    append_line(&log, "stdout: ", &line);
                }
            });
        }

        {
            let log = Arc::clone(&log);
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    match line {
                        Ok(line) => append_line(&log, "stderr: ", &line),
                        Err(err) => {
                            append_line(&log, "stderr: ", &format!("read error: {err}"));
                            break;
                        }
                    }
                }
            });
        }

        let port = match port_receiver.recv_timeout(scaled(Duration::from_secs(90))) {
            Ok(port) => port,
            Err(err) => {
                terminate_child(&mut child);
                return Err(format!(
                    "ct-mcr live debugserver did not report a port: {err}\n--- log ---\n{}",
                    read_text(log_path)
                )
                .into());
            }
        };

        Ok(LiveDebugserver { child, port })
    }

    fn lldb_string(value: &Path) -> String {
        serde_json::to_string(&value.to_string_lossy()).expect("path JSON string")
    }

    fn parse_prefixed_json_lines(text: &str, prefix: &str) -> Result<Vec<Value>, TestError> {
        let mut values = Vec::new();
        for line in text.lines() {
            let Some(raw) = line.strip_prefix(prefix) else {
                continue;
            };
            values.push(serde_json::from_str(raw.trim())?);
        }
        Ok(values)
    }

    fn live_event<'a>(events: &'a [Value], label: &str) -> Result<&'a Value, TestError> {
        events
            .iter()
            .find(|event| event.get("label").and_then(Value::as_str) == Some(label))
            .ok_or_else(|| format!("LLDB live transcript did not contain event {label:?}; got {events:?}").into())
    }

    fn live_event_line(event: &Value) -> Result<i64, TestError> {
        event
            .get("line")
            .and_then(Value::as_i64)
            .ok_or_else(|| format!("live event missing integer line: {event}").into())
    }

    fn assert_live_event_line(event: &Value, expected_line: usize, context: &str) -> Result<(), TestError> {
        let actual = live_event_line(event)?;
        if actual != expected_line as i64 {
            return Err(format!("{context}: expected LLDB stop at line {expected_line}, got {actual}: {event}").into());
        }
        let path = event.get("path").and_then(Value::as_str).unwrap_or_default();
        if !path.replace('\\', "/").ends_with("/src/patchable.c") {
            return Err(format!("{context}: expected source path ending in /src/patchable.c, got {path:?}").into());
        }
        Ok(())
    }

    fn lldb_live_probe_script() -> &'static str {
        r#"
import json
import subprocess
import threading
import time
import lldb

PREFIX = "CT_HCR_LIVE_JSON "
LOCAL_NAMES = [
    "iteration",
    "generation_zero_bias",
    "generation_one_bias",
    "step_state",
]

def _parse_value(raw):
    if raw is None:
        return None
    text = str(raw)
    try:
        return int(text, 0)
    except Exception:
        return text

def _parse_int_value(value):
    raw = value.GetValue() or value.GetSummary()
    if raw is None:
        return None
    text = str(raw).strip('"')
    try:
        return int(text, 0)
    except Exception:
        return None

def _selected_frame():
    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    if process.GetState() != lldb.eStateStopped:
        raise RuntimeError("process is not stopped; state=%s" % process.GetState())
    thread = process.GetSelectedThread()
    if not thread.IsValid() and process.GetNumThreads() > 0:
        thread = process.GetThreadAtIndex(0)
    if not thread.IsValid() or thread.GetNumFrames() == 0:
        raise RuntimeError("no selected frame")
    return process, thread, thread.GetSelectedFrame()

def _frame_path(frame):
    line_entry = frame.GetLineEntry()
    file_spec = line_entry.GetFileSpec()
    path = file_spec.fullpath
    if path:
        return path
    return str(file_spec)

def emit_stop(label):
    process, thread, frame = _selected_frame()
    line_entry = frame.GetLineEntry()
    pc = frame.GetPC()
    source_path = _frame_path(frame)
    source_line = line_entry.GetLine()
    function_name = frame.GetFunctionName() or frame.GetDisplayFunctionName()
    locals_by_name = {}
    for name in LOCAL_NAMES:
        value = frame.FindVariable(name)
        if value.IsValid():
            locals_by_name[name] = _parse_value(value.GetValue() or value.GetSummary())
    stack = []
    for index in range(min(thread.GetNumFrames(), 8)):
        stack_frame = thread.GetFrameAtIndex(index)
        stack_line = stack_frame.GetLineEntry()
        stack.append({
            "function": stack_frame.GetFunctionName() or stack_frame.GetDisplayFunctionName(),
            "path": _frame_path(stack_frame),
            "line": stack_line.GetLine(),
        })
    event = {
        "label": label,
        "function": function_name,
        "path": source_path,
        "line": source_line,
        "pc": pc,
        "stopReason": str(thread.GetStopReason()),
        "locals": locals_by_name,
        "callStack": stack,
    }
    print(PREFIX + json.dumps(event, sort_keys=True), flush=True)

def assert_latest_breakpoint_resolved(label):
    target = lldb.debugger.GetSelectedTarget()
    count = target.GetNumBreakpoints()
    if count == 0:
        raise RuntimeError("no breakpoint exists for %s" % label)
    breakpoint = target.GetBreakpointAtIndex(count - 1)
    if not breakpoint.IsValid() or breakpoint.GetNumLocations() == 0:
        raise RuntimeError("breakpoint for %s did not resolve to a location" % label)
    locations = []
    for index in range(breakpoint.GetNumLocations()):
        location = breakpoint.GetLocationAtIndex(index)
        load_address = location.GetAddress().GetLoadAddress(target)
        if load_address == lldb.LLDB_INVALID_ADDRESS or load_address < 0x1000:
            raise RuntimeError("breakpoint for %s resolved to invalid load address 0x%x" % (label, load_address))
        locations.append(load_address)
    print(PREFIX + json.dumps({
        "label": label,
        "breakpointId": breakpoint.GetID(),
        "locations": locations,
    }, sort_keys=True), flush=True)

def wait_for_log(path, needle, timeout_seconds):
    deadline = time.time() + float(timeout_seconds)
    while time.time() < deadline:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            if needle in text:
                print(PREFIX + json.dumps({
                    "label": "logObserved",
                    "path": path,
                    "needle": needle,
                }, sort_keys=True), flush=True)
                return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise RuntimeError("timed out waiting for %r in %s" % (needle, path))

def run_edit_driver(driver, project):
    completed = subprocess.run(
        [driver, project],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    event = {
        "label": "sourceEditDriver",
        "driver": driver,
        "project": project,
        "exitCode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }
    print(PREFIX + json.dumps(event, sort_keys=True), flush=True)
    if completed.returncode != 0:
        raise RuntimeError("source edit driver failed with exit code %s" % completed.returncode)

def run_edit_driver_after_delay(driver, project, delay_seconds):
    def worker():
        time.sleep(float(delay_seconds))
        run_edit_driver(driver, project)
    thread = threading.Thread(target=worker, name="hcr-edit-driver")
    thread.daemon = True
    thread.start()
    print(PREFIX + json.dumps({
        "label": "sourceEditDriverScheduled",
        "driver": driver,
        "project": project,
        "delaySeconds": float(delay_seconds),
    }, sort_keys=True), flush=True)
"#
    }

    struct LiveHcrLines {
        old_breakpoint: usize,
        old_step_start: usize,
        old_step_next: usize,
        new_breakpoint: usize,
        new_step_start: usize,
        new_step_next: usize,
    }

    struct LldbLiveHcrSession<'a> {
        lldb: &'a Path,
        live_binary: &'a Path,
        project_dir: &'a Path,
        edit_driver: &'a Path,
        port: u16,
        lines: LiveHcrLines,
        command_file: &'a Path,
        probe_file: &'a Path,
        output_log: &'a Path,
    }

    fn run_lldb_live_hcr_session(session: LldbLiveHcrSession<'_>) -> Result<Vec<Value>, TestError> {
        let LldbLiveHcrSession {
            lldb,
            live_binary,
            project_dir,
            edit_driver,
            port,
            lines,
            command_file,
            probe_file,
            output_log,
        } = session;
        let LiveHcrLines {
            old_breakpoint: old_breakpoint_line,
            old_step_start: old_step_start_line,
            old_step_next: old_step_next_line,
            new_breakpoint: new_breakpoint_line,
            new_step_start: new_step_start_line,
            new_step_next: new_step_next_line,
        } = lines;
        fs::write(probe_file, lldb_live_probe_script())?;
        let commands = format!(
            "\
settings set interpreter.prompt-on-quit false\n\
settings set stop-disassembly-display never\n\
settings set plugin.jit-loader.gdb.enable on\n\
command script import {probe_file}\n\
target create {live_binary}\n\
gdb-remote 127.0.0.1:{port}\n\
breakpoint set --file patchable.c --line {old_breakpoint_line}\n\
process continue\n\
script hcr_probe.emit_stop(\"oldGenerationStop\")\n\
breakpoint delete --force\n\
breakpoint set --file patchable.c --line {old_step_start_line}\n\
process continue\n\
script hcr_probe.emit_stop(\"oldGenerationStepStart\")\n\
breakpoint delete --force\n\
breakpoint set --file patchable.c --line {old_step_next_line}\n\
process continue\n\
script hcr_probe.emit_stop(\"oldGenerationStepNext\")\n\
breakpoint delete --force\n\
breakpoint set --name __jit_debug_register_code\n\
script hcr_probe.run_edit_driver_after_delay({edit_driver}, {project_dir}, 1.0)\n\
process continue\n\
script hcr_probe.emit_stop(\"hotCodeReloadHook\")\n\
breakpoint delete --force\n\
breakpoint set --file patchable.c --line {new_breakpoint_line}\n\
script hcr_probe.assert_latest_breakpoint_resolved(\"newGenerationBreakpointResolved\")\n\
process continue\n\
script hcr_probe.emit_stop(\"newGenerationStop\")\n\
breakpoint delete --force\n\
breakpoint set --file patchable.c --line {new_step_start_line}\n\
script hcr_probe.assert_latest_breakpoint_resolved(\"newGenerationStepStartResolved\")\n\
process continue\n\
script hcr_probe.emit_stop(\"newGenerationStepStart\")\n\
breakpoint delete --force\n\
breakpoint set --file patchable.c --line {new_step_next_line}\n\
script hcr_probe.assert_latest_breakpoint_resolved(\"newGenerationStepNextResolved\")\n\
process continue\n\
script hcr_probe.emit_stop(\"newGenerationStepNext\")\n\
breakpoint delete --force\n\
process detach\n\
quit\n",
            probe_file = lldb_string(probe_file),
            live_binary = lldb_string(live_binary),
            edit_driver = lldb_string(edit_driver),
            project_dir = lldb_string(project_dir),
            old_step_start_line = old_step_start_line,
            old_step_next_line = old_step_next_line,
            new_step_start_line = new_step_start_line,
            new_step_next_line = new_step_next_line,
        );
        fs::write(command_file, commands)?;

        let mut child = Command::new(lldb)
            .args([OsStr::new("-b"), OsStr::new("-s")])
            .arg(command_file)
            .current_dir(project_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let mut stdout_pipe = child.stdout.take().ok_or("failed to capture LLDB stdout")?;
        let mut stderr_pipe = child.stderr.take().ok_or("failed to capture LLDB stderr")?;
        let stdout_reader = thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = stdout_pipe.read_to_end(&mut buf);
            buf
        });
        let stderr_reader = thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = stderr_pipe.read_to_end(&mut buf);
            buf
        });

        let timeout = scaled(Duration::from_secs(120));
        let deadline = Instant::now() + timeout;
        let status = loop {
            if let Some(status) = child.try_wait()? {
                break status;
            }
            if Instant::now() >= deadline {
                terminate_child(&mut child);
                let stdout = String::from_utf8_lossy(&stdout_reader.join().unwrap_or_default()).into_owned();
                let stderr = String::from_utf8_lossy(&stderr_reader.join().unwrap_or_default()).into_owned();
                fs::write(
                    output_log,
                    format!(
                        "status: timed out after {:?}\n--- stdout ---\n{}\n--- stderr ---\n{}\n",
                        timeout, stdout, stderr
                    ),
                )?;
                return Err(format!(
                    "LLDB live HCR session timed out after {:?}\n--- output ---\n{}",
                    timeout,
                    read_text(output_log)
                )
                .into());
            }
            thread::sleep(Duration::from_millis(100));
        };

        let stdout = String::from_utf8_lossy(&stdout_reader.join().unwrap_or_default()).into_owned();
        let stderr = String::from_utf8_lossy(&stderr_reader.join().unwrap_or_default()).into_owned();
        fs::write(
            output_log,
            format!(
                "status: {}\n--- stdout ---\n{}\n--- stderr ---\n{}\n",
                status, stdout, stderr
            ),
        )?;
        if !status.success() {
            return Err(format!(
                "LLDB live HCR session failed with status {}\n--- output ---\n{}",
                status,
                read_text(output_log)
            )
            .into());
        }

        parse_prefixed_json_lines(&format!("{stdout}\n{stderr}"), "CT_HCR_LIVE_JSON ")
    }

    fn live_stop_evidence(event: &Value, line_marker: &str, source_generation: i64) -> Value {
        json!({
            "sourceLevel": true,
            "disassemblyFallback": false,
            "function": PATCHABLE_FUNCTION,
            "debuggerFunction": event.get("function").cloned().unwrap_or(Value::Null),
            "lineMarker": line_marker,
            "sourceGeneration": source_generation,
            "path": event.get("path").cloned().unwrap_or(Value::Null),
            "line": event.get("line").cloned().unwrap_or(Value::Null),
            "pc": event.get("pc").cloned().unwrap_or(Value::Null),
            "locals": event.get("locals").cloned().unwrap_or_else(|| json!({})),
            "callStack": event.get("callStack").cloned().unwrap_or_else(|| json!([])),
        })
    }

    fn live_step_evidence(
        start: &Value,
        next: &Value,
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
            "startPath": start.get("path").cloned().unwrap_or(Value::Null),
            "startLine": start.get("line").cloned().unwrap_or(Value::Null),
            "nextPath": next.get("path").cloned().unwrap_or(Value::Null),
            "nextLine": next.get("line").cloned().unwrap_or(Value::Null),
        })
    }

    fn run_real_live_debug_assertions(
        artifacts_dir: &Path,
        project_dir: &Path,
        binary_path: &Path,
        repro: &Path,
        ct_mcr: &Path,
        reprobuild_source_root: &Path,
    ) -> Result<(), TestError> {
        let lldb = require_lldb()?;
        let evidence_path = artifacts_dir.join("reprobuild-hcr-in-codetracer-evidence.json");
        let mut evidence = read_json(&evidence_path)?;
        let live_dap_transcript = assert_artifact_exists(artifacts_dir, &evidence, "/artifacts/liveDapTranscript")?;

        let source_path = project_dir.join("src/patchable.c");
        let gen0_snapshot = artifacts_dir.join("source-generation0-patchable.c");
        fs::copy(&gen0_snapshot, &source_path)?;

        let old_breakpoint_line = line_for_marker(&gen0_snapshot, GEN0_BREAKPOINT_MARKER)?;
        let old_step_start_line = line_for_marker(&gen0_snapshot, GEN0_STEP_START_MARKER)?;
        let old_step_next_line = line_for_marker(&gen0_snapshot, GEN0_STEP_NEXT_MARKER)?;
        let new_snapshot = artifacts_dir.join("source-generation1-patchable.c");
        let new_breakpoint_line = line_for_marker(&new_snapshot, GEN1_BREAKPOINT_MARKER)?;
        let new_step_start_line = line_for_marker(&new_snapshot, GEN1_STEP_START_MARKER)?;
        let new_step_next_line = line_for_marker(&new_snapshot, GEN1_STEP_NEXT_MARKER)?;

        let live_artifacts = artifacts_dir.join("live-debug");
        fs::create_dir_all(&live_artifacts)?;
        let socket_path = std::env::temp_dir().join(format!(
            "ct-hcr-live-{}-{}.sock",
            std::process::id(),
            Instant::now().elapsed().as_nanos()
        ));
        let _ = fs::remove_file(&socket_path);
        let coordinator_log = live_artifacts.join("repro-watch-live.log");
        let hcr_metadata = artifacts_dir.join("hcr-watch-metadata.json");
        let coordinator_out = File::create(&coordinator_log)?;
        let coordinator_err = coordinator_out.try_clone()?;
        let target_arg = format!("{}#hcr-target", project_dir.display());
        let hcr_socket_arg = format!("--hcr-agent-socket={}", socket_path.display());
        let hcr_artifacts_arg = format!("--hcr-artifacts={}", live_artifacts.display());
        let hcr_metadata_arg = format!("--hcr-metadata={}", hcr_metadata.display());
        let mut coordinator = Command::new(repro)
            .args([
                "watch",
                target_arg.as_str(),
                "--tool-provisioning=path",
                "--max-cycles=2",
                "--debounce-ms=100",
                hcr_socket_arg.as_str(),
                hcr_artifacts_arg.as_str(),
                hcr_metadata_arg.as_str(),
            ])
            .env("REPROBUILD_SOURCE_ROOT", reprobuild_source_root)
            .current_dir(project_dir)
            .stdout(Stdio::from(coordinator_out))
            .stderr(Stdio::from(coordinator_err))
            .spawn()?;

        let live_result = (|| -> Result<Value, TestError> {
            wait_for_file_contains_while_process(
                &coordinator_log,
                "repro watch: cycle 1 result exitCode=0",
                scaled(Duration::from_secs(20)),
                "live repro watch initial build",
                &mut coordinator,
                "repro watch",
            )?;

            let recorded_binary = artifacts_dir.join("recorded-hcr-target");
            let debug_binary_source = if recorded_binary.is_file() {
                recorded_binary
            } else {
                binary_path.to_path_buf()
            };
            let live_program_dir = live_artifacts.join("program");
            fs::create_dir_all(&live_program_dir)?;
            let live_binary = live_program_dir.join(
                debug_binary_source
                    .file_name()
                    .ok_or_else(|| format!("binary path has no file name: {}", debug_binary_source.display()))?,
            );
            fs::copy(&debug_binary_source, &live_binary)?;
            let dsym_src = debug_binary_source.with_extension("dSYM");
            if dsym_src.is_dir() {
                let dsym_dst = live_binary.with_extension("dSYM");
                if dsym_dst.exists() {
                    fs::remove_dir_all(&dsym_dst)?;
                }
                copy_dir_all(&dsym_src, &dsym_dst)?;
            }

            let debugserver_log = live_artifacts.join("ct-mcr-live-debugserver.log");
            let ready_file = live_artifacts.join("target-ready");
            let mut debugserver = start_live_debugserver(
                ct_mcr,
                &live_binary,
                project_dir,
                &socket_path,
                &ready_file,
                &debugserver_log,
            )?;

            let lldb_command_file = live_artifacts.join("live-hcr-lldb-commands.txt");
            let lldb_probe_file = live_artifacts.join("hcr_probe.py");
            let lldb_output_log = live_artifacts.join("live-lldb.log");
            let lldb_events = match run_lldb_live_hcr_session(LldbLiveHcrSession {
                lldb: &lldb,
                live_binary: &live_binary,
                project_dir,
                edit_driver: &project_dir.join("edit-driver.sh"),
                port: debugserver.port,
                lines: LiveHcrLines {
                    old_breakpoint: old_breakpoint_line,
                    old_step_start: old_step_start_line,
                    old_step_next: old_step_next_line,
                    new_breakpoint: new_breakpoint_line,
                    new_step_start: new_step_start_line,
                    new_step_next: new_step_next_line,
                },
                command_file: &lldb_command_file,
                probe_file: &lldb_probe_file,
                output_log: &lldb_output_log,
            }) {
                Ok(events) => events,
                Err(err) => {
                    terminate_child(&mut debugserver.child);
                    return Err(err);
                }
            };

            terminate_child(&mut debugserver.child);
            let status = coordinator.wait()?;
            if !status.success() {
                return Err(format!(
                    "live repro watch failed with status {status}\n--- log ---\n{}",
                    read_text(&coordinator_log)
                )
                .into());
            }
            wait_for_file_contains(
                &coordinator_log,
                "repro watch: cycle 2 result exitCode=0",
                scaled(Duration::from_secs(5)),
                "live repro watch HCR cycle",
            )?;

            let old_stop = live_event(&lldb_events, "oldGenerationStop")?;
            let old_step_start = live_event(&lldb_events, "oldGenerationStepStart")?;
            let old_step_next = live_event(&lldb_events, "oldGenerationStepNext")?;
            let new_stop = live_event(&lldb_events, "newGenerationStop")?;
            let new_step_start = live_event(&lldb_events, "newGenerationStepStart")?;
            let new_step_next = live_event(&lldb_events, "newGenerationStepNext")?;

            assert_live_event_line(old_stop, old_breakpoint_line, "old-generation live LLDB breakpoint")?;
            assert_live_event_line(
                old_step_start,
                old_step_start_line,
                "old-generation live LLDB step start",
            )?;
            assert_live_event_line(old_step_next, old_step_next_line, "old-generation live LLDB step next")?;
            assert_live_event_line(new_stop, new_breakpoint_line, "new-generation live LLDB breakpoint")?;
            assert_live_event_line(
                new_step_start,
                new_step_start_line,
                "new-generation live LLDB step start",
            )?;
            assert_live_event_line(new_step_next, new_step_next_line, "new-generation live LLDB step next")?;

            let live_report_path = live_artifacts.join("hcr-coordinator-report.json");
            let live_report = read_json(&live_report_path)?;
            if live_report.pointer("/patchApplied").is_none() {
                return Err(format!("live HCR coordinator report did not contain patchApplied: {live_report}").into());
            }

            let live_evidence = json!({
                "evidenceSource": "mcr-live-debugserver-lldb",
                "hotCodeReloadAppliedDuringDebugSession": true,
                "reproWatchDroveReload": true,
                "sourceEditDriverRanOutsideReproWatch": true,
                "oldGenerationStop": live_stop_evidence(old_stop, GEN0_BREAKPOINT_MARKER, 0),
                "newGenerationStop": live_stop_evidence(new_stop, GEN1_BREAKPOINT_MARKER, 1),
                "oldGenerationStep": live_step_evidence(
                    old_step_start,
                    old_step_next,
                    GEN0_STEP_START_MARKER,
                    GEN0_STEP_NEXT_MARKER,
                    0,
                ),
                "newGenerationStep": live_step_evidence(
                    new_step_start,
                    new_step_next,
                    GEN1_STEP_START_MARKER,
                    GEN1_STEP_NEXT_MARKER,
                    1,
                ),
                "debugger": {
                    "client": "lldb",
                    "transport": "ct-mcr debugserver live RSP",
                    "program": live_binary,
                    "debugserverLog": debugserver_log,
                    "lldbLog": lldb_output_log,
                    "coordinatorLog": coordinator_log,
                    "coordinatorReport": live_report_path
                }
            });

            fs::write(
                &live_dap_transcript,
                serde_json::to_string_pretty(&json!({
                    "schemaId": "codetracer.reprobuild-hcr-in-codetracer.dap-transcript.v1",
                    "mode": "live",
                    "evidenceSource": "mcr-live-debugserver-lldb",
                    "events": lldb_events,
                    "assertions": live_evidence,
                    "logs": {
                        "reproWatch": coordinator_log,
                        "debugserver": debugserver_log,
                        "lldb": lldb_output_log,
                        "lldbCommands": lldb_command_file,
                        "lldbProbe": lldb_probe_file
                    }
                }))?,
            )?;

            Ok(live_evidence)
        })();

        if let Err(err) = &live_result
            && coordinator.try_wait().ok().flatten().is_none()
        {
            terminate_child(&mut coordinator);
            return Err(format!("{err}").into());
        }

        let live_evidence = live_result?;
        evidence["dap"]["live"] = live_evidence;
        fs::write(&evidence_path, serde_json::to_string_pretty(&evidence)?)?;
        Ok(())
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
            ("CODETRACER_REPLAY_QUERY_TIMEOUT_SECS", "180"),
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
        let replay_move_timeout = scaled(Duration::from_secs(30));

        let mut client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        client.set_breakpoints(&old_source_file, &[old_breakpoint_line])?;
        let old_stop = client.dap_continue_with_timeout(replay_move_timeout)?;
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
        let new_stop = client.dap_continue_with_timeout(replay_move_timeout)?;
        assert_stop_line_and_path(
            &new_stop,
            new_breakpoint_line,
            new_path_suffix,
            "new-generation replay DAP",
        )?;
        let new_stop_evidence = stop_evidence(&mut client, &new_stop, PATCHABLE_FUNCTION, GEN1_BREAKPOINT_MARKER, 1)?;
        client.set_breakpoints(&old_source_file, &[old_breakpoint_line])?;
        let reverse_stop = client.dap_reverse_continue_with_timeout(replay_move_timeout)?;
        assert_stop_line_and_path(
            &reverse_stop,
            old_breakpoint_line,
            old_path_suffix,
            "reverse replay DAP",
        )?;
        client.set_breakpoints(&old_source_file, &[])?;
        client.set_breakpoints(&new_source_file, &[new_breakpoint_line])?;
        let forward_stop = client.dap_continue_with_timeout(replay_move_timeout)?;
        assert_stop_line_and_path(
            &forward_stop,
            new_breakpoint_line,
            new_path_suffix,
            "forward replay DAP",
        )?;
        client.disconnect()?;

        let mut old_step_client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        old_step_client.set_breakpoints(&old_source_file, &[old_step_start_line])?;
        let old_step_start = old_step_client.dap_continue_with_timeout(replay_move_timeout)?;
        assert_stop_line_and_path(
            &old_step_start,
            old_step_start_line,
            old_path_suffix,
            "old-generation replay DAP step start",
        )?;
        let old_step_next = old_step_client.dap_step_with_timeout("next", replay_move_timeout)?;
        assert_stop_line_and_path(
            &old_step_next,
            old_step_next_line,
            old_path_suffix,
            "old-generation replay DAP step next",
        )?;
        old_step_client.disconnect()?;

        let mut new_step_client = launch_replay_dap(db_backend, &trace, ct_native_replay, ct_mcr)?;
        new_step_client.set_breakpoints(&new_source_file, &[new_step_start_line])?;
        let new_step_start = new_step_client.dap_continue_with_timeout(replay_move_timeout)?;
        assert_stop_line_and_path(
            &new_step_start,
            new_step_start_line,
            new_path_suffix,
            "new-generation replay DAP step start",
        )?;
        let new_step_next = new_step_client.dap_step_with_timeout("next", replay_move_timeout)?;
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
        if !pointer.starts_with("/dap/live/") && locals.as_object().map(|obj| obj.is_empty()).unwrap_or(true) {
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
        assert_bool(&evidence, "/mcr/strictReplayRequired", true)?;
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

        assert_str(&evidence, "/dap/live/evidenceSource", "mcr-live-debugserver-lldb")?;
        assert_bool(&evidence, "/dap/live/hotCodeReloadAppliedDuringDebugSession", true)?;
        assert_bool(&evidence, "/dap/live/reproWatchDroveReload", true)?;
        assert_bool(&evidence, "/dap/live/sourceEditDriverRanOutsideReproWatch", true)?;
        assert_generation_stop(&evidence, "/dap/live/oldGenerationStop", 0, GEN0_BREAKPOINT_MARKER)?;
        assert_generation_stop(&evidence, "/dap/live/newGenerationStop", 1, GEN1_BREAKPOINT_MARKER)?;
        assert_generation_step(
            &evidence,
            "/dap/live/oldGenerationStep",
            0,
            GEN0_STEP_START_MARKER,
            GEN0_STEP_NEXT_MARKER,
        )?;
        assert_generation_step(
            &evidence,
            "/dap/live/newGenerationStep",
            1,
            GEN1_STEP_START_MARKER,
            GEN1_STEP_NEXT_MARKER,
        )?;
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
        let repro = write_repro_wrapper(&temp_root, &repro, &reprobuild_source_root)?;
        let project_dir = temp_root.join("project");
        let fixture_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_DIR);
        copy_dir_filtered(&fixture_dir, &project_dir)?;
        assert_fixture_contract(&project_dir)?;

        require_reprobuild_full_hcr_profile(&repro, &reprobuild_source_root)?;

        let binary_path = project_dir.join("build/hcr_target");
        let artifacts_dir = temp_root.join("artifacts");
        run_codetracer_hcr_gate_driver(GateDriverConfig {
            project_dir: &project_dir,
            binary_path: &binary_path,
            artifacts_dir: &artifacts_dir,
            repro: &repro,
            ct_native_replay: &ct_native_replay,
            ct_mcr: &ct_mcr,
            db_backend: &db_backend,
            reprobuild_source_root: &reprobuild_source_root,
        })?;
        run_real_live_debug_assertions(
            &artifacts_dir,
            &project_dir,
            &binary_path,
            &repro,
            &ct_mcr,
            &reprobuild_source_root,
        )?;
        run_real_replay_dap_assertions(&artifacts_dir, &project_dir, &db_backend, &ct_native_replay, &ct_mcr)?;
        assert_gate_evidence(&artifacts_dir)?;

        Ok(())
    }
}
