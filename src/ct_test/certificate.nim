## Test certificates — the record, the canonical payload, and the readers.
##
## This module implements the **vendor-neutral test-certificate standard**
## (workspace sibling ``test-certificates-spec/``):
##
## * ``Standard.md``           — what a certificate asserts, and its fields
## * ``Canonical-Payload.md``  — the exact byte sequence a signature covers
## * ``Verification.md``       — how a consumer evaluates one
##
## Everything here is **pure data handling**: building a record, rendering it,
## reading one back. There is deliberately no signing anywhere in this module
## and no import that could reach a signing primitive — see the module header
## of ``certificate_issuance.nim`` for why that separation is load-bearing
## (Standard.md §6.2: a producer MUST NOT expose any interface that signs a
## caller-supplied record, and this module is exactly the place such an
## interface would otherwise be convenient to put).
##
## Why a hand-written TOML reader
## ------------------------------
## codetracer vendors ``libs/parsetoml``, but it does not compile against the
## pinned Nim 2.2 toolchain (``parsetoml.nim:1725``: seq equality is a ``func``
## and cannot call parsetoml's side-effecting ``==``), and it is a pinned
## submodule that must not be patched from this repo. The reader covers exactly
## the TOML subset the standard uses — basic and literal strings, booleans,
## arrays of strings, ``[table]`` and ``[[array of tables]]`` headers — and
## rejects everything else loudly. Strictness is a feature here: a key store
## that cannot be read MUST be reported as unreadable rather than silently
## degraded (Verification.md §3.1), so a parser that guesses would be a defect.
##
## **It now lives in ``src/common/toml_subset.nim``** and is re-exported from
## here unchanged, because PLAT-11's project definitions read the same subset
## out of a cloned repository and a second copy of a parser is two answers to
## "what does this text mean" (Verification-Harness-Traps §14a).

import std/[algorithm, options, strutils, tables]

import ../common/toml_subset
export toml_subset

const
  CertificateSchema* = "test-certificate.v1"
    ## The schema identifier this implementation produces and verifies.
    ## Standard.md §3.1. A record declaring anything else is **unverifiable**
    ## here, not invalid (Verification.md §7).

  RegisteredKeysSchema* = "registered-keys.v1"
    ## The schema identifier of a registered-key store. Verification.md §3.1.

  SignatureNamespace* = "test-certificate-v1"
    ## The OpenSSH signature namespace that domain-separates test certificates
    ## from every other use of the same key material. Standard.md §6.1.
    ## Without it, a signature a developer produced under ``git`` (commit and
    ## tag signing) over arbitrary bytes would replay as a certificate
    ## signature.

  SignatureAlgorithm* = "ed25519"
    ## The only ``algorithm`` value this schema version defines.
    ## Standard.md §6.1.

