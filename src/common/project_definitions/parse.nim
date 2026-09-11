## project_definitions/parse.nim — PLAT-11. Reading one declarative
## definition file out of a repository somebody cloned and has not read.
##
## ## THE INPUT IS HOSTILE AND NOBODY AGREED TO IT
##
## Project-Definitions.md §1.1 states the asymmetry this file is built around:
## "A plugin is installed once by a user who evaluated it. A project
## definition is acquired by cloning, and a user who clones a repository to
## *look* at it has evaluated nothing."
##
## So this parser gets `plugin_model/manifest.nim`'s discipline and then some:
## a closed grammar, bounded sizes checked before the parser is entered, typed
## refusals naming the file and the line, and **no "unrecognised, ignored" arm
## anywhere in this file**. That absence is the deliverable, exactly as it is
## in the manifest parser.
##
## ## HOW EXECUTING IS MADE INEXPRESSIBLE
##
## The rule that decides whether this module is right is §2's:
##
##   "Cloning a repository and opening it in CodeTracer must not execute code
##    from that repository."
##
## The weak way to satisfy it is a check: parse a `command` key and refuse it.
## That is one `if` away from a regression, and it is the shape that has to be
## re-argued every time somebody adds a feature. The strong way is that there
## is nothing to refuse, and it is built from four properties, each of which a
## test asserts directly:
##
##   1. **Every accepted key is enumerated.** `AcceptedKeys` below is the
##      whole grammar. `acceptedKeysFor` is total over the tables, and a key
##      outside the set is `pdcUnknownKey`. A key that takes a program is not
##      refused — it does not exist, so there is no code path that reads one.
##      `project_definitions_test` asserts the accepted-key set against a
##      literal, so ADDING a key that names a program turns the suite red
##      before it can turn a user's machine into someone else's.
##   2. **No accepted value is a path to something loadable.** The only
##      path-shaped value in the grammar is a point's `path`, which is a
##      SOURCE file to put a breakpoint in, is `containment`-checked, and is
##      never opened by anything in this package.
##   3. **The file set is a constant** (`layout.nim`): nothing a definition
##      says can cause any other file to be opened. There is no `include`, no
##      `extends`, no `natvisFile`.
##   4. **Matching and templating are total** (`model.nim`): three O(n) string
##      predicates and one linear substitution pass, so "bounded evaluation"
##      needs no budget, no timeout and no partial answer.
##
## Executing is therefore not a thing this grammar can say. The hostile-input
## cases in the suite — an `interpreter` key, an `exec` key, a `command` key,
## a `script` key — all land on `pdcUnknownKey` for the same structural
## reason a misspelled `enabled` does, and that sameness is the evidence:
## there is no special handling, because there is nothing special about them.
##
## ## BOUNDS COME BEFORE SYNTAX
##
## `MaxDefinitionBytes` and `MaxDefinitionLines` are checked against the raw
## text before `parseTomlSubset` is called, so a nesting bomb or a
## hundred-megabyte file is refused without being tokenised. The reader's own
## `MaxTomlNesting` then bounds the recursion for everything that gets past
## the size gate — a bound this package NAMES rather than restates, so the two
## cannot drift.

import std/[strutils, tables]

import ../toml_subset
import ./diagnostics
import ./containment
import ./layout
import ./model

# ---------------------------------------------------------------------------
# The closed grammar
# ---------------------------------------------------------------------------

type
  TableId* = enum
    ## Every table a definition file may contain, across all three declarative
    ## kinds. An enum rather than strings at the call sites so `AcceptedKeys`
    ## can be an array indexed by it and a new table cannot be added without
    ## its key set.
    tiRootPoints      ## the top level of `points.toml`
    tiRootVisualisers ## the top level of `visualisers.toml`
    tiRootScratchpad  ## the top level of `scratchpad.toml`
    tiCollection      ## `[[collection]]`
    tiCollectionPoint ## `[[collection.point]]`
    tiVisualiser      ## `[[visualiser]]`
    tiDiff            ## `[[diff]]`

