## record_recognition_e2e_test.nim
##
## The NTR-2 delegation and the NTR-2 `--backend` refusal, driven through the
## **real, shipped `ct` binary** — milestone **NTR-2** of
## `codetracer-specs/Planned-Features/Native-Target-Recognition.md`.
##
## ## Why this exists beside `target_recognition_test.nim`
##
## That file asserts the delegation's *logic* by calling `detectTarget` and
## `resolveNativeRecordingBackend` directly.  A wrong-but-consistent wiring
## passes it: the recognizer could be spawned by a function nobody calls, the
## config discovery could resolve nothing, `--backend` could be validated in a
## branch `ct record` never reaches.  Every one of those is exactly the shape
## of the defect NTR-2 removes — the `debuginfo lang` call site was *correct
## Nim* that no `ct-native-replay` had ever been able to answer.
##
## So this file asserts the wiring instead, at the level a user hits:
##
## * `ct record <extension-less target>` really spawns
##   `ct-native-replay recognize --format=json <target>`, discovered from
##   `PATH` the way `src/common/config.nim` discovers it;
## * the recognizer's **answer** really selects the recorder — asserted with a
##   `primary` that uses a materialized trace, because a native `primary` and
##   `LangUnknown` take the *same* path and so cannot tell a consumed answer
##   from a discarded one (this file was blind to exactly that mutation until
##   the NTR-2 review added the case);
## * **Q7** — two `ct record` runs in a row spawn it twice as often as one run
##   does, so nothing was cached between invocations;
## * **Q8** — `ct record --lang <lang>` spawns it **zero** times, and still
##   selects the same backend, so `--lang` and `--backend` stay independent;
## * an **unrecognised schema** and a **non-zero recognizer exit** are both
##   reported by the shipped binary, by name;
## * **Q6** — `--backend` values this host cannot honour are refused with the
##   specified text and a non-zero exit, and honourable ones are not.
##
## ## How the recognizer is provided, and why that is not a mock
##
## Mocking justification (workspace policy on mock objects): **no mock object
## exists here.**  `ct` is the real binary, the recognizer is a real executable
## on a real `PATH`, spawned by the real `startProcess`, and nothing in the
## product is compiled differently for this test.  What the executable *prints*
## is scripted, for two reasons that are not about convenience:
##
## 1. `ct-native-replay` is **not on `PATH` in this repository's dev shell** —
##    it is a sibling repository the core discovers rather than bundles, which
##    is the very fact that makes the schema a cross-repository contract (Q5).
##    A test that required it would be red on every developer machine.
## 2. Three of the contracts asserted here — an unrecognised `schema`, a
##    non-zero exit, and (in the unit test) an `ambiguous-language` diagnostic —
##    **cannot be produced by a correct `ct-native-replay` at all**.  A
##    recognizer that could be made to emit a `v2` schema on demand would not
##    be the recognizer we ship.
##
## The real binary was additionally driven by hand during NTR-2 and the output
## is recorded in the milestone's verification block; this file is what keeps
## the wiring from rotting between those runs.
##
## Compile and run:
##   nim c -r src/tests/cli/record_recognition_e2e_test.nim

import std/[os, osproc, strutils, unittest]

const
  RecordTimeoutSeconds = 120
    ## Every case here fails fast by design; this only exists so a regression
    ## that hangs cannot wedge the lane.

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## The same binary `record_missing_recorder_test.nim` and the CLI smoke lane
  ## use, resolved the same way, so the three cannot disagree about what "the
  ## ct binary" means.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / "ct"

let scratch = getTempDir() / "ct-ntr2-record-e2e"

type
  Sandbox = object
    dir: string
    binDir: string
    configHome: string
    target: string
    spawnLog: string

proc writeStubRecognizer(box: Sandbox, body: string) =
  ## Install `<box.binDir>/ct-native-replay`.  `ct` finds it with `findExe`
  ## exactly as it finds the real one (src/common/config.nim's auto-discovery
  ## fires because the default config ships `rrBackend.path: ""`).
  let path = box.binDir / "ct-native-replay"
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                            fpGroupRead, fpGroupExec,
                            fpOthersRead, fpOthersExec})

proc newSandbox(name: string): Sandbox =
  let dir = scratch / name
  removeDir(dir)
  createDir(dir)
  result = Sandbox(
    dir: dir,
    binDir: dir / "bin",
    configHome: dir / "config",
    target: dir / "native-target",
    spawnLog: dir / "spawns.log")
  createDir(result.binDir)
  createDir(result.configHome)
  # An EXECUTABLE file with no extension: no extension signal can answer, and
  # `record.nim` must not try to build it.  This is the family of targets
  # NTR-1's routing rule exists to let through to the recognizer.
  writeFile(result.target, "#not-really-an-elf\n")
  setFilePermissions(result.target, {fpUserRead, fpUserWrite, fpUserExec})

