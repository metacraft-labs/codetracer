## test_m73_gpui_editor_scroll_plan.nim — Pxor-Bugs M73 (codetracer#840) on
## the GPUI window: the Debug-mode editor's rows MOVE under the user's input,
## read off the SHIPPED binary's window plan (`codetracer-gpui
## --report-window-plan --window-ops=…`: the window's own root builder and its
## own pointer and key handlers) over the real `calc` recording against a real
## `replay-server`.
##
## ## What was wrong
##
## GPUI's editor draws `SourceVM`'s window, the same one the terminal's source
## pane draws, and only a stop moved it (`gpui_host.serveWindow`): the vertical
## wheel over the editor was dropped (its arm took `dx` only), the read-only
## caret followed sideways only (`followEditorView`), and CodeTracer-TUI.md
## §4.2's scroll keys (`editor.scroll-line-down` …, `editor.center-on-pointer`)
## had no arm in `runWindowOperation`. So, as in the terminal, a file longer
## than the editor could not be read past the window around the pointer.
##
## ## What each case asserts
##
## The drawn rows (`data-ct-row`, the line each row shows) against the rows at
## rest, and the execution line (`data-ct-pointer` = `eptExecution`) unchanged
## by every gesture:
##
##   * `wheel:editor:3` (three lines of GPUI's wheel over the editor's centre,
##     the editor unfocused): the first drawn line is three later (§4.4);
##     `wheel:editor:-3` after it brings the rows back;
##   * the editor focused by a click on its text, `j` / `Ctrl+Down` / `.`
##     (CUA's read-only rows): a line down, a line down, the pointer centred;
##   * the caret clicked onto the last drawn row and moved one `Down`: the
##     rows follow it by one line (Editor-Pane.md § The caret in a read-only
##     editor);
##   * a breakpoint toggled in the gutter after a wheel keeps the scrolled
##     rows — following the pointer is a stop's, not a refresh's;
##   * the VERTICAL SCRUBBER (Scrollbar-Scrubbers.md §3, the terminal's M73
##     bar on this window): drawn only while the file is taller than the
##     editor, its thumb the window's share of the whole file and following
##     it, the execution line marked, a track press that jumps and a held
##     thumb that scrubs (`vbar:editor:…`) without moving the debugger, and —
##     on `wide_lines` at 600 px, where both bars are drawn — a corner that
##     belongs to neither (§6).
##
## No mocks: the binary, the engine and the recording are the product's.

import replay_prerequisite
import std/[json, math, os, osproc, streams, strtabs, strutils, tempfiles,
            unittest]

import ../../tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 43

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  W = 1440
  H = 1000
  Into = "key:f10,key:f10,key:f10,key:f10,key:f10,key:f10"
    ## Six steps over (F10) into the program before every case's own events,
    ## so the execution line (54 on `calc`) is inside the file with rows on
    ## both sides of it: a case that scrolls a line or centres it then still
    ## draws the pointer, and `.` has something the file's top cannot clamp.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc fixture(prefix: string): string =
  ## The `calc` recording the `tui` lane records on its first run (the one
  ## `test_plat68_gpui_keys_plan.nim` reads).
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

let calc = fixture("calc")
let calcLines = readFile(repo / "test-programs/calc/main.py").splitLines()

