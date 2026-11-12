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
##     `dblclick`, `contextmenu` and `auxclick` (resolved in the capture phase,
##     a base row performed when the press bubbles back to the window): the press's scope
##     from the DOM (`data-scope-kind` / `data-scope-id`), the element and its
##     kind, the gesture with its modifiers, resolved by the host's router and
##     performed here.
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
    # The event log (K24 - K26): a row, a column header (not its resize
    # grip), and the parts of a row with presses of their own.
    ("eventLog", "[data-ct-column-separator]", ""),
    ("eventLog", ".row-expander", ""),
    ("eventLog", ".marker-boundary-chip", ""),
    ("eventLog", ".eventLog-column-header [data-column]", "header"),
    ("eventLog", "tr[data-position]", "row"),
    # The variables (K27): a compound value's expander.
    ("state", ".value-expand-button", "row"),
    # Files (K17, K18): a node's anchor.
    ("fileTree", ".jstree-anchor", "row"),
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
    # Any other control: a button with a press of its own. (A link inside a
    # row is the row's: `routePointerPress` leaves a modified press on it to
    # the browser.)
    ("*", "button, [role=\"button\"]", "button"),
  ]

var procedures = initTable[string, ElementProc]()

proc registerElementOperation*(operation: string; run: ElementProc) =
  ## The desktop's procedure for `operation` on a pressed element. The last
  ## registration wins (a renderer re-imported by a hot reload).
  procedures[operation] = run

proc hasElementOperation*(operation: string): bool =
  procedures.hasKey(operation)

proc runElementOperation*(operation: string; press: ElementPress): bool =
  ## Performs `operation` on the element pressed; false when the desktop has
  ## no procedure for it or the procedure declined.
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
# The one listener
# ---------------------------------------------------------------------------

type
  PointerResolver* = proc(path: ScopePath; gesture: string): EditingResolution
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

proc routePointerPress(ev: JsObject; gestureKey: string) =
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
  if path.innermostPane < 0:
    # A pane shown outside the layout (the auto-hide overlay's) names its
    # kind for presses only (`data-ct-pane`): it is not a key scope.
    let host = closestOrNull(ev.target, cstring"[data-ct-pane]")
    if host.isNil:
      return
    path.add pane(attributeOf(host, "data-ct-pane"))
  let paneKind = path[path.innermostPane].paneKind
  let hit = domElementAt(ev.target, paneKind)
  if hit.kind.len == 0:
    return
  let mods = modifiersOf(ev)
  if not linkUnder(ev.target).isNil and (mods != {} or gestureKey != "Click"):
    return
  path.add elementOfAttributes(hit.kind, "")
  var res = resolver(path, chordName(mods, gestureKey))
  if res.kind != erOperation and mods != {}:
    res = resolver(path, gestureKey)
  if res.kind != erOperation:
    return
  let press = ElementPress(element: hit.element, event: ev, pane: paneKind)
  if hasElementOperation(res.operation):
    if res.layer.startsWith("user:"):
      # A user's row takes the press here, in the capture phase: nothing
      # else may answer it.
      if not tracer.isNil: tracer(res.operation)
      if runElementOperation(res.operation, press):
        stop(ev)
    else:
      # The base's row is performed when the press has reached the window
      # again (`performPendingPress`), where the view's own handler used to
      # run: what observes the press on its way (a pane's gesture tracking,
      # as the Requests pane's detail split does) sees it first, and an
      # element that answers it itself stops it there. No link is followed.
      discard ev.preventDefault()
      pending = PendingPress(event: ev, operation: res.operation, press: press)
  elif not fallback.isNil and fallback(res, press):
    stop(ev)

proc performPendingPress(ev: JsObject) =
  ## The bubble half of `routePointerPress`: the base row's procedure for the
  ## press that resolved in the capture phase, if it is this one.
  if pending.event.isNil or pending.event != ev:
    return
  let p = pending
  pending = PendingPress()
  if not tracer.isNil: tracer(p.operation)
  discard runElementOperation(p.operation, p.press)

proc onPointerClick(ev: JsObject) =
  if ev.button.to(int) == 0: routePointerPress(ev, "Click")

proc onPointerDoubleClick(ev: JsObject) =
  if ev.button.to(int) == 0: routePointerPress(ev, "DoubleClick")

proc onPointerContextMenu(ev: JsObject) =
  routePointerPress(ev, "RightClick")

proc onPointerAuxClick(ev: JsObject) =
  if ev.button.to(int) == 1: routePointerPress(ev, "MiddleClick")

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
           "window.addEventListener('click', ", performPendingPress, ", false);",
           "window.addEventListener('dblclick', ", performPendingPress, ", false);",
           "window.addEventListener('contextmenu', ", performPendingPress, ", false);",
           "window.addEventListener('auxclick', ", performPendingPress, ", false);"].}