type
  CertificateError* = object of CatchableError
    ## Raised when a record cannot be rendered in canonical form — an empty
    ## ``targets`` array, a ``clean = false`` record with no ``worktree``, a
    ## value carrying a control character the escape table cannot express.
    ## Canonical-Payload.md §2, §3, §4.

  # `TomlError` is `common/toml_subset`'s and arrives through the `export`
  # above. It stays deliberately distinct from `CertificateError`: "this file
  # is not readable" and "this record is invalid" are different verdicts for a
  # verifier (Verification.md §7), and that distinction is now shared with
  # every other consumer of the reader rather than restated per consumer.

  WorktreeClaim* = object
    ## ``[certificate.vcs.worktree]`` — identifies the exact modified state
    ## that was tested. Standard.md §3.2.2. At least one of ``tree`` and
    ## ``patchDigest`` must be present; ``format`` is required whenever
    ## ``patchDigest`` is.
    tree*: string
    format*: string
    patchDigest*: string

  VcsState* = object
    ## ``[certificate.vcs]`` — the repository state the tests ran against.
    ## Standard.md §3.2.
    repo*: string
    commit*: string
    paths*: seq[string]
      ## Repo-relative scope. Empty means the whole repository, and is
      ## **omitted entirely** from the payload — an omitted key and an empty
      ## array are different payloads (Canonical-Payload.md §2 rule 8).
    clean*: bool
    untracked*: bool
    worktree*: Option[WorktreeClaim]

  CertificateSignature* = object
    ## ``[certificate.signature]`` — OPTIONAL, and excluded from the canonical
    ## payload because a signature cannot cover itself
    ## (Canonical-Payload.md §2).
    algorithm*: string
    value*: string

  TestCertificate* = object
    ## One certificate record. Field order here mirrors Standard.md §3 so the
    ## two can be read side by side; the *payload* order is fixed separately by
    ## ``canonicalPayload`` and is not alphabetical.
    schema*: string
    framework*: string
    project*: string
    platform*: string
    targets*: seq[string]
      ## As observed. Sorting and deduplication happen at serialization time,
      ## never here — the record keeps what the producer saw.
    result*: string
    issuedAt*: string
    issuer*: string
    keyId*: string
      ## Emitted only when non-empty. An unsigned certificate omits the key
      ## entirely rather than emitting it empty (Canonical-Payload.md §2
      ## rule 3).
    vcs*: VcsState
    commands*: seq[seq[string]]
      ## ``[[certificate.command]]`` entries, in execution order. Never sorted,
      ## never deduplicated (Canonical-Payload.md §2 rule 7).
    signature*: CertificateSignature

# ---------------------------------------------------------------------------
# Byte-order sorting and deduplication
# ---------------------------------------------------------------------------

proc compareBytes*(a, b: string): int =
  ## Compare two strings as **unsigned byte sequences**, shorter-is-smaller on
  ## a common prefix.
  ##
  ## Written out rather than delegated to ``system.cmp`` because
  ## Canonical-Payload.md §3 spends a section on the three orders this is
  ## *not*, each of which is some language's default: locale collation (folds
  ## case and accents), UTF-16 code-unit order (surrogate pairs compare below
  ## ``E000``–``FFFF``, reversing the byte order above the BMP), and a sort of
  ## the *escaped* rendering (a value containing TAB sorts by ``09``; its
  ## rendering ``\t`` would sort by ``5C``). An explicit unsigned-byte
  ## comparison is the one that cannot drift into any of them.
  let shared = min(a.len, b.len)
  for i in 0 ..< shared:
    let
      x = uint8(a[i])
      y = uint8(b[i])
    if x != y:
      return if x < y: -1 else: 1
  if a.len == b.len: 0
  elif a.len < b.len: -1
  else: 1

proc sortedDeduplicated*(values: openArray[string]): seq[string] =
  ## Sort in ascending byte order and remove duplicates.
  ##
  ## Applied to ``targets`` (Canonical-Payload.md §3) and ``paths``
  ## (Standard.md §3.2.1). Deduplication is exact-byte equality: **no Unicode
  ## normalization is applied**, so a precomposed ``é`` (U+00E9) and a
  ## decomposed ``e`` + U+0301 are two different targets and both survive
  ## (Canonical-Payload.md §4). Normalizing would silently change what a
  ## signature covers.
  result = @values
  result.sort(compareBytes)
  var deduped: seq[string] = @[]
  for value in result:
    if deduped.len == 0 or deduped[^1] != value:
      deduped.add value
  result = deduped

# ---------------------------------------------------------------------------
# String escaping
# ---------------------------------------------------------------------------

proc isRepresentable*(value: string): bool =
  ## Whether every byte of ``value`` has a canonical rendering.
  ##
  ## A TOML basic string cannot carry a raw control character, and the escape
  ## table defines no escape for the ones it omits, so a value containing any
  ## character in ``U+0000``–``U+001F`` other than the five escapable ones, or
  ## ``U+007F``, **has no canonical form** and a producer MUST NOT emit one
  ## (Canonical-Payload.md §4). Inventing an escape for it would be a repair,
  ## which §5 forbids.
  for ch in value:
    let b = uint8(ch)
    if b == 0x7F'u8:
      return false
    if b < 0x20'u8 and b notin [0x08'u8, 0x09'u8, 0x0A'u8, 0x0C'u8, 0x0D'u8]:
      return false
  true

