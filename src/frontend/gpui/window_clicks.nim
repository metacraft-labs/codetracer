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
##   * a pane tab in a strip (`data-ct-tab-pane`).
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
    gcpPoint = "point"
      ## A point-list row (`pointList`'s option).
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
    gcpStateControl = "statecontrol"
      ## PLAT-51: a Variables row's value control — `history:<path>`,
      ## `origin:<path>`, `unwatch:<expression>` (`StateControlAttribute`).
    gcpHistoryEntry = "history"
      ## PLAT-51: a value-history row under its variable; the key is its tick.
    gcpAddWatch = "addwatch"
      ## PLAT-51: the Watches tab's "Add watch expression…" row.
    gcpCallSearch = "callsearch"
      ## The call trace's search field (`CallSearchAttribute`).
    gcpOriginHop = "hop"
      ## A hop of an open origin chain; the key is its index, its variable's
      ## path after `#` (`StateOriginHopAttribute`).

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
    ctrl*, alt*, shift*: bool
    clickCount*: int
      ## The platform's count (GPUI's `MouseDownEvent.click_count`), 0 when the
      ## event carries none.
    x*, y*: int
      ## The press, in window pixels.

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

func contextOfViewId(id: string): string =
  ## The pane a row belongs to, when `id` is the view id of a pane's root.
  case id
  of "eventLog": "eventLog"
  of "state.root": "state"
  of "fileTree": "fileTree"
  of "pointList": "pointList"
  of "scratchpad": "scratchpad"
  of "vcs.workingTree.files": "vcsFiles"
  of "vcs.commits.list": "vcsCommits"
  else: ""

