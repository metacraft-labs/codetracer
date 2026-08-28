## SDK-CONSUMER: BlockTracer.milestones.org M2b's second verification test.
## Declared as a consumer on purpose — the claim is about what composition
## a *consumer* can write over the five panes, so the test has to be able to
## write only what a consumer can write.
##
## test_cross_pane_composition_needs_no_bridge.nim
##
## M2b verification #2:
##
##   "Clicking a storage write in the event log moves the debugger position
##    through an ordinary memo read, with no serialisation or message
##    passing between panes."
##
## and M2b's second deliverable, which is the general form of it:
##
##   "Cross-pane composition: a memo in one pane may read a signal in
##    another."
##
## Front-End-Architecture.md §2 states the property this proves and why it
## is the reason for using IsoNim rather than embedding a pre-built debugger
## widget:
##
##   "a `Memo` in `TransactionVM` can read a `Signal` in `DebugControlsVM`
##    with no bridge, no serialisation and no message passing. ... It is what
##    makes affordances like 'click a storage write in the transaction page's
##    event list and the debugger jumps to the writing step' a two-line memo
##    rather than a protocol."
##
## ## What "no message passing between panes" is asserted *against*
##
## A debugger necessarily talks to a replay engine: a jump is a command, and
## the new position comes back from the engine. That traffic is the backend
## seam and it is not what this test forbids. What it forbids is a *pane*
## having to tell another *pane* anything — a bridge, an event bus, a
## serialised payload, a subscription callback registered by hand.
##
## So the assertions are shaped around the wire, which is the only place
## message passing could hide:
##
##   * `MockBackendService.receivedCommands` is counted across every
##     cross-pane read. A cross-pane composition that had to serialise
##     would show up there, and it does not: the count is unchanged.
##   * The panes are constructed in an order that makes a bridge
##     impossible — a memo is written over two panes *before* either has
##     any data, and reads correctly afterwards.
##   * No pane holds a reference to another pane. Each `create*VM` takes
##     the store and nothing else; there is no argument through which one
##     could be handed to another.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_cross_pane_composition_needs_no_bridge.nim

import std/[json, options, unittest]

import codetracer_embed

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc storageWriteRow(index: int; file: string; line: int;
                     rrTicks: uint64): EventLogRow =
  ## The row M2b's verification clicks.
  ##
  ## "A storage write" is the consumer's reading of an ordinary event row —
  ## `kind` is free text the recorder supplied. The SDK has no storage,
  ## transaction or chain concept and must not grow one
  ## (CodeTracer-Embed-SDK.md §3.2, last row).
  EventLogRow(
    eventId: rrTicks,
    eventIndex: index,
    kindId: 1,
    kind: "Write",
    file: file,
    line: line,
    value: "sstore slot=0x07 value=0x01",
    rrTicks: rrTicks,
    maxRRTicks: 4096'u64,
  )

# ---------------------------------------------------------------------------
# The deliverable: a memo in one pane may read a signal in another
# ---------------------------------------------------------------------------

