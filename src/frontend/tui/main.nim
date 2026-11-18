## main.nim — the CodeTracer TUI entrypoint. Wires `host/` to `app/`, and
## nothing else.
##
## ## The shape, and why it is this shape
##
## `src/frontend/tui/` is two layers with one line between them:
##
##   app/    SDK-CONSUMER. Imports `codetracer_embed` and `headless_app` only.
##           Owns views, layout projection, input and every pane.
##           `ci/test/sdk-facade-boundary.sh` covers this directory through the
##           `.sdk-consumer` marker it carries.
##   host/   NATIVE HOST. The only place allowed to reach
##           `backend/stdio_backend` and `viewmodel/headless_session` — process
##           spawning, pty, termios, signals. Explicitly outside the facade,
##           and the boundary script records that exemption by name rather than
##           inferring it from the absence of a marker.
##
## This module is the wiring, so it is the one place both sides are in scope at
## once. It stays small on purpose: everything it does is decide, print or
## exit, and each of those is a host act. The moment a decision here needs
## state it belongs in `app/`, and the moment it needs a file descriptor it
## belongs in `host/`.
##
## ## CTUI-11: THIS IS THE MILESTONE THAT MADE THE BINARY RUN
##
## Until now every pane in this front-end was exercised only through the
## in-process harness and the snapshot apps: `main.nim` parsed `--help`,
## `--version` and a trace path, and then reported — honestly, and by name —
## that opening a trace needed a terminal driver nobody had built. CTUI-11 built
## it (`host/terminal_driver.nim`), and this is the wiring.
##
## ## THE ORDER OF THE FIRST FRAME, WHICH IS THE MILESTONE'S OWN CONTRACT
##
## CTUI-11 requires that capabilities resolve BEFORE the first paint, and it
## puts a published gate on cold start with probing enabled. Both are properties
## of the sequence below, so the sequence is written out rather than left to be
## read out of the code:
##
##   1. parse `argv`                    — `app/cli.parseTuiCommand`, no I/O
##   2. negotiate the terminal          — `host/capabilities`, seven `getEnv`s
##                                        and one `isatty`, no child process
##   3. claim the tty                   — raw mode, alt screen, mouse
##   4. **paint frame 0**               — the shell, saying which trace is
##                                        being opened
##   5. spawn `replay-server`, DAP      — seconds, on a cold page cache
##   6. paint frame 1                   — the debugger
##
## Steps 1-4 are what "cold start" measures, and putting step 5 AFTER the first
## frame is not a trick to make a number look good: a user who typed a command
## should see their terminal change immediately, and a front-end that showed
## nothing until the engine had answered would be indistinguishable, for that
## whole second, from one that had hung. It is also what makes "resolved before
## first paint" observable rather than asserted — the driver cannot be
## constructed without a `TerminalCapabilities`, and the paint is a method on
## the driver.

import std/[os, strutils, tables, times]

from isonim_tui import caretSupportFor, caretBytes, TextCaret, CaretSupport,
  caretShapes, caretDrawn, ckBar, ckBlock

import ./app/cli
# `./app/edit_binding` IS DELIBERATELY NOT IMPORTED. It was, until the landing
# pass moved "open the first file and fill the tree" out of `editInteractive`
# and into `runtime.ensureEditWorkspace` — which is where it belongs, because
# the toggle out of a REPLAY session needs the same behaviour and a second copy
# here is §14's duplicated predicate in the one file no suite compiles. With
# the last call gone the import is unused, and an unused import is a warning on
# every build of the product.
import ./app/edit_binding   # PLAT-43: `EditSession.selectModel`
import ./app/runtime
import ./app/clipboard_read
import ./app/tui_app
import ./host/build_runner
import ./host/capabilities
import ./host/edit_host
import ./host/headless
import ./host/highlight_worker
import ./host/file_worker
import ./host/key_journal
import ./host/layout_store
import ./host/native_host
import ./app/views/low_level_code_pane   # PLAT-60: `LowLevelAct`
import ./host/pane_server
from ../viewmodel/host/find_in_files import running   # PLAT-57
from ../viewmodel/host/native_file_tree import wireNativeFileOperations,
  FilesystemVM, FileTreeOperationResult # K19
import ./host/terminal_driver
import ./host/terminal_probe
import ./app/theme/terminal_report
import ./app/theme/terminal_settings
import ./app/theme/degradation
import ./app/theme/colour_math
import ./host/tui_session
import ./host/vcs_source
import ./host/test_results_source   # PLAT-53
import ./host/problems_source       # PLAT-55
import ./host/edit_search           # Find in Files over the project in Edit mode
from ../viewmodel/viewmodels/test_results_vm import TraceOpenPolicy,
  TestTabPlacement, TestTabPlacementKind, placeTestRecording, testTabOf,
  noteTestTab, forgetTestTab   # Test-Results-Pane.md §9
import ./host/build_output_source   # PLAT-56
from ../viewmodel/host/native_requests_host import wireRequests   # PLAT-58
import ./app/views/requests_pane   # PLAT-58: `RequestsAct`
# PLAT-49 part B: the session strip's sessions — opened, adopted, closed here.
import headless_app/headless_app
import headless_app/session_tabs
import headless_app/welcome_tabs
import ./app/views/welcome_view
import ../viewmodel/host/native_agent_host   # PLAT-54: Agent Activity's host
import ../viewmodel/viewmodels/trace_open   # PLAT-54: a test recording the agent pane opens
import ../viewmodel/host/native_state
from ../viewmodel/viewmodels/omnibar_vm import OmnibarEntry, OmnibarMode
from backend/stdio_backend import toBackendService
from ./app/views/file_tree import FileTreeModel
import ./host/control_icons
import ./host/image_probe
import ./app/theme/palette
import ../viewmodel/host/keymap_preference
import ../viewmodel/host/keybindings_file
import ../viewmodel/keymap/keymap_router

const ShippedDesktopConfig = staticRead("../../config/default_config.yaml")
  ## The desktop's shipped configuration: what a user's edited YAML
  ## `bindings:` block is compared with when it is imported once into
  ## `keybindings.json` (Base-Keymaps-And-Layer-Stack.md §3.5).
import ../viewmodel/host/icons_preference
import ../viewmodel/host/layout_preferences
import ../viewmodel/host/table_column_widths
from codetracer_embed import withColumnWidths, ColumnWidthEntry

const
  IdlePollMs = 200
    ## How long the loop blocks when nothing is happening.
    ##
    ## A CEILING ON LATENCY FOR NOTHING, and it is not a poll interval: input
    ## and SIGWINCH both wake the `select` immediately, so this only bounds how
    ## long the process sleeps between two events it does not have. It exists so
    ## a partially framed escape sequence — an `ESC` with nothing after it — is
    ## not held forever.

const SearchPollMs = 10
  ## PLAT-57: how long the loop may block while a Find in Files search
  ## streams, so its batches reach the pane as they arrive.

proc idleWaitMs(rt: TuiRuntime): int =
  ## How long the loop may block: `IdlePollMs`, or less when the auto-hide
  ## hover has a preview or a dismissal due sooner (PLAT-49 part B) — so a
  ## preview opens when its delay is up, not up to `IdlePollMs` later — while
  ## a search streams (PLAT-57), or while a scrollbar fades (PLAT-70 Part H).
  if nativeFindInFiles.running:
    return SearchPollMs
  # PLAT-70 Part B: a truncated cell's tooltip is due too (500 ms of rest).
  var due = rt.autoHideDueMs()
  let hover = rt.cellHoverDueMs()
  if hover >= 0 and (due < 0 or hover < due):
    due = hover
  # PLAT-70 Part H: a fading scrollbar (a frame every `FadeFrameMs`), a held
  # paging press, or the moment a resting bar starts fading out.
  let bars = rt.scrollbarDueMs()
  if bars >= 0 and (due < 0 or bars < due):
    due = bars
  # PLAT-68 (§3.7): a pending chord prefix ends at its base's timeout.
  let prefix = rt.pendingPrefixDueMs()
  if prefix >= 0 and (due < 0 or prefix + 1 < due):
    due = prefix + 1
  if due < 0:
    return IdlePollMs
  clamp(int(due - nowMs()), 1, IdlePollMs)

type
  EditHostState = ref object
    ## The one piece of Edit-mode state a LOOP owns rather than `app/`: the
    ## process behind `:build` / `:run`.
    ##
    ## A `ref` AND NOT A `var` LOCAL, because `startBuild`'s closure has to
    ## write it and Nim does not let a closure capture a `var` parameter. It is
    ## also what lets `wireEditServices` be one function called from two loops
    ## instead of two copies of the same five closures — §14's construction
    ## rule, and the copy that would have been forgotten is the entrypoint's,
    ## because no suite compiles this module.
    running: RunningBuild

