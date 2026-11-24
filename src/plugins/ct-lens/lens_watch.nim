## lens_watch.nim — `ct-lens.watch`, CHANGED VALUES: what the last step
## changed, read from the core State ViewModel's change set and the mirrored
## locals; F7 (`watch.add-changed`) relays `state.addWatch` for each; the
## command's enablement and the `hasChanges` context key its binding reads are
## pushed whenever the set moves; and a per-type visualiser.
##
## A module of its own so the same `setupWatch` builds into the package's
## native executable (`ct_lens_plugins.nim`) and into a WebAssembly one.

import std/[algorithm, sets, strutils, tables]

import codetracer_plugin_sdk   # exports the mirrored types (value_changes, …)

const
  WatchId* = "ct-lens.watch"
  WatchVersion* = "0.1.0"

# ---------------------------------------------------------------------------
# Changed values
# ---------------------------------------------------------------------------

type
  Change = object
    path, before, after: string
    kind: VariableChange

  WatchState = ref object
    snapshots: OrderedTable[uint64, Table[string, string]]
    changes: seq[Change]
    tick: uint64
    known: bool
    fingerprint: string

const SnapshotsKept = 64

proc flatten(vars: seq[Variable]; prefix: string; nested: bool;
             into: var Table[string, string]) =
  for v in vars:
    let path = if prefix.len == 0: v.name else: prefix & "." & v.name
    into[path] = v.value
    if nested and v.children.len > 0:
      flatten(v.children, path, nested, into)

proc remember(w: WatchState; tick: uint64; values: Table[string, string]) =
  if w.snapshots.hasKey(tick): w.snapshots.del(tick)
  w.snapshots[tick] = values
  while w.snapshots.len > SnapshotsKept:
    var oldest: uint64
    for k in w.snapshots.keys:
      oldest = k
      break
    w.snapshots.del(oldest)

proc pendingWatches(changes: seq[Change]; watched: seq[string]): seq[string] =
  ## The changed values that are not watched yet, roots before members.
  let have = watched.toHashSet
  for c in changes:
    if c.kind == vchRemoved: continue
    if c.path notin have and c.path notin result:
      result.add c.path

proc refreshChanges(p: Plugin; w: WatchState) =
  let s = p.session
  if s.isNil or s.store.isNil or s.stateVM.isNil: return
  let nested = p.settings{"nested"}.getBool(false)
  let loadedFor = s.store.locals.loadedForRRTicks.val
  let locals = s.store.locals.locals.val
  if locals.len > 0:
    var values = initTable[string, string]()
    flatten(locals, "", true, values)
    w.remember(loadedFor, values)
  let diff = s.stateVM.valueChanges.val
  w.known = diff.currentKnown
  w.tick = diff.currentTick
  w.changes = @[]
  if diff.currentKnown:
    let now = w.snapshots.getOrDefault(diff.currentTick)
    let before = if diff.anchorKnown: w.snapshots.getOrDefault(diff.anchorTick)
                 else: initTable[string, string]()
    for path, kind in diff.changes:
      if not nested and '.' in path: continue
      w.changes.add Change(path: path, kind: kind,
                           before: before.getOrDefault(path, "?"),
                           after: now.getOrDefault(path, "?"))
    w.changes.sort(proc(a, b: Change): int = cmp(a.path, b.path))
  let pending = pendingWatches(w.changes, s.stateVM.watchExpressions.val)
  var fp = $w.known & "|" & $w.tick & "|" & pending.join(",")
  for c in w.changes: fp.add "|" & c.path & "=" & c.before & ">" & c.after
  if fp == w.fingerprint: return
  w.fingerprint = fp
  # What the pane shows.
  var kids: seq[ViewNode]
  if not w.known:
    kids.add viewText("changes.message", "waiting for the locals of this stop")
  elif w.changes.len == 0:
    kids.add viewText("changes.message", "this step changed nothing")
  else:
    var rows: seq[seq[string]]
    for c in w.changes:
      let what = case c.kind
        of vchAdded: "new"
        of vchRemoved: "gone"
        else: "changed"
      rows.add @[c.path, c.before, c.after, what]
    kids.add viewTable("changes.table", @["value", "before", "after", ""], rows)
    if pending.len > 0:
      kids.add viewText("changes.hint", "F7 watches " & pending.join(", "))
  p.pushView("changes", viewTreeNode("changes.root",
    "Changed at this step", kids, expanded = true))
  # The status item, the command's enablement, the binding's context key.
  let status =
    if not w.known: "changed: …"
    elif w.changes.len == 0: "changed: none"
    else:
      var paths: seq[string]
      for c in w.changes: paths.add c.path
      "changed: " & paths.join(", ")
  p.pushStatus("watch.status", viewText("watch.status", status))
  let reason =
    if not w.known: "the locals of this stop are not loaded yet"
    elif w.changes.len == 0: "this step changed nothing"
    elif pending.len == 0: "every changed value is already watched"
    else: ""
  p.pushEnablement("watch.add-changed", pending.len > 0, reason)
  p.pushContext("hasChanges", %(pending.len > 0))

proc publishVisualisers(p: Plugin) =
  ## Per-type visualisers as DATA (`supervisor.pluginVisualisers`): the host
  ## presents a matching value with the template; no plugin code runs while a
  ## pane renders. Python's `None` is shown as Python spells it, where the
  ## built-in rendering says `nil`.
  p.publish("visualisers", %*[
    {"id": "none", "typeMatch": "NoneType", "matchKind": "typeName",
     "summary": "None", "rank": 1}])

proc setupWatch*(sdk: PluginSdk) =
  let w = sdk.addPlugin(WatchId, WatchVersion)
  var state = WatchState()
  w.onActivate = proc(p: Plugin) =
    state = WatchState()
    p.pushEnablement("watch.add-changed", false,
                     "the locals of this stop are not loaded yet")
    p.pushContext("hasChanges", %false)
    p.publishVisualisers()
    p.refreshChanges(state)
  w.onSignals = proc(p: Plugin) =
    p.refreshChanges(state)
  w.onSettingsChanged = proc(p: Plugin) =
    state.fingerprint = ""
    p.refreshChanges(state)
  w.onInvoke("watch.add-changed", proc(p: Plugin; args: JsonNode; req: Request) =
    let s = p.session
    let watched = if s.isNil or s.stateVM.isNil: @[]
                  else: s.stateVM.watchExpressions.val
    let pending = pendingWatches(state.changes, watched)
    for path in pending:
      p.relay("state", "addWatch", %*{"expression": path})
    p.answer(req, %*{"watched": pending}))
