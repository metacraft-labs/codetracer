## pane_server.nim — `codetracer-tui --pane-server`: CodeTracer's panes for an
## editor that hosts them (Editor-Hosted-Front-Ends.md, HSF-E1).
##
## The editor (Neovim, Emacs) starts this process and talks to it over its
## stdio: JSON-RPC 2.0 with the LSP base protocol's `Content-Length` framing
## (https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#baseProtocol),
## the transport `vim.lsp.rpc` and `jsonrpc.el` already speak (§E2). It draws
## nothing: it answers for the content of each pane at the size of the editor
## window showing it.
##
## ## What it is built from
##
## Everything a pane shows is the terminal's: each session is a `TuiSession`
## (the `DebuggerSession` composition root, its stop loader and the shared
## `session_driver`) and a `TuiRuntime` over it, and a pane's rows are that
## runtime's own painting of the pane at the window's size
## (`runtime.hostedPaneRows`). An action is the operation a key bound to it
## runs (`runtime.runNamedOperation`) or what a click on the same cells of the
## terminal's pane does (`runtime.runPaneOperation`), and the session applies
## either as it applies a key's (`tui_session.applyOutcome`). So the editor and
## the terminal cannot show a pane differently, and no CodeTracer behaviour is
## written a second time here.
##
## ## The DAP endpoint (§ Open Questions Q3)
##
## The editor's own DAP client (nvim-dap, dap-mode, dape) may attach to a TCP
## endpoint this server listens on (`initialize`'s answer names it). It is a
## second CLIENT OF THE SAME SESSION, not a second connection to the engine:
## each DAP request becomes an operation on the active session, and every move
## — from DAP, a pane or a key — is pushed to both. DAP is framed exactly as
## the pane protocol is (the Debug Adapter Protocol's base protocol,
## https://microsoft.github.io/debug-adapter-protocol/overview#base-protocol).
##
## ## Shape
##
## `PaneServer.handle` takes one message and returns the messages to send:
## responses and notifications, as values. `runPaneServer` is the loop around
## it — stdin, the DAP listener and its client, one `select` — so the whole
## protocol is assertable in-process against a real recording
## (`tests/test_pane_server.nim`), and the stdio transport separately
## (`tests/real_terminal/test_pane_server_stdio.nim`).

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it owns the process's stdio.".}

import std/[base64, json, net, options, os, posix, selectors, strutils, tables, times, unicode]

import headless_app/layout_model
import codetracer_embed

import ../app/cli
import ../app/edit_binding
import ../app/views/file_tree
from ../../viewmodel/store/types import FilesystemEntryNode
from isonim/core/signals import val
import ../app/pane_protocol
import ../app/runtime
import ../app/theme/capabilities as app_capabilities
import ../app/tui_app
import ../app/views/gutter
import ../app/views/inline_annotations
import ../app/views/variables
import ../app/views/shell
import ./native_host
import ./tui_session
import ./visual_replay_host
from ../app/source_binding import sptBreakpoint
import ../../viewmodel/host/keymap_preference
import ../../viewmodel/host/keybindings_file

const
  ServerName* = "codetracer-tui pane server"
  NominalWidth = 200
  NominalHeight = 60
    ## The size the runtime's own screen is given. Only the LAYOUT PROFILE is
    ## read from it — the logical layout an editor realises is the desktop's
    ## standard one — since every pane an editor shows is painted at its own
    ## window's size.
  ErrInvalidParams = -32602
  ErrMethodNotFound = -32601
  ErrNotInitialized = -32002
  ErrRequestFailed = -32803

type
  HostedPane = object
    width, height: int
    rows: seq[JsonNode]
      ## What the editor holds, so an update sends only the rows that changed.

  ServerSession = ref object
    id: int
    folder: string
    app: TuiApp
    rt: TuiRuntime
    tui: TuiSession
    panes: Table[PaneKind, HostedPane]
    product: ProductMode
    layoutSent: string
    position: tuple[file: string; line: int; tick: uint64]
    sourceView: tuple[file: string; first, last: int]
    cursor: tuple[file: string; line, column: int]
      ## Where the editor's cursor is in its source window
      ## (`source/cursor`): the line an operation that acts "at the cursor"
      ## (a breakpoint, a tracepoint) acts on, as the terminal's caret is.
    decorationsSent: string
    graphics: GraphicsHost
      ## The recording's graphics (`visual_replay_host`), nil without any.
    frame: int
      ## The frame the frame viewer shows.
    frameView: Option[HostedPane]
      ## The frame viewer, when the editor shows it.
    imageSent: string
      ## Which frame's image the editor holds, so it is sent once per frame.
    pngCache: tuple[frame: int; png: string; width, height: int]
    viewedSent: string
      ## The viewed file (`TuiApp.viewedFile`) last sent as `source/show`.
    showRequest: string
      ## A file a pane's row asked to open (`file-tree.open`), to be shown in
      ## the editor's source window even when it is the stop's own file —
      ## which the terminal already shows, and so does not count as viewed.

  DapEndpoint = object
    listener: Socket
    client: Socket
    port: int
    seqNo: int
    refs: seq[string]
      ## `variablesReference` n is `refs[n - 1]`: a variables-pane path.
    attached: bool

  PaneServer* = ref object
    sessions: seq[ServerSession]
    active: int
      ## Index into `sessions`, -1 with none.
    nextId: int
    initialized: bool
    shutdownRequested*: bool
    exitRequested*: bool
    media: seq[string]
    shadowed: Table[string, seq[string]]
      ## Per pane wire name ("" for every pane): the keys the editor's own
      ## configuration binds there (§E6, ED-AREQ6).
    dap: DapEndpoint
    dapOut: seq[JsonNode]
      ## DAP messages to send to the attached client.
    dapEnabled*: bool

proc newPaneServer*(dap = true): PaneServer =
  PaneServer(active: -1, nextId: 1, dapEnabled: dap)

