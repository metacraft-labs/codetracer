## Headless tests for the `MemoryTrace` → engine-VFS transform.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob. The subject is
## pure — no browser, no worker, no `when defined(js)` — so the backend the
## renderer ships on runs all of it.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_replay_engine_vfs.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_replay_engine_vfs.nim
##
## ## What this suite is for
##
## Two false passes live on this path, and every case below exists to red on
## one of them:
##
##   1. A trace that LOADS AND REPORTS SUCCESS WHILE CARRYING ZERO STEPS. An
##      artifact compiled without debug instrumentation traces to one event and
##      no steps; both wasm modules answer `ok` over it, the engine accepts the
##      `trace.json`, and the session opens onto an empty timeline. So the
##      counts are asserted as counts, and a step-less document is a defect
##      before anything is posted to a worker.
##   2. A session that RESOLVES POSITIONS THAT ARE ALL `missingPath`. In a
##      browser every recorded path is that case unless the trace's own source
##      text is written into the VFS under the recorded key — so a payload that
##      carries no source view is a defect too, and the key each view is filed
##      under is asserted against `paths[path_id]` rather than against the
##      view's own name.
##
## The fixture is a real `MemoryTrace` shape, byte-array `content` included,
## because `SourceView.content` is a `Vec<u8>` under plain serde and decoding
## it as a string yields empty source for every file while looking like it
## worked.

import std/[json, strutils, unittest]

import ../../platform/replay_engine_vfs

# ---------------------------------------------------------------------------
# Counted assertions. `counted` is a TEMPLATE so `check` is inlined into the
# `test` body where `testStatusIMPL` is in scope — inside a proc every check
# would print and still report [OK]. Same reasoning as
# `test_noir_wasm_delivery.nim`.
# ---------------------------------------------------------------------------
var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 67
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures — the shape `noir-tracer` actually answers.
# ---------------------------------------------------------------------------

const
  MainPath = "/virtual/a_1_mul/src/main.nr"
  RelativePath = "hello_noir/src/main.nr"
  MainSource = "fn main(x: Field, y: pub Field) {\n    assert(x * y == 6);\n}\n"

proc byteArray(text: string): JsonNode =
  result = newJArray()
  for ch in text: result.add newJInt(ord(ch))

proc memoryTrace(steps = 2; withSourceView = true; paths = @[MainPath];
                 workdir = ""): string =
  var events = newJArray()
  events.add %*{"Path": paths[0]}
  events.add %*{"Function": {"path_id": 0, "line": 1, "name": "<toplevel>"}}
  events.add %*{"Call": {"function_id": 0, "args": []}}
  for i in 0 ..< steps:
    events.add %*{"Step": {"path_id": 0, "line": i + 1}}
  var pathArray = newJArray()
  for path in paths: pathArray.add newJString(path)
  var views = newJArray()
  if withSourceView:
    views.add %*{
      "path_id": 0, "view_kind": 0, "view_name": paths[0],
      "content": byteArray(MainSource), "sourcemap": newJArray()}
  var document = %*{
    "events": events, "paths": pathArray, "line_lengths": newJArray(),
    "source_views": views, "capabilities": %*{}}
  if workdir.len > 0: document["workdir"] = newJString(workdir)
  $document

proc fileNamed(payload: ReplayVfsPayload; path: string): string =
  for file in payload.files:
    if file.path == path: return file.content
  ""

proc hasFile(payload: ReplayVfsPayload; path: string): bool =
  for file in payload.files:
    if file.path == path: return true
  false

