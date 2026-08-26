## The `ct agent` command group — an agent's handoff into DeepReview (RV-7).
##
## `codetracer-specs/DeepReview/Agentic-Coding-Integration.md` §4.4: "The
## agent's route into DeepReview is the CLI, used the way a person would use
## it.  The agent decides what to record, runs `ct review collect` exactly as
## a human reviewer would, and then points CodeTracer at the file it
## produced.  There is no agent-specific collection path":
##
## ```sh
## ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
## ct agent evidence review.json
## ```
##
## ===============================  ==========================================
## Command                          Role
## ===============================  ==========================================
## ``ct agent evidence <PATH>``     Hand a review dataset over to CodeTracer
## ``ct agent end-of-turn …``       Run the pair above, for a project hook
## ``ct agent prompt``              Print the prompt text that teaches the pair
## ===============================  ==========================================
##
## ## Why the identity is read, not stated
##
## §4.4 again: the session, the task and the workspace "are read from the
## **environment variables the agent already runs under**, because an agent
## process is launched by a harness that knows all three; requiring the agent
## to restate them invites disagreement between what it claims and where it
## actually is."
##
## That is one notion of "which session am I in", not two: the variables are
## `ct/review_session.nim`'s, read through *its*
## :proc:`reviewSessionRefFromEnv`, which is the same routine RV-6 uses to
## stamp the session reference into `review.json` at `ct review collect` time.
## A dataset and the evidence handing it over therefore cannot name different
## sessions from the same environment, because only one piece of code reads
## that environment.
##
## Resolution order for each of the three, first non-empty wins:
##
## ===============  ==========================================================
## Source           Why it is where it is
## ===============  ==========================================================
## explicit flag    §4.4: "Explicit flags remain available and override the
##                  environment, for use outside a managed session and in
##                  tests."
## the environment  The normal case, and the only one that cannot lie.
## the dataset      The reference `ct review collect` already stamped into
##                  this very file, from the same variables.  Not a guess: a
##                  recorded fact about the collection, used when the handoff
##                  happens outside the collecting process (a human picking a
##                  dataset up later, a hook in a differently-scoped shell).
## ===============  ==========================================================
##
## The **session** has no fourth source.  When none of the three names one,
## the command fails and says so (:proc:`missingSessionMessage`) rather than
## inventing an id — the failure mode this whole design exists to avoid, and
## RV-7's third verification entry.  The *workspace* does fall back to the
## working directory, because a working directory is an observed fact rather
## than a guess, and the *task* is allowed to stay empty, because a session
## need not belong to one.
##
## ## Why the flag set shrank
##
## The pre-RV-7 command took twelve flags, ten of which asked the agent to
## *assert* something: which trace it recorded, what the test was called, what
## command ran it, what the exit code was, whether the run counts as ready.
## After RV-7 the argument is a review dataset, and the dataset is the record
## of all of it — so those flags could only ever agree with the file or
## contradict it, and a contradiction is unresolvable at the point where it
## matters.  They are retired outright, with a diagnostic naming what replaced
## them (:proc:`retiredEvidenceFlagMessage`), the convention the workspace
## applies elsewhere (`reprobuild-specs/Retired-Names.md`).  The three that
## survive are the three §4.4 explicitly keeps.
##
## ## Where each half runs
##
## Split like `review_cli.nim`, for the same reason: everything that *decides*
## what a command line means, what an environment means, and what a dataset
## says is a pure function of its inputs, and is therefore assertable on both
## the C and the JavaScript Nim backends without a filesystem, an environment
## or a subprocess.  The `when not defined(js)` half performs those decisions.

import std/[json, strutils]

import review_session
import ../frontend/viewmodel/agent_evidence
export agent_evidence

