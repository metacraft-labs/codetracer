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

import std/os

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
import ./app/tui_app
import ./host/build_runner
import ./host/capabilities
import ./host/edit_host
import ./host/headless
import ./host/key_journal
import ./host/layout_store
import ./host/native_host
import ./host/terminal_driver
import ./host/tui_session
import ../viewmodel/host/keymap_preference

const
  IdlePollMs = 200
    ## How long the loop blocks when nothing is happening.
    ##
    ## A CEILING ON LATENCY FOR NOTHING, and it is not a poll interval: input
    ## and SIGWINCH both wake the `select` immediately, so this only bounds how
    ## long the process sleeps between two events it does not have. It exists so
    ## a partially framed escape sequence — an `ESC` with nothing after it — is
    ## not held forever.

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

proc wireEditServices(rt: TuiRuntime; root: string;
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
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(root, relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
    try:
      writeProjectFile(root, relative, text)
      EditWriteResult(ok: true)
    except TuiHostError as e:
      EditWriteResult(ok: false, message: e.msg)
  rt.editServices.readConfig = proc(spelled: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readUserConfigFile(root, spelled))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.listFiles = listFiles
  # PLAT-43. The keymap model this session starts under is the one the user
  # last chose, read through the same `selectKeymap` a typed `:keymap` goes
  # through. A stored value that is not a model is REFUSED BY NAME on the
  # status line and the session runs the product default — never a silent
  # fallback a user cannot tell from a working preference.
  let keymapPreference = loadKeymapPreference()
  rt.keymapModel = keymapPreference.model
  if not rt.app.editSession.isNil:
    rt.app.editSession.selectModel(keymapPreference.model)
  if keymapPreference.status == kplRefused:
    rt.keymapNotice = keymapPreference.message
    rt.app.notification = keymapPreference.message
  rt.editServices.saveKeymap = proc(model: KeymapModel): string =
    saveKeymapPreference(model)
  rt.editServices.startBuild = proc(kind: BuildKind;
                                    cmd: string): BuildStartResult =
    state.running = startBuild(kind, cmd, root, nowMonoMs())
    rt.app.build = state.running.session
    if state.running.session.verdict == bvRunning:
      BuildStartResult(ok: true, message: $kind & " started: " & cmd)
    else:
      BuildStartResult(ok: false, message: describeVerdict(state.running.session))
  state

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
  let (prompting, row, col) = rt.promptCursor()
  if prompting:
    epilogue = "\x1b[" & $(row + 1) & ";" & $(col + 1) & "H" & ShowCursorBytes
  driver.paint(screen.styledRows,
               prologue = cursorControlBytes(rt.modal.mode),
               epilogue = epilogue)

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

  var size = driver.size()
  let app = newTuiApp()
  app.notification = "opening " & folder & " …"
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
  let rt = newTuiRuntime(app, caps, size.cols, size.rows)
  let edit = wireEditServices(rt, projectRoot, proc(): EditListResult =
    let listing = listProjectFiles(projectRoot)
    EditListResult(files: listing.files, truncated: listing.truncated))
  # PLAT-6's OPT-IN, and it is the only thing that turns the layout binding on
  # in a shipped binary. `app/runtime.enableLayoutBinding` records why it is an
  # opt-in and what would have to be true to flip the default; what matters
  # here is the shape: one guarded line, before the first frame, so the binding
  # is seeded from the arrangement this session would have painted anyway.
  #
  # WITHOUT THE FLAG NOTHING BELOW CHANGES. `shellModel` carries the session's
  # own `LayoutNode`, an empty `docked` and no `Interaction`, which is exactly
  # the model CTUI-3 built, and the `:` prompt routes to §4.3's interpreter as
  # it always has.
  var layoutRestore = LayoutRestoreReport()
  if command.layoutBinding:
    discard rt.enableLayoutBinding()
    # AND THE ARRANGEMENT COMES BACK. PLAT-6's Goal sentence promises "move
    # tabs, resize splits, dock panes, SAVE AND RESTORE", and until this line
    # the fourth clause was the one a user did not get: `binding.saveDocument`
    # and `binding.restoreDocument` existed and nothing in the product called
    # either, so an arrangement did not survive a restart.
    #
    # KEYED BY THE RECORDING, held under the user's own state directory, and
    # behind the SAME opt-in as the gestures — with the flag off
    # `restoreLayoutForSession` computes no path and opens no file at all.
    # `app/layout/persistence.nim`'s header carries the reasoning for each of
    # those three; what matters here is that this is the only place a shipped
    # binary reads one.
    layoutRestore = restoreLayoutForSession(rt, folder)
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
  defer: session.close()
  # THE HATCH COMES OFF NOW. See `tui_session.disarmHandshakeInterrupt`: a read
  # abandoned mid-message cannot be resynchronised, which is the right trade
  # while the session is still being built and the wrong one afterwards.
  session.disarmHandshakeInterrupt()

  session.header(rt)
  if command.noFlowOverlay:
    session.setFlowOverlay(false)
  session.setViewportHeight(rt.sourcePaneRows())
  session.learnExtent()
  session.refresh(rt)
  app.notification = describe(session)

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
  paint(driver, rt)

  var running = true
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
      ev = driver.nextEvent(IdlePollMs)
    case ev.kind
    of dekEof:
      # The terminal closed its end. Not an error and not a quit key: the user
      # is gone, and the only correct thing left is to give the tty back.
      running = false
    of dekIdle:
      # THE BUILD IS ADVANCED FROM THE SAME LOOP THAT READS THE KEYBOARD, on
      # exactly `editInteractive`'s rule and for §5's reason. A replay session
      # that switched to Edit mode and typed `:build` owns a process, and a
      # loop that never polled it would leave that build running with no
      # verdict, no output and no `:cancel`.
      if advanceBuild(rt, edit, report = true):
        paint(driver, rt)
    of dekResize:
      size = ev.size
      rt.resize(size.cols, size.rows)
      # THE SOURCE WINDOW FOLLOWS THE PANE, not the terminal. A reflow that
      # changed the profile changed the editor's rectangle, and a `SourceVM`
      # still holding the old height would scroll the execution line off the
      # pane — see `runtime.sourcePaneRows`.
      session.setViewportHeight(rt.sourcePaneRows())
      session.refresh(rt)
      paint(driver, rt)
    of dekToken:
      # RECORDED BEFORE IT IS HANDLED, so the journal of a session that quit on
      # this token still contains it. A `q` written down only after the loop
      # decided to stop would be a journal that replays to a different screen
      # than the one it recorded.
      journal.note(ev.token)
      let outcome = rt.handleToken(ev.token, nowMs())
      if outcome.quit:
        running = false
      else:
        session.applyOutcome(rt, outcome)
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
        if outcome.repaint and
           not driver.holdFrame(journal.pendingReplay > 0):
          paint(driver, rt)

  # THE ARRANGEMENT IS SAVED HERE, AND ONLY IF IT IS THE USER'S. Once per
  # session rather than once per gesture: a drag is a press and a release, and
  # writing through on each would put two file writes inside one pointer
  # movement for a document nobody reads until the next launch.
  #
  # `persistLayoutForSession` answers `lpoDisabled` and touches nothing when
  # `--layout-binding` is off, `lpoQuarantined` when this session started from
  # a document it could not read, and `lpoRemoved` when the arrangement is the
  # profile's own — which is what makes `:reset-layout` reach all the way to
  # the disk instead of leaving a stale document behind.
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

  var size = driver.size()
  let app = newTuiApp()
  app.projectRoot = root
  # THE PRODUCT MODE IS SET BEFORE THE FIRST FRAME, which is Mode-Transitions.md
  # §4 requirement 4 at startup: mode and layout are settled together, so the
  # first paint is Edit mode's arrangement rather than Debug's with an edit
  # pane in it.
  app.modes = initModeRegister(pmEdit)
  app.projectRoot = root

  let rt = newTuiRuntime(app, caps, size.cols, size.rows)

  # THE HOST'S FOUR CAPABILITIES, INJECTED — one function, shared with
  # `interactive`. See `wireEditServices`.
  #
  # `listFiles` CLOSES OVER THE LISTING ALREADY TAKEN rather than walking
  # again, which is how the "before the terminal is claimed" ordering above
  # survives being routed through a function the replay loop also uses. The
  # walk happened on the ordinary screen; this hands back its answer.
  let edit = wireEditServices(rt, root, proc(): EditListResult =
    EditListResult(files: listing.files, truncated: listing.truncated))

  # THE SAME FUNCTION THE TOGGLE CALLS. Opening the first file and filling the
  # tree used to be written out here as well as in `app/runtime.nim`; two
  # copies of one behaviour is §14's subject, and this is the copy no suite
  # would have mutated.
  let furnished = rt.ensureEditWorkspace()
  if furnished.len > 0:
    app.notification = furnished
  discard rt.focus.focusPaneKind(paneEditor)

  paint(driver, rt)

  var loop = true
  while loop:
    let ev = driver.nextEvent(IdlePollMs)
    case ev.kind
    of dekEof:
      loop = false
    of dekIdle:
      # THE BUILD IS ADVANCED FROM THE SAME LOOP THAT READS THE KEYBOARD, which
      # is the whole of §5's cancellability requirement: the key that cancels is
      # read while the compiler runs, and the clock that bounds an unattended
      # session is checked on every tick. See `host/build_runner.pollBuild`.
      if advanceBuild(rt, edit, report = true):
        paint(driver, rt)
    of dekResize:
      size = ev.size
      rt.resize(size.cols, size.rows)
      paint(driver, rt)
    of dekToken:
      let outcome = rt.handleToken(ev.token, nowMs())
      if outcome.quit:
        loop = false
      else:
        # A CANCEL REQUEST IS ACTED ON BEFORE THE NEXT IDLE TICK, so `:cancel`
        # does not wait up to `IdlePollMs` for the process to be signalled.
        discard advanceBuild(rt, edit, report = false)
        if outcome.repaint:
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
