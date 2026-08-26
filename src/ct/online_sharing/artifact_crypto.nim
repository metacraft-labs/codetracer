## Client-side encryption for artifact payloads (AS-3).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-3, designed in
## `codetracer-specs/Sharing/Artifact-Store.md` §10.
##
## ## What this module is
##
## The **only** place in this repository that holds an artifact's encryption
## key in plaintext, and the only place a password is turned into one.  It is
## the native half of AS-3; the claims, the prompt and the envelope's wire
## format are in `artifact_protection.nim`, which is pure and compiles on both
## Nim backends.
##
## Nothing here talks to the service, and that is the point of the split: "the
## key never reaches the service" is easier to *keep* true when the module that
## knows the key has no way to send anything.
##
## ## The construction, stated once
##
## For each sealing operation:
##
## 1. A **content-encryption key** (CEK) of 32 bytes is drawn from the
##    operating system's CSPRNG (`nimcrypto/sysrand`, which is `getrandom(2)` /
##    `/dev/urandom` on Linux, `SecRandomCopyBytes` on macOS and
##    `BCryptGenRandom` on Windows).  It is fresh for **every** operation, so
##    no key is ever used for two artifacts or twice for one.
## 2. A 32-byte salt is drawn the same way, and a **key-encryption key** (KEK)
##    is derived as `scrypt(password, salt, N = 2^17, r = 8, p = 1) → 32 bytes`
##    (RFC 7914, https://www.rfc-editor.org/rfc/rfc7914).  The parameters are
##    the OWASP Password Storage Cheat Sheet's recommendation and cost about
##    128 MiB and 0.27 s per derivation in a release build of this client.
## 3. The CEK is **wrapped**: `AES-256-GCM(KEK, random 96-bit nonce, CEK)` with
##    `keyWrapAad(envelope)` as additional data, so the wrap is bound to the
##    artifact it belongs to and to the exact KDF parameters used.  Wrapping,
##    rather than deriving the payload key from the password directly, is what
##    lets one artifact be re-shared under a different secret later without
##    re-encrypting gigabytes, and it keeps the per-part nonce schedule
##    independent of how the password was stretched.
## 4. Each payload part is sealed as
##    `AES-256-GCM(CEK, partNonce(index), plaintext)` with the part's **exact
##    header bytes** as additional data (NIST SP 800-38D,
##    https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf).
##
## ## What is authenticated, and what is not
##
## Authenticated — an attacker who alters any of it makes the client refuse,
## rather than making it accept altered content:
##
## * every byte of every part's ciphertext;
## * the whole envelope header: the artifact id, the kind, the part index, the
##   part count, the part name, the salt, the wrap nonce, the wrapped key and
##   the scrypt parameters;
## * the wrapped key, separately, against `keyWrapAad`.
##
## **Not** authenticated, and this is stated rather than glossed:
##
## * the artifact's *metadata* and access record.  Those travel in the request
##   bodies, not in the envelope, so the service can not only read them but
##   **change** them.  A client that read a *payload* out of the record would be
##   trusting them; nothing does — the bytes are what is opened.
## * **which upload** a payload came from.  Each frame is self-contained and
##   carries its own wrapped key, so a service holding two uploads of one
##   artifact id can serve the older one whole and it verifies.  Interleaving
##   the two is refused (`sameSealingOperation`); serving one entire is not.
## * **which artifact** the download was addressed to.
##   `openArtifactPayload` reports the envelope's artifact id rather than
##   refusing on a mismatch, and the reason is written out there.
##
## The **set of parts** is authenticated, and it was not always: `sliceCount`
## is in the envelope and `openArtifactPayload` checks the arrived count against
## it, which is what makes a *withheld* slice a refusal.  Per-part indices alone
## were not enough — dropping the last slice leaves a set of individually
## perfect frames that is simply shorter.
##
## ## Known limitation
##
## The AES and GHASH implementations in the vendored `nimcrypto` are
## table-driven and are therefore not hardened against cache-timing attacks by
## a *local* adversary.  The threat model AS-3 addresses is a remote holder of
## the ciphertext, for whom this is irrelevant; a local attacker who can
## measure this process's cache behaviour while it encrypts can already read
## the plaintext it is encrypting.  Recorded in `Artifact-Store.md` §8 rather
## than left for a reader to discover.

