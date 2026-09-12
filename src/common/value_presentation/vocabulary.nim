## value_presentation/vocabulary.nim — PLAT-3's abstract view vocabulary (the
## closed set of sixteen), plus the budget and the attribution a presentation
## carries.
##
## ## WHAT PLAT-3 CHANGED HERE, AND WHAT IT DID NOT
##
## PLAT-2 introduced FIVE of PLAT-3's sixteen entries under PLAT-3's own names
## and wrote, in this header, that "PLAT-3 adds the eleven entries this module
## does not name, and renames nothing". That is what happened, on 2026-09-07:
## the eleven are now in `PresentationKind` beside the five, nothing was
## renamed, and no second `Text` exists anywhere in the tree.
##
## What did NOT change is the PRESENTER'S range. `present` still returns only
## the five a recorded VALUE can inhabit; the eleven are reachable only by a
## VIEW (`common/view_vocabulary/`). `value_presentation_test`'s "the
## presenter's range is still PLAT-2's five" case asserts that over every
## `PValueKind`, so the widening of the enum is not a widening of what a value
## becomes. The reasons the eleven are not value shapes are unchanged and are
## kept here because they are the reasons that case exists:
##
##   `Button` `Checkbox` `Toggle` `Input` `Select` `Menu`  — interaction forms.
##       A value presentation has no actuation; the surface that embeds it does.
##   `Tabs` `Modal` `Collapsible`                          — container chrome.
##       `Tree` already carries expansion state, which is the only one of the
##       three a value needs; the other two are pane-level, not value-level.
##   `ProgressIndicator`                                    — no recorded value
##       is a progress.
##   `Markdown`                                             — a value carrying
##       `text/markdown` arrives through `pkImage`'s MIME type. PLAT-3 splits
##       `Markdown` out as a VIEW (a rendered document with its own structure),
##       which is a different question from how a value announces its media
##       type, and nothing here had to change for it.
##
## ## THE FIVE A VALUE CAN INHABIT, EACH WITH WHAT MADE IT UNAVOIDABLE
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
    ## PLAT-3's abstract view vocabulary — the closed set of sixteen.
    ##
    ## PLAT-2 declared five of them and wrote, in this file's header, that
    ## "PLAT-3 adds the eleven entries this module does not name, and renames
    ## nothing". PLAT-3 did exactly that: the eleven are below, in the enum
    ## PLAT-2 opened, so there is ONE spelling of `Text` in the tree and the
    ## extension is an extension rather than a second vocabulary. The header's
    ## "why these five" section is preserved verbatim above, because it still
    ## records why the five a VALUE can inhabit are those five.
    ##
    ## THE ENUM IS THE VOCABULARY; THE NODE TYPE IS NOT. A `Presentation` and a
    ## `ViewNode` (`common/view_vocabulary/`) are different objects carrying
    ## different state and they share this enum, which is what lets PLAT-12
    ## template a value into a view without a translation table between two
    ## enumerations that would drift.
    ##
    ## THE PRESENTER'S RANGE IS STILL THE FIVE. `presenter.present` cannot
    ## return any of the eleven — a recorded value has no actuation — and
    ## `value_presentation_test`'s "the presenter's range is still PLAT-2's
    ## five" case asserts it over every `PValueKind`, so extending the enum did
    ## not widen what a value can become.
    ##
    ## `common/view_vocabulary/vocabulary.nim` re-exports this type as
    ## `ViewKind` and specifies each entry by behaviour and state.
    pkText             ## PLAT-3 `Text`
    pkButton           ## PLAT-3 `Button`
    pkCheckbox         ## PLAT-3 `Checkbox`
    pkToggle           ## PLAT-3 `Toggle`
    pkInput            ## PLAT-3 `Input`
    pkSelect           ## PLAT-3 `Select`
    pkList             ## PLAT-3 `List`
    pkTree             ## PLAT-3 `Tree`
    pkTable            ## PLAT-3 `Table`
    pkTabs             ## PLAT-3 `Tabs`
    pkCollapsible      ## PLAT-3 `Collapsible`
    pkModal            ## PLAT-3 `Modal`
    pkMenu             ## PLAT-3 `Menu`
    pkProgressIndicator## PLAT-3 `ProgressIndicator`
    pkImage            ## PLAT-3 `Image`, generalised to any MIME type
    pkMarkdown         ## PLAT-3 `Markdown`

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

  ValueMatchKind* = enum
    ## The three TOTAL predicates a per-type visualiser may match a type name
    ## with (Project-Definitions.md §5.3), spelled as the words a project
    ## definition writes.
    ##
    ## IT LIVES HERE RATHER THAN IN `project_definitions/model.nim`, AND THE
    ## MOVE IS §14'S. PLAT-11 declared these three beside the grammar that
    ## parses them; PLAT-12 has to EVALUATE them inside `presenter.resolve`,
    ## which cannot see the definition grammar — the pipeline imports
    ## `std/strutils` and `std/unicode` and nothing else. Two copies of one
    ## three-armed string comparison is exactly the shape
    ## Verification-Harness-Traps §14 names, so `model.MatchKind` IS this type
    ## and `model.matches` forwards to `typeMatches` below. There is one
    ## predicate; the grammar and the presenter both call it.
    ##
    ## THERE IS DELIBERATELY NO REGULAR EXPRESSION, and the reason is PLAT-11's
    ## unchanged: a regex over a cloned repository's text is unbounded work
    ## (the catastrophic-backtracking family), and "bounded" would then mean a
    ## step budget, a timeout and a partial answer — three mechanisms replacing
    ## one that does not need them.
    mkTypeName = "typeName"      ## exact equality
    mkTypePrefix = "typePrefix"  ## `startsWith`
    mkTypeSuffix = "typeSuffix"  ## `endsWith`

  MediaClass* = enum
    ## What a declared media type IS, as a CLOSED enum.
    ##
    ## ## THE STRING IS CLASSIFIED ONCE AND THEN NEVER CONSULTED AGAIN
    ##
    ## This is hardening, not tidiness. A media type on a presentation is a
    ## string a CLONED REPOSITORY wrote (Project-Definitions.md §1.1: "a user
    ## who clones a repository to *look* at it has evaluated nothing"), and the
    ## obvious rendering design — a table keyed on the string, a decoder looked
    ## up by subtype, a `split('/')` and a dispatch on the second half — is a
    ## dispatch the repository controls. That is the shape PLAT-11's parse
    ## excluded by keeping the media list closed, and it would be reintroduced
    ## the moment rendering went looking for a decoder BY NAME.
    ##
    ## So `mediaClassOf` is a total function from bytes to a member of this
    ## enum by EXACT EQUALITY against a literal list, everything downstream
    ## branches on the ENUM, and an unrecognised string is `mcUnknown` —
    ## a value, reported, never a lookup miss. `image/png; charset=utf-8`,
    ## `IMAGE/PNG` and `image/png\0` are all `mcUnknown`, which is the right
    ## answer: this build has no renderer for any of them.
    mcUnknown
    mcImagePng
    mcImageJpeg
    mcImageSvg
    mcAudioWav
    mcAudioOgg
    mcTextMarkdown
    mcTextHtml
    mcOctetStream

  MediaGap* = object
    ## §5.2's media, declared on a surface that cannot draw it — "what is
    ## missing and how to get it", for a VALUE rather than for a pane.
    ##
    ## THE SHAPE IS PLAT-9'S `DependencyGap` AND THAT IS DELIBERATE. §8.2's
    ## rule for a plugin surface whose external component is absent is that the
    ## degradation "says what is missing and how to get it — a name and an
    ## install action, not 'unavailable'", and a terminal that cannot show
    ## `image/png` is the same sentence with a different subject. Inventing a
    ## second "cannot render" concept beside it would be the parallel banner
    ## §8.2 already refused once.
    ##
    ## `store/value_media_degradation.nim` is where this becomes a
    ## `PaneDegradation`; it is not in this package because `PaneDegradation`
    ## is the front-end's and this one is the pipeline's.
    mediaType*: string
      ## As DECLARED, verbatim and already bounded by the declaration's own
      ## length bound. Carried so a reader is told what the project said rather
      ## than what this build made of it.
    class*: MediaClass
    visualiser*: string
      ## The presenter id that declared it, so the gap and the attribution name
      ## the same thing.
    surface*: string
      ## The budget's name. The same value degrades on one surface and not on
      ## another, so a gap that could not say which surface it was on would be
      ## answering a different question — the reason `Budget.name` exists.
    bytes*: int
      ## How many bytes the declared field held, or 0 when the field named by
      ## `mediaFrom` is not in the value.
    fieldPresent*: bool
      ## Whether the value actually carried the field the rule named. A rule
      ## pointing at a field that is not there is a DIFFERENT problem from a
      ## surface that cannot draw, and the remedy differs, so the two are not
      ## collapsed into one message.

  ExpansionBound* = object
    ## PLAT-12. The WORK a rendering was allowed and what it did with it —
    ## and, when the allowance ran out, that fact as something a reader is
    ## told rather than something that silently shortens a value.
    ##
    ## ## WHY A PRESENTATION NEEDS A WORK BOUND AT ALL
    ##
    ## Because §5.2's templating is RECURSIVE and nothing above this said so.
    ## A summary is substituted by rendering each named field through the same
    ## presenter — `substituteSummary` -> `inlineText` -> `winningVisualiser`
    ## -> `visualisedText` -> `substituteSummary` — so a rule matching a type
    ## that CONTAINS ITSELF re-enters its own template once per placeholder.
    ## The branching factor is `MaxTemplatePlaceholders` (16) and the only
    ## bound on the number of levels is `Budget.depth`, which is 7 on the
    ## state panel and 16 on the terminal's tree. Measured on 2026-09-12, a
    ## 200-byte declaration against `Node { next: Node }`, release build:
    ##
    ## | budget depth | elapsed | text produced |
    ## |---|---|---|
    ## | 4 | 28 ms | 1.0 MB |
    ## | 5 | 453 ms | 16.8 MB |
    ## | 6 | 7.3 s | 268 MB |
    ## | 7 | 125 s | **4.29 GB**, for ONE value |
    ##
    ## Exactly ×16 per level, and CLIPPING DOES NOT SAVE A NARROW SURFACE:
    ## `flow` is 30 cells and depth 10, so it produces the whole string and
    ## then cuts 30 cells off the front of it.
    ##
    ## ## WHY THE BOUND IS ON WORK AND NOT ON DEPTH
    ##
    ## Depth was already bounded and bounded nothing: every row above is
    ## inside `Budget.depth`. What a declaration multiplies is the number of
    ## renderings per level, so the quantity to bound is the TOTAL — see
    ## `MaxRenderWork`.
    ##
    ## ## AND "WORK" HAD TO BE MEASURED, NOT ASSUMED
    ##
    ## *Corrected 2026-09-12, one day after the bound was added.* The first
    ## version charged one unit per rendering entered and one per byte
    ## produced, and called that the frame's cost. It is not. Three of the
    ## things one rendering does are proportional to the RECORDING and appear
    ## in neither number — the walk over the field a `media` rule names, the
    ## two walks `byteBufferOf` makes over a value's own members, and the
    ## `MaxVisualiserRules` × `MaxTypeMatchBytes` comparison the rule scan
    ## makes per node. Measured against a 200,000-element field at the state
    ## panel's depth: 19.5 seconds for ONE value, linear in the field, with
    ## `spent` below reporting the same 1,048,582 it reports for a field two
    ## hundred times smaller.
    ##
    ## THAT IS THE LESSON THIS FIELD EXISTS TO CARRY. A bound whose report is
    ## constant in the quantity being multiplied is a bound on the wrong
    ## quantity — and because it reports, it states that it honoured an
    ## allowance it never measured, which is worse than saying nothing. The
    ## charges are now one per QUANTITY at the site that spends it; see the
    ## block above `presenter.memberScanCost`.
    ##
    ## ## AND IT IS REPORTED, NOT SILENT
    ##
    ## The shape is `MediaGap`'s, for §8.2's reason: a value that stopped
    ## short because this process refused to spend more is a degradation, and
    ## a degradation that says nothing is the blank region §8.2 forbids. The
    ## rendering is not blanked either — expansion stops with the elision
    ## glyph the surface already uses, the value's own text up to that point
    ## stays, and `reached` carries the sentence.
    reached*: bool
      ## Whether the bound was hit. False on every ordinary presentation,
      ## including every presentation in this repository's suites and corpus.
    spent*: int
      ## Units consumed, in five quantities: one per inline rendering entered,
      ## one per byte produced, one per member each of a frame's O(n) walks may
      ## touch, one per byte the visualiser scan may compare, and one per
      ## member of the field a §5.2 rule named. Carried whether or not the
      ## bound was reached, because a number that only appears in the failure
      ## case cannot be watched — and, as the correction above records, a
      ## number that does not MOVE with the work cannot be watched either.
    bound*: int
      ## `MaxRenderWork`, carried so a report is readable without the reader
      ## having to look the constant up.
    visualiser*: string
      ## The id of the rule being expanded when the bound was reached, or ""
      ## when no visualiser was involved. This is what makes the sentence
      ## actionable: the remedy is a change to THAT rule.
    surface*: string
      ## The budget's name, for `MediaGap`'s reason — the same value at two
      ## budgets is two different renderings.

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
    media*: set[MediaClass]
      ## Which media this surface can RENDER AS MEDIA, rather than describe.
      ##
      ## PLAT-12. A per-type visualiser may declare that a region of a value is
      ## `image/png` (Project-Definitions.md §5.2); whether that becomes pixels
      ## is a property of the SURFACE, and §5.2 says so — "an image, at
      ## whatever fidelity the surface allows". A surface that cannot is not
      ## permitted to go blank: the class is absent from this set, the
      ## presenter renders the value's ordinary presentation instead, and a
      ## `MediaGap` on the result says what was missing and how to get it.
      ##
      ## THE ZERO VALUE IS THE EMPTY SET, AND THAT IS THE HONEST DEFAULT: a
      ## surface that has not said it can draw something cannot.
      ##
      ## EVERY BUDGET IN `surfaces.nim` DECLARES EXACTLY `{mcOctetStream}`
      ## TODAY, and the sameness is a measurement rather than an oversight —
      ## see that file's `MediaCapabilityNote`. No surface in this repository
      ## draws pixels, plays audio or renders markdown yet; raw bytes are the
      ## one medium all seven already honour, because `builtin.byte-buffer`
      ## has rendered a hex dump with a length since CTUI-7. Widening a set
      ## here is PLAT-14's work for the terminal and the desktop's own for the
      ## DOM, and claiming a capability nothing implements would turn the
      ## degradation path — the part that IS built — into a blank region.

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
    languageName*: string
      ## The recording's own name for its language — `rust`, `python`, `noir` —
      ## verbatim, as a project definition spells it in a rule's `language`.
      ##
      ## A SECOND LANGUAGE FIELD, AND THE TWO ANSWER DIFFERENT QUESTIONS.
      ## `lang` above is a three-member enum because PRESENTATION only ever
      ## needed to know whether to draw `vec![…]` or `@[…]`; collapsing every
      ## other language onto `plOther` is correct for that and useless for
      ## §5.3's "what it matches: … a language", where a rule saying
      ## `language = "python"` must not also claim a Ruby value. Widening the
      ## enum instead would have made this package carry a list of every
      ## language CodeTracer records, which is `common/lang.nim`'s job and is
      ## the module this package deliberately cannot see (see
      ## `PresentationLang`).
      ##
      ## EMPTY MEANS UNKNOWN, and an unknown language matches no
      ## language-qualified rule — `typeMatches` compares by equality and ""
      ## equals no declared language. An unqualified rule still matches, which
      ## is the right default: a rule that named no language did not ask.
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
    mediaGaps*: seq[MediaGap]
      ## PLAT-12. Every §5.2 media declaration this surface could not honour,
      ## deduplicated and bounded by `MaxMediaGaps`.
      ##
      ## A SEQ AND NOT A BOOL, because §8.2's rule is that the degradation says
      ## WHAT is missing: a value carrying two media fields on a surface that
      ## can draw neither has two things to say, and a flag would say one of
      ## them. It is also the reason it is not folded into `truncated` — a
      ## clipped string and an undrawable image have different remedies, and
      ## PLAT-2's budget model already owns the first.
      ##
      ## EMPTY IS THE ORDINARY CASE, including for every value on a build with
      ## no project definitions loaded: a gap can only be produced by a rule
      ## that declared media.
    expansion*: ExpansionBound
      ## PLAT-12. What this rendering SPENT, and whether it was cut off for
      ## spending it. See `ExpansionBound`; `reached` is false on every
      ## ordinary presentation and the zero value is therefore the ordinary
      ## case, exactly as `mediaGaps` being empty is.
      ##
      ## SEPARATE FROM `truncated`, and the separation is the point. A budget
      ## elision and a refused expansion have different remedies: the first is
      ## answered by opening the value on a surface with more room, and the
      ## second cannot be — no surface has 4 GB of room, and the fix is to the
      ## RULE. Folding the second into the first would offer a remedy that
      ## cannot work, which is the same error `describeMediaGap`'s three arms
      ## exist to avoid. `truncated` is ALSO set when the bound is reached,
      ## because something was in fact dropped.

