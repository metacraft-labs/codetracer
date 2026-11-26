## CTF-P2c step 5: the process switcher's rules and viewmodel
## (`viewmodel/process_switcher_vm.nim`; codetracer-pm
## `design/agent-harbor-front-end/p2c-omnibox-and-control-center-study.md`
## §2.6, D25, D76-D83).
##
## * **The tooltip** names the process, its pid and binary (D25), its state
##   when it is not ready, and leaves out what the wire did not carry.
## * **The ring** goes on the process a correlation marker leads to, never on
##   the active one, and goes when the reader follows it: a press, a number,
##   the next/previous keys landing on it, or the follow operation.
## * **Stepping** wraps and passes over a missing process.
## * **One process** draws no switcher.
## * **The buttons** are the recording switcher's (`recordingButtons`): the
##   first slots and the active one, the rest behind `+N`, whose severity is
##   the worst hidden state; the ringed process behind `+N` is reported.
## * **`onSwitch`** hears each change once.
## * **The focus hint** (for a host that draws no tooltip): while the
##   switcher has the focus, the active button's tooltip, following the
##   selection; nothing without the focus or without a switcher.
##
## No mocks: the viewmodel is the stories' own
## (`createProcessSwitcherStoryVM`) over plain values.

import std/[sequtils, strutils, unittest]
import isonim/core/owner
import ../../process_switcher_vm
import ../../views/agent_harbor_process_switcher_words
import ../../../stories/agent_harbor_process_switcher_stories

proc withVM(fixture: string; body: proc(vm: ProcessSwitcherVM)) =
  createRoot proc(disposeRoot: proc()) =
    let vm = createProcessSwitcherStoryVM(fixture)
    body(vm)
    vm.dispose()
    disposeRoot()

suite "the tooltip":
  test "names the role, pid and binary, and the state when not ready":
    let e = ProcessEntry(recordingId: "b", role: "backend", pid: 4182,
                         binary: "/srv/envelope/bin/backend")
    check processTooltipOf(e) == "backend \xC2\xB7 pid 4182 \xC2\xB7 /srv/envelope/bin/backend"
    var failed = e
    failed.state = rsFailed
    failed.error = "trace file truncated"
    check processTooltipOf(failed).endsWith("(failed to load: trace file truncated)")
    var loading = e
    loading.state = rsLoading
    check processTooltipOf(loading).endsWith("(loading)")

  test "leaves out a pid or binary the wire did not carry":
    type Row = object
      recordingId, role, displayName: string
    let p = fromProcessTree(Row(recordingId: "r1", role: "backend", displayName: "backend.ct"))
    check p.pid == 0 and p.binary == "" and p.state == rsReady
    check processTooltipOf(p) == "backend"
    check "pid" notin processTooltipOf(p)
    check processLabel(ProcessEntry(recordingId: "r2", displayName: "x.ct")) == "x.ct"

suite "the ring":
  test "the marker rings process 2 and the button's tooltip says so":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.ringedNumber == 2
      check vm.ringedId == "envelope-backend"
      let b = vm.buttons.buttons
      check b[1].tooltip.endsWith(CorrelationWords)
      check b.countIt(CorrelationWords in it.tooltip) == 1
      check b.mapIt(it.ringed) == @[false, true, false])

  test "a marker toward the active process, or outside the recording, rings nothing":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      check not vm.markCorrelation("envelope-frontend", "x")
      check not vm.markCorrelation("elsewhere", "x")
      check vm.ringedNumber == 0)

  test "following it by a press, a number or the follow operation clears it":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.select("envelope-backend")
      check vm.ringedNumber == 0
      check vm.activeNumber == 2)
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.selectNumber(2)
      check vm.ringedNumber == 0)
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.followCorrelation()
      check vm.activeNumber == 2 and vm.ringedNumber == 0
      check not vm.followCorrelation())

  test "once followed, it does not come back when the reader moves on":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.select("envelope-backend")
      check vm.select("envelope-worker")
      check vm.ringedNumber == 0
      check vm.correlation.val.toId == "")

  test "going elsewhere keeps it":
    withVM("correlation", proc(vm: ProcessSwitcherVM) =
      check vm.select("envelope-worker")
      check vm.ringedNumber == 2)

  test "behind +N, the chip carries it":
    withVM("many", proc(vm: ProcessSwitcherVM) =
      check vm.markCorrelation("envelope-worker-6", "x")
      check vm.ringedHidden(ProcessSlots)
      check not vm.ringedHidden(high(int)))

