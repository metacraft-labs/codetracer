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

proc markRecordFinished(ws: var Workspace) =
  ## The `CODETRACER::successful-record` / `CODETRACER::failed-record` round
  ## trip: the recorder we launched has reported back.
  ws.apply noteRecordFinished(ws.queue)

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

suite "Re-record is single-flight":
  ## Issue #603, second defect.  The reporter's screenshots show a *stack* of
  ## identical notifications — "Building/recording a new trace…" on 2026-07-22,
  ## "ct record process started" on 2026-08-17 — and the stack is three deep
  ## because `NOTIFICATION_LIMIT` in `src/frontend/ui/status.nim` renders at
  ## most three toasts, not because exactly three requests were made.  Both of
  ## those messages are emitted exactly once per recording launch, so a stack
  ## of them means the recorder was launched more than once for what the user
  ## experienced as one action.
  ##
  ## Concurrent `ct record` runs share one project build directory and one
  ## `data.recordProcess` slot in the index, so they fight and report each
  ## other's failures — which is the "program won't start" the issue is about.
  ## A re-record request must therefore be single-flight: while one is queued
  ## or running, another must be refused *visibly*, never silently stacked.
  ##
  ## What this suite CANNOT see, stated plainly so nobody reads it as more
  ## evidence than it is: `Workspace` threads one persistent `ReRecordQueue`
  ## through every simulated press, because that is what the fixed
  ## `renderer.reRecordCurrent` does.  The bug also had a renderer half — it
  ## allocated a *fresh* `ReRecordQueueRef()` per press, so every press reached
  ## this model with a pristine, idle queue and the guard below was
  ## unreachable.  Restoring that line would leave all 21 cases here green.
  ## The renderer, `ui_js` and index halves are covered by the Playwright case
  ## "a burst of Ctrl+R presses starts one recorder and says why" in
  ## `file_conflicts.spec.ts`, and by nothing else.

  test "a burst of Ctrl+R presses launches exactly one recording":
    # Key auto-repeat, or an impatient second press during a slow build, is
    # the whole repro: nothing in the model remembered that a recording was
    # already under way, so every press dispatched another one.
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: false, editorReady: true)])
    ws.pressCtrlR()
    ws.pressCtrlR()
    ws.pressCtrlR()

    check ws.count(newRecordMsg) == 1
    check ws.errors.len == 0
    check ws.warnings.len == 2

  test "a second press while saves are in flight does not re-send them":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    check ws.count(saveFileMsg) == 2

    ws.pressCtrlR()
    # Re-sending the saves both doubles the disk writes (waking the file
    # watchers again) and resets `savesInFlight` under the replies already
    # on their way back.
    check ws.count(saveFileMsg) == 2
    check ws.count(newRecordMsg) == 0
    check ws.warnings.len == 1
    check ws.queue.active

  test "a press while the recording runs is refused, not stacked":
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.markSaved("/w/main.py")
    ws.markSaved("/w/lib.py")
    check ws.count(newRecordMsg) == 1

    # The recorder has not reported back yet.  A second launch here is what
    # produced the reporter's stacked notifications.
    ws.pressCtrlR()
    check ws.count(newRecordMsg) == 1
    check ws.warnings.len == 1
    check ws.errors.len == 0

  test "the refusal names the phase the request is actually in":
    # "Still saving" and "already recording" are different situations and the
    # user can act on the difference; one generic message cannot be acted on.
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.pressCtrlR()
    check ws.warnings == @[reRecordAlreadySavingMessage]

    ws.markSaved("/w/main.py")
    ws.markSaved("/w/lib.py")
    ws.pressCtrlR()
    check ws.warnings == @[reRecordAlreadySavingMessage,
                           reRecordAlreadyRunningMessage]

  test "the gate reopens once the recorder reports back":
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: false, editorReady: true)])
    ws.pressCtrlR()
    check ws.count(newRecordMsg) == 1

    ws.markRecordFinished()
    ws.pressCtrlR()
    check ws.count(newRecordMsg) == 2
    check ws.warnings.len == 0
    check ws.errors.len == 0

  test "a released gate arms the save queue again from scratch":
    # The second cycle, and the one that goes back through the saves: after a
    # release, `savesInFlight` / `failedSaves` have to start clean or the next
    # request drains against stale counters.
    #
    # Note what this can and cannot see.  The model has one release entry
    # point, so it cannot tell `failed-record` from `successful-record` — that
    # distinction lives in `ui_js.onFailedRecord` / `onSuccessfulRecord`, which
    # both call `data.noteReRecordFinished()` and are covered by no headless
    # test.  What is asserted here is the release itself, and that it leaves a
    # queue the next request can re-arm.
    var ws = Workspace(tabs: @[
      SaveTarget(name: "/w/main.py", changed: true, editorReady: true)])
    ws.pressCtrlR()
    ws.markSaved("/w/main.py")
    check ws.count(newRecordMsg) == 1

    ws.markRecordFinished()   # `successful-record` or `failed-record`
    ws.tabs[0].changed = true
    ws.pressCtrlR()
    check ws.count(saveFileMsg) == 2
    ws.markSaved("/w/main.py")
    check ws.count(newRecordMsg) == 2

  test "an abandoned save queue does not hold the gate shut":
    # This one passes against the unmodified model too, by construction: it
    # guards the *fix* rather than reproducing the bug.  The latch must be
    # taken only where a recorder was actually launched, so a request the
    # watchdog abandoned before any launch cannot lock the feature out.
    var ws = twoDirtyTabs()
    ws.pressCtrlR()
    ws.apply abandonReRecord(ws.queue, reRecordTimedOutMessage)
    check ws.count(newRecordMsg) == 0

    # Nothing was launched, so nothing has to report back before the next
    # attempt is allowed.
    for tab in ws.tabs.mitems:
      tab.changed = false
    ws.pressCtrlR()
    check ws.count(newRecordMsg) == 1

