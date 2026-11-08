## fixtures/plat65_nim_project.nim — the Nim project every native suite of
## Nim's compile-time tracing drives, on the terminal and in the GPUI window.
##
## A library the suites import, not a suite.
##
## A REAL NIM PROJECT on a real filesystem: `tracing.nim` with a macro
## (`twice`), a `const` declaration, a `const` section, a `static:` block and
## a `static(expr)`; and `build.nims`, a NimScript file. The suites trace them
## with the REAL patched compiler — codetracer-nim's nimsuggest (`traceExpand`
## / `tracestatic`) and its `nim e --trace` — through the product's own
## route (`host/native_nim_tracer`).
##
## THE STARTING RECORDING is made by the product's own route for an
## evaluation (`NativeNimTracer`, `nim e --trace` over `build.nims`, its
## sources bundled beside it) — a real recording of the project, so the
## window opens on the project's own code and every trace the suite starts
## opens beside it in a new session tab.
##
## PREREQUISITES, named rather than assumed: the trace-enabled nimsuggest
## (`CODETRACER_NIMSUGGEST`), the compiler (`CODETRACER_NIM`, else `nim` on
## the PATH — the dev shell's is codetracer-nim's) and `REPLAY_SERVER_BIN`. A
## suite that finds one missing says `MISSING-PREREQ SKIP:` with which, and
## skips (`missingPrereq`).

import std/[os, strutils, times]

import ../../../viewmodel/host/native_nim_tracer

const
  TracingNim* = """import std/macros

macro twice(body: untyped): untyped =
  result = newStmtList(body, body)

proc compute(n: int): int =
  result = 0
  for i in 1..n:
    result += i * i

const squares = compute(3)

const
  limit = 4
  cubes = compute(limit)

static:
  var acc = 0
  for i in 0..<limit:
    acc += i
  echo "acc=", acc

echo "after"
let folded = static(compute(5))

twice:
  echo squares
"""
  BuildNims* = """proc step(total, i: int): int =
  result = total + i

var total = 0
for i in 1..3:
  total = step(total, i)
echo "total=", total
"""

  # The lines each construct spans, 1-based in `TracingNim` / `BuildNims` —
  # where a recording of it may stop first.
  MacroLines* = 3 .. 4
  ComputeLines* = 6 .. 9
  CubesLine* = 15
  StaticOpenerLine* = 17
  StaticLines* = 18 .. 21
  TwiceLine* = 26
  BuildLines* = 1 .. 7

type
  NimProject* = object
    root*: string
      ## The project folder (`tracing.nim`, `build.nims`).
    recording*: string
      ## The starting recording: `nim e --trace` over `build.nims`.
    state*: string
      ## The suite's own state root (XDG homes, layout, nim-traces).

const
  NimsuggestVar = "CODETRACER_NIMSUGGEST"
  NimVar = "CODETRACER_NIM"
    ## The host's variables (`host/native_nim_tracer`), named here for the
    ## prerequisite messages.

proc toolAt(envVar, name: string): string =
  let v = getEnv(envVar)
  if v.len > 0: (if fileExists(v): v else: "") else: findExe(name)

proc missingPrereq*(): string =
  ## Every missing prerequisite, joined; "" when there are none. nimsuggest
  ## must be NAMED: the one on a stock PATH has no trace queries.
  var parts: seq[string] = @[]
  if getEnv(NimsuggestVar).len == 0 or toolAt(NimsuggestVar, "nimsuggest").len == 0:
    parts.add "the trace-enabled nimsuggest (codetracer-nim's; set " &
              NimsuggestVar & ")"
  if toolAt(NimVar, "nim").len == 0:
    parts.add "the trace-enabled compiler (codetracer-nim's `nim`; set " &
              NimVar & ")"
  if getEnv("REPLAY_SERVER_BIN").len == 0 or
     not fileExists(getEnv("REPLAY_SERVER_BIN")):
    parts.add "replay-server (REPLAY_SERVER_BIN)"
  parts.join("; ")

proc recordEvaluation*(nims, folder: string) =
  ## `nim e --trace` over `nims`, recorded BY THE PRODUCT'S ROUTE
  ## (`NativeNimTracer`, as `Ctrl+K T E` records it — the `.ct` and its
  ## bundled sources), then moved to `folder`. The tracer's state root is
  ## this fixture's own while it runs.
  const StateVar = "CODETRACER_TUI_LAYOUT_DIR"
  let saved = getEnv(StateVar)
  let state = folder & ".state"
  putEnv(StateVar, state)
  try:
    let t = newNativeNimTracer()
    discard t.startNimTrace(NimTraceRequest(action: ntaEval, path: nims,
                                            line: 1, column: 1),
                            readFile(nims).splitLines())
    while t.vm.running:
      if not t.pollNimTrace():
        sleep(50)
    if t.vm.phase != ntpDone:
      raise newException(IOError, "nim e --trace " & nims & ": " &
                         t.vm.message)
    moveDir(t.vm.tracePath, folder)
  finally:
    if saved.len > 0: putEnv(StateVar, saved) else: delEnv(StateVar)
    removeDir(state)

proc writeNimProject*(tag: string): NimProject =
  ## The project in a fresh temporary folder, its starting recording made.
  let base = getTempDir() / ("plat65-" & tag & "-" & $getCurrentProcessId() &
                             "-" & $epochTime().int)
  removeDir(base)
  result.root = base / "project"
  result.state = base / "state"
  createDir(result.root)
  createDir(result.state / "ct-home")
  writeFile(result.state / "ct-home" / ".codetracer-test-home", "")
  writeFile(result.root / "tracing.nim", TracingNim)
  writeFile(result.root / "build.nims", BuildNims)
  result.recording = base / "start"
  recordEvaluation(result.root / "build.nims", result.recording)

proc removeProject*(p: NimProject) =
  removeDir(p.root.parentDir)

proc lineOfText*(text, needle: string): int =
  ## The 1-based line of `text` whose stripped text is `needle`.
  let lines = text.splitLines()
  for i, l in lines:
    if l.strip == needle:
      return i + 1
  raise newException(KeyError, "no line " & needle)
