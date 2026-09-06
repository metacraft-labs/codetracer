## test_real_launcher_exec.nim — CTUI-12, Tier 2. THE END-TO-END ONE.
##
## ## What only this file can say
##
## CTUI-12: "TermAssert spawns `ct tui <fixture>` and asserts a real TUI frame
## appears, proving the exec path end to end including terminal setup." And its
## verification gate: "`ct tui <trace.ct>` starts the TUI from a packaged
## install."
##
## Both, with nothing between the two ends. The process TermAssert puts in the
## pty is `codetracer-launcher/out/launcher` — the real `ct` — and the frame
## parsed out of that pty is painted by `build/bin/codetracer-tui`, the real
## shipped binary, on a real recording, through a component bundle
## `scripts/build-tui-component.sh` assembled from `packaging/
## codetracer-tui.caps`. Five artifacts, one process, no stubs.
##
## ## WHY THE PTY IS WHERE `execv` IS PROVEN, AND NOT JUST WHERE IT IS SHOWN
##
## `src/tests/launcher/test_launcher_routes_tui.nim` proves exec-not-fork
## arithmetically: the component's `$$` equals the pid `startProcess` returned
## for the launcher, which only holds if the process image was replaced. That
## is the clean proof and it belongs at Tier 1, where a stub can print its pid.
##
## This file proves the same thing a second way, and the second way is the one
## that matters to a user: **`main.nim` refuses to draw when stdout is not a
## terminal.** It calls `stdoutIsTerminal()` (an `isatty` on fd 1) and exits 3
## with "standard output is not a terminal" rather than painting into a pipe. A
## launcher that spawned the front-end as a subprocess — with pipes, as any
## ordinary `startProcess` would — would hand it a non-tty stdout and get
## exactly that refusal. So a frame appearing on this pty is evidence that the
## TUI INHERITED THE LAUNCHER'S OWN FILE DESCRIPTORS, which is what `execv`
## does and what "no subprocess indirection" means in practice. The terminal
## setup — raw mode, the alternate screen, mouse negotiation — is on the far
## side of that same inheritance, which is why the gate names it.
##
## ## THE TWO FRAME BARRIERS, AND WHY THERE ARE TWO
##
## `main.nim` paints TWICE on startup, on purpose: frame 0 is the shell saying
## which trace is being opened, painted BEFORE `replay-server` is spawned;
## frame 1 is the debugger. Both end with the cursor on the bottom-right cell,
## so `waitForCompleteFrame` alone cannot tell them apart — it returns on frame
## 0. `settleOnDebugger` waits for the STATUS ROW to stop saying `opening ` and
## then for the cursor barrier. This is CTUI-11's shape
## (`test_real_capability_negotiation.nim`), reproduced here rather than shared
## because the two suites disagree about what they spawn and sharing it would
## mean a helper that takes the subject as a parameter — which is how a barrier
## ends up waiting for the wrong thing.
##
## ## THE ROUTING CONTROL IS IN THIS FILE, NOT ONLY AT TIER 1
##
## "A frame appeared" is satisfied by any arrangement that starts the TUI,
## including one where the launcher ignored the capability file entirely. So
## the same pty, the same launcher and the same arguments are run against an
## EMPTY component root, and the terminal is asserted to show
## `ct: no component handles 'tui'` and nothing else. The difference between
## the two cases is one directory, and that directory is the packaged install.
##
## ## THE SIZE AND DEPENDENCY GATE, AND THE TWO ARMS THAT FALSIFY IT
##
## CTUI-12's second gate — a recorded size with a regression threshold, and no
## dynamic dependency beyond libc, the C++ runtime and tree-sitter — is asserted
## in the second suite below rather than written into a report, and it lives in
## THIS lane because `just test-tui-real-terminal` depends on `just build-tui`
## while the Tier-1 lane does not. A gate that reads a binary the lane does not
## guarantee is a gate that reports whatever was left in `build/bin` last week.
##
## Both halves were made to fail before the numbers were written down, by
## copying this file to `real_terminal/mutant_probe.nim` (a name neither lane's
## discovery collects), editing the copy, compiling and running it. THE FILE
## ITSELF WAS NEVER EDITED — `docs/tui-testing.md` records what a
## timestamp-preserving restore does to the Tier-2 binary cache, and the cheap
## way to not meet it is to never mutate the original. Measured 2026-09-06:
##
##   * `BinaryCeilingBytes` 14_500_000 -> 1_000_000
##     => `[FAILED] the binary's size is inside the recorded regression band`
##   * `cxxStems` `["libstdc++.", "libgcc_s.", …]` -> `["libNOSUCH."]`
##     => `[FAILED] it needs libc, the C++ runtime and tree-sitter — and
##        nothing else`, reporting
##        `UNEXPLAINED dynamic dependencies: libstdc++.so.6 libgcc_s.so.1`
##
## The `DT_NEEDED` set the second arm reads is, verbatim: `libm.so.6
## librt.so.1 libstdc++.so.6 libtree-sitter.so.0.25 libdl.so.2 libgcc_s.so.1
## libpthread.so.0 libc.so.6`.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[monotimes, options, os, osproc, streams, strutils, times, unittest]

