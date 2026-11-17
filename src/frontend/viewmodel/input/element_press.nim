## element_press.nim — WHAT ONE PRESS ON AN ELEMENT RUNS: the pointer keymap's
## row for it, or the operation a button carries.
##
## Input-Routing-And-Keymaps.md §5.1, "A button carries its operation; a row's
## press is the pointer keymap's": the hit test names the element and, for a
## button, the operation it carries; the pointer keymap is asked first (a
## user's row for the gesture, then the base's), a modified press with no row
## of its own is the plain gesture, and a plain primary press on a button with
## no row runs the button's operation by name. The terminal and the GPUI
## debugger window spell that in their `pressElement`; this module is the same
## decision for every host that resolves a press through a resolver it is
## handed — the DOM front-ends' one pointer listener (`dom_pointer`), the
## story hosts' playback chrome, and a suite that renders a view under
## `MockRenderer` and presses it as a DOM front-end would.
##
## A button's operation is DATA on the element: `data-ct-operation` in the
## DOM (`OperationAttribute`), the same attribute on a GPUI element. A view
## draws it and holds no handler, so a user's `keybindings.json` row for the
## press takes it over exactly as it takes a row's press. An element whose
## reference is for another gesture names it (`DoubleClick:<operation>`,
## `carriedReference`): its primary press then carries nothing.
##
## Refuses to own: hit-testing (a front-end's own geometry, §5.3), the
## resolver (the host's `KeymapRouter`), and what an operation does (the
## host's procedure for it).
##
## Pure; compiles on C and JS.

import std/strutils

import ../keymap/[context_keys, editing_keymap, keymap_router, scope_path]
import ../../../common/key_names

const
  OperationAttribute* = "data-ct-operation"
    ## The operation a button carries, as its view draws it.
  ButtonElementKind* = "button"
    ## `elementKind` of a control with a press of its own (`dom_pointer`'s
    ## `HitRules`' last rule).
  ElementKindAttribute* = "data-ct-element-kind"
    ## An element's kind, drawn by a view whose element is not a button (an
    ## inline value is `value`), for the pointer rows' `elementKind`.

type
  PressResolver* = proc(path: ScopePath; gesture: string): EditingResolution
    ## The host's router over the pointer keymap (`KeymapRouter.routePointer`
    ## with the host's facts): the user's rows, then the base's.

  PressOutcome* = object
    ## What a press runs: `operation` is empty when it runs nothing.
    operation*: string
    byRow*: bool
      ## A pointer row named it (`resolution` is that row's); false when it
      ## is the operation the button carries.
    resolution*: EditingResolution

const
  CarriedGestureSeparator* = ':'
    ## Between the gesture and the operation of a reference an element
    ## carries for a gesture other than its primary press
    ## (`DoubleClick:diff.show-unchanged-region`). No operation name holds
    ## one: a catalogued name is `namespace.verb` with an optional
    ## parenthesised argument, and a table's `pane:` prefix is not an
    ## operation's.

func carriedReference*(gestureKey, operation: string): string =
  ## What an element carrying `operation` for `gestureKey` draws in its
  ## `data-ct-operation`: the bare operation for its primary press
  ## (`Click`), else the gesture and the operation (§5.1: "Double click,
  ## context click and middle click are separate gestures with their own
  ## references").
  if gestureKey == "Click": operation
  else: gestureKey & CarriedGestureSeparator & operation

func splitCarried*(carried: string): tuple[gesture, operation: string] =
  ## A carried reference's gesture and operation: `Click` for a bare one.
  let at = carried.find(CarriedGestureSeparator)
  if at < 0: ("Click", carried)
  else: (carried[0 ..< at], carried[at + 1 .. ^1])

func carriedOperationRuns*(elementKind, gestureKey: string): bool =
  ## Whether a press with no row of its own runs the operation the element
  ## carries: the primary press of an element (a button, an inline value).
  ## `gestureKey` is the gesture without its modifiers (`Click`, not
  ## `Ctrl+Click`). A double click is not another press of the element: the
  ## DOM delivers each of its presses as a `click` already, and a second run
  ## would be a run the user did not ask for.
  elementKind.len > 0 and elementKind != "none" and gestureKey == "Click"

proc resolveElementPress*(resolve: PressResolver; path: ScopePath;
                          elementKind, carried: string; mods: KeyModifiers;
                          gestureKey: string): PressOutcome =
  ## **ONE PRESS ON THE ELEMENT `path` ENDS IN** (§5.1). `path` is the scope
  ## chain down to the element's pane, the element itself appended here from
  ## its kind; `carried` is the operation the element carries (empty for one
  ## that carries none). The row for the gesture with its modifiers, then for
  ## the plain gesture; else, for a button's primary press, `carried`.
  ##
  ## `carried` may name the gesture it is the reference of
  ## (`carriedReference`): `DoubleClick:<operation>` runs on the element's
  ## double click and on no other gesture, so its single presses run
  ## nothing of their own (the unified diff's "N hidden lines" label, which
  ## unfolds on a double click as Monaco's does).
  var p = path
  p.add elementOfAttributes(elementKind, "")
  var res = resolve(p, chordName(mods, gestureKey))
  if res.kind != erOperation and mods != {}:
    res = resolve(p, gestureKey)
  if res.kind == erOperation:
    return PressOutcome(operation: res.operation, byRow: true, resolution: res)
  let (gesture, operation) = splitCarried(carried)
  if operation.len > 0 and gesture == gestureKey and
     (if gesture == "Click": carriedOperationRuns(elementKind, gestureKey)
      else: elementKind.len > 0 and elementKind != "none"):
    return PressOutcome(operation: operation, byRow: false, resolution: res)
  PressOutcome(resolution: res)

proc routerResolver*(router: KeymapRouter; facts: SessionFacts): PressResolver =
  ## `router`'s pointer rows under `facts`, as a `PressResolver`. The router
  ## is captured as it is now: a host whose user keymap changes builds the
  ## resolver again.
  let r = router
  result = proc(path: ScopePath; gesture: string): EditingResolution =
    r.routePointer(facts, path, nmNormal, gesture)
