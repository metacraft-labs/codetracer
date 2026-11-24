## element_operations.nim — AN ELEMENT THAT CARRIES ITS OPERATION, AND THE
## PROCEDURE THAT PERFORMS IT ON THAT ELEMENT.
##
## Input-Routing-And-Keymaps.md §5.1: a press on an element is the pointer
## keymap's to decide (a user's row first, then the base's), and with no row
## of its own a primary press runs the operation the element carries. On the
## DOM front-ends the window's one pointer listener (`dom_pointer`) resolves
## the press and runs "the procedure registered for that operation on that
## element". Most of the session's panes register a procedure per operation
## that reads the element's identity off its `data-*` attributes
## (`pane_presses`). A component that holds its state in the closures it draws
## with (a legacy Karax component, a chip whose value is in hand) binds the
## procedure to the element instead:
##
##   bindElementOperation(el, "trace-chart.show-table", proc(p: PressInfo) = …)
##
## draws `data-ct-operation` (when the element carries the operation — its
## plain press) and keeps the procedure ON the element; the one procedure
## registered for the operation runs the pressed element's. A view holds no
## press handler: the procedure runs only when the router resolved a press to
## that operation on that element, so a user's row for the press takes it over
## and a `-` row's absence of any changes nothing.
##
## An element may also be bound to an operation it does not carry — one a
## pointer row runs on it (`Ctrl+Click` on an inline value is
## `scratchpad.add-value`, K36) — so the row's operation is performed on the
## element it was pressed on.
##
## Refuses to own: which operation a press runs (the router over the pointer
## keymap), the hit test (`dom_pointer`'s selectors), and what the procedure
## does (its component's).
##
## Compiles on C and JS. On C (a `MockRenderer` suite) the binding is kept in
## a table keyed by the node, and a suite presses through `resolveElementPress`
## and `runBoundOperation`, as the page's listener does.

import std/tables

import isonim/testing/mock_dom

import ./element_press

export element_press

type
  PressInfo* = object
    ## The press a bound procedure performs on, as the DOM reported it.
    ctrl*, shift*, alt*, meta*: bool
    button*: int
    x*, y*: int

  ElementRun* = proc(press: PressInfo) {.closure.}

