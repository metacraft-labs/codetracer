## key_names.nim — THE CANONICAL KEY NAME: one modifier order, one spelling
## function, the terminal's byte decoder, and the one predicate that decides
## whether a key stands for a character.
##
## Owns:
##
##   * `chordName` — the ONLY function that spells a key with its modifiers.
##     Every decoder (the terminal's bytes here, GPUI's keystrokes in
##     `gpui/app/gpui_keys.nim`, the desktop's `KeyboardEvent` in
##     `key_event_names.nim`) and every reader of a written chord
##     (`normalizeChord`) ends in it, so `Ctrl+Shift+Alt+Up` written in a file,
##     decoded from `CSI 1 ; 8 A` and delivered by GPUI as `up` + three
##     modifiers are one string.
##   * `keyName` — the byte-token → canonical-name decoder for the terminal.
##   * `keyCharacter` / `isTextKey` — the text-entry predicate
##     (`GUI/Editing-Operations-And-Keymaps.md` §4.3).
##
## ## THE ORDER IS VS CODE'S: Ctrl, Shift, Alt, Meta
##
## Base-Keymaps-And-Layer-Stack.md §2 measured the table this module replaced
## (`ModifierNames`) ordering `Shift` before `Alt` in `Shift+Alt` and after it
## in `Ctrl+Alt+Shift`, so VS Code's Linux copy-line chord `Ctrl+Shift+Alt+Up`
## could never equal what the decoder produced. One order, one function.
##
## ## LETTERS AND SHIFT
##
## A terminal sends `A`, not "Shift+a", so an unmodified or Shift-only letter
## is the letter in its case (`a`, `A`) and a shifted US symbol is the shifted
## symbol (`?`). As soon as `Ctrl`, `Alt` or `Meta` is held the key is the
## UNSHIFTED key and `Shift` is spelled: `Ctrl+Shift+k`, `Shift+Alt+a`,
## `Ctrl+Shift+[`. That is the only reading under which xterm's legacy
## `ESC A`, the Kitty protocol's `CSI 97 ; 4 u` and GPUI's `a` + alt + shift
## are the same chord.
##
## ## NOTHING HERE READS A TERMINAL
##
## A pure function over strings: no `std/os`, no clock, no FFI, so it compiles
## on the C, JS and wasm32 backends the ViewModel suites run on. The terminal's
## erase byte (termios `VERASE`) is a PARAMETER of `keyName`, supplied by the
## driver that read it, rather than something this module asks a tty.

import std/[strutils, tables]

type
  KeyModifier* = enum
    ## Declared in the canonical order; `chordName` spells a set in this
    ## order and in no other.
    kmodCtrl = "Ctrl"
    kmodShift = "Shift"
    kmodAlt = "Alt"
    kmodMeta = "Meta"

  KeyModifiers* = set[KeyModifier]

  KeyProtocol* = enum
    ## How chords reach a front-end (Base-Keymaps-And-Layer-Stack.md §7): the
    ## `keyProtocol` context key. Here, beside the decoder whose input it
    ## describes, so the terminal's capability negotiation and the shared
    ## keymap read ONE enum.
    kpLegacy = "legacy"
      ## The classic xterm encoding: modified keys that have no byte of their
      ## own (`Ctrl+Shift+K`, `Shift+Enter`) cannot be typed.
    kpKitty = "kitty"
      ## The Kitty keyboard protocol, flag 1 (disambiguate escape codes).
    kpModifyOtherKeys = "modify-other-keys"
      ## xterm's `modifyOtherKeys` level 2.
    kpNative = "native"
      ## A front-end that receives keys, not bytes: GPUI and the desktop.

