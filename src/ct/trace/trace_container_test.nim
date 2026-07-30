## Unit tests for recording-folder shape detection.
##
## Run with:
##
## ```
##   nim c -r --hints:off src/ct/trace/trace_container_test.nim
## ```
##
## These cover the classification that decides whether `ct` opens a
## folder as a CTFS recording, a materialized `runtime_tracing`
## recording, a multi-recording session, or refuses it — and the wording
## of the refusal, which is a user-facing contract (M41 deliverable 2:
## "`findCtFileInFolder`'s failure on a directory named `*.ct` reports
## what it actually wants").
##
## No mocks: every case writes real files into a real temporary
## directory and runs the production detector against them.

import
  std / [ os, unittest, strutils ],
  trace_container

proc scratchDir(name: string): string =
  ## Fresh, empty scratch directory for one test case.
  result = getTempDir() / "ct-trace-container-test" / name
  removeDir(result)
  createDir(result)

proc writeCtfsFile(path: string) =
  ## Write a file that passes the CTFS magic check.  Only the 5-byte
  ## header matters to the detector.
  var f = open(path, fmWrite)
  defer: f.close()
  var magic = CtfsMagic
  discard f.writeBytes(magic, 0, magic.len)
  f.write("payload")

suite "recording folder shape detection":
  test "a CTFS container file is detected":
    let dir = scratchDir("ctfs")
    writeCtfsFile(dir / "trace.ct")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeCtfs
    check shape.path == dir / "trace.ct"

  test "a non-canonically named CTFS container is detected":
    let dir = scratchDir("ctfs-named")
    writeCtfsFile(dir / "server.ct")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeCtfs
    check shape.path == dir / "server.ct"

  test "a `.ct` file without the CTFS magic is not a container":
    # A stray note or placeholder must not shadow a real recording, and
    # must not be reported as a loadable trace.
    let dir = scratchDir("ctfs-fake")
    writeFile(dir / "notes.ct", "not a container")
    check detectTraceFolderShape(dir).kind == TraceShapeMissing
    check findCtFileInFolder(dir) == ""

  test "the canonical trace.ct wins over other containers":
    let dir = scratchDir("ctfs-multi")
    writeCtfsFile(dir / "aaa.ct")
    writeCtfsFile(dir / "trace.ct")
    check findCtFileInFolder(dir) == dir / "trace.ct"

  test "a materialized runtime_tracing directory is detected":
    # This is what `ct record-web` writes for browser recordings.
    let dir = scratchDir("materialized")
    writeFile(dir / "trace.json", "[]")
    writeFile(dir / "trace_metadata.json", """{"program":"frontend"}""")
    writeFile(dir / "trace_paths.json", "[]")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeMaterialized
    check shape.path == dir / "trace.json"

  test "a binary materialized recording is detected":
    let dir = scratchDir("materialized-bin")
    writeFile(dir / "trace.bin", "\x00\x01")
    check detectTraceFolderShape(dir).kind == TraceShapeMaterialized

  test "CTFS wins over a materialized sidecar in the same folder":
    # M-REC-1.5 keeps the container authoritative when both are present.
    let dir = scratchDir("both")
    writeCtfsFile(dir / "trace.ct")
    writeFile(dir / "trace.json", "[]")
    check detectTraceFolderShape(dir).kind == TraceShapeCtfs

  test "a session manifest wins over any single recording beside it":
    # Opening one member of a session would silently show a fraction of
    # the program, so the manifest must take precedence.
    let dir = scratchDir("session")
    writeFile(dir / SESSION_MANIFEST_FILE, "version = 1\n")
    writeCtfsFile(dir / "trace.ct")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeSession
    check shape.path == dir / SESSION_MANIFEST_FILE

  test "callers can opt out of the session interpretation":
    # The per-`[[trace]]` import inside a session needs the
    # single-recording reading of the same folder.
    let dir = scratchDir("session-optout")
    writeFile(dir / SESSION_MANIFEST_FILE, "version = 1\n")
    writeCtfsFile(dir / "trace.ct")
    check detectTraceFolderShape(dir, allowSession = false).kind ==
      TraceShapeCtfs

  test "an empty folder holds no recording":
    let dir = scratchDir("empty")
    check detectTraceFolderShape(dir).kind == TraceShapeMissing

suite "missing-recording diagnostics":
  test "a folder of `*.ct` DIRECTORIES explains that they are not containers":
    # The regression this pins: the pre-M41 message was "trace folder
    # missing `.ct` CTFS container" printed against a folder that
    # visibly contains `backend.ct`, which reads as a CodeTracer bug.
    let dir = scratchDir("ct-dirs")
    createDir(dir / "frontend.ct")
    createDir(dir / "backend.ct")
    let message = describeMissingTraceContainer(dir)
    check "backend.ct" in message
    check "frontend.ct" in message
    check "not container files" in message
    # It must point at both ways out: a session manifest, or opening one
    # recording directly.
    check SESSION_MANIFEST_FILE in message
    check "--trace-path" in message

  test "the accepted shapes are named":
    let dir = scratchDir("diag-shapes")
    let message = describeMissingTraceContainer(dir)
    check "trace.json" in message
    check "trace.bin" in message
    check "the folder is empty" in message

  test "a missing folder says so rather than blaming the container":
    let missing = getTempDir() / "ct-trace-container-test" / "definitely-absent"
    removeDir(missing)
    check "does not exist" in describeMissingTraceContainer(missing)

  test "a file passed where a folder was expected says so":
    let dir = scratchDir("diag-file")
    let file = dir / "some-file"
    writeFile(file, "x")
    check "is a file" in describeMissingTraceContainer(file)
