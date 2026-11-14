## dom_pointer.nim — A PRESS ON A PANE'S ELEMENT, IN A DOM FRONT-END: THE ONE
## POINTER LISTENER, ITS HIT TEST AND THE PROCEDURES IT RUNS.
##
## Input-Routing-And-Keymaps.md §5.1: a press on an element resolves through the
## pointer keymap (`viewmodel/keymap/pointer_rows`, a user's `keybindings.json`)
## to an operation, and the front-end performs it on the element pressed. The
## terminal and the GPUI window hit-test their cells into a pane, an element
## kind and a `ContextTarget`; this module is the half every DOM front-end (the
## desktop and web renderer, a VS Code panel's webview) shares:
##
##   * `domElementAt` — the HIT TEST: the DOM element under a press and its
##     kind (`row`, `toggle`, `header`, `value`, `button`), read off the pane's
##     own markup by selector, innermost first;
##   * the PROCEDURES — one per operation a pane's element runs, each taking the
##     element pressed (`ElementPress`) and acting on the pane's ViewModel,
##     registered by the host (`registerElementOperation`): the session's panes
##     by `dom_pane_presses`, the desktop's own panes by their `ui/` modules;
##   * `installDomPointerRouting` — the ONE listener per window for `click`,
##     `dblclick`, `contextmenu` and `auxclick`, and `mousedown` for the
##     mouse's side buttons (resolved in the capture phase,
##     a base row performed when the press bubbles back to the window): the press's scope
##     from the DOM (`data-scope-kind` / `data-scope-id`), the element and its
##     kind, the gesture with its modifiers, resolved by the host's router and
##     performed here. A button's primary press with no row of its own runs
##     the operation the button carries (`data-ct-operation`; `element_press`),
##     as `pressElement` does on the terminal and in the GPUI window.
##
## So a pane's view draws its elements and their identity (`data-*` attributes)
## and nothing else: what a press on them does is the keymap's row and the
## procedure, and a user's row takes the press over the same way it does on the
## terminal and in the GPUI window.
##
## Refuses to own: what an operation means (the catalogue), which operation a
## gesture runs (the host's router over the pointer keymap), and the procedures
## themselves (beside each pane's ViewModel).

when not defined(js):
  {.error: "viewmodel/input/dom_pointer is a DOM front-end's (JS).".}

import std/[jsffi, strutils, tables]
import ../keymap/[scope_path, editing_keymap]
import ../../../common/key_names
import ./element_press

export element_press.OperationAttribute

type
  ElementPress* = object
    ## A press on a pane's element, as the procedure that performs its
    ## operation receives it.
    element*: JsObject
      ## The element the hit test found (`domElementAt`): the row, the
      ## toggle, the header cell — what the selectors below name.
    event*: JsObject
      ## The DOM event of the press (its coordinates, for the frame).
    pane*: string
      ## The pane's kind (`paneKind`), as the scope path names it.

  ElementProc* = proc(press: ElementPress): bool {.closure.}
    ## Performs an operation on the element pressed; false when it declined
    ## (the element was not one it acts on), so the press is left alone.

  ElementHit* = object
    element*: JsObject
    kind*: string
      ## `elementKind` to a pointer row's `when`; empty when nothing under the
      ## press is an element of the pane.
    operation*: string
      ## The operation the element carries, when a view's own hit test
      ## (`registerHitTest`) names it; empty: read off the element's
      ## `data-ct-operation`.
    pressDown*: bool
      ## The element is pressed on the press, not on its click (as an element
      ## marked `data-ct-press="down"` is).

  HitTest* = proc(target, event: JsObject): ElementHit {.closure.}
    ## A view's own hit test (§5.3) for the presses in its pane, for an element
    ## no selector can name — a part of a cell's text, a surface's backdrop.
    ## An empty `kind` leaves the press to the selectors.

  HitRule = tuple[pane, selector, kind: string]
    ## At a node of the walk up from the press, in the pane `pane` ("*": any
    ## pane): an element matching `selector` is an element of kind `kind`. An
    ## empty kind is an element whose press is not the pane's (a drag grip, a
    ## control with a gesture of its own): the walk stops there with no hit.