const
  AcceptedKeys*: array[TableId, seq[string]] = [
    # tiRootPoints
    @["schema", "collection"],
    # tiRootVisualisers
    @["schema", "visualiser"],
    # tiRootScratchpad
    @["schema", "diff"],
    # tiCollection
    @["name", "enabled", "point"],
    # tiCollectionPoint
    @["kind", "path", "anchor", "occurrence", "offset", "line", "expression",
      "label"],
    # tiVisualiser
    @["match", "matchKind", "language", "summary", "hide", "present", "media",
      "mediaFrom"],
    # tiDiff
    @["match", "matchKind", "algorithm", "tolerance"],
  ]
    ## THE WHOLE GRAMMAR, in one place a reader can audit in ten seconds.
    ##
    ## THE ROOT IS THREE ROWS, NOT ONE, and that is a repair the suite forced:
    ## with one shared root row, `points.toml` and `visualisers.toml` accepted
    ## each other's top-level table, and a `[[visualiser]]` written into
    ## `points.toml` would have been read by nobody and reported by nobody —
    ## the "unrecognised, ignored" arm this file exists not to have, arriving
    ## through the table name instead of through a key.
    ##
    ## Twenty-nine keys. Not one of them takes a program name, a command line,
    ## an interpreter, a shell, a library, a URL, or a path to anything that
    ## is loaded rather than displayed. `path` is a SOURCE file a breakpoint
    ## goes in; `mediaFrom` is a field name inside a recorded value.
    ##
    ## `project_definitions_test` asserts this array against a literal copy.
    ## That is deliberately a second copy of the data — the one place in this
    ## package where §14's "one predicate, one function" is knowingly not
    ## followed — because the thing being guarded is not a computation, it is
    ## a *decision about what may exist*, and a guard that derived itself from
    ## the subject would approve of whatever the subject said.

  DeclarativeMediaTypes* = [
    ## §5.2's table, as the MIME types a rule may declare. A closed list
    ## rather than "any `type/subtype`", because every entry here is something
    ## a surface must know how to render, and a type nothing renders is a
    ## silently blank value — `lpUnknownPane` at value scale.
    "image/png", "image/jpeg", "image/svg+xml",
    "audio/wav", "audio/ogg",
    "text/markdown", "text/html",
    "application/octet-stream",
  ]

  MinOccurrence = 1
  MaxOccurrence = 10_000
  MaxOffset = 10_000
  MaxLineHint = 10_000_000

# ---------------------------------------------------------------------------
# Small total readers
# ---------------------------------------------------------------------------

func boundedDecimal*(s: string; dest: var int; lo, hi: int): bool =
  ## A non-negative decimal, accumulated by hand.
  ##
  ## BY HAND rather than through `parseInt` so this function has no exception
  ## path at all — the same reason `manifest.parseSemVer` does it: a loader
  ## whose every other refusal is a value must not have one refusal that
  ## raises, or every caller needs a `try` for one case.
  ##
  ## THE NUMBERS ARE QUOTED IN THE FILE (`occurrence = "2"`), and that is a
  ## consequence of `common/toml_subset` admitting strings, booleans, arrays
  ## and tables and nothing else. Widening the shared reader to admit integers
  ## would change what a TEST CERTIFICATE accepts — the other consumer, which
  ## refuses everything outside its subset on purpose — so the narrower
  ## reader keeps its refusals and this grammar quotes its numbers.
  if s.len == 0 or s.len > MaxNumberBytes: return false
  var n = 0
  for c in s:
    if c notin {'0' .. '9'}: return false
    n = n * 10 + (ord(c) - ord('0'))
    if n > hi: return false
  if n < lo: return false
  dest = n
  true

func boundedTolerance*(s: string): bool =
  ## `0`, `0.5`, `1e-6`, `2.5e-3`. A closed grammar rather than `parseFloat`,
  ## for the same no-exception reason, and bounded in every part so the
  ## accumulator cannot be made to do interesting work.
  if s.len == 0 or s.len > MaxNumberBytes: return false
  var i = 0
  var digits = 0
  while i < s.len and s[i] in {'0' .. '9'}:
    inc i
    inc digits
  if digits == 0 or digits > 9: return false
  if i < s.len and s[i] == '.':
    inc i
    var frac = 0
    while i < s.len and s[i] in {'0' .. '9'}:
      inc i
      inc frac
    if frac == 0 or frac > 9: return false
  if i < s.len and (s[i] == 'e' or s[i] == 'E'):
    inc i
    if i < s.len and (s[i] == '-' or s[i] == '+'): inc i
    var expDigits = 0
    while i < s.len and s[i] in {'0' .. '9'}:
      inc i
      inc expDigits
    if expDigits == 0 or expDigits > 2: return false
  i == s.len