proc runCt(box: Sandbox, args: seq[string]):
    tuple[output: string, exitCode: int] =
  ## Run the real `ct` with the sandbox's `bin` first on `PATH` and its own
  ## `XDG_CONFIG_HOME`, from inside the sandbox, so neither the developer's
  ## config nor a `.config.yaml` anywhere above the repo can change the answer.
  var cmd = "cd " & quoteShell(box.dir) & " && timeout " &
    $RecordTimeoutSeconds & " env" &
    " PATH=" & quoteShell(box.binDir & ":" & getEnv("PATH")) &
    " XDG_CONFIG_HOME=" & quoteShell(box.configHome) &
    " CT_NTR2_SPAWN_LOG=" & quoteShell(box.spawnLog) &
    " " & quoteShell(ctBinary())
  for arg in args:
    cmd.add(" " & quoteShell(arg))
  cmd.add(" 2>&1")
  execCmdEx(cmd)

proc recognizeSpawns(box: Sandbox): int =
  result = 0
  if fileExists(box.spawnLog):
    for line in readFile(box.spawnLog).splitLines:
      if line.startsWith("recognize"):
        result += 1

const CDocument = """{
  "schema": "codetracer.target-recognition.v1",
  "target": "TARGET",
  "kind": "executable",
  "primary": {"language": "c", "confidence": "likely", "weight": 1,
              "evidence": ["dwarf:sources=1"]},
  "components": [{"language": "c", "confidence": "likely", "weight": 1,
                  "evidence": ["dwarf:sources=1"]}],
  "interpreter": null,
  "format": {"container": "elf", "arch": "x86_64", "os": null,
             "pie": true, "stripped": false},
  "debug_info": {"present": true, "kind": "dwarf"},
  "recommended": {"recorder": "ct-mcr", "backend": "mcr",
                  "strategy": "native"},
  "diagnostics": []
}"""

proc answeringStub(document: string): string =
  ## A recognizer that logs its argv, answers `recognize` with `document`, and
  ## refuses anything else — so a recording attempt fails loudly instead of
  ## producing a trace for a program that never ran.
  ##
  ## POSIX only, like `record_missing_recorder_test.nim` beside it (which
  ## drives `ct` through `timeout` and `env`): `just test-cli-record` is a bash
  ## recipe and this whole lane runs under it.
  "#!/usr/bin/env bash\n" &
  "printf '%s\\n' \"$*\" >> \"${CT_NTR2_SPAWN_LOG:-/dev/null}\"\n" &
  "if [ \"$1\" = \"recognize\" ]; then\n" &
  "  cat <<'CT_NTR2_DOCUMENT'\n" &
  document & "\n" &
  "CT_NTR2_DOCUMENT\n" &
  "  exit 0\n" &
  "fi\n" &
  "echo \"stub ct-native-replay: refusing to run '$1'\" >&2\n" &
  "exit 9\n"

proc failingStub(exitCode: int, message: string): string =
  "#!/usr/bin/env bash\n" &
  "printf '%s\\n' \"$*\" >> \"${CT_NTR2_SPAWN_LOG:-/dev/null}\"\n" &
  "if [ \"$1\" = \"recognize\" ]; then\n" &
  "  echo " & quoteShell(message) & " >&2\n" &
  "  exit " & $exitCode & "\n" &
  "fi\n" &
  "echo \"stub ct-native-replay: refusing to run '$1'\" >&2\n" &
  "exit 9\n"

