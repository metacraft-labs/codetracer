## The context-expansion gesture on a Monaco diff editor (UD-2).
##
## DeepReview-GUI.md §4.2 requires expanding the surrounding context above and
## below a visible region; §4.3 asks for the boundary to be *draggable*:
##
##   "Each currently visible context boundary exposes a draggable edge line.
##    Dragging that boundary upward or downward increases the number of visible
##    lines without forcing the user to repeatedly press expansion buttons."
##
## What Monaco already does, and what this module adds
## ---------------------------------------------------
## Measured against the shipped bundle of the vendored monaco-editor 0.54.0
## (``src/public/third_party/monaco-editor/min/vs/editor.api-i0YVFWkl.js``),
## not against ``monaco.d.ts``.  With ``hideUnchangedRegions`` on, the editor
## draws a ``div.diff-hidden-lines`` widget at each collapsed run, containing:
##
## - ``div.top`` and ``div.bottom`` — the **drag handles**, bound to
##   ``mousedown``/``mousemove``/``mouseup``.  A drag moves the boundary by one
##   line per line-height; a press without movement calls ``showMoreAbove`` /
##   ``showMoreBelow`` by ``hideUnchangedRegionsRevealLineCount``.  So §4.3's
##   drag and §4.2's click-to-expand are both Monaco's, and this module writes
##   neither.
## - ``div.center`` — a band reading "N hidden lines", with an unfold link that
##   reveals the whole region (both directions at once).
##
## Three things it does not have, and this module supplies:
##
## 1. **A visible affordance.**  The handles are ``background-color:
##    transparent`` until ``:hover`` — measured in
##    ``editor.main.css``.  A gesture nobody can see is not a feature, so the
##    stylesheet paints them (``styles/components/unified_diff.styl``) and this
##    module gives them the title text that says what they do and how much they
##    are hiding.
## 2. **A keyboard path.**  Only ``div.bottom`` carries ``role="button"``, and
##    neither handle is focusable, so a reader without a mouse cannot reach the
##    boundary at all.  This module stamps ``tabindex``, ``role`` and an
##    accessible name onto both, and handles Enter / Space / Shift+Enter.
## 3. **A context menu**, offering more lines and the whole file in that
##    direction — the owner's description of this milestone.  Monaco has no
##    menu on the boundary at all.
##
## How it reaches the region
## -------------------------
## Monaco exposes no public API for its unchanged regions: ``IDiffEditor`` has
## neither the regions nor a per-region command.  The widget class
## (``DiffEditorWidget``, which ``monaco.editor.createDiffEditor`` returns —
## the standalone editor *extends* it) does have them, under names the minifier
## preserves because they are property names: ``_diffModel.get()
## .unchangedRegions.get()`` yields objects carrying ``lineCount``,
## ``visibleLineCountTop`` / ``…Bottom`` and ``showMoreAbove`` /
## ``showMoreBelow`` / ``showAll``.
##
## Every access below is guarded and returns a neutral answer if the shape is
## not there, so a Monaco upgrade that renames them degrades to "Monaco's own
## drag and click still work, ours do not appear" rather than to a broken tab.
## ``deepreview-gui.spec.ts`` asserts the menu and the keyboard path against
## the running product, which is what makes such an upgrade fail loudly.

import ui_imports

import ../viewmodel/viewmodels/diff_expansion_menu

export DiffExpandDirection

const
  ExpansionBoundaryClass* = "ct-diff-expand-boundary"
    ## Stamped on each of Monaco's two drag handles, so the stylesheet can
    ## paint an affordance on them without reaching into Monaco's own class
    ## names from CSS that would then silently stop matching on an upgrade.
  ExpansionMenuClass* = "ct-diff-expand-menu"
  ExpansionMenuItemClass* = "ct-diff-expand-menu-item"
  ExpansionDirectionAttr* = "data-ct-expand"
  ExpansionRegionAttr* = "data-ct-region"
  ExpansionHiddenAttr* = "data-ct-hidden"

# ---------------------------------------------------------------------------
# Monaco FFI — the unchanged regions
# ---------------------------------------------------------------------------

