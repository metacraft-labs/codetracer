## plugin_model_test.nim — PLAT-7's contract suite for the PURE half of the
## plugin substrate: the manifest, its load-time validation, the DAG resolver
## and the activation planner.
##
## ## NO MOCKS
##
## There is no mock in this file and none is justified, because there is
## nothing to mock. `common/plugin_model` imports `std/[json, strutils,
## tables, sets, algorithm]` and `common/view_vocabulary`, and nothing else.
## Every manifest below is a JSON string — the same bytes a plugin would ship
## — not a stand-in for a collaborator. There is no clock, no filesystem, no
## process and no reactive graph here; those live on the other side of
## `plugin_host/`, and `test_plugin_lifecycle.nim` drives them for real.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## `unittest.check` inside a plain `proc` assigns a MODULE-LEVEL
## `testStatusIMPL` and leaves the running test's own status untouched — the
## test prints its failed comparison and still reports `[OK]`. **Every
## assertion helper in this file is a `template`.** The two sweeps PLAT-7 ran
## are recorded in the milestone: a direct one for `check` inside `proc`, and
## a WRAPPER-AWARE one, because a suite that asserts only through `ck` is
## invisible to a scanner looking for the word `check`.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)
##
## Every assertion goes through `ck`, and the last case asserts the tally
## against a number written from a run. A branch that returned early, a loop
## that skipped an entry, or a `continue` that dropped a case cannot reach the
## end of this file with the right count.
##
## ## THE ERROR SWEEP, AND ITS CONTROL
##
## §4.1's rule is that a load-time error NAMES THE EXTENSION. Asserting that
## per case would assert it for the cases somebody remembered. Instead every
## error this file constructs is accumulated in `allErrorsSeen` and swept at
## the end — and the sweep's own positive control is one hand-built error with
## an empty `plugin`, which `namesPlugin` must answer `false` for. A sweep
## that could only say yes is Verification-Harness-Traps §4 with a different
## coat on.

import std/[strutils, tables, unittest]

import plugin_model

var countedAssertions = 0
var allErrorsSeen: seq[PluginError] = @[]

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template remember(errs: seq[PluginError]) =
  ## Feed the end-of-file sweep. A template rather than a proc for trap 13's
  ## reason even though it contains no `check` today — a helper that grows an
  ## assertion later must not have to be converted then.
  for e in errs:
    allErrorsSeen.add e

template ckRefused(errs: seq[PluginError]; expected: PluginErrorCode) =
  ## A refusal asserted AS a refusal — by code, never by "there was an error".
  ## Verification-Harness-Traps §4b: a test that checks only `errs.len > 0`
  ## passes when the manifest was refused for an unrelated reason.
  let es = errs
  remember(es)
  checkpoint("errors were:\n" & renderAll(es))
  var got = false
  for e in es:
    if e.code == expected: got = true
  ck got

template ckAccepted(p: ParsedManifest) =
  let parsed = p
  remember(parsed.errors)
  checkpoint("errors were:\n" & renderAll(parsed.errors))
  ck parsed.isOk

const CoreVersion = semver(1, 4, 0)

# ---------------------------------------------------------------------------
# Fixtures. Written as JSON text because that is what a plugin ships; a
# fixture built as a Nim object would skip the parser that half these cases
# are about.
# ---------------------------------------------------------------------------

proc manifestText(id: string; version = "1.0.0"; body = ""): string =
  result = "{\n  \"id\": \"" & id & "\",\n  \"version\": \"" & version & "\""
  if body.len > 0:
    result.add ",\n" & body
  result.add "\n}"

proc parseOne(id: string; version = "1.0.0"; body = ""): ParsedManifest =
  parseManifest(manifestText(id, version, body), id & ".json")

proc resolveOf(ms: varargs[ParsedManifest]): Resolution =
  var all: seq[ParsedManifest] = @[]
  for m in ms: all.add m
  resolve(all, CoreVersion)

# ---------------------------------------------------------------------------

