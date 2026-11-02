## chord_display.nim — PLAT-68: the chord a desktop surface SHOWS for an
## action (a menu item, a toolbar tooltip, the shortcuts dialog), from the
## router that RUNS keys (`ui/key_router.chordForAction`, KL-8): a rebinding
## in `keybindings.json` is shown the moment it loads, and a shadowed chord is
## never shown.
##
## A leaf with no imports from the panes, so the menu and the debug toolbar
## can read it without depending on the router's module (which reaches the
## layout, which reaches them).

import ../types

var chordOfAction*: proc(action: ClientAction): cstring = nil
  ## Installed by `ui/key_router` at load.

proc displayedChord*(action: ClientAction): cstring =
  ## The chord shown beside `action`, or "" when no key reaches it here.
  if chordOfAction.isNil: cstring"" else: chordOfAction(action)
