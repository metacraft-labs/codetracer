## SB-1 — the certificate indicator against a real repository and a real host.
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

import std/[algorithm, options, os, osproc, streams, strutils, unittest]

import viewmodels/certificate_indicator_source
import viewmodel/host/desktop_native
import viewmodel/platform/platform

import ../../../../ct_test/certificate

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
  discard git(result, ["init", "--initial-branch=main", "."])
  discard git(result, ["config", "user.email", "sb1@example.invalid"])
  discard git(result, ["config", "user.name", "sb1 suite"])
  discard git(result, ["config", "commit.gpgsign", "false"])
  discard git(result, ["add", "-A"])
  discard git(result, ["commit", "-m", "initial"])

proc headCommit(repo: string): string =
  git(repo, ["rev-parse", "HEAD"]).strip()

proc writeCertificateFor(repo, commit: string; name = "run.toml";
                         dir = CtTestStoreDir; issuer = "ct-test") =
  ## A real certificate file, in the real store directory, produced by the
  ## shipped canonical serializer.
  let cert = TestCertificate(
    schema: CertificateSchema,
    framework: "ct-test",
    project: repo.lastPathPart,
    platform: Platform,
    targets: @["calc_test.nim"],
    result: "passed",
    issuedAt: "2026-08-18T09:00:00Z",
    issuer: issuer,
    vcs: VcsState(repo: repo.lastPathPart, commit: commit, paths: @[],
                  clean: true, untracked: false, worktree: none(WorktreeClaim)),
    commands: @[@["ct", "test", "run"]])
  createDir(repo / dir)
  writeFile(repo / dir / name, renderCertificate(cert))

proc indicatorFor(repo: string): CertificateIndicatorVm =
  newCertificateIndicatorVm(
    platformCertificateFactsReader(platform(), repo, Platform))

suite "SB-1: the indicator against a real repository":

  setup:
    # The shipped native instantiation, not a fake. `resetPlatformForTesting`
    # first so the suite cannot pass on a platform some earlier file installed.
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

  test "a certificate for the real HEAD, on a clean tree, reads certified":
    ## The positive control, end to end: real git reports the commit, the real
    ## filesystem holds the record, and the shipped verifier decides.
    let repo = newRepository("certified")
    writeCertificateFor(repo, headCommit(repo))
    let vm = indicatorFor(repo)
    discard vm.refresh(citStartup)
    checkpoint $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisCertified
    check vm.model.authenticity == caNotChecked
    check vm.model.authenticityNote == NoKeysRegisteredNote

  test "the indicator refreshes when a real commit changes the facts":
    ## The refresh deliverable, against facts that really moved. Each step
    ## below changes the world with a real git operation or a real file write
    ## and then asks the SAME ViewModel again.
    let repo = newRepository("refresh")
    let first = headCommit(repo)
    writeCertificateFor(repo, first)

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
    check vm.model.state == cisWasCertified
    check vm.revision == certifiedAt + 1

    # (2) A CHECKOUT back to the certified commit. The indicator must recover,
    # or it is not reading the facts at all — it is remembering a verdict.
    discard git(repo, ["checkout", "--detach", first])
    check vm.refresh(citCommitChanged)
    checkpoint "after checkout: " & $vm.model.state
    check vm.model.state == cisCertified

    # (3) AN EDIT, with HEAD standing still. A `clean = true` certificate's
    # tested state IS its commit (Verification.md §4.1); a modified tracked
    # file is that commit plus the edit, which the record does not describe.
    writeFile(repo / "calc.nim", "proc add(a, b: int): int = a + b + 0\n")
    check vm.refresh(citWorktreeChanged)
    checkpoint "after edit: " & $vm.model.state & " — " & vm.model.summary
    check vm.model.state == cisWasCertified
    check headCommit(repo) == first     # HEAD really did not move

    # (4) REVERTING the edit brings it back, so (3) was about the edit and not
    # about the ViewModel latching.
    discard git(repo, ["checkout", "--", "calc.nim"])
    check vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified

    # (5) AN UNTRACKED FILE IS NOT AN EDIT. `vcs.clean` is about tracked files
    # differing from the commit; untracked files get their own field precisely
    # because they usually mean scratch work (Standard.md §3.2). An indicator
    # that went stale on every build directory would be ignored within a day.
    writeFile(repo / "scratch.log", "noise\n")
    discard vm.refresh(citWorktreeChanged)
    check vm.model.state == cisCertified

  test "a certificate written by a hook reads the same as one written by an agent":
    ## Producer-agnosticism against the real carriers: one record in
    ## reprobuild's store directory, one in `ct test`'s, differing in issuer and
    ## in which directory holds them. Only the record's own name may differ.
    let repo = newRepository("producers")
    let commit = headCommit(repo)
    writeCertificateFor(repo, commit, name = "hook.toml",
                        dir = ReprobuildStoreDir, issuer = "repro-hook")
    let hookVm = indicatorFor(repo)
    discard hookVm.refresh(citStartup)
    let hook = hookVm.model
    check hook.certificateName == ReprobuildStoreDir & "/hook.toml"

    removeDir(repo / ReprobuildStoreDir)
    writeCertificateFor(repo, commit, name = "agent.toml",
                        dir = CtTestStoreDir, issuer = "ct-test-agent")
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

  test "a directory that is not a repository is unverifiable, not uncertified":
    ## The consumer could not establish the commit, so it must not behave as
    ## though it had. Reporting "not certified" would send an operator to run
    ## tests over a VCS problem.
    let dir = scratchDir("not-a-repo")
    createDir(dir / CtTestStoreDir)
    writeFile(dir / CtTestStoreDir / "run.toml",
      renderCertificate(TestCertificate(
        schema: CertificateSchema, framework: "ct-test", project: "x",
        platform: Platform, targets: @["t"], result: "passed",
        issuedAt: "2026-08-18T09:00:00Z", issuer: "ct-test",
        vcs: VcsState(repo: "x", commit: "a".repeat(40), paths: @[],
                      clean: true, untracked: false,
                      worktree: none(WorktreeClaim)),
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
    writeCertificateFor(repo, headCommit(repo))

    proc snapshot(): seq[string] =
      result = @[]
      for kind, path in walkDir(repo / CtTestStoreDir):
        result.add $kind & " " & path.lastPathPart & " " &
                   $getFileSize(path)
      result.sort()

    let before = snapshot()
    let statusBefore = git(repo, ["status", "--porcelain=v1"])

    let vm = indicatorFor(repo)
    for i in 0 .. 4:
      discard vm.refresh(citManualRefresh)
    check vm.model.state == cisCertified

    check snapshot() == before
    check git(repo, ["status", "--porcelain=v1"]) == statusBefore