proc wireEditServices(rt: TuiRuntime; root: string; keymapFlag: string;
                      listFiles: proc(): EditListResult): EditHostState =
  ## Hand `rt` the four capabilities `app/` may not have: read a file, write a
  ## file, list the project, start a process.
  ##
  ## **BOTH LOOPS CALL THIS**, and that is the whole reason it exists as a
  ## function. `ct edit --ui=tui` obviously needs them; `ct replay --ui=tui`
  ## needs them too, because `Ctrl+F5` reaches Edit mode from a replay session
  ## and CodeTracer-TUI-Edit-Mode.md §6 says it must: *"the toggle moves
  ## between them within one session, as on the desktop."* Until PLAT-16's
  ## landing pass the replay loop wired none of them, so that toggle arrived at
  ## an editor with no reader — and §2.1's stale-trace notice, which needs a
  ## recording AND an edit at the same time, had no route in the product on
  ## which it could fire at all.
  ##
  ## `listFiles` is the parameter because it is the one that differs: see
  ## `runtime.EditServices.listFiles` for why one loop can walk the project
  ## before it claims the terminal and the other must not walk it at all until
  ## asked.
  let state = EditHostState()
  # PLAT-51: THE ROOT IS READ AT EACH CALL — a welcome tab's "Open folder"
  # re-roots the session's Edit mode (`app.projectRoot`), and every service
  # follows it.
  proc rootOf(): string =
    if rt.app.projectRoot.len > 0: rt.app.projectRoot else: root
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(rootOf(), relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
    try:
      writeProjectFile(rootOf(), relative, text)
      EditWriteResult(ok: true)
    except TuiHostError as e:
      EditWriteResult(ok: false, message: e.msg)
  rt.editServices.readConfig = proc(spelled: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readUserConfigFile(rootOf(), spelled))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.listFiles = listFiles
  # K19: Edit mode's Files menu acts on the disk here, in-process, by the
  # index process's rules (`native_file_tree`).
  rt.editServices.wireFileTree = proc(vm: FilesystemVM;
                                      openedFolder: proc(): string;
                                      done: proc(r: FileTreeOperationResult)) =
    wireNativeFileOperations(vm, openedFolder, done)
  # PLAT-43. The keymap model this session starts under is the one the user
  # last chose, read through the same `selectKeymap` a typed `:keymap` goes
  # through. A stored value that is not a model is REFUSED BY NAME on the
  # status line and the session runs the product default — never a silent
  # fallback a user cannot tell from a working preference.
  #
  # PLAT-68: precedence is the `--keymap` flag (this session only, never
  # stored), then the stored preference, then `cua` (Base-Keymaps §3.6). A
  # stored `default` — PLAT-43's name for the product default — is read as
  # `cua` and rewritten, and the notice says so once.
  let keymapPreference = sessionKeymap(keymapFlag)
  rt.selectBase(keymapPreference.model,
                case keymapPreference.reason
                of "flag": ksFlag
                of "stored": ksStored
                else: ksDefault)
  if keymapPreference.status in {kplRefused, kplMigrated}:
    rt.keymapNotice = keymapPreference.message
    rt.app.notification = keymapPreference.message
  rt.editServices.saveKeymap = proc(model: BaseKeymap): string =
    saveKeymapPreference(model)
  rt.editServices.startBuild = proc(kind: BuildKind;
                                    cmd: string): BuildStartResult =
    state.running = startBuild(kind, cmd, rootOf(), nowMonoMs())
    rt.app.build = state.running.session
    if state.running.session.verdict == bvRunning:
      BuildStartResult(ok: true, message: $kind & " started: " & cmd)
    else:
      BuildStartResult(ok: false, message: describeVerdict(state.running.session))
  # Build-Output-Pane.md §3.6: a build TASK — its command in its own working
  # directory, named, read by its problem matcher.
  rt.editServices.projectDir = proc(): string = rootOf()
  rt.editServices.startTask = proc(cmd, dir, task,
                                   matcher: string): BuildStartResult =
    state.running = startBuild(bkBuild, cmd, (if dir.len > 0: dir
                                              else: rootOf()), nowMonoMs())
    state.running.session.taskName = task
    state.running.session.problemMatcher = matcher
    rt.app.build = state.running.session
    if state.running.session.verdict == bvRunning:
      BuildStartResult(ok: true, message: "")
    else:
      BuildStartResult(ok: false, message: describeVerdict(state.running.session))
  state

proc wireKeybindings(rt: TuiRuntime): ref KeybindingsLoad =
  ## PLAT-68: THE ONE USER KEYMAP (Base-Keymaps-And-Layer-Stack.md §3.5) —
  ## `keybindings.json`, the file GPUI and the desktop read too. On the first
  ## run an existing `.cttui-keys` or an edited desktop YAML `bindings:`
  ## block is translated into it once (`importOldConfigsOnce`); the file is
  ## then laid over the base, and `:keys reload` re-reads it. The status line
  ## says what loaded when anything did not, or when an import ran.
  result = new KeybindingsLoad
  let imported = importOldConfigsOnce(defaultOldConfigs(ShippedDesktopConfig))
  result[] = readKeybindings()
  var notes = imported
  if result.readError.len > 0:
    notes.add result.readError
  else:
    let summary = rt.applyUserKeymap(result.keymap)
    if rt.router.errors.len > 0: notes.add summary
  if notes.len > 0:
    rt.app.notification = notes.join("; ")
  let held = result
  rt.editServices.reloadKeybindings = proc(): string =
    held[] = readKeybindings(held.path)
    if held.readError.len > 0: held.readError
    else: rt.applyUserKeymap(held.keymap)
  rt.refreshMenuForKeymap()

proc pollKeybindings(rt: TuiRuntime; held: ref KeybindingsLoad): bool =
  ## Between frames: the file changed on disk — read it and lay it over the
  ## base again. A file that cannot be read keeps the rows that loaded last.
  if held.isNil or not held[].changedSince:
    return false
  let fresh = readKeybindings(held.path)
  if fresh.readError.len > 0:
    rt.app.notification = fresh.readError
  else:
    held[] = fresh
    rt.app.notification = rt.applyUserKeymap(fresh.keymap)
    rt.refreshMenuForKeymap()
  true

proc wireTopBar(rt: TuiRuntime) =
  ## PLAT-48: the top bar's host half, for both loops.
  ##
  ##   * the menu is enabled for what this front-end performs and shows the
  ##     ACTIVE keymap's chords (`runtime.refreshMenuForKeymap`);
  ##   * the `icons` setting the user chose last time is read back; a stored
  ##     value that is not a mode is refused by name on the status line;
  ##   * `:icons` writes it through `saveIconsPreference`;
  ##   * when nothing was chosen and the environment says Nerd Fonts are in
  ##     use, the status line SUGGESTS `nerd` — a font cannot be measured
  ##     from a terminal, so it is never switched on for the user.
  rt.refreshMenuForKeymap()
  let stored = loadIconsPreference()
  case stored.status
  of iplLoaded:
    rt.app.icons = stored.mode
    rt.app.iconsChosen = true
  of iplRefused:
    rt.app.notification = stored.message
  of iplAbsent:
    rt.app.icons = defaultIconsMode(graphicsDrawn = false)
    if nerdFontHint(getEnv("NERD_FONT", getEnv("NERDFONT", "")),
                    getEnv("TERM_PROGRAM", ""), getEnv("KITTY_FONT", "")):
      rt.app.notification = NerdSuggestion
  rt.saveIcons = proc(mode: IconsMode): string = saveIconsPreference(mode)

proc wireLayoutPreferences(rt: TuiRuntime;
                           flags: array[LayoutSetting, string]) =
  ## PLAT-51 deliverables 9 and 11, PLAT-70 Part H: the remembered layout
  ## settings (`host/layout_preferences`, beside the remembered layout) and
  ## then this session's flags (each a value word, "" when absent), which
  ## beat them; `:set` remembers a new choice through `savePreference`. A
  ## stored value that is not a setting is refused by name on the status
  ## line, and the defaults stay.
  let product: LayoutProduct = lpTerminal
  let stored = loadLayoutPreferences(product)
  var settings = stored.settings
  if stored.status == lpsRefused:
    rt.app.notification = stored.message
  for which in LayoutSetting:
    settings.applyOverride(which, flags[which])
  for which in LayoutSetting:
    # PLAT-71: the terminal settings are NOT applied here — they are ranks
    # of the capability profile, read by the negotiation (the remembered
    # ones as ranks 4–5, the flags as rank 2) — so a remembered value is
    # never mistaken for this session's `:set`.
    if which.isTerminalSetting:
      continue
    discard rt.applyLayoutSetting(which, settings.valueText(which),
                                  remember = false)
  rt.savePreference = proc(name, value: string): string =
    let (known, which) = parseSettingName(name)
    if not known: "unknown setting " & name
    else: saveLayoutPreference(product, which, value)

proc wireColumnWidths(rt: TuiRuntime) =
  ## PLAT-70 Part B (Horizontal-Overflow.md §5.2): the column widths every
  ## front-end remembers (`host/table_column_widths`), read at start-up into
  ## the Event Log's model, and written whenever one changes here. A stored
  ## document that is not widths is refused by name on the status line.
  let stored = loadColumnWidths()
  if stored.message.len > 0:
    rt.app.notification = stored.message
  rt.app.eventLog.columns =
    rt.app.eventLog.columns.withColumnWidths(stored.entries)
  rt.saveColumnWidths = proc(table: string;
                             entries: seq[ColumnWidthEntry]): string =
    saveColumnWidths(table, entries)

proc adoptMouseMetrics(driver: TerminalDriver; n: StartupNegotiation) =
  ## PLAT-51 (Layout-ViewModel §4.2.2): what the start-up round said about
  ## the pointer — SGR-pixel reports (DECSET 1016) on a terminal that
  ## recognises the mode and said its cell size, else cells mapped to their
  ## centres through that size (or the desktop's) — installed for every
  ## decode, and 1016 switched on when it applies. Re-run on a late reply.
  let m = mouseMetricsOf(n.probe, n.caps.mouse)
  setMouseMetrics(m)
  if m.pixels:
    driver.enablePixelMouse()

var gIconState: ControlIconState
  ## What the terminal already holds of the controls' pictures (one terminal
  ## per process).

type GraphicsProbeState = object
  ## PLAT-48: the kitty graphics query sent after the first frame, so the
  ## `icons` default can be `graphics` on a terminal that draws pictures —
  ## measured, never assumed from `$TERM`. Sent AFTER frame 0 rather than in
  ## the start-up round, so the cold-start gate pays nothing for it.
  open: bool
  deadlineMs: int64

const GraphicsProbeWaitMs = 500'i64

proc startGraphicsProbe(driver: TerminalDriver; rt: TuiRuntime):
    GraphicsProbeState =
  ## Ask, unless a multiplexer is in the path (tmux or screen would need a
  ## passthrough this probe does not negotiate; `image_capability` refuses
  ## tier 0 there too) or the user already chose a mode that is not
  ## `graphics`.
  let env = readImageEnv()
  if env.tmux.len > 0 or env.sty.len > 0:
    return
  if rt.app.iconsChosen and rt.app.icons != imGraphics:
    return
  driver.expectReplies(true)
  writeAll(driver.outFd, ProbeQuery & ProbeFence)
  GraphicsProbeState(open: true, deadlineMs: nowMs() + GraphicsProbeWaitMs)

proc isGraphicsProbeReply(token: string): bool =
  token.startsWith("\x1b_Gi=" & $ProbeImageId & ";")

proc startHighlights(rt: TuiRuntime; driver: TerminalDriver): HighlightWorker =
  ## PLAT-29. The Edit pane's parse moves onto a worker thread: the runtime
  ## hands it requests, the driver wakes on its pipe, and `drainHighlights`
  ## installs the answers. Both loops call this, so neither parses on the
  ## render path.
  result = startHighlightWorker()
  let worker = result
  driver.auxWakeFd = worker.wakeRead
  rt.editServices.requestHighlight = proc(req: HighlightRequest) =
    worker.submit(req)

proc startFiles(rt: TuiRuntime; root: string;
                highlights: HighlightWorker): FileWorker =
  ## PLAT-29. `:w` and `:e!` run on this worker and are reconciled when they
  ## answer (`app/file_io_producer`). It wakes the loop through the
  ## highlight worker's pipe.
  result = startFileWorker(root, highlights.wakeWriteFd)
  let worker = result
  rt.editServices.submitFileJob = proc(job: FileJob) =
    worker.submit(job)

proc drainHighlights(rt: TuiRuntime; worker: HighlightWorker;
                     files: FileWorker): bool =
  ## Every parse and every file answer that arrived, installed. Whether a
  ## frame should be drawn.
  for res in worker.drain():
    if rt.deliverHighlight(res):
      result = true
  for res in files.drain():
    if rt.deliverFileJob(res):
      result = true

proc advanceBuild(rt: TuiRuntime; state: EditHostState;
                  report: bool): bool =
  ## Advance a running build by one tick. Returns whether the screen changed.
  ##
  ## `report` is what tells the two call sites apart, and they are different on
  ## purpose: on an IDLE tick nothing else is competing for the status line, so
  ## a verdict goes there; right after a KEY the line belongs to whatever the
  ## key just said (`:cancel` says *"cancelling …"*), and overwriting it would
  ## take the user's own answer away from them one tick later.
  ##
  ## `pollBuild` does not block — `host/build_runner.nim`'s header carries the
  ## measurement that says so, and the suite that keeps it true is
  ## `tests/test_build_runner_process.nim`.
  if state.isNil or state.running.isNil:
    return false
  result = pollBuild(state.running, nowMonoMs())
  if result and report:
    rt.app.notification = describeVerdict(state.running.session)

var gCaretSupport = caretShapes
  ## PLAT-49: whether the running terminal shapes its cursor (`interactive`
  ## decides it once, from `TERM` / `TERM_PROGRAM` / `TMUX`).

proc paint(driver: TerminalDriver; rt: TuiRuntime) =
  ## One frame of `rt` onto `driver`.
  ##
  ## The cursor is CTUI-9's: `modal_state.cursorControlBytes` says what shape
  ## and visibility the current mode has, and it goes in the PROLOGUE because it
  ## does not move the cursor. §3.3.6's prompt DOES move it, so it goes in the
  ## epilogue — `docs/tui-testing.md` records why those two are different hooks
  ## and what it costs a reader of the frame barrier.
  let screen = rt.shellScreenOf()
  var epilogue = ""
  # PLAT-48: the debugger controls as the desktop's marks, placed over the
  # cells the top bar reserved — only on a terminal measured to draw them.
  let mode = rt.caps.mode
  epilogue.add controlIconBytes(gIconState, screen.topBarLayout,
                                rt.app.controlsEnabledOf(),
                                RoleColourTable[mode][srChromeText].fgRgb,
                                RoleColourTable[mode][srChromeMuted].fgRgb)
  let (prompting, row, col) = rt.promptCursor()
  if prompting:
    epilogue.add "\x1b[" & $(row + 1) & ";" & $(col + 1) & "H" &
                 ShowCursorBytes
  # PLAT-49: AN OPEN OMNIBAR OWNS THE CARET. The terminal's cursor goes where
  # its text goes — a thin bar while inserting, a block while overwriting
  # (DECSCUSR) — after the modal prologue, so it wins over the mode's shape;
  # where the terminal is not known to shape its cursor, the top bar has
  # already drawn the caret into its cell and the cursor stays hidden.
  let caret = screen.topBar.omnibarCaret(screen.topBarLayout)
  if caret.shown and not prompting:
    epilogue.add caretBytes(
      TextCaret(row: caret.row, col: caret.col, visible: true,
                shape: (if caret.overwrite: ckBlock else: ckBar)),
      gCaretSupport)
  # PLAT-51: A WELCOME TAB'S FORM owns the caret when it is open (the
  # omnibar's and the prompt's win, being over it).
  if not prompting and not caret.shown:
    let wv = rt.app.welcomeViewOf()
    if wv.shown:
      let wc = welcomeCursor(wv, screen.welcomeLayout)
      if wc.on:
        epilogue.add caretBytes(
          TextCaret(row: wc.row, col: wc.col, visible: true, shape: ckBar),
          gCaretSupport)
  # PLAT-50: TEXT A CLICK COPIED (the editor menu's Copy) goes to the
  # terminal's clipboard — OSC 52 (`ESC ] 52 ; c ; <base64> BEL`, xterm's
  # "Manipulate Selection Data",
  # https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands),
  # which a terminal that allows it forwards to the system clipboard — once.
  if rt.app.clipboard.len > 0:
    epilogue.add osc52Copy(rt.app.clipboard)
    rt.app.clipboard = ""
  # PLAT-68: A HELD PASTE ASKS THE TERMINAL FOR ITS CLIPBOARD — the OSC 52
  # read, written with this frame; the answer is a reply string the framer
  # delivers as one token (`takeClipboardReply`), or the wait runs out
  # (`clipboardReadDue`).
  if rt.clipboardRead.requested:
    epilogue.add ClipboardQuery
    rt.clipboardRead.requested = false
    rt.clipboardRead.open = true
    rt.clipboardRead.deadlineMs = nowMs() + ClipboardReadWaitMs
    driver.expectReplies(true)
  driver.paint(screen.styledRows,
               prologue = cursorControlBytes(rt.modal.mode),
               epilogue = epilogue,
               overlays = screen.frameOverlays)

proc takeClipboardReply(rt: TuiRuntime; driver: TerminalDriver;
                        token: string): bool =
  ## PLAT-68: the terminal's answer to the clipboard read — never a key,
  ## never journalled: the held paste runs with its text.
  if not isClipboardReply(token):
    return false
  let reply = decodeClipboardReply(token)
  discard rt.completePaste(reply.ok, reply.text, nowMs())
  paint(driver, rt)
  true

proc clipboardReadDue(rt: TuiRuntime; driver: TerminalDriver): bool =
  ## The clipboard read's wait ran out: the held paste runs with the
  ## internal clipboard, and the terminal is not asked again.
  if not rt.clipboardRead.open or nowMs() <= rt.clipboardRead.deadlineMs:
    return false
  discard rt.completePaste(false, "", nowMs())
  paint(driver, rt)
  true

proc themeSwitch(negotiation: StartupNegotiation; driver: TerminalDriver;
                 rt: TuiRuntime): proc(name: string): bool {.closure.} =
  ## §4.3's `:theme <dark|light>`: the interpreter has already validated the
  ## name against `ThemeNames`; this pins that design-system mode, re-resolves
  ## and hands the runtime the new capabilities. The loop's paint after the
  ## command is then a FULL frame (`adoptCapabilities` forgot the screen).
  result = proc(name: string): bool =
    let (known, theme) = parseTheme(name)
    if not known or theme == utPlain:
      return false
    discard negotiation.switchTheme(driver, theme)
    rt.adoptCaps(negotiation.caps)
    true

proc storedTerminalPrefs(): (LayoutPreferencesLoad, TerminalPrefs) =
  ## PLAT-71: the remembered terminal settings — global and per terminal —
  ## as ranks 4 and 5 of Terminal-Adaptation §5.2.
  let stored = loadLayoutPreferences(lpTerminal)
  (stored, prefsOf(stored.settings))

proc printCard(caps: TerminalCapabilities) =
  ## The glyph test card (§10.3) on stdout, in the terminal's own colours.
  for row in glyphTestCard(caps):
    var line = ""
    for span in row:
      let s = degradeStyle(span.style, caps)
      var sgr: seq[string] = @[]
      if s.bold: sgr.add "1"
      if s.italic: sgr.add "3"
      if s.underline: sgr.add "4"
      if s.reverse: sgr.add "7"
      proc colour(c: string; base: int): string =
        if c.len == 7 and c[0] == '#':
          try:
            return $(base + 8) & ";2;" & $fromHex[int](c[1 .. 2]) & ";" &
                   $fromHex[int](c[3 .. 4]) & ";" & $fromHex[int](c[5 .. 6])
          except ValueError: return ""
        if c.startsWith("indexed:"):
          return $(base + 8) & ";5;" & c["indexed:".len .. ^1]
        let i = AnsiNames.find(c)
        if i >= 0:
          return (if i < 8: $(base + i) else: $(base + 60 + i - 8))
        ""
      let fg = colour(s.fg, 30)
      let bg = colour(s.bg, 40)
      if fg.len > 0: sgr.add fg
      if bg.len > 0: sgr.add bg
      if sgr.len > 0:
        line.add "\e[" & sgr.join(";") & "m" & span.text & "\e[m"
      else:
        line.add span.text
    echo line

proc reportCapabilities(command: TuiCommand): int =
  ## PLAT-68: `--capabilities`. The negotiation a session runs — the
  ## environment, then the start-up query round on the claimed terminal — and
  ## its result printed after the terminal is given back.
  ##
  ## PLAT-71 (Terminal-Adaptation §10.1): the REPORT — every axis with the
  ## source that decided it (`terminal_report.profileReport`), or the same as
  ## JSON (`--capabilities=json`), and with `--card` (what `ct doctor
  ## terminal` passes) the glyph test card after it.
  let flags = command.flags
  let (_, prefs) = storedTerminalPrefs()
  let caps = resolveCapabilities(readTerminalEnv(), flags, prefs = prefs)
  var negotiated = caps
  if stdoutIsTerminal():
    let driver = newTerminalDriver(caps)
    driver.start()
    try:
      negotiated = driver.negotiateOnTerminal(flags, prefs).caps
    finally:
      driver.stop()
  if command.capabilitiesJson:
    echo pretty(profileJson(negotiated))
    return ExitOk
  for line in profileReport(negotiated):
    echo line
  echo "summary      " & describe(negotiated)
  if command.capabilitiesCard:
    echo ""
    printCard(negotiated)
  ExitOk

proc wireTerminalService(rt: TuiRuntime; n: StartupNegotiation;
                         driver: TerminalDriver) =
  ## PLAT-71: the host's half of the terminal settings (`TerminalService`):
  ## a `:set` of one re-resolves the profile at rank 1 and the screen is
  ## repainted from it; the test card's `y` / `n` remembers `modern-unicode`
  ## for THIS terminal; `r` asks again; `dismiss` turns the hint off for good.
  rt.terminalService = TerminalService(
    setChoice: proc(which: LayoutSetting; value: string): string =
      if which == lsTerminalHints:
        return describe(which, value)
      var c = TerminalChoices()
      if not choicesOf(which, value, c):
        return "'" & value & "' is not a value of " & $which
      if which in {lsGlyphs, lsAmbiguousWidth, lsColors, lsReduceMotion} and
         value == "auto":
        # `auto` at rank 1 SAYS NOTHING: drop an earlier `:set` of this axis.
        case which
        of lsGlyphs: n.session.glyphs = none(GlyphsChoice)
        of lsAmbiguousWidth: n.session.ambiguousWidth = none(AmbiguousChoice)
        of lsColors: n.session.colors = none(ColorsChoice)
        else: n.session.reduceMotion = none(bool)
      discard n.setSessionChoice(driver, c)
      rt.adoptCaps(n.caps)
      let caps = n.caps
      result = describe(which, value) & " -> " &
        (case which
         of lsModernUnicode: "modern-unicode " &
           (if caps.modernUnicode: "on" else: "off") & " (" & caps.modernNote &
           ")"
         of lsGlyphs: "glyphs " & $caps.tier
         of lsAmbiguousWidth: "ambiguous " &
           (if caps.ambiguousWide: "wide" else: "narrow")
         of lsColors: "colours " & $caps.colors
         of lsReduceMotion: "motion " &
           (if caps.reduceMotion: "reduced" else: "animated")
         else: "applied"),
    setForThisTerminal: proc(which: LayoutSetting; value: string): string =
      let name = n.caps.identity.name
      if name.len == 0:
        return "this terminal did not identify itself; use :set " & $which &
               " " & value & " for every terminal"
      let failure = saveScopedPreference(lpTerminal, name, which, value)
      if failure.len > 0:
        return failure
      let (_, prefs) = storedTerminalPrefs()
      discard n.setPrefs(driver, prefs)
      rt.adoptCaps(n.caps)
      $which & " " & value & " for " & name & " (remembered in [terminal \"" &
        name & "\"])",
    rerun: proc(): string =
      n.restartProbe(driver)
      "asking the terminal again",
    dismissHints: proc(): string =
      let failure = saveLayoutPreference(lpTerminal, lsTerminalHints, "off")
      if failure.len > 0: failure
      else: "terminal hints dismissed (terminal-hints off)")

proc interactive(command: TuiCommand): int =
  ## Open a trace and run the loop until the user quits or the terminal goes
  ## away. Returns the process's exit status; nothing here calls `quit`.
  let caps = negotiateCapabilities(command.flags)
  if not stdoutIsTerminal():
    stderr.writeLine(TuiProgramName & ": standard output is not a terminal," &
                     " so there is nothing to draw on.")
    stderr.writeLine("  negotiated: " & describe(caps))
    # THE MESSAGE NAMES A FLAG THAT EXISTS. It used to end "wait for --serve
    # (CTUI-13) and --headless (CTUI-12)", which named a milestone that had
    # already landed and one that never owned the flag; --serve was later cut
    # outright, because `ct host` already serves a trace to a browser together
    # with the replay front end.
    stderr.writeLine("  run it in a terminal, or use --headless for one" &
                     " plain-text screen.")
    stderr.writeLine("  to replay it in a browser, use `ct host` instead.")
    return ExitNoTerminal

  let folder = resolveTraceFolder(command.tracePath)
  # BEFORE THE TERMINAL IS CLAIMED, and that order is the whole point. CTUI-11
  # measured what the other order costs: pointed at a directory that is not a
  # recording, the binary claimed the alternate screen, painted "opening …",
  # and then hung inside the DAP handshake — `replay-server` exits 2 on a folder
  # it cannot open and writes no DAP at all. The input loop had not started, so
  # no key could end it. Both checks below are `stat`s and both refuse on the
  # ORDINARY screen.
  let problem = traceFolderProblem(folder)
  if problem.len > 0:
    stderr.writeLine(TuiProgramName & ": " & folder & ": " & problem)
    return ExitUsage
  let replayServer = findReplayServer()
  if replayServer.len == 0:
    stderr.writeLine(TuiProgramName & ": " & replayServerRemedy())
    return ExitUsage

  # THE KEY JOURNAL IS OPENED BEFORE THE TTY, for the reason the two `stat`s
  # above are done before it: a missing `--replay-keys` file and an unwritable
  # `--record-keys` path are both diagnoses a user can act on, and a diagnosis
  # printed onto a claimed alternate screen is a diagnosis nobody reads.
  var journal: KeyJournal = nil
  try:
    journal = openKeyJournal(command.recordKeys, command.replayKeys)
  except TuiHostError as e:
    stderr.writeLine(TuiProgramName & ": " & e.msg)
    return ExitUsage
  defer: journal.close()

  let driver = newTerminalDriver(caps)
  driver.start()
  # FROM HERE THE TERMINAL IS OURS AND MUST BE GIVEN BACK ON EVERY PATH,
  # including an exception. `nim-termctl`'s signal handlers and `atexit` hook
  # cover a kill and a crash; this covers a normal return and a raise.
  defer: driver.stop()
  # PLAT-46: THE ONE START-UP QUERY ROUND — the terminal's real background
  # (OSC 11) and whether it keeps 24-bit colour (DECRQSS / XTGETTCAP, tmux's
  # `RGB`) — in raw mode, before frame 0, bounded by one short wait. Late
  # replies are taken by the loop below.
  let (storedPrefs, terminalPrefs) = storedTerminalPrefs()
  let negotiation = driver.negotiateOnTerminal(command.flags, terminalPrefs)
  adoptMouseMetrics(driver, negotiation)
  let hintsOn = storedPrefs.settings.terminal.terminalHints != "off"

  var size = driver.size()
  let app = newTuiApp()
  # PLAT-49: whether this terminal shapes its cursor (DECSCUSR) — decided
  # from its own identity; where it is not known to, the omnibar's caret is
  # drawn into its cell instead (`isonim_tui.caretSupportFor`).
  gCaretSupport = caretSupportFor(getEnv("TERM"), getEnv("TERM_PROGRAM"),
                                  inTmux = getEnv("TMUX").len > 0)
  app.caretDrawn = gCaretSupport == caretDrawn
  # The negotiation's note FIRST: the status line clips a long notification
  # from the right, and a trace folder's path is long.
  app.notification = capabilityNote(negotiation.caps, hintsOn) &
                     " | opening " & folder & " …"
  # PLAT-16: THE PROJECT A REPLAY SESSION EDITS IS THE WORKING DIRECTORY, and
  # that is a decision rather than a fallback, so it is written down here.
  #
  # `Ctrl+F5` reaches Edit mode from this loop (CodeTracer-TUI-Edit-Mode.md §6),
  # which means this loop has to answer "edit WHAT". Three candidates, and only
  # one of them is a fact this front-end has:
  #
  #   * the recording's own source tree — the ideal answer, and unavailable:
  #     a trace carries per-file payloads with their recorded paths, not a
  #     checkout root, and `host/tui_session.nim` reads no trace metadata at
  #     all. Inferring a root from `getCurrentFile()`'s directory would be a
  #     guess presented as knowledge, and the containment check in
  #     `host/edit_host.nim` would then be a check about a guess.
  #   * a `--project` flag — a new published option for a question most users
  #     never ask, on a command line §6.2 already fills.
  #   * the working directory — where the user typed the command, which for
  #     `ct replay` is overwhelmingly the checkout the recording came from.
  #
  # It is NOT silent: the first `Ctrl+F5` puts `editing <root> — N file(s)` on
  # the status line (`runtime.ensureEditWorkspace`), so a user who was
  # somewhere else sees the root they actually got rather than discovering it
  # from a file tree that looks wrong.
  #
  # NOTHING IS WALKED HERE. `listProjectFiles` runs inside the closure below,
  # on the first switch only — a filesystem walk on every `ct replay` would sit
  # inside CTUI-11's cold-start budget for a mode most sessions never enter.
  let projectRoot = getCurrentDir()
  app.projectRoot = projectRoot
  let rt = newTuiRuntime(app, negotiation.caps, size.cols, size.rows)
  # Opening a replay gives its editor the keyboard. Seed this before the
  # layout binding copies the focus; restoring a saved layout then keeps it
  # only while the editor is visible. Empty shells keep projection order.
  discard rt.focus.focusPaneKind(paneEditor)
  rt.eraseByte = driver.eraseByte()
  rt.themeService = themeSwitch(negotiation, driver, rt)
  wireTerminalService(rt, negotiation, driver)
  let edit = wireEditServices(rt, projectRoot, command.keymap,
                              proc(): EditListResult =
    let listing = listProjectFiles(rt.app.projectRoot)
    EditListResult(files: listing.files, truncated: listing.truncated))
  wireTopBar(rt)
  let keybindings = wireKeybindings(rt)
  # PLAT-29: the Edit pane's parse runs on this worker, never on the render
  # path; stopped when the loop that owns it returns.
  let highlights = startHighlights(rt, driver)
  defer: highlights.stop()
  # Declared AFTER the highlight worker, so it is stopped FIRST (defers run in
  # reverse) — its pending writes finish while the shared wake pipe is open.
  var files = startFiles(rt, projectRoot, highlights)
  defer: files.stop()
  # PLAT-45: THE LAYOUT IS THE USER'S BY DEFAULT, AND IT IS REMEMBERED.
  #
  # Until PLAT-45 this was PLAT-6's opt-in: only `--layout-binding` gave the
  # terminal a rearrangeable layout, and only then was it saved — per
  # recording. PLAT-45 deliverable 8 flips both: every session starts on the
  # shared default (or on the arrangement the user last left the TERMINAL in),
  # the `:` layout verbs and the mouse can rearrange it, and every committed
  # change is written through to ONE document for the terminal product under
  # the user's state directory (`host/layout_store.layoutDocumentPath`). The
  # desktop and the GPUI window keep files of their own and never read this
  # one. `--layout-binding` is still accepted, and asks for what is now the
  # default. What made PLAT-6 keep this an opt-in — the session slot holding a
  # bare tree — is gone since PLAT-4's closing pass, and a committed gesture is
  # now written back onto the slot (`runtime.afterLayoutCommit`).
  #
  # The binding is enabled before the first frame, seeded from the arrangement
  # this session would have painted anyway, so frame 0 is unchanged by it.
  discard rt.enableLayoutBinding()
  wireLayoutPreferences(rt, command.layoutFlags)
  wireColumnWidths(rt)
  rt.layoutCommitted = proc(rt: TuiRuntime) =
    # WRITE-THROUGH, so a crash loses nothing. A failure is the user's to
    # know about, on the status line, and is not fatal: the arrangement is
    # still on screen and the exit save below tries again.
    let saved = persistLayoutForSession(rt)
    if saved.outcome == lpoFailed:
      rt.app.notification = saved.message
  let layoutRestore = restoreLayoutForSession(rt)
  if layoutRestore.message.len > 0:
    app.notification = layoutRestore.message
  # FRAME 0, BEFORE THE ENGINE. See this module's header on why the order is
  # this way round.
  paint(driver, rt)

  # THE HANDSHAKE IS BOUNDED, AND IT IS ALSO INTERRUPTIBLE. CTUI-14.
  #
  # This is the point the front-end used to wedge at, and the reproduction is
  # in `backend/stdio_backend.nim`'s header: a folder with a garbage
  # `trace.bin` passes every `stat` above, `replay-server` answers the whole
  # handshake up to and including `launch` and then goes silent without ever
  # sending `stopped`, and the old blocking read never returned. The
  # alternate screen was already claimed, `cfmakeraw` had cleared `ISIG`, and
  # the loop below had not started — so `Ctrl+c` reached nothing and the user's
  # only recovery was a kill from another terminal.
  #
  # Both halves are installed here rather than one, because they answer
  # different users: the clock is for a session nobody is watching, and the
  # keyboard is for one somebody is. The fd is the DRIVER's, and
  # `absorbInterruptByte` queues whatever it takes, so nothing typed while the
  # trace opens is lost.
  let bound = DapReadBound(
    timeoutMs: handshakeBudgetMs(),
    interruptFd: driver.inFd,
    onInterrupt: proc(): bool = driver.absorbInterruptByte())

  var session: TuiSession = nil
  try:
    session = openTuiSession(folder, viewportHeight = max(1, size.rows - 6),
                             bound = bound)
  except DapInterruptedError:
    # THE USER ENDED IT, so this is not a failure. `driver.stop()` gives the
    # terminal back on the ordinary screen and the status is the one `q` and
    # `Ctrl+c` produce everywhere else in this program.
    driver.stop()
    stderr.writeLine(TuiProgramName & ": cancelled while opening " & folder)
    return ExitOk
  except DapLaunchRefusedError as e:
    # THE ENGINE ANSWERED, AND THE ANSWER REACHES THE USER. This arm sits
    # ABOVE the stalled one on purpose: before it existed, a recording
    # `replay-server` had explicitly refused — naming the container version it
    # found, the version it requires, and that re-recording is the remedy —
    # produced no response at all. The refusal arrived as a `ct/notification`
    # the handshake buffered, the wait for `stopped` ran out its budget, and
    # the user was told the engine had stopped answering. Before CTUI-14 put a
    # clock on that wait, they were told nothing and the panes simply stayed
    # empty for as long as they cared to look.
    #
    # The engine's sentence is printed VERBATIM and alone. Every fact a user
    # needs is already in it and a summary of it here would be a second
    # wording of the same thing, free to go stale against the reader that
    # produced it.
    driver.stop()
    stderr.writeLine(TuiProgramName & ": cannot open " & folder & ": " & e.msg)
    return ExitUnreadableRecording
  except EngineStalledAfterOpenError as e:
    # THE ENGINE READ THE RECORDING, then went quiet on the session's first
    # request. The same exit code as a stalled open, because it is the same
    # fact for a script, but NOT the open's remedy: re-recording a recording
    # the engine has read cannot help (§8b).
    driver.stop()
    for line in stalledAfterOpenReport(TuiProgramName, folder, e.msg):
      stderr.writeLine(line)
    return ExitEngineStalled
  except DapStalledError as e:
    # A DISTINCT EXIT CODE, because this is a distinct fact. `ExitUsage` would
    # send a user to look at their command line for a folder that named itself
    # correctly and then did not open.
    driver.stop()
    stderr.writeLine(TuiProgramName & ": " & folder &
                     ": the replay engine stopped answering (" & e.msg & ")")
    stderr.writeLine("  the folder has a recording's shape but the engine" &
                     " could not read it; re-record it, or run" &
                     " `replay-server dap-server --stdio` against it to see" &
                     " what it says.")
    return ExitEngineStalled
  except CatchableError as e:
    driver.stop()
    stderr.writeLine(TuiProgramName & ": could not open " & folder & ": " &
                     e.msg)
    return ExitUsage
  # PLAT-49 part B: EVERY SESSION THIS PROCESS OPENED, by its tab's id — the
  # one above and each a "+" opens — closed on the way out.
  var sessions = initTable[int, TuiSession]()
  defer:
    for s in sessions.values:
      s.close()
    if sessions.len == 0:
      session.close()
  # THE HATCH COMES OFF NOW. See `tui_session.disarmHandshakeInterrupt`: a read
  # abandoned mid-message cannot be resynchronised, which is the right trade
  # while the session is still being built and the wrong one afterwards.
  session.disarmHandshakeInterrupt()
  # Somebody is watching from here on: a sweep or a `continue` that is silent
  # for longer than the clock is a slow engine, not a stopped one (§8b).
  session.allowSlowOperations()
  session.header(rt)
  app.dividers = command.dividers
  # THE FIRST PANE LOADS, and the stall they can end on. `learnExtent` raises
  # an engine that answers none of them for a whole budget
  # (`EngineStalledAfterOpenError`) instead of costing one budget per request;
  # it is reported here as the open's stall is, in the after-open wording.
  try:
    if command.noFlowOverlay:
      session.setFlowOverlay(false)
    session.setViewportHeight(rt.sourcePaneRows())
    session.learnExtent()
    session.wireFindInFiles()
    # PLAT-58: a request whose execution is in another recording opens it in
    # a new session tab (`recordingOpener`, set below).
    wireRequests(session.session, proc(path: string): string =
      if app.recordingOpener.isNil: "this terminal cannot open " & path
      else: app.recordingOpener(path))
    session.refresh(rt)
  except DapStalledError as e:
    driver.stop()
    for line in stalledAfterOpenReport(TuiProgramName, folder, e.msg):
      stderr.writeLine(line)
    return ExitEngineStalled

  # PLAT-49 part B (finding 7): THE SESSION IS A TAB OF THE STRIP. It is put
  # into `HeadlessApp` (adopted, as GPUI's is: the engine is this host's), so
  # the strip and the header read it; a second recording opened from the
  # strip's "+" becomes the next tab, and a click on a tab — or its close
  # control — re-points the panes at that session (`showSession`).
  let firstSlot = app.shell.openSession(
    session.session.backend.toBackendService(),
    title = app.traceName, layout = app.layoutBinding.layout,
    adopt = session.session.sdk)
  sessions[int(firstSlot.id)] = session
  var shownId = firstSlot.id
  app.recordings = recordingsBeside(folder)

  var agentWiring: proc(s: TuiSession) = nil
    ## PLAT-54: wires a session's Agent Activity host to this terminal (set
    ## once the VCS pane exists, below).
  proc showSession(id: HeadlessSessionId) =
    ## Point the terminal at the session behind tab `id`: its header, its
    ## panes from its current stop, its files and its omnibar index. The
    ## arrangement is the terminal's one remembered layout (PLAT-45
    ## deliverable 8), the same in every tab — a new tab starts from it, as
    ## the desktop's new tab starts from the current one.
    if not sessions.hasKey(int(id)):
      return
    let fromEnded = not session.isNil and session.ended
    session = sessions[int(id)]
    shownId = id
    let slot = app.shell.activeSlot()
    if not slot.isNil:
      # The DEBUG arrangement, even when the tab is left in Edit mode: a
      # slot holds a replay arrangement (`runtime.debugArrangementOf`).
      slot.layout = rt.debugArrangementOf().clone()
    if session.ended:
      # M76: a tab whose session *Stop* ended is an edit tab: nothing of a
      # replay is shown in it, and its workspace is Edit mode.
      rt.forgetSession()
      rt.enterProductMode(pmEdit)
      app.notification = EndedSessionNote
      return
    if fromEnded:
      # Back from such a tab onto a live session: a replay is Debug mode.
      rt.enterProductMode(pmDebug)
    session.header(rt)
    if not agentWiring.isNil and session.agent.openRecording.isNil:
      agentWiring(session)
    session.refreshAgent(rt)            # PLAT-54: this session's agent
    app.fileTree = FileTreeModel()      # this session's files (`refresh`)
    session.setViewportHeight(rt.sourcePaneRows())
    session.refresh(rt)
    app.refreshOmnibarIndex()
    app.notification = describe(session)

  # M76: set by `welcomeHost` around the open it performs for the welcome tab
  # that stands in for a tab *Stop* ended (`TuiApp.stoppedTabWelcome`); only
  # then does `recordingOpener` start the session in the stopped tab.
  var openingInStoppedTab = false
  # Test-Results-Pane.md §9.5: set around the open a placement makes in
  # place — the tab whose session the recording REPLACES (rule 4, or the
  # current tab chosen by the setting or Ctrl): the new slot takes its place
  # in the strip and the old session's engine is closed, as for a stopped
  # tab. -1 for an ordinary open.
  var replaceTab = -1

  app.recordingOpener = proc(path: string): string =
    # The handshake is BOUNDED, as the first one is; no keyboard hatch: the
    # loop is running and owns the input.
    var opened: TuiSession = nil
    try:
      opened = openTuiSession(path, viewportHeight = max(1, size.rows - 6),
                              bound = DapReadBound(timeoutMs: handshakeBudgetMs(),
                                                   interruptFd: -1))
    except EngineStalledAfterOpenError as e:
      return "could not open " & path & ": " & StalledAfterOpenPhrase & " (" &
        e.msg.splitLines()[0] & ")"
    except CatchableError as e:
      return "could not open " & path & ": " & e.msg.splitLines()[0]
    # Interactive, as the first session is (§8b).
    opened.allowSlowOperations()
    try:
      if command.noFlowOverlay:
        opened.setFlowOverlay(false)
      opened.learnExtent()
    except DapStalledError as e:
      # Its first pane loads went unanswered: refused like an open that
      # failed, and its engine closed rather than left in a tab nobody can use.
      opened.close()
      return "could not open " & path & ": " & StalledAfterOpenPhrase & " (" &
        e.msg.splitLines()[0] & ")"
    let slot = app.shell.openSession(
      opened.session.backend.toBackendService(),
      title = extractFilename(opened.session.tracePath.strip(chars = {'/'})),
      layout = rt.debugArrangementOf(), adopt = opened.session.sdk)
    opened.wireFindInFiles()
    wireRequests(opened.session, proc(path: string): string =
      if app.recordingOpener.isNil: "this terminal cannot open " & path
      else: app.recordingOpener(path))
    sessions[int(slot.id)] = opened
    # M76: OPENED FROM A TAB WHOSE SESSION *STOP* ENDED — *File › Open
    # Trace…* (or *Record New Trace…*) chosen there, whose welcome tab
    # `openingInStoppedTab` names — the recording starts its new debugging
    # session IN THAT TAB (Debugger-Controls.md § "Ending a session from
    # inside it", requirement 3: "*Run*, or opening a trace, starts a new
    # debugging session in it by the ordinary route"): the new slot takes the
    # stopped one's place in the strip, and the stopped slot — whose engine is
    # already gone — is removed. The workspace returns to Debug mode, as a
    # replay opens in it. Any other open (*Open Trace in New Tab…*, the "+",
    # the omnibar) is a new tab and leaves the stopped tab where it is:
    # *Stop* never closes a tab, and neither does a later request for a new
    # one.
    let stoppedId = if replaceTab >= 0: HeadlessSessionId(replaceTab)
                    else: shownId
    let replacing =
      (replaceTab >= 0 and sessions.hasKey(replaceTab)) or
      (openingInStoppedTab and not session.isNil and
       session.ended and sessions.hasKey(int(stoppedId)))
    if replacing:
      var at = -1
      for i, t in app.shell.tabsOf():
        if t.id == stoppedId:
          at = i
      if app.shell.closeSession(stoppedId, disconnectBackend = false):
        # THE AGENT STAYS WITH THE TAB (DeepReview-GUI.md §2.2.4): the replay
        # is what is replaced; the Agent Activity host — its conversation, a
        # live agent, the prompt's attachments — moves onto the new session,
        # as the desktop's panel keeps them when it loads a recording in
        # place.
        let old = sessions[int(stoppedId)]
        if not old.agent.isNil:
          let store = opened.agent.store   # the new session's own
          opened.agent.close()
          opened.agent = old.agent
          old.agent = nil
          opened.agent.rehome(store)
        sessions[int(stoppedId)].close()
        sessions.del(int(stoppedId))
        if at >= 0:
          discard app.shell.moveSlot(slot.id, at)
      discard app.shell.activate(slot.id)
      rt.enterProductMode(pmDebug)
    showSession(slot.id)
    ""

  var testsTabs: proc(tab: int) = nil
    ## §9.2: tell the Test Results pane a tab closed (set once it exists).
  app.sessionCloser = proc(index: int): bool =
    # Rule 4: "Closing a tab stops its backend and removes it" — and the last
    # tab is not closed (the desktop's close control is not drawn on it).
    let tabs = app.shell.tabsOf()
    if index < 0 or index >= tabs.len or tabs.len < 2:
      return false
    let id = tabs[index].id
    if not app.shell.closeTab(index, disconnectBackend = false):
      return false
    if sessions.hasKey(int(id)):
      sessions[int(id)].close()
      sessions.del(int(id))
    if not testsTabs.isNil:
      # §9.2: a closed tab is no test's tab any more.
      testsTabs(int(id))
    showSession(app.shell.activeSessionId())
    true
  # PLAT-57: Find in Files — `:grep` searches the shown session's recording
  # into its `SearchResultsVM` (the shared runner, pumped on the idle tick
  # below); `:cnext` / `:cprev` open the next / previous result.
  app.findInFiles = proc(query: string): string =
    session.findInFiles(rt, query)
  app.stepSearchResult = proc(delta: int): string =
    session.stepSearchResult(rt, delta)
  app.toggleSearchOption = proc(operation: string): string =
    session.toggleSearchOption(rt, operation)
  # PLAT-70 Part D: the field's seed (`Ctrl+Shift+F`, `:grep` alone).
  app.openFindInFilesField = proc(selection: string): string =
    session.openFindInFilesField(rt, selection)
  # PLAT-54: Agent Activity — a press runs the row's action through the
  # session's `AgentActivityVM`; `/ai <prompt>` sends a prompt to the agent.
  app.agentPress = proc(row, button: int): string =
    session.agentPress(rt, row, button)
  app.agentPrompt = proc(text: string): string =
    session.agentPrompt(rt, text)
  app.agentStop = proc(): string =
    session.agentStop(rt)
  # The prompt's "add context" menu (DeepReview-GUI.md §2.2.7).
  app.agentAttach = proc(context: string; mustExist: bool): string =
    session.agentAttach(rt, context, mustExist)
  # PLAT-58: the Requests pane — a press, a menu, the URL search, a key —
  # done through the shown session's `RequestPanelVM`; its tail is polled on
  # the idle tick below.
  app.requestsAct = proc(act: RequestsAct): RequestsActResult =
    session.requestsAct(rt, act)
  # PLAT-60: the Low Level Code pane — a press, a menu, a key, the sync
  # toggle, the editor's caret, a step — done through the shown session's
  # `LowLevelCodeVM`.
  app.lowLevelAct = proc(act: LowLevelAct): LowLevelActResult =
    session.lowLevelAct(rt, act)

  # PLAT-47 deliverable 4: the VCS pane reads the directory the desktop's VCS
  # panel reads for a replay — the process's own working directory.
  var vcs = newVcsSource(projectRoot)
  defer: vcs.close()
  vcs.refresh(rt)
  # PLAT-53: the Test Results pane — the window's project (`app.projectRoot`,
  # which a welcome tab's folder re-roots) and the desktop's host over the
  # native producers; a test's recording opens where Test-Results-Pane.md §9
  # places it — a NEW session tab by default (`recordingOpener`), the
  # test's own tab when it has one, the current tab by the setting or Ctrl.
  var tests: TestsSource = nil
  proc placeTestRecording(testId, recordingId, folder: string;
                          policy: TraceOpenPolicy): string =
    let problem = traceFolderProblem(folder)
    if problem.len > 0:
      return "could not open " & folder & ": " & problem
    var place = tests.vm.placeTestRecording(testId, recordingId, policy)
    if place.kind != ttpNewTab and not sessions.hasKey(place.tab):
      # A tab the bookkeeping outlived: forget it, and open a new one.
      tests.vm.forgetTestTab(place.tab)
      place = TestTabPlacement(kind: ttpNewTab, tab: -1)
    let own = tests.vm.testTabOf(testId) >= 0
    case place.kind
    of ttpShowTab:
      discard app.shell.activate(HeadlessSessionId(place.tab))
      showSession(HeadlessSessionId(place.tab))
      tests.host.placedWords = " in its own tab"
      return ""
    of ttpReplaceTab:
      replaceTab = place.tab
      let why =
        try: app.recordingOpener(folder)
        finally: replaceTab = -1
      if why.len > 0:
        return why
      tests.vm.forgetTestTab(place.tab)
      tests.host.placedWords = if own: " in its own tab" else: " in this tab"
    of ttpNewTab:
      let why = app.recordingOpener(folder)
      if why.len > 0:
        return why
      tests.host.placedWords = " in a new tab"
    tests.vm.noteTestTab(testId, int(shownId), recordingId)
    ""
  tests = newTestsSource(
    projectRoot = proc(): string = app.projectRoot,
    ctBinary = proc(): string = nativeCtBinary(),
    resolveFolder = proc(id: string): string = recordingFolderOf(id),
    openFolder = proc(testId, recordingId, folder: string;
                      policy: TraceOpenPolicy): string =
      placeTestRecording(testId, recordingId, folder, policy))
  defer: tests.close()
  proc syncTestsTabs(): bool =
    ## §9: the current tab, and whether a replay may replace it — a live
    ## replay in Debug mode (not a tab *Stop* ended, not Edit mode).
    let live = sessions.hasKey(int(shownId)) and not session.isNil and
               not session.ended
    tests.setTabs(int(shownId), live and app.modes.product == pmDebug, true)
  testsTabs = proc(tab: int) =
    tests.vm.forgetTestTab(tab)
  discard syncTestsTabs()
  tests.refresh(rt)
  # PLAT-54: each session's Agent Activity host opens a test's recording the
  # way the welcome tab does — as a session tab (`recordingOpener`) — and
  # enters a review over an evidence card's dataset in the VCS pane.
  proc wireAgent(s: TuiSession) =
    if s.isNil or s.agent.isNil:
      return
    s.agent.vcs = vcs.vm
    # §2.2.4: `[Open recording]` replaces the current tab's session when it
    # is a live replay in Debug mode (the Test Results pane's rule 3 test),
    # and the host opens a new tab otherwise.
    s.agent.currentTabReplaceable = proc(): bool =
      sessions.hasKey(int(shownId)) and not session.isNil and
        not session.ended and app.modes.product == pmDebug
    s.agent.openRecording = proc(request: TraceOpenRequest): string =
      if app.recordingOpener.isNil:
        return "this terminal cannot open a recording"
      if request.policy != topCurrentTab:
        return app.recordingOpener(request.tracePath)
      let replaced = int(shownId)
      replaceTab = replaced
      result =
        try: app.recordingOpener(request.tracePath)
        finally: replaceTab = -1
      if result.len == 0 and not testsTabs.isNil:
        # Test-Results-Pane §9.2: a tab whose session was replaced is no
        # test's tab any more.
        testsTabs(replaced)
  agentWiring = wireAgent
  # An evidence card's review lands in the VCS pane at once, not at its next
  # refresh.
  app.agentPress = proc(row, button: int): string =
    let pressed = session
    result = pressed.agentPress(rt, row, button)
    # A recording opened from the pane is a NEW TAB, shown by then: the pane
    # is that session's, not the one the press was on.
    if session != pressed:
      session.refreshAgent(rt)
    vcs.publish(rt)
  wireAgent(session)
  if command.reviewDataset.len > 0:
    if not session.agent.loadReviewDataset(command.reviewDataset):
      app.notification = session.agent.message
    vcs.refresh(rt)
  if command.reviewSession.len > 0:
    discard session.agent.loadReviewSession(command.reviewSession)
  session.refreshAgent(rt)
  # PLAT-55: the Problems pane — the window's builds (`:build`), read by the
  # shared rule into the window's `ErrorsVM`. A row opens in Edit mode's
  # editor, or, in Debug mode, from the recording.
  let problems = newProblemsSource(rt,
    proc(path: string; line, col: int): string =
      if rt.app.modes.product == pmEdit:
        rt.openWorkingFileAt(path, line, col)
      else:
        session.showFileAt(rt, path, line, col))
  defer: problems.close()
  # PLAT-56: the Build Output pane over the same reader — the window's
  # `BuildVM`, the desktop BUILD panel's ViewModel; a located line opens as a
  # Problems row does, and Run builds the shown command again.
  let buildOut = newBuildOutputSource(rt, problems,
    proc(path: string; line, col: int): string =
      if rt.app.modes.product == pmEdit:
        rt.openWorkingFileAt(path, line, col)
      else:
        session.showFileAt(rt, path, line, col),
    proc(command, noun: string): string =
      if rt.editServices.startBuild.isNil:
        return "this window has no build runner"
      let started = rt.editServices.startBuild(
        (if noun == "run": bkRun else: bkBuild), command)
      if started.ok: "" else: started.message)
  app.notification = describe(session)

  # PLAT-51 deliverable 8: A NEW TAB'S WELCOME SCREEN, performed. The "+"
  # opens it (`runtime.openWelcomeTab`); a choice there is handed here, and
  # turns the tab into the session it starts:
  #   * a recording — opened as a session tab (`recordingOpener`) in the
  #     welcome tab's place;
  #   * a program to record — `ct record` in the background
  #     (`native_host.startRecordJob`), polled from the idle tick below, and
  #     its recording opened the same way when it finishes;
  #   * a folder — the session's Edit mode re-rooted there (the edit
  #     services, the file worker and the VCS pane follow `app.projectRoot`),
  #     and the tab becomes that folder's.
  var recordJob: NativeRecordJob = nil
  var recordSerial = -1
  proc welcomeIndexOf(serial: int): int =
    for i, t in app.welcomeTabs.tabs:
      if t.serial == serial:
        return i
    -1
  proc rootAt(path: string) =
    if path == app.projectRoot:
      return
    app.projectRoot = path
    files.stop()
    files = startFiles(rt, path, highlights)
    vcs.close()
    vcs = newVcsSource(path)
    vcs.refresh(rt)
    # A new workspace: the next arrival in Edit mode furnishes it from the
    # new root (`ensureEditWorkspace`), never over unsaved buffers.
    var unsaved = false
    if not app.editSession.isNil:
      for buf in app.editSession.buffers:
        if buf.isDirty:
          unsaved = true
    if not unsaved:
      app.editSession = nil
  app.welcomeHost = proc(tab: int; intent: NativeWelcomeIntent): string =
    if tab < 0 or tab >= app.welcomeTabs.tabs.len:
      return "that tab is gone"
    case intent.kind
    of niNone:
      return ""
    of niOpenTrace:
      let path = absolutePath(intent.path.expandTilde())
      let problem = traceFolderProblem(path)
      if problem.len > 0:
        return path & ": " & problem
      # M76: the welcome tab that stands in for a stopped tab
      # (`runtime.openWelcomeOption`) opens its recording IN that tab.
      let standsIn = app.welcomeTabs.tabs[tab].serial == app.stoppedTabWelcome
      openingInStoppedTab = standsIn
      let why =
        try: app.recordingOpener(path)
        finally: openingInStoppedTab = false
      if why.len > 0:
        return why
      if standsIn:
        app.stoppedTabWelcome = -1
      # THE TAB BECAME THAT SESSION: the welcome tab gives its place up.
      app.welcomeTabs.closeWelcomeTab(tab)
      if tab < app.welcomes.len:
        app.welcomes.delete(tab)
      var known = false
      for e in app.recordings:
        if e.target == path:
          known = true
      if not known:
        app.recordings.insert(OmnibarEntry(kind: OmnibarMode.omRecording,
                                           label: extractFilename(path),
                                           detail: path.parentDir,
                                           target: path), 0)
      ""
    of niRecord:
      if not recordJob.isNil and not recordJob.done:
        return "a recording is already running: " & recordJob.program
      let stamp = now().format("yyyyMMdd-HHmmss")
      let output = nativeStateRoot() / "recordings" /
                   (extractFilename(intent.program).changeFileExt("") & "-" &
                    stamp)
      recordJob = startRecordJob(intent.program, intent.args, output)
      recordSerial = app.welcomeTabs.tabs[tab].serial
      if recordJob.done:
        return recordJob.message
      ""
    of niOpenFolder:
      let path = absolutePath(intent.path.expandTilde())
      let problem = editProjectProblem(path)
      if problem.len > 0:
        return problem
      rootAt(path)
      app.welcomeTabs.turnIntoFolder(tab, path)
      app.welcomeTabs.active = tab
      let at = app.recentFolders.find(path)
      if at >= 0:
        app.recentFolders.delete(at)
      app.recentFolders.insert(path, 0)
      rt.enterProductMode(pmEdit)
      ""
  proc pollRecording(): bool =
    ## The background `ct record`, once it finishes: its recording opened
    ## in the tab that asked, or the failure on that tab's screen.
    if not pollRecordJob(recordJob):
      return false
    let at = welcomeIndexOf(recordSerial)
    if at < 0:
      return true
    if recordJob.ok:
      let why = app.welcomeHost(at, NativeWelcomeIntent(
        kind: niOpenTrace, path: recordJob.outputFolder))
      if why.len > 0 and at < app.welcomes.len:
        app.welcomes[at].message = why
    elif at < app.welcomes.len:
      app.welcomes[at].message = recordJob.message
    true
  if hintsOn and negotiation.caps.remedies.len > 0:
    # THE ONE CAPABILITY FINDING THAT OUTLIVES FRAME 0 (Terminal-Adaptation
    # §10.2): at most one hint per session — the most useful remedy, e.g. a
    # tmux painting a 24-bit terminal at 256 colours — dismissed for good
    # with `:terminal-info dismiss`.
    app.notification.add " | " & negotiation.caps.remedies[0]

  # §6.2's `--goto=<tick>`: BEFORE THE FIRST DEBUGGER FRAME, which is the whole
  # of what the flag adds over typing `:goto` — `session.seekToStartupTick`
  # dispatches the same `kaSeekToTick` action the command resolves to. It runs
  # after `learnExtent` on purpose: the clamp is against the recording's own
  # bounds, and those are what `ct/event-load`'s `maxRRTicks` just supplied.
  if command.gotoTick != NoGotoTick:
    app.notification = session.seekToStartupTick(rt, command.gotoTick)
  if journal.isReplaying:
    app.notification = describe(journal)
  # A SAVED LAYOUT THAT COULD NOT BE READ OUTLIVES THE "opened" MESSAGE, and
  # that ordering is the whole of the promise `app/layout/persistence.nim`
  # makes. `describe(session)` above is a routine fact about a recording that
  # opened correctly; this is a thing the user has to know — they asked for
  # their arrangement, they did not get it, and without this line the only
  # evidence would have been erased by the next repaint. A restore that
  # SUCCEEDED says so on frame 0 and then gets out of the way, which is the
  # opposite precedence and is also deliberate.
  if layoutRestore.status == lrsUnreadable:
    app.notification = layoutRestore.message
  # The menu's chords and the omnibar's commands, now that the session's
  # ViewModels exist.
  rt.refreshMenuForKeymap()
  paint(driver, rt)
  var graphicsProbe = startGraphicsProbe(driver, rt)

  var running = true
  var frameOwed = false
  var lastPaintMs = 0'i64
    ## PLAT-71 (Terminal-Adaptation §4.6): when the last token-driven frame
    ## was painted — on a link-conservative session a pointer merely passing
    ## repaints at most once per `HoverCoalesceMs`.
  var commitsSeen = rt.layoutCommits
  var viewRows = rt.sourcePaneRows()
  # PLAT-70: the editor's horizontal bar takes a row from the source window
  # while the document is wider than the pane (`runtime.sourcePaneRows`);
  # the first frame is what measured the pane's width.
  var barSeen = rt.editorBarShown()
  if barSeen and viewRows > 0:
    session.setViewportHeight(viewRows)
    session.refresh(rt)
    paint(driver, rt)
  while running:
    # §6.2's `--replay-keys`: "replay input events from file and exit". The
    # journal REPLACES the keyboard rather than being merged with it, so a
    # replay is a fixed amount of work — which is what lets
    # `benchmarks/tui_benchmarks.nim` time one and
    # `tests/real_terminal/test_real_high_latency.nim` compare two.
    var ev: DriverEvent
    if journal.isReplaying:
      let (has, token) = journal.nextReplayToken()
      if not has:
        break
      ev = DriverEvent(kind: dekToken, token: token)
    else:
      ev = driver.nextEvent(idleWaitMs(rt))
    case ev.kind
    of dekEof:
      # The terminal closed its end. Not an error and not a quit key: the user
      # is gone, and the only correct thing left is to give the tty back.
      running = false
    of dekIdle:
      if graphicsProbe.open and nowMs() > graphicsProbe.deadlineMs:
        # No answer: the terminal draws no pictures. The default stays.
        graphicsProbe.open = false
      discard rt.clipboardReadDue(driver)
      if not graphicsProbe.open and not rt.clipboardRead.open:
        negotiation.closeReplyWindow(driver)
      # THE BUILD IS ADVANCED FROM THE SAME LOOP THAT READS THE KEYBOARD, on
      # exactly `editInteractive`'s rule and for §5's reason. A replay session
      # that switched to Edit mode and typed `:build` owns a process, and a
      # loop that never polled it would leave that build running with no
      # verdict, no output and no `:cancel`.
      let built = advanceBuild(rt, edit, report = true)
      let vcsChanged = vcs.tick(rt)
      # PLAT-53: a test run that ended, and a re-rooted project; §9: the
      # tab facts the `⏵` titles read.
      let tabsMoved = syncTestsTabs()
      if tabsMoved:
        tests.publish(rt)
      let testsChanged = tests.tick(rt) or tabsMoved
      # PLAT-55: the build's diagnostics, as they arrive.
      let problemsTicked = problems.tick(rt, nowMonoMs())
      let problemsChanged = buildOut.tick(rt) or problemsTicked
      # PLAT-57: the search in flight, a bounded step per tick.
      let searched = session.pumpFindInFiles(rt)
      # PLAT-54: what a live agent sent since the last tick.
      let agentChanged = session.pumpAgent(rt)
      # PLAT-58: the Requests pane's tail (a live session's), and its reveal
      # once the recording's requests are known.
      let requestsChanged = session.pumpRequests(rt, nowMs())
      # PLAT-51: a welcome tab's recording, when it finishes.
      let recorded = pollRecording()
      # PLAT-49 part B: the auto-hide hover's clock — a preview due after
      # the pointer rested on a label, a dismissal due after it left.
      let hoverChanged = rt.tickAutoHide(nowMs()) or
                         rt.tickCellHover(nowMs()) or
                         rt.tickPendingPrefix(nowMs())
      # PLAT-70 Part H: the scrollbars' fades and a held paging press (a
      # page of the editor is a source scroll the session makes).
      let bars = rt.tickScrollbars(nowMs())
      if bars.repaint:
        session.applyOutcome(rt, bars)
      let barsChanged = bars.repaint
      let keysChanged = rt.pollKeybindings(keybindings)
      if drainHighlights(rt, highlights, files) or built or vcsChanged or
         hoverChanged or frameOwed or recorded or keysChanged or searched or
         barsChanged or testsChanged or agentChanged or problemsChanged or
         requestsChanged:
        paint(driver, rt)
        frameOwed = false
    of dekResize:
      size = ev.size
      rt.resize(size.cols, size.rows)
      # THE SOURCE WINDOW FOLLOWS THE PANE, not the terminal. A reflow that
      # changed the profile changed the editor's rectangle, and a `SourceVM`
      # still holding the old height would scroll the execution line off the
      # pane — see `runtime.sourcePaneRows`.
      viewRows = rt.sourcePaneRows()
      session.setViewportHeight(viewRows)
      session.refresh(rt)
      # The VCS pane's history follows its new height (Viewport-Driven-Loading
      # V6): a taller pane reads the commits it can now show.
      discard vcs.followViewport(rt)
      paint(driver, rt)
    of dekFocus:
      # THE VCS PANE'S SECOND TRIGGER (VCS-Panel.md's auto-refresh, the
      # desktop's window `focus` listener in `ui/vcs.nim`): the terminal
      # window regained focus (`CSI I`, DECSET 1004), so the repository is
      # read again NOW rather than up to `VcsRefreshMs` later, and the frame
      # is painted only when the pane's value moved. Never a key and never
      # journalled — `terminal_driver.tokenEvent` already took it out of the
      # token stream, so a replay of `--record-keys` is unchanged by it.
      if vcs.refreshOnFocus(rt, ev.focused):
        paint(driver, rt)
    of dekToken:
      if rt.takeClipboardReply(driver, ev.token):
        continue
      # PLAT-48: THE ANSWER TO THE GRAPHICS QUERY. `OK` means the terminal
      # draws pictures: the controls default to the desktop's marks, unless
      # the user chose otherwise. Never a key, never journalled.
      if isGraphicsProbeReply(ev.token):
        graphicsProbe.open = false
        if ev.token.contains(";OK"):
          rt.app.graphicsDrawn = true
          if not rt.app.iconsChosen:
            rt.app.icons = imGraphics
          paint(driver, rt)
        continue
      # PLAT-46: A TERMINAL'S LATE ANSWER TO THE START-UP ROUND IS NOT A KEY.
      # It re-decides the capabilities and repaints; it is never journalled.
      let (wasReply, changed) = negotiation.takeReply(driver, ev.token)
      if wasReply:
        adoptMouseMetrics(driver, negotiation)
        if changed:
          rt.adoptCaps(negotiation.caps)
          app.notification = capabilityNote(negotiation.caps, hintsOn)
          paint(driver, rt)
        continue
      # RECORDED BEFORE IT IS HANDLED, so the journal of a session that quit on
      # this token still contains it. A `q` written down only after the loop
      # decided to stop would be a journal that replays to a different screen
      # than the one it recorded.
      journal.note(ev.token)
      let outcome = rt.handleToken(ev.token, nowMs())
      if outcome.quit:
        running = false
      else:
        # PLAT-49 part B: a tab click (or `next-session-tab`) chose another
        # session: the panes follow it before the outcome is applied.
        if app.shell.activeSessionId() != shownId:
          showSession(app.shell.activeSessionId())
        if syncTestsTabs():
          tests.publish(rt)
        # PLAT-50: a click in the VCS pane is the VCS source's; PLAT-53: one
        # on Test Results' controls is the Test Results source's.
        if not vcs.applyClick(rt, outcome.paneClick) and
           not tests.applyClick(rt, outcome.paneClick):
          session.applyOutcome(rt, outcome)
        # V6: THE VCS HISTORY FOLLOWS ITS LIST. The token may have scrolled the
        # pane, revealed its tab or committed an arrangement that resized it;
        # a list that now reaches the last commit read reads more at once.
        let vcsFollowed = vcs.followViewport(rt)
        # PLAT-51 (Layout-ViewModel §4.3a): A COMMITTED ARRANGEMENT MAY HAVE
        # RESIZED THE SOURCE PANE — it fetches for its new height now, once,
        # after the release; never while a divider is still held (the frames
        # of a live drag re-lay-out what the pane holds).
        if rt.layoutCommits != commitsSeen:
          commitsSeen = rt.layoutCommits
          let rows = rt.sourcePaneRows()
          if rows > 0 and rows != viewRows:
            viewRows = rows
            session.setViewportHeight(rows)
            session.refresh(rt)
        # A CANCEL REQUEST IS ACTED ON BEFORE THE NEXT IDLE TICK, so `:cancel`
        # does not wait up to `IdlePollMs` for the process to be signalled.
        # `report = false`: the line the key just wrote is the user's own.
        discard advanceBuild(rt, edit, report = false)
        # WRITE COALESCING, CTUI-14. A repaint is skipped only when the user's
        # NEXT key is already waiting to be handled — `driver.holdFrame` asks
        # the input fd, it does not consult a clock — so the frame that answers
        # a keystroke typed on its own is never delayed by a millisecond, and
        # the frames dropped are the ones a terminal could not have shown
        # before they were replaced. `ssh_tuning.WriteCoalescer.maxHeld` is what
        # stops a held key from freezing the screen for as long as it is held.
        #
        # PLAT-48: A HELD FRAME IS OWED, NOT DROPPED. It was held because the
        # next token was already waiting — but that token may change nothing
        # on screen (the release half of a click on a debugger control, a
        # pointer passing over the body), and a frame held for a token that
        # repaints nothing was never drawn: the step the click made happened
        # and the screen kept the old tick. `frameOwed` carries it to the
        # next token and to the next idle tick.
        # PLAT-70 Part H: a fade keeps moving while tokens arrive (a pointer
        # passing over the panes is a stream of them).
        let bars = rt.tickScrollbars(nowMs())
        if bars.repaint:
          session.applyOutcome(rt, bars)
        let barsMoved = bars.repaint
        # PLAT-71 (§4.6): over a slow link, hover-driven repaints are
        # coalesced; the owed frame is painted by the next token or idle tick.
        let hoverOnly = negotiation.caps.linkConservative and
                        isPointerPassing(ev.token)
        if outcome.repaint or frameOwed or vcsFollowed or barsMoved:
          if driver.holdFrame(journal.pendingReplay > 0) or
             (hoverOnly and nowMs() - lastPaintMs < HoverCoalesceMs):
            frameOwed = true
          else:
            paint(driver, rt)
            lastPaintMs = nowMs()
            frameOwed = false
        # PLAT-70: the editor's horizontal bar came or went (a wider file, an
        # edit, a narrower pane): the source window follows the rows it left.
        if rt.editorBarShown() != barSeen:
          barSeen = not barSeen
          let rows = rt.sourcePaneRows()
          if rows > 0 and rows != viewRows:
            viewRows = rows
            session.setViewportHeight(rows)
            session.refresh(rt)
            paint(driver, rt)

  # THE ARRANGEMENT IS SAVED AGAIN ON THE WAY OUT, AND ONLY IF IT IS THE
  # USER'S. PLAT-45 added the write-through on every committed change (a drag
  # commits once, on release, so a pointer movement costs no writes); this
  # final save is what makes a session that ended with the default in place —
  # untouched, or reset — remove a stale document.
  #
  # `persistLayoutForSession` answers `lpoQuarantined` when this session
  # started from a document it could not read, and `lpoRemoved` when the
  # arrangement is the shared default's own — which is what makes
  # `:reset-layout` reach all the way to the disk instead of leaving a stale
  # document behind. Every committed change was already written through
  # (`rt.layoutCommitted` above); this is the last word.
  #
  # BEFORE `driver.stop()` runs from its `defer`, so a failure message is
  # composed while the screen is still ours; it is REPORTED ON STDERR after the
  # terminal is given back, for the reason every other diagnosis in this module
  # is: a message printed onto a claimed alternate screen is a message nobody
  # reads.
  let saved = persistLayoutForSession(rt)
  if saved.outcome == lpoFailed:
    driver.stop()
    stderr.writeLine(TuiProgramName & ": " & saved.message)
  ExitOk


proc editInteractive(command: TuiCommand): int =
  ## PLAT-16. `ct edit --ui=tui <project>` — open a project in EDIT mode.
  ##
  ## ## WHY THIS IS A SECOND LOOP AND NOT A FLAG ON `interactive`
  ##
  ## `interactive` opens a REPLAY: it resolves a trace folder, finds
  ## `replay-server`, spawns it, runs a bounded DAP handshake and pumps
  ## `ct/complete-move` after every navigation. Edit mode does none of those —
  ## there is no recording, no engine and no tick — and a shared loop would be
  ## that loop with five `if editing` branches in it, including inside the
  ## handshake. The two share everything that matters (`TuiRuntime`,
  ## `handleToken`, `paint`, the driver), which is the part that must not be
  ## duplicated and is not.
  ##
  ## Mode-Transitions.md §1 is why this is honest rather than a split product:
  ## the TRANSITION between the modes is instant and in-memory, and `Ctrl+F5`
  ## reaches it from either loop. What differs is what was open when the process
  ## started.
  ##
  ## ## `ct edit` HAS NO RECORDING, AND THE STALE-TRACE NOTICE IS NOT ITS JOB
  ##
  ## Stated plainly because PLAT-16's landing pass found it being assumed.
  ## Nothing here assigns `app.traceName`, deliberately: this command opens a
  ## PROJECT, no `replay-server` is spawned, no DAP handshake runs, and there is
  ## no tick. So `Ctrl+F5` out of this loop calls
  ## `edit_binding.noticeForSwitchToDebug(hasTrace = false)`, which resolves to
  ## `stvNoTrace` and says nothing — which is **correct**: a recording that does
  ## not exist cannot be outrun by an edit. §2.1 consequence 3's notice is about
  ## *"the toggle onto an EXISTING trace"*, and the loop that has one is
  ## `interactive` above. Giving this loop a synthetic trace name to make the
  ## notice reachable would be a fiction arranged to satisfy a test.
  ##
  ## `Ctrl+F5` from here still works and still switches: Debug mode without a
  ## recording is the empty debugger, which is the same thing `codetracer-tui`
  ## with no argument has always painted.
  let caps = negotiateCapabilities(command.editFlags)
  if not stdoutIsTerminal():
    stderr.writeLine(TuiProgramName & ": standard output is not a terminal," &
                     " so there is nothing to draw on.")
    stderr.writeLine("  negotiated: " & describe(caps))
    stderr.writeLine("  edit mode needs a terminal; --headless renders one" &
                     " settled screen and is refused with --edit.")
    return ExitNoTerminal

  # BEFORE THE TERMINAL IS CLAIMED, on exactly `interactive`'s rule and for the
  # reason recorded there: a diagnosis printed onto a claimed alternate screen
  # is a diagnosis nobody reads.
  let root = absolutePath(command.projectPath)
  let problem = editProjectProblem(root)
  if problem.len > 0:
    stderr.writeLine(TuiProgramName & ": " & root & ": " & problem)
    return ExitUsage

  # AND THE LISTING IS TAKEN BEFORE THE TERMINAL TOO. It is the one unbounded
  # walk in this path; `edit_host.MaxProjectFiles` bounds it, and doing it here
  # means a slow filesystem shows as a slow start rather than as a blank
  # alternate screen.
  let listing = listProjectFiles(root)

  let driver = newTerminalDriver(caps)
  driver.start()
  defer: driver.stop()
  let (storedPrefs, terminalPrefs) = storedTerminalPrefs()
  let negotiation = driver.negotiateOnTerminal(command.editFlags, terminalPrefs)
  adoptMouseMetrics(driver, negotiation)
  let hintsOn = storedPrefs.settings.terminal.terminalHints != "off"

  var size = driver.size()
  let app = newTuiApp()
  app.projectRoot = root
  # THE PRODUCT MODE IS SET BEFORE THE FIRST FRAME, which is Mode-Transitions.md
  # §4 requirement 4 at startup: mode and layout are settled together, so the
  # first paint is Edit mode's arrangement rather than Debug's with an edit
  # pane in it.
  app.modes = initModeRegister(pmEdit)
  app.projectRoot = root

  let rt = newTuiRuntime(app, negotiation.caps, size.cols, size.rows)
  rt.eraseByte = driver.eraseByte()
  rt.themeService = themeSwitch(negotiation, driver, rt)
  wireTerminalService(rt, negotiation, driver)
  rt.dispatcher.services.setTheme = rt.themeService

  # THE HOST'S FOUR CAPABILITIES, INJECTED — one function, shared with
  # `interactive`. See `wireEditServices`.
  #
  # `listFiles` CLOSES OVER THE LISTING ALREADY TAKEN rather than walking
  # again, which is how the "before the terminal is claimed" ordering above
  # survives being routed through a function the replay loop also uses. The
  # walk happened on the ordinary screen; this hands back its answer.
  #
  # K19: ONLY THE FIRST ANSWER IS THAT LISTING. A Create, Rename or Delete in
  # the Files pane changes the project, and the pane must follow the disk, so
  # every later call walks again (the terminal is long claimed by then, and a
  # walk after an operation is the user's own action).
  var served = false
  let edit = wireEditServices(rt, root, command.keymap,
                              proc(): EditListResult =
    if not served:
      served = true
      return EditListResult(files: listing.files, truncated: listing.truncated)
    let fresh = listProjectFiles(rt.app.projectRoot)
    EditListResult(files: fresh.files, truncated: fresh.truncated))
  wireTopBar(rt)
  let keybindings = wireKeybindings(rt)
  # THE LAYOUT IS THE USER'S IN EDIT MODE TOO — AND IT IS NOT REMEMBERED.
  #
  # Edit mode's arrangement puts Files and VCS in one stack, and without a
  # binding nothing could choose the VCS tab: `handleToken` hands a mouse
  # report to the layout only when a binding is enabled, the View menu's pane
  # items (`showPane`) refuse with "the layout is not rearrangeable in this
  # session", and the `:` layout verbs are unknown commands. So the VCS pane
  # this loop keeps refreshed (below) could never be shown (codetracer-pm
  # issue 2026-10-21). Enabled exactly as the replay loop enables it, and
  # before `wireLayoutPreferences` for the same reason: `live-resize` is
  # applied to the binding, so a binding enabled after it would ignore it.
  #
  # Frame 0 is unchanged by it: the product mode is already Edit, and an
  # Edit-mode runtime with no session seeds the binding from Edit mode's own
  # default (`tui_app.enableLayoutBinding`, `profile.layoutValueForMode`), not
  # from Debug's.
  #
  # NO LAYOUT DOCUMENT IS BOUND, deliberately, and that is the half of the
  # replay loop's wiring left out: no `restoreLayoutForSession`, no
  # `rt.layoutCommitted` write-through, no exit save. The terminal's remembered
  # arrangement (`host/layout_store.layoutDocumentPath`) is ONE document, and
  # it is not keyed by mode — Mode-Transitions.md §4b's second tier is not
  # implemented (see `views/shell.switchTo`). It holds the replay loop's Debug
  # arrangement, so restoring it here would paint Debug's panes into an editor
  # and saving here would overwrite the user's Debug arrangement with Edit's.
  # With no document bound, `layoutPersistenceEnabled` is false and
  # `layoutPersistPlanOf` answers the intent that touches nothing, so an Edit
  # arrangement lasts for the session — which is what the mode register
  # already promises for Edit mode (§4b tier 1) — and no file is read or
  # written.
  discard rt.enableLayoutBinding()
  var noFlags: array[LayoutSetting, string]
  wireLayoutPreferences(rt, noFlags)
  wireColumnWidths(rt)
  # PLAT-29: the Edit pane's parse runs on this worker, never on the render
  # path; stopped when the loop that owns it returns.
  let highlights = startHighlights(rt, driver)
  defer: highlights.stop()
  # Declared AFTER the highlight worker, so it is stopped FIRST (defers run in
  # reverse) — its pending writes finish while the shared wake pipe is open.
  let files = startFiles(rt, root, highlights)
  defer: files.stop()

  # THE SAME FUNCTION THE TOGGLE CALLS. Opening the first file and filling the
  # tree used to be written out here as well as in `app/runtime.nim`; two
  # copies of one behaviour is §14's subject, and this is the copy no suite
  # would have mutated.
  let furnished = rt.ensureEditWorkspace()
  if furnished.len > 0:
    app.notification = furnished
  discard rt.focus.focusPaneKind(paneEditor)
  # PLAT-47 deliverable 4: in Edit mode the VCS pane reads the project, the
  # folder the desktop's edit mode hands its VCS panel.
  let vcs = newVcsSource(root)
  defer: vcs.close()
  vcs.refresh(rt)
  # PLAT-53: the Test Results pane over the project. This loop has no session
  # tabs, so a test's recording is not opened here: the pane says where it is
  # instead (Test-Results-Pane.md §8.3).
  let tests = newTestsSource(
    projectRoot = proc(): string = app.projectRoot,
    ctBinary = proc(): string = nativeCtBinary(),
    resolveFolder = proc(id: string): string = recordingFolderOf(id),
    openFolder = proc(testId, recordingId, folder: string;
                      policy: TraceOpenPolicy): string =
      NoSessionTabsText & folder)
  defer: tests.close()
  # §9: no session tabs here.
  discard tests.setTabs(-1, false, false)
  tests.refresh(rt)
  # PLAT-55: the Problems pane over this window's builds; a row opens in the
  # editor.
  let problems = newProblemsSource(rt,
    proc(path: string; line, col: int): string =
      rt.openWorkingFileAt(path, line, col))
  defer: problems.close()

  # PLAT-56: the Build Output pane over the same reader — the window's
  # `BuildVM`, the desktop BUILD panel's ViewModel; a located line opens as a
  # Problems row does, and Run builds the shown command again.
  let buildOut = newBuildOutputSource(rt, problems,
    proc(path: string; line, col: int): string =
      rt.openWorkingFileAt(path, line, col),
    proc(command, noun: string): string =
      if rt.editServices.startBuild.isNil:
        return "this window has no build runner"
      let started = rt.editServices.startBuild(
        (if noun == "run": bkRun else: bkBuild), command)
      if started.ok: "" else: started.message)

  # Find in Files, which Edit mode docks, searches the project
  # (Find-And-Incremental-Search.md §5.1); a result opens in the editor.
  let editSearch = newEditSearchSource(rt, root)

  paint(driver, rt)

  var loop = true
  while loop:
    let ev = driver.nextEvent(idleWaitMs(rt))
    case ev.kind
    of dekEof:
      loop = false
    of dekIdle:
      discard rt.clipboardReadDue(driver)
      if not rt.clipboardRead.open:
        negotiation.closeReplyWindow(driver)
      let searched = editSearch.tick(rt)
      # THE BUILD IS ADVANCED FROM THE SAME LOOP THAT READS THE KEYBOARD, which
      # is the whole of §5's cancellability requirement: the key that cancels is
      # read while the compiler runs, and the clock that bounds an unattended
      # session is checked on every tick. See `host/build_runner.pollBuild`.
      let built = advanceBuild(rt, edit, report = true)
      let vcsChanged = vcs.tick(rt)
      let testsChanged = tests.tick(rt)
      let problemsTicked = problems.tick(rt, nowMonoMs())
      let problemsChanged = buildOut.tick(rt) or problemsTicked
      let hoverChanged = rt.tickAutoHide(nowMs()) or
                         rt.tickCellHover(nowMs()) or
                         rt.tickPendingPrefix(nowMs())
      let barsChanged = rt.tickScrollbars(nowMs()).repaint
      let keysChanged = rt.pollKeybindings(keybindings)
      if drainHighlights(rt, highlights, files) or built or vcsChanged or
         hoverChanged or keysChanged or barsChanged or testsChanged or
         problemsChanged or searched:
        paint(driver, rt)
    of dekResize:
      size = ev.size
      rt.resize(size.cols, size.rows)
      discard vcs.followViewport(rt)
      paint(driver, rt)
    of dekFocus:
      # The terminal window regained focus: the project's VCS pane re-reads
      # now, exactly as in the replay loop above (`VcsSource.refreshOnFocus`).
      if vcs.refreshOnFocus(rt, ev.focused):
        paint(driver, rt)
    of dekToken:
      if rt.takeClipboardReply(driver, ev.token):
        continue
      let (wasReply, changed) = negotiation.takeReply(driver, ev.token)
      if wasReply:
        adoptMouseMetrics(driver, negotiation)
        if changed:
          rt.adoptCaps(negotiation.caps)
          app.notification = capabilityNote(negotiation.caps, hintsOn)
          paint(driver, rt)
        continue
      let outcome = rt.handleToken(ev.token, nowMs())
      if outcome.quit:
        loop = false
      else:
        # PLAT-50: a click in the VCS pane is the VCS source's, in Edit mode
        # too; PLAT-53: Test Results' controls are the Test Results source's.
        discard vcs.applyClick(rt, outcome.paneClick)
        discard tests.applyClick(rt, outcome.paneClick)
        # V6: the history follows its list, as in the replay loop above.
        let vcsFollowed = vcs.followViewport(rt)
        # A CANCEL REQUEST IS ACTED ON BEFORE THE NEXT IDLE TICK, so `:cancel`
        # does not wait up to `IdlePollMs` for the process to be signalled.
        discard advanceBuild(rt, edit, report = false)
        let barsMoved = rt.tickScrollbars(nowMs()).repaint
        if outcome.repaint or vcsFollowed or barsMoved:
          paint(driver, rt)
  ExitOk

proc run(args: seq[string]): int =
  ## The whole entrypoint, as a function of its arguments, returning the
  ## process's exit status rather than calling `quit`.
  ##
  ## `src/ct/codetracer.nim` exiting 0 on an unhandled exception is the single
  ## highest-value defect in the Silent-Self-Pass audit — it made every gate
  ## that ran `ct` and checked `$?` read crashes as success. So this returns a
  ## status, the wrapper below is the only thing that quits, and the failure
  ## paths are visible in one screen rather than spread across the arms.
  # PLAT-1 §7.1: `ct tui` is a deprecated alias for `ct replay --ui=tui`, kept
  # for one release. EXACTLY ONE LINE, on stderr, before anything else — stdout
  # carries `--version`'s machine-readable answer and the alternate screen's
  # first frame, and a warning in either would corrupt a parse or be erased by
  # the first repaint. Emitted here rather than inside `parseTuiCommand`
  # because printing is a host act and that module does none.
  let deprecated = deprecatedCommandWord(args)
  if deprecated.len > 0:
    stderr.writeLine(deprecationLine(deprecated))

  let command = parseTuiCommand(args)
  case command.kind
  of tckHelp:
    echo TuiHelpText
    ExitOk
  of tckVersion:
    echo TuiVersionText
    ExitOk
  of tckUsageError:
    stderr.writeLine(TuiProgramName & ": " & command.message)
    ExitUsage
  of tckOpenTrace:
    try:
      interactive(command)
    except TuiHostError as e:
      stderr.writeLine(TuiProgramName & ": " & e.msg)
      ExitUsage
  of tckHeadless:
    try:
      runHeadless(command.tracePath, command.flags, headlessGeometry(),
                  gotoTick = command.gotoTick)
    except TuiHostError as e:
      stderr.writeLine(TuiProgramName & ": " & e.msg)
      ExitUsage
  of tckEditProject:
    try:
      editInteractive(command)
    except TuiHostError as e:
      stderr.writeLine(TuiProgramName & ": " & e.msg)
      ExitUsage
  of tckCapabilities:
    reportCapabilities(command)
  of tckPaneServer:
    # HSF-E1: an editor's pane server. Its stdio is the protocol, so a
    # refusal is written to stderr like every other diagnostic here.
    runPaneServer()

when isMainModule:
  # The ONLY `quit` in the entrypoint, and it is reached on every path. An
  # unhandled exception must not become exit 0 here: `run` returns a status and
  # anything that escapes it is caught, named on stderr and reported as a
  # failure. stdout is left clean because `--version` is machine-readable.
  var status = ExitOk
  try:
    status = run(commandLineParams())
  except CatchableError as e:
    stderr.writeLine(TuiProgramName & ": " & $e.name & ": " & e.msg)
    status = ExitUnhandled
  quit(status)