const
  HitRules*: seq[HitRule] = @[
    # The call trace (K20, K21, K38): the call's text is the row's control,
    # its expander the toggle.
    ("calltrace", ".toggle-call", "toggle"),
    ("calltrace", ".call-text", "row"),
    # A call's argument (K23): its right press opens the argument's menu.
    ("calltrace", ".call-arg", "value"),
    # The event log (K24 - K26): a row, a column header (not its resize
    # grip), and the parts of a row with presses of their own.
    ("eventLog", "[data-ct-column-separator]", ""),
    ("eventLog", ".row-expander", ""),
    ("eventLog", ".marker-boundary-chip", ""),
    ("eventLog", ".eventLog-column-header [data-column]", "header"),
    ("eventLog", "tr[data-position]", "row"),
    # The variables (K27): a compound value's expander.
    ("state", ".value-expand-button", "row"),
    # The rest of a variable's row (K28): a right press opens its menu; a
    # plain press on it is nothing (the expander is the row's toggle).
    ("state", "[data-variable-name]", "value"),
    # Files (K17, K18): a node's anchor.
    ("fileTree", ".filesystem-name-field", ""),
    ("fileTree", ".jstree-anchor", "row"),
    # The rest of a node's row (K19): a right press opens its menu.
    ("fileTree", "li.jstree-node", "value"),
    # Points (K31).
    ("pointList", "[data-point-index]", "row"),
    # Terminal Output (K32): a fragment, and a line past its text.
    ("terminalOutput", "[data-event-index]", "row"),
    ("terminalOutput", ".terminal-line", "row"),
    # The VCS pane (K34, K53): a changed file's diff button, a commit's
    # expander.
    ("vcs", "[data-ct-vcs-file-diff]", "row"),
    ("vcs", "[data-ct-vcs-commit-toggle]", "toggle"),
    # Find in Files (K35).
    ("search", "[data-search-result-index]", "row"),
    # Requests (K58).
    ("requests", "[data-request-index]", "row"),
    # Low Level Code (K61, K63).
    ("lowLevelCode", "[data-ct-low-level-sync]", "toggle"),
    ("lowLevelCode", "[data-low-level-row]", "row"),
    # Verification (K64): a finding, a counterexample offer, a step.
    ("verification", "[data-ct-verification-target]", "row"),
    # Constraints (K67).
    ("constraints", "[data-constraint-index]", "row"),
    # The Visual Replay panes (K72, K73): the Video Player's frame, a Pixel
    # History entry.
    ("videoPlayer", ".video-player-stage", "value"),
    ("pixelHistory", "[data-pixel-history-index]", "row"),
    # An inline value a view marks as one (`data-ct-element-kind`).
    ("*", "[data-ct-element-kind=\"value\"]", "value"),
    # An element that carries its own menu (`setPressMenu`): an inline value
    # in the editor (K36), a toolbar button's history.
    ("*", "[data-ct-press-menu]", "value"),
    # Any other control: a button with a press of its own, or an element
    # carrying its operation. (A link inside a row is the row's:
    # `routePointerPress` leaves a modified press on it to the browser.)
    ("*", "button, [role=\"button\"], [data-ct-operation]", "button"),
  ]

const
  ChromePane* = "layout"
    ## The scope of a press outside every pane — the layout's chrome (a pane's
    ## tab, an auto-hide strip's label: K7, K42) and the toolbar: an element
    ## there is a press's only when it carries a menu (`setPressMenu`).
  ChromeMenuSelector = "[data-ct-press-menu]"
  ChromeTabSelector = ".lm_tab, [data-ct-strip-index]"

var procedures = initTable[string, ElementProc]()
var hitTests = initTable[string, HitTest]()
var everyPaneHitTests: seq[HitTest] = @[]

proc registerHitTest*(pane: string; test: HitTest) =
  ## `pane`'s own hit test, asked before the selectors; the last registration
  ## wins. `"*"`: a hit test asked in every pane (after the pane's own), for a
  ## part every pane of a kind draws (a table cell's `…`); each is kept.
  if pane == "*":
    everyPaneHitTests.add test
  else:
    hitTests[pane] = test

var paneMenus = initTable[string, ElementProc]()

proc registerPaneMenu*(pane: string; open: ElementProc) =
  ## The menu a right click opens on an element of `pane` when the pointer
  ## keymap resolves it to `context-menu.open` and no element of that pane
  ## opens a menu of its own: the front-end's procedure, run by its fallback
  ## (the desktop's session-tab strip, `ui/session_tabs`). The last
  ## registration wins.
  paneMenus[pane] = open

proc openPaneMenu*(press: ElementPress): bool =
  ## Opens the menu registered for `press.pane`; false when there is none or
  ## it declined.
  if not paneMenus.hasKey(press.pane):
    return false
  paneMenus[press.pane](press)

