## shared_editor_chromium_test.nim — the desktop's shared editor
## (`ui/shared_editor`, `ui/shared_editor_facade`) in a real page in headless
## Chromium: what a user of the editor pane sees and does, through the
## browser's own input pipeline.
##
## WHY A BROWSER: every claim here is about what a BROWSER does with the
## editor's DOM — where a trusted click lands, which text an input method
## commits, what the accessibility tree hands a screen reader, how a
## forced-colours theme paints — which only a browser decides. This runs in
## the `renderer-chromium` lane (`src/frontend/tests/chromium-run.mjs`, which
## supplies `ctPress`, `ctMouse`, `ctIme`, `ctAxTree`, `ctForcedColors`).
##
## NO MOCKS. The editor is the shipped module over the shipped editing core,
## in a real document; Monaco is not loaded and nothing stands in for it (the
## facade installs the minimal `monaco.editor` the desktop's callers read).
## The keys reach the editor the way they reach it with no router installed:
## a printable key's default action is the text area's `input`, which the
## editor hands to the core. The router's half — chords, modes, the
## desktop's operations — is graded through the desktop
## (`src/tests/gui/tests/shared-editor/`).
##
## COUNTED ASSERTIONS (Verification-Harness-Traps §4c): `ck` tallies, each
## case prints `[OK]` / `[FAILED]`, and the tally is compared with a number
## written from a run.

import std/[asyncjs, jsffi, strutils, json]

import ../ui/[shared_editor, shared_editor_facade, shared_diff_editor]
import ../viewmodel/editing_core
import ../viewmodel/keymap/base_keymaps
import ../tui/app/syntax/token_class
import ../tui/app/theme/editor_theme
import ../styles/generated/design_tokens

proc ctPress(selector, key: cstring): Future[void] {.importjs:
  "window.ctPress(#, #)".}
proc ctMouse(kind: cstring; x, y: float; button: cstring;
             clickCount: int): Future[void] {.importjs:
  "window.ctMouse(#, #, #, #, #)".}
proc ctIme(composing, commit: cstring): Future[void] {.importjs:
  "window.ctIme(#, #)".}
