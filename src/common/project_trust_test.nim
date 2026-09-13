## project_trust_test.nim — PLAT-13's policy suite. The per-repository trust
## grant, the capability floor, and the WebAssembly sandbox, all asserted
## WITHOUT A MACHINE.
##
## ## NO MOCKS, AND NOTHING HERE STANDS IN FOR ANYTHING
##
## Every subject is a pure function over values: a ledger built by calling the
## product's own `grant`/`revoke`, a `GrantSet` handed to PLAT-8's real
## `capabilities.decide`, and REAL WebAssembly modules whose bytes are emitted
## by `project_wasm_fixtures` and read by the real `decodeModule`. The encoder
## is not a double — it emits the wasm 1.0 binary format, section ids and opcode
## bytes as the SPEC numbers them, and the thing that reads it is the shipped
## decoder. Its header says so at more length.
##
## The identity a grant is keyed on is a string here, because deriving one needs
## a filesystem and that half is `src/ct/launch/project_trust_store.nim`,
## exercised against real directories by `project_executable_tier_test.nim` in
## `ct-cli-units`. What is asserted here is that the MODEL compares identities
## and never parses them; what is asserted there is that two directories get two
## identities and a copy gets a third.
##
## ## TRAP 13 (Verification-Harness-Traps §13, §13a)
##
## Every assertion helper in this file is a `template`. A `check` inside a plain
## `proc` assigns a module-level `testStatusIMPL`, so the assertion cannot fail
## the test that called it and the case reports `[OK]` with the failed
## comparison printed directly above it.
##
## ## §7a: EVERY NEGATIVE CONTROL IN THIS FILE HAS A POSITIVE TWIN IN THE SAME
## ## CASE
##
## An assertion of ABSENCE looks the same when everything is present. So the
## case that asserts a refusal runs the SAME function through the SAME inputs
## with the decision changed, and asserts the opposite — the shape PLAT-8 used
## for its exploit sentinels ("one function, two callers, and the only
## difference between them is the decision").
##
## Compile and run:
##   nim c -r src/common/project_trust_test.nim

import std/[monotimes, strutils, times, unittest]

import ./project_executables
import ./project_wasm_fixtures
import ./plugin_model/capabilities

const ExpectedAssertions = 615
  ## Written from a run, and asserted against the tally at the end of the file.
  ## `ci/lib/run-nim-test-lane.sh` reads this name.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

template ckAdmits(ledger, identity, kind, digest, wanted: untyped) =
  ## An admission asserted BY CODE. Verification-Harness-Traps §4b: a test
  ## asserting only "it refused" passes when the refusal was for the wrong
  ## reason, and this decision has five distinct refusals whose remedies differ.
  inc countedAssertions
  let got = admit(ledger, identity, kind, digest)
  if got != wanted:
    checkpoint("wanted " & $wanted & ", got " & $got & " (" &
               admissionText(got) & ")")
  check got == wanted

template ckRefusedModule(bytes: untyped; wanted: WasmProblemCode) =
  ## A decode refusal asserted by code, with the module's first bytes in the
  ## transcript so a failure names what was actually read.
  inc countedAssertions
  let decoded = decodeModule(bytes)
  if decoded.ok or decoded.problem.code != wanted:
    checkpoint("wanted " & $wanted & ", got " &
               (if decoded.ok: "a DECODED module"
                else: render(decoded.problem)) & "\n  bytes: " &
               describeBytes(bytes))
  check (not decoded.ok) and decoded.problem.code == wanted

const
  AtOne = "2026-09-12T10:00:00Z"
  AtTwo = "2026-09-12T11:00:00Z"
  IdentityA: RepositoryIdentity = "fs1:66306:1441795"
  IdentityB: RepositoryIdentity = "fs1:66306:9900001"
  DigestOne = "sha256:" & "11" .repeat(32)
  DigestTwo = "sha256:" & "22" .repeat(32)

proc grantedLedger(identity = IdentityA; kind = dfkVisualiserCode;
                   digest = DigestOne): ProjectTrustLedger =
  discard result.grant(identity, kind, digest, AtOne, "/src/demo")

# ---------------------------------------------------------------------------
# 1. §2.3's capability floor, expressed in PLAT-8's own model
# ---------------------------------------------------------------------------

suite "PLAT-13: an executable definition gets STRICTLY LESS than a plugin":

  test "every I/O request an executable definition could make is refused":
    # BY ENUMERATION over the closed `IoRequestKind`, not over the two or three
    # somebody thought of — PLAT-8's own rule for its sixty-four subsets.
    var checkedKinds = 0
    for k in IoRequestKind:
      inc checkedKinds
      checkpoint("request kind: " & $k)
      let d = executableTierDecision(
        IoRequest(kind: k, target: "/etc/hostname", port: 443))
      ck not d.permitted
      ck d.reason.len > 0
      ck d.reason.contains(ExecutableTierPrincipal)
    ckEq checkedKinds, ord(high(IoRequestKind)) + 1
    # THE POSITIVE TWIN, IN THE SAME CASE (§7a). Without it every assertion
    # above is satisfied by a `decide` that refuses everything, and the claim
    # "an executable definition holds nothing" would be indistinguishable from
    # "this policy permits nothing".
    let plugin = GrantSet(capabilities: {capFsRead}, readPaths: @["/src"])
    ck decide(plugin, "reader", IoRequest(kind: irReadPath,
                                          target: "/src/a.nim")).permitted

  test "the floor is the empty set, and it is a PROPER subset of every grant":
    ckEq executableTierCapabilities(), {}
    ck not subsumesEverything(executableTierCapabilities())
    ck not needsTraceEgressGrant(executableTierCapabilities())
    ck traceEgressPermitted(ExecutableTierGrants)
    ckEq ExecutableTierGrants.executables.len, 0
    ckEq ExecutableTierGrants.hosts.len, 0
    ckEq ExecutableTierGrants.readPaths.len, 0
    ckEq ExecutableTierGrants.writePaths.len, 0
    ck not ExecutableTierGrants.traceEgress.acknowledged
    # "Strictly less" as a MEASUREMENT over all sixty-four capability subsets:
    # the floor is a subset of every one of them and equal to only one.
    var subsets = 0
    var strictlyFewer = 0
    for mask in 0 ..< 64:
      var caps: set[Capability] = {}
      for i, c in [capProcess, capSocketLocal, capSocketRemote, capFsRead,
                   capFsWrite, capTrace]:
        if (mask and (1 shl i)) != 0: caps.incl c
      inc subsets
      ck executableTierCapabilities() <= caps
      if caps != {}: inc strictlyFewer
    ckEq subsets, 64
    ckEq strictlyFewer, 63

  test "the floor is asked THROUGH PLAT-8's subsumption rule, not read off":
    # `executableTierCapabilities` calls `effectiveCapabilities`, so the day a
    # later milestone puts a grant into `SubsumingCapabilities` this answer is
    # still derived. The control is the same function on a set that DOES
    # subsume: it must widen, or the call is decorative.
    ckEq effectiveCapabilities({}), {}
    ckEq effectiveCapabilities({capProcess}),
         {capProcess, capSocketLocal, capSocketRemote, capFsRead, capFsWrite,
          capTrace}
    ck capProcess notin ExecutableTierGrants.capabilities

# ---------------------------------------------------------------------------
# 2. §2.3's grant: per repository, per file, revocable, bound to the bytes
# ---------------------------------------------------------------------------

