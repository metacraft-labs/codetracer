## SB-1 and SB-2b — the status bar's test-certificate indicator, headless.
##
## Drives ``viewmodels/certificate_indicator_vm`` over a workspace whose
## certificate store, repository state and platform the test controls, and
## asserts SB-1's states and the two distinctions that carry them
## (**unverifiable must never collapse into "not certified"**, and **a
## missing store is "no certificates", never an error**), then SB-2b's
## decision table (Status-Bar.md): every row, decided on the content facts W
## (the working tree), H (HEAD's content) and S (the staged content).
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
## Where the records sit (2026-10-10, CTC-3e): most cases put them in
## reprobuild's workspace carrier (``StoreDir``), which the reader still pools
## and which lists every record whatever its content, so these cases keep
## exercising the ViewModel's decision over records for other content. `ct
## test` itself now publishes to the per-user local certificate store,
## looked up by content id; the cases that are about a record `ct test`
## wrote put it there (``localPath``), under its own content's directory, and
## the facts look W up in it the way the indicator source does. `ct test`'s
## old ``.ct/certificates`` is read by nothing.
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
import viewmodels/certificate_indicator_source
import platform/platform

import ../../../../ct_test/certificate
import ../../../../ct_test/certificate_content_id

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
    known: bool
      ## Whether the repository could be established at all.
    workingTree: string
      ## W: the whole-repository ``git-tree-sha1`` content id of the working
      ## tree's tracked files. An edit moves W alone; a commit of exactly W
      ## moves H to it; a checkout moves all three.
    head: string
      ## H: HEAD's content id. Empty: no commit yet.
    index: string
      ## S: the staged content's id.
    workingTreeProblem: string
      ## When non-empty, W has no content id at all (Content-Id.md §3), and
      ## this is the reason.
    platform: string
    verifier: CertificateSignatureVerifier

const
  RepoName = "demo-project"
  WorkspaceRoot = "/w/demo-project"
  CommitA = "1111111111111111111111111111111111111111"
  CommitB = "2222222222222222222222222222222222222222"
    ## Values for `base`, which is informational and never compared.
  TreeA = "git-tree-sha1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  TreeB = "git-tree-sha1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    ## Content ids — the binding.
  Platform = "linux/amd64"
  StoreDir = ".repro/workspace/certificates"
    ## reprobuild's workspace carrier. (`.ct/certificates` until CTC-3e.)
  UserRoot = "/home/u/.local/state/test-certificates"
    ## The local certificate store's user root, as a host would resolve it.

proc newWorld(): FakeWorld =
  FakeWorld(
    files: initTable[string, FakeFile](),
    unlistableDirs: @[],
    known: true,
    workingTree: TreeA,
    head: TreeA,
    index: TreeA,
    workingTreeProblem: "",
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
      var exists = false
      for path in world.files.keys:
        if dirOf(path) == dir:
          names.add nameOf(path)
        if path.startsWith(dir & "/"):
          # A directory exists when anything is below it, as on a real
          # filesystem: the local store's root holds directories, not files.
          exists = true
      if not exists:
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

proc answer(world: FakeWorld; id: string; problem: string; algorithm: string;
            paths: seq[string]): ContentAnswer =
  ## A state as a host computes it: the whole-repository ``git-tree-sha1``
  ## id, and nothing else — another algorithm is one this "host" cannot
  ## compute, and this fake computes no scoped id.
  if problem.len > 0:
    return ContentAnswer(computed: false, reason: problem)
  if id.len == 0:
    return ContentAnswer(computed: false, reason: "there is no commit yet")
  if algorithm != "git-tree-sha1":
    return ContentAnswer(computed: false,
      reason: "this host cannot compute " & algorithm)
  if paths.len > 0:
    return ContentAnswer(computed: false,
      reason: "this fake computes no scoped id")
  ContentAnswer(computed: true, id: id)

proc workspaceState(world: FakeWorld): WorkspaceVcsState =
  if not world.known:
    return WorkspaceVcsState(known: false)
  WorkspaceVcsState(known: true, repo: RepoName,
    workingTree: proc(algorithm: string; paths: seq[string]): ContentAnswer
        {.closure.} =
      world.answer(world.workingTree, world.workingTreeProblem, algorithm,
                   paths),
    head: proc(algorithm: string; paths: seq[string]): ContentAnswer
        {.closure.} = world.answer(world.head, "", algorithm, paths),
    index: proc(algorithm: string; paths: seq[string]): ContentAnswer
        {.closure.} = world.answer(world.index, "", algorithm, paths),
    workingTreeProblem: world.workingTreeProblem,
    workingTreeRemedy:
      if world.workingTreeProblem.len > 0: "Resolve the merge." else: "")

proc localQuery(world: FakeWorld): LocalStoreQuery =
  ## The local store looked up by W, H and S, as `localStoreQuery` does on a
  ## host.
  result.roots = CertificateStoreRoots(available: true, user: UserRoot)
  if not world.known:
    return
  for (id, problem) in [(world.workingTree, world.workingTreeProblem),
                        (world.head, ""), (world.index, "")]:
    if id.len > 0 and problem.len == 0 and id notin result.contentIds:
      result.contentIds.add id

proc facts(world: FakeWorld): CertificateIndicatorFacts =
  CertificateIndicatorFacts(
    store: readCertificateStore(world.access, WorkspaceRoot, world.localQuery),
    vcs: world.workspaceState,
    platform: world.platform,
    signatureVerifier: world.verifier)

proc reader(world: FakeWorld): CertificateFactsReader =
  proc(): CertificateIndicatorFacts {.closure.} = world.facts

proc evaluate(world: FakeWorld): CertificateIndicatorModel =
  evaluateCertificateIndicator(world.facts)

# ---------------------------------------------------------------------------
# Real certificate documents, produced by the shipped serializer
# ---------------------------------------------------------------------------

proc sampleCertificate(content = TreeA; base = CommitA; platform = Platform;
                       repo = RepoName; framework = "ct-test";
                       issuer = "ct-test";
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
      repo: repo, paths: @[], content: content, untracked: false,
      base: base),
    commands: @[@["ct", "test", "run"]])
  if signature.len > 0:
    result.signature = CertificateSignature(
      algorithm: SignatureAlgorithm, value: signature)