const
  UsShiftedSymbols* = {
    '`': '~', '1': '!', '2': '@', '3': '#', '4': '$', '5': '%', '6': '^',
    '7': '&', '8': '*', '9': '(', '0': ')', '-': '_', '=': '+', '[': '{',
    ']': '}', '\\': '|', ';': ':', '\'': '"', ',': '<', '.': '>',
    '/': '?'}.toTable
    ## The US layout's shifted symbols. A keystroke may arrive as the
    ## unshifted key plus Shift (GPUI, Kitty) or as the shifted character
    ## (a terminal's plain bytes); both spell the same name.

  NamedKeys* = [
    "Esc", "Enter", "Tab", "Backspace", "Delete", "Insert", "Space",
    "Home", "End", "PageUp", "PageDown", "Up", "Down", "Left", "Right",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11",
    "F12"]
    ## Every canonical non-character key name. Closed: `normalizeChord`
    ## refuses anything that is neither one of these nor one printable
    ## character.

  KeyAliases = {
    "escape": "Esc", "esc": "Esc", "return": "Enter", "enter": "Enter",
    "tab": "Tab", "backspace": "Backspace", "bs": "Backspace",
    "delete": "Delete", "del": "Delete", "insert": "Insert", "ins": "Insert",
    "space": "Space", "spc": "Space", "home": "Home", "end": "End",
    "pageup": "PageUp", "pgup": "PageUp", "pagedown": "PageDown",
    "pgdn": "PageDown", "up": "Up", "uparrow": "Up", "down": "Down",
    "downarrow": "Down", "left": "Left", "leftarrow": "Left",
    "right": "Right", "rightarrow": "Right", "backquote": "`"}.toTable
    ## Spellings `normalizeChord` accepts for a key, lower-cased: this
    ## product's own, VS Code's (`escape`, `pageup`), and GPUI's.

  ModifierAliases = {
    "ctrl": kmodCtrl, "control": kmodCtrl, "ctrlcmd": kmodCtrl,
    "shift": kmodShift, "alt": kmodAlt, "option": kmodAlt, "opt": kmodAlt,
    "meta": kmodMeta, "cmd": kmodMeta, "win": kmodMeta, "super": kmodMeta}.toTable
    ## `CtrlCmd` is VS Code's "Ctrl, or Cmd on macOS"; every terminal and
    ## this decoder resolve it to `Ctrl` (Base-Keymaps §7.4).

func shiftedOf(c: char): char =
  if c in 'a'..'z': chr(ord(c) - 32)
  elif UsShiftedSymbols.hasKey(c): UsShiftedSymbols[c]
  else: '\0'

func unshiftedOf(c: char): char =
  ## The key that, with Shift, produces `c`; `'\0'` when `c` is not a shifted
  ## character.
  if c in 'A'..'Z': return chr(ord(c) + 32)
  for k, v in UsShiftedSymbols:
    if v == c: return k
  '\0'

func chordName*(mods: KeyModifiers; key: string): string =
  ## **THE ONE SPELLING.** A key name with its modifiers, in the canonical
  ## order. `key` is a `NamedKeys` member or one printable character, in
  ## either case; "" yields "".
  if key.len == 0:
    return ""
  var m = mods
  var k = key
  if k.len == 1:
    var c = k[0]
    if c < ' ' or c > '~':
      return ""
    if c == ' ':
      k = "Space"
    else:
      # Fold a shifted character back to its key plus Shift…
      let un = unshiftedOf(c)
      if un != '\0':
        c = un
        m.incl kmodShift
      # …then, with no command modifier, Shift is spelled by the character.
      if (m * {kmodCtrl, kmodAlt, kmodMeta}) == {}:
        if kmodShift in m:
          let s = shiftedOf(c)
          if s != '\0':
            return $s
        return (if kmodShift in m: "Shift+" else: "") & $c
      k = $c
  result = ""
  for mo in KeyModifier:
    if mo in m:
      result.add $mo
      result.add '+'
  result.add k

