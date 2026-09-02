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
## What is claimed, and what is not
## --------------------------------
## Shift+right-click bypasses a page's `contextmenu` handler in **Chrome and
## Firefox**. WebKit/Safari has no equivalent documented bypass, and — unlike
## the two engines named — that could not be verified here: a native context
## menu is drawn by the browser chrome, outside the page, and is suppressed
## entirely under automation, so no in-page or Playwright assertion can observe
## one in any engine.
##
## Rather than sniff the user agent and risk hiding the hint from a browser that
## does honour the gesture (or showing it to one that does not), the text NAMES
## the browsers the claim covers. It is then true as written in every browser it
## can appear in, including Safari, where it reads as "not for you" instead of
## as a broken instruction. That is the trade this module is making, and it is
## deliberate: a hint naming a gesture that does nothing is worse than no hint,
## because the user tries it, it fails, and they conclude the app is broken.
##
## No DOM, no `js` backend, no platform import — the two renderers of this row
## (`renderer.showContextMenu` and its twin in `views/context_menu_bridge.nim`)
## pass in the one fact that decides it, so the decision can be exercised
## headlessly on both backends. Same shape as `ui/menu_render_gate.nim`.

const
  ContextMenuBrowserHintText* =
    "Browser menu: Shift + right-click (Chrome, Firefox)"
    ## The row's text. A statement about the browser, phrased so no engine makes
    ## it false — see the module header.

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
