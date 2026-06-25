## IsoNim DOM view for the VCS / DeepReview changed-files panel.
##
## Commit graph
## ------------
## ``renderCommitGraph`` renders each commit as an accordion row.  The left
## side is a grid of ``VCSGraphCell`` lane columns (vertical lines + dots
## drawn with CSS ``::before`` / ``::after`` pseudo-elements using
## ``currentColor``).  The right side shows the abbreviated commit message and
## a relative timestamp.
##
## Accordion expand / collapse
## ---------------------------
## Clicking a commit header either selects + expands it (loading ``changedFiles``
## inline under the row) or, if it was already selected, collapses it (setting
## ``selectedCommitIndex`` to -1).  Only one commit is expanded at a time.
##
## Infinite scroll
## ---------------
## A sentinel ``<div>`` is appended after the last commit row.  On JS targets
## an ``IntersectionObserver`` watches the sentinel; when it becomes visible
## (user has scrolled near the bottom) ``callbacks.onLoadMoreCommits`` fires to
## fetch the next page.  A "Loading…" row is shown while ``vm.loadingMore`` is
## true.

import std/[strformat, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/vcs_vm

const VCSContainerClass* = "component-container vcs-container"
const VCSNoRepoClass* = "vcs-no-repo"
const VCSNoFilesText* = "No changed files"
const VCSNoDiffText* = "No working tree changes."

## Branch lane colour palette — cycled by ``VCSGraphCell.colorIdx``.
## Values are chosen to harmonise with the CodeTracer dark-theme design system
## (CT_SECONDARY_BLUE, VALUE_RESULT_COLOR, etc.) while giving enough contrast
## to distinguish adjacent lanes.
const branchColors* = [
  "#93c5fd",  ## colors-ui-icon-information-primary (blue-300)
  "#FB923C",  ## orange    — aligns with VALUE_RESULT_COLOR
  "#4ADE80",  ## green
  "#F472B6",  ## pink
  "#38BDF8",  ## sky blue
  "#A78BFA",  ## purple    — aligns with VALUE_NAME_COLOR
]

type
  VCSCallbacks* = object
    onToggleBranchDropdown*: proc()
    onCheckoutBranch*: proc(branch: string)
    onSelectCommit*: proc(index: int)
    ## Toggle the accordion for commit at ``index``.
    ## Collapses if already selected; selects + loads files otherwise.
    ## Toggle accordion for commit at ``index``.
    ## ``ctrl`` = Ctrl/Meta held → toggle individual without clearing others.
    ## ``shift`` = Shift held → select range from last-clicked to ``index``.
    ## Neither → exclusive select (clears others) or collapse if already sole.
    onToggleCommitExpand*: proc(index: int; ctrl: bool; shift: bool)
    ## Called when the scroll sentinel becomes visible so the next page of
    ## commits can be appended.
    onLoadMoreCommits*: proc()
    onSelectFile*: proc(index: int; path: string)
    onToggleUnifiedDiff*: proc()
    onRefresh*: proc()
    onSelectHunk*: proc(fileIdx, hunkIdx: int; shiftKey, ctrlKey: bool)
    onCopySelectedHunks*: proc()
    onStageSelectedHunks*: proc()
    onClearSelectedHunks*: proc()

# ---------------------------------------------------------------------------
# CSS class helpers
# ---------------------------------------------------------------------------

proc statusClass*(status: string): string =
  case status
  of "A", "added": "vcs-status-added"
  of "D", "deleted": "vcs-status-deleted"
  of "M", "modified": "vcs-status-modified"
  else: "vcs-status-other"

proc diffStatusClass*(status: string): string =
  case status
  of "A", "added": "deepreview-diff-status deepreview-diff-added"
  of "D", "deleted": "deepreview-diff-status deepreview-diff-deleted"
  of "M", "modified": "deepreview-diff-status deepreview-diff-modified"
  else: "deepreview-diff-status"

proc statusLabel*(status: string): string =
  case status
  of "added": "A"
  of "deleted": "D"
  of "modified": "M"
  else: status

proc accordionFileStatusClass*(status: string): string =
  ## CSS class for the coloured status letter inside an expanded accordion row.
  case status
  of "A", "added":    "vcs-accordion-file-status vcs-accordion-status-added"
  of "D", "deleted":  "vcs-accordion-file-status vcs-accordion-status-deleted"
  of "M", "modified": "vcs-accordion-file-status vcs-accordion-status-modified"
  of "C", "copied":   "vcs-accordion-file-status vcs-accordion-status-copied"
  of "R", "renamed":  "vcs-accordion-file-status vcs-accordion-status-renamed"
  else:               "vcs-accordion-file-status vcs-accordion-status-other"

proc commitHeaderClass*(selected: bool): string =
  if selected: "vcs-commit-header vcs-commit-header-selected"
  else: "vcs-commit-header"

proc fileRowClass*(selected: bool): string =
  if selected: "vcs-file-item vcs-file-selected" else: "vcs-file-item"

proc toggleButtonClass*(active: bool): string =
  if active: "vcs-toggle-button vcs-toggle-active" else: "vcs-toggle-button"

proc hunkClass*(selected: bool): string =
  if selected: "deepreview-unified-hunk hunk-selected"
  else: "deepreview-unified-hunk"

proc diffLineClass*(lineType: string): string =
  case lineType
  of "added": "deepreview-unified-line deepreview-unified-line-added"
  of "removed": "deepreview-unified-line deepreview-unified-line-removed"
  else: "deepreview-unified-line deepreview-unified-line-context"

proc fileStatsText*(additions, deletions: int): string =
  if additions == 0 and deletions == 0: ""
  else: "+" & $additions & " -" & $deletions

proc hunkHeaderText*(hunk: VCSHunkRow): string =
  fmt"@@ -{hunk.oldStart},{hunk.oldCount} +{hunk.newStart},{hunk.newCount} @@"

proc hunkToolbarText*(count: int): string =
  $count & " hunk" & (if count == 1: "" else: "s") & " selected"

proc abbreviateRelTime*(t: string): string =
  ## Convert a git ``%cr`` relative-time string to a compact abbreviated form.
  ##
  ## Git produces strings like "3 seconds ago", "5 minutes ago", "2 hours ago",
  ## "4 days ago", "2 weeks ago", "3 months ago", "1 year ago".
  ## We strip " ago", split on the first space, parse the number, and map the
  ## unit word to its abbreviation:  s  m  h  d  w  mo  y
  var s = t
  const ago = " ago"
  if s.len > ago.len and s[s.len - ago.len .. ^1] == ago:
    s = s[0 .. s.len - ago.len - 1]
  let sp = s.find(' ')
  if sp < 0:
    return s   # "yesterday", "today", etc. — return as-is
  let numStr = s[0 ..< sp]
  let unit   = s[sp + 1 .. ^1]
  let abbr =
    if unit.startsWith("second"):   "s"
    elif unit.startsWith("minute"): "m"
    elif unit.startsWith("hour"):   "h"
    elif unit.startsWith("day"):    "d"
    elif unit.startsWith("week"):   "w"
    elif unit.startsWith("month"):  "mo"
    elif unit.startsWith("year"):   "y"
    else: unit
  numStr & abbr

proc changedFilesHeaderText(vm: VCSVM): string =
  if vm.deepReviewMode.val:
    " (" & $vm.fileCount.val & " files)"
  elif vm.selectedCommitIndices.val.len == 1:
    let idx = vm.selectedCommitIndices.val[0]
    if idx >= 0 and idx < vm.commits.val.len:
      " (" & vm.commits.val[idx].hash & ")"
    else: ""
  else:
    ""

# ---------------------------------------------------------------------------
# Callback dispatch helpers
# ---------------------------------------------------------------------------

proc invokeToggleBranchDropdown(vm: VCSVM; callbacks: VCSCallbacks) =
  if callbacks.onToggleBranchDropdown != nil:
    callbacks.onToggleBranchDropdown()
  else:
    vm.branchDropdownOpen.val = not vm.branchDropdownOpen.val

proc invokeCheckoutBranch(callbacks: VCSCallbacks; branch: string) =
  if callbacks.onCheckoutBranch != nil:
    callbacks.onCheckoutBranch(branch)

proc invokeSelectCommit(vm: VCSVM; callbacks: VCSCallbacks; index: int) =
  if callbacks.onSelectCommit != nil:
    callbacks.onSelectCommit(index)
  else:
    vm.selectedCommitIndices.val = @[index]

proc invokeToggleCommitExpand(vm: VCSVM; callbacks: VCSCallbacks;
                               index: int; ctrl: bool; shift: bool) =
  ## Toggle accordion for the given commit index.
  ## Falls back to simple exclusive-select logic when no callback is registered
  ## (unit tests / mock renderer), ignoring modifier keys in that case.
  if callbacks.onToggleCommitExpand != nil:
    callbacks.onToggleCommitExpand(index, ctrl, shift)
  else:
    let cur = vm.selectedCommitIndices.val
    if cur == @[index]:
      vm.selectedCommitIndices.val = @[]
    else:
      vm.selectedCommitIndices.val = @[index]

proc invokeSelectFile(callbacks: VCSCallbacks; index: int; path: string) =
  if callbacks.onSelectFile != nil:
    callbacks.onSelectFile(index, path)

proc invokeToggleUnifiedDiff(vm: VCSVM; callbacks: VCSCallbacks) =
  if callbacks.onToggleUnifiedDiff != nil:
    callbacks.onToggleUnifiedDiff()
  else:
    vm.unifiedDiffActive.val = not vm.unifiedDiffActive.val

proc invokeRefresh(callbacks: VCSCallbacks) =
  if callbacks.onRefresh != nil:
    callbacks.onRefresh()

proc invokeSelectHunk(callbacks: VCSCallbacks; fileIdx, hunkIdx: int;
                      shiftKey, ctrlKey: bool) =
  if callbacks.onSelectHunk != nil:
    callbacks.onSelectHunk(fileIdx, hunkIdx, shiftKey, ctrlKey)

# ---------------------------------------------------------------------------
# IntersectionObserver sentinel (JS only)
# ---------------------------------------------------------------------------

when defined(js):
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc shiftKey(ev: isonim_dom.Event): bool {.importjs: "!!#.shiftKey".}
  proc ctrlOrMetaKey(ev: isonim_dom.Event): bool {.importjs: "(function(ev) { return !!(ev.ctrlKey || ev.metaKey); })(#)".}

  ## Attach an IntersectionObserver to ``el``.  When the element becomes
  ## visible in its scroll container (threshold 0.1), ``cb`` is invoked once.
  ## The observer is persistent so that successive scroll-to-bottom events
  ## keep loading pages automatically.
  proc setupScrollSentinel(el: isonim_dom.Element; cb: proc())
    {.importjs: """(function(el, cb) {
      if (typeof IntersectionObserver === 'undefined') return;
      var io = new IntersectionObserver(function(entries) {
        if (entries[0] && entries[0].isIntersecting) { cb(); }
      }, { threshold: 0.1 });
      io.observe(el);
    })(#, #)""".}

proc attachScrollSentinel(r: MockRenderer; sentinel: MockNode;
                          callbacks: VCSCallbacks) =
  ## No-op for the mock renderer (used in unit tests).
  discard

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  r.appendChild(host, child)

when defined(js):
  proc attachScrollSentinel(r: WebRenderer; sentinel: isonim_dom.Element;
                            callbacks: VCSCallbacks) =
    if callbacks.onLoadMoreCommits == nil:
      return
    setupScrollSentinel(sentinel, callbacks.onLoadMoreCommits)

  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    r.appendChild(host, child)

# ---------------------------------------------------------------------------
# Hunk-click attachment (needs native event for Shift/Ctrl detection)
# ---------------------------------------------------------------------------

proc attachHunkClick(r: MockRenderer; header: MockNode; callbacks: VCSCallbacks;
                     fileIdx, hunkIdx: int) =
  r.addEventListener(header, "click", proc() =
    callbacks.invokeSelectHunk(fileIdx, hunkIdx, false, false))

when defined(js):
  proc attachHunkClick(r: WebRenderer; header: isonim_dom.Element;
                       callbacks: VCSCallbacks; fileIdx, hunkIdx: int) =
    isonim_dom.addEventListener(isonim_dom.Node(header), cstring"click",
      proc(ev: isonim_dom.Event) =
        callbacks.invokeSelectHunk(fileIdx, hunkIdx, ev.shiftKey(), ev.ctrlOrMetaKey())
        ev.preventDefault())

proc renderBranchOption[R](r: R; vm: VCSVM; callbacks: VCSCallbacks;
                           branch: string): auto =
  let branchName = branch
  ui(r):
    tdiv(class = "vcs-branch-option",
         onclick = proc() =
           callbacks.invokeCheckoutBranch(branchName)):
      if branchName == vm.currentBranch.val:
        span(class = "vcs-branch-active-marker"):
          text "* "
      text branchName

# ---------------------------------------------------------------------------
# Commit header click with modifier-key detection
# ---------------------------------------------------------------------------
#
# A plain ``onclick = proc()`` in the DSL cannot read Shift / Ctrl state.
# These procs attach a native click listener so modifier keys are passed
# through to the toggle callback, enabling ctrl+click (toggle one) and
# shift+click (select range) multi-select.

proc attachCommitClick(r: MockRenderer; header: MockNode;
                       vm: VCSVM; callbacks: VCSCallbacks; index: int) =
  r.addEventListener(header, "click", proc() =
    vm.invokeToggleCommitExpand(callbacks, index, false, false))

when defined(js):
  proc attachCommitClick(r: WebRenderer; header: isonim_dom.Element;
                         vm: VCSVM; callbacks: VCSCallbacks; index: int) =
    isonim_dom.addEventListener(isonim_dom.Node(header), cstring"click",
      proc(ev: isonim_dom.Event) =
        vm.invokeToggleCommitExpand(callbacks, index,
                                    ev.ctrlOrMetaKey(), ev.shiftKey()))

# ---------------------------------------------------------------------------
# Commit-detail tooltip (JS only)
# ---------------------------------------------------------------------------
#
# A single fixed-position tooltip div with id="vcs-commit-tooltip" is
# rendered once in renderCommitGraph.  Hover events on each commit header
# populate and reposition it via showVCSTooltip / hideVCSTooltip.
# position:fixed lets it escape the panel's overflow:hidden so it can
# appear to the right of the panel boundary.

when defined(js):
  ## Populate and show the commit-detail tooltip next to ``anchorEl``.
  ## The tooltip element is found by its well-known id in the current document.
  proc showVCSTooltip(hash, fullHash, author, relTime, dotColor: cstring;
                       anchorEl: isonim_dom.Element)
    {.importjs: """(function(h, fh, a, t, c, el) {
      var tip = document.getElementById('vcs-commit-tooltip');
      if (!tip) return;
      var rect = el.getBoundingClientRect();
      tip.style.top  = rect.top + 'px';
      tip.style.left = (rect.right + 8) + 'px';
      var dot = tip.querySelector('.vcs-tip-dot');
      if (dot) dot.style.background = c;
      var hs = tip.querySelector('.vcs-tip-hash');
      if (hs) hs.textContent = h;
      var dt = tip.querySelector('.vcs-tip-date');
      if (dt) dt.textContent = t;
      var cm = tip.querySelector('.vcs-tip-commit');
      if (cm) cm.textContent = fh;
      var au = tip.querySelector('.vcs-tip-author');
      if (au) au.textContent = a;
      tip.style.display = 'block';
    })(#, #, #, #, #, #)""".}

  ## Hide the commit-detail tooltip.
  proc hideVCSTooltip()
    {.importjs: """(function() {
      var tip = document.getElementById('vcs-commit-tooltip');
      if (tip) tip.style.display = 'none';
    })()""".}

  ## Attach hover handlers that drive the commit-detail tooltip.
  proc attachCommitTooltip(r: WebRenderer; header: isonim_dom.Element;
                            hash, fullHash, author, relTime, dotColor: string) =
    let h  = cstring(hash)
    let fh = cstring(fullHash)
    let a  = cstring(author)
    let t  = cstring(relTime)
    let c  = cstring(dotColor)
    isonim_dom.addEventListener(isonim_dom.Node(header), cstring"mouseenter",
      proc(ev: isonim_dom.Event) = showVCSTooltip(h, fh, a, t, c, header))
    isonim_dom.addEventListener(isonim_dom.Node(header), cstring"mouseleave",
      proc(ev: isonim_dom.Event) = hideVCSTooltip())

proc attachCommitTooltip(r: MockRenderer; header: MockNode;
                          hash, fullHash, author, relTime, dotColor: string) =
  ## No-op in the mock renderer.
  discard

# ---------------------------------------------------------------------------
# Branch picker
# ---------------------------------------------------------------------------

const chevronDownSvg = """<svg width="9" height="5" viewBox="0 0 9 5" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M0.353516 0.353577L4.35352 4.35358L8.35352 0.353576" stroke="#DDDDDD" stroke-linejoin="round"/></svg>"""
const chevronUpSvg  = """<svg width="9" height="5" viewBox="0 0 9 5" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8.35352 4.35358L4.35352 0.353577L0.353516 4.35358" stroke="#DDDDDD" stroke-linejoin="round"/></svg>"""

proc renderBranchPicker[R](r: R; vm: VCSVM; callbacks: VCSCallbacks): auto =
  var chevronHost: typeof(r.createElement("span"))
  var dropdown: typeof(r.createElement("div"))
  let isOpen = vm.branchDropdownOpen.val
  let chevronSvg = if isOpen: chevronUpSvg else: chevronDownSvg
  let panel = ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current",
           onclick = proc() = vm.invokeToggleBranchDropdown(callbacks)):
        span(ref = chevronHost, class = "vcs-branch-chevron")
        span(class = "vcs-branch-name"):
          text vm.currentBranch.val
      if isOpen:
        tdiv(ref = dropdown, class = "vcs-branch-dropdown")
  r.setInnerHtml(chevronHost, chevronSvg)
  if isOpen:
    for branch in vm.branches.val:
      r.appendRenderedChild(dropdown, renderBranchOption(r, vm, callbacks, branch))
  panel

