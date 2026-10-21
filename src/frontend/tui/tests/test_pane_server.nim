## test_pane_server.nim — HSF-E1, the pane server's protocol, on a real trace.
##
## Drives `host/pane_server.PaneServer` message by message — the same
## `handle` / `handleDap` the stdio loop calls — over a real `.ct` recording
## opened by a real `replay-server`: open a session, open panes at editor
## sizes, resize, scroll, step, run a hotspot's operation, switch modes and
## back, edit the layout, report a source viewport, attach a DAP client.
##
## THE CROSS-CHECK AGAINST THE TERMINAL (the milestone's Verification): a pane
## hosted at the size the interactive terminal gives that pane in its own
## screen must show the very rows the terminal paints there. The terminal's
## screen is `shell.shellScreen` of the same session's model; the server's is
## `pane/content`. Equal text, row by row.
##
## No mocks: the recording, the engine, the session and the painters are the
## product's. The stdio transport itself is `test_pane_server_stdio.nim`'s.

import std/[json, options, sequtils, strutils, tables, unittest]

import headless_app/layout_model

import ../app/runtime
import ../app/views/shell
import ../app/views/styled_row
import ../app/layout/cells
import ../app/layout/project
import ../host/pane_server
import ./fixtures/fixture_provider

const
  FixtureName = "calc"

var nextId = 0

proc request(srv: PaneServer; meth: string; params: JsonNode = newJObject()):
    (JsonNode, seq[JsonNode]) =
  ## Send a request; the response and the notifications it caused.
  inc nextId
  let answer = srv.handle(%*{"jsonrpc": "2.0", "id": nextId, "method": meth,
                          "params": params})
  doAssert answer.len >= 1 and answer[0]{"id"}.getInt(-1) == nextId,
    meth & " answered " & $answer
  (answer[0], answer[1 .. ^1])

proc notes(msgs: seq[JsonNode]; meth: string): seq[JsonNode] =
  msgs.filterIt(it{"method"}.getStr("") == meth)

proc rowTexts(content: JsonNode): Table[int, string] =
  for r in content{"params", "rows"}.getElems:
    result[r{"index"}.getInt] = r{"text"}.getStr

proc findPane(node: JsonNode; pane: string): JsonNode =
  if node{"pane"}.getStr("") == pane:
    return node
  for c in node{"children"}.getElems:
    let f = findPane(c, pane)
    if not f.isNil: return f