import std/[os, strutils, syncio]

import nimcrypto/[sha2, hmac, scrypt, bcmode, rijndael, sysrand]

import artifact_protection
export artifact_protection

proc readSecretFromFile*(path: string): tuple[secret: string, error: string] =
  ## Read a password from `path`, or from standard input when `path` is
  ## `SecretFromStdin`.
  ##
  ## **There is deliberately no `--password <TEXT>` flag anywhere in the CLI.**
  ## A password in `argv` is readable by every process on the machine
  ## (`/proc/<pid>/cmdline` on Linux, `ps` almost everywhere) and lands in the
  ## user's shell history; offering the flag "for convenience" would undo, at
  ## the command line, the confidentiality the rest of this milestone builds.
  ## So a password arrives either from a prompt with echo off, from a file
  ## whose permissions the user controls, or from standard input.
  ##
  ## One implementation for `ct upload` and `ct download` both, because a
  ## password file that worked for one and not the other would be a difference
  ## between the two halves of one flow.
  ##
  ## A single trailing newline is stripped, because `echo hunter2 > pw.txt` is
  ## what people actually type and an invisible `\n` would make the password
  ## wrong in a way nothing could diagnose.  Nothing else is trimmed: leading
  ## and interior whitespace are part of a password.
  var raw = ""
  let describedSource =
    if path == SecretFromStdin: "standard input" else: "'" & path & "'"
  try:
    raw = if path == SecretFromStdin: readAll(stdin) else: readFile(path)
  except CatchableError as e:
    return ("", "could not read the password from " & describedSource &
      ": " & e.msg)
  if raw.endsWith("\r\n"):
    raw.setLen(raw.len - 2)
  elif raw.endsWith("\n") or raw.endsWith("\r"):
    raw.setLen(raw.len - 1)
  if raw.len == 0:
    return ("", "the password read from " & describedSource & " is empty")
  (raw, "")

proc bareDashInArgv*(): bool =
  ## Whether a bare `-` appears on this process's command line.
  ##
  ## The observation half of `secretSource`'s `bareDashInArgv` rule: the
  ## *decision* is pure and asserted headlessly, and this is the one line that
  ## looks at the real world.  It reads `argv` rather than any parsed value
  ## because the whole problem is that the parser has already eaten the token
  ## by the time a parsed value exists.
  for parameter in commandLineParams():
    if parameter == SecretFromStdin:
      return true
  false

proc optionGivenWithoutValueInArgv*(name: string): bool =
  ## Whether `--name` appears on this process's command line with no value.
  ##
  ## **The same defect as `bareDashInArgv`, on a different option** (AS-4).
  ## `confutils` drops `--visibility=` and a bare `--visibility` before
  ## `uploadCommand` sees anything, so both resolved to `none` and the access
  ## setting the user typed was silently the default. Measured against the
  ## shipped binary, not inferred: `--visibility=` uploaded with
  ## `"visibility":"tenant"` and exit 0.
  ##
  ## The observation only; the **rule** is
  ## `artifact_protection.optionGivenWithoutValue`, which is pure and asserted
  ## headlessly — including the case that matters most, `--visibility <VALUE>`
  ## with a perfectly good value, which an earlier version of this guard
  ## refused because it matched the bare token and never looked at the next one.
  ##
  ## It reads `argv` for the same reason `bareDashInArgv` does: the whole
  ## problem is that the parser has already eaten the token by the time a
  ## parsed value exists. Not fixable in `libs/nim-confutils` — that submodule
  ## is pinned, and a client-side refusal is the smaller change.
  optionGivenWithoutValue(commandLineParams(), name)

