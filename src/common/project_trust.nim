## project_trust.nim — PLAT-13 deliverable 1. The per-repository trust grant
## that the executable tier of a project definition sits behind, and the
## capability floor it gets once it is past it.
##
## Project-Definitions.md §2.3, in full, because every sentence below is one of
## its clauses:
##
##   "**per repository**, recorded by identity rather than by path, so moving a
##    checkout does not silently re-grant and a different repository at the same
##    path does not inherit it; **revocable**, and visible — a user can see what
##    is trusted and withdraw it; **not implied by any other trust decision**.
##    Opening, recording and replaying a project are all possible without it."
##
## ## WHAT WAS REUSED, AND THE ONE PLACE THIS DELIBERATELY DIFFERS
##
## PLAT-8 and PLAT-10 already answer "what may this code do" and "what did the
## user decide, and can they take it back". A second answer to either would be
## two answers to one question, which is the shape PLAT-8 paid eleven verified
## escapes to avoid, so:
##
##   * **the capability floor is PLAT-8's own `decide`.** `ExecutableTierGrants`
##     below is an empty `GrantSet`, and every refusal an executable definition
##     meets is the same `capabilities.decide` arm that refuses a plugin which
##     never asked for the grant. There is no second policy and no second
##     vocabulary — §2.3's "strictly less" is expressed as *the empty set in the
##     model that already exists*, and `project_trust_test` asserts it by
##     enumerating every `IoRequestKind`;
##   * **the ledger's shape is PLAT-10's**: append-only, last entry wins,
##     undecided is not granted, revoking an undecided entry is RECORDED, and
##     the whole history is what `describe` prints. Those are not conveniences,
##     they are the properties that make revocation survive a reinstall, and
##     `grant_ledger.nim`'s header argues each one;
##   * **the file, the lock and the atomic write are PLAT-10's**, reached by
##     CALLING `grant_store.withGrantLedgerLock` and
##     `grant_store.grantLedgerStagingPath` rather than by copying them — see
##     `ct/launch/project_trust_store.nim`.
##
## **AND ONE THING IS DELIBERATELY NOT REUSED: there is no `grantDeclared`.**
## PLAT-10 has an acceptance step that grants every capability a manifest
## declares which has no decision yet, and that is right for a plugin: a user
## installed it *by name*, and the install is the moment they decided. A project
## definition arrives with a `git clone` the user may not have read, so there is
## no act to hang an acceptance on — and an "accept everything undecided" call
## would turn cloning into deciding, which is precisely what §2 forbids. Every
## grant here names ONE repository, ONE file and ONE digest, and there is no
## function anywhere in this package that records more than one at a time.
##
## ## THE DEFAULT IS NOT GRANTED, AND IT IS THE ZERO VALUE
##
## `TrustState`'s zero value is `tsUndecided` and `admit` refuses it. That is
## the §7a/`pkText` lesson taken before it costs anything: a zero value that is
## also the permissive answer is a producer that forgets to set a field and
## silently gets maximum privilege — which PLAT-12 found in `Visualiser.tier`,
## where the enum's zero was §5.4's HIGHEST precedence tier.
##
## ## IDENTITY IS NOT A PATH, AND IT IS NOT DERIVED HERE
##
## `RepositoryIdentity` is an opaque string this module compares and never
## parses. Producing one needs the filesystem — see
## `ct/launch/project_trust_store.checkoutIdentity`, which derives it from the
## checkout directory's own `(device, file)` identity, so that renaming a
## checkout keeps its grant, a COPY of a checkout does not inherit one, and a
## different repository later occupying the same path does not either.
##
## Keeping the derivation out of this module is what lets every rule below be
## asserted in `common-units`, a lane that links no renderer and opens no
## handle — the argument `capabilities.nim` and `grant_ledger.nim` both make.
##
## ## THE GRANT IS BOUND TO THE BYTES, NOT ONLY TO THE REPOSITORY
##
## This is the clause §2.3 does not state and the threat model requires. A grant
## keyed on the repository alone is a grant that a later `git pull` inherits:
## the user consented to code they could have read, and the next fetch replaces
## it with code they cannot have. So a grant records the CONTENT DIGEST of the
## file it was given for, and `admit` refuses when the bytes have moved on —
## `etaContentChanged`, whose remedy is to look at the new file and grant again.
##
## The three mechanisms are deliberately separable and each has evidence only it
## can satisfy (Verification-Harness-Traps §32a, which exists because a second
## mechanism disarms an arm exactly as a moved needle does):
##
##   | mechanism | what only it refuses |
##   |---|---|
##   | the identity | a byte-identical COPY of a granted checkout |
##   | the ledger state | a checkout whose grant was revoked, bytes unchanged |
##   | the digest | the SAME checkout after its `.wasm` changed |
##
## ## THE ROW GRAMMAR IS CLOSED, BECAUSE ONE FIELD IS DERIVED FROM A PATH
##
## The ledger is one row per line with a TAB between fields, and until
## 2026-09-13 nothing checked that a field could be written in it. That is
## survivable while every field is a hand-typed remark; it is not survivable
## here, because `grantExecutableTier` defaults the `note` to the CHECKOUT PATH
## — and a directory name is chosen by whoever ran `git clone`. Measured:
##
##     checkout: /tmp/evil\ngrant\t<victim identity>\tvisualisers.wasm\t…
##     one `grant` call -> `parseTrustLedger` reads TWO rows, 0 problems
##     the VICTIM checkout, which the user had decided NOTHING about, RUNS
##
## The answer is a closed grammar and not an encoder: `representableField`
## refuses a TAB, a NEWLINE or a CARRIAGE RETURN in `identity`, `digest`, `at`
## or `note`; `record` is the one constructor and enforces it; `parseTrustLedger`
## goes through the same `record`; and `pathAnnotation` is where a path that
## cannot be a field loses its ANNOTATION rather than its GRANT. An escape
## sequence would be a second grammar with a second parser that has to agree
## with the first for ever, over rows written by builds that predate it.
##
## ## AND A REFUSAL THAT NOBODY CAN TELL FROM A NO-OP IS A REFUSAL NOBODY HEARS
##
## Closing the grammar made `record` refuse a row, which made `grant` and
## `revoke` answer `false` — and `false` already meant "this did not change what
## is in force", which is what a re-grant of an unchanged decision answers.
## **Two events with opposite consequences behind one value**, and both of this
## package's callers (`ct/launch/project_trust_store`) `discard`ed it and
## returned "" — their own spelling of SUCCESS. Measured on 2026-09-13:
##
##     revokeExecutableTier(…, at = "2026-09-13T00:00:00Z\n…") -> ""  (success)
##     rows written: 0        the definition it was about: STILL LOADING
##
## A grant that is not recorded fails closed. A REVOCATION that is not recorded
## fails OPEN — the user asked for the code to stop and was told it had. So
## `grant` and `revoke` answer a `TrustRecordOutcome` (six values, one meaning
## each), `decisionStands` is the one function that says which non-records are
## benign, and neither is `{.discardable.}`.
##
## ## PURE
##
## No filesystem, no clock, no process. The timestamp is a string the caller
## supplies, for the reason `grant_ledger.nim` gives: a record that could fail
## to load because a date did not parse is a record that fails OPEN on the day
## the format drifts.

