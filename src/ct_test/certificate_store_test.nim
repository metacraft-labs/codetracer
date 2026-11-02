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

proc contentOf(letter: char): string = "git-tree-sha1:" & letter.repeat(40)
proc dirOf(letter: char): string = "v1/git-tree-sha1/" & letter.repeat(40)

proc rootsAt(user: string;
             system = "/nonexistent-ct-test-system-root"): CertificateStoreRoots =
  ## A RESOLVED system root that does not exist ("none found" there): an
  ## empty `system` would be an UNRESOLVED root, which makes every search
  ## incomplete (Transport.md §2.1).
  CertificateStoreRoots(available: true, user: user, system: system)

proc readFor(access: CertificateStoreAccess; roots: CertificateStoreRoots;
             letters: openArray[char]): CertificateStore =
  var ids: seq[string] = @[]
  for letter in letters:
    ids.add contentOf(letter)
  readCertificateStore(access, LocalStoreQuery(roots: roots, contentIds: ids))

suite "the certificate store, on a real filesystem":

  test "a store with nothing for this content is not an error and not a store":
    ## Transport.md §5: an absent certificate store is a normal state for a
    ## project that does not use certificates and MUST NOT be an error in
    ## itself. The `searched` list is what makes the report actionable.
    let user = scratchDir("absent-user")
    var store = readFor(nativeStoreAccess(), rootsAt(user / "missing"), ['a'])
    check not store.present
    check not store.unreadable
    check not store.incomplete
    check store.certificates.len == 0
    check store.searched == @[user / "missing" & "/" & dirOf('a'),
      "/nonexistent-ct-test-system-root/" & dirOf('a')]
    check not store.hasKeyStore
    # The content directory existing and empty is the same answer.
    createDir(user / dirOf('a'))
    store = readFor(nativeStoreAccess(), rootsAt(user), ['a'])
    check not store.present
    check not store.incomplete
    check store.certificates.len == 0

  test "no directory in the working tree is read for certificates":
    ## CTC-3e retired `.ct/certificates`; reprobuild now publishes to the
    ## local store (reprobuild-pm TC-8c), so its old
    ## `.repro/workspace/certificates` — records, registered-keys.toml and
    ## the private signing key reprobuild kept beside them — is not read
    ## either. A record there that covers everything is not a candidate, and
    ## the reader is not even told where the working tree is.
    let workspace = scratchDir("abandoned-workspace")
    for dir in [AbandonedCtTestStoreDir, AbandonedReprobuildStoreDir]:
      writeCertificate(workspace, dir, "run.toml",
                       sampleDocument(content = contentOf('a')))
    writeFile(workspace / AbandonedReprobuildStoreDir / "registered-keys.toml",
              "schema = \"registered-keys.v1\"\n")
    let previous = getCurrentDir()
    setCurrentDir(workspace)
    defer: setCurrentDir(previous)
    let store = readFor(nativeStoreAccess(),
                        rootsAt(scratchDir("abandoned-user")), ['a'])
    check store.certificates.len == 0
    check not store.present
    check not store.hasKeyStore
    for searched in store.searched:
      check AbandonedCtTestStoreDir notin searched
      check AbandonedReprobuildStoreDir notin searched
    # Structural half: the reader's signature takes no workspace at all.
    let source = readFile(currentSourcePath().parentDir / "certificate_store.nim")
    check "proc readCertificateStore*(access: CertificateStoreAccess;\n" &
          "                           local: LocalStoreQuery)" in source
    check "proc readWorkspaceCarriers" notin source

  test "records are ordered newest first, by arrival":
    ## "The last produced certificate, whatever produced it", across the
    ## content directories looked up and across both roots.
    let user = scratchDir("order-user")
    let system = scratchDir("order-system")
    writeCertificate(user, dirOf('a'), "w.toml",
                     sampleDocument(content = contentOf('a')))
    writeCertificate(system, dirOf('b'), "h.toml",
                     sampleDocument(content = contentOf('b')))
    let base = getTime()
    setLastModificationTime(user / dirOf('a') / "w.toml",
                            base - initDuration(minutes = 10))
    setLastModificationTime(system / dirOf('b') / "h.toml", base)
    var store = readFor(nativeStoreAccess(), rootsAt(user, system), ['a', 'b'])
    check store.present
    check store.certificates.len == 2
    check store.lastProduced.name == system & "/" & dirOf('b') & "/h.toml"
    # Flip the arrival order and the answer flips with it.
    setLastModificationTime(user / dirOf('a') / "w.toml",
                            base + initDuration(minutes = 10))
    store = readFor(nativeStoreAccess(), rootsAt(user, system), ['a', 'b'])
    check store.lastProduced.name == user & "/" & dirOf('a') & "/w.toml"

  test "arrival order beats the record's own issued_at":
    ## `issued_at` is informational and explicitly NOT a trust input
    ## (Verification.md §4.3): clock skew is ordinary. A store ordered by that
    ## field would let one misconfigured machine pin itself at the top.
    let user = scratchDir("skew-user")
    writeCertificate(user, dirOf('a'), "skewed.toml",
                     sampleDocument(content = contentOf('a'),
                                    issuedAt = "2099-01-01T00:00:00Z"))
    writeCertificate(user, dirOf('a'), "recent.toml",
                     sampleDocument(content = contentOf('a'), platform = "x/y",
                                    issuedAt = "2026-01-01T00:00:00Z"))
    let base = getTime()
    setLastModificationTime(user / dirOf('a') / "skewed.toml",
                            base - initDuration(hours = 1))
    setLastModificationTime(user / dirOf('a') / "recent.toml", base)
    let store = readFor(nativeStoreAccess(), rootsAt(user), ['a'])
    check store.lastProduced.name.endsWith("/recent.toml")

  test "records that arrived together are ordered by name, the greater first":
    ## SB-1's open mutation survivor: `compareArrival`'s name tiebreak was
    ## untested, and it is not decoration — `modifiedMs` answers 0 for
    ## "unknown", so on a host whose stat is unavailable EVERY pair ties and
    ## the whole order falls to the name. Pinned here at equal times, both
    ## through the pure rule and through a reader whose clock says nothing.
    var records = @[
      StoredCertificate(name: "/r/v1/a/b.toml", receivedAtMs: 0),
      StoredCertificate(name: "/r/v1/a/c.toml", receivedAtMs: 0),
      StoredCertificate(name: "/r/v1/a/a.toml", receivedAtMs: 0)]
    orderByArrival(records)
    check records.mapIt(it.name) ==
      @["/r/v1/a/c.toml", "/r/v1/a/b.toml", "/r/v1/a/a.toml"]
    # Arrival still wins over the name when the times differ.
    records[2].receivedAtMs = 5
    orderByArrival(records)
    check records[0].name == "/r/v1/a/a.toml"

    let user = scratchDir("tie-user")
    for name in ["m.toml", "z.toml", "a.toml"]:
      writeCertificate(user, dirOf('a'), name,
                       sampleDocument(content = contentOf('a'),
                                      platform = "os/" & name[0]))
    var access = nativeStoreAccess()
    access.modifiedMs = proc(path: string): int64 {.closure.} = 0
    let store = readFor(access, rootsAt(user), ['a'])
    check store.certificates.mapIt(it.name.extractFilename) ==
      @["z.toml", "m.toml", "a.toml"]

  test "a certificate that cannot be read makes the search incomplete, not empty":
    ## "There is nothing here" and "I could not look" are different answers.
    ## Made real with mode bits where this process is subject to them.
    let user = scratchDir("unreadable-file-user")
    writeCertificate(user, dirOf('a'), "run.toml",
                     sampleDocument(content = contentOf('a')))
    let path = user / dirOf('a') / "run.toml"
    setFilePermissions(path, {})
    var denied = false
    try:
      discard readFile(path)
    except IOError, OSError:
      denied = true
    var access = nativeStoreAccess()
    if not denied:
      # Root reads a 0000 file: assert the rule through the seam instead of
      # reporting green for an environment that never exercised it.
      checkpoint "this process can read a 0000 file (root?); asserting " &
                 "through the access seam"
      access.readText = proc(p: string): StoreRead {.closure.} =
        StoreRead(status: srUnreadable, detail: "permission denied")
    let store = readFor(access, rootsAt(user), ['a'])
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    check store.present
    check store.incomplete
    check not store.unreadable
    check store.incompleteReasons.len == 1
    check "could not be read" in store.incompleteReasons[0]
    check store.certificates.len == 0

  test "a content directory that cannot be listed is present and incomplete":
    ## Found by mutation testing (SB-1): `present` is a documented field of
    ## the report, and a consumer reading it alone must not be told there is
    ## nothing where there is something it could not open.
    let user = scratchDir("unlistable-user")
    createDir(user / dirOf('a'))
    var access = nativeStoreAccess()
    let inner = access.listFiles
    access.listFiles = proc(dir: string): StoreListing {.closure.} =
      if dir.endsWith(dirOf('a')):
        StoreListing(status: srUnreadable, detail: "permission denied")
      else:
        inner(dir)
    let store = readFor(access, rootsAt(user), ['a'])
    check store.present
    check store.incomplete
    check "could not be listed" in store.incompleteReasons.join(" ")
    check store.certificates.len == 0

  test "only .toml records are opened in a content directory":
    ## A private key or any other file that lands in a content directory is
    ## never read: the listing is an allow-list on `.toml` names that do not
    ## begin with `.` (Transport.md §2.4).
    let user = scratchDir("signing-key-user")
    writeCertificate(user, dirOf('a'), "run.toml",
                     sampleDocument(content = contentOf('a')))
    writeFile(user / dirOf('a') / "signing-key",
              "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n")
    var opened: seq[string] = @[]
    var access = nativeStoreAccess()
    let inner = access.readText
    access.readText = proc(p: string): StoreRead {.closure.} =
      opened.add p.extractFilename
      inner(p)
    let store = readFor(access, rootsAt(user), ['a'])
    check store.certificates.len == 1
    check opened == @["run.toml"]
    for stored in store.certificates:
      check "PRIVATE KEY" notin stored.text