const
  ValuePresentationKinds* = {pkText, pkList, pkTree, pkTable, pkImage}
    ## THE PRESENTER'S RANGE, as a value rather than as a sentence.
    ##
    ## The five of PLAT-3's sixteen that a recorded VALUE can inhabit. The
    ## other eleven are interaction forms and container chrome reachable only
    ## by a VIEW; the reasons are in this module's header, one per entry.
    ##
    ## It is a named constant because two callers need the same answer and a
    ## second copy of a closed set is how the two come to disagree
    ## (Verification-Harness-Traps §14):
    ##
    ##   * `value_presentation_test`'s "the presenter's range is still PLAT-2's
    ##     five" case, which folds `present` over every `PValueKind` at two
    ##     budgets — this was the set's first home, as a `const` local to that
    ##     case;
    ##   * `common/project_definitions/parse.nim`, which refuses a project
    ##     definition declaring `present = "Button"`. A visualiser is a
    ##     function from a value to a presentation
    ##     (Project-Definitions.md §3.1), so the presentations it may name are
    ##     exactly the ones a value can become — and if the presenter's range
    ##     ever widened, the declarative grammar would widen with it on the
    ##     same day rather than a release later.

  Ellipsis* = "…"
    ## One display cell wide, so a clipped field's width is still its cell
    ## count. The same constant the TUI's formatters used before this package
    ## existed.

  MaxMediaGaps* = 8
    ## How many DISTINCT media gaps one presentation reports.
    ##
    ## A BOUND RATHER THAN A LIST THAT GROWS WITH THE VALUE, because the gap
    ## list is derived from attacker-controlled declarations applied to an
    ## attacker-controlled recording: a rule matching by suffix against a
    ## thousand-member record would otherwise produce a thousand identical
    ## sentences, each of them a string this process allocated on behalf of a
    ## repository nobody read. Gaps are deduplicated first, so the bound is
    ## reached only by a value that genuinely declares more than eight
    ## different undrawable media — at which point the ninth is dropped and
    ## the eight that are shown are still true.

  MaxRenderWork* = 1_048_576
    ## HOW MUCH ONE PRESENTATION MAY SPEND — one mebibyte, counted as one unit
    ## per inline rendering entered plus one per byte it produced.
    ##
    ## THE UNIT IS OUTPUT, WITH A FLOOR OF ONE PER RENDERING, and both halves
    ## are load-bearing. Output is the quantity a reader can check (it is the
    ## length of the strings this process allocated on a repository's behalf)
    ## and it bounds memory directly; the floor of one is what keeps a
    ## rendering that produces nothing from being free, so the count is a bound
    ## on WORK and not only on bytes.
    ##
    ## WHY A CONSTANT AND NOT A FUNCTION OF THE BUDGET. Because the runaway is
    ## not a property of the surface: `flow` is the narrowest budget in the
    ## product (30 cells) and has the DEEPEST exposure of the one-line
    ## surfaces (depth 10), since clipping happens after the string exists.
    ## A bound derived from `Budget.cells` would be smallest exactly where the
    ## exposure is largest.
    ##
    ## THE NUMBER IS QUOTED AGAINST THE LARGEST RENDERING EVER MEASURED HERE.
    ## `headless_session.extractValueText` produced a 12 KB string for a
    ## 600-entry mapping — the measurement `surfaces.tuiValueBudget` records
    ## as the cost its member cap removed — so this is ~87× the worst real
    ## case, and three to four ORDERS OF MAGNITUDE below what a declaration
    ## reaches without it (268 MB at depth 6, 4.29 GB at depth 7; see
    ## `ExpansionBound`). Nothing in this repository's suites or in its
    ## recorded fixture corpus reaches it, and that is a measurement rather
    ## than an expectation: the whole `tui` lane is green with the bound in
    ## place, including `test_value_presentation_corpus`'s 25,924 assertions
    ## over three real recordings driven through a real `replay-server`, and
    ## `expansion.reached` is false on every one of them.
    ##
    ## REACHING IT IS A REPORTABLE CONDITION, NOT A BLANK. See
    ## `ExpansionBound` and `describeExpansionBound`.

