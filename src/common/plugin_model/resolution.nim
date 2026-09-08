## plugin_model/resolution.nim — PLAT-7 deliverable 2. "Resolution as a DAG,
## total before any activation; a cycle is an error naming it."
##
## ## TOTAL, AND WHAT THAT COSTS
##
## Extensibility-Model.md §4.2: "Resolution is total and happens before any
## activation. Dependencies form a DAG; a cycle is an error naming the cycle.
## All-or-nothing per dependency subtree: an extension whose dependency failed
## does not activate half-alive."
##
## `resolve` therefore takes the WHOLE registry and answers about all of it in
## one pass. It never activates anything and it cannot: this module imports
## nothing from `isonim` and knows nothing about effects, which is why it can
## be exercised by a `src/common` unit lane that links no renderer.
##
## Three properties the shape enforces rather than documents:
##
##   1. **A plugin is loadable or it is not, and the reason is retrievable by
##      id.** There is no `seq[PluginId]` of survivors with the failures
##      thrown away, because a caller that wants to tell a user why their
##      plugin is absent needs the reason, and §4.1 says the user is told.
##   2. **A failure propagates to dependents transitively.** `pecBlocked-
##      ByDependency` names the plugin that failed, not the immediate edge, so
##      a chain of five reports the same root cause five times rather than
##      four "blocked by something that was blocked".
##   3. **`order` is a topological order of the LOADABLE set only.** A caller
##      walking it to activate cannot reach a plugin whose dependency failed,
##      because it is not in the list.
##
## ## CYCLES NAME THEMSELVES
##
## A cycle is reported as the path `a -> b -> c -> a`, once per participating
## plugin (each naming itself first, so the error a user sees about THEIR
## plugin starts with their plugin). "There is a cycle" without the path is
## the diagnostic equivalent of a blank tab.
##
## ## NO MOCKS AND NOTHING TO MOCK
##
## Every input is a value. There is no clock, no filesystem, no process and no
## collaborator here to stand in for.

import std/[algorithm, sets, strutils, tables]

import ./diagnostics
import ./manifest

export diagnostics, manifest

type
  Resolution* = object
    manifests*: Table[PluginId, PluginManifest]
      ## Every manifest that PARSED, loadable or not. A blocked plugin is
      ## still describable, which is what lets a UI list it as present and
      ## unavailable rather than as absent.
    order*: seq[PluginId]
      ## Topological, dependencies first, over the loadable set. Ties are
      ## broken by id so the order is a function of the input and not of the
      ## hash seed — a resolution that reordered between runs would make
      ## "activated in dependency order" untestable.
    errors*: seq[PluginError]
      ## Every failure, in the order discovered. Never truncated.
    failed*: Table[PluginId, PluginError]
      ## The FIRST error attributed to each plugin — what a user is shown
      ## beside that plugin's name.

func isLoadable*(r: Resolution; id: PluginId): bool =
  r.manifests.hasKey(id) and not r.failed.hasKey(id)

func failureFor*(r: Resolution; id: PluginId): PluginError =
  ## The failure, or an error whose `code` is `pecMissingDependency` and whose
  ## detail says the plugin is unknown. Callers check `isLoadable` first; this
  ## exists so a diagnostic path cannot crash a host.
  if r.failed.hasKey(id): r.failed[id]
  else: pluginError(id, pecMissingDependency, "no such plugin in the registry")

proc note(r: var Resolution; e: PluginError) =
  r.errors.add e
  if not r.failed.hasKey(e.plugin):
    r.failed[e.plugin] = e