import term_assert

import ../../testing/dual_snap
import ../fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 44

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  TuiBuildRecipe = "just build-tui"
  LauncherRecipe = "cd ../codetracer-launcher && just build"
  FixtureName = "calc"
  Cols = 120
  Rows = 40
    ## 120x40 selects the STANDARD profile (`app/layout/profile.selectProfile`:
    ## `lpCompact` below 35 rows whatever the width, `lpStandard` at 120
    ## columns), so TIMELINE gets a rectangle of its own instead of being a tab
    ## of the state stack. The same geometry CTUI-11's suite uses, so a frame
    ## that differs between the two files differs for a reason other than size.
  NoHandlerText = "ct: no component handles 'tui'"
    ## `S_ERR_NO_HANDLER` + the command, from
    ## `codetracer-launcher/src/install.nim`'s emit block. Not importable: that
    ## string lives in C inside an `--os:standalone` module.
  PaneTitles: array[4, string] = ["CALL STACK", "SOURCE", "VARIABLES", "TIMELINE"]
    ## §3.1's screen, as the pane titles a real frame carries. Asserted as a
    ## counted sweep rather than four loose `contains` calls so a partially
    ## painted screen cannot satisfy "at least one".

  MeasurementDate = "2026-09-06"
  MeasuredBinaryBytes = 13_364_232
    ## `build/bin/codetracer-tui` as `just build-tui` produces it — `--mm:orc
    ## -d:release`, NOT stripped, ten tree-sitter grammars statically archived
    ## in, the runtime dynamic. `wc -c` on a Linux x86-64 host on
    ## `MeasurementDate`. Stripped it is 12_783_664; the shipped artifact is the
    ## unstripped one, so that is what the band below is drawn around.
    ##
    ## This REPLACES the draft's "<15 MB stripped, no dynamic dependencies
    ## except libc/libSystem", which CTUI-0 falsified by reading the link line.
    ## The number is measured rather than budgeted, which is the point: it says
    ## what the product costs today so a change can be seen, not what somebody
    ## hoped it would cost.
    ##
    ## RE-MEASURED AFTER CTUI-13 WAS CUT, and it came back down. The withdrawn
    ## web bridge had taken this to 14_055_704 — `isonim-tui-serve`, the
    ## `std/asynchttpserver` + `asyncnet` + `asyncdispatch` closure,
    ## `isonim-tui`'s `WebDriver`, and 288 KB of `staticRead` xterm.js. All of
    ## it is gone with the feature.
    ##
    ##   13_355_200  CTUI-12
    ##   14_055_704  CTUI-13's bridge + embedded xterm bundle (withdrawn)
    ##   13_364_232  today: the bridge removed, `--headless` KEPT
    ##
    ## The +9_032 bytes over CTUI-12 (+0.068%) is what `--headless` costs on its
    ## own — `host/headless.nim` plus `terminal_driver.plainScreen` /
    ## `plainFrame`. It is a MEASURED number and not a restored one: the value
    ## here was taken from a fresh `just build-tui` after the removal, because
    ## the pre-bridge figure could not have accounted for the flag that
    ## survived the cut.

  BinaryCeilingBytes = 14_500_000
    ## MeasuredBinaryBytes + 8.50%. Wide enough that ordinary work — a pane, a
    ## formatter, a grammar's parser table growing — does not redden the lane on
    ## the day it lands, narrow enough that a link-line accident (a second
    ## grammar archive, a stdlib module pulling in a subsystem) does. When it
    ## trips, RE-MEASURE and move the band in the same change as the growth,
    ## with the new number and the date; do not raise it to make a run green.
    ##
    ## BACK TO CTUI-12'S CEILING, because the growth it had been widened for
    ## (15_300_000) no longer exists. Lowering a ceiling is the same discipline
    ## as raising one: the band is anchored to `MeasuredBinaryBytes`, and
    ## leaving 15_300_000 against a 13_364_232 anchor would have widened the
    ## margin to 14.5% — a band loose enough to let a real link-line accident
    ## through unnoticed.

  BinaryFloorBytes = 6_000_000
    ## The other half of the band, and not a formality. The single largest
    ## member of the grammar archive — `ct_ts_nim_parser.o` — is 8.4 MB on its
    ## own, so a binary under 6 MB cannot be the ten-grammar build: it is a
    ## link that lost the archive, or a stub. Without a floor, "size <= ceiling"
    ## is satisfied by exactly the regression that would matter most.