import std/strutils

import ./project_definitions
import ./plugin_model/capabilities

export DefinitionFileKind, DefinitionTier, tierOf, definitionFileName,
       executableKinds, definitionPath

type
  RepositoryIdentity* = string
    ## An opaque identity for ONE checkout. Compared for equality and never
    ## parsed here — see the header. An empty identity is never granted
    ## anything, which is the fail-closed answer for a checkout whose identity
    ## could not be derived.

  TrustDecision* = enum
    ## THE ZERO VALUE IS THE REFUSING ONE, and the order is the whole reason
    ## these two are written the way round they are. `tdGranted` was first
    ## until 2026-09-13, which made `default(TrustDecision)` a GRANT — a
    ## producer that forgets to set the field gets maximum privilege, which is
    ## exactly the lesson `TrustState` below already carried and PLAT-12 paid
    ## for in `Visualiser.tier`. No site default-constructs one today; the
    ## ordering is what stops the first one that does.
    tdRevoked = "revoke"
    tdGranted = "grant"

  TrustState* = enum
    ## THE ZERO VALUE IS THE REFUSING ONE — see the header.
    tsUndecided
    tsGranted
    tsRevoked

  TrustEntry* = object
    identity*: RepositoryIdentity
    kind*: DefinitionFileKind
      ## WHICH FILE, because §6 puts the trust gate on a file rather than on a
      ## section of one: a project that ships a visualiser and a diff is asking
      ## for two decisions, and a user may take one of them back.
    decision*: TrustDecision
    digest*: string
      ## The content digest the decision was taken over. Empty on a `revoke`,
      ## which revokes the FILE for that repository rather than one version of
      ## it — a revocation that only covered the bytes in front of the user
      ## would be undone by the next edit.
    at*: string
      ## When, as the caller spelled it. Never parsed.
    note*: string
      ## Free text, last field on the line. In practice the checkout path AS IT
      ## WAS WHEN THE DECISION WAS TAKEN — which is inspection material and is
      ## **never** consulted by `admit`. §2.3's "by identity rather than by
      ## path" is a statement about what decides, not about what is shown.
      ##
      ## "FREE" IS BOUNDED BY THE GRAMMAR, and it has to be precisely because it
      ## is path-derived: see `representableField`. A note carrying a newline
      ## made one `grant` call record two decisions.

  ProjectTrustLedger* = object
    entries*: seq[TrustEntry]

  TrustLedgerParse* = object
    ledger*: ProjectTrustLedger
    problems*: seq[string]

  TrustRecordOutcome* = enum
    ## WHAT HAPPENED TO ONE DECISION, AS A CLOSED ENUM WITH ONE MEANING PER
    ## VALUE.
    ##
    ## `grant` and `revoke` returned a `bool` until 2026-09-13, and it meant two
    ## things: "this did not change what is in force" (a re-grant of the
    ## decision already recorded — benign) and "this was not recorded at all" (a
    ## field a ledger row cannot carry — a decision the user took and the
    ## machine did not keep). A caller cannot tell those apart, and
    ## `grantExecutableTier` / `revokeExecutableTier` `discard`ed the bool and
    ## answered "" — SUCCESS — for both. Measured on 2026-09-13:
    ##
    ##     revoke with an `at` carrying a newline -> "" (success), 0 rows written
    ##     the definition it was about: STILL LOADING, STILL RUNNING
    ##
    ## That is the direction `updateProjectTrustAt`'s own comment names as the
    ## one this record must never fail in — *"If the lost one is a `revoke`, the
    ## code is running again at the next start"* — reached without a race, by a
    ## caller passing a timestamp with a newline in it.
    ##
    ## THE ZERO VALUE IS A NON-RECORD, like every other zero value in this file:
    ## `recorded` is false for it, so a producer that forgets to set the field
    ## reports "nothing was written" rather than "it is recorded".
    troNoIdentity
      ## THE DEFAULT, and the zero value. No identity to record against.
    troNotExecutableTier
      ## A declarative file is not grantable.
    troNoDigest
      ## A grant with no digest. An empty digest is a MISMATCH in `admit` and
      ## never a wildcard, so recording one would be recording a decision that
      ## admits nothing.
    troUnchanged
      ## THE DECISION ASKED FOR IS ALREADY THE ONE IN FORCE. Nothing was
      ## appended and nothing needed to be — this is a success for a caller and
      ## is why `decisionStands` exists rather than `recorded` alone.
    troUnwritableField
      ## A field carries a tab, a newline or a carriage return, so NOTHING WAS
      ## APPENDED and what is in force is NOT what the caller asked for. This is
      ## the value that must never be confused with `troUnchanged`.
    troRecorded
      ## One row was appended and it is in force.

  ExecutableTierAdmission* = enum
    ## THE ONE DECISION, AS A CLOSED ENUM. `admit` is total over it and there is
    ## no `else`, so a new way for a module to be admitted is a compile error
    ## here rather than a silent permit at a call site — `IoRequestKind`'s own
    ## argument, in a different policy.
    ##
    ## THE ZERO VALUE IS THE REFUSING ONE. `etaAdmitted` sat at ordinal 0 until
    ## 2026-09-13, so `default(ExecutableTierAdmission)` — an uninitialised
    ## field, a `var` nobody assigned, a `seq` grown with `setLen` — was
    ## PERMISSION. Nothing reached it, which is precisely how the same defect
    ## reached PLAT-12's `Visualiser.tier`: latent until a producer forgot a
    ## field. `etaNoGrant` is the right zero because it is also THE DEFAULT in
    ## the sentence below, so the enum's zero and the policy's default are one
    ## fact rather than two that can drift.
    etaNoGrant
      ## No decision has ever been recorded. THE DEFAULT, and the zero value.
    etaAdmitted
    etaNotExecutableTier
      ## The caller asked about a declarative file. Declarative definitions load
      ## always and never come through here; asking is a programming error and
      ## is answered rather than assumed away.
    etaNoIdentity
      ## The checkout's identity could not be derived. Fail closed.
    etaRevoked
      ## A decision was recorded and taken back.
    etaContentChanged
      ## Granted, and the file is not the file that was granted.

