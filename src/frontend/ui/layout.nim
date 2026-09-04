import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  state, editor, debug, menu, status, command, search_results, shell, session_tabs, build, errors, step_list,
  welcome_screen,
  # The five panes whose mount was moved into this file's component factory.
  # `state` was already imported; `calltrace`, `trace`, `event_log` and
  # `terminal_output` are new here and are imported for exactly one symbol
  # each — their `tryMountIsoNim…` proc. See the factory arms below.
  calltrace, trace, event_log, terminal_output,
  calltrace_editor, repl, low_level_code, request_panel, trace_log, scratchpad, filesystem,
  test_results, constraints,
  frame_viewer, pixel_history, shader_debug, video_player,
  vcs, unified_diff, verification,
  agent_activity, agent_workspace,
  session_switch, auto_hide, auto_hide_overlay,
  caption_bar_progress,
  ../[ types, renderer, config, utils ],
  ../index/layout_config_repair,
  # The per-mode layout register and its stores. `stateChanged` writes the
  # live arrangement into the current mode's cell; `loadLayoutSafely` degrades
  # to the current mode's DEFAULT rather than to the raw bundled tree.
  mode_layouts,
  ../lib/[ logging, misc_lib, jslib ]

# `panel_transfer` moves a pane between APPLICATION WINDOWS over Electron IPC,
# and its own guard declares it absent from a web build because `capMultiWindow`
# is absent — not because its call sites await migration. A tab has no second
# window to send a pane to.
#
# So this import is conditional rather than the module being ported, which is
# what its guard asks for. `registerPanelAttachHandler` is the only symbol
# `layout.nim` uses from it (one call site, guarded to match), so the web build
# simply never installs a handler for an event no web build can raise.
when not defined(ctWeb):
  import panel_transfer

import kdom except Location
from dom import Element, getAttribute, Node, preventDefault, document,
                getElementById, querySelectorAll, querySelector

template dispatchLayoutUpdated() =
  {.emit: """
    window.dispatchEvent(new CustomEvent('ct:layoutUpdated'));
  """.}

type
  ContextHandler* = proc(tab: js, args: seq[string])

# context handlers for each shortcut
var contextHandlers*: JsAssoc[cstring, JsAssoc[cstring, ContextHandler]] = JsAssoc[cstring, JsAssoc[cstring, ContextHandler]]{} # app-global

const RESULT_LIMIT = 20

var activeDraggedItem: GoldenContentItem

# FIND

proc historyFind*(tab: js, args: seq[string]) =
  log "history find"

proc focus: js = # nil?
  if data.ui.focusHistory.len > 0:
    return data.ui.focusHistory[^1]
  else:
    return nil

proc changeFocus*(panel: js) =
  if data.ui.focusHistory.len == 0 or panel != data.ui.focusHistory[^1]:
    data.ui.focusHistory.add(panel)

proc contextBind*(shortcut: string, arg: js, handler: ContextHandler) =
  var c = contextHandlers[shortcut]
  if c.isNil:

    c = JsAssoc[cstring, ContextHandler]{}
    contextHandlers[shortcut] = c

    Mousetrap.`bind`(cstring(shortcut)) do ():
      var focused = focus()
      if focused.isNil: return

proc configureFind =
  discard

var document {.importc.}: js

proc enforceMinStackWidth*(layout: GoldenLayout) =
  ## Walk every stack in the layout tree and set each component item's
  ## minimum size to MIN_STACK_PX.
  ##
  ## GL uses the ACTIVE component's minSize as the stack's effective minimum,
  ## not the sum — so the minimum must be set on every component individually
  ## (not divided by n) to ensure the stack stays at least MIN_STACK_PX wide
  ## regardless of which tab is currently active.
  ## SizeUnitEnum.Pixel is the string "px" in GL 2.x.
  {.emit: """
    const MIN_STACK_PX = 200;
    const MIN_STACK_PX_H = 50;
    function visit(item) {
      if (!item || !item.contentItems) return;
      if (item.isStack) {
        const n = item.contentItems.length;
        if (n > 0) {
          for (const ci of item.contentItems) {
            ci.minSize     = `layout`.isColumn ? MIN_STACK_PX_H : MIN_STACK_PX;
            ci.minSizeUnit = "px";
          }
        }
      } else {
        for (const ci of item.contentItems) visit(ci);
      }
    }
    if (`layout`.groundItem) visit(`layout`.groundItem);
  """.}

proc newGoldenLayout*(
  root: JsObject,
  bindComponentCallback: proc,
  unbindComponentCallback: proc
): GoldenLayout {.importjs: "new GoldenLayout(#, #, #)".}

proc convertTabTitle(content: cstring): cstring =
  ## Derive a human-readable uppercase tab title from a Content enum name.
  ## Special-case overrides are listed first; the generic fallback splits
  ## CamelCase into separate uppercase words (e.g. "EventLog" -> "EVENT LOG").
  if content == cstring"BuildErrors":
    return cstring"PROBLEMS"
  if content == cstring"VCS":
    return cstring"VCS"
  if content == cstring"Filesystem":
    return cstring"FILES"
  # TESTS, NOT "TEST RESULTS", and the shorter name is what the pane became
  # rather than a tidy-up. It now sits in the FILES stack beside FILES and VCS
  # (`paneHomesForMode`), where the tab strip is narrow and shared: two words
  # take a third of the strip from the two panes it is nested with, and a title
  # that has to be truncated is a title nobody reads. "TESTS" also says what the
  # pane IS — every test in the project, listed, whether or not a run has
  # happened — where "TEST RESULTS" describes only the state it is in after one.
  #
  # An override here rather than a rename of `Content.TestResults`: the enum
  # name is the wire identity, persisted inside every saved layout's
  # `componentState.content`, and this proc is exactly the seam that exists so a
  # caption can differ from it. `Filesystem` -> `FILES` above is the same move.
  if content == cstring"TestResults":
    return cstring"TESTS"

  var title: cstring = ""
  var label = content
  let pattern = regex("[A-Z][a-z0-9]*")
  var matches = label.matchAll(pattern)

  return (matches.mapIt(it[0].toUpperCase())).join(cstring" ")

proc clearSaveHistoryTimeout(editorService: EditorService) =
  if editorService.hasSaveHistoryTimeout:
    windowClearTimeout(editorService.saveHistoryTimeoutId)
    editorService.hasSaveHistoryTimeout = false
    editorService.saveHistoryTimeoutId = -1

proc addTabToHistory(editorService: EditorService, tab: EditorViewTabArgs) =
  cdebug "tabs: addTabToHistory " & $tab
  editorService.tabHistory = editorService.tabHistory.filterIt(
    it.name != tab.name
  )
  editorService.tabHistory.add(tab)
  editorService.historyIndex = editorService.tabHistory.len - 1
  cdebug "tabs: addTabToHistory: historyIndex -> " & $editorService.historyIndex


proc eventuallyUpdateTabHistory(editorService: EditorService, tab: EditorViewTabArgs) =
  editorService.clearSaveHistoryTimeout()
  editorService.saveHistoryTimeoutId = windowSetTimeout(
    proc = editorService.addTabToHistory(tab),
    editorService.switchTabHistoryLimit)
  editorService.hasSaveHistoryTimeout = true

type
  ContextMenuOption = object
    label: cstring
    action: proc(container: GoldenContainer, state: GoldenItemState)

# ---------------------------------------------------------------------------
# M21: "Send to Window" context menu on GL tabs
# ---------------------------------------------------------------------------

proc addPanelTransferContextMenu(tab: GoldenTab, contentItem: GoldenContentItem) =
  ## Attach a right-click context menu to a GL tab element that offers
  ## pin (left/bottom/right), close, and maximise actions.
  let tabElement = tab.element
  if tabElement.isNil or tabElement.isUndefined:
    return

  tabElement.addEventListener(cstring"contextmenu", proc(event: JsObject) =
    event.preventDefault()
    let x = event.clientX.to(int)
    let y = event.clientY.to(int)
    let capturedItem = contentItem
    let stack = cast[js](capturedItem.parent)
    let maxLabel =
      if cast[bool](stack.isMaximised): cstring"Minimise container"
      else: cstring"Maximise container"
    showContextMenu(@[
      ContextMenuItem(name: cstring"Pin to Left", hint: cstring"",
        handler: proc(ev: kdom.Event) =
          pinPanel(data.ui.layout, capturedItem, AutoHideEdge.Left)),
      ContextMenuItem(name: cstring"Pin to Bottom", hint: cstring"",
        handler: proc(ev: kdom.Event) =
          pinPanel(data.ui.layout, capturedItem, AutoHideEdge.Bottom)),
      ContextMenuItem(name: cstring"Pin to Right", hint: cstring"",
        handler: proc(ev: kdom.Event) =
          pinPanel(data.ui.layout, capturedItem, AutoHideEdge.Right)),
      ContextMenuItem(name: cstring"Close", hint: cstring"",
        handler: proc(ev: kdom.Event) =
          capturedItem.parent.removeChild(capturedItem)),
      ContextMenuItem(name: maxLabel, hint: cstring"",
        handler: proc(ev: kdom.Event) =
          let s = cast[js](capturedItem.parent)
          if cast[bool](s.isMaximised): s.minimise()
          else: s.maximise())
    ], x, y))

let commonContextMenuOptions: seq[ContextMenuOption] = @[
  ContextMenuOption(
    label: "Duplicate Tab",
    action: proc(container: GoldenContainer, state: GoldenItemState) = cwarn "TODO create new tab of the same type")
]

let editorSpecificContextMenuOptions: seq[ContextMenuOption] = @[
  ContextMenuOption(
    label: "Copy full path",
    action: proc(container: GoldenContainer, state: GoldenItemState) = clipboardCopy(state.label))
]

proc createContextMenuFromOptions(
  container: GoldenContainer,
  state: GoldenItemState,
  contextMenuOptions: seq[ContextMenuOption]
): ContextMenu =

  var
    options: JsAssoc[int, cstring] = JsAssoc[int, cstring]{}
    actions: JsAssoc[int, proc()] = JsAssoc[int, proc()]{}

  for i, option in contextMenuOptions:
    options[i] = option.label
    actions[i] = proc() {.closure.} = option.action(container, state)

  return ContextMenu(
    options: options,
    actions: actions
  )

proc injectPinButton(tabElement: JsObject, onPin: proc()) =
  ## Insert a pin button to the left of the GL close button inside a tab element.
  ## Clicking it calls `onPin`, which sends the panel to the auto-hide sidebar.
  if tabElement.isNil or tabElement.isUndefined:
    return
  {.emit: """
    var _pinBtn = document.createElement('div');
    _pinBtn.className = 'lm_pin_tab';
    var _closeEl = `tabElement`.querySelector('.lm_close_tab');
    if (_closeEl) {
      `tabElement`.insertBefore(_pinBtn, _closeEl);
    } else {
      `tabElement`.appendChild(_pinBtn);
    }
    var _onPin = `onPin`;
    _pinBtn.addEventListener('click', function(e) {
      e.stopPropagation();
      _onPin();
    });
  """.}


proc markPanelTab(tabElement: JsObject, content: Content) =
  ## Stamp `data-ct-panel-content` on a GoldenLayout tab so a panel can find
  ## its own tab without matching on the title text.
  ##
  ## Matching on text is what the docked-panel outline and the auto-hide
  ## overlay do (`auto_hide.nim`, and `layout.nim`'s outline geometry), and it
  ## is the reason a tab title is effectively an identity key here: append one
  ## character to it and those lookups stop resolving, along with the several
  ## Playwright specs that compare `.lm_title` text exactly. A panel that wants
  ## to decorate its own tab — the calltrace busy state is the first — needs a
  ## handle that is not the title, or the decoration and the identity fight.
  if tabElement.isNil or tabElement.isUndefined:
    return
  let name = cstring($content)
  {.emit: """
    `tabElement`.setAttribute('data-ct-panel-content', `name`);
  """.}

proc setupDropdownDismissListeners() =
  ## Close an open dropdown when Escape is pressed or the pointer goes down
  ## outside it.  Without this the branch picker stayed open until its own
  ## trigger was clicked again, so it could be left hanging over the panel while
  ## the user worked elsewhere.
  ##
  ## Dismissal re-clicks the menu's own trigger rather than hiding the element:
  ## each dropdown's open state lives in its ViewModel, and hiding the DOM alone
  ## would leave that state saying "open" — the next click on the trigger would
  ## then appear to do nothing.
  ##
  ## Listeners are in the capture phase and never call `preventDefault`, so the
  ## click that dismisses a menu still reaches whatever it landed on.
  {.emit: """
    (function () {
      // One entry per dropdown:
      //   container — the whole control; a pointer landing inside it is not a
      //               dismissal, so the menu's own rows stay clickable;
      //   open      — a selector that exists only while the menu is open;
      //   trigger   — what to re-click to close it.  Null means "the element
      //               immediately before the open menu", which is how the
      //               event-log filters are built.
      //
      // Context menus are absent on purpose: `viewmodel/views/context_menu_bridge`
      // already dismisses them on Escape and on any document click, and driving
      // them from here as well would close them twice.
      var DISMISSIBLE = [
        { container: '.vcs-branch-picker',
          open: '.vcs-branch-current-open',
          trigger: '.vcs-branch-current-open' },
        { container: '.session-tab-bar',
          open: '.session-tab-bar.overflow-open',
          trigger: '.session-tab-bar.overflow-open .session-tab-overflow' },
        { container: '.ct-picker',
          open: '.ct-picker-trigger--open',
          trigger: '.ct-picker-trigger--open' },
        { container: '.hamburger-dropdown-container',
          open: '.dropdown-list.active',
          trigger: null }
      ];

      function triggerFor(entry) {
        if (entry.trigger !== null) { return document.querySelector(entry.trigger); }
        var opened = document.querySelector(entry.open);
        return opened === null ? null : opened.previousElementSibling;
      }

      function closeOpenMenus(isInside) {
        for (var i = 0; i < DISMISSIBLE.length; i++) {
          var entry = DISMISSIBLE[i];
          if (document.querySelector(entry.open) === null) { continue; }
          if (isInside !== null && isInside(entry.container)) { continue; }
          var trigger = triggerFor(entry);
          if (trigger !== null) { trigger.click(); }
        }
      }

      document.addEventListener('mousedown', function (ev) {
        var target = ev.target;
        if (!target || !target.closest) { return; }
        closeOpenMenus(function (container) {
          return target.closest(container) !== null;
        });
      }, true);

      document.addEventListener('keydown', function (ev) {
        if (ev.key !== 'Escape' && ev.keyCode !== 27) { return; }
        closeOpenMenus(null);
      }, true);
    })();
  """.}

