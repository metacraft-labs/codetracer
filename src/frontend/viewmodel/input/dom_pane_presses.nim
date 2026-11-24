## dom_pane_presses.nim — a DOM front-end's procedures for a press on an element
## of one of the session's panes: `pane_presses`' procedures, registered with
## `dom_pointer` and fed the attributes of the element its hit test found, and
## each pane's `context-menu.open`: the element's menu, from the items its view
## projects (`rowMenuItems`, `variableRowMenuItems`, `fileTreeMenuItems`, …),
## shown at the press with the shared right-click menu. The views open no menu
## of their own.
##
## The desktop's panes with a ViewModel of their own register beside it: the
## event log's `event-log.show-content` (`ui/event_log`), the VCS pane
## (`ui/vcs`), Verification (`ui/verification`), Constraints
## (`ui/constraints`), the Video Player (`ui/video_player`) and Pixel History
## (`ui/pixel_history`).

when not defined(js):
  {.error: "viewmodel/input/dom_pane_presses is a DOM front-end's (JS).".}

import std/[jsffi, json, strutils]
from kdom import nil

import ./dom_pointer
import ./pane_presses
import ../session_vm
import ../viewmodels/[calltrace_vm, low_level_code_vm, request_panel_vm,
                      state_vm, filesystem_vm]
from ../store/types import CallLine
import isonim/core/signals
from ../views/context_menu_bridge import showContextMenu
from ../../context_menu_item import ContextMenuItem
import ../views/isonim_calltrace_view
from ../views/isonim_state_view import variableRowMenuItems
from ../views/isonim_filesystem_view import fileTreeMenuItems
from ../views/isonim_low_level_code_view import nil
from ../views/isonim_request_panel_view import nil
import ../keymap/[keymap_router, base_keymaps, context_keys, scope_path,
                  editing_keymap]
import ../viewmodels/product_mode
from ../../../common/key_names import kpNative

proc closestWith(element: JsObject; selector: cstring): JsObject {.importjs:
  "((e, s) => (e && e.closest) ? e.closest(s) : null)(#, #)".}

when defined(ctWasmPanes):
  proc wasmPaneHosts(element: JsObject): bool {.importjs:
    "((e) => !!globalThis.ctwPanels && !!globalThis.ctwPanels.owns && globalThis.ctwPanels.owns(e))(#)".}
    ## Whether a WebAssembly core draws the pane `element` is in — each tab's
    ## own core (`web_core/web_core_panels.js`).
  proc wasmPanePress(operation: cstring; element: JsObject): bool {.importjs:
    "globalThis.ctwPanels.press(#, #)".}
  proc wasmPaneMenu(pane: cstring; element: JsObject): JsObject {.importjs:
    "globalThis.ctwPanels.menu(#, #)".}
    ## The core's menu of `element`: `[{label, hint, enabled, choose()}]`.

  proc wasmMenuItem(entry: JsObject): ContextMenuItem =
    ## One entry of the core's menu, choosing it in the core; what the core
    ## leaves to the page (a value for the Scratchpad, which the shell
    ## draws) is done here.
    ContextMenuItem(
      name: entry["label"].to(cstring),
      hint: entry["hint"].to(cstring),
      handler: proc(ev: kdom.Event) =
        let rest = $entry.choose().to(cstring)
        if rest.len > 0:
          let j = try: parseJson(rest) except CatchableError: newJObject()
          if j.hasKey("scratchpad") and
              not isonim_calltrace_view.addToScratchpadHook.isNil:
            isonim_calltrace_view.addToScratchpadHook(
              j["scratchpad"]{"name"}.getStr, j["scratchpad"]{"text"}.getStr))

  proc wasmMenuItems(pane: string; element: JsObject): seq[ContextMenuItem] =
    ## The right-click menu of an element of a pane the WebAssembly core
    ## draws: its entries and their actions are the core's, on the core's
    ## ViewModels.
    let entries = wasmPaneMenu(cstring(pane), element)
    if entries.isNil or entries.isUndefined: return
    for i in 0 ..< entries["length"].to(int):
      let entry = entries[i]
      if entry["enabled"].to(bool):
        result.add wasmMenuItem(entry)

proc readerOf*(element: JsObject): AttributeReader =
  ## `name` on `element`, or on its nearest ancestor that carries it (a call's
  ## text reads its row's `data-call-index`).
  result = proc(name: string): string =
    let carrier = closestWith(element, cstring("[" & name & "]"))
    if carrier.isNil or carrier.isUndefined: "" else: attributeOf(carrier, name)

proc numberOf(attr: AttributeReader; name: string): int =
  try: parseInt(attr(name)) except ValueError: -1

proc showMenuAt*(press: ElementPress; items: seq[ContextMenuItem]): bool =
  ## Shows `items` as the shared right-click menu at the press; false for an
  ## empty menu (the press is then left alone).
  if items.len == 0:
    return false
  showContextMenu(items, press.event[cstring"clientX"].to(int),
                  press.event[cstring"clientY"].to(int))
  true

proc callLineAt(vm: CalltraceVM; index: int): CallLine =
  for line in vm.store.calltrace.lines.val:
    if line.index == int64(index):
      return line
  CallLine(index: -1)