type
  TemplateProblem* = enum
    tpOk
    tpUnterminated     ## a `{` with no `}`
    tpNested           ## a `{` inside a placeholder
    tpEmptyPlaceholder ## `{}`
    tpTooManyPlaceholders
    tpPlaceholderTooLong
    tpBadPlaceholderChar

func templateProblem*(s: string): TemplateProblem =
  ## §2.2: "Matching and **templating** are total and terminate by
  ## construction."
  ##
  ## Validated HERE, at parse time, so substitution later is one linear pass
  ## that cannot fail: a well-formed template has balanced, non-nested,
  ## bounded placeholders over a closed identifier charset, and substituting
  ## a field's text into one never produces another placeholder because the
  ## result is not re-scanned. There is no recursion to bound because there is
  ## no recursion.
  ##
  ## `{{` is an escaped literal brace, so a summary CAN contain a `{`.
  if s.len > MaxSummaryBytes: return tpPlaceholderTooLong
  var i = 0
  var count = 0
  while i < s.len:
    if s[i] == '{':
      if i + 1 < s.len and s[i + 1] == '{':
        i += 2
        continue
      inc count
      if count > MaxTemplatePlaceholders: return tpTooManyPlaceholders
      var j = i + 1
      var nameLen = 0
      while j < s.len and s[j] != '}':
        if s[j] == '{': return tpNested
        if s[j] notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '.'}:
          return tpBadPlaceholderChar
        inc j
        inc nameLen
        if nameLen > MaxFieldNameBytes: return tpPlaceholderTooLong
      if j >= s.len: return tpUnterminated
      if nameLen == 0: return tpEmptyPlaceholder
      i = j + 1
    else:
      inc i
  tpOk

func describeTemplate*(p: TemplateProblem): string =
  case p
  of tpOk: "a well-formed summary template"
  of tpUnterminated: "a '{' with no closing '}'"
  of tpNested: "a '{' inside a placeholder; placeholders do not nest"
  of tpEmptyPlaceholder: "an empty placeholder '{}'"
  of tpTooManyPlaceholders:
    "more than " & $MaxTemplatePlaceholders & " placeholders"
  of tpPlaceholderTooLong:
    "a placeholder or a summary longer than the bound"
  of tpBadPlaceholderChar:
    "a placeholder naming something that is not a field: a placeholder is " &
    "letters, digits, '_' and '.'"

# ---------------------------------------------------------------------------
# The reader
# ---------------------------------------------------------------------------

type
  FileReader = object
    ## One file being read. `problems` accumulates EVERY problem rather than
    ## the first, for `manifest.parseManifest`'s reason: an author fixing a
    ## file one error per run is an author who stops reading errors.
    file: DefinitionFile
    problems: seq[ProjectDefinitionProblem]
    refused: bool
      ## Set when the file as a whole contributes nothing — a size bound, a
      ## syntax error, an unknown schema. Distinct from "some entry was
      ## refused", which leaves the rest of the file usable.

proc note(r: var FileReader; code: ProjectDefinitionCode; detail: string;
          line = 0) =
  r.problems.add problem(r.file.path, line, code, detail)

func pointKindByName(name: string; dest: var PointKind): bool =
  for k in PointKind:
    if $k == name:
      dest = k
      return true
  false

func matchKindByName(name: string; dest: var MatchKind): bool =
  for k in MatchKind:
    if $k == name:
      dest = k
      return true
  false

func diffAlgorithmByName(name: string; dest: var DiffAlgorithm): bool =
  for a in DiffAlgorithm:
    if $a == name:
      dest = a
      return true
  false

func presentationByName(name: string; dest: var PresentationKind): bool =
  ## DERIVED from the enum, and then narrowed to `ValuePresentationKinds`.
  ##
  ## The narrowing is the interesting half. PLAT-3's vocabulary has sixteen
  ## entries and a recorded VALUE can inhabit five of them; a definition
  ## declaring `present = "Button"` is not naming a rare presentation, it is
  ## naming something a value cannot be. Refusing it here rather than letting
  ## PLAT-12 discover it is §4.1's rule — a declaration naming something that
  ## does not exist is a load-time error, never a silently missing feature.
  for k in PresentationKind:
    if presentationSpelling(k) == name:
      if k notin ValuePresentationKinds: return false
      dest = k
      return true
  false

