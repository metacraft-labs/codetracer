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

import std/[os, posix, strutils]

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

proc traceFolderProblem*(path: string): string =
  ## "" when `path` holds something `replay-server` can open, and what is wrong
  ## with it otherwise.
  ##
  ## ## Why this exists, measured rather than supposed
  ##
  ## CTUI-11 pointed the shipped binary at a directory that is not a recording
  ## (the checkout root) and it HUNG: the driver had already claimed the
  ## terminal and painted "opening …", `replay-server` refused the folder and
  ## exited 2 without writing one byte of DAP, and the handshake's blocking read
  ## never returned. The user was left with a claimed alternate screen, no
  ## input loop yet running, and no key that could end it — the worst shape a
  ## failure can take in a full-screen application.
  ##
  ## So the shape is checked BEFORE anything is spawned and before the terminal
  ## is claimed. It is a cheap `stat`, and it turns the overwhelmingly common
  ## mistake — a mistyped or wrong path — into a named refusal on the ordinary
  ## screen.
  ##
  ## ## What it does NOT claim
  ##
  ## That the recording is INTACT. A folder with a truncated `trace.bin` passes
  ## here and fails in the engine.
  ##
  ## CTUI-11 recorded that as an OPEN WEDGE — such a folder hung the handshake
  ## behind a claimed alternate screen — and CTUI-14 closed it, in
  ## `backend/stdio_backend.DapReadBound` rather than here. The division is the
  ## point and is worth stating: THIS function refuses a folder that is not a
  ## recording, cheaply and before anything is spawned; the BOUND survives a
  ## folder that is a recording's shape and is not a recording, which no `stat`
  ## can tell apart from one that is. `openLocalTrace` below installs it.
  ##
  ## ## The three shapes
  ##
  ## The same three `src/frontend/tui/tests/fixtures/fixture_provider.
  ## isUsableTraceDir` recognises, which are in turn the ones
  ## `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim` has always
  ## recognised. Spelled again here rather than shared, because that one is a
  ## TEST helper and a shipped binary must not depend on the test tree; the two
  ## are cross-referenced so a fourth shape is added to both.
  if not dirExists(path):
    return "no such folder"
  if fileExists(path / "trace.bin"):
    return ""
  if dirExists(path / "rr"):
    return ""
  for kind, entry in walkDir(path):
    if kind == pcFile and entry.endsWith(".ct"):
      return ""
  "it holds no `trace.bin`, no `rr/` and no `.ct` container, so it is not a " &
  "CodeTracer recording"

const
  DefaultHandshakeMs* = 30_000
    ## How long the TUI waits for ONE message from `replay-server` before it
    ## gives the terminal back and says so.
    ##
    ## THIRTY SECONDS IS DELIBERATELY GENEROUS, and it can be because it is not
    ## the only way out: the same bound watches the keyboard, so an attended
    ## session never waits this out — `Ctrl+c` ends it at once. What the clock
    ## is for is the UNATTENDED session, where there is nobody to press
    ## anything: a `ct tui` in a pane nobody is watching, or a CI job. A budget
    ## tight enough to be felt would instead have to be defended against every
    ## slow recording on every loaded machine, and losing that argument means
    ## refusing to open a trace that was merely slow.
    ##
    ## PER MESSAGE, not per session. See `DapReadBound.timeoutMs`.
  HandshakeEnvVar* = "CODETRACER_TUI_HANDSHAKE_MS"
    ## Overrides `DefaultHandshakeMs`, in milliseconds.
    ##
    ## NOT A COMMAND-LINE FLAG. §6.2 is a published surface and this is a knob
    ## for a test that needs the clock to fire in seconds rather than in
    ## half a minute — `tests/real_terminal/test_real_pty_lifecycle.nim` is the
    ## reason it exists. `app/cli.parseTuiCommand` therefore never sees it and
    ## `TuiHelpText` never mentions it.

proc handshakeBudgetMs*(): int =
  ## The per-message budget this process will use, from the environment or
  ## from `DefaultHandshakeMs`.
  ##
  ## A value that does not parse, or that is not positive, falls back to the
  ## default rather than disabling the bound: "the clock is off" is exactly the
  ## state this milestone exists to remove, and it must not be reachable by
  ## mistyping an environment variable.
  let raw = getEnv(HandshakeEnvVar, "")
  if raw.len == 0:
    return DefaultHandshakeMs
  try:
    let parsed = parseInt(raw.strip())
    if parsed > 0: parsed else: DefaultHandshakeMs
  except ValueError:
    DefaultHandshakeMs

proc openLocalTrace*(traceFolder: string;
                     bound: DapReadBound = DapReadBound(interruptFd: -1)
                    ): HeadlessDebugSession =
  ## Spawn `replay-server` on `traceFolder` and complete the DAP handshake.
  ##
  ## The one operation in the whole TUI that the Embed SDK facade cannot
  ## express, and therefore the one that decided this directory exists.
  ##
  ## `bound` is CTUI-14's clock and escape hatch. It defaults to the zero value
  ## so a caller that has no terminal to lose — a fixture builder, a probe —
  ## keeps the reads it always had; `main.nim` builds a real one.
  let resolved = resolveTraceFolder(traceFolder)
  let problem = traceFolderProblem(resolved)
  if problem.len > 0:
    raiseHost(resolved & ": " & problem)
  let bin = findReplayServer()
  if bin.len == 0:
    raiseHost(replayServerRemedy())
  newHeadlessDebugSession(resolved, bin, handshake = bound)

proc stdoutIsTerminal*(): bool =
  ## Whether standard output is a terminal.
  ##
  ## `isatty` is in `std/posix`, which is exactly the kind of import the
  ## `app/` layer may not make — the question "am I attached to a terminal" is
  ## the definition of a host concern. CTUI-11 builds capability negotiation on
  ## top of this; CTUI-0 uses it to decide whether `main.nim` may assume a
  ## screen.
  isatty(STDOUT_FILENO) == 1
