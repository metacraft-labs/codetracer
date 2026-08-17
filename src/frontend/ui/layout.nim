import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  state, editor, debug, menu, status, command, search_results, shell, deepreview, session_tabs, build, errors, step_list,
  welcome_screen,
  calltrace_editor, repl, low_level_code, request_panel, trace_log, scratchpad, filesystem,
  frame_viewer, pixel_history, shader_debug, video_player,
  vcs, unified_diff,
  agent_activity, agent_activity_deepreview, agent_workspace,
  session_switch, panel_transfer, auto_hide, auto_hide_overlay,
  caption_bar_progress,
  ../[ types, renderer, config, utils ],
  ../index/layout_config_repair,
  ../lib/[ logging, misc_lib, jslib ]

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

proc pinActiveContentItem(layout: js, stack: js, edge: AutoHideEdge) =
  ## Pin the currently active tab in `stack` to the given auto-hide edge.
  ## Uses `getActiveContentItem` to find what to detach.
  let activeItem = stack.getActiveContentItem()
  if activeItem.isNil or activeItem.isUndefined:
    cwarn "auto_hide: no active content item in stack"
    return
  pinPanel(cast[GoldenLayout](layout), cast[GoldenContentItem](activeItem), edge)

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


proc createLayoutDropdown(layout: js, stackCreatedEvent: Event): kdom.Element =
  ## Build the GoldenLayout stack-header dropdown directly.
  ##
  ## This intentionally preserves the legacy class names and labels used by
  ## the auto-hide GUI specs while keeping the dropdown on the direct-DOM path.
  result = kdom.document.createElement("div")
  result.class = cstring"layout-dropdown menu-node-container hidden"
  result.id = cstring"layout-dropdown-toggle"

  template appendDropdownItem(label: cstring, body: untyped) =
    let item = kdom.document.createElement("div")
    item.class = cstring"layout-dropdown-node ct-menu-item"
    item.innerHTML = label
    item.addEventListener(cstring"click", proc(e {.inject.}: Event) =
      body
    )
    result.appendChild(item)

  appendDropdownItem(cstring"Close all"):
    stackCreatedEvent.toJs.target.parent.removeChild(stackCreatedEvent.target)

  appendDropdownItem(cstring"Maximise container"):
    if cast[bool](stackCreatedEvent.toJs.target.isMaximised):
      stackCreatedEvent.toJs.target.minimise()
      e.toJs.target.innerHTML = cstring"Maximise container"
    else:
      stackCreatedEvent.toJs.target.maximise()
      e.toJs.target.innerHTML = cstring"Minimise container"

  appendDropdownItem(cstring"Pin to Bottom"):
    pinActiveContentItem(layout, stackCreatedEvent.toJs.target, AutoHideEdge.Bottom)
  appendDropdownItem(cstring"Pin to Left"):
    pinActiveContentItem(layout, stackCreatedEvent.toJs.target, AutoHideEdge.Left)
  appendDropdownItem(cstring"Pin to Right"):
    pinActiveContentItem(layout, stackCreatedEvent.toJs.target, AutoHideEdge.Right)

