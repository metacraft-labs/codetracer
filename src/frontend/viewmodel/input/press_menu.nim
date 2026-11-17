## press_menu.nim — an element that carries its own right-click menu, in a
## generic view: the menu travels with the element and the right press is the
## pointer row `context-menu.open` (Input-Routing-And-Keymaps.md §5.1).
##
## On a DOM front-end the view hands the menu to `dom_pointer.setPressMenu`
## and listens for nothing: the one pointer listener resolves the press and
## opens the menu the element carries. Under `MockRenderer` there is no pointer
## listener, so a suite's right press reaches the menu directly — the stand-in
## for the router a mock has not got, and the only place a press is wired here.

import isonim/testing/mock_dom
when defined(js):
  import std/jsffi
  import isonim/web/dom_api as isonim_dom
  import ./dom_pointer

type
  ElementMenu* = proc(x, y: int; ctrl, shift: bool): bool {.closure.}
    ## Opens the element's menu at (`x`, `y`); false when it opened none (the
    ## press is then the browser's).

proc bindPressMenu*[R, N](r: R; node: N; open: ElementMenu) =
  ## `node` opens `open`'s menu on a right press.
  if open.isNil:
    return
  when N is MockNode:
    r.addEventListener(node, "contextmenu", proc(ev: MockEvent) =
      if open(int(ev.clientX), int(ev.clientY), ev.ctrlKey, ev.shiftKey):
        ev.preventDefault()
        ev.stopPropagation())
  else:
    when defined(js):
      when N is isonim_dom.Element:
        setPressMenu(cast[JsObject](node), proc(event: JsObject): bool =
          open(event[cstring"clientX"].to(int), event[cstring"clientY"].to(int),
               event[cstring"ctrlKey"].to(bool), event[cstring"shiftKey"].to(bool)))
      else:
        {.error: "bindPressMenu: no press menu for this renderer".}
    else:
      {.error: "bindPressMenu: no press menu for this renderer".}
