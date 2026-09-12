## value_presentation/presenter.nim — `PValue -> Presentation`, the ONE
## resolution every surface consumes.
##
## PLAT-2's four deliverables live here:
##
##   1. `present` — the resolution itself.
##   2. Every surface calls it (`surfaces.nim` declares the budgets; the gate
##      `ci/test/value-presentation-boundary.sh` asserts nobody bypasses it).
##   3. THE BUDGET IS AN INPUT, NOT A POST-FILTER. `present` descends only as
##      far as the budget allows, renders only as many members as fit, and
##      clips text to the surface's own cell measure BEFORE returning. There is
##      no `truncate(present(v))` anywhere in this repository, and the gate
##      fails if one appears — that is the deliverable the milestone brief
##      names as most likely to be faked.
##   4. `resolve` returns an `Attribution` naming the winner, the tier, what it
##      matched and every other candidate, so `describeAttribution` can answer
##      "which presenter rendered this value".
##
## ## PRECEDENCE
##
## Project-Definitions.md §5.4: *in-program function -> project definition ->
## plugin -> built-in*, and within a tier the more specific match wins, with
## ties broken by declaration order and REPORTED.
##
## Three of those four tiers have no members yet — there is no in-program
## visualiser convention, no `.codetracer/` loader and no plugin host. They are
## nonetheless part of the resolution *function* rather than of a later one,
## because a `PresenterSet` is a PARAMETER: PLAT-12 adds rules by passing a
## different set, not by editing this file. That is also why the set is a
## parameter and not a module-level registry — a mutable global registry would
## make every presentation impure, which is the one property this milestone
## cannot trade.
##
## ## PURITY
##
## Every routine here is `func`. Nim's `func` implies `{.noSideEffect.}`, so a
## presenter that read the CLOCK, the FILESYSTEM or a module-level `var` would
## not COMPILE. `ci/test/value-presentation-boundary-test.sh` plants exactly
## those presenters against a copy of this package and asserts `nim check`
## refuses each, naming the effect.
##
## THE ENVIRONMENT IS THE EXCEPTION AND IS ENFORCED THE OTHER WAY.
## `std/envvars.getEnv` carries `ReadEnvEffect` as a tag rather than as a side
## effect and therefore compiles inside a `func` — measured, and asserted as a
## negative fact by that same suite so a change in Nim reddens it. What keeps
## it out is `ci/test/value-presentation-boundary.sh`'s
## `FORBIDDEN_PIPELINE_IMPORTS`, which names `envvars`; the suite plants that
## import too and watches the gate fire.
##
## The gate also covers the escapes the compiler cannot see: a module-scope
## `let` initialised from a call at module load, a `{.cast(noSideEffect).}`
## block, and a `proc` written where a `func` is required — at any indentation,
## including under a `when`.

import std/strutils

import vocabulary, value_model

export vocabulary, value_model

type
  PresenterRule* = object
    ## One entry of the precedence table.
    ##
    ## DATA, not code: a rule says which kinds it claims and how specific the
    ## claim is. The renderer is chosen from `id` by `renderInline` below. A
    ## later tier contributes a rule with a higher `tier` precedence and the
    ## resolution function is untouched.
    id*: string          ## stable, greppable, e.g. `builtin.sequence`
    tier*: PresenterTier
    kinds*: set[PValueKind]
    rank*: int
      ## specificity WITHIN the tier; higher wins. A rule claiming one kind
      ## outranks a rule claiming twenty, and the number is written down rather
      ## than derived from `card(kinds)` so a future rule that matches on a type
      ## NAME (which has no kind set to count) can be ranked beside these.

  Visualiser* = object
    ## PLAT-12. A per-type visualiser, as the PRESENTER sees one.
    ##
    ## ## WHY THIS IS NOT `project_definitions.VisualiserRule`
    ##
    ## Because this package cannot see that one, and must not. The pipeline's
    ## whole import closure is `std/strutils` and `std/unicode`
    ## (`ci/test/value-presentation-boundary.sh` asserts it), and
    ## `VisualiserRule` carries an origin, a scope, a defining file and a
    ## declaration order — four facts about WHERE A DECLARATION CAME FROM, none
    ## of which a renderer may branch on. So the two types are the two sides of
    ## a boundary and `common/value_visualisers.nim` is the one function that
    ## crosses it: it takes the provenance, applies §5.4's ordering and the
    ## bounds, and hands over the rendering payload alone.
    ##
    ## ## EVERY FIELD IS DATA, AND THE ABSENCES ARE STILL THE DESIGN
    ##
    ## PLAT-11's `model.nim` header states this of the declaration; it has to
    ## remain true of the thing the declaration BECOMES, or parsing excluded
    ## something rendering let back in. So, as there: no field here names a
    ## program, a path to something loadable, an interpreter, a command, a URL
    ## or a callable. `mediaFrom` is a FIELD NAME inside the recorded value and
    ## is compared to member labels by equality; `mediaType` is classified by
    ## `mediaClassOf` into a closed enum before anything branches on it; and
    ## `summary` is substituted in one linear pass whose output is never
    ## re-scanned. There is nothing here to resolve, open, or look up.
    id*: string
      ## Stable, greppable, and what `Attribution.presenter` reports —
      ## `project:.codetracer/visualisers.toml#0`. It is the visualiser's whole
      ## identity as far as this package is concerned; the bridge composes it
      ## from the provenance this type does not carry.
    tier*: PresenterTier
      ## §5.4's precedence: *in-program function -> project definition ->
      ## plugin -> built-in*. A field rather than a constant because the
      ## ordering is the contract and `resolve` compares tiers; a `Visualiser`
      ## that could not say which tier it is in could not lose to one above it.
      ##
      ## READ IT THROUGH `effectiveTier`, NEVER DIRECTLY — see `tierDeclared`.
    tierDeclared*: bool
      ## Whether `tier` was WRITTEN or is the zero value, and it is here for
      ## `presentDeclared`'s reason with a much worse consequence.
      ##
      ## `ptInProgram` is the zero value of `PresenterTier` AND the
      ## HIGHEST-PRECEDENCE tier — §5.4 puts the recorded program's own
      ## function first deliberately, "because it is the author's stated intent
      ## about their own type". So a `Visualiser` constructed by anything that
      ## omitted `tier` would silently arrive with MAXIMUM privilege and beat
      ## every declaration in the product. Today nothing can: `visualiserFor`
      ## is the only producer and it sets both fields. That is exactly the
      ## state `present`/`pkText` was in before it cost a rendering, and the
      ## producers §5.1 still expects — a plugin tier, PLAT-13's executable
      ## tier — are the ones that would construct a `Visualiser` by hand.
      ##
      ## Zero is the SAFE answer here and not the dangerous one, which is the
      ## whole point of spending a field on it: an undeclared tier competes at
      ## the bottom (`effectiveTier` answers `ptBuiltin`), so a producer that
      ## forgets loses a contest instead of winning one it should not have
      ## entered. A rule that means to outrank another has to say so.
    typeMatch*: string
    matchKind*: ValueMatchKind
    language*: string
      ## "" means "any language". Compared by equality against
      ## `PresentationContext.languageName`.
    summary*: string
      ## §5.2's templating: `"{rows}x{cols}"`, over the value's FIELD NAMES.
      ## "" means the visualiser does not replace the rendering, only hides
      ## fields and/or declares media.
    hide*: seq[string]
      ## §5.3: "often the single most valuable thing a visualiser does".
    present*: PresentationKind
      ## From `ValuePresentationKinds`. `pkText` is the zero value AND a
      ## legitimate declaration, so `presentDeclared` below says which.
    presentDeclared*: bool
      ## Whether `present` was WRITTEN or is the zero value. Without it a rule
      ## that declared nothing would force every value it matched to `pkText`,
      ## which would silently flatten a matched record's tree — the difference
      ## between "the project asked for a tree" and "the project said nothing"
      ## is not expressible in `PresentationKind` alone.
    mediaType*: string
    mediaFrom*: string
      ## The member label holding the bytes. Non-empty exactly when
      ## `mediaType` is, which PLAT-11's parser enforces on the declaration and
      ## `value_visualisers.admit` enforces again here.
    rank*: int
      ## Specificity WITHIN the tier; higher wins, ties go to the earlier entry
      ## (§5.4's "ties broken by declaration order"). Computed by the bridge
      ## from the declaration's scope depth and match specificity, because
      ## those are provenance and provenance does not cross the boundary.

  PresenterSet* = object
    ## The ordered rules resolution considers. A parameter, so PLAT-12 extends
    ## precedence without a global.
    rules*: seq[PresenterRule]
    visualisers*: seq[Visualiser]
      ## PLAT-12's tier, as DATA on the same parameter PLAT-2 made a parameter
      ## for exactly this. The zero value is the empty seq, so a caller that
      ## has loaded no project definitions gets byte-identical output to the
      ## build before this milestone — which is what makes "the extension did
      ## not disturb the evaluator" (§5.5) checkable rather than asserted.
      ##
      ## NOT A REGISTRY, AND NOT A GLOBAL. A module-level mutable set would
      ## make every presentation impure, which is the one property PLAT-2
      ## cannot trade and the property PLAT-12's "a visualiser is pure:
      ## identical output across runs and front-ends" rests on.