proc paneMenuItems(vms: PaneVMs; pane: string;
                   attr: AttributeReader): seq[ContextMenuItem] =
  ## The menu of the element `attr` describes in `pane` (K19, K22, K23,
  ## K28, K59, K62), selecting the row first where the pane's own menu did.
  case pane
  of "calltrace":
    let vm = vms.calltrace
    if vm.isNil: return
    let argName = attr("data-arg-name")
    if argName.len > 0:
      return callArgContextItems(argName, attr("data-arg-text"))
    let line = vm.callLineAt(numberOf(attr, "data-call-index"))
    if line.index >= 0:
      return calltraceRowContextItems(vm, proc(): CallLine = line)
  of "state":
    let path = attr("data-variable-path")
    if not vms.state.isNil and path.len > 0:
      return variableRowMenuItems(vms.state, path)
  of "fileTree":
    let path = attr("data-ct-path")
    if not vms.fileTree.isNil and path.len > 0:
      return fileTreeMenuItems(vms.fileTree, path)
  of "lowLevelCode":
    let index = numberOf(attr, "data-low-level-row")
    if not vms.lowLevelCode.isNil and index >= 0:
      vms.lowLevelCode.selectInstruction(index)
      return isonim_low_level_code_view.rowMenuItems(vms.lowLevelCode, index)
  of "requests":
    let index = numberOf(attr, "data-request-index")
    if not vms.requests.isNil and index >= 0:
      vms.requests.selectRequest(index)
      return isonim_request_panel_view.rowMenuItems(vms.requests, index)
  else: discard

const MenuPanes* = ["calltrace", "state", "fileTree", "lowLevelCode",
                    "requests"]
  ## The panes whose element menus this module opens (`context-menu.open`).

proc installPanePresses*(vms: proc(): PaneVMs) =
  ## Register `pane_presses`' procedures and the panes' menus over the
  ## ViewModels `vms` answers: on the desktop the tab on screen's, in a VS
  ## Code panel the mirror's, in an embedder its own. A later call replaces
  ## them.
  for operation in SessionPressOperations:
    closureScope:
      let op = operation
      registerElementOperation(op, proc(p: ElementPress): bool =
        when defined(ctWasmPanes):
          # A press on a pane the WebAssembly core draws is the core's
          # (`web_core/web_core_host.js`'s `press`), on its ViewModels.
          if wasmPaneHosts(p.element):
            return wasmPanePress(cstring(op), p.element)
        performPanePress(vms(), op, readerOf(p.element)))
  for pane in MenuPanes:
    closureScope:
      let paneKind = pane
      registerPaneOperation("context-menu.open", paneKind,
        proc(p: ElementPress): bool =
          when defined(ctWasmPanes):
            if wasmPaneHosts(p.element):
              return p.showMenuAt(wasmMenuItems(paneKind, p.element))
          p.showMenuAt(paneMenuItems(vms(), paneKind, readerOf(p.element))))

proc installSessionPanePresses*(session: proc(): SessionViewModel) =
  ## `installPanePresses` over `session`'s ViewModels.
  installPanePresses(proc(): PaneVMs =
    let s = if session.isNil: SessionViewModel(nil) else: session()
    paneVMsOf(s))

proc installBasePointerRouting(router: KeymapRouter) =
  installDomPointerRouting(proc(path: ScopePath; gesture: string): EditingResolution =
    router.routePointer(SessionFacts(product: pmDebug, replayLoaded: true),
                        path, nmNormal, gesture))

proc baseRouter(): KeymapRouter =
  initKeymapRouter(bkCua, KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                                      keyProtocol: kpNative))

proc installPanePointerRoutingWith*(perform: proc(operation: string;
                                                   attr: AttributeReader): bool) =
  ## As `installPanePointerRouting`, for a host that holds the panes'
  ## ViewModels one by one rather than as a session (an embedder mounting a
  ## Call Trace and an Event Log over its own ViewModels): `perform` is its
  ## call into `pane_presses` (`pressCalltrace(vm, operation, attr)` …).
  for operation in SessionPressOperations:
    closureScope:
      let op = operation
      registerElementOperation(op, proc(p: ElementPress): bool =
        perform(op, readerOf(p.element)))
  installBasePointerRouting(baseRouter())

proc installBaseElementRouting*() =
  ## A page with no keymap of its own whose presses are buttons carrying
  ## their operations (StoryBook's story chrome, `storybook_components`):
  ## every press through the base keymap's pointer rows, performed by the
  ## procedures the page registered (`registerElementOperation`). A page
  ## whose presses are routed already keeps its router.
  if not domPointerRoutingInstalled():
    installBasePointerRouting(baseRouter())

proc installPanePointerRoutingFor*(vms: proc(): PaneVMs) =
  ## A DOM host that mounts some of the panes over ViewModels of its own (an
  ## embedder such as BlockTracer): every press on their elements, and the
  ## right press that opens an element's menu, through the base keymap's
  ## pointer rows, performed over `vms`. The host marks each pane's mount
  ## root with `data-scope-kind="pane"` and the pane's kind as
  ## `data-scope-id` (`calltrace`, `state`, `eventLog`).
  installPanePresses(vms)
  installBasePointerRouting(baseRouter())

proc installPanePointerRouting*(session: proc(): SessionViewModel) =
  ## A DOM host that mounts the session's panes without a keymap of its own
  ## (a VS Code panel's webview, a page embedding the views): every press on
  ## their elements through the base keymap's pointer rows (`pointer_rows`),
  ## performed over `session`'s ViewModels. The host's pane roots carry
  ## `data-scope-kind="pane"` and the pane's kind as `data-scope-id`.
  installSessionPanePresses(session)
  installBasePointerRouting(baseRouter())
