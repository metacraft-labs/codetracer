## target_recognition.nim
##
## The core's client for `ct-native-replay recognize` — milestone **NTR-2** of
## `codetracer-specs/Planned-Features/Native-Target-Recognition.md`.
##
## ## Why this module exists
##
## `ct record <target>` has to decide *what the target is* before it can decide
## which recorder runs.  For a native target that decision needs the target's
## own bytes — ELF/Mach-O/PE container, Go build sections, Go runtime symbols,
## DWARF `DW_AT_language`, GNAT symbols, the DWARF source-language mix — and
## the design's third load-bearing decision (§ Overview) is that CodeTracer
## **delegates** that reading to `ct-native-replay` rather than growing a second
## recognizer in the core.
##
## The core already reached for that delegation, and had been reaching for a
## subcommand that never existed: `language_detection.nim` shelled out to
## `<rrBackend.path> debuginfo lang <program>`, `clap` refused it, stdout was
## empty, `toLang("")` yielded `LangUnknown`, and detection silently fell
## through.  Q4 decided the replacement verb is `recognize`
## (`ct-native-replay recognize --format=json <target>`, NTR-0), and this module
## is the consumer half of it.
##
## ## The schema is a cross-repository contract, so it is version-checked
##
## Q5 (decided by the user) makes `codetracer.target-recognition.v1` a stable
## contract between two **independently released** repositories: the core does
## not bundle `ct-native-replay`, it discovers whatever is first on `PATH`
## (`src/common/config.nim`), so a version-skewed pair is a routine deployment
## state rather than a hypothetical.  Q5's consumer obligations are implemented
## here, literally:
##
## * `schema` is read first and a document whose schema this build does not
##   recognise is **refused, not parsed** — `rsUnsupportedSchema`, with a
##   message naming both the version found and the versions supported.
## * Unknown keys are ignored (the parser reads the keys it knows and never
##   enumerates the document).
## * An unknown *enum* value — a `language`, `kind`, `confidence` or diagnostic
##   `code` this build has never heard of — is never a parse error.  An
##   unrecognised language maps to `LangUnknown`, which means "not recognised by
##   me", exactly as Q5 requires; without this every additive change on the
##   producer side would be silently breaking.
##
## ## What this module does NOT do
##
## It does not decide.  It spawns, parses, version-checks, and hands back a
## result plus a decision *proposal*; `language_detection.nim` is what acts on
## it, and `record.nim`/`run.nim` are what carry it forward.  It also holds no
## state: Q7 decided there is **no cache**, so there is nothing here to
## invalidate and no file is written anywhere.

import
  std/[json, options, osproc, streams, strutils, tables],
  ../../common/lang

const
  RecognitionSchema* = "codetracer.target-recognition.v1"
    ## The one schema version this build of the core understands.

  SupportedRecognitionSchemas* = [RecognitionSchema]
    ## Q5's "the versions it supports".  A list rather than a single constant
    ## because Q5's deprecation window explicitly contemplates a core that
    ## accepts both `v1` and `v2` during a transition.

  RecognizeSubcommand* = "recognize"
    ## Q4's decision.  Named rather than inlined so a test can assert the argv
    ## the core builds without duplicating the spelling.

  RecognizeJsonFormatFlag* = "--format=json"

  DiagAmbiguousLanguage* = "ambiguous-language"
    ## The one **acted-on** diagnostic code (design §6.2's two-class table).
    ## Every other code is informational: carried forward, never acted on.

