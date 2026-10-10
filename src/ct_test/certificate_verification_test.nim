## The verifier's own suite: matching by content (Verification.md §4.1.1).
##
## The conformance walker (``certificate_vectors_test.nim``) proves the
## verifier against the standard's ``verify/`` vectors, whose state is a list
## of precomputed content ids. This file pins the rules those vectors leave to
## prose, each with the control that makes it mean something:
##
## * a certificate is matched by its CONTENT, computed in the certificate's own
##   algorithm over the certificate's own scope — and ``base`` is never
##   compared with anything, in either direction;
## * an earlier-draft record (``commit`` + ``clean``, no ``content``) is
##   decidably invalid, names its remedy, and is never translated into the
##   current shape — not even when the commit's tree, or its ``worktree.tree``,
##   is exactly the content under evaluation;
## * an algorithm the consumer cannot compute for the state is unevaluated
##   (unverifiable, subject to §7.1's relevance rule), while a malformed
##   content id is rejected and never repaired.
##
## NO MOCKS of the subject: every certificate is a real document from the
## shipped serializer (or hand-written TOML, for the shapes the serializer can
## no longer produce), read by the shipped reader and decided by the shipped
## ``verifyCertificates``. The content oracle is a table of ids, which is what
## a content oracle IS — the computation behind it is
## ``certificate_content_id_test.nim``'s subject.

import std/[strutils, unittest]

import certificate
import certificate_verification

const
  Repo = "example"
  Platform = "linux/amd64"
  HeadCommit = "a858633c1f4d7bb4b7c2e2b6a1c0d9e8f7a6b5c4"
    ## The commit the user is on. Informational: nothing may compare it.
  OtherCommit = "cc11223344556677889900aabbccddeeff001122"
  WDigest = "9f8e7d6c5b4a3928170695e4d3c2b1a099887766"
  W = "git-tree-sha1:" & WDigest
    ## The content id of the state under evaluation.
  ScopedW = "git-tree-sha1:3c1f5e0a9b8d7c6e5f4a3b2c1d0e9f8a7b6c5d4e"
  OtherContent = "git-tree-sha1:1122334455667788990011223344556677889900"

type
  Asked = ref object
    ## Every (algorithm, scope) the verifier asked the oracle for.
    calls: seq[string]

proc sha1Oracle(asked: Asked): ContentOracle =
  ## A SHA-1 repository's state: `git-tree-sha1` over the whole repository is
  ## W, over `src/db` it is ScopedW; every other algorithm — `git-tree-sha256`
  ## in particular — cannot be computed here.
  result = proc(algorithm: string; paths: seq[string]): ContentAnswer
      {.closure.} =
    asked.calls.add algorithm & " " & paths.join(",")
    if algorithm != "git-tree-sha1":
      return ContentAnswer(computed: false,
        reason: algorithm & " cannot be computed in a SHA-1 repository")
    if paths.len == 0:
      return ContentAnswer(computed: true, id: W)
    if paths == @["src/db"]:
      return ContentAnswer(computed: true, id: ScopedW)
    ContentAnswer(computed: false, reason: "no id for that scope")

proc stateFor(asked: Asked): EvaluatedState =
  EvaluatedState(repo: Repo, content: sha1Oracle(asked))

proc record(content: string; base = ""; platform = Platform;
            targets = @["t-unit"]; paths: seq[string] = @[]): TestCertificate =
  TestCertificate(
    schema: CertificateSchema, framework: "ct-test", project: Repo,
    platform: platform, targets: targets, result: "passed",
    issuedAt: "2026-06-23T10:14:33Z", issuer: "ct-test@host",
    vcs: VcsState(repo: Repo, paths: paths, content: content,
                  untracked: false, base: base),
    commands: @[@["ct", "test", "run"]])

proc candidate(name: string; cert: TestCertificate): CandidateCertificate =
  CandidateCertificate(name: name, text: renderCertificate(cert))

proc requirement(targets = @["t-unit"]; paths: seq[string] = @[];
                 pathsGiven = false): Requirement =
  Requirement(frameworksImplemented: @["ct-test"], framework: "ct-test",
              targets: targets, platforms: @[Platform],
              requireSignature: false, paths: paths, pathsGiven: pathsGiven)

proc names(notes: seq[CertificateNote]): seq[string] =
  for note in notes:
    result.add note.certificate

