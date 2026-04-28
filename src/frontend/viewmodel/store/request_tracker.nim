## store/request_tracker.nim
##
## RequestTracker — deduplicates identical in-flight requests.
##
## Before issuing a backend command the store calls `isDuplicate` with a
## logical key (e.g. "load-locals") and the serialised arguments that
## distinguish one request from another.  If an identical request is
## already pending the store skips the send.
##
## After the response arrives the store calls `markComplete` so that a
## future request with the same key can proceed.

import std/tables

type
  RequestTracker* = ref object
    ## Tracks pending requests keyed by a logical name.
    ## The value is the concatenation of the argument strings so we can
    ## tell whether the *same* request (key + args) is already in flight.
    pending: Table[string, string]

proc newRequestTracker*(): RequestTracker =
  ## Create a fresh tracker with no pending requests.
  RequestTracker(pending: initTable[string, string]())

proc argsKey(args: openArray[string]): string =
  ## Deterministic serialisation of the argument tuple.
  ## Simple concatenation with a separator that is unlikely to appear
  ## in real values.
  result = ""
  for i, a in args:
    if i > 0:
      result.add('\x1F')  # ASCII unit separator
    result.add(a)

proc isDuplicate*(tracker: RequestTracker; key: string;
                  args: varargs[string]): bool =
  ## Returns true when a request with the same key *and* the same
  ## arguments is already pending — the caller should skip the send.
  let serialised = argsKey(args)
  if key in tracker.pending:
    return tracker.pending[key] == serialised
  return false

proc markPending*(tracker: RequestTracker; key: string;
                  args: varargs[string]) =
  ## Record that a request with the given key and arguments is now
  ## in flight.  Any subsequent `isDuplicate` call with matching
  ## key + args will return true until `markComplete` is called.
  tracker.pending[key] = argsKey(args)

proc markComplete*(tracker: RequestTracker; key: string) =
  ## Remove the pending entry for `key`, allowing a new request with
  ## the same key to be issued.
  tracker.pending.del(key)

proc hasPending*(tracker: RequestTracker; key: string): bool =
  ## Check whether there is any pending request under `key`
  ## (regardless of arguments).
  key in tracker.pending

proc clear*(tracker: RequestTracker) =
  ## Drop all pending entries.  Useful when the session resets.
  tracker.pending.clear()
