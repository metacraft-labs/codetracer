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
## RV-3 adds the routing cases.  `collect` now inspects the recordings it was
## given and chooses the collector that can read them, and the shipped binary
## is the only place that can be observed end to end: the rules and the route
## are unit-tested in the ViewModel suite, but *that the executor surveys
## before it looks for a backend* is a property of the linked program.  The
## recordings here are real directories carrying the real marker files (rr's
## `version`, a CTFS `.ct` container, a `trace_metadata.json`), because the
## survey's whole job is to read a filesystem.
##
## RV-4 fills in the arm RV-3 refused: materialized recordings now reach the
## db-backend collector (`replay-server review-collect`) instead of a "not yet
## supported" message.  The cases that asserted the refusal assert the route
## instead — the behaviour genuinely changed, and this milestone is where it
## changed — but the property the refusal was protecting is kept and asserted
## on its own: a machine with no CodeTracer replay backend must be told THAT,
## and never that `ct-native-replay` is missing, because a Python user told
## the rr backend is missing has been told DeepReview is an rr-only feature.
##
## Mocking justification (workspace policy on mock objects): two stand-ins, one
## per collector, each used by the routing cases only.
## `collect_over_native_recordings_reaches_the_native_collector` points the
## documented `CODETRACER_NATIVE_REPLAY_PATH` override at a script that records
## its argv and exits 0;
## `collect_over_materialized_recordings_reaches_the_db_backend_collector`
## does the same through `CODETRACER_REPLAY_SERVER_PATH`.
##
## They are justified because the alternative does not assert the thing: the
## real `ct-native-replay review-data collect` starts an rr replay, so running
## it for real turns a routing assertion into a test of whether this machine
## can replay (it cannot — `perf_event_paranoid` is 2 here), and the real
## `replay-server review-collect` needs a real recording of a real program,
## which is a recorder-toolchain dependency this lane does not have.  Every
## other way of observing the route is negative ("it did not say the other
## thing").  What is being asserted here is precisely the subprocess contract —
## which binary `ct` invokes, with which argv — and a stand-in is the only way
## to see it.  Nothing about either collector's behaviour is simulated: the
## cases make no claim about what comes back beyond `ct`'s own post-run check
## that a `review.json` was left behind.  The collectors' *behaviour* is
## asserted for real elsewhere: the materialized one by
## `src/db-backend/tests/deepreview_materialized_collector_test.rs`, over a
## recording made by the real Noir recorder, and its output by
## `src/tests/gui/tests/deepreview/materialized_review_dataset_test.nim`.
## The other cases use no double at all: `ct` is the real binary, invoked by
## absolute path, and the "backend absent" cases are produced by scrubbing PATH
## and the override variables, which is a real environment rather than a
## substitute for one.
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

proc runCt(args: seq[string]; scrubNativeBackend = false;
           extraEnv: openArray[(string, string)] = []): RunResult =
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
  for (key, value) in extraEnv:
    env[key] = value
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

  test "review_help_describes_the_whole_command_group":
    # RV-2, from RV-1's verification.  `--help` used to be answered by
    # confutils, which knows only the shape `review` was DECLARED with, so it
    # printed `ct review <reviewPath>` and never mentioned `collect` or
    # `inspect`.  The two other commands of the group were undiscoverable from
    # the group itself — only bare `ct review` (an error path) listed them.
    for tokens in [@["review", "--help"], @["review", "-h"],
                   @["review", "help"]]:
      let run = runCt(tokens)
      checkpoint($tokens & ": " & run.output)
      check run.exitCode == 0
      check run.output.contains("ct review <PATH>")
      check run.output.contains("ct review collect")
      check run.output.contains("ct review inspect")

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

