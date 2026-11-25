## main.nim — the `codetracer-zgui` entry point: CodeTracer's debugger on
## zgui's retained document, through isonim-zgui.
##
## ## THE SHAPE
##
## A proof of concept beside the GPUI front-end, and built from the same
## renderer-free parts:
##
##   * the host: `gpui/host/gpui_host` spawns `replay-server` and completes the
##     DAP handshake (`openGpuiTrace`), and serves the editor's source window
##     (`newGpuiSourceService`); `host/native_host` and
##     `host/session_driver` load the panes and run a debugger control —
##     the producers both native front-ends already call;
##   * the shell: `gpui/app/shell` (`HeadlessApp` plus the window's layout) and
##     its dock projection, the shared default layout;
##   * the panes: `view_vocabulary/pane_views` and `editor_surface`.
##
## What is this front-end's own is the drawing (`app/zgui_leaves`,
## `app/zgui_top_bar`, `view_vocabulary/zgui_binding`) and this module: the
## command line, the keys, and the loop that turns a debugger move into an
## update of the document zgui already holds.
##
## ## WINDOW AND HEADLESS
##
## Without `--headless` the binary opens a desktop window (`runWindow`) and the
## compositor's keys drive it. With `--headless` it runs zgui's headless
## platform: the same document, cascade, layout and paint, the frames read
## back as RGBA (`--capture-dir`), and the operations of `--replay-ops` driven
## through the same key path a window takes.
##
## ## THE MEASUREMENT
##
## `--frame-report` records, per operation, the engine's share (the DAP move
## and the pane loads), this front-end's update of the document, and zgui's
## frames — the time a frame took and the work counters zgui keeps — so a
## step and a one-row change can be compared with the GPUI binary's report
## at the same codetracer commit.

import std/[json, monotimes, options, os, strutils, tables, times]

import isonim_zgui/[bindings, renderer, png, testing]

import isonim/core/signals
import headless_session
import viewmodels/[source_vm, debug_controls_vm, calltrace_vm]
import viewport
import backend/stdio_backend
import headless_app/[headless_app, layout_model, window_set]
import ../gpui/app/[shell, dock_projection]
import ../gpui/host/gpui_host
import ../gpui/replay_ops
import ../host/[native_host, session_driver]
import ../view_vocabulary/[editor_surface, zgui_binding]
import ../viewmodel/viewmodels/[menu_vm, product_menu]
import ../viewmodel/host/keymap_preference
import ../viewmodel/keymap/[keymap_router, editing_keymap, context_keys,
                            scope_path]
import ../../common/key_names
import ../../common/value_presentation
import ../../common/view_vocabulary
import ./app/[zgui_leaves, zgui_top_bar]

const
  ZguiFrontEndVersion* = "0.1.0-poc"
  ExitUsage = 2

  HelpText = """
codetracer-zgui — CodeTracer's debugger on zgui (proof of concept)

Usage: codetracer-zgui [options] <recording-folder>

  --headless           run on zgui's headless platform; no window
  --capture-dir=<dir>  headless: draw with the real renderer offscreen and
                       write open.png, then one PNG per operation
  --replay-ops=<spec>  after opening, perform these debugger operations, as
                       the Debug menu does, e.g. next=3,stepIn=1
  --keys=<k1,k2,...>   headless: press these keys (DOM names, modifiers
                       first: F10, Alt+e, ArrowDown) one by one, as a
                       reader would
  --clicks=<c1,c2,...> headless: click, as a pointer does, a top-bar menu
                       (menu:Debug), an item of the open menu by its action
                       (action:forwardNext), a control (control:next) or a
                       pane's row (row:calltrace:<call>, row:eventLog:<row>)
  --width=<px> --height=<px>
                       the window's size (default 1600x1000)
  --frame-report=<path>
                       write the timing record: every operation's engine and
                       update time, and every zgui frame's time and work
  --facts-out=<path>   write what the panes show, read back out of zgui
  --keymap=<base>      cua (the default), emacs, vim or kakoune, for this
                       session; otherwise the remembered preference
  --quit-after-ms=<ms> window: close after this long
  --version            print the version
  --help               this text
"""

