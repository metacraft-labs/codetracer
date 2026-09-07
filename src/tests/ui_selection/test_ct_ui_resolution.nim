## test_ct_ui_resolution.nim — PLAT-1, END TO END, through the shipped binaries.
##
## Specification: `codetracer-specs/CLI/ct/ui-selection.md`.
## Milestone: `codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org`,
## PLAT-1 — "Real-stack integration tests (no mocks)".
##
## ## WHAT IS REAL HERE, WHICH IS EVERYTHING
##
## Five artefacts, no stubs anywhere:
##
##   * `codetracer-launcher/out/launcher` — the real `ct`, `--os:standalone
##     --mm:none`, byte for byte the binary that repository's `just build`
##     produces.
##   * `src/build-debug/bin/ct` — the real desktop core, which is what resolves
##     `--ui`.
##   * `build/bin/codetracer-tui` — the real terminal front-end, which is what
##     the handoff `exec`s.
##   * `packaging/codetracer-tui.caps` and
##     `resources/codetracer-desktop-capabilities` — the real capability files,
##     copied byte for byte into component bundles by the real packaging
##     producers (`scripts/build-{tui,desktop}-component.sh`).
##   * a real recording of the `calc` fixture, produced by `ct record`.
##
## The evidence a case reads back is a real TUI frame — `--headless` renders one
## settled screen as plain text and exits 0, so the whole chain is assertable
## without a pty. `src/frontend/tui/tests/real_terminal/test_real_launcher_exec.
## nim` is the pty half of the same claim for `ct tui`, and this file
## deliberately does not duplicate it.
##
## ## WHY A FRAME IS THE ONLY ACCEPTABLE EVIDENCE FOR "IT REACHED THE TUI"
##
## Verification-Harness-Traps §7: an assertion whose failure arm cannot fire is
## not an assertion. "`ct` exited 0" is satisfied by `ct` having done nothing at
## all; "stderr was empty" is satisfied by a silent refusal. So every positive
## case below asserts PANE TITLES from §3.1's screen — text only the terminal
## front-end can produce — and the negative cases assert that those same titles
## are ABSENT, through the same reader.
##
## ## THE LAUNCHER IS UNCHANGED, AND THAT IS ASSERTED RATHER THAN CLAIMED
##
## ui-selection.md §2: "This is the load-bearing constraint, and it is satisfied
## by doing nothing." The launcher is already 3,104 bytes over its 50 KB cap, so
## a design that made it parse a flag value would have to buy the space first.
## The first suite asserts the constraint three ways — a clean worktree, a clean
## diff against the merge base, and no occurrence of `--ui` or `CODETRACER_UI`
## anywhere in its sources — because "we did not change it" is exactly the kind
## of claim that quietly stops being true.

import std/[algorithm, os, osproc, sequtils, streams, strtabs, strutils,
            unittest]

import ../../frontend/tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 225

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  CtRecipe = "just build-once"
  TuiRecipe = "just build-tui"
  LauncherRecipe = "cd ../codetracer-launcher && just build"

  PaneTitles: array[4, string] = ["CALL STACK", "SOURCE", "VARIABLES",
                                  "TIMELINE"]
    ## §3.1's screen, as the pane titles a real headless frame carries.
    ## Asserted as a counted sweep rather than as four loose `contains` calls,
    ## so a partially painted screen cannot satisfy "at least one".
    ##
    ## FOUR OF THEM ONLY BECAUSE THE GEOMETRY IS PINNED. `host/headless.
    ## headlessGeometry` reads the tty when there is one, then `COLUMNS`/
    ## `LINES`, then a fallback; the fallback is 80x24, which selects the
    ## COMPACT profile, and TIMELINE is then a TAB of the state stack rather
    ## than a rectangle with a title. Measured, not assumed: the first run of
    ## this suite failed on `TIMELINE` alone. `HeadlessColumns`/`HeadlessRows`
    ## below pin the STANDARD profile for every child, so the sweep asserts the
    ## same four panes whether or not the runner has a terminal.

  HeadlessColumns = "120"
  HeadlessRows = "40"
    ## 120x40 — `app/layout/profile.selectProfile`'s STANDARD profile, and the
    ## same geometry CTUI-11's and CTUI-12's real-terminal suites use, so a
    ## frame that differs between them differs for a reason other than size.

  AcceptedSetText = "electron, gui, tui, webui"
    ## §4's accepted set as the refusal must name it. Spelled here rather than
    ## imported: this suite is a statement about what the SHIPPED BINARY prints,
    ## and importing the constant it prints from would make the assertion
    ## circular — Verification-Harness-Traps' "an expected value must not be
    ## produced by the code under test".

