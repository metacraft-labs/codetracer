## PLAT-44 — the GPUI edit arm WRITES the editing core.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_edit_arm.nim
##
## What this suite asserts, below the window (the window is
## `ci/test/plat44-edit-window.sh`, and the shipped binary's headless reading
## is the last suite here):
##
##   * GPUI's keystroke spelling decodes to the product's canonical key names —
##     every key PLAT-31's divergent tasks use, plus navigation and `Ctrl+s`;
##   * a keystroke CHANGES the buffer, through `editing_core.applyKey` under
##     `editScopeOf` — the terminal's call and scope — and `Ctrl+s` WRITES THE
##     FILE, on a real directory;
##   * a read-only buffer STILL REFUSES a keystroke from this arm (PLAT-34 once
##     took a route around the filters);
##   * the surface is writable and agrees with the edit-mode contract.
##
## The SHIPPED BINARY's half — `--edit-keys` through the shim's focus
## dispatch, the file on disk, the plan, the notice's absence with its
## positive control — is `test_plat44_shipped_writes.nim`, kept apart so this
## suite stays portable (no binary to build) and can be counted by the floor.
##
## NO MOCKS. A real directory and the real editing core.

import std/[os, strutils, tempfiles, unittest]

import codetracer_embed
import ../app/edit_arm
import ../../view_vocabulary/editor_surface
import ../../viewmodel/tests/generators/keymap_task_set

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ProjectFile = "doc.txt"
  ProjectText = "alpha beta\ngamma\n"

proc gpuiSpellingOf(name: string): (string, seq[string]) =
  ## The inverse of `canonicalKeyOfGpui` for the names this suite needs — how
  ## GPUI's `keystroke.key` + modifiers spell a canonical key. Written out
  ## rather than derived from the decoder's table, so the law below compares
  ## two independent spellings.
  case name
  of "Esc": ("escape", @[])
  of "Enter": ("enter", @[])
  of "Tab": ("tab", @[])
  of "Backspace": ("backspace", @[])
  of "Space": ("space", @[])
  of "Up": ("up", @[])
  of "Down": ("down", @[])
  of "Left": ("left", @[])
  of "Right": ("right", @[])
  else:
    if name.startsWith("Ctrl+"):
      let rest = name[5 .. ^1]
      if rest.len == 1: (rest, @["control"])
      else: (rest.toLowerAscii, @["control"])
    elif name.len == 1 and name[0] in 'A'..'Z':
      ($name[0].toLowerAscii, @["shift"])
    else: (name, @[])

suite "PLAT-44: GPUI keystrokes decode to the product's key names":

  test "every key the divergent tasks use, plus navigation and save":
    var names = @["Esc", "Enter", "Up", "Down", "Left", "Right", "Ctrl+s",
                  "Backspace", "Space"]
    for t in TaskSet:
      for k in t.vimKeys & t.kakouneKeys:
        if k notin names: names.add k
    ck names.len > 40
    for n in names:
      let (key, mods) = gpuiSpellingOf(n)
      checkpoint(n & " <- " & key & " " & $mods)
      ck canonicalKeyOfGpui(key, mods) == n

  test "a shifted symbol decodes the same from either GPUI spelling":
    # Which of the two a platform sends is measured by the window lane; the
    # decoder must not depend on it.
    for (unshifted, shifted) in [("`", "~"), (".", ">"), (",", "<"),
                                 ("1", "!"), ("9", "("), ("/", "?")]:
      ck canonicalKeyOfGpui(unshifted, ["shift"]) == shifted
      ck canonicalKeyOfGpui(shifted, ["shift"]) == shifted
      ck canonicalKeyOfGpui(shifted, []) == shifted

  test "Shift+Tab keeps its prefix, and a platform chord has no name":
    ck canonicalKeyOfGpui("tab", ["shift"]) == "Shift+Tab"
    ck canonicalKeyOfGpui("a", ["platform"]) == ""
    ck canonicalKeyOfGpui("mediaplay", []) == ""

suite "PLAT-44: the arm writes the core, and saves through the project writer":

  test "a keystroke changes the buffer, and Ctrl+s writes the file":
    let dir = createTempDir("plat44-", "-project")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let arm = newGpuiEditArm(dir, ProjectFile, ProjectText)
      let typed = arm.applyGpuiKey("z", [], 1)
      ck typed.name == "z"
      ck typed.outcome == eoChanged
      ck arm.text == "z" & ProjectText
      ck arm.isDirty
      # Not yet on disk: the model changing and the file changing are two
      # facts.
      ck readFile(dir / ProjectFile) == ProjectText
      let saved = arm.applyGpuiKey("s", ["control"], 2)
      ck saved.saved
      ck readFile(dir / ProjectFile) == "z" & ProjectText
      ck not arm.isDirty
      ck arm.status == "wrote " & ProjectFile
      # Undo from a real key, through the model.
      discard arm.applyGpuiKey("z", ["control"], 3)
      ck arm.text == ProjectText
    finally:
      removeDir(dir)

  test "under Vim the same keys mean Vim's commands, and Vim's own save writes":
    let dir = createTempDir("plat44-", "-vim")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let arm = newGpuiEditArm(dir, ProjectFile, ProjectText, kmVim)
      discard arm.applyGpuiKey("x", [], 1)       # delete-char-forward
      ck arm.text == ProjectText[1 .. ^1]
      let saved = arm.applyGpuiKey("s", ["control"], 2)
      ck saved.saved
      ck readFile(dir / ProjectFile) == ProjectText[1 .. ^1]
    finally:
      removeDir(dir)

  test "the surface is writable, and so is the contract — they no longer disagree":
    let arm = newGpuiEditArm("", ProjectFile, ProjectText)
    let surface = arm.surfaceOf(20)
    ck surface.mutable
    ck surface.mutable == sourceContractFor(pmEdit).mutable
    ck surface.notice.len == 0

  test "the pane FOLLOWS THE CARET down a long file, with the minimal scroll":
    # Until the arm carried a viewport, its surface always began at line 1:
    # a caret moved below the fold edited text nobody could see.
    var text = ""
    for i in 1 .. 100: text.add "line " & $i & "\n"
    let arm = newGpuiEditArm("", ProjectFile, text)
    let first = arm.surfaceOf(10)
    ck first.rows[0].line == 1
    for i in 1 .. 30:
      discard arm.applyGpuiKey("down", [], int64(i))
    let s = arm.surfaceOf(10)
    # Caret on line 31 in a 10-row pane: the window is 22 … 31, not centred.
    ck s.rows[0].line == 22
    ck s.rows[^1].line == 31
    ck "line 31" in s.rows[^1].text
    # …and back up: one line above the window moves it by exactly one.
    for i in 1 .. 10:
      discard arm.applyGpuiKey("up", [], int64(100 + i))
    ck arm.surfaceOf(10).rows[0].line == 21

  test "a READ-ONLY buffer still refuses a keystroke from this arm":
    let dir = createTempDir("plat44-", "-ro")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let arm = newGpuiEditArm(dir, ProjectFile, ProjectText)
      arm.doc.state.filters.add TransactionFilter(kind: tfReadOnly)
      let refused = arm.applyGpuiKey("z", [], 1)
      ck refused.outcome != eoChanged
      ck arm.text == ProjectText
      # THE CONTROL: the same key without the filter does change it, so the
      # refusal above is the filter's and not a key that does nothing.
      let open = newGpuiEditArm(dir, ProjectFile, ProjectText)
      ck open.applyGpuiKey("z", [], 1).outcome == eoChanged
    finally:
      removeDir(dir)

suite "PLAT-44 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
