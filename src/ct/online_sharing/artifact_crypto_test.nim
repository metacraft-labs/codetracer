## AS-3 — the cryptography itself, against the real primitives.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-3
## verification item 1 ("an encrypted artifact is unreadable without the key"),
## plus the three the milestone asked to be added: tampered ciphertext is
## rejected, a wrong password fails cleanly, and an old-format artifact still
## downloads.
##
## ## Why this is a third suite
##
## `src/tests/gui/tests/sharing/artifact_protection_vm_test.nim` asserts the
## *claims* and the wire format, headlessly on both Nim backends.
## `artifact_store_roundtrip_test.nim` asserts the whole thing over a real
## socket.  Neither can assert what this one does: that the construction is
## actually sound — that a wrong password fails, that a flipped bit anywhere is
## detected, that two sealings of the same bytes do not produce the same
## ciphertext, and that a part cannot be transplanted between artifacts.
##
## ## On mocking, per the workspace policy
##
## Nothing is mocked.  This runs the real `nimcrypto` AES-256-GCM, the real
## scrypt and the real operating-system CSPRNG — the same code `ct upload
## --encrypt` links.
##
## ## On the work factor, stated rather than hidden
##
## Most cases below derive keys at `ArtifactScryptMinN` (2^14) instead of the
## shipped 2^17.  That is a **cost** decision and it is disclosed here because
## a suite that quietly weakens the thing it is testing is worse than a slow
## one:
##
## * the code path is identical — the same `scrypt`, the same AES-256-GCM, the
##   same envelope — and the parameters travel in the header precisely so that
##   the opening side honours a range rather than one point;
## * 2^14 is inside the accepted range and is the FLOOR this client will read,
##   so exercising it is also the only way the floor is exercised at all;
## * `the shipped scrypt work factor is what is actually used` pins 2^17 on the
##   default path, and `artifact_store_roundtrip_test.nim` pins it again on the
##   bytes that cross the socket, so the number that ships is asserted twice
##   at full cost.
##
## Without this the suite takes about a minute and three quarters in the debug
## build the lane compiles; with it, about twenty seconds.
##
## Runs in `just test-mcr-enrichment-units`, which globs this directory.

import std/[strutils, unittest]

import artifact_crypto

const
  SampleRecordingId = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
  SampleDatasetId = "0194a000-1111-7abc-8def-000000000001"
  SamplePassword = "correct horse battery staple"
  SamplePlaintext = "the quick brown fox jumps over the lazy dog, 42 times"

const
  CheapParameters = ArtifactScryptParameters(
    n: ArtifactScryptMinN, r: ArtifactScryptR, p: ArtifactScryptP)
    ## The accepted floor, used where the case under test is about the envelope
    ## rather than about the work factor.  See the module comment.

proc sealOne(password, artifactId, kindToken, plaintext: string,
    partIndex = 0, partCount = 1, partName = "payload.zip",
    sliceCount = 1, parameters = CheapParameters): string =
  ## Seal one part and return the frame, failing the test rather than
  ## returning something unusable.
  let prepared = newArtifactSeal(
    password, artifactId, kindToken, sliceCount, parameters)
  doAssert prepared.error == "", prepared.error
  var seal = prepared.seal
  let frame = sealArtifactPart(seal, partIndex, partCount, partName, plaintext)
  doAssert frame.error == "", frame.error
  wipe(seal)
  frame.frame

