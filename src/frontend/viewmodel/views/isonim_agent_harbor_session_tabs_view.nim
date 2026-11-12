## IsoNim views of the Agent Harbor sessions an operator works with, as
## CodeTracer's session tabs, over `SessionTabStripVM`
## (nim-agents-isonim-viewmodels, the sessions family's tab-strip variant).
##
## Two renderings of the one viewmodel:
##
## - `renderAgentHarborTabStrip`: the strip in the caption bar, built from
##   CodeTracer's own session tab strip (`isonim_session_tabs_view.nim`,
##   `session_tabs.styl`): the same `.session-tab` shape and colours, the
##   same active tab, close control, overflow chevron and menu (hanging from
##   its chip, `hangOverflowMenu`), and "+". Each tab adds a status mark
##   before its title (running, idle, needs input, queued, failed, ended)
##   and the front-end that started the session after it. One line keeps the
##   active tab visible and puts the rest in the overflow menu
##   (`SessionTabStripVM.singleLine`, CodeTracer's rule); the multi-line
##   layout wraps onto as many lines as it needs.
## - `renderAgentHarborSessionList`: the same tabs as a vertical list -- the
##   strip's sidebar layout, collapsible to a rail of marks, and its docked
##   layout, a panel in the layout that spreads into columns when wide.
##   Grouped by initiative when the viewmodel says so.
##
## What a tab says, and in what order the tabs come, is the viewmodel's; the
## views only draw it, so the terminal and GPUI front-ends read the same words.

import std/strutils
when defined(js):
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/session_tabs_vm
import ./isonim_session_tabs_view

import ./agent_harbor_words

export signals, computation, components, session_tabs_vm, agent_harbor_words

const
  AgentHarborTabStripClass* = "session-tab-bar ah-tab-strip"
  AgentHarborSessionListClass* = "component-container ah-session-list"

type
  AgentHarborTabCallbacks* = object
    ## Host hooks; a missing one falls back to the viewmodel's own action.
    onActivate*: proc(sessionId: string)
    onClose*: proc(sessionId: string)
    onAdd*: proc()
    onRetry*: proc()

proc attentionClass*(attention: SessionAttention): string =
  "ah-att-" & $attention

proc tabClassOf*(vm: SessionTabStripVM; tab: SessionItem): string =
  result = tabClass(tab.active) & " ah-tab " & attentionClass(tab.attention)
  if vm.isInFocus(tab): result.add " ah-tab-in-focus"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc invokeActivate(vm: SessionTabStripVM; cb: AgentHarborTabCallbacks; id: string) =
  if cb.onActivate != nil: cb.onActivate(id)
  else: discard vm.activate(id)

proc invokeClose(vm: SessionTabStripVM; cb: AgentHarborTabCallbacks; id: string) =
  if cb.onClose != nil: cb.onClose(id)
  else: discard vm.close(id)

proc invokeRetry(vm: SessionTabStripVM; cb: AgentHarborTabCallbacks) =
  if cb.onRetry != nil: cb.onRetry() else: vm.load()

proc invokeAdd(cb: AgentHarborTabCallbacks) =
  ## "+" opens a new tab (Multi-Window-Tab-Management, Tab Behavior rule 3);
  ## a prototype with no host has nowhere to open it.
  if cb.onAdd != nil: cb.onAdd()

when defined(js):
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

