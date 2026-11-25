## `dvs-guiassert-codetracer-zgui`: DemoVideoScript's `dvs` command line with
## the GuiAssert backend and CodeTracer's zgui binding linked in process.
##
##   dvs-guiassert-codetracer-zgui run <scenario> --pack <pack> --backend guiassert
##   dvs-guiassert-codetracer-zgui lane <lane.yaml>
##   dvs-guiassert-codetracer-zgui --serve        the same backend over JSON lines

import std/[os, tables]
import demo_video_script/[backend, cli, jsonlines]
import demo_video_script_guiassert
import ./ct_zgui_binding

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--serve":
    serveJsonLines(newGuiAssertBackend(ctZguiBinding()))
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["guiassert"] = proc (): Backend = newGuiAssertBackend(ctZguiBinding())
  dvsMain(builtins)
