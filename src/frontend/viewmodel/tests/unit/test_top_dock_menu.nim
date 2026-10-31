## All four native auto-hide edges must be reachable after dragging adopted
## GoldenLayout's split semantics. These are the actual menu models consumed
## by the TUI and GPUI, with no mocks or copied menu implementation.
import std/unittest
import headless_app/[layout_model, pane_clicks]

suite "native top docking remains reachable from context menus":
  test "a placed pane offers Pin to Top":
    let menu = tabContextMenu(paneState, false)
    let top = menu.labels.find("Pin to Top")
    require top >= 0
    check menu.entries[top].enabled
    check $menu.entries[top].action == "pin-top"
    check menu.target.pane == paneState

  test "every other dock edge offers Pin to Top":
    for edge in [leLeft, leBottom, leRight]:
      checkpoint $edge
      let menu = dockLabelContextMenu(paneState, edge)
      let top = menu.labels.find("Pin to Top")
      require top >= 0
      check menu.entries[top].enabled
      check $menu.entries[top].action == "pin-top"
      check menu.target.pane == paneState and menu.target.edge == edge

  test "a top-docked pane offers all the other edges and Unpin":
    let menu = dockLabelContextMenu(paneState, leTop)
    check "Pin to Top" notin menu.labels
    for label in ["Pin to Left", "Pin to Bottom", "Pin to Right", "Unpin"]:
      check label in menu.labels