func knownPresentationNames*(): seq[string] =
  for k in PresentationKind:
    if k in ValuePresentationKinds: result.add presentationSpelling(k)

func knownPointKinds*(): seq[string] =
  for k in PointKind: result.add $k

func knownMatchKinds*(): seq[string] =
  for k in MatchKind: result.add $k

func knownDiffAlgorithms*(): seq[string] =
  for a in DiffAlgorithm: result.add $a

proc rootTableFor(k: DefinitionFileKind): TableId =
  ## Which root row governs a file of this kind. TOTAL over the enum; the two
  ## executable kinds are never parsed, and naming them here rather than
  ## falling through an `else` is what makes that a decision rather than an
  ## accident.
  case k
  of dfkPoints: tiRootPoints
  of dfkVisualisers: tiRootVisualisers
  of dfkScratchpad: tiRootScratchpad
  of dfkVisualiserCode, dfkDiffCode: tiRootPoints

proc checkKeys(r: var FileReader; node: TomlNode; table: TableId;
               where: string): bool =
  ## THE CLOSED-KEY CHECK. Every table in every declarative file goes through
  ## it, and there is no arm that tolerates an unknown key.
  ##
  ## IT RETURNS A VERDICT AND THE CALLER ABANDONS THE ENTRY. Noting the
  ## problem and carrying on would load a rule whose author wrote something
  ## this build did not read — which is a partial honouring of a file, and §6
  ## forbids exactly that for a schema version. A key is the same question one
  ## level down.
  result = true
  if node == nil or node.kind != tomlTable: return
  for key in node.fields.keys:
    if key notin AcceptedKeys[table]:
      r.note(pdcUnknownKey,
        where & " has no key '" & key & "'. The keys it accepts are " &
        AcceptedKeys[table].join(", ") & ". A project definition is data: " &
        "there is no key here that names a program, a command, an " &
        "interpreter or a file to load, and adding one would move this file " &
        "into the executable tier, which loads only behind an explicit " &
        "per-repository trust grant (Project-Definitions.md §2.1)")
      result = false

proc stringField(r: var FileReader; node: TomlNode; key, where: string;
                 maxBytes: int; required: bool; dest: var string): bool =
  ## Read one bounded string. Returns `false` when the entry it belongs to
  ## should be abandoned.
  let child = node.field(key)
  if child == nil:
    if required:
      r.note(pdcMissingField, where & " needs '" & key & "'")
      return false
    dest = ""
    return true
  if child.kind != tomlString:
    r.note(pdcWrongType, where & "'s '" & key & "' must be a string")
    return false
  if child.strVal.len > maxBytes:
    r.note(pdcValueTooLong,
      where & "'s '" & key & "' is longer than " & $maxBytes & " bytes")
    return false
  dest = child.strVal
  true

proc boolField(r: var FileReader; node: TomlNode; key, where: string;
               dest: var bool): bool =
  let child = node.field(key)
  if child == nil: return true
  if child.kind != tomlBool:
    r.note(pdcWrongType, where & "'s '" & key & "' must be true or false")
    return false
  dest = child.boolVal
  true

proc intField(r: var FileReader; node: TomlNode; key, where: string;
              lo, hi: int; dest: var int): bool =
  let child = node.field(key)
  if child == nil: return true
  if child.kind != tomlString:
    r.note(pdcWrongType,
      where & "'s '" & key & "' must be a quoted decimal, e.g. \"2\". The " &
      "TOML subset this reader accepts has strings, booleans, arrays and " &
      "tables and no bare numbers")
    return false
  if not boundedDecimal(child.strVal, dest, lo, hi):
    r.note(pdcBadNumber,
      where & "'s '" & key & "' is '" & child.strVal & "', which is not a " &
      "decimal between " & $lo & " and " & $hi)
    return false
  true

proc entriesOf(r: var FileReader; root: TomlNode; key, where: string;
               maxEntries: int; dest: var seq[TomlNode]): bool =
  ## `[[key]]` — an array of tables — read with its bound applied before
  ## anything in it is looked at.
  let child = root.field(key)
  if child == nil:
    dest = @[]
    return true
  if child.kind != tomlArray:
    r.note(pdcWrongType,
      where & "'s '" & key & "' must be written as [[" & key & "]] entries")
    return false
  if child.items.len > maxEntries:
    r.note(pdcTooManyEntries,
      where & " declares " & $child.items.len & " '" & key & "' entries; the " &
      "bound is " & $maxEntries)
    return false
  for item in child.items:
    if item.kind != tomlTable:
      r.note(pdcWrongType, "every '" & key & "' entry must be a table")
      return false
  dest = child.items
  true