const
  AgentEvidenceVerb* = "evidence"
  AgentEndOfTurnVerb* = "end-of-turn"
  AgentPromptVerb* = "prompt"

  ReviewDiffEnvVar* = "CODETRACER_REVIEW_DIFF"
    ## The end-of-turn hook's diff specification (`main..HEAD`).  A hook is
    ## configured once, for a whole project, and the branch it reviews against
    ## is the one thing about it that varies per checkout — so it is readable
    ## from the environment as well as from the command line.
  ReviewDiffFileEnvVar* = "CODETRACER_REVIEW_DIFF_FILE"
  ReviewRepoEnvVar* = "CODETRACER_REVIEW_REPO"
  ReviewRecordingsEnvVar* = "CODETRACER_REVIEW_RECORDINGS"
  ReviewOutputEnvVar* = "CODETRACER_REVIEW_OUTPUT"

  DefaultHookRecordingsDir* = ".ct/runs"
    ## The recordings directory §4.4's own example names.  A default, not a
    ## requirement: a project that records elsewhere sets `--recordings` (or
    ## `CODETRACER_REVIEW_RECORDINGS`) in its hook configuration.
  DefaultHookOutputDir* = ".ct/review"

  AgentUsage* = """
`ct agent` — the agent handoff into DeepReview.

Usage:
  ct agent evidence <PATH>            hand a review dataset to CodeTracer
  ct agent end-of-turn [OPTIONS]      collect a dataset and hand it over
  ct agent prompt                     print the prompt text for an agent

`ct agent evidence` options:
  --session <ID>        the agent session this evidence belongs to
  --task <ID>           the task the session is working on
  --workspace <DIR>     the workspace the session is working in

  All three are read from the environment the agent already runs under
  (CODETRACER_AGENT_SESSION_ID, CODETRACER_AGENT_TASK_ID,
  CODETRACER_AGENT_WORKSPACE); the flags override it.

`ct agent end-of-turn` runs the two ordinary commands, in order:

  ct review collect --repo <DIR> --diff <BASE..HEAD> \
      --recordings <DIR> --output <DIR>
  ct agent evidence <DIR>

and takes `ct review collect`'s options (--repo, --diff, --diff-file,
--recordings, --output/-o, --preset, --progress) plus the three above.
Unset options default to $CODETRACER_REVIEW_DIFF, $CODETRACER_REVIEW_REPO,
$CODETRACER_REVIEW_DIFF_FILE, $CODETRACER_REVIEW_RECORDINGS (or .ct/runs)
and $CODETRACER_REVIEW_OUTPUT (or .ct/review).
"""

type
  AgentIdentityFlags* = object
    ## The three identity flags, exactly as typed.  Empty means "not given",
    ## which is what makes the environment the next source rather than a
    ## second opinion.
    session*, task*, workspace*: string

  AgentIdentity* = object
    ## Who this evidence belongs to, once every source has been consulted.
    sessionId*, taskId*, workspacePath*: string

  HookCollectOptions* = object
    ## `ct review collect`'s options as the end-of-turn hook holds them,
    ## before defaults and before translation into that command's argv.
    repo*, diff*, diffFile*, recordings*, output*, preset*: string
    progress*: bool

  AgentPlanKind* = enum
    apkEvidence
    apkEndOfTurn
    apkPrompt
    apkUsage
    apkError

  AgentPlan* = object
    case kind*: AgentPlanKind
    of apkEvidence:
      datasetPath*: string
      identity*: AgentIdentityFlags
    of apkEndOfTurn:
      hook*: HookCollectOptions
      hookIdentity*: AgentIdentityFlags
    of apkPrompt, apkUsage:
      discard
    of apkError:
      message*: string

  AgentCliResult* = object
    ## What a `ct agent …` line produced.  `output` is stdout, `errorOutput`
    ## is stderr; they are separate because the notification on stdout is
    ## machine-read (a hook pipes it into `jq`) and a diagnostic mixed into it
    ## would corrupt that.
    handled*: bool
    exitCode*: int
    output*: string
    errorOutput*: string

const
  RetiredEvidenceFlags*: array[9, tuple[flag, replacement: string]] = [
    ("--tab",
     "the tab is CodeTracer's own; the session id identifies the session"),
    ("--trace-id",
     "the dataset lists the recordings it was collected from"),
    ("--trace-path",
     "the dataset lists the recordings it was collected from"),
    ("--test-name",
     "the dataset names each recording it carries"),
    ("--test-command",
     "the dataset records the collection, not the command that ran it"),
    ("--exit-code",
     "collect evidence for a run worth reviewing; a failing run is reported " &
     "as a failing run, not handed over"),
    ("--status",
     "the status is derived from the dataset, so it cannot contradict it"),
    ("--message",
     "the status message comes with the status it explains"),
    ("--metadata",
     "the dataset carries what this file used to carry"),
  ]
    ## Retired outright rather than accepted-and-ignored.  Silently ignoring
    ## a flag an agent still passes would let it believe it had asserted
    ## something; the workspace convention (`Retired-Names.md`) is to fail and
    ## name the replacement.

