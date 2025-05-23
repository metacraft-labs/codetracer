import std / [os, sequtils, strformat]
import env

when not defined(js):
  import std / posix

  # copied and adapted from https://stackoverflow.com/a/8953445/438099
  let pwd = getpwuid(geteuid())
  let username = pwd.pw_name

  var inUiTest = false
else:
  import jsffi

  type
    NodePath* = ref object
      join*: proc: cstring {.varargs.}
      resolve*: proc(path: cstring): cstring
      dirname*: proc(path: cstring): cstring
      basename*: proc(path: cstring): cstring

  when not defined(ctRenderer):
    let nodeOs = require("os")
    # copied and adapted from https://stackoverflow.com/a/40424568/438099
    let username = cast[cstring](nodeOs.userInfo().username)

    let nodePath = cast[NodePath](require("path"))

  else:
    let codetracerExeDirDefault* = ""
    let username = ""

  var inUiTest = false
  when defined(ctRenderer):
    inUiTest = false
  else:
    inUiTest = env.get("CODETRACER_IN_UI_TEST", "") == "1"

const linksPathConst {.strdefine.} = ""
const pathToNodeModules {.strdefine.} = ""

# binary/lib/artifact paths
# should be same in folder structure
# in tup dev env, nix and packages
let
  linksPath* = env.get("LINKS_PATH_DIR",
    if linksPathConst.len > 0:
      linksPathConst
    else:
      when not defined(js) and defined(ctEntrypoint):
        getAppDir().parentDir
      else:
        ""
  )

# we might call this from a different process, e.g. index, so
# getting this path is not always easy
# (additional note: it is a workaround for dev/some cases: TODO think more)
# also, we mean the more top level folder `<folder1>` where `ct` is in `<folder1>/bin/`
when not defined(js) and defined(ctEntrypoint):
  # echo "ct entrypoint"
  let codetracerExeDir* = getAppDir().parentDir
else:
  # echo "not ct entrypoint: env : ", env.get("NIX_CODETRACER_EXE_DIR")
  let codetracerExeDir* = env.get("NIX_CODETRACER_EXE_DIR", "<unknown>")

# when defined(js):
#   echo "linksPath ", linksPath
#   echo "linksPathConst ", linksPathConst
#   echo "codetracerExeDir ", codetracerExeDir

let
  cTraceSourcePath* = linksPath / "src" / "trace.c"
  consoleExe* = linksPath / "bin" / "console"
  # (additional note: it is a workaround for dev/some cases: TODO think more)
  codetracerExe* = codetracerExeDir / "bin" / "ct"
  bashExe* = linksPath / "bin" / "bash"
  taskProcessExe* = linksPath / "bin" / "task_process"
  python3Path* = linksPath / "bin" / "python3"
  # TODO: tup/nix? => in linksPath / "bin
  rubyExe* = env.get("CODETRACER_RUBY_EXE_PATH", linksPath / "bin" / "ruby" )
  rubyTracerPath* = linksPath / "src" / "trace.rb"
  smallExe* = linksPath / "bin" / "small-lang"
  noirExe* = env.get("CODETRACER_NOIR_EXE_PATH", linksPath / "bin" / "nargo" )
  wazeroExe* = env.get("CODETRACER_WASM_VM_PATH", linksPath / "bin" / "wazero")
  dbBackendExe* = linksPath / "bin" / "db-backend"
  dbBackendRecordExe* = codetracerExeDir / "bin" / "db-backend-record"
  virtualizationLayersExe* = linksPath / "bin" / "virtualization-layers"
  ctagsExe* = linksPath / "bin" / "ctags"

  cargoExe* = linksPath / "bin" / "cargo"

  # TODO make it work
  electronExe* = linksPath / "bin" / "electron"
  electronIndexPath* = codetracerExeDir / "src" / "index.js"
  chromedriverExe* = linksPath / "bin" / "chromedriver"

  cTraceObjectFilePath* = env.get(
    "CODETRACER_C_TRACE_OBJECT_FILE_PATH",
    linksPath / "lib" / "trace.o")


let
  localShellPreloadInstallPath* = fmt"/tmp/shell_preload_{username}.so"


var
  # overrideable in local functions !:
  shellPreloadPath* = linksPath / "lib" / "shell_preload.so"


# other path/exe consts:
#  either universal, or usually development environment-specific
let
  codetracerCache* = "/tmp/codetracer_cache/"
  codetracerTmpPath* = "/tmp/codetracer"
  codetracerInstallDir* = when defined(builtWithNix):
    codetracerExeDir # e.g. result/ (from result/)
  else:
    codetracerExeDir.parentDir.parentDir # <top-level>/ (from <top-level>/src/build-debug/)

  nodeModulesPath* = linksPath / "node_modules"

  # nodeModulesPath* = if pathToNodeModules.len > 0:
  #     pathToNodeModules
  #   else:
  #     codetracerInstallDir / "node_modules"

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

  nimcacheDir* = "/tmp/codetracer_projects/"
  scriptExe* = linksPath / "bin" / "script"
  nodeExe* = linksPath / "bin" / "node"

  zipExe* = linksPath / "bin" / "zip"
  unzipExe* = linksPath / "bin" / "unzip"
  curlExe* = linksPath / "bin" / "curl"

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
