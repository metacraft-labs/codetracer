## The GPUI footer's shipped host boundary over real git, real certificates,
## and the real native facts reader. The git wrapper only records which task
## spawned git and gates its first invocation: deterministic UI liveness needs
## a pending operation, which a small real repository cannot guarantee. Every
## invocation is forwarded unchanged to the real executable. No facts, VCS
## answers, certificate parsing or verification are mocked.
##
## The synchronous control is the original certificateLabel body extracted
## unchanged into host/certificate_indicator. It compiles with this suite and
## fails the caller-task and pending-answer assertions (rather than hanging:
## the wrapper deliberately does not gate a git spawned by the main task).

import std/[os, osproc, sequtils, streams, strutils, tempfiles, unittest]
import ../host/certificate_indicator
import ../../../ct_test/certificate
import ../../viewmodel/viewmodels/certificate_indicator_source
import ../../viewmodel/host/desktop_native

let scratch = createTempDir("gpui-cert-", "")
let realGit = findExe("git")
let oldPath = getEnv("PATH")
let oldStore = getEnv("TEST_CERTIFICATES_DIR")
let oldSystemStore = getEnv("TEST_CERTIFICATES_SYSTEM_DIR")
putEnv("TEST_CERTIFICATES_DIR", scratch / "store")
putEnv("TEST_CERTIFICATES_SYSTEM_DIR", scratch / "system-store")

proc git(dir: string; args: seq[string]): string =
  let p = startProcess(realGit, workingDir = dir, args = args,
                       options = {poStdErrToStdOut})
  result = p.outputStream.readAll().strip()
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, result

proc repository(name: string): string =
  result = scratch / name
  createDir(result)
  writeFile(result / "source.nim", "echo " & escape(name) & "\n")
  discard git(result, @["init", "--initial-branch=main"])
  discard git(result, @["add", "source.nim"])
  discard git(result, @["-c", "user.name=GPUI test", "-c",
    "user.email=gpui@example.invalid", "-c", "commit.gpgsign=false",
    "commit", "-m", "initial"])

let first = repository("first")
let second = repository("second")
let content = "git-tree-sha1:" & git(second, @["rev-parse", "HEAD^{tree}"])
let cert = TestCertificate(schema: CertificateSchema, framework: "ct-test",
  project: "second", platform: standardPlatformTriple(hostOS, hostCPU),
  targets: @["source.nim"], result: "passed", issuedAt: "2026-10-22T00:00:00Z",
  issuer: "ct-test", vcs: VcsState(repo: "second", content: content,
                                 paths: @["source.nim"]),
  commands: @[@["ct", "test", "run"]])
let certDir = scratch / "store" / localStoreContentDir(content).relative
createDir(certDir)
writeFile(certDir / "run.toml", renderCertificate(cert))
let expected = evaluateCertificateIndicator(platformCertificateFacts(
  newDesktopNativePlatform(), second, standardPlatformTriple(hostOS, hostCPU)))

createDir(scratch / "bin")
let wrapper = scratch / "bin/git"
let entered = scratch / "entered"
let released = scratch / "released"
let calls = scratch / "calls"
# Linux exposes the calling task's child list, so this proves which thread
# actually launched each real git, including lazy scoped-oracle evaluation.
writeFile(wrapper, "#!/bin/sh\n" &
  "task=unknown\n" &
  "for f in /proc/$PPID/task/*/children; do\n" &
  "  case \" $(cat \"$f\") \" in *\" $$ \"*) task=${f%/children}; task=${task##*/};; esac\n" &
  "done\n" &
  "echo \"$task $*\" >> " & quoteShell(calls) & "\n" &
  "if [ ! -e " & quoteShell(entered) & " ]; then\n" &
  "  touch " & quoteShell(entered) & "\n" &
  "  if [ \"$task\" != \"$PPID\" ]; then\n" &
  "    while [ ! -e " & quoteShell(released) & " ]; do sleep 0.01; done\n" &
  "  fi\nfi\nexec " & quoteShell(realGit) & " \"$@\"\n")
setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
putEnv("PATH", scratch / "bin" & PathSep & oldPath)

proc waitEntered() =
  while not fileExists(entered): sleep(1)

proc settle(host: NativeCertificateIndicator): int =
  while host.pending:
    if host.poll(): inc result
    sleep(1)

suite "GPUI certificate indicator never runs git on its caller's thread":
  test "a blocked git leaves the caller free and no partial answer is published":
    let host = newNativeCertificateIndicator()
    try:
      check expected.state == cisCertified
      host.request(first)
      waitEntered()
      check host.pending
      check not fileExists(released)
      check host.model.summary == "Not looked yet."
      check not host.poll()
      check host.model.summary == "Not looked yet."
      # A new folder supersedes the answer in flight. The old folder must
      # never appear as a completed answer while the new one is pending.
      host.request(second)
      check host.model.summary == "Not looked yet."
      writeFile(released, "continue")
      var published = 0
      while host.pending:
        if host.poll():
          inc published
          check host.model == expected
        sleep(1)
      check published == 1
      check host.model == expected
      let log = readFile(calls).strip().splitLines()
      echo "git caller tasks: ", log.mapIt(it.splitWhitespace()[0]).deduplicate(),
           "; UI task: ", getCurrentProcessId(), "; calls: ", log.len
      check log.len > 3
      check log.anyIt(it.contains("write-tree"))
      check log.anyIt(it.contains("--literal-pathspecs") and
                         it.contains("source.nim"))
      when defined(linux):
        # /proc's task-to-child relation is Linux's extra direct evidence;
        # the gated request/poll assertions above exercise liveness everywhere.
        for line in log:
          check not line.startsWith($getCurrentProcessId() & " ")
          check not line.startsWith("unknown ")
      # A later refresh retains the previous complete answer until done.
      removeFile(entered)
      removeFile(released)
      host.request(first)
      waitEntered()
      check host.model == expected
      check not host.poll()
      writeFile(released, "continue")
      check host.settle() == 1
      check host.model.state == cisNoCertificates
      check host.model.summary != "Not looked yet."
      host.request(first)
      check not host.pending
      host.close()
      host.close()
      host.request(second)
      check not host.pending
    finally:
      writeFile(released, "continue")
      host.close()

putEnv("PATH", oldPath)
putEnv("TEST_CERTIFICATES_DIR", oldStore)
putEnv("TEST_CERTIFICATES_SYSTEM_DIR", oldSystemStore)
removeDir(scratch)