type
  Run = object
    rc: int
    stdout: string
    stderr: string

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
  ctBinary = root / "src" / "build-debug" / "bin" / "ct"
  tuiBinary = root / "build" / "bin" / "codetracer-tui"
  launcherRepo = root.parentDir / "codetracer-launcher"
  launcherBin = launcherRepo / "out" / "launcher"

var
  scratch = ""
  tracePath = ""
  componentsRoot = ""
  emptyConfigHome = ""
  runSerial = 0
    ## Names the per-run stderr capture file. A counter rather than a clock:
    ## two runs inside the same millisecond would otherwise share a file and
    ## one of them would read the other's diagnostics.

proc runProcessCapturing(exe: string; args: seq[string];
                         extraEnv: openArray[(string, string)] = [];
                         removeEnv: openArray[string] = [];
                         workDir = ""): Run =
  ## Run `exe` with a CONTROLLED environment and capture the two streams apart.
  ##
  ## Separately, not merged, because two of this milestone's claims are about
  ## which stream something lands on: a refusal is one line on stderr, and the
  ## deprecation notice must not corrupt stdout, which carries `--version`'s
  ## machine-readable answer and the headless frame.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key in removeEnv or key == "CODETRACER_UI":
      continue
    env[key] = value
  # The headless screen's size, pinned for every child — see `PaneTitles`.
  # Set BEFORE `extraEnv` so a case that wants a different geometry can say so,
  # and after the inherited environment so a developer's own terminal size
  # cannot change what this suite asserts.
  env["COLUMNS"] = HeadlessColumns
  env["LINES"] = HeadlessRows
  for (key, value) in extraEnv:
    env[key] = value

  inc runSerial
  let errFile = getTempDir() / ("plat1-stderr-" & $getCurrentProcessId() &
                                "-" & $runSerial)
  # `poStdErrToStdOut` would merge the two, and `osproc` has no two-pipe
  # capture that does not deadlock on a large stdout — a headless frame is
  # 40 lines wide. A file for stderr keeps them apart with no reader loop.
  let wrapper = "exec 2>\"$CT_TEST_STDERR_FILE\"; exec \"$@\""
  env["CT_TEST_STDERR_FILE"] = errFile
  var argv = @["-c", wrapper, "bash", exe]
  argv.add args
  let p = startProcess("/usr/bin/env",
                       args = @["bash"] & argv,
                       env = env,
                       workingDir = workDir,
                       options = {})
  result.stdout = p.outputStream.readAll()
  result.rc = p.waitForExit()
  p.close()
  result.stderr = try: readFile(errFile) except CatchableError: ""
  try: removeFile(errFile) except CatchableError: discard

