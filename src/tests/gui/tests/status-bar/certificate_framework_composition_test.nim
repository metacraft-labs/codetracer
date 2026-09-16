## CTC-2 — a workspace that more than one framework has certified.
##
## `certificate_indicator_vm_test.nim` (SB-1) proves the five states are
## decided correctly for **one** record. This file is about the case CTC-2
## exists for: a store holding records from `ct test` AND from reprobuild at
## once, plus a neighbour from a framework this consumer has never heard of.
##
## Three properties, each grounded in the standard rather than in the code:
##
## 1. **Each record is evaluated against its own claim** (Verification.md §2:
##    "A consumer MUST NOT apply its own validity rules to another framework's
##    certificate, even when the record parses cleanly. The fields are shared;
##    their framework-specific meaning is not.") For a consumer that implements
##    no framework-specific rule at all, that comes to this: the requirement a
##    record is judged against is built from *its* framework, *its* targets and
##    *its* scope, and never from a neighbour's.
## 2. **An unrecognised framework's record is IGNORED, not rejected**
##    (Verification.md §2, §7). It is not evidence for this consumer and it is
##    not evidence against anything either — so it must not stop a record that
##    does bind from certifying, and it must not make the workspace read as
##    broken. Asserted at both levels: on `verifyCertificates`, where the
##    framework filter lives, and on the indicator, where getting it wrong
##    turns a harmless neighbour into a broken workspace.
## 3. **A `ct test` certificate and a reprobuild certificate carrying the same
##    claim RENDER identically** — compared by rendering both through the real
##    status shell and diffing the DOM, not by reading the code. The two
##    records genuinely differ in `framework`, `issuer` and `commands`; the
##    only things a user may see differ are the disclosed rows that name those
##    facts.
##
## ## Why the indicator does not filter by framework, and why that is not a
## ## violation of §2
##
## §2 says a consumer filters to the frameworks it *implements*. The framework
## filter selects which records are that consumer's to evaluate — and the
## status bar implements exactly one thing, the **generic** check
## (Verification.md §4.1), for every framework and no framework-specific rule
## for any of them (§4.2 forbids inventing a generic substitute for that step,
## so it is absent rather than approximated). That is not a shortcut, it is the
## milestone's requirement: SB-1 and CTC-2 both require reprobuild's records to
## be read identically to `ct test`'s, and `framework = "reprobuild"` is not
## `framework = "ct-test"`. A consumer that filtered to its own vendor's
## records could not satisfy that at all.
##
## So "Certified" here means what SB-1's module header says it means: the
## generic check passed, and nothing more.
##
## ## The one fake
##
## `CertificateStoreAccess` is an in-memory tree, for the reason SB-1's headless
## suite records: this file runs on **both** Nim backends and `std/os` does not
## exist under `nim js`. Everything else is real — real documents from the
## shipped `renderCertificate`, the shipped `readCertificate`, the shipped
## `verifyCertificates`, the shipped projection and the shipped status shell.
## No agent session, service or layout is constructed anywhere in this file.

import std/[algorithm, options, strutils, tables, unittest]

import isonim/testing/mock_dom

import views/status_certificate_projection

import ../../../../ct_test/certificate
import ../../../../ct_test/certificate_verification

# ---------------------------------------------------------------------------
# Countable assertions
#
# `[OK]` counts test BLOCKS, and a block that asserts nothing prints one too,
# so the lane cannot score this file from its own output unless the file says
# how many checks it ran. `ck` is `check` plus a tally; the total is printed as
# `CHECKS: <n>` at the end of the file, which is what `ci/lib/run-nim-test-lane.sh`
# reads.
# ---------------------------------------------------------------------------
var checksRun = 0

template ck(condition: untyped) =
  inc checksRun
  check condition

# ---------------------------------------------------------------------------
# A workspace the test can move around under the indicator
# ---------------------------------------------------------------------------

type
  FakeFile = object
    text: string
    modifiedMs: int64

  FakeWorld = ref object
    files: Table[string, FakeFile]
    vcs: WorkspaceVcsState
    platform: string