const
  BuiltinRules*: seq[PresenterRule] = @[
    PresenterRule(id: "builtin.media", tier: ptBuiltin,
                  kinds: {pvkMedia}, rank: 90),
    PresenterRule(id: "builtin.error", tier: ptBuiltin,
                  kinds: {pvkError}, rank: 80),
    PresenterRule(id: "builtin.byte-buffer", tier: ptBuiltin,
                  kinds: {pvkSequence}, rank: 70),
      # Ranked above `builtin.sequence` and claiming the same kind, which is
      # what makes this table a PRECEDENCE table rather than a lookup: a
      # sequence of bytes has two candidates and the report says so.
      #
      # THE PREDICATE IS INHERITED VERBATIM from
      # `tui/app/formatters/type_formatters.byteBufferOf`: every member an
      # integer in `0 … 255`, and at least one. It is deliberately UNCHANGED by
      # this migration, including the consequence that `@[1, 2]` renders
      # `01 02 (2 bytes)` — the terminal's variables pane has done that since
      # CTUI-7 and a migration that quietly moved the line would be
      # indistinguishable from a defect.
      #
      # What DID change is its reach: it now applies on every surface rather
      # than on the one that had it. That is the milestone, and it is also the
      # rule most likely to want a project definition on top of it — which is
      # exactly the tier this table already has a slot for
      # (Project-Definitions §5.4). `value_presentation_test` pins the
      # behaviour so a later narrowing is a visible decision.
    PresenterRule(id: "builtin.pointer", tier: ptBuiltin,
                  kinds: {pvkPointer, pvkReference}, rank: 60),
    PresenterRule(id: "builtin.variant", tier: ptBuiltin,
                  kinds: {pvkVariant}, rank: 55),
    PresenterRule(id: "builtin.map", tier: ptBuiltin,
                  kinds: {pvkMap}, rank: 50),
    PresenterRule(id: "builtin.record", tier: ptBuiltin,
                  kinds: {pvkRecord}, rank: 45),
    PresenterRule(id: "builtin.tuple", tier: ptBuiltin,
                  kinds: {pvkTuple}, rank: 40),
    PresenterRule(id: "builtin.sequence", tier: ptBuiltin,
                  kinds: {pvkSequence}, rank: 35),
    PresenterRule(id: "builtin.enum", tier: ptBuiltin,
                  kinds: {pvkEnum}, rank: 30),
    PresenterRule(id: "builtin.function", tier: ptBuiltin,
                  kinds: {pvkFunction}, rank: 25),
    PresenterRule(id: "builtin.scalar", tier: ptBuiltin,
                  kinds: {pvkNil, pvkInt, pvkFloat, pvkBool, pvkString,
                          pvkChar, pvkCString}, rank: 20),
    PresenterRule(id: "builtin.opaque", tier: ptBuiltin,
                  kinds: {pvkRaw, pvkOpaque, pvkRecursion, pvkNotExpanded},
                  rank: 10),
  ]

  BuiltinPresenters* = PresenterSet(rules: BuiltinRules)

func withVisualisers*(visualisers: seq[Visualiser];
                      base: PresenterSet = BuiltinPresenters): PresenterSet =
  ## The built-in table plus a tier of visualisers.
  ##
  ## A named constructor rather than an object literal at each call site,
  ## because the field a caller would forget is `rules` — and a `PresenterSet`
  ## with visualisers and no built-ins resolves every unmatched value to
  ## `builtin.none`, which renders but renders WRONGLY and does so quietly.
  ## Passing `@[]` returns the built-in set unchanged, which is what every
  ## surface does before a checkout's definitions are loaded.
  PresenterSet(rules: base.rules, visualisers: visualisers)

func effectiveTier*(vis: Visualiser): PresenterTier =
  ## The tier a visualiser actually competes in.
  ##
  ## ONE FUNCTION, AND EVERY READER OF `tier` GOES THROUGH IT (§14). The rank
  ## comparison and the report are the two readers; a second copy of "is this
  ## tier declared" is a second thing that can be wrong while its twin agrees
  ## with itself, and the failure would be a visualiser ranked in one tier and
  ## reported in another — which is worse than either answer alone.
  ##
  ## An undeclared tier answers `ptBuiltin`, the LOWEST precedence. See
  ## `Visualiser.tierDeclared`: the zero value must be the answer that wins
  ## nothing, because it is what a future producer gets by forgetting.
  if vis.tierDeclared: vis.tier else: ptBuiltin

func visualiserRanks(a, b: Visualiser): bool =
  ## Whether `a` outranks `b`. §5.4: tier first, then specificity within the
  ## tier. Ties are NOT resolved here — the caller keeps the earlier entry,
  ## which is §5.4's "ties broken by declaration order".
  let (ta, tb) = (effectiveTier(a), effectiveTier(b))
  ta < tb or (ta == tb and a.rank > b.rank)

func winningVisualiser*(v: PValue; presenters: PresenterSet;
                        language: string): int =
  ## The index of the visualiser that claims `v`, or -1.
  ##
  ## §5.4's precedence, over one list: the lowest TIER wins, the highest rank
  ## within it, and a genuine tie goes to the entry declared first. The loop is
  ## the shape the built-in loop below already has, deliberately — one
  ## precedence, expressed twice would be two precedences (§14), and the two
  ## are then combined in `resolve` by comparing the two winners' tiers.
  ##
  ## BOUNDED BY THE LIST, which `value_visualisers.presentersFor` bounds by
  ## `MaxVisualiserRules`, and by `typeMatch.len` per entry. A nested value
  ## re-resolves, so this runs once per rendered node rather than once per
  ## presentation — which is why it is a linear scan over a bounded list and
  ## not a scan over anything the RECORDING controls.
  ##
  ## *AND BOUNDED PER FRAME IS NOT BOUNDED PER PRESENTATION.* Corrected
  ## 2026-09-12: both of the numbers above are the DECLARATION's — 256 × 200 =
  ## 51,200 byte comparisons per rendered node — and the number of nodes is
  ## what `MaxRenderWork` exists to bound, so the two multiply. A rendering
  ## therefore pays for this scan through `chargedWinner`, which is the only
  ## way `inlineText` and `renderNode` reach it. This function itself stays
  ## uncharged and pure so that `resolve` — asked once per presentation, and
  ## asked by callers who are not rendering at all — can call it.
  result = -1
  if v.isNil:
    return
  for i, vis in presenters.visualisers:
    if not typeMatches(vis.matchKind, vis.typeMatch, vis.language,
                       v.typeName, language):
      continue
    if result < 0 or visualiserRanks(vis, presenters.visualisers[result]):
      result = i

func resolveBuiltin*(v: PValue;
                     presenters: PresenterSet = BuiltinPresenters): Attribution =
  ## Which BUILT-IN presenter renders `v`, ignoring every other tier.
  ##
  ## THE BODY IS PLAT-2'S `resolve`, MOVED AND OTHERWISE UNTOUCHED, and the
  ## split was forced by a defect the suite caught on its first run rather than
  ## chosen: `builtinInlineText` dispatches on `Attribution.presenter` through
  ## a `case` over `builtin.*` ids, and once `resolve` started answering with a
  ## VISUALISER id every such value fell through to the `else` arm and rendered
  ## as `<Wide>` — the opaque fallback — instead of as its record. A visualiser
  ## that only HID a field therefore erased the whole rendering.
  ##
  ## So the two questions are two functions: "which tier wins" is `resolve`,
  ## and "which built-in draws the shape" is this. `resolve` calls it, so there
  ## is still one built-in precedence loop.
  let kind = if v.isNil: pvkNil else: v.kind
  var winner = -1
  var candidates: seq[string] = @[]
  for i, rule in presenters.rules:
    if kind notin rule.kinds:
      continue
    # A byte buffer is the one built-in whose claim depends on the value's
    # CONTENTS rather than on its kind, which is exactly the shape a NatVis
    # rule has (Project-Definitions §5.3: "what it matches: a type name, a
    # pattern, a language, a structural shape"). Handling it here, in the
    # resolution loop, is what keeps the loop the only place precedence is
    # decided.
    if rule.id == "builtin.byte-buffer" and byteBufferOf(v).len == 0:
      continue
    candidates.add rule.id
    if winner < 0:
      winner = i
    else:
      let w = presenters.rules[winner]
      if rule.tier < w.tier or (rule.tier == w.tier and rule.rank > w.rank):
        # Move the new winner to the front so `candidates[0]` is always the
        # winner and `candidates[1..]` is what it beat — the invariant
        # `describeAttribution` reads.
        let last = candidates.len - 1
        for j in countdown(last, 1):
          swap(candidates[j], candidates[j - 1])
        winner = i
  if winner < 0:
    return Attribution(tier: ptBuiltin, presenter: "builtin.none",
                       matched: "kind=" & $kind, rank: 0,
                       candidates: @["builtin.none"])
  Attribution(tier: presenters.rules[winner].tier,
              presenter: presenters.rules[winner].id,
              matched: "kind=" & $kind,
              rank: presenters.rules[winner].rank,
              candidates: candidates)

func resolve*(v: PValue; presenters: PresenterSet = BuiltinPresenters;
              language = ""): Attribution =
  ## Which presenter renders `v`, and what else could have — across ALL of
  ## §5.4's tiers.
  ##
  ## Total: `builtin.opaque` claims the kinds nothing else does, and the
  ## fallback names itself rather than returning an empty attribution —
  ## "no presenter" is a state a reader must be able to see, and an empty
  ## string in a report is indistinguishable from a bug in the reporter.
  ##
  ## PLAT-12 ADDS A TIER AND CHANGES NO EXISTING ANSWER. With
  ## `presenters.visualisers` empty — which is every call this repository made
  ## before this milestone, and every call a build with no project definitions
  ## makes now — this is `resolveBuiltin` and nothing else, byte for byte.
  ## §5.5's compatibility rule ("a file using none of them behaves exactly as
  ## it does today") applied to the resolution itself, and
  ## `value_visualisers_test`'s "with no visualisers the pipeline is
  ## byte-identical to PLAT-2's" case asserts it over every budget.
  ##
  ## `language` IS A PARAMETER AND NOT A FIELD ON THE VALUE. A `PValue` is one
  ## node of a tree and the recording's language is a property of the session;
  ## putting it on the value would mean every adapter stamping every node with
  ## the same string, and a nested node that disagreed with its parent would be
  ## unrepresentable-in-principle and constructible-in-practice.
  let vis = winningVisualiser(v, presenters, language)
  if vis < 0:
    return resolveBuiltin(v, presenters)
  # The visualiser tier won. §5.4 asks that a user be able to ask WHICH
  # visualiser rendered a value and get an answer, and that the answer say what
  # it beat — so `candidates` carries the winner, then every other visualiser
  # that matched, then every built-in that would have claimed the value. A
  # single-element list would mean the winner won unopposed, and that is a
  # different fact.
  let winner = presenters.visualisers[vis]
  var candidates: seq[string] = @[winner.id]
  for i, other in presenters.visualisers:
    if i != vis and typeMatches(other.matchKind, other.typeMatch,
                                other.language, v.typeName, language):
      candidates.add other.id
  for id in resolveBuiltin(v, presenters).candidates:
    candidates.add id
  Attribution(
    tier: effectiveTier(winner), presenter: winner.id,
    matched: "type=" & v.typeName & " (" & $winner.matchKind &
             (if winner.language.len > 0: ", language=" & winner.language
              else: "") & ")",
    rank: winner.rank, candidates: candidates)