type
  Command = object
    traceFolder: string
    headless: bool
    captureDir: string
    replayOps: seq[ReplayOp]
    keys: seq[string]
    clicks: seq[string]
    width, height: int
    frameReport: string
    factsOut: string
    quitAfterMs: int
    keymap: string

  Operation = object
    ## One thing the window did, for the frame report.
    name: string
    engineNs: int64
      ## the DAP move and the pane loads (`runDebugControl` + `afterMove`).
    updateNs: int64
      ## this front-end's update of zgui's document.
    framesBefore: int
      ## zgui's frame count when the operation began.
    settleNs: int64
      ## headless: the frames the update asked for, run to idle.
    rowsWritten: int
    paneReplaced, paneWritten: int
    visited, relaid, restyled: uint64
      ## zgui's work counters over the operation's frames.

var
  gCmd: Command
  gSession: HeadlessDebugSession
  gShell: GpuiShell
  gWindow = WindowId(0)
  gSource: GpuiSourceService
  gLeaves: ZguiLeaves
  gTopBar: ZguiTopBar
  gMenu: MenuVM
  gRouter: KeymapRouter
  gOps: seq[Operation]
  gRenderer: ZguiRenderer
  gCaptureIndex = 0
  gInKey = false
    ## Headless: inside a key's dispatch, where the frames run after it.

const ZguiDelivery = KeyDelivery(frontEnd: feGpui, platform: hostPlatform(),
                                 keyProtocol: kpNative)
  ## zgui, like GPUI, receives KEYS from the platform, never terminal bytes,
  ## so every chord can be typed. `feGpui` is the native-window class of the
  ## keymap's front-ends; the router has no other distinction to draw.

proc nowNs(): int64 = getMonoTime().ticks

# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------

proc usage(msg: string) {.noreturn.} =
  stderr.writeLine("codetracer-zgui: " & msg)
  stderr.writeLine("run 'codetracer-zgui --help' for the options")
  quit(ExitUsage)

proc parseCommand(args: seq[string]): Command =
  result = Command(width: 1600, height: 1000)
  for a in args:
    if a == "--help" or a == "-h":
      echo HelpText
      quit(0)
    elif a == "--version":
      echo "codetracer-zgui " & ZguiFrontEndVersion
      quit(0)
    elif a == "--headless": result.headless = true
    elif a.startsWith("--capture-dir="): result.captureDir = a.split('=', 1)[1]
    elif a.startsWith("--replay-ops="):
      try: result.replayOps = parseReplayOps(a.split('=', 1)[1])
      except ReplayOpError as e: usage("--replay-ops: " & e.msg)
    elif a.startsWith("--keys="):
      for k in a.split('=', 1)[1].split(','):
        if k.len > 0: result.keys.add(if k == "comma": "," else: k)
    elif a.startsWith("--clicks="):
      for k in a.split('=', 1)[1].split(','):
        if k.len > 0: result.clicks.add k
    elif a.startsWith("--width="): result.width = parseInt(a.split('=', 1)[1])
    elif a.startsWith("--height="): result.height = parseInt(a.split('=', 1)[1])
    elif a.startsWith("--frame-report="): result.frameReport = a.split('=', 1)[1]
    elif a.startsWith("--facts-out="): result.factsOut = a.split('=', 1)[1]
    elif a.startsWith("--keymap="): result.keymap = a.split('=', 1)[1]
    elif a.startsWith("--quit-after-ms="):
      result.quitAfterMs = parseInt(a.split('=', 1)[1])
    elif a.startsWith("-"): usage("unknown option '" & a & "'")
    elif result.traceFolder.len == 0: result.traceFolder = a
    else: usage("one recording folder, not two ('" & a & "')")
  if result.traceFolder.len == 0: usage("name a recording folder")
  if result.captureDir.len > 0 and not result.headless:
    usage("--capture-dir draws offscreen, so it needs --headless")

# ---------------------------------------------------------------------------
# What the window shows, from the session
# ---------------------------------------------------------------------------

proc currentSurface(): EditorSurface =
  editorSurfaceFor(
    source = gSource.vm, editor = gSession.session.editorVM,
    state = gSession.session.stateVM, flow = gSession.session.flowVM,
    availability = gSource.availability(), budget = gpuiRowBudget(),
    medium = ZguiMedium,
    points = editorPointsOf(gSession.session.store.pointList.rows.val))

