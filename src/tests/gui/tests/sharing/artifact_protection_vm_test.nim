## AS-3 — what a protection claims, what the dialog says, and the envelope's
## wire format.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-3, designed
## in `codetracer-specs/Sharing/Artifact-Store.md` §10.
##
## AS-3's four verification items, and the share of each that is answered here
## — the rest is answered over real HTTP in
## `src/ct/online_sharing/artifact_store_roundtrip_test.nim` and against the
## real primitives in `src/ct/online_sharing/artifact_crypto_test.nim`:
##
## 1. **an encrypted artifact is unreadable without the key** — the frame
##    format and its refusals are here; the cryptography is in the crypto
##    suite.
## 2. **the service never receives the key** — asserted here as a property of
##    the *design* (`everyProtectionKeepsTheSecretLocal`, and that no envelope
##    header field carries the password or the content key), and on the socket
##    in the round-trip suite.
## 3. **the flow is identical across kinds** — answered here in full, and it is
##    the item this file exists for.  The prompt is a function of
##    `(protection, noun)`, and the test asserts that swapping the noun is the
##    *only* difference between any two kinds' prompts.  A kind cannot acquire
##    its own password flow because there is nowhere to put one.
## 4. **what metadata remains visible is exactly what is documented** — the
##    list is here and is exhaustive per kind; the round-trip suite compares it
##    against the JSON keys that actually cross the socket, which is the half
##    that can catch documentation drifting away from the wire.
##
## Headless on both Nim backends.  That is deliberate and not incidental: every
## sentence a user reads about what encryption does and does not do lives in
## `artifact_protection.nim`, which is pure, so the *claims* can be asserted
## without a socket, a file or an OS CSPRNG.  A promise whose test needs a
## service is a promise nothing checks on most runs.
##
## `just test-vm-native` and `just test-vm-js` reach this file by globbing
## `src/tests/gui/tests/**/*_test.nim`, and `CoreViewModelGateTests` in
## `src/ct_test/release_gate.nim` is the registry that says it must exist and
## must not be skip-disabled.

import std/[base64, json, strutils, unittest]

import ../../../../ct/online_sharing/artifact

const
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"

proc sampleEnvelope(artifactId, kindToken: string,
    sliceCount = 1): ArtifactEnvelope =
  ## A structurally valid envelope with values that are *distinguishable* —
  ## every byte string is a different repeated character, so an assertion that
  ## the wrong field ended up somewhere fails rather than coincidentally
  ## passing.
  ArtifactEnvelope(
    version: int(ArtifactEnvelopeVersion),
    cipher: ArtifactEnvelopeCipher,
    kdf: ArtifactEnvelopeKdf,
    scryptN: ArtifactScryptN,
    scryptR: ArtifactScryptR,
    scryptP: ArtifactScryptP,
    salt: repeat('s', ArtifactEnvelopeSaltBytes),
    wrapNonce: repeat('n', ArtifactEnvelopeNonceBytes),
    wrappedKey: repeat('w',
      ArtifactEnvelopeKeyBytes + ArtifactEnvelopeTagBytes),
    artifactId: artifactId,
    kindToken: kindToken,
    sliceCount: sliceCount)

proc sampleHeader(artifactId, kindToken: string, partIndex = 0,
    partCount = 1, partName = "payload.zip", sliceCount = 1,
    sealedBytes = 64): ArtifactEnvelopeHeader =
  ArtifactEnvelopeHeader(
    envelope: sampleEnvelope(artifactId, kindToken, sliceCount),
    partIndex: partIndex,
    partCount: partCount,
    partName: partName,
    sealedBytes: sealedBytes)

