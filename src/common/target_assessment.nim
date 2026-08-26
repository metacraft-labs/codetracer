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
## ## The kind chain, and the must-understand rule
##
## A kind is not a single token.  It is an **ordered chain, most specific
## first**, whose last element is drawn from a vocabulary frozen for the life of
## the major version:
##
## ```text
##   ["cargo-project", "rust-project", "project-directory"]
##                                     ^^^^^^^^^^^^^^^^^^^  a TargetFamily
## ```
##
## | Rule | Statement |
## | --- | --- |
## | **K1** | The last element of the chain is always a `TargetFamily` token. |
## | **K2** | A consumer takes the **first** element it understands. |
## | **K3** | If it understands none, K1 was violated — that is a protocol error and it fails loudly, naming the chain and the producer. |
## | **K4** | A producer that must *not* be degraded ends its chain at `tfUnassessable`, which is itself a family and therefore satisfies K1 while forbidding any general handling. |
##
## The degradation path is written by the **producer**, which knows what a
## `cargo-project` may safely be treated as; it is never guessed by the
## consumer.  That is the whole difference between "degrade explicitly" and
## "degrade silently".
##
## `TargetKind` below makes **K1 unrepresentable-if-violated**: the family is a
## typed field, not the chain's last string, so a producer cannot emit a chain
## that ends anywhere else.  K3 can therefore only fire at the parse boundary,
## which is where `parseKindChain` puts it.
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
## *shape*, which is exactly the family level of this model, and it maps onto
## `TargetFamily` with no loss (`familyFromRecognitionKind` below).
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
## This module is **additive**: it defines the type and its conversions.  No
## producer emits one yet and no consumer reads one yet; wiring it into
## `recognize` and into `detectTarget` is a later increment, sequenced in
## `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.milestones.org`.

import std/strutils
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
      ## it.  Refuse, naming `kind.specific[0]` and the producer, so the user is
      ## told *which* component to update.  This is rule K4's landing site: it
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
    ## An assessment's answer.  See "the kind chain" above.
    specific*: seq[string]
      ## Open vocabulary, most specific first.  May be empty, which means the
      ## producer had nothing more specific than the family.  Tokens are
      ## lowercase ASCII with `-` as the word separator.
    family*: TargetFamily
      ## Closed vocabulary; the guaranteed floor of the chain.  Typed rather
      ## than "the last string" so that rule K1 cannot be violated by
      ## construction.

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
    ## What happened when a consumer resolved a kind chain.
    krExact       ## the consumer understood the most specific token
    krDegraded    ## it understood a less specific one; `token` says which
    krFamilyOnly  ## it understood no specific token and fell back to the family
    krRefused     ## the family is `tfUnassessable`: the producer forbade
                  ## degradation and the consumer must refuse

  KindResolution* = object
    status*: KindResolutionStatus
    token*: string
      ## The token the consumer will act on.  For `krFamilyOnly` and
      ## `krRefused` this is the family token.
    skipped*: seq[string]
      ## The more specific tokens that were passed over, in order.  A consumer
      ## that degrades should say so using this; that is what makes the
      ## degradation *explicit* rather than silent.

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
# The chain
# ---------------------------------------------------------------------------

func chain*(k: TargetKind): seq[string] =
  ## The wire form: the specific tokens, then the family token.  Never empty,
  ## because the family is always present — which is rule K1, enforced by the
  ## type rather than by the encoder.
  result = @[]
  for s in k.specific:
    result.add(s)
  result.add(token(k.family))

func parseKindChain*(wire: openArray[string], value: var TargetKind,
                     diagnostic: var string): bool =
  ## Decode a wire chain.  Rule K3 lives here and nowhere else.
  ##
  ## Fails, loudly and with a named diagnostic, when the chain is empty or its
  ## last element is not a family token of this major version.  It deliberately
  ## does **not** search the chain for *any* recognisable family: a producer
  ## that put the family somewhere other than last has violated K1, and quietly
  ## repairing that would turn a protocol bug into an invisible behaviour
  ## change.
  if wire.len == 0:
    diagnostic = "target-assessment: the kind chain is empty; rule K1 requires " &
      "at least the family token"
    return false
  var fam: TargetFamily
  let last = wire[wire.high]
  if not parseTargetFamily(last, fam):
    diagnostic = "target-assessment: the kind chain ends in '" & last &
      "', which is not a target family this build knows. Known families: " &
      knownFamilyTokens() & ". The chain was: " & wire.join(" -> ") & "."
    return false
  var specific: seq[string] = @[]
  for i in 0 ..< wire.high:
    specific.add(wire[i])
  value = TargetKind(specific: specific, family: fam)
  true

func resolveKind*(k: TargetKind, understood: openArray[string]): KindResolution =
  ## Rule K2: take the first token the consumer understands.
  ##
  ## `understood` is the consumer's own vocabulary — the specific kinds it has
  ## code for.  It is passed in rather than read from a registry so that a test
  ## can drive a consumer that knows nothing, which is the version-skew case
  ## that has to work.
  ##
  ## The family is never in `understood`: falling back to it is `krFamilyOnly`,
  ## which is a distinct outcome from understanding a specific token, and a
  ## caller that logs the difference is what makes the degradation visible.
  var skipped: seq[string] = @[]
  if k.family == tfUnassessable:
    return KindResolution(status: krRefused, token: token(k.family),
                          skipped: k.specific)
  for i, s in k.specific:
    var known = false
    for u in understood:
      if u == s:
        known = true
        break
    if known:
      return KindResolution(
        status: (if i == 0: krExact else: krDegraded),
        token: s, skipped: skipped)
    skipped.add(s)
  KindResolution(status: krFamilyOnly, token: token(k.family), skipped: skipped)

# ---------------------------------------------------------------------------
# Composition with `codetracer.target-recognition.v1`
# ---------------------------------------------------------------------------

func familyFromRecognitionKind*(recognitionKind: string,
                               value: var TargetFamily): bool =
  ## Map `recognize`'s `kind` onto a family.  Total.
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
    value = tfPrebuiltArtefact
    true
  of "script":
    value = tfSingleFile
    true
  of "directory":
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
# markers are `detectFolderLang` (`src/ct/utilities/language_detection.nim:28-65`),
# which is the assessment algorithm in embryo and which today throws the answer
# away by returning a `Lang`: `Cargo.toml` becomes `LangRust`, and the fact that
# it was a *cargo project* — the thing that decides whether to build before
# recording — is lost at the return statement.
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
    ## In `detectFolderLang`'s own order, which is load-bearing there: the first
    ## marker that exists wins, so `Cargo.toml` is tested *after* the six
    ## chain-specific manifests.  A crate that is also a Foundry project is a
    ## Foundry project.  Recorded in order so that a later implementation
    ## reproduces the existing precedence rather than reinventing one.

func projectKindForMarker*(marker: string, kind: var string): bool =
  ## Total lookup over `ProjectMarkerKinds`.
  for row in ProjectMarkerKinds:
    if row.marker == marker:
      kind = row.kind
      return true
  false
