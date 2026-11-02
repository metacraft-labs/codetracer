when defined(js):
  import std/[dom, strformat, strutils]
  import kdom
  import ../../context_menu_item
  import context_menu_hint
  from ../../lib/electron_presence import inElectron

  var contextMenuHandlers: seq[proc(ev: kdom.Event) {.closure.}]

  proc windowInnerWidth(): int
      {.importjs: "(window.innerWidth || document.documentElement.clientWidth || 0)".}
  proc windowInnerHeight(): int
      {.importjs: "(window.innerHeight || document.documentElement.clientHeight || 0)".}
  proc eventKeyCode(ev: kdom.Event): int {.importjs: "(#.keyCode || 0)".}
  proc currentTargetId(ev: kdom.Event): cstring
      {.importjs: "(function(e){ return (e.currentTarget && e.currentTarget.id) || ''; })(#)".}

  proc contextMenuIsOpen*(): bool {.importjs: """
    (function(){
      const c = document.getElementById('context-menu-container');
      return !!c && getComputedStyle(c).display !== 'none';
    })()""".}
    ## Whether the right-click menu is showing. The desktop's key router asks
    ## before every key, so that while it shows the menu's own keys
    ## (`Escape` → `context-menu.close`) are consulted first, as on the
    ## terminal and GPUI (CUA-Keymap.md §3.8).

  proc hideContextMenu*() =
    ## Close the right-click menu, whichever `showContextMenu` opened it (this
    ## one or its twin in `renderer.nim`): both draw into the one
    ## `#context-menu-container`.
    let container = kdom.document.getElementById(cstring"context-menu-container")
    if not container.isNil:
      container.style.display = cstring"none"

  proc moveContextMenuHighlight(step: int; fromEnd: bool) {.importjs: """
    (function(step, fromEnd){
      const c = document.getElementById('context-menu-container');
      if (!c) return;
      const rows = Array.from(c.querySelectorAll('.context-menu-item'));
      const n = rows.length;
      if (n === 0) return;
      const ACTIVE = 'ct-menu-item--active';
      let i = fromEnd ? -1 : rows.findIndex(r => r.classList.contains(ACTIVE));
      if (i < 0) i = step > 0 ? -1 : n;
      for (let k = 0; k < n; k++) {
        i = (((i + step) % n) + n) % n;
        if (!rows[i].classList.contains('ct-menu-item--disabled')) {
          rows.forEach(r => r.classList.remove(ACTIVE));
          rows[i].classList.add(ACTIVE);
          if (rows[i].scrollIntoView) rows[i].scrollIntoView({block: 'nearest'});
          return;
        }
      }
    })(#, #)""".}
    ## Move the keyboard highlight (`.ct-menu-item--active`, the design
    ## system's keyboard-navigation row) `step` ENABLED rows on, wrapping, as
    ## the shared `ContextMenuState.move` does for the terminal and GPUI; with
    ## `fromEnd` it starts outside the list, so `step` 1 is the first enabled
    ## row and -1 the last. Disabled rows are skipped: they cannot be chosen.

  proc acceptContextMenuHighlight() {.importjs: """
    (function(){
      const c = document.getElementById('context-menu-container');
      const row = c && c.querySelector(
        '.context-menu-item.ct-menu-item--active:not(.ct-menu-item--disabled)');
      if (row) row.click();
    })()""".}
    ## Choose the highlighted row through its own `onclick` — the one path a
    ## pointer takes, which runs the entry's handler and closes the menu.
    ## With no row highlighted nothing is chosen, as on the terminal.

  proc contextMenuOperation*(operation: string): bool =
    ## Perform a `ContextMenuTable` operation (CUA-Keymap.md §3.8) on the
    ## right-click menu: the desktop's counterpart of the terminal's and
    ## GPUI's `context-menu.*` dispatch. Answers whether `operation` was one;
    ## `context-menu.open` (a global operation) is not.
    case operation
    of "context-menu.focus-next": moveContextMenuHighlight(1, false)
    of "context-menu.focus-previous": moveContextMenuHighlight(-1, false)
    of "context-menu.focus-first": moveContextMenuHighlight(1, true)
    of "context-menu.focus-last": moveContextMenuHighlight(-1, true)
    of "context-menu.accept": acceptContextMenuHighlight()
    of "context-menu.close": hideContextMenu()
    of "context-menu.enter-submenu", "context-menu.leave-submenu":
      discard  # this menu has no submenus; the key is still the menu's
    else: return false
    true

  proc showContextMenu*(options: seq[ContextMenuItem], x: int, yPos: int): void =
    let container = kdom.document.getElementById(cstring"context-menu-container")
    if container.isNil:
      return

    container.style.display = cstring"flex"
    container.innerHTML = cstring""
    contextMenuHandlers.setLen(options.len)

    for i, option in options:
      contextMenuHandlers[i] = option.handler

      let itemContainer = kdom.document.createElement(cstring"div")
      itemContainer.classList.add(cstring"context-menu-item-container")

      let item = kdom.document.createElement(cstring"div")
      item.classList.add(cstring"context-menu-item")
      item.classList.add(cstring"ct-menu-item")
      item.id = cstring(fmt"menu-item-{i}")
      let labelEl = kdom.document.createElement(cstring"span")
      labelEl.classList.add(cstring"ct-menu-item-label")
      # `textContent`, not `innerHTML`: a menu label is a label.  Most are
      # literals, but not all — `isonim_state_view`'s "Switch process: <role>"
      # carries a `role`/`recordingId` copied verbatim out of a session
      # manifest that ships with the recording, and `panel_transfer`'s "Send
      # to: <title>" carries a window title.  None of them is markup.
      labelEl.textContent = option.name
      discard cast[dom.Element](item).append(cast[dom.Element](labelEl))
      # Twin of the same block in `renderer.showContextMenu`, which carries the
      # reasoning.  The two implementations of this menu have to stay
      # indistinguishable, or the surface a user right-clicks decides whether a
      # disabled row is clickable.
      if option.disabled:
        item.classList.add(cstring"ct-menu-item--disabled")
        item.setAttribute(cstring"aria-disabled", cstring"true")
      else:
        item.onclick = proc(ev: kdom.Event) {.nimcall.} =
          let targetId = $ev.currentTargetId()
          if targetId.startsWith("menu-item-"):
            let itemIndex = parseInt(targetId["menu-item-".len..^1])
            if itemIndex >= 0 and itemIndex < contextMenuHandlers.len:
              contextMenuHandlers[itemIndex](ev)
          hideContextMenu()

      let sublabel =
        if option.disabled and option.disabledReason.len > 0: option.disabledReason
        else: option.hint
      if sublabel.len > 0:
        let hint = kdom.document.createElement(cstring"span")
        hint.classList.add(cstring"ct-menu-item-sublabel")
        hint.id = cstring(fmt"menu-hint-{i}")
        hint.textContent = sublabel
        discard cast[dom.Element](item).append(cast[dom.Element](hint))

      discard cast[dom.Element](itemContainer).append(cast[dom.Element](item))
      discard cast[dom.Element](container).append(cast[dom.Element](itemContainer))

    # The one NON-INTERACTIVE row.  The twin of this block is
    # `renderer.appendContextMenuBrowserHint`, which carries the reasoning; the
    # two implementations of this menu have to stay indistinguishable, so the
    # row is added in both or the surface a user right-clicks decides whether
    # they are told about the gesture.
    let hintText = contextMenuBrowserHint(inElectron)
    if hintText.len > 0:
      let hintRow = kdom.document.createElement(cstring"div")
      hintRow.classList.add(cstring ContextMenuHintClass)
      hintRow.id = cstring ContextMenuHintId
      hintRow.setAttribute(cstring"role", cstring"presentation")
      hintRow.setAttribute(cstring"aria-hidden", cstring"true")
      hintRow.textContent = cstring hintText
      discard cast[dom.Element](container).append(cast[dom.Element](hintRow))

    let contextWidth = cast[dom.Element](container).clientWidth
    let contextHeight = cast[dom.Element](container).clientHeight
    let clientWidth = windowInnerWidth()
    let clientHeight = windowInnerHeight()
    # Anchor the menu corner closest to the cursor:
    # default is top-left at cursor; flip horizontally if too far right,
    # flip vertically if too far down.
    let tooFarRight = x + contextWidth > clientWidth
    let tooFarDown  = yPos + contextHeight > clientHeight
    let leftPos = max(0, if tooFarRight: x - contextWidth else: x)
    let topPos  = max(0, if tooFarDown:  yPos - contextHeight else: yPos)

    container.style.top = cstring(fmt"{topPos}px")
    container.style.left = cstring(fmt"{leftPos}px")

    kdom.document.addEventListener(cstring"click", proc(ev: kdom.Event) =
      hideContextMenu())
    kdom.document.addEventListener(cstring"keydown", proc(ev: kdom.Event) =
      if ev.eventKeyCode() == 27:
        hideContextMenu())