# ---------------------------------------------------------------------------
# The three declarative files
# ---------------------------------------------------------------------------

proc readPoints(r: var FileReader; root: TomlNode;
                into: var seq[PointCollection]) =
  var entries: seq[TomlNode]
  if not r.entriesOf(root, "collection", "points.toml", MaxCollections,
                     entries):
    return
  var seen = initTable[string, bool]()
  for entry in entries:
    var c = PointCollection(origin: r.file.origin, scope: r.file.scope,
                            file: r.file.path)
    let where = "a collection"
    if not r.checkKeys(entry, tiCollection, where): continue
    if not r.stringField(entry, "name", where, MaxNameBytes, true, c.name):
      continue
    if c.name.strip().len == 0:
      r.note(pdcMissingField, "a collection's 'name' is blank")
      continue
    if seen.hasKey(c.name):
      # REFUSED RATHER THAN LAST-WINS. Either could be the one the author
      # meant, and a silently dropped half of a collection is exactly §4's
      # "a collection that silently loses half its points ... is worse than
      # one that says so", arriving one level up.
      r.note(pdcDuplicateName,
        "two collections are both named '" & c.name & "'. Rename one: with " &
        "two, enabling the collection could only ever enable one of them, " &
        "and nothing would say which")
      continue
    seen[c.name] = true
    if not r.boolField(entry, "enabled", "collection '" & c.name & "'",
                       c.enabledByDefault):
      continue

    var pointEntries: seq[TomlNode]
    if not r.entriesOf(entry, "point", "collection '" & c.name & "'",
                       MaxPointsPerCollection, pointEntries):
      continue
    var pointProblem = false
    for pe in pointEntries:
      let pwhere = "a point in collection '" & c.name & "'"
      if not r.checkKeys(pe, tiCollectionPoint, pwhere):
        pointProblem = true
        continue
      var p = PointDefinition()
      var kindName = ""
      if not r.stringField(pe, "kind", pwhere, MaxNameBytes, true, kindName):
        pointProblem = true
        continue
      if not pointKindByName(kindName, p.kind):
        r.note(pdcUnknownPointKind,
          pwhere & " is a '" & kindName & "'; §4's point kinds are " &
          knownPointKinds().join(" and "))
        pointProblem = true
        continue
      var rawPath = ""
      if not r.stringField(pe, "path", pwhere, MaxContainedPathBytes, true,
                           rawPath):
        pointProblem = true
        continue
      let pp = pathProblem(rawPath)
      if pp != ppOk:
        # §2.2's containment, and the ONE predicate that decides it.
        r.note(pdcPathEscapesProject, pwhere & ": " & describe(pp, rawPath))
        pointProblem = true
        continue
      p.path = joinContained(r.file.scope, rawPath)
      if not r.stringField(pe, "anchor", pwhere, MaxAnchorBytes, false,
                           p.anchor.text):
        pointProblem = true
        continue
      p.anchor.occurrence = MinOccurrence
      if not r.intField(pe, "occurrence", pwhere, MinOccurrence, MaxOccurrence,
                        p.anchor.occurrence):
        pointProblem = true
        continue
      if not r.intField(pe, "offset", pwhere, 0, MaxOffset, p.anchor.offset):
        pointProblem = true
        continue
      if not r.intField(pe, "line", pwhere, 0, MaxLineHint, p.anchor.line):
        pointProblem = true
        continue
      if p.anchor.text.strip().len == 0:
        # §4: "a stable location: path plus a resilient anchor, NOT A BARE
        # LINE NUMBER, so an edit above the point does not silently move it."
        # The refusal is here rather than in a review comment, and it names
        # the line the author wrote so they can see what to anchor on.
        r.note(pdcAnchorMissing,
          pwhere & " has no 'anchor'" &
          (if p.anchor.line > 0:
             ", only line \"" & $p.anchor.line & "\". A bare line number " &
             "moves the moment anything is inserted above it, and the point " &
             "then silently marks a different statement"
           else: ""))
        pointProblem = true
        continue
      if not r.stringField(pe, "expression", pwhere, MaxExpressionBytes, false,
                           p.expression):
        pointProblem = true
        continue
      if not r.stringField(pe, "label", pwhere, MaxNameBytes, false, p.label):
        pointProblem = true
        continue
      c.points.add p
    if pointProblem: continue
    if c.points.len == 0:
      r.note(pdcEmptyCollection,
        "collection '" & c.name & "' declares no points. A name a user can " &
        "enable that does nothing is a blank surface with a label")
      continue
    into.add c

