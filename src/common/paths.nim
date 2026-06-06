import std / [os, strformat]
import env

when not defined(js):
  when defined(windows):
    # Avoid POSIX-only pwd/getpwuid on Windows toolchains.
    let username = env.get("USERNAME", "unknown")
  else:
    import std / posix

    # copied and adapted from https://stackoverflow.com/a/8953445/438099
    let pwd = getpwuid(geteuid())
    let username = pwd.pw_name

  var inUiTest = false
else:
  type
    NodePath* = ref object
      join*: proc: cstring {.varargs.}
      resolve*: proc(path: cstring): cstring
      dirname*: proc(path: cstring): cstring
      basename*: proc(path: cstring): cstring

  when not defined(ctRenderer):
    import std / jsffi

    let nodeOs = require("os")
    # copied and adapted from https://stackoverflow.com/a/40424568/438099
    let username = cast[cstring](nodeOs.userInfo().username)

  else:
    let codetracerExeDirDefault* = ""
    let username = ""

  var inUiTest = false
  when defined(ctRenderer):
    inUiTest = false
  else:
    inUiTest = env.get("CODETRACER_IN_UI_TEST", "") == "1"

when not defined(ctRenderer):
  import std / sequtils

## Compile-time fallback for the runtime-deps prefix. When the nix build
## passes -d:codetracerPrefixConst=<path>, this value is baked into the
## binary/JS so that paths resolve even when CODETRACER_PREFIX is not in
## the process environment (e.g. Electron renderer in the nix package).
const codetracerPrefixConst {.strdefine.} = ""

when not defined(js) and defined(ctEntrypoint):
  # echo "ct entrypoint"
  let codetracerExeDir* = getAppDir().parentDir
else:
  # In non-entrypoint contexts (e.g. Electron renderer), codetracerExeDir is
  # derived from CODETRACER_PREFIX when available, otherwise the compile-time
  # constant, otherwise "<unknown>".
  let codetracerExeDir* = env.get("CODETRACER_PREFIX",
    if codetracerPrefixConst.len > 0: codetracerPrefixConst
    else: "<unknown>")

when not defined(js) and defined(ctEntrypoint):
  let codetracerPrefix* = env.get("CODETRACER_PREFIX", getAppDir().parentDir)
else:
  let codetracerPrefix* = env.get("CODETRACER_PREFIX",
    if codetracerPrefixConst.len > 0: codetracerPrefixConst
    else: codetracerExeDir)

when not defined(js):
  proc findTool*(name: string): string =
    ## Find an external tool on PATH.
    ## Returns the full path, or "" if not found.
    result = findExe(name)

  proc requireTool*(name: string, installHint: string = ""): string =
    ## Find an external tool on PATH, or exit with a helpful error.
    result = findTool(name)
    if result.len == 0:
      var msg = "error: required tool '" & name & "' not found on PATH"
      if installHint.len > 0:
        msg &= "\n  install: " & installHint
      quit(msg, 1)

let bundledCtagsPath = codetracerPrefix / "bin" / "ctags"
let bundledNargoPath = codetracerPrefix / "bin" / "nargo"
when not defined(js):
  let bundledNargoPathWithExeExt = bundledNargoPath & ExeExt

