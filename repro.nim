import std/[os, strutils]

import repro_dsl_stdlib




const
  PublicResourceRoot = "src/public"

# Reprobuild's output root — codetracer's tup-friendly override of
# reprobuild's cargo-like default (see codetracer-specs
# Architecture/Build-Outputs-And-Path-Resolution.md and reprobuild-specs
# Standard-Configurations.md).
#
# ``src/build-<buildType>-repro`` on ALL platforms: reprobuild's output must
# never share a directory with tup's ``src/build-debug`` variant dir (tup
# refuses to build when its variant dir contains files it did not create), so
# the reprobuild outputs sit beside the tup dirs with a ``-repro`` suffix.
#
# ``buildType`` is a reprobuild VARIANT — a tracked solver input that is part
# of the graph cache key, unlike a runtime ``getEnv`` (which is silently
# ignored when the lowered graph is served from cache, ``providerInvocations:
# 0``). ``repro build --release`` / ``--variant buildType=release`` selects
# ``src/build-release-repro``. It is declared at module scope (not inside the
# ``config:`` block) so the top-level ``buildDebugPath`` proc below can read
# its resolved value; the ``package`` macro's ``finalizeVariants()`` resolves
# it before the build graph is emitted.
let buildType = block:
  let info = instantiationInfo(fullPaths = true)
  let s = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[string](
    defaultValue = "debug", scopeName = "buildType",
    description = "Build configuration: debug or release.",
    explicitId = "", descriptionFile = info.filename,
    descriptionLine = info.line, descriptionColumn = 0, site = s)

