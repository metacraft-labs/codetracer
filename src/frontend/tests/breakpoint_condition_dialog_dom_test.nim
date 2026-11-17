## breakpoint_condition_dialog_dom_test.nim
##
## The "Edit breakpoint condition" dialog (`ui/breakpoint_condition_dialog`)
## in a real DOM, held to Input-Routing-And-Keymaps.md §5.1 and §6: the dialog
## holds no press handler; a press on OK or Cancel goes through the window's
## one pointer listener (`viewmodel/input/dom_pointer`) and the router, and
## runs the operation the button carries (`breakpoint-condition.apply`,
## `breakpoint-condition.cancel`); the field's Enter and Escape are the
## field's own keys, and Escape elsewhere closes it through `dismissals`. A
## press on the backdrop is an `overlay` element's, carrying
## `breakpoint-condition.cancel`, routed the same way.
##
## The presses are real `MouseEvent`s dispatched on the buttons, the keys
## real `KeyboardEvent`s on the field. The router is the shipped
## `KeymapRouter` over the shipped CUA base keymap, as the desktop's key
## router installs it (`ui/key_router` calls `installDomPointerRouting`); a
## user's `keybindings.json` row is parsed by the shipped parser.
##
## THE CONTROLS. Before the pointer listener is installed, a click on OK
## applies nothing and leaves the dialog open: the dialog's buttons hold no
## handler of their own (before they were routed, their `click` listeners
## applied here). And a user's row for a press on the dialog's buttons takes
## it over, so OK applies nothing: a button that handled its press itself
## would still apply.
##
## No doubles: the dialog, the listener, the router and the keymaps are the
## product's; `apply` is the caller's callback, recorded.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[jsffi, unittest]

import ../ui/breakpoint_condition_dialog
import ../viewmodel/input/[dom_pointer, element_press]
import ../viewmodel/keymap/[base_keymaps, context_keys, editing_keymap,
                            keymap_router, user_keymap]
import ../viewmodel/viewmodels/product_mode
from ../../common/key_names import kpNative

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)

proc query(selector: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc click(el: JsObject) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('click', { bubbles: true,
    cancelable: true, button: 0 }))""".}
proc mouseDown(el: JsObject) {.importjs: """
  #.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true,
    cancelable: true, button: 0 }))""".}
proc keyDown(el: JsObject; key: cstring) {.importjs: """
  #.dispatchEvent(new window.KeyboardEvent('keydown', { bubbles: true,
    cancelable: true, key: # }))""".}
proc askDismissals(): bool {.importjs: """
  (function () {
    // What the key router does before it routes Escape
    // (`keyboard_focus.closeOpenDropdown`): each registered surface, newest
    // first, until one closed something.
    var list = globalThis.__ctDismissals || [];
    for (var i = list.length - 1; i >= 0; i--) if (list[i]()) return true;
    return false;
  })()""".}

var failed = 0
template ck(cond: untyped) =
  ## Evaluates `cond` once: a press is an action, not only a value.
  let ok = cond
  if not ok:
    inc failed
  check ok

var applied: seq[string] = @[]

proc show(condition = "x > 1") =
  showBreakpointConditionDialog(cstring"main.c:7", cstring(condition),
    proc(c: cstring) = applied.add $c)

proc field(): JsObject = query(cstring".breakpoint-condition-input")
proc okButton(): JsObject = query(cstring"[data-action='apply']")
proc cancelButton(): JsObject = query(cstring"[data-action='cancel']")
proc backdrop(): JsObject = query(cstring".breakpoint-condition-dialog-backdrop")

proc routeWith(router: KeymapRouter) =
  installDomPointerRouting(routerResolver(router,
    SessionFacts(product: pmDebug, replayLoaded: true)))

suite "the breakpoint condition dialog's presses and keys are routed":
  test "CONTROL: with no pointer listener, OK and the backdrop do nothing":
    applied = @[]
    show()
    okButton().click()
    backdrop().mouseDown()
    ck applied.len == 0
    ck breakpointConditionDialogOpen()
    closeBreakpointConditionDialog()
    # ... and a row for the backdrop's press takes that one.
    let backdropRow = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[ { "key": "click", "command": "debugger.continue",
             "when": "paneKind == breakpointCondition && elementKind == overlay" } ]"""))
    ck backdropRow.errors.len == 0
    routeWith(backdropRow)
    show()
    backdrop().mouseDown()
    ck breakpointConditionDialogOpen()
    closeBreakpointConditionDialog()
    ck not breakpointConditionDialogOpen()

  test "OK applies the field's text, trimmed, through the router":
    routeWith(initKeymapRouter(bkCua, Desktop))
    applied = @[]
    show()
    ck $okButton().getAttribute(cstring(OperationAttribute)).to(cstring) ==
      BreakpointConditionApply
    field().value = cstring"  y == 2  "
    okButton().click()
    ck applied == @["y == 2"]
    ck not breakpointConditionDialogOpen()

  test "Cancel closes it and applies nothing":
    applied = @[]
    show()
    cancelButton().click()
    ck applied.len == 0
    ck not breakpointConditionDialogOpen()

  test "the field's Enter applies, its Escape cancels":
    applied = @[]
    show("a")
    field().value = cstring"b"
    field().keyDown(cstring"Enter")
    ck applied == @["b"]
    ck not breakpointConditionDialogOpen()
    show("c")
    field().keyDown(cstring"Escape")
    ck applied == @["b"]
    ck not breakpointConditionDialogOpen()

  test "a press on the backdrop cancels; one on the dialog does not":
    applied = @[]
    show()
    query(cstring".breakpoint-condition-dialog").mouseDown()
    field().mouseDown()
    ck breakpointConditionDialogOpen()
    # A text selection dragged out of the field, released on the backdrop:
    # its click lands on the backdrop, and is no press of it.
    backdrop().click()
    ck breakpointConditionDialogOpen()
    backdrop().mouseDown()
    ck not breakpointConditionDialogOpen()
    ck applied.len == 0

  test "Escape on the window closes it, through dismissals":
    applied = @[]
    show()
    ck askDismissals()
    ck not breakpointConditionDialogOpen()
    ck applied.len == 0
    # With the dialog closed, it closes nothing.
    ck not askDismissals()

  test "CONTROL: a user's row for a press on its buttons takes it over":
    let router = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[ { "key": "click", "command": "debugger.continue",
             "when": "paneKind == breakpointCondition && elementKind == button" } ]"""))
    ck router.errors.len == 0
    routeWith(router)
    applied = @[]
    show()
    okButton().click()
    ck applied.len == 0
    ck breakpointConditionDialogOpen()
    closeBreakpointConditionDialog()
    # ... and a row for the backdrop's press takes that one.
    let backdropRow = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[ { "key": "click", "command": "debugger.continue",
             "when": "paneKind == breakpointCondition && elementKind == overlay" } ]"""))
    ck backdropRow.errors.len == 0
    routeWith(backdropRow)
    show()
    backdrop().mouseDown()
    ck breakpointConditionDialogOpen()
    closeBreakpointConditionDialog()
    # The base again: OK is OK.
    routeWith(initKeymapRouter(bkCua, Desktop))
    show()
    okButton().click()
    ck applied == @["x > 1"]

if failed > 0:
  {.emit: "process.exitCode = 1;".}
