## watch_expressions_browser_probe.nim — mount the STATE pane in a REAL
## browser and let a user type a watch expression into it.
##
## ## WHY THIS EXISTS
##
## The pane's headless suites drive the **MockRenderer**. The Web renderer is
## a separate code path in the same file, and the difference is not academic
## here: the tab strip that makes the Watches tab reachable existed ONLY in
## the Mock panel. `stWatches` was selectable from `vm.selectTab` — which is
## what a headless test calls — and from no gesture in any shipping product.
## A mock-only suite was green over a tab no user could open.
##
## So this mounts `renderStatePanel(WebRenderer, ...)`: the procedure the
## browser actually runs. The probe asserts nothing; it paints, and
## `ci/test/watch-expressions-in-browser.sh` reads what painted.
##
## ## THE FIXTURE IS THE BACKEND'S OWN RESPONSE
##
## `ci/test/watch-expressions-probe/backend-response.json` is the `ct/load-
## locals` response body VERBATIM, as produced by `Db::load_locals` through
## `Handler::load_locals` and written out by
## `src/db-backend/tests/watch_expressions_dap_test.rs` under
## `CT_WRITE_WATCH_FIXTURE`. Nothing here is hand-written, so what the pane
## is asked to render is what this backend emits, and the two cannot drift
## without that suite noticing.
##
## The rows are fed through `applyLocalsResponse` — the product's own split —
## rather than by placing them in the signals directly, so the probe exercises
## the same separation the GUI and the SDK use.
##
## ## WHAT IS AND IS NOT UNDER TEST HERE
##
## Under test: the tab strip is reachable, the Watches tab renders watch
## answers, a refused watch renders its reason, the locals tab is unaffected,
## and typing into `#watch-0` reaches `StateVM.addWatch`.
##
## NOT under test: the transport. There is no engine in this page. The
## request/response half is what `watch_expressions_dap_test.rs` proves over
## the real `ct/load-locals` path, and its control run (all six checks red
## against the pre-fix `db.rs`) is what shows those checks can fail.
##
## Build (browser target — NOT -d:nodejs, which would ship a node build):
##   nim js -d:ctWeb --hints:off -o:<out>/probe.js \
##     ci/test/watch_expressions_browser_probe.nim

import std/[json, strutils]

import isonim/core/[signals, computation]
import isonim/web/dom_api as dom

import ../../src/frontend/viewmodel/store/replay_data_store
import ../../src/frontend/viewmodel/store/types as store_types
import ../../src/frontend/viewmodel/backend/mock_backend
import ../../src/frontend/viewmodel/viewmodels/state_vm
import ../../src/frontend/viewmodel/views/isonim_state_view

# The backend's own `ct/load-locals` body. `staticRead` so the bytes are in
# the bundle and the page needs no network — the same choice
# `constraints_listing_browser_probe.nim` makes, and for the same reason.
# The path is a compile-time define so a mutation arm can point this at a
# DIFFERENT response — e.g. the pre-fix backend's, with every watch row
# removed — without copying the probe out of this directory, where its
# relative imports and `--path` would stop resolving. `staticRead` takes an
# absolute path, which is what the arm supplies.
const WatchFixturePath {.strdefine.} = "watch-expressions-probe/backend-response.json"
const BackendResponse = staticRead(WatchFixturePath)

