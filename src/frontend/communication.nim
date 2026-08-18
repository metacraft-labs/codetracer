import std / [ jsffi, strformat, jsconsole ]
import .. / common / ct_event
import errors

type
  # can be in the same process
  # can be a vscode webview
  # can be an electron subwindow
  # can be a separate browser client
  Subscriber* = ref object of RootObj
    name*: cstring

  Transport* = ref object of RootObj
    receiveHandlers*: seq[proc(raw: JsObject, subscriber: Subscriber)]

### Transport:

method send*(t: Transport, data: JsObject, subscriber: Subscriber) {.base.} =
  raise newException(NotImplementedError, "not implemented")

method onRawReceive*(t: Transport, callback: proc(raw: JsObject, subscriber: Subscriber)) {.base.} =
  t.receiveHandlers.add(callback)

method internalRawReceive*(t: Transport, raw: JsObject, subscriber: Subscriber) {.base.}=
  for handler in t.receiveHandlers:
    try:
      handler(raw, subscriber)
    except:
      echo "transport receive handler error: ", getCurrentExceptionMsg()


# === Subscriber:

method emitRaw*(subscriber: Subscriber, eventKind: CtEventKind, value: JsObject, sourceSubscriber: Subscriber) {.base.} =
  raise newException(NotImplementedError, "not implemented")


# === MediatorWithSubscribers:

type
  # using a single type with all flags/cases needed for now
  #   in order to not use inheritance and methods, but to support generic api
  #   as otherwise if we use generic methods, we get
  #   `generic methods are deprecated` warning
  #
  #   some field types do use internally inheritance: can be overriden:
  #     Subscriber and Transport (but they represent values/data as raw JsObject-s,
  #       so their methods are not generic)
  #
  # maybe rename to CommunicationApi?
  MediatorWithSubscribers* = ref object
    name*: cstring
    transport*: Transport
    asSubscriber*: Subscriber # can be overriden
    subscribers*: array[CtEventKind, seq[Subscriber]]
    handlers*: array[CtEventKind, seq[proc(eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber)]]
    isRemote*: bool
    singleSubscriber*: bool
    # Optional back-reference to the mediator this one subscribes to.
    #
    # A child mediator (one per UI component, built by
    # ``types.setupLocalViewToMiddlewareApi``) announces itself to the parent
    # by emitting ``CtSubscribe``, which appends ``asSubscriber`` to the
    # parent's ``subscribers`` list.  Nothing in the event payload identifies
    # the child afterwards, so without this pointer a destroyed component can
    # never be taken off the parent's fan-out list.  ``unsubscribeAll`` uses
    # it to complete the teardown; it stays ``nil`` for root mediators and for
    # genuinely remote transports (webview / subwindow / browser client),
    # where clearing the local handlers is the only teardown available.
    parent*: MediatorWithSubscribers

proc emit*[T](m: MediatorWithSubscribers, eventKind: CtEventKind, value: T) =
  console.log cstring"api for ", m.name, " emit: ", cstring($eventKind), value
  if m.singleSubscriber:
    echo "  -> single sub using transport"
    m.transport.send(CtRawEvent(kind: eventKind, value: value.toJs).toJs, m.asSubscriber)
  else:
    echo "  subscribers: ", m.subscribers[eventKind].len
    for subscriber in m.subscribers[eventKind]:
      console.log cstring"    -> subscriber: ", subscriber
      subscriber.emitRaw(eventKind, value.toJs, m.asSubscriber)

proc subscribe*[T](m: MediatorWithSubscribers, eventKind: CtEventKind, callback: proc(eventKind: CtEventKind, value: T, subscriber: Subscriber)) =
  console.log cstring"api for ", m.name, " subscribe: ", cstring($eventKind)
  m.handlers[eventKind].add(proc(eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber) =
    callback(eventKind, rawValue.to(T), subscriber))
  if m.isRemote:
    echo "  remote: emit CtSubscribe"
    m.emit(CtSubscribe, eventKind)

proc registerSubscriber*(m: MediatorWithSubscribers, eventKind: CtEventKind, subscriber: Subscriber) =
  m.subscribers[eventKind].add(subscriber) # callbacks for the event kind are actually preserved in the mediator on the other side

proc removeSubscriber*(m: MediatorWithSubscribers, subscriber: Subscriber) =
  ## Drop every registration of ``subscriber`` from this mediator's fan-out
  ## lists.  The counterpart of ``registerSubscriber``: without it
  ## ``subscribers`` is append-only and a mediator keeps emitting into
  ## components that were destroyed long ago (see ``unsubscribeAll``).
  ##
  ## Matching is by reference identity, which is what ``registerSubscriber``
  ## stored — a subscriber may legitimately appear under several event kinds,
  ## so every kind is swept.
  if subscriber.isNil:
    return
  for kind in CtEventKind:
    if m.subscribers[kind].len == 0:
      continue
    var kept: seq[Subscriber] = @[]
    for existing in m.subscribers[kind]:
      if existing != subscriber:
        kept.add(existing)
    m.subscribers[kind] = kept

proc unsubscribeAll*(m: MediatorWithSubscribers) =
  ## Detach this mediator from the event bus.
  ##
  ## Two things have to happen for a destroyed component to stop reacting to
  ## events:
  ##
  ## 1. its own handlers must go — delivery terminates in ``receive``, which
  ##    walks ``m.handlers[kind]``, so clearing that array is what actually
  ##    silences the component.  This is the load-bearing half and it works
  ##    for every transport, local or remote.
  ## 2. the parent must stop fanning out to it — otherwise
  ##    ``parent.subscribers`` grows by one entry per opened-and-closed panel
  ##    and every emit pays for a round trip through a dead mediator.
  ##
  ## Safe to call more than once; the second call is a no-op.
  for kind in CtEventKind:
    if m.handlers[kind].len > 0:
      m.handlers[kind] = @[]
  if not m.parent.isNil:
    m.parent.removeSubscriber(m.asSubscriber)

proc receive*(m: MediatorWithSubscribers, eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber) {.exportc.} =
  console.log cstring"api for ", m.name, cstring" receive: ", cstring($eventKind), rawValue, subscriber
  if eventKind != CtSubscribe:
    console.log cstring"  handlers: ", m.handlers[eventKind].len
    for handler in m.handlers[eventKind]:
      try:
        console.log cstring"  handler: call"
        handler(eventKind, rawValue, subscriber)
      except:
        echo fmt"mediator {m.name} handler error: {getCurrentExceptionMsg()}"
  else:
    console.log cstring"  register subscriber for event kind(raw: ", rawValue, ")"
    echo "    event kind: ", cast[CtEventKind](rawValue) # if this doesn't appear, maybe the value isn't valid CtEventKind!
    m.registerSubscriber(cast[CtEventKind](rawValue), subscriber)

proc newMediatorWithSubscribers*(name: cstring, isRemote: bool, singleSubscriber: bool, transport: Transport): MediatorWithSubscribers =
  let mediator = MediatorWithSubscribers(
    name: name,
    isRemote: isRemote,
    singleSubscriber: singleSubscriber,
    transport: transport,
    asSubscriber: Subscriber(name: name))
  transport.onRawReceive(proc(data: JsObject, subscriber: Subscriber) =
    if not data.kind.isNil and not data.value.isNil:
      let eventKind = cast[CtEventKind](data.kind)
      let rawValue = data.value
      mediator.receive(eventKind, rawValue, subscriber))
  result = mediator

# usecases:
# -> load locals --send event to the central context -> does stuff; <-> backend; -> send us back loaded locals event or response;
# -> update status/notification --send event .. -> does stuff; -> send event to another component/webview;
