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

import std/strutils

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

  BufferProvenance* = object
    ## What the buffer a save was read from can prove about ITSELF.
    ##
    ## Reported: *"when I enter a debug sesion and hit the Stop button, the
    ## contents of some files become empty. What's worse is that this seems to
    ## be persisted even after I refresh the tab."*
    ##
    ## A save reads `tab.monacoEditor.getValue()`. If the instance it reads is
    ## not the one the user typed into — a mode transition destroys the editor's
    ## GoldenLayout pane and another rebuilds it — then `getValue()` answers for
    ## a model that never held the file, and the answer is `""`. The save path
    ## cannot tell that from a user who selected everything and pressed Delete,
    ## so it wrote the empty string through to OPFS, and the next reload read it
    ## back. The work is gone and a refresh does not recover it.
    ##
    ## THE GUARD IS NOT A HEURISTIC ON LENGTH, because emptying a file is a
    ## legitimate thing to do and a rule that forbade it would be a different
    ## defect. It is provenance the wipe cannot forge: `editsSinceLoad` is the
    ## editor's own count of modifications to the model it is holding. A user
    ## who deleted the contents of a file made at least one edit to do it. A
    ## model that was constructed empty and never typed into has made none, and
    ## no arrangement of panes can give it one.
    ##
    ## `-1` means "the buffer could not be asked". Treated as unproven, so a
    ## caller that cannot supply provenance cannot truncate — a save path that
    ## has not been taught to answer this question must not be able to delete a
    ## user's file by omission.
    contentLength*: int
    editsSinceLoad*: int

  TruncationVerdict* = enum
    ## Whether a save may proceed.
    tvWrite            ## persist it
    tvRefuseUnproven   ## it would empty a file, and the buffer shows no edit
                       ## that could have emptied it

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
    ## The state of a re-record request, from Ctrl+R to the recorder's reply.
    ##
    ## `active` replaces the old "is `pendingReRecord` non-nil" test.  The
    ## distinction matters: a request that was abandoned must be observably
    ## different from one that completed, and previously both merely cleared
    ## the field.
    ##
    ## `recording` is the second half of that lifetime and the reason issue
    ## #603 survived its first fix.  Once the saves drained, the model forgot
    ## the request entirely, so the *next* Ctrl+R — a key auto-repeat, or an
    ## impatient second press during a slow build — saw an idle world and
    ## launched another recorder alongside the first.  Concurrent `ct record`
    ## runs share the project's build directory and the index's single
    ## `data.recordProcess` slot, so they fight and report each other's
    ## failures; the reporter saw a stack of identical notifications and a
    ## program that never started.
    active*: bool
    recording*: bool
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
  reRecordAlreadySavingMessage* =
    "A re-recording is already saving your changes; " &
    "the new request was ignored."
  reRecordAlreadyRunningMessage* =
    "A recording is already in progress; the new request was ignored."

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

const UneditedModelVersion* = 1
  ## Monaco's version id for a model nobody has modified. `ITextModel`
  ## documents `getVersionId()` as starting at 1 and increasing on every edit,
  ## so `<= 1` is "this buffer has never been changed since it was created".

func classifyWrite*(provenance: BufferProvenance): TruncationVerdict =
  ## May this content be written over whatever is stored for the file?
  ##
  ## TRUNCATION IS NOT A SAVE UNLESS SOMEONE TRUNCATED IT. The only refusal is
  ## an empty payload from a buffer that cannot show an edit — the state a
  ## rebuilt, never-typed-into editor is in, and the state a user who cleared a
  ## file can never be in.
  ##
  ## Everything else is written, including a deliberately emptied file. The rule
  ## is about the WRITER BEING UNABLE TO DISTINGUISH an intended empty from a
  ## wipe, and this is the fact that distinguishes them.
  when defined(ctSaveWritesAnything):
    # THE PRE-FIX BEHAVIOUR: whatever the buffer said, write it. Reachable only
    # by defining this symbol, which only the control-data run in
    # `truncation_guard_test.nim` does. Nothing in the product defines it.
    return tvWrite
  if provenance.contentLength > 0:
    return tvWrite
  if provenance.editsSinceLoad > UneditedModelVersion:
    # The buffer was modified after it was created. Whatever else happened, a
    # human or a command changed this model, so an empty result is a result.
    return tvWrite
  tvRefuseUnproven

