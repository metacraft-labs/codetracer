## key_devices.nim — the DIFF-13 suite's KEY SYNTHESISER: one canonical key
## name (`Ctrl+Shift+k`, `G`, `F10`) spelled in each front-end's own DEVICE
## form, so each front-end's own decoder can turn it back into a name.
##
##   * the terminal: the BYTES a terminal sends on the negotiated protocol —
##     the Kitty keyboard protocol's flag 1 (`CSI <code> ; <mods> u` for a
##     modified character, xterm's cursor / function-key sequences otherwise)
##     or the classic xterm encoding (`kpLegacy`);
##   * GPUI: a keystroke as GPUI's platform layer delivers it — `keystroke.key`
##     (`"escape"`, `"up"`, the unshifted character) and its modifier list
##     (`control`, `shift`, `alt`, `platform`);
##   * the desktop: a DOM `KeyboardEvent`'s `key`, `code` and four modifier
##     flags on a US layout.
##
## This is the suite's DRIVER, not shipped code: it plays the part of the
## keyboard and the platform. Every form it produces is checked against the
## decoder that receives it (`roundTrips`) — Verification-Harness-Traps §25:
## a synthesiser that drops a modifier would turn the differential into a
## test about a different key. A name a device has no form for is answered
## with "" and COUNTED by the suite as inexpressible on that front-end.
##
## Pure; no I/O.

import std/[strutils, tables]

import ../../../../common/key_names

type
  SplitKey* = tuple[mods: KeyModifiers, key: string]
    ## A canonical name taken apart: the modifiers, and the KEY — a
    ## `NamedKeys` member or one unshifted printable character (`k`, `[`).

  DomKey* = object
    ## The fields of one `keydown` the desktop's decoder reads.
    key*, code*: string
    ctrl*, shift*, alt*, meta*: bool

  GpuiKeystroke* = object
    key*: string
    mods*: seq[string]

const
  ShiftedOfUs = {'`': '~', '1': '!', '2': '@', '3': '#', '4': '$', '5': '%',
                 '6': '^', '7': '&', '8': '*', '9': '(', '0': ')', '-': '_',
                 '=': '+', '[': '{', ']': '}', '\\': '|', ';': ':',
                 '\'': '"', ',': '<', '.': '>', '/': '?'}.toTable

func unshifted(c: char): char =
  if c in 'A'..'Z': return chr(ord(c) + 32)
  for k, v in ShiftedOfUs:
    if v == c: return k
  '\0'

func shifted(c: char): char =
  if c in 'a'..'z': chr(ord(c) - 32)
  elif ShiftedOfUs.hasKey(c): ShiftedOfUs[c]
  else: '\0'

func splitCanonical*(name: string): SplitKey =
  ## `Ctrl+Shift+k` → ({Ctrl, Shift}, "k"); `G` → ({Shift}, "g"); `{` →
  ## ({Shift}, "["); `Space` → ({}, "Space"). A literal `+` key is the last
  ## field (`Ctrl++`).
  var parts: seq[string] = @[]
  var cur = ""
  for ch in name:
    if ch == '+' and cur.len > 0:
      parts.add cur
      cur = ""
    else:
      cur.add ch
  parts.add cur
  for i in 0 ..< parts.len - 1:
    case parts[i]
    of "Ctrl": result.mods.incl kmodCtrl
    of "Shift": result.mods.incl kmodShift
    of "Alt": result.mods.incl kmodAlt
    of "Meta": result.mods.incl kmodMeta
    else: return (mods: {}, key: "")
  let k = parts[^1]
  if k.len == 1:
    let un = unshifted(k[0])
    if un != '\0':
      result.mods.incl kmodShift
      result.key = $un
    else:
      result.key = k
  else:
    result.key = k

func modParam(mods: KeyModifiers): int =
  ## xterm's / Kitty's modifier parameter, `1 + bits`.
  result = 1
  if kmodShift in mods: result += 1
  if kmodAlt in mods: result += 2
  if kmodCtrl in mods: result += 4
  if kmodMeta in mods: result += 8