proc bodyRows(paneId: string; rowPx: int; fallback: int): int =
  ## How many rows a pane's body holds, read off the box zgui laid it out in.
  if gLeaves.isNil: return fallback
  let host = gLeaves.panes.getOrDefault(paneId)
  if host.isNil: return fallback
  let box = host.body.borderBox()
  if not box.ok or box.h <= 0: return fallback
  max(1, int(box.h) div rowPx)

proc paneWidth(paneId: string): int =
  let host = if gLeaves.isNil: nil else: gLeaves.panes.getOrDefault(paneId)
  if host.isNil: return 600
  let box = host.body.borderBox()
  if box.ok and box.w > 0: int(box.w) else: 600

proc reportViewports() =
  ## The call trace and the event log ask for the rows their panes show — the
  ## sizes zgui laid the panes out at (Viewport-Driven-Loading V2).
  discard gSession.pageCalltrace(bodyRows($paneCalltrace, 18, 30), 0,
                                 paneWidth($paneCalltrace), 16)
  discard gSession.pageEventLog(
    gSession.session.store.eventLog.loadedStart.val,
    bodyRows($paneEventLog, 18, 30) - 1)
  let rows = bodyRows($paneEditor, EditorLinePx, 40)
  if rows != gSource.visibleRows:
    gSource.visibleRows = rows
    gSource.vm.setViewport(gSource.vm.viewport.withRows(rows))

proc refreshWindow() =
  ## After the debugger moved: the source window, the list windows, then the
  ## document — each pane updated in place and the editor's changed rows.
  gSource.serveWindow()
  reportViewports()
  gLeaves.updateEditor(currentSurface())
  gLeaves.refreshPanes()
  if not gTopBar.isNil:
    var controls: seq[TopBarControl]
    let vm = gSession.session.debugControlsVM
    for c in gTopBar.controlEls:
      controls.add TopBarControl(id: c.id,
        enabled: not vm.isNil and vm.transportAvailable(c.id))
    gTopBar.setControls(controls)

proc capture(name: string) =
  if gCmd.captureDir.len == 0: return
  let c = testing.capture()
  if c.width == 0: return
  inc gCaptureIndex
  let path = gCmd.captureDir / ($gCaptureIndex).align(3, '0') & "-" & name & ".png"
  writePng(path, c.width, c.height, c.pixels)

proc runControl(id: string; label = "") =
  ## A debugger control — from a key, a menu item, a top-bar button or
  ## `--replay-ops` — then the window brought up to date. Timed in parts.
  var op = Operation(name: if label.len > 0: label else: id,
                     framesBefore: int(zg_frame_count()))
  gLeaves.resetCounters()
  let t0 = nowNs()
  let moved = gSession.runDebugControl(id)
  if moved: gSession.afterMove()
  let t1 = nowNs()
  refreshWindow()
  let t2 = nowNs()
  op.engineNs = t1 - t0
  op.updateNs = t2 - t1
  op.rowsWritten = gLeaves.rowsWritten
  (op.paneReplaced, op.paneWritten) = gLeaves.paneWork()
  if gCmd.headless and not gInKey:
    let c0 = (zg_counter("nodes_visited"), zg_counter("nodes_relaid_out"),
              zg_counter("restyled"))
    let t3 = nowNs()
    discard settle()
    op.settleNs = nowNs() - t3
    op.visited = zg_counter("nodes_visited") - c0[0]
    op.relaid = zg_counter("nodes_relaid_out") - c0[1]
    op.restyled = zg_counter("restyled") - c0[2]
  gOps.add op
  if not moved:
    stderr.writeLine("codetracer-zgui: '" & id & "' did not move the debugger")

