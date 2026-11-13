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

import std/[importutils, json, options, os, sequtils, strutils, tables, tempfiles, times, unittest]

import headless_app/layout_model

import ../app/runtime
import ../app/views/shell
import ../app/views/styled_row
import ../app/layout/cells
import ../app/layout/project
import ../host/pane_server
import ./fixtures/fixture_provider
import ./fixtures/plat53_noir_project
import ./fixtures/plat65_nim_project
import ./fixtures/native_recording
import ../app/edit_binding
import ../app/views/low_level_code_pane
from ../host/edit_services import EditHostState
from ../host/tui_session import TuiSession
import viewmodels/low_level_code_vm
from ../host/native_host import traceFolderProblem
from backend/stdio_backend import DapStdioBackend

proc activeRuntime(srv: PaneServer): TuiRuntime =
  ## The active session's runtime, to compare a hosted pane with the
  ## interactive terminal's painting of the same pane. The server keeps its
  ## sessions private (an editor reaches them only through the protocol), so
  ## the suite reads them through std/importutils.
  privateAccess(PaneServer)
  if srv.active < 0:
    return nil
  let session = srv.sessions[srv.active]
  privateAccess(typeof(session))
  session.rt

proc activeEdit(srv: PaneServer): EditHostState =
  ## The active session's Edit-mode services, for the listing they hold.
  privateAccess(PaneServer)
  let session = srv.sessions[srv.active]
  privateAccess(typeof(session))
  session.edit

proc activeReplay(srv: PaneServer): TuiSession =
  privateAccess(PaneServer)
  let session = srv.sessions[srv.active]
  privateAccess(typeof(session))
  session.tui

proc engineRequests(srv: PaneServer): int =
  ## How many requests the active session has sent the engine: the DAP
  ## transport's sequence number, which every request takes the next of.
  privateAccess(PaneServer)
  let session = srv.sessions[srv.active]
  privateAccess(typeof(session))
  privateAccess(DapStdioBackend)
  session.tui.session.backend.seqCounter

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