proc document(cert: TestCertificate): string = renderCertificate(cert)

proc rowValue(model: CertificateIndicatorModel; label: string): string =
  for row in model.detail:
    if row.label == label:
      return row.value
  "<absent>"

proc storePath(name: string): string = WorkspaceRoot & "/" & StoreDir & "/" & name

proc localPath(content, name: string): string =
  ## Where `ct test` publishes a record for ``content`` (Transport.md §2.2).
  UserRoot & "/" & localStoreContentDir(content).relative & "/" & name

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

  test "a certificate matching the working tree's content and platform reads certified":
    ## Verification item 1. The positive control for every negative one below:
    ## if this did not read certified, none of the others would mean anything.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate())
    let model = world.evaluate()
    checkpoint "state = " & $model.state & "; summary = " & model.summary
    check model.state == cisCertified
    check model.label == CertifiedLabel
    check model.summary == CommittedCertifiedSummary
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
    # The binding, and the commit labelled for what it is: informational.
    check rows.getOrDefault("Content") == TreeA
    check rows.getOrDefault("Base (informational)") == CommitA
    check rows.getOrDefault("Scope") == "whole repository"
    # Nothing of the earlier draft is disclosed.
    check not rows.hasKey("Commit")
    check not rows.hasKey("Tested state")
    # A record with no base has no base row, rather than an empty one.
    let unbased = newWorld()
    discard unbased.withCertificate(sampleCertificate(base = ""))
    for row in unbased.evaluate().detail:
      check row.label != "Base (informational)"

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

  test "a certificate for other content does not read certified":
    ## Verification item 2. `vcs.content` must equal the working tree's
    ## content id (Verification.md §4.1.1).
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(content = TreeB))
    let model = world.evaluate()
    checkpoint "state = " & $model.state & "; summary = " & model.summary
    check model.state != cisCertified
    check model.label != CertifiedLabel

  test "base is never compared: content decides, in both directions":
    ## Verification.md §4.1.1. A record whose base is ANOTHER commit covers
    ## this tree when its content is W; a record whose base IS the commit the
    ## user is on does not when its content differs. A consumer comparing base
    ## fails one of the two.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(content = TreeA,
                                                    base = CommitB))
    let otherBase = world.evaluate()
    checkpoint "other base, same content: " & $otherBase.state
    check otherBase.state == cisCertified

    let moved = newWorld()
    moved.workingTree = TreeB
    moved.head = TreeB
    moved.index = TreeB
    discard moved.withCertificate(sampleCertificate(content = TreeA,
                                                    base = CommitA))
    let sameBase = moved.evaluate()
    checkpoint "same base, other content: " & $sameBase.state & " — " &
               sameBase.summary
    check sameBase.state != cisCertified
    # 2026-10-10 (SB-2b): neither W nor H is covered, and the record is for
    # content no longer in front of the user — "No certificates", never "was
    # certified" (operator decision 2026-10-09).
    check sameBase.state == cisNoCertificates

  test "a certificate for another platform does not read certified":
    ## A green Linux run says nothing about macOS (Verification.md §5), and
    ## the remedy differs from staleness: nothing about this machine has ever
    ## been certified, so it is "not certified" rather than "was certified".
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(platform = "macos/arm64"))
    let model = world.evaluate()
    check model.state == cisNotCertified
    check "macos/arm64" in model.summary

  test "an edit after a green run reads changed since certified":
    ## SB-2b (SB-1's "was certified" case, rewritten for the content binding).
    ## HEAD certified, then a tracked edit: W moves, H does not. The only form
    ## of the "was certified" state (operator decision 2026-10-09).
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(content = TreeA))
    check world.evaluate().state == cisCertified
    world.workingTree = TreeB
    let model = world.evaluate()
    checkpoint "after the edit: " & $model.state & " — " & model.summary
    check model.state == cisWasCertified
    check model.label == WasCertifiedLabel
    check model.label == "Changed since certified"
    check model.summary == ChangedSinceCertifiedSummary
    check model.remedy == ChangedSinceCertifiedRemedy
    # THE CONTROL: reverting the edit returns to "Certified" with no run,
    # because W is H again.
    world.workingTree = TreeA
    let reverted = world.evaluate()
    check reverted.state == cisCertified
    check reverted.label == CertifiedLabel

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
    check ".repro/workspace/certificates" in model.searched
    check localPath(TreeA, "").strip(leading = false, chars = {'/'}) in
          model.searched
    check ".ct/certificates" notin model.searched

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

  test "the indicator refreshes when the working tree's content changes":
    ## Verification item 6. The deliverable is that the indicator "cannot go on
    ## claiming validity it has lost", so the assertion is that the model MOVED
    ## — not merely that a refresh was requested.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(content = TreeA))
    let vm = newCertificateIndicatorVm(world.reader)

    check vm.refresh(citStartup)
    check vm.model.state == cisCertified
    let atStartup = vm.revision

    # A checkout of other content — HEAD moved, and W and S with it.
    world.workingTree = TreeB
    world.head = TreeB
    world.index = TreeB
    check vm.refresh(citCommitChanged)
    check vm.model.state == cisNoCertificates
    check vm.revision == atStartup + 1
    check vm.lastTrigger == citCommitChanged

    # Back, then an edit and its revert: the tree moved without HEAD moving.
    world.workingTree = TreeA
    world.head = TreeA
    world.index = TreeA
    discard vm.refresh(citCommitChanged)
    check vm.model.state == cisCertified
    world.workingTree = TreeB
    check vm.refresh(citWorktreeChanged)
    check vm.model.state == cisWasCertified
    check vm.lastTrigger == citWorktreeChanged

    # A certificate arriving in the store.
    world.put(storePath("later.toml"),
              document(sampleCertificate(content = TreeB, base = CommitB)),
              2000)
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
              document(sampleCertificate(content = TreeA)), 1000)
    world.put(localPath(TreeB, "new.toml"),
              document(sampleCertificate(content = TreeB)), 2000)
    world.workingTree = TreeB
    let model = world.evaluate()
    check model.state == cisCertified
    check model.certificateName == localPath(TreeB, "new.toml")

    # And the other way round, so the case cannot pass by accident of which
    # directory is searched first.
    world.put(WorkspaceRoot & "/.repro/workspace/certificates/old.toml",
              document(sampleCertificate(content = TreeA)), 3000)
    world.workingTree = TreeA
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
    agentWorld.put(localPath(TreeA, "agent.toml"), document(agentCert), 1000)

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
      "base = \"" & CommitA & "\"\r\n" &
      "content = '" & TreeA & "'\r\n" &
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
    discard stale.withCertificate(sampleCertificate(content = TreeA))
    stale.workingTree = TreeB
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

  test "a repository this build could not establish is unverifiable":
    ## Where the client cannot tell, it must say so. A consumer that does not
    ## know which repository it is in cannot decide the content binding either
    ## way, and reporting "not certified" would send an operator to run tests
    ## over a VCS problem.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate())
    world.known = false
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

  test "a content id this build cannot compute reads unverifiable":
    ## Verification.md §4.1.1: a record in an algorithm the consumer cannot
    ## compute for the working tree — `git-tree-sha256` against a SHA-1
    ## repository, an algorithm the standard does not define — has not been
    ## shown to mismatch. Reporting "was certified, no longer valid" would be a
    ## claim this build has not earned every bit as much as "certified" would.
    for content in [
        "git-tree-sha256:" & repeat('a', 64),
        "blake3-manifest-v1:" & repeat('a', 64)]:
      let world = newWorld()
      discard world.withCertificate(sampleCertificate(content = content))
      let model = world.evaluate()
      checkpoint content & ": " & $model.state & " — " & model.summary
      check model.state == cisUnverifiable
      check model.state != cisWasCertified
      check model.state != cisCertified
      check model.remedy == FixConfigurationRemedy

  test "a malformed content id is not evidence, and is not unverifiable":
    ## Content-Id.md §1: an uppercase or abbreviated digest is decidably
    ## invalid and is never repaired into the id it was probably meant to be.
    ## The uppercase spelling of W itself must not read certified.
    for content in [TreeA.toUpperAscii.replace("GIT-TREE-SHA1", "git-tree-sha1"),
                    TreeA[0 ..< 26]]:
      let world = newWorld()
      discard world.withCertificate(sampleCertificate(content = content))
      let model = world.evaluate()
      checkpoint content & ": " & $model.state & " — " & model.summary
      check model.state != cisCertified
      check model.state != cisUnverifiable
      check "malformed content id" in model.summary

  test "a working tree with no content id reads unverifiable, never certified":
    ## Content-Id.md §3: an unmerged index, an assume-unchanged entry, a
    ## modified submodule — states with no honest content id. The record may
    ## well be for this tree; nobody can tell, and the reason is named.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(content = TreeA))
    world.workingTreeProblem = "the working tree has no content id: the " &
                               "index has unmerged entries (f.txt)"
    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check "unmerged" in model.summary
    # The control: the condition cleared, the same record reads by content.
    world.workingTreeProblem = ""
    check world.evaluate().state == cisCertified

  test "an earlier-draft record in the store no longer reads certified":
    ## The record `ct test` wrote before the content-binding revision: bound
    ## to a commit, `clean = true`, no `content`. Before CTC-3c the shipped
    ## verifier read it as covering HEAD, so the status bar said "Certified".
    ## It is decidably invalid — "Not certified", never unverifiable — and
    ## nothing translates it into the current shape.
    let world = newWorld()
    world.put(storePath("linux-amd64.toml"), "schema = \"test-certificate.v1\"\n" &
      "\n[certificate]\nframework = \"ct-test\"\nproject = \"" & RepoName &
      "\"\nplatform = \"" & Platform & "\"\n" &
      "targets = [\"tests/calc_test.nim\"]\nresult = \"passed\"\n" &
      "issued_at = \"2026-08-18T09:00:00Z\"\nissuer = \"ct-test\"\n" &
      "\n[certificate.vcs]\nrepo = \"" & RepoName & "\"\n" &
      "commit = \"" & CommitA & "\"\nclean = true\nuntracked = false\n" &
      "\n[[certificate.command]]\nargv = [\"ct\", \"test\", \"run\"]\n", 1000)
    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    check model.state == cisNotCertified
    check model.label == NotCertifiedLabel
    check model.state != cisUnverifiable
    # The cause and the remedy (Status-Bar.md): the record predates the
    # current format; run the tests to re-issue it.
    check model.summary == EarlierDraftSummary
    check "earlier-draft" in model.summary
    check "predates the current certificate format" in model.summary
    check model.remedy == EarlierDraftRemedy
    check "re-issue" in model.remedy

  test "a record issued under another repository name covers the same content":
    ## 2026-10-10 (CTC-3f): `vcs.repo` is NOT compared. It is the producer's
    ## root directory name, so requiring it to match would blind a clone or
    ## worktree checked out under another name to its siblings' certificates
    ## for the very same content (Transport.md §2.2); Verification.md §4.1
    ## leaves the comparison to the consumer, and this one declines it. The
    ## name is still disclosed, labelled informational.
    let world = newWorld()
    discard world.withCertificate(sampleCertificate(repo = "other-project"))
    let model = world.evaluate()
    check model.state == cisCertified
    check rowValue(model, "Repository (informational)") == "other-project"
    # Control: the same foreign name over OTHER content is still not covered —
    # it is the content, not the name, that decides.
    let other = newWorld()
    discard other.withCertificate(sampleCertificate(repo = "other-project",
                                                    content = TreeB))
    check other.evaluate().state != cisCertified

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