func mediaTypeSpelling*(c: MediaClass): string =
  ## The MIME type a class is written as, in a declaration and in a report.
  ##
  ## THE CLOSED LIST LIVES HERE AND NOWHERE ELSE. PLAT-11's
  ## `parse.DeclarativeMediaTypes` — the set a project definition may name — is
  ## DERIVED from this function by `declarableMediaTypes` below, so the
  ## grammar's list and the renderer's classification cannot disagree about
  ## whether `audio/ogg` is a thing. They were written as two literals in the
  ## first draft, which is Verification-Harness-Traps §14 in its most literal
  ## form: a type the grammar accepts and the renderer does not know is a
  ## silently blank value, and a type the renderer knows and the grammar
  ## refuses is a feature nobody can reach.
  case c
  of mcUnknown: ""
  of mcImagePng: "image/png"
  of mcImageJpeg: "image/jpeg"
  of mcImageSvg: "image/svg+xml"
  of mcAudioWav: "audio/wav"
  of mcAudioOgg: "audio/ogg"
  of mcTextMarkdown: "text/markdown"
  of mcTextHtml: "text/html"
  of mcOctetStream: "application/octet-stream"

func mediaClassOf*(mediaType: string): MediaClass =
  ## The class a declared media type IS, or `mcUnknown`.
  ##
  ## EXACT EQUALITY, over the whole string, against the spelling
  ## `mediaTypeSpelling` gives — no `split`, no lowercasing, no parameter
  ## stripping, no prefix test on the type half. Every one of those would make
  ## the string a repository wrote select what this process does with it, which
  ## is the dispatch-by-name this enum exists to prevent. See `MediaClass`.
  ##
  ## Written as a loop over the enum rather than as a `case` over string
  ## literals so that the two directions are one table: a member added to
  ## `MediaClass` with a spelling is classifiable, declarable and renderable on
  ## the same edit.
  if mediaType.len == 0:
    return mcUnknown
  for c in MediaClass:
    if c != mcUnknown and mediaTypeSpelling(c) == mediaType:
      return c
  mcUnknown