proc ctAxTree(): Future[cstring] {.importjs: "window.ctAxTree()".}
proc ctForcedColors(on: bool): Future[void] {.importjs:
  "window.ctForcedColors(#)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc ctOnly(): cstring {.importjs: "(window.ctOnly || '')@".}
  ## The cases a harness asked for (`CT_CHROMIUM_ONLY`), or "" for all.

proc selected(name: string): bool =
  let only = $ctOnly()
  only.len == 0 or name in only.split(',')
proc settle(): Future[void] {.importjs:
  "new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)))".}

proc setHtml(html: cstring) {.importjs: "document.body.innerHTML = #".}
proc qs(sel: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc qsa(root: JsObject; sel: cstring): JsObject {.importjs: "#.querySelectorAll(#)".}
proc isNull(o: JsObject): bool {.importjs: "(# == null)".}
proc activeEl(): JsObject {.importjs: "(document.activeElement)@".}
proc textOf(e: JsObject): cstring {.importjs: "(#.textContent)".}
proc styleOf(e: JsObject; prop: cstring): cstring {.importjs:
  "getComputedStyle(#).getPropertyValue(#)".}
proc rectOf(e: JsObject): JsObject {.importjs: "#.getBoundingClientRect()".}
proc newDivEl(): JsObject {.importjs: "document.createElement('div')@".}
proc getComputed(e: JsObject; prop: cstring): JsObject {.importjs: "getComputedStyle(#).getPropertyValue(#)".}
proc num(v: JsObject): float {.importjs: "Number(#)".}
proc jsNew(): JsObject {.importjs: "({})@".}
proc newJsArray(): JsObject {.importjs: "([])@".}
proc newInputEvent(): JsObject {.importjs: "(new Event('input', {bubbles: true}))@".}
type js = JsObject
proc str(v: JsObject): string =
  ## A JavaScript value as text; "" for null and undefined.
  if v.isNil or isNull(v): "" else: $v.to(cstring)
proc jsParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc perfNow(): float {.importjs: "performance.now()@".}
proc dispatchClipboard(target: JsObject; kind, text: cstring) {.importjs: """
  ((t, kind, text) => {
    const dt = new DataTransfer();
    dt.setData('text/plain', text);
    t.dispatchEvent(new ClipboardEvent(kind, {clipboardData: dt, bubbles: true, cancelable: true}));
  })(#, #, #)""".}
proc clipboardEventText(target: JsObject; kind: cstring): cstring {.importjs: """
  ((t, kind) => {
    const dt = new DataTransfer();
    t.dispatchEvent(new ClipboardEvent(kind, {clipboardData: dt, bubbles: true, cancelable: true}));
    return dt.getData('text/plain');
  })(#, #)""".}
proc systemColour(name: cstring): cstring {.importjs: """
  ((name) => {
    const p = document.createElement('div');
    p.style.background = name;
    p.style.forcedColorAdjust = 'none';
    document.body.appendChild(p);
    const c = getComputedStyle(p).backgroundColor;
    p.remove();
    return c;
  })(#)""".}
proc pxOf(e: JsObject): float =
  ## An element's inline `top`, in pixels.
  parseFloat(($e.style.top.to(cstring)).replace("px", ""))

proc hexToRgb(hex: string): string =
  let h = hex.strip(chars = {'#'})
  "rgb(" & $parseHexInt(h[0..1]) & ", " & $parseHexInt(h[2..3]) & ", " &
    $parseHexInt(h[4..5]) & ")"

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
  Source = "def main():\n    x = 1\n    if x:\n        y = 2\n\n    return x\nprint(main())\n"
  ExpectedChecks = 131
    ## Written from a run. See the end of `main`.

proc fresh(text = Source; readOnly = false; model = bkCua;
           dark = true): SharedEditor =
  setHtml("""<button id="before">before</button>
    <div id="host" style="width: 800px; height: 400px; position: relative"></div>
    <button id="after">after</button>""")
  let live = sharedEditors
  for ed in live: ed.dispose()
  installMonacoGlobals()
  result = newSharedEditor(qs("#host"), text, "/src/main.py", "python",
                           readOnly, 14, "monospace", dark, jsNew(), model)
  result.render()

proc viewLine(n: int): JsObject = qs(cstring(".view-line[data-line=\"" & $n & "\"]"))

proc pointOf(ed: SharedEditor; line1, byteCol: int): tuple[x, y: float] =
  ## The page point over byte column `byteCol` of a drawn line (its middle,
  ## a quarter of a cell past the column's left edge).
  let base = rectOf(ed.root.querySelector(cstring".lines-content"))
  let vl = viewLine(line1)
  let r = rectOf(vl)
  (num(base.left) + ed.xOfByteCol(line1, byteCol) + ed.charWidth / 4,
   num(r.top) + num(r.height) / 2)

proc caseRendersTheDocument() {.async.} =
  beginCase()
  let ed = fresh()
  await settle()
  ck not isNull(viewLine(1)), "line 1 is drawn"
  ck $textOf(viewLine(1)) == "def main():", "line 1 reads `" & $textOf(viewLine(1)) & "`"
  ck $textOf(viewLine(4)) == "        y = 2"
  # The Monarch runner's classes, painted the editor theme's colours.
  let kw = ed.root.querySelector(cstring(".view-line[data-line=\"1\"] span.mtk-tcKeyword"))
  ck not isNull(kw), "`def` is a keyword span"
  if not isNull(kw):
    ck $textOf(kw) == "def"
    # The design system's dark keyword colour, named here rather than read
    # back from the editor, so a theme the editor got wrong cannot agree
    # with itself.
    ck $styleOf(kw, "color") == hexToRgb(DesignTokenHex[tokenClassToken(tcKeyword)][dmDark]),
      "keyword colour " & $styleOf(kw, "color")
  # The gutter: the numbers, the current line's marked active.
  let n1 = ed.root.querySelector(cstring(".margin-view-overlays div[data-line=\"1\"] .line-numbers"))
  ck not isNull(n1) and $textOf(n1) == "1"
  ck not isNull(ed.root.querySelector(cstring".line-numbers.active-line-number"))
  # The editor theme's ground.
  ck $styleOf(ed.root, "background-color") == hexToRgb("#282828"),
    "ground " & $styleOf(ed.root, "background-color")
  # The light theme's ground and keyword colour, from the same tokens.
  let light = fresh(dark = false)
  await settle()
  ck $styleOf(light.root, "background-color") == hexToRgb("#e6e2db"),
    "light ground " & $styleOf(light.root, "background-color")
  let lkw = light.root.querySelector(cstring(".view-line[data-line=\"1\"] span.mtk-tcKeyword"))
  ck not isNull(lkw) and $styleOf(lkw, "color") == hexToRgb(light.tokenColour(tcKeyword))
  # A theme switch (`monaco.editor.setTheme`) repaints an open editor.
  {.emit: ["monaco.editor.setTheme('codetracerDark');"].}
  await settle()
  ck $styleOf(light.root, "background-color") == hexToRgb("#282828"),
    "switched ground " & $styleOf(light.root, "background-color")
  endCase("the document's lines, coloured by the Monarch runner, with the gutter")

proc caseTypingReachesTheCore() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  await ctPress("", "x")
  await ctPress("", "y")
  await settle()
  ck ed.text.startsWith("xydef main"), "the document starts `" & ed.text[0 ..< 10] & "`"
  ck $textOf(viewLine(1)) == "xydef main():"
  # Undo is the core's (PLAT-32): one group for the two keys.
  discard ed.applyKeyName("Ctrl+z")
  await settle()
  ck ed.text == Source, "undo restored the text"
  discard ed.applyKeyName("Ctrl+y")
  ck ed.text.startsWith("xydef")
  endCase("printable keys are the core's text, and undo / redo are the core's")

proc caseReadOnlyRefusesText() {.async.} =
  beginCase()
  let ed = fresh(readOnly = true)
  ed.focusEditor()
  await ctPress("", "x")
  await settle()
  ck ed.text == Source, "a read-only document refused the key"
  # And the core refuses it too, on the path the desktop's router sends a
  # writable editor's keys down (`applyKey`).
  discard ed.applyKeyName("x")
  ck ed.text == Source, "the read-only core refused the key"
  # Moving and selecting still work (Monaco's read-only allows them).
  discard ed.applyKeyName("Shift+Down")
  ck not ed.doc.state.selection.mainRange.isEmpty
  endCase("a read-only editor takes no text but moves and selects")

proc caseImeComposition() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  await ctIme("にほ", "")
  await settle()
  ck str(ed.root.getAttribute(cstring"data-ct-composing")) == "true",
    "the editor shows a composition in progress"
  ck ed.text == Source, "nothing is committed while composing"
  await ctIme("", "日本")
  await settle()
  ck ed.text.startsWith("日本def"), "the commit went into the document: `" &
    ed.text[0 ..< 12] & "`"
  ck isNull(ed.root.getAttribute(cstring"data-ct-composing"))
  # A dead key arrives in Chromium as a composition of the accent and a
  # commit of the composed character.
  await ctIme("´", "")
  await ctIme("", "é")
  await settle()
  ck ed.text.startsWith("日本édef"), "the dead key's character: `" & ed.text[0 ..< 14] & "`"
  # One undo takes the commit back as a unit.
  discard ed.applyKeyName("Ctrl+z")
  ck not ed.text.contains("é")
  endCase("an input method's composition is shown and its commit is the core's text")

proc axNodes(): Future[JsObject] {.async.} =
  let s = await ctAxTree()
  return jsParse(s)

proc focusedTextbox(nodes: JsObject): JsObject =
  for i in 0 ..< num(nodes.length).int:
    let n = nodes[i]
    if str(n.role) == "textbox" and n.focused.to(bool):
      return n
  nil

proc caseScreenReader() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  await settle()
  var nodes = await axNodes()
  var tb = focusedTextbox(nodes)
  ck not tb.isNil, "a focused textbox in the accessibility tree"
  if not tb.isNil:
    ck str(tb.value) == "def main():", "it reads the caret's line: `" &
      str(tb.value) & "`"
    ck tb.multiline.to(bool)
    ck str(tb.name).contains("line 1"), "name `" & str(tb.name) & "`"
  discard facadeOf(ed).setPosition(js{lineNumber: 4, column: 9})
  await settle()
  nodes = await axNodes()
  tb = focusedTextbox(nodes)
  ck not tb.isNil and str(tb.value) == "        y = 2",
    "the caret's new line is read"
  ck not tb.isNil and str(tb.name).contains("line 4") and
     str(tb.name).contains("column 9")
  let ro = fresh(readOnly = true)
  ro.focusEditor()
  await settle()
  nodes = await axNodes()
  tb = focusedTextbox(nodes)
  ck not tb.isNil and tb.readonly.to(bool), "a read-only editor says so"
  endCase("a screen reader reads the caret's line and position")

proc caseFocusOrder() {.async.} =
  beginCase()
  let ed = fresh()
  await ctPress("#before", "Tab")
  ck activeEl() == ed.textarea, "Tab from the button before reaches the editor"
  await ctPress("", "Shift+Tab")
  ck activeEl() == qs("#before"), "Shift+Tab goes back"
  endCase("the editor is in the page's focus order")

proc caseHighContrast() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  discard facadeOf(ed).setSelection(js{startLineNumber: 1, startColumn: 1,
                               endLineNumber: 1, endColumn: 4})
  await ctForcedColors(true)
  await settle()
  let sel = ed.root.querySelector(cstring".selected-text")
  ck not isNull(sel), "the selection is drawn"
  if not isNull(sel):
    ck $styleOf(sel, "background-color") == $systemColour("Highlight"),
      "the selection is the system Highlight: " & $styleOf(sel, "background-color")
  ck $styleOf(ed.root, "background-color") == $systemColour("Canvas")
  await ctForcedColors(false)
  endCase("a forced-colours theme paints the editor in system colours")

proc caseClicksAndDrags() {.async.} =
  beginCase()
  let ed = fresh()
  await settle()
  # A click on line 2 at `x` (byte 4).
  var p = ed.pointOf(2, 4)
  await ctMouse("click", p.x, p.y, "left", 1)
  await settle()
  ck ed.doc.state.primaryHead == ed.offsetAt(2, 5),
    "the caret is at line 2 column 5 (" & $ed.positionAt(ed.doc.state.primaryHead) & ")"
  ck ed.hasTextFocus, "a click focuses the editor"
  # A click on the middle of a character puts the caret after it, as
  # Monaco does (the scenario pack aims its text anchors there).
  # (Line 3, so the browser does not count it as the first click's second.)
  let base = rectOf(ed.root.querySelector(cstring".lines-content"))
  let mx = num(base.left) + (ed.xOfByteCol(3, 4) + ed.xOfByteCol(3, 5)) / 2
  await ctMouse("click", mx, ed.pointOf(3, 4).y, "left", 1)
  await settle()
  ck ed.doc.state.primaryHead == ed.offsetAt(3, 6),
    "a press on the middle of `i` puts the caret after it (" &
    $ed.positionAt(ed.doc.state.primaryHead) & ")"
  # A double click selects the word (`return` on line 6).
  p = ed.pointOf(6, 6)
  await ctMouse("click", p.x, p.y, "left", 1)
  await ctMouse("click", p.x, p.y, "left", 2)
  await settle()
  ck ed.selectedText == "return", "double click selected `" & ed.selectedText & "`"
  # A drag from line 1 to line 3 selects across.
  let a = ed.pointOf(1, 0)
  let b = ed.pointOf(3, 6)
  await ctMouse("down", a.x, a.y, "left", 1)
  await ctMouse("move", b.x, b.y, "left", 1)
  await ctMouse("up", b.x, b.y, "left", 1)
  await settle()
  ck ed.selectedText == "def main():\n    x = 1\n    if", "drag selected `" &
    ed.selectedText & "`"
  ck not isNull(ed.root.querySelector(cstring(".view-overlays div[data-line=\"2\"] .selected-text")))
  endCase("a click places the caret, a double click selects a word, a drag selects across lines")

proc caseDecorationsAndZones() {.async.} =
  beginCase()
  let ed = fresh()
  let f = facadeOf(ed)
  let ids = f.deltaDecorations(newJsArray(), toJs([js{
    range: js{startLineNumber: 2, startColumn: 1, endLineNumber: 2, endColumn: 10},
    options: js{isWholeLine: true, className: cstring"on",
                glyphMarginClassName: cstring"gutter-glyph-breakpoint",
                inlineClassName: cstring"line-flow-hit"}}]))
  await settle()
  ck num(ids.length) == 1
  ck not isNull(ed.root.querySelector(cstring(".view-overlays div[data-line=\"2\"] .cdr.on")))
  ck not isNull(ed.root.querySelector(cstring(".glyph-margin-widgets .cgmr[data-line=\"2\"].gutter-glyph-breakpoint")))
  ck not isNull(ed.root.querySelector(cstring(".view-line[data-line=\"2\"] .line-flow-hit")))
  # The decoration follows its line when a line is typed above it.
  ed.focusEditor()
  discard ed.applyKeyName("Enter")
  await settle()
  ck not isNull(ed.root.querySelector(cstring(".view-overlays div[data-line=\"3\"] .cdr.on"))),
    "the line class moved to line 3"
  ck isNull(ed.root.querySelector(cstring(".view-overlays div[data-line=\"2\"] .cdr.on")))
  let r = f.getModel().getDecorationRange(ids[0])
  ck num(r.startLineNumber) == 3
  # A view zone after line 1 pushes line 2 down by its height.
  let zone = qs("#before").cloneNode(false)
  discard f.changeViewZones(proc(acc: JsObject) =
    discard acc.addZone(js{afterLineNumber: 1, heightInPx: 40, domNode: zone}))
  await settle()
  ck pxOf(viewLine(2)) == float(ed.lineHeight + 40),
    "line 2 top " & $pxOf(viewLine(2))
  ck pxOf(zone) == float(ed.lineHeight), "the zone's top " & $pxOf(zone)
  # Injected text (a value chip) sits at the end of its line.
  discard f.deltaDecorations(newJsArray(), toJs([js{
    range: js{startLineNumber: 4, startColumn: 10, endLineNumber: 4, endColumn: 10},
    options: js{showIfCollapsed: true,
                after: js{content: cstring"x = 1", inlineClassName: cstring"flow-chip"}}}]))
  await settle()
  let chip = ed.root.querySelector(cstring(".view-line[data-line=\"4\"] .flow-chip"))
  ck not isNull(chip) and $textOf(chip) == "x = 1"
  # A content widget at EXACT sits on its line (Monaco's
  # `ContentWidgetPositionPreference.EXACT`, the flow's value chips); one
  # whose line is not drawn is hidden, whatever `display` the page gives it.
  proc widgetAt(line: int; id: cstring): JsObject =
    let node = newDivEl()
    node.textContent = id
    node.style.display = cstring"flex"
    result = js{getId: proc(): cstring = id, getDomNode: proc(): JsObject = node,
                getPosition: proc(): JsObject =
                  js{position: js{lineNumber: line, column: 1}, preference: toJs(@[0])}}
  let near = widgetAt(3, cstring"near")
  let far = widgetAt(5000, cstring"far")
  discard facadeOf(ed).addContentWidget(near)
  discard facadeOf(ed).addContentWidget(far)
  await settle()
  let nearNode = near.getDomNode()
  ck num(rectOf(nearNode).top) == num(rectOf(viewLine(3)).top),
    "an EXACT widget is on its line, not under it"
  ck str(getComputed(far.getDomNode(), cstring"visibility")) == "hidden",
    "a widget whose line is not drawn is hidden"
  endCase("decorations and view zones through Monaco's API, following the text")

proc caseFolding() {.async.} =
  beginCase()
  let ed = fresh()
  await settle()
  let chevron = ed.root.querySelector(cstring(".margin-view-overlays div[data-line=\"3\"] .ct-fold-toggle"))
  ck not isNull(chevron), "`if x:` has a fold chevron"
  if not isNull(chevron):
    let r = rectOf(chevron)
    await ctMouse("click", num(r.left) + num(r.width) / 2, num(r.top) + num(r.height) / 2,
                  "left", 1)
    await settle()
    ck isNull(viewLine(4)), "line 4 is folded away"
    ck not isNull(viewLine(5))
    ck ed.doc.state.folded == @[2]
    let again = ed.root.querySelector(cstring(".margin-view-overlays div[data-line=\"3\"] .ct-fold-toggle"))
    ck not isNull(again) and str(again.getAttribute(cstring"data-folded")) == "true"
  # Folding through the core's operation (Ctrl+Shift+[ under CUA).
  discard ed.applyNamedOp("unfold-all")
  await settle()
  ck not isNull(viewLine(4)), "unfold-all shows line 4 again"
  endCase("a fold chevron hides the block, the core's unfold shows it")

proc caseMultipleCursorsAndClipboard() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  discard facadeOf(ed).setPosition(js{lineNumber: 2, column: 5})
  discard ed.applyNamedOp("add-cursor-below")
  await settle()
  ck ed.doc.state.selection.rangeCount == 2
  ck num(qsa(ed.root, ".cursors-layer .cursor").length) == 2, "two carets drawn"
  # Typing goes in at both carets.
  await ctPress("", "z")
  await settle()
  ck ed.lineText(2) == "    zx = 1" and ed.lineText(3) == "    zif x:",
    "lines 2-3: `" & ed.lineText(2) & "` / `" & ed.lineText(3) & "`"
  discard ed.applyKeyName("Esc")
  # Copy puts the selection on the clipboard event and in the core's register.
  discard facadeOf(ed).setSelection(js{startLineNumber: 1, startColumn: 5,
                               endLineNumber: 1, endColumn: 9})
  let copied = clipboardEventText(ed.textarea, "copy")
  ck $copied == "main", "copied `" & $copied & "`"
  ck ed.doc.clipboardText == "main"
  # Paste inserts the clipboard's text through the core.
  discard facadeOf(ed).setPosition(js{lineNumber: 7, column: 1})
  dispatchClipboard(ed.textarea, "paste", "# ")
  await settle()
  ck ed.lineText(7) == "# print(main())", "line 7 `" & ed.lineText(7) & "`"
  endCase("several carets type at once, and copy and paste carry the clipboard")

proc caseFindAndReplace() {.async.} =
  beginCase()
  let ed = fresh()
  ed.focusEditor()
  # The caret on `x` in line 2: Ctrl+F seeds the field with the word.
  discard facadeOf(ed).setPosition(js{lineNumber: 2, column: 5})
  discard ed.findCommand("find.open")
  await settle()
  ck str(ed.root.getAttribute(cstring"data-ct-find")) == "open"
  ck not isNull(ed.root.querySelector(cstring".find-widget.visible")), "Monaco's open-widget class"
  ck activeEl() == ed.findInput, "the field takes the keyboard"
  ck str(ed.findInput.value) == "x", "seeded with `" & str(ed.findInput.value) & "`"
  ck $textOf(ed.root.querySelector(cstring".ct-find-count")) == "1 of 3",
    "count `" & $textOf(ed.root.querySelector(cstring".ct-find-count")) & "`"
  ck num(qsa(ed.root, ".view-overlays .findMatch").length) == 2, "the other matches highlighted"
  ck num(qsa(ed.root, ".view-overlays .currentFindMatch").length) == 1
  # Typing into the field searches incrementally (trusted keys into the field).
  await ctPress("", "Control+a")
  for ch in "return": await ctPress("", cstring($ch))
  await settle()
  ck str(ed.findInput.value) == "return"
  ck ed.selectedText == "return", "the match is selected: `" & ed.selectedText & "`"
  # Enter walks (wrapping) and Escape closes keeping the match selected.
  await ctPress("", "Enter")
  await settle()
  ck ed.selectedText == "return"
  await ctPress("", "Escape")
  await settle()
  ck str(ed.root.getAttribute(cstring"data-ct-find")) == "closed"
  ck isNull(ed.root.querySelector(cstring".find-widget.visible"))
  ck ed.selectedText == "return" and ed.hasTextFocus
  # Replace all, as one undoable change.
  discard ed.findCommand("find.open-replace")
  ed.findInput.value = cstring"x"
  discard ed.findInput.dispatchEvent(newInputEvent())
  ed.replaceInput.value = cstring"value"
  discard ed.findCommand("find.replace-all")
  await settle()
  ck not ed.text.contains(" x"), "every `x` replaced"
  ck ed.lineText(2) == "    value = 1"
  ck $textOf(ed.root.querySelector(cstring".ct-find-count")) == "no matches"
  ed.closeFindWidget(restore = false)
  discard ed.applyKeyName("Ctrl+z")
  ck ed.text == Source, "one undo restores every replacement"
  endCase("find highlights incrementally and walks; replace all is one undoable change")

proc textModel(text: cstring): JsObject {.importjs: """
  ((t) => ({ getValue: () => t, onDidChangeContent: () => ({ dispose() {} }) }))(#)""".}
  ## THE STAND-IN, AND WHY IT IS NOT A MOCK: Monaco is not loaded in this page,
  ## and the unified diff hands its diff editor two Monaco models it built with
  ## `monaco.editor.createModel`. The shared diff editor reads exactly two
  ## members of a model — `getValue` and `onDidChangeContent` — and this
  ## object has those two, answering the model's own text.

proc caseUnifiedDiff() {.async.} =
  beginCase()
  setHtml("""<div id="host" style="width: 800px; height: 400px; position: relative"></div>""")
  let all = sharedEditors
  for e in all: e.dispose()
  let diff = newSharedDiffEditor(qs("#host"), jsNew(), 14, "monospace", true, "python")
  let before = "a = 1\nb = 2\nc = 3\nd = 4\n"
  let after = "a = 1\nc = 3\nd = 40\nd2 = 5\n"
  let models = jsNew()
  models["original"] = textModel(cstring(before))
  models["modified"] = textModel(cstring(after))
  discard diff.setModel(models)
  await settle()
  ck not isNull(qs(".monaco-diff-editor .monaco-editor.modified-in-monaco-diff-editor"))
  ck not isNull(qs(".monaco-diff-editor .monaco-editor.original-in-monaco-diff-editor"))
  # The removed lines are drawn as zones in the new revision.
  let deleted = qsa(qs(".modified-in-monaco-diff-editor"), ".view-zones .line-delete .view-line")
  var removed: seq[string] = @[]
  for i in 0 ..< num(deleted.length).int: removed.add $textOf(deleted[i])
  ck removed == @["b = 2", "d = 4"], "removed lines " & $removed
  # The added lines carry the insert class.
  ck num(qsa(qs(".modified-in-monaco-diff-editor"), ".view-overlays .cdr.line-insert").length) == 2
  let changes = diff.getLineChanges()
  ck num(changes.length) == 2
  # The view's own decorations go on each side (`createDecorationsCollection`).
  let modified = diff.getModifiedEditor()
  discard modified.createDecorationsCollection(toJs([js{
    range: js{startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1},
    options: js{isWholeLine: true, className: cstring"ct-diff-line-context"}}]))
  await settle()
  ck not isNull(qs(".modified-in-monaco-diff-editor .view-overlays .ct-diff-line-context"))
  endCase("the unified diff: removed lines as zones, added lines marked, decorations per side")

proc gutterRow(side: cstring; n: int): JsObject =
  qs(cstring("." & $side & "-in-monaco-diff-editor .margin-view-overlays > div[data-line=\"" &
             $n & "\"]"))

proc topOf(e: JsObject): float = num(rectOf(e).top)

proc caseUnifiedDiffRegions() {.async.} =
  ## What the review's and the VCS panel's diff use of Monaco's diff editor
  ## beyond the line diff: collapsed unchanged regions and their boundaries,
  ## word-level marks, coloured removed lines and the old revision aligned
  ## beside the new one.
  beginCase()
  setHtml("""<div id="host" style="width: 800px; height: 600px; position: relative"></div>""")
  let all = sharedEditors
  for e in all: e.dispose()
  var before, after: seq[string] = @[]
  for i in 1 .. 40:
    before.add "v" & $i & " = " & $i
  after = before
  before[19] = "value = compute(a, b)"
  after[19] = "value = compute(a, c)"
  after.insert("added = 1", 30)
  let opts = js{hideUnchangedRegions: js{enabled: true, contextLineCount: 3,
                                         minimumLineCount: 3, revealLineCount: 10},
                glyphMargin: false, folding: false, lineDecorationsWidth: 0}
  let diff = newSharedDiffEditor(qs("#host"), opts, 14, "monospace", true, "python")
  let models = jsNew()
  models["original"] = textModel(cstring(before.join("\n")))
  models["modified"] = textModel(cstring(after.join("\n")))
  discard diff.setModel(models)
  # Measured at once, as Monaco answers it (the review sizes its value
  # columns from these before any frame is drawn).
  let x5 = num(diff.getModifiedEditor().getOffsetForColumn(1, 11))
  ck x5 > 10.0, "a column is measured before the next frame (" & $x5 & ")"
  await settle()
  await settle()
  let modRoot = qs(".modified-in-monaco-diff-editor")
  # Three runs collapse: lines 1-16 (context below only), 24-27 (between
  # the changes) and new 35-41 (context above only).
  let bands = qsa(modRoot, ".diff-hidden-lines-widget > .diff-hidden-lines")
  ck num(bands.length) == 3, "three collapsed regions (" & $num(bands.length) & ")"
  let regions = diff["_diffModel"].get()["unchangedRegions"].get()
  ck num(regions.length) == 3
  ck num(regions[0]["lineCount"]) == 16 and num(regions[0]["modifiedLineNumber"]) == 1
  ck $textOf(bands[0].querySelector(cstring".center")) == "16 hidden lines",
     "the band says what it hides: " & $textOf(bands[0].querySelector(cstring".center"))
  # The band spans the editor, gutter included (Monaco draws it as an
  # overlay at its zone's place), level with the room its zone holds.
  let band1 = bands[1]
  ck abs(num(rectOf(band1.querySelector(cstring".center")).left) - num(rectOf(modRoot).left)) < 1.0,
     "the band starts at the editor's left edge"
  let holder1 = qsa(modRoot, ".view-zones .ct-diff-band-zone")[1]
  ck abs(num(rectOf(band1.parentNode).top) - num(rectOf(holder1).top)) < 1.0,
     "the band is drawn where its zone is"
  ck not isNull(bands[0].querySelector(cstring":scope > .top")) and
     not isNull(bands[0].querySelector(cstring":scope > .bottom[role=button]"))
  ck isNull(qs(".modified-in-monaco-diff-editor .view-line[data-line=\"1\"]")),
     "a hidden line is not drawn"
  ck not isNull(qs(".modified-in-monaco-diff-editor .view-line[data-line=\"17\"]"))
  # Word-level marks: only the changed word, in each revision.
  let ins = qsa(modRoot, ".view-lines .char-insert")
  var insText: seq[string] = @[]
  for i in 0 ..< num(ins.length).int: insText.add $textOf(ins[i])
  ck insText == @["c"], "only the inserted word is marked: " & $insText
  ck num(qsa(modRoot, ".view-overlays .cdr.char-insert").length) == 1,
     "an added-only line is marked whole-line"
  let dels = qsa(modRoot, ".view-zones .line-delete .char-delete")
  ck num(dels.length) == 1 and $textOf(dels[0]) == "b",
     "the removed word is marked in the removed line"
  # The removed line coloured by the old revision's tokens.
  let delSpans = qsa(modRoot, ".view-zones .line-delete .view-line span[class^='mtk']")
  var kinds: seq[string] = @[]
  for i in 0 ..< num(delSpans.length).int:
    for c in ($delSpans[i].className.to(cstring)).split(' '):
      # Monaco's numbered token classes (`mtk1`, `mtk5`, …), what the
      # review's checks count
      if c.len > 3 and c.startsWith("mtk") and c[3] in {'0'..'9'} and c notin kinds:
        kinds.add c
  ck kinds.len >= 2, "the removed line has token colours: " & $kinds
  # The old revision is a strip as wide as its numbers: the diff's options
  # turn the glyph, decoration and folding lanes off.
  let stripMargin = qs(".original-in-monaco-diff-editor .margin")
  ck num(rectOf(stripMargin).width) < 40.0,
     "the old revision's gutter is its numbers (" & $num(rectOf(stripMargin).width) & " px)"
  # The old revision beside the new one, row for row: old line 20 (removed)
  # beside its block, old line 21 beside new line 21.
  let delRow = qs(".modified-in-monaco-diff-editor .view-zones .line-delete .view-line")
  ck not isNull(gutterRow("original", 20)) and
     abs(topOf(gutterRow("original", 20)) - topOf(delRow)) < 1.0,
     "the removed line's old number is beside it"
  ck abs(topOf(gutterRow("original", 21)) - topOf(gutterRow("modified", 21))) < 1.0
  ck isNull(gutterRow("original", 1)), "the old revision hides the region too"
  # A block the view adds to the new revision is matched in the old one.
  let zone = jsNew()
  zone["afterLineNumber"] = 22
  zone["heightInPx"] = 50
  zone["domNode"] = newDivEl()
  let modFacade = diff.getModifiedEditor()
  discard modFacade.changeViewZones(proc(acc: JsObject) = discard acc.addZone(zone))
  await settle()
  ck abs(topOf(gutterRow("original", 23)) - topOf(gutterRow("modified", 23))) < 1.0,
     "a view zone has its spacer in the old revision"
  ck abs(topOf(gutterRow("original", 31)) - topOf(gutterRow("modified", 32))) < 1.0,
     "below an added line the rows still line up"
  # A press on the lower handle reveals ten lines; the band says six.
  let bottomHandle = bands[0].querySelector(cstring":scope > .bottom")
  let br = rectOf(bottomHandle)
  let bx = num(br.left) + num(br.width) / 2
  let by = num(br.top) + num(br.height) / 2
  await ctMouse("move", bx, by, "left", 1)
  await ctMouse("down", bx, by, "left", 1)
  await ctMouse("up", bx, by, "left", 1)
  await settle()
  let bands2 = qsa(modRoot, ".diff-hidden-lines")
  ck $textOf(bands2[0].querySelector(cstring".center")) == "6 hidden lines",
     "a press reveals ten lines: " & $textOf(bands2[0].querySelector(cstring".center"))
  let r0 = diff["_diffModel"].get()["unchangedRegions"].get()[0]
  ck num(r0["visibleLineCountBottom"].get()) == 10,
     "the lower end shows ten (" & $num(r0["visibleLineCountTop"].get()) & "/" &
     $num(r0["visibleLineCountBottom"].get()) & ")"
  # A view zone after the last hidden line (6) is shown — the line after it
  # (7) is — where the hidden lines are, above the region's band and line 7,
  # as Monaco shows it.
  let late = newDivEl()
  let lateZone = jsNew()
  lateZone["afterLineNumber"] = 6
  lateZone["heightInPx"] = 30
  lateZone["domNode"] = late
  discard modFacade.changeViewZones(proc(acc: JsObject) = discard acc.addZone(lateZone))
  await settle()
  var lateTop = 0.0
  {.emit: [lateTop, " = parseFloat(", late, ".style.top);"].}
  ck $late.style.display.to(cstring) != "none" and
     abs(lateTop + 30.0 + 24.0 - num(modFacade.getTopForLineNumber(7))) < 1.0,
     "a zone after a hidden line stays, above the band and line 7 (" & $lateTop & ", " &
     $num(modFacade.getTopForLineNumber(7)) & ")"
  # A drag on the upper handle of the middle region, three lines down.
  let topHandle = bands2[1].querySelector(cstring":scope > .top")
  let tr = rectOf(topHandle)
  let tx = num(tr.left) + num(tr.width) / 2
  let ty = num(tr.top) + num(tr.height) / 2
  let lh = float(sharedEditors[^1].lineHeight)   # the new revision's editor
  await ctMouse("move", tx, ty, "left", 1)
  await ctMouse("down", tx, ty, "left", 1)
  await ctMouse("move", tx, ty + lh * 1.5, "left", 1)
  await ctMouse("move", tx, ty + lh * 3.0, "left", 1)
  await ctMouse("up", tx, ty + lh * 3.0, "left", 1)
  await settle()
  let r1 = diff["_diffModel"].get()["unchangedRegions"].get()[1]
  ck num(r1["visibleLineCountTop"].get()) == 3,
     "a drag of three line heights reveals three lines (" &
     $num(r1["visibleLineCountTop"].get()) & ")"
  var sizeChanges = 0
  discard modFacade.onDidContentSizeChange(proc(e: JsObject) = inc sizeChanges)
  # The unfold control shows the whole region: its band goes.
  let unfold = qsa(modRoot, ".diff-hidden-lines")[0].querySelector(cstring".center a[role=button]")
  discard unfold.click()
  await settle()
  ck num(qsa(modRoot, ".diff-hidden-lines").length) == 2, "the unfolded region has no band"
  var stillHidden = false
  for span in sharedEditors[^1].allHidden:
    if span.first <= 15: stillHidden = true
  ck not stillHidden, "lines 1-16 are shown again: " & $sharedEditors[^1].allHidden
  await settle()
  ck sizeChanges > 0, "the content grew, and the editor said so (onDidContentSizeChange)"
  # Tab from the text reaches a zone's controls and then the bands, as from
  # Monaco's text area (first in its overflow guard).
  var tabOrder = false
  let ta = qs(".modified-in-monaco-diff-editor textarea.inputarea")
  let zoneEl = qs(".modified-in-monaco-diff-editor .view-zones")
  let bandEl = qs(".modified-in-monaco-diff-editor .diff-hidden-lines .top")
  {.emit: [tabOrder, " = !!(", ta, ".compareDocumentPosition(", zoneEl, ") & 4) && !!(", zoneEl, ".compareDocumentPosition(", bandEl, ") & 4);"].}
  ck tabOrder, "the text area, then the zones, then the bands, in document order"
  # One scroll position for both revisions.
  discard modFacade.setScrollTop(100)
  await settle()
  ck num(diff.getOriginalEditor().getScrollTop()) == num(modFacade.getScrollTop()),
     "the old revision scrolls with the new one"
  endCase("the unified diff: collapsed regions and their handles, word marks, coloured removed lines, the old revision aligned")

proc caseNimColours() {.async.} =
  ## Nim, which Monaco colours with the desktop's own Monarch definition
  ## (`languages/nimLanguage.js`), is coloured with the same definition here:
  ## a Nim file — the unified diff of a Nim commit among them — is not plain.
  beginCase()
  setHtml("""<div id="host" style="width: 800px; height: 200px; position: relative"></div>""")
  let live = sharedEditors
  for ed in live: ed.dispose()
  let ed = newSharedEditor(qs("#host"),
    "proc main(x: int): string =\n  let y = \"hello\" # note\n  result = $x & y\n",
    "", "nim", true, 14, "monospace", true, jsNew())
  ed.render()
  await settle()
  var kinds: seq[string] = @[]
  let spans = qsa(ed.root, ".view-lines .view-line span span")
  for i in 0 ..< num(spans.length).int:
    for c in ($spans[i].className.to(cstring)).split(' '):
      if c.len > 3 and c.startsWith("mtk") and c[3] in {'0'..'9'} and c notin kinds:
        kinds.add c
  ck kinds.len >= 4, "a Nim file in several token colours: " & $kinds
  endCase("Nim is coloured by the desktop's own Monarch definition")

proc caseBracketsAndWheel() {.async.} =
  beginCase()
  var lines: seq[string] = @[]
  for i in 1 .. 300: lines.add "value_" & $i & " = (" & $i & ")"
  let ed = fresh(lines.join("\n"))
  discard facadeOf(ed).setPosition(js{lineNumber: 1, column: 12})
  await settle()
  ck num(qsa(ed.root, ".bracket-match").length) == 2, "the bracket and its partner"
  let before = ed.scrollTop
  let r = rectOf(ed.root)
  await ctMouse("move", num(r.left) + 200, num(r.top) + 100, "left", 1)
  await ctMouse("wheel", 0, 300, "left", 1)
  await settle()
  ck ed.scrollTop > before, "the wheel scrolled (" & $ed.scrollTop & ")"
  ck isNull(viewLine(1)), "line 1 scrolled out of the drawn window"
  endCase("bracket matching at the caret, and the wheel scrolls")

proc caseScrollRangeAndViewState() {.async.} =
  beginCase()
  # Monaco's scroll range: with `scrollBeyondLastLine` (its default, the
  # desktop's source editors') a line near the end is centred, the last
  # line able to reach the top; without it the view stops at the last line.
  var lines: seq[string] = @[]
  for i in 1 .. 60: lines.add "row_" & $i
  let ed = fresh(lines.join("\n"))
  let f = facadeOf(ed)
  discard f.revealLineInCenter(55)
  await settle()
  let vh = ed.height
  let lh = ed.lineHeight
  ck ed.scrollTop == ed.topForLine(55) - (vh - lh) div 2,
    "line 55 centred past the last screenful (" & $ed.scrollTop & ")"
  ck num(f.getScrollHeight()) == float(60 * lh - lh + vh), "Monaco's scroll height"
  ed.options[cstring"scrollBeyondLastLine"] = false
  discard f.setScrollTop(100_000)
  await settle()
  ck ed.scrollTop == 60 * lh - vh, "without it, the last line stops at the bottom"
  # The view state Monaco gives back on a re-mount (a mode switch): every
  # cursor's selection, with its direction.
  discard f.setSelections(toJs(@[
    js{startLineNumber: 2, startColumn: 1, endLineNumber: 2, endColumn: 4},
    js{startLineNumber: 5, startColumn: 1, endLineNumber: 5, endColumn: 3}]))
  let state = f.saveViewState()
  discard f.setPosition(js{lineNumber: 9, column: 1})
  discard f.restoreViewState(state)
  let sels = f.getSelections()
  ck num(sels.length) == 2, "both selections back"
  ck str(f.getModel().getValueInRange(sels[0])) == "row" and
     str(f.getModel().getValueInRange(sels[1])) == "ro", "with their text"
  endCase("Monaco's scroll range, and the view state carries every selection")

proc caseHugeFile() {.async.} =
  beginCase()
  # 200,000 lines (PLAT-24's corpus size): the editor opens it, draws only
  # the viewport, and the line-splitting keystroke costs about the same at
  # the first line as at the last (Editor-ViewModel.md §4.1's gate, < 4x).
  var lines = newSeqOfCap[string](200_000)
  for i in 1 .. 200_000: lines.add "    let value_" & $i & " = compute(" & $i & ", other)"
  let text = lines.join("\n")
  echo "    huge file: text built"
  let t0 = perfNow()
  let ed = fresh(text)
  let opened = perfNow() - t0
  echo "    huge file: opened in " & $opened & " ms"
  ck ed.lineCount == 200_000
  ck num(qsa(ed.root, ".view-line").length) < 60, "only the viewport is drawn"
  ed.focusEditor()
  proc enterAt(line: int): float =
    # The line split is left in place: one more line changes nothing the
    # gate compares, and an undo would double the keystrokes this case
    # costs on a loaded lane.
    discard facadeOf(ed).setPosition(js{lineNumber: line, column: 5})
    let s = perfNow()
    discard ed.applyKeyName("Enter")
    ed.render()
    result = perfNow() - s
  # The first keystroke pays the engine's warm-up; it is not a take.
  discard enterAt(100_000)
  var first, last: seq[float]
  for k in 0 ..< 2:
    first.add enterAt(1)
    last.add enterAt(ed.lineCount)
    echo "    huge file: take " & $k & ": " & $first[^1] & " / " & $last[^1] & " ms"
  # The best take of each: on a loaded machine the slower take measures
  # the machine.
  proc best(xs: seq[float]): float = min(xs)
  let ratio = best(first) / max(0.001, best(last))
  echo "    huge file: opened in " & $opened.int & " ms; Enter at line 1 " &
    $best(first) & " ms, at the last line " & $best(last) & " ms, ratio " & $ratio
  ck ratio < 4.0, "Enter at line 1 / at the last line = " & $ratio
  discard facadeOf(ed).revealLineInCenter(150_000)
  await settle()
  ck not isNull(viewLine(150_000)), "line 150,000 is drawn after a reveal"
  endCase("a 200,000-line file opens, scrolls and edits with the keystroke gate held")

proc guarded(c: proc(): Future[void]; name: string) {.async.} =
  ## A case that raises fails, by name, with the exception's message and the
  ## Nim stack, and the suite goes on to the next case. A case a harness did
  ## not ask for (`CT_CHROMIUM_ONLY`) is skipped.
  if not selected(name): return
  try:
    await c()
  except CatchableError, Defect:
    inc failedCases
    echo "  [FAILED] " & name & " raised " & getCurrentExceptionMsg()
    echo getStackTrace(getCurrentException())

proc main() {.async.} =
  echo ""
  echo "[Suite] the shared editor in a browser"
  await guarded(caseRendersTheDocument, "caseRendersTheDocument")
  await guarded(caseTypingReachesTheCore, "caseTypingReachesTheCore")
  await guarded(caseReadOnlyRefusesText, "caseReadOnlyRefusesText")
  await guarded(caseImeComposition, "caseImeComposition")
  await guarded(caseScreenReader, "caseScreenReader")
  await guarded(caseFocusOrder, "caseFocusOrder")
  await guarded(caseHighContrast, "caseHighContrast")
  await guarded(caseClicksAndDrags, "caseClicksAndDrags")
  await guarded(caseDecorationsAndZones, "caseDecorationsAndZones")
  await guarded(caseFolding, "caseFolding")
  await guarded(caseMultipleCursorsAndClipboard, "caseMultipleCursorsAndClipboard")
  await guarded(caseFindAndReplace, "caseFindAndReplace")
  await guarded(caseUnifiedDiff, "caseUnifiedDiff")
  await guarded(caseUnifiedDiffRegions, "caseUnifiedDiffRegions")
  await guarded(caseNimColours, "caseNimColours")
  await guarded(caseBracketsAndWheel, "caseBracketsAndWheel")
  await guarded(caseScrollRangeAndViewState, "caseScrollRangeAndViewState")
  await guarded(caseHugeFile, "caseHugeFile")
  beginCase()
  inc checks
  echo "CHECKS: " & $checks
  if ($ctOnly()).len == 0 and checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