func refusalSentence*(relativePath: string): string =
  ## What the user is told when a truncating save is refused.
  ##
  ## SAID ON THE SURFACE, not only in the console. A refusal the user cannot see
  ## is indistinguishable from a save that worked, and this one is refusing
  ## something they may believe they asked for — so it names the file, says what
  ## was declined, and says how to actually empty a file if that was the intent.
  "Refused to save an empty '" & relativePath & "': the editor holding it " &
  "has no record of anything being deleted, so this is a buffer that was " &
  "rebuilt empty rather than a file you cleared. Your stored copy is " &
  "unchanged. To empty this file, edit it in the editor and save again."

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
    # The request is not over when the recorder is launched — it is over when
    # the recorder answers.  Holding `recording` across that window is what
    # makes the request single-flight; `noteRecordFinished` releases it.
    queue.recording = true
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
  ##
  ## A request made while one is already in flight is **refused, out loud**.
  ## Silently starting a second one is issue #603's remaining defect: it
  ## doubles the saves (waking the file watchers for CodeTracer's own writes)
  ## and puts two recorders on the same build directory.  Saying so is also
  ## the only feedback the user gets during a long build, and the absence of
  ## any feedback is what provokes the extra press in the first place.
  if queue.recording:
    return @[ReRecordEffect(kind: rreWarn,
                            message: reRecordAlreadyRunningMessage)]
  if queue.active:
    return @[ReRecordEffect(kind: rreWarn,
                            message: reRecordAlreadySavingMessage)]
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

proc noteRecordFinished*(queue: var ReRecordQueue): seq[ReRecordEffect] =
  ## The recorder reported back (`successful-record` / `failed-record`).
  ##
  ## This is the only thing that reopens the gate for the next Ctrl+R, so
  ## every reachable exit of the index's record handler has to reach it —
  ## otherwise "single-flight" degrades into "one flight, ever".
  queue.recording = false

proc abandonReRecord*(queue: var ReRecordQueue;
                      reason: string): seq[ReRecordEffect] =
  ## Give up on a queued request (watchdog expiry, trace teardown, ...).
  ##
  ## Only the *save* half can be abandoned this way: once the recorder is
  ## running, the process — not a timer — decides when the request ends.
  if not queue.active:
    return
  result = queue.settle(rrgAbort, reason)

# ───────────────────────── launching the recorder ──────────────────────────
#
# Issue #747.  `rreDispatchRecord` ends in one `child_process.spawn` of the
# `ct` binary, and the reporter's whole symptom is that spawn answering
# `ENOENT`.  Node reports `ENOENT` for THREE different causes at that call and
# gives the caller nothing to tell them apart — measured on node v20.20.0,
# macOS 15 / arm64:
#
#   * the executable path does not exist;
#   * `options.cwd` names a directory that does not exist;
#   * the executable is a bare name that the *effective* `PATH` (which is
#     `options.env.PATH` whenever `options.env` is supplied) does not resolve.
#
# In all three the error object reads `code: "ENOENT"`, `syscall: "spawn <exe>"`
# and — this is the trap — `path: "<exe>"`, i.e. it names the EXECUTABLE even
# when the executable is fine and the cwd is what is missing.  So the reported
# message cannot be read as evidence about which one happened, and neither can
# the `error.path` field.
#
# The values that reach that spawn on a re-record are RECORDED METADATA:
# `Trace.workdir` and `Trace.env` describe the machine and the moment the
# recording was made, not this machine now.  Every other sender of
# `CODETRACER::new-record` supplies a working directory the user just picked in
# a file dialog, which is why plain recording works while re-recording does
# not.  The two funcs below are that whole decision, made explicit so it can be
# exercised without Electron:
#
#   * `planRecordLaunch` derives what the renderer asks for;
#   * `classifyRecordLaunch` / `recordLaunchCwd` / the two message funcs decide
#     what the main process actually does with it, and say what was missing by
#     name instead of letting `spawn` answer `ENOENT` for three questions.

