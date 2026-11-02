## key_event_names.nim — the desktop's decoder: a DOM `KeyboardEvent` → this
## product's canonical key name.
##
## Base-Keymaps-And-Layer-Stack.md §8 item 2: *one key decoder per device, one
## canonical spelling*. The terminal's bytes are `key_names.keyName`, GPUI's
## keystrokes `gpui/app/gpui_keys.canonicalKeyOfGpui`, and a `KeyboardEvent` is
## this. All three end in `key_names.chordName`, so a chord is one string
## whichever device produced it.
##
## Takes the event's FIELDS rather than the event, so it is pure and compiles
## on C, JS and wasm32 like `key_names`: a caller on the desktop passes
## `ev.key`, `ev.code` and the four modifier flags.
##
## ## `key` OR `code`
##
## With no command modifier the layout's character is the key (`ev.key`: `?`
## on a US layout, `é` elsewhere — the latter names no key here and yields "").
## With Ctrl, Alt or Meta held, `ev.key` is unreliable — macOS's Option turns
## `e` into `´`, and Ctrl+Shift+2 is `@` on one layout and `"` on another — so
## the PHYSICAL key (`ev.code`: `KeyE`, `Digit2`, `BracketLeft`) is read, which
## is also what VS Code's keybinding dispatcher reads for its default chords.

import std/[strutils, tables]

import ./key_names

const
  DomNamedKeys = {
    "Escape": "Esc", "Enter": "Enter", "NumpadEnter": "Enter", "Tab": "Tab",
    "Backspace": "Backspace", "Delete": "Delete", "Insert": "Insert",
    "Space": "Space", "Home": "Home", "End": "End", "PageUp": "PageUp",
    "PageDown": "PageDown", "ArrowUp": "Up", "ArrowDown": "Down",
    "ArrowLeft": "Left", "ArrowRight": "Right"}.toTable
    ## `KeyboardEvent.code` values of the non-character keys this product
    ## names (F1–F12 are spelled the same in both vocabularies).

  DomCodeCharacters = {
    "Minus": '-', "Equal": '=', "BracketLeft": '[', "BracketRight": ']',
    "Backslash": '\\', "Semicolon": ';', "Quote": '\'', "Comma": ',',
    "Period": '.', "Slash": '/', "Backquote": '`'}.toTable

func keyOfDomCode(code: string): string =
  if DomNamedKeys.hasKey(code): return DomNamedKeys[code]
  if code.len == 4 and code.startsWith("Key") and code[3] in 'A'..'Z':
    return $chr(ord(code[3]) + 32)
  if code.len == 6 and code.startsWith("Digit") and code[5] in '0'..'9':
    return $code[5]
  if DomCodeCharacters.hasKey(code): return $DomCodeCharacters[code]
  if code.len >= 2 and code[0] == 'F':
    try:
      let n = parseInt(code[1 .. ^1])
      if n >= 1 and n <= 12: return code
    except ValueError:
      discard
  ""

func canonicalKeyOfDom*(key, code: string;
                        ctrl, shift, alt, meta: bool): string =
  ## The canonical name of one `keydown`, or "" when it names no key (a
  ## modifier pressed alone, a dead key, a character outside printable
  ## ASCII).
  var mods: KeyModifiers = {}
  if ctrl: mods.incl kmodCtrl
  if shift: mods.incl kmodShift
  if alt: mods.incl kmodAlt
  if meta: mods.incl kmodMeta
  let fromCode = keyOfDomCode(code)
  if (mods * {kmodCtrl, kmodAlt, kmodMeta}) != {}:
    return chordName(mods, fromCode)
  if DomNamedKeys.hasKey(code) or (fromCode.len > 1):
    return chordName(mods, fromCode)
  if key.len == 1 and key[0] >= ' ' and key[0] <= '~':
    # The layout's character, which already carries Shift.
    return chordName(mods - {kmodShift}, key)
  ""
