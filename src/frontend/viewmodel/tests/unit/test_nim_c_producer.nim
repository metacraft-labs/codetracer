## test_nim_c_producer.nim — the Nim producer of the Generated Code Listing's
## `nim.c` target (`GUI/Debugging-Features/Generated-Code-Listing.md` §13.4).
##
## Two inputs, both real Nim output:
##   * an excerpt in the exact shape Nim 2.2's C backend writes with
##     `--lineDir:on` — the `FX_` table, then `#line` before each statement —
##     so the anchor arithmetic is asserted row by row;
##   * when CodeTracer's native Nim example recording is checked out beside
##     this repository (`codetracer-example-recordings/nim/flow_test`), the
##     generated C it bundles: every directive's run is anchored, the anchors
##     pass `generated_code_anchors.validate`, and the module's own C file is
##     the one chosen for its source. Without the checkout that case says so
##     and is skipped (the excerpt still runs);
##   * Edit mode's source, the compiler run now
##     (`native_nim_c_compiler`): a two-proc file compiled with the `nim` on
##     the PATH, its own C file chosen and anchored at its lines. Without a
##     `nim` that case says so and is skipped.
##
## No mocks: a producer is a pure function of the compiler's text, and the
## compile is the real compiler's.
import std/[strutils, tables, unittest]
when not defined(js):
  import std/os
  import ../../host/native_nim_c_compiler

import ../../viewmodels/generated_code_vm
import ../../viewmodels/generated_code_anchors
import ../../viewmodels/nim_c_producer

const Excerpt = """#define FX_0 "/nix/store/x-nim/lib/system.nim"
#define FX_1 "/home/u/project/flow_test.nim"
#include "nimbase.h"
N_LIB_PRIVATE N_NIMCALL(void, compute)(NI n) {
#line 6 FX_1
	NI result = 0;
#line 7 FX_1
	for (NI i = 1; i <= n; ++i) {
#line 8 FX_1
		result += i * i;
	}
#line 444 FX_0
	nimln_(444);
}
"""

