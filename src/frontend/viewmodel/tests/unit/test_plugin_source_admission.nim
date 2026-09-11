## test_plugin_source_admission.nim — PLAT-8's SOURCE-admission suite, and the
## one place in this campaign where an exploit is COMPILED AND RUN.
##
## ## THE FINDING THIS FILE EXISTS FOR
##
## PLAT-8 landed with six repairs and a residual list, and the worst entry on
## that list was this: **a plugin may import any `std` module and call it
## directly, and the capability model is not in that path at all.** Measured
## 2026-09-09, with a declared plugin, against the real gate — a module carrying
## `## CT-PLUGIN:`, importing `codetracer_plugin` and `std/posix` and nothing
## else:
##
##     posix read of /etc/hostname, no fs:read grant -> gpu-server-001
##     posix fork+exec of /bin/sh, no process grant  -> child pid 505249
##
## over a gate printing `19 check(s), 0 failing`. The repair is an ALLOW-LIST
## over the imports of a plugin's reachable closure
## (`src/common/plugin_model/source_admission.nim`), and its own attack surface
## is an FFI pragma, which needs no import at all and is closed beside it.
##
## ## ASSERT THE EFFECT, NOT THE REPORT
##
## The obvious suite here asserts that the gate PRINTED a violation. That is the
## weaker signal, and this campaign has withdrawn six claims that were all the
## same shape: the report was unchanged while the state moved. So the case that
## matters — `under admission, neither effect happens` — asserts on the
## SENTINELS:
##
##   * the READ sentinel holds the bytes the probe pulled out of `/etc/hostname`
##     with posix `open`/`read`, holding no `fs:read` grant;
##   * the EXEC sentinel is written BY `/bin/sh`, so its existence means `execv`
##     succeeded and a shell ran — not merely that `fork` returned.
##
## ## AND THE TWIN IS INSIDE THE SAME CASE
##
## Verification-Harness-Traps §4a. "The sentinel does not exist" is satisfied by
## a probe that never compiled, a binary at the wrong path, a temp directory
## that was not created, and a runner with a typo in it. So the case that
## asserts the absence ALSO runs the same binary through the same runner with
## the admission decision forced to `true`, on sentinel paths of the same shape,
## and asserts they DO appear. One function, two callers, and the difference
## between them is the admission decision and nothing else — which is the only
## arrangement in which the absence is evidence.
##
## ## WHAT THIS SUITE DOES NOT CLAIM
##
## The gate is a SOURCE lint. It decides whether a plugin is admitted; it does
## not stand between a running plugin and the kernel. So "the shell was not
## reached" is a fact about a plugin that was refused ADMISSION, and the
## `admitAndRun` helper below is the model of a host that consults the gate —
## not a sandbox. Nothing here should be read as saying an admitted plugin is
## contained at runtime; PLAT-8's residual list says the opposite, in those
## words, on the `process` row.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion goes through `ck`, which is a `template`. A `check` inside a
## plain `proc` sets a module-level global and the case reports `[OK]` with the
## failed comparison printed directly above it. The helpers below that contain
## no `check` are ordinary `proc`s; the moment one needs an assertion it becomes
## a template.
##
## ## EVERY WAIT IS BOUNDED
##
## "A test that hangs on the defect it detects reports the defect as its
## absence." Each child — the nim compiler, the probe, the gate — is spawned
## under `timeout(1)` with its own budget, so a probe that blocks on a read of
## fd 0 that never arrives fails the case rather than the lane.
##
## Compile and run (from the repository root):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_source_admission.nim

import std/[os, osproc, streams, strutils, unittest]