type
  DepBucket = enum
    ## The three justifications CTUI-12's gate allows, plus everything else.
    blLibc
    blCxx
    blTreeSitter
    blUnexplained

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "could not locate the codetracer checkout from " & currentSourcePath())

let
  root = repoRoot()
  tuiBinary = root / "build" / "bin" / "codetracer-tui"
  launcherBin = root.parentDir / "codetracer-launcher" / "out" / "launcher"
  artifactDir = root / "test-logs" / "ctui12-launcher-exec"
  componentsRoot = artifactDir / "components"
  emptyRoot = artifactDir / "components-empty"

proc buildComponent(): tuple[rc: int, output: string] =
  ## Run the REAL packaging producer over the REAL binary.
  ##
  ## `--link` rather than `--copy`: `host/native_host.repoRoot` walks up from
  ## `currentSourcePath()` — a path baked in at compile time — so the symlink
  ## costs the binary nothing when it looks for `replay-server`, and it saves
  ## the lane a 13 MB copy per run.
  let p = startProcess("/usr/bin/env",
                       args = @["bash", "-euo", "pipefail",
                                root / "scripts" / "build-tui-component.sh",
                                "--out-root", componentsRoot,
                                "--tui-bin", tuiBinary, "--link"],
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

proc bucketOf(lib: string): DepBucket =
  ## Which of CTUI-12's three justifications covers `lib`.
  ##
  ## Matched on the library's STEM rather than on a full soname, because a
  ## soname carries a version (`libtree-sitter.so.0.25`, `libc.so.6`) that moves
  ## with the toolchain and has nothing to do with what the gate is about.
  const
    libcStems = ["libc.", "libm.", "librt.", "libdl.", "libpthread.",
                 "ld-linux", "ld.so", "libSystem."]
    cxxStems = ["libstdc++.", "libgcc_s.", "libc++.", "libc++abi."]
    treeSitterStems = ["libtree-sitter."]
  let name = lib.extractFilename
  for stem in libcStems:
    if name.startsWith(stem): return blLibc
  for stem in cxxStems:
    if name.startsWith(stem): return blCxx
  for stem in treeSitterStems:
    if name.startsWith(stem): return blTreeSitter
  blUnexplained

proc runCapture(exe: string; args: seq[string]): tuple[rc: int, output: string] =
  let p = startProcess(exe, args = args, options = {poUsePath})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

proc neededLibraries(binary: string): seq[string] =
  ## The libraries `binary` DECLARES it needs — `DT_NEEDED` on ELF, the load
  ## commands on Mach-O.
  ##
  ## `readelf -d` rather than `ldd`: `ldd` resolves the whole transitive graph,
  ## and CTUI-12's gate is about what this binary declares. `objdump -p` is the
  ## fallback because a toolchain that ships one usually ships the other, and a
  ## host with NEITHER fails by name rather than silently reporting an empty
  ## list — which would satisfy "nothing unexplained" for free.
  result = @[]
  when defined(macosx):
    let (rc, output) = runCapture("otool", @["-L", binary])
    if rc != 0:
      raise newException(IOError, "otool -L failed on " & binary)
    for line in output.splitLines():
      let trimmed = strutils.strip(line)
      if trimmed.len == 0 or trimmed.endsWith(":"): continue
      let space = trimmed.find(' ')
      result.add(if space < 0: trimmed else: trimmed[0 ..< space])
  else:
    var output = ""
    var got = false
    for tool in ["readelf", "objdump"]:
      let args = if tool == "readelf": @["-d", binary] else: @["-p", binary]
      try:
        let (rc, captured) = runCapture(tool, args)
        if rc == 0:
          output = captured
          got = true
          break
      except OSError:
        discard
    if not got:
      raise newException(IOError,
        "neither `readelf` nor `objdump` is on PATH, so the dynamic " &
        "dependencies of " & binary & " cannot be read — enter the dev shell")
    for line in output.splitLines():
      # readelf: " 0x0000...0001 (NEEDED)  Shared library: [libc.so.6]"
      # objdump: "  NEEDED               libc.so.6"
      if line.contains("(NEEDED)"):
        let open = line.rfind('[')
        let close = line.rfind(']')
        if open >= 0 and close > open:
          result.add line[open + 1 ..< close]
      elif strutils.strip(line).startsWith("NEEDED"):
        let rest = strutils.strip(strutils.strip(line)[len("NEEDED") .. ^1])
        if rest.len > 0:
          result.add rest

proc launcherSession(componentRoot: string; args: seq[string]): TuiTestBuilder =
  ## A pty session running the REAL launcher with a KNOWN environment.
  ##
  ## `CODETRACER_COMPONENTS_ROOT` replaces the user level and suppresses the
  ## absolute system/distro paths (`launcher.collectLevels`); the three
  ## `envRemove`d variables would otherwise let an inherited value add a
  ## discovery level or a registry. The terminal variables are pinned for the
  ## same reason CTUI-11 pins them: the lane inherits whatever terminal the
  ## developer is in, and a case that depended on `COLORTERM` would be
  ## asserting the runner's environment.
  newTuiTest(launcherBin, args)
    .width(Cols).height(Rows)
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE",
               "CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
               "CODETRACER_COMPONENT_DIR")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet("CODETRACER_COMPONENTS_ROOT", componentRoot)

