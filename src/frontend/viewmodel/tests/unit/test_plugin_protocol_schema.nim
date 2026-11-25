## test_plugin_protocol_schema.nim — pins the plugin protocol's wire format
## (Extensibility-Model.md §11.4), owned by `plugin_host/protocol.nim`.
##
## Pure: no process, no session, no stand-in of any kind. A change to the wire
## — a message type added or renamed, the framing's byte order, a limit, the
## view codec — turns a case here red, so it is a decision rather than drift.

import std/[json, sequtils, strutils, tables, unittest]

import plugin_host/protocol
import ../../../../common/view_vocabulary/vocabulary

suite "§11.4.1: framing":

  test "a frame is a 4-byte big-endian length, then the JSON":
    let f = encodeFrame("""{"type":"ping"}""")
    check f.len == 4 + 15
    check f[0 .. 3] == "\x00\x00\x00\x0f"
    check f[4 .. ^1] == """{"type":"ping"}"""

  test "frames split across reads come out whole, in order":
    var r: FrameReader
    let a = encodeFrame("one")
    let b = encodeFrame("two")
    let all = a & b
    var got: seq[string]
    for i in 0 ..< all.len:
      r.feed($all[i])
      var frame: string
      while r.next(frame) == fsFrame:
        got.add frame
    check got == @["one", "two"]
    check r.buffered == 0

  test "a frame over 4 MiB is refused on both sides":
    check MaxProtocolFrameBytes == 4 * 1024 * 1024
    check encodeFrame(newString(MaxProtocolFrameBytes + 1)) == ""
    var r: FrameReader
    let n = MaxProtocolFrameBytes + 1
    r.feed(chr((n shr 24) and 0xff) & chr((n shr 16) and 0xff) &
           chr((n shr 8) and 0xff) & chr(n and 0xff))
    var frame: string
    check r.next(frame) == fsOversize

  test "a frame of several MiB is written and read back whole, on every backend":
    # Up to the cap, a frame's size is the sender's business, and the hosts
    # that run the wire on the JavaScript backend (the desktop's main
    # process, `ct host`) send large ones: a mirrored batch carries the
    # stop's locals, and a module's include `__builtins__`. There, appending
    # the payload with `add` was one call with a byte per argument and threw
    # past ~100 000 bytes, so the batch was never sent and the plugin's mirror
    # stopped at the revision before it (codetracer-pm issues/
    # 2026-11-24-under-ct-host-a-plugins-mirror-never-learns-what-a-step-changed.md).
    let big = "x".repeat(3 * 1024 * 1024)
    let msg = %*{"type": "signal-batch", "session": "s", "revision": 7,
                 "batch": [{"key": "store.locals.locals", "value": big}]}
    let frame = encodeMessage(msg)
    let payload = $msg
    check frame.len == 4 + payload.len
    # Read back from ONE chunk of the whole frame (a pipe hands over as much
    # as it has), then from a second frame split in two large chunks.
    var r: FrameReader
    r.feed(frame)
    var got: string
    check r.next(got) == fsFrame
    check got.len == payload.len
    check parseJson(got)["batch"][0]["value"].getStr.len == big.len
    let half = frame.len div 2
    r.feed(frame[0 ..< half])
    check r.next(got) == fsIncomplete
    r.feed(frame[half .. ^1])
    check r.next(got) == fsFrame
    check got == payload
    check r.buffered == 0

suite "§11.4.4: the message set":

  test "host to process":
    check @HostToProcessTypes == @["hello", "signal-snapshot", "signal-batch",
      "view-event", "invoke", "query", "cancel", "activate", "deactivate",
      "settings-changed", "layer-popped", "ping", "shutdown"]

  test "process to host":
    check @ProcessToHostTypes == @["hello", "activated", "activation-failed",
      "action", "publish-batch", "view", "view-patch", "decorations", "status",
      "enablement", "context", "push-layer", "pop-layer", "ack", "answer",
      "rows", "done", "error", "log", "progress", "pong"]

  test "every message but hello and pong must name a registered plugin":
    let reg = @["acme.a"]
    check violation(%*{"type": "pong"}, reg) == ""
    check violation(%*{"type": "ack", "plugin": "acme.a", "id": "r1"}, reg) == ""
    check violation(%*{"type": "ack", "id": "r1"}, reg).contains("names no plugin")
    check violation(%*{"type": "ack", "plugin": "acme.b", "id": "r1"},
                    reg).contains("did not register")
    check violation(%*{"type": "teleport", "plugin": "acme.a"},
                    reg).contains("unknown message type")
    check violation(%*{"type": "view", "plugin": "acme.a"},
                    reg).contains("without 'surface'")
    check violation(%*[1, 2], reg).contains("not a JSON object")

