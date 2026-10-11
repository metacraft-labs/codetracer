## SB-1 and SB-2b — the certificate indicator against a real repository and a
## real host.
##
## NO MOCKS AT ALL. The platform is the shipped native instantiation
## (`host/desktop_native.newDesktopNativePlatform`), the repository is a real
## git repository in a temporary directory, the certificates are real files
## written by the shipped `renderCertificate`, and the whole chain the product
## runs — `platformCertificateFactsReader` → `readCertificateStore` over the
## `FileSystemFacade` → `workspaceVcsState` over the `VcsFacade` → the shipped
## `verifyCertificates` — is what produces every verdict below.
##
## ## Why this is a separate file from `certificate_indicator_vm_test.nim`
##
## That suite runs on BOTH Nim backends, so it cannot touch `std/os`,
## `std/osproc` or a real host. This one needs all three, and therefore runs on
## the native backend only — it is subtracted from the `vm-js` lane in
## `ci/lib/test-lane-files.sh` with that reason recorded there. The split is
## the same one `welcome_screen_recent_folders_test.nim` was carved out for,
## and for the same reason: the alternative is a `when defined(js)` guard that
## leaves a suite reporting green having asserted nothing.
##
## ## What only this file can prove
##
## That the refresh triggers fire against facts that really moved. The headless
## suite moves a struct; this one runs `git commit`, edits a tracked file and
## checks out another branch, and asserts the indicator followed. A ViewModel
## that reads a cached snapshot passes the first and fails this.
##
## ## Where the records are (2026-10-10, CTC-3e)
##
## `ct test` publishes to the per-user local certificate store, and the
## indicator reads it by the content ids of W, H and S (both roots), through
## `fs.certificateStoreRoots` — which on this host follows
## `TEST_CERTIFICATES_DIR`, pointed at a fresh scratch root for every case.
## `.ct/certificates` is read by nothing ("the indicator reads the local
## store, not .ct/certificates"). Records that are about the ViewModel's
## decision over OTHER content (a `base` that is HEAD on unrelated content,
## an algorithm the host cannot compute) sit in reprobuild's workspace
## carrier, which is still pooled and lists every record whatever its
## content; a lookup by content would never reach them.

import std/[algorithm, options, os, osproc, streams, strtabs, strutils, times,
            unittest]

import viewmodels/certificate_indicator_source
import viewmodel/host/desktop_native
import viewmodel/platform/platform

import ../../../../ct_test/certificate
import ../../../../ct_test/certificate_store_roots_native

const
  Platform = "linux/amd64"
    ## The certificates written below claim this, and the facts are built with
    ## the same string, so the suite is about the VCS binding rather than about
    ## whichever machine runs it. The platform mismatch has its own case in the
    ## headless suite.

proc scratchDir(name: string): string =
  ## Under `getTempDir()`, which honours `TMPDIR` — deliberately, because this
  ## suite creates a git repository and must be able to do so outside any other
  ## repository and off a quota-bounded filesystem.
  result = getTempDir() / "ct-cert-indicator" / name & "-" &
           $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc git(dir: string; args: openArray[string]): string =
  var p = startProcess("git", workingDir = dir, args = @args,
                       options = {poUsePath, poStdErrToStdOut})
  result = p.outputStream.readAll()
  discard p.waitForExit()
  p.close()

proc newRepository(name: string): string =
  result = scratchDir(name)
  writeFile(result / "calc.nim", "proc add(a, b: int): int = a + b\n")
  # The certificate store is workspace-local state, not source, and a real
  # project ignores it. Without this the first `git add -A` below would COMMIT
  # the certificate, and a later `git checkout` of an earlier commit would then
  # delete the store — which is a fact about the fixture and not about the
  # indicator. It cost this case a red before it was understood, so it is
  # written down rather than left as a line that looks like housekeeping.
  writeFile(result / ".gitignore", ".ct/\n.repro/\n")
  # (`.ct/` stays ignored here because one case plants a CTC-2 record there.)
  discard git(result, ["init", "--initial-branch=main", "."])
  discard git(result, ["config", "user.email", "sb1@example.invalid"])
  discard git(result, ["config", "user.name", "sb1 suite"])
  discard git(result, ["config", "commit.gpgsign", "false"])
  discard git(result, ["add", "-A"])
  discard git(result, ["commit", "-m", "initial"])