suite "PLAT-7 manifest: identity, version, capabilities, contributions":

  test "a complete manifest parses, and every field survives the round trip":
    let p = parseOne("acme.heatmap", "2.3.1", """
  "displayName": "Heat map",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "capabilities": ["trace", "socket:local"],
  "activation": [
    { "event": "trace-opened" },
    { "event": "language", "value": "rust" },
    { "event": "command", "value": "acme.heatmap.show" }
  ],
  "contributes": {
    "pane": [ { "id": "acme.heatmap.pane", "views": ["Table", "Text"] } ],
    "command": [ { "id": "acme.heatmap.show", "title": "Show heat map" } ],
    "viewModel": [ { "id": "acme.heatmap.model", "version": "1.1.0" } ],
    "marker": [ { "id": "acme.heatmap.gutter" } ],
    "statusItem": [ { "id": "acme.heatmap.status" } ]
  }""")
    ckAccepted p
    let m = p.manifest
    ck m.id == "acme.heatmap"
    ck $m.version == "2.3.1"
    ck m.displayName == "Heat map"
    ck m.capabilities == {capTrace, capSocketLocal}
    ck m.activation.len == 3
    ck m.contributions.len == 5
    ck m.contributionsOf(ckPane).len == 1
    ck m.contributionsOf(ckPane)[0].views == @[pkTable, pkText]
    ck m.commandIds() == @["acme.heatmap.show"]
    ck m.contributionsOf(ckViewModel)[0].version == semver(1, 1, 0)
    # THE CAPABILITY THAT IS NOT THERE. §8.1.2's grants are separate, and a
    # manifest declaring two of six must not acquire a third.
    ck capSocketRemote notin m.capabilities
    ck capProcess notin m.capabilities

  test "the six capability names are the spec's own spellings":
    # §8.1.2's table. Written out here rather than derived, because this is
    # the one place where a copy is the point: if the enum's string values
    # were renamed, every manifest in the wild would break and this case is
    # what says so.
    var seen = 0
    for c in Capability:
      ck ($c) in ["process", "socket:local", "socket:remote", "fs:read",
                  "fs:write", "trace"]
      inc seen
    ck seen == 6

  test "an unknown capability is refused, naming the plugin and the set":
    let p = parseOne("acme.rogue", body = """
  "capabilities": ["trace", "kernel"]""")
    ckRefused p.errors, pecUnknownCapability
    ck renderAll(p.errors).contains("acme.rogue")
    ck renderAll(p.errors).contains("socket:remote")

  test "an unknown contribution surface is refused":
    let p = parseOne("acme.rogue", body = """
  "contributes": { "sidebar": [ { "id": "x" } ] }""")
    ckRefused p.errors, pecUnknownContribution

  test "a malformed version is refused rather than defaulted":
    ckRefused parseOne("acme.x", "2.3").errors, pecBadVersion
    ckRefused parseOne("acme.x", "v2.3.1").errors, pecBadVersion
    ckRefused parseOne("acme.x", "2.3.1-rc1").errors, pecBadVersion
    ckAccepted parseOne("acme.x", "0.0.1")

  test "a manifest with no id still produces an error that names something":
    let p = parseManifest("""{ "version": "1.0.0" }""", "nameless.json")
    ckRefused p.errors, pecMissingField
    ck p.errors[0].plugin == UnknownPluginId
    ck render(p.errors[0]).contains("nameless.json")

  test "text that is not JSON at all is a manifest error, not a crash":
    ckRefused parseManifest("not json", "broken.json").errors,
      pecMalformedManifest
    ckRefused parseManifest("[1, 2, 3]", "array.json").errors,
      pecMalformedManifest

