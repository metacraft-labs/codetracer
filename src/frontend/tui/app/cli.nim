## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
##
## A module here may import `codetracer_embed`, `headless_app`, `isonim`,
## `isonim_tui` and `std/*` modules that touch neither a process nor a
## terminal. Nothing else. In particular it may not import
## `backend/stdio_backend`, `viewmodel/headless_session`, `std/osproc` or
## `std/posix` — those are `src/frontend/tui/host/`'s, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` walks this directory's
## import graph on every run to keep the rule a fact rather than a convention.
##
## app/cli.nim — the command line, as a value.
##
## ## What this is
##
## `parseTuiCommand` turns `argv` into a `TuiCommand` and does nothing else: it
## opens no trace, prints nothing, and exits nowhere. That is what makes the
## whole command surface testable without a terminal, and it is the same shape
## the layer rule above asks for one level up — the decision lives in `app/`,
## the effect lives in `host/`.
##
## CTUI-0 recognised `--help` and `--version` and nothing more, by design: a
## flag accepted before the machinery behind it exists would be a promise the
## binary cannot keep. A trace path IS recognised — as `tckOpenTrace` — because
## refusing to parse it would leave `main.nim` unable to say "not yet" with a
## useful message, and "unknown argument" is the wrong diagnosis for an
## argument that is merely not implemented.
##
## ## CTUI-11 adds four flags; CTUI-14 adds the last four, and the list is now
## ## §6.2 ENTIRE
##
## §6.2 lists eleven options. CTUI-11 owned `--truecolor`, `--no-color`,
## `--ascii-borders` and `--no-mouse` — the capability overrides — alongside
## `--headless`. CTUI-14 adds `-t/--theme`, `--goto`, `--record-keys` and
## `--replay-keys`, which empties `PlannedOptions` for the first time in this
## campaign. That is the interesting fact about this file now: **there is no
## published option this binary refuses**, and the machinery that reported the
## refusals is kept rather than deleted, because it is the shape the NEXT
## published-before-built option needs and because
## `app/tests/test_capability_resolution.nim` asserts the rule it enforces.
##
## The four this milestone adds are not all the same kind of thing, and the type
## says so:
##
##   * `--theme` is a CAPABILITY override like the other four. It lands in
##     `CapabilityFlags` and `app/theme/degradation` decides what it means.
##   * `--goto` is a STARTUP NAVIGATION. It is a tick, it is applied once before
##     the first debugger frame, and nothing reads it afterwards.
##   * `--record-keys` / `--replay-keys` are an INPUT SOURCE and an input SINK.
##     They are the pair §6.2 publishes together and they are what makes a
##     hundred-step benchmark or a reported bug reproducible key for key.
##
## The overrides land in a `CapabilityFlags` value and nothing else. Deciding
## what they MEAN is `app/theme/capabilities.resolveCapabilities`, which is a
## pure function of that value and of the environment; this module does not
## know what a colour depth is.

import std/strutils

import ./theme/capabilities

# The product's own version, not a second one. `src/ct/version.nim` imports
# `strutils` and nothing else, so reaching it costs nothing and cannot drag a
# host dependency into this layer. Spelled relatively because `src/` is not on
# this lane's module path, and adding it would put 40 top-level module names
# one ambiguous import away.
import ../../../ct/version

