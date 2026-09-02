## views/context_menu_hint.nim
##
## Pure decision logic for the one NON-INTERACTIVE row in our context menus:
## the line that names the browser's own escape hatch back to its native menu.
##
## Why this exists
## ---------------
## A user reported (2026-09-02, ide.codetracer.com) seeing *both* the browser's
## context menu and CodeTracer's when right-clicking the editor, and asked for a
## command in our menu that shows the browser's.
##
## **That command cannot be built.** A page can suppress the native context menu
## (`event.preventDefault()`) but the web platform gives it no way to *summon*
## one — there is no API, in any browser. A menu entry promising it would be a
## dead affordance, which is the exact defect class this product is currently
## tracking three instances of elsewhere. So the entry is a HINT, not a command:
## it names the gesture the browser itself provides and does nothing when
## clicked, because it is not clickable.
##
## Why the text names no browser, and how that was earned
## ------------------------------------------------------
## The first draft read "(Chrome, Firefox)", on the usual folklore that those
## two implement a Shift bypass and Safari does not. Measured instead, the
## picture is different — and it is different because of how the handlers are
## written, not because of what the browsers do.
##
## What the engines do with Shift held, measured 2026-09-02 with Playwright on
## a page whose `contextmenu` listener calls `preventDefault` unconditionally:
##
##     chromium 141.0.7390.37   the page STILL receives the event (shift: true)
##     firefox  142.0.1         the page receives NOTHING — not dispatched
##     webkit   26.0            the page STILL receives the event (shift: true)
##
## Firefox implements the bypass by not delivering the event at all, so the
## native menu opens whatever the page would have done. Chromium and WebKit both
## deliver it, which means what happens next is decided by the page.
##
## And our handlers STAND DOWN on Shift rather than suppressing and hoping the
## browser overrides them (`ui/editor.nim`, `ui/flow.nim`, `ui/value.nim`). So on
## every engine that delivers the event we show nothing and prevent nothing, and
## the browser's default action for an unprevented `contextmenu` — its own menu
## — happens. On the one engine that does not deliver it, the same menu happens
## for the engine's own reason.
##
## That covers Safari through WebKit, which is why the browser names came out of
## the text. What is still NOT claimed, and cannot be from here: that the menu
## is actually *painted*. A native context menu is browser chrome, outside the
## document, and every engine suppresses it under automation — so no in-page or
## Playwright assertion can observe one anywhere. What is asserted, in
## `ci/test/menu-and-context-menu-in-browser.sh`, is the half this code owns:
## with Shift held, our menu is not shown and `defaultPrevented` is false.
##
## No DOM, no `js` backend, no platform import — the two renderers of this row
## (`renderer.showContextMenu` and its twin in `views/context_menu_bridge.nim`)
## pass in the one fact that decides it, so the decision can be exercised
## headlessly on both backends. Same shape as `ui/menu_render_gate.nim`.

const
  ContextMenuBrowserHintText* =
    "Browser menu: Shift + right-click"
    ## The row's text. Unqualified because it is true on every engine measured,
    ## and it is true because OUR handlers stand down on Shift rather than
    ## relying on the browser to override them — see the module header for the
    ## per-engine measurement that replaced an earlier "(Chrome, Firefox)".

  ContextMenuHintClass* = "context-menu-hint"
    ## The row's only class. Deliberately NOT `context-menu-item` and NOT
    ## `ct-menu-item`: those carry the hover highlight, the pointer cursor and
    ## the selectors that keyboard traversal and the GUI suite use to find
    ## COMMANDS. A row that looked selectable and did nothing is the thing this
    ## row exists to avoid being.

  ContextMenuHintId* = "context-menu-browser-hint"
    ## Stable id so a test can assert the row is present AND that it is inert,
    ## which is the assertion pair that matters here: presence alone would pass
    ## over a row that had secretly become a dead command.

proc contextMenuBrowserHint*(inElectron: bool): string =
  ## The hint row's text, or `""` when there must be no row.
  ##
  ## `inElectron` is the whole decision. Electron draws no context menu of its
  ## own over ours, so there is nothing to escape TO and the gesture does
  ## nothing there — the hint would be false on the desktop, which is the same
  ## failure as showing it in a browser that ignores the modifier.
  if inElectron:
    ""
  else:
    ContextMenuBrowserHintText