proc escapeBasicString*(value: string): string =
  ## Render ``value`` as the body of a TOML basic string.
  ##
  ## **This escape set is closed** (Canonical-Payload.md §4): backslash, double
  ## quote, and the five whitespace controls. A character absent from the table
  ## is emitted literally — in particular non-ASCII bytes are emitted as
  ## literal UTF-8 and never as ``\uXXXX``, and ``/`` is an ordinary character.
  ##
  ## The ``/`` case is why a JSON encoder cannot simply be reused here. JSON
  ## *permits* ``\/``, and ``/`` appears in almost every certificate
  ## (``platform`` is ``os/arch``, every multi-segment path contains one), so
  ## an encoder that takes that liberty produces ``linux\/amd64`` — valid JSON,
  ## invalid here, and a different signature.
  result = newStringOfCap(value.len + 8)
  for ch in value:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    else: result.add ch

proc quoted(value: string): string =
  '"' & escapeBasicString(value) & '"'

proc inlineArray(values: openArray[string]): string =
  ## ``["a", "b"]`` — comma and a single space between elements, no trailing
  ## comma, no spaces inside the brackets (Canonical-Payload.md §3).
  result = "["
  for i, value in values:
    if i > 0:
      result.add ", "
    result.add quoted(value)
  result.add "]"

# ---------------------------------------------------------------------------
# The canonical payload
# ---------------------------------------------------------------------------

proc requireRepresentable(field, value: string) =
  if not isRepresentable(value):
    raise newException(CertificateError,
      "field '" & field & "' contains a control character with no canonical " &
      "escape; such a value has no canonical form (Canonical-Payload.md §4)")

proc validateForCanonicalisation(cert: TestCertificate) =
  ## Every rule that makes a record un-renderable rather than merely unusual.
  if cert.schema.len == 0:
    raise newException(CertificateError, "schema is required")
  if cert.targets.len == 0:
    raise newException(CertificateError,
      "a certificate covering no target supports no claim; targets = [] is " &
      "not a payload this standard defines (Canonical-Payload.md §3)")
  if cert.commands.len == 0:
    raise newException(CertificateError,
      "a certificate recording no command asserts nothing; at least one " &
      "[[certificate.command]] is required (Standard.md §3.1)")
  for argv in cert.commands:
    if argv.len == 0:
      raise newException(CertificateError,
        "an empty argv describes no command and MUST NOT be emitted " &
        "(Canonical-Payload.md §2 rule 7)")
  if cert.vcs.clean:
    if cert.vcs.worktree.isSome:
      raise newException(CertificateError,
        "[certificate.vcs.worktree] MUST be absent when clean = true " &
        "(Standard.md §3.2.2)")
  else:
    if cert.vcs.worktree.isNone:
      raise newException(CertificateError,
        "[certificate.vcs.worktree] is REQUIRED when clean = false: a dirty " &
        "certificate without it identifies no state at all (Standard.md §3.2.2)")
    let worktree = cert.vcs.worktree.get
    if worktree.tree.len == 0 and worktree.patchDigest.len == 0:
      raise newException(CertificateError,
        "at least one of worktree.tree and worktree.patch_digest MUST be " &
        "present (Standard.md §3.2.2)")
    if worktree.patchDigest.len > 0 and worktree.format.len == 0:
      raise newException(CertificateError,
        "worktree.format is REQUIRED when patch_digest is present, because " &
        "diff output is not canonical (Standard.md §3.2.2)")

  requireRepresentable("schema", cert.schema)
  requireRepresentable("framework", cert.framework)
  requireRepresentable("project", cert.project)
  requireRepresentable("platform", cert.platform)
  requireRepresentable("result", cert.result)
  requireRepresentable("issued_at", cert.issuedAt)
  requireRepresentable("issuer", cert.issuer)
  requireRepresentable("key_id", cert.keyId)
  requireRepresentable("vcs.repo", cert.vcs.repo)
  requireRepresentable("vcs.commit", cert.vcs.commit)
  for target in cert.targets:
    requireRepresentable("targets", target)
  for path in cert.vcs.paths:
    requireRepresentable("vcs.paths", path)
  for argv in cert.commands:
    for arg in argv:
      requireRepresentable("command.argv", arg)
  if cert.vcs.worktree.isSome:
    let worktree = cert.vcs.worktree.get
    requireRepresentable("worktree.tree", worktree.tree)
    requireRepresentable("worktree.format", worktree.format)
    requireRepresentable("worktree.patch_digest", worktree.patchDigest)