proc readVisualisers(r: var FileReader; root: TomlNode;
                     into: var seq[VisualiserRule]) =
  var entries: seq[TomlNode]
  if not r.entriesOf(root, "visualiser", "visualisers.toml",
                     MaxVisualiserRules, entries):
    return
  var order = 0
  for entry in entries:
    var v = VisualiserRule(origin: r.file.origin, scope: r.file.scope,
                           file: r.file.path, order: order,
                           present: pkText)
    inc order
    let where = "a visualiser"
    if not r.checkKeys(entry, tiVisualiser, where): continue
    if not r.stringField(entry, "match", where, MaxTypeMatchBytes, true,
                         v.match):
      continue
    if v.match.len == 0:
      r.note(pdcMissingField, "a visualiser's 'match' is empty")
      continue
    var matchKindName = $mkTypeName
    if not r.stringField(entry, "matchKind", where, MaxNameBytes, false,
                         matchKindName):
      continue
    if matchKindName.len == 0: matchKindName = $mkTypeName
    if not matchKindByName(matchKindName, v.matchKind):
      r.note(pdcUnknownMatchKind,
        where & " matches by '" & matchKindName & "'. The match kinds are " &
        knownMatchKinds().join(", ") & " — all three total string " &
        "comparisons. There is deliberately no regular expression: a regex " &
        "over a cloned repository's text is unbounded work, and " &
        "§2.2 requires matching to terminate by construction")
      continue
    if not r.stringField(entry, "language", where, MaxNameBytes, false,
                         v.language):
      continue
    if not r.stringField(entry, "summary", where, MaxSummaryBytes, false,
                         v.summary):
      continue
    let tp = templateProblem(v.summary)
    if tp != tpOk:
      r.note(pdcBadTemplate,
        where & "'s 'summary' has " & describeTemplate(tp))
      continue

    var presentName = ""
    if not r.stringField(entry, "present", where, MaxNameBytes, false,
                         presentName):
      continue
    if presentName.len > 0 and not presentationByName(presentName, v.present):
      r.note(pdcUnknownPresentation,
        where & " presents as '" & presentName & "'. A visualiser is a " &
        "function from a value to a presentation, so the presentations it " &
        "may name are the ones a recorded value can inhabit: " &
        knownPresentationNames().join(", "))
      continue

    if not r.stringField(entry, "media", where, MaxNameBytes, false,
                         v.mediaType):
      continue
    if v.mediaType.len > 0 and v.mediaType notin DeclarativeMediaTypes:
      r.note(pdcUnknownMediaType,
        where & " declares media type '" & v.mediaType & "'. §5.2's " &
        "declarable media are " & DeclarativeMediaTypes.join(", ") &
        ". A type nothing renders is a silently blank value")
      continue
    if not r.stringField(entry, "mediaFrom", where, MaxFieldNameBytes, false,
                         v.mediaFrom):
      continue
    if v.mediaType.len > 0 and v.mediaFrom.len == 0:
      r.note(pdcMissingField,
        where & " declares media type '" & v.mediaType & "' but no " &
        "'mediaFrom'. §5.2's whole mechanism is the project SAYING WHICH " &
        "BYTES they are; a media type with no field names none")
      continue
    if v.mediaFrom.len > 0 and v.mediaType.len == 0:
      r.note(pdcMissingField,
        where & " names 'mediaFrom' = '" & v.mediaFrom & "' with no 'media'. " &
        "A debugger cannot infer what bytes are, which is the knowledge §5.2 " &
        "exists to capture")
      continue

    let hideNode = entry.field("hide")
    if hideNode != nil:
      if hideNode.kind != tomlArray:
        r.note(pdcWrongType, where & "'s 'hide' must be an array of field names")
        continue
      if hideNode.items.len > MaxHiddenFields:
        r.note(pdcTooManyEntries,
          where & " hides " & $hideNode.items.len & " fields; the bound is " &
          $MaxHiddenFields)
        continue
      var hideProblem = false
      for item in hideNode.items:
        if item.kind != tomlString:
          r.note(pdcWrongType, where & "'s 'hide' entries must be strings")
          hideProblem = true
          break
        if item.strVal.len == 0 or item.strVal.len > MaxFieldNameBytes:
          r.note(pdcValueTooLong,
            where & " hides a field name that is empty or longer than " &
            $MaxFieldNameBytes & " bytes")
          hideProblem = true
          break
        v.hide.add item.strVal
      if hideProblem: continue

    into.add v

