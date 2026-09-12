## plugin_capabilities_test.nim — PLAT-8's capability POLICY, and PLAT-8's
## verification gate.
##
## ## WHAT THIS SUITE IS FOR, AND WHAT IT DELIBERATELY IS NOT
##
## `plugin_model/capabilities.nim` is pure: it opens nothing, so every refusal
## in it can be asserted without a machine, in a lane that links no dispatcher.
## That is why the decisions live there and why this file exists.
##
## It is NOT the evidence that the sandbox holds. A policy that says "refused"
## and a call site that spawns anyway are indistinguishable from here, so
## `test_plugin_io_sdk.nim` asserts every refusal a SECOND time by ATTEMPTING
## it against real processes and real sockets, and measures the effect —
## no child, no socket — against the operating system. Verification-Harness-
## Traps §4b: a test asserting only "it refused" passes when the refusal
## happened for the wrong reason, and a test asserting only that a function
## returned `false` passes when nobody calls it.
##
## ## THE VERIFICATION GATE
##
## PLAT-8: "The `trace` + `socket:remote` combination requires an explicit
## grant that states what it permits, and **is not implied by any other
## grant**."
##
## The second half is asserted BY ENUMERATION over all sixty-four subsets of
## the six capabilities, in `the trace-egress grant is implied by no
## capability subset`. A property claimed about "any other grant" and tested on
## the two or three subsets somebody thought of is the shape this repository
## has had to withdraw before; there are only sixty-four, so there is no reason
## to sample.
##
## The first half — "states what it permits" — is asserted on
## `traceEgressDisclosure`, which is DERIVED from the declared hosts rather
## than quoted from the author's own sentence. Those are different claims: an
## author's statement is what they were willing to write, and a user needs to
## be told what the grant actually permits. The suite asserts the disclosure
## names both capabilities and every declared host, and that it changes when
## the declared hosts change.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## Every assertion helper in this file is a `template`. There is exactly one
## (`ck`), and it wraps `unittest.check` — a `check` inside a plain `proc`
## sets a global and the case reports `[OK]` with the failed comparison
## printed above it.
##
## Compile and run:
##   nim c -r src/common/plugin_capabilities_test.nim

import std/[strutils, unittest]

import ./plugin_model

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Ack = "this plugin uploads recorded stack frames to the team's shared " &
        "analysis service so a colleague can open the same failure"
  Acked = TraceEgressGrant(acknowledged: true, statement: Ack)
    ## Written out once because, since 2026-09-09, a `process` grant needs it
    ## too — `process` subsumes every other capability, so it is an
    ## exfiltration path on its own. Every `capProcess` grant below that
    ## expects to be PERMITTED therefore carries this, and the cases that
    ## expect a refusal deliberately do not.

func grants(caps: set[Capability]; execs: seq[string] = @[];
            hosts: seq[DeclaredHost] = @[]; reads: seq[string] = @[];
            writes: seq[string] = @[];
            egress = TraceEgressGrant()): GrantSet =
  GrantSet(capabilities: caps, executables: execs, hosts: hosts,
           readPaths: reads, writePaths: writes, traceEgress: egress)

func spawnOf(name: string): IoRequest =
  IoRequest(kind: irSpawnProcess, target: name)

func tcpOf(host: string; port: int): IoRequest =
  IoRequest(kind: irConnectTcp, target: host, port: port)

# ---------------------------------------------------------------------------