proc headCommit(repo: string): string =
  git(repo, ["rev-parse", "HEAD"]).strip()

proc headContent(repo: string): string =
  ## The content id a commit of this repository records: its tree, in the
  ## repository's (SHA-1) object format.
  "git-tree-sha1:" & git(repo, ["rev-parse", "HEAD^{tree}"]).strip()

const UnrelatedBase = "cc11223344556677889900aabbccddeeff001122"
  ## A `base` naming no commit of these repositories. Informational only, so
  ## it must change nothing.

const LocalStore = "<local store>"
  ## `dir` value meaning "the local certificate store, under the record's
  ## content", where `ct test` publishes.

var storeCounter = 0

proc freshStoreRoot(): string =
  ## A new, empty local store for one case, through the variable the host's
  ## resolver reads (Transport.md §2.1).
  inc storeCounter
  result = getTempDir() / "ct-cert-indicator" / "stores-" &
           $getCurrentProcessId() / $storeCounter
  removeDir(result)
  putEnv("TEST_CERTIFICATES_DIR", result)
  putEnv("TEST_CERTIFICATES_SYSTEM_DIR", result & "-system")

proc writeCertificateFor(repo, content: string; base = UnrelatedBase;
                         name = "run.toml"; dir = LocalStore;
                         issuer = "ct-test") =
  ## A real certificate file, produced by the shipped canonical serializer,
  ## in the local store under its content's directory (where `ct test`
  ## publishes) or in the named workspace directory.
  let cert = TestCertificate(
    schema: CertificateSchema,
    framework: "ct-test",
    project: repo.lastPathPart,
    platform: Platform,
    targets: @["calc_test.nim"],
    result: "passed",
    issuedAt: "2026-08-18T09:00:00Z",
    issuer: issuer,
    vcs: VcsState(repo: repo.lastPathPart, paths: @[], content: content,
                  untracked: false, base: base),
    commands: @[@["ct", "test", "run"]])
  let target =
    if dir == LocalStore:
      getEnv("TEST_CERTIFICATES_DIR") /
        localStoreContentDir(content).relative.replace('/', DirSep)
    else:
      repo / dir
  createDir(target)
  writeFile(target / name, renderCertificate(cert))

proc gitWithIndex(dir, indexFile: string; args: openArray[string]): string =
  ## git with ``GIT_INDEX_FILE`` pointed at a copy, so computing a tree here
  ## never touches the repository's own index.
  var env = newStringTable()
  for key, value in envPairs():
    env[key] = value
  env["GIT_INDEX_FILE"] = indexFile
  var p = startProcess("git", workingDir = dir, args = @args, env = env,
                       options = {poUsePath, poStdErrToStdOut})
  result = p.outputStream.readAll()
  discard p.waitForExit()
  p.close()

proc treeOfIndexCopy(repo: string; addTracked: bool): string =
  ## A content id computed INDEPENDENTLY of the facade, with plain git: S is
  ## `write-tree` over a copy of the index (no stat data is involved), and W
  ## is S's tree read into a FRESH index — whose entries carry no stat data,
  ## so git must read every tracked file's content — with every tracked
  ## change added (`git add -u`; untracked files are outside the content).
  ## Not `add -u` over a copy of the index: that trusts the copy's stat data,
  ## which is the defect CTC-3b fixed in the product (a same-size edit in the
  ## second of the last index write read as clean), and an oracle with the
  ## product's old defect would agree with it.
  let dir = getTempDir() / "ct-cert-indicator"
  let copy = dir / "index-copy-" & $getCurrentProcessId()
  let fresh = dir / "index-fresh-" & $getCurrentProcessId()
  copyFile(repo / ".git" / "index", copy)
  let staged = gitWithIndex(repo, copy, ["write-tree"]).strip()
  removeFile(copy)
  if not addTracked:
    return "git-tree-sha1:" & staged
  discard gitWithIndex(repo, fresh, ["read-tree", staged])
  discard gitWithIndex(repo, fresh, ["add", "-u"])
  result = "git-tree-sha1:" & gitWithIndex(repo, fresh, ["write-tree"]).strip()
  removeFile(fresh)

