## The status bar's test-certificate indicator (SB-1).
##
## Answers one question about the workspace in front of the user — *is what I
## have covered by a test certificate?* — and answers it in the standard's own
## vocabulary rather than a second one invented here
## (``test-certificates-spec/Verification.md``).
##
## ## What this module does NOT do, and why that matters
##
## It does not parse a certificate, it does not check a signature, and it does
## not decide coverage. All three are ``src/ct_test/certificate.nim`` and
## ``src/ct_test/certificate_verification.nim``, which this module *imports*.
## A second reader or a second verifier living in the front end is exactly the
## two-implementation drift the standard exists to prevent, and it would be a
## drift inside a single binary — the CLI and the status bar would disagree
## about the same file with nobody to notice.
##
## Reaching them took one change and it is recorded rather than worked around:
## ``certificate_verification.nim`` used to run ``ssh-keygen`` inline, which
## needs ``std/os`` and a process bridge and therefore does not exist under
## ``nim js``. The signature *primitive* moved to
## ``certificate_signature.nim`` and is now **injected**, so the algorithm
## itself is host-free and this ViewModel compiles on both Nim backends against
## the same code the CLI runs. ``certificate.nim`` needed nothing: it was
## already DOM-free, signing-free and dependency-free.
##
## ## Read-only, structurally
##
## Nothing reachable from here writes a file or produces a signature.
## ``certificate_store.CertificateStoreAccess`` offers no write operation, and
## the only route to a signature in CodeTracer is
## ``certificate_issuance.runAndAttest`` — which this module does not import
## and could not usefully call, because it *is* a test run.
##
## ## The honesty rule this indicator is under
##
## Status-Bar.md: *the display MUST NOT imply a stronger guarantee than the
## certificate carries.* "Valid" here means **binds to the state in front of
## you**, and nothing more. It does not mean "verified as unforgeable": that
## depends on which keys the verifier trusts, which is a deployment property
## and not a fact in the record (Verification.md §3.2).
##
## So the model below carries ``authenticity`` as its own field, every state
## has a ``detail`` that says what was and was not checked, and where this
## consumer cannot tell it reports **unverifiable** instead of choosing the
## reassuring reading. Five places that arises are named at their sites: a
## store that could not be listed or read, a commit this build could not
## establish, a platform it could not establish, a record in a schema version
## it does not implement, a certificate that identifies its state by content
## when the content id of the current tree is unknown, and a key store that
## cannot be read.
##
## ## What this indicator does NOT check, stated rather than implied
##
## **Framework-specific validity (Verification.md §4.2).** Past the generic
## check, validity is the framework's own question — does *its* lock file, or
## config, or target definition at ``vcs.commit`` agree with what the
## certificate claims — and the standard defines none of it. This indicator
## implements the generic check only, for every framework, and applies no
## framework's rules to any certificate including its own. §4.2 is explicit
## that a consumer MUST NOT invent a generic substitute for that step, so it
## is absent rather than approximated, and "Certified" here means the generic
## check passed and nothing more.
##
## **Coverage against a requirement the user chose.** The status bar has no
## idea which targets or platforms a project considers necessary; that is
## policy (Standard.md §5) and belongs to a gate, not to ambient chrome. What
## is evaluated is each stored certificate against *its own* targets on *this*
## platform — "does a green run still describe what I have" — which is the
## question the status bar is for. Which of several records answers it, and how
## records from different frameworks compose, is written out at
## ``evaluateCertificateIndicator``.

import std/strutils

import ../../../ct_test/certificate
import ../../../ct_test/certificate_store
import ../../../ct_test/certificate_verification

# `CertificateSignatureVerifier` is re-exported so a host can name the injected signature
# primitive without importing the verifier itself. Nothing else of
# `certificate_verification` is: the algorithm is this module's to call, not its
# callers'.
#
# `#` and not `##` — a doc comment indented under an `export` is
# `Error: invalid indentation`, the same trap `platform_host.nim` records.
export certificate_store
export CertificateSignatureVerifier, SignatureCheck

