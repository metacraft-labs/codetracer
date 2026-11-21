## keyboard_pane_scripts.nim — the key scripts the debugger's four keyboard
## panes are driven through on every medium, and the structural form in which
## a pane view crosses from the suite that can open a recording to the suite
## that can open a browser.
##
## `src/frontend/tui/tests/test_cross_renderer_panes.nim` opens a real
## recording and drives the state pane (a `Tree`), the call trace (a `List`),
## the event log (a `Table`) and the tracepoints (a `List` with one disabled
## point) through isonim-tui's widgets, the in-memory DOM and the GPUI shim.
## A browser cannot open a recording — it has no `replay-server` — so that
## suite also EXPORTS, for each pane, the view's structure and what the
## terminal's widgets answered after every key of these scripts, and requires
## the export to equal the committed fixture
## (`src/frontend/tests/fixtures/keyboard_panes_calc.json`).
## `src/frontend/tests/keyboard_panes_chromium_test.nim` reads that fixture
## and drives the SAME scripts through the web binding in headless Chromium
## and through the W3C ARIA Authoring Practices' own widgets.
##
## ## WHAT THE PROJECTION KEEPS, AND WHAT IT DROPS
##
## Everything a key can move or a fact can report: kinds, ids, the tree's
## shape and expansion, the cursor, the highlight, the selection, the
## options' availability, the table's dimensions, a `Text` node's text and a
## `Button`'s label. It DROPS labels and cell contents, which carry recorded
## VALUES (`<function add at 0x10666c2c0>`) that differ between two recordings
## of the same program, and option ids, which carry the recording's absolute
## source path. No fact reads either, so the web arm's facts over the decoded
## view are comparable with the terminal's over the original.
##
## Pure (std only): it compiles for C and for JavaScript.

import std/[algorithm, json, strutils]

import ../../common/view_vocabulary

type
  KeyStep* = object
    target*: string   ## the `ViewNode.id` the key is aimed at
    key*: Key

  PaneScript* = object
    pane*: string     ## the pane's name, as `PaneKind`'s `$`
    steps*: seq[KeyStep]

func step(target: string; key: Key): KeyStep = KeyStep(target: target, key: key)

const PaneScripts* = [
  # The state pane: move, return to the top, open the first variable (the
  # interpreter's `__builtins__`, a Dict of some hundred and fifty entries the
  # recorder produced), and close it again.
  PaneScript(pane: "state", steps: @[
    step("state.root", kDown), step("state.root", kDown),
    step("state.root", kHome), step("state.root", kDown),
    step("state.root", kRight), step("state.root", kLeft)]),
  # The call trace: move, jump to the end, press past it (no wrap), return,
  # and a key outside the contract.
  PaneScript(pane: "calltrace", steps: @[
    step("calltrace", kDown), step("calltrace", kEnd),
    step("calltrace", kDown), step("calltrace", kHome),
    step("calltrace", kRight)]),
  # The event log: a row, a column, the last row, and past it.
  PaneScript(pane: "eventLog", steps: @[
    step("eventLog", kDown), step("eventLog", kRight),
    step("eventLog", kEnd), step("eventLog", kDown)]),
  # The tracepoints: motion over the point that could not be located.
  PaneScript(pane: "pointList", steps: @[
    step("pointList", kDown), step("pointList", kUp)])]
  ## THE ONE COPY of the scripts. Both suites iterate this constant, so the
  ## export and the browser cannot press different keys.

# ---------------------------------------------------------------------------
# The structural projection
# ---------------------------------------------------------------------------

proc encodeView*(v: ViewNode): JsonNode =
  ## `v` as data, labels and values dropped (see the header).
  result = newJObject()
  result["kind"] = %vocabularyName(v.kind)
  result["id"] = %v.id
  if v.kind == pkText or v.kind == pkMarkdown: result["text"] = %v.text
  if v.kind == pkButton: result["label"] = %v.label
  if v.disabled: result["disabled"] = %true
  if v.expanded: result["expanded"] = %true
  if v.cursor != 0: result["cursor"] = %v.cursor
  if v.column != 0: result["column"] = %v.column
  if v.selected != -1: result["selected"] = %v.selected
  if v.highlight != -1: result["highlight"] = %v.highlight
  if v.open: result["open"] = %true
  if v.activation.len > 0:
    var acts = newJArray()
    for a in Activation:
      if a in v.activation: acts.add %($a)
    result["activation"] = acts
  if v.options.len > 0:
    var opts = newJArray()
    for o in v.options: opts.add %(o.disabled)
    result["options"] = opts
  if v.kind == pkTable:
    result["columns"] = %v.columns.len
    result["rows"] = %v.rows.len
  if v.children.len > 0:
    var kids = newJArray()
    for c in v.children: kids.add encodeView(c)
    result["children"] = kids

proc kindNamed(name: string): ViewKind =
  for k in ViewKind:
    if vocabularyName(k) == name: return k
  raise newException(ValueError, "no vocabulary entry is named '" & name & "'")

proc decodeView*(j: JsonNode): ViewNode =
  ## The inverse of `encodeView`, with each dropped label spelled as the
  ## node's id and each dropped cell as its coordinates.
  result = ViewNode(kind: kindNamed(j["kind"].getStr), id: j["id"].getStr,
                    label: j{"label"}.getStr(j["id"].getStr),
                    text: j{"text"}.getStr,
                    disabled: j{"disabled"}.getBool,
                    expanded: j{"expanded"}.getBool,
                    cursor: j{"cursor"}.getInt,
                    column: j{"column"}.getInt,
                    selected: j{"selected"}.getInt(-1),
                    highlight: j{"highlight"}.getInt(-1),
                    open: j{"open"}.getBool)
  for a in j{"activation"}.getElems:
    for m in Activation:
      if $m == a.getStr: result.activation.incl m
  var i = 0
  for d in j{"options"}.getElems:
    result.options.add ViewOption(id: result.id & ".o" & $i,
                                  label: result.id & " " & $i,
                                  disabled: d.getBool)
    inc i
  if result.kind == pkTable:
    for c in 0 ..< j{"columns"}.getInt:
      result.columns.add "c" & $c
    for r in 0 ..< j{"rows"}.getInt:
      var row: seq[string] = @[]
      for c in 0 ..< j{"columns"}.getInt: row.add $r & "," & $c
      result.rows.add row
  for c in j{"children"}.getElems:
    result.children.add decodeView(c)

proc factLines*(facts: openArray[StateFact]): seq[string] =
  ## Facts as sorted `id.field=value` lines — the fixture's spelling, and the
  ## one both suites compare.
  for f in facts: result.add f.id & "." & f.field & "=" & f.value
  result.sort()
