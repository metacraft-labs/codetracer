## plugin_model/activation.nim — PLAT-7 deliverable 3, the planning half.
## "Lazy activation on declared events; eager activation requires a stated
## reason."
##
## ## WHAT A PLAN IS, AND WHY IT IS A VALUE
##
## An activation plan is the ordered list of plugin ids an event should bring
## up: every plugin that declared the event, each preceded by its dependency
## closure, deduplicated, in the resolution's topological order.
##
## It is computed here — with no owner, no effect and no clock — so that "the
## right plugins, in the right order" is testable without a reactive runtime,
## and so the runtime half (`plugin_host/host.nim`) has exactly one decision
## left to make: create the scope and run the plugin's `activate`.
##
## ## LAZY IS THE DEFAULT AND EAGER IS A DECLARATION
##
## `eagerPlan` is the startup plan and it contains only plugins that declared
## `startup` WITH a reason — a plugin cannot reach it by omission, because
## `manifest.parseManifest` refuses `{"event": "startup"}` with no `reason` at
## load time. So the set of plugins paid for at startup is exactly the set
## whose authors wrote down why, and `eagerReasonsIn` is what a `--why-slow`
## style report reads.
##
## ## MATCHING IS EXACT, NOT PREFIX AND NOT GLOB
##
## `language:rust` matches `language:rust` and nothing else. A glob would make
## "which plugins does this event start" a question whose answer depends on a
## pattern language, and the first thing a pattern language acquires is a
## pattern that matches more than its author meant.

import std/[sets, tables]

import ./diagnostics
import ./manifest
import ./resolution

export diagnostics, manifest, resolution

func occurrence*(kind: ActivationEventKind; value = ""): ActivationEvent =
  ## An event that HAPPENED, as opposed to one a manifest declared. The same
  ## type carries both, deliberately: a declaration and an occurrence that
  ## could not be compared for equality would need a translation between them,
  ## and a translation is a place for a mismatch to hide.
  ActivationEvent(kind: kind, value: value)

func matches*(declared, occurred: ActivationEvent): bool =
  ## Exact on kind, and exact on value where the kind carries one.
  if declared.kind != occurred.kind: return false
  if declared.kind in EventsNeedingValue:
    return declared.value == occurred.value
  true

func declaresEvent*(m: PluginManifest; occurred: ActivationEvent): bool =
  for a in m.activation:
    if a.matches(occurred): return true
  false

proc plan*(r: Resolution; occurred: ActivationEvent): seq[PluginId] =
  ## The ordered activation plan for one event.
  ##
  ## A plugin appears only if it is LOADABLE — §4.2's "an extension whose
  ## dependency failed does not activate half-alive" is enforced by the plan
  ## not containing it, rather than by a check at activation time that
  ## somebody could forget to write.
  var wanted = initHashSet[PluginId]()
  for id in r.order:
    if not r.manifests.hasKey(id): continue
    if r.manifests[id].declaresEvent(occurred):
      for dep in r.dependencyClosure(id):
        wanted.incl dep
  for id in r.order:
    if id in wanted: result.add id

proc eagerPlan*(r: Resolution): seq[PluginId] =
  ## Everything that activates at startup, with its dependencies, in order.
  plan(r, occurrence(aeStartup))

proc eagerReasonsIn*(r: Resolution): Table[PluginId, string] =
  ## Why each eager plugin says it must be eager. This is the report §4.2's
  ## rule exists to make possible: a startup that got slow is answerable by
  ## reading the reasons rather than by profiling.
  result = initTable[PluginId, string]()
  for id in r.order:
    if not r.manifests.hasKey(id): continue
    for a in r.manifests[id].activation:
      if a.isEager:
        result[id] = a.reason

proc lazyPlugins*(r: Resolution): seq[PluginId] =
  ## Every loadable plugin that is NOT eager. The complement is worth having
  ## by name: a suite asserting "eager is the exception" needs both sides, and
  ## deriving one from the other at the call site is how the two drift.
  for id in r.order:
    if r.manifests.hasKey(id) and not r.manifests[id].activatesEagerly():
      result.add id
