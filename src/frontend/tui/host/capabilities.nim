## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
## See `host/native_host.nim`'s header for the full rule, and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## keeps `app/` on the other side of it.
##
## host/capabilities.nim — CTUI-11. The process's environment, read ONCE, and
## turned into the one capability value everything downstream is a function of.
##
## ## What this file is, and what it deliberately is not
##
## It is seven `getEnv` calls and one `isatty`, in one function, feeding
## `app/theme/capabilities.resolveCapabilities`. That is the whole of it, and
## the smallness is the design:
##
##   * **The DECISION is not here.** It is a pure function in `app/`, because
##     CTUI-11 names `app/tests/test_capability_resolution.nim` and describes it
##     as "pure resolution logic, tested as such" — and `app/tests/` may not
##     import this directory. A resolver that lived here could only be tested
##     through a spawned process, which is exactly the coverage the milestone
##     asks NOT to be the only kind.
##   * **The READING is here, and only here.** `std/os.getEnv` is not on
##     `app/`'s forbidden list, so nothing structural would stop a view from
##     asking `COLORTERM` itself. What stops it is that there is one function
##     that answers the question and every consumer is handed its result — the
##     milestone's "one value computed once, not a set of scattered `getEnv`
##     calls", enforced by there being nothing else to call.
##
## ## Non-blocking, and resolved before the first paint
##
## `readTerminalEnv` does no I/O beyond `getEnv` and one `isatty(2)`: no child
## process, no terminal query, no read from a file descriptor. That is CTUI-11's
## risk mitigation taken literally — "probes are environment-only plus a bounded
## non-blocking query" — and it is why §6.3's `tput colors` is answered from
## `TERM` instead of by spawning `tput`. The cost is a handful of microseconds,
## which is what makes the cold-start gate (< 50 ms with probing enabled)
## a measurement of the trace open rather than of the probe.
##
## The ORDER is enforced by `host/terminal_driver.nim`, which takes a resolved
## `TerminalCapabilities` in its constructor: a driver cannot be started without
## one, so there is no path on which a frame is painted before negotiation.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it reads the tty.".}

import std/[os, posix]

import ../app/theme/capabilities

export capabilities

proc readTerminalEnv*(fd: cint = STDOUT_FILENO): TerminalEnv =
  ## Every variable capability resolution reads, plus whether `fd` is a tty.
  ##
  ## `STDOUT_FILENO` by default, matching `host/resize.nim`'s choice and for the
  ## same reason it records: stdout is the descriptor a TUI draws on, and stdin
  ## can be a pipe while stdout is a terminal (`codetracer-tui trace </dev/null`
  ## is a real invocation).
  TerminalEnv(
    term: getEnv("TERM", ""),
    colorterm: getEnv("COLORTERM", ""),
    termProgram: getEnv("TERM_PROGRAM", ""),
    lcAll: getEnv("LC_ALL", ""),
    lcCtype: getEnv("LC_CTYPE", ""),
    lang: getEnv("LANG", ""),
    noColor: getEnv("NO_COLOR", ""),
    isTty: isatty(fd) == 1)

proc negotiateCapabilities*(flags: CapabilityFlags;
                            fd: cint = STDOUT_FILENO): TerminalCapabilities =
  ## THE call the entrypoint makes, once, before anything is drawn.
  ##
  ## Returned rather than stored in a module-level variable: a global would make
  ## "was this resolved before the paint?" a question about execution order that
  ## nothing could answer, and it would make the whole negotiation untestable
  ## twice in one process.
  resolveCapabilities(readTerminalEnv(fd), flags)
