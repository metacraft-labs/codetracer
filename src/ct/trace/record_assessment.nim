## record_assessment.nim
##
## The assessment `ct record` dispatches on — built LOCALLY, from what the tree
## already knows about a target, until the protocol producer lands (LRS-2P).
##
## `ct record`'s algorithm is *"assess what the target file or directory is
## and decide what sort of recording to create"*, and the assessment does not
## return a language (`src/common/target_assessment.nim`).  Before LRS-2B the
## decision was a function of one `Lang` value, which is why a `.nims` and a
## `.nim` — same language, different ISA, toolchain AND recording approach —
## reached the same `recorderToolFor(LangNim)` arm and `requireRecorder`
## demanded `ct-mcr` for a script the compiler's own VM records.
##
## `assessRecordingTarget` below derives a `TargetAssessment` from three
## things the tree has today: the detected `Lang` summary (`detectTarget`),
## the target path, and the project markers in a directory.  It is honest
## about what it is:
##
## * It is NOT a protocol producer.  Nothing emits it on a wire; its
##   `producer` says so, and its `schema` is the v1 constant only because the
##   type carries one.  LRS-2P replaces the `Lang`-derived parts with the
##   recognizer's own assessment.
## * The KIND decides where it can (`.nims` → `nimscript`, `Cargo.toml` +
##   `wasm32` → `wasm-cargo-project`, every project marker present → every
##   project kind, per Q10), and the `Lang` value's own axes answer where it
##   cannot.  A `Lang` that exists precisely to name a non-default ISA or
##   approach (`LangRustWasm`, the retired `LangPython`/`LangRuby`) keeps
##   that answer.
## * Two facts that would dispatch differently are a REFUSAL, never a pick
##   (rule K2): two project manifests implying two toolchains, or two kinds
##   implying two ISAs, land in `diagnostics` and the caller refuses — unless
##   the user already resolved it with an explicit `--lang`, which
##   `detectTarget` already treats as an instruction that is not
##   second-guessed (its Q8 rule).  Then the facts are still recorded, the
##   user's answer is used, and the diagnostic says so without refusing.

import std/[os, strutils]
import ../../common/[lang, target_assessment]
import ../utilities/language_detection
import ./recorder_dispatch

export target_assessment

const
  LocalAssessmentProducer* = "ct record (local assessment, not a protocol producer)"
    ## What `TargetAssessment.producer` says for an assessment built here.
    ## Deliberately unlike a `<component>/<version>` so that a diagnostic
    ## quoting it cannot be mistaken for a PATH-discovered component.

  RefusalMarker = "nothing may pick one silently"
    ## Every refusal-grade diagnostic carries this phrase; `isAmbiguous` keys
    ## on it so the protocol type needs no extra field for local state.

proc directoryEntryNames(folder: string): seq[string] =
  ## The bare names of the entries in `folder`.  Pure input for the pure
  ## `projectKindsForMarkers`.
  result = @[]
  for _, path in walkDir(folder):
    result.add(path.extractFilename)

proc assessKind(program: string, language: SourceLanguage): TargetKind =
  ## The kind: family from the target's shape, specific kinds from the
  ## markers and the extension.  ALL project markers present are emitted
  ## (Q10).  The two Nim kinds are emitted only when the target IS Nim — a
  ## `.nims` handed to `--lang py` is, by the user's instruction, a Python
  ## target, and `nimscript` would then override the ISA of a language it
  ## does not belong to.
  if dirExists(program):
    let names = directoryEntryNames(program)
    var specific = projectKindsForMarkers(names)
    if "Cargo.toml" in names and isWasmCargoProject(program):
      specific.add(KindWasmCargoProject)
    return TargetKind(specific: specific, family: tfProjectDirectory)
  let ext = program.splitFile.ext.toLowerAscii
  if fileExists(program) or language != slUnknown:
    if language == slNim and ext == ".nims":
      TargetKind(specific: @[KindNimScript], family: tfSingleFile)
    elif language == slNim and ext == ".nim":
      TargetKind(specific: @[KindNimSource], family: tfSingleFile)
    elif ext == ".wasm":
      TargetKind(specific: @[], family: tfPrebuiltArtefact)
    else:
      TargetKind(specific: @[], family: tfSingleFile)
  else:
    TargetKind(specific: @[], family: tfUnknown)

