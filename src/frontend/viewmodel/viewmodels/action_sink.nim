## viewmodels/action_sink.nim — where a mirror's ViewModel sends a user action.
##
## A ViewModel in a MIRROR session (a VS Code webview: `sync/mirror_session`)
## does not act on its own: its backend is inert, and the session it shows is
## the primary's, somewhere else (Shared-DOM-Front-Ends D6: "In a VS Code
## webview the action crosses to the host through `action_relay` and runs on
## the primary VM"). The view calls the same ViewModel proc it calls
## anywhere; when the ViewModel has an `ActionSink`, that proc hands the
## action to the sink instead of running it, and the primary runs it
## (`sync/action_relay.applyAction`, which names the same `vm` / `action` /
## argument names). The outcome reaches the mirror as the primary's next
## batch.
##
## A primary ViewModel has no sink, so every proc runs as it always has.
##
## A viewport is the exception: a mirror keeps the size its own view measured
## (the view compares against it), so `setViewport` forwards the report AND
## records it locally.
##
## Works on both the C and JS backends.

import std/[json, options]

type
  ActionSink* = proc(vm, action: string; args: JsonNode) {.closure.}
    ## Send `vm`.`action`(`args`) to the primary session.

# An argument is encoded as `action_relay` decodes it (`std/jsonutils`,
# `joptEnumString`): an `Option` as its value or `null`, an enum by name, the
# rest as `std/json` writes it. Written out rather than through
# `jsonutils.toJson`: a generic instantiated here would be the instance every
# other module gets, and this module cannot see the hooks the sync layer
# brings into scope for it (`sync/synced_signals`).

proc sinkArg*[T: enum](value: T): JsonNode =
  %($value)

proc sinkArg*[T](value: Option[T]): JsonNode =
  if value.isSome: sinkArg(value.get) else: newJNull()

proc sinkArg*[T: not enum](value: T): JsonNode =
  %value

proc forwards*(sink: ActionSink; vm, action: string;
               args: JsonNode = newJObject()): bool =
  ## Hand the action to `sink` and answer `true` — the caller then returns
  ## without running it — or answer `false` when there is no sink.
  if sink.isNil:
    return false
  sink(vm, action, args)
  true