suite "PLAT-13: the grant is per repository, per file, and revocable":

  test "the default is REFUSED, and it is the enum's zero value":
    var empty: ProjectTrustLedger
    ckEq empty.stateOf(IdentityA, dfkVisualiserCode), tsUndecided
    ckEq low(TrustState), tsUndecided
    ckAdmits empty, IdentityA, dfkVisualiserCode, DigestOne, etaNoGrant
    ck not admits(admit(empty, IdentityA, dfkVisualiserCode, DigestOne))
    # The positive twin, in this case, so "refused" is not simply what this
    # function always says.
    ck admits(admit(grantedLedger(), IdentityA, dfkVisualiserCode, DigestOne))

  test "a grant is for ONE checkout: another identity inherits nothing":
    let led = grantedLedger()
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted
    # THE COPY. Same file, same bytes, same digest — a different checkout.
    ckAdmits led, IdentityB, dfkVisualiserCode, DigestOne, etaNoGrant
    ckEq led.stateOf(IdentityB, dfkVisualiserCode), tsUndecided
    ck led.identities() == @[IdentityA]

  test "a grant is for ONE file: the other executable file is undecided":
    let led = grantedLedger(kind = dfkVisualiserCode)
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted
    ckAdmits led, IdentityA, dfkDiffCode, DigestOne, etaNoGrant
    ckEq executableKinds(), @[dfkVisualiserCode, dfkDiffCode]

  test "a grant is for THOSE BYTES: the file changing is a separate decision":
    let led = grantedLedger(digest = DigestOne)
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestTwo, etaContentChanged
    # AN EMPTY DIGEST ON EITHER SIDE IS A MISMATCH, NEVER A WILDCARD. This is
    # the one direction the decision may not fail in.
    ckAdmits led, IdentityA, dfkVisualiserCode, "", etaContentChanged
    var noDigest: ProjectTrustLedger
    noDigest.record(IdentityA, dfkVisualiserCode, tdGranted, "", AtOne, "")
    ckAdmits noDigest, IdentityA, dfkVisualiserCode, DigestOne, etaContentChanged
    ckAdmits noDigest, IdentityA, dfkVisualiserCode, "", etaContentChanged
    # And the twin: the same bytes still admit.
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted

  test "revocation is recorded, survives a re-grant attempt, and is reversible":
    var led = grantedLedger()
    ckEq led.revoke(IdentityA, dfkVisualiserCode, AtTwo, "changed my mind"),
         troRecorded
    ckEq led.stateOf(IdentityA, dfkVisualiserCode), tsRevoked
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaRevoked
    ckEq led.grantedDigest(IdentityA, dfkVisualiserCode), ""
    # A SECOND REVOKE CHANGES NOTHING, so a UI that revokes on every launch does
    # not grow the file without bound.
    ckEq led.revoke(IdentityA, dfkVisualiserCode, AtTwo), troUnchanged
    ckEq led.entries.len, 2
    # The history is kept, which is the `visible` half of §2.3.
    ckEq led.entries[0].decision, tdGranted
    ckEq led.entries[1].decision, tdRevoked
    # And a deliberate re-grant works: revocation is a decision, not a tombstone.
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtTwo), troRecorded
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted
    # AND `grantedDigest`'s REVOKED GUARD GETS EVIDENCE ONLY IT CAN SATISFY
    # (Verification-Harness-Traps §16a). `revoke` records an EMPTY digest, so
    # every assertion above is equally satisfied by a `grantedDigest` that
    # returned the last entry's digest whatever the decision was — measured,
    # by arm T7, which SURVIVED until this was written. A hand-built ledger
    # whose REVOKE row carries a digest is the one shape that separates the
    # two, and a ledger file somebody edited is where it comes from.
    var handBuilt: ProjectTrustLedger
    handBuilt.record(IdentityA, dfkVisualiserCode, tdGranted, DigestOne, AtOne, "")
    handBuilt.record(IdentityA, dfkVisualiserCode, tdRevoked, DigestTwo, AtTwo, "")
    ckEq handBuilt.stateOf(IdentityA, dfkVisualiserCode), tsRevoked
    ckEq handBuilt.grantedDigest(IdentityA, dfkVisualiserCode), ""

  test "revoking a file nobody ever granted is RECORDED, not dropped":
    # `grant_ledger.revoke`'s asymmetry, and it is worth more here: a user who
    # has read a repository and decided in advance is a user whose decision must
    # survive to the next launch.
    var led: ProjectTrustLedger
    ckEq led.revoke(IdentityA, dfkDiffCode, AtOne, "I read it and said no"),
         troRecorded
    ckEq led.entries.len, 1
    ckAdmits led, IdentityA, dfkDiffCode, DigestOne, etaRevoked

  test "a declarative file is not grantable, and asking is answered":
    var led: ProjectTrustLedger
    ckEq led.grant(IdentityA, dfkPoints, DigestOne, AtOne), troNotExecutableTier
    ckEq led.revoke(IdentityA, dfkVisualisers, AtOne), troNotExecutableTier
    ckEq led.entries.len, 0
    ckAdmits led, IdentityA, dfkPoints, DigestOne, etaNotExecutableTier
    ckEq tierOf(dfkPoints), dtDeclarative
    ckEq tierOf(dfkVisualiserCode), dtExecutable

  test "a checkout with no identity is refused, and never granted":
    var led: ProjectTrustLedger
    ckEq led.grant("", dfkVisualiserCode, DigestOne, AtOne), troNoIdentity
    ckEq led.grant(IdentityA, dfkVisualiserCode, "", AtOne), troNoDigest
    ckEq led.entries.len, 0
    ckAdmits led, "", dfkVisualiserCode, DigestOne, etaNoIdentity
    ckEq grantedLedger().stateOf("", dfkVisualiserCode), tsUndecided

  test "THERE IS NO ACCEPTANCE STEP, and that is where this differs from a plugin":
    # PLAT-10 has `grantDeclared`: at install time it grants every capability a
    # manifest declares that has no decision yet. A plugin is installed BY NAME,
    # so there is a moment the user decided. A project definition arrives with a
    # clone, so an equivalent here would turn cloning into deciding.
    #
    # ASSERTED IN THE TYPE SYSTEM rather than described, the way PLAT-8 asserts
    # its facade's absences: no call of that shape compiles against this ledger.
    var led: ProjectTrustLedger
    ck not compiles(led.grantDeclared(IdentityA, {dfkVisualiserCode}, AtOne))
    ck not compiles(grantAllExecutable(led, IdentityA, AtOne))
    # The twin: the one-at-a-time call DOES compile, so the two assertions above
    # are about the missing shape rather than about a typo.
    ck compiles(led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne))

  test "the two phases of the decision read ONE predicate":
    # `mayReadBytes` is `admit` without the digest test. A caller that gets past
    # phase one holds a `ReadDecision`, which `admits` is not defined over — so
    # nothing can run on the strength of "the bytes may be read".
    var led = grantedLedger()
    ck mayReadBytes(led, IdentityA, dfkVisualiserCode).permitted
    ck not compiles(admits(mayReadBytes(led, IdentityA, dfkVisualiserCode)))
    ckEq mayReadBytes(led, IdentityB, dfkVisualiserCode).refusal, etaNoGrant
    ck not mayReadBytes(led, IdentityB, dfkVisualiserCode).permitted
    discard led.revoke(IdentityA, dfkVisualiserCode, AtTwo)
    ckEq mayReadBytes(led, IdentityA, dfkVisualiserCode).refusal, etaRevoked
    ck not mayReadBytes(led, IdentityA, dfkVisualiserCode).permitted
    # AND THE DIGEST TEST IS PHASE TWO'S ALONE: a file whose bytes moved on is
    # still readable and is not admitted, which is what makes the two phases two
    # phases rather than one asked twice.
    let moved = grantedLedger()
    ck mayReadBytes(moved, IdentityA, dfkVisualiserCode).permitted
    ckAdmits moved, IdentityA, dfkVisualiserCode, DigestTwo, etaContentChanged

# ---------------------------------------------------------------------------
# 3. What a user reads before deciding, and afterwards
# ---------------------------------------------------------------------------

suite "PLAT-13: the grant is VISIBLE, and its disclosure is DERIVED":

  test "the disclosure names the checkout, the file and the bytes":
    let text = trustDisclosure(IdentityA, dfkVisualiserCode, DigestOne,
                               "/src/demo")
    ck text.contains(IdentityA)
    ck text.contains("visualisers.wasm")
    ck text.contains(DigestOne)
    ck text.contains("/src/demo")
    ck text.contains("Cloning and opening never ran it")
    ck text.contains("no capabilities at all")
    # IT MOVES WITH THE GRANT. PLAT-8's rule for `traceEgressDisclosure`: a
    # sentence that says the same thing whatever it is describing is a sentence
    # nobody can rely on.
    let other = trustDisclosure(IdentityB, dfkDiffCode, DigestTwo, "/src/other")
    ck other != text
    ck other.contains("diffs.wasm")
    ck not other.contains(DigestOne)
    ck not other.contains(IdentityA)

  test "the disclosure states the residual as well as the refusals":
    let text = trustDisclosure(IdentityA, dfkDiffCode, DigestTwo, "/src/demo")
    ck text.contains("cannot open a file, reach the network or start a process")
    ck text.contains("spend the host's time")
    ck text.contains("return a wrong answer")
    ck text.contains("withdrawing it stops the code running")

  test "describe prints the history AND what is in force":
    var led = grantedLedger()
    discard led.grant(IdentityA, dfkDiffCode, DigestTwo, AtOne, "/src/demo")
    discard led.revoke(IdentityA, dfkVisualiserCode, AtTwo, "changed my mind")
    let text = led.describe(IdentityA)
    ck text.contains("granted visualisers.wasm at " & AtOne)
    ck text.contains("REVOKED visualisers.wasm at " & AtTwo)
    ck text.contains("granted diffs.wasm")
    ck text.contains("in force now: diffs.wasm")
    ck not text.contains("in force now: visualisers.wasm")
    ck led.describe(IdentityB).contains("no executable-tier decision")

  test "forgetting a checkout drops its decisions and nobody else's":
    var led = grantedLedger()
    discard led.grant(IdentityB, dfkVisualiserCode, DigestTwo, AtOne)
    ckEq led.forget(IdentityA), 1
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaNoGrant
    ckAdmits led, IdentityB, dfkVisualiserCode, DigestTwo, etaAdmitted

# ---------------------------------------------------------------------------
# 4. The ledger on the wire
# ---------------------------------------------------------------------------

