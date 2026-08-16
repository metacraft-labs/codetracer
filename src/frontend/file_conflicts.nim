## Pure decision model for "the file changed underneath us" and for the
## save-then-re-record handshake that Ctrl+R starts.
##
## Everything here is deliberately free of JS/DOM/IPC dependencies so it can be
## compiled and exercised natively by
## `src/tests/gui/tests/welcome-screen/file_conflicts_vm_test.nim` and
## `src/tests/gui/tests/welcome-screen/re_record_queue_vm_test.nim`.  The
## renderer (`src/frontend/renderer.nim`) is a thin adapter: it converts its
## `services.editor.open` table into `SaveTarget`s, asks this module what to do
## and then performs the returned effects.  Keeping the decisions here is what
## makes the "never hang" invariants below testable at all — see issue #603,
## where the queue could be armed and then silently never drained.

type
  ExternalChangeDecision* = enum
    ecdReload
    ecdPrompt

  FileConflictAction* = enum
    fcaDiscardMemory
    fcaSaveMemory
    fcaOpenMerge
    fcaKeepEditing

  ReRecordGate* = enum
    ## What the re-record request should do *right now*.
    rrgDispatch      ## nothing is dirty: launch the recorder
    rrgWaitForSaves  ## saves are in flight; a completion event will re-ask
    rrgAbort         ## nothing will ever open the gate: fail loudly

  SaveTarget* = object
    ## A snapshot of one entry of `services.editor.open`.
    ##
    ## `editorReady` is the guard that #603 was missing: `open` also holds
    ## entries inserted by `tabLoad` before Monaco mounts, plus calltrace and
    ## instruction tabs keyed as `path:functionName-key` that never get an
    ## editor at all.  Reading `monacoEditor.getValue()` on one of those threw
    ## a `TypeError` out of `saveFiles` *after* the queue had been armed and
    ## *before* a single save was sent.
    name*: string
    changed*: bool
    untitled*: bool
    editorReady*: bool

  ReRecordEffectKind* = enum
    rreSaveFile        ## send `CODETRACER::save-file` for `target`
    rreSaveUntitled    ## send `CODETRACER::save-untitled` for `target`
    rreDispatchRecord  ## the gate opened: build/record a new trace
    rreError           ## show `message` as an error notification
    rreWarn            ## show `message` as a warning notification

  ReRecordEffect* = object
    kind*: ReRecordEffectKind
    target*: string   ## file name, for the save effects
    message*: string  ## user-facing text, for `rreError` / `rreWarn`

  ReRecordQueue* = object
    ## The state of a queued re-record request.
    ##
    ## `active` replaces the old "is `pendingReRecord` non-nil" test.  The
    ## distinction matters: a request that was abandoned must be observably
    ## different from one that completed, and previously both merely cleared
    ## the field.
    active*: bool
    projectOnly*: bool
    savesInFlight*: int
    failedSaves*: int

  ReRecordQueueRef* = ref ReRecordQueue

const
  reRecordUnsavableMessage* =
    "Could not save the modified files; re-recording aborted."
  reRecordSaveFailedMessage* =
    "Saving the modified files failed; re-recording aborted."
  reRecordStalledMessage* =
    "Some files are still unsaved and no save is in progress; " &
    "re-recording aborted."
  reRecordTimedOutMessage* =
    "Timed out waiting for the modified files to be saved; " &
    "re-recording aborted."

proc classifyExternalChange*(bufferChanged: bool): ExternalChangeDecision =
  if bufferChanged:
    ecdPrompt
  else:
    ecdReload

proc buildThreeWayMergeDocument*(path, base, ours, theirs: string): string =
  result = "CodeTracer three-way merge\n"
  result.add "Path: " & path & "\n\n"
  result.add "======= BASE: last synchronized version =======\n"
  result.add base
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"
  result.add "\n======= OURS: in-memory CodeTracer buffer =======\n"
  result.add ours
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"
  result.add "\n======= THEIRS: current disk version =======\n"
  result.add theirs
  if result.len == 0 or result[^1] != '\n':
    result.add "\n"

proc countDirty*(tabs: openArray[SaveTarget]): int =
  ## How many buffers still hold unsaved edits.
  for tab in tabs:
    if tab.changed:
      inc result

proc classifyReRecordRequest*(dirtyFiles: int): ReRecordGate =
  ## Decide what a freshly issued Ctrl+R should do.
  if dirtyFiles == 0:
    rrgDispatch
  else:
    rrgWaitForSaves

proc reRecordGateAfterSave*(dirtyFiles, failedSaves,
                            savesInFlight: int): ReRecordGate =
  ## Re-evaluate a queued request after a save round-trip (or right after the
  ## saves were dispatched).
  ##
  ## The two loud cases are the whole point:
  ##   * a failed save can never clear `changed`, so waiting is waiting forever;
  ##   * dirty buffers with nothing in flight are unreachable by waiting — this
  ##     is what `saveFiles` throwing before it sent anything used to produce.
  if failedSaves > 0:
    rrgAbort
  elif dirtyFiles == 0:
    rrgDispatch
  elif savesInFlight > 0:
    rrgWaitForSaves
  else:
    rrgAbort

