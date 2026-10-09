## viewmodels/native_welcome.nim — PLAT-51 deliverable 8: THE WELCOME SCREEN
## OF A NEW SESSION TAB on the terminal and in the GPUI window.
##
## Multi-Window-Tab-Management.md rule 3 (the user, 2026-10-05): the "+"
## opens a new tab showing the Welcome Screen — open a folder, record a new
## recording, open an existing recording, and the recent lists — on EVERY
## front-end, "from the same `WelcomeScreenVM` start options … choosing an
## option turns that tab into the session it starts".
##
## This module is the native front-ends' ONE model of that screen. It holds
## a real `WelcomeScreenVM` (the desktop's own ViewModel, over a stub store
## exactly as the desktop's `ui/welcome_screen.nim` builds it: the screen's
## flows are host concerns, not engine commands) with the NATIVE ARM's strip
## (`nativeWelcomeStartOptions`) and the recent lists the host knows, and adds
## what a keyboard-and-pointer screen without a file dialog needs:
##
##   * the screen's ROWS, in reading order — the recent folders, the recent
##     recordings, then the six start options — each with its label, its
##     detail and, for a refused option, the reason (the desktop's tooltip);
##   * a FOCUS over them (Up / Down / Tab), and Enter to choose;
##   * the one-line FORM a chosen option opens where the desktop opens a
##     dialog: the folder to open, the recording to open, or the program to
##     record and its arguments (the desktop's Start Debugger form, reduced
##     to its one required field — `isNewRecordValid` needs the executable).
##
## What a choice DOES is the VM's own action — `loadRecentFolder`,
## `loadRecentTrace`, `submitNewRecord` — whose host callbacks this module
## installs to turn the decision into an INTENT the front-end performs
## (`takeIntent`): Edit mode over a folder, a recording opened in this tab, a
## program recorded with `ct record` and then opened. The terminal
## (`tui/app/views/welcome_view`) and GPUI (`gpui/welcome_leaf`) draw the
## same rows and route the same keys here, so the two cannot list different
## options or act on them differently.
##
## Native C backend (it is a host-facing model; the browser has its own
## view of the same VM).

import std/[json, options, strutils]

import isonim/core/[async_compat, signals]

import ../backend/backend_service
import ../store/[replay_data_store, types]
import ./welcome_screen_vm

export welcome_screen_vm

type
  NativeWelcomeRowKind* = enum
    nwrRecentFolder = "recent-folder"
    nwrRecentTrace = "recent-trace"
    nwrOption = "option"

  NativeWelcomeRow* = object
    kind*: NativeWelcomeRowKind
    index*: int
      ## Into the VM's list of that kind.
    key*: string
      ## The option's key (`open-folder`, …), or the entry's path.
    label*: string
    detail*: string
      ## A recent entry's folder; an option's refusal reason.
    enabled*: bool

  NativeWelcomeForm* = enum
    nwfNone = "none"
    nwfOpenFolder = "open-folder"
    nwfOpenTrace = "open-local-trace"
    nwfRecord = "record-new-trace"

  NativeWelcomeIntentKind* = enum
    niNone = "none"
    niOpenFolder = "open-folder"
      ## Turn the tab into an Edit-mode session over `path`.
    niOpenTrace = "open-trace"
      ## Turn the tab into a replay of the recording at `path`.
    niRecord = "record"
      ## Record `program` with `args` (`ct record`), then open the result in
      ## this tab.

  NativeWelcomeIntent* = object
    kind*: NativeWelcomeIntentKind
    path*: string
    program*: string
    args*: seq[string]

  NativeWelcome* = ref object
    vm*: WelcomeScreenVM
    focus*: int
      ## Index into `rows`.
    form*: NativeWelcomeForm
    input*: string
      ## The form's field.
    placeholder*: string
      ## What Enter on an EMPTY field uses — "Open folder" offers the
      ## process's own folder — shown in the field until a key is typed.
    message*: string
      ## What the screen says under the strip: a refusal, a progress line
      ## ("recording …"), a failure the host reported.
    pending: NativeWelcomeIntent