proc detectCycles(deps: Table[PluginId, seq[PluginId]];
                  ids: seq[PluginId]): seq[seq[PluginId]] =
  ## Every elementary cycle reachable by depth-first search, as a path whose
  ## first and last elements are the same plugin.
  ##
  ## Iterative with an explicit stack rather than recursive: a manifest set is
  ## user input, and a deep chain must produce an error rather than a stack
  ## overflow.
  var colour = initTable[PluginId, int]()   # 0 white, 1 grey, 2 black
  for id in ids: colour[id] = 0
  var found: seq[seq[PluginId]] = @[]
  var seenCycle = initHashSet[string]()

  for root in ids:
    if colour[root] != 0: continue
    var path: seq[PluginId] = @[]
    # (node, index of the next child to visit)
    var stack: seq[(PluginId, int)] = @[(root, 0)]
    colour[root] = 1
    path.add root
    while stack.len > 0:
      let (node, childIdx) = stack[^1]
      let children =
        if deps.hasKey(node): deps[node] else: newSeq[PluginId]()
      if childIdx >= children.len:
        colour[node] = 2
        discard path.pop()
        discard stack.pop()
        continue
      stack[^1] = (node, childIdx + 1)
      let child = children[childIdx]
      if not colour.hasKey(child):
        continue                      # a missing dependency, reported elsewhere
      if colour[child] == 1:
        # Back edge: the cycle is the tail of `path` from `child` onward.
        var start = -1
        for i in 0 ..< path.len:
          if path[i] == child:
            start = i
            break
        if start >= 0:
          var cyc = path[start .. ^1]
          cyc.add child
          # Deduplicate by the SET of participants, so one cycle discovered
          # from three different roots is one finding rather than three.
          var members = cyc[0 .. ^2]
          members.sort()
          let key = members.join("|")
          if key notin seenCycle:
            seenCycle.incl key
            found.add cyc
      elif colour[child] == 0:
        colour[child] = 1
        path.add child
        stack.add (child, 0)
  found

func cyclePath(cyc: seq[PluginId]): string =
  cyc.join(" -> ")

func rotateTo(cyc: seq[PluginId]; id: PluginId): seq[PluginId] =
  ## The same cycle written so that it starts and ends at `id`. A user reading
  ## the error attached to their plugin should see their plugin first.
  let members = cyc[0 .. ^2]
  var start = 0
  for i, m in members:
    if m == id:
      start = i
      break
  for i in 0 ..< members.len:
    result.add members[(start + i) mod members.len]
  result.add id

