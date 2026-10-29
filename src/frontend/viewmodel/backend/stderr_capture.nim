## Independently drain a child pipe while retaining a bounded diagnostic tail.
## The worker never touches DAP, a Nim Stream, or caller-owned GC objects.
## Nonblocking reads let close join it even when a descendant holds stderr open.
import std/[atomics, locks, os]
when defined(windows):
  import std/winlean
else:
  import std/posix

const DiagnosticTailBytes* = 64 * 1024

type
  CaptureState = object
    handle: FileHandle
    stop: Atomic[bool]
    lock: Lock
    bytes: array[DiagnosticTailBytes, char]
    first, length: int
    truncated: bool
    ended: bool
    readError: OSErrorCode
  StderrCapture* = object
    state: ptr CaptureState
    worker: Thread[ptr CaptureState]

proc readAvailable(state: ptr CaptureState): bool =
  ## Called under lock, on either thread. At most one bounded read; `false`
  ## includes a temporarily empty pipe. No buffered reader competes with it.
  if state.ended:
    return false
  var buffer: array[8192, char]
  var count = 0
  when defined(windows):
    var available, received: int32
    if not peekNamedPipe(Handle(state.handle), nil, 0, nil, addr available, nil):
      let error = osLastError()
      state.ended = true
      if error != OSErrorCode(109): # ERROR_BROKEN_PIPE is ordinary EOF.
        state.readError = error
    elif available > 0:
      if winlean.readFile(Handle(state.handle), addr buffer[0],
          min(available, int32(buffer.len)), addr received, nil) != 0:
        count = int(received)
      else:
        state.readError = osLastError()
        state.ended = true
  else:
    count = int(posix.read(state.handle, addr buffer[0], buffer.len))
    if count == 0:
      state.ended = true
    elif count < 0:
      let error = osLastError()
      if error.cint notin [EINTR, EAGAIN, EWOULDBLOCK]:
        state.readError = error
        state.ended = true
  if count <= 0:
    return false
  for i in 0 ..< count:
    if state.length < DiagnosticTailBytes:
      state.bytes[(state.first + state.length) mod DiagnosticTailBytes] = buffer[i]
      inc state.length
    else:
      state.bytes[state.first] = buffer[i]
      state.first = (state.first + 1) mod DiagnosticTailBytes
      state.truncated = true
  true

proc collect(state: ptr CaptureState) {.thread.} =
  while not state.stop.load(moAcquire):
    acquire(state.lock)
    let progress = state.readAvailable()
    let ended = state.ended
    release(state.lock)
    if ended:
      return
    if not progress:
      sleep(5)

proc startStderrCapture*(handle: FileHandle): StderrCapture =
  ## The Process retains handle ownership; stop this worker before closing it.
  when not defined(windows):
    let flags = fcntl(handle, F_GETFL)
    if flags < 0 or fcntl(handle, F_SETFL, flags or O_NONBLOCK) < 0:
      raiseOSError(osLastError(), "cannot make replay-server stderr nonblocking")
  result.state = cast[ptr CaptureState](allocShared0(sizeof(CaptureState)))
  result.state.handle = handle
  initLock(result.state.lock)
  try:
    createThread(result.worker, collect, result.state)
  except:
    deinitLock(result.state.lock)
    deallocShared(result.state)
    result.state = nil
    raise

proc diagnosticTail*(capture: var StderrCapture): string =
  ## Drain already queued bytes before taking a snapshot. This closes the race
  ## between stdout EOF and the worker reading the child's final diagnostic.
  ## Bound the work too: a live, flooding descendant cannot hold up the caller.
  if capture.state == nil:
    return ""
  let state = capture.state
  acquire(state.lock)
  defer: release(state.lock)
  for _ in 0 ..< 64:
    if not state.readAvailable():
      break
  if state.truncated:
    result = "[stderr truncated; showing last " & $DiagnosticTailBytes & " bytes]\n"
  for i in 0 ..< state.length:
    result.add(state.bytes[(state.first + i) mod DiagnosticTailBytes])
  if state.readError != OSErrorCode(0):
    result.add("\n[stderr capture failed: " & osErrorMsg(state.readError) & "]")

proc stop*(capture: var StderrCapture): string =
  ## Join before freeing the state or allowing Process.close to close its fd.
  ## The stop flag, rather than pipe EOF, owns the worker's lifetime.
  if capture.state == nil:
    return ""
  capture.state.stop.store(true, moRelease)
  joinThread(capture.worker)
  result = capture.diagnosticTail()
  deinitLock(capture.state.lock)
  deallocShared(capture.state)
  capture.state = nil
