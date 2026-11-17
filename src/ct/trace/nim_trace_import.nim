## nim_trace_import.nim — registering a Nim compile-time trace the desktop
## asked for, from the path nimsuggest wrote it to.
##
## nimsuggest writes a macro or static-block trace as a bare `.ct` under its
## nimcache. Nothing registers that file, and the trace store finds a
## recording by its output folder, so the desktop could not open it. The
## terminal and GPUI lay such a trace out in a folder of its own
## (`viewmodel/host/native_nim_tracer`). This does the same for the desktop:
## the `.ct` is copied into a fresh folder of the trace store with the traced
## sources beside it under `files/`, and that folder is registered in place.
##
## Each call takes a fresh recording id, so a second request for the same
## nimcache file is a second recording and never clashes with the first. The
## nimcache file is left as nimsuggest wrote it.

import std/os
import ../../common/[trace_index, lang, types, paths, nim_trace_bundle]
import storage_and_import, trace_container, trace_kind

proc importNimTraceFile*(ctPath, sourcePath: string): Trace =
  ## Registers the `.ct` at `ctPath` as a recording in a folder of its own,
  ## bundling the Nim sources beside `sourcePath` when it is given, and returns
  ## its trace row. Raises `IOError` when there is no file at `ctPath` or the
  ## recording cannot be registered.
  if not fileExists(ctPath):
    raise newException(IOError, "no trace at " & ctPath)
  let recordingId = trace_index.newID(test = false)
  let folder = recordingFolder(codetracerTraceDir, recordingId)
  createDir(folder)
  try:
    copyFile(ctPath, folder / CANONICAL_CT_FILE)
    if sourcePath.len > 0:
      bundleNimTraceSources(folder, sourcePath)
    # Registered in place: `importTrace` with an explicit id keeps the folder
    # where it is, so the sources bundled above stay beside the container.
    result = importTrace(folder, recordingId, NO_PID, LangUnknown,
      traceKind = traceKindString(detectTraceKind(folder)))
    if result.isNil:
      raise newException(IOError, "could not register " & folder)
  except CatchableError:
    # A recording that did not register must not leave a folder behind: each
    # failed request would otherwise add one the trace store never lists.
    removeDir(folder)
    raise
