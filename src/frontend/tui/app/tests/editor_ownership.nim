## editor_ownership.nim — test support: whether a key is the EDITOR's.
##
## The terminal has no such query of its own: every key goes through the one
## router (`viewmodel/keymap/keymap_router`), and the suites ask the same
## router what a key WOULD do (`runtime.probeKey`, no effect). A key is the
## editor's when the editor pane has the focus and the resolution types it, or
## names an operation (or a pending prefix) in the editor's own layer.
##
## No stand-ins: the shipped runtime, its focus ring and its router.

import std/strutils

import codetracer_embed

import ../runtime
import ../input/motions

proc editorOwnsToken*(rt: TuiRuntime; token: string): bool =
  let (had, focused) = rt.focus.focusedPane()
  if not had or focused != paneEditor:
    return false
  let res = rt.probeKey(rt.keyOf(token))
  res.kind == erCharacter or
    (res.kind in {erOperation, erPending} and res.layer.endsWith(":editor"))