proc elementOperationProcedure*(operation: string): ElementProc =
  ## The procedure registered for `operation`; nil when none is.
  procedures.getOrDefault(operation)

proc registerElementOperation*(operation: string; run: ElementProc) =
  ## The desktop's procedure for `operation` on a pressed element. The last
  ## registration wins (a renderer re-imported by a hot reload).
  procedures[operation] = run

proc registerPaneOperation*(operation, pane: string; run: ElementProc) =
  ## The procedure for `operation` on an element of the pane `pane` only: an
  ## operation every pane names alike but each performs on its own elements
  ## (`context-menu.open` opens that pane's menu for the element pressed).
  procedures[operation & "@" & pane] = run

proc hasElementOperation*(operation: string; pane = ""): bool =
  procedures.hasKey(operation & "@" & pane) or procedures.hasKey(operation)

proc runElementOperation*(operation: string; press: ElementPress): bool =
  ## Performs `operation` on the element pressed — its pane's procedure when
  ## the pane has one, else the operation's; false when there is none or the
  ## procedure declined.
  let scoped = operation & "@" & press.pane
  if procedures.hasKey(scoped):
    return procedures[scoped](press)
  if not procedures.hasKey(operation):
    return false
  procedures[operation](press)

proc matchesJs(node: JsObject; selector: cstring): bool {.importjs:
  "((n, s) => !!n.matches && n.matches(s))(#, #)".}

proc isPaneRoot(node: JsObject): bool {.importjs:
  "((n) => !!n.getAttribute && (n.getAttribute('data-scope-kind') === 'pane' || n.hasAttribute('data-ct-pane')))(#)".}

proc domElementAt*(target: JsObject; pane: string): ElementHit =
  ## The element of `pane` under a press on `target`: walking up from the
  ## target to the pane's root, the first node a rule names, the rules taken
  ## in order at each node — so a control inside a row is the control.
  var node = target
  while not node.isNil and not node.isUndefined:
    if isPaneRoot(node):
      return
    if not node[cstring"matches"].isUndefined:
      for rule in HitRules:
        if (rule.pane == "*" or rule.pane == pane) and
           matchesJs(node, cstring(rule.selector)):
          if rule.kind.len == 0:
            return
          return ElementHit(element: node, kind: rule.kind)
    node = node[cstring"parentNode"]

proc attributeOf*(element: JsObject; name: string): string =
  ## A `data-*` (or any) attribute of `element`, empty when it has none.
  if element.isNil or element.isUndefined:
    return ""
  let v = element.getAttribute(cstring(name))
  if v.isNil or v.isUndefined: "" else: $v.to(cstring)

proc intAttributeOf*(element: JsObject; name: string; default = -1): int =
  ## An integer attribute of `element`, `default` when it is absent or not
  ## a number.
  let text = attributeOf(element, name)
  if text.len == 0:
    return default
  var sign = 1
  var i = 0
  if text[0] == '-':
    sign = -1
    i = 1
  if i >= text.len:
    return default
  var n = 0
  while i < text.len:
    if text[i] notin {'0' .. '9'}:
      return default
    n = n * 10 + (ord(text[i]) - ord('0'))
    inc i
  sign * n

# ---------------------------------------------------------------------------
# An element's own menu
# ---------------------------------------------------------------------------

type
  PressMenu* = proc(event: JsObject): bool {.closure.}
    ## Opens the menu at the press `event` (its coordinates, its target, its
    ## modifiers); false when it opened none (Shift held over the editor area
    ## leaves the browser its own menu), so the press is left alone.

proc setPressMenu*(element: JsObject; menu: PressMenu) {.importjs:
  "((e, m) => { e.__ctPressMenu = m; e.setAttribute('data-ct-press-menu', ''); })(#, #)".}
  ## What a right press on `element` opens, for an element whose menu its host
  ## builds from state the element alone does not carry (a pane's tab, an
  ## auto-hide strip's label, an inline value, a toolbar button): the host
  ## hands the menu here instead of listening for the press itself, and the
  ## press is the pointer row `context-menu.open` like any other
  ## (`openPressMenu`).

proc pressMenuOf(element: JsObject): JsObject {.importjs: """
  ((e) => { const c = e && e.closest ? e.closest('[data-ct-press-menu]') : null;
            return c && c.__ctPressMenu ? c.__ctPressMenu : null; })(#)""".}
