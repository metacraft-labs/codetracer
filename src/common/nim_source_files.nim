## nim_source_files.nim — which files hold Nim source.
##
## Pure string logic, with no filesystem access, so the JavaScript desktop
## build (which compiles `viewmodel/viewmodels/nim_tracing_vm`) can use it as
## well as the native hosts and `ct`.

import std/strutils

func isNimSource*(path: string): bool =
  ## A `.nim` file, or a NimScript one: both hold compile-time code.
  let p = path.toLowerAscii
  p.endsWith(".nim") or p.endsWith(".nims")