suite "a browser-produced MemoryTrace becomes the files the engine reads":

  test "the trace lands at the two paths setup_from_vfs probes":
    let payload = replayVfsPayload(memoryTrace())
    counted payload.defects.len == 0
    counted payload.traceFolder == "trace"
    counted payload.hasFile("trace/trace.json")
    counted payload.hasFile("trace/trace_metadata.json")
    # `trace.json` is the EVENT ARRAY, not the whole document: the engine
    # decodes it as `Vec<TraceLowLevelEvent>` and a `{events: [...]}` object
    # fails to deserialize with an error naming serde rather than the shape.
    let events = parseJson(payload.fileNamed("trace/trace.json"))
    counted events.kind == JArray
    counted events.len == 5
    # And the metadata carries the one key the engine reads out of it.
    let meta = parseJson(payload.fileNamed("trace/trace_metadata.json"))
    counted meta.kind == JObject
    counted meta.hasKey("workdir")
    counted meta["workdir"].getStr == "/virtual/a_1_mul/src"

  test "an explicit workdir is preferred over the one derived from a path":
    let payload = replayVfsPayload(memoryTrace(workdir = "/virtual/a_1_mul"))
    counted payload.defects.len == 0
    let meta = parseJson(payload.fileNamed("trace/trace_metadata.json"))
    counted meta["workdir"].getStr == "/virtual/a_1_mul"

  test "the counts are counted, so a step-less trace cannot report success":
    # Arm 1 of the acceptance: the false pass is a trace that loads and reports
    # success while carrying zero steps.
    let good = replayVfsPayload(memoryTrace(steps = 7))
    counted good.steps == 7
    counted good.calls == 1
    counted good.defects.len == 0

    let stepless = replayVfsPayload(memoryTrace(steps = 0))
    counted stepless.steps == 0
    counted stepless.defects.len == 1
    counted "no steps" in stepless.defects[0]
    # Nothing is posted to a worker for a defective payload — a caller that
    # ignored `defects` would otherwise still get a launchable trace.
    counted stepless.files.len == 0

  test "an empty document is refused by name rather than by exception":
    for raw in ["", "not json at all", "[1,2,3]", "{}"]:
      let payload = replayVfsPayload(raw)
      counted payload.defects.len > 0
      counted payload.files.len == 0

  test "the source text is filed under the recorded path, verbatim":
    # Arm 2: without this the session resolves positions that are all
    # `missingPath`, which reads as success and displays nothing.
    let payload = replayVfsPayload(memoryTrace())
    counted payload.sourceViews == 1
    counted payload.sourceFileCount == 1
    counted payload.hasFile(MainPath)
    counted payload.fileNamed(MainPath) == MainSource
    # The key is `paths[path_id]` and NOT the view's own `view_name`, and not
    # a path under the trace folder: the engine probes the recorded string.
    counted not payload.hasFile("trace/" & MainPath)

  test "a byte-array content is decoded as bytes, not read as a string":
    # `SourceView.content` is a `Vec<u8>`. Under plain serde that is a JSON
    # array of integers; a reader that expected a string would produce empty
    # source for every file and every position would go dark with no error.
    let payload = replayVfsPayload(memoryTrace())
    let text = payload.fileNamed(MainPath)
    counted text.len == MainSource.len
    counted text.startsWith("fn main")
    counted text.endsWith("}\n")

  test "a trace that embeds no source is a defect, not a quiet degradation":
    let payload = replayVfsPayload(memoryTrace(withSourceView = false))
    counted payload.sourceViews == 0
    counted payload.defects.len == 1
    counted "no source text" in payload.defects[0]
    counted payload.files.len == 0

  test "a relative recorded path is written under BOTH spellings":
    # THIS CASE USED TO ASSERT A REFUSAL, and the refusal was wrong. The
    # reasoning behind it was right — the engine's flat key store is probed
    # bare by `find_real_path` and workdir-joined by `StepLinesLoader`, so one
    # key would satisfy one probe — but the conclusion was measured against
    # the engine and never against the product. The browser Noir compiler is
    # handed a virtual package tree and records `hello_noir/src/main.nr`.
    # Every trace a tab can produce is the refused case, so this module would
    # have rejected all of them and shown the user a defect naming the
    # engine's probe order.
    let payload = replayVfsPayload(memoryTrace(paths = @[RelativePath]))
    counted payload.defects.len == 0
    counted payload.sourceViews == 1
    # Both keys carry the same bytes, so whichever probe asks, it hits.
    counted payload.hasFile(RelativePath)
    counted payload.hasFile("trace/" & RelativePath)
    counted payload.fileNamed(RelativePath) == MainSource
    counted payload.fileNamed("trace/" & RelativePath) == MainSource
    # And the metadata names the workdir those keys were derived from, rather
    # than leaving the engine to fall back to a value this module did not use.
    let meta = parseJson(payload.fileNamed("trace/trace_metadata.json"))
    counted meta["workdir"].getStr == "trace"

  test "an absolute recorded path still writes exactly one key":
    # `PathBuf::join` discards the base for an absolute path, so all three
    # probes collapse onto one string and a second entry would be dead weight
    # in a map that holds a whole recording's source.
    counted vfsKeysFor(MainPath, "/anything").len == 1
    counted vfsKeysFor(MainPath, "/anything") == @[MainPath]
    counted vfsKeysFor(RelativePath, "trace") ==
      @[RelativePath, "trace/" & RelativePath]
    counted vfsKeysFor("", "trace").len == 0
    counted vfsKeysFor(RelativePath, "") == @[RelativePath]

  test "a location is retargeted to the spelling the renderer opens tabs by":
    # The compiler records `hello_noir/src/main.nr`; the renderer keys tabs by
    # `/hello_noir/src/main.nr`. A location handed to `editor_service` in the
    # compiler's spelling opens a SECOND, empty tab beside the one the user is
    # looking at, which is the failure that looks like it worked.
    counted rendererSpelling(RelativePath, "hello_noir", "/hello_noir") ==
      "/hello_noir/src/main.nr"
    # A path outside the package is passed through rather than having a slash
    # bolted on: inventing a project-relative identity for a stdlib source
    # would make a location claim the project contains a file it does not.
    counted rendererSpelling("std/option.nr", "hello_noir", "/hello_noir") ==
      "std/option.nr"
    counted rendererSpelling("", "hello_noir", "/hello_noir") == ""
    counted rendererSpelling(RelativePath, "", "/hello_noir") == RelativePath

    # The walk covers every `location` in a frame, not one known key: the
    # engine puts a `Location` in `ct/complete-move`'s body AND in a call, and
    # a rewrite that knew only the first would leave the calltrace pointing at
    # the compiler's spelling.
    var frame = %*{
      "event": "ct/complete-move",
      "body": {
        "location": {"path": RelativePath, "line": 3},
        "calls": [{"location": {"path": RelativePath, "line": 1}}]}}
    let rewritten = retargetLocationPaths(frame, "hello_noir", "/hello_noir")
    # A COUNT, because zero over a frame that carries a location is the silent
    # case — the session steps, the position resolves, and a second empty tab
    # opens.
    counted rewritten == 2
    counted frame["body"]["location"]["path"].getStr == "/hello_noir/src/main.nr"
    counted frame["body"]["calls"][0]["location"]["path"].getStr ==
      "/hello_noir/src/main.nr"
    # Idempotent: a frame that has already been retargeted is left alone, so a
    # host that installed the translation twice does not double-prefix.
    counted retargetLocationPaths(frame, "hello_noir", "/hello_noir") == 0

  test "vfsJoin is the engine's join, not the host's":
    # `os./` emits a backslash on a Windows build of this lane and the VFS key
    # is compared byte-for-byte against a `/`-joined probe.
    counted vfsJoin("trace", "trace.json") == "trace/trace.json"
    counted vfsJoin("trace/", "trace.json") == "trace/trace.json"
    counted vfsJoin("", "trace.json") == "trace.json"

  test "a caller may name the folder the engine launches against":
    let payload = replayVfsPayload(memoryTrace(), traceFolder = "session-4")
    counted payload.defects.len == 0
    counted payload.hasFile("session-4/trace.json")
    counted payload.hasFile("session-4/trace_metadata.json")
    counted not payload.hasFile("trace/trace.json")
    # The source view is NOT under the folder — its key is the recorded path.
    counted payload.hasFile(MainPath)
    counted payload.sourceFileCount == 1

  test "the assertion count is measured":
    ## Every case above runs its checks through `counted`, so this number
    ## moving without a deliberate edit means a case stopped asserting.
    check countedAssertions == ExpectedAssertions
