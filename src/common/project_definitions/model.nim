## project_definitions/model.nim — PLAT-11. What a declarative project
## definition IS, once it has been read.
##
## ## EVERY FIELD IS DATA, AND THE ABSENCES ARE THE DESIGN
##
## Project-Definitions.md §2.2 asks that the declarative tier be "incapable of
## harm". The usual way to write that down is a list of things the loader
## refuses to do. This module writes it down the other way: there is no field
## anywhere below that names a program, a path to something loadable, an
## interpreter, a command, a shell, a URL, or a callable of any kind. A rule
## that could name one is not "refused", it is unrepresentable — `parse.nim`
## has nowhere to put it and the closed key set has no key for it.
##
## The two places a reader would look for such a field, and what is there
## instead:
##
##   * a visualiser (§5) carries a MATCH, a SUMMARY TEMPLATE, a set of hidden
##     field names, a presentation kind from PLAT-3's closed vocabulary and an
##     optional media type from a closed list. §5.1's mechanism 3 — an
##     executable visualiser — has no representation here at all; it is
##     PLAT-13's, in a separate file, behind a grant.
##   * a scratchpad diff (§7) carries a SELECTION from the algorithms
##     CodeTracer itself ships. A project chooses; it cannot supply. Supplying
##     one is §7's executable tier, which is PLAT-13's.
##
## ## MATCHING IS TOTAL BY CONSTRUCTION
##
## §2.2: "A declarative rule that can loop is not declarative. Matching and
## templating are total and terminate by construction."
##
## `MatchKind` has three members and all three are O(len) string comparisons.
## There is deliberately no regular expression: a regex over
## attacker-controlled input is unbounded work (the catastrophic-backtracking
## family), and "bounded" would then mean a step budget, a timeout and a
## partial answer — three mechanisms to replace one that does not need them.
## A project that genuinely needs a regex needs §5.1 mechanism 1 or 3, both of
## which are somewhere else.

import ./diagnostics
import ./layout
import ../value_presentation/vocabulary as presentation_vocabulary

# THE RE-EXPORT IS NARROW, AND THE NARROWNESS IS DELIBERATE. A project
# definition names a presentation (`present = "Table"`), so it needs the enum,
# the spelling and the five a VALUE can inhabit. It does not need `Budget`,
# `Presentation`, `PresentationNode` or the measure — a definition DECLARES a
# presentation, it does not build one, and PLAT-12 is where those meet.
export presentation_vocabulary.PresentationKind
export presentation_vocabulary.ValuePresentationKinds
export presentation_vocabulary.presentationSpelling
export presentation_vocabulary.PresenterTier

# §5.2's closed media list, DERIVED from the renderer's `MediaClass` rather
# than written out a second time here. `parse.DeclarativeMediaTypes` is this
# call; see the note there for what the two literals used to be and what went
# wrong between them.
export presentation_vocabulary.declarableMediaTypes

# PLAT-12 MOVED `MatchKind` AND ITS PREDICATE DOWN, and nothing else about this
# module changed. The three match kinds and the comparison over them are now
# `value_presentation/vocabulary`'s, because `presenter.resolve` has to
# evaluate them and cannot see this package — the pipeline's whole import
# closure is two `std` modules. `MatchKind` below is an alias, `matches`
# forwards, and there is exactly one implementation of "does this rule match
# this type" in the tree (Verification-Harness-Traps §14).
#
# Exporting the TYPE is what carries `mkTypeName`, `mkTypePrefix` and
# `mkTypeSuffix` with it — Nim refuses an enum field exported on its own, and
# the refusal is the language saying what this alias already claims: the fields
# belong to the type and the type is one type.
export presentation_vocabulary.ValueMatchKind
export presentation_vocabulary.typeMatches