proc readScratchpad(r: var FileReader; root: TomlNode;
                    into: var seq[DiffSelection]) =
  var entries: seq[TomlNode]
  if not r.entriesOf(root, "diff", "scratchpad.toml", MaxDiffSelections,
                     entries):
    return
  var order = 0
  for entry in entries:
    var d = DiffSelection(origin: r.file.origin, scope: r.file.scope,
                          file: r.file.path, order: order,
                          algorithm: daStructural)
    inc order
    let where = "a scratchpad diff"
    if not r.checkKeys(entry, tiDiff, where): continue
    if not r.stringField(entry, "match", where, MaxTypeMatchBytes, true,
                         d.match):
      continue
    if d.match.len == 0:
      r.note(pdcMissingField, "a scratchpad diff's 'match' is empty")
      continue
    var matchKindName = $mkTypeName
    if not r.stringField(entry, "matchKind", where, MaxNameBytes, false,
                         matchKindName):
      continue
    if matchKindName.len == 0: matchKindName = $mkTypeName
    if not matchKindByName(matchKindName, d.matchKind):
      r.note(pdcUnknownMatchKind,
        where & " matches by '" & matchKindName & "'; the match kinds are " &
        knownMatchKinds().join(", "))
      continue
    var algName = ""
    if not r.stringField(entry, "algorithm", where, MaxNameBytes, true,
                         algName):
      continue
    if not diffAlgorithmByName(algName, d.algorithm):
      # THE CLOSED SET IS THE DECLARATIVE/EXECUTABLE BOUNDARY, IN ONE MESSAGE.
      # §7's comparisons are "executable by nature"; what a declarative file
      # can do is SELECT one CodeTracer ships. An unknown name is therefore
      # not a missing file to go and find — there is no file — it is a name
      # outside a closed list.
      r.note(pdcUnknownDiffAlgorithm,
        where & " asks for '" & algName & "'. The algorithms CodeTracer " &
        "ships are " & knownDiffAlgorithms().join(", ") & ". A project " &
        "SELECTS one here; supplying a comparison of its own is " &
        "§7's executable tier, which is a separate file behind an explicit " &
        "per-repository trust grant")
      continue
    if not r.stringField(entry, "tolerance", where, MaxNumberBytes, false,
                         d.tolerance):
      continue
    if d.tolerance.len > 0 and not boundedTolerance(d.tolerance):
      r.note(pdcBadNumber,
        where & "'s 'tolerance' is '" & d.tolerance & "', which is not a " &
        "decimal such as \"1e-6\" or \"0.001\"")
      continue
    if d.algorithm == daNumericTolerance and d.tolerance.len == 0:
      r.note(pdcMissingField,
        where & " selects '" & $daNumericTolerance & "' with no 'tolerance'. " &
        "A tolerance of nothing is a structural diff with a different name")
      continue
    if d.algorithm != daNumericTolerance and d.tolerance.len > 0:
      r.note(pdcUnknownKey,
        where & " selects '" & $d.algorithm & "' and declares a 'tolerance', " &
        "which that algorithm does not read. A setting that does nothing " &
        "reads to its author as one that does")
      continue
    into.add d

# ---------------------------------------------------------------------------
# One file
# ---------------------------------------------------------------------------

