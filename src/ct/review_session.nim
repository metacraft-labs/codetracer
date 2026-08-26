## The agent session a review dataset came from (RV-6).
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: a review dataset MAY
## carry an optional reference to the agent session that produced it, and
## opening the review loads *that session* into the Agent Activity panel, so
## the reviewer can read what the agent actually did in the run leading up to
## the dataset.
##
## Two rules shape everything in this module.
##
## **CodeTracer does not persist agent sessions and must not start.**  Session
## history belongs to the agent backend — Agent Harbor, or the ACP agent — and
## is reached through `nim-agents`.  Nothing here writes a transcript
## anywhere durable; a resolved session lives for exactly as long as the
## review window that is showing it.
##
## **The dataset stores a reference, never a copy.**  A dataset that embedded
## the conversation would go stale the moment the session gained another turn,
## and would duplicate conversation content into a file that may be shared far
## more widely than the session it came from.  So `review.json` carries an id
## plus the context needed to resolve it (`DeepReviewSessionRef`), and the
## transcript is fetched at review-open time.
##
## ## Where each half runs
##
## The module is split the way `review_cli.nim` is, and for the same reason:
##
## * Everything that *decides* something — what the environment says, what a
##   reference means, whether a resolution succeeded and what to say about it
##   — is a pure function of its inputs, so the whole contract is assertable
##   headlessly on both the C and the JavaScript Nim backends.
## * The `when not defined(js)` half performs those decisions: it reads the
##   environment, rewrites `review.json`, spawns an ACP agent or speaks HTTP
##   to Agent Harbor, and writes the resolved session out for the renderer.
##
## ## The two moments
##
## ===============================  ==========================================
## Moment                           What happens here
## ===============================  ==========================================
## `ct review collect …`            :proc:`detectReviewSessionRef` reads the
##                                  agent's environment; if it names a
##                                  session, :proc:`stampReviewSessionRef`
##                                  writes the reference into the dataset that
##                                  was just produced.  Absence is normal.
## `ct review <PATH>`               :proc:`reviewSessionRefOfDataset` reads the
##                                  reference back, :proc:`resolveReviewSession`
##                                  asks the backend for the session, and the
##                                  outcome — transcript **or** an explicit
##                                  failure — is handed to the renderer.
## ===============================  ==========================================
##
## Why the *stamp* rather than the collectors: the reference is a fact about
## the **environment the collection ran in**, and `ct review collect` is the
## one process that sees it.  It is also the single path both collectors go
## through (the rr collector lives in `codetracer-native-backend`, the
## materialized one in `src/db-backend`), so doing it once here is what makes
## the reference independent of which collector ran — rather than two
## implementations that can disagree.

import std/json
import std/strutils

const
  ReviewSessionIdEnvVar* = "CODETRACER_AGENT_SESSION_ID"
    ## The session the collecting agent is running as.  This is the one
    ## variable that decides whether a dataset gets a reference at all: with
    ## no session id there is nothing to point at, which is the ordinary case
    ## for a human running `ct review collect` by hand.
  ReviewSessionBackendEnvVar* = "CODETRACER_AGENT_BACKEND"
    ## `"acp"` or `"harbor"`.  Defaulted rather than required — see
    ## :proc:`reviewSessionRefFromEnv`.
  ReviewSessionTaskEnvVar* = "CODETRACER_AGENT_TASK_ID"
  ReviewSessionWorkspaceEnvVar* = "CODETRACER_AGENT_WORKSPACE"
  ReviewSessionAcpCommandEnvVar* = "CODETRACER_AGENT_ACP_COMMAND"
  ReviewSessionAcpArgsEnvVar* = "CODETRACER_AGENT_ACP_ARGS"
    ## Whitespace-separated.  Deliberately not a shell string: a reference
    ## that needed shell quoting to be correct would be a reference that
    ## could be wrong in a way nothing here could detect.
  ReviewSessionHarborUrlEnvVar* = "CODETRACER_AGENT_HARBOR_URL"

  AcpBackendName* = "acp"
  HarborBackendName* = "harbor"

  ReviewSessionStateLoaded* = "loaded"
  ReviewSessionStateUnsupported* = "unsupported"
  ReviewSessionStateUnavailable* = "unavailable"
    ## The three spellings `nim-agents`' `AgentSessionLoadState` renders as.
    ## They are repeated here rather than imported because the pure half of
    ## this module compiles on the JavaScript backend, where `nim-agents`'
    ## native transports do not exist; the round-trip is pinned by
    ## `agents_load_session_state_renders_as_a_stable_string` in
    ## `nim-agents/tests/test_session_load_client.nim` at the other end.

