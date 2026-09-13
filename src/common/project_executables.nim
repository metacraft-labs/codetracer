## project_executables.nim — PLAT-13. THE ONE CROSSING: a trust decision and a
## pile of bytes become something that can run, or a named refusal.
##
## PLAT-12 put its crossing in `common/value_visualisers.nim` — "a THIRD module
## both may be imported by and neither is … one crossing plus `admit`, the only
## door" — and this file is the same shape for the tier above it:
##
##   * `project_trust.nim` decides. It has no bytes and no interpreter.
##   * `project_wasm.nim` decodes and runs. It has no idea what a grant is.
##   * this file is the only place the two meet, and `admitExecutable` is the
##     only door.
##
## ## THE BYTES ARE NOT DECODED WITHOUT THE GRANT, WHICH IS STRONGER THAN NOT RUN
##
## `admitExecutable` tests the admission BEFORE it calls `decodeModule`. That
## ordering is the deliverable rather than tidiness: a decoder is a parser over
## hostile input, so "we parsed it but did not run it" still exposes the parser
## to a repository nobody agreed to trust. §2's sentence is "must not execute
## code from that repository", and the cheapest way to be sure nothing executed
## is for nothing to have been looked at.
##
## The disk half (`ct/launch/project_executable_tier.nim`) takes the same
## ordering one step further out: without an admission it does not `open(2)` the
## file at all, so the refusal is observable as a syscall that did not happen.
##
## ## AND THE GRANT IS ASKED AGAIN ON EVERY RUN, BECAUSE THE HANDLE IS A CACHE
##
## `admitExecutable` answers about the bytes ONCE. `ExecutableDefinition.module`
## is that answer, kept — which is the point of a handle and is also how a
## withdrawn decision gets outlived. So `visualiseWith` and `diffWith` take a
## `ProjectTrustLedger` and re-ask through `stillAdmitted` before anything runs.
##
## This was found on 2026-09-13 by a verification pass, and the shape is worth
## stating because the suite that should have caught it was asserting the right
## thing the wrong way: revocation was asserted by RE-LOADING the checkout and
## finding no definitions, and a fresh load is exactly what cannot see a handle
## somebody is already holding. Measured, before the repair:
##
##     before revoke: held = 1, visualised = EXECUTABLE-TIER-RAN-ct-plat13
##     after revoke, a FRESH load: 0 definitions
##     after revoke, the HELD handle: STILL RUNS
##
## It is PLAT-10's `resolveAll()` one tier up, and it falsified a sentence a
## user reads: `trustDisclosure` promises that "withdrawing it stops the code
## running rather than only recording that you changed your mind".
##
## ## EVERY ANSWER SAYS WHO ANSWERED
##
## `fromDefinition` is on every result record. §7 requires the host to "bound
## [a diff], report the offender by name, and fall back to the structural diff",
## and a fallback that is indistinguishable from a success is a fallback nobody
## can audit — PLAT-12's `describeAttribution` exists for the same reason one
## level down. So a caller can always tell whether the project's code produced
## the answer, and when it did not, `offender` names the file and the export and
## `problems` says what happened.
##
## ## THE WORK BOUND IS ONE ALLOWANCE ACROSS THE WHOLE CALL
##
## Instantiating the module, writing the inputs in, running, and reading the
## answer out are all charged against `MaxExecutableWork`, and `spent` is
## reported whether or not there was an answer. PLAT-12 spent four verification
## rounds on the sentence a bound whose report is constant in the quantity being
## multiplied is a bound on the wrong quantity; the answer taken here is its
## remedy — one charge per quantity, at the site that spends it, with the bound
## tested in the one loop every instruction passes through.
##
## ## PURE
##
## No filesystem, no clock, no process. It runs in `common-units`.

import std/strutils

import ./project_trust
import ./project_wasm
import ./project_definitions/layout

export project_trust, project_wasm

