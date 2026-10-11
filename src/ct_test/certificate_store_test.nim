## The certificate store READER, against a real filesystem: the local
## certificate store (Transport.md §2.4, looked up by content id in both
## roots) and reprobuild's workspace carrier.
##
## 2026-10-10 (CTC-3e): the cases that used `ct test`'s old workspace store
## (`.ct/certificates`) now use reprobuild's carrier, which is still pooled
## and has the same flat layout; `.ct/certificates` is no longer read at all
## ("the abandoned .ct store is not searched"), and the local-store lookup has
## its own suite below ("the reader finds records by content id").
##
## NO MOCKS. Every directory below is a real directory, every certificate a
## real file produced by the shipped ``renderCertificate``, and the unreadable
## cases are made unreadable with real mode bits. The companion suite
## ``src/tests/gui/tests/status-bar/certificate_indicator_vm_test.nim`` drives
## the same ``readCertificateStore`` over an in-memory tree, because it must
## also run under ``nim js`` where ``std/os`` does not exist; this file is the
## half that proves the rules hold against the host the product reads.
##
## It also carries the **read-only guard**. SB-1 requires that the indicator
## never issue, sign or verify-into-existence a certificate, and that is a
## property of the module graph rather than of any single run — so it is
## asserted at the source level, the way ``certificate_issuance_test.nim``
## asserts that nothing outside its own module can reach the signing routine.

import std/[options, os, sequtils, strutils, times, unittest]

import certificate
import certificate_store

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-cert-store" / name & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc sampleDocument(content = "git-tree-sha1:" & "a".repeat(40);
                    platform = "linux/amd64";
                    repo = "demo"; issuedAt = "2026-08-18T09:00:00Z"): string =
  renderCertificate(TestCertificate(
    schema: CertificateSchema,
    framework: "ct-test",
    project: repo,
    platform: platform,
    targets: @["tests/calc_test.nim"],
    result: "passed",
    issuedAt: issuedAt,
    issuer: "ct-test",
    vcs: VcsState(repo: repo, paths: @[], content: content,
                  untracked: false),
    commands: @[@["ct", "test", "run"]]))

proc writeCertificate(root, dir, name, text: string) =
  createDir(root / dir)
  writeFile(root / dir / name, text)

proc noLocalLookup(): LocalStoreQuery =
  ## The workspace carriers alone: no content id to look up, so the local
  ## store is not consulted.
  LocalStoreQuery(roots: CertificateStoreRoots(available: true,
                                               user: "/nonexistent-user-root"))

proc readWorkspace(access: CertificateStoreAccess; root: string):
    CertificateStore =
  readCertificateStore(access, root, noLocalLookup())