template classifyClick(at: int; ctx: string; attrAt, up: untyped): GPaneClick =
  ## The click a press on node `at` reports, read off the tree through
  ## `attrAt(node, name)` and `up(node)` (its parent, -1 above the top):
  ## a snapshot's when the window wires the row, the live element's when
  ## the press arrives (`wireOne`). `ctx` is the pane the node is in.
  block:
    let id = attrAt(at, ViewIdAttribute)
    let kind = attrAt(at, ViewKindAttribute)
    var c = GPaneClick(part: gcpNone)
    if kind == "Tree" and ctx == "fileTree" and id.startsWith("fileTree"):
      c = GPaneClick(part: gcpFileNode, key: id)
    elif kind == "Tree" and ctx == "state" and id != "state.root" and
         id.len > 0:
      c = GPaneClick(part: gcpVariable, key: id)
    elif ctx == "eventLog" and attrAt(at, "data-row-index").len > 0:
      try:
        c = GPaneClick(part: gcpEventRow,
                       index: parseInt(attrAt(at, "data-row-index")))
      except ValueError: discard
    elif ctx == "eventLog" and attrAt(at, "data-column-index").len > 0 and
         attrAt(up(at), "data-row-index").len == 0:
      # A header cell (a cell of the row with no row index): its column.
      try:
        c = GPaneClick(part: gcpEventHeader,
                       index: parseInt(attrAt(at, "data-column-index")))
      except ValueError: discard
    elif ctx == "scratchpad" and
         attrAt(at, "data-column-index") == "0" and
         attrAt(up(at), "data-row-index").len > 0:
      # The FIRST cell of a row is its close button.
      try:
        c = GPaneClick(part: gcpScratchClose,
                       index: parseInt(attrAt(up(at), "data-row-index")))
      except ValueError: discard
    elif ctx in ["pointList", "vcsFiles", "vcsCommits"] and
         attrAt(at, "data-option-index").len > 0:
      let option = attrAt(at, "data-option-id")
      try:
        let i = parseInt(attrAt(at, "data-option-index"))
        c = case ctx
            of "pointList": GPaneClick(part: gcpPoint, index: i)
            of "vcsFiles": GPaneClick(part: gcpVcsFile, key: option)
            else:
              if option.startsWith("commitfile-"):
                GPaneClick(part: gcpVcsFile, key: option)
              else: GPaneClick(part: gcpVcsCommit, index: i, key: option)
      except ValueError: discard
    elif attrAt(at, CallArgAttribute).len > 0:
      let row = up(at)
      if row >= 0 and attrAt(row, CallRowAttribute).len > 0:
        try:
          c = GPaneClick(part: gcpCallArg,
                         index: parseBiggestInt(attrAt(row, CallRowAttribute)),
                         line: parseInt(attrAt(at, CallArgAttribute)))
        except ValueError: discard
    elif attrAt(at, TextRoleAttribute) == $trValueText:
      let line = attrAt(up(up(at)), EditorRowAttribute)
      if line.len > 0:
        try: c = GPaneClick(part: gcpValue, line: parseInt(line))
        except ValueError: discard
    elif attrAt(at, FooterPositionAttribute).len > 0:
      c = GPaneClick(part: gcpPosition,
                     key: attrAt(at, FooterPositionAttribute))
    elif attrAt(at, CallRowAttribute).len > 0:
      try:
        c = GPaneClick(part: gcpCallRow,
                       index: parseBiggestInt(attrAt(at, CallRowAttribute)))
      except ValueError: discard
    elif attrAt(at, StateControlAttribute).len > 0:
      c = GPaneClick(part: gcpStateControl,
                     key: attrAt(at, StateControlAttribute))
    elif attrAt(at, StateHistoryEntryAttribute).len > 0:
      c = GPaneClick(part: gcpHistoryEntry,
                     key: attrAt(at, StateHistoryEntryAttribute))
    elif attrAt(at, StateOriginHopAttribute).len > 0:
      c = GPaneClick(part: gcpOriginHop,
                     key: attrAt(at, StateOriginHopAttribute) & "#" &
                          attrAt(at, StateOriginPathAttribute))
    elif attrAt(at, StateAddWatchAttribute).len > 0:
      c = GPaneClick(part: gcpAddWatch, key: "watch")
    elif attrAt(at, CallSearchAttribute).len > 0:
      c = GPaneClick(part: gcpCallSearch, key: "calls")
    elif attrAt(at, TabPaneAttribute).len > 0:
      c = GPaneClick(part: gcpTab, key: attrAt(at, TabPaneAttribute))
    elif attrAt(at, TextRoleAttribute) == $trGutterLineNumber or
         attrAt(at, EditorCodeColumnAttribute).len > 0:
      let line = attrAt(up(at), EditorRowAttribute)
      if line.len > 0:
        try:
          c = GPaneClick(
            part: (if attrAt(at, EditorCodeColumnAttribute).len > 0:
                     gcpCode else: gcpGutter),
            line: parseInt(line))
        except ValueError: discard

    c

proc liveClickOf(r: GpuiRenderer; el: GpuiElement): GPaneClick =
  ## The click a press on `el` reports, read off the element as it is NOW:
  ## its attributes and its ancestors'. A row the window kept across a
  ## redraw (`element_reuse`) may have been rewired by its attributes since
  ## it was first wired, so its listener asks the tree rather than
  ## remembering what the row said then.
  var chain = @[el]
  proc nodeAt(at: int): GpuiElement =
    while chain.len <= at and not chain[^1].isNil:
      chain.add r.parentNode(chain[^1])
    if at < chain.len: chain[at] else: nil
  proc attrAt(at: int; name: string): string =
    let e = if at < 0: nil else: nodeAt(at)
    if e.isNil: "" else: getAttribute(e, name)
  proc up(at: int): int =
    if at < 0 or nodeAt(at + 1).isNil: -1 else: at + 1
  var ctx = ""
  var k = 0
  while ctx.len == 0 and not nodeAt(k).isNil:
    ctx = contextOfViewId(getAttribute(nodeAt(k), ViewIdAttribute))
    inc k
  classifyClick(0, ctx, attrAt, up)