suite "HSF-E1: the pane server, over a real recording":

  test "the protocol, end to end":
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      fail()
      return
    let srv = newPaneServer()
    srv.openDapListener()

    # ---- before initialize, nothing is served ------------------------------
    block:
      inc nextId
      let answer = srv.handle(%*{"jsonrpc": "2.0", "id": nextId,
                              "method": "session/list"})
      check answer[0]{"error", "code"}.getInt == -32002

    # ---- initialize: version, encoding, the DAP endpoint -------------------
    let (init, _) = srv.request("initialize", %*{
      "capabilities": {"media": ["text"], "tabs": true, "mouseResize": true},
      "keymapOverrides": [{"pane": "calltrace", "key": "Enter"}]})
    check init{"result", "protocolVersion"}.getInt == 1
    check init{"result", "positionEncoding"}.getStr == "utf-8"
    check init{"result", "capabilities", "dap", "port"}.getInt > 0
    # An editor that did not declare the image medium is sent text only.
    check init{"result", "capabilities", "media"} == %["text"]

    # ---- operations/list: the catalogue and the panes' own ----------------
    let (ops, _) = srv.request("operations/list")
    let names = ops{"result"}.getElems.mapIt(it{"name"}.getStr)
    check "debugger.step-over" in names
    check "session.toggle-product-mode" in names
    check "calltrace.go-to-call" in names

    # ---- session/open: the session and the debug layout -------------------
    let (opened, afterOpen) = srv.request("session/open",
                                          %*{"trace": resolution.tracePath})
    check opened{"error"}.isNil
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    check opened{"result", "mode"}.getStr == "debug"
    # `calc` draws nothing: no graphics, and no frame viewer to open.
    check opened{"result", "graphics", "available"}.getBool == false
    let (noFrames, _) = srv.request("pane/open",
      %*{"session": opened{"result", "session"}.getInt, "pane": "frameViewer",
         "width": 40, "height": 10})
    check noFrames{"error", "code"}.getInt == -32803
    check not findPane(opened{"result", "layout"}, "calltrace").isNil
    let firstPos = afterOpen.notes("session/position")
    check firstPos.len == 1
    check firstPos.len == 1 and
          firstPos[0]{"params", "file"}.getStr.endsWith("main.py")

    # ---- pane/open: keymap and full content at the window's size ----------
    let (ct, ctNotes) = srv.request("pane/open",
      %*{"session": sid, "pane": "calltrace", "width": 70, "height": 12})
    check ct{"result", "height"}.getInt == 12
    let km = ctNotes.notes("pane/keymap")
    check km.len == 1
    let bindings = km[0]{"params", "bindings"}.getElems
    check bindings.len > 0
    check bindings.anyIt(it{"operation"}.getStr == "debugger.step-over")
    # The editor's own binding for Enter in this pane is left in place.
    check bindings.allIt(it{"key"}.getStr != "Enter" or
                         it{"shadowedBy"}.getStr == "editor")
    let content = ctNotes.notes("pane/content")
    check content.len == 1
    check content[0]{"params", "full"}.getBool
    let rows = content[0]{"params", "rows"}.getElems
    check rows.len == 12
    check rows.anyIt(it{"text"}.getStr.strip.len > 0)
    var goTo: JsonNode = nil
    for r in rows:
      for h in r{"hotspots"}.getElems:
        # The LAST call on screen: not the one the debugger starts in, so
        # going to it must move the position.
        if h{"operation"}.getStr == "calltrace.go-to-call":
          goTo = h
    check not goTo.isNil
    if goTo.isNil: return
    # Spans name semantic styles, never colours.
    check rows.anyIt(it{"spans"}.getElems.anyIt(
      it{"style"}.getStr.startsWith("ct.")))

    # ---- the terminal paints the same rows at the same size ---------------
    block crossCheck:
      let rt = srv.activeRuntime()
      let model = rt.app.shellModel(120, 40)
      let screen = shellScreen(model, 120, 40)
      let projection = projectLayout(model.layout, bodyArea(120, 40))
      var area = CellArea()
      var found = false
      for region in projection.regions:
        if region.pane == paneCalltrace:
          let frame = paneFrame(region.area, bodyArea(120, 40))
          area = CellArea(col: region.area.col, row: region.area.row,
                          width: frame.box.width, height: frame.box.height)
          found = true
      check found
      if not found: break crossCheck
      let h = area.height - 1
      let (_, resized) = srv.request("pane/resize",
        %*{"session": sid, "pane": "calltrace", "width": area.width,
           "height": h})
      let full = resized.notes("pane/content")
      check full.len == 1
      if full.len != 1: break crossCheck
      let texts = rowTexts(full[0])
      check texts.len == h
      var same = 0
      for i in 0 ..< h:
        let term = cellSlice(screen.rows[area.row + 1 + i], area.col,
                             area.col + area.width)
        checkpoint("row " & $i & " terminal: [" & term & "] server: [" &
                   texts.getOrDefault(i) & "]")
        if term.strip(leading = false) == texts.getOrDefault(i).strip(leading = false):
          inc same
      check same == h
      # Back to the editor's size.
      discard srv.request("pane/resize",
        %*{"session": sid, "pane": "calltrace", "width": 70, "height": 12})

    # ---- the state and event-log panes ------------------------------------
    let (_, stNotes) = srv.request("pane/open",
      %*{"session": sid, "pane": "state", "width": 50, "height": 10})
    check stNotes.notes("pane/content").len == 1
    let (_, elNotes) = srv.request("pane/open",
      %*{"session": sid, "pane": "eventLog", "width": 80, "height": 8})
    check elNotes.notes("pane/content").len == 1

    # ---- a step moves the position and updates only changed rows ----------
    let before = firstPos[0]{"params"}
    let (stepped, stepNotes) = srv.request("operation/run",
      %*{"session": sid, "operation": "debugger.step-over"})
    check stepped{"result", "ok"}.getBool
    let moved = stepNotes.notes("session/position")
    check moved.len == 1
    check moved.len == 1 and
          (moved[0]{"params", "tick"}.getBiggestInt !=
             before{"tick"}.getBiggestInt or
           moved[0]{"params", "line"}.getInt != before{"line"}.getInt)
    check stepNotes.notes("pane/content").allIt(not it{"params", "full"}.getBool)

    # ---- an unknown operation is refused, by name -------------------------
    let (bad, _) = srv.request("operation/run",
      %*{"session": sid, "operation": "debugger.fly"})
    check bad{"error", "code"}.getInt == -32602

    # ---- a hotspot's operation: go to that call ----------------------------
    let (went, wentNotes) = srv.request("operation/run",
      %*{"session": sid, "operation": goTo{"operation"}.getStr,
         "args": goTo{"args"}})
    checkpoint("go-to-call answered " & $went)
    check went{"result", "ok"}.getBool
    check wentNotes.notes("session/position").len == 1
    check wentNotes.notes("pane/content").len >= 1

    # ---- scrolling the pane is an operation on the focused pane -----------
    let (scrolled, _) = srv.request("operation/run",
      %*{"session": sid, "operation": "editor.scroll-line-down",
         "pane": "calltrace"})
    check scrolled{"error"}.isNil

    # ---- mode switch, the user's layout edit, and back --------------------
    let (edited, _) = srv.request("layout/edited",
      %*{"session": sid, "mode": "debug", "sizes": {"calltrace": 3.0}})
    check findPane(edited{"result", "layout"}, "calltrace"){"weight"}.getFloat == 3.0
    let (_, toEdit) = srv.request("operation/run",
      %*{"session": sid, "operation": "session.toggle-product-mode"})
    let editLayout = toEdit.notes("layout/changed")
    check editLayout.len == 1
    check editLayout.len == 1 and editLayout[0]{"params", "mode"}.getStr == "edit"
    let (_, toDebug) = srv.request("operation/run",
      %*{"session": sid, "operation": "session.toggle-product-mode"})
    let debugLayout = toDebug.notes("layout/changed")
    check debugLayout.len == 1
    check debugLayout.len == 1 and
          debugLayout[0]{"params", "mode"}.getStr == "debug"
    # The arrangement the user left the mode in comes back with it.
    check debugLayout.len == 1 and findPane(debugLayout[0]{"params", "layout"},
                                            "calltrace"){"weight"}.getFloat == 3.0

    # ---- source decorations for the visible lines -------------------------
    let pos = srv.request("session/list")[0]
    discard pos
    let rt = srv.activeRuntime()
    let file = rt.app.source.path
    let execLine = rt.app.source.executionLine
    let (_, decoNotes) = srv.request("source/viewport",
      %*{"session": sid, "file": file, "firstLine": max(1, execLine - 5),
         "lastLine": execLine + 5})
    let deco = decoNotes.notes("source/decorations")
    check deco.len == 1
    check deco.len == 1 and deco[0]{"params", "rows"}.getElems.anyIt(
      it{"line"}.getInt == execLine and it{"execution"}.getBool)

    # ---- the DAP endpoint drives the same session -------------------------
    var dseq = 0
    proc dap(command: string; args: JsonNode = newJObject()): JsonNode =
      inc dseq
      let answer = srv.handleDap(%*{"seq": dseq, "type": "request",
                                 "command": command, "arguments": args})
      doAssert answer.len == 1, command & " answered " & $answer
      answer[0]
    check dap("initialize"){"success"}.getBool
    check dap("attach"){"success"}.getBool
    check dap("configurationDone"){"success"}.getBool
    check dap("threads"){"body", "threads"}.len == 1
    let frames = dap("stackTrace", %*{"threadId": 1}){"body", "stackFrames"}
    check frames.len >= 1
    let scopes = dap("scopes", %*{"frameId": 1}){"body", "scopes"}
    check scopes.len >= 1
    if scopes.len >= 1:
      let vars = dap("variables", %*{"variablesReference":
        scopes[0]{"variablesReference"}.getInt}){"body", "variables"}
      check vars.kind == JArray
    let stepped2 = dap("next", %*{"threadId": 1})
    check stepped2{"success"}.getBool
    let pushed = srv.publishActive()
    check pushed.notes("session/position").len == 1
    check srv.takeDapOut().anyIt(it{"event"}.getStr == "stopped")
    check not dap("fly"){"success"}.getBool

    # ---- sessions ----------------------------------------------------------
    let (list, _) = srv.request("session/list")
    check list{"result"}.len == 1
    check list{"result"}[0]{"active"}.getBool
    let (closed, _) = srv.request("pane/close",
      %*{"session": sid, "pane": "eventLog"})
    check closed{"error"}.isNil

    # ---- shutdown and exit -------------------------------------------------
    let (down, _) = srv.request("shutdown")
    check down{"error"}.isNil
    check srv.handle(%*{"jsonrpc": "2.0", "method": "exit"}).len == 0
    check srv.exitRequested