proc setupSelectedPanelOutline() =
  ## Draw the selected panel's outline as ONE stroked SVG path.
  ##
  ## The tab's concave connectors are painted by box-shadows, and a shadow is a
  ## fill with no edge — nothing to put a border on.  Every CSS attempt to
  ## outline the shape therefore stroked some *other* rectangle and cut across
  ## the curve.  A single path sidesteps that entirely: tab, both connectors and
  ## the panel are one continuous outline, so the joins are exact by
  ## construction rather than by alignment.
  ##
  ## The path is rebuilt from measured geometry, so it follows any tab width,
  ## any radius and any panel size.  Stroke colour and width come from the
  ## stylesheet (`.ct-selected-outline`), keeping them on design tokens.
  {.emit: """
    (function () {
      var SVG_NS = 'http://www.w3.org/2000/svg';
      var OUTLINE_CLASS = 'ct-selected-outline';

      // Each corner carries its own radius: they are not interchangeable.  The
      // top-left is squared when the tab is flush against it, and reading one
      // corner for all four drew a square outline over a rounded panel.
      function buildPath(w, h, tabX0, tabX1, tabTop, panelTop, panelBottom,
                         tabTL, tabTR, panelTL, panelTR, panelBR, panelBL,
                         connR, inset, tabIsFirst, tabIsLast) {
        // Inset by half the stroke so the line sits INSIDE the shape: SVG
        // centres a stroke on its path.
        var l = inset, r = w - inset, b = panelBottom - inset, t = tabTop + inset;
        var x0 = tabX0 + inset, x1 = tabX1 - inset, pt = panelTop + inset;

        // Clockwise from the tab's top-left. Convex corners sweep 1, the two
        // concave connectors sweep 0 — that flag is the whole difference
        // between a rounded corner and the curve that flows into the panel.
        var d = [];
        d.push('M', x0 + tabTL, t);
        d.push('L', x1 - tabTR, t);
        d.push('A', tabTR, tabTR, 0, 0, 1, x1, t + tabTR);

        // THE RIGHT CONNECTOR NEEDS ROOM, AND A LAST TAB HAS NONE.
        //
        // Reported as *"when the last tab in a pane is selected, there is a
        // bit of discontinuity in the border on the right, just below the
        // point where the right border of the tabbar label for the tab
        // begins."*  Measured, on a 400-wide stack whose last tab is active:
        // the path ran `L 399.5 14.5`, arced to `405.5 20.5` — SIX PIXELS PAST
        // the panel's right edge at 399.5 — and then went `L 399.5 20.5`
        // straight back.  A spur out and back, starting just under the tab's
        // top-right corner.  That is the report, in the place the report puts
        // it.
        //
        // The stylesheet already knew: `golden_layout.styl` switches the last
        // active tab's `::after` connector off and squares the panel's
        // top-right radius, both keyed on `:last-child`.  Only the path
        // builder was never told, so it drew a connector into space that the
        // paint had already given up, and then a degenerate `A 0 0` where the
        // squared corner used to be.
        //
        // This is the mirror of the `tabIsFirst` branch below, which has
        // always been here.  It was written once already — on the branch this
        // outline came from — and lost in the same merge that dropped the
        // docked outline; grafted back with it.
        //
        // The `Math.min` is the general form rather than a special case for
        // the last tab: any tab whose right edge is within `connR` of the
        // panel's corner has less room than the curve needs, and the clamp is
        // what stops the path doubling back for all of them.
        var cRight = tabIsLast ? 0 : Math.max(0, Math.min(connR, r - panelTR - x1));
        if (cRight > 0.01) {
          d.push('L', x1, pt - cRight);
          d.push('A', cRight, cRight, 0, 0, 0, x1 + cRight, pt);
          d.push('L', r - panelTR, pt);
          d.push('A', panelTR, panelTR, 0, 0, 1, r, pt + panelTR);
        } else {
          // Flush: the tab's right edge and the panel's are one line, so run
          // straight down it.
          d.push('L', r, pt);
        }
        d.push('L', r, b - panelBR);
        d.push('A', panelBR, panelBR, 0, 0, 1, r - panelBR, b);
        d.push('L', l + panelBL, b);
        d.push('A', panelBL, panelBL, 0, 0, 1, l, b - panelBL);
        if (tabIsFirst) {
          // The tab is flush with the panel's left edge: one straight run from
          // the panel's bottom-left up the shared edge into the tab.  No corner
          // to round, and no connector — there is nothing to its left.
          d.push('L', l, t + tabTL);
        } else {
          d.push('L', l, pt + panelTL);
          d.push('A', panelTL, panelTL, 0, 0, 1, l + panelTL, pt);
          // The same clamp on the left, for the same reason: a tab that starts
          // within `connR` of the panel's top-left corner has no room for the
          // curve either, and an unclamped one doubles back past `l`.
          var cLeft = Math.max(0, Math.min(connR, x0 - panelTL - l));
          if (cLeft > 0.01) {
            d.push('L', x0 - cLeft, pt);
            d.push('A', cLeft, cLeft, 0, 0, 0, x0, pt - cLeft);
          } else {
            d.push('L', x0, pt);
          }
          d.push('L', x0, t + tabTL);
        }
        d.push('A', tabTL, tabTL, 0, 0, 1, x0 + tabTL, t);
        d.push('Z');
        return d.join(' ');
      }

      function radiusOf(el, pseudo, prop) {
        var v = parseFloat(window.getComputedStyle(el, pseudo || null)[prop]);
        return isFinite(v) ? v : 0;
      }

      // The connector radius, in pixels, for the docked outline below.
      //
      // A docked panel has no GoldenLayout tab to read a `::before` radius off,
      // so the value rides on the stroked path's own `border-top-left-radius`
      // (see golden_layout.styl) instead: that resolves to pixels, where a
      // custom property would come back as its raw `em`.
      function connectorRadius() {
        var probe = document.querySelector(
          '.ct-selected-outline path, .ct-docked-outline path, .ct-overlay-outline path');
        if (probe !== null) {
          var v = parseFloat(window.getComputedStyle(probe).borderTopLeftRadius);
          if (isFinite(v) && v > 0) { return v; }
        }
        return 6;
      }

      function clearOutlines(except) {
        var existing = document.querySelectorAll('.' + OUTLINE_CLASS);
        for (var i = 0; i < existing.length; i++) {
          if (existing[i] !== except) { existing[i].remove(); }
        }
      }

      function update() {
        // Exactly one outline is on screen at a time, and this is the order of
        // precedence: the slide-in overlay first, then a selected docked panel,
        // then the GoldenLayout stack.
        //
        // The overlay comes first because it is on top of everything else and
        // is only ever on screen while the user is pointing at it.  Nothing
        // clears `ct-docked-focused` or GL's `.lm_focused` when the overlay
        // opens — the strip tab that opens it is inside neither a
        // `.auto-hide-docked` nor an `.lm_stack`, so the click-to-focus
        // listener below does not fire — which means without this branch the
        // overlay's outline and the outline of whatever was focused before it
        // would both be drawn.  That is the same clash the docked branch
        // already exists to prevent, one level up.
        if (updateOverlayOutline()) {
          clearOutlines(null); removeDockedOutline(); return;
        }
        removeOverlayOutline();

        // A selected docked panel is outlined by `updateDockedOutline` below.
        // It lives outside the GoldenLayout tree, so GL keeps its own
        // `.lm_focused` while that is so, and drawing the stack outline as well
        // would put two selection cues on screen at once.
        if (document.querySelector('.auto-hide-docked.ct-docked-focused') !== null) {
          clearOutlines(null); updateDockedOutline(); return;
        }
        removeDockedOutline();

        var stack = document.querySelector('.lm_stack:has(> .lm_header.lm_focused)');
        if (stack === null) { clearOutlines(null); return; }

        var tab = stack.querySelector(':scope > .lm_header .lm_tab.lm_active');
        var items = stack.querySelector(':scope > .lm_items');
        if (tab === null || items === null) { clearOutlines(null); return; }

        var sr = stack.getBoundingClientRect();
        var tr = tab.getBoundingClientRect();
        var ir = items.getBoundingClientRect();
        if (sr.width < 1 || ir.height < 1) { clearOutlines(null); return; }

        var svg = stack.querySelector(':scope > .' + OUTLINE_CLASS);
        if (svg === null) {
          svg = document.createElementNS(SVG_NS, 'svg');
          svg.setAttribute('class', OUTLINE_CLASS);
          svg.appendChild(document.createElementNS(SVG_NS, 'path'));
          stack.appendChild(svg);
        }
        clearOutlines(svg);

        var path = svg.firstChild;
        var strokeWidth = parseFloat(window.getComputedStyle(path).strokeWidth) || 1;

        svg.setAttribute('viewBox', '0 0 ' + sr.width + ' ' + sr.height);
        svg.setAttribute('width', sr.width);
        svg.setAttribute('height', sr.height);

        path.setAttribute('d', buildPath(
          sr.width, sr.height,
          tr.left - sr.left, tr.right - sr.left, tr.top - sr.top,
          ir.top - sr.top, ir.bottom - sr.top,
          radiusOf(tab, null, 'borderTopLeftRadius'),
          radiusOf(tab, null, 'borderTopRightRadius'),
          radiusOf(items, null, 'borderTopLeftRadius'),
          radiusOf(items, null, 'borderTopRightRadius'),
          radiusOf(items, null, 'borderBottomRightRadius'),
          radiusOf(items, null, 'borderBottomLeftRadius'),
          radiusOf(tab, '::before', 'borderBottomRightRadius') || 10,
          strokeWidth / 2,
          tab.parentElement !== null && tab.parentElement.firstElementChild === tab,
          tab.parentElement !== null && tab.parentElement.lastElementChild === tab));
      }

      // ---------------------------------------------------------------------
      // The same outline, for a docked auto-hide panel.
      //
      // A docked panel is the GoldenLayout case turned on its side: the strip
      // tab plays the part of the GL tab and juts out of the panel's edge, so
      // the line has to run around the tab and not stop at the panel.  Same
      // shape, same concave connectors, same tokens — only the axis differs.
      //
      // It is built here rather than in CSS for the same reason the GL outline
      // is: an inset shadow can only follow the one box it is set on, and the
      // panel and its tab are two boxes traced as one shape.
      // ---------------------------------------------------------------------
      var DOCKED_OUTLINE_CLASS = 'ct-docked-outline';

      function radii(el) {
        var cs = window.getComputedStyle(el);
        var f = function (v) { var n = parseFloat(v); return isFinite(n) ? n : 0; };
        return { tl: f(cs.borderTopLeftRadius), tr: f(cs.borderTopRightRadius),
                 br: f(cs.borderBottomRightRadius), bl: f(cs.borderBottomLeftRadius) };
      }

      function removeDockedOutline() {
        // Document-wide: an outline left behind by an earlier build may still be
        // parked on the body rather than in `#root-container`.
        var old = document.querySelectorAll('.' + DOCKED_OUTLINE_CLASS);
        for (var i = 0; i < old.length; i++) { old[i].remove(); }
      }

      // The panel alone: a plain rounded rectangle.  Used whenever the tab that
      // opened the panel cannot be found.
      function dockedPanelOnlyPath(p, rr, inset) {
        var l = p.left + inset, r = p.right - inset, t = p.top + inset, b = p.bottom - inset;
        return ['M', l + rr.tl, t,
                'L', r - rr.tr, t, 'A', rr.tr, rr.tr, 0, 0, 1, r, t + rr.tr,
                'L', r, b - rr.br, 'A', rr.br, rr.br, 0, 0, 1, r - rr.br, b,
                'L', l + rr.bl, b, 'A', rr.bl, rr.bl, 0, 0, 1, l, b - rr.bl,
                'L', l, t + rr.tl, 'A', rr.tl, rr.tl, 0, 0, 1, l + rr.tl, t, 'Z'].join(' ');
      }

      // Panel plus the strip tab that juts out of one side of it.
      //
      // `side` is the side the tab is on: 'left' for the left strip, 'right'
      // for the right one.  The traversal is written for the left strip and
      // mirrored horizontally for the right, so the shape is described once.
      //
      // A tab flush with the panel's top or bottom has no room for a connector
      // on that end — the curve would reach past the panel and the path would
      // double back on itself.  There the tab and the panel share one straight
      // edge instead, which is what the GL outline does for a first tab.
      function dockedWithTabPath(p, tb, rr, tr_, inset, side) {
        var mirror = (side === 'right');
        // Reflection about the panel's own horizontal centre.  The traversal
        // below is written once, for a tab on the panel's LEFT, and `px` turns
        // it into the right-hand case on the way out.
        var px = function (x) { return mirror ? (p.left + p.right) - x : x; };
        // Every coordinate below is therefore in reflected space, where the
        // traversal always steps the same way; `px` alone does the flipping,
        // so there is no second direction to carry.
        var sgn = 1;
        var CV = mirror ? 0 : 1;   // convex corner sweep
        var CC = mirror ? 1 : 0;   // concave connector sweep

        // In reflected space the panel's tab-side edge is always its left one
        // and its far edge always its right, whichever strip it is docked
        // against: `px` maps `p.left` back onto `p.right` for a right strip,
        // because the panel's two edges are each other's reflection.
        var L  = p.left + inset;    // the panel edge the tab attaches to
        var R  = p.right - inset;   // the opposite edge
        var T  = p.top + inset, B = p.bottom - inset;
        // THE TAB IS NOT SYMMETRIC ABOUT THAT CENTRE, so unlike the panel's own
        // two edges it cannot be reflected by reading the other end of it — it
        // has to be reflected outright.
        //
        // This is the defect that was here.  `tb.right` was passed in
        // unreflected and then sent through `px` anyway, which put the tab at
        // its mirror image: hanging off the panel's INNER edge, into the
        // layout, instead of out to the strip it belongs to.  The panel
        // rectangle itself was traced correctly, so on the right-hand strip the
        // outline read as a line going somewhere strange rather than as a line
        // that was missing — and only on that one strip, since `mirror` is
        // false for the left one and this expression collapses to `tb.left`.
        var TO = (mirror ? (p.left + p.right) - tb.right : tb.left) + inset;
        var tT = tb.top + inset, tB = tb.bottom - inset;

        // Panel corners, and the two tab corners on its outer side.
        var pTL = mirror ? rr.tr : rr.tl, pTR = mirror ? rr.tl : rr.tr;
        var pBR = mirror ? rr.bl : rr.br, pBL = mirror ? rr.br : rr.bl;
        var tTL = mirror ? tr_.tr : tr_.tl, tBL = mirror ? tr_.br : tr_.bl;

        // One radius for every connector, clamped by the room actually there:
        // along the panel's edge (so the curve cannot run off its end) and
        // across the tab's edge (so it lands on the flat, not on its corner).
        var CONN = connectorRadius();
        var tabRoom = Math.abs(L - TO) - Math.max(tTL, tBL);
        var flushTop = (tT - T) < 1.5;
        var flushBot = (B - tB) < 1.5;
        var cT = flushTop ? 0 : Math.max(0, Math.min(CONN, tT - T, tabRoom));
        var cB = flushBot ? 0 : Math.max(0, Math.min(CONN, B - tB, tabRoom));

        var d = [];
        // Top edge — from the tab's outer corner when the two share it.
        if (flushTop) {
          d.push('M', px(TO + sgn * tTL), T);
        } else {
          d.push('M', px(L + sgn * pTL), T);
        }
        d.push('L', px(R - sgn * pTR), T);
        d.push('A', pTR, pTR, 0, 0, CV, px(R), T + pTR);
        d.push('L', px(R), B - pBR);
        d.push('A', pBR, pBR, 0, 0, CV, px(R - sgn * pBR), B);

        // Bottom edge, then up the left-hand profile.
        if (flushBot) {
          d.push('L', px(TO + sgn * tBL), B);
          d.push('A', tBL, tBL, 0, 0, CV, px(TO), B - tBL);
        } else {
          d.push('L', px(L + sgn * pBL), B);
          d.push('A', pBL, pBL, 0, 0, CV, px(L), B - pBL);
          d.push('L', px(L), tB + cB);
          if (cB > 0.01) { d.push('A', cB, cB, 0, 0, CC, px(L - sgn * cB), tB); }
          else { d.push('L', px(L), tB); }
          d.push('L', px(TO + sgn * tBL), tB);
          d.push('A', tBL, tBL, 0, 0, CV, px(TO), tB - tBL);
        }

        // Up the tab's outer edge.
        d.push('L', px(TO), (flushTop ? T : tT) + tTL);
        d.push('A', tTL, tTL, 0, 0, CV, px(TO + sgn * tTL), (flushTop ? T : tT));

        if (!flushTop) {
          d.push('L', px(L - sgn * cT), tT);
          if (cT > 0.01) { d.push('A', cT, cT, 0, 0, CC, px(L), tT - cT); }
          else { d.push('L', px(L), tT); }
          d.push('L', px(L), T + pTL);
          d.push('A', pTL, pTL, 0, 0, CV, px(L + sgn * pTL), T);
        }
        d.push('Z');
        return d.join(' ');
      }

      // The bottom edge: the panel sits above its tab rather than beside it, and
      // the tabs live in the status bar (`#auto-hide-bottom-strip`) instead of a
      // strip alongside.  Same shape, same connectors, turned a quarter turn.
      function dockedWithTabPathBottom(p, tb, rr, tr_, inset) {
        var L = p.left + inset, R = p.right - inset;
        var T = p.top + inset, B = p.bottom - inset;
        var tL = tb.left + inset, tR = tb.right - inset, tB = tb.bottom - inset;

        // Same radius as everywhere else, clamped by the room along the panel's
        // bottom edge and by the height of the tab's own side edge.
        var CONN = connectorRadius();
        var tabRoom = (tB - B) - Math.max(tr_.bl, tr_.br);
        var cL = Math.max(0, Math.min(CONN, tL - L, tabRoom));
        var cR = Math.max(0, Math.min(CONN, R - tR, tabRoom));

        var d = [];
        d.push('M', L + rr.tl, T);
        d.push('L', R - rr.tr, T);
        d.push('A', rr.tr, rr.tr, 0, 0, 1, R, T + rr.tr);
        d.push('L', R, B - rr.br);
        d.push('A', rr.br, rr.br, 0, 0, 1, R - rr.br, B);
        // Leftward along the panel's bottom, then down and around the tab.
        d.push('L', tR + cR, B);
        if (cR > 0.01) { d.push('A', cR, cR, 0, 0, 0, tR, B + cR); }
        else { d.push('L', tR, B); }
        d.push('L', tR, tB - tr_.br);
        d.push('A', tr_.br, tr_.br, 0, 0, 1, tR - tr_.br, tB);
        d.push('L', tL + tr_.bl, tB);
        d.push('A', tr_.bl, tr_.bl, 0, 0, 1, tL, tB - tr_.bl);
        d.push('L', tL, B + cL);
        if (cL > 0.01) { d.push('A', cL, cL, 0, 0, 0, tL - cL, B); }
        else { d.push('L', tL, B); }
        // And on along the panel's bottom to close.
        d.push('L', L + rr.bl, B);
        d.push('A', rr.bl, rr.bl, 0, 0, 1, L, B - rr.bl);
        d.push('L', L, T + rr.tl);
        d.push('A', rr.tl, rr.tl, 0, 0, 1, L + rr.tl, T);
        d.push('Z');
        return d.join(' ');
      }

      function updateDockedOutline() {
        removeDockedOutline();
        var panel = document.querySelector('.auto-hide-docked.docked-open.ct-docked-focused');
        if (panel === null) { return; }

        var pr = panel.getBoundingClientRect();
        if (pr.width < 1 || pr.height < 1) { return; }

        // Trim the resize grip off the panel's edge.
        //
        // It is the divider between this panel and whatever it is docked
        // against — GoldenLayout's own `.lm_splitter` in all but name — but it
        // lives INSIDE the docked container, so the container's rect covers it
        // and the outline was drawn around the gap as though it were part of
        // the panel.  A GL panel's outline stops at its own edge and leaves the
        // splitter beside it alone; this one now does the same.
        var p = { left: pr.left, top: pr.top, right: pr.right, bottom: pr.bottom };
        var grip = panel.querySelector('.auto-hide-docked-resize-handle');
        if (grip !== null) {
          var g = grip.getBoundingClientRect();
          if (g.width > 0 && g.height > 0) {
            if (g.width < g.height) {
              // Upright grip: it hugs the left or the right edge.
              if (Math.abs(g.right - p.right) < 1) { p.right = g.left; }
              else if (Math.abs(g.left - p.left) < 1) { p.left = g.right; }
            } else {
              // Lying flat: the top or the bottom edge.
              if (Math.abs(g.top - p.top) < 1) { p.top = g.bottom; }
              else if (Math.abs(g.bottom - p.bottom) < 1) { p.bottom = g.top; }
            }
          }
        }

        var side = panel.id.indexOf('right') !== -1 ? 'right'
                 : panel.id.indexOf('bottom') !== -1 ? 'bottom' : 'left';

        var svg = document.createElementNS(SVG_NS, 'svg');
        svg.setAttribute('class', DOCKED_OUTLINE_CLASS);
        var path = document.createElementNS(SVG_NS, 'path');
        svg.appendChild(path);
        // Into `#root-container`, NOT the body.  That element is
        // `position: fixed; z-index: 0`, so it opens a stacking context, and the
        // hover overlay lives inside it: parked on the body this outline would
        // be compared against root-container's own 0 and win every time,
        // painting across a hovered panel however high the overlay's z-index
        // was set.  Inside, the two are ordered against each other and the
        // overlay covers the outline where they meet.  `position: fixed` still
        // resolves against the viewport here (no transformed ancestor), so the
        // viewport coordinates below stay correct.
        var host = document.getElementById('root-container') || document.body;
        host.appendChild(svg);

        var w = window.innerWidth, h = window.innerHeight;
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('width', w);
        svg.setAttribute('height', h);

        var strokeWidth = parseFloat(window.getComputedStyle(path).strokeWidth) || 1;
        var inset = strokeWidth / 2;
        var rr = radii(panel);

        // The bottom strip is the status bar, and is named differently from the
        // two side strips.
        var stripSel = side === 'bottom' ? '#auto-hide-bottom-strip'
                                         : '#auto-hide-strip-' + side;

        // Find the tab by the docked panel's own title, not by `.active`.  That
        // class marks a tab whose panel is docked *or* being previewed in the
        // hover overlay, so while hovering two tabs carry it and picking the
        // first drew this border around whichever tab the pointer was over.
        // The border is for the docked panel alone.
        var wanted = panel.getAttribute('data-ct-docked-title');
        var tab = null;
        var candidates = document.querySelectorAll(stripSel + ' .auto-hide-strip-tab');
        for (var ti = 0; ti < candidates.length; ti++) {
          if (candidates[ti].textContent.trim() === wanted) { tab = candidates[ti]; break; }
        }
        if (tab === null) {
          path.setAttribute('d', dockedPanelOnlyPath(p, rr, inset));
          return;
        }
        var tb = tab.getBoundingClientRect();
        if (tb.width < 1 || tb.height < 1) {
          path.setAttribute('d', dockedPanelOnlyPath(p, rr, inset));
          return;
        }
        path.setAttribute('d', side === 'bottom'
          ? dockedWithTabPathBottom(p, tb, rr, radii(tab), inset)
          : dockedWithTabPath(p, tb, rr, radii(tab), inset, side));
      }

      // ---------------------------------------------------------------------
      // The same outline once more, for the slide-in overlay.
      //
      // Reported as: *"There is still a glitch with borders of the active tab
      // in the auto hidden panels positioned in the status bar.  The borders
      // display properly when I dock a panel, but not when it's focused in
      // auto-hide mode."*
      //
      // An open overlay is the docked case in every respect that matters here:
      // a panel flush against a strip, with one tab in that strip jutting out
      // of it, and the tab already painting the connector curves that join the
      // two into a single shape (`.auto-hide-strip-tab.active`'s `::before` /
      // `::after` box-shadows).  The app was drawing the FILL of that shape and
      // not its edge.  So this reuses the docked path builders unchanged rather
      // than describing the shape a second time — the reported defect is two
      // renderings of one panel disagreeing, and a second copy of the geometry
      // is how they would disagree again.
      //
      // WHEN: whenever the overlay is `.visible`, with no focus test.
      //
      // The overlay has a pinned/preview distinction (`pinnedOpen` in
      // `ui/auto_hide.nim`) and it is deliberately NOT used here.  In the
      // shipped app a strip tab's CLICK docks the panel and its HOVER opens the
      // overlay (the strip callbacks' `onSelect` is `showDockedPanel`,
      // `onHoverEnter` is `showOverlayPreview`), so the ordinary way to reach
      // the overlay — the way the report describes — leaves `pinnedOpen` false
      // throughout.  Keyed on it, this border would not appear in the case it
      // was written for.
      //
      // Unconditional is also the truthful rule.  The overlay is dismissed by
      // the pointer leaving it, by a backdrop click, or by Escape, so it is
      // never on screen unattended; visible and in-use are the same state.  And
      // the tab is `.active` for exactly as long, so the line and the curves it
      // continues appear and disappear together.
      // ---------------------------------------------------------------------
      var OVERLAY_OUTLINE_CLASS = 'ct-overlay-outline';

      function removeOverlayOutline() {
        var old = document.querySelectorAll('.' + OVERLAY_OUTLINE_CLASS);
        for (var i = 0; i < old.length; i++) { old[i].remove(); }
      }

      // Returns whether it drew, so `update` can tell "the overlay owns the
      // outline" from "fall through to the docked and stack cases".
      function updateOverlayOutline() {
        var overlay = document.getElementById('auto-hide-overlay');
        if (overlay === null || !overlay.classList.contains('visible')) {
          return false;
        }

        // The BODY, not the overlay.
        //
        // The outer element spans the resize handle as well, and the handle is
        // the divider between this panel and the GL content — the same thing
        // `updateDockedOutline` trims off a docked container's rect above, for
        // the same reason.  Here the trim is already done in the paint: the
        // body carries a margin on the handle's side (`auto_hide.styl`), so it
        // is the box the user sees as the panel.  It is also the box that is
        // actually rounded — `#auto-hide-overlay` deliberately has no
        // `overflow: hidden`, so that the handle keeps right-angle corners —
        // so reading the radii off it is what makes the line follow the paint.
        var body = document.getElementById('auto-hide-overlay-body');
        if (body === null) { removeOverlayOutline(); return false; }

        var pr = body.getBoundingClientRect();
        if (pr.width < 1 || pr.height < 1) { removeOverlayOutline(); return false; }
        var p = { left: pr.left, top: pr.top, right: pr.right, bottom: pr.bottom };

        var side = overlay.classList.contains('auto-hide-overlay-right') ? 'right'
                 : overlay.classList.contains('auto-hide-overlay-bottom') ? 'bottom'
                 : overlay.classList.contains('auto-hide-overlay-left') ? 'left'
                 : null;
        // No edge class means the overlay is mid-teardown: `hideOverlay` drops
        // all three before it drops `visible`.  There is no shape to draw.
        if (side === null) { removeOverlayOutline(); return false; }

        // Alongside the overlay in `#root-container`, for the reason given on
        // the docked outline: parked on the body it would be measured against
        // root-container's own z-index rather than against the overlay's.
        var host = document.getElementById('root-container') || document.body;

        // REUSED, not rebuilt each pass.
        //
        // `schedule` is driven by a MutationObserver watching the whole body
        // for childList changes, so an outline that removes and re-appends
        // itself every pass is a mutation that schedules the next pass: a
        // rAF loop that never settles, running for as long as the panel is on
        // screen.  Writing `d` / `viewBox` / `width` / `height` into an element
        // that is already in place mutates nothing the observer watches (its
        // `attributeFilter` is `class` alone), so a steady overlay costs one
        // update and then nothing.
        var svg = host.querySelector(':scope > .' + OVERLAY_OUTLINE_CLASS);
        if (svg === null) {
          svg = document.createElementNS(SVG_NS, 'svg');
          svg.setAttribute('class', OVERLAY_OUTLINE_CLASS);
          svg.appendChild(document.createElementNS(SVG_NS, 'path'));
          host.appendChild(svg);
        }
        // Any stray left elsewhere by an earlier build or an earlier host.
        var strays = document.querySelectorAll('.' + OVERLAY_OUTLINE_CLASS);
        for (var si = 0; si < strays.length; si++) {
          if (strays[si] !== svg) { strays[si].remove(); }
        }
        var path = svg.firstChild;

        var w = window.innerWidth, h = window.innerHeight;
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('width', w);
        svg.setAttribute('height', h);

        var strokeWidth = parseFloat(window.getComputedStyle(path).strokeWidth) || 1;
        var inset = strokeWidth / 2;
        var rr = radii(body);

        var stripSel = side === 'bottom' ? '#auto-hide-bottom-strip'
                                         : '#auto-hide-strip-' + side;

        // By title, not by `.active` — the same trap the docked outline
        // documents.  A tab is `active` when its panel is docked OR when it is
        // the one being previewed, so while a preview is open two tabs carry
        // the class; the overlay's tab is the one whose label matches the
        // title the overlay was opened with.
        var titleEl = document.getElementById('auto-hide-overlay-title');
        var wanted = titleEl === null ? '' : titleEl.textContent.trim();
        var tab = null;
        if (wanted !== '') {
          var candidates = document.querySelectorAll(stripSel + ' .auto-hide-strip-tab');
          for (var ti = 0; ti < candidates.length; ti++) {
            if (candidates[ti].textContent.trim() === wanted) { tab = candidates[ti]; break; }
          }
        }
        if (tab === null) {
          // No tab found: an overlay opened by a command rather than from a
          // strip, or a collapsed strip. The panel alone is still a shape.
          path.setAttribute('d', dockedPanelOnlyPath(p, rr, inset));
          return true;
        }
        var tb = tab.getBoundingClientRect();
        if (tb.width < 1 || tb.height < 1) {
          path.setAttribute('d', dockedPanelOnlyPath(p, rr, inset));
          return true;
        }
        path.setAttribute('d', side === 'bottom'
          ? dockedWithTabPathBottom(p, tb, rr, radii(tab), inset)
          : dockedWithTabPath(p, tb, rr, radii(tab), inset, side));
        return true;
      }

      var pending = false;
      function schedule() {
        if (pending) { return; }
        pending = true;
        window.requestAnimationFrame(function () { pending = false; update(); });
      }

      // Focus moves by a class change, wherever it came from — a tab click, the
      // click-to-focus listener, or GoldenLayout itself — so watch the class
      // rather than any one entry point.  Resizes and tab drags change the
      // geometry without touching focus, hence the resize hook too.
      var observer = new MutationObserver(schedule);
      observer.observe(document.body, {
        attributes: true, attributeFilter: ['class'], subtree: true, childList: true
      });
      window.addEventListener('resize', schedule);

      // Dragging a docked panel's resize grip changes its width through inline
      // style, which the class-filtered observer above never sees.
      //
      // The overlay is dragged by its own grip and sized the same way — through
      // inline `width` / `height` on `#auto-hide-overlay`, written by the same
      // per-panel stored size — so its outline would otherwise stay where the
      // panel used to end.  Observing the body rather than the overlay: the body
      // is the box the outline is measured from, and it tracks the overlay.
      if (typeof ResizeObserver !== 'undefined') {
        var ro = new ResizeObserver(schedule);
        var docks = document.querySelectorAll('.auto-hide-docked');
        for (var di = 0; di < docks.length; di++) { ro.observe(docks[di]); }
        var overlayBody = document.getElementById('auto-hide-overlay-body');
        if (overlayBody !== null) { ro.observe(overlayBody); }
      }

      schedule();
    })();
  """.}

