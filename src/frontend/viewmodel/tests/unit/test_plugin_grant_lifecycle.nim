## test_plugin_grant_lifecycle.nim — PLAT-10 deliverable 3, against the real
## host, the real capability policy and the real kernel.
##
## > "The capability grant recorded per plugin, inspectable and revocable. […]
## >  A user who granted `process` to a plugin last month must be able to see
## >  that and take it back."
##
## and the one place PLAT-10 asks for adversarial reading:
##
## > "A revoked grant must actually be revoked. If revocation only edits a
## >  record that nothing consults on the next activation, it is theatre.
## >  Assert that a plugin whose grant was revoked cannot do the thing —
## >  measured against PLAT-8's enforcement, not against the record."
##
## ## HOW THAT IS MEASURED HERE
##
## Every refusal in this file is asserted THREE ways, and the third is the one
## that makes the other two worth anything:
##
##   1. the outcome is `ioRefused` and its message names `process`, which is
##      `capabilities.decide`'s own text — so the refusal came from PLAT-8's
##      policy and not from a second gate added by this milestone;
##   2. `effectiveCapabilitiesOf` — the very `set[Capability]` the SDK hands
##      to `decide` — no longer contains the capability;
##   3. **the sentinel file the child process would have created does not
##      exist.** The program is `touch`, from coreutils, spawned through
##      `std/osproc` onto a real `execve`. A host that refused politely and
##      spawned anyway would pass (1) and (2) and fail this.
##
## AND (2) IS A CLAIM ABOUT WHICH STORE IS READ, which is why there is now a
## case whose whole subject is that claim. `effectiveCapabilitiesOf` used to
## read `resolution.manifests` unconditionally, while a LIVE plugin's I/O reads
## `grantsOf(ctx)` — two stores, and (2) was about the one nobody was executing.
## Measured, with mutation arm H1 applied (the arm that stops `applyLedgerTo`
## narrowing the live context):
##
##   | `effectiveCapabilitiesOf` reads | assertion (2) in "a LIVE plugin loses…" |
##   | resolution.manifests (before)   | GREEN — reported `{fs:read}`, child ran |
##   | the live ctx (now)              | red — reported `{process, fs:read}`     |
##
## Only the sentinel file caught H1 before. "The inspection API reads the store
## the SDK reads" is the case that keeps (2) from being about a value nothing
## consults, and it asserts the API against `grantsOf` itself rather than
## against a second spelling of the same field (Verification-Harness-Traps §14).
##
## And the probe can answer both ways, which is what keeps (3) from being
## Verification-Harness-Traps §4's empty set: every revoked-case sentinel path
## is asserted ABSENT before the attempt and the granted-case sentinel is
## asserted PRESENT after one, through the same helper.
##
## ## "SURVIVES A RESTART" IS A SECOND PROCESS-SHAPED THING, NOT A RE-READ
##
## A restart here is a NEW `PluginHost`, built from a fresh `register` /
## `resolveAll` / `activateFor` over a manifest parsed again, with the ledger
## loaded again from the same file on disk. Nothing is carried across in
## memory. That is as close to a restart as a unit lane can get, and the part
## that would break if persistence broke — the file — is the real one.
##
## ## NO MOCKS
##
## The host is PLAT-7's real `PluginHost` over `isonim`'s real reactive graph.
## The plugin is `plugin_fixtures/io_tool_plugin.IoProbePlugin`, a declared
## `.ct-plugin` tree bound by both boundary gates, making its attempts through
## the same SDK a shipped plugin would. The manifests are parsed by the real
## `parseManifest`. The ledger is a real file under a real temporary user root,
## written and read by `src/ct/launch/grant_store.nim`. The child process is
## `touch`.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper here is a `template` — `ck`, `ckEq`, `ckSpawned` and
## `ckRefusedSpawn`. A `check` inside a plain `proc` assigns a module-level
## `testStatusIMPL` and the case reports `[OK]` with the failed comparison
## printed above it.
##
## ## PLATFORM
##
## POSIX. It spawns `touch` and reads `/proc`-free filesystem state; the
## process half of PLAT-8's SDK is `when not defined(js)`, which is why this
## file is rejected from `vm-unit-js` in `ci/lib/test-lane-files.sh` rather
## than guarded with a `when`.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_plugin_grant_lifecycle.nim

import std/[asyncdispatch, os, strutils, tables, times, unittest]