proc resolve*(parsed: seq[ParsedManifest]; coreVersion: SemVer): Resolution =
  ## The whole registry, in one pass, before anything is activated.
  ##
  ## Phases, in order, because each depends on the previous having run over
  ## EVERY plugin rather than over the one being considered:
  ##
  ##   1. parse errors carried through, and duplicate ids;
  ##   2. the core version requirement;
  ##   3. activation events naming a command nobody contributes;
  ##   4. dependency existence and version;
  ##   5. cycles;
  ##   6. transitive blocking;
  ##   7. the topological order over what is left.
  result.manifests = initTable[PluginId, PluginManifest]()
  result.failed = initTable[PluginId, PluginError]()

  # --- phase 1: parse errors and duplicate identity ------------------------
  var ids: seq[PluginId] = @[]
  for p in parsed:
    for e in p.errors:
      result.note e
    if not p.isOk:
      # A manifest that did not parse still occupies its id, so a dependent
      # is blocked by it rather than told the dependency is missing. That
      # distinction is what makes the blocked error point at the real fault.
      if p.manifest.id.len > 0 and not result.manifests.hasKey(p.manifest.id):
        result.manifests[p.manifest.id] = p.manifest
        ids.add p.manifest.id
      continue
    if result.manifests.hasKey(p.manifest.id):
      result.note pluginError(p.manifest.id, pecDuplicatePlugin,
        "two manifests declare id '" & p.manifest.id & "'")
      continue
    result.manifests[p.manifest.id] = p.manifest
    ids.add p.manifest.id
  ids.sort()

  # --- phase 2: the core requirement ---------------------------------------
  for id in ids:
    let m = result.manifests[id]
    if result.failed.hasKey(id): continue
    if not coreVersion.satisfies(m.coreVersion):
      result.note pluginError(id, pecCoreTooOld,
        "requires core " & describe(m.coreVersion) & "; this core is " &
        $coreVersion)

  # --- phase 3: activation naming a command nobody contributes -------------
  # §4.1's rule reaches activation events as well as contributions: a plugin
  # that activates on `acme.show` when no plugin in the registry contributes
  # that command would never activate, and "never activates" is precisely the
  # silently missing feature the rule forbids.
  var allCommands = initHashSet[string]()
  for id in ids:
    for c in result.manifests[id].commandIds():
      allCommands.incl c
  for id in ids:
    if result.failed.hasKey(id): continue
    for a in result.manifests[id].activation:
      if a.kind == aeCommand and a.value notin allCommands:
        result.note pluginError(id, pecUnknownCommand,
          "activates on command '" & a.value &
          "', which no plugin in this registry contributes")

  # --- phase 4: dependency existence and version ---------------------------
  var deps = initTable[PluginId, seq[PluginId]]()
  for id in ids:
    # The EDGES are computed for every plugin, including one that has already
    # failed, because phases 5 and 6 walk the whole graph and a missing entry
    # would make a cycle through a failed plugin invisible. Only the REPORTING
    # is suppressed for an already-failed plugin, so a manifest with a bad
    # version does not also collect a dependency complaint about itself.
    let quiet = result.failed.hasKey(id)
    var edges: seq[PluginId] = @[]
    for d in result.manifests[id].dependencies:
      if not result.manifests.hasKey(d.id):
        if not quiet:
          result.note pluginError(id, pecMissingDependency,
            "requires '" & d.id & "' " & describe(d.range) &
            ", which is not installed")
        continue
      edges.add d.id
      let have = result.manifests[d.id].version
      if not have.satisfies(d.range) and not quiet:
        result.note pluginError(id, pecVersionConflict,
          "requires '" & d.id & "' " & describe(d.range) &
          " but the installed version is " & $have)
    deps[id] = edges

  # --- phase 5: cycles ------------------------------------------------------
  for cyc in detectCycles(deps, ids):
    for member in cyc[0 .. ^2]:
      if result.failed.hasKey(member) and
         result.failed[member].code == pecDependencyCycle:
        continue
      result.note pluginError(member, pecDependencyCycle,
        cyclePath(rotateTo(cyc, member)))

  # --- phase 6: transitive blocking ----------------------------------------
  # Fixed point rather than one pass: a chain a -> b -> c whose `c` failed
  # must block `b` and then `a`, and a single sweep in id order would block
  # only whichever happened to come after its dependency alphabetically.
  var changed = true
  while changed:
    changed = false
    for id in ids:
      if result.failed.hasKey(id): continue
      for dep in deps[id]:
        if result.failed.hasKey(dep):
          let rootCause = result.failed[dep]
          result.note pluginError(id, pecBlockedByDependency,
            "'" & dep & "' failed to load (" & codeText(rootCause.code) &
            "), so this plugin is not activated at all rather than half-alive")
          changed = true
          break

  # --- phase 7: the topological order over the loadable set ----------------
  var loadable: seq[PluginId] = @[]
  for id in ids:
    if not result.failed.hasKey(id): loadable.add id
  var emitted = initHashSet[PluginId]()
  # Kahn's algorithm with a sorted ready set: deterministic, and it cannot
  # loop, because every cycle member was removed in phase 5/6.
  var remaining = loadable
  while remaining.len > 0:
    var ready: seq[PluginId] = @[]
    for id in remaining:
      var satisfiedDeps = true
      for dep in deps[id]:
        if dep in emitted: continue
        # A dependency outside the loadable set cannot exist here: it would
        # have blocked `id` in phase 6.
        satisfiedDeps = false
        break
      if satisfiedDeps: ready.add id
    if ready.len == 0:
      # Unreachable given phases 5 and 6. Reported rather than looped, per
      # Verification-Harness-Traps' rule that an impossible state must be
      # loud: a `while` that cannot make progress is a hang, and a hang is
      # the one failure a test cannot read.
      for id in remaining:
        result.note pluginError(id, pecDependencyCycle,
          "unresolved after cycle removal — this is a defect in resolve()")
      break
    ready.sort()
    for id in ready:
      emitted.incl id
      result.order.add id
    var next: seq[PluginId] = @[]
    for id in remaining:
      if id notin emitted: next.add id
    remaining = next

func dependencyClosure*(r: Resolution; id: PluginId): seq[PluginId] =
  ## `id` preceded by every plugin it depends on, transitively, in `r.order`'s
  ## order. This is what an activation must walk: §4.2's "all-or-nothing per
  ## dependency subtree" is only meaningful if a dependency is activated
  ## before the plugin that needs it.
  if not r.isLoadable(id): return @[]
  var wanted = initHashSet[PluginId]()
  var frontier = @[id]
  while frontier.len > 0:
    let cur = frontier.pop()
    if cur in wanted: continue
    wanted.incl cur
    if r.manifests.hasKey(cur):
      for d in r.manifests[cur].dependencies:
        if r.isLoadable(d.id): frontier.add d.id
  for candidate in r.order:
    if candidate in wanted: result.add candidate