# ───────────────────────── issue #747: the launch itself ────────────────────
#
# Everything above stops at `rreDispatchRecord`.  #747 is what happens next:
# the renderer derives `args[0]`, `options.cwd` and `filename` from the loaded
# recording's metadata, and the main process spawns `ct record` with them.
# That spawn answered `ENOENT` and the reporter had no way to tell which of
# three unrelated causes produced it.
#
# These cases drive the same two production funcs the renderer and the main
# process call — `planRecordLaunch` and the `classifyRecordLaunch` family in
# `src/frontend/file_conflicts.nim` — with the shapes real `trace_index.db`
# rows actually hold.

const
  # A Noir recording, exactly as `trace_index.db` stores one: `program` is the
  # PROJECT NAME and `workdir` is the project root.
  noirTrace = RecordLaunchInputs(
    program: "noir_example",
    workdir: "/w/test-programs/noir_example",
    locationPath: "/w/test-programs/noir_example/src/main.nr",
    noirProject: true)
  # A Python recording: `program` is an absolute source path.
  pythonTrace = RecordLaunchInputs(
    program: "/w/demo/main.py",
    workdir: "/w/demo",
    locationPath: "/w/demo/main.py",
    noirProject: false)

suite "Re-record launch derivation (#747)":
  test "a bare program name is anchored to the recorded workdir":
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: "demo",
      workdir: "/w/demo",
      locationPath: "/w/demo/main.py",
      noirProject: false))
    # Without the workdir this is a name no other process can resolve.
    check plan.programArg == "/w/demo/demo"
    check plan.cwd == "/w/demo"
    check plan.filename == "/w/demo/main.py"

  test "an empty workdir leaves the bare name alone and requests no cwd":
    # There is nothing to anchor to, and — this is the part that matters — an
    # empty `cwd` is what makes the renderer omit `options.cwd` entirely
    # (`renderer.launchReRecord` sets the key only when this is non-empty).
    # Putting the empty string in that field instead would make the launch
    # depend on which node API runs it: async `spawn` tolerates `{cwd: ""}` and
    # inherits, while `spawnSync` answers `ENOENT` for the same input
    # (measured, node v20.20.0 / macOS 15 arm64).
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: "demo",
      workdir: "",
      locationPath: "/w/demo/main.py",
      noirProject: false))
    check plan.programArg == "demo"
    check plan.cwd == ""

  test "an empty workdir on a Noir recording does not erase the program":
    # The Noir branch replaces the program with the workdir.  With no workdir
    # there is nothing to replace it WITH, and swapping in "" would send
    # `ct record ""`.
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: "noir_example",
      workdir: "",
      locationPath: "",
      noirProject: true))
    check plan.programArg == "noir_example"
    check plan.cwd == ""

  test "an empty debugger location leaves the filename empty, not the program":
    # `filename` picks the BUILD target in the main process and is allowed to
    # be empty (it falls back to `args[0]`).  What it must never do is silently
    # become the program, which would make the two fields disagree.
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: "/w/demo/main.py",
      workdir: "/w/demo",
      locationPath: "",
      noirProject: false))
    check plan.filename == ""
    check plan.programArg == "/w/demo/main.py"

  test "a Noir recording re-records from its project root":
    let plan = planRecordLaunch(noirTrace)
    check plan.programArg == "/w/test-programs/noir_example"
    check plan.cwd == "/w/test-programs/noir_example"

  test "an absolute program is passed through untouched":
    let plan = planRecordLaunch(pythonTrace)
    check plan.programArg == "/w/demo/main.py"
    check plan.cwd == "/w/demo"

  test "a Windows program path is not re-rooted under the workdir":
    # `C:\demo\main.py` contains no forward slash and does not start with "/",
    # so the old test read it as a bare name and produced
    # `C:\w\demo/C:\demo\main.py`.
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: r"C:\demo\main.py",
      workdir: r"C:\w\demo",
      locationPath: r"C:\demo\main.py",
      noirProject: false))
    check plan.programArg == r"C:\demo\main.py"

  test "a bare name under a Windows workdir keeps the workdir's separator":
    let plan = planRecordLaunch(RecordLaunchInputs(
      program: "demo",
      workdir: r"C:\w\demo",
      locationPath: "",
      noirProject: false))
    check plan.programArg == r"C:\w\demo\demo"