proc rowsFromResponse(body: JsonNode): seq[store_types.Variable] =
  ## Turn the wire rows into store rows, exactly as a host does.
  ##
  ## Deliberately mirrors `syncStoreLocals`'s field mapping, including
  ## reading the refusal out of the `Error` value's `msg` — which is the
  ## point of carrying a refusal as an `Error` rather than a new field:
  ## the value's own text representation IS the reason, so no host needs a
  ## special case to display it.
  result = @[]
  for row in body{"locals"}.getElems(@[]):
    let value = row{"value"}
    # `text_representation.nim` dispatches per kind; the kinds this fixture
    # carries are Int (`i`), Error (`msg`) and the compound Seq/Struct.
    var rendered = value{"msg"}.getStr("")
    if rendered.len == 0:
      rendered = value{"i"}.getStr("")
    if rendered.len == 0:
      rendered = value{"text"}.getStr("")
    if rendered.len == 0 and value{"elements"}.getElems(@[]).len > 0:
      var parts: seq[string] = @[]
      for element in value{"elements"}.getElems(@[]):
        parts.add(element{"i"}.getStr(""))
      rendered = "[" & parts.join(", ") & "]"
    result.add(makeVariable(
      name = row{"expression"}.getStr(""),
      value = rendered,
      typeName = value{"typ"}{"langType"}.getStr(""),
      hasChildren = false,
      children = @[],
      isWatch = value{"isWatch"}.getBool(false),
    ))

proc deferToTask(cb: proc()) {.importjs: "setTimeout(#, 0)".}

proc settle(store: ReplayDataStore) =
  ## Leave the pane in the state a REAL host reaches once its request has
  ## been answered.
  ##
  ## `StateVM`'s auto-load effect issues `ct/load-locals` through the store
  ## whenever the watch list changes, and this page has no engine to answer
  ## it — so the loading flag would stay set and the pane would paint
  ## "Loading..." forever, over rows that are already there. That is an
  ## artefact of the harness, not of the product, and leaving it in would
  ## put a misleading word in this gate's screenshot. The rows themselves
  ## come from `applyLocalsResponse` above, which is the product's path.
  ##
  ## DEFERRED BY A TASK, because the VM's effect calls this bridge FIRST and
  ## `store.requestLocals` SECOND — so clearing the flag inline is undone a
  ## line later by the request that will never be answered. Measured: the
  ## flag came back and the pane kept saying "Loading...".
  deferToTask(proc() = store.locals.loadingState.val = lsIdle)

proc main() =
  let backend = newMockBackendService(autoRespond = true).toBackendService()
  let store = createReplayDataStore(backend)
  let vm = createStateVM(store)

  let body = parseJson(BackendResponse)
  let rows = rowsFromResponse(body)

  # THE PRODUCT'S OWN SPLIT. Not a local reimplementation: this is the
  # single entry point `ui/state.nim` and `headless_session.nim` both use.
  store.applyLocalsResponse(rows)
  store.updateCodeStateLine(2, "let shield = 10000;")

  # WHAT THE TYPED GESTURE DOES, without an engine on the page.
  #
  # `addWatch` fires the VM's effect, which calls this bridge on the hosts
  # that have one. Here it re-applies the same recorded response, so the
  # pane's contents after a real keystroke are still the BACKEND's bytes and
  # never something this file invented. An expression the fixture does not
  # cover is answered the way a pane must answer anything it has no row
  # for — visibly, with a reason — rather than by leaving the tab blank.
  vm.onWatchesChangedProc = proc(expressions: seq[string]) =
    var next = rows
    for expression in expressions:
      var known = false
      for row in rows:
        if row.isWatch and row.name == expression:
          known = true
          break
      if not known:
        next.add(makeVariable(
          name = expression,
          value = "cannot evaluate `" & expression &
                  "`: no variable named `" & expression &
                  "` was recorded at this step",
          typeName = "watch error",
          hasChildren = false,
          children = @[],
          isWatch = true,
        ))
    store.applyLocalsResponse(next)
    settle(store)

  let container = dom.getElementById(dom.document, cstring"ct-state-pane")
  mountIsoNimStatePanel(container, vm)
  settle(store)

  # A machine-readable line beside the painted DOM, so a probe can tell
  # "the pane painted the wrong thing" from "the fixture never loaded".
  let summary = dom.getElementById(dom.document, cstring"ct-probe-summary")
  dom.appendChild(dom.Node(summary), dom.createTextNode(dom.document, cstring(
    "rows=" & $rows.len &
    " locals=" & $store.locals.locals.val.len &
    " watches=" & $store.locals.watches.val.len)))

main()