type
  CertificateIndicatorState* = enum
    ## What the status bar shows.
    ##
    ## SB-1 requires four distinguishable states — *certified*, *not
    ## certified*, *was certified no longer valid*, *unverifiable*. There are
    ## five values here because Transport.md §4 requires one more distinction
    ## **inside** "not certified": *"No certificates found" and "certificates
    ## found but none matched" are different outcomes and MUST be reported
    ## differently — the first usually means a fetch or push was missed, the
    ## second means the state genuinely is not covered.*
    ##
    ## The four SB-1 names map onto these as: certified → ``cisCertified``;
    ## not certified → ``cisNoCertificates`` or ``cisNotCertified``; was
    ## certified → ``cisWasCertified``; unverifiable → ``cisUnverifiable``.
    cisNoCertificates
      ## No store, or a store with nothing in it. **Never an error** — a
      ## project that does not use certificates is an ordinary project
      ## (Transport.md §4).
    cisCertified
      ## A certificate binds to the current state. Read the honesty rule in
      ## the module header before making this label say more.
    cisNotCertified
      ## Certificates exist and none of them is even *about* this state — a
      ## different repository, a different platform, or a record that is
      ## decidably invalid. The remedy is to run the tests.
    cisWasCertified
      ## The last produced certificate is a passing run for this repository on
      ## this platform, and no longer binds: the tree moved on. The
      ## informative state, and the reason a boolean is not enough.
    cisUnverifiable
      ## Evaluation itself broke down. **MUST NOT be collapsed into
      ## "not certified"** (Verification.md §7): one means run the tests, the
      ## other means something is misconfigured and running tests changes
      ## nothing.

  CertificateAuthenticity* = enum
    ## What was established about *who signed*, kept separate from whether the
    ## record binds to the current state. Conflating the two is the overstating
    ## this indicator is most at risk of: a certificate can bind perfectly and
    ## be unsigned, and a signed one is worth exactly what the deployment's
    ## registered keys are worth (Verification.md §3.2).
    caNotChecked
      ## This workspace registered no keys, so no signature policy exists to
      ## apply. The indicator says so rather than implying either answer.
    caUnsigned
      ## The record carries no signature and the workspace requires one.
    caRejected
      ## The record is signed and the signature is not one this workspace
      ## accepts: an unregistered ``key_id``, a **revoked** key, or a signature
      ## that does not verify. A decidable answer, and therefore never
      ## unverifiable (Verification.md §7).
    caVerified
      ## The signature verified against a registered, unrevoked key. Still not
      ## "unforgeable" — see the module header.
    caUndecidable
      ## The check could not be made.

  CertificateDetailRow* = object
    ## One line of the disclosure. A label/value pair rather than pre-formatted
    ## prose so the view decides the presentation and a test can assert the
    ## facts.
    label*: string
    value*: string

  CertificateIndicatorModel* = object
    state*: CertificateIndicatorState
    label*: string
      ## The short text in the status bar.
    summary*: string
      ## One sentence saying what is true, in the user's terms.
    remedy*: string
      ## What to do about it, when there is something to do. Empty for
      ## ``cisCertified``. The distinction between "run the tests" and "fix the
      ## configuration" lives here, and it is the practical payload of keeping
      ## unverifiable apart from not-certified.
    authenticity*: CertificateAuthenticity
    authenticityNote*: string
      ## The sentence that keeps the display from over-claiming.
    detail*: seq[CertificateDetailRow]
      ## Framework, targets, platform, time and scope — disclosed on selection
      ## (Status-Bar.md, "Interaction"). Empty when there is no record to
      ## describe.
    certificateName*: string
      ## Which record in the store this speaks for. Empty when none.
    searched*: seq[string]
      ## Where discovery looked. Transport.md §4 asks discovery to be explicit
      ## about this, and it is the first thing a "no certificates" report needs
      ## to be actionable.

  WorkspaceVcsState* = object
    ## The repository state the indicator evaluates against.
    ##
    ## ``known`` is the field that keeps this honest, and it is the same
    ## distinction ``certificate_issuance.VcsProbe.determined`` draws on the
    ## producing side: a build that could not establish the commit MUST NOT
    ## behave as though it had established one. Here that means
    ## **unverifiable**, not "not certified".
    known*: bool
    repo*: string
    commit*: string
    clean*: bool
      ## No tracked file differs from ``commit``.
    treeKnown*: bool
      ## Whether ``tree`` below is a real content id.
    tree*: string
      ## The canonical content id of the current state, for matching a
      ## modified-worktree claim by content (Verification.md §4.1.1).

  CertificateIndicatorFacts* = object
    ## Everything the indicator is a function of. Gathering these is the
    ## host's job; deciding what they mean is this module's.
    store*: CertificateStore
    vcs*: WorkspaceVcsState
    platform*: string
      ## ``os/arch``, as the certificate spells it (Standard.md §3.1). Empty
      ## means the host could not say, which is **unverifiable**: a certificate
      ## covers exactly the platform that ran the tests, and a consumer that
      ## did not know its own platform would be guessing about the one field
      ## a green Linux run says nothing about.
    signatureVerifier*: CertificateSignatureVerifier
      ## ``nil`` on a host with no ``ssh-keygen``. Never silently treated as
      ## "valid" or as "invalid" — see ``CertificateSignatureVerifier``.

