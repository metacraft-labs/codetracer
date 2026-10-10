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
## reassuring reading. The places that arises are named at their sites: a
## store that could not be listed or read, a repository this build could not
## establish, a platform it could not establish, a record in a schema version
## it does not implement, a certificate whose content id cannot be computed
## for the working tree (an algorithm this host does not implement, or a
## working tree with no content id at all — Content-Id.md §3), and a key
## store that cannot be read.
##
## ## What "the state in front of you" is
##
## Content, never a commit (Status-Bar.md, "Requirements"): a certificate is
## bound to the content of the tracked files (Verification.md §4.1.1), so a
## record covers a state exactly when its content id equals that state's,
## computed in the record's own algorithm over its own scope. ``base`` is
## informational and is never compared. Three states are evaluated, each
## through its own oracle (``WorkspaceVcsState``): **W**, the working tree;
## **H**, HEAD's content; **S**, the staged content ``git commit`` would
## record. The decision is made on W first, because the indicator answers
## "is what is in front of me tested?" — the table is written out at
## ``evaluateCertificateIndicator``.
##
## ## What this indicator does NOT check, stated rather than implied
##
## **Framework-specific validity (Verification.md §4.2).** Past the generic
## check, validity is the framework's own question — does *its* lock file, or
## config, or target definition for the tested content agree with what the
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
import ../../../ct_test/certificate_content_id
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
export ContentOracle, ContentAnswer

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
      ## Neither W nor H is covered and no record was found for W's, H's or
      ## S's content (Transport.md §5: "none found" is not "none matched").
      ## Also no store at all. **Never an error** — a project that does not
      ## use certificates is an ordinary project.
    cisCertified
      ## A certificate binds W. Two labels: *Certified* when W = H, and
      ## *Certified, uncommitted* when it does not — the same state, because
      ## the certificate is valid for what is in front of the user and the
      ## commit that records it will be covered. Read the honesty rule in the
      ## module header before making either label say more.
    cisNotCertified
      ## Neither W nor H is covered, and records WERE found for W's, H's or
      ## S's content: the one that speaks is for another platform or another
      ## repository, reports no pass, is not accepted as authentic, or is
      ## decidably invalid (an earlier-draft record among them). The remedy is
      ## to run the tests.
    cisWasCertified
      ## *Changed since certified*: no certificate covers W and one covers H.
      ## HEAD is certified and the working-tree changes are not. The
      ## informative state, and the reason a boolean is not enough. Its only
      ## form (operator decision 2026-10-09): when neither W nor H is covered
      ## the indicator reads not certified, never "was certified".
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
    ## The repository state the indicator evaluates against: three content
    ## facts, each an oracle answering "the content id in this algorithm over
    ## this scope", or why there is none (Content-Id.md §5).
    ##
    ## ``known`` is the field that keeps this honest, and it is the same
    ## distinction ``certificate_issuance.VcsProbe.determined`` draws on the
    ## producing side: a build that could not establish the repository MUST
    ## NOT behave as though it had established one. Here that means
    ## **unverifiable**, not "not certified".
    known*: bool
    repo*: string
    workingTree*: ContentOracle
      ## W — the working tree's tracked files as they are. An answer that is
      ## not an id — an algorithm this host cannot compute, a working tree
      ## with no content id, git failing — makes a record *unverifiable*
      ## against W, never a match and never a mismatch. ``nil`` means no id
      ## can be computed for anything.
    head*: ContentOracle
      ## H — ``HEAD^{tree}``. ``nil`` (or answers that are not ids) when there
      ## is no commit yet; H is then simply not covered.
    index*: ContentOracle
      ## S — the user's index, what ``git commit`` without ``-a`` would record.
      ## Consulted only for the staged-content warning and the disclosure.
    workingTreeProblem*: string
      ## Non-empty when W HAS NO CONTENT ID (Content-Id.md §3: unmerged
      ## entries, an assume-unchanged or present skip-worktree entry, a
      ## submodule with modified content), naming the condition and its
      ## paths. Kept apart from an oracle answer that merely failed because
      ## the remedy differs and is named: such a tree is *unverifiable* even
      ## when H is certified, and it is never certified.
    workingTreeRemedy*: string
      ## How to clear ``workingTreeProblem``: resolve the merge, clear the
      ## flag, commit inside the submodule.

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
  CertifiedUncommittedLabel* = "Certified, uncommitted"
    ## ``cisCertified`` when W is covered and W differs from H.
  WasCertifiedLabel* = "Changed since certified"
    ## The only label of ``cisWasCertified`` (operator decision 2026-10-09:
    ## SB-1's "Was certified, no longer valid" is no longer produced).
  UnverifiableLabel* = "Unverifiable"

  CommittedCertifiedSummary* =
    "The committed state in front of you is certified."
  UncommittedCertifiedSummary* =
    "Your working tree as it stands is certified; a commit of exactly this " &
    "content is covered with no second run."
  StagedDiffersWarning* =
    "The staged content differs from what was tested, so `git commit` " &
    "without `-a` will not be covered."
    ## Added to the uncommitted summary when S differs from W — partial
    ## staging is the most common way to commit something other than what
    ## was tested (Standard.md §3.2.2).
  UntrackedNote* =
    "Untracked files were present when the tests ran, and they are not " &
    "covered."
    ## Added whenever the binding certificate reports ``untracked = true``.
  ChangedSinceCertifiedSummary* =
    "HEAD is certified; your working-tree changes are not."
  ChangedSinceCertifiedRemedy* = "Run the tests to certify them."
  NoCertificatesFoundSummary* =
    "No certificate was found for the content in front of you — none for " &
    "the working tree, HEAD or the staged content."
    ## Transport.md §5: "none found" is reported differently from "none
    ## matched". It is also what a commit or a checkout past certified content
    ## reads: records for content that is no longer in front of the user are
    ## not consulted.
  EarlierDraftSummary* =
    "The newest record predates the current certificate format: it is an " &
    "earlier-draft record, bound to a commit rather than to content, so it " &
    "covers nothing and is not translated."
  EarlierDraftRemedy* = "Run the tests to re-issue it in the current format."

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
    # The binding. The certificate covers whatever state has this content id.
    row("Content", cert.vcs.content)]
  if cert.vcs.base.len > 0:
    # Where the work started, and nothing else: never compared with anything
    # (Standard.md §3.2.3), and labelled so nobody reads it as the binding.
    result.add row("Base (informational)", cert.vcs.base)
  if cert.vcs.paths.len > 0:
    result.add row("Scope", sortedDeduplicated(cert.vcs.paths).join(", "))
  else:
    result.add row("Scope", "whole repository")
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
                               stored: StoredCertificate;
                               content: ContentOracle):
    CertificateIndicatorModel =
  ## What **one** record in the store says about ONE content state — W, H or
  ## S, whichever ``content`` computes.
  ##
  ## The answer is per record and per state; ``cisWasCertified`` here means
  ## only "a valid record for this repository and platform, about other
  ## content". What the user is shown is decided over all three states by
  ## ``evaluateCertificateIndicator``.
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
    # That is a rejection and never unverifiable (Verification.md §7) — and
    # that includes an EARLIER-DRAFT record, bound to a commit with no
    # `content`, which is every certificate `ct test` wrote before the
    # 2026-10-09 revision. It is not translated; the reader's detail names
    # the remedy (run the tests, which re-issues it in the current shape).
    if read.earlierDraft:
      # Status-Bar.md: the tooltip names the cause and the remedy — the record
      # predates the current format, and running the tests re-issues it.
      return CertificateIndicatorModel(
        state: cisNotCertified,
        label: NotCertifiedLabel,
        summary: EarlierDraftSummary,
        remedy: EarlierDraftRemedy,
        authenticity: caNotChecked,
        authenticityNote:
          "Nothing was checked about who produced it; a record in the " &
          "earlier-draft shape is not evidence whoever signed it.",
        certificateName: stored.name,
        searched: facts.store.searched)
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

  # ---- The verdict, from the shared verifier -----------------------------
  #
  # THE STATE UNDER EVALUATION IS ONE CONTENT STATE — W, H or S. The verifier
  # asks its oracle for the record's own algorithm over the record's own
  # scope and compares content ids (Verification.md §4.1.1). No commit is
  # passed, because none is compared: a record issued on top of another
  # commit covers this tree when the content is the same, and a record whose
  # `base` is HEAD does not when the tree has moved on. An algorithm that
  # cannot be computed for the state, or a state with no content id, comes
  # back from the verifier as unevaluated and is reported *unverifiable*.
  let state = EvaluatedState(repo: facts.vcs.repo, content: content)

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
    # does not describe this content. Whether that is "changed since
    # certified", "not certified" or "no certificates" depends on the other
    # states, and is decided by the caller.
    return CertificateIndicatorModel(
      state: cisWasCertified,
      label: WasCertifiedLabel,
      summary:
        if binding.rejected.len > 0:
          "The newest record does not cover this content: " &
          binding.rejected[0].why
        else:
          "The newest record does not cover this content.",
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

type
  StateVerdict = object
    ## What the records say about ONE content state (W, H or S), under the
    ## composition policy written at ``evaluateCertificateIndicator``.
    covered: bool
    unverifiable: bool
      ## A record could not be evaluated against this state, and none binds.
    model: CertificateIndicatorModel
      ## The record that speaks for this state: the binding one when
      ## ``covered``, the first unevaluated one when ``unverifiable``,
      ## otherwise the newest. Zero when there are no records.
    binding: TestCertificate
      ## The binding record, when ``covered``.

proc composeOver(facts: CertificateIndicatorFacts; content: ContentOracle;
                 records: openArray[StoredCertificate]): StateVerdict =
  ## The CTC-2 composition over several records, for one content state:
  ##
  ## 1. **A record that binds wins**, whichever framework produced it and
  ##    wherever it sits in the arrival order (Verification.md §7.1 rule 1 —
  ##    in v1 coverage only ever grows, so no record can subtract what another
  ##    established). Consulting only the newest record would let a stale
  ##    neighbour veto a certificate that covers the state.
  ## 2. Otherwise, if any record could not be **evaluated**, the state is
  ##    *unverifiable* (§7.1 rule 2): "run the tests" is the wrong instruction
  ##    while an unread record might already cover it.
  ## 3. Otherwise the **newest** record speaks.
  ##
  ## Every record is decided by ``evaluateStoredCertificate`` against its OWN
  ## framework, targets and scope (Verification.md §2) — no framework's rules
  ## are applied to another's record, and none borrows another's coverage.
  var haveNewest = false
  for stored in records:
    let model = evaluateStoredCertificate(facts, stored, content)
    if model.state == cisCertified:
      result.covered = true
      result.unverifiable = false
      result.model = model
      result.binding = readCertificate(stored.text).cert
      return
    if not haveNewest:
      # `store.certificates` is ordered by ARRIVAL (`orderByArrival`), so the
      # first record this loop sees is the newest one.
      result.model = model
      haveNewest = true
    if not result.unverifiable and model.state == cisUnverifiable:
      result.model = model
      result.unverifiable = true

proc answerOf(oracle: ContentOracle; algorithm: string;
              paths: seq[string]): ContentAnswer =
  if oracle.isNil:
    return ContentAnswer(computed: false,
      reason: "no content id can be computed for this state")
  oracle(algorithm, paths)

proc foundForStatesInFront(vcs: WorkspaceVcsState;
                           stored: StoredCertificate): bool =
  ## Whether a record counts as FOUND for W's, H's or S's content, which is
  ## what separates *not certified* from *no certificates* (Transport.md §5).
  ##
  ## A record looked up in the local store is in one of those content
  ## directories by construction (the reader rejects one whose content does
  ## not match its directory). The test matters for reprobuild's pooled
  ## workspace directory, which holds records for any content: one that is
  ## decidably about OTHER content is not "found" here, exactly as a record
  ## sitting in another content's directory of the local store is not read
  ## at all (operator decision 2026-10-09 — the indicator consults nothing
  ## outside W's, H's and S's content). Anything the indicator cannot place
  ## — a record that does not parse, an earlier-draft record, an unknown
  ## schema or algorithm, a content id no state could be computed in — counts
  ## as found: it is not evidence that nothing is here.
  let read = readCertificate(stored.text)
  if read.status != crsOk:
    return true
  let content = read.cert.vcs.content
  let parsed = parseContentId(content)
  if parsed.form != cifWellFormed:
    return true
  let scope = sortedDeduplicated(read.cert.vcs.paths)
  var anyComputed = false
  for oracle in [vcs.workingTree, vcs.head, vcs.index]:
    let answer = answerOf(oracle, parsed.algorithmName, scope)
    if answer.computed:
      anyComputed = true
      if answer.id == content:
        return true
  not anyComputed

proc coverageValue(verdict: StateVerdict; absent: string): string =
  if absent.len > 0: absent
  elif verdict.covered: "covered"
  elif verdict.unverifiable: "could not be evaluated"
  else: "not covered"

proc coverageRows(vcs: WorkspaceVcsState;
                  w, h, s: StateVerdict): seq[CertificateDetailRow] =
  ## The disclosure's "whether W, H and S are each covered" (Status-Bar.md,
  ## "Interaction"), by any record — not only the one that speaks.
  @[row("Working tree (W)", coverageValue(w,
          if vcs.workingTreeProblem.len > 0:
            "no content id: " & vcs.workingTreeProblem
          else: "")),
    row("HEAD (H)", coverageValue(h,
          if vcs.head.isNil: "no commit yet" else: "")),
    row("Staged (S)", coverageValue(s, ""))]

proc withUntrackedNote(summary: string; cert: TestCertificate): string =
  if cert.vcs.untracked: summary & " " & UntrackedNote else: summary

proc evaluateCertificateIndicator*(facts: CertificateIndicatorFacts):
    CertificateIndicatorModel =
  ## Decide what the status bar shows — Status-Bar.md's table, decided on
  ## the working tree's content W first, because the indicator answers "is
  ## what is in front of me tested?":
  ##
  ## | when | state | label |
  ## |---|---|---|
  ## | a certificate covers W, and W = H | certified | *Certified* |
  ## | a certificate covers W, and W ≠ H | certified | *Certified, uncommitted* (+ the staged-content warning when S ≠ W) |
  ## | no certificate covers W, one covers H | was certified | *Changed since certified* |
  ## | neither; records found for W's, H's or S's content | not certified | *Not certified* |
  ## | neither; nothing found there | not certified | *No certificates* |
  ##
  ## and, ahead of the table, the cases where this consumer genuinely
  ## **cannot tell** — each *unverifiable* rather than the reassuring reading:
  ## a store that could not be read, a repository or platform that could not
  ## be established, **a working tree with no content id** (never certified,
  ## even when H is), and a record that could not be evaluated against W.
  ##
  ## Coverage of each state is composed over every record (``composeOver``).
  ## No commit is compared anywhere: ``base`` is informational, and "W = H"
  ## is a comparison of content ids in the binding certificate's algorithm.
  ##
  ## What is deliberately absent, still: this applies **no framework-specific
  ## validity rule** to any record, its own included (Verification.md §4.2 —
  ## a consumer MUST NOT invent a generic substitute for that step). See the
  ## module header.
  result.searched = facts.store.searched

  # ---- The store could not be looked at ---------------------------------
  # Kept ahead of the emptiness check on purpose. "There is nothing here" and
  # "I could not look" are different answers and only the second is a fault
  # (Transport.md §5); collapsing them would render "no certificates" for a
  # store the user can see on disk — or, on a host with no local store at all
  # (a browser tab), for a store this host simply cannot reach.
  if facts.store.unreadable:
    return unverifiable(facts, facts.store.unreadableReason)

  # ---- No store, or nothing in it for this content ----------------------
  # Explicitly NOT an error, and explicitly not "unverifiable" either:
  # Verification.md §7 says "no certificates from a framework I implement" is
  # simply not covered, and unverifiable is reserved for evaluation breaking
  # down. A working tree with no content id still says so here — no record
  # could describe it — but with nothing to evaluate there is nothing that
  # could not be verified.
  if not facts.store.present or facts.store.certificates.len == 0:
    var summary =
      if facts.store.present: NoCertificatesFoundSummary
      else: "No certificate store exists yet. " & NoCertificatesFoundSummary
    var remedy = RunTheTestsRemedy
    if facts.vcs.known and facts.vcs.workingTreeProblem.len > 0:
      summary.add " The working tree has no content id (" &
        facts.vcs.workingTreeProblem & "), so no certificate could describe it."
      if facts.vcs.workingTreeRemedy.len > 0:
        remedy = facts.vcs.workingTreeRemedy
    return CertificateIndicatorModel(
      state: cisNoCertificates,
      label: NoCertificatesLabel,
      summary: summary,
      remedy: remedy,
      authenticity: caNotChecked,
      authenticityNote:
        "There is no record to say anything about.",
      searched: facts.store.searched)

  let newest = facts.store.lastProduced
  result.certificateName = newest.name

  # ---- Facts about the world this build could not establish -------------
  # A certificate names content and a platform. A consumer that does not know
  # its own repository, or its own platform, cannot decide either — and the
  # honest report is that it could not, not that the answer was no.
  if not facts.vcs.known:
    return unverifiable(facts,
      "CodeTracer could not establish which repository this workspace is, " &
      "so it cannot tell whether the certificate covers its content.",
      name = newest.name)
  if facts.platform.len == 0:
    return unverifiable(facts,
      "CodeTracer could not establish which platform it is running on, so it " &
      "cannot tell whether the certificate covers this machine. A green run " &
      "on one platform says nothing about another.",
      name = newest.name)

  let records = facts.store.certificates
  let w = composeOver(facts, facts.vcs.workingTree, records)
  let h = composeOver(facts, facts.vcs.head, records)
  let s = composeOver(facts, facts.vcs.index, records)
  let coverage = coverageRows(facts.vcs, w, h, s)

  # ---- A working tree with no content id --------------------------------
  # Content-Id.md §3: what is in front of the user is not a state any
  # certificate can describe, and a producer would refuse to certify it too.
  # Never certified — not even when H is covered, which the disclosure and
  # the summary still say. Decided BEFORE W's verdict on purpose: an oracle
  # that defaulted an uncomputable W to H would otherwise read certified.
  if facts.vcs.workingTreeProblem.len > 0:
    var model = unverifiable(facts,
      "The working tree has no content id: " & facts.vcs.workingTreeProblem &
      ". No certificate can describe it, so it is not read as certified" &
      (if h.covered: ", even though HEAD's content is certified."
       else: "."),
      detail = (if h.covered: h.model.detail else: @[]) & coverage,
      name = (if h.covered: h.model.certificateName else: newest.name))
    if facts.vcs.workingTreeRemedy.len > 0:
      model.remedy = facts.vcs.workingTreeRemedy
    return model

  # ---- A certificate covers W: certified --------------------------------
  if w.covered:
    let algorithm = parseContentId(w.binding.vcs.content).algorithmName
    let wId = answerOf(facts.vcs.workingTree, algorithm, @[])
    let hId = answerOf(facts.vcs.head, algorithm, @[])
    let sId = answerOf(facts.vcs.index, algorithm, @[])
    # Compared as whole-repository ids in the binding record's algorithm. An
    # H that cannot be computed (no commit yet) is not equal to anything: the
    # content exists only on this machine until it is committed.
    let committed = wId.computed and hId.computed and wId.id == hId.id
    var model = w.model
    model.detail = w.model.detail & coverage
    if committed:
      model.label = CertifiedLabel
      model.summary = withUntrackedNote(CommittedCertifiedSummary, w.binding)
    else:
      model.label = CertifiedUncommittedLabel
      var summary = UncommittedCertifiedSummary
      if not (sId.computed and wId.computed and sId.id == wId.id):
        summary.add " " & StagedDiffersWarning
      model.summary = withUntrackedNote(summary, w.binding)
    return model

  # ---- W could not be evaluated ------------------------------------------
  # A record that might cover W could not be read against it, so "changed
  # since certified" — a claim that W is NOT covered — would be a guess.
  if w.unverifiable:
    var model = w.model
    model.detail = w.model.detail & coverage
    return model

  # ---- W is not covered, H is: changed since certified -------------------
  if h.covered:
    var model = h.model
    model.state = cisWasCertified
    model.label = WasCertifiedLabel
    model.summary = withUntrackedNote(ChangedSinceCertifiedSummary, h.binding)
    model.remedy = ChangedSinceCertifiedRemedy
    model.detail = h.model.detail & coverage
    return model

  # ---- Neither W nor H: not certified -------------------------------------
  # Only records found for W's, H's or S's content are consulted (operator
  # decision 2026-10-09); "the last green run" for some other content is not
  # identified, so a tree that moved on past certified content reads "no
  # certificates", never "was certified".
  var found: seq[StoredCertificate] = @[]
  for stored in records:
    if foundForStatesInFront(facts.vcs, stored):
      found.add stored
  if found.len == 0:
    return CertificateIndicatorModel(
      state: cisNoCertificates,
      label: NoCertificatesLabel,
      summary: NoCertificatesFoundSummary,
      remedy: RunTheTestsRemedy,
      authenticity: caNotChecked,
      authenticityNote: "There is no record to say anything about.",
      searched: facts.store.searched)

  let speaking = composeOver(facts, facts.vcs.workingTree, found).model
  var model = speaking
  model.state = cisNotCertified
  model.label = NotCertifiedLabel
  if speaking.state == cisWasCertified:
    # A valid record for this repository and platform, about content that is
    # in front of the user but is neither W nor H — the staged content.
    model.summary =
      if s.covered:
        "A certificate covers the staged content, and neither the working " &
        "tree nor HEAD."
      else:
        speaking.summary
    model.remedy = RunTheTestsRemedy
  model.detail = speaking.detail & coverage
  model

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
      ## HEAD moved: a commit, a checkout, a rebase, a branch switch. Changes
      ## H (and, after a checkout, W and S).
    citIndexChanged
      ## The index was rewritten: staging or unstaging. Changes S, which
      ## decides the staged-content warning.
    citWorktreeChanged
      ## A tracked file was edited or reverted. Changes W.
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

proc gitDirTrigger*(changedPath: string): CertificateIndicatorTrigger =
  ## Which fact a change inside ``.git`` moved, from the name of the file
  ## that changed: ``index`` (and git's ``index.lock`` while it rewrites it)
  ## is staging, which moves S; anything else there — ``HEAD``, a ref,
  ## ``ORIG_HEAD``, ``MERGE_HEAD`` — is a commit, a checkout or a merge,
  ## which moves H. Either way the indicator re-reads all three facts; the
  ## trigger is what a test reads to prove the right watch fired.
  var last = changedPath.len - 1
  while last >= 0 and changedPath[last] in {'/', '\\'}:
    dec last
  var start = last
  while start >= 0 and changedPath[start] notin {'/', '\\'}:
    dec start
  let name = if last < 0: "" else: changedPath[start + 1 .. last]
  if name == "index" or name == "index.lock": citIndexChanged
  else: citCommitChanged