suite "the local certificate store reader (Transport.md §2.4)":

  test "store directory names reject non-portable algorithm identifiers":
    for name in ["../x", "a/b", "a\\b", ".x", "x.", "CON", "con", "prn", "aux",
                 "nul", "com1", "com9", "lpt1", "lpt9", "nul.x", "a_b", "Upper",
                 "é", repeat('x', 65)]:
      let content = name & ":aa"
      checkpoint content
      let path = localStoreContentDir(content)
      check not path.ok
      check path.relative == ""
      check path.problem.len > 0
    for name in ["future-v2", "-", "0", "com0", "lpt0", "con-v2", repeat('x', 64)]:
      let path = localStoreContentDir(name & ":a")
      check path.ok
      check path.relative == "v1/" & name & "/a"


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
    let store = readCertificateStore(nativeStoreAccess(),
      LocalStoreQuery(roots: roots, contentIds: @[w]))
    check store.certificates.len == 3
    check store.rejected.len == 1
    check store.present

  test "a root that cannot be searched makes the search incomplete, and the other is still searched":
    ## Transport.md §2.1/§2.4: the two roots resolve and are searched
    ## independently. A root that is UNRESOLVED, or that exists and cannot be
    ## read, is reported as not covered — `incomplete`, with the reason —
    ## never as "searched and empty"; and a certificate in the OTHER root
    ## still counts. Symmetric: before this, an unreadable USER root stopped
    ## the search outright (the system root was never looked at) and an
    ## unresolved one did too.
    let w = "git-tree-sha1:" & "a".repeat(40)
    let wDir = "v1/git-tree-sha1/" & "a".repeat(40)
    let user = scratchDir("incomplete-user")
    let system = scratchDir("incomplete-system")
    writeCertificate(user, wDir, "u.toml", sampleDocument(content = w))
    writeCertificate(system, wDir, "s.toml",
                     sampleDocument(content = w, platform = "os/system"))
    let roots = CertificateStoreRoots(available: true, user: user,
                                      system: system)
    var access = nativeStoreAccess()
    let inner = access.listFiles
    proc blinding(prefix: string): proc(dir: string): StoreListing {.closure.} =
      # Seam, not mode bits: a root-run test reads a 0000 directory, and the
      # property is about what the reader DOES with the answer.
      result = proc(dir: string): StoreListing {.closure.} =
        if dir.startsWith(prefix):
          StoreListing(status: srUnreadable, detail: "permission denied")
        else:
          inner(dir)

    # Control: both roots readable — complete, both records found.
    let complete = lookupLocalStore(access, roots, w)
    check not complete.incomplete
    check complete.found.len == 2

    # The SYSTEM root unreadable: the user root's record still found.
    access.listFiles = blinding(system)
    var found = lookupLocalStore(access, roots, w)
    check not found.unreadable
    check found.incomplete
    check found.found.len == 1
    check found.found[0].name.startsWith(user)
    check "system root" in found.incompleteReasons.join(" ")

    # The USER root unreadable: the system root is STILL searched.
    access.listFiles = blinding(user)
    found = lookupLocalStore(access, roots, w)
    check not found.unreadable
    check found.incomplete
    check found.found.len == 1
    check found.found[0].name.startsWith(system)
    check "user root" in found.incompleteReasons.join(" ")
    let store = readCertificateStore(access,
      LocalStoreQuery(roots: roots, contentIds: @[w]))
    check store.incomplete
    check store.present
    check store.certificates.len == 1
    check "The certificate search was incomplete" in store.incompleteSummary

    # The USER root UNRESOLVED (no usable variable): reported with the
    # resolver's reason, and the system root still searched.
    access.listFiles = inner
    let unresolved = CertificateStoreRoots(available: true, user: "",
      system: system, problems: @["the user root cannot be resolved: " &
        "neither $TEST_CERTIFICATES_DIR, $XDG_STATE_HOME nor $HOME is an " &
        "absolute path"])
    found = lookupLocalStore(access, unresolved, w)
    check found.incomplete
    check found.found.len == 1
    check "user root could not be resolved" in found.incompleteReasons[0]
    check "$HOME" in found.incompleteReasons[0]
    check found.searched == @[system & "/" & wDir]

    # A host with no local store at all (a browser tab) could not look.
    let none = readCertificateStore(nativeStoreAccess(),
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