type
  ExecutableTierCode* = enum
    ## Why an executable definition produced nothing. Ordered by the phase that
    ## discovers it: the grant, the file, the module, the run.
    ##
    ## IT IS A SEPARATE VOCABULARY FROM PLAT-11'S `ProjectDefinitionCode`, and
    ## that is the same decision PLAT-11 took about `plugin_model`'s errors: a
    ## declarative refusal is "this file is malformed and here is the line", and
    ## every code below is "this file was not trusted, or its code misbehaved".
    ## A reader who meets `unknown key 'interpreter'` and `no trust grant has
    ## been recorded` in one column needs to be able to tell which of the two is
    ## a decision they can take.
    etcNoGrant
    etcRevoked
    etcContentChanged
    etcNoIdentity
    etcNotExecutableTier
    etcNotContained
      ## The file is not where a definition file must be — a symlink, or a path
      ## that resolves outside the checkout. PLAT-11 measured this exact escape
      ## in the DECLARATIVE reader, where the consequence was a leaked READ; here
      ## the consequence would be running bytes from outside the repository the
      ## user granted.
    etcUnreadable
    etcMalformedModule
    etcMissingExport
    etcTrapped
    etcWorkExhausted
    etcOutputRefused
      ## The module answered with something the host will not take: an address
      ## outside its own memory, or text past the bound.

  ExecutableTierProblem* = object
    file*: string
      ## ALWAYS set and repository-relative. PLAT-11's `diagnostics` header
      ## argues it: a project definition arrives by `git clone`, so a reader has
      ## no prior relationship with the file and a message that does not name it
      ## tells them nothing.
    code*: ExecutableTierCode
    detail*: string

  ExecutableDefinition* = object
    ## AN ADMITTED MODULE. There is no way to construct one of these except
    ## through `admitExecutable`, and `admitExecutable` will not build one
    ## without `project_trust.admits`.
    ##
    ## ## IT IS A CACHED PARSE, SO IT CARRIES WHAT IT WAS ADMITTED UNDER
    ##
    ## `module` is the decode taken at admission time, and a handle that ran on
    ## the strength of that decode alone would be PLAT-10's `resolveAll()`
    ## exactly: a capability the user withdrew, still held by whoever already
    ## had it. `trustDisclosure` promises "withdrawing it stops the code running
    ## rather than only recording that you changed your mind", and a sentence
    ## about the NEXT session is not that promise.
    ##
    ## So `identity`, `kind` and `digest` are on the handle, `stillAdmitted`
    ## re-asks `project_trust.admit` with them, and **every entry point that
    ## runs anything takes a ledger and calls it first**. Re-loading and finding
    ## nothing is the shape that cannot see a held handle, which is why
    ## `C_REVOKED_HANDLE` asserts THROUGH the handle instead.
    kind*: DefinitionFileKind
    file*: string
    digest*: string
    identity*: RepositoryIdentity
      ## The checkout this was admitted for. Compared, never parsed.
    module*: WasmModule

  ExecutableAdmission* = object
    ok*: bool
    definition*: ExecutableDefinition
    problem*: ExecutableTierProblem

  DiffVerdict* = enum
    dvEqual
    dvDifferent

  DiffAnswer* = object
    ## §7's answer, and who gave it.
    verdict*: DiffVerdict
    fromDefinition*: bool
    offender*: string
      ## Empty when the project's own code answered. Otherwise the file and the
      ## export that failed, so §7's "reports the offender by name" is a name.
    problems*: seq[ExecutableTierProblem]
    spent*: int
    bound*: int

  VisualisedText* = object
    text*: string
    fromDefinition*: bool
    offender*: string
    problems*: seq[ExecutableTierProblem]
    spent*: int
    bound*: int

const
  VisualiserExport* = "ct_visualise"
    ## `(i32 ptr, i32 len) -> i32 ptr`. The host writes the value's rendering
    ## input at `ptr`, the module returns the address of a NUL-terminated
    ## answer.
  DiffExport* = "ct_diff"
    ## `(i32 aPtr, i32 aLen, i32 bPtr, i32 bLen) -> i32`. Zero means equal.

  ExecutableScratchBytes* = 1024
    ## `[0, 1024)` belongs to the module: it is where an answer is written, and
    ## the host never writes there. A module that wants more uses the space
    ## above its inputs.

  ExecutableInputBase* = ExecutableScratchBytes
  MaxExecutableInputBytes* = 4096
    ## Per input. Two inputs fit inside one wasm page with room to spare, which
    ## is what keeps `MaxWasmPages` at four rather than at "whatever a module
    ## asks for".

  MaxExecutableTextBytes* = MaxSummaryBytes
    ## THE SAME BOUND A DECLARATIVE SUMMARY HAS (`layout.MaxSummaryBytes`),
    ## because the two produce the same thing — a summary line for a value — and
    ## a second number here would be a second thing to keep in step (§14). An
    ## executable visualiser is not entitled to a longer answer than a declared
    ## one for being code.

