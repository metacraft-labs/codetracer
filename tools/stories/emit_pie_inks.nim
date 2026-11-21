## Writes the web's progress-pie inks, `src/frontend/styles/components/
## agent_harbor_pie_inks.styl`, from the palette that resolves them for GPUI
## and the terminal (`agent_harbor_palette.pieStylesheet`), so the three
## front ends draw a pie in the same inks. The sheet is committed; a unit test
## (`viewmodel/tests/unit/test_agent_harbor_pie.nim`) fails when it differs
## from what this tool would write.
##
##   nim r tools/stories/emit_pie_inks.nim [--check]
##
## `--check` writes nothing and exits 1 when the committed sheet is stale.

import std/[os, strutils]
import ../../src/frontend/viewmodel/views/agent_harbor_palette

const SheetPath* = "src/frontend/styles/components/agent_harbor_pie_inks.styl"

when isMainModule:
  let root = currentSourcePath().parentDir.parentDir.parentDir
  let path = root / SheetPath
  let wanted = pieStylesheet()
  if "--check" in commandLineParams():
    if not fileExists(path) or readFile(path) != wanted:
      stderr.writeLine "stale: " & SheetPath & " (run nim r tools/stories/emit_pie_inks.nim)"
      quit 1
    echo "up to date: ", SheetPath
  else:
    writeFile(path, wanted)
    echo "wrote ", SheetPath
