## test_trace_log_window.nim — Tier 1 for the Trace Log's locals window
## (Viewport-Driven-Loading, Decided Q4).
##
## A sweep answers each hit's tick and location; the Trace Log reads the
## locals of the rows it shows:
##
##   - an unmeasured view reads nothing;
##   - a viewport of R rows at row F reads the 20/10 window's rows, one
##     `ct/update-table` per tracepoint among them, for the window of that
##     tracepoint's hits they span;
##   - a row already read, and a window already asked, are not asked again.
##
## WHY A SCRIPTED BACKEND: the property under test is what the ViewModel
## sends and how it applies an answer of the engine's shape (`traceLocals`
## indexed by the hit's place among its tracepoint's hits — pinned on the
## engine side by `dap_handler`'s tests). A closure answers in that shape, so
## each request is visible without a recording.
##
## Runs on the C and JS backends.

import std/[json, strutils, unittest]

import isonim/core/[signals, computation, async_compat]

import backend/backend_service
import store/[replay_data_store, types]
import viewport
import viewmodels/trace_log_vm

proc drain() = drainPlatformCallbacks()

type
  Engine = ref object
    sent: seq[JsonNode]

proc tableAnswer(args: JsonNode): JsonNode =
  ## Each hit's locals: `x` = its place among its tracepoint's hits.
  let start = args{"tableArgs", "start"}.getInt
  let count = args{"tableArgs", "length"}.getInt
  var locals = newJArray()
  for i in 0 ..< start + count:
    if i < start:
      locals.add newJArray()
    else:
      locals.add %*[{"Field0": "x", "Field1": {"kind": 7, "i": $i,
                     "typ": {"kind": 7, "langType": "int"}}}]
  %*{"tableUpdate": {"data": {"draw": 0, "recordsTotal": 0,
                              "recordsFiltered": 0, "data": []},
                     "isTrace": true, "eventSlot": args["eventSlot"]},
     "traceLocals": locals}

proc setup(): (Engine, TraceLogVM) =
  let e = Engine()
  let backend = BackendService(
    sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
      var a = args
      a["command"] = %command
      e.sent.add a
      let body = if command == "ct/update-table": tableAnswer(args)
                 else: newJObject()
      newCompletedFuture[JsonNode](
        %*{"type": "response", "success": true, "body": body}),
    onEventProc: proc(handler: EventHandler) = discard)
  let vm = createTraceLogVM(createReplayDataStore(backend))
  # 200 hits of two tracepoints, interleaved: even rows tracepoint 0, odd 1.
  var rows: seq[TraceLogEntry]
  for i in 0 ..< 200:
    rows.add TraceLogEntry(rrTicks: i + 1, path: "/p.py", line: 3,
                           tracepointId: i mod 2)
  vm.setEntries(rows)
  (e, vm)

suite "the trace log reads the locals of the rows it shows":

  test "an unmeasured view reads nothing":
    let (e, vm) = setup()
    drain()
    check e.sent.len == 0
    check vm.entries.val[0].localsText == ""

  test "the window's rows are read, one request per tracepoint":
    let (e, vm) = setup()
    vm.setViewport(Viewport(rows: 10, firstRow: 100))
    drain()
    # Rows 90 ..< 130 (10 above, 20 below): 20 hits of each tracepoint,
    # from place 45.
    check e.sent.len == 2
    for a in e.sent:
      check a["isTrace"].getBool
      check a{"tableArgs", "start"}.getInt == 45
      check a{"tableArgs", "length"}.getInt == 20
    let rows = vm.entries.val
    checkpoint("row 100: " & rows[100].localsText)
    check rows[100].localsLoaded
    check rows[100].localsText.startsWith("x=")
    check "50" in rows[100].localsText
    check "50" in rows[101].localsText
    check rows[129].localsLoaded
    check not rows[89].localsLoaded
    check not rows[130].localsLoaded

  test "rows already read are not asked again":
    let (e, vm) = setup()
    vm.setViewport(Viewport(rows: 10, firstRow: 100))
    drain()
    let before = e.sent.len
    vm.setViewport(Viewport(rows: 10, firstRow: 101))
    drain()
    # Only row 130 is new: tracepoint 0's hit at place 65, one request.
    check e.sent.len == before + 1
    check e.sent[^1]["eventSlot"].getInt == 0
    check e.sent[^1]{"tableArgs", "start"}.getInt == 65
    check e.sent[^1]{"tableArgs", "length"}.getInt == 1
    vm.setViewport(Viewport(rows: 10, firstRow: 100))
    drain()
    check e.sent.len == before + 1