suite "§11.4.2, §11.4.3: the handshake":

  test "the host's hello carries the protocol, the front-end and the features":
    let h = hostHello("1.2.3", "tui", "linux-amd64", @["x"])
    check h["protocol"]["major"].getInt == ProtocolMajor
    check h["host"]["frontEnd"].getStr == "tui"

  test "a matching process hello is accepted":
    let p = processHello("acme", @[("acme.a", "1.0.0"), ("acme.b", "1.0.0")])
    let c = checkProcessHello(p, "acme", @["acme.a", "acme.b"])
    check c.ok
    check c.pluginIds == @["acme.a", "acme.b"]

  test "a plugin missing from either side is a load error naming it":
    let p = processHello("acme", @[("acme.a", "1.0.0"), ("acme.x", "1.0.0")])
    let c = checkProcessHello(p, "acme", @["acme.a", "acme.b"])
    check not c.ok
    check c.problems.anyIt(it.contains("'acme.b'") and it.contains("does not register"))
    check c.problems.anyIt(it.contains("'acme.x'") and it.contains("no manifest"))

  test "a major version outside the host's range names the plugin and both versions":
    var p = processHello("acme", @[("acme.a", "1.0.0")])
    p["protocol"]["major"] = %2
    let c = checkProcessHello(p, "acme", @["acme.a"])
    check not c.ok
    check c.problems[0].contains("acme.a")
    check c.problems[0].contains("2.x")
    check c.problems[0].contains("1..1")

suite "§11.4.5: epochs":

  test "an answer is current only at the same session and position":
    let a = Epoch(session: "s", position: 4, revision: 9)
    check samePosition(a, Epoch(session: "s", position: 4, revision: 12))
    check not samePosition(a, Epoch(session: "s", position: 5, revision: 9))
    check not samePosition(a, Epoch(session: "t", position: 4, revision: 9))
    check epochFrom(a.toJson) == a

suite "§11.4.4 view trees and §11.4.7 limits":

  test "a view tree round-trips through the codec":
    let tree = viewTreeNode("root", "Root", @[
      viewText("t", "hello"), viewButton("b", "Go", disabled = true),
      viewList("l", @[ViewOption(id: "x", label: "X")]),
      viewTable("tb", @["a", "b"], @[@["1", "2"]]),
      viewProgress("p", 40)], expanded = true)
    let back = decodeViewTree(tree.toJson)
    check back.error == ""
    check back.nodes == 6
    check back.tree.toJson == tree.toJson

  test "a tree over 20,000 nodes is refused":
    check MaxViewNodes == 20_000
    var kids: seq[ViewNode]
    for i in 0 .. MaxViewNodes: kids.add viewText("n" & $i, "")
    let dec = decodeViewTree(viewTreeNode("r", "r", kids).toJson)
    check dec.error.contains("more than 20000 nodes")

  test "a third-party native view is refused (§11.11, answered 2026-11-20)":
    let dec = decodeViewTree(nativeEscape("e", "terminal", "editor").toJson)
    check dec.error.contains("native view")

  test "a patch replaces the node with that id, and is held to the budget":
    let tree = viewTreeNode("root", "Root", @[viewText("a", "old")])
    let patched = applyViewPatch(tree, %*[{"id": "a",
      "node": viewText("a", "new").toJson}])
    check patched.error == ""
    check patched.tree.children[0].text == "new"
    check applyViewPatch(tree, %*[{"id": "nope", "node": viewText("x", "").toJson}]).error.contains("does not have")

  test "the §11.4.7 limits are the spec's starting points":
    check MaxMessagesPerSecond == 500
    check MaxMessageBurst == 2000
    check MaxDecorationsPerDocument == 10_000
    check MaxLayersPerPlugin == 4
    check MaxContextKeysPerPlugin == 64
    check AckBudgetMs == 50
    check InputDeadlineMs == 500

suite "§11.7.2: bindings and when clauses":

  test "a when clause is a conjunction of context keys and negations":
    var ctx = initTable[string, bool]()
    ctx["a"] = true
    check evalWhen("", ctx)
    check evalWhen("a", ctx)
    check not evalWhen("b", ctx)
    check evalWhen("a && !b", ctx)
    check not evalWhen("a && b", ctx)
    check evalWhen("!!a", ctx)