suite "PLAT-13: the trust ledger round-trips and refuses what it cannot read":

  test "render and parse agree, including the path annotation":
    var led = grantedLedger()
    discard led.revoke(IdentityA, dfkVisualiserCode, AtTwo, "a note with spaces")
    let parsed = parseTrustLedger(led.render())
    ckEq parsed.problems.len, 0
    ckEq parsed.ledger.entries.len, 2
    ckEq parsed.ledger.entries[0].identity, IdentityA
    ckEq parsed.ledger.entries[0].kind, dfkVisualiserCode
    ckEq parsed.ledger.entries[0].digest, DigestOne
    ckEq parsed.ledger.entries[1].note, "a note with spaces"
    ckEq parsed.ledger.stateOf(IdentityA, dfkVisualiserCode), tsRevoked
    ck led.render().startsWith(TrustLedgerHeader)

  test "an unusable line is a PROBLEM and the usable ones survive":
    let text = TrustLedgerHeader & "\n" &
      "grant\t" & IdentityA & "\tvisualisers.wasm\t" & DigestOne & "\t" & AtOne & "\n" &
      "three\tfields\tonly\n" &
      "maybe\t" & IdentityA & "\tdiffs.wasm\t" & DigestOne & "\t" & AtOne & "\n" &
      "grant\t\tdiffs.wasm\t" & DigestOne & "\t" & AtOne & "\n" &
      "grant\t" & IdentityA & "\tnot-a-file.wasm\t" & DigestOne & "\t" & AtOne & "\n" &
      "grant\t" & IdentityA & "\tpoints.toml\t" & DigestOne & "\t" & AtOne & "\n"
    let parsed = parseTrustLedger(text)
    ckEq parsed.ledger.entries.len, 1
    ckEq parsed.problems.len, 5
    ck parsed.problems[0].contains("line 3")
    ck parsed.problems[1].contains("neither 'grant' nor 'revoke'")
    ck parsed.problems[2].contains("checkout identity is empty")
    ck parsed.problems[3].contains("not a definition file")
    ck parsed.problems[4].contains("loads without a decision")
    # A ROW FOR A DECLARATIVE FILE IS NOT KEPT, so `describe` cannot tell a user
    # they trusted something that never needed trusting.
    ckAdmits parsed.ledger, IdentityA, dfkPoints, DigestOne, etaNotExecutableTier
    ckAdmits parsed.ledger, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted

  test "a ledger that carries only rubbish grants nothing":
    let parsed = parseTrustLedger("nonsense\nmore nonsense\n")
    ckEq parsed.ledger.entries.len, 0
    ck parsed.problems.len == 2
    ckAdmits parsed.ledger, IdentityA, dfkVisualiserCode, DigestOne, etaNoGrant

# ---------------------------------------------------------------------------
# 5. The sandbox: what a module is not allowed to be
# ---------------------------------------------------------------------------

