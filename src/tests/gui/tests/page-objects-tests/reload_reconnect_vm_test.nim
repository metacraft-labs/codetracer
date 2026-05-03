## reload_reconnect_vm_test.nim
##
## Headless contract companion for:
##   page-objects-tests/reload_reconnect.spec.ts
##
## The browser test exercises a host/Electron reload boundary: `ct host`
## must replay the one-shot `ct/complete-move` DAP event to a freshly
## reconnected browser client so editor_service.onCompleteMove can reopen
## the source tab.  That cache/replay state is owned by the host bootstrap
## cache, not by a ViewModel/store signal.  These tests cover the nearest
## pure module; the remaining unrepresented boundary is Electron's
## webContents.send shim and the actual socket reconnect.

import std/[sequtils, strutils, unittest]

import ../../../../frontend/index/bootstrap_cache

proc replayed(cache: seq[BootstrapPayload]): seq[string] =
  var messages: seq[string] = @[]
  replayBootstrap(cache, proc(id: cstring, payload: cstring) =
    messages.add($id & ":" & $payload))
  messages

suite "ReloadReconnect bootstrap cache contract":

  test "ct/complete-move is the only replayed DAP event key":
    check bootstrapDapEventKey(cstring"ct/complete-move") ==
      cstring"ct/complete-move"
    check bootstrapDapEventKey(cstring"ct/updated-events") == cstring""
    check bootstrapDapEventKey(cstring"") == cstring""

  test "replayed complete-move survives reconnect with latest location":
    var cache: seq[BootstrapPayload] = @[]

    upsertBootstrap(cache, BootstrapPayload(
      id: cstring"CODETRACER::started",
      key: cstring"",
      payload: cstring"{}"))
    upsertBootstrap(cache, BootstrapPayload(
      id: cstring"CODETRACER::dap-receive-event",
      key: bootstrapDapEventKey(cstring"ct/complete-move"),
      payload: cstring"""{"event":"ct/complete-move","body":{"path":"old.nr","line":3}}"""))
    upsertBootstrap(cache, BootstrapPayload(
      id: cstring"CODETRACER::dap-receive-event",
      key: bootstrapDapEventKey(cstring"ct/complete-move"),
      payload: cstring"""{"event":"ct/complete-move","body":{"path":"ship.nr","line":17}}"""))

    let messages = replayed(cache)
    check messages.len == 2
    check messages[0] == "CODETRACER::started:{}"

    let completeMoves =
      messages.filterIt(it.startsWith("CODETRACER::dap-receive-event"))
    check completeMoves.len == 1
    check completeMoves[0].contains("\"path\":\"ship.nr\"")
    check completeMoves[0].contains("\"line\":17")
    check not completeMoves[0].contains("old.nr")

  test "legacy bootstrap payloads still upsert by channel":
    var cache: seq[BootstrapPayload] = @[]

    upsertBootstrap(cache, BootstrapPayload(
      id: cstring"CODETRACER::trace-loaded",
      key: cstring"",
      payload: cstring"""{"trace":1}"""))
    upsertBootstrap(cache, BootstrapPayload(
      id: cstring"CODETRACER::trace-loaded",
      key: cstring"",
      payload: cstring"""{"trace":2}"""))

    let messages = replayed(cache)
    check messages == @["CODETRACER::trace-loaded:{\"trace\":2}"]
