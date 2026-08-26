## agent_cli_test.nim
##
## The `ct agent` command group, asserted through the real `ct` binary — the
## level an agent and a project hook actually hit.
##
## RV-7 of `codetracer-specs/DeepReview/Review-Command.milestones.org` turns
## the agent handoff into two ordinary commands:
##
## ```sh
## ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
## ct agent evidence review.json
## ```
##
## The decisions behind that — what an environment means, which flags survive,
## what a dataset says — are pure and are asserted in
## `src/tests/gui/tests/deepreview/agent_evidence_vm_test.nim`.  What *that*
## suite cannot see is whether the shipped binary is wired to them, because
## the wiring is an interception that runs before confutils and only exists in
## a linked `ct`; and it cannot see whether the two commands, actually run,
## leave a dataset anybody can open.  Both are here.
##
## The last case is the milestone's fourth verification entry and is
## deliberately end to end: a real git repository, a real Noir recording made
## by the real recorder, the real `replay-server` collector, the real hook,
## and then the produced `review.json` is *opened* and read.  A hook that
## reports success over a file nothing can load is exactly the failure this
## entry exists to catch, and no amount of argv assertion reaches it.
##
## Mocking justification (workspace policy on mock objects): **none used**.
## `ct` is the real binary, invoked by absolute path; the recorder, the
## collector and git are the real programs.  The environment is set, not
## simulated — which is the point, since the thing under test is what `ct`
## reads out of an environment.
##
## Compile and run:
##   nim c -r src/tests/cli/agent_cli_test.nim

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

const
  BaseProgram = """fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        sum = sum + x;
    }
    assert(sum == 20);
}
"""
    ## The base revision of the hook case's recorded program.
  ReviewedProgram = """fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        sum = sum + x;
    }
    assert(sum == 20);
    let doubled = sum + sum;
    assert(doubled == 40);
}
"""
    ## The reviewed revision: two added lines, which is the diff the hook's
    ## `ct review collect` reads and the evidence then reports.

  AgentTimeoutSeconds = 300
    ## The hook case records a Noir program and runs a collector over it, so
    ## this is a wedge guard rather than a performance budget.

proc repoRoot(): string =
  ## ``<repo>/src/tests/cli`` -> ``<repo>``
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  ## Resolved exactly as `review_cli_test.nim` resolves it, so the two cannot
  ## disagree about what "the ct binary" means.
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR",
    repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / "ct"

proc replayServerBinary(): string =
  ## The db-backend collector, the way `regenerate-materialized-review.sh`
  ## finds it: the documented override first, then the two places a
  ## development build leaves it.
  result = getEnv("CODETRACER_REPLAY_SERVER_PATH", "")
  if result.len > 0:
    return
  for candidate in [
      repoRoot() / "src" / "build-debug" / "bin" / "replay-server",
      repoRoot() / "src" / "db-backend" / "target" / "debug" / "replay-server"]:
    if fileExists(candidate):
      return candidate
  result = findExe("replay-server")

type
  RunResult = object
    exitCode: int
    output: string

proc runCt(args: seq[string]; extraEnv: openArray[(string, string)] = [];
           workingDir = ""): RunResult =
  ## Run `ct` with the given argv and environment, capturing stdout+stderr
  ## together — a user reading a terminal does not distinguish them.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  # The suite must not inherit an agent session from whatever launched it:
  # `a_missing_environment` asserts the absence of exactly these.
  for name in ["CODETRACER_AGENT_SESSION_ID", "CODETRACER_AGENT_TASK_ID",
               "CODETRACER_AGENT_WORKSPACE", "CODETRACER_AGENT_BACKEND",
               "CODETRACER_AGENT_EVIDENCE_RPC_PATH", "CODETRACER_REVIEW_DIFF",
               "CODETRACER_REVIEW_REPO", "CODETRACER_REVIEW_DIFF_FILE",
               "CODETRACER_REVIEW_RECORDINGS", "CODETRACER_REVIEW_OUTPUT"]:
    env[name] = ""
  for (key, value) in extraEnv:
    env[key] = value
  let process = startProcess(
    ctBinary(), args = args, env = env,
    workingDir = if workingDir.len > 0: workingDir else: getCurrentDir(),
    options = {poStdErrToStdOut})
  defer: close(process)
  let output = outputStream(process).readAll()
  let code = waitForExit(process, timeout = AgentTimeoutSeconds * 1000)
  RunResult(exitCode: code, output: output)