suite "PLAT-8: an address is classified, not taken on the plugin's word":

  test "loopback literals are loopback, in both families":
    ck classifyHost("127.0.0.1") == acLoopback
    ck classifyHost("127.13.9.2") == acLoopback
    ck classifyHost("::1") == acLoopback
    ck classifyHost("0:0:0:0:0:0:0:1") == acLoopback
    ck classifyHost("[::1]") == acLoopback

  test "everything else that is an address is remote":
    ck classifyHost("10.0.0.1") == acRemote
    ck classifyHost("128.0.0.1") == acRemote
    ck classifyHost("126.255.255.255") == acRemote
    ck classifyHost("203.0.113.9") == acRemote
    ck classifyHost("2001:db8::1") == acRemote
    ck classifyHost("symbols.example.com") == acRemote

  test "'localhost' is refused BY NAME rather than assumed to be loopback":
    # A name the machine resolves is not an address. This is the whole third
    # outcome, and it costs an author eight characters.
    ck classifyHost("localhost") == acAmbiguous
    ck classifyHost("LOCALHOST") == acAmbiguous
    ck classifyHost("db.localhost") == acAmbiguous
    let d = decide(grants({capSocketLocal}), "acme.p", tcpOf("localhost", 9000))
    ck not d.permitted
    ck "127.0.0.1" in d.reason
    # ... and the control: the same plugin, the same port, written as an
    # address, is permitted. The refusal is about the spelling, not about
    # loopback.
    ck decide(grants({capSocketLocal}), "acme.p", tcpOf("127.0.0.1", 9000)).permitted

  test "malformed addresses are not loopback":
    ck not isLoopbackLiteral("127.0.0")
    ck not isLoopbackLiteral("127.0.0.256")
    ck not isLoopbackLiteral("")
    ck not isLoopbackLiteral("127.0.0.1.1")
    ck not isLoopbackLiteral("::2")

  test "F4: the UNSPECIFIED address is its own class, in every spelling":
    # THE KILLING CASE FOR "neither grant implies the other, in both
    # directions". Until 2026-09-09 `0.0.0.0` classified `acRemote`, RESOLVED
    # to `0.0.0.0` so the second pass agreed with the first, and
    # `connect(0.0.0.0)` reached 127.0.0.1 — so a `socket:remote`-only plugin
    # reached a loopback daemon with both capability passes green. The end-to-
    # end half of this, against a real listener, is in `test_plugin_io_sdk`.
    ck classifyHost("0.0.0.0") == acUnspecified
    ck classifyHost("::") == acUnspecified
    ck classifyHost("[::]") == acUnspecified
    ck classifyHost("0:0:0:0:0:0:0:0") == acUnspecified
    ck classifyHost("0") == acUnspecified
    ck classifyHost("::0") == acUnspecified
    ck classifyHost("0x0") == acUnspecified
    # THE WHOLE /8, not the four-zero spelling: 0.0.0.0/8 is "this network"
    # and a policy that special-cased `0.0.0.0` is evaded by `0.1.2.3`.
    ck classifyHost("0.1.2.3") == acUnspecified
    ck classifyHost("0.255.255.255") == acUnspecified
    # THE CONTROLS, through the same function. A `classifyHost` that had
    # started answering `acUnspecified` to everything would satisfy every
    # assertion above and nothing else in this file would notice.
    ck classifyHost("127.0.0.1") == acLoopback
    ck classifyHost("10.0.0.1") == acRemote
    ck classifyHost("1.0.0.0") == acRemote
    ck classifyHost("::1") == acLoopback

  test "F4: neither socket grant reaches the unspecified address":
    # It is refused BY NAME for both verbs, because the two verbs disagree
    # about which class it would be: a connect to it reaches loopback and a
    # bind of it publishes on every interface. Neither socket grant is
    # therefore the right answer, and picking either would let the other
    # through.
    for caps in [{capSocketLocal}, {capSocketRemote},
                 {capSocketLocal, capSocketRemote}]:
      let g = grants(caps, hosts = @[DeclaredHost(host: "0.0.0.0",
                                                  port: AnyPort)])
      let d = decide(g, "acme.p", tcpOf("0.0.0.0", 9000))
      ck not d.permitted
      ck "UNSPECIFIED" in d.reason
      ck not decide(g, "acme.p",
        IoRequest(kind: irListenTcp, target: "0.0.0.0", port: 9000)).permitted
    # THE CONTROL: the same plugin, the same port, an address that IS one of
    # the two classes. The refusal is about the address, not about the plugin.
    ck decide(grants({capSocketLocal}), "acme.p",
              tcpOf("127.0.0.1", 9000)).permitted

  test "F4: an IPv4-mapped loopback literal is loopback":
    # `::ffff:127.0.0.1` is unambiguously loopback and classified `acRemote`
    # until 2026-09-09 — the loopback parser saw a ':' and demanded eight hex
    # groups. Only the second capability pass refused it, which is fail-closed
    # and is not the same as a policy that is right about the address.
    ck classifyHost("::ffff:127.0.0.1") == acLoopback
    ck classifyHost("::127.0.0.1") == acLoopback
    ck classifyHost("[::ffff:127.0.0.1]") == acLoopback
    ck classifyHost("::ffff:0.0.0.0") == acUnspecified
    # The control: a mapped address that is NOT loopback stays remote.
    ck classifyHost("::ffff:203.0.113.9") == acRemote