suite "the workspace certificate store, on a real filesystem":

  test "a workspace with no store is not an error and not a store":
    ## Transport.md §4: an absent certificate store is a normal state for a
    ## project that does not use certificates and MUST NOT be an error in
    ## itself. The `searched` list is what makes the report actionable.
    let root = scratchDir("absent")
    let store = readWorkspace(nativeStoreAccess(), root)
    check not store.present
    check not store.unreadable
    check store.certificates.len == 0
    check store.searched == @[ReprobuildStoreDir]
    check AbandonedCtTestStoreDir notin store.searched
    check not store.hasKeyStore

  test "a store directory that exists and is empty is present and empty":
    ## The distinction Transport.md §4 asks for in as many words: "no
    ## certificates found" and "certificates found but none matched" are
    ## different outcomes. This is the first, with the store genuinely there.
    let root = scratchDir("empty")
    createDir(root / ReprobuildStoreDir)
    let store = readWorkspace(nativeStoreAccess(), root)
    check store.present
    check not store.unreadable
    check store.certificates.len == 0

  test "certificates are found in both carriers and ordered newest first":
    ## "The last produced certificate, whatever produced it." The local store
    ## and reprobuild's workspace directory are pooled — a hook writing into
    ## reprobuild's location and `ct test` publishing to the local store must
    ## be ranked together, or which one speaks would depend on which tool ran.
    let root = scratchDir("both")
    let userRoot = scratchDir("both-user-root")
    let agentContent = "git-tree-sha1:" & "b".repeat(40)
    writeCertificate(root, ReprobuildStoreDir, "hook.toml", sampleDocument())
    let agentDir = "v1/git-tree-sha1/" & "b".repeat(40)
    writeCertificate(userRoot, agentDir, "agent.toml",
                     sampleDocument(content = agentContent))
    let query = LocalStoreQuery(
      roots: CertificateStoreRoots(available: true, user: userRoot),
      contentIds: @[agentContent])

    # Real mtimes, set explicitly so the ordering assertion is about the rule
    # and not about how fast this machine writes two files.
    let base = getTime()
    setLastModificationTime(root / ReprobuildStoreDir / "hook.toml",
                            base - initDuration(minutes = 10))
    setLastModificationTime(userRoot / agentDir / "agent.toml", base)

    var store = readCertificateStore(nativeStoreAccess(), root, query)
    check store.present
    check store.certificates.len == 2
    check store.lastProduced.name == userRoot & "/" & agentDir & "/agent.toml"

    # Flip the arrival order and the answer flips with it.
    setLastModificationTime(root / ReprobuildStoreDir / "hook.toml",
                            base + initDuration(minutes = 10))
    store = readCertificateStore(nativeStoreAccess(), root, query)
    check store.lastProduced.name == ReprobuildStoreDir & "/hook.toml"

  test "the abandoned .ct store is not searched":
    ## CTC-3e: `ct test` no longer writes `.ct/certificates`, and nothing reads
    ## it. A record left there by CTC-2 — even one covering everything — is
    ## not a candidate.
    let root = scratchDir("abandoned")
    writeCertificate(root, AbandonedCtTestStoreDir, "linux-amd64.toml",
                     sampleDocument())
    let store = readWorkspace(nativeStoreAccess(), root)
    check store.certificates.len == 0
    check not store.present
    check AbandonedCtTestStoreDir notin store.searched

  test "arrival order beats the record's own issued_at":
    ## `issued_at` is informational and explicitly NOT a trust input
    ## (Verification.md §4.3): clock skew is ordinary, and a consumer MUST NOT
    ## reject a certificate solely because its timestamp is in the future. A
    ## store ordered by that field would let one misconfigured machine pin
    ## itself permanently at the top of the list.
    let root = scratchDir("skew")
    writeCertificate(root, ReprobuildStoreDir, "skewed.toml",
                     sampleDocument(issuedAt = "2099-01-01T00:00:00Z"))
    writeCertificate(root, ReprobuildStoreDir, "recent.toml",
                     sampleDocument(content = "git-tree-sha1:" & "c".repeat(40),
                                    issuedAt = "2026-01-01T00:00:00Z"))
    let base = getTime()
    setLastModificationTime(root / ReprobuildStoreDir / "skewed.toml",
                            base - initDuration(hours = 1))
    setLastModificationTime(root / ReprobuildStoreDir / "recent.toml", base)

    let store = readWorkspace(nativeStoreAccess(), root)
    check store.lastProduced.name == ReprobuildStoreDir & "/recent.toml"

  test "a certificate that cannot be read makes the store unreadable, not empty":
    ## "There is nothing here" and "I could not look" are different answers,
    ## and only the second is a configuration fault. Made real with mode bits
    ## rather than simulated.
    let root = scratchDir("unreadable")
    writeCertificate(root, ReprobuildStoreDir, "run.toml", sampleDocument())
    let path = root / ReprobuildStoreDir / "run.toml"
    setFilePermissions(path, {})

    # A test running as root can read a 0000 file, so the case would pass
    # vacuously there. Establish that the mode bit actually denies this
    # process before asserting anything about it.
    var denied = false
    try:
      discard readFile(path)
    except IOError, OSError:
      denied = true
    if denied:
      let store = readWorkspace(nativeStoreAccess(), root)
      check store.present
      check store.unreadable
      check "could not be read" in store.unreadableReason
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    else:
      # A process running as root reads a 0000 file, so the mode bit cannot
      # deny it and the real-filesystem form of this case is unavailable here.
      # The rule is still asserted, through the seam — which is what the
      # headless suite does on every host — rather than being reported green
      # for an environment that never exercised it.
      setFilePermissions(path, {fpUserRead, fpUserWrite})
      checkpoint "this process can read a 0000 file (root?); asserting the " &
                 "rule through the access seam instead of the mode bit"
      var access = nativeStoreAccess()
      access.readText = proc(p: string): StoreRead {.closure.} =
        StoreRead(status: srUnreadable, detail: "permission denied")
      let store = readWorkspace(access, root)
      check store.present
      check store.unreadable
      check "could not be read" in store.unreadableReason

  test "the key store is read, and an unreadable one is not an empty one":
    ## Verification.md §3.1's most easily-lost distinction, at the store layer:
    ## an empty store ANSWERS — nobody is trusted — while one that cannot be
    ## read answers nothing.
    let root = scratchDir("keys")
    writeCertificate(root, ReprobuildStoreDir, "run.toml", sampleDocument())
    writeFile(root / ReprobuildStoreDir / RegisteredKeysFile, """
schema = "registered-keys.v1"

[[key]]
key_id = "k1"
public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
status = "active"
""")
    var store = readWorkspace(nativeStoreAccess(), root)
    check store.hasKeyStore
    check store.keyStore.readable
    check store.keyStore.keys.len == 1
    # The key store is not a certificate, and must not be listed as one.
    check store.certificates.len == 1

    writeFile(root / ReprobuildStoreDir / RegisteredKeysFile, "not { toml at all")
    store = readWorkspace(nativeStoreAccess(), root)
    check store.hasKeyStore
    check not store.keyStore.readable
    # And the store itself is still perfectly readable — an unreadable KEY
    # store is an authenticity problem, not a discovery one.
    check not store.unreadable
    check store.certificates.len == 1

  test "a store directory that cannot be listed is present and unreadable":
    ## Found by mutation testing: flipping `present` to `false` on the
    ## unlistable branch survived every case in this repo, because the
    ## indicator happens to test `unreadable` first. `present` is a documented
    ## field of the store's report — "at least one store directory exists" —
    ## and a consumer reading it alone would have been told there is no store
    ## where there is one it could not open. The two fields answer different
    ## questions, so both are asserted.
    let root = scratchDir("unlistable")
    createDir(root / ReprobuildStoreDir)
    var access = nativeStoreAccess()
    access.listFiles = proc(dir: string): StoreListing {.closure.} =
      if dir.endsWith(ReprobuildStoreDir):
        StoreListing(status: srUnreadable, detail: "permission denied")
      else:
        StoreListing(status: srAbsent)
    let store = readWorkspace(access, root)
    check store.present
    check store.unreadable
    check "could not be listed" in store.unreadableReason
    check store.certificates.len == 0

  test "a private signing key in the store directory is never read":
    ## reprobuild's current implementation keeps a workspace-local private key
    ## beside the certificates. A discovery pass that slurped every file would
    ## read it — the last thing a read-only display should do — so the listing
    ## is an allow-list on `.toml`, and this case is what holds it there.
    let root = scratchDir("signing-key")
    writeCertificate(root, ReprobuildStoreDir, "run.toml", sampleDocument())
    writeFile(root / ReprobuildStoreDir / SigningKeyFile,
              "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n")
    let store = readWorkspace(nativeStoreAccess(), root)
    check store.certificates.len == 1
    for stored in store.certificates:
      check "PRIVATE KEY" notin stored.text
      check stored.name.endsWith(".toml")

