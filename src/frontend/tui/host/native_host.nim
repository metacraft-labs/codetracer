## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
##
## A module here may import everything `src/frontend/tui/app/` may, and
## additionally `backend/stdio_backend`, `viewmodel/headless_session`,
## `std/osproc`, `std/posix` and `nim_pty`. That is not a relaxation of the
## boundary; it is where the boundary is drawn.
##
## The reason is in CodeTracer-Embed-SDK.md §3.2 and is worth restating,
## because it is the argument that put the TUI in this repository at all:
## `codetracer_embed` deliberately withholds `backend/stdio_backend` and
## `viewmodel/headless_session` — the only modules that spawn a local
## `replay-server` for a `.ct` folder on disk. A front-end that lived outside
## this repo could therefore not open a local trace through the sanctioned
## surface at all. So the capability is not smuggled in; it is isolated in one
## named directory, on the other side of a line that
## `ci/test/sdk-facade-boundary.sh` records as an explicit exemption and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` enforces from the
## `app/` side.
##
## This directory carries NO `.sdk-consumer` marker, and that absence is
## load-bearing: adding one would make every module here a declared consumer
## and the facade guard would immediately, correctly, fail.
##
## host/native_host.nim — the process-owning side of the terminal front-end.
##
## ## What this is
##
## The counterpart of `viewmodel/headless_session.nim` for a terminal rather
## than for a test suite: it resolves a trace folder against the real
## filesystem, finds `replay-server` the way every other suite in this repo
## finds it, spawns it, and hands the resulting `BackendService` to
## `app/tui_app.nim`, which cannot build one.
##
## ## What it is not
##
## It is not the application. It holds no views, no layout and no ViewModel
## state, and nothing here is reactive. `TuiApp` is handed a backend and is
## otherwise unaware that a process exists — which is what lets the whole
## `app/` layer be exercised at Tier 1 with no child process at all.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it spawns replay-server.".}

import std/[os, posix]

import headless_session
export headless_session

type
  TuiHostError* = object of CatchableError
    ## A host-side failure a user can act on: no such trace folder, no
    ## `replay-server`. Every message names what to do about it, because the
    ## alternative — a stack trace out of the DAP handshake — diagnoses the
    ## symptom rather than the cause.

proc raiseHost(msg: string) {.noreturn.} =
  raise newException(TuiHostError, msg)

proc repoRoot(): string =
  ## The checkout this binary was built from, found by walking up from this
  ## source file until a marker appears.
  ##
  ## `currentSourcePath` rather than `getAppDir`: the test lane's binaries live
  ## in a nimcache directory that is nowhere near the checkout, and resolving
  ## `replay-server` relative to the executable would find nothing there. The
  ## markers are the same pair the ViewModel suites walk for.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raiseHost("could not locate the codetracer checkout from " &
            currentSourcePath())

proc findReplayServer*(): string =
  ## Where `replay-server` is, or "" when it has not been built.
  ##
  ## The search order is the one `src/frontend/viewmodel/tests/unit/
  ## test_column_evm_vm.nim` and the rest of the headless suites already use —
  ## `REPLAY_SERVER_BIN`, then the debug build tree, then cargo's own output
  ## directories — because a front-end that looked somewhere else would find a
  ## different binary than the tests do, which is a difference nobody would
  ## notice until it mattered.
  ##
  ## Returns "" rather than raising: a caller that only wants `--version` must
  ## not need a backend, and CTUI-1's fixture provider needs to be able to
  ## report the absence as a named, counted prerequisite rather than catch an
  ## exception.
  let envBin = getEnv("REPLAY_SERVER_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let root = repoRoot()
  for candidate in [
      root / "src" / "build-debug" / "bin" / "replay-server",
      root / "src" / "db-backend" / "target" / "debug" / "replay-server",
      root / "src" / "db-backend" / "target" / "release" / "replay-server"]:
    if fileExists(candidate):
      return candidate
  ""

proc replayServerRemedy*(): string =
  ## What to tell a user whose `replay-server` is missing. One string, so the
  ## host and every future caller name the same command.
  "no replay-server found; set REPLAY_SERVER_BIN, or build one with " &
  "`cd src/db-backend && cargo build`"

proc resolveTraceFolder*(path: string): string =
  ## Turn a command-line trace path into an absolute directory, or fail saying
  ## why.
  ##
  ## `app/cli.nim` returns the path exactly as it was typed and does no
  ## filesystem I/O — resolving it against the process's working directory is
  ## this side of the line, and so is deciding that it does not exist.
  if path.len == 0:
    raiseHost("no trace folder given")
  let absolute = absolutePath(path.expandTilde())
  if not dirExists(absolute):
    if fileExists(absolute):
      raiseHost("'" & path & "' is a file; a CodeTracer trace is a folder")
    raiseHost("no such trace folder: " & absolute)
  absolute

proc openLocalTrace*(traceFolder: string): HeadlessDebugSession =
  ## Spawn `replay-server` on `traceFolder` and complete the DAP handshake.
  ##
  ## The one operation in the whole TUI that the Embed SDK facade cannot
  ## express, and therefore the one that decided this directory exists.
  let resolved = resolveTraceFolder(traceFolder)
  let bin = findReplayServer()
  if bin.len == 0:
    raiseHost(replayServerRemedy())
  newHeadlessDebugSession(resolved, bin)

proc stdoutIsTerminal*(): bool =
  ## Whether standard output is a terminal.
  ##
  ## `isatty` is in `std/posix`, which is exactly the kind of import the
  ## `app/` layer may not make — the question "am I attached to a terminal" is
  ## the definition of a host concern. CTUI-11 builds capability negotiation on
  ## top of this; CTUI-0 uses it to decide whether `main.nim` may assume a
  ## screen.
  isatty(STDOUT_FILENO) == 1