suite "PLAT-7 manifest: a manifest naming something that does not exist":

  test "a pane naming a view outside PLAT-3's sixteen fails, naming both":
    let p = parseOne("acme.sparkles", body = """
  "contributes": {
    "pane": [ { "id": "acme.sparkles.pane", "views": ["Text", "Sparkline"] } ]
  }""")
    ckRefused p.errors, pecUnknownView
    let text = renderAll(p.errors)
    # The plugin, the surface, the offending entry, and the closed set.
    ck text.contains("acme.sparkles")
    ck text.contains("acme.sparkles.pane")
    ck text.contains("Sparkline")
    ck text.contains("ProgressIndicator")

  test "all sixteen of PLAT-3's entries are accepted by name":
    # DERIVED FROM THE VOCABULARY, not from a list written here. A
    # seventeenth entry admitted by PLAT-3 lands in this case without an
    # edit, and a renamed one reddens it.
    var names: seq[string] = @[]
    for n in knownViewNames():
      names.add "\"" & n & "\""
    ck names.len == 16
    let p = parseOne("acme.everything", body = """
  "contributes": {
    "pane": [ { "id": "acme.everything.pane", "views": [""" &
      names.join(", ") & """] } ]
  }""")
    ckAccepted p
    ck p.manifest.contributionsOf(ckPane)[0].views.len == 16

  test "an unknown activation event is refused, listing the declared set":
    let p = parseOne("acme.guess", body = """
  "activation": [ { "event": "on-tuesday" } ]""")
    ckRefused p.errors, pecUnknownActivation
    ck renderAll(p.errors).contains("trace-opened")

  test "an activation event that needs an argument and has none is refused":
    ckRefused parseOne("acme.a", body = """
  "activation": [ { "event": "language" } ]""").errors,
      pecActivationValueMissing
    ckRefused parseOne("acme.b", body = """
  "activation": [ { "event": "command" } ]""").errors,
      pecActivationValueMissing
    # `trace-opened` needs none, and must not be refused for lacking one.
    ckAccepted parseOne("acme.c", body = """
  "activation": [ { "event": "trace-opened" } ]""")

  test "activating on a command nobody contributes is a load-time error":
    # The same rule as the unknown view, one level up: a plugin whose only
    # activation event can never occur would never activate, and "never
    # activates" IS the silently missing feature §4.1 forbids.
    let p = parseOne("acme.ghost", body = """
  "activation": [ { "event": "command", "value": "acme.ghost.nowhere" } ]""")
    ckAccepted p                       # the manifest itself is well-formed
    let r = resolveOf(p)
    remember r.errors
    ck not r.isLoadable("acme.ghost")
    ck r.failureFor("acme.ghost").code == pecUnknownCommand
    ck render(r.failureFor("acme.ghost")).contains("acme.ghost.nowhere")

  test "the same activation is fine when a plugin contributes the command":
    let provider = parseOne("acme.tools", body = """
  "contributes": { "command": [ { "id": "acme.tools.run" } ] }""")
    let user = parseOne("acme.ghost", body = """
  "activation": [ { "event": "command", "value": "acme.tools.run" } ]""")
    let r = resolveOf(provider, user)
    remember r.errors
    ck r.errors.len == 0
    ck r.isLoadable("acme.ghost")

suite "PLAT-7: lazy by default, eager only with a stated reason":

  test "eager activation without a reason is refused at load":
    let p = parseOne("acme.greedy", body = """
  "activation": [ { "event": "startup" } ]""")
    ckRefused p.errors, pecEagerWithoutReason
    ck renderAll(p.errors).contains("slow startup")

  test "eager activation with a reason is accepted and the reason is kept":
    let p = parseOne("acme.greedy", body = """
  "activation": [ { "event": "startup",
                    "reason": "installs the trace-format decoder that every other plugin resolves against" } ]""")
    ckAccepted p
    ck p.manifest.activatesEagerly()
    ck p.manifest.eagerReasons()["startup"].contains("decoder")

  test "a plugin with no startup event is lazy, and is not in the eager plan":
    let lazy = parseOne("acme.lazy", body = """
  "activation": [ { "event": "trace-opened" } ]""")
    let eager = parseOne("acme.eager", body = """
  "activation": [ { "event": "startup", "reason": "owns the command palette" } ]""")
    let r = resolveOf(lazy, eager)
    remember r.errors
    ck r.errors.len == 0
    ck eagerPlan(r) == @["acme.eager"]
    ck lazyPlugins(r) == @["acme.lazy"]
    ck eagerReasonsIn(r).len == 1
    ck eagerReasonsIn(r)["acme.eager"] == "owns the command palette"

  test "a plugin activates on the event it declared and on no other":
    let p = parseOne("acme.noir", body = """
  "activation": [ { "event": "language", "value": "noir" } ]""")
    let r = resolveOf(p)
    remember r.errors
    ck plan(r, occurrence(aeLanguage, "noir")) == @["acme.noir"]
    ck plan(r, occurrence(aeLanguage, "rust")).len == 0
    ck plan(r, occurrence(aeTraceOpened)).len == 0
    ck plan(r, occurrence(aeStartup)).len == 0

