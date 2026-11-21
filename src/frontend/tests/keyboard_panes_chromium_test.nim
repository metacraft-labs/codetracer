## keyboard_panes_chromium_test.nim — the debugger's four keyboard panes in a
## real browser, against two oracles that share no code.
##
## `src/frontend/tui/tests/test_cross_renderer_panes.nim` drives the state
## pane (a `Tree`), the call trace (a `List`), the event log (a `Table`) and
## the tracepoints (a `List` with a point that could not be located) on a real
## recording, through isonim-tui's widgets, the in-memory DOM and the GPUI
## shim. Until this suite its web arm was `MockRenderer` and its keyboard claim
## had ONE independent oracle: isonim-tui's widgets. The web and GPUI arms both
## end at the vocabulary's own key rules. This suite adds the two things that
## were missing.
##
## ## 1. THE WEB ARM IN A BROWSER
##
## The same four pane views — carried across from the recording by the C
## suite, which exports their structure and what isonim-tui's widgets answered
## after every key (`keyboard_pane_scripts`, `fixtures/
## keyboard_panes_calc.json`) — are rendered by `web_binding` at
## `[WebRenderer, Element]` into a page in headless Chromium, and the SAME key
## scripts are pressed through Chromium's own input pipeline (`ctPress`,
## trusted events). After every key the browser's facts must equal the
## terminal's.
##
## ## 2. A SECOND INDEPENDENT KEYBOARD ORACLE: THE W3C REFERENCE WIDGETS
##
## The W3C ARIA Authoring Practices Guide publishes reference implementations
## of the keyboard behaviour of a listbox, a tree view and a data grid. They
## are vendored verbatim (`vendor/aria-practices/`, with `PROVENANCE.md`) and
## run in the same page: `apg_keyboard_oracle` builds the markup they expect
## from the fixture's plain data, and every key is delivered to them by
## Chromium. Their handlers — W3C's code — decide where the focus goes.
##
## Independent in the two senses that matter: no shared AUTHOR (W3C's
## authors wrote these for the APG; isonim-tui's widgets and the vocabulary
## are this organisation's) and no shared CODE PATH (the glue passes plain
## data and reads back the widget's own focus; the source scan below holds it
## to never naming the vocabulary's key rules or isonim-tui).
##
## Each key is judged as one TRANSITION: before it, the reference widget is
## put in the terminal's state (the active option, the focused cell, the open
## items and the cursor), the key is pressed, and the widget's new state is
## compared with the terminal's. So a disagreement on one key is that key's
## and does not carry into the next.
##
## ## WHERE THE W3C WIDGETS AGREE, AND THE TWO PLACES THEY DO NOT
##
## Agreed, key for key — fourteen of the seventeen transitions, measured
## 2026-11-21: a `Tree`'s Down, Home, and Right/Left opening and closing an
## item (the cursor stays on it, and the number of rows it shows is the
## terminal's); a `List`'s Down, End, Home, no wrap past the last option, and
## a key outside the contract doing nothing; a `Table`'s Down, Right and no
## motion past the last row.
##
## Pinned as findings (`PinnedDivergences`), because they are differences in
## SPECIFIED behaviour rather than defects of either side:
##
##   * `APG-LISTBOX-DISABLED` — the reference listbox moves ONTO an option
##     marked `aria-disabled`; the vocabulary's `List` skips it (and isonim-tui
##     agrees). The APG listbox pattern lets a disabled option be focusable.
##   * `APG-GRID-END` — in the reference grid End moves to the last CELL of
##     the row (Ctrl+End to the last row); the vocabulary's `Table` End moves
##     to the last ROW, keeping the column.
##
## ## NO MOCKS
##
## None: the browser, its input pipeline and its DOM are Chromium's, the
## reference widgets are W3C's, and the answers they are compared with are
## isonim-tui's, taken on a real recording.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## As `view_vocabulary_chromium_test.nim`: `ck` tallies, each case prints
## `[OK]` or `[FAILED]`, and the tally is compared with a number written from
## a run.

import std/[asyncjs, json, jsffi, sets, strutils, tables]

import isonim/web/dom_api
import isonim/web/web_renderer

import ../../common/view_vocabulary
import ../view_vocabulary/keyboard_pane_scripts
import ../view_vocabulary/web_binding as wbind
import ./apg_keyboard_oracle