proc setupClickToFocusListeners() =
  ## Focus the panel the user clicks *into*, not only the one whose tab they hit.
  ##
  ## GoldenLayout only focuses a stack from its tab, so clicking straight into a
  ## panel's body left the selected-panel surface behind on whichever tab was
  ## touched last — the highlight pointed at a panel the user was not working in.
  ##
  ## The click is forwarded to the stack's already-active tab rather than the
  ## focus class being set directly, so GoldenLayout's own focus bookkeeping runs
  ## (it blurs the previously focused item and emits its focus event); setting the
  ## class here would leave the two disagreeing.
  ##
  ## A docked auto-hide panel counts as a panel here too.  It lives outside the
  ## GoldenLayout tree, so GL has no way to focus it and no way to know it was
  ## clicked; `ct-docked-focused` is the equivalent, and the GL outline builder
  ## stands down while it is set so exactly one panel is ever outlined.
  ##
  ## Listens in the capture phase and never calls `preventDefault`, so the click
  ## still reaches whatever was clicked — this only runs alongside it.
  {.emit: """
    function ctClearDockedFocus(except) {
      var docked = document.querySelectorAll('.auto-hide-docked.ct-docked-focused');
      for (var i = 0; i < docked.length; i++) {
        if (docked[i] !== except) { docked[i].classList.remove('ct-docked-focused'); }
      }
    }

    document.addEventListener('mousedown', function (ev) {
      var target = ev.target;
      if (!target || !target.closest) return;

      var docked = target.closest('.auto-hide-docked');
      if (docked !== null) {
        ctClearDockedFocus(docked);
        // A docked panel that is not open is a zero-size container; only an
        // open one can be the selected panel.
        if (docked.classList.contains('docked-open')) {
          docked.classList.add('ct-docked-focused');
        }
        return;
      }

      var stack = target.closest('.lm_stack');
      if (stack === null) return;

      // Clicking back into the layout hands the selection to GoldenLayout.
      ctClearDockedFocus(null);

      // Header clicks are GoldenLayout's own business: tabs, the close and pin
      // buttons and the stack menu all live there and already focus correctly.
      if (target.closest('.lm_header') !== null) return;

      // Already the selected panel — nothing to do.
      if (stack.querySelector(':scope > .lm_header.lm_focused') !== null) return;

      var activeTab = stack.querySelector(':scope > .lm_header .lm_tab.lm_active');
      if (activeTab !== null) {
        activeTab.click();
      }
    }, true);
  """.}

proc setupDragToPinListeners(layout: GoldenLayout) =
  ## Wire drag-to-pin listener.
  ## Coordinates mousemove/mouseup events when a tab is dragged to check
  ## if it intersects with the Left, Right, or Bottom auto-hide drop zones.
  {.emit: """
    (function() {
      var isActuallyDragging = false;
      window.addEventListener('mousemove', function(e) {
        if (!`activeDraggedItem`) return;
        if (document.querySelector('.lm_dragProxy') !== null) {
          isActuallyDragging = true;
        }
        if (!isActuallyDragging) return;

        var x = e.clientX;
        var y = e.clientY;
        var width = window.innerWidth;
        var height = window.innerHeight;

        var leftStrip = document.getElementById('auto-hide-strip-left');
        var rightStrip = document.getElementById('auto-hide-strip-right');
        var bottomStrip = document.getElementById('auto-hide-bottom-strip');

        if (leftStrip) leftStrip.classList.remove('drag-over');
        if (rightStrip) rightStrip.classList.remove('drag-over');
        if (bottomStrip) bottomStrip.classList.remove('drag-over');

        if (x >= 0 && x <= 40) {
          if (leftStrip) leftStrip.classList.add('drag-over');
        } else if (x >= width - 40 && x <= width) {
          if (rightStrip) rightStrip.classList.add('drag-over');
        } else if (y >= height - 40 && y <= height) {
          if (bottomStrip) bottomStrip.classList.add('drag-over');
        }
      });

      window.addEventListener('mouseup', function(e) {
        var wasDragging = isActuallyDragging;
        isActuallyDragging = false;

        if (!`activeDraggedItem`) return;

        var x = e.clientX;
        var y = e.clientY;
        var width = window.innerWidth;
        var height = window.innerHeight;

        var leftStrip = document.getElementById('auto-hide-strip-left');
        var rightStrip = document.getElementById('auto-hide-strip-right');
        var bottomStrip = document.getElementById('auto-hide-bottom-strip');

        if (leftStrip) leftStrip.classList.remove('drag-over');
        if (rightStrip) rightStrip.classList.remove('drag-over');
        if (bottomStrip) bottomStrip.classList.remove('drag-over');

        if (wasDragging) {
          var edge = -1;
          if (x >= 0 && x <= 40) {
            edge = 0; // Left
          } else if (x >= width - 40 && x <= width) {
            edge = 1; // Right
          } else if (y >= height - 40 && y <= height) {
            edge = 2; // Bottom
          }

          if (edge !== -1) {
            `pinPanel`(`layout`, `activeDraggedItem`, edge);
          }
        }

        `activeDraggedItem` = null;
      });
    })();
  """.}