proc renderHeader[R](r: R; vm: VCSVM): auto =
  ui(r):
    tdiv(class = "vcs-branch-picker"):
      tdiv(class = "vcs-branch-current"):
        span(class = "vcs-branch-icon"):
          text vm.headerIcon.val
        span(class = "vcs-branch-name"):
          text vm.headerTitle.val

proc renderNoRepo[R](r: R; vm: VCSVM): auto =
  ui(r):
    tdiv(class = VCSNoRepoClass):
      tdiv(class = "vcs-no-repo-icon"):
        text vm.headerIcon.val
      tdiv(class = "vcs-no-repo-message"):
        text vm.errorMessage.val

# ---------------------------------------------------------------------------
# Commit graph: lane cells, accordion rows, infinite-scroll sentinel
# ---------------------------------------------------------------------------

proc renderGraphLanes[R](r: R; cells: seq[VCSGraphCell];
                          dotLane: int;
                          connectors: seq[VCSGraphConnector];
                          isFirst: bool): auto =
  ## Render the branch-lane graph column for one commit row.
  ##
  ## Lane slots (``div.vcs-gc-slot``, 0.5em wide):
  ##   • ``div.vcs-gc-line``          — full-height bar (gckLine and gckDot).
  ##   • ``div.vcs-gc-line-bot``      — bottom-half bar only; used on the first
  ##                                   (newest) commit so no line appears above it.
  ##   • ``div.vcs-gc-dot``           — filled circle centred on the row (gckDot).
  ##   • ``div.vcs-gc-dot-hollow``    — ring-only circle; used when the commit has
  ##                                   at least one connector (branch-out or merge-in).
  ##
  ## Right-angle connectors (``div.vcs-gc-conn-r`` / ``vcs-gc-conn-l``) are
  ## absolutely positioned in the container and draw a border-based right-angle
  ## curve — right+down or left+down — matching the designer reference style.
  ##
  ## Uses ``if/elif`` not ``case``: IsoNim's ui macro supports ``if/elif``
  ## but may silently mishandle ``case`` inside DSL blocks.
  # Lane slots are 0.5em wide (CSS: flex: 0 0 0.5em).
  # The vertical lane line inside each slot is positioned by CSS as:
  #   left: calc(50% - 0.05em);  width: 0.1em
  # So within a 0.5em slot:
  #   line left edge  = 0.20em  (= 0.25em - 0.05em)
  #   line right edge = 0.30em  (= 0.25em + 0.05em)
  #
  # For lane N (counting from 0), measured from the graph left edge:
  #   line left edge  = N * 0.5em + 0.20em
  #   line right edge = N * 0.5em + 0.30em
  #
  # A connector spanning leftLane→rightLane must start at the left edge of
  # the leftmost line and end at the right edge of the rightmost line:
  #   left  = calc(leftLane  * 0.5em + 0.2em)
  #   width = calc(diffLanes * 0.5em + 0.1em)
  #
  # The 0.1em width absorbs the connector border (box-sizing: border-box)
  # so the border-right / border-left lands exactly on the target lane line.
  # Commits with branch-outs or merge-ins get a hollow ring dot; regular
  # commits with no connectors get the solid filled dot.
  let isHollowDot = connectors.len > 0
  ui(r):
    tdiv(class = "vcs-commit-graph"):
      for cell in cells:
        let color = branchColors[cell.colorIdx mod branchColors.len]
        if cell.kind == gckDot:
          if isHollowDot:
            # Hollow ring: border carries the branch colour; background (centre)
            # is left transparent so the dark panel background shows through.
            # The inline style sets border-color; the CSS class sets border-width/bg.
            if isFirst:
              tdiv(class = "vcs-gc-slot"):
                tdiv(class = "vcs-gc-line-bot",       style = "background:" & color): discard
                tdiv(class = "vcs-gc-dot vcs-gc-dot-hollow", style = "border-color:" & color): discard
            else:
              tdiv(class = "vcs-gc-slot"):
                tdiv(class = "vcs-gc-line",           style = "background:" & color): discard
                tdiv(class = "vcs-gc-dot vcs-gc-dot-hollow", style = "border-color:" & color): discard
          else:
            # Solid filled dot for regular commits (no branch-outs or merge-ins).
            if isFirst:
              tdiv(class = "vcs-gc-slot"):
                tdiv(class = "vcs-gc-line-bot", style = "background:" & color): discard
                tdiv(class = "vcs-gc-dot",      style = "background:" & color): discard
            else:
              tdiv(class = "vcs-gc-slot"):
                tdiv(class = "vcs-gc-line", style = "background:" & color): discard
                tdiv(class = "vcs-gc-dot",  style = "background:" & color): discard
        elif cell.kind == gckLine:
          tdiv(class = "vcs-gc-slot"):
            tdiv(class = "vcs-gc-line", style = "background:" & color): discard
        else:
          tdiv(class = "vcs-gc-slot"): discard
      for conn in connectors:
        let color     = branchColors[conn.colorIdx mod branchColors.len]
        let leftLane  = min(conn.fromLane, conn.toLane)
        let diffLanes = max(conn.fromLane, conn.toLane) - leftLane
        # em-based position/size — tracks the CSS 0.5em slot width at any font size.
        let leftStr  = "calc(" & $leftLane & " * 0.5em + 0.2em)"
        let widthStr = "calc(" & $diffLanes & " * 0.5em + 0.1em)"
        let geom = "left:" & leftStr & ";width:" & widthStr & ";border-color:" & color
        if conn.isTop:
          # Top-half connector: side lane at row top curves into dot lane at centre.
          # fromLane is the side lane (converging), toLane is the dot lane.
          if conn.fromLane < conn.toLane:
            # Side lane is to the LEFT of the dot → conn-tl shape.
            tdiv(class = "vcs-gc-conn-tl", style = geom): discard
          elif conn.fromLane > conn.toLane:
            # Side lane is to the RIGHT of the dot → conn-tr shape.
            tdiv(class = "vcs-gc-conn-tr", style = geom): discard
        else:
          # Bottom-half connector: dot lane at centre curves into new branch at bottom.
          # fromLane is the dot lane, toLane is the new branch lane.
          if conn.fromLane < conn.toLane:
            tdiv(class = "vcs-gc-conn-r", style = geom): discard
          elif conn.fromLane > conn.toLane:
            tdiv(class = "vcs-gc-conn-l", style = geom): discard