type
  ReviewSessionRefSpec* = object
    ## A `DeepReviewSessionRef` in the plain-string form the CLI works in.
    ##
    ## Separate from the `common_types` type on purpose: that one is
    ## `include`d twice (once with `langstring = cstring`, once with
    ## `langstring = string`) and cannot be named from a module that must
    ## compile on both backends without picking one.
    sessionId*: string
    backend*: string
    workspacePath*: string
    taskId*: string
    agentCommand*: string
    agentArgs*: seq[string]
    endpoint*: string

proc hasSessionRef*(spec: ReviewSessionRefSpec): bool {.noSideEffect.} =
  ## Whether `spec` names a session at all.
  ##
  ## The id is the whole test: every other field is context for resolving an
  ## id, and none of them means anything without one.  A dataset whose
  ## environment supplied, say, only a Harbor URL is *not* associated with a
  ## session, and stamping a reference with an empty id would produce exactly
  ## the "unresolvable reference" state §2.1 asks to be shown — for a review
  ## that in truth has no session.
  spec.sessionId.len > 0

proc normalizeBackend*(value: string): string {.noSideEffect.} =
  ## The backend name, canonicalised.
  ##
  ## Anything unrecognised resolves to ACP rather than to Harbor because ACP
  ## needs the most context to resolve a session and therefore fails loudest;
  ## defaulting to Harbor would send a request to whatever URL happened to be
  ## configured, which is a worse answer than an explicit failure.
  if value.strip().toLowerAscii() == HarborBackendName:
    HarborBackendName
  else:
    AcpBackendName

proc splitAgentArgs*(value: string): seq[string] {.noSideEffect.} =
  ## Split `CODETRACER_AGENT_ACP_ARGS` on whitespace, dropping empties.
  for part in value.splitWhitespace():
    if part.len > 0:
      result.add part

proc reviewSessionRefFromEnv*(lookup: proc(name: string): string {.closure.};
                              fallbackWorkspace = ""): ReviewSessionRefSpec =
  ## Read the session reference out of the agent's environment.
  ##
  ## `Agentic-Coding-Integration.md` §4: "The session it belongs to, the task,
  ## and the workspace are read from the **environment variables the agent
  ## already runs under**, because an agent process is launched by a harness
  ## that knows all three; requiring the agent to restate them invites
  ## disagreement between what it claims and where it actually is."
  ##
  ## `lookup` is injected rather than calling `getEnv` directly so this — the
  ## part that decides what an environment *means* — is assertable on both Nim
  ## backends and without mutating the test process's own environment.
  ##
  ## **Absence is normal, not an error.**  A human running `ct review collect`
  ## by hand has none of these set and gets a spec with an empty
  ## `sessionId`, which :proc:`hasSessionRef` reports as "no reference" and
  ## the caller silently honours.
  ##
  ## The backend defaults rather than being required: a harness that set a
  ## Harbor URL is running a Harbor session, and one that set an ACP command
  ## is running an ACP one.  An explicit `CODETRACER_AGENT_BACKEND` always
  ## wins, because a harness that says which it is knows better than this
  ## inference does.
  result.sessionId = lookup(ReviewSessionIdEnvVar).strip()
  if result.sessionId.len == 0:
    return
  result.taskId = lookup(ReviewSessionTaskEnvVar).strip()
  result.endpoint = lookup(ReviewSessionHarborUrlEnvVar).strip()
  result.agentCommand = lookup(ReviewSessionAcpCommandEnvVar).strip()
  result.agentArgs = splitAgentArgs(lookup(ReviewSessionAcpArgsEnvVar))
  let declared = lookup(ReviewSessionBackendEnvVar).strip()
  result.backend =
    if declared.len > 0: normalizeBackend(declared)
    elif result.endpoint.len > 0: HarborBackendName
    else: AcpBackendName
  let workspace = lookup(ReviewSessionWorkspaceEnvVar).strip()
  result.workspacePath =
    if workspace.len > 0: workspace else: fallbackWorkspace

