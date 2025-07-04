import std / [ jsffi, strformat, jsconsole ]
import .. / common / ct_event

type
  # can be in the same process
  # can be a vscode webview
  # can be an electron subwindow
  # can be a seprate browser client
  Subscriber* = ref object of RootObj
    name*: cstring

  Transport* = ref object of RootObj
    receiveHandlers*: seq[proc(raw: JsObject, subscriber: Subscriber)]
    # direct field to make it easier to access from JavaScript/TypeScript
    receive*: proc(t: Transport, raw: JsObject, subscriber: Subscriber)

type
  CtRawEvent* = ref object
    kind*: CtEventKind
    value*: JsObject

  CtEvent*[T] = ref object
    kind*: CtEventKind
    value: T

type
  NotImplementedError* = object of CatchableError

### Transport:

method send*(t: Transport, data: JsObject, subscriber: Subscriber) {.base.} =
  raise newException(NotImplementedError, "not implemented")

method onRawReceive*(t: Transport, callback: proc(raw: JsObject, subscriber: Subscriber)) {.base.} =
  t.receiveHandlers.add(callback)
  # raise newException("not implemented")

method internalRawReceive*(t: Transport, raw: JsObject, subscriber: Subscriber) {.base.}=
  for handler in t.receiveHandlers:
    try:
      handler(raw, subscriber)
    except:
      echo "transport receive handler error: ", getCurrentExceptionMsg()


### Mediator:

# webview/component(mediator with vscode-view-transport OR same-process-local-transport) <-> (mediator with vscode-central-transport; OR same-process-central-transport)central context (renderer.nim / extension context / some other process);
# central context (mediator central-backend-transport) <-> (dap) backend;

# method emit*[T](v: Mediator, eventKind: CtEventKind, value: T) {.base.} =
#   v.transport.send(CtRawEvent(kind: eventKind, value: value.toJs).toJs, Subscriber(name: v.name))

# method subscribe*[T](v: Mediator, eventKind: CtEventKind, callback: proc(eventKind: CtEventKind, value: T, subscriber: Subscriber)) {.base.} =
#   # v.transport.emit(SubscribeEvent(eventKind: eventKind))
#   # v.transport.subscribe(eventKind, callback, subscriber)
#   raise newException(NotImplementedError, "not implemented")

# method receive*(m: Mediator, eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber) {.base.} =
#   raise newException(NotImplementedError, "not implemented")

# === Subscriber:

method emitRaw*(subscriber: Subscriber, eventKind: CtEventKind, value: JsObject, sourceSubscriber: Subscriber) {.base.} =
  raise newException(NotImplementedError, "not implemented")


# === MediatorWithSubscribers:

type
  # reimplementing methods/repeating fields from Mediator
  #   in order to not use inheritance, but to support geneirc methods
  #   as otherwise we get
  #   `generic methods are deprecated` warning
  MediatorWithSubscribers* = ref object # of Mediator
    name*: cstring
    transport*: Transport
    asSubscriber*: Subscriber
    subscribers*: array[CtEventKind, seq[Subscriber]]
    handlers*: array[CtEventKind, seq[proc(eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber)]]
    isRemote*: bool
    singleSubscriber*: bool
    # receive*: proc(t: TransportWithSubscribers, eventKind: CtEventKind, rawValue: JsObject, subscriber: Subscriber)

proc emit*[T](m: MediatorWithSubscribers, eventKind: CtEventKind, value: T) =
  console.log cstring"api for ", m.name, " emit: ", cstring($eventKind), value
  if m.singleSubscriber:
    echo "  -> using transport"
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
  result = MediatorWithSubscribers(
    name: name,
    isRemote: isRemote,
    singleSubscriber: singleSubscriber,
    transport: transport,
    asSubscriber: Subscriber(name: name))
  transport.onRawReceive(proc(data: JsObject, subscriber: Subscriber) =
    if not data.kind.isNil and not data.value.isNil:
      let eventKind = cast[CtEventKind](data.kind)
      let rawValue = data.value
      result.receive(eventKind, rawValue, subscriber))

###

# vscode extension(central)
# vscode view (webviews with components)
# electron central process (central)
# electron separate subwindow (components)
# same-process central
# same-process view (components)

# central context 1 <-> N components
# Transport
#   TransportWithSubscribers
#     VscodeCentralTransport
#     VscodeViewTransport
#     LocalTransport
#     ElectronCentralTransport
#     ElectronViewTransport
# 
#
 

# loadLocals()

# step(..)

# onCompleteMove

# await loadLocals()

# MVVM

# view 
# viewmodel 
# (middleware: mediator) 
# model

# -> load locals --send event to the central context -> does stuff; <-> backend; -> send us back loaded locals event or response;
# -> update status/notification --send event .. -> does stuff; -> send event to another component/webview;

# api.emit(CtLoadLocals, {..})

# await api.emit(..)

# api.subscribe(CtOnLoadedLocals, self.onLoadedLocals)



# <-> viewmodel;
# 