proc computeContinuationCells(cells: seq[VCSGraphCell];
                               connectors: seq[VCSGraphConnector]): seq[VCSGraphCell] =
  ## Derive the lane cells that continue below this commit row.
  ## Used to render lane lines through the accordion expanded area so the
  ## graph looks continuous when a commit is expanded.
  ##
  ## Rules per slot:
  ##   gckDot / gckLine → gckLine   (lane continues past this commit)
  ##   gckEmpty + branch-out connector → gckLine (new branch just opened)
  ##   gckEmpty otherwise → gckEmpty (converging lane ended, or unused slot)
  result = newSeq[VCSGraphCell](cells.len)
  for i, cell in cells:
    if cell.kind == gckDot or cell.kind == gckLine:
      result[i] = VCSGraphCell(kind: gckLine, colorIdx: cell.colorIdx)
    else:
      for conn in connectors:
        if not conn.isTop and conn.toLane == i:
          result[i] = VCSGraphCell(kind: gckLine, colorIdx: conn.colorIdx)
          break
      # else stays gckEmpty (zero-value default)

proc renderLaneSpacer[R](r: R; cells: seq[VCSGraphCell]): auto =
  ## Render a graph-column spacer (lines only, no dot, no connectors) for one
  ## row inside the accordion expanded area.  Reuses .vcs-commit-graph /
  ## .vcs-gc-slot / .vcs-gc-line so the lane lines look identical to those
  ## in the surrounding commit header rows.
  ui(r):
    tdiv(class = "vcs-commit-graph"):
      for cell in cells:
        let color = branchColors[cell.colorIdx mod branchColors.len]
        if cell.kind == gckLine:
          tdiv(class = "vcs-gc-slot"):
            tdiv(class = "vcs-gc-line", style = "background:" & color): discard
        else:
          tdiv(class = "vcs-gc-slot"): discard

