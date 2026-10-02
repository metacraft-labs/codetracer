## test_trace_folder_problem.nim — the terminal front-end's pre-spawn check on
## a trace folder (`host/native_host.traceFolderProblem`) refuses a folder
## whose only trace is a `trace.json` event stream, with the same test-oracle
## message `ct print`, `ct replay` and the debugger give.
##
## Real folders on disk, no mocks: the function under test is a `stat` of the
## folder, so a temp directory holding the files IS the input it sees in use.

import std/[os, strutils, times, unittest]

import ../host/native_host
import ../../../ct/trace/trace_kind   # TestOracleOutputError

var counter = 0

proc freshDir(): string =
  inc counter
  result = getTempDir() / ("ct_tui_folder_problem_" &
    $(epochTime() * 1_000_000.0).int64 & "_" & $counter)
  createDir(result)

suite "traceFolderProblem":
  test "a trace.json-only folder is refused as test-oracle output":
    let dir = freshDir()
    writeFile(dir / "trace.json", "[]")
    writeFile(dir / "trace_paths.json", "[]")
    writeFile(dir / "trace_metadata.json", "{}")
    let problem = traceFolderProblem(dir)
    check TestOracleOutputError in problem
    check (dir / "trace.json") in problem

  test "a folder with a .ct container opens even beside a trace.json":
    let dir = freshDir()
    writeFile(dir / "trace.json", "[]")
    writeFile(dir / "trace.ct", "")
    check traceFolderProblem(dir) == ""

  test "an empty folder is still refused as not a recording":
    let dir = freshDir()
    let problem = traceFolderProblem(dir)
    check problem.len > 0
    check TestOracleOutputError notin problem
