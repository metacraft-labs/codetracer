## menu_item_click_runs_once_test.nim
##
## One click on a menu entry runs its action once.
##
## The menu shell drew each entry as an item inside a row container and gave
## BOTH an `onclick` that activates the entry. A click on the item's label
## bubbles from the item to the row, so the entry was activated twice per
## click. For most entries the second run was invisible (a pane already open
## is opened again), but for a toggle it undid the first: View > Notifications
## and Help > Report a Problem opened their status-bar popover and closed it
## again within the same click, so neither could be opened from the menu.
##
## The click is delivered the way a browser delivers it: to the label the
## pointer is over, then to every ancestor in turn. `MockRenderer` runs only the
## handlers of the node an event is fired on, so the bubbling is spelled out
## here, along the real view's own tree.

import std/[tables, unittest]
import isonim/testing/mock_dom
import views/isonim_menu_shell_view

proc record(name: string; path: seq[int];
            kind: MenuNodeRecordKind = MenuRecordElement;
            children: seq[MenuNodeRecord] = @[]): MenuNodeRecord =
  MenuNodeRecord(kind: kind, name: name, shortcut: "", enabled: true,
                 iconClass: "", nameClass: "", nodeClass: "", path: path,
                 nameWidth: name.len + 1, beforeNextSubGroup: false,
                 children: children)

proc labelNamed(node: MockNode; name: string): MockNode =
  ## The `ct-menu-item-label` span whose text is `name`.
  if node.isNil:
    return nil
  if node.attributes.getOrDefault("class", "") == "ct-menu-item-label" and
      node.textContent == name:
    return node
  for child in node.children:
    let found = labelNamed(child, name)
    if not found.isNil:
      return found
  nil

proc clickBubbling(target: MockNode) =
  ## `click` on `target`, then on each of its ancestors, as the DOM bubbles it.
  var node = target
  while not node.isNil:
    fireEvent(node, "click")
    node = node.parent

suite "a menu entry clicked once":
  test "runs its action once, from the top level and from an open folder":
    var clicks: seq[seq[int]] = @[]
    let callbacks = MenuShellCallbacks(
      onNodeClick: proc(path: seq[int]) = clicks.add path)
    let model = MenuShellModel(
      showNavigation: true, active: true, searchQuery: "",
      rootNodes: @[
        record("View", @[0], kind = MenuRecordFolder, children = @[
          record("Notifications", @[0, 0])]),
        record("Settings", @[1])],
      searchResults: @[],
      nestedMenus: @[MenuNestedRecord(
        id: "menu-nested-elements-1", className: "menu-nested-elements",
        style: "", nodes: @[record("Notifications", @[0, 0])])],
      showWindowMenu: false, maximized: false)
    let r = MockRenderer()
    let host = r.createElement("div")
    renderMenuShellInto[MockRenderer, MockNode](r, host, model, callbacks)

    let nested = labelNamed(host, "Notifications")
    check not nested.isNil
    clickBubbling(nested)
    check clicks == @[@[0, 0]]

    clicks.setLen(0)
    let topLevel = labelNamed(host, "Settings")
    check not topLevel.isNil
    clickBubbling(topLevel)
    check clicks == @[@[1]]