proc renderTab[R](r: R; vm: SessionTabStripVM; cb: AgentHarborTabCallbacks;
                  tab: SessionItem; closable: bool): auto =
  ## One tab: mark, title, origin, close. A proc of its own so each closure
  ## owns its session id.
  let id = tab.id
  var close: typeof(r.createElement("span"))
  let node = ui(r):
    tdiv(class = vm.tabClassOf(tab), id = "ah-tab-" & tab.shortId,
         title = tab.tooltip, role = "button", tabindex = "0",
         onclick = proc() = vm.invokeActivate(cb, id)):
      span(class = "ah-tab-mark"):
        discard
      span(class = SessionTabLabelClass):
        text tabLabelOf(tab)
      if tab.originShort.len > 0:
        span(class = "ah-tab-origin", title = "started from " & tab.originLabel):
          text tab.originShort
      if closable:
        span(ref = close, class = SessionTabCloseClass, title = "Close tab",
             onclick = proc() = vm.invokeClose(cb, id)):
          discard
  when defined(js):
    when typeof(close) is isonim_dom.Element:
      if closable:
        # Stopped here: the tab's own click would activate the closing tab.
        isonim_dom.addEventListener(isonim_dom.Node(close), cstring"click",
          proc(ev: isonim_dom.Event) = ev.stopPropagation())
  node

proc renderOverflowItem[R](r: R; vm: SessionTabStripVM; cb: AgentHarborTabCallbacks;
                           tab: SessionItem): auto =
  let id = tab.id
  ui(r):
    tdiv(class = SessionTabOverflowItemClass & " ah-tab-overflow-item " &
                 attentionClass(tab.attention) & (if tab.active: " active" else: ""),
         title = tab.tooltip, onclick = proc() = vm.invokeActivate(cb, id)):
      span(class = "ah-tab-mark"):
        discard
      span(class = "ah-tab-overflow-title"):
        text tab.title
      if tab.originShort.len > 0:
        span(class = "ah-tab-origin", title = "started from " & tab.originLabel):
          text tab.originShort

proc stripClass(vm: SessionTabStripVM; overflow: bool): string =
  result = AgentHarborTabStripClass
  if vm.mode.val == tsmMultiLine: result.add " ah-tab-strip-wrap"
  if overflow: result.add " has-overflow"
  if vm.overflowOpen.val: result.add " overflow-open"

proc renderStatusTab[R](r: R; vm: SessionTabStripVM; cb: AgentHarborTabCallbacks;
                        text, extra: string; retry: bool): auto =
  ## A tab-shaped notice in place of the tabs: loading, or an error with
  ## its retry.
  ui(r):
    tdiv(class = SessionTabClass & " ah-tab-notice " & extra, title = text):
      span(class = SessionTabLabelClass):
        text text
      if retry:
        button(class = "ah-tab-retry", onclick = proc() = vm.invokeRetry(cb)):
          text "Retry"

when defined(js):
  proc hangOverflowMenu*(within: isonim_dom.Element) {.importjs: """
    (function(el) {
      var bars = el.classList.contains('ah-tab-strip') ? [el]
                 : el.querySelectorAll('.ah-tab-strip');
      for (var i = 0; i < bars.length; i++) {
        var bar = bars[i];
        if (!bar.isConnected) continue;
        var chip = bar.querySelector(':scope > .ah-tab-overflow-count');
        var menu = bar.querySelector(':scope > .session-tab-overflow-menu');
        if (!chip || !menu) continue;
        menu.style.left = menu.style.right = menu.style.width = '';
        var w = menu.getBoundingClientRect().width;
        if (w === 0) continue;
        var view = document.documentElement.clientWidth;
        var left = Math.max(0, Math.min(chip.getBoundingClientRect().right - w, view - w));
        var b = bar.getBoundingClientRect();
        menu.style.right = 'auto';
        menu.style.width = w + 'px';
        menu.style.left = (left - b.left - bar.clientLeft) + 'px';
      }
    })(#)""".}
    ## A strip's `+N` menu -- this strip's, and the initiative bar's -- hangs
    ## from its chip: its right edge on the chip's right edge, shifted only
    ## as far as it must be to stay inside the window on either side. The
    ## menu is `session-tab-overflow-menu`, placed in its bar (its containing
    ## block, so its height under the caption bar is the strip's), whose
    ## rule right-aligns it under the bar's end; where the chip is cannot be
    ## said in CSS, so it is measured. The width is measured where the
    ## stylesheet puts it and kept, so moving the menu never rewraps it.
    ## `within` is a bar or holds bars; a bar not yet in the document, or
    ## whose menu is closed (not drawn), is left alone: the mount places it
    ## again once it is (and when the window's size or its fonts move the
    ## chip).

  proc onFontsLoaded*(cb: proc()) {.importjs: """
    (function(cb) {
      if (!document.fonts) return;
      document.fonts.ready.then(cb);
      document.fonts.addEventListener('loadingdone', cb);
    })(#)""".}
    ## A face that arrives after a bar is drawn changes the tabs' widths,
    ## and with them where the `+N` chip is.