proc renderAccordionFileRow[R](r: R; callbacks: VCSCallbacks;
                               index: int; file: VCSFileRow;
                               continuationCells: seq[VCSGraphCell]): auto =
  ## One file row inside an expanded accordion entry.
  ## Layout: [lane-spacer] [status] [filename] [+N -N].
  ## Proc parameters (not loop vars) are used for closure capture so each row
  ## independently captures its own index and path.
  let rowIndex = index
  let rowPath = file.path

  var rowNode: typeof(r.createElement("div"))
  let row = ui(r):
    tdiv(ref = rowNode, class = "vcs-accordion-file",
         onclick = proc() = callbacks.invokeSelectFile(rowIndex, rowPath))

  r.appendRenderedChild(rowNode, renderLaneSpacer(r, continuationCells))

  let content = ui(r):
    tdiv(class = "vcs-accordion-file-body"):
      span(class = accordionFileStatusClass(file.status)):
        text statusLabel(file.status)
      span(class = "vcs-accordion-file-name"):
        text file.baseName
      if file.additions > 0:
        span(class = "vcs-accordion-file-adds"):
          text "+" & $file.additions
      if file.deletions > 0:
        span(class = "vcs-accordion-file-dels"):
          text "-" & $file.deletions
  r.appendRenderedChild(rowNode, content)

  row