type
  PointKind* = enum
    ## §4's two. Spelled as the user-facing words, because the same strings
    ## are what a definition file writes and what an error message prints.
    pkTracepoint = "tracepoint"
    pkBreakpoint = "breakpoint"

  PointAnchor* = object
    ## §4: "each identified by a stable location: path plus a resilient
    ## anchor, not a bare line number, so an edit above the point does not
    ## silently move it."
    ##
    ## THE ANCHOR IS REQUIRED AND THE LINE IS A HINT. That asymmetry is the
    ## deliverable: `text` + `occurrence` is what LOCATES the point, and
    ## `line` exists only so re-resolution can tell `prResolved` from
    ## `prMoved`. A point carrying `line` and no `text` is refused
    ## (`pdcAnchorMissing`) rather than accepted as a bare line number.
    text*: string
      ## A substring of the anchoring line, as written in the file. Compared
      ## by containment on the STRIPPED line, so leading indentation changing
      ## does not unresolve a point.
    occurrence*: int
      ## Which match, 1-based. `proc handle` may appear four times; an anchor
      ## that silently took the first would move the point on the day someone
      ## added a fifth above it.
    offset*: int
      ## Lines BELOW the anchor line. 0 means the anchor line itself. Bounded,
      ## non-negative: a negative offset would let a point sit above its own
      ## anchor, which makes "did it move" undecidable.
    line*: int
      ## The line the author last saw it at, or 0 if they did not record one.
      ## A HINT, never a locator. See above.

  PointDefinition* = object
    kind*: PointKind
    path*: string
      ## Repository-relative, already through `containment.pathProblem`, and
      ## already joined with the defining file's `scope` so a nested
      ## definition's path is expressed the same way a root one's is.
    anchor*: PointAnchor
    expression*: string
      ## §4: "Tracepoint *expressions* in a collection are the same
      ## expressions a user could type; this is data, not code, and it does
      ## not cross into the executable tier."
      ##
      ## It is stored as TEXT and this package never evaluates it. The thing
      ## that eventually does is the same evaluator a user's typed expression
      ## goes to — which is the point: a definition can express what a user
      ## could express, and nothing more.
    label*: string

  PointCollection* = object
    ## §4: "A collection is a **named set of point definitions**."
    name*: string
    enabledByDefault*: bool
      ## §4: collections "may be enabled and disabled as a unit, and several
      ## may be active at once". The definition states the default; the
      ## user's own toggle is session state and is not this file's business.
    origin*: DefinitionOrigin
    scope*: string
      ## Which package's `.codetracer/` declared it. Carried so an override
      ## can be REPORTED with both sides named (§6).
    file*: string
    points*: seq[PointDefinition]

  MatchKind* = ValueMatchKind
    ## The three total predicates. See this module's header for why there is
    ## no fourth, and `value_presentation/vocabulary.ValueMatchKind` for why
    ## they are declared there rather than here.
    ##
    ## AN ALIAS AND NOT A COPY. `mkTypeName` is the same symbol both packages
    ## name, `$mkTypeName` is still `"typeName"` — which is what
    ## `parse.matchKindByName` reads and what an error message prints — and
    ## `ord(high(MatchKind)) + 1` is still 3, which is the assertion that keeps
    ## a fourth kind from arriving without the argument for it.

  VisualiserRule* = object
    ## §5.3: "what it matches", "how it presents", "what it hides".
    match*: string
    matchKind*: MatchKind
    language*: string
      ## Optional. Compared by exact equality against the recording's language
      ## name; empty means "any language". A bounded identifier, never a path
      ## and never a lookup key for a file.
    summary*: string
      ## A template over the value's FIELD NAMES: `"{rows}x{cols}"`. Validated
      ## at parse time for balanced, bounded, non-nested placeholders, so
      ## substitution is one linear pass with no re-scan of what it
      ## substituted. Nothing it produces is ever evaluated.
    hide*: seq[string]
      ## §5.3: "often the single most valuable thing a visualiser does".
    present*: PresentationKind
      ## Constrained to `ValuePresentationKinds` at parse time — the five a
      ## recorded value can inhabit, named by
      ## `value_presentation/vocabulary`. PLAT-12 renders it; PLAT-11 reads it.
    presentDeclared*: bool
      ## Whether `present` was WRITTEN or is the zero value.
      ##
      ## ADDED BY PLAT-12, AND THE ABSENCE WAS A REAL AMBIGUITY RATHER THAN AN
      ## OMISSION. `pkText` is both the first member of the enum and a
      ## legitimate declaration (`present = "Text"` is how a project flattens a
      ## record to one line), so a renderer reading `present` alone cannot tell
      ## "the project asked for text" from "the project said nothing" — and the
      ## second must leave the value's own shape alone. Reading it wrongly
      ## turns every matched record into a leaf, which is a silent loss of the
      ## tree beside it.
      ##
      ## The field is `false` for every rule that does not write `present`, so
      ## a definition file that predates this field parses to exactly what it
      ## parsed to before.
    mediaType*: string
      ## §5.2: "a rule may declare that a region of a value is media of a
      ## stated MIME type". From a closed list; see `parse.nim`.
    mediaFrom*: string
      ## Which field of the value holds the bytes. A FIELD NAME, bounded, from
      ## the value itself — never a filename.
    origin*: DefinitionOrigin
    scope*: string
    file*: string
    order*: int
      ## Declaration order within its file. §5.4 breaks ties by it AND
      ## reports them, so it has to survive into the model.

  DiffAlgorithm* = enum
    ## §7's declarative half: the comparisons CodeTracer ITSELF ships, which a
    ## project may SELECT.
    ##
    ## A project supplying its own is §7's executable tier and is PLAT-13's:
    ## it is "executable by nature", needs the total-and-bounded guarantee the
    ## host imposes, and has no representation in this enum. That is the
    ## whole shape of the declarative/executable split applied to one feature
    ## — selecting from a closed set is data, and supplying a comparison is
    ## code.
    daStructural = "structural"
      ## The default, and what the scratchpad does today.
    daNumericTolerance = "numeric-tolerance"
      ## §7's "two matrices differ by tolerance". Needs `tolerance`.
    daUnorderedSet = "unordered-set"
      ## §7's "two graphs by isomorphism rather than by node order", in the
      ## form that is decidable in linear time: compare as multisets.
    daTextLines = "text-lines"
      ## Line-oriented rather than structural, for a value that is a document.

  DiffSelection* = object
    match*: string
    matchKind*: MatchKind
    algorithm*: DiffAlgorithm
    tolerance*: string
      ## As WRITTEN, validated against a bounded decimal grammar. Kept as text
      ## rather than a float because the definition is data and the consumer
      ## decides the precision it wants; and because a float here would mean a
      ## parse that can raise inside a loader whose every other refusal is a
      ## value.
    origin*: DefinitionOrigin
    scope*: string
    file*: string
    order*: int

  ProjectDefinitions* = object
    ## Everything one load produced. §6's separation is STRUCTURAL: the
    ## project's records and the user's are two fields, and there is no
    ## function anywhere that returns them concatenated without the
    ## `origin` tag that says which is which.
    collections*: seq[PointCollection]
    visualisers*: seq[VisualiserRule]
    diffs*: seq[DiffSelection]

  LoadedProjectDefinitions* = object
    ## The result of reading a checkout's definitions, and the user's.
    ##
    ## `problems` holds BOTH refusals and notices; `diagnostics.refusals` and
    ## `.notices` split them. A caller that ignores the whole list gets a
    ## `project` containing exactly the entries that were well formed — never
    ## a silently partial one, because every entry that was dropped is a
    ## refusal in this list naming the file and the line.
    project*: ProjectDefinitions
    user*: ProjectDefinitions
    problems*: seq[ProjectDefinitionProblem]