const
  RepoName = "demo-project"
  WorkspaceRoot = "/w/demo-project"
  CommitA = "1111111111111111111111111111111111111111"
  CommitB = "2222222222222222222222222222222222222222"
  Platform = "linux/amd64"
  CtDir = ".ct/certificates"
  ReproDir = ".repro/workspace/certificates"
  UnknownFramework = "some-other-framework"
    ## Deliberately not a real framework identifier. Two frameworks MUST NOT
    ## claim the same identifier (Standard.md §4), and a name nothing in this
    ## repository implements is what makes the "unrecognised" cases mean what
    ## they say.

proc newWorld(): FakeWorld =
  FakeWorld(
    files: initTable[string, FakeFile](),
    vcs: WorkspaceVcsState(
      known: true, repo: RepoName, commit: CommitA, clean: true,
      treeKnown: false, tree: ""),
    platform: Platform)

proc dirOf(path: string): string =
  let slash = path.rfind('/')
  if slash < 0: "" else: path[0 ..< slash]

proc nameOf(path: string): string =
  let slash = path.rfind('/')
  if slash < 0: path else: path[slash + 1 .. ^1]

proc access(world: FakeWorld): CertificateStoreAccess =
  CertificateStoreAccess(
    listFiles: proc(dir: string): StoreListing {.closure.} =
      var names: seq[string] = @[]
      for path in world.files.keys:
        if dirOf(path) == dir:
          names.add nameOf(path)
      if names.len == 0:
        return StoreListing(status: srAbsent)
      StoreListing(status: srOk, names: names)
    ,
    readText: proc(path: string): StoreRead {.closure.} =
      if not world.files.hasKey(path):
        return StoreRead(status: srAbsent)
      StoreRead(status: srOk, text: world.files[path].text)
    ,
    modifiedMs: proc(path: string): int64 {.closure.} =
      if world.files.hasKey(path): world.files[path].modifiedMs else: 0'i64
    )

proc facts(world: FakeWorld): CertificateIndicatorFacts =
  CertificateIndicatorFacts(
    store: readCertificateStore(world.access, WorkspaceRoot),
    vcs: world.vcs,
    platform: world.platform,
    signatureVerifier: nil)

proc evaluate(world: FakeWorld): CertificateIndicatorModel =
  evaluateCertificateIndicator(world.facts)

# ---------------------------------------------------------------------------
# Real certificate documents, produced by the shipped serializer
# ---------------------------------------------------------------------------

proc certificate(framework = "ct-test"; issuer = "ct-test";
                 commit = CommitA; targets = @["tests/calc_test.nim"];
                 commands = @[@["ct", "test", "run"]]): TestCertificate =
  TestCertificate(
    schema: CertificateSchema,
    framework: framework,
    project: RepoName,
    platform: Platform,
    targets: targets,
    result: "passed",
    issuedAt: "2026-08-18T09:00:00Z",
    issuer: issuer,
    vcs: VcsState(
      repo: RepoName, commit: commit, paths: @[], clean: true,
      untracked: false, worktree: none(WorktreeClaim)),
    commands: commands)

proc put(world: FakeWorld; dir, name: string; cert: TestCertificate;
         modifiedMs: int64) =
  world.files[WorkspaceRoot & "/" & dir & "/" & name] =
    FakeFile(text: renderCertificate(cert), modifiedMs: modifiedMs)

proc rowValue(model: CertificateIndicatorModel; label: string): string =
  for row in model.detail:
    if row.label == label:
      return row.value
  ""

# ---------------------------------------------------------------------------
# Rendering, through the real status shell
# ---------------------------------------------------------------------------

proc serialize(node: MockNode): string =
  ## The DOM as bytes, so two renderings can be diffed rather than inspected
  ## field by field. Attributes are emitted in sorted order, because a table's
  ## iteration order is not part of what a user sees and would make the
  ## comparison flaky rather than strict.
  if node == nil:
    return "<nil>"
  if node.kind == mnkText:
    return "#text(" & node.text & ")"
  var attrNames: seq[string] = @[]
  for key in node.attributes.keys:
    attrNames.add key
  attrNames.sort()
  result = "<" & node.tag
  for key in attrNames:
    result.add " " & key & "=\"" & node.attributes[key] & "\""
  result.add ">"
  for child in node.children:
    result.add serialize(child)
  result.add "</" & node.tag & ">"

