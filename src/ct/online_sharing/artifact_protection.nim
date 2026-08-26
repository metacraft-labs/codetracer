## Artifact protection: what confidentiality an artifact carries, and the
## wire format of the envelope that carries it (AS-3).
##
## `codetracer-specs/Sharing/Artifact-Store.milestones.org` AS-3, designed in
## `codetracer-specs/Sharing/Artifact-Store.md` §10.
##
## ## What this module is, and what it is not
##
## This is the **pure** half of AS-3: the closed set of protections, what each
## one honestly claims, the prompt a user is shown before choosing one, and the
## byte layout of the envelope a protected payload is wrapped in.  It performs
## **no cryptography**.  The primitives live in `artifact_crypto.nim`, which is
## native-only because it needs the operating system's CSPRNG and a block
## cipher; everything here compiles on both Nim backends so the *claims* — which
## are the part a user reads and the part that must not overstate — are
## assertable in the headless ViewModel lane.
##
## Splitting it this way is not tidiness.  The sentence "encrypted" is a
## promise, and the place a promise is written must be reachable by a test that
## does not need a socket, a file or an OS.
##
## ## The claim this module is built to keep honest
##
## AS-3's first deliverable says client-side encryption "with the key never
## reaching the service — otherwise 'encrypted' means 'encrypted from everyone
## except us', which must not be implied if it is not true."  So every
## protection is a **row in a registry** that must state, in fields rather than
## in prose:
##
## * whether the payload is encrypted (`encryptsPayload`);
## * whether the **metadata** is (`encryptsMetadata` — `false` for everything
##   AS-3 ships, and the UI copy says so);
## * whether the secret ever leaves this machine (`secretReachesService` —
##   `false` for everything, and `everyProtectionKeepsTheSecretLocal` asserts
##   it, so a future escrow scheme cannot be added without changing a flag that
##   several user-visible strings are derived from);
## * what it protects against, what it does not, and what recovery exists.
##
## The registry is `array[ArtifactProtection, ArtifactProtectionSpec]`, indexed
## by the enum, exactly like `ArtifactKindRegistry`: a protection value without
## a row does not compile.  That is the property AS-1's one-value cardinality
## assertion was standing in for, and it is strictly stronger — counting the
## enum tells you *that* somebody widened it, the registry makes them say what
## they widened it to *mean*.
##
## ## The envelope
##
## A protected payload part is stored as
##
##     magic | version | headerLen | header | ciphertext‖tag
##
## and nothing about the transfer changes: the service receives opaque bytes at
## the same URLs, in the same order, with the same request bodies.  That is the
## reason the envelope is in the *payload* rather than in the artifact record —
## the recording kind's request bodies are frozen (AS-1's compatibility
## guarantee), so an envelope carried in a request body could not have been
## expressed for that kind at all, and AS-3 would have shipped encryption for
## one kind and a plan for the other.
##
## The header is ASCII JSON and is used **verbatim as the AEAD's additional
## authenticated data**, so every field in it — the artifact id, the kind, the
## slice count, the part index, the part count, the part name, the frame's own
## length and the KDF parameters — is covered by the authentication tag.  An
## attacker who can rewrite stored bytes therefore cannot swap one part for
## another, re-attribute a part to a different artifact, drop a slice from a
## reassembled payload, or lower the KDF's work factor, without the client
## refusing.
##
## A **reassembled** payload is a concatenation of frames: a sliced upload
## publishes one envelope per part and the service puts the slices back
## together, so what a download hands back is *n* frames end to end.  That is
## why the frame's own length lives in the header (`sealedBytes`) rather than in
## an outer field — the boundary between one frame and the next is under the
## tag — and why `artifact_crypto.openArtifactPayload`, not `openArtifactPart`,
## is what the download path uses.
##
## References:
## * NIST SP 800-38D (GCM, and the nonce-uniqueness requirement):
##   https://nvlpubs.nist.gov/nistpubs/Legacy/SP/nistspecialpublication800-38d.pdf
## * RFC 7914 (scrypt): https://www.rfc-editor.org/rfc/rfc7914
## * NIST SP 800-63B §5.1.1.2 (password rules — length floor, no composition
##   rules): https://pages.nist.gov/800-63-3/sp800-63b.html
## * OWASP Password Storage Cheat Sheet (the scrypt work factors chosen below):
##   https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html

import std/[base64, json, strutils]

# ---------------------------------------------------------------------------
# The closed set of protections
# ---------------------------------------------------------------------------