suite "PLAT-8: the grants are per-kind, and neither socket grant implies the other":

  test "socket:remote does not reach loopback":
    let g = grants({capSocketRemote},
                   hosts = @[DeclaredHost(host: "symbols.example.com",
                                          port: AnyPort)])
    let d = decide(g, "acme.p", tcpOf("127.0.0.1", 4000))
    ck not d.permitted
    ck d.capability == capSocketLocal
    ck "does not imply" in d.reason

  test "socket:local does not reach beyond loopback":
    let d = decide(grants({capSocketLocal}), "acme.p", tcpOf("203.0.113.9", 80))
    ck not d.permitted
    ck d.capability == capSocketRemote
    ck "does not imply" in d.reason

  test "a Unix domain socket is socket:local and nothing else grants it":
    let req = IoRequest(kind: irConnectUnix, target: "/run/analyser.sock")
    ck decide(grants({capSocketLocal}), "acme.p", req).permitted
    for c in Capability:
      if c == capSocketLocal: continue
      ck not decide(grants({c}), "acme.p", req).permitted

  test "a listener beyond loopback is refused even with socket:remote":
    # §8.1.2 grants socket:remote for OUTBOUND connections. A listener on a
    # public interface publishes a service from inside the debugger.
    #
    # THE SUBJECT MOVED ON 2026-09-09 and the assertion did not. It used to
    # name `0.0.0.0`, which is now refused one arm earlier as `acUnspecified`
    # — so it would still have been red, correctly, but for a different reason
    # than the one this case exists to state. A public address is the honest
    # subject for "a listener beyond loopback"; the unspecified address has its
    # own case above.
    let g = grants({capSocketRemote, capSocketLocal},
                   hosts = @[DeclaredHost(host: "203.0.113.9", port: AnyPort)])
    let d = decide(g, "acme.p",
                   IoRequest(kind: irListenTcp, target: "203.0.113.9",
                             port: 8080))
    ck not d.permitted
    ck "OUTBOUND" in d.reason
    # The control: the same plugin may listen on loopback.
    ck decide(g, "acme.p",
              IoRequest(kind: irListenTcp, target: "127.0.0.1",
                        port: 8080)).permitted

suite "PLAT-8: process is a name against a declared set, never a path":

  test "an executable is named, not pathed":
    ck isBareExecutableName("cat")
    ck isBareExecutableName("python3")
    ck not isBareExecutableName("/bin/sh")
    ck not isBareExecutableName("../../bin/sh")
    ck not isBareExecutableName("..")
    ck not isBareExecutableName("")
    ck not isBareExecutableName("-c")
    ck not isBareExecutableName("bin\\sh")

  test "a path is refused with the reason, not silently normalised":
    let g = grants({capProcess}, execs = @["sh"])
    let d = decide(g, "acme.p", spawnOf("/bin/sh"))
    ck not d.permitted
    ck "named, not pathed" in d.reason

  test "an undeclared program is refused and the declared set is printed":
    let g = grants({capProcess}, execs = @["cat", "python3"], egress = Acked)
    let d = decide(g, "acme.p", spawnOf("sh"))
    ck not d.permitted
    ck "cat, python3" in d.reason
    # The control: a declared one is permitted, through the same call.
    ck decide(g, "acme.p", spawnOf("cat")).permitted

  test "no other capability grants a spawn":
    let req = spawnOf("cat")
    for c in Capability:
      if c == capProcess: continue
      ck not decide(grants({c}, execs = @["cat"], egress = Acked), "acme.p",
                    req).permitted