proc callPressMenu(menu: JsObject; event: JsObject): bool {.importjs: "!!(#(#))".}

proc openPressMenu(p: ElementPress): bool =
  ## `context-menu.open` on an element that carries its menu (`setPressMenu`),
  ## at the press, else the menu registered for its pane (`registerPaneMenu`:
  ## the session tabs' strip); a pane whose elements each open their own
  ## menu registers its procedure with `registerPaneOperation`, which comes
  ## first.
  let menu = pressMenuOf(p.element)
  if menu.isNil:
    return openPaneMenu(p)
  callPressMenu(menu, p.event)

registerElementOperation("context-menu.open", openPressMenu)

# ---------------------------------------------------------------------------
# The one listener
# ---------------------------------------------------------------------------

type
  PointerResolver* = PressResolver
    ## The host's router over the pointer keymap: the user's rows, then the
    ## base's (`KeymapRouter.routePointer`).
  PointerFallback* = proc(res: EditingResolution; press: ElementPress): bool
    ## An operation no element procedure performs (a user's row binding a
    ## press to Continue): the host's own dispatch, true when it ran it.
  PointerTrace* = proc(operation: string)
    ## Told every operation a press runs (the desktop's `__ctKeyTrace`).

type
  PendingPress = object
    event: JsObject
    operation: string
    press: ElementPress

var
  pending: PendingPress
  resolver: PointerResolver
  fallback: PointerFallback
  tracer: PointerTrace
  installed = false

proc scopeChainOf*(start: JsObject): ScopePath =
  ## The scope elements from the document down to `start`, read off the
  ## `data-scope-kind` / `data-scope-id` each scope element carries.
  var node = start
  var reversed: seq[ScopeElement] = @[]
  while not node.isNil and not node.isUndefined:
    let getAttr = node[cstring"getAttribute"]
    if not getAttr.isNil and not getAttr.isUndefined:
      let kind = node.getAttribute(cstring"data-scope-kind")
      if not kind.isNil and not kind.isUndefined:
        let id = node.getAttribute(cstring"data-scope-id")
        reversed.add elementOfAttributes($kind.to(cstring),
          (if id.isNil or id.isUndefined: "" else: $id.to(cstring)))
    node = node[cstring"parentNode"]
  for i in countdown(reversed.high, 0):
    result.add reversed[i]

proc closestOrNull(target: JsObject; selector: cstring): JsObject {.importjs:
  "((t, s) => (t && t.closest && t.closest(s)) || null)(#, #)".}

proc linkUnder(target: JsObject): JsObject =
  ## The link the press is on, if any: a real one, not an `href="#"` anchor
  ## standing in for a button (the Files tree's).
  closestOrNull(target, cstring"a[href]:not([href='#'])")

proc modifiersOf(ev: JsObject): KeyModifiers =
  if ev.ctrlKey.to(bool): result.incl kmodCtrl
  if ev.shiftKey.to(bool): result.incl kmodShift
  if ev.altKey.to(bool): result.incl kmodAlt
  if ev.metaKey.to(bool): result.incl kmodMeta

proc stop(ev: JsObject) =
  discard ev.preventDefault()
  discard ev.stopImmediatePropagation()

const
  PressDownAttribute* = "data-ct-press"
    ## `down` on an element pressed on the press itself, not on its click:
    ## one on a surface that swallows the click (Monaco's view zones and
    ## content widgets, which re-render under a press) and that the press must
    ## not reach (it would move Monaco's caret).

proc performPendingPress(ev: JsObject)

proc listenOnce(element: JsObject; kind: cstring; handler: proc(ev: JsObject)) {.
  importjs: "#.addEventListener(#, #, {once: true})".}

proc performAtElement(element: JsObject; ev: JsObject) =
  ## The pressed element's own bubble listener for this one press, after the
  ## handlers it already carries. (Left behind when a descendant stopped the
  ## press, it runs once on the element's next press, which is not the
  ## pending one, and does nothing.)
  listenOnce(element, ev["type"].to(cstring), performPendingPress)