func retiredEvidenceReplacement*(flag: string): string {.noSideEffect.} =
  ## The reason a retired flag is gone, or "" if `flag` was never one.
  for entry in RetiredEvidenceFlags:
    if entry.flag == flag:
      return entry.replacement
  ""

func retiredEvidenceFlagMessage*(flag, replacement: string): string =
  "error: `ct agent evidence " & flag & "` was retired: " & replacement &
    ".\n" &
    "  `ct agent evidence` takes the review dataset and reads the session " &
    "from the environment:\n" &
    "    ct review collect --diff main..HEAD --recordings .ct/runs -o " &
    "review.json\n" &
    "    ct agent evidence review.json\n" &
    # Point at something the person reading this actually has.  This line used
    # to name `codetracer-specs/DeepReview/Agentic-Coding-Integration.md`, a
    # file that lives in a private specification repository: for every user of
    # the shipped binary it is a dead end, and it advertises internal layout
    # besides.
    "  Run `ct agent evidence --help` for the full flag set."

func missingSessionMessage*(datasetPath: string): string =
  ## RV-7's third verification entry: a missing environment must produce this
  ## rather than a plausible-looking default.
  ##
  ## It names all three sources it consulted, because the fix differs by
  ## situation — a harness that forgot to export the variable, a dataset
  ## collected outside a session, or a human running the command by hand who
  ## simply has to say which session they mean.
  "error: `ct agent evidence` could not tell which agent session this " &
    "evidence belongs to.\n" &
    "  It reads the session from " & ReviewSessionIdEnvVar &
    ", which the agent harness sets;\n" &
    "  that variable is unset, no --session was given, and the dataset " &
    "at '" & datasetPath & "'\n" &
    "  carries no session reference of its own.\n" &
    "  Export " & ReviewSessionIdEnvVar &
    ", or pass --session <ID> explicitly."

func firstNonEmpty(values: varargs[string]): string =
  for value in values:
    if value.len > 0:
      return value
  ""

proc resolveAgentIdentity*(flags: AgentIdentityFlags;
                           lookup: proc(name: string): string {.closure.};
                           datasetRef: ReviewSessionRefSpec;
                           cwd = ""): tuple[identity: AgentIdentity;
                                            error: string] =
  ## Decide who this evidence belongs to.  See the module header for the
  ## order and for why each source is where it is.
  ##
  ## `lookup` is injected rather than calling `getEnv`, so the whole decision
  ## is assertable on both Nim backends and without mutating the test
  ## process's own environment — the same seam `reviewSessionRefFromEnv` uses,
  ## and for the same reason.
  ##
  ## `reviewSessionRefFromEnv` returns an *empty* spec when no session id is
  ## exported, so the task and workspace variables are read again directly
  ## below.  That is not a second source: it covers the one case RV-6 has no
  ## opinion about, where the session came from `--session` and the rest of
  ## the environment is still the harness's.
  let envRef = reviewSessionRefFromEnv(lookup, fallbackWorkspace = "")
  result.identity.sessionId = firstNonEmpty(
    flags.session.strip(), envRef.sessionId, datasetRef.sessionId)
  if result.identity.sessionId.len == 0:
    result.error = "missing session"
    return
  result.identity.taskId = firstNonEmpty(
    flags.task.strip(), envRef.taskId,
    lookup(ReviewSessionTaskEnvVar).strip(), datasetRef.taskId)
  result.identity.workspacePath = firstNonEmpty(
    flags.workspace.strip(), envRef.workspacePath,
    lookup(ReviewSessionWorkspaceEnvVar).strip(),
    datasetRef.workspacePath, cwd)

# ---------------------------------------------------------------------------
# argv → plan
# ---------------------------------------------------------------------------

type
  FlagValue = object
    name: string
    value: string
    hasValue: bool

func splitFlag(arg: string): FlagValue =
  let eq = arg.find('=')
  if eq >= 0:
    FlagValue(name: arg[0 ..< eq], value: arg[eq + 1 .. ^1], hasValue: true)
  else:
    FlagValue(name: arg, value: "", hasValue: false)

func isHelpToken(arg: string): bool =
  arg in ["--help", "-h", "help"]