proc wireOne(r: GpuiRenderer; el: GpuiElement; c: GPaneClick;
             dedupe: ptr PressDedupe; onClick: proc(c: GPaneClick)) =
  ## `el`'s listeners. The click they report is read off the element when
  ## the press arrives (`liveClickOf`), not captured from `c`: a row the
  ## window keeps across redraws keeps its listeners, and they must report
  ## what the row says now.
  r.setAttribute(el, WiredAttribute, $c.part)
  let id = nodeId(el)
  proc handler(ev: GpuiEvent) =
    if not dedupe[].admit(ev):
      return
    let live = elementOf(id)
    if live.isNil:
      return
    var click = liveClickOf(r, live)
    if click.part == gcpNone:
      return
    click.button = buttonOf(ev)
    click.ctrl = gmControl in ev.modifiers
    click.alt = gmAlt in ev.modifiers
    click.shift = gmShift in ev.modifiers
    let p = pointerOf(ev)
    if p.valid:
      click.x = int(p.x)
      click.y = int(p.y)
      click.clickCount = p.clickCount
    onClick(click)
  for name in ["mousedown", "contextmenu", "auxdown"]:  # ir1-gate: hit test (reports the row to onClick)
    r.addEventListener(el, name, handler)

proc wireWindowClicks*(r: GpuiRenderer; nodes: var seq[SnapshotNode];
                       dedupe: ptr PressDedupe;
                       onClick: proc(c: GPaneClick)): int {.discardable.} =
  ## Walk the window's tree and give every row this module recognises (see
  ## the header) its listeners, once. Answers how many rows were wired by
  ## this walk.
  ##
  ## The tree is `nodes`, read ONCE (`snapshotTree`) and shared with
  ## `window_pointer.stampPointerShapes`: both walks run after every redraw,
  ## over every element of the window, and a shim call per attribute name
  ## per element made them the larger part of a live divider drag's cost a
  ## motion. An element's parent and grandparent are read from the snapshot
  ## too; only the rows wired here take a handle, and each is recorded in
  ## `nodes` (its `WiredAttribute`) as it is on the element, for the stamp.
  var wiredNow = 0
  var contexts = newSeq[string](nodes.len)
  template up(at: int): int =
    ## The parent of node `at`, -1 above the root (or for -1).
    (let k = at; if k < 0: -1 else: nodes[k].parent)
  template attrAt(at: int; name: string): string =
    ## Node `at`'s `name`, "" for -1 — what `getAttribute` says of a nil node.
    (let k = at; if k < 0: "" else: nodes[k].attr(name))
  for i in 0 ..< nodes.len:
    template n: untyped = nodes[i]
    # A row's pane is named by its nearest enclosing pane root.
    var ctx = if n.parent >= 0: contexts[n.parent] else: ""
    let own = contextOfViewId(n.attr(ViewIdAttribute))
    if own.len > 0: ctx = own
    contexts[i] = ctx
    let wired = n.attr(WiredAttribute).len > 0
    if not wired:
      let c = classifyClick(i, ctx, attrAt, up)
      if c.part != gcpNone:
        let el = elementOf(n.id)
        if not el.isNil:
          wireOne(r, el, c, dedupe, onClick)
          n.attributes.add (WiredAttribute, $c.part)
          inc wiredNow
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
    of gcpPosition, gcpAddWatch, gcpCallSearch: true
    of gcpOriginHop:
      getAttribute(el, StateOriginHopAttribute) & "#" &
        getAttribute(el, StateOriginPathAttribute) == key
    of gcpStateControl, gcpHistoryEntry:
      getAttribute(el, StateControlAttribute) == key or
        getAttribute(el, StateHistoryEntryAttribute) == key
    of gcpGutter, gcpCode:
      let row = r.parentNode(el)
      not row.isNil and getAttribute(row, EditorRowAttribute) == key
    of gcpValue:
      let row = r.parentNode(r.parentNode(el))
      not row.isNil and getAttribute(row, EditorRowAttribute) == key
    of gcpPoint:
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
