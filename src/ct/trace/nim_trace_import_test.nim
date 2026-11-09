## nim_trace_import_test.nim — the desktop's Nim trace route, server side.
##
## nimsuggest writes a macro or static-block trace as a bare `.ct` under its
## nimcache, and nothing registers it, so the desktop's trace store could not
## find it by path and opened nothing. This pins what `importNimTraceFile`
## (the `ct trace-metadata --import-ct` route the desktop's main process runs)
## does about that: the `.ct` is laid out in a folder of the trace store with
## the traced sources beside it under `files/`, that folder is registered, and
## the row the main process loads is returned. The terminal and GPUI lay the
## same trace out in `host/native_nim_tracer`.
##
## Mocks: none. The container is a real CTFS fixture (the db-backend's own
## `xos_hello.ct`), the store is the lane's isolated CODETRACER_HOME, and the
## registration goes through the production `importTrace`.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/nim_trace_import_test \
##       src/ct/trace/nim_trace_import_test.nim

import std/[os, unittest, tempfiles, strutils, algorithm]
import ../../common/[trace_index, paths]
import nim_trace_import

const fixtureCt = currentSourcePath.parentDir /
  "../../db-backend/tests/fixtures/xos/xos_hello.ct"

proc bundledPath(folder, source: string): string =
  ## Where a source copied into `folder` lives: `files/<absolute path>`.
  folder / "files" / absolutePath(source).strip(leading = true,
    trailing = false, chars = {'/'})

suite "the desktop's Nim trace is registered and laid out like the native route":

  test "a bare nimsuggest .ct is registered in a folder of its own, sources beside it":
    let work = createTempDir("ct-nim-trace-import-", "")
    defer: removeDir(work)
    let nimcache = work / "nimcache"
    createDir(nimcache)
    let ct = nimcache / "static_trace_20.ct"
    copyFile(fixtureCt, ct)
    let src = work / "project"
    createDir(src)
    writeFile(src / "main.nim", "echo 1\n")
    writeFile(src / "helper.nim", "proc h* = discard\n")
    writeFile(src / "notes.txt", "not a source\n")

    let trace = importNimTraceFile(ct, src / "main.nim")

    check not trace.isNil
    # The folder is the trace store's own layout for the recording, not the
    # nimcache: a second request for the same file cannot clobber the first.
    check trace.outputFolder == recordingFolder(codetracerTraceDir,
      trace.recordingId)
    check fileExists(trace.outputFolder / "trace.ct")
    # The traced file and the Nim files beside it are carried in `files/`,
    # where the replay server reads a recording's source.
    check fileExists(bundledPath(trace.outputFolder, src / "main.nim"))
    check fileExists(bundledPath(trace.outputFolder, src / "helper.nim"))
    check not fileExists(bundledPath(trace.outputFolder, src / "notes.txt"))
    # The registration is what the desktop's lookup finds by path.
    let registered = findByPath(trace.outputFolder, test = false)
    check not registered.isNil
    if not registered.isNil:
      check registered.recordingId == trace.recordingId
    # The nimcache file is left as nimsuggest wrote it.
    check fileExists(ct)

  test "each request for the same .ct is its own recording":
    let work = createTempDir("ct-nim-trace-import-twice-", "")
    defer: removeDir(work)
    let ct = work / "static_trace_7.ct"
    copyFile(fixtureCt, ct)

    let first = importNimTraceFile(ct, "")
    let second = importNimTraceFile(ct, "")

    check not first.isNil
    check not second.isNil
    check first.recordingId != second.recordingId
    check dirExists(first.outputFolder)
    check dirExists(second.outputFolder)

  test "a file that is not a trace is refused and leaves no folder behind":
    let work = createTempDir("ct-nim-trace-import-bad-", "")
    defer: removeDir(work)
    let ct = work / "static_trace_9.ct"
    writeFile(ct, "not a CTFS container\n")

    proc storeFolders(): seq[string] =
      for kind, path in walkDir(codetracerTraceDir):
        if kind == pcDir:
          result.add path
      result.sort()
    let before = storeFolders()

    var raised = false
    try:
      discard importNimTraceFile(ct, "")
    except CatchableError:
      raised = true
    check raised
    check storeFolders() == before

  test "a missing .ct is refused, naming the path it was asked for":
    let missing = getTempDir() / "ct-no-such-static_trace_1.ct"
    var raised = false
    try:
      discard importNimTraceFile(missing, "")
    except IOError as e:
      raised = true
      check missing in e.msg
    check raised