proc dxRegions(diffEditor: js): js {.importjs: """
  (function(e) {
    try {
      var model = e && e._diffModel && e._diffModel.get && e._diffModel.get();
      var regions = model && model.unchangedRegions && model.unchangedRegions.get();
      return Array.isArray(regions) ? regions : [];
    } catch (err) { return []; }
  })(#)""".}
  ## Monaco's own unchanged regions, in line order, or an empty array.

proc dxRegionCount(regions: js): int
  {.importjs: "(#).length".}

proc dxRegionHidden(regions: js, index: int): int {.importjs: """
  (function(rs, i) {
    var r = rs[i];
    if (!r) { return 0; }
    try {
      return r.lineCount - r.visibleLineCountTop.get() - r.visibleLineCountBottom.get();
    } catch (err) { return 0; }
  })(#, #)""".}
  ## Lines this region is still hiding.  Both handles draw from the same pool —
  ## revealing at the top leaves fewer to reveal at the bottom — so one number
  ## answers for both directions.

proc dxShowMore(regions: js, index: int, above: bool, lines: int) {.importjs: """
  (function(rs, i, above, lines) {
    var r = rs[i];
    if (!r || lines <= 0) { return; }
    try {
      if (above) { r.showMoreAbove(lines, undefined); }
      else { r.showMoreBelow(lines, undefined); }
    } catch (err) { /* a renamed internal: Monaco's own gestures still work */ }
  })(#, #, #, #)""".}
  ## Reveal ``lines`` more at one end of the region.  Monaco clamps to what is
  ## actually left, so "the whole file in this direction" is simply a large
  ## enough count and needs no separate call.

# ---------------------------------------------------------------------------
# DOM helpers
# ---------------------------------------------------------------------------

proc dxBoundaries(hostId: cstring): js {.importjs: """
  (function(id) {
    var host = document.getElementById(id);
    if (!host) { return []; }
    // The MODIFIED editor only.  An inline diff lays the original editor out
    // as a narrow strip and gives it its own (hidden) copy of every boundary
    // widget; counting those would put the widgets and the regions out of step
    // and a menu would then act on the wrong region.
    var editor = host.querySelector('.monaco-editor.modified-in-monaco-diff-editor');
    if (!editor) { return []; }
    var widgets = Array.prototype.slice.call(
      editor.querySelectorAll('.diff-hidden-lines'));
    // In line order.  Monaco creates the widgets as view zones, whose DOM
    // order is insertion order and not document order, so they are sorted by
    // where they actually sit — which IS the order `unchangedRegions` is in.
    widgets.sort(function(a, b) {
      return a.getBoundingClientRect().top - b.getBoundingClientRect().top;
    });
    var handles = [];
    for (var i = 0; i < widgets.length; i++) {
      var top = widgets[i].querySelector(':scope > .top');
      var bottom = widgets[i].querySelector(':scope > .bottom');
      if (top) { handles.push([top, i, true]); }
      if (bottom) { handles.push([bottom, i, false]); }
    }
    return handles;
  })(#)""".}
  ## Every boundary handle of the tab, as ``[element, regionIndex, isTop]``.

proc dxHandleElement(handle: js): Node {.importjs: "(#)[0]".}
proc dxHandleRegion(handle: js): int {.importjs: "(#)[1]".}
proc dxHandleIsTop(handle: js): bool {.importjs: "(#)[2]".}
proc dxLen(list: js): int {.importjs: "(#).length".}
proc dxAt(list: js, index: int): js {.importjs: "(#)[#]".}

proc dxSetAttr(node: Node, name, value: cstring)
  {.importjs: "#.setAttribute(#, #)".}

proc dxAddClass(node: Node, name: cstring)
  {.importjs: "#.classList.add(#)".}
  ## Added to Monaco's own classes rather than replacing them: ``top`` and
  ## ``bottom`` are what its stylesheet and its ``canMoveTop`` / ``dragging``
  ## toggles are keyed on, and replacing them would disable the drag this
  ## milestone is built on.

proc dxFirstChild(node: Node): Node {.importjs: "#.firstChild".}

