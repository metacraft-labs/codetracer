## fixtures/plat53_noir_project.nim — PLAT-53: the real Noir project every
## Test Results suite runs, on every front-end.
##
## A library the suites import, not a suite. The SAME crate the desktop's
## Electron capture writes (`src/tests/gui/tests/test-results-pane/
## plat53-test-results-capture.spec.ts`, byte for byte): one test that passes
## and one that fails, so a pane that painted every row green — or every row
## red — is caught, and so the rows each front-end draws can be compared with
## the desktop's captured ones (`src/tests/visual/answers/
## plat53-test-results.electron.json`).
##
## NO MOCK: a real crate on a real filesystem, run by the real `ct test run`,
## which hands it to the real `ct-test` and the real `nargo`.

import std/[os, tempfiles]

const
  Plat53PackageName* = "plat53_suite"
  Plat53NargoToml* =
    "[package]\nname = \"" & Plat53PackageName & "\"\ntype = \"bin\"\n" &
    "authors = [\"\"]\n\n[dependencies]\n"
  Plat53MainNr* = """fn main(x: Field, y: pub Field) {
    assert(x != y);
}

#[test]
fn test_passes() {
    main(1, 2);
}

#[test]
fn test_fails() {
    main(1, 1);
}
"""
  Plat53Passing* = "test_passes"
  Plat53Failing* = "test_fails"
  Plat53PassingLine* = 5
  Plat53FailingLine* = 10
    ## The catalog's lines: each test's `#[test]` attribute.

proc writePlat53Project*(prefix = "ct-plat53-project-"): string =
  ## A fresh copy of the crate in a temporary directory; its path.
  result = createTempDir(prefix, "")
  createDir(result / "src")
  writeFile(result / "Nargo.toml", Plat53NargoToml)
  writeFile(result / "src" / "main.nr", Plat53MainNr)