suite "the Nim producer reads the generated C's line directives":

  test "the FX table and the directives":
    let lines = Excerpt.splitLines()
    let files = fileTable(lines)
    check files["FX_0"] == "/nix/store/x-nim/lib/system.nim"
    check files["FX_1"] == "/home/u/project/flow_test.nim"
    let ds = lineDirectives(lines)
    check ds.len == 4
    check ds[0].row == 4 and ds[0].line == 6 and
          ds[0].path == "/home/u/project/flow_test.nim"
    check ds[3].path == "/nix/store/x-nim/lib/system.nim" and ds[3].line == 444

  test "rows are the file's lines; each directive's run is one coarse anchor":
    let l = nimCListing(Excerpt, "/home/u/project/flow_test.nim")
    check l.targetId == NimCTargetId
    check l.producer == NimCProducer
    check l.rows.len == 14
    check l.rows[5].text == "\tNI result = 0;"
    check l.rows.len == 14 and l.rows[13].index == 13
    check l.anchors.len == 4
    # `#line 6` opens rows 4..5; `#line 7` rows 6..7; `#line 8` rows 8..10;
    # `#line 444` rows 11..13, the file's end.
    check (l.anchors[0].generatedFirst, l.anchors[0].generatedLast) == (4, 5)
    check (l.anchors[1].generatedFirst, l.anchors[1].generatedLast) == (6, 7)
    check (l.anchors[2].generatedFirst, l.anchors[2].generatedLast) == (8, 10)
    check (l.anchors[3].generatedFirst, l.anchors[3].generatedLast) == (11, 13)
    check l.anchors[2].sources == @[SourceRegion(
      path: "/home/u/project/flow_test.nim", startLine: 8, endLine: 8)]
    for a in l.anchors:
      check a.fidelity == mfCoarse
    # The rows before the first directive are a gap, not an anchor.
    check l.anchors[0].generatedFirst == 4
    # What `LowLevelCodeVM.showGeneratedListing` installs must validate.
    check validate(l.anchors, l.support).len == 0

  test "a Source Map v3 anchors a C file with no directives":
    # The codetracer compiler's form (`--sourcemap:on`): line 0 unmapped,
    # lines 1 and 2 from /a.nim:2 (`AACA` moves the original line by +1,
    # `AAAA` keeps it), line 3 unmapped, line 4 from /a.nim:3.
    let map = """{"version": 3, "file": "@ma.nim.c", "sources": ["/a.nim"],
                  "names": [], "mappings": ";AACA;AAAA;;AACA"}"""
    check mapRowsOf(map) == @[newSeq[MappedPosition](),
                              @[(path: "/a.nim", line: 2)],
                              @[(path: "/a.nim", line: 2)],
                              newSeq[MappedPosition](),
                              @[(path: "/a.nim", line: 3)]]
    let c = "#include \"nimbase.h\"\nint a;\nint b;\n\nint c;\n"
    let l = nimCListing(c, "/a.nim", map)
    check l.anchors.len == 2
    check (l.anchors[0].generatedFirst, l.anchors[0].generatedLast) == (1, 2)
    check l.anchors[0].sources[0].startLine == 2
    check (l.anchors[1].generatedFirst, l.anchors[1].generatedLast) == (4, 4)
    check validate(l.anchors, l.support).len == 0
    check directiveCount(c, "/a.nim", map) == 2
    # Directives win over a map; a map that is not v3 is no map.
    check nimCListing(Excerpt, "/home/u/project/flow_test.nim", map).anchors.len == 4
    check mapRowsOf("""{"version": 2, "mappings": "AACA"}""").len == 0
    check mapRowsOf("not json").len == 0
    check nimCFileFor("/a.nim", [(path: "x.nim.c", text: c, map: ""),
                                 (path: "a.nim.c", text: c, map: map)]) == "a.nim.c"
    check mapPathOf("/c/@ma.nim.c") == "/c/@ma.nim.c.map"

  test "a C line names every Nim line its segments name; its own call's first":
    # The fork piles zero-width segments at one column as it emits a node:
    # this line's run lines 1, 60, 61, 62 in that order (`AAAA`, then `AA2DA`
    # +59, then `AACA` +1 twice), and its text names line 60 — the
    # statement the row's C is for (codetracer's `nim_sudoku_solver`, whose
    # `nimln_(60);{` carries 90 such segments, the first naming line 1).
    let map = """{"version": 3, "sources": ["/s.nim"], "names": [],
                  "mappings": "AAAA,AA2DA,AACA,AACA"}"""
    check mapRowsOf(map) == @[@[(path: "/s.nim", line: 1), (path: "/s.nim", line: 60),
                                (path: "/s.nim", line: 61), (path: "/s.nim", line: 62)]]
    let l = nimCListing("\tnimln_(60);{\n", "/s.nim", map)
    check l.anchors.len == 1
    # The call's line first, alone (the row's cross-reference); the rest
    # merged by file.
    check l.anchors[0].sources == @[
      SourceRegion(path: "/s.nim", startLine: 60, endLine: 60),
      SourceRegion(path: "/s.nim", startLine: 1, endLine: 1),
      SourceRegion(path: "/s.nim", startLine: 61, endLine: 62)]
    check validate(l.anchors, l.support).len == 0
    # Without a call on the line, the first named position leads.
    let plain = nimCListing("\t{\n", "/s.nim", map)
    check plain.anchors[0].sources[0] ==
      SourceRegion(path: "/s.nim", startLine: 1, endLine: 1)

  test "the module's own C file is the one whose directives name it most":
    let own = Excerpt
    let other = "#define FX_0 \"/home/u/project/flow_test.nim\"\n" &
                "#line 3 FX_0\nx();\n"
    check nimCFileFor("/home/u/project/flow_test.nim",
                      [(path: "a.nim.c", text: other),
                       (path: "b.nim.c", text: own)]) == "b.nim.c"
    check nimCFileFor("/nowhere.nim", [(path: "b.nim.c", text: own)]) == ""
    check isGeneratedNimC("/c/@mflow_test.nim.c")
    check not isGeneratedNimC("/c/flow_test.nim")

  when not defined(js):
   test "the example recording's bundled generated C":
     # tests/unit → viewmodel → frontend → src → codetracer → its siblings.
     let files = currentSourcePath().parentDir / ".." / ".." / ".." / ".." /
       ".." / ".." / "codetracer-example-recordings" / "nim" / "flow_test" /
       "files"
     if not dirExists(files):
       echo "  MISSING-PREREQ SKIP: ", files
       skip()
     else:
       var candidates: seq[tuple[path, text: string]] = @[]
       for f in walkDirRec(files):
         if isGeneratedNimC(f):
           candidates.add (path: f, text: readFile(f))
       check candidates.len >= 2
       # The program's own source, as its C names it.
       var source = ""
       for c in candidates:
         for d in lineDirectives(c.text.splitLines()):
           if d.path.endsWith("flow_test.nim") and not d.path.contains("/lib/"):
             source = d.path
             break
         if source.len > 0: break
       checkpoint("the program's source: " & source)
       check source.len > 0
       let chosen = nimCFileFor(source, candidates)
       checkpoint("its C: " & chosen)
       check chosen.len > 0
       # The module's own C file is the one compiled from it — `@m<name>.nim.c`
       # (the recording's folder names are encoded, so only the suffix is
       # stable).
       check chosen.endsWith(".nim.c")
       for c in candidates:
         if c.path == chosen:
           let l = nimCListing(c.text, source)
           check l.anchors.len > 0
           check l.anchors.len == lineDirectives(c.text.splitLines()).len
           check validate(l.anchors, l.support).len == 0
           check directiveCount(c.text, source) > 0

  when not defined(js):
   test "Edit mode: the C the compiler writes now":
     if findExe("nim").len == 0 and getEnv("CODETRACER_NIM").len == 0:
       echo "  MISSING-PREREQ SKIP: no nim on the PATH"
       skip()
     else:
       let dir = getTempDir() / "ct-nim-c-compile-test"
       createDir(dir)
       let state = dir / "state"
       putEnv("CODETRACER_TUI_LAYOUT_DIR", state)   # nativeStateRoot
       let source = dir / "squares.nim"
       writeFile(source, "proc square(x: int): int =\n" &
                         "  result = x * x\n" &
                         "\n" &
                         "echo square(7)\n")
       let c = newNimCCompile()
       check c.startNimCCompile(source)
       check c.waitNimCCompile()
       checkpoint("compile: " & $c.phase & " " & c.message)
       # A stock compiler anchors by directives, CodeTracer's by the map
       # beside each file: whichever this `nim` wrote.
       var candidates: seq[tuple[path, text, map: string]] = @[]
       for f in c.cFiles:
         let m = mapPathOf(f)
         candidates.add (path: f, text: readFile(f),
                         map: (if fileExists(m): readFile(m) else: ""))
       let chosen = nimCFileFor(source, candidates)
       checkpoint("its C: " & chosen)
       check chosen.len > 0
       for cand in candidates:
         if cand.path == chosen:
           let l = nimCListing(cand.text, source, cand.map)
           # Line 2's statement, `result = x * x`, has a run of its own.
           var found = false
           for a in l.anchors:
             if a.sources.len > 0 and a.sources[0].path == source and
                a.sources[0].startLine == 2:
               found = true
           check found
           check validate(l.anchors, l.support).len == 0
       # A statement whose C is one line carrying many positions (a literal
       # over three lines): the statement's line finds it, and it leads.
       let literal = dir / "literal.nim"
       writeFile(literal, "proc main() =\n" &
                          "  var b: array[2, array[2, int]] = [[1, 2],\n" &
                          "                                    [3, 4]]\n" &
                          "  echo b[1][0]\n" &
                          "main()\n")
       let lc = newNimCCompile()
       check lc.startNimCCompile(literal)
       check lc.waitNimCCompile()
       var lits: seq[tuple[path, text, map: string]] = @[]
       for f in lc.cFiles:
         let m = mapPathOf(f)
         lits.add (path: f, text: readFile(f),
                   map: (if fileExists(m): readFile(m) else: ""))
       let litC = nimCFileFor(literal, lits)
       check litC.len > 0
       for cand in lits:
         if cand.path == litC:
           let ll = nimCListing(cand.text, literal, cand.map)
           var covers2 = false
           for a in ll.anchors:
             for r in a.sources:
               if r.path == literal and r.startLine <= 2 and 2 <= r.endLine:
                 covers2 = true
           check covers2
           if cand.map.len > 0:
             # The fork's form: the row whose call names line 2 leads with it.
             let rows = cand.text.splitLines()
             for a in ll.anchors:
               if "nimln_(2)" in rows[a.generatedFirst]:
                 check a.sources[0] == SourceRegion(path: literal,
                                                    startLine: 2, endLine: 2)
           check validate(ll.anchors, ll.support).len == 0
       # A file that does not compile is refused with the compiler's error.
       let broken = dir / "broken.nim"
       writeFile(broken, "let x: int = \"text\"\n")
       let b = newNimCCompile()
       check b.startNimCCompile(broken)
       check not b.waitNimCCompile()
       check "Error:" in b.message
       removeDir(dir)