proc renderCommitRow[R](r: R; vm: VCSVM; callbacks: VCSCallbacks;
                        index: int; commit: VCSCommitRow; isSelected: bool): auto =
  ## Render one accordion entry (header row + optional expanded body).
  ##
  ## ``index`` is a **proc parameter**, not a loop variable, so the click
  ## closure captures a guaranteed-fresh binding for every call.  This is the
  ## standard IsoNim pattern to avoid the Nim/JS closure-capture issue where
  ## all closures in a ``for`` loop share the same mutable loop counter.
  ##
  ## IMPORTANT: IsoNim's ``ui`` macro only handles built-in element keywords
  ## (``tdiv``, ``span``, ``text``, ``if``, ``for`` …).  Arbitrary proc calls
  ## that return nodes inside a ``ui`` block are silently discarded.  That is
  ## why every nested view proc here is appended via ``r.appendRenderedChild``
  ## *outside* its own ``ui`` block — exactly as in ``renderChangedFiles``,
  ## ``renderCommitGraph``, ``renderVCSPanelImpl``, etc.
  var entryNode: typeof(r.createElement("div"))
  let entry = ui(r):
    tdiv(ref = entryNode, class = "vcs-commit-entry")

  # Header: a flex row whose children are appended manually so that proc calls
  # returning nodes (renderGraphLanes, the body block) are properly added.
  # NOTE: no onclick= here — attachCommitClick wires the native event so that
  # Ctrl/Shift modifier keys are visible to the toggle callback.
  var headerNode: typeof(r.createElement("div"))
  let header = ui(r):
    tdiv(ref = headerNode, class = commitHeaderClass(isSelected))

  r.attachCommitClick(headerNode, vm, callbacks, index)

  # Graph lanes column — must be appended outside the ui block (see note above).
  r.appendRenderedChild(headerNode,
    renderGraphLanes(r, commit.graphCells, commit.dotLane,
                     commit.connectors, index == 0))

  # Commit message + relative timestamp + hover diff button.
  let commitIndex = index
  let body = ui(r):
    tdiv(class = "vcs-commit-body"):
      span(class = "vcs-commit-msg"):
        text commit.message
      span(class = "vcs-commit-time-col"):
        text abbreviateRelTime(commit.relativeTime)
      span(class = "vcs-commit-diff-btn",
           onclick = proc() = vm.invokeToggleUnifiedDiff(callbacks)):
        text "⊟"
  r.appendRenderedChild(headerNode, body)

  # Tooltip: attach hover handlers that show commit details in the floating
  # fixed-position tooltip div.
  let dotColorStr =
    if commit.dotLane >= 0 and commit.dotLane < commit.graphCells.len:
      branchColors[commit.graphCells[commit.dotLane].colorIdx mod branchColors.len]
    else:
      branchColors[0]
  r.attachCommitTooltip(headerNode, commit.hash, commit.fullHash,
                        commit.author, commit.relativeTime, dotColorStr)

  r.appendRenderedChild(entryNode, header)

  # Expanded body: changed-files list for this commit (when selected).
  # Files are looked up from commitFilesMap keyed by index so multiple commits
  # can be expanded simultaneously without overwriting each other's file list.
  if isSelected:
    let continuationCells = computeContinuationCells(commit.graphCells, commit.connectors)

    # Find this commit's file list in the map.
    var commitFiles: seq[VCSFileRow] = @[]
    for pair in vm.commitFilesMap.val:
      if pair[0] == index:
        commitFiles = pair[1]
        break

    if commitFiles.len == 0:
      # "No changed files" row — same [lane-spacer][content] layout as file
      # rows so the lane lines continue through it without a gap.
      var emptyRowNode: typeof(r.createElement("div"))
      let emptyRow = ui(r):
        tdiv(ref = emptyRowNode, class = "vcs-accordion-file")
      r.appendRenderedChild(emptyRowNode, renderLaneSpacer(r, continuationCells))
      let emptyContent = ui(r):
        tdiv(class = "vcs-accordion-file-body"):
          tdiv(class = "vcs-no-files"):
            text VCSNoFilesText
      r.appendRenderedChild(emptyRowNode, emptyContent)
      r.appendRenderedChild(entryNode, emptyRow)
    else:
      var filesNode: typeof(r.createElement("div"))
      let filesContainer = ui(r):
        tdiv(ref = filesNode, class = "vcs-accordion-files")
      for j, file in commitFiles:
        r.appendRenderedChild(filesNode,
          renderAccordionFileRow(r, callbacks, j, file, continuationCells))
      r.appendRenderedChild(entryNode, filesContainer)

  entry