when defined(js) and not defined(ctRenderer):
  # On Windows (no Nix), use full paths so child_process.spawn works without
  # relying on PATH.  On Linux/macOS the Nix wrapper sets PATH to include
  # the codetracer derivation's bin/, but downstream consumers (Playwright
  # GUI test harness, dev shells without the wrapper, direct `ct host`
  # invocations from a Justfile recipe, etc.) drop the wrapper's PATH
  # additions when they spawn ct host as a subprocess — and then any
  # nested `spawn("ct", ...)` for `trace-metadata` fails with ENOENT, the
  # server's startup throws, and the renderer's socket.io transport
  # closes before any CODETRACER:: events get delivered.
  #
  # Resolve to the absolute path when ``codetracerExeDir`` is known and
  # the binary actually exists on disk; fall back to the bare name only
  # when we have no better information.  This keeps the
  # Nix-wrapper-PATH-only happy path working and removes the PATH
  # assumption for everyone else.
  proc resolveCodetracerExe(): cstring =
    when defined(windows):
      cstring(codetracerExeDir / "bin" / "ct")
    else:
      if codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
        let candidate = codetracerExeDir / "bin" / "ct"
        # ``existsFile`` is unavailable on the JS target; ask Node directly.
        proc nodeFsExistsSync(p: cstring): bool {.importjs: "require('fs').existsSync(#)".}
        if nodeFsExistsSync(cstring(candidate)):
          return cstring(candidate)
      cstring("ct")
  proc resolveDbBackendRecordExe(): cstring =
    when defined(windows):
      cstring(codetracerExeDir / "bin" / "db-backend-record")
    else:
      if codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
        let candidate = codetracerExeDir / "bin" / "db-backend-record"
        proc nodeFsExistsSync(p: cstring): bool {.importjs: "require('fs').existsSync(#)".}
        if nodeFsExistsSync(cstring(candidate)):
          return cstring(candidate)
      cstring("db-backend-record")
  let
    codetracerExe* = $resolveCodetracerExe()
    dbBackendRecordExe* = $resolveDbBackendRecordExe()
elif not defined(pythonPackage):
  let
    codetracerExe* = codetracerExeDir / "bin" / "ct"
    dbBackendRecordExe* = codetracerExeDir / "bin" / "db-backend-record"
else:
  let
    codetracerExe* = "ct"
    dbBackendRecordExe* = "db-backend-record"

