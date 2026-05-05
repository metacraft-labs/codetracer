## Focused headless checks for caption-bar session tab overflow.

import std/[strutils, tables, unittest]
import isonim/testing/mock_dom
import views/isonim_menu_shell_view
import views/isonim_session_tabs_view

proc findById(node: MockNode; id: string): MockNode =
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if found != nil:
      return found

proc findByClass(node: MockNode; cls: string): MockNode =
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found

proc findAllByClass(node: MockNode; cls: string): seq[MockNode] =
  if node.kind == mnkElement:
    for part in node.attributes.getOrDefault("class", "").split(' '):
      if part == cls:
        result.add(node)
        break
  for child in node.children:
    result.add(findAllByClass(child, cls))

suite "Caption session tabs overflow":
  test "menu shell owns the flex-row session-tab host":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(showNavigation: true, showWindowMenu: true))

    check findById(panel, NavigationMenuId) != nil
    check findById(panel, "isonim-debug-controls") != nil
    check findById(panel, "debug") != nil
    check findById(panel, SessionTabBarId) != nil
    check findByClass(panel, WindowMenuClass) != nil

  test "visible tabs stop at the supplied min-width capacity":
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2"),
        SessionTabRecord(label: "Trace 3"),
        SessionTabRecord(label: "Trace 4"),
        SessionTabRecord(label: "Trace 5")
      ],
      activeIndex = 4,
      visibleTabCount = 2)

    check panel.attributes["class"] == SessionTabBarOverflowClass
    check findAllByClass(panel, SessionTabClass).len == 2
    check findByClass(panel, SessionTabOverflowClass) != nil
    check findByClass(panel, SessionTabAddClass) != nil

    let overflowItems = findAllByClass(panel, SessionTabOverflowItemClass)
    check overflowItems.len == 5
    check overflowItems[4].attributes["class"].contains("active")

  test "active overflow tab replaces the last visible tab":
    check visibleTabIndexes(tabCount = 5, activeIndex = 1,
      visibleTabCount = 3) == @[0, 1, 2]
    check visibleTabIndexes(tabCount = 5, activeIndex = 4,
      visibleTabCount = 3) == @[0, 1, 4]
    check visibleTabIndexes(tabCount = 5, activeIndex = 4,
      visibleTabCount = 1) == @[4]

    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2"),
        SessionTabRecord(label: "Trace 3"),
        SessionTabRecord(label: "Trace 4"),
        SessionTabRecord(label: "Trace 5")
      ],
      activeIndex = 4,
      visibleTabCount = 3)

    let visibleTabs = findAllByClass(panel, SessionTabClass)
    check visibleTabs.len == 3
    check findById(panel, "session-tab-0") != nil
    check findById(panel, "session-tab-1") != nil
    check findById(panel, "session-tab-2").isNil
    check findById(panel, "session-tab-4") != nil
    check findById(panel, "session-tab-4").attributes["class"].contains("active")

  test "overflow menu items can select tabs hidden from the bar":
    var selected: seq[int] = @[]
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2"),
        SessionTabRecord(label: "Trace 3"),
        SessionTabRecord(label: "Trace 4")
      ],
      activeIndex = 0,
      visibleTabCount = 1,
      callbacks = SessionTabsCallbacks(
        onSelect: proc(index: int) = selected.add(index)))

    findAllByClass(panel, SessionTabOverflowItemClass)[3].fireEvent("click")
    check selected == @[3]