const
  NoCertificatesLabel* = "No certificates"
  CertifiedLabel* = "Certified"
  NotCertifiedLabel* = "Not certified"
  WasCertifiedLabel* = "Was certified, no longer valid"
  UnverifiableLabel* = "Unverifiable"

  RunTheTestsRemedy* = "Run the tests to certify this state."
  FixConfigurationRemedy* =
    "Running the tests will not change this — something in the certificate " &
    "configuration needs fixing."

proc stateClass*(state: CertificateIndicatorState): string =
  ## The CSS modifier the view stamps on the indicator. A *class*, not a
  ## colour: the four states differ in meaning, and the stylesheet decides how
  ## that reads.
  case state
  of cisNoCertificates: "none"
  of cisCertified: "certified"
  of cisNotCertified: "not-certified"
  of cisWasCertified: "stale"
  of cisUnverifiable: "unverifiable"

proc row(label, value: string): CertificateDetailRow =
  CertificateDetailRow(label: label, value: value)

proc detailRowsFor(cert: TestCertificate; name: string):
    seq[CertificateDetailRow] =
  ## The disclosure Status-Bar.md asks for: which framework certified, which
  ## targets and platform, when, and for scoped certificates which paths.
  ##
  ## Every value is read straight off the record. Nothing is inferred, and in
  ## particular ``Scope`` says "whole repository" only when ``vcs.paths`` is
  ## genuinely absent — the field exists precisely to stop a scoped claim being
  ## read as a whole-repository one (Verification.md §4.1.2).
  result = @[
    row("Framework", cert.framework),
    row("Platform", cert.platform),
    row("Targets", sortedDeduplicated(cert.targets).join(", ")),
    row("Issued", cert.issuedAt),
    row("Issuer", cert.issuer),
    row("Commit", cert.vcs.commit)]
  if cert.vcs.paths.len > 0:
    result.add row("Scope", sortedDeduplicated(cert.vcs.paths).join(", "))
  else:
    result.add row("Scope", "whole repository")
  if not cert.vcs.clean:
    result.add row("Tested state", "a modified worktree, not the commit itself")
  if cert.vcs.untracked:
    result.add row("Untracked files", "present when the tests ran")
  result.add row("Record", name)

proc unverifiable(facts: CertificateIndicatorFacts; summary: string;
                  detail: seq[CertificateDetailRow] = @[];
                  name = ""): CertificateIndicatorModel =
  CertificateIndicatorModel(
    state: cisUnverifiable,
    label: UnverifiableLabel,
    summary: summary,
    remedy: FixConfigurationRemedy,
    authenticity: caUndecidable,
    authenticityNote:
      "Nothing about authenticity was established, because the evaluation " &
      "did not get that far.",
    detail: detail,
    certificateName: name,
    searched: facts.store.searched)

const
  NoKeysRegisteredNote* =
    "This workspace registers no signing keys, so nothing was checked about " &
    "who produced this certificate. It binds to the state in front of you; " &
    "it is not evidence that the run was not fabricated."
    ## The sentence that keeps "Certified" from being read as "verified as
    ## unforgeable". A named constant because it is the display's single most
    ## load-bearing piece of honesty (Status-Bar.md; Verification.md §3.2) and
    ## a test asserts it is present rather than hoping it is.

  KeyVerifiedNote* =
    "The signature verified against a key this workspace registered. How much " &
    "that is worth depends on who can reach that key — a deployment property, " &
    "not a fact in the certificate."

