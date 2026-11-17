## `dvs-guiassert-codetracer`: DemoVideoScript's `dvs` command line with the
## GuiAssert backend and CodeTracer's GPUI binding linked in process.
##
##   dvs-guiassert-codetracer run <scenario> --pack <pack> --backend guiassert
##   dvs-guiassert-codetracer lane <lane.yaml>
##   dvs-guiassert-codetracer --serve        the same backend over JSON lines
##
## `--backend guiassert-<defect>` plants one of the adapter's defects.

import std/[os, strutils, tables]
import demo_video_script/[backend, cli, jsonlines]
import demo_video_script_guiassert
import ./ct_gui_binding

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--serve":
    var defect = gdNone
    for a in args[1 .. ^1]:
      if a.startsWith("--defect="): defect = parseEnum[GuiDefect](a[9 .. ^1])
    serveJsonLines(newGuiAssertBackend(ctGuiBinding(), defect))
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["guiassert"] = proc (): Backend = newGuiAssertBackend(ctGuiBinding())
  for d in [gdStaleRead, gdOffByOne, gdEarlySync, gdReadSideEffect]:
    let defect = d
    builtins["guiassert-" & $d] = proc (): Backend = newGuiAssertBackend(ctGuiBinding(), defect)
  dvsMain(builtins)