const
  NativeWelcomeHeading* = "Welcome to CodeTracer"
    ## Welcome-Screen.md: "Welcome to" and the product's name.
  RecentFoldersHeading* = "Recent folders"
  RecentTracesHeading* = "Recent traces"
  RecentFoldersEmpty* = "Folders you open are listed here."
  RecentTracesEmpty* = "Traces you record are listed here."
    ## Welcome-Screen.md, "What an empty panel says".

proc rowsOf*(w: NativeWelcome): seq[NativeWelcomeRow]
  ## Forward-declared; see below.

proc stubStore(): ReplayDataStore =
  ## The store a welcome VM holds — over a backend that answers nothing, as
  ## the desktop's `ui/welcome_screen.ensureWelcomeScreenVm` builds it: the
  ## screen's flows are host concerns, never engine commands.
  let send = proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
    # An already-settled future on either backend (`newCompletedFuture`, the
    # spelling `platform/outcome.resolved` explains): the facade exports this
    # module, so it compiles to JavaScript too.
    newCompletedFuture(%*{})
  createReplayDataStore(BackendService(
    sendProc: send,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard))

proc newNativeWelcome*(recentFolders: seq[string];
                       recentTraces: seq[string]): NativeWelcome =
  ## A new tab's welcome screen: the native strip, and the folders and
  ## recordings the host knows (each a path).
  let vm = createWelcomeScreenVM(stubStore())
  vm.setStartOptions(nativeWelcomeStartOptions())
  var folders: seq[RecentFolderRecord] = @[]
  for i, f in recentFolders:
    folders.add RecentFolderRecord(id: i, name: f.strip(chars = {'/'}).split('/')[^1],
                                   path: f)
  vm.setRecentFolders(folders)
  var traces: seq[RecentTraceRecord] = @[]
  for t in recentTraces:
    let trimmed = t.strip(leading = false, chars = {'/'})
    let cut = trimmed.rfind('/')
    traces.add RecentTraceRecord(recordingId: t,
                                 program: trimmed[cut + 1 .. ^1],
                                 workdir: (if cut > 0: trimmed[0 ..< cut]
                                           else: ""))
  vm.setRecentTraces(traces)
  result = NativeWelcome(vm: vm, focus: 0, form: nwfNone)
  let w = result
  # THE VM DECIDES, THE HOST PERFORMS: its four host callbacks become the
  # intent the front-end takes.
  vm.onLoadRecentFolder = proc(folderPath: string) =
    w.pending = NativeWelcomeIntent(kind: niOpenFolder, path: folderPath)
  vm.onLoadRecentTrace = proc(recordingId: string) =
    w.pending = NativeWelcomeIntent(kind: niOpenTrace, path: recordingId)
  vm.onSubmitNewRecord = proc(request: NewRecordRequest) =
    w.pending = NativeWelcomeIntent(kind: niRecord, program: request.executable,
                                    args: request.args)
  # The first live option is where the focus starts.
  let all = w.rowsOf()
  for i, r in all:
    if r.kind == nwrOption and r.enabled:
      w.focus = i
      break

proc rowsOf*(w: NativeWelcome): seq[NativeWelcomeRow] =
  ## Every row of the screen in reading order: the recent folders, the
  ## recent recordings, the six start options.
  for i, f in w.vm.recentFolders.val:
    result.add NativeWelcomeRow(kind: nwrRecentFolder, index: i, key: f.path,
                                label: f.name, detail: f.path, enabled: true)
  for i, t in w.vm.recentTraces.val:
    result.add NativeWelcomeRow(kind: nwrRecentTrace, index: i,
                                key: t.recordingId, label: t.program,
                                detail: t.workdir, enabled: true)
  for i, o in w.vm.startOptions.val:
    result.add NativeWelcomeRow(kind: nwrOption, index: i, key: o.key,
                                label: o.name, detail: o.disabledReason,
                                enabled: not o.inactive)

proc formPrompt*(f: NativeWelcomeForm): string =
  case f
  of nwfNone: ""
  of nwfOpenFolder: "Folder to open: "
  of nwfOpenTrace: "Recording to open: "
  of nwfRecord: "Program to record, then its arguments: "

proc takeIntent*(w: NativeWelcome): NativeWelcomeIntent =
  ## The choice the host must now perform, once; `niNone` when there is none.
  result = w.pending
  w.pending = NativeWelcomeIntent(kind: niNone)