type
  RecordLaunchInputs* = object
    ## What the renderer knows about the recording it is about to repeat.
    ##
    ## All four fields come from the live session: three off `Trace`, one off
    ## the debugger's current location.  Nothing here touches a filesystem —
    ## the renderer has no business stat-ing paths for a process the main
    ## process will spawn, and keeping the derivation pure is what lets
    ## `re_record_queue_vm_test.nim` drive it natively.
    program*: string
      ## `Trace.program`.  May be a bare name: the Noir recorder stores the
      ## project name, not a path.
    workdir*: string
      ## `Trace.workdir` — where the program ran WHEN IT WAS RECORDED.
    locationPath*: string
      ## `services.debugger.location.path`, the file the replay is stopped in.
    noirProject*: bool
      ## `Trace.lang == LangNoir`.  Noir re-records from the project root.

  RecordLaunchPlan* = object
    ## The `CODETRACER::new-record` payload, minus the parts that never vary.
    programArg*: string
      ## `args[0]`: what `ct record` is pointed at.
    cwd*: string
      ## The working directory the renderer REQUESTS.  Empty means "say
      ## nothing about it", which leaves the recorder in the main process's own
      ## directory — the same thing the welcome screen does when its work-dir
      ## field is blank.
    filename*: string
      ## The `filename` field, used by the main process to pick a build target.
      ## Empty is legal and means "use `args[0]`".

func looksLikeAPath*(path: string): bool =
  ## Does this string already name a location, or is it a bare name that only
  ## means something relative to some directory?
  ##
  ## Used to decide whether a program may be re-rooted under the recorded
  ## workdir.  The old test was `startsWith("/") or contains("/")`, which reads
  ## `C:\projects\demo.py` as a bare name and re-roots it into
  ## `<workdir>/C:\projects\demo.py`.  Windows is a supported host, so the
  ## backslash and the drive-letter form are both path shapes here.
  if path.len == 0:
    return false
  if path.contains('/') or path.contains('\\'):
    return true
  # `C:\x` is drive-absolute and `C:x` is drive-relative; either way the string
  # is anchored to a drive and re-rooting it produces nonsense.
  path.len >= 2 and path[1] == ':'

func joinUnder*(base, leaf: string): string =
  ## `base / leaf`, without dragging `std/os` into a module that also compiles
  ## for the browser renderer.  The separator follows `base` so a Windows
  ## workdir keeps its backslashes.
  if base.len == 0:
    return leaf
  if leaf.len == 0:
    return base
  let last = base[^1]
  if last == '/' or last == '\\':
    return base & leaf
  let sep = if base.contains('\\') and not base.contains('/'): '\\' else: '/'
  base & sep & leaf

func planRecordLaunch*(inputs: RecordLaunchInputs): RecordLaunchPlan =
  ## Turn the live session's facts into the three values a re-record sends.
  ##
  ## Extracted verbatim from `renderer.launchReRecord` (issue #747) apart from
  ## the `looksLikeAPath` correction noted above.  Two shapes it has to keep
  ## handling, both observed in real `trace_index.db` rows:
  ##
  ##   * `program` is an absolute source path and `workdir` is its directory —
  ##     the Python/Ruby/JavaScript recorders;
  ##   * `program` is a bare PROJECT NAME (`noir_example`) and `workdir` is the
  ##     project root — the Noir recorder.  `ct record` needs the root, so the
  ##     workdir replaces the program outright.
  result.programArg = inputs.program
  if inputs.noirProject and inputs.workdir.len > 0:
    # Noir metadata stores the project name; re-recording requires the project
    # root, which is the only place `Nargo.toml` can be found.
    result.programArg = inputs.workdir
  if inputs.workdir.len > 0 and result.programArg.len > 0 and
      not looksLikeAPath(result.programArg):
    # A bare name is meaningless to a process started somewhere else, so anchor
    # it to the directory the recording says it ran in.
    result.programArg = joinUnder(inputs.workdir, result.programArg)
  result.cwd = inputs.workdir
  result.filename = inputs.locationPath