proc canonicalPayload*(cert: TestCertificate): string =
  ## The **exact byte sequence a signature covers**: UTF-8, LF-only, BOM-free,
  ## no trailing whitespace, ending with exactly one newline
  ## (Canonical-Payload.md §1).
  ##
  ## Key order is fixed and MUST NOT be re-sorted; tables are separated by
  ## exactly one blank line; ``key_id``, ``paths`` and the whole
  ## ``worktree`` table are omitted rather than emitted empty
  ## (Canonical-Payload.md §2).
  ##
  ## Note the ordering inside this proc: ``targets`` and ``paths`` are sorted
  ## on their **raw values** and only then escaped. Escaping first and sorting
  ## the rendering reverses the order of any pair whose difference lies in an
  ## escapable character, which is the divergence
  ## ``vectors/payload/escapes`` exists to pin.
  validateForCanonicalisation(cert)

  var lines: seq[string] = @[]
  lines.add "schema = " & quoted(cert.schema)
  lines.add ""
  lines.add "[certificate]"
  lines.add "framework = " & quoted(cert.framework)
  lines.add "project = " & quoted(cert.project)
  lines.add "platform = " & quoted(cert.platform)
  lines.add "targets = " & inlineArray(sortedDeduplicated(cert.targets))
  lines.add "result = " & quoted(cert.result)
  # `issued_at` is a TOML *basic string*, never a bare TOML datetime, and its
  # characters are copied verbatim — nothing re-formats the timestamp. RFC 3339
  # spells the same instant as both `Z` and `+00:00`; those are different bytes
  # and therefore different signatures (Canonical-Payload.md §2 rule 10).
  lines.add "issued_at = " & quoted(cert.issuedAt)
  lines.add "issuer = " & quoted(cert.issuer)
  if cert.keyId.len > 0:
    lines.add "key_id = " & quoted(cert.keyId)

  lines.add ""
  lines.add "[certificate.vcs]"
  lines.add "repo = " & quoted(cert.vcs.repo)
  lines.add "commit = " & quoted(cert.vcs.commit)
  let paths = sortedDeduplicated(cert.vcs.paths)
  if paths.len > 0:
    lines.add "paths = " & inlineArray(paths)
  # Bare TOML booleans, never quoted strings (Canonical-Payload.md §2 rule 4).
  lines.add "clean = " & (if cert.vcs.clean: "true" else: "false")
  lines.add "untracked = " & (if cert.vcs.untracked: "true" else: "false")

  if cert.vcs.worktree.isSome:
    let worktree = cert.vcs.worktree.get
    lines.add ""
    lines.add "[certificate.vcs.worktree]"
    if worktree.tree.len > 0:
      lines.add "tree = " & quoted(worktree.tree)
    if worktree.format.len > 0:
      lines.add "format = " & quoted(worktree.format)
    if worktree.patchDigest.len > 0:
      lines.add "patch_digest = " & quoted(worktree.patchDigest)

  for argv in cert.commands:
    lines.add ""
    lines.add "[[certificate.command]]"
    # argv is serialized like targets but is NEVER sorted or deduplicated: an
    # argument vector is ordered by nature and repeated arguments are
    # meaningful (Canonical-Payload.md §2 rule 7).
    lines.add "argv = " & inlineArray(argv)

  result = lines.join("\n") & "\n"

