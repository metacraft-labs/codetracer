## window_clicks.nim — PLAT-50, the GPUI window's half of the click sweep: the
## desktop's click behaviours (`headless_app/pane_clicks.ClickInventory`) on
## the parts of the window the window draws.
##
## ## How a click reaches a row
##
## The window's panes are element trees the shim lays out; their rows have no
## pixel geometry this side can compute (a vocabulary `Tree` or `Table` row is
## as tall as its text). So the window does not hit-test rows itself, as it
## does the call trace (`main.clickCalltrace`, fixed-pitch native rows): it
## LISTENS ON THE ROWS. Every row this module recognises gets three pointer
## listeners — `mousedown` (the left button, with the modifiers held),
## `contextmenu` (the right button) and `auxdown` (the middle) — and the
## shim's own hit test delivers a press to the element under the pointer
## (isonim-gpui's `wire_pointer_listeners`; the right and middle buttons are
## new there for this). A listener names its row by the attributes the
## renderers already stamp:
##
##   * a Files node — the vocabulary `Tree` node under `fileTree` (its id is
##     the child-index path from the tree's root: `fileTree.0.1`);
##   * an event — a vocabulary `Table` row (`tr`, `data-row-index`) under
##     `eventLog`;
##   * a variable — a vocabulary `Tree` node under `state.root` (its id is the
##     variable's path);
##   * the editor's gutter and code column of a row (`data-ct-row`);
##   * a call-trace row (`data-call-index`);
##   * a pane tab in a strip (`data-ct-tab-pane`);
##   * the timeline's track (`data-ct-timeline-track`).
##
## A press bubbles in GPUI: a nested `Tree` node's ancestors hear the press on
## it too. The DEEPEST row answers and the rest of that one press is ignored
## (`PressDedupe`); the window root, which hears every press last, clears it.
##
## ## The right-click menu
##
## `pane_clicks.ContextMenuState` is the menu; this module places it as a
## popover at the press (kept in the window), and hit-tests a pixel against
## its rows, as the program menu's popovers are (`window_top_bar`).
##
## Nothing here talks to an engine: a click is a `GPaneClick` value handed to
## the window's handler (`main.onPaneClick`), which runs the shared ops.

import std/strutils

import isonim_gpui/renderer

import headless_app/pane_clicks
import ../view_vocabulary/fact_reader   # `ViewIdAttribute`, `ViewKindAttribute`
from ../../common/view_vocabulary/layout_questions import trGutterLineNumber,
  trValueText
import ./app/leaves
import ./window_geometry
import ./window_top_bar

export pane_clicks

type
  GClickPart* = enum
    gcpNone = "none"
    gcpFileNode = "file"
    gcpEventRow = "event"
    gcpVariable = "var"
    gcpGutter = "gutter"
    gcpCode = "code"
    gcpCallRow = "call"
    gcpTab = "tab"
    gcpTimelineTrack = "timeline"
    gcpPoint = "point"
      ## A point-list row (`pointList`'s option).
    gcpStateTab = "statetab"
      ## The Variables pane's Locals / Globals / Watches tab.
    gcpEventHeader = "header"
      ## An event-log column's header (`th`).
    gcpCallArg = "arg"
      ## A call-trace argument (`data-call-arg`).
    gcpScratchClose = "scratch"
      ## A pinned value's close button (the scratchpad's first cell).
    gcpValue = "value"
      ## An editor row's inline value annotation.
    gcpPosition = "position"
      ## The footer's location (`data-ct-footer-position`).
    gcpVcsFile = "vcsfile"
      ## A changed file, of the working tree or of an opened commit.
    gcpVcsCommit = "commit"
      ## A commit of the VCS pane's history.

  GClickButton* = enum
    gbLeft = "left"
    gbRight = "right"
    gbMiddle = "middle"

  GPaneClick* = object
    ## One press on one part of the window.
    part*: GClickPart
    key*: string
      ## A Files node's id, a variable's path, a tab's pane id.
    index*: int64
      ## An event row's index, a call's trace index.
    line*: int
      ## An editor row's line.
    button*: GClickButton
    ctrl*, alt*: bool
    x*, y*: int
      ## The press, in window pixels (the timeline's tick is read from x).

  PressDedupe* = object
    ## The press the deepest row already answered, so its ancestors' copies
    ## of the same press are dropped.
    armed*: bool
    kind*: GpuiEventKind
    key*: string

