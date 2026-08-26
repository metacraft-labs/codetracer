## The agent session a review is bound to, as the ViewModel layer sees it
## (RV-6).
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: "The primary thing
## the panel shows in a review is **the agent session that produced it**.  A
## review dataset MAY carry an optional reference to that session; when it
## does, opening the review loads the session into the Agent Activity panel."
##
## What arrives here has already been resolved: `ct` read the dataset's
## reference, asked the agent backend for the session through `nim-agents`,
## and handed the outcome to the renderer (`src/ct/review_session.nim`).  This
## module turns that outcome into what the panel renders, and it is the one
## place that decides **what a reviewer is told**:
##
## ==================  ====================================================
## State               What the panel shows
## ==================  ====================================================
## absent              Nothing.  A dataset collected by a human, or by an
##                     agent whose backend cannot replay sessions, is a
##                     complete review; §2.1 is explicit that "the panel
##                     simply shows no session rather than an error or an
##                     empty shell".
## loaded, non-empty   The conversation.
## loaded, empty       The conversation *and* a notice saying the session
##                     is empty.  Silence here would be indistinguishable
##                     from the two failures below.
## unsupported         A notice naming the limitation: this agent cannot
##                     replay sessions, so no session on it will load.
## unavailable         A notice naming the session and the backend's own
##                     reason: pruned, unknown, workspace elsewhere,
##                     unreachable.
## ==================  ====================================================
##
## The last three exist because of one rule, which the milestone states as a
## defect condition: "An empty session view that reads as 'the agent did
## nothing' is a defect."  So every non-conversation outcome produces a
## sentence, and none of them produces silence.
##
## Everything here is pure and DOM-free — the host supplies the resolved
## document, this decides what it means — so the whole contract is assertable
## headlessly on both Nim backends (`src/tests/gui/tests/deepreview/
## review_session_vm_test.nim`, registered in `CoreViewModelGateTests`).

import ../store/types
import agent_activity_vm

type
  ReviewSessionState* = enum
    ## Mirrors `nim-agents`' `AgentSessionLoadState`, plus the case that
    ## never reaches `nim-agents` at all.
    rssAbsent = "absent"
      ## The dataset named no session.  Not a failure.
    rssLoaded = "loaded"
    rssUnsupported = "unsupported"
    rssUnavailable = "unavailable"

  ReviewSessionEvent* = object
    ## One entry of a resolved conversation, reduced to what the panel
    ## renders.  A plain value with no `cstring` and no JS object, for the
    ## same reason `ReviewFile` is one (see `review_entry.nim`).
    kind*: string
    text*: string
    status*: string
    toolName*: string
    toolCallId*: string
    filePath*: string

  ReviewSession* = object
    ## A resolved session, or the explicit reason there is not one.
    state*: ReviewSessionState
    sessionId*: string
    backend*: string
    message*: string
      ## The backend's own diagnostic, never one invented here.  Empty for
      ## `rssLoaded` and `rssAbsent`.
    events*: seq[ReviewSessionEvent]

proc `==`*(a, b: ReviewSessionEvent): bool {.noSideEffect.} =
  a.kind == b.kind and a.text == b.text and a.status == b.status and
    a.toolName == b.toolName and a.toolCallId == b.toolCallId and
    a.filePath == b.filePath

proc `==`*(a, b: ReviewSession): bool {.noSideEffect.} =
  a.state == b.state and a.sessionId == b.sessionId and
    a.backend == b.backend and a.message == b.message and a.events == b.events

proc parseReviewSessionState*(value: string): ReviewSessionState
    {.noSideEffect.} =
  ## Inverse of `$`.
  ##
  ## An unrecognised spelling resolves to `rssUnavailable`, never to
  ## `rssLoaded`: guessing "loaded" for something we could not read would
  ## paint an empty conversation and claim it was the agent's, which is
  ## exactly the fabrication this milestone is about.
  case value
  of "absent": rssAbsent
  of "loaded": rssLoaded
  of "unsupported": rssUnsupported
  else: rssUnavailable

proc hasSession*(session: ReviewSession): bool {.noSideEffect.} =
  ## Whether the review is associated with a session at all — regardless of
  ## whether it could be read.  The Agent Activity panel uses this to decide
  ## whether it is showing a *session* at all, which is a different question
  ## from whether it has messages.
  session.state != rssAbsent