proc renderCertificate*(cert: TestCertificate): string =
  ## The full on-disk certificate: the canonical payload, plus the signature
  ## block when the record carries one.
  ##
  ## An unsigned certificate omits the block entirely. The empty-block spelling
  ## is equally valid on input and means the same thing
  ## (Canonical-Payload.md §6); this producer writes the shorter form.
  result = canonicalPayload(cert)
  if cert.signature.algorithm.len > 0 or cert.signature.value.len > 0:
    result.add "\n[certificate.signature]\n"
    result.add "algorithm = " & quoted(cert.signature.algorithm) & "\n"
    result.add "value = " & quoted(cert.signature.value) & "\n"

proc isSigned*(cert: TestCertificate): bool =
  ## Both spellings of "unsigned" — an absent block and a block with empty
  ## ``algorithm`` and ``value`` — mean the same thing and a verifier MUST
  ## treat them identically (Canonical-Payload.md §6).
  cert.signature.algorithm.len > 0 and cert.signature.value.len > 0

# ---------------------------------------------------------------------------
# The TOML subset reader
# ---------------------------------------------------------------------------
#
# IT MOVED TO `src/common/toml_subset.nim` ON 2026-09-11, UNCHANGED, and it is
# re-exported here so every existing consumer of `certificate` keeps spelling
# `TomlNode`, `TomlError`, `parseTomlSubset` and `field` exactly as before.
#
# PLAT-11 reads project definitions out of a CLONED REPOSITORY — hostile input
# with a shorter supply chain than the git notes a certificate travels in — and
# wants the same reader and, more to the point, the same REFUSALS: the
# duplicate key, the table reopened, the array nested past `MaxTomlNesting`.
# Writing a second reader would be Verification-Harness-Traps §14a's worst
# shape, "a whole re-derived module", with the disagreements between the two
# copies exactly where the interesting inputs are.
#
# `src/common/` rather than here because `common` is what both `ct_test` and
# `common/project_definitions` may depend on; a dependency the other way would
# put a test-certificate module underneath the debugger's own data path.


# ---------------------------------------------------------------------------
# Reading a certificate back
# ---------------------------------------------------------------------------

type
  CertificateReadStatus* = enum
    ## The three fates a candidate record can meet on the way in. They are
    ## kept apart because a verifier MUST distinguish them
    ## (Standard.md §7, Verification.md §7): a record missing a required v1
    ## field is decidably invalid and contributes nothing, while a record in a
    ## schema version this verifier does not implement may be a perfectly good
    ## certificate it simply cannot read.
    crsOk
    crsMalformed
    crsUnknownSchema

  CertificateRead* = object
    status*: CertificateReadStatus
    detail*: string
      ## Prose for a human. Never compared by anything.
    schema*: string
      ## Always populated when the input parsed at all, so an unknown-schema
      ## report can name the version it did not implement.
    cert*: TestCertificate