func normalizeChord*(text: string): string =
  ## One written chord (`Ctrl+Shift+K`, `ctrl+shift+k`, `Escape`,
  ## `Shift+Alt+A`) → its canonical name, or "" when it names no key.
  ## Case-insensitive in the modifiers and the named keys. **A letter is a
  ## KEY, whatever case it is written in, and Shift is written explicitly** —
  ## VS Code's notation, which CUA-Keymap.md and `keybindings.json` use:
  ## `Ctrl+K S` is the S key, `Ctrl+K Shift+O` the shifted O. (This product's
  ## own canonical names spell a shifted letter as the capital, `G`; those are
  ## names, already canonical, and never go through this function.)
  if text.len == 0:
    return ""
  var parts: seq[string] = @[]
  var cur = ""
  for i, ch in text:
    # A literal `+` key is the last token: `Ctrl++`.
    if ch == '+' and cur.len > 0:
      parts.add cur
      cur = ""
    else:
      cur.add ch
  parts.add cur
  var mods: KeyModifiers = {}
  for i in 0 ..< parts.len - 1:
    let p = parts[i].toLowerAscii
    if not ModifierAliases.hasKey(p):
      return ""
    mods.incl ModifierAliases[p]
  var key = parts[^1]
  if key.len == 1:
    var c = key[0]
    if c in 'A'..'Z':
      c = chr(ord(c) + 32)
    return chordName(mods, $c)
  let lower = key.toLowerAscii
  if KeyAliases.hasKey(lower):
    return chordName(mods, KeyAliases[lower])
  if lower.len >= 2 and lower[0] == 'f':
    try:
      let n = parseInt(lower[1 .. ^1])
      if n >= 1 and n <= 12:
        return chordName(mods, "F" & $n)
    except ValueError:
      discard
  ""

func normalizeChordSequence*(text: string): string =
  ## A space-separated chord sequence (`Ctrl+K Ctrl+C`), each chord through
  ## `normalizeChord`; "" when any chord names no key.
  var parts: seq[string] = @[]
  for c in text.splitWhitespace():
    let n = normalizeChord(c)
    if n.len == 0: return ""
    parts.add n
  parts.join(" ")

func isPrintableKey*(name: string): bool =
  ## Whether a canonical key name is a single printable character.
  ##
  ## `Esc`, `Enter`, `Tab`, `F10` and `Ctrl+p` are all multi-character names,
  ## so this needs no second list to know they are not characters. It is NOT
  ## the whole of the text-entry shadowing rule — see `keyCharacter`.
  name.len == 1 and name[0] >= ' ' and name[0] <= '~'

func keyCharacter*(name: string): string =
  ## The CHARACTER a canonical key name inserts into a text field, or "".
  ##
  ## Not `isPrintableKey`, because of exactly one key: `Space` is a five-letter
  ## NAME (CodeTracer-TUI.md §4.2 binds it, and a table cell reading ` ` would
  ## be unreadable), and under the narrower spelling a space typed at a `:`
  ## prompt was silently lost (CTUI-10, measured on a real pty). The editing
  ## keymap's text-entry scope asks the same question of the same names, which
  ## is why this is one function in a module both keymaps import.
  if name == "Space": " "
  elif isPrintableKey(name): name
  else: ""

func isTextKey*(name: string): bool =
  ## Whether a text field owns this key — `keyCharacter` with the character
  ## thrown away, named so a resolver reads as a rule.
  keyCharacter(name).len > 0

# ---------------------------------------------------------------------------
# The terminal's bytes
# ---------------------------------------------------------------------------

type
  DecodedKey = object
    ok: bool
    mods: KeyModifiers
    key: string

func decoded(mods: KeyModifiers; key: string): DecodedKey =
  DecodedKey(ok: key.len > 0, mods: mods, key: key)

const NoKey = DecodedKey(ok: false, mods: {}, key: "")

