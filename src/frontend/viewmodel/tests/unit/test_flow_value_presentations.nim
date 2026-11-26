## test_flow_value_presentations.nim
##
## ADOPTING A FLOW WINDOW PRESENTS EACH RECORDED VALUE ONCE.
##
## `FlowVM.applyFlowUpdate` decodes the window every surface draws from
## (`flowLayoutWindowOf`, which renders each value to text at the flow budget)
## and the flow pane's rows (`vm.steps`). The rows presented every value a
## second time, through the same pipeline, so a window's values went through
## PLAT-2's presenter twice on the thread that applies the update. In a
## profile of an Electron call-trace jump into a Noir loop, on a loaded host,
## the second pass alone was 560 ms of the renderer's time before the new
## editor mounted. Values that are large previews (a sudoku solver's boards)
## make each pass dearer.
##
## What is asserted: the number of presenter passes (`flowValuePresentations`)
## while adopting a real captured window equals the number of recorded values
## in it, and the rows carry the same texts the window does. The count is the
## subject; no timing is involved.
##
## The window is `fixtures/flow/zk_shields_flow_window.json`
## (`noir_space_ship`'s `iterate_asteroids`, verbatim from the engine). The
## backend is a `MockBackendService` only so a `FlowVM` can be built; the
## window is applied directly, as the `ct/updated-flow` handler applies it.

import std/[json, os, unittest]

import isonim/core/[signals, owner]

import backend/[backend_service, mock_backend]
import store/replay_data_store
import viewmodels/[flow_vm, flow_layout]

const fixturePath = currentSourcePath().parentDir / ".." / "fixtures" /
  "flow" / "zk_shields_flow_window.json"

const fixtureText = staticRead(fixturePath)

proc fixtureView(): JsonNode =
  parseJson(fixtureText)["viewUpdate"]

proc recordedValues(view: JsonNode): int =
  ## The values the window records: every non-null entry of each step's
  ## before and after maps (the `return` pseudo-expression included).
  for st in view["steps"]:
    for field in ["beforeValues", "afterValues"]:
      let map = st{field}
      if map.isNil or map.kind != JObject: continue
      for _, value in map:
        if value.kind != JNull: inc result

suite "flow value presentations":

  test "adopting a window presents each recorded value once":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let vm = createFlowVM(createReplayDataStore(mock.toBackendService()))
      let view = fixtureView()
      let expected = recordedValues(view)
      check expected > 0
      flowValuePresentations = 0
      vm.applyFlowUpdate(%*{"finished": true, "location": view["location"],
                            "viewUpdates": [view]})
      check vm.steps.val.len > 0
      check flowValuePresentations == expected
      dispose()

  test "the pane's rows carry the window's own texts":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let vm = createFlowVM(createReplayDataStore(mock.toBackendService()))
      let view = fixtureView()
      vm.applyFlowUpdate(%*{"finished": true, "location": view["location"],
                            "viewUpdates": [view]})
      let window = vm.layoutWindow.val
      var checked = 0
      for row in vm.steps.val:
        for st in window.steps:
          if st.stepCount != row.step: continue
          for v in st.afterValues:
            if v.expression == row.expression:
              check row.afterValue == v.text
              inc checked
      check checked > 0
      dispose()
