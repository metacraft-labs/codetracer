## ui/pointer_stamp.nim — the desktop's half of the pointer's shape
## (Pointer-Affordances.md §4): every interactive element carries
## `data-pointer` from the one shared function, and `styles/components/
## pointer.styl` is the only stylesheet that says `cursor`.
##
## The stylesheets used to hold a `cursor:` declaration per selector. Those
## selectors are this table now: each names the `HitKind` it is, and whether it
## is the disabled state of a control. The DOM is the desktop's hit-test
## (Input-Routing §5.3); `pointerShapeOf` is what turns its answer into a shape.
##
## A MutationObserver stamps what the views render, as they render it, and
## re-stamps an element whose enablement changes. Monaco's own subtree is left
## to Monaco, which is this table's `text` and `default` already.

import ../../common/pointer_shape

type
  PointerBinding = tuple[selector: cstring; kind: HitKind; disabled: bool]

  JsEl {.importc: "Element".} = ref object
  JsRecord {.importc: "MutationRecord".} = ref object
  JsObserver {.importc: "MutationObserver".} = ref object
  JsEv {.importc: "Event".} = ref object

const
  PointerBindings: array[267, PointerBinding] = [
    (cstring".ct-origin-inline-chain-hop", hkRow, false),
    (cstring".ct-origin-inline-chain-terminator", hkNone, false),
    (cstring".ct-origin-hop", hkRow, false),
    (cstring".ct-origin-hop details", hkNone, false),
    (cstring".ct-origin-hop summary", hkExpander, false),
    (cstring".install-btn", hkControl, false),
    (cstring".dismiss-btn", hkControl, false),
    (cstring".dialog-options label", hkControl, false),
    (cstring".agent-ha-container .agent-paste-thumb", hkControl, false),
    (cstring".agent-ha-container .agent-paste-thumb .agent-paste-remove", hkControl, false),
    (cstring".agent-ha-container .agent-context-path-chip .agent-paste-remove", hkControl, false),
    (cstring".agent-thought-header", hkControl, false),
    (cstring".agent-test-run-header", hkControl, false),
    (cstring".agent-test-row-header", hkControl, false),
    (cstring".agent-user-copy-button", hkControl, false),
    (cstring".agent-msg-thumb", hkControl, false),
    (cstring".agent-diff-unified-btn", hkControl, false),
    (cstring".agent-diff-file-row", hkControl, false),
    (cstring".agent-tc-toggle", hkControl, false),
    (cstring".agent-tc-icon", hkControl, false),
    (cstring".agent-idle-chip", hkControl, false),
    (cstring".agent-model-item", hkControl, false),
    (cstring".agent-branch-item", hkControl, false),
    (cstring".agent-branch-create-row", hkControl, false),
    (cstring".agent-add-context-menu-item", hkControl, false),
    (cstring".agent-settings-select-trigger", hkControl, false),
    (cstring".agent-settings-dropdown-item", hkControl, false),
    (cstring".agent-settings-toggle", hkControl, false),
    (cstring".agent-settings-add-chip", hkControl, false),
    (cstring".agent-settings-reset", hkControl, false),
    (cstring".ah-fleet-filter", hkControl, false),
    (cstring".ah-fleet-row", hkControl, false),
    (cstring".ah-fleet-activity-more", hkControl, false),
    (cstring".ah-fleet-retry", hkControl, false),
    (cstring".ah-tab-strip .session-tab.ah-tab-notice", hkNone, false),
    (cstring".ah-tab-retry", hkControl, false),
    (cstring".ah-session-list-collapse", hkControl, false),
    (cstring".ah-session-row", hkControl, false),
    (cstring".ah-initiative-row", hkControl, false),
    (cstring".ah-rec-button", hkControl, false),
    (cstring".ah-inbox-step", hkControl, false),
    (cstring".ah-inbox-auto", hkControl, false),
    (cstring".ah-inbox-empty .ah-inbox-step", hkNone, false),
    (cstring".ah-elsewhere", hkControl, false),
    (cstring".ah-initiative-popup", hkNone, false),
    (cstring".ah-session-group-header", hkControl, false),
    (cstring".ah-initiative-fold", hkControl, false),
    (cstring".ah-initiative-more-toggle", hkControl, false),
    (cstring".agent-workspace-view-toggle", hkControl, false),
    (cstring".agent-workspace-overlay-toggle", hkControl, false),
    (cstring".agent-workspace-file-item", hkControl, false),
    (cstring".toggle-btn", hkControl, false),
    (cstring".continuation-jump-link", hkControl, false),
    (cstring".auto-hide-docked-resize-handle", hkColumnSeparator, false),
    (cstring"#auto-hide-strip-left.collapsed-mode", hkControl, false),
    (cstring"#auto-hide-strip-right.collapsed-mode", hkControl, false),
    (cstring".collapsed-strip-line", hkControl, false),
    (cstring".auto-hide-docked-resize-handle-bottom", hkDividerHorizontal, false),
    (cstring".auto-hide-strip-tab", hkControl, false),
    (cstring".auto-hide-strip-tab-btn", hkControl, false),
    (cstring".auto-hide-strip-tab-hide", hkControl, false),
    (cstring".auto-hide-overlay-left .auto-hide-overlay-resize-handle", hkColumnSeparator, false),
    (cstring".auto-hide-overlay-right .auto-hide-overlay-resize-handle", hkColumnSeparator, false),
    (cstring".auto-hide-overlay-bottom .auto-hide-overlay-resize-handle", hkDividerHorizontal, false),
    (cstring".overlay-floating-pin", hkControl, false),
    (cstring".collapsed-icon", hkControl, false),
    (cstring".overlay-side-tab", hkControl, false),
    (cstring".auto-hide-mode-button", hkControl, false),
    (cstring".auto-hide-tablist-item .auto-hide-tablist-close", hkControl, false),
    (cstring"button:disabled", hkControl, true),
    (cstring"[class*=""-button-""][class*=""-secondary""]", hkControl, false),
    (cstring"[class*=""-button-""][class*=""-tertiary""]", hkControl, false),
    (cstring".ct-origin-badge", hkControl, false),
    (cstring".calltrace-view .call-text", hkControl, false),
    (cstring".calltrace-view .remove-expanded-value", hkControl, false),
    (cstring".calltrace-view .toggle-call .collapse-call-img", hkControl, false),
    (cstring".calltrace-view .toggle-call .expand-call-img", hkControl, false),
    (cstring".calltrace-view .collapsed-callstack", hkControl, false),
    (cstring".step-list .step-line", hkControl, false),
    (cstring".chevron", hkControl, false),
    (cstring".value-expanded-text", hkControl, false),
    (cstring".value-expand", hkControl, false),
    (cstring".call-search-results", hkControl, false),
    (cstring".search-result", hkControl, false),
    (cstring".caption-progress-container", hkControl, false),
    (cstring".ct-checkmark-field", hkControl, false),
    (cstring".ct-checkmark-field[data-disabled=""true""]", hkControl, true),
    (cstring"#fixed-search .search-results", hkControl, false),
    (cstring".data-table tr[role=""button""]", hkControl, false),
    (cstring".editor-test-action", hkControl, false),
    (cstring".editor-test-action.active-test-button", hkNone, false),
    (cstring".eventLog-medium-control-button", hkControl, false),
    (cstring".hamburger-dropdown", hkControl, false),
    (cstring".hamburger-dropdown", hkControl, false),
    (cstring".toggle-buttons .ct-tab", hkTab, false),
    (cstring".eventLog .eventLog-event", hkControl, false),
    (cstring".eventLog .eventLog-button", hkControl, false),
    (cstring".eventLog .eventLog-category", hkControl, false),
    (cstring".paging-menu .paging-page", hkControl, false),
    (cstring".eventLog .data-table .eventLog-column-header .eventLog-cell", hkControl, false),
    (cstring".eventLog .eventLog-row", hkControl, false),
    (cstring".eventLog-columns-button", hkControl, false),
    (cstring".eventLog-columns-menu .eventLog-column-option .eventLog-column-check", hkControl, false),
    (cstring".eventLog-columns-menu .eventLog-column-option .eventLog-column-title", hkControl, false),
    (cstring".eventLog-columns-menu .eventLog-column-option .eventLog-column-handle", hkDragHandle, false),
    (cstring".file-conflict-dialog-actions button", hkControl, false),
    (cstring".filesystem-entry", hkNone, false),
    (cstring".diff-file-path", hkControl, false),
    (cstring".flow-component .flow-mode-selector button", hkControl, false),
    (cstring".flow-component .flow-step-row", hkControl, false),
    (cstring".flow-component .raw-value-toggle", hkControl, false),
    (cstring".flow-loop-first-line .flow-left-button", hkControl, false),
    (cstring".flow-loop-first-line .flow-right-button", hkControl, false),
    (cstring".tippy-box[data-theme~='internal_default_light'] .add-to-scratchpad-button", hkControl, false),
    (cstring".review-flow-selector .review-flow-step", hkControl, false),
    (cstring".review-flow-selector .review-flow-step[disabled]", hkControl, true),
    (cstring".frame-viewer-component .frame-viewer-frame-controls button", hkControl, false),
    (cstring".frame-viewer-component .frame-viewer-image", hkControl, false),
    (cstring".frame-viewer-component .frame-viewer-draw-call", hkControl, false),
    (cstring".lm_splitter", hkDividerVertical, false),
    (cstring".lm_splitter.lm_vertical", hkDividerHorizontal, false),
    (cstring".lm_controls > *", hkControl, false),
    (cstring".lm_header .lm_tab .lm_close_tab", hkControl, false),
    (cstring".lm_header .lm_tab .lm_pin_tab", hkControl, false),
    (cstring".hcr-live-edit-row button", hkControl, false),
    (cstring".history-list .history-list-item-wrapper .history-list-item", hkControl, false),
    (cstring".toggle-value-history", hkControl, false),
    (cstring".inline-history", hkControl, false),
    (cstring".history", hkControl, false),
    (cstring".isonim-debug-controls .history-list-host .history-list-entry", hkControl, false),
    (cstring".isonim-debug-controls .history-list-host .history-list-close", hkControl, false),
    (cstring"input:disabled", hkControl, true),
    (cstring".recent", hkControl, false),
    (cstring".editor-info .editor-vertical-line.splitter", hkDividerHorizontal, false),
    (cstring".low-level-code-sync", hkControl, false),
    (cstring".window-menu", hkControl, false),
    (cstring"#menu #menu-root #menu-logo-img", hkControl, false),
    (cstring"#menu .menu-search-icon", hkControl, false),
    (cstring"#menu .menu-search-result", hkControl, false),
    (cstring".ct-menu-item", hkControl, false),
    (cstring".ct-menu-item.ct-menu-item--disabled", hkControl, true),
    (cstring".status-notification.ct-notification .notification-button", hkControl, false),
    (cstring".status-notification.ct-notification .notification-action-button", hkControl, false),
    (cstring".test-results-run-btn", hkControl, false),
    (cstring".test-results-run-btn.disabled", hkControl, true),
    (cstring".test-results-refresh-btn", hkControl, false),
    (cstring".test-results-open-btn", hkControl, false),
    (cstring".test-results-refresh-btn.disabled", hkControl, true),
    (cstring".test-results-open-btn.disabled", hkControl, true),
    (cstring".constraints-row.linked", hkControl, false),
    (cstring".constraints-opcode.linked", hkControl, false),
    (cstring"#ct-origin-chain-side-panel button", hkControl, false),
    (cstring".ct-origin-breadcrumb-chip.ct-origin-breadcrumb-chip-placeholder", hkNone, false),
    (cstring".pixel-history-component .pixel-history-entry", hkControl, false),
    (cstring".point-list-row", hkControl, false),
    (cstring".problems-filter-btn", hkControl, false),
    (cstring".problems-row", hkControl, false),
    (cstring".ct-process-tree-entry", hkControl, false),
    (cstring".request-row", hkControl, false),
    (cstring".request-detail-resize-handle", hkDividerHorizontal, false),
    (cstring".request-detail-tab", hkControl, false),
    (cstring".scratchpad-value-view .scratchpad-value-close", hkControl, false),
    (cstring".search-mode-selector button", hkControl, false),
    (cstring".search-result-row", hkControl, false),
    (cstring".fif-icon-btn", hkControl, false),
    (cstring".fif-clear-btn", hkControl, false),
    (cstring".fif-option", hkControl, false),
    (cstring".fif-recent-item", hkControl, false),
    (cstring".fif-match-row", hkControl, false),
    (cstring".session-tab", hkControl, false),
    (cstring".session-tab-close", hkControl, false),
    (cstring".session-tab-add", hkControl, false),
    (cstring".session-tab-overflow", hkControl, false),
    (cstring".session-tab-overflow-item", hkControl, false),
    (cstring".shader-debug-component .shader-debug-toolbar button", hkControl, false),
    (cstring".sidebar-menu-items", hkControl, false),
    (cstring".dropdown-list-item", hkControl, false),
    (cstring".ct-picker-trigger", hkControl, false),
    (cstring".xterm-screen .xterm-rows div span", hkControl, false),
    (cstring".isonim-state .hide-other-process-watches", hkControl, false),
    (cstring".build-panel .build-ctrl-btn", hkControl, false),
    (cstring".build-panel .build-ctrl-btn.disabled", hkControl, true),
    (cstring".build-panel .build-history-btn", hkControl, false),
    (cstring".build-panel .build-history-menu .build-history-item", hkControl, false),
    (cstring"#build .build-location", hkControl, false),
    (cstring"#build-errors .build-location", hkControl, false),
    (cstring"#build .build-clickable", hkControl, false),
    (cstring"#build-errors .build-clickable", hkControl, false),
    (cstring"#status #status-base .status-button", hkControl, false),
    (cstring"#status #status-base .status-button-clicked", hkControl, false),
    (cstring"#status #status-base .whitespace-change", hkControl, false),
    (cstring"#status #status-base .build-identity", hkNone, false),
    (cstring"#status #status-base .test-certificate-status", hkControl, false),
    (cstring"#status #status-base .build-status", hkControl, false),
    (cstring".copy-file-path", hkControl, false),
    (cstring".event-line", hkControl, false),
    (cstring".ct-tab", hkTab, false),
    (cstring".ct-tab[data-disabled=""true""]", hkControl, true),
    (cstring"[data-ct-cut]", hkControl, false),
    (cstring".eventLog-column-grip", hkColumnSeparator, false),
    (cstring".terminal .terminal-line", hkControl, false),
    (cstring".terminal-output", hkControl, false),
    (cstring".terminal-input", hkControl, false),
    (cstring".context-menu-hint", hkNone, false),
    (cstring".code-editor .flow-loop-textarea", hkTextInput, false),
    (cstring".code-editor .instantiations-menu", hkControl, false),
    (cstring".code-editor .instantiations-menu .instantiation-location", hkControl, false),
    (cstring".gutter", hkControl, false),
    (cstring".gutter .gutter-line", hkNone, false),
    (cstring".gutter-runtest", hkControl, false),
    (cstring".gutter-runtest.running", hkNone, false),
    (cstring".trace-button", hkControl, false),
    (cstring".ct-column-breakpoint-marker", hkControl, false),
    (cstring".editor-menu-trace", hkControl, false),
    (cstring".editor-menu-close", hkControl, false),
    (cstring".jump", hkControl, false),
    (cstring".flow-loop-textarea", hkTextInput, false),
    (cstring".ct-toggle", hkControl, false),
    (cstring".ct-toggle-field", hkControl, false),
    (cstring".ct-toggle-field[data-disabled=""true""]", hkControl, true),
    (cstring".traceLog .trace-log-row", hkControl, false),
    (cstring".traceLog .trace-values", hkControl, false),
    (cstring".trace-main .view-overlays.focused", hkTextInput, false),
    (cstring".trace-main .view-overlays", hkTextInput, false),
    (cstring".trace-main .trace-view .trace-values", hkControl, false),
    (cstring".trace-main .trace-chevron .trace-chevron-arrow", hkControl, false),
    (cstring".trace-menu .run-trace-button", hkControl, false),
    (cstring".trace-menu .trace-menu-header .dropdown", hkControl, false),
    (cstring".trace-simple", hkControl, false),
    (cstring".trace-expand", hkControl, false),
    (cstring".width-border", hkDividerHorizontal, false),
    (cstring".height-border", hkColumnSeparator, false),
    (cstring".select-view-kind-button", hkControl, false),
    (cstring".select-view-kind-button.active", hkControl, false),
    (cstring".editor-trace", hkControl, false),
    (cstring"#save-trace", hkControl, false),
    (cstring".trace-overlay", hkTextInput, false),
    (cstring".expand-trace", hkControl, false),
    (cstring".unified-diff-file-header-link", hkControl, false),
    (cstring".monaco-editor .diff-hidden-lines .center", hkControl, false),
    (cstring".ct-diff-expand-menu-item", hkControl, false),
    (cstring".vcs-branch-current", hkControl, false),
    (cstring".deepreview-trace-select", hkControl, false),
    (cstring".vcs-toggle-button", hkControl, false),
    (cstring".vcs-diff-toggle .vcs-refresh", hkControl, false),
    (cstring".vcs-commit-header", hkControl, false),
    (cstring".vcs-commit-toggle", hkControl, false),
    (cstring".vcs-tip-copy", hkControl, false),
    (cstring".vcs-tip-copy.copied", hkNone, false),
    (cstring".vcs-accordion-file", hkControl, false),
    (cstring".vcs-commit-item", hkControl, false),
    (cstring".vcs-file-item", hkControl, false),
    (cstring".vcs-refresh", hkControl, false),
    (cstring".hunk-header-selectable", hkControl, false),
    (cstring".hunk-toolbar-button", hkControl, false),
    (cstring".hunk-toolbar-button-subtle", hkControl, false),
    (cstring".vcs-file-diff-btn", hkControl, false),
    (cstring".video-player-component.picker-active", hkControl, false),
    (cstring".video-player-component .video-player-button", hkControl, false),
    (cstring".video-player-component .video-player-scrub-range:disabled", hkControl, true),
    (cstring".welcome-screen-wrapper .welcome-screen.welcome-screen-loading", hkNone, false),
    (cstring".welcome-screen-wrapper .welcome-screen .start-options .start-option", hkControl, false),
    (cstring".welcome-screen-wrapper .welcome-screen .start-options .inactive-start-option", hkControl, true),
    (cstring".welcome-screen-wrapper .welcome-screen .recent-traces-list .recent-trace", hkControl, false),
    (cstring".welcome-screen-wrapper .welcome-screen .recent-folders-list .recent-folder", hkControl, false),
    (cstring".online-functionality-buttons .recent-trace-buttons", hkControl, false),
    (cstring".action-transaction-button", hkControl, false),
    ]
  SkippedSubtree = cstring".monaco-editor"
  DragProxy = cstring".lm_dragProxy"
  LegalDropIndicator = cstring".lm_dropTargetIndicator"

