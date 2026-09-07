## headless_app/window_set.nim — the set of top-level windows a shell shows,
## sitting ABOVE `layout_model.Layout` (Layout-ViewModel §3A.1).
##
## ## Why this exists at all
##
## `Layout` describes ONE window, and a model that stops there silently
## assumes there is one. The desktop does not: `ui/panel_transfer.nim` moves a
## pane between application windows over Electron IPC — it serialises the
## panel's config, removes it from the source window, and recreates it in the
## target — and that capability has had no description in this model. A model
## that cannot describe something a shipped front-end already does is a model
## the front-end will keep working around.
##
## ## The one design claim, and what follows from it
##
## **Moving a tab between windows is a `WindowSet` operation composed of two
## `Layout` ones, not a `Layout` operation with a window argument.** It is
## `lcRemovePane` in the source layout and `lcAddPane` in the destination,
## sequenced here. Three things fall out for free rather than being designed:
##
##   * the SOURCE inherits §2.4's collapse rules, because it is an ordinary
##     `lcRemovePane` — including rule 3, so a window cannot be emptied by
##     dragging its last pane away without the operation refusing;
##   * the move is ATOMIC without a transaction, because `apply` is pure: the
##     two results are values, and a refusal on the second means the first is
##     simply never installed;
##   * a `WindowSet` of size one is not a degraded case. Every operation here
##     type-checks for a front-end that can only ever have one window, and
##     `singleWindow` is what such a front-end holds. It pays a `seq` of one
##     and an `int`.
##
## ## Capability, declared rather than assumed
##
## §3A.1: "A front-end declares the capability. The terminal has exactly one
## window and says so." `WindowCapacity` is that declaration, and
## `openWindow` refuses on a single-window set rather than producing a second
## window a terminal cannot show. This is the same shape as the web build's
## `capMultiWindow` degradation, which is why `panel_transfer.nim` is a hard
## `{.error.}` on `ctWeb` rather than an action that can only refuse.
##
## ## What is NOT here: floating panels (§3A.2)
##
## Multiple TOP-LEVEL windows are supported; floating panels inside one window
## are a stated non-goal. The distinction is ownership: the OS or the browser
## owns a top-level window and a user can find it in a task switcher, whereas
## a floating panel inside our own window is ours to lose. `WindowBounds` is
## the platform's rectangle for a window it owns — it is `Option`, because a
## front-end whose windows have no bounds it can state (a terminal) says so by
## leaving it `none` rather than by writing zeros.

import std/[json, options]

import ./layout_model