proc dxGetAttr(node: Node, name: cstring): cstring
  {.importjs: "(#.getAttribute(#) || '')".}

proc dxAttrInt(node: Node, name: cstring): int
  {.importjs: """
  (function(n, a) {
    var v = parseInt(n.getAttribute(a) || '', 10);
    return isNaN(v) ? -1 : v;
  })(#, #)""".}

proc dxObserve(hostId: cstring, onChange: proc()) {.importjs: """
  (function(id, cb) {
    var host = document.getElementById(id);
    if (!host || host.__ctExpandObserver) { return; }
    // Monaco re-creates the boundary widgets whenever the diff or the hidden
    // areas change, which is exactly when a reader expands one — so the
    // stamping has to be re-applied rather than done once.  Scoped to this
    // tab's host and cheap: the callback only reads attributes it may have to
    // set.
    var observer = new MutationObserver(function() { cb(); });
    observer.observe(host, { childList: true, subtree: true });
    host.__ctExpandObserver = observer;
  })(#, #)""".}

proc dxHasOpenMenu(): bool
  {.importjs: "!!document.querySelector('.ct-diff-expand-menu')".}

proc dxCloseMenus() {.importjs: """
  (function() {
    var menus = document.querySelectorAll('.ct-diff-expand-menu');
    for (var i = 0; i < menus.length; i++) {
      if (menus[i].parentNode) { menus[i].parentNode.removeChild(menus[i]); }
    }
  })()""".}

proc dxAppendToBody(node: Node) {.importjs: "document.body.appendChild(#)".}

proc dxPlaceMenu(menu: Node, x, y: int) {.importjs: """
  (function(menu, x, y) {
    menu.style.position = 'fixed';
    menu.style.left = x + 'px';
    menu.style.top = y + 'px';
    // Keep it on screen: a boundary near the bottom of a tall tab would
    // otherwise open its menu below the window.
    var rect = menu.getBoundingClientRect();
    if (rect.bottom > window.innerHeight) {
      menu.style.top = Math.max(0, y - rect.height) + 'px';
    }
    if (rect.right > window.innerWidth) {
      menu.style.left = Math.max(0, x - rect.width) + 'px';
    }
  })(#, #, #)""".}

proc dxEventX(e: js): int {.importjs: "(#).clientX".}
proc dxEventY(e: js): int {.importjs: "(#).clientY".}
proc dxEventKey(e: js): cstring {.importjs: "(#).key || ''".}
proc dxEventShift(e: js): bool {.importjs: "!!(#).shiftKey".}
proc dxPreventDefault(e: js) {.importjs: "(#).preventDefault()".}
proc dxStopPropagation(e: js) {.importjs: "(#).stopPropagation()".}
proc dxElementRectBottom(node: Node): int
  {.importjs: "Math.round(#.getBoundingClientRect().bottom)".}
proc dxElementRectLeft(node: Node): int
  {.importjs: "Math.round(#.getBoundingClientRect().left)".}
proc dxFocus(node: Node) {.importjs: "#.focus()".}
proc dxAddListener(node: Node, event: cstring, handler: proc(e: js))
  {.importjs: "#.addEventListener(#, #)".}
proc dxMarkBound(node: Node): bool {.importjs: """
  (function(n) {
    if (n.__ctExpandBound) { return false; }
    n.__ctExpandBound = true;
    return true;
  })(#)""".}

# ---------------------------------------------------------------------------
# The gesture
# ---------------------------------------------------------------------------

proc directionOf(isTop: bool): DiffExpandDirection =
  ## Monaco's ``.top`` handle reveals the region's topmost hidden lines, which
  ## is what "show more above" means to a reader looking at the boundary — and
  ## is how Monaco's own tooltip words it.
  if isTop: dedAbove else: dedBelow

proc refreshExpansionAffordances*(diffEditor: js; hostId: string)