proc evaluateStoredCertificate(facts: CertificateIndicatorFacts;
                               stored: StoredCertificate):
    CertificateIndicatorModel =
  ## What **one** record in the store says about the state in front of the user.
  ##
  ## Split out of ``evaluateCertificateIndicator`` for CTC-2, which is about a
  ## store holding several records — possibly from several frameworks — rather
  ## than the single-record workspaces SB-1 was built against. The composition
  ## over those records is next door; this decides one of them.
  ##
  ## **Every requirement below is built from THIS record's own framework,
  ## targets and scope**, and that is Verification.md §2's rule as it applies
  ## to a consumer implementing no framework-specific rule at all: *"A consumer
  ## MUST NOT apply its own validity rules to another framework's certificate,
  ## even when the record parses cleanly. The fields are shared; their
  ## framework-specific meaning is not."* A neighbouring record from another
  ## framework is neither borrowed to widen this one's claim nor allowed to
  ## narrow it — it is simply a different question, answered by a different
  ## call to this proc.
  result.searched = facts.store.searched
  result.certificateName = stored.name

  # ---- Read the record ---------------------------------------------------
  # `readCertificate` is CTC-1's reader. Its three-valued status is used as
  # given: an unknown schema is NOT malformed, and the difference decides
  # whether this is unverifiable or merely not evidence (Verification.md §7.1).
  let read = readCertificate(stored.text)
  case read.status
  of crsUnknownSchema:
    # A record this build cannot interpret MUST be treated as potentially
    # relevant whatever its fields appear to say (Verification.md §7.1):
    # reading `platform` out of a later-version record with a v1 parser means
    # trusting an interpretation this build has just admitted it does not have.
    return unverifiable(facts,
      "The newest record in the store is schema '" & read.schema &
      "', which this build of CodeTracer does not implement, so what it " &
      "covers cannot be established.",
      name = stored.name)
  of crsMalformed:
    # Decidably invalid: the consumer asked the question and got an answer.
    # That is a rejection and never unverifiable (Verification.md §7).
    return CertificateIndicatorModel(
      state: cisNotCertified,
      label: NotCertifiedLabel,
      summary: "The newest record in the store is not a valid certificate: " &
               read.detail,
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "Nothing was checked about who produced it; the record could not be " &
        "read at all.",
      certificateName: stored.name,
      searched: facts.store.searched)
  of crsOk: discard

  let cert = read.cert
  let detail = detailRowsFor(cert, stored.name)

  # ---- Is this record even about the state in front of the user? ---------
  # These three reads decide RELEVANCE, which is a display question: they are
  # plain field comparisons, not a reimplementation of verification, and the
  # verdict below still comes from `verifyCertificates`. They exist because
  # "your last green run no longer covers what you have" and "nothing here has
  # ever been about this" call for the same remedy but are different sentences,
  # and only the first is true of a certificate for this repository.
  if cert.result != "passed":
    return CertificateIndicatorModel(
      state: cisNotCertified,
      label: NotCertifiedLabel,
      summary: "The newest record reports result '" & cert.result &
               "', which supports no positive claim.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "Authenticity was not checked: a record that does not report a pass " &
        "is not evidence whoever signed it.",
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)
  if cert.vcs.repo != facts.vcs.repo:
    return CertificateIndicatorModel(
      state: cisNotCertified,
      label: NotCertifiedLabel,
      summary: "The newest record is for repository '" & cert.vcs.repo &
               "', not '" & facts.vcs.repo & "'.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "Authenticity was not checked: the record is about another " &
        "repository, so its signature could not change the answer.",
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)
  if cert.platform != facts.platform:
    return CertificateIndicatorModel(
      state: cisNotCertified,
      label: NotCertifiedLabel,
      summary: "The newest record covers " & cert.platform & ", and this is " &
               facts.platform & ". A green run on one platform says nothing " &
               "about another.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "Authenticity was not checked: the record is about another platform, " &
        "so its signature could not change the answer.",
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)

  # ---- A claim this build cannot evaluate --------------------------------
  # A `clean = false` certificate does not describe its commit; it describes
  # the commit plus a modification, matched by CONTENT (Verification.md
  # §4.1.1). CodeTracer has no way to compute the content id of the current
  # worktree, so it cannot tell whether such a record matches — and saying
  # "no longer valid" would be a claim it has not earned, exactly as much as
  # saying "certified" would.
  if not cert.vcs.clean and not facts.vcs.treeKnown:
    return unverifiable(facts,
      "The newest record identifies the state it tested by content rather " &
      "than by commit, and CodeTracer cannot compute the content id of this " &
      "worktree, so it cannot tell whether the two are the same state.",
      detail = detail, name = stored.name)

  # ---- The verdict, from the shared verifier -----------------------------
  #
  # THE STATE UNDER EVALUATION IS NOT ALWAYS `commit`. Verification.md §4.1:
  # a `clean = true` certificate's tested state IS the commit, so it covers
  # the commit and nothing else. When the working tree is dirty, what the user
  # has is the commit *plus* their edits — a state no committed-tree
  # certificate describes. Passing the commit anyway would report "certified"
  # for a tree that has moved on, which is precisely the staleness this
  # indicator exists to surface.
  #
  # So a dirty tree is evaluated as a state with no commit identity. Nothing
  # can match it by commit — `readCertificate` requires a non-empty
  # `vcs.commit`, so the empty string below is unmatchable by construction —
  # and a modified-worktree claim can still match it by content through
  # `tree`, which is exactly §4.1.1's rule.
  let state = EvaluatedState(
    repo: facts.vcs.repo,
    commit: (if facts.vcs.clean: facts.vcs.commit else: ""),
    tree: facts.vcs.tree)

  # WHETHER SIGNATURES ARE REQUIRED IS THE DEPLOYMENT'S CALL, and the store
  # file is where the deployment makes it. A workspace that registered keys has
  # said which signers it trusts; one with no store has said nothing, and
  # answering "fail-closed, therefore nobody" would be inventing a decision on
  # its behalf. Verification.md §3.1's fail-closed rule governs a consumer that
  # *requires* signatures — it does not decide whether to require them.
  let requireSignature = facts.store.hasKeyStore

  var requirement = Requirement(
    # The framework is the record's own. The indicator is producer-agnostic by
    # requirement (Status-Bar.md), and it applies no framework-specific rule at
    # all — see "What this indicator does not check" below.
    frameworksImplemented: @[cert.framework],
    framework: cert.framework,
    targets: cert.targets,
    platforms: @[facts.platform],
    requireSignature: false,
    paths: cert.vcs.paths,
    pathsGiven: cert.vcs.paths.len > 0)

  let candidates = [CandidateCertificate(name: stored.name, text: stored.text)]

  # ---- Question one: does this record describe the state in front of me? --
  #
  # THE TWO QUESTIONS ARE ASKED SEPARATELY BECAUSE THE STANDARD SAYS THEY ARE
  # SEPARATE. Verification.md §1: "A certificate can be perfectly authentic and
  # cover nothing relevant. It can cover exactly the right thing and be
  # unsigned. … All three MUST be answered; none implies another."
  #
  # One combined pass answers `not-covered` for both a stale certificate and an
  # untrusted one, and the indicator would then have to guess which — reporting
  # "was certified, no longer valid" for a record that binds perfectly and is
  # merely unsigned, which is a false statement about the user's tree. Two
  # passes over the SAME verifier is not two implementations; it is asking the
  # one implementation the two questions it distinguishes.
  let binding = verifyCertificates(state, requirement, candidates,
                                   facts.store.keyStore,
                                   facts.signatureVerifier)

  case binding.outcome
  of ocUnverifiable:
    return unverifiable(facts,
      "This certificate could not be evaluated: " &
      (if binding.unevaluated.len > 0: binding.unevaluated[0].why
       else: binding.reason),
      detail = detail, name = stored.name)
  of ocNotCovered:
    # The record is a passing run for this repository on this platform, and it
    # does not describe the state in front of the user. That is the informative
    # case: their last green run no longer covers what they have.
    return CertificateIndicatorModel(
      state: cisWasCertified,
      label: WasCertifiedLabel,
      summary:
        if binding.rejected.len > 0:
          "The last certificate no longer covers this state: " &
          binding.rejected[0].why
        else:
          "The last certificate no longer covers this state.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "Authenticity is not the question here: the record does not describe " &
        "this state, whoever signed it.",
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)
  of ocCovered: discard

  # ---- Question two: is it authentic? ------------------------------------
  # Only asked when the workspace declared a trust policy at all. A workspace
  # with no registered-key store has not said which signers it trusts, and
  # answering "fail-closed, therefore nobody" on its behalf would invent a
  # deployment decision nobody made. Verification.md §3.1's fail-closed rule
  # governs a consumer that *requires* signatures; it does not decide whether
  # to require them.
  if not requireSignature:
    return CertificateIndicatorModel(
      state: cisCertified,
      label: CertifiedLabel,
      # "binds to", not "verified": the sentence is the honesty rule in the
      # module header, spelled out where a user reads it.
      summary: "A test certificate binds to the state in front of you.",
      remedy: "",
      authenticity: caNotChecked,
      authenticityNote: NoKeysRegisteredNote,
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)

  requirement.requireSignature = true
  let authentic = verifyCertificates(state, requirement, candidates,
                                     facts.store.keyStore,
                                     facts.signatureVerifier)
  case authentic.outcome
  of ocCovered:
    return CertificateIndicatorModel(
      state: cisCertified,
      label: CertifiedLabel,
      summary: "A test certificate binds to the state in front of you.",
      remedy: "",
      authenticity: caVerified,
      authenticityNote: KeyVerifiedNote,
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)
  of ocUnverifiable:
    # The one this milestone is most concerned with: an unreadable key store
    # answers nothing, so authenticity is undecidable and the outcome is
    # unverifiable — NOT "not certified" (Verification.md §3.1, §7). The two
    # send an operator to different places, and only one of them is right.
    return unverifiable(facts,
      "This certificate binds to the state in front of you, and its " &
      "authenticity could not be established: " &
      (if authentic.unevaluated.len > 0: authentic.unevaluated[0].why
       else: authentic.reason),
      detail = detail, name = stored.name)
  of ocNotCovered:
    # Decidable, and therefore not unverifiable: unsigned when signatures are
    # required, an unregistered key_id, a revoked key, or a signature that did
    # not verify. The record may describe this state perfectly; this workspace
    # does not accept it as evidence.
    return CertificateIndicatorModel(
      state: cisNotCertified,
      label: NotCertifiedLabel,
      summary:
        if authentic.rejected.len > 0:
          "A certificate describes this state, and this workspace does not " &
          "accept it: " & authentic.rejected[0].why
        else:
          "A certificate describes this state, and this workspace does not " &
          "accept it as authentic.",
      remedy:
        "Certify this state with a key this workspace registers, or register " &
        "the key that signed it.",
      authenticity: (if cert.isSigned: caRejected else: caUnsigned),
      authenticityNote:
        if cert.isSigned:
          "The signature is not one this workspace accepts."
        else:
          "The record carries no signature, and this workspace registers " &
          "signing keys, so an unsigned record is not evidence here."
        ,
      detail: detail,
      certificateName: stored.name,
      searched: facts.store.searched)

