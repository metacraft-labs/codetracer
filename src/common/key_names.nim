## key_names.nim — PLAT-31: the CANONICAL KEY NAME, and the one predicate that
## decides whether a key stands for a character.
##
## Owns: the byte-token → canonical-name decoder (`keyName`) and the
## text-entry predicate (`keyCharacter` / `isTextKey`) that
## `GUI/Editing-Operations-And-Keymaps.md` §4.3 names as the fourth scope
## dimension.
##
## ## WHY THIS FILE EXISTS AT ALL: §30, PERFORMED RATHER THAN CITED
##
## Every line below was `src/frontend/tui/app/input/keymap.nim`'s until
## PLAT-31, and PLAT-31's spec asks for the text-entry rule to reuse
## *"`keymap.nim`'s existing `keyCharacter` spelling rather than
## `isPrintableKey`"*. There were exactly two ways to obey that sentence:
##
##   1. spell the rule again in the editing keymap, or
##   2. move the rule into one module both keymaps call.
##
## (1) is [Verification-Harness-Traps §30a](../../../codetracer-specs/Testing/Verification-Harness-Traps.md)
## in its worst recorded form — *"the worst instance was a whole re-derived
## module"* — and §30a's example is precisely a second author deriving a
## predicate from the same examples and getting it subtly narrower. The
## predicate being copied here would have been the one whose narrower spelling
## **already cost this product a defect**: `keyName(" ")` is the five-letter
## name `"Space"`, `isPrintableKey` answers false for it, and under that
## spelling a space typed at the `:` prompt resolved to nothing and `:goto 4500`
## could not be typed at all.
##
## So (2). `tui/app/input/keymap.nim` imports and re-exports this module and its
## call sites are unchanged; `viewmodel/keymap/editing_keymap.nim` imports the
## same names. **One predicate, one function, and the mutation goes on the
## function** (§30b), which is what makes the debugger keymap's arms and the
## editing keymap's arms evidence about each other rather than two opinions
## from one mistake.
##
## `src/common/` and not either front-end's tree, for `editing_key_bindings.nim`'s
## reason one directory up: *"nothing here imports `isonim_tui` or `viewmodel/`"*,
## so both halves can read it without either layer rule moving.
##
## ## NOTHING HERE READS A TERMINAL
##
## This module is a pure function over a `string`. It has no `std/os`, no
## `std/times`, no FFI — which is what lets it compile on the C, JS and wasm32
## backends the ViewModel suites run on, and `tui/app/input/keymap.nim` kept its
## own `std/os` (it has a `loadKeymapFile`) rather than this module gaining one.

import std/[strutils, tables]

const
  FunctionKeyCodes* = {
    15: "F5", 17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10", 23: "F11",
    24: "F12"}.toTable
    ## xterm's `CSI <code> ~` function keys. F1-F4 use SS3 (`ESC O P..S`) and
    ## are handled separately, which is xterm's own split rather than this
    ## module's — https://invisible-island.net/xterm/ctlseqs/ctlseqs.html,
    ## "PC-Style Function Keys".

  ModifierNames* = {2: "Shift", 3: "Alt", 4: "Shift+Alt", 5: "Ctrl",
                    6: "Ctrl+Shift", 7: "Ctrl+Alt", 8: "Ctrl+Alt+Shift"}.toTable
    ## xterm's modifier parameter: the value is `1 + (Shift=1 | Alt=2 | Ctrl=4)`.
    ## Spelled in the order CodeTracer-TUI.md §4.2 writes them (`Shift+F10`,
    ## `Alt+F5`, `Ctrl+p`).

proc isPrintableKey*(name: string): bool =
  ## Whether a canonical key name is a single printable character.
  ##
  ## `Esc`, `Enter`, `Tab`, `F10` and `Ctrl+p` are all multi-character names,
  ## so this needs no second list to know they are not characters. It is NOT
  ## the whole of the text-entry shadowing rule — see `keyCharacter`.
  name.len == 1 and name[0] >= ' ' and name[0] <= '~'