proc statusRowText(sess: var TuiTestSession): string =
  ## The bottom row, right-trimmed.
  ##
  ## `strutils.strip` EXPLICITLY: `docs/tui-testing.md` records that
  ## `unicode.strip` returns an ALL-whitespace string unchanged where
  ## `strutils.strip` returns "". A blank row would otherwise read as 120
  ## characters long and this barrier would never fire.
  strutils.strip(sess.regionText(Rows - 1, 0, Cols, 1), leading = false)

proc screenText(sess: var TuiTestSession): string =
  sess.regionText(0, 0, Cols, Rows)

proc settleOnDebugger(sess: var TuiTestSession; timeoutMs = 60000) =
  ## Wait for FRAME 1 — the debugger — rather than for frame 0.
  ##
  ## The failure is a diagnosis and not a timeout: it names the status row it
  ## saw, whether the child is alive and its exit code, so "the launcher
  ## refused to route", "still opening the trace" and "the binary died" are
  ## three different reports.
  discard sess.drainOutput(30)
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var last = ""
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    last = statusRowText(sess)
    if last.len > 0 and not last.contains("opening "):
      waitForCompleteFrame(sess, Cols, Rows, timeoutMs = 15000)
      return
    if not sess.isAlive:
      raise newException(AssertionFailedError,
        "the launcher's child exited before painting the debugger: status row" &
        " was '" & last & "', exit code " & $sess.exitCode() &
        ", screen:\n" & screenText(sess))
  raise newException(AssertionFailedError,
    "no debugger frame within " & $timeoutMs & " ms: status row was '" &
    last & "', child alive=" & $sess.isAlive & ", screen:\n" & screenText(sess))

template ckDebuggerFrame(sess: var TuiTestSession) =
  ## §3.1's screen, as a counted sweep over `PaneTitles`.
  ##
  ## A sweep rather than four loose assertions, and the count is asserted
  ## against the array's own length: "at least one pane title appeared" is
  ## satisfied by a screen that is three quarters blank.
  let text = screenText(sess)
  checkpoint("status row: " & statusRowText(sess))
  var compared = 0
  for title in PaneTitles:
    inc compared
    ck text.contains(title)
  ck compared == PaneTitles.len

template ckQuitsCleanly(sess: var TuiTestSession) =
  ## `q` is §4.2's quit. Exit 0 EXACTLY: `main.nim` separates a usage error (2)
  ## from "no terminal" (3) and from an unhandled exception (1), and `rc != 0`
  ## would be satisfied by the binary crashing on the way out.
  sess.send("q")
  let status = sess.waitExit(initDuration(seconds = 15))
  checkpoint("exit: " & (if status.isSome: $status.get() else: "none"))
  ck status.isSome
  ck status.get() == 0
  sess.close()

var
  tracePath = ""
  ctSuffixTrace = ""

