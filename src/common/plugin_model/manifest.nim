## plugin_model/manifest.nim — PLAT-7 deliverable 1. Plugin identity, version,
## contributions, requirements and capabilities, and the load-time validation
## that refuses a manifest naming something that does not exist.
##
## ## THE MANIFEST IS DATA AND THE VALIDATION IS TOTAL
##
## Extensibility-Model.md §4.1 lists what a manifest declares — what it
## contributes, what it requires, what it may access — and then states the
## rule this module exists to enforce:
##
##   "A manifest naming something that does not exist is a **load-time error
##    naming the extension**, never a silently missing feature. This is
##    `PaneKind`'s lesson generalised: the GoldenLayout failure mode where an
##    unrecognised component name produces a blank tab is exactly what a
##    plugin system reproduces at scale if it tolerates unresolved
##    references."
##
## So `parseManifest` returns EVERY problem it found rather than the first,
## and a manifest with any problem is not a manifest: `ParsedManifest` carries
## `errors` and a caller that ignores them gets a manifest whose `id` is the
## only field it can trust.
##
## ## WHAT "DOES NOT EXIST" MEANS, CONCRETELY
##
## Four closed sets, and every one of them is DERIVED rather than restated:
##
##   * the sixteen views — `common/view_vocabulary`'s `ViewKind`, spelled with
##     `vocabularyName`, so a seventeenth entry is accepted here the day it is
##     admitted there and never a day before. A manifest naming `Sparkline`
##     fails, naming the plugin AND the entry.
##   * the six capabilities — §8.1.2's table, as an enum with the spec's own
##     spellings (`socket:local`, not `socketLocal`).
##   * the five contribution kinds — §6.1's four surfaces plus the published
##     ViewModel of §2's second row.
##   * the five activation events — §4.2's "a trace opening, a language
##     appearing in a recording, a command being invoked", plus a pane and the
##     eager `startup` that must say why.
##
## An unknown member of any of the four is a `pecUnknown*` error. There is no
## "unrecognised, ignored" arm anywhere in this file, and that absence is the
## deliverable.
##
## ## VERSIONS ARE SEMANTIC AND RANGES ARE CONJUNCTIONS
##
## `>=1.2.0 <2.0.0` and its abbreviation `^1.2.0` are the two forms, because
## those are the two a dependency actually wants to express. A range that
## cannot be read is an error rather than a permissive default: "accept
## anything" is a decision a plugin author must write down as `*`.

import std/[json, strutils, tables]

import ./diagnostics
import ./capabilities
import ../contributed_pane_id
import ../value_presentation/vocabulary as presentation_vocabulary
import ../view_vocabulary/vocabulary as view_vocabulary
import ../view_vocabulary/mappings as view_mappings

export diagnostics
export capabilities

# THE VOCABULARY IS RE-EXPORTED NARROWLY, and the narrowness is deliberate.
# A consumer reading `Contribution.views` needs the sixteen entries by name
# (`pkTable`) and needs to spell them back (`vocabularyName`), so those two
# come with the manifest. The REST of `common/view_vocabulary` — `ViewNode`,
# the builders, `applyKey`, the mappings, the admission table — does not,
# because a plugin declaring a pane is not yet rendering one, and because this
# module reaches the Embed SDK facade through `plugin_host/plugin_api` where
# every name it exports becomes public surface.
export presentation_vocabulary.PresentationKind
export view_vocabulary.ViewKind, view_vocabulary.vocabularyName

# PLAT-9 WIDENS THAT RE-EXPORT BY EXACTLY ONE TYPE, and the comment above said
# it would: a pane declaring a view is now a pane RENDERING one, so `FrontEnd`
# — PLAT-3's three rendering targets — has to be spellable in a manifest and
# readable by whoever decides whether a surface has a view here. `Mapping`,
# `MappingStatus` and `mappingFor` come with it, because §6.3's decision is
# taken against the mapping table rather than against a second copy of it.
export view_mappings.FrontEnd, view_mappings.MappingStatus,
       view_mappings.Mapping, view_mappings.mappingFor,
       view_mappings.frontEndName,
       # `absentEntries`/`absentEntryNames` come with `mappingFor` because they
       # ARE `mappingFor`, folded over the enum: "which entries have no view
       # here" is the question §6.3 is about, and a consumer that had to write
       # the fold itself would be writing the second copy of a predicate
       # (Verification-Harness-Traps §14) — which is how the absent set came to
       # be stated wrongly in prose in two places at once.
       view_mappings.absentEntries, view_mappings.absentEntryNames

# PLAT-9. A contributed pane id is a value a manifest declares, a value the
# layout persists and a value a front-end renders, so the grammar travels with
# the manifest rather than being re-derived at each of the three.
export contributed_pane_id

