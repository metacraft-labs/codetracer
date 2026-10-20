## test_gpui_window_refusal.nim — **the shipped `codetracer-gpui`, linked to a
## shim with no window backend, refuses a window launch by name instead of
## exiting 0 having shown nothing.**
##
## Run (needs `just build-gpui` over isonim-gpui's DEFAULT, featureless shim —
## what this lane links — the `calc` recording under `test-logs/tui-fixtures/`,
## and `REPLAY_SERVER_BIN`):
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_window_refusal.nim
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
## shim, which this lane does not build; it is asserted by
## `ci/test/gpui-window-captures.sh`, which does.
##
## THE SHIM IS CHECKED, NOT ASSUMED. `isonim_gpui/bindings` resolves the shim
## at compile time to an absolute path, the same one for this test program and
## for `build/bin/codetracer-gpui` (both compile against the same isonim-gpui
## sources, and `just build-gpui` passes no `-d:gpuiShimPath`). So this
## program's own `gpui_has_window_backend()` reports the build the binary under
## test will load, and the first case requires it to be the featureless one: a
## lane that had swapped the windowed shim in at that path (the PLAT-37 capture
## does, temporarily) would otherwise fail every case below for a reason that
## is not this suite's.
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a real
## recording.

import std/[os, osproc, strtabs, strutils, tempfiles, times,
            unittest]

import isonim_gpui/bindings

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
let bin = repo / "build/bin/codetracer-gpui"
let calc = repo / CalcFixture

proc requirePrereq(ok: bool; what: string) =
  ## **A MISSING PREREQUISITE FAILS BY NAME. It does not skip.**
  if not ok:
    raise newException(IOError, "prerequisite missing: " & what)

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

  test "the prerequisites are here, and the shim is the featureless one":
    requirePrereq(fileExists(bin), bin & " (just build-gpui)")
    requirePrereq(dirExists(calc), calc & " (run 'just test-tui' once)")
    requirePrereq(existsEnv("REPLAY_SERVER_BIN") and
                  fileExists(getEnv("REPLAY_SERVER_BIN")),
                  "REPLAY_SERVER_BIN naming a built replay-server")
    requirePrereq(gpui_has_window_backend() == 0'u8,
                  "the FEATURELESS shim at isonim-gpui's rust/target/debug " &
                  "(`just rust-build` there); a windowed build is in its place")
    ck true

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