proc renderCommitGraph[R](r: R; vm: VCSVM; callbacks: VCSCallbacks): auto =
  ## Main commit-graph renderer.
  ##
  ## Produces a scrollable accordion list:
  ## - Each commit has a **header row**: [SVG graph] [message] [relative time].
  ## - The **selected** commit is expanded to show an info bar and an inline
  ##   file list sourced from ``vm.changedFiles``.
  ## - An invisible **sentinel div** at the bottom triggers
  ##   ``onLoadMoreCommits`` via IntersectionObserver when it enters the
  ##   viewport, enabling endless scroll pagination.
  ## - A "Loading…" text row appears while ``vm.loadingMore`` is true.
  var list: typeof(r.createElement("div"))
  var sentinel: typeof(r.createElement("div"))

  let panel = ui(r):
    tdiv(class = "vcs-commit-history"):
      tdiv(ref = list, class = "vcs-commit-list")

  for i, commit in vm.commits.val:
    # Each commit row is rendered by a dedicated proc so the click closure
    # captures ``i`` through a proc parameter — not a for-loop variable — giving
    # each row an independent, correct index capture.
    r.appendRenderedChild(list,
      renderCommitRow(r, vm, callbacks, i, commit,
                      i in vm.selectedCommitIndices.val))

  # Sentinel div at the end of the list.  The IntersectionObserver on JS
  # targets calls onLoadMoreCommits when this div scrolls into view.
  let bottomArea = ui(r):
    tdiv(ref = sentinel, class = "vcs-load-more-sentinel"):
      if vm.loadingMore.val:
        text "Loading\xe2\x80\xa6"  # "Loading…" — ellipsis U+2026

  r.appendRenderedChild(list, bottomArea)
  r.attachScrollSentinel(sentinel, callbacks)

  # Single commit-detail tooltip div, rendered once at the panel level.
  # It stays hidden (display:none) until a commit header is hovered.
  # position:fixed (via CSS) lets it escape the panel's overflow:hidden.
  let tooltip = ui(r):
    tdiv(id = "vcs-commit-tooltip", class = "vcs-commit-tooltip"):
      tdiv(class = "vcs-tip-header"):
        span(class = "vcs-tip-dot"): discard
        span(class = "vcs-tip-hash"): discard
      tdiv(class = "vcs-tip-row"):
        span(class = "vcs-tip-label"): text "DATE"
        span(class = "vcs-tip-date"): discard
      tdiv(class = "vcs-tip-row"):
        span(class = "vcs-tip-label"): text "COMMIT"
        span(class = "vcs-tip-commit"): discard
      tdiv(class = "vcs-tip-row"):
        span(class = "vcs-tip-label"): text "AUTHOR"
        span(class = "vcs-tip-author"): discard
  r.appendRenderedChild(panel, tooltip)


  panel

