## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI.
## See `host/native_host.nim`'s header for the rule and what it buys.
##
## host/edit_services.nim — the services Edit mode needs from a HOST: reading
## and writing the project's files, listing it, the keymap preference, the
## process behind `:build` / `:run` and build tasks, and Nim's compile-time
## tracer — and the two polls that advance a running build and a trace.
##
## Every loop that hosts a `TuiRuntime` wires them through `wireEditServices`
## and polls them with `advanceBuild` / `advanceNimTrace`: the terminal's
## replay and edit loops (`main.nim`) and the pane server
## (`pane_server.nim`, Editor-Hosted-Front-Ends §E9). They lived in
## `main.nim` until 2026-11-12, which the pane server cannot import; until
## then an editor-hosted session had none of them, and every operation that
## needs one answered with a silent success.
##
## HSF-E11 adds the third poll, `advanceGeneratedC`: Edit mode's "View
## Generated C Source" compiles the edited file to C
## (`native_nim_c_compiler`) and shows the listing in the Low Level Code pane
## through the presenter every surface shares (`generated_code_presenter`),
## from a `LowLevelCodeVM` of this state's own — an Edit-mode window has no
## replay, and one toggled out of Debug mode must not show the stop's listing
## as the edited file's.

import std/[os, strutils]
import ../app/runtime
import ../app/tui_app
import ../app/build_session
import ./build_runner
import ./edit_host
import ../../viewmodel/host/keymap_preference
import ../../viewmodel/host/native_nim_tracer
import ../../viewmodel/viewmodels/nim_tracing_vm
import ../../viewmodel/host/native_nim_c_compiler   # HSF-E11
import ../../viewmodel/viewmodels/[generated_code_presenter, generated_code_vm,
                                   generated_code_operation, low_level_code_vm,
                                   nim_c_producer]
from ../../viewmodel/store/types import StopLocation
import ../app/edit_binding
import ../app/views/low_level_code_pane
from ./tui_session import lowLevelModelOf, actOnListing
from isonim/core/signals import val
from ./test_results_source import NoSessionTabsText
from ../../viewmodel/host/native_file_tree import wireNativeFileOperations,
  FilesystemVM, FileTreeOperationResult # K19
from ../../viewmodel/keymap/keymap_router import ksFlag, ksStored, ksDefault

type
  EditHostState* = ref object
    ## The one piece of Edit-mode state a LOOP owns rather than `app/`: the
    ## process behind `:build` / `:run`.
    ##
    ## A `ref` AND NOT A `var` LOCAL, because `startBuild`'s closure has to
    ## write it and Nim does not let a closure capture a `var` parameter. It is
    ## also what lets `wireEditServices` be one function called from two loops
    ## instead of two copies of the same five closures — §14's construction
    ## rule, and the copy that would have been forgotten is the entrypoint's,
    ## because no suite compiles this module.
    running: RunningBuild
    nimTracer: NativeNimTracer
      ## Nim's compile-time tracing: the one trace in flight, polled by the
      ## loop like the build (`advanceNimTrace`).
    generatedC: NimCCompile
      ## HSF-E11: the compile behind Edit mode's "View Generated C Source",
      ## polled by the loop like the build (`advanceGeneratedC`).
    cAt: tuple[path: string; line: int]
      ## The caret the listing is anchored to: the file compiled, the line.
    cDirty: bool
      ## Whether that file's buffer had unsaved edits when the compile
      ## started: the compile reads the SAVED file (§13.4), and says so.
    listing*: LowLevelCodeVM
    operation: GeneratedCodeVM
      ## The listing's ViewModels — created without a replay store
      ## (`createLowLevelCodeVM(nil)`), so a session with no recording has
      ## them; nil until the first compile.

proc editListingModel(state: EditHostState;
                      prior: LowLevelPaneModel): LowLevelPaneModel =
  ## The Low Level Code pane's value for Edit mode's listing: the listing as
  ## the replay's is turned into the pane's (`lowLevelModelOf`), and while
  ## the compiler runs, the words that say so where the listing goes.
  if state.listing.isNil:
    return LowLevelPaneModel(loaded: true, executionRow: -1, selectedRow: -1,
      linkedRow: -1, activeRow: -1, scrollTop: prior.scrollTop,
      empty: "View Generated C Source shows the C a Nim file compiles to here")
  result = lowLevelModelOf(state.listing, prior)
  if state.generatedC.running:
    result.empty = "compiling " & state.cAt.path.extractFilename & " to C…"
    result.error = ""