const
  TrustLedgerHeader* = "# codetracer project executable-tier grants, v1"
  TrustFieldSeparator* = '\t'
    ## TAB, so a note may contain spaces and a reader needs no quoting rules —
    ## `grant_ledger.LedgerFieldSeparator`'s reasoning, and the same character,
    ## because a user looking at two ledgers under one directory should not have
    ## to learn two formats.

  ExecutableTierPrincipal* = "<project executable definition>"
    ## What a refusal from `capabilities.decide` names as its subject.
    ##
    ## It is NOT a plugin id and it is not empty. PLAT-10's `ledgerProblemErrors`
    ## took the same decision for the same reason: `diagnostics.namesPlugin` is
    ## swept over every error the suites build, and an anonymous subject fails
    ## that sweep — correctly. What this names is the tier, because that is what
    ## the refusal is about.

  ExecutableTierGrants* = GrantSet()
    ## §2.3: "**strictly less** [than a plugin]: no network, ever; no filesystem
    ## beyond what they are handed; no process spawning."
    ##
    ## THE EMPTY SET, IN PLAT-8'S OWN MODEL. Writing it as a `GrantSet` rather
    ## than as a sentence means the claim is checkable by the function that
    ## already decides these things: `project_trust_test` enumerates every
    ## `IoRequestKind` and asserts `decide` refuses each one, and asserts the
    ## same set through `effectiveCapabilities` so that the subsumption rule
    ## PLAT-8 added for `process` is in the path too.
    ##
    ## It is also why "strictly less" is a MEASUREMENT rather than an assertion:
    ## the suite compares this set against a plugin's and asserts it is a proper
    ## subset of every non-empty grant a plugin can hold.