suite "NTR-2 end to end: the shipped ct delegates recognition":

  let ct = ctBinary()

  test "the ct binary under test exists":
    # A missing binary would turn every assertion below into a vacuous pass on
    # an empty string, so it is checked once and loudly rather than skipped.
    if not fileExists(ct):
      echo "ERROR: no ct binary at ", ct
      echo "  build it with `just build-once`, or set CODETRACER_E2E_CT_PATH."
    check fileExists(ct)

  test "ct record spawns `recognize --format=json <target>` for a native target":
    require fileExists(ct)
    let box = newSandbox("delegation")
    writeStubRecognizer(box, answeringStub(CDocument))

    let run = runCt(box, @["record", "-o", box.dir / "out", box.target])
    checkpoint("ct output:\n" & run.output)
    checkpoint("spawn log:\n" &
      (if fileExists(box.spawnLog): readFile(box.spawnLog) else: "<absent>"))

    # The delegation really happened, with the argv the design specifies.
    check recognizeSpawns(box) >= 1
    check ("recognize --format=json " & box.target) in readFile(box.spawnLog)

    # And it really answered: the recognizer's `c` reached the core, which
    # therefore took the NATIVE path and asked ct-native-replay to record.
    # Before NTR-2 this target was `LangUnknown` on this exact input, because
    # the delegation asked for a subcommand that does not exist.
    check "refusing to run 'record'" in run.output
    check run.exitCode != 0

  test "the recognizer's ANSWER selects the recorder, not merely the spawn":
    # REGRESSION GUARD, added by the NTR-2 review after a mutation exposed the
    # hole.  Every other case in this file uses a document whose `primary` is a
    # NATIVE language, and `LangUnknown` also takes the native path — so a
    # mutation that spawns the recognizer and then THROWS THE ANSWER AWAY
    # (`lang: LangUnknown` in `detectTarget`) left all of them green.  The unit
    # file killed it; this file could not tell, which is exactly the
    # "correct Nim that answers nothing" shape NTR-2 exists to remove.
    #
    # The discriminator is a `primary` whose language uses a MATERIALIZED trace:
    # if the answer is consumed, `ct` must not ask `ct-native-replay` to record
    # at all.  `rubydb` is chosen deliberately — it is one of the wire spellings
    # `langFromWireName` has to map by hand, so this also proves that mapping
    # end to end.
    require fileExists(ct)
    let box = newSandbox("answer-selects-recorder")
    writeStubRecognizer(box, answeringStub(
      CDocument.replace("\"language\": \"c\"", "\"language\": \"rubydb\"")))

    let run = runCt(box, @["record", "-o", box.dir / "out", box.target])
    checkpoint("ct output:\n" & run.output)
    checkpoint("spawn log:\n" &
      (if fileExists(box.spawnLog): readFile(box.spawnLog) else: "<absent>"))

    check recognizeSpawns(box) >= 1
    # THE assertion: the native recorder was never selected, because the
    # delegation said this target is not native.
    check "refusing to run 'record'" notin run.output

  test "Q7: two recordings in a row recognize twice — nothing is cached":
    require fileExists(ct)
    let box = newSandbox("no-cache")
    writeStubRecognizer(box, answeringStub(CDocument))

    discard runCt(box, @["record", "-o", box.dir / "out1", box.target])
    let afterFirst = recognizeSpawns(box)
    checkpoint("spawns after one `ct record`: " & $afterFirst)
    check afterFirst >= 1

    discard runCt(box, @["record", "-o", box.dir / "out2", box.target])
    let afterSecond = recognizeSpawns(box)
    checkpoint("spawns after two `ct record`s: " & $afterSecond)

    # Stated as a RATIO rather than as the literal number 2, because one
    # `ct record` legitimately spawns the recognizer more than once: `ct` and
    # the `db-backend-record` process it starts each recognize in their own
    # process, and Q7 permits carrying a result only within ONE invocation.
    # What Q7 forbids is the second RECORDING reusing the first's answer, and
    # that is exactly what this equality pins.
    check afterSecond == afterFirst * 2

    # The ratio is the right shape for Q7 and is, by construction, blind to a
    # THIRD spawn appearing — 3 and 6 satisfy it as happily as 2 and 4.  The
    # per-recording count is therefore pinned separately and as an ABSOLUTE:
    # one `ct record` spawns `recognize` exactly TWICE, once in `record()` and
    # once inside the `db-backend-record` process it starts
    # (`src/ct/db_backend_record.nim:384`).  That is duplicated work, not a
    # cache, and it is recorded rather than smoothed over — but a fourth caller
    # appearing should be a deliberate decision, not a silent one, so it fails
    # here first.
    check afterFirst == 2

  test "Q8: --lang skips recognition entirely, and does not move the backend":
    require fileExists(ct)
    let box = newSandbox("lang-skips")
    writeStubRecognizer(box, answeringStub(CDocument))

    let pinned = runCt(box, @["record", "--lang", "c", "-o", box.dir / "out",
                              box.target])
    checkpoint("ct output:\n" & pinned.output)
    checkpoint("spawn log:\n" &
      (if fileExists(box.spawnLog): readFile(box.spawnLog) else: "<absent>"))

    # Not "spawned and overruled" — not spawned.
    check recognizeSpawns(box) == 0
    # It still reached the native path, so `--lang` did not change which
    # backend records: the two axes are independent (design §5.1).
    check "refusing to run 'record'" in pinned.output

    # The other direction, on the very same target and the same stub: without
    # `--lang` it IS spawned.  Direction one alone also passes if the
    # delegation is broken outright, so both are required.
    let box2 = newSandbox("lang-absent")
    writeStubRecognizer(box2, answeringStub(CDocument))
    discard runCt(box2, @["record", "-o", box2.dir / "out", box2.target])
    check recognizeSpawns(box2) >= 1

  test "an unrecognised schema is refused by name, not mis-parsed":
    require fileExists(ct)
    let box = newSandbox("schema-skew")
    writeStubRecognizer(box, answeringStub(
      CDocument.replace("codetracer.target-recognition.v1",
                        "codetracer.target-recognition.v2")))

    let run = runCt(box, @["record", "-o", box.dir / "out", box.target])
    checkpoint("ct output:\n" & run.output)
    check "codetracer.target-recognition.v2" in run.output
    check "codetracer.target-recognition.v1" in run.output
    check "does not understand" in run.output
    # Refused, not parsed: the `c` in that document must not have been used.
    check run.exitCode != 0

  test "a non-zero recognizer exit is reported, not read as `no language`":
    require fileExists(ct)
    let box = newSandbox("recognizer-fails")
    writeStubRecognizer(box, failingStub(3, "boom: the recognizer failed"))

    let run = runCt(box, @["record", "-o", box.dir / "out", box.target])
    checkpoint("ct output:\n" & run.output)
    check "recognize failed" in run.output
    check "boom: the recognizer failed" in run.output
    check run.exitCode != 0

  test "Q6: an unhonourable --backend is refused before anything is recorded":
    require fileExists(ct)
    let unhonourable =
      when defined(macosx): @["rr", "ttd", "nonsense"]
      elif defined(windows): @["rr", "nonsense"]
      else: @["ttd", "nonsense"]
    let host =
      when defined(macosx): "macos"
      elif defined(windows): "windows"
      elif defined(linux): "linux"
      else: "other"

    for value in unhonourable:
      checkpoint("--backend " & value)
      let box = newSandbox("refuse-" & value)
      writeStubRecognizer(box, answeringStub(CDocument))
      let run = runCt(box, @["record", "--backend", value, "-o",
                             box.dir / "out", box.target])
      checkpoint("ct output:\n" & run.output)
      check run.exitCode != 0
      check ("--backend " & value) in run.output
      check ("host:      " & host) in run.output
      check ("valid on " & host & ":") in run.output
      # Refused before the recorder was reached: the stub never saw `record`.
      check "refusing to run 'record'" notin run.output

  test "Q6: the desktop's `--backend db` still records a native target":
    # REGRESSION GUARD, found by the NTR-2 review against the shipped `ct`.
    #
    # The desktop sends `--backend db` for every recording whose target it did
    # not classify as native — including a file with an unrecognised extension
    # (`recordTargetAuto`) and a `.lua` script, both of which the CORE resolves
    # to a language that does not use materialized traces.  Those recordings
    # therefore arrive here, on the native path, carrying `db`.  Refusing them
    # exits 1 on a recording the user never passed a flag for; before NTR-2 the
    # same invocation recorded, because the value was coerced to `mcr`.
    #
    # So: not refused, a note on stderr, and the recorder really reached.
    require fileExists(ct)
    let box = newSandbox("materialized-sentinel")
    writeStubRecognizer(box, answeringStub(CDocument))
    let run = runCt(box, @["record", "--backend", "db", "-o",
                           box.dir / "out", box.target])
    checkpoint("ct output:\n" & run.output)
    check "is not a recognized recording backend" notin run.output
    check "cannot be honoured on this host" notin run.output
    check "names the materialized-trace recorder" in run.output
    # It got all the way to the recorder, which is the stub refusing to be one.
    check "refusing to run 'record'" in run.output

  test "Q6: a value this host CAN honour is not refused":
    require fileExists(ct)
    let honourable =
      when defined(macosx): @["mcr"]
      elif defined(windows): @["mcr", "ttd"]
      else: @["mcr", "rr"]

    for value in honourable:
      checkpoint("--backend " & value)
      let box = newSandbox("honour-" & value)
      writeStubRecognizer(box, answeringStub(CDocument))
      let run = runCt(box, @["record", "--backend", value, "-o",
                             box.dir / "out", box.target])
      checkpoint("ct output:\n" & run.output)
      check "cannot be honoured on this host" notin run.output
      check "is not a recognized recording backend" notin run.output
      # It got all the way to the recorder, which is the stub refusing to be
      # one.  `--backend mcr` is therefore a PIN that really reaches the
      # native path rather than a value that merely happens to equal the
      # default.
      check "refusing to run 'record'" in run.output