# ---------------------------------------------------------------------------
# SB-2b: the decision on W, H and S
# ---------------------------------------------------------------------------

const
  TreeC = "git-tree-sha1:cccccccccccccccccccccccccccccccccccccccc"
    ## A third content: a partially staged index, say.

proc inLocalStore(world: FakeWorld; cert: TestCertificate;
                  name = "linux-amd64.toml"; modifiedMs: int64 = 1000) =
  ## Where `ct test` publishes: the record's own content directory.
  world.put(localPath(cert.vcs.content, name), document(cert), modifiedMs)

# ---- A platform for the fact SOURCE, over the same fake world --------------
#
# `certificate_indicator_source` gathers W, H and S through the facade's
# `vcs.contentId`. Its failure paths — git failing for the working tree, a
# state with no content id — are what the obligation "a working tree whose
# content could not be computed never reads certified" is about, so they are
# driven through the SHIPPED source over a platform whose facade answers from
# the fake world (the shipped instantiations run against real git in
# `certificate_indicator_native_test.nim`). Built at module level: closure
# literals inside a `test` body do not compile under `nim js` (see above).

proc idFor(world: FakeWorld; source: VcsBlobSource): string =
  case source
  of vbsWorkingTree: world.workingTree
  of vbsHead: world.head
  of vbsIndex: world.index