suite "PLAT-13: the sandbox is an ALLOW-LIST of nothing, enforced at decode":

  test "a module that asks the host for a function is REFUSED, by name":
    # THE EXPLOIT. `wasi_snapshot_preview1.fd_write` is what a real toolchain
    # emits by default, so this is the module a project would actually ship.
    ckRefusedModule importingModule(), wpcImportDeclared
    let decoded = decodeModule(importingModule())
    ck decoded.problem.detail.contains("handed NOTHING")
    ck decoded.problem.detail.contains("§2.3")
    # THE TWIN: the same shape without the import section decodes and runs, so
    # the refusal is about the import and not about the rest of the module.
    let clean = decodeModule(needleModule())
    ck clean.ok
    ckEq clean.module.functions.len, 1

  test "every section this build does not implement is refused BY ID":
    var checkedSections = 0
    for id in [4, 6, 8, 9, 11, 12, 13, 200]:
      inc checkedSections
      checkpoint("section id " & $id)
      let m = WasmMagic & "\1\0\0\0" & section(id, "\0")
      let decoded = decodeModule(m)
      ck not decoded.ok
      ck decoded.problem.code == wpcUnsupportedSection
    ckEq checkedSections, 8
    # There is no "unsupported, ignored" arm anywhere: a CUSTOM section is the
    # one thing skipped, and it is skipped by LENGTH and never parsed.
    let withCustom = WasmMagic & "\1\0\0\0" &
      section(0, uleb(4) & "name" & "\xff\xff\xff") & needleModule()[8 .. ^1]
    let decoded = decodeModule(withCustom)
    ck decoded.ok
    ckEq decoded.module.exports.len, 1

  test "a value type, a block type and an opcode outside the subset are refused":
    # i64 (0x7E) as a parameter.
    let i64Param = WasmMagic & "\1\0\0\0" &
      section(1, vec([op(0x60) & uleb(1) & op(0x7E) & uleb(0)]))
    ckRefusedModule i64Param, wpcUnsupportedType
    # A block whose type is i32 rather than empty.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: op(0x02) & op(0x7F) & opEndB())]), wpcUnsupportedBlockType
    # f32.add (0x92) — an opcode in wasm 1.0 that this build does not implement.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: op(0x92))]), wpcUnsupportedOpcode
    # memory.grow (0x40): a module may not enlarge its own allowance.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: i32Const(1) & op(0x40) & op(0x00) & Drop)]), wpcUnsupportedOpcode
    # call_indirect (0x11): the route a table would have opened.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: i32Const(0) & op(0x11) & uleb(0) & uleb(0))]), wpcUnsupportedOpcode

  test "a hostile encoding is refused before it becomes an allocation":
    ckRefusedModule "", wpcEmpty
    ckRefusedModule "not a wasm file at all", wpcNotWasm
    ckRefusedModule WasmMagic & "\2\0\0\0", wpcUnsupportedVersion
    ckRefusedModule WasmMagic & "\1\0\0", wpcTruncated
    # A LEB128 WITH THE CONTINUATION BIT SET FOR EVER is the cheapest denial of
    # service a binary format has. Six bytes is refused by name.
    ckRefusedModule WasmMagic & "\1\0\0\0" & "\x01" & padded(4, 6),
      wpcMalformedInteger
    # A section that claims more bytes than the module has.
    ckRefusedModule WasmMagic & "\1\0\0\0" & "\x01" & uleb(9999),
      wpcTruncated
    # Too many pages: the pages are ZEROED at instantiation, so the count is a
    # cost the module chooses for the host.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: "", exportName: "x")], memPages = MaxWasmPages + 1), wpcTooLarge
    # Sections out of the spec's order: two ways to say one thing.
    ckRefusedModule WasmMagic & "\1\0\0\0" & section(3, uleb(0)) &
      section(1, uleb(0)), wpcSectionOutOfOrder
    # A body that does not close its blocks.
    ckRefusedModule buildWasm([FixtureFunc(params: 0, results: 0, locals: 0,
        body: blockEmpty())]), wpcUnbalancedBlock
    # An export naming a function the module does not have.
    ckRefusedModule WasmMagic & "\1\0\0\0" &
      section(1, vec([op(0x60) & uleb(0) & uleb(0)])) &
      section(3, vec([uleb(0)])) &
      section(7, vec([uleb(2) & "go" & op(0x00) & uleb(7)])) &
      section(10, vec([uleb(2) & uleb(0) & opEndB()])), wpcBadIndex

  test "the subset's control flow does what WebAssembly says it does":
    # `call`, `if`/`else`, a declared local, and a `return` from a nested frame.
    # Without this case the interpreter's call and else arms are reachable by no
    # fixture, and an arm aimed at either would be a row in a table that looks
    # like coverage (Verification-Harness-Traps §16).
    let decoded = decodeModule(controlFlowModule())
    if not decoded.ok:
      checkpoint(render(decoded.problem))
    ck decoded.ok
    ckEq decoded.module.functions.len, 2
    #   main(a, b) = helper(a) + (a == b ? 1000 : 2000),  helper(x) = x * 3
    let equalArm = decoded.module.runExport("ct_control", [5'i32, 5'i32])
    ck equalArm.ok
    ckEq equalArm.value, 1015
    let elseArm = decoded.module.runExport("ct_control", [5'i32, 6'i32])
    ck elseArm.ok
    ckEq elseArm.value, 2015
    # THE CALLED FRAME'S RESULT IS THE CALLER'S OPERAND: a return that landed in
    # the wrong frame would answer neither number.
    ckEq decoded.module.runExport("ct_control", [0'i32, 0'i32]).value, 1000
    ckEq decoded.module.runExport("ct_control", [7'i32, 1'i32]).value, 2021
    # A call with the wrong arity is a refusal, not a trap: neither is a
    # property of the run.
    let wrongArity = decoded.module.runExport("ct_control", [1'i32])
    ck not wrongArity.ok
    ckEq wrongArity.trap, wtNone

  test "a module that IS in the subset decodes, and its shape is read back":
    let decoded = decodeModule(byteEqualityDiffModule())
    if not decoded.ok:
      checkpoint(render(decoded.problem))
    ck decoded.ok
    ckEq decoded.module.memoryPages, 1
    ckEq decoded.module.exports.len, 1
    ckEq decoded.module.exports[0].name, DiffExport
    ckEq decoded.module.types[0].params.len, 4
    ckEq decoded.module.types[0].results.len, 1
    ck decoded.module.exportedFunction(DiffExport) >= 0
    ckEq decoded.module.exportedFunction("nothing-of-the-sort"), -1
    ckEq decoded.module.byteCount, byteEqualityDiffModule().len

# ---------------------------------------------------------------------------
# 6. §7: bounded and total, the offender named, the structural fallback taken
# ---------------------------------------------------------------------------

suite "PLAT-13: a definition's code is BOUNDED, and what it costs is COUNTED":

  test "a non-terminating comparison is bounded rather than hanging a pane":
    let decoded = decodeModule(nonTerminatingModule())
    ck decoded.ok
    let run = decoded.module.runExport(DiffExport, [0'i32, 0'i32, 0'i32, 0'i32])
    ck not run.ok
    ckEq run.trap, wtWorkExhausted
    ckEq run.bound, MaxExecutableWork
    ck run.spent > MaxExecutableWork
    # THE OVERSHOOT IS PINNED AS AN EQUALITY, not as an inequality. PLAT-12's
    # measurement is the reason: an inequality generous enough to be safe —
    # twice the bound — passed at 1049% of it. A loop retires one instruction
    # per unit, so the bound is crossed by exactly one.
    ckEq run.spent, MaxExecutableWork + 1

  test "`spent` counts the WORK, and every unit of a small run is enumerable":
    # Verification-Harness-Traps, PLAT-12's four rounds: a bound, a claim and a
    # measurement must describe the same quantity. This case enumerates every
    # unit a run of the needle module costs.
    #
    #   65536  one page, ZEROED at instantiation
    #       2  the entry frame's two parameters, allocated as locals
    #      90  29 characters x 3 instructions (const, const, store8)
    #          + 3 for the NUL terminator
    #       1  the `i32.const 16` that returns the address
    #       1  the body's own `end`
    let decoded = decodeModule(needleModule())
    ck decoded.ok
    let run = decoded.module.runExport(VisualiserExport, [0'i32, 0'i32])
    ck run.ok
    ckEq run.spent, 65536 + 2 + (ExecutionNeedle.len * 3) + 3 + 1 + 1
    ckEq decoded.module.instantiationCost, 65536
    # AND THE MEASUREMENT MOVES WITH THE QUANTITY, which is the half PLAT-12's
    # counter failed: a module that writes one more byte spends three more units.
    let longer = decodeModule(buildWasm([FixtureFunc(params: 2, results: 1,
      locals: 0, body: storeLiteral(16, ExecutionNeedle & "!") & i32Const(16),
      exportName: VisualiserExport)]))
    ck longer.ok
    let longerRun = longer.module.runExport(VisualiserExport, [0'i32, 0'i32])
    ckEq longerRun.spent - run.spent, 3

  test "a trap is a VALUE, and each kind is its own answer":
    var checkedTraps = 0
    for (body, wanted) in [
        (Unreachable, wtUnreachable),
        (i32Const(1) & i32Const(0) & I32DivS & Drop, wtDivideByZero),
        (i32Const(low(int32)) & i32Const(-1) & I32DivS & Drop,
         wtIntegerOverflow),
        (i32Const(-1) & i32Load8U() & Drop, wtOutOfBounds),
        (Drop, wtStackUnderflow)]:
      inc checkedTraps
      checkpoint("trap: " & $wanted)
      let decoded = decodeModule(buildWasm([FixtureFunc(params: 0, results: 0,
        locals: 0, body: body, exportName: "t")]))
      ck decoded.ok
      let run = decoded.module.runExport("t", [])
      ck not run.ok
      ck run.trap == wanted
      ck trapText(run.trap).len > 0
    ckEq checkedTraps, 5
    # THE TWIN: a body doing the same KINDS of operation inside the memory and
    # without a zero divisor answers, so the traps above are about the operands.
    let fine = decodeModule(buildWasm([FixtureFunc(params: 0, results: 0,
      locals: 0, body: i32Const(6) & i32Const(3) & I32DivS & Drop &
                        i32Const(0) & i32Load8U() & Drop, exportName: "t")]))
    ck fine.ok
    ck fine.module.runExport("t", []).ok

  test "a §7 diff that does not answer falls back, and names the OFFENDER":
    let bad = admitExecutable(dfkDiffCode, ".codetracer/diffs.wasm", DigestOne,
                              nonTerminatingModule(), etaAdmitted, IdentityA)
    ck bad.ok
    let diffTrust = grantedLedger(kind = dfkDiffCode)
    let answer = bad.definition.diffWith(diffTrust, "alpha", "alpha")
    # THE VERDICT IS NEVER ABSENT. A comparison that said "I could not compare
    # these" would hang the pane just as surely as the loop, slower.
    ckEq answer.verdict, dvEqual
    ckEq answer.verdict, structuralDiff("alpha", "alpha")
    ck not answer.fromDefinition
    ckEq answer.offender, ".codetracer/diffs.wasm#" & DiffExport
    ckEq answer.problems.len, 1
    ckEq answer.problems[0].code, etcWorkExhausted
    let sentence = describeFallback(answer)
    ck sentence.contains(".codetracer/diffs.wasm#" & DiffExport)
    ck sentence.contains("compared the two values structurally instead")
    # AND THE DIFFERING CASE FALLS BACK TO THE OTHER VERDICT, so the fallback is
    # the structural comparison rather than a constant.
    let differing = bad.definition.diffWith(diffTrust, "alpha", "beta")
    ckEq differing.verdict, dvDifferent
    ck not differing.fromDefinition

  test "a §7 diff that DOES answer is the project's, and says so":
    let good = admitExecutable(dfkDiffCode, ".codetracer/diffs.wasm", DigestOne,
                               byteEqualityDiffModule(), etaAdmitted, IdentityA)
    ck good.ok
    let diffTrust = grantedLedger(kind = dfkDiffCode)
    let same = good.definition.diffWith(diffTrust, "alpha", "alpha")
    ckEq same.verdict, dvEqual
    ck same.fromDefinition
    ckEq same.offender, ""
    ckEq same.problems.len, 0
    ckEq describeFallback(same), ""
    let other = good.definition.diffWith(diffTrust, "alpha", "alphb")
    ckEq other.verdict, dvDifferent
    ck other.fromDefinition
    # AND IT REALLY READ THE HOST'S BYTES: same length, one byte different, and
    # the answer changed — which a module returning a constant cannot do.
    ckEq good.definition.diffWith(diffTrust, "alpha", "alpha").verdict, dvEqual
    ckEq good.definition.diffWith(diffTrust, "alph", "alpha").verdict, dvDifferent
    ck same.spent > 0
    ck same.spent < MaxExecutableWork

# ---------------------------------------------------------------------------
# 7. The crossing: bytes become runnable ONLY through an admission
# ---------------------------------------------------------------------------

suite "PLAT-13: the only door checks the grant BEFORE it looks at the bytes":

  test "without an admission the bytes are not even DECODED":
    # The evidence is the CODE the refusal carries. These bytes are not a wasm
    # module at all, so a door that decoded first would answer
    # `etcMalformedModule`; it answers `etcNoGrant`, which only an untouched
    # `bytes` can produce.
    let refused = admitExecutable(dfkVisualiserCode,
      ".codetracer/visualisers.wasm", DigestOne, "this is not a module",
      etaNoGrant)
    ck not refused.ok
    ckEq refused.problem.code, etcNoGrant
    ck refused.problem.detail.contains("Cloning a repository never grants it")
    ckEq refused.definition.module.functions.len, 0
    # THE TWIN, IN THE SAME CASE: the same bytes WITH an admission reach the
    # decoder and are refused for being rubbish. One function, two callers, and
    # the only difference is the decision (PLAT-8's own shape).
    let reached = admitExecutable(dfkVisualiserCode,
      ".codetracer/visualisers.wasm", DigestOne, "this is not a module",
      etaAdmitted)
    ck not reached.ok
    ckEq reached.problem.code, etcMalformedModule
    ck reached.problem.detail.contains("not a WebAssembly module")

  test "every refusal the door can give is a distinct, reportable answer":
    var checkedAdmissions = 0
    for a in ExecutableTierAdmission:
      inc checkedAdmissions
      checkpoint("admission: " & $a)
      ck admissionText(a).len > 0
      if a != etaAdmitted:
        ck admissionRemedy(a).len > 0
        let refused = admitExecutable(dfkVisualiserCode, "f.wasm", DigestOne,
                                      needleModule(), a)
        ck not refused.ok
        ck refused.problem.code == codeFor(a)
    ckEq checkedAdmissions, ord(high(ExecutableTierAdmission)) + 1
    ck admits(etaAdmitted)
    ck admissionRemedy(etaAdmitted).len == 0

  test "an admitted visualiser RUNS, and the host's bytes reach it":
    let trust = grantedLedger()
    let ok = admitExecutable(dfkVisualiserCode, ".codetracer/visualisers.wasm",
                             DigestOne, needleModule(), etaAdmitted, IdentityA)
    ck ok.ok
    ck ok.definition.hasEntryPoint
    let seen = ok.definition.visualiseWith(trust, "a value")
    ckEq seen.text, ExecutionNeedle
    ck seen.fromDefinition
    ckEq seen.problems.len, 0
    # THE POSITIVE TWIN FOR "THE HOST'S BYTES REACHED THE MODULE". A module that
    # answers the same thing for every input passes the needle assertion above
    # and fails this one.
    let echoes = admitExecutable(dfkVisualiserCode,
      ".codetracer/visualisers.wasm", DigestOne, echoLengthModule(),
      etaAdmitted, IdentityA)
    ck echoes.ok
    ckEq echoes.definition.visualiseWith(trust, "x" .repeat(37)).text, "37"
    ckEq echoes.definition.visualiseWith(trust, "x" .repeat(8)).text, "08"

  test "a module missing the host's entry point is refused, not trapped":
    let trust = grantedLedger()
    let wrong = admitExecutable(dfkVisualiserCode, "v.wasm", DigestOne,
                                moduleWithoutExport("something_else"),
                                etaAdmitted, IdentityA)
    ck wrong.ok
    ck not wrong.definition.hasEntryPoint
    let seen = wrong.definition.visualiseWith(trust, "a value")
    ck not seen.fromDefinition
    ckEq seen.problems[0].code, etcMissingExport
    ckEq seen.offender, "v.wasm#" & VisualiserExport
    ckEq seen.text, ""
    # AND A DIFF FILE IS NOT A VISUALISER FILE: the ABI is a property of the
    # file kind, so calling the wrong one is an answer rather than a trap.
    let diffFile = admitExecutable(dfkDiffCode, "d.wasm", DigestOne,
                                   byteEqualityDiffModule(), etaAdmitted,
                                   IdentityA)
    ck diffFile.ok
    ck not diffFile.definition.visualiseWith(
      grantedLedger(kind = dfkDiffCode), "v").fromDefinition
    ckEq exportFor(dfkVisualiserCode), VisualiserExport
    ckEq exportFor(dfkDiffCode), DiffExport
    ckEq exportFor(dfkPoints), ""

  test "an answer the host will not take is refused, and the value still shows":
    # A module returning an address outside its own memory.
    let liar = admitExecutable(dfkVisualiserCode, "v.wasm", DigestOne,
      buildWasm([FixtureFunc(params: 2, results: 1, locals: 0,
        body: i32Const(999_999), exportName: VisualiserExport)]), etaAdmitted,
      IdentityA)
    ck liar.ok
    let trust = grantedLedger()
    let seen = liar.definition.visualiseWith(trust, "v")
    ck not seen.fromDefinition
    ckEq seen.problems[0].code, etcOutputRefused
    ck seen.problems[0].detail.contains("outside its own memory")
    # A module that never writes a terminator: the BOUND is the host's, so the
    # module cannot decide how long the host's answer is.
    var filler = ""
    for i in 0 ..< MaxExecutableTextBytes + 8:
      filler.add i32Const(int32(16 + i)) & i32Const(65) & i32Store8()
    let endless = admitExecutable(dfkVisualiserCode, "v.wasm", DigestOne,
      buildWasm([FixtureFunc(params: 2, results: 1, locals: 0,
        body: filler & i32Const(16), exportName: VisualiserExport)]),
      etaAdmitted, IdentityA)
    ck endless.ok
    let cut = endless.definition.visualiseWith(trust, "v")
    ck not cut.fromDefinition
    ckEq cut.problems[0].code, etcOutputRefused
    ck cut.problems[0].detail.contains("never wrote a terminator")
    ckEq cut.text, ""

# ---------------------------------------------------------------------------
# 8. The sweep
# ---------------------------------------------------------------------------

suite "PLAT-13: every problem this suite can produce names its file":

  test "the sweep, and it can fail":
    var checkedCodes = 0
    for c in ExecutableTierCode:
      inc checkedCodes
      checkpoint("code: " & $c)
      let p = ExecutableTierProblem(file: ".codetracer/visualisers.wasm",
                                    code: c, detail: "the detail")
      ck namesFile(p)
      ck render(p).contains(".codetracer/visualisers.wasm")
      ck codeText(c).len > 0
    ckEq checkedCodes, ord(high(ExecutableTierCode)) + 1
    # THE CONTROL. `namesFile` is a function precisely so the rule and its
    # control are one piece of code (§14); here is the control.
    ck not namesFile(ExecutableTierProblem(file: "", code: etcNoGrant,
                                           detail: "no file"))

  test "every wasm refusal has a spelling, and render names the offset":
    var checkedWasm = 0
    for c in WasmProblemCode:
      inc checkedWasm
      ck codeText(c).len > 0
    ckEq checkedWasm, ord(high(WasmProblemCode)) + 1
    var checkedTrapText = 0
    for t in WasmTrap:
      inc checkedTrapText
      ck trapText(t).len > 0
    ckEq checkedTrapText, ord(high(WasmTrap)) + 1
    let rendered = render(WasmProblem(code: wpcImportDeclared, at: 22,
                                      detail: "a detail"))
    ck rendered.contains("at 22")
    ck rendered.contains("a detail")

# ---------------------------------------------------------------------------
# 9. THE BOUND'S UNIT. One retired instruction is O(1), or the bound is a
#    bound on the wrong quantity.
# ---------------------------------------------------------------------------

const
  ProbeWork = 200_001
    ## Enough retired instructions for a per-instruction cost to be visible,
    ## few enough that a correct run is milliseconds.
  LongBody = 8000
    ## Inside `MaxWasmBodyInstr` (8,192) and inside `MaxWasmBytes`, so this is
    ## a module a repository could actually ship rather than a thought
    ## experiment.
  SlowdownTolerance = 10
  SlowdownFloorUs = 200_000
    ## THE BUDGET IS `short * 10 + 200 ms`, AND BOTH TERMS ARE ARGUED.
    ##
    ## Verification-Harness-Traps §12a: an absolute bound on one measurement is
    ## a coin flip that reads the scheduler. So the budget is measured against
    ## a signal taken IN THE SAME PROCESS, by the same code, microseconds
    ## earlier — the same module at a short body — and both sides carry the
    ## same noise. §12's question, answered with numbers (2026-09-13, this
    ## host, one session, best of seven):
    ##
    ##   | mm | | short | long | budget | verdict |
    ##   |---|---|---|---|---|---|
    ##   | orc | aliased (shipped) | 7.4 ms | 7.3 ms | 274 ms | passes, 37x under |
    ##   | orc | copying the body | 24.1 ms | **7,819.8 ms** | 441 ms | fails by 18x |
    ##   | orc | copying the callee | 28.6 ms | **3,390.8 ms** | 486 ms | fails by 7.0x |
    ##   | refc | copying the body | 22.1 ms | 22.6 ms | 421 ms | **PASSES** |
    ##   | refc | copying the callee | 35.6 ms | 36.7 ms | 556 ms | **PASSES** |
    ##
    ## The floor exists because the ratio alone divides by a few milliseconds;
    ## 200 ms is 15x below the smallest broken measurement, so it absorbs a
    ## descheduled run without absorbing the defect.
    ##
    ## **AND THE LAST TWO ROWS ARE WHY `ckFlatIn` ASSERTS ITS OWN BUILD.** The
    ## defect is `let x = someSeq`, which is a COPY under ORC and a REFCOUNT
    ## BUMP under refc — so under refc these two cases cannot fail, and a lane
    ## that compiled this file `--mm:refc` would carry two green cases that
    ## grade nothing. `common-units` uses Nim 2.x's default ORC today;
    ## `ct-cli-units` uses `--mm:refc`, and every SHIPPED binary is refc
    ## (`repro.nim`'s `ctNative` and `ctNimJs`, and `src/Tuprules.tup`), which
    ## is the plain statement of which builds were ever affected: this one's
    ## lane, and no shipped `ct`.

type Probe = object
  spent: int
  micros: int64
  instrCount: int
    ## EVERY function's body, summed. Not the longest: `paddedCalleeModule`
    ## pads the CALLEE and the exported function is the short one, so a maximum
    ## would report a difference the padding did not make.

proc probeRun(bytes: string): Probe =
  ## BEST OF THREE, and the same three on both sides. The smallest of a few
  ## runs is the one with the least scheduler noise in it; taking the same
  ## statistic for the baseline and the subject is what makes their ratio mean
  ## something.
  ##
  ## No `check` anywhere in here — Verification-Harness-Traps §13: a `check`
  ## inside a plain `proc` assigns a module-level `testStatusIMPL` and the test
  ## reports `[OK]` with the failure printed above it. `doAssert` raises.
  let d = decodeModule(bytes)
  doAssert d.ok, render(d.problem)
  for f in d.module.functions:
    result.instrCount += f.body.len
  result.micros = high(int64)
  for _ in 0 ..< 3:
    let t0 = getMonoTime()
    let r = d.module.runExport(DiffExport, [0'i32, 0'i32, 0'i32, 0'i32],
                               ProbeWork)
    result.micros = min(result.micros, (getMonoTime() - t0).inMicroseconds)
    result.spent = r.spent
    doAssert r.trap == wtWorkExhausted, $r.trap

template ckFlatIn(short, long: Probe; what: string) =
  ## The comparison, written once so the two cases below cannot come to
  ## disagree about what "flat" means (§14).
  ##
  ## IT ASSERTS THE MEMORY MANAGER FIRST, AND THAT IS NOT DEFENSIVE TIDINESS.
  ## The copy this measures is a copy under ORC and a refcount bump under refc,
  ## so under refc the comparison below passes with the defect restored — an
  ## assertion that cannot fail, which is Verification-Harness-Traps §10 wearing
  ## a build flag. The precondition is asserted rather than assumed, so a lane
  ## that changes `--mm` turns these cases RED instead of quietly vacuous.
  inc countedAssertions
  if not (defined(gcOrc) or defined(gcArc)):
    checkpoint("this case grades a `let x = someSeq` copy, which only ORC/ARC " &
               "makes a copy. Under refc it cannot fail and is not evidence")
  check defined(gcOrc) or defined(gcArc)
  inc countedAssertions
  let budget = short.micros * SlowdownTolerance + SlowdownFloorUs
  if long.micros > budget:
    checkpoint(what & ": " & $short.instrCount & " instruction(s) took " &
               $short.micros & " us and " & $long.instrCount & " took " &
               $long.micros & " us, budget " & $budget &
               " us. `spent` is identical at " & $long.spent &
               ", so the bound cannot see this")
  check long.micros <= budget

suite "PLAT-13: one RETIRED INSTRUCTION is one unit, whatever the body's length":

  test "a body 1,600x longer spends the same AND takes the same time":
    # WHY THIS CASE EXISTS. `spent` is a correct count of retired instructions
    # and says nothing about what one costs, so a run loop that copied the
    # function body per instruction reported 1,000,001 of 1,000,000 while
    # taking 66.9 s on an 8 KB module (ORC — see `SlowdownFloorUs`). Every assertion about `spent` in this
    # file was satisfied by it, and the §7 fixture's body is 5 instructions —
    # an amplification factor of ONE, which is why the suite was blind.
    let short = probeRun(paddedLoopModule(0))
    let long = probeRun(paddedLoopModule(LongBody))
    # THE FIXTURE IS PROVED BEFORE IT IS USED (§4): a generator that ignored
    # `pad` would make every assertion below pass for free.
    ckEq long.instrCount - short.instrCount, LongBody
    ck short.instrCount < 10
    # THE BOUND SAYS THE SAME NUMBER — which is the finding, not an aside.
    ckEq short.spent, long.spent
    ckEq long.spent, ProbeWork + 1
    ckFlatIn short, long, "the retired-instruction cost"

  test "a CALL to a long-bodied function costs the same as a call to a short one":
    # `opCall` and `enter` copied the callee's whole `WasmFunction` — the same
    # defect one level up, and reached by a different route, so it needs a case
    # of its own rather than sharing the one above (§16a).
    let short = probeRun(paddedCalleeModule(0))
    let long = probeRun(paddedCalleeModule(LongBody))
    ckEq long.instrCount - short.instrCount, LongBody
    ckEq short.spent, long.spent
    ckEq long.spent, ProbeWork + 1
    ckFlatIn short, long, "the call cost"

# ---------------------------------------------------------------------------
# 10. The ledger's GRAMMAR is closed, because one of its fields is a path
# ---------------------------------------------------------------------------

suite "PLAT-13: one grant records ONE decision, and a note cannot make it two":

  test "a NEWLINE in the note is refused, and the forged row is a real one":
    # THE EXPLOIT, and it is what `grantExecutableTier` hands the ledger by
    # default: the note is the CHECKOUT PATH, and a directory name is chosen
    # by whoever ran `git clone`.
    let forged = "/tmp/evil\n" &
      ["grant", IdentityB, "visualisers.wasm", DigestTwo, AtOne,
       "forged"].join($TrustFieldSeparator)

    # THE PLANT IS PROVED FIRST (§4, §7). Pasted into a ledger FILE, the second
    # line is an ordinary, well-formed row and the VICTIM checkout — which the
    # user decided nothing about — is granted. No reader can fix that: a file
    # with two rows has two rows. That is why the refusal has to be the
    # WRITER's, and it is what makes the assertions below non-vacuous.
    let asFile = TrustLedgerHeader & "\n" &
      ["grant", IdentityA, "visualisers.wasm", DigestOne, AtOne,
       forged].join($TrustFieldSeparator) & "\n"
    let pasted = parseTrustLedger(asFile)
    ckEq pasted.ledger.entries.len, 2
    ckEq pasted.ledger.stateOf(IdentityB, dfkVisualiserCode), tsGranted
    ckAdmits pasted.ledger, IdentityB, dfkVisualiserCode, DigestTwo, etaAdmitted

    # AND THE WRITER REFUSES IT. One call, zero rows, and the victim untouched.
    var led: ProjectTrustLedger
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne, forged),
         troUnwritableField
    ckEq led.entries.len, 0
    ckAdmits led, IdentityB, dfkVisualiserCode, DigestTwo, etaNoGrant
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaNoGrant
    # THE TWIN, IN THE SAME CASE: the same call with a note that IS a field
    # records exactly one decision and round-trips.
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne, "/tmp/fine"),
         troRecorded
    ckEq led.entries.len, 1
    ckEq parseTrustLedger(led.render()).ledger.entries.len, 1
    ckEq parseTrustLedger(led.render()).problems.len, 0

  test "every field is closed, not only the note":
    var led: ProjectTrustLedger
    ckEq led.grant(IdentityA & "\tx", dfkVisualiserCode, DigestOne, AtOne),
         troUnwritableField
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne & "\nx", AtOne),
         troUnwritableField
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne & "\ty"),
         troUnwritableField
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne, "n\rx"),
         troUnwritableField
    ckEq led.revoke(IdentityA, dfkVisualiserCode, "at\nnow"), troUnwritableField
    ckEq led.revoke(IdentityA, dfkVisualiserCode, AtOne, "note\twith\ttabs"),
         troUnwritableField
    ckEq led.entries.len, 0
    # `record` is the one constructor and enforces it there, so `grant` and
    # `revoke` cannot come to disagree with each other (§14).
    ck not led.record(IdentityA, dfkVisualiserCode, tdGranted, DigestOne, AtOne,
                      "a\nb")
    ckEq led.entries.len, 0
    # The predicate itself, with its positive twin.
    ck representableField("/src/demo — a note with spaces and an em dash")
    ck representableField("")
    ck not representableField("a\tb")
    ck not representableField("a\nb")
    ck not representableField("a\rb")
    ck unrepresentableFieldText().len > 0
    # AND THE TWO NON-RECORDS ARE DIFFERENT ANSWERS, which is the half of this
    # a `bool` could not carry: "nothing needed writing" and "nothing COULD be
    # written" both appended no row, and both were `false` until 2026-09-13.
    # `decisionStands` is where they part, and it is one function so the grant's
    # caller and the revocation's cannot part differently (§14).
    ck decisionStands(troUnchanged)
    ck not recorded(troUnchanged)
    ck not decisionStands(troUnwritableField)
    ck outcomeText(troUnwritableField) != outcomeText(troUnchanged)
    ck outcomeText(troUnwritableField).contains(unrepresentableFieldText())
    # THE TWIN: every field representable records one row.
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne, "ordinary"),
         troRecorded
    ckEq led.entries.len, 1

  test "a path that cannot be a field loses its ANNOTATION, never its grant":
    # Refusing the GRANT would be a repair that fails in the safe direction
    # (Verification-Harness-Traps §15): nothing would go red, and a user whose
    # checkout sits under an exotic directory name would simply never be able
    # to trust it. The path decides nothing, so the path is what is dropped.
    ckEq pathAnnotation("/src/demo"), "/src/demo"
    ckEq pathAnnotation("/src/de\nmo"), UnrepresentablePathNote
    ckEq pathAnnotation("/src/de\tmo"), UnrepresentablePathNote
    ck representableField(UnrepresentablePathNote)
    var led: ProjectTrustLedger
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtOne,
                   pathAnnotation("/src/de\nmo")), troRecorded
    ckEq led.entries.len, 1
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaAdmitted
    let round = parseTrustLedger(led.render())
    ckEq round.problems.len, 0
    ckEq round.ledger.entries.len, 1
    ck led.describe(IdentityA).contains(UnrepresentablePathNote)

  test "a row with more than six fields is a PROBLEM, not a rejoined note":
    # The reader used to rejoin `parts[5 .. ^1]`, which is a decoder for an
    # encoding the writer can no longer emit. A seven-field row is now a hand
    # edit or an injection attempt, and both are worth naming.
    let seven = TrustLedgerHeader & "\n" &
      ["grant", IdentityA, "visualisers.wasm", DigestOne, AtOne, "a",
       "b"].join($TrustFieldSeparator) & "\n"
    let parsed = parseTrustLedger(seven)
    ckEq parsed.ledger.entries.len, 0
    ckEq parsed.problems.len, 1
    ck parsed.problems[0].contains("got 7")
    # THE TWIN: six fields is a note and five is a row without one.
    let six = TrustLedgerHeader & "\n" &
      ["grant", IdentityA, "visualisers.wasm", DigestOne, AtOne,
       "a note"].join($TrustFieldSeparator) & "\n" &
      ["revoke", IdentityB, "diffs.wasm", "", AtTwo].join($TrustFieldSeparator) &
      "\n"
    let ok = parseTrustLedger(six)
    ckEq ok.problems.len, 0
    ckEq ok.ledger.entries.len, 2
    ckEq ok.ledger.entries[0].note, "a note"
    ckEq ok.ledger.entries[1].note, ""

  test "the ZERO VALUE of every decision type is the refusing one":
    # PLAT-12's `Visualiser.tier` lesson, swept over this campaign's own enums.
    # `ExecutableTierAdmission`'s zero was `etaAdmitted` and `TrustDecision`'s
    # was `tdGranted` until 2026-09-13 — latent, because no site
    # default-constructs one, which is exactly how PLAT-12's arrived.
    ckEq low(TrustState), tsUndecided
    ckEq low(TrustDecision), tdRevoked
    ckEq low(ExecutableTierAdmission), etaNoGrant
    # `TrustRecordOutcome` arrived on 2026-09-13 with the same rule applied
    # before it could cost anything: the zero is a NON-record, so a producer
    # that forgets the field reports "nothing was written" rather than "it is
    # recorded and in force".
    ckEq low(TrustRecordOutcome), troNoIdentity
    ckEq default(TrustRecordOutcome), troNoIdentity
    ck not recorded(default(TrustRecordOutcome))
    ck not decisionStands(default(TrustRecordOutcome))
    ckEq default(TrustDecision), tdRevoked
    ckEq default(ExecutableTierAdmission), etaNoGrant
    ckEq default(TrustState), tsUndecided
    ck not admits(default(ExecutableTierAdmission))
    # A ROW NOBODY FILLED IN IS A REVOCATION, end to end.
    var led: ProjectTrustLedger
    led.entries.add TrustEntry(identity: IdentityA, kind: dfkVisualiserCode)
    ckEq led.stateOf(IdentityA, dfkVisualiserCode), tsRevoked
    ckAdmits led, IdentityA, dfkVisualiserCode, DigestOne, etaRevoked
    # THE TWIN: the permissive values still exist and still spell themselves.
    ck admits(etaAdmitted)
    ckEq $tdGranted, "grant"
    ckEq $tdRevoked, "revoke"