proc windowPlan(ops: string; trace: var string; subject = calc; height = H;
                into = Into): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if subject.len == 0:
    raise newException(IOError, "prerequisite missing: the calc tui-fixtures " &
      "recording (the tui lane records it on its first run)")
  let state = createTempDir("m73-gpui-scroll-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  let events = if into.len > 0 and ops.len > 0: into & "," & ops
               elif into.len > 0: into else: ops
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $height]
  if events.len > 0:
    args.add "--window-ops=" & events
  args.add subject
  let errFile = genTempPath("m73-gpui-scroll-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc windowPlan(ops: string; subject = calc; height = H; into = Into): JsonNode =
  var trace = ""
  windowPlan(ops, trace, subject, height, into)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n{"attributes"}.kind == JObject and n["attributes"].hasKey(attribute):
      acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc rowLines(plan: JsonNode): seq[int] =
  ## The line every drawn editor row shows, top to bottom — not the sticky
  ## scope headers drawn over them (`data-ct-sticky-line`).
  for n in plan.nodesWith("data-ct-row"):
    if n.attr("data-ct-sticky-line").len > 0: continue
    try: result.add parseInt(n.attr("data-ct-row"))
    except ValueError: discard

proc firstLine(plan: JsonNode): int =
  let rows = plan.rowLines
  if rows.len == 0: 0 else: rows[0]

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith("data-ct-pointer"):
    if n.attr("data-ct-pointer") == "eptExecution":
      return parseInt(n.attr("data-ct-row"))
  -1

const
  VTrackAttr = "data-ct-editor-vscrollbar"
  VThumbAttr = "data-ct-editor-vscrollbar-thumb"
  VMarkAttr = "data-ct-editor-vscrollbar-mark"
  VMetricAttr = "data-ct-editor-vscroll"
    ## M73: the vertical scrubber's nodes, and its stamped extent (the
    ## horizontal bar's `data-ct-editor-scroll` on the other axis).

proc px(n: JsonNode; key: string): int =
  let v = n{"styles"}{key}.getStr
  if v.endsWith("px"): parseInt(v[0 ..< v.len - 2]) else: -1

proc field(stamp, key: string): int =
  ## One `k=v` of a `;`-separated stamp.
  for part in stamp.split(';'):
    let kv = part.split('=')
    if kv.len == 2 and kv[0] == key: return parseInt(kv[1])
  -1

proc vmetric(plan: JsonNode): string =
  let n = plan.nodesWith(VMetricAttr)
  if n.len == 0: "" else: n[0].attr(VMetricAttr)

proc wideLines(): string =
  ## PLAT-70's `wide_lines` recording: a line wider than any pane.
  let resolved = resolveFixture(FixtureSpec(
    name: "wide_lines", program: "test-programs/wide_lines/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let wide = wideLines()

let rest = windowPlan("")
let restRows = rest.rowLines
let execAtRest = rest.executionLine

suite "M73 (#840): the GPUI editor's rows move under the user's input":

  test "the positive control: the file is longer than the editor, the pointer is drawn":
    checkpoint("rows at rest " & $restRows & ", execution line " & $execAtRest)
    ck restRows.len >= 10
    ck calcLines.len > restRows.len + 12
    ck execAtRest >= restRows[0] and execAtRest <= restRows[^1]

  test "the vertical wheel over the editor moves the rows, and back":
    let down = windowPlan("wheel:editor:3")
    checkpoint("after wheel:editor:3 " & $down.rowLines)
    ck down.firstLine == restRows[0] + 3
    ck down.executionLine == execAtRest
    let back = windowPlan("wheel:editor:3,wheel:editor:-3")
    ck back.rowLines == restRows

  test "j, Ctrl+Down and `.` on the focused read-only editor":
    let at = restRows[2]
    let click = "click:code:" & $at & "@3"
    let j = windowPlan(click & ",key:j")
    checkpoint("after j " & $j.rowLines)
    ck j.firstLine == restRows[0] + 1
    ck j.executionLine == execAtRest
    let jj = windowPlan(click & ",key:j,key:down:control")
    ck jj.firstLine == restRows[0] + 2
    # Far away, then `.`: the pointer centred.
    let away = "wheel:editor:12,wheel:editor:12,wheel:editor:12"
    let centred = windowPlan(click & "," & away & ",key:.")
    let awayRows = windowPlan(click & "," & away).rowLines
    checkpoint("away " & $awayRows & " centred " & $centred.rowLines)
    ck awayRows.len > 0 and (execAtRest < awayRows[0] or
                             execAtRest > awayRows[^1])
    ck centred.executionLine == execAtRest
    let rows = centred.rowLines
    ck rows.len > 0
    # Centred: as many rows above it as below it, give or take one (or the
    # file's top edge, which the window cannot scroll past).
    let above = execAtRest - rows[0]
    let below = rows[^1] - execAtRest
    checkpoint("above " & $above & " below " & $below)
    ck rows[0] == 1 or abs(above - below) <= 2

  test "a caret moved below the last row brings the rows with it":
    let last = restRows[^1]
    let plan = windowPlan("click:code:" & $last & "@3,key:down")
    checkpoint("after the caret left the last row " & $plan.rowLines)
    ck plan.firstLine == restRows[0] + 1
    ck plan.rowLines.len > 0 and plan.rowLines[^1] == last + 1
    ck plan.executionLine == execAtRest

  test "a breakpoint toggled after a wheel keeps the scrolled rows":
    let scrolled = windowPlan("wheel:editor:6")
    let line = scrolled.rowLines[1]
    let plan = windowPlan("wheel:editor:6,click:gutter:" & $line)
    checkpoint("after the gutter click " & $plan.rowLines)
    ck scrolled.firstLine == restRows[0] + 6
    ck plan.rowLines == scrolled.rowLines

  # ---- M73: THE VERTICAL SCRUBBER ------------------------------------------
  # Scrollbar-Scrubbers.md §3 on the editor's line axis, as the terminal's
  # source pane draws it: present only while the file is taller than the
  # editor (Monaco's `vertical: 'auto'`), the thumb the window's share of the
  # WHOLE file, the execution line marked, a press that jumps and a drag that
  # scrubs — the window only, never the debugger — and, with the horizontal
  # bar, a corner that belongs to neither (§6).

  test "the vertical scrubber: drawn while the file is taller, its thumb the window, the pointer marked":
    let tracks = rest.nodesWith(VTrackAttr)
    checkpoint("vertical tracks at rest: " & $tracks.len & ", metric " &
               rest.vmetric)
    ck tracks.len == 1
    let m = rest.vmetric
    let total = m.field("total")
    let trackPx = m.field("trackPx")
    ck total == calcLines.len or total == calcLines.len - 1
    ck m.field("first") == restRows[0]
    ck trackPx > 0
    # The thumb: `visible / total` of the track, at least Monaco's 20 px, at
    # `(first - 1) / total` along it — the shared model's arithmetic restated
    # from the specification's sentence, within a pixel of rounding.
    let visible = m.field("visible")
    let thumb = rest.nodesWith(VThumbAttr)
    ck thumb.len == 1
    let wantLen = max(20, int(round(float(trackPx) * float(visible) /
                                    float(total))))
    let wantTop = int(round(float(trackPx) * float(restRows[0] - 1) /
                            float(total)))
    checkpoint("thumb top " & $thumb[0].px("top") & " h " &
               $thumb[0].px("h") & ", want " & $wantTop & " / " &
               $wantLen)
    ck abs(thumb[0].px("h") - wantLen) <= 1
    ck abs(thumb[0].px("top") - wantTop) <= 1
    # The execution line is the track's mark.
    let marks = rest.nodesWith(VMarkAttr)
    ck marks.len == 1 and marks[0].attr(VMarkAttr) == $execAtRest

  test "the vertical scrubber's thumb follows the window":
    let thumb0 = rest.nodesWith(VThumbAttr)[0].px("top")
    let down = windowPlan("wheel:editor:12")
    let thumb1 = down.nodesWith(VThumbAttr)[0].px("top")
    checkpoint("thumb top " & $thumb0 & " -> " & $thumb1)
    ck down.vmetric.field("first") == restRows[0] + 12
    ck thumb1 > thumb0
    let back = windowPlan("wheel:editor:12,wheel:editor:-12")
    ck back.nodesWith(VThumbAttr)[0].px("top") == thumb0

  test "a press on the vertical track jumps, a held thumb scrubs; the debugger stays":
    let total = rest.vmetric.field("total")
    let near = windowPlan("vbar:editor:track:980")
    checkpoint("track press at 98%: rows " & $near.rowLines)
    ck near.rowLines.len > 0 and max(near.rowLines) >= total - 1
    ck near.nodesWith(VMarkAttr)[0].attr(VMarkAttr) == $execAtRest
    let bottom = windowPlan("vbar:editor:drag:0:1000")
    checkpoint("thumb dragged to the end: rows " & $bottom.rowLines)
    ck bottom.rowLines.len > 0 and max(bottom.rowLines) >= total - 1
    let top = windowPlan("vbar:editor:drag:1000:0")
    checkpoint("thumb dragged to the top: rows " & $top.rowLines)
    ck top.firstLine == 1
    ck top.nodesWith(VMarkAttr)[0].attr(VMarkAttr) == $execAtRest

  test "one line up from the file's end moves the rows one line, and back":
    # The window at the file's end is drawn bottom-aligned (Monaco's last
    # line on the editor's bottom edge), and a window ONE ROW SHORT of that
    # end is moved to it when a stop serves it. A user's one-line scroll up
    # from the end lands exactly there, so that rule must not take it back:
    # before this case, `wheel:editor:-1` at the end drew the same rows, and
    # `k` / `Ctrl+Up` could never leave the end.
    let atEnd = windowPlan("vbar:editor:drag:0:1000")
    let up1 = windowPlan("vbar:editor:drag:0:1000,wheel:editor:-1")
    let up2 = windowPlan("vbar:editor:drag:0:1000,wheel:editor:-1," &
                         "wheel:editor:-1")
    checkpoint("at the end " & $atEnd.rowLines & ", one up " & $up1.rowLines &
               ", two up " & $up2.rowLines)
    ck up1.firstLine == atEnd.firstLine - 1
    ck up2.firstLine == atEnd.firstLine - 2
    # The scroll key on the focused editor takes the same route.
    let line = atEnd.rowLines[^5]
    let key = windowPlan("vbar:editor:drag:0:1000,click:code:" & $line &
                         "@3,key:up:control")
    checkpoint("Ctrl+Up at the end " & $key.rowLines)
    ck key.firstLine == atEnd.firstLine - 1
    # And a line back down is the end again, drawn as it was.
    let back = windowPlan("vbar:editor:drag:0:1000,wheel:editor:-1," &
                          "wheel:editor:1")
    ck back.rowLines == atEnd.rowLines

  test "with the horizontal bar, the corner cell is neither bar's (§6)":
    # `wide_lines` has a line wider than any pane; at 600 px tall its 34
    # lines are taller than the editor too, so both bars are drawn.
    let plan = windowPlan("", subject = wide, height = 600, into = "")
    let v = plan.nodesWith(VTrackAttr)
    let h = plan.nodesWith("data-ct-editor-scrollbar")
    checkpoint("vertical " & $v.len & ", horizontal " & $h.len & ", metric " &
               plan.vmetric)
    ck v.len == 1 and h.len == 1
    # The horizontal track ends where the vertical one begins…
    ck h[0].px("w") > 0 and v[0].px("left") > 0
    ck h[0].px("left") + h[0].px("w") <= v[0].px("left")
    # …and the vertical one ends a horizontal bar's height above the pane's
    # bottom.
    let m = plan.vmetric
    ck m.field("corner") == 12
    ck m.field("trackTop") + m.field("trackPx") + m.field("corner") ==
       m.field("paneH")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