proc closeLayoutTab*(data: Data, content: Content, id: int) =
  if not data.ui.componentMapping[content].hasKey(id):
    raise newException(Exception, "There is not any component with the given id.")

  # Detach the component from the event bus BEFORE it leaves the registry.
  # Dropping the reference alone is not enough: the component's handlers live
  # on its private mediator, which is itself registered as a subscriber of
  # `data.viewsApi`, so a closed panel keeps receiving (and acting on) every
  # event it ever subscribed to.  Re-opening the panel then adds a second
  # live handler, and each closed generation multiplies the effect — this is
  # what made "Add to Scratchpad" append the same value once per generation
  # (#612).  `itemDestroyed` suppresses this path while auto-hide is
  # reparenting a panel, so a pinned panel is never unregistered here.
  let closedComponent = data.ui.componentMapping[content][id]
  if not closedComponent.isNil:
    closedComponent.unregister()

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

  let bundled = tryParseLayoutJson(cstring(bundledDefaultLayoutJson))
  if not bundled.isNil and
      loadLayoutOnce(layout, cast[GoldenLayoutResolvedConfig](bundled),
                     cstring"the bundled default layout"):
    cerror "layout: the saved layout could not be restored; " &
      "fell back to the bundled default"
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

  # Create nested buttons in header
  layout.on(cstring"stackCreated") do (ev: Event):
    let newElement = kdom.document.createElement("div")
    let hiddenDropdown = createLayoutDropdown(layout, ev)
    newElement.classList.add("layout-buttons-container")
    newElement.setAttribute("tabindex", "0")
    newElement.onclick = proc(e: Event) {.nimcall.} =
      let currentElement = cast[kdom.Element](e.toJs.currentTarget)
      let element = cast[kdom.Element](currentElement.children[0])

      if element.classList.contains("hidden"):
        element.classList.remove("hidden")
        currentElement.classList.add("active")
      else:
        element.classList.add("hidden")
        currentElement.classList.remove("active")

      cast[kdom.Element](e.target).focus()

    newElement.onblur = proc(e: Event) {.nimcall.} =
      let currentElement = cast[kdom.Element](e.toJs.currentTarget)
      e.toJs.target.children[0].classList.add("hidden")
      currentElement.classList.remove("active")

    let container = ev.toJs.target.element.childNodes[0].childNodes[1]
    let tabContainer = ev.toJs.target.element.childNodes[0].childNodes[0]

    while cast[kdom.Element](container).childNodes.len() > 0:
      container.removeChild(container.childNodes[0])

    newElement.appendChild(hiddenDropdown)
    tabContainer.appendChild(newElement)

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
      element.innerHTML = cstring(fmt"<div id={componentLabel} class=" & "\"component-container\"></div>")

    container.on(cstring"tab") do (tab: GoldenTab):
      data.ui.saveLayout = true
      #componentMapping -> all registered components in data
      #content -> enum {TERMINAL, TRACELOG etc..}

      if data.ui.openComponentIds[state.content].find(state.id) == -1:
        data.ui.openComponentIds[state.content].add(state.id)

      let similarComponents = data.ui.componentMapping[state.content]

      if similarComponents.len > 0:
        let openComponents = data.ui.openComponentIds[state.content]
        let lastComponentId = if openComponents.len > 0: openComponents[^1] else: 0
        let lastComponent = similarComponents[lastComponentId]

        lastComponent.layoutItem = cast[GoldenContentItem](container.tab.contentItem)

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
      if not ($state.label).startsWith("event:"):
        tab.titleElement.innerHTML = if labelTokens.len > 1:
            labelTokens[^2] & cstring"/" & labelTokens[^1]
          else:
            labelTokens[^1]
      else:
        tab.titleElement.innerHTML = if labelTokens.len > 1:
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

      discard windowSetTimeout((proc =
        if not data.ui.componentMapping[state.content].hasKey(state.id):
          discard data.makeComponent(state.content, state.id)
        if not data.ui.componentMapping[state.content][state.id].isNil:
          let component = data.ui.componentMapping[state.content][state.id]

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
      element.innerHTML = cstring(fmt"<div id={editorLabel} class=" & "\"component-container\"></div>")

    container.on(cstring"tab") do (tab: GoldenTab):
      # prepare layout to be saved on upcoming stateChanged event
      data.ui.saveLayout = true

      # add contentItem to component
      # all components - data.ui.componentMapping
      let similarComponents = data.ui.componentMapping[state.content]

      ## check if id of the component was added to the open components register
      # data.ui.openComponentIds all components that are open
      if data.ui.openComponentIds[state.content].find(state.id) == -1:
        data.ui.openComponentIds[state.content].add(state.id)

      ## map corresponding layout item to the last component that was added
      if similarComponents.len > 0:
        let openComponents = data.ui.openComponentIds[state.content]
        # ^1 - last element of an array
        let lastComponentId = if openComponents.len > 0: openComponents[^1] else: 0
        let lastComponent = similarComponents[lastComponentId]
        # container.tab.contentItem reference to golden layout item
        lastComponent.layoutItem = cast[GoldenContentItem](container.tab.contentItem)

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
      Content.Scratchpad,
      Content.Filesystem,
      Content.CommandPalette,
      Content.DeepReview,
      Content.VCS,
      Content.UnifiedDiff,
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

        if state.content == Content.DeepReview:
          deepreview.syncLegacyDeepReviewIntoVM(
            DeepReviewComponent(component))
          deepreview.tryMountIsoNimDeepReviewPanel(component.id)

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

        if state.content == Content.AgentActivity:
          agent_activity.syncLegacyAgentActivityIntoVM(
            AgentActivityComponent(component))
          agent_activity.tryMountIsoNimAgentActivityPanel(component.id)

        # AgentActivityDeepReview is now an IsoNim view -- its DOM
        # is mounted by
        # ``agent_activity_deepreview.tryMountIsoNimAgentActivityDeepReviewPanel``
        # against the ``agentActivityDeepReviewComponent-{id}``
        # container, and reactive effects keep it in sync.  No
        # direct-DOM redraw hook is needed here. The
        # legacy ``AgentActivityDeepReviewComponent`` remains as the
        # event-bus carrier (the ``IPC_DEEPREVIEW_NOTIFICATION``
        # handler keeps populating ``self.fileEntries`` /
        # ``self.recentNotifications``) and
        # ``syncLegacyAgentActivityDeepReviewIntoVM`` mirrors any
        # rows already accumulated when the panel becomes visible.
        # Mission goal #3 \u00a71.73.  The rich per-row affordances
        # (per-file coverage bar, per-notification colour pills,
        # the "Functions" summary card) remain a follow-up.
        if state.content == Content.AgentActivityDeepReview:
          agent_activity_deepreview.syncLegacyAgentActivityDeepReviewIntoVM(
            AgentActivityDeepReviewComponent(component))
          agent_activity_deepreview.tryMountIsoNimAgentActivityDeepReviewPanel()

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
      (content: Content.SearchResults, title: cstring"SEARCH RESULTS", label: cstring"searchResultsComponent-0"),
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
        let component = data.ui.componentMapping[panelDef.content][0]
        if not component.isNil and not component.layoutItem.isNil:
          cdebug "auto_hide: pinning GL panel '" & $panelDef.title & "' to bottom auto-hide"
          pinPanel(layout, component.layoutItem, AutoHideEdge.Bottom)
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