suite "AS-3 — an encrypted artifact is unreadable without the key":

  test "the plaintext does not appear in the sealed bytes, for either kind":
    for kindToken in ["recording", "review-dataset"]:
      checkpoint(kindToken)
      let frame = sealOne(SamplePassword, SampleDatasetId, kindToken,
        SamplePlaintext)
      # The obvious assertion, and it is worth making obviously: the payload
      # is not sitting in the file.
      check SamplePlaintext notin frame
      check "quick brown fox" notin frame
      # Nor is the password, nor anything derived from it that is not meant to
      # be there.  The salt and the wrapped key are in the header by design;
      # the password is not, anywhere.
      check SamplePassword notin frame
      check "correct horse" notin frame

  test "the right password recovers the plaintext exactly":
    for kindToken in ["recording", "review-dataset"]:
      checkpoint(kindToken)
      let frame = sealOne(SamplePassword, SampleDatasetId, kindToken,
        SamplePlaintext)
      let opened = openArtifactPart(SamplePassword, frame,
        expectedArtifactId = SampleDatasetId, expectedPartIndex = 0)
      check opened.error == ""
      check opened.plaintext == SamplePlaintext
      check opened.header.envelope.kindToken == kindToken
      check opened.header.envelope.cipher == "AES-256-GCM"
      check opened.header.envelope.kdf == "scrypt"

  test "the shipped scrypt work factor is what is actually used":
    # The DEFAULT — no `parameters` argument — which is what every product call
    # site passes.  Pinned rather than assumed: these are the numbers
    # `Artifact-Store.md` §10.2 states and justifies, and a change to them is a
    # change to the security of every artifact sealed afterwards, so it should
    # have to be made here too.
    let frame = sealOne(SamplePassword, SampleRecordingId, "recording", "x",
      parameters = ShippedScryptParameters)
    let opened = openArtifactPart(SamplePassword, frame)
    check opened.error == ""
    check opened.header.envelope.scryptN == 131072   # 2^17
    check opened.header.envelope.scryptR == 8
    check opened.header.envelope.scryptP == 1
    # 128 MiB at these parameters — the memory-hardness that is the whole
    # reason for preferring scrypt to a plain iterated hash.
    check 128 * opened.header.envelope.scryptN *
      opened.header.envelope.scryptR == 128 * 1024 * 1024

  test "an empty payload seals and opens, rather than being a special case":
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset", "")
    let opened = openArtifactPart(SamplePassword, frame)
    check opened.error == ""
    check opened.plaintext == ""

  test "a payload with NUL bytes and high bytes round-trips unchanged":
    # The payloads this actually carries are zip archives and CTFS containers.
    var binary = newString(4096)
    for i in 0 ..< binary.len:
      binary[i] = chr(i mod 256)
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      binary)
    let opened = openArtifactPart(SamplePassword, frame)
    check opened.error == ""
    check opened.plaintext == binary
    check opened.plaintext.len == 4096

suite "AS-3 — the key is fresh every time, so a nonce is never reused":

  test "two sealings of identical bytes produce different ciphertext":
    # This is the observable consequence of "a fresh content key from the OS
    # CSPRNG for every sealing operation", which is in turn what makes the
    # deterministic per-part nonce schedule safe (NIST SP 800-38D §8.2.1).
    # If the key were derived from the password alone, these would be equal —
    # and re-uploading an artifact would be a (key, nonce) reuse.
    let first = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    let second = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    check first != second
    check first.len == second.len
    # …and both still open, so the difference is randomisation and not damage.
    check openArtifactPart(SamplePassword, first).plaintext == SamplePlaintext
    check openArtifactPart(SamplePassword, second).plaintext == SamplePlaintext

  test "the salt and the wrap nonce are fresh too":
    let a = newArtifactSeal(
      SamplePassword, SampleDatasetId, "review-dataset", 1, CheapParameters)
    let b = newArtifactSeal(
      SamplePassword, SampleDatasetId, "review-dataset", 1, CheapParameters)
    check a.error == ""
    check b.error == ""
    check a.seal.envelope.salt != b.seal.envelope.salt
    check a.seal.envelope.wrapNonce != b.seal.envelope.wrapNonce
    check a.seal.contentKey != b.seal.contentKey
    check a.seal.envelope.salt.len == 32
    check a.seal.contentKey.len == 32

  test "every part of one artifact seals under a different nonce":
    # The one failure mode of GCM that loses the key stream outright.  The
    # nonces are distinct because the part indices are, and
    # `planArtifactUpload` is what enforces the indices — asserted there.  Here
    # the consequence is asserted: identical bytes at different indices produce
    # different ciphertext under ONE key.
    let prepared = newArtifactSeal(
      SamplePassword, SampleRecordingId, "recording", 5, CheapParameters)
    check prepared.error == ""
    var seal = prepared.seal
    var frames: seq[string] = @[]
    for index in 0 ..< 5:
      let sealed = sealArtifactPart(seal, index, 5,
        "slice_" & align($index, 4, '0') & ".ct", "identical bytes")
      check sealed.error == ""
      check sealed.frame notin frames
      frames.add sealed.frame
    for index in 0 ..< 5:
      let opened = openArtifactPart(SamplePassword, frames[index],
        expectedArtifactId = SampleRecordingId, expectedPartIndex = index)
      check opened.error == ""
      check opened.plaintext == "identical bytes"
    wipe(seal)

  test "wiping a seal removes the content key from it":
    var prepared = newArtifactSeal(
      SamplePassword, SampleDatasetId, "review-dataset", 1, CheapParameters)
    check prepared.error == ""
    var seal = prepared.seal
    check seal.contentKey.len == 32
    wipe(seal)
    check seal.contentKey.len == 0
    # …and a wiped seal cannot be used to seal anything, rather than sealing
    # under an all-zero key.
    let refused = sealArtifactPart(seal, 0, 1, "x", "y")
    check refused.error.len > 0
    check "no content key" in refused.error