func declarableMediaTypes*(): seq[string] =
  ## §5.2's table, as the MIME types a project definition may declare.
  ##
  ## DERIVED from `MediaClass`, which is the point — see `mediaTypeSpelling`.
  ## `mcUnknown` is not in it because it is the ABSENCE of a class rather than
  ## a member of the list.
  for c in MediaClass:
    if c != mcUnknown: result.add mediaTypeSpelling(c)

func describeMediaGap*(g: MediaGap): string =
  ## §8.2's sentence, for a value: the name, the surface, and how to get it.
  ##
  ## BOTH HALVES ARE IN THE STRING AND THE SUITE ASSERTS BOTH SUBSTRINGS
  ## rather than that the string is non-empty — `surface_host.describe` carries
  ## the same note for the same reason. "unavailable" is what §8.2 forbids, and
  ## a blank region is what it forbids one step further.
  ##
  ## THREE CAUSES, THREE REMEDIES, because collapsing them would tell a user to
  ## do something that cannot work — §14's retry-that-cannot-succeed at value
  ## scale:
  ##
  ##   * the rule names a field the value does not have. The project's
  ##     declaration is wrong, or this value is not the one it meant; there is
  ##     nothing to install and nothing to switch to.
  ##   * the media type is outside §5.2's list. No surface in any front-end
  ##     draws it, so "try another front-end" would be that same bad advice.
  ##   * the type is one §5.2 names and THIS surface cannot draw it. That is
  ##     the renewable one, and the remedy names the surfaces that can.
  let where = if g.surface.len > 0: g.surface else: "this surface"
  if not g.fieldPresent:
    return "visualiser '" & g.visualiser & "' declares '" & g.mediaType &
      "' but the value has no such field, so there are no bytes to draw. " &
      "The value is shown as it would be without the declaration. To fix it: " &
      "point the rule's 'mediaFrom' at a field this type actually has"
  if g.class == mcUnknown:
    return "visualiser '" & g.visualiser & "' declares media type '" &
      g.mediaType & "' (" & $g.bytes & " bytes), which this build has no " &
      "renderer for on ANY surface — it is outside the media a declaration " &
      "may name. The value is shown as it would be without the declaration. " &
      "To fix it: declare one of " & declarableMediaTypes().join(", ")
  "visualiser '" & g.visualiser & "' declares '" & g.mediaType & "' (" &
    $g.bytes & " bytes) and the '" & where & "' surface draws no " &
    g.mediaType & ". The value is shown as it would be without the " &
    "declaration, so nothing is hidden. To see it: open the value on a " &
    "surface that draws it — a surface whose budget declares '" &
    g.mediaType & "' in its media set"