type
  SemVer* = object
    major*, minor*, patch*: int

  VersionBoundKind* = enum
    vbAtLeast   ## `>=`
    vbLessThan  ## `<`
    vbExact     ## `=`

  VersionBound* = object
    kind*: VersionBoundKind
    version*: SemVer

  VersionRange* = object
    ## A conjunction of bounds. An EMPTY conjunction accepts everything and is
    ## reachable only by writing `*`, so "no constraint" is something an
    ## author said rather than something a parser assumed.
    text*: string          ## as written, for the diagnostic
    bounds*: seq[VersionBound]

  ContributionKind* = enum
    ## §6.1's four surfaces, plus the published ViewModel §2 names as the
    ## second of the three things an extension may do.
    ckPane = "pane"
    ckCommand = "command"
    ckMarker = "marker"
    ckStatusItem = "statusItem"
    ckViewModel = "viewModel"

  SurfaceRequirement* = enum
    ## §6.3's rule: "an extension declares, per surface, whether it is
    ## `required` or `optional`."
    ##
    ## `srOptional` IS THE ZERO VALUE, DELIBERATELY. A manifest that says
    ## nothing gets the arm that cannot refuse activation, so omitting the
    ## field never turns a plugin off; declaring `required` is a decision the
    ## author writes down, exactly as `startup` activation is.
    srOptional = "optional"
    srRequired = "required"

  Contribution* = object
    kind*: ContributionKind
    id*: string
      ## The surface's LOCAL id. For a pane the host composes the qualified,
      ## namespaced id as `<pluginId>/<id>` — see `contributed_pane_id`.
    title*: string
    views*: seq[ViewKind]
      ## The PLAT-3 vocabulary entries this surface's ABSTRACT view is written
      ## in — §6.2's first arm, "written once in the shared vocabulary, runs on
      ## every front-end". A surface declaring none and no `nativeViews` has no
      ## view anywhere, which §6.3 decides on rather than ignores.
    nativeFrontEnds*: set[FrontEnd]
      ## §6.2's second arm: the front-ends for which this surface supplies a
      ## NATIVE view. "An extension may supply **both**: an abstract view as
      ## the baseline and a native view for one or more front-ends, with the
      ## native one preferred where present."
    requirement*: SurfaceRequirement
      ## §6.3. Read only for the surfaces that RENDER
      ## (`RenderingContributionKinds`): a command is invoked, not drawn, so
      ## "no view for this front-end" is not a condition it can be in.
    needs*: seq[string]
      ## §8.2: "A plugin declares, per surface, which of its dependencies that
      ## surface needs." Each entry is a bare program name that must also
      ## appear in the manifest's `executables` — §8.1.1 has the host resolve a
      ## tool against that declared set, so a need outside it could never be
      ## satisfied.
    install*: string
      ## §8.2: "The degradation says what is missing and **how to get it** — a
      ## name and an install action, not 'unavailable'." Required whenever
      ## `needs` is non-empty; see `pecMissingInstallHint`.
    reprobe*: seq[ActivationEvent]
      ## §8.2: "The dependency is re-probed on a declared trigger, so
      ## installing the missing component does not require restarting
      ## CodeTracer." The trigger vocabulary IS §4.2's activation events —
      ## one vocabulary rather than two, so `activation.matches` is the one
      ## comparison and a trigger cannot acquire a second spelling.
    version*: SemVer
      ## `viewModel` only. §10's open decision 3 recommends published
      ## ViewModels be versioned; recording the version now costs nothing and
      ## makes the later range check possible.

  ActivationEventKind* = enum
    aeStartup = "startup"           ## EAGER. Must carry `reason`.
    aeTraceOpened = "trace-opened"
    aeLanguage = "language"         ## argument: the language name
    aeCommand = "command"           ## argument: the command id
    aePane = "pane"                 ## argument: the pane id

  ActivationEvent* = object
    kind*: ActivationEventKind
    value*: string
      ## The event's argument. Required for `language`, `command` and `pane`;
      ## meaningless for `startup` and `trace-opened`.
    reason*: string
      ## §4.2: "An extension that activates eagerly must say why, because
      ## eager activation is how a plugin system acquires a slow startup."
      ## Required for `startup` and refused as a load-time error without it.

  Dependency* = object
    id*: PluginId
    range*: VersionRange

  PluginManifest* = object
    id*: PluginId
    version*: SemVer
    displayName*: string
    coreVersion*: VersionRange
    dependencies*: seq[Dependency]
    capabilities*: set[Capability]
      ## PLAT-7's field, kept as the shorthand every existing caller reads.
      ## It is the SAME set as `grants.capabilities` — `parseManifest` assigns
      ## both from one parse and `plugin_model_test` asserts they agree, so
      ## there is no second source of truth, only a second spelling of the one
      ## a caller most often wants.
    grants*: GrantSet
      ## PLAT-8. The capabilities WITH their declared sets: the executables a
      ## `process` grant may reach, the hosts a `socket:remote` grant may
      ## reach, the paths the `fs:*` grants may reach, and the explicit
      ## trace-egress grant. §8.4 makes this "declared in a manifest the user
      ## can read before granting", and `capabilities.decide` is what reads it.
    activation*: seq[ActivationEvent]
    contributions*: seq[Contribution]

  ParsedManifest* = object
    ## The result of reading one manifest. `errors` is empty or the manifest
    ## is not usable; there is no third state and no partially valid manifest.
    manifest*: PluginManifest
    errors*: seq[PluginError]

const
  UnknownPluginId* = "<unnamed>"
    ## What a manifest with no readable `id` is called in its own error. An
    ## error must still name SOMETHING — "malformed manifest" with no subject
    ## is the blank tab this whole module exists to refuse — and the source
    ## the caller passes in is appended to the detail.

func isOk*(p: ParsedManifest): bool =
  p.errors.len == 0

# ---------------------------------------------------------------------------
# Semantic versions
# ---------------------------------------------------------------------------

func semver*(major, minor, patch: int): SemVer =
  SemVer(major: major, minor: minor, patch: patch)

func `$`*(v: SemVer): string =
  $v.major & "." & $v.minor & "." & $v.patch

func cmpSemVer*(a, b: SemVer): int =
  if a.major != b.major: (if a.major < b.major: -1 else: 1)
  elif a.minor != b.minor: (if a.minor < b.minor: -1 else: 1)
  elif a.patch != b.patch: (if a.patch < b.patch: -1 else: 1)
  else: 0

