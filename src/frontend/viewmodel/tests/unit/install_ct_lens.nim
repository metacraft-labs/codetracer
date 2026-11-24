## install_ct_lens.nim — `ct_lens_fixture.installLens` as a command, for the
## suites that are not Nim: the GUI suite's ct-lens specs
## (`src/tests/gui/tests/plugins/*ct_lens*.spec.ts`) build and install the
## `ct-lens` package (`src/plugins/ct-lens/`) as it ships with
##
##     nim c -r --hints:off install_ct_lens.nim <components root>
##
## and read the component directory it prints. Not a suite (no `test_`
## prefix), so no lane collects it.

import std/os

import ./ct_lens_fixture

when isMainModule:
  if paramCount() < 1:
    quit "usage: install_ct_lens <components root>", 2
  createDir(paramStr(1))
  echo installLens(paramStr(1))