type
  ArtifactProtection* = enum
    ## Confidentiality applied to the payload **before** it reaches the
    ## service.
    ##
    ## Closed, and read from untrusted input only through
    ## `artifact.readClosedEnumField`, which refuses an unrecognised token
    ## rather than substituting a default.  That refusal is what makes it safe
    ## for this enum to grow: a client built before a protection existed meets
    ## a record declaring it and **refuses the record**, rather than reading an
    ## encrypted artifact as plaintext-safe.  See `Artifact-Store.md` §8 defect
    ## 10, closed by AS-2 precisely so AS-3 could land here.
    apNone = "none"
      ## No confidentiality from the service.  TLS in transit and a bearer
      ## token for access, and nothing else.  This is what every artifact
      ## stored before AS-3 carries, and it is the default.
    apPasswordScryptAes256Gcm = "password-scrypt-aes-256-gcm"
      ## Client-side authenticated encryption under a key derived from a
      ## password that never leaves this machine.
      ##
      ## The token names the construction rather than saying "encrypted",
      ## deliberately: it is a **version marker**.  If the construction is ever
      ## replaced — a different AEAD, a different KDF — that is a new token, and
      ## every client that predates it refuses records declaring it instead of
      ## trying to open them with the wrong primitive.

  ArtifactProtectionSpec* = object
    ## One row of the closed protection registry.
    ##
    ## Fields rather than prose, because these are the sentences a user is
    ## shown and the ones a reviewer checks.  A protection that cannot fill
    ## them in has not been thought through.
    protection*: ArtifactProtection
    wireToken*: string
      ## Equal to `$protection`; held explicitly so the registry is
      ## self-describing when dumped.
    encryptsPayload*: bool
      ## Whether the bytes the service stores are ciphertext.
    encryptsMetadata*: bool
      ## Whether the artifact's **metadata** is also unreadable by the service.
      ## `false` for everything AS-3 ships — see `whatItDoesNotProtect`, and
      ## `artifact.serviceVisibleMetadataFields` for the exact list.
    secretReachesService*: bool
      ## Whether the secret needed to read the payload is ever sent.  `false`
      ## for every row, asserted by `everyProtectionKeepsTheSecretLocal`.
    requiresSecretToRead*: bool
      ## Whether a reader must supply something beyond their bearer token.
    authenticated*: bool
      ## Whether altered ciphertext is *detected* rather than silently
      ## decrypted into wrong plaintext.
    headline*: string
      ## One line, in the user's terms, stating what this is.
    whatItProtectsAgainst*: string
    whatItDoesNotProtect*: string
    recoveryWhenSecretLost*: string
      ## Shown **before** the choice is made, not after.  For a scheme with no
      ## recovery this says so plainly; "nothing" is an acceptable answer and an
      ## unacceptable surprise.

const
  ArtifactProtectionRegistry*: array[ArtifactProtection,
      ArtifactProtectionSpec] = [
    apNone: ArtifactProtectionSpec(
      protection: apNone,
      wireToken: "none",
      encryptsPayload: false,
      encryptsMetadata: false,
      secretReachesService: false,
        # There is no secret at all, so there is nothing to send.  The flag is
        # about what the scheme *does*, not about what it happens to have.
      requiresSecretToRead: false,
      authenticated: false,
      headline: "Not encrypted by CodeTracer.",
      whatItProtectsAgainst:
        "Nothing on its own. Access is controlled by the bearer token and the " &
        "owning tenant, and the transfer itself is protected by TLS.",
      whatItDoesNotProtect:
        "The service can read the payload and its metadata. Anyone who can " &
        "read the stored copy — the operator, a backup, a compromised " &
        "bucket — can read what you shared.",
      recoveryWhenSecretLost:
        "Not applicable: there is no secret to lose."),
    apPasswordScryptAes256Gcm: ArtifactProtectionSpec(
      protection: apPasswordScryptAes256Gcm,
      wireToken: "password-scrypt-aes-256-gcm",
      encryptsPayload: true,
      encryptsMetadata: false,
      secretReachesService: false,
      requiresSecretToRead: true,
      authenticated: true,
      headline:
        "Encrypted on this computer with your password. CodeTracer never " &
        "sends the password or the key.",
      whatItProtectsAgainst:
        "Anyone who can read the stored copy without knowing your password — " &
        "including CodeTracer and whoever operates the service, a stolen " &
        "backup, or a leaked share link. They get bytes they cannot open, " &
        "and bytes they cannot alter without the change being detected.",
      whatItDoesNotProtect:
        "The metadata is NOT encrypted. The service still sees which kind of " &
        "artifact this is, its size, its file names and the fields listed " &
        "under 'what stays visible' — for a review dataset that includes the " &
        "commit it describes — and it can CHANGE them, because only the " &
        "payload is covered by the authentication tag. It also does not " &
        "protect against someone who learns the password, and it does not " &
        "stop the service from deleting the copy or serving you an older " &
        "upload of the same artifact.",
      recoveryWhenSecretLost:
        "Nothing. The password is never sent anywhere and no copy of the key " &
        "is kept, so if you lose the password the artifact cannot be " &
        "recovered by you, by anyone you shared it with, or by CodeTracer. " &
        "Store it somewhere you will still have it later."),
  ]

proc protectionSpec*(protection: ArtifactProtection): ArtifactProtectionSpec =
  ## The registry row for `protection`.  Total: the array is indexed by the
  ## enum, so a protection without a row does not compile.
  ArtifactProtectionRegistry[protection]

proc everyProtectionKeepsTheSecretLocal*(): bool =
  ## Whether **no** declared protection sends its secret to the service.
  ##
  ## True today, and the assertion that it is true is what makes "the key never
  ## reaches the service" a property of the *design* rather than of the one
  ## scheme that happens to exist.  A future escrow scheme would have to set
  ## `secretReachesService: true`, which makes this false, which fails a test
  ## and forces the user-visible strings to be rewritten before it ships.
  for protection in ArtifactProtection:
    if ArtifactProtectionRegistry[protection].secretReachesService:
      return false
  true

proc protectionRequiresSecret*(protection: ArtifactProtection): bool =
  ## Whether storing or reading under `protection` needs a secret from the
  ## user.  The one call both the CLI and AS-4's dialog make to decide whether
  ## to ask, so neither can decide differently.
  ArtifactProtectionRegistry[protection].requiresSecretToRead

# ---------------------------------------------------------------------------
# The prompt — one dialog, whatever the kind
# ---------------------------------------------------------------------------

