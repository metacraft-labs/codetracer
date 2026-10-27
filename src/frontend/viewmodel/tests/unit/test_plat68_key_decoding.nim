## test_plat68_key_decoding.nim — PLAT-68 deliverable 1: the decoders and the
## one modifier order.
##
## Base-Keymaps-And-Layer-Stack.md §2 measured three decoder gaps the CUA base
## hits at once, and §8 item 2 makes "one decoder per device, one canonical
## spelling" a rule. This suite is both, asserted:
##
##   * every xterm spelling of `Home` / `End`, plain and modified
##     (`issues/2026-10-10-tui-key-decoder-drops-home-and-end.md`);
##   * `Ctrl+Backspace` apart from `Backspace`, decided by the terminal's erase
##     byte (`…-reads-ctrl-backspace-as-backspace.md`);
##   * `Ctrl+]`, `Ctrl+\`, `Ctrl+/`, `Ctrl+Space`, and `Ctrl+Alt+<letter>`;
##   * the Kitty protocol's `CSI u` and xterm's `modifyOtherKeys` for EVERY
##     printable code point, not only `Tab` / `Enter`;
##   * one modifier order — Ctrl, Shift, Alt, Meta — produced by
##     `key_names.chordName` and reached from every spelling a user may write
##     (`…-key-names-modifier-order-is-two-rules.md`);
##   * the desktop's `KeyboardEvent` decoder (`key_event_names`) naming the same
##     chords the terminal's bytes name.
##
## ## THE WITNESS IS THREE ENCODINGS OF ONE KEY, NOT A TABLE RE-DERIVED HERE
##
## Spelling the expected name for every code point in this file would be the
## decoder written twice (Verification-Harness-Traps §30a). So the sweeps assert
## AGREEMENT: the legacy bytes, the Kitty `CSI u` form and the
## `modifyOtherKeys` form of one key must decode to one name, and that name
## must be `chordName` of the modifiers the sweep put in. The literal
## expectations are reserved for the issues' own byte sequences, which are
## facts about terminals rather than about this decoder.
##
## ## No mocks
## Pure functions over strings; nothing is substituted.

import std/[algorithm, strutils, unittest]

import ../../../../common/key_names
import ../../../../common/key_event_names

const ExpectedAssertions = 1702

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc xtermModParam(mods: KeyModifiers): int =
  ## xterm's and Kitty's modifier parameter for a set: `1 + bits`.
  result = 1
  if kmodShift in mods: result += 1
  if kmodAlt in mods: result += 2
  if kmodCtrl in mods: result += 4
  if kmodMeta in mods: result += 8

proc allModifierSets(): seq[KeyModifiers] =
  for bits in 0 ..< 16:
    var s: KeyModifiers = {}
    if (bits and 1) != 0: s.incl kmodCtrl
    if (bits and 2) != 0: s.incl kmodShift
    if (bits and 4) != 0: s.incl kmodAlt
    if (bits and 8) != 0: s.incl kmodMeta
    result.add s

suite "PLAT-68: Home and End in every xterm spelling":
  test "the issue's own byte sequences":
    # `issues/2026-10-10-tui-key-decoder-drops-home-and-end.md`'s evidence,
    # each of which answered "" before.
    for (bytes, want) in [("\e[H", "Home"), ("\e[F", "End"), ("\eOH", "Home"),
                          ("\eOF", "End"), ("\e[1~", "Home"), ("\e[4~", "End"),
                          ("\e[7~", "Home"), ("\e[8~", "End"),
                          ("\e[1;5H", "Ctrl+Home")]:
      checkpoint(bytes.escape & " -> " & keyName(bytes))
      ck keyName(bytes) == want

  test "every modified form, in all three spellings":
    var n = 0
    for mods in allModifierSets():
      if mods == {}: continue
      let p = $xtermModParam(mods)
      for (key, final, tilde) in [("Home", 'H', "1"), ("End", 'F', "4")]:
        let want = chordName(mods, key)
        ck keyName("\e[1;" & p & final) == want
        ck keyName("\e[" & tilde & ";" & p & "~") == want
        inc n
    ck n == 30

