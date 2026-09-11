## project_definitions/diagnostics.nim — PLAT-11. The one problem type, and
## the rule that every instance of it names the FILE it came from.
##
## ## WHY THE FILE IS A FIELD
##
## `plugin_model/diagnostics.nim` made the same argument about the plugin id
## and it applies here with more force. A plugin manifest is something a user
## installed; a project definition arrives by `git clone`, so the reader of an
## error has no prior relationship with the file at all. "unknown key
## 'interpreter'" tells them nothing; "`.codetracer/visualisers.toml` line 14:
## unknown key 'interpreter'" tells them which of possibly several
## `.codetracer/` directories in a monorepo to open, and where.
##
## So `file` is a FIELD, `render` puts it first, and
## `project_definitions_test` sweeps every problem the whole suite produces
## and asserts the file name is present in the rendered text — a sweep rather
## than a per-case claim, because a per-case claim is satisfied by the cases
## somebody remembered to write.
##
## ## TWO SEVERITIES, BECAUSE "UNKNOWN TO THIS BUILD" IS NOT "MALFORMED"
##
## PLAT-11's brief asks that a definition which is merely unknown to this
## build — a future schema version, a key this build does not have — be a
## *reportable condition* rather than a silent skip. Both of those ARE
## refusals: the file contributes nothing. What distinguishes them from a
## syntax error is what the reader should do about it, so `code` carries that
## distinction and `isUnknownToThisBuild` answers it, rather than the caller
## pattern-matching on a message.
##
## The second severity, `pdsNotice`, is for things that happened and were
## honoured: a nested package shadowing an ancestor's collection, a
## precedence tie broken by declaration order (§5.4 requires ties be
## *reported*), an executable-tier file sitting unread beside the declarative
## ones. A notice is not a failure and does not stop anything loading; it
## exists so that none of those is invisible.
##
## ## THE CODE IS SEPARATE FROM THE DETAIL
##
## `code` is what a caller may branch on; `detail` is what a reader needs.
## Verification-Harness-Traps §4b: a test asserting only "it refused" passes
## when the refusal was for the wrong reason, so every refusal in the suite is
## asserted by `code`.

import std/strutils