proc pressRow(paneId: string; press: RowPress) =
  ## A pointer press on a pane's row, as the desktop's press does: a call
  ## trace row goes to the call (`calltrace.go-to-call`), an event log row to
  ## the event (`event-log.jump`); then the window brought up to date. A press
  ## on another pane's row is that pane's view's business, not a move.
  var op = Operation(name: "press:" & paneId & ":" & press.key,
                     framesBefore: int(zg_frame_count()))
  gLeaves.resetCounters()
  let t0 = nowNs()
  var moved = false
  if paneId == $paneCalltrace and press.kind == rpOption:
    var index = -1'i64
    try: index = parseBiggestInt(press.key)
    except ValueError: discard
    if index >= 0:
      gSession.session.calltraceVM.selectEntry(some(index))
      let why = gSession.jumpToCall(index)
      if why.len > 0: stderr.writeLine("codetracer-zgui: " & why)
      else: moved = true
  elif paneId == $paneEventLog and press.kind == rpRow:
    let rows = gSession.session.eventLogVM.eventRows.val
    var row = -1
    try: row = parseInt(press.key)
    except ValueError: discard
    if row >= 0 and row < rows.len:
      try:
        gSession.eventJump(toEventLogEntry(rows[row]))
        moved = true
      except CatchableError as e:
        stderr.writeLine("codetracer-zgui: could not go to the event: " & e.msg)
  if not moved: return
  gSession.afterMove()
  let t1 = nowNs()
  refreshWindow()
  op.engineNs = t1 - t0
  op.updateNs = nowNs() - t1
  op.rowsWritten = gLeaves.rowsWritten
  (op.paneReplaced, op.paneWritten) = gLeaves.paneWork()
  gOps.add op

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

const DomNamedKeys = {
  "Escape": "Esc", "Enter": "Enter", "Backspace": "Backspace", "Tab": "Tab",
  " ": "Space", "Delete": "Delete", "Home": "Home", "End": "End",
  "PageUp": "PageUp", "PageDown": "PageDown", "Insert": "Insert",
  "ArrowUp": "Up", "ArrowDown": "Down", "ArrowLeft": "Left",
  "ArrowRight": "Right", "F1": "F1", "F2": "F2", "F3": "F3", "F4": "F4",
  "F5": "F5", "F6": "F6", "F7": "F7", "F8": "F8", "F9": "F9", "F10": "F10",
  "F11": "F11", "F12": "F12"}.toTable
  ## zgui reports keys in the DOM's spelling (`KeyboardEvent.key`).

const
  ModShift = 1'u32
  ModCtrl = 2'u32
  ModAlt = 4'u32
  ModMeta = 8'u32

proc canonicalKeyOfZgui*(key: string; modifiers: uint32): string =
  ## The canonical name of one zgui key press, or "" when there is none.
  var mods: KeyModifiers
  if (modifiers and ModCtrl) != 0: mods.incl kmodCtrl
  if (modifiers and ModAlt) != 0: mods.incl kmodAlt
  if (modifiers and ModMeta) != 0: mods.incl kmodMeta
  if DomNamedKeys.hasKey(key):
    if (modifiers and ModShift) != 0: mods.incl kmodShift
    return chordName(mods, DomNamedKeys[key])
  if key.len == 1 and key[0] >= ' ' and key[0] <= '~':
    # A printable key arrives already shifted (`G`, `{`); `chordName` folds
    # the shift into it.
    return chordName(mods, key)
  ""

proc windowFacts(): SessionFacts =
  SessionFacts(product: pmDebug, replayLoaded: not gSession.isNil)

proc focusPane(kind: PaneKind) =
  ## Bring a pane to the front and give its view the keyboard.
  var op = Operation(name: "focus:" & $kind, framesBefore: int(zg_frame_count()))
  let t0 = nowNs()
  defer:
    op.updateNs = nowNs() - t0
    gOps.add op
  discard gShell.applyIn(gWindow, LayoutCommand(kind: lcActivateTab,
                                                activateTarget: kind))
  let host = gLeaves.panes.getOrDefault($kind)
  if host.isNil:
    gLeaves.rebuildArrangement(gShell.leavesFor(gWindow),
                               gShell.projectionFor(gWindow))
    refreshWindow()
  let fresh = gLeaves.panes.getOrDefault($kind)
  if not fresh.isNil and not fresh.binding.isNil:
    fresh.binding.root.focus()

