## The conformance-vector walker for the test-certificate standard.
##
## ``test-certificates-spec/vectors/`` is **plain data with no runner** — that
## is deliberate, so that nothing in the standard's repository has to be
## invoked, imported, ported or trusted in order to claim conformance
## (``vectors/README.md``). This file is CodeTracer's own thin walker over it.
##
## It walks all three groups:
##
## * ``payload/`` — serialize ``fields.json`` and compare byte for byte with
##   ``canonical.txt``. Plus the one optional ``received.toml``, a deliberately
##   non-canonical rendering of the same values that MUST parse to the same
##   payload (Canonical-Payload.md §5).
## * ``signature/`` — **verify**, never reproduce. Conformance.md §2 sets that
##   direction: SSH signature framing is an implementation's own business,
##   while verification is what interoperability actually needs. Three of the
##   six vectors MUST fail, and one of them (``wrong-namespace``) is a genuine
##   signature by the right key over exactly these bytes, made under the
##   namespace OpenSSH uses for commit signing.
## * ``verify/`` — the three-valued outcome, plus which certificates were
##   ignored / rejected / unevaluated. Those three fates are the ones an
##   implementation confuses, so their classification is normative even though
##   the wording is not.
##
## ``index.json`` is cross-checked against what was walked: a case that has
## silently gone missing is a case that stops testing anything.
##
## The vectors are a sibling repository. When it is absent this suite **fails
## loudly** rather than skipping — a missing required sibling that quietly
## turns a suite green is the failure mode
## ``codetracer-specs/Working-with-the-CodeTracer-Repos.md`` Part 2 exists to
## forbid. Point ``CT_TEST_CERTIFICATE_VECTORS`` at the ``vectors`` directory
## for layouts where the relative sibling does not resolve.

import std/[algorithm, json, options, os, sets, strutils, unittest]

import certificate
import certificate_verification

const RelativeVectorsPath = "test-certificates-spec/vectors"

proc vectorsRoot(): string =
  ## Locate ``vectors/``: the environment override first, then the sibling
  ## checkout relative to this source file.
  let override = getEnv("CT_TEST_CERTIFICATE_VECTORS")
  if override.len > 0:
    return override
  # src/ct_test/<this file> -> src/ct_test -> src -> repo root -> workspace
  let workspaceRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  workspaceRoot / RelativeVectorsPath

proc sortedCaseDirs(group: string): seq[string] =
  ## Every case directory in a group, by name. Directory names are case ids and
  ## are stable; a rename is a new case.
  ##
  ## A case is identified by its ``pins.md``, because "every case directory
  ## carries a ``pins.md``" is the directory contract and a group may hold
  ## directories that are not cases — ``signature/keys/`` holds the published
  ## signing keys. Walking by that marker also satisfies the contract's other
  ## instruction, to ignore what you do not recognise: a walker that fails on
  ## a new optional entry is a walker that cannot be updated.
  result = @[]
  if not dirExists(group):
    return
  for kind, path in walkDir(group):
    if kind == pcDir and fileExists(path / "pins.md"):
      result.add path.lastPathPart
  result.sort()

proc sortedFiles(dir: string): seq[string] =
  result = @[]
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile:
      result.add path.lastPathPart
  result.sort()

proc strSeq(node: JsonNode; key: string): seq[string] =
  ## Read a string array. Guarded on ``hasKey`` on purpose: ``node{key}``
  ## returns ``nil`` for a missing key, and iterating ``nil`` is a segfault
  ## that takes the whole binary — and every later case — down with it.
  result = @[]
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return
  let child = node[key]
  if child.kind != JArray:
    return
  for item in child.items:
    if item.kind == JString:
      result.add item.getStr

proc str(node: JsonNode; key: string): string =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return ""
  let child = node[key]
  if child.kind == JString: child.getStr else: ""

proc boolean(node: JsonNode; key: string): bool =
  if node == nil or node.kind != JObject or not node.hasKey(key):
    return false
  let child = node[key]
  child.kind == JBool and child.getBool

