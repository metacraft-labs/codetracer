## Which backend reads a recording — decided once, in one place.
##
## CodeTracer has always spelled a recording's *trace kind* as one of the
## strings ``"rr"`` and ``"db"``: it is the argument `importTrace` takes
## (`src/ct/trace/storage_and_import.nim`), the thing `ct record` decides
## (`src/ct/db_backend_record.nim`) and the thing `ct replay` decides again
## (`src/ct/trace/replay.nim`).  What it did *not* have was one routine that
## answers "what is this path?", so the answer was open-coded at every site
## that needed it, and the copies had already drifted apart.
##
## This module is that routine.  It states the evidence, the rules, and the
## two questions the rules answer:
##
## * **"Which backend opens this trace?"** — `ct replay`'s question.  Every
##   path is one of the two; a path that carries no recognisable evidence is
##   assumed to be a native replay trace, because that is what `replay.nim`
##   has always assumed and its metadata comes from `meta.dat` rather than
##   from the folder shape.
## * **"Is this a recording at all?"** — `ct review collect`'s question, which
##   is *not* the same question.  A directory the user mistyped is not a
##   native trace, and answering "native" for it is how
##   `ct review collect --recordings ~/src` produced an empty dataset and
##   exited 0.  :enum:`CtTraceKind` therefore has an explicit
##   `ctkUnknown`, and each caller chooses what to do with it: `replay.nim`
##   maps it to ``"rr"`` (its long-standing default), `review_cli.nim` refuses.
##
## ## The evidence
##
## ==========================  ==================================================
## On disk                     Means
## ==========================  ==================================================
## the path *is* a ``.ct``     an MCR container, replayed by the native worker
## a ``mcr`` marker file       an MCR recording folder
## an rr ``version`` file      an rr trace directory — rr writes one in every
##                             trace, and it is the rule the native DeepReview
##                             collector already discovers recordings by
##                             (`codetracer-native-backend`,
##                             `deepreview::cli::discover_recordings`)
## a ``.ct`` container inside  a materialized CTFS bundle
## ``trace_metadata.json`` /   a materialized trace in the pre-CTFS three-file
## ``trace.bin`` / ``trace.json``  layout
## ==========================  ==================================================
##
## The `.ct` container is genuinely ambiguous — native MCR recordings and
## materialized traces share the CTFS container format — and the `mcr` marker
## is what distinguishes them.  That is not a rule invented here: it is
## exactly the rule `ct replay` has been applying, preserved rather than
## replaced.
##
## ## Two deliberate changes to `ct replay`'s answer
##
## Moving these rules out of `replay.nim` was intended to be exact, and is
## everywhere except two cases, which the exhaustive equivalence test in
## `src/tests/gui/tests/deepreview/ct_review_cli_test.nim` found by building
## every combination of the facts the two rules read.  Both are the same
## correction — the old rule decided by falling through, these rules decide on
## positive evidence — and both move a path towards the backend that can
## actually open it:
##
## 1. A *pre-CTFS materialized* folder (`trace_metadata.json` + `trace.bin`,
##    the shape `ct record-web` writes) has no `.ct` container, so the old
##    rule fell through to its `else` and answered ``"rr"`` — a materialized
##    recording classified as one the native replay worker opens, which then
##    decides the language mapping (`detectTraceLang`) and which arm of
##    `trace_index.recordTrace` runs.  It is answered ``"db"`` here.
## 2. An rr trace directory that also holds a `*.ct` file was answered
##    ``"db"``, because the old rule had no test for rr's `version` file at
##    all and reached its container test first.  It is answered ``"rr"`` here.
##
## Neither can reclassify a native recording *away* from the native worker:
## an rr trace directory has rr's `version`, an MCR folder has its marker, a
## TTD trace is a `.run` file, and all three are tested before any
## materialized evidence is considered.
##
## The sibling `codetracer-native-backend/src/trace_kind.rs` answers the same
## question on the Rust side (`TraceKind` / `detect_trace_kind`) and is kept
## in step with the table above; the two are separate implementations because
## `ct` must be able to say "these are materialized traces" on a machine where
## the native replay backend was never installed, which is the whole point of
## DeepReview not being an rr-only feature (DeepReview-GUI.md §1.1).

type
  CtTraceKind* = enum
    ## What kind of recording a path holds, and therefore which backend reads
    ## it.  See the module header for why `ctkUnknown` is a value rather than
    ## an assumed default.
    ctkUnknown
      ## nothing on disk identifies this path as a recording
    ctkNative
      ## rr, TTD or MCR — read by the native replay worker (`ct-native-replay`)
    ctkMaterialized
      ## a materialized trace (CTFS container or the pre-CTFS three-file
      ## layout) — read by the db-backend

const
  TraceKindNative* = "rr"
    ## The `traceKind` string CodeTracer has always used for traces the
    ## native replay worker opens.  Named here so callers stop spelling it
    ## as a literal in a dozen places.
  TraceKindMaterialized* = "db"
    ## The `traceKind` string for materialized traces.

  McrMarkerFileName* = "mcr"
    ## Marker file that distinguishes a native MCR recording folder from a
    ## materialized CTFS bundle; both hold a `.ct` container.
  RrVersionFileName* = "version"
    ## rr writes this in every trace directory it records.
  CtContainerExt* = ".ct"
    ## CTFS container extension.
  MaterializedIndexFileNames* = ["trace_metadata.json", "trace.bin",
                                 "trace.json"]
    ## The pre-CTFS materialized layout: any one of these in a directory
    ## identifies it as a materialized trace.  `ct print-trace` recognises
    ## the same three (`src/ct/cli/print_trace.detectTraceType`).

