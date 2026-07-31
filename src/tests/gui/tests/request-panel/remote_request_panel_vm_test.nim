## remote_request_panel_vm_test.nim
##
## RS-M11 — ``vm_remote_request_panel_rows``.
##
## The codetracer-side half of the remote-live-session milestone: the HTTP
## Request Panel's ViewModel, driven by the payloads the **production remote
## tail actually emitted over a real HTTP socket** while a growing container
## was served with byte-range requests.
##
## Per
## ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
## §RS-M11, the required assertion is that "the panel's ViewModel observes each
## request remotely, with no sidecar transferred".  The transport half of that
## sentence is proved in
## ``src/db-backend/tests/remote_span_tail_http_test.rs``
## (``remote_live_panel_over_http_range``): a real ``TcpListener`` serving four
## growing snapshots of one session, a real ``HttpRangeSource``, server-side
## counters showing every response was a ``206 Partial Content`` and that the
## whole session moved 6 598 bytes against the 622 592 a downloading reader
## would have needed, and an assertion that the ONLY resource ever requested was
## the ``.ct`` itself.  This file is the other half: that the rows the panel
## renders from those payloads are the requests the recording actually contains.
##
## ## What is real here
##
## ``fixtures/remote_http_range/deltas.jsonl`` is a **capture, not a fixture in
## the hand-written sense**: each line is one ``RequestSpanDelta`` as
## ``remote_live_panel_over_http_range`` serialised it, in poll order, straight
## off the wire.  The Rust test re-derives it on every run and FAILS if it
## differs from the committed bytes, so this file can never drift away from
## what the remote reader emits.  Regenerate with
##
##   direnv exec ../.. env CT_REGENERATE_REMOTE_DELTA_FIXTURE=1 \
##     cargo test --test remote_span_tail_http_test remote_live_panel_over_http_range
##
## from ``src/db-backend``.
##
## The ground truth for the rows is **not** that capture.  It is the span-stream
## generator's own declaration —
## ``src/db-backend/tests/fixtures/span_stream/web_session_tail_stage{1..4}.expected.jsonl``,
## written from the values fed to the Nim writer rather than by re-reading any
## container — so neither the reader nor the transport can make the expectations
## agree with themselves.
##
## ## The property that makes this test meaningful
##
## The panel has NO remote code path.  A remote session is the same
## ``CtUpdatedHttpRequests`` body, the same merge-on-``id`` rule, the same
## opaque cursor.  That is exactly what "a remote live request panel needs no
## new protocol" has to mean, and it is why this test can be written at all:
## the ViewModel under test is the shipped one, unmodified, and it cannot tell
## that the bytes came from another machine.
##
## Mocking justification (per the workspace policy on mock objects): the only
## mock is ``MockBackendService``, used purely as the transport that carries an
## already-serialised delta into the store — exactly as in
## ``request_panel_live_vm_test.nim`` and the six language row tests.  There is
## no fake container, no fake reader and no fake span data: every byte replayed
## here was produced by the production remote reader from a real Nim-written
## container fetched over a real socket.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/remote_request_panel_vm_test.nim

