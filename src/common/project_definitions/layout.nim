## project_definitions/layout.nim — PLAT-11 deliverable 1. What `.codetracer/`
## contains, split by concern so the trust gate applies to a FILE.
##
## Project-Definitions.md §6:
##
##   "**Split by concern, not one large file**: point collections, visualisers
##    and executable definitions are separate files with separate schemas, so
##    the trust gate can apply to a file rather than to a section of one."
##
## ## THE FILE SET IS A CONSTANT, AND THAT IS THE WHOLE SECURITY ARGUMENT
##
## `DefinitionFileKind` is a closed enum and `definitionFileName` maps it to a
## fixed name. Nothing in this package ever derives a filename from the
## CONTENTS of a definition — there is no `include`, no `extends`, no
## `natvisFile`, no `visualiser = "./render.so"`. A reader of `.codetracer/`
## opens the names below and no others.
##
## That is what makes §2's rule structural rather than enforced. "Cloning a
## repository and opening it in CodeTracer must not execute code from that
## repository" is usually attacked by getting the host to *resolve* something
## and then *run* it, and both halves need the repository to be able to name a
## target. Here it cannot name one: the only strings that reach a filesystem
## call are these five constants.
##
## ## THE NAME COLLISION, NAMED RATHER THAN LEFT TO BE FOUND
##
## `.codetracer/` already means two other things in this tree, and neither is
## this one:
##
##   * `$CODETRACER_USER_ROOT` or `$HOME/.codetracer` — the LAUNCHER's user
##     root, holding `registry/v1/`, `components/v1/` and PLAT-10's
##     `grants/v1/grants.tsv`. That is a per-USER directory in the home
##     directory; this is a per-PROJECT directory in a checkout.
##   * `<repo>/.codetracer/<name>.trace` — a recording, as the test-explorer
##     suites spell it. That IS the same directory as this one, and the two
##     coexist precisely because the file set here is a constant: a `.trace`
##     file is not one of the five names below, so it is neither read nor
##     reported, and a definition file is not a recording.
##
## §6's "a user's own definitions are separate and not checked in" is
## `DefinitionOrigin`, below, and it is carried on every record rather than
## being a property of which call produced it.

import ./diagnostics

type
  DefinitionFileKind* = enum
    ## The concerns, one per file. Adding a sixth is deliberately a change to
    ## this enum — which forces a tier, a schema id and a name, and makes the
    ## trust question unavoidable rather than defaulted.
    dfkPoints        ## §4 — named collections of tracepoints and breakpoints
    dfkVisualisers   ## §5 — per-type visualiser DECLARATIONS
    dfkScratchpad    ## §7 — which comparison the scratchpad should use
    dfkVisualiserCode
      ## §5.1 mechanism 3 / §6 — EXECUTABLE visualisers. PLAT-13's file. This
      ## build knows the NAME so that finding one can be reported; it has no
      ## reader for it, no loader for it and no way to run it.
    dfkDiffCode
      ## §7 — EXECUTABLE scratchpad diff algorithms. PLAT-13's file, for the
      ## same reason.

  DefinitionTier* = enum
    ## §2.1's two tiers. The boundary between them is the point, so it is a
    ## property of the FILE KIND, decided here, once.
    dtDeclarative
      ## Data. Loads automatically, always, with no prompt, because it is
      ## incapable of harm (§2.2).
    dtExecutable
      ## Code. Loads only after an explicit, per-repository trust grant — and
      ## this build has no such grant and no loader, so in this build it does
      ## not load at all.

  DefinitionOrigin* = enum
    ## §6: "A user's own definitions are separate and not checked in, and
    ## never silently merged into the project's — otherwise a user's local
    ## experiment becomes a diff."
    ##
    ## Carried on every record rather than inferred from which call produced
    ## it, so a consumer that merges the two lists still knows which entry
    ## came from where, and `load` can refuse a set that mixes them.
    doProject   ## from a `.codetracer/` inside the checkout, under version control
    doUser      ## from the user's own directory, outside the checkout

  DefinitionFile* = object
    ## ONE DEFINITION FILE, AS TEXT.
    ##
    ## The loader is handed bytes somebody else read. That is what makes
    ## "**no** I/O, network, process or filesystem access" (PLAT-11
    ## deliverable 3) a property of the TYPE rather than a promise in a
    ## comment: there is no field here a filesystem call could be made from,
    ## and `project_definitions_test` asserts this package's entire import
    ## closure to keep it that way.
    kind*: DefinitionFileKind
    origin*: DefinitionOrigin
    scope*: string
      ## The package directory this `.codetracer/` sits in, relative to the
      ## repository root. Empty for the root one. §6's composition: "a
      ## monorepo has definitions per package". Checked against
      ## `containment.pathProblem` like any other path, so a nested definition
      ## cannot be reached from outside the checkout either.
    path*: string
      ## Where it came from, for the diagnostics. NEVER used to open anything
      ## — the reader's file set is the constants below — and never used as an
      ## identity.
    text*: string

