## nim_trace_bundle.nim — the sources a Nim trace steps through, copied into
## the trace's own folder.
##
## A recording is a folder holding its `.ct` container and the sources it
## steps through, at `files/<absolute path>`: that is where `replay-server`
## reads a recording's source. The compiler's tracer records paths and not
## text, so the copy is made here, from the file that was traced and the Nim
## files beside it (what it imports from its own folder).
##
## Shared by the native hosts (the terminal and GPUI, `host/native_nim_tracer`)
## and by `ct trace-metadata --import-ct`, which the desktop's main process
## runs, so every front-end lays a Nim trace out the same way.

import std/[os, strutils]
import nim_source_files

proc bundleNimTraceSources*(folder, source: string) =
  ## Copies the Nim sources beside `source` (the traced file included) into
  ## `folder/files/<absolute path>`. A file that cannot be copied is skipped:
  ## the trace still opens, and the replay reads that source from the paths
  ## the trace records.
  let dir = source.parentDir
  for kind, path in walkDir(dir):
    if kind notin {pcFile, pcLinkToFile} or not isNimSource(path):
      continue
    let target = folder / "files" / absolutePath(path).strip(
      leading = true, trailing = false, chars = {'/'})
    try:
      createDir(target.parentDir)
      copyFile(path, target)
    except CatchableError:
      discard
