## element_operations_dom_test.nim
##
## Input-Routing-And-Keymaps.md §5.1 on the DOM front-ends, for the presses that
## were view-held `mousedown` handlers until 2026-11-14: an element carrying its
## operation with the procedure bound to it (`viewmodel/input/element_operations`),
## pressed through the window's one pointer listener (`viewmodel/input/dom_pointer`)
## and the router, in a real DOM.
##
## What is held, each against the shipped router over the shipped CUA base
## keymap and the shipped user-keymap parser:
##   * a bound element in a pane runs its procedure on a click, with and
##     without Ctrl, and a user's row for the press takes it over;
##   * an element outside every pane (a popup on the body) is routed too;
##   * an element pressed on the press (`data-ct-press="down"`, one inside
##     Monaco) runs on its `mousedown`, the press goes no further, and its
##     click does not run it again;
##   * an inline value (`elementKind == value`): its plain press runs what it
##     carries, `Ctrl+Click` the pointer keymap's `scratchpad.add-value` on it;
##   * an element carrying its operation for its double click
##     (`DoubleClick:<operation>`, the unified diff's band label) runs it on
##     its `dblclick` and not on either of the clicks the browser delivers
##     before it;
##   * the mouse's side buttons are pointer rows (`BackClick`,
##     `ForwardClick` → `navigation.back` / `navigation.forward`);
##   * a cut table cell's `…` is named by the table panes' own hit test and
##     runs `list.show-detail` on its row.
##
## THE CONTROLS. Before the listener is installed no press runs anything: the
## elements hold no handler of their own. A user's row takes each kind of press
## over. And a `mousedown` listener on the pressed element's parent does not
## hear a press-down element's press.
##
## jsdom lays nothing out, so every rectangle is empty: the `…` press is made at
## clientX 0, which is on the right edge of an empty cell, and one at 50 is
## not on it. jsdom's canvas has no 2D context, which the cells measure a
## character with; a stand-in measures at a fixed advance. No other doubles.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[jsffi, unittest]

import ../viewmodel/input/[dom_pointer, element_operations]
import ../viewmodel/views/table_overflow_dom
import ../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                            keymap_router, user_keymap]
import ../viewmodel/viewmodels/product_mode
from ../../common/key_names import kpNative

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)

proc newEl(html: cstring): JsObject {.importjs: """
  (function (html) {
    var host = document.createElement('div');
    host.innerHTML = html;
    var el = host.firstElementChild;
    document.body.appendChild(el);
    return el;
  })(#)""".}
proc query(root: JsObject; selector: cstring): JsObject {.importjs: "#.querySelector(#)".}
proc click(el: JsObject; ctrl = false) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('click', { bubbles: true,
    cancelable: true, button: 0, ctrlKey: # }))""".}
proc dblClick(el: JsObject) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('dblclick', { bubbles: true,
    cancelable: true, button: 0, detail: 2 }))""".}
proc mouseDown(el: JsObject; button = 0; x = 0) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true,
    cancelable: true, button: #, clientX: # }))""".}
proc countMouseDowns(el: JsObject): JsObject {.importjs: """
  (function (el) {
    var box = { n: 0 };
    el.addEventListener('mousedown', function () { box.n++; });
    return box;
  })(#)""".}

{.emit: """
if (window.HTMLCanvasElement) {
  // jsdom's canvas has no 2D context; the table cells measure a character
  // with one. A stand-in at a fixed advance: nothing here reads a size.
  window.HTMLCanvasElement.prototype.getContext = function () {
    return { font: '', measureText: (t) => ({ width: String(t).length * 7 }) };
  };
}
""".}

var failed = 0
template ck(cond: untyped) =
  ## Evaluates `cond` once: a press is an action, not only a value.
  let ok = cond
  if not ok:
    inc failed
  check ok

proc routeWith(router: KeymapRouter) =
  installDomPointerRouting(routerResolver(router,
    SessionFacts(product: pmDebug, replayLoaded: true)))

let pane = newEl(cstring"""<div data-scope-kind="pane" data-scope-id="calltrace">
  <span class="bound">bound</span>
  <div class="zone"><span class="down">down</span></div>
  <span class="value">42</span>
  <span class="twice">12 hidden lines</span>
</div>""")
let popup = newEl(cstring"""<div class="popup"><span class="loose">x</span></div>""")
let editor = newEl(cstring"""<div data-scope-kind="pane" data-scope-id="editor">
  <span class="chip">7</span></div>""")
let tablePaneEl = newEl(cstring"""<div data-scope-kind="pane" data-scope-id="eventLog">
  <table><tr><td data-ct-cell="event-log|5|text" data-ct-cut="text">a long te…</td></tr></table>
</div>""")

var runs: seq[string] = @[]
bindElementOperation(pane.query(cstring".bound"), "test.bound",
  proc(p: PressInfo) = runs.add("bound" & (if p.ctrl: "+ctrl" else: "")))
