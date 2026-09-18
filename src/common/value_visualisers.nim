## value_visualisers.nim — PLAT-12. The ONE function that turns a repository's
## declaration into something that renders.
##
## ## WHY THIS IS A THIRD MODULE AND NOT A FUNCTION IN EITHER PACKAGE
##
## Because it is a boundary, and a boundary that lives inside one of the two
## things it separates is not one.
##
##   * `common/value_presentation/` may not see a project definition. Its whole
##     import closure is `std/strutils` and `std/unicode`, asserted byte for
##     byte by `ci/test/value-presentation-boundary.sh`, and that closure is
##     what makes "a presentation is pure and byte-identical across runs"
##     checkable rather than promised. A presenter that could read a
##     `DefinitionOrigin` would be a presenter that could branch on where a
##     rule came from.
##   * `common/project_definitions/` may not see the presenter. Its closure is
##     four `std` modules plus `toml_subset` plus the presentation VOCABULARY,
##     asserted verbatim by `project_definitions_test`, and PLAT-11's third
##     deliverable ("a loader with no I/O, network, process or filesystem
##     access") is a fact about that closure.
##
## So the declaration and the renderer meet HERE, in a module both may be
## imported by and neither is. Every crossing is one function —
## `visualiserFor` — and everything that has to be true of a declaration before
## it may render is `admit` below.
##
## ## THE INPUT IS STILL HOSTILE, AND RENDERING IS A LONGER PATH THAN PARSING
##
## Project-Definitions.md §1.1: "A project definition is acquired by cloning,
## and a user who clones a repository to *look* at it has evaluated nothing."
## PLAT-11's parser is written around that and bounds every field it reads.
## This module exists at the point where that text stops being data in a
## `seq` and starts being consulted once per rendered node on every surface —
## which is a much longer path, and a `Visualiser` can reach `resolve` without
## having come through `parse.nim` at all (a test constructs one; so could a
## future in-program or plugin tier).
##
## `admit` therefore re-checks, from the SAME named bounds PLAT-11 uses rather
## than from second numbers (§14), the three things a renderer could otherwise
## reintroduce:
##
##   1. **An unbounded size.** Every string a rule contributes is bounded here:
##      the match, the language, the summary, the media type, the field name,
##      each hidden name, and the COUNT of hidden names and of rules. A
##      declaration is text from a `git clone`, and a renderer that walks it
##      once per node on every surface multiplies whatever the parser let
##      through.
##   2. **A path that resolves.** There is no field on a `Visualiser` that
##      names a file, and that is structural rather than checked — see
##      `presenter.Visualiser`'s header. What `admit` adds is the one thing
##      structure cannot say: `mediaFrom` and every `hide` entry are compared
##      to member LABELS by equality and are refused if they carry a path
##      separator, a NUL or any other control character. No member label in any
##      recording this workspace produces contains one, so nothing legitimate
##      is lost — and a name that cannot be a label but could be read as a path
##      by something downstream is refused before it can be.
##   3. **A media type that selects a decoder by name.** The type is classified
##      into `MediaClass` — a closed enum, by exact whole-string equality — and
##      a rule whose type does not classify is refused here as well as reported
##      at render time. `mediaClassOf` is the only thing in the tree that looks
##      at the bytes of a declared media type.
##
## ## WHAT IS DELIBERATELY ABSENT
##
## There is no way to run anything, and it is absent in the same way it is
## absent from PLAT-11: not refused, unrepresentable. `VisualiserRule` has no
## field naming a program and neither does `Visualiser`, so there is nothing
## for this function to copy across. §5.1's mechanism 3 — an executable
## visualiser — is PLAT-13's, behind a per-repository grant, in a file this
## module never sees: `loadProjectDefinitions` reports an executable-tier file
## as a notice and never parses it, so its rules never reach `visualisersFor`
## and there is no code path here that could take one.

import std/strutils

import ./project_definitions
import ./value_presentation

const
  UserVisualiserTier* = ptProjectDefinition
    ## The tier a definition from the USER'S own `.codetracer/` renders in.
    ##
    ## THE SAME TIER AS THE PROJECT'S, AND THE ORDER BETWEEN THEM IS NEARNESS.
    ## §5.4 names four tiers and "the user's own definitions" is not one of
    ## them — §6 keeps them a separate FIELD so a local experiment never
    ## becomes a diff, which is a question about storage rather than about
    ## precedence. Giving the user a fifth tier would have meant deciding, here
    ## and permanently, whether a user's rule beats a project's; `visualisersFor`
    ## instead ranks the user's AHEAD within the shared tier, which is the
    ## answer a user expects from their own machine and is reversible by
    ## deleting one file rather than by changing an enum.

  MaxHideNameBytes = MaxFieldNameBytes
    ## PLAT-11's bound on a field name, NAMED rather than restated. A second
    ## number here would be a second answer to "how long may a field name be",
    ## and the two would diverge on the day one of them was tuned.