proc menuItem(command: DiffExpandCommand; regions: js;
              regionIndex: int): Node =
  ## One row of the boundary's menu.
  ##
  ## A proc rather than the body of a loop, for the reason
  ## ``bindBoundaryHandlers`` gives: a ``let`` in a ``for`` body is one slot
  ## shared by every closure the loop builds, so every item built inside a loop
  ## would share one ``lines`` and act as whichever command was built last.
  ## Measured: "Expand 10 lines above" revealed all twelve.
  result = document.createElement(cstring"button")
  result.setAttribute(cstring"class", cstring(ExpansionMenuItemClass))
  result.setAttribute(cstring"role", cstring"menuitem")
  result.setAttribute(cstring"type", cstring"button")
  result.setAttribute(cstring"data-ct-lines", cstring($command.lines))
  if command.wholeFile:
    result.setAttribute(cstring"data-ct-whole-file", cstring"true")
  result.appendChild(document.createTextNode(cstring(command.label)))
  let lines = command.lines
  let above = command.direction == dedAbove
  result.addEventListener(cstring"click", proc(e: Event) =
    dxShowMore(regions, regionIndex, above, lines)
    dxCloseMenus())

proc openBoundaryMenu(regions: js; regionIndex: int;
                      direction: DiffExpandDirection; x, y: int) =
  ## The owner's context menu: expand by the increment, by a larger step, or to
  ## the file's edge in that direction.
  ##
  ## Built fresh on every open, from ``expansionMenuCommands``, so the offers
  ## always describe the region's *current* remaining lines rather than what it
  ## was hiding when the tab loaded.
  dxCloseMenus()
  let hidden = dxRegionHidden(regions, regionIndex)
  let commands = expansionMenuCommands(direction, hidden)
  if commands.len == 0:
    return
  let menu = document.createElement(cstring"div")
  menu.setAttribute(cstring"class", cstring(ExpansionMenuClass))
  menu.setAttribute(cstring"role", cstring"menu")
  menu.setAttribute(cstring(ExpansionDirectionAttr),
                    cstring(directionWord(direction)))
  for command in commands:
    menu.appendChild(menuItem(command, regions, regionIndex))
  dxAppendToBody(menu)
  dxPlaceMenu(menu, x, y)
  # The first item takes focus so the menu is operable by the same keyboard
  # that opened it; Escape and any click elsewhere close it.
  dxFocus(dxFirstChild(menu))
  dxAddListener(menu, cstring"keydown", proc(e: js) =
    if $dxEventKey(e) == "Escape":
      dxCloseMenus())

proc bindBoundaryHandlers(element: Node; diffEditor: js; hostId: string) =
  ## Attach one handle's keyboard, menu and press handlers.
  ##
  ## A separate proc, and not the body of the loop in
  ## ``refreshExpansionAffordances``, because Nim builds one closure
  ## environment per enclosing *routine* and not per loop iteration: a ``let``
  ## in the loop body is a single slot, so every closure built inside the loop
  ## shares ONE set of variables, holding whatever the last iteration left in
  ## them.  Measured, not guessed — right-clicking the handle that reveals
  ## lines above opened the menu for the one that reveals lines below, because
  ## ``.bottom`` is stamped after ``.top``.  A proc call gives each handle its
  ## own frame, which is the only thing that fixes it.  (This is Nim's
  ## semantics, not the JavaScript backend's: ``nim c`` behaves the same way.
  ## See ``.agents/codebase-insights.txt``.)
  ##
  ## Nothing about the region is captured either: the index and the direction
  ## are read back from the element's own attributes, and the region array from
  ## the editor, at the moment the event fires.  Monaco recreates its region
  ## objects whenever the diff is recomputed, and a handler holding the
  ## previous set would expand a region that no longer exists.
  proc regionOf(): (js, int) =
    let regions = dxRegions(diffEditor)
    let index = dxAttrInt(element, cstring(ExpansionRegionAttr))
    if index < 0 or index >= dxRegionCount(regions):
      return (regions, -1)
    (regions, index)

  proc directionOfElement(): DiffExpandDirection =
    if $dxGetAttr(element, cstring(ExpansionDirectionAttr)) ==
       directionWord(dedAbove): dedAbove
    else: dedBelow

  element.dxAddListener(cstring"keydown", proc(e: js) =
    let key = $dxEventKey(e)
    let (regions, index) = regionOf()
    if index < 0:
      return
    case key
    of "Enter", " ", "Spacebar":
      dxPreventDefault(e)
      dxStopPropagation(e)
      # Shift takes everything left in that direction, which is the same offer
      # the menu's last item makes — the keyboard equivalent of "expand the
      # whole file this way".
      let lines =
        if dxEventShift(e): dxRegionHidden(regions, index)
        else: DiffExpandStep
      dxShowMore(regions, index, directionOfElement() == dedAbove, lines)
      refreshExpansionAffordances(diffEditor, hostId)
    of "ContextMenu", "F10":
      if key == "F10" and not dxEventShift(e):
        return
      dxPreventDefault(e)
      dxStopPropagation(e)
      openBoundaryMenu(regions, index, directionOfElement(),
                       dxElementRectLeft(element), dxElementRectBottom(element))
    of "Escape":
      dxCloseMenus()
    else:
      discard)

  element.dxAddListener(cstring"contextmenu", proc(e: js) =
    # Monaco's editor context menu would otherwise open over the boundary and
    # offer nothing about it.
    dxPreventDefault(e)
    dxStopPropagation(e)
    let (regions, index) = regionOf()
    if index < 0:
      return
    openBoundaryMenu(regions, index, directionOfElement(),
                     dxEventX(e), dxEventY(e)))

  # A press on the handle is Monaco's own click-to-expand; the only thing to do
  # here is dismiss a menu that is still open, and give the handle focus so the
  # keyboard path continues from where the mouse left off.
  element.dxAddListener(cstring"mousedown", proc(e: js) =
    if dxHasOpenMenu():
      dxCloseMenus()
    dxFocus(element))

