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
import ./app/runtime
import ./app/tui_app
import ./host/capabilities
import ./host/headless
import ./host/key_journal
import ./host/layout_store
import ./host/native_host
import ./host/terminal_driver
import ./host/tui_session

const
  IdlePollMs = 200
    ## How long the loop blocks when nothing is happening.
    ##
    ## A CEILING ON LATENCY FOR NOTHING, and it is not a poll interval: input
    ## and SIGWINCH both wake the `select` immediately, so this only bounds how
    ## long the process sleeps between two events it does not have. It exists so
    ## a partially framed escape sequence — an `ESC` with nothing after it — is
    ## not held forever.

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
  let rt = newTuiRuntime(app, caps, size.cols, size.rows)
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
      discard
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
        if outcome.awaitsMove:
          session.pumpMove()
          session.refresh(rt)
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