func errorPlan(message: string): AgentPlan =
  AgentPlan(kind: apkError, message: message)

func planEvidence(rest: openArray[string]): AgentPlan =
  var
    path = ""
    flags = AgentIdentityFlags()
    i = 0
  while i < rest.len:
    let arg = rest[i]
    if isHelpToken(arg):
      return AgentPlan(kind: apkUsage)
    if not arg.startsWith("-"):
      if path.len > 0:
        return errorPlan("error: `ct agent evidence` takes exactly one " &
          "dataset path, but got both '" & path & "' and '" & arg & "'.")
      path = arg
      inc i
      continue
    let flag = splitFlag(arg)
    let retired = retiredEvidenceReplacement(flag.name)
    if retired.len > 0:
      return errorPlan(retiredEvidenceFlagMessage(flag.name, retired))
    var value = flag.value
    if not flag.hasValue:
      if i + 1 >= rest.len:
        return errorPlan("error: " & flag.name & " expects a value.")
      value = rest[i + 1]
      inc i
    case flag.name
    of "--session": flags.session = value
    of "--task": flags.task = value
    of "--workspace": flags.workspace = value
    else:
      return errorPlan("error: unknown option '" & flag.name &
        "' for `ct agent evidence`.\n" & AgentUsage)
    inc i
  if path.len == 0:
    return errorPlan("error: `ct agent evidence` needs the path of the " &
      "review dataset to hand over.\n" &
      "  Produce one first:\n" &
      "    ct review collect --diff main..HEAD --recordings .ct/runs -o " &
      "review.json\n" &
      "    ct agent evidence review.json")
  AgentPlan(kind: apkEvidence, datasetPath: path, identity: flags)

func planEndOfTurn(rest: openArray[string]): AgentPlan =
  var
    hook = HookCollectOptions()
    flags = AgentIdentityFlags()
    i = 0
  while i < rest.len:
    let arg = rest[i]
    if isHelpToken(arg):
      return AgentPlan(kind: apkUsage)
    if not arg.startsWith("-"):
      return errorPlan("error: `ct agent end-of-turn` takes no positional " &
        "arguments, but got '" & arg & "'.\n" &
        "  Name the dataset directory with --output <DIR>.")
    let flag = splitFlag(arg)
    let retired = retiredEvidenceReplacement(flag.name)
    if retired.len > 0:
      return errorPlan(retiredEvidenceFlagMessage(flag.name, retired))
    var value = flag.value
    let wantsValue = flag.name != "--progress"
    if wantsValue and not flag.hasValue:
      if i + 1 >= rest.len:
        return errorPlan("error: " & flag.name & " expects a value.")
      value = rest[i + 1]
      inc i
    case flag.name
    of "--repo": hook.repo = value
    of "--diff": hook.diff = value
    of "--diff-file": hook.diffFile = value
    of "--recordings": hook.recordings = value
    of "--output", "-o": hook.output = value
    of "--preset": hook.preset = value
    of "--progress":
      if flag.hasValue:
        return errorPlan("error: --progress is a switch and takes no value.")
      hook.progress = true
    of "--session": flags.session = value
    of "--task": flags.task = value
    of "--workspace": flags.workspace = value
    else:
      return errorPlan("error: unknown option '" & flag.name &
        "' for `ct agent end-of-turn`.\n" & AgentUsage)
    inc i
  AgentPlan(kind: apkEndOfTurn, hook: hook, hookIdentity: flags)

func planAgentCli*(args: openArray[string]): AgentPlan =
  ## Resolve a full `ct agent …` argv (including the leading `agent`) into the
  ## one thing it means.  Pure: no filesystem, no environment.
  if args.len == 0 or args[0] != "agent":
    return errorPlan("error: not a `ct agent` command line.")
  if args.len == 1 or args[1].len == 0:
    return errorPlan("error: `ct agent` needs a subcommand.\n" & AgentUsage)
  let verb = args[1]
  if isHelpToken(verb):
    return AgentPlan(kind: apkUsage)
  case verb
  of AgentEvidenceVerb:
    planEvidence(args.toOpenArray(2, args.len - 1))
  of AgentEndOfTurnVerb:
    planEndOfTurn(args.toOpenArray(2, args.len - 1))
  of AgentPromptVerb:
    if args.len > 2:
      errorPlan("error: `ct agent prompt` takes no arguments, but got '" &
        args[2] & "'.")
    else:
      AgentPlan(kind: apkPrompt)
  else:
    errorPlan("error: unknown subcommand '" & verb & "' for `ct agent`.\n" &
      AgentUsage)

