import std/[os, strutils]

import repro_dsl_stdlib

const
  BuildDebugRoot = "src/build-debug"
  PublicResourceRoot = "src/public"

# Windows: extra C/linker flags so the bundled libzip C sources compile under
# MinGW UCRT (mirror of src/Tuprules.tup's NIM_WINDOWS_CFLAGS / DYNLIB_OVERRIDE_FLAGS
# windows branch). zlib lives at the vendored DIY path because env.ps1 does not
# yet install a system zlib; -Wno-implicit-function-declaration demotes the
# getpid/unlink/mkstemp implicit-decl errors to warnings so MinGW's import
# library can wire the names at link time.
const
  CodeTracerDevEnvInputFiles = [
    ".envrc",
    ".env",
    "flake.nix",
    "flake.lock",
    "justfile",
    "nix/pre-commit.nix",
    "nix/shells/default.nix",
    "nix/shells/main.nix",
    "nix/shells/armShell.nix",
    "node-packages/package.json",
    "node-packages/yarn.lock",
    "package.json",
    "scripts/build.sh",
    "scripts/build-once.sh",
    "scripts/detect-siblings.sh",
    "scripts/developer-setup.sh",
    "non-nix-build/env.sh",
    "non-nix-build/windows/setup-codetracer-runtime-env.sh",
    "src/Tuprules.tup"
  ]
  CodeTracerKnownSiblingDirs = [
    "codetracer-native-backend",
    "codetracer-rr-backend",
    "codetracer-native-recorder",
    "codetracer-native-test-programs",
    "codetracer-python-recorder",
    "codetracer-ruby-recorder",
    "codetracer-js-recorder",
    "codetracer-beam-recorder",
    "codetracer-elixir-recorder",
    "codetracer-shell-recorders",
    "codetracer-wasm-recorder",
    "codetracer-trace-format",
    "codetracer-trace-format-nim",
    "codetracer-visual-replay",
    "codetracer-cairo-recorder",
    "codetracer-cardano-recorder",
    "codetracer-circom-recorder",
    "codetracer-evm-recorder",
    "codetracer-flow-recorder",
    "codetracer-fuel-recorder",
    "codetracer-leo-recorder",
    "codetracer-miden-recorder",
    "codetracer-move-recorder",
    "codetracer-polkavm-recorder",
    "codetracer-solana-recorder",
    "codetracer-ton-recorder",
    "codetracer-wasmi-recorder",
    "nix-blockchain-development",
    "noir",
    "runquota",
    "reprobuild"
  ]
  CodeTracerNixSiblingInputs = [
    ("codetracer-python-recorder", "codetracer-python-recorder"),
    ("codetracer-ruby-recorder", "codetracer-ruby-recorder"),
    ("codetracer-js-recorder", "codetracer-js-recorder"),
    ("codetracer-shell-recorders", "codetracer-shell-recorders"),
    ("codetracer-wasm-recorder", "wazero"),
    ("codetracer-trace-format", "codetracer-trace-format"),
    ("nix-blockchain-development", "nix-blockchain-development"),
    ("runquota", "runquota"),
    ("reprobuild", "reprobuild")
  ]
  CodeTracerRepoEnvAliases = [
    ("codetracer-native-backend", "CODETRACER_NATIVE_BACKEND_REPO_PATH"),
    ("codetracer-rr-backend", "CODETRACER_RR_BACKEND_PATH"),
    ("codetracer-native-recorder", "CODETRACER_NATIVE_RECORDER_REPO_PATH"),
    ("codetracer-native-test-programs", "CODETRACER_NATIVE_TEST_PROGRAMS_PATH"),
    ("codetracer-python-recorder", "CODETRACER_PYTHON_RECORDER_REPO_PATH"),
    ("codetracer-ruby-recorder", "CODETRACER_RUBY_RECORDER_REPO_PATH"),
    ("codetracer-js-recorder", "CODETRACER_JS_RECORDER_REPO_PATH"),
    ("codetracer-beam-recorder", "CODETRACER_BEAM_RECORDER_PATH"),
    ("codetracer-elixir-recorder", "CODETRACER_ELIXIR_RECORDER_PATH"),
    ("codetracer-shell-recorders", "CODETRACER_SHELL_RECORDERS_REPO_PATH"),
    ("codetracer-wasm-recorder", "CODETRACER_WASM_RECORDER_REPO_PATH"),
    ("codetracer-trace-format", "CODETRACER_TRACE_FORMAT_REPO_PATH"),
    ("codetracer-trace-format-nim", "CODETRACER_TRACE_FORMAT_NIM_REPO_PATH"),
    ("codetracer-visual-replay", "CODETRACER_VISUAL_REPLAY_REPO_PATH"),
    ("nix-blockchain-development", "CODETRACER_NIX_BLOCKCHAIN_DEVELOPMENT_REPO_PATH"),
    ("runquota", "RUNQUOTA_SRC"),
    ("reprobuild", "CODETRACER_REPROBUILD_REPO_PATH")
  ]
  WindowsZlibRoot = "D:/metacraft-dev-deps/zlib/1.3.1"
  WindowsExtraPassC = @[
    "-I" & WindowsZlibRoot & "/include",
    "-Wno-implicit-function-declaration",
    "-Wno-error=implicit-function-declaration"
  ]
  WindowsExtraPassL = @[
    "-L" & WindowsZlibRoot & "/lib",
    "-lz"
  ]