func problem(file: string; code: ExecutableTierCode;
             detail: string): ExecutableTierProblem =
  ExecutableTierProblem(file: file, code: code, detail: detail)

func codeText*(c: ExecutableTierCode): string =
  ## The human half of the code, in one place, so one code cannot acquire two
  ## spellings (PLAT-11's `diagnostics.codeText`, same rule).
  case c
  of etcNoGrant: "no trust grant for this repository"
  of etcRevoked: "the trust grant was revoked"
  of etcContentChanged: "the file is not the file that was granted"
  of etcNoIdentity: "this checkout has no identity"
  of etcNotExecutableTier: "not an executable-tier definition"
  of etcNotContained: "the definition file is not inside this checkout"
  of etcUnreadable: "the definition file could not be read"
  of etcMalformedModule: "not a module this build will run"
  of etcMissingExport: "the module does not export what the host calls"
  of etcTrapped: "the definition's code trapped"
  of etcWorkExhausted: "the definition's code reached its work bound"
  of etcOutputRefused: "the definition's code returned an answer the host refused"

func render*(p: ExecutableTierProblem): string =
  ## THE FILE COMES FIRST — a reader scanning a column must be able to attribute
  ## every line without reading to the end of it.
  result = p.file & ": " & codeText(p.code)
  if p.detail.len > 0: result.add ": " & p.detail

func namesFile*(p: ExecutableTierProblem): bool =
  ## The property the suite sweeps for, as a FUNCTION so the rule and its
  ## control are one piece of code (§14).
  p.file.len > 0 and render(p).contains(p.file)

func codeFor*(a: ExecutableTierAdmission): ExecutableTierCode =
  ## The admission, as a problem code. TOTAL over `ExecutableTierAdmission`, so
  ## a new admission value is a compile error here rather than an admission with
  ## no way to be reported.
  case a
  of etaAdmitted: etcNoGrant     # never reached; `admitExecutable` returns first
  of etaNotExecutableTier: etcNotExecutableTier
  of etaNoIdentity: etcNoIdentity
  of etaNoGrant: etcNoGrant
  of etaRevoked: etcRevoked
  of etaContentChanged: etcContentChanged

# ---------------------------------------------------------------------------
# The door
# ---------------------------------------------------------------------------

func admitExecutable*(kind: DefinitionFileKind; file, digest, bytes: string;
                      admission: ExecutableTierAdmission;
                      identity: RepositoryIdentity = ""): ExecutableAdmission =
  ## THE ONLY WAY BYTES BECOME SOMETHING THAT CAN RUN.
  ##
  ## The admission is tested FIRST and `bytes` is not looked at on the refusing
  ## path — see the header. `bytes` is a parameter rather than something this
  ## function fetches because fetching is the filesystem's job and this module
  ## has no filesystem; the caller that read the file is the caller that had a
  ## grant in hand.
  if not admits(admission):
    return ExecutableAdmission(problem: problem(file, codeFor(admission),
      admissionText(admission) & ". " & admissionRemedy(admission)))
  let decoded = decodeModule(bytes)
  if not decoded.ok:
    return ExecutableAdmission(problem: problem(file, etcMalformedModule,
      render(decoded.problem)))
  ExecutableAdmission(ok: true, definition: ExecutableDefinition(
    kind: kind, file: file, digest: digest, identity: identity,
    module: decoded.module))

func stillAdmitted*(d: ExecutableDefinition;
                    trust: ProjectTrustLedger): ExecutableTierAdmission =
  ## IS THIS HANDLE STILL ALLOWED TO RUN? Asked again, against the ledger as it
  ## is NOW, out of the identity/kind/digest the handle was admitted under.
  ##
  ## It is `project_trust.admit` and not a second decision — one predicate, one
  ## function, with `visualiseWith` and `diffWith` both going through this one
  ## (Verification-Harness-Traps §14). A revoked grant, a forgotten checkout,
  ## and a re-grant over different bytes all refuse here, each with its own
  ## code, and the handle is what supplies the key.
  admit(trust, d.identity, d.kind, d.digest)

func exportFor*(kind: DefinitionFileKind): string =
  ## Which function the host calls in a file of this kind. A `case` over the
  ## closed enum rather than a string at the call site, so the two file kinds
  ## cannot come to disagree about their own ABI.
  case kind
  of dfkVisualiserCode: VisualiserExport
  of dfkDiffCode: DiffExport
  of dfkPoints, dfkVisualisers, dfkScratchpad: ""

