## viewmodels/shell_vm.nim — the Shell pane's MODEL, shared by the desktop,
## the terminal and the GPUI window.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7
## ("The Shell pane on every front-end").
##
## The interactive CodeTracer shell: a real shell on a pseudo-terminal, whose
## output this model emulates and whose recorded commands it marks. One model,
## so the three front-ends cannot disagree about what the shell printed, which
## lines a recorded command's indicator covers, what it says, or which
## recording a press on it opens.
##
## ## What it owns
##
##  1. **The session**, through a `ShellHost` the front-end hands it: start it
##     at the pane's size, forward input, resize it, stop it. The process is
##     the host's (a pty needs a native process — `common/shell_session.nim`
##     on the terminal and in the GPUI window, `ct shell-session` behind the
##     desktop's main process); WHEN to start, what to send and what the
##     answers mean are this model's.
##  2. **The output**: the PLAT-52 emulator (`terminal_output_model.TermScreen`)
##     run live — scrollback kept, ONLCR left to the pty — so every front-end
##     draws the same rows from the same cells.
##  3. **The actions** (`ShellAction`): what a command run in the shell reported
##     on the session's event channel (§2.3) — a compile, a link, a recording —
##     with its status and the output lines it covers (§7.4: stamped here, when
##     the event arrives, the host having delivered every byte of output written
##     before it).
##  4. **The recordings** those actions produced, and opening one (§7.6).
##  5. **The keys**: which go to the shell and as what bytes, and the prefix
##     that reaches CodeTracer's own keys while the pane has the focus (§7.5).
##
## Pure apart from its signals: no renderer, no process, no
## `when defined(js)`. It compiles for the C and the JavaScript backends.

import std/[base64, json, strutils]

import isonim/core/[signals, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]
import ./terminal_output_model

export terminal_output_model.ScreenRun, terminal_output_model.TermScreen

const
  ShellScrollbackLines* = 5000
    ## Lines kept above the screen (§7.3).
  ShellDefaultCols* = 80
  ShellDefaultRows* = 24
  ShellPrefixChord* = "Ctrl+]"
    ## The stated prefix (§7.5): pressed in the focused pane, the NEXT key goes
    ## to CodeTracer instead of the shell; pressed twice, the shell gets it.
  ShellPrefixByte* = "\x1d"
    ## What `Ctrl+]` is on a terminal line (GS).
  ShellActionMarkOsc* = "6973"
    ## The OSC `ct record` writes to its terminal as it reports a recording
    ## (§7.4): `ESC ] 6973 ; action=<id> ; status=<working|ok|error> BEL`,
    ## written BEFORE the report line — so the mark sits in the output exactly
    ## where the command's output starts or ends.