proc readCertificate*(text: string): CertificateRead =
  ## Parse one certificate record.
  ##
  ## The payload a signature is checked against is reconstructed from the
  ## parsed **fields**, never by slicing the received bytes
  ## (Canonical-Payload.md §5) — which is why this returns a record and never
  ## a byte range. A received file may differ from canonical form in
  ## whitespace, key order or escaping while parsing to identical values.
  var root: TomlNode
  try:
    root = parseTomlSubset(text)
  except TomlError as err:
    return CertificateRead(status: crsMalformed,
                           detail: "not readable as TOML: " & err.msg)

  result.schema = root.strField("schema")
  if result.schema.len == 0:
    return CertificateRead(status: crsMalformed, detail: "schema is missing")
  if result.schema != CertificateSchema:
    return CertificateRead(status: crsUnknownSchema, schema: result.schema,
      detail: "schema '" & result.schema & "' is not implemented")

  let certificate = root.field("certificate")
  if certificate == nil or certificate.kind != tomlTable:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "[certificate] table is missing")
  let vcs = certificate.field("vcs")
  if vcs == nil or vcs.kind != tomlTable:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "[certificate.vcs] table is missing")

  var cert = TestCertificate(schema: result.schema)
  cert.framework = certificate.strField("framework")
  cert.project = certificate.strField("project")
  cert.platform = certificate.strField("platform")
  cert.targets = certificate.strSeqField("targets")
  cert.result = certificate.strField("result")
  cert.issuedAt = certificate.strField("issued_at")
  cert.issuer = certificate.strField("issuer")
  cert.keyId = certificate.strField("key_id")

  cert.vcs.repo = vcs.strField("repo")
  cert.vcs.commit = vcs.strField("commit")
  cert.vcs.paths = vcs.strSeqField("paths")
  let cleanNode = vcs.field("clean")
  let untrackedNode = vcs.field("untracked")
  if cleanNode == nil or cleanNode.kind != tomlBool:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "vcs.clean is missing or not a boolean")
  if untrackedNode == nil or untrackedNode.kind != tomlBool:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "vcs.untracked is missing or not a boolean")
  cert.vcs.clean = cleanNode.boolVal
  cert.vcs.untracked = untrackedNode.boolVal

  let worktree = vcs.field("worktree")
  if worktree != nil:
    if worktree.kind != tomlTable:
      return CertificateRead(status: crsMalformed, schema: result.schema,
                             detail: "vcs.worktree is not a table")
    cert.vcs.worktree = some(WorktreeClaim(
      tree: worktree.strField("tree"),
      format: worktree.strField("format"),
      patchDigest: worktree.strField("patch_digest")))

  let commands = certificate.field("command")
  if commands != nil and commands.kind == tomlArray:
    for entry in commands.items:
      if entry.kind == tomlTable:
        cert.commands.add entry.strSeqField("argv")

  let signature = certificate.field("signature")
  if signature != nil and signature.kind == tomlTable:
    cert.signature.algorithm = signature.strField("algorithm")
    cert.signature.value = signature.strField("value")

  # Required-field checks. A conforming verifier MUST reject a record missing
  # any required field (Standard.md §3.1, §7) — and this is a *decidable*
  # verdict, never "unverifiable".
  for (name, value) in {
      "framework": cert.framework, "project": cert.project,
      "platform": cert.platform, "result": cert.result,
      "issued_at": cert.issuedAt, "issuer": cert.issuer,
      "vcs.repo": cert.vcs.repo, "vcs.commit": cert.vcs.commit}.items:
    if value.len == 0:
      return CertificateRead(status: crsMalformed, schema: result.schema,
                             detail: "required field '" & name & "' is missing")
  if cert.targets.len == 0:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "at least one target is required")
  if cert.commands.len == 0:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: "at least one [[certificate.command]] is required")
  if not cert.vcs.clean and cert.vcs.worktree.isNone:
    return CertificateRead(status: crsMalformed, schema: result.schema,
      detail: "clean = false with no [certificate.vcs.worktree]: the record " &
              "identifies no state at all (Standard.md §3.2.2)")
  if cert.vcs.clean and cert.vcs.worktree.isSome:
    return CertificateRead(status: crsMalformed, schema: result.schema,
      detail: "[certificate.vcs.worktree] must be absent when clean = true")

  # Everything else that makes a record decidably invalid is exactly the set of
  # things that leave it with **no canonical form**, so ask the serializer
  # rather than re-deriving its rules here and drifting from them: a value
  # carrying a control character the escape table cannot express
  # (Canonical-Payload.md §4 — "a verifier encountering one MUST reject the
  # record as malformed"), an `argv = []` describing no command (§2 rule 7),
  # and the worktree-key combinations §3.2.2 forbids.
  #
  # Doing it HERE rather than at the signature check is deliberate. The check
  # used to live on the signature path only, so an *unsigned* unrepresentable
  # record was read as valid and went on to contribute coverage. That is not
  # exploitable into a false `covered`, but it is a non-conforming verifier,
  # and "which rules apply" must not depend on the consumer's signature policy.
  try:
    discard canonicalPayload(cert)
  except CertificateError as err:
    return CertificateRead(status: crsMalformed, schema: result.schema,
                           detail: err.msg)

  CertificateRead(status: crsOk, schema: result.schema, cert: cert)

