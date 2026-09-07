## value_presentation/vocabulary.nim — PLAT-2's slice of PLAT-3's abstract view
## vocabulary, plus the budget and the attribution a presentation carries.
##
## ## WHY A SLICE, AND WHY THESE FIVE
##
## PLAT-3 (`codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org`)
## declares a closed set of sixteen platform-agnostic views: `Text`, `Button`,
## `Checkbox`, `Toggle`, `Input`, `Select`, `List`, `Tree`, `Table`, `Tabs`,
## `Collapsible`, `Modal`, `Menu`, `ProgressIndicator`, `Image`, `Markdown`.
## PLAT-3 is not implemented. PLAT-2 needs `Presentation` expressed in that
## vocabulary *now*, so this module introduces the smallest subset a recorded
## VALUE can inhabit — and every entry below is one of PLAT-3's sixteen, spelled
## with a `pk` prefix. That is the property that makes PLAT-3 an EXTENSION of
## this file rather than a replacement of it: PLAT-3 adds the eleven entries this
## module does not name, and renames nothing.
##
## The eleven deliberately absent, with the reason:
##
##   `Button` `Checkbox` `Toggle` `Input` `Select` `Menu`  — interaction forms.
##       A value presentation has no actuation; the surface that embeds it does.
##   `Tabs` `Modal` `Collapsible`                          — container chrome.
##       `Tree` already carries expansion state, which is the only one of the
##       three a value needs; the other two are pane-level, not value-level.
##   `ProgressIndicator`                                    — no recorded value
##       is a progress.
##   `Markdown`                                             — see `pkImage`: the
##       media carrier below takes a MIME type, so `text/markdown` arrives
##       through it. PLAT-3 may split it out; nothing here has to change if it
##       does, because the MIME type is the discriminator either way.
##
## ## THE FIVE, EACH WITH WHAT MADE IT UNAVOIDABLE
##
##   `pkText`   Every scalar. Unavoidable: an `Int`, a `Bool` and a `String`
##              have exactly one medium-independent rendering, and every
##              surface has a text cell.
##   `pkList`   Positional containers — `Seq`, `Array`, `Set`, `Tuple`.
##              Unavoidable because the alternative is a string, and a string
##              has no elements, so no per-element visualiser (PLAT-12) can ever
##              attach to one.
##   `pkTree`   Named, expandable children — `Instance`, `Variant`, `Union`.
##              Unavoidable because PLAT-2's own budget example is "the state
##              panel holds a tree": a `Presentation` that cannot BE a tree
##              cannot express that budget.
##   `pkTable`  Key/value containers — `TableKind`. Separate from `pkTree`
##              because a tree's children are named by STRINGS and a map's keys
##              are VALUES: `{(1,2): "a"}` has no string label, and folding it
##              into a tree would either stringify the key (losing the key's own
##              presentation) or invent a label.
##   `pkImage`  Media, by MIME type. Not reachable from any recorded value
##              TODAY — no adapter in this repository produces it — and included
##              anyway, because Project-Definitions.md §5.2 makes "bytes +
##              `image/png`" the first row of the declarative visualiser table
##              PLAT-12 builds, and a presentation type that cannot carry it
##              would have to be replaced rather than extended. Its degradation
##              (what a one-line terminal surface shows instead of pixels) is
##              specified and tested here rather than in PLAT-12, because that
##              is the part PLAT-2's budget model owns.
##
## ## PURITY
##
## Everything in this package is `func`. Nim's `func` is `{.noSideEffect.}`, so
## a presenter that reads the CLOCK, the FILESYSTEM or a MODULE-LEVEL `var`
## fails to COMPILE — enforced by the compiler rather than by a scanner, which
## is the structural check PLAT-2 asks for.
##
## THE ENVIRONMENT IS NOT IN THAT LIST, and it used to be. `std/envvars.getEnv`
## carries `ReadEnvEffect` as a TAG rather than as a side effect, so
## `func f(s: string): string = s & getEnv("HOME")` compiles. Measured, not
## assumed. What keeps it out of this package is a different mechanism: the
## `FORBIDDEN_PIPELINE_IMPORTS` list in `ci/test/value-presentation-boundary.sh`
## names `envvars`, and that gate's contract suite
## (`ci/test/value-presentation-boundary-test.sh`) both plants the import and
## asserts the compiler's acceptance, so neither half of the claim rests on
## memory.
##
## That same gate carries the rest of what the compiler cannot see: a
## module-scope `let` initialised from a call at module load, a
## `{.cast(noSideEffect).}` escape, and a `proc` written where a `func` is
## required.