proc keyCharacter*(name: string): string =
  ## The CHARACTER a canonical key name inserts into a text field, or "".
  ##
  ## THE PREDICATE THE TEXT-ENTRY SHADOWING RULE ACTUALLY USES, and it is not
  ## `isPrintableKey` because of exactly one key. `keyName` answers `"Space"`
  ## for byte `0x20`, deliberately: CodeTracer-TUI.md §4.2 binds `Space` to
  ## "Toggle Breakpoint" and a table cell reading ` ` would be unreadable. But
  ## `isPrintableKey` answers false for a five-letter name, so under CTUI-9's
  ## rule a space typed at a `:` prompt resolved to `krNone` AND WAS SILENTLY
  ## LOST — `:goto 4500` could not be typed at all.
  ##
  ## CTUI-9 could not have seen it: its own header records that "§4.2's table
  ## has no key that enters INSPECT mode and no way to run or edit the `:`
  ## prompt", so there was no text field to lose a character into. CTUI-10 has
  ## one, and `tests/real_terminal/test_real_command_mode.nim` types
  ## `:goto 4500` as real bytes on a real pty, which is where this was measured.
  ##
  ## **PLAT-31 IS THE SECOND CONSUMER AND THAT IS WHY THIS MOVED.** The editing
  ## keymap's text-entry scope asks the same question of the same key names; a
  ## second spelling of this five-line function is the one thing §30a says not
  ## to write. The difference between the two spellings is still exactly one
  ## key, and `test_editor_keymap_laws.nim` asserts it on `Space` BY NAME —
  ## a rule whose one known counterexample is not in the suite is a rule tested
  ## on the cases that never failed.
  if name == "Space": " "
  elif isPrintableKey(name): name
  else: ""

proc isTextKey*(name: string): bool =
  ## Whether a text field owns this key. `keyCharacter` with the character
  ## thrown away, named so a resolver reads as a rule rather than as a length
  ## test.
  keyCharacter(name).len > 0

proc keyName*(token: string): string =
  ## The canonical name of one complete input token — a byte, or a whole escape
  ## sequence as `testing/test_app_runtime.nim` frames them.
  ##
  ## Returns "" for anything unrecognised (an SGR-1006 mouse report, a runaway
  ## sequence), so a caller can tell "not a key" from "a key nothing is bound
  ## to".
  if token.len == 0:
    return ""
  if token.len == 1:
    let c = token[0]
    case c
    of '\t': return "Tab"
    of '\r', '\n': return "Enter"
    # `\b` is Ctrl+H on the wire and `\x7f` is what most terminals send for
    # Backspace. Both spell Backspace here, which costs the product a `Ctrl+h`
    # binding it does not have and buys a Backspace that works on every
    # terminal.
    of '\x7f', '\b': return "Backspace"
    of ' ': return "Space"
    of '\x1b': return "Esc"
    else:
      if c >= '\x01' and c <= '\x1a':
        return "Ctrl+" & $char(ord('a') + ord(c) - 1)
      if c >= ' ' and c <= '~':
        return $c
      return ""
  # SS3: ESC O P..S — F1 to F4.
  if token.len == 3 and token[0] == '\x1b' and token[1] == 'O':
    case token[2]
    of 'P': return "F1"
    of 'Q': return "F2"
    of 'R': return "F3"
    of 'S': return "F4"
    else: return ""
  if token.len < 3 or token[0] != '\x1b' or token[1] != '[':
    return ""
  let body = token[2 .. ^1]
  let final = body[^1]
  let params = body[0 ..< body.len - 1]
  case final
  of 'A', 'B', 'C', 'D':
    # Arrows, plain (`CSI A`) or modified (`CSI 1 ; m A`).
    let name = case final
               of 'A': "Up"
               of 'B': "Down"
               of 'C': "Right"
               else: "Left"
    if params.len == 0:
      return name
    let parts = params.split(';')
    if parts.len == 2 and parts[0] == "1":
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          return ModifierNames[m] & "+" & name
      except ValueError:
        return ""
    return ""
  of 'Z':
    # `CSI Z` is xterm's back-tab, which is what `Shift+Tab` sends.
    if params.len == 0: return "Shift+Tab"
    return ""
  of 'P', 'Q', 'R', 'S':
    # Modified F1-F4: `CSI 1 ; m P`.
    let parts = params.split(';')
    if parts.len == 2 and parts[0] == "1":
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          let name = case final
                     of 'P': "F1"
                     of 'Q': "F2"
                     of 'R': "F3"
                     else: "F4"
          return ModifierNames[m] & "+" & name
      except ValueError:
        return ""
    return ""
  of '~':
    let parts = params.split(';')
    var code = 0
    try:
      code = parseInt(parts[0])
    except ValueError:
      return ""
    var base = ""
    if FunctionKeyCodes.hasKey(code):
      base = FunctionKeyCodes[code]
    else:
      case code
      of 2: base = "Insert"
      of 3: base = "Delete"
      of 5: base = "PageUp"
      of 6: base = "PageDown"
      else: return ""
    if parts.len == 1:
      return base
    if parts.len == 2:
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          return ModifierNames[m] & "+" & base
      except ValueError:
        return ""
    return ""
  else:
    return ""