# ---------------------------------------------------------------------------
# Framing (the LSP base protocol)
# ---------------------------------------------------------------------------

type
  Framer* = object
    ## Bytes in, whole messages out.
    buf: string

proc frame*(msg: JsonNode): string =
  let body = $msg
  "Content-Length: " & $body.len & "\r\n\r\n" & body

proc feed*(f: var Framer; data: string) =
  f.buf.add data

proc next*(f: var Framer): Option[JsonNode] =
  ## The next whole message, if the buffer holds one. A message that is not
  ## JSON is answered by the caller as a parse error (JSON-RPC 2.0 §5.1).
  let headerEnd = f.buf.find("\r\n\r\n")
  if headerEnd < 0:
    return none(JsonNode)
  var length = -1
  for line in f.buf[0 ..< headerEnd].split("\r\n"):
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip().toLowerAscii == "content-length":
      try: length = parseInt(line[colon + 1 .. ^1].strip())
      except ValueError: length = -1
  if length < 0:
    # No usable header: drop it rather than wedge on it.
    f.buf = f.buf[headerEnd + 4 .. ^1]
    return none(JsonNode)
  let start = headerEnd + 4
  if f.buf.len < start + length:
    return none(JsonNode)
  let body = f.buf[start ..< start + length]
  f.buf = f.buf[start + length .. ^1]
  try:
    some(parseJson(body))
  except CatchableError:
    some(%*{"__unparsable": body})

# ---------------------------------------------------------------------------
# JSON-RPC values
# ---------------------------------------------------------------------------

proc response(id: JsonNode; res: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "result": res}