type
  WindowId* = distinct int
    ## Opaque to this module. A shell maps it to whatever its platform calls a
    ## window; nothing here interprets the number.

  WindowBounds* = object
    ## The platform's rectangle for a window IT owns. Not a layout coordinate:
    ## nothing inside a `Layout` has a position, and §3A.2 is why.
    x*, y*, width*, height*: int

  WindowSlot* = object
    id*: WindowId
    layout*: Layout
    bounds*: Option[WindowBounds]

  WindowCapacity* = enum
    ## What the front-end says it can show.
    wcSingleWindow = "single"
      ## Exactly one top-level window, forever. The terminal.
    wcMultiWindow = "multi"
      ## As many as the user opens. Electron.

  WindowSet* = object
    windows*: seq[WindowSlot]
    focused*: int
      ## Index into `windows`. Out of range is `wpFocusOutOfRange`.
    capacity*: WindowCapacity
    version*: int

  WindowSetProblemKind* = enum
    ## Every way a window set can be wrong, or a window-set operation can be
    ## refused. Separate from `LayoutProblemKind` because these are about
    ## WINDOWS: a caller that gets one of these must not have to ask whether a
    ## `lpPaneNotPlaced` meant "in this window" or "in any window".
    wpNoWindows = "NoWindows"
      ## A set with no windows. A shell showing nothing has no way back.
    wpFocusOutOfRange = "FocusOutOfRange"
    wpDuplicateWindowId = "DuplicateWindowId"
    wpUnknownWindow = "UnknownWindow"
      ## An operation named a window id that is not in the set.
    wpPaneInTwoWindows = "PaneInTwoWindows"
      ## The same pane placed or docked in two windows at once. The
      ## cross-window twin of `lpDuplicatePane`, and the defect a
      ## remove-then-add that forgot the remove would produce.
    wpSingleWindowOnly = "SingleWindowOnly"
      ## `openWindow` on a front-end that declared `wcSingleWindow`.
    wpLayoutRefused = "LayoutRefused"
      ## The `Layout` half said no, and `layoutProblem` carries its typed
      ## reason verbatim. Wrapping rather than flattening is what lets a
      ## caller report "the source window refused: EmptyRoot" instead of "the
      ## move failed".
    wpSameWindow = "SameWindow"
      ## A cross-window move whose source and destination are the same
      ## window. `moveTabToWindow` refuses it by kind rather than falling
      ## through to an in-window move, because the two are different gestures
      ## and the in-window one is `lcMoveTab`.

  WindowSetProblem* = object
    kind*: WindowSetProblemKind
    window*: Option[WindowId]
    pane*: Option[PaneKind]
    layoutProblem*: Option[LayoutProblem]
      ## Set when the refusal came from the `Layout` half — the `apply` that
      ## said no. Carried rather than flattened, so a caller can report "the
      ## source window refused: EmptyRoot" instead of "the move failed".

  WindowSetOutcomeKind* = enum
    wsApplied = "applied"
    wsNoOp = "noOp"
    wsRefused = "refused"

  WindowSetOutcome* = object
    ## The same three-way answer `LayoutOutcome` gives, for the same reason
    ## (§2.3): a caller that cannot distinguish "nothing changed" from "it
    ## changed" pushes an undo entry for a gesture that did nothing.
    case kind*: WindowSetOutcomeKind
    of wsApplied:
      windows*: WindowSet
    of wsNoOp:
      discard
    of wsRefused:
      problem*: WindowSetProblem

const
  WindowSetSchemaVersion* = 1
    ## Versioned on its own axis, and each window's `Layout` carries its own
    ## version inside its own document. That nesting is deliberate: a layout
    ## schema bump migrates through `layout_model`'s chain without this
    ## module's version moving, and this module's shape can change without
    ## invalidating a layout.

proc `==`*(a, b: WindowId): bool {.borrow.}
proc `$`*(id: WindowId): string {.borrow.}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc singleWindow*(layout: Layout; id: WindowId = WindowId(0)): WindowSet =
  ## What a front-end with exactly one window holds. **This is the whole cost
  ## of windows to such a front-end**: a `seq` of one slot and an `int`. No
  ## operation below has a single-window special case, and none of them is
  ## unavailable — `moveTabToWindow` simply has no second window to name and
  ## refuses with `wpUnknownWindow`, which is a true statement rather than a
  ## degradation.
  WindowSet(windows: @[WindowSlot(id: id, layout: layout,
                                  bounds: none(WindowBounds))],
            focused: 0, capacity: wcSingleWindow,
            version: WindowSetSchemaVersion)

proc multiWindow*(layouts: openArray[Layout]): WindowSet =
  ## A set whose front-end can open more windows. Ids are the indices, which
  ## a shell is free to replace.
  result = WindowSet(windows: @[], focused: 0, capacity: wcMultiWindow,
                     version: WindowSetSchemaVersion)
  for i, l in layouts:
    result.windows.add(WindowSlot(id: WindowId(i), layout: l,
                                  bounds: none(WindowBounds)))

proc indexOf*(ws: WindowSet; id: WindowId): int =
  for i, w in ws.windows:
    if w.id == id:
      return i
  -1

proc focusedLayout*(ws: WindowSet): Layout =
  ## The layout of the focused window. For a single-window front-end this is
  ## "the layout", and reading it costs one bounds check.
  if ws.focused >= 0 and ws.focused < ws.windows.len:
    ws.windows[ws.focused].layout
  else:
    initLayout(nil)

proc clone*(ws: WindowSet): WindowSet =
  ## Deep: every window's tree is a `ref` and would otherwise be shared.
  result = WindowSet(windows: @[], focused: ws.focused,
                     capacity: ws.capacity, version: ws.version)
  for w in ws.windows:
    result.windows.add(WindowSlot(id: w.id, layout: w.layout.clone(),
                                  bounds: w.bounds))

