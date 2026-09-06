## test_launcher_routes_tui.nim — CTUI-12, Tier 1 (`tui` lane).
##
## ## What this suite establishes
##
## CTUI-12: "installs the capability file into a scratch component root,
## invokes the real launcher with `tui <trace>`, and asserts it selected the
## TUI binary. Also asserts the *negative*: with the capability file absent,
## the launcher reports no handler rather than falling through to something
## else."
##
## Every word of that is taken literally:
##
##   * **The real launcher.** `codetracer-launcher/out/launcher`, the
##     `--os:standalone --mm:none` binary `just build` produces in that repo. A
##     missing build FAILS by name with the recipe (`docs/tui-testing.md`
##     rule 1) — it is never a skip.
##   * **The real packaging producer.** The scratch root is laid down by
##     `scripts/build-tui-component.sh`, not by this file writing directories.
##     A test that assembled its own bundle would pass over a packaging script
##     that had stopped working, which is half of what this milestone ships.
##   * **The real capability file.** That script copies
##     `packaging/codetracer-tui.caps` byte-for-byte, and this suite asserts the
##     copy with `cmp`-equivalent equality before routing anything through it.
##   * **A second, DIFFERENT component beside it.** `codetracer-desktop`, laid
##     down by `scripts/build-desktop-component.sh` from the file the product
##     actually ships. Without it every "the TUI was selected" assertion would
##     be satisfied by a root with exactly one component in it, and the whole
##     negative — "reports no handler rather than falling through to something
##     else" — would have nothing to fall through TO.
##
## ## THE BINARIES IN THE BUNDLES ARE STUBS, AND THAT IS THE POINT
##
## This is the only fake in the file and it is at the far side of the boundary
## under test: the question is WHICH PATH THE LAUNCHER EXECS, and a stub that
## names itself answers it exactly, while the real front-end would claim a
## terminal and the real core would start a debugger. `docs/tui-testing.md`
## rule 7 permits a fake at a hardware boundary when the header justifies it;
## the boundary here is `execv`, and the Tier-2 suite
## `tests/real_terminal/test_real_launcher_exec.nim` runs the same routing into
## the REAL binary on a real pty, so the pair covers both halves.
##
## ## `execv`, NOT a subprocess — asserted rather than described
##
## CTUI-12's architecture line is "the launcher performs no subprocess
## indirection: it execs the binary". That is observable: `execv` REPLACES the
## process image, so the stub's `$$` is the same pid `startProcess` returned for
## the launcher. A launcher that forked, waited and forwarded the exit status
## would behave identically in every other assertion here and fail this one.
##
## ## THE COMMAND WORD IS PASSED THROUGH, and finding that out is why
## ## `app/cli.LauncherCommandNames` exists
##
## `launcher.cmain` overwrites `argv[0]` with the resolved binary path and
## `execv`s the ORIGINAL argv. So `ct tui <trace>` arrives at the component as
## `[<binpath>, "tui", "<trace>"]` — the command word is NOT stripped, exactly
## as `ct record foo.py` reaches the desktop core as `codetracer record
## foo.py`. Before CTUI-12 the TUI answered that with `expected at most one
## trace folder, got 'tui' and '<trace>'`. The stub's `ARG[0]`/`ARG[1]` lines
## pin the contract from the launcher's side; `app/cli.nim` answers it from the
## component's.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1. The helpers below that only RUN things are procs;
## every helper that asserts is a template.

import std/[algorithm, os, osproc, streams, strtabs, strutils, unittest]

import ../../frontend/tui/tests/fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 62

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  LauncherRecipe = "cd ../codetracer-launcher && just build"
  FixtureName = "calc"
  TuiMarker = "CTUI12-TUI-STUB"
  DesktopMarker = "CTUI12-DESKTOP-STUB"
  NoHandlerPrefix = "ct: no component handles '"
    ## `S_ERR_NO_HANDLER` in `codetracer-launcher/src/install.nim`. Spelled here
    ## rather than imported because that string lives in an `emit` block inside
    ## a `--os:standalone` module; a divergence shows up as this suite failing
    ## with both texts named.
  ExecvFailedText = "ct: execv failed"
    ## `S_ERR_EXECV`, same file. The launcher reaches it only after it has
    ## chosen a component and tried to become it.

  StubScript = """#!/usr/bin/env bash
# CTUI-12 routing stub. Prints WHICH component was selected, WITH WHAT ARGV,
# in WHICH process, so the suite can tell exec from fork.
echo "MARKER=@MARKER@"
echo "PID=$$"
i=0
for a in "$@"; do
  echo "ARG[$i]=$a"
  i=$((i + 1))
done
echo "COMPONENT_DIR=${CODETRACER_COMPONENT_DIR-}"
exit 0
"""