type
  ArtifactProtectionPrompt* = object
    ## Everything a password dialog (or a CLI equivalent) must show, derived
    ## from the protection and from **one noun** naming what is being shared.
    ##
    ## AS-3's second deliverable asks for a dialog and a flow that are
    ## identical whatever the kind.  The way that is guaranteed here is by
    ## construction: this record is a function of `(protection, subjectNoun)`,
    ## so two kinds can differ only in the noun, and
    ## `artifact_protection_vm_test.nim` asserts that substituting the noun is
    ## the *only* difference between any two kinds' prompts.
    headline*: string
    protectsAgainst*: string
    doesNotProtect*: string
    recoveryNotice*: string
    metadataNotice*: string
      ## What the service still sees.  Kept as its own line rather than folded
      ## into `doesNotProtect` because it is the question AS-1 §6 explicitly
      ## deferred to this milestone, and a user scanning a dialog should not
      ## have to find it inside a paragraph.
    confirmRequired*: bool
      ## Whether the password must be typed twice.  True whenever losing it is
      ## unrecoverable, which is the only situation in which a typo is
      ## permanent.
    action*: string
      ## The button/verb, with the subject in it.

const
  MetadataStillVisibleNotice* =
    "The payload is encrypted, but its metadata is not: CodeTracer still " &
    "tells the service what kind of artifact this is, how big it is, what " &
    "its files are called, and the fields listed above."
    ## The one place this sentence is written.  §10.4 of the design lists the
    ## fields; this is the sentence that points at the list.

proc protectionPrompt*(protection: ArtifactProtection,
    subjectNoun: string): ArtifactProtectionPrompt =
  ## The dialog for `protection`, about a `subjectNoun`.
  ##
  ## The only kind-dependent input is the noun, and it appears only in
  ## `action`.  Everything a user is told about what the protection does, does
  ## not do, and cannot recover from is identical for every kind, because it is
  ## a property of the protection and not of what is being protected.
  let spec = protectionSpec(protection)
  ArtifactProtectionPrompt(
    headline: spec.headline,
    protectsAgainst: spec.whatItProtectsAgainst,
    doesNotProtect: spec.whatItDoesNotProtect,
    recoveryNotice: spec.recoveryWhenSecretLost,
    metadataNotice:
      if spec.encryptsPayload and not spec.encryptsMetadata:
        MetadataStillVisibleNotice
      else:
        "",
    confirmRequired: spec.requiresSecretToRead,
    action:
      if spec.requiresSecretToRead:
        "Encrypt and upload this " & subjectNoun
      else:
        "Upload this " & subjectNoun)

const
  MinimumPasswordLength* = 8
    ## NIST SP 800-63B §5.1.1.2: a length floor and **no** composition rules.
    ## Eight is that document's minimum for a user-chosen secret.  There is
    ## deliberately no maximum, no required character classes and no breached-
    ## password check — the last is a service the client does not have, and
    ## claiming a strength check that is not performed is the kind of implied
    ## capability this campaign exists to avoid.

type
  PasswordChoiceProblem* = enum
    ## Why a chosen password was refused.  An enum rather than a bare string so
    ## a UI can react to the *reason* (highlight which field) while the CLI
    ## prints the message.
    pcpNone = "none"
    pcpEmpty = "empty"
    pcpTooShort = "too-short"
    pcpMismatch = "mismatch"

const
  SecretFromStdin* = "-"
    ## The internal spelling of "read the password from standard input".
    ##
    ## **Not a user-facing spelling, and that is a correction.**
    ## `--password-file -` was one, and it was a defect found by running the
    ## shipped binary rather than by reading the source: with a value-taking
    ## option a bare `-` is parsed as the start of another option, so the
    ## password silently arrived as *nothing*.  Under `--encrypt` that reported
    ## "there is no terminal to ask on"; **without** `--encrypt` it skipped the
    ## refusal that exists to stop somebody uploading in the clear while
    ## believing otherwise — a silent failure in the unsafe direction.  The CLI
    ## now spells it `--password-stdin`, a boolean flag that cannot be
    ## swallowed, and this constant is what that flag resolves to.

proc secretSource*(fromStdin: bool, file: string,
    bareDashInArgv = false): tuple[path: string, error: string] =
  ## Which source a password should be read from, or why that is ambiguous.
  ##
  ## One resolver for `ct upload` and `ct download` both, so the two halves of
  ## one flow cannot accept different combinations of the same two options.
  ## Pure, so the whole table is assertable headlessly with nothing on disk —
  ## which is the point, given that the bug it replaces was a *parsing*
  ## outcome that no test looked at.
  ##
  ## An empty `path` with an empty error means "no password was named", which
  ## is a valid answer rather than a refusal: downloading an artifact that
  ## turns out not to be encrypted needs none.
  ##
  ## `bareDashInArgv` is the second half of §8 defect 16's fix, and it is
  ## needed because replacing the spelling did not retire it. The retired form
  ## was `--password-file -`, which is the conventional Unix one and the one
  ## this campaign shipped, so people will keep typing it — and `confutils`
  ## eats the bare `-` before this code ever sees it, leaving no password and,
  ## without `--encrypt`, **no refusal either**. So the caller reports whether
  ## a bare `-` appeared on the command line at all, and a `-` that named no
  ## source is refused with the spelling that works. Silence there is the
  ## unsafe direction: it uploads in the clear.
  if fromStdin and file.len > 0:
    return ("", "--password-stdin and --password-file are mutually " &
      "exclusive; a password has one source")
  if fromStdin:
    return (SecretFromStdin, "")
  if file.len > 0:
    return (file, "")
  if bareDashInArgv:
    return ("", "a bare `-` is not a password source. To read the password " &
      "from standard input, use --password-stdin.")
  ("", "")