proc showEditListing(rt: TuiRuntime; state: EditHostState) =
  ## Edit mode's listing into the pane — only while the window is in Edit
  ## mode: a compile that settles after a toggle to Debug mode keeps its
  ## listing for the way back and leaves the stop's alone.
  if rt.app.modes.product == pmEdit:
    rt.app.lowLevel = editListingModel(state, rt.app.lowLevel)

proc bufferIsDirty(rt: TuiRuntime; path: string): bool =
  ## Whether Edit mode's buffer of `path` holds unsaved edits.
  let es = rt.app.editSession
  if es.isNil:
    return false
  var at = es.indexOfPath(path)
  if at < 0 and rt.app.projectRoot.len > 0 and
     path.startsWith(rt.app.projectRoot):
    at = es.indexOfPath(path.relativePath(rt.app.projectRoot))
  at >= 0 and es.buffers[at].isDirty

proc startGeneratedC(rt: TuiRuntime; state: EditHostState; targetId,
                     path: string; line: int): string =
  ## `compileGeneratedCode`: start compiling `path` (absolute, or relative
  ## to the project) and show "compiling" in the pane. "" when it started,
  ## else why not — no compiler, no such file, a compile still running.
  if targetId != NimCTargetId:
    return "`" & targetId & "` is not a target Edit mode compiles"
  let source = if path.isAbsolute: path else: rt.app.projectRoot / path
  if state.generatedC.isNil:
    state.generatedC = newNimCCompile()
  if not state.generatedC.startNimCCompile(source):
    return "View Generated C Source: " & state.generatedC.message
  state.cAt = (path: state.generatedC.source, line: line)
  state.cDirty = rt.bufferIsDirty(source)
  if state.listing.isNil:
    state.listing = createLowLevelCodeVM(nil)
    state.operation = createGeneratedCodeVM()
  # The previous listing goes: the pane says it is compiling, not what the
  # last file compiled to.
  discard state.listing.showGeneratedListing(@[], @[], ArtefactSupport(),
                                             source, line, "")
  state.listing.selectInstruction(NoSelectedInstruction)
  rt.showEditListing(state)
  ""

proc advanceGeneratedC*(rt: TuiRuntime; state: EditHostState): bool =
  ## The compile behind Edit mode's "View Generated C Source", polled; true
  ## on the poll it settled. Its C files go to the shared presenter as a
  ## recording's do (`showGeneratedCode`, read from the compiler's scratch
  ## nimcache), the listing anchored to the caret the operation was asked
  ## at; that row is brought into view. A compile that failed shows the
  ## compiler's error, in the pane and on the status line.
  if state.isNil or state.generatedC.isNil or
     not state.generatedC.pollNimCCompile():
    return false
  let c = state.generatedC
  let (path, line) = state.cAt
  var failure = ""
  if c.phase == nccDone:
    let refused = showGeneratedCode(state.operation, state.listing, NimCTargetId,
      path, line, StopLocation(), c.cFiles,
      proc(p: string; done: proc(r: RecordedText)) =
        # The compiler's own output, on disk: read at once.
        try: done((ok: true, text: readFile(p), message: ""))
        except IOError, OSError:
          done((ok: false, text: "", message: "cannot read " & p)),
      proc(why: string) = failure = why)
    if refused.len > 0:
      failure = refused
  else:
    failure = c.message
    var t: GeneratedCodeTarget
    if targetById(NimCTargetId, t):
      present(state.operation, state.listing, t, GeneratedListing(),
              failure, path, line)
  rt.showEditListing(state)
  if rt.app.modes.product == pmEdit:
    if failure.len == 0:
      rt.revealAnchoredRow(rt.app.lowLevel.activeRow)
  let name = path.extractFilename
  rt.app.notification =
    if failure.len > 0: "Generated C of " & name & ": " & failure
    elif state.cDirty: "Generated C of " & name & " as saved: save it to " &
                       "see your unsaved edits"
    else: "Generated C of " & name & " beside the source"
  true