func hasEntryPoint*(d: ExecutableDefinition): bool =
  d.module.exportedFunction(exportFor(d.kind)) >= 0

# ---------------------------------------------------------------------------
# The structural comparison, which is what a failure falls back TO
# ---------------------------------------------------------------------------

func structuralDiff*(a, b: string): DiffVerdict =
  ## §7's "falls back to the structural diff", at the level this ABI works at:
  ## the two inputs the host would have handed the module.
  ##
  ## IT IS THE HOST'S OWN ANSWER AND IT IS TOTAL. A fallback that could itself
  ## fail would leave a pane with nothing, which is the blank surface §8.2 of
  ## Extensibility-Model.md forbids; a byte comparison cannot.
  ##
  ## What this is NOT is the scratchpad's structural comparison over recorded
  ## values. Nothing in this build supplies a checkout's definitions to the
  ## scratchpad (see PLAT-13's bound 1), so there is no `Value` pair here to
  ## compare — and writing a second value-level comparison beside the one the
  ## scratchpad already has would be two answers to one question. The fallback
  ## is over the same two inputs the module was given, which is the strongest
  ## honest statement available at this seam.
  if a == b: dvEqual else: dvDifferent

# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

type
  Prepared = object
    instance: WasmInstance
    spent: int
    ok: bool
    detail: string

func prepare(d: ExecutableDefinition; inputs: openArray[string]): Prepared =
  ## Instantiate and fill. Charges the pages and every byte written, so the run
  ## starts with an allowance that has already paid for the module's own
  ## appetite.
  ##
  ## THE CHARGE IS TAKEN BEFORE THE ALLOCATION, and the two lines were the other
  ## way round until 2026-09-13 while `instantiationCost`'s own doc comment said
  ## "a number the host charges BEFORE it allocates". Nothing observable moved —
  ## `newSeq` cannot fail here — but a comment that describes an ordering the
  ## code does not take is the shape Verification-Harness-Traps §4d is about,
  ## and this is the ordering the next bound (a host-wide allowance across
  ## several definitions) has to be able to rely on.
  result.spent = d.module.instantiationCost
  result.instance = d.module.instantiate()
  var at = ExecutableInputBase
  for input in inputs:
    if input.len > MaxExecutableInputBytes:
      result.detail = "an input of " & $input.len &
        " bytes; the bound is " & $MaxExecutableInputBytes
      return
    if not result.instance.writeBytes(at, input):
      result.detail = "the module declares " & $d.module.memoryPages &
        " page(s), which is not enough memory for the host to write " &
        $input.len & " byte(s) of input at " & $at
      return
    result.spent += input.len
    at += MaxExecutableInputBytes
  result.ok = true

func visualiseWith*(d: ExecutableDefinition; trust: ProjectTrustLedger;
                    input: string;
                    work = MaxExecutableWork): VisualisedText =
  ## Run a visualiser definition over one value's rendering input.
  ##
  ## THE LEDGER IS A PARAMETER BECAUSE THE HANDLE IS A CACHED PARSE. A held
  ## `ExecutableDefinition` would otherwise go on running after the user
  ## withdrew the grant, and `trustDisclosure` promises the opposite in the
  ## words a user reads. See `ExecutableDefinition`'s own comment.
  ##
  ## EVERY FAILURE PATH LEAVES `text` EMPTY AND `fromDefinition` FALSE, and
  ## names the offender. The caller's fallback is to present the value the way
  ## it would have without the declaration — PLAT-12's rule that "the rest of
  ## the value still presents, always".
  result.bound = work
  let entry = exportFor(d.kind)
  let current = d.stillAdmitted(trust)
  if not admits(current):
    result.problems.add problem(d.file, codeFor(current),
      admissionText(current) & ". " & admissionRemedy(current) &
      ". The definition was already loaded; it was NOT run")
    result.offender = d.file & (if entry.len > 0: "#" & entry else: "")
    return
  if entry != VisualiserExport:
    result.problems.add problem(d.file, etcMissingExport,
      "a '" & definitionFileName(d.kind) & "' is not a visualiser definition")
    result.offender = d.file
    return
  if d.module.exportedFunction(entry) < 0:
    result.problems.add problem(d.file, etcMissingExport,
      "it exports no '" & entry & "'")
    result.offender = d.file & "#" & entry
    return
  var prep = prepare(d, [input])
  result.spent = prep.spent
  # `prepare` reports "not enough memory" for a module that declares fewer
  # pages than the host's input needs — including ZERO pages, where
  # `writeBytes`' bounds check is the only thing between a well-formed granted
  # module and an `IndexDefect` in the host.

  if not prep.ok:
    result.problems.add problem(d.file, etcOutputRefused, prep.detail)
    result.offender = d.file & "#" & entry
    return
  let run = d.module.runExportIn(prep.instance, entry,
                                 [int32(ExecutableInputBase), int32(input.len)],
                                 work, prep.spent)
  result.spent = run.spent
  if not run.ok:
    result.problems.add problem(d.file,
      (if run.trap == wtWorkExhausted: etcWorkExhausted else: etcTrapped),
      trapText(run.trap) & " after " & $run.spent & " of " & $work &
      " unit(s) of work")
    result.offender = d.file & "#" & entry
    return
  let at = int(run.value)
  if at < 0 or at >= run.instance.memory.len:
    result.problems.add problem(d.file, etcOutputRefused,
      "it returned address " & $at & ", which is outside its own memory")
    result.offender = d.file & "#" & entry
    return
  let text = run.instance.readCString(at, MaxExecutableTextBytes + 1)
  result.spent = run.spent + text.len
  if text.len > MaxExecutableTextBytes:
    result.problems.add problem(d.file, etcOutputRefused,
      "it returned more than " & $MaxExecutableTextBytes &
      " byte(s) of text, or never wrote a terminator")
    result.offender = d.file & "#" & entry
    return
  result.text = text
  result.fromDefinition = true

