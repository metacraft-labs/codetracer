## chord_display.nim — PLAT-68: the chord a desktop surface SHOWS for an
## action (a menu item, a toolbar tooltip, the shortcuts dialog), from the
## router that RUNS keys (`ui/key_router.chordForAction`, KL-8): a rebinding
## in `keybindings.json` is shown the moment it loads, and a shadowed chord is
## never shown.
##
## A leaf with no imports from the panes, so the menu and the debug toolbar
## can read it without depending on the router's module (which reaches the
## layout, which reaches them).

import std/jsffi
from ../lib/jslib import hasKey
import ../types

var chordOfAction*: proc(action: ClientAction): cstring = nil
  ## Installed by `ui/key_router` at load.

var heldChords: JsAssoc[cstring, cstring]
  ## The chords already looked up while `holdingChords` runs, by action.
  ## Nil outside it.

proc displayedChord*(action: ClientAction): cstring =
  ## The chord shown beside `action`, or "" when no key reaches it here.
  if chordOfAction.isNil:
    return cstring""
  if heldChords.isNil:
    return chordOfAction(action)
  let key = cstring($action)
  if heldChords.hasKey(key):
    return heldChords[key]
  result = chordOfAction(action)
  heldChords[key] = result

template holdingChords*(body: untyped) =
  ## Run `body` with each action's chord looked up once.
  ##
  ## A lookup asks the router (`ui/key_router.chordForAction`), which works
  ## out the focused element's scope path from the DOM every time: tens of
  ## milliseconds on a loaded host. One menu build shows the chord of every
  ## item and reached the router once per item per sibling, and `data.redraw()`
  ## rebuilds the menu, so a jump that redrew three times spent about a third
  ## of the time before the new editor mounted there. Nothing a build reads
  ## changes the answer while it runs, so it is held for the build and
  ## dropped after: the next build sees a rebinding or a focus change.
  let outermost = heldChords.isNil
  if outermost:
    heldChords = JsAssoc[cstring, cstring]{}
  try:
    body
  finally:
    if outermost:
      heldChords = nil