proc toJson*(spec: ReviewSessionRefSpec): JsonNode =
  ## The reference as it is written into `review.json`.
  ##
  ## Field names match `DeepReviewSessionRef`'s exactly, because the renderer
  ## reads the dataset with an unchecked `cast` over `JSON.parse` — the same
  ## contract every other field of `DeepReviewData` is held to.
  result = %*{
    "sessionId": spec.sessionId,
    "backend": normalizeBackend(spec.backend),
    "workspacePath": spec.workspacePath,
    "taskId": spec.taskId,
    "agentCommand": spec.agentCommand,
    "endpoint": spec.endpoint
  }
  var args = newJArray()
  for arg in spec.agentArgs:
    args.add %arg
  result["agentArgs"] = args

proc reviewSessionRefFromJson*(node: JsonNode): ReviewSessionRefSpec =
  ## Read a reference back out of a dataset.  A missing or non-object
  ## `session` yields an empty spec — i.e. "this dataset names no session",
  ## which is a complete review and not a failure.
  if node == nil or node.kind != JObject:
    return
  result = ReviewSessionRefSpec(
    sessionId: node{"sessionId"}.getStr("").strip(),
    backend: normalizeBackend(node{"backend"}.getStr("")),
    workspacePath: node{"workspacePath"}.getStr(""),
    taskId: node{"taskId"}.getStr(""),
    agentCommand: node{"agentCommand"}.getStr(""),
    endpoint: node{"endpoint"}.getStr(""))
  # `getElems`, not `items`: `items` dereferences its argument, and a session
  # reference written by anything other than `toJson` (a hand-edited dataset,
  # an older writer, another tool) need not carry `agentArgs` at all.  The
  # doc comment above promises that a session this cannot read yields an empty
  # spec rather than a failure, and a nil dereference is not that.
  for arg in node{"agentArgs"}.getElems:
    result.agentArgs.add arg.getStr("")

proc withSessionRef*(dataset: JsonNode;
                     spec: ReviewSessionRefSpec): JsonNode =
  ## `dataset` with the session reference set — or *removed*, when `spec`
  ## names none.
  ##
  ## Removing rather than writing `"session": null` is deliberate: a null
  ## would be indistinguishable from a reference the writer failed to
  ## serialise, and the difference matters because one of them is normal and
  ## the other is a bug.  Re-stamping is idempotent, so collecting twice into
  ## the same directory cannot leave a stale reference behind.
  if dataset == nil or dataset.kind != JObject:
    return dataset
  result = dataset
  if hasSessionRef(spec):
    result["session"] = spec.toJson()
  elif result.hasKey("session"):
    result.delete("session")

proc unresolvedSessionJson*(spec: ReviewSessionRefSpec;
                            state, message: string): JsonNode =
  ## A resolved-session document describing a failure.
  ##
  ## Produced instead of "no session at all" so the panel can say *why* the
  ## conversation is missing.  §2.1: "It must not silently render an empty
  ## session, which reads as 'the agent did nothing'."
  %*{
    "state": state,
    "sessionId": spec.sessionId,
    "backend": normalizeBackend(spec.backend),
    "message": message,
    "events": newJArray()
  }

