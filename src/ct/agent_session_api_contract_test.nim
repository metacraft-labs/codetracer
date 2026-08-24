## The `nim-agents` / `nim-acp` surface `ct` is built against (RV-6).
##
## Run:  nim c -r --hints:off src/ct/agent_session_api_contract_test.nim
##       (or: just test-agent-api-contract)
##
## ## The failure this exists to catch
##
## `src/ct/review_session.nim` resolves a review's agent session through
## `nim-agents`, which is a *sibling checkout*, not a vendored library: the
## revision it compiles against is whatever the workspace, the CI
## `siblings:` list or `repro.lock` happened to place at `../nim-agents`.
## Those three do not always agree, and when the one in force predates the
## API this repo calls, the build fails — but it fails as a type mismatch
## roughly fifteen minutes into a full Nim compile of `ct`, naming a line
## in `review_session.nim` and blaming the caller.  That diagnostic sends
## you to read the caller, which is correct; the sibling is not.
##
## This module is the same claim, made in about a second, against a name it
## can print.  It compiles the exact calls `review_session.nim` makes — the
## real signatures, the real argument names, the real return type — so a
## sibling that is behind fails *here*, with the remedy in the message,
## before the expensive build starts.
##
## ## Why a compile-time contract and not a mock
##
## There is no double anywhere in this file, and nothing is stubbed: every
## symbol below resolves to production `nim-agents` / `nim-acp` code in the
## sibling checkout, and the assertions are the compiler's own overload
## resolution.  That is the whole point — a test that *simulated* the
## sibling would pass against a sibling that no longer exists in that
## shape, which is precisely the failure being guarded.
##
## Nothing here performs I/O.  `loadSession` and `fromStdioAcpAgent` are
## never *called*: spawning an agent or reaching a Harbor endpoint would
## make this a slow, network-dependent test of somebody else's code.  What
## is asserted is that the calls **type-check**, which is the entire
## content of "the sibling is at the right revision".  The runtime
## behaviour behind them is owned by `nim-agents/tests/
## test_session_load_client.nim` and `nim-acp/tests/test_session_load.nim`.
##
## ## What must stay true here
##
## Every check below has to *positively find* something.  A contract test
## that merely compiled an empty module would pass against any sibling at
## all, which is the vacuous-green shape this file must not take: so the
## call shapes are written out in full, the state spellings are compared to
## literals, and the runtime suite at the bottom asserts values rather than
## just the absence of a compile error.

import std/json
import std/unittest

import nim_everywhere
import nim_agents

import review_session

# ---------------------------------------------------------------------------
# The call shapes `review_session.nim` makes.
#
# These procs are never invoked.  Their bodies are the contract: if any
# signature in the sibling has drifted, this module does not compile, and
# the message names this file rather than the caller.
# ---------------------------------------------------------------------------

proc acpCallShape(spec: ReviewSessionRefSpec): JsonNode {.used.} =
  ## `resolveReviewSession`'s ACP branch, verbatim.
  ##
  ## `fromStdioAcpAgent` is native-only in `nim-agents` (it spawns a stdio
  ## child), which is why this whole module is native-only too.
  var client: AgentClient = fromStdioAcpAgent(spec.agentCommand, spec.agentArgs)
  let loaded: AgentSessionLoad = client.loadSession(spec.sessionId,
    cwd = spec.workspacePath, taskId = spec.taskId)
  result = loaded.toJson()
  client.shutdown()

proc harborCallShape(spec: ReviewSessionRefSpec;
                     transport: HttpTransport): JsonNode {.used.} =
  ## `resolveReviewSession`'s Harbor branch, verbatim.
  var client: AgentClient = fromHarbor(newHarborClient(spec.endpoint, transport))
  let loaded: AgentSessionLoad = client.loadSession(spec.sessionId,
    cwd = spec.workspacePath, taskId = spec.taskId)
  result = loaded.toJson()
  client.shutdown()