# ---------------------------------------------------------------------------
# 11. A HELD handle cannot outlive its grant
# ---------------------------------------------------------------------------

suite "PLAT-13: withdrawing a grant stops a handle that is ALREADY loaded":

  test "a revoke reaches a handle somebody is holding, asserted THROUGH it":
    # PLAT-10's `resolveAll()`, arriving one tier up.
    # `ExecutableDefinition.module` IS the cached parse, so a suite that
    # asserts revocation by RE-LOADING and finding nothing is asserting the one
    # thing that cannot see a handle already in hand. This case never reloads.
    var led = grantedLedger()
    let held = admitExecutable(dfkVisualiserCode, ".codetracer/visualisers.wasm",
                               DigestOne, needleModule(), etaAdmitted, IdentityA)
    ck held.ok
    ckEq held.definition.identity, IdentityA
    ckEq held.definition.stillAdmitted(led), etaAdmitted
    ckEq held.definition.visualiseWith(led, "v").text, ExecutionNeedle
    ck held.definition.visualiseWith(led, "v").fromDefinition

    # The user changes their mind. THE HANDLE IS THE SAME OBJECT.
    ckEq led.revoke(IdentityA, dfkVisualiserCode, AtTwo, "changed my mind"),
         troRecorded
    ckEq held.definition.stillAdmitted(led), etaRevoked
    let after = held.definition.visualiseWith(led, "v")
    ck not after.fromDefinition
    ckEq after.text, ""
    ckEq after.problems.len, 1
    ckEq after.problems[0].code, etcRevoked
    ck after.problems[0].detail.contains("it was NOT run")
    ckEq after.offender, ".codetracer/visualisers.wasm#" & VisualiserExport

    # AND THE OTHER TWO MECHANISMS REACH THE HANDLE TOO, each with evidence
    # only it can produce (§16a): forgetting the checkout, and re-granting the
    # same file over DIFFERENT bytes.
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestTwo, AtTwo), troRecorded
    ckEq held.definition.stillAdmitted(led), etaContentChanged
    ckEq held.definition.visualiseWith(led, "v").problems[0].code,
         etcContentChanged
    ckEq led.forget(IdentityA), 3
    ckEq held.definition.stillAdmitted(led), etaNoGrant
    ckEq held.definition.visualiseWith(led, "v").problems[0].code, etcNoGrant

    # THE TWIN, IN THE SAME CASE: granting THESE bytes again brings the same
    # handle back to life, so the refusals above are the decision and not a
    # handle that has simply stopped working.
    ckEq led.grant(IdentityA, dfkVisualiserCode, DigestOne, AtTwo), troRecorded
    ckEq held.definition.visualiseWith(led, "v").text, ExecutionNeedle

  test "a §7 comparison from a held handle falls back once the grant is gone":
    var led = grantedLedger(kind = dfkDiffCode)
    let held = admitExecutable(dfkDiffCode, ".codetracer/diffs.wasm", DigestOne,
                               byteEqualityDiffModule(), etaAdmitted, IdentityA)
    ck held.ok
    ck held.definition.diffWith(led, "alpha", "alpha").fromDefinition
    ckEq led.revoke(IdentityA, dfkDiffCode, AtTwo), troRecorded
    let answer = held.definition.diffWith(led, "alpha", "alpha")
    # THE VERDICT IS STILL NEVER ABSENT — the pane gets the structural answer.
    ckEq answer.verdict, dvEqual
    ck not answer.fromDefinition
    ckEq answer.problems[0].code, etcRevoked
    ckEq answer.offender, ".codetracer/diffs.wasm#" & DiffExport
    ckEq held.definition.diffWith(led, "alpha", "beta").verdict, dvDifferent
    ck describeFallback(answer).contains("the trust grant for this repository was revoked")
    # AND IT DID NOT RUN: `spent` never left the caller's charge, because the
    # refusal is before `prepare`.
    ckEq answer.spent, 0

