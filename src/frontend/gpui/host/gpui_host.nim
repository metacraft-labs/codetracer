## gpui/host/gpui_host.nim — PLAT-20. **The GPUI front-end's native host: the
## only part of it that opens a recording, and the reason this directory
## carries no `.sdk-consumer` marker.**
##
## ## The exemption is the ABSENCE of a marker, which is why it is stated
##
## `src/frontend/tui/host/`'s own header makes this argument and
## `ci/test/sdk-facade-boundary.sh` records it by name: `backend/stdio_backend`
## and `viewmodel/headless_session` are the two modules `codetracer_embed`
## deliberately withholds, and they are the only ones that spawn a local
## `replay-server` for a `.ct` folder on disk. A front-end living outside this
## repository could not open a local trace through the sanctioned surface at
## all; the capability is not smuggled in, it is isolated in one named
## directory on the far side of the line. The same sentence is true here, word
## for word, which is why the same shape is used.
##
## ## THIS MODULE DOES NOT RE-DERIVE `tui/host/native_host.nim`, AND THAT IS
## ## A DECISION WITH A COST
##
## `openLocalTrace`, `resolveTraceFolder`, `traceFolderProblem`,
## `findReplayServer` and `replayServerRemedy` are not TERMINAL concerns — they
## are "open a local recording" concerns, and every one of them would be
## byte-identical here. Verification-Harness-Traps §14a is the entry about what
## happens when a second author re-derives a solved problem in a second
## directory: *"the problem was solved, in this repository, in a file the second
## author had read. Re-derivation threw the solution away and then hid the loss
## behind a green run."* Its example is an import extractor whose second copy
## missed a spelling the first handled; `traceFolderProblem` has exactly that
## character (it knows that a recording is a *directory* holding `trace.bin`, or
## `rr/`, or a `.ct` container) and a second copy of it would be one more place
## to get that wrong.
##
## So this module imports the terminal front-end's host for those five, and the
## cost is named rather than hidden: **`src/frontend/gpui/host/` now depends on
## `src/frontend/tui/host/`, which is a front-end depending on a front-end.**
## The right home is a neutral `src/frontend/host/` that both import, and moving
## it is a rename across two front-ends' suites rather than PLAT-20's diff. It
## is recorded as a residue in PLAT-20's status block so the next person counts
## it rather than rediscovers it.
##
## What this module does NOT take from there is `stdoutIsTerminal` and the
## terminal-capability negotiation, because those really are terminal concerns
## and a GPUI binary that consulted `isatty` would be answering a question
## nobody asked it.

when defined(js):
  {.error: "src/frontend/gpui/host is native-only: it spawns replay-server.".}

import std/strutils

import tui/host/native_host
export native_host

# The one adapter this front-end needs from the withheld half: a
# `DapStdioBackend` presented as the SDK's `BackendService`.
#
# Re-exported from HERE rather than imported in `main.nim`, so the whole of
# this front-end's reach past `codetracer_embed` is in one file that the
# boundary gate can read — which is what the directory split is for.
import backend/stdio_backend
export stdio_backend

import ../../version_gpui

proc gpuiFrontEndVersion*(): string =
  ## The version this binary reports. One function, so `--version` and any
  ## future about-box cannot part.
  GpuiFrontEndVersion

proc openGpuiTrace*(traceFolder: string): HeadlessDebugSession =
  ## Spawn `replay-server` on `traceFolder` and complete the DAP handshake.
  ##
  ## A thin naming of `native_host.openLocalTrace` rather than a second
  ## implementation — see the module header. It exists so this front-end's
  ## call sites read in this front-end's vocabulary and so the dependency has
  ## exactly one site, which is what makes the residue above a one-line move
  ## rather than a sweep.
  ##
  ## No `DapReadBound` is threaded: CTUI-14's read bound exists because a
  ## stalled adapter can wedge a TERMINAL a user cannot get back, and a window
  ## that has not opened yet is not in that state. A GPUI equivalent is
  ## PLAT-21's, when there is a pane whose data can stall.
  if traceFolder.strip().len == 0:
    raise newException(TuiHostError,
      "codetracer-gpui: name a recording folder")
  openLocalTrace(traceFolder)