# ---------------------------------------------------------------------------
# Delimiters
# ---------------------------------------------------------------------------

func sequenceDelimiters(v: PValue; lang: PresentationLang): (string, string) =
  ## The brackets a positional container is drawn with.
  ##
  ## From the ENGINE's own kind name plus the language, reproducing
  ## `text_representation.textReprDefault`'s table (`@[`, `{`, `HashSet{`,
  ## `OrderedSet{`, `[`, `varargs[`) and `textReprRust`'s `vec![`. This is the
  ## one place the surfaces genuinely disagreed for a defensible reason
  ## — the desktop was language-aware and the terminal's decoder was not — and
  ## the disagreement is resolved by keeping the language-aware answer, because
  ## the terminal losing `vec![` was a loss of information rather than a
  ## simplification.
  if lang == plRust:
    let open = if v.sourceKind == "Array": "[" else: "vec!["
    return (open, "]")
  case v.sourceKind
  of "Set": ("{", "}")
  of "HashSet": ("HashSet{", "}")
  of "OrderedSet": ("OrderedSet{", "}")
  of "Array": ("[", "]")
  of "Varargs": ("varargs[", "]")
  of "Slice": ("[", "]")
  else: ("@[", "]")

func recordOpenClose(lang: PresentationLang): (string, string) =
  ## `Type(a:1)` by default, `Type{a:1}` under Rust — `textReprRust`'s shape.
  if lang == plRust: ("{", "}") else: ("(", ")")

# ---------------------------------------------------------------------------
# Numbers, both ways — moved here from
# `tui/app/formatters/type_formatters.nim`, which is the only place they used
# to exist and therefore the only surface that had them.
# ---------------------------------------------------------------------------

func toHexLiteral*(decimal: string): string =
  ## `42` -> `0x2a`, `-42` -> `-0x2a`, and "" for anything that does not fit a
  ## `BiggestInt`.
  ##
  ## An out-of-range integer answers "" rather than a wrapped value: the whole
  ## point of showing hex beside decimal is that the two say the same thing, and
  ## a silently truncated companion says something else.
  if not isDecimalIntegerText(decimal):
    return ""
  var negative = false
  var body = decimal
  if body[0] == '-':
    negative = true
    body = body[1 .. ^1]
  elif body[0] == '+':
    body = body[1 .. ^1]
  var acc: BiggestInt = 0
  for c in body:
    let digit = BiggestInt(ord(c) - ord('0'))
    if acc > (high(BiggestInt) - digit) div 10:
      return ""
    acc = acc * 10 + digit
  const NibblesInBiggestInt = sizeof(BiggestInt) * 2
  let hex = toLowerAscii(toHex(acc, NibblesInBiggestInt))
              .strip(chars = {'0'}, trailing = false)
  let digits = if hex.len == 0: "0" else: hex
  (if negative: "-0x" else: "0x") & digits