# ---------------------------------------------------------------------------
# Registered-key stores
# ---------------------------------------------------------------------------

type
  KeyStatus* = enum
    ksActive = "active"
    ksRevoked = "revoked"

  RegisteredKey* = object
    keyId*: string
    publicKey*: string
    status*: KeyStatus

  KeyStore* = object
    ## A parsed registered-key store.
    ##
    ## ``readable`` is the field that carries Verification.md §3.1's most
    ## easily-lost distinction: an **empty or missing** store *answers* the
    ## question — nobody is trusted, fail-closed, and the certificates it
    ## denies are **not covered**. A store that cannot be read answers nothing,
    ## and the outcome is **unverifiable**. Collapsing the two sends an
    ## operator to re-run tests when the fault is a corrupt config file.
    readable*: bool
    unreadableReason*: string
    keys*: seq[RegisteredKey]

proc readKeyStore*(text: string): KeyStore =
  ## Parse a registered-key store. An unparseable store is *readable = false*,
  ## which is a different verdict from an empty one.
  result.readable = true
  var root: TomlNode
  try:
    root = parseTomlSubset(text)
  except TomlError as err:
    return KeyStore(readable: false,
                    unreadableReason: "not readable as TOML: " & err.msg)
  let schema = root.strField("schema")
  if schema != RegisteredKeysSchema:
    return KeyStore(readable: false,
      unreadableReason: "unexpected key-store schema: '" & schema & "'")
  let keys = root.field("key")
  if keys == nil:
    return
  if keys.kind != tomlArray:
    return KeyStore(readable: false,
                    unreadableReason: "[[key]] is not an array of tables")
  for entry in keys.items:
    if entry.kind != tomlTable:
      return KeyStore(readable: false,
                      unreadableReason: "a [[key]] entry is not a table")
    let statusText = entry.strField("status")
    let status =
      case statusText
      of "active": ksActive
      of "revoked": ksRevoked
      else:
        return KeyStore(readable: false,
          unreadableReason: "unknown key status: '" & statusText & "'")
    let keyId = entry.strField("key_id")
    let publicKey = entry.strField("public_key")
    # A store is a trust decision, so a half-written entry has to be a loud
    # failure rather than a silent one. An entry with no `key_id` matches no
    # certificate; one with no `public_key` resolves and then verifies nothing.
    if keyId.len == 0:
      return KeyStore(readable: false,
                      unreadableReason: "a [[key]] entry has no key_id")
    if publicKey.len == 0:
      return KeyStore(readable: false,
        unreadableReason: "[[key]] '" & keyId & "' has no public_key")
    # Duplicate ids are rejected outright, not resolved by first-wins.
    # Revocation is a status flip rather than a deletion (Verification.md
    # §3.1), so an `active` duplicate listed *above* a `revoked` entry would
    # shadow the revocation and quietly restore a key someone deliberately
    # withdrew — the exact failure the flip-not-delete rule exists to prevent.
    for existing in result.keys:
      if existing.keyId == keyId:
        return KeyStore(readable: false,
          unreadableReason: "key_id '" & keyId & "' is registered twice, so " &
            "which entry (and which status) applies is undecidable")
    result.keys.add RegisteredKey(
      keyId: keyId, publicKey: publicKey, status: status)

proc lookup*(store: KeyStore; keyId: string): Option[RegisteredKey] =
  ## Resolve a ``key_id``. **Revocation is a status flip, never a deletion**
  ## (Verification.md §3.1), so a revoked key still resolves — and is then
  ## rejected for its status, which is a different report from "unrecognised".
  for key in store.keys:
    if key.keyId == keyId:
      return some(key)
  none(RegisteredKey)