const
  ProjectDefinitionDir* = ".codetracer"
    ## The directory, in the project root. §6.

  MaxDefinitionBytes* = 64 * 1024
    ## §2.2's bounded evaluation, applied to the input. Checked against the
    ## byte count BEFORE the parser is entered, so a nesting bomb is refused
    ## without being tokenised. A real definition is a few kilobytes; the
    ## largest thing anyone would legitimately write is a long list of hidden
    ## fields.

  MaxDefinitionLines* = 2_000
    ## The same bound in the other unit, because a file can be small in bytes
    ## and still be an enormous number of empty lines — which costs the line
    ## counter in `fail` a full scan per diagnostic.

  MaxCollections* = 64
  MaxPointsPerCollection* = 256
  MaxVisualiserRules* = 256
  MaxDiffSelections* = 64
  MaxHiddenFields* = 64
  MaxDefinitionScopes* = 64
    ## A monorepo with more than 64 packages carrying their own definitions is
    ## not refused as a repository — this bounds what ONE load may compose, so
    ## the merge is bounded by a constant rather than by a directory walk.

  MaxNameBytes* = 120
  MaxAnchorBytes* = 200
  MaxExpressionBytes* = 400
  MaxTypeMatchBytes* = 200
  MaxFieldNameBytes* = 80
  MaxSummaryBytes* = 200
  MaxTemplatePlaceholders* = 16
  MaxNumberBytes* = 24

func tierOf*(k: DefinitionFileKind): DefinitionTier =
  ## TOTAL over the enum. A `case` with an `else` would give the next file
  ## kind the declarative tier by default, and the default that loads without
  ## asking is the wrong side to fail towards.
  case k
  of dfkPoints, dfkVisualisers, dfkScratchpad: dtDeclarative
  of dfkVisualiserCode, dfkDiffCode: dtExecutable

func definitionFileName*(k: DefinitionFileKind): string =
  ## The name inside `.codetracer/`. A CONSTANT per kind — see the header.
  case k
  of dfkPoints: "points.toml"
  of dfkVisualisers: "visualisers.toml"
  of dfkScratchpad: "scratchpad.toml"
  of dfkVisualiserCode: "visualisers.wasm"
  of dfkDiffCode: "diffs.wasm"

func schemaOf*(k: DefinitionFileKind): string =
  ## The schema id THIS BUILD implements for that file.
  ##
  ## The version is in the id rather than in a separate `version` key on
  ## purpose: it makes "which format is this" a single string comparison with
  ## no arithmetic, so there is no `>=` anywhere for a future version to be
  ## silently accepted by. §6's rule is that an unknown version is *reported*,
  ## never partially honoured, and the cheapest way to make partial honouring
  ## impossible is to have no ordering to be lenient with.
  case k
  of dfkPoints: "codetracer.points.v1"
  of dfkVisualisers: "codetracer.visualisers.v1"
  of dfkScratchpad: "codetracer.scratchpad.v1"
  of dfkVisualiserCode: "codetracer.visualiser-code.v1"
  of dfkDiffCode: "codetracer.diff-code.v1"

func declarativeKinds*(): seq[DefinitionFileKind] =
  ## DERIVED from `tierOf` rather than listed, so the two cannot disagree.
  for k in DefinitionFileKind:
    if tierOf(k) == dtDeclarative: result.add k

func executableKinds*(): seq[DefinitionFileKind] =
  for k in DefinitionFileKind:
    if tierOf(k) == dtExecutable: result.add k

func kindForSchema*(schema: string; dest: var DefinitionFileKind): bool =
  ## Which file kind claims this schema id. DERIVED from `schemaOf` by a fold
  ## over the enum, so a new kind is recognised the day it is added and never
  ## a day before.
  for k in DefinitionFileKind:
    if schemaOf(k) == schema:
      dest = k
      return true
  false

func knownSchemas*(): seq[string] =
  for k in DefinitionFileKind:
    result.add schemaOf(k)

func definitionPath*(scope: string; k: DefinitionFileKind): string =
  ## Where a file of this kind lives, relative to the repository root.
  if scope.len == 0: ProjectDefinitionDir & "/" & definitionFileName(k)
  else: scope & "/" & ProjectDefinitionDir & "/" & definitionFileName(k)

func executableTierNotice*(file: DefinitionFile): ProjectDefinitionProblem =
  ## What a reader is told about an executable-tier file this build found.
  ##
  ## A NOTICE rather than a refusal, because nothing failed: the declarative
  ## tier beside it loaded, the debugger opened, and the only thing that did
  ## not happen is the thing §2 says must not happen without a grant. It is
  ## reported at all so that "this project ships a visualiser and I see
  ## nothing" has an answer.
  problem(file.path, 0, pdnExecutableTierPresent,
    "'" & definitionFileName(file.kind) & "' is an executable-tier " &
    "definition. It was not read, not parsed and not run: the executable " &
    "tier loads only behind an explicit, per-repository trust grant " &
    "(Project-Definitions.md §2.3), and this build implements no such grant " &
    "and no loader for it. The declarative definitions beside it loaded " &
    "normally")