func unquotedText(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': s[1 ..< s.high] else: s

func fromHexLiteral*(hex: string): string =
  ## `0x2a` -> `42`, and "" for a VALUE too large for a `BiggestInt`.
  ##
  ## The bound is on the value, not on the literal's width: a Noir field element
  ## is written as 64 hex digits whatever it holds, so `0x000…2710` answers
  ## `10000` and only a genuinely wide element answers "".
  let body = unquotedText(hex)
  if not isHexLiteralText(body):
    return ""
  var acc: BiggestInt = 0
  for i in 2 ..< body.len:
    let c = body[i]
    let digit =
      if c in {'0' .. '9'}: BiggestInt(ord(c) - ord('0'))
      elif c in {'a' .. 'f'}: BiggestInt(ord(c) - ord('a') + 10)
      else: BiggestInt(ord(c) - ord('A') + 10)
    if acc > (high(BiggestInt) - digit) div 16:
      return ""
    acc = acc * 16 + digit
  $acc

func normalisedHexLiteral*(hex: string): string =
  ## A `0x…` literal with its leading zeros removed, so a 32-byte field element
  ## reads `0x7d0` rather than as sixty characters of padding a reader has to
  ## count through. `0x000…0` normalises to `0x0`.
  let body = unquotedText(hex)
  if not isHexLiteralText(body):
    return body
  var i = 2
  while i < body.high and body[i] == '0':
    inc i
  "0x" & body[i .. ^1].toLowerAscii()

func formatByteBuffer*(bytes: openArray[int]; maxBytes: int): string =
  ## `01 02 ff … (12 bytes)` — a hex dump bounded by `maxBytes`, with the full
  ## length always reported so the bound cannot be mistaken for the buffer.
  var parts: seq[string] = @[]
  for i in 0 ..< min(bytes.len, max(0, maxBytes)):
    parts.add toLowerAscii(toHex(bytes[i], 2))
  var text = parts.join(" ")
  if bytes.len > maxBytes:
    if text.len > 0: text.add " "
    text.add Ellipsis
  if text.len > 0: text.add " "
  text & "(" & $bytes.len & " bytes)"

func mediaLabel*(mediaType: string; bytes: int): string =
  ## `<image/png, 2048 bytes>` — media named and measured, in one line.
  ##
  ## ONE SPELLING, TWO PRODUCERS (§14). A `pvkMedia` value that arrived as
  ## media already goes through `mediaSummary` below; a §5.2 visualiser
  ## DECLARATION over an ordinary value goes through `visualisedMediaText`.
  ## Two literals would be two answers to "how is media written down", and the
  ## two would have to stay in step for the corpus's cross-surface byte
  ## identity to mean anything.
  let kindText =
    if mediaType.len > 0: mediaType else: mediaTypeSpelling(mcOctetStream)
  if bytes > 0: "<" & kindText & ", " & $bytes & " bytes>"
  else: "<" & kindText & ">"

func mediaSummary*(v: PValue): string =
  ## What a surface WITHOUT pixels shows for a `pvkMedia` value.
  ##
  ## This is the degradation Project-Definitions §5.2 requires ("an image, at
  ## whatever fidelity the surface allows") and it is specified here rather
  ## than in PLAT-12 because it is a BUDGET question: a one-line surface has
  ## no fidelity to offer, and what it shows instead is the presenter's answer,
  ## not the surface's.
  mediaLabel(v.mediaType, v.mediaBytes)

# ---------------------------------------------------------------------------
# Inline rendering
# ---------------------------------------------------------------------------

func vocabularyKindOf(v: PValue): PresentationKind =
  ## The PLAT-3 view a value inhabits.
  if v.isNil:
    return pkText
  case v.kind
  of pvkMedia: pkImage
  of pvkMap: pkTable
  of pvkRecord, pvkVariant: pkTree
  of pvkSequence, pvkTuple: pkList
  of pvkPointer, pvkReference:
    if v.target.isNil: pkText else: pkTree
  else: pkText

type
  RenderTally = object
    ## What one rendering ACCUMULATED, threaded through the recursion.
    ##
    ## Two `var` parameters became one object when PLAT-12 added the second.
    ## That is not cosmetic: `truncated` and `gaps` are both facts the whole
    ## tree contributes to, and a recursive helper that took one and forgot the
    ## other would drop the forgotten one silently — which is exactly how a
    ## media gap on a nested member would have gone missing while the node's
    ## own gap was reported.
    truncated: bool
    gaps: seq[MediaGap]
    work: int
      ## PLAT-12. What this rendering has SPENT so far, in `MaxRenderWork`'s
      ## units: one per inline rendering entered, one per byte produced, and
      ## one per element of the recording each of that frame's O(n) walks may
      ## touch — the value's own members, the rules the visualiser scan
      ## compares, and the field a §5.2 declaration named. See
      ## `vocabulary.ExpansionBound` for why a presentation needs a work bound
      ## at all, `inlineText` for the one place the bound is TESTED, and the
      ## block above `memberScanCost` for why the charges are at five sites and
      ## what the version that charged at one reported while it was being
      ## overrun.
    exhausted: bool
      ## Whether the bound was reached. It is on the TALLY and not a return
      ## value for the reason `truncated` is: it is a fact the whole tree
      ## contributes to, and a helper that took one and forgot the other would
      ## drop the forgotten one silently.
    exhaustedIn: string
      ## The id of the visualiser whose expansion was in progress when the
      ## bound was reached, or "" when none was. FIRST WRITER WINS and the
      ## first writer is the DEEPEST frame, because the stack unwinds from the
      ## point the bound was reached — which is the rule a reader has to edit,
      ## rather than whichever rule happened to be outermost.

func noteGap(tally: var RenderTally; gap: MediaGap) =
  ## Record a gap, once, up to `MaxMediaGaps`.
  ##
  ## DEDUPLICATED BEFORE BOUNDED. One member is rendered twice in an ordinary
  ## presentation — once inside its parent's inline text and once as its own
  ## node — so a gap that was merely appended would appear twice for one
  ## declaration, and a reader would be told about two problems when there is
  ## one. The comparison is on the whole gap: two DIFFERENT fields of one value
  ## declaring the same media type are two gaps and stay two, because the
  ## `bytes` and `fieldPresent` they carry differ.
  ##
  ## The scan is linear in a list bounded by `MaxMediaGaps`, so this is O(1) in
  ## everything the recording or the declaration controls.
  for existing in tally.gaps:
    if existing == gap: return
  if tally.gaps.len >= MaxMediaGaps: return
  tally.gaps.add gap

# ---------------------------------------------------------------------------
# The work bound's THREE charges, each at the point the work is spent
# ---------------------------------------------------------------------------
#
# ## WHY THREE AND NOT ONE, AND WHAT THE FIRST VERSION OF THIS GOT WRONG
#
# `MaxRenderWork` was first charged in one place — `inlineText`, one unit for
# entering a frame and one per byte produced — under the argument that a funnel
# every rendering passes through is the one place to charge (§14). The funnel
# part of that is right and is unchanged. The UNIT was wrong: a frame's cost is
# not one plus its output, because three of the things a frame does are
# proportional to the RECORDING and appear in neither number.
#
# Measured on 2026-09-12, release build, `Node { next: Node, payload: <bytes> }`
# at the state panel's depth, against the 200-byte declaration in
# `value_visualisers_test`'s own case — which the loader and `admit` both
# accept:
#
#   | field bytes | before | after | `spent` before | `spent` after |
#   |---|---|---|---|---|
#   | 1,000 | 51 ms | 12 ms | 1,048,582 | 1,048,634 |
#   | 10,000 | 415 ms | 12 ms | 1,048,582 | 1,050,044 |
#   | 200,000 | **19,511 ms** | **12 ms** | 1,048,582 | 1,236,554 |
#
# `spent` was IDENTICAL in all three runs before, which is the tell: the
# counter said the same number while the process did two hundred times the
# work. A bound whose report is constant in the quantity being multiplied is a
# bound on the wrong quantity, and it does not merely fail to stop the attack —
# it REPORTS that it honoured an allowance it never measured.
#
# So each charge below is at the site that spends it, and each names the
# quantity it prices. §14 is satisfied by there being ONE function per
# quantity, called from every site that spends it, rather than by there being
# one function in total: a second copy of "how much does a media field cost"
# would be the duplication §14 is about, and three copies of the same *number*
# is what the first version had.

func memberScanCost(v: PValue): int =
  ## How many of `v`'s OWN members one inline rendering of `v` may walk.
  ##
  ## THREE WALKS, NONE OF THEM VISIBLE IN THE OUTPUT'S LENGTH. `byteBufferOf`
  ## runs twice over a `pvkSequence` — once in `resolveBuiltin`'s contents test
  ## for `builtin.byte-buffer`, once in `builtinInlineText`'s
  ## `formatByteBuffer` — and walks every member, allocating a `seq[int]` slot
  ## per member, before `formatByteBuffer` prints at most `budget.members` of
  ## them. `joinMembers`' hidden-member scan is the third and applies to every
  ## kind that has members. All three are O(`members.len`) while the output
  ## they contribute to is capped by the budget, so none of them is priced by
  ## the byte charge.
  ##
  ## THIS IS THE HALF THE MEDIA CHARGE DOES NOT COVER, and it needs no
  ## declaration at all: a summary naming one byte field sixteen times reaches
  ## it through the BUILT-IN path, with no `media` key anywhere. Measured at
  ## 200,000 bytes: 474 ms with `spent` at 105,513 — a tenth of the bound, so
  ## the rendering was not even stopped, which is worse than being stopped.
  ##
  ## AND A THIRD WALKER SHARES THIS FUNCTION: `chargedMemberNamed`, which
  ## prices `memberNamed`'s equality scan over the same list. It is the same
  ## quantity asked by a different question — "how long is the member list" —
  ## so it is the same function and not a fourth number (§14).
  ##
  ## ## ONE CONSTANT FACTOR IS KNOWINGLY LEFT OUT, AND IT IS PRICED HERE
  ## ## RATHER THAN LEFT TO BE FOUND
  ##
  ## The hidden-member walk calls `isHidden` per member, which is a scan of
  ## `MaxHiddenFields` (64) names — so its true cost is `members * 64` and this
  ## charges `members`. The factor is a constant and BOTH of its inputs are
  ## already bounded: the members by this charge, the hide list by PLAT-11's
  ## own constant, so the total is 64 × `MaxRenderWork` string comparisons —
  ## tens of milliseconds, not a hang, and it cannot be multiplied by anything
  ## the declaration or the recording adds. It is stated because an unstated
  ## constant factor is exactly what the first version of this bound was made
  ## of, and the way to not repeat that is to write down the ones that remain
  ## rather than to imply there are none.
  ##
  ## CHARGED AT THE PLACES THAT WALK, NOT ONCE PER FRAME. `inlineText` is
  ## the wrong site for it even though it is the funnel: a rule answering with
  ## a SUMMARY never reaches `builtinInlineText` and walks nothing, so charging
  ## at the funnel would bill a declaration for work it did not cause — and a
  ## charge that is wrong in the safe direction is still a wrong charge,
  ## because `spent` is a number a reader is invited to watch approaching.
  if v.isNil: 0 else: v.members.len

func mediaScanCost(m: PValue): int =
  ## What `declaredMediaBytes` SPENDS on the member a §5.2 rule named.
  ##
  ## Its `pvkSequence` arm calls `byteBufferOf`, which walks and allocates a
  ## `seq[int]` as long as the field, and its other arms read a field. So the
  ## cost is the member count and nothing else — and it is charged against the
  ## member the DECLARATION named rather than against the value being rendered,
  ## which is why this is a second function and not `memberScanCost` again.
  if m.isNil or m.kind != pvkSequence: 0 else: m.members.len

func visualiserScanCost(v: PValue; presenters: PresenterSet): int =
  ## What one `winningVisualiser` scan may spend on `v`.
  ##
  ## `winningVisualiser`'s own doc comment names the cost — bounded by
  ## `MaxVisualiserRules` and by `typeMatch.len` per entry — and BOTH of those
  ## numbers are the declaration's: 256 × 200 = 51,200 byte comparisons per
  ## rendered node, from a file a `git clone` brought with it. Bounded per
  ## frame is not bounded per presentation, and the frame count is itself the
  ## thing `MaxRenderWork` was supposed to bound, so the two compose.
  ##
  ## THE COST IS THE BYTES THE COMPARISONS MAY EXAMINE, not the rule count.
  ## `typeMatches` is three total string comparisons that stop at the shorter
  ## operand, so a rule whose match is a different LENGTH from the type name is
  ## O(1) and a rule sharing 199 of 200 bytes with it is O(200) — which is
  ## exactly the difference a decoy exploits. Charging the rule count alone
  ## would leave a factor of `MaxTypeMatchBytes` unpriced.
  ##
  ## IT IS ZERO WHEN THE TIER IS EMPTY, which is every call this repository
  ## makes today and every call a build with no project definitions makes
  ## (§5.5): no visualisers, no scan, no charge, and `spent` is byte-for-byte
  ## what it was before this charge existed.
  if v.isNil: return 0
  let nameLen = v.typeName.len
  for vis in presenters.visualisers:
    result += 1 + min(vis.typeMatch.len, nameLen)

func chargedWinner(v: PValue; presenters: PresenterSet; language: string;
                   tally: var RenderTally): int =
  ## `winningVisualiser`, charged to the rendering that runs it.
  ##
  ## THE ONLY WAY A RENDERING RESOLVES A VISUALISER (§14): `inlineText` and
  ## `renderNode` both come through here, so there is one charge for one scan
  ## and not two copies of a number. `resolve` deliberately does NOT — it runs
  ## once per presentation rather than once per node, it has no tally, and it
  ## is the function a caller asks "which presenter drew this" outside a
  ## rendering entirely.
  ##
  ## THE CHARGE STOPS WHEN THE ALLOWANCE DOES, AND THE SCAN DOES NOT. That
  ## asymmetry is deliberate and is the opposite of `chargedMediaBytes` below.
  ## The scan's ANSWER is used by the node — its declared presentation and its
  ## media type are both stamped from it, above `renderNode`'s exhaustion
  ## return — so skipping it would change what an elided node reports about a
  ## rule that did match it. What is skipped is the charge, for `inlineText`'s
  ## own reason: `spent` is what was spent before the rendering stopped, not
  ## what the unwinding stack spent afterwards. The unwind is bounded by
  ## `Budget.depth * Budget.members` scans and by nothing the recording
  ## controls.
  ##
  ## AND THAT SENTENCE HAS EVIDENCE NOW, WHICH IT DID NOT UNTIL 2026-09-12.
  ## A verification pass ran the opposite arm — answer "no rule" once
  ## exhausted — and the whole suite was green, byte for byte, because no case
  ## had a node that was BOTH elided AND claimed by a rule with something to
  ## declare. `renderNode`'s child loop does not stop when the allowance does
  ## (only the descent below each node does), so every sibling after the one
  ## that exhausted the budget is such a node.
  ## `value_visualisers_test`'s "an ELIDED node still reports the rule that
  ## claimed it" is that case: two elided siblings of one exhausted rendering,
  ## one carrying a declared `Image` presentation and `image/png`, the other
  ## keeping the value's own shape and no media type — two different answers
  ## that a scan returning -1 would collapse into one.
  if not tally.exhausted:
    tally.work += visualiserScanCost(v, presenters)
  winningVisualiser(v, presenters, language)

func isHidden(hide: openArray[string]; label: string): bool =
  ## §5.3's "what it hides". Exact equality against a member's label, over a
  ## list PLAT-11 bounds at `MaxHiddenFields`.
  ##
  ## A POSITIONAL MEMBER IS NEVER HIDDEN, because its label is "" and a rule
  ## hiding "" would hide every element of every sequence it matched. That is
  ## not a refusal — nothing to refuse, since an empty hide entry is already
  ## refused at parse and again at admission — it is the reason the guard is
  ## written as `label.len > 0` rather than as a bare membership test.
  if label.len == 0: return false
  for h in hide:
    if h == label: return true
  false

func inlineText(v: PValue; ctx: PresentationContext; depth: int;
                presenters: PresenterSet; tally: var RenderTally): string

func joinMembers(v: PValue; ctx: PresentationContext; depth: int;
                 presenters: PresenterSet; tally: var RenderTally;
                 labelled: bool; hide: openArray[string]): string =
  ## The comma-separated member list, ELIDED BY THE BUDGET rather than
  ## rendered in full and cut afterwards.
  ##
  ## This is the deliverable. `textRepr` rendered all ten thousand elements of
  ## a ten-thousand-element sequence and left the surface to clip the resulting
  ## string; `flow.nim` then measured that string's `.len` twice per value to
  ## decide whether to show a "view more" button. Here the loop STOPS at
  ## `budget.members`, so the cost of a one-line rendering of a 600-entry
  ## mapping is bounded by the budget and not by the recording.
  ##
  ## A HIDDEN MEMBER IS NOT IN THE TOTAL, AND THAT IS THE POINT OF HIDING.
  ## Counting hidden fields against `budget.members` would let a rule that
  ## hides four of a six-field record produce `Type(a:1, …)` on a surface with
  ## room for five — the reader would be shown an elision that is a fact about
  ## the rule rather than about the budget, which is the one distinction
  ## `Presentation.truncated` exists to keep straight.
  var visible: seq[int] = @[]
  for i in 0 ..< v.members.len:
    if not isHidden(hide, v.members[i].label): visible.add i
  let total = visible.len
  let cap = if ctx.budget.members <= 0: 0 else: min(ctx.budget.members, total)
  var parts: seq[string] = @[]
  for k in 0 ..< cap:
    let m = v.members[visible[k]]
    let rendered = inlineText(m.value, ctx, depth + 1, presenters, tally)
    if labelled and m.label.len > 0:
      parts.add m.label & ":" & rendered
    else:
      parts.add rendered
  if cap < total:
    tally.truncated = true
    parts.add Ellipsis
  parts.join(", ")

func joinEntries(v: PValue; ctx: PresentationContext; depth: int;
                 presenters: PresenterSet; tally: var RenderTally): string =
  let total = v.entries.len
  let cap = if ctx.budget.members <= 0: 0 else: min(ctx.budget.members, total)
  var parts: seq[string] = @[]
  for i in 0 ..< cap:
    let e = v.entries[i]
    parts.add inlineText(e.key, ctx, depth + 1, presenters, tally) & ": " &
              inlineText(e.val, ctx, depth + 1, presenters, tally)
  if cap < total:
    tally.truncated = true
    parts.add Ellipsis
  parts.join(", ")

func builtinInlineText(v: PValue; ctx: PresentationContext; depth: int;
                       presenters: PresenterSet; tally: var RenderTally;
                       hide: openArray[string]): string =
  ## One value as ONE line, at the current budget, by the BUILT-IN table.
  ##
  ## THE ONE RENDERING. Seven implementations of this function existed when
  ## PLAT-2 was written — `textReprDefault`, `textReprRust`, `text`/`$`,
  ## `headless_session.extractValueText`, `calltrace.safeCallArgText`,
  ## `db-backend/src/value.rs::text_repr` and `src/tui/src/value.rs::text_repr`.
  ## The first five are Nim and are collapsed into this one; the two Rust ones
  ## are named in `ci/test/value-presentation-boundary.sh`'s declared scope as
  ## OUT of it, because a Nim import lint cannot reach them.
  ##
  ## PLAT-12 SPLIT IT IN TWO AND CHANGED NOTHING IN THIS HALF. `inlineText`
  ## below decides whether a visualiser claims the value; this is what happens
  ## when none does, and it is also what a visualiser that only HIDES fields
  ## falls back to — which is why `hide` is a parameter here rather than a
  ## branch above. With `hide` empty every line below is byte-for-byte what it
  ## was before this milestone (§5.5).
  ##
  ## AND IT IS WHERE THE MEMBER WALKS ARE PAID FOR, because it is where they
  ## happen: `resolveBuiltin` runs `byteBufferOf` over a sequence, the
  ## `builtin.byte-buffer` arm runs it a second time, and `joinMembers` walks
  ## every member to find the hidden ones. A rule that answers with a SUMMARY
  ## never reaches this function and correctly pays none of it. See
  ## `memberScanCost`.
  tally.work += memberScanCost(v)
  let attribution = resolveBuiltin(v, presenters)
  case attribution.presenter
  of "builtin.media":
    mediaSummary(v)
  of "builtin.error":
    # `<error: msg>`. Chosen over `textRepr`'s bare `msg` because a bare
    # message is indistinguishable from a recorded string, and over
    # `trace.nim`'s `<span class=error-trace>` because a span is HTML and this
    # layer has no medium. The three surfaces that wanted the distinction get
    # it from `class == pcError` instead.
    "<error: " & v.text & ">"
  of "builtin.byte-buffer":
    formatByteBuffer(byteBufferOf(v), max(1, ctx.budget.members))
  of "builtin.pointer":
    let address =
      if v.text.len == 0: (if v.kind == pvkReference: "" else: "NULL")
      else: v.text
    if v.target.isNil:
      if address.len == 0: "nil" else: address
    elif address.len == 0:
      inlineText(v.target, ctx, depth, presenters, tally)
    else:
      address & " -> (" & inlineText(v.target, ctx, depth + 1, presenters, tally) & ")"
  of "builtin.variant":
    let head =
      if v.typeName.len > 0 and v.variantName.len > 0:
        v.typeName & "::" & v.variantName
      elif v.variantName.len > 0: v.variantName
      else: v.typeName & "::?"
    if v.members.len == 0: head
    else: head & "(" & joinMembers(v, ctx, depth, presenters, tally, true, hide) & ")"
  of "builtin.map":
    "{" & joinEntries(v, ctx, depth, presenters, tally) & "}"
  of "builtin.record":
    let (open, close) = recordOpenClose(ctx.lang)
    v.typeName & open &
      joinMembers(v, ctx, depth, presenters, tally, true, hide) & close
  of "builtin.tuple":
    "(" & joinMembers(v, ctx, depth, presenters, tally, false, hide) & ")"
  of "builtin.sequence":
    let (open, close) = sequenceDelimiters(v, ctx.lang)
    var body = joinMembers(v, ctx, depth, presenters, tally, false, hide)
    if v.partial:
      # The RECORDING is short, not the budget. Reported with `..` — the
      # engine's own `partiallyExpanded` spelling — so a reader can tell the
      # two apart from the glyph alone: `…` is the pane, `..` is the trace.
      body.add ".."
    open & body & close
  of "builtin.enum":
    if v.enumName.len > 0: v.enumName
    else: v.typeName & "(" & v.text & ")"
  of "builtin.function":
    "function<" & (if v.text.len > 0: v.text else: v.typeName) & ">"
  of "builtin.scalar":
    case v.kind
    of pvkNil: "nil"
    of pvkString, pvkCString: "\"" & v.text & "\""
    of pvkChar: "'" & v.text & "'"
    else:
      # AN EMPTY PAYLOAD IS NAMED, NOT LEFT BLANK.
      #
      # A malformed `Int` — one whose `i` the engine omitted — used to render
      # "". `headless_session`'s own header records why that is the dangerous
      # outcome: `app/source_binding.annotationsFrom` DROPS a variable whose
      # value is empty on the grounds that "the formatter had nothing to
      # print", and a step-to-step diff over rendered text cannot see a change
      # between two values that both render as "". So a blank is reported as a
      # blank instead of disappearing.
      if v.text.len > 0: v.text
      elif v.typeName.len > 0: "<" & v.typeName & ": no value>"
      elif v.sourceKind.len > 0: "<" & v.sourceKind & ": no value>"
      else: "<no value>"
  else:
    # `builtin.opaque` and `builtin.none`. The payload is emitted rather than
    # "" because "" is indistinguishable from "the debugger has no value for
    # this" on every surface downstream — the same reason
    # `extractValueText`'s `else` arm gave.
    case v.kind
    of pvkRecursion: "this"
    of pvkNotExpanded: ".."
    else:
      if v.text.len > 0: v.text
      elif v.typeName.len > 0: "<" & v.typeName & ">"
      else: "<" & v.sourceKind & ">"

# ---------------------------------------------------------------------------
# PLAT-12 — the visualiser tier's own rendering
# ---------------------------------------------------------------------------

func memberNamed(v: PValue; label: string): PValue =
  ## The member of `v` labelled `label`, or nil.
  ##
  ## EQUALITY OVER LABELS, AND NOTHING ELSE. This is the whole of what a
  ## `mediaFrom` or a `{placeholder}` does with the name a cloned repository
  ## wrote: it is compared to the labels the RECORDING produced. It is not a
  ## path, not a key into any table this process owns, and not a selector —
  ## there is no `.` traversal, no index syntax and no wildcard, so the search
  ## space is `v.members` and the cost is its length.
  ##
  ## AND THAT COST IS THE POINT, WHICH IS WHY NO RENDERING CALLS THIS DIRECTLY.
  ## The sentence above — "the cost is its length" — was in this header before
  ## the work bound existed and was read as a reassurance. It is not one: a
  ## summary makes up to `MaxTemplatePlaceholders` of these PER FRAME, over a
  ## member list the RECORDING sizes, and a rule whose placeholders name a
  ## field at the end of a long member list (or no field at all) pays the full
  ## length every time. Measured on 2026-09-12, sixteen placeholders over a
  ## 100,000-member record at the state panel's depth: **4,118 ms for one
  ## value**, with a work counter that moved by 100,000 — one node's worth —
  ## because nothing here was charged. Every call site inside a rendering goes
  ## through `chargedMemberNamed`.
  if v.isNil: return nil
  for m in v.members:
    if m.label == label: return m.value
  nil

func chargedMemberNamed(tally: var RenderTally; v: PValue;
                        label: string): PValue =
  ## `memberNamed`, charged to the rendering that looks it up.
  ##
  ## THE ONLY WAY A RENDERING RESOLVES A DECLARED FIELD NAME (§14): the
  ## template's placeholders, the `media` rule's field in `visualisedText` and
  ## the same rule's field in `renderNode` all come through here, so the scan
  ## is priced once wherever it happens.
  ##
  ## THE CHARGE STOPS WHEN THE ALLOWANCE DOES, AND THE SCAN DOES NOT, for
  ## `chargedWinner`'s reason rather than `chargedMediaBytes`': the answer is
  ## the FIELD, and a `substituteSummary` loop that started getting `nil` back
  ## half way through would emit `<no field 'x'>` for placeholders whose field
  ## is there — turning a rendering that ran out of allowance into a rendering
  ## that reports a wrong declaration. The unwind is bounded by
  ## `Budget.depth * MaxTemplatePlaceholders` scans.
  ##
  ## AND THAT CONSEQUENCE IS ASSERTED NOW, WHICH IT WAS NOT UNTIL 2026-09-12.
  ## The sentence above states a user-visible outcome exactly and nothing in
  ## the 52-case suite said so: a verification pass ran the opposite arm — the
  ## lookup itself skipped once exhausted — and every case stayed green.
  ## Measured on the recursive-summary case's own value, whose every `Node`
  ## carries the `next` its summary names at every level: **69 occurrences of
  ## `<no field`** in a rendering that had one reason to stop and reported a
  ## different one. `value_visualisers_test`'s "a summary that re-enters its
  ## own type is bounded by WORK, not depth" now asserts the string is absent,
  ## and its positive twin — "a placeholder naming a field the value lacks is
  ## REPORTED, not blanked" — runs through this same function, so a renderer
  ## that stopped emitting the message altogether reddens that one instead.
  if not tally.exhausted:
    tally.work += memberScanCost(v)
  memberNamed(v, label)

func declaredMediaBytes(m: PValue): int =
  ## How many bytes the field a §5.2 rule pointed at holds.
  ##
  ## TOTAL over every kind, because the rule is data from a repository and the
  ## value is data from a recording and neither was written with the other in
  ## view. A field that is not bytes in any recognisable sense answers 0, and 0
  ## is reported as 0 — `<image/png>` without a size — rather than as an error,
  ## because "the project says these are PNG bytes and we cannot tell how many"
  ## is a true thing to show and a guess is not.
  ##
  ## IT IS O(m.members.len) AND NO RENDERING CALLS IT DIRECTLY. The
  ## `pvkSequence` arm walks and allocates a `seq[int]` as long as the field,
  ## and every call site inside a rendering goes through `chargedMediaBytes`
  ## so that walk is paid for. See `mediaScanCost`.
  if m.isNil: return 0
  case m.kind
  of pvkMedia: m.mediaBytes
  of pvkSequence:
    let bytes = byteBufferOf(m)
    if bytes.len > 0: bytes.len else: m.members.len
  of pvkString, pvkCString: m.text.len
  else: 0

func chargedMediaBytes(tally: var RenderTally; m: PValue): int =
  ## `declaredMediaBytes`, charged to the rendering that pays for it.
  ##
  ## THE ONLY WAY THE RENDERER ASKS HOW BIG A DECLARED FIELD IS (§14). Three
  ## sites read that size — `mediaGapFor` when the surface cannot draw,
  ## `visualisedText` when it can, and `renderNode` when it stamps the node —
  ## and all three now come through here, so the walk is priced once wherever
  ## it happens rather than by three copies of the same reasoning.
  ##
  ## THE WALK STOPS WHEN THE ALLOWANCE DOES, which is the opposite of
  ## `chargedWinner`'s rule and for the opposite reason: a size shown beside a
  ## line that is already the elision glyph is a number nobody is reading, so
  ## answering 0 for it says "this rendering did not look" and costs nothing —
  ## whereas the winner's answer decides what the node reports about itself.
  ## `renderNode` reaches this after `inlineText` has exhausted the allowance,
  ## and without the short-circuit the unwind would pay `Budget.depth *
  ## Budget.members` full walks of a field the recording sizes.
  if tally.exhausted: return 0
  tally.work += mediaScanCost(m)
  declaredMediaBytes(m)

func substituteSummary(vis: Visualiser; v: PValue; ctx: PresentationContext;
                       depth: int; presenters: PresenterSet;
                       tally: var RenderTally): string =
  ## §5.2's templating: `"{rows}x{cols}"` over the value's field names.
  ##
  ## ONE LINEAR PASS OVER THE TEMPLATE, AND THE OUTPUT IS NEVER RE-SCANNED.
  ## The loop walks `vis.summary` once, left to right, and a field's
  ## substituted text is appended to the result rather than pushed back onto
  ## the input. A value whose own rendering contains `{cols}` therefore cannot
  ## make a second placeholder appear, so there is no fixed point to reach in
  ## the TEXT.
  ##
  ## ## THAT IS NOT THE SAME AS "THERE IS NO RECURSION", AND THIS COMMENT USED
  ## ## TO SAY IT WAS
  ##
  ## It read *"no depth to bound and no budget to spend"*, and that was wrong
  ## in the direction that costs most: a placeholder is substituted by
  ## RENDERING the named field through the whole pipeline, so
  ## `substituteSummary` -> `inlineText` -> `winningVisualiser` ->
  ## `visualisedText` -> `substituteSummary` is a cycle. A rule matching a type
  ## that contains itself re-enters its own template once per placeholder, with
  ## branching factor `MaxTemplatePlaceholders` (16) and levels bounded only by
  ## `Budget.depth` — 7 on the state panel, 10 on `flow`, 16 on the terminal's
  ## tree. Measured: 4.29 GB of text and 125 seconds for ONE value from a
  ## 200-byte declaration. The table and the argument are in
  ## `vocabulary.ExpansionBound`; the bound is `MaxRenderWork` and it is
  ## TESTED in `inlineText`, which is the one funnel every one of those
  ## renderings goes through.
  ##
  ## Nothing in THIS function tests it, deliberately: a second check here
  ## would be a second answer to "how much may a rendering spend" (§14), and
  ## the recursion does not pass through this function on every level — it
  ## passes through `inlineText` on every level, which is why that is where the
  ## test is. *The CHARGES are a different question and are not all there
  ## either* — see the block above `memberScanCost` for which quantity is
  ## charged where, and for the measurement that says why "one check in one
  ## funnel" was not the same claim as "the work is bounded".
  ##
  ## `{{` IS A LITERAL BRACE, matching the validator PLAT-11 already applies at
  ## parse time (`parse.templateProblem`). This function does NOT re-validate:
  ## a malformed template is refused before it becomes a `Visualiser` (at parse
  ## AND again at admission), and the arms below are written to be total for an
  ## unvalidated one anyway — an unterminated `{` emits the rest of the summary
  ## verbatim rather than reading past the end.
  ##
  ## A PLACEHOLDER NAMING A FIELD THE VALUE DOES NOT HAVE IS REPORTED IN PLACE,
  ## not blanked. `<no field 'rows'>` is ugly on purpose: the project wrote a
  ## rule about a type and the value it matched does not have the field, which
  ## is a thing the project's author has to see. Silently emitting "" would
  ## make a wrong rule look like a value with an empty field, and PLAT-2's own
  ## header records what a blank costs — `annotationsFrom` DROPS a variable
  ## whose rendering is empty.
  var acc = ""
  var i = 0
  while i < vis.summary.len:
    let c = vis.summary[i]
    if c == '{':
      if i + 1 < vis.summary.len and vis.summary[i + 1] == '{':
        acc.add '{'
        i += 2
        continue
      var j = i + 1
      while j < vis.summary.len and vis.summary[j] != '}':
        inc j
      if j >= vis.summary.len:
        # Unterminated. Emit what is there and stop; see the header.
        acc.add vis.summary[i .. ^1]
        break
      let name = vis.summary[i + 1 ..< j]
      # CHARGED, AND THIS IS THE LOOP THAT MADE IT NECESSARY: up to
      # `MaxTemplatePlaceholders` equality scans over a member list the
      # RECORDING sizes, per frame, none of which shows up in the text this
      # frame returns. See `chargedMemberNamed`.
      let field = chargedMemberNamed(tally, v, name)
      if field.isNil:
        acc.add "<no field '" & name & "'>"
      else:
        acc.add inlineText(field, ctx, depth + 1, presenters, tally)
      i = j + 1
    else:
      acc.add c
      inc i
  acc

func mediaGapFor(vis: Visualiser; ctx: PresentationContext; field: PValue;
                 tally: var RenderTally): MediaGap =
  ## The gap a §5.2 declaration this surface cannot honour leaves behind.
  ##
  ## IT TAKES THE TALLY BECAUSE IT SPENDS. `noteGap` deduplicates, but it
  ## deduplicates a gap this function has already BUILT — so the walk behind
  ## `bytes` happens once per frame whether or not the gap is new, which is
  ## where the 19.5 seconds above were going.
  ##
  ## AND IT TAKES THE FIELD RATHER THAN LOOKING IT UP. Its caller has already
  ## resolved `vis.mediaFrom` and a second lookup would be a second O(members)
  ## scan for an answer already in hand — §14's rule applied to a LOOKUP: one
  ## resolution per frame, passed down, rather than three call sites each
  ## asking the recording again.
  MediaGap(mediaType: vis.mediaType, class: mediaClassOf(vis.mediaType),
           visualiser: vis.id, surface: ctx.budget.name,
           bytes: chargedMediaBytes(tally, field), fieldPresent: not field.isNil)

func surfaceDrawsMedia(ctx: PresentationContext; vis: Visualiser;
                       field: PValue): bool =
  ## Whether this surface can draw what this rule declared, over this value.
  ##
  ## THREE CONDITIONS, ALL OF THEM NECESSARY, and each is a separate reason a
  ## reader may be shown (see `describeMediaGap`): the media type has to be one
  ## this build classifies at all, the surface's budget has to claim that
  ## class, and the value has to actually carry the field the rule named.
  ##
  ## THE THIRD IS ASKED OF A FIELD THE CALLER ALREADY RESOLVED, for
  ## `mediaGapFor`'s reason: this used to take the VALUE and run its own
  ## `memberNamed`, which is the same scan its caller had just run, over a
  ## member list the recording sizes.
  let class = mediaClassOf(vis.mediaType)
  if class == mcUnknown: return false
  if class notin ctx.budget.media: return false
  not field.isNil

func visualisedText(vis: Visualiser; v: PValue; ctx: PresentationContext;
                    depth: int; presenters: PresenterSet;
                    tally: var RenderTally): string =
  ## What a value renders as once a visualiser has claimed it.
  ##
  ## §5.2's three declarable outcomes, in the order a rule's own fields put
  ## them:
  ##
  ##   1. MEDIA THIS SURFACE DRAWS. The value becomes its media label —
  ##      `<image/png, 2048 bytes>` — and the node carries the type and the
  ##      size so a surface with pixels has what it needs. No surface in this
  ##      repository has pixels yet; `application/octet-stream` is the one
  ##      class every budget claims, and this is the arm it takes.
  ##   2. MEDIA THIS SURFACE DOES NOT DRAW. A gap is recorded and the rendering
  ##      falls through to 3 — "the rest of the value still presents" is the
  ##      requirement, and a §8.2 degradation that BLANKED the value would be
  ##      the blank region §8.2 exists to forbid.
  ##   3. A SUMMARY TEMPLATE, or, when the rule declared none, the built-in
  ##      rendering with the rule's hidden fields removed. A rule that only
  ##      hides is the common case and must not have to restate the rendering.
  if vis.mediaType.len > 0:
    let field = chargedMemberNamed(tally, v, vis.mediaFrom)
    if surfaceDrawsMedia(ctx, vis, field):
      return mediaLabel(vis.mediaType, chargedMediaBytes(tally, field))
    tally.noteGap(mediaGapFor(vis, ctx, field, tally))
  if vis.summary.len > 0:
    return substituteSummary(vis, v, ctx, depth, presenters, tally)
  builtinInlineText(v, ctx, depth, presenters, tally, vis.hide)

func inlineText(v: PValue; ctx: PresentationContext; depth: int;
                presenters: PresenterSet; tally: var RenderTally): string =
  ## One value as ONE line, at the current budget — through whichever tier
  ## §5.4's precedence selected.
  ##
  ## The nil, depth and WORK guards are here rather than in either half
  ## because they are properties of the RECURSION and not of a tier: a
  ## visualiser matching a type eleven levels down must not be reached past the
  ## budget's depth, or a declaration would buy a project more of the pane than
  ## the surface offered.
  ##
  ## ## THIS IS THE ONE PLACE THE BOUND IS TESTED, AND IT IS ONE PLACE BECAUSE
  ## ## IT IS ONE FUNNEL. IT IS NOT THE ONLY PLACE WORK IS CHARGED.
  ##
  ## Every rendering of every value at every tier arrives here: `renderNode`
  ## calls it per node, `joinMembers` and `joinEntries` call it per member, and
  ## `substituteSummary` calls it per placeholder — which is the edge that
  ## closes the cycle `substituteSummary` -> here -> `visualisedText` ->
  ## `substituteSummary`. Testing the bound at the funnel rather than at each
  ## call site is §14's rule: four copies of "have we spent too much" would be
  ## four things that can be wrong while three of them agree.
  ##
  ## THE CHARGES ARE A DIFFERENT QUESTION AND THEY ARE NOT ALL HERE.
  ## *Corrected 2026-09-12*: this header used to say two units were charged per
  ## frame and that they were the frame's cost. They are not — three of the
  ## things a frame does are proportional to the RECORDING and appear in
  ## neither number, and the version of this bound that charged only these two
  ## reported an unchanged `spent` of 1,048,582 while the process did two
  ## hundred times the work. See the block above `memberScanCost` for the
  ## measurement and for why one charge per QUANTITY, at the site that spends
  ## it, is the shape §14 asks for rather than one charge in total.
  ##
  ## SIX CHARGES ARE MADE, and only three of them are made here, because only
  ## three of them are spent here:
  ##
  ##   1. the `inc` BELOW — one unit for ENTERING a frame, so the number of
  ##      frames can never exceed `MaxRenderWork` whatever each one produces;
  ##   2. `chargedWinner` — the visualiser scan, whose two bounds
  ##      (`MaxVisualiserRules`, `MaxTypeMatchBytes`) are BOTH the
  ##      declaration's, so bounded per frame is not bounded per rendering;
  ##   3. the `+= result.len` at the end — what was PRODUCED, so the bound is
  ##      also a bound on the bytes this process allocated on a repository's
  ##      behalf;
  ##   4. `memberScanCost`, charged in `builtinInlineText` and again in
  ##      `renderNode` — the two places that WALK a value's members;
  ##   5. `memberScanCost` again, charged by `chargedMemberNamed` at every
  ##      place a DECLARED NAME is resolved against those members — up to
  ##      `MaxTemplatePlaceholders` times per frame from one summary;
  ##   6. `mediaScanCost`, charged by `chargedMediaBytes` where the size of the
  ##      field a §5.2 rule named is read.
  ##
  ## 4, 5 and 6 are elsewhere on purpose. A rule that answers with a summary
  ## never reaches `builtinInlineText`, so it must not pay for a member walk it
  ## never makes; a placeholder's lookup is spent inside `substituteSummary`,
  ## once per placeholder rather than once per frame; and the field a `media`
  ## key names is a member that this frame's own length and member count both
  ## say nothing about.
  ##
  ## AFTER THE BOUND IS REACHED, NO NEW FRAME IS ENTERED, which is what makes
  ## the unwind cheap without a second check in every loop. The frames still
  ## running are the ones already on the stack — at most `Budget.depth` of them
  ## — and each finishes its own loop of at most `Budget.members` calls, so the
  ## unwind is bounded by `depth * members` RETURNS and `joinMembers`,
  ## `joinEntries` and `substituteSummary` need no bound of their own.
  ##
  ## *"IN CONSTANT TIME" IS WHAT THIS USED TO SAY, AND IT WAS FALSE.*
  ## Corrected 2026-09-12. Each of those returns is constant HERE — the test
  ## above is the first statement in the function — but three of them are not
  ## constant at their own call site, and one of them was also CHARGED:
  ##
  ##   * `chargedWinner` still scans, deliberately, because its answer decides
  ##     what an elided node reports about itself. `MaxVisualiserRules` x
  ##     `MaxTypeMatchBytes`, from the declaration, per return.
  ##   * `chargedMemberNamed` still looks up, deliberately, because answering
  ##     `nil` would report a wrong declaration. O(`members`) per placeholder.
  ##   * `renderNode`'s hidden-member walk did too, and NOT deliberately — it
  ##     sat above that function's own exhaustion return, which stops the
  ##     descent and not the caller's loop. That one both walked and charged,
  ##     so a 200-wide DAG over a 400,000-member shared child reported `spent`
  ##     at **77x** the bound it was reporting against. It is now guarded, and
  ##     the measurement is at the guard.
  ##
  ## So the work after exhaustion is `depth * members` returns, each costing a
  ## visualiser scan and up to `MaxTemplatePlaceholders` member lookups — both
  ## bought on purpose, both priced in their own function's header — and NOT a
  ## member walk. The two that remain are the subject of the milestone file's
  ## residue 6.
  if v.isNil:
    return "nil"
  if depth > ctx.budget.depth:
    tally.truncated = true
    # `#` is what BOTH prior implementations emitted at their depth limit
    # (`textReprDefault` and `extractValueText`), so the one surface that had a
    # depth limit keeps the spelling its snapshots know.
    return "#"
  if tally.work >= MaxRenderWork:
    # REFUSED, AND SAID SO. The glyph is the surface's own elision mark rather
    # than "" or a word, because a blank here is indistinguishable from a value
    # the debugger had nothing for — PLAT-2's header records what that costs —
    # and `Presentation.expansion` carries the sentence with the remedy.
    tally.truncated = true
    tally.exhausted = true
    return Ellipsis
  inc tally.work
  let vi = chargedWinner(v, presenters, ctx.languageName, tally)
  if vi >= 0:
    result = visualisedText(presenters.visualisers[vi], v, ctx, depth,
                            presenters, tally)
    if tally.exhausted and tally.exhaustedIn.len == 0:
      # The deepest frame that was expanding a rule when the allowance ran out
      # names it, because that is the rule whose author has something to
      # change. See `RenderTally.exhaustedIn`.
      tally.exhaustedIn = presenters.visualisers[vi].id
  else:
    result = builtinInlineText(v, ctx, depth, presenters, tally, [])
  if not tally.exhausted:
    # NOT CHARGED ONCE THE ALLOWANCE IS GONE, so `spent` is what was spent
    # BEFORE the rendering stopped rather than what the unwinding stack would
    # have spent afterwards. Without this the outer frames each add their own
    # (already-paid-for) result on the way out and the report reads `4477915 of
    # 1048576`, which looks like a bound that did not hold. Measured: at depth
    # 16 the same rendering reports four times the bound without this line.
    tally.work += result.len

func annotatedText(v: PValue; class: PresentationClass; text: string): string =
  ## The SECOND rendering a surface with room asks for — a number in the other
  ## base. `306` gains `(0x132)`; `0x2710` gains `(10000)` and loses its
  ## padding.
  ##
  ## Gated on `Budget.annotated` rather than on a `focused` flag threaded
  ## through every view, because "do I have room for the pair" is a budget
  ## question and this is where budget questions are answered.
  case class
  of pcInteger:
    let hex = toHexLiteral(text)
    if hex.len == 0: text else: text & " (" & hex & ")"
  of pcHexLiteral:
    let shown = normalisedHexLiteral(text)
    let decimal = fromHexLiteral(text)
    if decimal.len == 0: shown else: shown & " (" & decimal & ")"
  else:
    text

func renderNode(v: PValue; ctx: PresentationContext; depth: int; label: string;
                presenters: PresenterSet; tally: var RenderTally): PresentationNode =
  ## One node and, within the budget's depth and member caps, its children.
  ##
  ## PLAT-12 GIVES THE VISUALISER THREE SAYS HERE, AND NO MORE. It may replace
  ## the node's `kind` (§5.3's "how it presents"), remove members from the
  ## child list and from the totals (§5.3's "what it hides"), and mark the node
  ## as media. It may NOT change the budget, the depth, the member cap or the
  ## class: those are the surface's and the value's respectively, and a
  ## declaration that could move them would let a cloned repository decide how
  ## much of a pane it gets.
  let class = classOf(v)
  let vi = chargedWinner(v, presenters, ctx.languageName, tally)
  let hide: seq[string] =
    if vi >= 0: presenters.visualisers[vi].hide else: @[]
  var inline = inlineText(v, ctx, depth, presenters, tally)
  if ctx.budget.annotated:
    inline = annotatedText(v, class, inline)
  if ctx.budget.cells > 0:
    let (clipped, wasClipped) = clipToCells(ctx, inline, ctx.budget.cells)
    inline = clipped
    if wasClipped:
      tally.truncated = true

  # The members this node SHOWS, after hiding. `childCount` counts what the
  # value has; a hidden member is not one of them as far as the reader is
  # concerned, and reporting it in `totalMembers` would put an expansion caret
  # on a record whose every remaining field is hidden.
  #
  # ## THE EXHAUSTION TEST IS ABOVE THE WALK, AND IT WAS NOT (2026-09-12)
  #
  # This walk used to run unconditionally, and the `tally.exhausted` return
  # below it — the one that stops the tree descending — was the only thing that
  # stopped it. That is too late by one loop, because the loop the walk is
  # inside is the CALLER's: when a child exhausts the allowance, every
  # REMAINING SIBLING still gets its own `renderNode`, whose `inlineText`
  # returns the elision glyph for free and whose walk here then pays a full
  # frame's charge over a member list the RECORDING sizes. Up to
  # `Budget.depth * Budget.members` of them.
  #
  # Measured, release, `state-panel`, a positional sequence sharing one child
  # `Budget.members` times — the DAG shape residue 4 names:
  #
  #   | shared child | no declaration     | a cheap summary on the root |
  #   |---|---|---|
  #   | 100,000 | `spent` 1,107,210 = 1x | `spent` 20,613,990 = **19.7x** |
  #   | 400,000 | `spent` 1,202,258 = 1x | `spent` 80,803,474 = **77.1x** |
  #
  # The declaration buys the multiplier by making the PARENT's line cheap
  # enough for the child loop to start at all; with no rule the parent's own
  # `inlineText` spends the allowance and this frame returns before the loop.
  # So the bound's report read `80803474 of 1048576` — which is exactly the
  # sentence `inlineText`'s byte charge already refuses to produce ("looks like
  # a bound that did not hold"), arriving at the one charge site that reasoning
  # had not reached. Every other post-exhaustion decision in this file is
  # already made this way: `chargedWinner` and `chargedMemberNamed` stop
  # charging, `chargedMediaBytes` stops walking, `inlineText` stops adding its
  # output. This was the only bare `tally.work +=` left.
  #
  # WHAT IT COSTS IS ONE FACT ABOUT AN ELIDED NODE: it no longer knows its
  # HIDDEN-member count, because the scan that applies `hide` is the cost. It
  # reports the value's own member count instead — the recording's number, not
  # the rule's. That is the right way to be wrong here: the alternative is 0,
  # which removes the expansion caret and says "this value has no members",
  # and a node whose line is already the elision glyph is one a reader is being
  # told to expand.
  var visible: seq[int] = @[]
  if not v.isNil and v.kind != pvkMap and not tally.exhausted:
    # CHARGED HERE TOO, because this is a SECOND walk of the same members and a
    # charge that priced only `builtinInlineText`'s would be a charge on one of
    # the two things that spend (§14: the charge goes where the work is, and
    # `memberScanCost` is the one function that says how much).
    tally.work += memberScanCost(v)
    for i in 0 ..< v.members.len:
      if not isHidden(hide, v.members[i].label): visible.add i
  let shownMembers =
    if v.isNil: 0
    elif v.kind == pvkMap: v.entries.len
    elif tally.exhausted: v.members.len
    else: visible.len

  result = PresentationNode(
    label: label,
    typeName: (if v.isNil: "" else: v.typeName),
    kind: vocabularyKindOf(v),
    class: class,
    text: inline,
    totalMembers: shownMembers,
    expandable: (not v.isNil) and
                (shownMembers > 0 or
                 ((v.kind in {pvkPointer, pvkReference}) and not v.target.isNil)))

  if vi >= 0:
    let vis = presenters.visualisers[vi]
    if vis.presentDeclared:
      # §5.3's "how it presents". Constrained to `ValuePresentationKinds` at
      # parse AND at admission, so this cannot make a value into a `Button`.
      result.kind = vis.present
    if vis.mediaType.len > 0:
      # The node says what the project said it is, WHETHER OR NOT this surface
      # drew it. A degraded node that dropped the media type would leave the
      # gap on the presentation with nothing on the node to attach it to, and a
      # surface that later gains the capability would have nothing to read.
      let field = chargedMemberNamed(tally, v, vis.mediaFrom)
      result.mediaType = vis.mediaType
      result.mediaBytes = chargedMediaBytes(tally, field)
      if surfaceDrawsMedia(ctx, vis, field):
        result.kind = pkImage
        result.class = pcMedia

  if v.isNil or depth >= ctx.budget.depth:
    if result.totalMembers > 0:
      result.elided = result.totalMembers
    return

  if tally.exhausted:
    # PLAT-12. The bound is on the PRESENTATION and not on one node, so a tree
    # walk does not continue for free once the allowance is gone: every
    # `inlineText` below here would return the elision glyph without charging,
    # and a node whose own line is an ellipsis has nothing to hang children on.
    # The members are reported as elided, which is what they are.
    if result.totalMembers > 0:
      result.elided = result.totalMembers
    return

  # A one-line surface has no children to draw. Asserted here rather than left
  # to each surface: `budget.lines == 1` means the presentation IS the line.
  if ctx.budget.lines == 1:
    if result.totalMembers > 0:
      result.elided = result.totalMembers
    return

  let cap = if ctx.budget.members <= 0: 0 else: ctx.budget.members
  if v.kind == pvkMap:
    for i in 0 ..< min(cap, v.entries.len):
      result.keys.add renderNode(v.entries[i].key, ctx, depth + 1, "",
                                 presenters, tally)
      result.children.add renderNode(v.entries[i].val, ctx, depth + 1, "",
                                     presenters, tally)
    result.elided = max(0, v.entries.len - cap)
  else:
    for k in 0 ..< min(cap, visible.len):
      let i = visible[k]
      let m = v.members[i]
      # THE POSITIONAL LABEL IS THE VALUE'S OWN INDEX, NOT THE VISIBLE ONE.
      # `[2]` has to mean the third element of the recorded sequence whether or
      # not a rule hid the second; renumbering would make a visualiser change
      # what an index MEANS, and a reader comparing a pane against a `print`
      # would be comparing two different orderings.
      let childLabel = if m.label.len > 0: m.label else: "[" & $i & "]"
      result.children.add renderNode(m.value, ctx, depth + 1, childLabel,
                                     presenters, tally)
    result.elided = max(0, visible.len - cap)
    if v.kind in {pvkPointer, pvkReference} and not v.target.isNil:
      result.children.add renderNode(v.target, ctx, depth + 1, "*",
                                     presenters, tally)
  if result.elided > 0:
    tally.truncated = true

func present*(v: PValue; ctx: PresentationContext;
              presenters: PresenterSet = BuiltinPresenters): Presentation =
  ## `Value -> Presentation`. PLAT-2 deliverable 1.
  var tally = RenderTally()
  let root = renderNode(v, ctx, 0, "", presenters, tally)
  Presentation(root: root,
               attribution: resolve(v, presenters, ctx.languageName),
               budget: ctx.budget, truncated: tally.truncated,
               mediaGaps: tally.gaps,
               # PLAT-12. `spent` is carried whether or not the bound was
               # reached: a number that only appears in the failure case is a
               # number nobody can watch approaching.
               expansion: ExpansionBound(
                 reached: tally.exhausted, spent: tally.work,
                 bound: MaxRenderWork, visualiser: tally.exhaustedIn,
                 surface: ctx.budget.name))

func present*(v: PValue; budget: Budget; lang = plUnknown;
              measure: PresentationMeasure = nil;
              presenters: PresenterSet = BuiltinPresenters;
              languageName = ""): Presentation =
  ## The spelling every surface uses: a value, its own budget, and the
  ## recording's language.
  ##
  ## `languageName` IS LAST AND DEFAULTS TO "", so every call site written
  ## before PLAT-12 means what it meant: no language name, therefore no
  ## language-qualified visualiser matches, therefore the built-in table
  ## answers. A surface that HAS loaded a checkout's definitions passes both —
  ## `lang` for the delimiters and `languageName` for §5.3's matching.
  present(v, PresentationContext(lang: lang, languageName: languageName,
                                 budget: budget, measure: measure),
          presenters)

func presentText*(v: PValue; budget: Budget; lang = plUnknown;
                  measure: PresentationMeasure = nil): string =
  ## The one-line rendering alone, for the four surfaces that are a line.
  ##
  ## A convenience over `present(…).root.text` and NOT a second path: it calls
  ## the same function and returns one field of the same result. The gate
  ## permits it by name for that reason.
  present(v, budget, lang, measure).root.text