suite "AS-3 — the protection registry says what it claims, in fields":
  ## AS-1 guarded this seam with a cardinality assertion: `ArtifactProtection`
  ## had exactly one value and a test counted it, so AS-3 would have to widen
  ## it deliberately.  AS-3 widens it, and replaces that guard with a **stronger
  ## one** rather than merely updating the number: the registry is indexed by
  ## the enum, so a protection without a row does not compile at all, and every
  ## row must state what it protects against, what it does not, and what
  ## recovery exists.  Counting the enum tells you that somebody widened it;
  ## the registry makes them say what they widened it to mean.

  test "the enum has exactly the two values AS-3 declares":
    # Kept, and kept as a literal, because the count is what makes the *next*
    # addition deliberate.  Whoever adds a third protection edits this line and
    # is thereby made to read the suite that follows it.
    var protections = 0
    for protection in ArtifactProtection:
      inc protections
    check protections == 2
    check $apNone == "none"
    check $apPasswordScryptAes256Gcm == "password-scrypt-aes-256-gcm"

  test "every protection has a complete registry row":
    for protection in ArtifactProtection:
      checkpoint($protection)
      let spec = protectionSpec(protection)
      check spec.protection == protection
      check spec.wireToken == $protection
      # Each of these is a sentence a user is shown.  An empty one is a
      # protection that has not been thought through.
      check spec.headline.len > 0
      check spec.whatItProtectsAgainst.len > 0
      check spec.whatItDoesNotProtect.len > 0
      check spec.recoveryWhenSecretLost.len > 0

  test "no protection sends its secret to the service":
    # The claim AS-3's first deliverable turns on, asserted as a property of
    # the whole closed set rather than of the one scheme that exists.  A future
    # escrow scheme would have to set `secretReachesService: true`, which makes
    # this fail and forces the user-visible strings to be rewritten before it
    # can ship.
    check everyProtectionKeepsTheSecretLocal()
    for protection in ArtifactProtection:
      checkpoint($protection)
      check not protectionSpec(protection).secretReachesService

  test "a protection that encrypts is authenticated, and says it encrypts":
    # An unauthenticated cipher would let somebody who can rewrite the stored
    # bytes hand the reader altered content that decrypts without complaint.
    # Every encrypting protection this store offers must be an AEAD.
    for protection in ArtifactProtection:
      checkpoint($protection)
      let spec = protectionSpec(protection)
      if spec.encryptsPayload:
        check spec.authenticated
        check spec.requiresSecretToRead
      else:
        check not spec.requiresSecretToRead

  test "apNone claims nothing, and says so in the words a user reads":
    let spec = protectionSpec(apNone)
    check not spec.encryptsPayload
    check not spec.authenticated
    check "Not encrypted" in spec.headline
    # The honest reading of "none" is not "safe by default": the sentence must
    # say the service can read it.
    check "read the payload" in spec.whatItDoesNotProtect
    check protectionRequiresSecret(apNone) == false

  test "the encrypting protection does NOT claim to encrypt the metadata":
    # AS-3's third deliverable.  The flag is the machine-readable half; the
    # sentence is the half a user reads, and both must say the same thing.
    let spec = protectionSpec(apPasswordScryptAes256Gcm)
    check spec.encryptsPayload
    check not spec.encryptsMetadata
    check "metadata is NOT encrypted" in spec.whatItDoesNotProtect
    check "commit" in spec.whatItDoesNotProtect

  test "the recovery answer is 'nothing', and it is written as 'nothing'":
    # AS-3's fourth deliverable: "if the answer is 'nothing', that is
    # acceptable and must be said before they choose it, not after."  Asserted
    # on the string, because a euphemism here — "contact support", "may not be
    # possible" — is exactly how a user ends up finding out afterwards.
    let recovery = protectionSpec(apPasswordScryptAes256Gcm).recoveryWhenSecretLost
    check recovery.startsWith("Nothing.")
    check "cannot be" in recovery
    check "CodeTracer" in recovery

