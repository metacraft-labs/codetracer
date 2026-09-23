## gpui_keys.nim — PLAT-44: GPUI's keystroke spelling → this product's
## canonical key names.
##
## The shim passes GPUI's own `keystroke.key` through verbatim (`"up"`,
## `"escape"`, `"a"`) with the modifiers as a separate list, and says why:
## *"the canonical-name vocabulary belongs to the consumer that has one"*.
## This is that consumer. Its answers are the names `key_names.keyName` gives
## the terminal's bytes — `"Esc"`, `"Up"`, `"Ctrl+x"`, `"Shift+Tab"` — so one
## editing keymap resolves both front-ends' keys.
##
## TWO INDEPENDENT READINGS OF ONE KEYSTROKE, NOT ONE FUNCTION CALLED TWICE.
## The terminal decodes BYTES and this decodes GPUI's NAMES; what ties them is
## asserted in `tests/test_gpui_keys.nim` — every key PLAT-31's divergent tasks
## use, spelled as GPUI would deliver it, must decode here to the name the
## terminal's decoder gives the same key's bytes.
##
## The modifier PREFIX is spelled through `key_names.ModifierNames` — the
## terminal's own table (`Ctrl+Shift`, `Shift+Alt`) — rather than a second
## ordering of the same words.
##
## Pure: no FFI, no I/O.

import std/[strutils, tables]

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
  }.toTable
    ## GPUI's names for the non-printable keys, as `keystroke.key` spells
    ## them.

  UsShiftedSymbols* = {
    '`': '~', '1': '!', '2': '@', '3': '#', '4': '$', '5': '%', '6': '^',
    '7': '&', '8': '*', '9': '(', '0': ')', '-': '_', '=': '+', '[': '{',
    ']': '}', '\\': '|', ';': ':', '\'': '"', ',': '<', '.': '>',
    '/': '?'}.toTable
    ## The US layout's shifted symbols. A keystroke may arrive as the UNSHIFTED
    ## key plus `shift` (`` ` `` + shift) or as the shifted character itself
    ## (`~`); which one GPUI's platform layer sends is a property of the
    ## platform and is measured by the window lane rather than assumed, so the
    ## decoder accepts both and they decode to the same name.

proc canonicalKeyOfGpui*(key: string; modifiers: openArray[string]): string =
  ## The canonical name of one GPUI keystroke, or "" when there is none.
  ##
  ## * A printable character with `shift` is the SHIFTED character and no
  ##   prefix — `a` + shift is `A` — because that is what the terminal's bytes
  ##   decode to (a terminal sends `A`, not "Shift+a").
  ## * `control` + a letter is `Ctrl+<lower>`, the terminal's spelling.
  ## * Every other modified key takes `ModifierNames`' prefix.
  let ctrl = "control" in modifiers
  let alt = "alt" in modifiers
  let shift = "shift" in modifiers
  if "platform" in modifiers or "function" in modifiers:
    return ""
  var base = ""
  var printable = false
  if GpuiNamedKeys.hasKey(key):
    base = GpuiNamedKeys[key]
  elif key.len == 1 and key[0] >= ' ' and key[0] <= '~':
    base = key
    printable = true
  else:
    return ""
  if printable:
    if ctrl or alt:
      # The terminal names control letters `Ctrl+<lower>`; shift is not
      # separately observable in a control byte.
      base = base.toLowerAscii
      let m = 1 + (if alt: 2 else: 0) + (if ctrl: 4 else: 0)
      return ModifierNames[m] & "+" & base
    if shift and base[0] in 'a'..'z':
      return $base[0].toUpperAscii
    if shift and UsShiftedSymbols.hasKey(base[0]):
      return $UsShiftedSymbols[base[0]]
    return base
  let m = 1 + (if shift: 1 else: 0) + (if alt: 2 else: 0) +
          (if ctrl: 4 else: 0)
  if m == 1: base
  else: ModifierNames[m] & "+" & base