type
  ArtifactSeal* = object
    ## A prepared encryption: the envelope that will be written into every
    ## part, and the content key those parts are sealed with.
    ##
    ## `contentKey` is the secret this whole milestone is about.  It is held in
    ## an ordinary string because Nim gives no locked-memory primitive here;
    ## `wipe` overwrites it when the caller is done, which stops it outliving
    ## the upload in a reused heap block.  It is never serialised, never
    ## logged, and never a field of anything that reaches `api_client.nim`.
    envelope*: ArtifactEnvelope
    contentKey*: string

  ArtifactSealResult* = object
    seal*: ArtifactSeal
    error*: string
      ## Empty iff the seal is usable.

  ArtifactOpenResult* = object
    plaintext*: string
    header*: ArtifactEnvelopeHeader
    error*: string

proc wipe*(seal: var ArtifactSeal) =
  ## Overwrite the content key in place.
  ##
  ## Best effort, and said to be best effort: Nim's garbage collector may have
  ## copied the string, and the operating system may have paged it out.  It
  ## still removes the most likely way a key outlives its use — a heap block
  ## reused by the next allocation in the same process.
  for i in 0 ..< seal.contentKey.len:
    seal.contentKey[i] = '\0'
  seal.contentKey.setLen(0)

proc randomString(length: int): tuple[value: string, error: string] =
  ## `length` bytes from the operating system's CSPRNG.
  ##
  ## A short read is a **hard error**, never a shorter key: `randomBytes`
  ## returns -1 when the platform source failed, and silently continuing there
  ## would produce a key made of whatever the buffer happened to contain.
  var buffer = newSeq[byte](length)
  let produced = randomBytes(buffer)
  if produced != length:
    return ("", "the operating system's random number generator returned " &
      $produced & " of " & $length & " requested bytes")
  var value = newString(length)
  for i in 0 ..< length:
    value[i] = chr(int(buffer[i]))
  (value, "")

