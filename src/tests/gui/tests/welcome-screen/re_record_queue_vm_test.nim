## Headless drain test for the Ctrl+R "save everything, then re-record" queue
## (issue #603 — re-recording never started the program after the
## "File changed on disk" dialog resolved).
##
## Layer: pure ViewModel / decision model.  The state machine under test is the
## production one in `src/frontend/file_conflicts.nim`; the only thing this file
## adds is a workspace fixture plus an IPC spy that records the messages the
## renderer would send, so the *observable* contract — how many
## `CODETRACER::save-file` messages go out, and whether exactly one
## `CODETRACER::new-record` ever follows — is asserted directly.
##
## Mocking justification (per the workspace policy): nothing is mocked.  The
## "spy" is not a mock of a collaborator — it is the effect list the model
## already returns by value, rendered as message names.  There is no
## filesystem, no Electron and no Monaco in this test because the model has no
## dependency on any of them; that is the point of extracting it.

import std/[strutils, unittest]

import file_conflicts

type
  Workspace = object
    ## Stands in for `data.services.editor.open`.
    tabs: seq[SaveTarget]
    queue: ReRecordQueue
    sent: seq[string]          ## the IPC spy: message names, in order
    errors: seq[string]
    warnings: seq[string]

const
  saveFileMsg = "CODETRACER::save-file"
  saveUntitledMsg = "CODETRACER::save-untitled"
  newRecordMsg = "CODETRACER::new-record"

proc apply(ws: var Workspace; effects: seq[ReRecordEffect]) =
  ## The renderer adapter, in miniature: perform the effects the model asked
  ## for.  `renderer.applyReRecordEffects` does exactly this against real IPC.
  for effect in effects:
    case effect.kind
    of rreSaveFile:
      ws.sent.add saveFileMsg & " " & effect.target
    of rreSaveUntitled:
      ws.sent.add saveUntitledMsg & " " & effect.target
    of rreDispatchRecord:
      ws.sent.add newRecordMsg
    of rreError:
      ws.errors.add effect.message
    of rreWarn:
      ws.warnings.add effect.message

proc count(ws: Workspace; message: string): int =
  for sent in ws.sent:
    if sent == message or sent.startsWith(message & " "):
      inc result

proc pressCtrlR(ws: var Workspace; projectOnly = false) =
  ws.apply requestReRecord(ws.queue, ws.tabs, projectOnly)

proc markSaved(ws: var Workspace; name: string) =
  ## The `CODETRACER::saved-file` round-trip: the buffer is clean again.
  for tab in ws.tabs.mitems:
    if tab.name == name:
      tab.changed = false
  ws.apply noteSaveOutcome(ws.queue, ws.tabs, failed = false)

proc markSaveFailed(ws: var Workspace; name: string) =
  ## The `CODETRACER::save-file-error` round-trip: the buffer stays dirty.
  ws.apply noteSaveOutcome(ws.queue, ws.tabs, failed = true)

proc answerDialog(ws: var Workspace; action: FileConflictAction;
                  path: string) =
  if action == fcaDiscardMemory:
    for tab in ws.tabs.mitems:
      if tab.name == path:
        tab.changed = false
  ws.apply applyConflictAction(ws.queue, action, ws.tabs, path)

proc twoDirtyTabs(): Workspace =
  Workspace(tabs: @[
    SaveTarget(name: "/w/main.py", changed: true, editorReady: true),
    SaveTarget(name: "/w/lib.py", changed: true, editorReady: true),
    # Always present in `services.editor.open`, never has a Monaco editor.
    SaveTarget(name: "/w/main.py:main-0", changed: false, editorReady: false)])

suite "Re-record queue drain":
  test "two dirty buffers save first and record only after both replies":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()

    check ws.count(saveFileMsg) == 2
    check ws.count(newRecordMsg) == 0
    check ws.queue.active
    check ws.errors.len == 0

    ws.markSaved("/w/main.py")
    check ws.count(newRecordMsg) == 0
    check ws.queue.active

    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1
    check not ws.queue.active
    check ws.errors.len == 0
    check ws.warnings.len == 0

  test "a clean workspace records straight away":
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: false, editorReady: true)])
    ws.pressCtrlR()

    check ws.count(saveFileMsg) == 0
    check ws.count(newRecordMsg) == 1
    check not ws.queue.active

  test "the recorder is launched at most once":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.markSaved("/w/main.py")
    ws.markSaved("/w/lib.py")
    # A late duplicate reply (both watchers can answer for the same write)
    # must not launch a second recording.
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1

  test "projectOnly survives the queue":
    var ws = twoDirtyTabs()
    ws.pressCtrlR(projectOnly = true)
    check ws.queue.projectOnly
    ws.markSaved("/w/main.py")
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1

