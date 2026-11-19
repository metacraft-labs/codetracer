## dom_activity_presses.nim — a DOM story host's procedures for a press on, and
## a key in, the session activity timeline
## (`viewmodel/views/isonim_agent_harbor_session_activity_view`): what
## StoryBook registers when it mounts a timeline story
## (`storybook_components.mountAgentHarborSessionActivity`).
##
## The presses: the timeline's elements carry their operations
## (`session-activity.toggle` on a line that opens, `session-activity.copy`
## on a detail's Copy, `session-activity.jump-to-latest` on the unseen chip,
## `session-activity.retry` on Retry) and their target
## (`data-ah-target`), and hold no handler. The page's one pointer listener
## (`viewmodel/input/dom_pointer`) resolves a press on one through the pointer
## keymap -- a user's row first -- and, with no row, runs the procedure
## registered here for the operation the element carries, on its target.
##
## The keys: the timeline's list is the `sessionActivity` scope. A key
## pressed while it has the keyboard focus is named as the keymap names keys
## (`ArrowRight` is `Right`) and resolved by the story host's router in that
## scope; the operation it resolves to runs on the timeline
## (`runActivityOperation`). The base rows are `overlay_rows`'
## `pane:sessionActivity` table.
##
## The clipboard is the host's: Copy writes its target through the browser's
## asynchronous clipboard
## (https://w3c.github.io/clipboard-apis/#dom-clipboard-writetext), and the
## story host records the last text it got on the page's body
## (`data-ah-copied`), where a play check reads it: a headless browser may
## refuse the clipboard itself.
##
## Refuses to own: what an operation does (`agent_harbor_activity_words`) and
## which operation a press or key runs (the router).

when not defined(js):
  {.error: "stories/dom_activity_presses is a DOM front-end's (JS).".}

import std/jsffi

import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ../viewmodel/views/agent_harbor_activity_words
import ../viewmodel/input/[dom_pointer, dom_pane_presses]
import ../viewmodel/keymap/[context_keys, editing_keymap, keymap_router, scope_path]
import ../../common/key_names

proc writeClipboard(text: cstring) {.importjs: """
  (function (t) {
    document.body.setAttribute('data-ah-copied', t);
    try {
      if (navigator.clipboard && navigator.clipboard.writeText)
        navigator.clipboard.writeText(t).catch(function () {});
    } catch (e) {}
  })(#)""".}

proc copyToClipboard*(text: string) =
  ## The story host's clipboard: the browser's, and the record a play check
  ## reads.
  writeClipboard(cstring(text))

proc registerActivityPresses*(shown: proc(): SessionTimelineVM) =
  ## Register a procedure for every press operation of the timeline, acting
  ## on the timeline `shown` answers when the press comes (nil: none is on the
  ## page, and the press is inert), on the target the pressed element
  ## carries. The last registration wins.
  for operation in ActivityPressOperations:
    closureScope:
      let op = operation
      registerElementOperation(op, proc(p: ElementPress): bool =
        let vm = shown()
        if vm.isNil: return false
        let target = readerOf(p.element)(PressTargetAttribute)
        vm.runActivityPress(op, target, copyToClipboard))

proc keyNameOf*(key: string; ctrl, alt, meta: bool): string =
  ## The keymap's name of a DOM `KeyboardEvent.key`
  ## (https://www.w3.org/TR/uievents-key/): the arrows without their
  ## `Arrow`, every other key as the event names it, with the modifiers
  ## (`key_names.chordName`). A printable character already carries its
  ## Shift (`+` is Shift+`=` on a US keyboard, and its name is `+`).
  let base = if key.len > 5 and key[0 .. 4] == "Arrow": key[5 .. ^1] else: key
  var mods: KeyModifiers
  if ctrl: mods.incl kmodCtrl
  if alt: mods.incl kmodAlt
  if meta: mods.incl kmodMeta
  chordName(mods, base)

proc listenKeys(list: JsObject; onKey: proc(key: cstring; ctrl, alt, meta: bool): bool) {.importjs: """
  (function (list, onKey) {
    if (!list || list.__ahActivityKeys) return;
    list.__ahActivityKeys = true;
    list.addEventListener('keydown', function (ev) {
      if (onKey(ev.key, ev.ctrlKey, ev.altKey, ev.metaKey)) {
        ev.preventDefault();
        ev.stopPropagation();
      }
    });
  })(#, #)""".}

let ActivityScopePath = @[element(ekWindow, "window"), pane(SessionActivityScope)]
  ## Where the timeline's keys resolve.

proc routeActivityKeys*(root: JsObject; shown: proc(): SessionTimelineVM) =
  ## Route the keys pressed in the timeline under `root` (its panel; the
  ## listener sits on the panel, so it outlives the list a redraw replaces)
  ## through the base keymap's rows in the `sessionActivity` scope.
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
                                                   platform: hostPlatform(),
                                                   keyProtocol: kpNative))
  listenKeys(root, proc(key: cstring; ctrl, alt, meta: bool): bool =
    let vm = shown()
    if vm.isNil: return false
    let name = keyNameOf($key, ctrl, alt, meta)
    let res = router.route(SessionFacts(), ActivityScopePath, nmNormal, name, 0)
    res.kind == erOperation and vm.runActivityOperation(res.operation))

proc routeActivityPresses*(shown: proc(): SessionTimelineVM) =
  ## `registerActivityPresses`, and the base keymap's pointer rows for a page
  ## with no keymap of its own (`installBaseElementRouting`).
  registerActivityPresses(shown)
  installBaseElementRouting()