proc notificationOf(output: string): JsonNode =
  ## The evidence notification `ct agent evidence` printed, picked out of a
  ## run's whole output.  It is one line of compact JSON on stdout, which is
  ## what makes it pipeable into `jq` from a hook.
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("{") and trimmed.endsWith("}"):
      try:
        let node = parseJson(trimmed)
        if node.kind == JObject and node.hasKey("sessionId"):
          return node
      except CatchableError:
        discard
  nil

proc sh(cwd, command: string) =
  let (output, code) = execCmdEx(command, workingDir = cwd)
  doAssert code == 0, command & "\n" & output

proc sampleDataset(dir: string): string =
  ## A real collector's dataset, copied where the cases can point at it.  It
  ## is the checked-in output of `replay-server review-collect` over a real
  ## Noir recording, so the fields the evidence reads are a collector's, not
  ## this test's.
  createDir(dir)
  result = dir / "review.json"
  copyFile(repoRoot() / "src" / "tests" / "gui" / "tests" / "deepreview" /
    "fixtures" / "materialized-review.json", result)

template runHookEndToEnd(nargo, collector: string) =
  ## The body of the hook case.
  ##
  ## A **template**, not a proc, and that matters: `unittest`'s `check` only
  ## marks the enclosing `test` as failed when it expands inside it.  As a
  ## proc this body's failures set the process exit code but the case still
  ## printed `[OK]`, and `just test-cli-record` decides pass/fail by counting
  ## `[OK]` / `[FAILED]` lines — so every assertion below would have been
  ## invisible to the lane.
  let work = getTempDir() / "ct-agent-cli-hook"
  removeDir(work)
  createDir(work / "repo" / "src")
  # `nargo trace` writes into --out-dir but does not create it: without
  # this it exits 0 having written nothing, which is how the first run of
  # this case produced an empty recordings directory.
  createDir(work / "recordings" / "run-1")
  defer: removeDir(work)
  let repo = work / "repo"
  let programs = repoRoot() / "src" / "db-backend" / "test-programs" /
    "noir_loop"
  copyFile(programs / "Nargo.toml", repo / "Nargo.toml")
  copyFile(programs / "Prover.toml", repo / "Prover.toml")

  # The base revision, committed, then the reviewed one.  A real diff, from
  # real git, because the hook's first command reads a repository.
  writeFile(repo / "src" / "main.nr", BaseProgram)
  sh(repo, "git init -q")
  sh(repo, "git config user.email rv7@fixture")
  sh(repo, "git config user.name rv7")
  sh(repo, "git add -A && git commit -qm base")
  writeFile(repo / "src" / "main.nr", ReviewedProgram)
  sh(repo, "git add -A && git commit -qm reviewed")
  sh(repo, nargo & " trace --out-dir " & (work / "recordings" / "run-1") &
    " >/dev/null")

  # The hook, configured the way a project configures one: entirely from the
  # environment, so the line in the harness's hook table is bare.
  let output = work / "out"
  let run = runCt(@["agent", "end-of-turn"], extraEnv = {
    "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7-hook",
    "CODETRACER_AGENT_TASK_ID": "task-rv7-hook",
    "CODETRACER_AGENT_WORKSPACE": repo,
    "CODETRACER_REVIEW_DIFF": "HEAD~..HEAD",
    "CODETRACER_REVIEW_RECORDINGS": work / "recordings",
    "CODETRACER_REVIEW_OUTPUT": output,
    "CODETRACER_REPLAY_SERVER_PATH": collector}, workingDir = repo)
  checkpoint(run.output)
  check run.exitCode == 0
  # It ran the two ordinary commands, and said which — a hook whose actions
  # are not reproducible by hand is a private path by another name.
  check run.output.contains("+ ct review collect --repo " & repo &
    " --diff HEAD~..HEAD")
  check run.output.contains("+ ct agent evidence " & output)

  # …and the dataset it produced is loadable.  Opened here, not asserted
  # from the command's own report.
  let datasetPath = output / "review.json"
  check fileExists(datasetPath)
  let dataset = parseJson(readFile(datasetPath))
  check dataset.kind == JObject
  check dataset{"files"}.len > 0
  check dataset{"files"}[0]{"path"}.getStr() == "src/main.nr"
  check dataset{"traceContexts"}.len > 0
  check dataset{"files"}[0]{"coverage"}.len > 0

  # RV-6 and RV-7 read one environment: the dataset the hook's first command
  # produced names the same session the hook's second command handed over.
  check dataset{"session"}{"sessionId"}.getStr() == "agent:acp:rv7-hook"
  let notification = notificationOf(run.output)
  check notification != nil
  check notification{"status"}.getStr() == "ready"
  check notification{"sessionId"}.getStr() == "agent:acp:rv7-hook"
  check notification{"taskId"}.getStr() == "task-rv7-hook"
  check notification{"datasetPath"}.getStr() == datasetPath
  check notification{"files"}[0]{"path"}.getStr() == "src/main.nr"
  check notification{"files"}[0]{"diff"}.getStr().contains("+    let doubled")