proc errorResponse(id: JsonNode; code: int; message: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

proc notification(meth: string; params: JsonNode): JsonNode =
  %*{"jsonrpc": "2.0", "method": meth, "params": params}

type
  RequestError = object of CatchableError
    code: int

proc fail(code: int; message: string) {.noreturn.} =
  var e = newException(RequestError, message)
  e.code = code
  raise e

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

proc paneCaps(): TerminalCapabilities =
  ## A terminal that can show every glyph the painters draw. The editor maps
  ## the semantic styles to its own colours, so no colour is decided here.
  resolveCapabilities(TerminalEnv(term: "xterm-256color", colorterm: "truecolor",
                                  lang: "en_US.UTF-8", isTty: true),
                      initCapabilityFlags())

proc wireKeymap(rt: TuiRuntime) =
  ## The user's shared CodeTracer keymap (ED-AREQ6): the base they chose and
  ## their `keybindings.json` over it — what the terminal, GPUI and the
  ## desktop load.
  let pref = sessionKeymap("")
  rt.selectBase(pref.model, case pref.reason
                            of "stored": ksStored
                            else: ksDefault)
  let user = readKeybindings()
  if user.readError.len == 0:
    discard rt.applyUserKeymap(user.keymap)

proc sessionById(srv: PaneServer; params: JsonNode): ServerSession =
  ## The session `params.session` names, else the active one.
  let id = params{"session"}.getInt(-1)
  if id >= 0:
    for s in srv.sessions:
      if s.id == id:
        return s
    fail(ErrInvalidParams, "no session " & $id)
  if srv.active < 0:
    fail(ErrRequestFailed, "no session is open")
  srv.sessions[srv.active]

proc currentLayout(s: ServerSession): LayoutNode =
  s.app.shellModel(NominalWidth, NominalHeight).layout

proc openServerSession(srv: PaneServer; trace: string): ServerSession =
  let folder = resolveTraceFolder(trace)
  let problem = traceFolderProblem(folder)
  if problem.len > 0:
    fail(ErrRequestFailed, folder & ": " & problem)
  if findReplayServer().len == 0:
    fail(ErrRequestFailed, replayServerRemedy())
  let app = newTuiApp()
  let rt = newTuiRuntime(app, paneCaps(), NominalWidth, NominalHeight)
  # THE MODE'S LAYOUT IS HELD, so the editor's edits to it (`layout/edited`)
  # persist for the session and a mode switch returns to them
  # (Mode-Transitions §4a): the register owns one tree per mode.
  app.modes.layouts[pmDebug] = layoutForMode(pmDebug,
    selectProfile(NominalWidth, NominalHeight))
  wireKeymap(rt)
  var tui: TuiSession = nil
  try:
    tui = openTuiSession(folder, viewportHeight = 1,
                         bound = DapReadBound(timeoutMs: handshakeBudgetMs(),
                                              interruptFd: -1))
  except EngineStalledAfterOpenError as e:
    fail(ErrRequestFailed, "cannot open " & folder & ": " &
         StalledAfterOpenPhrase & " (" & e.msg & ")")
  except CatchableError as e:
    fail(ErrRequestFailed, "cannot open " & folder & ": " & e.msg)
  tui.disarmHandshakeInterrupt()
  # An editor's user is watching: a sweep or a `continue` that is silent for
  # longer than the clock is a slow engine, not a stopped one (§8b).
  tui.allowSlowOperations()
  # Every pane is hosted from here on: a pane the editor does not show has
  # no viewport, and the source window is the editor's.
  rt.hostedRows[paneEditor] = 0
  tui.header(rt)
  # The first pane loads: an engine that answers none of them is reported
  # after ONE budget, in §8b's after-open wording, and its child is closed
  # rather than left behind a session the editor never received.
  try:
    tui.learnExtent()
    tui.refresh(rt)
  except DapStalledError as e:
    tui.close()
    fail(ErrRequestFailed, "cannot open " & folder & ": " &
         StalledAfterOpenPhrase & " (" & e.msg & ")")
  result = ServerSession(id: srv.nextId, folder: folder, app: app, rt: rt,
                         tui: tui, product: app.modes.product,
                         pngCache: (frame: -1, png: "", width: 0, height: 0))
  # A recording that carries a gfx stream has graphics: the player the
  # desktop starts for it serves its frames.
  result.graphics = startGraphics(folder)
  inc srv.nextId
  srv.sessions.add result
  srv.active = srv.sessions.len - 1

proc close(s: ServerSession) =
  if not s.graphics.isNil:
    s.graphics.close()
    s.graphics = nil
  if not s.tui.isNil:
    s.tui.close()
    s.tui = nil

proc modeName(p: ProductMode): string =
  if p == pmEdit: "edit" else: "debug"

proc layoutParams(s: ServerSession): JsonNode =
  %*{"session": s.id, "mode": modeName(s.app.modes.product),
     "layout": layoutJson(s.currentLayout())}

proc graphicsJson(s: ServerSession): JsonNode =
  ## What `session/open` says of the recording's graphics.
  let g = s.graphics
  if g.isNil:
    return %*{"available": false}
  result = %*{"available": g.error.len == 0, "frameCount": g.frameCount,
              "width": g.width, "height": g.height}
  if g.error.len > 0:
    result["error"] = %g.error

# ---------------------------------------------------------------------------
# What is pushed after a change
# ---------------------------------------------------------------------------

proc paneHotspots(s: ServerSession; pane: PaneKind; w, h: int): seq[seq[PaneHotspot]] =
  s.rt.hostedHotspots(pane, w, h)

proc paneRows(s: ServerSession; pane: PaneKind; w, h: int): seq[JsonNode] =
  let rows = s.rt.hostedPaneRows(pane, w, h)
  let spots = s.paneHotspots(pane, w, h)
  for i, row in rows:
    result.add rowJson(row, if i < spots.len: spots[i] else: @[])

proc contentOf(s: ServerSession; pane: PaneKind; full: bool): JsonNode =
  ## `pane/content` for `pane`: every row when `full`, else the rows that
  ## differ from what the editor holds — nil when nothing changed.
  var hp = s.panes[pane]
  let fresh = s.paneRows(pane, hp.width, hp.height)
  var changed = newJArray()
  for i, r in fresh:
    if full or i >= hp.rows.len or hp.rows[i] != r:
      var entry = copy(r)
      entry["index"] = %i
      changed.add entry
  hp.rows = fresh
  s.panes[pane] = hp
  if not full and changed.len == 0:
    return nil
  notification("pane/content",
    %*{"session": s.id, "pane": $pane, "width": hp.width,
       "height": hp.height, "full": full, "rows": changed})

proc wantsImages(srv: PaneServer): bool =
  "image" in srv.media

proc frameViewerRows(s: ServerSession; withImage: bool;
                     w, h: int): seq[JsonNode] =
  ## The frame viewer's text: which frame of how many, and the controls that
  ## move between frames. The text medium's whole pane, and the caption of
  ## the image an image-capable editor draws below it.
  let g = s.graphics
  var lines: seq[(string, seq[JsonNode])] = @[]
  if g.isNil:
    lines.add ("This recording has no graphics.", @[])
  elif g.error.len > 0:
    lines.add ("Graphics: " & g.error, @[])
  else:
    let size = if g.width > 0: " · " & $g.width & "×" & $g.height else: ""
    let unit = if g.selector == "draw": "Draw " else: "Frame "
    lines.add (unit & $(s.frame + 1) & " of " & $g.frameCount & size, @[])
    let prev = "◀ previous"
    let next = "next ▶"
    let controls = prev & "   " & next
    lines.add (controls, @[
      %*{"start": 0, "end": prev.len, "operation": "frame-viewer.previous-frame",
         "args": {}},
      %*{"start": prev.len + 3, "end": controls.len,
         "operation": "frame-viewer.next-frame", "args": {}}])
    if not withImage:
      lines.add ("The frame is an image; an editor that declares the image " &
                 "medium draws it here.", @[])
  for i in 0 ..< h:
    if i < lines.len:
      let text = lines[i][0]
      let shown = if text.runeLen > w: text.runeSubStr(0, w) else: text
      var row = %*{"text": shown, "spans": []}
      if lines[i][1].len > 0 and shown == text:
        row["hotspots"] = %lines[i][1]
      result.add row
    else:
      result.add %*{"text": "", "spans": []}

proc frameImage(s: ServerSession): JsonNode =
  ## The current frame as a PNG, for an editor that draws images; nil when
  ## there is none to draw.
  let g = s.graphics
  if g.isNil or g.error.len > 0 or g.frameCount <= 0:
    return nil
  if s.pngCache.frame != s.frame:
    let (f, png) = g.framePng(s.frame)
    s.pngCache = (frame: s.frame, png: png, width: f.width, height: f.height)
  %*{"mediaType": "image/png", "encoding": "base64",
     "data": encode(s.pngCache.png), "width": s.pngCache.width,
     "height": s.pngCache.height, "frame": s.frame,
     "frameCount": g.frameCount}

proc frameViewerContent(srv: PaneServer; s: ServerSession; full: bool): JsonNode =
  ## `pane/content` for the frame viewer: its rows as for any pane (only the
  ## changed ones unless `full`), and — for an editor that declared the
  ## image medium — the frame's `image`, sent when the editor does not hold
  ## that frame yet.
  if s.frameView.isNone:
    return nil
  var hp = s.frameView.get
  let withImage = srv.wantsImages and not s.graphics.isNil and
                  s.graphics.error.len == 0
  let fresh = s.frameViewerRows(withImage, hp.width, hp.height)
  var changed = newJArray()
  for i, r in fresh:
    if full or i >= hp.rows.len or hp.rows[i] != r:
      var entry = copy(r)
      entry["index"] = %i
      changed.add entry
  hp.rows = fresh
  s.frameView = some(hp)
  var image: JsonNode = nil
  let key = $s.frame
  if withImage and (full or s.imageSent != key):
    try:
      image = s.frameImage()
      s.imageSent = key
    except CatchableError as e:
      s.graphics.error = "frame " & $(s.frame + 1) & ": " & e.msg
  if not full and changed.len == 0 and image.isNil:
    return nil
  result = notification("pane/content",
    %*{"session": s.id, "pane": FrameViewerPane, "width": hp.width,
       "height": hp.height, "full": full, "rows": changed})
  if not image.isNil:
    result["params"]["image"] = image

proc keymapOf(srv: PaneServer; s: ServerSession; pane: PaneKind): JsonNode =
  var shadowed = srv.shadowed.getOrDefault("")
  shadowed.add srv.shadowed.getOrDefault($pane)
  notification("pane/keymap",
    %*{"session": s.id, "pane": $pane,
       "bindings": keymapJson(s.rt.paneShortcutReference(pane), shadowed)})

proc markName(m: GutterMark): string =
  case m
  of gmBreakpoint: "breakpoint"
  of gmBreakpointDisabled: "breakpoint-disabled"
  of gmTracepoint: "tracepoint"
  of gmNone: ""

proc decorationsOf(s: ServerSession): JsonNode =
  ## `source/decorations` for the lines the editor reported visible (§E7):
  ## the execution line, gutter marks and inline values, from the same source
  ## model the terminal's source pane draws.
  let v = s.sourceView
  if v.file.len == 0:
    return nil
  let src = s.app.source
  var rows = newJArray()
  if src.path == v.file:
    for line in max(1, v.first) .. v.last:
      var row = %*{"line": line}
      var any = false
      if line == src.executionLine:
        row["execution"] = %true
        any = true
        if src.values.len > 0:
          var vals = newJArray()
          for a in src.values:
            vals.add %*{"name": a.name, "value": a.value}
          row["values"] = vals
      for (l, mark) in src.marks:
        if l == line and mark != gmNone:
          row["mark"] = %markName(mark)
          any = true
      for (l, anns) in src.lineValues:
        if l == line and anns.len > 0:
          var vals = newJArray()
          for a in anns:
            vals.add %*{"name": a.name, "value": a.value}
          row["flow"] = vals
          any = true
      if any:
        rows.add row
  notification("source/decorations",
    %*{"session": s.id, "file": v.file, "firstLine": v.first,
       "lastLine": v.last, "rows": rows})

proc dapEvent(srv: PaneServer; event: string; body: JsonNode)

proc publish(srv: PaneServer; s: ServerSession; fullPanes: seq[PaneKind] = @[];
             fullFrameViewer = false): seq[JsonNode] =
  ## Everything the editor holds that this session's state changed: a new
  ## mode's layout, the debugger's position, the open panes' rows and the
  ## visible source lines' decorations. The DAP client is told of a move.
  let product = s.app.modes.product
  let layout = $layoutJson(s.currentLayout())
  if product != s.product or layout != s.layoutSent:
    s.product = product
    s.layoutSent = layout
    result.add notification("layout/changed", s.layoutParams())
  let t = s.tui.session
  let pos = (file: t.getCurrentFile(), line: t.getCurrentLine(),
             tick: t.getCurrentRRTicks())
  if pos != s.position:
    s.position = pos
    let col = t.getCurrentColumn()
    result.add notification("session/position",
      %*{"session": s.id, "file": pos.file, "line": pos.line,
         "column": (if col.isSome: col.get else: 1), "tick": pos.tick})
    if srv.dap.attached and srv.active >= 0 and srv.sessions[srv.active] == s:
      srv.dap.refs.setLen(0)
      srv.dapEvent("stopped", %*{"reason": "step", "threadId": 1,
                                 "allThreadsStopped": true})
  for pane in s.panes.keys:
    let n = s.contentOf(pane, pane in fullPanes)
    if not n.isNil:
      result.add n
  let fv = srv.frameViewerContent(s, fullFrameViewer)
  if not fv.isNil:
    result.add fv
  let deco = s.decorationsOf()
  if not deco.isNil and $deco != s.decorationsSent:
    s.decorationsSent = $deco
    result.add deco
  # A file a pane opened is shown in the editor's source window (§E7): the
  # editor owns the source, so the server only names the file. One the
  # editor cannot open from disk it reads with `source/read`.
  let viewed = s.app.viewedFile
  var show = s.showRequest
  s.showRequest = ""
  if viewed != s.viewedSent:
    s.viewedSent = viewed
    if show.len == 0:
      show = viewed
  if show.len > 0:
    result.add notification("source/show", %*{"session": s.id, "file": show})

proc resyncViewports(s: ServerSession) =
  ## The editor's windows changed size: each pane's viewport is its window's,
  ## so the session loads what the windows now show.
  s.tui.setViewportHeight(s.rt.sourcePaneRows())
  s.tui.refresh(s.rt)

# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------

proc paneParam(params: JsonNode): PaneKind =
  let name = params{"pane"}.getStr("")
  let (ok, pane) = paneOfWire(name)
  if not ok or pane == paneEditor:
    fail(ErrInvalidParams, "'" & name & "' is not a pane the server draws " &
      "(the source editor is the editor's own)")
  pane

proc sizeParams(params: JsonNode): (int, int) =
  let w = params{"width"}.getInt(0)
  let h = params{"height"}.getInt(0)
  if w <= 0 or h <= 0:
    fail(ErrInvalidParams, "a pane's width and height are positive cell counts")
  (w, h)

proc recordedFiles(node: FilesystemEntryNode; acc: var seq[JsonNode]) =
  ## The files under `node` (folders walked, not listed).
  if not node.isFolder and node.path.len > 0:
    acc.add %*{"path": node.path, "name": node.text}
  for c in node.children:
    recordedFiles(c, acc)

proc applyCursor(s: ServerSession) =
  ## The editor's cursor is the caret the operations act at. In the terminal
  ## a debug-mode command's line is the command context's (the stop's line
  ## until a move rebuilds it) and an edit-mode one's is the edited file's
  ## caret; in an editor-hosted session both are the editor's cursor.
  let c = s.cursor
  if c.file.len == 0 or c.line <= 0:
    return
  s.rt.context.file = c.file
  s.rt.context.line = c.line
  if s.app.modes.product == pmEdit and not s.app.editSession.isNil:
    var at = s.app.editSession.indexOfPath(c.file)
    if at < 0 and fileExists(c.file):
      try:
        at = s.app.editSession.openFile(c.file, readFile(c.file))
      except IOError, OSError:
        at = -1
    if at >= 0:
      s.app.editSession.activateBuffer(at)
      s.app.editSession.activeBuffer().moveCaretTo(c.line - 1, max(0, c.column - 1))

proc runOperation(srv: PaneServer; s: ServerSession; params: JsonNode): JsonNode =
  ## `operation/run`: a catalogued operation, or a pane operation from a
  ## hotspot, applied to the session as a key or a click is.
  let text = params{"operation"}.getStr("")
  let (name, inlineArg) = splitOperation(text)
  let argument = params{"argument"}.getStr(inlineArg)
  for (op, _) in FrameViewerOperations:
    if op == name:
      let g = s.graphics
      if g.isNil or g.error.len > 0:
        fail(ErrRequestFailed, "this recording's graphics cannot be shown" &
          (if g.isNil: "" else: ": " & g.error))
      let last = max(0, g.frameCount - 1)
      case name
      of "frame-viewer.next-frame": s.frame = min(last, s.frame + 1)
      of "frame-viewer.previous-frame": s.frame = max(0, s.frame - 1)
      else: s.frame = clamp(int(paneArgsOf(params{"args"}).index), 0, last)
      return %*{"ok": true, "operation": text,
                "detail": "frame " & $(s.frame + 1) & " of " & $g.frameCount}
  if params.hasKey("pane") and params{"pane"}.getStr("") != FrameViewerPane:
    discard s.rt.focusHostedPane(paneParam(params))
  var outcome: RuntimeOutcome
  var isPaneOp = false
  for (op, _) in PaneOperations:
    if op == name: isPaneOp = true
  s.applyCursor()
  if isPaneOp:
    let args = paneArgsOf(params{"args"})
    discard s.rt.runPaneOperation(name, args, outcome)
    if name == "file-tree.open":
      s.showRequest = args.path
  elif isCatalogued(name):
    let problem = argumentProblem(name, argument)
    if problem.len > 0:
      fail(ErrInvalidParams, problem)
    outcome = s.rt.runNamedOperation(name, argument, epochTime().int64 * 1000)
  else:
    fail(ErrInvalidParams, "'" & name & "' is not an operation")
  s.app.notification = ""
  s.tui.applyOutcome(s.rt, outcome)
  let detail = if outcome.detail.len > 0: outcome.detail else: s.app.notification
  %*{"ok": true, "operation": text, "detail": detail}

proc handleRequest(srv: PaneServer; meth: string; params: JsonNode;
                   extra: var seq[JsonNode]): JsonNode =
  ## One request's result; notifications it causes go to `extra`.
  if not srv.initialized and meth != "initialize":
    fail(ErrNotInitialized, "the first request must be `initialize`")
  case meth
  of "initialize":
    srv.initialized = true
    srv.media = @[]
    for m in params{"capabilities", "media"}.getElems:
      srv.media.add m.getStr("")
    if srv.media.len == 0:
      srv.media = @["text"]
    for o in params{"keymapOverrides"}.getElems:
      let pane = o{"pane"}.getStr("")
      srv.shadowed.mgetOrPut(pane, @[]).add o{"key"}.getStr("")
    var dap = newJNull()
    if srv.dapEnabled and not srv.dap.listener.isNil:
      dap = %*{"host": "127.0.0.1", "port": srv.dap.port}
    result = %*{
      "protocolVersion": PaneProtocolVersion,
      "positionEncoding": PositionEncoding,
      "serverInfo": {"name": ServerName, "version": TuiVersionText},
      "capabilities": {
        # What this server will send: the image medium only to an editor
        # that declared it (Q2), text to every editor.
        "media": (if srv.wantsImages: %["text", "image"] else: %["text"]),
        "dap": dap,
        "panes": [$paneCalltrace, $paneState, $paneEventLog,
                  $panePointList, $paneScratchpad,
                  $paneTerminalOutput, $paneSearch,
                  $paneFileTree, $paneBuildOutput, $paneVcs,
                  FrameViewerPane]}}
  of "shutdown":
    srv.shutdownRequested = true
    for s in srv.sessions:
      s.close()
    srv.sessions.setLen(0)
    srv.active = -1
    result = newJNull()
  of "session/open":
    let trace = params{"trace"}.getStr("")
    if trace.len == 0:
      fail(ErrInvalidParams, "session/open names a `trace`")
    let s = srv.openServerSession(trace)
    s.layoutSent = $layoutJson(s.currentLayout())
    result = s.layoutParams()
    result["graphics"] = s.graphicsJson()
    extra.add srv.publish(s)
  of "session/list":
    result = newJArray()
    for i, s in srv.sessions:
      result.add %*{"session": s.id, "trace": s.folder,
                    "title": s.app.traceName,
                    "mode": modeName(s.app.modes.product),
                    "active": i == srv.active}
  of "session/activate":
    let s = srv.sessionById(params)
    srv.active = srv.sessions.find(s)
    extra.add notification("layout/changed", s.layoutParams())
    result = newJNull()
  of "session/close":
    let s = srv.sessionById(params)
    let at = srv.sessions.find(s)
    s.close()
    srv.sessions.delete(at)
    srv.active = if srv.sessions.len == 0: -1 else: min(srv.active, srv.sessions.len - 1)
    result = newJNull()
  of "layout/edited":
    # The user's resizes and closings, recorded in this mode's layout so a
    # return to the mode restores them (§E4).
    let s = srv.sessionById(params)
    let tree = s.currentLayout()
    let sizes = params{"sizes"}
    if not sizes.isNil and sizes.kind == JObject:
      for name, weight in sizes.pairs:
        let (ok, pane) = paneOfWire(name)
        if ok:
          discard tree.setWeight(pane, weight.getFloat(0.0))
    # Weights addressed by the node's path from the root (child indices):
    # the editor's realization may not have one window per tree node (an
    # Emacs side holds its slots in one line), so it reports the weight of
    # every node it sized — containers and stacks included, which a weight
    # keyed by pane cannot reach. Applied before `closed`, whose collapsing
    # renumbers the paths.
    for w in params{"weights"}.getElems:
      let weight = w{"weight"}.getFloat(-1.0)
      if weight < 0.0:
        continue
      var node = tree
      for step in w{"path"}.getElems:
        let k = step.getInt(-1)
        if node.isNil or k < 0 or k >= node.children.len:
          node = nil
          break
        node = node.children[k]
      if not node.isNil and node != tree:
        node.weight = weight
    for name in params{"closed"}.getElems:
      let (ok, pane) = paneOfWire(name.getStr(""))
      if ok:
        discard tree.removePane(pane)
    s.layoutSent = $layoutJson(tree)
    result = newJObject()
    result["layout"] = layoutJson(tree)
  of "pane/open", "pane/resize":
    let s = srv.sessionById(params)
    if params{"pane"}.getStr("") == FrameViewerPane:
      if s.graphics.isNil:
        fail(ErrRequestFailed, "this recording carries no graphics")
      let (w, h) = sizeParams(params)
      s.frameView = some(HostedPane(width: w, height: h))
      if meth == "pane/open":
        s.imageSent = ""
        extra.add notification("pane/keymap",
          %*{"session": s.id, "pane": FrameViewerPane, "bindings": []})
      extra.add srv.publish(s, fullFrameViewer = true)
      result = %*{"pane": FrameViewerPane, "width": w, "height": h}
      return
    let pane = paneParam(params)
    let (w, h) = sizeParams(params)
    s.panes[pane] = HostedPane(width: w, height: h)
    s.rt.hostedRows[pane] = h
    s.rt.hostedCols[pane] = w
    s.resyncViewports()
    if meth == "pane/open":
      extra.add srv.keymapOf(s, pane)
    extra.add srv.publish(s, fullPanes = @[pane])
    result = newJObject()
    result["pane"] = %($pane)
    result["width"] = %w
    result["height"] = %h
  of "pane/close":
    let s = srv.sessionById(params)
    if params{"pane"}.getStr("") == FrameViewerPane:
      s.frameView = none(HostedPane)
      s.imageSent = ""
      return newJNull()
    let pane = paneParam(params)
    s.panes.del(pane)
    s.rt.hostedRows[pane] = 0
    s.rt.hostedCols[pane] = 0
    result = newJNull()
  of "pane/keymap":
    let s = srv.sessionById(params)
    result = srv.keymapOf(s, paneParam(params))["params"]
  of "keymap/shadowed":
    # The plugin's report of the editor bindings it left in place (§E6).
    let pane = params{"pane"}.getStr("")
    var keys: seq[string] = @[]
    for k in params{"keys"}.getElems:
      keys.add k.getStr("")
    srv.shadowed[pane] = keys
    if srv.active >= 0:
      let s = srv.sessions[srv.active]
      for p in s.panes.keys:
        extra.add srv.keymapOf(s, p)
    result = newJNull()
  of "operations/list":
    result = operationsJson()
  of "operation/run":
    let s = srv.sessionById(params)
    result = srv.runOperation(s, params)
    extra.add srv.publish(s)
  of "session/files":
    # The recording's source set (the file tree role's floor, §E8): what an
    # editor that shows the files itself lists, including sources that are
    # not in its project.
    let s = srv.sessionById(params)
    var files: seq[JsonNode] = @[]
    let vm = s.tui.session.session.fileTreeVM
    if not vm.isNil:
      recordedFiles(vm.rootEntry.val, files)
    result = %files
  of "source/read":
    # A recorded file, whole, as the recording holds it — for a source the
    # editor cannot open from disk (§E8: a read-only buffer per trace file).
    let s = srv.sessionById(params)
    let file = params{"file"}.getStr("")
    if file.len == 0:
      fail(ErrInvalidParams, "source/read names a `file`")
    let (ok, text, message) = s.tui.recordedSourceText(file)
    if not ok:
      fail(ErrRequestFailed, message)
    result = %*{"file": file, "text": text}
  of "files/changed":
    # The editor's file tree, when it fills the file tree role (§E8), reports
    # the files it created, renamed and deleted. Edit mode lists the project
    # again so its file tree, and what a build sees, follow; a recording's
    # source set does not change.
    let s = srv.sessionById(params)
    if s.app.modes.product == pmEdit and not s.rt.editServices.listFiles.isNil:
      # The rows and the Files model the menu decides on (K19), together.
      s.rt.installProjectListing(s.rt.editServices.listFiles())
      extra.add srv.publish(s)
    result = newJNull()
  of "files/selected":
    # The file selected in the editor's own tree, when it fills the file tree
    # role (§E8): the file tree's selection follows, as a selection in
    # CodeTracer's file pane would.
    let s = srv.sessionById(params)
    let path = params{"path"}.getStr("")
    var tree = s.app.fileTree
    tree.selected = -1
    for i, e in tree.entries:
      if e.path == path:
        tree.selected = i
    if tree.selected < 0:
      tree.selected = tree.files.find(path)
    s.app.fileTree = tree
    result = newJNull()
  of "source/cursor":
    # The editor's cursor in its source window (§E7, the source editor
    # role's floor): what operations "at the cursor" act on.
    let s = srv.sessionById(params)
    s.cursor = (file: params{"file"}.getStr(""), line: params{"line"}.getInt(0),
                column: params{"column"}.getInt(1))
    result = newJNull()
  of "source/viewport":
    let s = srv.sessionById(params)
    let first = params{"firstLine"}.getInt(1)
    let last = params{"lastLine"}.getInt(first)
    s.sourceView = (file: params{"file"}.getStr(""), first: first,
                    last: max(first, last))
    s.rt.hostedRows[paneEditor] = max(1, last - first + 1)
    s.resyncViewports()
    extra.add srv.publish(s)
    result = newJNull()
  else:
    fail(ErrMethodNotFound, "unknown method " & meth)

proc handle*(srv: PaneServer; msg: JsonNode): seq[JsonNode] =
  ## One message from the editor; the messages to send back, in order — a
  ## request's response first, then the notifications it caused.
  if msg.hasKey("__unparsable"):
    return @[errorResponse(newJNull(), -32700, "parse error")]
  let meth = msg{"method"}.getStr("")
  let id = msg.getOrDefault("id")
  let params = if msg.hasKey("params"): msg["params"] else: newJObject()
  if id.isNil:
    # A notification: `exit`, or a request-shaped report with no answer.
    if meth == "exit":
      srv.exitRequested = true
      return @[]
    var extra: seq[JsonNode] = @[]
    try:
      discard srv.handleRequest(meth, params, extra)
    except CatchableError as e:
      stderr.writeLine(ServerName & ": " & meth & ": " & e.msg)
    return extra
  var extra: seq[JsonNode] = @[]
  try:
    let res = srv.handleRequest(meth, params, extra)
    result = @[response(id, res)]
    result.add extra
  except RequestError as e:
    result = @[errorResponse(id, e.code, e.msg)]
  except CatchableError as e:
    result = @[errorResponse(id, ErrRequestFailed, e.msg)]

# ---------------------------------------------------------------------------
# The DAP endpoint (Q3)
# ---------------------------------------------------------------------------

proc dapEvent(srv: PaneServer; event: string; body: JsonNode) =
  if not srv.dap.attached:
    return
  inc srv.dap.seqNo
  srv.dapOut.add %*{"seq": srv.dap.seqNo, "type": "event", "event": event,
                    "body": body}

proc dapReply(srv: PaneServer; req: JsonNode; ok: bool; body: JsonNode;
              message = ""): JsonNode =
  inc srv.dap.seqNo
  result = newJObject()
  result["seq"] = %srv.dap.seqNo
  result["type"] = %"response"
  result["request_seq"] = %req{"seq"}.getInt(0)
  result["success"] = %ok
  result["command"] = %req{"command"}.getStr("")
  if not body.isNil: result["body"] = body
  if message.len > 0: result["message"] = %message

proc dapRef(srv: PaneServer; path: string): int =
  let at = srv.dap.refs.find(path)
  if at >= 0: return at + 1
  srv.dap.refs.add path
  srv.dap.refs.len

const DapOperations = {
  "next": "debugger.step-over", "stepIn": "debugger.step-into",
  "stepOut": "debugger.step-out", "continue": "debugger.continue",
  "reverseContinue": "debugger.reverse-continue",
  "stepBack": "debugger.reverse-step-over"}.toTable

proc handleDap*(srv: PaneServer; req: JsonNode): seq[JsonNode] =
  ## One DAP request, as an operation on the active session. Returns the
  ## response; events go to `dapOut`, pane notifications are returned to the
  ## editor by the caller through `publishActive`.
  let command = req{"command"}.getStr("")
  let args = req{"arguments"}
  srv.dap.attached = true
  if command == "initialize":
    result.add srv.dapReply(req, true, %*{
      "supportsConfigurationDoneRequest": true, "supportsStepBack": true,
      "supportsTerminateRequest": true, "supportsEvaluateForHovers": true})
    srv.dapEvent("initialized", newJObject())
    return
  if command in ["launch", "attach"]:
    result.add srv.dapReply(req, true, nil)
    return
  if command in ["disconnect", "terminate"]:
    result.add srv.dapReply(req, true, nil)
    srv.dap.attached = false
    return
  if srv.active < 0:
    result.add srv.dapReply(req, false, nil, "no CodeTracer session is open")
    return
  let s = srv.sessions[srv.active]
  case command
  of "configurationDone":
    result.add srv.dapReply(req, true, nil)
    srv.dapEvent("stopped", %*{"reason": "entry", "threadId": 1,
                               "allThreadsStopped": true})
  of "threads":
    result.add srv.dapReply(req, true, %*{"threads": [{"id": 1, "name": "main"}]})
  of "stackTrace":
    var frames = newJArray()
    for f in s.app.callStack.frames:
      frames.add %*{"id": f.index + 1, "name": f.name, "line": f.line,
                    "column": 1, "source": {"path": f.path,
                                            "name": extractFilename(f.path)}}
    if frames.len == 0:
      let t = s.tui.session
      frames.add %*{"id": 1, "name": "?", "line": t.getCurrentLine(), "column": 1,
                    "source": {"path": t.getCurrentFile()}}
    result.add srv.dapReply(req, true, %*{"stackFrames": frames,
                                          "totalFrames": frames.len})
  of "scopes":
    var scopes = newJArray()
    for sc in s.app.variables.scopes:
      let path = scopePath(sc.kind)
      scopes.add %*{"name": $sc.kind, "variablesReference": srv.dapRef(path),
                    "expensive": false}
    result.add srv.dapReply(req, true, %*{"scopes": scopes})
  of "variables":
    let r = args{"variablesReference"}.getInt(0)
    if r < 1 or r > srv.dap.refs.len:
      result.add srv.dapReply(req, false, nil, "unknown variablesReference")
      return
    var vars = newJArray()
    for n in s.app.variables.childrenOf(srv.dap.refs[r - 1]):
      vars.add %*{"name": n.name, "value": n.value, "type": n.typeName,
                  "variablesReference":
                    (if n.memberCount > 0: srv.dapRef(n.path) else: 0)}
    result.add srv.dapReply(req, true, %*{"variables": vars})
  of "evaluate":
    let expr = args{"expression"}.getStr("")
    var found = false
    for sc in s.app.variables.scopes:
      for n in s.app.variables.childrenOf(scopePath(sc.kind)):
        if n.name == expr and not found:
          found = true
          result.add srv.dapReply(req, true, %*{"result": n.value,
            "type": n.typeName,
            "variablesReference": (if n.memberCount > 0: srv.dapRef(n.path) else: 0)})
    if not found:
      result.add srv.dapReply(req, false, nil,
        "'" & expr & "' is not a value at this stop")
  of "setBreakpoints":
    let path = args{"source", "path"}.getStr("")
    var wanted: seq[int] = @[]
    for b in args{"breakpoints"}.getElems:
      wanted.add b{"line"}.getInt(0)
    # Make the session's breakpoints in `path` exactly `wanted`, through the
    # one toggle every front-end uses.
    var have: seq[int] = @[]
    for p in s.tui.points():
      if p.path == path and p.kind == sptBreakpoint:
        have.add p.line
    for line in have:
      if line notin wanted:
        discard s.tui.toggleBreakpoint(path, line)
    for line in wanted:
      if line notin have:
        discard s.tui.toggleBreakpoint(path, line)
    s.tui.refresh(s.rt)
    var bps = newJArray()
    for line in wanted:
      bps.add %*{"verified": true, "line": line}
    result.add srv.dapReply(req, true, %*{"breakpoints": bps})
  else:
    if DapOperations.hasKey(command):
      let outcome = s.rt.runNamedOperation(DapOperations[command], "",
                                           epochTime().int64 * 1000)
      s.tui.applyOutcome(s.rt, outcome)
      result.add srv.dapReply(req, true, nil)
    else:
      result.add srv.dapReply(req, false, nil, "'" & command &
        "' is not supported by the CodeTracer pane server")

proc publishActive*(srv: PaneServer): seq[JsonNode] =
  ## What a DAP request changed, for the editor's panes.
  if srv.active >= 0:
    result = srv.publish(srv.sessions[srv.active])

proc takeDapOut*(srv: PaneServer): seq[JsonNode] =
  result = srv.dapOut
  srv.dapOut = @[]

proc openDapListener*(srv: PaneServer) =
  ## Listen on an ephemeral loopback port; `initialize` names it.
  let sock = newSocket()
  sock.setSockOpt(OptReuseAddr, true)
  sock.bindAddr(Port(0), "127.0.0.1")
  sock.listen()
  srv.dap.listener = sock
  srv.dap.port = int(sock.getLocalAddr()[1])

# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n <= 0:
      if errno == EINTR: continue
      raise newException(IOError, "the editor closed the pane server's output")
    off += n

proc runPaneServer*(): int =
  ## `codetracer-tui --pane-server`: serve the editor on stdin/stdout until
  ## `exit` (or the editor closes stdin). Exit status per the LSP convention:
  ## 0 after `shutdown`, 1 otherwise.
  let srv = newPaneServer()
  try:
    srv.openDapListener()
  except CatchableError as e:
    stderr.writeLine(ServerName & ": no DAP endpoint: " & e.msg)
  var editorIn: Framer
  var dapIn: Framer
  var selector = newSelector[int]()
  selector.registerHandle(int(STDIN_FILENO), {Event.Read}, 0)
  if not srv.dap.listener.isNil:
    selector.registerHandle(int(srv.dap.listener.getFd), {Event.Read}, 1)
  var buffer = newString(65536)
  let sendEditor = proc(msgs: seq[JsonNode]) =
    for m in msgs:
      writeAll(STDOUT_FILENO, frame(m))
  let sendDap = proc() =
    for m in srv.takeDapOut():
      if not srv.dap.client.isNil:
        try: srv.dap.client.send(frame(m))
        except CatchableError: discard
  while not srv.exitRequested:
    for ready in selector.select(-1):
      # ONE EVENT'S FAILURE IS NOT THE SERVER'S: a DAP client that breaks
      # off mid-message, or a write to it that fails, is reported and the
      # editor's session goes on.
      try:
        let which = selector.getData(ready.fd)
        case which
        of 0:
          let n = posix.read(STDIN_FILENO, addr buffer[0], buffer.len)
          if n <= 0:
            srv.exitRequested = true
            break
          editorIn.feed(buffer[0 ..< n])
          while true:
            let msg = editorIn.next()
            if msg.isNone: break
            sendEditor(srv.handle(msg.get))
            sendDap()
            if srv.exitRequested: break
        of 1:
          var client: Socket
          srv.dap.listener.accept(client)
          if not srv.dap.client.isNil:
            selector.unregister(int(srv.dap.client.getFd))
            srv.dap.client.close()
          srv.dap.client = client
          dapIn = Framer()
          selector.registerHandle(int(client.getFd), {Event.Read}, 2)
        else:
          # The selector reported data: one read of the DESCRIPTOR returns
          # what is there, and 0 only when the client closed. (A buffered
          # `Socket.recv(buf, size)` waits for all `size` bytes.)
          var got = newString(4096)
          let n = posix.recv(srv.dap.client.getFd, addr got[0], 4096, 0'i32)
          got.setLen(max(0, n))
          if n <= 0:
            selector.unregister(int(srv.dap.client.getFd))
            srv.dap.client.close()
            srv.dap.client = nil
            srv.dap.attached = false
            continue
          dapIn.feed(got)
          while true:
            let msg = dapIn.next()
            if msg.isNone: break
            # The response before the events the request produced (DAP's
            # `initialized` follows the `initialize` response).
            let responses = srv.handleDap(msg.get)
            srv.dapOut = responses & srv.takeDapOut()
            sendDap()
            sendEditor(srv.publishActive())
            sendDap()
      except IOError as e:
        # The editor's own stream: nothing left to serve.
        stderr.writeLine(ServerName & ": " & e.msg)
        srv.exitRequested = true
      except CatchableError as e:
        stderr.writeLine(ServerName & ": " & e.msg)
  for s in srv.sessions:
    s.close()
  if srv.shutdownRequested: 0 else: 1
