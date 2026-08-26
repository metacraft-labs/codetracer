## viewmodels/evidence_call_vm.nim
##
## AA-3 — recognising the agent's *evidence handoff* in a session transcript.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1.1: "When the agent
## hands a review over, that handoff appears in the session as a tool call
## like any other.  It gets a **custom rendering** rather than the generic
## tool-call line, and it is **actionable**: selecting it loads the review
## dataset that call produced."
##
## The handoff is not a CodeTracer-specific protocol — RV-7 made it "two
## ordinary commands" a shell tool runs (`docs/agent-prompt/
## deepreview-evidence.md`):
##
## ```sh
## ct review collect --diff main..HEAD --recordings .ct/runs -o review.json
## ct agent evidence review.json
## ```
##
## so recognising it means recognising *those command lines* in the session's
## tool calls.  This module is that recogniser plus the fold that decides what
## became of the call, and it is deliberately pure — no DOM, no `cstring`, no
## signals — so every rule below is assertable on both Nim backends
## (`src/tests/gui/tests/agent-activity/evidence_call_vm_test.nim`, registered
## in `CoreViewModelGateTests`).
##
## ## Two rules that shape the whole module
##
## 1. **Only a tool call counts.**  The recogniser reads
##    `AgentActivityMessageEntry.toolName` — the tool's own invocation, which
##    the agent protocols fill in (`nim-agents`' `acpUpdateToAgentEvent` maps
##    ACP's `tool_call.title` onto it) — and never the prose in `content`.  An
##    agent that *writes* "next I'll run ct review collect" has collected
##    nothing, and turning that sentence into a clickable review would be the
##    fabricated-evidence failure this milestone family exists to prevent.
##    This is the same shape as AA-2's rule that a message becomes a run only
##    when it actually carries runner events.
##
## 2. **A command is evidence only when we can name its dataset.**  Every
##    accepted spelling below states its output path explicitly, so the
##    dataset a card points at is always one the agent typed, never one
##    inferred from a default.  `ct agent end-of-turn` is accepted *only* when
##    it carries `--output`, precisely because that flag has a default
##    (`agent_cli.DefaultHookOutputDir`, overridable from the environment) and
##    guessing it would be an unverifiable claim about where a file is.

import std/[options, strutils]

import ../store/types

type
  EvidenceCommandKind* = enum
    ## Which of RV-7's two commands this call is.  Kept apart because they
    ## mean different things to a reviewer: `collect` *produced* the dataset,
    ## `evidence` *handed it over*, and a session usually contains both.
    eckCollect = "collect"
    eckHandoff = "handoff"

  EvidenceCallState* = enum
    ## What the *tool call* did — a separate question from whether the dataset
    ## it names can be read (`EvidenceDatasetState`).
    ecsUnreported = "unreported"
      ## No update has reported an outcome for this call.  That covers a
      ## collect still in flight **and** a session that ended without ever
      ## saying how the call went; nothing in a transcript distinguishes the
      ## two, so the rendering states the fact it has rather than picking one.
    ecsFailed = "failed"
      ## The backend said the call failed.  Its own output is kept verbatim.
    ecsCompleted = "completed"

  EvidenceDatasetState* = enum
    ## What is known about the file the call named.  Filled in by the host
    ## (only the main process can read a file); the projection never invents
    ## a value here.
    edsUnknown = "unknown"
      ## Nobody has looked yet.  Renders no shape and offers nothing —
      ## "unknown" is not "missing" and must not be printed as either.
    edsReady = "ready"
    edsUnavailable = "unavailable"
      ## The file is gone, or would not read.  Carries the reader's own
      ## message, never one invented here.

  EvidenceDataset* = object
    ## The shape of a dataset, as far as it is known.
    ##
    ## `fileCount` is meaningful **only** under `edsReady`; a dataset that
    ## genuinely contains no files still prints "0 files", because the rule is
    ## about *absent* data rather than about zero being unprintable (the same
    ## distinction AA-2 drew for "0/5 passed").
    state*: EvidenceDatasetState
    fileCount*: int
    commit*: string
      ## Already abbreviated for display, or "" when the dataset names none.
    message*: string
      ## The reader's diagnostic for `edsUnavailable`; "" otherwise.

  EvidenceCall* = object
    ## One evidence handoff in the session feed.
    anchorId*: string
      ## The id of the message this card is painted *in place of*, exactly as
      ## `AgentTestRunEntry.anchorId` is — the message list stays the feed's
      ## ordering spine, so a handoff renders where it happened.
    toolCallId*: string
    kind*: EvidenceCommandKind
    command*: string
      ## The command line the session reported, verbatim.  Never a
      ## reconstructed one: a command CodeTracer invented would read as one
      ## that ran.
    datasetPath*: string
      ## The path the command named.  Never empty for a recognised call —
      ## see rule 2 in the module header.
    state*: EvidenceCallState
    failureText*: string
      ## The failing call's own output, or "".
    dataset*: EvidenceDataset

  EvidenceCommand* = object
    ## The result of recognising one command line.
    kind*: EvidenceCommandKind
    datasetPath*: string