type
  RecognitionStatus* = enum
    ## Why this outcome is what it is.  Distinguishing the failure modes is the
    ## point: "the recognizer said it could not tell" (`rsOk` with
    ## `kind: unknown`) and "the recognizer could not be asked" are different
    ## facts and the core must not conflate them.
    rsOk                 ## a document was produced, parsed and version-checked
    rsNotAttempted       ## no backend was configured, so nothing was asked
    rsSpawnFailed        ## the backend binary could not be started
    rsExitedNonZero      ## the backend ran and failed (I/O or CLI error)
    rsMalformedOutput    ## stdout was not a recognition document
    rsUnsupportedSchema  ## a document arrived carrying a schema we do not read

  RecognitionDiagnostic* = object
    code*: string
    message*: string

  RecognitionComponent* = object
    language*: string      ## the wire spelling, e.g. "go", "rust", "pythondb"
    confidence*: string    ## "certain" | "likely" | "weak" — kept as text on
                           ## purpose: an unknown value must not be an error
    weight*: int
    evidence*: seq[string]

  RecognitionInterpreter* = object
    program*: string
    args*: seq[string]
    source*: string

  RecognitionFormat* = object
    container*: string
    arch*: string
    os*: string            ## "" when the document says `null` — which it does
                           ## for ELF, deliberately (design §6.2)
    pie*: bool
    stripped*: bool

  RecognitionDebugInfo* = object
    present*: bool
    kind*: string          ## "" when `null`

  RecognitionRecommendation* = object
    recorder*: string
    backend*: string
    strategy*: string

  Recognition* = object
    ## One `codetracer.target-recognition.v1` document.
    schema*: string
    target*: string
    kind*: string
    primary*: Option[RecognitionComponent]
    components*: seq[RecognitionComponent]
    interpreter*: Option[RecognitionInterpreter]
    format*: Option[RecognitionFormat]
    debugInfo*: RecognitionDebugInfo
    recommended*: Option[RecognitionRecommendation]
    diagnostics*: seq[RecognitionDiagnostic]

  RecognitionOutcome* = object
    status*: RecognitionStatus
    recognition*: Recognition
      ## Meaningful only when `status == rsOk`.
    failure*: seq[string]
      ## The user-facing diagnostic for a non-`rsOk` status, already formatted
      ## as lines.  Empty when `status` is `rsOk` or `rsNotAttempted`.
    exitCode*: int

  RecognitionDecisionKind* = enum
    rdLanguage    ## the delegation answered with a language
    rdNoLanguage  ## the delegation answered and could not tell
    rdAmbiguous   ## `primary` is null AND `ambiguous-language` was reported
    rdDegraded    ## the delegation could not be performed or trusted

  RecognitionDecision* = object
    kind*: RecognitionDecisionKind
    lang*: Lang
    lines*: seq[string]
      ## What to tell the user.  Empty for the ordinary `rdLanguage` /
      ## `rdNoLanguage` outcomes; a named diagnostic otherwise.

const WireLanguageOverrides = {
  # `toLang` (src/common/lang.nim) predates the recognition wire format and
  # spells these differently, so they are mapped explicitly rather than left to
  # fall through.  They matter: these are the values that select a RECORDER, so
  # getting one wrong is a recorder change disguised as a parse gap.
  #
  # `pythondb` / `rubydb` would otherwise be `LangUnknown` — `toLang` has never
  # heard of either.
  "pythondb": LangPythonDb,
  "rubydb": LangRubyDb,
  # `python` and `ruby` are the spellings a *shebang* produces, which is what
  # NTR-3 adds, and `toLang` is ASYMMETRIC about them: `"python"` already gives
  # `LangPythonDb` but `"ruby"` gives `LangRuby`, which does NOT use
  # materialized traces and would therefore send a Ruby script down the NATIVE
  # path.  Both are pinned here so the wire mapping is uniformly
  # recorder-selecting and the asymmetry cannot leak in when the producer starts
  # emitting interpreter languages.  (`--lang ruby` is a different road and
  # still goes through `toLang`; this table is only for the wire.)
  "python": LangPythonDb,
  "ruby": LangRubyDb,
}.toTable()

proc langFromWireName*(wire: string): Lang =
  ## Map a `components[].language` wire value onto the core's `Lang`.
  ##
  ## An unrecognised value yields `LangUnknown` and is **not** an error — Q5's
  ## consumer obligation, in one function: "must not fail on an unknown enum
  ## value ... treated as 'not recognised by me', never as a parse error".
  let key = wire.strip.toLowerAscii
  if key.len == 0:
    return LangUnknown
  if WireLanguageOverrides.hasKey(key):
    return WireLanguageOverrides[key]
  toLang(key)

proc recognizeArgs*(target: string): seq[string] =
  ## The exact argv the core invokes.  Exported so a test can assert the
  ## delegation's shape without re-spelling it.
  @[RecognizeSubcommand, RecognizeJsonFormatFlag, target]

# ---------------------------------------------------------------------------
# Parsing
#
# Every reader below is total: it answers for a node of the wrong kind rather
# than raising, because Q5 forbids failing on anything except an unreadable
# schema.
# ---------------------------------------------------------------------------