proc evaluateCertificateIndicator*(facts: CertificateIndicatorFacts):
    CertificateIndicatorModel =
  ## Decide what the status bar shows.
  ##
  ## The order below is the standard's own, and the early returns are the cases
  ## where this consumer genuinely **cannot tell** — each of which reports
  ## unverifiable rather than picking the reassuring reading.
  ##
  ## ## Several records, and possibly several frameworks
  ##
  ## A workspace may hold certificates from more than one framework at once — a
  ## `ct test` record beside a reprobuild one is the case CTC-2 exists for —
  ## and the standard deliberately defines **no** composition rule for that:
  ## *"A project using several frameworks composes several verifiers, one per
  ## framework, according to its own policy"* (Verification.md §6). So this is
  ## the status bar's policy, written where it is implemented:
  ##
  ## 1. **A record that binds wins**, whichever framework produced it and
  ##    wherever it sits in the arrival order. This is Verification.md §7.1's
  ##    rule 1 — *covered* wins — and it is safe for the reason §7.1 gives:
  ##    **in v1 coverage only ever grows.** No record subtracts, none
  ##    contradicts another, so a second record can only ever have *added* the
  ##    coverage a first one lacked.
  ##
  ##    Consulting only the newest record — which is what this did before CTC-2
  ##    — fails in exactly the direction that costs most: a stale neighbour
  ##    landing last would report "was certified, run the tests" to a user whose
  ##    state is covered by a certificate sitting in the same store. When that
  ##    neighbour is from a framework this consumer does not implement, it is
  ##    also §2's rule failing in the *rejecting* direction, which is the one
  ##    the standard singles out: such a record "is not evidence for this
  ##    consumer, and it is not evidence against anything either".
  ##
  ## 2. Otherwise, if any record could not be **evaluated**, the outcome is
  ##    *unverifiable* — §7.1's rule 2. "Run the tests" is the wrong instruction
  ##    while an unread record might already cover the state, and a decided-but-
  ##    negative newest record must not mask it: that would be reporting the
  ##    reassuring reading of a question this consumer never got to ask.
  ##
  ## 3. Otherwise the **newest** record speaks, unchanged from SB-1 — "your last
  ##    green run no longer covers what you have" is the sentence the user
  ##    needs, and it is the last run that produced it.
  ##
  ## For a store holding ONE record — every workspace SB-1 was built against —
  ## all three rules return that record's verdict, so nothing there changed.
  ##
  ## What is deliberately absent, still: this applies **no framework-specific
  ## validity rule** to any record, its own included (Verification.md §4.2 —
  ## a consumer MUST NOT invent a generic substitute for that step). See the
  ## module header.
  result.searched = facts.store.searched

  # ---- The store could not be looked at ---------------------------------
  # Kept ahead of the emptiness check on purpose. "There is nothing here" and
  # "I could not look" are different answers and only the second is a fault
  # (Transport.md §4); collapsing them would render "no certificates" for a
  # store the user can see on disk.
  if facts.store.unreadable:
    return unverifiable(facts, facts.store.unreadableReason)

  # ---- No store, or an empty one ----------------------------------------
  # Explicitly NOT an error, and explicitly not "unverifiable" either:
  # Verification.md §7 says "no certificates from a framework I implement" is
  # simply not covered, and unverifiable is reserved for evaluation breaking
  # down.
  if not facts.store.present or facts.store.certificates.len == 0:
    return CertificateIndicatorModel(
      state: cisNoCertificates,
      label: NoCertificatesLabel,
      summary:
        if facts.store.present:
          "The workspace has a certificate store and nothing in it."
        else:
          "This workspace has no certificate store.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote:
        "There is no record to say anything about.",
      searched: facts.store.searched)

  let newest = facts.store.lastProduced
  result.certificateName = newest.name

  # ---- Facts about the world this build could not establish -------------
  # A certificate names a commit and a platform. A consumer that does not know
  # its own commit, or its own platform, cannot decide either field — and the
  # honest report is that it could not, not that the answer was no.
  #
  # Decided ONCE, ahead of any record, because neither fact is a property of a
  # record: no certificate in the store could be evaluated without them. They
  # name the newest record because that is the one a user would go looking for.
  if not facts.vcs.known:
    return unverifiable(facts,
      "CodeTracer could not establish which commit this workspace is on, so " &
      "it cannot tell whether the certificate covers it.",
      name = newest.name)
  if facts.platform.len == 0:
    return unverifiable(facts,
      "CodeTracer could not establish which platform it is running on, so it " &
      "cannot tell whether the certificate covers this machine. A green run " &
      "on one platform says nothing about another.",
      name = newest.name)

  # ---- The records, newest first (see the policy above) ------------------
  var
    newestModel: CertificateIndicatorModel
    haveNewest = false
    unevaluated: CertificateIndicatorModel
    haveUnevaluated = false
  for stored in facts.store.certificates:
    let model = evaluateStoredCertificate(facts, stored)
    if model.state == cisCertified:
      return model
    if not haveNewest:
      # `store.certificates` is ordered by ARRIVAL (`orderByArrival`), so the
      # first record this loop sees is the newest one.
      newestModel = model
      haveNewest = true
    if not haveUnevaluated and model.state == cisUnverifiable:
      unevaluated = model
      haveUnevaluated = true
  if haveUnevaluated:
    return unevaluated
  newestModel

