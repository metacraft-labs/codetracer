## mock_backend.nim
##
## MockBackendService — deterministic, in-memory implementation of
## BackendService for unit testing.
##
## Features:
## - Expectation queue: pre-program (command, response) pairs.
## - Command log: every `send` is recorded for later assertion.
## - Strict mode: rejects unexpected commands with a clear error.
## - Event simulation: `emitEvent` pushes events to registered
##   handlers, enabling tests to exercise the event path.
##
## Works on both JS and C backends.

import std/[json, options]
when defined(js):
  import std/jsffi

import isonim/core/async_compat
import backend_service

type
  DeferredResponse* = object
    ## One outstanding `send` whose answer has not arrived yet.
    command*: string
    when defined(js):
      ## A hand-rolled thenable rather than a `Promise`.
      ##
      ## `async_compat.onComplete` branches on `__syncResolved`: absent, it
      ## calls `future.then(onSuccess, onError)`. A real `Promise` would
      ## then deliver on a microtask, which a synchronous test cannot
      ## observe and `drainPlatformCallbacks` cannot pump — so a test built
      ## on one could assert nothing. A thenable takes the *same*
      ## `onComplete` branch as a real promise (that is the property under
      ## test) while letting [`settleDeferred`] invoke the stored callbacks
      ## deterministically.
      thenable*: JsObject
    else:
      future*: Future[JsonNode]

  Expectation* = tuple[command: string, response: JsonNode]
    ## A canned response that MockBackendService returns when a
    ## matching command arrives.

  ReceivedCommand* = tuple[command: string, args: JsonNode]
    ## Record of a command that was sent through the mock.

  MockBackendService* = ref object
    ## Test double for BackendService.
    expectations*: seq[Expectation]
      ## FIFO queue of expected (command, response) pairs.  Each
      ## `send` consumes the first matching expectation.

    receivedCommands*: seq[ReceivedCommand]
      ## Log of every command that was sent, in order.

    eventHandlers*: seq[EventHandler]
      ## Event handlers registered via `onEvent`.

    autoRespond*: bool
      ## When true and no matching expectation exists, return an
      ## empty JSON object instead of raising.

    strict*: bool
      ## When true, an unmatched command raises an assertion error
      ## (overrides autoRespond).

    disconnected*: bool
      ## Set to true when `disconnect` is called.

    deferResponses*: bool
      ## When true, `send` returns a future that is **not yet settled** and
      ## that `async_compat.onComplete` treats as genuinely asynchronous —
      ## the `.then` branch on JS, an incomplete `Future` on C. Nothing
      ## resolves until [`settleDeferred`] is called.
      ##
      ## This exists because every other transport in this repo answers
      ## before `send` returns, and code written against that assumption
      ## looks correct until it meets a worker. `DebuggerSession.launch`
      ## called `markReady` on the strength of having *sent* three commands,
      ## which was invisible to every suite: the mock's
      ## `newCompletedFuture` carries `__syncResolved`, so
      ## `drainPlatformCallbacks` ran its callbacks, while a `newPromise`
      ## from `real_backend.nim` resolves on a microtask no synchronous
      ## drain can pump. The taxonomy was inert on the backend BlockTracer
      ## ships and nothing said so.

    deferred: seq[DeferredResponse]
      ## Futures handed out while `deferResponses` was set, oldest first.

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newMockBackendService*(strict: bool = false,
                            autoRespond: bool = false): MockBackendService =
  ## Create a new MockBackendService.
  ## - `strict`: if true, unmatched commands fail with an assertion.
  ## - `autoRespond`: if true (and not strict), unmatched commands
  ##   return `%*{}`.
  MockBackendService(
    expectations: @[],
    receivedCommands: @[],
    eventHandlers: @[],
    autoRespond: autoRespond,
    strict: strict,
    disconnected: false,
    deferResponses: false,
    deferred: @[],
  )

# ---------------------------------------------------------------------------
# Deferred (genuinely asynchronous) responses
# ---------------------------------------------------------------------------

proc newDeferredResponse(command: string): DeferredResponse =
  result = DeferredResponse(command: command)
  when defined(js):
    var thenable: JsObject
    {.emit: """
    `thenable` = {
      __ctWaiters: [],
      then: function (onSuccess, onError) {
        this.__ctWaiters.push({ ok: onSuccess, err: onError });
        return this;
      }
    };
    """.}
    result.thenable = thenable
  else:
    result.future = newFuture[JsonNode]("MockBackendService.deferred")