func nameIsLabelShaped(name: string): bool =
  ## Whether `name` could be a member label a recording produced.
  ##
  ## THE REFUSAL IS OF PATH-SHAPED AND CONTROL BYTES, NOT A CHARSET. A member
  ## label is language-defined — `self`, `__dict__`, `r#type`, `字段` are all
  ## real — so a closed alphabet here would refuse legitimate recordings, and
  ## `containment.pathProblem`'s reasoning does not transfer: that predicate
  ## guards a string that becomes a PATH, and this one guards a string that
  ## becomes a comparison.
  ##
  ## What IS refused is the overlap between the two: `/`, `\`, a NUL and every
  ## other control character. None of them occurs in a member label in any
  ## recording this workspace produces, and all of them are what a string would
  ## have to contain to be mistaken for a path by anything downstream that one
  ## day handled these names less carefully than this module does. It is a
  ## narrow, cheap refusal of exactly the shapes PLAT-11's path grammar exists
  ## to refuse, applied to a field that is NOT a path — so that it cannot
  ## become one by someone else's edit.
  ##
  ## ## THE SCOPE IS BYTES, NOT CHARACTERS, AND THAT IS A LIMIT ON THE CLAIM
  ##
  ## The loop below walks `char`s. It is therefore blind to every *encoding* of
  ## a separator or a control character that is not the ASCII byte itself:
  ##
  ##   * overlong UTF-8 — `C0 80` for NUL, `C0 AF` for `/` — which a decoder
  ##     that does not reject overlong forms folds back to the byte this
  ##     refuses;
  ##   * U+0085 NEL, U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR, which
  ##     are line terminators to a Unicode-aware consumer and ordinary
  ##     continuation bytes here;
  ##   * U+FF0F FULLWIDTH SOLIDUS and the rest of the compatibility forms, which
  ##     NFKC normalises to `/`;
  ##   * U+202E RIGHT-TO-LEFT OVERRIDE and its family, which change how a name
  ##     READS without changing what it is.
  ##
  ## All of them are admitted, and that is verified HARMLESS AS WRITTEN rather
  ## than argued to be: the name reaches exactly one thing, `memberNamed`'s
  ## equality against the labels the RECORDING produced, so `pix\xC0\xAFels`
  ## does not match a member labelled `pix/els` — it matches a member labelled
  ## `pix\xC0\xAFels`, and no recorder in this workspace emits one.
  ##
  ## BUT THE STATED PURPOSE OF THIS FUNCTION IS THAT THE NAME CANNOT BECOME A
  ## PATH BY SOMEONE ELSE'S EDIT, and that purpose is exactly where a
  ## byte-level scope stops being sufficient. The edit that would break it is
  ## not "open this name as a file" — that would be caught by
  ## `containment.pathProblem` on the way — it is any consumer that DECODES or
  ## NORMALISES the name before comparing or joining it: an NFKC fold, a lenient
  ## UTF-8 decoder, a JSON or TOML round trip through a permissive library. If
  ## one appears, this predicate has to move to runes and refuse those classes
  ## by code point; until one does, widening it would refuse legitimate labels
  ## (`字段` is here because a closed alphabet was wrong) for no gain.
  if name.len == 0: return false
  for ch in name:
    if ch < ' ' or ch == '\x7f': return false
    if ch == '/' or ch == '\\': return false
  true