proc buildDebugRoot(): string =
  ## ``src/build-<buildType>-repro``. Reads the resolved ``buildType``
  ## variant; falls back to ``debug`` if read before finalisation.
  let bt =
    try: buildType.value
    except EVariantNotResolved: "debug"
  "src/build-" & bt & "-repro"

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
  WindowsZstdRoot = "D:/metacraft-dev-deps/zstd/1.5.6/zstd-v1.5.6-win64"
  WindowsExtraPassC = @[
    "-I" & WindowsZlibRoot & "/include",
    "-I" & WindowsZstdRoot & "/include",
    "-Wno-implicit-function-declaration",
    "-Wno-error=implicit-function-declaration"
  ]
  WindowsExtraPassL = @[
    "-L" & WindowsZlibRoot & "/lib",
    "-L" & WindowsZstdRoot & "/dll",
    "-lz",
    "-lzstd"
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
  projectRootPath = parentDir(currentSourcePath())
  workspaceRootPath = parentDir(projectRootPath)
  CodeTracerNimPaths = @[
    projectRootPath / "src/frontend",
    projectRootPath / "libs/NimYAML",
    projectRootPath / "libs/asynctools",
    projectRootPath / "libs/karax/karax",
    projectRootPath / "libs/nim",
    projectRootPath / "libs/nim-chronicles",
    projectRootPath / "libs/nim-faststreams",
    projectRootPath / "libs/nim-json-serialization",
    projectRootPath / "libs/nim-prompt",
    projectRootPath / "libs/nim-serialization",
    projectRootPath / "libs/nim-stew",
    projectRootPath / "libs/nim-unicodedb/src",
    projectRootPath / "libs/poly",
    projectRootPath / "libs/quicktest",
    projectRootPath / "libs/chronos",
    projectRootPath / "libs/parsetoml/src",
    projectRootPath / "libs/nim-result",
    projectRootPath / "libs/nim-confutils",
    projectRootPath / "libs/nimcrypto",
    projectRootPath / "libs/zip",
    projectRootPath / "libs/jsony/src",
    projectRootPath / "libs/nim-uuid4/src"
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

when defined(macosx):
  proc deriveNativeLibFlags(): seq[string] {.compileTime.} =
    let libraryPath = getEnv("LIBRARY_PATH")
    for dir in libraryPath.split(':'):
      if dir.len == 0:
        continue
      result.add("-L" & dir)
      result.add("-Wl,-rpath," & dir)
    result.add("-lssl")
    result.add("-lcrypto")
    result.add("-lsqlite3")
    result.add("-lpcre")
    result.add("-lzip")

  const NativePassL = deriveNativeLibFlags()
else:
  const NativePassL = @[
    "-lssl",
    "-lcrypto",
    "-lsqlite3",
    "-lpcre",
    "-lzip"
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
  # Force forward slashes — the result is interpolated into POSIX-style
  # shell commands (bash via the reprobuild ``shell`` action) where
  # backslashes are escape characters. On Windows, Nim's ``/`` operator
  # yields ``src\build-debug\foo`` which bash sees as ``srcbuild-debugfoo``
  # after escape processing, breaking ``cp`` and friends.
  (buildDebugRoot() / path).replace('\\', '/')

proc nativeLibraryPathEnvName(): string =
  when defined(macosx):
    "DYLD_LIBRARY_PATH"
  else:
    "LD_LIBRARY_PATH"

package codeTracer:
  # macOS / Linux: the Nix dev shell provisions every tool listed in
  # ``uses:`` below into ``/nix/store`` and the engine picks them up via the
  # cakNix adapter. Windows has no Nix; the codetracer DIY toolchain
  # bootstrap (``non-nix-build/windows/`` driven by ``env.ps1``) populates
  # PATH with the same set, and ``scripts/build-once.sh`` switches the
  # invocation to ``--tool-provisioning=path`` on that branch. We can't
  # express ``when defined(windows): defaultToolProvisioning "path"`` here
  # because the package DSL macro does not recognize ``when`` at the
  # package-body root (see reprobuild ``libs/repro_project_dsl/src/
  # repro_project_dsl/macros_a.nim``'s ``parsePackageDef``: it only
  # dispatches on ``calleeName``, treating any nnkWhenStmt as an
  # unrecognized identifier and emitting it back verbatim).
  defaultToolProvisioning "nix"

  uses:
    # Cross-platform build tools. Each one has matching provisioning
    # entries in the reprobuild stdlib's package definitions at
    # libs/repro_dsl_stdlib/packages/<tool>.nim:
    #   * ``nixPackage`` for cakNix on Linux / macOS, and
    #   * ``scoopApp`` for cakScoop on Windows (and non-Nix Linux).
    # A Windows operator can therefore run ``repro build .
    # --tool-provisioning=scoop`` and the engine drives a real
    # ``scoop install bucket/app@<version>`` for every tool that doesn't
    # already satisfy the constraint locally. ``capnp`` is on
    # ScoopInstaller/Main as the upstream `capnp` package (added below
    # in libs/repro_dsl_stdlib/packages/capnp.nim).
    "bash >=4"
    "capnp >=0"
    "cargo >=1"
    "emcc >=0"
    "gcc >=10"
    "git >=2"
    "just >=1"
    "mdbook >=0"
    "nim >=1.6 <3.0"
    "nimble >=0"
    "node >=20"
    "npx >=0"
    "python3 >=3"
    "rustc >=1"
    "rustup >=1"
    "sh >=1"
    "wasm-opt >=0"

    # Sibling library dependencies (SC-11 develop-mode from-source consumption)
    "isonim >=0"
    "nim-everywhere >=0"
    "nim-agent-harbor >=0"
    "nim-agents >=0"
    "nim-acp >=0"

    # Windows-only build tools. ``nsis`` (the Nullsoft Scriptable
    # Install System compiler) is what the ``windows-installer``
    # build action invokes to produce ``CodeTracer-Setup.exe``.
    # Linux + macOS use the existing ``appimage-scripts/`` and
    # ``macos-dmg`` paths instead.
    when defined(windows):
      "nsis >=3"

    # macOS-only build tools. ``create-dmg`` produces the .dmg in the
    # ``dmg`` target; it is a Darwin-only nixpkgs package (its
    # ``meta.platforms`` is the two darwin systems), so declaring it in the
    # shared ``not defined(windows)`` block below makes tool resolution fail
    # on Linux (``create-dmg ... is not available on the requested
    # hostPlatform x86_64-linux``). Linux packages instead via
    # ``appimage-scripts/`` / ``nix bundle`` (see ``build-app-image``).
    when defined(macosx):
      "create-dmg >=1"

    # POSIX-only / Nix-only tools — guarded off the Windows branch.
    when not defined(windows):
      "attic-client >=0"
      "cargo-nextest >=0"
      "clang >=1"
      "ctags >=0"
      "curl >=0"
      "electron >=0"
      "flake8 >=0"
      "gh >=0"
      "llvm-config >=0"
      "nix >=2"
      "openssl >=0"
      "pcre-config >=0"
      "pkg-config >=0"
      "playwright >=0"
      "rg >=0"
      "ruby >=0"
      "rust-analyzer >=0"
      "rustfmt >=1"
      "shellcheck >=0"
      "sqlite3 >=0"
      "tmux >=0"
      "tree-sitter >=0"
      "vim >=0"
      "wasm-pack >=0"
      "webpack-cli >=0"
      "wget >=0"
      "yarn >=1"
      "zstd >=0"
    # Tup is the legacy build driver on Linux. macOS now uses reprobuild
    # exclusively, and the Windows build (reprobuild via env.ps1) has no
    # Tup story (the env.ps1 Ensure-Tup is preserved for the old non-
    # reprobuild fallback only).
    when not defined(macosx) and not defined(windows):
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
    setEnv "CODETRACER_PREFIX", projectRoot / buildDebugRoot()
    setEnv "CODETRACER_DEV_TOOLS", "0"
    setEnv "CODETRACER_LOG_LEVEL", "INFO"
    setEnv "RUST_LOG", "info"
    setEnv "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS", "true"
    setEnv "REPROBUILD_USE_SYSTEM_HASH_LIBS", "1"
    appendPath "NODE_PATH", projectRoot / "node_modules"
    prependPath "PATH", projectRoot / "node_modules" / ".bin"
    prependPath "PATH", projectRoot / buildDebugRoot() / "bin"

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
    nim.nimRepropathsConfig()

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
          paths = CodeTracerNimPaths,
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
          paths = CodeTracerNimPaths,
          output = outputPath,
          source = sourcePath)

    template ctStylus(name: string): BuildActionDef =
      # Project-local ``yarn install`` drops ``node_modules/stylus/bin/stylus``
      # as a Node script. Invoke that script through the ``node`` typed tool on
      # every platform instead of declaring a separate ``stylus`` tool. This
      # keeps the build tied to package.json/package-lock.json, avoids a second
      # NPM/Nix provisioning path for the same compiler, and on Windows keeps
      # the direct-CreateProcess shape that avoids Git-Bash fork emulation under
      # the fs-snoop shim.
      let inputStyl = "src/frontend/styles/" & name & ".styl"
      let outputCss = buildDebugPath("frontend/styles/" & name & ".css")
      node(
        args = @["node_modules/stylus/bin/stylus",
                 "-o", outputCss,
                 inputStyl],
        actionId = "stylus-" & name,
        extraInputs = @[inputStyl],
        extraOutputs = @[outputCss])

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

    let defaultDarkThemeExtensionCss =
      ctStylus("default_dark_theme_extension")
    var styleActions: seq[BuildActionDef] = @[defaultDarkThemeExtensionCss]
    for name in StylusCssEntryPoints:
      if name != "default_dark_theme_extension":
        styleActions.add(ctStylus(name))
    let defaultDarkThemeCss = fs.copyFile(
      source = buildDebugPath("frontend/styles/default_dark_theme_extension.css"),
      output = buildDebugPath("frontend/styles/default_dark_theme.css"),
      after = @[defaultDarkThemeExtensionCss])
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
      # Invoke ``node`` DIRECTLY on webpack's CLI entry point. The
      # previous ``ctShell`` formulation went through ``sh -c "...
      # node_modules/.bin/webpack ..."`` which wraps in Git Bash's
      # MSYS2/Cygwin fork-emulation layer; the shim's CREATE_SUSPENDED
      # + LoadLibraryW + Resume injection collides with that fork
      # emulation and the bash sub-process never spawns its child node.
      # Reprobuild's design is to invoke target binaries directly via
      # CreateProcessW, so the ``node`` typed-tool call achieves that
      # — one CreateProcessW, no shell wrapper, no fork emulation.
      # ``mkdir -p src/public/dist`` is handled via the ``ensureDir``
      # builtin instead of an inline shell line.
      # webpack's only emitted artifact is the ``src/public/dist`` tree
      # (see ``webpack.config.js``'s ``output.path``); it does not write a
      # marker file. Declaring a ``.webpack-dist-built.stamp`` output here
      # therefore made the action fail post-run output validation on Linux
      # ("No such file or directory: .../.webpack-dist-built.stamp") because
      # nothing ever creates that stamp. Track the directory tree itself as
      # the output — repro snapshots directory outputs (the Windows
      # ``windows-app`` target relies on the same) and the downstream
      # ``frontend-public-dist`` action already consumes ``src/public/dist``
      # directly, so the stamp was redundant as well as absent.
      let webpackDist = node(
        args = @["node_modules/webpack/bin/webpack.js"],
        actionId = "frontend-webpack-dist",
        extraInputs = @[
          "webpack.config.js",
          "package.json",
          "src/frontend/frontend_imports.js"
        ],
        extraOutputs = @[
          "src/public/dist"
        ])
      target("frontend-webpack-dist", webpackDist)
      frontendExtraActions.add(webpackDist)

      # Mirror src/public/dist into build-debug/public/dist via a one-
      # shot ``node -e`` script. The previous shell formulation used
      # ``sh -c "rm -rf … mkdir -p … cp -a … touch …"`` which spawned
      # rm/mkdir/cp/touch as ~4 grandchildren and hit the same Git-Bash
      # fork-emulation wedge as webpack. ``node -e`` does the entire
      # copy in-process: one CreateProcessW, no shell, no wedge.
      let publicDistTarget = buildDebugPath("public/dist")
      let publicDistStamp = buildDebugPath(".public-dist.stamp")
      let publicDistScript =
        "const fs=require('node:fs'),path=require('node:path');" &
        "const src='src/public/dist',dst='" & publicDistTarget.replace('\\', '/') & "';" &
        "fs.rmSync(dst,{recursive:true,force:true});" &
        "fs.cpSync(src,dst,{recursive:true,dereference:false});" &
        "fs.closeSync(fs.openSync('" & publicDistStamp.replace('\\', '/') & "','w'));"
      let publicDist = node(
        args = @["-e", publicDistScript],
        actionId = "frontend-public-dist",
        extraInputs = @["src/public/dist"],
        extraOutputs = @[publicDistTarget, publicDistStamp],
        after = @[webpackDist])
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
      let sessionManagerBinary =
        CargoTargetBase & "/backend_manager_target/release/session-manager" &
          ExeSuffix
      let sessionManagerBuild = cargo.build(
        locked = true,
        release = true,
        manifestPath = "src/backend-manager/Cargo.toml",
        targetDir = CargoTargetBase & "/backend_manager_target",
        actionId = "backend-session-manager-cargo",
        extraInputs = @[
          "src/backend-manager/Cargo.toml",
          "src/backend-manager/Cargo.lock"
        ],
        extraOutputs = @[sessionManagerBinary])
      let sessionManager = fs.copyFile(
        source = sessionManagerBinary,
        output = buildDebugPath("bin/session-manager" & ExeSuffix),
        actionId = "backend-session-manager",
        after = @[sessionManagerBuild])
      target("session-manager", sessionManager)
      codetracerActions.add(sessionManager)

    if fileExists("src/db-backend/Cargo.toml"):
      let replayServerBinary =
        CargoTargetBase & "/db_backend_target/debug/replay-server" & ExeSuffix
      let replayServerBuild = cargo.build(
        locked = true,
        manifestPath = "src/db-backend/Cargo.toml",
        targetDir = CargoTargetBase & "/db_backend_target",
        actionId = "db-replay-server-cargo",
        extraInputs = @[
          "src/db-backend/Cargo.toml",
          "src/db-backend/Cargo.lock",
          "src/db-backend/build.rs",
          "libs/tree-sitter-nim/grammar.js",
          "libs/tree-sitter-nim/src/parser.c",
          "libs/tree-sitter-nim/src/scanner.c"
        ],
        extraOutputs = @[replayServerBinary])
      let replayServer = fs.copyFile(
        source = replayServerBinary,
        output = buildDebugPath("bin/replay-server" & ExeSuffix),
        actionId = "db-replay-server",
        after = @[replayServerBuild])
      target("replay-server", replayServer)
      codetracerActions.add(replayServer)

    # Nim cache dirs. ``/tmp`` is POSIX-only; on Windows we resolve to
    # ``%TEMP%/ct-nim-cache`` via getEnv. The nimcache path is consumed
    # raw by nim.exe (not via bash), so backslash mixing is OK.
    let ctNimCacheRoot =
      when defined(windows):
        (getEnv("TEMP") / "ct-nim-cache").replace('\\', '/')
      else:
        "/tmp/ct-nim-cache"

    if fileExists("src/ct/db_backend_record.nim"):
      let dbBackendRecord = ctNative(
        nimcachePath = ctNimCacheRoot & "/db_backend_record_codetracer_binary",
        outputPath = buildDebugPath("bin/db-backend-record"),
        sourcePath = "src/ct/db_backend_record.nim")
      target("db-backend-record", dbBackendRecord)
      codetracerActions.add(dbBackendRecord)

    if fileExists("src/ct/codetracer.nim"):
      let ct = ctNative(
        nimcachePath = ctNimCacheRoot & "/codetracer_codetracer_binary",
        outputPath = buildDebugPath("bin/ct"),
        sourcePath = "src/ct/codetracer.nim")
      target("ct", ct)
      codetracerActions.add(ct)

    if hasFrontendInputs and hasDbBackendRecordInput and hasCtInput:
      let codetracer = aggregate("codetracer",
        actions = codetracerActions,
        targets = @[frontend])
      defaultBuildAction(codetracer)

      when defined(macosx):
        let macosApp = ctShell(
          "macos-app",
          "set -eu\n" &
          "APP_ROOT=non-nix-build/CodeTracer.app\n" &
          "CONTENTS=\"$APP_ROOT/Contents\"\n" &
          "MACOS=\"$CONTENTS/MacOS\"\n" &
          "RESOURCES=\"$CONTENTS/Resources\"\n" &
          "rm -rf \"$APP_ROOT\"\n" &
          "mkdir -p \"$MACOS\" \"$RESOURCES\"\n" &
          "cp -a " & buildDebugPath(".") & "/. \"$MACOS\"/\n" &
          "mkdir -p \"$MACOS/bin\" \"$MACOS/src\"\n" &
          "cp resources/electron \"$MACOS/bin/electron\"\n" &
          "cp src/helpers.js \"$MACOS/src/helpers.js\"\n" &
          "cp src/helpers.js \"$MACOS/helpers.js\"\n" &
          "if [ -d node_modules ]; then cp -a node_modules \"$MACOS/node_modules\"; fi\n" &
          "if [ -e \"$MACOS/bin/ct\" ]; then\n" &
          "  mv \"$MACOS/bin/ct\" \"$MACOS/bin/ct_unwrapped\"\n" &
          "  cat >\"$MACOS/bin/ct\" <<'EOF'\n" &
          "#!/usr/bin/env bash\n" &
          "HERE=$(cd \"$(dirname \"$(dirname \"$0\")\")\" && pwd)\n" &
          "export CODETRACER_PREFIX=\"$HERE\"\n" &
          "export PATH=\"$HERE/bin:${PATH}\"\n" &
          "exec \"$HERE/bin/ct_unwrapped\" \"$@\"\n" &
          "EOF\n" &
          "  chmod +x \"$MACOS/bin/ct\"\n" &
          "fi\n" &
          "if [ -n \"${CT_SANDBOX_TOOLS_DIR:-}\" ] && " &
            "{ [ -x \"$CT_SANDBOX_TOOLS_DIR/usr/bin/iconutil\" ] || " &
              "[ -x \"$CT_SANDBOX_TOOLS_DIR/bin/iconutil\" ]; }; then\n" &
          "  iconutil -c icns resources/Icon.iconset --output \"$RESOURCES/CodeTracer.icns\"\n" &
          "else\n" &
          "  python3 - \"$RESOURCES/CodeTracer.icns\" <<'PY'\n" &
          "import struct\n" &
          "import sys\n" &
          "from pathlib import Path\n" &
          "\n" &
          "# Fallback for hosts without a non-SIP iconutil drop-in. When\n" &
          "# CT_SANDBOX_TOOLS_DIR contains iconutil, the branch above uses the\n" &
          "# normal macOS tool and lets the monitor rewrite it through\n" &
          "# nim-stackable-hooks/io-mon sandbox-tools propagation.\n" &
          "iconset = Path('resources/Icon.iconset')\n" &
          "entries = [\n" &
          "    ('icp4', 'icon_16x16.png'),\n" &
          "    ('icp5', 'icon_32x32.png'),\n" &
          "    ('icp6', 'icon_32x32@2x.png'),\n" &
          "    ('ic07', 'icon_128x128.png'),\n" &
          "    ('ic08', 'icon_256x256.png'),\n" &
          "    ('ic09', 'icon_512x512.png'),\n" &
          "    ('ic10', 'icon_512x512@2x.png'),\n" &
          "]\n" &
          "payload = bytearray()\n" &
          "for code, name in entries:\n" &
          "    data = (iconset / name).read_bytes()\n" &
          "    payload += code.encode('ascii') + struct.pack('>I', len(data) + 8) + data\n" &
          "Path(sys.argv[1]).write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)\n" &
          "PY\n" &
          "fi\n" &
          "YEAR=$(sed -n 's/.*CodeTracerYear\\* = //p' src/ct/version.nim | head -n1)\n" &
          "MONTH=$(printf '%02d' \"$(sed -n 's/.*CodeTracerMonth\\* = //p' src/ct/version.nim | head -n1)\")\n" &
          "BUILD=$(sed -n 's/.*CodeTracerBuild\\* = //p' src/ct/version.nim | head -n1)\n" &
          "VERSION=\"$YEAR.$MONTH.$BUILD\"\n" &
          "cp resources/Info.plist \"$CONTENTS/Info.plist\"\n" &
          "sed \"s/CFBundleShortVersionString.*/CFBundleShortVersionString<\\/key><string>$VERSION<\\/string>/g\" \"$CONTENTS/Info.plist\" >\"$CONTENTS/Info.plist.tmp\"\n" &
          "mv \"$CONTENTS/Info.plist.tmp\" \"$CONTENTS/Info.plist\"\n" &
          "sed \"s/CFBundleVersion.*/CFBundleVersion<\\/key><string>$VERSION<\\/string>/g\" \"$CONTENTS/Info.plist\" >\"$CONTENTS/Info.plist.tmp\"\n" &
          "mv \"$CONTENTS/Info.plist.tmp\" \"$CONTENTS/Info.plist\"\n" &
          "rm -f \"$CONTENTS/node_modules\"\n" &
          "ln -s MacOS/node_modules \"$CONTENTS/node_modules\"\n" &
          "ELECTRON_APP=\"$MACOS/node_modules/electron/dist/Electron.app\"\n" &
          "if [ -d \"$ELECTRON_APP\" ]; then\n" &
          "  cp \"$CONTENTS/Info.plist\" \"$ELECTRON_APP/Contents/Info.plist\"\n" &
          "  cp \"$RESOURCES/CodeTracer.icns\" \"$ELECTRON_APP/Contents/Resources/\"\n" &
          "  sed 's/<string>bin\\/ct/<string>Electron/g' \"$ELECTRON_APP/Contents/Info.plist\" >\"$ELECTRON_APP/Contents/Info.plist.tmp\"\n" &
          "  mv \"$ELECTRON_APP/Contents/Info.plist.tmp\" \"$ELECTRON_APP/Contents/Info.plist\"\n" &
          "fi\n" &
          "FRAMEWORKS=\"$CONTENTS/Frameworks\"\n" &
          "mkdir -p \"$FRAMEWORKS\"\n" &
          "is_bundle_dep() { case \"$1\" in /nix/store/*|/tmp/*) return 0 ;; *) return 1 ;; esac; }\n" &
          "copy_bundle_dep() {\n" &
          "  dep=\"$1\"\n" &
          "  base=$(basename \"$dep\")\n" &
          "  dest=\"$FRAMEWORKS/$base\"\n" &
          "  if [ ! -e \"$dest\" ]; then\n" &
          "    cp -L \"$dep\" \"$dest\"\n" &
          "    chmod u+w \"$dest\"\n" &
          "    printf '%s\\n' \"$dest\" >>\"$FRAMEWORKS/.deps.queue\"\n" &
          "  fi\n" &
          "}\n" &
          "bundle_deps_for() {\n" &
          "  otool -L \"$1\" 2>/dev/null | awk '/^[[:space:]]*\\/(nix\\/store|tmp)\\// { print $1 }'\n" &
          "}\n" &
          ": >\"$FRAMEWORKS/.deps.queue\"\n" &
          "find \"$MACOS/bin\" -type f -print | while IFS= read -r binary; do\n" &
          "  [ -x \"$binary\" ] || continue\n" &
          "  bundle_deps_for \"$binary\" | while IFS= read -r dep; do copy_bundle_dep \"$dep\"; done\n" &
          "done\n" &
          "while [ -s \"$FRAMEWORKS/.deps.queue\" ]; do\n" &
          "  queue=\"$FRAMEWORKS/.deps.queue\"\n" &
          "  next=\"$FRAMEWORKS/.deps.next\"\n" &
          "  mv \"$queue\" \"$next\"\n" &
          "  : >\"$queue\"\n" &
          "  while IFS= read -r dylib; do\n" &
          "    bundle_deps_for \"$dylib\" | while IFS= read -r dep; do copy_bundle_dep \"$dep\"; done\n" &
          "  done <\"$next\"\n" &
          "  rm -f \"$next\"\n" &
          "done\n" &
          "rm -f \"$FRAMEWORKS/.deps.queue\"\n" &
          "rewrite_macho_deps() {\n" &
          "  file=\"$1\"\n" &
          "  prefix=\"$2\"\n" &
          "  bundle_deps_for \"$file\" | while IFS= read -r dep; do\n" &
          "    base=$(basename \"$dep\")\n" &
          "    if [ -e \"$FRAMEWORKS/$base\" ]; then\n" &
          "      install_name_tool -change \"$dep\" \"$prefix/$base\" \"$file\"\n" &
          "    fi\n" &
          "  done\n" &
          "}\n" &
          "find \"$MACOS/bin\" -type f -print | while IFS= read -r binary; do\n" &
          "  [ -x \"$binary\" ] || continue\n" &
          "  rewrite_macho_deps \"$binary\" '@executable_path/../Frameworks'\n" &
          "done\n" &
          "find \"$FRAMEWORKS\" -type f -print | while IFS= read -r dylib; do\n" &
          "  chmod u+w \"$dylib\"\n" &
          "  install_name_tool -id \"@rpath/$(basename \"$dylib\")\" \"$dylib\" 2>/dev/null || true\n" &
          "  rewrite_macho_deps \"$dylib\" '@loader_path'\n" &
          "done",
          extraInputsValue = @[
            "resources/electron",
            "resources/Icon.iconset",
            "resources/Info.plist",
            "src/ct/version.nim",
            "src/helpers.js",
            "node_modules",
            "scripts/build-once.sh"
          ],
          extraOutputsValue = @["non-nix-build/CodeTracer.app"],
          afterValue = codetracerActions & frontendActions & styleActions)
        target("macos-app", macosApp)

        let stagingApp = fs.preserveTree(
          sourceRoot = "non-nix-build/CodeTracer.app",
          outputRoot = "non-nix-build/dmg-staging/CodeTracer.app",
          actionId = "stage-app-for-dmg",
          after = @[macosApp]
        )

        let macosDmg = create_dmg(
          volname = "CodeTracer",
          background = "non-nix-build/dmg_background.png",
          windowPos = @["200", "120"],
          windowSize = @["600", "400"],
          iconSize = "100",
          icon = @["CodeTracer.app", "150", "200"],
          appDropLink = @["450", "200"],
          sandboxSafe = true,
          dmg = "non-nix-build/CodeTracer.dmg",
          src = "non-nix-build/dmg-staging",
          actionId = "macos-dmg",
          extraInputs = @[
            "non-nix-build/dmg_background.png"
          ],
          after = @[stagingApp]
        )
        target("dmg", macosDmg)


      when defined(windows):
        # Windows app staging — assembles the prebuilt CodeTracer tree
        # the NSIS installer bundles. The shape mirrors `macos-app`:
        # binaries land at `bin/`, the frontend bundle + Electron
        # runtime + node_modules live alongside, and the launcher
        # `ct.bat` is a thin wrapper that exports CODETRACER_PREFIX +
        # extends PATH before invoking the real `ct.exe`. The
        # installer's `File /r` then mirrors the staged tree under
        # `$PROGRAMFILES64\CodeTracer` so end-user paths match the
        # build-debug layout exactly.
        # windows-app staging — one ``node -e`` script in lieu of the
        # earlier ``ctShell("sh -c '...rm...mkdir...cp...mv...cat...'")``
        # to avoid the Git-Bash fork-emulation wedge. Each file op
        # runs in-process inside a single node.exe (one CreateProcessW
        # the shim handles cleanly; no bash sub-fork).
        let appRoot = "non-nix-build/CodeTracer-win"
        let buildDebugRootPath = buildDebugRoot()   # forward slashes
        let ctBatContents =
          "@echo off\r\n" &
          "setlocal\r\n" &
          "set \"HERE=%~dp0..\"\r\n" &
          "set \"CODETRACER_PREFIX=%HERE%\"\r\n" &
          "set \"PATH=%HERE%\\bin;%PATH%\"\r\n" &
          "\"%HERE%\\bin\\ct_unwrapped.exe\" %*\r\n"
        let windowsAppScript =
          "const fs=require('node:fs'),path=require('node:path');" &
          "const APP_ROOT=" & escape(appRoot) & ";" &
          "fs.rmSync(APP_ROOT,{recursive:true,force:true});" &
          "fs.mkdirSync(path.join(APP_ROOT,'bin'),{recursive:true});" &
          "fs.mkdirSync(path.join(APP_ROOT,'src'),{recursive:true});" &
          "fs.cpSync(" & escape(buildDebugRootPath) & ",APP_ROOT,{recursive:true});" &
          "fs.copyFileSync('src/helpers.js',path.join(APP_ROOT,'src/helpers.js'));" &
          "fs.copyFileSync('src/helpers.js',path.join(APP_ROOT,'helpers.js'));" &
          "if(fs.existsSync('node_modules'))" &
            "fs.cpSync('node_modules',path.join(APP_ROOT,'node_modules')," &
              "{recursive:true,dereference:false});" &
          "fs.copyFileSync('resources/CodeTracer.ico',path.join(APP_ROOT,'CodeTracer.ico'));" &
          "const ctExe=path.join(APP_ROOT,'bin','ct.exe');" &
          "if(fs.existsSync(ctExe)){" &
            "fs.renameSync(ctExe,path.join(APP_ROOT,'bin','ct_unwrapped.exe'));" &
            "fs.writeFileSync(path.join(APP_ROOT,'bin','ct.bat')," &
              escape(ctBatContents) & ");" &
          "}"
        let windowsApp = node(
          args = @["-e", windowsAppScript],
          actionId = "windows-app",
          extraInputs = @[
            "resources/CodeTracer.ico",
            "src/ct/version.nim",
            "src/helpers.js",
            "node_modules"
          ],
          extraOutputs = @[appRoot],
          after = codetracerActions & frontendActions & styleActions)
        target("windows-app", windowsApp)

        # NSIS installer — compiles `resources/CodeTracer.nsi` against
        # the staged tree and emits `non-nix-build/CodeTracer-Setup.exe`.
        # The version string is reassembled from `src/ct/version.nim`
        # so the installer's Add/Remove Programs entry tracks the
        # codetracer release. ``makensis`` is provisioned through the
        # ``nsis`` package declared in this recipe's Windows ``uses:``
        # clause above, so the action shells out to the resolved
        # binary on PATH (no out-of-band ``scoop install`` step).
        # windows-installer — parse version.nim and spawn makensis in
        # one ``node -e`` step. spawnSync(makensis) goes through a
        # single CreateProcessW that the shim handles fine (makensis
        # is a native binary with no fork emulation, unlike Git Bash).
        let installerScript =
          "const fs=require('node:fs');" &
          "const cp=require('node:child_process');" &
          "const path=require('node:path');" &
          "const ver=fs.readFileSync('src/ct/version.nim','utf8');" &
          "const match=(r)=>{const m=ver.match(r);if(!m)" &
            "throw new Error('version field missing: '+r);return m[1].trim();};" &
          "const Y=match(/CodeTracerYear[*][ ]*=[ ]*([0-9]+)/);" &
          "const M=String(parseInt(match(/CodeTracerMonth[*][ ]*=[ ]*([0-9]+)/),10))" &
            ".padStart(2,'0');" &
          "const B=match(/CodeTracerBuild[*][ ]*=[ ]*([0-9]+)/);" &
          "const VERSION=Y+'.'+M+'.'+B;" &
          "const REPO_ROOT=process.cwd();" &
          "const STAGING=path.join(REPO_ROOT,'non-nix-build','CodeTracer-win');" &
          "const OUT=path.join(REPO_ROOT,'non-nix-build','CodeTracer-Setup.exe');" &
          "try{fs.unlinkSync(OUT);}catch(e){if(e.code!=='ENOENT')throw e;}" &
          "const r=cp.spawnSync('makensis',['-NOCD'," &
            "'-DAPP_VERSION='+VERSION," &
            "'-DSTAGING_DIR='+STAGING," &
            "'-DOUT_FILE='+OUT," &
            "'-DICON_PATH='+path.join(REPO_ROOT,'resources','CodeTracer.ico')," &
            "'-DLICENSE_PATH='+path.join(REPO_ROOT,'LICENSE')," &
            "'resources/CodeTracer.nsi'" &
          "],{stdio:'inherit',shell:false});" &
          "process.exit(r.status||0);"
        let windowsInstaller = node(
          args = @["-e", installerScript],
          actionId = "windows-installer",
          extraInputs = @[
            "non-nix-build/CodeTracer-win",
            "resources/CodeTracer.nsi",
            "resources/CodeTracer.ico",
            "LICENSE",
            "src/ct/version.nim"
          ],
          extraOutputs = @["non-nix-build/CodeTracer-Setup.exe"],
          after = @[windowsApp])
        target("windows-installer", windowsInstaller)

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