type
  TraceEvidence* = object
    ## Everything about a path that the classification depends on, gathered
    ## in one filesystem pass by `traceEvidence` and decided by the pure
    ## `traceKindFromEvidence`.
    ##
    ## Splitting the two is what lets the rules be asserted on the `nim js`
    ## backend and without a recording on disk — the same split
    ## `review_cli.nim` uses for argv.
    name*: string
      ## The entry's own name, for diagnostics.  Not part of the decision.
    isDirectory*: bool
    pathIsCtContainer*: bool
      ## the path itself ends in `.ct`.  Suffix only, with no existence
      ## check: that is what `ct replay` has always tested, and this module
      ## replaced that test rather than tightening it, so that moving the
      ## rules here would not change what `ct replay` does.
    hasMcrMarker*: bool
    hasRrVersionFile*: bool
    holdsCtContainer*: bool
      ## a `*.ct` file directly inside the directory
    holdsMaterializedIndex*: bool
      ## one of `MaterializedIndexFileNames` directly inside the directory

  RecordingSurveyEntry* = object
    ## One entry of a recordings directory, with what it turned out to be.
    ##
    ## Declared with the pure rules rather than beside `surveyRecordings`
    ## because the *routing* decision that consumes a survey
    ## (`review_cli.routeReviewCollect`) is itself pure and is asserted on the
    ## `nim js` backend, where there is no filesystem to survey.
    name*: string
    kind*: CtTraceKind

func traceKindFromEvidence*(evidence: TraceEvidence): CtTraceKind =
  ## Classify a path from the facts gathered about it.
  ##
  ## Order matters and is the order of the table in the module header: the
  ## MCR marker is checked before the `.ct` container because a folder that
  ## has both is a native MCR recording, not a materialized bundle.
  if evidence.pathIsCtContainer:
    return ctkNative
  if evidence.hasMcrMarker:
    return ctkNative
  if evidence.hasRrVersionFile:
    return ctkNative
  if evidence.holdsCtContainer or evidence.holdsMaterializedIndex:
    return ctkMaterialized
  ctkUnknown

func traceKindString*(kind: CtTraceKind): string =
  ## The `traceKind` string this kind is spelled as everywhere else in `ct`.
  ##
  ## `ctkUnknown` maps to `TraceKindNative` deliberately: it is the default
  ## `ct replay` and `ct import` have always taken for a folder they could
  ## not otherwise identify, and this routine must not change what they do.
  ## Callers that must *not* guess (`ct review collect`) look at the
  ## `CtTraceKind` instead.
  case kind
  of ctkMaterialized: TraceKindMaterialized
  else: TraceKindNative

func traceKindLabel*(kind: CtTraceKind): string =
  ## How a kind is named to a user.  Diagnostics have to name the kind they
  ## could not handle, so the wording lives with the enum rather than being
  ## re-invented per message.
  case kind
  of ctkNative: "native (rr)"
  of ctkMaterialized: "materialized (CTFS)"
  of ctkUnknown: "unrecognised"

when not defined(js):
  import std/[algorithm, os, strutils]

  proc traceEvidence*(path: string): TraceEvidence =
    ## Gather the facts `traceKindFromEvidence` decides on, in one pass over
    ## the directory.  A path that does not exist yields no evidence at all,
    ## and therefore classifies as `ctkUnknown`.
    result = TraceEvidence(
      name: path.lastPathPart,
      pathIsCtContainer: path.endsWith(CtContainerExt))
    if not dirExists(path):
      return
    result.isDirectory = true
    result.hasMcrMarker = fileExists(path / McrMarkerFileName)
    result.hasRrVersionFile = fileExists(path / RrVersionFileName)
    for name in MaterializedIndexFileNames:
      if fileExists(path / name):
        result.holdsMaterializedIndex = true
        break
    for kind, entry in walkDir(path):
      if kind in {pcFile, pcLinkToFile} and entry.endsWith(CtContainerExt):
        result.holdsCtContainer = true
        break

  proc detectTraceKind*(path: string): CtTraceKind =
    ## What kind of recording lives at `path`.  See the module header.
    traceKindFromEvidence(traceEvidence(path))

  proc surveyRecordings*(recordingsDir: string): seq[RecordingSurveyEntry] =
    ## Classify every entry of a recordings directory.
    ##
    ## *Every* entry, including the ones that are not recordings: a caller
    ## that only saw the recordings could not tell an empty directory from a
    ## directory full of source files, and those two mistakes deserve
    ## different answers.  Sorted by name so a diagnostic naming "the first
    ## three" names the same three on every filesystem.
    result = @[]
    if not dirExists(recordingsDir):
      return
    for kind, entry in walkDir(recordingsDir):
      if kind notin {pcFile, pcDir, pcLinkToFile, pcLinkToDir}:
        continue
      result.add RecordingSurveyEntry(
        name: entry.lastPathPart,
        kind: detectTraceKind(entry))
    result.sort do (a, b: RecordingSurveyEntry) -> int:
      cmp(a.name, b.name)