suite "AS-3 — the password flow is identical whatever the kind":
  ## Verification item 3.  The property is asserted by *construction* and then
  ## checked: `artifactProtectionPrompt` is a function of the protection and a
  ## noun, so the test can demand that substituting the noun turns one kind's
  ## prompt into another's, exactly.

  test "two kinds' prompts differ in the noun and in nothing else":
    for protection in ArtifactProtection:
      for first in ArtifactKind:
        for second in ArtifactKind:
          checkpoint($protection & " " & $first & " -> " & $second)
          let a = artifactProtectionPrompt(first, protection)
          let b = artifactProtectionPrompt(second, protection)
          # Everything that describes the PROTECTION is byte-identical.
          check a.headline == b.headline
          check a.protectsAgainst == b.protectsAgainst
          check a.doesNotProtect == b.doesNotProtect
          check a.recoveryNotice == b.recoveryNotice
          check a.metadataNotice == b.metadataNotice
          check a.confirmRequired == b.confirmRequired
          # …and the only thing that describes the SUBJECT turns into the
          # other one by replacing the noun.  Not "is similar": is equal.
          check a.action.replace(artifactSubjectNoun(first),
            artifactSubjectNoun(second)) == b.action

  test "the prompt names what is being shared, in the user's words":
    check artifactSubjectNoun(akRecording) == "recording"
    check artifactSubjectNoun(akReviewDataset) == "review dataset"
    for kind in ArtifactKind:
      checkpoint($kind)
      let prompt = artifactProtectionPrompt(kind, apPasswordScryptAes256Gcm)
      check artifactSubjectNoun(kind) in prompt.action
      check prompt.action.startsWith("Encrypt")

  test "an encrypting prompt carries the metadata notice; apNone does not":
    for kind in ArtifactKind:
      checkpoint($kind)
      check artifactProtectionPrompt(
        kind, apPasswordScryptAes256Gcm).metadataNotice ==
        MetadataStillVisibleNotice
      # Nothing implies a capability that does not exist, in this direction
      # too: an unencrypted upload must not display a notice about which parts
      # of it are encrypted, because none of it is.
      check artifactProtectionPrompt(kind, apNone).metadataNotice == ""

  test "the password is confirmed exactly when losing it is unrecoverable":
    for kind in ArtifactKind:
      for protection in ArtifactProtection:
        checkpoint($kind & " " & $protection)
        check artifactProtectionPrompt(kind, protection).confirmRequired ==
          protectionSpec(protection).requiresSecretToRead

suite "AS-3 — a password is validated the same way everywhere":
  ## One validator, shared by the CLI and by AS-4's dialog, so the two cannot
  ## enforce different rules.  NIST SP 800-63B §5.1.1.2: a length floor and no
  ## composition rules.

  test "an empty password is refused":
    let refused = validatePasswordChoice("", "")
    check refused.problem == pcpEmpty
    check refused.message.len > 0

  test "a password shorter than the floor is refused, and says how short":
    let refused = validatePasswordChoice("hunter2", "hunter2")
    check refused.problem == pcpTooShort
    check $MinimumPasswordLength in refused.message
    check "7" in refused.message

  test "a mistyped confirmation is refused, and says why it was asked twice":
    let refused = validatePasswordChoice(
      "correct horse battery", "correct horse batteru")
    check refused.problem == pcpMismatch
    check "cannot be recovered" in refused.message

  test "a password has exactly one source, and naming two is refused":
    # This exists because of a defect found by running the shipped binary
    # rather than by reading the source. The stdin source used to be spelled
    # `--password-file -`, and `confutils` parses a bare `-` as the start of
    # another option — so the password silently arrived as *nothing*. Under
    # `--encrypt` that surfaced as "there is no terminal to ask on"; without
    # it, the refusal that stops an unencrypted upload never fired at all.
    #
    # The fix is a boolean flag, which cannot be swallowed, and this is the
    # decision table it feeds — pure, so it is checked without a shell.
    check secretSource(false, "") == ("", "")
    check secretSource(true, "") == (SecretFromStdin, "")
    check secretSource(false, "/tmp/pw.txt") == ("/tmp/pw.txt", "")
    let both = secretSource(true, "/tmp/pw.txt")
    check both.path == ""
    check both.error.len > 0
    check "mutually" in both.error
    # The stdin marker is not a path a user could name by accident from the
    # file option — it is reached only through the flag.
    check SecretFromStdin == "-"

  test "a long passphrase is accepted, and no composition rule is imposed":
    # Explicitly asserted, because "require a digit and a symbol" is the rule
    # people add by reflex and SP 800-63B §5.1.1.2 says not to: it pushes users
    # towards shorter, more predictable secrets.
    for accepted in ["correct horse battery staple",
        "aaaaaaaa", "        ", "пароль от артефакта",
        repeat("x", 4096)]:
      checkpoint($accepted.len & " characters")
      check validatePasswordChoice(accepted, accepted).problem == pcpNone

