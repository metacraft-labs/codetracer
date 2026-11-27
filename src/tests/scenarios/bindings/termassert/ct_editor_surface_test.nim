## What the editor bindings read off a screen (`ct_editor_surface`) and how
## they spell an editor's keys and commands (`ct_editor_binding`), over
## screens as Neovim with codetracer.nvim and Emacs with codetracer.el draw
## them (rows copied from real runs over the `calc` recording), with the
## window layout each editor reports for them.
##
## No mocks: the readers are pure functions of a screen and a layout; the
## screens are the editors' own, typed in as cells.

import std/[json, sequtils, strutils, unittest]
from std/unicode import runes, runeLen, `$`
import demo_video_script/surface
import ./ct_tui_screen
import ./ct_editor_surface
import ./ct_editor_binding

proc screen(rows: openArray[string]; width: int): ScreenGrid =
  result = ScreenGrid(width: width, height: rows.len)
  for r in rows:
    var row: seq[GridCell]
    for ch in r.runes: row.add GridCell(text: $ch, bg: "d", fg: "d")
    while row.len < width: row.add GridCell(text: " ", bg: "d", fg: "d")
    result.rows.add row[0 ..< width]

proc pad(s: string; n: int): string =
  ## `s` padded with blanks to `n` cells.
  s & spaces(max(0, n - s.runeLen))

proc beside(left, right: string; leftWidth: int; divider: string): string =
  ## A row of two side-by-side windows: `left` in `leftWidth` cells, the
  ## divider, then `right`.
  pad(left, leftWidth) & divider & right

proc find(t: Tree; role: string): seq[SurfaceNode] =
  proc walk(n: SurfaceNode; acc: var seq[SurfaceNode]) =
    if n.role == role: acc.add n
    for k in t.kids(n): walk(k, acc)
  walk(t.root, result)

# Neovim: a tab line with the controls, the source window (sign column of
# two, number column of four with its blank: textoff 6) and an event log pane.
let NvimRows = @[
  pad(" [No Name]  main.py", 54) & "↶  ↷  ⇣  ↓  ⇡  ↑  ⏴  ⏵  ⏮  ■",
  beside("    1 #!/usr/bin/env python3", "    tick    # kind output", 40, "│"),
  beside("    2 \"\"\"calc — the small, fast, det", "      38    0 out  2 + 3 = 5", 40, "│"),
  beside("        ure.", "      68    1 out  10 - 4 + 1 = 7", 40, "│"),
  beside("▶  29 def add(left, right):", "      88    2 out  6 * 7 = 42", 40, "│"),
  beside("   30     return left + right", "     170    5 out  checksum = 73", 40, "│"),
  beside("main.py", "ct://1/eventLog", 41, "")]

const NvimLayout = """{"mode": "debug", "sessions": 1, "windows": [
  {"buf": "/w/test-programs/calc/main.py", "file": "/w/test-programs/calc/main.py",
   "row": 1, "col": 0, "width": 40, "height": 5, "textoff": 6, "topline": 1, "botline": 30,
   "cursor": 29, "editor": true, "selected": true},
  {"buf": "ct://1/eventLog", "file": "", "row": 1, "col": 41, "width": 40, "height": 5,
   "textoff": 0, "topline": 1, "botline": 6, "cursor": 1, "editor": false, "selected": false}]}"""

# Emacs: a menu bar, the tab bar with the controls, the source window with
# the execution mark in its one-column margin and line numbers (textoff
# 1 + 4), and the call trace pane.
let EmacsRows = @[
  "File Edit Options Buffers Tools Python Help",
  pad("|CodeTracer 1: calc-x| +", 43) & "↶  ↷  ⇣  ↓  ⇡  ↑  ⏴  ⏵  ⏮  ■",
  beside("   38 def mul(left, right):", " ▾ <toplevel> #0() => 0", 38, "| "),
  beside("   39     \"\"\"Integer multiplication.\"\"\"", " ▾ main #2() => @[5, 7, 42, 17, 2]", 38, "| "),
  beside("▶  41     return left * right", "   · mul #13(left=6, right=7) => 42", 38, "| "),
  beside("-UUU:---  F1  main.py", "-UUU:%*-D  F1  ct://1/calltrace", 40, "")]