const
  PresenterTierOfProjectDefinition* = ptProjectDefinition
    ## §5.4's precedence: *in-program function -> project definition -> plugin
    ## -> built-in*. The tier is `value_presentation/vocabulary`'s, named here
    ## rather than re-declared, so PLAT-12 resolving a visualiser and PLAT-2
    ## reporting the attribution are talking about one value.

func isOk*(l: LoadedProjectDefinitions): bool =
  ## Whether anything was REFUSED. Notices do not make a load not-ok — an
  ## executable-tier file sitting unread is the system working.
  for p in l.problems:
    if severityOf(p.code) == pdsRefusal: return false
  true

func matches*(rule: VisualiserRule; typeName, language: string): bool =
  ## TOTAL, and bounded by `typeName.len`. The one implementation of §5.3's
  ## matching: PLAT-12 calls it, the suite calls it, and there is no second
  ## copy for the two to disagree over (Verification-Harness-Traps §14).
  ##
  ## THE BODY MOVED DOWN IN PLAT-12 AND WAS NOT COPIED. It is
  ## `value_presentation/vocabulary.typeMatches`, because `presenter.resolve`
  ## has to ask the same question of a `Visualiser` and cannot see this type.
  ## This function is now the adapter from a `VisualiserRule`'s four fields to
  ## that predicate's four parameters and contains no comparison of its own —
  ## which is what makes "the grammar and the renderer agree about what a rule
  ## matches" structural rather than a claim about two similar-looking `case`
  ## statements.
  typeMatches(rule.matchKind, rule.match, rule.language, typeName, language)

func specificity*(rule: VisualiserRule): int =
  ## §5.4: "within a tier the more specific match wins".
  ##
  ## An exact type name is more specific than an affix, a longer affix more
  ## specific than a shorter one, and a language-qualified rule more specific
  ## than an unqualified one. Expressed as a NUMBER rather than as a
  ## comparison function so a tie is a visible equality — which is what §5.4's
  ## "ties broken by declaration order and reported" needs to be able to
  ## detect at all.
  result = rule.match.len
  if rule.matchKind == mkTypeName: result += 1000
  if rule.language.len > 0: result += 1

func declaresMedia*(rule: VisualiserRule): bool =
  rule.mediaType.len > 0

func pointPath*(p: PointDefinition): string =
  ## The repository-relative path, which is what `path` already is. A named
  ## accessor rather than a field read because `parse.nim` is the only place
  ## the scope join happens (`containment.joinContained`) and a reader looking
  ## for "is this relative to the package or to the repo" should find the
  ## answer rather than infer it.
  p.path
