## The target assessment, and the versioned protocol type that carries it.
##
## `ct run` / `ct record` must be smart about launching the correct recorder.
## The algorithm is *"assess what the target file or directory is and decide
## what sort of recording to create"*, and **the assessment does not return a
## language**.  It returns a *kind*: "this is a cargo project", "this is a CMake
## project", "this is a main C file (potentially stand-alone)", "this is a Nim
## file".  `main.c` and a CMake project are both C and need different handling;
## a Cargo project and a stand-alone `.rs` are both Rust and likewise.  A
## language is a property of a **file** (`target_axes.nim`), and a file census is
## advisory data an assessment may carry, never the thing it answers with.
##
## ## Why this is a protocol type and not an internal enum
##
## The assessment crosses the **launcher ↔ installed component** boundary.
##
## * The launcher (`codetracer-launcher`) is deliberately tiny and
##   dependency-free — line-oriented text only, no JSON, no heap allocation
##   (`codetracer-launcher/src/caps.nim:3-12`).  It cannot open a `Cargo.toml`
##   or read an ELF header, so it routes **coarsely** from the installed
##   capability file and the installed component performs the assessment.
## * The pair is **PATH-discovered**, not bundled
##   (`configuredRecognitionBackend`, `src/ct/utilities/language_detection.nim:195-205`,
##   over `loadConfig`'s PATH auto-discovery).  A version-skewed pair is a real
##   deployment state, not a hypothetical: this project has been bitten by
##   `--use-interpose` (a flag one side retired while the other kept sending it)
##   and by `serde_repr` ordinals drifting across repositories.
##
## So the result is versioned, extensible, forward-compatible, and has an
## explicit answer for *"the producer sent a kind this consumer does not know"*.
##
## ## The kind set, and the must-understand rule
##
## A kind is not a single token, and it is not an ordered chain either.  It is
## a **set of specific kinds** plus a **family** carried in its own field:
##
## ```text
##   specific: {"cargo-project", "cmake-project"}    open vocabulary, unordered
##   family:   project-directory                     closed vocabulary, frozen
## ```
##
## | Rule | Statement |
## | --- | --- |
## | **K1** | The family is always present, as its own typed field, and is drawn from a vocabulary frozen for the life of the major version. |
## | **K2** | A consumer acts on the specific kinds it knows.  If it knows **two** of them, that is a loud **ambiguity** naming both — never a silent choice.  If it knows none, it acts on the family. |
## | **K3** | A family token this build does not know is a protocol error: fail loudly, naming the token, the producer and the family vocabulary this build knows.  Never silently. |
## | **K4** | A producer that must *not* be degraded sets the family to `tfUnassessable`, which is itself a family and therefore satisfies K1 while forbidding any general handling. |
##
## **Why a set and not a chain (design question Q10, decided 2026-09-20).**
## An earlier revision made `specific` an ordered specificity chain — "a cargo
## project is a rust project is a project directory" — with the family as its
## last element and K2 reading "take the first element you understand".  A
## chain cannot say that a directory is *both* a Cargo workspace *and* a CMake
## project: it forces the producer to invent a precedence, which is exactly the
## defect `detectFolderLang` had, where a crate that also carried a
## `foundry.toml` silently became a Foundry project and the Cargo fact was
## discarded at the return statement.  (LRS-2P replaced it with
## `assessFolderKind`, which reports every marker present.)  A set carries both facts; the consumer,
## which is the only party that knows whether two kinds *dispatch differently*,
## either resolves the pair itself or refuses — and it never guesses.
## Degradation therefore has exactly one target, the family, and the family
## lives in its own field rather than being "the last element".
##
## `TargetKind` below makes **K1 unrepresentable-if-violated**: the family is a
## typed field, so a producer cannot emit a kind without one.  K3 can therefore
## only fire at the parse boundary, which is where `parseKind` puts it.
##
## ## Versioning
##
## * `schema` carries the **major** version, exactly as
##   `codetracer.target-recognition.v1` does
##   (`src/ct/utilities/target_recognition.nim:56-63`).  A consumer refuses an
##   unrecognised schema with a named diagnostic rather than sniffing fields —
##   that file states the rule at `:263-271` and this document adopts it
##   verbatim.
## * **Within a major, specific kinds are open and additive.**  A new
##   `cmake-project` token needs no version bump: an older consumer degrades to
##   the family the producer supplied.
## * **Within a major, the family vocabulary is frozen.**  Adding a
##   `TargetFamily` member would break K3 for every already-installed consumer,
##   so it requires a new major.  This is the one asymmetry a contributor must
##   remember, and it is why the two vocabularies are different types.
## * Unknown keys are ignored, and no ordinal crosses: every axis and every
##   family travels as a name.
##
## ## How it composes with `recognize`
##
## `ct-native-replay recognize --format=json` already emits
## `codetracer.target-recognition.v1` with a `kind` of
## `executable | script | directory | unknown`
## (`codetracer-native-backend/src/recognize.rs:74-81`) alongside `primary` and
## `components[]`, a per-file language census derived from a
## `HashMap<Lang, usize>`.  That document is **not** replaced.  Its `kind` is a
## *shape*, which is the family level of this model, and
## `familyFromRecognitionKind` below maps it onto `TargetFamily`.
##
## That mapping is **lossy in both directions**, and an earlier version of this
## comment claimed "with no loss".  The correction, with the evidence:
##
## * `recognize` returns `Directory` for **any** directory.  `recognize.rs:493`
##   is a bare `if meta.is_dir()` that returns immediately with
##   `primary: None, components: Vec::new()` — it explicitly does not read
##   manifests.  `tfProjectDirectory`, which it maps to, is documented "A
##   directory with a build manifest."  So the mapping *upgrades* an unqualified
##   directory into a claim the recognizer never made.
## * `Executable` (`recognize.rs:582`) is the unconditional endpoint for
##   anything `object::File::parse` accepts — a `.so`, a `.o`, a core dump —
##   and all of them become `tfPrebuiltArtefact` ("Record it directly").
## * `TargetKind::Script` is **never constructed**.  The only occurrence in the
##   file is the doc comment at `recognize.rs:71` saying so outright ("NTR-0
##   never emits `TargetKind::Script`"); a file that does not parse as an object
##   becomes `Unknown` (`:534`), not `Script`.  The `of "script"` arm below is
##   therefore unreachable against today's producer.
## * The reverse direction is **not a function at all**: `tfUnassessable`,
##   `tfCommand` and `tfExistingRecording` have no recognition kind to map back
##   to, which is expected — they are assessments `recognize` cannot make.
## * The Rust enum derives `Serialize` only (`recognize.rs:74`), so nothing on
##   that side parses this vocabulary back in.
##
## None of this makes the mapping wrong to have — a coarse shape is still the
## right floor for a consumer that knows no specific kind. It makes it a
## *coarsening*, and the arms are kept as they are on purpose: correcting the
## documentation rather than the code, because changing what `Directory` maps to
## would need the producer to start distinguishing the two cases first.
##
## This is a **sibling** document type rather than an extension of that one, for
## two reasons that are about ownership rather than taste:
##
## 1. `recognize` belongs to `codetracer-native-backend` and answers questions it
##    can answer from an ELF header and DWARF.  "This is a cargo project" is not
##    such a question.  A sibling type lets either component produce an
##    assessment; folding it into `recognize` would make the native backend the
##    only possible producer of a fact about a Nim file.
## 2. A recognition document that *could* carry an assessment and does not is
##    ambiguous between "the target has none" and "the producer is older than
##    the field".  The core already refuses to conflate those two — the
##    `recognitionRan` flag exists for precisely that distinction
##    (`src/ct/utilities/language_detection.nim:180-189`).
##
## The composition is therefore: a recognition document **embeds** an
## assessment under an `assessment` key, and a producer that starts emitting one
## bumps its own schema to `codetracer.target-recognition.v2`.  The consumer side
## already has the mechanism — `SupportedRecognitionSchemas`
## (`target_recognition.nim:60-63`) is a *list*, and its comment says outright
## that it is a list "because Q5's deprecation window explicitly contemplates a
## core that accepts both `v1` and `v2` during a transition".  A `v1` document
## then means "no assessment was computed", which is a fact rather than an
## absence.
##
## ## Scope
##
## This module defines the type and its conversions.  **Since LRS-2P
## (2026-09-22) it also crosses a process boundary**: `ct-native-replay
## recognize` emits one under the `assessment` key of a
## `codetracer.target-recognition.v2` document (design Q8), and
## `src/ct/utilities/target_recognition.nim` decodes it — which is where
## `parseKind`'s K3 refusal and `understand`'s degradation actually run.
## Since LRS-2B, `ct record` ALSO builds one LOCALLY from what it already
## knows about the target (`src/ct/trace/record_assessment.nim`) and
## dispatches its recorder on the result; the two coexist because either
## component may produce an assessment (design §9.5's first reason for making
## it a sibling type).  Because no producer had ever emitted
## `codetracer.target-assessment.v1` when Q10 was decided, the change from
## chain to set redefined v1 rather than minting a v2: there was no installed
## consumer of the chain shape to skew against.  Sequenced in
## `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.milestones.org`.