proc certificateFromFields(fields: JsonNode): TestCertificate =
  ## Build a record from a vector's ``fields.json``.
  ##
  ## The values there are **inputs, not canonical output**: ``targets`` and
  ## ``paths`` arrive in whatever order the producer observed them and may
  ## contain duplicates, and ``key_id`` / ``paths`` / ``worktree`` are absent
  ## when they do not apply. Sorting, deduplication and omission are the
  ## serializer's job, not this reader's.
  let certificate = if fields.hasKey("certificate"): fields["certificate"] else: nil
  result = TestCertificate(
    schema: fields.str("schema"),
    framework: certificate.str("framework"),
    project: certificate.str("project"),
    platform: certificate.str("platform"),
    targets: certificate.strSeq("targets"),
    result: certificate.str("result"),
    issuedAt: certificate.str("issued_at"),
    issuer: certificate.str("issuer"),
    keyId: certificate.str("key_id"))

  let vcs = if certificate != nil and certificate.hasKey("vcs"): certificate["vcs"] else: nil
  result.vcs = VcsState(
    repo: vcs.str("repo"),
    commit: vcs.str("commit"),
    paths: vcs.strSeq("paths"),
    clean: vcs.boolean("clean"),
    untracked: vcs.boolean("untracked"),
    worktree: none(WorktreeClaim))
  if vcs != nil and vcs.hasKey("worktree"):
    let worktree = vcs["worktree"]
    result.vcs.worktree = some(WorktreeClaim(
      tree: worktree.str("tree"),
      format: worktree.str("format"),
      patchDigest: worktree.str("patch_digest")))

  if certificate != nil and certificate.hasKey("command"):
    let commands = certificate["command"]
    if commands.kind == JArray:
      for entry in commands.items:
        result.commands.add entry.strSeq("argv")

proc describeBytes(value: string): string =
  ## Render a payload with its line structure visible, so a one-byte
  ## disagreement is legible in the failure output rather than being a wall of
  ## identical-looking text.
  result = ""
  for line in value.split('\n'):
    result.add "  |" & line & "|\n"