# ---------------------------------------------------------------------------
# Outcome helpers
# ---------------------------------------------------------------------------

proc refuse(kind: WindowSetProblemKind; window = none(WindowId);
            pane = none(PaneKind);
            lp = none(LayoutProblem)): WindowSetOutcome =
  WindowSetOutcome(kind: wsRefused,
                   problem: WindowSetProblem(kind: kind, window: window,
                                             pane: pane, layoutProblem: lp))

proc applied(ws: WindowSet): WindowSetOutcome =
  WindowSetOutcome(kind: wsApplied, windows: ws)

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

proc applyIn*(ws: WindowSet; id: WindowId;
              cmd: LayoutCommand): WindowSetOutcome =
  ## Run an ordinary `LayoutCommand` against one window. Never mutates `ws`.
  ##
  ## This is what makes the set a thin layer rather than a second algebra:
  ## every command in §2.2 reaches a window through here unchanged, and only
  ## the operations that are genuinely ABOUT windows get their own routine.
  let at = ws.indexOf(id)
  if at < 0:
    return refuse(wpUnknownWindow, window = some(id))
  let outcome = apply(ws.windows[at].layout, cmd)
  case outcome.kind
  of loNoOp:
    WindowSetOutcome(kind: wsNoOp)
  of loRefused:
    refuse(wpLayoutRefused, window = some(id), pane = outcome.problem.pane,
           lp = some(outcome.problem))
  of loApplied:
    var next = ws.clone()
    next.windows[at].layout = outcome.layout
    applied(next)

proc moveTabToWindow*(ws: WindowSet; pane: PaneKind; source, destination: WindowId;
                      beside: Option[PaneKind] = none(PaneKind)):
    WindowSetOutcome =
  ## §3A.1's headline: move a pane to another top-level window.
  ##
  ## COMPOSED, NOT SPECIAL-CASED. The body is `lcRemovePane` against the
  ## source layout and `lcAddPane` against the destination, and everything
  ## interesting is inherited:
  ##
  ##   * the source collapses per §2.4 because `lcRemovePane` collapses;
  ##   * dragging a window's LAST pane away is refused, because `lcRemovePane`
  ##     refuses with `lpEmptyRoot` — this routine did not have to know that
  ##     rule existed;
  ##   * the whole thing is atomic because `apply` is pure. The removal
  ##     produces a VALUE; if the insertion then refuses, that value is
  ##     discarded and `ws` was never touched. There is no half-move to undo.
  if source == destination:
    return refuse(wpSameWindow, window = some(source), pane = some(pane))
  let srcAt = ws.indexOf(source)
  if srcAt < 0:
    return refuse(wpUnknownWindow, window = some(source), pane = some(pane))
  let dstAt = ws.indexOf(destination)
  if dstAt < 0:
    return refuse(wpUnknownWindow, window = some(destination),
                  pane = some(pane))
  let title =
    block:
      let leaf = ws.windows[srcAt].layout.tree.find(pane)
      if leaf.isNil: "" else: leaf.title
  let removal = apply(ws.windows[srcAt].layout, cmdRemovePane(pane))
  case removal.kind
  of loNoOp:
    return WindowSetOutcome(kind: wsNoOp)
  of loRefused:
    return refuse(wpLayoutRefused, window = some(source), pane = some(pane),
                  lp = some(removal.problem))
  of loApplied: discard
  let insertion = apply(ws.windows[dstAt].layout,
                        cmdAddPane(pane, title, after = beside))
  case insertion.kind
  of loNoOp:
    return WindowSetOutcome(kind: wsNoOp)
  of loRefused:
    # The removal is discarded here. That is the atomicity, and it is a
    # consequence of `apply` returning values rather than mutating.
    return refuse(wpPaneInTwoWindows, window = some(destination),
                  pane = some(pane), lp = some(insertion.problem))
  of loApplied: discard
  var next = ws.clone()
  next.windows[srcAt].layout = removal.layout
  next.windows[dstAt].layout = insertion.layout
  applied(next)