const
  CtConfigHeader = """
#ifndef REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_CONFIG_H
#define REPROBUILD_CT_SUBSET_GENERATED 1
#endif
"""
  CommonNimDefines = @[
    "chronicles_sinks=json",
    "chronicles_line_numbers=true",
    "chronicles_timestamps=UnixTime",
    "ssl",
    "nimNoLentIterators",
    "debug"
  ]
  RendererDefines = @[
    "chronicles_enabled=off",
    "ctRenderer"
  ]
  HmrRendererDefines = RendererDefines & @[
    "ctHmr",
    "isonimHmr"
  ]
  NativeDefines = @[
    "chronicles_sinks=json",
    "chronicles_line_numbers=true",
    "chronicles_timestamps=UnixTime",
    "ssl",
    "nimNoLentIterators",
    "debug",
    "testing",
    "ctEntrypoint",
    "withTup",
    "useOpenssl3",
    "ssl"
  ]
  DisabledNimHints = @[
    "Processing]:off",
    "Conf]:off",
    "CC]:off",
    "Pattern]:off",
    "XDeclaredButNotUsed]:off",
    "XCannotRaiseY]:off"
  ]
  DisabledCaseTransitionWarning = @["CaseTransition]:off"]
  CodeTracerNimPaths = @[
    "libs/NimYAML",
    "libs/asynctools",
    "libs/karax/karax",
    "libs/nim",
    "libs/nim-chronicles/",
    "libs/nim-faststreams",
    "libs/nim-json-serialization",
    "libs/nim-prompt",
    "libs/nim-serialization",
    "libs/nim-stew",
    "libs/nim-unicodedb/src",
    "libs/poly",
    "libs/quicktest",
    "libs/asynctools",
    "libs/chronos",
    "libs/parsetoml/src",
    "libs/nim-result",
    "libs/nim-confutils",
    "libs/nimcrypto",
    "libs/zip",
    "libs/jsony/src",
    "libs/nim-uuid4/src"
  ]
  NativePassL = @[
    "-lssl",
    "-lcrypto",
    "-lsqlite3",
    "-lpcre",
    "-lzip"
  ]
  StylusCssEntryPoints = @[
    "default_white_theme",
    "default_dark_theme_electron",
    "default_dark_theme_extension",
    "loader",
    "subwindow"
  ]

when defined(windows):
  const
    ExeSuffix = ".exe"
    CargoTargetBase = "C:/tmp/codetracer"
else:
  const
    ExeSuffix = ""
    CargoTargetBase = "/tmp/codetracer"

when defined(linux) or defined(macosx):
  const NativeDynlibOverrides = @[
    # Nim 2.2's static OpenSSL wrapper path currently expands to `gimportc`,
    # which is rejected as an invalid pragma. Keep OpenSSL dynamic on POSIX,
    # while still linking the same libraries through NativePassL.
    "sqlite3",
    "pcre",
    "libzip"
  ]
else:
  const NativeDynlibOverrides = @[
    "libcrypto",
    "libssl",
    "sqlite3",
    "pcre",
    "libzip"
  ]

proc codeTracerWorkspaceRoot(projectRoot: string): string =
  for candidate in [projectRoot.parentDir, projectRoot.parentDir.parentDir]:
    if candidate.len == 0:
      continue
    for sibling in CodeTracerKnownSiblingDirs:
      if dirExists(candidate / sibling):
        return normalizedPath(candidate)