suite "CTUI-12 Tier 2: `ct tui <trace>` paints the debugger through a packaged install":

  test "every artifact this lane composes exists":
    # FIRST AND SEPARATELY, so a missing build reports as a missing build
    # rather than as a spawn failure inside libvterm several assertions later.
    # None of these is a skip — `docs/tui-testing.md` rule 1.
    if not fileExists(tuiBinary):
      checkpoint("missing " & tuiBinary & " — run `" & TuiBuildRecipe & "`")
    ck fileExists(tuiBinary)
    if not fileExists(launcherBin):
      checkpoint("missing " & launcherBin & " — run `" & LauncherRecipe & "`")
    ck fileExists(launcherBin)
    ck fileExists(root / "packaging" / "codetracer-tui.caps")

    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail &
                 " — `just test-tui` records and caches it, or set $CT_BIN")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    checkpoint("trace: " & tracePath)
    ck dirExists(tracePath)

  test "the packaging script assembles the component from the shipped caps":
    removeDir(artifactDir)
    createDir(artifactDir)
    let built = buildComponent()
    checkpoint("build-tui-component.sh exit " & $built.rc & "\n" & built.output)
    ck built.rc == 0

    var bundle = ""
    for kind, path in walkDir(componentsRoot):
      if kind == pcDir: bundle = path
    checkpoint("bundle: " & bundle)
    ck bundle.len > 0
    ck bundle.extractFilename.startsWith("codetracer-tui@")
    # BYTE-FOR-BYTE, so the routing below is a statement about the file the
    # product ships rather than about one the test wrote.
    ck readFile(bundle / "capabilities") ==
       readFile(root / "packaging" / "codetracer-tui.caps")
    # The symlink resolves to the binary asserted above.
    ck expandFilename(bundle / "bin" / "codetracer-tui") ==
       expandFilename(tuiBinary)

    # The empty root the control case needs, created here so both cases are
    # looking at directories built in the same place by the same run.
    createDir(emptyRoot)
    var emptyCount = 0
    for kind, path in walkDir(emptyRoot):
      inc emptyCount
    ck emptyCount == 0

  test "`ct tui <trace>` paints §3.1's screen in a real terminal":
    # THE MILESTONE, end to end: the launcher is the process in the pty, the
    # capability file chose the component, `execv` replaced the image, and the
    # frame below was painted by the shipped binary onto the launcher's own
    # inherited tty.
    var sess = launcherSession(componentsRoot, @["tui", tracePath]).spawn()
    settleOnDebugger(sess)
    ckDebuggerFrame(sess)
    # THE TERMINAL WAS SET UP, read from the terminal's side rather than from
    # the application's. `mpSgr` is what `?1000h ?1006h` leaves in libvterm's
    # extended state, and it is unreachable for a process whose stdout is a
    # pipe: `main.nim` would have refused with exit 3 before claiming anything.
    checkpoint("mouseProtocol=" & $sess.mouseProtocol())
    ck sess.mouseProtocol() == mpSgr
    ckQuitsCleanly(sess)

  test "`ct tui <trace.ct>` — the gate's own spelling — paints it too":
    # CTUI-12's verification gate names a `.ct` path, and that path takes a
    # DIFFERENT route through the capability file: the `.ct` extension token
    # rather than the `noext` one a suffix-less recorded fixture uses. A
    # symlink to the real recording, so the binary opens a real trace.
    ctSuffixTrace = artifactDir / "recording.ct"
    if symlinkExists(ctSuffixTrace) or dirExists(ctSuffixTrace):
      removeFile(ctSuffixTrace)
    createSymlink(tracePath, ctSuffixTrace)
    ck dirExists(ctSuffixTrace)
    var sess = launcherSession(componentsRoot, @["tui", ctSuffixTrace]).spawn()
    settleOnDebugger(sess)
    ckDebuggerFrame(sess)
    ckQuitsCleanly(sess)

  test "CONTROL: with an empty component root the same command paints NOTHING":
    # The difference between this case and the two above is one directory. It
    # is what makes "a frame appeared" evidence about the packaged install
    # rather than about the binary being on the machine somewhere.
    var sess = launcherSession(emptyRoot, @["tui", tracePath]).spawn()
    let status = sess.waitExit(initDuration(seconds = 30))
    discard sess.drainOutput(60)
    let text = screenText(sess)
    checkpoint("exit: " & (if status.isSome: $status.get() else: "none") &
               ", screen:\n" & text)
    ck status.isSome
    ck status.get() == 1
    ck text.contains(NoHandlerText)
    # NO FRAME. The positive twin of every `contains` in `ckDebuggerFrame`,
    # through the same reader — a blank screen would satisfy this for free, so
    # the line above asserts what IS there before these assert what is not.
    var compared = 0
    for title in PaneTitles:
      inc compared
      ck not text.contains(title)
    ck compared == PaneTitles.len
    sess.close()