proc toByteSeq(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc toStringBytes(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = chr(int(b[i]))

proc deriveKeyEncryptionKey(password, salt: string, n, r, p: int):
    tuple[key: string, error: string] =
  ## `scrypt(password, salt, n, r, p) → 32 bytes` (RFC 7914).
  ##
  ## The parameters are re-validated here even though the caller has usually
  ## validated them already, because this is the procedure that turns them into
  ## an allocation: `scryptCalc(2^40, 8, 1)` asks for terabytes, and the
  ## parameters on the opening path come from a file that has not been
  ## authenticated yet (it cannot be — these numbers are what the
  ## authentication needs).
  let problem = scryptParametersProblem(n, r, p)
  if problem.len > 0:
    return ("", problem)
  let (xyvLen, bLen) = scryptCalc(n, r, p)
  var xyv = newSeq[uint32](xyvLen)
  var b = newSeq[byte](bLen)
  var output = newSeq[byte](ArtifactEnvelopeKeyBytes)
  let produced = scrypt(password, salt, n, r, p, xyv, b, output)
  if produced != ArtifactEnvelopeKeyBytes:
    return ("", "key derivation failed (scrypt produced " & $produced &
      " of " & $ArtifactEnvelopeKeyBytes & " bytes)")
  (toStringBytes(output), "")

proc gcmSeal(key, nonce, aad, plaintext: string): string =
  ## `ciphertext ‖ tag`, AES-256-GCM.  The tag is appended rather than carried
  ## separately, and it is never truncated: SP 800-38D §5.2.1.2 permits shorter
  ## tags and §C.1 explains what they cost, and there is no reason here to pay
  ## it.
  var ctx: GCM[aes256]
  var ciphertext = newSeq[byte](plaintext.len)
  ctx.init(toByteSeq(key), toByteSeq(nonce), toByteSeq(aad))
  ctx.encrypt(toByteSeq(plaintext), ciphertext)
  let tag = ctx.getTag()
  ctx.clear()
  result = toStringBytes(ciphertext) & toStringBytes(tag)

proc constantTimeEquals(a, b: string): bool =
  ## Compare two authentication tags without an early exit.
  ##
  ## A `==` on strings returns as soon as it finds a difference, which leaks
  ## how many leading bytes of a forged tag were right and turns a 2^128 forgery
  ## into 16 sequential 2^8 searches against an oracle that will tell you.  The
  ## fold below always reads every byte.
  if a.len != b.len:
    return false
  var difference = 0
  for i in 0 ..< a.len:
    difference = difference or (int(uint8(a[i])) xor int(uint8(b[i])))
  difference == 0

proc gcmOpen(key, nonce, aad, sealed: string):
    tuple[plaintext: string, ok: bool] =
  ## The inverse of `gcmSeal`, refusing when the tag does not verify.
  ##
  ## The plaintext is discarded on a tag failure and an empty string is
  ## returned with `ok = false`.  Returning unverified plaintext "so the caller
  ## can decide" is the mistake that makes an AEAD no better than a stream
  ## cipher, so the decision is not offered.
  if sealed.len < ArtifactEnvelopeTagBytes:
    return ("", false)
  let ciphertext = sealed[0 ..< sealed.len - ArtifactEnvelopeTagBytes]
  let expectedTag = sealed[sealed.len - ArtifactEnvelopeTagBytes .. ^1]
  var ctx: GCM[aes256]
  var plaintext = newSeq[byte](ciphertext.len)
  ctx.init(toByteSeq(key), toByteSeq(nonce), toByteSeq(aad))
  ctx.decrypt(toByteSeq(ciphertext), plaintext)
  let actualTag = toStringBytes(ctx.getTag())
  ctx.clear()
  if not constantTimeEquals(actualTag, expectedTag):
    for i in 0 ..< plaintext.len:
      plaintext[i] = 0
    return ("", false)
  (toStringBytes(plaintext), true)

proc newArtifactSeal*(password, artifactId, kindToken: string,
    sliceCount: int,
    parameters: ArtifactScryptParameters = ShippedScryptParameters):
    ArtifactSealResult =
  ## Prepare to encrypt one artifact under `password`.
  ##
  ## Every call produces a **new** content key, a new salt and a new wrap
  ## nonce, even for the same artifact and the same password.  That is what
  ## makes the deterministic per-part nonce schedule safe: re-uploading an
  ## artifact does not re-use a (key, nonce) pair, because it does not re-use
  ## the key.
  ##
  ## `parameters` defaults to `ShippedScryptParameters` and every product call
  ## site takes that default — `artifact_store.prepareProtectedPayload` is the
  ## only one, and `artifact_store_roundtrip_test.nim` pins the value that
  ## reaches the wire.  It is a parameter because the *opening* side must
  ## already honour the whole accepted range, and a sealer that could only
  ## produce one point in it leaves the rest of that range untested.
  let parameterProblem = scryptParametersProblem(
    parameters.n, parameters.r, parameters.p)
  if parameterProblem.len > 0:
    return ArtifactSealResult(error: parameterProblem)
  if password.len == 0:
    return ArtifactSealResult(error:
      "refusing to encrypt with an empty password")
  if artifactId.len == 0:
    return ArtifactSealResult(error:
      "refusing to encrypt an artifact with no id: the id is bound into the " &
      "authentication tag, so it cannot be filled in afterwards")
  if sliceCount < 1:
    return ArtifactSealResult(error:
      "refusing to encrypt a payload that reassembles from " & $sliceCount &
      " slice(s)")

  let contentKey = randomString(ArtifactEnvelopeKeyBytes)
  if contentKey.error.len > 0:
    return ArtifactSealResult(error: contentKey.error)
  let salt = randomString(ArtifactEnvelopeSaltBytes)
  if salt.error.len > 0:
    return ArtifactSealResult(error: salt.error)
  let wrapNonce = randomString(ArtifactEnvelopeNonceBytes)
  if wrapNonce.error.len > 0:
    return ArtifactSealResult(error: wrapNonce.error)

  var envelope = ArtifactEnvelope(
    version: int(ArtifactEnvelopeVersion),
    cipher: ArtifactEnvelopeCipher,
    kdf: ArtifactEnvelopeKdf,
    scryptN: parameters.n,
    scryptR: parameters.r,
    scryptP: parameters.p,
    salt: salt.value,
    wrapNonce: wrapNonce.value,
    wrappedKey: "",
    artifactId: artifactId,
    kindToken: kindToken,
    sliceCount: sliceCount)

  let kek = deriveKeyEncryptionKey(password, envelope.salt,
    envelope.scryptN, envelope.scryptR, envelope.scryptP)
  if kek.error.len > 0:
    return ArtifactSealResult(error: kek.error)
  envelope.wrappedKey = gcmSeal(
    kek.key, envelope.wrapNonce, keyWrapAad(envelope), contentKey.value)

  ArtifactSealResult(seal: ArtifactSeal(
    envelope: envelope, contentKey: contentKey.value))

proc partHeader*(seal: ArtifactSeal, partIndex, partCount: int,
    partName: string, plaintextSize: int): ArtifactEnvelopeHeader =
  ## The header that will sit in front of, and authenticate, one part.
  ##
  ## `sealedBytes` is derived rather than passed separately: AES-GCM is a
  ## stream mode, so the ciphertext is exactly the plaintext's length and the
  ## frame is that plus the tag.  Deriving it here is what keeps the size this
  ## header *declares* and the size the sealing *produces* the same number by
  ## construction rather than by two callers agreeing.
  ArtifactEnvelopeHeader(
    envelope: seal.envelope,
    partIndex: partIndex,
    partCount: partCount,
    partName: partName,
    sealedBytes: plaintextSize + ArtifactEnvelopeTagBytes)

proc sealedPartSize*(seal: ArtifactSeal, partIndex, partCount: int,
    partName: string, plaintextSize: int64): int64 =
  ## How large a part becomes once sealed, computed **without** sealing it.
  ##
  ## This exists because the upload tells the service each part's content
  ## length before it sends the bytes, and the plan is validated against the
  ## artifact's declared payload size.  Both numbers must be the sealed size,
  ## and both are computed here from the same header-producing function the
  ## sealing itself uses — so they cannot disagree.
  plaintextSize + int64(envelopeOverheadBytes(envelopeHeaderJson(
    partHeader(seal, partIndex, partCount, partName, plaintextSize.int))))

proc sealArtifactPart*(seal: ArtifactSeal, partIndex, partCount: int,
    partName, plaintext: string): tuple[frame: string, error: string] =
  ## Seal one part into a complete envelope frame.
  if seal.contentKey.len != ArtifactEnvelopeKeyBytes:
    return ("", "the artifact seal has no content key")
  if partIndex < 0 or partCount < 1 or partIndex >= partCount:
    return ("", "refusing to seal part " & $partIndex & " of " & $partCount)
  let headerJson = envelopeHeaderJson(
    partHeader(seal, partIndex, partCount, partName, plaintext.len))
  # The header IS the additional authenticated data — see the module comment
  # in `artifact_protection.nim` for the list of what that covers.
  let sealed = gcmSeal(
    seal.contentKey, partNonce(partIndex), headerJson, plaintext)
  (encodeEnvelopeFrame(headerJson, sealed), "")

proc openArtifactPart*(password, frame: string,
    expectedArtifactId: string = "",
    expectedPartIndex: int = -1): ArtifactOpenResult =
  ## Recover one part's plaintext from an envelope frame.
  ##
  ## `expectedArtifactId` and `expectedPartIndex` are checked **after** the
  ## authentication tag verifies, and refusing on a mismatch is not
  ## belt-and-braces: without it, a service holding two artifacts a user
  ## encrypted with the same password could serve one in place of the other and
  ## every tag would verify, because both were genuinely produced by that user.
  ## Binding the identity into the AAD is what makes the substitution
  ## detectable; checking it here is what makes it detected.
  let frameParse = decodeEnvelopeFrame(frame)
  if not frameParse.isEnvelope:
    return ArtifactOpenResult(error:
      "this payload is not encrypted, so there is nothing to decrypt")
  if frameParse.error.len > 0:
    return ArtifactOpenResult(error: frameParse.error)
  let header = frameParse.header

  if password.len == 0:
    return ArtifactOpenResult(error:
      "this artifact is encrypted and no password was supplied")

  let kek = deriveKeyEncryptionKey(password, header.envelope.salt,
    header.envelope.scryptN, header.envelope.scryptR, header.envelope.scryptP)
  if kek.error.len > 0:
    return ArtifactOpenResult(error: kek.error)

  let unwrapped = gcmOpen(kek.key, header.envelope.wrapNonce,
    keyWrapAad(header.envelope), header.envelope.wrappedKey)
  if not unwrapped.ok:
    # A wrong password and a tampered key wrap are indistinguishable here, and
    # deliberately so: the tag is the only evidence either way.  The message
    # names the likely cause first because it is overwhelmingly the common one,
    # and names the other so a user is not told "wrong password" about a file
    # somebody rewrote.
    return ArtifactOpenResult(error:
      "wrong password for this artifact (or its encryption header has been " &
      "altered)")
  var contentKey = unwrapped.plaintext

  let headerJson = frameParse.headerJson
  let opened = gcmOpen(contentKey, partNonce(header.partIndex), headerJson,
    frameParse.sealedPayload)
  for i in 0 ..< contentKey.len:
    contentKey[i] = '\0'
  if not opened.ok:
    return ArtifactOpenResult(error:
      "this artifact's encrypted payload failed its integrity check: the " &
      "stored bytes have been altered since they were uploaded")

  if expectedArtifactId.len > 0 and
      header.envelope.artifactId != expectedArtifactId:
    return ArtifactOpenResult(error:
      "refusing this payload: it was encrypted for artifact '" &
      header.envelope.artifactId & "', and '" & expectedArtifactId &
      "' was asked for")
  if expectedPartIndex >= 0 and header.partIndex != expectedPartIndex:
    return ArtifactOpenResult(error:
      "refusing this payload: it is part " & $header.partIndex &
      " and part " & $expectedPartIndex & " was asked for")

  ArtifactOpenResult(plaintext: opened.plaintext, header: header)

proc sameSealingOperation(a, b: ArtifactEnvelope): bool =
  ## Whether two frames were produced by **one** call to `newArtifactSeal`.
  ##
  ## Every field compared here is freshly generated per sealing operation or is
  ## a property of the artifact, so two different operations agree on all of
  ## them only with negligible probability: the salt and the wrap nonce are 32
  ## and 12 random bytes, and the wrapped key is a GCM output over a fresh
  ## content key.
  ##
  ## This is what makes a **mix-and-match** reassembly detectable. Each frame is
  ## self-contained and carries its own wrapped key, so nothing in the AEAD
  ## alone binds a part to a particular *upload*: a service holding two uploads
  ## of one artifact id could otherwise interleave their slices and every tag
  ## would verify, because the user really did seal all of them. Requiring one
  ## envelope across the whole payload is the binding the frames do not have.
  a.salt == b.salt and a.wrapNonce == b.wrapNonce and
    a.wrappedKey == b.wrappedKey and a.artifactId == b.artifactId and
    a.kindToken == b.kindToken and a.sliceCount == b.sliceCount and
    a.scryptN == b.scryptN and a.scryptR == b.scryptR and
    a.scryptP == b.scryptP and a.version == b.version and
    a.cipher == b.cipher and a.kdf == b.kdf

proc openArtifactPayload*(password, bytes: string): ArtifactOpenResult =
  ## Recover a whole payload's plaintext from a **reassembled** download.
  ##
  ## This is the procedure the download path uses, and it exists because
  ## `openArtifactPart` was the wrong shape for it. A sliced upload publishes
  ## one envelope per part and the service reassembles the payload by
  ## concatenating the slices — so what `…/download-url` hands back for a
  ## sliced artifact is *n* frames end to end, not one. Treating that as a
  ## single frame produced "the stored bytes have been altered since they were
  ## uploaded" for an artifact nobody had touched: a false and alarming message
  ## on the recording kind's **normal** shape.
  ##
  ## A single-file artifact is the one-frame case of the same walk, so there is
  ## one code path rather than a special case per layout — which is the same
  ## reason `storeArtifact` dispatches on layout and not on kind.
  ##
  ## Four things are checked across the frames, and each of them makes a
  ## sentence in `Artifact-Store.md` §10.3 true rather than aspirational:
  ##
  ## * **the indices are `0, 1, 2, …`** — a reordered payload is refused;
  ## * **there are exactly `sliceCount` of them** — a *withheld* slice is
  ##   refused rather than reassembled short, which a per-frame check cannot
  ##   see because each surviving frame is individually perfect;
  ## * **every frame is from one sealing operation** — a mix-and-match set is
  ##   refused (`sameSealingOperation`);
  ## * **nothing follows the last frame** — trailing bytes are refused rather
  ##   than ignored.
  ##
  ## The password is stretched **once** for the whole payload, not once per
  ## frame: the content key is shared, so a five-slice recording costs one
  ## scrypt derivation rather than five.
  ##
  ## ## What it deliberately does NOT check, and why
  ##
  ## It does **not** refuse when the envelope's `artifactId` differs from the
  ## id the caller asked the service for, and that is a disclosure rather than
  ## an omission (`Artifact-Store.md` §10.3, and §8 defect 18).
  ##
  ## The sealing happens before the upload, so the envelope carries the id the
  ## *client* knows. For a **sliced recording** the service may not carry that
  ## id at all — the kind's frozen `…/upload-session` body has no room for it
  ## (§9.5), so the service names the result itself — and the share link is
  ## then built from the service's name. Refusing on the mismatch would make
  ## an encrypted sliced recording unopenable through its own link: a trap,
  ## and on the recording kind's *normal* shape.
  ##
  ## So the identity is carried in the AAD, where it stops an attacker
  ## *editing* it, and the envelope's id is returned to the caller
  ## (`header.envelope.artifactId`) to be reported rather than enforced. The
  ## caller that genuinely knows the id — `openArtifactPart`, which callers use
  ## when they minted it themselves — still enforces equality.
  ##
  ## What remains enforceable, and is enforced, is internal consistency: one
  ## sealing operation, contiguous indices, the full authenticated count. The
  ## residual is that a service could serve a *different* artifact the same
  ## user sealed with the same password. That is the same class and the same
  ## bound as the replay residual §10.3 lists: the plaintext a user could be
  ## shown is always their own.
  if not looksLikeEnvelope(bytes):
    return ArtifactOpenResult(error:
      "this payload is not encrypted, so there is nothing to decrypt")
  if password.len == 0:
    return ArtifactOpenResult(error:
      "this artifact is encrypted and no password was supplied")

  var offset = 0
  var frameIndex = 0
  var plaintext = ""
  var contentKey = ""
  var first: ArtifactEnvelopeHeader
  var haveFirst = false

  while offset < bytes.len:
    let frame = decodeEnvelopeFrame(bytes, offset)
    if not frame.isEnvelope:
      # Bytes that are not a frame, where a frame was expected. Reported with
      # the position, because on a reassembled payload "where" is the whole
      # diagnosis.
      for i in 0 ..< contentKey.len: contentKey[i] = '\0'
      return ArtifactOpenResult(error:
        "this artifact's encrypted payload has " & $(bytes.len - offset) &
        " trailing byte(s) after slice " & $frameIndex &
        " that are not part of it")
    if frame.error.len > 0:
      for i in 0 ..< contentKey.len: contentKey[i] = '\0'
      return ArtifactOpenResult(error: frame.error)

    if not haveFirst:
      first = frame.header
      haveFirst = true
      let kek = deriveKeyEncryptionKey(password, first.envelope.salt,
        first.envelope.scryptN, first.envelope.scryptR, first.envelope.scryptP)
      if kek.error.len > 0:
        return ArtifactOpenResult(error: kek.error)
      let unwrapped = gcmOpen(kek.key, first.envelope.wrapNonce,
        keyWrapAad(first.envelope), first.envelope.wrappedKey)
      if not unwrapped.ok:
        return ArtifactOpenResult(error:
          "wrong password for this artifact (or its encryption header has " &
          "been altered)")
      contentKey = unwrapped.plaintext
    elif not sameSealingOperation(first.envelope, frame.header.envelope):
      for i in 0 ..< contentKey.len: contentKey[i] = '\0'
      return ArtifactOpenResult(error:
        "refusing this payload: slice " & $frameIndex &
        " was encrypted in a different upload from slice 0, so these are " &
        "not the pieces of one artifact")

    if frame.header.partIndex != frameIndex:
      for i in 0 ..< contentKey.len: contentKey[i] = '\0'
      return ArtifactOpenResult(error:
        "refusing this payload: slice " & $frameIndex &
        " of the download says it is part " & $frame.header.partIndex)

    let opened = gcmOpen(contentKey, partNonce(frame.header.partIndex),
      frame.headerJson, frame.sealedPayload)
    if not opened.ok:
      for i in 0 ..< contentKey.len: contentKey[i] = '\0'
      return ArtifactOpenResult(error:
        "this artifact's encrypted payload failed its integrity check: the " &
        "stored bytes have been altered since they were uploaded")
    plaintext.add opened.plaintext
    inc frameIndex
    offset = frame.nextOffset

  for i in 0 ..< contentKey.len:
    contentKey[i] = '\0'

  if frameIndex != first.envelope.sliceCount:
    # The check a per-frame reader cannot make. Every surviving frame is
    # individually perfect, so only the authenticated COUNT distinguishes "the
    # payload" from "most of the payload".
    return ArtifactOpenResult(error:
      "this artifact's encrypted payload is incomplete: it reassembles from " &
      $first.envelope.sliceCount & " slice(s) and only " & $frameIndex &
      " arrived")

  ArtifactOpenResult(plaintext: plaintext, header: first)

proc envelopeSummary*(header: ArtifactEnvelopeHeader): string =
  ## A one-line description of an envelope, for diagnostics.  Names the
  ## construction and the artifact; **never** the salt, the wrapped key or
  ## anything derived from the password.
  "AES-256-GCM payload for artifact " & header.envelope.artifactId &
    " (" & header.envelope.kindToken & "), part " & $header.partIndex &
    " of " & $header.partCount & ", key from scrypt N=" &
    $header.envelope.scryptN & " r=" & $header.envelope.scryptR &
    " p=" & $header.envelope.scryptP

proc protectionOfPayload*(bytes: string): ArtifactProtection =
  ## What protection the payload in `bytes` actually carries, read from the
  ## bytes themselves rather than from what any record claims.
  ##
  ## The download path decides with this, and the reason it consults the bytes
  ## is that a service deployed before AS-3 returns no artifact record at all —
  ## and a record, when there is one, is something the service says.
  if looksLikeEnvelope(bytes): apPasswordScryptAes256Gcm else: apNone

proc redactedForLog*(value: string): string =
  ## What a secret looks like when something insists on printing one.
  ##
  ## Exists so there is a right answer close to hand: the sharing path's
  ## progress narration is an `echo`, and the distance between "log the upload
  ## parameters" and "log the password" is one careless line.
  if value.len == 0: "(none)" else: "(" & $value.len & " characters, redacted)"
