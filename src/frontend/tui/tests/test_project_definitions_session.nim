## test_project_definitions_session.nim — a terminal session reads the
## checkout it opens, and a user sees what it read.
##
## Project-Definitions.md: "Let a repository teach CodeTracer about itself."
## Until this suite no shipped front-end called the loader. Every case below
## goes through the product's own path: a REAL program recorded by the REAL
## Python recorder (`ct record`) from a scratch checkout that carries a real
## `.codetracer/`, replayed by a real `replay-server`, opened by
## `openTuiSession` with the checkout as the runtime's project root, and read
## back from the panes' own models after `TuiSession.refresh` — the call
## `main.nim` makes.
##
## Asserted:
##
##   * the checkout's point collection lands in the session's point list, in
##     the Points pane, and in the editor gutter — with the point whose anchor
##     no longer resolves REPORTED as a row rather than dropped, and every row
##     carrying a stable id;
##   * the checkout's visualiser renders the recorded value in the Variables
##     pane, and the recorded program's OWN visualiser function (§5.1
##     mechanism 1, replayed from the trace) outranks it for the value it was
##     called with — while a value it never saw still gets the declaration;
##   * `:project` shows the user what was read;
##   * a value pinned to the scratchpad re-renders when the author saves the
##     visualiser file (the authoring loop's live preview), and two pinned
##     samples are compared the way `.codetracer/scratchpad.toml` selects;
##   * the project's code is NOT run on open, the status line says so,
##     `:project review` shows the trust disclosure, `:project grant` grants
##     exactly what was shown, and the granted visualiser then renders.
##
## WAITS ON STATE, NEVER ON TIME. The live-preview case drives the idle tick
## (`pumpDefinitions`) with a synthetic clock and loops until the row changes,
## bounded by a count rather than a stopwatch.
##
## NO MOCKS. `CODETRACER_USER_ROOT` points at a scratch directory so no case
## reads or writes the user's own trust ledger; it is the launcher's
## documented override, not a stand-in.

import std/[os, osproc, sequtils, strutils, tables, unittest]

import codetracer_embed
import backend/stdio_backend
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/variables
import ../app/views/point_list
import ../app/views/source_pane
import ../app/views/gutter
import ../app/views/scratchpad_pane
import ../app/views/context_menu
import ../host/tui_session
import ./fixtures/fixture_provider
import ../../../common/project_wasm_fixtures
import ../../../ct/launch/project_trust_store

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 160
  Rows = 48
  PumpClockMs = 60_000

const Points = """
schema = "codetracer.points.v1"

[[collection]]
name = "hot path"
enabled = true

[[collection.point]]
kind = "breakpoint"
path = "main.py"
anchor = "total = m[0] * k"

[[collection.point]]
kind = "tracepoint"
path = "main.py"
anchor = "this line is not in the program"
expression = "x"
"""

const VisualisersV1 = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Tuple"
summary = "a pair"
"""

const VisualisersV2 = """
schema = "codetracer.visualisers.v1"

[[visualiser]]
match = "Tuple"
summary = "another pair"
"""

const Scratchpad = """
schema = "codetracer.scratchpad.v1"