type
  RunResult = object
    exitCode: int
    output: string
    launcherPid: int

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
  launcherBin = root.parentDir / "codetracer-launcher" / "out" / "launcher"
  shippedCaps = root / "packaging" / "codetracer-tui.caps"
  desktopCaps = root / "resources" / "codetracer-desktop-capabilities"

proc writeStub(path, marker: string) =
  createDir(path.parentDir)
  writeFile(path, StubScript.replace("@MARKER@", marker))
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                            fpGroupRead, fpGroupExec,
                            fpOthersRead, fpOthersExec})

proc runScript(script: string; args: openArray[string]): tuple[rc: int, output: string] =
  ## Run one of this repository's packaging scripts and capture everything.
  var argv = @["-euo", "pipefail", script]
  argv.add @args
  # `bash <script> <args>` rather than `execShellCmd`: the arguments carry
  # absolute paths that may contain spaces on a developer's machine, and a
  # shell-quoted command line is one escaping mistake away from assembling the
  # wrong bundle and reporting a routing failure.
  let p = startProcess("/usr/bin/env", args = @["bash"] & argv,
                       options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  (rc, output)

proc runLauncher(componentsRoot, workDir: string;
                 args: openArray[string]): RunResult =
  ## Invoke the REAL launcher with a controlled environment.
  ##
  ## `CODETRACER_COMPONENTS_ROOT` replaces the user level AND suppresses the
  ## absolute system/distro paths (`launcher.collectLevels`), so a developer's
  ## real install cannot answer for this suite. The other two overrides are
  ## cleared so an inherited value cannot add a level or a registry.
  ##
  ## `workDir` is a scratch directory: the launcher walks up from the working
  ## directory looking for `.ctrc`, and one anywhere above this checkout would
  ## pin component versions underneath the test.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k in ["CODETRACER_COMPONENTS_PATH", "CODETRACER_REGISTRY_PATH",
             "CODETRACER_CTRC_PATH", "CODETRACER_COMPONENT_DIR"]:
      continue
    env[k] = v
  env["CODETRACER_COMPONENTS_ROOT"] = componentsRoot
  let p = startProcess(launcherBin, workingDir = workDir, args = @args,
                       env = env, options = {poStdErrToStdOut})
  result.launcherPid = p.processID
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()

proc field(res: RunResult; key: string): string =
  ## The value of a `KEY=value` line the stub printed, or "" if absent.
  for line in res.output.splitLines():
    if line.startsWith(key & "="):
      return line[key.len + 1 .. ^1]
  ""

template ckSelected(res: RunResult; marker: string) =
  ## The component named by `marker` ran, exited 0, and did so IN THE
  ## LAUNCHER'S OWN PROCESS. Three assertions, because "it ran" alone would be
  ## satisfied by a forked child and "exit 0" alone by a launcher that never
  ## execed anything.
  checkpoint("exit " & $res.exitCode & ", launcher pid " & $res.launcherPid &
             "\n" & res.output)
  ck res.exitCode == 0
  ck res.output.contains("MARKER=" & marker)
  ck res.field("PID") == $res.launcherPid

var
  scratch = ""
  workDir = ""
  bothRoot = ""
  desktopOnlyRoot = ""
  noBinRoot = ""
  tracePath = ""
  ctSuffixTrace = ""

