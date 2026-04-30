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

import isonim/core/async_compat
import backend_service

type
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
  )

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