proc parseDefinitionFile*(file: DefinitionFile;
                          into: var ProjectDefinitions):
    seq[ProjectDefinitionProblem] =
  ## Read ONE declarative definition file into `into`, and report everything
  ## that went wrong.
  ##
  ## A file that is refused as a whole contributes NOTHING to `into` — never a
  ## partial load. An entry that is refused contributes nothing while the rest
  ## of the file still does, which is the only partiality here and it is
  ## always accompanied by a problem naming the entry.
  var r = FileReader(file: file)

  if tierOf(file.kind) != dtDeclarative:
    # UNREACHABLE FROM `load`, which never hands an executable-tier file here,
    # and present anyway because the alternative to an explicit refusal is a
    # future caller discovering by experiment what this function does with
    # one. §2's rule is worth an `if` that should never fire.
    r.note(pdcSchemaKindMismatch,
      "'" & definitionFileName(file.kind) & "' is an executable-tier " &
      "definition and has no declarative reader")
    return r.problems

  # ---- bounds, before the parser is entered -------------------------------
  if file.text.len > MaxDefinitionBytes:
    r.note(pdcFileTooLarge,
      $file.text.len & " bytes; the bound is " & $MaxDefinitionBytes &
      ". The bound is checked before the file is tokenised, so an oversized " &
      "definition costs a length comparison rather than a parse")
    return r.problems
  var lines = 1
  for ch in file.text:
    if ch == '\n': inc lines
  if lines > MaxDefinitionLines:
    r.note(pdcTooManyLines,
      $lines & " lines; the bound is " & $MaxDefinitionLines)
    return r.problems

  # ---- syntax -------------------------------------------------------------
  var root: TomlNode
  try:
    root = parseTomlSubset(file.text)
  except TomlError as e:
    # The shared reader's own message names the line, INCLUDING the
    # array-nesting bound — which is where a nesting bomb lands, and why this
    # package does not need a nesting bound of its own.
    r.note(pdcMalformedToml, e.msg)
    return r.problems
  except CatchableError as e:
    r.note(pdcMalformedToml, e.msg)
    return r.problems
  if root == nil or root.kind != tomlTable:
    r.note(pdcMalformedToml, "the top level is not a table")
    return r.problems

  # ---- schema -------------------------------------------------------------
  # THE ROOT KEY CHECK RUNS BEFORE THE SCHEMA CHECK and its verdict is not
  # acted on until after it, deliberately: a file from a FUTURE version will
  # carry top-level tables this build does not know, and the right thing to
  # tell its reader is "this build is too old", not "unknown table". So the
  # unknown-key problem is recorded, the schema decides, and a file whose
  # schema is not ours returns on the schema's message with the key problem
  # beside it rather than instead of it.
  let rootKeysOk = r.checkKeys(root, rootTableFor(file.kind),
                               "the top level of '" &
                               definitionFileName(file.kind) & "'")
  let schemaNode = root.field("schema")
  if schemaNode == nil or schemaNode.kind != tomlString or
     schemaNode.strVal.len == 0:
    r.note(pdcMissingSchema,
      "no 'schema' key. Every definition file declares the format it is in, " &
      "so a file from a newer CodeTracer is reported rather than read with " &
      "this build's assumptions. This build reads '" & schemaOf(file.kind) &
      "' here")
    return r.problems
  let schema = schemaNode.strVal
  if schema != schemaOf(file.kind):
    var otherKind: DefinitionFileKind
    if kindForSchema(schema, otherKind):
      # A KNOWN schema in the WRONG file. Refused rather than followed: §6
      # makes the trust gate apply per FILE, and a file that can redeclare
      # which concern it carries is a file no per-file gate can be applied to.
      r.note(pdcSchemaKindMismatch,
        "'" & definitionFileName(file.kind) & "' declares schema '" & schema &
        "', which belongs to '" & definitionFileName(otherKind) & "'. The " &
        "trust tier is a property of the FILE (§6), so a file does not get " &
        "to say which concern it carries")
    else:
      # §6's rule, and `LayoutDecodeError`'s: reported, never partially
      # honoured. The user's next step is in the message, and it is not "fix
      # your file" — it is "this project needs a newer CodeTracer".
      r.note(pdcUnknownSchemaVersion,
        "'" & definitionFileName(file.kind) & "' declares schema '" & schema &
        "', which this build does not implement. It reads '" &
        schemaOf(file.kind) & "'; the schemas it knows at all are " &
        knownSchemas().join(", ") & ". The file was NOT partially honoured: " &
        "reading a newer format with an older reader silently drops whatever " &
        "is new, and a definition that half-applied would be worse than one " &
        "that did not apply")
    return r.problems

  if not rootKeysOk: return r.problems

  # ---- the file's own concern ---------------------------------------------
  case file.kind
  of dfkPoints: r.readPoints(root, into.collections)
  of dfkVisualisers: r.readVisualisers(root, into.visualisers)
  of dfkScratchpad: r.readScratchpad(root, into.diffs)
  of dfkVisualiserCode, dfkDiffCode: discard  # refused above

  r.problems