func executableTierCapabilities*(): set[Capability] =
  ## What an executable definition holds, asked THROUGH PLAT-8's subsumption
  ## rule rather than read off the field.
  ##
  ## `effectiveCapabilities` is "the one function that knows about subsumption"
  ## (`capabilities.nim`), and asking it here is what makes the floor survive a
  ## later milestone adding a capability to `SubsumingCapabilities`: this
  ## function's answer is derived, so it cannot go on saying "empty" while the
  ## model beneath it has changed.
  effectiveCapabilities(ExecutableTierGrants.capabilities)

func executableTierDecision*(req: IoRequest): Decision =
  ## PLAT-8's `decide`, called with the floor. THE ONLY WAY this module answers
  ## "may an executable definition do X", so the rule and its control are one
  ## function (Verification-Harness-Traps §14).
  decide(ExecutableTierGrants, ExecutableTierPrincipal, req)

# ---------------------------------------------------------------------------
# Reading the ledger
# ---------------------------------------------------------------------------

func stateOf*(ledger: ProjectTrustLedger; identity: RepositoryIdentity;
              kind: DefinitionFileKind): TrustState =
  ## THE LAST ENTRY WINS, scanned backwards so the rule is visible rather than
  ## implied by a fold — `grant_ledger.stateOf`'s shape, for the same reason.
  if identity.len == 0: return tsUndecided
  for i in countdown(ledger.entries.high, 0):
    let e = ledger.entries[i]
    if e.identity == identity and e.kind == kind:
      return (if e.decision == tdGranted: tsGranted else: tsRevoked)
  tsUndecided

func grantedDigest*(ledger: ProjectTrustLedger; identity: RepositoryIdentity;
                    kind: DefinitionFileKind): string =
  ## The digest the decision in force was taken over, or "".
  if identity.len == 0: return ""
  for i in countdown(ledger.entries.high, 0):
    let e = ledger.entries[i]
    if e.identity == identity and e.kind == kind:
      return (if e.decision == tdGranted: e.digest else: "")
  ""

func decidedAt*(ledger: ProjectTrustLedger; identity: RepositoryIdentity;
                kind: DefinitionFileKind): string =
  if identity.len == 0: return ""
  for i in countdown(ledger.entries.high, 0):
    let e = ledger.entries[i]
    if e.identity == identity and e.kind == kind:
      return e.at
  ""

type
  ReadDecision* = object
    ## WHETHER THE BYTES MAY BE READ AT ALL — a different type from an
    ## admission, deliberately.
    ##
    ## The decision genuinely has two phases, because the digest that binds a
    ## grant to its bytes cannot be computed without reading the bytes. The
    ## danger in a two-phase decision is that a caller runs a module on the
    ## strength of phase one, so phase one does not return the same type:
    ## `admits` is not defined over `ReadDecision`, and the only way to obtain an
    ## `ExecutableTierAdmission` is `admit`, which takes a digest.
    ##
    ## Both phases read ONE private predicate (`preDigestVerdict`), so they
    ## cannot come to disagree about whether a grant is in force
    ## (Verification-Harness-Traps §14: one predicate, one function, with every
    ## caller going through it).
    permitted*: bool
    refusal*: ExecutableTierAdmission
      ## Meaningful when `permitted` is false.

func preDigestVerdict(ledger: ProjectTrustLedger;
                      identity: RepositoryIdentity;
                      kind: DefinitionFileKind): ExecutableTierAdmission =
  ## Everything decidable WITHOUT the bytes. `etaAdmitted` from here means
  ## exactly "a grant is in force for this file in this checkout", which is
  ## permission to look at the file and nothing else.
  if tierOf(kind) != dtExecutable: return etaNotExecutableTier
  if identity.len == 0: return etaNoIdentity
  case ledger.stateOf(identity, kind)
  of tsUndecided: etaNoGrant
  of tsRevoked: etaRevoked
  of tsGranted: etaAdmitted

func mayReadBytes*(ledger: ProjectTrustLedger; identity: RepositoryIdentity;
                   kind: DefinitionFileKind): ReadDecision =
  ## May the host OPEN this executable definition?
  ##
  ## Asked before the file is opened, because "we parsed it but did not run it"
  ## still exposes a decoder — a parser over hostile input — to a repository
  ## nobody agreed to trust. The refusal is therefore observable as a syscall
  ## that did not happen, which is what lets PLAT-13's gate be asserted on an
  ## effect rather than on a returned status.
  let v = preDigestVerdict(ledger, identity, kind)
  ReadDecision(permitted: v == etaAdmitted, refusal: v)

