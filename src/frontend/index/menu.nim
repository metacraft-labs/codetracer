import
  std/[ jsffi, strutils, sequtils ],
  config, electron_vars,
  ../lib/[ jslib, electron_lib ],
  ../[ types ]

when defined(ctmacos):
  # The native application menu's accelerators are the ROUTER's chords
  # (Base-Keymaps-And-Layer-Stack.md KL-8): the base the desktop runs with the
  # user's `keybindings.json` laid over it — the same text the renderer's
  # router reads (`index/keybindings`) — never the legacy YAML `bindings:`
  # table, which no key is delivered through since every key reaches the one
  # router (`ui/key_router`). Rebuilt whenever the file changes on disk.
  import ../viewmodel/keymap/[keymap_router, user_keymap, context_keys,
                              editing_keymap, menu_accelerators]
  import ./keybindings

  var
    menuRouter = initKeymapRouter(bkCua, KeyDelivery(
      frontEnd: feDesktop, platform: pkMac, keyProtocol: kpNative))
    lastMenu: MenuNode = nil

  proc menuNodeToItem(node: MenuNode): js =
    if node.kind == MenuFolder:
      var items: seq[js] = @[]
      for child in node.elements:
        if not cast[bool](child.menuOs and ord(MenuNodeOSNonMacOS)) and not cast[bool](child.menuOs and ord(MenuNodeOSHost)):
          items.add(menuNodeToItem(child))
          if child.isBeforeNextSubGroup:
            items.add(js{type: cstring"separator"})
      js{ label: node.name, enabled: node.enabled, submenu: cast[js](items), role: node.role }
    else:
      let accelerator = menuRouter.menuAccelerator($node.action)
      if node.role != "":
        js{ role: node.role }
      else:
        js{
          label: node.name,
          enabled: node.enabled,
          accelerator: cstring(accelerator),
          click: proc(menuItem: js, win: js) =
            mainWindow.webContents.send("CODETRACER::menu-action", js{action: node.action})
        }

  proc applyMenu(menu: MenuNode) =
    var elements: seq[js] = @[]
    for child in menu.elements:
      if child.menuOs != ord(MenuNodeOSNonMacOS):
        elements.add(menuNodeToItem(child))
        if child.isBeforeNextSubGroup:
          elements.add(js{type: cstring"separator"})
    Menu.setApplicationMenu(Menu.buildFromTemplate(cast[js](elements)))

  keybindings.onKeybindingsText = proc(text: string) =
    menuRouter.applyUserKeymap(parseUserKeymap(text))
    if not lastMenu.isNil:
      applyMenu(lastMenu)

  proc onRegisterMenu*(sender: js, response: jsobject(menu=MenuNode)) =
    lastMenu = response.menu
    applyMenu(lastMenu)

else:
  proc onRegisterMenu*(sender: js, response: jsobject(menu=MenuNode)) = discard
