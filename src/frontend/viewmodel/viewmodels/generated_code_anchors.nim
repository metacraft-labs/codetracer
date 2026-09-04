## viewmodels/generated_code_anchors.nim
##
## The anchoring model for the Generated Code Listing
## (`GUI/Debugging-Features/Generated-Code-Listing.md`), Noir Studio NS4.
##
## ## What this module is, and what it deliberately is not
##
## It is the **model**: the fidelity ladder, the anchor record, the
## source<->generated synchronisation decision, and the count-provenance
## vocabulary. It is a pure module — no signals, no store, no host — so it
## compiles and runs in BOTH `vm-unit` and `vm-unit-js`. That is not
## incidental tidiness: `CONTRIBUTING.md`'s "Code compiled for both backends"
## entry exists because a guard that was correct under `nim c` crashed the
## process under `nim js`, and the renderer ships on `nim js`.
##
## It is NOT the wiring. `low_level_code_vm.nim` currently has no anchor,
## sync or unmapped-region machinery at all, and connecting this model to it
## — and to a Noir producer that fills it — are separate units. Splitting the
## model out first is what makes the rules below assertable without Monaco,
## without a recording and without a toolchain.
##
## ## The one rule the whole module exists to enforce
##
## §4: *"a confidently wrong mapping in this pane sends someone optimising
## the wrong loop."* Every type here is shaped so that the confident-but-wrong
## answer is either impossible to express or is caught by `validate`.
##
## Two of those claims are **structurally impossible** rather than merely
## doubtful, and those are the ones `validate` rejects outright:
##
## - **`mfExact` over two or more sources.** "Exact" means debug info maps
##   this instruction to *this* source position, singular. A producer
##   offering two positions has not got an exact mapping; it has a merge and
##   has mislabelled it. Presented as exact, the pane would pick one and
##   claim it.
## - **`mfMerged` over fewer than two sources.** "Merged" means one
##   instruction sequence serves *several* source locations after inlining or
##   CSE — §4's presentation rule is "all contributing sources shown, none
##   claimed as *the* source". With one source there is nothing to merge, and
##   the label suppresses a claim the producer could have made.
##
## Neither needs a recording, a compiler or a judgement call to detect. The
## claim contradicts itself, so it can be caught rather than doubted.
##
## ## The ladder is ordered by claim strength, not by quality
##
## `MappingFidelity`'s ordinals ascend by *how specific a source-position
## claim the rung makes* — nothing at all, then "positively no user source",
## then a set, then a region, then a point. That ordering is what makes
## `claimCeiling` meaningful: an anchor may sit at or below what the artefact
## supports and never above it.
##
## This is the rule the Aztec campaign held to when it declared rung 3 and
## refused to assert resolved source positions, and it is why **this module
## hard-codes no rung for any language, Noir included**. Noir has real source
## and may well earn a high rung — but the producer must derive its
## `ArtefactSupport` from the container it actually opened, not from what the
## language could in principle provide. A `noirArtefactSupport` constant here
## would be exactly the confident-but-sometimes-wrong shape the pane is
## supposed to be immune to.
##
## ## Anchors, never interpolation
##
## §3.1: the panes are not the same length and their order is not the same,
## so scrolling "aligns the nearest anchors rather than interpolating between
## them". `syncFromGenerated` / `syncFromSource` therefore return an *anchor*,
## never a computed position:
##
## - Every row inside one anchor yields the **identical** counterpart. A row
##   halfway down a five-row anchor does not get a source line offset
##   proportionally into the region — there is no evidence for that line, and
##   producing it is the plausible-and-wrong failure §3.1 names.
## - A position in a **gap** between anchors is not attributed to the nearest
##   one. §3.1 sends the no-anchor case to §4, and §4 says the panes stop
##   pretending. So a gap suspends synchronisation with a reason.
## - `mfUnmapped` and `mfCompilerGenerated` suspend as well: the first has no
##   information, and the second has the positive information that there is
##   no user source, which §4 says must "never be attributed to a nearby
##   line".
##
## ## Counts carry where they came from
##
## §2's whole argument is executed counts rather than static ones, and §7
## leaves open that a source-level recording (Noir's, Python's) can only
## reach instruction counts by inverting the producer's own anchors — which
## "may be approximate. Approximate counts are useful and must be *labelled*
## approximate." So a count is never a bare integer here; it is a value plus
## its provenance, and `countLabel` renders the two differently.