import std/[algorithm, strutils]
import ./target_axes

export target_axes

const
  TargetAssessmentSchema* = "codetracer.target-assessment.v1"
    ## The one schema version this build produces.

  SupportedTargetAssessmentSchemas* = [TargetAssessmentSchema]
    ## The schemas this build *consumes*.  A list, not a constant, so that a
    ## transition can accept two — the same shape, and for the same stated
    ## reason, as `SupportedRecognitionSchemas`
    ## (`src/ct/utilities/target_recognition.nim:60-63`).

type
  TargetFamily* = enum
    ## **Closed and frozen for the life of schema major version 1.**  Adding a
    ## member here breaks rule K3 for every already-installed consumer and
    ## therefore requires `…v2`.
    ##
    ## The members are disjoint by *required response*, not by shape, because a
    ## family exists to tell a consumer what to do when it does not recognise
    ## the specific kind.  "Executable" and "source file" are both files; they
    ## are different families because one is built and one is not.
    tfUnknown
      ## Nothing could be decided.  Refuse, and say what was tried.
    tfUnassessable
      ## The producer knows what this is and no version-1 consumer can act on
      ## it.  Refuse, naming the specific kinds and the producer, so the user
      ## is told *which* component to update.  This is rule K4's landing site: it
      ## is how a producer forbids degradation without violating K1.
    tfSingleFile
      ## One source file, potentially stand-alone.  Compile it or interpret it,
      ## then record.  `main.c`, `a.nim`, `script.py`.
    tfProjectDirectory
      ## A directory with a build manifest.  Build it, then record the product.
      ## `Cargo.toml`, `CMakeLists.txt`, `Nargo.toml`, `Scarb.toml`.
    tfPrebuiltArtefact
      ## An already-built binary or bytecode module.  Record it directly; there
      ## is no build step.  `a.out`, a `.wasm` module, a deployed contract.
    tfCommand
      ## An argv to run under a general-purpose recorder rather than a path to
      ## build.  `ct record -- npm test`.
    tfExistingRecording
      ## Not a recording target at all — a recording already on disk.  Open or
      ## replay it.  `CtTraceKind` (`src/ct/trace/trace_kind.nim`) is what
      ## detects this today.

  TargetKind* = object
    ## An assessment's answer.  See "the kind set" above.
    specific*: seq[string]
      ## Open vocabulary, and a **set**: order carries no meaning and a
      ## consumer must not read one into it.  May be empty, which means the
      ## producer had nothing more specific than the family.  Tokens are
      ## lowercase ASCII with `-` as the word separator.  `specificKinds`
      ## returns the canonical (sorted, deduplicated) spelling for the wire.
    family*: TargetFamily
      ## Closed vocabulary; the guaranteed floor and the only degradation
      ## target.  Typed, and its own field, so that rule K1 cannot be violated
      ## by construction.

  AssessedLanguage* = object
    ## One row of the **advisory** per-file language census.
    ##
    ## Advisory is the operative word: this never decides routing.  It is the
    ## same data `recognize` already emits as `components[]` from a
    ## `HashMap<Lang, usize>` frequency map, and it exists because a target may
    ## legitimately hold several languages — which the product already supports
    ## and re-derives per move rather than reading off the trace
    ## (`src/frontend/ui/calltrace.nim:985`).
    language*: SourceLanguage
    fileCount*: int
      ## How many files carried this language.  `0` means "present, count not
      ## computed" — distinct from the row being absent.
    evidence*: seq[string]
      ## Free text, for diagnostics only.  Never parsed.

  TargetAssessment* = object
    ## The protocol document.
    schema*: string
      ## Always read first and checked against
      ## `SupportedTargetAssessmentSchemas` before any other field is trusted.
    producer*: string
      ## `<component-name>/<version>`, e.g. `ct-native-replay/0.6.3`.  Carried so
      ## that an unknown-kind refusal can name *which* half of a
      ## PATH-discovered pair to update.  Free text; never parsed for logic.
    target*: string
      ## The target as the user spelled it.
    kind*: TargetKind
    toolchain*: Toolchain
    targetIsa*: TargetIsa
    arch*: string
      ## The specific CPU architecture, as a free string, when `targetIsa` is
      ## `tiNative`.  Deliberately not an enum: `recognize` already carries it
      ## as `format.arch` (a `String`), and a closed enum over the set of CPU
      ## architectures is the same defect this whole split removes.
    recordingApproach*: RecordingApproach
    languages*: seq[AssessedLanguage]
      ## Advisory census, most significant first.  Empty means "not computed",
      ## which is not the same as "the target had none" — the same distinction
      ## `DetectedTarget.recognitionRan` draws
      ## (`src/ct/utilities/language_detection.nim:180-193`).
    diagnostics*: seq[string]

  KindResolutionStatus* = enum
    ## What happened when a consumer resolved a kind set.
    krExact       ## the consumer understood exactly one specific kind
    krAmbiguous   ## it understood TWO OR MORE; `candidates` names them all and
                  ## the consumer must refuse or resolve the pair itself — the
                  ## protocol never picks one for it (rule K2)
    krCompatible  ## it understood TWO OR MORE and they DISPATCH ALIKE: one
                  ## toolchain and one target ISA between them
                  ## (`kindsDispatchAlike`), so they are one target described
                  ## twice — `cargo-project` beside `wasm-cargo-project` is a
                  ## wasm crate — and not a collision.  Produced only by
                  ## `understand`, which is the consumer "resolving the pair
                  ## itself" that design §9.3 allows; `resolveKind` never
                  ## answers it, because the protocol never breaks a tie
                  ## (LRS-6, 2026-09-23)
    krFamilyOnly  ## it understood no specific kind and fell back to the family
    krRefused     ## the family is `tfUnassessable`: the producer forbade
                  ## degradation and the consumer must refuse

  KindResolution* = object
    status*: KindResolutionStatus
    token*: string
      ## The token the consumer will act on.  For `krFamilyOnly` and
      ## `krRefused` this is the family token; for `krAmbiguous` it is empty,
      ## because there is nothing the consumer may act on yet.
    candidates*: seq[string]
      ## `krAmbiguous` only: every specific kind the consumer knows, in the
      ## producer's order.  A refusal must name all of them.
    skipped*: seq[string]
      ## The specific kinds the consumer did NOT know, in the producer's
      ## order.  A consumer that falls back to the family should say so using
      ## this; that is what makes the degradation *explicit* rather than
      ## silent.