proc runOperation(operation, argument: string) =
  let control = controlForOperation(operation)
  if control.len > 0:
    runControl(control, operation)
    return
  if operation == "layout.focus-pane":
    # The keymap's pane names (`call-trace`, `variables`, `event-log`, …)
    # or the pane's own.
    for k in PaneKind:
      if $k == argument or argument == "variables" and k == paneState or
         argument == "call-trace" and k == paneCalltrace or
         argument == "event-log" and k == paneEventLog or
         argument == "editor" and k == paneEditor:
        focusPane(k)
        return

proc onWindowKey(ev: ZguiEvent): uint32 =
  ## A key no view consumed, at the window: an open menu first, then the
  ## keymap router.
  if existsEnv("CODETRACER_ZGUI_TRACE_KEYS"):
    stderr.writeLine("codetracer-zgui: key '" & ev.key & "' mods " &
                     $ev.modifiers & " -> '" &
                     canonicalKeyOfZgui(ev.key, ev.modifiers) & "'")
  if not gTopBar.isNil and gTopBar.menuKey(ev.key):
    return 3
  let name = canonicalKeyOfZgui(ev.key, ev.modifiers)
  if name.len == 0: return 0
  let path = @[element(ekWindow, "window"), pane($paneEditor)]
  let res = gRouter.route(windowFacts(), path, nmNormal, name,
                          int64(epochTime() * 1000))
  if existsEnv("CODETRACER_ZGUI_TRACE_KEYS"):
    stderr.writeLine("codetracer-zgui:   -> " & $res.kind & " '" &
                     res.operation & "'")
  if res.kind != erOperation: return 0
  runOperation(res.operation, res.argument)
  3

proc onAction(action: string) =
  ## A menu item or a top-bar control.
  if action.startsWith("control:"):
    runControl(action["control:".len .. ^1])
    return
  let control = controlForMenuAction(action)
  if control.len > 0: runControl(control, action)

# ---------------------------------------------------------------------------
# Building the window
# ---------------------------------------------------------------------------

const TopBarControls = [
  ("reverse-continue", "⏮"), ("reverse-next", "↶"), ("reverse-step-in", "↓◂"),
  ("reverse-step-out", "↑◂"), ("next", "↷"), ("step-in", "↓"),
  ("step-out", "↑"), ("continue", "⏭")]

proc windowTitle(): string =
  extractFilename(gSession.tracePath.strip(chars = {'/'})) & " — CodeTracer"

proc writeFacts(path: string)
  ## What the window shows, read back out of zgui's document; below.

proc buildWindow(root: ZguiNode) =
  let r = gRenderer
  var controls: seq[TopBarControl]
  let vm = gSession.session.debugControlsVM
  for (id, label) in TopBarControls:
    controls.add TopBarControl(id: id, label: label,
      enabled: not vm.isNil and vm.transportAvailable(id))
  gTopBar = renderTopBar(r, gMenu, windowTitle(), controls, onAction)
  gLeaves = renderLeaves(r, gShell.leavesFor(gWindow),
                         gShell.projectionFor(gWindow), gTopBar.el)
  gLeaves.onViewKey = proc(paneId: string; binding: ZguiBinding) =
    gOps.add Operation(name: "view-key:" & paneId,
                       framesBefore: int(zg_frame_count()),
                       updateNs: binding.lastKeyUpdateNs,
                       paneReplaced: binding.replaced,
                       paneWritten: binding.written)
  gLeaves.onRowPress = pressRow
  gLeaves.onTab = proc(paneId: string) =
    for k in PaneKind:
      if $k == paneId: focusPane(k)
  r.setAttribute(gLeaves.root, "tabindex", "0")
  addListener(gLeaves.root, "keydown", onWindowKey)
  r.appendChild(root, gLeaves.root)
  gLeaves.updateEditor(currentSurface())
  gLeaves.root.focus()
  if not gCmd.headless:
    # The window's clock exists once the window does.
    if gCmd.quitAfterMs > 0:
      setTimer(gCmd.quitAfterMs, proc() =
        if gCmd.factsOut.len > 0: writeFacts(gCmd.factsOut)
        quitApp())
    # A first layout pass decides how many rows the panes hold.
    setTimer(50, proc() =
      refreshWindow()
      gLeaves.root.focus())

proc stylesheet(): string =
  ZguiVocabularyCss & ZguiLeavesCss & ZguiTopBarCss