suite "PLAT-8 F1: 'process' subsumes every other grant, and the model says so":

  # WHAT THIS SUITE EXISTS FOR. PLAT-8 shipped claiming "`process` is not the
  # hole that would make [`socket:remote` grantable] pointless". A verification
  # pass on 2026-09-08 built a plugin declaring `trace`, `fs:read` and
  # `process` with `env` as its one declared executable — NO socket capability,
  # NO declared host, NO trace-egress grant — and it read a recording and
  # shipped it over TCP, with the user shown no exfiltration disclosure at all.
  #
  # THE RULE BINDS BY COMPOSITION, NOT BY NAME. A denylist of exec wrappers
  # (`env`, `xargs`, `find`, `sh`, `python3`, …) was refused as the primary
  # defence: it is the shape of PLAT-7's import-extractor blocklist, which took
  # seven passes and still has a residual, and it is unsound in principle
  # because the host cannot know what an arbitrary binary does with its argv.
  # So `capProcess` is in `SubsumingCapabilities`, `effectiveCapabilities`
  # expands it to the whole enum, and every rule asks its question there.

  test "the effective set of a 'process' grant is every capability":
    ck subsumesEverything({capProcess})
    ck not subsumesEverything({capFsRead, capTrace, capSocketRemote})
    for c in Capability:
      ck c in effectiveCapabilities({capProcess})
    # The control, through the same function: a grant WITHOUT `process` is
    # its own effective set and nothing more. An `effectiveCapabilities` that
    # had started returning the full set unconditionally would satisfy the
    # loop above and be caught here.
    ck effectiveCapabilities({capFsRead}) == {capFsRead}
    ck effectiveCapabilities({}) == {}

  test "'process' alone needs the trace-egress grant":
    # THE CORE OF F1. It needs no `trace` and no socket capability, because
    # the attack needs neither: a spawned program reads the recording and
    # opens the socket, and both are outside every declaration.
    ck needsTraceEgressGrant({capProcess})
    ck needsTraceEgressGrant({capProcess, capFsRead, capTrace})
    ck not traceEgressPermitted(grants({capProcess}, execs = @["env"]))
    ck traceEgressPermitted(grants({capProcess}, execs = @["env"],
                                   egress = Acked))
    # The controls: the compositions that do NOT trigger it still do not, so
    # the widening is a widening and not a collapse into "everything needs it".
    ck not needsTraceEgressGrant({capFsRead, capFsWrite, capTrace})
    ck not needsTraceEgressGrant({capSocketLocal, capTrace})
    ck not needsTraceEgressGrant({capSocketRemote, capFsRead})

  test "decide refuses the spawn without the grant, and permits it with":
    # Refused at LOAD by `parseManifest` and again HERE, two arms graded
    # separately — neither may cover for the other.
    let without = grants({capTrace, capFsRead, capProcess}, execs = @["env"],
                         reads = @["/srv/plugin-data"])
    let d = decide(without, "armc.exfil", spawnOf("env"))
    ck not d.permitted
    ck d.capability == capProcess
    ck "subsumes every other capability" in d.reason
    # The ONLY difference between these two grant sets is the acknowledgement.
    let withGrant = grants({capTrace, capFsRead, capProcess},
                           execs = @["env"], reads = @["/srv/plugin-data"],
                           egress = Acked)
    ck decide(withGrant, "armc.exfil", spawnOf("env")).permitted

  test "the disclosure names the reach, and the reach is not the declared set":
    # The old sentence would have said, for exactly this plugin, "is being
    # granted BOTH 'trace' and 'socket:remote'" (it holds neither pair member
    # in that spelling) and "may send it to no declared host, which makes the
    # pair useless" (it has no hosts, and it exfiltrated anyway). Both halves
    # false, in the one sentence whose job is to be true.
    let g = grants({capTrace, capFsRead, capProcess}, execs = @["env"],
                   reads = @["/srv/plugin-data"], egress = Acked)
    let text = traceEgressDisclosure("armc.exfil", g)
    ck "armc.exfil" in text
    ck "'trace' and 'process'" in text
    ck "any host this machine can reach" in text
    ck "SUBSUMES every other capability" in text
    ck "env" in text
    # It does NOT claim the declared set is a bound.
    ck "does not bound that" in text
    # DERIVED, not quoted, exactly as the pair's disclosure is.
    ck Ack notin text

  test "describeGrants discloses the subsumption on the 'process' row itself":
    # A user scanning the list reads one line per grant and takes each line as
    # the extent of that grant. `process — may spawn: env` states the declared
    # set correctly and implies a bound that does not exist.
    let g = grants({capProcess}, execs = @["env"], egress = Acked)
    let text = describeGrants("armc.exfil", g)
    ck "may spawn: env" in text
    ck "OUTSIDE this sandbox" in text
    ck "SUBSUMES every other capability" in text
    # THE CONTROL, through the same renderer: a plugin without `process` is
    # not told its grants subsume anything, so the sentence is a fact about
    # this grant rather than a banner on every report.
    let quiet = describeGrants("acme.q", grants({capFsRead},
                                                reads = @["/srv/x"]))
    ck "may read under: /srv/x" in quiet
    ck "SUBSUMES" notin quiet