import std/strutils

type
  MappingFidelity* = enum
    ## `Generated-Code-Listing.md` §4's ladder, five rungs, ordered by the
    ## strength of the source-position claim each one makes. See the module
    ## header: the ordering exists so `claimCeiling` can be a `<=`.
    mfUnmapped = 0
      ## Debug info is absent or was discarded. Claims nothing, and
      ## suspends synchronisation rather than guessing.
    mfCompilerGenerated = 1
      ## Prologue, bounds check, padding — no user source at all. This is a
      ## positive claim ("there is no source here"), not an absence of one,
      ## which is why it outranks `mfUnmapped` and why it needs its own
      ## evidence in `ArtefactSupport`.
    mfMerged = 2
      ## One instruction sequence serves several source locations after
      ## inlining or CSE. All contributing sources are shown; none is
      ## claimed as *the* source.
    mfCoarse = 3
      ## Mapped to a region — a statement, a block — but not to a position.
      ## The region highlights; no single-line claim is made.
    mfExact = 4
      ## Debug info maps this instruction to this source position.

  CountProvenance* = enum
    ## Where an executed count came from. §7's open question, answered by
    ## refusing to let the two cases share a representation.
    cpNone = 0
      ## No count is available. The pane shows no count column for this
      ## anchor rather than showing a zero, which would read as "never ran".
    cpExecuted = 1
      ## Counted directly from the recording, per generated instruction.
      ## §2's headline case.
    cpApproximate = 2
      ## Derived by inverting the producer's anchors from a source-level
      ## recording. Useful, and §7 requires it be labelled as approximate.

  SourceRegion* = object
    ## A contributing source span. `startLine == endLine` is a single line;
    ## it is still a *region*, because `mfExact` is what makes a positional
    ## claim, not the shape of this record.
    path*: string
    startLine*: int
    endLine*: int

  ExecutedCount* = object
    value*: int
    provenance*: CountProvenance

  MappingAnchor* = object
    ## One mapping point. `generatedFirst` / `generatedLast` are inclusive
    ## row indices into the generated listing.
    generatedFirst*: int
    generatedLast*: int
    fidelity*: MappingFidelity
    sources*: seq[SourceRegion]
    count*: ExecutedCount

  ArtefactSupport* = object
    ## What the compiler artefact in hand actually carries. A producer fills
    ## this in from the container it opened. Nothing here is a property of a
    ## *language*; it is a property of one artefact.
    hasSourcePositions*: bool
      ## Per-instruction source position, resolved. Supports `mfExact`.
    hasSourceRegions*: bool
      ## Statement or block spans, without resolved positions. Supports
      ## `mfCoarse`.
    hasInliningRecords*: bool
      ## Enough to know an instruction serves several sources. Supports
      ## `mfMerged`.
    marksCompilerGenerated*: bool
      ## The artefact distinguishes synthetic instructions from user ones.
      ## Supports `mfCompilerGenerated` — which is off the ordinal ceiling
      ## axis, because it is a claim about the *absence* of user source and
      ## needs its own evidence.

  AnchorDefectKind* = enum
    adkExactOverManySources
      ## `mfExact` with a source count other than exactly one.
    adkMergedUnderTwoSources
      ## `mfMerged` with fewer than two sources.
    adkUnmappedClaimsSource
      ## `mfUnmapped` carrying a source. Unmapped claims nothing.
    adkCompilerGeneratedClaimsSource
      ## `mfCompilerGenerated` carrying a source. §4: never attributed to a
      ## nearby line.
    adkFidelityAboveArtefactCeiling
      ## A rung stronger than the artefact supports.
    adkCountWithoutProvenance
      ## A non-zero count whose provenance is `cpNone` — a number on screen
      ## that cannot say whether it was measured or inferred.
    adkEmptyGeneratedRange
      ## `generatedLast < generatedFirst`: an anchor covering no row, which
      ## would silently never match and turn every lookup into a gap.

  AnchorDefect* = object
    kind*: AnchorDefectKind
    anchorIndex*: int
    message*: string

  SyncOutcome* = enum
    soAligned
      ## The position sits inside an anchor that carries user source. The
      ## counterpart is that anchor, snapped.
    soSuspended
      ## No anchor, or an anchor that claims no user source. §4: the panes
      ## stop pretending to be synchronised and say so.
    soDisabled
      ## §3's toggle is off. Distinct from `soSuspended`, because "you turned
      ## it off" and "the mapping ran out here" are different things to show.

  SyncDecision* = object
    outcome*: SyncOutcome
    anchorIndex*: int
      ## `NoAnchor` unless `outcome == soAligned`.
    reason*: string
      ## Non-empty whenever the outcome is not `soAligned`. This is the
      ## "and say so" half of §4 — a suspension the user cannot see is
      ## indistinguishable from drift.

  SyncSettings* = object
    ## §3: "it is a toggle, defaulting to on, and unlocking is a deliberate
    ## act with a visible state."
    enabled*: bool