suite "test-certificate conformance vectors":
  let root = vectorsRoot()

  test "the conformance vectors are present":
    ## A missing sibling fails here, once, loudly — rather than turning every
    ## case below into a silent pass.
    check dirExists(root)
    if not dirExists(root):
      echo "the test-certificate conformance vectors were not found at: ", root
      echo "clone the `test-certificates-spec` sibling repository, or point ",
           "CT_TEST_CERTIFICATE_VECTORS at its `vectors` directory"

  test "index.json lists exactly the cases on disk":
    ## A case that has silently gone missing is a case that stops testing
    ## anything (``vectors/README.md``).
    require fileExists(root / "index.json")
    let index = parseJson(readFile(root / "index.json"))
    require index.hasKey("groups")
    let groups = index["groups"]
    for group in ["payload", "signature", "verify"]:
      var listed: seq[string] = @[]
      if groups.hasKey(group):
        for entry in groups[group].items:
          listed.add entry.str("name")
      listed.sort()
      let onDisk = sortedCaseDirs(root / group)
      checkpoint "group: " & group
      check listed == onDisk

  test "payload vectors serialize byte-for-byte":
    let group = root / "payload"
    let cases = sortedCaseDirs(group)
    check cases.len > 0
    echo "    walking ", cases.len, " payload cases: ", cases.join(", ")
    for name in cases:
      let dir = group / name
      if not fileExists(dir / "fields.json") or not fileExists(dir / "canonical.txt"):
        checkpoint "payload/" & name & ": missing fields.json or canonical.txt"
        check false
        continue
      let expected = readFile(dir / "canonical.txt")
      var produced = ""
      try:
        produced = canonicalPayload(certificateFromFields(
          parseJson(readFile(dir / "fields.json"))))
      except CatchableError as err:
        checkpoint "payload/" & name & ": serialization raised " & err.msg
        check false
        continue
      if produced != expected:
        checkpoint "payload/" & name & " diverged"
        checkpoint "expected:\n" & describeBytes(expected)
        checkpoint "produced:\n" & describeBytes(produced)
        checkpoint "see " & (dir / "pins.md") & " for the rule this case pins"
      check produced == expected

  test "a non-canonical rendering parses to the canonical payload":
    ## ``payload/escapes/received.toml`` uses CRLF, aligned ``=``, tables and
    ## keys in a different order, a TOML literal string, ``\uXXXX`` escapes and
    ## an empty signature block. Parsing it MUST produce exactly
    ## ``canonical.txt``: a verifier reconstructs the payload from the parsed
    ## **fields**, never by slicing the received file, or a cosmetically
    ## reformatted certificate would fail against its own valid signature
    ## (Canonical-Payload.md §5).
    let dir = root / "payload" / "escapes"
    require fileExists(dir / "received.toml")
    let read = readCertificate(readFile(dir / "received.toml"))
    checkpoint "read status: " & $read.status & " " & read.detail
    check read.status == crsOk
    if read.status == crsOk:
      check canonicalPayload(read.cert) == readFile(dir / "canonical.txt")

  test "signature vectors verify, or fail, exactly as expected":
    let group = root / "signature"
    let cases = sortedCaseDirs(group)
    check cases.len > 0
    echo "    walking ", cases.len, " signature cases: ", cases.join(", ")
    for name in cases:
      let dir = group / name
      if not fileExists(dir / "expect.txt"):
        continue        # `signature/keys/` is documentation, not a case
      let
        payload = readFile(dir / "canonical.txt")
        publicKey = readFile(dir / "key.pub").strip()
        signature = readFile(dir / "signature.b64").strip()
        expected = readFile(dir / "expect.txt").strip()
      let outcome = verifyDetachedSignature(payload, publicKey, signature)
      checkpoint "signature/" & name & ": expected " & expected &
                 ", got " & $outcome.check & " (" & outcome.detail & ")"
      # `scUndecidable` is never an acceptable answer here: every input is
      # present and well-formed, so it would mean ssh-keygen could not be run.
      check outcome.check != scUndecidable
      if expected == "verify":
        check outcome.check == scValid
      else:
        check outcome.check == scInvalid

  test "verification vectors produce the expected three-valued outcome":
    let group = root / "verify"
    let cases = sortedCaseDirs(group)
    check cases.len > 0
    echo "    walking ", cases.len, " verification cases: ", cases.join(", ")
    for name in cases:
      let dir = group / name
      if not fileExists(dir / "expected.json"):
        checkpoint "verify/" & name & ": no expected.json"
        check false
        continue
      let
        stateJson = parseJson(readFile(dir / "state.json"))
        requirementJson = parseJson(readFile(dir / "requirement.json"))
        expected = parseJson(readFile(dir / "expected.json"))

      let state = EvaluatedState(
        repo: stateJson.str("repo"),
        commit: stateJson.str("commit"),
        tree: stateJson.str("tree"))

      var requirement = Requirement(
        frameworksImplemented: requirementJson.strSeq("frameworks_implemented"),
        framework: requirementJson.str("framework"),
        targets: requirementJson.strSeq("targets"),
        platforms: requirementJson.strSeq("platforms"),
        requireSignature: requirementJson.boolean("require_signature"),
        paths: @[],
        pathsGiven: false)
      # `paths: null` means the whole repository, which is a *stronger* demand
      # than any scoped certificate satisfies — so null and [] are not the same
      # requirement and must not be conflated.
      if requirementJson.hasKey("paths") and requirementJson["paths"].kind == JArray:
        requirement.paths = requirementJson.strSeq("paths")
        requirement.pathsGiven = true

      var candidates: seq[CandidateCertificate] = @[]
      for fileName in sortedFiles(dir / "certificates"):
        candidates.add CandidateCertificate(
          name: fileName, text: readFile(dir / "certificates" / fileName))

      var store = KeyStore(readable: true)
      if fileExists(dir / "registered-keys.toml"):
        store = readKeyStore(readFile(dir / "registered-keys.toml"))

      let report = verifyCertificates(state, requirement, candidates, store)

      checkpoint "verify/" & name & ": expected " & expected.str("outcome") &
                 ", got " & $report.outcome & " — " & report.reason
      checkpoint "see " & (dir / "pins.md") & " for the rule this case pins"
      check $report.outcome == expected.str("outcome")

      # `missing` is normative in content: a consumer must report which target,
      # on which platform, for which framework — not a bare pass/fail.
      var producedGaps: seq[string] = @[]
      for gap in report.missing:
        producedGaps.add gap.framework & "|" & gap.platform & "|" &
                          gap.targets.join(",")
      producedGaps.sort()
      var expectedGaps: seq[string] = @[]
      if expected.hasKey("missing") and expected["missing"].kind == JArray:
        for gap in expected["missing"].items:
          var targets = gap.strSeq("targets")
          targets.sort()
          expectedGaps.add gap.str("framework") & "|" & gap.str("platform") &
                            "|" & targets.join(",")
      expectedGaps.sort()
      check producedGaps == expectedGaps

      # The three fates are normative in *which* certificates they name.
      proc namesOf(notes: seq[CertificateNote]): seq[string] =
        result = @[]
        for note in notes:
          result.add note.certificate
        result.sort()
      proc expectedNames(key: string): seq[string] =
        result = @[]
        if expected.hasKey(key) and expected[key].kind == JArray:
          for entry in expected[key].items:
            result.add entry.str("certificate")
        result.sort()
      check namesOf(report.ignored) == expectedNames("ignored")
      check namesOf(report.rejected) == expectedNames("rejected")
      check namesOf(report.unevaluated) == expectedNames("unevaluated")
