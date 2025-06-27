import async
import transport

type
  ViewModelClient* = ref object
    transport*: Transport

method emit*[T](v: ViewModelClient, event: T) =
  v.transport.emit(event)

method subscribe*[T](v: ViewModelClient, eventKind: CtEventKind, callback: proc(value: T): Future[void]) =
  # v.transport.emit(SubscribeEvent(eventKind: eventKind))
  v.transport.subscribe(eventKind, callback)

proc newViewModelClient*(transport: Transport): ViewModelClient =
  result = ViewModelClient(transport: transport)
  # transport.connectViewModelServer(result)

type
  Subscriber* = ref object of RootObj

method emit*(eventKind: CtEventKind, value: T) {.base.} =
  raise newException("not implemented")

type
  ViewModelServer*[T] = ref object
    subscribers*: array[CtEventKind, Subscriber]
    receive*: proc(v: ViewModelServer[T], eventKind: CtEventKind, rawValue: T, subscriber: Subscriber)

method emit*[T, U](v: ViewModelServer[T], eventKind: CtEventKind, value: U) =
  for subscriber in v.subscribers[eventKind]:
    subscriber.emit(eventKind, value)

method register*[T](v: ViewModelServer[T], eventKind: CtEventKind, subscriber: Subscriber) =
  v.subscribers[eventKind] = subscriber

proc newViewModelServer*[T](receive: proc(v: ViewModelServer[T], eventKind: CtEventKind, rawValue: T, subscriber: Subscriber)) =
  ViewModelServer(receive: receive)