const
  NoAnchor* = -1

  DefaultSyncSettings* = SyncSettings(enabled: true)
    ## Defaults ON, per §3.

# ---------------------------------------------------------------------------
# Ladder
# ---------------------------------------------------------------------------

proc claimsUserSource*(f: MappingFidelity): bool =
  ## True for the rungs that attribute generated code to user source.
  ## `mfUnmapped` has no information; `mfCompilerGenerated` has the positive
  ## information that there is none.
  f in {mfMerged, mfCoarse, mfExact}

proc label*(f: MappingFidelity): string =
  ## The word §4's table uses, for the pane's fidelity badge.
  case f
  of mfUnmapped: "unmapped"
  of mfCompilerGenerated: "compiler-generated"
  of mfMerged: "merged"
  of mfCoarse: "coarse"
  of mfExact: "exact"

proc claimCeiling*(support: ArtefactSupport): MappingFidelity =
  ## The strongest source-attribution rung this artefact can support.
  ##
  ## `mfCompilerGenerated` is deliberately not reachable here: it is not a
  ## stronger version of `mfMerged`, it is a different claim, and it is
  ## gated on `marksCompilerGenerated` in `validate` instead.
  if support.hasSourcePositions: mfExact
  elif support.hasSourceRegions: mfCoarse
  elif support.hasInliningRecords: mfMerged
  else: mfUnmapped

# ---------------------------------------------------------------------------
# Counts
# ---------------------------------------------------------------------------

proc isApproximate*(c: ExecutedCount): bool =
  c.provenance == cpApproximate

proc countLabel*(c: ExecutedCount): string =
  ## §2's mock renders `×1024`. §7 requires an inverted count be *labelled*
  ## approximate, so it renders `≈×1024` — the two must not be confusable at
  ## a glance, because the whole commercial argument of the pane is that its
  ## numbers are facts about the run.
  case c.provenance
  of cpNone: ""
  of cpExecuted: "×" & $c.value
  of cpApproximate: "≈×" & $c.value

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

proc defect(kind: AnchorDefectKind; index: int; message: string): AnchorDefect =
  AnchorDefect(kind: kind, anchorIndex: index, message: message)