suite "PLAT-8's verification gate: trace + socket:remote":

  test "the trace-egress grant is implied by no capability subset":
    # ALL SIXTY-FOUR. §8.1.2's pair must require "an explicit, informed grant"
    # that "is not implied by any other grant", and a property about every
    # other grant, sampled, is the shape this campaign has had to withdraw.
    var subsets = 0
    var pairHolders = 0
    for bits in 0 ..< 64:
      var caps: set[Capability] = {}
      var i = 0
      for c in Capability:
        if (bits and (1 shl i)) != 0: caps.incl c
        inc i
      inc subsets
      # The grant field is left at its default: nothing was acknowledged.
      let g = grants(caps, execs = @["cat"],
                     hosts = @[DeclaredHost(host: "a.example.com",
                                            port: AnyPort)])
      if needsTraceEgressGrant(caps):
        inc pairHolders
        ck not traceEgressPermitted(g)
      else:
        ck traceEgressPermitted(g)
    ck subsets == 64
    # FORTY of the sixty-four need the grant, where sixteen did before
    # 2026-09-09, and the arithmetic is the fix rather than a bigger number:
    #
    #   * 32 subsets contain `process`. Every one of them needs the grant,
    #     because `effectiveCapabilities` expands `process` to the whole enum
    #     — a spawned program reads the recording and opens the socket, and
    #     neither is a capability the plugin declared.
    #   * of the 32 WITHOUT `process`, those holding both `trace` and
    #     `socket:remote` are 2^3 = 8: the remaining three vary freely.
    #
    # 32 + 8 = 40. A count that came out at zero would mean the loop never
    # reached the interesting half and every assertion above it was about the
    # boring one; a count that came out at 64 would mean the widening had
    # collapsed into "everything needs it" and the grant had stopped
    # discriminating.
    ck pairHolders == 40
    ck subsets - pairHolders == 24

  test "the pair with the grant is permitted, and it is the grant that did it":
    let hosts = @[DeclaredHost(host: "symbols.example.com", port: 443)]
    let without = grants({capTrace, capSocketRemote}, hosts = hosts)
    let with0 = grants({capTrace, capSocketRemote}, hosts = hosts,
                       egress = TraceEgressGrant(acknowledged: true,
                                                 statement: Ack))
    ck not traceEgressPermitted(without)
    ck traceEgressPermitted(with0)
    # And through `decide`, on a declared host, which is the call the SDK
    # makes: the ONLY difference between these two is the grant.
    let req = tcpOf("symbols.example.com", 443)
    ck not decide(without, "acme.p", req).permitted
    ck decide(with0, "acme.p", req).permitted

  test "an acknowledgement without a statement is not a grant":
    let hosts = @[DeclaredHost(host: "symbols.example.com", port: 443)]
    ck not traceEgressPermitted(
      grants({capTrace, capSocketRemote}, hosts = hosts,
             egress = TraceEgressGrant(acknowledged: true, statement: "")))
    ck not traceEgressPermitted(
      grants({capTrace, capSocketRemote}, hosts = hosts,
             egress = TraceEgressGrant(acknowledged: true, statement: "ok")))
    # ... and a statement without the acknowledgement is not one either.
    ck not traceEgressPermitted(
      grants({capTrace, capSocketRemote}, hosts = hosts,
             egress = TraceEgressGrant(acknowledged: false, statement: Ack)))

  test "the disclosure states what it permits, derived from the declaration":
    let g = grants({capTrace, capSocketRemote},
                   hosts = @[DeclaredHost(host: "symbols.example.com",
                                          port: 443),
                             DeclaredHost(host: "203.0.113.9",
                                          port: AnyPort)],
                   egress = TraceEgressGrant(acknowledged: true,
                                             statement: Ack))
    let text = traceEgressDisclosure("acme.p", g)
    ck "acme.p" in text
    ck "trace" in text
    ck "socket:remote" in text
    ck "symbols.example.com:443" in text
    ck "203.0.113.9" in text
    ck "No capability on the list implies this grant" in text
    # DERIVED, not quoted: the author's own sentence is not what the user is
    # shown as the permission.
    ck Ack notin text
    # It moves with the declaration. A disclosure that named a fixed set would
    # be a constant, and a constant cannot be wrong about a particular plugin.
    let narrower = grants({capTrace, capSocketRemote},
                          hosts = @[DeclaredHost(host: "symbols.example.com",
                                                 port: 443)],
                          egress = TraceEgressGrant(acknowledged: true,
                                                    statement: Ack))
    ck "203.0.113.9" notin traceEgressDisclosure("acme.p", narrower)

  test "neither capability alone carries the weight":
    # §8.1.2: "Neither alone carries the same weight." A trace-only plugin and
    # a network-only plugin both need no egress grant.
    ck traceEgressPermitted(grants({capTrace}))
    ck traceEgressPermitted(grants({capSocketRemote},
      hosts = @[DeclaredHost(host: "a.example.com", port: AnyPort)]))
    ck not needsTraceEgressGrant({capTrace})
    ck not needsTraceEgressGrant({capSocketRemote})
    ck needsTraceEgressGrant({capTrace, capSocketRemote})

