type
  Transport* = ref object of RootObj

method emit*[T](t: Transport, event: T) {.base.} =
  raise newException("not implemented")

method subscribe*[T](t: Transport, eventKind: CtEventKind, callback: proc(value: T): Future[void]) {.base.} =
  raise newException("not implemented")

type
  LocalTransport* = ref object of Transport

method emit*[T](t: LocalTransport, event: T) =
  t.events.add(event.toJs)
  if not t.serverHandle.isNil:
    t.serverHandle(event)
method subsc

# ViewModelServer: local transport: init with the same transport;
# it will delegate to it its own handle call
