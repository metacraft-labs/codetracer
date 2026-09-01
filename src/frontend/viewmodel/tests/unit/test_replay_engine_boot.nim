## Headless tests for the replay engine's bootstrap handshake.
##
## LANE: `vm-unit` AND `vm-unit-js`, both by the directory glob. The subject is
## a state machine over JSON, so the backend the renderer ships on runs it.
##
## Compile and run:
##   nim c  -r src/frontend/viewmodel/tests/unit/test_replay_engine_boot.nim
##   nim js -r src/frontend/viewmodel/tests/unit/test_replay_engine_boot.nim
##
## ## What this suite is for
##
## The handshake is four steps that each wait on an acknowledgement, and every
## way of getting it wrong produces a session that looks like it worked:
##
##   * `start` before the writes land — the engine opens a trace folder whose
##     `trace.json` is not there yet, or is there without its source, and the
##     session reports success over a timeline with nothing in it.
##   * an ack for a path nobody wrote — on a flat exact-match VFS that is the
##     host and the engine disagreeing about a key, and the session resolves
##     some positions and not others with no error anywhere.
##   * a boot that advances on any message at all — the worker also emits
##     `worker-status` and `vfs-exists-result`.
##
## Each case below reds on one of those. The counts are asserted as counts
## because "it reached `rbpReady`" is exactly the claim a broken sequence also
## makes.

import std/[json, strutils, unittest]

import ../../backend/replay_engine_boot
import ../../platform/replay_engine_vfs

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 70
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

const
  MainPath = "/virtual/a_1_mul/src/main.nr"
  MainSource = "fn main(x: Field) {\n    assert(x == 6);\n}\n"

proc byteArray(text: string): JsonNode =
  result = newJArray()
  for ch in text: result.add newJInt(ord(ch))

proc memoryTrace(steps = 3; withSourceView = true): string =
  var events = newJArray()
  events.add %*{"Path": MainPath}
  events.add %*{"Call": {"function_id": 0, "args": []}}
  for i in 0 ..< steps:
    events.add %*{"Step": {"path_id": 0, "line": i + 1}}
  var views = newJArray()
  if withSourceView:
    views.add %*{
      "path_id": 0, "view_kind": 0, "view_name": MainPath,
      "content": byteArray(MainSource), "sourcemap": newJArray()}
  $(%*{"events": events, "paths": [MainPath], "line_lengths": newJArray(),
       "source_views": views, "capabilities": %*{},
       "workdir": "/virtual/a_1_mul"})

proc urls(): seq[tuple[id: string, url: string]] =
  @[(id: glueAssetId, url: "/assets/db_backend.js"),
    (id: engineAssetId, url: "/assets/db_backend_bg.wasm")]

proc ackFor(path: string; ok = true): JsonNode =
  %*{"type": "vfs-ack", "path": path, "ok": ok}