proc ctPress(selector, key: cstring): Future[void] {.importjs:
  "window.ctPress(#, #)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc body(): Element {.importjs: "(document.body)".}
proc newDiv(): Element {.importjs: "(document.createElement('div'))".}
proc appendEl(p, c: Element) {.importjs: "#.appendChild(#)".}
proc removeEl(e: Element) {.importjs: "#.remove()".}
proc isTrustedLast(): bool {.importjs: "(window.__ctLastKeyTrusted === true)".}
proc installTrustProbe() {.importjs:
  "(document.addEventListener('keydown', function(e){ window.__ctLastKeyTrusted = e.isTrusted; }, true))".}
proc asJs(e: Element): JsObject {.importjs: "(#)".}

const
  Fixture = staticRead("fixtures/keyboard_panes_calc.json")
  OracleText = staticRead("apg_keyboard_oracle.nim")
  ForbiddenInOracle = ["applyKey", "behaviour", "keyContract", "nextEnabled",
                       "isonim_tui", "view_vocabulary", "web_binding",
                       "terminal_binding", "sendKey"]
    ## What the reference-widget glue must never name: the vocabulary's key
    ## rules, its bindings and isonim-tui. Its cardinality is asserted, so an
    ## emptied list cannot pass the scan for free.
  PinnedDivergences = [
    "APG-GRID-END eventLog step 3 (kEnd): terminal=(5, 1) apg=(1, 3)",
    "APG-LISTBOX-DISABLED pointList step 1 (kDown): terminal=2 apg=1",
    "APG-LISTBOX-DISABLED pointList step 2 (kUp): terminal=0 apg=1"]
    ## Measured 2026-11-21 on the calc recording: six events in four columns,
    ## and three tracepoints of which the middle one could not be located.
  ExpectedChecks = 90

var checks = 0
var caseFailed = false
var failedCases = 0

template ck(cond: untyped; detail: string = "") =
  inc checks
  if not (cond):
    caseFailed = true
    echo "    Check failed: " & astToStr(cond) &
      (if detail.len > 0: "  -- " & detail else: "")

proc beginCase() = caseFailed = false

proc endCase(name: string) =
  if caseFailed:
    inc failedCases
    echo "  [FAILED] " & name
  else:
    echo "  [OK] " & name

proc selectorFor(id: string): cstring =
  cstring("[data-view-id=\"" & id & "\"]")

func playwrightKey(k: Key): cstring =
  if k == kSpace: cstring"Space" else: cstring(domKeyName(k))

proc lines(j: JsonNode): seq[string] =
  for l in j.getElems: result.add l.getStr

proc factOf(answer: JsonNode; key: string): string =
  for l in answer.getElems:
    let s = l.getStr
    if s.startsWith(key & "="): return s[key.len + 1 .. ^1]
  "<absent>"

proc findNode(v: ViewNode; id: string): ViewNode =
  if v.id == id: return v
  for c in v.children:
    let f = findNode(c, id)
    if not f.isNil: return f
  nil

proc diffLines(a, b: seq[string]): seq[string] =
  let sa = a.toHashSet
  let sb = b.toHashSet
  for x in a:
    if x notin sb: result.add "browser has " & x
  for x in b:
    if x notin sa: result.add "terminal has " & x

var host: Element = nil

proc freshHost(): Element =
  if not host.isNil: removeEl(host)
  host = newDiv()
  appendEl(body(), host)
  host

let doc = parseJson(Fixture)
var divergences: seq[string] = @[]
var agreed = 0
var judged = 0

proc scriptFor(pane: string): PaneScript =
  for s in PaneScripts:
    if s.pane == pane: return s

# ---------------------------------------------------------------------------
# The web arm
# ---------------------------------------------------------------------------

proc caseWebArm(entry: JsonNode) {.async.} =
  let pane = entry["pane"].getStr
  beginCase()
  let script = scriptFor(pane)
  let answers = entry["terminal"]
  ck answers.len == script.steps.len + 1, pane
  let c = renderWeb[WebRenderer, Element](WebRenderer(),
                                          decodeView(entry["view"]))
  mountWeb(c, freshHost())
  let first = factLines(readWebFacts(c))
  ck first.len > 0
  ck first == lines(answers[0]),
    pane & " as rendered: " & $diffLines(first, lines(answers[0]))
  for i, st in script.steps:
    await ctPress(selectorFor(st.target), playwrightKey(st.key))
    ck isTrustedLast(), "the key Chromium delivered was not trusted"
    let now = factLines(readWebFacts(c))
    ck now == lines(answers[i + 1]),
      pane & " after " & st.target & " " & $st.key & ": " &
      $diffLines(now, lines(answers[i + 1]))
  endCase("the " & pane & " pane in Chromium answers every key as the " &
          "terminal's widgets did")

# ---------------------------------------------------------------------------
# The second oracle
# ---------------------------------------------------------------------------

proc judge(tag, pane: string; i: int; k: Key; terminal, apg: string) =
  inc judged
  if terminal == apg:
    inc agreed
  else:
    divergences.add tag & " " & pane & " step " & $(i + 1) & " (" & $k &
      "): terminal=" & terminal & " apg=" & apg

proc apgNodeOf(v: ViewNode): ApgNode =
  result = ApgNode(id: v.id, expanded: v.expanded)
  for c in v.children: result.children.add apgNodeOf(c)

proc visibleCountAfter(v: ViewNode; answer: JsonNode): int =
  ## How many rows the TERMINAL shows: the view's rows, opened as the
  ## terminal's facts say.
  proc count(n: ViewNode): int =
    result = 1
    if factOf(answer, n.id & ".expanded") == "true":
      for c in n.children: result += count(c)
  count(v)

proc caseReferenceWidgets(entry: JsonNode) {.async.} =
  let pane = entry["pane"].getStr
  beginCase()
  let script = scriptFor(pane)
  let answers = entry["terminal"]
  let view = decodeView(entry["view"])
  let target = findNode(view, script.steps[0].target)
  ck not target.isNil, pane & ": no node " & script.steps[0].target
  if target.isNil:
    endCase("the W3C reference widget for " & pane)
    return
  let before = judged
  let id = target.id
  case target.kind
  of pkList:
    var disabled: seq[bool] = @[]
    for o in target.options: disabled.add o.disabled
    let lb = newApgListbox(asJs(freshHost()), disabled)
    for i, st in script.steps:
      lb.syncListbox(parseInt(factOf(answers[i], id & ".highlight")))
      await ctPress("", playwrightKey(st.key))
      ck isTrustedLast()
      judge("APG-LISTBOX-DISABLED", pane, i, st.key,
            factOf(answers[i + 1], id & ".highlight"), $lb.listboxIndex())
  of pkTable:
    let g = newApgGrid(asJs(freshHost()), target.rows.len,
                       target.columns.len)
    for i, st in script.steps:
      g.syncGrid(parseInt(factOf(answers[i], id & ".row")),
                 parseInt(factOf(answers[i], id & ".column")))
      await ctPress("", playwrightKey(st.key))
      ck isTrustedLast()
      let want = (parseInt(factOf(answers[i + 1], id & ".row")),
                  parseInt(factOf(answers[i + 1], id & ".column")))
      judge("APG-GRID-END", pane, i, st.key, $want, $g.gridCell())
  of pkTree:
    let t = newApgTree(asJs(freshHost()), apgNodeOf(target))
    for i, st in script.steps:
      let pre = answers[i]
      t.syncTree(proc(n: string): bool = factOf(pre, n & ".expanded") == "true",
                 parseInt(factOf(pre, id & ".cursor")))
      await ctPress("", playwrightKey(st.key))
      ck isTrustedLast()
      let post = answers[i + 1]
      judge("APG-TREE", pane, i, st.key,
            factOf(post, id & ".cursor") & " of " &
              $visibleCountAfter(target, post),
            $t.treeCursor() & " of " & $t.treeVisibleCount())
  else:
    ck false, pane & ": no reference widget for " & vocabularyName(target.kind)
  # Every key of the pane's script was JUDGED, not skipped.
  ck judged - before == script.steps.len, pane & ": a key was not judged"
  endCase("the W3C reference widget for " & pane & " was asked every key")

proc main() {.async.} =
  installTrustProbe()
  echo ""
  echo "[Suite] the four keyboard panes in Chromium: the web arm and the " &
    "W3C reference widgets"
  beginCase()
  # The fixture carries the four panes the scripts name, in their order.
  ck doc["panes"].len == PaneScripts.len
  for i, s in PaneScripts:
    if i < doc["panes"].len:
      ck doc["panes"][i]["pane"].getStr == s.pane
  # THE SCAN THAT KEEPS THE SECOND ORACLE INDEPENDENT (§30a), with its
  # positive control: the glue is read (it names W3C's widget), and the
  # forbidden list is the size it is written as.
  ck ForbiddenInOracle.len == 9
  ck "aria.Listbox" in OracleText
  for f in ForbiddenInOracle:
    ck f notin OracleText, "the reference-widget glue names " & f
  endCase("the fixture and the independence scan")
  for entry in doc["panes"]:
    await caseWebArm(entry)
  for entry in doc["panes"]:
    await caseReferenceWidgets(entry)
  beginCase()
  echo "  W3C reference widgets: " & $agreed & " transitions agreed, " &
    $divergences.len & " differ"
  for d in divergences: echo "    " & d
  ck divergences == @PinnedDivergences, $divergences
  ck agreed == 14
  endCase("the reference widgets agree on every key but the pinned findings")
  inc checks
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    inc failedCases
    echo "  [FAILED] the assertion count is " & $checks & ", expected " &
      $ExpectedChecks
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