suite "PLAT-7: resolution is a DAG, and it is total":

  test "dependencies come first in the order, transitively":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": "^1.0.0" } }""")
    let b = parseOne("acme.b", body = """
  "requires": { "plugins": { "acme.c": "^1.0.0" } }""")
    let c = parseOne("acme.c")
    let r = resolveOf(a, b, c)
    remember r.errors
    ck r.errors.len == 0
    ck r.order == @["acme.c", "acme.b", "acme.a"]
    ck r.dependencyClosure("acme.a") == @["acme.c", "acme.b", "acme.a"]
    ck r.dependencyClosure("acme.c") == @["acme.c"]

  test "an activation plan carries the dependency closure, in order":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": "^1.0.0" } },
  "activation": [ { "event": "trace-opened" } ]""")
    let b = parseOne("acme.b")
    let r = resolveOf(a, b)
    remember r.errors
    # `acme.b` declares NO activation event and is still in the plan, because
    # `acme.a` cannot run without it. A plan that contained only the declaring
    # plugin would activate it half-alive.
    ck plan(r, occurrence(aeTraceOpened)) == @["acme.b", "acme.a"]

  test "a missing dependency fails the dependent, naming both":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.missing": "^1.0.0" } }""")
    let r = resolveOf(a)
    remember r.errors
    ck not r.isLoadable("acme.a")
    ck r.failureFor("acme.a").code == pecMissingDependency
    let text = render(r.failureFor("acme.a"))
    ck text.contains("acme.a")
    ck text.contains("acme.missing")

  test "a dependency at an unacceptable version is a conflict, not a miss":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": ">=2.0.0 <3.0.0" } }""")
    let b = parseOne("acme.b", "1.9.9")
    let r = resolveOf(a, b)
    remember r.errors
    ck r.failureFor("acme.a").code == pecVersionConflict
    ck render(r.failureFor("acme.a")).contains("1.9.9")
    # And the dependency itself is unharmed: §4.2's rule is per subtree, and
    # `acme.b` has no failing dependency.
    ck r.isLoadable("acme.b")

  test "a failure blocks every dependent transitively, all-or-nothing":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": "^1.0.0" } }""")
    let b = parseOne("acme.b", body = """
  "requires": { "plugins": { "acme.c": "^1.0.0" } }""")
    let c = parseOne("acme.c", body = """
  "capabilities": ["telepathy"]""")     # the root cause
    let r = resolveOf(a, b, c)
    remember r.errors
    ck r.failureFor("acme.c").code == pecUnknownCapability
    ck r.failureFor("acme.b").code == pecBlockedByDependency
    ck r.failureFor("acme.a").code == pecBlockedByDependency
    ck r.order.len == 0
    # THE BLOCKED ERROR NAMES THE PLUGIN THAT FAILED, not "something upstream".
    ck render(r.failureFor("acme.b")).contains("acme.c")
    ck render(r.failureFor("acme.a")).contains("acme.b")

  test "a healthy sibling of a failed subtree still loads":
    let bad = parseOne("acme.bad", body = """
  "capabilities": ["telepathy"]""")
    let good = parseOne("acme.good")
    let r = resolveOf(bad, good)
    remember r.errors
    ck not r.isLoadable("acme.bad")
    ck r.isLoadable("acme.good")
    ck r.order == @["acme.good"]

  test "a two-plugin cycle is an error naming the cycle, on both plugins":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": "^1.0.0" } }""")
    let b = parseOne("acme.b", body = """
  "requires": { "plugins": { "acme.a": "^1.0.0" } }""")
    let r = resolveOf(a, b)
    remember r.errors
    ck r.failureFor("acme.a").code == pecDependencyCycle
    ck r.failureFor("acme.b").code == pecDependencyCycle
    # Each names the WHOLE path, starting at the plugin the error is about.
    ck r.failureFor("acme.a").detail == "acme.a -> acme.b -> acme.a"
    ck r.failureFor("acme.b").detail == "acme.b -> acme.a -> acme.b"
    ck r.order.len == 0

  test "a three-plugin cycle names all three, in path order":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.b": "^1.0.0" } }""")
    let b = parseOne("acme.b", body = """
  "requires": { "plugins": { "acme.c": "^1.0.0" } }""")
    let c = parseOne("acme.c", body = """
  "requires": { "plugins": { "acme.a": "^1.0.0" } }""")
    let r = resolveOf(a, b, c)
    remember r.errors
    ck r.failureFor("acme.a").detail == "acme.a -> acme.b -> acme.c -> acme.a"
    ck r.failureFor("acme.b").detail == "acme.b -> acme.c -> acme.a -> acme.b"
    ck r.failureFor("acme.c").detail == "acme.c -> acme.a -> acme.b -> acme.c"

  test "a self-dependency is a cycle of one, and says so":
    let a = parseOne("acme.a", body = """
  "requires": { "plugins": { "acme.a": "^1.0.0" } }""")
    let r = resolveOf(a)
    remember r.errors
    ck r.failureFor("acme.a").code == pecDependencyCycle
    ck r.failureFor("acme.a").detail == "acme.a -> acme.a"

  test "two manifests claiming one id is a duplicate error":
    let r = resolveOf(parseOne("acme.a", "1.0.0"), parseOne("acme.a", "2.0.0"))
    remember r.errors
    ck r.failureFor("acme.a").code == pecDuplicatePlugin

  test "a core requirement the host does not meet fails, naming both versions":
    let old = parseOne("acme.future", body = """
  "requires": { "core": ">=9.0.0" }""")
    let r = resolveOf(old)
    remember r.errors
    ck r.failureFor("acme.future").code == pecCoreTooOld
    ck render(r.failureFor("acme.future")).contains("9.0.0")
    ck render(r.failureFor("acme.future")).contains($CoreVersion)