suite "ct review collect — the collector is chosen by inspecting the recordings":
  ## RV-3, through the shipped binary.  DeepReview-GUI.md §1.1: "A collector
  ## is chosen by inspecting the recording, never by the user naming a
  ## backend."
  ##
  ## Every case here failed against the pre-RV-3 binary in the same way: it
  ## printed
  ##
  ##     DeepReview collect complete: 0 recordings found, 0 processed …
  ##     Review dataset ready: …/review.json
  ##
  ## and exited 0 — a green command over a dataset with nothing in it,
  ## whatever it was pointed at.

  var workspace = ""

  setup:
    check fileExists(ctBinary())
    workspace = getTempDir() / "ct-review-collect-routing"
    removeDir(workspace)
    createDir(workspace)

  teardown:
    removeDir(workspace)

  proc gitRepoWithADiff(): string =
    ## A real two-commit git repository, because `collect` parses a real diff
    ## before it ever reaches the recordings and an unparseable one would
    ## mask the routing.
    let repo = workspace / "repo"
    createDir(repo)
    let git = findExe("git")
    check git.len > 0
    proc run(args: varargs[string]) =
      let process = startProcess(git, workingDir = repo, args = @args,
        options = {poStdErrToStdOut})
      defer: close(process)
      discard outputStream(process).readAll()
      check waitForExit(process) == 0
    run("init", "-q", ".")
    run("config", "user.email", "rv3@example.invalid")
    run("config", "user.name", "RV-3")
    writeFile(repo / "main.rs", "fn main() {\n    one();\n}\n")
    run("add", "-A")
    run("commit", "-qm", "base")
    writeFile(repo / "main.rs", "fn main() {\n    one();\n    two();\n}\n")
    run("add", "-A")
    run("commit", "-qm", "head")
    repo

  proc recordingsDir(name: string): string =
    result = workspace / name
    createDir(result)

  proc rrTrace(parent, name: string) =
    ## rr writes `version` into every trace directory it records; it is the
    ## rule the native collector itself discovers recordings by.
    createDir(parent / name)
    writeFile(parent / name / "version", "7\n")

  proc materializedTrace(parent, name: string) =
    ## The layout the example Python recordings still have.
    createDir(parent / name)
    writeFile(parent / name / "trace_metadata.json", "{}")
    writeFile(parent / name / "trace.bin", "")

  proc collect(recordings: string; extraEnv: openArray[(string, string)] = [];
               scrubNativeBackend = false): RunResult =
    let repo = workspace / "repo"
    if not dirExists(repo):
      discard gitRepoWithADiff()
    result = runCt(@["review", "collect", "--repo", repo,
      "--diff", "HEAD~1..HEAD", "--recordings", recordings,
      "--output", workspace / ("out-" & recordings.lastPathPart)],
      scrubNativeBackend = scrubNativeBackend, extraEnv = extraEnv)

  test "collect_over_native_recordings_reaches_the_native_collector":
    # The positive half of the routing: `ct` invokes the native collector's
    # hidden `review-data` group with the argv it translated.  See the
    # mocking justification in the file header for why the collector is
    # stood in for here rather than run.
    let log = workspace / "native-collector-argv.log"
    let stub = workspace / "stub-ct-native-replay"
    writeFile(stub, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & log & "\n")
    setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
    let recordings = recordingsDir("native")
    rrTrace(recordings, "app-0")
    rrTrace(recordings, "app-1")
    let run = collect(recordings,
      extraEnv = {"CODETRACER_NATIVE_REPLAY_PATH": stub})
    checkpoint(run.output)
    check run.exitCode == 0
    check fileExists(log)
    let invocations = readFile(log).strip.splitLines()
    # Two: the collection itself, then the JSON export `ct review <DIR>`
    # needs (see review_cli.nim's header on why `collect` writes both).
    check invocations.len == 2
    checkpoint(invocations.join("\n"))
    check invocations[0].startsWith("review-data collect ")
    check invocations[0].contains("--recordings " & recordings)
    check invocations[1].startsWith("review-data export ")
    # The user never named a backend anywhere in this.
    check not run.output.contains("--backend")

  test "collect_over_materialized_recordings_reaches_the_db_backend_collector":
    # RV-4.  Until it landed this command refused with "does not support this
    # trace kind yet"; now it must reach the db-backend collector with the
    # db-backend's own argv.  The native backend is deliberately NOT scrubbed:
    # the route must come from what the recordings are, not from what happens
    # to be installed — and nothing in the run may invoke the rr binary.
    let log = workspace / "db-backend-argv.log"
    let nativeLog = workspace / "native-collector-argv.log"
    let stub = workspace / "stub-replay-server"
    let outDir = workspace / "out-materialized"
    # The stand-in writes the dataset the real collector writes, so `ct`'s
    # post-run check (a collection that reports success must leave a
    # `review.json`) is exercised rather than bypassed.  See the file header
    # for why the collector itself is stood in for here.
    writeFile(stub, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & log & "\n" &
      "mkdir -p " & outDir & "\n" &
      "printf '{\"files\":[]}' > " & outDir / "review.json" & "\n")
    setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
    let nativeStub = workspace / "stub-ct-native-replay-unused"
    writeFile(nativeStub,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " & nativeLog & "\n")
    setFilePermissions(nativeStub, {fpUserRead, fpUserWrite, fpUserExec})

    let recordings = recordingsDir("materialized")
    materializedTrace(recordings, "py-0")
    materializedTrace(recordings, "py-1")
    let run = collect(recordings, extraEnv = {
      "CODETRACER_REPLAY_SERVER_PATH": stub,
      "CODETRACER_NATIVE_REPLAY_PATH": nativeStub})
    checkpoint(run.output)
    check run.exitCode == 0
    check fileExists(log)
    let invocations = readFile(log).strip.splitLines()
    # One, not two: the db-backend writes `review.json` itself, so there is no
    # binary intermediate to export from.
    check invocations.len == 1
    checkpoint(invocations[0])
    check invocations[0].startsWith("review-collect ")
    check invocations[0].contains("--recordings " & recordings)
    check invocations[0].contains("--output " & outDir)
    check fileExists(outDir / "review.json")
    check run.output.contains("ct review " & outDir)
    # The rr backend was available and was never asked: a materialized
    # recording is not its job (DeepReview-GUI.md §1.1).
    check not fileExists(nativeLog)
    # The user never named a backend anywhere in this.
    check not run.output.contains("--backend")

  test "a_materialized_collection_names_the_db_backend_when_it_is_missing":
    # A Python user has no `ct-native-replay`.  The whole point of §1.1's
    # "DeepReview is not an rr-only feature" is that such a user is never told
    # the rr backend is what is missing.  With PATH scrubbed and both
    # overrides cleared, the diagnostic must name the CodeTracer replay
    # backend and nothing else.
    let recordings = recordingsDir("materialized-no-backend")
    materializedTrace(recordings, "py-0")
    let run = collect(recordings, scrubNativeBackend = true,
      extraEnv = {"CODETRACER_REPLAY_SERVER_PATH": "",
                  "CODETRACER_PREFIX": workspace / "nowhere"})
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("replay-server")
    check run.output.contains("CODETRACER_REPLAY_SERVER_PATH")
    check not run.output.contains("ct-native-replay")
    check not run.output.contains("CODETRACER_NATIVE_REPLAY_PATH")
    # It must not claim a dataset was produced.
    check not run.output.contains("Review dataset ready")
    check not fileExists(
      workspace / "out-materialized-no-backend" / "review.json")

  test "a_materialized_collection_that_writes_no_dataset_is_not_reported_as_ready":
    # The failure mode RV-3 removed from the native path, kept closed on the
    # new one: a collector that exits 0 without writing `review.json` leaves
    # the user with a directory `ct review` cannot open, so `ct` checks rather
    # than trusting the exit code.
    let stub = workspace / "stub-replay-server-silent"
    writeFile(stub, "#!/bin/sh\nexit 0\n")
    setFilePermissions(stub, {fpUserRead, fpUserWrite, fpUserExec})
    let recordings = recordingsDir("materialized-silent")
    materializedTrace(recordings, "py-0")
    let run = collect(recordings,
      extraEnv = {"CODETRACER_REPLAY_SERVER_PATH": stub})
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("review.json")
    check not run.output.contains("Open it with")

  test "collect_over_a_mixed_recordings_directory_is_refused":
    # RV-3's recorded decision: refuse, rather than collect per kind and
    # merge.  The message names both kinds so the user can see what to split.
    let recordings = recordingsDir("mixed")
    rrTrace(recordings, "app-0")
    materializedTrace(recordings, "py-0")
    let run = collect(recordings)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("mixed")
    check run.output.contains("native (rr)")
    check run.output.contains("materialized (CTFS)")
    check not run.output.contains("Review dataset ready")

  test "collect_over_an_empty_recordings_directory_is_refused":
    let recordings = recordingsDir("empty")
    let run = collect(recordings)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("no recordings")
    check run.output.contains("empty")
    check not fileExists(workspace / "out-empty" / "review.json")

  test "collect_over_a_directory_that_holds_no_recordings_says_what_it_holds":
    let recordings = recordingsDir("source-tree")
    writeFile(recordings / "README.md", "hi")
    createDir(recordings / "src")
    let run = collect(recordings)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("none of which is a recording")
    check run.output.contains("README.md")

  test "collect_over_a_missing_recordings_directory_names_the_path":
    # Previously answered by the collector with a Rust `Debug` rendering of
    # its own error type: Error: Custom { kind: Other, error: "invalid data…
    let missing = workspace / "not-there"
    let run = collect(missing)
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains(missing)
    check not run.output.contains("Custom {")

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