const
  WiredAttribute* = "data-ct-clicks"
    ## Stamped on an element once its listeners are attached, so a re-walk of
    ## the window (after every redraw) never attaches a second set.
  TabPaneAttribute* = "data-ct-tab-pane"
    ## A strip tab's pane id (`main.drawNode`).
  TimelineTrackAttribute* = "data-ct-timeline-track"
    ## The timeline's track (`leaves.renderTimeline`).
  FooterPositionAttribute* = "data-ct-footer-position"
    ## The footer's location (`main.drawFooter`).
  WindowRootAttribute* = "data-ct-window-root"
    ## The window's root (`main`), whose own pointer listener routes the
    ## window's presses; a row's press bubbles up to, not into, it.
  ContextRowPx* = MenuItemPx
    ## One right-click menu row: the program menu's row.
  ContextMenuPadPx* = 4
  ContextMenuMinPx* = 200

proc admit*(d: var PressDedupe; ev: GpuiEvent): bool =
  ## Whether this listener should act on `ev`: the first row to hear a press
  ## acts, every ancestor hearing the same press after it does not.
  if d.armed and d.kind == ev.kind and d.key == ev.key:
    return false
  d = PressDedupe(armed: true, kind: ev.kind, key: ev.key)
  true

proc clear*(d: var PressDedupe) =
  ## The window root heard the press: the next one is a new press.
  d.armed = false

proc buttonOf(ev: GpuiEvent): GClickButton =
  case ev.kind
  of gekContextMenu: gbRight
  of gekAuxDown: gbMiddle
  else: gbLeft

proc childIndexPath*(id: string; prefix: string): seq[int] =
  ## `fileTree.0.1` -> `@[0, 1]`: the child indices from the tree's root.
  if not id.startsWith(prefix):
    return
  for part in id[prefix.len .. ^1].split('.'):
    if part.len == 0: continue
    try: result.add parseInt(part)
    except ValueError: return @[]

proc wireOne(r: GpuiRenderer; el: GpuiElement; c: GPaneClick;
             dedupe: ptr PressDedupe; onClick: proc(c: GPaneClick)) =
  r.setAttribute(el, WiredAttribute, $c.part)
  let base = c
  proc handler(ev: GpuiEvent) =
    if not dedupe[].admit(ev):
      return
    var click = base
    click.button = buttonOf(ev)
    click.ctrl = gmControl in ev.modifiers
    click.alt = gmAlt in ev.modifiers
    let p = pointerOf(ev)
    if p.valid:
      click.x = int(p.x)
      click.y = int(p.y)
    onClick(click)
  for name in ["mousedown", "contextmenu", "auxdown"]:
    r.addEventListener(el, name, handler)

