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

const linksPathConst {.strdefine.} = ""

when not defined(js) and defined(ctEntrypoint):
  # echo "ct entrypoint"
  let codetracerExeDir* = getAppDir().parentDir
else:
  # echo "not ct entrypoint: env : ", env.get("NIX_CODETRACER_EXE_DIR")
  let codetracerExeDir* = env.get("NIX_CODETRACER_EXE_DIR", "<unknown>")

when not defined(js) and defined(ctEntrypoint):
  let codetracerPrefix* = env.get("CODETRACER_PREFIX", getAppDir().parentDir)
else:
  let codetracerPrefix* = env.get("CODETRACER_PREFIX", codetracerExeDir)

# binary/lib/artifact paths
# should be same in folder structure
# in tup dev env, nix and packages
var linksPathValue = env.get("LINKS_PATH_DIR",
  if linksPathConst.len > 0:
    linksPathConst
  else:
    when not defined(js) and defined(ctEntrypoint):
      codetracerExeDir
    else:
      ""
)

when defined(js):
  if linksPathValue.len == 0 or linksPathValue == "<unknown>":
    # In renderer processes triggered from tests the launcher may omit LINKS_PATH_DIR,
    # so fall back to the Electron bundle directory if it is available.
    if codetracerExeDir.len > 0 and codetracerExeDir != "<unknown>":
      linksPathValue = codetracerExeDir

let linksPath* = linksPathValue

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

let bundledCtagsPath = linksPath / "bin" / "ctags"
let bundledNargoPath = linksPath / "bin" / "nargo"
when not defined(js):
  let bundledNargoPathWithExeExt = bundledNargoPath & ExeExt

# binary/lib/artifact paths
# should be same in folder structure
# in tup dev env, nix and packages
# when defined(js):
#   echo "linksPath ", linksPath
#   echo "linksPathConst ", linksPathConst
#   echo "codetracerExeDir ", codetracerExeDir

when not defined(pythonPackage):
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
  bashExe* = when not defined(js): findTool("bash") else: linksPath / "bin" / "bash"
  taskProcessExe* = codetracerPrefix / "bin" / "task_process"
  python3Path* = when not defined(js): findTool("python3") else: linksPath / "bin" / "python3"

  rubyExe* = env.get("CODETRACER_RUBY_EXE_PATH",
    when not defined(js): findTool("ruby") else: linksPath / "bin" / "ruby")
  rubyRecorderPath* = env.get("CODETRACER_RUBY_RECORDER_PATH",
    when not defined(js): findTool("codetracer-ruby-recorder") else: linksPath / "bin" / "codetracer-ruby-recorder")

  smallExe* = codetracerPrefix / "bin" / "small-lang"
  noirExe* = env.get(
    "CODETRACER_NOIR_EXE_PATH",
    when defined(js):
      bundledNargoPath
    else:
      findTool("nargo"))
  wazeroExe* = env.get("CODETRACER_WASM_VM_PATH",
    when not defined(js): findTool("wazero") else: linksPath / "bin" / "wazero")
  dbBackendExe* = codetracerPrefix / "bin" / "db-backend"
  backendManagerExe* = codetracerPrefix / "bin" / "backend-manager"
  virtualizationLayersExe* = codetracerPrefix / "bin" / "virtualization-layers"

  cargoExe* = when not defined(js): findTool("cargo") else: linksPath / "bin" / "cargo"

  electronExe* = when not defined(js): findTool("electron") else: linksPath / "bin" / "electron"
  electronIndexPath* = codetracerExeDir / "src" / "index.js"
  userInterfacePath* = codetracerExeDir / "ui.js"
  chromedriverExe* = when not defined(js): findTool("chromedriver") else: linksPath / "bin" / "chromedriver"

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
  scriptExe* = when not defined(js): findTool("script") else: linksPath / "bin" / "script"

  zipExe* = when not defined(js): findTool("zip") else: linksPath / "bin" / "zip"
  unzipExe* = when not defined(js): findTool("unzip") else: linksPath / "bin" / "unzip"
  curlExe* = when not defined(js): findTool("curl") else: linksPath / "bin" / "curl"

when defined(js):
  let nodeExe* = env.get("CODETRACER_NODE_EXE_PATH", linksPath / "bin" / "node")
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
