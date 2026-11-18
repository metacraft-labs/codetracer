## viewmodel/backend/engine_stall_dump.nim — what the engine was doing when it
## stalled.
##
## `DapStdioBackend` gives up on a `replay-server` that sends nothing for its
## per-message budget (`DapStalledError`). On a CI runner that has so far left
## two questions open — was the engine hung, or only starved on a loaded
## machine? — because the process was gone by the time anyone could look, and
## its stderr was empty.
##
## When `StallDiagnosticsEnvVar` names a directory, the backend calls
## `dumpEngineState` with the engine's pid BEFORE anything tears the engine
## down, and the file written there answers both: the kernel's view of the
## process and of each thread (`/proc/<pid>/status` — State, the voluntary and
## non-voluntary context switches — `wchan`, `task/*/stat`, `task/*/wchan`),
## and a backtrace of every thread (`gdb -batch -ex "thread apply all bt"`, or
## `eu-stack`, whichever is on PATH). A host starved at the same moment shows
## in the job's memory samples.
##
## BOUNDED AND SILENT ON FAILURE: each external tool runs under `timeout`, a
## file that cannot be read is noted and skipped, and nothing here raises —
## the stall's own error is what the caller reports.

import std/[os, osproc, strutils, times]

const
  StallDiagnosticsEnvVar* = "CODETRACER_STALL_DIAGNOSTICS_DIR"
    ## The directory a stall's dump goes to; unset (the default), nothing is
    ## written. The test lanes set it under `test-logs/`, which CI uploads.
  ToolTimeoutSeconds = 20

proc section(title, body: string): string =
  "== " & title & "\n" & body.strip(leading = false) & "\n\n"

proc readOr(path: string): string =
  try: readFile(path)
  except CatchableError as e: "(unreadable: " & e.msg & ")"

proc runTool(args: seq[string]): string =
  ## `args` under `timeout`, its output, or why there is none.
  if findExe(args[0]).len == 0:
    return "(" & args[0] & " is not on PATH)"
  try:
    let (output, code) = execCmdEx(
      "timeout " & $ToolTimeoutSeconds & " " & quoteShellCommand(args))
    output & (if code != 0: "\n(exit " & $code & ")" else: "")
  except CatchableError as e:
    "(" & args[0] & " failed: " & e.msg & ")"

proc engineStateText*(pid: int; reason: string): string =
  ## The dump's text, for `pid`, headed by `reason` (the stall's message).
  let proc0 = "/proc" / $pid
  result = section("engine stall", "pid " & $pid & " at " &
                   $now().utc & "\n" & reason)
  result.add section("status", readOr(proc0 / "status"))
  result.add section("wchan", readOr(proc0 / "wchan"))
  var tasks = ""
  try:
    for kind, path in walkDir(proc0 / "task"):
      tasks.add path.extractFilename & " stat: " &
                readOr(path / "stat").strip() & "\n"
      tasks.add path.extractFilename & " wchan: " &
                readOr(path / "wchan").strip() & "\n"
  except CatchableError as e:
    tasks.add "(task list unreadable: " & e.msg & ")\n"
  result.add section("threads", tasks)
  let backtrace =
    if findExe("gdb").len > 0:
      runTool(@["gdb", "-p", $pid, "-batch", "-ex", "thread apply all bt"])
    else:
      runTool(@["eu-stack", "-p", $pid])
  result.add section("backtrace", backtrace)

proc dumpEngineState*(pid: int; reason: string): string =
  ## Write `engineStateText` into `StallDiagnosticsEnvVar`'s directory and
  ## answer the file's path; "" when the variable is unset or nothing could
  ## be written. Never raises.
  let dir = getEnv(StallDiagnosticsEnvVar, "")
  if dir.len == 0 or pid <= 0:
    return ""
  try:
    createDir(dir)
    let path = dir / ("engine-stall-" & $pid & "-" &
                      $(epochTime() * 1000).int64 & ".txt")
    writeFile(path, engineStateText(pid, reason))
    path
  except CatchableError:
    ""
