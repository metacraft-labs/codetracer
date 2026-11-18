## record_missing_recorder_test.nim
##
## What `ct record` does when the recorder for the detected language is not
## installed — asserted through the real `ct` binary, at the level a user hits.
##
## The Python path already modelled the right behaviour: `checkPythonRecorder`
## in `src/ct/trace/record.nim` probes the interpreter and, when the module is
## absent, prints a precise "install it with `python -m pip install
## codetracer_python_recorder`" and exits non-zero.  No other language had
## anything.  Ruby, JavaScript, bash, zsh and the twelve blockchain recorders
## resolved their binary out of `paths.nim` and spawned it without checking
## the lookup had succeeded — with nothing on PATH the exe was the empty
## string, `startProcess` raised, `db_backend_record`'s `except CatchableError`
## swallowed the exception, and `ct` registered a trace for a recording that
## never ran.  PHP, Elixir and Erlang had no dispatch arm at all and produced
## `ERROR: unsupported trace kind db` **with exit status 0**.
##
## So this test asserts the three things that were each independently broken:
##
## 1. the exit code is non-zero — a script or CI job that checks `$?` must see
##    the failure;
## 2. the message names the LANGUAGE, so the user knows which of their files
##    could not be recorded;
## 3. the message names the REMEDY — the sibling repo that builds the
##    recorder, and the environment variable that points at an existing build.
##
## ## How "recorder absent" is simulated
##
## By running the real `ct` with `PATH` scrubbed to a directory that contains
## nothing, and with every `CODETRACER_*` recorder override cleared.  That is
## genuinely the end-user situation: `paths.nim` resolves every recorder at
## process start from those overrides and then from `PATH`, so a scrubbed
## environment is the same state as a machine where the recorders were never
## installed.  Nothing is stubbed and no production code is altered for the
## test — `ct` itself is invoked by absolute path and finds its own
## `db-backend-record` through `CODETRACER_PREFIX`, neither of which needs
## `PATH`.
##
## Mocking justification (workspace policy on mock objects): none. There is no
## mock object in this file. The "absent recorder" is produced by removing the
## recorders from the child process's environment, which is a real
## environment, not a test double.
##
## Compile and run:
##   nim c -r src/tests/cli/record_missing_recorder_test.nim

import std/[os, osproc, strutils, times, unittest]
import results
when NimMajor >= 2:
  import ../../db_connector/db_sqlite
else:
  import impure/db_sqlite
from codetracer_trace_writer/multi_stream_writer import
  initMultiStreamWriter, registerPath, registerStep, close, closeCtfs
import ../../common/lang

const
  RecordTimeoutSeconds = 120
    ## A run that cannot find its recorder should fail immediately; this
    ## exists so a regression that hangs cannot wedge the lane.

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## The same binary the CLI smoke lane uses
  ## (``ci/test/cli-record-smoke.sh``), so this test and that one cannot
  ## disagree about what "the ct binary" means.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug-repro")
  result = buildDir / "bin" / "ct"

type
  MissingCase = object
    lang: Lang
    extension: string
    source: string          ## a minimal, syntactically valid program
    remedyFragments: seq[string]
      ## substrings the diagnostic MUST contain: the sibling repo and the
      ## override variable are what make the message actionable.