suite "stepping":
  test "next and previous wrap":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      check vm.previous()
      check vm.activeNumber == 3
      check vm.next()
      check vm.activeNumber == 1
      check vm.next() and vm.activeNumber == 2)

  test "a missing process is passed over and cannot be chosen":
    withVM("loading-and-missing", proc(vm: ProcessSwitcherVM) =
      check vm.next()
      check vm.activeNumber == 2         # the loading back end
      check vm.next()
      check vm.activeNumber == 1         # the missing worker passed over
      check not vm.selectNumber(3)
      check not vm.select("envelope-worker"))

  test "numbers outside the recording change nothing":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      check not vm.selectNumber(0)
      check not vm.selectNumber(4)
      check not vm.selectNumber(1))     # already active

suite "the buttons":
  test "one process draws no switcher":
    createRoot proc(disposeRoot: proc()) =
      let vm = newProcessSwitcherVM("single", @[ProcessEntry(recordingId: "only",
                                                             role: "main")])
      check not vm.shown
      check vm.buttons.buttons.len == 0
      check not vm.next()
      vm.dispose()
      disposeRoot()

  test "many: the first slots, +N with the failed severity":
    withVM("many", proc(vm: ProcessSwitcherVM) =
      let b = vm.buttons(ProcessSlots)
      check b.buttons.mapIt(it.number) == @[1, 2, 3, 4, 5]
      check b.hidden == 3
      check rsFailed in b.hiddenStates
      check b.buttons[0].active)

  test "the active process past the slots takes the last one":
    withVM("many", proc(vm: ProcessSwitcherVM) =
      check vm.selectNumber(8)
      check vm.buttons(ProcessSlots).buttons.mapIt(it.number) == @[1, 2, 3, 4, 8])

  test "a process that turns ready keeps its number":
    withVM("loading-and-missing", proc(vm: ProcessSwitcherVM) =
      var backend = vm.entries.val[1]
      backend.state = rsReady
      check vm.applyProcess(backend)
      check vm.buttons.buttons[1].state == rsReady
      check vm.buttons.buttons[1].number == 2
      check not vm.applyProcess(backend))

suite "onSwitch":
  test "hears each change once":
    createRoot proc(disposeRoot: proc()) =
      var heard: seq[string]
      let vm = newProcessSwitcherVM("t", @[ProcessEntry(recordingId: "a"),
                                           ProcessEntry(recordingId: "b")],
                                    onSwitch = proc(id: string) = heard.add id)
      check vm.activeId.val == "a"
      check vm.select("b")
      check not vm.select("b")
      check vm.next()
      check heard == @["b", "a"]
      vm.dispose()
      disposeRoot()

suite "the focus hint":
  test "the focused (active) button's tooltip, only while focused":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      check not vm.focused.val          # the story at rest
      check vm.focusHint == ""
      vm.focused.val = true
      check vm.focusHint == "frontend \xC2\xB7 pid 4180 \xC2\xB7 /srv/envelope/bin/frontend"
      check vm.focusHint == vm.buttons.buttons.filterIt(it.active)[0].tooltip
      check vm.next()
      check vm.focusHint.startsWith("backend ")
      vm.focused.val = false
      check vm.focusHint == "")

  test "the in-use stories are focused; the active button past the slots still has one":
    for fixture in ["correlation", "many", "many-ringed", "loading-and-missing"]:
      withVM(fixture, proc(vm: ProcessSwitcherVM) =
        check vm.focused.val
        check vm.focusHint.startsWith("frontend "))
    withVM("many", proc(vm: ProcessSwitcherVM) =
      check vm.selectNumber(8)
      check vm.focusHint.startsWith("worker-6 "))

  test "a press focuses the switcher; one process has no hint":
    withVM("three", proc(vm: ProcessSwitcherVM) =
      check vm.runProcessSwitcherPress(ProcessSelectOperation, "envelope-frontend")
      check vm.focused.val
      check vm.focusHint.startsWith("frontend "))
    createRoot proc(disposeRoot: proc()) =
      let vm = newProcessSwitcherVM("single", @[ProcessEntry(recordingId: "only", role: "only")])
      vm.focused.val = true
      check vm.focusHint == ""
      vm.dispose()
      disposeRoot()