proc workingTreeContent(repo: string): string = treeOfIndexCopy(repo, true)
proc stagedContent(repo: string): string = treeOfIndexCopy(repo, false)

proc writeRecord(repo, content: string; platform = Platform;
                 name = "run.toml") =
  ## A record in the local store under its content's directory, for an
  ## arbitrary platform.
  let cert = TestCertificate(
    schema: CertificateSchema, framework: "ct-test",
    project: repo.lastPathPart, platform: platform,
    targets: @["calc_test.nim"], result: "passed",
    issuedAt: "2026-10-10T09:00:00Z", issuer: "ct-test",
    vcs: VcsState(repo: repo.lastPathPart, paths: @[], content: content,
                  untracked: false, base: UnrelatedBase),
    commands: @[@["ct", "test", "run"]])
  let target = getEnv("TEST_CERTIFICATES_DIR") /
    localStoreContentDir(content).relative.replace('/', DirSep)
  createDir(target)
  writeFile(target / name, renderCertificate(cert))

proc storeSnapshot(): seq[string] =
  result = @[]
  let root = getEnv("TEST_CERTIFICATES_DIR")
  if dirExists(root):
    for path in walkDirRec(root):
      result.add path & " " & readFile(path)
  result.sort()

proc indicatorFor(repo: string): CertificateIndicatorVm =
  newCertificateIndicatorVm(
    platformCertificateFactsReader(platform(), repo, Platform))

