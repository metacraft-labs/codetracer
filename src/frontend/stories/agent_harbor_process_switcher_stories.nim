## The process switcher stories' viewmodel constructors (CTF-P2c step 5;
## codetracer-pm `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83).
##
## A story of the `agent-harbor-process-switcher` surface (declared in
## `codetracer_stories.nim`) is a `ProcessSwitcherVM` built by
## `createProcessSwitcherStoryVM` for the story's fixture, drawn by each
## host's session-tab view in the window's caption bar.
##
## THE DATA IS INVENTED (D79). `envelope-flow` is a multi-process
## recording of a made-up service whose processes pass an envelope from a
## front end to a back end and on to workers, the example boundary
## Correlation-Markers.md uses (`envelope-flow`, `fe` / `be`). Its pids,
## binaries and step numbers are made up; no real program or trace is named.
## The pid, the binary and a process's load state are what D25's tooltip and
## P3 need and what the backend's `ct/listProcesses` does not carry yet
## (codetracer-pm `issues/2026-11-21-ct-list-processes-carries-no-pid-binary-or-load-state.md`),
## so they exist only here until it does.

import ../viewmodel/process_switcher_vm

export process_switcher_vm

const
  EnvelopeFlowTitle* = "envelope-flow"
  OtherTabTitle* = "sudoku"
    ## The plain session tab beside it, as CodeTracer's own strip draws one.
  ProcessSlots* = 5
    ## Buttons the tab draws before `+N` (the initiative tab's
    ## `RecordingSlots`).
  ProcessSlotsCompact* = 2
    ## On a narrow window: the first process and the active one, then `+N`.
  CorrelationWords* = "a correlation marker (envelope-flow, step 1 204) leads here"
    ## What the ringed button's tooltip adds: the marker at the reader's
    ## position whose counterpart is in that process.
  HiddenCorrelationWords* = "a correlation marker (envelope-flow, step 2 311) leads here"
    ## The many-ringed story's marker: its counterpart is in the sixth
    ## worker, a process behind `+N`.
  processSwitcherFixtures* = ["three", "correlation", "many", "many-ringed",
                              "loading-and-missing"]
    ## Every fixture an `agent-harbor-process-switcher` story may name.

proc process(id, role: string; pid: int; binary: string;
             state = rsReady; error = ""): ProcessEntry =
  ProcessEntry(recordingId: id, role: role, displayName: role & ".ct", pid: pid,
               binary: binary, state: state, error: error)

proc threeProcesses(): seq[ProcessEntry] =
  @[process("envelope-frontend", "frontend", 4180, "/srv/envelope/bin/frontend"),
    process("envelope-backend", "backend", 4182, "/srv/envelope/bin/backend"),
    process("envelope-worker", "worker", 4190, "/srv/envelope/bin/worker")]

proc manyProcesses(): seq[ProcessEntry] =
  ## Eight processes: the front end, the back end and six workers, the
  ## fourth worker's trace failed to load.
  result = @[process("envelope-frontend", "frontend", 4180, "/srv/envelope/bin/frontend"),
             process("envelope-backend", "backend", 4182, "/srv/envelope/bin/backend")]
  for i in 1 .. 6:
    if i == 4:
      result.add process("envelope-worker-4", "worker-4", 4193,
                         "/srv/envelope/bin/worker", rsFailed, "trace file truncated")
    else:
      result.add process("envelope-worker-" & $i, "worker-" & $i, 4189 + i,
                         "/srv/envelope/bin/worker")

proc loadingProcesses(): seq[ProcessEntry] =
  ## The front end ready, the back end's trace still loading, the worker's
  ## missing from the recording's bundle.
  @[process("envelope-frontend", "frontend", 4180, "/srv/envelope/bin/frontend"),
    process("envelope-backend", "backend", 4182, "/srv/envelope/bin/backend", rsLoading),
    process("envelope-worker", "worker", 4190, "/srv/envelope/bin/worker", rsMissing,
            "not in the recording's bundle")]

proc createProcessSwitcherStoryVMAtRest(fixture: string): ProcessSwitcherVM =
  ## The fixture's switcher, its focus not yet set.
  case fixture
  of "three":
    newProcessSwitcherVM(EnvelopeFlowTitle, threeProcesses(), "envelope-frontend")
  of "correlation":
    # The reader stands on the front end's send marker; its counterpart is
    # the back end's receive (Correlation-Markers.md §5.3), so process 2 is
    # ringed until the reader goes there.
    let vm = newProcessSwitcherVM(EnvelopeFlowTitle, threeProcesses(), "envelope-frontend")
    doAssert vm.markCorrelation("envelope-backend", CorrelationWords)
    vm
  of "many":
    newProcessSwitcherVM(EnvelopeFlowTitle, manyProcesses(), "envelope-frontend")
  of "many-ringed":
    # The marker leads to the sixth worker, process 8: behind `+N` at every
    # size, so the chip carries the ring (study D80).
    let vm = newProcessSwitcherVM(EnvelopeFlowTitle, manyProcesses(), "envelope-frontend")
    doAssert vm.markCorrelation("envelope-worker-6", HiddenCorrelationWords)
    vm
  of "loading-and-missing":
    newProcessSwitcherVM(EnvelopeFlowTitle, loadingProcesses(), "envelope-frontend")
  else:
    raise newException(ValueError, "no process switcher story fixture named " & fixture)

proc storyHasFocus*(fixture: string): bool =
  ## Whether the fixture's switcher has the focus (`ProcessSwitcherVM.focused`):
  ## `three` shows the tab at rest, the focus elsewhere in the window; every
  ## other story shows the switcher while the reader works it, so a host
  ## that draws no tooltip shows the focused button's in its status line
  ## (the terminal).
  fixture != "three"

proc createProcessSwitcherStoryVM*(fixture: string): ProcessSwitcherVM =
  ## The switcher the fixture names, showing the front end (process 1),
  ## focused as `storyHasFocus` says. An unknown fixture raises rather than
  ## showing some other state.
  result = createProcessSwitcherStoryVMAtRest(fixture)
  result.focused.val = storyHasFocus(fixture)

proc slotsFor*(compact: bool): int =
  ## The buttons a tab draws before `+N`.
  if compact: ProcessSlotsCompact else: ProcessSlots