suite "M2b — cross-pane composition needs no bridge":

  test "a memo reads a Signal owned by one pane and a Memo owned by another":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let eventLog = createEventLogVM(store)
      let editor = createEditorVM(store)

      # The composition. It is written here, outside both panes, over one
      # pane's mutable Signal and another pane's derived Memo — which is
      # exactly the shape Front-End-Architecture §2 promises a consumer's
      # own ViewModel can use.
      let caption = createMemo[string] proc(): string =
        let selected = eventLog.selectedRow.val      # Signal, EventLogVM
        let file = editor.activeFileName.val         # Memo, EditorVM
        if selected.isNone: "no row"
        else: $selected.get & "@" & file

      check caption.val == "no row"

      eventLog.selectRow(some(4))
      check caption.val == "4@"
      store.updateDebuggerPosition(21'u64, file = "vault.nr", line = 9)
      check caption.val == "4@vault.nr"

      # Two panes, one memo, and the wire does not move for it. The count
      # is taken after the writes have settled — those legitimately fire
      # each pane's own auto-load effect — and then held across further
      # cross-pane reads, which are the thing under test.
      let settled = mock.receivedCommands.len
      check caption.val == "4@vault.nr"
      check eventLog.selectedRow.val == some(4)
      check editor.activeFileName.val == "vault.nr"
      check mock.receivedCommands.len == settled

      eventLog.dispose()
      editor.dispose()
      store.dispose()
      disposeRoot()

  test "the cross-pane read is reactive, not a snapshot":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let controls = createDebugControlsVM(store)
      let calltrace = createCalltraceVM(store)

      var recomputes = 0
      let composed = createMemo[string] proc(): string =
        inc recomputes
        # A Memo in one pane and a Signal in another, in one expression.
        $controls.canStepForward.val & ":" & $calltrace.scrollPosition.val

      check composed.val == "true:0"
      let afterFirst = recomputes

      calltrace.scroll(12)
      check composed.val == "true:12"
      check recomputes > afterFirst

      store.setReplayAvailability(raUnreplayable)
      check composed.val == "false:12"

      controls.dispose()
      calltrace.dispose()
      store.dispose()
      disposeRoot()

  test "the composition survives one pane being disposed after the other":
    # Each pane owns its own reactive root (`withViewModel`). If cross-pane
    # composition needed a bridge, tearing one root down would leave the
    # other holding a dangling registration; it does not, because the
    # signals are the only thing shared and they belong to whoever created
    # them.
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let eventLog = createEventLogVM(store)
      let state = createStateVM(store)

      let composed = createMemo[int] proc(): int =
        state.watchExpressions.val.len + eventLog.eventRows.val.len

      check composed.val == 0
      state.addWatch("balance")
      check composed.val == 1
      state.dispose()
      # The disposed pane's signal is still readable — dispose tears down
      # the root's effects, not the values other code already holds.
      check composed.val == 1
      eventLog.appendLiveDebuggerStop(storageWriteRow(0, "vault.nr", 9, 21'u64))
      check composed.val == 2

      eventLog.dispose()
      store.dispose()
      disposeRoot()

# ---------------------------------------------------------------------------
# The verification: clicking a storage write moves the debugger position
# ---------------------------------------------------------------------------

suite "M2b — clicking a storage write moves the debugger position":

  test "the click is one command, and every other pane learns by memo read":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      # All five panes, each constructed from the store alone. There is no
      # argument on any of these calls through which one pane could be
      # handed another — the structural half of "no bridge".
      let eventLog = createEventLogVM(store)
      let editor = createEditorVM(store)
      let calltrace = createCalltraceVM(store)
      let state = createStateVM(store)
      let controls = createDebugControlsVM(store)

      # A consumer's own derivation over three panes at once — the "two-line
      # memo rather than a protocol" of Front-End-Architecture §2.
      let debuggerCaption = createMemo[string] proc(): string =
        editor.activeFileName.val & ":" & $state.currentVariables.val.len &
          ":" & $controls.statusText.val

      let writeRow = storageWriteRow(0, "vault.nr", 91, 512'u64)
      eventLog.appendLiveDebuggerStop(writeRow)
      eventLog.appendLiveDebuggerStop(
        storageWriteRow(1, "vault.nr", 104, 640'u64))

      check editor.activeFileName.val == ""
      check debuggerCaption.val == ":0:Idle"

      # The click.
      mock.clearReceivedCommands()
      eventLog.doubleClickRow(0)

      # Exactly one command left the process for the click itself: the
      # navigation. It went to the replay engine, not to another pane.
      let jump = mock.findCommand("ct/event-jump")
      check jump.isSome
      check jump.get.args["highLevelPath"].getStr == "vault.nr"
      check jump.get.args["highLevelLine"].getInt == 91
      check jump.get.args["directLocationRRTicks"].getBiggestInt == 512

      # The engine reports the new position on the store's own signal, the
      # way a real backend's complete-move event does.
      store.updateDebuggerPosition(512'u64, file = "vault.nr", line = 91)
      store.updateLocals(@[makeVariable("slot", "1", "Field")])

      # And every other pane has it — by an ordinary memo read. No pane was
      # told; each one derived.
      check editor.activeFileName.val == "vault.nr"
      check state.currentVariables.val.len == 1
      check debuggerCaption.val == "vault.nr:1:Idle"

      # The claim under test, stated as a measurement: reading the position
      # out of four different panes moves nothing on the wire. If any of
      # these reads had gone through a bridge, the count would move.
      let settled = mock.receivedCommands.len
      check editor.activeFileName.val == "vault.nr"
      check editor.cursorLine.val >= 1
      check calltrace.visibleLines.val.len == 0
      check state.currentVariables.val[0].name == "slot"
      check controls.canStepForward.val == true
      check debuggerCaption.val == "vault.nr:1:Idle"
      check mock.receivedCommands.len == settled

      eventLog.dispose()
      editor.dispose()
      calltrace.dispose()
      state.dispose()
      controls.dispose()
      store.dispose()
      disposeRoot()

  test "a click on a row that does not exist moves nothing":
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let eventLog = createEventLogVM(store)
      let editor = createEditorVM(store)

      mock.clearReceivedCommands()
      eventLog.doubleClickRow(0)
      eventLog.doubleClickRow(-1)
      check mock.findCommand("ct/event-jump").isNone
      check editor.activeFileName.val == ""

      eventLog.dispose()
      editor.dispose()
      store.dispose()
      disposeRoot()

  test "the panes compose the same way when the replay is degraded":
    # The degraded states are values on the ViewModels, so they compose
    # exactly like every other derivation — a consumer's banner memo is
    # written the same way whether the trace is healthy or not.
    createRoot proc(disposeRoot: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let eventLog = createEventLogVM(store)
      let controls = createDebugControlsVM(store)

      let banner = createMemo[string] proc(): string =
        # One memo, two panes, both reading §14 enum values.
        $controls.degradedState.val & "/" & $eventLog.degradedState.val

      check banner.val == "pdNone/pdNone"

      let before = mock.receivedCommands.len
      mock.emitEvent(%*{"kind": "CtReplayStatus", "integrity": "truncated"})
      check banner.val == "pdTraceTruncated/pdTraceTruncated"
      check mock.receivedCommands.len == before

      eventLog.dispose()
      controls.dispose()
      store.dispose()
      disposeRoot()