type
  ShellActionKind* = enum
    sakCompile = "compile"   ## `CustomCompilerFlagCommand`
    sakLink = "link"         ## `LinkingBinary`
    sakRecord = "record"     ## `RecordingCommand`

  ShellActionStatus* = enum
    sasWorking = "working"
    sasOk = "ok"
    sasError = "error"

  ShellAction* = object
    ## One command the session's event channel reported on (§2.3), by its
    ## `actionId`: a `WorkingStatus` event opens it, an `OkStatus` /
    ## `ErrorStatus` event settles it.
    actionId*: int
    kind*: ShellActionKind
    status*: ShellActionStatus
    command*: string
    program*: string        ## a compile's program
    binary*: string         ## a link's binary
    errorMessage*: string
    recordingId*: string    ## a settled recording's id
    traceFolder*: string    ## …and its folder, which a front-end opens
    firstLine*, lastLine*: int
      ## ABSOLUTE output lines (`TermScreen.scrolledOff` counting): the first
      ## line the command wrote on and the last. A working action's last line
      ## follows the cursor (`actionRange`).

  ShellTone* = enum
    ## How an indicator is coloured; each front-end maps it onto its theme's
    ## roles (`working` → the busy role, `ok` → success, `error` → error).
    stWorking = "working"
    stOk = "ok"
    stError = "error"

  ShellSessionState* = enum
    sssIdle = "idle"          ## not started yet
    sssRunning = "running"
    sssExited = "exited"      ## the shell exited (`exitCode`)
    sssFailed = "failed"      ## could not start (`failure`)

  ShellHost* = object
    ## The front-end's process side. Every member may be nil: a front-end that
    ## cannot run a process (a browser without a main process) leaves `start`
    ## nil, and the pane says so.
    start*: proc(cols, rows: int): string {.closure.}
      ## Spawn the shell at that size; "" when it started, else why not.
    input*: proc(data: string) {.closure.}
    resize*: proc(cols, rows: int) {.closure.}
    stop*: proc() {.closure.}

  ShellKey* = object
    ## A key press, front-end neutral: `key` is the key's name as the keymaps
    ## spell it (`Enter`, `Up`, `F5`, `a`, `]`), `text` what it types (empty
    ## for a named key, the character otherwise).
    key*: string
    text*: string
    ctrl*, alt*, shift*: bool

  ShellKeyRouteKind* = enum
    skrShell     ## send `bytes` to the shell
    skrApp       ## the key is CodeTracer's (the prefix was armed)
    skrConsumed  ## the prefix itself: armed, nothing else happens

  ShellKeyRoute* = object
    kind*: ShellKeyRouteKind
    bytes*: string

  ShellRowMark* = enum
    srmNone      ## no action covers the line
    srmStart     ## the first line of an action: its glyph
    srmRange     ## a later line of an action: its bar

  ShellActionMark* = object
    ## Where a command's mark was in the output (`ShellActionMarkOsc`).
    actionId*: int
    status*: ShellActionStatus
    line*, col*: int

  ShellRow* = object
    ## One output line as a front-end draws it.
    line*: int               ## absolute line
    text*: string            ## its characters, trailing blanks removed
    runs*: seq[ScreenRun]    ## styled runs over every column
    cursorCol*: int          ## the cursor's column on this line, else -1
    mark*: ShellRowMark
    action*: int             ## index into `actions` when `mark != srmNone`
    tone*: ShellTone

  ShellVM* = ref object of ViewModel
    ## Reactive state for the Shell pane.
    ##
    ## Mutable signals:
    ##   state     — the session's lifecycle
    ##   revision  — bumped on every change a pane draws (output, an action,
    ##               the scroll position); panes re-read on it
    ##   scrollTop — the first line shown, as an index into the kept lines;
    ##               -1 follows the tail
    ##   note      — the last thing the pane has to say (the status line)
    store*: ReplayDataStore
      ## Unused by the shell itself (a shell outlives recordings); kept so the
      ## session's VM set constructs every VM alike.
    host*: ShellHost
    openRecording*: proc(action: ShellAction): string {.closure.}
      ## The front-end's "open this recording" (a new session tab on the
      ## terminal and in the GPUI window, the desktop's open-in-a-new-window);
      ## "" when it opened, else why not.
    screen*: TermScreen
    actions*: seq[ShellAction]
    exitCode*: int
    failure*: string
    prefixArmed*: bool
    opened*: seq[string]
      ## The recordings this pane opened, in order: the folder (or id) of each.
    marks*: seq[ShellActionMark]
      ## The action marks read from the output, not yet taken by an event.

    state*: Signal[ShellSessionState]
    revision*: Signal[int]
    scrollTop*: Signal[int]
    note*: Signal[string]

# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

proc newShellScreen*(cols, rows: int): TermScreen =
  ## The live emulator §7.3 describes: scrollback kept, a line feed only a
  ## line feed (the pty applied ONLCR).
  result = newTermScreen(max(1, cols), max(1, rows))
  result.onlcr = false
  result.scrollbackLimit = ShellScrollbackLines

proc firstKeptLine*(vm: ShellVM): int =
  ## The oldest line still held (the scrollback's first, else the screen's).
  vm.screen.scrolledOff - vm.screen.keptLines

proc cursorLine*(vm: ShellVM): int =
  ## The absolute line the cursor is on.
  vm.screen.scrolledOff + vm.screen.row

proc lastScreenRowUsed(s: TermScreen): int =
  result = s.row
  for r in countdown(s.rows - 1, s.row + 1):
    if s.screenRowText(r).strip(leading = false).len > 0:
      return r

proc lastLine*(vm: ShellVM): int =
  ## The last line with output or the cursor on it.
  vm.screen.scrolledOff + lastScreenRowUsed(vm.screen)

proc lineCount*(vm: ShellVM): int =
  ## The lines a pane can show, scrollback included.
  vm.lastLine - vm.firstKeptLine + 1