proc optionGivenWithoutValue*(parameters: openArray[string],
    name: string): bool =
  ## Whether `--name` appears in `parameters` with **no value**.
  ##
  ## Pure, and separated from the `argv` read for the same reason `secretSource`
  ## is separated from `bareDashInArgv`: the bug being guarded is a *parsing*
  ## outcome, and a decision only observable by launching a process is a
  ## decision nothing asserts. `artifact_crypto.optionGivenWithoutValueInArgv`
  ## is the one line that looks at the real world.
  ##
  ## **The neighbour decides, and getting that wrong is how this guard shipped
  ## broken once already.** `--name=` is unambiguous. A bare `--name` is not:
  ## `confutils` takes the following token as the value unless there is none or
  ## it starts with `-`, so `--visibility tenant-or-invite` is a perfectly good
  ## invocation that an earlier version of this rule refused — it matched the
  ## bare token and never looked at what came after it. That is AS-3's
  ## `--password-file -` in mirror image: the first fix under-fired on one
  ## spelling, the second over-fired on another, and both times the guard
  ## reasoned about a token without reasoning about its neighbour.
  for index in 0 ..< parameters.len:
    let parameter = parameters[index]
    if parameter == "--" & name & "=":
      return true
    if parameter == name:
      # Not an option at all — a positional argument that happens to match.
      continue
    if parameter == "--" & name:
      if index == parameters.len - 1:
        return true
      if parameters[index + 1].startsWith("-"):
        return true
  false

proc validatePasswordChoice*(password, confirmation: string):
    tuple[problem: PasswordChoiceProblem, message: string] =
  ## Whether `password` may be used, with `confirmation` re-typed.
  ##
  ## Pure, and shared by every surface, so the CLI and AS-4's dialog cannot
  ## enforce different rules — a dialog that accepted a seven-character
  ## password the CLI refused would be two flows wearing one name.
  if password.len == 0:
    return (pcpEmpty, "a password is required to encrypt this artifact")
  if password.len < MinimumPasswordLength:
    return (pcpTooShort,
      "the password must be at least " & $MinimumPasswordLength &
      " characters; it is " & $password.len)
  if password != confirmation:
    return (pcpMismatch,
      "the two passwords do not match — since a lost password cannot be " &
      "recovered, CodeTracer asks for it twice")
  (pcpNone, "")

# ---------------------------------------------------------------------------
# The envelope's wire format
# ---------------------------------------------------------------------------

const
  ArtifactEnvelopeMagic* = "\x89CTAENC\x0D\x0A\x1A\x0A"
    ## The first bytes of a protected payload part.
    ##
    ## Shaped after PNG's signature (https://www.w3.org/TR/png/#5PNG-file-
    ## signature) and for the same reasons: the high bit is set in byte 0 so
    ## a transport that strips it corrupts the file detectably; `\r\n` and
    ## `\n` catch line-ending translation; `\x1a` stops a naive `type` on
    ## Windows.  It also cannot be confused with a zip, whose first bytes are
    ## `PK\x03\x04` — which matters because "is this file already encrypted?"
    ## is decided by looking at it.
  ArtifactEnvelopeVersion* = 1'u8
  ArtifactEnvelopeCipher* = "AES-256-GCM"
  ArtifactEnvelopeKdf* = "scrypt"

  ArtifactEnvelopeContentType* = "application/vnd.codetracer.artifact-envelope"
    ## The content type a protected payload is stored under.
    ##
    ## A protected recording is not `application/zip` any more, and telling the
    ## service that it is would be a false statement about bytes the service is
    ## about to store — the precise thing this campaign is not allowed to do,
    ## in the other direction.  Unprotected artifacts keep their kind's default
    ## content type exactly, so nothing that exists today moves.

  ArtifactEnvelopeKeyBytes* = 32     ## AES-256.
  ArtifactEnvelopeNonceBytes* = 12   ## SP 800-38D's recommended 96-bit IV.
  ArtifactEnvelopeTagBytes* = 16     ## The full GCM tag; never truncated.
  ArtifactEnvelopeSaltBytes* = 32

  ArtifactScryptN* = 1 shl 17
    ## 131072.  With `r = 8` that is 128 MiB of memory per derivation and about
    ## 0.27 s in a release build of this client — the OWASP Password Storage
    ## Cheat Sheet's recommended scrypt work factor, and an order of magnitude
    ## above RFC 7914 §2's 2016-era interactive suggestion of 16384.
  ArtifactScryptR* = 8
  ArtifactScryptP* = 1

  ArtifactScryptMinN* = 1 shl 14
    ## A floor on what this client will *accept* from a stored header.  The
    ## header is covered by the authentication tag, so it cannot be lowered by
    ## an attacker who does not already know the password; the floor exists so
    ## that a header written by some future client with weaker parameters is
    ## refused loudly rather than opened quietly.
  ArtifactScryptMaxN* = 1 shl 20
    ## A ceiling, and this one *is* a defence: the parameters are read before
    ## the tag can be checked (they are what the tag check needs), so a header
    ## claiming `N = 2^40` would otherwise have this client try to allocate a
    ## terabyte before discovering the file was junk.  2^20 is 1 GiB at r = 8.
  ArtifactScryptMaxR* = 32
  ArtifactScryptMaxP* = 16

  MaxEnvelopeHeaderBytes* = 64 * 1024
    ## Same reasoning as `ArtifactScryptMaxN`: the declared header length is
    ## read before anything about the file has been authenticated, so it is
    ## bounded before it is used to size an allocation.

  MaxEnvelopeFrameBytes* = 1024 * 1024 * 1024
    ## The ceiling on one **frame's** declared `sealedBytes`, for the same
    ## reason as `MaxEnvelopeHeaderBytes`: it is read from bytes nothing has
    ## authenticated yet and then used to size a slice.
    ##
    ## One GiB, and it is a bound on a *frame* rather than on a payload — a
    ## payload larger than this is transferred as a slice set, which is already
    ## the store's answer to a payload too large to hold at once
    ## (`Artifact-Store.md` §8 defect 7). It is also chosen to be representable
    ## on both Nim backends: this module compiles under `nim js`, where an
    ## `int` is a JavaScript number, so a constant near 2^36 is not a value the
    ## whole build can carry.

