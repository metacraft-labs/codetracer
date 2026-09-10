## SB-1 — the status bar's test-certificate indicator, headless.
##
## Drives ``viewmodels/certificate_indicator_vm`` over a workspace whose
## certificate store, repository state and platform the test controls, and
## asserts the four states SB-1 requires plus the two distinctions that carry
## the milestone: **unverifiable must never collapse into "not certified"**,
## and **a missing store is "no certificates", never an error**.
##
## ## The one fake, and why it is the honest boundary here
##
## ``CertificateStoreAccess`` is filled in with an in-memory tree
## (``fakeStore`` below). Everything else is real: real certificate documents,
## produced by ``certificate.renderCertificate`` — the shipped canonical
## serializer — and read back by ``certificate.readCertificate``, the shipped
## strict reader; real ``registered-keys.toml`` text through the shipped
## ``readKeyStore``; and the real ``certificate_verification.verifyCertificates``
## deciding every verdict. Nothing about the *subject* is stubbed.
##
## The filesystem is faked for one reason, and it is a hard one: **this suite
## runs on both Nim backends** (`vm-native` and `vm-js`), and ``std/os`` does
## not exist under ``nim js``. A real-filesystem version could only ever run on
## one of the two, and the ViewModel must be proven on the backend the Electron
## renderer actually is. The real-filesystem half is not skipped, it is
## *elsewhere*: ``src/ct_test/certificate_store_test.nim`` drives the same
## ``readCertificateStore`` against real directories, real files, a real
## unreadable file and a real missing store, in the ``ct-test-certificates``
## lane.
##
## ## No agent session, anywhere
##
## Nothing in this file constructs an agent session, an agent service, a
## DeepReview session or a layout, and that is one of SB-1's verification
## items rather than an accident of how the suite is written: a certificate
## attests to a repository state and must be visible when no session exists.
## The suite is the behavioural half of that claim; the structural half — that
## the ViewModel's imports reach nothing session-shaped — is asserted in
## ``src/ct_test/certificate_store_test.nim``, which can read the source tree.

import std/[options, strutils, tables, unittest]

import viewmodels/certificate_indicator_vm

import ../../../../ct_test/certificate

# ---------------------------------------------------------------------------
# A workspace the test can move around under the indicator
# ---------------------------------------------------------------------------

type
  FakeFile = object
    text: string
    modifiedMs: int64
    readable: bool
      ## ``false`` models a file that exists and cannot be read — a mode bit, a
      ## filesystem error. The distinction from "absent" is the whole of
      ## Verification.md §3.1 for a key store and of Transport.md §4 for a
      ## certificate, so the fake has to be able to express it.

  FakeWorld = ref object
    ## The world the indicator reads. Mutable, because the refresh requirement
    ## is precisely that moving the world under a live ViewModel moves what it
    ## says.
    files: Table[string, FakeFile]
    unlistableDirs: seq[string]
    vcs: WorkspaceVcsState
    platform: string
    verifier: CertificateSignatureVerifier

const
  RepoName = "demo-project"
  WorkspaceRoot = "/w/demo-project"
  CommitA = "1111111111111111111111111111111111111111"
  CommitB = "2222222222222222222222222222222222222222"
  Platform = "linux/amd64"
  StoreDir = ".ct/certificates"

proc newWorld(): FakeWorld =
  FakeWorld(
    files: initTable[string, FakeFile](),
    unlistableDirs: @[],
    vcs: WorkspaceVcsState(
      known: true, repo: RepoName, commit: CommitA, clean: true,
      treeKnown: false, tree: ""),
    platform: Platform,
    verifier: nil)

proc put(world: FakeWorld; path, text: string; modifiedMs: int64;
         readable = true) =
  world.files[path] = FakeFile(
    text: text, modifiedMs: modifiedMs, readable: readable)

proc dirOf(path: string): string =
  let slash = path.rfind('/')
  if slash < 0: "" else: path[0 ..< slash]

proc nameOf(path: string): string =
  let slash = path.rfind('/')
  if slash < 0: path else: path[slash + 1 .. ^1]