suite "AS-3 — what stays visible is a list, not a caveat":
  ## Verification item 4's headless half.  The list is exhaustive per kind, so
  ## a new kind must answer "which of my metadata is sensitive" — the ninth
  ## obligation in `Artifact-Store.md` §3.1 — and the round-trip suite compares
  ## this list against the keys that actually cross the socket.

  test "every kind states which metadata the service can still read":
    for kind in ArtifactKind:
      checkpoint($kind)
      check serviceVisibleMetadataFields(kind).len > 0

  test "a recording's frozen bodies leak two fields and no more":
    # The recording kind's request bodies cannot grow keys (§9.3), and here
    # that constraint is a confidentiality *advantage*: the program name, the
    # language and the record-start time do not travel at all.
    check serviceVisibleMetadataFields(akRecording) ==
      @["recordingId", "platform"]
    for absent in ["program", "lang", "recordedAtUnixMs"]:
      checkpoint(absent)
      check absent notin serviceVisibleMetadataFields(akRecording)

  test "a review dataset's commit is visible, and that is the point of saying so":
    # AS-1 §6 named exactly this: "a review dataset's metadata names files and
    # a commit, which may itself be sensitive".  Encrypting the payload does
    # not hide it, so the list says it does not.
    let visible = serviceVisibleMetadataFields(akReviewDataset)
    check visible == @["commitSha", "baseCommitSha", "fileCount",
      "recordingCount", "sessionTitle"]

  test "the transfer facts are visible for every kind, by construction":
    let facts = serviceVisibleTransferFacts()
    for expected in ["artifactId", "kind", "fileName", "contentLength"]:
      checkpoint(expected)
      check expected in facts

  test "the visible-metadata line is rendered one way for every caller":
    check describeVisibleMetadata(@["a", "b"]) == "a, b"
    check describeVisibleMetadata(@[]) == "nothing beyond the transfer itself"