proc lineCells(vm: ShellVM; line: int): seq[TermCell] =
  let s = vm.screen
  if line < s.scrolledOff:
    return s.keptLine(line - (s.scrolledOff - s.keptLines))
  let row = line - s.scrolledOff
  if row < 0 or row >= s.rows:
    return @[]
  result = newSeq[TermCell](s.cols)
  for c in 0 ..< s.cols:
    result[c] = s.cellAt(row, c)

proc lineText*(vm: ShellVM; line: int): string =
  ## A line's characters, trailing blanks removed.
  cellsText(vm.lineCells(line)).strip(leading = false)

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc actionRange*(vm: ShellVM; a: ShellAction): tuple[first, last: int] =
  ## The lines an action covers: a working one reaches the cursor.
  if a.status == sasWorking:
    (a.firstLine, max(a.firstLine, vm.cursorLine))
  else:
    (a.firstLine, max(a.firstLine, a.lastLine))

proc actionAtLine*(vm: ShellVM; line: int): int =
  ## The action covering `line` (the LATEST, when two do), else -1.
  result = -1
  for i in countdown(vm.actions.high, 0):
    let (f, l) = vm.actionRange(vm.actions[i])
    if line >= f and line <= l:
      return i

func toneOf*(a: ShellAction): ShellTone =
  case a.status
  of sasWorking: stWorking
  of sasOk: stOk
  of sasError: stError

func actionGlyph*(a: ShellAction; ascii = false): string =
  ## The indicator on an action's first line (§7.5).
  case a.status
  of sasWorking: (if ascii: "~" else: "◌")
  of sasOk: (if ascii: "*" else: "●")
  of sasError: (if ascii: "x" else: "✕")

func actionBar*(ascii = false): string =
  ## The indicator on an action's later lines.
  if ascii: "|" else: "│"

func shortId*(recordingId: string): string =
  ## A recording id as the pane prints it: its first eight characters.
  if recordingId.len > 8: recordingId[0 ..< 8] else: recordingId

func actionSummary*(a: ShellAction): string =
  ## What an action says — the desktop's gutter words (`ui/shell.nim`'s
  ## `eventSummary`), now the model's, so every front-end says the same.
  case a.kind
  of sakCompile:
    "custom compiling flags: " & a.program
  of sakLink:
    case a.status
    of sasWorking: "linking binary: " & a.binary
    of sasOk: "linked and marked binary: " & a.binary
    of sasError: "didn't link binary: " & a.binary & ": error " & a.errorMessage
  of sakRecord:
    case a.status
    of sasWorking: "recording command: " & a.command
    of sasOk:
      "recorded command: " & a.command & " — recording " & shortId(a.recordingId)
    of sasError:
      "error recording command: " & a.command & " error: " & a.errorMessage

func actionHint*(a: ShellAction): string =
  ## What a press on the indicator would do, said before it is pressed.
  if a.kind != sakRecord:
    "not a recording"
  else:
    case a.status
    of sasWorking: "still recording"
    of sasOk:
      if a.recordingId.len == 0 and a.traceFolder.len == 0:
        "the recording reported no id"
      else: "open the recording"
    of sasError: "the recording failed: " & a.errorMessage

proc enumOf[T: enum](n: JsonNode; names: openArray[(string, T)]; default: T): T =
  ## An enum the event channel spelled as its Nim name or its ordinal.
  if n.isNil: return default
  case n.kind
  of JString:
    for (name, v) in names:
      if n.getStr == name: return v
  of JInt:
    let i = n.getInt
    if i >= 0 and i < names.len: return names[i][1]
  else: discard
  default

proc str(n: JsonNode; key: string): string =
  if n.isNil or n.kind != JObject: return ""
  let v = n{key}
  if v.isNil: ""
  elif v.kind == JString: v.getStr
  elif v.kind == JInt: $v.getInt
  else: ""

