## The replay engine's bootstrap handshake, as a value rather than a callback.
##
## ## What has to happen, and why it cannot be one message
##
## `worker_backend.nim` owns the DAP protocol and knows nothing about how bytes
## reach the worker — deliberately, per its own header. But before a single DAP
## request can be sent, four things have to happen in order, each waiting on an
## acknowledgement from the worker:
##
##   1. `configure` — the worker dynamic-imports the wasm-bindgen glue from the
##      URL the entry document declared and instantiates the wasm. Answers
##      `wasm-loaded`, or `worker-error` with a reason.
##   2. one `vfs-write` per file — `trace.json`, `trace_metadata.json`, and the
##      recording's own source text under each recorded path. Each answers
##      `vfs-ack`.
##   3. `start` — hands `self.onmessage` to the wasm-side DAP dispatcher, which
##      answers with the bare string `"ready"`.
##   4. only then, `initialize` / `launch` / `configurationDone`.
##
## That sequence existed in exactly two places: `browser-replay`'s plain-JS
## `gateway-client.js` and an e2e test. Neither is reachable from the product,
## and a third hand-written copy inside a browser-only module would have been
## the first version of it nothing could test.
##
## ## So it is a state machine
##
## `ReplayBoot` is a plain object. `nextMessages` says what to post, `deliver`
## takes a control message and says what to post next, and `phase` says where
## it is. No `when defined(js)`, no worker, no promises — the `vm-unit` lane
## runs all of it, and the browser host is a loop that posts what it is handed.
##
## ## What it refuses
##
## An acknowledgement for a path that was never written is a defect, not a
## no-op: on a flat exact-match VFS it means the host and the engine disagree
## about a key, and the session that follows would resolve some positions and
## not others. A `vfs-ack` with `ok: false` fails the boot by name rather than
## proceeding to `start` with a file missing — the trace would then load,
## report success, and step through source the engine cannot display, which is
## precisely the false pass this path has.

import std/[json, strutils, tables]

import ../platform/replay_engine_vfs

type
  ReplayBootPhase* = enum
    ## Where the handshake is. Ordered, and it only ever moves forward.
    rbpConfiguring
      ## `configure` posted, waiting for `wasm-loaded`.
    rbpWriting
      ## Writing the trace and its source into the VFS, one ack at a time.
    rbpStarting
      ## `start` posted, waiting for the worker's `"ready"`.
    rbpReady
      ## The DAP dispatcher owns the worker. Requests may be sent.
    rbpFailed
      ## Terminal. `failure` says why, in a sentence a user can read.

  ReplayBoot* = object
    phase*: ReplayBootPhase
    failure*: string
      ## Empty unless `phase == rbpFailed`.
    payload*: ReplayVfsPayload
    acked*: seq[string]
      ## Paths the worker has confirmed, in ack order.
    unwritten: Table[string, bool]
      ## Paths posted and not yet acknowledged. A `Table` and not a count,
      ## because "three acks arrived" and "the three paths I wrote were
      ## acknowledged" are different claims and only the second is the one
      ## that matters on an exact-match key store.

const
  glueAssetId* = "replay-engine-glue"
  engineAssetId* = "replay-engine"
    ## The manifest's ids, and `replay-worker.js` looks its two URLs up by
    ## exactly these strings. A rename on one side produces "no url was
    ## declared for ..." in a browser and nothing at all before that.

proc failWith(boot: var ReplayBoot; reason: string): seq[JsonNode] =
  boot.phase = rbpFailed
  boot.failure = reason
  @[]

proc beginReplayBoot*(payload: ReplayVfsPayload;
                      moduleUrls: seq[tuple[id: string, url: string]]):
    tuple[boot: ReplayBoot, messages: seq[JsonNode]] =
  ## Start the handshake for `payload`, or refuse before posting anything.
  ##
  ## The payload's own defects are checked FIRST. A trace with no steps or no
  ## embedded source is not something to launch and report on afterwards; it
  ## is something not to launch. `replayVfsPayload` already cleared its file
  ## list for exactly that reason and this is the second half of the same
  ## decision.
  result.boot.payload = payload
  result.boot.acked = @[]
  result.boot.unwritten = initTable[string, bool]()
  result.messages = @[]

  if payload.defects.len > 0:
    result.messages = failWith(result.boot, payload.defects[0])
    return

  var urls = initTable[string, string]()
  for entry in moduleUrls:
    urls[entry.id] = entry.url
  for id in [glueAssetId, engineAssetId]:
    if id notin urls or urls[id].len == 0:
      result.messages = failWith(
        result.boot,
        "this deployment declares no url for `" & id & "`, so there is no " &
        "replay engine to step this trace in")
      return

  result.boot.phase = rbpConfiguring
  result.messages = @[%*{
    "type": "configure",
    "moduleUrls": {
      glueAssetId: urls[glueAssetId],
      engineAssetId: urls[engineAssetId]}}]