proc baseShell(certificate: StatusCertificateModel): StatusShellModel =
  StatusShellModel(
    base: StatusBaseModel(
      language: "Nim",
      encoding: "UTF-8",
      processClass: "ready-status",
      processText: "stable: ready",
      showFinished: false,
      locationText: "/w/main.nim:12#44",
      locationTitle: "/w/main.nim:12#44",
      certificate: certificate))

proc rendered(model: CertificateIndicatorModel; disclosed: bool): string =
  ## What a user would see, produced through the SHIPPED chain: the ViewModel's
  ## model → `statusCertificateModel` → `renderStatusShell`.
  let vm = newCertificateIndicatorVm(nil)
  vm.model = model
  vm.disclosed = disclosed
  let r = MockRenderer()
  serialize(renderStatusShell(r, baseShell(statusCertificateModel(vm))))

# ---------------------------------------------------------------------------

suite "CTC-2: a workspace with more than one framework":

  test "each certificate is evaluated against its own claim, not its neighbour's":
    ## Verification.md §2. The store holds a reprobuild record and a `ct test`
    ## one, with **different frameworks and different target vocabularies** —
    ## "t-unit" means nothing to `ct test` and "tests/calc_test.nim" means
    ## nothing to reprobuild, which is exactly why §5 forbids one contributing
    ## to the other's union.
    ##
    ## The newest record is the `ct test` one and it is STALE. If either
    ## framework's claim were applied to the other's record — or if only the
    ## newest record were consulted at all — this workspace would read "was
    ## certified" while a certificate covering it sat in the same store.
    let world = newWorld()
    world.put(ReproDir, "build.toml", certificate(
      framework = "reprobuild", issuer = "repro-daemon@build-host-7",
      targets = @["t-unit", "t-integration"], commit = CommitA,
      commands = @[@["repro", "test"]]), 1000)
    world.put(CtDir, "linux-amd64.toml", certificate(commit = CommitB), 2000)
    world.vcs.commit = CommitA

    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary & " (" &
               model.certificateName & ")"
    ck model.state == cisCertified
    # The record that speaks is the one that BINDS, not the one that landed
    # last, and the disclosure names its framework rather than the newest
    # record's.
    ck model.certificateName == ReproDir & "/build.toml"
    ck rowValue(model, "Framework") == "reprobuild"
    ck rowValue(model, "Targets") == "t-integration, t-unit"

    # THE CONTROL, without which the case above would pass for a build that
    # always answers "certified": move to the commit the `ct test` record
    # covers and the OTHER record speaks, with its own framework and its own
    # targets.
    world.vcs.commit = CommitB
    let flipped = world.evaluate()
    checkpoint $flipped.state & " — " & flipped.certificateName
    ck flipped.state == cisCertified
    ck flipped.certificateName == CtDir & "/linux-amd64.toml"
    ck rowValue(flipped, "Framework") == "ct-test"
    ck rowValue(flipped, "Targets") == "tests/calc_test.nim"

    # AND THE NEGATIVE CONTROL: on a commit neither record covers, neither is
    # borrowed to cover the other. "Certified" must be earned by a record that
    # actually binds.
    world.vcs.commit = "3" & CommitA[1 .. ^1]
    let uncovered = world.evaluate()
    checkpoint $uncovered.state & " — " & uncovered.summary
    ck uncovered.state != cisCertified
    ck uncovered.state == cisWasCertified

  test "an unrecognised framework's certificate is ignored, not rejected":
    ## Verification.md §2 at the layer the framework filter lives in, and the
    ## same three-way discrimination the standard's `verify/other-framework`
    ## vector exists to pin: counting it is wrong, rejecting it (or failing on
    ## it) is wrong, ignoring it is right.
    let foreign = CandidateCertificate(
      name: "b-other-framework.toml",
      text: renderCertificate(certificate(
        framework = UnknownFramework, issuer = "other-runner",
        targets = @["tests/calc_test.nim"])))
    let state = EvaluatedState(repo: RepoName, commit: CommitA, tree: "")
    let requirement = Requirement(
      frameworksImplemented: @["ct-test"],
      framework: "ct-test",
      targets: @["tests/calc_test.nim"],
      platforms: @[Platform],
      requireSignature: false)

    let alone = verifyCertificates(state, requirement, [foreign], KeyStore())
    checkpoint $alone.outcome & " — " & alone.reason
    # NOT counted: it covers the required target on the required platform and
    # is worth nothing, because two frameworks may use one target name for two
    # different things (§5).
    ck alone.outcome == ocNotCovered
    # NOT rejected, and NOT unevaluable: a record for another framework is not
    # evidence against anything, and it cannot make this consumer unable to
    # answer (§7 — unverifiable is reserved for evaluation breaking down).
    ck alone.outcome != ocUnverifiable
    ck alone.rejected.len == 0
    ck alone.unevaluated.len == 0
    # Named in the report, so a reader can see what was skipped and why.
    ck alone.ignored.len == 1
    ck alone.ignored[0].certificate == "b-other-framework.toml"
    ck UnknownFramework in alone.ignored[0].why
    ck alone.missing.len == 1
    ck alone.missing[0].targets == @["tests/calc_test.nim"]

    # And it does not subtract: with a record this consumer DOES implement
    # covering the requirement, the outcome is covered and the ignored record
    # is still named (§7.1 rule 1 — "The unevaluated records MUST still be
    # named in the report").
    let mine = CandidateCertificate(
      name: "a-ct-test.toml", text: renderCertificate(certificate()))
    let together = verifyCertificates(state, requirement, [foreign, mine],
                                      KeyStore())
    checkpoint $together.outcome & " — " & together.reason
    ck together.outcome == ocCovered
    ck together.ignored.len == 1
    ck together.rejected.len == 0

  test "a neighbour from an unrecognised framework does not break the workspace":
    ## The same rule where getting it wrong is expensive. The neighbour is the
    ## NEWEST record in the store and it does not bind — so a consumer that let
    ## the newest record veto the rest, or that treated an unrecognised
    ## framework as a fault, would report a broken workspace to a user whose
    ## state is covered by the record sitting beside it.
    let world = newWorld()
    world.put(CtDir, "linux-amd64.toml", certificate(commit = CommitA), 2000)
    world.put(ReproDir, "neighbour.toml", certificate(
      framework = UnknownFramework, issuer = "other-runner",
      commit = CommitB), 3000)

    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    ck model.state == cisCertified
    ck model.state != cisNotCertified
    ck model.state != cisUnverifiable
    ck model.certificateName == CtDir & "/linux-amd64.toml"

    # A store holding ONLY the unrecognised record is not an error either. It
    # reads through the generic check like every other record — see this
    # file's header for why the indicator implements no framework filter — and
    # the disclosure names the framework, so the display never implies the
    # record is something it is not.
    let alone = newWorld()
    alone.put(CtDir, "neighbour.toml", certificate(
      framework = UnknownFramework, issuer = "other-runner"), 1000)
    let solo = alone.evaluate()
    checkpoint $solo.state & " — " & solo.summary
    ck solo.state != cisUnverifiable
    ck solo.state == cisCertified
    ck rowValue(solo, "Framework") == UnknownFramework

  test "a ct-test certificate and a reprobuild certificate render identically":
    ## CTC-2's second deliverable, and it is a *rendering* claim, so it is
    ## checked by rendering: both models go through the shipped projection and
    ## the shipped status shell, and the DOM is compared as bytes.
    ##
    ## The two records carry the SAME claim — same repository, commit,
    ## platform, targets and result — and differ in exactly the three fields a
    ## producer owns: `framework`, `issuer` and the attested `commands`. That is
    ## the comparison the deliverable asks for; two records making different
    ## claims would differ for a reason that has nothing to do with who wrote
    ## them.
    let ctWorld = newWorld()
    ctWorld.put(CtDir, "run.toml", certificate(
      framework = "ct-test", issuer = "ct-test@dev-box",
      commands = @[@["ct", "test", "run", "--workspace", "."]]), 1000)

    let reproWorld = newWorld()
    reproWorld.put(ReproDir, "run.toml", certificate(
      framework = "reprobuild", issuer = "repro-daemon@build-host-7",
      commands = @[@["repro", "test"]]), 1000)

    let ct = ctWorld.evaluate()
    let repro = reproWorld.evaluate()
    checkpoint "ct-test = " & $ct.state & "; reprobuild = " & $repro.state
    ck ct.state == cisCertified
    ck repro.state == cisCertified

    # The two documents are genuinely different bytes, or this case would be
    # comparing a rendering with itself.
    ck ctWorld.files[WorkspaceRoot & "/" & CtDir & "/run.toml"].text !=
       reproWorld.files[WorkspaceRoot & "/" & ReproDir & "/run.toml"].text

    # THE INDICATOR AS THE USER MEETS IT: closed, the whole rendered element —
    # label, state class, tooltip, role, every attribute and every text node —
    # must be byte-identical. The tooltip is included on purpose: it is the
    # shortest path from "Certified" to a conclusion, and a tooltip that named
    # the producer would be a difference in appearance.
    let ctClosed = rendered(ct, disclosed = false)
    let reproClosed = rendered(repro, disclosed = false)
    checkpoint "ct-test closed:    " & ctClosed
    checkpoint "reprobuild closed: " & reproClosed
    ck ctClosed == reproClosed

    # And the parts that are not the DOM, named individually so a failure says
    # which one moved rather than pointing at a diff of the whole bar.
    ck ct.label == repro.label
    ck ct.summary == repro.summary
    ck ct.remedy == repro.remedy
    ck ct.authenticity == repro.authenticity
    ck ct.authenticityNote == repro.authenticityNote
    ck stateClass(ct.state) == stateClass(repro.state)
    ck certificateTooltip(ct) == certificateTooltip(repro)

    # OPENED, the disclosure differs in exactly the rows that name the facts
    # that differ — and in nothing else. The disclosure shows the framework BY
    # DESIGN (SB-1's "Selecting the indicator discloses detail (framework,
    # targets, platform, time, scope)"), so this is the legitimate difference
    # rather than a defect.
    const DisclosedDifferences = ["Framework", "Issuer", "Record"]
    ck ct.detail.len == repro.detail.len
    for i in 0 ..< min(ct.detail.len, repro.detail.len):
      ck ct.detail[i].label == repro.detail[i].label
      if ct.detail[i].label in DisclosedDifferences:
        checkpoint "differs by design: " & ct.detail[i].label & " = " &
                   ct.detail[i].value & " vs " & repro.detail[i].value
        ck ct.detail[i].value != repro.detail[i].value
      else:
        checkpoint "must match: " & ct.detail[i].label
        ck ct.detail[i].value == repro.detail[i].value

    # `commands` is the third field that differs, and it must reach no surface
    # at all — neither the closed indicator (asserted byte-identical above) nor
    # the disclosure.
    let ctOpen = rendered(ct, disclosed = true)
    let reproOpen = rendered(repro, disclosed = true)
    ck "repro" notin ctOpen
    ck "--workspace" notin reproOpen

  test "a record that could not be evaluated is not masked by a decided one":
    ## Verification.md §7.1 rule 2, applied to a store rather than to a single
    ## record: when nothing binds, an unread record that MIGHT have covered the
    ## state makes the outcome unverifiable — "run the tests" is the wrong
    ## instruction while an unread certificate might already cover the gap.
    ##
    ## The newest record here is decidably stale, which is the reassuring
    ## reading; the older one is in a schema version this build does not
    ## implement, whose relevance is undecidable and MUST be assumed (§7.1).
    let world = newWorld()
    world.files[WorkspaceRoot & "/" & ReproDir & "/future.toml"] = FakeFile(
      text: "schema = \"test-certificate.v2\"\n\n[certificate]\n" &
            "framework = \"reprobuild\"\n",
      modifiedMs: 1000)
    world.put(CtDir, "linux-amd64.toml", certificate(commit = CommitB), 2000)

    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    ck model.state == cisUnverifiable
    ck model.state != cisWasCertified
    ck model.remedy == FixConfigurationRemedy

    # THE CONTROL: once a record binds, the unread one can no longer change the
    # answer — coverage in v1 only ever grows, so a record nobody could read
    # could only have ADDED coverage that is already there (§7.1 rule 1).
    world.vcs.commit = CommitB
    let covered = world.evaluate()
    checkpoint $covered.state & " — " & covered.summary
    ck covered.state == cisCertified

echo "CHECKS: ", checksRun