proc matches(el: JsEl; selector: cstring): bool {.importjs: "#.matches(#)".}
proc closest(el: JsEl; selector: cstring): JsEl {.importjs: "#.closest(#)".}
proc queryAll(el: JsEl; selector: cstring): seq[JsEl]
  {.importjs: "Array.from(#.querySelectorAll(#))".}
proc query(selector: cstring): JsEl {.importjs: "document.querySelector(#)".}
proc attr(el: JsEl; name: cstring): cstring {.importjs: "#.getAttribute(#)".}
proc setAttr(el: JsEl; name, value: cstring) {.importjs: "#.setAttribute(#, #)".}
proc removeAttr(el: JsEl; name: cstring) {.importjs: "#.removeAttribute(#)".}
proc isDisabledProp(el: JsEl): bool {.importjs: "(#.disabled === true)".}
proc shown(el: JsEl): bool
  {.importjs: "(getComputedStyle(#).display !== 'none')".}
proc isElement(el: JsEl): bool {.importjs: "(#?.nodeType === 1)".}
var
  documentRoot {.importc: "document.documentElement", nodecl.}: JsEl
  bodyEl {.importc: "document.body", nodecl.}: JsEl
proc target(r: JsRecord): JsEl {.importjs: "#.target".}
proc added(r: JsRecord): seq[JsEl] {.importjs: "Array.from(#.addedNodes)".}
proc removed(r: JsRecord): seq[JsEl] {.importjs: "Array.from(#.removedNodes)".}
proc evTarget(e: JsEv): JsEl {.importjs: "#.target".}
proc newObserver(cb: proc(records: seq[JsRecord])): JsObserver
  {.importjs: "new MutationObserver(#)".}