proc `==`*(a, b: EvidenceDataset): bool {.noSideEffect.} =
  a.state == b.state and a.fileCount == b.fileCount and
    a.commit == b.commit and a.message == b.message

proc `==`*(a, b: EvidenceCall): bool {.noSideEffect.} =
  a.anchorId == b.anchorId and a.toolCallId == b.toolCallId and
    a.kind == b.kind and a.command == b.command and
    a.datasetPath == b.datasetPath and a.state == b.state and
    a.failureText == b.failureText and a.dataset == b.dataset

proc `==`*(a, b: EvidenceCommand): bool {.noSideEffect.} =
  a.kind == b.kind and a.datasetPath == b.datasetPath

# ---------------------------------------------------------------------------
# Reading a command line
# ---------------------------------------------------------------------------

proc splitCommandLine*(line: string): seq[string] {.noSideEffect.} =
  ## Split a command line into argv the way a POSIX shell would, for the two
  ## quoting forms an agent's tool title actually uses.
  ##
  ## Quoting matters here rather than being pedantry: a path with a space in
  ## it (`"/home/a b/review.json"`) is the case where a naive whitespace split
  ## produces a *wrong but plausible* path, and the reviewer would be told a
  ## dataset is missing when it is not.  Backslash escaping is honoured
  ## outside single quotes, as the shell does.
  ##
  ## An unterminated quote yields the tokens read so far — a partial command
  ## is not evidence, and the caller's own checks reject it.
  result = @[]
  var current = ""
  var started = false
  var i = 0
  while i < line.len:
    let c = line[i]
    case c
    of ' ', '\t', '\n', '\r':
      if started:
        result.add current
        current = ""
        started = false
      inc i
    of '\'':
      started = true
      inc i
      while i < line.len and line[i] != '\'':
        current.add line[i]
        inc i
      inc i
    of '"':
      started = true
      inc i
      while i < line.len and line[i] != '"':
        if line[i] == '\\' and i + 1 < line.len:
          inc i
        current.add line[i]
        inc i
      inc i
    of '\\':
      started = true
      if i + 1 < line.len:
        inc i
        current.add line[i]
      inc i
    else:
      started = true
      current.add c
      inc i
  if started:
    result.add current

proc commandBaseName(token: string): string {.noSideEffect.} =
  ## The executable name of an argv[0], with any directory and a Windows
  ## `.exe` suffix removed.  An agent may invoke `ct` by absolute path (a Nix
  ## store path, a build tree) and that is still `ct`.
  var cut = -1
  for i in countdown(token.high, 0):
    if token[i] == '/' or token[i] == '\\':
      cut = i
      break
  result = if cut >= 0: token[cut + 1 .. ^1] else: token
  if result.len > 4 and result[^4 .. ^1].toLowerAscii == ".exe":
    result = result[0 ..< result.len - 4]

proc flagValue(tokens: openArray[string]; start: int;
               names: openArray[string]): string {.noSideEffect.} =
  ## The value of the first of `names` that appears at or after `start`,
  ## in either the `--flag value` or the `--flag=value` spelling.
  ##
  ## "" when the flag is absent or names nothing — which the caller turns into
  ## "this is not a recognisable evidence call", never into a guessed path.
  var i = start
  while i < tokens.len:
    let token = tokens[i]
    for name in names:
      if token == name:
        if i + 1 < tokens.len:
          return tokens[i + 1]
        return ""
      if token.len > name.len and token.startsWith(name) and
          token[name.len] == '=':
        return token[name.len + 1 .. ^1]
    inc i
  ""