# ---------------------------------------------------------------------------
# Family tokens
# ---------------------------------------------------------------------------

func token*(v: TargetFamily): string =
  ## The wire spelling of a family.  Exhaustive `case`, so a new member is a
  ## compile error here — which is the reminder that adding one needs a schema
  ## major bump.
  case v
  of tfUnknown: UnknownToken
  of tfUnassessable: "unassessable"
  of tfSingleFile: "single-file"
  of tfProjectDirectory: "project-directory"
  of tfPrebuiltArtefact: "prebuilt-artefact"
  of tfCommand: "command"
  of tfExistingRecording: "existing-recording"

func knownFamilyTokens*(): string =
  ## The family vocabulary, for a diagnostic.  Built from the enum on purpose:
  ## this is the *live* vocabulary being reported back to a human, not a
  ## historical decode table.  (The distinction matters in this repo:
  ## `langV0OrdinalNames` in `src/common/trace_index.nim` decodes integers
  ## written by an *older* build and is therefore a frozen literal that must
  ## never be regenerated from the live enum.)
  var parts: seq[string] = @[]
  for v in TargetFamily:
    parts.add(token(v))
  parts.join(", ")

func parseTargetFamily*(s: string, value: var TargetFamily): bool =
  ## Total.  `false` means "not a family token of this major version", which is
  ## rule K3's trigger and never a silent fallback.
  let key = s.strip.toLowerAscii
  for v in TargetFamily:
    if token(v) == key:
      value = v
      return true
  false

# ---------------------------------------------------------------------------
# The kind set on the wire
# ---------------------------------------------------------------------------

func specificKinds*(k: TargetKind): seq[string] =
  ## The canonical wire spelling of the specific-kind set: sorted and
  ## deduplicated.  Canonical so that two producers naming the same facts in
  ## a different order emit the same document, and so that equality of two
  ## kinds is equality of two sequences.
  result = @[]
  for s in k.specific:
    if s notin result:
      result.add(s)
  result.sort()