proc fakePlatform(world: FakeWorld; workingTreeFails = false;
                  unmergedPath = ""; localStore = true;
                  versionControl = true): Platform =
  result = newPlatform(
    if versionControl: desktopProfile
    else: desktopProfile.withCapabilities(
      desktopCapabilities - {capVcsRead, capVcsWrite, capVcsRemote}, @[]))
  result.vcs.repositoryRoot = proc(path: string):
      PlatformFuture[PlatformOutcome[string]] =
    resolvedOk(WorkspaceRoot)
  result.vcs.contentId = proc(repository: string; state: VcsBlobSource;
                              algorithm: string; scope: seq[string]):
      PlatformFuture[PlatformOutcome[VcsContentId]] =
    if state == vbsWorkingTree and workingTreeFails:
      # The temporary index could not be built: git failed. An ERROR, not an
      # id — and in particular not H's id, which is the reassuring default.
      return resolvedErr[VcsContentId](pkFailed,
        "git status --porcelain failed: fatal: index file corrupt")
    if state == vbsWorkingTree and unmergedPath.len > 0:
      return resolvedOk(VcsContentId(kind: vcikNoContentId,
        algorithm: algorithm,
        conditions: @[NoContentIdState(condition: ncUnmergedEntries,
                                       paths: @[unmergedPath])],
        reason: "this state has no content id"))
    let id = world.idFor(state)
    if algorithm != "git-tree-sha1" or scope.len > 0:
      return resolvedOk(VcsContentId(kind: vcikCannotCompute,
        algorithm: algorithm, reason: "a SHA-1 repository"))
    if id.len == 0:
      return resolvedErr[VcsContentId](pkFailed, "HEAD does not exist yet")
    resolvedOk(VcsContentId(kind: vcikComputed, id: id, algorithm: algorithm))
  result.fs.certificateStoreRoots = proc():
      PlatformFuture[PlatformOutcome[CertificateStoreRoots]] =
    if localStore:
      resolvedOk(CertificateStoreRoots(available: true, user: UserRoot))
    else:
      resolvedOk(noLocalStore("this host has no per-user directory"))
  result.fs.listDir = proc(path: string):
      PlatformFuture[PlatformOutcome[seq[FsDirEntry]]] =
    var entries: seq[FsDirEntry] = @[]
    var exists = false
    for file in world.files.keys:
      if dirOf(file) == path:
        entries.add FsDirEntry(name: nameOf(file), kind: fekFile)
      if file.startsWith(path & "/"):
        exists = true
    if not exists:
      return resolvedErr[seq[FsDirEntry]](pkNotFound, "no such directory")
    resolvedOk(entries)
  result.fs.readText = proc(path: string):
      PlatformFuture[PlatformOutcome[string]] =
    if not world.files.hasKey(path):
      return resolvedErr[string](pkNotFound, "no such file")
    resolvedOk(world.files[path].text)