func agentNeedsRawDispatch*(args: openArray[string]): bool =
  ## Whether a `ct agent …` line must be handled before confutils sees argv.
  ##
  ## All of it, always.  Every verb of this group carries options that are not
  ## `ct`'s own, and confutils rejects any dash-prefixed token it does not
  ## recognise — the limitation `ct-complete` and `ct record --` are already
  ## intercepted for.  Unlike `ct review`, this group has no launch form that
  ## wants ct's global options, so there is nothing to leave behind.
  args.len >= 1 and args[0] == "agent"

# ---------------------------------------------------------------------------
# the end-of-turn hook's two commands, as data
# ---------------------------------------------------------------------------

proc applyHookEnvDefaults*(hook: HookCollectOptions;
                           lookup: proc(name: string): string {.closure.}):
    HookCollectOptions =
  ## Fill unset hook options from the environment, then from the documented
  ## defaults.  Pure given `lookup`, so what a hook would run is assertable
  ## without running it.
  result = hook
  result.repo = firstNonEmpty(hook.repo, lookup(ReviewRepoEnvVar).strip())
  result.diff = firstNonEmpty(hook.diff, lookup(ReviewDiffEnvVar).strip())
  result.diffFile = firstNonEmpty(hook.diffFile,
    lookup(ReviewDiffFileEnvVar).strip())
  result.recordings = firstNonEmpty(hook.recordings,
    lookup(ReviewRecordingsEnvVar).strip(), DefaultHookRecordingsDir)
  result.output = firstNonEmpty(hook.output,
    lookup(ReviewOutputEnvVar).strip(), DefaultHookOutputDir)

func hookCollectArgs*(hook: HookCollectOptions; workspacePath: string):
    tuple[args: seq[string]; error: string] =
  ## The `ct review collect …` argv the hook runs, including the leading
  ## `review` token — *the same* command line a person would type, which is
  ## what "the hook runs the same commands; it is not a second mechanism"
  ## (§4.4) means concretely.
  ##
  ## `--repo` defaults to the resolved workspace because that is the
  ## repository the agent was working in, and a hook that had to be told it
  ## again would be a fourth place the workspace is stated.
  var repo = hook.repo
  if repo.len == 0 and hook.diffFile.len == 0:
    repo = workspacePath
  if hook.diffFile.len == 0 and hook.diff.len == 0:
    return (@[], "error: `ct agent end-of-turn` needs a diff to collect: " &
      "pass --diff <BASE..HEAD>\n  (or --diff-file <PATH>), or set " &
      ReviewDiffEnvVar & " in the hook's environment.")
  result.args = @["review", "collect"]
  if hook.diffFile.len > 0:
    result.args.add(@["--diff-file", hook.diffFile])
    if hook.repo.len > 0:
      result.args.add(@["--repo", hook.repo])
  else:
    result.args.add(@["--repo", repo, "--diff", hook.diff])
  result.args.add(@["--recordings", hook.recordings, "--output", hook.output])
  if hook.preset.len > 0:
    result.args.add(@["--preset", hook.preset])
  if hook.progress:
    result.args.add("--progress")

# ---------------------------------------------------------------------------
# dataset → notification
# ---------------------------------------------------------------------------

func unifiedDiffLine*(kind, content: string): string {.noSideEffect.} =
  ## One line of a `diff -u` body, from a dataset hunk line.
  ##
  ## Collectors write added/removed content with its marker already attached
  ## and context content without one, so the marker is added only where it is
  ## missing.  Context is *always* prefixed with a space, per the unified diff
  ## format: an unprefixed context line whose source text happens to begin
  ## with `-` would otherwise be re-read as a deletion by every consumer,
  ## including CodeTracer's own `diffRows`.
  case kind
  of "added":
    if content.startsWith("+"): content else: "+" & content
  of "removed":
    if content.startsWith("-"): content else: "-" & content
  else:
    " " & content