proc runScript(script: string; args: openArray[string]): tuple[rc: int, output: string] =
  var argv = @["-euo", "pipefail", script]
  argv.add @args
  let p = startProcess("/usr/bin/env", args = @["bash"] & argv,
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

proc git(args: seq[string]): tuple[rc: int, output: string] =
  let p = startProcess("git", args = args, options = {poUsePath,
                                                      poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

template ckFrame(res: Run) =
  ## A REAL headless frame from the terminal front-end, as a counted sweep.
  checkpoint("rc=" & $res.rc & "\nstdout head: " &
             res.stdout.splitLines()[0 .. min(2, res.stdout.splitLines().high)].join("\n") &
             "\nstderr: " & res.stderr)
  ck res.rc == 0
  var compared = 0
  for title in PaneTitles:
    inc compared
    ck res.stdout.contains(title)
  ck compared == PaneTitles.len

template ckNoFrame(res: Run) =
  ## The positive twin of `ckFrame`, through the same reader — so "the TUI was
  ## not reached" is a statement about the same bytes rather than about silence.
  var compared = 0
  for title in PaneTitles:
    inc compared
    ck not res.stdout.contains(title)
  ck compared == PaneTitles.len

template ckUsageError(res: Run; mustContain: openArray[string]) =
  ## §4.2's refusal shape: exit 2, ONE line on stderr, nothing on stdout, and
  ## the line says the things it has to say.
  checkpoint("rc=" & $res.rc & " stderr=" & res.stderr &
             " stdout=" & res.stdout)
  ck res.rc == 2
  ck res.stdout.len == 0
  let lines = res.stderr.strip().splitLines()
  ck lines.len == 1
  var compared = 0
  for needle in mustContain:
    inc compared
    ck res.stderr.contains(needle)
  ck compared == mustContain.len
  ckNoFrame(res)

suite "PLAT-1 §2: the launcher is unchanged, and knows nothing about `--ui`":

  test "the codetracer-launcher checkout is clean and matches its HEAD":
    # PLAT-1's own first integration test: "The launcher is unchanged: `git
    # diff` on `codetracer-launcher` is empty".
    ck dirExists(launcherRepo)
    # `--untracked-files=no`, and the reason is worth stating rather than
    # leaving as a flag: a developer's checkout carries `.direnv/` and other
    # untracked local apparatus that has nothing to do with this milestone, and
    # a suite that reddened on those would be reporting somebody's tooling as a
    # violation of §2. TRACKED state is the claim — "`git diff` on
    # `codetracer-launcher` is empty", in PLAT-1's own words.
    let status = git(@["-C", launcherRepo, "status", "--porcelain",
                       "--untracked-files=no"])
    checkpoint("git status --porcelain -uno:\n" & status.output)
    ck status.rc == 0
    ck status.output.strip().len == 0
    let diff = git(@["-C", launcherRepo, "diff", "--stat", "HEAD"])
    checkpoint("git diff --stat HEAD:\n" & diff.output)
    ck diff.rc == 0
    ck diff.output.strip().len == 0
    # THE READER WORKS, which is what stops the two emptinesses above from
    # being satisfied by a `git` that failed silently or a path that is not a
    # repository at all: the same reader, on the same repository, produces a
    # non-empty answer to a question that has one.
    let head = git(@["-C", launcherRepo, "rev-parse", "HEAD"])
    ck head.rc == 0
    ck head.output.strip().len == 40

  test "no source file in the launcher mentions `--ui` or CODETRACER_UI":
    # THE STRONGER STATEMENT, and the one that stays true after somebody
    # commits: a clean worktree only says nothing changed TODAY. §2's claim is
    # that the launcher has no parser, no flag table and no opinion about
    # `--ui`, and that is a property of its sources.
    var scanned = 0
    var hits: seq[string] = @[]
    for path in walkDirRec(launcherRepo / "src"):
      if not path.endsWith(".nim"):
        continue
      inc scanned
      let text = readFile(path)
      if text.contains("--ui") or text.contains("CODETRACER_UI"):
        hits.add path
    checkpoint("scanned " & $scanned & " launcher sources; hits: " & $hits)
    # A SCANNER THAT FOUND NOTHING PASSES EVERY "MUST NOT CONTAIN"
    # (Verification-Harness-Traps §5), so the sweep's own size is asserted
    # first: the launcher has more than a handful of Nim sources, and a glob
    # that matched none of them would satisfy the line below for free.
    ck scanned >= 3
    ck hits.len == 0
    # …and the scanner CAN find a string that is really there, proving it reads
    # the bytes rather than reporting an empty set.
    var foundExecv = 0
    for path in walkDirRec(launcherRepo / "src"):
      if path.endsWith(".nim") and readFile(path).contains("execv"):
        inc foundExecv
    ck foundExecv > 0

suite "PLAT-1: the artefacts this suite composes":

  test "every binary and the fixture exist, by name":
    # FIRST AND SEPARATELY, so a missing build reports as a missing build
    # rather than as a routing failure several cases later. None of these is a
    # skip — `docs/tui-testing.md` rule 1.
    if not fileExists(ctBinary):
      checkpoint("missing " & ctBinary & " — run `" & CtRecipe & "`")
    ck fileExists(ctBinary)
    if not fileExists(tuiBinary):
      checkpoint("missing " & tuiBinary & " — run `" & TuiRecipe & "`")
    ck fileExists(tuiBinary)
    if not fileExists(launcherBin):
      checkpoint("missing " & launcherBin & " — run `" & LauncherRecipe & "`")
    ck fileExists(launcherBin)

    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail & " — `just test-tui` records and caches it")
    ck resolved.outcome == foRecorded
    tracePath = absolutePath(resolved.tracePath)
    checkpoint("trace: " & tracePath)
    ck dirExists(tracePath)

    scratch = getTempDir() / ("plat1-ui-resolution-" & $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
    # An EMPTY config home for every child, so a developer's own
    # `~/.config/codetracer/.config.yaml` cannot answer for the default-layer
    # cases below.
    emptyConfigHome = scratch / "xdg"
    createDir(emptyConfigHome)
    ck dirExists(emptyConfigHome)

  test "the real packaging producers lay down both component bundles":
    componentsRoot = scratch / "components"
    let desktop = runScript(root / "scripts" / "build-desktop-component.sh",
                            ["--out-root", componentsRoot,
                             "--core-bin", ctBinary, "--link"])
    checkpoint("build-desktop-component.sh exit " & $desktop.rc & "\n" &
               desktop.output)
    ck desktop.rc == 0
    let tui = runScript(root / "scripts" / "build-tui-component.sh",
                        ["--out-root", componentsRoot,
                         "--tui-bin", tuiBinary, "--link"])
    checkpoint("build-tui-component.sh exit " & $tui.rc & "\n" & tui.output)
    ck tui.rc == 0

    var bundles: seq[string] = @[]
    for kind, path in walkDir(componentsRoot):
      if kind == pcDir: bundles.add path.lastPathPart
    bundles.sort()
    checkpoint("bundles: " & $bundles)
    ck bundles.len == 2
    ck bundles[0].startsWith("codetracer-desktop@")
    ck bundles[1].startsWith("codetracer-tui@")
    # BYTE FOR BYTE: the routing below is a statement about the files the
    # product ships, not about ones this suite wrote.
    ck readFile(componentsRoot / bundles[1] / "capabilities") ==
       readFile(root / "packaging" / "codetracer-tui.caps")
    ck readFile(componentsRoot / bundles[0] / "capabilities") ==
       readFile(root / "resources" / "codetracer-desktop-capabilities")

suite "PLAT-1 §3: `ct replay --ui=tui <trace>` reaches the terminal front-end":

  test "through the REAL LAUNCHER and an unmodified router, a real frame":
    # THE MILESTONE'S FIRST INTEGRATION TEST, end to end: the launcher routes
    # `replay` to codetracer-desktop by its capability file, execs the real
    # `ct`, `ct`'s prologue resolves `--ui=tui`, finds the sibling component in
    # the SAME root the launcher chose, and execs the real front-end, which
    # paints §3.1's screen.
    let res = runProcessCapturing(launcherBin,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", componentsRoot),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    ckFrame(res)

  test "CONTROL: the same line with the TUI component absent paints nothing":
    # The difference between this case and the one above is ONE COMPONENT
    # BUNDLE, and it is what makes "a frame appeared" evidence about the
    # handoff rather than about the front-end being on the machine somewhere.
    #
    # `--copy`, not `--link`, and that is the whole reason this case works.
    # `resolveTuiBinary` falls back — after the component roots — to the
    # DEVELOPER LAYOUT, `<checkout>/build/bin/codetracer-tui` relative to
    # `getAppDir()`. With a symlinked bundle, `/proc/self/exe` resolves back
    # into the checkout and the fallback finds the real front-end, so the
    # control passed for the wrong reason and asserted nothing. Measured: the
    # first run of this case reported rc=0 and a full frame. A COPY of `ct`
    # inside the bundle puts `getAppDir()` under `$TMPDIR`, where no
    # `build/bin/codetracer-tui` exists, so every fallback misses and the
    # component roots are the only thing left that could answer.
    let desktopOnly = scratch / "components-desktop-only"
    let desktop = runScript(root / "scripts" / "build-desktop-component.sh",
                            ["--out-root", desktopOnly,
                             "--core-bin", ctBinary, "--copy"])
    checkpoint("build-desktop-component.sh exit " & $desktop.rc & "\n" &
               desktop.output)
    ck desktop.rc == 0
    var bundles: seq[string] = @[]
    for kind, path in walkDir(desktopOnly):
      if kind == pcDir: bundles.add path.lastPathPart
    checkpoint("bundles: " & $bundles)
    ck bundles.len == 1
    ck bundles[0].startsWith("codetracer-desktop@")
    ck not fileExists(desktopOnly / bundles[0] / "bin" / "codetracer-tui")

    let res = runProcessCapturing(launcherBin,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", desktopOnly),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    checkpoint("rc=" & $res.rc & " stderr=" & res.stderr)
    ck res.rc == 2
    # It names the COMPONENT rather than failing at `execv` with ENOENT, which
    # is the difference between "install this" and "something went wrong".
    ck res.stderr.contains("codetracer-tui")
    ck res.stderr.contains("not installed")
    ckNoFrame(res)

    # THE POSITIVE TWIN, on the SAME isolated copy: add the TUI bundle beside
    # it and the identical command line paints a frame. Without this, the
    # refusal above could be a property of the copied `ct` rather than of the
    # missing component.
    let tui = runScript(root / "scripts" / "build-tui-component.sh",
                        ["--out-root", desktopOnly,
                         "--tui-bin", tuiBinary, "--link"])
    ck tui.rc == 0
    let after = runProcessCapturing(launcherBin,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", desktopOnly),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    ckFrame(after)

  test "the desktop core reached directly does the same thing":
    # Without the launcher, so a failure above can be attributed: the launcher
    # forwards argv verbatim and adds nothing, and `ct` is where `--ui` lives.
    let res = runProcessCapturing(ctBinary,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)])
    ckFrame(res)

  test "`--ui` itself never reaches the front-end":
    # The TUI has no `--ui` option and refuses unknown ones by name, so a
    # handoff that forwarded the flag would exit 2 with "unknown option".
    # The frame above already proves it; this says so out loud on the argument
    # the TUI would have complained about.
    let res = runProcessCapturing(ctBinary,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)])
    ck not res.stderr.contains("unknown option")
    ck not res.stderr.contains("--ui")

suite "PLAT-1 §4.2: an unrecognised value is refused, naming the accepted set":

  test "`--ui=gpui` is refused by the shipped binary":
    # §4.1: `gpui` is added to the accepted set by PLAT-20, which makes it
    # work, and by no earlier milestone.
    let res = runProcessCapturing(ctBinary,
      @["replay", "--ui=gpui", tracePath],
      extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)])
    ckUsageError(res, ["gpui", AcceptedSetText])

  test "every other unrecognised value is refused the same way":
    var compared = 0
    for value in ["banana", "GUI", "term", "web", "electron2", ""]:
      inc compared
      let res = runProcessCapturing(ctBinary,
        @["replay", "--ui=" & value, tracePath],
        extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)])
      checkpoint("--ui=" & value & " -> rc=" & $res.rc & " " & res.stderr)
      ck res.rc == 2
      ck res.stderr.contains(AcceptedSetText)
    ck compared == 6

  test "an unrecognised CODETRACER_UI is refused, naming the variable":
    let res = runProcessCapturing(ctBinary,
      @["replay", tracePath],
      extraEnv = [("CODETRACER_UI", "banana"),
                  ("XDG_CONFIG_HOME", emptyConfigHome)])
    ckUsageError(res, ["CODETRACER_UI", "banana", AcceptedSetText])

  test "an unrecognised configured value is refused, naming the setting":
    let dir = scratch / "bad-config"
    createDir(dir)
    writeFile(dir / ".config.yaml", "ui: banana\n")
    let res = runProcessCapturing(ctBinary,
      @["replay", tracePath],
      extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckUsageError(res, ["'ui'", "banana", AcceptedSetText])

  test "`--ui` on a command that presents no session names the conflict":
    var compared = 0
    for command in ["record", "list", "print", "import", "login"]:
      inc compared
      let res = runProcessCapturing(ctBinary,
        @[command, "--ui=tui", tracePath],
        extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)])
      checkpoint("ct " & command & " --ui=tui -> rc=" & $res.rc & " " &
                 res.stderr)
      ck res.rc == 2
      ck res.stderr.contains("ct " & command)
      ck res.stderr.contains("replay, run, edit, review")
    ck compared == 5

