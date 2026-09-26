## view_vocabulary_chromium_test.nim — PLAT-3's web arm, in a real browser.
##
## PLAT-3's first integration test asks that "one view written once in the
## vocabulary renders and behaves equivalently on the terminal and the web".
## `src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim` measures that
## on isonim-tui's widgets and on isonim's in-memory DOM, and PLAT-3's status
## recorded the bound on it: *"the web arm runs against `MockRenderer`, not a
## browser"*. This suite is the browser.
##
## ## WHAT IS REAL HERE
##
##   * THE DOCUMENT. The view is rendered by `web_binding` instantiated at
##     `[WebRenderer, Element]` — isonim's live-DOM renderer — into a page in
##     headless Chromium (`src/frontend/tests/chromium-run.mjs`, the
##     `renderer-chromium` lane).
##   * THE KEYS. Every key is pressed by Playwright's `keyboard.press`, which
##     Chromium receives through its own input pipeline as a TRUSTED event:
##     the browser decides which element it reaches (whatever holds focus),
##     runs its own default actions unless a handler prevents them, and makes
##     inert whatever a modal dialog has made inert. Nothing in this file
##     constructs a `KeyboardEvent`.
##   * THE READ-BACK. State is read off the live elements — the `data-*`
##     projection `readWebFacts` walks, and, separately, the DOM's OWN
##     properties (`.checked`, `.open`, `.selectedIndex`, `.value`,
##     `.selectionStart`, `:modal`, `.hidden`), which are the browser's
##     reading of the markup rather than this repository's.
##
## ## THE COMPARISONS, AND WHY THE TERMINAL IS NOT IN THIS PROCESS
##
## The scripted cases and their expected values are
## `frontend/view_vocabulary/cross_medium_script` — the same data the terminal
## suite holds isonim-tui's widgets to. This suite holds Chromium to the same
## expected values, and after EVERY key compares Chromium's whole fact set
## with the same binding running on isonim's in-memory DOM in this page. The
## terminal cannot be linked into a browser page (isonim-tui needs a pty and
## tree-sitter); meeting the same expectations, step for step, is the
## comparison that survives the process boundary.
##
## And after every key, `keysHandled` must have grown exactly when the
## in-memory twin says the vocabulary consumed the key: a state change the
## binding's handler did not make would mean the BROWSER changed the control
## on its own, behind the model's back.
##
## ## NO MOCKS
##
## `isonim.testing.mock_dom.MockRenderer` is the comparison twin, and it is
## not a mock in the policy's sense: it is one of the four renderer backends
## isonim ships and satisfies the same `checkRendererBackend` conformance proof
## `WebRenderer` does (see `test_view_vocabulary_cross_medium.nim`'s header).
## Nothing else here stands in for anything: the browser, the input pipeline
## and the DOM are Chromium's.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## `std/unittest` cannot `await`, and a `check` inside a proc sets the global
## status rather than the test's (the trap `test_view_vocabulary_cross_medium`
## records). So this file counts its own: `ck` tallies, each case prints
## `[OK]` or `[FAILED]`, and the tally is compared with a number written from
## a run.

import std/[asyncjs, strutils, tables, unicode]

import isonim/web/dom_api
import isonim/web/web_renderer
import isonim/testing/mock_dom

import ../../common/view_vocabulary
import ../view_vocabulary/cross_medium_script
import ../view_vocabulary/web_binding as wbind
import ../view_vocabulary/graphemes

# ---------------------------------------------------------------------------
# The page's side of the runner
# ---------------------------------------------------------------------------