const
  CsiLetter = {"Up": 'A', "Down": 'B', "Right": 'C', "Left": 'D',
               "Home": 'H', "End": 'F'}.toTable
  Ss3Letter = {"F1": 'P', "F2": 'Q', "F3": 'R', "F4": 'S'}.toTable
  TildeCode = {"Insert": 2, "Delete": 3, "PageUp": 5, "PageDown": 6,
               "F5": 15, "F6": 17, "F7": 18, "F8": 19, "F9": 20, "F10": 21,
               "F11": 23, "F12": 24}.toTable
  CodepointOf = {"Enter": 13, "Tab": 9, "Esc": 27, "Backspace": 127,
                 "Space": 32}.toTable

func functionKeyBytes(sk: SplitKey): string =
  ## The cursor and function keys, which both protocols send in xterm's form.
  let m = modParam(sk.mods)
  if CsiLetter.hasKey(sk.key):
    return (if m == 1: "\e[" & $CsiLetter[sk.key]
            else: "\e[1;" & $m & $CsiLetter[sk.key])
  if Ss3Letter.hasKey(sk.key):
    return (if m == 1: "\eO" & $Ss3Letter[sk.key]
            else: "\e[1;" & $m & $Ss3Letter[sk.key])
  if TildeCode.hasKey(sk.key):
    return (if m == 1: "\e[" & $TildeCode[sk.key] & "~"
            else: "\e[" & $TildeCode[sk.key] & ";" & $m & "~")
  ""

func kittyBytes*(name: string): string =
  ## The bytes a terminal speaking the Kitty keyboard protocol with flag 1
  ## ("disambiguate escape codes") sends for `name`, or "".
  let sk = splitCanonical(name)
  if sk.key.len == 0 or sk.key == "Alt": return ""
  let f = functionKeyBytes(sk)
  if f.len > 0: return f
  let command = (sk.mods * {kmodCtrl, kmodAlt, kmodMeta}) != {}
  if CodepointOf.hasKey(sk.key):
    let code = CodepointOf[sk.key]
    if sk.mods == {}:
      # Flag 1 keeps Enter, Tab and Backspace as their bytes; Esc becomes
      # `CSI 27 u` — the disambiguation the flag exists for.
      return (case sk.key
              of "Enter": "\r"
              of "Tab": "\t"
              of "Backspace": "\x7f"
              of "Space": " "
              else: "\e[27u")
    return "\e[" & $code & ";" & $modParam(sk.mods) & "u"
  if sk.key.len != 1: return ""
  if not command:
    # A text key: its text, shifted by Shift.
    if kmodShift in sk.mods:
      let s = shifted(sk.key[0])
      return (if s == '\0': "" else: $s)
    return sk.key
  "\e[" & $ord(sk.key[0]) & ";" & $modParam(sk.mods) & "u"

func legacyCandidates(): seq[string] =
  ## The classic encoding's tokens (key_names' own enumeration, restated:
  ## that one is private to the decoder it describes).
  for b in 0 .. 127:
    result.add $chr(b)
    result.add "\e" & $chr(b)
  for f in "PQRSHFABCDM":
    result.add "\eO" & $f
  var mods = @[""]
  for m in 2 .. 16: mods.add "1;" & $m
  for f in "ABCDHFPQRSZ":
    for m in mods: result.add "\e[" & m & $f
  for code in [1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 17, 18, 19, 20,
               21, 23, 24]:
    result.add "\e[" & $code & "~"
    for m in 2 .. 16: result.add "\e[" & $code & ";" & $m & "~"

let legacyIndex = block:
  var t = initTable[string, string]()
  for tok in legacyCandidates():
    let n = keyName(tok, '\x7f')
    if n.len > 0 and n notin t:
      # `ESC <byte>` is held by the framer as a lone ESC first; prefer a
      # token that is not a bare ESC prefix when there is a choice.
      t[n] = tok
  t