proc actionFromEvent*(ev: JsonNode): ShellAction =
  ## A `SessionEvent` (§2.3) as `ct record` writes it on the report file
  ## (`trace_index.sessionEventJson`): `kind` and `status` by name, the
  ## recording's id and folder under `trace`.
  result.kind = enumOf(ev{"kind"}, [("CustomCompilerFlagCommand", sakCompile),
                                     ("LinkingBinary", sakLink),
                                     ("RecordingCommand", sakRecord)], sakRecord)
  result.status = enumOf(ev{"status"}, [("WorkingStatus", sasWorking),
                                         ("OkStatus", sasOk),
                                         ("ErrorStatus", sasError)], sasWorking)
  result.actionId = (if ev{"actionId"}.isNil: -1 else: ev{"actionId"}.getInt(-1))
  result.command = ev.str("command")
  result.program = ev.str("program")
  result.binary = ev.str("binary")
  result.errorMessage = ev.str("errorMessage")
  let trace = ev{"trace"}
  result.recordingId = trace.str("recordingId")
  result.traceFolder = trace.str("outputFolder")

proc parseActionMark*(payload: string; line, col: int;
                      mark: var ShellActionMark): bool =
  ## `6973;action=<id>;status=<…>` as a mark; false for any other OSC.
  let parts = payload.split(';')
  if parts.len < 3 or parts[0] != ShellActionMarkOsc:
    return false
  mark = ShellActionMark(actionId: -1, line: line, col: col)
  var statusSeen = false
  for p in parts[1 .. ^1]:
    let eq = p.find('=')
    if eq < 0: continue
    let (k, v) = (p[0 ..< eq], p[eq + 1 .. ^1])
    case k
    of "action":
      try: mark.actionId = parseInt(v)
      except ValueError: return false
    of "status":
      case v
      of "working": mark.status = sasWorking
      of "ok": mark.status = sasOk
      of "error": mark.status = sasError
      else: return false
      statusSeen = true
    else: discard
  mark.actionId >= 0 and statusSeen

proc takeMark(vm: ShellVM; actionId: int; status: ShellActionStatus;
              mark: var ShellActionMark): bool =
  for i, m in vm.marks:
    if m.actionId == actionId and m.status == status:
      mark = m
      vm.marks.delete(i)
      return true

proc bump(vm: ShellVM) =
  vm.revision.val = vm.revision.val + 1

func settledLastLine(first, line, col: int): int =
  ## The last line a command that just finished wrote on: the line its mark
  ## (or the cursor) is on, or the one above when that is the start of a fresh
  ## line.
  var last = line
  if col == 0 and last > first:
    dec last
  max(first, last)

proc receiveEvent*(vm: ShellVM; ev: JsonNode) =
  ## An event from the session's channel. The host delivers it AFTER every
  ## byte of output written before it, so the lines stamped here are the
  ## output's (§7.4): a new action starts at the cursor's line; a settled one
  ## ends at the last line written.
  let incoming = actionFromEvent(ev)
  # Where the command marked the output (§7.4); else where the output stood
  # when the event arrived.
  var mark: ShellActionMark
  let marked = incoming.actionId >= 0 and
               vm.takeMark(incoming.actionId, incoming.status, mark)
  var at = -1
  if incoming.actionId >= 0:
    for i, a in vm.actions:
      if a.actionId == incoming.actionId and a.kind == incoming.kind:
        at = i
        break
  let (line, col) = if marked: (mark.line, mark.col)
                    else: (vm.cursorLine, vm.screen.col)
  if at < 0:
    var a = incoming
    a.firstLine = line
    if a.status != sasWorking and col == 0 and a.firstLine > vm.firstKeptLine:
      # A settled event with no working one before it: the command's line
      # is the one the cursor just left.
      dec a.firstLine
    a.lastLine = (if a.status == sasWorking: a.firstLine
                  else: settledLastLine(a.firstLine, line, col))
    vm.actions.add a
  else:
    var a = vm.actions[at]
    let first = a.firstLine
    a.status = incoming.status
    if incoming.command.len > 0: a.command = incoming.command
    if incoming.program.len > 0: a.program = incoming.program
    if incoming.binary.len > 0: a.binary = incoming.binary
    if incoming.errorMessage.len > 0: a.errorMessage = incoming.errorMessage
    if incoming.recordingId.len > 0: a.recordingId = incoming.recordingId
    if incoming.traceFolder.len > 0: a.traceFolder = incoming.traceFolder
    a.lastLine = (if a.status == sasWorking: first
                  else: settledLastLine(first, line, col))
    vm.actions[at] = a
  vm.bump()