suite "Re-record launch preconditions (#747)":
  # `child_process.spawn` answers ENOENT for a missing executable, a missing
  # `options.cwd` and an unresolvable bare command name alike, and puts the
  # EXECUTABLE in `error.path` in all three (measured on node v20.20.0).  These
  # are the questions the main process now asks before it spawns.
  proc healthyFacts(): RecordLaunchFacts =
    RecordLaunchFacts(
      recorder: "/opt/ct/bin/ct",
      recorderResolved: "/opt/ct/bin/ct",
      recordTarget: "/w/demo/main.py",
      requestedCwd: "/w/demo",
      requestedCwdUsable: true,
      fallbackCwd: "")

  test "a launch with every precondition met is not refused":
    let facts = healthyFacts()
    check classifyRecordLaunch(facts) == rldNone
    check recordLaunchCwd(facts) == "/w/demo"
    check recordLaunchCwdWarning(facts) == ""

  test "an unresolvable recorder is named, and names the PATH when it is bare":
    var facts = healthyFacts()
    facts.recorder = "ct"
    facts.recorderResolved = ""
    check classifyRecordLaunch(facts) == rldRecorderMissing
    let message = recordLaunchRefusal(facts, rldRecorderMissing)
    check message.contains("ct")
    check message.contains("PATH")
    # The old behaviour said "ENOENT" and nothing else.
    check not message.contains("ENOENT")

  test "a missing recorder PATH names the path when the recorder is one":
    var facts = healthyFacts()
    facts.recorderResolved = ""
    let message = recordLaunchRefusal(facts, rldRecorderMissing)
    check message.contains("/opt/ct/bin/ct")
    check not message.contains("PATH")

  test "nothing to record is refused before the spawn, by name":
    var facts = healthyFacts()
    facts.recordTarget = ""
    check classifyRecordLaunch(facts) == rldNoRecordTarget
    check recordLaunchRefusal(facts, rldNoRecordTarget).len > 0

  test "the recorded workdir is checked, and a dead one does not fail the launch":
    # THE #747 CASE.  `Trace.workdir` says where the program ran when it was
    # recorded; the project can have moved, the recording can have come from
    # another machine, or it can have been made in a temp directory that is
    # long gone.  Handing that to `spawn` unchecked is the ENOENT.
    var facts = healthyFacts()
    facts.requestedCwd = "/gone/demo"
    facts.requestedCwdUsable = false
    facts.fallbackCwd = "/w/demo"
    # Not a refusal: the record target is absolute, so the launch can proceed.
    check classifyRecordLaunch(facts) == rldNone
    check recordLaunchCwd(facts) == "/w/demo"
    let warning = recordLaunchCwdWarning(facts)
    check warning.contains("/gone/demo")
    check warning.contains("/w/demo")
    check warning.contains("no longer exists")

  test "a dead workdir with no replacement inherits rather than dying":
    var facts = healthyFacts()
    facts.requestedCwd = "/gone/demo"
    facts.requestedCwdUsable = false
    facts.fallbackCwd = ""
    check classifyRecordLaunch(facts) == rldNone
    # "" means "send no `options.cwd` at all", which is what makes the child
    # inherit instead of `chdir`-ing into a directory that is not there.
    check recordLaunchCwd(facts) == ""
    check recordLaunchCwdWarning(facts).contains("/gone/demo")

  test "a recording that asked for no workdir is not warned about":
    var facts = healthyFacts()
    facts.requestedCwd = ""
    facts.requestedCwdUsable = false
    check recordLaunchCwd(facts) == ""
    check recordLaunchCwdWarning(facts) == ""