func admit*(rule: VisualiserRule): bool =
  ## Whether a declaration may become a `Visualiser` at all.
  ##
  ## TOTAL, PURE, AND THE ONLY DOOR. `visualisersFor` below calls this and
  ## nothing else admits a rule, so a reader asking "what must be true of a
  ## declaration before it renders" has one function to read.
  ##
  ## THIS IS DELIBERATELY A SECOND CHECK OF THINGS PLAT-11 ALREADY CHECKS, and
  ## that needs the argument Verification-Harness-Traps §32a asks for, because
  ## two mechanisms guarding one property silently halve the mutation coverage
  ## of the older one unless each has evidence only it can satisfy. The
  ## evidence is disjoint here by construction: PLAT-11's parser is reachable
  ## only from a `.codetracer/` FILE, and this is reachable from a
  ## `VisualiserRule` VALUE — which a test constructs, which a future
  ## in-program or plugin tier would construct, and which is how every case in
  ## `value_visualisers_test` that names `admit` reaches it. A rule that never
  ## went through `parse.nim` is refused here and by nothing else.
  ##
  ## Every bound below is PLAT-11's own constant. There is no number in this
  ## function.
  if rule.match.len == 0 or rule.match.len > MaxTypeMatchBytes: return false
  if rule.language.len > MaxNameBytes: return false
  if rule.summary.len > MaxSummaryBytes: return false
  if templateProblem(rule.summary) != tpOk: return false
  if rule.present notin ValuePresentationKinds: return false
  if rule.hide.len > MaxHiddenFields: return false
  for h in rule.hide:
    if h.len > MaxHideNameBytes or not nameIsLabelShaped(h): return false
  if rule.mediaType.len > 0:
    # A media type that does not classify is refused HERE as well as reported
    # at render time, and the two are not redundant. This one keeps an
    # unclassifiable type out of the presenter entirely; the render-time gap
    # (`describeMediaGap`'s `mcUnknown` arm) covers a `Visualiser` built by
    # something other than this function — which is the only way one can now
    # arrive, and is exactly the case a report has to be able to make.
    if mediaClassOf(rule.mediaType) == mcUnknown: return false
    if rule.mediaFrom.len == 0 or rule.mediaFrom.len > MaxFieldNameBytes:
      return false
    if not nameIsLabelShaped(rule.mediaFrom): return false
  elif rule.mediaFrom.len > 0:
    # `mediaFrom` with no `media` names bytes without saying what they are,
    # which is the knowledge §5.2 exists to capture. PLAT-11 refuses it at
    # parse; refused again here for the reason above.
    return false
  true

func visualiserIdOf*(rule: VisualiserRule; origin: DefinitionOrigin): string =
  ## The stable, greppable id `Attribution.presenter` reports.
  ##
  ## `project:.codetracer/visualisers.toml#0`. THREE PARTS, EACH LOAD-BEARING:
  ## the origin, because §6 keeps the user's definitions separate and a report
  ## that could not tell a user their OWN rule won would be answering the wrong
  ## question; the file, because a monorepo has one per package and "which one"
  ## is the first thing an author asks; and the declaration order within it,
  ## because §5.4 breaks ties by it and two rules in one file are otherwise
  ## indistinguishable in a report.
  ##
  ## IT IS DERIVED FROM THE DECLARATION AND NOT FROM A COUNTER. An id that was
  ## a running index would change when an unrelated file was added, so a
  ## provenance string a user copied out of a pane would stop naming the rule
  ## they copied it from.
  (if origin == doUser: "user:" else: "project:") & rule.file & "#" & $rule.order

func visualiserFor*(rule: VisualiserRule; origin: DefinitionOrigin;
                    rank: int): Visualiser =
  ## One declaration, as the presenter sees it. THE ONLY CROSSING.
  ##
  ## Note what does NOT cross: `origin`, `scope`, `file` and `order` are read
  ## to compute an id and a rank and are then left behind. A renderer that
  ## could see them could render a rule from a nested package differently from
  ## one at the root, which is a difference §5.4 resolves by PRECEDENCE — once,
  ## here — rather than by letting every rendering re-decide it.
  Visualiser(
    id: visualiserIdOf(rule, origin),
    tier: UserVisualiserTier,
    # SET TOGETHER WITH `tier`, ALWAYS. `ptInProgram` is the enum's zero value
    # and §5.4's highest precedence at once, so a producer that wrote `tier`
    # and forgot this one would be declaring the top tier by accident. See
    # `presenter.Visualiser.tierDeclared`; this function is the only producer
    # in the product today and a future tier's is the case that field exists
    # for.
    tierDeclared: true,
    typeMatch: rule.match,
    matchKind: rule.matchKind,
    language: rule.language,
    summary: rule.summary,
    hide: rule.hide,
    present: rule.present,
    presentDeclared: rule.presentDeclared,
    mediaType: rule.mediaType,
    mediaFrom: rule.mediaFrom,
    rank: rank)

func rankOf(rule: VisualiserRule; origin: DefinitionOrigin): int =
  ## §5.4's "within a tier the more specific match wins", as ONE number.
  ##
  ## Three inputs, most significant first, packed so that a comparison is `>`
  ## and a genuine tie is an EQUALITY a report can detect (which is why
  ## `model.specificity` is a number rather than a comparator, and this is the
  ## same argument one level up):
  ##
  ##   * the ORIGIN — a user's own rule ahead of the project's, see
  ##     `UserVisualiserTier`;
  ##   * the SCOPE DEPTH — §6's "a nearer `.codetracer/` overrides an
  ##     ancestor's", which `load.rankVisualisers` already applies to the seq's
  ##     order and which is carried into the number as well so that the number
  ##     alone decides and the seq's order is only a tie-break;
  ##   * the MATCH SPECIFICITY — `model.specificity`, unchanged.
  ##
  ## DECLARATION ORDER IS DELIBERATELY NOT ONE OF THE INPUTS, and that absence
  ## is the reason this function takes two arguments rather than three. §5.4
  ## breaks ties BY declaration order AND requires the tie to be reported; a
  ## rank that folded the position in would make every pair of rules distinct,
  ## so a tie would stop being an equality and `load.reportTies` would have
  ## nothing to detect. `winningVisualiser` keeps the earlier entry on an equal
  ## rank, and `load.rankVisualisers` is what puts them in declaration order —
  ## which is the same division of labour `model.specificity` describes one
  ## level down.
  let originWeight = if origin == doUser: 1 else: 0
  originWeight * 1_000_000 + scopeDepth(rule.scope) * 10_000 + specificity(rule)