suite "AS-3 — the envelope's wire format":

  test "a sealed frame round-trips through the frame codec":
    for kind in ArtifactKind:
      checkpoint($kind)
      let header = sampleHeader("0194a000-1111-7abc-8def-000000000001",
        kindSpec(kind).wireToken)
      let headerJson = envelopeHeaderJson(header)
      let frame = encodeEnvelopeFrame(
        headerJson, repeat('c', header.sealedBytes))
      check looksLikeEnvelope(frame)
      let decoded = decodeEnvelopeFrame(frame)
      check decoded.isEnvelope
      check decoded.error == ""
      check decoded.headerJson == headerJson
      check decoded.sealedPayload == repeat('c', header.sealedBytes)
      check decoded.nextOffset == frame.len
      let parsed = parseEnvelopeHeader(decoded.headerJson)
      check parsed.error == ""
      check parsed.header.envelope.artifactId == header.envelope.artifactId
      check parsed.header.envelope.kindToken == kindSpec(kind).wireToken
      check parsed.header.envelope.salt == header.envelope.salt
      check parsed.header.envelope.wrapNonce == header.envelope.wrapNonce
      check parsed.header.envelope.wrappedKey == header.envelope.wrappedKey
      check parsed.header.partIndex == header.partIndex
      check parsed.header.partName == header.partName

  test "the header is deterministic, which is what makes the AAD work":
    # The header is written into the file AND used verbatim as the additional
    # authenticated data, and its length is computed once before sealing and
    # again while sealing.  If it were not byte-stable the client would tell
    # the service a content length it then did not send, and the tag would not
    # verify against the bytes on disk.
    let header = sampleHeader(SampleDatasetId, "review-dataset")
    check envelopeHeaderJson(header) == envelopeHeaderJson(header)
    check envelopeHeaderJson(header).len > 0
    # ASCII only, so its length in bytes is its length in characters — the
    # four-byte length prefix counts bytes.
    for c in envelopeHeaderJson(header):
      check int(uint8(c)) < 128

  test "the overhead is exact, not an estimate":
    let headerJson = envelopeHeaderJson(sampleHeader(
      SampleRecordingId, "recording",
      sealedBytes = 100 + ArtifactEnvelopeTagBytes))
    # AES-GCM is a stream mode: no padding, so a 100-byte plaintext seals to
    # 100 bytes of ciphertext plus the 16-byte tag, and the whole growth over
    # the plaintext is the frame prefix plus that tag.
    let sealedPayload = repeat('c', 100 + ArtifactEnvelopeTagBytes)
    let frame = encodeEnvelopeFrame(headerJson, sealedPayload)
    check frame.len == 100 + envelopeOverheadBytes(headerJson)
    # Stated the other way round too, because the number this feeds is a
    # `Content-Length` an S3 presigned PUT rejects outright if it is wrong.
    check envelopeOverheadBytes(headerJson) ==
      ArtifactEnvelopeMagic.len + 1 + 4 + headerJson.len +
      ArtifactEnvelopeTagBytes

  test "the magic cannot be confused with a zip, and survives a hex dump":
    check ArtifactEnvelopeMagic.len == 11
    check int(uint8(ArtifactEnvelopeMagic[0])) == 0x89
    check ArtifactEnvelopeMagic[1 .. 6] == "CTAENC"
    check "\x0D\x0A" in ArtifactEnvelopeMagic
    check "\x1A" in ArtifactEnvelopeMagic
    # The two file shapes that actually reach this path today.
    check not looksLikeEnvelope("PK\x03\x04rest of a zip")
    check not looksLikeEnvelope("{\"a\": 1}")
    check not looksLikeEnvelope("")
    check not looksLikeEnvelope(ArtifactEnvelopeMagic[0 ..< 5])

  test "the envelope header never carries the password or the content key":
    # Verification item 2, in the one place a key could plausibly end up on the
    # wire by accident: the header is the only thing about the encryption that
    # is transmitted, and what it carries is a WRAPPED key.  The test asserts
    # the field set exactly, so a later addition has to be argued for here.
    let headerJson = envelopeHeaderJson(
      sampleHeader(SampleDatasetId, "review-dataset"))
    let node = parseJson(headerJson)
    var keys: seq[string] = @[]
    for key, _ in node.pairs:
      keys.add key
    # Two fields were added after independent verification found that an
    # encrypted slice set had no working download path (§8 defect 19), and the
    # list is widened HERE deliberately, which is what this assertion is for:
    #
    #   * `sliceCount` — how many frames the reassembled payload is, so a
    #     WITHHELD slice is refused rather than reassembled short;
    #   * `sealedBytes` — where one frame ends and the next begins, under the
    #     tag rather than in an outer length field.
    #
    # Neither is a secret. Both are facts the service could compute from the
    # object it is holding anyway.
    check keys == @["v", "cipher", "kdf", "n", "r", "p", "salt", "wrapNonce",
      "wrappedKey", "artifactId", "kind", "sliceCount", "partIndex",
      "partCount", "partName", "sealedBytes"]
    for forbidden in ["password", "secret", "key", "contentKey", "passphrase"]:
      checkpoint(forbidden)
      check not node.hasKey(forbidden)

  test "the nonce is a pure function of the part index, and never repeats":
    # NIST SP 800-38D §8.2.1's deterministic construction.  Reuse is
    # impossible by construction — a fresh content key per sealing operation,
    # plus distinct indices within it — rather than by convention, and this is
    # the "distinct indices" half.
    var seenNonces: seq[string] = @[]
    for index in 0 ..< 512:
      let nonce = partNonce(index)
      check nonce.len == ArtifactEnvelopeNonceBytes
      check nonce notin seenNonces
      seenNonces.add nonce
      # …and it is a function, so the same index always gives the same nonce:
      # the sealing and the size computation must agree.
      check partNonce(index) == nonce
    # The leading four bytes are SP 800-38D's fixed field, reserved here.
    check partNonce(0) == repeat('\0', ArtifactEnvelopeNonceBytes)
    check partNonce(1)[0 ..< 11] == repeat('\0', 11)
    check int(uint8(partNonce(1)[11])) == 1
    check int(uint8(partNonce(256)[10])) == 1
    check int(uint8(partNonce(256)[11])) == 0