suite "CTUI-12: the real launcher routes `tui` to the TUI component":

  test "the launcher binary, the capability files and the fixture all exist":
    # FIRST AND SEPARATELY, so a missing prerequisite reports as itself rather
    # than as a routing failure several cases later. None of these is a skip.
    if not fileExists(launcherBin):
      checkpoint("missing " & launcherBin & " — run `" & LauncherRecipe & "`")
    ck fileExists(launcherBin)
    ck fileExists(shippedCaps)
    # The desktop's file is what makes the "does not fall through" negative
    # mean anything; this suite would be much weaker without it.
    ck fileExists(desktopCaps)

    let resolved = resolveFixture(FixtureName)
    if resolved.outcome != foRecorded:
      # NOT A SKIP. `ct tui <trace>` is the milestone's gate and a trace it
      # cannot get is a prerequisite it must name.
      checkpoint("the `" & FixtureName & "` fixture is unavailable: " &
                 resolved.detail & " — `just test-tui` records and caches it")
    ck resolved.outcome == foRecorded
    tracePath = resolved.tracePath
    checkpoint("trace: " & tracePath)
    ck dirExists(tracePath)
    # A REAL RECORDING WITH NO SUFFIX AT ALL, which is what a recorded fixture
    # is and what makes the `noext` token in the capability file load-bearing.
    ck not tracePath.extractFilename.contains('.')

  test "the packaging scripts lay down two real component bundles":
    scratch = getTempDir() / ("ctui12-launcher-" & $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
    workDir = scratch / "cwd"
    createDir(workDir)

    bothRoot = scratch / "components-both"
    let tuiStub = scratch / "stubs" / "codetracer-tui"
    let desktopStub = scratch / "stubs" / "codetracer"
    writeStub(tuiStub, TuiMarker)
    writeStub(desktopStub, DesktopMarker)

    # THE REAL PRODUCERS. `--copy` rather than `--link` so the bundle stands on
    # its own, which is also the packaging mode a distribution uses.
    let tuiRun = runScript(root / "scripts" / "build-tui-component.sh",
                           ["--out-root", bothRoot, "--tui-bin", tuiStub, "--copy"])
    checkpoint("build-tui-component.sh exit " & $tuiRun.rc & "\n" & tuiRun.output)
    ck tuiRun.rc == 0
    let desktopRun = runScript(root / "scripts" / "build-desktop-component.sh",
                               ["--out-root", bothRoot, "--core-bin", desktopStub,
                                "--copy"])
    checkpoint("build-desktop-component.sh exit " & $desktopRun.rc & "\n" &
               desktopRun.output)
    ck desktopRun.rc == 0

    # The layout the launcher expects: `<root>/<name>@<version>/capabilities`
    # and `<root>/<name>@<version>/bin/<bin-name>`.
    var bundles: seq[string] = @[]
    for kind, path in walkDir(bothRoot):
      if kind == pcDir: bundles.add path.extractFilename
    bundles.sort()
    checkpoint("bundles: " & $bundles)
    ck bundles.len == 2
    ck bundles[0].startsWith("codetracer-desktop@")
    ck bundles[1].startsWith("codetracer-tui@")

    let tuiBundle = bothRoot / bundles[1]
    # BYTE-FOR-BYTE. The launcher's contract is with the file the product
    # ships; a bundle carrying a rewritten capability file would make every
    # routing assertion below a statement about a file nobody installs.
    ck readFile(tuiBundle / "capabilities") == readFile(shippedCaps)
    ck fileExists(tuiBundle / "bin" / "codetracer-tui")

  test "`ct tui <trace>` selects the TUI component and execs it":
    # THE MILESTONE'S GATE, with a suffix-less recorded trace — the shape a
    # real fixture has, routed through the capability file's `noext` token.
    let res = runLauncher(bothRoot, workDir, ["tui", tracePath])
    ckSelected(res, TuiMarker)
    # THE ARGV CONTRACT: the command word is passed through, the trace follows
    # it, and nothing else was added.
    ck res.field("ARG[0]") == "tui"
    ck res.field("ARG[1]") == tracePath
    ck res.field("ARG[2]") == ""
    # …and the component directory is exported, which is how a component finds
    # its own resources after `execv` has thrown away its argv[0]. It names the
    # TUI bundle specifically, not merely "some directory".
    let compDir = res.field("COMPONENT_DIR")
    checkpoint("CODETRACER_COMPONENT_DIR=" & compDir)
    ck compDir.extractFilename.startsWith("codetracer-tui@")
    ck compDir.parentDir == bothRoot
    ck fileExists(compDir / "capabilities")

  test "`ct tui <trace.ct>` selects it too — the `.ct` extension arm":
    # The other half of the capability file's command line, and the spelling
    # §6.1 and the milestone's gate both use. A `.ct`-suffixed DIRECTORY is a
    # real trace container shape (`host/native_host.traceFolderProblem` accepts
    # a folder holding a `.ct` file), so this is a symlink to the fixture
    # rather than an invented path: the launcher must route it and the binary
    # must be able to open it.
    ctSuffixTrace = scratch / "recording.ct"
    createSymlink(tracePath, ctSuffixTrace)
    ck dirExists(ctSuffixTrace)
    let res = runLauncher(bothRoot, workDir, ["tui", ctSuffixTrace])
    ckSelected(res, TuiMarker)
    ck res.field("ARG[1]") == ctSuffixTrace

  test "`ct ct-tui <trace>` selects it as well":
    # The second declared command word, asserted because the capability file
    # declares it and an unexercised declaration is an unverified one.
    let res = runLauncher(bothRoot, workDir, ["ct-tui", tracePath])
    ckSelected(res, TuiMarker)
    ck res.field("ARG[0]") == "ct-tui"

  test "the OTHER component in the same root is live and routes its own work":
    # THE POSITIVE CONTROL FOR THE WHOLE ROOT. Every "the TUI was selected"
    # above would also hold in a root where the desktop bundle was malformed
    # and silently ignored — and then the fall-through negative below would be
    # vacuous. `record .py` is a desktop declaration, not a TUI one.
    let res = runLauncher(bothRoot, workDir, ["record", "prog.py"])
    ckSelected(res, DesktopMarker)
    ck res.field("ARG[0]") == "record"

  test "`ct tui prog.py` refuses: the TUI does not answer for a foreign suffix":
    # `noext` is rule NTR-R1's "no informative suffix", NOT "any suffix". The
    # desktop component declares `.py`, so pass 1 classifies the suffix as
    # DECLARED, `noextFallback` is false, and the TUI's command lines — which
    # list `.ct` and `noext` — match nothing. Without this the `noext` token
    # would be indistinguishable from an unqualified `tui` declaration.
    let res = runLauncher(bothRoot, workDir, ["tui", "prog.py"])
    checkpoint("exit " & $res.exitCode & "\n" & res.output)
    ck res.exitCode == 1
    ck res.output.contains(NoHandlerPrefix & "tui")
    ck res.output.contains("' for '.py'")
    ck not res.output.contains("MARKER=")

suite "CTUI-12: the NEGATIVE — no capability file, no handler, no fall-through":

  test "with the TUI component absent, `ct tui <trace>` reports no handler":
    # THE MILESTONE'S NEGATIVE, stated exactly: "with the capability file
    # absent, the launcher reports no handler rather than falling through to
    # something else". The root still holds a working `codetracer-desktop`, so
    # "something else" EXISTS and is reachable — asserted in the same case,
    # through the same root, so this cannot be passing because the root is
    # empty.
    desktopOnlyRoot = scratch / "components-desktop-only"
    let desktopStub = scratch / "stubs" / "codetracer"
    let desktopRun = runScript(root / "scripts" / "build-desktop-component.sh",
                               ["--out-root", desktopOnlyRoot,
                                "--core-bin", desktopStub, "--copy"])
    ck desktopRun.rc == 0
    var bundles: seq[string] = @[]
    for kind, path in walkDir(desktopOnlyRoot):
      if kind == pcDir: bundles.add path.extractFilename
    checkpoint("bundles: " & $bundles)
    ck bundles.len == 1
    ck bundles[0].startsWith("codetracer-desktop@")

    # The reachable alternative, first — so the negative below is about `tui`
    # and not about a broken root.
    let control = runLauncher(desktopOnlyRoot, workDir, ["record", "prog.py"])
    ckSelected(control, DesktopMarker)

    const AbsentCommands = ["tui", "ct-tui"]
    var compared = 0
    for command in AbsentCommands:
      inc compared
      let res = runLauncher(desktopOnlyRoot, workDir, [command, tracePath])
      checkpoint(command & ": exit " & $res.exitCode & "\n" & res.output)
      ck res.exitCode == 1
      ck res.output.contains(NoHandlerPrefix & command & "'")
      # NOTHING RAN. Not the desktop stub, not anything: the launcher reported
      # and stopped. This is the "rather than falling through" half, and it is
      # the assertion that a router which fell back to its help delegate or to
      # the only installed component would fail.
      ck not res.output.contains("MARKER=")
      ck not res.output.contains(DesktopMarker)
    # The sweep's own size, against its parameter: a loop that ran once would
    # leave `ct-tui` unasserted and say nothing about it.
    ck compared == AbsentCommands.len

  test "a declared command whose binary is missing fails at execv, not silently":
    # The third state, distinct from both of the above: the capability file IS
    # found and the component IS selected, and only then does becoming it fail.
    # It is what proves the two cases above are reporting a ROUTING decision
    # rather than a missing file — the launcher gets strictly further here.
    noBinRoot = scratch / "components-no-bin"
    let tuiStub = scratch / "stubs" / "codetracer-tui"
    let run = runScript(root / "scripts" / "build-tui-component.sh",
                        ["--out-root", noBinRoot, "--tui-bin", tuiStub, "--copy"])
    ck run.rc == 0
    var bundle = ""
    for kind, path in walkDir(noBinRoot):
      if kind == pcDir: bundle = path
    ck bundle.len > 0
    removeFile(bundle / "bin" / "codetracer-tui")
    ck not fileExists(bundle / "bin" / "codetracer-tui")
    # The capability file is untouched, so the routing decision is unchanged.
    ck readFile(bundle / "capabilities") == readFile(shippedCaps)

    let res = runLauncher(noBinRoot, workDir, ["tui", tracePath])
    checkpoint("exit " & $res.exitCode & "\n" & res.output)
    ck res.exitCode == 127
    ck res.output.contains(ExecvFailedText)
    ck not res.output.contains(NoHandlerPrefix)

  test "the scratch tree is removed":
    # Not a cleanup convenience: `scratch` sits under $TMPDIR and the suite
    # writes stubs, bundles and a symlink into it. A run that left it behind
    # would make the next run's `bundles.len == 2` depend on the previous one.
    removeDir(scratch)
    ck not dirExists(scratch)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