type
  ProjectDefinitionCode* = enum
    ## Why a project definition, or one entry in it, contributes nothing —
    ## plus the three notices at the end.
    ##
    ## Ordered by the phase that discovers it: size, syntax, schema, shape,
    ## vocabulary, containment, composition.

    # -- size, before anything is parsed ------------------------------------
    pdcFileTooLarge
      ## §2.2's "bounded evaluation", applied to the input itself. The bound
      ## is checked against the BYTE COUNT before the parser is entered, so a
      ## gigabyte of `[` is refused without being tokenised.
    pdcTooManyLines
      ## The same bound in the other unit. A file can be small in bytes and
      ## still be a million empty lines.

    # -- syntax --------------------------------------------------------------
    pdcMalformedToml
      ## `common/toml_subset` refused it. The detail carries that reader's own
      ## message, which names the line — including the array-nesting bound,
      ## which is where a nesting bomb lands.

    # -- schema --------------------------------------------------------------
    pdcMissingSchema
      ## No `schema` key. Refused rather than assumed to be the current
      ## version: a file that never said which format it is in cannot be
      ## honoured "partially" without guessing, and §6 forbids the guess.
    pdcUnknownSchemaVersion
      ## A `schema` this build does not implement — typically a FUTURE one.
      ## §6: "an unknown version reported rather than partially honoured — the
      ## rule `LayoutDecodeError` already establishes for saved layouts."
    pdcSchemaKindMismatch
      ## A well-known schema, in the wrong file: `visualisers.toml` declaring
      ## `codetracer.points.v1`. Refused rather than followed, because the
      ## trust gate applies PER FILE (§6) and a file that can redefine which
      ## concern it carries is a file the gate cannot be applied to.

    # -- shape ---------------------------------------------------------------
    pdcUnknownKey
      ## A key outside the closed set this table accepts. THE ABSENCE OF AN
      ## "unrecognised, ignored" ARM IS THE DELIVERABLE — see `parse.nim`'s
      ## header. Every key a project definition may write is enumerated, so a
      ## key naming a program, a path or an interpreter is not "refused", it
      ## is *not a key*, and this is what it produces.
    # THERE IS DELIBERATELY NO `pdcUnknownTable`. An earlier draft declared
    # one and nothing could produce it: a top-level table outside the closed
    # set is a KEY of the root table, and a nested one is a key of its parent,
    # so both land on `pdcUnknownKey` through one check. A code nothing can
    # raise is a claim about what can happen that is not true, and it would
    # have passed the suite's every-code sweep for ever.
    pdcWrongType
      ## The key exists and the value is the wrong TOML kind — an array where
      ## a string belongs.
    pdcMissingField
      ## A required key is absent from an entry.
    pdcTooManyEntries
      ## A bounded collection overflowed: too many collections, points, rules,
      ## hidden fields, scopes.
    pdcValueTooLong
      ## A bounded string overflowed.
    pdcDuplicateName
      ## Two collections in one file share a name. Refused rather than
      ## last-wins, because either could be the one the author meant.
    pdcEmptyCollection
      ## A named collection with no points. §4 makes a collection "a named set
      ## of point definitions"; an empty one is a name a user can enable that
      ## does nothing, which is `lpUnknownPane`'s blank surface with a label.

    # -- vocabulary (closed sets) --------------------------------------------
    pdcUnknownPointKind
    pdcUnknownMatchKind
    pdcUnknownPresentation
    pdcUnknownMediaType
    pdcUnknownDiffAlgorithm
    pdcBadTemplate
      ## A summary template with an unterminated or over-long placeholder, or
      ## more placeholders than the bound. Templating is total by
      ## construction (§2.2) and this is what "by construction" costs at the
      ## boundary.
    pdcBadNumber
      ## A bounded decimal that is not one.
    pdcAnchorMissing
      ## §4: a point located "by a stable location: path plus a resilient
      ## anchor, **not a bare line number**". A point carrying only `line` is
      ## refused here rather than accepted and silently mislocated after the
      ## first edit above it.

    # -- containment ---------------------------------------------------------
    pdcPathEscapesProject
      ## §2.2: "A definition may not name a file outside the project." The
      ## detail names the path AND which rule of the grammar it broke, because
      ## "bad path" over `..` and over `C:\` is two different fixes.
    pdcScopeEscapesProject
      ## The same rule applied to the package directory a nested
      ## `.codetracer/` was found in, so composition cannot smuggle in an
      ## escape the per-path check would catch.

    # -- provenance ----------------------------------------------------------
    pdcOriginMixed
      ## §6: "A user's own definitions are separate and not checked in, and
      ## never silently merged into the project's." A load presented as the
      ## PROJECT's set containing a file tagged `doUser` — or the reverse — is
      ## refused, so the separation is a checked property of the call rather
      ## than a convention of the caller.

    # -- notices (honoured, and reported anyway) -----------------------------
    pdnExecutableTierPresent
      ## An executable-tier file exists in this `.codetracer/`. It was NOT
      ## read, NOT parsed and NOT run — PLAT-13 owns the grant that would let
      ## anything happen to it, and PLAT-11 owns saying that it is there.
      ## Reported so "the project shipped a visualiser and I see nothing" has
      ## an answer other than silence.
    pdnUnrecognisedDefinitionFile
      ## A `.toml` file in a `.codetracer/` directory that is not one of the
      ## three declarative names. Almost always a typo — `point.toml` for
      ## `points.toml` — and without this it is the most invisible failure the
      ## whole feature has: the author's definitions simply never apply and
      ## nothing anywhere says why.
      ##
      ## SCOPED TO `.toml` ON PURPOSE. `<repo>/.codetracer/<name>.trace` is a
      ## RECORDING and shares this directory; reporting every file here would
      ## report every recording, and a report that fires constantly is one
      ## nobody reads (Verification-Harness-Traps §13a's false-positive
      ## argument, arriving in a user-facing surface).
    pdnCollectionShadowed
      ## §6's "a nested project inherits and may override, with the override
      ## rules stated rather than emergent". The override happened; this is
      ## the statement.
    pdnRuleTieReported
      ## §5.4: "ties broken by declaration order **and reported**".

  ProjectDefinitionSeverity* = enum
    pdsRefusal   ## the file, or the entry, contributes nothing
    pdsNotice    ## it was honoured, and a reader still needs to know

  ProjectDefinitionProblem* = object
    file*: string
      ## ALWAYS set, and repository-relative. See the header. For a problem
      ## found before any file could be identified there is
      ## `UnknownDefinitionFile`, because an error with no subject is the
      ## blank surface this module exists to refuse.
    line*: int
      ## 1-based, or 0 when the problem is about the file as a whole.
    code*: ProjectDefinitionCode
    detail*: string
      ## The specifics a reader needs. Never a restatement of `code`.

const
  UnknownDefinitionFile* = "<unnamed definition>"