proc reRecordGateAfterConflictAction*(action: FileConflictAction;
                                      dirtyFiles: int): ReRecordGate =
  ## Decide what a queued request should do once the user answered the
  ## "File changed on disk" dialog.  `dirtyFiles` must already reflect the
  ## action's local effect (a discarded buffer is no longer dirty).
  case action
  of fcaKeepEditing, fcaOpenMerge:
    # The user explicitly chose to keep unsaved work, so the gate can never
    # open.  Cancel the request instead of leaving it armed forever.
    rrgAbort
  of fcaDiscardMemory, fcaSaveMemory:
    if dirtyFiles == 0:
      rrgDispatch
    else:
      rrgWaitForSaves

proc saveEffects*(tabs: openArray[SaveTarget]; path: string = "";
                  saveAs: bool = false): seq[ReRecordEffect] =
  ## The set of save messages a `saveFiles(path, saveAs)` call should send.
  ##
  ## Filters, in order:
  ##   * `path` selects a single buffer when non-empty;
  ##   * a buffer with no mounted editor is skipped (see `SaveTarget`);
  ##   * only dirty / untitled buffers are written, unless this is a
  ##     "Save As".  Rewriting untouched files was both pointless and harmful:
  ##     every rewrite wakes the file watchers and can raise a conflict dialog
  ##     for CodeTracer's own write.
  for tab in tabs:
    if path.len > 0 and tab.name != path:
      continue
    if not tab.editorReady:
      continue
    if not (tab.changed or tab.untitled or saveAs):
      continue
    if tab.untitled:
      result.add ReRecordEffect(kind: rreSaveUntitled, target: tab.name)
    else:
      result.add ReRecordEffect(kind: rreSaveFile, target: tab.name)

proc settle(queue: var ReRecordQueue; gate: ReRecordGate;
            abortMessage: string; abortIsWarning = false): seq[ReRecordEffect] =
  ## Turn a gate decision into effects and update the queue accordingly.
  case gate
  of rrgDispatch:
    queue.active = false
    result.add ReRecordEffect(kind: rreDispatchRecord)
  of rrgWaitForSaves:
    discard
  of rrgAbort:
    queue.active = false
    result.add ReRecordEffect(
      kind: if abortIsWarning: rreWarn else: rreError,
      message: abortMessage)

proc requestReRecord*(queue: var ReRecordQueue; tabs: openArray[SaveTarget];
                      projectOnly: bool): seq[ReRecordEffect] =
  ## Start a re-record request.  Either dispatches immediately, or arms the
  ## queue and returns the saves that will eventually drain it.
  queue = ReRecordQueue(active: true, projectOnly: projectOnly)
  let dirty = countDirty(tabs)
  case classifyReRecordRequest(dirty)
  of rrgDispatch:
    result.add queue.settle(rrgDispatch, "")
  of rrgWaitForSaves:
    let saves = saveEffects(tabs)
    queue.savesInFlight = saves.len
    result.add saves
    # Never arm a queue nothing can drain.  When every dirty buffer was
    # skipped (no mounted editor) this is `rrgAbort` and the user is told,
    # instead of the UI going quiet forever.
    result.add queue.settle(
      reRecordGateAfterSave(dirty, 0, saves.len), reRecordUnsavableMessage)
  of rrgAbort:
    result.add queue.settle(rrgAbort, reRecordUnsavableMessage)

proc noteSaveOutcome*(queue: var ReRecordQueue; tabs: openArray[SaveTarget];
                      failed: bool): seq[ReRecordEffect] =
  ## Feed one `saved-file` / `save-file-error` reply into a queued request.
  ## `tabs` must already reflect the reply (a saved buffer is no longer dirty).
  if not queue.active:
    return
  if queue.savesInFlight > 0:
    dec queue.savesInFlight
  if failed:
    inc queue.failedSaves
  result = queue.settle(
    reRecordGateAfterSave(countDirty(tabs), queue.failedSaves,
                          queue.savesInFlight),
    reRecordSaveFailedMessage)

proc applyConflictAction*(queue: var ReRecordQueue; action: FileConflictAction;
                          tabs: openArray[SaveTarget];
                          path: string = ""): seq[ReRecordEffect] =
  ## Resolve the "File changed on disk" dialog.  `tabs` must already reflect
  ## the action's local effect on the conflicting buffer.
  ##
  ## `fcaSaveMemory` saves *every* dirty buffer, not just the conflicting one:
  ## the gate needs zero dirty buffers, so saving one of two left the request
  ## armed and unreachable.
  if action == fcaSaveMemory:
    let saves = saveEffects(tabs)
    result.add saves
    if queue.active:
      queue.savesInFlight = saves.len
      queue.failedSaves = 0
  if not queue.active:
    return
  let gate = reRecordGateAfterConflictAction(action, countDirty(tabs))
  if gate == rrgWaitForSaves and queue.savesInFlight == 0:
    # Dirty buffers, nothing in flight: unreachable by waiting.
    result.add queue.settle(rrgAbort, reRecordStalledMessage)
    return
  let cancelled =
    if path.len > 0:
      "Re-recording cancelled — " & path & " still has unsaved changes"
    else:
      "Re-recording cancelled — some files still have unsaved changes"
  result.add queue.settle(gate, cancelled, abortIsWarning = true)

proc abandonReRecord*(queue: var ReRecordQueue;
                      reason: string): seq[ReRecordEffect] =
  ## Give up on a queued request (watchdog expiry, trace teardown, ...).
  if not queue.active:
    return
  result = queue.settle(rrgAbort, reason)