proc openForm(w: NativeWelcome; f: NativeWelcomeForm; prefill = "") =
  w.form = f
  w.input = ""
  w.placeholder = prefill
  w.message = ""
  if f == nwfRecord:
    w.vm.showNewRecord()

proc closeForm*(w: NativeWelcome) =
  ## `Esc` in a form: back to the screen, nothing chosen.
  if w.form == nwfRecord:
    w.vm.showWelcome()
  w.form = nwfNone
  w.input = ""
  w.placeholder = ""

proc activate*(w: NativeWelcome; row: int; folderDefault = "") =
  ## Choose row `row` (a click, or Enter on the focus): a recent entry is
  ## opened at once; a live option opens its form; a refused option says
  ## why, and does nothing else.
  let all = w.rowsOf()
  if row < 0 or row >= all.len:
    return
  w.focus = row
  let r = all[row]
  case r.kind
  of nwrRecentFolder:
    w.vm.loadRecentFolder(r.key)
  of nwrRecentTrace:
    w.vm.loadRecentTrace(r.key)
  of nwrOption:
    if not r.enabled:
      w.message = r.label & ": " & r.detail
      return
    let kind = startOptionKindForKey(r.key)
    if kind.isNone:
      return
    case kind.get
    of wsoOpenFolder: w.openForm(nwfOpenFolder, folderDefault)
    of wsoOpenLocalTrace: w.openForm(nwfOpenTrace)
    of wsoRecordNewTrace: w.openForm(nwfRecord)
    else: w.message = r.label & ": " & StartOptionUnavailableHereReason

proc splitCommandLine*(text: string): seq[string] =
  ## `prog "an arg" b` -> @["prog", "an arg", "b"]: whitespace separates,
  ## double quotes group.
  var cur = ""
  var inQuote = false
  var started = false
  for c in text:
    if c == '"':
      inQuote = not inQuote
      started = true
    elif c in Whitespace and not inQuote:
      if started:
        result.add cur
        cur = ""
        started = false
    else:
      cur.add c
      started = true
  if started:
    result.add cur

proc submit*(w: NativeWelcome) =
  ## Enter in a form: the VM's own action for it, whose host callback
  ## records the intent. An empty field is refused by name.
  let text = if w.input.strip.len > 0: w.input.strip else: w.placeholder
  case w.form
  of nwfNone:
    discard
  of nwfOpenFolder:
    if text.len == 0:
      w.message = "Type the folder to open."
      return
    w.vm.loadRecentFolder(text)
    w.form = nwfNone
  of nwfOpenTrace:
    if text.len == 0:
      w.message = "Type the recording's folder."
      return
    w.vm.loadRecentTrace(text)
    w.form = nwfNone
  of nwfRecord:
    let words = splitCommandLine(text)
    if words.len == 0:
      w.message = "Type the program to record."
      return
    w.vm.setRecordExecutable(words[0])
    w.vm.setRecordArgs(if words.len > 1: words[1 .. ^1] else: @[])
    if not w.vm.submitNewRecord():
      w.message = "The program to record is required."
      return
    w.form = nwfNone
    w.message = "recording " & words.join(" ") & " …"

proc moveFocus*(w: NativeWelcome; delta: int) =
  let n = w.rowsOf().len
  if n == 0:
    return
  w.focus = (w.focus + delta + n) mod n

proc applyKey*(w: NativeWelcome; key: string; folderDefault = ""): bool =
  ## One key, by its canonical name (`Up`, `Enter`, `Esc`, `Backspace`, a
  ## printable character). True when the screen consumed it.
  if w.form != nwfNone:
    case key
    of "Esc": w.closeForm()
    of "Enter": w.submit()
    of "Backspace":
      if w.input.len > 0:
        w.input.setLen(w.input.len - 1)
    else:
      if key.len == 1 and key[0] >= ' ':
        w.input.add key
      elif key == "Space":
        w.input.add ' '
      else:
        return false
    return true
  case key
  of "Up", "Shift+Tab", "Left": w.moveFocus(-1)
  of "Down", "Tab", "Right": w.moveFocus(1)
  of "Enter", "Space": w.activate(w.focus, folderDefault)
  else: return false
  true