proc renderAgentHarborTabStrip*[R, N](r: R; vm: SessionTabStripVM;
    cb: AgentHarborTabCallbacks = AgentHarborTabCallbacks()): N =
  ## The strip, single-line or multi-line by `vm.mode`. Rebuilt when the
  ## viewmodel moves.
  mixin clearChildren, setAttribute
  var bar: N
  let host = ui(r):
    tdiv(class = "ah-tab-strip-host"):
      tdiv(ref = bar, id = SessionTabBarId, class = AgentHarborTabStripClass)
  createRenderEffect proc() =
    r.clearChildren(bar)
    let tabs = vm.tabs
    var overflowIndexes: seq[int]
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(bar, renderStatusTab(r, vm, cb, AgentHarborTabsLoadingText,
                                            "ah-tab-loading", false))
    of asError:
      r.appendRendered(bar, renderStatusTab(r, vm, cb, AgentHarborTabsErrorText &
        ": " & vm.error.val, "ah-tab-error", true))
    of asReady:
      if tabs.len == 0:
        r.appendRendered(bar, renderStatusTab(r, vm, cb, AgentHarborTabsEmptyText,
                                              "ah-tab-empty", false))
      else:
        let closable = tabs.len > 1
        if vm.mode.val == tsmMultiLine:
          for tab in tabs:
            r.appendRendered(bar, renderTab(r, vm, cb, tab, closable))
        else:
          let line = vm.singleLine
          overflowIndexes = line.overflow
          for i in line.visible:
            r.appendRendered(bar, renderTab(r, vm, cb, tabs[i], closable))
    r.setAttribute(bar, "class", vm.stripClass(overflowIndexes.len > 0))
    if overflowIndexes.len > 0:
      let target = vm
      # A hidden tab that needs the reader marks the chip, so "what needs
      # me" is seen without opening the menu.
      var hiddenWaits = 0
      for i in overflowIndexes:
        if tabs[i].attention == saNeedsInput: inc hiddenWaits
      let chevron = ui(r):
        tdiv(class = SessionTabOverflowClass & " ah-tab-overflow-count" &
                     (if hiddenWaits > 0: " ah-att-needs-input" else: ""),
             title = $overflowIndexes.len & " more tabs" &
                     (if hiddenWaits > 0: ", " & $hiddenWaits & " needing input" else: ""),
             onclick = proc() = target.toggleOverflow()):
          text "+" & $overflowIndexes.len
      r.appendRendered(bar, chevron)
    let add = ui(r):
      button(class = "ct-button-image-sm-secondary ct-button-no-border session-tab-add",
             title = SessionTabAddTitle,
             onclick = proc() = cb.invokeAdd()):
        discard
    r.appendRendered(bar, add)
    if overflowIndexes.len > 0:
      var menu: N
      let menuNode = ui(r):
        tdiv(ref = menu, class = SessionTabOverflowMenuClass)
      for i in overflowIndexes:
        r.appendRendered(menu, renderOverflowItem(r, vm, cb, tabs[i]))
      r.appendRendered(bar, menuNode)
      # Open (the strip's `overflow-open`), the menu is drawn, so it is
      # placed now.
      when defined(js):
        when N is isonim_dom.Element:
          if vm.overflowOpen.val: hangOverflowMenu(bar)
  host

# ---------------------------------------------------------------------------
# The sidebar and docked layouts
# ---------------------------------------------------------------------------