type
  ArtifactScryptParameters* = object
    ## One scrypt work factor, as a value.
    ##
    ## The parameters are a *parameter* rather than a constant because the
    ## opening side already has to honour any value inside
    ## `scryptParametersProblem`'s accepted range — the header carries them, and
    ## a client that could only open artifacts sealed at today's exact numbers
    ## would refuse its own future output.  Making the sealing side symmetric is
    ## what lets that range be exercised rather than asserted; the only value
    ## any product path passes is `ShippedScryptParameters`, and the round-trip
    ## suite pins the number that actually reaches the wire.
    n*: int
    r*: int
    p*: int

const
  ShippedScryptParameters* = ArtifactScryptParameters(
    n: ArtifactScryptN, r: ArtifactScryptR, p: ArtifactScryptP)
    ## What `ct upload --encrypt` uses, and what every artifact CodeTracer
    ## seals is sealed with.

type
  ArtifactEnvelope* = object
    ## The per-artifact half of an envelope header: everything that is the same
    ## for every part of one protected artifact.
    ##
    ## The content-encryption key is **not** here.  It is carried wrapped, in
    ## `wrappedKey`, and only `artifact_crypto.nim` ever holds the unwrapped
    ## form.
    version*: int
    cipher*: string
    kdf*: string
    scryptN*: int
    scryptR*: int
    scryptP*: int
    salt*: string        ## raw bytes
    wrapNonce*: string   ## raw bytes
    wrappedKey*: string  ## raw bytes: the CEK sealed under the password key
    artifactId*: string
    kindToken*: string
    sliceCount*: int
      ## How many frames the **reassembled payload** is made of.
      ##
      ## The same number `…/finalize` sends as `totalSlices`, deliberately, and
      ## for the same reason: it is what the payload is put back together from.
      ## It is *not* `partCount` — a sliced recording publishes its `.smnf` /
      ## `.amnf` sidecars through the same session, and the service does not
      ## reassemble those (§9.1's `ArtifactPartRole`).
      ##
      ## It lives in the envelope, authenticated, because it is what makes a
      ## **withheld slice** detectable: a download that yields fewer frames than
      ## this is refused rather than silently reassembled short.  Without it,
      ## dropping the last slice would look exactly like a shorter payload.

  ArtifactEnvelopeHeader* = object
    ## An envelope header as it appears in front of one part.
    envelope*: ArtifactEnvelope
    partIndex*: int
    partCount*: int
      ## Every object the session uploaded, sidecars included.  Carried so a
      ## part can say where it sat in the transfer; reassembly uses
      ## `envelope.sliceCount`.
    partName*: string
    sealedBytes*: int
      ## The length of this frame's `ciphertext‖tag`.
      ##
      ## Carried in the **header**, and therefore authenticated, rather than in
      ## an outer length field: a reassembled payload is a *concatenation* of
      ## frames, so something has to say where one frame ends and the next
      ## begins, and the honest place for it is under the tag. A lie about it
      ## slices the ciphertext wrongly and the tag fails.

proc envelopeHeaderJson*(header: ArtifactEnvelopeHeader): string =
  ## The header's exact bytes.
  ##
  ## This string is two things at once and both matter:
  ##
  ## 1. it is what is written into the file, and
  ## 2. it is the **additional authenticated data** of the payload's AEAD.
  ##
  ## So it must be produced by exactly one function, deterministically — which
  ## is why the fields are spelled out in a fixed order through `%*` (whose
  ## object is order-preserving) rather than assembled from a table.  It is
  ## also computed *before* the parts are sealed, to work out how much each
  ## part grows, and again *while* sealing; if those two disagreed by one byte
  ## the client would tell the service a content length it then did not send.
  $(%*{
    "v": header.envelope.version,
    "cipher": header.envelope.cipher,
    "kdf": header.envelope.kdf,
    "n": header.envelope.scryptN,
    "r": header.envelope.scryptR,
    "p": header.envelope.scryptP,
    "salt": encode(header.envelope.salt),
    "wrapNonce": encode(header.envelope.wrapNonce),
    "wrappedKey": encode(header.envelope.wrappedKey),
    "artifactId": header.envelope.artifactId,
    "kind": header.envelope.kindToken,
    "sliceCount": header.envelope.sliceCount,
    "partIndex": header.partIndex,
    "partCount": header.partCount,
    "partName": header.partName,
    "sealedBytes": header.sealedBytes,
  })

proc envelopeOverheadBytes*(headerJson: string): int =
  ## How many bytes a part grows by when it is sealed under `headerJson`.
  ##
  ## Exact, not an estimate: the magic, the version byte, the four-byte header
  ## length, the header itself and the authentication tag.  AES-GCM is a stream
  ## mode, so the ciphertext is the same length as the plaintext and there is
  ## no padding term.
  ArtifactEnvelopeMagic.len + 1 + 4 + headerJson.len + ArtifactEnvelopeTagBytes