suite "the local certificate store reader (Transport.md §2.4)":

  test "the reader finds records by content id":
    ## Through the same read-only seam the indicator uses, on real
    ## directories: both roots are listed for the one content directory asked
    ## about, and nothing else in the store is read.
    let w = "git-tree-sha1:" & "a".repeat(40)
    let other = "git-tree-sha1:" & "e".repeat(40)
    let wDir = "v1/git-tree-sha1/" & "a".repeat(40)
    let user = scratchDir("lookup-user")
    let system = scratchDir("lookup-system")
    let roots = CertificateStoreRoots(available: true, user: user,
                                      system: system)

    # An absent content directory is "none found": not unreadable, and the
    # report says where it looked, in both roots.
    var found = lookupLocalStore(nativeStoreAccess(), roots, w)
    check not found.unreadable
    check found.found.len == 0
    check found.searched == @[user & "/" & wDir, system & "/" & wDir]
    # An absent ROOT is the same answer.
    found = lookupLocalStore(nativeStoreAccess(), CertificateStoreRoots(
      available: true, user: user / "missing", system: system / "missing"), w)
    check not found.unreadable
    check found.found.len == 0

    # The candidates: a record for W in the user root; the same bytes in the
    # system root (evaluated once); a signed twin in the system root (NOT the
    # same bytes, so it is a second candidate); and things that are not
    # candidates — a writer's temporary file, a dot-file ending in .toml, a
    # non-.toml file, and a record whose own content names another directory.
    let record = sampleDocument(content = w)
    var signedCert = readCertificate(record).cert
    signedCert.keyId = "k1"
    let unsignedTwin = renderCertificate(signedCert)
    signedCert.signature = CertificateSignature(algorithm: SignatureAlgorithm,
                                                value: "U1NIU0lH")
    let signedTwin = renderCertificate(signedCert)
    writeCertificate(user, wDir, "r1.toml", record)
    writeCertificate(system, wDir, "r1.toml", record)
    writeCertificate(user, wDir, "twin.toml", unsignedTwin)
    writeCertificate(system, wDir, "twin.toml", signedTwin)
    writeCertificate(user, wDir, ".twin.toml.tmp-1-2-3", "partial")
    writeCertificate(user, wDir, ".hidden.toml", sampleDocument(content = w,
                                                                platform = "x/y"))
    writeCertificate(user, wDir, "notes.txt", "not a certificate")
    writeCertificate(user, wDir, "misfiled.toml",
                     sampleDocument(content = other))
    # And a record for ANOTHER content, which a lookup by W must not read.
    writeCertificate(user, "v1/git-tree-sha1/" & "e".repeat(40), "o.toml",
                     sampleDocument(content = other))

    found = lookupLocalStore(nativeStoreAccess(), roots, w)
    check not found.unreadable
    var texts: seq[string] = @[]
    for stored in found.found:
      texts.add stored.text
    checkpoint $found.found.len
    check found.found.len == 3
    check texts.count(record) == 1
    check unsignedTwin in texts
    check signedTwin in texts
    check found.rejected.len == 1
    check "misfiled.toml" in found.rejected[0]
    check other in found.rejected[0]
    for stored in found.found:
      check not stored.name.extractFilename.startsWith(".")
      check stored.name.endsWith(".toml")

    # Pooled into the indicator's store: the rejected record is reported
    # there too, and is not a candidate.
    let store = readCertificateStore(nativeStoreAccess(), scratchDir("ws"),
      LocalStoreQuery(roots: roots, contentIds: @[w]))
    check store.certificates.len == 3
    check store.rejected.len == 1
    check store.present

  test "an unreadable system root is reported, and the user root still searched":
    let w = "git-tree-sha1:" & "a".repeat(40)
    let wDir = "v1/git-tree-sha1/" & "a".repeat(40)
    let user = scratchDir("unreadable-system-user")
    let system = scratchDir("unreadable-system")
    writeCertificate(user, wDir, "r.toml", sampleDocument(content = w))
    let roots = CertificateStoreRoots(available: true, user: user,
                                      system: system)
    var access = nativeStoreAccess()
    let inner = access.listFiles
    access.listFiles = proc(dir: string): StoreListing {.closure.} =
      # Seam, not mode bits: a root-run test reads a 0000 directory, and the
      # property is about what the reader DOES with the answer.
      if dir.startsWith(system):
        StoreListing(status: srUnreadable, detail: "permission denied")
      else:
        inner(dir)
    let found = lookupLocalStore(access, roots, w)
    check not found.unreadable
    check found.found.len == 1
    check found.problems.len == 1
    check "system root" in found.problems[0]

    # The USER root unreadable is "could not look", never "none found".
    access.listFiles = proc(dir: string): StoreListing {.closure.} =
      if dir.startsWith(user):
        StoreListing(status: srUnreadable, detail: "permission denied")
      else:
        inner(dir)
    let blind = lookupLocalStore(access, roots, w)
    check blind.unreadable
    check "user root" in blind.unreadableReason
    let store = readCertificateStore(access, scratchDir("ws2"),
      LocalStoreQuery(roots: roots, contentIds: @[w]))
    check store.unreadable

    # A host with no local store at all (a browser tab) could not look either.
    let none = readCertificateStore(nativeStoreAccess(), scratchDir("ws3"),
      LocalStoreQuery(roots: noLocalStore("no per-user directory here"),
                      contentIds: @[w]))
    check none.unreadable
    check "no per-user directory here" in none.unreadableReason