func admit*(ledger: ProjectTrustLedger; identity: RepositoryIdentity;
            kind: DefinitionFileKind; digest: string): ExecutableTierAdmission =
  ## THE DECISION. Every path that could decode or run an executable definition
  ## goes through this one function.
  ##
  ## It is `mayReadBytes`'s predicate plus the digest test, in that order, so
  ## the four refusals a reader can meet before opening a file are the same four
  ## objects afterwards.
  let pre = preDigestVerdict(ledger, identity, kind)
  if pre != etaAdmitted: return pre
  let granted = ledger.grantedDigest(identity, kind)
  # AN EMPTY DIGEST ON EITHER SIDE IS A MISMATCH, never a wildcard. A grant
  # recorded with no digest, or a file whose digest could not be computed,
  # must not admit anything: the one direction this decision may not fail in
  # is "permitted because something was missing".
  if granted.len == 0 or digest.len == 0 or granted != digest:
    return etaContentChanged
  etaAdmitted

func admits*(a: ExecutableTierAdmission): bool =
  ## Whether this admission lets anything happen. A FUNCTION and not `a ==
  ## etaAdmitted` at four call sites, so "is this permitted" has one
  ## implementation and a new admission value cannot be permissive by accident
  ## at the site somebody forgot.
  a == etaAdmitted

func admissionText*(a: ExecutableTierAdmission): string =
  ## The human half. Written here rather than at each call site so one
  ## admission cannot acquire two spellings.
  case a
  of etaAdmitted: "admitted"
  of etaNotExecutableTier: "not an executable-tier definition"
  of etaNoIdentity: "this checkout has no identity to record a grant against"
  of etaNoGrant: "no trust grant has been recorded for this repository"
  of etaRevoked: "the trust grant for this repository was revoked"
  of etaContentChanged:
    "the executable definition is not the one the grant was given for"

func admissionRemedy*(a: ExecutableTierAdmission): string =
  ## WHAT TO DO ABOUT IT, kept separate from `admissionText` for the reason
  ## PLAT-12 keeps `describeAttribution` and `describeDegradation` apart: a
  ## one-line report has room for the first and not the second, and a remedy
  ## that cannot work is worse than none (§8.2 of Extensibility-Model.md).
  case a
  of etaAdmitted: ""
  of etaNotExecutableTier:
    "Declarative definitions load without a decision and do not come through " &
    "the trust gate at all"
  of etaNoIdentity:
    "The checkout directory could not be identified. A grant is recorded " &
    "against the checkout itself rather than against its path, so there is " &
    "nothing to record one against"
  of etaNoGrant:
    "Read the file, then grant the executable tier for THIS checkout. " &
    "Cloning a repository never grants it (Project-Definitions.md §2)"
  of etaRevoked:
    "Grant it again for this checkout if you have changed your mind. " &
    "Reinstalling, re-cloning or pulling does not undo a revocation"
  of etaContentChanged:
    "The file changed after the grant — a pull, a rebase or an edit. Read " &
    "the new file and grant it again; a grant covers the bytes it was given for"

# ---------------------------------------------------------------------------
# Writing the ledger
# ---------------------------------------------------------------------------

func representableField*(s: string): bool =
  ## MAY THIS STRING BE A FIELD OF A LEDGER ROW?
  ##
  ## THE GRAMMAR IS CLOSED AND THE ANSWER IS A REFUSAL, NOT AN ENCODER. The
  ## format is one row per line and one TAB between fields, so a field carrying
  ## a TAB is a field that becomes two, and a field carrying a NEWLINE is a
  ## field that becomes a ROW. Measured on 2026-09-13, before this existed:
  ##
  ##     grantExecutableTier(user, "/evil\n" & "grant\t<victim>\t…", …)
  ##
  ## recorded ONE decision and `parseTrustLedger` read back TWO, with no
  ## problems reported — so granting one checkout granted another, against
  ## §2.3 and against `grant`'s own "ONE repository, ONE file and ONE digest".
  ## The default `note` is the CHECKOUT PATH, and a path is the most
  ## attacker-reachable string in this record: a repository is cloned into a
  ## directory whose name a `git clone` argument, a CI template or an archive
  ## can choose.
  ##
  ## Escaping was considered and refused. An encoder is a second grammar with a
  ## second parser, and the two have to agree for ever over rows written by
  ## older builds; a closed grammar has one rule and no version. The cost is
  ## real and is paid where it is cheapest: a checkout path that cannot be a
  ## field loses its *annotation* (see `pathAnnotation`), never its grant.
  ##
  ## `\r` is refused with the other two because `parseTrustLedger` strips a
  ## trailing `\r` for CRLF files, so a `\r` INSIDE a field would survive a
  ## round trip on one platform and not on another.
  for c in s:
    if c == TrustFieldSeparator or c == '\n' or c == '\r': return false
  true

func unrepresentableFieldText*(): string =
  ## What a refusal says, in one place so the message cannot acquire two
  ## spellings (`codeText`'s rule).
  "a tab, a newline or a carriage return, which a ledger row cannot carry"

const
  UnrepresentablePathNote* =
    "(the checkout path contains a character a ledger row cannot carry)"
    ## Substituted for a path-derived annotation that is not a legal field.
    ## It is a CONSTANT and not the path with the offending bytes removed: a
    ## mangled path looks like a path and would be read as one, and the useful
    ## fact here is that the annotation is missing rather than what it nearly
    ## was. The GRANT is unaffected — §2.3's "by identity rather than by path"
    ## means nothing in this row's decision came from the path in the first
    ## place.

