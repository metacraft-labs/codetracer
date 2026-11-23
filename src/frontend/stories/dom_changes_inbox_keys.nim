## dom_changes_inbox_keys.nim — a DOM story host's keys for the Agent Harbor
## Changes panel and Inbox (`viewmodel/views/isonim_agent_harbor_changes_view`,
## `isonim_agent_harbor_inbox_view`): what StoryBook installs for their
## stories (`storybook_components.mountAgentHarborChanges`, `…Inbox`,
## `…InboxItem`).
##
## Input-Routing-And-Keymaps.md §4: a key pressed while the focus is in the
## panel (`data-ct-pane="changes"` or `"inbox"`) is named by the desktop's one
## decoder (`key_event_names.canonicalKeyOfDom`) and resolved by the base
## keymap's router in the panel's scope (`ChangesPanelScope`,
## `InboxPanelScope`; the rows are `overlay_rows`'); the operation it resolves
## to runs on the viewmodel on the page (`runChangesOperation`,
## `runInboxOperation`), as in the terminal and GPUI story hosts. Scrolling
## is the browser's own: the page keys and the arrows are left to it. A key
## typed in a text field of the panel (an answer, a password) is the
## field's (`withNativeTextField`), never a panel operation. After a key,
## what the keyboard is on is kept in view (`keepKeyboardItemInView`):
## the keyboard's card or file, the item on screen, as the terminal's views
## keep it (`ah_tui_changes_inbox_parts.drawScrolled`). A story's first frame
## shows it too (`keepInViewWhenLaidOut`, called by the StoryBook mounts),
## as the terminal's and GPUI's first frames do (GPUI's panels scroll the
## same way, `gpui/agent_harbor/ah_changes_inbox_parts.scrollWindow`), so
## the web's first frame and GPUI's agree
## (`test_ctf_p1b_gpui_capture_matches_web_layout`).
##
## Presses on the elements that carry their operation (the dropdowns'
## `dropdown.toggle` / `dropdown.choose`, a single choice's
## `inbox.choose-option`) go through the page's one pointer listener and the
## base keymap's pointer rows (`installBaseElementRouting`), which run the
## procedure bound to the element pressed (`element_operations`).
##
## Refuses to own: what an operation does (`agent_harbor_changes_inbox_words`)
## and which operation a key runs (the router).

when not defined(js):
  {.error: "stories/dom_changes_inbox_keys is a DOM front-end's (JS).".}

import std/jsffi

import nim_agents_isonim_viewmodels/agent_harbor/[changes_vm, inbox_vm, inbox_item_vm]
import ../viewmodel/views/agent_harbor_changes_inbox_words
import ../viewmodel/keymap/[base_keymaps, context_keys, keymap_router, scope_path,
                            editing_keymap]
import ../../common/key_event_names
from ../viewmodel/input/dom_pane_presses import installBaseElementRouting

var shownChanges: proc(): ChangesVM
var shownInbox: proc(): InboxVM
var shownItem: proc(): InboxItemVM
  ## The viewmodels on the page when a key comes (nil: none).
var keysInstalled = false

proc fieldFactsOf(target: JsObject): FocusedFieldFacts =
  ## What `withNativeTextField` needs to know about the element the key went
  ## to (the desktop reads the same off `document.activeElement`,
  ## `ui/key_router.focusedFieldFactsOf`): an answer's text field, a
  ## password, a search box take their own keys, so `]`, `[` and `1`-`4`
  ## typed there are text, not Next, Previous or a priority (Agent Harbor
  ## binds them only while no text field has the focus).
  if target.isNil or target.isUndefined: return FocusedFieldFacts()
  proc str(v: JsObject): string =
    if v.isNil or v.isUndefined: "" else: $v.to(cstring)
  proc flag(v: JsObject): bool =
    not v.isNil and not v.isUndefined and v.to(bool)
  FocusedFieldFacts(tagName: str(target[cstring"tagName"]),
                    inputType: str(target[cstring"type"]),
                    contentEditable: flag(target[cstring"isContentEditable"]),
                    id: str(target[cstring"id"]),
                    readOnly: flag(target[cstring"readOnly"]),
                    disabled: flag(target[cstring"disabled"]))

proc paneOf(target: JsObject): cstring {.importjs:
  "(function (t) { var p = t && typeof t.closest === 'function' ? t.closest('[data-ct-pane]') : null; return p ? p.getAttribute('data-ct-pane') : ''; })(#)".}

const KeyboardItemSelector = ".ah-card-focused, .ah-code-file-focused, .ah-inbox-row-current"
  ## What the keyboard is on in the Changes panel and the Inbox
  ## (`isonim_agent_harbor_changes_view`, `isonim_agent_harbor_inbox_view`).

