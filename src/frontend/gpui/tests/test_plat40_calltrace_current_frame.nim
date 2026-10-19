## test_plat40_calltrace_current_frame.nim — **TIER 3 OVER THE CALL TRACE'S
## CURRENT-FRAME MARKER: `PLAT35-F2`.**
##
## Run (needs the real `isonim-gpui` shim at the baked path and the built
## binary, like every suite that reads `--report-window-plan`):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_plat40_calltrace_current_frame.nim
##
## ## The finding, and what was re-measured
##
## `PLAT35-F2`: *"the call-trace pane lists frames and marks none as current
## — no highlight, caret or weight difference"*, sharpened at iteration 3 to
## *"a marker now exists in the tree and is on the wrong row in every
## scenario"*. Its two measured halves were, at `73e8c3dc4`:
##
##   * exactly one row carried `data-highlighted: true` and it was ALWAYS
##     `data-option-index 0` (`<toplevel> #0`) while the execution line was
##     1 / 44 / 56 / 110 / 113 / 44 — *"a resting list cursor"*; and
##   * six independent readers saw no visual difference at all, so the
##     attribute drew nothing either.
##
## **NEITHER HALF REPRODUCES AT `42655fd72`**, and the reason is datable:
## `84bb71050` (*"feat(tui,gpui): session tabs, call trace, footer and drop
## zones as the desktop draws them"*, PLAT-49 part B) landed AFTER iteration
## 3's `73e8c3dc4` and replaced the vocabulary `List` the pane used to draw
## with `leaves.renderCallTrace`. Re-measured over all seven
## `scenarios.json` plans at this revision: `data-highlighted` occurs **zero**
## times, `data-call-selected` occurs 29 times with **exactly one** `true`,
## and that one is `data-call-index` **2** on `returned-calltrace` and
## `continued-event-log` and **1** on the other five — so the marker moves
## with the stop instead of resting on row 0. It is drawn, too:
## `bg: #333333` on the row (the design system's active-row token) and
## `font-weight: bold` on the callee and its index.
##
## So this suite does not gate a fix made here. **It gates the behaviour
## against coming back**, which is the thing iteration 3's reading could not
## do: the rule that decides which row is current — `calltrace_vm
## .currentCallOf` — was asserted by NOTHING before this file, which is how
## a marker pinned to row 0 could sit in the ledger for an iteration.
##
## ## §7 / §7b: what each case would be satisfied by if it stood alone
##
## Stated because an assertion that cannot fail is the defect this campaign
## is about, and the specific trap here is named in the finding itself — a
## highlight that exists but always on row 0 passes a naive *"something is
## highlighted"* check.
##
##   1. *a row is marked* — satisfied by a marker on EVERY row, and by one
##      welded to row 0. So the pane case requires the count of marked rows
##      to be exactly one, AND the marked row to be the frame the debugger is
##      in, derived independently (below). Presence alone is asserted
##      nowhere.
##   2. *the marked row is the current frame* — satisfied by reading the
##      product's own answer back out of the product. So the expected callee
##      is derived from **the recorded program's source text**: a line is
##      inside `def F` when it is indented and the nearest preceding
##      column-0 construct is that `def`, and the `def` statement itself and
##      every other column-0 line run at module level (`<__main__>`). That
##      rule is computed here from `test-programs/calc/main.py` and compared
##      against the marked row's callee and the editor's own
##      `data-ct-execution-line` **in the same plan** — a cross-pane
##      correspondence, so a pane that marked a fixed row would have to be
##      wrong about the editor too in order to pass.
##   3. *the marker is drawn* — satisfied by a style nobody can see. So the
##      marked row is required to carry a background the unmarked rows do
##      NOT, and bold callee/index weights the unmarked rows do NOT; both
##      sides of each comparison are read off the same plan.
##   4. *the rule is right* — satisfied by "the last call entered", which is
##      wrong exactly when a call has already returned. That is
##      `currentCallOf`'s own documented trap (*"the last line entered alone
##      would name `mul` while the debugger is back in `main`"*) and it has
##      its own case, driven over constructed `CallLine`s so the already-
##      returned shape is reached deterministically rather than hoped for.
##
## ## The one thing this suite does NOT assert
##
## Pixels. Nothing here opens a window. The frame-level reading is the
## capture lane's (`ci/test/plat35-gpui-capture.sh`) and the tier-4 ledger's.
## What is asserted is the shipped binary's own reported plan at both of
## `scenarios.json`'s viewports.
##
## ## Trap 13 / §29
##
## Every helper that calls `check` is a `template`. The `proc`s return values.