suite "PLAT-8: fs:read and fs:write reach declared paths only":

  test "a declared root reaches its children and nothing above it":
    let g = grants({capFsRead}, reads = @["/srv/symbols"])
    ck decide(g, "acme.p",
              IoRequest(kind: irReadPath, target: "/srv/symbols/a.sym")).permitted
    ck decide(g, "acme.p",
              IoRequest(kind: irReadPath, target: "/srv/symbols")).permitted
    ck not decide(g, "acme.p",
              IoRequest(kind: irReadPath, target: "/srv/symbols-other/a")).permitted
    ck not decide(g, "acme.p",
              IoRequest(kind: irReadPath, target: "/etc/shadow")).permitted

  test "a path containing '..' is refused rather than resolved":
    ck not pathIsUnder("/srv/symbols/../../etc/shadow", "/srv/symbols")
    ck not pathIsUnder("/srv/symbols/a", "/srv/../srv/symbols")

  test "a '..' inside a NAME is not a '..' segment":
    # THE SEGMENT/SUBSTRING DISTINCTION, repaired 2026-09-12. `pathIsUnder`
    # asked `".." in path or ".." in root` — a SUBSTRING test, applied to BOTH
    # arguments, the second of which is the resolved ROOT. So a declared root
    # or a checkout whose own path merely contains those two characters had
    # EVERY file in it refused, with a message saying the file was not inside
    # it. It failed in the safe direction, so nothing went red
    # (Verification-Harness-Traps §15).
    #
    # These are the cases only the segment walk admits. `..` is a segment;
    # `my..project`, `v1..v2` and `a..b.sym` are names.
    ck pathIsUnder("/srv/my..project/src/a.nim", "/srv/my..project")
    ck pathIsUnder("/srv/symbols/a..b.sym", "/srv/symbols")
    ck pathIsUnder("/srv/v1..v2", "/srv/v1..v2")
    # A name that ENDS in `..` is still a name; only the whole component `..`
    # is the parent segment. This is the boundary the walk has to get right and
    # a `endsWith("..")` test would not.
    ck pathIsUnder("/srv/symbols/trailing../leaf", "/srv/symbols")

    # AND THE EFFECT, through `decide`, which is the function a plugin meets.
    # The three lines above are about the predicate; this one is about the
    # grant, and it is the one that was actually broken for a user.
    let g = grants({capFsRead}, reads = @["/srv/my..project"])
    ck decide(g, "acme.p", IoRequest(kind: irReadPath,
      target: "/srv/my..project/src/a.nim")).permitted

    # THE REFUSAL IS UNCHANGED, asserted in the same case so the widening
    # cannot be read as a loosening. A real `..` segment still escapes nothing,
    # in either argument, at any depth.
    ck not pathIsUnder("/srv/my..project/../../etc/shadow", "/srv/my..project")
    ck not pathIsUnder("/srv/my..project/a", "/srv/my..project/..")
    ck not decide(g, "acme.p", IoRequest(kind: irReadPath,
      target: "/srv/my..project/../../etc/shadow")).permitted

  test "read and write are separate grants":
    let readOnly = grants({capFsRead}, reads = @["/srv/x"])
    ck not decide(readOnly, "acme.p",
      IoRequest(kind: irWritePath, target: "/srv/x/a")).permitted
    let writeOnly = grants({capFsWrite}, writes = @["/srv/x"])
    ck not decide(writeOnly, "acme.p",
      IoRequest(kind: irReadPath, target: "/srv/x/a")).permitted