func visualisersFor*(loaded: LoadedProjectDefinitions): seq[Visualiser] =
  ## Every admitted visualiser a checkout declared, in §5.4's order.
  ##
  ## THE USER'S COME FIRST AND THE PROJECT'S FOLLOW, which is the opposite of
  ## `load.allCollections`'s order and is deliberate: that function lists
  ## collections for a pane, where the shared ones belong at the top, and this
  ## one builds a PRECEDENCE, where the nearer authority belongs at the front.
  ## Both orders are also encoded in `rank`, so the seq's order only decides a
  ## genuine tie.
  ##
  ## BOUNDED BY `MaxVisualiserRules`. `loadProjectDefinitions` already bounds
  ## what one load can contain; this bounds what one PRESENTER SET can, which
  ## is the number `winningVisualiser` scans once per rendered node. A rule
  ## past the bound is dropped rather than truncating the list silently in some
  ## other place — and because the input is already ordered by precedence, the
  ## rules that are dropped are the least specific ones rather than an
  ## arbitrary suffix.
  ##
  ## A REFUSED RULE IS DROPPED AND THE REST STILL RENDER, which is
  ## `parseDefinitionFile`'s rule for an entry that is refused, applied one
  ## layer up: the load has already reported anything malformed, and a rule
  ## this function additionally refuses is one no file produced.
  var ordered: seq[(VisualiserRule, DefinitionOrigin)] = @[]
  for rule in loaded.user.visualisers: ordered.add (rule, doUser)
  for rule in loaded.project.visualisers: ordered.add (rule, doProject)
  for (rule, origin) in ordered:
    if result.len >= MaxVisualiserRules: break
    if not admit(rule): continue
    result.add visualiserFor(rule, origin, rankOf(rule, origin))

func presentersFor*(loaded: LoadedProjectDefinitions;
                    base: PresenterSet = BuiltinPresenters): PresenterSet =
  ## The presenter set a surface renders with once a checkout has been read.
  ##
  ## This is the whole of PLAT-12's wiring contract: a front-end that has
  ## loaded definitions calls this once and passes the result to `present`.
  ## There is no registry to install into and no global to set, so two
  ## sessions in one process cannot see each other's rules and a presentation
  ## remains a function of its arguments (PLAT-2's byte-identity, which PLAT-12
  ## inherits as "a visualiser is pure").
  withVisualisers(visualisersFor(loaded), base)

func describeVisualisers*(presenters: PresenterSet): string =
  ## What a `--verbose` run, a log or a diagnostics pane prints about the tier
  ## that is active: how many rules, and each one's id, match and effect.
  ##
  ## THE COMPANION TO `load.describeLoad`, which says what was READ. This says
  ## what is in FORCE, and the two are different facts: a rule can be read,
  ## reported as well formed, and then dropped by `admit` or by the bound
  ## above, and a user comparing the two numbers is entitled to see that.
  if presenters.visualisers.len == 0:
    return "no per-type visualisers are active"
  var lines: seq[string] = @[]
  lines.add $presenters.visualisers.len & " per-type visualiser(s) active, " &
    "most specific first:"
  for vis in presenters.visualisers:
    var effect: seq[string] = @[]
    if vis.summary.len > 0: effect.add "summary '" & vis.summary & "'"
    if vis.hide.len > 0: effect.add "hides " & vis.hide.join(", ")
    if vis.mediaType.len > 0:
      effect.add "media " & vis.mediaType & " from '" & vis.mediaFrom & "'"
    if vis.presentDeclared:
      effect.add "presents as " & presentationSpelling(vis.present)
    lines.add "  " & vis.id & ": " & $vis.matchKind & " '" & vis.typeMatch &
      "'" & (if vis.language.len > 0: " in " & vis.language else: "") &
      " (rank " & $vis.rank & ") — " &
      (if effect.len > 0: effect.join("; ") else: "no effect declared")
  lines.join("\n")