type
  TuiCommandKind* = enum
    ## What `argv` asked for.
    tckHelp
    tckVersion
    tckOpenTrace
      ## A trace path was given. CTUI-0 parses it and `main.nim` reports that
      ## opening is not wired yet; CTUI-1 gives it fixtures and CTUI-3 gives it
      ## a screen.
    tckHeadless
      ## `--headless`. Render one settled §3.1 screen as plain text and exit.
      ##
      ## §6.2 publishes it ("run headlessly without opening a terminal window
      ## (for CI)") and it is the answer to a real dead end: `codetracer-tui
      ## <trace> | cat` used to exit 3 with "there is nothing to draw on", which
      ## is true and unhelpful.
    tckUsageError
      ## The arguments do not name a command. Carries the message a user reads.

  TuiCommand* = object
    ## The parsed command line. A value, so a test can assert on it without a
    ## process.
    ##
    ## The two trace-opening arms share one branch, so a caller can read
    ## `tracePath` and `flags` off either without knowing which mode it got.
    ## `--help` and `--version` are NOT in that branch: a colour depth is not a
    ## property of either, and the type is what says so.
    case kind*: TuiCommandKind
    of tckOpenTrace, tckHeadless:
      tracePath*: string
      flags*: CapabilityFlags
        ## §6.2's five capability overrides, as a value — the four CTUI-11
        ## parsed plus CTUI-14's `--theme`.
      gotoTick*: int64
        ## `--goto=<tick>`, or `NoGotoTick` when it was not given.
        ##
        ## SIGNED, and the parser refuses a negative one, so "not given" and
        ## "given as 0" are different values: tick 0 is the entry point of every
        ## recording and is a perfectly ordinary thing to ask for.
      recordKeys*: string
      replayKeys*: string
        ## `--record-keys=<file>` and `--replay-keys=<file>`, or "".
      layoutBinding*: bool
        ## `--layout-binding` — PLAT-6's rearrangeable layout, OFF BY DEFAULT.
        ##
        ## A MODE RATHER THAN A CAPABILITY, which is why it is a `bool` here
        ## and not a field of `CapabilityFlags`: it says nothing about what the
        ## terminal can do. With it the front-end gives itself a
        ## `LayoutBinding` (`app/runtime.enableLayoutBinding`), the `:`
        ## prompt's twelve layout verbs — `:move-tab`, `:dock`, `:resize`, … —
        ## reach it, and so does the MOUSE: `runtime.handleToken` decodes an
        ## SGR-1006 report and hands it to `binding.onMouse`, so a tab can be
        ## dragged, a pane docked and a tab strip scrolled with a pointer.
        ## **And the arrangement is REMEMBERED**, per recording, under the
        ## user's own state directory — `app/layout/persistence.nim` decides
        ## where and what happens to a document this build cannot read, and
        ## `host/layout_store.nim` is the only thing that opens it.
        ## Without it the shell paints the session's own `LayoutNode` exactly as
        ## CTUI-3 painted it, those words are unknown commands, and a mouse
        ## report is the inert token it has always been — the decoder is not
        ## even called, and **no layout document is read, written or removed**:
        ## `host/layout_store` computes no path without a binding, so the state
        ## directory is not touched, not even by a `stat`.
        ##
        ## OPT-IN, and the reason is recorded at `app/runtime
        ## .enableLayoutBinding`: a binding's tree is a CLONE of the session's,
        ## so enabling one by default would give the terminal a second layout
        ## authority. The divergence that would cause is latent today (nothing
        ## calls `headless_app.activatePane`), and the flag is what keeps it
        ## latent while the gesture surface is reachable for anybody who asks.
    of tckUsageError:
      message*: string
    else:
      discard