suite "PLAT-8: the manifest refuses a grant nobody can inspect":

  test "'process' with no declared executables is a load-time error":
    let p = parseManifest("""{
  "id": "acme.spawner", "version": "1.0.0",
  "capabilities": ["process"]
}""", "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecCapabilityWithoutDeclaration: found = true
      ck e.namesPlugin()
    ck found

  test "declared executables without 'process' is the mirror error":
    let p = parseManifest("""{
  "id": "acme.spawner", "version": "1.0.0",
  "executables": ["cat"]
}""", "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecDeclarationWithoutCapability: found = true
    ck found

  test "an executable declared as a path is refused, naming the rule":
    let p = parseManifest("""{
  "id": "acme.spawner", "version": "1.0.0",
  "capabilities": ["process"], "executables": ["/bin/sh"]
}""", "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecBadDeclaration and "bare program name" in e.detail:
        found = true
    ck found

  test "hosts parse with and without a port, and refuse a bad one":
    let p = parseManifest("""{
  "id": "acme.net", "version": "1.0.0",
  "capabilities": ["socket:remote"],
  "hosts": ["symbols.example.com:443", "203.0.113.9", "[2001:db8::1]:8443"]
}""", "t")
    ck p.isOk
    ck p.manifest.grants.hosts.len == 3
    ck p.manifest.grants.declaresHost("symbols.example.com", 443)
    ck not p.manifest.grants.declaresHost("symbols.example.com", 80)
    ck p.manifest.grants.declaresHost("203.0.113.9", 9999)
    ck p.manifest.grants.declaresHost("[2001:db8::1]", 8443)

    let bad = parseManifest("""{
  "id": "acme.net", "version": "1.0.0",
  "capabilities": ["socket:remote"], "hosts": ["a.example.com:70000"]
}""", "t")
    ck not bad.isOk

  test "a declared host that is 'localhost' is refused at load":
    let p = parseManifest("""{
  "id": "acme.net", "version": "1.0.0",
  "capabilities": ["socket:remote"], "hosts": ["localhost:9000"]
}""", "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecBadDeclaration and "127.0.0.1" in e.detail: found = true
    ck found

  test "the pair without the grant does not load, and the error is the disclosure":
    let p = parseManifest("""{
  "id": "acme.leaky", "version": "1.0.0",
  "capabilities": ["trace", "socket:remote"],
  "hosts": ["symbols.example.com:443"]
}""", "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecTraceEgressNotAcknowledged:
        found = true
        ck "credentials, keys and customer data" in e.detail
        ck "symbols.example.com:443" in e.detail
        ck e.namesPlugin()
    ck found

  test "the pair WITH the grant loads, and that is the only difference":
    let text = """{
  "id": "acme.leaky", "version": "1.0.0",
  "capabilities": ["trace", "socket:remote"],
  "hosts": ["symbols.example.com:443"]$1
}"""
    ck not parseManifest(text % [""], "t").isOk
    let ok = parseManifest(text % [
      ",\n  \"traceEgress\": {\"acknowledged\": true, \"statement\": \"" &
      Ack & "\"}"], "t")
    if not ok.isOk:
      checkpoint renderAll(ok.errors)
    ck ok.isOk
    ck ok.manifest.grants.traceEgress.acknowledged
    ck traceEgressPermitted(ok.manifest.grants)

  test "a trace-egress grant on a plugin without the pair is refused too":
    let p = parseManifest("""{
  "id": "acme.trainer", "version": "1.0.0",
  "capabilities": ["trace"],
  "traceEgress": {"acknowledged": true, "statement": "$1"}
}""" % [Ack], "t")
    ck not p.isOk
    var found = false
    for e in p.errors:
      if e.code == pecTraceEgressWithoutPair: found = true
    ck found

  test "F1: 'process' alone does not load, and the error is the disclosure":
    # THE ACCEPTANCE TEST FOR F1 AT THE MANIFEST LAYER, and it is the
    # verification pass's own arm C manifest, reproduced byte for byte in its
    # capability set: `trace` + `fs:read` + `process`, one declared executable,
    # no hosts, no acknowledgement. It loaded before 2026-09-09 and then
    # exfiltrated a recording.
    let armC = parseManifest("""{
  "id": "armc.exfil", "version": "1.0.0",
  "capabilities": ["process", "fs:read", "trace"],
  "executables": ["env"],
  "paths": {"read": ["/srv/plugin-data"]}
}""", "t")
    ck not armC.isOk
    var found = false
    for e in armC.errors:
      if e.code == pecTraceEgressNotAcknowledged:
        found = true
        ck "SUBSUMES every other capability" in e.detail
        ck "any host this machine can reach" in e.detail
        ck e.namesPlugin()
    ck found

    # `process` with NOTHING else is the same refusal, because the attack
    # needs nothing else.
    let bare = parseManifest("""{
  "id": "acme.spawner", "version": "1.0.0",
  "capabilities": ["process"], "executables": ["sort"]
}""", "t")
    ck not bare.isOk
    var bareFound = false
    for e in bare.errors:
      if e.code == pecTraceEgressNotAcknowledged: bareFound = true
    ck bareFound

    # THE CONTROL, AND IT IS THE ACCEPTANCE TEST'S SECOND HALF: with the
    # acknowledgement the same plugin LOADS, and what a user reads then names
    # the reach. "Refused at load OR forced to disclose" — both arms exist,
    # and this is the one that shows the disclosure is reachable rather than
    # the plugin being simply unbuildable.
    let acked = parseManifest("""{
  "id": "armc.exfil", "version": "1.0.0",
  "capabilities": ["process", "fs:read", "trace"],
  "executables": ["env"],
  "paths": {"read": ["/srv/plugin-data"]},
  "traceEgress": {"acknowledged": true, "statement": "$1"}
}""" % [Ack], "t")
    if not acked.isOk:
      checkpoint renderAll(acked.errors)
    ck acked.isOk
    let shown = describeGrants("armc.exfil", acked.manifest.grants)
    ck "may spawn: env" in shown
    ck "SUBSUMES every other capability" in shown
    ck "any host this machine can reach" in shown

  test "manifest.capabilities and manifest.grants.capabilities are one set":
    # Two spellings of one fact. A second source of truth here would let the
    # SDK decide against a capability set the report never showed.
    let p = parseManifest("""{
  "id": "acme.both", "version": "1.0.0",
  "capabilities": ["process", "socket:local"], "executables": ["cat"],
  "traceEgress": {"acknowledged": true, "statement": "$1"}
}""" % [Ack], "t")
    if not p.isOk:
      checkpoint renderAll(p.errors)
    ck p.isOk
    ck p.manifest.capabilities == p.manifest.grants.capabilities
    ck p.manifest.capabilities == {capProcess, capSocketLocal}

suite "PLAT-8: what a user is shown before granting":

  test "describeGrants names every grant with its declared set":
    let g = grants({capProcess, capSocketRemote, capTrace},
                   execs = @["cat"],
                   hosts = @[DeclaredHost(host: "symbols.example.com",
                                          port: 443)],
                   egress = TraceEgressGrant(acknowledged: true,
                                             statement: Ack))
    let text = describeGrants("acme.p", g)
    ck "acme.p" in text
    ck "may spawn: cat" in text
    ck "symbols.example.com:443" in text
    ck "may read recorded program data" in text
    # The pair is never shown as two ordinary rows.
    ck "No capability on the list implies this grant" in text

  test "a plugin granted nothing is said to have been granted nothing":
    ck "was granted nothing" in describeGrants("acme.p", grants({}))

suite "PLAT-8: the resolved address is judged, not the string":

  test "a name that resolves off the machine is refused for socket:local":
    let g = grants({capSocketLocal})
    let d = decideResolvedAddress(g, "acme.p", "analyser.internal",
                                  "10.4.0.9", 9000)
    ck not d.permitted
    ck d.capability == capSocketRemote
    ck "analyser.internal" in d.reason
    ck "10.4.0.9" in d.reason
    # The control: the same name resolving to loopback is permitted.
    ck decideResolvedAddress(g, "acme.p", "analyser.internal",
                             "127.0.0.1", 9000).permitted

  test "the second pass does NOT re-demand the declared host":
    # It asks a DIFFERENT question of the same policy — see
    # `decideResolvedAddress`. Re-running the whole of `decide` on the resolved
    # literal would require the ADDRESS to be declared as well as the name, and
    # every legitimate connection to a declared hostname would be refused. This
    # case is what stops that from being a plausible simplification.
    let g = grants({capSocketRemote},
                   hosts = @[DeclaredHost(host: "symbols.example.com",
                                          port: 443)])
    ck decide(g, "acme.p", tcpOf("symbols.example.com", 443)).permitted
    ck decideResolvedAddress(g, "acme.p", "symbols.example.com",
                             "93.184.216.34", 443).permitted
    # ... and a plugin WITHOUT the grant is still refused on the same address.
    ck not decideResolvedAddress(grants({capSocketLocal}), "acme.p",
                                 "symbols.example.com", "93.184.216.34",
                                 443).permitted

suite "PLAT-8: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c. Written from a run; a suite that stops
    # asserting is a suite whose count moves. 193 before the 2026-09-09
    # verification repairs; 267 with F1's and F4's arms and their controls;
    # 275 with the 2026-09-12 segment-vs-substring case for `pathIsUnder`.
    check countedAssertions == 275