proc routePointerPress(ev: JsObject; gestureKey: string; onDown = false) =
  ## **A PRESS ON A PANE'S ELEMENT, THROUGH THE ROUTER** (Input-Routing §5.1):
  ## the element under the press and its kind (`domElementAt`), its pane from
  ## the scope the DOM carries, the gesture with its modifiers — resolved by
  ## the host's router (a user's `keybindings.json` row, then the base's
  ## `pointer_rows`) and performed by the procedure for that operation on that
  ## element. A modified press with no row of its own is the plain gesture: a
  ## Ctrl+click on a row is still a click on it.
  ##
  ## A link inside a row (a host that addresses rows, Shared-DOM-Front-Ends
  ## D10) is the row's for a plain click — the navigation is cancelled, the
  ## session is already open — and the browser's for any other press.
  if resolver.isNil:
    return
  var path = scopeChainOf(ev.target)
  var hit: ElementHit
  if path.innermostPane < 0:
    # A pane shown outside the layout (the auto-hide overlay's) names its
    # kind for presses only (`data-ct-pane`): it is not a key scope.
    let host = closestOrNull(ev.target, cstring"[data-ct-pane]")
    let menuEl = if gestureKey == "RightClick":
                   closestOrNull(ev.target, cstring(ChromeMenuSelector))
                 else: nil
    if not host.isNil:
      path.add pane(attributeOf(host, "data-ct-pane"))
    elif not menuEl.isNil:
      # A right press outside every pane (K7, K42, the toolbar) on an element
      # that carries a menu: in the scope `ChromePane`, a `tab` for a pane's
      # tab or a strip's label, a `value` otherwise.
      path.add pane(ChromePane)
      hit = ElementHit(element: menuEl,
        kind: if matchesJs(menuEl, cstring(ChromeTabSelector)): "tab" else: "value")
    elif not closestOrNull(ev.target, cstring"[data-ct-operation]").isNil:
      # An element carrying its operation outside every pane (a popup on
      # the document's body): its press is routed with no pane.
      path.add pane("none")
    else:
      return
  let paneKind = path[path.innermostPane].paneKind
  if hit.kind.len == 0 and hitTests.hasKey(paneKind):
    hit = hitTests[paneKind](ev.target, ev)
  for test in everyPaneHitTests:
    if hit.kind.len > 0: break
    hit = test(ev.target, ev)
  if hit.kind.len == 0:
    hit = domElementAt(ev.target, paneKind)
  if hit.kind.len == 0:
    return
  let pressedOnDown = hit.pressDown or not closestOrNull(ev.target,
    cstring("[" & PressDownAttribute & "=\"down\"]")).isNil
  if onDown != pressedOnDown and gestureKey in ["Click", "DoubleClick"]:
    # An element pressed on the press is routed then, and not again by its
    # click; every other element by its click only. That is the primary
    # button's: a right press on such an element (an inline value's menu)
    # is its `contextmenu`, as on any other.
    return
  let mods = modifiersOf(ev)
  if not linkUnder(ev.target).isNil and (mods != {} or gestureKey != "Click"):
    return
  # The row for the press, else — a button's primary press with no row of
  # its own — the operation the button carries (`data-ct-operation`,
  # `element_press`): §5.1's `pressElement`, as the terminal and the GPUI
  # window decide it.
  let carried = if hit.operation.len > 0: hit.operation
                else: attributeOf(hit.element, OperationAttribute)
  let outcome = resolveElementPress(resolver, path, hit.kind, carried,
                                    mods, gestureKey)
  if outcome.operation.len == 0:
    return
  let res = outcome.resolution
  let press = ElementPress(element: hit.element, event: ev, pane: paneKind)
  if hasElementOperation(outcome.operation, paneKind):
    if onDown:
      # Performed now, and the press goes no further: its click may never
      # come, and what lies under the element (Monaco) must not take the
      # press. Its default stays: the press still moves the focus.
      if not tracer.isNil: tracer(outcome.operation)
      if runElementOperation(outcome.operation, press):
        discard ev.stopImmediatePropagation()
    elif (outcome.byRow and res.layer.startsWith("user:")) or
         outcome.operation == "context-menu.open":
      # A user's row takes the press here, in the capture phase: nothing
      # else may answer it. So does an element's menu, as the views' own
      # menus did: nothing observes a right press, and an editor underneath
      # (Monaco's own menu) must not answer it too.
      if not tracer.isNil: tracer(outcome.operation)
      if runElementOperation(outcome.operation, press):
        stop(ev)
    else:
      # The base's row, or the operation a button carries, is performed when
      # the press bubbles back to the element pressed (`performPendingPress`),
      # where the view's own handler used to run: what observes the press on
      # its way down (a pane's gesture tracking, as the Requests pane's detail
      # split does in the capture phase) sees it first, and a descendant that
      # answers it itself stops it there. Performed there, before the
      # handlers of the elements around it, a procedure whose element sits
      # inside another with a press of its own (a VCS file's View Diff button
      # inside the file's row) can keep the press from it, as the view's
      # handler did. The window's bubble listener performs it when the
      # element's listener did not run. No link is followed.
      if not linkUnder(ev.target).isNil:
        discard ev.preventDefault()
      pending = PendingPress(event: ev, operation: outcome.operation, press: press)
      performAtElement(hit.element, ev)
  elif outcome.byRow and not fallback.isNil and fallback(res, press):
    stop(ev)