proc reviewSessionFrom*[T](transcript: T): ReviewSession =
  ## Project the resolved-session document `ct` produced
  ## (`DeepReviewSessionTranscript`) into the ViewModel layer's value.
  ##
  ## Generic over the *shape* rather than typed against the common type, for
  ## the same reason `review_entry.reviewDatasetFrom` is: that type lives in
  ## `common/common_types/codetracer_features/deepreview.nim`, which is
  ## `include`d twice — once with `langstring = cstring` (the renderer) and
  ## once with `langstring = string` (the headless build) — so the two copies
  ## are distinct types a ViewModel module can name neither of.  One generic
  ## proc instantiated over both means the renderer and the tests run *the
  ## same* projection.
  ##
  ## A nil document is `rssAbsent`: the dataset named no session.  That is
  ## deliberately *not* the same as `rssUnavailable`, and the difference is
  ## the whole reason `ct` writes a document for failures instead of writing
  ## nothing.
  if transcript.isNil:
    return ReviewSession(state: rssAbsent, events: @[])
  result.state = parseReviewSessionState($transcript.state)
  result.sessionId = $transcript.sessionId
  result.backend = $transcript.backend
  result.message = $transcript.message
  result.events = @[]
  for event in transcript.events:
    result.events.add ReviewSessionEvent(
      kind: $event.kind,
      text: $event.text,
      status: $event.status,
      toolName: $event.toolName,
      toolCallId: $event.toolCallId,
      filePath: $event.filePath)

proc eventContent*(event: ReviewSessionEvent): string {.noSideEffect.} =
  ## The line the panel shows for one event.
  ##
  ## The fallback chain mirrors `agentic_session_vm.eventToActivityMessage`
  ## so a loaded session and a live one read alike: an event's own text, else
  ## the tool it named, else the file it touched, else its kind.  The last
  ## resort is the kind rather than the empty string because a blank row is
  ## indistinguishable from a missing one.
  if event.text.len > 0:
    return event.text
  if event.toolName.len > 0:
    return event.toolName
  if event.filePath.len > 0:
    return event.filePath
  event.kind

proc sessionMessages*(session: ReviewSession):
    seq[AgentActivityMessageEntry] {.noSideEffect.} =
  ## The session's conversation as the Agent Activity panel's message rows.
  ##
  ## Ids are `"<sessionId>:<index>"` — the same scheme
  ## `agent_service.toStoreEvent` uses for a live session — so a loaded
  ## session's rows key identically to a live one's and the view's DOM ids
  ## do not collide across the two paths.
  ##
  ## Nothing is marked loading: this is a session that has *finished*.  A
  ## spinner on a replayed row would claim work is still happening.
  ##
  ## AA-3: the tool identity (`toolName`, `toolCallId`, `status`) is carried
  ## through rather than being collapsed into `content` by `eventContent`.
  ## Recognising an evidence handoff needs to know the row *was* a tool call
  ## — an agent that merely writes `ct review collect …` in prose has
  ## collected nothing — and needs the call/update pairing to say whether it
  ## succeeded.
  result = @[]
  for i, event in session.events:
    result.add AgentActivityMessageEntry(
      id: session.sessionId & ":" & $i,
      content: eventContent(event),
      role: aamrAgent,
      canceled: event.kind == "cancelled",
      isLoading: false,
      diffs: @[],
      toolName: event.toolName,
      toolCallId: event.toolCallId,
      status: event.status)

proc sessionNoticeText*(session: ReviewSession): string {.noSideEffect.} =
  ## The sentence the panel shows about this session, or "".
  ##
  ## Every branch that is not "here is the conversation" produces one.  The
  ## backend's own `message` is appended where there is one, because it is
  ## the only part that can distinguish "pruned" from "the workspace moved"
  ## from "the agent host is down" — and inventing a reason would be worse
  ## than quoting the system that actually refused.
  case session.state
  of rssAbsent:
    # No session was ever named.  §2.1: "the panel simply shows no session
    # rather than an error or an empty shell."
    ""
  of rssLoaded:
    if session.events.len > 0:
      ""
    else:
      "Agent session " & session.sessionId &
        " loaded, but it contains no messages."
  of rssUnsupported:
    var text = "The agent cannot replay sessions, so session " &
      session.sessionId & " could not be loaded."
    if session.message.len > 0:
      text.add " " & session.message
    text
  of rssUnavailable:
    var text = "Agent session " & session.sessionId & " could not be loaded."
    if session.message.len > 0:
      text.add " " & session.message
    text

proc applyReviewSession*(activity: AgentActivityVM; session: ReviewSession) =
  ## Put `session` into the Agent Activity panel.
  ##
  ## Called from `review_entry.enterReview`, so every launch path lands the
  ## session the same way — the same convergence rule §7 imposes on the other
  ## three entry steps.
  ##
  ## An **absent** session leaves the panel entirely alone: a review over a
  ## dataset with no reference must not clear a conversation the panel is
  ## already showing (the agentic handoff enters a review from *inside* a
  ## live session, and erasing it would delete the very thing the reviewer
  ## came from).  Every other state replaces the conversation, because the
  ## review is now about that session.
  if activity.isNil or session.state == rssAbsent:
    return
  activity.setSessionKey(session.sessionId)
  activity.setMessages(session.sessionMessages())
  activity.setSessionNotice(session.sessionNoticeText())
  # A replayed session is not in flight; a spinner would say otherwise.
  activity.setLoading(false)