proc validate*(anchors: seq[MappingAnchor];
               support: ArtefactSupport): seq[AnchorDefect] =
  ## Reject the mappings that are wrong *by construction* — a producer bug
  ## that would otherwise reach the pane as a confident answer.
  ##
  ## Returns every defect rather than the first, so a producer's test sees
  ## its whole delta at once.
  result = @[]
  let ceiling = claimCeiling(support)
  for i, a in anchors:
    if a.generatedLast < a.generatedFirst:
      result.add defect(adkEmptyGeneratedRange, i,
        "anchor covers no generated row: last " & $a.generatedLast &
        " precedes first " & $a.generatedFirst)

    case a.fidelity
    of mfExact:
      if a.sources.len != 1:
        result.add defect(adkExactOverManySources, i,
          "exact mapping claims " & $a.sources.len &
          " sources; an exact mapping is to one source position. " &
          "Two or more contributing sources is " & label(mfMerged) & ".")
    of mfMerged:
      if a.sources.len < 2:
        result.add defect(adkMergedUnderTwoSources, i,
          "merged mapping carries " & $a.sources.len &
          " sources; a merge serves several source locations. " &
          "One source is " & label(mfExact) & " or " & label(mfCoarse) & ".")
    of mfUnmapped:
      if a.sources.len > 0:
        result.add defect(adkUnmappedClaimsSource, i,
          "unmapped mapping carries " & $a.sources.len &
          " sources; unmapped means the debug info is absent, so there is " &
          "nothing to attribute")
    of mfCompilerGenerated:
      if a.sources.len > 0:
        result.add defect(adkCompilerGeneratedClaimsSource, i,
          "compiler-generated mapping carries " & $a.sources.len &
          " sources; it must never be attributed to a nearby line")
    of mfCoarse:
      discard

    if a.fidelity == mfCompilerGenerated:
      if not support.marksCompilerGenerated:
        result.add defect(adkFidelityAboveArtefactCeiling, i,
          "artefact does not mark compiler-generated instructions, so " &
          label(mfCompilerGenerated) & " is not claimable from it")
    elif ord(a.fidelity) > ord(ceiling):
      result.add defect(adkFidelityAboveArtefactCeiling, i,
        "artefact supports at most " & label(ceiling) & "; anchor claims " &
        label(a.fidelity))

    if a.count.provenance == cpNone and a.count.value != 0:
      result.add defect(adkCountWithoutProvenance, i,
        "count " & $a.count.value & " has no provenance; a number in this " &
        "pane must say whether it was measured or inferred")

proc kinds*(defects: seq[AnchorDefect]): seq[AnchorDefectKind] =
  result = @[]
  for d in defects:
    result.add d.kind

proc describe*(defects: seq[AnchorDefect]): string =
  ## One line per defect, for a producer test's failure output.
  var parts: seq[string] = @[]
  for d in defects:
    parts.add "anchor " & $d.anchorIndex & ": " & $d.kind & ": " & d.message
  parts.join("\n")

# ---------------------------------------------------------------------------
# Synchronisation
# ---------------------------------------------------------------------------

proc covers(a: MappingAnchor; row: int): bool =
  a.generatedLast >= a.generatedFirst and
    row >= a.generatedFirst and row <= a.generatedLast

proc covers(r: SourceRegion; path: string; line: int): bool =
  r.path == path and r.endLine >= r.startLine and
    line >= r.startLine and line <= r.endLine

proc aligned(index: int): SyncDecision =
  SyncDecision(outcome: soAligned, anchorIndex: index, reason: "")

proc suspended(reason: string): SyncDecision =
  SyncDecision(outcome: soSuspended, anchorIndex: NoAnchor, reason: reason)

proc disabled(): SyncDecision =
  SyncDecision(outcome: soDisabled, anchorIndex: NoAnchor,
    reason: "source syncing is off")

proc decideFor(anchors: seq[MappingAnchor]; index: int): SyncDecision =
  ## Shared tail of both directions: an anchor was found, so decide whether
  ## it can be aligned to.
  let a = anchors[index]
  if not claimsUserSource(a.fidelity):
    return suspended("no source mapping here (" & label(a.fidelity) &
      ") — synchronisation is suspended rather than interpolated to a " &
      "nearby anchor")
  if a.sources.len == 0:
    return suspended("the mapping here claims " & label(a.fidelity) &
      " and names no source — synchronisation is suspended rather than " &
      "interpolated to a nearby anchor")
  aligned(index)

proc anchorIndexAtRow*(anchors: seq[MappingAnchor]; row: int): int =
  ## The anchor covering a generated row, or `NoAnchor`.
  ##
  ## Separate from `syncFromGenerated` on purpose: that answers "what should
  ## the other pane do", which depends on the toggle and on whether the rung
  ## claims user source. This answers "which anchor is this row in", which is
  ## what a per-row badge or count needs and which is true regardless of
  ## whether synchronisation is on. Reusing the sync decision for rendering
  ## would blank every row's fidelity the moment a user turned the toggle off.
  for i, a in anchors:
    if a.covers(row):
      return i
  NoAnchor

