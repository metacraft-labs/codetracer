## test_dual_snap_stamp_parsers.nim — the two parsers Tier 2's child-app
## rebuild stamp is built from, held to their inputs.
##
## `dual_snap.compileChildApp` stamps a child with what its compile read:
## `processedFiles` reads the modules from the compiler's `Processing` hint,
## and `compileTimeReads` finds what those modules read at compile time that
## the hint does not report (`staticRead` / `slurp` of a literal path, a
## `{.compile.}`d tree, or a read it cannot name). A parser that silently
## reads nothing would stamp a child with nothing and reuse it forever, so
## each is checked here on input written for the purpose; the stamp's
## behaviour end to end is `test_dual_snap_child_stamp.nim`'s.
##
## ## NO MOCKS
##
## The `Processing` lines are spelled as the compiler prints them
## (`compiler/modulegraphs.nim`, `"$#$# $#: $#: $#"` plus ` [Processing]`),
## and the module `compileTimeReads` scans is a real file on disk.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible.

import std/[os, unittest]

import ../../testing/dual_snap

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 17

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

suite "dual-snap stamp parsers":
  test "the stamp reads the compiler's Processing lines as the compiler prints them":
    # Spelled as `modulegraphs.nim` prints them, the `(nims)` one included.
    let lines = "Hint: (nims)  config: include: /w/ct/src/a.nims [Processing]\n" &
                "Hint: >> app_x: import: /w/isonim-tui/src/isonim_tui.nim [Processing]\n" &
                "Hint: >> app_x: import: relative/ignored.nim [Processing]\n" &
                "Hint: >> app_y: import: /w/isonim-tui/src/isonim_tui.nim [Processing]\n" &
                "CC: something else\n"
    var files = processedFiles(lines)
    ck files.len == 2
    ck files.len == 2 and files[0].config and files[0].path == "/w/ct/src/a.nims"
    ck files.len == 2 and not files[1].config and
       files[1].path == "/w/isonim-tui/src/isonim_tui.nim"
    # A file the config script and the program both read is the program's.
    files = processedFiles(lines &
      "Hint: >> app_x: import: /w/ct/src/a.nims [Processing]\n")
    ck files.len == 2 and not files[0].config

  test "the stamp names what a module reads at compile time":
    let root = getTempDir() / ("ct-dual-snap-reads-" & $getCurrentProcessId())
    let dir = root / "reads"
    createDir(dir)
    defer: removeDir(root)
    let module = dir / "reader.nim"
    writeFile(module,
      "const a = staticRead(\"../data/a.json\")\n" &
      "const b = slurp(\"b.txt\")\n" &
      "# const c = staticRead(\"commented.txt\")\n" &
      "{.compile: \"native.c\".}\n")
    var reads = compileTimeReads(module)
    ck reads.files == @[root / "data" / "a.json", dir / "b.txt"]
    ck reads.trees == @[dir] and not reads.computed
    writeFile(module, "const d = staticRead(root / \"x\")\n")
    ck compileTimeReads(module).computed
    writeFile(module, "const e = gorge(\"date\")\n")
    ck compileTimeReads(module).computed
    writeFile(module, "const f = mySlurp(\"x\")\n")
    ck not compileTimeReads(module).computed
    # Every other spelling of a read is one the scan cannot name.
    for spelling in ["const g = staticRead \"x\"",
                     "const h = \"x\".staticRead",
                     "const i = staticRead(\"x\" & suffix)",
                     "const j = slurp\"x\""]:
      writeFile(module, spelling & "\n")
      checkpoint(spelling)
      ck compileTimeReads(module).computed
    # A line the literal reader may misread is judged on its raw text.
    for spelling in ["if c == '\"': discard staticRead(p)",
                     "let d = r\"dir/\" & slurp(p)",
                     "#[ note ]# const m = staticRead(p)"]:
      writeFile(module, spelling & "\n")
      checkpoint(spelling)
      ck compileTimeReads(module).computed
    # A mention inside a string or a comment reads nothing.
    writeFile(module, "const k = \"staticRead(x)\" # slurp(y)\n")
    ck not compileTimeReads(module).computed

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