const
  TuiProgramName* = "codetracer-tui"

  LauncherCommandNames*: array[2, string] = ["tui", "ct-tui"]
    ## The command words `packaging/codetracer-tui.caps` declares, and the
    ## reason this parser has to know them at all — CTUI-12.
    ##
    ## THE LAUNCHER DOES NOT STRIP THE COMMAND WORD. `codetracer-launcher/src/
    ## launcher.nim` overwrites `argv[0]` with the resolved binary path and
    ## `execv`s the ORIGINAL argv, so `ct tui <trace>` reaches this process as
    ## `[<binpath>, "tui", "<trace>"]`. That is the same contract the desktop
    ## core lives under (`ct record foo.py` arrives as `codetracer record
    ## foo.py`), and it is what "the launcher execs the binary, with no
    ## subprocess indirection" costs: there is no wrapper in between to rewrite
    ## the arguments. Measured, not assumed — before this, `ct tui <trace>`
    ## reported `expected at most one trace folder, got 'tui' and '<trace>'`.
    ##
    ## Only in FIRST position, so `codetracer-tui --no-mouse tui` still opens a
    ## folder named `tui`. A folder named `tui` or `ct-tui` in the working
    ## directory is shadowed when it is written first and bare; `./tui` names
    ## it unambiguously, the same escape the launcher's own `project ./Makefile`
    ## marker uses.

  DeprecatedCommandNames*: array[2, string] = ["tui", "ct-tui"]
    ## PLAT-1 (`codetracer-specs/CLI/ct/ui-selection.md` §7.1): the `tui`
    ## command word is REPLACED by `ct replay --ui=tui`, and kept as a
    ## deprecated alias **for one release** so every script written between
    ## CTUI-12 and this change keeps working.
    ##
    ## Deliberately a SECOND array with the same members as
    ## `LauncherCommandNames` rather than an alias of it, because the two say
    ## different things and stop being the same list at different times: the
    ## first says "the launcher passes this word through, drop it", which is
    ## true for as long as the caps file declares the word; the second says
    ## "warn about this word", which stops being true the release after next
    ## when the declarations are removed. Aliasing them would make deleting one
    ## silently delete the other.

  NoGotoTick* = -1'i64
    ## `--goto` was not given. See `TuiCommand.gotoTick`.

  PlannedOptions*: array[0, (string, string)] = []
    ## §6.2's options that are PUBLISHED AND NOT BUILT, each with the milestone
    ## that owns it.
    ##
    ## **EMPTY AS OF CTUI-14, and that is a state this list is written to be
    ## able to reach.** The four it carried are built: `--theme` resolves a
    ## palette through `app/theme/degradation.tintsFor`, `--goto` seeks before
    ## the first debugger frame, and `--record-keys` / `--replay-keys` are
    ## `host/key_journal.nim`. The mechanism is deliberately NOT deleted with
    ## its last entry — a published option that is not built is a state this
    ## product will be in again, and the rule
    ## `app/tests/test_capability_resolution.nim` enforces about owners is worth
    ## more than the four lines it costs to keep the list declarable.
    ##
    ## Refused by name rather than swallowed, and refused rather than accepted:
    ## the two failure modes this list is written against are a flag that parses
    ## and silently does nothing, and a flag from the published specification
    ## that reports "unknown option". Both leave a user unable to tell a gap in
    ## the product from a mistake in their command line.
    ##
    ## EVERY OWNER NAMES AN UNLANDED MILESTONE, OR NAMES NO MILESTONE AT ALL.
    ## That is the rule `app/tests/test_capability_resolution.nim` enforces, and
    ## it is what makes this list a promise rather than a fossil: a milestone
    ## that has landed — or that has been CUT — cannot owe anybody a flag. Two
    ## entries broke it and both are fixed here: `--goto` said "the flag is
    ## CTUI-12's entrypoint work" and CTUI-12 shipped without it (it is
    ## CTUI-14's now), and `--theme` credited CTUI-10 for a MEASUREMENT, which
    ## reads as ownership; that entry now states the finding and names no
    ## milestone, because none owns it.
    ##
    ## `--headless` IS OFF THIS LIST BECAUSE IT IS BUILT. It was labelled
    ## `CTUI-12, the launcher and packaging milestone` — but CTUI-12's
    ## Deliverables never named it, CTUI-12 is landed, and the message therefore
    ## told a user that a FINISHED milestone owed them a flag. It is now a
    ## parsed mode (`tckHeadless`, `host/headless.nim`).
    ##
    ## `--serve` IS OFF THIS LIST BECAUSE THE FEATURE WAS CUT, not built. CTUI-13
    ## would have served the session to a browser over `isonim-tui-serve`; it was
    ## withdrawn because `ct host` already serves a trace together with the
    ## replay front end, so a browser-hosted terminal emulator duplicated it with
    ## a worse UI. §6.4 of `codetracer-specs/Front-Ends/CodeTracer-TUI.md` points
    ## the reader at `ct host`, and the flag is deliberately absent from §6.2's
    ## published set rather than parked here: nothing owes it.

  ExitOk* = 0
  ExitUnhandled* = 1
  ExitUsage* = 2
  ExitNoTerminal* = 3
    ## There is a trace and there is no screen to draw it on. Distinguishable
    ## from a usage error on purpose: `codetracer-tui trace | cat` is a correct
    ## command line and an impossible request, and reporting it as a bad
    ## argument would send the user looking at their arguments.
    ##
    ## `--headless` gives that invocation an ANSWER, so the message behind this
    ## code names a flag that exists rather than a milestone.
    ##
    ## The exit codes live HERE rather than in `main.nim` because
    ## `host/headless.nim` returns them and `main.nim` imports it: a constant in
    ## the entrypoint would have to be duplicated by everything the entrypoint
    ## calls.
  ExitEngineStalled* = 4
    ## The folder has a recording's SHAPE, `replay-server` accepted it, and
    ## then the engine stopped answering — CTUI-14.
    ##
    ## Distinct from `ExitUsage` on purpose, and the distinction is measured
    ## rather than stylistic: `host/native_host.traceFolderProblem` refuses a
    ## folder that is not a recording (exit 2, on the ordinary screen, before
    ## anything is spawned), and this is what is left over — a garbage
    ## `trace.bin` passes every `stat` and stalls the DAP handshake. Reporting
    ## that as a usage error would send a user to inspect a command line that
    ## was correct.

  TuiVersionText* = TuiProgramName & " " & CodeTracerVersionStr
    ## Deliberately the CodeTracer version. The TUI is a front-end of this
    ## repository's debugger, not a separately versioned product, and a second
    ## version number would be a second thing to keep true.

  TuiHelpText* = """
CodeTracer TUI — omniscient time-travel debugging in the terminal.

usage:
  """ & TuiProgramName & """ [options] [<trace-folder>]

options:
  -h, --help         show this help and exit
  -v, --version      show the version and exit
  --truecolor        force 24-bit colour, overriding what the terminal claims
  --no-color         monochrome: weight, underline and glyph carry every state
  --ascii-borders    draw + - | instead of the Unicode box-drawing glyphs
  --no-mouse         do not ask the terminal for mouse reporting
  -t, --theme=NAME   dark (default), light, plain, monokai
  --goto=TICK        seek to TICK before the first debugger frame
  --record-keys=FILE write every input token to FILE, one per line
  --replay-keys=FILE read input from FILE instead of the keyboard, then exit
  --layout-binding   let : and the mouse rearrange the panes, and remember them
  --headless         render one screen as plain text and exit — for CI

The capability flags always beat the environment probe. With none of them, the
colour depth comes from COLORTERM / TERM / TERM_PROGRAM, the border set from
the UTF-8 locale, and synchronized output (DEC 2026) from the terminal's own
identity; run with a flag to see the resolved set named on the status line.

Keys: q or Ctrl+c quits, n / F10 steps over, s / F11 steps into, f steps out,
c continues, p / b / rf / rc do each in reverse, [ ] { } seek by call and by
mutation, gg and G jump to the ends, Tab cycles panes, : opens the command
prompt and / searches. The full table is §4.2 of
codetracer-specs/Front-Ends/CodeTracer-TUI.md.
"""