proc syncFromGenerated*(anchors: seq[MappingAnchor]; row: int;
                        settings: SyncSettings = DefaultSyncSettings):
                        SyncDecision =
  ## Generated row -> source. Returns an ANCHOR, never a computed line: every
  ## row inside one anchor gets the same answer, and a row in a gap gets no
  ## answer at all. See the module header.
  if not settings.enabled:
    return disabled()
  for i, a in anchors:
    if a.covers(row):
      return decideFor(anchors, i)
  suspended("generated row " & $row &
    " has no source mapped to it — synchronisation is suspended here " &
    "rather than interpolated to the nearest anchor")

proc syncFromSource*(anchors: seq[MappingAnchor]; path: string; line: int;
                     settings: SyncSettings = DefaultSyncSettings):
                     SyncDecision =
  ## Source line -> generated. The same rule in the other direction, which
  ## §3 requires: a source line with no anchor over it suspends rather than
  ## scrolling the listing somewhere plausible.
  if not settings.enabled:
    return disabled()
  for i, a in anchors:
    if not claimsUserSource(a.fidelity):
      continue
    for r in a.sources:
      if r.covers(path, line):
        return decideFor(anchors, i)
  suspended(path & ":" & $line &
    " has no anchor over it, so no generated code is mapped to it — " &
    "synchronisation is suspended here rather than interpolated to the " &
    "nearest anchor")

proc anchorsFromSource*(anchors: seq[MappingAnchor]; path: string;
                        line: int): seq[int] =
  ## EVERY anchor a source position produced, in row order — not the first.
  ##
  ## `syncFromSource` above answers "where should the follower go", and to do
  ## that it has to pick one. This answers "how many places did this line
  ## become", and the two are different questions: one source position is
  ## compiled into as many places as the compiler chose — a generic
  ## monomorphised, a template expanded at several call sites, a function
  ## inlined at several, an unrolled loop body — and §4.2 makes that
  ## multiplicity first-class rather than resolving it by picking one.
  ##
  ## WHY THIS IS NOT A REFINEMENT OF `syncFromSource`. §13.1's second
  ## requirement is that a producer supply "a source→generated query that
  ## returns an ordered sequence, not a single result", because *a query that
  ## returns the first is not a narrower version of the right answer — it is an
  ## answer that cannot be corrected by the caller, because the caller cannot
  ## see what was dropped*. A surface built only on `syncFromSource` shows one
  ## range and gives the reader no way to tell that three existed. That is the
  ## silent-drop failure §4.2 exists to prevent, and it is invisible by
  ## construction, which is why the count has to come from somewhere else.
  ##
  ## Anchors that claim no user source are excluded, for the same reason
  ## `syncFromSource` skips them: an unmapped anchor names no source and so
  ## cannot be one of the places THIS line became.
  ##
  ## The order is the anchor order the producer emitted, which for a listing is
  ## generated-row order. GCL-D26 requires a *descriptor* order once
  ## descriptors exist; until a producer supplies them this is the honest
  ## available order and callers must not persist an index into it.
  for i, a in anchors:
    if not claimsUserSource(a.fidelity):
      continue
    for r in a.sources:
      if r.covers(path, line):
        result.add i
        break

proc counterpartSources*(anchors: seq[MappingAnchor];
                         decision: SyncDecision): seq[SourceRegion] =
  ## The sources to highlight for an aligned decision. §4: for a merge, ALL
  ## contributing sources, none claimed as *the* source — so this returns a
  ## seq for every rung, and a caller that wants "the" source has to notice
  ## it may be getting more than one.
  if decision.outcome != soAligned:
    return @[]
  anchors[decision.anchorIndex].sources

proc counterpartRows*(anchors: seq[MappingAnchor];
                      decision: SyncDecision): (int, int) =
  ## The inclusive generated row range to reveal for an aligned decision.
  ## `(NoAnchor, NoAnchor)` when there is nothing to align to.
  if decision.outcome != soAligned:
    return (NoAnchor, NoAnchor)
  let a = anchors[decision.anchorIndex]
  (a.generatedFirst, a.generatedLast)