func severityOf*(c: ProjectDefinitionCode): ProjectDefinitionSeverity =
  ## The four notices are LISTED and everything else is a refusal.
  ##
  ## So this is NOT total over the enum, and the `else` is the decision rather
  ## than an omission: a code added without being thought about becomes a
  ## REFUSAL, which stops the entry loading. Listing the refusals instead and
  ## defaulting to `pdsNotice` would make the next code the arm that stops
  ## nothing, and a definition that half-loaded because somebody forgot a
  ## `case` arm is the silent partial load §2.2's last bullet forbids.
  ##
  ## (The doc comment here used to claim totality, which the code has never
  ## had. Corrected 2026-09-11.)
  case c
  of pdnExecutableTierPresent, pdnUnrecognisedDefinitionFile,
     pdnCollectionShadowed, pdnRuleTieReported:
    pdsNotice
  else:
    pdsRefusal

func isUnknownToThisBuild*(c: ProjectDefinitionCode): bool =
  ## The `lpUnknownPane` question: was this file refused because it is WRONG,
  ## or because it is NEWER than this build?
  ##
  ## A function rather than a set literal at each call site for the usual
  ## reason (§14), and it is the predicate a user-facing report keys on: "this
  ## project needs a newer CodeTracer" and "this project's definition has a
  ## typo" are different sentences and only one of them is the user's problem.
  c in {pdcUnknownSchemaVersion, pdcUnknownKey,
        pdcUnknownPointKind, pdcUnknownMatchKind, pdcUnknownPresentation,
        pdcUnknownMediaType, pdcUnknownDiffAlgorithm}

func codeText*(c: ProjectDefinitionCode): string =
  ## The human half of the code. Written here rather than at each raise site
  ## so one code cannot acquire two spellings.
  case c
  of pdcFileTooLarge: "definition file is too large"
  of pdcTooManyLines: "definition file has too many lines"
  of pdcMalformedToml: "definition file is not readable"
  of pdcMissingSchema: "no schema declared"
  of pdcUnknownSchemaVersion: "schema version this build does not implement"
  of pdcSchemaKindMismatch: "schema belongs to a different definition file"
  of pdcUnknownKey: "unknown key"
  of pdcWrongType: "value has the wrong type"
  of pdcMissingField: "missing required field"
  of pdcTooManyEntries: "too many entries"
  of pdcValueTooLong: "value is too long"
  of pdcDuplicateName: "two collections share one name"
  of pdcEmptyCollection: "a named collection with no points"
  of pdcUnknownPointKind: "unknown point kind"
  of pdcUnknownMatchKind: "unknown match kind"
  of pdcUnknownPresentation: "unknown presentation"
  of pdcUnknownMediaType: "unknown media type"
  of pdcUnknownDiffAlgorithm: "unknown diff algorithm"
  of pdcBadTemplate: "malformed summary template"
  of pdcBadNumber: "malformed number"
  of pdcAnchorMissing: "a point located by line number alone"
  of pdcPathEscapesProject: "path outside the project"
  of pdcScopeEscapesProject: "package directory outside the project"
  of pdcOriginMixed: "a user definition in the project's set"
  of pdnExecutableTierPresent: "an executable definition is present and was not loaded"
  of pdnUnrecognisedDefinitionFile:
    "a .toml in .codetracer/ that is not a definition file this build reads"
  of pdnCollectionShadowed: "a collection was overridden by a nested definition"
  of pdnRuleTieReported: "two rules matched equally; declaration order decided"

func problem*(file: string; line: int; code: ProjectDefinitionCode;
              detail: string): ProjectDefinitionProblem =
  ProjectDefinitionProblem(file: file, line: line, code: code, detail: detail)

func render*(p: ProjectDefinitionProblem): string =
  ## THE FILE COMES FIRST. A reader scanning a column of these must be able to
  ## attribute every line without reading to the end of it.
  result = p.file
  if p.line > 0:
    result.add ":" & $p.line
  result.add ": " & codeText(p.code)
  if p.detail.len > 0:
    result.add ": " & p.detail

func renderAll*(problems: seq[ProjectDefinitionProblem]): string =
  var lines: seq[string] = @[]
  for p in problems:
    lines.add render(p)
  lines.join("\n")

func namesFile*(p: ProjectDefinitionProblem): bool =
  ## The property the suite sweeps for. A function rather than an assertion
  ## inside the test so that the *rule* and its *control* are one piece of
  ## code (§14): the suite proves it can answer `false` by handing it a
  ## problem whose `file` was left empty.
  p.file.len > 0 and render(p).contains(p.file)

func refusals*(problems: seq[ProjectDefinitionProblem]):
    seq[ProjectDefinitionProblem] =
  for p in problems:
    if severityOf(p.code) == pdsRefusal: result.add p

func notices*(problems: seq[ProjectDefinitionProblem]):
    seq[ProjectDefinitionProblem] =
  for p in problems:
    if severityOf(p.code) == pdsNotice: result.add p
