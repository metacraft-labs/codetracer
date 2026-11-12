## dom_pane_presses.nim — a DOM front-end's procedures for a press on an element
## of one of the session's panes: `pane_presses`' procedures, registered with
## `dom_pointer` and fed the attributes of the element its hit test found.
##
## The desktop's panes with a ViewModel of their own register beside it: the
## event log's `event-log.show-content` (`ui/event_log`), the VCS pane
## (`ui/vcs`), Verification (`ui/verification`), Constraints
## (`ui/constraints`), the Video Player (`ui/video_player`) and Pixel History
## (`ui/pixel_history`).

when not defined(js):
  {.error: "viewmodel/input/dom_pane_presses is a DOM front-end's (JS).".}

import std/jsffi

import ./dom_pointer
import ./pane_presses
import ../session_vm
import ../keymap/[keymap_router, base_keymaps, context_keys, scope_path,
                  editing_keymap]
import ../viewmodels/product_mode
from ../../../common/key_names import kpNative

proc closestWith(element: JsObject; selector: cstring): JsObject {.importjs:
  "((e, s) => (e && e.closest) ? e.closest(s) : null)(#, #)".}

proc readerOf*(element: JsObject): AttributeReader =
  ## `name` on `element`, or on its nearest ancestor that carries it (a call's
  ## text reads its row's `data-call-index`).
  result = proc(name: string): string =
    let carrier = closestWith(element, cstring("[" & name & "]"))
    if carrier.isNil or carrier.isUndefined: "" else: attributeOf(carrier, name)

proc installSessionPanePresses*(session: proc(): SessionViewModel) =
  ## Register `pane_presses`' procedures over the ViewModels `session`
  ## answers: on the desktop the tab on screen (the one its panes render and
  ## its keys act on), in a VS Code panel the mirror it renders. A later call
  ## replaces them.
  for operation in SessionPressOperations:
    closureScope:
      let op = operation
      registerElementOperation(op, proc(p: ElementPress): bool =
        let s = if session.isNil: nil else: session()
        performSessionPress(s, op, readerOf(p.element)))

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

proc installPanePointerRouting*(session: proc(): SessionViewModel) =
  ## A DOM host that mounts the session's panes without a keymap of its own
  ## (a VS Code panel's webview, a page embedding the views): every press on
  ## their elements through the base keymap's pointer rows (`pointer_rows`),
  ## performed over `session`'s ViewModels. The host's pane roots carry
  ## `data-scope-kind="pane"` and the pane's kind as `data-scope-id`.
  installSessionPanePresses(session)
  installBasePointerRouting(baseRouter())
