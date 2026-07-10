when defined(js):
  import std/[dom, strformat, strutils]
  import kdom
  import ../../types

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
      item.id = cstring(fmt"menu-item-{i}")
      item.innerHTML = option.name
      item.onclick = proc(ev: kdom.Event) {.nimcall.} =
        let targetId = $ev.currentTargetId()
        if targetId.startsWith("menu-item-"):
          let itemIndex = parseInt(targetId["menu-item-".len..^1])
          if itemIndex >= 0 and itemIndex < contextMenuHandlers.len:
            contextMenuHandlers[itemIndex](ev)
        hideContextMenu()

      if option.hint.len > 0:
        let hint = kdom.document.createElement(cstring"div")
        hint.classList.add(cstring"context-menu-hint")
        hint.id = cstring(fmt"menu-hint-{i}")
        hint.innerHTML = option.hint
        discard cast[dom.Element](item).append(cast[dom.Element](hint))

      discard cast[dom.Element](itemContainer).append(cast[dom.Element](item))
      discard cast[dom.Element](container).append(cast[dom.Element](itemContainer))

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
