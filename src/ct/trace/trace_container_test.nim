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

suite "recordings one level below the requested folder":
  ## Some recorders treat `--out-dir` as the recording's PARENT:
  ## codetracer-js-recorder writes `<out-dir>/trace-<n>/` and
  ## codetracer-php-recorder writes `<out-dir>/worker_<pid>/`. Without
  ## the one-level descent `ct record app.js` recorded successfully and
  ## then died in importTrace with "no recording found".

  test "a single CTFS recording one level down is found":
    let dir = scratchDir("nested-ctfs")
    createDir(dir / "trace-0")
    writeCtfsFile(dir / "trace-0" / "trace.ct")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeCtfs
    check shape.path == dir / "trace-0" / "trace.ct"
    # The payload folder must be the nested one, not the parent — the
    # importer reads sidecars out of `shape.folder`.
    check shape.folder == dir / "trace-0"

  test "a single materialized recording one level down is found":
    let dir = scratchDir("nested-materialized")
    createDir(dir / "trace-0")
    writeFile(dir / "trace-0" / "trace.json", "[]")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeMaterialized
    check shape.folder == dir / "trace-0"

  test "the folder's own recording wins over anything below it":
    let dir = scratchDir("nested-shadowed")
    writeCtfsFile(dir / "trace.ct")
    createDir(dir / "trace-0")
    writeCtfsFile(dir / "trace-0" / "trace.ct")
    check detectTraceFolderShape(dir).path == dir / "trace.ct"

  test "several recordings one level down are ambiguous":
    # The multi-worker PHP layout. Picking one arbitrarily would
    # silently open the wrong worker, so the caller has to say which.
    let dir = scratchDir("nested-ambiguous")
    for worker in ["worker_1", "worker_2"]:
      createDir(dir / worker)
      writeCtfsFile(dir / worker / "trace.ct")
    check detectTraceFolderShape(dir).kind == TraceShapeMissing
    let message = describeMissingTraceContainer(dir)
    check "worker_1" in message
    check "worker_2" in message
    check "ambiguous" in message

  test "descent never runs two levels down":
    let dir = scratchDir("nested-deep")
    createDir(dir / "a")
    createDir(dir / "a" / "b")
    writeCtfsFile(dir / "a" / "b" / "trace.ct")
    check detectTraceFolderShape(dir).kind == TraceShapeMissing

  test "callers can switch descent off":
    let dir = scratchDir("nested-optout")
    createDir(dir / "trace-0")
    writeCtfsFile(dir / "trace-0" / "trace.ct")
    check detectTraceFolderShape(dir, descend = false).kind ==
      TraceShapeMissing

suite "descent must never open one member of a session":
  ## The regression guarded here is a real one: the committed fixture
  ## `src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm`
  ## is a session whose members are DIRECTORIES named `frontend.ct`,
  ## `frontend-wasm.ct` (materialized) and `backend.ct` (holding a real
  ## CTFS container at `backend.ct/server.ct`). An unguarded one-level
  ## search finds exactly ONE container there — the backend — and would
  ## open a third of the program with no error at all.

  proc writeSessionFixture(dir: string) =
    writeFile(dir / SESSION_MANIFEST_FILE, "version = 1\n")
    createDir(dir / "frontend.ct")
    writeFile(dir / "frontend.ct" / "trace.json", "[]")
    createDir(dir / "frontend-wasm.ct")
    writeFile(dir / "frontend-wasm.ct" / "trace.json", "[]")
    createDir(dir / "backend.ct")
    writeCtfsFile(dir / "backend.ct" / "server.ct")

  test "a session folder is a session, not its backend member":
    let dir = scratchDir("session-descent")
    writeSessionFixture(dir)
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeSession
    check shape.path == dir / SESSION_MANIFEST_FILE

  test "opting out of sessions still does not flatten one to a member":
    # `importTrace` passes `allowSession = false` because a session
    # belongs to `importSessionManifest`. It must get "no recording
    # here" and raise, NOT the backend recording.
    let dir = scratchDir("session-descent-optout")
    writeSessionFixture(dir)
    check detectTraceFolderShape(dir, allowSession = false).kind ==
      TraceShapeMissing

  test "a lone member under a manifest is still not the session":
    # The narrowest form of the same bug: descent finding exactly one
    # nested recording is precisely the case that looks unambiguous.
    let dir = scratchDir("session-descent-single")
    writeFile(dir / SESSION_MANIFEST_FILE, "version = 1\n")
    createDir(dir / "backend.ct")
    writeCtfsFile(dir / "backend.ct" / "server.ct")
    check detectTraceFolderShape(dir, allowSession = false).kind ==
      TraceShapeMissing
    check detectTraceFolderShape(dir).kind == TraceShapeSession

  test "a nested session is reported as a session, not flattened":
    let dir = scratchDir("session-nested")
    createDir(dir / "run")
    writeFile(dir / "run" / SESSION_MANIFEST_FILE, "version = 1\n")
    writeCtfsFile(dir / "run" / "trace.ct")
    let shape = detectTraceFolderShape(dir)
    check shape.kind == TraceShapeSession
    check shape.folder == dir / "run"

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