proc keepInView(root: JsObject; selector: cstring) {.importjs: """
(function (root, sel) {
  // Each marked element's nearest scrolling ancestor moves the least that
  // shows the element's top (an open file's diff may be taller than the
  // region); the item on screen, out of view, is brought to the top, so the
  // page under the rows shows with it (the terminal's `keepAtTop`). The
  // window itself is never scrolled.
  var els = (root || document).querySelectorAll(sel);
  for (var i = 0; i < els.length; i++) {
    var el = els[i], p = el.parentElement;
    while (p && !(p.scrollHeight > p.clientHeight &&
                  /(auto|scroll)/.test(getComputedStyle(p).overflowY))) p = p.parentElement;
    if (!p) continue;
    var er = el.getBoundingClientRect(), pr = p.getBoundingClientRect();
    var out = er.top < pr.top || er.bottom > pr.bottom;
    if (out && el.classList.contains('ah-inbox-row-current')) p.scrollTop += er.top - pr.top;
    else if (er.top < pr.top) p.scrollTop -= pr.top - er.top;
    else if (er.bottom > pr.bottom) p.scrollTop += Math.min(er.bottom - pr.bottom, er.top - pr.top);
  }
})(#, #)""".}

proc keepKeyboardItemInView*(root: JsObject = nil) =
  ## Scrolls each Changes panel's or Inbox's region under `root` (the
  ## document for nil) the least that shows what the keyboard is on.
  keepInView(root, cstring(KeyboardItemSelector))

proc keepWhenLaidOut(root: JsObject; selector: cstring; keep: proc(root: JsObject)) {.importjs: """
(function (root, sel, keep) {
  // Polls (every 50 ms, up to 3 s) until what the keyboard is on sits in a
  // scrolling region the browser has laid out -- its golden-layout frame is
  // sized after the mount, so the region may not overflow yet -- then keeps
  // it in view once. Nothing to keep, or a region that never overflows,
  // needs no scroll.
  var tries = 60;
  function laidOut() {
    var els = (root || document).querySelectorAll(sel);
    if (els.length === 0) return false;
    for (var i = 0; i < els.length; i++) {
      var p = els[i].parentElement;
      while (p && !(p.scrollHeight > p.clientHeight &&
                    /(auto|scroll)/.test(getComputedStyle(p).overflowY))) p = p.parentElement;
      if (p && p.clientHeight > 0) return true;
    }
    return false;
  }
  (function step() {
    if (laidOut()) keep(root);
    else if (--tries > 0) setTimeout(step, 50);
  })();
})(#, #, #)""".}

proc keepInViewWhenLaidOut*(root: JsObject) =
  ## Once the panel under `root` is laid out (its region overflowing, so the
  ## rows' heights are their drawn ones), scrolls each of its regions the
  ## least that shows what the keyboard is on: a story's first frame.
  keepWhenLaidOut(root, cstring(KeyboardItemSelector), keepKeyboardItemInView)

proc onPanelKey(ev: JsObject) =
  ## A key while the focus is in the Changes panel or the Inbox: resolved in
  ## its scope by the base keymap; one of its operations runs and the event
  ## stops there.
  let pane = $paneOf(ev.target)
  if pane != ChangesPanelScope and pane != InboxPanelScope: return
  let name = canonicalKeyOfDom($ev.key.to(cstring), $ev.code.to(cstring),
                               ev.ctrlKey.to(bool), ev.shiftKey.to(bool),
                               ev.altKey.to(bool), ev.metaKey.to(bool))
  if name.len == 0: return
  var router = initKeymapRouter(bkCua, KeyDelivery(frontEnd: feWeb,
    platform: hostPlatform(), keyProtocol: kpNative))
  let path = withNativeTextField(@[element(ekWindow, "window"), pane(pane)],
                                 fieldFactsOf(ev.target))
  let res = router.route(SessionFacts(), path, nmNormal, name, 0)
  if res.kind != erOperation or res.operation in ScrollOperations: return
  var ran = false
  if pane == ChangesPanelScope:
    let vm = if shownChanges.isNil: nil else: shownChanges()
    ran = not vm.isNil and vm.runChangesOperation(res.operation)
  else:
    let vm = if shownInbox.isNil: nil else: shownInbox()
    let page = if not vm.isNil: vm.page
               elif shownItem.isNil: nil else: shownItem()
    ran = runInboxOperation(vm, page, res.operation)
  if ran:
    discard ev.preventDefault()
    discard ev.stopPropagation()
    keepKeyboardItemInView()

proc installKeys() =
  ## The panels' key listener, once per window, and the routing of the
  ## presses their elements carry (`installBaseElementRouting` keeps a
  ## router the page already has).
  installBaseElementRouting()
  if not keysInstalled:
    keysInstalled = true
    {.emit: ["window.addEventListener('keydown', ", onPanelKey, ", true);"].}

proc routeChangesKeys*(shown: proc(): ChangesVM) =
  ## The Changes panel's keys, acting on the panel `shown` answers when a key
  ## comes; the last registration wins.
  shownChanges = shown
  installKeys()

proc routeInboxKeys*(inbox: proc(): InboxVM; item: proc(): InboxItemVM) =
  ## The Inbox's keys, acting on the Inbox panel (or the item's page standing
  ## alone) the procedures answer when a key comes.
  shownInbox = inbox
  shownItem = item
  installKeys()