proc refreshExpansionAffordances*(diffEditor: js; hostId: string) =
  ## Give every boundary handle its affordance, its name and its handlers.
  ##
  ## Idempotent, and re-run whenever Monaco re-creates the widgets: the
  ## attributes are set unconditionally (they carry the *current* hidden count,
  ## which changes as a reader expands) and the listeners are attached once,
  ## guarded by a flag on the element.
  if diffEditor.isNil:
    return
  let regions = dxRegions(diffEditor)
  let handleList = dxBoundaries(cstring(hostId))
  let regionCount = dxRegionCount(regions)
  for i in 0 ..< dxLen(handleList):
    let handle = dxAt(handleList, i)
    let element = dxHandleElement(handle)
    let regionIndex = dxHandleRegion(handle)
    if regionIndex < 0 or regionIndex >= regionCount:
      # The widgets and the regions disagree — a Monaco upgrade, or a widget
      # caught mid-rebuild.  Acting on a guessed index would expand the wrong
      # place, so nothing is stamped and Monaco's own drag stays untouched.
      continue
    let direction = directionOf(dxHandleIsTop(handle))
    let hidden = dxRegionHidden(regions, regionIndex)
    element.dxAddClass(cstring(ExpansionBoundaryClass))
    element.dxSetAttr(cstring"role", cstring"button")
    element.dxSetAttr(cstring"tabindex", cstring"0")
    element.dxSetAttr(cstring"aria-label",
                      cstring(expansionActionLabel(direction)))
    element.dxSetAttr(cstring"title",
                      cstring(expansionBoundaryTitle(direction, hidden)))
    element.dxSetAttr(cstring(ExpansionDirectionAttr),
                      cstring(directionWord(direction)))
    element.dxSetAttr(cstring(ExpansionRegionAttr), cstring($regionIndex))
    element.dxSetAttr(cstring(ExpansionHiddenAttr), cstring($hidden))

    if not element.dxMarkBound():
      continue
    bindBoundaryHandlers(element, diffEditor, hostId)

proc installExpansionGestures*(diffEditor: js; hostId: string) =
  ## Wire the tab up once.  Monaco rebuilds its boundary widgets on every diff
  ## and every reveal, so the stamping is re-run from a ``MutationObserver``
  ## scoped to this tab's host rather than attempted once at mount.
  if diffEditor.isNil:
    return
  refreshExpansionAffordances(diffEditor, hostId)
  dxObserve(cstring(hostId), proc() =
    refreshExpansionAffordances(diffEditor, hostId))