[[diff]]
match = "Int"
algorithm = "numeric-tolerance"
tolerance = "2"
"""

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc lineOf(path, needle: string): int =
  var i = 0
  for l in readFile(path).splitLines():
    inc i
    if needle in l: return i
  -1

type Checkout = object
  root: string
  trace: string
  userRoot: string

proc recordCheckout(name: string; extra: proc(root: string) = nil): Checkout =
  ## A scratch checkout with the program and a `.codetracer/`, recorded there.
  let base = getTempDir() / ("ct-projdefs-" & name & "-" &
                             $getCurrentProcessId())
  removeDir(base)
  result.root = base / "checkout"
  result.userRoot = base / "userroot"
  createDir(result.root / ".codetracer")
  createDir(result.userRoot)
  putEnv("CODETRACER_USER_ROOT", result.userRoot)
  copyFile(repoRoot() / "test-programs/project_definitions/main.py",
           result.root / "main.py")
  writeFile(result.root / ".codetracer/points.toml", Points)
  writeFile(result.root / ".codetracer/visualisers.toml", VisualisersV1)
  writeFile(result.root / ".codetracer/scratchpad.toml", Scratchpad)
  if not extra.isNil: extra(result.root)
  let recDir = base / "rec"
  let cmd = quoteShell(fixture_provider.findCtBinary()) & " record -o " & quoteShell(recDir) &
            " " & quoteShell(result.root / "main.py")
  let (output, code) = execCmdEx(cmd)
  checkpoint("ct record: " & output)
  doAssert code == 0, "ct record failed: " & output
  result.trace = recDir
  if not isUsableTraceDir(recDir):
    for kind, p in walkDir(recDir):
      if kind == pcDir and isUsableTraceDir(p):
        result.trace = p

proc open(c: Checkout; rt: TuiRuntime): TuiSession =
  rt.app.projectRoot = c.root
  result = openTuiSession(c.trace, viewportHeight = Rows - 6,
                          bound = DapReadBound(timeoutMs: PumpClockMs,
                                               interruptFd: -1))
  result.setViewportHeight(rt.sourcePaneRows())
  result.refresh(rt)

proc goTo(s: TuiSession; rt: TuiRuntime; path: string; line: int;
          behaviour = "forward") =
  s.session.sourceLineJump(path, line, behaviour)
  s.refresh(rt)

proc valueOf(rt: TuiRuntime; name: string): string =
  ## What the Variables pane shows for `name`, through the pane's own
  ## rendering (`fullValueOf`, the checkout's visualisers applied).
  let model = rt.app.variables
  for row in model.paneRows():
    if row.kind == vrkVariable and row.node.name == name:
      return model.fullValueOf(row.node)
  "<no " & name & ">"

proc pin(s: TuiSession; rt: TuiRuntime; name: string) =
  var o = RuntimeOutcome(repaint: true)
  o.paneClick = PaneClickRequest(kind: pcScratchpadAdd,
                                 values: @[(name, rt.valueOf(name))])
  s.applyOutcome(rt, o)

proc scratchpadRow(rt: TuiRuntime; name: string): string =
  for r in rt.app.scratchpad.rows:
    if r.expression == name: return r.value
  "<no row " & name & ">"

suite "a terminal session reads the checkout it opens":

  let prereq = resolveFixture(pythonScriptSpec("project_definitions"))

  test "collections, visualisers, the program's own visualiser, :project":
    if prereq.outcome == foMissingPrereq:
      let message = missingPrereqMessage(prereq.spec, prereq.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      skip()
    else:
      let c = recordCheckout("open")
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = c.open(rt)
      defer: s.close()
      let main = c.root / "main.py"
      let anchorLine = lineOf(main, "total = m[0] * k")
      ck anchorLine > 0

      # --- the point list ---------------------------------------------------
      let rows = s.session.session.store.pointList.rows.val
      var collected = newSeq[typeof(rows[0])]()
      for r in rows:
        if r.collection == "hot path": collected.add r
      checkpoint("rows: " & $rows)
      # BOTH points — the resolved one and the one whose anchor is gone.
      ck collected.len == 2
      var bp, tp = -1
      for i, r in collected:
        if r.kind == "breakpoint": bp = i
        if r.kind == "tracepoint": tp = i
      ck bp >= 0 and tp >= 0
      if bp >= 0 and tp >= 0:
        ck collected[bp].line == anchorLine
        ck collected[bp].path == main
        ck collected[bp].enabled
        ck collected[tp].line == 0
        ck collected[tp].resolution != "resolved"
      for r in collected: ck r.id.startsWith("collection:hot path:")
      # The Points pane lists both, the unresolved one included.
      var paneTexts: seq[string] = @[]
      for r in rt.app.points.rows: paneTexts.add r.rowText()
      checkpoint("points pane: " & $paneTexts)
      ck paneTexts.len == 2
      var boundShown = false
      for t in paneTexts:
        if t.startsWith("breakpoint main.py:" & $anchorLine & " [hot path]"):
          boundShown = true
      ck boundShown
      var unresolvedShown = false
      for t in paneTexts:
        if t.startsWith("tracepoint main.py:? [hot path]"): unresolvedShown = true
      ck unresolvedShown

      # --- the collection's breakpoint is ARMED: the replay stops on it -----
      s.session.continueForward()
      s.refresh(rt)
      ck rt.app.source.executionLine == anchorLine
      # The gutter marks it, and the row is still the collection's.
      ck rt.app.source.markFor(anchorLine) == gmBreakpoint
      var stillCollected = false
      for r in s.session.session.store.pointList.rows.val:
        if r.line == anchorLine and r.collection == "hot path":
          stillCollected = true
      ck stillCollected

      # --- visualisers, at a stop where every Matrix is alive ---------------
      s.goTo(rt, main, lineOf(main, "print(label, t, n[0], d)"))
      checkpoint("m = " & rt.valueOf("m") & ", n = " & rt.valueOf("n") &
                 ", locals = " & $rt.app.variables.paneRows().len)
      # `m` was handed to the program's own `codetracer_visualise`, which
      # outranks every declaration; `n` never was, so the declaration draws it.
      ck rt.valueOf("m") == "a 3 by 4 matrix"
      ck rt.valueOf("n") == "a pair"

      # --- :project ---------------------------------------------------------
      discard rt.typeLine("project")
      ck rt.app.content.open
      ck rt.app.content.title == "PROJECT DEFINITIONS"
      ck "collection 'hot path'" in rt.app.content.text
      ck "program:codetracer_visualise" in rt.app.content.text
      rt.app.content.open = false

  test "the scratchpad previews an edited visualiser and compares samples":
    if prereq.outcome == foMissingPrereq:
      skip()
    else:
      let c = recordCheckout("preview")
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = c.open(rt)
      defer: s.close()
      let main = c.root / "main.py"
      s.goTo(rt, main, lineOf(main, "print(label, t, n[0], d)"))
      s.pin(rt, "n")
      ck rt.scratchpadRow("n") == "a pair"

      # SAVE AN EDIT. The idle tick sees it and the pinned value re-renders.
      writeFile(c.root / ".codetracer/visualisers.toml", VisualisersV2)
      var clock = 1_000_000'i64
      var changed = false
      for _ in 0 ..< 50:
        clock += 1000
        if s.pumpDefinitions(rt, clock):
          changed = true
          break
      ck changed
      ck rt.scratchpadRow("n") == "another pair"
      ck rt.valueOf("n") == "another pair"

      # TWO SAMPLES OF ONE EXPRESSION, compared the way scratchpad.toml says.
      # Back into `drift`'s loop: its last pass, then the one before it.
      let loop = lineOf(main, "x = x + 1")
      s.goTo(rt, main, loop, "backward")
      let first = rt.valueOf("x")
      s.pin(rt, "x")
      s.goTo(rt, main, loop, "backward")
      let second = rt.valueOf("x")
      checkpoint("x: " & first & " then " & second)
      ck first != second
      s.pin(rt, "x")
      let row = rt.scratchpadRow("x")
      checkpoint("row: " & row)
      ck "= equal by numeric-tolerance 2" in row
      ck ".codetracer/scratchpad.toml#0" in row

  test "the project's code runs only after the user reviewed and granted it":
    if prereq.outcome == foMissingPrereq:
      skip()
    else:
      let c = recordCheckout("trust", proc(root: string) =
        writeFile(root / ".codetracer/visualisers.wasm", echoLengthModule()))
      let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
      let s = c.open(rt)
      defer: s.close()
      let main = c.root / "main.py"
      # The status line says the code was NOT run, and how to decide.
      checkpoint("status: " & rt.app.notification)
      ck "ships code (.codetracer/visualisers.wasm) that was NOT run" in
         rt.app.notification
      ck ":project review" in rt.app.notification
      s.goTo(rt, main, lineOf(main, "print(label, t, n[0], d)"))
      let before = rt.valueOf("t")
      ck before == "6"

      # A grant with nothing reviewed is refused.
      discard rt.typeLine("project grant")
      ck "nothing was reviewed" in rt.app.notification
      ck s.definitions.defs.executable.definitions.len == 0

      # The review shows the disclosure, naming the file, the checkout and the
      # digest of the bytes on disk.
      discard rt.typeLine("project review")
      ck rt.app.content.open
      ck "You are being asked to trust 'visualisers.wasm'" in rt.app.content.text
      ck c.root in rt.app.content.text
      ck contentDigest(echoLengthModule()) in rt.app.content.text
      rt.app.content.open = false

      discard rt.typeLine("project grant")
      checkpoint("grant: " & rt.app.notification)
      ck "granted .codetracer/visualisers.wasm" in rt.app.notification
      s.refresh(rt)
      # `echoLengthModule` answers the length of the value's rendering: the
      # project's code ran, in the sandbox, over the value on screen.
      let after = rt.valueOf("t")
      checkpoint("t after the grant: " & after)
      ck after == "01"

      # Withdrawn, it stops — the held handle re-asks the ledger.
      discard rt.typeLine("project revoke")
      ck "withdrew the grant" in rt.app.notification
      s.refresh(rt)
      ck rt.valueOf("t") == "6"

  test "assertion count":
    echo "CHECKS: ", CHECKS
