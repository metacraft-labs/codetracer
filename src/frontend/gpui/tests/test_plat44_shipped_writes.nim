## PLAT-44 — the eight transaction kinds, WRITTEN BY THE SHIPPED BINARY and
## read from its run.
##
## Run (needs `just build-gpui`):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_plat44_shipped_writes.nim
##
## For each of PLAT-34's eight transaction kinds, `codetracer-gpui --edit
## <project> --edit-keys=<keys> --report-plan` is run with the kind's keys in
## GPUI's own spelling, delivered through the shim's focus dispatch to the
## editor pane's listener — the window's route — and then `Ctrl+s`. Read back:
##
##   * the FILE ON DISK, which must equal the document the same key names
##     produce in-process under the same model;
##   * the RENDER PLAN (the Rust shadow tree), which must contain the line the
##     transaction produced.
##
## The keymap is chosen the way a user chooses it: the STORED PREFERENCE in
## the run's own state directory (`CODETRACER_TUI_LAYOUT_DIR`), read by
## `loadKeymapPreference` — PLAT-43's one selector, from GPUI's side.
##
## The kind→keys table is the one `tui/tests/test_plat44_both_arms_write.nim`
## asserts against PLAT-34's named operations; it is restated here only as
## DATA (GPUI spellings), and the expected document is computed, not typed.
##
## It also carries the shipped binary's own edit-mode facts, moved here from
## `test_gpui_edit_arm.nim` so that suite stays portable: a typed key changes
## the FILE and the plan, the read-only notice is gone (with the positive
## control that the scan can find it), and a key that reaches no element
## fails the run.
##
## No mocks: the shipped binary, the real shim, a real directory.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import codetracer_embed
import ../../view_vocabulary/editor_surface

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ProjectFile = "doc.txt"
  ProjectText = "alpha beta\ngamma\n"
  Doc = "def calc(n):\n    total = 0\n    for i in range(n):\n" &
        "        total += i\n    return total\n"

type
  ShippedTx = object
    name: string
    model: KeymapModel
    keys: seq[string]
      ## Canonical names, arrangement included (no snapshot is taken inside
      ## the binary; the before-state is the file as written).

let Kinds = @[
  ShippedTx(name: "insert a character", model: kmProductDefault,
            keys: @["X"]),
  ShippedTx(name: "split a line", model: kmProductDefault,
            keys: @["Right", "Right", "Right", "Enter"]),
  ShippedTx(name: "delete backward", model: kmProductDefault,
            keys: @["Right", "Backspace"]),
  ShippedTx(name: "delete a selection", model: kmKakoune, keys: @["w", "d"]),
  ShippedTx(name: "indent a selection", model: kmKakoune, keys: @["X", ">"]),
  ShippedTx(name: "upper-case a selection", model: kmKakoune,
            keys: @["w", "~"]),
  ShippedTx(name: "undo", model: kmProductDefault,
            keys: @["X", "Y", "Ctrl+z"]),
  ShippedTx(name: "redo", model: kmProductDefault,
            keys: @["X", "Ctrl+z", "Ctrl+y"]),
]
const KindCount = 8

proc gpuiSpec(name: string): string =
  ## The `--edit-keys` spelling of a canonical key: GPUI's `keystroke.key`
  ## with its modifiers, `-`-joined.
  case name
  of "Enter": "enter"
  of "Backspace": "backspace"
  of "Right": "right"
  of "Esc": "escape"
  else:
    if name.startsWith("Ctrl+"): "control-" & name[5 .. ^1]
    elif name.len == 1 and name[0] in 'A'..'Z': "shift-" & $name[0].toLowerAscii
    elif name == "~": "shift-`"
    elif name == ">": "shift-."
    else: name

proc expectedDoc(tx: ShippedTx): string =
  var d = initEditingDocument(ProjectFile, Doc, tx.model)
  var now = 0'i64
  for k in tx.keys:
    inc now
    discard d.applyKey(editScopeOf(d), k, now)
  d.state.doc

proc changedLine(before, after: string): string =
  let a = before.splitLines()
  let b = after.splitLines()
  for i in 0 ..< b.len:
    if i >= a.len or a[i] != b[i]:
      return b[i].strip()
  ""

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = repo.parentDir / "isonim-gpui/rust/target/debug"

proc runKeys(project, stateDir: string; specs: seq[string]): (int, string) =
  let p = startProcess(bin,
    args = @["--edit", "--report-plan", "--width=1280", "--height=800",
             "--edit-keys=" & specs.join(","), project],
    env = newStringTable({"LD_LIBRARY_PATH": shimDir,
                          "CODETRACER_TUI_LAYOUT_DIR": stateDir}),
    options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

suite "PLAT-44: the shipped binary writes each transaction kind":

  test "the table is the eight kinds":
    ck Kinds.len == KindCount
    ck fileExists(bin)

  for tx in Kinds:
    test "typed into the binary, saved, on disk and in the plan: " & tx.name:
      let dir = createTempDir("plat44-", "-kind")
      try:
        let project = dir / "project"
        let state = dir / "state"
        createDir(project)
        createDir(state)
        writeFile(project / ProjectFile, Doc)
        # THE MODEL, AS A USER CHOSE IT: the stored preference.
        writeFile(state / "keymap", $tx.model & "\n")
        var specs: seq[string] = @[]
        for k in tx.keys: specs.add gpuiSpec(k)
        specs.add "control-s"
        let (rc, plan) = runKeys(project, state, specs)
        checkpoint("rc " & $rc & ": " & plan[0 ..< min(300, plan.len)])
        ck rc == 0
        let want = expectedDoc(tx)
        let onDisk = readFile(project / ProjectFile)
        checkpoint("on disk: " & onDisk.splitLines()[0])
        ck onDisk == want
        ck onDisk != Doc or tx.name == "undo"
        let line = changedLine(Doc, want)
        if line.len > 0:
          ck plan.contains(line)
      finally:
        removeDir(dir)

suite "PLAT-44: the shipped binary, headless, through the shim's own dispatch":

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

suite "PLAT-44 shipped writes — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