proc mountComponentContainer(host: Element, componentId: cstring) =
  ## Replace `host`'s children with the single `.component-container` div a
  ## GoldenLayout component mounts into.
  ##
  ## NOT EXPORTED, and that is asserted rather than incidental. Its three
  ## callers are the two `genericUiComponent` registrations below and nothing
  ## else — `grep -rn mountComponentContainer src` finds this module, a test
  ## that reads this module's SOURCE TEXT, and no importer. It carried a `*`
  ## until 2026-09-04, and while it did, `ci/test/frontend-reachability.sh`
  ## counted it: b59186fa0 added a test that mentions the name, which moved it
  ## out of the uncounted "only its own module reaches it" bucket and into the
  ## counted "tested, and no product module reaches it" one, taking the
  ## repository from the recorded ceiling of 1228 to 1229 and reddening
  ## `lint-nim` for a second reason nobody had reported. An export nobody
  ## outside can use is what that guard exists to find.
  ##
  ## Built with `createElement` + `setAttribute` rather than
  ## `innerHTML = fmt"<div id={componentId} class=...>"`, which is what this
  ## used to be.  `componentId` is a panel label, and the editor registration's
  ## labels are native absolute paths — interpolated into an UNQUOTED `id=`
  ## attribute, a path containing a space and `onmouseover=` became an event
  ## handler on this div.  `setAttribute` cannot leave the attribute it is
  ## given, whatever the value contains.
  host.innerHTML = cstring""
  let inner = kdom.document.createElement(cstring"div")
  inner.setAttribute(cstring"id", componentId)
  inner.setAttribute(cstring"class", cstring"component-container")
  host.appendChild(inner)


proc swapLayout*(data: Data, config: GoldenLayoutResolvedConfig) =
  ## Hand GoldenLayout a WHOLE new layout, and say so while it happens.
  ##
  ## `loadLayout` destroys the current tree before it builds the new one, and
  ## GoldenLayout announces each destruction with `itemDestroyed`. That handler
  ## cannot tell the two situations apart on its own, and they could not be
  ## more different:
  ##
  ##   * THE USER CLOSED A TAB — the file is finished with, so
  ##     `closeEditorTab` drops it from `data.ui.editors`, drops its entry from
  ##     `EditorService.open`, and adds it to the closed-tabs list.
  ##   * A MODE TRANSITION SWAPPED THE LAYOUT — the same file is coming back,
  ##     often in the very next layout, and everything the user has typed into
  ##     it is in that editor's buffer.
  ##
  ## Treating the second as the first is why a Run and a Stop left an editor
  ## PANE with no editor in it. Measured on the assembled bundle: after Stop the
  ## edit layout came back with its `src/main.nr` tab and an 880x902
  ## `editorComponent-0` host, `document.querySelectorAll(".view-line").length`
  ## was 0, and the single `monaco.editor.getEditors()` entry was detached and
  ## still carried the replay's `readOnly: true`. `closeEditorTab` had run
  ## during the swap and taken the tab out of `data.ui.editors`, so the mount
  ## that followed built a SECOND, empty component instead of finding the one
  ## that owned the file — and `ci/test/noir-mode-roundtrip.sh` read the result
  ## as "the editors are writable again" failing on every trip.
  ##
  ## `isReparenting` is the same idea one case earlier: auto-hide moves a panel
  ## between two places in the tree, and the destruction it causes is not a
  ## close either. This adds the second such case rather than inventing a
  ## mechanism.
  if data.ui.layout.isNil:
    return
  data.ui.isLoadingLayout = true
  try:
    data.ui.layout.loadLayout(config)
  finally:
    data.ui.isLoadingLayout = false

proc closeLayoutTab*(data: Data, content: Content, id: int) =
  ## A TAB WITH NO COMPONENT BEHIND IT IS CLOSED, NOT AN ERROR.
  ##
  ## This used to `raise` when `componentMapping[content]` had no entry for
  ## `id`, and its only caller is the `itemDestroyed` layout event — which
  ## GoldenLayout fires from INSIDE `loadLayout`, while it tears the previous
  ## layout down. So the raise did not report a closed tab that could not be
  ## found; it ABORTED THE LOAD, half-way through, leaving whatever GoldenLayout
  ## had built so far on screen.
  ##
  ## Measured on the assembled bundle, three round trips: trip 3's Run reported
  ## `replay: could not load the debugging layout: There is not any component
  ## with the given id.` and the tab sat on the debugger topbar with ZERO
  ## debugger panes; the Stop that followed reported the same message about the
  ## edit layout. The state that produced it is ordinary on the web, where
  ## `createUIComponents` walks `resolvedConfig` once at startup and every pane
  ## a later layout names — Files, VCS, the source tab — therefore has a
  ## GoldenLayout container and no Nim component.
  ##
  ## What remains to do for such a tab is the bookkeeping that is not about the
  ## component: the legacy renderer instance and the open-id register. Both run
  ## below.
  let hasComponent = data.ui.componentMapping[content].hasKey(id)
  if not hasComponent:
    cwarn "layout: closing " & $content & "/" & $id &
      " which has no component; unregistering nothing"

  # Detach the component from the event bus BEFORE it leaves the registry.
  # Dropping the reference alone is not enough: the component's handlers live
  # on its private mediator, which is itself registered as a subscriber of
  # `data.viewsApi`, so a closed panel keeps receiving (and acting on) every
  # event it ever subscribed to.  Re-opening the panel then adds a second
  # live handler, and each closed generation multiplies the effect — this is
  # what made "Add to Scratchpad" append the same value once per generation
  # (#612).  `itemDestroyed` suppresses this path while auto-hide is
  # reparenting a panel, so a pinned panel is never unregistered here.
  if hasComponent:
    let closedComponent = data.ui.componentMapping[content][id]
    if not closedComponent.isNil:
      closedComponent.unregister()

  # A closed diff tab drops its ViewModel and its source-text cache with it, so
  # a re-opened tab starts with no hunk selection, no context expansion and no
  # cached blobs — DR-R5: "Expansion state resets when the tab is closed and
  # does not leak between files."
  if content == Content.UnifiedDiff:
    unified_diff.forgetUnifiedDiffTab(id)

  # remove component from registry
  discard jsDelete(data.ui.componentMapping[content][id])

  # remove component renderer instance (only for remaining legacy-backed
  # components, e.g. editor tabs; IsoNim GL components no longer register one)
  let label = convertComponentLabel(content, id)
  renderer.removeLegacyRendererInstance(label)

  # remove component from open components registry from the same content type (if there is any)
  let idx = data.ui.openComponentIds[content].find(id)
  if idx != -1:
    data.ui.openComponentIds[content].delete(idx)

# Track whether the shared (non-GL) global renderers have been initialised.
# Menu/status/session-tab-bar/fixed-search are refreshed directly; the global
# search-results footer placeholder is static and no longer has a Karax stub.
var sharedRenderersInitialised = false

# Coalescing state for the `window.resize` -> menu re-render below.
#
# MODULE level, deliberately, not per `initLayout` call: `initLayout` runs
# once per session (`ui_js.nim` on load, `session_switch.nim` on first
# activation of each new session) and the `resize` listener it installs is
# never removed, so a workspace with N sessions has N listeners.  Holding the
# throttle here means those N listeners still collapse to a single menu
# render per window, instead of N renders per resize event.
var menuResizeRenderPending = false

proc ensureSharedRenderers() =
  ## Set up the shared global chrome elements that live outside individual
  ## session GL containers. Safe to call multiple times — it only acts on the
  ## first invocation.
  if sharedRenderersInitialised:
    return
  sharedRenderersInitialised = true

  renderer.sharedDirectRedraw = proc() =
    if not data.ui.menu.isNil:
      try:
        data.ui.menu.requestMenuRender()
      except:
        cerror "layout: menu redraw failed: " & getCurrentExceptionMsg()
    if not data.ui.status.isNil:
      try:
        data.ui.status.requestStatusRender()
      except:
        cerror "layout: status redraw failed: " & getCurrentExceptionMsg()
    try:
      requestFixedSearchRender()
    except:
      cerror "layout: fixed search redraw failed: " & getCurrentExceptionMsg()
  if not data.ui.menu.isNil:
    discard windowSetTimeout(proc() = data.ui.menu.requestMenuRender(), 0)
  discard windowSetTimeout(proc() = requestFixedSearchRender(), 0)
  # Session tab bar: the menu shell owns the flex-row host and
  # ui/session_tabs.nim creates it defensively for older shells/tests;
  # explicit session/trace mutation sites refresh the direct IsoNim mount.
  discard windowSetTimeout(proc() = requestSessionTabsRender(data), 50)

  if not data.ui.status.isNil:
    discard windowSetTimeout(proc() = data.ui.status.requestStatusRender(), 0)

## The layout shipped with CodeTracer, embedded at compile time.
##
## It is the last-resort fallback for `loadLayoutSafely`: if the persisted
## layout AND its repaired form are both rejected by GoldenLayout, we still
## have to hand `loadLayout` *something*, because everything after it in
## `initLayout` — auto-hide init, the `stateChanged` / `itemDestroyed`
## handlers, standalone panel registration — must still run.  Reading it
## from disk here would need another IPC round trip during startup; the file
## is ~6 KB, so embedding it is cheaper than the mechanism to fetch it.
const bundledDefaultLayoutJson = staticRead("../../config/default_layout.json")

proc tryParseLayoutJson(raw: cstring): js {.importjs:
  """(function(raw) {
    try { return JSON.parse(raw); } catch (error) { return null; }
  })(#)""".}

proc callLoadLayoutUnchecked(layout: GoldenLayout,
                             config: GoldenLayoutResolvedConfig) =
  ## Thin wrapper that calls `loadLayout` as a normal Nim call, so
  ## `loadLayoutOnce` can reference the call site from inside a JS-level
  ## try/catch without emit-level name-resolution issues.  Mirrors
  ## `ui/session_switch.nim`'s `callInitLayoutUnchecked`.
  layout.loadLayout(config)

proc loadLayoutOnce(layout: GoldenLayout, config: GoldenLayoutResolvedConfig,
                    what: cstring): bool =
  ## Apply a config to GoldenLayout, reporting failure instead of propagating
  ## it.  The try/catch is raw JavaScript on purpose: GoldenLayout signals a
  ## rejected config with a native `Error` (`ActiveItemIndex out of range`,
  ## `ConfigurationError`, a `TypeError` from an unknown component type), and
  ## Nim's `except` catches only Nim-derived exceptions — the same reason
  ## `ui/session_switch.nim:97-116` uses this pattern around `initLayout`.
  if config.isNil:
    return false
  {.emit: """
    try {
      `callLoadLayoutUnchecked`(`layout`, `config`);
      `result` = true;
    } catch (e) {
      console.warn("layout: loadLayout rejected " + `what` + ": " +
        (e && e.message ? e.message : String(e)));
      `result` = false;
    }
  """.}

proc loadLayoutSafely(layout: GoldenLayout,
                      initialLayout: GoldenLayoutResolvedConfig): bool
                     {.discardable.} =
  ## Apply the session's layout, degrading rather than aborting.
  ##
  ## A config that GoldenLayout rejects used to throw straight out of
  ## `initLayout`, *after* `data.ui.layout` had been assigned but *before*
  ## auto-hide init, the event handlers and the standalone panels were
  ## installed — a half-initialised, unusable window that reappeared on every
  ## launch because nothing rewrote the offending file (issue #608).
  ##
  ## Three attempts, in decreasing fidelity to what the user arranged:
  ## the saved config, its repaired form, then the bundled default.
  if loadLayoutOnce(layout, initialLayout, cstring"the saved layout"):
    return true

  let repair = repairLayoutConfig(cast[js](initialLayout))
  if repair.ok:
    for issue in repair.issues:
      cwarn "layout: repairing the rejected layout: " & $issue
    if loadLayoutOnce(layout,
                      cast[GoldenLayoutResolvedConfig](repair.config),
                      cstring"the repaired layout"):
      cwarn "layout: restored the saved layout after repairing it"
      return true

  # THE MODE'S DEFAULT, NOT THE RAW BUNDLED TREE.
  #
  # The bundled `default_layout.json` is nobody's layout: it is the input both
  # modes' defaults are derived from, and handing it over verbatim gives an
  # edit session the replay-only panels it has no data for, and a debug session
  # the standing TEST RESULTS and CONSTRAINTS columns that
  # `paneHomesForMode` exists to re-home. A fallback that lands the user in a
  # layout neither mode declares is a third arrangement invented at the worst
  # possible moment.
  let modeDefault = mode_layouts.bundledLayoutForMode(data.ui.mode)
  if not modeDefault.isNil and
      loadLayoutOnce(layout, cast[GoldenLayoutResolvedConfig](modeDefault),
                     cstring"the mode's default layout"):
    cerror "layout: the saved layout could not be restored; " &
      "fell back to the default layout for " & $data.ui.mode
    return true

  # AND ONLY THEN THE BUNDLED TREE, which is worse but is still a workspace.
  let bundled = tryParseLayoutJson(cstring(bundledDefaultLayoutJson))
  if not bundled.isNil and
      loadLayoutOnce(layout, cast[GoldenLayoutResolvedConfig](bundled),
                     cstring"the bundled default layout"):
    cerror "layout: the saved layout could not be restored and neither could " &
      "the default for " & $data.ui.mode & "; fell back to the bundled tree"
    return true

  cerror "layout: no layout config could be applied; " &
    "continuing with an empty GoldenLayout so the rest of the UI still mounts"
  return false

proc persistAutoHideState*() =
  ## Send the current pinned-panel set to the index process, which writes it
  ## to `~/.config/codetracer/auto_hide_state.json`.
  ##
  ## The panels a user pins are REMOVED from the GoldenLayout tree, so they
  ## are not part of the layout config and cannot ride along with it — they
  ## need their own persisted file, and this is the only writer.
  if ipc.isNil or ipc.isUndefined:
    return
  let serialized = serializeAutoHideState()
  if serialized.isNil or serialized.isUndefined:
    return
  ipc.send "CODETRACER::save-auto-hide-state", js{
    state: JSON.stringify(serialized)
  }

var autoHideStateRestored = false
  ## Guards the once-per-process restore in `initLayout`; see the call site.

proc requestSavedAutoHideState(): JsObject =
  ## Read back the auto-hide (pinned panel) state the index process persisted.
  ##
  ## Synchronous on purpose.  The standalone auto-hide panels are registered
  ## on a 500 ms timer whose `findPanelByContent` skip is what keeps a
  ## restored panel from being duplicated, so the restore has to have
  ## happened before `initLayout` returns; an async round trip would make
  ## that a race.  The payload is a few hundred bytes, read once per window.
  ##
  ## Returns `undefined` when there is no saved state, when the IPC bridge is
  ## absent (server builds render without Electron), or when the payload does
  ## not parse — every one of which is an ordinary first-run situation.
  {.emit: """
    `result` = undefined;
    try {
      if (`ipc` && typeof `ipc`.sendSync === 'function') {
        const raw = `ipc`.sendSync("CODETRACER::request-auto-hide-state");
        if (typeof raw === 'string' && raw.length > 0) {
          `result` = JSON.parse(raw);
        }
      }
    } catch (e) {
      console.warn("layout: could not read the saved auto-hide state: " +
        (e && e.message ? e.message : String(e)));
    }
  """.}

