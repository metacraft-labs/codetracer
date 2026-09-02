## component_registry_binding_test.nim
##
## Regression test for "statusBaseModel dereferences null: reading 'sessions'".
##
## THE CHAIN THE CRASH TOOK
##
## 1. ``makeStatusComponent`` and ``makeSearchResultsComponent`` in
##    ``utils.nim`` build their component with no ``id`` at all, so both are
##    id 0 every time.  (The other singleton factories call ``generateId``,
##    which returns the lowest FREE id and therefore makes a second component
##    rather than a duplicate — a different oddity, not this one.)  Each
##    factory also publishes the component (``data.ui.status = result``)
##    BEFORE handing it to ``types.registerComponent``.
## 2. ``ui/session_switch.nim``'s ``createNewSession`` builds the shared chrome
##    for a new replay tab, ``makeStatusComponent`` included.  When that tab is
##    first activated, ``switchSession`` calls ``renderer.createUIComponents``
##    for the SAME session, which builds the chrome a second time.
## 3. ``registerComponent`` saw ``componentMapping[Status]`` already holding id
##    0, printed a warning and returned — and both ``component.data = data``
##    and ``component.content = content`` lived inside the branch it skipped.
## 4. So ``data.ui.status`` — the component the app renders — had ``data ==
##    nil``, and had never been subscribed to anything either.
## 5. ``ui/status.nim``'s ``statusBaseModel`` opens with
##    ``self.data.services.editor.active``.  ``services`` is one of the Data
##    forwarding templates in ``types.nim``; it expands to
##    ``self.data.sessions[self.data.activeSessionIndex].services``.  With a
##    nil ``self.data`` that is ``null.sessions`` in the generated JS:
##    ``TypeError: Cannot read properties of null (reading 'sessions')``.
##
## The reported message names ``sessions`` and not ``data`` precisely because
## the nil receiver is one hop upstream of the property that is read.
##
## WHAT IS ASSERTED HERE
##
## * the second-generation component is bound to its ``Data`` (case 1), and the
##   exact forwarding hop that crashed resolves to a real value (case 2);
## * the replaced first generation is detached from the bus and the new one is
##   attached, so a single emit is delivered exactly once (cases 3 and 4) —
##   binding ``data`` without that would fix the crash and leave the status bar
##   frozen, since a component that never got a mediator never subscribed to
##   ``InternalStatusUpdate`` / ``CtCompleteMove``.
##
## The stand-in is limited to WHERE the events come from: ``ui/status.nim``
## cannot be imported into a node test (it pulls in the Karax/DOM
## ``ui_imports`` tree), so the real ``StatusComponent`` type — which is
## declared in ``types.nim`` — is registered here with a ``register`` override
## that subscribes to ``InternalStatusUpdate`` the way ``ui/status.nim`` does,
## and the middleware re-emit is reproduced instead of imported.  Everything
## else is production code: ``types.registerComponent``,
## ``types.setupLocalViewToMiddlewareApi``, ``Component.unregister`` and the
## real ``communication.nim`` mediator.
##
## Runs under ``just test-frontend-js`` (lane ``frontend-js``):
## ``communication.nim`` is JS-only (``std/jsffi``), and the ``sessions``
## forwarding this test is about only exists on the JS side.

import std/[jsffi, unittest]
import ../types
import ../communication
import ../../common/ct_event

var statusDeliveries = 0
  ## Total ``InternalStatusUpdate`` deliveries across every registered status
  ## component — the leak counter.

method register(self: StatusComponent, api: MediatorWithSubscribers) =
  ## Mirrors ``ui/status.nim``'s ``StatusComponent.register``: keep the
  ## mediator and subscribe to the status-update event.
  ##
  ## Deliveries are counted BOTH globally and per component.  A global count
  ## alone cannot see this defect: with the duplicate left subscribed and the
  ## rendered component subscribed to nothing, the total is still exactly one
  ## — it is just going to the wrong object.  ``completeMoveId`` is a real
  ## ``StatusComponent`` field and stands in here for "this component redrew".
  self.api = api
  api.subscribe(InternalStatusUpdate,
    proc(kind: CtEventKind, value: StatusState, sub: Subscriber) =
      statusDeliveries += 1
      self.completeMoveId += 1
  )

proc resetComponentRegistry() =
  for content in Content:
    data.ui.componentMapping[content] = JsAssoc[int, Component]{}
    data.ui.openComponentIds[content] = @[]

proc installMiddlewareReEmit() =
  ## ``middleware.nim`` re-emits ``InternalStatusUpdate`` on ``viewsApi`` so
  ## every registered view sees it.  Reproduced rather than imported.
  let viewsApi = data.viewsApi
  viewsApi.subscribe(InternalStatusUpdate,
    proc(kind: CtEventKind, value: StatusState, sub: Subscriber) =
      viewsApi.emit(InternalStatusUpdate, value)
  )

proc freshBus() =
  data.sessions[data.activeSessionIndex].viewsApi =
    setupSinglePageViewsApi(cstring"test-frontend-to-views")
  resetComponentRegistry()
  installMiddlewareReEmit()
  statusDeliveries = 0

