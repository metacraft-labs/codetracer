## alt_tap.nim — PLAT-68 Phase B: `Alt` PRESSED AND RELEASED ALONE.
##
## VS Code on Linux and Windows toggles its menu bar when `Alt` is tapped on
## its own (CUA-Keymap.md §3.8, the key name `Alt`). No keydown names that
## gesture: a front-end sees the modifier go down and come up, and it is a
## tap only when NOTHING happened in between — no other key (`Alt+F` is a
## chord, not a tap followed by `F`), no other modifier (`Alt+Shift` switches
## the keyboard layout on many desktops), no pointer press (`Alt`+drag moves a
## window).
##
## The rule, once, for every front-end that can see a modifier on its own:
## the desktop feeds it from `keydown` / `keyup` of `Alt`, GPUI from its
## modifier changes (`modifierschange`). A terminal reports no modifier alone
## and has no producer; it uses `` Alt+` ``.
##
## Owns: the tap state machine. Refuses to own: what a tap does (the router
## resolves the key name `Alt`).

import ../../../common/key_names

type
  AltTap* = object
    ## Whether the current press of `Alt` is still a candidate tap.
    held: KeyModifiers
      ## The modifiers held now, as last reported.
    armed: bool
      ## `Alt` went down alone and nothing has happened since.

func modifiersChanged*(t: var AltTap; now: KeyModifiers): bool =
  ## The held modifiers are now `now`. Answers whether this change COMPLETES
  ## a tap: `Alt` was pressed with nothing else held and is released with
  ## nothing having happened in between.
  let before = t.held
  t.held = now
  if before == {} and now == {kmodAlt}:
    t.armed = true
    return false
  if t.armed and before == {kmodAlt} and now == {}:
    t.armed = false
    return true
  # Another modifier joined, or one let go of while another is held.
  t.armed = false
  false

func interrupted*(t: var AltTap) =
  ## Something other than a modifier happened — a key, a pointer press, the
  ## window losing focus: the press of `Alt` in progress is not a tap.
  t.armed = false  # a chord now, or a click: no tap on the release

func reset*(t: var AltTap) =
  ## Forget the held set too (the window lost focus: a release may never be
  ## reported).
  t = AltTap()
