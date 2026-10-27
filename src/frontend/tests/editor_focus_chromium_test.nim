## editor_focus_chromium_test.nim — a programmatic editor focus does not take
## the keyboard from a text field the user is typing in
## (`ui/editor_focus.revealLineAndFocus`, which `utils.focusLine` calls).
##
## THE DEFECT (codetracer-pm issues/2026-10-22-a-watch-typed-in-the-browser-
## never-produces-a-row.md): the replay's first stop opens its file in the
## editor and, from a timer, puts the caret on the stop's line and focused
## Monaco unconditionally. A user typing `asteroid_masses_positive[1]` into the
## State pane's watch box when it fired lost the rest of the keystrokes to the
## read-only editor, and `Enter` submitted `ast`. The first case below is that
## sequence: keys typed into a real `<input>` through Chromium's own input
## pipeline (`ctPress`), the focus call in the middle of them, and the rest of
## the keys after it. It fails against an unconditional `focus()`.
##
## WHY A BROWSER: the subject is where the KEYBOARD goes, which only a browser
## decides — `document.activeElement`, `focus()` and trusted key events. This
## runs in headless Chromium through the `renderer-chromium` lane
## (`src/frontend/tests/chromium-run.mjs`).
##
## THE ONE STAND-IN: the Monaco instance. No Monaco is loaded in this page, and
## what is under test is the focus decision, not Monaco. The stand-in has the
## four members `revealLineAndFocus` calls (`revealLineInCenter`,
## `setPosition`, `focus`, `getDomNode`), records the first two, and its
## `focus()` focuses a real `<textarea>` inside its real DOM node, which is
## where Monaco's own `focus()` puts the keyboard.
##
## COUNTED ASSERTIONS (Verification-Harness-Traps §4c): `std/unittest` cannot
## `await`, so — as `view_vocabulary_chromium_test.nim` does — `ck` tallies,
## each case prints `[OK]` / `[FAILED]`, and the tally is compared with a
## number written from a run.

import std/[asyncjs, jsffi]

import ../ui/editor_focus

proc ctPress(selector, key: cstring): Future[void] {.importjs:
  "window.ctPress(#, #)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}

proc setHtml(html: cstring) {.importjs: "document.body.innerHTML = #".}
proc qs(sel: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc activeId(): cstring {.importjs:
  "((document.activeElement && document.activeElement.id) || '')".}
proc focusEl(e: JsObject) {.importjs: "#.focus()".}
proc valueOf(e: JsObject): cstring {.importjs: "(#.value)".}
proc standInMonaco(node, input: JsObject): JsObject {.importjs: """
  ((node, input) => ({
    revealed: 0, line: 0, column: -1, focusCalls: 0,
    revealLineInCenter(l) { this.revealed = l; },
    setPosition(p) { this.line = p.lineNumber; this.column = p.column; },
    focus() { this.focusCalls++; input.focus(); },
    getDomNode() { return node; },
  }))(#, #)""".}
proc num(o: JsObject; field: cstring): int {.importjs: "(Number(#[#]))".}

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

const
  Page = """
    <form id="watch-form"><input type="text" id="watch-0"></form>
    <textarea id="notes"></textarea>
    <div id="rich" contenteditable="true"></div>
    <input type="text" id="locked" readonly>
    <input type="checkbox" id="flag">
    <button id="button">a button</button>
    <div id="editor"><textarea id="editor-input"></textarea></div>
  """
  ExpectedChecks = 22
    ## Written from a run. See the end of `main`.

proc freshEditor(): JsObject =
  setHtml(Page)
  standInMonaco(qs("#editor"), qs("#editor-input"))

proc typeInto(selector: cstring; text: string) {.async.} =
  ## Each character as a trusted key event; the first one focuses
  ## `selector`, the rest go wherever the keyboard then is.
  var first = true
  for ch in text:
    await ctPress(if first: selector else: cstring"", cstring($ch))
    first = false

proc caseFirstStopWhileTyping() {.async.} =
  beginCase()
  let editor = freshEditor()
  await typeInto("#watch-0", "ast")
  # The first stop's editor tab, from its timer, in the middle of the word.
  revealLineAndFocus(editor, 12, 0)
  await typeInto("", "eroid")
  ck $valueOf(qs("#watch-0")) == "asteroid",
    "the watch box holds `" & $valueOf(qs("#watch-0")) & "`"
  ck $activeId() == "watch-0", "the keyboard is on `" & $activeId() & "`"
  ck $valueOf(qs("#editor-input")) == ""
  ck editor.num("focusCalls") == 0
  # The line is still revealed and the caret still placed.
  ck editor.num("revealed") == 12
  ck editor.num("line") == 12
  ck editor.num("column") == 1,
    "a column below 1 is placed at 1, not passed to Monaco as is"
  endCase("a focus of the editor while the watch box is typed in leaves the keys in the box")

proc caseOtherTextFields() {.async.} =
  beginCase()
  for id in ["notes", "rich"]:
    let editor = freshEditor()
    focusEl(qs(cstring("#" & id)))
    revealLineAndFocus(editor, 3, 5)
    ck $activeId() == id, id & ": the keyboard went to `" & $activeId() & "`"
    ck editor.num("line") == 3 and editor.num("column") == 5
  endCase("a textarea and contenteditable content keep the keyboard too")

proc caseNoTextField() {.async.} =
  beginCase()
  # Nothing focused, a button, a checkbox, a read-only field: no text is
  # being typed, so the editor takes the keyboard as it always did.
  for id in ["", "button", "flag", "locked"]:
    let editor = freshEditor()
    if id.len > 0:
      focusEl(qs(cstring("#" & id)))
    revealLineAndFocus(editor, 7, 0)
    ck $activeId() == "editor-input",
      (if id.len > 0: id else: "<body>") & ": the keyboard is on `" &
      $activeId() & "`"
    ck editor.num("focusCalls") == 1
  endCase("with no text field focused the editor takes the keyboard")

proc caseFocusAlreadyInEditor() {.async.} =
  beginCase()
  let editor = freshEditor()
  await typeInto("#editor-input", "x")
  revealLineAndFocus(editor, 9, 0)
  ck editor.num("focusCalls") == 1
  ck $activeId() == "editor-input"
  endCase("a text field INSIDE the editor is the editor's: it is focused as before")

proc main() {.async.} =
  echo ""
  echo "[Suite] a programmatic editor focus and the field being typed in"
  await caseFirstStopWhileTyping()
  await caseOtherTextFields()
  await caseNoTextField()
  await caseFocusAlreadyInEditor()
  beginCase()
  # THE TALLY: a case that returned early is a count mismatch, not a pass.
  inc checks
  echo "CHECKS: " & $checks
  if checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
