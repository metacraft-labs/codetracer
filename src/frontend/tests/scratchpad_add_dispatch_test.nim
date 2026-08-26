## scratchpad_add_dispatch_test.nim
##
## Regression test for #612 — "Add to Scratchpad" adding the same value
## several times from a single click.
##
## The bug was NOT a DOM listener leak on the ``+`` button (that element is
## re-created from scratch every time the value popup is rebuilt).  It was a
## leak on the event bus: ``MediatorWithSubscribers`` had no teardown path at
## all, so every ``ScratchpadComponent`` that had ever been registered stayed
## subscribed to ``InternalAddToScratchpad`` for the lifetime of the page.
## Panels are destroyed and re-created routinely — closing a tab
## (``layout.closeLayoutTab``), a layout reset (``renderer.resetLayoutState``,
## which runs on every re-record / trace reload), closing a session — and each
## generation left one more live handler behind.  One emitted event was then
## delivered once per accumulated generation, which is why the multiplier was
## constant for a whole session instead of growing as the user stepped.
##
## What this test wires up:
## - the real ``communication.nim`` mediator (emit / subscribe / receive /
##   registerSubscriber / unsubscribeAll),
## - the real ``types.setupLocalViewToMiddlewareApi`` + ``registerComponent``,
##   i.e. the production "one private mediator per component, registered as a
##   subscriber of ``data.viewsApi``" wiring,
## - the real ``Component.register`` / ``Component.unregister`` methods.
##
## Only two things are stand-ins, both stated here rather than mocked
## silently:
## - ``SinkComponent`` stands in for ``ScratchpadComponent``.  ``ui/scratchpad``
##   cannot be imported into a plain node test (it pulls in the Karax/DOM
##   ``ui_imports`` tree), so the component subscribes to
##   ``InternalAddToScratchpad`` exactly like ``ScratchpadComponent.register``
##   does and counts the deliveries its handler receives.  The subscription
##   shape is what the bug lives in, not the handler body.
## - the middleware re-emit is installed directly instead of importing
##   ``middleware.nim`` (same import-tree reason).  ``addToScratchpadHandler``
##   ends in ``viewsApi.emit(InternalAddToScratchpad, value)``; that re-emit is
##   the fan-out step under test and is reproduced verbatim.
##
## This test lives under ``src/frontend/tests`` and runs through
## ``just test-frontend-js`` because ``communication.nim`` is JS-only
## (``std/jsffi``), while ``just test-vm-native`` compiles everything under
## ``src/tests/gui/tests`` with the C backend.

import std/[jsffi, unittest]
import ../types
import ../communication
import ../../common/ct_event

# ---------------------------------------------------------------------------
# Test double for ScratchpadComponent — see the header note.
# ---------------------------------------------------------------------------

var sinkDeliveries = 0
  ## Incremented once per delivery of ``InternalAddToScratchpad`` to a
  ## registered component, i.e. once per ``registerValue`` call the real
  ## Scratchpad panel would have made.

type
  SinkComponent = ref object of Component

method register(self: SinkComponent, api: MediatorWithSubscribers) =
  ## Mirrors ``ScratchpadComponent.register``: keep the mediator and subscribe
  ## the panel's sink to ``InternalAddToScratchpad``.
  self.api = api
  api.subscribe(InternalAddToScratchpad,
    proc(kind: CtEventKind, value: cstring, sub: Subscriber) =
      sinkDeliveries += 1
  )

proc resetComponentRegistry() =
  ## ``data`` is a module-level singleton in ``types.nim`` and its
  ## ``componentMapping`` entries start out nil (they are normally filled in by
  ## ``resetLayoutState`` / ``createNewSession``).  Rebuild them so
  ## ``registerComponent`` can run, and drop any component left over from a
  ## previous test case.
  for content in Content:
    data.ui.componentMapping[content] = JsAssoc[int, Component]{}
    data.ui.openComponentIds[content] = @[]

proc installMiddlewareReEmit() =
  ## The production middleware subscribes to ``InternalAddToScratchpad`` on
  ## ``viewsApi`` and re-emits it so that every registered view receives it
  ## (``middleware.addToScratchpadHandler``).  Installed once per test case,
  ## on the freshly created ``viewsApi``.
  let viewsApi = data.viewsApi
  viewsApi.subscribe(InternalAddToScratchpad,
    proc(kind: CtEventKind, value: cstring, sub: Subscriber) =
      viewsApi.emit(InternalAddToScratchpad, value)
  )