proc access(world: FakeWorld): CertificateStoreAccess =
  CertificateStoreAccess(
    listFiles: proc(dir: string): StoreListing {.closure.} =
      for unlistable in world.unlistableDirs:
        if unlistable == dir:
          return StoreListing(status: srUnreadable,
                              detail: "permission denied")
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
      let entry = world.files[path]
      if not entry.readable:
        return StoreRead(status: srUnreadable, detail: "permission denied")
      StoreRead(status: srOk, text: entry.text)
    ,
    modifiedMs: proc(path: string): int64 {.closure.} =
      if world.files.hasKey(path): world.files[path].modifiedMs else: 0'i64
    )

proc facts(world: FakeWorld): CertificateIndicatorFacts =
  CertificateIndicatorFacts(
    store: readCertificateStore(world.access, WorkspaceRoot),
    vcs: world.vcs,
    platform: world.platform,
    signatureVerifier: world.verifier)

proc reader(world: FakeWorld): CertificateFactsReader =
  proc(): CertificateIndicatorFacts {.closure.} = world.facts

proc evaluate(world: FakeWorld): CertificateIndicatorModel =
  evaluateCertificateIndicator(world.facts)

# ---------------------------------------------------------------------------
# Real certificate documents, produced by the shipped serializer
# ---------------------------------------------------------------------------

proc sampleCertificate(commit = CommitA; platform = Platform;
                       repo = RepoName; framework = "ct-test";
                       issuer = "ct-test"; clean = true;
                       targets = @["tests/calc_test.nim"];
                       resultValue = "passed";
                       keyId = ""; signature = ""): TestCertificate =
  result = TestCertificate(
    schema: CertificateSchema,
    framework: framework,
    project: repo,
    platform: platform,
    targets: targets,
    result: resultValue,
    issuedAt: "2026-08-18T09:00:00Z",
    issuer: issuer,
    keyId: keyId,
    vcs: VcsState(
      repo: repo, commit: commit, paths: @[], clean: clean,
      untracked: false, worktree: none(WorktreeClaim)),
    commands: @[@["ct", "test", "run"]])
  if signature.len > 0:
    result.signature = CertificateSignature(
      algorithm: SignatureAlgorithm, value: signature)

proc document(cert: TestCertificate): string = renderCertificate(cert)

proc storePath(name: string): string = WorkspaceRoot & "/" & StoreDir & "/" & name

proc withCertificate(world: FakeWorld; cert: TestCertificate;
                     name = "run.toml"; modifiedMs: int64 = 1000): FakeWorld =
  world.put(storePath(name), document(cert), modifiedMs)
  world

# Signature verifiers, declared at module level rather than inline in the cases
# that install them. Not a style choice: a capture-free closure literal
# assigned inside a `unittest` `test` body is an `env is missing` codegen
# assertion in `nim js` (jsgen.nim:1239), so the JS lane would not compile at
# all. Top-level procs assigned to the closure-typed field are equivalent for
# what these cases assert — they stand in for a host that CAN answer, and for
# one that answers no.
proc alwaysValidSignature(payload, publicKey, signatureValue: string):
    tuple[check: SignatureCheck; detail: string] {.gcsafe.} =
  (scValid, "")

proc alwaysInvalidSignature(payload, publicKey, signatureValue: string):
    tuple[check: SignatureCheck; detail: string] {.gcsafe.} =
  (scInvalid, "signature did not verify")

# ---------------------------------------------------------------------------

