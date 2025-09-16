import
  std/[ jsffi, strutils, sequtils ],
  config, electron_vars,
  ../[ lib, types ]

when defined(ctmacos):
  let modMap* : JsAssoc[cstring, cstring] = JsAssoc[cstring, cstring]{
    $"ctrl":    $"cmdorctrl",
    $"meta":    $"cmd",
    $"super":   $"cmd",
    $"shift":   $"shift",
    $"alt":     $"option",
  }

  proc lookup(map: JsAssoc[cstring,cstring], tok: string): string =
    let v = map[tok.cstring]
    if v.isNil: tok else: $v

  proc toAccelerator* (raw: cstring): string =
    let s = $raw
    result = s
      .split({'+'})
      .mapIt(lookup(modMap, it.toLowerAscii))
      .join("+")

  proc menuNodeToItem(node: MenuNode): js =
    if node.kind == MenuFolder:
      var items: seq[js] = @[]
      for child in node.elements:
        if child.menuOs != ord(MenuNodeOSNonMacOS):
          items.add(menuNodeToItem(child))
          if child.isBeforeNextSubGroup:
            items.add(js{type: cstring"separator"})
      js{ label: node.name, enabled: node.enabled, submenu: cast[js](items), role: node.role }
    else:
      let binding = data.config.shortcutMap.actionShortcuts[node.action]
      let resultBinding = if binding.len == 0: "" else: toAccelerator($binding[0].renderer)
      if node.role != "":
        js{ role: node.role }
      else:
        js{
          label: node.name,
          enabled: node.enabled,
          accelerator: cstring(resultBinding),
          click: proc(menuItem: js, win: js) =
            mainWindow.webContents.send("CODETRACER::menu-action", js{action: node.action})
        }

  proc onRegisterMenu*(sender: js, response: jsobject(menu=MenuNode)) =
    var elements: seq[js] = @[]
    for child in response.menu.elements:
      if child.menuOs != ord(MenuNodeOSNonMacOS):
        elements.add(menuNodeToItem(child))
        if child.isBeforeNextSubGroup:
          elements.add(js{type: cstring"separator"})
    let menu = Menu.buildFromTemplate(cast[js](elements))
    Menu.setApplicationMenu(menu)

else:
  proc onRegisterMenu*(sender: js, response: jsobject(menu=MenuNode)) = discard
