import async
import transport

type
  ViewModelClient* = ref object
    transport*: Transport

type
  ViewModelServer* = ref object
    transport*: Transport

method emit*[T](v: ViewModelClient, event: T) =
  v.transport.emit(event)

method subscribe*[T](v: ViewModelClient, eventKind: CtEventKind, callback: proc(value: T): Future[void]) =
  v.transport.emit(SubscribeEvent(eventKind: eventKind))
  v.transport.subscribe(eventKind, callback)

proc newViewModelClient*(transport: Transport): ViewModelClient =
  ViewModelClient(transport: transport)

# viewmodel.subscribe(CtEventKind.CtCompleteMove, callgraphComponent.onCompleteMove)