import codetracer_embed
import plugin_host/host
import plugin_host/plugin_io
import plugin_fixtures/io_tool_plugin
import ../../../../ct/launch/grant_store

const ExpectedAssertions = 178
  ## Written from a run, and asserted against the tally at the end of the file.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

const
  CoreVersion = semver(1, 4, 0)
  ProbeId = "grant-probe"
  Tool = "touch"
    ## coreutils. It is declared in the manifest, resolved by the host, and its
    ## whole observable effect is a file that either exists or does not — which
    ## is the measurement this suite is built on.
  GrantedAt = "2026-08-14T09:00:00Z"
  RevokedAt = "2026-09-11T14:30:00Z"
  RegrantedAt = "2026-09-11T15:00:00Z"
  Ack = "this plugin spawns a declared tool, which is the composition the " &
        "trace-egress grant exists to disclose"

# ---------------------------------------------------------------------------
# The world
# ---------------------------------------------------------------------------

proc manifestText(caps: openArray[string]; execs: openArray[string];
                  reads: openArray[string]): string =
  ## Built as TEXT and parsed by the real `parseManifest`, so a capability
  ## this suite grants is one a real manifest could grant and every
  ## declaration rule PLAT-8 enforces at load time applies here too.
  var quoted: seq[string] = @[]
  for c in caps: quoted.add "\"" & c & "\""
  var body = "{\"id\": \"" & ProbeId & "\", \"version\": \"1.0.0\", " &
    "\"activation\": [{\"event\": \"trace-opened\"}], " &
    "\"capabilities\": [" & quoted.join(", ") & "]"
  if execs.len > 0:
    var e: seq[string] = @[]
    for x in execs: e.add "\"" & x & "\""
    body.add ", \"executables\": [" & e.join(", ") & "]"
  if reads.len > 0:
    var r: seq[string] = @[]
    for x in reads: r.add "\"" & x & "\""
    body.add ", \"paths\": {\"read\": [" & r.join(", ") & "]}"
  if "process" in caps or ("trace" in caps and "socket:remote" in caps):
    body.add ", \"traceEgress\": {\"acknowledged\": true, \"statement\": \"" &
      Ack & "\"}"
  body & "}"

type
  World = object
    ## One "process": a host, its plugin, and the ledger it was started with.
    host: PluginHost
    probe: IoProbePlugin

proc boot(manifest: string; ledger: GrantLedger): World =
  ## A start-up, in the order a front-end would do it: discover, resolve,
  ## attach the grants the user has recorded, then activate.
  result.probe = newIoProbePlugin()
  result.host = newPluginHost(CoreVersion, initDuration(milliseconds = 2000))
  let parsed = result.host.register(manifest, ProbeId & "/plugin.json",
    result.probe.implementation(PluginManifest()).activate)
  doAssert parsed.isOk, "the suite's own manifest does not parse: " &
    renderAll(parsed.errors)
  result.host.resolveAll()
  result.host.attachGrantLedger(ledger)
  discard result.host.activateFor(occurrence(aeTraceOpened))
  doAssert result.host.isActive(ProbeId)
  doAssert not result.probe.ctx.isNil

proc spawnTouch(w: World; sentinel: string): SpawnOutcome =
  ## The plugin — not the suite — reaches for the tool, and the child is
  ## waited for, so "the file is not there" cannot mean "not yet".
  result = waitFor w.probe.attemptSpawn(Tool, @[sentinel])
  if result.status == ioOk:
    discard waitFor result.process.awaitExit()
    closeProcess(result.process)

template ckSpawned(w: World; sentinel: string) =
  ## Permitted AND it happened. Three assertions, because "the outcome said
  ## ok" alone would be satisfied by a spawn that failed silently.
  ck not fileExists(sentinel)          # the probe can answer "no"
  let outcome = spawnTouch(w, sentinel)
  checkpoint("spawn status " & $outcome.status & ": " & outcome.message)
  ckEq outcome.status, ioOk
  ck fileExists(sentinel)

template ckRefusedSpawn(w: World; sentinel: string) =
  ## Refused, by PLAT-8's policy, and the child never ran.
  ck not fileExists(sentinel)
  let outcome = spawnTouch(w, sentinel)
  checkpoint("spawn status " & $outcome.status & ": " & outcome.message)
  ckEq outcome.status, ioRefused
  ck outcome.message.contains("'process'")
  ck outcome.message.contains(ProbeId)
  ck capProcess notin w.host.effectiveCapabilitiesOf(ProbeId)
  # THE MEASUREMENT. Everything above is a report; this is the world.
  ck not fileExists(sentinel)