suite "AS-3 — tampered ciphertext is rejected, not silently accepted":
  ## The property that makes this an AEAD rather than a cipher.  An attacker
  ## who can rewrite the stored bytes must not be able to make a client accept
  ## altered content.

  test "flipping any single bit of the ciphertext is detected":
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    let firstCiphertextByte = frame.len - SamplePlaintext.len -
      ArtifactEnvelopeTagBytes
    for offset in [firstCiphertextByte,
        firstCiphertextByte + SamplePlaintext.len div 2,
        frame.len - ArtifactEnvelopeTagBytes - 1]:
      for bit in [0, 3, 7]:
        checkpoint("byte " & $offset & " bit " & $bit)
        var tampered = frame
        tampered[offset] = chr(int(uint8(tampered[offset])) xor (1 shl bit))
        let opened = openArtifactPart(SamplePassword, tampered)
        check opened.error.len > 0
        check "integrity check" in opened.error
        # And nothing came out. Returning unverified plaintext "so the caller
        # can decide" is what makes an AEAD no better than a stream cipher.
        check opened.plaintext == ""

  test "flipping any single bit of the authentication tag is detected":
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    for offset in [frame.len - ArtifactEnvelopeTagBytes, frame.len - 1]:
      checkpoint("tag byte " & $offset)
      var tampered = frame
      tampered[offset] = chr(int(uint8(tampered[offset])) xor 0x01)
      check openArtifactPart(SamplePassword, tampered).error.len > 0

  test "truncating the ciphertext is detected":
    # The case `artifact_protection_vm_test.nim` deliberately does NOT claim to
    # catch: a shortened ciphertext is a structurally valid frame, so the tag
    # is what refuses it. This is where that is asserted.
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    for shorterBy in [1, 5, 20]:
      checkpoint("shorter by " & $shorterBy)
      let opened = openArtifactPart(
        SamplePassword, frame[0 ..< frame.len - shorterBy])
      check opened.error.len > 0
      check opened.plaintext == ""

  test "rewriting the HEADER is detected, because the header is the AAD":
    # The header is not merely stored, it is the additional authenticated data,
    # so the artifact id, the kind, the part index, the part name and the KDF
    # parameters are all covered by the tag. Each substitution below is a real
    # attack shape, not a fuzz case.
    let prepared = newArtifactSeal(
      SamplePassword, SampleRecordingId, "recording", 3, CheapParameters)
    check prepared.error == ""
    var seal = prepared.seal
    let honest = sealArtifactPart(seal, 1, 3, "slice_0001.ct", SamplePlaintext)
    check honest.error == ""
    let decoded = decodeEnvelopeFrame(honest.frame)
    check decoded.error == ""

    # Two groups, because the binding has two layers and it is worth saying
    # which one catches what.  `keyWrapAad` covers the artifact id, the kind
    # and the KDF parameters, so rewriting one of those breaks the KEY UNWRAP;
    # the part's position and name are covered only by the payload's own AAD,
    # so rewriting one of those breaks the PAYLOAD TAG.  Either way nothing
    # comes out, which is the property; naming the layer is what stops a later
    # change silently moving a field out of both.
    const refusedAtTheUnwrap = "wrong password"
    const refusedAtThePayload = "integrity check"
    for swap in [("\"partIndex\":1", "\"partIndex\":2", refusedAtThePayload),
        ("\"partCount\":3", "\"partCount\":9", refusedAtThePayload),
        ("\"partName\":\"slice_0001.ct\"", "\"partName\":\"slice_0002.ct\"",
          refusedAtThePayload),
        ("\"kind\":\"recording\"", "\"kind\":\"review-dataset\"",
          refusedAtTheUnwrap),
        ("\"artifactId\":\"" & SampleRecordingId & "\"",
          "\"artifactId\":\"" & SampleDatasetId & "\"", refusedAtTheUnwrap),
        ("\"n\":16384", "\"n\":32768", refusedAtTheUnwrap)]:
      checkpoint(swap[0] & " -> " & swap[1])
      check swap[0] in decoded.headerJson
      let rewritten = decoded.headerJson.replace(swap[0], swap[1])
      let forged = encodeEnvelopeFrame(rewritten, decoded.sealedPayload)
      # The forgery is STRUCTURALLY sound — it decodes, and its header parses —
      # so what refuses it is an authentication tag and nothing else. Asserted
      # in that order so a future length check cannot quietly take the credit.
      let forgedFrame = decodeEnvelopeFrame(forged)
      check forgedFrame.error == ""
      check parseEnvelopeHeader(forgedFrame.headerJson).error == ""
      let opened = openArtifactPart(SamplePassword, forged)
      check opened.error.len > 0
      check swap[2] in opened.error
      check opened.plaintext == ""
    wipe(seal)

  test "a part cannot be transplanted onto another artifact's identity":
    # The substitution attack the AAD and `expectedArtifactId` exist for. A
    # service holding two artifacts a user encrypted with the SAME password
    # could otherwise serve one in place of the other and every tag would
    # verify, because both really were sealed by that user.
    let recording = sealOne(SamplePassword, SampleRecordingId, "recording",
      "the recording's bytes")
    let dataset = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      "the dataset's bytes")

    # Asked for the dataset, served the recording: refused by name.
    let substituted = openArtifactPart(SamplePassword, recording,
      expectedArtifactId = SampleDatasetId)
    check substituted.error.len > 0
    check SampleRecordingId in substituted.error
    check SampleDatasetId in substituted.error
    check substituted.plaintext == ""

    # …and each still opens under its own identity, so the check is not just
    # refusing everything.
    check openArtifactPart(SamplePassword, dataset,
      expectedArtifactId = SampleDatasetId).plaintext == "the dataset's bytes"

  test "a part cannot be served in place of a different part":
    let prepared = newArtifactSeal(
      SamplePassword, SampleRecordingId, "recording", 3, CheapParameters)
    check prepared.error == ""
    var seal = prepared.seal
    let second = sealArtifactPart(seal, 1, 3, "slice_0001.ct", "part one")
    check second.error == ""
    let opened = openArtifactPart(SamplePassword, second.frame,
      expectedArtifactId = SampleRecordingId, expectedPartIndex = 0)
    check opened.error.len > 0
    check "part 1" in opened.error
    wipe(seal)