when defined(js):
  import std/jsffi
  import ./dom_pointer

  var procedureFor = initTable[string, bool]()

  proc jsSetAttribute(el: JsObject; name, value: cstring) {.importjs:
    "#.setAttribute(#, #)".}

  proc pressInfoOf*(ev: JsObject): PressInfo =
    ## The press `ev` reports (a `MouseEvent`); the zero press for none.
    if ev.isNil or ev.isUndefined:
      return
    template flag(name: string): bool =
      (let v = ev[cstring(name)]; not v.isUndefined and v.to(bool))
    template number(name: string): int =
      (let v = ev[cstring(name)]; if v.isUndefined: 0 else: v.to(int))
    PressInfo(ctrl: flag("ctrlKey"), shift: flag("shiftKey"),
              alt: flag("altKey"), meta: flag("metaKey"),
              button: number("button"), x: number("clientX"),
              y: number("clientY"))

  proc runsOf(element: JsObject; create: bool): JsObject =
    if element.isNil or element.isUndefined:
      return nil
    var runs = element[cstring"__ctElementOperations"]
    if runs.isUndefined or runs.isNil:
      if not create:
        return nil
      runs = newJsObject()
      element[cstring"__ctElementOperations"] = runs
    runs

  proc runBoundOperation*(element: JsObject; operation: string;
                          press: PressInfo): bool =
    ## Runs the procedure bound to `element` for `operation`; false when it
    ## has none.
    let runs = runsOf(element, false)
    if runs.isNil:
      return false
    let run = runs[cstring(operation)]
    if run.isUndefined or run.isNil:
      return false
    run.to(ElementRun)(press)
    true

  proc ensureProcedure(operation: string) =
    ## The one procedure for `operation`: the pressed element's bound one,
    ## else the procedure registered before it (the session panes' own,
    ## `pane_presses`), so binding an element never takes an operation from
    ## the elements that do not carry a binding.
    if procedureFor.hasKey(operation):
      return
    procedureFor[operation] = true
    let previous = elementOperationProcedure(operation)
    registerElementOperation(operation, proc(p: ElementPress): bool =
      if runBoundOperation(p.element, operation, pressInfoOf(p.event)):
        true
      elif not previous.isNil:
        previous(p)
      else:
        false)

  proc bindElementOperation*(element: JsObject; operation: string;
                             run: ElementRun; carried = true; onDown = false;
                             gesture = "Click") =
    ## `element` carries `operation` (when `carried`: its plain press runs
    ## it) and `run` is the procedure that performs `operation` on it.
    ## `onDown`: the element is pressed on the press, not on its click
    ## (`dom_pointer.PressDownAttribute`: an element inside Monaco).
    ## `gesture`: the gesture the carried reference is for, when it is not
    ## the primary press (`DoubleClick`: the element's double click runs
    ## `operation` and its single press runs nothing, `carriedReference`).
    if element.isNil or element.isUndefined:
      return
    if carried:
      jsSetAttribute(element, cstring(OperationAttribute),
                     cstring(carriedReference(gesture, operation)))
    if onDown:
      jsSetAttribute(element, cstring(PressDownAttribute), cstring"down")
    runsOf(element, true)[cstring(operation)] = toJs(run)
    ensureProcedure(operation)

  proc bindPressOperation*(element: JsObject; operation: string;
                           run: ElementRun) =
    ## `bindElementOperation` for an element pressed on the press
    ## (`onDown`): one whose press was its `mousedown` because it lies in a
    ## surface that swallows the click (Monaco's view zones and widgets).
    bindElementOperation(element, operation, run, carried = true, onDown = true)

  # A `MockRenderer` suite compiled with `nim js` draws `MockNode`s, not DOM
  # elements: their bindings are kept here, by node identity, and read by the
  # `MockNode` overload of `runBoundOperation` (a `MockNode` has no
  # `setAttribute` to carry them on).
  var mockNodes: seq[MockNode]
  var mockRuns: seq[Table[string, ElementRun]]

  proc mockBind(node: MockNode; operation: string; run: ElementRun) =
    for i, n in mockNodes:
      if n == node:
        mockRuns[i][operation] = run
        return
    mockNodes.add node
    mockRuns.add {operation: run}.toTable

  proc runBoundOperation*(node: MockNode; operation: string;
                          press: PressInfo): bool =
    ## Runs the procedure bound to the mock `node` for `operation`; false
    ## when it has none.
    for i, n in mockNodes:
      if n == node and mockRuns[i].hasKey(operation):
        mockRuns[i][operation](press)
        return true
    false

else:
  var nativeRuns = initTable[pointer, Table[string, ElementRun]]()
    ## A `MockRenderer` suite's bindings, keyed by the node.

  proc runBoundOperation*[N](node: N; operation: string;
                             press: PressInfo): bool =
    ## Runs the procedure bound to `node` for `operation`; false when it has
    ## none.
    let key = cast[pointer](node)
    if not nativeRuns.hasKey(key) or not nativeRuns[key].hasKey(operation):
      return false
    nativeRuns[key][operation](press)
    true

const PressDownValue* = "down"
  ## `data-ct-press="down"` (`dom_pointer.PressDownAttribute`).

proc setNodeAttribute[R, N](r: R; node: N; name, value: string) =
  ## On the DOM the element's own `setAttribute` (whichever renderer drew
  ## it); under `MockRenderer` the node's attribute table.
  when N is MockNode:
    node.attributes[name] = value
  elif defined(js):
    jsSetAttribute(cast[JsObject](node), cstring(name), cstring(value))
  else:
    mixin setAttribute
    r.setAttribute(node, name, value)

proc bindOperation*[R, N](r: R; node: N; operation: string; run: ElementRun;
                          carried = true; onDown = false) =
  ## A renderer-generic view's `bindElementOperation`: on the DOM (the
  ## `WebRenderer`'s element) exactly that; under `MockRenderer` the
  ## attributes and a binding `runBoundOperation` reads.
  if carried:
    setNodeAttribute(r, node, OperationAttribute, operation)
  if onDown:
    setNodeAttribute(r, node, "data-ct-press", PressDownValue)
  when defined(js) and N is MockNode:
    mockBind(node, operation, run)
  elif defined(js):
    bindElementOperation(cast[JsObject](node), operation, run, carried = false)
  else:
    nativeRuns.mgetOrPut(cast[pointer](node),
                         initTable[string, ElementRun]())[operation] = run

proc bindElementKind*[R, N](r: R; node: N; kind: string) =
  ## `node` is an element of `kind` to the pointer rows (`value`), not a
  ## button.
  setNodeAttribute(r, node, ElementKindAttribute, kind)
