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
## CTUI-0 recognises `--help` and `--version` and nothing more, by design: the
## milestone's subject is the build ground and the facade boundary, and a flag
## accepted here before the machinery behind it exists would be a promise the
## binary cannot keep. A trace path IS recognised — as `tckOpenTrace` — because
## refusing to parse it would leave `main.nim` unable to say "not yet" with a
## useful message, and "unknown argument" is the wrong diagnosis for an
## argument that is merely not implemented.

import std/strutils

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
    of tckUsageError:
      message*: string
    else:
      discard

const
  TuiProgramName* = "codetracer-tui"

  TuiVersionText* = TuiProgramName & " " & CodeTracerVersionStr
    ## Deliberately the CodeTracer version. The TUI is a front-end of this
    ## repository's debugger, not a separately versioned product, and a second
    ## version number would be a second thing to keep true.

  TuiHelpText* = """
CodeTracer TUI — omniscient time-travel debugging in the terminal.

usage:
  """ & TuiProgramName & """ [options] [<trace-folder>]

options:
  -h, --help       show this help and exit
  -v, --version    show the version and exit

At this milestone (CTUI-0) the binary parses --help and --version and reports
what it cannot yet do. The screen, the panes and the keymap arrive in CTUI-3
and later; see codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org.
"""

proc parseTuiCommand*(args: openArray[string]): TuiCommand =
  ## Classify `args` — the arguments AFTER the program name.
  ##
  ## An empty command line is `tckHelp`: a debugger front-end launched with no
  ## trace has nothing to show, and printing the usage is more useful than an
  ## empty screen or an error.
  if args.len == 0:
    return TuiCommand(kind: tckHelp)

  var tracePath = ""
  for arg in args:
    case arg
    of "-h", "--help":
      return TuiCommand(kind: tckHelp)
    of "-v", "--version":
      return TuiCommand(kind: tckVersion)
    else:
      if arg.startsWith("-"):
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

  # The path is returned exactly as it was written. Resolving it against the
  # process's working directory is `host/`'s job, along with deciding whether
  # it exists — this layer does no filesystem I/O, which is what lets the whole
  # command surface be asserted without one.
  TuiCommand(kind: tckOpenTrace, tracePath: tracePath)