import std/[json, options, os, osproc, streams, strtabs, strutils, tables,
            tempfiles, unittest]

import codetracer_embed

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 257
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  CalcSource = "test-programs/calc/main.py"
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  ModuleFrame = "<__main__>"
    ## What Python's module-level frame is called in the recording, and what
    ## the rule below answers for a column-0 line.
  Viewports = [(1920, 1080), (1440, 900)]
    ## `scenarios.json`'s two, which are the two the finding was measured at.
  CallIndexAttr = "data-call-index"      # `leaves.CallRowAttribute`
  CallSelectedAttr = "data-call-selected" # `leaves.CallSelectedAttribute`
  CallPartAttr = "data-call-part"        # `leaves.CallPartAttribute`
  ExecutionAttr = "data-ct-execution-line" # `leaves.EditorExecutionAttribute`
  PaneAttr = "data-ct-pane"              # `leaves.PaneRoleAttribute`
  HighlightedAttr = "data-highlighted"
    ## The attribute iteration 3 measured, from the vocabulary `List` the
    ## pane no longer draws. Asserted absent **inside the call-trace pane**,
    ## so a regression that reinstated the old path would redden here rather
    ## than quietly pass case 1.
    ##
    ## **SCOPED, and the first draft of this suite was not**: asserted over
    ## the whole plan it went red at 3, because the STATE pane's tab strip
    ## (`Locals` / `Globals` / `Watches`) is a vocabulary `List` whose option
    ## 0 is legitimately highlighted. That is §4 — the instrument measuring
    ## something next to the subject — and it is recorded because the count
    ## it produced, "one highlighted option at index 0", is almost exactly
    ## iteration 3's sentence about a different pane.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                     repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = repo / CalcFixture

# ---------------------------------------------------------------------------
# The expectation, derived from the RECORDED PROGRAM rather than the product
# ---------------------------------------------------------------------------

proc enclosingFrames(path: string): Table[int, string] =
  ## For every 1-based line of a Python source, the name of the frame that
  ## executes it: the enclosing top-level `def`, or `<__main__>`.
  ##
  ## **Raises rather than returning an empty table** — a check whose
  ## instrument is missing has to go red, not quietly pass
  ## (Verification-Harness-Traps §4).
  if not fileExists(path):
    raise newException(IOError,
      "prerequisite missing: " & path & " — the expected callee per line is " &
      "derived from the recorded program's own text, because reading it out " &
      "of the product would agree with the product's own mistake (§30)")
  result = initTable[int, string]()
  var pending = ""   # the innermost top-level def seen
  var current = ""   # the frame an indented line belongs to
  let sourceLines: seq[string] =
    readFile(path).strip(leading = false, chars = {'\n'}).split('\n')
  for i, raw in sourceLines:
    let n = i + 1
    let stripped = raw.strip()
    if raw.startsWith("def ") and "(" in raw:
      # The `def` STATEMENT runs at module level; its body does not.
      pending = raw["def ".len ..< raw.find('(')].strip()
      current = ""
      result[n] = ModuleFrame
    elif stripped.len == 0 or stripped.startsWith("#"):
      result[n] = (if current.len > 0: current else: ModuleFrame)
    elif raw[0] notin {' ', '\t'}:
      pending = ""
      current = ""
      result[n] = ModuleFrame
    else:
      current = pending
      result[n] = (if current.len > 0: current else: ModuleFrame)

let frameOfLine = enclosingFrames(repo / CalcSource)

# ---------------------------------------------------------------------------
# Reading the shipped binary's plan
# ---------------------------------------------------------------------------

var planCache = initTable[string, JsonNode]()