proc unifiedDiffText*(diff: JsonNode): string =
  ## A dataset file's `diff` record rendered as unified diff text.
  ##
  ## The evidence notification carries diffs as text because that is what
  ## every consumer of it already parses — `AgenticSessionVM`'s `diffRows`,
  ## the VCS panel's rows, the review's own hunks — and because a notification
  ## is also read by humans and by `jq` in CI, where a patch is the readable
  ## form.  The hunk headers are kept: they carry the real line numbers, which
  ## a flat body would lose.
  if diff == nil or diff.kind != JObject:
    return ""
  # `getElems` rather than `items`: a dataset is an arbitrary file an agent
  # pointed at, and `JsonNode.items` dereferences its argument, so a missing
  # `hunks` (a nil node) crashes the process.  A dataset this command cannot
  # make sense of must reach the GUI as `malformed_metadata`, which a
  # segfault cannot.  Same at every `{...}` lookup iterated below.
  for hunk in diff{"hunks"}.getElems:
    result &= "@@ -" & $hunk{"oldStart"}.getInt(0) & "," &
      $hunk{"oldCount"}.getInt(0) & " +" & $hunk{"newStart"}.getInt(0) & "," &
      $hunk{"newCount"}.getInt(0) & " @@\n"
    for line in hunk{"lines"}.getElems:
      result &= unifiedDiffLine(line{"type"}.getStr(""),
        line{"content"}.getStr("")) & "\n"

proc evidenceFilesOfDataset*(dataset: JsonNode): seq[AgentEvidenceFile] =
  ## The changeset a dataset describes, in the notification's shape.
  result = @[]
  if dataset == nil or dataset.kind != JObject:
    return
  for file in dataset{"files"}.getElems:
    let diff = file{"diff"}
    result.add AgentEvidenceFile(
      path: file{"path"}.getStr(""),
      status: diff{"status"}.getStr("M"),
      linesAdded: diff{"linesAdded"}.getInt(0),
      linesRemoved: diff{"linesRemoved"}.getInt(0),
      diff: unifiedDiffText(diff))

proc datasetRecordingLabel(dataset: JsonNode): tuple[id, label: string] =
  for ctx in dataset{"traceContexts"}.getElems:
    let id = ctx{"recordingId"}.getStr("")
    let label = ctx{"label"}.getStr("")
    if result.id.len == 0:
      result.id = id
    if result.label.len == 0:
      result.label = label

proc notificationFromDataset*(dataset: JsonNode; datasetPath: string;
                              identity: AgentIdentity; createdAt: string):
    AgentEvidenceNotification =
  ## Build the notification `ct agent evidence` sends, from the dataset it was
  ## pointed at.
  ##
  ## Every descriptive field is read out of the file rather than asserted on
  ## the command line, which is the whole of RV-7's flag shrink: there is one
  ## account of what was recorded and what changed, and it is the account the
  ## reviewer will open.
  ##
  ## The status is *derived* for the same reason, and the three failure
  ## statuses keep their pre-RV-7 meanings with dataset-shaped triggers:
  ##
  ## ======================  =================================================
  ## Status                  When
  ## ======================  =================================================
  ## `malformed_metadata`    the dataset is missing or is not a dataset
  ## `no_recording`          it names no recordings — nothing to review *with*
  ## `diff_trace_mismatch`   it has recordings but no changed file with a diff
  ##                         — nothing to review
  ## `ready`                 both halves are present
  ## ======================  =================================================
  result = AgentEvidenceNotification(
    sessionId: identity.sessionId,
    taskId: identity.taskId,
    tabId: identity.sessionId,
    workspacePath: identity.workspacePath,
    datasetPath: datasetPath,
    createdAt: createdAt,
    status: aesReady,
    rawMetadata: newJObject())
  if dataset == nil or dataset.kind != JObject:
    result.status = aesMalformedMetadata
    result.statusMessage = "'" & datasetPath &
      "' is not a review dataset CodeTracer can read"
    return
  let recording = datasetRecordingLabel(dataset)
  result.traceId = recording.id
  result.testName = recording.label
  result.files = evidenceFilesOfDataset(dataset)

  # Either half is enough to say the dataset has recordings: the two
  # collectors do not agree about which of the two they populate, and a
  # dataset with trace contexts but no `recordingCount` is still a dataset
  # with recordings.
  var contexts = 0
  for _ in dataset{"traceContexts"}.getElems:
    inc contexts
  if dataset{"recordingCount"}.getInt(0) == 0 and contexts == 0:
    result.status = aesNoRecording
    result.statusMessage = "'" & datasetPath &
      "' was collected from no recordings, so there is nothing to review with"
    return
  var withDiff = 0
  for file in result.files:
    if file.diff.len > 0:
      inc withDiff
  if withDiff == 0:
    result.status = aesDiffTraceMismatch
    result.statusMessage = "'" & datasetPath &
      "' has recordings but no changed file with a diff, so there is " &
      "nothing to review"