# ---------------------------------------------------------------------------

suite "PLAT-10: a granted capability survives a restart":

  setup:
    let tmp = getTempDir() / ("ct-plat10-grant-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmp)
    let priorRoot = getEnv(userRootEnvVar, "")
    let hadRoot = existsEnv(userRootEnvVar)
    putEnv(userRootEnvVar, tmp)
    let full = manifestText(["process", "fs:read"], [Tool], [tmp])

  teardown:
    if hadRoot: putEnv(userRootEnvVar, priorRoot) else: delEnv(userRootEnvVar)
    removeDir(tmp)

  test "a declared capability nobody has granted is refused, and nothing runs":
    # UNDECIDED IS NOT GRANTED. This is the state a freshly installed plugin
    # is in before the user accepts its manifest, and it is what makes the
    # acceptance step below a real event rather than a formality.
    let w = boot(full, loadGrantLedger().ledger)
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsUndecided
    ckRefusedSpawn(w, tmp / "never-touched")

  test "accepting the manifest grants it, and THEN the child runs":
    var w = boot(full, loadGrantLedger().ledger)
    ckRefusedSpawn(w, tmp / "before-accept")
    ckEq w.host.acceptDeclaredGrants(ProbeId, GrantedAt, "accepted at install"), 2
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsGranted
    ck capProcess in w.host.effectiveCapabilitiesOf(ProbeId)
    ckSpawned(w, tmp / "after-accept")

  test "the grant is on disk, and a RESTART finds it there":
    # First process: accept and save.
    var first = boot(full, loadGrantLedger().ledger)
    ckEq first.host.acceptDeclaredGrants(ProbeId, GrantedAt, "accepted"), 2
    ckEq saveGrantLedger(first.host.ledger), ""
    ck fileExists(grantLedgerPath())
    ckSpawned(first, tmp / "first-process")

    # Second process: a NEW host, a NEW registration, a NEW activation, and a
    # ledger read back off the disk. Nothing is carried across in memory.
    let reloaded = loadGrantLedger()
    ckEq reloaded.problems.len, 0
    let second = boot(full, reloaded.ledger)
    ck second.host != first.host
    ck second.probe.ctx != first.probe.ctx
    ckEq second.host.grantStateOf(ProbeId, capProcess), gsGranted
    ckEq second.host.ledger.decidedAt(ProbeId, capProcess), GrantedAt
    ckSpawned(second, tmp / "second-process")

  test "a restart with NO ledger on disk refuses, which is the control":
    # Verification-Harness-Traps §4a. Without this, "the grant survived" would
    # be satisfied by a host that permitted everything regardless of what the
    # file said.
    removeFile(grantLedgerPath())
    let w = boot(full, loadGrantLedger().ledger)
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsUndecided
    ckRefusedSpawn(w, tmp / "no-ledger")

suite "PLAT-10: a revoked capability is refused, not merely recorded":

  setup:
    let tmp = getTempDir() / ("ct-plat10-revoke-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmp)
    let priorRoot = getEnv(userRootEnvVar, "")
    let hadRoot = existsEnv(userRootEnvVar)
    putEnv(userRootEnvVar, tmp)
    let full = manifestText(["process", "fs:read"], [Tool], [tmp])
    var accepted: GrantLedger
    discard accepted.grantDeclared(ProbeId, {capProcess, capFsRead},
                                   GrantedAt, "accepted at install")
    discard saveGrantLedger(accepted)

  teardown:
    if hadRoot: putEnv(userRootEnvVar, priorRoot) else: delEnv(userRootEnvVar)
    removeDir(tmp)

  test "a LIVE plugin loses the capability the moment it is revoked":
    # No restart, no deactivation. `PluginManifest` is a value type, so the
    # running plugin holds its own copy of the grants — this is the case that
    # fails if `applyLedgerTo` narrows only `resolution.manifests`.
    var w = boot(full, loadGrantLedger().ledger)
    ckSpawned(w, tmp / "while-granted")
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt, "taken back")
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsRevoked
    ckRefusedSpawn(w, tmp / "after-revoke-same-session")

  test "re-running discovery does not hand the capability back":
    # THE ATTACK CASE, and the one difference from the case above it is a single
    # public call. `resolveAll` rebuilds `resolution.manifests` from
    # `host.parsed` — the manifests AS PARSED, the one `GrantSet` in the host
    # that is never narrowed — so a second discovery pass used to discard every
    # narrowing `applyLedgerTo` had made, and `activateOne` then copied the
    # widened manifest into the next `ctx`.
    #
    # Measured, before `resolveAll` re-applied the ledger, as an A/B/C isolation
    # over this exact sequence with a real `execve`:
    #
    #   A  revoke, deactivate, activate                -> ioRefused,  no sentinel
    #   B  revoke, resolveAll(), deactivate, activate  -> ioOk,       SENTINEL WRITTEN
    #   C  revoke, resolveAll(), applyLedger(), …      -> ioRefused,  no sentinel
    #
    # In B the ledger still said `gsRevoked` and `report()` still printed
    # "REVOKED" with the date. That is the state PLAT-10's brief names as
    # theatre, reached without touching the ledger at all — and reached through
    # two ordinary public calls, neither of them privileged.
    #
    # THE REVOCATION IS ASSERTED BEFORE THE REDISCOVERY AS WELL AS AFTER IT, so
    # this is not a case that could pass over a host which had simply never
    # granted the capability: the first `ckRefusedSpawn` is the negative half
    # and `ckSpawned` in the cases above is the positive twin over the same
    # probe (Verification-Harness-Traps §4a).
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt, "taken back")
    ckRefusedSpawn(w, tmp / "before-rediscovery")
    w.host.resolveAll()                  # <- the only call the attack adds
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsRevoked
    ck w.host.deactivate(ProbeId)
    discard w.host.activateFor(occurrence(aeTraceOpened))
    ck w.host.isActive(ProbeId)
    ckRefusedSpawn(w, tmp / "after-rediscovery")

  test "the inspection API reads the store the SDK reads, for a LIVE plugin":
    # `effectiveCapabilitiesOf` is assertion (2) of the three this file makes
    # about every refusal, and this header calls it "the very `set[Capability]`
    # the SDK hands to `decide`". That sentence is a claim about WHICH STORE it
    # reads, and it is true or false independently of whether enforcement works
    # — an inspection API that misreports is a wrong sentence, not a wrong
    # permission, so no refusal assertion anywhere can fail on it.
    #
    # There are two stores. A live plugin's I/O reads `grantsOf(ctx)`; a plugin
    # not yet up will be handed `resolution.manifests[id]`. This asserts the
    # inspection API against the FIRST, through `grantsOf` itself rather than
    # through a second spelling of `ctx.manifest.grants`
    # (Verification-Harness-Traps §14), and it asserts it across a revocation so
    # a constant answer cannot satisfy it.
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.isActive(ProbeId)
    ckEq w.host.effectiveCapabilitiesOf(ProbeId),
         grantsOf(w.probe.ctx).capabilities
    ck capProcess in grantsOf(w.probe.ctx).capabilities
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt, "taken back")
    ckEq w.host.effectiveCapabilitiesOf(ProbeId),
         grantsOf(w.probe.ctx).capabilities
    ck capProcess notin grantsOf(w.probe.ctx).capabilities
    # …and the two stores agree HERE, which is what makes the assertion above
    # a statement about the API's choice of store rather than about the host
    # having only one.
    ckEq w.host.effectiveCapabilitiesOf(ProbeId),
         w.host.resolution.manifests[ProbeId].grants.capabilities

  test "and it is still refused after a restart":
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt, "taken back")
    ckEq saveGrantLedger(w.host.ledger), ""
    let reopened = loadGrantLedger()
    ckEq reopened.problems.len, 0
    ckEq reopened.ledger.stateOf(ProbeId, capProcess), gsRevoked
    let restarted = boot(full, reopened.ledger)
    ckRefusedSpawn(restarted, tmp / "after-restart")

  test "the refusal comes from PLAT-8's own policy, not from a second gate":
    # The message is `capabilities.refuse`'s, word for word, and the decision
    # is reachable without any host at all — which is how this case shows
    # there is one predicate rather than two.
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    let outcome = spawnTouch(w, tmp / "policy-text")
    ckEq outcome.status, ioRefused
    let narrowed = w.host.resolution.manifests[ProbeId].grants
    # THE TWO SPELLINGS STAY IN SYNC. `PluginManifest` carries the capability
    # set twice — as `capabilities` and as `grants.capabilities` — and
    # `parseManifest` assigns both from one parse specifically so there is no
    # second source of truth. A narrowing that updated one of them would
    # reintroduce exactly the divergence that field comment forbids.
    ckEq w.host.resolution.manifests[ProbeId].capabilities,
         w.host.resolution.manifests[ProbeId].grants.capabilities
    let direct = decide(narrowed, ProbeId,
                        IoRequest(kind: irSpawnProcess, target: Tool))
    ck not direct.permitted
    ckEq direct.capability, capProcess
    ckEq outcome.message, direct.reason
    ck direct.reason.contains("it was not granted 'process'")

  test "revoking one capability does not take the others away":
    # §8.1.2's grants are per-kind, and so is taking one back. A revocation
    # that disabled the plugin would be a different product decision, and a
    # user who revoked `process` from a working plugin would find the rest of
    # it gone.
    let readable = tmp / "readable.txt"
    writeFile(readable, "hello from the host")
    var w = boot(full, loadGrantLedger().ledger)
    let io = PluginIoContext()
    let before = waitFor w.probe.attemptRead(io, readable)
    ckEq before.status, ioOk
    ckEq before.data, "hello from the host"
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    ckRefusedSpawn(w, tmp / "process-gone")
    let after = waitFor w.probe.attemptRead(io, readable)
    ckEq after.status, ioOk
    ckEq after.data, "hello from the host"
    ck capFsRead in w.host.effectiveCapabilitiesOf(ProbeId)
    ck w.host.isActive(ProbeId)

  test "revoking `fs:read` is refused the same way, so the rule is per-kind":
    let readable = tmp / "readable.txt"
    writeFile(readable, "hello from the host")
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capFsRead, RevokedAt)
    let outcome = waitFor w.probe.attemptRead(PluginIoContext(), readable)
    ckEq outcome.status, ioRefused
    ck outcome.message.contains("'fs:read'")
    ckEq outcome.data, ""
    # …and `process` is untouched, which is the twin of the case above.
    ckSpawned(w, tmp / "process-still-there")

  test "re-granting brings it back, so the narrowing is not one-way":
    # The positive twin for the whole mechanism (Verification-Harness-Traps
    # §4a). A `revokeCapability` that had simply broken the plugin would pass
    # every refusal assertion above and fail this one.
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    ckRefusedSpawn(w, tmp / "revoked-once")
    ck w.host.grantCapability(ProbeId, capProcess, RegrantedAt, "changed my mind")
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsGranted
    ckSpawned(w, tmp / "regranted")

  test "the acceptance step does NOT resurrect a revoked grant":
    # Otherwise a revocation lasts until the next `ct install` or the next
    # start-up that re-accepts the manifest, which is the cheapest way for a
    # revocation to stop meaning anything.
    var w = boot(full, loadGrantLedger().ledger)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    ckEq w.host.acceptDeclaredGrants(ProbeId, RegrantedAt, "reinstalled"), 0
    ckEq w.host.grantStateOf(ProbeId, capProcess), gsRevoked
    ckRefusedSpawn(w, tmp / "after-reaccept")

  test "an UPGRADE that widens the manifest does not inherit the old consent":
    # The plugin was installed declaring `fs:read` and the user accepted it.
    # Version 2 adds `process`. The new power is undecided, so it is refused
    # until somebody decides — measured, not asserted about the record.
    var narrow: GrantLedger
    discard narrow.grantDeclared(ProbeId, {capFsRead}, GrantedAt, "v1")
    ckEq saveGrantLedger(narrow), ""
    let v2 = boot(full, loadGrantLedger().ledger)
    ckEq v2.host.grantStateOf(ProbeId, capFsRead), gsGranted
    ckEq v2.host.grantStateOf(ProbeId, capProcess), gsUndecided
    ckRefusedSpawn(v2, tmp / "widened-manifest")
    # And accepting the UPGRADE grants exactly the one that was added.
    ckEq v2.host.acceptDeclaredGrants(ProbeId, RegrantedAt, "accepted v2"), 1
    ckSpawned(v2, tmp / "after-accepting-v2")

  test "a ledger entry cannot grant a power the manifest never declared":
    # `effectiveGrants` intersects with the DECLARED set, so a ledger that had
    # been edited by hand cannot widen a plugin past its own manifest.
    var forged: GrantLedger
    discard forged.grantDeclared(ProbeId, {capProcess, capFsRead}, GrantedAt)
    discard forged.grant(ProbeId, capSocketRemote, GrantedAt, "forged")
    let w = boot(full, forged)
    ckEq w.host.grantStateOf(ProbeId, capSocketRemote), gsGranted
    ck capSocketRemote notin w.host.effectiveCapabilitiesOf(ProbeId)
    let outcome = waitFor w.probe.attemptConnect("203.0.113.9", 9)
    ckEq outcome.status, ioRefused
    ck outcome.message.contains("'socket:remote'")