func pathAnnotation*(path: string): string =
  ## The default `note` for a decision taken about a checkout at `path`.
  ##
  ## DERIVING THE NOTE FROM A PATH IS THIS PACKAGE'S DECISION, so refusing the
  ## paths that cannot be a field is this package's job — the alternative is a
  ## caller that has to remember, which is the shape PLAT-8's `ReadOutcome`
  ## argues against. One function, two callers (`grantExecutableTier` and
  ## `revokeExecutableTier`), so the grant and the revocation cannot come to
  ## disagree about what a path may say.
  if representableField(path): path else: UnrepresentablePathNote

func recorded*(o: TrustRecordOutcome): bool =
  ## Did this append a row? A FUNCTION and not `o == troRecorded` at each call
  ## site, for `admits`' own reason (§14): a new outcome cannot become
  ## "recorded" by accident at the site somebody forgot.
  o == troRecorded

func decisionStands*(o: TrustRecordOutcome): bool =
  ## IS WHAT THE CALLER ASKED FOR WHAT IS IN FORCE NOW? — which is the question
  ## a user action has, and it is NOT `recorded`. Re-granting a decision already
  ## recorded appends nothing and is a success; a field that could not be
  ## written appends nothing and is a failure. One function, so the grant's
  ## reporting and the revocation's cannot come to disagree about which
  ## non-records are benign (§14), and so that "the two reasons" have one place
  ## to be told apart rather than a test spelled out at each caller.
  o in {troRecorded, troUnchanged}

func outcomeText*(o: TrustRecordOutcome): string =
  ## What a caller reports, in one place so one outcome cannot acquire two
  ## spellings (`codeText`'s rule). TOTAL over the enum, so a new outcome is a
  ## compile error here rather than an unreportable answer.
  case o
  of troRecorded: "recorded"
  of troUnchanged: "that decision was already the one in force"
  of troNoIdentity: "there is no checkout identity to record it against"
  of troNotExecutableTier:
    "a declarative definition loads without a decision, so there is nothing " &
    "to record"
  of troNoDigest:
    "a grant records the digest it was given for, and none was supplied"
  of troUnwritableField:
    "a field carries " & unrepresentableFieldText()

proc record*(ledger: var ProjectTrustLedger; identity: RepositoryIdentity;
             kind: DefinitionFileKind; decision: TrustDecision;
             digest, at, note: string): bool {.discardable.} =
  ## Append one row. `false`, AND NOTHING APPENDED, when any field is not
  ## representable — see `representableField`.
  ##
  ## THIS ONE STAYS A `bool` BECAUSE IT HAS ONE FAILURE MODE. `grant` and
  ## `revoke` answer a `TrustRecordOutcome` because their `false` meant two
  ## different things; this function's does not — a row is appended or a field
  ## could not be written — so a second vocabulary here would be a type with one
  ## inhabited failure and nothing to tell apart.
  ##
  ## THIS IS THE ONE PLACE THIS PACKAGE CONSTRUCTS A `TrustEntry`, which is what
  ## makes `render` total over what it can be handed: `grant`, `revoke` and the
  ## suites all come through here, and `parseTrustLedger` — the only other
  ## producer — splits on exactly the characters this refuses, so no field it
  ## yields can contain one. A third party constructing a `TrustEntry` literal
  ## and pushing it onto `entries` is outside that closure; the fields are
  ## exported because `describe` and the suites read them, and Nim has no
  ## read-only export.
  if not representableField(identity) or not representableField(digest) or
     not representableField(at) or not representableField(note):
    return false
  ledger.entries.add TrustEntry(identity: identity, kind: kind,
                                decision: decision, digest: digest, at: at,
                                note: note)
  true

proc grant*(ledger: var ProjectTrustLedger; identity: RepositoryIdentity;
            kind: DefinitionFileKind; digest, at: string;
            note = ""): TrustRecordOutcome =
  ## Record a grant for ONE repository, ONE file and ONE digest, and say WHICH
  ## of the six things happened.
  ##
  ## NOT `{.discardable.}`, AND `record` STILL IS. Dropping this answer is how
  ## a decision goes unrecorded in silence, so a caller that does not want it
  ## has to write `discard` and be seen doing it. `record` keeps the pragma
  ## because the suites build ledgers with it and its answer has one meaning.
  ##
  ## A DECLARATIVE FILE IS NOT GRANTABLE, and the refusal is here rather than at
  ## the caller: a ledger entry for `points.toml` would be an inert row that
  ## looks like a decision, and a user reading `describe` would be told they had
  ## trusted something that never needed trusting.
  if tierOf(kind) != dtExecutable: return troNotExecutableTier
  if identity.len == 0: return troNoIdentity
  if digest.len == 0: return troNoDigest
  if ledger.stateOf(identity, kind) == tsGranted and
     ledger.grantedDigest(identity, kind) == digest:
    return troUnchanged
  # A FIELD THAT CANNOT BE WRITTEN IS A DECISION THAT IS NOT TAKEN, AND IT IS
  # NOT THE SAME ANSWER AS "NOTHING NEEDED WRITING". `record` refuses and
  # appends nothing; this says `troUnwritableField`, which `decisionStands`
  # separates from `troUnchanged` — the distinction the caller needs and did not
  # have while both were `false`.
  if ledger.record(identity, kind, tdGranted, digest, at, note): troRecorded
  else: troUnwritableField

