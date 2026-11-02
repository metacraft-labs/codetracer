## tab_session_ids_test.nim
##
## A TAB'S SESSION ID IS NEVER ONE ANOTHER TAB OF THE WINDOW HAS HELD.
##
## ## The defect this pins
##
## codetracer-pm issue
## `2026-10-23-a-tab-opened-after-closing-a-middle-tab-reuses-a-live-tabs-session-id.md`:
## a "+" tab (`session_switch.createNewSession`) was named
## `ReplaySessionId(data.sessions.len)`, and the same number became its DAP
## session id (`DapApi.sessionId`, via `attachSessionApis`). `closeSession`
## deletes the closed tab from `data.sessions`, so
##
## * open tabs 0, 1 and 2, close tab 1, press "+": the new tab got id 2, the
##   id the surviving third tab holds;
## * open tabs 0 and 1, close tab 1, press "+": the new tab got id 1, the
##   closed tab's.
##
## Commit 5db072dc4 replaced `data.sessions.len` with "one past the largest id
## in use", which fixes the first sequence and not the second: with tab 1 gone
## the largest id in use is 0, and the new tab is tab 1 again. Everything keyed
## by the id treats it as unique per window — the main process routes a tab's
## requests and events by it (`index/ipc_subsystems/dap.nim`), the renderer
## hands an event to the first tab whose `DapApi.sessionId` matches
## (`event_helpers.sessionDapApi`), a main-process answer names its tab by
## `ReplaySession.id` (`ui/tab_answer_routing.deliverTabAnswer`, which drops
## an answer for a closed tab — unless a new tab took the closed one's id),
## and per-tab module tables are keyed by `session_viewmodels.tabScopedKey`.
## The rule is `GUI/Multi-Window-Tab-Management.md` §Tab Behavior rules 1 and
## 4: each tab is an independent session, and closing one leaves nothing a
## later tab could take over.
##
## ## What is asserted
##
## * After each of the two sequences above, and over a longer run of opens and
##   closes, the new tab's `ReplaySession.id` and `DapApi.sessionId` are one
##   number, and it is not one any tab of the window has held, open or closed.
## * Consequently an event the main process tags with the closed tab's id
##   reaches no tab (`deliverDapEvent`), and a per-tab table key of the new tab
##   is not the closed tab's (`tabScopedKey`).
## * The tab's `DapApi` carries the replay the Backend Manager answered for
##   the tab (`ReplaySession.assignReplay`), and every request it sends names
##   that replay (`replayId`) beside the tab's own id (`sessionId`), so the
##   main process can select the replay without assuming the two numbers are
##   equal; a tab with no replay names none, and Stop clears it.
##
## ## What is real, and the one stand-in
##
## REAL: `types`' window `Data` and its first session;
## `event_helpers.newTabSession`, the whole of what `createNewSession` does to
## name a new tab and give it its DAP API (`createNewSession` itself is not
## importable by a runnable lane: `session_switch` reaches the editor through
## its menu, which creates a Monaco model as its module loads — the reason
## `later_session_launch_failure_test.nim` gives); `deliverDapEvent`;
## `tabScopedKey`; `DapApi.sendCtRequest`, the renderer's one send path.
## Closing a tab is `closeSession`'s removal from `data.sessions`
## (`data.sessions.delete(index)`), the step that makes the number free for
## `data.sessions.len` and for "one past the largest in use"; the rest of
## `closeSession` (its GoldenLayout and DOM teardown) is not about ids.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records frames instead
## of writing them to the main process — as in
## `later_session_launch_failure_test.nim`.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run by `jsdom-run.mjs`).
## Without `-d:nodejs` `std/unittest` cannot set the exit status, so this
## suite sets it.

import std/[unittest, jsffi, sets]

import ../types
import ../dap
import ../event_helpers
import ../ui/session_viewmodels
import ../../common/ct_event

const ExpectedChecks = 29
var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  inc checks
  if not (cond):
    inc failedChecks
  check cond

template scenario(name: string; body: untyped) =
  block:
    let failedBefore = failedChecks
    body
    echo(if failedChecks == failedBefore: "  [OK] " else: "  [FAILED] ", name)

var sentPackets: seq[(cstring, JsObject)] = @[]

proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add((channel, packet))
  ipc

data.ipc = recordingIpc()
data.dapApi.ipc = data.ipc

var everUsed = initHashSet[int]()
  ## Every id a tab of this window has held, open or closed.
everUsed.incl int(data.sessions[0].id)
everUsed.incl data.sessions[0].dapApi.sessionId

proc openTab(): ReplaySession =
  ## The "+" button: a new tab, named and wired as `createNewSession` names
  ## and wires it, appended to the window's tabs.
  result = newTabSession(data, data.ipc)
  data.sessions.add(result)

proc closeTab(index: int) =
  ## `closeSession`'s removal of the tab at `index` from the window.
  data.sessions.delete(index)

proc isFresh(tab: ReplaySession): bool =
  ## The tab's two ids are one number, which no tab of the window has held.
  int(tab.id) == tab.dapApi.sessionId and int(tab.id) notin everUsed

proc remember(tab: ReplaySession) =
  everUsed.incl int(tab.id)
  everUsed.incl tab.dapApi.sessionId

proc resetWindow() =
  ## Back to the one tab the window opened with; the ids already handed out
  ## stay used, as they do in a real window.
  data.sessions.setLen(1)
  data.activeSessionIndex = 0