proc assessRecordingTarget*(program: string, lang: Lang,
                            languageWasExplicit = false): TargetAssessment =
  ## Assess `program`, whose `Lang` summary `detectTarget` already produced.
  ## `languageWasExplicit` is true when that summary came from `--lang`.
  ##
  ## The ISA is decided in this order, each step only when the previous one
  ## said nothing: the kind (`targetIsaForAssessment`), then the `Lang`
  ## value's own ISA (`axesOfLang`, which is `tiWasm` for `LangRustWasm` and
  ## the per-language fallback for everything else).  The approach follows the
  ## ISA (`defaultRecordingApproach`) unless the `Lang` value exists to name a
  ## non-default one — the retired rr pair — in which case that is what the
  ## user asked for and what the dispatch table must answer about.
  let axes = axesOfLang(lang)
  let kind = assessKind(program, axes.language)
  result = TargetAssessment(
    schema: TargetAssessmentSchema,
    producer: LocalAssessmentProducer,
    target: program,
    kind: kind)

  let isaClash = targetIsaAmbiguity(kind)
  let toolchainClash = toolchainAmbiguity(kind)
  let clashes = isaClash.len > 0 or toolchainClash.len > 0
  let refuse = clashes and not languageWasExplicit

  if isaClash.len > 0:
    result.diagnostics.add(
      "target-assessment: the target is more than one kind that decides the " &
      "target ISA — " & isaClash.join(" and ") & " — and " &
      (if refuse: RefusalMarker & "."
       else: "`--lang` resolved it as " & displayName(axes.language) & "."))
  if toolchainClash.len > 0:
    result.diagnostics.add(
      "target-assessment: the directory carries more than one project " &
      "manifest that names a toolchain — " & toolchainClash.join(" and ") &
      " — and " &
      (if refuse: RefusalMarker & ". Name the intended project explicitly " &
                  "(`--lang`), or record from inside the one you mean."
       else: "`--lang` resolved it as " & displayName(axes.language) &
             "; the toolchain is left undetermined."))

  if refuse:
    # Nothing downstream may read a decision out of a refusal.
    result.targetIsa = tiUnknown
    result.toolchain = tcUnknown
    result.recordingApproach = raUnknown
  else:
    result.toolchain = if toolchainClash.len == 0: toolchainForKind(kind)
                       else: tcUnknown
    let fromKind = if isaClash.len == 0: targetIsaForAssessment(kind, axes.language)
                   else: tiUnknown
    result.targetIsa =
      if fromKind != tiUnknown and
         fromKind != fallbackTargetIsaForLanguage(axes.language): fromKind
      else: axes.targetIsa
    if axes.approach != defaultRecordingApproach(axes.targetIsa):
      # The `Lang` value names a non-default approach: `LangPython` /
      # `LangRuby` are `raRr` on an interpreted ISA whose default is the
      # instrumented runtime.  That IS the fact the user stated with `--lang`,
      # so it is kept and the dispatch table gets to say what it thinks of it.
      result.recordingApproach = axes.approach
    else:
      result.recordingApproach = defaultRecordingApproach(result.targetIsa)

  if axes.language != slUnknown:
    result.languages.add(AssessedLanguage(language: axes.language, fileCount: 0))

func isAmbiguous*(assessment: TargetAssessment): bool =
  ## Did the assessment find two facts it may not choose between, with no
  ## `--lang` to resolve them?  A caller that sees `true` refuses, printing
  ## `diagnostics`, and records nothing.
  for line in assessment.diagnostics:
    if RefusalMarker in line:
      return true
  false

proc recorderSelectorFor*(assessment: TargetAssessment,
                          lang: Lang): RecorderSelector =
  ## The dispatch key for this assessment and the target's primary language.
  selectorOf(assessment, sourceLanguageOf(lang))

proc assessedSelector*(program: string, lang: Lang,
                       languageWasExplicit = false): RecorderSelector =
  ## One-call convenience for callers that only need the dispatch key.
  ## Ambiguity is NOT swallowed: a refused assessment yields a selector with
  ## `raUnknown`, which no table arm supports, so the caller still fails —
  ## but a caller that wants the diagnostic must use `assessRecordingTarget`
  ## and check `isAmbiguous` itself.
  recorderSelectorFor(
    assessRecordingTarget(program, lang, languageWasExplicit), lang)