# ---------------------------------------------------------------------------
# Changed-files panel (DeepReview mode and unified-diff view)
# ---------------------------------------------------------------------------

proc renderChangedFileRow[R](r: R; callbacks: VCSCallbacks;
                             index: int; file: VCSFileRow): auto =
  ## Render a single changed-file row.  Extracted into its own proc so the
  ## ``onclick`` closure captures the per-row ``index``/``path`` through
  ## proc parameters — a guaranteed-fresh binding per call.
  let rowIndex = index
  let rowPath = file.path
  ui(r):
    tdiv(class = fileRowClass(file.selected),
         onclick = proc() =
           callbacks.invokeSelectFile(rowIndex, rowPath)):
      span(class = "vcs-file-status " & statusClass(file.status)):
        text statusLabel(file.status)
      span(class = "vcs-file-name"):
        text file.baseName
      if file.additions > 0 or file.deletions > 0:
        span(class = "vcs-file-stats"):
          if file.additions > 0:
            span(class = "vcs-stat-added"):
              text "+" & $file.additions
          if file.deletions > 0:
            span(class = "vcs-stat-deleted"):
              text "-" & $file.deletions
      if file.coverageText.len > 0:
        span(class = "vcs-file-coverage"):
          text file.coverageText

proc renderChangedFiles[R](r: R; vm: VCSVM;
                           callbacks: VCSCallbacks): auto =
  var list: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = "vcs-changed-files"):
      tdiv(class = "vcs-section-header"):
        text "Changed Files"
        span(class = "vcs-changed-files-commit"):
          text changedFilesHeaderText(vm)
      tdiv(ref = list, class = "vcs-file-list")
  if vm.changedFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "vcs-no-files"):
        text VCSNoFilesText
    r.appendRenderedChild(list, empty)
  else:
    for i, file in vm.changedFiles.val:
      r.appendRenderedChild(list, renderChangedFileRow(r, callbacks, i, file))
  panel

# ---------------------------------------------------------------------------
# Unified diff (hunk editor)
# ---------------------------------------------------------------------------

proc renderHunkToolbar[R](r: R; vm: VCSVM;
                          callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "hunk-toolbar"):
      span(class = "hunk-toolbar-count"):
        text hunkToolbarText(vm.selectedHunkCount.val)
      tdiv(class = "hunk-toolbar-actions"):
        tdiv(class = "hunk-toolbar-button",
             onclick = proc() =
               if callbacks.onCopySelectedHunks != nil:
                 callbacks.onCopySelectedHunks()):
          text (if vm.hunkCopyFeedback.val: "Copied!" else: "Copy as patch")
        tdiv(class = "hunk-toolbar-button",
             onclick = proc() =
               if callbacks.onStageSelectedHunks != nil:
                 callbacks.onStageSelectedHunks()):
          text "Stage hunks"
        tdiv(class = "hunk-toolbar-button hunk-toolbar-button-subtle",
             onclick = proc() =
               if callbacks.onClearSelectedHunks != nil:
                 callbacks.onClearSelectedHunks()):
          text "Clear"

proc renderDiffLine[R](r: R; line: VCSDiffLineRow): auto =
  let oldText = if line.oldLine > 0: $line.oldLine else: ""
  let newText = if line.newLine > 0: $line.newLine else: ""
  let prefix = case line.lineType
    of "added": "+"
    of "removed": "-"
    else: " "
  ui(r):
    tdiv(class = diffLineClass(line.lineType)):
      span(class = "deepreview-unified-gutter-old"):
        text oldText
      span(class = "deepreview-unified-gutter-new"):
        text newText
      span(class = "deepreview-unified-line-prefix"):
        text prefix
      span(class = "deepreview-unified-line-content"):
        text line.content

proc renderDiffHunk[R](r: R; fileIndex, hunkIdx: int; hunk: VCSHunkRow;
                       callbacks: VCSCallbacks): auto =
  var header: typeof(r.createElement("div"))
  let node = ui(r):
    tdiv(class = hunkClass(hunk.selected)):
      tdiv(ref = header,
           class = "deepreview-unified-hunk-header hunk-header-selectable"):
        if hunk.selected:
          span(class = "hunk-selection-indicator"):
            text "v"
        text hunkHeaderText(hunk)
  for line in hunk.lines:
    r.appendRenderedChild(node, renderDiffLine(r, line))
  r.attachHunkClick(header, callbacks, fileIndex, hunkIdx)
  node

proc renderDiffFile[R](r: R; file: VCSDiffFileRow;
                       callbacks: VCSCallbacks): auto =
  let fileIndex = file.fileIndex
  let stats = fileStatsText(file.additions, file.deletions)
  let node = ui(r):
    tdiv(class = "deepreview-unified-file",
         `data-file-index` = $fileIndex):
      tdiv(class = "deepreview-unified-file-header"):
        span(class = diffStatusClass(file.status)):
          text statusLabel(file.status)
        span(class = "deepreview-unified-file-path"):
          text file.path
        span(class = "deepreview-unified-file-stats"):
          text stats
  for hunkIdx, hunk in file.hunks:
    r.appendRenderedChild(node, renderDiffHunk(r, fileIndex, hunkIdx, hunk,
                                               callbacks))
  node

