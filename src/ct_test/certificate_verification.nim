## Verifying test certificates — the consumer half of the standard.
##
## Implements ``test-certificates-spec/Verification.md``: framework filtering,
## authenticity against a registered-key store, the VCS/platform match, and
## coverage as a union — reported with a **three-valued** outcome.
##
## The third value is the point. ``covered`` and ``not-covered`` both mean the
## consumer *could tell*; ``unverifiable`` means it could not. They call for
## different responses — not-covered means *run the tests*, unverifiable means
## *fix the configuration, because re-running changes nothing* — and a boolean
## verifier collapses them while passing all its own tests
## (Verification.md §7).
##
## Nothing here signs, and nothing here runs a subprocess either. The
## signature *check* — ``ssh-keygen -Y verify`` — lives in
## ``certificate_signature.nim`` and is **injected** as a
## ``CertificateSignatureVerifier``. That split is what lets the status-bar indicator
## (SB-1) consume this exact module instead of growing a second verifier
## beside it: a ViewModel compiles on both Nim backends, ``std/os`` and a
## process bridge do not, and one algorithm with an injected primitive is the
## only shape that serves both. Read ``certificate_signature.nim``'s header
## for the full argument.
##
## The only routine in the repository that produces a signature is private to
## ``certificate_issuance.nim`` (Standard.md §6.2).

import std/[options, sets, strutils, tables]

import certificate

type
  Outcome* = enum
    ## Verification.md §7. ``$`` renders the wire spelling the conformance
    ## vectors use.
    ocCovered = "covered"
    ocNotCovered = "not-covered"
    ocUnverifiable = "unverifiable"

  SignatureCheck* = enum
    ## Three-valued for the same reason the outcome is: "the signature is bad"
    ## and "I could not check the signature" are different answers, and only
    ## the first is a rejection.
    scValid
    scInvalid
    scUndecidable

  CertificateSignatureVerifier* = proc(payload, publicKey, signatureValue: string):
      tuple[check: SignatureCheck; detail: string] {.closure, gcsafe.}
    ## How this verifier reaches the signature primitive.
    ##
    ## Spelled with the ``Certificate`` prefix rather than the obvious
    ## ``SignatureVerifier``, and not for style: ``viewmodel/identity/token.nim``
    ## already exports an unrelated ``SignatureVerifier`` — an identity-token
    ## seam over a different primitive — and the status-bar indicator re-exports
    ## this one into the same front end. Two unrelated types of that name in one
    ## import graph is a real reading hazard, and it also masked token.nim's
    ## export from ``ci/test/frontend-reachability.sh``, whose scan is by name:
    ## naming this the same thing silently marked a genuinely unreached export
    ## as reached and lowered the ratchet by one for no reason.
    ##
    ## **``nil`` is a supported value and means "this consumer cannot check a
    ## signature at all"** — a front end with no ``ssh-keygen``, a browser tab,
    ## a ViewModel test. It yields ``scUndecidable`` and therefore
    ## **unverifiable**, never ``scInvalid``: reporting "the signature does not
    ## verify" when the check was never made is exactly the collapse
    ## Verification.md §7 forbids, and it would send an operator to re-issue a
    ## perfectly good certificate.
    ##
    ## Injected rather than imported so this module stays free of ``std/os``
    ## and of any process bridge. See the module header.

  EvaluatedState* = object
    ## The world under evaluation.
    repo*: string
    commit*: string
    tree*: string
      ## The canonical content id of that state, used to match
      ## modified-worktree claims by **content** rather than by commit identity
      ## (Verification.md §4.1.1).

  Requirement* = object
    ## What the consumer demands. Deliberately separate from the state: a
    ## commit is not "on" a platform, and platforms, targets and signature
    ## policy are the consumer's choices, not properties of the tree.
    frameworksImplemented*: seq[string]
      ## Certificates from any other framework are **ignored**, not rejected
      ## (Verification.md §2).
    framework*: string
      ## The framework this particular requirement is about.
    targets*: seq[string]
    platforms*: seq[string]
    requireSignature*: bool
      ## When true, unsigned certificates are rejected **outright** rather than
      ## accepted at reduced confidence (Standard.md §6).
    paths*: seq[string]
      ## The scope that must be covered. Meaningful only with ``pathsGiven``.
    pathsGiven*: bool
      ## ``false`` means the whole repository is required — which is a
      ## *stronger* demand than any scoped certificate can satisfy, so the two
      ## must not be conflated with "no paths were listed".

  CandidateCertificate* = object
    ## One record found by discovery, with the name the report will use for it.
    name*: string
    text*: string

  MissingCoverage* = object
    ## A gap. A consumer MUST report *what* is missing — which target, on which
    ## platform, for which framework — not a bare pass/fail, because the remedy
    ## depends on the gap (Verification.md §5).
    framework*: string
    platform*: string
    targets*: seq[string]

  CertificateNote* = object
    ## A certificate named in the report together with its fate. The wording of
    ## ``why`` is prose for humans; the *classification* is not.
    certificate*: string
    why*: string

  VerificationReport* = object
    outcome*: Outcome
    reason*: string
      ## Prose for a human. Never compared by anything.
    missing*: seq[MissingCoverage]
    ignored*: seq[CertificateNote]
      ## Framework this consumer does not implement.
    rejected*: seq[CertificateNote]
      ## Evaluated, and decidably not evidence.
    unevaluated*: seq[CertificateNote]
      ## Evaluation itself broke down.

