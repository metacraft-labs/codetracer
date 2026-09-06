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
## ## CTUI-11 adds four flags, and exactly four
##
## §6.2 lists eleven options. CTUI-11 owns `--truecolor`, `--no-color`,
## `--ascii-borders` and `--no-mouse` — the capability overrides — and those are
## the four this parser accepts, alongside `--headless`. `--theme`, `--goto`,
## `--record-keys` and `--replay-keys` are still refused BY NAME
## (see `PlannedOptions`), with the milestone that owns each: a flag that parsed
## and then did nothing is the shape CTUI-0's header refuses, and a flag that
## reported "unknown option" would tell a user who read §6.2 that the
## specification was wrong rather than that the work is not done.
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
        ## §6.2's four capability overrides, as a value.
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

  PlannedOptions*: array[4, (string, string)] = [
    ("--theme",
     "unbuilt here: isonim-tui ships a ThemeRegistry, app/ carries 121" &
     " const CellStyle literals and no wiring to it"),
    ("--goto", "CTUI-14, startup navigation"),
    ("--record-keys", "CTUI-14, input recording for replay and benchmarks"),
    ("--replay-keys", "CTUI-14, input replay")]
    ## §6.2's options that are PUBLISHED AND NOT BUILT, each with the milestone
    ## that owns it.
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
  for i in first .. high(args):
    let arg = args[i]
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
    of "--headless":
      # Idempotent rather than an error: `--headless --headless` asks for the
      # same one thing twice, and there is no second display mode left for it
      # to contradict.
      mode = tckHeadless
    else:
      if arg.startsWith("-"):
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

  # A DISPLAY MODE WITH NOTHING TO DISPLAY is a usage error rather than a help
  # screen. `codetracer-tui --headless` with no trace reached `tckHeadless` with
  # an empty path, and `host/headless` would then have reported the working
  # directory as an unopenable recording — a diagnosis about the wrong thing.
  if mode == tckHeadless and tracePath.len == 0:
    return TuiCommand(
      kind: tckUsageError,
      message: "'--headless' needs a trace folder to open")

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
    TuiCommand(kind: tckHeadless, tracePath: tracePath, flags: flags)
  else:
    TuiCommand(kind: tckOpenTrace, tracePath: tracePath, flags: flags)