type
  RecordLaunchDefect* = enum
    ## A precondition of the recorder spawn that does not hold.
    ##
    ## Deliberately NOT a list of everything that can go wrong — it is the list
    ## of things `spawn` would otherwise report as an indistinguishable
    ## `ENOENT`.  A missing working directory is absent because it does not
    ## have to be fatal: see `recordLaunchCwd`.
    rldNone
    rldNoRecordTarget    ## nothing was named to record
    rldRecorderMissing   ## the `ct` binary this process would spawn is not
                         ## reachable — either the path does not exist, or it
                         ## is a bare name and the effective `PATH` has no such
                         ## executable

  RecordLaunchFacts* = object
    ## What the main process observed about the launch it is about to make.
    ##
    ## The *observations* (does this path exist? does `PATH` resolve this name?)
    ## belong to the caller, which has `fs` and `process.env`; the *decision*
    ## belongs here, where a test can make every combination without a
    ## filesystem.
    recorder*: string
      ## The `ct` this process would spawn, as written.
    recorderResolved*: string
      ## Where it was actually found.  Empty means `spawn` will answer ENOENT
      ## for it, whatever `error.path` ends up saying.
    recordTarget*: string
      ## The first argument after `record` — what gets recorded.
    requestedCwd*: string
      ## `options.cwd` as the renderer asked for it (`Trace.workdir`).
    requestedCwdUsable*: bool
      ## Does `requestedCwd` exist on THIS machine, and is it a directory?
    fallbackCwd*: string
      ## An existing directory to use when the requested one is gone — in
      ## practice the directory holding `recordTarget`.  Empty means there is
      ## none and the recorder should simply inherit.

func classifyRecordLaunch*(facts: RecordLaunchFacts): RecordLaunchDefect =
  ## Which precondition, if any, is broken.
  if facts.recordTarget.len == 0:
    return rldNoRecordTarget
  if facts.recorderResolved.len == 0:
    return rldRecorderMissing
  rldNone

func recordLaunchCwd*(facts: RecordLaunchFacts): string =
  ## The working directory to actually pass to `spawn`.  Empty means "pass
  ## none", i.e. inherit the main process's directory.
  ##
  ## A recorded workdir that no longer exists must NOT fail the launch. The
  ## record target is an absolute path (or a project root) by the time it gets
  ## here, so `ct record <target>` does not need the directory the program
  ## happened to run in two weeks ago on another machine — and refusing would
  ## turn a recoverable situation into issue #747's dead end.
  if facts.requestedCwd.len == 0:
    return ""
  if facts.requestedCwdUsable:
    return facts.requestedCwd
  facts.fallbackCwd

func recordLaunchRefusal*(facts: RecordLaunchFacts;
                          defect: RecordLaunchDefect): string =
  ## What the user is told when a precondition fails.
  ##
  ## Names the thing that is missing and where it was looked for. "ENOENT" on
  ## its own is not a diagnosis — it is the same five letters for three
  ## unrelated causes, and the reporter of #747 could not act on it.
  case defect
  of rldNone:
    ""
  of rldNoRecordTarget:
    "Nothing to record: this recording does not name a program, and no file " &
    "was selected to record instead."
  of rldRecorderMissing:
    if looksLikeAPath(facts.recorder):
      "The CodeTracer recorder is missing: '" & facts.recorder &
      "' does not exist. Recording needs the 'ct' binary that ships with " &
      "this build."
    else:
      "The CodeTracer recorder is missing: '" & facts.recorder &
      "' was not found on the PATH this recording would run with. Recording " &
      "needs the 'ct' binary that ships with this build."

func recordLaunchCwdWarning*(facts: RecordLaunchFacts): string =
  ## What the user is told when the recorded working directory is gone and the
  ## launch proceeds from somewhere else. Empty when there is nothing to say.
  ##
  ## Said out loud rather than logged: the recording that comes back was made
  ## in a different directory from the one it claims, and a program that reads
  ## relative data files will behave differently because of it.
  if facts.requestedCwd.len == 0 or facts.requestedCwdUsable:
    return ""
  let replacement = recordLaunchCwd(facts)
  if replacement.len > 0:
    "The directory this recording was made in ('" & facts.requestedCwd &
    "') no longer exists; recording from '" & replacement & "' instead."
  else:
    "The directory this recording was made in ('" & facts.requestedCwd &
    "') no longer exists; recording from CodeTracer's own directory instead."