func modifiersOfParam(param: string; ok: var bool): KeyModifiers =
  ## xterm's and the Kitty protocol's modifier parameter: `1 + bits`, with
  ## Shift 1, Alt 2, Ctrl 4, Super 8, Hyper 16, Meta 32, Caps Lock 64,
  ## Num Lock 128. Super and Meta both spell `Meta`; the two lock bits are
  ## STATE, not modifiers, and are ignored (a `Ctrl+c` typed with Num Lock on
  ## is `Ctrl+c`). Hyper names no key this product has, so a chord carrying
  ## it is not a key. A sub-parameter (`:event-type`) is ignored: only press
  ## events are requested.
  ok = true
  var p = param
  let colon = p.find(':')
  if colon >= 0: p = p[0 ..< colon]
  if p.len == 0:
    return {}
  var v = 0
  try:
    v = parseInt(p)
  except ValueError:
    ok = false
    return {}
  if v < 1:
    ok = false
    return {}
  let bits = v - 1
  if (bits and 16) != 0:
    ok = false
    return {}
  if (bits and 1) != 0: result.incl kmodShift
  if (bits and 2) != 0: result.incl kmodAlt
  if (bits and 4) != 0: result.incl kmodCtrl
  if (bits and (8 or 32)) != 0: result.incl kmodMeta

func codepointKey(code: int): string =
  ## A Unicode code point as the Kitty protocol and `modifyOtherKeys` report
  ## it → a key name. The functional keys the product names; any other code
  ## point outside printable ASCII names no key.
  case code
  of 9: "Tab"
  of 13, 57414: "Enter"     # 57414: the keypad's Enter
  of 27: "Esc"
  of 8, 127: "Backspace"
  of 32: "Space"
  of 33 .. 126: $chr(code)
  else: ""

func singleByteKey(c: char; eraseByte: char): DecodedKey =
  case c
  of '\t': decoded({}, "Tab")
  of '\r', '\n': decoded({}, "Enter")
  of ' ': decoded({}, "Space")
  of '\x1b': decoded({}, "Esc")
  of '\0': decoded({kmodCtrl}, "Space")
  of '\x1c': decoded({kmodCtrl}, "\\")
  of '\x1d': decoded({kmodCtrl}, "]")
  of '\x1f': decoded({kmodCtrl}, "/")
  of '\x7f', '\b':
    # THE TERMINAL'S ERASE BYTE IS BACKSPACE AND THE OTHER ONE IS
    # Ctrl+Backspace. xterm sends `0x7f` for Backspace and `0x08` for
    # Ctrl+Backspace; a terminal whose `VERASE` is `0x08` swaps them. Folding
    # both into Backspace lost the one byte that tells them apart.
    if c == eraseByte: decoded({}, "Backspace")
    else: decoded({kmodCtrl}, "Backspace")
  of '\x01' .. '\x07', '\x0b', '\x0c', '\x0e' .. '\x1a':
    decoded({kmodCtrl}, $chr(ord('a') + ord(c) - 1))
  of '!' .. '~':
    decoded({}, $c)
  else: NoKey