suite "CTUI-12: what the shipped binary costs and what it needs at load time":

  test "the binary's size is inside the recorded regression band":
    # CTUI-12'S OTHER GATE, and the one the 2026-09-05 revision restated:
    # "binary size is RECORDED and a regression threshold set from the MEASURED
    # value". A number in a report is not a threshold, so it is here, in the
    # lane that guarantees the binary is fresh — `just test-tui-real-terminal`
    # depends on `just build-tui`, which the Tier-1 lane does not.
    #
    # A BAND, not a ceiling. A ceiling alone is satisfied by a binary that
    # linked none of the ten grammars, or by a stub; the floor is what makes
    # "this is still the product" part of the assertion.
    let size = getFileSize(tuiBinary)
    checkpoint("build/bin/codetracer-tui: " & $size & " bytes (measured " &
               $MeasuredBinaryBytes & " on " & MeasurementDate & "), band [" &
               $BinaryFloorBytes & ", " & $BinaryCeilingBytes & "]")
    ck size <= BinaryCeilingBytes
    ck size >= BinaryFloorBytes

  test "it needs libc, the C++ runtime and tree-sitter — and nothing else":
    # THE GATE'S OWN WORDING: "no dynamic dependencies beyond libc, libstdc++
    # and the tree-sitter runtime, each justified". Read from the ELF's DT_NEEDED
    # entries rather than from `ldd`, because `ldd` also reports what the
    # dependencies themselves pull in; the claim is about what THIS binary
    # declares.
    #
    # CLASSIFIED, not listed. A literal allow-list would carry `libtree-sitter.
    # so.0.25` — a soname that moves with the runtime's minor version and would
    # redden this on a nixpkgs bump for no product reason. Each entry is put in
    # one of three JUSTIFIED buckets instead, and anything that lands in none is
    # named in the failure.
    let needed = neededLibraries(tuiBinary)
    checkpoint("DT_NEEDED: " & needed.join(" "))
    # A binary with no dependencies at all would satisfy every "is in a bucket"
    # test below for free. It would also be a different product.
    ck needed.len > 0

    var libc, cxx, treeSitter, unexplained: seq[string] = @[]
    var classified = 0
    for lib in needed:
      inc classified
      if lib.bucketOf == blLibc: libc.add lib
      elif lib.bucketOf == blCxx: cxx.add lib
      elif lib.bucketOf == blTreeSitter: treeSitter.add lib
      else: unexplained.add lib
    # The sweep's size against its parameter.
    ck classified == needed.len
    ck libc.len + cxx.len + treeSitter.len + unexplained.len == needed.len

    if unexplained.len > 0:
      checkpoint("UNEXPLAINED dynamic dependencies: " & unexplained.join(" ") &
                 " — CTUI-12's gate allows only libc, the C++ runtime and the" &
                 " tree-sitter runtime, each justified. Widening this list is" &
                 " a product decision, not a test fix.")
    ck unexplained.len == 0

    # THE POSITIVE HALF, one assertion per justified bucket. Without these,
    # `unexplained.len == 0` is satisfied by a binary that needs nothing.
    #
    #   libc         — the platform C library. Nim's runtime is built on it.
    #   C++ runtime  — Yoga is C++ (`isonim/src/isonim/layout/yoga_bindings.nim`
    #                  compiles ~40 `.cpp` files and passes `-lstdc++`), and the
    #                  unwinder comes with it. CTUI-0 recorded this as the
    #                  reason the draft's "libc only" gate was unachievable.
    #   tree-sitter  — `isonim_tui/syntax/treesitter_ffi.nim` ends its
    #                  `{.passl.}` with `-ltree-sitter`; the ten grammars are
    #                  statically archived, the RUNTIME is not.
    checkpoint("libc=" & libc.join(",") & "  c++=" & cxx.join(",") &
               "  tree-sitter=" & treeSitter.join(","))
    ck libc.len > 0
    ck cxx.len > 0
    # If this ever goes to zero it means the runtime was linked statically.
    # That is a legitimate change — measured on 2026-09-06 at +180224 bytes
    # stripped — but it MUST arrive together with a re-measured size band
    # above, so it reddens here rather than passing quietly.
    ck treeSitter.len > 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