suite "Re-record queue never hangs":
  test "an editor-less dirty buffer aborts loudly instead of going quiet":
    # The #603 repro: `open` holds a dirty entry with no mounted Monaco
    # editor.  Previously `saveFiles` threw on it, after the queue was armed
    # and before anything was sent — no save, no drain, no message.
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/pending.py", changed: true, editorReady: false)])
    ws.pressCtrlR()

    check ws.count(saveFileMsg) == 0
    check ws.count(newRecordMsg) == 0
    check ws.errors.len == 1
    check ws.errors[0] == reRecordUnsavableMessage
    check not ws.queue.active

  test "a save that only partly dispatches still aborts":
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: true, editorReady: true),
      SaveTarget(name: "/w/pending.py", changed: true, editorReady: false)])
    ws.pressCtrlR()

    check ws.count(saveFileMsg) == 1
    check ws.count(newRecordMsg) == 0
    check ws.queue.active

    # `/w/pending.py` can never be saved, so once the one real save comes
    # back the request is unreachable and must fail rather than wait.
    ws.markSaved("/w/main.py")
    check ws.count(newRecordMsg) == 0
    check ws.errors.len == 1
    check not ws.queue.active

  test "a failed save aborts with an error and clears the queue":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    check ws.count(saveFileMsg) == 2

    ws.markSaveFailed("/w/main.py")
    check ws.count(newRecordMsg) == 0
    check ws.errors.len == 1
    check ws.errors[0] == reRecordSaveFailedMessage
    check not ws.queue.active

    # The second reply arrives after the abort and must be inert.
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 0
    check ws.errors.len == 1

  test "the watchdog abandons a request nothing ever answered":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.apply abandonReRecord(ws.queue, reRecordTimedOutMessage)

    check ws.count(newRecordMsg) == 0
    check ws.errors == @[reRecordTimedOutMessage]
    check not ws.queue.active

suite "Re-record queue and the conflict dialog":
  test "keep editing cancels with a warning, not silence":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.answerDialog(fcaKeepEditing, "/w/main.py")

    check ws.count(newRecordMsg) == 0
    check ws.warnings.len == 1
    check "/w/main.py" in ws.warnings[0]
    check ws.errors.len == 0
    check not ws.queue.active

  test "opening the three-way merge cancels with a warning":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.answerDialog(fcaOpenMerge, "/w/main.py")

    check ws.count(newRecordMsg) == 0
    check ws.warnings.len == 1
    check not ws.queue.active

  test "saving the in-memory version saves every dirty buffer":
    # The dialog used to save only the conflicting file while the gate
    # required zero dirty buffers, so a second dirty buffer kept it shut.
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    let savesBefore = ws.count(saveFileMsg)

    ws.answerDialog(fcaSaveMemory, "/w/main.py")
    check ws.count(saveFileMsg) == savesBefore + 2
    check ws.count(newRecordMsg) == 0

    ws.markSaved("/w/main.py")
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1
    check ws.errors.len == 0

  test "discarding the last dirty buffer records immediately":
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: true, editorReady: true)])
    ws.pressCtrlR()
    check ws.count(newRecordMsg) == 0

    ws.answerDialog(fcaDiscardMemory, "/w/main.py")
    check ws.count(newRecordMsg) == 1
    check not ws.queue.active

  test "discarding one buffer keeps waiting for the other's save":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.answerDialog(fcaDiscardMemory, "/w/main.py")

    check ws.count(newRecordMsg) == 0
    check ws.queue.active
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1

  test "the dialog outside a re-record only saves, it never records":
    var ws = twoDirtyTabs()
    ws.answerDialog(fcaSaveMemory, "/w/main.py")

    check ws.count(saveFileMsg) == 2
    check ws.count(newRecordMsg) == 0
    check ws.errors.len == 0
    check ws.warnings.len == 0