suite "PLAT-1 §5: the resolution order, through the shipped binary":

  test "the CONFIGURATION layer selects the front-end, and a frame proves it":
    let dir = scratch / "config-tui"
    createDir(dir)
    writeFile(dir / ".config.yaml", "ui: tui\n")
    let res = runProcessCapturing(ctBinary,
      @["replay", "--headless", tracePath],
      extraEnv = [("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckFrame(res)

  test "the ENVIRONMENT layer selects it too, with no configuration at all":
    let dir = scratch / "no-config"
    createDir(dir)
    let res = runProcessCapturing(ctBinary,
      @["replay", "--headless", tracePath],
      extraEnv = [("CODETRACER_UI", "tui"),
                  ("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckFrame(res)

  test "the ENVIRONMENT beats the CONFIGURATION":
    # Both layers are set and they DISAGREE, so exactly one of them can be
    # answering. `--headless` is what makes the answer visible: with `electron`
    # it is a usage error naming the source, with `tui` it is a frame.
    let dir = scratch / "config-tui"
    let res = runProcessCapturing(ctBinary,
      @["replay", "--headless", tracePath],
      extraEnv = [("CODETRACER_UI", "electron"),
                  ("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckUsageError(res, ["--headless", "--ui=electron",
                       "CODETRACER_UI environment variable"])

  test "the FLAG beats the environment AND the configuration":
    let dir = scratch / "config-tui"
    let res = runProcessCapturing(ctBinary,
      @["replay", "--ui=electron", "--headless", tracePath],
      extraEnv = [("CODETRACER_UI", "tui"),
                  ("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckUsageError(res, ["--headless", "--ui=electron", "the --ui flag"])

  test "…and the flag wins the other way round too, which is the control":
    # Without this the case above is satisfied by an implementation in which
    # the FLAG always loses and `electron` merely happens to be the default.
    let dir = scratch / "config-electron"
    createDir(dir)
    writeFile(dir / ".config.yaml", "ui: electron\n")
    let res = runProcessCapturing(ctBinary,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_UI", "electron"),
                  ("CODETRACER_TUI_BIN", tuiBinary),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckFrame(res)

  test "the DEFAULT is electron: with nothing set, `--headless` contradicts it":
    let dir = scratch / "no-config"
    let res = runProcessCapturing(ctBinary,
      @["replay", "--headless", tracePath],
      extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)],
      workDir = dir)
    ckUsageError(res, ["--headless", "--ui=electron", "built-in default"])

suite "PLAT-1 §8: `--headless` belongs to `--ui=tui` and to nothing else":

  test "every non-tui value refuses it, naming both sides":
    var compared = 0
    for value in ["electron", "gui", "webui"]:
      inc compared
      let res = runProcessCapturing(ctBinary,
        @["replay", "--ui=" & value, "--headless", tracePath],
        extraEnv = [("XDG_CONFIG_HOME", emptyConfigHome)])
      checkpoint("--ui=" & value & " --headless -> " & res.stderr)
      ck res.rc == 2
      ck res.stderr.contains("--headless")
      ck res.stderr.contains("--ui=" & value)
      ckNoFrame(res)
    ck compared == 3

suite "PLAT-1 §7.1: `ct tui` is a deprecated alias, and says so ONCE":

  test "it still works, and emits exactly one line on stderr":
    let res = runProcessCapturing(launcherBin,
      @["tui", tracePath, "--headless"],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", componentsRoot),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    # STILL WORKS: the alias is kept for one release, so the frame must appear.
    ckFrame(res)
    # EXACTLY ONE LINE. Not "at least one" — a warning printed per parse, or
    # per frame, is the shape this assertion exists to refuse.
    let lines = res.stderr.strip().splitLines().filterIt(it.strip().len > 0)
    checkpoint("stderr lines: " & $lines)
    ck lines.len == 1
    # …and it names the replacement, which is what makes it a migration notice
    # rather than a complaint.
    ck lines[0].contains("deprecated")
    ck lines[0].contains("--ui=tui")
    # ON STDERR, NOT STDOUT: stdout carries the frame, and a warning inside it
    # would corrupt every consumer that parses one.
    ck not res.stdout.contains("deprecated")

  test "`ct ct-tui` is the same alias and says the same thing once":
    let res = runProcessCapturing(launcherBin,
      @["ct-tui", tracePath, "--headless"],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", componentsRoot),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    ckFrame(res)
    let lines = res.stderr.strip().splitLines().filterIt(it.strip().len > 0)
    ck lines.len == 1
    ck lines[0].contains("ct-tui")

  test "CONTROL: the replacement spelling emits NO deprecation line":
    # Without this, "exactly one line" is satisfied by an implementation that
    # prints the notice on every invocation, including the one it recommends.
    let res = runProcessCapturing(launcherBin,
      @["replay", "--ui=tui", "--headless", tracePath],
      extraEnv = [("CODETRACER_COMPONENTS_ROOT", componentsRoot),
                  ("XDG_CONFIG_HOME", emptyConfigHome)],
      removeEnv = ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
                   "CODETRACER_COMPONENT_DIR", "CODETRACER_TUI_BIN"])
    ckFrame(res)
    checkpoint("stderr: " & res.stderr)
    ck not res.stderr.contains("deprecated")

suite "cleanup and count":

  test "the scratch tree is removed":
    removeDir(scratch)
    ck not dirExists(scratch)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
