## common/value_comparison.nim — what the scratchpad's "is this the same value?"
## asks, and which comparison answers it.
##
## Project-Definitions §7: "The scratchpad compares values. A project may know a
## better comparison than a structural diff: two matrices differ by tolerance,
## two timestamps by skew, two graphs by isomorphism rather than by node order."
##
## A project says which comparison applies to a type in two ways, and this module
## is where both meet a pair of recorded values:
##
##   * it SELECTS one CodeTracer ships, in `.codetracer/scratchpad.toml`
##     (`DiffSelection`: `structural`, `numeric-tolerance` with its `tolerance`,
##     `unordered-set`, `text-lines`) — data, read by `compareValues` below;
##   * it SUPPLIES one, in `.codetracer/diff.wasm`, behind the per-repository
##     trust grant — code, run by `project_executables.diffWith`, which this
##     module calls through `compareWithDefinition`.
##
## ## THE TWO PACKAGES STILL DO NOT SEE EACH OTHER
##
## `common/project_definitions/` reads declarations and knows nothing about
## values; `common/value_presentation/` renders values and knows nothing about
## declarations. `value_visualisers.nim` is the one crossing for presentation;
## this is the one crossing for comparison, and it is the same shape: it takes a
## declaration and a value and hands back an answer, and it performs no I/O.
##
## ## TOTAL AND BOUNDED
##
## §7's extra requirement — "a diff algorithm must be total and bounded" — holds
## for the algorithms CodeTracer ships as well as for a project's. Every walk
## below is charged against `MaxComparisonWork` nodes; a pair too large to
## compare within it is answered by the canonical renderings of the two values
## (`executableInputOf`, the same bounded rendering an executable comparison is
## handed), and the answer says so.

import std/[algorithm, strutils]

import ./executable_value_abi
import ./project_definitions
import ./project_executables
import ./project_trust
import ./value_presentation

type
  ComparisonVerdict* = enum
    cvEqual = "equal"
    cvDifferent = "different"

  Comparison* = object
    verdict*: ComparisonVerdict
    algorithm*: string
      ## Which comparison answered, in the words a reader is shown:
      ## `structural`, `numeric-tolerance 0.01`, `unordered-set`, `text-lines`,
      ## or `project code (.codetracer/diff.wasm)`.
    selectedBy*: string
      ## `<file>#<order>` of the declaration that chose it, or "" when nothing
      ## did and the structural comparison is the default.
    note*: string
      ## Why the answer is not the one the project asked for, when it is not:
      ## a definition that trapped, ran out of work or was revoked, and the
      ## comparison that answered instead. "" otherwise.

const
  MaxComparisonWork* = 100_000
    ## Nodes one comparison may visit across BOTH values. Ten times the largest
    ## rendering ever measured in this repository (a 600-entry mapping) and far
    ## below anything that would stall a pane.

func diffMatches(d: DiffSelection; v: PValue): bool =
  if v.isNil: return false
  if d.matchKind == mkShape: shapeMatches(d.match, v)
  else: typeMatches(d.matchKind, d.match, "", v.typeName, "")

func selectDiff*(loaded: LoadedProjectDefinitions; v: PValue;
                 found: var DiffSelection): bool =
  ## The declaration that governs values of `typeName`, if any.
  ##
  ## THE USER'S OWN SELECTION FIRST, then the project's — the order
  ## `value_visualisers` gives the two origins, for its reason (a user's own
  ## definition is a decision about their own screen). Within each, the order
  ## `load.rankDiffs` already put them in: the nearer scope, then the longer
  ## match, then declaration order.
  ## A selection matches by the value's type name or, with
  ## `matchKind = "shape"`, by its members (§5.3).
  for d in loaded.user.diffs:
    if d.diffMatches(v):
      found = d
      return true
  for d in loaded.project.diffs:
    if d.diffMatches(v):
      found = d
      return true
  false

func parseTolerance*(s: string): float =
  ## The selection's `tolerance`. PLAT-11's parser has already admitted it
  ## through `parse.boundedTolerance`, so the closed grammar holds; a value that
  ## still does not parse compares with a tolerance of zero, which is the
  ## structural comparison and never a looser one.
  try:
    result = parseFloat(s)
  except ValueError:
    result = 0.0
  if result < 0: result = 0.0

type
  Walk = object
    work: int
    exhausted: bool

func numberOf(v: PValue; dest: var float): bool =
  if v.isNil or v.kind notin {pvkInt, pvkFloat}: return false
  try:
    dest = parseFloat(v.text.strip())
    true
  except ValueError:
    false

func sameScalar(a, b: PValue): bool =
  a.kind == b.kind and a.typeName == b.typeName and a.text == b.text and
    a.enumName == b.enumName and a.variantName == b.variantName and
    a.mediaType == b.mediaType and a.mediaBytes == b.mediaBytes