# ---------------------------------------------------------------------------
# Scope matching
# ---------------------------------------------------------------------------

proc scopeCovers*(certificatePaths: openArray[string]; required: string): bool =
  ## Whether a required path lies inside a certificate's scope.
  ##
  ## A path naming a directory scopes the subtree beneath it; a path naming a
  ## file scopes that file (Standard.md §3.2.1). Paths are repo-relative and
  ## use ``/`` separators, so the prefix test is a plain string one.
  for scoped in certificatePaths:
    if required == scoped:
      return true
    if required.startsWith(scoped & "/"):
      return true
  false

# ---------------------------------------------------------------------------
# The evaluation
# ---------------------------------------------------------------------------

type
  PendingRelevance = object
    ## An interpretable record whose evaluation broke down, held aside so its
    ## *relevance* can be judged once the gaps are known.
    framework: string
    platform: string
    targets: seq[string]

proc verifyCertificates*(state: EvaluatedState; requirement: Requirement;
                         certificates: openArray[CandidateCertificate];
                         keyStore: KeyStore;
                         signatureVerifier: CertificateSignatureVerifier = nil):
    VerificationReport =
  ## Evaluate a set of candidate certificates against a state and a
  ## requirement, and report the three-valued outcome with the gaps and the
  ## fate of every record.
  ##
  ## ``signatureVerifier`` is consulted only when
  ## ``requirement.requireSignature`` is set. ``nil`` means this consumer has
  ## no way to check a signature at all, which is **undecidable** rather than
  ## invalid — see ``CertificateSignatureVerifier``.
  var
    coverage = initTable[string, HashSet[string]]()
    uninterpretable = false
      ## A record in a schema version this consumer does not implement. It MUST
      ## be treated as potentially relevant **whatever its fields appear to
      ## say**: reading ``platform`` out of a v2 record with a v1 parser and
      ## concluding it was irrelevant means trusting an interpretation the
      ## consumer has just admitted it does not have (Verification.md §7.1).
    pending: seq[PendingRelevance] = @[]

  for platform in requirement.platforms:
    coverage[platform] = initHashSet[string]()

  for candidate in certificates:
    let read = readCertificate(candidate.text)

    if read.status == crsUnknownSchema:
      result.unevaluated.add CertificateNote(certificate: candidate.name,
        why: "schema '" & read.schema & "' is not implemented, so this " &
             "record's relevance cannot be established from its fields")
      uninterpretable = true
      continue

    if read.status == crsMalformed:
      # A record missing a required v1 field, or a `clean = false` record with
      # no `worktree`, is **decidably invalid** — the consumer asked the
      # question and got an answer, which is a rejection and never
      # unverifiable (Verification.md §7).
      result.rejected.add CertificateNote(certificate: candidate.name,
        why: "malformed: " & read.detail)
      continue

    let cert = read.cert

    # Framework filtering comes FIRST. Checking a signature or a VCS match on a
    # certificate you were never going to evaluate wastes work and, worse,
    # produces verdicts about certificates you do not understand
    # (Verification.md §2).
    if cert.framework notin requirement.frameworksImplemented:
      result.ignored.add CertificateNote(certificate: candidate.name,
        why: "framework '" & cert.framework &
             "' is not implemented by this consumer")
      continue
    if cert.framework != requirement.framework:
      # Implemented, but this requirement is about a different framework. Two
      # frameworks may use the same target name for different things, so it
      # contributes nothing here — and it is neither ignored nor rejected,
      # because some other requirement is its to answer.
      continue

    if requirement.requireSignature:
      if not cert.isSigned:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "unsigned, and this consumer requires signatures")
        continue
      if not keyStore.readable:
        # The store answers nothing, so authenticity is undecidable for this
        # record. Distinct from an empty store, which *answers*: nobody is
        # trusted (Verification.md §3.1).
        result.unevaluated.add CertificateNote(certificate: candidate.name,
          why: "authenticity undecidable: the registered-key store could not " &
               "be read (" & keyStore.unreadableReason & ")")
        pending.add PendingRelevance(framework: cert.framework,
          platform: cert.platform, targets: cert.targets)
        continue
      let registered = keyStore.lookup(cert.keyId)
      if registered.isNone:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "key_id '" & cert.keyId & "' resolves to no registered key")
        continue
      if registered.get.status == ksRevoked:
        # Revocation beats cryptography: the signature is still perfectly
        # valid, and the certificate is still rejected (Verification.md §3.1).
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "key_id '" & cert.keyId & "' has status = revoked")
        continue
      var payload: string
      try:
        # Reconstructed from the parsed FIELDS, never by slicing the received
        # file (Canonical-Payload.md §5).
        payload = canonicalPayload(cert)
      except CertificateError as err:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "no canonical form: " & err.msg)
        continue
      # A consumer with no verifier at all has not decided anything about this
      # signature, so it MUST NOT report one. `scUndecidable` is the same
      # answer a missing `ssh-keygen` produces, and lands as unverifiable.
      let checked =
        if signatureVerifier.isNil:
          (check: scUndecidable,
           detail: "this consumer has no signature verifier, so authenticity " &
                   "could not be checked")
        else:
          signatureVerifier(payload, registered.get.publicKey,
                            cert.signature.value)
      case checked.check
      of scInvalid:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "signature does not verify over the canonical payload under " &
               "namespace " & SignatureNamespace & ": " & checked.detail)
        continue
      of scUndecidable:
        result.unevaluated.add CertificateNote(certificate: candidate.name,
          why: "authenticity undecidable: " & checked.detail)
        pending.add PendingRelevance(framework: cert.framework,
          platform: cert.platform, targets: cert.targets)
        continue
      of scValid: discard

    if cert.result != "passed":
      result.rejected.add CertificateNote(certificate: candidate.name,
        why: "result is '" & cert.result & "'; only 'passed' supports a " &
             "positive claim")
      continue

    if cert.vcs.repo != state.repo:
      result.rejected.add CertificateNote(certificate: candidate.name,
        why: "vcs.repo is '" & cert.vcs.repo & "', not '" & state.repo & "'")
      continue

    if cert.vcs.clean:
      if cert.vcs.commit != state.commit:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "vcs.commit " & cert.vcs.commit &
               " is not the commit under evaluation")
        continue
    else:
      # A `clean = false` certificate does not describe `commit`; it describes
      # `commit` plus the modification in `worktree`, and is matched by
      # **content** (Verification.md §4.1.1).
      let worktree = cert.vcs.worktree.get
      if worktree.tree.len > 0:
        if worktree.tree != state.tree:
          result.rejected.add CertificateNote(certificate: candidate.name,
            why: "worktree.tree " & worktree.tree &
                 " does not equal the tree under evaluation")
          continue
      else:
        # `patch_digest` only. Reproducing the patch requires reproducing the
        # certificate's exact `format`, which is an opaque identifier this
        # consumer does not implement — so the record is **unverifiable**, not
        # invalid (Verification.md §4.1.1).
        result.unevaluated.add CertificateNote(certificate: candidate.name,
          why: "worktree carries only a patch_digest in format '" &
               worktree.format & "', which this consumer cannot reproduce")
        pending.add PendingRelevance(framework: cert.framework,
          platform: cert.platform, targets: cert.targets)
        continue

    if cert.vcs.paths.len > 0:
      # A scoped certificate is not a whole-repository certificate, and
      # treating it as one is the mistake this field exists to prevent
      # (Verification.md §4.1.2).
      if not requirement.pathsGiven:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "vcs.paths scopes the claim to [" &
               sortedDeduplicated(cert.vcs.paths).join(", ") &
               "], narrower than the whole-repository requirement")
        continue
      var uncovered = ""
      for required in requirement.paths:
        if not scopeCovers(cert.vcs.paths, required):
          uncovered = required
          break
      if uncovered.len > 0:
        result.rejected.add CertificateNote(certificate: candidate.name,
          why: "vcs.paths does not cover the required path '" & uncovered & "'")
        continue

    # Certificates for other platforms MUST NOT contribute to a platform's
    # union — a green Linux run says nothing about macOS (Verification.md §5).
    # This is not a rejection: the record is perfectly good, simply about
    # something else, so it is named nowhere in the report.
    if cert.platform notin requirement.platforms:
      continue

    for target in cert.targets:
      coverage.mgetOrPut(cert.platform, initHashSet[string]()).incl target

  # ---- Gaps --------------------------------------------------------------
  var gaps: seq[MissingCoverage] = @[]
  for platform in requirement.platforms:
    var uncovered: seq[string] = @[]
    let covered = coverage.getOrDefault(platform, initHashSet[string]())
    for target in sortedDeduplicated(requirement.targets):
      if target notin covered:
        uncovered.add target
    if uncovered.len > 0:
      gaps.add MissingCoverage(framework: requirement.framework,
                               platform: platform, targets: uncovered)

  # ---- Precedence (Verification.md §7.1) ---------------------------------
  # 1. Covered wins when every requirement is met by records evaluated end to
  #    end. This is safe because in v1 coverage only ever GROWS: no record can
  #    subtract, so one the consumer could not read could only have added.
  #    Reporting unverifiable here would send an operator to fix a
  #    configuration problem in order to reach a conclusion already reached.
  if gaps.len == 0:
    result.outcome = ocCovered
    result.missing = @[]
    result.reason = "every required target is covered on every required " &
                    "platform by certificates evaluated end to end"
    return

  # 2. Otherwise unverifiable, if any record that could not be evaluated is
  #    potentially relevant. "Run the tests" would be the wrong instruction
  #    while an unread certificate might already cover the gap.
  var relevant = uninterpretable
  if not relevant:
    for entry in pending:
      if entry.framework != requirement.framework:
        continue
      if entry.platform notin requirement.platforms:
        continue
      var intersects = false
      for target in entry.targets:
        for gap in gaps:
          if gap.platform == entry.platform and target in gap.targets:
            intersects = true
            break
        if intersects: break
      if intersects:
        relevant = true
        break
  if relevant:
    result.outcome = ocUnverifiable
    result.missing = @[]
    result.reason = "a record that could not be evaluated might have covered " &
                    "the gap, so this consumer cannot tell"
    return

  # 3. Otherwise not covered, naming the gaps.
  result.outcome = ocNotCovered
  result.missing = gaps
  result.reason = "the requirement is not met, and every record that could " &
                  "not be evaluated was demonstrably irrelevant to it"