import std/[strutils, unicode]

type
  PresentationKind* = enum
    ## PLAT-2's slice of PLAT-3's vocabulary. See the header for the eleven
    ## entries deliberately absent and why each is.
    pkText   ## PLAT-3 `Text`
    pkList   ## PLAT-3 `List`
    pkTree   ## PLAT-3 `Tree`
    pkTable  ## PLAT-3 `Table`
    pkImage  ## PLAT-3 `Image`, generalised to any MIME type

  PresentationClass* = enum
    ## What the node IS, semantically — the thing a front-end maps onto a
    ## colour, a CSS class or a cell style.
    ##
    ## THE CLASS IS HERE AND THE COLOUR IS NOT, and that split is the whole
    ## reason this vocabulary can be shared. `cyan` is a terminal fact;
    ## `value-integer` is a DOM fact; "this is an integer" is neither.
    ## `src/frontend/tui/app/formatters/type_formatters.valueStyle` and the
    ## renderer's own class table both key on this enum.
    pcUnknown
    pcInteger
    pcHexLiteral   ## a `0x…` field element — a number written the other way
    pcFloat
    pcBoolean
    pcString
    pcChar
    pcEnum
    pcPointer
    pcRecord
    pcSequence
    pcTuple
    pcMap
    pcVariant
    pcByteBuffer
    pcFunction
    pcNone
    pcError
    pcOpaque
    pcMedia

  PresenterTier* = enum
    ## Project-Definitions.md §5.4's precedence, in order, most specific first:
    ## *in-program function -> project definition -> plugin -> built-in*.
    ##
    ## Only `ptBuiltin` has members today. The other three are declared because
    ## §5.4 states the order as a contract and because a resolution function
    ## that cannot NAME the tiers it does not yet have cannot report that the
    ## built-in won by default rather than by absence of competition.
    ptInProgram        ## a function in the recorded program (§5.1 mechanism 1)
    ptProjectDefinition## `.codetracer/` NatVis-derived rules (§5.1 mechanism 2)
    ptPlugin           ## an installed extension's contribution
    ptBuiltin          ## this repository's own kind-directed presenters

  Attribution* = object
    ## WHICH presenter rendered a value, and what else could have.
    ##
    ## PLAT-2 deliverable 4: "a user can ask which presenter rendered a value
    ## and get an answer". This object IS that answer, carried on every
    ## `Presentation` rather than logged — a debug log is not queryable from a
    ## pane, and Project-Definitions §5.4 says "a formatting layer that cannot
    ## explain itself becomes untrustworthy the first time it is wrong".
    tier*: PresenterTier
    presenter*: string     ## stable id, e.g. `builtin.sequence`
    matched*: string       ## what it matched on, e.g. `kind=pvkSequence`
    rank*: int             ## specificity within the tier; higher wins
    candidates*: seq[string]
      ## every presenter that matched, in the order precedence considered them,
      ## winner first. A single-element list means the winner won unopposed,
      ## which is a different fact from winning a contest and is worth being
      ## able to tell apart.

  Budget* = object
    ## What the SURFACE can hold. The presenter returns what fits; a surface
    ## never truncates afterwards.
    ##
    ## PLAT-2 deliverable 3, and the one the milestone brief names as most
    ## likely to be faked by leaving the old truncation in place beside a new
    ## budget parameter. The bans in
    ## `ci/test/value-presentation-boundary.sh` are what make that
    ## structurally impossible rather than merely discouraged.
    name*: string
      ## the surface's own name, e.g. `state-panel`. Carried so
      ## `describeAttribution` can say which budget produced the rendering —
      ## the same value at two budgets is two different byte strings, and a
      ## report that does not say which one it measured is ambiguous.
    lines*: int
      ## maximum lines. `1` means a single-line surface — a tracepoint line, a
      ## flow annotation, one row of a table. `0` means unbounded.
    cells*: int
      ## maximum display cells on ONE line, measured by `measure` below. `0`
      ## means unbounded.
    depth*: int
      ## how far into the value's structure to descend. `0` means scalar only.
    members*: int
      ## maximum children rendered per container before eliding. `0` means
      ## none — the container renders as its summary alone.
    expandable*: bool
      ## whether the surface can offer the reader the elided remainder. A state
      ## panel can; a tracepoint line cannot, and the difference changes what
      ## the presenter should spend its cells on.
    annotated*: bool
      ## whether the surface has room for the SECOND rendering of a number —
      ## `306 (0x132)`, `0x7d0 (2000)`.
      ##
      ## A budget field rather than a `focused: bool` threaded through every
      ## view, because "do I have room for the pair" is the same question every
      ## other field here answers. The TUI raises it for the row under the
      ## cursor (CodeTracer-TUI.md §3.3.4's "decimal and hexadecimal
      ## simultaneously upon focus"); no other surface raises it today, which
      ## is why the same value reads `306` in a tracepoint line and
      ## `306 (0x132)` on a focused TUI row — a budget difference, which is the
      ## only difference PLAT-2 permits between surfaces.

  PresentationMeasure* = proc (s: string): int {.noSideEffect, gcsafe, raises: [].}
    ## How WIDE a string is on the consuming surface.
    ##
    ## A parameter rather than a constant because the answer is
    ## medium-specific and the truncation is not: the terminal measures CELLS
    ## (a wide glyph is two, and a pane whose value column overflows by one
    ## corrupts every column after it), the DOM measures characters. Making it
    ## a parameter is what lets the *truncation* stay in the presenter — which
    ## is the deliverable — while staying accurate on both.
    ##
    ## `{.noSideEffect.}` is part of the type: a measure that read the clock
    ## would make every presentation impure through the back door, and this is
    ## the only proc value the pipeline accepts.

  PresentationContext* = object
    ## Everything a presentation depends on, other than the value.
    ##
    ## THE LANGUAGE IS IN HERE AND NOT IN A GLOBAL, and that is a correction
    ## rather than a preference. `common_types/utils/text_representation.textRepr`
    ## reads `common_lang.CURRENT_LANG` — a module-level `var` — whenever it is
    ## called without an explicit `lang`, which is nearly always. So the same
    ## value rendered before and after a session switch produced different
    ## bytes with no argument having changed. That is precisely the impurity
    ## PLAT-2's "byte-identical across runs and across front-ends" forbids.
    lang*: PresentationLang
    budget*: Budget
    measure*: PresentationMeasure

  PresentationLang* = enum
    ## The recording's language, as far as PRESENTATION is concerned.
    ##
    ## Deliberately not `common/lang.Lang`: this package imports nothing but
    ## `std/strutils` and `std/unicode`, and `lang.nim` is a large module on the
    ## far side of `common_types`. The bridge maps one onto the other.
    plUnknown
    plRust    ## `vec![…]`, `Type { field: … }` — the one language whose
              ## rendering genuinely differs today
    plOther

  PresentationNode* = ref object
    ## One node of a presentation. Every node carries `text` — its own
    ## single-line rendering — WHATEVER its kind, which is what makes the
    ## migration of a one-line surface a one-line change: a tracepoint reads
    ## `p.root.text` and a state panel walks `p.root.children`.
    label*: string        ## the node's name in its parent; "" when positional
    typeName*: string     ## the language type name, verbatim; "" when unknown
    kind*: PresentationKind
    class*: PresentationClass
    text*: string         ## the node's own one-line rendering, already budgeted
    children*: seq[PresentationNode]
    keys*: seq[PresentationNode]
      ## `pkTable` only, parallel to `children`: the key half of each row. A
      ## key is a PRESENTATION and not a string, because a map key can be a
      ## record and stringifying it here would throw away the only structure a
      ## per-type visualiser could attach to.
    elided*: int          ## members the budget dropped
    totalMembers*: int    ## members the value has, whether rendered or not
    expandable*: bool     ## whether this node has children a surface may open
    mediaType*: string    ## `pkImage` only
    mediaBytes*: int      ## `pkImage` only

  Presentation* = object
    ## The pipeline's output. One type, every surface.
    root*: PresentationNode
    attribution*: Attribution
    budget*: Budget
    truncated*: bool
      ## whether ANYTHING was dropped anywhere in the tree — text clipped,
      ## members elided, depth cut. A surface uses it to decide whether to
      ## offer "more"; a test uses it to assert that a budget bit.