const EmacsLayout = """{"mode": "debug", "sessions": 2, "windows": [
  {"buf": "main.py", "file": "/w/test-programs/calc/main.py",
   "row": 2, "col": 0, "width": 38, "height": 3, "textoff": 5, "topline": 38,
   "cursor": 41, "editor": true, "selected": false},
  {"buf": "ct://1/calltrace", "file": "", "row": 2, "col": 40, "width": 40, "height": 3,
   "textoff": 0, "topline": 1, "cursor": 1, "editor": false, "selected": true}]}"""

suite "the editor surface":
  test "Neovim: the source window's lines, the execution sign, the event log, the controls":
    let t = readEditorSurface(screen(NvimRows, 84), parseJson(NvimLayout), [0])
    let ed = t.find("editor")
    check ed.len == 1
    check ed[0].props["file"].getStr == "main.py"
    check ed[0].props["current-line"].getInt == 29
    check ed[0].props["caret-line"].getInt == 29
    check ed[0].props["first-visible"].getInt == 1
    check ed[0].props["last-visible"].getInt == 30
    var numbers: seq[int]
    for l in t.kids(ed[0]): numbers.add l.props["number"].getInt
    # the wrapped row of line 2 is no line of its own
    check numbers == @[1, 2, 29, 30]
    check t.kids(ed[0])[2].props["text"].getStr == "def add(left, right):"
    check t.kids(ed[0])[2].props["current"].getBool
    check t.hasExecutionLine
    let events = t.find("event")
    check events.len == 4
    check events[2].props["text"].getStr == "6 * 7 = 42"
    let buttons = t.find("toolbar-button")
    check buttons.len == 10
    check buttons[1].props["label"].getStr == "Next"
    check int(buttons[1].x) == 57 and int(buttons[1].y) == 0
    check t.find("session-strip")[0].props["count"].getInt == 1

  test "Emacs: the margin's execution mark, the call trace, the tab bar's controls":
    let t = readEditorSurface(screen(EmacsRows, 80), parseJson(EmacsLayout), [1, 0])
    let ed = t.find("editor")
    check ed[0].props["current-line"].getInt == 41
    check ed[0].props["caret-line"].getInt == 41
    check not ed[0].props["focused"].getBool
    let calls = t.find("call")
    var names: seq[string]
    for c in calls: names.add c.props["name"].getStr
    check names == @["<toplevel>", "main", "mul"]
    check calls[2].props["arguments"].getStr.contains("left=6, right=7")
    check t.find("toolbar-button")[0].props["label"].getStr == "Reverse next"
    check int(t.find("toolbar-button")[0].y) == 1
    check t.find("session-strip")[0].props["count"].getInt == 2

  test "the controls drawn as words (the plugins' text tier)":
    var rows = @NvimRows
    rows[0] = pad(" [No Name]  main.py", 20) & "Rev next  Next  Rev in  In  Rev out  Out  Rev cont  Continue  Entry  Stop"
    let t = readEditorSurface(screen(rows, 100), parseJson(NvimLayout), [0])
    let buttons = t.find("toolbar-button")
    var labels: seq[string]
    for b in buttons: labels.add b.props["label"].getStr
    check labels == @["Reverse next", "Next", "Reverse step in", "Step in", "Reverse step out",
                      "Step out", "Reverse continue", "Continue", "Run to entry", "Stop"]
    # "Next" is the word after "Rev next", not the "next" inside it
    check int(buttons[1].x) == 30 and int(buttons[1].w) == 4
    check int(buttons[0].x) == 20 and int(buttons[0].w) == 8

  test "a test's ▶ sign is not the execution line; the highlighted line is":
    var rows = @NvimRows
    rows[2] = beside("▶   2 \"\"\"calc — the small, fast, det", "      38    0 out  2 + 3 = 5", 40, "│")
    var g = screen(rows, 84)
    for c in 0 ..< 40: g.rows[4][c].bg = "#40,40,60"     # line 29: CodeTracerExecutionLine
    let t = readEditorSurface(g, parseJson(NvimLayout), [0])
    check t.find("editor")[0].props["current-line"].getInt == 29
    # without the highlight two ▶ say nothing about which is the stop
    let u = readEditorSurface(screen(rows, 84), parseJson(NvimLayout), [0])
    check u.find("editor")[0].props["current-line"].getInt == 0

  test "with no window named the source, the largest window showing a file is":
    let layout = parseJson(NvimLayout)
    layout["windows"][0]["editor"] = %false
    let t = readEditorSurface(screen(NvimRows, 84), layout, [0])
    check t.find("editor").len == 1
    check t.find("editor")[0].props["file"].getStr == "main.py"

  test "no execution line before the replay stops anywhere":
    var rows = @NvimRows
    rows[4] = beside("   29 def add(left, right):", "      88    2 out  6 * 7 = 42", 40, "│")
    let t = readEditorSurface(screen(rows, 84), parseJson(NvimLayout), [0])
    check not t.hasExecutionLine
    check t.find("editor")[0].props["current-line"].getInt == 0

  test "a pane without a role of its own is a pane of rows, titled by the pane":
    let layout = parseJson(NvimLayout)
    layout["windows"][1]["buf"] = %"ct://1/lowLevelCode"
    let t = readEditorSurface(screen(NvimRows, 84), layout, [0])
    let panes = t.find("pane")
    check panes.len == 1
    check panes[0].props["title"].getStr == "lowLevelCode"
    check panes[0].keys == @[("title", "lowLevelCode")]
    check "88    2 out  6 * 7 = 42" in panes[0].props["text"].getElems[3].getStr

  test "the pane of a buffer name":
    check paneOf("ct://3/calltrace") == (3, "calltrace")
    check paneOf("/home/u/main.py") == (0, "")
    check paneOf("ct://x/calltrace") == (0, "")