proc observeAll(o: JsObserver; root: JsEl) {.importjs:
  "#.observe(#, {childList: true, subtree: true, attributes: true, " &
  "attributeFilter: ['class', 'disabled', 'aria-disabled', 'data-disabled']})".}
proc listen(name: cstring; cb: proc(e: JsEv))
  {.importjs: "document.addEventListener(#, #, true)".}

proc validSelector(selector: cstring): bool {.importjs:
  "(() => { try { document.querySelector(#); return true } catch (e) { return false } })()".}

var
  bindings: seq[PointerBinding]
    ## The table, less any selector this engine refuses: one bad selector would
    ## otherwise throw from every `matches` and take the page's layout with it.
  everySelector: cstring

proc loadBindings() =
  var joined = ""
  var refused = 0
  for b in PointerBindings:
    if validSelector(b.selector):
      bindings.add b
      if joined.len > 0: joined.add ", "
      joined.add $b.selector
    else:
      inc refused
  everySelector = cstring(joined)
  documentRoot.setAttr("data-pointer-refused", cstring($refused))

proc hitTargetOf(el: JsEl): HitTarget =
  ## The DOM's answer: the LAST binding that matches, as the last rule of equal
  ## weight won in the stylesheets these came from.
  for i in countdown(bindings.high, 0):
    let b = bindings[i]
    if el.matches(b.selector):
      return HitTarget(kind: b.kind,
                       disabled: b.disabled or el.isDisabledProp or
                                 el.attr("aria-disabled") == cstring"true" or
                                 el.attr("data-disabled") == cstring"true")

