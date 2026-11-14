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
## press takes it over exactly as it takes a row's press.
##
## Refuses to own: hit-testing (a front-end's own geometry, §5.3), the
## resolver (the host's `KeymapRouter`), and what an operation does (the
## host's procedure for it).
##
## Pure; compiles on C and JS.

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
  var p = path
  p.add elementOfAttributes(elementKind, "")
  var res = resolve(p, chordName(mods, gestureKey))
  if res.kind != erOperation and mods != {}:
    res = resolve(p, gestureKey)
  if res.kind == erOperation:
    return PressOutcome(operation: res.operation, byRow: true, resolution: res)
  if carried.len > 0 and carriedOperationRuns(elementKind, gestureKey):
    return PressOutcome(operation: carried, byRow: false, resolution: res)
  PressOutcome(resolution: res)

proc routerResolver*(router: KeymapRouter; facts: SessionFacts): PressResolver =
  ## `router`'s pointer rows under `facts`, as a `PressResolver`. The router
  ## is captured as it is now: a host whose user keymap changes builds the
  ## resolver again.
  let r = router
  result = proc(path: ScopePath; gesture: string): EditingResolution =
    r.routePointer(facts, path, nmNormal, gesture)