# ---------------------------------------------------------------------------
# The ViewModel
# ---------------------------------------------------------------------------

type
  CertificateIndicatorTrigger* = enum
    ## Why the indicator was asked to look again.
    ##
    ## Named rather than anonymous because *which* triggers are wired is the
    ## deliverable — "refresh when the underlying facts change, so the
    ## indicator cannot go on claiming validity it has lost" — and a wiring
    ## nothing can enumerate is a wiring nothing can test. ``lastTrigger``
    ## below is what a test reads to prove a trigger fired.
    citStartup
    citCommitChanged
      ## HEAD moved: a commit, a checkout, a rebase, a branch switch.
    citWorktreeChanged
      ## A tracked file was edited, staged or reverted.
    citStoreChanged
      ## A certificate was written, replaced or removed.
    citManualRefresh
      ## The user asked, by selecting the indicator.

  CertificateFactsReader* = proc(): CertificateIndicatorFacts {.closure.}
    ## Re-reads the world. Held by the ViewModel rather than called once,
    ## because the whole point of the refresh requirement is that the answer
    ## is recomputed from the *current* facts and never served from a cache
    ## that outlived them.

  CertificateIndicatorVm* = ref object
    ## Holds the last computed model and the reader that produced it.
    ##
    ## The model is cached only so the view can render without re-reading the
    ## filesystem on every one of the 60+ redraws a trace open triggers (see
    ## ``ui/status.nim``'s render bookkeeping). ``refresh`` is the only thing
    ## that fills it, so a stale model is only ever as stale as the last
    ## trigger — which is why the triggers are enumerated above.
    reader: CertificateFactsReader
    model*: CertificateIndicatorModel
    revision*: int
      ## Increments on every refresh that CHANGED the model. A counter rather
      ## than a flag, for the reason ``ui/status.nim``'s
      ## ``notificationsDelivered`` is one: a flag cannot tell one refresh from
      ## three, and a test proving "the indicator refreshed when the commit
      ## changed" needs to see movement, not a boolean that was already true.
    refreshes*: int
      ## Every refresh, changed or not. The pair separates "the trigger fired"
      ## from "the answer moved", which are different failures.
    lastTrigger*: CertificateIndicatorTrigger
    disclosed*: bool
      ## Whether the detail is showing. Selecting the indicator toggles it.
      ## Deliberately a field on this ViewModel and not a layout state: the
      ## disclosure is a fact already on screen being expanded, and it must not
      ## open a panel or disturb the user's layout (Status-Bar.md,
      ## "Interaction").

