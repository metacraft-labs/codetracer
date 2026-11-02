## fixtures/plat55_noir_build.nim — PLAT-55: the real Noir crate whose build
## every Problems suite runs, on every front-end.
##
## A library the suites import, not a suite. The SAME crate the desktop's
## Electron capture writes (`src/tests/gui/tests/problems-pane/
## plat55-problems-capture.spec.ts`, byte for byte): two files, so the rows
## carry two paths (and grouping by file has two groups); in `src/util.nr` one
## warning and one error, in `src/main.nr` one error — so a pane that painted
## every row as an error, dropped the warning, or lost the file order is
## caught; and the rows each front-end lists can be compared with the
## desktop's captured ones (`src/tests/visual/answers/
## plat55-problems.electron.json`).
##
## `nargo compile` (1.0.0-beta.26) reports, in this order:
##
##   warning  src/util.nr:2:9   unused variable unused
##   error    src/util.nr:3:22  Expected type bool, found type Field
##   error    src/main.nr:5:19  Expected type bool, found type Field
##
## NO MOCK: a real crate on a real filesystem, built by the real `nargo`.

import std/[os, strutils, tempfiles]

const
  Plat55PackageName* = "plat55_build"
  Plat55NargoToml* =
    "[package]\nname = \"" & Plat55PackageName & "\"\ntype = \"bin\"\n" &
    "authors = [\"\"]\n\n[dependencies]\n"
  Plat55MainNr* = """mod util;

fn main(x: Field, y: pub Field) {
    let a: Field = 42;
    let b: bool = a;
    assert(b);
    assert(util::double(y) != x);
}
"""
  Plat55UtilNr* = """pub fn double(v: Field) -> Field {
    let unused = 1;
    let flag: bool = v;
    assert(flag);
    v * 2
}
"""
  Plat55BuildCommand* = "nargo compile"

  Plat55Expected*: array[3, tuple[severity, path: string; line, col: int;
                                  message: string]] = [
    ("warning", "src/util.nr", 2, 9, "unused variable unused"),
    ("error", "src/util.nr", 3, 22, "Expected type bool, found type Field"),
    ("error", "src/main.nr", 5, 19, "Expected type bool, found type Field")]
    ## What the build reports, in its order — what every front-end's pane
    ## lists (and what the desktop's capture is asserted to have listed).

proc writePlat55Project*(prefix = "ct-plat55-project-"): string =
  ## A fresh copy of the crate in a temporary directory; its path.
  result = createTempDir(prefix, "")
  createDir(result / "src")
  writeFile(result / "Nargo.toml", Plat55NargoToml)
  writeFile(result / "src" / "main.nr", Plat55MainNr)
  writeFile(result / "src" / "util.nr", Plat55UtilNr)

proc lineOf*(text: string; line: int): string =
  ## Line `line` (1-based) of `text`.
  var n = 1
  for l in text.splitLines:
    if n == line: return l
    inc n
  ""
