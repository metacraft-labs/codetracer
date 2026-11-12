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
##     and is skipped (the excerpt still runs).
##
## No mocks: a producer is a pure function of the compiler's text.
import std/[strutils, tables, unittest]
when not defined(js):
  import std/os

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