import ../../../../common/plugin_model/source_admission

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    .parentDir.parentDir
    ## `src/frontend/viewmodel/tests/unit/<this file>` — six hops.

  ProbeDir = "src/frontend/viewmodel/tests/unit/plugin_probes"
  PosixProbe = "posix_raw_plugin"
  FfiProbe = "ffi_raw_plugin"
  SurfaceProbe = "surface_reach_probe"
  SysioProbe = "sysio_raw_plugin"
    ## THE THIRD EXPLOIT, and it is the one both repairs walk past: it needs no
    ## import for the allow-list to refuse and no pragma for the FFI denylist
    ## to refuse. `system` is auto-imported and is `export syncio`.

  Gate = "ci/test/plugin-reactive-boundary.sh"
  AllowListCheck = "plugin-imports-allow-listed"
  FfiCheck = "plugin-binds-no-foreign-function"
  SyncIoCheck = "plugin-names-no-sync-io"
    ## The check that refuses the `system` route. It is the OLDEST of the
    ## three mechanisms — a denylist of names — and it is the only one that can
    ## reach `system`, because there is no import to refuse and no scope to
    ## filter. What changed on 2026-09-09 is not the mechanism but where its
    ## list comes from: `ci/lib/system-io-surface.sh` derives the surface off
    ## the pinned compiler, and check 23 requires every derived name to be
    ## denied or exempted-with-a-reason.

  # The files the synthetic tree carries, COPIED FROM THE REAL REPOSITORY
  # rather than written out here. A second copy of the allow-list, of the
  # surface or of the denied tables would be a second thing that can drift
  # while agreeing with itself (Verification-Harness-Traps §14), and it is the
  # REAL allow-list whose verdict this suite is about.
  TreeFiles = [
    "src/common/plugin_model/source_admission.nim",
    "src/frontend/viewmodel/plugin_host/plugin_api.nim",
    "src/frontend/viewmodel/plugin_host/plugin_io.nim",
    "src/frontend/viewmodel/codetracer_embed.nim",
    "src/frontend/viewmodel/codetracer_plugin.nim",
    "src/frontend/viewmodel/tests/unit/plugin_fixtures/.ct-plugin",
    "src/frontend/viewmodel/tests/unit/plugin_fixtures/position_watch_plugin.nim",
    "src/frontend/viewmodel/tests/unit/plugin_fixtures/surface_probe_plugin.nim",
  ]
  FixturesRel = "src/frontend/viewmodel/tests/unit/plugin_fixtures"

  CompileBudget = "300"
  RunBudget = "20"
  GateBudget = "180"

type
  Ran = object
    output: string
    code: int

proc runBounded(exe: string; args: seq[string]; input = "";
                budget = RunBudget): Ran =
  ## Spawn EXE under `timeout(1)`, feed INPUT to its stdin, and return what it
  ## printed together with its exit code.
  ##
  ## The bound is `timeout` rather than a poll loop here on purpose: a poll loop
  ## has to decide what to do when the child ignores the deadline, and the
  ## answer is always "send it a signal", which is what `timeout` already is.
  doAssert findExe("timeout").len > 0,
    "coreutils `timeout` is required to bound this suite"
  # `poUsePath` AND THE BARE NAME, not the path `findExe` returns. On this
  # toolchain `timeout` is a symlink into coreutils' MULTI-CALL binary, which
  # dispatches on `argv[0]`; `startProcess` sets `argv[0]` to the command it was
  # given, so handing it the resolved `/nix/store/…/bin/coreutils` made every
  # child run as `coreutils` and answer `unrecognized option '--hints:off'`.
  # Measured on the first run of this suite, and it is worth a comment because
  # the symptom named the ARGUMENT rather than the program.
  let p = startProcess("timeout", workingDir = repoRoot,
                       args = @[budget, exe] & args,
                       options = {poUsePath, poStdErrToStdOut})
  try:
    if input.len > 0:
      p.inputStream.write(input)
    p.inputStream.close()
    # READ BEFORE WAITING, and it is not a style choice. `waitForExit` on a
    # child whose stdout pipe is full never returns: the child blocks on the
    # write, the parent blocks on the exit, and the suite hangs on exactly the
    # runs that produced the most output. Draining to EOF first makes the wait
    # a formality.
    result.output = p.outputStream.readAll()
    result.code = p.waitForExit()
  finally:
    p.close()

proc compileProbe(probe, outBin: string): Ran =
  ## `nim c` on a probe, from the repository root so `config.nims` supplies the
  ## sibling paths `codetracer_plugin` needs.
  doAssert findExe("nim").len > 0, "nim is required to compile the probe"
  runBounded("nim", @["c", "--hints:off", "--warnings:off",
                    "--path:src/frontend/viewmodel",
                    "--nimcache:" & outBin & ".cache",
                    "-o:" & outBin, probe],
             budget = CompileBudget)