func deprecatedCommandWord*(args: openArray[string]): string =
  ## The deprecated launcher command word `args` begins with, or "".
  ##
  ## FIRST POSITION ONLY, exactly like `parseTuiCommand`'s own stripping — a
  ## folder called `tui` named later on the line is a folder, not a command
  ## word, and warning about it would be a message about somebody's directory.
  ##
  ## A `func` over an `openArray` and not a side effect: `main.nim` prints the
  ## line, `app/tests/test_cli_parsing.nim` asserts the decision, and there is
  ## no arrangement in which the warning can be emitted twice for one argv
  ## because the only caller is the entrypoint.
  if args.len == 0:
    return ""
  for name in DeprecatedCommandNames:
    if args[0] == name:
      return name
  ""

func deprecationLine*(word: string): string =
  ## The ONE line §7.1 asks for: it names the replacement and says when the
  ## alias goes away, and it is a single line because a paragraph on stderr in
  ## front of a full-screen application is noise a user cannot read anyway.
  TuiProgramName & ": warning: 'ct " & word & "' is deprecated and will be" &
  " removed after the next release; use 'ct replay --ui=tui <trace>'"

proc plannedOption(arg: string): (bool, string) =
  ## Whether `arg` names one of §6.2's published-but-unbuilt options, and the
  ## milestone that owns it.
  ##
  ## Matched on the option NAME, so `--goto=1200` is recognised as `--goto`
  ## rather than reported as an unknown option that happens to start the same
  ## way. That distinction is the reason this is a function and not an `in`.
  let name = if arg.contains('='): arg[0 ..< arg.find('=')] else: arg
  for (option, owner) in PlannedOptions:
    if name == option:
      return (true, owner)
  (false, "")

