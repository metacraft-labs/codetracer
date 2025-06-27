import std / jsffi

type
  Transport* = ref object of RootObj

method emit*[T](t: Transport, event: T) {.base.} =
  raise newException("not implemented")

method subscribe*[T](t: Transport, eventKind: CtEventKind, callback: proc(value: T): Future[void]) {.base.} =
  raise newException("not implemented")

method connectViewModelServer*(t: Transport, server: ViewModelServer) {.base.} =
  discard

type
  LocalTransport* = ref object of Transport
    handlers: array[CtEventKind, proc(value: JsObject): void]
    server: ViewModelServer
    subscriber: LocalSubscriber

  LocalSubscriber* = ref object of Subscriber
    transport*: LocalTransport

    
# === LocalTransport:

method emit*[T](t: LocalTransport, eventKind: CtEventKind, value: T) =
  t.server.receive(t.server, eventKind, value, t.subscriber)

method subscribe*[T](t: LocalTransport, eventKind: CtEventKind, callback: proc(value: T): Future[void]) =
  t.server.register(eventKind, t.subscriber)
  t.handlers[eventKind].add(proc(value: JsObject) = discard callback(cast[T](value))

method call*[T](t: LocalTransport, eventKind: CtEventKind, value: T) =
  for handler in t.handlers[event.kind]:
    handler(value.toJs)


# method connectViewModelServer*(t: Transport, server: ViewModelServer) =
  # t.server = server

proc newLocalTransport(server: ViewModelServer): LocalTransport =
  result = LocalTransport(server: server)
  result.subscriber = LocalSubscriber(transport: result)

# ViewModelServer: connect to this with the constructor: `newLocalTransport`


# === LocalSubscriber:

method emit*[T](l: LocalSubscriber, eventKind: CtEventKind, value: T) =
  l.transport.call(eventKind, value)

  