proc renderUnifiedDiff*[R](r: R; vm: VCSVM;
                          callbacks: VCSCallbacks): auto =
  let panel = ui(r):
    tdiv(class = "deepreview-unified-diff")
  if vm.hunkToolbarVisible.val and vm.selectedHunkCount.val > 0:
    r.appendRenderedChild(panel, renderHunkToolbar(r, vm, callbacks))
  if vm.diffFiles.val.len == 0:
    let empty = ui(r):
      tdiv(class = "deepreview-unified-empty"):
        text VCSNoDiffText
    r.appendRenderedChild(panel, empty)
  else:
    for file in vm.diffFiles.val:
      r.appendRenderedChild(panel, renderDiffFile(r, file, callbacks))
  panel

proc renderDiffToggle[R](r: R; vm: VCSVM; callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "vcs-diff-toggle"):
      tdiv(class = toggleButtonClass(vm.unifiedDiffActive.val),
           onclick = proc() =
             vm.invokeToggleUnifiedDiff(callbacks)):
        text "Unified Diff"

proc renderRefresh[R](r: R; callbacks: VCSCallbacks): auto =
  ui(r):
    tdiv(class = "vcs-refresh",
         onclick = proc() = callbacks.invokeRefresh()):
      text "Refresh"

# ---------------------------------------------------------------------------
# Scroll-position preservation helpers
# ---------------------------------------------------------------------------
#
# ``createRenderEffect`` calls ``clearChildren(body)`` on every reactive
# update, rebuilding the entire subtree and resetting any scroll position to 0.
# These two procs bracket the clear+rebuild so the commit-list scrollTop
# survives rerenders.  The position is stashed as a JS property directly on
# the ``body`` element so each mounted panel instance is independent.

when defined(js):
  ## Save the scrollTop of the .vcs-commit-list child onto the body element
  ## so it survives the upcoming clearChildren + rebuild cycle.
  proc saveCommitListScroll(body: isonim_dom.Element)
    {.importjs: """(function(body) {
      var list = body.querySelector('.vcs-commit-list');
      if (list) body._vcsScrollTop = list.scrollTop;
    })(#)""".}

  ## Restore the scrollTop saved by saveCommitListScroll onto the newly
  ## created .vcs-commit-list child after the rebuild is complete.
  ## Also dispatches a synthetic mousemove at the last known cursor position so
  ## the browser re-evaluates hover state without requiring the user to move the
  ## mouse — important after load-more triggers a full DOM rebuild.
  proc restoreCommitListScroll(body: isonim_dom.Element)
    {.importjs: """(function(body) {
      var list = body.querySelector('.vcs-commit-list');
      if (list && body._vcsScrollTop != null) list.scrollTop = body._vcsScrollTop;
      if (body._vcsLastMouseX != null) {
        var el = document.elementFromPoint(body._vcsLastMouseX, body._vcsLastMouseY);
        if (el) {
          el.dispatchEvent(new MouseEvent('mousemove', {
            bubbles: true, cancelable: true,
            clientX: body._vcsLastMouseX, clientY: body._vcsLastMouseY
          }));
        }
      }
    })(#)""".}

  ## Track cursor position on the panel so restoreCommitListScroll can replay it.
  proc attachMouseTracker(body: isonim_dom.Element)
    {.importjs: """(function(body) {
      if (body._vcsMouseTracked) return;
      body._vcsMouseTracked = true;
      body.addEventListener('mousemove', function(e) {
        body._vcsLastMouseX = e.clientX;
        body._vcsLastMouseY = e.clientY;
      }, { passive: true });
    })(#)""".}

proc saveCommitListScroll(body: MockNode)    = discard
proc restoreCommitListScroll(body: MockNode) = discard
proc attachMouseTracker(body: MockNode)      = discard

# ---------------------------------------------------------------------------
# Top-level panel assembly
# ---------------------------------------------------------------------------

proc renderVCSPanelImpl[R](r: R; vm: VCSVM;
                           callbacks: VCSCallbacks): auto =
  var body: typeof(r.createElement("div"))
  let panel = ui(r):
    tdiv(class = VCSContainerClass):
      tdiv(ref = body, class = "vcs-panel-body")

  attachMouseTracker(body)

  createRenderEffect proc() =
    saveCommitListScroll(body)
    r.clearChildren(body)
    if vm.deepReviewMode.val:
      r.appendRenderedChild(body, renderHeader(r, vm))
      r.appendRenderedChild(body, renderChangedFiles(r, vm, callbacks))
    elif not vm.isGitRepo.val:
      r.appendRenderedChild(body, renderNoRepo(r, vm))
    else:
      r.appendRenderedChild(body, renderBranchPicker(r, vm, callbacks))
      if vm.unifiedDiffActive.val:
        r.appendRenderedChild(body, renderUnifiedDiff(r, vm, callbacks))
      else:
        # Commit graph with accordion expand/collapse and infinite-scroll.
        r.appendRenderedChild(body, renderCommitGraph(r, vm, callbacks))
    restoreCommitListScroll(body)

  panel

proc renderVCSPanel*(r: MockRenderer; vm: VCSVM;
                     callbacks: VCSCallbacks = VCSCallbacks()): MockNode =
  renderVCSPanelImpl(r, vm, callbacks)

when defined(js):
  proc renderVCSPanel*(r: WebRenderer; vm: VCSVM;
                       callbacks: VCSCallbacks = VCSCallbacks()):
                       isonim_dom.Element =
    renderVCSPanelImpl(r, vm, callbacks)

  proc mountIsoNimVCSPanel*(container: isonim_dom.Element; vm: VCSVM;
                            callbacks: VCSCallbacks = VCSCallbacks()) =
    let r = WebRenderer()
    let panel = renderVCSPanel(r, vm, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