proc revoke*(ledger: var ProjectTrustLedger; identity: RepositoryIdentity;
             kind: DefinitionFileKind; at: string;
             note = ""): TrustRecordOutcome =
  ## `grant`'s twin, with the same six answers and the same reason for them.
  ##
  ## REVOKING AN UNDECIDED FILE IS RECORDED, not ignored — `grant_ledger.revoke`'s
  ## asymmetry, and it is worth MORE here than there. A user who has read a
  ## repository and decided in advance that they do not want its executable tier
  ## has taken a decision, and a ledger that dropped it would ask them the
  ## question again on the next launch.
  ##
  ## AND THE OUTCOME MATTERS MOST ON THIS SIDE. A grant that is not recorded
  ## fails closed — nothing runs that was not going to run anyway. A REVOCATION
  ## that is not recorded fails OPEN: the user asked for the code to stop, and
  ## it does not. Everything above `troRecorded` here has to reach the caller.
  if tierOf(kind) != dtExecutable: return troNotExecutableTier
  if identity.len == 0: return troNoIdentity
  if ledger.stateOf(identity, kind) == tsRevoked: return troUnchanged
  if ledger.record(identity, kind, tdRevoked, "", at, note): troRecorded
  else: troUnwritableField

proc forget*(ledger: var ProjectTrustLedger;
             identity: RepositoryIdentity): int {.discardable.} =
  ## Drop every entry for a checkout. The ONE operation that is not append-only,
  ## and it exists for the case `grant_ledger.forget` exists for: a checkout that
  ## is gone. A ledger that kept decisions for checkouts nobody has any more
  ## would grow without bound and would re-apply a grant to whatever later
  ## acquired the same identity.
  var kept: seq[TrustEntry] = @[]
  for e in ledger.entries:
    if e.identity == identity: inc result
    else: kept.add e
  ledger.entries = kept

func identities*(ledger: ProjectTrustLedger): seq[RepositoryIdentity] =
  ## Every checkout the ledger has an opinion about, in first-mention order.
  for e in ledger.entries:
    if e.identity notin result: result.add e.identity

# ---------------------------------------------------------------------------
# What a user reads
# ---------------------------------------------------------------------------

func describe*(ledger: ProjectTrustLedger;
               identity: RepositoryIdentity): string =
  ## §2.3's "visible — a user can see what is trusted and withdraw it".
  ##
  ## THE HISTORY IS IN THE ANSWER. "granted 2026-09-01, revoked 2026-09-12" is
  ## the fact the deliverable is about, and a view showing only the current
  ## state could not tell a user they had ever granted it.
  var lines: seq[string] = @[]
  for e in ledger.entries:
    if e.identity != identity: continue
    lines.add "  " & (if e.decision == tdGranted: "granted" else: "REVOKED") &
      " " & definitionFileName(e.kind) & " at " & e.at &
      (if e.digest.len > 0: " (" & e.digest & ")" else: "") &
      (if e.note.len > 0: " — " & e.note else: "")
  if lines.len == 0:
    return "checkout '" & identity &
      "': no executable-tier decision has been recorded"
  var inForce: seq[string] = @[]
  for k in executableKinds():
    if ledger.stateOf(identity, k) == tsGranted:
      inForce.add definitionFileName(k)
  "checkout '" & identity & "':\n" & lines.join("\n") & "\n  in force now: " &
    (if inForce.len == 0: "(nothing)" else: inForce.join(", "))

func trustDisclosure*(identity: RepositoryIdentity; kind: DefinitionFileKind;
                      digest, checkoutPath: string): string =
  ## WHAT THE USER IS BEING ASKED, derived from the grant rather than quoted
  ## from anybody's description of it.
  ##
  ## PLAT-8's `traceEgressDisclosure` established the rule and the reason: "an
  ## author's sentence is what they were willing to write, and a user needs to
  ## be told what the grant actually permits". Here there is no author's
  ## sentence at all — a project definition carries no manifest and no prose —
  ## so the whole disclosure is derived: the file, the checkout, the digest, and
  ## the capability floor read OUT OF THE FLOOR rather than restated.
  var caps: seq[string] = @[]
  for c in Capability:
    if c in executableTierCapabilities(): caps.add $c
  result = "You are being asked to trust '" & definitionFileName(kind) &
    "' from the checkout at " & checkoutPath & ".\n" &
    "  It is CODE from that repository. Cloning and opening never ran it; " &
    "granting this is what runs it.\n" &
    "  The grant covers THIS checkout only (" & identity & ") and THESE " &
    "bytes only (" & digest & "). A copy of this checkout, a different " &
    "repository later at the same path, and this same file after it changes " &
    "are all separate decisions.\n" &
    "  What it may do: compute, in a sandbox with " &
    (if caps.len == 0: "no capabilities at all"
     else: "the capabilities " & caps.join(", ")) &
    ". It cannot open a file, reach the network or start a process — an " &
    "executable definition is handed no host functions, so there is nothing " &
    "for it to call.\n" &
    "  What it may still do: spend the host's time, up to a bound, and return " &
    "a wrong answer. A visualiser that lies about a value is a visualiser you " &
    "trusted.\n" &
    "  You can withdraw this at any time, and withdrawing it stops the code " &
    "running rather than only recording that you changed your mind."

# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

func render*(ledger: ProjectTrustLedger): string =
  ## `<decision>\t<identity>\t<file>\t<digest>\t<at>\t<note>` per entry, in
  ## order.
  ##
  ## IT DOES NOT ESCAPE AND IT DOES NOT NEED TO: every entry this package
  ## produces came through `record`, which refuses a field carrying a tab, a
  ## newline or a carriage return. `<file>` is `definitionFileName(kind)` over a
  ## closed enum and `<decision>` is `$TrustDecision`, so those two are closed
  ## by their types. That is the whole argument for there being no encoder here,
  ## and it is only sound while `record` is the one constructor — which is what
  ## its own comment records.
  var lines: seq[string] = @[TrustLedgerHeader]
  for e in ledger.entries:
    lines.add [$e.decision, e.identity, definitionFileName(e.kind), e.digest,
               e.at, e.note].join($TrustFieldSeparator)
  lines.join("\n") & "\n"

func kindForFileName(name: string; dest: var DefinitionFileKind): bool =
  ## DERIVED from `layout.definitionFileName` by a fold over the enum, so the
  ## reader and the writer cannot disagree about what a row names.
  for k in DefinitionFileKind:
    if definitionFileName(k) == name:
      dest = k
      return true
  false

func parseTrustLedger*(text: string): TrustLedgerParse =
  ## Total. Every unusable line becomes a problem naming its number; nothing
  ## raises, because this is read at start-up and a start-up that dies on a
  ## stray byte in a state file is worse than one that says what it could not
  ## read (`grant_ledger.parseLedger`, same argument).
  ##
  ## A ROW NAMING A DECLARATIVE FILE IS A PROBLEM, not a silently kept entry.
  ## The trust gate applies to the executable tier; a `grant … points.toml` row
  ## would be a decision about something that needs none, and keeping it would
  ## put it in front of a user in `describe`.
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    let line = rawLine.strip(leading = false, trailing = true, chars = {'\r'})
    if line.len == 0: continue
    if line[0] == '#': continue
    let parts = line.split(TrustFieldSeparator)
    if parts.len < 5 or parts.len > 6:
      # THE ROW HAS FIVE FIELDS OR SIX, AND NEVER MORE. The note used to be
      # `parts[5 .. ^1].join(tab)`, which is a decoder for an encoding the
      # writer no longer emits — `record` refuses a field carrying a tab
      # (`representableField`). Rejoining is how a reader and a writer come to
      # disagree about how many fields a row has, and a seven-field row can now
      # only be a hand edit or an injection attempt: both are worth naming.
      result.problems.add "line " & $lineNo & ": expected five or six " &
        "tab-separated fields (decision, checkout, file, digest, when, and an " &
        "optional note), got " & $parts.len
      continue
    var decision: TrustDecision
    var decisionOk = false
    for d in TrustDecision:
      if $d == parts[0]:
        decision = d
        decisionOk = true
    if not decisionOk:
      result.problems.add "line " & $lineNo & ": '" & parts[0] &
        "' is neither 'grant' nor 'revoke'"
      continue
    if parts[1].len == 0:
      result.problems.add "line " & $lineNo & ": the checkout identity is empty"
      continue
    var kind: DefinitionFileKind
    if not kindForFileName(parts[2], kind):
      var known: seq[string] = @[]
      for k in executableKinds(): known.add definitionFileName(k)
      result.problems.add "line " & $lineNo & ": '" & parts[2] &
        "' is not a definition file; the executable-tier files are " &
        known.join(", ")
      continue
    if tierOf(kind) != dtExecutable:
      result.problems.add "line " & $lineNo & ": '" & parts[2] &
        "' is a declarative definition. It loads without a decision, so a " &
        "trust row for it would be a decision about nothing"
      continue
    # THROUGH `record`, so the reader cannot admit a row the writer would
    # refuse (§14: one predicate, one function). It cannot fail here — the
    # split removed every tab and `splitLines` every newline — and going
    # through it anyway is what keeps that true if either rule changes.
    if not result.ledger.record(parts[1], kind, decision, parts[3], parts[4],
                                (if parts.len > 5: parts[5] else: "")):
      result.problems.add "line " & $lineNo & ": a field carries " &
        unrepresentableFieldText()