const MissingCases = [
  MissingCase(
    lang: LangPhp, extension: "php", source: "<?php\necho \"hi\\n\";\n",
    remedyFragments: @["codetracer-php-recorder",
                       "CODETRACER_PHP_RECORDER_EXTENSION"]),
  MissingCase(
    lang: LangRubyDb, extension: "rb", source: "puts \"hi\"\n",
    remedyFragments: @["codetracer-ruby-recorder",
                       "CODETRACER_RUBY_RECORDER_PATH"]),
  MissingCase(
    lang: LangJavascript, extension: "js", source: "console.log(\"hi\")\n",
    remedyFragments: @["codetracer-js-recorder",
                       "CODETRACER_JS_RECORDER_PATH"]),
  MissingCase(
    lang: LangElixir, extension: "exs", source: "IO.puts \"hi\"\n",
    remedyFragments: @["codetracer-beam-recorder",
                       "CODETRACER_BEAM_RECORDER_BIN"]),
  MissingCase(
    lang: LangErlang, extension: "erl",
    source: "main(_) -> io:format(\"hi~n\").\n",
    remedyFragments: @["codetracer-beam-recorder",
                       "CODETRACER_BEAM_RECORDER_BIN"]),
  MissingCase(
    lang: LangBash, extension: "sh", source: "echo hi\n",
    remedyFragments: @["codetracer-shell-recorders"]),
  MissingCase(
    lang: LangCairo, extension: "cairo", source: "fn main() {}\n",
    remedyFragments: @["codetracer-cairo-recorder",
                       "CODETRACER_CAIRO_RECORDER_PATH"]),
]

const ClearedOverrides = [
  # Every override `paths.nim` consults for a recorder. Clearing them plus
  # scrubbing PATH is what makes the child see "nothing installed".
  "CODETRACER_PHP_EXE_PATH", "CODETRACER_PHP_RECORDER_EXTENSION",
  "CODETRACER_PHP_RECORDER_PATH",
  "CODETRACER_RUBY_EXE_PATH", "CODETRACER_RUBY_RECORDER_PATH",
  "CODETRACER_JS_RECORDER_PATH",
  "CODETRACER_BEAM_RECORDER_BIN", "CODETRACER_ELIXIR_RECORDER_BIN",
  "CODETRACER_ELIXIR_EXE_PATH", "CODETRACER_ESCRIPT_EXE_PATH",
  "CODETRACER_PYTHON_INTERPRETER", "PYTHON_EXECUTABLE", "PYTHONEXECUTABLE",
  "PYTHON",
  "CODETRACER_NOIR_EXE_PATH", "CODETRACER_WASM_VM_PATH",
  "CODETRACER_CT_MCR_CMD", "CODETRACER_CT_MCR_PATH",
  "CODETRACER_NATIVE_SERVER_RECORDER_PATH",
  "CODETRACER_CAIRO_RECORDER_PATH", "CODETRACER_MIDEN_RECORDER_PATH",
  "CODETRACER_MOVE_RECORDER_PATH", "CODETRACER_SOLANA_RECORDER_PATH",
  "CODETRACER_FUEL_RECORDER_PATH", "CODETRACER_CIRCOM_RECORDER_PATH",
  "CODETRACER_LEO_RECORDER_PATH", "CODETRACER_POLKAVM_RECORDER_PATH",
  "CODETRACER_TON_RECORDER_PATH", "CODETRACER_CARDANO_RECORDER_PATH",
  "CODETRACER_FLOW_RECORDER_PATH", "CODETRACER_EVM_RECORDER_PATH",
]

proc runWithoutRecorders(ct, program, outDir, emptyDir: string;
                         extra: seq[string] = @[];
                         setVars: seq[(string, string)] = @[];
                         timeoutSeconds = RecordTimeoutSeconds):
    tuple[output: string, exitCode: int] =
  ## Run the real `ct record` in an environment where no recorder can be
  ## found.  `env -i` is deliberately NOT used: `ct` needs HOME (for
  ## ~/.local/share/codetracer) and the loader variables the Nix-built
  ## binary was linked with, and the point of the test is the recorder
  ## lookup, not a hermetic environment.
  ##
  ## ``setVars`` is applied AFTER the overrides are cleared, so a case can
  ## point exactly one recorder override at a binary of its own.
  # `env` does the unsetting and the PATH replacement, so the scrubbed PATH
  # applies to `ct` ONLY.  Setting PATH in the shell instead would also hide
  # `timeout` from the shell itself, which silently turns every assertion
  # below into a check against "timeout: command not found".
  var cmd = "timeout " & $timeoutSeconds & " env"
  for name in ClearedOverrides:
    cmd.add(" -u " & name)
  for (name, value) in setVars:
    cmd.add(" " & name & "=" & quoteShell(value))
  cmd.add(" PATH=" & quoteShell(emptyDir))
  cmd.add(" " & quoteShell(ct) & " record -o " & quoteShell(outDir))
  for arg in extra:
    cmd.add(" " & quoteShell(arg))
  cmd.add(" " & quoteShell(program) & " 2>&1")
  execCmdEx(cmd)