proc renderListRow[R](r: R; vm: SessionTabStripVM; cb: AgentHarborTabCallbacks;
                      tab: SessionItem; collapsed: bool): auto =
  let id = tab.id
  let cls = "ah-session-row " & attentionClass(tab.attention) &
    (if tab.active: " ah-session-row-active" else: "") &
    (if vm.isInFocus(tab): " ah-tab-in-focus" else: "")
  if collapsed:
    return ui(r):
      tdiv(class = cls & " ah-session-row-rail", title = tab.tooltip,
           role = "button", tabindex = "0",
           onclick = proc() = vm.invokeActivate(cb, id)):
        span(class = "ah-tab-mark"):
          discard
  let detail = if tab.failureText.len > 0: tab.failureText
               elif tab.activity.len > 0: tab.activity[0].lineText
               else: ""
  ui(r):
    tdiv(class = cls, title = tab.tooltip, role = "button", tabindex = "0",
         onclick = proc() = vm.invokeActivate(cb, id)):
      span(class = "ah-tab-mark"):
        discard
      tdiv(class = "ah-session-row-main"):
        tdiv(class = "ah-session-row-title"):
          text tab.title
        tdiv(class = "ah-session-row-meta"):
          span(class = "ah-session-row-status"):
            text tab.statusLabel
          span(class = "ah-session-row-meta-text"):
            text metaOf(tab)
        if detail.len > 0:
          tdiv(class = "ah-session-row-detail" &
                       (if tab.failureText.len > 0: " ah-session-row-failure" else: "")):
            text detail
      span(class = "ah-session-row-age"):
        text tab.ageLabel

proc renderGroupHeader[R](r: R; vm: SessionTabStripVM; group: SessionTabGroup): auto =
  ## An initiative's node of the tree: a fold control, the initiative's state
  ## mark, its name, `n/m` milestones and its sessions' counts.
  let planId = group.planId
  let target = vm
  let chevron = if group.collapsed: "\xE2\x96\xB8" else: "\xE2\x96\xBE"
  let foldTitle = if group.collapsed: "Show its sessions" else: "Hide its sessions"
  ui(r):
    tdiv(class = "ah-session-group-header ah-ist-" & $group.state &
                 (if group.planId.len > 0 and group.planId == vm.focusedPlan.val:
                    " ah-session-group-focus" else: ""),
         title = group.title, role = "treeitem",
         onclick = proc() = target.toggleGroup(planId)):
      span(class = "ah-session-group-fold", title = foldTitle):
        text chevron
      if group.planId.len > 0:
        span(class = "ah-tab-mark"):
          discard
      span(class = "ah-session-group-title"):
        text group.title
      if group.progressText.len > 0:
        span(class = "ah-tab-progress"):
          text group.progressText
      span(class = "ah-session-group-counts", title = countsText(group.counts)):
        text countsText(group.counts)