proc openWindow*(ws: WindowSet; id: WindowId; layout: Layout;
                 bounds: Option[WindowBounds] = none(WindowBounds)):
    WindowSetOutcome =
  ## Add a top-level window. Refused on a `wcSingleWindow` front-end — the
  ## capability is declared, not discovered by trying.
  if ws.capacity == wcSingleWindow:
    return refuse(wpSingleWindowOnly, window = some(id))
  if ws.indexOf(id) >= 0:
    return refuse(wpDuplicateWindowId, window = some(id))
  for w in ws.windows:
    for p in w.layout.allPanes():
      if layout.tree.contains(p) or layout.dockedIndex(p) >= 0:
        return refuse(wpPaneInTwoWindows, window = some(id), pane = some(p))
  var next = ws.clone()
  next.windows.add(WindowSlot(id: id, layout: layout, bounds: bounds))
  applied(next)

proc closeWindow*(ws: WindowSet; id: WindowId): WindowSetOutcome =
  ## Remove a window. Refused when it is the last one: a shell with no window
  ## is `wpNoWindows`, which is `lpEmptyRoot` one level up and refused for the
  ## same reason.
  let at = ws.indexOf(id)
  if at < 0:
    return refuse(wpUnknownWindow, window = some(id))
  if ws.windows.len <= 1:
    return refuse(wpNoWindows, window = some(id))
  var next = ws.clone()
  next.windows.delete(at)
  if next.focused >= next.windows.len:
    next.focused = next.windows.len - 1
  applied(next)

proc focus*(ws: WindowSet; id: WindowId): WindowSetOutcome =
  let at = ws.indexOf(id)
  if at < 0:
    return refuse(wpUnknownWindow, window = some(id))
  if at == ws.focused:
    return WindowSetOutcome(kind: wsNoOp)
  var next = ws.clone()
  next.focused = at
  applied(next)

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

proc validate*(ws: WindowSet; owned: set[PaneKind] = {}): seq[WindowSetProblem] =
  ## Every way the set is wrong. Layout-level defects are reported through
  ## `layoutProblem`, so one walk answers both levels.
  result = @[]
  if ws.windows.len == 0:
    result.add(WindowSetProblem(kind: wpNoWindows, window: none(WindowId),
                                pane: none(PaneKind),
                                layoutProblem: none(LayoutProblem)))
    return
  if ws.focused < 0 or ws.focused >= ws.windows.len:
    result.add(WindowSetProblem(kind: wpFocusOutOfRange, window: none(WindowId),
                                pane: none(PaneKind),
                                layoutProblem: none(LayoutProblem)))
  for i, w in ws.windows:
    for j in 0 ..< i:
      if ws.windows[j].id == w.id:
        result.add(WindowSetProblem(kind: wpDuplicateWindowId,
                                    window: some(w.id), pane: none(PaneKind),
                                    layoutProblem: none(LayoutProblem)))
    for p in validate(w.layout):
      result.add(WindowSetProblem(kind: wpPaneInTwoWindows, window: some(w.id),
                                  pane: p.pane, layoutProblem: some(p)))
  # A pane may appear in exactly one window. `panel_transfer.nim` removes
  # before it adds for this reason; a set in which it did not would render the
  # same ViewModel in two windows, which is `lpDuplicatePane` across a
  # boundary `validate(Layout)` cannot see.
  for i, w in ws.windows:
    for p in w.layout.allPanes():
      for j in (i + 1) ..< ws.windows.len:
        if ws.windows[j].layout.tree.contains(p) or
           ws.windows[j].layout.dockedIndex(p) >= 0:
          result.add(WindowSetProblem(kind: wpPaneInTwoWindows,
                                      window: some(w.id), pane: some(p),
                                      layoutProblem: none(LayoutProblem)))
  # `owned` is the shell's set, exactly as it is for `validate(Layout)`, and
  # here it spans the whole set rather than one window — which is the answer a
  # shell actually wants: "is this pane anywhere?"
  for p in owned:
    var found = false
    for w in ws.windows:
      if w.layout.tree.contains(p) or w.layout.dockedIndex(p) >= 0:
        found = true
    if not found:
      result.add(WindowSetProblem(
        kind: wpUnknownWindow, window: none(WindowId), pane: some(p),
        layoutProblem: some(LayoutProblem(kind: lpPaneNeitherPlacedNorDocked,
                                          path: "", pane: some(p)))))