func `<`*(a, b: SemVer): bool = cmpSemVer(a, b) < 0
func `<=`*(a, b: SemVer): bool = cmpSemVer(a, b) <= 0

func parseSemVer*(s: string; dest: var SemVer): bool =
  ## `true` on success. Three components, all decimal, no pre-release and no
  ## build metadata — the subset a plugin range needs, refusing the rest
  ## rather than half-supporting it.
  ##
  ## The digits are accumulated by hand rather than through `parseInt` so the
  ## function has no exception path at all: a version component of a thousand
  ## digits is refused as too long rather than raising out of a parser whose
  ## every other refusal is a `false`.
  let parts = s.strip().split('.')
  if parts.len != 3: return false
  var v: SemVer
  for i, p in parts:
    if p.len == 0 or p.len > 9: return false
    var n = 0
    for c in p:
      if c notin {'0' .. '9'}: return false
      n = n * 10 + (ord(c) - ord('0'))
    case i
    of 0: v.major = n
    of 1: v.minor = n
    else: v.patch = n
  dest = v
  true

func parseVersionRange*(s: string; dest: var VersionRange): bool =
  ## Two forms, and `*`:
  ##
  ##   `*`                 no constraint, said out loud
  ##   `^1.2.0`            >=1.2.0 <2.0.0 — the caret's usual meaning
  ##   `>=1.2.0 <2.0.0`    an explicit conjunction, any number of terms
  ##   `=1.2.0`            exactly this version
  ##
  ## Anything else is refused. A permissive fallback here would turn a typo
  ## into a silently unconstrained dependency, which is the same class of
  ## defect as a silently missing feature.
  var r = VersionRange(text: s.strip())
  if r.text == "*":
    dest = r
    return true
  if r.text.len == 0: return false
  for term in r.text.splitWhitespace():
    var ver: SemVer
    if term.startsWith("^"):
      if not parseSemVer(term[1 .. ^1], ver): return false
      r.bounds.add VersionBound(kind: vbAtLeast, version: ver)
      # The caret's upper bound is the next major, except below 1.0.0 where
      # the next MINOR is breaking — npm's rule, and the one authors expect.
      let upper =
        if ver.major > 0: semver(ver.major + 1, 0, 0)
        else: semver(0, ver.minor + 1, 0)
      r.bounds.add VersionBound(kind: vbLessThan, version: upper)
    elif term.startsWith(">="):
      if not parseSemVer(term[2 .. ^1], ver): return false
      r.bounds.add VersionBound(kind: vbAtLeast, version: ver)
    elif term.startsWith("<"):
      if not parseSemVer(term[1 .. ^1], ver): return false
      r.bounds.add VersionBound(kind: vbLessThan, version: ver)
    elif term.startsWith("="):
      if not parseSemVer(term[1 .. ^1], ver): return false
      r.bounds.add VersionBound(kind: vbExact, version: ver)
    else:
      return false
  dest = r
  true

func satisfies*(v: SemVer; r: VersionRange): bool =
  for b in r.bounds:
    case b.kind
    of vbAtLeast:
      if v < b.version: return false
    of vbLessThan:
      if not (v < b.version): return false
    of vbExact:
      if cmpSemVer(v, b.version) != 0: return false
  true

func describe*(r: VersionRange): string =
  if r.text.len == 0: "*" else: r.text

# ---------------------------------------------------------------------------
# The four closed sets, and the lookups that are the whole of "does not exist"
# ---------------------------------------------------------------------------

func viewKindByName*(name: string; dest: var ViewKind): bool =
  ## PLAT-3's sixteen, by PLAT-3's own spelling. DERIVED from the enum via
  ## `vocabularyName` rather than from a table written here, so this function
  ## cannot fall behind the vocabulary — which is the failure a second copy of
  ## a closed set always eventually has.
  for k in ViewKind:
    if vocabularyName(k) == name:
      dest = k
      return true
  false

func knownViewNames*(): seq[string] =
  for k in ViewKind:
    result.add vocabularyName(k)

func capabilityByName*(name: string; dest: var Capability): bool =
  for c in Capability:
    if $c == name:
      dest = c
      return true
  false

func contributionKindByName*(name: string; dest: var ContributionKind): bool =
  for k in ContributionKind:
    if $k == name:
      dest = k
      return true
  false

func activationKindByName*(name: string;
                           dest: var ActivationEventKind): bool =
  for k in ActivationEventKind:
    if $k == name:
      dest = k
      return true
  false

const
  RenderingContributionKinds* = {ckPane, ckMarker, ckStatusItem}
    ## §6.1's surfaces that DRAW. A command is invoked from the palette and a
    ## published ViewModel is consumed by other code; neither can be in the
    ## state §6.3 is about ("no view for the active front-end"), so neither is
    ## evaluated against it. Stated as a set rather than as an `if` inside the
    ## evaluator so a suite can assert the partition directly.

  FrontEndAliases*: array[6, tuple[spelling: string; frontEnd: FrontEnd]] = [
    ## §6.2 is written in PLAT-3's three rendering targets, and a plugin author
    ## thinks in `--ui` values. Both spellings are accepted and BOTH ARE
    ## LISTED, so `--ui=electron` and `--ui=webui` are visibly one rendering
    ## target rather than silently folded into one.
    ##
    ## `gui` is on the list because `ui_selection.effectiveFrontEnd` resolves
    ## it to Electron today; `tui` is the terminal. The canonical spellings
    ## (`terminal`, `web`, `gpui`) come first so an error message that prints
    ## this table leads with the vocabulary's own names.
    ("terminal", feTerminal),
    ("web", feWeb),
    ("gpui", feGpui),
    ("tui", feTerminal),
    ("electron", feWeb),
    ("webui", feWeb),
  ]

