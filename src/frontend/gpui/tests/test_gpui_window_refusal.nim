## test_gpui_window_refusal.nim — **the production `codetracer-gpui`, linked to a
## shim with no window backend, refuses a window launch by name instead of
## exiting 0 having shown nothing.**
##
## Run (needs the `calc` recording under `test-logs/tui-fixtures/` and a
## built `replay-server`, through this repository's development environment):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_window_refusal.nim
##
## The suite provisions its own featureless shim and a release build of the
## production entry point under `build/gpui-refusal/`. This works even when
## the rest of `gpui-shell` uses the shared windowed shim and executable.
##
## `codetracer-pm/issues/2026-10-01-gpui-launch-is-silent-when-no-window-can-open.md`
## measured `ct replay --ui=gpui <trace>` against the featureless shim: rc 0 in
## 0.4 s, no window, no output. The contract that replaces it
## (`codetracer-pm/spec/CLI/ct/ui-selection.md` §8a) is a refusal by kind on
## stderr with exit 3. This suite runs the REAL binary on a REAL recording with
## a window-opening command line and asserts that contract:
##
##   * it exits `ExitNoWindow` (3), PROMPTLY — under a watchdog, so a launch
##     that blocked would fail here rather than hang the lane;
##   * its stderr names the missing window backend and the remedy;
##   * with no `DISPLAY` / `WAYLAND_DISPLAY` as well, it is still the
##     featureless kind, and the missing session is named beside it;
##   * the NEGATIVE TWIN: the same binary, environment and recording with
##     `--report-plan` still exits 0 with a plan, so the refusal is scoped to
##     the window path and the introspection tier works on any host.
##
## The windowed shim's no-display refusal needs a binary linked to the WINDOWED
## shim; it is asserted by
## `ci/test/gpui-window-captures.sh`, which does.
##
## THE SHIM IS CHECKED, NOT ASSUMED. The prerequisite builder pins the
## production executable to an absolute `gpuiShimPath`, and this suite loads
## that exact library to check its capability. Importing the ordinary Nim
## bindings here would instead load whichever shim the surrounding lane uses.
## Shared shim and executable bytes are checked before and after provisioning:
## making this suite green must not break a neighbouring windowed suite.
##
## No mocks: the production entry point, the real shim, the real `replay-server`, a real
## recording.

import replay_prerequisite
import std/[dynlib, os, osproc, sha1, strtabs, strutils, tempfiles, times,
            unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  CalcFixture = "test-logs/tui-fixtures/calc-2f0db4f45192"
  ExitNoWindow = 3
    ## `window_preflight.ExitNoWindow`, restated: this suite asserts the
    ## number the CONTRACT publishes, so importing the constant under test
    ## would let the two move together.
  WatchdogSeconds = 120.0
    ## Generous for a recording that must be opened before the window path is
    ## reached (seconds on a loaded host), and finite: the pre-fix windowed
    ## failure mode was "never returns", and a lane must not inherit it.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
when defined(windows):
  const ProgramName = "codetracer-gpui.exe"
  const ShimName = "gpui_nim_shim.dll"
elif defined(macosx):
  const ProgramName = "codetracer-gpui"
  const ShimName = "libgpui_nim_shim.dylib"
else:
  const ProgramName = "codetracer-gpui"
  const ShimName = "libgpui_nim_shim.so"
let bin = repo / "build/gpui-refusal" / ProgramName
let shim = repo / "build/gpui-refusal/shim/debug" / ShimName
let calc = repo / CalcFixture
let gpuiSource = block:
  let override = getEnv("ISONIM_GPUI_SRC")
  # Match the prerequisite builder's shell `${ISONIM_GPUI_SRC:-...}`:
  # an explicitly empty override selects the ordinary sibling too.
  if override.len > 0: override else: repo.parentDir / "isonim-gpui/src"
let sharedArtifacts = [repo / "build/bin" / ProgramName,
                       gpuiSource.normalizedPath.parentDir /
                         "rust/target/debug" / ShimName]
var
  buildAttempted, buildSucceeded: bool
  sharedBefore, sharedAfter: array[2, string]

proc requirePrereq(ok: bool; what: string) =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.**
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

proc artifactDigest(path: string): string =
  ## Absence must also be preserved: running this suite alone does not need
  ## to create the ordinary executable or shared shim as a side effect.
  if fileExists(path): $secureHashFile(path) else: "<absent>"

proc ensureRefusalBuild() =
  ## Lazy so test discovery does not build anything. Memoise a failed attempt
  ## too: every case fails loudly on that failure, without retrying the build.
  if not buildAttempted:
    buildAttempted = true
    for i, path in sharedArtifacts:
      sharedBefore[i] = artifactDigest(path)
    let r = execCmdEx(quoteShellCommand(@["bash",
      repo / "ci/lib/gpui-refusal-prereqs.sh"]))
    echo r.output
    if r.exitCode == 0:
      for i, path in sharedArtifacts:
        sharedAfter[i] = artifactDigest(path)
      buildSucceeded = true
  requirePrereq(buildSucceeded,
    "isolated GPUI refusal build (ci/lib/gpui-refusal-prereqs.sh; see output above)")

type Run = object
  rc: int
  stdout, stderr: string
  seconds: float
  killed: bool

proc runBinary(args: seq[string]; withDisplay: bool): Run =
  ## One run of the shipped binary under a watchdog. `withDisplay` = false
  ## removes every variable GPUI reads to find a display; true supplies an X
  ## display NAME — nothing listens there, and nothing needs to: the
  ## featureless shim never connects, and the preflight only reads the name.
  ensureRefusalBuild()
  var env = newStringTable()
  for k, v in envPairs():
    if k notin ["DISPLAY", "WAYLAND_DISPLAY", "ZED_HEADLESS"]:
      env[k] = v
  if withDisplay:
    env["DISPLAY"] = ":99"
  let errFile = genTempPath("gpui-window-refusal-", ".err")
  let outFile = genTempPath("gpui-window-refusal-", ".out")
  # Both streams to files rather than pipes: a pipe nobody drains while the
  # watchdog polls can fill and block the child, which would read as a hang.
  let started = epochTime()
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" >" & quoteShell(outFile) & " 2>" &
             quoteShell(errFile), bin] & args,
    env = env, options = {})
  while p.running and epochTime() - started < WatchdogSeconds:
    sleep(50)
  if p.running:
    result.killed = true
    p.kill()
  result.rc = p.waitForExit()
  result.seconds = epochTime() - started
  p.close()
  result.stdout = if fileExists(outFile): readFile(outFile) else: ""
  result.stderr = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(outFile)
  removeFile(errFile)