proc stamp(el: JsEl) =
  el.setAttr("data-pointer", cstring(pointerShapeOf(el.hitTargetOf).cssName))

proc stampTree(root: JsEl) =
  if not root.isElement or not root.closest(SkippedSubtree).isNil:
    return
  if root.matches(everySelector):
    root.stamp
  for el in root.queryAll(everySelector):
    el.stamp

proc setGesture(gesture: PointerGesture) =
  ## §4: the shape on the body, over every element, for the gesture's length.
  if gesture.kind == pgNone:
    bodyEl.removeAttr("data-pointer-gesture")
  else:
    bodyEl.setAttr("data-pointer-gesture",
                     cstring(pointerShapeOf(HitTarget(), gesture).cssName))

proc tabDragGesture(): PointerGesture =
  let indicator = query(LegalDropIndicator)
  PointerGesture(kind: pgTabDrag,
                 legalDrop: not indicator.isNil and indicator.shown)

proc dragGestureAt(el: JsEl): PointerGesture =
  ## A press that starts a held gesture, by what it landed on.
  if not el.isElement:
    return
  let hit = el.closest(everySelector)
  if not hit.isElement:
    return
  case pointerShapeOf(hit.hitTargetOf)
  of psColResize: PointerGesture(kind: pgColumnDrag)
  of psRowResize: PointerGesture(kind: pgRowDrag)
  else: PointerGesture()

proc installPointerStamp*() =
  ## Stamp what is on the page and everything rendered after it, and watch the
  ## presses and the drag proxy that begin a gesture.
  loadBindings()
  stampTree(documentRoot)
  let observer = newObserver(proc(records: seq[JsRecord]) =
    for record in records:
      if record.added.len > 0 or record.removed.len > 0:
        for node in record.added:
          stampTree(node)
          if node.isElement and node.matches(DragProxy):
            setGesture(tabDragGesture())
        for node in record.removed:
          if node.isElement and node.matches(DragProxy):
            setGesture(PointerGesture())
      elif record.target.isElement and record.target.matches(everySelector):
        stampTree(record.target))
  observer.observeAll(documentRoot)
  listen("mousedown", proc(e: JsEv) =
    setGesture(dragGestureAt(e.evTarget)))
  listen("mousemove", proc(e: JsEv) =
    if not query(DragProxy).isNil:
      setGesture(tabDragGesture()))
  listen("mouseup", proc(e: JsEv) =
    setGesture(PointerGesture()))
