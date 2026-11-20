## zgui/app/zgui_top_bar.nim — the window's top bar and its menus.
##
## The menu is the product's (`product_menu.nativeFrontEndMenu`), held by the
## shared `MenuVM`; this module draws it. A menu that opens is drawn in zgui's
## popover overlay root (`overlayRoot(.., olPopover)`), above the panes and
## outside their clipping, which is what a portalled menu is for. The debugger
## controls beside the menus run through the host's callback, the same door a
## key and a menu item go through.

import isonim_zgui/renderer

import viewmodels/menu_vm

const
  ZguiTopBarCss* = """
.ct-topbar { display: flex; flex-direction: row; flex-shrink: 0; height: 28px;
  align-items: center; gap: 2px; padding: 0 6px; background-color: #1f1f1f;
  border-bottom: 1px solid #3c3c3c; color: #cccccc; }
.ct-menu-button { padding: 3px 8px; border-radius: 3px; }
.ct-menu-button-open { background-color: #37373d; }
.ct-control { padding: 3px 8px; border-radius: 3px; background-color: #2d2d30; }
.ct-control-off { color: #6b6b6b; }
.ct-title { flex: 1 1 0; text-align: center; color: #9d9d9d; white-space: nowrap;
  overflow: hidden; }
.ct-menu { position: absolute; display: flex; flex-direction: column;
  min-width: 220px; padding: 4px 0; background-color: #252526;
  border: 1px solid #454545; color: #cccccc; font-size: 13px; }
.ct-menu-item { display: flex; flex-direction: row; padding: 3px 18px;
  white-space: nowrap; }
.ct-menu-item-label { flex: 1 1 0; }
.ct-menu-item-shortcut { color: #9d9d9d; padding-left: 24px; }
.ct-menu-item-off { color: #6b6b6b; }
.ct-menu-item-hi { background-color: #04395e; }
.ct-menu-sep { height: 1px; margin: 4px 0; background-color: #454545; }
"""

type
  TopBarControl* = object
    id*: string       ## the debugger control (`session_driver.runDebugControl`)
    label*: string
    enabled*: bool

  ZguiTopBar* = ref object
    renderer*: ZguiRenderer
    el*: ZguiNode
    menu*: MenuVM
    folderButtons*: seq[tuple[index: int; el: ZguiNode]]
    controlEls*: seq[tuple[id: string; el: ZguiNode]]
    titleEl*: ZguiNode
    popup*: ZguiNode
      ## The open menu's element in the popover layer, or nil.
    itemEls*: seq[tuple[index: int; el: ZguiNode]]
    onAction*: proc(action: string) {.closure.}
      ## A menu item's action (`forwardNext`, …) or a control's id prefixed
      ## `control:`.

proc textEl(r: ZguiRenderer; cls, text: string): ZguiNode =
  result = r.createElement("span")
  r.setAttribute(result, "class", cls)
  r.appendChild(result, r.createTextNode(text))

proc closeMenu*(t: ZguiTopBar) =
  if not t.popup.isNil:
    t.popup.release()
    t.popup = noNode
  t.itemEls = @[]
  for (_, b) in t.folderButtons:
    t.renderer.setAttribute(b, "class", "ct-menu-button")
  if t.menu.isOpen: t.menu.close()

proc paintHighlight(t: ZguiTopBar) =
  for (i, el) in t.itemEls:
    let it = t.menu.folderAt(t.menu.path).children[i]
    var cls = "ct-menu-item"
    if not it.enabled: cls.add " ct-menu-item-off"
    if i == t.menu.highlight: cls.add " ct-menu-item-hi"
    t.renderer.setAttribute(el, "class", cls)

proc runAction(t: ZguiTopBar; act: MenuActivation) =
  if act.ran:
    t.closeMenu()
    if not t.onAction.isNil: t.onAction(act.action)

# A listener is made by a proc of its own rather than inside the loop that
# installs it: a closure made in a loop body shares that body's variables
# across iterations, so every button would answer for the last one.

proc onItemClick(t: ZguiTopBar; path: seq[int]): ZguiHandler =
  result = proc(ev: ZguiEvent): uint32 =
    t.runAction(t.menu.clickPath(path))
    1'u32