func describeExpansionBound*(e: ExpansionBound): string =
  ## §8.2's sentence, for a rendering that ran out of allowance. "" when it did
  ## not, which is every ordinary presentation.
  ##
  ## A NAME AND A REMEDY, like `describeMediaGap`, and for the same reason: a
  ## value that stops short without saying why is the blank region §8.2
  ## forbids. The remedy names the RULE rather than a surface, because no
  ## surface has room for the rendering that was refused — telling a reader to
  ## open it somewhere else would be the retry that cannot succeed.
  ##
  ## TWO REMEDIES, because there are two ways to reach the bound and only one
  ## of them is a declaration's fault. A rule whose summary re-enters its own
  ## type is named and blamed; a presentation that simply rendered a very large
  ## recording is told what it spent and is not told to edit a rule it does not
  ## have.
  if not e.reached:
    return ""
  let where = if e.surface.len > 0: e.surface else: "this surface"
  if e.visualiser.len > 0:
    return "visualiser '" & e.visualiser & "' was still expanding when this " &
      "rendering reached its work bound of " & $e.bound & " units (" &
      $e.spent & " spent) on the '" & where & "' surface. Expansion " &
      "stopped there and " &
      "the value is shown as far as it got, marked with '" & Ellipsis &
      "'. A summary template is substituted by RENDERING each field it names, " &
      "so a rule whose type contains itself re-enters its own template once " &
      "per placeholder. To fix it: give that rule a summary that does not " &
      "name a field of its own type, or name fewer of them"
  "this rendering reached its work bound of " & $e.bound & " units (" &
    $e.spent & " spent) on the '" & where &
    "' surface and stopped there, marked with '" &
    Ellipsis & "'. No visualiser was expanding, so this is the size of the " &
    "recorded value rather than a declaration. To see more of it: open the " &
    "value on a surface whose budget descends less far, so that fewer " &
    "renderings are spent above the part you are reading"