proc settleLayout() =
  ## Headless: let zgui lay the window out, then ask for the rows the panes
  ## turned out to hold.
  discard settle()
  refreshWindow()
  discard settle()

proc writeFrameReport(path: string; loadStart: string) =
  var frames = newJArray()
  for i in 0'u64 ..< zg_frame_count():
    let f = zg_frame(i)
    frames.add %*{"elapsedNs": f.elapsedNs, "paintNs": f.paintNs,
                  "restyled": f.restyled}
  var ops = newJArray()
  for op in gOps:
    ops.add %*{"name": op.name, "engineNs": op.engineNs,
               "updateNs": op.updateNs, "settleNs": op.settleNs,
               "framesBefore": op.framesBefore,
               "rowsWritten": op.rowsWritten,
               "paneElementsReplaced": op.paneReplaced,
               "paneElementsWritten": op.paneWritten,
               "nodesVisited": op.visited, "nodesRelaidOut": op.relaid,
               "restyled": op.restyled}
  var counters = newJObject()
  for i in 0'u64 ..< zg_counter_total():
    let name = $zg_counter_name(i)
    counters[name] = %zg_counter(name.cstring)
  let load = try: readFile("/proc/loadavg").splitWhitespace()[0 .. 2].join(" ")
             except CatchableError: ""
  let doc = %*{"record": "codetracer-zgui-frames", "headless": gCmd.headless,
               "operations": ops, "frames": frames, "counters": counters,
               "loadAverageStart": loadStart, "loadAverageEnd": load}
  writeFile(path, doc.pretty & "\n")

proc writeFacts(path: string) =
  ## What the window shows, read back out of zgui's document.
  var panes = newJObject()
  for id, host in gLeaves.panes:
    var facts = newJArray()
    if not host.binding.isNil:
      for f in host.binding.readZguiFacts():
        facts.add %*{"id": f.id, "field": f.field, "value": f.value}
    panes[id] = %*{"state": getAttribute(host.el, StateAttribute),
                   "text": textContent(host.body), "facts": facts}
  var rows = newJArray()
  if not gLeaves.editor.isNil:
    for el in gLeaves.editor.rowEls:
      rows.add %*{"line": getAttribute(el, EditorRowAttribute),
                  "pointer": getAttribute(el, EditorPointerAttribute),
                  "flow": getAttribute(el, EditorFlowAttribute),
                  "values": getAttribute(el, EditorValuesAttribute),
                  "text": textContent(el)}
  var doc = %*{"panes": panes, "editorRows": rows}
  if not gLeaves.editorTab.isNil:
    doc["editorTab"] = %textContent(gLeaves.editorTab)
  if not gTopBar.popup.isNil:
    doc["openMenu"] = %getAttribute(gTopBar.popup, "data-ct-menu")
    doc["openMenuText"] = %textContent(gTopBar.popup)
    let layer = gRenderer.parentNode(gTopBar.popup)
    doc["openMenuInOverlay"] = %(not layer.isNil and
      layer == overlayRoot(gTopBar.el, olPopover))
  # With a capture, the pixel 3px into the execution row's code column, read
  # off the frame the real renderer drew: the band a reader sees.
  if gCmd.captureDir.len > 0 and not gLeaves.editor.isNil:
    let c = testing.capture()
    for el in gLeaves.editor.rowEls:
      if getAttribute(el, EditorPointerAttribute) == "eptExecution" and c.width > 0:
        let box = el.borderBox()
        if box.ok:
          let p = c.pixel(int(box.x) + 64 + 3, int(box.y + box.h / 2))
          doc["executionRowPixel"] = %("#" & toHex(p.r, 2) & toHex(p.g, 2) &
                                        toHex(p.b, 2)).toLowerAscii
          doc["executionRowLine"] = %getAttribute(el, EditorRowAttribute)
  writeFile(path, pretty(doc) & "\n")

