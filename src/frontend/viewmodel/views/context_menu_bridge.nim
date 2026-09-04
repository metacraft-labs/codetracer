when defined(js):
  import std/[dom, strformat, strutils]
  import kdom
  import ../../types
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

  proc hideContextMenu() =
    let container = kdom.document.getElementById(cstring"context-menu-container")
    if not container.isNil:
      container.style.display = cstring"none"

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