proc earlierDraft(commit: string; clean = true; worktreeTree = ""): string =
  ## A record in the shape `ct test` issued before the 2026-10-09 revision.
  ## Hand-written: the serializer can no longer produce it, which is part of
  ## the point.
  result = "schema = \"test-certificate.v1\"\n\n[certificate]\n" &
    "framework = \"ct-test\"\nproject = \"" & Repo & "\"\n" &
    "platform = \"" & Platform & "\"\ntargets = [\"t-unit\"]\n" &
    "result = \"passed\"\nissued_at = \"2026-06-23T10:14:33Z\"\n" &
    "issuer = \"ct-test@host\"\n\n[certificate.vcs]\nrepo = \"" & Repo &
    "\"\ncommit = \"" & commit & "\"\nclean = " & $clean &
    "\nuntracked = false\n"
  if worktreeTree.len > 0:
    result.add "\n[certificate.vcs.worktree]\ntree = \"" & worktreeTree & "\"\n"
  result.add "\n[[certificate.command]]\nargv = [\"ct\", \"test\", \"run\"]\n"

suite "the verifier matches by content":

  test "the verifier matches by content and never by base":
    ## Verification.md §4.1.1: "Comparing `base`, or any commit id, to the
    ## state under evaluation is therefore always wrong."
    let asked = Asked()
    let state = stateFor(asked)

    # A record issued on top of ANOTHER commit covers this state when its
    # content is the state's content.
    let otherBase = verifyCertificates(state, requirement(),
      [candidate("other-base.toml", record(W, base = OtherCommit))], KeyStore())
    checkpoint $otherBase.outcome & " — " & otherBase.reason
    check otherBase.outcome == ocCovered
    check otherBase.rejected.len == 0

    # A record whose base IS the commit under evaluation does not, when its
    # content differs: base does not rescue it, and the rejection names the
    # content, not the commit.
    let sameBase = verifyCertificates(state, requirement(),
      [candidate("same-base.toml", record(OtherContent, base = HeadCommit))],
      KeyStore())
    checkpoint $sameBase.outcome & " — " & sameBase.reason
    check sameBase.outcome == ocNotCovered
    check sameBase.rejected.names == @["same-base.toml"]
    check "vcs.content" in sameBase.rejected[0].why
    check sameBase.missing.len == 1

    # With no base at all the verdicts are the same: base is not an input.
    check verifyCertificates(state, requirement(),
      [candidate("no-base.toml", record(W))], KeyStore()).outcome == ocCovered
    check verifyCertificates(state, requirement(),
      [candidate("no-base.toml", record(OtherContent))],
      KeyStore()).outcome == ocNotCovered

    # The id is computed in the CERTIFICATE'S algorithm over the
    # CERTIFICATE'S scope — and the state carries no commit to compare.
    check asked.calls.len > 0
    for call in asked.calls:
      check call == "git-tree-sha1 "
    check not compiles(EvaluatedState(commit: HeadCommit))

  test "a scoped record is matched against the content of its own scope":
    ## The scope is the certificate's, sorted and deduplicated, and the
    ## whole-repository id is NOT what a scoped record is compared with.
    let asked = Asked()
    let state = stateFor(asked)
    let scoped = verifyCertificates(state,
      requirement(paths = @["src/db/query.c"], pathsGiven = true),
      [candidate("scoped.toml",
                 record(ScopedW, paths = @["src/db", "src/db"]))], KeyStore())
    checkpoint $scoped.outcome & " — " & scoped.reason
    check scoped.outcome == ocCovered
    check asked.calls == @["git-tree-sha1 src/db"]

    # The whole-repository id in a scoped record does not match.
    let wrongScope = verifyCertificates(state,
      requirement(paths = @["src/db/query.c"], pathsGiven = true),
      [candidate("scoped.toml", record(W, paths = @["src/db"]))], KeyStore())
    check wrongScope.outcome == ocNotCovered
    check wrongScope.rejected.names == @["scoped.toml"]

  test "an earlier-draft record is invalid and is not translated":
    ## Canonical-Payload.md §7.1. Bound to a commit, carrying no content: the
    ## state's content would match a translation of it — the commit IS the
    ## one under evaluation, and its tree IS W — so a verifier that filled
    ## `content` from the commit (or from `worktree.tree`) would cover it.
    let asked = Asked()
    let state = stateFor(asked)
    for (name, text) in [
        ("clean.toml", earlierDraft(HeadCommit)),
        ("dirty.toml", earlierDraft(HeadCommit, clean = false,
                                    worktreeTree = WDigest)),
        ("dirty-prefixed.toml", earlierDraft(HeadCommit, clean = false,
                                             worktreeTree = W))]:
      let report = verifyCertificates(state, requirement(),
        [CandidateCertificate(name: name, text: text)], KeyStore())
      checkpoint name & ": " & $report.outcome & " — " & report.reason
      # Decidably invalid: rejected, never unverifiable, never covered.
      check report.outcome == ocNotCovered
      check report.unevaluated.len == 0
      check report.rejected.names == @[name]
      check report.rejected.len == 1 and
            "earlier-draft" in report.rejected[0].why and
            "re-issue" in report.rejected[0].why
      # And it never reached the content check: nothing was computed for it.
      check asked.calls.len == 0

      # No path produces a content field from a commit.
      let read = readCertificate(text)
      check read.status == crsMalformed
      check read.earlierDraft
      check read.cert.vcs.content.len == 0

    # The same claim in the CURRENT shape covers the state: the rejection
    # above is about the shape, not the claim.
    check verifyCertificates(state, requirement(),
      [candidate("reissued.toml", record(W, base = HeadCommit))],
      KeyStore()).outcome == ocCovered

  test "an uncomputable algorithm is unverifiable; a malformed content id is invalid":
    ## Verification.md §4.1.1 and §7.1.
    let asked = Asked()
    let state = stateFor(asked)

    # git-tree-sha256 against a SHA-1 state, and an algorithm the standard
    # does not define: not a mismatch. Unevaluated, and — being relevant to
    # the gap — the outcome is unverifiable.
    for content in ["git-tree-sha256:" & repeat('a', 64),
                    "blake3-manifest-v1:" & repeat('b', 64)]:
      let report = verifyCertificates(state, requirement(),
        [candidate("uncomputable.toml", record(content))], KeyStore())
      checkpoint content & ": " & $report.outcome & " — " & report.reason
      check report.outcome == ocUnverifiable
      check report.unevaluated.names == @["uncomputable.toml"]
      check report.rejected.len == 0
    # The undefined algorithm was never handed to the oracle; sha256 was.
    check asked.calls == @["git-tree-sha256 "]

    # §7.1: an interpretable record that could not be evaluated is decisive
    # only if it could have satisfied part of the requirement. Off-platform,
    # it is named and does not decide.
    let offPlatform = verifyCertificates(state, requirement(),
      [candidate("off-platform.toml",
                 record("git-tree-sha256:" & repeat('a', 64),
                        platform = "macos/arm64"))], KeyStore())
    checkpoint $offPlatform.outcome & " — " & offPlatform.reason
    check offPlatform.outcome == ocNotCovered
    check offPlatform.unevaluated.names == @["off-platform.toml"]
    # And covered still wins over an unevaluated neighbour (§7.1 rule 1).
    let coveredAnyway = verifyCertificates(state, requirement(),
      [candidate("uncomputable.toml",
                 record("git-tree-sha256:" & repeat('a', 64))),
       candidate("w.toml", record(W))], KeyStore())
    check coveredAnyway.outcome == ocCovered
    check coveredAnyway.unevaluated.names == @["uncomputable.toml"]

    # A consumer that can compute nothing for the state (no oracle at all)
    # has not established a mismatch either.
    let blind = verifyCertificates(EvaluatedState(repo: Repo), requirement(),
      [candidate("w.toml", record(W))], KeyStore())
    check blind.outcome == ocUnverifiable
    check blind.unevaluated.names == @["w.toml"]

    # Malformed: decidably invalid, rejected — and NOT repaired, even though
    # each is one keystroke from W (the oracle would match the repair).
    let malformedAsked = Asked()
    let malformedState = stateFor(malformedAsked)
    for (name, content) in [
        ("uppercase.toml", "git-tree-sha1:" & WDigest.toUpperAscii),
        ("short.toml", "git-tree-sha1:" & WDigest[0 ..< 12]),
        ("no-algorithm.toml", WDigest),
        ("second-colon.toml", "git-tree-sha1:sha1:" & WDigest),
        ("sha1-length-in-sha256.toml", "git-tree-sha256:" & WDigest)]:
      let report = verifyCertificates(malformedState, requirement(),
        [candidate(name, record(content))], KeyStore())
      checkpoint name & ": " & $report.outcome & " — " & report.reason
      check report.outcome == ocNotCovered
      check report.rejected.names == @[name]
      check report.unevaluated.len == 0
      check report.rejected.len == 1 and
            "malformed content id" in report.rejected[0].why
    check malformedAsked.calls.len == 0