const
  StaleNargoVersion = "nargo version = 0.36.0-stale-fixture"
    ## What the fake recorder below prints for ``--version``, so the case can
    ## check that ``ct`` reports the RECORDER's version and not only the
    ## container's.

proc writeContainerAtVersion(root: string, version: int): string =
  ## A container written by the pinned writer (``codetracer-trace-format-nim``'s
  ## ``MultiStreamTraceWriter``, the library nargo links), with its container
  ## version byte (offset 5, ``ctfs-container.md`` §1) set to ``version``.
  ## That is exactly what a nargo built against an older writer leaves behind:
  ## the reader refuses it on that byte alone, before reading anything else.
  let fresh = root / "fresh.ct"
  let src = root / "main.nr"
  writeFile(src, "fn main() {}\n")
  var w = initMultiStreamWriter(fresh, src).get()
  let pathId = w.registerPath(src).get()
  w.registerStep(pathId, 1'u64, []).get()
  w.close().get()
  w.closeCtfs().get()
  var data = readFile(fresh)
  data[5] = char(version)
  result = root / ("container-v" & $version & ".ct")
  writeFile(result, data)

proc writeContainerWithMetaDatVersion(root: string, version: int): string =
  ## The pinned writer's container (``writeContainerAtVersion``'s
  ## ``fresh.ct``, at the container version this reader reads) with the
  ## ``meta.dat`` schema version -- the u16 after its ``CTMD`` magic
  ## (``internal-files.md`` §"Metadata (meta.dat)") -- set to ``version``.
  ## ``meta.dat`` is a few dozen bytes, so it sits whole in one block and is
  ## found by its magic and current version, which must occur exactly once.
  discard writeContainerAtVersion(root, 5)   # leaves the unpatched fresh.ct
  var data = readFile(root / "fresh.ct")
  let header = "CTMD" & char(7) & char(0)
  let at = data.find(header)
  doAssert at >= 0 and data.find(header, at + 1) < 0,
    "fixture: expected exactly one meta.dat v7 header in the writer's container"
  data[at + 4] = char(version and 0xff)
  data[at + 5] = char(version shr 8)
  result = root / ("metadat-v" & $version & ".ct")
  writeFile(result, data)

proc writeFakeNargo(root, container: string;
                    versionBody = "echo " & quoteShell(StaleNargoVersion) &
                                  "; exit 0"): string =
  ## A stand-in for a STALE nargo: ``nargo trace --out-dir <dir>`` copies
  ## ``container`` into ``<dir>`` and prints nargo's own success line, then
  ## exits 0 -- the reporter's sequence in #909.  ``--version`` runs
  ## ``versionBody``, by default answering like nargo does.  Only absolute
  ## paths are used: ``PATH`` is scrubbed.
  result = root / "stale-nargo"
  writeFile(result, "#!/bin/sh\n" &
    "if [ \"$1\" = \"--version\" ]; then " & versionBody & "; fi\n" &
    "out=\"\"\n" &
    "while [ $# -gt 0 ]; do\n" &
    "  if [ \"$1\" = \"--out-dir\" ]; then out=\"$2\"; fi\n" &
    "  shift\n" &
    "done\n" &
    "/bin/cp " & quoteShell(container) & " \"$out/trace.ct\" || exit 3\n" &
    "echo \"Saved trace to $out\"\n")
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc traceIndexRows(home: string): int =
  ## The rows of the trace index ``ct`` keeps under ``CODETRACER_HOME``
  ## (``$CODETRACER_HOME/data/trace_index.db``; ``trace_index.nim``,
  ## ``ct_home.nim``).  0 when no index, or no ``recordings`` table, exists yet:
  ## `ct` opens the file before it records, and creates the table only when
  ## it registers.  A "no row" check built on this is only worth something
  ## next to a run that DOES add one in the same home, which the #909 case's
  ## control arm is.
  let db = home / "data" / "trace_index.db"
  if not fileExists(db):
    return 0
  let conn = open(db, "", "", "")
  defer: conn.close()
  if conn.getValue(sql"SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'recordings'") == "0":
    return 0
  parseInt(conn.getValue(sql"SELECT COUNT(*) FROM recordings"))

proc writeNoirPackage(root: string): string =
  ## The smallest Noir package ``ct record`` detects as Noir: nargo traces
  ## the package it is run inside (``recorderInvocation``, EXCEPTION 3).
  result = root / "pkg"
  createDir(result / "src")
  writeFile(result / "Nargo.toml",
    "[package]\nname = \"pkg\"\ntype = \"bin\"\nauthors = [\"\"]\n\n[dependencies]\n")
  writeFile(result / "src" / "main.nr", "fn main() {}\n")

suite "ct record missing-recorder diagnostics":

  let ct = ctBinary()
  let scratch = getTempDir() / "ct-missing-recorder-test"
  let emptyDir = scratch / "empty-path"

  setup:
    createDir(emptyDir)

  test "the ct binary under test exists":
    # A missing binary would turn every assertion below into a vacuous pass
    # on an empty string, so it is checked once and loudly.
    if not fileExists(ct):
      echo "ERROR: no ct binary at ", ct
      echo "  build it with `just build-once`, or set CODETRACER_E2E_CT_PATH."
    check fileExists(ct)

  test "each language fails loudly and actionably when its recorder is absent":
    require fileExists(ct)
    for missing in MissingCases:
      checkpoint("language: " & missing.lang.toName)
      let dir = scratch / ($missing.lang)
      removeDir(dir)
      createDir(dir)
      let program = dir / ("program." & missing.extension)
      writeFile(program, missing.source)

      let (output, exitCode) = runWithoutRecorders(
        ct, program, dir / "out", emptyDir)
      checkpoint("ct output:\n" & output)

      # 1. Non-zero exit. `ct record app.php` used to print an error and
      #    exit 0, which no caller could detect.
      check exitCode != 0

      # 2. The message names the language — the SOURCE language, on its own
      #    axis (`displayName(slRuby) == "Ruby"`), not the `toName` of the
      #    member, which until LRS-4 spelled a language and a recording mode
      #    by hand in one string (`"Ruby(db)"`; it is `"Ruby"` now that the
      #    retired pair partner is gone).  Since LRS-2B the diagnostic is
      #    built from the selector, so this is what a user reads.
      check displayName(sourceLanguageOf(missing.lang)) in output

      # 3. The message names the remedy.
      for fragment in missing.remedyFragments:
        checkpoint("  remedy must mention: " & fragment)
        check fragment in output

      # 4. And never silently falls through to a different backend.
      check "unsupported trace kind" notin output
      check "recordingId:" notin output

  test "a recorder that writes a refused container version is named, with both versions, and no re-record advice (#909)":
    require fileExists(ct)
    # GitHub #909: `ct record test-programs/noir_space_ship` -- nargo printed
    # `Saved trace to ...` and exited 0, then `ct` failed with the READER's
    # text, "CTFS container version 4 is not readable: this reader reads
    # versions 5 and 6. Re-record the trace".  Re-recording ran the same nargo
    # and wrote version 4 again.  The container is seconds old; the recorder
    # is what is old.  `CLI/ct/record.md` §"Corner Cases": "Recorder present
    # but wrong version.  Report both versions; do not attempt a
    # compatibility shim."  So the refusal stays (non-zero exit, nothing
    # registered), but the message names the recorder `ct` ran, its own
    # version, the container version it wrote and the ones this `ct` reads,
    # and the override that points `ct` at another recorder.
    let dir = scratch / "stale-recorder"
    removeDir(dir)
    createDir(dir)
    let container = writeContainerAtVersion(dir, 4)
    let nargo = writeFakeNargo(dir, container)
    let pkg = writeNoirPackage(dir)
    let home = dir / "home"
    createDir(home)

    let (output, exitCode) = runWithoutRecorders(
      ct, pkg, dir / "out", emptyDir,
      setVars = @[("CODETRACER_NOIR_EXE_PATH", nargo),
                  ("CODETRACER_HOME", home)])
    checkpoint("ct output:\n" & output)

    # The fake recorder really ran and succeeded: this is #909's sequence,
    # not a missing-recorder failure.
    check "Saved trace to" in output
    check "was not found" notin output

    # The refusal stays, and nothing is registered: no row in the trace
    # index of this run's own home.
    check exitCode != 0
    check "recordingId:" notin output
    check traceIndexRows(home) == 0

    # Both versions: the container version the recorder wrote, the ones this
    # reader reads, and the recorder's own `--version`.
    check "version 4" in output
    check "5 and 6" in output
    check StaleNargoVersion in output

    # The recorder, by the path `ct` ran, and the way to point at another.
    check nargo in output
    check "CODETRACER_NOIR_EXE_PATH" in output

    # And not the advice that cannot work: re-recording runs the same binary.
    check "Re-record the trace" notin output
    # It is the recorder that is behind, not `ct`.
    check "the recorder is out of date" in output
    check "update ct" notin output

    # The control: the same writer's container at its OWN version, through
    # the same fake recorder, records and registers.  So the refusal above is
    # the version byte's doing, not the fixture's or the fake recorder's.
    createDir(dir / "current")
    let currentNargo = writeFakeNargo(dir / "current",
      dir / "fresh.ct") # `writeContainerAtVersion` left the unpatched one here
    let (controlOutput, controlExit) = runWithoutRecorders(
      ct, pkg, dir / "out-current", emptyDir,
      setVars = @[("CODETRACER_NOIR_EXE_PATH", currentNargo),
                  ("CODETRACER_HOME", home)])
    checkpoint("control ct output:\n" & controlOutput)
    check controlExit == 0
    check "recordingId:" in controlOutput
    check "is not readable" notin controlOutput
    # ...and its row lands in the index the refused run was checked against,
    # so `traceIndexRows(home) == 0` above could see a row had there been one.
    check traceIndexRows(home) == 1

  test "a recorder that writes a NEWER container version than ct reads is named, and the advice is to update ct (#909 review)":
    require fileExists(ct)
    # The other direction of #909: the recorder writes container version 7
    # and this `ct` reads 5 and 6.  The container is just as fresh, but now
    # it is `ct` that is behind -- pointing `ct` at "a current recorder"
    # would replace the one part that is current.
    let dir = scratch / "newer-recorder"
    removeDir(dir)
    createDir(dir)
    let nargo = writeFakeNargo(dir, writeContainerAtVersion(dir, 7))
    let pkg = writeNoirPackage(dir)
    let home = dir / "home"
    createDir(home)

    let (output, exitCode) = runWithoutRecorders(
      ct, pkg, dir / "out", emptyDir,
      setVars = @[("CODETRACER_NOIR_EXE_PATH", nargo),
                  ("CODETRACER_HOME", home)])
    checkpoint("ct output:\n" & output)
    check "Saved trace to" in output
    check exitCode != 0
    check "recordingId:" notin output
    check traceIndexRows(home) == 0
    # Both versions, still.
    check "version 7" in output
    check "5 and 6" in output
    check StaleNargoVersion in output
    check nargo in output
    # The stale party is `ct`.
    check "update ct" in output
    check "the recorder is out of date" notin output
    check "Re-record the trace" notin output

  test "a recorder that writes a refused meta.dat version is named, older or newer than ct reads (#909 review)":
    require fileExists(ct)
    # The second version `ct` gates on: the container version is one it
    # reads, the `meta.dat` schema version is not.  Older (6): the recorder
    # is behind.  Newer (8): `ct` is.
    for (version, recorderBehind) in [(6, true), (8, false)]:
      checkpoint("meta.dat version " & $version)
      let dir = scratch / ("metadat-v" & $version)
      removeDir(dir)
      createDir(dir)
      let nargo = writeFakeNargo(dir, writeContainerWithMetaDatVersion(dir, version))
      let pkg = writeNoirPackage(dir)
      let home = dir / "home"
      createDir(home)

      let (output, exitCode) = runWithoutRecorders(
        ct, pkg, dir / "out", emptyDir,
        setVars = @[("CODETRACER_NOIR_EXE_PATH", nargo),
                    ("CODETRACER_HOME", home)])
      checkpoint("ct output:\n" & output)
      check "Saved trace to" in output
      check exitCode != 0
      check traceIndexRows(home) == 0
      check ("meta.dat version " & $version) in output
      check "version 7 only" in output
      check nargo in output
      check StaleNargoVersion in output
      check "Re-record the trace" notin output
      if recorderBehind:
        check "the recorder is out of date" in output
        check "update ct" notin output
      else:
        check "update ct" in output
        check "the recorder is out of date" notin output

  test "a recorder whose --version hangs does not hold up the refusal beyond the probe's cap (#909 review)":
    require fileExists(ct)
    # `ct` asks the recorder for its `--version` only to REPORT it, after the
    # refusal is already decided, and caps that at 5 s
    # (`recorder_version_probe.RecorderVersionProbeTimeoutMs`).  A recorder
    # that is a `/bin/sh` wrapper (nargo often is one) and whose `--version`
    # child outlives the cap must not make `ct` wait for that child: the
    # review measured 20 s for `sleep 20; echo late`.  The fake sleeps 40 s;
    # the run gets 90 s, so a `ct` that waits it out is still red by name,
    # on the elapsed time, and a wedged one by the 124 watchdog.
    let dir = scratch / "hanging-version"
    removeDir(dir)
    createDir(dir)
    let nargo = writeFakeNargo(dir, writeContainerAtVersion(dir, 4),
                               versionBody = "/bin/sleep 40; echo late; exit 0")
    let pkg = writeNoirPackage(dir)
    let home = dir / "home"
    createDir(home)

    let started = epochTime()
    let (output, exitCode) = runWithoutRecorders(
      ct, pkg, dir / "out", emptyDir,
      setVars = @[("CODETRACER_NOIR_EXE_PATH", nargo),
                  ("CODETRACER_HOME", home)],
      timeoutSeconds = 90)
    let elapsed = epochTime() - started
    checkpoint("ct output:\n" & output)
    checkpoint("elapsed: " & formatFloat(elapsed, ffDecimal, 1) & " s")
    check exitCode != 124                       # the watchdog did not fire
    check exitCode != 0
    check "Saved trace to" in output
    check "reported no version" in output
    check "late" notin output
    # The 5 s cap, 1 s between the probe's SIGTERM and SIGKILL, and the
    # recording itself, with slack for a loaded host: far below 40 s.
    check elapsed < 5.0 + 1.0 + 10.0

  test "a recorder whose --version fails is reported as giving no version (#909 review)":
    require fileExists(ct)
    # An error text is not a version: quoting it as "reports: ..." puts the
    # recorder's complaint where its version belongs.
    let dir = scratch / "failing-version"
    removeDir(dir)
    createDir(dir)
    let nargo = writeFakeNargo(dir, writeContainerAtVersion(dir, 4),
      versionBody = "echo 'error: unrecognized option --version'; exit 2")
    let pkg = writeNoirPackage(dir)
    let home = dir / "home"
    createDir(home)

    let (output, exitCode) = runWithoutRecorders(
      ct, pkg, dir / "out", emptyDir,
      setVars = @[("CODETRACER_NOIR_EXE_PATH", nargo),
                  ("CODETRACER_HOME", home)])
    checkpoint("ct output:\n" & output)
    check exitCode != 0
    check "Saved trace to" in output
    check "reported no version" in output
    check "unrecognized option" notin output

  test "no trace is registered for a recording that never happened":
    require fileExists(ct)
    let dir = scratch / "no-trace"
    removeDir(dir)
    createDir(dir)
    let program = dir / "program.php"
    writeFile(program, "<?php\necho \"hi\\n\";\n")
    let outDir = dir / "out"

    let (output, exitCode) = runWithoutRecorders(ct, program, outDir, emptyDir)
    checkpoint("ct output:\n" & output)
    check exitCode != 0

    # The old failure mode left an output folder behind and a row in the
    # trace index, so `ct list` showed a recording that could not be opened.
    var produced: seq[string] = @[]
    if dirExists(outDir):
      for path in walkDirRec(outDir):
        produced.add(path)
    checkpoint("files under " & outDir & ": " & produced.join(", "))
    check produced.len == 0

  test "--server on a language without server support is rejected":
    require fileExists(ct)
    let dir = scratch / "server-unsupported"
    removeDir(dir)
    createDir(dir)
    # `.nr` is a language with a real recorder but no server story, so this
    # exercises the --server guard rather than the missing-recorder guard.
    let program = dir / "program.nr"
    writeFile(program, "fn main() {}\n")

    let (output, exitCode) = runWithoutRecorders(
      ct, program, dir / "out", emptyDir, extra = @["--server"])
    checkpoint("ct output:\n" & output)
    check exitCode != 0
    check "--server" in output
    check displayName(sourceLanguageOf(LangNoir)) in output

  test "--lang ruby names the working Ruby recorder, and --lang ruby(db) is announced as deprecated (LRS-4, Q6)":
    require fileExists(ct)
    # Before LRS-4 `--lang ruby` named `LangRuby`, the retired rr backend, and
    # `ct record --lang ruby foo.rb` printed "CodeTracer has no recorder for
    # Ruby" with advice to "pass `--lang ruby(db)`".  Now both spellings reach
    # the Ruby recorder -- which is absent here, so the diagnostic is the
    # MISSING-RECORDER one naming `codetracer-ruby-recorder`, not the retired
    # one -- and only the deprecated spelling gets a note.
    let dir = scratch / "lang-ruby-q6"
    removeDir(dir)
    createDir(dir)
    let program = dir / "program.rb"
    writeFile(program, "puts 1\n")
    let note = deprecatedLangSpellingNote("ruby(db)")
    check note.len > 0

    let (plain, plainExit) = runWithoutRecorders(
      ct, program, dir / "out-ruby", emptyDir, extra = @["--lang", "ruby"])
    checkpoint("ct --lang ruby output:\n" & plain)
    check plainExit != 0
    check "codetracer-ruby-recorder" in plain
    check "retired" notin plain
    check "no recorder for Ruby" notin plain
    check note notin plain

    let (aliased, aliasedExit) = runWithoutRecorders(
      ct, program, dir / "out-rubydb", emptyDir, extra = @["--lang", "ruby(db)"])
    checkpoint("ct --lang ruby(db) output:\n" & aliased)
    check aliasedExit != 0
    check "codetracer-ruby-recorder" in aliased
    check note in aliased
    check aliased.count(note) == 1     # once: ct prints it, db-backend-record does not

    # WHAT THIS CASE CAN AND CANNOT SEE (test-integrity note, LRS-4 review).
    # `ct` here is whatever `src/build-debug-repro/bin/ct` currently is, and no lane
    # in this file builds it (`test-cli-record` depends on `vm-test-prereqs`,
    # which only runs the tailwind extract).  A ct built BEFORE LRS-4 is
    # caught: it prints "no recorder for Ruby" / "retired" and the three
    # `notin` checks above go red.  A ct built from a tree where only the
    # `stderr.writeLine(deprecationNote)` call was removed is NOT caught —
    # the stale binary still prints the note and this case still passes.  The
    # guard for that mutation is therefore NOT here but in
    # `record_backend_selection_test.nim`, which pins the call site in
    # `src/ct/trace/record.nim`'s source and needs no binary at all; if the
    # note's production call site is ever asserted only through a shipped
    # binary again, the assertion becomes conditional on a rebuild nobody
    # scheduled.  An mtime freshness gate — the shape
    # `ci/test/desktop-capabilities-dispatch.sh` uses, where a core older
    # than `help_delegate.nim` is a HARD failure — is deliberately NOT added
    # here: that lane documents `just build-once` as a prerequisite, while
    # `just test-cli-record` never builds `ct` at all (it depends only on
    # `vm-test-prereqs`, the tailwind extract), so the same gate would fail
    # the lane for every developer who edits `record.nim` and runs the tests,
    # which is this lane's normal flow.  Mtime is a poor proxy here for a
    # second reason: the verification workflow copies sources in after
    # building, so a current binary routinely looks older than the
    # byte-identical sources it was built from.

  test "an unrecognised --lang is REFUSED, not read as 'no language given' (LRS-5, at review)":
    require fileExists(ct)
    # The defect, found at LRS-5's second-deletion-round review by running the
    # binary rather than the suites.  `toLang` answers `LangUnknown` for a
    # spelling it does not have, and `detectTarget`'s first line reads
    # `LangUnknown` as "no language was given" and runs detection anyway --
    # so `--lang typo ./crate` recorded the crate NATIVELY, with no
    # diagnostic and a zero exit, exactly as if the flag had been omitted.
    # Measured before the fix: `--lang typo` and the bare invocation produced
    # byte-identical output.
    #
    # It is the same class of defect this repository already settled for
    # `--backend` (`record_backend_selection_test.nim`, and `ct-mcr/record.md`:
    # "refuse to start when the requested configuration cannot be honored,
    # rather than silently downgrading"), and LRS-5 walked right up to it:
    # removing the `polkavm` / `solana` spellings with their `Lang` members
    # would have deleted `ct record` for those two targets THROUGH this
    # fall-through.  The spellings were kept; the hole was not closed, and is
    # closed here.
    let dir = scratch / "lang-unrecognised"
    removeDir(dir)
    createDir(dir)
    let program = dir / "program.rb"
    writeFile(program, "puts 1\n")

    let (refused, refusedExit) = runWithoutRecorders(
      ct, program, dir / "out-typo", emptyDir, extra = @["--lang", "definitely-not-a-language"])
    checkpoint("ct --lang definitely-not-a-language output:\n" & refused)
    check refusedExit != 0
    check "definitely-not-a-language" in refused
    # It must say it will not guess, and it must say what IS accepted.
    check "neither a language nor a target" in refused
    check "ruby" in refused
    check "polkavm" in refused
    # ...and it must refuse BEFORE doing any work: no recorder was looked up,
    # so the missing-recorder diagnostic must not appear.
    check "codetracer-ruby-recorder" notin refused

    # The control: the same target with NO `--lang` still gets as far as the
    # recorder lookup.  Before the fix these two outputs were identical.
    let (bare, _) = runWithoutRecorders(
      ct, program, dir / "out-bare", emptyDir)
    checkpoint("ct (no --lang) output:\n" & bare)
    check "codetracer-ruby-recorder" in bare
    check refused != bare

    # The two ISA-only spellings are NOT refused: they name a target rather
    # than a language, which is exactly why they survived the deletion round
    # and why this guard cannot simply test `toLang(...) == LangUnknown`.
    # Asserted on a plain Rust crate -- the shape a Solana or PolkaVM program
    # really has, and the one that would be read as native Rust if the
    # spelling ever stopped resolving.
    let crate = dir / "crate"
    createDir(crate)
    createDir(crate / "src")
    writeFile(crate / "Cargo.toml", "[package]\nname = \"prog\"\n")
    writeFile(crate / "src" / "main.rs", "fn main() {}\n")
    for spelling in ["polkavm", "solana"]:
      checkpoint("--lang " & spelling)
      check isKnownLangSpelling(spelling)
      check toLang(spelling) == LangUnknown     # ...and still no language
      let (accepted, acceptedExit) = runWithoutRecorders(
        ct, crate, dir / ("out-" & spelling), emptyDir,
        extra = @["--lang", spelling])
      checkpoint("ct --lang " & spelling & " output:\n" & accepted)
      check acceptedExit != 0                   # no recorder on the scrubbed PATH
      check "neither a language nor a target" notin accepted
      check ("codetracer-" & spelling & "-recorder") in accepted