proc isValid*(ws: WindowSet; owned: set[PaneKind] = {}): bool =
  validate(ws, owned).len == 0

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

proc saveWindowSet*(ws: WindowSet): JsonNode =
  ## §3A.1: "restoring a session should restore the window SET, not one
  ## window's arrangement — which is more than `savedLayoutConfig` captures
  ## today."
  result = newJObject()
  result["version"] = %WindowSetSchemaVersion
  result["capacity"] = %($ws.capacity)
  result["focused"] = %ws.focused
  var arr = newJArray()
  for w in ws.windows:
    var entry = newJObject()
    entry["id"] = %int(w.id)
    entry["layout"] = saveLayout(w.layout)
    if w.bounds.isSome:
      let b = w.bounds.get
      entry["bounds"] = %*{"x": b.x, "y": b.y, "width": b.width,
                           "height": b.height}
    arr.add(entry)
  result["windows"] = arr

proc restoreWindowSet*(j: JsonNode): WindowSet =
  ## Decode. Each window's layout goes through `restoreLayoutDocument`, so a
  ## v1 layout inside a v1 window set migrates without this module knowing
  ## that layouts have versions at all.
  if j.isNil or j.kind != JObject:
    raise (ref LayoutDecodeError)(
      kind: ldeNotAnObject,
      msg: "restoreWindowSet: document is not an object")
  if not j.hasKey("version") or j["version"].kind != JInt:
    raise (ref LayoutDecodeError)(
      kind: ldeMissingField, detail: "version",
      msg: "restoreWindowSet: missing or non-integer 'version'")
  if j["version"].getInt != WindowSetSchemaVersion:
    raise (ref LayoutDecodeError)(
      kind: ldeUnknownVersion, detail: $j["version"].getInt,
      msg: "restoreWindowSet: schema version " & $j["version"].getInt &
           " is not " & $WindowSetSchemaVersion)
  if not j.hasKey("windows") or j["windows"].kind != JArray:
    raise (ref LayoutDecodeError)(
      kind: ldeMissingField, detail: "windows",
      msg: "restoreWindowSet: missing or non-array 'windows'")
  result = WindowSet(windows: @[], focused: 0, capacity: wcMultiWindow,
                     version: WindowSetSchemaVersion)
  if j.hasKey("capacity"):
    if j["capacity"].kind != JString:
      raise (ref LayoutDecodeError)(
        kind: ldeWrongFieldType, detail: "capacity",
        msg: "restoreWindowSet: 'capacity' is not a string")
    var known = false
    for c in WindowCapacity:
      if $c == j["capacity"].getStr:
        result.capacity = c
        known = true
    if not known:
      raise (ref LayoutDecodeError)(
        kind: ldeUnknownVersion, detail: j["capacity"].getStr,
        msg: "restoreWindowSet: unknown capacity '" &
             j["capacity"].getStr & "'")
  for entry in j["windows"]:
    if entry.kind != JObject:
      raise (ref LayoutDecodeError)(
        kind: ldeNotAnObject, msg: "restoreWindowSet: window is not an object")
    if not entry.hasKey("id") or entry["id"].kind != JInt:
      raise (ref LayoutDecodeError)(
        kind: ldeMissingField, detail: "id",
        msg: "restoreWindowSet: window has no integer 'id'")
    if not entry.hasKey("layout"):
      raise (ref LayoutDecodeError)(
        kind: ldeMissingField, detail: "layout",
        msg: "restoreWindowSet: window has no 'layout'")
    var slot = WindowSlot(id: WindowId(entry["id"].getInt),
                          layout: restoreLayoutDocument(entry["layout"]),
                          bounds: none(WindowBounds))
    if entry.hasKey("bounds"):
      let b = entry["bounds"]
      if b.kind != JObject:
        raise (ref LayoutDecodeError)(
          kind: ldeWrongFieldType, detail: "bounds",
          msg: "restoreWindowSet: 'bounds' is not an object")
      slot.bounds = some(WindowBounds(
        x: b{"x"}.getInt, y: b{"y"}.getInt,
        width: b{"width"}.getInt, height: b{"height"}.getInt))
    result.windows.add(slot)
  if j.hasKey("focused") and j["focused"].kind == JInt:
    result.focused = j["focused"].getInt