func typeMatches*(matchKind: ValueMatchKind; match, ruleLanguage: string;
                  typeName, valueLanguage: string): bool =
  ## Whether a rule matching `match` under `matchKind` (and, when non-empty,
  ## restricted to `ruleLanguage`) claims a value of type `typeName` recorded
  ## from `valueLanguage`.
  ##
  ## TOTAL, AND BOUNDED BY `typeName.len`. §2.2: "Matching and templating are
  ## total and terminate by construction." Three O(n) string comparisons, no
  ## backtracking, no allocation, no re-scan.
  ##
  ## THE ONE IMPLEMENTATION. `project_definitions/model.matches` calls this and
  ## contains no comparison of its own, `presenter.resolve` calls it, and both
  ## suites call it through their subjects. §14: one predicate, one function,
  ## rule and control both calling it — which is the property that stops the
  ## grammar's idea of "does this rule match" drifting from the renderer's.
  ##
  ## AN EMPTY `match` MATCHES NOTHING, deliberately, and this is not the
  ## "empty pattern matches everything" convention. `mkTypeName` with an empty
  ## match asks whether the type name is "", which for an unnamed value it is —
  ## so the rule that a whole tier could be claimed by a one-character typo is
  ## closed where it can be closed rather than here: PLAT-11's parser refuses a
  ## visualiser whose `match` is empty (`pdcMissingField`), and
  ## `value_visualisers.admit` refuses one again at the presenter boundary, so
  ## no `Visualiser` reaching `resolve` has one.
  if ruleLanguage.len > 0 and ruleLanguage != valueLanguage: return false
  case matchKind
  of mkTypeName: typeName == match
  of mkTypePrefix:
    match.len <= typeName.len and typeName[0 ..< match.len] == match
  of mkTypeSuffix:
    match.len <= typeName.len and
      typeName[typeName.len - match.len .. ^1] == match

