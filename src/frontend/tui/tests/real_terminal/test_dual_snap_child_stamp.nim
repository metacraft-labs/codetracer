## test_dual_snap_child_stamp.nim — Tier 2's child-app rebuild stamp covers the
## `isonim-tui` checkout the child links.
##
## ## The defect this pins
##
## `dual_snap.compileChildApp` reuses `test-logs/tui-dual-snap/bin/<stem>` when
## the binary is newer than its stamp. The stamp was a hand-written list of
## in-repo trees — `app/`, `host/` and a few others — that left out the
## `isonim-tui` checkout whose renderer every child links, the other sibling
## libraries, and most of the in-repo modules a child imports. CTF-P1b's SGR 58 work landed in
## `isonim-tui`'s `text/ansi`, the Agent Harbor story host built before it was
## reused, and the Tier-2 terminal ran the OLD renderer against a Tier-1 model
## built with the NEW one: the coverage suite went red on a correct tree and
## stayed red until someone deleted the binary by hand. Run the other way, the
## same stale child keeps passing after an `isonim-tui` regression.
##
## ## How it is recreated
##
## The suite copies the `isonim-tui` source tree the child would link, points
## `ISONIM_TUI_SRC` at the copy (the override `config.nims` gives the child
## compile), builds `tests/apps/app_stamp_probe.nim` through `compileChildApp`,
## then EDITS one encoder in the copy — the same module the SGR 58 change
## touched — and asks `compileChildApp` for the child again. The probe prints
## that encoder's bytes, so what is asserted is what the binary RUNS, not what
## the stamp decided:
##
##   1. after the edit, the child prints the edited bytes (the defect: it
##      printed the old ones, because nothing in the stamp had changed);
##   2. asked again with nothing changed, the binary is reused, not relinked —
##      the stamp must cost one rebuild per edit, not one per case;
##   3. touching a module no hand-written list named — `common/key_names` in
##      this repository, `nim_everywhere/platform` in a sibling — rebuilds the
##      child, because the stamp is now the set of files the compile read; so
##      does touching a file the child embeds with `staticRead` from another
##      directory, which the compiler does not report, and touching the
##      directory of a module it read, which is how adding or deleting a file
##      there shows;
##   4. a stamp marked `volatile` — a module read something the stamp cannot
##      name — is never trusted;
##   5. pointed back at the workspace's own `isonim-tui`, whose files are all
##      OLDER than the binary, the child is rebuilt and prints the original
##      bytes. Modification times alone cannot see a change of checkout.
##
## The suite uses only `compileChildApp` and `appBinaryPath`, which predate the
## fix, so it compiles against the unfixed `dual_snap.nim` and fails there at
## every case by name (2 because case 1 never rebuilt the child, 4 because
## the unfixed code writes no stamp to mark).
## The stamp's own parsers are held to their inputs in
## `test_dual_snap_stamp_parsers.nim`.
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## The child is compiled by the product's own compile line from a real copy of
## the real `isonim-tui` tree, and run as a real process. The one thing the
## suite changes is the process environment the compile inherits, which is the
## documented override and not a substitution inside the subject.
##
## Case 3 cannot use a copy: nothing it touches has an override to point at
## one. It moves the REAL files' modification times forward and puts each back
## afterwards, even when a check fails, unless something else changed it in
## between; their contents are never written.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible.

import std/[os, osproc, strutils, times, unittest]

import ../../testing/dual_snap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 25

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Stem = "app_stamp_probe"
  EncoderModule = "isonim_tui" / "text" / "ansi.nim"
  OriginalLine = "proc cursorHide*(): string {.inline.} = \"\\x1b[?25l\""
    ## The line the suite edits in its copy. Matched literally so an upstream
    ## rewrite of it fails the suite by name instead of editing nothing.
  EditedLine = "proc cursorHide*(): string {.inline.} = \"\\x1b[?25lSTAMP\""
  OriginalOutput = "CURSOR-HIDE \"\\x1B[?25l\""
  EditedOutput = "CURSOR-HIDE \"\\x1B[?25lSTAMP\""
  NimEverywhereModule = "nim_everywhere" / "platform.nim"

proc runProbe(): string =
  let (output, code) = execCmdEx(appBinaryPath(Stem).quoteShell)
  if code != 0:
    raise newException(OSError,
      "app_stamp_probe exited " & $code & ":\n" & output)
  output.strip()

proc binTime(): Time =
  getLastModificationTime(appBinaryPath(Stem))