func namedProducer*(producer: string): string =
  ## How every diagnostic in this module spells the producer.
  ##
  ## **The producer is named in every refusal and every degradation, without
  ## exception.**  The pair is PATH-discovered (§9.2), so "this build does not
  ## understand that" is only half an answer: the user also has to be told
  ## *which half of the pair* to update, and no other field of the document
  ## carries that.  It is a single function so that a diagnostic cannot be
  ## added later that quietly omits it, and `target_axes_test.nim` asserts the
  ## producer appears in each of the four.
  if producer.strip.len == 0: "(unnamed)" else: producer.strip

func parseKind*(specific: openArray[string], family, producer: string,
                value: var TargetKind, diagnostic: var string): bool =
  ## Decode a wire kind.  Rule K3 lives here and nowhere else.
  ##
  ## Fails, loudly and with a named diagnostic, when `family` is not a family
  ## token of this major version, or when a family token appears among the
  ## specific kinds — a producer that put a family there has confused the two
  ## vocabularies, and quietly accepting it would turn a protocol bug into an
  ## invisible behaviour change.  Duplicates in `specific` are collapsed; order
  ## is not preserved as meaning, only as the producer's spelling.
  ##
  ## `producer` is **required, not defaulted**.  K3 says the refusal names "the
  ## token, the producer and the family vocabulary this build knows"; a default
  ## would let a call site drop the one field that says which binary to
  ## replace, and it would drop it silently.  Making it a parameter without a
  ## default turns that omission into a compile error.  (LRS-2 shipped this
  ## proc without the parameter and its K3 message named only the token and the
  ## vocabulary — corrected here under milestone rule 7 rather than left.)
  var fam: TargetFamily
  if not parseTargetFamily(family, fam):
    diagnostic = "target-assessment: the kind's family is '" & family &
      "', which is not a target family this build knows. Known families: " &
      knownFamilyTokens() & ". The specific kinds were: " &
      (if specific.len == 0: "(none)" else: specific.join(", ")) &
      ". Producer: " & namedProducer(producer) &
      ". A family token is frozen for the life of a schema major version " &
      "(§9.4), so this is a version skew: update this build of CodeTracer, " &
      "or put a matching producer first on PATH."
    return false
  var kinds: seq[string] = @[]
  for s in specific:
    var asFamily: TargetFamily
    if parseTargetFamily(s, asFamily):
      diagnostic = "target-assessment: '" & s & "' is a family token and " &
        "was sent among the specific kinds; the family travels in its own " &
        "field (rule K1). The specific kinds were: " & specific.join(", ") &
        "; the family was: " & family & ". Producer: " &
        namedProducer(producer) & "."
      return false
    if s notin kinds:
      kinds.add(s)
  value = TargetKind(specific: kinds, family: fam)
  true

func resolveKind*(k: TargetKind, understood: openArray[string]): KindResolution =
  ## Rule K2: act on the specific kinds the consumer knows — one of them
  ## exactly, two or more loudly, none by falling back to the family.
  ##
  ## `understood` is the consumer's own vocabulary — the specific kinds it has
  ## code for.  It is passed in rather than read from a registry so that a test
  ## can drive a consumer that knows nothing, which is the version-skew case
  ## that has to work.
  ##
  ## The library never breaks a tie.  Whether two known kinds dispatch the same
  ## way or differently is a fact about the CONSUMER's code, not about the
  ## protocol, so `krAmbiguous` hands both names back and the consumer either
  ## resolves them itself or refuses naming both.  A silent pick here would be
  ## the `detectFolderLang` precedence defect reintroduced one layer up.
  ##
  ## The family is never in `understood`: falling back to it is `krFamilyOnly`,
  ## which is a distinct outcome from understanding a specific kind, and a
  ## caller that logs the difference is what makes the degradation visible.
  var known: seq[string] = @[]
  var skipped: seq[string] = @[]
  if k.family == tfUnassessable:
    return KindResolution(status: krRefused, token: token(k.family),
                          skipped: k.specific)
  for s in k.specific:
    var isKnown = false
    for u in understood:
      if u == s:
        isKnown = true
        break
    if isKnown:
      if s notin known: known.add(s)
    else:
      skipped.add(s)
  case known.len
  of 0:
    KindResolution(status: krFamilyOnly, token: token(k.family), skipped: skipped)
  of 1:
    KindResolution(status: krExact, token: known[0], skipped: skipped)
  else:
    KindResolution(status: krAmbiguous, token: "", candidates: known,
                   skipped: skipped)

func ambiguityDiagnostic*(r: KindResolution, producer: string): string =
  ## The refusal a consumer prints for `krAmbiguous`: names every candidate
  ## and the producer, so the user is told which facts collided and which
  ## component asserted them.  Empty for any other status.
  if r.status != krAmbiguous:
    return ""
  "target-assessment: the target is more than one kind this build handles " &
    "differently — " & r.candidates.join(" and ") & " — and nothing may " &
    "pick one silently. Producer: " & namedProducer(producer) &
    ". Name the intended kind explicitly."

func degradationDiagnostic*(r: KindResolution, producer: string): string =
  ## What a consumer MUST print when it falls back to the family because the
  ## producer named specific kinds this build has never heard of.
  ##
  ## This is the half of §9.3 that is easy to get wrong, because the code path
  ## *works*: `resolveKind` answers `krFamilyOnly`, the consumer acts on the
  ## family, and the recording happens.  What is lost without this line is the
  ## user's only clue that a newer producer told them something their core
  ## could not use — which is the precise failure this protocol exists to make
  ## visible (§9.2's "bitten by skew twice").  Additive-within-a-major is a
  ## promise that the fallback is *correct*, never that it is *silent*.
  ##
  ## Empty when nothing was skipped: a producer that simply had nothing more
  ## specific than the family has not degraded anything, and saying so would
  ## be noise on every ordinary run.
  if r.status != krFamilyOnly or r.skipped.len == 0:
    return ""
  "target-assessment: this build does not know the specific target " &
    (if r.skipped.len == 1: "kind " else: "kinds ") & r.skipped.join(", ") &
    ", so it is acting on the family '" & r.token & "' instead. Producer: " &
    namedProducer(producer) &
    ". Specific kinds are additive within a schema major version (§9.4), so " &
    "this is not an error — but the producer knows more about this target " &
    "than this build can use; update CodeTracer to act on it."