proc sourced(world: FakeWorld; workingTreeFails = false; unmergedPath = "";
             localStore = true; versionControl = true):
    CertificateIndicatorModel =
  evaluateCertificateIndicator(platformCertificateFacts(
    fakePlatform(world, workingTreeFails, unmergedPath, localStore,
                 versionControl),
    WorkspaceRoot, Platform))

suite "SB-2b: the indicator decides on content":

  test "a certificate matching the working tree's content and platform reads certified, whatever its base":
    ## The full label set: W = H reads "Certified", with the committed-state
    ## tooltip, from a record whose base is a commit that is not HEAD.
    let world = newWorld()
    world.inLocalStore(sampleCertificate(content = TreeA, base = CommitB))
    let model = world.evaluate()
    check model.state == cisCertified
    check model.label == CertifiedLabel
    check model.summary == CommittedCertifiedSummary
    check model.remedy == ""
    check rowValue(model, "Base (informational)") == CommitB
    check rowValue(model, "Content") == TreeA

  test "a tested, uncommitted tree reads certified, uncommitted":
    ## Edit, run, no commit: the record covers W, and W ≠ H.
    let world = newWorld()
    world.workingTree = TreeB
    world.inLocalStore(sampleCertificate(content = TreeB))
    let vm = newCertificateIndicatorVm(world.reader)
    discard vm.refresh(citStartup)
    checkpoint vm.model.summary
    check vm.model.state == cisCertified
    check vm.model.label == CertifiedUncommittedLabel
    check vm.model.label == "Certified, uncommitted"
    check vm.model.summary.startsWith(UncommittedCertifiedSummary)
    # Nothing staged yet: S is H's content, not what was tested.
    check StagedDiffersWarning in vm.model.summary

    # `git add -A`: S is now W, and the warning goes.
    world.index = TreeB
    check vm.refresh(citIndexChanged)
    check vm.lastTrigger == citIndexChanged
    check vm.model.label == CertifiedUncommittedLabel
    check vm.model.summary == UncommittedCertifiedSummary
    check StagedDiffersWarning notin vm.model.summary

    # `git add` of HALF the change: S is a third content, and the warning is
    # back — a `git commit` now would record something nobody tested.
    world.index = TreeC
    check vm.refresh(citIndexChanged)
    check vm.model.label == CertifiedUncommittedLabel
    check vm.model.summary == UncommittedCertifiedSummary & " " &
                              StagedDiffersWarning

    # `git commit -a`: H becomes the tested content. Certified, with the store
    # unchanged and no test run in between.
    let filesBefore = world.files.len
    world.head = TreeB
    world.index = TreeB
    check vm.refresh(citCommitChanged)
    check vm.model.state == cisCertified
    check vm.model.label == CertifiedLabel
    check vm.model.summary == CommittedCertifiedSummary
    check world.files.len == filesBefore

  test "a tree that moved on past its last green run reads not certified":
    ## Operator decision 2026-10-09. HEAD certified, then a commit of other
    ## content: neither W nor H is covered while a valid record for the old
    ## content sits in the store. Nothing was found for W's, H's or S's
    ## content, so the label is "No certificates" — never "was certified".
    let world = newWorld()
    world.inLocalStore(sampleCertificate(content = TreeA))
    # A pooled reprobuild record for the old content too, newest of all: a
    # "newest record in the store speaks" fallback would pick it up.
    world.put(storePath("build.toml"),
              document(sampleCertificate(content = TreeA)), 5000)
    check world.evaluate().state == cisCertified
    world.workingTree = TreeB
    world.head = TreeB
    world.index = TreeB
    let moved = world.evaluate()
    checkpoint $moved.state & " — " & moved.summary
    check moved.state == cisNoCertificates
    check moved.label == NoCertificatesLabel
    check moved.summary == NoCertificatesFoundSummary
    check moved.state != cisWasCertified
    check moved.certificateName == ""

    # A record for this content that fails to cover W — another platform —
    # placed in W's directory: records WERE found, and none matched.
    world.inLocalStore(sampleCertificate(content = TreeB,
                                         platform = "macos/arm64"),
                       name = "macos-arm64.toml")
    let found = world.evaluate()
    checkpoint $found.state & " — " & found.summary
    check found.state == cisNotCertified
    check found.label == NotCertifiedLabel
    check "says nothing about another" in found.summary
    check found.remedy == RunTheTestsRemedy

    # THE CONTROL: an edit with HEAD still certified is "changed since
    # certified".
    let edited = newWorld()
    edited.inLocalStore(sampleCertificate(content = TreeA))
    edited.workingTree = TreeB
    check edited.evaluate().state == cisWasCertified

  test "a record covering only the staged content is found, and is not certified":
    ## Transport.md §5 from the other side: a valid record for S's content
    ## (looked up in S's directory) is "found" — the label is "Not certified",
    ## not "No certificates" — and it certifies neither W nor H.
    let world = newWorld()
    world.workingTree = TreeB
    world.index = TreeC
    world.inLocalStore(sampleCertificate(content = TreeC))
    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    check model.state == cisNotCertified
    check "staged content" in model.summary
    check rowValue(model, "Staged (S)") == "covered"
    check rowValue(model, "Working tree (W)") == "not covered"
    check rowValue(model, "HEAD (H)") == "not covered"

  test "the disclosure says whether W, H and S are each covered":
    let world = newWorld()
    world.workingTree = TreeB
    world.index = TreeB
    world.inLocalStore(sampleCertificate(content = TreeB))
    world.inLocalStore(sampleCertificate(content = TreeA))
    let model = world.evaluate()
    check model.label == CertifiedUncommittedLabel
    check rowValue(model, "Working tree (W)") == "covered"
    check rowValue(model, "HEAD (H)") == "covered"
    check rowValue(model, "Staged (S)") == "covered"
    check rowValue(model, "Content") == TreeB
    world.workingTree = TreeC
    world.index = TreeC
    let changed = world.evaluate()
    check changed.label == WasCertifiedLabel
    check rowValue(changed, "Working tree (W)") == "not covered"
    check rowValue(changed, "HEAD (H)") == "covered"
    check rowValue(changed, "Staged (S)") == "not covered"
    # The record that speaks for "changed since certified" is H's.
    check rowValue(changed, "Content") == TreeA

  test "untracked = true is named in the tooltip of every state it binds":
    ## Status-Bar.md: when the binding certificate reports untracked = true,
    ## the tooltip says untracked files were present and are not covered.
    var cert = sampleCertificate(content = TreeA)
    cert.vcs.untracked = true
    let world = newWorld()
    world.inLocalStore(cert)
    let committed = world.evaluate()
    check committed.label == CertifiedLabel
    check committed.summary == CommittedCertifiedSummary & " " & UntrackedNote
    check rowValue(committed, "Untracked files") == "present when the tests ran"
    world.workingTree = TreeB
    let changed = world.evaluate()
    check changed.label == WasCertifiedLabel
    check UntrackedNote in changed.summary
    # The control: the same record with untracked = false says nothing.
    let clean = newWorld()
    clean.inLocalStore(sampleCertificate(content = TreeA))
    check UntrackedNote notin clean.evaluate().summary

  test "a working tree with no content id is unverifiable, even with HEAD certified":
    ## Never certified — the condition and the remedy named, and the
    ## disclosure still saying H is covered. Through the SHIPPED source, so
    ## the condition is the facade's and the remedy is the source's.
    let world = newWorld()
    world.inLocalStore(sampleCertificate(content = TreeA))
    let model = world.sourced(unmergedPath = "calc.nim")
    checkpoint $model.state & " — " & model.summary & " / " & model.remedy
    check model.state == cisUnverifiable
    check model.state != cisCertified
    check "unmerged" in model.summary
    check "calc.nim" in model.summary
    check "even though HEAD's content is certified" in model.summary
    check "Resolve the merge" in model.remedy
    check "git merge --abort" in model.remedy
    check rowValue(model, "HEAD (H)") == "covered"
    check rowValue(model, "Working tree (W)").startsWith("no content id")
    # THE CONTROL: the condition cleared, the same repository reads by its
    # content.
    check world.sourced().state == cisCertified

  test "a working tree with no content id and nothing stored reads no certificates":
    ## Status-Bar.md, clarified 2026-10-10: with no record found anywhere the
    ## absent-store rule decides — "No certificates", never "Unverifiable" —
    ## but the condition and its remedy are still named, and it is never
    ## certified.
    let world = newWorld()
    let model = world.sourced(unmergedPath = "calc.nim")
    checkpoint $model.state & " — " & model.summary & " / " & model.remedy
    check model.state == cisNoCertificates
    check model.label == NoCertificatesLabel
    check "unmerged" in model.summary
    check "calc.nim" in model.summary
    check "Resolve the merge" in model.remedy
    # The control: the condition cleared, the plain empty-store reading.
    let clear = world.sourced()
    check clear.state == cisNoCertificates
    check "unmerged" notin clear.summary
    check clear.remedy == RunTheTestsRemedy

  test "a working tree whose content could not be computed never reads certified":
    ## The obligation SB-1's mutation survivor left. The working tree's
    ## content id FAILS (git could not build the temporary index) while H is
    ## covered by a record in H's directory. A source that defaulted W to H —
    ## or to any id — would read "Certified" here.
    let world = newWorld()
    world.inLocalStore(sampleCertificate(content = TreeA))
    check world.sourced().state == cisCertified
    let failed = world.sourced(workingTreeFails = true)
    checkpoint $failed.state & " — " & failed.summary
    check failed.state != cisCertified
    check failed.state == cisUnverifiable
    check "index file corrupt" in failed.summary
    check failed.remedy == FixConfigurationRemedy
    # And with W computable but moved, the same store reads by content: H's
    # record is found through H's directory, and W is not covered.
    world.workingTree = TreeB
    check world.sourced().state == cisWasCertified

  test "the source looks up W's, H's and S's content directories, and no other":
    let world = newWorld()
    world.workingTree = TreeB
    world.index = TreeC
    let model = world.sourced()
    for id in [TreeA, TreeB, TreeC]:
      check localPath(id, "").strip(leading = false, chars = {'/'}) in
            model.searched
    check localPath("git-tree-sha1:" & repeat('d', 40), "").strip(
      leading = false, chars = {'/'}) notin model.searched
    check model.state == cisNoCertificates

  test "a host with no local store reads unverifiable, not no certificates":
    ## SB-2b: the web host has no local certificate store; it has not looked,
    ## and "no certificates" would claim it had.
    let world = newWorld()
    let model = world.sourced(localStore = false)
    checkpoint $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check model.state != cisNoCertificates
    check "no local certificate store" in model.summary
    # And with no version control either — the web host has neither, so no
    # content id is ever looked up and the store reader never reaches the
    # roots; the source still reports that it could not look.
    let noVcs = world.sourced(localStore = false, versionControl = false)
    checkpoint $noVcs.state & " — " & noVcs.summary
    check noVcs.state == cisUnverifiable
    check "no local certificate store" in noVcs.summary
    # The controls: the same worlds with a store read "No certificates".
    check world.sourced().state == cisNoCertificates
    check world.sourced(versionControl = false).state == cisNoCertificates

  test "an earlier-draft record in W's directory is not certified, with the re-issue remedy":
    ## Found for W's content (it sits in W's directory of the local store)
    ## and decidably invalid: never unverifiable, never translated.
    let world = newWorld()
    world.put(localPath(TreeA, "draft.toml"),
      "schema = \"test-certificate.v1\"\n" &
      "\n[certificate]\nframework = \"ct-test\"\nproject = \"" & RepoName &
      "\"\nplatform = \"" & Platform & "\"\n" &
      "targets = [\"tests/calc_test.nim\"]\nresult = \"passed\"\n" &
      "issued_at = \"2026-08-18T09:00:00Z\"\nissuer = \"ct-test\"\n" &
      "\n[certificate.vcs]\nrepo = \"" & RepoName & "\"\n" &
      "commit = \"" & CommitA & "\"\nclean = true\nuntracked = false\n" &
      "\n[[certificate.command]]\nargv = [\"ct\", \"test\", \"run\"]\n", 1000)
    let model = world.evaluate()
    check model.state == cisNotCertified
    check model.summary == EarlierDraftSummary
    check model.remedy == EarlierDraftRemedy

  test "an uncomputable algorithm reads unverifiable even when H is certified":
    ## git-tree-sha256 in a SHA-1 repository, beside a record covering H: W
    ## cannot be decided, so "changed since certified" — a claim that W is
    ## NOT covered — would be a guess.
    let world = newWorld()
    world.workingTree = TreeB
    world.inLocalStore(sampleCertificate(content = TreeA))
    world.put(storePath("sha256.toml"), document(sampleCertificate(
      content = "git-tree-sha256:" & repeat('e', 64))), 2000)
    let model = world.evaluate()
    checkpoint $model.state & " — " & model.summary
    check model.state == cisUnverifiable
    check model.remedy == FixConfigurationRemedy

  test "a change in .git names the fact it moved":
    ## The refresh triggers: staging rewrites `index` (S), everything else in
    ## `.git` that a watch sees is HEAD moving (H).
    check gitDirTrigger("/w/demo-project/.git/index") == citIndexChanged
    check gitDirTrigger("/w/demo-project/.git/index.lock") == citIndexChanged
    check gitDirTrigger("index") == citIndexChanged
    check gitDirTrigger("/w/demo-project/.git/HEAD") == citCommitChanged
    check gitDirTrigger("/w/demo-project/.git/ORIG_HEAD") == citCommitChanged
    check gitDirTrigger("C:\\w\\.git\\index") == citIndexChanged
    check gitDirTrigger("/w/demo-project/.git/indexes") == citCommitChanged
