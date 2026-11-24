## plugin_host/key_snapshot.nim — the plugins' keys, as a front-end that does
## not hold the `Supervisor` decides them (Extensibility-Model.md §11.7.1).
##
## The desktop's key router runs in the RENDERER, and its supervisor in the
## main process (or, under `ct host`, in the server). §11.7.1 asks that a key
## be decided in the turn it arrives — `preventDefault` included — and from
## what the plugins pushed, never by asking a plugin. A round trip to the
## main process is not that turn. So the main process sends the renderer this
## snapshot of what the plugins pushed that decides a key, every time it
## changes, and the renderer resolves against it in the keydown listener.
##
## `snapshotOf` is written over the supervisor's own reading of its slots
## (`resolveLayerKey` / `resolveStaticKey`), not a second copy of the rules:
## what is filtered out there (an open breaker, an inactive plugin, a disabled
## operation) is left out here; what is decided per key there (scope, the
## `when` clause over the context keys, a suspect layer being transparent) is
## decided per key here, by `resolveLayer` and `resolveStatic`. The main
## process then routes the key the renderer consumed with `routeKey`, and a
## key that passed through a suspect layer is reported back so the plugin
## takes the strike `resolveLayerKey` would have given it.
##
## Pure (JSON in, a route out): it compiles for the renderer, the main
## process and the C backend's suites alike.

import std/[json, strutils, tables]

import ./protocol
import ../../../common/key_names

type
  SnapshotRoute* = object
    found*: bool
    plugin*: string
    op*: string
    viaLayer*: string
    passedSuspect*: seq[string]
      ## The suspect plugins whose layer the key fell through (§11.7.4).

const
  SnapshotLayers* = "layers"
  SnapshotStatics* = "statics"
  SnapshotContext* = "context"
  SnapshotReserved* = "reserved"
  SnapshotChordCount* = "chordCount"
  SnapshotChordWindowMs* = "chordWindowMs"

proc contextOf(snap: JsonNode; host: Table[string, bool]): Table[string, bool] =
  result = host
  let c = snap{SnapshotContext}
  if not c.isNil and c.kind == JObject:
    for k, v in c:
      result[k] = v.getBool(false)

proc isRecoveryChordKey*(key: string): bool =
  ## Whether `key` is the recovery chord's key (§11.7.6), in any spelling a
  ## front-end names it: the canonical `Esc` (`key_names.bindingKeyName`
  ## folds `esc` and `escape` to it).
  bindingKeyName(key) == "Esc"

proc isReserved*(snap: JsonNode; key: string): bool =
  ## The palette key and the recovery chord's key are no plugin's.
  let k = bindingKeyName(key)
  let r = snap{SnapshotReserved}
  if not r.isNil and r.kind == JArray:
    for x in r:
      if bindingKeyName(x.getStr("")) == k: return true
  false

proc resolveLayer*(snap: JsonNode; key, focusedSurface: string;
                   host = initTable[string, bool]()): SnapshotRoute =
  ## The plugin layers' answer for `key`, top layer first. The caller
  ## consults this only when no host modal is open (host modal layers rank
  ## above every plugin layer).
  if snap.isNil or snap.isReserved(key): return
  # Canonical names (`key_names.bindingKeyName`), the spelling the bindings
  # are stored in: `J` is not `j`, and `ctrl+alt+m` is `Ctrl+Alt+m`.
  let k = bindingKeyName(key)
  let ctx = snap.contextOf(host)
  let layers = snap{SnapshotLayers}
  if layers.isNil or layers.kind != JArray: return
  for i in countdown(layers.len - 1, 0):
    let l = layers[i]
    if not l{"window"}.getBool(false) and
       l{"owner"}.getStr("") != focusedSurface:
      continue
    let plugin = l{"plugin"}.getStr("")
    for b in l{"bindings"}.getElems():
      if b{"key"}.getStr("") == k and evalWhen(b{"when"}.getStr(""), ctx):
        if l{"suspect"}.getBool(false):
          if plugin notin result.passedSuspect:
            result.passedSuspect.add plugin
          break
        result.found = true
        result.plugin = plugin
        result.op = b{"op"}.getStr("")
        result.viaLayer = l{"token"}.getStr("")
        return

proc resolveStatic*(snap: JsonNode; key, focusedSurface: string;
                    host = initTable[string, bool]()): SnapshotRoute =
  ## The plugin PASS, between the user pass and the base pass (§11.7.2).
  if snap.isNil or snap.isReserved(key): return
  # Canonical names (`key_names.bindingKeyName`), the spelling the bindings
  # are stored in: `J` is not `j`, and `ctrl+alt+m` is `Ctrl+Alt+m`.
  let k = bindingKeyName(key)
  let ctx = snap.contextOf(host)
  for b in snap{SnapshotStatics}.getElems():
    if b{"key"}.getStr("") != k: continue
    let scope = b{"scope"}.getStr("")
    let plugin = b{"plugin"}.getStr("")
    if scope != "window" and scope != focusedSurface and
       plugin & "/" & scope != focusedSurface: continue
    if not evalWhen(b{"when"}.getStr(""), ctx): continue
    return SnapshotRoute(found: true, plugin: plugin, op: b{"op"}.getStr(""))

proc chordCount*(snap: JsonNode): int =
  if snap.isNil: 3 else: snap{SnapshotChordCount}.getInt(3)

proc chordWindowMs*(snap: JsonNode): int =
  if snap.isNil: 1_000 else: snap{SnapshotChordWindowMs}.getInt(1_000)

proc dropLayers*(snap: JsonNode) =
  ## The recovery chord, applied to the snapshot at once: every plugin
  ## layer is gone before the main process says so.
  if not snap.isNil and snap.kind == JObject:
    snap[SnapshotLayers] = newJArray()