let
  cTraceSourcePath* = codetracerPrefix / "src" / "trace.c"
  consoleExe* = codetracerPrefix / "bin" / "console"
  # Deprecated: ct-remote is now built into the ct binary natively.
  # Kept for the "ct remote" escape hatch during migration.
  ctRemoteExe* {.deprecated: "ct-remote is now built into ct".} = codetracerExeDir / "bin" / "ct-remote"
  # External tools - use findTool (PATH lookup)
  bashExe* = when not defined(js): findTool("bash") else: codetracerPrefix / "bin" / "bash"
  taskProcessExe* = codetracerPrefix / "bin" / "task_process"
  python3Path* = env.get("CODETRACER_PYTHON_EXE_PATH",
    when not defined(js): findTool("python3") else: codetracerPrefix / "bin" / "python3")

  rubyExe* = env.get("CODETRACER_RUBY_EXE_PATH",
    when not defined(js): findTool("ruby") else: codetracerPrefix / "bin" / "ruby")
  rubyRecorderPath* = env.get("CODETRACER_RUBY_RECORDER_PATH",
    when not defined(js): findTool("codetracer-ruby-recorder") else: codetracerPrefix / "bin" / "codetracer-ruby-recorder")

  noirExe* = env.get(
    "CODETRACER_NOIR_EXE_PATH",
    when defined(js):
      bundledNargoPath
    else:
      findTool("nargo"))
  wazeroExe* = env.get("CODETRACER_WASM_VM_PATH",
    when not defined(js): findTool("wazero") else: codetracerPrefix / "bin" / "wazero")
  # Blockchain/VM recorder binaries — looked up from env vars with fallback to PATH
  cairoRecorderExe* = env.get("CODETRACER_CAIRO_RECORDER_PATH",
    when not defined(js): findTool("codetracer-cairo-recorder") else: codetracerPrefix / "bin" / "codetracer-cairo-recorder")
  midenRecorderExe* = env.get("CODETRACER_MIDEN_RECORDER_PATH",
    when not defined(js): findTool("codetracer-miden-recorder") else: codetracerPrefix / "bin" / "codetracer-miden-recorder")
  moveRecorderExe* = env.get("CODETRACER_MOVE_RECORDER_PATH",
    when not defined(js): findTool("codetracer-move-recorder") else: codetracerPrefix / "bin" / "codetracer-move-recorder")
  solanaRecorderExe* = env.get("CODETRACER_SOLANA_RECORDER_PATH",
    when not defined(js): findTool("codetracer-solana-recorder") else: codetracerPrefix / "bin" / "codetracer-solana-recorder")
  fuelRecorderExe* = env.get("CODETRACER_FUEL_RECORDER_PATH",
    when not defined(js): findTool("codetracer-fuel-recorder") else: codetracerPrefix / "bin" / "codetracer-fuel-recorder")
  circomRecorderExe* = env.get("CODETRACER_CIRCOM_RECORDER_PATH",
    when not defined(js): findTool("codetracer-circom-recorder") else: codetracerPrefix / "bin" / "codetracer-circom-recorder")
  leoRecorderExe* = env.get("CODETRACER_LEO_RECORDER_PATH",
    when not defined(js): findTool("codetracer-leo-recorder") else: codetracerPrefix / "bin" / "codetracer-leo-recorder")
  polkavmRecorderExe* = env.get("CODETRACER_POLKAVM_RECORDER_PATH",
    when not defined(js): findTool("codetracer-polkavm-recorder") else: codetracerPrefix / "bin" / "codetracer-polkavm-recorder")
  tonRecorderExe* = env.get("CODETRACER_TON_RECORDER_PATH",
    when not defined(js): findTool("codetracer-ton-recorder") else: codetracerPrefix / "bin" / "codetracer-ton-recorder")
  cardanoRecorderExe* = env.get("CODETRACER_CARDANO_RECORDER_PATH",
    when not defined(js): findTool("codetracer-cardano-recorder") else: codetracerPrefix / "bin" / "codetracer-cardano-recorder")
  flowRecorderExe* = env.get("CODETRACER_FLOW_RECORDER_PATH",
    when not defined(js): findTool("codetracer-flow-recorder") else: codetracerPrefix / "bin" / "codetracer-flow-recorder")
  evmRecorderExe* = env.get("CODETRACER_EVM_RECORDER_PATH",
    when not defined(js): findTool("codetracer-evm-recorder") else: codetracerPrefix / "bin" / "codetracer-evm-recorder")

  # Python recorder — pip-installed console script from the venv.
  pythonRecorderExe* = when not defined(js): findTool("codetracer-python-recorder") else: codetracerPrefix / "bin" / "codetracer-python-recorder"

  # Shell recorders — the launcher scripts are the entry points.
  # In the nix package they are installed as codetracer-bash-recorder / codetracer-zsh-recorder.
  bashRecorderExe* = when not defined(js): findTool("codetracer-bash-recorder") else: codetracerPrefix / "bin" / "codetracer-bash-recorder"
  zshRecorderExe* = when not defined(js): findTool("codetracer-zsh-recorder") else: codetracerPrefix / "bin" / "codetracer-zsh-recorder"

  # JavaScript/TypeScript recorder — Node.js CLI installed via npm.
  jsRecorderExe* = when not defined(js): findTool("codetracer-js-recorder") else: codetracerPrefix / "bin" / "codetracer-js-recorder"

  dbBackendExe* = codetracerPrefix / "bin" / "replay-server"
  backendManagerExe* = codetracerPrefix / "bin" / "session-manager"
  virtualizationLayersExe* = codetracerPrefix / "bin" / "virtualization-layers"

  cargoExe* = when not defined(js): findTool("cargo") else: codetracerPrefix / "bin" / "cargo"

  electronExe* = when not defined(js): findTool("electron") else: codetracerPrefix / "bin" / "electron"
  electronIndexPath* = codetracerExeDir / "src" / "index.js"
  userInterfacePath* = codetracerExeDir / "ui.js"
  chromedriverExe* = when not defined(js): findTool("chromedriver") else: codetracerPrefix / "bin" / "chromedriver"

when defined(js):
  let ctagsExe* = env.get("CODETRACER_CTAGS_EXE_PATH", bundledCtagsPath)
else:
  let ctagsExe* = env.get("CODETRACER_CTAGS_EXE_PATH", findTool("ctags"))

let cTraceObjectFilePath* = env.get(
  "CODETRACER_C_TRACE_OBJECT_FILE_PATH",
  codetracerPrefix / "lib" / "trace.o")

when defined(ctmacos):
  let codetracerTmpPath* = env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/"
  let codetracerCache* = env.get("HOME") / "Library/Caches/com.codetracer.CodeTracer/cache"
else:
  let tmpFolder = env.get("TMPDIR",
                            env.get("TEMPDIR",
                                    env.get("TEMP",
                                            env.get("TMP",
                                                    "/tmp"
                                            )
                                    )
                            )
  )
  let
    codetracerCache* = tmpFolder / "codetracer/cache"
    codetracerTmpPath* = tmpFolder / "codetracer"