proc newCertificateIndicatorVm*(reader: CertificateFactsReader):
    CertificateIndicatorVm =
  ## A ViewModel that has not looked yet.
  ##
  ## The initial model is the ``cisNoCertificates`` one rather than a zero
  ## value, so a status bar that renders before the first refresh shows an
  ## honest "no certificates" instead of a blank or a stray "Certified" from
  ## whatever the enum's first value happens to be.
  result = CertificateIndicatorVm(
    reader: reader,
    model: CertificateIndicatorModel(
      state: cisNoCertificates,
      label: NoCertificatesLabel,
      summary: "Not looked yet.",
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote: "There is no record to say anything about."),
    revision: 0,
    refreshes: 0,
    lastTrigger: citStartup,
    disclosed: false)

proc `==`(a, b: CertificateDetailRow): bool =
  a.label == b.label and a.value == b.value

proc sameModel(a, b: CertificateIndicatorModel): bool =
  ## Whether a refresh changed anything a user could see. Compared field by
  ## field rather than by a digest so a field added to the model without being
  ## compared here is a compile-visible omission rather than a silent one.
  a.state == b.state and a.label == b.label and a.summary == b.summary and
    a.remedy == b.remedy and a.authenticity == b.authenticity and
    a.authenticityNote == b.authenticityNote and a.detail == b.detail and
    a.certificateName == b.certificateName and a.searched == b.searched

proc refresh*(self: CertificateIndicatorVm;
              trigger = citManualRefresh): bool {.discardable.} =
  ## Re-read the facts and recompute. Returns whether the model changed.
  ##
  ## Always re-reads. There is no "has anything changed?" short-circuit in
  ## front of the reader, and there must not be: every such short-circuit is a
  ## second, weaker theory of when the facts moved, and the failure it produces
  ## is the indicator going on claiming a validity it has lost — which is the
  ## one failure this deliverable names.
  self.lastTrigger = trigger
  inc self.refreshes
  if self.reader.isNil:
    return false
  let next = evaluateCertificateIndicator(self.reader())
  if sameModel(next, self.model):
    return false
  self.model = next
  inc self.revision
  true

proc toggleDisclosure*(self: CertificateIndicatorVm) =
  ## Selecting the indicator.
  ##
  ## Opening the disclosure refreshes first, because the detail is a claim
  ## about the current state and showing a remembered one at the moment the
  ## user asks is the worst time to be stale. Closing does not.
  if not self.disclosed:
    self.refresh(citManualRefresh)
  self.disclosed = not self.disclosed
