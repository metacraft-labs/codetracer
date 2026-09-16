## Argument-parsing contract of `ct test --incremental`.
##
## The subcommand has two front doors: the human-facing selection run
## (`parseIncrementalArgs`) and the granular `--watch-decide` / `--watch-record`
## JSON protocol (`parseWatchArgs`) that Reprobuild's std-only
## `ct_incremental_adapter` process seam drives. This suite pins the two
## properties that keep them honest:
##
##   1. Everything `usage()` advertises is actually accepted — the same flag
##      spellings, and both the `--flag value` and `--flag=value` forms, on both
##      front doors. The watch path used to understand only the bare form and
##      only its own spellings, so `--test-id=abc` silently produced an EMPTY
##      test id: the caller got a confident decision about a test that does not
##      exist rather than a complaint about the flag.
##   2. A missing required value is an error, not a default. Absence and
##      emptiness are different things, and only the flags with a defensible
##      default (`--source-root`, `--cache-path`, `--non-deterministic`) are
##      allowed to fall back to one.
##
## No mocks: these are pure functions over an argument vector. The one test that
## touches the filesystem does so because `parseIncrementalArgs` validates that
## `--program` exists, which is real behaviour worth exercising against a real
## file rather than stubbing out.

import std/[os, strutils, unittest]
import results

import incremental_cli
import incremental/engine

const
  DecideMode = "--watch-decide"
  TraceDir = "/traces/edge-1"
  TestId = "suite::case"

suite "ct test --incremental --watch-* argument parsing":

  test "the --flag=value form is accepted for every value-taking flag":
    # The regression this suite exists for: before the fix each of these
    # returned "" and the run continued as though nothing was wrong.
    let parsed = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir, "--source-root=/src", "--cache-path=/c.json"])
    check parsed.isOk
    check parsed.value.testId == TestId
    check parsed.value.traceDir == TraceDir
    check parsed.value.sourceRoot == "/src"
    check parsed.value.cachePath == "/c.json"

  test "the --flag value form parses identically to the --flag=value form":
    let spaced = parseWatchArgs(@[DecideMode, "--test-id", TestId,
      "--trace-dir", TraceDir, "--source-root", "/src",
      "--cache-path", "/c.json"])
    let equals = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir, "--source-root=/src", "--cache-path=/c.json"])
    check spaced.isOk
    check equals.isOk
    check spaced.value == equals.value

  test "the human-facing --id/--cache aliases are accepted on the watch path":
    # Same subcommand, same concepts: a caller who learned `--id` and `--cache`
    # from the usage line must not be silently misread here.
    let parsed = parseWatchArgs(@[DecideMode, "--id=" & TestId,
      "--trace-dir=" & TraceDir, "--cache=/aliased.json"])
    check parsed.isOk
    check parsed.value.testId == TestId
    check parsed.value.cachePath == "/aliased.json"

  test "an absent required flag is an error rather than an empty value":
    let noTestId = parseWatchArgs(@[DecideMode, "--trace-dir=" & TraceDir])
    check noTestId.isErr
    check "--test-id" in noTestId.error

    let noTraceDir = parseWatchArgs(@[DecideMode, "--test-id=" & TestId])
    check noTraceDir.isErr
    check "--trace-dir" in noTraceDir.error

  test "a required flag whose value was forgotten is an error":
    let dangling = parseWatchArgs(@[DecideMode, "--trace-dir=" & TraceDir,
      "--test-id"])
    check dangling.isErr
    check "requires a value" in dangling.error

    let emptyValue = parseWatchArgs(@[DecideMode, "--trace-dir=" & TraceDir,
      "--test-id="])
    check emptyValue.isErr

  test "optional flags fall back to the defaults the usage line documents":
    # Absence here is legitimate, so it must NOT be an error — the required
    # checks above must not have been implemented by rejecting everything.
    let parsed = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir])
    check parsed.isOk
    check parsed.value.sourceRoot == "/"
    check parsed.value.cachePath == defaultCachePath("/")
    check not parsed.value.nonDeterministic

  test "--cache-path defaults under an explicitly given --source-root":
    let parsed = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir, "--source-root=/work"])
    check parsed.isOk
    check parsed.value.cachePath == defaultCachePath("/work")

  test "--non-deterministic is an optional bare flag in both directions":
    let without = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir])
    check without.isOk
    check not without.value.nonDeterministic

    let present = parseWatchArgs(@["--watch-record", "--test-id=" & TestId,
      "--trace-dir=" & TraceDir, "--non-deterministic"])
    check present.isOk
    check present.value.nonDeterministic

  test "an unrecognised argument is reported instead of ignored":
    let parsed = parseWatchArgs(@[DecideMode, "--test-id=" & TestId,
      "--trace-dir=" & TraceDir, "--no-such-flag=1"])
    check parsed.isErr
    check "unknown argument" in parsed.error

suite "ct test --incremental selection-run argument parsing":

  setup:
    let program = getTempDir() / "ct_incremental_cli_test_program.py"
    writeFile(program, "print('hi')\n")

  teardown:
    removeFile(getTempDir() / "ct_incremental_cli_test_program.py")

  test "the explicit --test-id/--cache-path spellings are accepted here too":
    # The usage line now names these as the canonical spellings for BOTH front
    # doors; a usage string advertising a flag the parser rejects is its own
    # defect, so assert the parser really takes them.
    let parsed = parseIncrementalArgs(@["--language=python",
      "--program=" & program, "--test-id=canonical", "--cache-path=/c.json"])
    check parsed.isOk
    check parsed.value.testId == "canonical"
    check parsed.value.cachePath == "/c.json"

  test "the short --id/--cache spellings keep working":
    let parsed = parseIncrementalArgs(@["--language", "python",
      "--program", program, "--id", "short", "--cache", "/short.json"])
    check parsed.isOk
    check parsed.value.testId == "short"
    check parsed.value.cachePath == "/short.json"
