## review_cli_test.nim
##
## The `ct review` command group, asserted through the real `ct` binary — the
## level a user and an agent actually hit.
##
## RV-1 of `codetracer-specs/DeepReview/Review-Command.milestones.org` makes
## `ct review` DeepReview's entire command-line surface and retires the older
## spellings outright.  The pure dispatch is unit-tested in
## `src/tests/gui/tests/deepreview/ct_review_cli_test.nim`; what *that* suite
## cannot see is whether the shipped binary is wired to it, because the wiring
## runs through confutils and a pre-parser interception that only exist in a
## linked `ct`.  Before RV-1 the binary answered `ct review …` with
##
##     ct has no such subcommand
##     Try ct --help for more information.
##
## and accepted `ct --deepreview <PATH>` silently, so both of those are
## asserted here against the artefact that ships.
##
## Every case below is an *error or help* path on purpose: the success path of
## `ct review <PATH>` launches Electron, which belongs to the Playwright suites
## (`src/tests/gui/tests/deepreview/`), retargeted at this spelling by
## `src/tests/gui/lib/fixtures.ts`.  What is left for a CLI test is precisely
## the part those suites cannot reach — that a wrong command line is refused
## with a diagnostic that names what to do instead, and with a non-zero status
## a CI job can see.  The old surface got that wrong twice over: an unknown
## subcommand printed a message and could exit 0 depending on the shell, and a
## `--deepreview` path that did not exist reached the renderer and died in
## `JSON.parse`.
##
## Mocking justification (workspace policy on mock objects): none. There is no
## mock object in this file. `ct` is the real binary, invoked by absolute path;
## the "native backend absent" case is produced by scrubbing PATH and the
## documented override variable, which is a real environment, not a double.
##
## Compile and run:
##   nim c -r src/tests/cli/review_cli_test.nim

import std/[os, osproc, streams, strtabs, strutils, unittest]

const
  ReviewTimeoutSeconds = 60
    ## Every case here fails fast by design; this exists so a regression that
    ## hangs cannot wedge the lane.

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## Resolved exactly as `record_missing_recorder_test.nim` resolves it, so
  ## the two cannot disagree about what "the ct binary" means.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / "ct"

type
  RunResult = object
    exitCode: int
    output: string

proc runCt(args: seq[string]; scrubNativeBackend = false): RunResult =
  ## Run `ct` with the given argv, capturing stdout+stderr together — a user
  ## reading a terminal does not distinguish them, and neither should the
  ## assertions.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  if scrubNativeBackend:
    # The documented ways to reach the native replay backend, removed: an
    # empty PATH plus a cleared override is genuinely the state of a machine
    # where it was never installed.  `ct` finds its own helpers through
    # CODETRACER_PREFIX, which needs neither.
    env["PATH"] = ""
    env["CODETRACER_NATIVE_REPLAY_PATH"] = ""
  let process = startProcess(
    ctBinary(), args = args, env = env,
    options = {poStdErrToStdOut})
  defer: close(process)
  # Drain before waiting: `ct` writes usage screens that comfortably exceed a
  # pipe buffer, and waiting first would deadlock on a full pipe.
  let output = outputStream(process).readAll()
  let code = waitForExit(process, timeout = ReviewTimeoutSeconds * 1000)
  RunResult(exitCode: code, output: output)

suite "ct review — the shipped binary":
  setup:
    check fileExists(ctBinary())

  test "review_is_a_known_subcommand_with_a_usage_screen":
    let run = runCt(@["review", "--help"])
    checkpoint(run.output)
    check run.exitCode == 0
    check run.output.contains("review")
    check not run.output.contains("no such subcommand")

  test "review_with_no_argument_reports_usage_and_fails":
    let run = runCt(@["review"])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("ct review collect")
    check run.output.contains("ct review inspect")

  test "review_over_a_missing_dataset_names_the_path_and_fails":
    # `--deepreview` used to pass this straight to the renderer, which read a
    # missing file and died inside `JSON.parse` with a stack trace naming
    # nothing the user typed.
    let missing = getTempDir() / "ct-review-cli-absent-dataset.json"
    removeFile(missing)
    let run = runCt(@["review", missing])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("ct-review-cli-absent-dataset.json")

  test "review_over_a_directory_without_a_dataset_says_how_to_produce_one":
    let dir = getTempDir() / "ct-review-cli-empty-dataset-dir"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let run = runCt(@["review", dir])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("review.json")
    check run.output.contains("ct review collect")

  test "a_global_option_after_the_dataset_path_reaches_the_parser":
    # Regression: `ct review <PATH>` is an ordinary `ct` command, so ct's own
    # global options apply to it exactly as they do to `ct edit`
    # (CLI-Reference.md §3.1) — `--remote-debugging-port` in particular, which
    # Playwright and the Electron tooling inject.  The pre-parser interception
    # used to swallow the whole line as soon as a second token appeared and
    # answered "takes exactly one dataset path".
    #
    # A path that does not exist is used deliberately: the success path would
    # launch Electron, which belongs to the Playwright suites.  What is being
    # asserted is *which* diagnostic comes back — the dataset was resolved (so
    # the launch arm ran, so the option parsed), not the argument count.
    let missing = getTempDir() / "ct-review-cli-absent-dataset.json"
    removeFile(missing)
    let run = runCt(@["review", missing, "--remote-debugging-port=0"])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("no review dataset at")
    check not run.output.contains("exactly one dataset path")

  test "extra_positionals_are_refused_the_way_every_other_command_refuses_them":
    let run = runCt(@["review", "/tmp/a.json", "/tmp/b.json"])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("does not accept additional arguments")

  test "review_collect_validates_before_it_needs_a_backend":
    # An incomplete command line must be refused on its own terms; requiring
    # the native backend to be installed before saying "--output is missing"
    # would make the diagnostic depend on the machine.
    let run = runCt(@["review", "collect", "--recordings", "/tmp/rec"],
      scrubNativeBackend = true)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("--output")

  test "review_collect_offers_no_backend_flag":
    # DeepReview-GUI.md §1.1: "A collector is chosen by inspecting the
    # recording, never by the user naming a backend."
    let run = runCt(@["review", "collect", "--backend", "native",
      "--repo", ".", "--diff", "a..b", "--recordings", "/tmp/rec",
      "-o", "/tmp/out"], scrubNativeBackend = true)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("--backend")

  test "review_inspect_without_a_backend_names_what_is_missing":
    let run = runCt(@["review", "inspect", "/tmp/whatever"],
      scrubNativeBackend = true)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("ct-native-replay")
    check run.output.contains("CODETRACER_NATIVE_REPLAY_PATH")

suite "ct review — the retired spellings, through the shipped binary":
  test "the_deepreview_option_fails_and_names_ct_review":
    for argv in [@["--deepreview", "/tmp/x.json"],
        @["--deepreview=/tmp/x.json"]]:
      checkpoint(argv.join(" "))
      let run = runCt(argv)
      checkpoint(run.output)
      check run.exitCode != 0
      check run.output.contains("retired")
      check run.output.contains("ct review")

  test "the_deepreview_option_is_gone_from_the_help_screen":
    let run = runCt(@["--help"])
    checkpoint(run.output)
    check not run.output.contains("--deepreview")
    check run.output.contains("ct review")

  test "review_export_points_at_collect":
    let run = runCt(@["review", "export", "/tmp/out"])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("ct review collect")