func unassessableDiagnostic*(r: KindResolution, producer: string): string =
  ## Rule K4: the producer set the family to `unassessable`, which forbids any
  ## general handling.  A consumer refuses and names the producer, because the
  ## component that must change is the one that said so.  Empty otherwise.
  if r.status != krRefused:
    return ""
  "target-assessment: the producer marked this target 'unassessable', which " &
    "forbids acting on the family (rule K4). The specific kinds were: " &
    (if r.skipped.len == 0: "(none)" else: r.skipped.join(", ")) &
    ". Producer: " & namedProducer(producer) &
    ". Update CodeTracer to a build that understands one of them."

type
  KindVerdict* = object
    ## What a consumer learned from a kind, and what it must say about it.
    ##
    ## `understand` below returns this instead of a bare token so that the
    ## "never silently" half of §9.3 is carried by the TYPE rather than by a
    ## call-site convention: a consumer that acts on `token` and ignores
    ## `diagnostic` is visibly dropping something, whereas a consumer that
    ## called `resolveKind` and ignored the `skipped` field looked correct.
    status*: KindResolutionStatus
    ok*: bool
      ## May the consumer act on the verdict?  False for `krAmbiguous` (rule
      ## K2) and `krRefused` (rule K4) — both are refusals.  True for
      ## `krCompatible`: the kinds agree on everything this build dispatches
      ## on.
    token*: string
      ## The specific kind, or the family token when degrading.  Empty when
      ## `ok` is false, and for `krCompatible`, where there is no ONE kind to
      ## name: the consumer acts on all of `candidates`, and picking one of
      ## them for this field would be the silent pick rule K2 forbids.
    candidates*: seq[string]
      ## `krAmbiguous` and `krCompatible`: every specific kind the consumer
      ## knows, in the producer's order.  Empty otherwise.
    diagnostic*: string
      ## **Non-empty for every outcome that is not an exact or compatible,
      ## undegraded match.**  Printing it is not optional: it is the
      ## degradation or the refusal, and it always names the producer.
      ## (`krCompatible` prints nothing, exactly as the LOCAL assessment
      ## prints nothing for the same kind set -- `record_assessment.nim`
      ## raises a diagnostic only for a toolchain or ISA clash.)

func targetIsaAmbiguity*(kind: TargetKind): seq[string]
func toolchainAmbiguity*(kind: TargetKind): seq[string]
  # Forward declarations: both are defined below, beside the derivations
  # whose disagreement they report, and `kindsDispatchAlike` is built on them.

func kindsDispatchAlike*(kinds: openArray[string], family: TargetFamily): bool =
  ## Do the specific kinds `kinds` DISPATCH ALIKE in this build -- is every
  ## decision this build derives from a kind the same whichever of them it
  ## is derived from?  Those decisions are the toolchain (`toolchainForKind`)
  ## and the target ISA (`targetIsaForAssessment`); a set that names two of
  ## either is a collision, and anything else is one target described more
  ## than once.
  ##
  ## **This is the same test the LOCAL assessment applies**
  ## (`src/ct/trace/record_assessment.nim` refuses exactly when
  ## `targetIsaAmbiguity` or `toolchainAmbiguity` is non-empty), which is the
  ## point: until LRS-6 `understand` refused ANY two known kinds, so a
  ## producer that reported a wasm crate as `cargo-project` +
  ## `wasm-cargo-project` -- the kind set `assessFolderKind` itself builds for
  ## one -- would have been refused by `ct record` while the identical set
  ## built locally proceeded.  One rule, reached from both places, is what
  ## keeps the two paths from disagreeing again.
  ##
  ## The language a kind implies is not a third test because no two kinds
  ## this build understands share a toolchain and differ in language
  ## (`langForProjectKind` in `src/ct/utilities/language_detection.nim` maps
  ## `cargo-project` and `wasm-cargo-project` -- the only toolchain-sharing
  ## pair -- both to Rust), and that function lives above this module's floor
  ## (`src/ct`), where the JS front end cannot reach it.
  ##
  ## **A gap in the shared rule, recorded rather than closed (LRS-6).**  Of
  ## the 91 pairs of understood kinds, 11 pass this test: the wasm crate, and
  ## `wasm-module` beside each of the ten project kinds (`noir-project` +
  ## `wasm-module` -> `tcNargo` / `tiWasm`).  The ten are not one target
  ## described twice -- a project kind names a toolchain and no ISA, and
  ## `wasm-module` names an ISA and no toolchain, so neither clash test can
  ## see that they disagree.  They are unreachable on BOTH paths today:
  ## `wasm-module` is assessed only for a FILE and every project kind only for
  ## a DIRECTORY (`record_assessment.assessKind`; the native-backend producer
  ## emits no project kind at all).  Closing it means teaching the rule which
  ## family each kind belongs to, which changes the local assessment too; it
  ## is recorded in the LRS-6 tracker entry instead of being changed here.
  let together = TargetKind(specific: @kinds, family: family)
  toolchainAmbiguity(together).len == 0 and
    targetIsaAmbiguity(together).len == 0