proc missingAcpCommandMessage*(spec: ReviewSessionRefSpec): string =
  ## Why an ACP reference with no agent binary cannot be resolved.  Naming
  ## the environment variable is the point: the fix is one export away, and a
  ## message that only said "cannot load session" would not say so.
  "the dataset names ACP session '" & spec.sessionId &
    "' but no agent command to reach it; set " &
    ReviewSessionAcpCommandEnvVar &
    " when collecting so the reference can be resolved"

proc missingHarborUrlMessage*(spec: ReviewSessionRefSpec): string =
  "the dataset names Agent Harbor session '" & spec.sessionId &
    "' but no Harbor endpoint to reach it; set " &
    ReviewSessionHarborUrlEnvVar &
    " when collecting so the reference can be resolved"

when not defined(js):
  import std/[httpclient, os]
  import nim_everywhere
  import nim_agents

  proc envLookup*(name: string): string =
    ## `getEnv`, as the closure :proc:`reviewSessionRefFromEnv` wants.
    getEnv(name, "")

  proc detectReviewSessionRef*(cwd = ""): ReviewSessionRefSpec =
    ## The session the current process's environment names, if any.
    reviewSessionRefFromEnv(envLookup, fallbackWorkspace = cwd)

  proc stampReviewSessionRef*(jsonPath: string;
                              spec: ReviewSessionRefSpec): string =
    ## Write `spec` into the dataset at `jsonPath`.  Returns an error message,
    ## or `""` on success.
    ##
    ## A no-op when the spec names no session *and* the dataset carries none,
    ## so the ordinary human collection does not rewrite a file for nothing.
    ##
    ## Rewriting the produced `review.json` — rather than teaching each
    ## collector to emit the field — is what makes the reference independent
    ## of which collector ran; see the module header.
    ##
    ## The order of the two guards below matters.  A missing dataset is only
    ## this proc's problem when there is a reference that needs writing into
    ## it: with no session named there is nothing to do, and reporting the
    ## file's absence would turn RV-6 into a new post-condition on
    ## `ct review collect` that the collectors' own success reporting does not
    ## make.  Absence of a session is normal (DeepReview-GUI.md §2.1) and must
    ## stay costless.
    if not hasSessionRef(spec) and not fileExists(jsonPath):
      return ""
    if not fileExists(jsonPath):
      return "no review dataset at '" & jsonPath & "' to associate a session with"
    var dataset: JsonNode
    try:
      dataset = parseFile(jsonPath)
    except CatchableError as e:
      return "could not read '" & jsonPath & "': " & e.msg
    if dataset.kind != JObject:
      return "'" & jsonPath & "' is not a review dataset object"
    if not hasSessionRef(spec) and not dataset.hasKey("session"):
      return ""
    try:
      writeFile(jsonPath, pretty(dataset.withSessionRef(spec)))
    except CatchableError as e:
      return "could not write '" & jsonPath & "': " & e.msg
    ""

  proc reviewSessionRefOfDataset*(jsonPath: string): ReviewSessionRefSpec =
    ## The reference a dataset carries, or an empty spec.
    ##
    ## A dataset that cannot be parsed yields no reference rather than
    ## raising: `ct review` is about to hand the same file to the renderer,
    ## which diagnoses a malformed dataset itself, and failing here would
    ## replace that diagnosis with a worse one about sessions.
    if not fileExists(jsonPath):
      return
    try:
      let dataset = parseFile(jsonPath)
      if dataset.kind != JObject:
        return
      reviewSessionRefFromJson(dataset{"session"})
    except CatchableError:
      ReviewSessionRefSpec()

  proc harborHttpTransport(): HttpTransport =
    ## A synchronous HTTP transport over `std/httpclient`, which is what
    ## Agent Harbor's REST client wants and what `nim-everywhere` does not
    ## ship (it offers a fake and an async `fetch`, neither usable from a
    ## short-lived CLI process).
    ##
    ## Kept deliberately thin: every decision about what a response *means*
    ## belongs to `nim-agent-harbor`, which is where it is tested.
    proc(request: HttpRequest): HttpResponse =
      var client = newHttpClient()
      try:
        var headers = newHttpHeaders()
        for header in request.headers:
          headers[header.name] = header.value
        # `nim-everywhere`'s `HttpMethod` and `std/httpclient`'s are distinct
        # enums; mapped explicitly rather than through the deprecated
        # string-typed overload.
        let verb =
          case request.httpMethod
          of hmGet: httpclient.HttpGet
          of hmPost: httpclient.HttpPost
          of hmPut: httpclient.HttpPut
          of hmDelete: httpclient.HttpDelete
        let response = client.request(
          request.url,
          httpMethod = verb,
          body = request.body,
          headers = headers)
        result = HttpResponse(
          status: response.code.int,
          body: response.body)
        for name, value in response.headers.pairs:
          result.headers.add HttpHeader(name: name, value: value)
      except CatchableError as e:
        # A transport failure is an unavailable session, not a crash: the
        # caller turns a non-2xx into the explicit "could not be reached"
        # state the panel renders.
        result = HttpResponse(status: 599, body: e.msg)
      finally:
        try: client.close() except CatchableError: discard

  proc resolveReviewSession*(spec: ReviewSessionRefSpec): JsonNode =
    ## Ask the backend for the session `spec` names, and return the outcome
    ## in the form the renderer reads (`DeepReviewSessionTranscript`).
    ##
    ## Never nil when `spec` names a session, and never an empty document
    ## standing in for a failure: every path produces an explicit `state`.
    ## That is the whole contract §2.1 asks for — "when the backend cannot
    ## resolve the referenced session … the panel says so explicitly".
    if not hasSessionRef(spec):
      return nil
    let backend = normalizeBackend(spec.backend)
    var client: AgentClient
    if backend == HarborBackendName:
      if spec.endpoint.len == 0:
        return unresolvedSessionJson(spec, ReviewSessionStateUnavailable,
          missingHarborUrlMessage(spec))
      client = fromHarbor(newHarborClient(spec.endpoint, harborHttpTransport()))
    else:
      if spec.agentCommand.len == 0:
        return unresolvedSessionJson(spec, ReviewSessionStateUnavailable,
          missingAcpCommandMessage(spec))
      try:
        client = fromStdioAcpAgent(spec.agentCommand, spec.agentArgs)
      except CatchableError as e:
        # The agent binary is gone, or is not on PATH any more.  That is an
        # unresolvable reference, reported as one.
        return unresolvedSessionJson(spec, ReviewSessionStateUnavailable,
          "could not start the ACP agent '" & spec.agentCommand & "': " & e.msg)
    try:
      let loaded = client.loadSession(spec.sessionId,
        cwd = spec.workspacePath, taskId = spec.taskId)
      result = loaded.toJson()
    except CatchableError as e:
      result = unresolvedSessionJson(spec, ReviewSessionStateUnavailable, e.msg)
    finally:
      # The ACP child must not outlive the resolution; `ct` is about to exec
      # Electron and would otherwise leak an agent process per review.
      client.shutdown()

  proc writeResolvedReviewSession*(session: JsonNode;
                                   dir = getTempDir()): string =
    ## Persist a resolved session where the renderer can read it, and return
    ## the path.
    ##
    ## This file holds conversation content, so it is deliberately *not* the
    ## dataset and deliberately not durable: it is written next to the
    ## process's temporary files, named per process, and is the renderer's to
    ## read once.  The dataset keeps only the reference — see the module
    ## header.
    if session == nil:
      return ""
    let path = dir / ("codetracer-review-session-" & $getCurrentProcessId() &
      ".json")
    try:
      writeFile(path, $session)
      path
    except CatchableError:
      # Losing the transcript must not stop the review opening; the panel
      # then shows no session, which is the same state a dataset without a
      # reference produces.
      ""