proc legacyBytes*(name: string): string =
  ## The bytes a terminal WITHOUT extended key reporting sends for `name`,
  ## or "" when it has none (§7.4).
  legacyIndex.getOrDefault(name, "")

const
  GpuiOfNamed = {"Esc": "escape", "Enter": "enter", "Backspace": "backspace",
                 "Tab": "tab", "Space": "space", "Delete": "delete",
                 "Home": "home", "End": "end", "PageUp": "pageup",
                 "PageDown": "pagedown", "Insert": "insert", "Up": "up",
                 "Down": "down", "Left": "left", "Right": "right"}.toTable

func gpuiKeystroke*(name: string): GpuiKeystroke =
  ## GPUI's keystroke for `name`: the key as `keystroke.key` spells it and
  ## the modifier list. `key` is "" when GPUI delivers no keystroke for it
  ## (`Alt` alone is a modifier change, not a keystroke).
  let sk = splitCanonical(name)
  if sk.key.len == 0 or sk.key == "Alt": return
  if kmodCtrl in sk.mods: result.mods.add "control"
  if kmodShift in sk.mods: result.mods.add "shift"
  if kmodAlt in sk.mods: result.mods.add "alt"
  if kmodMeta in sk.mods: result.mods.add "platform"
  if GpuiOfNamed.hasKey(sk.key): result.key = GpuiOfNamed[sk.key]
  elif sk.key.len >= 2 and sk.key[0] == 'F': result.key = sk.key.toLowerAscii
  else: result.key = sk.key

const
  DomOfNamed = {"Esc": ("Escape", "Escape"), "Enter": ("Enter", "Enter"),
                "Tab": ("Tab", "Tab"), "Backspace": ("Backspace", "Backspace"),
                "Delete": ("Delete", "Delete"), "Insert": ("Insert", "Insert"),
                "Space": (" ", "Space"), "Home": ("Home", "Home"),
                "End": ("End", "End"), "PageUp": ("PageUp", "PageUp"),
                "PageDown": ("PageDown", "PageDown"), "Up": ("ArrowUp", "ArrowUp"),
                "Down": ("ArrowDown", "ArrowDown"),
                "Left": ("ArrowLeft", "ArrowLeft"),
                "Right": ("ArrowRight", "ArrowRight")}.toTable
  DomCodeOfSymbol = {'-': "Minus", '=': "Equal", '[': "BracketLeft",
                     ']': "BracketRight", '\\': "Backslash", ';': "Semicolon",
                     '\'': "Quote", ',': "Comma", '.': "Period", '/': "Slash",
                     '`': "Backquote"}.toTable

func domKey*(name: string): DomKey =
  ## The `keydown` a US-layout keyboard produces for `name`; `code` is ""
  ## when there is none (`Alt` alone is a modifier's own keydown, which the
  ## desktop reads as the start of a tap, not as a key).
  let sk = splitCanonical(name)
  if sk.key.len == 0 or sk.key == "Alt": return
  result.ctrl = kmodCtrl in sk.mods
  result.shift = kmodShift in sk.mods
  result.alt = kmodAlt in sk.mods
  result.meta = kmodMeta in sk.mods
  if DomOfNamed.hasKey(sk.key):
    (result.key, result.code) = DomOfNamed[sk.key]
  elif sk.key.len >= 2 and sk.key[0] == 'F':
    result.key = sk.key
    result.code = sk.key
  elif sk.key.len == 1:
    let c = sk.key[0]
    result.code =
      if c in 'a'..'z': "Key" & $chr(ord(c) - 32)
      elif c in '0'..'9': "Digit" & $c
      elif DomCodeOfSymbol.hasKey(c): DomCodeOfSymbol[c]
      else: ""
    result.key = (if result.shift and shifted(c) != '\0': $shifted(c) else: $c)