proc encodeEnvelopeFrame*(headerJson, sealedPayload: string): string =
  ## `magic | version | headerLen | header | ciphertext‖tag`.
  ##
  ## `headerLen` is big-endian, which is the byte order every wire format in
  ## this repository already uses and the one that makes a hex dump readable.
  result = newStringOfCap(
    ArtifactEnvelopeMagic.len + 5 + headerJson.len + sealedPayload.len)
  result.add ArtifactEnvelopeMagic
  result.add chr(int(ArtifactEnvelopeVersion))
  let n = headerJson.len
  result.add chr((n shr 24) and 0xFF)
  result.add chr((n shr 16) and 0xFF)
  result.add chr((n shr 8) and 0xFF)
  result.add chr(n and 0xFF)
  result.add headerJson
  result.add sealedPayload

proc looksLikeEnvelope*(bytes: string): bool =
  ## Whether `bytes` begins a protected payload.
  ##
  ## This is how a download decides whether it is holding ciphertext, and it
  ## deliberately does not consult the artifact record: a service deployed
  ## before AS-3 returns no record at all, and a record is in any case
  ## something the service says rather than something the bytes prove.  The
  ## bytes are the truth.
  bytes.len >= ArtifactEnvelopeMagic.len and
    bytes[0 ..< ArtifactEnvelopeMagic.len] == ArtifactEnvelopeMagic

proc scryptParametersProblem*(n, r, p: int): string =
  ## Why `(n, r, p)` may not be used, or `""`.
  ##
  ## Bounded in both directions and for two different reasons — see
  ## `ArtifactScryptMinN` (refuse a weakened header loudly) and
  ## `ArtifactScryptMaxN` (refuse to allocate on the say-so of unauthenticated
  ## bytes).
  if n < ArtifactScryptMinN or n > ArtifactScryptMaxN:
    return "scrypt cost N=" & $n & " is outside the accepted range " &
      $ArtifactScryptMinN & " .. " & $ArtifactScryptMaxN
  if (n and (n - 1)) != 0:
    return "scrypt cost N=" & $n & " is not a power of two"
  if r < 1 or r > ArtifactScryptMaxR:
    return "scrypt block size r=" & $r & " is outside 1 .. " &
      $ArtifactScryptMaxR
  if p < 1 or p > ArtifactScryptMaxP:
    return "scrypt parallelism p=" & $p & " is outside 1 .. " &
      $ArtifactScryptMaxP
  ""