bindPressOperation(pane.query(cstring".down"), "test.down",
  proc(p: PressInfo) = runs.add "down")
bindElementOperation(pane.query(cstring".twice"), "test.twice",
  (proc(p: PressInfo) = runs.add "twice"), gesture = "DoubleClick")
bindElementOperation(popup.query(cstring".loose"), "test.loose",
  proc(p: PressInfo) = runs.add "loose")
let chip = editor.query(cstring".chip")
discard chip.setAttribute(cstring(ElementKindAttribute), cstring"value")
bindElementOperation(chip, "test.jump", proc(p: PressInfo) = runs.add "jump")
bindElementOperation(chip, "scratchpad.add-value",
  (proc(p: PressInfo) = runs.add "scratchpad"), carried = false)
registerElementOperation("navigation.back", proc(p: ElementPress): bool =
  runs.add "back"
  true)
registerElementOperation("navigation.forward", proc(p: ElementPress): bool =
  runs.add "forward"
  true)
discard attachTableOverflow(tablePaneEl, EventLogDetailPane, cstring"tr")

suite "an element that carries its operation is pressed through the router":
  test "CONTROL: with no pointer listener, nothing runs":
    pane.query(cstring".bound").click()
    pane.query(cstring".down").mouseDown()
    popup.query(cstring".loose").click()
    pane.query(cstring".twice").dblClick()
    pane.mouseDown(button = 3)
    ck runs.len == 0

  test "a bound element runs its procedure on its click, Ctrl or not":
    routeWith(initKeymapRouter(bkCua, Desktop))
    runs = @[]
    pane.query(cstring".bound").click()
    pane.query(cstring".bound").click(ctrl = true)
    ck runs == @["bound", "bound+ctrl"]

  test "an element outside every pane is routed too":
    runs = @[]
    popup.query(cstring".loose").click()
    ck runs == @["loose"]

  test "an element pressed on the press runs on its mousedown, once":
    runs = @[]
    let heard = countMouseDowns(pane.query(cstring".zone"))
    pane.query(cstring".down").mouseDown()
    ck runs == @["down"]
    # The press went no further: what lies under the element did not hear it.
    ck heard.n.to(int) == 0
    pane.query(cstring".down").click()
    ck runs == @["down"]

  test "a double click's reference runs on the double click only":
    runs = @[]
    let twice = pane.query(cstring".twice")
    ck $twice.getAttribute(cstring(OperationAttribute)).to(cstring) ==
       "DoubleClick:test.twice"
    # The browser's two clicks, then its `dblclick`.
    twice.click()
    twice.click()
    ck runs.len == 0
    twice.dblClick()
    ck runs == @["twice"]

  test "an inline value: its press is its own, Ctrl+Click the scratchpad's":
    runs = @[]
    chip.click()
    chip.click(ctrl = true)
    ck runs == @["jump", "scratchpad"]

  test "the mouse's side buttons are pointer rows":
    runs = @[]
    pane.mouseDown(button = 3)
    pane.mouseDown(button = 4)
    popup.mouseDown(button = 3)
    ck runs == @["back", "forward", "back"]

  test "a cut cell's … shows its row's detail; the rest of the cell does not":
    let cell = tablePaneEl.query(cstring"[data-ct-cell]")
    cell.mouseDown(x = 50)
    ck not openDetail.isOpenIn(EventLogDetailPane)
    cell.mouseDown(x = 0)
    ck openDetail.isOpenIn(EventLogDetailPane)
    ck openDetail.key == "5"
    cell.mouseDown(x = 0)
    ck not openDetail.isOpenIn(EventLogDetailPane)

  test "CONTROL: a user's row for each press takes it over":
    let router = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap("""[
      { "key": "click", "command": "debugger.continue",
        "when": "paneKind == calltrace && elementKind == button" },
      { "key": "click", "command": "debugger.continue",
        "when": "paneKind == editor && elementKind == value" },
      { "key": "backclick", "command": "debugger.continue" },
      { "key": "click", "command": "debugger.continue",
        "when": "paneKind == eventLog && elementKind == value" },
      { "key": "doubleclick", "command": "debugger.continue",
        "when": "paneKind == calltrace && elementKind == button" } ]"""))
    ck router.errors.len == 0
    routeWith(router)
    runs = @[]
    pane.query(cstring".bound").click()
    pane.query(cstring".down").mouseDown()
    chip.click()
    pane.query(cstring".twice").dblClick()
    pane.mouseDown(button = 3)
    tablePaneEl.query(cstring"[data-ct-cell]").mouseDown(x = 0)
    ck runs.len == 0
    ck not openDetail.isOpenIn(EventLogDetailPane)
    routeWith(initKeymapRouter(bkCua, Desktop))

if failed > 0:
  {.emit: "process.exitCode = 1;".}