func understand*(k: TargetKind, understood: openArray[string],
                 producer: string): KindVerdict =
  ## Apply rules K2/K4 and produce the diagnostic the outcome obliges.
  ##
  ## One call, so that a consumer cannot implement "act on the family" without
  ## also obtaining the sentence that says it did.  `understood` is the
  ## consumer's own vocabulary — passed in, exactly as `resolveKind` takes it,
  ## so a test can drive a build that knows nothing, which is the version-skew
  ## case that has to work.
  ##
  ## Two or more understood kinds are refused only when they would DISPATCH
  ## DIFFERENTLY (`kindsDispatchAlike`); a set that agrees on toolchain and
  ## ISA is `krCompatible` and proceeds, silently, as the local assessment
  ## does.  This is the consumer resolving the pair itself, which §9.3 allows
  ## and `resolveKind` deliberately does not do.
  let r = k.resolveKind(understood)
  case r.status
  of krExact:
    KindVerdict(status: r.status, ok: true, token: r.token, diagnostic: "")
  of krFamilyOnly:
    KindVerdict(status: r.status, ok: true, token: r.token,
                diagnostic: r.degradationDiagnostic(producer))
  of krAmbiguous:
    if kindsDispatchAlike(r.candidates, k.family):
      KindVerdict(status: krCompatible, ok: true, token: "",
                  candidates: r.candidates, diagnostic: "")
    else:
      KindVerdict(status: r.status, ok: false, token: "",
                  candidates: r.candidates,
                  diagnostic: r.ambiguityDiagnostic(producer))
  of krCompatible:
    # `resolveKind` never answers this (see the enum); handled rather than
    # asserted so a future change there is still a correct verdict.
    KindVerdict(status: r.status, ok: true, token: "",
                candidates: r.candidates, diagnostic: "")
  of krRefused:
    KindVerdict(status: r.status, ok: false, token: "",
                diagnostic: r.unassessableDiagnostic(producer))

# ---------------------------------------------------------------------------
# Composition with `codetracer.target-recognition.v1`
# ---------------------------------------------------------------------------

func familyFromRecognitionKind*(recognitionKind: string,
                               value: var TargetFamily): bool =
  ## Map `recognize`'s `kind` onto a family.  Total, and **lossy** — see the
  ## module header for the evidence; this is a coarsening, not an isomorphism.
  ##
  ## `codetracer-native-backend/src/recognize.rs:74-81` declares
  ## `enum TargetKind { Executable, Script, Directory, Unknown }` with
  ## `rename_all = "lowercase"`, and the core keeps the value as a raw `string`
  ## rather than an enum precisely so an unknown one is not a parse error
  ## (`src/ct/utilities/target_recognition.nim:93-95`).  This preserves that: an
  ## unrecognised kind returns `false` and the caller decides, rather than
  ## silently becoming `tfUnknown` — which would be indistinguishable from the
  ## recognizer having genuinely said "unknown".
  case recognitionKind.strip.toLowerAscii
  of "executable":
    # Anything `object::File::parse` accepts, including a `.so`, a `.o` or a
    # core dump.  "Record it directly" is right for the common case and
    # over-confident for the rest; the recognizer draws no finer distinction
    # for this to preserve.
    value = tfPrebuiltArtefact
    true
  of "script":
    # UNREACHABLE against today's producer: `recognize.rs:71` states that NTR-0
    # never emits `Script`, and a file that fails to parse as an object becomes
    # `Unknown` (`:534`).  Kept because the variant is declared and the arm
    # costs nothing — but it is not evidence that scripts are handled.
    value = tfSingleFile
    true
  of "directory":
    # NOTE: `recognize.rs:493` returns `Directory` for ANY directory, without
    # reading a manifest, whereas `tfProjectDirectory` is documented "A
    # directory with a build manifest."  This arm therefore asserts slightly
    # more than the producer knew.  Changing it would require the producer to
    # distinguish the two cases first, so the claim is documented rather than
    # silently relied upon.
    value = tfProjectDirectory
    true
  of UnknownToken:
    value = tfUnknown
    true
  else:
    false

# ---------------------------------------------------------------------------
# The specific kinds this tree can already justify
#
# Every token below is backed by a marker the code reads TODAY.  The folder
# markers are read by `assessFolderKind`
# (`src/ct/utilities/language_detection.nim`), which IS the assessment
# algorithm since LRS-2P.  It used to be `detectFolderLang`, which threw the
# answer away by returning a `Lang`: `Cargo.toml` became `LangRust`, and the
# fact that it was a *cargo project* — the thing that decides whether to build
# before recording — was lost at the return statement.
#
# This list is NOT exhaustive and is not meant to be: specific kinds are the
# open half of the vocabulary.  `cmake-project` has no marker in the tree yet
# and is therefore absent rather than aspirational.
# ---------------------------------------------------------------------------

const
  KindCargoProject* = "cargo-project"        ## `Cargo.toml`, `language_detection.nim:41`
  KindNoirProject* = "noir-project"          ## `Nargo.toml`, `:29`
  KindCairoProject* = "cairo-project"        ## `Scarb.toml`, `:31`
  KindAikenProject* = "aiken-project"        ## `aiken.toml`, `:33`
  KindMoveProject* = "move-project"          ## `Move.toml`, `:35`
  KindSwayProject* = "sway-project"          ## `Forc.toml`, `:37`
  KindFoundryProject* = "foundry-project"    ## `foundry.toml`, `:39`
  KindLeanProject* = "lean-project"          ## `lakefile.lean`, `:46`
  KindCrystalProject* = "crystal-project"    ## `shard.yml`, `:48`
  KindLeoProject* = "leo-project"            ## `program.json`, `:50-52`

  ProjectMarkerKinds*: array[10, tuple[marker: string, kind: string]] = [
    ("Nargo.toml", KindNoirProject),
    ("Scarb.toml", KindCairoProject),
    ("aiken.toml", KindAikenProject),
    ("Move.toml", KindMoveProject),
    ("Forc.toml", KindSwayProject),
    ("foundry.toml", KindFoundryProject),
    ("Cargo.toml", KindCargoProject),
    ("lakefile.lean", KindLeanProject),
    ("shard.yml", KindCrystalProject),
    ("program.json", KindLeoProject)]
    ## The ten markers `detectFolderLang` reads, and the specific kind each
    ## one asserts.  **The order of this table carries no meaning.**  It is
    ## the order `detectFolderLang` happens to test them in, kept only so a
    ## reader can compare the two lists side by side; `projectKindsForMarkers`
    ## below emits EVERY kind whose marker is present, so a crate that is also
    ## a Foundry project is reported as both, and the consumer decides
    ## (rule K2) rather than the table deciding for it.
    ##
    ## ## Q10 — chain versus set: DECIDED (set), 2026-09-20
    ##
    ## An earlier revision recorded this as an open question and kept the
    ## table "in `detectFolderLang`'s own order, which is load-bearing there:
    ## the first marker that exists wins, so a crate that is also a Foundry
    ## project is a Foundry project."  That precedence is arbitrary with
    ## respect to the model and it silently discards a fact.  The user named
    ## the defect ("a crate that is also a Foundry project silently becomes
    ## Foundry") and decided: `TargetKind.specific` is an unordered SET, the
    ## family has its own field, and two known kinds are a loud ambiguity.
    ## **LRS-2P completed it**: `detectFolderLang` is now `assessFolderKind`,
    ## it returns a `TargetKind` rather than a `Lang`, and it reports EVERY
    ## marker present instead of the first.  `target_axes_test.nim` asserts
    ## that this table and `assessFolderKind` read the same SET of markers —
    ## membership, not order — and, separately and behaviourally, that two
    ## markers in one directory yield two kinds.