proc partNonce*(partIndex: int): string =
  ## The AEAD nonce for part `partIndex`, as raw bytes.
  ##
  ## **Nonce reuse is impossible by construction here, not by convention**, and
  ## the construction is the one NIST SP 800-38D §8.2.1 calls deterministic:
  ##
  ## * the content-encryption key is freshly generated from the operating
  ##   system's CSPRNG for **every** sealing operation, so no key is ever used
  ##   for two different artifacts, or twice for the same artifact;
  ## * within one sealing operation the nonce is this pure function of the part
  ##   index, and `planArtifactUpload` refuses a payload whose part indices are
  ##   not exactly `0 ..< parts.len` — so the indices are distinct, so the
  ##   nonces are distinct.
  ##
  ## The alternative, a random 96-bit nonce per part, has a birthday-bound
  ## collision probability rather than none; §8.2.1's deterministic
  ## construction has none, so that is the one taken.
  ##
  ## The leading four zero bytes are SP 800-38D's "fixed field" — reserved
  ## here, so that a future scheme that needs to partition the nonce space (a
  ## second stream under the same key, say) can do it without colliding with
  ## anything this version emits.
  result = newString(ArtifactEnvelopeNonceBytes)
  for i in 0 ..< 4:
    result[i] = '\0'
  var value = uint64(partIndex)
  for i in countdown(7, 0):
    result[4 + i] = chr(int(value and 0xFF'u64))
    value = value shr 8

type
  EnvelopeHeaderParse* = object
    header*: ArtifactEnvelopeHeader
    error*: string

proc requireString(node: JsonNode, field: string):
    tuple[value: string, error: string] =
  let value = node{field}
  if value.isNil or value.kind != JString:
    return ("", "encrypted payload header field '" & field &
      "' is missing or not a string")
  (value.getStr(), "")

proc requireInt(node: JsonNode, field: string):
    tuple[value: int, error: string] =
  let value = node{field}
  if value.isNil or value.kind != JInt:
    return (0, "encrypted payload header field '" & field &
      "' is missing or not a number")
  (value.getInt(), "")

proc decodeBase64Field(node: JsonNode, field: string, wantLen: int):
    tuple[value: string, error: string] =
  ## Read a base64 field and require its decoded length exactly.
  ##
  ## The length is required rather than merely read: a salt or a nonce of the
  ## wrong size is not a smaller salt, it is a file this client must not try to
  ## interpret.
  let raw = requireString(node, field)
  if raw.error.len > 0:
    return ("", raw.error)
  var decoded = ""
  try:
    decoded = decode(raw.value)
  except CatchableError:
    return ("", "encrypted payload header field '" & field &
      "' is not valid base64")
  if decoded.len != wantLen:
    return ("", "encrypted payload header field '" & field & "' is " &
      $decoded.len & " bytes, and must be " & $wantLen)
  (decoded, "")

proc parseEnvelopeHeader*(headerJson: string): EnvelopeHeaderParse =
  ## Read an envelope header.  Unauthenticated input: everything is checked.
  var node: JsonNode
  try:
    node = parseJson(headerJson)
  except CatchableError:
    return EnvelopeHeaderParse(
      error: "encrypted payload header is not valid JSON")
  if node.isNil or node.kind != JObject:
    return EnvelopeHeaderParse(
      error: "encrypted payload header is not a JSON object")

  let version = requireInt(node, "v")
  if version.error.len > 0:
    return EnvelopeHeaderParse(error: version.error)
  if version.value != int(ArtifactEnvelopeVersion):
    return EnvelopeHeaderParse(error:
      "encrypted payload header declares version " & $version.value &
      ", and this CodeTracer understands only version " &
      $int(ArtifactEnvelopeVersion))

  let cipher = requireString(node, "cipher")
  if cipher.error.len > 0:
    return EnvelopeHeaderParse(error: cipher.error)
  if cipher.value != ArtifactEnvelopeCipher:
    # Refused rather than attempted.  A client that met an unknown cipher and
    # carried on would be deciding, on the strength of unauthenticated bytes,
    # to run a primitive it does not implement.
    return EnvelopeHeaderParse(error:
      "encrypted payload uses cipher '" & cipher.value &
      "', and this CodeTracer implements only " & ArtifactEnvelopeCipher)

  let kdf = requireString(node, "kdf")
  if kdf.error.len > 0:
    return EnvelopeHeaderParse(error: kdf.error)
  if kdf.value != ArtifactEnvelopeKdf:
    return EnvelopeHeaderParse(error:
      "encrypted payload uses key derivation '" & kdf.value &
      "', and this CodeTracer implements only " & ArtifactEnvelopeKdf)

  let n = requireInt(node, "n")
  if n.error.len > 0: return EnvelopeHeaderParse(error: n.error)
  let r = requireInt(node, "r")
  if r.error.len > 0: return EnvelopeHeaderParse(error: r.error)
  let p = requireInt(node, "p")
  if p.error.len > 0: return EnvelopeHeaderParse(error: p.error)
  let parameterProblem = scryptParametersProblem(n.value, r.value, p.value)
  if parameterProblem.len > 0:
    return EnvelopeHeaderParse(error: parameterProblem)

  let salt = decodeBase64Field(node, "salt", ArtifactEnvelopeSaltBytes)
  if salt.error.len > 0: return EnvelopeHeaderParse(error: salt.error)
  let wrapNonce = decodeBase64Field(
    node, "wrapNonce", ArtifactEnvelopeNonceBytes)
  if wrapNonce.error.len > 0:
    return EnvelopeHeaderParse(error: wrapNonce.error)
  let wrappedKey = decodeBase64Field(node, "wrappedKey",
    ArtifactEnvelopeKeyBytes + ArtifactEnvelopeTagBytes)
  if wrappedKey.error.len > 0:
    return EnvelopeHeaderParse(error: wrappedKey.error)

  let artifactId = requireString(node, "artifactId")
  if artifactId.error.len > 0:
    return EnvelopeHeaderParse(error: artifactId.error)
  let kindToken = requireString(node, "kind")
  if kindToken.error.len > 0:
    return EnvelopeHeaderParse(error: kindToken.error)
  let partIndex = requireInt(node, "partIndex")
  if partIndex.error.len > 0:
    return EnvelopeHeaderParse(error: partIndex.error)
  let partCount = requireInt(node, "partCount")
  if partCount.error.len > 0:
    return EnvelopeHeaderParse(error: partCount.error)
  let partName = requireString(node, "partName")
  if partName.error.len > 0:
    return EnvelopeHeaderParse(error: partName.error)
  if partIndex.value < 0 or partCount.value < 1 or
      partIndex.value >= partCount.value:
    return EnvelopeHeaderParse(error:
      "encrypted payload header claims part " & $partIndex.value & " of " &
      $partCount.value)

  let sliceCount = requireInt(node, "sliceCount")
  if sliceCount.error.len > 0:
    return EnvelopeHeaderParse(error: sliceCount.error)
  # The reassembled payload is made of the frames at indices
  # `0 ..< sliceCount`, so the count has to be at least one and cannot exceed
  # the objects the session uploaded.
  if sliceCount.value < 1 or sliceCount.value > partCount.value:
    return EnvelopeHeaderParse(error:
      "encrypted payload header claims " & $sliceCount.value &
      " reassembly slice(s) out of " & $partCount.value & " part(s)")

  let sealedBytes = requireInt(node, "sealedBytes")
  if sealedBytes.error.len > 0:
    return EnvelopeHeaderParse(error: sealedBytes.error)
  # A frame always carries at least its own tag; the ceiling is the same
  # unauthenticated-input reasoning as `MaxEnvelopeHeaderBytes`, several orders
  # up because payloads are genuinely large.  The number is
  # `MaxEnvelopeFrameBytes` — **1 GiB**, and see its declaration for why a
  # frame rather than a payload is the thing bounded.  (This comment said
  # "64 GiB" until AS-4; the code was right and the comment was stale.)
  if sealedBytes.value < ArtifactEnvelopeTagBytes or
      sealedBytes.value > MaxEnvelopeFrameBytes:
    return EnvelopeHeaderParse(error:
      "encrypted payload header declares a " & $sealedBytes.value &
      "-byte frame, outside " & $ArtifactEnvelopeTagBytes & " .. " &
      $MaxEnvelopeFrameBytes)

  EnvelopeHeaderParse(header: ArtifactEnvelopeHeader(
    envelope: ArtifactEnvelope(
      version: version.value,
      cipher: cipher.value,
      kdf: kdf.value,
      scryptN: n.value,
      scryptR: r.value,
      scryptP: p.value,
      salt: salt.value,
      wrapNonce: wrapNonce.value,
      wrappedKey: wrappedKey.value,
      artifactId: artifactId.value,
      kindToken: kindToken.value,
      sliceCount: sliceCount.value),
    partIndex: partIndex.value,
    partCount: partCount.value,
    partName: partName.value,
    sealedBytes: sealedBytes.value))

type
  EnvelopeFrameParse* = object
    ## What `decodeEnvelopeFrame` found.  A result object rather than an
    ## exception: a file that is not an envelope is an ordinary, expected
    ## answer on the download path.
    isEnvelope*: bool
    header*: ArtifactEnvelopeHeader
      ## Parsed, **not yet authenticated**.  The caller verifies the tag; until
      ## it does, every field here is something an attacker may have written.
    headerJson*: string
      ## The header's exact bytes, which are the AEAD's additional data.  Kept
      ## alongside the parsed form because the tag is over the *bytes*, and
      ## re-serialising the parsed form could differ by a space.
    sealedPayload*: string
    nextOffset*: int
      ## Where the following frame begins, or `bytes.len` if this was the last.
    error*: string

proc decodeEnvelopeFrame*(bytes: string, offset = 0): EnvelopeFrameParse =
  ## Split one frame out of `bytes`, starting at `offset`.
  ##
  ## Every length is checked against the data actually present before it is
  ## used, because at this point **nothing has been authenticated**: the tag
  ## cannot be verified until the header has been parsed, and the header cannot
  ## be parsed until its length has been read.  So this procedure treats its
  ## input as hostile and the caller treats its output as unverified.
  ##
  ## The frame's own extent comes from the header's `sealedBytes`, which is
  ## covered by the tag — so a reassembled payload can be walked frame by
  ## frame, and a lie about where a frame ends either mis-slices the ciphertext
  ## (tag fails) or lands the next frame off its magic (refused here).
  if offset < 0 or offset > bytes.len:
    return EnvelopeFrameParse(isEnvelope: false)
  let rest = bytes[offset .. ^1]
  if not looksLikeEnvelope(rest):
    return EnvelopeFrameParse(isEnvelope: false)
  var cursor = ArtifactEnvelopeMagic.len
  if rest.len < cursor + 5:
    return EnvelopeFrameParse(isEnvelope: true,
      error: "encrypted payload is truncated: no header length")
  let version = int(uint8(rest[cursor]))
  inc cursor
  if version != int(ArtifactEnvelopeVersion):
    return EnvelopeFrameParse(isEnvelope: true,
      error: "encrypted payload declares envelope version " & $version &
        ", and this CodeTracer understands only version " &
        $int(ArtifactEnvelopeVersion))
  var headerLen = 0
  for i in 0 ..< 4:
    headerLen = (headerLen shl 8) or int(uint8(rest[cursor + i]))
  cursor += 4
  if headerLen <= 0 or headerLen > MaxEnvelopeHeaderBytes:
    return EnvelopeFrameParse(isEnvelope: true,
      error: "encrypted payload declares a header of " & $headerLen &
        " bytes, outside 1 .. " & $MaxEnvelopeHeaderBytes)
  if rest.len < cursor + headerLen + ArtifactEnvelopeTagBytes:
    return EnvelopeFrameParse(isEnvelope: true,
      error: "encrypted payload is truncated: it is " & $rest.len &
        " bytes, and its own header says it needs at least " &
        $(cursor + headerLen + ArtifactEnvelopeTagBytes))

  let headerJson = rest[cursor ..< cursor + headerLen]
  let parsed = parseEnvelopeHeader(headerJson)
  if parsed.error.len > 0:
    return EnvelopeFrameParse(isEnvelope: true, error: parsed.error)
  cursor += headerLen
  if rest.len < cursor + parsed.header.sealedBytes:
    return EnvelopeFrameParse(isEnvelope: true,
      error: "encrypted payload is truncated: its header declares a " &
        $parsed.header.sealedBytes & "-byte frame and only " &
        $(rest.len - cursor) & " bytes follow")
  EnvelopeFrameParse(
    isEnvelope: true,
    header: parsed.header,
    headerJson: headerJson,
    sealedPayload: rest[cursor ..< cursor + parsed.header.sealedBytes],
    nextOffset: offset + cursor + parsed.header.sealedBytes)

proc keyWrapAad*(envelope: ArtifactEnvelope): string =
  ## The additional authenticated data the content key is wrapped under.
  ##
  ## Deliberately **not** the header JSON: the header contains the wrapped key,
  ## so using it here would be circular.  What it binds instead is everything
  ## the wrap must not be transplanted away from — the artifact it belongs to,
  ## and the exact KDF parameters and salt the password was stretched with.
  ## Without that binding, an attacker holding two artifacts encrypted under
  ## the same password could move one's wrapped key onto the other's header.
  "ctae1-wrap|" & envelope.artifactId & "|" & envelope.kindToken & "|" &
    $envelope.scryptN & "|" & $envelope.scryptR & "|" & $envelope.scryptP &
    "|" & encode(envelope.salt)

proc describeVisibleMetadata*(fields: openArray[string]): string =
  ## The "what stays visible" line, from a list of field names.  One
  ## formatting, so the CLI and the dialog cannot list the same facts
  ## differently.
  if fields.len == 0:
    return "nothing beyond the transfer itself"
  fields.join(", ")