proc stageProbe(work, probe: string): string =
  ## Copy `<probe>.nim.probe` next to a build directory as a `.nim` file.
  ##
  ## THE EXTENSION IS WHY THE COPY EXISTS. The probes are committed as
  ## `.nim.probe` so `git ls-files '*.nim'` — the set the gate seeds plugin
  ## discovery from — cannot reach them; a live exploit in a `.ct-plugin`
  ## directory would make the real gate red on every run, and a gate that is red
  ## for a reason everybody has agreed to ignore is a gate nobody reads.
  result = work / probe & ".nim"
  copyFile(repoRoot / ProbeDir / (probe & ".nim.probe"), result)

proc makeAdmissionTree(work, probe: string): string =
  ## A tree carrying the REAL configuration and ONE plugin: the probe.
  result = work / "tree-" & probe
  for rel in TreeFiles:
    createDir(result / rel.parentDir)
    copyFile(repoRoot / rel, result / rel)
  createDir(result / FixturesRel)
  copyFile(repoRoot / ProbeDir / (probe & ".nim.probe"),
           result / FixturesRel / (probe & ".nim"))
  # The gate seeds its discovery from `git ls-files` UNIONED WITH
  # `git ls-files --others --exclude-standard`, so the tree has to be a
  # repository or the subject list is empty — and an empty subject list is a
  # clean sweep of nothing, which is the vacuous pass check 0 exists to refuse.
  discard runBounded("git", @["-C", result, "init", "-q"])

proc gateOver(tree: string): Ran =
  runBounded("bash", @[repoRoot / Gate, "--root", tree],
             budget = GateBudget)

proc slurpIfAny(path: string): string =
  ## `readFile` on a path that is not there RAISES, and an unhandled exception
  ## in a `unittest` case ends the whole SUITE — so one failed assertion would
  ## take every case after it with it and the run would report a defect it
  ## never reached. Reading absence as an empty string keeps a red case red and
  ## the ones after it running.
  if fileExists(path): readFile(path) else: ""

proc gateRefuses(gateOut: string; checkName: string): bool =
  ## The admission decision, read out of the gate's own output. ONE FUNCTION,
  ## called by the case that asserts the refusal AND by the case that acts on
  ## it (Verification-Harness-Traps §14) — written twice, the acting copy could
  ## go on agreeing with itself while the asserting copy was broken.
  ## The parameter is `checkName` and not `check` deliberately: a parameter
  ## named `check` SHADOWS `unittest.check` inside this proc, which is harmless
  ## here and is exactly the shape a wrapper-aware trap-13 sweep reports as a
  ## finding. Naming it out of the way costs nothing and keeps the sweep's
  ## output about defects.
  gateOut.contains("VIOLATION " & checkName)

proc admitAndRun(admitted: bool; bin, readSentinel, execSentinel: string): Ran =
  ## The model of a host that consults the gate before loading a plugin. It is
  ## the ONE runner both directions of the effect case go through, so the only
  ## difference between "the sentinels are there" and "the sentinels are not" is
  ## the boolean.
  if not admitted:
    return Ran(output: "REFUSED-AT-ADMISSION", code: 0)
  runBounded(bin, @[], input = readSentinel & "\n" & execSentinel & "\n")

var
  work: string
  posixBin: string
  ffiBin: string
  sysioBin: string