let workspaceTui = repoRoot().parentDir / "isonim-tui" / "src"
let keyNames = repoRoot() / "src" / "common" / "key_names.nim"
let nimEverywhere = repoRoot().parentDir / "nim-everywhere" / "src" /
                    NimEverywhereModule
let eventsSource = repoRoot() / "src" / "common" / "common_types" /
                   "codetracer_features" / "events.nim"

template rebuildsAfterTouching(path: string) =
  ## Moves `path`'s modification time to now, asks for the child, and puts
  ## the time back whatever happens.
  let before = binTime()
  let original = getLastModificationTime(path)
  var touched = getTime()
  try:
    setLastModificationTime(path, touched)
    # Read back: the file system keeps less precision than `getTime` has.
    touched = getLastModificationTime(path)
    compileChildApp(Stem)
    checkpoint("touched " & path & "; binary " & $before & " -> " & $binTime())
    ck binTime() != before
    ck runProbe() == EditedOutput
  finally:
    # Put back only our own touch: a real edit made meanwhile keeps its time.
    if getLastModificationTime(path) == touched:
      setLastModificationTime(path, original)
let copyRoot = getTempDir() / ("ct-dual-snap-stamp-" & $getCurrentProcessId())
let copyTui = copyRoot / "src"

suite "dual-snap child stamp covers the isonim-tui checkout":
  test "the suite's preconditions hold":
    # A stale probe from an earlier run would let case 1 pass on a binary this
    # run never built, so the run starts with none.
    removeFile(appBinaryPath(Stem))
    removeFile(appBinaryPath(Stem) & ".stamp")
    ck fileExists(workspaceTui / EncoderModule)
    ck fileExists(keyNames)
    ck fileExists(nimEverywhere)
    ck fileExists(eventsSource)
    ck OriginalLine in readFile(workspaceTui / EncoderModule)
    # `config.nims` lets a `reprobuild.paths` or `repro.paths` entry outrank
    # `ISONIM_TUI_SRC` and the sibling checkouts; the copy, and the sibling
    # case 3 touches, are only what the child links when no such entry names
    # another checkout of them.
    var pathsNameOne = false
    for file in ["reprobuild.paths", "repro.paths"]:
      let pathsFile = repoRoot() / file
      if fileExists(pathsFile):
        let text = readFile(pathsFile)
        if "isonim-tui/" in text or "nim-everywhere/" in text:
          pathsNameOne = true
    ck(not pathsNameOne)
    removeDir(copyRoot)
    copyDir(workspaceTui, copyTui)
    putEnv("ISONIM_TUI_SRC", copyTui)

  test "an isonim-tui edit rebuilds the child, which runs the edited renderer":
    compileChildApp(Stem)
    ck runProbe() == OriginalOutput
    let before = binTime()
    let module = copyTui / EncoderModule
    writeFile(module, readFile(module).replace(OriginalLine, EditedLine))
    ck EditedLine in readFile(module)
    compileChildApp(Stem)
    checkpoint("binary " & $before & " -> " & $binTime())
    ck binTime() != before
    ck runProbe() == EditedOutput

  test "an unchanged tree reuses the child instead of relinking it":
    let before = binTime()
    compileChildApp(Stem)
    ck binTime() == before
    ck runProbe() == EditedOutput

  test "touching a module no hand-written list named rebuilds the child":
    rebuildsAfterTouching(keyNames)
    rebuildsAfterTouching(nimEverywhere)
    rebuildsAfterTouching(eventsSource)
    rebuildsAfterTouching(keyNames.parentDir)
    # And once more with nothing touched, it is reused again.
    let before = binTime()
    compileChildApp(Stem)
    ck binTime() == before

  test "a stamp marked volatile is never trusted":
    let stamp = appBinaryPath(Stem) & ".stamp"
    writeFile(stamp, readFile(stamp) & "volatile " & keyNames & "\n")
    let before = binTime()
    compileChildApp(Stem)
    ck binTime() != before
    ck "volatile " notin readFile(stamp)

  test "pointing back at the workspace's isonim-tui rebuilds the child":
    let before = binTime()
    delEnv("ISONIM_TUI_SRC")
    compileChildApp(Stem)
    ck binTime() != before
    ck runProbe() == OriginalOutput

  test "every assertion in this file ran":
    # The copy is removed here rather than at the end of the case that last
    # uses it, so a failing case does not leave it in the temp directory.
    removeDir(copyRoot)
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