suite "SB-1: the indicator against a real repository":

  setup:
    # The shipped native instantiation, not a fake. `resetPlatformForTesting`
    # first so the suite cannot pass on a platform some earlier file installed.
    discard freshStoreRoot()
    resetPlatformForTesting()
    installPlatform(newDesktopNativePlatform())

  teardown:
    resetPlatformForTesting()

  test "a real workspace with no store reads \"no certificates\", not an error":
    ## The ordinary state of every project that does not use certificates, and
    ## the one a status bar meets most often. It must be silent and honest, not
    ## a failure (Transport.md §4).
    let repo = newRepository("no-store")
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint vm.model.summary
    check vm.model.state == cisNoCertificates
    check vm.model.label == NoCertificatesLabel

  test "a revised record whose base is another commit reads certified when its content is W":
    ## The positive control, end to end: the real host computes W through the
    ## facade (a temporary index, real git), the real filesystem holds the
    ## record, and the shipped verifier decides — by content. The record's
    ## `base` names a commit that is not HEAD (not even in this repository),
    ## so an indicator comparing `base` anywhere on its path reads it as stale.
    let repo = newRepository("certified")
    writeCertificateFor(repo, headContent(repo), base = UnrelatedBase)
    check UnrelatedBase != headCommit(repo)
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisCertified
    check vm.model.authenticity == caNotChecked
    check vm.model.authenticityNote == NoKeysRegisteredNote

    # THE MIRROR: a record whose base IS HEAD and whose content is not W does
    # not read certified. Together the two kill a comparison of `base` in
    # either direction.
    let other = newRepository("same-base-other-content")
    # Its own store: content ids do not depend on the repository, and this
    # repository's content is the one above's, whose record is in that store.
    discard freshStoreRoot()
    writeCertificateFor(other,
      "git-tree-sha1:" & repeat('d', 40), base = headCommit(other),
      dir = ReprobuildStoreDir)
    let otherVm = indicatorFor(other)
    discard otherVm.refresh(citStartup)
    checkpoint $otherVm.model.state & " — " & otherVm.model.summary
    check otherVm.model.state != cisCertified
    # SB-2b: the record is for content that is neither W, H nor S, so it is
    # not "found" for this tree — and nothing was looked up in another
    # content's directory.
    check otherVm.model.state == cisNoCertificates

  test "a content id the host cannot compute reads unverifiable":
    ## `git-tree-sha256` against this SHA-1 repository: the real host answers
    ## "cannot compute", which is not a mismatch (Verification.md §4.1.1).
    let repo = newRepository("sha256-on-sha1")
    writeCertificateFor(repo, "git-tree-sha256:" & repeat('a', 64),
                        dir = ReprobuildStoreDir)
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisUnverifiable
    check vm.model.remedy == FixConfigurationRemedy

  test "a working tree with no content id reads unverifiable, even with HEAD certified":
    ## An assume-unchanged entry hides an edit from `git status`; Content-Id.md
    ## §3 says such a tree has no content id. A record for HEAD's content must
    ## not read certified on the strength of a guess, and the control (the
    ## flag cleared) shows the edit, then the revert, decided by content.
    let repo = newRepository("assume-unchanged")
    writeCertificateFor(repo, headContent(repo))
    discard git(repo, ["update-index", "--assume-unchanged", "calc.nim"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a + b + 1\n")
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisUnverifiable
    check "assume-unchanged" in vm.model.summary
    check "calc.nim" in vm.model.summary
    check "even though HEAD's content is certified" in vm.model.summary
    check "git update-index --no-assume-unchanged -- calc.nim" in
          vm.model.remedy
    discard git(repo, ["update-index", "--no-assume-unchanged", "calc.nim"])
    discard vm.refresh(citWorktreeChanged)
    check vm.model.state == cisWasCertified
    check vm.model.label == WasCertifiedLabel
    discard git(repo, ["checkout", "--", "calc.nim"])
    discard vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified

  test "the indicator refreshes when a real commit changes the facts":
    ## The refresh deliverable, against facts that really moved. Each step
    ## below changes the world with a real git operation or a real file write
    ## and then asks the SAME ViewModel again.
    let repo = newRepository("refresh")
    let first = headCommit(repo)
    writeCertificateFor(repo, headContent(repo), base = first)

    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    check vm.model.state == cisCertified
    let certifiedAt = vm.revision

    # (1) A COMMIT. The tree moved on; the last green run no longer covers it.
    writeFile(repo / "calc.nim",
              "proc add(a, b: int): int = a + b\nproc sub(a, b: int): int = a - b\n")
    discard git(repo, ["add", "-A"])
    discard git(repo, ["commit", "-m", "add sub"])
    let second = headCommit(repo)
    check second != first
    check vm.refresh(citCommitChanged)
    checkpoint "after commit: " & $vm.model.state & " — " & vm.model.summary
    # 2026-10-10 (CTC-3e): was `cisWasCertified`. The record for the old
    # content is in the old content's directory, and the indicator looks up
    # only W's, H's and S's (CTC-3 operator decision 10: "neither W nor H
    # covered" reads not certified; with nothing found there, "No
    # certificates").
    check vm.model.state == cisNoCertificates
    check vm.revision == certifiedAt + 1

    # (2) A CHECKOUT back to the certified commit. The indicator must recover,
    # or it is not reading the facts at all — it is remembering a verdict.
    discard git(repo, ["checkout", "--detach", first])
    check vm.refresh(citCommitChanged)
    checkpoint "after checkout: " & $vm.model.state
    check vm.model.state == cisCertified

    # (3) AN EDIT, with HEAD standing still. The record names the content it
    # tested (Verification.md §4.1.1); a modified tracked file changes W, which
    # the record does not describe.
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a + b + 0\n")
    check vm.refresh(citWorktreeChanged)
    checkpoint "after edit: " & $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisWasCertified
    check vm.model.label == "Changed since certified"
    check headCommit(repo) == first     # HEAD really did not move

    # (4) REVERTING the edit brings it back, so (3) was about the edit and not
    # about the ViewModel latching.
    discard git(repo, ["checkout", "--", "calc.nim"])
    check vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified

    # (5) AN UNTRACKED FILE IS NOT AN EDIT. Untracked files are outside the
    # content (Standard.md §3.2) — they get their own field precisely because
    # they usually mean scratch work. An indicator that went stale on every
    # build directory would be ignored within a day.
    writeFile(repo / "scratch.log", "noise\n")
    discard vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified

  test "a certificate written by a hook reads the same as one written by an agent":
    ## Producer-agnosticism against the real carriers: one record in
    ## reprobuild's store directory, one in `ct test`'s, differing in issuer and
    ## in which directory holds them. Only the record's own name may differ.
    let repo = newRepository("producers")
    let content = headContent(repo)
    writeCertificateFor(repo, content, name = "hook.toml",
                        dir = ReprobuildStoreDir, issuer = "repro-hook")
    let hookVm = indicatorFor(repo)
    discard hookVm.refresh(citStartup)
    let hook = hookVm.model
    check hook.certificateName == ReprobuildStoreDir & "/hook.toml"

    removeDir(repo / ReprobuildStoreDir)
    writeCertificateFor(repo, content, name = "agent.toml",
                        dir = LocalStore, issuer = "ct-test-agent")
    let agentVm = indicatorFor(repo)
    discard agentVm.refresh(citStartup)
    let agent = agentVm.model

    checkpoint "hook = " & $hook.state & "; agent = " & $agent.state
    check hook.state == cisCertified
    check agent.state == hook.state
    check agent.label == hook.label
    check agent.summary == hook.summary
    check agent.remedy == hook.remedy
    check agent.authenticityNote == hook.authenticityNote
    for i in 0 ..< min(hook.detail.len, agent.detail.len):
      if hook.detail[i].label in ["Record", "Issuer"]:
        continue
      checkpoint "row: " & hook.detail[i].label
      check agent.detail[i] == hook.detail[i]

  test "the indicator reads the local store, not .ct/certificates":
    ## CTC-3e. A CTC-2 record in `.ct/certificates` that would cover W is not
    ## read at all; the same claim in the local store, where `ct test` now
    ## publishes, is — found through the host's own root resolution
    ## (`TEST_CERTIFICATES_DIR`), in W's content directory.
    let repo = newRepository("local-not-dot-ct")
    let content = headContent(repo)
    writeCertificateFor(repo, content, dir = AbandonedCtTestStoreDir)
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisNoCertificates
    for dir in vm.model.searched:
      check AbandonedCtTestStoreDir notin dir

    writeCertificateFor(repo, content, dir = LocalStore)
    discard vm.refresh(citStoreChanged)
    checkpoint $vm.model.state & " — " & vm.model.certificateName
    check vm.model.state == cisCertified
    check vm.model.certificateName.startsWith(getEnv("TEST_CERTIFICATES_DIR"))
    check ("/v1/git-tree-sha1/" & content["git-tree-sha1:".len .. ^1] & "/") in
          vm.model.certificateName

    # The SYSTEM root is read too (Transport.md §2.4): the same record there
    # alone also covers.
    let systemRoot = getEnv("TEST_CERTIFICATES_SYSTEM_DIR") / nativeStoreAccount()
    let relative = localStoreContentDir(content).relative
    createDir(systemRoot / relative)
    moveFile(getEnv("TEST_CERTIFICATES_DIR") / relative / "run.toml",
             systemRoot / relative / "run.toml")
    discard vm.refresh(citStoreChanged)
    check vm.model.state == cisCertified
    check vm.model.certificateName.startsWith(systemRoot)

  test "a directory that is not a repository is unverifiable, not uncertified":
    ## The consumer could not establish the repository, so it must not behave
    ## as though it had. Reporting "not certified" would send an operator to run
    ## tests over a VCS problem.
    let dir = scratchDir("not-a-repo")
    createDir(dir / ReprobuildStoreDir)
    writeFile(dir / ReprobuildStoreDir / "run.toml",
      renderCertificate(TestCertificate(
        schema: CertificateSchema, framework: "ct-test", project: "x",
        platform: Platform, targets: @["t"], result: "passed",
        issuedAt: "2026-08-18T09:00:00Z", issuer: "ct-test",
        vcs: VcsState(repo: "x", paths: @[],
                      content: "git-tree-sha1:" & "a".repeat(40),
                      untracked: false),
        commands: @[@["ct", "test", "run"]])))
    let vm = indicatorFor(dir)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisUnverifiable
    check vm.model.remedy == FixConfigurationRemedy

  test "reading the store writes nothing into the workspace":
    ## SB-1: read-only. Asserted as an observation of the real tree rather than
    ## as a claim about the code — the store directory's contents, and the
    ## repository's own cleanliness, are identical before and after a refresh.
    let repo = newRepository("read-only")
    writeCertificateFor(repo, headContent(repo))

    proc snapshot(): seq[string] =
      result = @[]
      for path in walkDirRec(getEnv("TEST_CERTIFICATES_DIR"),
                             yieldFilter = {pcFile, pcDir}):
        result.add path & " " & $getLastModificationTime(path).toUnix
      for path in walkDirRec(repo):
        result.add path
      result.sort()

    let before = snapshot()
    check before.len > 0
    let statusBefore = git(repo, ["status", "--porcelain=v1"])

    let vm = indicatorFor(repo)
    for i in 0 .. 4:
      discard vm.refresh(citManualRefresh)
    check vm.model.state == cisCertified

    check snapshot() == before
    check git(repo, ["status", "--porcelain=v1"]) == statusBefore

# EVERY EDIT IN THIS SUITE KEEPS THE FILE'S SIZE, and most land in the same
# second as the index write that recorded the file: the realistic edit, and
# the one git's stat check cannot see. Before CTC-3b's fix (2026-10-10) the
# product's W recipe trusted stat data in a COPY of the index and missed such
# an edit about one run in three here; these edits are the regression test
# for that in the shipped native host.
suite "SB-2b: the indicator decides on W, H and S in a real repository":

  setup:
    discard freshStoreRoot()
    resetPlatformForTesting()
    installPlatform(newDesktopNativePlatform())

  teardown:
    resetPlatformForTesting()

  test "a tested, uncommitted tree reads certified, uncommitted":
    ## Edit, certify the working tree, no commit. Then stage only half of the
    ## change — the tooltip warns that `git commit` without `-a` would not be
    ## covered — then all of it, then `git commit`: "Certified", with the
    ## store unchanged and no record written in between.
    let repo = newRepository("uncommitted")
    writeFile(repo / "notes.txt", "notes\n")
    discard git(repo, ["add", "-A"])
    discard git(repo, ["commit", "-m", "notes"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = b + a\n")
    writeFile(repo / "notes.txt", "NOTES\n")
    let tested = workingTreeContent(repo)
    check tested != headContent(repo)
    writeRecord(repo, tested)

    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint vm.model.label & " — " & vm.model.summary
    check vm.model.state == cisCertified
    check vm.model.label == CertifiedUncommittedLabel
    check StagedDiffersWarning in vm.model.summary
    check vm.model.summary.startsWith(UncommittedCertifiedSummary)

    discard git(repo, ["add", "calc.nim"])
    check stagedContent(repo) != tested
    discard vm.refresh(gitDirTrigger(repo / ".git" / "index"))
    check vm.lastTrigger == citIndexChanged
    check vm.model.label == CertifiedUncommittedLabel
    check vm.model.summary == UncommittedCertifiedSummary & " " &
                              StagedDiffersWarning

    discard git(repo, ["add", "notes.txt"])
    check stagedContent(repo) == tested
    check vm.refresh(citIndexChanged)
    check vm.model.summary == UncommittedCertifiedSummary

    let storeBefore = storeSnapshot()
    discard git(repo, ["commit", "-m", "tested change"])
    check headContent(repo) == tested
    check vm.refresh(gitDirTrigger(repo / ".git" / "HEAD"))
    check vm.lastTrigger == citCommitChanged
    checkpoint vm.model.label & " — " & vm.model.summary
    check vm.model.state == cisCertified
    check vm.model.label == CertifiedLabel
    check vm.model.summary == CommittedCertifiedSummary
    check storeSnapshot() == storeBefore

  test "an untracked file does not change the state":
    ## Untracked files are outside W (Standard.md §3.2), in every state.
    let repo = newRepository("untracked")
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = b + a\n")
    writeRecord(repo, workingTreeContent(repo))
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    let before = vm.model
    check before.label == CertifiedUncommittedLabel
    writeFile(repo / "scratch.log", "noise\n")
    createDir(repo / "build")
    writeFile(repo / "build" / "out.o", "object\n")
    check not vm.refresh(citWorktreeChanged)
    check vm.model.label == before.label
    check vm.model.summary == before.summary

  test "a tree that moved on past its last green run reads not certified":
    ## Certify HEAD, then commit a content change: neither W nor H is
    ## covered while a valid record for the old content sits in the store.
    let repo = newRepository("moved-on")
    writeRecord(repo, headContent(repo))
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    check vm.model.label == CertifiedLabel

    writeFile(repo / "calc.nim", "proc add(a, b: int): int = b + a\n")
    discard vm.refresh(citWorktreeChanged)
    # The control: an edit with HEAD still certified.
    check vm.model.label == WasCertifiedLabel

    discard git(repo, ["commit", "-a", "-m", "moved on"])
    discard vm.refresh(citCommitChanged)
    checkpoint vm.model.label & " — " & vm.model.summary
    check vm.model.state == cisNoCertificates
    check vm.model.label == NoCertificatesLabel
    check vm.model.state != cisWasCertified

    # A record for this platform's neighbour, in W's own directory: found,
    # and none matched.
    writeRecord(repo, headContent(repo), platform = "macos/arm64",
                name = "macos.toml")
    discard vm.refresh(citStoreChanged)
    checkpoint vm.model.label & " — " & vm.model.summary
    check vm.model.state == cisNotCertified
    check vm.model.label == NotCertifiedLabel

  test "an unmerged merge is unverifiable, even with HEAD certified":
    let repo = newRepository("unmerged")
    discard git(repo, ["checkout", "-q", "-b", "side"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a - b\n")
    discard git(repo, ["commit", "-q", "-a", "-m", "side"])
    discard git(repo, ["checkout", "-q", "main"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a * b\n")
    discard git(repo, ["commit", "-q", "-a", "-m", "main"])
    writeRecord(repo, headContent(repo))
    discard git(repo, ["merge", "side"])
    check "UU calc.nim" in git(repo, ["status", "--porcelain=v1"])
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint vm.model.summary & " / " & vm.model.remedy
    check vm.model.state == cisUnverifiable
    check vm.model.state != cisCertified
    check "unmerged" in vm.model.summary
    check "calc.nim" in vm.model.summary
    check "even though HEAD's content is certified" in vm.model.summary
    check "Resolve the merge" in vm.model.remedy
    # THE CONTROL: the condition cleared, the same repository reads by its
    # content.
    discard git(repo, ["merge", "--abort"])
    discard vm.refresh(citCommitChanged)
    check vm.model.state == cisCertified
    check vm.model.label == CertifiedLabel

  test "a submodule with modified content is unverifiable, even with HEAD certified":
    let sub = newRepository("submodule-inner")
    let repo = newRepository("submodule-outer")
    discard git(repo, ["-c", "protocol.file.allow=always", "submodule", "add",
                       "-q", sub, "inner"])
    discard git(repo, ["commit", "-q", "-m", "add submodule"])
    writeRecord(repo, headContent(repo))
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    check vm.model.label == CertifiedLabel
    writeFile(repo / "inner" / "calc.nim", "proc add(a, b: int): int = b - a\n")
    discard vm.refresh(citWorktreeChanged)
    checkpoint vm.model.summary & " / " & vm.model.remedy
    check vm.model.state == cisUnverifiable
    check "nested repository has modified content" in vm.model.summary
    check "inner" in vm.model.remedy
    check "submodule" in vm.model.remedy
    discard git(repo / "inner", ["checkout", "--", "calc.nim"])
    discard vm.refresh(citWorktreeChanged)
    check vm.model.label == CertifiedLabel

  test "computing W leaves the index and the working tree untouched":
    ## With a partially staged file present, the index file's bytes and `git
    ## status` are identical after five refreshes. New loose objects in
    ## `.git/objects` are expected (that is how git computes a tree id) and
    ## are not asserted against.
    let repo = newRepository("index-untouched")
    writeFile(repo / "notes.txt", "notes\n")
    discard git(repo, ["add", "-A"])
    discard git(repo, ["commit", "-q", "-m", "notes"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = b + a\n")
    writeFile(repo / "notes.txt", "NOTES\n")
    discard git(repo, ["add", "calc.nim"])
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a * b\n")
    writeRecord(repo, workingTreeContent(repo))
    # `git status` BEFORE the bytes are taken: it refreshes the index it
    # reads and writes it back, and with calc.nim edited (same size) in the
    # second the index was written, that write smudges the racily clean
    # entry's recorded size (https://git-scm.com/docs/racy-git). That is
    # git's doing, not the facade's, so it must happen before the baseline.
    let statusBefore = git(repo, ["status", "--porcelain=v1"])
    check "MM calc.nim" in statusBefore
    let indexBefore = readFile(repo / ".git" / "index")
    let vm = indicatorFor(repo)
    for i in 0 .. 4:
      discard vm.refresh(citManualRefresh)
    check vm.model.label == CertifiedUncommittedLabel
    check readFile(repo / ".git" / "index") == indexBefore
    check git(repo, ["status", "--porcelain=v1"]) == statusBefore