func diffWith*(d: ExecutableDefinition; trust: ProjectTrustLedger; a, b: string;
               work = MaxExecutableWork): DiffAnswer =
  ## §7, whole: run the project's comparison, bound it, and when it does not
  ## answer, report the offender and fall back to the structural comparison.
  ##
  ## THE LEDGER IS A PARAMETER for the reason `visualiseWith`'s is: the handle
  ## is a cached parse, and a withdrawn grant has to stop the code running
  ## rather than only stop the NEXT load finding it.
  ##
  ## THE FALLBACK IS TAKEN ON EVERY FAILURE PATH AND THE VERDICT IS NEVER
  ## ABSENT. A comparison that returned "I could not compare these" would hang
  ## the pane just as surely as the loop §7 is about — slower, and with a
  ## message.
  result.bound = work
  result.verdict = structuralDiff(a, b)
  let entry = exportFor(d.kind)

  template fallBack(code: ExecutableTierCode; detail: string): untyped =
    result.problems.add problem(d.file, code, detail)
    result.offender = d.file & "#" & entry
    result.fromDefinition = false
    return

  let current = d.stillAdmitted(trust)
  if not admits(current):
    fallBack(codeFor(current),
             admissionText(current) & ". " & admissionRemedy(current) &
             ". The definition was already loaded; it was NOT run")
  if entry != DiffExport:
    result.problems.add problem(d.file, etcMissingExport,
      "a '" & definitionFileName(d.kind) & "' is not a diff definition")
    result.offender = d.file
    return
  if d.module.exportedFunction(entry) < 0:
    fallBack(etcMissingExport, "it exports no '" & entry & "'")
  var prep = prepare(d, [a, b])
  result.spent = prep.spent
  if not prep.ok:
    fallBack(etcOutputRefused, prep.detail)
  let run = d.module.runExportIn(prep.instance, entry,
    [int32(ExecutableInputBase), int32(a.len),
     int32(ExecutableInputBase + MaxExecutableInputBytes), int32(b.len)],
    work, prep.spent)
  result.spent = run.spent
  if not run.ok:
    fallBack((if run.trap == wtWorkExhausted: etcWorkExhausted else: etcTrapped),
             trapText(run.trap) & " after " & $run.spent & " of " & $work &
             " unit(s) of work")
  result.verdict = (if run.value == 0: dvEqual else: dvDifferent)
  result.fromDefinition = true

func describeFallback*(answer: DiffAnswer): string =
  ## What a user is told when §7's bound fired. NAMES THE OFFENDER, says what
  ## the host did instead, and does not ask them to do anything about a file
  ## they may not own.
  if answer.fromDefinition: return ""
  var why: seq[string] = @[]
  for p in answer.problems: why.add render(p)
  "the project's own comparison did not answer (" & why.join("; ") &
    "), so this pane compared the two values structurally instead. " &
    "The offending definition is " & answer.offender & ", and it spent " &
    $answer.spent & " of " & $answer.bound & " unit(s) of work"