proc editLowLevelAct*(rt: TuiRuntime; state: EditHostState;
                      act: LowLevelAct): LowLevelActResult =
  ## The Low Level Code pane's act on Edit mode's listing (`TuiApp
  ## .lowLevelAct` in Edit mode): select, menu, keys and the caret as a
  ## replay's listing does them (`actOnListing`); but "go to the source
  ## line" moves the EDITOR to the Nim line the C came from — there is no
  ## debugger to move — and a step is refused: the listing is the
  ## compiler's, not a replay's.
  if state.isNil or state.listing.isNil:
    return LowLevelActResult(note: "nothing is listed: View Generated C " &
                                   "Source compiles the file in the editor")
  let vm = state.listing
  if act.kind == llaStep:
    return LowLevelActResult(note: "Edit mode has no replay to step: the " &
                                   "listing is the compiler's C")
  var jump = actOnListing(vm, act, result)
  # A generated row names no line of its own: its line is the anchor's.
  if jump.line <= 0 and act.kind in {llaPress, llaActivate}:
    let source = vm.sourceLineOf(vm.selected.val)
    if source.line > 0:
      jump = source
      result.note = ""
  if jump.line > 0:
    let why = rt.openWorkingFileAt(jump.path, jump.line, 0)
    result.note = if why.len > 0: why
                  else: jump.path.extractFilename & ":" & $jump.line
  rt.showEditListing(state)

proc wireEditServices*(rt: TuiRuntime; root: string; keymapFlag: string;
                      listFiles: proc(): EditListResult): EditHostState =
  ## Hand `rt` the four capabilities `app/` may not have: read a file, write a
  ## file, list the project, start a process.
  ##
  ## **BOTH LOOPS CALL THIS**, and that is the whole reason it exists as a
  ## function. `ct edit --ui=tui` obviously needs them; `ct replay --ui=tui`
  ## needs them too, because `Ctrl+F5` reaches Edit mode from a replay session
  ## and CodeTracer-TUI-Edit-Mode.md §6 says it must: *"the toggle moves
  ## between them within one session, as on the desktop."* Until PLAT-16's
  ## landing pass the replay loop wired none of them, so that toggle arrived at
  ## an editor with no reader — and §2.1's stale-trace notice, which needs a
  ## recording AND an edit at the same time, had no route in the product on
  ## which it could fire at all.
  ##
  ## `listFiles` is the parameter because it is the one that differs: see
  ## `runtime.EditServices.listFiles` for why one loop can walk the project
  ## before it claims the terminal and the other must not walk it at all until
  ## asked.
  let state = EditHostState()
  # PLAT-51: THE ROOT IS READ AT EACH CALL — a welcome tab's "Open folder"
  # re-roots the session's Edit mode (`app.projectRoot`), and every service
  # follows it.
  proc rootOf(): string =
    if rt.app.projectRoot.len > 0: rt.app.projectRoot else: root
  rt.editServices.readFile = proc(relative: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readProjectFile(rootOf(), relative))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
    try:
      writeProjectFile(rootOf(), relative, text)
      EditWriteResult(ok: true)
    except TuiHostError as e:
      EditWriteResult(ok: false, message: e.msg)
  rt.editServices.readConfig = proc(spelled: string): EditReadResult =
    try:
      EditReadResult(ok: true, text: readUserConfigFile(rootOf(), spelled))
    except TuiHostError as e:
      EditReadResult(ok: false, message: e.msg)
  rt.editServices.listFiles = listFiles
  # K19: Edit mode's Files menu acts on the disk here, in-process, by the
  # index process's rules (`native_file_tree`).
  rt.editServices.wireFileTree = proc(vm: FilesystemVM;
                                      openedFolder: proc(): string;
                                      done: proc(r: FileTreeOperationResult)) =
    wireNativeFileOperations(vm, openedFolder, done)
  # PLAT-43. The keymap model this session starts under is the one the user
  # last chose, read through the same `selectKeymap` a typed `:keymap` goes
  # through. A stored value that is not a model is REFUSED BY NAME on the
  # status line and the session runs the product default — never a silent
  # fallback a user cannot tell from a working preference.
  #
  # PLAT-68: precedence is the `--keymap` flag (this session only, never
  # stored), then the stored preference, then `cua` (Base-Keymaps §3.6). A
  # stored `default` — PLAT-43's name for the product default — is read as
  # `cua` and rewritten, and the notice says so once.
  let keymapPreference = sessionKeymap(keymapFlag)
  rt.selectBase(keymapPreference.model,
                case keymapPreference.reason
                of "flag": ksFlag
                of "stored": ksStored
                else: ksDefault)
  if keymapPreference.status in {kplRefused, kplMigrated}:
    rt.keymapNotice = keymapPreference.message
    rt.app.notification = keymapPreference.message
  rt.editServices.saveKeymap = proc(model: BaseKeymap): string =
    saveKeymapPreference(model)
  rt.editServices.startBuild = proc(kind: BuildKind;
                                    cmd: string): BuildStartResult =
    state.running = startBuild(kind, cmd, rootOf(), nowMonoMs())
    rt.app.build = state.running.session
    if state.running.session.verdict == bvRunning:
      BuildStartResult(ok: true, message: $kind & " started: " & cmd)
    else:
      BuildStartResult(ok: false, message: describeVerdict(state.running.session))
  # Nim's compile-time tracing: nimsuggest or `nim e`, run here; the loop
  # polls it (`advanceNimTrace`) and opens what it records.
  state.nimTracer = newNativeNimTracer()
  rt.editServices.startNimTrace = proc(request: NimTraceRequest;
                                       lines: seq[string]): string =
    discard state.nimTracer.startNimTrace(request, lines)
    state.nimTracer.vm.message
  # HSF-E11: Edit mode's generated C, compiled now; polled by the loop
  # (`advanceGeneratedC`).
  rt.editServices.compileGeneratedCode = proc(targetId, path: string;
                                              line: int): string =
    startGeneratedC(rt, state, targetId, path, line)
  rt.editServices.editLowLevelModel = proc(prior: LowLevelPaneModel):
      LowLevelPaneModel =
    editListingModel(state, prior)
  # Build-Output-Pane.md §3.6: a build TASK — its command in its own working
  # directory, named, read by its problem matcher.
  rt.editServices.projectDir = proc(): string = rootOf()
  rt.editServices.startTask = proc(cmd, dir, task,
                                   matcher: string): BuildStartResult =
    state.running = startBuild(bkBuild, cmd, (if dir.len > 0: dir
                                              else: rootOf()), nowMonoMs())
    state.running.session.taskName = task
    state.running.session.problemMatcher = matcher
    rt.app.build = state.running.session
    if state.running.session.verdict == bvRunning:
      BuildStartResult(ok: true, message: "")
    else:
      BuildStartResult(ok: false, message: describeVerdict(state.running.session))
  state

