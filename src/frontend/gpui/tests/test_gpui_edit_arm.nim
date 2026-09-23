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
##   * the shipped binary, driven headlessly with `--edit-keys` through the
##     shim's own focus dispatch, changes a file ON DISK, draws the typed byte
##     in its render plan, and no longer carries the read-only notice — with a
##     positive control proving the notice scan can find the notice.
##
## NO MOCKS. A real directory, the real editing core, and for the last suite
## the shipped `codetracer-gpui` binary over the real isonim-gpui shim.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

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

suite "PLAT-44: the shipped binary, headless, through the shim's own dispatch":

  let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
  let bin = repo / "build/bin/codetracer-gpui"
  let shimDir = repo.parentDir / "isonim-gpui/rust/target/debug"

  proc runBinary(project: string; keys: string): (int, string, string) =
    var args = @["--edit", "--report-plan", "--width=1280", "--height=800"]
    if keys.len > 0: args.add "--edit-keys=" & keys
    args.add project
    let p = startProcess(bin, args = args,
                         env = newStringTable({"LD_LIBRARY_PATH": shimDir,
                                               "CODETRACER_TUI_LAYOUT_DIR":
                                                 project / ".state"}),
                         options = {poStdErrToStdOut})
    let output = p.outputStream.readAll()
    let rc = p.waitForExit()
    p.close()
    (rc, output, readFile(project / ProjectFile))

  test "the binary exists":
    checkpoint(bin)
    ck fileExists(bin)

  test "typed keys change the FILE ON DISK, and the typed byte is in the plan":
    let dir = createTempDir("plat44-", "-bin")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let (rc, output, onDisk) = runBinary(dir, "shift-q,control-s")
      checkpoint(output[0 ..< min(400, output.len)])
      ck rc == 0
      ck onDisk == "Q" & ProjectText
      ck output.contains("Qalpha beta")
      # …and the negative twin: the same run with no keys leaves the file and
      # the plan as they were.
      writeFile(dir / ProjectFile, ProjectText)
      let (rc2, output2, onDisk2) = runBinary(dir, "")
      ck rc2 == 0
      ck onDisk2 == ProjectText
      ck not output2.contains("Qalpha beta")
      ck output2.contains("alpha beta")
    finally:
      removeDir(dir)

  test "the read-only notice is GONE, and the scan can find it when present":
    let dir = createTempDir("plat44-", "-notice")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let (rc, output, _) = runBinary(dir, "")
      ck rc == 0
      let marker = "read-only: the '"
      ck not output.contains(marker)
      # POSITIVE CONTROL: the surface builder still produces that notice for
      # a medium that cannot write, so the marker is the right string to scan
      # for — an absence scan over a string nothing ever emits cannot fail.
      let readOnly = editorSurfaceForProject(ProjectFile, ProjectText,
                                             "gpui", mutableHere = false)
      ck readOnly.notice.contains(marker)
    finally:
      removeDir(dir)

  test "a key that reaches no element fails the run":
    let dir = createTempDir("plat44-", "-badkey")
    try:
      writeFile(dir / ProjectFile, ProjectText)
      let (rc, output, onDisk) = runBinary(dir, "hyper-x")
      ck rc != 0
      ck output.contains("cannot spell")
      ck onDisk == ProjectText
    finally:
      removeDir(dir)

suite "PLAT-44 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