func projectKindForMarker*(marker: string, kind: var string): bool =
  ## Total lookup over `ProjectMarkerKinds`.
  for row in ProjectMarkerKinds:
    if row.marker == marker:
      kind = row.kind
      return true
  false

func projectKindsForMarkers*(present: openArray[string]): seq[string] =
  ## Every specific kind whose marker is among `present` — the file names in
  ## a target directory.  Pure, so it compiles on both backends; the caller
  ## lists the directory.  Emits ALL matches: this is the set model of Q10,
  ## and the point at which "first marker wins" stops being how the facts are
  ## produced.  Returned in `ProjectMarkerKinds` order for determinism only;
  ## the order means nothing (`specificKinds` canonicalises).
  result = @[]
  for row in ProjectMarkerKinds:
    for name in present:
      if name == row.marker and row.kind notin result:
        result.add(row.kind)

# ---------------------------------------------------------------------------
# Deriving the artefact axes from the assessment
#
# This is the PRIMARY path, and it lives here rather than in `target_axes.nim`
# because it needs `TargetKind`, and `target_axes.nim` must not depend on this
# module.  The layering is deliberate: the axes know nothing about assessments;
# assessments know how to produce axes.
# ---------------------------------------------------------------------------

const
  KindNimScript* = "nimscript"
    ## A `.nims` evaluated by `nim e --trace:<…>/trace.ct`
    ## (`src/ct/db_backend_record.nim:119-141`).  The Nim compiler's own VM runs
    ## it and emits the trace.
  KindNimSource* = "nim-source"
    ## A `.nim` compiled with `nim c` and handed to `ct-mcr`
    ## (`src/ct/db_backend_record.nim:143-188`).
  KindWasmCargoProject* = "wasm-cargo-project"
    ## A `Cargo.toml` project whose `.cargo/config.toml` mentions `wasm32`.
    ## `assessCargoProject` (`src/ct/utilities/language_detection.nim`)
    ## is what reads the marker; before LRS-2P it was `isWasmCargoProject`,
    ## answering the same question as a bare `bool`.  (It used to be turned into
    ## `LangRustWasm` by `detectFolderLang` — the ISA welded onto the
    ## language; LRS-5's second deletion round removed the member and left the
    ## marker doing the work it was already doing.)
  KindWasmModule* = "wasm-module"
    ## A **prebuilt `.wasm` module** handed to `ct record` — which is also
    ## what a `wasm-cargo-project` hands to `db-backend-record` after
    ## `cargo build --target wasm32-wasip1` (`src/ct/trace/record.nim`).
    ##
    ## **LRS-5, precondition (c).**  The extension is an ARTEFACT fact, of
    ## exactly the same kind as the `.cargo/config.toml` marker above, and
    ## until this milestone the assessment did not read it: `assessKind`
    ## answered `tfPrebuiltArtefact` with NO specific kind, so
    ## `targetIsaForAssessment` fell through to the per-language fallback and
    ## the `tiWasm` came from `axesOfLang(LangRustWasm)` — from the Lang
    ## MEMBER.  That is why the member could not be deleted without the route
    ## for a prebuilt module silently becoming the native one.  With this kind
    ## the route rides on the artefact, and
    ## `record_dispatch_test` "a prebuilt .wasm module dispatches to wazero,
    ## and the route rides on the ARTEFACT" is the case that pins it.

const
  UnderstoodSpecificKinds*: array[14, string] = [
    KindCargoProject, KindNoirProject, KindCairoProject, KindAikenProject,
    KindMoveProject, KindSwayProject, KindFoundryProject, KindLeanProject,
    KindCrystalProject, KindLeoProject,
    KindNimScript, KindNimSource, KindWasmCargoProject, KindWasmModule]
    ## **Every specific kind this build has code for**, and therefore the
    ## `understood` vocabulary a consumer passes to `understand`.
    ##
    ## It is a list of what the code DOES, not of what the protocol may say:
    ## the ten project manifests `langForProjectKind` and `toolchainForKind`
    ## dispatch on, plus the four kinds `targetIsaForAssessment` reads.  A kind
    ## outside it is not an error — specific kinds are additive within a schema
    ## major version (design 9.4) — it is a DEGRADATION, and
    ## `degradationDiagnostic` is what makes the degradation visible instead of
    ## silent.
    ##
    ## Deriving it from the `Kind*` constants by hand rather than generating it
    ## is deliberate: a constant exists here for `cmake-project`'s sake too
    ## (design 9.3 uses it as the example of a kind a producer may emit and a
    ## consumer may not know), and a generated list would claim understanding
    ## of every token that had ever been named.  `target_axes_test.nim` pins
    ## that every entry is a kind some production function actually acts on.