suite "the editors' keys and commands":
  test "Neovim's and Emacs's spellings of a key, as chords":
    check chordOf(ekNeovim, "<F10>") == "F10"
    check chordOf(ekNeovim, "<S-F10>") == "Shift+F10"
    check chordOf(ekNeovim, "<C-S-F11>") == "Ctrl+Shift+F11"
    check chordOf(ekEmacs, "<f10>") == "F10"
    check chordOf(ekEmacs, "S-<f10>") == "Shift+F10"
    check chordOf(ekEmacs, "C-<f5>") == "Ctrl+F5"
    check chordOf(ekEmacs, "C-c C-n") == ""     # a sequence is no chord
    check chordOf(ekNeovim, "") == ""

  test "an operation with no key is the plugin's command, typed":
    check commandChords(ekNeovim, "view.generated-c-source", "") ==
      ": C o d e T r a c e r Space g e n e r a t e d - c Enter"
    check commandChords(ekNeovim, "debugger.step-over", "").startsWith(": C o d e T r a c e r Space d e b u g")
    check commandChords(ekEmacs, "tests.record-at", "codetracer-tests-record-at") ==
      "Alt+x " & "codetracer-test-at-point".toSeq.mapIt($it).join(" ") & " Enter"
    check commandChords(ekEmacs, "debugger.step-over", "codetracer-step-over") ==
      "Alt+x " & "codetracer-step-over".toSeq.mapIt($it).join(" ") & " Enter"
    check commandChords(ekEmacs, "debugger.step-over", "") == ""

proc lispBalance(code: string): int =
  ## The depth an Emacs Lisp text ends at (0 when its parentheses balance,
  ## -1 when one closes too soon), outside strings, characters and comments.
  var i = 0
  while i < code.len:
    case code[i]
    of ';':
      while i < code.len and code[i] != '\n': inc i
    of '"':
      inc i
      while i < code.len and code[i] != '"':
        if code[i] == '\\': inc i
        inc i
    of '?':
      inc i                   # a character literal, ?( or ?\(
      if i < code.len and code[i] == '\\': inc i
    of '(': inc result
    of ')':
      dec result
      if result < 0: return -1
    else: discard
    inc i

suite "the editor configurations the binding writes":
  test "the Emacs Lisp reads: its parentheses balance":
    # A paren too many in the windows query made every Emacs run answer
    # nothing (2026-11-26): each wait timed out with a correct screen.
    check lispBalance(EmacsInit) == 0
    check lispBalance(EmacsSurface) == 0
    check lispBalance("(a))") == -1
