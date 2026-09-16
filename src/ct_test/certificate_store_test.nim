## The workspace certificate store, against a real filesystem.
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

import std/[options, os, strutils, times, unittest]

import certificate
import certificate_store

proc scratchDir(name: string): string =
  result = getTempDir() / "ct-cert-store" / name & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc sampleDocument(commit = "a" .repeat(40); platform = "linux/amd64";
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
    vcs: VcsState(repo: repo, commit: commit, paths: @[], clean: true,
                  untracked: false, worktree: none(WorktreeClaim)),
    commands: @[@["ct", "test", "run"]]))

proc writeCertificate(root, dir, name, text: string) =
  createDir(root / dir)
  writeFile(root / dir / name, text)

suite "the workspace certificate store, on a real filesystem":

  test "a workspace with no store is not an error and not a store":
    ## Transport.md §4: an absent certificate store is a normal state for a
    ## project that does not use certificates and MUST NOT be an error in
    ## itself. The `searched` list is what makes the report actionable.
    let root = scratchDir("absent")
    let store = readCertificateStore(nativeStoreAccess(), root)
    check not store.present
    check not store.unreadable
    check store.certificates.len == 0
    check store.searched.len == 2
    check ReprobuildStoreDir in store.searched
    check CtTestStoreDir in store.searched
    check not store.hasKeyStore

  test "a store directory that exists and is empty is present and empty":
    ## The distinction Transport.md §4 asks for in as many words: "no
    ## certificates found" and "certificates found but none matched" are
    ## different outcomes. This is the first, with the store genuinely there.
    let root = scratchDir("empty")
    createDir(root / CtTestStoreDir)
    let store = readCertificateStore(nativeStoreAccess(), root)
    check store.present
    check not store.unreadable
    check store.certificates.len == 0

  test "certificates are found in both carriers and ordered newest first":
    ## "The last produced certificate, whatever produced it." The two store
    ## directories are pooled — a hook writing into reprobuild's location and
    ## an agent writing into `ct test`'s must be ranked together, or which one
    ## speaks would depend on which tool happened to run.
    let root = scratchDir("both")
    writeCertificate(root, ReprobuildStoreDir, "hook.toml", sampleDocument())
    writeCertificate(root, CtTestStoreDir, "agent.toml",
                     sampleDocument(commit = "b".repeat(40)))

    # Real mtimes, set explicitly so the ordering assertion is about the rule
    # and not about how fast this machine writes two files.
    let base = getTime()
    setLastModificationTime(root / ReprobuildStoreDir / "hook.toml",
                            base - initDuration(minutes = 10))
    setLastModificationTime(root / CtTestStoreDir / "agent.toml", base)

    var store = readCertificateStore(nativeStoreAccess(), root)
    check store.present
    check store.certificates.len == 2
    check store.lastProduced.name == CtTestStoreDir & "/agent.toml"

    # Flip the arrival order and the answer flips with it. Without this the
    # case above would pass for an implementation that simply preferred
    # `.ct/certificates`.
    setLastModificationTime(root / ReprobuildStoreDir / "hook.toml",
                            base + initDuration(minutes = 10))
    store = readCertificateStore(nativeStoreAccess(), root)
    check store.lastProduced.name == ReprobuildStoreDir & "/hook.toml"

  test "arrival order beats the record's own issued_at":
    ## `issued_at` is informational and explicitly NOT a trust input
    ## (Verification.md §4.3): clock skew is ordinary, and a consumer MUST NOT
    ## reject a certificate solely because its timestamp is in the future. A
    ## store ordered by that field would let one misconfigured machine pin
    ## itself permanently at the top of the list.
    let root = scratchDir("skew")
    writeCertificate(root, CtTestStoreDir, "skewed.toml",
                     sampleDocument(issuedAt = "2099-01-01T00:00:00Z"))
    writeCertificate(root, CtTestStoreDir, "recent.toml",
                     sampleDocument(commit = "c".repeat(40),
                                    issuedAt = "2026-01-01T00:00:00Z"))
    let base = getTime()
    setLastModificationTime(root / CtTestStoreDir / "skewed.toml",
                            base - initDuration(hours = 1))
    setLastModificationTime(root / CtTestStoreDir / "recent.toml", base)

    let store = readCertificateStore(nativeStoreAccess(), root)
    check store.lastProduced.name == CtTestStoreDir & "/recent.toml"

  test "a certificate that cannot be read makes the store unreadable, not empty":
    ## "There is nothing here" and "I could not look" are different answers,
    ## and only the second is a configuration fault. Made real with mode bits
    ## rather than simulated.
    let root = scratchDir("unreadable")
    writeCertificate(root, CtTestStoreDir, "run.toml", sampleDocument())
    let path = root / CtTestStoreDir / "run.toml"
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
      let store = readCertificateStore(nativeStoreAccess(), root)
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
      let store = readCertificateStore(access, root)
      check store.present
      check store.unreadable
      check "could not be read" in store.unreadableReason

  test "the key store is read, and an unreadable one is not an empty one":
    ## Verification.md §3.1's most easily-lost distinction, at the store layer:
    ## an empty store ANSWERS — nobody is trusted — while one that cannot be
    ## read answers nothing.
    let root = scratchDir("keys")
    writeCertificate(root, CtTestStoreDir, "run.toml", sampleDocument())
    writeFile(root / CtTestStoreDir / RegisteredKeysFile, """
schema = "registered-keys.v1"

[[key]]
key_id = "k1"
public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
status = "active"
""")
    var store = readCertificateStore(nativeStoreAccess(), root)
    check store.hasKeyStore
    check store.keyStore.readable
    check store.keyStore.keys.len == 1
    # The key store is not a certificate, and must not be listed as one.
    check store.certificates.len == 1

    writeFile(root / CtTestStoreDir / RegisteredKeysFile, "not { toml at all")
    store = readCertificateStore(nativeStoreAccess(), root)
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
    createDir(root / CtTestStoreDir)
    var access = nativeStoreAccess()
    access.listFiles = proc(dir: string): StoreListing {.closure.} =
      if dir.endsWith(CtTestStoreDir):
        StoreListing(status: srUnreadable, detail: "permission denied")
      else:
        StoreListing(status: srAbsent)
    let store = readCertificateStore(access, root)
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
    writeCertificate(root, CtTestStoreDir, "run.toml", sampleDocument())
    writeFile(root / CtTestStoreDir / SigningKeyFile,
              "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n")
    let store = readCertificateStore(nativeStoreAccess(), root)
    check store.certificates.len == 1
    for stored in store.certificates:
      check "PRIVATE KEY" notin stored.text
      check stored.name.endsWith(".toml")

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
    check imports.len == 4
    check "std/strutils" in imports
    check "../../../ct_test/certificate" in imports
    check "../../../ct_test/certificate_store" in imports
    check "../../../ct_test/certificate_verification" in imports
