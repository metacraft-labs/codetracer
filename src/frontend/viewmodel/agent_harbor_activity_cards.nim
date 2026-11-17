## agent_harbor_activity_cards.nim — CTF-P2b. The comparison of the cardless
## session activity timeline with today's Agent Activity cards: one session's
## Agent Harbor events, in their wire shape, fed to both.
##
## The timeline is `SessionTimelineVM` over `timelineSource` (a
## `TimelineDataSource` holding these events). The cards are CodeTracer's own
## `AgentActivityVM`, fed the way a live session feeds it: each wire event is
## decoded by nim-agent-harbor (`eventFromJson`) and projected by nim-agents
## (`harborEventToAgentEvent`), then handed to the agent service
## (`agent_service.applyEvents`), which records them in the session's store
## entry; the panel reads that entry (`applyAgentSession`). Nothing is
## re-implemented here: the adapter only builds a store entry for a session
## CodeTracer did not start, which `applyEvents` needs to exist.
##
## Both halves must show one session's one event list. `againstCardsProblems`
## says where they do not: another session, or a different number of events
## (the comparison story's check).

import std/json

import nim_agent_harbor
import nim_agents
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_timeline_vm]

import ./agent_service
import ./store/[replay_data_store, types]
import ./viewmodels/agent_activity_vm

export agent_activity_vm, session_timeline_vm

type
  ActivityAgainstCards* = object
    ## One session's events, as the timeline's source and as the cards.
    sessionId*: string
    raw*: seq[JsonNode]          ## the wire events both halves are fed
    events*: seq[AgentEvent]     ## the same, as the agent service takes them
    tabId*: string               ## the cards' store entry
    store*: ReplayDataStore
    cards*: AgentActivityVM

proc agentEventsOf*(sessionId: string; raw: openArray[JsonNode]): seq[AgentEvent] =
  ## Wire events as `applyEvents` takes them: nim-agent-harbor's decoding,
  ## then nim-agents' projection, as a live Agent Harbor session's are.
  for event in raw:
    result.add harborEventToAgentEvent(sessionId, eventFromJson(event))

proc entry*(a: ActivityAgainstCards): AgentServiceSessionEntry =
  ## The cards' store entry.
  for session in a.store.agentSessions.val.sessions:
    if session.tabId == a.tabId: return session

proc newActivityAgainstCards*(store: ReplayDataStore; sessionId: string;
                              raw: openArray[JsonNode]): ActivityAgainstCards =
  ## The cards of `sessionId` over `raw`, oldest first, recorded in `store`
  ## (the host's: a story's, or a test's), whose agent sessions gain the
  ## entry. Call inside a reactive root.
  result = ActivityAgainstCards(sessionId: sessionId, raw: @raw,
                                events: agentEventsOf(sessionId, raw),
                                store: store)
  result.tabId = buildAgentTabId(ctabHarbor, sessionId)
  # A session started elsewhere: the store entry a launch would have made.
  var state = result.store.agentSessions.val
  state.sessions.add AgentServiceSessionEntry(tabId: result.tabId,
                                              sessionId: sessionId,
                                              backend: asbHarbor,
                                              lifecycle: aslRunning)
  state.activeTabId = result.tabId
  result.store.agentSessions.val = state
  let service = newCodeTracerAgentService(result.store,
                                          AgentClient(backend: abkHarbor))
  service.applyEvents(result.tabId, result.events)
  result.cards = createAgentActivityVM(result.store)
  result.cards.applyAgentSession(result.entry)

proc timelineSource*(a: ActivityAgainstCards): TimelineDataSource =
  ## The timeline's source over the same events.
  newTimelineDataSource(@[(a.sessionId, a.raw)], label = "against the cards")

proc againstCardsProblems*(a: ActivityAgainstCards; timeline: SessionTimelineVM;
                           source: AgentHarborDataSource): seq[string] =
  ## Where the two halves do not show one session's one event list: the
  ## timeline's session against the cards' entry, and the events the
  ## timeline's `source` holds for it against the events the cards recorded.
  let entry = a.entry
  if timeline.sessionId != entry.sessionId:
    result.add "the timeline shows " & timeline.sessionId & ", the cards " &
      entry.sessionId
  var held = -1
  source.loadSessionEvents(timeline.sessionId,
    proc(answer: DataResult[SessionEventHistory]) =
      if answer.ok: held = answer.value.rawEvents.len)
  if held != entry.events.len:
    result.add "the timeline's source holds " & $held & " events, the cards " &
      $entry.events.len