func equalWalk(a, b: PValue; tolerance: float; useTolerance: bool;
               depth: int; w: var Walk): bool =
  ## Structural equality, with numeric leaves compared within `tolerance` when
  ## `useTolerance` is set. Charged one unit per node pair.
  inc w.work
  if w.work > MaxComparisonWork:
    w.exhausted = true
    return false
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if depth > 32:
    w.exhausted = true
    return false
  if useTolerance:
    var x, y: float
    if numberOf(a, x) and numberOf(b, y):
      return abs(x - y) <= tolerance
  if not sameScalar(a, b): return false
  if a.members.len != b.members.len or a.entries.len != b.entries.len:
    return false
  for i in 0 ..< a.members.len:
    if a.members[i].label != b.members[i].label: return false
    if not equalWalk(a.members[i].value, b.members[i].value, tolerance,
                     useTolerance, depth + 1, w):
      return false
  for i in 0 ..< a.entries.len:
    if not equalWalk(a.entries[i].key, b.entries[i].key, tolerance,
                     useTolerance, depth + 1, w):
      return false
    if not equalWalk(a.entries[i].val, b.entries[i].val, tolerance,
                     useTolerance, depth + 1, w):
      return false
  if (a.target.isNil) != (b.target.isNil): return false
  if not a.target.isNil:
    return equalWalk(a.target, b.target, tolerance, useTolerance, depth + 1, w)
  true

func canonical(v: PValue): string =
  if v.isNil: "" else: executableInputOf(v)

func memberSet(v: PValue): seq[string] =
  for m in v.members:
    result.add canonical(m.value)
  result.sort()

func linesOf(s: string): seq[string] =
  for l in s.replace("\r\n", "\n").split('\n'):
    result.add l.strip(leading = false)
  while result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

func verdictOf(equal: bool): ComparisonVerdict =
  if equal: cvEqual else: cvDifferent

func structuralOf(a, b: PValue; c: var Comparison) =
  var w = Walk()
  let eq = equalWalk(a, b, 0.0, false, 0, w)
  if w.exhausted:
    c.verdict = verdictOf(canonical(a) == canonical(b))
    c.note = "the two values are larger than one comparison may walk (" &
      $MaxComparisonWork & " nodes); their renderings were compared instead"
  else:
    c.verdict = verdictOf(eq)

func compareValues*(a, b: PValue; selection: DiffSelection;
                    selected: bool): Comparison =
  ## Compare two recorded values the way `selection` says, or structurally
  ## when nothing was `selected`.
  ##
  ## TOTAL: every algorithm has an answer for every pair, and a pair the
  ## algorithm does not apply to (an unordered-set selection over two scalars,
  ## a text-lines selection over two records) is compared structurally, with a
  ## note saying so rather than a refusal.
  result.algorithm = $daStructural
  if not selected:
    structuralOf(a, b, result)
    return
  result.selectedBy = selection.file & "#" & $selection.order
  case selection.algorithm
  of daStructural:
    structuralOf(a, b, result)
  of daNumericTolerance:
    let tol = parseTolerance(selection.tolerance)
    result.algorithm = $daNumericTolerance & " " & selection.tolerance
    var w = Walk()
    let eq = equalWalk(a, b, tol, true, 0, w)
    if w.exhausted:
      result.verdict = verdictOf(canonical(a) == canonical(b))
      result.note = "the two values are larger than one comparison may " &
        "walk (" & $MaxComparisonWork & " nodes); their renderings were " &
        "compared exactly instead"
    else:
      result.verdict = verdictOf(eq)
  of daUnorderedSet:
    result.algorithm = $daUnorderedSet
    if a.isNil or b.isNil or a.kind != pvkSequence or b.kind != pvkSequence:
      structuralOf(a, b, result)
      result.note = "'" & $daUnorderedSet & "' compares sequences; these " &
        "values are not both sequences, so they were compared structurally"
    else:
      result.verdict = verdictOf(a.typeName == b.typeName and
                                 memberSet(a) == memberSet(b))
  of daTextLines:
    result.algorithm = $daTextLines
    if a.isNil or b.isNil or a.kind notin {pvkString, pvkCString} or
       b.kind notin {pvkString, pvkCString}:
      structuralOf(a, b, result)
      result.note = "'" & $daTextLines & "' compares text; these values are " &
        "not both strings, so they were compared structurally"
    else:
      result.verdict = verdictOf(linesOf(a.text) == linesOf(b.text))

func compareWithDefinition*(d: ExecutableDefinition; trust: ProjectTrustLedger;
                            a, b: PValue): Comparison =
  ## §7's executable tier over two recorded values: hand the project's module
  ## the two values' canonical renderings and let it decide.
  ##
  ## THE FALLBACK IS `diffWith`'s OWN — the bounded run, the offender named,
  ## the structural verdict over the same two inputs — and the note carries
  ## every problem it reported, so a comparison that trapped says so in the
  ## pane that shows the answer.
  # ABI version 2 when the module speaks it: both values as trees.
  let (va, vb) =
    if d.takesStructuredValues: (encodeStructuredValue(a), encodeStructuredValue(b))
    else: ("", "")
  let answer = d.diffWith(trust, canonical(a), canonical(b), valueA = va,
                          valueB = vb)
  result.verdict =
    if answer.verdict == dvEqual: cvEqual else: cvDifferent
  if answer.fromDefinition:
    result.algorithm = "project code (" & d.file & ")"
    result.selectedBy = d.file
  else:
    result.algorithm = $daStructural
    var why: seq[string] = @[]
    for p in answer.problems: why.add render(p)
    result.note = "the project's comparison " & answer.offender &
      " did not answer, so the structural comparison did" &
      (if why.len > 0: ": " & why.join("; ") else: "")

func describe*(c: Comparison): string =
  ## One line for the pane: the verdict, the comparison that reached it, and
  ## the fallback when there was one.
  result = (if c.verdict == cvEqual: "= " else: "≠ ") & $c.verdict & " by " &
    c.algorithm
  if c.selectedBy.len > 0: result.add " (" & c.selectedBy & ")"
  if c.note.len > 0: result.add " — " & c.note
