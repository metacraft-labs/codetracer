## gpui_keys.nim — GPUI's keystroke spelling → this product's canonical key
## names.
##
## The shim passes GPUI's own `keystroke.key` through verbatim (`"up"`,
## `"escape"`, `"a"`) with the modifiers as a separate list, and says why:
## *"the canonical-name vocabulary belongs to the consumer that has one"*.
## This is that consumer: GPUI's one decoder (Base-Keymaps-And-Layer-Stack.md
## §8 item 2), and like the terminal's it ends in `key_names.chordName`, the
## one function that spells modifiers — so a chord is the same string whichever
## device produced it, and one keymap resolves both front-ends' keys.
##
## `platform` (Super / the Windows key; Cmd on macOS) is spelled `Meta`.
## VS Code's `CtrlCmd` resolving to Cmd on macOS is not applied here: this
## front-end ships on Linux, and the macOS reading is recorded in
## CUA-Keymap.md §2 for when it does not.
##
## Pure: no FFI, no I/O.

import std/tables

import ../../../common/key_names

const
  GpuiNamedKeys* = {
    "escape": "Esc", "enter": "Enter", "backspace": "Backspace",
    "tab": "Tab", "space": "Space", "delete": "Delete",
    "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown",
    "insert": "Insert",
    "up": "Up", "down": "Down", "left": "Left", "right": "Right",
    "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
    "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11",
    "f12": "F12",
    "alt": "Alt",
  }.toTable
    ## GPUI's names for the non-printable keys, as `keystroke.key` spells
    ## them. `alt` is never a keystroke — GPUI reports a modifier alone as a
    ## modifier change — and is the name the window gives `Alt` pressed and
    ## released alone (`alt_tap`, CUA-Keymap.md §3.8).

func keyModifiersOfGpui*(modifiers: openArray[string]): KeyModifiers =
  ## GPUI's modifier names as this product's set (`platform` is Meta).
  if "control" in modifiers: result.incl kmodCtrl
  if "shift" in modifiers: result.incl kmodShift
  if "alt" in modifiers: result.incl kmodAlt
  if "platform" in modifiers: result.incl kmodMeta

proc canonicalKeyOfGpui*(key: string; modifiers: openArray[string]): string =
  ## The canonical name of one GPUI keystroke, or "" when there is none.
  ##
  ## A keystroke may arrive as the unshifted key plus `shift` (`` ` `` +
  ## shift) or as the shifted character (`~`); which one GPUI's platform
  ## layer sends is the platform's, so both are accepted and `chordName`
  ## folds them to one name.
  if "function" in modifiers:
    return ""
  let mods = keyModifiersOfGpui(modifiers)
  if GpuiNamedKeys.hasKey(key):
    return chordName(mods, GpuiNamedKeys[key])
  if key.len == 1 and key[0] >= ' ' and key[0] <= '~':
    return chordName(mods, key)
  ""