suite "PLAT-10: the grant is inspectable":

  setup:
    let tmp = getTempDir() / ("ct-plat10-inspect-" & $getCurrentProcessId() &
                              "-" & $epochTime().int64)
    createDir(tmp)
    let priorRoot = getEnv(userRootEnvVar, "")
    let hadRoot = existsEnv(userRootEnvVar)
    putEnv(userRootEnvVar, tmp)
    let full = manifestText(["process", "fs:read"], [Tool], [tmp])

  teardown:
    if hadRoot: putEnv(userRootEnvVar, priorRoot) else: delEnv(userRootEnvVar)
    removeDir(tmp)

  test "the report says what was granted, when, and what is in force now":
    var w = boot(full, loadGrantLedger().ledger)
    ckEq w.host.acceptDeclaredGrants(ProbeId, GrantedAt, "accepted at install"), 2
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt, "taken back")
    let text = w.host.grantLedgerReport()
    checkpoint(text)
    ck text.contains(ProbeId)
    ck text.contains(GrantedAt)
    ck text.contains(RevokedAt)
    ck text.contains("accepted at install")
    ck text.contains("taken back")
    ck text.contains("granted process")
    ck text.contains("REVOKED process")
    ck text.contains("in force now: fs:read")

  test "and the host's own report names the revocation beside the load errors":
    var w = boot(full, loadGrantLedger().ledger)
    ckEq w.host.acceptDeclaredGrants(ProbeId, GrantedAt), 2
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    let text = w.host.report()
    checkpoint(text)
    ck text.contains("'process' was REVOKED on " & RevokedAt)
    ck text.contains(ProbeId)

  test "an undecided capability is reported too, with a different sentence":
    # "You revoked it" and "you never granted it" are different facts to a
    # user looking at a feature that is not there.
    let w = boot(full, loadGrantLedger().ledger)
    let text = w.host.report()
    checkpoint(text)
    ck text.contains("has never been granted")
    ck not text.contains("REVOKED")

  test "the grants report shows the EFFECTIVE set, not the declared one":
    # `describeGrants` walks the capabilities the plugin holds, so a revoked
    # `process` must stop appearing in the disclosure a user reads.
    var w = boot(full, loadGrantLedger().ledger)
    ckEq w.host.acceptDeclaredGrants(ProbeId, GrantedAt), 2
    let before = w.host.grantsReport()
    ck before.contains("process")
    ck before.contains("may spawn: " & Tool)
    ck w.host.revokeCapability(ProbeId, capProcess, RevokedAt)
    let after = w.host.grantsReport()
    checkpoint(after)
    ck not after.contains("may spawn: " & Tool)
    ck after.contains("fs:read")

  test "a host with no ledger says so rather than reporting an empty one":
    # The distinction matters: "nothing has been granted" and "grants are not
    # being tracked here" are different states, and PLAT-8's own suites run in
    # the second.
    let hostNoLedger = newPluginHost(CoreVersion)
    discard hostNoLedger.register(full, "x.json", proc(ctx: PluginContext) = discard)
    hostNoLedger.resolveAll()
    ck hostNoLedger.grantLedgerReport().contains("no capability grant ledger")
    ck not hostNoLedger.ledgerAttached
    ckEq hostNoLedger.grantStateOf(ProbeId, capProcess), gsUndecided
    # …and with no ledger the manifest's declaration IS the grant, which is
    # PLAT-8's model, unchanged by this milestone.
    ck capProcess in hostNoLedger.effectiveCapabilitiesOf(ProbeId)

  test "revoking without a ledger raises rather than silently doing nothing":
    let hostNoLedger = newPluginHost(CoreVersion)
    discard hostNoLedger.register(full, "x.json", proc(ctx: PluginContext) = discard)
    hostNoLedger.resolveAll()
    var raised = false
    try:
      discard hostNoLedger.revokeCapability(ProbeId, capProcess, RevokedAt)
    except PluginHostError as e:
      raised = true
      ck e.msg.contains("attachGrantLedger")
    ck raised
    ck capProcess in hostNoLedger.effectiveCapabilitiesOf(ProbeId)

# ---------------------------------------------------------------------------

suite "PLAT-10: the counted-assertion tally":

  test "the tally":
    check countedAssertions == ExpectedAssertions
