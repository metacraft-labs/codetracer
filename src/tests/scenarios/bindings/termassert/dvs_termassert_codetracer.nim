## `dvs-termassert-codetracer`: DemoVideoScript's `dvs` command line with the
## TermAssert backend and CodeTracer's terminal binding linked in process.
##
##   dvs-termassert-codetracer run <scenario> --pack <pack> --backend termassert
##   dvs-termassert-codetracer lane <lane.yaml>
##   dvs-termassert-codetracer --serve        the same backend over JSON lines
##   dvs-termassert-codetracer --serve --editor=nvim|emacs
##
## `--backend termassert-nvim` / `termassert-emacs` runs the scenario in
## Neovim with codetracer.nvim / Emacs with codetracer.el instead of the
## terminal front-end (`ct_editor_binding`).
##
## `--backend termassert-<defect>` plants one of the adapter's defects
## (stale-read, off-by-one, early-sync, read-side-effect), which the pack's
## mutation grade uses.

import std/[os, strutils, tables]
import demo_video_script/[backend, cli, jsonlines]
import demo_video_script_termassert
import ./ct_term_binding
import ./ct_editor_binding

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--serve":
    var defect = tdNone
    var editor = ""
    for a in args[1 .. ^1]:
      if a.startsWith("--defect="): defect = parseEnum[TermDefect](a[9 .. ^1])
      if a.startsWith("--editor="): editor = a[9 .. ^1]
    if editor.len > 0:
      serveJsonLines(newTermAssertBackend(ctEditorBinding(parseEnum[EditorKind](editor)), defect))
    else:
      serveJsonLines(newTermAssertBackend(ctTermBinding(), defect))
    quit 0
  var builtins = initTable[string, BackendFactory]()
  builtins["termassert"] = proc (): Backend = newTermAssertBackend(ctTermBinding())
  for d in [tdStaleRead, tdOffByOne, tdEarlySync, tdReadSideEffect]:
    let defect = d
    builtins["termassert-" & $d] = proc (): Backend = newTermAssertBackend(ctTermBinding(), defect)
  # one factory per editor; a closure made in the loop would share `k`
  proc editorFactory(kind: EditorKind): BackendFactory =
    result = proc (): Backend = newTermAssertBackend(ctEditorBinding(kind))
  for k in EditorKind:
    builtins["termassert-" & $k] = editorFactory(k)
  dvsMain(builtins)
