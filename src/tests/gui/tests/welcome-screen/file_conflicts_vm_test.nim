## Headless model tests for the file-conflict / re-record gate.
##
## No mocks: `src/frontend/file_conflicts.nim` is the production decision
## model the renderer calls into, compiled natively here.
import std/[strutils, unittest]

import file_conflicts

suite "External file change conflict model":
  test "clean buffers reload automatically":
    check classifyExternalChange(bufferChanged = false) == ecdReload

  test "dirty buffers prompt before reload":
    check classifyExternalChange(bufferChanged = true) == ecdPrompt

  test "three-way merge document contains all sides":
    let document = buildThreeWayMergeDocument(
      "/workspace/main.nim",
      "let value = 1",
      "let value = 2",
      "let value = 3")

    check "BASE: last synchronized version" in document
    check "OURS: in-memory CodeTracer buffer" in document
    check "THEIRS: current disk version" in document
    check "let value = 1" in document
    check "let value = 2" in document
    check "let value = 3" in document

suite "Re-record gate":
  test "a clean workspace re-records immediately":
    check classifyReRecordRequest(0) == rrgDispatch

  test "dirty buffers wait for their saves":
    check classifyReRecordRequest(2) == rrgWaitForSaves

  test "a save still in flight keeps the request queued":
    check reRecordGateAfterSave(dirtyFiles = 1, failedSaves = 0,
                                savesInFlight = 1) == rrgWaitForSaves

  test "the last save opens the gate":
    check reRecordGateAfterSave(dirtyFiles = 0, failedSaves = 0,
                                savesInFlight = 0) == rrgDispatch

  test "a failed save aborts loudly instead of waiting forever":
    # #603: `save-file-error` had no subscriber at all, so a failed write left
    # the buffer dirty and the request armed with nothing left to drain it.
    check reRecordGateAfterSave(dirtyFiles = 1, failedSaves = 1,
                                savesInFlight = 0) == rrgAbort

  test "dirty buffers with nothing in flight are unreachable by waiting":
    # #603 primary: `saveFiles` threw on a tab with no Monaco editor *after*
    # the queue was armed and *before* any save was sent.  Queue set, no save,
    # no drain, no error.  This is that state, and it must abort.
    check reRecordGateAfterSave(dirtyFiles = 2, failedSaves = 0,
                                savesInFlight = 0) == rrgAbort

  test "a failed save aborts even while other saves are in flight":
    check reRecordGateAfterSave(dirtyFiles = 2, failedSaves = 1,
                                savesInFlight = 1) == rrgAbort

suite "Re-record gate after the conflict dialog":
  test "keep editing cancels the request":
    check reRecordGateAfterConflictAction(fcaKeepEditing, 1) == rrgAbort

  test "opening the three-way merge cancels the request":
    check reRecordGateAfterConflictAction(fcaOpenMerge, 1) == rrgAbort

  test "keep editing cancels even when no buffer is left dirty":
    check reRecordGateAfterConflictAction(fcaKeepEditing, 0) == rrgAbort

  test "saving the in-memory version waits for every dirty buffer":
    check reRecordGateAfterConflictAction(fcaSaveMemory, 2) == rrgWaitForSaves

  test "discarding the buffer re-records once nothing is dirty":
    check reRecordGateAfterConflictAction(fcaDiscardMemory, 0) == rrgDispatch

  test "discarding one of two buffers still waits":
    check reRecordGateAfterConflictAction(fcaDiscardMemory, 1) ==
      rrgWaitForSaves

suite "Save target selection":
  let tabs = @[
    SaveTarget(name: "/w/main.py", changed: true, editorReady: true),
    SaveTarget(name: "/w/lib.py", changed: false, editorReady: true),
    # A calltrace tab: keyed `path:functionName-key`, never gets an editor.
    SaveTarget(name: "/w/main.py:main-0", changed: false, editorReady: false),
    # A tab inserted by `tabLoad` before Monaco mounted.
    SaveTarget(name: "/w/pending.py", changed: true, editorReady: false),
    SaveTarget(name: "untitled-1", changed: false, untitled: true,
               editorReady: true)]

  test "only dirty and untitled buffers with a mounted editor are saved":
    let effects = saveEffects(tabs)
    check effects.len == 2
    check effects[0] == ReRecordEffect(kind: rreSaveFile, target: "/w/main.py")
    check effects[1] ==
      ReRecordEffect(kind: rreSaveUntitled, target: "untitled-1")

  test "a path filter selects a single buffer":
    let effects = saveEffects(tabs, path = "/w/main.py")
    check effects.len == 1
    check effects[0].target == "/w/main.py"

  test "an editor-less buffer is never saved, even by path":
    check saveEffects(tabs, path = "/w/pending.py").len == 0
    check saveEffects(tabs, path = "/w/main.py:main-0").len == 0

  test "save-as writes clean buffers too":
    let effects = saveEffects(tabs, path = "/w/lib.py", saveAs = true)
    check effects.len == 1
    check effects[0] == ReRecordEffect(kind: rreSaveFile, target: "/w/lib.py")

  test "counting dirty buffers ignores clean ones":
    check countDirty(tabs) == 2