suite "ct agent — the shipped binary":
  setup:
    check fileExists(ctBinary())

  test "agent_is_a_known_subcommand_with_a_usage_screen":
    # Before RV-7 `ct agent --help` reached the evidence command, which
    # answered every line it was given with a notification.
    let run = runCt(@["agent", "--help"])
    checkpoint(run.output)
    check run.exitCode == 0
    check run.output.contains("ct agent evidence <PATH>")
    check run.output.contains("ct agent end-of-turn")
    check run.output.contains("ct agent prompt")
    check not run.output.contains("no such subcommand")

  test "agent_prompt_prints_the_pair_a_project_can_paste_into_its_agent":
    ## RV-7's fifth deliverable: the guidance ships as something a project can
    ## use (`ct agent prompt >> AGENTS.md`), not as prose in a spec.
    let run = runCt(@["agent", "prompt"])
    checkpoint(run.output)
    check run.exitCode == 0
    check run.output.contains("ct review collect")
    check run.output.contains("ct agent evidence review.json")
    # The two instructions §4 of Agent-Prompt-Guidance.md requires and an
    # agent will otherwise improvise around: what to do on a red suite, and
    # that evidence is never to be fabricated.
    check run.output.contains("If the tests fail, stop and fix them")
    check run.output.contains("Never hand-write")
    # And the instruction that makes the flag shrink safe: an agent told it
    # cannot resolve its session must say so rather than invent an id.
    check run.output.contains("do not invent a `--session` value")
    # The document's editorial preamble is NOT printed.  `ct agent prompt >>
    # AGENTS.md` would otherwise paste "add this to your agent's
    # instructions" into an agent's instructions.
    check not run.output.contains("Install it into a project")
    check not run.output.contains("ct-agent-prompt")
    check run.output.strip().startsWith("## Recording evidence for review")

  test "evidence_resolves_the_session_from_the_environment":
    let dir = getTempDir() / "ct-agent-cli-env"
    removeDir(dir)
    let dataset = sampleDataset(dir)
    defer: removeDir(dir)
    let run = runCt(@["agent", "evidence", dataset], extraEnv = {
      "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7",
      "CODETRACER_AGENT_TASK_ID": "task-rv7",
      "CODETRACER_AGENT_WORKSPACE": dir})
    checkpoint(run.output)
    check run.exitCode == 0
    let notification = notificationOf(run.output)
    check notification != nil
    check notification{"sessionId"}.getStr() == "agent:acp:rv7"
    check notification{"taskId"}.getStr() == "task-rv7"
    check notification{"workspacePath"}.getStr() == dir
    check notification{"datasetPath"}.getStr() == dataset
    check notification{"status"}.getStr() == "ready"
    # The dataset is what the evidence describes: this file's one changed
    # file, read out of it rather than asserted on the command line.
    check notification{"files"}[0]{"path"}.getStr() == "src/main.nr"

  test "explicit_flags_override_the_environment":
    let dir = getTempDir() / "ct-agent-cli-flags"
    removeDir(dir)
    let dataset = sampleDataset(dir)
    defer: removeDir(dir)
    let run = runCt(@["agent", "evidence", dataset,
        "--session", "flag-session", "--task", "flag-task",
        "--workspace", "/flag/workspace"], extraEnv = {
      "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7",
      "CODETRACER_AGENT_TASK_ID": "task-rv7",
      "CODETRACER_AGENT_WORKSPACE": dir})
    checkpoint(run.output)
    check run.exitCode == 0
    let notification = notificationOf(run.output)
    check notification != nil
    check notification{"sessionId"}.getStr() == "flag-session"
    check notification{"taskId"}.getStr() == "flag-task"
    check notification{"workspacePath"}.getStr() == "/flag/workspace"

  test "a_missing_environment_yields_a_clear_error_not_a_wrong_guess":
    ## The milestone's third verification entry, at the level it matters: a
    ## real process with a real (empty) environment.
    let dir = getTempDir() / "ct-agent-cli-no-session"
    removeDir(dir)
    let dataset = sampleDataset(dir)
    defer: removeDir(dir)
    let run = runCt(@["agent", "evidence", dataset])
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("CODETRACER_AGENT_SESSION_ID")
    check run.output.contains("--session")
    check run.output.contains(dataset)
    # No notification was emitted: refusing must not also hand a review over
    # under some invented id.
    check notificationOf(run.output) == nil

  test "evidence_over_a_missing_dataset_names_the_path":
    let missing = getTempDir() / "ct-agent-cli-absent-review.json"
    removeFile(missing)
    let run = runCt(@["agent", "evidence", missing], extraEnv = {
      "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7"})
    checkpoint(run.output)
    check run.exitCode != 0
    check run.output.contains("ct-agent-cli-absent-review.json")

  test "a_file_that_is_not_a_dataset_is_reported_not_crashed_on":
    ## The argument is whatever path an agent typed, so the command must
    ## survive a file that is JSON but is not a review dataset.  Each shape
    ## here omits an array the reader walks, and each used to end in SIGSEGV
    ## (exit 139) — a crash reports nothing to the agent and nothing to the
    ## GUI, and it is invisible to the status the milestone specifies.
    let dir = getTempDir() / "ct-agent-cli-not-a-dataset"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    for document in ["{}",
        """{"recordingCount": 1, "traceContexts": [{"recordingId": "r"}]}""",
        """{"recordingCount": 1, "files": []}""",
        """{"recordingCount": 1, "traceContexts": [],
            "files": [{"path": "a", "diff": {"status": "M"}}]}""",
        """{"sessionId": "x", "session": {"sessionId": "y"}}"""]:
      let path = dir / "review.json"
      writeFile(path, document)
      let run = runCt(@["agent", "evidence", path], extraEnv = {
        "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7"})
      checkpoint(document & "\n" & run.output)
      # Exit 1 is "this is not reviewable", which is a report.  139 is a
      # segfault, and 0 would mean it handed a broken review over.
      check run.exitCode == 1
      check not run.output.contains("SIGSEGV")

  test "the_retired_flags_fail_and_name_what_replaced_them":
    ## RV-7 retires nine of the twelve flags outright — the workspace
    ## convention (`reprobuild-specs/Retired-Names.md`) rather than
    ## accept-and-ignore, because an agent whose `--exit-code 0` is silently
    ## swallowed believes it asserted something.
    let dir = getTempDir() / "ct-agent-cli-retired"
    removeDir(dir)
    let dataset = sampleDataset(dir)
    defer: removeDir(dir)
    for flag in ["--tab", "--trace-id", "--trace-path", "--test-name",
                 "--test-command", "--exit-code", "--status", "--message",
                 "--metadata"]:
      let run = runCt(@["agent", "evidence", dataset, flag, "x"], extraEnv = {
        "CODETRACER_AGENT_SESSION_ID": "agent:acp:rv7"})
      checkpoint(flag & ": " & run.output)
      check run.exitCode != 0
      check run.output.contains("was retired")
      check run.output.contains("ct agent evidence review.json")

  test "the_end_of_turn_hook_produces_a_loadable_dataset":
    ## RV-7's fourth verification entry, end to end.
    ##
    ## Noir is the recorder because it is the materialized recorder the
    ## CodeTracer dev shell provides, for the reasons
    ## `fixtures/regenerate-materialized-review.sh` sets out.  Both tools it
    ## needs ship in that shell; their absence is reported as the
    ## environmental gap it is rather than skipped, because this case IS the
    ## milestone's claim and an all-skipped run of it asserts nothing.
    let nargo = findExe("nargo")
    let collector = replayServerBinary()
    # Reported as a failure, not a skip: this case IS the milestone's claim,
    # and both tools ship in the shell the lane already runs in.
    check nargo.len > 0     # from the codetracer dev shell's `noir` input
    check collector.len > 0 # `cargo build` in src/db-backend, or build-once
    if nargo.len > 0 and collector.len > 0:
      runHookEndToEnd(nargo, collector)