proc freshBus() =
  ## Start each test case from a clean event bus: a new ``viewsApi`` with the
  ## middleware re-emit installed and an empty component registry.
  data.sessions[data.activeSessionIndex].viewsApi =
    setupSinglePageViewsApi(cstring"test-frontend-to-views")
  resetComponentRegistry()
  installMiddlewareReEmit()
  sinkDeliveries = 0

proc openScratchpadPanel(id: int): SinkComponent =
  ## Equivalent of ``utils.makeScratchpadComponent`` — construct the component
  ## and let ``registerComponent`` build and attach its private mediator.
  result = SinkComponent(id: id)
  data.registerComponent(result, Content.Scratchpad)

proc closeScratchpadPanel(component: SinkComponent) =
  ## Equivalent of ``layout.closeLayoutTab``: detach from the event bus, then
  ## drop the component from the registry.
  component.unregister()
  discard jsDelete(data.ui.componentMapping[Content.Scratchpad][component.id])

proc clickAddToScratchpad() =
  ## Equivalent of one click on the ``+`` button of an Omniscience inline
  ## value: the emitting component (a flow/value component shares the editor's
  ## mediator) emits exactly one ``InternalAddToScratchpad``.
  let emitter = SinkComponent(id: 0)
  let emitterApi = setupLocalViewToMiddlewareApi(
    cstring"editor #0 api", data.viewsApi)
  emitter.api = emitterApi
  emitterApi.emit(InternalAddToScratchpad, cstring"i: 1 u32")

# ---------------------------------------------------------------------------

suite "InternalAddToScratchpad dispatch":

  test "one click delivers exactly once after the panel is rebuilt 4 times":
    # The reported scenario: the Scratchpad panel has been torn down and
    # re-created four times over the life of the page (closed tabs, re-records,
    # layout resets).  Before the fix every generation stayed subscribed and a
    # single click produced four rows.
    freshBus()

    var live: SinkComponent = nil
    for generation in 0 ..< 4:
      if not live.isNil:
        closeScratchpadPanel(live)
      # `utils.generateId` hands out the lowest free id, so a re-opened panel
      # normally gets the id its predecessor had.  Each generation is
      # nevertheless a distinct component object with its own mediator, which
      # is exactly why identity-based bookkeeping was not enough on its own.
      live = openScratchpadPanel(0)

    clickAddToScratchpad()

    check sinkDeliveries == 1

  test "a panel that is closed and never re-opened receives nothing":
    freshBus()

    let panel = openScratchpadPanel(0)
    closeScratchpadPanel(panel)

    clickAddToScratchpad()

    check sinkDeliveries == 0

  test "unregister removes the component from the parent's subscriber list":
    # Clearing the component's own handlers is what stops delivery, but the
    # parent's `subscribers` array is append-only too: without removal it grows
    # by one dead entry per opened-and-closed panel and every emit pays for a
    # round trip through a mediator that can no longer do anything.
    freshBus()

    let before = data.viewsApi.subscribers[InternalAddToScratchpad].len
    let panel = openScratchpadPanel(0)
    check data.viewsApi.subscribers[InternalAddToScratchpad].len == before + 1

    closeScratchpadPanel(panel)
    check data.viewsApi.subscribers[InternalAddToScratchpad].len == before

  test "unregister is idempotent and re-registration restores delivery":
    freshBus()

    let panel = openScratchpadPanel(0)
    closeScratchpadPanel(panel)
    # A second teardown (e.g. `resetLayoutState` running after the GL
    # `itemDestroyed` handler already closed the tab) must be harmless.
    panel.unregister()
    check panel.api.isNil

    # A component object that survives its panel (e.g. a cached editor tab)
    # must be able to re-register: `registerComponent` skips components that
    # still carry an `api`, which is why `unregister` clears it.
    data.registerComponent(panel, Content.Scratchpad)
    clickAddToScratchpad()

    check sinkDeliveries == 1

  test "two concurrently open panels each receive the event once":
    # The fix must not over-correct: genuinely live components stay subscribed.
    freshBus()

    # Two panels open at the same time carry different ids.
    discard openScratchpadPanel(0)
    discard openScratchpadPanel(1)

    clickAddToScratchpad()

    check sinkDeliveries == 2