proc siblingPath(workspaceRoot, repoName: string): string =
  if workspaceRoot.len == 0:
    return ""
  let candidate = normalizedPath(workspaceRoot / repoName)
  if dirExists(candidate):
    return candidate

proc metacraftScriptsPath(projectRoot, workspaceRoot: string): string =
  for candidate in [workspaceRoot, projectRoot.parentDir,
      projectRoot.parentDir.parentDir]:
    if candidate.len == 0:
      continue
    let scripts = normalizedPath(candidate / "scripts")
    if dirExists(scripts):
      return scripts

proc buildDebugPath(path: string): string =
  BuildDebugRoot / path

proc nativeLibraryPathEnvName(): string =
  when defined(macosx):
    "DYLD_LIBRARY_PATH"
  else:
    "LD_LIBRARY_PATH"

package codeTracer:
  defaultToolProvisioning "nix"

  uses:
    "bash >=5"
    "cachix >=0"
    "capnp >=0"
    "cargo >=1"
    "cargo-nextest >=0"
    "clang >=1"
    "ctags >=0"
    "curl >=0"
    "electron >=0"
    "emcc >=0"
    "flake8 >=0"
    "nim >=1.6 <3.0"
    "nimble >=0"
    "node >=20"
    "npx >=0"
    "gcc >=1"
    "gh >=0"
    "git >=2"
    "just >=1"
    "llvm-config >=0"
    "mdbook >=0"
    "nix >=2"
    "openssl >=0"
    "pcre-config >=0"
    "pkg-config >=0"
    "playwright >=0"
    "python3 >=3"
    "rg >=0"
    "ruby >=0"
    "rust-analyzer >=0"
    "rustc >=1"
    "rustfmt >=1"
    "rustup >=1"
    "sh >=1"
    "shellcheck >=0"
    "sqlite3 >=0"
    "stylus >=0"
    "tmux >=0"
    "tree-sitter >=0"
    "vim >=0"
    "wasm-opt >=0"
    "wasm-pack >=0"
    "webpack-cli >=0"
    "wget >=0"
    "yarn >=1"
    "zstd >=0"
    when not defined(macosx):
      "tup >=0"
    when defined(linux):
      "bpftrace >=0"
      "bpftool >=0"
      "dpkg >=0"
      "xdotool >=0"
      "xvfb-run >=0"

  devEnv:
    activity "default"
    activity "frontend"
    activity "backend"
    activity "tests"
    activity "recorders"
    activity "docs"
    activity "bpf"

    let projectRoot = getCurrentDir()
    let workspaceRoot = codeTracerWorkspaceRoot(projectRoot)
    var nixOverrideFlags: seq[string] = @[]
    let workspaceParent = normalizedPath(projectRoot / "..")

    setWorkingDirectory "."
    providerDirectoryInput("..")
    if workspaceRoot.len > 0 and workspaceRoot != workspaceParent:
      providerDirectoryInput(workspaceRoot)

    for inputFile in CodeTracerDevEnvInputFiles:
      if fileExists(projectRoot / inputFile):
        discard readDevEnvFile(inputFile)

    setEnv "CODETRACER_REPO_ROOT_PATH", projectRoot
    setEnv "CODETRACER_PREFIX", projectRoot / "src" / "build-debug"
    setEnv "CODETRACER_DEV_TOOLS", "0"
    setEnv "CODETRACER_LOG_LEVEL", "INFO"
    setEnv "RUST_LOG", "info"
    setEnv "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS", "true"
    setEnv "REPROBUILD_USE_SYSTEM_HASH_LIBS", "1"
    appendPath "NODE_PATH", projectRoot / "node_modules"
    prependPath "PATH", projectRoot / "node_modules" / ".bin"
    prependPath "PATH", projectRoot / "src" / "build-debug" / "bin"

    let metacraftScripts = metacraftScriptsPath(projectRoot, workspaceRoot)
    if metacraftScripts.len > 0:
      setEnv "METACRAFT_WORKSPACE_PRESENT", "1"
      setEnv "METACRAFT_WORKSPACE_SCRIPTS", metacraftScripts
      prependPath "PATH", metacraftScripts

    for (repoName, envName) in CodeTracerRepoEnvAliases:
      let path = siblingPath(workspaceRoot, repoName)
      if path.len > 0:
        setEnv envName, path
        if repoName == "reprobuild":
          setEnv "REPROBUILD_SOURCE_ROOT", path

    let nativeReplay = siblingPath(workspaceRoot, "codetracer-native-backend") /
      "target" / "debug"
    if fileExists(nativeReplay / "ct-native-replay"):
      prependPath "PATH", nativeReplay

    let nativeRecorder = siblingPath(workspaceRoot, "codetracer-native-recorder")
    let nativeRecorderBin =
      when defined(macosx):
        if fileExists(nativeRecorder / "ct_cli" / "ct_cli-debug"):
          nativeRecorder / "ct_cli" / "ct_cli-debug"
        else:
          nativeRecorder / "ct_cli" / "ct_cli"
      else:
        nativeRecorder / "ct_cli" / "ct_cli"
    if fileExists(nativeRecorderBin):
      setEnv "CODETRACER_CT_MCR_CMD", nativeRecorderBin
      prependPath "PATH", nativeRecorder / "ct_cli"

    let pythonRecorder = siblingPath(workspaceRoot, "codetracer-python-recorder")
    if dirExists(pythonRecorder / "codetracer-python-recorder"):
      setEnv "CODETRACER_PYTHON_RECORDER_SRC",
        pythonRecorder / "codetracer-python-recorder"
      setEnv "CODETRACER_PYTHON_PURE_RECORDER_SRC",
        pythonRecorder / "codetracer-pure-python-recorder"

    let rubyRecorder = siblingPath(workspaceRoot, "codetracer-ruby-recorder")
    if dirExists(rubyRecorder / "gems"):
      setEnv "RUBY_RECORDER_ROOT", rubyRecorder
      let rubyRecorderBin =
        rubyRecorder / "gems" / "codetracer-ruby-recorder" / "bin"
      if fileExists(rubyRecorderBin / "codetracer-ruby-recorder"):
        prependPath "PATH", rubyRecorderBin

    let jsRecorder = siblingPath(workspaceRoot, "codetracer-js-recorder")
    if fileExists(jsRecorder / "node_modules" / ".bin" /
        "codetracer-js-recorder"):
      prependPath "PATH", jsRecorder / "node_modules" / ".bin"

    let shellRecorders = siblingPath(workspaceRoot, "codetracer-shell-recorders")
    if dirExists(shellRecorders / "bash-recorder"):
      prependPath "PATH", shellRecorders / "zsh-recorder"
      prependPath "PATH", shellRecorders / "bash-recorder"

    let wasmRecorder = siblingPath(workspaceRoot, "codetracer-wasm-recorder")
    if fileExists(wasmRecorder / "wazero"):
      prependPath "PATH", wasmRecorder

    let traceFormat = siblingPath(workspaceRoot, "codetracer-trace-format") /
      "target" / "release"
    if dirExists(traceFormat):
      prependPath nativeLibraryPathEnvName(), traceFormat

    let traceFormatNim = siblingPath(workspaceRoot,
      "codetracer-trace-format-nim")
    let traceWriterLib =
      when defined(macosx):
        "libcodetracer_trace_writer.dylib"
      else:
        "libcodetracer_trace_writer.so"
    if fileExists(traceFormatNim / traceWriterLib):
      prependPath nativeLibraryPathEnvName(), traceFormatNim

    for recorderName in [
        "cairo", "cardano", "circom", "evm", "flow", "fuel", "leo",
        "miden", "move", "polkavm", "solana", "ton", "native", "wasmi"]:
      let recorderRepo = siblingPath(workspaceRoot,
        "codetracer-" & recorderName & "-recorder")
      let recorderBin = recorderRepo / "target" / "release" /
        ("codetracer-" & recorderName & "-recorder")
      if fileExists(recorderBin):
        prependPath "PATH", recorderRepo / "target" / "release"

    for (repoName, inputName) in CodeTracerNixSiblingInputs:
      let path = siblingPath(workspaceRoot, repoName)
      if path.len > 0:
        nixOverrideFlags.add("--override-input " & inputName & " path:" & path)
    if nixOverrideFlags.len > 0:
      setEnv "CODETRACER_NIX_OVERRIDE_FLAGS", nixOverrideFlags.join(" ")

    task "build", command = "just build-once",
      description = "Build the CodeTracer development binaries"
    task "watch", command = "just build",
      description = "Run the continuous development build",
      activities = ["frontend"]
    task "nix-develop",
      command = "nix develop '.?submodules=1' ${CODETRACER_NIX_OVERRIDE_FLAGS:-} -c bash",
      description = "Enter the Nix shell with the detected sibling overrides"
    task "test", command = "just test",
      description = "Run the non-GUI test suite",
      activities = ["tests"]
    task "test-gui", command = "just test-gui",
      description = "Run the Playwright GUI suite under a virtual display",
      activities = ["tests"]
    task "test-e2e", command = "just test-e2e",
      description = "Run the Playwright GUI suite on the current display",
      activities = ["tests"]
    task "test-rust", command = "just test-rust",
      description = "Run db-backend and backend-manager Rust tests",
      activities = ["tests"]
    task "db-backend-build", command = "cd src/db-backend && cargo build",
      description = "Build the Rust db-backend",
      activities = ["backend"]
    task "db-backend-clippy",
      command = "cd src/db-backend && cargo clippy --all-targets -- -D warnings",
      description = "Run db-backend clippy checks",
      activities = ["backend"]
    task "frontend-tests", command = "just test-frontend-js",
      description = "Run the frontend JavaScript tests",
      activities = ["tests"]
    task "storybook", command = "just storybook",
      description = "Run Storybook",
      activities = ["frontend"]
    task "docs", command = "just build-docs",
      description = "Build the documentation book",
      activities = ["docs"]
    task "developer-setup", command = "just developer-setup",
      description = "Install local development capabilities such as BPF setup",
      activities = ["bpf"]
    task "test-bpf", command = "just test-bpf",
      description = "Run BPF monitor tests",
      activities = ["bpf"]

    diagnostic "CodeTracer dev environment definition loaded"

  build:
    template ctNimJs(definesValue: seq[string];
                     outputPath, sourcePath: string;
                     extraInputsValue: openArray[string] = [];
                     extraOutputsValue: openArray[string] = [];
                     debugInfoOnValue = false;
                     sourcemapOnValue = false;
                     hotCodeReloadingOnValue = false): BuildActionDef =
      nim.js(
        defines = definesValue,
        mm = "refc",
        hintsOff = true,
        warningsOff = true,
        disabledHints = DisabledNimHints,
        disabledWarnings = DisabledCaseTransitionWarning,
        debugInfo = true,
        debugInfoOn = debugInfoOnValue,
        lineDirOn = true,
        stacktraceOn = true,
        linetraceOn = true,
        sourcemapOn = sourcemapOnValue,
        hotCodeReloadingOn = hotCodeReloadingOnValue,
        output = outputPath,
        extraInputs = extraInputsValue,
        extraOutputs = extraOutputsValue,
        paths = CodeTracerNimPaths,
        source = sourcePath)

    template ctNative(outputPath, sourcePath, nimcachePath: string):
        BuildActionDef =
      # Windows: drop the Linux/Nix dynlibOverride+passL set (no system
      # libssl/libcrypto/libsqlite3/libpcre/libzip available on the DIY
      # toolchain); pin -lz + zlib include/lib paths via passC/passL so the
      # bundled libzip C sources compile (see WindowsExtraPassC/PassL above).
      # The DSL output role for nim.c does NOT auto-append .exe on Windows;
      # add it explicitly so the cache lookup and downstream consumers see the
      # real file path emitted by the Nim compiler.
      when defined(windows):
        nim.c(
          defines = NativeDefines,
          mm = "refc",
          hintsOff = true,
          warningsOff = true,
          disabledHints = DisabledNimHints,
          disabledWarnings = DisabledCaseTransitionWarning,
          debugInfo = true,
          lineDirOn = true,
          stacktraceOn = true,
          linetraceOn = true,
          boundChecksOn = true,
          warningsOn = true,
          hintsOn = true,
          passC = WindowsExtraPassC,
          passL = WindowsExtraPassL,
          nimcache = nimcachePath,
          output = outputPath & ".exe",
          source = sourcePath)
      else:
        nim.c(
          defines = NativeDefines,
          mm = "refc",
          hintsOff = true,
          warningsOff = true,
          disabledHints = DisabledNimHints,
          disabledWarnings = DisabledCaseTransitionWarning,
          debugInfo = true,
          lineDirOn = true,
          stacktraceOn = true,
          linetraceOn = true,
          boundChecksOn = true,
          warningsOn = true,
          hintsOn = true,
          dynlibOverrides = NativeDynlibOverrides,
          passL = NativePassL,
          nimcache = nimcachePath,
          output = outputPath,
          source = sourcePath)

    template ctStylus(name: string): BuildActionDef =
      stylus(
        source = "src/frontend/styles/" & name & ".styl",
        output = buildDebugPath("frontend/styles/" & name & ".css"))

    template ctShell(actionIdValue, commandValue: string;
                     extraInputsValue: openArray[string] = [];
                     extraOutputsValue: openArray[string] = [];
                     afterValue: openArray[BuildActionDef] = [];
                     cacheableValue = true): BuildActionDef =
      shell(
        command = commandValue,
        actionId = actionIdValue,
        extraInputs = extraInputsValue,
        extraOutputs = extraOutputsValue,
        after = afterValue,
        cacheable = cacheableValue)

    let generatedConfigHeader = fs.writeText(
      output = "build/generated/ct_config.h",
      text = CtConfigHeader)
    target("generate-config-header", generatedConfigHeader)

    let buildCDir = fs.ensureDir(path = "build/c")
    target("build-c-dir", buildCDir)

    let ipcRegistryTest = ctNimJs(
      definesValue = CommonNimDefines & HmrRendererDefines,
      outputPath = buildDebugPath("tests/ipc_registry_test.js"),
      sourcePath = "src/frontend/tests/ipc_registry_test.nim",
      extraInputsValue = @[
        "src/frontend/index/ipc_registry.nim",
        "src/frontend/lib/jslib.nim"
      ],
      debugInfoOnValue = true,
      hotCodeReloadingOnValue = true)
    target("nim-js-ipc-registry-test", ipcRegistryTest)

    let reloadReconnectTest = ctNimJs(
      definesValue = CommonNimDefines & HmrRendererDefines,
      outputPath = buildDebugPath("tests/reload_reconnect.js"),
      sourcePath = "src/frontend/tests/test_suites/reload_reconnect.nim",
      debugInfoOnValue = true,
      hotCodeReloadingOnValue = true)
    target("nim-js-reload-reconnect-test", reloadReconnectTest)

    let reloadBootstrapHost = fs.copyFile(
      source = "src/frontend/tests/test_suites/reload_bootstrap_host.js",
      output = buildDebugPath("tests/reload_bootstrap_host.js"))
    target("reload-bootstrap-host-js", reloadBootstrapHost)

    let frontendUiJs = ctNimJs(
      definesValue = CommonNimDefines & HmrRendererDefines,
      outputPath = buildDebugPath("ui.js"),
      sourcePath = "src/frontend/ui_js.nim",
      debugInfoOnValue = true,
      hotCodeReloadingOnValue = true)
    target("frontend-ui-js", frontendUiJs)

    let frontendPublicUiJs = fs.copyFile(
      source = buildDebugPath("ui.js"),
      output = buildDebugPath("public/ui.js"))
    target("frontend-public-ui-js", frontendPublicUiJs)

    let frontendIndexJs = ctNimJs(
      definesValue = CommonNimDefines & @["ctIndex", "nodejs"],
      outputPath = buildDebugPath("index.js"),
      extraOutputsValue = @[buildDebugPath("index.js.map")],
      sourcePath = "src/frontend/index.nim",
      sourcemapOnValue = true)
    target("frontend-index-js", frontendIndexJs)

    let frontendSrcIndexJs = fs.copyFile(
      source = buildDebugPath("index.js"),
      output = buildDebugPath("src/index.js"))
    target("frontend-src-index-js", frontendSrcIndexJs)

    let frontendServerIndexJs = ctNimJs(
      definesValue = CommonNimDefines & @["ctIndex", "server", "nodejs"],
      outputPath = buildDebugPath("server_index.js"),
      extraOutputsValue = @[buildDebugPath("server_index.js.map")],
      sourcePath = "src/frontend/index.nim",
      sourcemapOnValue = true)
    target("frontend-server-index-js", frontendServerIndexJs)

    let frontendSubwindowJs = ctNimJs(
      definesValue = CommonNimDefines & RendererDefines,
      outputPath = buildDebugPath("subwindow.js"),
      extraOutputsValue = @[buildDebugPath("subwindow.js.map")],
      sourcePath = "src/frontend/subwindow.nim",
      debugInfoOnValue = true,
      sourcemapOnValue = true,
      hotCodeReloadingOnValue = true)
    target("frontend-subwindow-js", frontendSubwindowJs)

    let frontendSrcSubwindowJs = fs.copyFile(
      source = buildDebugPath("subwindow.js"),
      output = buildDebugPath("src/subwindow.js"))
    target("frontend-src-subwindow-js", frontendSrcSubwindowJs)

    let frontendIndexHtml = fs.copyFile(
      source = "src/frontend/index.html",
      output = buildDebugPath("index.html"))
    target("frontend-index-html", frontendIndexHtml)

    let frontendSubwindowHtml = fs.copyFile(
      source = "src/frontend/subwindow.html",
      output = buildDebugPath("subwindow.html"))
    target("frontend-subwindow-html", frontendSubwindowHtml)

    let frontendRootHelpersJs = fs.copyFile(
      source = "src/helpers.js",
      output = buildDebugPath("helpers.js"))
    target("frontend-helpers-js", frontendRootHelpersJs)

    let frontendHelpersJs = fs.copyFile(
      source = buildDebugPath("helpers.js"),
      output = buildDebugPath("src/helpers.js"))
    target("frontend-src-helpers-js", frontendHelpersJs)

    var styleActions: seq[BuildActionDef] = @[]
    for name in StylusCssEntryPoints:
      styleActions.add(ctStylus(name))
    let defaultDarkThemeCss = fs.copyFile(
      source = buildDebugPath("frontend/styles/default_dark_theme_extension.css"),
      output = buildDebugPath("frontend/styles/default_dark_theme.css"))
    styleActions.add(defaultDarkThemeCss)
    let frontendStyles = aggregate("frontend-styles", actions = styleActions)

    let publicResources = fs.preserveTree(
      sourceRoot = PublicResourceRoot,
      outputRoot = buildDebugPath("public"),
      excludePrefixes = @["dist"])
    target("frontend-public-resources", publicResources)

    var frontendExtraActions: seq[BuildActionDef] = @[]
    if fileExists("webpack.config.js") and
        fileExists("src/frontend/frontend_imports.js"):
      let webpackDist = ctShell(
        "frontend-webpack-dist",
        "set -eu\n" &
        "mkdir -p src/public/dist\n" &
        "WEBPACK_BIN=node_modules/.bin/webpack\n" &
        "if [ ! -x \"$WEBPACK_BIN\" ]; then WEBPACK_BIN=webpack; fi\n" &
        "\"$WEBPACK_BIN\" --progress\n" &
        "touch " & buildDebugPath(".webpack-dist-built.stamp"),
        extraInputsValue = @[
          "webpack.config.js",
          "package.json",
          "src/frontend/frontend_imports.js"
        ],
        extraOutputsValue = @[
          "src/public/dist",
          buildDebugPath(".webpack-dist-built.stamp")
        ])
      target("frontend-webpack-dist", webpackDist)
      frontendExtraActions.add(webpackDist)

      let publicDist = ctShell(
        "frontend-public-dist",
        "set -eu\n" &
        "rm -rf " & buildDebugPath("public/dist") & "\n" &
        "mkdir -p " & buildDebugPath("public/dist") & "\n" &
        "cp -a src/public/dist/. " & buildDebugPath("public/dist") & "/\n" &
        "touch " & buildDebugPath(".public-dist.stamp"),
        extraInputsValue = @["src/public/dist"],
        extraOutputsValue = @[
          buildDebugPath("public/dist"),
          buildDebugPath(".public-dist.stamp")
        ],
        afterValue = @[webpackDist])
      target("frontend-public-dist", publicDist)
      frontendExtraActions.add(publicDist)

    var frontendActions = @[
      frontendUiJs,
      frontendPublicUiJs,
      frontendIndexJs,
      frontendSrcIndexJs,
      frontendServerIndexJs,
      frontendSubwindowJs,
      frontendSrcSubwindowJs,
      frontendIndexHtml,
      frontendSubwindowHtml,
      frontendRootHelpersJs,
      frontendHelpersJs,
      reloadReconnectTest,
      reloadBootstrapHost,
      publicResources
    ]
    frontendActions.add(frontendExtraActions)

    let frontend = aggregate("frontend",
      actions = frontendActions,
      targets = @[frontendStyles])

    var codetracerActions: seq[BuildActionDef] = @[]

    if fileExists("src/config/default_layout.json"):
      let defaultLayout = fs.copyFile(
        source = "src/config/default_layout.json",
        output = buildDebugPath("config/default_layout.json"))
      target("config-default-layout-json", defaultLayout)
      codetracerActions.add(defaultLayout)

    if fileExists("src/config/default_config.yaml"):
      let defaultConfig = fs.copyFile(
        source = "src/config/default_config.yaml",
        output = buildDebugPath("config/default_config.yaml"))
      target("config-default-config-yaml", defaultConfig)
      codetracerActions.add(defaultConfig)

    let hasFrontendInputs =
      fileExists("src/frontend/ui_js.nim") and
      fileExists("src/frontend/index.nim") and
      fileExists("src/frontend/subwindow.nim") and
      fileExists("src/frontend/index.html") and
      fileExists("src/frontend/subwindow.html") and
      fileExists("src/helpers.js")
    let hasDbBackendRecordInput = fileExists("src/ct/db_backend_record.nim")
    let hasCtInput = fileExists("src/ct/codetracer.nim")

    if fileExists("src/backend-manager/Cargo.toml"):
      let sessionManager = ctShell(
        "backend-session-manager",
        "set -eu\n" &
        "mkdir -p " & buildDebugPath("bin") & "\n" &
        "cargo build --locked --release " &
          "--manifest-path src/backend-manager/Cargo.toml " &
          "--target-dir " & CargoTargetBase & "/backend_manager_target\n" &
        "cp " & CargoTargetBase & "/backend_manager_target/release/" &
          "session-manager" & ExeSuffix & " " &
          buildDebugPath("bin/session-manager" & ExeSuffix),
        extraInputsValue = @[
          "src/backend-manager/Cargo.toml",
          "src/backend-manager/Cargo.lock"
        ],
        extraOutputsValue = @[buildDebugPath("bin/session-manager" & ExeSuffix)])
      target("session-manager", sessionManager)
      codetracerActions.add(sessionManager)

    if fileExists("src/db-backend/Cargo.toml"):
      let replayServer = ctShell(
        "db-replay-server",
        "set -eu\n" &
        "mkdir -p " & buildDebugPath("bin") & "\n" &
        "if [ -f libs/tree-sitter-nim/grammar.js ] && " &
          "[ ! -f libs/tree-sitter-nim/src/parser.c ]; then\n" &
        "  (cd libs/tree-sitter-nim && tree-sitter generate)\n" &
        "fi\n" &
        "cargo build --locked " &
          "--manifest-path src/db-backend/Cargo.toml " &
          "--target-dir " & CargoTargetBase & "/db_backend_target\n" &
        "cp " & CargoTargetBase & "/db_backend_target/debug/" &
          "replay-server" & ExeSuffix & " " &
          buildDebugPath("bin/replay-server" & ExeSuffix),
        extraInputsValue = @[
          "src/db-backend/Cargo.toml",
          "src/db-backend/Cargo.lock",
          "src/db-backend/build.rs",
          "libs/tree-sitter-nim/grammar.js",
          "libs/tree-sitter-nim/src/scanner.c"
        ],
        extraOutputsValue = @[buildDebugPath("bin/replay-server" & ExeSuffix)])
      target("replay-server", replayServer)
      codetracerActions.add(replayServer)

    if fileExists("src/ct/db_backend_record.nim"):
      let dbBackendRecord = ctNative(
        nimcachePath = "/tmp/ct-nim-cache/db_backend_record_codetracer_binary",
        outputPath = buildDebugPath("bin/db-backend-record"),
        sourcePath = "src/ct/db_backend_record.nim")
      target("db-backend-record", dbBackendRecord)
      codetracerActions.add(dbBackendRecord)

    if fileExists("src/ct/codetracer.nim"):
      let ct = ctNative(
        nimcachePath = "/tmp/ct-nim-cache/codetracer_codetracer_binary",
        outputPath = buildDebugPath("bin/ct"),
        sourcePath = "src/ct/codetracer.nim")
      target("ct", ct)
      codetracerActions.add(ct)

    if hasFrontendInputs and hasDbBackendRecordInput and hasCtInput:
      let codetracer = aggregate("codetracer",
        actions = codetracerActions,
        targets = @[frontend])
      defaultBuildAction(codetracer)

    let cSudokuObjectTup = gcc(
      source = "test-programs/c_sudoku_solver/main.c",
      output = "build/c/main.tup.o",
      pic = true,
      debug3 = true,
      compileOnly = true,
      after = @[buildCDir])
    target("c-sudoku-object-tup", cSudokuObjectTup)

    let cSudokuObjectWithGeneratedHeader = gcc(
      source = "test-programs/c_sudoku_solver/main.c",
      output = "build/c/main.with-header.o",
      pic = true,
      debug3 = true,
      compileOnly = true,
      includes = @["build/generated/ct_config.h"],
      after = @[buildCDir])
    target("c-sudoku-object-with-generated-header",
      cSudokuObjectWithGeneratedHeader)