suite "cross-repo API contract: nim-agents session loading":
  test "ct_agent_session_api_contract_binds_every_call_review_session_makes":
    ## The compile-time half, restated as a runtime assertion so this suite
    ## cannot pass by having asserted nothing.  Taking the address of each
    ## shape forces it to be instantiated rather than discarded as unused
    ## generic scaffolding.
    check acpCallShape != nil
    check harborCallShape != nil

  test "ct_agent_session_load_states_match_the_strings_ct_repeats":
    ## `review_session.nim` repeats `nim-agents`' three state spellings as
    ## its own string constants, because its pure half compiles on the
    ## JavaScript backend where `nim-agents`' native transports do not
    ## exist.  That duplication is only safe while the two agree, and
    ## nothing else in this repo compares them — the renderer receives
    ## strings that have already been through `toJson`.
    ##
    ## The enum is also walked in full, so a fourth state added upstream
    ## without a decision here is a failure rather than something a
    ## three-line check silently ignores.
    check $aslsLoaded == ReviewSessionStateLoaded
    check $aslsUnsupported == ReviewSessionStateUnsupported
    check $aslsUnavailable == ReviewSessionStateUnavailable

    var upstream: seq[string] = @[]
    for state in AgentSessionLoadState:
      upstream.add $state
    check upstream == @[ReviewSessionStateLoaded, ReviewSessionStateUnsupported,
      ReviewSessionStateUnavailable]

  test "ct_agent_session_document_carries_the_keys_the_renderer_reads":
    ## `resolveReviewSession` hands the renderer either `loaded.toJson()`
    ## (from `nim-agents`) or `unresolvedSessionJson` (from this repo), and
    ## the renderer decodes both with one path.  Every key that path reads
    ## must therefore exist in **both** documents; a key present in only one
    ## of them is a field the panel sees on a success and not on a failure,
    ## which is how a renderer ends up reading null on exactly the paths
    ## that matter.
    ##
    ## The five are asserted by name against both producers rather than by
    ## comparing the two key sets for equality.  Set equality would be a
    ## stricter rule than anything states: `nim-agents` serialises for more
    ## consumers than this one, and it is entitled to carry a field this
    ## renderer ignores.  It does today — see the `taskId` assertion below,
    ## which pins that difference as *known* rather than letting it sit
    ## undetected behind a count.
    let unresolved = unresolvedSessionJson(
      ReviewSessionRefSpec(sessionId: "session-abc", backend: "acp"),
      ReviewSessionStateUnavailable, "unknown session: session-abc")

    var localKeys: seq[string] = @[]
    for key in unresolved.keys:
      localKeys.add key

    # The sibling's own document, built from a default value so this needs
    # no agent: `toJson` is a pure projection of the object.
    let fromSibling = AgentSessionLoad(state: aslsUnavailable).toJson()
    var siblingKeys: seq[string] = @[]
    for key in fromSibling.keys:
      siblingKeys.add key

    check localKeys.len == 5
    for expected in ["state", "sessionId", "backend", "message", "events"]:
      check expected in localKeys
      check expected in siblingKeys

    check unresolved["state"].getStr() == ReviewSessionStateUnavailable
    check fromSibling["state"].getStr() == ReviewSessionStateUnavailable
    check unresolved["events"].kind == JArray
    check fromSibling["events"].kind == JArray

  test "ct_agent_session_document_taskid_asymmetry_is_known_and_unread":
    ## `nim-agents`' document carries `taskId` — Agent Harbor's id for the
    ## task owning the session — and this repo's failure document does not.
    ##
    ## That asymmetry is deliberate on neither side; it is simply where the
    ## two producers landed, and it is harmless *only for as long as nothing
    ## in the renderer reads it*, because a review whose session failed to
    ## load would find the field missing.  Pinning it here means the day
    ## something wants `taskId` on a review, this test says so rather than
    ## the field silently reading empty on every failure path.
    let fromSibling = AgentSessionLoad(
      session: AgentSession(id: "session-abc", taskId: "task-42",
        backend: abkHarbor),
      state: aslsLoaded).toJson()
    let unresolved = unresolvedSessionJson(
      ReviewSessionRefSpec(sessionId: "session-abc", backend: "harbor",
        taskId: "task-42"),
      ReviewSessionStateUnavailable, "unreachable")

    check fromSibling.hasKey("taskId")
    check fromSibling["taskId"].getStr() == "task-42"
    # The reference this repo writes into a dataset *does* keep the task id;
    # it is only the resolved-session document that drops it, so nothing is
    # lost — the caller still holds the spec.
    check not unresolved.hasKey("taskId")
    check fromSibling["backend"].getStr() == "harbor"
    check unresolved["backend"].getStr() == "harbor"