# Triage: rename to initGoldenLayout
proc bindLayoutItemForTab(state: GoldenItemState; container: GoldenContainer) =
  ## Give the component this tab belongs to a handle on its GoldenLayout item.
  ##
  ## THE COMPONENT IS THE ONE THE TAB NAMES, not "the most recently opened one
  ## of this content". Both `registerComponent` bodies used to read
  ## `componentMapping[state.content][openComponentIds[state.content][^1]]`,
  ## and that heuristic is wrong in two ways at once:
  ##
  ##   * WITH SEVERAL TABS OF ONE CONTENT it hands every tab's layout item to
  ##     the same component — the last one opened — so the other components end
  ##     up with a stale item or none, and `closeAuxiliaryPanels` then removes
  ##     the wrong pane.
  ##   * WHEN THE LAST OPENED ID HAS NO COMPONENT AT ALL the lookup answers
  ##     `undefined` and the assignment THROWS. Measured on the assembled
  ##     bundle, driving Run and then Stop in a browser: `layout: GoldenLayout
  ##     rejected the edit layout: Cannot read properties of undefined (reading
  ##     'layoutItem')`, thrown from inside `loadLayout` after GoldenLayout had
  ##     already torn the debug layout down and mounted five of the edit
  ##     layout's components. The restore aborted half-way and left the
  ##     workspace EMPTY: no editor, no Files, no VCS, no tabs at all. The
  ##     mode-roundtrip gate saw that as "the editors are writable again"
  ##     failing on every trip — there was no editor pane left to be writable —
  ##     and as a caret that never moved, because there was no source view to
  ##     paint it in.
  ##
  ## `state.id` is the authority the same handler already uses two lines further
  ## down for `Content.UnifiedDiff`, and that `findPanelByContentAndId(
  ## state.content, state.id)` uses above.
  ##
  ## A MISSING COMPONENT IS NAMED RATHER THAN THROWN. A tab can legitimately
  ## exist with no component behind it — `web_replay_host` loads a debugging
  ## layout that declares a retired `Content.Trace` pane and deliberately skips
  ## constructing it — and one such pane must not abort the load of every other.
  if data.ui.openComponentIds[state.content].find(state.id) == -1:
    data.ui.openComponentIds[state.content].add(state.id)

  let similarComponents = data.ui.componentMapping[state.content]
  if not similarComponents.hasKey(state.id):
    cwarn "layout: tab for " & $state.content & "/" & $state.id &
      " has no component; its layout item is not bound"
    return
  let component = similarComponents[state.id]
  if component.isNil:
    cwarn "layout: tab for " & $state.content & "/" & $state.id &
      " maps to a nil component; its layout item is not bound"
    return
  component.layoutItem = cast[GoldenContentItem](container.tab.contentItem)

