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

  PresenterSet* = object
    ## The ordered rules resolution considers. A parameter, so PLAT-12 extends
    ## precedence without a global.
    rules*: seq[PresenterRule]

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

func resolve*(v: PValue; presenters: PresenterSet = BuiltinPresenters): Attribution =
  ## Which presenter renders `v`, and what else could have.
  ##
  ## Total: `builtin.opaque` claims the kinds nothing else does, and the
  ## fallback below names itself rather than returning an empty attribution —
  ## "no presenter" is a state a reader must be able to see, and an empty
  ## string in a report is indistinguishable from a bug in the reporter.
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

func mediaSummary*(v: PValue): string =
  ## What a surface WITHOUT pixels shows for a `pvkMedia` value.
  ##
  ## This is the degradation Project-Definitions §5.2 requires ("an image, at
  ## whatever fidelity the surface allows") and it is specified here rather
  ## than in PLAT-12 because it is a BUDGET question: a one-line surface has
  ## no fidelity to offer, and what it shows instead is the presenter's answer,
  ## not the surface's.
  let kindText = if v.mediaType.len > 0: v.mediaType else: "application/octet-stream"
  if v.mediaBytes > 0:
    "<" & kindText & ", " & $v.mediaBytes & " bytes>"
  else:
    "<" & kindText & ">"

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

func inlineText(v: PValue; ctx: PresentationContext; depth: int;
                presenters: PresenterSet; truncated: var bool): string

func joinMembers(v: PValue; ctx: PresentationContext; depth: int;
                 presenters: PresenterSet; truncated: var bool;
                 labelled: bool): string =
  ## The comma-separated member list, ELIDED BY THE BUDGET rather than
  ## rendered in full and cut afterwards.
  ##
  ## This is the deliverable. `textRepr` rendered all ten thousand elements of
  ## a ten-thousand-element sequence and left the surface to clip the resulting
  ## string; `flow.nim` then measured that string's `.len` twice per value to
  ## decide whether to show a "view more" button. Here the loop STOPS at
  ## `budget.members`, so the cost of a one-line rendering of a 600-entry
  ## mapping is bounded by the budget and not by the recording.
  let total = v.members.len
  let cap = if ctx.budget.members <= 0: 0 else: min(ctx.budget.members, total)
  var parts: seq[string] = @[]
  for i in 0 ..< cap:
    let m = v.members[i]
    let rendered = inlineText(m.value, ctx, depth + 1, presenters, truncated)
    if labelled and m.label.len > 0:
      parts.add m.label & ":" & rendered
    else:
      parts.add rendered
  if cap < total:
    truncated = true
    parts.add Ellipsis
  parts.join(", ")

func joinEntries(v: PValue; ctx: PresentationContext; depth: int;
                 presenters: PresenterSet; truncated: var bool): string =
  let total = v.entries.len
  let cap = if ctx.budget.members <= 0: 0 else: min(ctx.budget.members, total)
  var parts: seq[string] = @[]
  for i in 0 ..< cap:
    let e = v.entries[i]
    parts.add inlineText(e.key, ctx, depth + 1, presenters, truncated) & ": " &
              inlineText(e.val, ctx, depth + 1, presenters, truncated)
  if cap < total:
    truncated = true
    parts.add Ellipsis
  parts.join(", ")