proc strField(node: JsonNode, key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else:
    ""

proc boolField(node: JsonNode, key: string): bool =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
    node[key].getBool
  else:
    false

proc intField(node: JsonNode, key: string): int =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JInt:
    node[key].getInt
  else:
    0

proc stringSeqField(node: JsonNode, key: string): seq[string] =
  result = @[]
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JArray:
    for item in node[key]:
      if item.kind == JString:
        result.add(item.getStr)

proc parseComponent(node: JsonNode): RecognitionComponent =
  RecognitionComponent(
    language: node.strField("language"),
    confidence: node.strField("confidence"),
    weight: node.intField("weight"),
    evidence: node.stringSeqField("evidence"))

proc parseRecognitionDocument*(raw: string): RecognitionOutcome =
  ## Parse and version-check one `--format=json` document.
  ##
  ## Pure: no process, no filesystem.  It is the half of the delegation that a
  ## test can drive with a literal string, which is what makes "an unrecognised
  ## schema is refused" and "`kind: unknown` is not an error" assertable
  ## without a compiler toolchain.
  var document: JsonNode
  try:
    document = parseJson(raw)
  except CatchableError as e:
    return RecognitionOutcome(
      status: rsMalformedOutput,
      failure: @[
        "warning: ct-native-replay recognize did not produce a JSON document.",
        "         " & e.msg,
        "         target recognition was skipped for this run."])

  if document.kind != JObject:
    return RecognitionOutcome(
      status: rsMalformedOutput,
      failure: @[
        "warning: ct-native-replay recognize produced a JSON value that is " &
          "not a recognition document.",
        "         target recognition was skipped for this run."])

  let schema = document.strField("schema")
  if schema.len == 0:
    return RecognitionOutcome(
      status: rsMalformedOutput,
      failure: @[
        "warning: ct-native-replay recognize produced a document with no " &
          "`schema` field.",
        "         the schema string is the only supported way to detect the " &
          "version; field-presence sniffing is not.",
        "         target recognition was skipped for this run."])

  if schema notin SupportedRecognitionSchemas:
    # Q5: "must refuse, with an error naming both the version it found and the
    # versions it supports ... must never parse a document whose schema it does
    # not recognise".  So this returns BEFORE reading a single other key.
    return RecognitionOutcome(
      status: rsUnsupportedSchema,
      failure: @[
        "error: ct-native-replay produced target-recognition schema '" &
          schema & "',",
        "       which this build of CodeTracer does not understand.",
        "       supported: " & SupportedRecognitionSchemas.join(", "),
        "help: update CodeTracer, or put a matching ct-native-replay first " &
          "on PATH."])

  var recognition = Recognition(
    schema: schema,
    target: document.strField("target"),
    kind: document.strField("kind"),
    primary: none(RecognitionComponent),
    components: @[],
    interpreter: none(RecognitionInterpreter),
    format: none(RecognitionFormat),
    debugInfo: RecognitionDebugInfo(),
    recommended: none(RecognitionRecommendation),
    diagnostics: @[])

  if document.hasKey("primary") and document["primary"].kind == JObject:
    recognition.primary = some(parseComponent(document["primary"]))

  if document.hasKey("components") and document["components"].kind == JArray:
    for item in document["components"]:
      if item.kind == JObject:
        recognition.components.add(parseComponent(item))

  if document.hasKey("interpreter") and document["interpreter"].kind == JObject:
    let node = document["interpreter"]
    recognition.interpreter = some(RecognitionInterpreter(
      program: node.strField("program"),
      args: node.stringSeqField("args"),
      source: node.strField("source")))

  if document.hasKey("format") and document["format"].kind == JObject:
    let node = document["format"]
    recognition.format = some(RecognitionFormat(
      container: node.strField("container"),
      arch: node.strField("arch"),
      os: node.strField("os"),
      pie: node.boolField("pie"),
      stripped: node.boolField("stripped")))

  if document.hasKey("debug_info") and document["debug_info"].kind == JObject:
    let node = document["debug_info"]
    recognition.debugInfo = RecognitionDebugInfo(
      present: node.boolField("present"),
      kind: node.strField("kind"))

  if document.hasKey("recommended") and document["recommended"].kind == JObject:
    let node = document["recommended"]
    recognition.recommended = some(RecognitionRecommendation(
      recorder: node.strField("recorder"),
      backend: node.strField("backend"),
      strategy: node.strField("strategy")))

  if document.hasKey("diagnostics") and document["diagnostics"].kind == JArray:
    for item in document["diagnostics"]:
      if item.kind == JObject:
        recognition.diagnostics.add(RecognitionDiagnostic(
          code: item.strField("code"),
          message: item.strField("message")))

  RecognitionOutcome(status: rsOk, recognition: recognition)

proc hasDiagnostic*(recognition: Recognition, code: string): bool =
  for entry in recognition.diagnostics:
    if entry.code == code:
      return true
  false

proc diagnosticMessage*(recognition: Recognition, code: string): string =
  for entry in recognition.diagnostics:
    if entry.code == code:
      return entry.message
  ""

# ---------------------------------------------------------------------------
# Invocation
# ---------------------------------------------------------------------------

proc recognizeTarget*(backendPath, target: string): RecognitionOutcome =
  ## Run `<backendPath> recognize --format=json <target>` and consume it.
  ##
  ## **Q7: this runs on every invocation and stores nothing.**  There is no
  ## cache, no cache file and no invalidation rule, because an mtime-preserving
  ## rebuild would make a `(path, mtime, size)` key answer confidently and
  ## wrongly.  Carrying the returned value along one invocation's own call
  ## chain is ordinary parameter passing and is expected; persisting it is not.
  ##
  ## Exit-status contract (design §6.2), honoured literally: a **non-zero exit
  ## is a real failure** (the target does not exist, is unreadable, or the CLI
  ## was misused), while `kind: unknown` on a zero exit is a *result* — "I
  ## looked and could not tell" — and is not treated as an error here.
  if backendPath.len == 0:
    return RecognitionOutcome(status: rsNotAttempted)

  let args = recognizeArgs(target)
  var process: Process
  try:
    process = startProcess(backendPath, args = args, options = {})
  except CatchableError as e:
    return RecognitionOutcome(
      status: rsSpawnFailed,
      failure: @[
        "warning: could not run the target recognizer: " & backendPath & " " &
          args.join(" "),
        "         " & e.msg,
        "         target recognition was skipped for this run."])

  var output = ""
  var errors = ""
  try:
    # The document is a few hundred bytes and the recognizer's stderr is one
    # line at most, so reading stdout to EOF before stderr cannot deadlock on
    # a full pipe here.
    output = process.outputStream.readAll()
    errors = process.errorStream.readAll()
  except CatchableError as e:
    errors = e.msg
  let code = process.waitForExit()
  process.close()

  if code != 0:
    var lines = @[
      "warning: ct-native-replay recognize failed for '" & target &
        "' (exit " & $code & ").",
    ]
    for line in errors.strip.splitLines:
      if line.strip.len > 0:
        lines.add("         " & line.strip)
    lines.add("         target recognition was skipped for this run.")
    return RecognitionOutcome(
      status: rsExitedNonZero, failure: lines, exitCode: code)

  result = parseRecognitionDocument(output)
  result.exitCode = code

# ---------------------------------------------------------------------------
# Deciding
# ---------------------------------------------------------------------------

proc decideFromRecognition*(outcome: RecognitionOutcome,
                            target: string): RecognitionDecision =
  ## Turn a recognition outcome into the core's `Lang` decision.
  ##
  ## Three rules, and only the first of them is new to NTR-2:
  ##
  ## 1. `primary` names the language; `components[]`, `kind`, `interpreter` and
  ##    `format` ride along on the outcome for the caller to carry forward.
  ## 2. A **null `primary` with an `ambiguous-language` diagnostic** is design
  ##    rule C2: a hard error naming `--lang`, never a silent fallback.  Every
  ##    other diagnostic code is informational — carried, never acted on
  ##    (design §6.2's two-class table); whether it is *printed* is Q10 and
  ##    belongs to NTR-3.
  ## 3. Anything that prevented a trustworthy answer is `rdDegraded` with a
  ##    named diagnostic.  It is deliberately not silent: "the delegation did
  ##    not happen" used to be indistinguishable from "the delegation found
  ##    nothing", and that indistinguishability is what let a dead call site
  ##    survive unnoticed.
  case outcome.status
  of rsNotAttempted:
    return RecognitionDecision(kind: rdDegraded, lang: LangUnknown)
  of rsSpawnFailed, rsExitedNonZero, rsMalformedOutput, rsUnsupportedSchema:
    return RecognitionDecision(
      kind: rdDegraded, lang: LangUnknown, lines: outcome.failure)
  of rsOk:
    discard

  let recognition = outcome.recognition
  if recognition.primary.isNone:
    if recognition.hasDiagnostic(DiagAmbiguousLanguage):
      var lines = @[
        "error: target recognition is ambiguous for '" & target & "'.",
      ]
      let message = recognition.diagnosticMessage(DiagAmbiguousLanguage)
      if message.len > 0:
        lines.add("       " & message)
      lines.add(
        "help: pass --lang <language> to say which language to record; " &
          "CodeTracer will not guess.")
      return RecognitionDecision(
        kind: rdAmbiguous, lang: LangUnknown, lines: lines)
    return RecognitionDecision(kind: rdNoLanguage, lang: LangUnknown)

  let lang = langFromWireName(recognition.primary.get.language)
  if lang == LangUnknown:
    return RecognitionDecision(kind: rdNoLanguage, lang: LangUnknown)
  RecognitionDecision(kind: rdLanguage, lang: lang)