func csiKey(params: string; final: char): DecodedKey =
  ## `ESC [ <params> <final>`.
  if params.len > 0 and params[0] in {'?', '>', '<', '=', '$'}:
    # A REPLY (`CSI ? 1 u`, a DA report) or a mouse report — not a key.
    return NoKey
  let parts = params.split(';')
  var ok = true
  case final
  of 'A', 'B', 'C', 'D', 'H', 'F', 'P', 'Q', 'R', 'S', 'Z':
    # Cursor keys, Home/End, F1-F4, back-tab: plain (`CSI A`) or modified
    # (`CSI 1 ; m A`).
    let key = case final
              of 'A': "Up"
              of 'B': "Down"
              of 'C': "Right"
              of 'D': "Left"
              of 'H': "Home"
              of 'F': "End"
              of 'P': "F1"
              of 'Q': "F2"
              of 'R': "F3"
              of 'S': "F4"
              else: "Tab"
    var mods: KeyModifiers = if final == 'Z': {kmodShift} else: {}
    if params.len == 0:
      return decoded(mods, key)
    if parts.len == 2 and parts[0] == "1":
      mods = mods + modifiersOfParam(parts[1], ok)
      if ok: return decoded(mods, key)
    return NoKey
  of 'u':
    # The Kitty protocol: `CSI code[:alternates] [; mods[:event] [; text]] u`.
    var codeText = parts[0]
    let colon = codeText.find(':')
    if colon >= 0: codeText = codeText[0 ..< colon]
    var code = 0
    try:
      code = parseInt(codeText)
    except ValueError:
      return NoKey
    let mods = if parts.len >= 2: modifiersOfParam(parts[1], ok) else: {}
    if not ok: return NoKey
    return decoded(mods, codepointKey(code))
  of '~':
    var code = 0
    try:
      code = parseInt(parts[0])
    except ValueError:
      return NoKey
    if code == 27:
      # xterm's `modifyOtherKeys`: `CSI 27 ; <mods> ; <code point> ~`, for
      # every code point, not only Tab and Enter.
      if parts.len != 3: return NoKey
      let mods = modifiersOfParam(parts[1], ok)
      var cp = 0
      try:
        cp = parseInt(parts[2])
      except ValueError:
        return NoKey
      if not ok: return NoKey
      return decoded(mods, codepointKey(cp))
    let key = case code
              of 1, 7: "Home"
              of 4, 8: "End"
              of 2: "Insert"
              of 3: "Delete"
              of 5: "PageUp"
              of 6: "PageDown"
              of 11: "F1"
              of 12: "F2"
              of 13: "F3"
              of 14: "F4"
              of 15: "F5"
              of 17: "F6"
              of 18: "F7"
              of 19: "F8"
              of 20: "F9"
              of 21: "F10"
              of 23: "F11"
              of 24: "F12"
              else: ""
    if key.len == 0: return NoKey
    if parts.len == 1: return decoded({}, key)
    if parts.len == 2:
      let mods = modifiersOfParam(parts[1], ok)
      if ok: return decoded(mods, key)
    return NoKey
  else:
    return NoKey

func decodeToken(token: string; eraseByte: char): DecodedKey =
  if token.len == 0:
    return NoKey
  if token.len == 1:
    return singleByteKey(token[0], eraseByte)
  if token[0] != '\x1b':
    return NoKey
  if token.len == 2:
    # `ESC <byte>`: Alt (Meta sends an ESC prefix) on top of whatever the
    # byte alone is — `ESC a` Alt+a, `ESC A` Shift+Alt+a, `ESC 0x01`
    # Ctrl+Alt+a, `ESC 0x7f` Alt+Backspace, `ESC CR` Alt+Enter.
    # `ESC ESC` is one Esc then the start of the next key, and `ESC [` is a
    # control sequence that never finished — neither is Alt on anything.
    if token[1] in {'\x1b', '['}:
      return NoKey
    var inner = singleByteKey(token[1], eraseByte)
    if not inner.ok: return NoKey
    inner.mods.incl kmodAlt
    return inner
  if token[1] == 'O' and token.len == 3:
    # SS3: F1-F4, Home/End and the cursor keys in application mode, and the
    # keypad's Enter.
    let key = case token[2]
              of 'P': "F1"
              of 'Q': "F2"
              of 'R': "F3"
              of 'S': "F4"
              of 'H': "Home"
              of 'F': "End"
              of 'A': "Up"
              of 'B': "Down"
              of 'C': "Right"
              of 'D': "Left"
              of 'M': "Enter"
              else: ""
    return decoded({}, key)
  if token[1] != '[' or token.len < 3:
    return NoKey
  csiKey(token[2 ..< token.len - 1], token[^1])

func keyName*(token: string; eraseByte = '\x7f'): string =
  ## The canonical name of one complete input token — a byte, `ESC` plus a
  ## byte, or a whole escape sequence as `host/terminal_driver.feed` frames
  ## them — or "" for anything that is not a key (a mouse report, a reply to
  ## a query, a runaway sequence), so a caller can tell "not a key" from "a
  ## key nothing is bound to".
  ##
  ## `eraseByte` is the byte the terminal declares as Backspace (termios
  ## `VERASE`); xterm's `0x7f` unless the driver read otherwise.
  let d = decodeToken(token, eraseByte)
  if not d.ok: "" else: chordName(d.mods, d.key)