func inlineText(v: PValue; ctx: PresentationContext; depth: int;
                presenters: PresenterSet; truncated: var bool): string =
  ## One value as ONE line, at the current budget.
  ##
  ## THE ONE RENDERING. Seven implementations of this function existed when
  ## PLAT-2 was written — `textReprDefault`, `textReprRust`, `text`/`$`,
  ## `headless_session.extractValueText`, `calltrace.safeCallArgText`,
  ## `db-backend/src/value.rs::text_repr` and `src/tui/src/value.rs::text_repr`.
  ## The first five are Nim and are collapsed into this one; the two Rust ones
  ## are named in `ci/test/value-presentation-boundary.sh`'s declared scope as
  ## OUT of it, because a Nim import lint cannot reach them.
  if v.isNil:
    return "nil"
  if depth > ctx.budget.depth:
    truncated = true
    # `#` is what BOTH prior implementations emitted at their depth limit
    # (`textReprDefault` and `extractValueText`), so the one surface that had a
    # depth limit keeps the spelling its snapshots know.
    return "#"

  let attribution = resolve(v, presenters)
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
      inlineText(v.target, ctx, depth, presenters, truncated)
    else:
      address & " -> (" & inlineText(v.target, ctx, depth + 1, presenters, truncated) & ")"
  of "builtin.variant":
    let head =
      if v.typeName.len > 0 and v.variantName.len > 0:
        v.typeName & "::" & v.variantName
      elif v.variantName.len > 0: v.variantName
      else: v.typeName & "::?"
    if v.members.len == 0: head
    else: head & "(" & joinMembers(v, ctx, depth, presenters, truncated, true) & ")"
  of "builtin.map":
    "{" & joinEntries(v, ctx, depth, presenters, truncated) & "}"
  of "builtin.record":
    let (open, close) = recordOpenClose(ctx.lang)
    v.typeName & open &
      joinMembers(v, ctx, depth, presenters, truncated, true) & close
  of "builtin.tuple":
    "(" & joinMembers(v, ctx, depth, presenters, truncated, false) & ")"
  of "builtin.sequence":
    let (open, close) = sequenceDelimiters(v, ctx.lang)
    var body = joinMembers(v, ctx, depth, presenters, truncated, false)
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
                presenters: PresenterSet; truncated: var bool): PresentationNode =
  ## One node and, within the budget's depth and member caps, its children.
  let class = classOf(v)
  var inline = inlineText(v, ctx, depth, presenters, truncated)
  if ctx.budget.annotated:
    inline = annotatedText(v, class, inline)
  if ctx.budget.cells > 0:
    let (clipped, wasClipped) = clipToCells(ctx, inline, ctx.budget.cells)
    inline = clipped
    if wasClipped:
      truncated = true

  result = PresentationNode(
    label: label,
    typeName: (if v.isNil: "" else: v.typeName),
    kind: vocabularyKindOf(v),
    class: class,
    text: inline,
    totalMembers: childCount(v),
    expandable: (not v.isNil) and
                (childCount(v) > 0 or
                 ((v.kind in {pvkPointer, pvkReference}) and not v.target.isNil)))

  if v.isNil or depth >= ctx.budget.depth:
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
                                 presenters, truncated)
      result.children.add renderNode(v.entries[i].val, ctx, depth + 1, "",
                                     presenters, truncated)
    result.elided = max(0, v.entries.len - cap)
  else:
    for i in 0 ..< min(cap, v.members.len):
      let m = v.members[i]
      let childLabel = if m.label.len > 0: m.label else: "[" & $i & "]"
      result.children.add renderNode(m.value, ctx, depth + 1, childLabel,
                                     presenters, truncated)
    result.elided = max(0, v.members.len - cap)
    if v.kind in {pvkPointer, pvkReference} and not v.target.isNil:
      result.children.add renderNode(v.target, ctx, depth + 1, "*",
                                     presenters, truncated)
  if result.elided > 0:
    truncated = true

func present*(v: PValue; ctx: PresentationContext;
              presenters: PresenterSet = BuiltinPresenters): Presentation =
  ## `Value -> Presentation`. PLAT-2 deliverable 1.
  var truncated = false
  let root = renderNode(v, ctx, 0, "", presenters, truncated)
  Presentation(root: root, attribution: resolve(v, presenters),
               budget: ctx.budget, truncated: truncated)

func present*(v: PValue; budget: Budget; lang = plUnknown;
              measure: PresentationMeasure = nil;
              presenters: PresenterSet = BuiltinPresenters): Presentation =
  ## The spelling every surface uses: a value, its own budget, and the
  ## recording's language.
  present(v, PresentationContext(lang: lang, budget: budget, measure: measure),
          presenters)

func presentText*(v: PValue; budget: Budget; lang = plUnknown;
                  measure: PresentationMeasure = nil): string =
  ## The one-line rendering alone, for the four surfaces that are a line.
  ##
  ## A convenience over `present(…).root.text` and NOT a second path: it calls
  ## the same function and returns one field of the same result. The gate
  ## permits it by name for that reason.
  present(v, budget, lang, measure).root.text