proc pressKey(key: string) =
  ## Headless: one key, delivered by zgui to the focused element, then the
  ## frames it asked for run to idle. A key that ran an operation (a step) is
  ## timed as that operation; a key a view kept (a table's cursor) as itself.
  let before = gOps.len
  var op = Operation(name: "key:" & key, framesBefore: int(zg_frame_count()))
  gLeaves.resetCounters()
  let c0 = (zg_counter("nodes_visited"), zg_counter("nodes_relaid_out"),
            zg_counter("restyled"))
  gInKey = true
  let t0 = nowNs()
  try:
    var mods = 0'u32
    var name = key
    # `Alt+e`, `Ctrl+Shift+F5`: the modifiers before the key, by name.
    while true:
      let plus = name.find('+')
      if plus <= 0 or plus == name.high: break
      case name[0 ..< plus].toLowerAscii
      of "shift": mods = mods or ModShift
      of "ctrl", "control": mods = mods or ModCtrl
      of "alt": mods = mods or ModAlt
      of "meta", "cmd", "super": mods = mods or ModMeta
      else: break
      name = name[plus + 1 .. ^1]
    zgCheck(zg_headless_key(name.cstring, "".cstring, mods), "key " & key)
    # The platform queues the key and zgui dispatches it in the next frame,
    # so the listener — and a step it runs — runs inside this settle.
    discard settle()
  finally:
    gInKey = false
  let t1 = nowNs()
  discard settle()
  let t2 = nowNs()
  if gOps.len > before:
    op = gOps[^1]
    gOps.setLen(before)
    op.name = "key:" & key & " -> " & op.name
    op.settleNs = (t1 - t0) - op.engineNs - op.updateNs
  else:
    # The view's own handler ran inside the frame that delivered the key.
    op.settleNs = t1 - t0
    op.rowsWritten = gLeaves.rowsWritten
    (op.paneReplaced, op.paneWritten) = gLeaves.paneWork()
  op.settleNs += t2 - t1
  op.visited = zg_counter("nodes_visited") - c0[0]
  op.relaid = zg_counter("nodes_relaid_out") - c0[1]
  op.restyled = zg_counter("restyled") - c0[2]
  gOps.add op

proc findTagged(node: ZguiNode; attr, value: string): ZguiNode =
  if getAttribute(node, attr) == value: return node
  var c = gRenderer.firstChild(node)
  while not c.isNil:
    let found = findTagged(c, attr, value)
    if not found.isNil: return found
    c = gRenderer.nextSibling(c)
  noNode

proc clickOn(spec: string) =
  ## Headless: a pointer press and release at the centre of a top-bar part,
  ## or of a pane's row (`row:<pane>:<option id or row index>`).
  var target = noNode
  if spec.startsWith("row:"):
    let parts = spec.split(':', 2)
    let host = if parts.len == 3: gLeaves.panes.getOrDefault(parts[1]) else: nil
    if not host.isNil:
      target = findTagged(host.body, "data-option-id", parts[2])
      if target.isNil: target = findTagged(host.body, "data-row-index", parts[2])
  else:
    let (attr, value) =
      if spec.startsWith("menu:"): ("data-ct-menu-button", spec[5 .. ^1])
      elif spec.startsWith("action:"): ("data-ct-action", spec[7 .. ^1])
      elif spec.startsWith("control:"): ("data-ct-control", spec[8 .. ^1])
      else: raise newException(ValueError, "--clicks: '" & spec & "' is not " &
                               "menu:<name>, action:<action>, control:<id> " &
                               "or row:<pane>:<row>")
    target = findTagged(gTopBar.el, attr, value)
    if target.isNil and not gTopBar.popup.isNil:
      target = findTagged(gTopBar.popup, attr, value)
  if target.isNil:
    raise newException(ValueError, "--clicks: nothing to click for '" & spec & "'")
  let before = gOps.len
  var op = Operation(name: "click:" & spec, framesBefore: int(zg_frame_count()))
  let (x, y) = target.center()
  gInKey = true
  let t0 = nowNs()
  try:
    zgCheck(zg_headless_pointer(3, x, y), "click " & spec)
    discard settle()
  finally:
    gInKey = false
  let t1 = nowNs()
  discard settle()
  let t2 = nowNs()
  if gOps.len > before:
    op = gOps[^1]
    gOps.setLen(before)
    op.name = "click:" & spec & " -> " & op.name
    op.settleNs = (t1 - t0) - op.engineNs - op.updateNs
  else:
    op.settleNs = t1 - t0
  op.settleNs += t2 - t1
  gOps.add op

