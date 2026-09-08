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
import ../value_presentation/vocabulary as presentation_vocabulary
import ../view_vocabulary/vocabulary as view_vocabulary

export diagnostics

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

  Capability* = enum
    ## Extensibility-Model.md §8.1.2's table, verbatim in its own spellings.
    ## PLAT-7 records the grant; PLAT-8 is what makes each one do anything.
    capProcess = "process"
    capSocketLocal = "socket:local"
    capSocketRemote = "socket:remote"
    capFsRead = "fs:read"
    capFsWrite = "fs:write"
    capTrace = "trace"

  ContributionKind* = enum
    ## §6.1's four surfaces, plus the published ViewModel §2 names as the
    ## second of the three things an extension may do.
    ckPane = "pane"
    ckCommand = "command"
    ckMarker = "marker"
    ckStatusItem = "statusItem"
    ckViewModel = "viewModel"

  Contribution* = object
    kind*: ContributionKind
    id*: string
    title*: string
    views*: seq[ViewKind]
      ## PANES ONLY. The PLAT-3 vocabulary entries this surface is written in
      ## — §6.2's "abstract" arm. A pane declaring none is declaring a native
      ## view, which is PLAT-9's business and not refused here.
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
          m.contributions.add c

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