proc windowArgs(): seq[string] =
  ## A command line that OPENS A WINDOW: none of `--report-plan`,
  ## `--report-window-plan`, `--pixels-out`. `--quit-after-ms` bounds the
  ## event loop in case a window does open (a windowed shim at the baked
  ## path), so even that misconfiguration ends instead of hanging.
  @["--quit-after-ms=5000", "--width=1440", "--height=900", calc]

suite "codetracer-gpui refuses a window launch the featureless shim cannot serve":

  test "the prerequisites are here, and the isolated shim is featureless":
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")
    requirePrereq(existsEnv("REPLAY_SERVER_BIN") and
                  fileExists(getEnv("REPLAY_SERVER_BIN")),
                  "REPLAY_SERVER_BIN naming a built replay-server")
    ensureRefusalBuild()
    requirePrereq(fileExists(bin), bin & " (isolated production build)")
    let library = loadLib(shim)
    requirePrereq(library != nil, "loadable featureless shim: " & shim)
    defer: unloadLib(library)
    let capability = library.symAddr("gpui_has_window_backend")
    requirePrereq(capability != nil, "gpui_has_window_backend in " & shim)
    type BackendProbe = proc(): uint8 {.cdecl.}
    ck cast[BackendProbe](capability)() == 0'u8

  test "provisioning preserves the shared shim and production executable":
    ensureRefusalBuild()
    for i, path in sharedArtifacts:
      checkpoint(path)
      ck sharedBefore[i] == sharedAfter[i]

  test "with a display: exit 3, promptly, naming the missing backend":
    let r = runBinary(windowArgs(), withDisplay = true)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck not r.killed
    ck r.rc == ExitNoWindow
    ck "codetracer-gpui: this build of the GPUI shim has no window backend" in
      r.stderr
    ck "--features gpui-backend" in r.stderr
    # One problem, so one is named: the display is there.
    ck "graphical session" notin r.stderr

  test "with no display either: still the featureless kind, both named":
    let r = runBinary(windowArgs(), withDisplay = false)
    checkpoint("rc " & $r.rc & " in " & $r.seconds & " s; killed: " &
               $r.killed & "; stderr: " & r.stderr)
    ck not r.killed
    ck r.rc == ExitNoWindow
    ck "no window backend" in r.stderr
    when defined(linux) or defined(freebsd):
      ck "no graphical session" in r.stderr

  test "the negative twin: --report-plan still answers, with no display":
    let r = runBinary(@["--report-plan"] & windowArgs(), withDisplay = false)
    checkpoint("rc " & $r.rc & "; stderr: " & r.stderr)
    ck not r.killed
    ck r.rc == 0
    ck "no window backend" notin r.stderr
    ck r.stdout.strip.startsWith("{")

suite "codetracer-gpui window refusal: the tally":
  test "every assertion above ran":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