proc eventFrame(sessionId: int; text: cstring): JsObject =
  js{"type": cstring"event", "event": cstring"ct/notification",
     "sessionId": sessionId,
     "body": js{"kind": 2, "time": 0, "text": text, "active": true,
                "seen": false, "timeoutId": 0, "hasTimeout": false,
                "isOperationStatus": false, "actions": newSeq[JsObject]()}}

proc receivesEvents(tab: ReplaySession): ref int =
  ## Count the `ct/notification` events delivered to `tab`'s `DapApi`.
  let count = new int
  tab.dapApi.on(CtNotification, proc(kind: CtEventKind, value: JsObject) =
    inc count[])
  count

proc requestsSent(): seq[JsObject] =
  for (channel, packet) in sentPackets:
    if channel == cstring"CODETRACER::dap-raw-message":
      result.add packet

scenario "open 0 and 1, close 1, press +: the new tab is not the closed tab":
  resetWindow()
  let second = openTab()
  remember(second)
  let closedId = second.dapApi.sessionId
  let closedKey = tabScopedKey(second, 0)
  closeTab(1)
  let third = openTab()
  ck third.isFresh
  ck third.dapApi.sessionId != closedId
  # An event the main process still tags for the closed tab (it was in
  # flight when the tab closed) reaches no tab — not the new one.
  let thirdEvents = receivesEvents(third)
  ck sessionDapApi(data, closedId).isNil
  deliverDapEvent(data, eventFrame(closedId, cstring"for the closed tab"))
  ck thirdEvents[] == 0
  # The new tab's per-tab table keys are its own, not the closed tab's.
  ck tabScopedKey(third, 0) != closedKey
  remember(third)

scenario "open 0, 1 and 2, close 1, press +: the new tab is not the third tab":
  resetWindow()
  let second = openTab()
  remember(second)
  let third = openTab()
  remember(third)
  closeTab(1)
  let fourth = openTab()
  ck fourth.isFresh
  ck fourth.dapApi.sessionId != third.dapApi.sessionId
  ck int(fourth.id) != int(third.id)
  # Each open tab receives its own events and only its own.
  let thirdEvents = receivesEvents(third)
  let fourthEvents = receivesEvents(fourth)
  deliverDapEvent(data, eventFrame(third.dapApi.sessionId, cstring"third"))
  ck thirdEvents[] == 1
  ck fourthEvents[] == 0
  deliverDapEvent(data, eventFrame(fourth.dapApi.sessionId, cstring"fourth"))
  ck thirdEvents[] == 1
  ck fourthEvents[] == 1
  remember(fourth)

scenario "close the last tab, then the first after tab 0, many times over":
  # Every way of freeing a number: the newest tab, the oldest after tab 0,
  # and all but tab 0. No new tab ever takes a number already handed out.
  resetWindow()
  var fresh = true
  for round in 0 ..< 4:
    for _ in 0 ..< 3:
      let tab = openTab()
      fresh = fresh and tab.isFresh
      remember(tab)
    closeTab(data.sessions.len - 1)
    closeTab(1)
  ck fresh
  resetWindow()
  let after = openTab()
  ck after.isFresh
  remember(after)

scenario "the window's first tab keeps id 0, and no later tab takes it":
  resetWindow()
  ck int(data.sessions[0].id) == 0
  ck data.sessions[0].dapApi.sessionId == 0
  let later = openTab()
  ck int(later.id) != 0 and later.dapApi.sessionId != 0
  remember(later)

scenario "a tab's requests name its replay beside its own id":
  resetWindow()
  let tab = openTab()
  remember(tab)
  # A tab with no replay yet (a "+" tab on the welcome screen) names none:
  # the main process must not pick one for it.
  sentPackets = @[]
  tab.dapApi.sendCtRequest(CtLoadLocals, js{})
  var reqs = requestsSent()
  ck reqs.len == 1
  if reqs.len == 1:
    ck reqs[0]["sessionId"].to(int) == tab.dapApi.sessionId
    ck reqs[0]["replayId"].isUndefined
  # The Backend Manager answered a replay for it whose number is not the
  # tab's (`dap-replay-selected`): its requests name that replay.
  let replay = tab.dapApi.sessionId + 7
  tab.assignReplay(replay)
  ck tab.replayId == replay
  ck tab.dapApi.replayOf == replay
  sentPackets = @[]
  tab.dapApi.sendCtRequest(CtLoadLocals, js{})
  reqs = requestsSent()
  ck reqs.len == 1
  if reqs.len == 1:
    ck reqs[0]["sessionId"].to(int) == tab.dapApi.sessionId
    ck reqs[0]["replayId"].to(int) == replay
  # Stop (`stop_command`) ends the replay: the tab names none again.
  tab.assignReplay(-1)
  ck tab.replayId == -1
  ck tab.dapApi.replayOf == -1
  sentPackets = @[]
  tab.dapApi.sendCtRequest(CtLoadLocals, js{})
  reqs = requestsSent()
  ck reqs.len == 1
  if reqs.len == 1:
    ck reqs[0]["replayId"].isUndefined

if checks != ExpectedChecks:
  echo "  [FAILED] every check ran: expected ", ExpectedChecks, ", ran ", checks
  inc failedChecks
echo "CHECKS: ", checks
if failedChecks > 0:
  {.emit: "process.exitCode = 1;".}