suite "the certificate indicator is read-only by construction":

  test "the store's filesystem seam offers no way to write anything":
    ## SB-1: never issue, sign, or verify-into-existence a certificate. The
    ## seam is where a future change would be tempted to add one, because a
    ## caller supplies it — so the guard is on the seam's declared surface
    ## rather than on any particular caller's behaviour.
    let source = readFile(currentSourcePath().parentDir / "certificate_store.nim")
    var seamFields: seq[string] = @[]
    var inSeam = false
    for line in source.splitLines():
      if line.startsWith("  CertificateStoreAccess* = object"):
        inSeam = true
        continue
      if inSeam:
        if line.len > 0 and not line.startsWith("    ") and
           not line.startsWith("  #"):
          break
        let stripped = line.strip()
        let star = stripped.find("*: proc")
        if star > 0:
          seamFields.add stripped[0 ..< star]
    check seamFields == @["listFiles", "readText", "modifiedMs"]

  test "no module the indicator imports can produce a signature":
    ## The same argument `certificate_issuance_test.nim` makes about its own
    ## module, applied to the front end's import graph: the ONLY route to a
    ## signature is `runAndAttest`, and the indicator must not be able to reach
    ## it even by accident.
    ##
    ## A source-level assertion, because the property is "there is no such
    ## edge" — which no run can observe.
    let ctTestDir = currentSourcePath().parentDir
    let repoRoot = ctTestDir.parentDir.parentDir
    let vmDir = repoRoot / "src" / "frontend" / "viewmodel" / "viewmodels"

    for name in ["certificate_indicator_vm.nim", "certificate_indicator_source.nim"]:
      let path = vmDir / name
      check fileExists(path)
      if not fileExists(path):
        continue
      # IMPORT EDGES, not substrings. Both modules NAME the producer in prose —
      # `certificate_indicator_source` explains that it mirrors
      # `certificate_issuance.probeVcs` — and a substring scan would fail on
      # the comment while an actual import slipped past in a module the
      # comment did not mention. The property is about the graph.
      var imported: seq[string] = @[]
      var signs = false
      for line in readFile(path).splitLines():
        let stripped = line.strip()
        if stripped.startsWith("import ") or stripped.startsWith("from "):
          imported.add stripped
        # `-Y sign` cannot appear as CODE anywhere near the front end. Comment
        # lines are excluded for the same reason as above.
        if not stripped.startsWith("#") and "-Y\", \"sign\"" in stripped:
          signs = true
      checkpoint name & " imports: " & imported.join(" | ")
      for line in imported:
        # The producer module, which is the only one that can sign.
        check "certificate_issuance" notin line
        # And the signature primitive's own module, which shells out.
        check "certificate_signature" notin line
      check not signs

  test "the indicator's ViewModel depends on no agent session":
    ## SB-1: the indicator renders with no agent session present. That is a
    ## property of what the module can reach, and the behavioural half of it
    ## lives in the headless suite; this is the structural half.
    ##
    ## AA-4 became SB-1 precisely because a certificate attests to a repository
    ## state rather than to a conversation, so an import edge to a session is
    ## the defect this case exists to catch — not a stylistic preference.
    let ctTestDir = currentSourcePath().parentDir
    let repoRoot = ctTestDir.parentDir.parentDir
    let path = repoRoot / "src" / "frontend" / "viewmodel" / "viewmodels" /
               "certificate_indicator_vm.nim"
    check fileExists(path)
    var imports: seq[string] = @[]
    for line in readFile(path).splitLines():
      let stripped = line.strip()
      if stripped.startsWith("import "):
        imports.add stripped["import ".len .. ^1]
    checkpoint "imports: " & imports.join(" | ")
    check imports.len == 5
    check "std/strutils" in imports
    check "../../../ct_test/certificate" in imports
    # SB-2b: the content-id parser, to read a record's algorithm for "W = H"
    # and to tell records for other content from records it cannot place. A
    # pure module — no process, no signing, no session.
    check "../../../ct_test/certificate_content_id" in imports
    check "../../../ct_test/certificate_store" in imports
    check "../../../ct_test/certificate_verification" in imports