proc advanceNimTrace*(rt: TuiRuntime; edit: EditHostState;
                     open: proc(request: TraceOpenRequest): string;
                     followIntoDebug = true): bool =
  ## The Nim trace in flight, polled: once it settles, its recording is
  ## opened where the shared rule places it (`nimTracePlacement`, a new
  ## session tab) — or, in a loop that has no session tabs (`open` nil), the
  ## status line says where it is. True when the trace settled on this poll.
  let t = edit.nimTracer
  if t.isNil or not t.pollNimTrace():
    return false
  if t.vm.phase != ntpDone:
    rt.app.notification = t.vm.message
    return true
  if open.isNil:
    rt.app.notification = t.vm.message & " | " & NoSessionTabsText &
                          t.vm.tracePath
    return true
  let why = open(traceOpenRequestOf(t.vm.tracePath))
  # `followIntoDebug`: whether `rt` is the runtime the recording is SHOWN in.
  # The terminal's window has one runtime for all its tabs, so the new tab is
  # shown in Debug mode through it; a pane server's session has a runtime of
  # its own, the recording opens as ANOTHER session, and the session the
  # trace was started from stays in Edit mode.
  if why.len == 0 and followIntoDebug and rt.app.modes.product == pmEdit:
    # A replay opens in Debug mode (Mode-Transitions.md): a trace started
    # from Edit mode shows its recording, not the buffer it was asked from.
    rt.enterProductMode(pmDebug)
  rt.app.notification =
    if why.len > 0: why
    else: t.vm.message & " — opened in a new session tab"
  true

proc advanceBuild*(rt: TuiRuntime; state: EditHostState;
                  report: bool): bool =
  ## Advance a running build by one tick. Returns whether the screen changed.
  ##
  ## `report` is what tells the two call sites apart, and they are different on
  ## purpose: on an IDLE tick nothing else is competing for the status line, so
  ## a verdict goes there; right after a KEY the line belongs to whatever the
  ## key just said (`:cancel` says *"cancelling …"*), and overwriting it would
  ## take the user's own answer away from them one tick later.
  ##
  ## `pollBuild` does not block — `host/build_runner.nim`'s header carries the
  ## measurement that says so, and the suite that keeps it true is
  ## `tests/test_build_runner_process.nim`.
  if state.isNil or state.running.isNil:
    return false
  result = pollBuild(state.running, nowMonoMs())
  if result and report:
    rt.app.notification = describeVerdict(state.running.session)