when not defined(js):
  import std/[os, times]
  import review_cli

  const
    AgentPromptDocument = staticRead(
      "../../docs/agent-prompt/deepreview-evidence.md")
      ## The shipped prompt, embedded so the binary carries it and a project
      ## can install it with one command.  Its source of truth is
      ## `codetracer-specs/DeepReview/Agent-Prompt-Guidance.md` §3; the copy in
      ## `docs/` is the part of it that describes commands which actually ship
      ## (that document's §6).
    AgentPromptMarker = "<!-- ct-agent-prompt -->"
      ## Everything before this line is editorial — what the file is, how to
      ## install it, why it differs from the spec's longer version — and must
      ## not be printed, because `ct agent prompt >> AGENTS.md` would
      ## otherwise paste "add this to your agent's instructions" *into* an
      ## agent's instructions.

  func promptTextOf*(document: string): string =
    ## The printable half of the prompt document.  Falls back to the whole
    ## document if the marker is missing, so a mis-edited file degrades to
    ## "prints too much" rather than to "prints nothing".
    let marker = document.find(AgentPromptMarker)
    if marker < 0:
      return document
    document[marker + AgentPromptMarker.len .. ^1].strip(
      leading = true, trailing = false)

  const ShippedAgentPrompt* = promptTextOf(AgentPromptDocument)

  proc envLookupClosure(): proc(name: string): string {.closure.} =
    proc(name: string): string = getEnv(name, "")

  proc readDataset(jsonPath: string): JsonNode =
    ## The dataset at `jsonPath`, or nil when it is not one.  Nil is a value
    ## the caller renders as `malformed_metadata`, so a broken dataset is
    ## reported through the same channel as every other evidence problem
    ## instead of as a crash.
    try:
      let dataset = parseFile(jsonPath)
      if dataset.kind != JObject:
        return nil
      dataset
    except CatchableError:
      nil

  proc runAgentEvidence*(datasetPath: string; flags: AgentIdentityFlags;
                         cwd = getCurrentDir();
                         sendRpc: AgentEvidenceRpcSender = defaultRpcSender;
                         lookup: proc(name: string): string {.closure.} = nil):
      AgentCliResult =
    ## `ct agent evidence <PATH>`.
    let resolveLookup =
      if lookup.isNil: envLookupClosure() else: lookup
    let resolved = resolveReviewDatasetJson(datasetPath)
    # A dataset that is not there at all is diagnosed as such: it is the one
    # evidence failure the agent can fix by re-running `ct review collect`,
    # and `resolveReviewDatasetJson` already says which of the two shapes it
    # looked for.  Everything that IS a file goes on to the notification, so
    # a corrupt dataset still reaches the GUI as an explicit status.
    if resolved.error.len > 0:
      return AgentCliResult(handled: true, exitCode: 1,
        errorOutput: resolved.error)
    let dataset = readDataset(resolved.jsonPath)
    let datasetRef =
      if dataset == nil: ReviewSessionRefSpec()
      else: reviewSessionRefFromJson(dataset{"session"})
    let identity = resolveAgentIdentity(flags, resolveLookup, datasetRef, cwd)
    if identity.error.len > 0:
      return AgentCliResult(handled: true, exitCode: 1,
        errorOutput: missingSessionMessage(resolved.jsonPath))
    let notification = notificationFromDataset(dataset, resolved.jsonPath,
      identity.identity, $now().utc())
    sendRpc(notification)
    AgentCliResult(
      handled: true,
      exitCode: if notification.status == aesReady: QuitSuccess
                else: QuitFailure,
      output: $(%notification))

  proc runAgentEndOfTurn*(hook: HookCollectOptions;
                          flags: AgentIdentityFlags;
                          cwd = getCurrentDir();
                          sendRpc: AgentEvidenceRpcSender = defaultRpcSender;
                          lookup: proc(name: string): string {.closure.} = nil):
      AgentCliResult =
    ## `ct agent end-of-turn` — the two ordinary commands, run in order.
    ##
    ## It prints each command before running it, so what a hook did is
    ## readable in the turn's log and reproducible by hand.  `ct review
    ## collect` is invoked through `runReviewCli`, which is the same entry
    ## point `ct review collect` itself goes through: there is one collector
    ## dispatch, not a hook-shaped copy of one.
    let resolveLookup =
      if lookup.isNil: envLookupClosure() else: lookup
    # The workspace is resolved BEFORE the collection, because `--repo`
    # defaults to it.  A hook whose session cannot be identified fails here
    # rather than after collecting a dataset it then cannot hand over.
    let identity = resolveAgentIdentity(flags, resolveLookup,
      ReviewSessionRefSpec(), cwd)
    if identity.error.len > 0:
      return AgentCliResult(handled: true, exitCode: 1,
        errorOutput: missingSessionMessage("(not collected yet)"))
    let filled = applyHookEnvDefaults(hook, resolveLookup)
    let collect = hookCollectArgs(filled, identity.identity.workspacePath)
    if collect.error.len > 0:
      return AgentCliResult(handled: true, exitCode: 1,
        errorOutput: collect.error)
    echo "+ ct ", collect.args.join(" ")
    let collectCode = runReviewCli(collect.args)
    if collectCode != 0:
      return AgentCliResult(handled: true, exitCode: collectCode,
        errorOutput: "error: `ct agent end-of-turn` stopped: the collection " &
          "above failed, so there is no dataset to hand over.")
    echo "+ ct agent evidence ", filled.output
    runAgentEvidence(filled.output, flags, cwd = cwd, sendRpc = sendRpc,
      lookup = resolveLookup)

  proc runAgentPlan*(plan: AgentPlan; cwd = getCurrentDir();
                     sendRpc: AgentEvidenceRpcSender = defaultRpcSender;
                     lookup: proc(name: string): string {.closure.} = nil):
      AgentCliResult =
    case plan.kind
    of apkEvidence:
      runAgentEvidence(plan.datasetPath, plan.identity, cwd = cwd,
        sendRpc = sendRpc, lookup = lookup)
    of apkEndOfTurn:
      runAgentEndOfTurn(plan.hook, plan.hookIdentity, cwd = cwd,
        sendRpc = sendRpc, lookup = lookup)
    of apkPrompt:
      AgentCliResult(handled: true, exitCode: QuitSuccess,
        output: ShippedAgentPrompt)
    of apkUsage:
      AgentCliResult(handled: true, exitCode: QuitSuccess, output: AgentUsage)
    of apkError:
      AgentCliResult(handled: true, exitCode: QuitFailure,
        errorOutput: plan.message)

  proc dispatchAgentEvidenceCli*(args: openArray[string];
                                 cwd = getCurrentDir();
                                 sendRpc: AgentEvidenceRpcSender =
                                   defaultRpcSender): AgentCliResult =
    ## The `ct agent …` interception, called from `src/ct/codetracer.nim`
    ## *before* confutils parses argv.
    ##
    ## The name is unchanged from before RV-7 on purpose: it is the hook
    ## `codetracer.nim` calls, and the interception it performs is one of the
    ## confutils limitations catalogued in the fork — confutils rejects any
    ## dash-prefixed token it does not itself declare, so a group with its own
    ## options can only be reached ahead of it.
    if not agentNeedsRawDispatch(args):
      return AgentCliResult(handled: false)
    runAgentPlan(planAgentCli(args), cwd = cwd, sendRpc = sendRpc)

  proc runAgentCli*(args: openArray[string]; cwd = getCurrentDir();
                    sendRpc: AgentEvidenceRpcSender = defaultRpcSender): int =
    ## Execute a `ct agent …` line and emit its output on the right stream.
    let dispatch = dispatchAgentEvidenceCli(args, cwd = cwd, sendRpc = sendRpc)
    if not dispatch.handled:
      stderr.writeLine("error: not a `ct agent` command line.")
      return QuitFailure
    if dispatch.errorOutput.len > 0:
      stderr.writeLine(dispatch.errorOutput)
    if dispatch.output.len > 0:
      echo dispatch.output
    dispatch.exitCode