proc receiveOutput*(vm: ShellVM; data: string) =
  ## Bytes the shell wrote to its terminal — and the action marks in them.
  if data.len == 0: return
  vm.screen.feed(data)
  for o in vm.screen.oscSeen:
    var m: ShellActionMark
    if parseActionMark(o.payload, o.line, o.col, m):
      vm.marks.add m
  vm.bump()

proc receiveExit*(vm: ShellVM; code: int) =
  vm.exitCode = code
  vm.state.val = sssExited
  vm.note.val = "the shell exited (" & $code & ")"
  vm.bump()

proc receiveFailure*(vm: ShellVM; why: string) =
  vm.failure = why
  vm.state.val = sssFailed
  vm.note.val = why
  vm.bump()

proc receiveUpdate*(vm: ShellVM; msg: JsonNode) =
  ## One message of the session wire (§7.2): `{"output": <base64>}`,
  ## `{"event": <SessionEvent>}`, `{"exit": <code>}`, `{"failed": <why>}`.
  if msg.isNil or msg.kind != JObject: return
  if msg.hasKey("output"):
    vm.receiveOutput(decode(msg["output"].getStr))
  elif msg.hasKey("event"):
    vm.receiveEvent(msg["event"])
  elif msg.hasKey("exit"):
    vm.receiveExit(msg["exit"].getInt)
  elif msg.hasKey("failed"):
    vm.receiveFailure(msg["failed"].getStr)

proc outputMessage*(data: string): JsonNode = %*{"output": encode(data)}
proc eventMessage*(ev: JsonNode): JsonNode = %*{"event": ev}
proc exitMessage*(code: int): JsonNode = %*{"exit": code}
proc failedMessage*(why: string): JsonNode = %*{"failed": why}

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc startShell*(vm: ShellVM; cols, rows: int) =
  ## Start the session at the pane's size, once.
  if vm.state.val == sssRunning:
    return
  vm.screen = newShellScreen(cols, rows)
  vm.actions.setLen(0)
  vm.marks.setLen(0)
  vm.failure = ""
  vm.prefixArmed = false
  if vm.host.start.isNil:
    vm.receiveFailure("this front-end cannot run a shell")
    return
  let why = vm.host.start(max(1, cols), max(1, rows))
  if why.len > 0:
    vm.receiveFailure(why)
    return
  vm.state.val = sssRunning
  vm.scrollTop.val = -1
  vm.note.val = ""
  vm.bump()

proc resizeShell*(vm: ShellVM; cols, rows: int) =
  ## The pane's text area took a new size.
  let cols = max(1, cols)
  let rows = max(1, rows)
  if cols == vm.screen.cols and rows == vm.screen.rows:
    return
  vm.screen.resize(cols, rows)
  if vm.state.val == sssRunning and not vm.host.resize.isNil:
    vm.host.resize(cols, rows)
  vm.bump()

proc stopShell*(vm: ShellVM) =
  if vm.state.val == sssRunning and not vm.host.stop.isNil:
    vm.host.stop()

proc sendInput*(vm: ShellVM; data: string) =
  ## Bytes typed or pasted into the shell; the view returns to the tail.
  if data.len == 0 or vm.state.val != sssRunning or vm.host.input.isNil:
    return
  vm.host.input(data)
  if vm.scrollTop.val != -1:
    vm.scrollTop.val = -1
    vm.bump()

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

proc visibleTop*(vm: ShellVM; height: int): int =
  ## The first kept line shown in a `height`-line view (an index from
  ## `firstKeptLine`).
  let maxTop = max(0, vm.lineCount - max(1, height))
  if vm.scrollTop.val < 0: maxTop
  else: min(vm.scrollTop.val, maxTop)

proc scrollShell*(vm: ShellVM; delta, height: int) =
  ## The wheel / the scrollbar: move the view by `delta` lines; reaching the
  ## tail follows it again.
  let maxTop = max(0, vm.lineCount - max(1, height))
  let top = max(0, min(maxTop, vm.visibleTop(height) + delta))
  vm.scrollTop.val = (if top >= maxTop: -1 else: top)
  vm.bump()

proc scrollShellTo*(vm: ShellVM; top, height: int) =
  let maxTop = max(0, vm.lineCount - max(1, height))
  let top = max(0, min(maxTop, top))
  vm.scrollTop.val = (if top >= maxTop: -1 else: top)
  vm.bump()