proc ctPress(selector, key: cstring): Future[void] {.importjs:
  "window.ctPress(#, #)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}

proc body(): Element {.importjs: "(document.body)".}
proc qsa(sel: cstring): seq[Element] {.importjs:
  "Array.from(document.querySelectorAll(#))".}
proc qs(sel: cstring): Element {.importjs: "document.querySelector(#)".}
proc activeEl(): Element {.importjs: "(document.activeElement)".}
proc attr(e: Element; name: cstring): cstring {.importjs:
  "(#.getAttribute(#) ?? '')".}
proc hasAttr(e: Element; name: cstring): bool {.importjs: "#.hasAttribute(#)".}
proc propBool(e: Element; name: cstring): bool {.importjs: "(!!#[#])".}
proc propNum(e: Element; name: cstring): float {.importjs: "Number(#[#])".}
proc propStr(e: Element; name: cstring): cstring {.importjs: "String(#[#])".}
proc matchesSel(e: Element; sel: cstring): bool {.importjs: "#.matches(#)".}
proc insideDialog(e: Element): bool {.importjs:
  "((e) => e != null && e.closest('dialog') != null)(#)".}
proc setHtml(e: Element; html: cstring) {.importjs: "#.innerHTML = #".}
proc newDiv(): Element {.importjs: "(document.createElement('div'))".}
proc appendEl(p, c: Element) {.importjs: "#.appendChild(#)".}
proc removeEl(e: Element) {.importjs: "#.remove()".}
proc showModalEl(e: Element) {.importjs: "#.showModal()".}
proc countClicks(e: Element) {.importjs:
  "((el) => { el.__clicks = 0; el.addEventListener('click', () => el.__clicks++); })(#)".}
proc setValue(e: Element; v: cstring) {.importjs: "#.value = #".}
proc setCaret(e: Element; at: int) {.importjs:
  "((el, n) => el.setSelectionRange(n, n))(#, #)".}
proc isTrustedLast(): bool {.importjs: "(window.__ctLastKeyTrusted === true)".}
proc installTrustProbe() {.importjs:
  "(document.addEventListener('keydown', function(e){ window.__ctLastKeyTrusted = e.isTrusted; }, true))".}

# ---------------------------------------------------------------------------
# Counting
# ---------------------------------------------------------------------------

var checks = 0
var caseFailed = false
var failedCases = 0
var passedCases = 0

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
    inc passedCases
    echo "  [OK] " & name

const ExpectedChecks = 561
  ## Written from a run. See the end of `main`.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type
  Chrome = WebBinding[WebRenderer, Element]
  Twin = WebBinding[MockRenderer, MockNode]

proc selectorFor(id: string): cstring =
  cstring("[data-view-id=\"" & id & "\"]")

func playwrightKey(k: Key; ch: string): cstring =
  ## Playwright's name for a key. The DOM spells Space `" "`; Playwright
  ## names it `"Space"` and delivers `key: " "`.
  case k
  of kSpace: cstring"Space"
  of kChar: cstring(ch)
  else: cstring(domKeyName(k))

proc factTable(fs: seq[StateFact]): Table[string, string] =
  for f in fs: result[f.id & "." & f.field] = f.value

proc diff(a, b: Table[string, string]): seq[string] =
  for k, v in a:
    let o = b.getOrDefault(k, "<absent>")
    if o != v: result.add k & ": chromium=" & v & " twin=" & o
  for k, v in b:
    if k notin a: result.add k & ": chromium=<absent> twin=" & v

var host: Element = nil

proc freshHost(): Element =
  if not host.isNil: removeEl(host)
  host = newDiv()
  appendEl(body(), host)
  host

proc mountFresh(): (Chrome, Twin) =
  let c = renderWeb[WebRenderer, Element](WebRenderer(), settingsPanel())
  mountWeb(c, freshHost())
  let t = renderWeb[MockRenderer, MockNode](MockRenderer(), settingsPanel())
  (c, t)

proc caretUnits(e: Element): int =
  ## Where the BROWSER's caret must be, in its own unit (UTF-16 code units),
  ## for the model's `data-cursor` (grapheme clusters) on `data-text`.
  let text = $attr(e, "data-text")
  let bounds = graphemeBoundaries(text)
  let c = parseInt($attr(e, "data-cursor"))
  if c < 0 or c >= bounds.len: return -1
  for ru in runes(text[0 ..< bounds[c]]):
    result += (if int32(ru) > 0xFFFF: 2 else: 1)

proc nativeMismatches(): seq[string] =
  ## Every place where the BROWSER's reading of an element disagrees with the
  ## `data-*` state the binding stamped on it. Empty is the only good answer.
  for e in qsa("input[type=checkbox][data-view-id]"):
    if propBool(e, "checked") != ($attr(e, "data-checked") == "true"):
      result.add $attr(e, "data-view-id") & ": .checked"
  for e in qsa("details[data-view-id]"):
    if propBool(e, "open") != ($attr(e, "data-expanded") == "true"):
      result.add $attr(e, "data-view-id") & ": details.open"
  for e in qsa("select[data-view-id]"):
    if int(propNum(e, "selectedIndex")) != parseInt($attr(e, "data-selected")):
      result.add $attr(e, "data-view-id") & ": .selectedIndex"
  for e in qsa("dialog[data-view-id]"):
    let open = $attr(e, "data-open") == "true"
    if propBool(e, "open") != open:
      result.add $attr(e, "data-view-id") & ": dialog.open"
    if matchesSel(e, ":modal") != open:
      result.add $attr(e, "data-view-id") & ": :modal"
  for e in qsa("progress[data-view-id]"):
    let p = parseInt($attr(e, "data-progress"))
    if p == ProgressIndeterminate:
      if propNum(e, "position") != -1.0:
        result.add $attr(e, "data-view-id") & ": progress.position"
    elif int(propNum(e, "value")) != p:
      result.add $attr(e, "data-view-id") & ": progress.value"
  for e in qsa("input[type=text][data-view-id]"):
    if $propStr(e, "value") != $attr(e, "data-text"):
      result.add $attr(e, "data-view-id") & ": input.value"
    if activeEl() == e and
       int(propNum(e, "selectionStart")) != caretUnits(e):
      result.add $attr(e, "data-view-id") & ": input.selectionStart"
  for e in qsa("[data-view-kind=Menu]"):
    if propBool(e, "hidden") != ($attr(e, "data-open") != "true"):
      result.add $attr(e, "data-view-id") & ": menu.hidden"

# ---------------------------------------------------------------------------
# The cases
# ---------------------------------------------------------------------------

proc caseRendersIntoADocument() {.async.} =
  beginCase()
  let (c, t) = mountFresh()
  # THE POSITIVE CONTROL: it rendered, into THIS document.
  ck qsa("[data-view-id]").len == 19
  ck not qs("[data-view-id=\"panel\"]").isNil
  let cf = factTable(readWebFacts(c))
  let tf = factTable(readWebFacts(t))
  ck cf.len == 29, $cf.len
  ck diff(cf, tf).len == 0, $diff(cf, tf)
  let nm = nativeMismatches()
  ck nm.len == 0, $nm
  # The open Modal is shown MODALLY, which only a document can do.
  ck matchesSel(qs("[data-view-id=\"dlg\"]"), ":modal")
  # Markdown: rendered as blocks, read back off the elements.
  let outline = webMarkdownOutline(c, "doc")
  ck outline.len == 23, $outline
  ck outline == webMarkdownOutline(t, "doc")
  ck "h1 Title" in outline
  ck "p Some [b:bold] text and [c:code]." in outline
  ck "code nim|echo 1" in outline
  ck qsa("[data-view-id=\"doc\"] h1").len == 1
  ck qsa("[data-view-id=\"doc\"] blockquote").len == 1
  ck qsa("[data-view-id=\"doc\"] ol > li").len == 2
  endCase("the binding renders into a real document, and the browser reads it the same way")

proc caseScript(sc: ScriptCase): Future[void] {.async.} =
  beginCase()
  let (c, t) = mountFresh()
  var handledHere = 0
  for st in sc.steps:
    case st.kind
    of skKey, skKeyHere:
      let before = c.keysHandled
      let sel = if st.kind == skKey: selectorFor(st.id) else: cstring""
      await ctPress(sel, playwrightKey(st.key, st.ch))
      ck isTrustedLast(), "the key Chromium delivered was not trusted"
      let twin = t.sendKey(st.id, st.key, st.ch)
      let grew = c.keysHandled - before
      # The browser's key reached the binding's handler EXACTLY when the
      # vocabulary consumed it — never more (a double delivery), never less
      # (the browser, or a lost focus, swallowed it).
      ck grew == (if twin.handled: 1 else: 0),
        sc.name & ": " & st.id & " " & $st.key & " handled twin=" &
        $twin.handled & " chromium grew by " & $grew
      if twin.handled: inc handledHere
      let d = diff(factTable(readWebFacts(c)), factTable(readWebFacts(t)))
      ck d.len == 0, sc.name & " after " & st.id & " " & $st.key & ": " & $d
      let nm = nativeMismatches()
      ck nm.len == 0, sc.name & " after " & st.id & " " & $st.key & ": " & $nm
      if st.kind == skKeyHere:
        # Focus stayed where the reader left it across the re-render.
        ck $attr(activeEl(), "data-view-id") == st.id
    of skExpect:
      let v = factTable(readWebFacts(c)).getOrDefault(st.fact, "<absent>")
      ck v == st.value, sc.name & ": " & st.fact & " = " & v &
        ", expected " & st.value
  ck handledHere > 0
  endCase("scripted: " & sc.name)

proc caseModalExclusivity() {.async.} =
  ## An open Modal takes input until dismissed — supplied by `showModal()`,
  ## measured with keys the browser routes.
  beginCase()
  let (c, _) = mountFresh()
  ck matchesSel(qs("[data-view-id=\"dlg\"]"), ":modal")
  # Aim a key at the checkbox OUTSIDE the dialog. The browser will not move
  # focus into an inert element, so the key lands inside the dialog, and the
  # checkbox is untouched.
  await ctPress(selectorFor("wrap"), "Space")
  ck $attr(qs("[data-view-id=\"wrap\"]"), "data-checked") == "false"
  ck insideDialog(activeEl()), "focus left the modal dialog"
  # Dismiss, and the same key now reaches the checkbox.
  await ctPress(selectorFor("dlg"), "Escape")
  ck $attr(qs("[data-view-id=\"dlg\"]"), "data-open") == "false"
  ck not matchesSel(qs("[data-view-id=\"dlg\"]"), ":modal")
  await ctPress(selectorFor("wrap"), "Space")
  ck $attr(qs("[data-view-id=\"wrap\"]"), "data-checked") == "true"
  ck propBool(qs("[data-view-id=\"wrap\"]"), "checked")
  ck c.keysHandled == 2
  endCase("an open Modal takes input until it is dismissed (showModal, inert page)")

proc caseNativeSemantics() {.async.} =
  ## WHAT THE BROWSER DOES ON ITS OWN, with no binding and no handler: bare
  ## HTML elements, trusted keys. `mappings.webMapping`'s notes cite these
  ## as their evidence, and `web_binding.nativeDefaultChangesState` is built
  ## from the last two groups. They are facts about Chromium; if a release
  ## changes one, this case goes red and the note it supports is the thing
  ## to re-read.
  beginCase()
  let h = freshHost()
  setHtml(h, "<input type=checkbox id=ncb><button id=nbt>b</button>" &
    "<select id=nsel><option>a<option>b<option>c</select>" &
    "<details id=ndet><summary id=nsum>s</summary>body</details>" &
    "<dialog id=ndlg><button>x</button></dialog>" &
    "<progress id=npr max=100></progress><input id=ntx value=abcdef>")
  # Checkbox: Space toggles; Enter does NOT. The vocabulary's Checkbox
  # answers both, so Enter is the binding's.
  await ctPress("#ncb", "Space")
  ck propBool(qs("#ncb"), "checked")
  await ctPress("#ncb", "Enter")
  ck propBool(qs("#ncb"), "checked"), "Enter toggled a native checkbox"
  # Button: Enter and Space both activate.
  countClicks(qs("#nbt"))
  await ctPress("#nbt", "Enter")
  await ctPress("#nbt", "Space")
  ck int(propNum(qs("#nbt"), "__clicks")) == 2
  # Select, CLOSED: Down and End COMMIT at once — no highlight step.
  await ctPress("#nsel", "ArrowDown")
  ck int(propNum(qs("#nsel"), "selectedIndex")) == 1
  await ctPress("#nsel", "End")
  ck int(propNum(qs("#nsel"), "selectedIndex")) == 2
  await ctPress("#nsel", "Home")
  ck int(propNum(qs("#nsel"), "selectedIndex")) == 0
  await ctPress("#nsel", "c")                      # type-ahead
  ck int(propNum(qs("#nsel"), "selectedIndex")) == 2
  await ctPress("#nsel", "ArrowUp")
  ck int(propNum(qs("#nsel"), "selectedIndex")) == 1
  # Details: Enter and Space on the summary disclose and close.
  await ctPress("#nsum", "Enter")
  ck propBool(qs("#ndet"), "open")
  await ctPress("#nsum", "Space")
  ck not propBool(qs("#ndet"), "open")
  # Dialog: shown modally, Escape dismisses it.
  showModalEl(qs("#ndlg"))
  ck matchesSel(qs("#ndlg"), ":modal")
  await ctPress("", "Escape")
  ck not propBool(qs("#ndlg"), "open")
  # Progress with no value is indeterminate.
  ck propNum(qs("#npr"), "position") == -1.0
  # Text input: Up and Down move the caret to the ends.
  setCaret(qs("#ntx"), 3)
  await ctPress("#ntx", "ArrowUp")
  ck int(propNum(qs("#ntx"), "selectionStart")) == 0
  setCaret(qs("#ntx"), 3)
  await ctPress("", "ArrowDown")
  ck int(propNum(qs("#ntx"), "selectionStart")) == 6
  # And the caret moves by GRAPHEME CLUSTER: `e` + U+0301 is one step of
  # Right (two UTF-16 units), as it is one step in isonim-tui's InputWidget.
  setValue(qs("#ntx"), "e\u0301x")
  setCaret(qs("#ntx"), 0)
  await ctPress("", "ArrowRight")
  ck int(propNum(qs("#ntx"), "selectionStart")) == 2
  endCase("what the browser does on its own (the evidence behind the web mapping)")

proc main() {.async.} =
  installTrustProbe()
  echo ""
  echo "[Suite] PLAT-3: the web arm in a real browser (Chromium)"
  await caseRendersIntoADocument()
  let cases = scriptedCases()
  for sc in cases:
    await caseScript(sc)
  await caseModalExclusivity()
  await caseNativeSemantics()
  beginCase()
  ck cases.len == 13
  # THE TALLY. Compared with a number written from a run, so a case that
  # returned early or a loop that skipped its body is a count mismatch rather
  # than a silent pass. `CHECKS:` is the line the lane runner reads.
  inc checks
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