proc openMenu*(t: ZguiTopBar; folderIndex: int; keyboard = false) =
  ## Open one top-level folder as a popover under its button.
  t.closeMenu()
  t.menu.openFolder(folderIndex, keyboard)
  if not t.menu.isOpen: return
  let r = t.renderer
  var button = noNode
  for (i, b) in t.folderButtons:
    if i == folderIndex:
      button = b
      r.setAttribute(b, "class", "ct-menu-button ct-menu-button-open")
  let layer = overlayRoot(t.el, olPopover)
  let popup = r.createElement("div")
  r.setAttribute(popup, "class", "ct-menu")
  r.setAttribute(popup, "role", "menu")
  r.setAttribute(popup, "data-ct-menu", t.menu.root.children[folderIndex].label)
  if not button.isNil:
    let box = button.borderBox()
    if box.ok:
      r.setStyle(popup, "left", $int(box.x) & "px")
      r.setStyle(popup, "top", $int(box.y + box.h) & "px")
  let folder = t.menu.root.children[folderIndex]
  for i, it in folder.children:
    if it.hidden: continue
    let row = r.createElement("div")
    r.setAttribute(row, "role", "menuitem")
    r.setAttribute(row, "data-ct-action", it.action)
    r.appendChild(row, textEl(r, "ct-menu-item-label",
      it.label & (if it.kind == mikFolder: "  ▸" else: "")))
    let chord = t.menu.shortcutFor(it.action)
    if chord.len > 0:
      r.appendChild(row, textEl(r, "ct-menu-item-shortcut", chord))
    addListener(row, "click", t.onItemClick(@[folderIndex, i]))
    r.appendChild(popup, row)
    t.itemEls.add (i, row)
    if it.separatorAfter:
      let s = r.createElement("div")
      r.setAttribute(s, "class", "ct-menu-sep")
      r.appendChild(popup, s)
  r.appendChild(layer, popup)
  t.popup = popup
  t.paintHighlight()

proc menuKey*(t: ZguiTopBar; key: string): bool =
  ## A key while a menu is open: the arrows move, Enter runs, Escape closes.
  ## Answers whether the menu took it.
  if t.popup.isNil: return false
  case key
  of "ArrowDown": t.menu.moveHighlight(1); t.paintHighlight()
  of "ArrowUp": t.menu.moveHighlight(-1); t.paintHighlight()
  of "Enter", " ": t.runAction(t.menu.activate())
  of "Escape": t.closeMenu()
  of "ArrowLeft", "ArrowRight":
    var open: seq[int] = @[]
    for (i, _) in t.folderButtons: open.add i
    let at = open.find(t.menu.path[0])
    if at >= 0 and open.len > 0:
      let next = open[(at + (if key == "ArrowRight": 1 else: -1) + open.len) mod open.len]
      t.openMenu(next, keyboard = true)
  else: return false
  true

proc setControls*(t: ZguiTopBar; controls: openArray[TopBarControl]) =
  ## The controls' availability, written in place.
  for c in controls:
    for (id, el) in t.controlEls:
      if id == c.id:
        t.renderer.setAttribute(el, "class",
          if c.enabled: "ct-control" else: "ct-control ct-control-off")
        t.renderer.setAttribute(el, "data-ct-enabled", $c.enabled)

proc setTitle*(t: ZguiTopBar; title: string) =
  t.renderer.setTextContent(t.titleEl, title)

proc onFolderClick(t: ZguiTopBar; index: int): ZguiHandler =
  result = proc(ev: ZguiEvent): uint32 =
    if not t.popup.isNil and t.menu.path.len > 0 and t.menu.path[0] == index:
      t.closeMenu()
    else:
      t.openMenu(index)
    1'u32

proc onControlClick(t: ZguiTopBar; id: string): ZguiHandler =
  result = proc(ev: ZguiEvent): uint32 =
    t.closeMenu()
    if not t.onAction.isNil: t.onAction("control:" & id)
    1'u32

proc renderTopBar*(r: ZguiRenderer; menu: MenuVM; title: string;
                   controls: openArray[TopBarControl];
                   onAction: proc(action: string)): ZguiTopBar =
  result = ZguiTopBar(renderer: r, menu: menu, onAction: onAction)
  let t = result
  t.el = r.createElement("div")
  r.setAttribute(t.el, "class", "ct-topbar")
  r.setAttribute(t.el, "role", "menubar")
  for i, it in menu.root.children:
    if it.hidden or it.kind != mikFolder: continue
    let b = textEl(r, "ct-menu-button", it.label)
    r.setAttribute(b, "data-ct-menu-button", it.label)
    addListener(b, "click", t.onFolderClick(i))
    r.appendChild(t.el, b)
    t.folderButtons.add (i, b)
  for c in controls:
    let b = textEl(r, "ct-control", c.label)
    r.setAttribute(b, "data-ct-control", c.id)
    addListener(b, "click", t.onControlClick(c.id))
    r.appendChild(t.el, b)
    t.controlEls.add (c.id, b)
  t.titleEl = textEl(r, "ct-title", title)
  r.appendChild(t.el, t.titleEl)
  t.setControls(controls)

func controlForMenuAction*(action: string): string =
  ## The debugger control a Debug menu item runs, or "".
  case action
  of "forwardContinue": "continue"
  of "forwardNext": "next"
  of "forwardStep": "step-in"
  of "forwardStepOut": "step-out"
  of "reverseContinue": "reverse-continue"
  of "reverseNext": "reverse-next"
  of "reverseStep": "reverse-step-in"
  of "reverseStepOut": "reverse-step-out"
  else: ""

func controlForOperation*(operation: string): string =
  ## The debugger control a keymap operation runs, or "".
  case operation
  of "debugger.step-over": "next"
  of "debugger.reverse-step-over": "reverse-next"
  of "debugger.step-into": "step-in"
  of "debugger.reverse-step-into": "reverse-step-in"
  of "debugger.step-out": "step-out"
  of "debugger.reverse-step-out": "reverse-step-out"
  of "debugger.continue": "continue"
  of "debugger.reverse-continue": "reverse-continue"
  else: ""