import std/[algorithm, json, os, sequtils, strutils, unittest]
import isonim/core/[signals, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/request_panel_vm

const
  ThisDir = currentSourcePath.parentDir
  DeltaCapture = ThisDir / "fixtures" / "remote_http_range" / "deltas.jsonl"
  SpanFixtureDir = ThisDir / ".." / ".." / ".." / ".." / "db-backend" /
    "tests" / "fixtures" / "span_stream"

type
  ExpectedRow = object
    ## One request as the GENERATOR declared it, read from the stage's
    ## ``.expected.jsonl``.  Deliberately independent of anything the reader,
    ## the transport or the capture says.
    id: int
    httpMethod: string
    url: string
    statusCode: int

proc expectedRows(stage: int): seq[ExpectedRow] =
  ## The web requests the generator declared for tail stage ``stage``.
  let path = SpanFixtureDir / ("web_session_tail_stage" & $stage & ".expected.jsonl")
  doAssert fileExists(path), "missing span-stream ground truth: " & path
  for line in lines(path):
    if line.strip().len == 0:
      continue
    let node = parseJson(line)
    if node["span_type"].getStr != "web-request":
      continue
    let meta = node["metadata"]
    result.add ExpectedRow(
      id: node["span_id"].getInt,
      # The wire format carries every metadata value as a string.
      httpMethod: meta["http.method"].getStr,
      url: meta["http.url"].getStr,
      statusCode: parseInt(meta["http.status_code"].getStr("0")))
  result.sort(proc (a, b: ExpectedRow): int = cmp(a.id, b.id))

proc remoteDeltas(): seq[JsonNode] =
  ## The captured ``RequestSpanDelta`` bodies, in poll order.
  doAssert fileExists(DeltaCapture),
    "missing remote delta capture " & DeltaCapture &
    " — regenerate it with CT_REGENERATE_REMOTE_DELTA_FIXTURE=1 (see this file's header)"
  for line in lines(DeltaCapture):
    if line.strip().len > 0:
      result.add parseJson(line)

proc deltaEvent(body: JsonNode): JsonNode =
  ## The ``ct/updated-http-requests`` envelope as ``RealBackendService`` shapes
  ## it: the ``CtEventKind`` name in ``kind`` and the DAP body under ``data``
  ## (see ``viewmodel/backend/real_backend.nim``).  The body is passed through
  ## VERBATIM — anything this proc reshaped would be a place the test could
  ## paper over a wire-format change.
  %*{"kind": "CtUpdatedHttpRequests", "data": body}

proc ids(records: seq[RequestRecord]): seq[int] =
  result = newSeqOfCap[int](records.len)
  for r in records:
    result.add(r.id)

suite "RequestPanelVM over a remote HTTP-range live session":

  test "vm_remote_request_panel_rows":
    let deltas = remoteDeltas()
    check deltas.len == 4  # one poll per published stage

    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createRequestPanelVM(store)

      check vm.requests.val.len == 0

      for stage in 1 .. 4:
        mock.emitEvent(deltaEvent(deltas[stage - 1]))

        # The panel observes EACH request as the remote session grows.
        let want = expectedRows(stage)
        check vm.requests.val.ids == want.mapIt(it.id)
        for i, row in want:
          check vm.requests.val[i].httpMethod == row.httpMethod
          check vm.requests.val[i].url == row.url
          check vm.requests.val[i].statusCode == row.statusCode
          # A remote span is bound to a step range in the container it came
          # from, exactly as a local one is: this is what makes "jump to
          # handler" work over the network with no extra transport.
          check vm.requests.val[i].startGeid > 0'i64

        # The cursor the panel echoes back is the one the remote tail sent,
        # verbatim and uninterpreted.
        check store.requestSpans.cursor.val == deltas[stage - 1]["cursor"].getInt.int64
        check store.requestSpans.source.val == "span-stream"

      dispose()

  test "only the first remote delta is a snapshot":
    # A growing container never re-snapshots: every poll after the first is a
    # pure append the client merges. If this ever flipped, the panel would be
    # replacing its list on every poll and the range budget in the backend test
    # would be the only thing left saying the session was incremental.
    let deltas = remoteDeltas()
    check deltas[0]["reset"].getBool
    for i in 1 ..< deltas.len:
      check not deltas[i]["reset"].getBool
    # And the cursor advances monotonically, which is what makes it a cursor.
    for i in 1 ..< deltas.len:
      check deltas[i]["cursor"].getInt > deltas[i - 1]["cursor"].getInt

  test "no remote delta carries an external trace path":
    # Every span in this session is bound INLINE — the execution is in the very
    # container that was range-read. That is the shape the sidecar era could not
    # produce (a PHP `session_manifest.jsonl` row pointed at a separate trace
    # directory, which over a network is a second artifact to find and fetch),
    # and it is why one `.ct` is now sufficient.
    for delta in remoteDeltas():
      for span in delta["spans"]:
        check span["externalTracePath"].kind == JNull
        check span["startGeid"].getInt > 0