suite "AS-3 — an envelope this client cannot read is refused, never guessed":
  ## The same rule the kind registry follows, one layer down: unrecognised
  ## input is an error naming what was wrong, not a default.  It matters more
  ## here, because the input has not been authenticated yet — the parameters
  ## being read are the ones the authentication needs.

  test "a structurally truncated frame is refused before anything is parsed":
    # Two kinds of truncation, and they are caught in two different places on
    # purpose.  Everything up to and including the header is checked HERE,
    # because those lengths are what the parse itself needs and a parser that
    # trusted them would index past the end of an attacker-supplied buffer.
    let headerJson = envelopeHeaderJson(
      sampleHeader(SampleDatasetId, "review-dataset"))
    let frame = encodeEnvelopeFrame(headerJson, repeat('c', 64))
    # The structural minimum is "magic, version, length, the whole header, and
    # at least a tag".  Every cut below that is refused here; a cut above it is
    # the ciphertext case in the test that follows.
    let structuralMinimum =
      ArtifactEnvelopeMagic.len + 1 + 4 + headerJson.len +
      ArtifactEnvelopeTagBytes
    for cut in [ArtifactEnvelopeMagic.len,
        ArtifactEnvelopeMagic.len + 3,
        ArtifactEnvelopeMagic.len + 5,
        ArtifactEnvelopeMagic.len + 5 + headerJson.len div 2,
        structuralMinimum - ArtifactEnvelopeTagBytes,
        structuralMinimum - 1]:
      checkpoint("truncated to " & $cut)
      let decoded = decodeEnvelopeFrame(frame[0 ..< cut])
      check decoded.isEnvelope
      check decoded.error.len > 0

  test "a frame truncated in the CIPHERTEXT is refused by its declared length":
    # This claim CHANGED, and the change is the interesting part.
    #
    # It first read "a truncated ciphertext leaves a structurally valid frame,
    # so the tag is what rejects it" — true when the frame's extent was
    # implicitly "the rest of the file". It is no longer: a reassembled payload
    # is a concatenation, so something has to say where one frame ends, and
    # `sealedBytes` says it *inside the header*, under the tag. A short frame
    # is therefore caught by the framing, before any key is derived — which
    # also means a corrupt download costs no scrypt derivation.
    #
    # The tag still catches what a length cannot: bytes altered in place.
    # `artifact_crypto_test.nim` asserts that, against the real primitive.
    let header = sampleHeader(SampleDatasetId, "review-dataset",
      sealedBytes = 64 + ArtifactEnvelopeTagBytes)
    let frame = encodeEnvelopeFrame(
      envelopeHeaderJson(header), repeat('c', header.sealedBytes))
    let whole = decodeEnvelopeFrame(frame)
    check whole.error == ""
    check whole.nextOffset == frame.len

    for missing in [1, 5, 64]:
      checkpoint("short by " & $missing)
      let decoded = decodeEnvelopeFrame(frame[0 ..< frame.len - missing])
      check decoded.isEnvelope
      check decoded.error.len > 0
      check "truncated" in decoded.error

  test "frames concatenate, and each one says where the next begins":
    # What a sliced artifact's download actually looks like: one envelope per
    # slice, end to end, because the service reassembles the payload by
    # concatenating them. Walking that is `openArtifactPayload`'s job; this is
    # the pure half of it.
    var payload = ""
    var expectedOffsets: seq[int] = @[]
    for index in 0 ..< 3:
      let header = sampleHeader(SampleDatasetId, "review-dataset",
        partIndex = index, partCount = 3, sliceCount = 3,
        partName = "slice_" & $index & ".ct",
        sealedBytes = 32 + index)
      payload.add encodeEnvelopeFrame(
        envelopeHeaderJson(header), repeat('c', header.sealedBytes))
      expectedOffsets.add payload.len

    var offset = 0
    var seen = 0
    while offset < payload.len:
      let frame = decodeEnvelopeFrame(payload, offset)
      check frame.isEnvelope
      check frame.error == ""
      check frame.header.partIndex == seen
      check frame.header.envelope.sliceCount == 3
      check frame.sealedPayload.len == 32 + seen
      check frame.nextOffset == expectedOffsets[seen]
      offset = frame.nextOffset
      inc seen
    check seen == 3

  test "a future envelope version is refused, naming both versions":
    var frame = encodeEnvelopeFrame(
      envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")),
      repeat('c', 32))
    frame[ArtifactEnvelopeMagic.len] = chr(9)
    let decoded = decodeEnvelopeFrame(frame)
    check decoded.error.len > 0
    check "version 9" in decoded.error
    check "version 1" in decoded.error

  test "an absurd declared header length is refused before it is allocated":
    # The length is read from bytes nothing has authenticated, so it is bounded
    # before it sizes anything.  A client that trusted it would try to allocate
    # four gigabytes on the say-so of a corrupt download.
    var frame = encodeEnvelopeFrame(
      envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")),
      repeat('c', 32))
    let lengthAt = ArtifactEnvelopeMagic.len + 1
    frame[lengthAt] = chr(0x7F)
    let decoded = decodeEnvelopeFrame(frame)
    check decoded.error.len > 0
    check $MaxEnvelopeHeaderBytes in decoded.error

  test "a weakened scrypt cost is refused rather than honoured":
    # The header is covered by the tag, so this cannot be done by an attacker
    # who does not already know the password.  The floor exists so that a
    # header written with weaker parameters — by some future client, or by a
    # user's own older build — is refused loudly instead of opened quietly.
    for weak in [1, 2, 1024, ArtifactScryptMinN div 2]:
      checkpoint($weak)
      check scryptParametersProblem(weak, 8, 1).len > 0
    check scryptParametersProblem(ArtifactScryptN, 8, 1) == ""
    check scryptParametersProblem(ArtifactScryptMinN, 8, 1) == ""

  test "an absurd scrypt cost is refused, which is a memory-exhaustion guard":
    for absurd in [ArtifactScryptMaxN * 2, 1 shl 30]:
      checkpoint($absurd)
      let problem = scryptParametersProblem(absurd, 8, 1)
      check problem.len > 0
      check $ArtifactScryptMaxN in problem
    check scryptParametersProblem(ArtifactScryptN, 4096, 1).len > 0
    check scryptParametersProblem(ArtifactScryptN, 8, 4096).len > 0
    # N must be a power of two — RFC 7914 §2 requires it, and the
    # implementation's own validator rejects it, so refusing here means the
    # refusal names the reason instead of surfacing as "produced 0 bytes".
    let notPowerOfTwo = scryptParametersProblem(ArtifactScryptN + 1, 8, 1)
    check "power of two" in notPowerOfTwo

  test "a cipher or KDF this client does not implement is refused":
    for swap in [("cipher", "AES-128-GCM"), ("cipher", "ChaCha20"),
        ("cipher", "AES-256-CBC"), ("kdf", "pbkdf2"), ("kdf", "argon2id")]:
      checkpoint(swap[0] & "=" & swap[1])
      var node = parseJson(
        envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")))
      node[swap[0]] = %swap[1]
      let parsed = parseEnvelopeHeader($node)
      check parsed.error.len > 0
      check swap[1] in parsed.error

  test "a salt, nonce or wrapped key of the wrong size is refused":
    for field in ["salt", "wrapNonce", "wrappedKey"]:
      for wrongLength in [0, 8, 100]:
        checkpoint(field & " -> " & $wrongLength)
        var node = parseJson(
          envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")))
        node[field] = %encode(repeat('x', wrongLength))
        let parsed = parseEnvelopeHeader($node)
        check parsed.error.len > 0
        check field in parsed.error

  test "a header field that is missing or the wrong JSON type is refused":
    let complete = parseJson(
      envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")))
    for key, _ in complete.pairs:
      checkpoint("missing " & key)
      var node = parseJson($complete)
      node.delete(key)
      check parseEnvelopeHeader($node).error.len > 0

      checkpoint("wrong type " & key)
      var swapped = parseJson($complete)
      swapped[key] = if complete[key].kind == JString: %7 else: %"seven"
      check parseEnvelopeHeader($swapped).error.len > 0

  test "a header claiming an impossible part position is refused":
    for bad in [(-1, 3), (3, 3), (7, 3), (0, 0), (0, -1)]:
      checkpoint($bad[0] & " of " & $bad[1])
      var node = parseJson(
        envelopeHeaderJson(sampleHeader(SampleDatasetId, "review-dataset")))
      node["partIndex"] = %bad[0]
      node["partCount"] = %bad[1]
      check parseEnvelopeHeader($node).error.len > 0

  test "the key wrap is bound to the artifact and to the KDF parameters":
    # Not circular, and not decorative: without this binding, an attacker
    # holding two artifacts a user encrypted with the SAME password could move
    # one's wrapped key onto the other's header and both tags would verify.
    let first = sampleEnvelope(SampleRecordingId, "recording")
    var second = sampleEnvelope(SampleDatasetId, "review-dataset")
    check keyWrapAad(first) != keyWrapAad(second)
    var weakened = first
    weakened.scryptN = ArtifactScryptMinN
    check keyWrapAad(weakened) != keyWrapAad(first)
    var resalted = first
    resalted.salt = repeat('t', ArtifactEnvelopeSaltBytes)
    check keyWrapAad(resalted) != keyWrapAad(first)
    # …and it does not contain the wrapped key, which would be circular.
    check encode(first.wrappedKey) notin keyWrapAad(first)

suite "AS-3 — an old client refuses an unknown protection, in the safe direction":
  ## This is the reason `Artifact-Store.md` §8 defect 10 had to be closed in
  ## AS-2 rather than here.  A client built before a protection existed cannot
  ## be compiled in this test binary, but the code path it would take is one
  ## function, and driving it with a token this build does not know is exactly
  ## that path.

  test "a protection token this build does not know is refused, not coerced":
    # Every one of these is a plausible NEXT protection.  An old client meeting
    # one must refuse the record rather than read it as `none` — reading it as
    # `none` would present an encrypted payload as plaintext-safe.
    for future in ["password-xchacha20-poly1305-argon2id",
        "recipient-public-key", "hardware-token", "aes-256-gcm",
        "password-scrypt-aes-256-gcm ", "Password-Scrypt-Aes-256-Gcm"]:
      checkpoint(future)
      let read = readClosedEnumField[ArtifactProtection](
        %*{"protection": future}, "protection", apNone)
      check read.error.len > 0
      check future in read.error
      # …and the refusal shows the closed set, so the answer to "why" does not
      # require reading the source.
      check "none" in read.error
      check "password-scrypt-aes-256-gcm" in read.error

  test "an absent protection still reads as none, so pre-AS-3 records parse":
    # Absence is not an unknown value.  A record written before protection
    # existed genuinely declares none, and refusing those would strand every
    # artifact stored before this milestone.
    let read = readClosedEnumField[ArtifactProtection](
      %*{"artifactId": SampleDatasetId}, "protection", apNone)
    check read.error == ""
    check read.value == apNone

  test "both declared protections round-trip through an artifact record":
    # The refusal must not be so eager that it rejects what this build itself
    # writes.
    for kind in ArtifactKind:
      for protection in ArtifactProtection:
        checkpoint($kind & " " & $protection)
        let record = %*{
          "artifactId": SampleDatasetId,
          "kind": kindSpec(kind).wireToken,
          "displayName": "x",
          "access": {
            "tenantId": "tenant-123",
            "protection": protectionSpec(protection).wireToken,
          },
        }
        let parsed = parseArtifact(record)
        check parsed.error == ""
        check parsed.artifact.access.protection == protection