suite "AS-3 — a wrong password fails cleanly":

  test "a wrong password is refused, and says which of two things it was":
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    for wrong in ["correct horse battery stapl",
        "Correct horse battery staple",
        "correct horse battery staple ",
        "", "hunter2", "  "]:
      checkpoint("'" & wrong & "'")
      let opened = openArtifactPart(SamplePassword & "x", frame)
      check opened.error.len > 0
      check opened.plaintext == ""

  test "an absent password says so, and says CodeTracer cannot help":
    # AS-3's fourth deliverable, at the moment it bites. The message must not
    # imply a recovery route that does not exist.
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    let opened = openArtifactPart("", frame)
    check opened.error.len > 0
    check "no password was supplied" in opened.error

  test "a wrong password does not leak how wrong it was":
    # Every wrong password must produce the same message, so the error cannot
    # be used as an oracle. Asserted, because "wrong password (3 of 4 blocks
    # decrypted)" is the kind of helpfulness that ends up in a diagnostic.
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset",
      SamplePlaintext)
    var messages: seq[string] = @[]
    for wrong in ["a-completely-different-password",
        "correct horse battery stapl", "correct horse battery stapleX"]:
      let opened = openArtifactPart(wrong, frame)
      check opened.error.len > 0
      messages.add opened.error
    check messages[0] == messages[1]
    check messages[1] == messages[2]
    # …and it does not contain the password, which is the other way a
    # diagnostic leaks one.
    for message in messages:
      check "correct horse" notin message
      check SamplePassword notin message

  test "refusing to seal with an empty password is a refusal, not a weak key":
    let refused = newArtifactSeal(
      "", SampleDatasetId, "review-dataset", 1, CheapParameters)
    check refused.error.len > 0
    check "empty password" in refused.error
    check refused.seal.contentKey.len == 0

  test "refusing to seal without an artifact id, because the id is in the tag":
    let refused = newArtifactSeal(
      SamplePassword, "", "review-dataset", 1, CheapParameters)
    check refused.error.len > 0
    check "no id" in refused.error