const
  Ellipsis* = "…"
    ## One display cell wide, so a clipped field's width is still its cell
    ## count. The same constant the TUI's formatters used before this package
    ## existed.

func defaultMeasure*(s: string): int {.gcsafe, raises: [].} =
  ## Runes, not bytes. The fallback when a surface declares no measure of its
  ## own — correct for the DOM, and correct for the terminal for everything but
  ## wide glyphs, which is why the terminal supplies its own.
  try:
    result = s.runeLen
  except CatchableError:
    # `runeLen` cannot raise on a valid string; the handler exists so this proc
    # can carry `raises: []` and therefore satisfy `PresentationMeasure`.
    result = s.len

func measureOf*(ctx: PresentationContext; s: string): int =
  ## `ctx.measure` applied to `s`, or `defaultMeasure` when the context carries
  ## none. Every width question in this package goes through here, so a nil
  ## measure degrades to a defensible answer instead of crashing a pane.
  if ctx.measure.isNil: defaultMeasure(s) else: ctx.measure(s)

func clipToCells*(ctx: PresentationContext; s: string; cells: int): tuple[text: string, clipped: bool] =
  ## `s` reduced to at most `cells` display cells, ending in `…` when anything
  ## was dropped.
  ##
  ## BOUNDED BY `cells`, NEVER BY THE LENGTH OF `s`: the walk stops as soon as
  ## one more cell would overflow, so clipping a 12 KB member list to twenty
  ## columns costs twenty runes rather than measuring twelve thousand. That is
  ## the property `type_formatters.truncateValue` was rewritten for on
  ## 2026-09-06 (11 ms -> 4.3 ms painting a 24-row pane against a 15 ms gate),
  ## and it is preserved here rather than rediscovered.
  if cells <= 0:
    return (s, false)
  var used = 0
  var fits = true
  var cut = 0
  for r in runes(s):
    let piece = $r
    let w = max(1, measureOf(ctx, piece))
    if used + w > cells:
      fits = false
      break
    used += w
    cut += piece.len
  if fits:
    return (s, false)
  # THE ELLIPSIS IS MEASURED, NOT ASSUMED TO BE ONE CELL.
  #
  # It is one cell on a terminal, which is why the TUI's own truncator wrote
  # `cells - 1`. But the measure is a PARAMETER, and a surface whose measure
  # says `…` is three (a byte count) or six (a proportional-font estimate) would
  # get back a string wider than the budget it declared — the one thing this
  # function exists to prevent. Caught by
  # `value_presentation_test`'s custom-measure case, which asserted the budget
  # in the caller's own units and found 14 where it had asked for 10.
  let ellipsisWidth = max(1, measureOf(ctx, Ellipsis))
  if cells <= ellipsisWidth:
    return (Ellipsis, true)
  var kept = 0
  var keptBytes = 0
  for r in runes(s):
    let piece = $r
    let w = max(1, measureOf(ctx, piece))
    if kept + w > cells - ellipsisWidth:
      break
    kept += w
    keptBytes += piece.len
  (s[0 ..< keptBytes] & Ellipsis, true)

func describeAttribution*(p: Presentation): string =
  ## PLAT-2 deliverable 4, rendered.
  ##
  ## A single line naming the winning presenter, its tier, what it matched, the
  ## budget it rendered under, and — when there was one — the contest it won.
  ## Written as one line on purpose: it has to fit the surfaces it describes,
  ## including a tracepoint's.
  var parts: seq[string] = @[]
  parts.add p.attribution.presenter
  parts.add "tier=" & (case p.attribution.tier
    of ptInProgram: "in-program"
    of ptProjectDefinition: "project-definition"
    of ptPlugin: "plugin"
    of ptBuiltin: "builtin")
  if p.attribution.matched.len > 0:
    parts.add "matched=" & p.attribution.matched
  parts.add "budget=" & (if p.budget.name.len > 0: p.budget.name else: "unnamed")
  if p.attribution.candidates.len > 1:
    parts.add "over=" & p.attribution.candidates[1 .. ^1].join(",")
  else:
    parts.add "unopposed"
  if p.truncated:
    parts.add "truncated"
  parts.join(" ")
