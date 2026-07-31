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

import std/[os, osproc, strutils, unittest]
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
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug")
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
                         extra: seq[string] = @[]):
    tuple[output: string, exitCode: int] =
  ## Run the real `ct record` in an environment where no recorder can be
  ## found.  `env -i` is deliberately NOT used: `ct` needs HOME (for
  ## ~/.local/share/codetracer) and the loader variables the Nix-built
  ## binary was linked with, and the point of the test is the recorder
  ## lookup, not a hermetic environment.
  # `env` does the unsetting and the PATH replacement, so the scrubbed PATH
  # applies to `ct` ONLY.  Setting PATH in the shell instead would also hide
  # `timeout` from the shell itself, which silently turns every assertion
  # below into a check against "timeout: command not found".
  var cmd = "timeout " & $RecordTimeoutSeconds & " env"
  for name in ClearedOverrides:
    cmd.add(" -u " & name)
  cmd.add(" PATH=" & quoteShell(emptyDir))
  cmd.add(" " & quoteShell(ct) & " record -o " & quoteShell(outDir))
  for arg in extra:
    cmd.add(" " & quoteShell(arg))
  cmd.add(" " & quoteShell(program) & " 2>&1")
  execCmdEx(cmd)

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

      # 2. The message names the language.
      check missing.lang.toName in output

      # 3. The message names the remedy.
      for fragment in missing.remedyFragments:
        checkpoint("  remedy must mention: " & fragment)
        check fragment in output

      # 4. And never silently falls through to a different backend.
      check "unsupported trace kind" notin output
      check "recordingId:" notin output

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
    check LangNoir.toName in output