proc performPendingPress(ev: JsObject) =
  ## The bubble half of `routePointerPress`: the base row's procedure for the
  ## press that resolved in the capture phase, if it is this one.
  if pending.event.isNil or pending.event != ev:
    return
  let p = pending
  pending = PendingPress()
  if not tracer.isNil: tracer(p.operation)
  if runElementOperation(p.operation, p.press):
    discard ev.preventDefault()

proc routeWindowGesture(ev: JsObject; gestureKey: string) =
  ## A gesture that is the WINDOW's, wherever it lands — the mouse's side
  ## buttons (`BackClick`, `ForwardClick`): resolved in the scope the press
  ## is in, with no element, and performed by the procedure registered for
  ## the operation (a user's row naming another operation: the host's
  ## dispatch).
  if resolver.isNil:
    return
  let path = scopeChainOf(ev.target)
  let mods = modifiersOf(ev)
  var res = resolver(path, chordName(mods, gestureKey))
  if res.kind != erOperation and mods != {}:
    res = resolver(path, gestureKey)
  if res.kind != erOperation:
    return
  let press = ElementPress(element: ev.target, event: ev, pane: "")
  if hasElementOperation(res.operation):
    if not tracer.isNil: tracer(res.operation)
    if runElementOperation(res.operation, press):
      stop(ev)
  elif not fallback.isNil and fallback(res, press):
    stop(ev)

proc onPointerDown(ev: JsObject) =
  # `MouseEvent.button` 3 and 4: the platform's Back and Forward
  # (https://w3c.github.io/uievents/#dom-mouseevent-button). Taken on the
  # press, as the buttons always were here; a browser may not deliver their
  # `auxclick`. A primary press on an element pressed on the press
  # (`PressDownAttribute`) is its click.
  case ev.button.to(int)
  of 0: routePointerPress(ev, "Click", onDown = true)
  of 3: routeWindowGesture(ev, "BackClick")
  of 4: routeWindowGesture(ev, "ForwardClick")
  else: discard

proc onPointerClick(ev: JsObject) =
  if ev.button.to(int) == 0: routePointerPress(ev, "Click")

proc onPointerDoubleClick(ev: JsObject) =
  if ev.button.to(int) == 0: routePointerPress(ev, "DoubleClick")

proc onPointerContextMenu(ev: JsObject) =
  routePointerPress(ev, "RightClick")

proc onPointerAuxClick(ev: JsObject) =
  if ev.button.to(int) == 1: routePointerPress(ev, "MiddleClick")

proc domPointerRoutingInstalled*(): bool =
  ## Whether this window's pointer listener is installed (a host that mounts
  ## a surface into a page another host may already route, as StoryBook's
  ## story chrome, installs the base rows only when nothing did).
  installed

proc installDomPointerRouting*(resolve: PointerResolver;
                               onUnperformed: PointerFallback = nil;
                               trace: PointerTrace = nil) =
  ## Route every press on a pane's element through `resolve`. The listener is
  ## installed once per window; a later call replaces the resolver (a host
  ## whose router is rebuilt).
  resolver = resolve
  fallback = onUnperformed
  tracer = trace
  if installed:
    return
  installed = true
  {.emit: ["window.addEventListener('click', ", onPointerClick, ", true);",
           "window.addEventListener('dblclick', ", onPointerDoubleClick, ", true);",
           "window.addEventListener('contextmenu', ", onPointerContextMenu, ", true);",
           "window.addEventListener('auxclick', ", onPointerAuxClick, ", true);",
           "window.addEventListener('mousedown', ", onPointerDown, ", true);",
           "window.addEventListener('click', ", performPendingPress, ", false);",
           "window.addEventListener('dblclick', ", performPendingPress, ", false);",
           "window.addEventListener('contextmenu', ", performPendingPress, ", false);",
           "window.addEventListener('auxclick', ", performPendingPress, ", false);"].}