proc renderAgentHarborSessionList*[R, N](r: R; vm: SessionTabStripVM;
    cb: AgentHarborTabCallbacks = AgentHarborTabCallbacks()): N =
  ## The sidebar (`tsmSidebar`) or docked (`tsmDocked`) layout.
  mixin clearChildren, setAttribute
  var body, root: N
  let panel = ui(r):
    tdiv(ref = root, class = AgentHarborSessionListClass):
      tdiv(ref = body, class = "ah-session-list-body")
  createRenderEffect proc() =
    # Signals are read here, in the effect, and not inside the `ui` blocks
    # below: a `ui` block's `if` runs once when the block builds, so it is
    # this effect re-running that makes the head follow `vm.mode`.
    let sidebar = vm.mode.val == tsmSidebar
    let collapsed = vm.collapsed.val and sidebar
    r.setAttribute(root, "class", AgentHarborSessionListClass & " ah-session-list-" &
      $vm.mode.val & (if collapsed: " ah-session-list-collapsed" else: ""))
    r.clearChildren(body)
    let target = vm
    var headerSummary = ""
    if vm.state.val == asReady: headerSummary = vm.summaryText
    let collapseTitle = if collapsed: "Expand the session list" else: "Collapse to marks"
    let collapseGlyph = if collapsed: "\xC2\xBB" else: "\xC2\xAB"
    let loadingText = if collapsed: "\xE2\x80\xA6" else: AgentHarborTabsLoadingText
    let head = ui(r):
      tdiv(class = "ah-session-list-head"):
        if not collapsed:
          span(class = "ah-session-list-title"):
            text "Sessions"
          span(class = "ah-session-list-summary", title = vm.sourceLabel):
            text headerSummary
        if sidebar:
          button(class = "ah-session-list-collapse",
                 title = collapseTitle,
                 onclick = proc() = target.collapsed.val = not target.collapsed.val):
            text collapseGlyph
    r.appendRendered(body, head)
    if not collapsed and vm.sourceLabel.len > 0:
      # Where the sessions come from (a server, a snapshot, an invented set),
      # as the fleet panel names its source.
      let source = ui(r):
        tdiv(class = "ah-session-list-source", title = vm.sourceLabel):
          text vm.sourceLabel
      r.appendRendered(body, source)
    case vm.state.val
    of asIdle, asLoading:
      let overlay = ui(r):
        tdiv(class = "empty-overlay ah-session-list-overlay ah-session-list-loading"):
          text loadingText
      r.appendRendered(body, overlay)
    of asError:
      let error = ui(r):
        tdiv(class = "ah-fleet-error ah-session-list-error"):
          tdiv(class = "ah-fleet-error-title"):
            text "Could not load the sessions"
          tdiv(class = "ah-fleet-error-message"):
            text vm.error.val
          button(class = "ah-fleet-retry", onclick = proc() = target.invokeRetry(cb)):
            text "Retry"
      r.appendRendered(body, error)
    of asReady:
      let groups = vm.groups
      if vm.tabs.len == 0:
        let overlay = ui(r):
          tdiv(class = "empty-overlay ah-session-list-overlay"):
            text AgentHarborTabsEmptyText
        r.appendRendered(body, overlay)
      else:
        var list: N
        let listNode = ui(r):
          tdiv(ref = list, class = "ah-session-list-rows")
        for group in groups:
          var section: N
          let sectionNode = ui(r):
            tdiv(ref = section, class = "ah-session-group")
          if vm.grouped.val and not collapsed:
            r.appendRendered(section, renderGroupHeader(r, vm, group))
          if not (group.collapsed and vm.grouped.val and not collapsed):
            var rows: N
            let rowsNode = ui(r):
              tdiv(ref = rows, class = "ah-session-group-rows", role = "group")
            for tab in group.tabs:
              r.appendRendered(rows, renderListRow(r, vm, cb, tab, collapsed))
            r.appendRendered(section, rowsNode)
          r.appendRendered(list, sectionNode)
        r.appendRendered(body, listNode)
  panel

when defined(js):
  proc measureWidth(el: isonim_dom.Element): int {.importjs: "(#.getBoundingClientRect().width | 0)".}
  proc onResize(cb: proc()) {.importjs: "window.addEventListener('resize', #)".}

  proc mountAgentHarborTabStrip*(container: isonim_dom.Element;
                                 vm: SessionTabStripVM;
                                 cb = AgentHarborTabCallbacks()) =
    ## Mounts the strip into `container` (the caption bar) and keeps the
    ## viewmodel told how wide the strip is, so one line knows what fits.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborTabStrip[WebRenderer, isonim_dom.Element](WebRenderer(), vm, cb)))
    let measure = proc() =
      let width = measureWidth(container)
      if width > 0 and width != vm.stripWidthPx.val: vm.stripWidthPx.val = width
      hangOverflowMenu(container)
    measure()
    onResize(measure)
    onFontsLoaded(proc() = hangOverflowMenu(container))

  proc mountAgentHarborSessionList*(container: isonim_dom.Element;
                                    vm: SessionTabStripVM;
                                    cb = AgentHarborTabCallbacks()) =
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborSessionList[WebRenderer, isonim_dom.Element](WebRenderer(), vm, cb)))