proc pendingDeferredCount*(mock: MockBackendService): int =
  ## How many `send` calls are still waiting for an answer.
  mock.deferred.len

proc settleDeferred*(mock: MockBackendService; response: JsonNode) =
  ## Answer the oldest outstanding deferred `send` with `response`, then let
  ## the platform run whatever callbacks that unblocked.
  ##
  ## Deliberately one at a time: a handshake that fails on its second
  ## command must be distinguishable from one that fails on its third.
  if mock.deferred.len == 0:
    return
  let entry = mock.deferred[0]
  mock.deferred.delete(0)
  when defined(js):
    let thenable = entry.thenable
    let payload = response
    {.emit: """
    var waiters = `thenable`.__ctWaiters;
    `thenable`.__ctWaiters = [];
    for (var i = 0; i < waiters.length; i++) {
      waiters[i].ok(`payload`);
    }
    """.}
  else:
    entry.future.complete(response)
  drainPlatformCallbacks()

proc settleAllDeferred*(mock: MockBackendService; response: JsonNode) =
  ## Answer every outstanding deferred `send` with the same `response`.
  while mock.deferred.len > 0:
    mock.settleDeferred(response)

# ---------------------------------------------------------------------------
# Expectation setup
# ---------------------------------------------------------------------------

proc expect*(mock: MockBackendService, command: string,
             response: JsonNode) =
  ## Enqueue an expectation: when `command` is sent, `response` is
  ## returned.  Expectations are matched FIFO.
  mock.expectations.add((command, response))

proc clearReceivedCommands*(mock: MockBackendService) =
  ## Clear the recorded command log.  Useful in multi-phase tests
  ## where you want to assert only on commands sent after a certain
  ## point without counting earlier setup traffic.
  mock.receivedCommands.setLen(0)

proc findCommand*(mock: MockBackendService;
                  command: string): Option[ReceivedCommand] =
  ## Search the recorded commands for the first matching command name.
  ## Returns `some(ReceivedCommand)` if found, `none` otherwise.
  ## Useful for asserting that a specific command was (or was not)
  ## sent without caring about its position in the log.
  for rc in mock.receivedCommands:
    if rc.command == command:
      return some(rc)
  return none(ReceivedCommand)

# ---------------------------------------------------------------------------
# Event simulation
# ---------------------------------------------------------------------------

proc emitEvent*(mock: MockBackendService, event: JsonNode) =
  ## Simulate a backend event — calls every registered handler.
  for h in mock.eventHandlers:
    h(event)

# ---------------------------------------------------------------------------
# Conversion to BackendService
# ---------------------------------------------------------------------------

proc toBackendService*(mock: MockBackendService): BackendService =
  ## Produce a BackendService whose procs delegate to this mock.
  let m = mock  # capture for closures

  let sendProc = proc(command: string,
                      args: JsonNode): BackendFuture[JsonNode] =
    m.receivedCommands.add((command, args))

    if m.deferResponses:
      # A worker-shaped answer: recorded now, delivered later, and taking
      # `onComplete`'s asynchronous branch in the meantime.
      let entry = newDeferredResponse(command)
      m.deferred.add(entry)
      when defined(js):
        return cast[BackendFuture[JsonNode]](entry.thenable)
      else:
        return entry.future

    # Find the first matching expectation.
    var idx = -1
    for i, exp in m.expectations:
      if exp.command == command:
        idx = i
        break

    if idx >= 0:
      let response = m.expectations[idx].response
      m.expectations.delete(idx)
      return newCompletedFuture[JsonNode](response)
    elif m.strict:
      # Use AssertionDefect to match test expectations: strict-mode
      # violations are programming errors, not recoverable failures.
      when defined(js):
        raise newException(AssertionDefect,
          "MockBackendService: unexpected command in strict mode: " & command)
      else:
        var fut = newFuture[JsonNode]("MockBackendService.send.strict")
        fut.fail(newException(AssertionDefect,
          "MockBackendService: unexpected command in strict mode: " & command))
        return fut
    elif m.autoRespond:
      return newCompletedFuture[JsonNode](%*{})
    else:
      return newCompletedFuture[JsonNode](newJNull())

  let onEventProc = proc(handler: EventHandler) =
    m.eventHandlers.add(handler)

  let disconnectProc = proc() =
    m.disconnected = true

  BackendService(
    sendProc: sendProc,
    onEventProc: onEventProc,
    disconnectProc: disconnectProc,
  )