proc wireWindowClicks*(r: GpuiRenderer; root: GpuiElement;
                       dedupe: ptr PressDedupe;
                       onClick: proc(c: GPaneClick)): int {.discardable.} =
  ## Walk the window's tree and give every row this module recognises (see
  ## the header) its listeners, once. Answers how many rows were wired by
  ## this walk.
  var wiredNow = 0
  proc walk(el: GpuiElement; context: string) =
    if el.isNil:
      return
    var ctx = context
    let id = getAttribute(el, ViewIdAttribute)
    let kind = getAttribute(el, ViewKindAttribute)
    if id == "eventLog": ctx = "eventLog"
    elif id == "state.root": ctx = "state"
    elif id == "fileTree": ctx = "fileTree"
    elif id == "pointList": ctx = "pointList"
    elif id == "state.tabs": ctx = "stateTabs"
    elif id == "scratchpad": ctx = "scratchpad"
    elif id == "vcs.workingTree.files": ctx = "vcsFiles"
    elif id == "vcs.commits.list": ctx = "vcsCommits"
    let wired = getAttribute(el, WiredAttribute).len > 0
    if not wired:
      var c = GPaneClick(part: gcpNone)
      if kind == "Tree" and ctx == "fileTree" and id.startsWith("fileTree"):
        c = GPaneClick(part: gcpFileNode, key: id)
      elif kind == "Tree" and ctx == "state" and id != "state.root" and
           id.len > 0:
        c = GPaneClick(part: gcpVariable, key: id)
      elif ctx == "eventLog" and getAttribute(el, "data-row-index").len > 0:
        try:
          c = GPaneClick(part: gcpEventRow,
                         index: parseInt(getAttribute(el, "data-row-index")))
        except ValueError: discard
      elif ctx == "eventLog" and getAttribute(el, "data-column-index").len > 0 and
           getAttribute(r.parentNode(el), "data-row-index").len == 0:
        # A header cell (a cell of the row with no row index): its column.
        try:
          c = GPaneClick(part: gcpEventHeader,
                         index: parseInt(getAttribute(el, "data-column-index")))
        except ValueError: discard
      elif ctx == "scratchpad" and
           getAttribute(el, "data-column-index") == "0" and
           getAttribute(r.parentNode(el), "data-row-index").len > 0:
        # The FIRST cell of a row is its close button.
        try:
          c = GPaneClick(part: gcpScratchClose,
                         index: parseInt(getAttribute(r.parentNode(el),
                                                      "data-row-index")))
        except ValueError: discard
      elif ctx in ["pointList", "stateTabs", "vcsFiles", "vcsCommits"] and
           getAttribute(el, "data-option-index").len > 0:
        let option = getAttribute(el, "data-option-id")
        try:
          let i = parseInt(getAttribute(el, "data-option-index"))
          c = case ctx
              of "pointList": GPaneClick(part: gcpPoint, index: i)
              of "stateTabs": GPaneClick(part: gcpStateTab, index: i)
              of "vcsFiles": GPaneClick(part: gcpVcsFile, key: option)
              else:
                if option.startsWith("commitfile-"):
                  GPaneClick(part: gcpVcsFile, key: option)
                else: GPaneClick(part: gcpVcsCommit, index: i, key: option)
        except ValueError: discard
      elif getAttribute(el, CallArgAttribute).len > 0:
        let row = r.parentNode(el)
        if not row.isNil and getAttribute(row, CallRowAttribute).len > 0:
          try:
            c = GPaneClick(part: gcpCallArg,
                           index: parseBiggestInt(getAttribute(row,
                                                               CallRowAttribute)),
                           line: parseInt(getAttribute(el, CallArgAttribute)))
          except ValueError: discard
      elif getAttribute(el, TextRoleAttribute) == $trValueText:
        let column = r.parentNode(el)
        let row = if column.isNil: nil else: r.parentNode(column)
        let line = if row.isNil: "" else: getAttribute(row, EditorRowAttribute)
        if line.len > 0:
          try: c = GPaneClick(part: gcpValue, line: parseInt(line))
          except ValueError: discard
      elif getAttribute(el, FooterPositionAttribute).len > 0:
        c = GPaneClick(part: gcpPosition,
                       key: getAttribute(el, FooterPositionAttribute))
      elif getAttribute(el, CallRowAttribute).len > 0:
        try:
          c = GPaneClick(part: gcpCallRow,
                         index: parseBiggestInt(getAttribute(el,
                                                             CallRowAttribute)))
        except ValueError: discard
      elif getAttribute(el, TabPaneAttribute).len > 0:
        c = GPaneClick(part: gcpTab, key: getAttribute(el, TabPaneAttribute))
      elif getAttribute(el, TimelineTrackAttribute).len > 0:
        c = GPaneClick(part: gcpTimelineTrack)
      elif getAttribute(el, TextRoleAttribute) == $trGutterLineNumber or
           getAttribute(el, EditorCodeColumnAttribute).len > 0:
        let row = r.parentNode(el)
        let line = if row.isNil: "" else: getAttribute(row, EditorRowAttribute)
        if line.len > 0:
          try:
            c = GPaneClick(
              part: (if getAttribute(el, EditorCodeColumnAttribute).len > 0:
                       gcpCode else: gcpGutter),
              line: parseInt(line))
          except ValueError: discard
      if c.part != gcpNone:
        wireOne(r, el, c, dedupe, onClick)
        inc wiredNow
    for i in 0 ..< childCount(el):
      walk(nthChild(el, i), ctx)
  walk(root, "")
  wiredNow

