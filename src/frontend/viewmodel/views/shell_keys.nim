## shell_keys.nim — a browser `KeyboardEvent` as the Shell pane's key.
##
## Owns: the desktop's decoder for the one pane whose keys are its shell's
## (CodeTracer-Shell.md §7.5): every key goes to the pty, so this names them for
## `ShellVM.pressKey` and decides nothing. Declared to
## `ci/test/input-routing-gate.sh` as that decoder.
##
## Refuses to own: the prefix and what a key does (`shell_vm`).

from std/unicode import runes

import ../viewmodels/shell_vm

func domKeyName(key: string): string =
  case key
  of "ArrowUp": "Up"
  of "ArrowDown": "Down"
  of "ArrowLeft": "Left"
  of "ArrowRight": "Right"
  of " ": "Space"
  else: key

proc shellKeyOfDom*(key: string; ctrl, alt, shift: bool): ShellKey =
  ## A browser `KeyboardEvent` as the model's key: a named key by its name,
  ## a character by itself (`text`).
  let name = domKeyName(key)
  var text = ""
  var n = 0
  for _ in key.runes:
    inc n
  if n == 1 and name != "Space":
    text = key
  ShellKey(key: name, text: text, ctrl: ctrl, alt: alt, shift: shift)