suite "PLAT-68: Backspace and Ctrl+Backspace":
  test "xterm: 0x7f is Backspace and 0x08 is Ctrl+Backspace":
    ck keyName("\x7f") == "Backspace"
    ck keyName("\b") == "Ctrl+Backspace"
  test "a terminal whose erase byte is 0x08 swaps them":
    ck keyName("\b", '\b') == "Backspace"
    ck keyName("\x7f", '\b') == "Ctrl+Backspace"
  test "under the Kitty protocol the two arrive as two keys":
    ck keyName("\e[127u") == "Backspace"
    ck keyName("\e[127;5u") == "Ctrl+Backspace"
    ck keyName("\e[127;3u") == "Alt+Backspace"
  test "Alt+Backspace and Ctrl+Alt+Backspace from the ESC prefix":
    ck keyName("\e\x7f") == "Alt+Backspace"
    ck keyName("\e\b") == "Ctrl+Alt+Backspace"

suite "PLAT-68: the C0 bytes that are not letters, and Ctrl+Alt":
  test "Ctrl+], Ctrl+\\, Ctrl+/ and Ctrl+Space":
    ck keyName("\x1d") == "Ctrl+]"
    ck keyName("\x1c") == "Ctrl+\\"
    ck keyName("\x1f") == "Ctrl+/"
    ck keyName("\x00") == "Ctrl+Space"
  test "Ctrl+Alt+<letter> is ESC + the control byte":
    var n = 0
    for c in 'a' .. 'z':
      let bytes = "\e" & $char(ord(c) - ord('a') + 1)
      let want = case c
                 of 'h': "Ctrl+Alt+Backspace"
                 of 'i': "Alt+Tab"
                 of 'j', 'm': "Alt+Enter"
                 else: "Ctrl+Alt+" & $c
      checkpoint(bytes.escape & " -> " & keyName(bytes) & " want " & want)
      ck keyName(bytes) == want
      inc n
    ck n == 26

suite "PLAT-68: three encodings of one key decode to one name":
  test "every letter with Ctrl: legacy byte = Kitty = modifyOtherKeys":
    var n = 0
    for c in 'a' .. 'z':
      if c in {'h', 'i', 'j', 'm'}: continue   # named keys' bytes, above
      let legacy = keyName($char(ord(c) - ord('a') + 1))
      let kitty = keyName("\e[" & $ord(c) & ";5u")
      let mok = keyName("\e[27;5;" & $ord(c) & "~")
      ck legacy == "Ctrl+" & $c
      ck kitty == legacy
      ck mok == legacy
      inc n
    ck n == 22

  test "every printable code point under every modifier set: Kitty = modifyOtherKeys = chordName":
    var n = 0
    for code in 33 .. 126:
      for mods in allModifierSets():
        if mods * {kmodCtrl, kmodAlt, kmodMeta} == {}: continue
        let p = $xtermModParam(mods)
        let kitty = keyName("\e[" & $code & ";" & p & "u")
        let mok = keyName("\e[27;" & p & ";" & $code & "~")
        let agree = kitty == mok and kitty == chordName(mods, $chr(code))
        if not agree:
          checkpoint("code " & $code & " mods " & $mods & ": kitty '" & kitty &
                     "' mok '" & mok & "'")
        ck agree
        inc n
    ck n == 94 * 14

  test "Ctrl+Shift+K arrives as itself, never as Ctrl+K":
    ck keyName("\e[107;6u") == "Ctrl+Shift+k"
    ck keyName("\e[27;6;75~") == "Ctrl+Shift+k"
    ck keyName("\v") == "Ctrl+k"
    ck keyName("\e[107;6u") != keyName("\v")

  test "the keys the classic encoding cannot send":
    ck keyName("\e[13;2u") == "Shift+Enter"
    ck keyName("\e[13;5u") == "Ctrl+Enter"
    ck keyName("\e[13;6u") == "Ctrl+Shift+Enter"
    ck keyName("\e[27u") == "Esc"
    ck keyName("\e[91;5u") == "Ctrl+["
    ck keyName("\e[47;6u") == "Ctrl+Shift+/"
    ck keyName("\e[9;5u") == "Ctrl+Tab"
    ck keyName("\e[27;5;9~") == "Ctrl+Tab"

  test "lock state is not a modifier, and Hyper names no key":
    ck keyName("\e[99;69u") == "Ctrl+c"       # 5 + Caps Lock (64)
    ck keyName("\e[99;133u") == "Ctrl+c"      # 5 + Num Lock (128)
    ck keyName("\e[99;17u") == ""             # Hyper
    ck keyName("\e[99;5:1u") == "Ctrl+c"      # an event-type sub-parameter

  test "a terminal's REPLY is not a key":
    for reply in ["\e[?1u", "\e[?0u", "\e[?31u", "\e[?64;1;2c",
                  "\e[<0;10;5M"]:
      ck keyName(reply) == ""