suite "SB-1: the status bar's test-certificate indicator":

  test "a certificate matching the current commit and platform reads certified":
    ## Verification item 1. The positive control for every negative one below:
    ## if this did not read certified, none of the others would mean anything.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate())
    let model = world.evaluate()
    checkpoint "state = " & $model.state & "; summary = " & model.summary
    check model.state == cisCertified
    check model.label == CertifiedLabel
    check model.certificateName == StoreDir & "/run.toml"
    # THE HONESTY RULE, asserted rather than hoped for. "Valid" means binds to
    # the current state, not verified as unforgeable (Status-Bar.md Notes).
    check model.authenticity == caNotChecked
    check model.authenticityNote == NoKeysRegisteredNote
    check "not evidence that the run was not fabricated" in model.authenticityNote
    # A certified state has nothing to remedy; every other state does.
    check model.remedy == ""

  test "the disclosure names the framework, targets, platform, time and scope":
    ## The interaction deliverable: selecting the indicator reveals detail
    ## (Status-Bar.md, "Interaction"). Asserted on the MODEL, because the
    ## requirement that it not open a panel or disturb the layout is met by
    ## there being no layout involved at all — `disclosed` is a field on this
    ## ViewModel and nothing else moves.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(
      targets = @["tests/b_test.nim", "tests/a_test.nim"]))
    let model = world.evaluate()
    var rows = initTable[string, string]()
    for row in model.detail:
      rows[row.label] = row.value
    check rows.getOrDefault("Framework") == "ct-test"
    check rows.getOrDefault("Platform") == Platform
    # Sorted and deduplicated exactly as the canonical payload orders them, so
    # the disclosure and the signed bytes cannot disagree.
    check rows.getOrDefault("Targets") == "tests/a_test.nim, tests/b_test.nim"
    check rows.getOrDefault("Issued") == "2026-08-18T09:00:00Z"
    check rows.getOrDefault("Commit") == CommitA
    check rows.getOrDefault("Scope") == "whole repository"

    let vm = newCertificateIndicatorVm(world.reader)
    check not vm.disclosed
    vm.toggleDisclosure()
    check vm.disclosed
    # Opening refreshes, because the detail is a claim about the current state
    # and the moment the user asks is the worst moment to be stale.
    check vm.refreshes == 1
    vm.toggleDisclosure()
    check not vm.disclosed

  test "a scoped certificate says so instead of reading as whole-repository":
    ## Verification.md §4.1.2: a scoped certificate is not a whole-repository
    ## certificate, and treating it as one is the mistake `vcs.paths` exists to
    ## prevent. The indicator must not let a reader draw that conclusion.
    let world = newWorld()
    var cert = sampleCertificate()
    cert.vcs.paths = @["src/lib"]
    discard world.withCertificate(cert)
    let model = world.evaluate()
    var scope = ""
    for row in model.detail:
      if row.label == "Scope": scope = row.value
    check scope == "src/lib"
    check scope != "whole repository"

  test "a certificate for another commit does not read certified":
    ## Verification item 2. `vcs.commit` must match the commit under
    ## evaluation exactly (Verification.md §4.1).
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(commit = CommitB))
    let model = world.evaluate()
    checkpoint "state = " & $model.state & "; summary = " & model.summary
    check model.state != cisCertified
    check model.label != CertifiedLabel

  test "a certificate for another platform does not read certified":
    ## A green Linux run says nothing about macOS (Verification.md §5), and
    ## the remedy differs from staleness: nothing about this machine has ever
    ## been certified, so it is "not certified" rather than "was certified".
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(platform = "macos/arm64"))
    let model = world.evaluate()
    check model.state == cisNotCertified
    check "macos/arm64" in model.summary

  test "a stale certificate renders \"was certified, no longer valid\"":
    ## Verification item 3, and the state that carries the milestone: it tells
    ## the user their last green run no longer covers what they have.
    ##
    ## Two ways a tree moves on, and both must land here rather than in
    ## "not certified" — the record IS about this repository and this platform,
    ## which is exactly what makes the sentence true.
    block movedToANewCommit:
      let world = newWorld()
      discard world.withCertificate(sampleCertificate(commit = CommitA))
      world.vcs.commit = CommitB
      let model = world.evaluate()
      checkpoint "after a commit: " & $model.state & " — " & model.summary
      check model.state == cisWasCertified
      check model.label == WasCertifiedLabel
      check model.remedy == RunTheTestsRemedy

    block editedTheWorktree:
      # A `clean = true` certificate's tested state IS its commit
      # (Verification.md §4.1). An edited tree is that commit PLUS the edit,
      # which no committed-tree certificate describes — so the certificate
      # stops binding the moment a tracked file changes, without HEAD moving.
      let world = newWorld()
      discard world.withCertificate(sampleCertificate(commit = CommitA))
      check world.evaluate().state == cisCertified
      world.vcs.clean = false
      let model = world.evaluate()
      checkpoint "after an edit: " & $model.state & " — " & model.summary
      check model.state == cisWasCertified
      check model.label == WasCertifiedLabel

  test "an unreadable key store renders unverifiable, not \"not certified\"":
    ## Verification item 4, and the distinction the whole standard's
    ## three-valued outcome exists for (Verification.md §3.1, §7).
    ##
    ## An empty or missing store *answers* — nobody is trusted, and the records
    ## it denies are not covered. A store that cannot be read answers nothing.
    ## Collapsing the two sends an operator to re-run tests when the actual
    ## fault is a corrupt configuration file, and the remedies below are what
    ## that costs.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(
      keyId = "repro-sign-2026-q2", signature = "AAAAsignature"))
    world.put(storePath("registered-keys.toml"), "", 900, readable = false)

    let model = world.evaluate()
    checkpoint "state = " & $model.state & "; summary = " & model.summary
    check model.state == cisUnverifiable
    check model.state != cisNotCertified
    check model.label == UnverifiableLabel
    # The practical payload of keeping them apart: the two states send the
    # operator to different places, and this is the sentence that does it.
    check model.remedy == FixConfigurationRemedy
    check model.remedy != RunTheTestsRemedy

    # AND THE CONTROL, without which the case above proves nothing: the SAME
    # certificate against an EMPTY-but-readable store is not-covered, because
    # an empty store answers the question. If both rendered unverifiable this
    # test would pass while the distinction was gone.
    world.put(storePath("registered-keys.toml"),
              "schema = \"registered-keys.v1\"\n", 900)
    let denied = world.evaluate()
    checkpoint "empty store: " & $denied.state & " — " & denied.summary
    check denied.state == cisNotCertified
    check denied.state != cisUnverifiable
    check denied.authenticity == caRejected

  test "a revoked key is rejected, not reported as unverifiable":
    ## Verification.md §7: "Nor is a record that is decidably invalid. … a
    ## revoked key … in each of those the consumer asked the question and got
    ## an answer." Revocation beats cryptography and is still a decision.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(
      keyId = "old-key", signature = "AAAAsignature"))
    world.put(storePath("registered-keys.toml"), """
schema = "registered-keys.v1"

[[key]]
key_id = "old-key"
public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
status = "revoked"
""", 900)
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisNotCertified
    check model.state != cisUnverifiable
    check "revoked" in model.summary

  test "a signed certificate this build cannot check reads unverifiable":
    ## A consumer with no signature verifier has not decided anything about
    ## the signature, so it MUST NOT report one. This is the browser tab and
    ## the renderer: no `ssh-keygen`, so `scUndecidable` — never `scInvalid`.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(
      keyId = "known-key", signature = "AAAAsignature"))
    world.put(storePath("registered-keys.toml"), """
schema = "registered-keys.v1"

[[key]]
key_id = "known-key"
public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
status = "active"
""", 900)
    check world.verifier.isNil
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check model.remedy == FixConfigurationRemedy

    # The control: hand it a verifier that DOES answer, and the same inputs
    # decide. Without this the case above could pass for a build that reports
    # unverifiable no matter what.
    world.verifier = alwaysValidSignature
    let verified = world.evaluate()
    check verified.state == cisCertified
    check verified.authenticity == caVerified
    check verified.authenticityNote == KeyVerifiedNote
    # Even here the display must not claim unforgeability.
    check "deployment property" in verified.authenticityNote

    world.verifier = alwaysInvalidSignature
    let rejected = world.evaluate()
    check rejected.state == cisNotCertified
    check rejected.authenticity == caRejected

  test "a missing store renders \"no certificates\", not an error":
    ## Verification item 5. Transport.md §4: an absent certificate store is a
    ## normal state for a project that does not use certificates and MUST NOT
    ## be an error in itself.
    let world = newWorld()
    check world.files.len == 0
    var raised = ""
    var model: CertificateIndicatorModel
    try:
      model = world.evaluate()
    except CatchableError as err:
      raised = err.msg
    checkpoint "raised = '" & raised & "'; state = " & $model.state
    check raised == ""
    check model.state == cisNoCertificates
    check model.label == NoCertificatesLabel
    check model.state != cisUnverifiable
    # Discovery MUST be explicit about what it searched (Transport.md §4) —
    # "no certificates found" usually means a fetch or a push was missed, and
    # a report that does not say where it looked cannot be acted on.
    check model.searched.len == 2
    check ".ct/certificates" in model.searched
    check ".repro/workspace/certificates" in model.searched

  test "a store that exists and cannot be listed is unverifiable, not empty":
    ## The other half of the case above, and the reason it is not enough on its
    ## own: "there is nothing here" and "I could not look" are different
    ## answers, and rendering the second as the first would tell a user their
    ## project has no certificates while the store sits on disk in front of
    ## them.
    let world = newWorld()
    world.unlistableDirs.add WorkspaceRoot & "/" & StoreDir
    world.put(storePath("run.toml"), document(sampleCertificate()), 1000)
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check model.state != cisNoCertificates

  test "the indicator refreshes when the commit changes":
    ## Verification item 6. The deliverable is that the indicator "cannot go on
    ## claiming validity it has lost", so the assertion is that the model MOVED
    ## — not merely that a refresh was requested.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(commit = CommitA))
    let vm = newCertificateIndicatorVm(world.reader)

    check vm.refresh(citStartup)
    check vm.model.state == cisCertified
    let atStartup = vm.revision

    # A commit, a checkout, a rebase — HEAD moved.
    world.vcs.commit = CommitB
    check vm.refresh(citCommitChanged)
    check vm.model.state == cisWasCertified
    check vm.revision == atStartup + 1
    check vm.lastTrigger == citCommitChanged

    # An edit: the tree moved without HEAD moving.
    world.vcs.commit = CommitA
    discard vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified
    world.vcs.clean = false
    check vm.refresh(citWorktreeChanged)
    check vm.model.state == cisWasCertified
    check vm.lastTrigger == citWorktreeChanged

    # A certificate arriving in the store.
    world.vcs.clean = true
    discard vm.refresh(citWorktreeChanged)
    world.vcs.commit = CommitB
    discard vm.refresh(citCommitChanged)
    check vm.model.state == cisWasCertified
    world.put(storePath("later.toml"),
              document(sampleCertificate(commit = CommitB)), 2000)
    check vm.refresh(citStoreChanged)
    check vm.model.state == cisCertified
    check vm.lastTrigger == citStoreChanged

    # A refresh that changes nothing does not move the revision — the pair of
    # counters separates "the trigger fired" from "the answer moved".
    let settled = vm.revision
    let refreshes = vm.refreshes
    check not vm.refresh(citManualRefresh)
    check vm.revision == settled
    check vm.refreshes == refreshes + 1

  test "the newest certificate is the one that speaks, whichever store holds it":
    ## "The last produced certificate, whatever produced it." Ordering is by
    ## when the record landed, not by `issued_at` — which is informational and
    ## explicitly not a trust input (Verification.md §4.3), so a producer with
    ## a skewed clock cannot pin itself at the top of the list.
    let world = newWorld()
    world.put(WorkspaceRoot & "/.repro/workspace/certificates/old.toml",
              document(sampleCertificate(commit = CommitA)), 1000)
    world.put(storePath("new.toml"),
              document(sampleCertificate(commit = CommitB)), 2000)
    world.vcs.commit = CommitB
    let model = world.evaluate()
    check model.state == cisCertified
    check model.certificateName == StoreDir & "/new.toml"

    # And the other way round, so the case cannot pass by accident of which
    # directory is searched first.
    world.put(WorkspaceRoot & "/.repro/workspace/certificates/old.toml",
              document(sampleCertificate(commit = CommitA)), 3000)
    world.vcs.commit = CommitA
    let flipped = world.evaluate()
    check flipped.state == cisCertified
    check flipped.certificateName ==
      ".repro/workspace/certificates/old.toml"

  test "a hook-written certificate renders identically to an agent-written one":
    ## Verification item 7. The indicator is producer-agnostic; a difference in
    ## appearance would be a defect (Status-Bar.md).
    ##
    ## Two things differ between the two files and neither may reach the
    ## display: the CARRIER (a hook writes into reprobuild's store, an agent
    ## into `ct test`'s) and the BYTES (a hook may write a perfectly valid
    ## non-canonical rendering — different key order, comments, CRLF, a
    ## trailing comma — which must parse to the same record).
    let agentCert = sampleCertificate()
    let agentWorld = newWorld()
    agentWorld.put(storePath("agent.toml"), document(agentCert), 1000)

    # The same claim, written by hand the way a shell hook would: keys out of
    # canonical order, a comment, CRLF line endings, extra whitespace, and the
    # array spread over lines with a trailing comma. `readCertificate`
    # reconstructs the payload from the FIELDS, never by slicing the received
    # bytes (Canonical-Payload.md §5), which is what makes this legitimate.
    let hookText = ("# written by the end-of-turn hook\r\n" &
      "schema = \"test-certificate.v1\"\r\n" &
      "\r\n" &
      "[certificate.vcs]\r\n" &
      "untracked   = false\r\n" &
      "clean = true\r\n" &
      "commit = \"" & CommitA & "\"\r\n" &
      "repo = \"" & RepoName & "\"\r\n" &
      "\r\n" &
      "[certificate]\r\n" &
      "result   = \"passed\"\r\n" &
      "targets = [\r\n  \"tests/calc_test.nim\",\r\n]\r\n" &
      "platform = \"" & Platform & "\"\r\n" &
      "project = \"" & RepoName & "\"\r\n" &
      "framework = \"ct-test\"\r\n" &
      "issued_at = \"2026-08-18T09:00:00Z\"\r\n" &
      "issuer = \"ct-test\"\r\n" &
      "\r\n" &
      "[[certificate.command]]\r\n" &
      "argv = [\"ct\", \"test\", \"run\"]\r\n")
    let hookWorld = newWorld()
    hookWorld.put(
      WorkspaceRoot & "/.repro/workspace/certificates/hook.toml",
      hookText, 1000)

    let agent = agentWorld.evaluate()
    let hook = hookWorld.evaluate()
    checkpoint "agent = " & $agent.state & "; hook = " & $hook.state
    # The two files are genuinely different bytes — otherwise this case would
    # be comparing a document with itself.
    check hookText != document(agentCert)
    check agent.state == cisCertified
    check hook.state == agent.state
    check hook.label == agent.label
    check hook.summary == agent.summary
    check hook.remedy == agent.remedy
    check hook.authenticity == agent.authenticity
    check hook.authenticityNote == agent.authenticityNote
    # Every disclosed fact matches except the one that IS the difference —
    # which record it is. Compared as a whole rather than field by field, so a
    # row added later is covered without editing this case.
    check hook.detail.len == agent.detail.len
    for i in 0 ..< min(hook.detail.len, agent.detail.len):
      if agent.detail[i].label == "Record":
        check hook.detail[i].label == "Record"
        check hook.detail[i].value != agent.detail[i].value
      else:
        checkpoint "row " & $i & ": " & agent.detail[i].label
        check hook.detail[i] == agent.detail[i]

  test "the indicator renders with no agent session present":
    ## Verification item 8. A certificate attests to a repository state and has
    ## no connection to any conversation; tying its display to a session would
    ## hide it exactly when no session is open (Status-Bar.md).
    ##
    ## This suite constructs no session of any kind — no `AgentSession`, no
    ## `DeepReviewVm`, no layout, no `Data`. Every state below is reached from
    ## a certificate store and a repository state alone, which is the whole
    ## claim. The structural half (that the ViewModel's import graph reaches
    ## nothing session-shaped) is asserted in
    ## `src/ct_test/certificate_store_test.nim`.
    var seen: seq[CertificateIndicatorState] = @[]

    let empty = newWorld()
    seen.add empty.evaluate().state

    let certified = newWorld()
    discard certified.withCertificate(sampleCertificate())
    seen.add certified.evaluate().state

    let stale = newWorld()
    discard stale.withCertificate(sampleCertificate(commit = CommitB))
    seen.add stale.evaluate().state

    let foreign = newWorld()
    discard foreign.withCertificate(sampleCertificate(platform = "macos/arm64"))
    seen.add foreign.evaluate().state

    let broken = newWorld()
    broken.put(storePath("registered-keys.toml"), "", 900, readable = false)
    discard broken.withCertificate(sampleCertificate(
      keyId = "k", signature = "AAAA"))
    seen.add broken.evaluate().state

    checkpoint "states reached without a session: " & $seen
    check cisNoCertificates in seen
    check cisCertified in seen
    check cisWasCertified in seen
    check cisNotCertified in seen
    check cisUnverifiable in seen
    # Every state renders something: a label, a summary and a class. An
    # indicator that goes blank in one of its states is an indicator a user
    # learns to ignore.
    for state in [cisNoCertificates, cisCertified, cisNotCertified,
                  cisWasCertified, cisUnverifiable]:
      check stateClass(state).len > 0
    check stateClass(cisUnverifiable) != stateClass(cisNotCertified)

  test "a commit this build could not establish is unverifiable":
    ## Where the client cannot tell, it must say so. A consumer that does not
    ## know which commit it is on cannot decide `vcs.commit` either way, and
    ## reporting "not certified" would send an operator to run tests over a
    ## VCS problem.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate())
    world.vcs = WorkspaceVcsState(known: false)
    let model = world.evaluate()
    check model.state == cisUnverifiable
    check model.remedy == FixConfigurationRemedy

  test "a platform this build could not establish is unverifiable":
    ## Same argument on the other required field. A green run on one platform
    ## says nothing about another (Verification.md §5), so a consumer that does
    ## not know its own platform is guessing.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate())
    world.platform = ""
    let model = world.evaluate()
    check model.state == cisUnverifiable

  test "a schema this build does not implement is unverifiable, not invalid":
    ## Verification.md §7.1: a record the consumer cannot interpret MUST be
    ## treated as potentially relevant whatever its fields appear to say.
    ## Reading `platform` out of a later-version record with a v1 parser means
    ## trusting an interpretation this build has just admitted it does not have.
    let world = newWorld()
    world.put(storePath("future.toml"), """
schema = "test-certificate.v2"

[certificate]
framework = "ct-test"
""", 1000)
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check "test-certificate.v2" in model.summary

  test "a malformed record is not evidence, and is not unverifiable either":
    ## The counterpart, and the reason the two must not be merged: a record
    ## missing a required v1 field is DECIDABLY invalid — the consumer asked
    ## the question and got an answer (Verification.md §7).
    let world = newWorld()
    world.put(storePath("broken.toml"), """
schema = "test-certificate.v1"

[certificate]
framework = "ct-test"
""", 1000)
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisNotCertified
    check model.state != cisUnverifiable
    check model.remedy == RunTheTestsRemedy

  test "a modified-worktree claim this build cannot match reads unverifiable":
    ## A `clean = false` certificate is matched by canonical CONTENT id
    ## (Verification.md §4.1.1), and CodeTracer cannot compute one for the
    ## current worktree. Reporting "was certified, no longer valid" would be a
    ## claim it has not earned every bit as much as "certified" would.
    let world = newWorld()
    var cert = sampleCertificate(clean = false)
    cert.vcs.worktree = some(WorktreeClaim(tree: "deadbeef"))
    discard world.withCertificate(cert)
    world.vcs.clean = false
    let model = world.evaluate()
    checkpoint "state = " & $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check model.state != cisWasCertified
    check model.state != cisCertified

  test "a certificate for another repository is not this workspace's business":
    ## The record parses, is authentic-shaped and reports a pass — and says
    ## nothing about the tree in front of the user. "Was certified" would be a
    ## false sentence about their history.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(repo = "other-project"))
    let model = world.evaluate()
    check model.state == cisNotCertified
    check model.state != cisWasCertified
    check "other-project" in model.summary

  test "the ViewModel starts honest and never serves a model it did not compute":
    ## A status bar renders before anything has looked at the filesystem. The
    ## initial model must therefore be an honest "no certificates" rather than
    ## whatever the enum's first value happens to be — and a ViewModel with no
    ## reader at all must not invent one.
    let bare = newCertificateIndicatorVm(nil)
    check bare.model.state == cisNoCertificates
    check bare.model.label == NoCertificatesLabel
    check not bare.refresh(citStartup)
    check bare.model.state == cisNoCertificates
    check bare.revision == 0
