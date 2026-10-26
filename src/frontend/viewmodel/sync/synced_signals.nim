## sync/synced_signals.nim
##
## The registry of every signal a mirrored session carries: each writable
## `Signal` of the session's `ReplayDataStore` and of its panel ViewModels,
## found by walking their fields, with a JSON encoder and decoder for each.
##
## WHY WALKED AND NOT LISTED. A hand-written list of the fields to mirror
## falls behind the ViewModels the day one of them grows a signal, and a
## mirror that silently lacks a field shows a webview that disagrees with the
## primary in exactly that field. Walking the objects' fields means a new
## signal is mirrored without anyone remembering to, and the one signal that
## cannot be (it holds closures) is reported by name rather than lost:
## `skippedKeys` is what a test asserts on.
##
## Memos are not registered — `Memo` is not a `Signal` — because they are
## computed: the mirror recomputes them from the mirrored inputs, which is
## both cheaper on the wire and what keeps the two sides' derivations the
## same code.
##
## Keys are `<owner>.<field>` (`store.calltrace.lines`, `calltrace.scrollPosition`),
## identical on every build of the same source, which is the one thing a
## primary and its mirrors must share: they are always the same bundle.
##
## Works on both the C and JS backends.

import std/[json, jsonutils, options, sets, tables]
  # `sets` and `tables` are not used by name: `jsonutils` finds its hooks for
  # `HashSet` and `Table` only when those modules are in scope where the
  # generic is instantiated. Without them a `HashSet` is written as an object
  # and read back as an array — a round trip that fails at runtime.

import isonim/core/signals

import ../session_vm
import ../store/replay_data_store

type
  SyncedSignal* = object
    ## One mirrored signal.
    key*: string
    read*: proc(): JsonNode
      ## Read the current value, encoded. Reading subscribes the caller's
      ## effect to the signal, which is how the publisher observes it.
    write*: proc(value: JsonNode)
      ## Decode `value` and write it. A value that does not decode as this
      ## signal's type is ignored, so a mirror never crashes on a message
      ## from a primary it disagrees with.

  SyncRegistry* = object
    signals*: seq[SyncedSignal]
    index: Table[string, int]
    skippedKeys*: seq[string]
      ## Signals that exist but cannot be mirrored (their values hold
      ## closures or ViewModel references). Listed so a test can say which.

const
  EncodeOptions = ToJsonOptions(enumMode: joptEnumString)
  DecodeOptions = Joptions(allowMissingKeys: true, allowExtraKeys: true)

proc holdsNil(node: JsonNode): bool =
  ## Whether `node` is nil or holds a nil node at any depth.
  if node.isNil:
    return true
  case node.kind
  of JObject:
    for _, child in node.pairs:
      if child.holdsNil:
        return true
  of JArray:
    for child in node.elems:
      if child.holdsNil:
        return true
  else:
    discard
  false

proc copyNilAsNull(node: JsonNode): JsonNode =
  ## A copy of `node` in which every nil node is a JSON `null`.
  if node.isNil:
    return newJNull()
  case node.kind
  of JObject:
    result = newJObject()
    for key, child in node.pairs:
      result[key] = copyNilAsNull(child)
  of JArray:
    result = newJArray()
    for child in node.elems:
      result.add copyNilAsNull(child)
  else:
    result = node.copy

proc encode[T](value: T): JsonNode =
  ## `value` as the wire carries it.
  ##
  ## A NIL `JsonNode` INSIDE A VALUE IS WRITTEN AS `null`. A signal may hold
  ## one: `FlowValueText.value` is nil for a step that recorded no value.
  ## `jsonutils.toJson` passes a `JsonNode` through as the same reference
  ## (`joptJsonNodeAsRef`), so the encoded tree had a nil child, and
  ## `std/json`'s `$`, `copy` and `==` all dereference it. The publisher's
  ## snapshot and batches then raised, and every mirror of the session
  ## stayed at the last message it had received: under `ct host` the page's
  ## panes showed no stop and no watches. The tree is copied only when it
  ## holds a nil, and never changed in place, because its nodes are the
  ## signal's own value. A mirror decodes the `null` as a `JNull` node, which
  ## the readers of such a field treat as "no value" as they treat nil.
  result = toJson(value, EncodeOptions)
  if result.holdsNil:
    result = copyNilAsNull(result)

proc add[T](reg: var SyncRegistry; key: string; sig: Signal[T]) =
  let s = sig
  reg.index[key] = reg.signals.len
  reg.signals.add SyncedSignal(
    key: key,
    read: proc(): JsonNode = encode(s.val),
    write: proc(value: JsonNode) =
      var decoded: T
      try:
        fromJson(decoded, value, DecodeOptions)
      except CatchableError, AssertionDefect:
        return
      s.val = decoded)

proc walk[T](reg: var SyncRegistry; prefix: string; x: T) =
  ## Register every `Signal` field of `x`, descending into plain object
  ## fields (the store's per-domain groups). Refs are not followed: they lead
  ## to other ViewModels, the backend and the collaboration core.
  for name, field in x.fieldPairs:
    when field is Signal:
      when compiles((var t = field.val; fromJson(t, newJNull());
                     discard toJson(t))):
        reg.add(prefix & name, field)
      else:
        reg.skippedKeys.add prefix & name
    elif field is object:
      reg.walk(prefix & name & ".", field)

template walkVM(reg: var SyncRegistry; prefix: string; vm: typed) =
  if not vm.isNil:
    reg.walk(prefix & ".", vm[])

proc syncedSignalsOf*(session: SessionViewModel): SyncRegistry =
  ## The registry for `session`: its store and every panel ViewModel it has.
  ## The same call on a primary and on its mirror yields the same keys,
  ## because both are built by `initializePanelViewModels`.
  result.index = initTable[string, int]()
  if session.isNil or session.store.isNil:
    return
  result.walk("store.", session.store[])
  result.walkVM("state", session.stateVM)
  result.walkVM("calltrace", session.calltraceVM)
  result.walkVM("eventLog", session.eventLogVM)
  result.walkVM("flow", session.flowVM)
  result.walkVM("editor", session.editorVM)
  result.walkVM("timeline", session.timelineVM)
  result.walkVM("debugControls", session.debugControlsVM)
  result.walkVM("search", session.searchVM)
  result.walkVM("searchResults", session.searchResultsVM)
  result.walkVM("pointList", session.pointListVM)
  result.walkVM("scratchpad", session.scratchpadVM)
  result.walkVM("shell", session.shellVM)
  result.walkVM("fileTree", session.fileTreeVM)
  result.walkVM("terminalOutput", session.terminalOutputVM)
  result.walkVM("traceLog", session.traceLogVM)

proc find*(reg: SyncRegistry; key: string): Option[SyncedSignal] =
  ## The signal registered under `key`, if any.
  if reg.index.hasKey(key):
    some(reg.signals[reg.index[key]])
  else:
    none(SyncedSignal)

proc keys*(reg: SyncRegistry): seq[string] =
  for s in reg.signals:
    result.add s.key

proc snapshot*(reg: SyncRegistry): JsonNode =
  ## Every registered signal's current value, as `[{key, value}, …]`.
  result = newJArray()
  for s in reg.signals:
    result.add %*{"key": s.key, "value": s.read()}
