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
  # In the Electron main process (index.js), use full paths derived from
  # CODETRACER_PREFIX so that child_process.spawn works on all platforms
  # (bare names require ct/db-backend-record to be on PATH, which is not
  # guaranteed on Windows where there is no Nix profile).
  let
    codetracerExe* = codetracerExeDir / "bin" / "ct"
    dbBackendRecordExe* = codetracerExeDir / "bin" / "db-backend-record"
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
  # (additional note: it is a workaround for dev/some cases: TODO think more)
  ctRemoteExe* = codetracerExeDir / "bin" / "ct-remote"
  # External tools - use findTool (PATH lookup)
  bashExe* = when not defined(js): findTool("bash") else: codetracerPrefix / "bin" / "bash"
  taskProcessExe* = codetracerPrefix / "bin" / "task_process"
  python3Path* = when not defined(js): findTool("python3") else: codetracerPrefix / "bin" / "python3"

  rubyExe* = env.get("CODETRACER_RUBY_EXE_PATH",
    when not defined(js): findTool("ruby") else: codetracerPrefix / "bin" / "ruby")
  rubyRecorderPath* = env.get("CODETRACER_RUBY_RECORDER_PATH",
    when not defined(js): findTool("codetracer-ruby-recorder") else: codetracerPrefix / "bin" / "codetracer-ruby-recorder")

  smallExe* = codetracerPrefix / "bin" / "small-lang"
  noirExe* = env.get(
    "CODETRACER_NOIR_EXE_PATH",
    when defined(js):
      bundledNargoPath
    else:
      findTool("nargo"))
  wazeroExe* = env.get("CODETRACER_WASM_VM_PATH",
    when not defined(js): findTool("wazero") else: codetracerPrefix / "bin" / "wazero")
  dbBackendExe* = codetracerPrefix / "bin" / "db-backend"
  backendManagerExe* = codetracerPrefix / "bin" / "backend-manager"
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


  let DB_FOLDERS* = @[codetracerTraceDir, codetracerTestDir]
  when not defined(serverCI):
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "trace_index.db")
  else:
    let DB_PATHS* = DB_FOLDERS.mapIt(it / "index.db")