proc optionValue(arg: string; name: string): (bool, string) =
  ## `("--goto=17", "--goto")` -> `(true, "17")`. `(false, "")` for any other
  ## option.
  ##
  ## `--goto=<value>` ONLY, and never `--goto <value>`. §6.2 writes every one of
  ## these with an `=`, and accepting the separated spelling would make a
  ## mistyped flag swallow the trace path: `codetracer-tui --got 400 trace`
  ## would then be a run with two positional arguments rather than a named
  ## refusal.
  if arg == name:
    return (true, "")
  if arg.startsWith(name & "="):
    return (true, arg[name.len + 1 .. ^1])
  (false, "")

proc parseTuiCommand*(args: openArray[string]): TuiCommand =
  ## Classify `args` — the arguments AFTER the program name.
  ##
  ## An empty command line is `tckHelp`: a debugger front-end launched with no
  ## trace has nothing to show, and printing the usage is more useful than an
  ## empty screen or an error.
  if args.len == 0:
    return TuiCommand(kind: tckHelp)

  # THE LAUNCHER'S COMMAND WORD, DROPPED HERE AND NOWHERE ELSE. See
  # `LauncherCommandNames`. `low(args)` rather than `0`: `args` is an
  # `openArray` and a caller may hand it a slice.
  var first = low(args)
  if args[first] in LauncherCommandNames:
    inc first
  if first > high(args):
    # `ct tui` with nothing after it. The same answer an empty command line
    # gets, for the same reason: a debugger front-end with no trace has
    # nothing to show.
    return TuiCommand(kind: tckHelp)

  var tracePath = ""
  var flags = initCapabilityFlags()
  var mode = tckOpenTrace
  var gotoTick = NoGotoTick
  var recordKeys = ""
  var replayKeys = ""
  var layoutBinding = false
  var i = first
  while i <= high(args):
    let arg = args[i]
    inc i
    case arg
    of "-h", "--help":
      return TuiCommand(kind: tckHelp)
    of "-v", "--version":
      return TuiCommand(kind: tckVersion)
    of "--truecolor":
      flags.forceTrueColor = true
    of "--no-color":
      flags.noColor = true
    of "--ascii-borders":
      flags.asciiBorders = true
    of "--no-mouse":
      flags.noMouse = true
    of "--layout-binding":
      # Idempotent, like `--headless`: asking for the same one thing twice is
      # not a contradiction and there is no second arrangement mode for it to
      # disagree with.
      layoutBinding = true
    of "--headless":
      # Idempotent rather than an error: `--headless --headless` asks for the
      # same one thing twice, and there is no second display mode left for it
      # to contradict.
      mode = tckHeadless
    of "-t":
      # THE ONLY SHORT OPTION §6.2 GIVES A VALUE TO, and it is written
      # `-t, --theme=<name>` there, so the separated spelling is the one a user
      # of the short form will type.
      if i > high(args):
        return TuiCommand(
          kind: tckUsageError,
          message: "'-t' needs a theme name (" & themeNames() & ")")
      let (ok, theme) = parseTheme(args[i])
      inc i
      if not ok:
        return TuiCommand(
          kind: tckUsageError,
          message: "unknown theme '" & args[i - 1] & "'; pick one of " &
                   themeNames())
      flags.theme = theme
    else:
      if arg.startsWith("-"):
        block options:
          let (isTheme, themeName) = optionValue(arg, "--theme")
          if isTheme:
            let (ok, theme) = parseTheme(themeName)
            if not ok:
              return TuiCommand(
                kind: tckUsageError,
                message: "unknown theme '" & themeName & "'; pick one of " &
                         themeNames())
            flags.theme = theme
            break options
          let (isGoto, tickText) = optionValue(arg, "--goto")
          if isGoto:
            var tick = NoGotoTick
            try:
              tick = parseBiggestInt(tickText)
            except ValueError:
              return TuiCommand(
                kind: tckUsageError,
                message: "'--goto' takes a tick number, not '" & tickText & "'")
            if tick < 0:
              # A NEGATIVE TICK IS NOT A POSITION, and it is refused rather
              # than clamped to 0: `--goto=-1` is `NoGotoTick`'s own value, and
              # a clamp would make "seek to the start" and "do not seek"
              # indistinguishable inside the parsed command.
              return TuiCommand(
                kind: tckUsageError,
                message: "'--goto' takes a tick at or after 0, not '" &
                         tickText & "'")
            gotoTick = tick
            break options
          let (isRecord, recordPath) = optionValue(arg, "--record-keys")
          if isRecord:
            if recordPath.len == 0:
              return TuiCommand(
                kind: tckUsageError,
                message: "'--record-keys' needs a file to write to")
            recordKeys = recordPath
            break options
          let (isReplay, replayPath) = optionValue(arg, "--replay-keys")
          if isReplay:
            if replayPath.len == 0:
              return TuiCommand(
                kind: tckUsageError,
                message: "'--replay-keys' needs a file to read from")
            replayKeys = replayPath
            break options
          let (planned, owner) = plannedOption(arg)
          if planned:
            return TuiCommand(
              kind: tckUsageError,
              message: "'" & arg & "' is in CodeTracer-TUI.md §6.2 and is not" &
                       " built yet (" & owner & ")")
          return TuiCommand(
            kind: tckUsageError,
            message: "unknown option '" & arg & "'; try '" & TuiProgramName &
                     " --help'")
      else:
        if tracePath.len > 0:
          return TuiCommand(
            kind: tckUsageError,
            message: "expected at most one trace folder, got '" & tracePath &
                     "' and '" & arg & "'")
        tracePath = arg

  # CONTRADICTORY FLAGS ARE A USAGE ERROR, not a precedence rule. `--truecolor`
  # says "24-bit whatever the terminal claims" and `--no-color` says "no colour
  # at all"; any ordering `resolveCapabilities` chose between them would be this
  # program inventing an intent the user did not express, and the user would
  # learn which one lost only by looking at the screen.
  if flags.forceTrueColor and flags.noColor:
    return TuiCommand(
      kind: tckUsageError,
      message: "--truecolor and --no-color contradict each other; pass one")

  # `--theme=plain` IS A COLOUR DECISION, so it can contradict one. It resolves
  # the ladder to monochrome (`app/theme/capabilities.resolveColorDepth`), which
  # is the opposite of what `--truecolor` asks for; the two are refused together
  # for exactly the reason above rather than ordered.
  if flags.theme == utPlain and flags.forceTrueColor:
    return TuiCommand(
      kind: tckUsageError,
      message: "--theme=plain and --truecolor contradict each other; pass one")

  # …AND `--record-keys` / `--replay-keys` CONTRADICT EACH OTHER TOO, for a
  # different reason: `--replay-keys` reads a journal and exits, so a recording
  # made during it would be a copy of its own input file. Refused rather than
  # quietly producing one.
  if recordKeys.len > 0 and replayKeys.len > 0:
    return TuiCommand(
      kind: tckUsageError,
      message: "--record-keys and --replay-keys contradict each other;" &
               " a replay would only record its own input back")

  # A DISPLAY MODE WITH NOTHING TO DISPLAY is a usage error rather than a help
  # screen. `codetracer-tui --headless` with no trace reached `tckHeadless` with
  # an empty path, and `host/headless` would then have reported the working
  # directory as an unopenable recording — a diagnosis about the wrong thing.
  if mode == tckHeadless and tracePath.len == 0:
    return TuiCommand(
      kind: tckUsageError,
      message: "'--headless' needs a trace folder to open")

  # `--headless` HAS NO INPUT LOOP, SO THE TWO JOURNAL FLAGS ARE REFUSED RATHER
  # THAN ACCEPTED AND IGNORED. This list's own rule (see `PlannedOptions`) is
  # that "a flag that parses and silently does nothing" is one of the two
  # failure modes it exists to prevent, and `--headless --replay-keys=f` was
  # exactly that: it parsed, it reached `tckHeadless`, and `host/headless.nim`
  # never read the field. The mode renders ONE settled screen as plain text and
  # exits; a replayed session's interest is in the frames BETWEEN its keys,
  # which one frame at the end throws away, and there is no keyboard for
  # `--record-keys` to record. Named individually so the message says which.
  #
  # `--goto` is NOT on this list, and the difference is the point: it is a
  # startup navigation applied before the first paint, and the one frame
  # `--headless` renders IS the first paint. It is honoured (`host/headless.
  # runHeadless` takes the tick and dispatches the same `kaSeekToTick`), which
  # is what makes `codetracer-tui --headless --goto=200 <trace>` a usable CI
  # assertion about a specific point in a recording.
  if mode == tckHeadless:
    for (given, option) in [(recordKeys.len > 0, "--record-keys"),
                            (replayKeys.len > 0, "--replay-keys")]:
      if given:
        return TuiCommand(
          kind: tckUsageError,
          message: "'" & option & "' and '--headless' contradict each other;" &
                   " --headless renders one settled screen and exits, so" &
                   " there is no input loop to " &
                   (if option == "--record-keys": "record from"
                    else: "replay into"))
    # `--layout-binding` IS ON THE SAME LIST AND FOR THE SAME REASON, not
    # accepted and ignored. What the flag buys is a `:` prompt that rearranges
    # the panes; `--headless` renders one settled screen and exits, so there is
    # no prompt to type into and the arrangement it would produce is the
    # default one it started from. That is precisely "a flag that parses and
    # silently does nothing" — see `PlannedOptions`' header on why this file
    # refuses instead.
    if layoutBinding:
      return TuiCommand(
        kind: tckUsageError,
        message: "'--layout-binding' and '--headless' contradict each other;" &
                 " --headless renders one settled screen and exits, so there" &
                 " is no `:` prompt to rearrange anything from")

  # THE SAME RULE FOR THE THREE OPTIONS THAT ACT ON A SESSION. `--goto`,
  # `--record-keys` and `--replay-keys` all describe something to do with a
  # trace, and every one of them is silently nothing without one. Named
  # individually rather than as "one of these", so the message says which.
  if tracePath.len == 0:
    for (given, option) in [(gotoTick != NoGotoTick, "--goto"),
                            (recordKeys.len > 0, "--record-keys"),
                            (replayKeys.len > 0, "--replay-keys"),
                            (layoutBinding, "--layout-binding")]:
      if given:
        return TuiCommand(
          kind: tckUsageError,
          message: "'" & option & "' needs a trace folder to open")
  # The path is returned exactly as it was written. Resolving it against the
  # process's working directory is `host/`'s job, along with deciding whether
  # it exists — this layer does no filesystem I/O, which is what lets the whole
  # command surface be asserted without one.
  # SPELLED AS A `case` rather than as `TuiCommand(kind: mode, …)`: nim will
  # not construct an object variant from a runtime discriminator unless it can
  # prove every branch that value could select carries the fields being set,
  # and `mode` is an ordinary `TuiCommandKind` as far as the compiler knows.
  # Two one-line arms are the price of not having to prove it.
  case mode
  of tckHeadless:
    TuiCommand(kind: tckHeadless, tracePath: tracePath, flags: flags,
               gotoTick: gotoTick, recordKeys: recordKeys,
               replayKeys: replayKeys, layoutBinding: layoutBinding)
  else:
    TuiCommand(kind: tckOpenTrace, tracePath: tracePath, flags: flags,
               gotoTick: gotoTick, recordKeys: recordKeys,
               replayKeys: replayKeys, layoutBinding: layoutBinding)