proc initLayout*(initialLayout: GoldenLayoutResolvedConfig,
                 containerElement: kdom.Element = nil) =
  ## Initialise GoldenLayout for the active session.
  ##
  ## ``containerElement`` is the DOM element GL will bind to.  When nil
  ## (the default, used during initial page load) we look up
  ## ``session-container-<activeSessionIndex>`` inside ``#ROOT``.
  ## For new sessions created at runtime the caller passes the freshly
  ## created container element directly.
  echo "initLayout"
  echo data.ui.layout.isNil

  if data.startOptions.shellUi:
    renderer.sharedDirectRedraw = proc() =
      if not data.ui.menu.isNil:
        try:
          data.ui.menu.requestMenuRender()
        except:
          cerror "layout: menu redraw failed: " & getCurrentExceptionMsg()
      if not data.ui.status.isNil:
        try:
          data.ui.status.requestStatusRender()
        except:
          cerror "layout: status redraw failed: " & getCurrentExceptionMsg()
      try:
        requestFixedSearchRender()
      except:
        cerror "layout: fixed search redraw failed: " & getCurrentExceptionMsg()
    if not data.ui.menu.isNil:
      discard windowSetTimeout(proc() = data.ui.menu.requestMenuRender(), 0)
    discard windowSetTimeout(proc() = requestFixedSearchRender(), 0)
    return

  # DeepReview mode: uses the normal GL layout path.  The DeepReview-specific
  # layout config (built in onStartDeepReview) includes a Modified Files
  # panel and an empty editor stack.  The DeepReviewComponent is registered
  # as a genericUiComponent and rendered inside the GL container like any
  # other panel.  File selection in the sidebar opens editor tabs via
  # data.openTab with diff decorations applied by the component.

  # Shared chrome must be available even when this session mounts the welcome
  # screen instead of GoldenLayout.
  ensureSharedRenderers()

  if data.startOptions.welcomeScreen and data.trace.isNil:
    clog "initLayout: mounting IsoNim welcome screen"
    if not data.ui.welcomeScreen.isNil:
      data.ui.welcomeScreen.syncLegacyWelcomeScreenIntoVM()
    welcome_screen.tryMountIsoNimWelcomeScreen()
    return

  # Determine the GL container element.
  # On initial load (session 0) there is no session-container-0 in the DOM
  # yet.  We create it here so that hide/show session switching can toggle
  # its visibility without special-casing the first session.
  let root = if not containerElement.isNil:
      containerElement
    else:
      let containerId = cstring("session-container-" & $data.activeSessionIndex)
      var el = document.getElementById(containerId)
      if el.isNil:
        # Create the container inside #ROOT.
        el = document.createElement("div")
        el.id = containerId
        el.class = cstring"session-container"
        let rootEl = document.getElementById(cstring"ROOT")
        if not rootEl.isNil:
          rootEl.appendChild(el)
      el

  var layout = newGoldenLayout(
    cast[JsObject](root),
    proc() = (cdebug "layout: component binded"),
    proc() = (cdebug "layout: component unbinded")
  )

  # EMPTY THE STACK HEADER'S CONTROL BAR, AND STOP RESERVING WIDTH FOR IT.
  #
  # `b31dbcc0` removed the stack-header three-dots dropdown — every command it
  # carried is on the tab's right-click menu (`addPanelTransferContextMenu`),
  # and it cost 1.7em of header width per stack. It deleted BOTH halves: the
  # Nim that built it and the `.layout-buttons-container` rule in
  # `shared_widgets.styl`. The merge `69e881ca` then resurrected the Nim half
  # alone — both its parents have zero occurrences of
  # `layout-buttons-container` in this file, the merge result has four — so an
  # empty, unstyled `div.layout-buttons-container` was still being appended
  # into `section.lm_tabs` on every stack. Measured on the shipped build
  # (`1a427e3e`, noirstudio.dev): it is a 0x0 flex child of a strip whose
  # `gap` is 0.25em, so it still bought a full gap. With one tab that gap sat
  # at the end of the strip — the 4px of "awkward empty space" — and once
  # GoldenLayout re-appended the tabs around it, it landed between the first
  # and second tab, which is why exactly one inter-tab gap measured 8px while
  # every other measured 4px.
  #
  # It also defeated `golden_layout.styl`'s `.lm_tab.lm_active:last-child`
  # rules: the stray div, not the last tab, was `:last-child`, so the
  # connector curve that is meant to be switched off at the panel's edge was
  # drawn anyway.
  #
  # This finishes the removal. The control bar is still emptied — GL's own
  # maximise/popout/close buttons are not part of this design — but the width
  # GL reserves for controls is now zeroed to match. `tabControlOffset`
  # defaults to 10px and is subtracted in `Header._updateTabSizes`:
  #
  #     availableWidth = header.offsetWidth - controls.offsetWidth - tabControlOffset
  #
  # while `golden_layout.styl` gives `.lm_tab` `flex: 1`, so the tabs always
  # expand to fill the whole strip. The measured total therefore always
  # exceeded `availableWidth` by that reserved 10px, and `tabOverlapAllowance`
  # defaults to 0, which makes the guard `overlap < tabOverlapAllowance`
  # unsatisfiable — so EVERY non-active tab was moved to
  # `ul.lm_tabdropdown_list`. That list is `display: none`, and the
  # `.lm_tabdropdown` button that opens it lives in the control bar this
  # handler empties, so an exiled tab was invisible AND unreachable.
  #
  # That is the whole of "the VCS panel is not drawn in the tab bar next to
  # FILES": `default_layout.json` puts Filesystem and VCS in one stack, and
  # VCS — the non-active one — was exiled at layout load. Measured on the
  # shipped build it was present in the DOM at 0x0 inside the hidden list. It
  # "shows up when I unpin FILES" because pinning removes FILES from the
  # stack, leaving VCS as the sole and therefore active tab, and an active tab
  # is never exiled. The same exile is why a panel dropped onto an existing
  # tab bar does not appear.
  #
  # The offset is zeroed per stack rather than only in the bundled layout
  # settings because a user's SAVED layout file carries its own `settings`
  # block, written before `tabControlOffset` was set there, and would
  # otherwise keep GoldenLayout's 10px default forever.
  layout.on(cstring"stackCreated") do (ev: Event):
    let controlsContainer = ev.toJs.target.element.childNodes[0].childNodes[1]

    while cast[kdom.Element](controlsContainer).childNodes.len() > 0:
      controlsContainer.removeChild(controlsContainer.childNodes[0])

    # Bracket access, not dot access: `_tabControlOffset` begins with an
    # underscore and Nim's lexer rejects that as an identifier.
    let header = ev.toJs.target.header
    if not header.isNil and not header.isUndefined:
      header[cstring"_tabControlOffset"] = toJs(0)

  data.ui.layout = layout
  data.ui.layoutConfig = cast[GoldenLayoutConfigClass](window.toJs.LayoutConfig)
  data.ui.contentItemConfig = cast[GoldenLayoutItemConfigClass](window.toJs.ItemConfig)

  layout.registerComponent(cstring"editorComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return

    let componentLabel = cstring(fmt"editorComponent-{state.id}")
    var element = cast[Element](container.getElement())

    let panel = if not autoHideState.isNil: autoHideState.findPanelByContentAndId(state.content, state.id) else: nil
    let isReparenting = not panel.isNil and not panel.liveElement.isNil and (data.ui.isReparenting or state.isReparenting)

    cdebug "[EDITOR_REG] label=" & $state.label & " content=" & $state.content & " id=" & $state.id & " panelIsNil=" & $(panel.isNil) & " liveElIsNil=" & $(if panel.isNil: true else: panel.liveElement.isNil) & " uiIsRep=" & $(data.ui.isReparenting) & " stateIsRep=" & $(state.isReparenting) & " isReparenting=" & $isReparenting

    # Clean up the transient reparenting property from state so it is not saved to the layout database.
    {.emit: """
    if (`state`) {
      delete `state`.isReparenting;
    }
    """.}

    if isReparenting:
      cdebug "[EDITOR_REG] Reparenting: liveElement childNodes.len=" & $(panel.liveElement.childNodes.len)
      element.innerHTML = cstring""
      while panel.liveElement.childNodes.len > 0:
        element.appendChild(panel.liveElement.childNodes[0])
      cdebug "[EDITOR_REG] Reparenting completed. element childNodes.len=" & $(element.childNodes.len)
      dispatchLayoutUpdated()
    else:
      cdebug "[EDITOR_REG] Regular mount (non-reparenting)"
      element.mountComponentContainer(componentLabel)

    container.on(cstring"tab") do (tab: GoldenTab):
      data.ui.saveLayout = true
      #componentMapping -> all registered components in data
      #content -> enum {TERMINAL, TRACELOG etc..}
      bindLayoutItemForTab(state, container)

      tab.setTitle(state.label)

      # Editor tab labels carry native absolute paths.  Split on both `/`
      # and `\` so a Windows path (`D:\repo\src\main.nr`) renders as the
      # `src/main.nr` tail instead of the whole path.  The split is done
      # with a literal JS regex in an `{.emit.}` block: a Nim `cstring`
      # backslash literal round-trips as a two-character JS string, so
      # `split("\\")` would never match a single separator (see the
      # matching note in `types.baseName`).
      var labelTokens: seq[cstring]
      {.emit: """
      `labelTokens` = (`state`.label || "").split(/[\\/]/);
      """.}
      # `textContent`, not `innerHTML`: the comment above says it — this label
      # is a native absolute path, and a path is not markup.  Written as
      # markup, a source file under a directory named
      # `<img src=x onerror=...>` executes in the Electron renderer the moment
      # its tab is drawn.
      if not ($state.label).startsWith("event:"):
        tab.titleElement.textContent = if labelTokens.len > 1:
            labelTokens[^2] & cstring"/" & labelTokens[^1]
          else:
            labelTokens[^1]
      else:
        tab.titleElement.textContent = if labelTokens.len > 1:
            labelTokens[0] & labelTokens[^1]
          else:
            state.label

      let editorPathForTab = state.label
      tab.element.addEventListener(cstring"click", proc(event: JsObject) =
        if data.ui.editors.hasKey(editorPathForTab):
          let editor = data.ui.editors[editorPathForTab]
          data.services.editor.active = editorPathForTab
          editor.refreshFlowAfterActivation()
          discard setTimeout(proc() =
            editor.refreshFlowAfterActivation()
          , 250)
          discard setTimeout(proc() =
            editor.refreshFlowAfterActivation()
          , 1000))

      data.ui.activeEditorPanel = cast[GoldenContentItem](tab.contentItem.parent)

      # get latest editorPanel
      let editorPanel = data.viewerPanel()

      if not editorPanel.isNil:
        # set all editor view types panels to latest editorPanel
        for view, nilPanel in data.ui.editorPanels:
          data.ui.editorPanels[view] = editorPanel

        # setup active editor panel: used for switch/closing active tab actions: ctrl-tab/ctrl-w and other shortcuts(configurable)
          data.ui.activeEditorPanel = editorPanel

        if data.ui.openComponentIds[state.content].len == 1:
          # add activeContentItemChanged event handler
          editorPanel.toJs.on(cstring"activeContentItemChanged") do (event:  GoldenContentItem):
            let config = event.toConfig()
            let componentState = config.componentState

            if componentState.content.to(Content) != Content.EditorView:
              return

            let editorPath = componentState.fullPath.to(cstring)
            cdebug "layout: tab changed: active = " & $editorPath
            data.services.editor.active = editorPath
            let editor = data.ui.editors[editorPath]
            editor.refreshFlowAfterActivation()

            # A GENERATED-CODE LISTING FOLLOWS THE ACTIVE SOURCE TAB.
            # `Generated-Code-Listing.md` §6.2: the leader is the document the
            # user last interacted with, and switching tabs IS that
            # interaction. The line travels with the path because each tab
            # carries its own cursor — a consumer told only the path would
            # keep the previous tab's line under the new tab's name until the
            # user happened to move the caret.
            #
            # Read from the Monaco instance rather than from `tabInfo
            # .viewLine`, which is a scroll target and not a caret: they agree
            # after a jump and diverge the moment a user clicks a line.
            if not editorActiveTabChangedHook.isNil:
              var activeLine = 1
              if not editor.monacoEditor.isNil:
                let position = editor.monacoEditor.getPosition()
                if not position.isNil:
                  activeLine = cast[int](position.lineNumber)
              editorActiveTabChangedHook(editorPath, activeLine)
            let tab = EditorViewTabArgs(name: editorPath, editorView: editor.editorView)
            # check if current active tab is newly created or it exists in tab history
            if data.services.editor.tabHistory.find(tab) == -1:
              # if the tab is newly created it needs to be added to history without time limit (immediately)
              data.services.editor.addTabToHistory(tab)
            else:
              # if it is existing (already is in the history), the tab history time limit should expire
              # because existing tab is added to history only if the user keeps it open
              # if the user switch to another tab before the limit expires - the tab should not be added to history
              data.services.editor.eventuallyUpdateTabHistory(tab)

      # M21: Attach "Send to Window" context menu to the tab.
      addPanelTransferContextMenu(tab, cast[GoldenContentItem](tab.contentItem))
      let editorContentItem = cast[GoldenContentItem](tab.contentItem)
      injectPinButton(tab.element, proc() =
        pinPanel(cast[GoldenLayout](layout), editorContentItem, AutoHideEdge.Left))

    let panelObj = if not autoHideState.isNil: autoHideState.findPanelByContentAndId(state.content, state.id) else: nil
    let isReparentingObj = isReparenting

    if not isReparentingObj:
      var containerId: cstring
      containerId = cstring(fmt"editorComponent-{state.id}")

      let editorPathForMount = state.label

      discard windowSetTimeout((proc =
        # THE EDITOR THAT ALREADY OWNS THIS PATH, IF THERE IS ONE.
        #
        # `state.label` is the tab's full path, and `data.ui.editors` is keyed
        # by exactly that. When a mode transition destroys the editor pane and
        # a later one rebuilds it, the component holding the loaded source, the
        # tab info and the live Monaco instance is STILL in `data.ui.editors`
        # — it is only its GoldenLayout container that went. Reaching for
        # `componentMapping` first and calling `makeComponent` on a miss builds
        # a SECOND, empty `EditorViewComponent` with no path and no tab info,
        # whose `renderTopLevelEditorDirect` then retries 1200 times waiting for
        # a source that will never arrive, and gives up.
        #
        # Measured on the assembled bundle: after Stop the edit layout came
        # back with its `src/main.nr` tab and an 880x902 `editorComponent-0`
        # host, and `document.querySelectorAll(".view-line").length` was 0 —
        # an editor pane with no editor in it. The real instance was still
        # alive and detached, reporting the replay's `readOnly: true`.
        # `ci/test/noir-mode-roundtrip.sh` reads that as "the editors are
        # writable again" failing on every trip.
        var component: Component
        if data.ui.editors.hasKey(editorPathForMount):
          component = data.ui.editors[editorPathForMount]
        else:
          if not data.ui.componentMapping[state.content].hasKey(state.id):
            discard data.makeComponent(state.content, state.id)
          component = data.ui.componentMapping[state.content][state.id]

        if not component.isNil:
          EditorViewComponent(component).renderTopLevelEditorDirect(containerId)

        ), 200)

  layout.registerComponent(cstring"genericUiComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return
    let editorLabel = state.label
    var element = cast[Element](container.getElement())

    let panel = if not autoHideState.isNil: autoHideState.findPanelByContentAndId(state.content, state.id) else: nil
    let isReparenting = not panel.isNil and not panel.liveElement.isNil and (data.ui.isReparenting or state.isReparenting)

    cdebug "[GENERIC_REG] label=" & $state.label & " content=" & $state.content & " id=" & $state.id & " panelIsNil=" & $(panel.isNil) & " liveElIsNil=" & $(if panel.isNil: true else: panel.liveElement.isNil) & " uiIsRep=" & $(data.ui.isReparenting) & " stateIsRep=" & $(state.isReparenting) & " isReparenting=" & $isReparenting

    # Clean up the transient reparenting property from state so it is not saved to the layout database.
    {.emit: """
    if (`state`) {
      delete `state`.isReparenting;
    }
    """.}

    if isReparenting:
      cdebug "[GENERIC_REG] Reparenting: liveElement childNodes.len=" & $(panel.liveElement.childNodes.len)
      element.innerHTML = cstring""
      while panel.liveElement.childNodes.len > 0:
        element.appendChild(panel.liveElement.childNodes[0])
      cdebug "[GENERIC_REG] Reparenting completed. element childNodes.len=" & $(element.childNodes.len)

      # Clean up the panel from autoHideState.panels list now that it is reparented
      if not autoHideState.isNil:
        autoHideState.panels = autoHideState.panels.filterIt(it != panel)
        if not autoHideState.onChanged.isNil:
          autoHideState.onChanged()

      dispatchLayoutUpdated()
    else:
      cdebug "[GENERIC_REG] Regular mount (non-reparenting)"
      element.mountComponentContainer(editorLabel)

    container.on(cstring"tab") do (tab: GoldenTab):
      # prepare layout to be saved on upcoming stateChanged event
      data.ui.saveLayout = true

      # add contentItem to the component this tab names, and register the id as
      # open — both in `bindLayoutItemForTab`, which the editor registration
      # above shares.
      bindLayoutItemForTab(state, container)

      if state.content == Content.UnifiedDiff:
        let component = data.ui.componentMapping[state.content][state.id]
        if not component.isNil:
          let diffComp = UnifiedDiffComponent(component)
          if not diffComp.diffTarget.isNil and ($diffComp.diffTarget).startsWith("diff:"):
            let target = ($diffComp.diffTarget)[5 .. ^1]
            if target == "Working Tree":
              tab.setTitle("Diff: Working Tree")
            elif target.startsWith("file:"):
              let filepath = target[5 .. ^1]
              let slashIdx = filepath.rfind('/')
              let baseName = if slashIdx >= 0: filepath[slashIdx + 1 .. ^1] else: filepath
              tab.setTitle(cstring("Diff: " & baseName))
            elif target.startsWith("commit:"):
              let commitPart = target[7 .. ^1]
              let colonIdx = commitPart.find(':')
              if colonIdx >= 0:
                let filepath = commitPart[colonIdx + 1 .. ^1]
                let slashIdx = filepath.rfind('/')
                let baseName = if slashIdx >= 0: filepath[slashIdx + 1 .. ^1] else: filepath
                tab.setTitle(cstring("Diff: " & baseName & " (" & commitPart[0 ..< min(6, colonIdx)] & ")"))
              else:
                tab.setTitle(cstring("Diff: " & commitPart[0 ..< min(6, commitPart.len)]))
            else:
              tab.setTitle(cstring("Diff: " & target))
          else:
            tab.setTitle(cstring(convertTabTitle($state.content)))
        else:
          tab.setTitle(cstring(convertTabTitle($state.content)))
      else:
        tab.setTitle(cstring(convertTabTitle($state.content)))

      # M21: Attach "Send to Window" context menu to the tab.
      addPanelTransferContextMenu(tab, cast[GoldenContentItem](tab.contentItem))
      let genericContentItem = cast[GoldenContentItem](tab.contentItem)
      markPanelTab(tab.element, state.content)
      injectPinButton(tab.element, proc() =
        pinPanel(cast[GoldenLayout](layout), genericContentItem, AutoHideEdge.Left))

      let tabEl = cast[Element](tab.element)
      if not tabEl.isNil:
        tabEl.addEventListener(cstring"mousedown", proc(ev: Event) =
          activeDraggedItem = genericContentItem
        )

    # Components that still enter the generic GoldenLayout route mount
    # directly into the GoldenLayout container. Editor tabs use the separate
    # editorComponent route above.
    let isDirectMountComponent = state.content in {
      Content.Calltrace,
      Content.State,
      Content.EventLog,
      Content.Timeline,
      Content.Build,
      Content.BuildErrors,
      Content.SearchResults,
      Content.Shell,
      Content.CaptionBarProgress,
      Content.TerminalOutput,
      Content.StepList,
      Content.CalltraceEditor,
      Content.Repl,
      Content.LowLevelCode,
      Content.RequestPanel,
      Content.TraceLog,
      # NS9's two panes. Listed here, and NOT in `editModeHiddenContentIds`,
      # which together is the whole of "both platforms get them": edit mode
      # shows them on the desktop and in a browser from one declaration.
      Content.TestResults,
      Content.Constraints,
      Content.Scratchpad,
      Content.Filesystem,
      Content.CommandPalette,
      Content.VCS,
      Content.UnifiedDiff,
      Content.Verification,
      Content.AgentActivity,
      Content.AgentActivityDeepReview,
      Content.AgentWorkspace,
      # Content.FrameViewer was retired in M3 — the Video Player pane
      # supersedes it.  ``FrameViewerVM`` remains as the data source the
      # Video Player wraps; see ``viewmodel/viewmodels/frame_viewer_vm.nim``.
      Content.PixelHistory,
      Content.ShaderDebug,
      Content.VideoPlayer,
    }

    var containerId: cstring
    containerId = state.label

    let panelObj = if not autoHideState.isNil: autoHideState.findPanelByContentAndId(state.content, state.id) else: nil
    let isReparentingObj = isReparenting

    discard windowSetTimeout((proc =
      if isReparentingObj:
        return
      if not data.ui.componentMapping[state.content].hasKey(state.id):
        discard data.makeComponent(state.content, state.id)
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]

        if not isDirectMountComponent:
          cwarn "layout: genericUiComponent has no direct mount for " &
            $state.content & " id " & $state.id

        # THE FIVE PANES THAT HAD NO ARM HERE.
        #
        # This proc is the only site that KNOWS the container exists:
        # `element.mountComponentContainer(editorLabel)` above has just built
        # `#<x>Component-<id>`, and this dispatch runs 200 ms later. Every
        # other pane in `isDirectMountComponent` has been mounted from here
        # all along. These five mounted from their `register` method or from
        # their `initXVMWithStore`, and then POLLED for a container that
        # neither of those moments can guarantee.
        #
        # Measured on 25 real Electron desktop session logs (2026-09), on the
        # modern shared-store path: `#stateComponent-0`,
        # `#calltraceComponent-0` and `#timelineComponent-0` were absent at
        # retry #1 in ALL 25 runs. The two that ran long enough to reach a
        # verdict gave up at retry #200, 10.9 s and 30.4 s of runway in:
        #
        #   ERROR | state.nim     | tryMountIsoNimStatePanel: not ready after 200 retries, giving up
        #   ERROR | calltrace.nim | tryMountIsoNimCalltrace: not ready after 200 retries, giving up
        #   DEBUG | trace.nim     | IsoNim timeline panel: not ready after 200 retries, giving up
        #
        # A 2026-09 TRANSCRIPT, PRE-DATING THE ARMS BELOW. Do not grep the
        # source for those three strings: the arms below made their claim
        # false — a give-up ends one poll, because each mount re-enters with a
        # fresh retry counter — and all three now `cwarn` that they abandoned
        # THIS poll rather than the pane. The transcript stays because it is
        # the measurement that put these arms here.
        #
        # The other 23 ended mid-poll between retry #20 and #110 with the
        # container still absent. There is no retry margin to widen: the poll
        # starts before the thing it polls for can exist, so it is not a race
        # a faster machine wins. The State, Call Trace and Timeline panes were
        # blank on the desktop for every one of those sessions.
        #
        # `1cb7b9d6` added the `register`-time call in `ui/state.nim` and it
        # genuinely fixed Noir Studio — but `CalltraceComponent.register` has
        # ALWAYS made the equivalent call, and calltrace still gave up on the
        # desktop in both runs above. On the desktop `register` runs at
        # component-construction time (`types.createUIComponents` in `onInit`),
        # which is EARLIER than the container, not later. A second poll window
        # opened before the container exists is still a poll that loses.
        #
        # Called unqualified: the module `state` is shadowed inside this
        # closure by its own `state: GoldenItemState` parameter, so
        # `state.tryMountIsoNimStatePanel()` would resolve against the wrong
        # `state`.
        if state.content == Content.State:
          tryMountIsoNimStatePanel()

        if state.content == Content.Calltrace:
          tryMountIsoNimCalltrace()

        # The Timeline was the worst-placed of the five and the reason nobody
        # reported it: `TimelineComponent` has no `register` method at all. It
        # falls back to the base method in `types.nim`, which only assigns
        # `self.api`, so the timeline was the one pane with NO mount call on
        # the component-registration path — its only callers were the two
        # `initTimelineVM*` procs. This arm is its first.
        if state.content == Content.Timeline:
          tryMountIsoNimTimelinePanel()

        # EventLog and TerminalOutput are the same shape as Calltrace: both
        # mount from `register` and nowhere else, and both are in
        # `isDirectMountComponent`. They are joined here so the invariant
        # `test_every_mountable_pane_has_a_factory_arm.nim` asserts — every
        # direct-mount `Content` has an arm — holds without an allowlist of
        # unexamined exemptions. Their mounts are idempotent and additionally
        # guarded on their own component ref, so this arm can only help.
        if state.content == Content.EventLog:
          tryMountIsoNimEventLogPanel()

        if state.content == Content.TerminalOutput:
          tryMountIsoNimTerminalOutputPanel()

        if state.content == Content.Shell:
          let shellComponent = ShellComponent(component)
          if shellComponent.shell.isNil:
            discard shellComponent.createShell()

        # Build is now an IsoNim view — its DOM is mounted by
        # `build.tryMountIsoNimBuildPanel` against the `buildComponent-{id}`
        # container, and reactive effects keep it in sync. No direct-DOM
        # redraw hook is needed here.
        if state.content == Content.Build:
          # The IsoNim view mounts itself once `buildComponentRef` and
          # the VM are both available (the registration order between
          # `register()` and `configureMiddleware` is non-deterministic
          # under different layouts).  Calling tryMount here is safe and
          # idempotent — it short-circuits when already mounted.  Also
          # sync any data the legacy ``build`` record already carries
          # (e.g. when the GL container appears after a recorded build
          # already finished).
          build.syncLegacyBuildIntoVM(BuildComponent(component))
          build.tryMountIsoNimBuildPanel()

        # BuildErrors is now an IsoNim view -- its DOM is mounted by
        # ``errors.tryMountIsoNimErrorsPanel`` against the
        # ``errorsComponent-{id}`` container, and reactive effects keep
        # it in sync. No direct-DOM redraw hook is
        # needed here.
        if state.content == Content.BuildErrors:
          errors.syncLegacyErrorsIntoVM(ErrorsComponent(component))
          errors.tryMountIsoNimErrorsPanel()

        # SearchResults is now an IsoNim view -- its DOM is mounted by
        # ``search_results.tryMountIsoNimSearchResultsPanel`` against
        # the ``searchResultsComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.SearchResults:
          search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(component))
          search_results.tryMountIsoNimSearchResultsPanel()

        # StepList is now an IsoNim view -- its DOM is mounted by
        # ``step_list.tryMountIsoNimStepListPanel`` against the
        # ``stepListComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.StepList:
          step_list.syncLegacyStepListIntoVM(StepListComponent(component))
          step_list.tryMountIsoNimStepListPanel()

        # CalltraceEditor is now an IsoNim view -- its DOM is mounted
        # by ``calltrace_editor.tryMountIsoNimCalltraceEditorPanel``
        # against the GoldenLayout-managed ``<div id="calls">``
        # container.  The panel is single-instance and the legacy
        # render produced an empty placeholder, so there is no
        # legacy state to sync into the VM.
        if state.content == Content.CalltraceEditor:
          calltrace_editor.tryMountIsoNimCalltraceEditorPanel()

        # Repl is now an IsoNim view -- its DOM is mounted by
        # ``repl.tryMountIsoNimReplPanel`` against the
        # ``replComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.Repl:
          repl.syncLegacyReplIntoVM(ReplComponent(component))
          repl.syncReplConfigIntoVM()
          repl.tryMountIsoNimReplPanel()

        # LowLevelCode is now an IsoNim view -- its outer container
        # is mounted by ``low_level_code.tryMountIsoNimLowLevelCodePanel``
        # against the ``lowLevelCodeComponent-{id}`` GoldenLayout host,
        # and reactive effects keep it in sync.  The Monaco-driven
        # asm buffer still lives inside the editor sub-tree (the
        # EditorViewComponent owns that DOM); the IsoNim view here
        # exposes the parity-faithful container shell + a fallback
        # row list so headless tests can exercise the same data flow
        # without Monaco.  Closes the no_source asm sub-tree
        # follow-up tracked from 1.40.
        if state.content == Content.LowLevelCode:
          low_level_code.syncLegacyLowLevelCodeIntoVM(
            LowLevelCodeComponent(component))
          low_level_code.tryMountIsoNimLowLevelCodePanel()

        # RequestPanel is now an IsoNim view -- its DOM is mounted by
        # ``request_panel.tryMountIsoNimRequestPanel`` against the
        # ``requestPanelComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``RequestPanelComponent``
        # remains as the event-bus carrier (its ``register`` subscribes to
        # ``CtUpdatedHttpRequests`` — RS-M3) and its mutators feed the VM via
        # ``syncLegacyRequestPanelIntoVM`` so the IsoNim view tracks
        # any rows already accumulated when the panel becomes visible.
        if state.content == Content.RequestPanel:
          request_panel.syncLegacyRequestPanelIntoVM(
            RequestPanelComponent(component))
          request_panel.tryMountIsoNimRequestPanel()

        # TraceLog is now an IsoNim view -- its DOM is mounted by
        # ``trace_log.tryMountIsoNimTraceLogPanel`` against the
        # ``traceLogComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``TraceLogComponent`` remains
        # as the event-bus carrier (its ``register`` method still
        # subscribes to tracepoint-result events) and
        # ``syncLegacyTraceLogIntoVM`` mirrors any rows already
        # accumulated when the panel becomes visible.
        # TestResults and Constraints are IsoNim views with no legacy half,
        # so there is nothing to sync -- the mount is the whole hook.
        if state.content == Content.TestResults:
          test_results.tryMountIsoNimTestResultsPanel()

        if state.content == Content.Constraints:
          constraints.tryMountIsoNimConstraintsPanel()

        if state.content == Content.TraceLog:
          trace_log.syncLegacyTraceLogIntoVM(TraceLogComponent(component))
          trace_log.tryMountIsoNimTraceLogPanel()

        # Scratchpad is now an IsoNim view -- its DOM is mounted by
        # ``scratchpad.tryMountIsoNimScratchpadPanel`` against the
        # ``scratchpadComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``ScratchpadComponent`` remains
        # as the event-bus carrier (its ``register`` method still
        # subscribes to ``InternalAddToScratchpad`` /
        # ``InternalAddToScratchpadFromExpression`` /
        # ``CtLoadLocalsResponse``) and ``syncLegacyScratchpadIntoVM``
        # mirrors any rows already accumulated when the panel becomes
        # visible.  Mission goal #3 §1.70.
        if state.content == Content.Scratchpad:
          scratchpad.syncLegacyScratchpadIntoVM(
            ScratchpadComponent(component))
          scratchpad.tryMountIsoNimScratchpadPanel()

        # Filesystem is now an IsoNim view -- its DOM is mounted by
        # ``filesystem.tryMountIsoNimFilesystemPanel`` against the
        # ``filesystemComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is
        # needed here.  The legacy ``FilesystemComponent`` remains as
        # the event-bus carrier (its existing event handlers populate
        # ``data.services.editor.filesystem``) and
        # ``syncLegacyFilesystemIntoVM`` mirrors any tree already
        # accumulated when the panel becomes visible.  Mission goal #3
        # \u00a71.71.  The rich jstree affordances (animated open/close,
        # contextmenu plugin, search plugin) remain a follow-up.
        if state.content == Content.Filesystem:
          filesystem.syncLegacyFilesystemIntoVM(
            FilesystemComponent(component))
          filesystem.tryMountIsoNimFilesystemPanel()

        # CommandPalette is now an IsoNim view -- its DOM is mounted by
        # ``command.tryMountIsoNimCommandPalettePanel`` against the
        # ``commandPaletteComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy
        # ``CommandPaletteComponent`` remains as the event-bus carrier
        # (the keyboard / interpreter / agent passthrough) and
        # ``syncLegacyCommandPaletteIntoVM`` mirrors any state already
        # accumulated when the panel becomes visible.  Mission goal #3
        # \u00a71.72.  The rich per-kind row rendering paths
        # (program-search HTML fragment, symbol-kind suffix, file-path
        # tail truncation, agent-mode passthrough) remain a follow-up.
        if state.content == Content.CommandPalette:
          command.syncLegacyCommandPaletteIntoVM(
            CommandPaletteComponent(component))
          command.tryMountIsoNimCommandPalettePanel()

        if state.content == Content.VCS:
          vcs.syncLegacyVCSIntoVM(VCSComponent(component))
          vcs.tryMountIsoNimVCSPanel(component.id)

        # A unified diff is an editor-area *document*, not a second VCS panel
        # (VCS-Panel.md, "Unified Diff View (Editor Integration)"): the sync
        # parses the target's hunks into the tab's ViewModel and the mount
        # creates the Monaco instance over them.
        if state.content == Content.UnifiedDiff:
          unified_diff.syncIntoVM(UnifiedDiffComponent(component))
          unified_diff.tryMountUnifiedDiffTab(component.id)

        # VN-M5. The verification panel is an IsoNim view with no legacy
        # renderer at all, so there is nothing to sync into a VM first: the
        # `VerificationComponent` carries no state. Its mount puts TWO IsoNim
        # roots in the container — the run, and the counterexample the run
        # produced — and the second is empty until a session is opened from
        # the first.
        if state.content == Content.Verification:
          verification.tryMountIsoNimVerificationPanel()

        if state.content == Content.AgentActivity:
          agent_activity.syncLegacyAgentActivityIntoVM(
            AgentActivityComponent(component))
          agent_activity.tryMountIsoNimAgentActivityPanel(component.id)

        # ``Content.AgentActivityDeepReview`` has no renderer of its own since
        # AA-1 deleted the roll-up.  The id survives as the review's layout
        # identity for the Agent Activity pillar (see the note on the
        # ``Content`` enum), so a layout persisted by an older build still
        # constructs its component and gets an empty pane; there is nothing to
        # mount into it until AA-2/AA-3 render the session's own content.

        if state.content == Content.AgentWorkspace:
          agent_workspace.syncLegacyAgentWorkspaceIntoVM(
            AgentWorkspaceComponent(component))
          agent_workspace.tryMountIsoNimAgentWorkspacePanel(component.id)

        # Content.FrameViewer pane dispatch was retired in M3.  The legacy
        # frame_viewer.nim now only owns the FrameViewerVM bootstrap that
        # other panes (Video Player, Pixel History, Shader Debug) share.

        if state.content == Content.PixelHistory:
          pixel_history.tryMountIsoNimPixelHistoryPanel(
            PixelHistoryComponent(component))

        if state.content == Content.ShaderDebug:
          shader_debug.tryMountIsoNimShaderDebugPanel(
            ShaderDebugComponent(component))

        if state.content == Content.VideoPlayer:
          video_player.syncVisualReplaySessionIntoPlayerVM()
          video_player.tryMountIsoNimVideoPlayerPanel(
            VideoPlayerComponent(component))

        # CaptionBarProgress: render via IsoNim WebRenderer directly
        # into the GL container. Progress and hover mutation paths refresh
        # this direct mount explicitly.
        if state.content == Content.CaptionBarProgress:
          tryMountCaptionBarProgress(
            containerId,
            CaptionBarProgressComponent(component))

        discard component.afterInit()

      ), 200)

  # Widen the splitter grab zone so it is easier to grab with the mouse.
  # The per-stack minimum width is enforced dynamically by enforceMinStackWidth
  # (called after loadLayout and on every stateChanged) so it stays constant
  # regardless of how many tabs are open in the stack.
  {.emit: """
    if (!`initialLayout`.dimensions) `initialLayout`.dimensions = {};
    `initialLayout`.dimensions.borderGrabWidth = 8;
    `initialLayout`.dimensions.headerHeight = `data`.ui.fontSize * 2;
  """.}
  # NEVER call `loadLayout` directly here: a config GoldenLayout rejects
  # throws a native JS Error that Nim cannot catch, which would abort the
  # rest of this proc (auto-hide, event handlers, standalone panels) and
  # leave a half-initialised window — issue #608.
  loadLayoutSafely(layout, initialLayout)
  enforceMinStackWidth(layout)

  # M21: Register IPC handler for receiving panels from other windows.
  # Desktop only: a web build has no second window to receive a pane FROM, so
  # there is no event to handle. See this file's `panel_transfer` import.
  when not defined(ctWeb):
    registerPanelAttachHandler(layout)

  # Auto-hide panes: initialise state and set up the edge strip renderer
  # and overlay event handlers.
  initAutoHideState()

  # Restore the panels the user pinned to a screen edge in an earlier
  # session.  This has to happen here — after `initAutoHideState`, before the
  # 500 ms standalone-panel registration below — because that loop skips any
  # content already present in the auto-hide state (`findPanelByContent`),
  # which is what stops a restored BUILD/PROBLEMS/SEARCH/REQUESTS panel from
  # being duplicated as a fresh standalone one.
  #
  # Before this call `restoreAutoHideState` had zero call sites and the state
  # was posted to an IPC channel nobody listened on, so pinning a panel never
  # survived a restart (issue #608).
  #
  # Once per renderer process, not once per `initLayout`: creating or
  # switching to another session calls this proc again against the SAME
  # module-level `autoHideState`, and `restoreAutoHideState` appends, so a
  # second restore would duplicate every pinned panel in the strips.
  if not autoHideStateRestored:
    autoHideStateRestored = true
    let savedAutoHideState = requestSavedAutoHideState()
    if not savedAutoHideState.isNil and not savedAutoHideState.isUndefined:
      restoreAutoHideState(savedAutoHideState)

  setupDragToPinListeners(layout)
  setupClickToFocusListeners()
  setupSelectedPanelOutline()
  setupDropdownDismissListeners()
  auto_hide.unpinPanelTarget = proc(layout: GoldenLayout, panel: AutoHidePanel) =
    let isEditor = panel.config.componentState.isEditor.to(bool)
    let edge = panel.edge
    # Place the panel in its own new standalone group at the correct edge.
    # We call addItem(config, index) directly on the main row/column —
    # GL2 wraps the component in a fresh stack automatically.
    #
    # AutoHideEdge ordinals: Bottom=0, Left=1, Right=2
    let ground = layout.groundItem
    if ground.isNil or ground.contentItems.len == 0:
      discard ground.addItem(panel.config)
      return

    let main = ground.contentItems[0]

    case edge:
    of AutoHideEdge.Left:
      # Prepend: insert at position 0 of the main row.
      discard main.addItem(panel.config, 0)
    of AutoHideEdge.Right:
      # Append: insert after all existing children.
      discard main.addItem(panel.config, main.contentItems.len)
    of AutoHideEdge.Bottom:
      # If the main container is already a column, append the panel as a new
      # standalone stack at the very bottom.  For a flat row (the common case)
      # append it at the end of the row — it still gets its own group and GL
      # avoids the restructuring that causes the component to disappear.
      discard main.addItem(panel.config, main.contentItems.len)
  # When an auto-hide panel's overlay is shown, refresh that panel's mounted
  # surface so it displays current content after reparenting.
  autoHideState.onPanelShown = proc(panel: AutoHidePanel) =
    # Map Content type to the renderer label used by standalone panels.
    let label = case panel.content
      of Content.Build:         cstring"buildComponent-0"
      of Content.BuildErrors:   cstring"errorsComponent-0"
      of Content.SearchResults: cstring"searchResultsComponent-0"
      of Content.RequestPanel:  cstring"requestPanelComponent-0"
      else:
        # For panels pinned from GL, try the standard label format.
        convertComponentLabel(panel.content, panel.componentId)
    # Standalone auto-hide panels are direct IsoNim mounts.  Opening the
    # overlay reparents their existing wrapper, so refresh the specific
    # ViewModel-backed mount in place.
    if panel.content == Content.Build:
      let buildComp = data.ui.componentMapping[Content.Build][0]
      if not buildComp.isNil:
        build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
      build.isoNimBuildMounted = false
      build.tryMountIsoNimBuildPanel()
      return
    if panel.content == Content.BuildErrors:
      let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
      if not errorsComp.isNil:
        errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
      errors.isoNimErrorsMounted = false
      errors.tryMountIsoNimErrorsPanel()
      return
    if panel.content == Content.SearchResults:
      let srComp = data.ui.componentMapping[Content.SearchResults][0]
      if not srComp.isNil:
        search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
      search_results.isoNimSearchResultsMounted = false
      search_results.tryMountIsoNimSearchResultsPanel()
      return
    if panel.content == Content.RequestPanel:
      let reqComp = data.ui.componentMapping[Content.RequestPanel][0]
      if not reqComp.isNil:
        request_panel.syncLegacyRequestPanelIntoVM(RequestPanelComponent(reqComp))
      request_panel.tryMountIsoNimRequestPanel()
      return
    # Pinned GoldenLayout panels already carry a liveElement that showOverlay()
    # reparents into the overlay. Remaining legacy-backed GL panels (currently
    # Editor) keep their renderer instance behind renderer.nim; IsoNim-owned
    # panels have no instance and need no work here.
    discard renderer.redrawLegacyRendererInstance(label)

  autoHideState.onChanged = proc() =
    # Re-render the side strip tabs whenever the auto-hide state changes.
    # Left and right strip hosts are static DOM nodes in the layout row; their
    # contents and sizing classes are now refreshed through IsoNim directly.
    requestAutoHideSideStripRender(
      cstring"auto-hide-strip-left",
      AutoHideEdge.Left)
    requestAutoHideSideStripRender(
      cstring"auto-hide-strip-right",
      AutoHideEdge.Right)
    # The bottom strip lives in #status-base. Ask the status bar to refresh
    # so the #auto-hide-bottom-strip host exists, then mount the strip into
    # it. Once the host exists the status render no longer destroys it (it
    # patches values in place — see `ui/status.nim`), so the mount below is
    # what actually updates the tabs; when the host is still missing the
    # mount is a no-op and the status render's own rebuild path re-mounts
    # the strip as soon as it has created the host.
    if not data.ui.status.isNil:
      data.ui.status.requestStatusRender()
    requestAutoHideBottomStripRender(cstring"auto-hide-bottom-strip")
    # …and the collapsed status-bar icon zone, for the same reason and on the
    # same terms as the bottom strip: it is a host inside the status shell, so
    # the mount below is a no-op while the host is missing and `ui/status.nim`
    # re-mounts it whenever it rebuilds the shell.
    #
    # This line was missing, and its absence is a real defect rather than a
    # missed optimisation.  When the strips are collapsed — the normal state for
    # a maximized window, `Planned-Features/Auto-Hide-Panes.md` §1.3 — the side
    # strip renders as a 1 px accent line with no tabs, and §10 makes the icon
    # zone the replacement affordance: "This icon zone serves as the panel
    # directory — it tells the user which panels" are pinned.  With no render
    # request here, pinning a panel while collapsed left the zone empty until
    # something unrelated happened to rebuild the status shell, so the panel had
    # no visible affordance at all.
    requestCollapsedIconZoneRender(cstring"auto-hide-collapsed-icon-zone")
    # Persist here rather than only from the `stateChanged` handler below.
    # Pinning is a REPARENT, and `itemDestroyed` deliberately returns early
    # while `data.ui.isReparenting` is set, so a pin can complete without
    # ever setting `data.ui.saveLayout` — the flag that gates the save in
    # `stateChanged`.  Hanging the write off the auto-hide state's own
    # change hook makes the persistence follow the thing being persisted.
    persistAutoHideState()

  requestAutoHideSideStripRender(
    cstring"auto-hide-strip-left",
    AutoHideEdge.Left)
  requestAutoHideSideStripRender(
    cstring"auto-hide-strip-right",
    AutoHideEdge.Right)
  requestAutoHideBottomStripRender(cstring"auto-hide-bottom-strip")

  # Wire overlay header buttons and dismissal handlers.
  setupAutoHideOverlay(layout)

  # Register the standalone auto-hide bottom panes — BUILD, PROBLEMS,
  # SEARCH RESULTS and REQUESTS. These panels are not part of the GL layout
  # — they live exclusively in the auto-hide state and appear as clickable
  # labels in the status bar footer.
  #
  # `standaloneAutoHidePanels` below is the single source of this set, and
  # its LENGTH is an observable contract: it is the tab count every
  # auto-hide GUI spec measures a pin against, mirrored in
  # `src/tests/gui/page-objects/auto-hide-strip.ts` as
  # `DEFAULT_BOTTOM_TAB_TITLES`. Adding or removing an entry here must be
  # mirrored there, or those specs fail on the count rather than on what
  # they meant to test.
  #
  # We use a short timeout to run after GL has finished creating all
  # component containers from the layout config. This lets us detect
  # whether these panels exist as GL tabs (from a saved layout that
  # still includes them) and pin them from GL, or create standalone
  # auto-hide panels if they were never in GL (the default layout).
  # Create a hidden container in the DOM to host standalone auto-hide panel
  # elements. The auto-hide overlay reparents the wrapper elements when shown.
  var autoHideHost = kdom.document.getElementById(cstring"auto-hide-standalone-host")
  if autoHideHost.isNil:
    autoHideHost = kdom.document.createElement("div")
    autoHideHost.id = cstring"auto-hide-standalone-host"
    # Use offscreen positioning instead of display:none so mounts keep
    # measurable host dimensions while hidden.
    autoHideHost.style.position = cstring"absolute"
    autoHideHost.style.left = cstring"-9999px"
    autoHideHost.style.width = cstring"1px"
    autoHideHost.style.height = cstring"1px"
    autoHideHost.style.overflow = cstring"hidden"
    kdom.document.body.appendChild(autoHideHost)

  discard windowSetTimeout(proc() =
    type AutoHidePanelDef = tuple
      content: Content
      title: cstring
      label: cstring   ## The component label used as DOM id and renderer key

    let standaloneAutoHidePanels: seq[AutoHidePanelDef] = @[
      (content: Content.Build,         title: cstring"BUILD",          label: cstring"buildComponent-0"),
      (content: Content.BuildErrors,   title: cstring"PROBLEMS",       label: cstring"errorsComponent-0"),
      (content: Content.SearchResults, title: cstring"FIND IN FILES", label: cstring"searchResultsComponent-0"),
      (content: Content.RequestPanel,  title: cstring"REQUESTS",       label: cstring"requestPanelComponent-0"),
    ]

    let host = kdom.document.getElementById(cstring"auto-hide-standalone-host")

    for panelDef in standaloneAutoHidePanels:
      # Skip if this content is already in the auto-hide state (e.g.
      # restored from a saved layout or previously pinned by the user).
      if not autoHideState.isNil:
        let existing = autoHideState.findPanelByContent(panelDef.content)
        if not existing.isNil:
          if existing.standalone or not existing.liveElement.isNil:
            continue
          # A pinned-state entry restored from disk for one of the four
          # standalone panes: it has no live element, and unlike a restored
          # GL panel there is no component config the overlay could build one
          # from.  Leaving it in place would suppress the registration below
          # and leave a strip tab whose overlay is empty, so drop it and
          # register the standalone pane normally.
          cwarn "auto_hide: replacing a restored entry for standalone pane '" &
            $panelDef.title & "' with a fresh registration"
          autoHideState.panels = autoHideState.panels.filterIt(it != existing)

      # Check if GL created a container for this component (from a saved
      # layout that still includes it). If so, find the GL content item
      # and pin it rather than creating a standalone panel.
      let glContainerDiv = kdom.document.getElementById(panelDef.label)
      if not glContainerDiv.isNil and not glContainerDiv.parentNode.isNil:
        # The component exists in GL. Find its content item by walking
        # up from the component mapping's layoutItem.
        #
        # THE `continue` IS AT THIS LEVEL DELIBERATELY, and it used to be one
        # level deeper. The question this branch answers is "did GoldenLayout
        # already emit a container carrying this id?", and once the answer is
        # yes there is nothing below that may run — the code below creates a
        # div with `id = panelDef.label`, so reaching it would put a SECOND
        # element with the same id in the document.
        #
        # That is not hypothetical. `layoutItem` is assigned only from GL's tab
        # callback (`:1013`, `:1174`) and the component itself is built inside
        # a deferred `windowSetTimeout` (`:1264`), while this loop runs on its
        # own fixed 500 ms timer — so on a layout saved with the pane docked,
        # "container exists, `layoutItem` not populated yet" is an ordinary
        # race outcome, not a corner. Measured before this change with the
        # container present and `layoutItem` nil: two `#errorsComponent-0`
        # nodes, the GL one holding the mounted panel and an empty duplicate
        # parked in the offscreen host at x = -9999.
        #
        # It stays broken after the duplicate is gone, because
        # `ui/errors.nim`'s `tryMountIsoNimErrorsPanel` resolves its container
        # with `getElementById` — which returns the FIRST match — and
        # `mountIsoNimErrors` has no owner and no disposal. Any of the five
        # sites that reset `isoNimErrorsMounted` could then remount into a
        # different node and leave the previous subtree live. One id, one node.
        let component = data.ui.componentMapping[panelDef.content][0]
        if not component.isNil and not component.layoutItem.isNil:
          cdebug "auto_hide: pinning GL panel '" & $panelDef.title & "' to bottom auto-hide"
          pinPanel(layout, component.layoutItem, AutoHideEdge.Bottom)
        else:
          # GL owns the container but we cannot reach its content item yet, so
          # there is nothing to pin. Say so rather than falling through: a
          # silent skip here is indistinguishable from a pane that was pinned,
          # and the duplicate this used to create was the only evidence the
          # state had been reached at all.
          cwarn "auto_hide: '" & $panelDef.title & "' has a GoldenLayout " &
            "container but no resolvable layoutItem; not pinning, and NOT " &
            "creating a standalone duplicate of id '" & $panelDef.label & "'"
        continue

      # Panel is not in GL — create a standalone auto-hide panel with
      # its own DOM container. Build/BuildErrors/SearchResults are now
      # IsoNim-migrated and mount via the IsoNim reactive root, so they
      # need no redraw hook.

      # Create a wrapper element that the auto-hide overlay will
      # reparent when the panel is shown.
      let wrapper = kdom.document.createElement("div")
      wrapper.id = cstring("auto-hide-standalone-" & $panelDef.label)
      wrapper.class = cstring"auto-hide-standalone-container"
      wrapper.style.width = cstring"100%"
      wrapper.style.height = cstring"100%"

      # Inner div matching the component label id.
      let innerDiv = kdom.document.createElement("div")
      innerDiv.id = panelDef.label
      innerDiv.class = cstring"component-container"
      wrapper.appendChild(innerDiv)

      # Attach to the hidden host so getElementById can find the element.
      if not host.isNil:
        host.appendChild(wrapper)

      # Every standalone auto-hide panel (Build, BuildErrors,
      # SearchResults, RequestPanel) is an IsoNim view.  Each mounts itself
      # against the inner div the next time its ``tryMountIsoNim*``
      # runs; the reactive root keeps the DOM in sync automatically.
      if panelDef.content == Content.Build:
        try:
          let buildComp = data.ui.componentMapping[Content.Build][0]
          if not buildComp.isNil:
            build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
          build.isoNimBuildMounted = false
          build.tryMountIsoNimBuildPanel()
        except:
          cerror "auto_hide: tryMountIsoNimBuildPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      elif panelDef.content == Content.BuildErrors:
        try:
          let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
          if not errorsComp.isNil:
            errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
          errors.isoNimErrorsMounted = false
          errors.tryMountIsoNimErrorsPanel()
        except:
          cerror "auto_hide: tryMountIsoNimErrorsPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      elif panelDef.content == Content.SearchResults:
        try:
          let srComp = data.ui.componentMapping[Content.SearchResults][0]
          if not srComp.isNil:
            search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
          search_results.isoNimSearchResultsMounted = false
          search_results.tryMountIsoNimSearchResultsPanel()
        except:
          cerror "auto_hide: tryMountIsoNimSearchResultsPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      elif panelDef.content == Content.RequestPanel:
        try:
          let reqComp = data.ui.componentMapping[Content.RequestPanel][0]
          if not reqComp.isNil:
            request_panel.syncLegacyRequestPanelIntoVM(RequestPanelComponent(reqComp))
          request_panel.tryMountIsoNimRequestPanel()
        except:
          cerror "auto_hide: tryMountIsoNimRequestPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      addStandaloneAutoHidePanel(
        panelDef.title,
        panelDef.content,
        componentId = 0,
        liveElement = wrapper,
        edge = AutoHideEdge.Bottom)
  , 500)  # 500ms delay lets GL finish its internal layout cycle

  # Expose redrawAll on window so E2E tests can trigger Karax re-renders
  # after injecting data into component state.
  # Also expose a helper to re-render a specific auto-hide panel by content ID.
  # Expose helper functions on window for E2E tests.
  proc renderAutoHidePanelById(contentId: int) =
    ## Re-render a standalone auto-hide panel by content ID.
    ## Build, BuildErrors, and SearchResults are all IsoNim views:
    ## sync any legacy state (E2E tests inject directly into
    ## ``build.output`` / ``build.problems`` / search service results)
    ## into the VM and then re-mount.
    if contentId == int(Content.Build):
      let buildComp = data.ui.componentMapping[Content.Build][0]
      if not buildComp.isNil:
        build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
      build.isoNimBuildMounted = false
      build.tryMountIsoNimBuildPanel()
      return
    if contentId == int(Content.BuildErrors):
      # ``syncLegacyBuildIntoVM`` already pushed the bulk-replay path
      # for the Build panel into both ``BuildVM`` and ``ErrorsVM``;
      # explicitly re-syncing here covers the case where E2E tests
      # call ``__ctRenderPanel(21)`` after mutating
      # ``build.problems`` directly without re-rendering the Build
      # panel first.
      let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
      if not errorsComp.isNil:
        errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
      errors.isoNimErrorsMounted = false
      errors.tryMountIsoNimErrorsPanel()
      return
    if contentId == int(Content.SearchResults):
      let srComp = data.ui.componentMapping[Content.SearchResults][0]
      if not srComp.isNil:
        search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
      search_results.isoNimSearchResultsMounted = false
      search_results.tryMountIsoNimSearchResultsPanel()
      return

  # Expose a helper to pin a GL content item to an auto-hide edge.
  # Used by E2E tests to bypass the dropdown UI which has blur race issues.
  # Edge: 0 = Left, 1 = Right, 2 = Bottom.
  proc pinContentItemToEdge(contentItemJs: js, edgeInt: int) =
    let edge = AutoHideEdge(edgeInt)
    let contentItem = cast[GoldenContentItem](contentItemJs)
    pinPanel(layout, contentItem, edge)

  # Expose a helper to create a new session tab.
  # Used by E2E tests because the "+" button is hidden when only one
  # session exists (the tab bar in the caption bar has `display: none`
  # via `.single-session`).
  proc createNewSessionHelper() =
    createNewSession(data)

  # Force collapsed mode on/off for E2E tests.  Bypasses maximize
  # detection so tests can capture collapsed-mode screenshots without
  # actually maximizing the window.
  #
  # The override is STICKY.  Without this, `updateCollapsedMode` below — which
  # runs on every window `resize`, plus once 1 s after layout init — simply
  # overwrote the forced value from its maximize heuristic, so the override
  # silently expired at the next resize.  Under Xvfb the window
  # fills the virtual screen, so the heuristic answers "maximized", and a spec
  # that had asked for expanded strips would find `#auto-hide-strip-left`
  # rendered as the 1 px `collapsed-strip-line` with its tabs gone —
  # `auto-hide-panes.spec.ts`'s "editor unpin behavior" failed exactly that
  # way, with the tab detached from under `locator.hover`.
  #
  # There is deliberately no way to clear the override: only test hooks set it,
  # and a test that has pinned the rendering mode wants it pinned for the rest
  # of the process.
  var collapsedModeForced = false
  var collapsedModeForcedValue = false

  proc forceCollapsedMode(enable: bool) =
    if autoHideState.isNil:
      initAutoHideState()
    collapsedModeForced = true
    collapsedModeForcedValue = enable
    autoHideState.collapsedMode = enable
    autoHideState.leftBounded = enable
    autoHideState.rightBounded = enable
    if not autoHideState.onChanged.isNil:
      autoHideState.onChanged()

  # Render side-edge tabs into the overlay's side-tab container.
  # Called from onPanelShown and whenever the overlay edge changes.
  proc renderOverlaySideTabs() =
    requestOverlaySideEdgeTabsRender(cstring"auto-hide-overlay-side-tabs")

  # Wire onPanelShown to also render side-edge tabs.
  let originalOnPanelShown = autoHideState.onPanelShown
  autoHideState.onPanelShown = proc(panel: AutoHidePanel) =
    if not originalOnPanelShown.isNil:
      originalOnPanelShown(panel)
    renderOverlaySideTabs()

  {.emit: """
    window.__ctRedrawAll = function() {
      `redrawAll`();
    };
    window.__ctRenderPanel = function(contentId) {
      `renderAutoHidePanelById`(contentId);
    };
    window.__ctPinPanel = function(contentItemJs, edgeInt) {
      `pinContentItemToEdge`(contentItemJs, edgeInt);
    };
    window.__ctCreateNewSession = function() {
      `createNewSessionHelper`();
    };
    window.__ctRequestSessionTabsRender = function() {
      `requestSessionTabsRender`(`data`);
    };
    window.__ctForceCollapsedMode = function(enable) {
      `forceCollapsedMode`(enable);
    };
  """.}

  # ---------------------------------------------------------------------------
  # Maximize detection for collapsed-mode auto-hide strips.
  # When the window is maximized and an edge is bounded (no adjacent monitor),
  # side strips collapse to a 1px accent line.
  # ---------------------------------------------------------------------------
  proc updateCollapsedMode() =
    ## Check if the window is maximized and update collapsed mode.
    ## Each edge is evaluated independently for adjacent monitors.
    ## This is a simplified check — full multi-monitor detection requires
    ## Electron's screen API (done via IPC in main process).
    ## For now, we use a heuristic: if outerWidth ~= screen.availWidth
    ## and outerHeight ~= screen.availHeight, the window is maximized.
    ##
    ## An explicit `forceCollapsedMode` override wins: see the note there.
    if collapsedModeForced:
      if not autoHideState.isNil and
         autoHideState.collapsedMode != collapsedModeForcedValue:
        autoHideState.collapsedMode = collapsedModeForcedValue
        autoHideState.leftBounded = collapsedModeForcedValue
        autoHideState.rightBounded = collapsedModeForcedValue
        if not autoHideState.onChanged.isNil:
          autoHideState.onChanged()
      return
    {.emit: """
      var isMax = (window.outerWidth >= screen.availWidth - 8) &&
                  (window.outerHeight >= screen.availHeight - 8);
    """.}
    var isMax {.importc, nodecl.}: bool
    if not autoHideState.isNil:
      let wasCollapsed = autoHideState.collapsedMode
      autoHideState.collapsedMode = isMax
      # Simplified bounded-edge detection: when maximized, assume both
      # left and right edges are bounded.  Full multi-monitor detection
      # via Electron's screen API is a future enhancement.
      autoHideState.leftBounded = isMax
      autoHideState.rightBounded = isMax
      if wasCollapsed != isMax:
        if not autoHideState.onChanged.isNil:
          autoHideState.onChanged()

  # Check on initial load and on window resize/maximize.
  discard windowSetTimeout(proc() = updateCollapsedMode(), 1000)

  proc requestMenuRenderAfterResize() =
    ## Refresh the caption bar after a resize, at most once per 50 ms.
    ##
    ## The menu has to be re-rendered on resize because `model.maximized` is
    ## recomputed only at render time (`ui/menu.nim`'s
    ## `isWindowMaximizedForMenu`), so the maximize/restore glyph goes stale
    ## otherwise.
    ##
    ## THROTTLED, because `requestMenuRender` is not cheap and not coalesced
    ## itself: each call clears and rebuilds `#menu` wholesale and then
    ## cascades into the session tab bar, the debug shell, the command
    ## palette and the debug controls.  A drag-resize emits `resize`
    ## continuously, so calling it per event rebuilds the entire caption
    ## chrome dozens of times a second and destroys the command-palette
    ## input's focus and caret along with it.
    ##
    ## 50 ms mirrors `ui/session_tabs.nim`'s `installResizeRender`, which
    ## throttles the tab bar against the same event for the same reason;
    ## `ui/status.nim`'s `requestStatusRender` is the other precedent.
    if menuResizeRenderPending:
      return
    menuResizeRenderPending = true
    discard windowSetTimeout(proc() =
      menuResizeRenderPending = false
      if not data.ui.menu.isNil:
        data.ui.menu.requestMenuRender(),
      50)

  {.emit: """
    window.addEventListener('resize', function() {
      `updateCollapsedMode`();
      `requestMenuRenderAfterResize`();
    });
  """.}

  # THE SHUTDOWN SEAM. `renderer.saveCurrentLayoutConfig` runs on
  # `beforeunload` and cannot reach `mode_layouts` (the import runs the other
  # way), so it calls this. Assigned here, beside the layout it is about, and
  # only once a layout exists to snapshot.
  persistModeLayoutHook = proc(d: Data) =
    mode_layouts.rememberModeLayout(d, d.ui.mode)

  layout.on(cstring"stateChanged") do (event: js):
    cdebug "layout event: stateChanged"
    enforceMinStackWidth(layout)

    # check if only one tab is left and prevent user from close/drag it
    let mainContainer = data.ui.layout.groundItem.contentItems[0]
    if mainContainer.contentItems.len == 1 and
      mainContainer.contentItems[0].isStack and
      mainContainer.contentItems[0].contentItems.len == 1 and
      mainContainer.contentItems[0].contentItems[0].isComponent:
      mainContainer.contentItems[0].contentItems[0]
        .tab.element.style.pointerEvents = cstring"none"
    else:
      let tabElements = jqAll(".lm_tab")
      for element in tabElements:
        element.style.pointerEvents = cstring"auto"

    if not data.ui.layout.isNil and data.ui.saveLayout:
      data.ui.resolvedConfig = data.ui.layout.saveLayout()
      data.saveConfig(data.ui.layoutConfig.fromResolved(data.ui.resolvedConfig))
      # AND INTO THE CURRENT MODE'S OWN CELL AND STORE.
      #
      # `saveConfig` above is the DESKTOP's persistence: it sends the layout to
      # the index process, which picks the file by mode. A browser has no index
      # process, so before this line a web user's arrangement reached nothing
      # that survived the tab — every drag was forgotten by the next reload,
      # and "saved between sessions" was true of one platform.
      #
      # It is also what keeps the register current between switches. Without
      # it, `applyModeLayout` would snapshot the live layout at the moment of
      # the switch and that would be enough — but only for a session that
      # switches. A user who arranges Edit mode and reloads without ever
      # entering Debug mode has made an arrangement that nothing recorded.
      #
      # `data.ui.mode` is the right mode to read HERE, unlike at a transition:
      # this fires on a user gesture in a settled session, so the layout on
      # screen is by definition the current mode's.
      mode_layouts.rememberModeLayout(data, data.ui.mode)
      data.ui.saveLayout = false

      # Persist auto-hide panel state alongside the GL layout config.
      # It travels on its own IPC channel and lands in its own file because
      # a pinned panel is precisely a panel the GoldenLayout config no
      # longer contains.  `autoHideState.onChanged` writes it too — this
      # call additionally covers changes that never reach that hook, such
      # as a resized overlay.
      persistAutoHideState()

    dispatchLayoutUpdated()

  layout.on(cstring"stackCreated") do (event: js):
    cdebug "layout event: stackCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"columnCreated") do (event: js):
    cdebug "layout event: columnCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"rowCreated") do (event: js):
    cdebug "layout event: rowCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"itemDestroyed") do (event: js):
    cdebug "layout event: itemDestroyed"
    if not data.ui.isNil and data.ui.isReparenting:
      cdebug "layout event: itemDestroyed - suppressed during reparenting"
      return
    if not data.ui.isNil and data.ui.isLoadingLayout:
      # A wholesale layout swap is not the user closing tabs — see `swapLayout`.
      cdebug "layout event: itemDestroyed - suppressed during a layout swap"
      return

    let eventTarget = cast[GoldenContentItem](event.target)

    if eventTarget.isComponent:
      let componentState = cast[GoldenItemState](eventTarget.toConfig().componentState)

      if componentState.isEditor:
        let id = componentState.fullPath
        let editorService = data.services.editor

        if editorService.open.hasKey(id):
          data.closeEditorTab(id)

      data.closeLayoutTab(componentState.content, componentState.id)

    data.ui.saveLayout = true
    dispatchLayoutUpdated()

# Wire the initLayout proc into session_switch to break the circular
# import dependency (layout -> session_tabs -> session_switch -> layout).
setInitLayoutProc(initLayout)

# Wire the tab-bar setup so that switchSession can ensure and refresh the
# direct IsoNim mount for ``#session-tab-bar`` even when initLayout is not
# called (e.g. for empty sessions).
proc ensureTabBarRenderer() =
  requestSessionTabsRender(data)
  # Use a short delay as a fallback for paths where the surrounding shell has
  # just been mounted and the flex-row host may not be available until the next
  # tick.
  discard windowSetTimeout(proc() = requestSessionTabsRender(data), 50)
setEnsureTabBarRendererProc(ensureTabBarRenderer)