proc windowPlan(width, height: int; ops: string): JsonNode =
  ## The window's root as the shipped binary reports it, at `width`x`height`
  ## after the replay operations `ops`. Cached: one process per distinct
  ## reading, because every case below would otherwise pay for a replay.
  let key = $width & "x" & $height & "|" & ops
  if key in planCache:
    return planCache[key]
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if not dirExists(calc):
    raise newException(IOError, "prerequisite missing: " & calc &
                       " (run 'just test-tui' once)")
  let state = createTempDir("plat40-calltrace-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  # Every other per-user location (trace index, config, caches) of the
  # spawned binary: its own, under this case's directory (common/ct_home).
  env["CODETRACER_HOME"] = state / "ct-home"
  var args = @["--report-window-plan", "--width=" & $width,
               "--height=" & $height]
  if ops.len > 0:
    args.add "--replay-ops=" & ops
  args.add calc
  let errFile = genTempPath("plat40-calltrace-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  planCache[key] = result

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc paneOf(plan: JsonNode; pane: string): JsonNode =
  ## The subtree of the pane whose `data-ct-pane` is `pane`. Nil when the
  ## pane is not in the plan, which the caller asserts against.
  for n in plan.nodesWith(PaneAttr):
    if n.attr(PaneAttr) == pane: return n
  nil

proc callRows(plan: JsonNode): seq[JsonNode] = plan.nodesWith(CallIndexAttr)

proc markedRows(plan: JsonNode): seq[JsonNode] =
  for r in plan.callRows:
    if r.attr(CallSelectedAttr) == "true": result.add r

proc partText(row: JsonNode; kind: string): string =
  for c in row{"children"}.getElems:
    if c.attr(CallPartAttr) == kind: return c.textOf
  ""

proc executionLine(plan: JsonNode): int =
  ## The editor's own execution line in the SAME plan. -1 when no node
  ## carries it, which the caller asserts against rather than defaulting.
  for n in plan.nodesWith(ExecutionAttr):
    let v = n.attr(ExecutionAttr)
    if v.len > 0:
      try: return parseInt(v)
      except ValueError: return -1
  -1

# ---------------------------------------------------------------------------
# Constructed call lines, for the rule
# ---------------------------------------------------------------------------

func cl(index: int64; name: string; depth: int; ticks: uint64): CallLine =
  CallLine(index: index, name: name, depth: depth, rrTicks: ticks)

suite "PLAT-40 / PLAT35-F2: the rule that names the call the debugger is in":

  # `calltrace_vm.currentCallOf` is the rule the terminal marks from
  # (`tui/app/views/call_trace`) and the one GPUI selects from
  # (`native_host.selectCurrentCall`). Before this file nothing asserted it.

  test "the innermost frame of the stack is the current call":
    let lines = @[cl(0, ModuleFrame, 0, 1), cl(1, "main", 1, 2),
                  cl(2, "evaluate", 2, 3)]
    let at = currentCallOf(lines, 3, @["evaluate", "main", ModuleFrame])
    ck at.isSome
    ck at.get == 2'i64

  test "A CALL THAT ALREADY RETURNED IS NOT CURRENT — the rule's own trap":
    # `mul` is entered before the tick and has returned; the debugger is back
    # in `main`. "The last line entered" would name `mul`, which is the
    # mistake the rule exists to avoid and the one a naive marker makes.
    let lines = @[cl(0, ModuleFrame, 0, 1), cl(1, "main", 1, 2),
                  cl(2, "mul", 2, 3)]
    let at = currentCallOf(lines, 9, @["main", ModuleFrame])
    ck at.isSome
    ck at.get == 1'i64
    ck at.get != 2'i64

  test "depth disambiguates two frames of the same name (recursion)":
    let lines = @[cl(0, ModuleFrame, 0, 1), cl(1, "fact", 1, 2),
                  cl(2, "fact", 2, 3), cl(3, "fact", 3, 4)]
    ck currentCallOf(lines, 9, @["fact", "fact", ModuleFrame]).get == 2'i64
    ck currentCallOf(lines, 9, @["fact", "fact", "fact", ModuleFrame]).get ==
       3'i64

  test "a call entered after the tick is never current":
    let lines = @[cl(0, ModuleFrame, 0, 1), cl(1, "main", 1, 2),
                  cl(2, "late", 2, 100)]
    let at = currentCallOf(lines, 5, @["main", ModuleFrame])
    ck at.isSome
    ck at.get == 1'i64

  test "with no stack the rule falls back to the last call entered":
    let lines = @[cl(0, ModuleFrame, 0, 1), cl(1, "main", 1, 2),
                  cl(2, "mul", 2, 3)]
    let at = currentCallOf(lines, 9, @[])
    ck at.isSome
    ck at.get == 2'i64

  test "no line qualifies and no fallback applies: none":
    let lines = @[cl(0, ModuleFrame, 0, 50)]
    ck currentCallOf(lines, 1, @["nosuch"]).isNone
    ck currentCallOf(@[], 1, @["main"]).isNone

  test "the derived expectation agrees with the recorded program's shape":
    # The instrument for the cases below, checked against the program whose
    # lines the finding quotes. A `def` statement runs at module level; its
    # body runs in the function.
    ck frameOfLine.len == 116
    ck frameOfLine[1] == ModuleFrame     # the shebang
    ck frameOfLine[44] == ModuleFrame    # `def div(left, right):` itself
    ck frameOfLine[45] == "div"          # its body
    ck frameOfLine[56] == ModuleFrame    # inside the OPERATIONS dict literal
    ck frameOfLine[110] == "main"        # `results.append(value)`
    ck frameOfLine[113] == "main"        # `return results`
    ck frameOfLine[116] == ModuleFrame   # the `main()` call

suite "PLAT-40 / PLAT35-F2: the pane marks the current frame, and draws it":

  for (w, h) in Viewports:
    let vp = $w & "x" & $h

    test "at " & vp & " EXACTLY ONE call row is marked, and none is `data-highlighted`":
      # Not "a row is marked": a marker on every row satisfies that and is
      # the §7 trap this case is written against.
      for ops in ["", "stepIn=6", "stepIn=21,stepOut=1"]:
        let plan = windowPlan(w, h, ops)
        let rows = plan.callRows
        checkpoint(vp & " ops='" & ops & "' rows=" & $rows.len &
                   " marked=" & $plan.markedRows.len)
        ck rows.len > 1
        ck plan.markedRows.len == 1
        # The attribute iteration 3 measured belongs to a path the pane no
        # longer draws; if it comes back, so does the defect. Scoped to the
        # call-trace pane — see `HighlightedAttr`.
        let ctPane = plan.paneOf("calltrace")
        ck not ctPane.isNil
        ck ctPane.nodesWith(HighlightedAttr).len == 0

    test "at " & vp & " the marked row IS the frame the execution line is in":
      # The correspondence, not the presence — and the expected callee comes
      # from the recorded program's text, not from the product.
      for ops in ["", "stepIn=6", "stepIn=21,stepOut=1"]:
        let plan = windowPlan(w, h, ops)
        let line = plan.executionLine
        ck line > 0
        ck frameOfLine.hasKey(line)
        let expected = frameOfLine[line]
        let marked = plan.markedRows
        ck marked.len == 1
        let callee = marked[0].partText("callee")
        checkpoint(vp & " ops='" & ops & "' line=" & $line &
                   " expected=" & expected & " marked=" & callee &
                   " index=" & marked[0].attr(CallIndexAttr))
        ck callee == expected

    test "at " & vp & " the marked row is DRAWN differently from the others":
      # The finding's second half: the attribute drew nothing. Both sides of
      # every comparison are read off the same plan.
      let plan = windowPlan(w, h, "stepIn=21,stepOut=1")
      let marked = plan.markedRows
      ck marked.len == 1
      let row = marked[0]
      ck row.style("bg").len > 0
      ck row.partText("callee").len > 0
      # Its callee and index carry weight; an unmarked row's do not.
      var boldOnMarked = 0
      for c in row{"children"}.getElems:
        if c.attr(CallPartAttr) in ["callee", "index"] and
           c.style("font_weight") == "bold":
          inc boldOnMarked
      checkpoint(vp & " bold parts on the marked row " & $boldOnMarked)
      ck boldOnMarked == 2
      var others = 0
      for r in plan.callRows:
        if r.attr(CallSelectedAttr) == "true": continue
        inc others
        ck r.style("bg").len == 0
        for c in r{"children"}.getElems:
          if c.attr(CallPartAttr) in ["callee", "index"]:
            ck c.style("font_weight") != "bold"
      ck others > 1

    test "at " & vp & " the marker MOVES with the stop rather than resting":
      # Iteration 3's measurement was a marker always on index 0. Two stops
      # in different frames must not mark the same row, and neither may be
      # the row the stale reading named.
      let entry = windowPlan(w, h, "")
      let inMain = windowPlan(w, h, "stepIn=21,stepOut=1")
      let a = entry.markedRows
      let b = inMain.markedRows
      ck a.len == 1
      ck b.len == 1
      let ia = a[0].attr(CallIndexAttr)
      let ib = b[0].attr(CallIndexAttr)
      checkpoint(vp & " entry marks #" & ia & ", in main marks #" & ib)
      ck ia != ib
      ck b[0].partText("callee") == "main"
      ck entry.executionLine != inMain.executionLine

suite "PLAT-40 / PLAT35-F2: every case in this file ran":

  test "the assertion count is the one this file declares":
    checkpoint("counted " & $CHECKS & ", expected " & $ExpectedAssertions)
    doAssert CHECKS == ExpectedAssertions,
      "this suite's assertion count moved: counted " & $CHECKS &
      ", declared " & $ExpectedAssertions &
      ". A case that stopped running is not a case that passed."