suite "PLAT-68: one modifier order, through one function":
  test "chordName spells every subset in the order Ctrl, Shift, Alt, Meta":
    for mods in allModifierSets():
      let name = chordName(mods, "Up")
      let parts = name.split('+')
      ck parts[^1] == "Up"
      var order: seq[int] = @[]
      for p in parts[0 ..< parts.len - 1]:
        for m in KeyModifier:
          if $m == p: order.add ord(m)
      ck order.len == parts.len - 1
      ck order == order.sorted()
  test "every written spelling of one chord normalises to the one name":
    # The issue's case: `Ctrl+Shift+Alt+Up` and `Ctrl+Alt+Shift+Up` must mean
    # one chord. Every permutation of the three, in two cases.
    let want = chordName({kmodCtrl, kmodShift, kmodAlt}, "Up")
    ck want == "Ctrl+Shift+Alt+Up"
    for spelled in ["Ctrl+Shift+Alt+Up", "Ctrl+Alt+Shift+Up",
                    "Shift+Ctrl+Alt+Up", "Shift+Alt+Ctrl+Up",
                    "Alt+Ctrl+Shift+Up", "Alt+Shift+Ctrl+Up",
                    "ctrl+alt+shift+up", "ALT+SHIFT+CTRL+UP"]:
      ck normalizeChord(spelled) == want
    ck keyName("\e[1;8A") == want
  test "a written letter is a KEY and Shift is written (VS Code's notation)":
    ck normalizeChord("Ctrl+K") == "Ctrl+k"
    ck normalizeChord("Ctrl+Shift+K") == "Ctrl+Shift+k"
    ck normalizeChord("Shift+Alt+A") == "Shift+Alt+a"
    ck normalizeChord("Shift+O") == "O"
    ck normalizeChord("J") == "j"
    ck normalizeChordSequence("Ctrl+K Ctrl+C") == "Ctrl+k Ctrl+c"
    ck normalizeChordSequence("Ctrl+K S") == "Ctrl+k s"
    ck normalizeChord("Escape") == "Esc"
    ck normalizeChord("Ctrl+Shift+[") == "Ctrl+Shift+["
    ck normalizeChord("Ctrl+{") == "Ctrl+Shift+["
    ck normalizeChord("Hyper+K") == ""
    ck normalizeChord("Ctrl+Nonsense") == ""
  test "the legacy ESC prefix and the written chord agree on Alt + a shifted letter":
    ck keyName("\eA") == "Shift+Alt+a"
    ck keyName("\eA") == normalizeChord("Shift+Alt+A")
    ck keyName("\ea") == "Alt+a"

suite "PLAT-68: the desktop's KeyboardEvent decoder names the same chords":
  test "a sweep of keystrokes against their Kitty bytes":
    var n = 0
    for c in 'a' .. 'z':
      let code = "Key" & $chr(ord(c) - 32)
      ck canonicalKeyOfDom($c, code, true, false, false, false) ==
         keyName("\e[" & $ord(c) & ";5u")
      ck canonicalKeyOfDom($chr(ord(c) - 32), code, true, true, false, false) ==
         keyName("\e[" & $ord(c) & ";6u")
      ck canonicalKeyOfDom($c, code, false, false, false, false) == $c
      ck canonicalKeyOfDom($chr(ord(c) - 32), code, false, true, false, false) ==
         $chr(ord(c) - 32)
      inc n
    ck n == 26
  test "named keys, symbols and the layout's own characters":
    ck canonicalKeyOfDom("Home", "Home", false, true, false, false) == "Shift+Home"
    ck canonicalKeyOfDom("Backspace", "Backspace", true, false, false, false) ==
       "Ctrl+Backspace"
    ck canonicalKeyOfDom("Enter", "Enter", true, true, false, false) ==
       "Ctrl+Shift+Enter"
    ck canonicalKeyOfDom("F10", "F10", false, true, false, false) == "Shift+F10"
    ck canonicalKeyOfDom("{", "BracketLeft", true, true, false, false) ==
       "Ctrl+Shift+["
    ck canonicalKeyOfDom("?", "Slash", false, true, false, false) == "?"
    ck canonicalKeyOfDom(" ", "Space", false, false, false, false) == "Space"
    ck canonicalKeyOfDom("é", "KeyE", false, false, false, false) == ""
    ck canonicalKeyOfDom("Shift", "ShiftLeft", false, true, false, false) == ""

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