# ---------------------------------------------------------------------------
# 12. The guards a crash would go through, each with a module that reaches it
# ---------------------------------------------------------------------------

suite "PLAT-13: the guards between a granted module and a Defect in the HOST":

  test "a module that declares NO memory is refused, not indexed out of bounds":
    # `writeBytes`' bounds check is the only thing between a granted,
    # well-formed, correctly-exporting module and an `IndexDefect` raised out
    # of the host — the host writes its input at 1,024 into a memory of length
    # zero. A sandbox whose failure mode is a Defect is not a sandbox.
    let trust = grantedLedger()
    let zero = admitExecutable(dfkVisualiserCode, "v.wasm", DigestOne,
                               zeroPageVisualiserModule(), etaAdmitted, IdentityA)
    ck zero.ok
    ck zero.definition.hasEntryPoint
    ckEq zero.definition.module.memoryPages, 0
    # `writeBytes` FIRST, with both halves over one instance (§4a) — and the
    # ORDER is deliberate: the end-to-end call below raises rather than
    # returning, so a case that led with it would abort before reaching a
    # single assertion, and the only thing an arm could be attributed to would
    # be an `IndexDefect` message two other arms also produce (§17a).
    var inst = zero.definition.module.instantiate()
    ckEq inst.memory.len, 0
    # THE ZERO-LENGTH WRITE COMES FIRST, and the order is load-bearing twice
    # over. `writeBytes(-1, "")` writes no bytes, so without the guard it
    # RETURNS TRUE rather than raising — which makes it the one assertion here
    # that can report a failure instead of dying in the middle of one, and
    # therefore the only thing an arm on this guard can be attributed to
    # (§17a). The raising case is next, and it is the one that shows the cost.
    ck not inst.writeBytes(-1, "")
    ck not inst.writeBytes(0, "x")
    var page = decodeModule(needleModule()).module.instantiate()
    ck page.writeBytes(16, "x")
    ck not page.writeBytes(page.memory.len, "x")
    ck not page.writeBytes(page.memory.len - 1, "xx")
    ck page.writeBytes(page.memory.len - 1, "x")
    # AND END TO END: the host's write into a memory of length zero.
    let seen = zero.definition.visualiseWith(trust, "a value")
    ck not seen.fromDefinition
    ckEq seen.text, ""
    ckEq seen.problems[0].code, etcOutputRefused
    ck seen.problems[0].detail.contains("not enough memory")

  test "a function that declares a result and leaves nothing is a TRAP":
    # `ret`'s own underflow guard — a DIFFERENT guard from the `pop()` template
    # the `Drop` fixture drives, so each has evidence only it can satisfy
    # (§16a). Without it the host reads `stack[^1]` on an empty seq.
    let d = decodeModule(returnsNothingModule())
    ck d.ok
    let run = d.module.runExport("t", [])
    ck not run.ok
    ckEq run.trap, wtStackUnderflow
    # THE TWIN: the same shape with a value on the stack answers.
    let fine = decodeModule(buildWasm([FixtureFunc(params: 0, results: 1,
      locals: 0, body: i32Const(42), exportName: "t")]))
    ck fine.ok
    ckEq fine.module.runExport("t", []).value, 42

  test "a call with fewer operands than the callee's parameters is a TRAP":
    # `enter`'s operand test. Without it `stack.pop()` runs on an empty seq.
    let d = decodeModule(callWithTooFewOperandsModule())
    ck d.ok
    let run = d.module.runExport("t", [])
    ck not run.ok
    ckEq run.trap, wtStackOverflow

  test "a callee cannot take an OUTER frame's operands":
    # The operand test compares against the CALLER's `stackBase` and not
    # against the whole stack's height — which is what wasm's validator
    # guarantees and what this interpreter has no other check for. Three frames
    # are needed for the escape to exist at all; see the fixture.
    let d = decodeModule(calleeReachingIntoCallerModule())
    ck d.ok
    ckEq d.module.functions.len, 3
    let run = d.module.runExport("t", [])
    ck not run.ok
    ckEq run.trap, wtStackOverflow
    ck run.value != 333
    # THE TWIN, THROUGH THE SAME THREE-FRAME SHAPE: a nested call that brings
    # its own operands answers. Without it, "a nested call is refused" is
    # equally satisfied by an interpreter that refuses every nested call.
    let good = decodeModule(nestedCallAnswersModule())
    ck good.ok
    let ok = good.module.runExport("t", [])
    ck ok.ok
    ckEq ok.value, 7

  test "a second 'else' decodes, and falling out of the 'then' arm TRAPS":
    # The counterexample to the run loop's former "UNREACHABLE BY
    # CONSTRUCTION": the first `else` keeps `target = -1`, so a `pc` of -1 is
    # reachable from a module a repository can ship. The guard is what makes
    # that a trap rather than an `IndexDefect`.
    let d = decodeModule(doubleElseModule())
    ck d.ok
    let run = d.module.runExport("t", [])
    ck not run.ok
    ckEq run.trap, wtUnreachable
    # THE TWIN: one `else` resolves and the module answers.
    let one = decodeModule(controlFlowModule())
    ck one.ok
    ckEq one.module.runExport("ct_control", [5'i32, 5'i32]).value, 1015

  test "the locals bound is tested BEFORE the locals are allocated":
    # The declared count is what the decoder would allocate from, and a `u32`
    # reaches 2^31-1 — two billion `seq.add`s, and the host is gone. The bound
    # is tested before the append, so the refusal costs one comparison.
    ckRefusedModule tooManyLocalsModule(MaxWasmLocals + 1), wpcTooLarge
    ckRefusedModule tooManyLocalsModule(100_000), wpcTooLarge
    # THE TWIN: exactly the bound decodes, so the refusal is about the excess.
    let at = decodeModule(tooManyLocalsModule(MaxWasmLocals))
    ck at.ok
    ckEq at.module.functions[0].localTypes.len, MaxWasmLocals

  test "more code bodies than declared functions is refused, not indexed":
    # `typeCounts[i]` is indexed once per body; the count test is the only
    # thing between a module a repository ships and an `IndexDefect`.
    ckRefusedModule codeBodyCountMismatchModule(2), wpcBadIndex
    ckRefusedModule codeBodyCountMismatchModule(7), wpcBadIndex
    let one = decodeModule(codeBodyCountMismatchModule(1))
    ck one.ok
    ckEq one.module.functions.len, 1

  test "a padded LEB128 INSIDE the five-byte bound is the spec's own encoding":
    # A deliberate asymmetry, argued in `u32leb`'s header and falsifiable here
    # (§7a): `80 80 80 80 00` is a well-formed `u32` per the WebAssembly binary
    # format — the grammar is recursive over at most ceil(32/7) = 5 bytes and
    # constrains only the VALUE — so accepting it is conformance rather than
    # laxity. A SIXTH byte is refused.
    let padded5 = decodeModule(WasmMagic & "\1\0\0\0" & section(1, padded(0, 5)))
    ck padded5.ok
    ckEq padded5.module.types.len, 0
    ckRefusedModule WasmMagic & "\1\0\0\0" & section(1, padded(0, 6)),
      wpcMalformedInteger
    # And the ordinary encoding of the same value decodes to the same module.
    let plain = decodeModule(WasmMagic & "\1\0\0\0" & section(1, uleb(0)))
    ck plain.ok
    ckEq plain.module.types.len, padded5.module.types.len

  test "an immediate past 2^31-1 is refused, not narrowed into a RangeDefect":
    # `u32leb`'s RANGE test, which is a DIFFERENT guard from its five-byte
    # length bound and needs a module only it refuses (§16a). `FF FF FF FF 7F`
    # is five bytes — inside the length bound, and the case above says why that
    # is the spec's own rule — carrying 34,359,738,367. `decodeBody` narrows a
    # `local.get` immediate with `int32(...)`, so without this test the refusal
    # is a `RangeDefect` unwound out of the decoder:
    #
    #   Error: unhandled exception: value out of range: 34359738367 notin
    #   -2147483648 .. 2147483647 [RangeDefect]
    #
    # A decoder whose failure mode is a Defect takes the host down with a file
    # a repository ships, which is `W22`-`W26`'s finding in a sixth place.
    ckRefusedModule hugeImmediateModule(), wpcMalformedInteger
    let refused = decodeModule(hugeImmediateModule())
    ck render(refused.problem).contains("larger than 2^31-1")
    # THE TWIN: the same instruction with an in-range index decodes and runs, so
    # the refusal is about the VALUE rather than about `local.get`.
    let fine = decodeModule(buildWasm([FixtureFunc(params: 4, results: 1,
      locals: 0, body: localGet(1), exportName: "ct_diff")]))
    ck fine.ok
    ckEq fine.module.runExport("ct_diff", [7'i32, 9'i32, 0'i32, 0'i32]).value, 9

  test "an operand stack past its bound is a TRAP, not a seq that keeps growing":
    # `push`'s depth test. Its absence is not a crash — `MaxWasmBodyInstr`
    # bounds how many pushes a body can contain — which is exactly why it needs
    # an arm: what is lost is the BOUND, silently, and the module goes on to
    # ANSWER where it should have trapped. The pair is taken at the boundary in
    # both directions, so the arm cannot be killed by an off-by-one instead.
    let over = decodeModule(stackDepthModule(MaxWasmStack + 1))
    ck over.ok
    let run = over.module.runExport(DiffExport, [0'i32, 0'i32, 0'i32, 0'i32],
                                    MaxExecutableWork)
    ck not run.ok
    ckEq run.trap, wtStackOverflow
    # THE TWIN, AT THE BOUND EXACTLY: 1,024 operands is the deepest stack this
    # build runs, and it answers.
    let at = decodeModule(stackDepthModule(MaxWasmStack))
    ck at.ok
    let fine = at.module.runExport(DiffExport, [0'i32, 0'i32, 0'i32, 0'i32],
                                   MaxExecutableWork)
    ck fine.ok
    ckEq fine.value, 1

  test "every way a module can end early is a DISTINCT report":
    # `wpcTruncated` has six producers, and a mutation removing any one of them
    # survives while another answers for it (§16a). Each gets a module only it
    # refuses, asserted on the DETAIL rather than on the code.
    var seenDetails: seq[string] = @[]
    for (bytes, needle) in [
        (WasmMagic & "\1\0\0", "byte(s) were wanted"),
        (WasmMagic & "\1\0\0\0" & "\x01" & uleb(9999), "and the module has"),
        (WasmMagic & "\1\0\0\0" & "\x01", "a byte was wanted"),
        (WasmMagic & "\1\0\0\0" & section(1, vec([op(0x60) & uleb(0) & uleb(0)])) &
           section(3, vec([uleb(0)])), "no code section followed"),
        (WasmMagic & "\1\0\0\0" & section(1, vec([op(0x60) & uleb(0) & uleb(0)])) &
           section(3, vec([uleb(0)])) &
           section(10, vec([uleb(99) & uleb(0) & opEndB()])),
         "runs past its section"),
        (WasmMagic & "\1\0\0\0" & section(1, vec([op(0x60) & uleb(0) & uleb(0)])) &
           section(3, vec([uleb(0)])) &
           section(10, vec([uleb(3) & uleb(0) & opEndB() & op(0x01)])),
         "did not end where its length said")]:
      checkpoint("needle: " & needle)
      let decoded = decodeModule(bytes)
      if decoded.ok or not render(decoded.problem).contains(needle):
        checkpoint("got " & (if decoded.ok: "a DECODED module"
                             else: render(decoded.problem)) & "\n  bytes: " &
                   describeBytes(bytes))
      ck (not decoded.ok) and render(decoded.problem).contains(needle)
      seenDetails.add needle
    ckEq seenDetails.len, 6

# ---------------------------------------------------------------------------

suite "PLAT-13: the counted-assertion tally":

  test "the tally":
    # Verification-Harness-Traps §4c: a per-check assertion count is a
    # fingerprint, and a check that asserts its own count turns a silent skip
    # into a red run with no second run and no human noticing.
    check countedAssertions == ExpectedAssertions