suite "PLAT-8: a plugin that declines to use the SDK":

  setup:
    if work.len == 0:
      # UNDER `build/`, NOT UNDER `/tmp`, and that is load-bearing rather than
      # tidy. `nim` reads `config.nims` from the project file's directory and
      # its ANCESTORS, and this repository's `config.nims` is what puts the
      # `isonim` sibling on the path. A probe staged in `/tmp` therefore fails
      # with `cannot open file: isonim/core/signals` — measured, first run —
      # and would have made every case below fail for a reason that has nothing
      # to do with the boundary. `/build/` is gitignored, so nothing staged
      # here can be picked up by the gate's own `git ls-files` seed scan.
      work = repoRoot / "build" / ("plat8-admission-" & $getCurrentProcessId())
      removeDir(work)
      createDir(work)

  test "the posix exploit is REAL — it reads the file and it reaches the shell":
    ## THE POSITIVE TWIN FOR EVERYTHING BELOW. A gate that refuses a program
    ## which could not have done anything is a gate that has proved nothing, and
    ## "the shell was not reached" is trivially true of a probe that never ran.
    let src = stageProbe(work, PosixProbe)
    posixBin = work / PosixProbe & ".bin"
    let built = compileProbe(src, posixBin)
    if built.code != 0: checkpoint(built.output)
    ck built.code == 0
    ck fileExists(posixBin)

    let readSentinel = work / "real-read.txt"
    let execSentinel = work / "real-exec.txt"
    let ran = runBounded(posixBin, @[],
                         input = readSentinel & "\n" & execSentinel & "\n")
    ck ran.code == 0
    ck ran.output.contains("POSIX-PROBE-DONE")

    # The EFFECT, both halves, against the filesystem rather than against the
    # probe's own summary line.
    ck fileExists(readSentinel)
    ck slurpIfAny(readSentinel).strip().len > 0
    ck fileExists(execSentinel)
    ck slurpIfAny(execSentinel).contains("SHELL-REACHED")

    # And it holds no grant of any kind: there is no manifest, no `GrantSet`
    # and no `decide` call anywhere in its path. That is the finding.
    ck not isAllowedStdlibModule("std/posix")

  test "the FFI exploit is REAL — one pragma is system(3), with nothing imported":
    ## THE ATTACK ON THE ALLOW-LIST, run as a program. This probe imports
    ## `codetracer_plugin` and NOTHING else, so an allow-list over imports does
    ## not see it at all.
    let src = stageProbe(work, FfiProbe)
    ffiBin = work / FfiProbe & ".bin"
    let built = compileProbe(src, ffiBin)
    if built.code != 0: checkpoint(built.output)
    ck built.code == 0
    ck fileExists(ffiBin)

    let sentinel = work / "real-ffi.txt"
    let ran = runBounded(ffiBin, @[], input = sentinel & "\n")
    ck ran.code == 0
    ck ran.output.contains("FFI-PROBE-DONE")
    ck fileExists(sentinel)
    ck slurpIfAny(sentinel).contains("FFI-REACHED")

  test "the system exploit is REAL — no import, no pragma, any file read and written":
    ## THE THIRD POSITIVE TWIN, and it is the one that shows both repairs
    ## missing the same plugin. `posix_raw_plugin` needs `import std/posix`,
    ## which the ALLOW-LIST refuses. `ffi_raw_plugin` needs `{.importc.}`,
    ## which the FFI DENYLIST refuses. This module's entire import list is
    ## `import codetracer_plugin` and it carries no pragma at all — `open`,
    ## `readBuffer`, `writeBuffer`, `close` and `File` are in its scope because
    ## `system` is auto-imported and ends with `export syncio`.
    ##
    ## It reproduces the allow-list's OWN motivating measurement, by a route
    ## the allow-list structurally cannot see.
    let src = stageProbe(work, SysioProbe)
    sysioBin = work / SysioProbe & ".bin"
    let built = compileProbe(src, sysioBin)
    if built.code != 0: checkpoint(built.output)
    ck built.code == 0
    ck fileExists(sysioBin)

    let readSentinel = work / "real-sysio-read.txt"
    let writeSentinel = work / "real-sysio-write.txt"
    let ran = runBounded(sysioBin, @[],
                         input = readSentinel & "\n" & writeSentinel & "\n")
    ck ran.code == 0
    ck ran.output.contains("SYSIO-PROBE-DONE")

    # THE EFFECT, AGAINST THE FILESYSTEM. The READ sentinel's CONTENT is the
    # evidence of the read — a file the probe merely created would prove
    # nothing about reading — and the WRITE sentinel's EXISTENCE is the
    # evidence of the write, at a path that did not exist before.
    ck fileExists(readSentinel)
    ck slurpIfAny(readSentinel).strip().len > 0
    ck slurpIfAny(readSentinel).strip() == slurpIfAny("/etc/hostname").strip()
    ck fileExists(writeSentinel)
    ck slurpIfAny(writeSentinel).contains("SYSIO-WRITE-OK")

    # AND NEITHER OF THE TWO EARLIER MECHANISMS HAS ANYTHING TO SAY ABOUT IT.
    # `system` is not a `std/` module spec, so the allow-list's own predicate
    # returns false for it in the same way it returns false for `std/posix` —
    # and that is beside the point, because there is no import statement here
    # for the allow-list to range over at all.
    ck not isAllowedStdlibModule("system")

  test "the gate refuses the sysio probe, naming the primitives":
    let tree = makeAdmissionTree(work, SysioProbe)
    let gate = gateOver(tree)
    if gate.output.count("VIOLATION ") != 1: checkpoint(gate.output)
    ck gate.code != 0
    ck gateRefuses(gate.output, SyncIoCheck)
    ck gate.output.contains(SysioProbe & ".nim:")
    # The names, and they are the ones the residual paragraph did not have.
    ck gate.output.contains(":open")
    ck gate.output.contains(":readBuffer")
    ck gate.output.contains(":writeBuffer")
    # ONE violation: the other two mechanisms have no opinion about this
    # module, which is exactly why it got through them.
    ck gate.output.count("VIOLATION ") == 1
    ck not gateRefuses(gate.output, AllowListCheck)
    ck not gateRefuses(gate.output, FfiCheck)

  test "under admission the file is neither read nor written":
    ## THE ACCEPTANCE CASE FOR THE THIRD EXPLOIT, asserting the EFFECT in both
    ## directions through one runner and one binary.
    let tree = makeAdmissionTree(work, SysioProbe)
    let gate = gateOver(tree)
    let admitted = not gateRefuses(gate.output, SyncIoCheck)
    ck not admitted

    let refusedRead = work / "refused-sysio-read.txt"
    let refusedWrite = work / "refused-sysio-write.txt"
    let refusedRun = admitAndRun(admitted, sysioBin, refusedRead, refusedWrite)
    ck refusedRun.output.contains("REFUSED-AT-ADMISSION")
    ck not fileExists(refusedRead)
    ck not fileExists(refusedWrite)

    let admittedRead = work / "admitted-sysio-read.txt"
    let admittedWrite = work / "admitted-sysio-write.txt"
    let admittedRun = admitAndRun(true, sysioBin, admittedRead, admittedWrite)
    ck admittedRun.output.contains("SYSIO-PROBE-DONE")
    ck fileExists(admittedRead)
    ck fileExists(admittedWrite)
    ck slurpIfAny(admittedWrite).contains("SYSIO-WRITE-OK")

  test "the gate refuses the posix probe, naming the module and the import":
    let tree = makeAdmissionTree(work, PosixProbe)
    let gate = gateOver(tree)
    if gate.output.count("VIOLATION ") != 1: checkpoint(gate.output)
    ck gate.code != 0
    ck gateRefuses(gate.output, AllowListCheck)
    ck gate.output.contains(PosixProbe & ".nim imports std/posix")
    ck gate.output.contains("which is not in PluginAllowedStdlibModules")
    # TWO violations, and they are NAMED — not "at least one", and not a general
    # redness. The tree carries the real configuration, so a gate reporting a
    # check nobody expected would mean the refusal rode in on something other
    # than the rules under test.
    #
    # IT WAS ONE UNTIL 2026-09-09 and the second one is the `system` sweep
    # arriving. `std/posix` spells its operations `open`, `read`, `write`,
    # `close` — and `open` is a denied NAME now, because `system` re-exports
    # `std/syncio` and the sweep put every routine that binds a path to a File
    # on `PluginDeniedSyncIo`. So this probe is refused by the import allow-list
    # AND by the name gate, and the overlap is structural rather than lucky: the
    # two mechanisms are named different things but `open` is one word.
    #
    # The old note said `open` could not be denied because `handles.open` was
    # the SDK's own proc. That proc is `registerHandle` now.
    ck gate.output.count("VIOLATION ") == 2
    ck gateRefuses(gate.output, SyncIoCheck)
    ck gate.output.contains(PosixProbe & ".nim:")

  test "the gate refuses the FFI probe, naming the pragma":
    let tree = makeAdmissionTree(work, FfiProbe)
    let gate = gateOver(tree)
    if gate.output.count("VIOLATION ") != 1: checkpoint(gate.output)
    ck gate.code != 0
    ck gateRefuses(gate.output, FfiCheck)
    ck gate.output.contains("binds a foreign function with 'importc'")
    ck gate.output.count("VIOLATION ") == 1
    # The allow-list has no opinion about this probe, which is the whole reason
    # check 21 exists: it imports nothing but the sanctioned surface.
    ck not gateRefuses(gate.output, AllowListCheck)

  test "under admission the file is not read and the shell is not reached":
    ## THE ACCEPTANCE CASE, and it asserts the EFFECT.
    let tree = makeAdmissionTree(work, PosixProbe)
    let gate = gateOver(tree)
    let admitted = not gateRefuses(gate.output, AllowListCheck)
    ck not admitted

    let refusedRead = work / "refused-read.txt"
    let refusedExec = work / "refused-exec.txt"
    let refusedRun = admitAndRun(admitted, posixBin, refusedRead, refusedExec)
    ck refusedRun.output.contains("REFUSED-AT-ADMISSION")
    ck not fileExists(refusedRead)
    ck not fileExists(refusedExec)

    # THE TWIN, THROUGH THE SAME RUNNER AND THE SAME BINARY. Without it the two
    # assertions above are satisfied by a binary that does not exist, a temp
    # directory that was never created and a runner with a typo in it —
    # Verification-Harness-Traps §4a, inside the case rather than beside it.
    let admittedRead = work / "admitted-read.txt"
    let admittedExec = work / "admitted-exec.txt"
    let admittedRun = admitAndRun(true, posixBin, admittedRead, admittedExec)
    ck admittedRun.output.contains("POSIX-PROBE-DONE")
    ck fileExists(admittedRead)
    ck fileExists(admittedExec)
    ck slurpIfAny(admittedExec).contains("SHELL-REACHED")

  test "under admission the FFI probe does not reach system(3) either":
    let tree = makeAdmissionTree(work, FfiProbe)
    let gate = gateOver(tree)
    let admitted = not gateRefuses(gate.output, FfiCheck)
    ck not admitted

    let refused = work / "refused-ffi.txt"
    let refusedRun = admitAndRun(admitted, ffiBin, refused, refused)
    ck refusedRun.output.contains("REFUSED-AT-ADMISSION")
    ck not fileExists(refused)

    let allowed = work / "admitted-ffi.txt"
    let allowedRun = admitAndRun(true, ffiBin, allowed, allowed)
    ck allowedRun.output.contains("FFI-PROBE-DONE")
    ck fileExists(allowed)

  test "the SDK's own internals are NOT what the surface hands a plugin":
    ## THE COMPLEMENT, and the refusals above are worth nothing without it.
    ##
    ## `codetracer_plugin` re-exports `plugin_host/plugin_io`, whose native arm
    ## imports `std/os`, `std/osproc`, `std/posix`, `std/net`,
    ## `std/nativesockets` and `std/asyncfile`. `plugin_io` is a TERMINAL of the
    ## gate's closure walk — reached, reported, and not entered — so NO check in
    ## the gate holds those imports against a plugin. The boundary therefore
    ## rests on the terminal re-exporting none of them, and that sentence is
    ## measured here rather than argued: if it ever stopped being true the
    ## allow-list would be intact and the boundary would be gone.
    let src = stageProbe(work, SurfaceProbe)
    let bin = work / SurfaceProbe & ".bin"
    let built = compileProbe(src, bin)
    if built.code != 0: checkpoint(built.output)
    ck built.code == 0
    let ran = runBounded(bin, @[])
    checkpoint(ran.output.strip())
    ck ran.output.contains("SURFACE-PROBE-DONE")
    ck ran.output.contains("osproc-reachable=false")
    ck ran.output.contains("posix-reachable=false")
    ck ran.output.contains("os-reachable=false")
    ck ran.output.contains("net-reachable=false")
    ck ran.output.contains("nativesockets-reachable=false")
    ck ran.output.contains("asyncfile-reachable=false")
    # The two positive halves. A probe on which everything is unreachable is a
    # probe that has stopped compiling anything, and `system` is the residual.
    ck ran.output.contains("future-reachable=true")
    ck ran.output.contains("system-readFile-reachable=true")

    # THE AsyncFD VOCABULARY. `export asyncdispatch except waitFor,
    # runForever, poll, drain` filters four names and leaves a socket
    # vocabulary on `AsyncFD` — an INTEGER — in every plugin's scope,
    # unqualified. Recorded as LATENT rather than repaired: a plugin cannot
    # mint an AsyncFD, so it would have to guess a descriptor the host owns.
    #
    # The two halves are asserted TOGETHER, because the second is what makes
    # the first latent, and a pass that asserted only the first would be
    # claiming a hole and a pass that asserted only the second would be
    # claiming a closure.
    ck ran.output.contains("asyncfd-connect-reachable=true")
    ck ran.output.contains("asyncfd-send-reachable=true")
    ck ran.output.contains("asyncfd-recv-reachable=true")
    ck ran.output.contains("asyncfd-accept-reachable=true")
    ck ran.output.contains("asyncfd-register-reachable=true")
    ck ran.output.contains("socket-mint-reachable=false")
    # AND `dial` IS REACHABLE, which sharpens the record: what stops a plugin
    # minting a socket through `dial` is the source gate's denied list, NOT the
    # language. Asserted so nobody upgrades "latent" into "impossible".
    ck ran.output.contains("dial-reachable=true")

    # THE `system` FAMILY, measured rather than described. Every one of these
    # is in the scope of a plugin importing nothing but the surface, which is
    # what makes the denied list the only thing in front of them.
    ck ran.output.contains("system-open-reachable=true")
    ck ran.output.contains("system-reopen-reachable=true")
    ck ran.output.contains("system-readBuffer-reachable=true")
    ck ran.output.contains("system-writeBuffer-reachable=true")
    ck ran.output.contains("system-slurp-reachable=true")
    ck ran.output.contains("system-getFileHandle-reachable=true")
    # THE METHODOLOGY FINDING, asserted so it cannot be forgotten:
    # `compiles(lines("x"))` is FALSE and `for l in lines("x")` compiles. A
    # `compiles`-shaped probe answers the question you spelled, and the
    # convenient spelling reports a name that reads any file as unreachable.
    ck ran.output.contains("system-lines-call-reachable=false")
    ck ran.output.contains("system-lines-for-reachable=true")

    # `cast` IS OUTSIDE THE DERIVED SCOPE, AND THAT SCOPE IS A CLAIM. The sweep
    # covers `std/syncio` and `system/compilation.nim`; `cast` is one of
    # `system.nim`'s other five hundred names. It fabricates a `File` out of an
    # integer, and `write` — undeniable, because it is the SDK's own spelling —
    # takes it. What that does NOT do is name a path: the value is a `FILE*`,
    # so it reaches a real file only by guessing an address the host already
    # holds, and the constant below is a null pointer.
    #
    # Asserted so the residual's "it cannot name a path" is read with the
    # caveat it carries, and so the day somebody widens the derivation this
    # case is the list of what widening it would have to cover.
    ck ran.output.contains("cast-to-File-reachable=true")
    ck ran.output.contains("cast-to-AsyncFD-reachable=true")
    ck ran.output.contains("write-to-cast-File-reachable=true")

    # AND IT IS CLEAN TO THE GATE. A plugin importing only the sanctioned
    # surface is admitted — the rule permits as well as refuses, which is what
    # keeps the two refusals above from being satisfied by a gate that says no
    # to everything.
    let tree = makeAdmissionTree(work, SurfaceProbe)
    let gate = gateOver(tree)
    if gate.code != 0: checkpoint(gate.output)
    ck gate.code == 0
    ck gate.output.contains("26 check(s), 0 failing")

  test "the assertion count is what this file says it is":
    ## Verification-Harness-Traps §4c. `unittest` ships no assertion counter, so
    ## a silent skip — an early `return`, a guard that swallowed a case — would
    ## leave the suite green with fewer assertions than it claims. The number is
    ## written from a run, and it fails until somebody moves it deliberately.
    check countedAssertions == 97
    # DECLARE THE TALLY TO THE LANE. `run-nim-test-lane.sh` reads
    # `CHECKS: <n>` out of a suite's OUTPUT; a file that prints none is
    # counted as unmeasured and named as such, because a CASE count is
    # not an assertion count (Verification-Harness-Traps 7).
    echo "CHECKS: " & $countedAssertions
    removeDir(work)
