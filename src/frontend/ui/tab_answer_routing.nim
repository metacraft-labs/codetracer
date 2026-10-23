## WHICH TAB AN ANSWER FROM THE MAIN PROCESS IS FOR.
##
## The renderer names the asking tab on every request (`ui_js.stampAskingTab`)
## and the main process names it on the answer (`index/tab_answers.nim`).
## `deliverTabAnswer` gives each answer to that tab; `session_switch` delivers
## what waited for a tab when it is shown (`deliverPendingTabAnswers`).
## A module of its own so the routing rule can be imported — and tested —
## without the session switcher's import graph.

import std/jsffi
import ../types
import ../lib/logging

proc answerTabId(answer: JsObject): int =
  ## The `ReplaySession.id` an answer from the main process names in its
  ## `tab` field (`index/tab_answers.nim`), or -1 when it names none.
  if answer.isNil or answer.isUndefined or answer.isNull:
    return -1
  if jsTypeOf(answer) != cstring"object":
    return -1
  let tab = answer[cstring"tab"]
  if tab.isNil or tab.isUndefined or tab.isNull or
      jsTypeOf(tab) != cstring"number":
    return -1
  tab.to(int)

proc deliverTabAnswer*(data: Data; message: cstring; answer: JsObject;
                       deliver: proc()) =
  ## Run `deliver` — the handler of `message`, applied to `answer` — for the
  ## tab the answer is for (`GUI/Multi-Window-Tab-Management.md` §Tab
  ## Behavior rules 1 and 2: each tab is its own session, and shows its own
  ## data):
  ##
  ## * an answer that names no tab is for the tab on screen: delivered now,
  ##   as every answer was while the window had one tab;
  ## * an answer for the tab on screen: delivered now;
  ## * an answer for a hidden tab: queued on that tab
  ##   (`ReplaySession.pendingTabAnswers`), in arrival order, and delivered
  ##   when the tab is next shown (`session_switch.switchSession`). Not delivered into it at
  ##   once, because a handler writes through `Data`'s active-session
  ##   forwarding and draws the window's one set of chrome (status bar,
  ##   topbar, menus): run for a hidden tab, it would write the shown tab's
  ##   state and draw the hidden tab's over the shown one. Queued, it runs
  ##   under exactly the conditions it was written for, and in order — a
  ##   load's `init`, `filesystem-loaded` and `trace-loaded` keep their
  ##   sequence;
  ## * an answer for a tab that has closed: dropped, and logged. Delivering
  ##   it to whatever tab is shown is the defect this routing removes.
  let tab = answerTabId(answer)
  if tab < 0 or data.sessions.len == 0:
    deliver()
    return
  for session in data.sessions:
    if session.isNil or int(session.id) != tab:
      continue
    if session == data.activeSession:
      deliver()
    else:
      session.pendingTabAnswers.add(PendingTabAnswer(message: message, deliver: deliver))
    return
  cwarn "tab answers: dropped " & $message & " for tab " & $tab &
    ", which is no longer open"

proc deliverPendingTabAnswers*(session: ReplaySession) =
  ## Run the answers that arrived for `session` while it was hidden, now that
  ## it is the tab on screen (`deliverTabAnswer`). One that raises does not
  ## stop the rest. Taken off the queue first, so an answer that queues
  ## another (for a tab no longer shown) is not run twice.
  if session.isNil or session.pendingTabAnswers.len == 0:
    return
  let pending = session.pendingTabAnswers
  session.pendingTabAnswers = @[]
  for answer in pending:
    try:
      answer.deliver()
    except:
      cerror "tab answers: the queued " & $answer.message & " for tab " &
        $int(session.id) & " failed: " & getCurrentExceptionMsg()
