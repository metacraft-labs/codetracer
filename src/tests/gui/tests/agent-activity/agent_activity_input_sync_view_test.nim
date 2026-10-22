## agent_activity_input_sync_view_test.nim
##
## The prompt box's VM -> element sync must not feed back into the VM.
##
## The panel binds the prompt textarea to `AgentActivityVM.inputValue` in both
## directions: an `input` event the USER causes writes the VM
## (`attachInputEvents` -> `invokeInputChange`, which also tells the host
## through `onInputChange`), and a render effect copies the VM back into the
## element (`syncInputValue`).  The second direction used to finish by
## dispatching a synthetic `input` event, so every programmatic sync looked
## like typing: the host's `onInputChange` republished its whole state into
## the VM, the effect that had just run was invalidated again, and on a
## DeepReview launch -- where each republish flips `isLoading` and the
## conversation between the live carrier and the replayed session -- the
## cycle ran until the renderer threw "Maximum call stack size exceeded".
##
## What this file pins:
##   * a VM write never reaches `onInputChange` -- the host hears about the
##     prompt only when the user edits it;
##   * the element still shows the VM's value after a programmatic write;
##   * the conversation written alongside it lands;
##   * the user's own edits still reach the VM and the host, exactly once;
##   * so does a suggestion chip, which fills the prompt for the user and
##     used to reach the host only through the synthetic event.
##
## The host callback below re-publishes the same state the production
## carrier does (`agent_activity.syncLegacyAgentActivityIntoVM`, followed by
## `replayReviewSessionInto`): the live conversation and `isLoading`, then the
## review's session over them.  It counts how often it is entered; the
## re-entry bound only keeps a regressed build from overflowing the test
## process's stack, so that the failure is reported as an assertion with a
## count instead of as a crash.  It is not a limit the product relies on.
##
## The Electron end-to-end twins are
## `agent-activity-deepreview/agent-activity-evidence.spec.ts` and
## `agent-activity-test-run.spec.ts`, which launch a review over a replayed
## session.
##
## TEST DOUBLE JUSTIFICATION (workspace policy).  One collaborator is supplied
## by the test: `MockRenderer`, IsoNim's headless renderer and the standard
## vehicle for every view suite in this repository.  The production
## `WebRenderer` needs a browser; the view code is generic over the renderer,
## and the input sync in particular is ONE generic routine
## (`syncInputValue`) over two renderer primitives, so the same sync runs
## either way.  The primitives themselves differ, and the synthetic event
## lived in the browser's write primitive, which the mock never runs: this
## file fails if the dispatch comes back in the shared routine (or in the
## mock's primitive), and the Electron twins above are what fail if it comes
## back in the browser's.  The store's `MockBackendService` is only there because
## `createAgentActivityVM` needs a store; nothing here talks to a backend.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom

import backend/mock_backend
import store/replay_data_store
import store/types
import viewmodels/agent_activity_vm
import viewmodels/review_session
import views/isonim_agent_activity_view

const ReentryBound = 25
  ## See the header: only a crash guard for a regressed build.

proc makeStore(): ReplayDataStore =
  createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())

proc findByTag(node: MockNode; tag: string): seq[MockNode] =
  if node.kind == mnkElement and node.tag.toLowerAscii == tag:
    result.add node
  for child in node.children:
    result.add findByTag(child, tag)

proc reviewSession(): ReviewSession =
  ## A finished session as `session/load` hands it over: a thought, a
  ## message, a status.
  ReviewSession(
    state: rssLoaded,
    sessionId: "session-fixture",
    events: @[
      ReviewSessionEvent(kind: "thought",
                         text: "Collecting the first review dataset"),
      ReviewSessionEvent(kind: "message",
                         text: "The tokenizer change is ready to read."),
    ])

type
  Host = ref object
    ## The production carrier's half of the binding, reduced to the state
    ## it republishes.
    vm: AgentActivityVM
    prompt: string
    liveIsLoading: bool
    entries: int

proc republish(host: Host) =
  ## `syncLegacyAgentActivityIntoVM` + `replayReviewSessionInto`, in that
  ## order: the live carrier (an empty conversation, a turn it believes is
  ## running), then the review's session over it, which ends the turn.
  host.vm.setMessages(newSeq[AgentActivityMessageEntry]())
  host.vm.setInputValue(host.prompt)
  host.vm.setLoading(host.liveIsLoading)
  applyReviewSession(host.vm, reviewSession())

proc callbacksFor(host: Host): AgentActivityCallbacks =
  result.onInputChange = proc(value: string) =
    inc host.entries
    if host.entries > ReentryBound:
      return
    host.prompt = value
    host.republish()

suite "the prompt's VM -> element sync does not feed back":

  test "a republish neither re-enters the host nor loses the conversation":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let host = Host(vm: vm, prompt: "a draft", liveIsLoading: true)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 97,
                                           callbacks = callbacksFor(host))
      let prompt = findByTag(panel, "textarea")[0]

      host.republish()

      check host.entries == 0
      check prompt.attributes.getOrDefault("value", "") == "a draft"
      check vm.inputValue.val == "a draft"
      check vm.messages.val.len == 2
      check vm.messages.val[0].content == "Collecting the first review dataset"
      check not vm.isLoading.val

      dispose()

  test "every VM write of the prompt reaches the element and not the host":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let host = Host(vm: vm)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 98,
                                           callbacks = callbacksFor(host))
      let prompt = findByTag(panel, "textarea")[0]

      for value in ["first", "first and second", ""]:
        vm.setInputValue(value)
        check prompt.attributes.getOrDefault("value", "<unset>") == value
      vm.setLoading(true)
      vm.setLoading(false)

      check host.entries == 0

      dispose()

  test "the user's edit reaches the VM and the host exactly once":
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let host = Host(vm: vm, liveIsLoading: true)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 99,
                                           callbacks = callbacksFor(host))
      let prompt = findByTag(panel, "textarea")[0]

      # The browser has already put the typed text into the element when it
      # fires `input`; the mock's value attribute is that state.
      prompt.attributes["value"] = "typed by the user"
      prompt.fireEvent("input")

      check host.entries == 1
      check host.prompt == "typed by the user"
      check vm.inputValue.val == "typed by the user"
      check prompt.attributes.getOrDefault("value", "") == "typed by the user"

      dispose()

  test "a suggestion chip is the user's input: the host hears it and keeps it":
    # The idle state's chips fill the prompt for the user.  That is input, so
    # it must reach the host the way typing does: the host keeps its own copy
    # of the prompt and republishes it on every sync, and a copy left behind
    # would wipe the chosen suggestion off the prompt at the next one.  The
    # synthetic `input` event used to carry it there by accident.
    createRoot proc(dispose: proc()) =
      let vm = createAgentActivityVM(makeStore())
      let host = Host(vm: vm)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel[MockRenderer, MockNode](r, vm, componentId = 100,
                                           callbacks = callbacksFor(host))
      let prompt = findByTag(panel, "textarea")[0]
      var chip: MockNode
      for button in findByTag(panel, "button"):
        if "agent-idle-chip" in button.attributes.getOrDefault("class", "") and
            textContent(button) == "Explain this codebase":
          chip = button
      check chip != nil

      chip.fireEvent("click")

      check host.entries == 1
      check host.prompt == "Explain this codebase"
      check vm.inputValue.val == "Explain this codebase"
      check prompt.attributes.getOrDefault("value", "") ==
        "Explain this codebase"
      # The next sync from the host leaves the suggestion where it is.
      host.republish()
      check prompt.attributes.getOrDefault("value", "") ==
        "Explain this codebase"

      dispose()