proc findClickTarget*(r: GpuiRenderer; root: GpuiElement; part: GClickPart;
                      key: string): GpuiElement =
  ## The wired element for `part` named by `key` — a Files node's label or
  ## id, a variable's path, an event's row index, a call's index, a line, a
  ## tab's pane id — for `--window-ops`' `click:` events, which press it
  ## exactly as the shim delivers a press to it.
  proc matches(el: GpuiElement): bool =
    if getAttribute(el, WiredAttribute) != $part:
      return false
    case part
    of gcpFileNode:
      getAttribute(el, ViewIdAttribute) == key or
        (childCount(el) > 0 and textContent(nthChild(el, 0)) == key)
    of gcpVariable: getAttribute(el, ViewIdAttribute) == key
    of gcpEventRow: getAttribute(el, "data-row-index") == key
    of gcpCallRow: getAttribute(el, CallRowAttribute) == key
    of gcpTab: getAttribute(el, TabPaneAttribute) == key
    of gcpTimelineTrack, gcpPosition: true
    of gcpGutter, gcpCode:
      let row = r.parentNode(el)
      not row.isNil and getAttribute(row, EditorRowAttribute) == key
    of gcpValue:
      let row = r.parentNode(r.parentNode(el))
      not row.isNil and getAttribute(row, EditorRowAttribute) == key
    of gcpPoint, gcpStateTab:
      getAttribute(el, "data-option-index") == key
    of gcpVcsFile, gcpVcsCommit:
      getAttribute(el, "data-option-id") == key or
        (childCount(el) > 0 and textContent(nthChild(el, 0)).endsWith(key))
    of gcpEventHeader:
      childCount(el) > 0 and textContent(nthChild(el, 0)).startsWith(key)
    of gcpScratchClose:
      let tr = r.parentNode(el)
      not tr.isNil and getAttribute(tr, "data-row-index") == key
    of gcpCallArg:
      let row = r.parentNode(el)
      let colon = key.find('/')
      colon > 0 and not row.isNil and
        getAttribute(row, CallRowAttribute) == key[0 ..< colon] and
        getAttribute(el, CallArgAttribute) == key[colon + 1 .. ^1]
    of gcpNone: false
  proc walk(el: GpuiElement): GpuiElement =
    if el.isNil: return nil
    if matches(el): return el
    for i in 0 ..< childCount(el):
      let found = walk(nthChild(el, i))
      if not found.isNil: return found
    nil
  walk(root)

# ---------------------------------------------------------------------------
# The right-click menu's popover
# ---------------------------------------------------------------------------

proc contextMenuRect*(s: ContextMenuState; viewportW, viewportH: int): PxRect =
  ## The popover: its top-left at the press (`anchorCol`, `anchorRow` are the
  ## press's x and y), kept inside the window.
  if not s.open or s.menu.entries.len == 0:
    return PxRect()
  var widest = 0
  for e in s.menu.entries:
    widest = max(widest, textPx(e.label) +
                         (if e.hint.len > 0: textPx(e.hint) + 3 * TabCharPx
                          else: 0))
  let w = min(viewportW, max(ContextMenuMinPx, widest + 2 * TabPadPx +
                                               2 * ContextMenuPadPx))
  let h = min(viewportH, s.menu.entries.len * ContextRowPx +
                         2 * ContextMenuPadPx)
  PxRect(x: max(0, min(s.anchorCol, viewportW - w)),
         y: max(0, min(s.anchorRow, viewportH - h)), w: w, h: h)

proc contextMenuRows*(s: ContextMenuState; rect: PxRect):
    seq[tuple[rect: PxRect, entry: int]] =
  ## Each entry's row inside the popover.
  for i in 0 ..< s.menu.entries.len:
    let y = rect.y + ContextMenuPadPx + i * ContextRowPx
    if y + ContextRowPx > rect.y + rect.h:
      break
    result.add (PxRect(x: rect.x + ContextMenuPadPx, y: y,
                       w: rect.w - 2 * ContextMenuPadPx, h: ContextRowPx), i)

proc contextMenuHitAt*(s: ContextMenuState; rect: PxRect;
                       x, y: int): tuple[inside: bool, entry: int] =
  ## `inside` for any pixel of the popover; `entry` the row under it, -1 on
  ## its padding.
  if rect.w <= 0 or not rect.contains(x, y):
    return (false, -1)
  for (rr, i) in contextMenuRows(s, rect):
    if rr.contains(x, y):
      return (true, i)
  (true, -1)