proc run(cmd: Command): int =
  gCmd = cmd
  ensureDispatchers()
  gSession = openGpuiTrace(cmd.traceFolder)
  defer: gSession.backend.close()
  if not gSession.session.editorVM.isNil:
    gSession.session.editorVM.showFlowOverlay.val = FlowOverlayShownByDefault

  gShell = newGpuiShell(DockViewport(width: cmd.width, height: cmd.height))
  let layout = initLayout(sharedDefaultLayout().tree,
                          sharedDefaultLayout().docked)
  let slot = gShell.app.openSession(gSession.backend.toBackendService(),
    title = extractFilename(gSession.tracePath.strip(chars = {'/'})),
    layout = layout, adopt = gSession.sdk)
  let opened = gShell.openWindowForSession(gWindow, slot.id)
  if opened.kind == wsRefused:
    stderr.writeLine("codetracer-zgui: could not open a window: " &
                     $opened.problem.kind)
    return 1
  discard slot.activatePane(paneCalltrace)

  gSource = newGpuiSourceService(gSession, cmd.traceFolder, 40)
  gSource.visibleRows = 40
  gSource.serveWindow()
  discard gSession.loadRecordingPanes(raiseOnStall = true)
  discard gSession.loadStopPanes()
  discard gSession.pageCalltrace(30, 0, 600, 16)
  gSession.selectCurrentCall()

  gMenu = newMenuVM(nativeFrontEndMenu("CodeTracer"))
  # The base every native host starts under: the flag, else the remembered
  # preference, else CUA (`keymap_preference.sessionKeymap`).
  let preference = sessionKeymap(cmd.keymap)
  gRouter = initKeymapRouter(preference.model, ZguiDelivery,
                             case preference.reason
                             of "flag": ksFlag
                             of "stored": ksStored
                             else: ksDefault)
  let loadStart = try: readFile("/proc/loadavg").splitWhitespace()[0 .. 2].join(" ")
                  except CatchableError: ""

  if cmd.headless:
    if cmd.captureDir.len > 0: createDir(cmd.captureDir)
    openHeadless(float32(cmd.width), float32(cmd.height), stylesheet(),
                 (if cmd.captureDir.len > 0: zrOffscreen else: zrNowhere),
                 buildWindow)
    try:
      zg_frames_reset()
      let t = nowNs()
      settleLayout()
      # The window takes the keyboard once it is in the document.
      gLeaves.root.focus()
      discard settle()
      gOps.add Operation(name: "open", settleNs: nowNs() - t)
      capture("open")
      for op in cmd.replayOps:
        let id = case op.kind
                 of "next": "next"
                 of "stepIn": "step-in"
                 of "stepOut": "step-out"
                 of "continueForward": "continue"
                 else: ""
        if id.len == 0: continue
        for _ in 0 ..< op.times:
          runControl(id, op.kind)
          capture(op.kind)
      for k in cmd.keys:
        pressKey(k)
        capture("key")
      for c in cmd.clicks:
        clickOn(c)
        capture("click")
      if cmd.factsOut.len > 0: writeFacts(cmd.factsOut)
      if cmd.frameReport.len > 0: writeFrameReport(cmd.frameReport, loadStart)
    finally:
      closeHeadless()
    return 0

  liftOpenBound(gSession)
  zg_frames_reset()
  runWindow(windowTitle(), float32(cmd.width), float32(cmd.height),
            stylesheet(), buildWindow)
  if cmd.frameReport.len > 0: writeFrameReport(cmd.frameReport, loadStart)
  0

proc main() =
  let cmd = parseCommand(commandLineParams())
  try:
    quit(run(cmd))
  except DapLaunchRefusedError as e:
    stderr.writeLine("codetracer-zgui: " & e.msg)
    quit(GpuiExitUnreadableRecording)
  except DapStalledError as e:
    stderr.writeLine("codetracer-zgui: " & cmd.traceFolder &
                     ": the replay engine stopped answering (" & e.msg & ")")
    quit(GpuiExitEngineStalled)
  except CatchableError as e:
    stderr.writeLine("codetracer-zgui: " & e.msg.splitLines()[0])
    quit(1)

when isMainModule:
  main()