func presentationSpelling*(k: PresentationKind): string =
  ## `pkProgressIndicator` -> `ProgressIndicator`. PLAT-3's own spelling of an
  ## entry, DERIVED from the enum rather than written in a table, so a name
  ## cannot drift from the member it names.
  ##
  ## IT LIVES WITH THE ENUM, and `view_vocabulary.vocabularyName` forwards to
  ## it. That is where it was written first, and it moved down on 2026-09-11
  ## when PLAT-11's declarative grammar needed to spell a `present = "Table"`
  ## back: a project definition names a PRESENTATION, so reaching for the
  ## name through the VIEW vocabulary would have made the value-presentation
  ## grammar depend on the view package for a string about its own enum.
  ($k)[2 .. ^1]

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

func attributionBadge*(p: Presentation): string =
  ## The SHORT form of the answer: `via builtin.record`.
  ##
  ## PLAT-2 deliverable 4 asks that a user be able to ask which presenter
  ## rendered a value. `describeAttribution` below is the full answer and is
  ## one line long; a pane title, a status line or a chip may not have that
  ## many cells, and a caller with too few cells for the full form should show
  ## the SHORTEST TRUE answer rather than a clipped one. A clipped attribution
  ## is worse than a short one: `builtin.byte-buf…` reads like a presenter
  ## nobody can grep for.
  ##
  ## The two forms are here rather than at a call site because two surfaces
  ## abbreviating the same fact differently is how PLAT-2's survey found five
  ## spellings of one error value.
  "via " & p.attribution.presenter

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
  if p.mediaGaps.len > 0:
    # PLAT-12. A value whose declared media this surface cannot draw is still
    # rendered — but a reader asking "which visualiser rendered this" has to be
    # told that the visualiser asked for something it did not get, or the
    # answer is true and misleading at once. The MARKER is here, one token per
    # gap; the sentence with the remedy in it is `describeDegradation`, because
    # this function is one line long by contract (see the doc comment) and
    # §8.2's remedy is not.
    var kinds: seq[string] = @[]
    for g in p.mediaGaps: kinds.add g.mediaType
    parts.add "media-degraded=" & kinds.join(",")
  if p.expansion.reached:
    # PLAT-12. The same division of labour as the marker above: a reader
    # asking which visualiser rendered a value has to be told that the
    # rendering was CUT OFF, or the answer is true and misleading at once.
    # The marker names the rule when there was one, because that is the thing
    # to edit; the sentence with the remedy in it is `describeDegradation`.
    parts.add "expansion-bounded=" &
      (if p.expansion.visualiser.len > 0: p.expansion.visualiser
       else: $p.expansion.spent & "/" & $p.expansion.bound)
  parts.join(" ")

func describeDegradation*(p: Presentation): string =
  ## Every way this rendering did not give the reader what was declared, one
  ## per line, each naming what is missing and how to get it. "" when there is
  ## nothing to say, which is the ordinary case.
  ##
  ## The full answer to `describeAttribution`'s `media-degraded=` and
  ## `expansion-bounded=` markers. Two functions rather than one for the reason
  ## `attributionBadge` and `describeAttribution` are two: a title row has a
  ## handful of cells and a diagnostics pane has a paragraph, and a caller
  ## short of room must show the shortest TRUE answer rather than a clipped
  ## one.
  ##
  ## PLAT-12'S WORK BOUND IS A LINE HERE RATHER THAN A SECOND FUNCTION, and
  ## that is the §8.2 decision rather than a convenience: a pane asking "is
  ## there anything to tell the reader about this value" must not have to know
  ## how many KINDS of answer exist, or the next kind is silent in every caller
  ## written before it. `value_media_degradation` and the terminal's title row
  ## both call this one function.
  var lines: seq[string] = @[]
  for g in p.mediaGaps:
    lines.add describeMediaGap(g)
  let bounded = describeExpansionBound(p.expansion)
  if bounded.len > 0:
    lines.add bounded
  lines.join("\n")