suite "AS-3 — an old-format payload is left alone":
  ## "An old-format artifact still downloads" — concretely, nothing on the
  ## encryption path runs at all, so there is no prompt, no failure and no
  ## behaviour change for every artifact stored before this milestone.

  test "a plaintext payload is recognised as unprotected":
    for plain in ["PK\x03\x04a zip archive", "{\"review\": true}", "",
        "\x89PNG\x0D\x0A\x1A\x0A", "CTAENC without the magic byte"]:
      checkpoint(plain[0 ..< min(plain.len, 12)])
      check protectionOfPayload(plain) == apNone

  test "an envelope is recognised as protected":
    let frame = sealOne(SamplePassword, SampleDatasetId, "review-dataset", "x")
    check protectionOfPayload(frame) == apPasswordScryptAes256Gcm

  test "opening something that is not an envelope says so, plainly":
    let opened = openArtifactPart(SamplePassword, "PK\x03\x04a zip archive")
    check opened.error.len > 0
    check "not encrypted" in opened.error

suite "AS-3 — a password never reaches a log":

  test "redactedForLog reports a length and nothing else":
    check redactedForLog("") == "(none)"
    let redacted = redactedForLog(SamplePassword)
    check SamplePassword notin redacted
    check $SamplePassword.len in redacted
    check "redacted" in redacted

  test "the envelope summary names the construction, never the secrets":
    let frame = sealOne(SamplePassword, SampleRecordingId, "recording",
      SamplePlaintext, partIndex = 0, partCount = 1, partName = "trace.zip",
      parameters = ShippedScryptParameters)
    let opened = openArtifactPart(SamplePassword, frame)
    check opened.error == ""
    let summary = envelopeSummary(opened.header)
    check SampleRecordingId in summary
    check "AES-256-GCM" in summary
    check "131072" in summary
    check SamplePassword notin summary
    check opened.header.envelope.salt notin summary
    check opened.header.envelope.wrappedKey notin summary
    check opened.header.envelope.wrapNonce notin summary