func targetIsaForAssessment*(kind: TargetKind,
                             lang: SourceLanguage): TargetIsa =
  ## **PRIMARY.**  The artefact's ISA, derived from the assessed KIND, with the
  ## per-language fallback used only when the kind says nothing.
  ##
  ## This exists because the ISA is a property of the ARTEFACT and the language
  ## is a property of the FILE, so `fallbackTargetIsaForLanguage` cannot be the
  ## answer — see its doc comment for the `.nim` / `.nims` counterexample that
  ## makes this concrete.  Every entry below is a case where the kind carries
  ## information the language provably does not:
  ##
  ## | kind | language | ISA | why the language cannot say |
  ## | --- | --- | --- | --- |
  ## | `nimscript` | `slNim` | `tiNimVm` | `.nim` is also `slNim` and is `tiNative` |
  ## | `nim-source` | `slNim` | `tiNative` | ditto, from the other side |
  ## | `wasm-cargo-project` | `slRust` | `tiWasm` | a plain crate is also `slRust` and is `tiNative` |
  ## | `wasm-module` | any | `tiWasm` | a `.rs` beside it is `slRust` and is `tiNative` |
  ##
  ## Rule K2 applies as everywhere else: this derivation knows four kinds,
  ## and they name three different ISAs, so TWO of them in one set is an
  ## ambiguity that must not be resolved silently — `targetIsaForAssessment`
  ## answers `tiUnknown` for it, which no caller may mistake for a decision,
  ## and `targetIsaAmbiguity` says which kinds collided.  A kind this build
  ## does not know is not an error here — it simply does not override, and the
  ## language fallback answers.
  var found: seq[TargetIsa] = @[]
  for specific in kind.specific:
    if specific == KindNimScript and tiNimVm notin found: found.add(tiNimVm)
    if specific == KindNimSource and tiNative notin found: found.add(tiNative)
    if specific == KindWasmCargoProject and tiWasm notin found: found.add(tiWasm)
    if specific == KindWasmModule and tiWasm notin found: found.add(tiWasm)
  case found.len
  of 0: fallbackTargetIsaForLanguage(lang)
  of 1: found[0]
  else: tiUnknown

func targetIsaAmbiguity*(kind: TargetKind): seq[string] =
  ## The ISA-deciding kinds present in `kind` when there is more than one of
  ## them — the names a refusal must print.  Empty when the ISA is decided.
  const IsaDecidingKinds = [KindNimScript, KindNimSource, KindWasmCargoProject,
                            KindWasmModule]
  var hits: seq[string] = @[]
  for specific in kind.specific:
    if specific in IsaDecidingKinds and specific notin hits:
      hits.add(specific)
  if hits.len >= 2: hits else: @[]

func toolchainForKind*(kind: TargetKind): Toolchain =
  ## The toolchain the assessed KIND implies — the one axis no `Lang` value
  ## can name (`LangNim` is `nim c` for a `.nim` and the script VM for a
  ## `.nims`), so it is derived from the kind alone.  `tcUnknown` when the kind
  ## names none, AND when it names more than one: two project manifests in one
  ## directory are two toolchains, and rule K2 forbids picking one silently.
  ## `toolchainAmbiguity` says which ones collided.
  var found: seq[Toolchain] = @[]
  for specific in kind.specific:
    let tc =
      case specific
      of KindCargoProject, KindWasmCargoProject: tcCargo
      of KindNoirProject: tcNargo
      of KindCairoProject: tcScarb
      of KindAikenProject: tcAikenCli
      of KindMoveProject: tcMoveCli
      of KindSwayProject: tcForc
      of KindFoundryProject: tcFoundry
      of KindLeanProject: tcLake
      of KindCrystalProject: tcShards
      of KindLeoProject: tcLeoCli
      of KindNimScript: tcNimScriptVm
      of KindNimSource: tcNimC
      else: tcUnknown
    if tc != tcUnknown and tc notin found:
      found.add(tc)
  if found.len == 1: found[0] else: tcUnknown

func toolchainAmbiguity*(kind: TargetKind): seq[string] =
  ## The kinds in `kind` that each imply a toolchain, when there are two or
  ## more DIFFERENT ones — the names a refusal must print.  Empty otherwise.
  ## (`cargo-project` beside `wasm-cargo-project` is one toolchain, not two,
  ## and is not an ambiguity.)
  var byToolchain: seq[tuple[tc: Toolchain, kinds: seq[string]]] = @[]
  for specific in kind.specific:
    let probe = TargetKind(specific: @[specific], family: kind.family)
    let tc = toolchainForKind(probe)
    if tc == tcUnknown: continue
    var placed = false
    for entry in byToolchain.mitems:
      if entry.tc == tc:
        if specific notin entry.kinds: entry.kinds.add(specific)
        placed = true
    if not placed:
      byToolchain.add((tc, @[specific]))
  if byToolchain.len < 2:
    return @[]
  for entry in byToolchain:
    for k in entry.kinds:
      result.add(k)

func recordingApproachForAssessment*(kind: TargetKind,
                                     lang: SourceLanguage): RecordingApproach =
  ## **PRIMARY.**  How CodeTracer will observe this artefact.
  ##
  ## A plain composition, and deliberately not a table of its own: once the
  ## assessment has settled the ISA, the approach is a total function of the
  ## ISA (`defaultRecordingApproach`) with nothing left to guess.  Writing it as
  ## a composition rather than a second hand-maintained mapping is the whole
  ## improvement over `USES_MATERIALIZED_TRACES`, whose 24 `true` entries had to
  ## be kept in agreement with `recorderToolFor`'s 24 `supported: true` arms by
  ## hand.
  defaultRecordingApproach(targetIsaForAssessment(kind, lang))