proc writeMessages(boot: var ReplayBoot): seq[JsonNode] =
  ## One `vfs-write` per file, and the paths recorded as outstanding.
  ##
  ## `data` is left as an array of byte values here. The browser host turns it
  ## into a `Uint8Array` before `postMessage`, because a structured clone of a
  ## JS array of numbers is not what `vfs_write_file(path, &[u8])` accepts —
  ## and that conversion is one line in one place rather than a shape this
  ## module has to know about.
  for file in boot.payload.files:
    boot.unwritten[file.path] = true
    var data = newJArray()
    for ch in file.content: data.add newJInt(ord(ch))
    result.add %*{"type": "vfs-write", "path": file.path, "data": data}

proc deliver*(boot: var ReplayBoot; message: JsonNode): seq[JsonNode] =
  ## Advance the handshake on one control message; answer with what to post.
  ##
  ## Unknown messages are ignored rather than treated as progress: the worker
  ## also emits `worker-status` lines and `vfs-exists-result`, and a state
  ## machine that advanced on anything at all would `start` before its writes
  ## landed.
  result = @[]
  if boot.phase in {rbpReady, rbpFailed}: return
  if message.isNil or message.kind != JObject: return

  let kind =
    if message.hasKey("type") and message["type"].kind == JString:
      message["type"].getStr
    elif message.hasKey("status") and message["status"].kind == JString:
      # `WorkerBackend.deliver` wraps the worker's bare `"ready"` string as
      # `{"type": "worker-status", "status": "ready"}`, so both spellings
      # reach here and both have to mean the same thing.
      "worker-status"
    else:
      ""

  case kind
  of "worker-error":
    let reason =
      if message.hasKey("error") and message["error"].kind == JString:
        message["error"].getStr
      else:
        "the replay worker failed without saying why"
    return failWith(boot, reason)

  of "wasm-loaded":
    if boot.phase != rbpConfiguring: return
    boot.phase = rbpWriting
    result = boot.writeMessages()
    # A payload that reached here with no files would post nothing, never be
    # acked, and sit in `rbpWriting` forever looking like it was working.
    if result.len == 0:
      return failWith(boot,
        "the trace produced no files to write, so there would be nothing " &
        "for the engine to open")

  of "vfs-ack":
    if boot.phase != rbpWriting: return
    let path =
      if message.hasKey("path") and message["path"].kind == JString:
        message["path"].getStr
      else:
        ""
    let ok = message.hasKey("ok") and message["ok"].kind == JBool and
             message["ok"].getBool
    if not ok:
      return failWith(boot,
        "the engine refused the file at `" & path & "`; every position in " &
        "the session would resolve to source it cannot display")
    if path notin boot.unwritten:
      # Not ignorable. On a flat exact-match key store this means the host and
      # the engine disagree about a path, and the session that followed would
      # resolve some positions and not others for no visible reason.
      return failWith(boot,
        "the engine acknowledged `" & path & "`, which was never written; " &
        "the host and the engine disagree about a VFS key")
    boot.unwritten.del path
    boot.acked.add path
    if boot.unwritten.len == 0:
      boot.phase = rbpStarting
      result = @[%*{"type": "start"}]

  of "worker-status":
    if boot.phase != rbpStarting: return
    let status =
      if message.hasKey("status") and message["status"].kind == JString:
        message["status"].getStr
      else:
        ""
    if status.strip == "ready":
      boot.phase = rbpReady

  else: discard

proc writtenPaths*(boot: ReplayBoot): seq[string] =
  ## Every path this boot posted, in post order.
  for file in boot.payload.files: result.add file.path

proc outstanding*(boot: ReplayBoot): int =
  ## Files posted and not yet acknowledged.
  boot.unwritten.len
