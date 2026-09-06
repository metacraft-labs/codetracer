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
## the four this parser accepts. `--theme`, `--goto`, `--serve`,
## `--record-keys`, `--replay-keys` and `--headless` are still refused BY NAME
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
    tckUsageError
      ## The arguments do not name a command. Carries the message a user reads.

  TuiCommand* = object
    ## The parsed command line. A value, so a test can assert on it without a
    ## process.
    case kind*: TuiCommandKind
    of tckOpenTrace:
      tracePath*: string
      flags*: CapabilityFlags
        ## §6.2's four capability overrides, as a value. Carried on this arm
        ## only: `--help` and `--version` print and exit, and a colour depth is
        ## not a property of either.
    of tckUsageError:
      message*: string
    else:
      discard

const
  TuiProgramName* = "codetracer-tui"

  PlannedOptions*: array[6, (string, string)] = [
    ("--theme", "CTUI-10 recorded the theme registry as unbuilt here"),
    ("--goto", "CTUI-8 owns tick seeking; the flag is CTUI-12's entrypoint work"),
    ("--serve", "CTUI-13, the isonim-tui-serve web bridge"),
    ("--record-keys", "CTUI-14, input recording for replay and benchmarks"),
    ("--replay-keys", "CTUI-14, input replay"),
    ("--headless", "CTUI-12, the launcher and packaging milestone")]
    ## §6.2's options that are PUBLISHED AND NOT BUILT, each with the milestone
    ## that owns it.
    ##
    ## Refused by name rather than swallowed, and refused rather than accepted:
    ## the two failure modes this list is written against are a flag that parses
    ## and silently does nothing, and a flag from the published specification
    ## that reports "unknown option". Both leave a user unable to tell a gap in
    ## the product from a mistake in their command line.

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

  var tracePath = ""
  var flags = initCapabilityFlags()
  for arg in args:
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

  # The path is returned exactly as it was written. Resolving it against the
  # process's working directory is `host/`'s job, along with deciding whether
  # it exists — this layer does no filesystem I/O, which is what lets the whole
  # command surface be asserted without one.
  TuiCommand(kind: tckOpenTrace, tracePath: tracePath, flags: flags)