suite "the replay engine's bootstrap handshake":

  test "configure carries the two urls the worker looks up by id":
    let (boot, messages) = beginReplayBoot(
      replayVfsPayload(memoryTrace()), urls())
    counted boot.phase == rbpConfiguring
    counted boot.failure.len == 0
    counted messages.len == 1
    counted messages[0]["type"].getStr == "configure"
    let moduleUrls = messages[0]["moduleUrls"]
    counted moduleUrls.hasKey(glueAssetId)
    counted moduleUrls.hasKey(engineAssetId)
    counted moduleUrls[glueAssetId].getStr == "/assets/db_backend.js"
    counted moduleUrls[engineAssetId].getStr == "/assets/db_backend_bg.wasm"
    # The ids are the manifest's, and `replay-worker.js` reads them verbatim.
    counted glueAssetId == "replay-engine-glue"
    counted engineAssetId == "replay-engine"

  test "the whole sequence, with the counts asserted at each step":
    var (boot, messages) = beginReplayBoot(
      replayVfsPayload(memoryTrace()), urls())
    counted messages.len == 1

    # 1. configure -> wasm-loaded, which releases the writes.
    let writes = boot.deliver(%*{"type": "wasm-loaded"})
    counted boot.phase == rbpWriting
    # trace.json, trace_metadata.json, and one source file. Asserted as a
    # NUMBER: a boot that wrote the trace and forgot the source would reach
    # `rbpReady` just as happily and resolve every position to `missingPath`.
    counted writes.len == 3
    counted boot.outstanding == 3
    var paths: seq[string]
    for write in writes:
      counted write["type"].getStr == "vfs-write"
      counted write["data"].kind == JArray
      paths.add write["path"].getStr
    counted "trace/trace.json" in paths
    counted "trace/trace_metadata.json" in paths
    counted MainPath in paths

    # The source bytes survive the trip as bytes.
    for write in writes:
      if write["path"].getStr == MainPath:
        counted write["data"].len == MainSource.len
        counted write["data"][0].getInt == ord('f')

    # 2. the acks, one at a time. `start` must not appear until the last.
    counted boot.deliver(ackFor(paths[0])).len == 0
    counted boot.phase == rbpWriting
    counted boot.deliver(ackFor(paths[1])).len == 0
    counted boot.phase == rbpWriting
    counted boot.outstanding == 1
    let starts = boot.deliver(ackFor(paths[2]))
    counted starts.len == 1
    counted starts[0]["type"].getStr == "start"
    counted boot.phase == rbpStarting
    counted boot.outstanding == 0
    counted boot.acked.len == 3

    # 3. the worker's bare "ready", as `WorkerBackend.deliver` wraps it.
    counted boot.deliver(%*{"type": "worker-status", "status": "ready"}).len == 0
    counted boot.phase == rbpReady

  test "an unrelated message is not progress":
    var (boot, _) = beginReplayBoot(replayVfsPayload(memoryTrace()), urls())
    counted boot.deliver(%*{"type": "vfs-exists-result",
                            "path": "trace/trace.ct", "exists": false}).len == 0
    counted boot.phase == rbpConfiguring
    discard boot.deliver(%*{"type": "wasm-loaded"})
    counted boot.phase == rbpWriting
    # A status line in the middle of the writes must not start the engine.
    counted boot.deliver(%*{"type": "worker-status", "status": "ready"}).len == 0
    counted boot.phase == rbpWriting
    counted boot.outstanding == 3

  test "an ack for a path nobody wrote fails the boot by name":
    # On a flat exact-match key store this is the host and the engine
    # disagreeing about a VFS key, and the session that followed would resolve
    # some positions and not others with no error anywhere.
    var (boot, _) = beginReplayBoot(replayVfsPayload(memoryTrace()), urls())
    discard boot.deliver(%*{"type": "wasm-loaded"})
    let response = boot.deliver(ackFor("/virtual/somewhere/else.nr"))
    counted response.len == 0
    counted boot.phase == rbpFailed
    counted "never written" in boot.failure
    # And it stays failed: a later, correct ack must not resurrect it.
    counted boot.deliver(ackFor("trace/trace.json")).len == 0
    counted boot.phase == rbpFailed

  test "a refused write fails the boot rather than starting anyway":
    var (boot, _) = beginReplayBoot(replayVfsPayload(memoryTrace()), urls())
    discard boot.deliver(%*{"type": "wasm-loaded"})
    counted boot.deliver(ackFor("trace/trace.json", ok = false)).len == 0
    counted boot.phase == rbpFailed
    counted "refused" in boot.failure

  test "a worker that cannot instantiate the engine says so":
    var (boot, _) = beginReplayBoot(replayVfsPayload(memoryTrace()), urls())
    counted boot.deliver(%*{"type": "worker-error",
                            "error": "no url was declared for `replay-engine`"}).len == 0
    counted boot.phase == rbpFailed
    counted "replay-engine" in boot.failure

  test "a deployment with no engine refuses before posting anything":
    for partial in [@[(id: glueAssetId, url: "/assets/db_backend.js")],
                    @[(id: engineAssetId, url: "/assets/db_backend_bg.wasm")],
                    newSeq[tuple[id: string, url: string]]()]:
      let (boot, messages) = beginReplayBoot(
        replayVfsPayload(memoryTrace()), partial)
      counted boot.phase == rbpFailed
      counted messages.len == 0
      counted "no url" in boot.failure

  test "a defective trace never reaches a worker at all":
    # Arm 1 of the acceptance, at this layer: the false pass is a trace that
    # loads and reports success while carrying zero steps. It must not be
    # posted, warned about, and launched anyway.
    let stepless = replayVfsPayload(memoryTrace(steps = 0))
    counted stepless.defects.len > 0
    let (a, aMessages) = beginReplayBoot(stepless, urls())
    counted a.phase == rbpFailed
    counted aMessages.len == 0
    counted "no steps" in a.failure

    # Arm 2: a session that resolves positions that are all `missingPath`.
    let sourceless = replayVfsPayload(memoryTrace(withSourceView = false))
    let (b, bMessages) = beginReplayBoot(sourceless, urls())
    counted b.phase == rbpFailed
    counted bMessages.len == 0
    counted "no source text" in b.failure

  test "the assertion count is measured":
    check countedAssertions == ExpectedAssertions