proc makeStatusPanel(): StatusComponent =
  ## The shape of ``utils.makeStatusComponent``: no ``id`` (so id 0),
  ## published into ``data.ui.status`` BEFORE registration, then registered.
  result = StatusComponent(
    maxNotificationsCount: 100,
    activeNotificationDuration: 3_000,
    state: StatusState())
  data.ui.status = result
  data.registerComponent(result, Content.Status)

proc pushStatusUpdate() =
  ## One ``InternalStatusUpdate`` from a middleware-side emitter, the way a
  ## queued operation produces one.
  let emitter = StatusComponent(state: StatusState())
  let emitterApi = setupLocalViewToMiddlewareApi(
    cstring"emitter #0 api", data.viewsApi)
  emitter.api = emitterApi
  emitterApi.emit(InternalStatusUpdate, StatusState())

proc observedSessionsLen(component: Component): int =
  ## The EXACT hop that crashed.  ``ui/status.nim``'s ``statusBaseModel``
  ## reads ``self.data.services``; ``services`` is a forwarding template that
  ## expands to ``self.data.sessions[self.data.activeSessionIndex].services``,
  ## so the first thing touched on ``self.data`` is ``sessions``.
  component.data.sessions.len

suite "component registry binds every component to its Data":

  test "a singleton rebuilt for the same session is still bound to Data":
    # createNewSession builds the chrome, switchSession's createUIComponents
    # builds it again for the same session: two id-0 status components.
    freshBus()

    let firstGeneration = makeStatusPanel()
    let secondGeneration = makeStatusPanel()

    echo "first generation data is nil: ", firstGeneration.data.isNil
    echo "second generation data is nil: ", secondGeneration.data.isNil
    echo "data.ui.status is the second generation: ",
      data.ui.status == secondGeneration

    # `data.ui.status` is what renders, so it is the one that must be bound.
    check data.ui.status == secondGeneration
    check secondGeneration.data.isNil == false
    check secondGeneration.data == data
    check secondGeneration.content == Content.Status

  test "the forwarding hop that crashed resolves to a value":
    freshBus()

    # Two generations, as in the case above — one generation was never the
    # problem, and a single `makeStatusPanel()` here would pass either way.
    discard makeStatusPanel()
    discard makeStatusPanel()
    let rendered = data.ui.status

    # Before the fix, evaluating `rendered.observedSessionsLen()` raised
    #   TypeError: Cannot read properties of null (reading 'sessions')
    # from the generated `rendered.data.sessions[...]` — the reported message.
    # The nil is reported as a value rather than walked into, so that the rest
    # of the suite still runs and this case fails on a comparison.
    check rendered.data.isNil == false
    if rendered.data.isNil:
      echo "sessions reachable through data.ui.status: NONE — ",
        "`data.ui.status.data` is nil, so `data.sessions` is `null.sessions`"
    else:
      let sessionsLen = rendered.observedSessionsLen()
      echo "sessions reachable through data.ui.status: ", sessionsLen
      check sessionsLen == data.sessions.len
      check sessionsLen >= 1
      check rendered.data.services.isNil == false

  test "one status update reaches the rendered component exactly once":
    # Binding `data` alone would stop the crash and leave the status bar dead:
    # the rejected duplicate never received a mediator, so it subscribed to
    # nothing while being the component `data.ui.status` names.
    freshBus()

    let firstGeneration = makeStatusPanel()
    let secondGeneration = makeStatusPanel()

    pushStatusUpdate()

    echo "deliveries — total: ", statusDeliveries,
      ", first generation: ", firstGeneration.completeMoveId,
      ", rendered (data.ui.status): ", data.ui.status.completeMoveId
    # The rendered component is the one that has to receive it.  Before the
    # fix the total was still 1 and the rendered component's count was 0: the
    # update went to the generation nothing draws.
    check data.ui.status.completeMoveId == 1
    check secondGeneration.completeMoveId == 1
    check firstGeneration.completeMoveId == 0
    check statusDeliveries == 1

  test "the replaced generation is detached from the bus":
    # The other half of the same property: replacing must not leave both
    # generations subscribed (that is the #612 handler leak).
    freshBus()

    let before = data.viewsApi.subscribers[InternalStatusUpdate].len
    let firstGeneration = makeStatusPanel()
    check data.viewsApi.subscribers[InternalStatusUpdate].len == before + 1

    let secondGeneration = makeStatusPanel()
    echo "first generation api is nil after replacement: ",
      firstGeneration.api.isNil
    echo "second generation api is nil: ", secondGeneration.api.isNil
    echo "subscriber count: before=", before,
      " after two generations=",
      data.viewsApi.subscribers[InternalStatusUpdate].len

    check firstGeneration.api.isNil
    check secondGeneration.api.isNil == false
    check data.viewsApi.subscribers[InternalStatusUpdate].len == before + 1

  test "two concurrently open panels with different ids both stay live":
    # The replacement must key on the id, not fire for every registration.
    freshBus()

    let panelZero = StatusComponent(id: 0, state: StatusState())
    data.registerComponent(panelZero, Content.Status)
    let panelOne = StatusComponent(id: 1, state: StatusState())
    data.registerComponent(panelOne, Content.Status)

    pushStatusUpdate()

    echo "deliveries with two distinct ids: ", statusDeliveries
    check panelZero.api.isNil == false
    check panelOne.api.isNil == false
    check statusDeliveries == 2