proc firstPositional(tokens: openArray[string]; start: int): string
    {.noSideEffect.} =
  ## The first token at or after `start` that is not a flag and is not a
  ## flag's value.  `ct agent evidence <PATH>`'s argument, in other words.
  var i = start
  while i < tokens.len:
    let token = tokens[i]
    if token.startsWith("-"):
      # `--session foo` consumes its value; `--session=foo` does not.  A
      # switch we do not know about is assumed to take a value only when it
      # is not written with `=`, which is the conservative reading: guessing
      # wrong here yields no path rather than a wrong one, because the next
      # candidate is checked the same way.
      if not token.contains('='):
        inc i
      inc i
      continue
    return token
  ""

proc parseEvidenceCommand*(commandLine: string): Option[EvidenceCommand]
    {.noSideEffect.} =
  ## Recognise one of RV-7's evidence commands, and name the dataset it
  ## produces or hands over.
  ##
  ## Accepted, and nothing else:
  ##
  ## ==================================  =========================
  ## command                             dataset
  ## ==================================  =========================
  ## `ct review collect … -o/--output X` `X`
  ## `ct agent evidence X`               `X`
  ## `ct agent end-of-turn … --output X` `X`
  ## ==================================  =========================
  ##
  ## The `ct` token may be any path whose base name is `ct`, because an agent
  ## commonly invokes the binary it was given rather than one on `PATH`; and
  ## it may be preceded by other tokens (`env FOO=1 ct review collect …`,
  ## `nix run … -- ct review collect …`), so the scan looks for `ct` anywhere
  ## rather than only at argv[0].
  ##
  ## Returns `none` for everything else — including a `ct review collect`
  ## with no `--output` and a `ct agent end-of-turn` with no `--output`.  See
  ## rule 2 in the module header: a card that could not name its dataset would
  ## have nothing to open and nothing honest to say about its shape.
  let tokens = splitCommandLine(commandLine)
  for i in 0 ..< tokens.len:
    if commandBaseName(tokens[i]) != "ct":
      continue
    if i + 2 >= tokens.len:
      continue
    let verb = tokens[i + 1]
    let subVerb = tokens[i + 2]
    if verb == "review" and subVerb == "collect":
      let output = flagValue(tokens, i + 3, ["--output", "-o"])
      if output.len > 0:
        return some(EvidenceCommand(kind: eckCollect, datasetPath: output))
    elif verb == "agent" and subVerb == "evidence":
      let path = firstPositional(tokens, i + 3)
      if path.len > 0:
        return some(EvidenceCommand(kind: eckHandoff, datasetPath: path))
    elif verb == "agent" and subVerb == "end-of-turn":
      let output = flagValue(tokens, i + 3, ["--output", "-o"])
      if output.len > 0:
        return some(EvidenceCommand(kind: eckCollect, datasetPath: output))
  none(EvidenceCommand)

# ---------------------------------------------------------------------------
# Folding a conversation
# ---------------------------------------------------------------------------

proc evidenceStateFromStatus*(status: string): EvidenceCallState
    {.noSideEffect.} =
  ## Read the backend's own word for how a tool call ended.
  ##
  ## Anything unrecognised — including the empty string a call that has not
  ## reported yet carries — is `ecsUnreported`, never `ecsCompleted`:
  ## guessing "completed" would offer a review over a dataset the command may
  ## never have written.
  case status.toLowerAscii
  of "completed", "success", "succeeded", "ok": ecsCompleted
  of "failed", "failure", "error", "cancelled", "canceled": ecsFailed
  else: ecsUnreported