proc shellRow*(vm: ShellVM; line: int): ShellRow =
  ## One absolute line as a front-end draws it.
  let cells = vm.lineCells(line)
  result.line = line
  result.text = cellsText(cells).strip(leading = false)
  result.runs = vm.screen.cellsRuns(cells)
  result.cursorCol =
    if line == vm.cursorLine and vm.screen.cursorVisible and
       vm.state.val == sssRunning: vm.screen.col
    else: -1
  result.action = vm.actionAtLine(line)
  if result.action >= 0:
    let a = vm.actions[result.action]
    result.mark = (if line == a.firstLine: srmStart else: srmRange)
    result.tone = a.toneOf

proc shellRows*(vm: ShellVM; height: int): seq[ShellRow] =
  ## The rows a `height`-line view shows now.
  let first = vm.firstKeptLine + vm.visibleTop(height)
  let last = min(vm.lastLine, first + max(1, height) - 1)
  for line in first .. last:
    result.add vm.shellRow(line)

# ---------------------------------------------------------------------------
# Indicators
# ---------------------------------------------------------------------------

proc activateAction*(vm: ShellVM; index: int): string =
  ## A press on an action's indicator (§7.6): a settled recording opens; any
  ## other action says why it cannot. The words go to the pane's note.
  if index < 0 or index >= vm.actions.len:
    return ""
  let a = vm.actions[index]
  if a.kind == sakRecord and a.status == sasOk and
     (a.traceFolder.len > 0 or a.recordingId.len > 0):
    if vm.openRecording.isNil:
      result = "this front-end cannot open a recording"
    else:
      result = vm.openRecording(a)
      if result.len == 0:
        vm.opened.add(if a.traceFolder.len > 0: a.traceFolder else: a.recordingId)
        result = "opened recording " & shortId(a.recordingId)
  else:
    result = a.actionHint
  vm.note.val = result
  vm.bump()

proc activateLine*(vm: ShellVM; line: int): string =
  ## A press on a line's indicator.
  vm.activateAction(vm.actionAtLine(line))

proc recordedActions*(vm: ShellVM): seq[int] =
  ## The settled recordings, oldest first.
  for i, a in vm.actions:
    if a.kind == sakRecord and a.status == sasOk:
      result.add i

# ---------------------------------------------------------------------------
# Keys (§7.5)
# ---------------------------------------------------------------------------

func isPrefix*(k: ShellKey): bool =
  k.ctrl and not k.alt and (k.key == "]" or k.text == "]")

proc cursorKey(final: char; app: bool; mods: int): string =
  if mods > 1: "\e[1;" & $mods & final
  elif app: "\eO" & final
  else: "\e[" & final

proc tildeKey(code: int; mods: int): string =
  if mods > 1: "\e[" & $code & ";" & $mods & "~"
  else: "\e[" & $code & "~"

func modsParam(k: ShellKey): int =
  1 + (if k.shift: 1 else: 0) + (if k.alt: 2 else: 0) + (if k.ctrl: 4 else: 0)