func frontEndByName*(name: string; dest: var FrontEnd): bool =
  for entry in FrontEndAliases:
    if entry.spelling == name:
      dest = entry.frontEnd
      return true
  false

func knownFrontEndNames*(): seq[string] =
  for entry in FrontEndAliases:
    result.add entry.spelling

func requirementByName*(name: string; dest: var SurfaceRequirement): bool =
  for r in SurfaceRequirement:
    if $r == name:
      dest = r
      return true
  false

const
  EventsNeedingValue* = {aeLanguage, aeCommand, aePane}
    ## The three whose meaning is entirely in the argument. `{"event":
    ## "language"}` with no language matches every language or none depending
    ## on how a matcher is written, and both readings are wrong, so it is a
    ## load-time error instead.

func isEager*(e: ActivationEvent): bool =
  e.kind == aeStartup

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

proc jstr(n: JsonNode; key: string): string =
  if n.kind == JObject and n.hasKey(key) and n[key].kind == JString:
    n[key].getStr()
  else:
    ""

proc parseManifest*(text, source: string): ParsedManifest =
  ## Read one manifest. `source` names where it came from and appears in the
  ## diagnostics; it is never used as an identity.
  ##
  ## EVERY problem is reported, not the first. A plugin author fixing a
  ## manifest one error per build is an author who stops reading errors.
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    result.errors.add pluginError(UnknownPluginId, pecMalformedManifest,
      source & ": " & e.msg)
    return
  if root.kind != JObject:
    result.errors.add pluginError(UnknownPluginId, pecMalformedManifest,
      source & ": top level is " & $root.kind & ", expected an object")
    return

  var m: PluginManifest
  m.id = jstr(root, "id")
  let named = if m.id.len > 0: m.id else: UnknownPluginId
  if m.id.len == 0:
    result.errors.add pluginError(named, pecMissingField,
      source & ": 'id' is required and must be a string")

  # PLAT-10, 2026-09-13. THE ID IS A LEDGER FIELD AND A THIRD PARTY WRITES IT.
  #
  # `grant_ledger` records one decision per line with a TAB between fields and
  # `plugin` is this string, so an id carrying a newline and four tab-separated
  # fields made ONE `grant` call append a row that reads back as a decision
  # about a DIFFERENT plugin — measured, with the victim holding `process`, the
  # capability PLAT-8 models as subsuming every other. The ledger refuses the
  # field; this refuses the ID, which is the producer, and the two have disjoint
  # evidence (Verification-Harness-Traps §16a): only this one refuses `acme
  # tool`, which a ledger row would carry perfectly well, and only the ledger's
  # refuses an `at` or a `note` no manifest ever saw.
  #
  # THE PREDICATE IS `segmentProblem` AND NOT A SECOND COPY OF ONE (§14). The
  # plugin half of every contributed pane id already goes through it — a
  # qualified id is `<plugin>/<surface>` and both segments are checked below —
  # so an id that fails here was already refused for any plugin that contributes
  # a pane, and was accepted for every plugin that does not. That gap is what is
  # being closed; the grammar is not new.
  #
  # IT DOES NOT `return`. A hostile id is a refusal and not a reason to stop
  # reading: every other problem in the manifest is still reported, which is
  # this module's rule ("EVERY problem is reported, not the first") and is also
  # what keeps the pane-id refusals below reachable for an id like `acme/tool`.
  if m.id.len > 0:
    let idProblem = segmentProblem(m.id)
    if idProblem != pipOk:
      # `describe` is written for a WHOLE pane id, and its separator arm says
      # "more than one '/'" — which is false about an id that may hold none at
      # all. Saying it anyway would be a message that is wrong about the input
      # it names, so that one arm is spelled here and every other is delegated.
      let why =
        if idProblem == pipTooManySeparators:
          "'" & m.id & "' contains '" & $PaneIdSeparator & "', which is what " &
          "separates a plugin id from a surface id and can therefore never be " &
          "inside one"
        else: describe(idProblem, m.id)
      result.errors.add pluginError(named, pecBadPluginId,
        source & ": " & why &
        ". A plugin id is written into the capability grant ledger as a " &
        "tab-separated field, composed into every contributed pane id, and " &
        "shown to a user in a list, so the charset is closed rather than " &
        "escaped at each of the three")

  m.displayName = jstr(root, "displayName")

  let versionText = jstr(root, "version")
  if versionText.len == 0:
    result.errors.add pluginError(named, pecMissingField,
      "'version' is required")
  elif not parseSemVer(versionText, m.version):
    result.errors.add pluginError(named, pecBadVersion,
      "'" & versionText & "' is not major.minor.patch")

  # ----- requires -----------------------------------------------------------
  m.coreVersion = VersionRange(text: "*")
  if root.hasKey("requires"):
    let req = root["requires"]
    if req.kind != JObject:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'requires' must be an object")
    else:
      let coreText = jstr(req, "core")
      if coreText.len > 0:
        if not parseVersionRange(coreText, m.coreVersion):
          result.errors.add pluginError(named, pecBadVersionRange,
            "requires.core '" & coreText & "' is not a version range")
      if req.hasKey("plugins"):
        let deps = req["plugins"]
        if deps.kind != JObject:
          result.errors.add pluginError(named, pecMalformedManifest,
            "'requires.plugins' must be an object of id -> range")
        else:
          for depId, rangeNode in deps.pairs:
            if rangeNode.kind != JString:
              result.errors.add pluginError(named, pecBadVersionRange,
                "requires.plugins['" & depId & "'] must be a string")
              continue
            var rng: VersionRange
            if not parseVersionRange(rangeNode.getStr(), rng):
              result.errors.add pluginError(named, pecBadVersionRange,
                "requires.plugins['" & depId & "'] = '" &
                rangeNode.getStr() & "' is not a version range")
              continue
            m.dependencies.add Dependency(id: depId, range: rng)

  # ----- capabilities -------------------------------------------------------
  if root.hasKey("capabilities"):
    let caps = root["capabilities"]
    if caps.kind != JArray:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'capabilities' must be an array")
    else:
      for c in caps:
        if c.kind != JString:
          result.errors.add pluginError(named, pecUnknownCapability,
            "a capability must be a string, got " & $c.kind)
          continue
        var cap: Capability
        if not capabilityByName(c.getStr(), cap):
          var known: seq[string] = @[]
          for k in Capability: known.add $k
          result.errors.add pluginError(named, pecUnknownCapability,
            "'" & c.getStr() & "' — the granted set is " & known.join(", "))
          continue
        m.capabilities.incl cap

  # ----- the declared sets (PLAT-8, §8.1.1 and §8.4) -------------------------
  #
  # A capability says WHICH POWER; a declaration says WHICH TARGETS. §8.4's
  # whole argument that the sandbox survives §8 is that "the executables and
  # hosts a plugin may reach are declared in a manifest the user can read
  # before granting", so the two are validated against each other in BOTH
  # directions: a grant with an empty declared set permits nothing, and a
  # declaration without its grant reads to a user as a power the plugin has.
  if root.hasKey("executables"):
    let execs = root["executables"]
    if execs.kind != JArray:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'executables' must be an array of bare program names")
    else:
      for e in execs:
        if e.kind != JString:
          result.errors.add pluginError(named, pecBadDeclaration,
            "an executable declaration must be a string, got " & $e.kind)
          continue
        let nm = e.getStr()
        if not isBareExecutableName(nm):
          result.errors.add pluginError(named, pecBadDeclaration,
            "'" & nm & "' is not a bare program name. §8.1.1: the host " &
            "resolves the name against this set and its own PATH policy, so " &
            "a plugin does not hand over a path of its choosing")
          continue
        m.grants.executables.add nm

  if root.hasKey("hosts"):
    let hosts = root["hosts"]
    if hosts.kind != JArray:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'hosts' must be an array of 'host' or 'host:port' strings")
    else:
      for h in hosts:
        if h.kind != JString:
          result.errors.add pluginError(named, pecBadDeclaration,
            "a host declaration must be a string, got " & $h.kind)
          continue
        var text = h.getStr().strip()
        var port = AnyPort
        # `host:port`, and the separator is recognised ONLY where it cannot be
        # part of a bare IPv6 literal: after a `]`, or when the string carries
        # exactly one colon. `::1` therefore stays `::1` rather than becoming
        # the host `::` on port 1, which is what a plain `rfind(':')` does to it.
        let colon = text.rfind(':')
        let bracket = text.rfind(']')
        let colonCount = text.count(':')
        let isSeparator = colon > 0 and colon < text.high and
          ((bracket >= 0 and bracket < colon) or
           (bracket < 0 and colonCount == 1))
        if isSeparator:
          let portText = text[colon + 1 .. ^1]
          var n = 0
          var ok = portText.len > 0 and portText.len <= 5
          if ok:
            for c in portText:
              if c notin {'0' .. '9'}:
                ok = false
                break
              n = n * 10 + (ord(c) - ord('0'))
          if not (ok and n >= 1 and n <= 65535):
            result.errors.add pluginError(named, pecBadDeclaration,
              "host '" & h.getStr() & "' has a port outside 1-65535")
            continue
          port = n
          text = text[0 ..< colon]
        if text.len == 0:
          result.errors.add pluginError(named, pecBadDeclaration,
            "host '" & h.getStr() & "' names no host")
          continue
        if classifyHost(text) == acAmbiguous:
          result.errors.add pluginError(named, pecBadDeclaration,
            "host '" & text & "' is a name the machine resolves rather than " &
            "an address. Declare loopback as 127.0.0.1 or ::1, which " &
            "'socket:local' already grants")
          continue
        m.grants.hosts.add DeclaredHost(host: text, port: port)

  if root.hasKey("paths"):
    let paths = root["paths"]
    if paths.kind != JObject:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'paths' must be an object with 'read' and/or 'write' arrays")
    else:
      for key in ["read", "write"]:
        if not paths.hasKey(key): continue
        if paths[key].kind != JArray:
          result.errors.add pluginError(named, pecMalformedManifest,
            "'paths." & key & "' must be an array")
          continue
        for p in paths[key]:
          if p.kind != JString:
            result.errors.add pluginError(named, pecBadDeclaration,
              "a path declaration must be a string, got " & $p.kind)
            continue
          let text = p.getStr()
          if text.len == 0 or not (text.startsWith("/") or
                                   (text.len > 2 and text[1] == ':')):
            result.errors.add pluginError(named, pecBadDeclaration,
              "path '" & text & "' is not absolute. A relative declared root " &
              "means a different directory depending on where CodeTracer was " &
              "started, which is not something a user can grant")
            continue
          if ".." in text:
            result.errors.add pluginError(named, pecBadDeclaration,
              "path '" & text & "' contains '..'; declare the directory it " &
              "resolves to")
            continue
          if key == "read": m.grants.readPaths.add text
          else: m.grants.writePaths.add text

  # ----- the explicit trace-egress grant (§8.1.2, PLAT-8's gate) -------------
  if root.hasKey("traceEgress"):
    let te = root["traceEgress"]
    if te.kind != JObject:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'traceEgress' must be an object with 'acknowledged' and 'statement'")
    else:
      let ack = te.hasKey("acknowledged") and te["acknowledged"].kind == JBool and
                te["acknowledged"].getBool()
      let statement = jstr(te, "statement")
      m.grants.traceEgress = TraceEgressGrant(acknowledged: ack,
                                              statement: statement)

  m.grants.capabilities = m.capabilities

  # Both directions, per capability. Each arm names the plugin, the grant and
  # the remedy, because a manifest error a user cannot act on is the blank tab
  # §4.1 refuses in a different costume.
  if capProcess in m.capabilities and m.grants.executables.len == 0:
    result.errors.add pluginError(named, pecCapabilityWithoutDeclaration,
      "'process' is granted but no 'executables' are declared, so the plugin " &
      "may spawn nothing. §8.1.1 has the host resolve a name against a " &
      "declared set; declare the programs it needs")
  if capProcess notin m.capabilities and m.grants.executables.len > 0:
    result.errors.add pluginError(named, pecDeclarationWithoutCapability,
      "'executables' are declared without the 'process' capability")
  if capSocketRemote in m.capabilities and m.grants.hosts.len == 0:
    result.errors.add pluginError(named, pecCapabilityWithoutDeclaration,
      "'socket:remote' is granted but no 'hosts' are declared. §8.1.2 grants " &
      "it 'to declared hosts', and the declaration is what makes the grant " &
      "inspectable")
  if capSocketRemote notin m.capabilities and m.grants.hosts.len > 0:
    result.errors.add pluginError(named, pecDeclarationWithoutCapability,
      "'hosts' are declared without the 'socket:remote' capability")
  if capFsRead in m.capabilities and m.grants.readPaths.len == 0:
    result.errors.add pluginError(named, pecCapabilityWithoutDeclaration,
      "'fs:read' is granted but 'paths.read' declares nothing")
  if capFsRead notin m.capabilities and m.grants.readPaths.len > 0:
    result.errors.add pluginError(named, pecDeclarationWithoutCapability,
      "'paths.read' is declared without the 'fs:read' capability")
  if capFsWrite in m.capabilities and m.grants.writePaths.len == 0:
    result.errors.add pluginError(named, pecCapabilityWithoutDeclaration,
      "'fs:write' is granted but 'paths.write' declares nothing")
  if capFsWrite notin m.capabilities and m.grants.writePaths.len > 0:
    result.errors.add pluginError(named, pecDeclarationWithoutCapability,
      "'paths.write' is declared without the 'fs:write' capability")

  # THE PAIR. Refused at LOAD time, so a plugin holding it without the grant
  # never activates at all — the runtime refusal in `capabilities.decide` is
  # the second of two, not the only one.
  if needsTraceEgressGrant(m.capabilities):
    if not traceEgressPermitted(m.grants):
      result.errors.add pluginError(named, pecTraceEgressNotAcknowledged,
        traceEgressDisclosure(named, m.grants) &
        " Declare \"traceEgress\": {\"acknowledged\": true, \"statement\": " &
        "\"<why this plugin sends recorded data off the machine>\"} — at " &
        "least " & $MinTraceEgressStatement & " characters of statement.")
  elif m.grants.traceEgress.acknowledged or
       m.grants.traceEgress.statement.len > 0:
    result.errors.add pluginError(named, pecTraceEgressWithoutPair,
      "a 'traceEgress' grant is declared, but this plugin holds " &
      (if capTrace in m.capabilities: "'trace' without 'socket:remote'"
       elif capSocketRemote in m.capabilities: "'socket:remote' without 'trace'"
       else: "neither 'trace' nor 'socket:remote'") &
      ". Asking a user to acknowledge a path the plugin cannot take teaches " &
      "them to acknowledge the next one without reading it")

  # ----- activation ---------------------------------------------------------
  if root.hasKey("activation"):
    let acts = root["activation"]
    if acts.kind != JArray:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'activation' must be an array")
    else:
      for a in acts:
        if a.kind != JObject:
          result.errors.add pluginError(named, pecUnknownActivation,
            "an activation entry must be an object")
          continue
        let evName = jstr(a, "event")
        var evKind: ActivationEventKind
        if not activationKindByName(evName, evKind):
          var known: seq[string] = @[]
          for k in ActivationEventKind: known.add $k
          result.errors.add pluginError(named, pecUnknownActivation,
            "'" & evName & "' — the declared set is " & known.join(", "))
          continue
        var ev = ActivationEvent(kind: evKind, value: jstr(a, "value"),
                                 reason: jstr(a, "reason"))
        if evKind in EventsNeedingValue and ev.value.len == 0:
          result.errors.add pluginError(named, pecActivationValueMissing,
            "activation event '" & evName & "' needs a 'value'")
          continue
        if evKind == aeStartup and ev.reason.len == 0:
          # §4.2, and the reason the rule exists is in the detail rather than
          # in a comment nobody reading the error will see.
          result.errors.add pluginError(named, pecEagerWithoutReason,
            "eager activation must carry a 'reason'; lazy activation on a " &
            "declared event is the default because eager activation is how " &
            "a plugin system acquires a slow startup")
          continue
        m.activation.add ev

  # ----- contributions ------------------------------------------------------
  if root.hasKey("contributes"):
    let contributes = root["contributes"]
    if contributes.kind != JObject:
      result.errors.add pluginError(named, pecMalformedManifest,
        "'contributes' must be an object keyed by surface kind")
    else:
      for kindName, entries in contributes.pairs:
        var ck: ContributionKind
        if not contributionKindByName(kindName, ck):
          var known: seq[string] = @[]
          for k in ContributionKind: known.add $k
          result.errors.add pluginError(named, pecUnknownContribution,
            "'" & kindName & "' — the contributable surfaces are " &
            known.join(", "))
          continue
        if entries.kind != JArray:
          result.errors.add pluginError(named, pecMalformedManifest,
            "'contributes." & kindName & "' must be an array")
          continue
        for entry in entries:
          if entry.kind != JObject:
            result.errors.add pluginError(named, pecMalformedManifest,
              "'contributes." & kindName & "' entries must be objects")
            continue
          var c = Contribution(kind: ck, id: jstr(entry, "id"),
                               title: jstr(entry, "title"))
          if c.id.len == 0:
            result.errors.add pluginError(named, pecMissingField,
              "a '" & kindName & "' contribution needs an 'id'")
            continue
          if entry.hasKey("views"):
            let views = entry["views"]
            if views.kind != JArray:
              result.errors.add pluginError(named, pecMalformedManifest,
                "'views' of '" & c.id & "' must be an array")
              continue
            var viewProblem = false
            for v in views:
              if v.kind != JString:
                result.errors.add pluginError(named, pecUnknownView,
                  "a view name must be a string, got " & $v.kind)
                viewProblem = true
                continue
              var vk: ViewKind
              if not viewKindByName(v.getStr(), vk):
                # THE ERROR NAMES THE PLUGIN, THE SURFACE AND THE ENTRY, and
                # lists the closed set — §4.1's "never a silently missing
                # feature", spelled so the author can fix it from the message.
                result.errors.add pluginError(named, pecUnknownView,
                  "'" & c.id & "' names view '" & v.getStr() &
                  "' — PLAT-3's vocabulary is " & knownViewNames().join(", "))
                viewProblem = true
                continue
              c.views.add vk
            if viewProblem: continue
          if entry.hasKey("version"):
            let vtext = jstr(entry, "version")
            if not parseSemVer(vtext, c.version):
              result.errors.add pluginError(named, pecBadVersion,
                "'" & c.id & "' declares version '" & vtext & "'")
              continue

          # ----- PLAT-9: the surface's own declarations --------------------
          #
          # A PANE'S QUALIFIED ID IS VALIDATED HERE, WHERE IT ENTERS. It is
          # composed from the plugin id and this contribution's id, persisted
          # into a layout document the desktop reads back, and rendered into a
          # tab. Refusing a malformed one at the boundary is what keeps every
          # later consumer — the encoder, the decoder, the renderer — free of
          # a second opinion about what an id may contain.
          if ck == ckPane:
            let qualified = qualifiedPaneId(named, c.id)
            let idProblem = paneIdProblem(qualified)
            if idProblem != pipOk:
              result.errors.add pluginError(named, pecBadContributedPaneId,
                describe(idProblem, qualified))
              continue

          if entry.hasKey("requirement"):
            let rtext = jstr(entry, "requirement")
            if not requirementByName(rtext, c.requirement):
              var known: seq[string] = @[]
              for r in SurfaceRequirement: known.add $r
              result.errors.add pluginError(named, pecUnknownRequirement,
                "'" & c.id & "' declares requirement '" & rtext &
                "' — §6.3 has exactly " & known.join(" and "))
              continue

          var surfaceProblem = false

          if entry.hasKey("nativeViews"):
            let natives = entry["nativeViews"]
            if natives.kind != JArray:
              result.errors.add pluginError(named, pecMalformedManifest,
                "'nativeViews' of '" & c.id & "' must be an array of " &
                "front-end names")
              continue
            for n in natives:
              if n.kind != JString:
                result.errors.add pluginError(named, pecUnknownFrontEnd,
                  "a front-end name must be a string, got " & $n.kind)
                surfaceProblem = true
                continue
              var fe: FrontEnd
              if not frontEndByName(n.getStr(), fe):
                result.errors.add pluginError(named, pecUnknownFrontEnd,
                  "'" & c.id & "' declares a native view for '" & n.getStr() &
                  "' — the front-ends are " & knownFrontEndNames().join(", "))
                surfaceProblem = true
                continue
              c.nativeFrontEnds.incl fe

          if entry.hasKey("needs"):
            let needs = entry["needs"]
            if needs.kind != JArray:
              result.errors.add pluginError(named, pecMalformedManifest,
                "'needs' of '" & c.id & "' must be an array of bare program " &
                "names")
              continue
            for n in needs:
              if n.kind != JString:
                result.errors.add pluginError(named, pecBadDeclaration,
                  "a dependency must be a string, got " & $n.kind)
                surfaceProblem = true
                continue
              let tool = n.getStr()
              if not isBareExecutableName(tool):
                result.errors.add pluginError(named, pecBadDeclaration,
                  "'" & c.id & "' needs '" & tool & "', which is not a bare " &
                  "program name. §8.1.1 has the host resolve the name; a " &
                  "plugin does not hand over a path of its choosing")
                surfaceProblem = true
                continue
              c.needs.add tool

          c.install = jstr(entry, "install")

          if entry.hasKey("reprobe"):
            let triggers = entry["reprobe"]
            if triggers.kind != JArray:
              result.errors.add pluginError(named, pecMalformedManifest,
                "'reprobe' of '" & c.id & "' must be an array of activation " &
                "event objects")
              continue
            for t in triggers:
              if t.kind != JObject:
                result.errors.add pluginError(named, pecUnknownReprobeTrigger,
                  "a re-probe trigger must be an object, got " & $t.kind)
                surfaceProblem = true
                continue
              let tname = jstr(t, "event")
              var tkind: ActivationEventKind
              if not activationKindByName(tname, tkind):
                var known: seq[string] = @[]
                for k in ActivationEventKind: known.add $k
                result.errors.add pluginError(named, pecUnknownReprobeTrigger,
                  "'" & c.id & "' re-probes on '" & tname &
                  "' — the trigger vocabulary is §4.2's activation events: " &
                  known.join(", "))
                surfaceProblem = true
                continue
              let tvalue = jstr(t, "value")
              if tkind in EventsNeedingValue and tvalue.len == 0:
                result.errors.add pluginError(named, pecUnknownReprobeTrigger,
                  "re-probe trigger '" & tname & "' on '" & c.id &
                  "' needs a 'value', for the same reason the activation " &
                  "event does: without one it matches every value or none")
                surfaceProblem = true
                continue
              c.reprobe.add ActivationEvent(kind: tkind, value: tvalue,
                                            reason: "")

          if surfaceProblem: continue

          # §8.2's two rules about a declared dependency, both refused at LOAD
          # time because both describe a surface that could only ever be
          # permanently and inexplicably degraded.
          if c.needs.len > 0 and c.install.strip().len == 0:
            result.errors.add pluginError(named, pecMissingInstallHint,
              "'" & c.id & "' needs " & c.needs.join(", ") & " but declares " &
              "no 'install'. §8.2: the degradation says what is missing AND " &
              "how to get it — a name and an install action, not " &
              "'unavailable'")
            continue

          m.contributions.add c

  # ----- PLAT-9 / §6.1: two rendering surfaces may not share a local id ------
  #
  # AFTER the contributions loop, because the rule relates two entries and both
  # have to have been read — and because `contributes` is a JSON OBJECT keyed by
  # kind, so a pane and a marker arrive in different iterations of the outer
  # loop and neither can see the other.
  #
  # WHY THE SET IS `RenderingContributionKinds` AND NOT EVERY CONTRIBUTION.
  # These are the kinds that share ONE namespace: the surface host keys its
  # registry on `qualifiedPaneId(plugin, id)`, which carries no kind, and
  # `plugin_api.declaresSurface` and `contributeView` both look a surface up by
  # local id across exactly this set. A `command` called `metrics` collides
  # with nothing — it is reached by `commandIds`, never by either of those —
  # so refusing it would be a rule without a failure behind it.
  #
  # REFUSED AT LOAD RATHER THAN QUALIFIED BY KIND, and the trade is worth
  # stating: putting the kind into the id would also make the collision
  # impossible, and it would change the shape of a string that is PERSISTED
  # into every saved layout document and validated by a grammar whose central
  # invariant is "exactly one separator" (`contributed_pane_id.nim`). That is a
  # format migration and a weakened grammar to fix a manifest that is a typo in
  # every real instance. Refusing costs an author one rename, names both
  # contributions so they can see which, and — Verification-Harness-Traps §17 —
  # refusing at load is the better place on its own merits.
  var surfaceKindById = initTable[string, ContributionKind]()
  for c in m.contributions:
    if c.kind notin RenderingContributionKinds: continue
    if surfaceKindById.hasKey(c.id):
      result.errors.add pluginError(named, pecDuplicateContribution,
        "'" & c.id & "' is declared as both a " & $surfaceKindById[c.id] &
        " and a " & $c.kind & " surface. Both compose the qualified id '" &
        qualifiedPaneId(named, c.id) & "', which is the surface registry's " &
        "one key and the id `contributeView` resolves, so only one of them " &
        "could ever be registered or rendered. Rename one of the two")
      continue
    surfaceKindById[c.id] = c.kind

  # ----- PLAT-9 / §8.2: a need outside the declared set can never be met -----
  #
  # AFTER the contributions loop, because it relates two sections of the
  # manifest and both have to have been read. §8.1.1 has the host resolve a
  # tool name "against a declared set and its own PATH policy", so a surface
  # needing `ripgrep` in a manifest whose `executables` does not name it
  # describes a dependency the host would refuse to use even if it were
  # installed — a surface that is degraded forever, for a reason the
  # degradation could not state.
  for c in m.contributions:
    for tool in c.needs:
      if tool notin m.grants.executables:
        result.errors.add pluginError(named, pecUndeclaredDependency,
          "'" & c.id & "' needs '" & tool & "', which 'executables' does " &
          "not declare. §8.1.1 resolves a tool against the declared set, so " &
          "this surface could not use it even where it is installed")

  result.manifest = m

# ---------------------------------------------------------------------------
# Reading a manifest back
# ---------------------------------------------------------------------------

func contributionsOf*(m: PluginManifest; k: ContributionKind): seq[Contribution] =
  for c in m.contributions:
    if c.kind == k: result.add c

func commandIds*(m: PluginManifest): seq[string] =
  for c in m.contributions:
    if c.kind == ckCommand: result.add c.id

func eagerReasons*(m: PluginManifest): Table[string, string] =
  ## Every eager activation this plugin declares, with the reason it gave.
  ## A `Table` rather than a `seq` because the interesting question is "does
  ## it activate eagerly, and what did it say", not "how many times".
  result = initTable[string, string]()
  for a in m.activation:
    if a.isEager:
      result[$a.kind] = a.reason

func activatesEagerly*(m: PluginManifest): bool =
  for a in m.activation:
    if a.isEager: return true
  false