proc regionOf(node: JsonNode; pane: string): JsonNode =
  ## The node whose weight sizes `pane`: its stack when it is one of a
  ## stack's tabs, else the pane's own leaf.
  for c in node{"children"}.getElems:
    if c{"pane"}.getStr("") == pane:
      return (if node{"kind"}.getStr("") == "stack": node else: c)
    let f = regionOf(c, pane)
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
    # Edit mode's project: one file, not the directory the suite runs in.
    let editProject = createTempDir("ct-hsf-e1-project-", "")
    writeFile(editProject / "edited_app.py", "print('edited')\n")
    srv.projectRoot = editProject

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
    # A click on an event's row jumps to that event: one hotspot spanning the
    # row, naming the events in the order the log shows them (the hit test
    # reads one paint of the log for every row).
    block eventHotspots:
      let el = elNotes.notes("pane/content")
      if el.len != 1: break eventHotspots
      var jumps: seq[int64] = @[]
      for r in el[0]{"params", "rows"}.getElems:
        for h in r{"hotspots"}.getElems:
          check h{"operation"}.getStr == "event-log.jump"
          check h{"start"}.getInt == 0 and
                h{"end"}.getInt >= r{"text"}.getStr.strip(leading = false).len
          check r{"text"}.getStr.strip.len > 0
          jumps.add h{"args", "index"}.getBiggestInt
      check jumps.len >= 2
      for i in 1 ..< jumps.len:
        check jumps[i] > jumps[i - 1]

    # ---- a resize at the same stop asks the engine for nothing -------------
    # A resize moves the pane's viewport (Editor-Hosted-Front-Ends §E5), and
    # what a viewport decides is how much is fetched, not the stop. Until
    # 2026-11-11 every resize rebuilt every pane from the stop, so a split
    # dragged in the editor queued a stop's worth of engine requests per
    # frame of the drag. The pane is still painted at its new size.
    let quiet = srv.engineRequests()
    for w in [51, 56, 63]:
      let (_, widened) = srv.request("pane/resize",
        %*{"session": sid, "pane": "state", "width": w, "height": 12})
      let painted = widened.notes("pane/content")
      check painted.len == 1 and painted[0]{"params", "width"}.getInt == w and
            painted[0]{"params", "rows"}.len == 12
    let (_, shorter) = srv.request("pane/resize",
      %*{"session": sid, "pane": "eventLog", "width": 80, "height": 6})
    check shorter.notes("pane/content").len == 1
    check srv.engineRequests() == quiet

    # ---- a step moves the position and updates only changed rows ----------
    let before = firstPos[0]{"params"}
    let (stepped, stepNotes) = srv.request("operation/run",
      %*{"session": sid, "operation": "debugger.step-over"})
    check stepped{"result", "ok"}.getBool
    # The positive control for the counter above: a step does ask.
    check srv.engineRequests() > quiet
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
    # Scrolling the source window one line, at the same height, asks the
    # engine for nothing: the decorations of the newly visible range are
    # read from the source model already held.
    let unscrolled = srv.engineRequests()
    let (_, scrollNotes) = srv.request("source/viewport",
      %*{"session": sid, "file": file, "firstLine": max(1, execLine - 4),
         "lastLine": execLine + 6})
    check srv.engineRequests() == unscrolled
    let scrolledDeco = scrollNotes.notes("source/decorations")
    check scrolledDeco.len == 1 and
          scrolledDeco[0]{"params", "lastLine"}.getInt == execLine + 6 and
          scrolledDeco[0]{"params", "rows"}.getElems.anyIt(
            it{"line"}.getInt == execLine and it{"execution"}.getBool)

    # ---- an operation "at the cursor" acts at the editor's cursor ----------
    # The editor reports where its cursor is (`source/cursor`); toggling a
    # breakpoint then places it there, not at the stop's line.
    let cursorLine = execLine + 2
    discard srv.request("source/cursor",
      %*{"session": sid, "file": file, "line": cursorLine, "column": 1})
    let (toggled, toggleNotes) = srv.request("operation/run",
      %*{"session": sid, "operation": "editor.toggle-breakpoint"})
    check toggled{"result", "ok"}.getBool
    var marked = toggleNotes.notes("source/decorations")
    if marked.len == 0:
      # The decorations follow the next publish when the toggle did not
      # change the visible range's text.
      marked = srv.request("source/viewport",
        %*{"session": sid, "file": file, "firstLine": max(1, execLine - 5),
           "lastLine": execLine + 6})[1].notes("source/decorations")
    check marked.len >= 1 and marked[^1]{"params", "rows"}.getElems.anyIt(
      it{"line"}.getInt == cursorLine and it{"mark"}.getStr == "breakpoint")
    check marked.len >= 1 and not marked[^1]{"params", "rows"}.getElems.anyIt(
      it{"line"}.getInt == execLine and it{"mark"}.getStr == "breakpoint")

    # ---- the recording's source set, for an editor's own file tree -------
    let (listed, _) = srv.request("session/files", %*{"session": sid})
    let files = listed{"result"}.getElems
    check files.anyIt(it{"path"}.getStr == file)
    let (read, _) = srv.request("source/read", %*{"session": sid, "file": file})
    check read{"result", "text"}.getStr == readFile(file) or
          read{"result", "text"}.getStr.len > 0
    check read{"result", "text"}.getStr.splitLines.len >= execLine
    let (missing, _) = srv.request("source/read",
      %*{"session": sid, "file": "/no/such/recorded/file.py"})
    check not missing{"error"}.isNil
    # The editor's tree selection: CodeTracer's file tree selects the file,
    # and its pane draws that row on the selection surface.
    discard srv.request("files/selected", %*{"session": sid, "path": file})
    let (_, treeNotes) = srv.request("pane/open",
      %*{"session": sid, "pane": "fileTree", "width": 40, "height": 12})
    let selectedRows = treeNotes.notes("pane/content")
    let base = file.extractFilename
    check selectedRows.len >= 1 and selectedRows[^1]{"params", "rows"}.getElems.anyIt(
      base in it{"text"}.getStr and it{"spans"}.getElems.anyIt(
        it{"surface"}.getStr == "ct.surface-selection"))
    discard srv.request("pane/close", %*{"session": sid, "pane": "fileTree"})
    let (changed, _) = srv.request("files/changed",
      %*{"session": sid, "created": ["/tmp/new.py"], "deleted": [], "renamed": []})
    check changed{"error"}.isNil

    # ---- CodeTracer's file pane: its rows open files in the editor ---------
    let (_, treeOpen) = srv.request("pane/open",
      %*{"session": sid, "pane": "fileTree", "width": 50, "height": 8})
    let treeRows = treeOpen.notes("pane/content")
    check treeRows.len == 1
    var fileSpot: JsonNode = nil
    if treeRows.len == 1:
      for r in treeRows[0]{"params", "rows"}.getElems:
        for h in r{"hotspots"}.getElems:
          if h{"operation"}.getStr == "file-tree.open" and
             h{"args", "path"}.getStr.endsWith("main.py"):
            fileSpot = h
    # A file's row offers to open it, by its path; a folder's to open or
    # close it.
    check not fileSpot.isNil
    check treeRows.len == 1 and treeRows[0]{"params", "rows"}.getElems.anyIt(
      it{"hotspots"}.getElems.anyIt(it{"operation"}.getStr == "file-tree.toggle-folder"))
    if not fileSpot.isNil:
      let path = fileSpot{"args", "path"}.getStr
      let (opened, openNotes) = srv.request("operation/run",
        %*{"session": sid, "operation": "file-tree.open", "pane": "fileTree",
           "args": fileSpot{"args"}})
      check opened{"result", "ok"}.getBool
      # The editor owns the source: it is told which file to show — even the
      # stop's own file, which the terminal would not count as opened.
      let shows = openNotes.notes("source/show")
      check shows.len == 1
      check shows.len == 1 and shows[0]{"params", "file"}.getStr == path
      # The editor's own tree selecting it: the file tree's selection follows.
      discard srv.request("files/selected", %*{"session": sid, "path": path})
      let tree = srv.activeRuntime().app.fileTree
      check tree.selected >= 0 and tree.selected < tree.entries.len and
            tree.entries[tree.selected].path == path
    discard srv.request("pane/close", %*{"session": sid, "pane": "fileTree"})

    # ---- mode switch, the user's layout edit, and back --------------------
    # AFTER the file-tree checks above: those are of the recording's tree, and
    # once Edit mode has listed the project the Files pane keeps that listing
    # (`tui_session.refresh`, PLAT-47), in the terminal and here alike.
    let (edited, _) = srv.request("layout/edited",
      %*{"session": sid, "mode": "debug", "sizes": {"calltrace": 3.0}})
    # Recorded on the region the pane occupies — the call trace is a tab of a
    # stack, so the stack's weight is what sizes it.
    check regionOf(edited{"result", "layout"}, "calltrace"){"weight"}.getFloat == 3.0
    # A weight addressed by its node's path reaches a container, which a
    # weight keyed by pane cannot: the root's last child here. A path that
    # names no node, and the root itself, are ignored.
    let rootKids = edited{"result", "layout", "children"}.len
    check rootKids >= 2
    let (byPath, _) = srv.request("layout/edited",
      %*{"session": sid, "mode": "debug",
         "weights": [{"path": [rootKids - 1], "weight": 42.0},
                     {"path": [99], "weight": 1.0},
                     {"path": [], "weight": 7.0}]})
    check byPath{"result", "layout", "children"}[rootKids - 1]{"weight"}.getFloat == 42.0
    check byPath{"result", "layout"}{"weight"}.getFloat(0.0) != 7.0
    let (_, toEdit) = srv.request("operation/run",
      %*{"session": sid, "operation": "session.toggle-product-mode"})
    let editLayout = toEdit.notes("layout/changed")
    check editLayout.len == 1
    check editLayout.len == 1 and editLayout[0]{"params", "mode"}.getStr == "edit"
    # Edit mode lists the session's project — the editor's directory, here
    # the suite's one-file project (§E9: until 2026-11-12 the server gave the
    # runtime no lister, and Edit mode's Files pane was empty).
    let (_, editFiles) = srv.request("pane/open",
      %*{"session": sid, "pane": "fileTree", "width": 40, "height": 6})
    let listedRows = editFiles.notes("pane/content")
    check listedRows.len == 1 and listedRows[0]{"params", "rows"}.getElems.anyIt(
      "edited_app.py" in it{"text"}.getStr)
    # ...and a press on the file's row opens it in the editor.
    check listedRows.len == 1 and listedRows[0]{"params", "rows"}.getElems.anyIt(
      it{"hotspots"}.getElems.anyIt(it{"operation"}.getStr == "file-tree.open" and
        it{"args", "path"}.getStr.endsWith("edited_app.py")))
    discard srv.request("pane/close", %*{"session": sid, "pane": "fileTree"})
    let (_, toDebug) = srv.request("operation/run",
      %*{"session": sid, "operation": "session.toggle-product-mode"})
    let debugLayout = toDebug.notes("layout/changed")
    check debugLayout.len == 1
    check debugLayout.len == 1 and
          debugLayout[0]{"params", "mode"}.getStr == "debug"
    # The arrangement the user left the mode in comes back with it.
    check debugLayout.len == 1 and regionOf(debugLayout[0]{"params", "layout"},
                                            "calltrace"){"weight"}.getFloat == 3.0
    check debugLayout.len == 1 and debugLayout[0]{"params", "layout",
      "children"}[rootKids - 1]{"weight"}.getFloat == 42.0

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

  test "HSF-E5: edit-mode services — refusals, messages, a test recorded from Test Results":
    # Editor-Hosted-Front-Ends §E9. Until 2026-11-12 the server wired none of
    # the services the terminal's window owns, and `operation/run` erased the
    # operation's own message, so every operation below answered
    # `{"ok": true, "detail": ""}` and did nothing (codetracer-pm issue
    # 2026-11-12). The project is PLAT-53's two-test Noir crate, recorded
    # with the real `ct record-test`; no stand-in: the recording is opened by
    # the server as a session of its own.
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      fail()
      return
    let ctBin = findCtBinary()
    doAssert ctBin.len > 0, "prerequisite missing: ct (build it, or set CT_BIN)"
    putEnv("CT_BIN", ctBin)
    putEnv("TEST_CERTIFICATES_DIR", createTempDir("ct-hsf-e5-certs-", ""))
    let project = writePlat53Project("ct-hsf-e5-project-")
    let srv = newPaneServer(dap = false)
    srv.projectRoot = project
    let (init, _) = srv.request("initialize", %*{
      "capabilities": {"media": ["text"]}, "keymapOverrides": []})
    # The panes the session's sources fill are drawable: an editor leaves
    # out of its layout what `capabilities.panes` does not name.
    let drawable = init{"result", "capabilities", "panes"}.getElems.mapIt(it.getStr)
    check "testResults" in drawable and "problems" in drawable
    let (opened, openNotes) = srv.request("session/open",
                                          %*{"trace": resolution.tracePath})
    let sid = opened{"result", "session"}.getInt
    check sid > 0

    # ---- HSF-E7: the debugger controls' strip -------------------------------
    # The terminal's top-bar controls, in the desktop toolbar's order, then
    # Stop; each names the operation a press runs, and is enabled by the
    # desktop toolbar's rule (`transportAvailable`).
    proc buttonsOf(notes: seq[JsonNode]): Table[string, JsonNode] =
      for n in notes.notes("controls/state"):
        for b in n{"params", "buttons"}.getElems:
          result[b{"id"}.getStr] = b
    # The source window's keys come with the session: the editor binds the
    # debugger's in its source buffers (§E11, Q6).
    let sourceKeys = openNotes.notes("pane/keymap").filterIt(
      it{"params", "pane"}.getStr == "editor")
    check sourceKeys.len == 1 and sourceKeys[0]{"params", "bindings"}.getElems.anyIt(
      it{"operation"}.getStr == "debugger.step-over")
    let strip = buttonsOf(openNotes)
    check strip.len == 10
    check strip.hasKey("next") and strip["next"]{"enabled"}.getBool and
          strip["next"]{"operation"}.getStr == "debugger.step-over"
    check strip.hasKey("reverse-next") and
          strip["reverse-next"]{"operation"}.getStr == "debugger.reverse-step-over"
    check strip.hasKey("stop") and strip["stop"]{"enabled"}.getBool
    check strip.hasKey("next") and strip["next"]{"glyphs", "unicode"}.getStr.len > 0
    # A press is that operation: one step.
    let (_, steppedNotes) = srv.request("operation/run", %*{"session": sid,
      "operation": strip.getOrDefault("next", %*{}){"operation"}.getStr})
    check steppedNotes.notes("session/position").len == 1
    # Unchanged, the strip is not sent again.
    let (_, idleNotes) = srv.request("source/viewport", %*{"session": sid,
      "file": "", "firstLine": 1, "lastLine": 10})
    check idleNotes.notes("controls/state").len == 0

    # ---- a refusal is a refusal ---------------------------------------------
    let (gone, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "tests.open-test", "args": {"path": "no-such-test"}})
    check not gone{"result", "ok"}.getBool
    check gone{"result", "detail"}.getStr.len > 0

    # ---- an operation's own message is its answer ---------------------------
    # The Nim tracer is wired now; on `calc`'s Python file it says why it
    # cannot trace there — before, that sentence was erased and the answer
    # was an empty success.
    let (traced, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "editor.trace-macro-at-cursor"})
    checkpoint("trace-macro answered " & $traced)
    check traced{"result", "detail"}.getStr.len > 0

    # ---- Test Results: the project's tests, their controls as hotspots ------
    let (_, shownNotes) = srv.request("pane/open", %*{"session": sid,
      "pane": "testResults", "width": 90, "height": 10})
    let shown = shownNotes.notes("pane/content")
    check shown.len == 1
    var openSpot: JsonNode = nil
    var text = ""
    if shown.len == 1:
      for r in shown[0]{"params", "rows"}.getElems:
        text.add r{"text"}.getStr & "\n"
        for h in r{"hotspots"}.getElems:
          if h{"operation"}.getStr == "tests.open-test" and
             Plat53Failing in r{"text"}.getStr:
            openSpot = h
    checkpoint("Test Results rows:\n" & text)
    check Plat53Passing in text and Plat53Failing in text
    check not openSpot.isNil
    if openSpot.isNil: return

    # ---- HSF-E10: the shown source file's tests ------------------------------
    # The editor shows the crate's source: each test the catalog places in it
    # is sent with its line and the pane's own controls, so a press on the
    # test's line is the pane's ⏵ (`tests.open-test`).
    let (_, sourceNotes) = srv.request("source/viewport", %*{"session": sid,
      "file": project / "src" / "main.nr", "firstLine": 1, "lastLine": 14})
    let inSource = sourceNotes.notes("source/tests")
    check inSource.len == 1
    if inSource.len == 1:
      let controls = inSource[0]{"params", "controls"}.getElems
      checkpoint("source/tests: " & $inSource[0])
      check controls.len == 2
      check controls.anyIt(it{"name"}.getStr == Plat53Passing and
                           it{"line"}.getInt == Plat53PassingLine)
      check controls.anyIt(it{"name"}.getStr == Plat53Failing and
                           it{"line"}.getInt == Plat53FailingLine and
                           it{"testId"}.getStr == openSpot{"args", "path"}.getStr and
                           it{"open", "label"}.getStr.len > 0)
    # Unchanged, they are not sent again.
    let (_, againNotes) = srv.request("source/viewport", %*{"session": sid,
      "file": project / "src" / "main.nr", "firstLine": 2, "lastLine": 14})
    check againNotes.notes("source/tests").len == 0

    # ---- ⏵ records the test; its recording opens as a session --------------
    let (pressed, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "tests.open-test", "args": openSpot{"args"}})
    check pressed{"result", "ok"}.getBool
    var announced: JsonNode = nil
    let deadline = epochTime() + 240.0
    while announced.isNil and epochTime() < deadline:
      for m in srv.tick():
        if m{"method"}.getStr == "session/opened":
          announced = m{"params"}
      sleep(100)
    check not announced.isNil
    if announced.isNil: return
    check announced{"session"}.getInt != sid
    check announced{"placement"}.getStr == "new-tab"
    check traceFolderProblem(announced{"trace"}.getStr) == ""
    check announced{"layout"}.kind == JObject
    # Its tab is named by the test, not by the recording's folder (an id).
    check announced{"title"}.getStr == Plat53Failing
    let (list, _) = srv.request("session/list")
    check list{"result"}.len == 2

    # ---- ⏵ redirected: the recording takes the current tab ------------------
    # The terminal's Ctrl on the press (§9.3), an editor's Ctrl+click: the
    # destination inverted, so the session it was pressed from is replaced.
    let redirected = openSpot{"args"}.copy
    redirected["text"] = %"redirect"
    let (again, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "tests.open-test", "args": redirected})
    check again{"result", "ok"}.getBool
    var replaced: JsonNode = nil
    let until = epochTime() + 240.0
    while replaced.isNil and epochTime() < until:
      for m in srv.tick():
        if m{"method"}.getStr == "session/opened":
          replaced = m{"params"}
      sleep(100)
    check not replaced.isNil
    check not replaced.isNil and replaced{"placement"}.getStr == "current-tab" and
          replaced{"replaces"}.getInt == sid

    # ---- Stop ends the replay: the strip goes dim --------------------------
    let (_, stoppedNotes) = srv.request("operation/run", %*{"session": sid,
      "operation": "debugger.stop"})
    let stopped = buttonsOf(stoppedNotes)
    check stopped.len == 10
    check stopped.len == 10 and toSeq(stopped.values).allIt(not it{"enabled"}.getBool)
    discard srv.request("shutdown")

  test "HSF-E8: Nim's compile-time tracing at the editor's cursor":
    # Editor-Hosted-Front-Ends §E12. The terminal traces a macro, a static
    # block, a constant or an evaluation at its caret through the window's
    # Nim tracer; an editor-hosted session's caret is the editor's cursor
    # (`source/cursor`), and what the trace records opens as a session the
    # editor is told of. No stand-in: PLAT-65's project, codetracer-nim's
    # nimsuggest and `nim e --trace`, the product's tracer.
    let missing = missingPrereq()
    if missing.len > 0:
      echo "  MISSING-PREREQ: ", missing
      fail()
      return
    let project = writeNimProject("hsf-e8")
    let srv = newPaneServer(dap = false)
    srv.projectRoot = project.root
    discard srv.request("initialize", %*{"capabilities": {"media": ["text"]},
                                         "keymapOverrides": []})
    let (opened, _) = srv.request("session/open", %*{"trace": project.recording})
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    # Edit mode: the project's file at the editor's cursor.
    discard srv.request("operation/run", %*{"session": sid,
      "operation": "session.toggle-product-mode"})
    let source = project.root / "tracing.nim"
    proc traceAt(operation: string; line, column: int): JsonNode =
      ## Run `operation` with the editor's cursor at `line:column`; the
      ## `session/opened` its recording is announced with, or nil.
      discard srv.request("source/cursor", %*{"session": sid, "file": source,
                                              "line": line, "column": column})
      let (answer, _) = srv.request("operation/run", %*{"session": sid,
        "operation": operation})
      checkpoint(operation & " answered " & $answer)
      check answer{"result", "ok"}.getBool
      let deadline = epochTime() + 300.0
      while epochTime() < deadline:
        for m in srv.tick():
          if m{"method"}.getStr == "session/opened":
            return m{"params"}
        sleep(100)
    let staticTrace = traceAt("editor.trace-static-block-at-cursor",
                              StaticLines.a, 5)
    check not staticTrace.isNil
    if not staticTrace.isNil:
      check traceFolderProblem(staticTrace{"trace"}.getStr) == ""
      check staticTrace{"session"}.getInt != sid
    # The session the trace was started from stays in Edit mode: the
    # recording is another session's (until 2026-11-12 the terminal's rule
    # moved this one to Debug mode, and the next trace read the recording's
    # file instead of the project's).
    let (listed, _) = srv.request("session/list")
    check listed{"result"}.getElems.anyIt(it{"session"}.getInt == sid and
                                          it{"mode"}.getStr == "edit")
    let macroTrace = traceAt("editor.trace-macro-at-cursor", TwiceLine, 1)
    check not macroTrace.isNil
    if not macroTrace.isNil:
      check traceFolderProblem(macroTrace{"trace"}.getStr) == ""
    discard srv.request("shutdown")
    removeProject(project)

  test "HSF-E9: an editor's Low Level Code pane is sent the stop's listing":
    # Editor-Hosted-Front-Ends §E13. The listing is asked for only while the
    # pane is shown, and until 2026-11-12 "shown" meant the terminal's own
    # screen, so an editor's Low Level Code pane was never sent one. The
    # recording is CodeTracer's native Nim example (rr), replayed by the
    # native backend.
    let recording = currentSourcePath().parentDir / ".." / ".." / ".." / ".." /
      ".." / "codetracer-example-recordings" / "nim" / "flow_test"
    let native = getEnv("CODETRACER_CT_NATIVE_REPLAY_CMD")
    if not dirExists(recording) or native.len == 0 or not fileExists(native):
      echo "  MISSING-PREREQ SKIP: the native Nim example recording (",
           recording, ") and the native backend ($CODETRACER_CT_NATIVE_REPLAY_CMD)"
      skip()
      return
    let srv = newPaneServer(dap = false)
    discard srv.request("initialize", %*{"capabilities": {"media": ["text"]},
                                         "keymapOverrides": []})
    let (opened, _) = srv.request("session/open", %*{"trace": recording})
    checkpoint("open: " & $opened)
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    if sid <= 0: return
    discard srv.request("pane/open", %*{"session": sid, "pane": "lowLevelCode",
                                        "width": 100, "height": 16})
    # Into the program: a step at a time until the listing has instructions.
    var listing = ""
    for i in 0 ..< 12:
      let (_, notes) = srv.request("operation/run", %*{"session": sid,
        "operation": "debugger.step-into"})
      for n in notes.notes("pane/content"):
        if n{"params", "pane"}.getStr == "lowLevelCode":
          listing = ""
          for r in n{"params", "rows"}.getElems:
            listing.add r{"text"}.getStr & "\n"
      if listing.len > 0 and "No low-level code" notin listing:
        break
    checkpoint("Low Level Code:\n" & listing)
    check listing.len > 0 and "No low-level code" notin listing

    # ---- Generated-Code-Listing §13.4: the generated C --------------------
    # Into the program's own module, then the editor's cursor on the stop.
    var at = (file: "", line: 0)
    for i in 0 ..< 40:
      let (_, notes) = srv.request("operation/run", %*{"session": sid,
        "operation": "debugger.step-into"})
      for n in notes.notes("session/position"):
        at = (file: n{"params", "file"}.getStr, line: n{"params", "line"}.getInt)
      if at.file.endsWith("flow_test.nim"):
        break
    checkpoint("stop: " & $at)
    check at.file.endsWith("flow_test.nim")
    discard srv.request("source/cursor", %*{"session": sid, "file": at.file,
                                            "line": at.line, "column": 1})
    # As an editor meets it: the pane not shown, the layout not placing it.
    discard srv.request("pane/close", %*{"session": sid, "pane": "lowLevelCode"})
    let (shown, shownNotes) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    checkpoint("view.generated-c-source answered " & $shown)
    check shown{"result", "ok"}.getBool
    # The layout now places the pane beside the source; the editor opens it.
    let placed = shownNotes.notes("layout/changed")
    check placed.len == 1 and "lowLevelCode" in $placed[0]{"params", "layout"}
    let (_, openNotes) = srv.request("pane/open", %*{"session": sid,
      "pane": "lowLevelCode", "width": 100, "height": 16})
    var cRows: seq[string] = @[]
    for n in openNotes.notes("pane/content"):
      if n{"params", "pane"}.getStr == "lowLevelCode":
        cRows = @[]
        for r in n{"params", "rows"}.getElems:
          cRows.add r{"text"}.getStr
    checkpoint("generated C rows:\n" & cRows[0 ..< min(cRows.len, 20)].join("\n"))
    # The pane shows the C the cursor's line compiled to: the directive
    # naming that line is in view, not the file's `#define`s at its top.
    check cRows.anyIt(("#line " & $at.line & " ") in it)
    # "View Disassembly" is the pane's machine code again.
    let (asmShown, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.disassembly"})
    check asmShown{"result", "ok"}.getBool
    # Outside a Nim source the operation refuses, with its reason.
    discard srv.request("source/cursor", %*{"session": sid,
      "file": "/somewhere/else.py", "line": 1, "column": 1})
    let (refused, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    check not refused{"result", "ok"}.getBool
    check "not a Nim source" in refused{"result", "detail"}.getStr
    discard srv.request("shutdown")


# ---------------------------------------------------------------------------
# §E9 "A project, not only a recording", and HSF-E11: Edit mode's generated C
# ---------------------------------------------------------------------------

const
  TinyNim = "proc triple(n: int): int =\n" &
            "  let zebraCount = n * 3\n" &
            "  result = zebraCount + 1\n" &
            "\n" &
            "echo triple(14)\n"
    ## Line 2's C names `zebraCount` (CodeTracer's Nim and a stock one both
    ## keep a local's name, suffixed), so the listing's anchored row can be
    ## checked by its text as well as by its mapping.
  BrokenNim = "let answer: int = \"forty-two\"\n"
    ## A type error: `nim c` fails with "type mismatch".

proc paneRowsOf(msgs: seq[JsonNode]; pane: string;
                rows: var seq[string]): bool =
  ## The rows of the last `pane/content` for `pane` in `msgs` applied to
  ## `rows` (a full update replaces them, a partial one patches them); true
  ## when there was one.
  for n in msgs.notes("pane/content"):
    if n{"params", "pane"}.getStr != pane:
      continue
    result = true
    if n{"params", "full"}.getBool:
      rows = @[]
    for r in n{"params", "rows"}.getElems:
      let i = r{"index"}.getInt
      while rows.len <= i: rows.add ""
      rows[i] = r{"text"}.getStr

proc tickUntil(srv: PaneServer; pane: string; rows: var seq[string];
               done: proc(rows: seq[string]): bool; seconds = 120.0): bool =
  ## The server's loop polled (`tick`, as `runPaneServer` does every
  ## `TickMs`) until `pane`'s rows satisfy `done`.
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    discard paneRowsOf(srv.tick(), pane, rows)
    if done(rows):
      return true
    sleep(100)
  false

proc anchoredRow(m: LowLevelPaneModel): int =
  ## The listing's anchored instruction: the VM index of the model's active
  ## row, -1 for none.
  if m.activeRow < 0 or m.activeRow >= m.rows.len: -1
  else: m.rows[m.activeRow].index

suite "§E9 and HSF-E11: a project session, and Edit mode's generated C":

  test "session/open {project}: an Edit-mode session with no recording":
    # Editor-Hosted-Front-Ends §E9 ("A project, not only a recording"): a
    # project folder opens in Edit mode, with the project's files, its files
    # read from disk inside it, and DAP refused — there is nothing to debug.
    let project = createTempDir("ct-e9-project-", "")
    writeFile(project / "tiny.nim", TinyNim)
    createDir(project / "sub")
    writeFile(project / "sub" / "other.nim", "echo 1\n")
    let srv = newPaneServer(dap = false)
    discard srv.request("initialize", %*{"capabilities": {"media": ["text"]},
                                         "keymapOverrides": []})
    let (opened, notes) = srv.request("session/open", %*{"project": project})
    checkpoint("open: " & $opened)
    check opened{"error"}.isNil
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    check opened{"result", "mode"}.getStr == "edit"
    check opened{"result", "graphics", "available"}.getBool == false
    # Edit mode's own layout, and the session's keys, sent as for a recording.
    check notes.notes("pane/keymap").len >= 1
    # A project session has no debugger position.
    check notes.notes("session/position").len == 0
    let (listed, _) = srv.request("session/list")
    check listed{"result"}.getElems.anyIt(it{"session"}.getInt == sid and
      it{"mode"}.getStr == "edit" and it{"project"}.getStr == project)
    # Its files are the project's, as Edit mode lists them.
    let (files, _) = srv.request("session/files", %*{"session": sid})
    let paths = files{"result"}.getElems.mapIt(it{"path"}.getStr)
    checkpoint("files: " & $paths)
    check (project / "tiny.nim") in paths
    check (project / "sub" / "other.nim") in paths
    # A file is read from disk, inside the project only.
    let (read, _) = srv.request("source/read", %*{"session": sid,
                                                  "file": project / "tiny.nim"})
    check read{"result", "text"}.getStr == TinyNim
    let (outside, _) = srv.request("source/read", %*{"session": sid,
      "file": project / ".." / "elsewhere.nim"})
    check not outside{"error"}.isNil
    check "outside the project" in outside{"error", "message"}.getStr
    # A pane is painted from the runtime: the Files pane lists the project.
    let (_, fileNotes) = srv.request("pane/open", %*{"session": sid,
      "pane": "fileTree", "width": 40, "height": 12})
    var tree: seq[string] = @[]
    check paneRowsOf(fileNotes, "fileTree", tree)
    checkpoint("file tree:\n" & tree.join("\n"))
    check tree.anyIt("tiny.nim" in it)
    # DAP: refused, with the reason.
    let dap = srv.handleDap(%*{"seq": 1, "type": "request",
                               "command": "threads"})
    check dap.len == 1 and not dap[0]{"success"}.getBool
    check "no recording" in dap[0]{"message"}.getStr
    let step = srv.handleDap(%*{"seq": 2, "type": "request", "command": "next"})
    check not step[0]{"success"}.getBool
    # A folder that holds a recording opens the recording, as `ct` does.
    let recording = resolveFixture(FixtureName)
    if recording.outcome != foMissingPrereq:
      let (asProject, _) = srv.request("session/open",
                                       %*{"project": recording.tracePath})
      checkpoint("recording as project: " & $asProject)
      check asProject{"result", "mode"}.getStr == "debug"
    # Not a folder: refused.
    let (missing, _) = srv.request("session/open",
                                   %*{"project": project / "nope"})
    check "no such folder" in missing{"error", "message"}.getStr
    discard srv.request("shutdown")
    removeDir(project)

  test "HSF-E11: View Generated C in Edit mode compiles the file, its caret's row in view":
    # Generated-Code-Listing §13.4, Edit mode: the C comes from the compiler,
    # now (`native_nim_c_compiler`), asynchronously — the pane opens at once
    # saying it is compiling, and the listing follows on the loop's poll,
    # scrolled to the row anchored to the cursor's line. The REAL `nim`.
    if findExe("nim").len == 0:
      echo "  MISSING-PREREQ SKIP: `nim` is not on PATH"
      skip()
      return
    let project = createTempDir("ct-e11-project-", "")
    # Enough Nim above the line that its C is far down the file, so "in
    # view" is not the file's top.
    var source = ""
    for i in 1 .. 40:
      source.add "proc filler" & $i & "(): int = " & $i & "\n"
    let zebraLine = 40 + 2
    source.add TinyNim
    writeFile(project / "tiny.nim", source)
    writeFile(project / "broken.nim", BrokenNim)
    let srv = newPaneServer(dap = false)
    discard srv.request("initialize", %*{"capabilities": {"media": ["text"]},
                                         "keymapOverrides": []})
    let (opened, _) = srv.request("session/open", %*{"project": project})
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    if sid <= 0: return
    discard srv.request("source/cursor", %*{"session": sid,
      "file": project / "tiny.nim", "line": zebraLine, "column": 3})
    let (shown, shownNotes) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    checkpoint("view.generated-c-source answered " & $shown)
    check shown{"result", "ok"}.getBool
    check "compiling" in shown{"result", "detail"}.getStr
    # The layout places the pane beside the source; the editor opens it and
    # it says it is compiling.
    let placed = shownNotes.notes("layout/changed")
    check placed.len == 1 and "lowLevelCode" in $placed[0]{"params", "layout"}
    let (_, openNotes) = srv.request("pane/open", %*{"session": sid,
      "pane": "lowLevelCode", "width": 100, "height": 16})
    var cRows: seq[string] = @[]
    check paneRowsOf(openNotes, "lowLevelCode", cRows)
    checkpoint("while compiling:\n" & cRows.join("\n"))
    check cRows.anyIt("compiling tiny.nim" in it)
    # The listing arrives on the loop's poll.
    check srv.tickUntil("lowLevelCode", cRows,
      proc(rows: seq[string]): bool = rows.anyIt("zebraCount" in it))
    checkpoint("generated C rows:\n" & cRows.join("\n"))
    # The row the listing anchored to the cursor maps back to the cursor's
    # line, and it is IN VIEW — not the file's top: line 2 of the program
    # is below forty procs' C.
    let rt = srv.activeRuntime()
    let m = rt.app.lowLevel
    let anchored = m.anchoredRow
    check anchored >= 0
    let edit = srv.activeEdit()
    check not edit.listing.isNil
    if anchored >= 0 and not edit.listing.isNil:
      let back = edit.listing.sourceLineOf(anchored)
      check back.line == zebraLine
      check back.path.endsWith("tiny.nim")
      check m.scrollTop > 0
      # The row as the pane shows it (a long one ends in "…").
      let shownText = m.rows[m.activeRow].instruction.strip
      check cRows.anyIt(shownText[0 ..< min(30, shownText.len)] in it)
    # And the C of the line after its anchor: the local's assignment.
    check cRows.anyIt("zebraCount" in it and " = " in it and "NI " notin it)
    # A press goes to the Nim line in the editor's buffer; a step refuses.
    if anchored >= 0:
      let pressed = rt.app.lowLevelAct(LowLevelAct(kind: llaPress,
                                                    index: anchored))
      checkpoint("press: " & pressed.note)
      let buf = rt.app.editSession.activeBuffer()
      check buf.path.endsWith("tiny.nim")
      check buf.caretLine == zebraLine
      let stepped = rt.app.lowLevelAct(LowLevelAct(kind: llaStep,
        operation: "debugger.step-over"))
      check "no replay" in stepped.note
    # THROUGH THE PROTOCOL: the anchored row's hotspot, pressed as an editor
    # presses it, moves the editor's cursor to the Nim line — `source/show`
    # carries the position (§E7), not only the file. The cursor is put
    # elsewhere first, so the move is the press's.
    discard srv.request("source/cursor", %*{"session": sid,
      "file": project / "tiny.nim", "line": 1, "column": 1})
    let (_, full) = srv.request("pane/resize", %*{"session": sid,
      "pane": "lowLevelCode", "width": 100, "height": 16})
    var spot: JsonNode = nil
    for n in full.notes("pane/content"):
      for r in n{"params", "rows"}.getElems:
        for h in r{"hotspots"}.getElems:
          if h{"operation"}.getStr == "low-level.go-to-source-line" and
             h{"args", "index"}.getInt(-1) == anchored:
            spot = h
    checkpoint("the anchored row's hotspot: " &
               (if spot.isNil: "none in " & $full.notes("pane/content").len &
                  " pane/content" else: $spot))
    check not spot.isNil
    if not spot.isNil:
      let (went, wentNotes) = srv.request("operation/run", %*{"session": sid,
        "pane": "lowLevelCode", "operation": spot{"operation"}.getStr,
        "args": spot{"args"}})
      checkpoint("press: " & $went & "\n" & $wentNotes.notes("source/show"))
      check went{"result", "ok"}.getBool
      let shows = wentNotes.notes("source/show")
      check shows.len == 1
      if shows.len == 1:
        let p = shows[0]{"params"}
        check p{"file"}.getStr == project / "tiny.nim"
        check p{"line"}.getInt == zebraLine
        check p{"column"}.getInt == 1
    # A file opened from the Files pane is shown where the editor left it:
    # no position.
    let (_, opened2) = srv.request("operation/run", %*{"session": sid,
      "pane": "fileTree", "operation": "file-tree.open",
      "args": {"path": project / "broken.nim"}})
    let opens = opened2.notes("source/show")
    check opens.len == 1
    for n in opens:
      check n{"params", "file"}.getStr == project / "broken.nim"
      check not n{"params"}.hasKey("line")
    # A file that does not compile: the compiler's error, in the pane.
    discard srv.request("source/cursor", %*{"session": sid,
      "file": project / "broken.nim", "line": 1, "column": 1})
    let (broken, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    check broken{"result", "ok"}.getBool
    check srv.tickUntil("lowLevelCode", cRows,
      proc(rows: seq[string]): bool = rows.anyIt("Error:" in it))
    checkpoint("broken:\n" & cRows.join("\n"))
    check cRows.anyIt("type mismatch" in it)
    check "type mismatch" in rt.app.notification
    # No compiler: refused at once, with the reason.
    putEnv("CODETRACER_NIM", project / "no-such-nim")
    discard srv.request("source/cursor", %*{"session": sid,
      "file": project / "tiny.nim", "line": zebraLine, "column": 1})
    let (noNim, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    delEnv("CODETRACER_NIM")
    checkpoint("no nim: " & $noNim)
    check not noNim{"result", "ok"}.getBool
    check "no `nim`" in noNim{"result", "detail"}.getStr
    discard srv.request("shutdown")
    removeDir(project)

  test "HSF-E11: a recording made by `ct record` shows its C, and Edit mode compiles":
    # Debug mode over today's `ct record` recording of a Nim program: the C
    # and its source maps are in `<trace>/nimcache/`, which the recording's
    # file tree does not list; the listing is anchored by the maps (the
    # fork writes no `#line`). Then the same session toggled into Edit mode
    # compiles the source instead (Edit mode means the edited file).
    let rec = nimForkRecording()
    if not rec.ok:
      echo "  ", MissingPrereqSkipPrefix, " ", NimForkFixtureName, " — ",
           rec.detail
      skip()
      return
    let srv = newPaneServer(dap = false)
    discard srv.request("initialize", %*{"capabilities": {"media": ["text"]},
                                         "keymapOverrides": []})
    let (opened, _) = srv.request("session/open", %*{"trace": rec.tracePath})
    checkpoint("open: " & $opened)
    let sid = opened{"result", "session"}.getInt
    check sid > 0
    if sid <= 0: return
    var at = (file: "", line: 0)
    for i in 0 ..< 60:
      let (_, notes) = srv.request("operation/run", %*{"session": sid,
        "operation": "debugger.step-into"})
      for n in notes.notes("session/position"):
        at = (file: n{"params", "file"}.getStr, line: n{"params", "line"}.getInt)
      if at.file.endsWith("nim_flow_test.nim") and at.line > 0:
        break
    checkpoint("stop: " & $at)
    check at.file.endsWith("nim_flow_test.nim")
    discard srv.request("source/cursor", %*{"session": sid, "file": at.file,
                                            "line": at.line, "column": 1})
    let (shown, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    checkpoint("view.generated-c-source answered " & $shown)
    check shown{"result", "ok"}.getBool
    let (_, openNotes) = srv.request("pane/open", %*{"session": sid,
      "pane": "lowLevelCode", "width": 100, "height": 16})
    var cRows: seq[string] = @[]
    discard paneRowsOf(openNotes, "lowLevelCode", cRows)
    checkpoint("generated C rows:\n" & cRows.join("\n"))
    check not cRows.anyIt("carries no generated C" in it)
    let rt = srv.activeRuntime()
    let m = rt.app.lowLevel
    let anchored = m.anchoredRow
    check anchored >= 0
    if anchored >= 0:
      let vm = srv.activeReplay().session.session.lowLevelCodeVM
      let back = vm.sourceLineOf(anchored)
      check back.line == at.line
      check back.path.endsWith("nim_flow_test.nim")
      let shownText = m.rows[m.activeRow].instruction.strip
      check cRows.anyIt(shownText[0 ..< min(30, shownText.len)] in it)
    # Edit mode: the edited source's C, compiled now — not the recording's.
    let (toggled, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "session.toggle-product-mode"})
    check toggled{"result", "ok"}.getBool
    let program = rec.sourcePath
    discard srv.request("source/cursor", %*{"session": sid, "file": program,
                                            "line": 8, "column": 3})
    let (compiling, _) = srv.request("operation/run", %*{"session": sid,
      "operation": "view.generated-c-source"})
    checkpoint("edit-mode view.generated-c-source: " & $compiling)
    check compiling{"result", "ok"}.getBool
    check "compiling" in compiling{"result", "detail"}.getStr
    check srv.tickUntil("lowLevelCode", cRows,
      proc(rows: seq[string]): bool = rows.anyIt("doubled" in it))
    let em = rt.app.lowLevel
    let edit = srv.activeEdit()
    if em.anchoredRow >= 0 and not edit.listing.isNil:
      check edit.listing.sourceLineOf(em.anchoredRow).line == 8
    else:
      check false
    discard srv.request("shutdown")