suite "PLAT-7: version ranges":

  test "the caret means the next major, and below 1.0.0 the next minor":
    var r: VersionRange
    ck parseVersionRange("^1.2.0", r)
    ck semver(1, 2, 0).satisfies(r)
    ck semver(1, 9, 9).satisfies(r)
    ck not semver(1, 1, 9).satisfies(r)
    ck not semver(2, 0, 0).satisfies(r)
    ck parseVersionRange("^0.2.0", r)
    ck semver(0, 2, 7).satisfies(r)
    ck not semver(0, 3, 0).satisfies(r)

  test "an explicit conjunction, an exact pin, and the wildcard":
    var r: VersionRange
    ck parseVersionRange(">=1.0.0 <1.5.0", r)
    ck semver(1, 4, 9).satisfies(r)
    ck not semver(1, 5, 0).satisfies(r)
    ck parseVersionRange("=1.4.0", r)
    ck semver(1, 4, 0).satisfies(r)
    ck not semver(1, 4, 1).satisfies(r)
    ck parseVersionRange("*", r)
    ck r.bounds.len == 0
    ck semver(99, 0, 0).satisfies(r)

  test "an unreadable range is refused rather than treated as permissive":
    var r: VersionRange
    ck not parseVersionRange("1.2.0", r)      # no operator
    ck not parseVersionRange("~1.2.0", r)     # tilde is not supported
    ck not parseVersionRange(">=1.2", r)      # not three components
    ck not parseVersionRange("", r)
    ckRefused parseOne("acme.a", body = """
  "requires": { "core": "~1.0.0" }""").errors, pecBadVersionRange

suite "PLAT-7: every load-time error names the plugin":

  test "the sweep over every error this file produced":
    # THE SWEEP. Not "the cases I remembered", but every error constructed
    # anywhere above — `ckRefused`, `ckAccepted` and `remember` all feed it.
    checkpoint("swept " & $allErrorsSeen.len & " errors")
    ck allErrorsSeen.len >= 25
    var offenders: seq[string] = @[]
    for e in allErrorsSeen:
      if not e.namesPlugin():
        offenders.add render(e)
    if offenders.len > 0:
      checkpoint(offenders.join("\n"))
    ck offenders.len == 0

  test "the sweep's own control: it can answer no":
    # Verification-Harness-Traps §4 — a scanner that finds nothing passes
    # every "must not contain" check. This is the same predicate, on the same
    # code path, handed an error it must reject.
    let anonymous = PluginError(plugin: "", code: pecMalformedManifest,
                                detail: "who wrote this")
    ck not anonymous.namesPlugin()
    ck pluginError("acme.a", pecMalformedManifest, "x").namesPlugin()

  test "every error code has its own text, and none is empty":
    var seen: Table[string, PluginErrorCode]
    seen = initTable[string, PluginErrorCode]()
    var n = 0
    for c in PluginErrorCode:
      let t = codeText(c)
      ck t.len > 0
      ck not seen.hasKey(t)
      seen[t] = c
      inc n
    ck n == 17

suite "PLAT-7: the counted-assertion tally":

  test "the tally":
    # Written from a run. See the header, Verification-Harness-Traps §4c.
    check countedAssertions == 162