proc keyBytes*(k: ShellKey; appCursor = false): string =
  ## The bytes a key sends to the shell, as xterm sends them.
  let mods = k.modsParam
  case k.key
  of "Enter", "Return": result = "\r"
  of "Tab": result = (if k.shift: "\e[Z" else: "\t")
  of "Backspace": result = (if k.ctrl: "\x08" else: "\x7f")
  of "Escape", "Esc": result = "\e"
  of "Up": result = cursorKey('A', appCursor, mods)
  of "Down": result = cursorKey('B', appCursor, mods)
  of "Right": result = cursorKey('C', appCursor, mods)
  of "Left": result = cursorKey('D', appCursor, mods)
  of "Home": result = cursorKey('H', appCursor, mods)
  of "End": result = cursorKey('F', appCursor, mods)
  of "Insert": result = tildeKey(2, mods)
  of "Delete": result = tildeKey(3, mods)
  of "PageUp": result = tildeKey(5, mods)
  of "PageDown": result = tildeKey(6, mods)
  # F1-F4 are SS3 keys (`ESC O P`..`ESC O S`) in either cursor mode, with
  # xterm's `CSI 1 ; <mods> P` form when modified: `cursorKey`'s app branch.
  of "F1": result = cursorKey('P', true, mods)
  of "F2": result = cursorKey('Q', true, mods)
  of "F3": result = cursorKey('R', true, mods)
  of "F4": result = cursorKey('S', true, mods)
  of "F5": result = tildeKey(15, mods)
  of "F6": result = tildeKey(17, mods)
  of "F7": result = tildeKey(18, mods)
  of "F8": result = tildeKey(19, mods)
  of "F9": result = tildeKey(20, mods)
  of "F10": result = tildeKey(21, mods)
  of "F11": result = tildeKey(23, mods)
  of "F12": result = tildeKey(24, mods)
  of "Space": result = (if k.ctrl: "\x00" else: " ")
  else:
    var t = (if k.text.len > 0: k.text else: k.key)
    if t.len == 1 and k.ctrl:
      let c = t[0]
      case c
      of 'a'..'z': t = $chr(ord(c) - ord('a') + 1)
      of 'A'..'Z': t = $chr(ord(c) - ord('A') + 1)
      of '@', ' ', '2': t = "\x00"
      of '[', '3': t = "\e"
      of '\\', '4': t = "\x1c"
      of ']', '5': t = "\x1d"
      of '^', '6': t = "\x1e"
      of '_', '-', '7': t = "\x1f"
      of '?', '8': t = "\x7f"
      else: discard
    if k.alt:
      t = "\e" & t
    result = t

proc shellKeyOfChord*(name: string): ShellKey =
  ## A canonical key name (`common/key_names.chordName`: `Ctrl+Shift+k`,
  ## `Alt+a`, `Up`, `A`, `Space`) as the model's key — what the terminal's and
  ## GPUI's key decoders produce.
  var rest = name
  while true:
    let plus = rest.find('+')
    if plus <= 0 or plus == rest.high: break
    case rest[0 ..< plus]
    of "Ctrl": result.ctrl = true
    of "Shift": result.shift = true
    of "Alt": result.alt = true
    of "Meta": discard
    else: break
    rest = rest[plus + 1 .. ^1]
  result.key = rest
  if rest.len == 1:
    result.text = rest

proc routeKey*(vm: ShellVM; k: ShellKey): ShellKeyRoute =
  ## Where a key pressed in the focused pane goes (§7.5): to the shell, as
  ## bytes; or — after the prefix — to CodeTracer. The prefix twice sends the
  ## prefix itself.
  if vm.prefixArmed:
    vm.prefixArmed = false
    vm.note.val = ""
    if k.isPrefix:
      return ShellKeyRoute(kind: skrShell, bytes: ShellPrefixByte)
    return ShellKeyRoute(kind: skrApp)
  if k.isPrefix:
    vm.prefixArmed = true
    vm.note.val = ShellPrefixChord & ": the next key goes to CodeTracer (" &
                  ShellPrefixChord & " again sends it to the shell)"
    vm.bump()
    return ShellKeyRoute(kind: skrConsumed)
  ShellKeyRoute(kind: skrShell, bytes: keyBytes(k, vm.screen.appCursor))

proc pressKey*(vm: ShellVM; k: ShellKey): ShellKeyRoute =
  ## `routeKey`, and the shell's bytes sent.
  result = vm.routeKey(k)
  if result.kind == skrShell:
    vm.sendInput(result.bytes)

# ---------------------------------------------------------------------------
# Words
# ---------------------------------------------------------------------------

proc statusWords*(vm: ShellVM): string =
  ## The pane's one-line state, for its strip / title.
  case vm.state.val
  of sssIdle: "not started"
  of sssRunning:
    let n = vm.recordedActions.len
    if n == 0: "running"
    elif n == 1: "running — 1 recording"
    else: "running — " & $n & " recordings"
  of sssExited: "exited (" & $vm.exitCode & ")"
  of sssFailed: "could not start: " & vm.failure

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createShellVM*(store: ReplayDataStore = nil): ShellVM =
  ## Create a ShellVM inside a reactive root owned by `withViewModel`.
  withViewModel proc(dispose: proc()): ShellVM =
    ShellVM(
      store: store,
      screen: newShellScreen(ShellDefaultCols, ShellDefaultRows),
      state: createSignal(sssIdle),
      revision: createSignal(0),
      scrollTop: createSignal(-1),
      note: createSignal(""),
      disposeProc: dispose,
    )