proc projectEvidenceCalls*(messages: openArray[AgentActivityMessageEntry]):
    seq[EvidenceCall] {.noSideEffect.} =
  ## Find the evidence handoffs in a conversation.
  ##
  ## Two passes over one message list.  The first recognises calls from their
  ## `toolName`; the second folds every *later* row carrying the same
  ## `toolCallId` onto the call it belongs to, which is how a `tool_call` and
  ## its `tool_call_update` are joined without relying on them being adjacent.
  ##
  ## A call whose backend reports no `toolCallId` (Agent Harbor's shell events
  ## do not) simply keeps `ecsUnreported` — pairing by position instead would
  ## attach whatever row happened to follow, and "the command succeeded" is
  ## exactly the claim that must not be guessed.
  result = @[]
  for message in messages:
    if message.toolName.len == 0:
      continue
    let command = parseEvidenceCommand(message.toolName)
    if command.isNone:
      continue
    result.add EvidenceCall(
      anchorId: message.id,
      toolCallId: message.toolCallId,
      kind: command.get.kind,
      command: message.toolName,
      datasetPath: command.get.datasetPath,
      # The call row may already carry an outcome (a backend that emits one
      # update per call rather than a call plus an update).
      state: evidenceStateFromStatus(message.status),
      failureText: "",
      dataset: EvidenceDataset(state: edsUnknown))

  if result.len == 0:
    return

  for message in messages:
    if message.toolCallId.len == 0 or message.toolName.len > 0:
      continue
    let state = evidenceStateFromStatus(message.status)
    if state == ecsUnreported:
      continue
    for i in 0 ..< result.len:
      if result[i].toolCallId != message.toolCallId:
        continue
      result[i].state = state
      # Only a failure keeps its output: a successful collect prints the
      # dataset's location, which the card already states from the command
      # itself, and repeating it would push the affordance off the row.
      result[i].failureText = if state == ecsFailed: message.content else: ""

proc evidenceCommandName*(kind: EvidenceCommandKind): string {.noSideEffect.} =
  ## What the card calls this kind of call, for a reader who has not memorised
  ## the CLI.
  case kind
  of eckCollect: "Collected review evidence"
  of eckHandoff: "Handed over review evidence"

proc canOpenEvidence*(call: EvidenceCall): bool {.noSideEffect.} =
  ## Whether this call has a review to enter.
  ##
  ## The view gates the affordance on this and `AgentActivityVM.openEvidence`
  ## gates the *action* on the same fact, so a stale rendering cannot enter a
  ## review over a dataset that is not there — the shape AA-2 gave the
  ## drill-down, for the same reason.
  call.state == ecsCompleted and call.dataset.state == edsReady and
    call.datasetPath.len > 0

proc evidenceDatasetShapeText*(call: EvidenceCall): string {.noSideEffect.} =
  ## "enough of its shape — file count, reviewed commit — to be recognisable
  ## without opening it" (§2.1.1), or "" when this card has no shape it may
  ## honestly claim.
  ##
  ## Gated on `canOpenEvidence` — the *same* fact that decides the affordance
  ## — rather than on the dataset's read state alone, so the two can never
  ## disagree.  That is not belt-and-braces: a session that collected twice
  ## into one path, failing the first time and succeeding the second, has a
  ## perfectly readable file at the failed call's path, and printing its
  ## shape on that card would attribute a real measurement to a command that
  ## did not produce it.  (Found by this rule's own view test, which paired
  ## "the failed card offers nothing" with "and claims no shape".)
  ##
  ## Under the open-able state the count always prints, zero included — that
  ## *is* a measurement, and hiding it would be the mirror defect AA-2
  ## recorded.  The commit prints only when the dataset names one: a
  ## changeset from a standalone patch has none, and an empty `commitSha` is
  ## absence rather than a value.
  if not call.canOpenEvidence():
    return ""
  let dataset = call.dataset
  result =
    if dataset.fileCount == 1: "1 file" else: $dataset.fileCount & " files"
  if dataset.commit.len > 0:
    result.add " · " & dataset.commit

proc evidenceNoteText*(call: EvidenceCall): string {.noSideEffect.} =
  ## The sentence the card shows about a call that has nothing to open, or ""
  ## when it has.
  ##
  ## AA-1's rule, stated for this surface: **where something happened, say so
  ## in words; where nothing happened, render nothing.**  Every state in which
  ## the reviewer cannot click through produces a sentence naming *which*
  ## state it is, because a card that merely lacked a button would be
  ## indistinguishable from a card that had not loaded yet.
  case call.state
  of ecsUnreported:
    # Deliberately not "still collecting": a transcript cannot tell a command
    # in flight from one whose session ended before it reported.  Stating the
    # observation covers both without claiming either.
    "No outcome has been reported for this command yet."
  of ecsFailed:
    "This command failed, so there is no review dataset to open."
  of ecsCompleted:
    case call.dataset.state
    of edsReady:
      ""
    of edsUnknown:
      "Reading " & call.datasetPath & "…"
    of edsUnavailable:
      var text = "The review dataset at " & call.datasetPath &
        " could not be read."
      if call.dataset.message.len > 0:
        text.add " " & call.dataset.message
      text
