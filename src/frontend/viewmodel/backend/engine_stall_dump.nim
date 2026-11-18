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
## non-voluntary context switches — `wchan`, and per thread `stat`, `wchan`,
## `syscall` and, where the kernel lets this user read it, `stack`), and a
## backtrace of every thread (`gdb -batch -ex "thread apply all bt"`, or
## `eu-stack`, whichever is on PATH). A host starved at the same moment shows
## in the job's memory samples.
##
## THE /proc PART IS THE FLOOR. A backtrace needs a debugger on PATH and
## ptrace permission, and a CI lane has had neither ("(eu-stack is not on
## PATH)"). Each thread's `syscall` line still names the call it is blocked
## in and its arguments (a `read` on fd 0 is a server waiting for a request;
## a `futex` is a lock), so a dump without a backtrace still says what the
## engine was waiting for.
##
## AND THE ENGINE'S CHILDREN. The replay server does much of its work in
## processes of its own (`ct_native_replay` workers, `rr` and its tracees), and
## a stalled server is often only waiting on one of them: on one stall its flow
## thread sat in a `read` on a worker's socket, and the worker's state, which
## said why, was not in the dump. Every descendant, found through
## `/proc/<pid>/task/*/children`, gets the same status, wait channel and
## per-thread lines. Only the engine itself is attached with a debugger, since
## a tracee under `rr` cannot be attached again. The walk is bounded by
## `MaxDescendants` and by the same `ToolTimeoutSeconds`.
##
## BOUNDED AND SILENT ON FAILURE: each external tool runs under `timeout`, a
## file that cannot be read is noted and skipped, and nothing here raises —
## the stall's own error is what the caller reports.

import std/[monotimes, os, osproc, strutils, times]

const
  StallDiagnosticsEnvVar* = "CODETRACER_STALL_DIAGNOSTICS_DIR"
    ## The directory a stall's dump goes to; unset (the default), nothing is
    ## written. The test lanes set it under `test-logs/`, which CI uploads.
  ToolTimeoutSeconds = 20
  MaxDescendants = 64
    ## A fork bomb is not a reason for the dump to never finish.

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

proc threadsText(proc0: string): string =
  ## Each thread's `stat`, `wchan`, `syscall` and, where readable, `stack`.
  try:
    for kind, path in walkDir(proc0 / "task"):
      let tid = path.extractFilename
      result.add tid & " stat: " & readOr(path / "stat").strip() & "\n"
      result.add tid & " wchan: " & readOr(path / "wchan").strip() & "\n"
      result.add tid & " syscall: " & readOr(path / "syscall").strip() & "\n"
      let stack = readOr(path / "stack").strip()
      if stack.len > 0:
        result.add tid & " stack:\n" & stack & "\n"
  except CatchableError as e:
    result.add "(task list unreadable: " & e.msg & ")\n"

proc childrenOf(pid: int): seq[int] =
  ## The direct children of every thread of `pid`.
  try:
    for kind, path in walkDir("/proc" / $pid / "task"):
      let text =
        try: readFile(path / "children")
        except CatchableError: ""
      for token in text.splitWhitespace:
        try: result.add parseInt(token)
        except ValueError: discard
  except CatchableError:
    discard

proc descendantsOf*(pid: int): seq[(int, int)] =
  ## Every descendant of `pid` as (pid, parent), breadth first, at most
  ## `MaxDescendants`, within `ToolTimeoutSeconds`.
  let deadline = getMonoTime() + initDuration(seconds = ToolTimeoutSeconds)
  var frontier = @[pid]
  while frontier.len > 0 and result.len < MaxDescendants and
        getMonoTime() < deadline:
    var next: seq[int]
    for parent in frontier:
      for child in childrenOf(parent):
        if result.len >= MaxDescendants: break
        result.add (child, parent)
        next.add child
    frontier = next

proc engineStateText*(pid: int; reason: string): string =
  ## The dump's text, for `pid`, headed by `reason` (the stall's message).
  let proc0 = "/proc" / $pid
  result = section("engine stall", "pid " & $pid & " at " &
                   $now().utc & "\n" & reason)
  result.add section("status", readOr(proc0 / "status"))
  result.add section("wchan", readOr(proc0 / "wchan"))
  result.add section("threads", threadsText(proc0))
  let backtrace =
    if findExe("gdb").len > 0:
      runTool(@["gdb", "-p", $pid, "-batch", "-ex", "thread apply all bt"])
    else:
      runTool(@["eu-stack", "-p", $pid])
  result.add section("backtrace", backtrace)
  let descendants = descendantsOf(pid)
  result.add section("descendants", $descendants.len &
    (if descendants.len >= MaxDescendants:
       " (the first " & $MaxDescendants & ")"
     else: ""))
  for (child, parent) in descendants:
    let childProc = "/proc" / $child
    let name = readOr(childProc / "comm").strip()
    result.add section("descendant " & $child & " (" & name & ") of " &
                       $parent,
      readOr(childProc / "status").strip() & "\n" &
      "wchan: " & readOr(childProc / "wchan").strip() & "\n" &
      threadsText(childProc))

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