let
  localShellPreloadInstallPath* = codetracerTmpPath / fmt"shell_preload_{username}.so"

var
  # overrideable in local functions !:
  shellPreloadPath* = codetracerPrefix / "lib" / "shell_preload.so"


# other path/exe consts:
#  either universal, or usually development environment-specific
let
  codetracerInstallDir* = when defined(builtWithNix):
    codetracerExeDir # e.g. result/ (from result/)
  else:
    codetracerExeDir.parentDir.parentDir # <top-level>/ (from <top-level>/src/build-debug/)

  nodeModulesPath* = codetracerPrefix / "node_modules"

  codetracerTestDir* = codetracerInstallDir / "src" / "tests"
  codetracerNixResultExe* = codetracerInstallDir / "result" / "bin" / "ct"
  codetracerTestBuildDir* = codetracerExeDir / "tests"
  programDir* = codetracerTestDir / "programs"
  recordDir* = codetracerTestDir / "records"
  testProgramBinariesDir* = codetracerTestDir / "binaries"
  runDir* = codetracerTestBuildDir / "run"
  reportFilesDir* = codetracerTestDir / "report-files"

  # we should load our dependencies from our own codebase if possible
  # e.g. having a python/ruby submodule
  #   eventually we might support various python/ruby paths ..
  #   for now this is easier
  #   note: python/ruby/lua are not currently real submodules
  #   TODO: support them normally

  rubyPath* = codetracerInstallDir / "libs" / "ruby" / "ruby"
  luaPath* = codetracerInstallDir / "libs" / "lua"

  nimcacheDir* = codetracerTmpPath / "codetracer_projects/"
  scriptExe* = when not defined(js): findTool("script") else: codetracerPrefix / "bin" / "script"

  zipExe* = when not defined(js): findTool("zip") else: codetracerPrefix / "bin" / "zip"
  unzipExe* = when not defined(js): findTool("unzip") else: codetracerPrefix / "bin" / "unzip"
  curlExe* = when not defined(js): findTool("curl") else: codetracerPrefix / "bin" / "curl"

when defined(js):
  let nodeExe* = env.get("CODETRACER_NODE_EXE_PATH", codetracerPrefix / "bin" / "node")
else:
  let nodeExe* = env.get("CODETRACER_NODE_EXE_PATH", findTool("node"))

# echo "codetracer exe dir ", codetracerExeDir

when not defined(ctRenderer):
  when not defined(js):
    let home* = getHomeDir()
  else:
    # TODO implement `/`
    let home* = $(cast[cstring](nodeOs.homedir()) & cstring"/")

  let codetracerTraceDir* = home / ".local" / "share" / "codetracer"

  proc recordingFolder*(baseDir: string, recordingId: string): string =
    ## Resolve the on-disk recording folder for ``recordingId`` under
    ## ``baseDir``.  M-REC-7: the folder name is now the bare UUIDv7
    ## (lowercase 36-char hyphenated form) rather than the pre-M-REC-7
    ## ``trace-<int_id>`` / ``trace-<uuid>`` prefix.  See
    ## ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``
    ## §4 ("On-Disk Recording Folder Layout") for the rationale: the
    ## bare UUIDv7 is portable across machines, lex-sorts by creation
    ## time, and lets the SQLite row remain the single source of truth
    ## for human-friendly metadata (program name, date, args).
    ##
    ## Empty / sentinel recording ids are rejected here rather than
    ## silently producing a degenerate ``baseDir/`` path that would
    ## collide with siblings.  Callers must mint a fresh id (via
    ## ``trace_index.newID`` / ``newRecordingId``) before invoking this
    ## helper.
    doAssert recordingId.len > 0,
      "recordingFolder: recording_id must be non-empty (caller must " &
      "mint a UUIDv7 via trace_index.newID / newRecordingId first)"
    baseDir / recordingId

  let DB_FOLDERS* = @[codetracerTraceDir, codetracerTestDir]
  when not defined(serverCI):
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "trace_index.db")
  else:
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "index.db")
