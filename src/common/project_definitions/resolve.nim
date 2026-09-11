## project_definitions/resolve.nim — PLAT-11. Where a declared point actually
## is, in a file that has been edited since somebody wrote the definition.
##
## Project-Definitions.md §4:
##
##   "A collection is a **named set of point definitions**, each identified by
##    a stable location: path plus a resilient anchor, not a bare line number,
##    so an edit above the point does not silently move it."
##
##   "**A point whose location no longer resolves is reported, not dropped.**
##    A collection that silently loses half its points as a file evolves is
##    worse than one that says so."
##
## ## THE OUTPUT IS ONE ENTRY PER DECLARED POINT, ALWAYS
##
## `resolveCollection` returns a `seq[PointResolution]` whose length is the
## collection's point count, unconditionally. There is no path through this
## module that drops a point: a point whose anchor is gone comes back as
## `prUnresolved` with the anchor text it was looking for, and a consumer that
## renders the list renders a row for it.
##
## That is the shape the milestone's third integration test asks for — "a
## collection re-resolved against an edited file reports per point: resolved,
## moved, or unresolvable. None is silently dropped" — and it is also why the
## outcome is an ENUM rather than an `Option[int]`: `none` collapses "the
## anchor is gone" and "the file is gone" into one answer, and those have
## different remedies.
##
## ## NO I/O HERE EITHER
##
## `resolveCollection` is given the file's LINES. It does not read the file,
## does not know whether the file exists, and cannot be made to look at a
## different one. The caller that has the checkout does the reading; this
## decides what the text means.
##
## THE ABSENT FILE IS ITS OWN OUTCOME (`prFileAbsent`) rather than an empty
## line list producing `prUnresolved`, because "the file you named is not in
## this checkout" is a different message from "the code you anchored to has
## been rewritten", and a user shown the second when the first is true will
## go looking in the wrong place.

import std/strutils

import ./model

type
  PointOutcome* = enum
    ## §4's three, plus the one the spec's sentence implies.
    prResolved
      ## The anchor was found and the point is where the definition said it
      ## was — `anchor.line` agreed, or the definition recorded no line hint.
    prMoved
      ## The anchor was found at a DIFFERENT line from the recorded hint. The
      ## point is usable; the fact that it moved is worth surfacing, because a
      ## collection whose every point has moved is usually a collection
      ## pointing at a file that was restructured.
    prUnresolved
      ## The anchor text does not occur in the file, or not that many times.
      ## Reported, never dropped.
    prFileAbsent
      ## The file the point names is not in this checkout.

  PointResolution* = object
    point*: PointDefinition
    outcome*: PointOutcome
    line*: int
      ## 1-based, where the point resolved to. 0 when it did not.
    detail*: string
      ## What a reader needs in order to fix it. Never empty for an outcome
      ## other than `prResolved`.

  CollectionResolution* = object
    collection*: PointCollection
    points*: seq[PointResolution]
      ## EXACTLY as many entries as `collection.points`. Asserted by the
      ## suite over a file edited in four different ways.

func isUsable*(o: PointOutcome): bool =
  ## Whether the point has a line a pane can jump to. `prMoved` is usable —
  ## that is the difference between "it moved" and "it is gone", and
  ## collapsing them is what §4 forbids.
  o in {prResolved, prMoved}

func describe*(o: PointOutcome): string =
  case o
  of prResolved: "resolved"
  of prMoved: "moved"
  of prUnresolved: "unresolvable"
  of prFileAbsent: "file absent"

func getSuffix(n: int): string =
  ## `1st`, `2nd`, `3rd`, `4th`. Small, and here rather than inline so the
  ## ordinal in a diagnostic reads like English in the one place ordinals are
  ## produced.
  if n mod 100 in 11 .. 13: "th"
  else:
    case n mod 10
    of 1: "st"
    of 2: "nd"
    of 3: "rd"
    else: "th"

func anchorLine(lines: openArray[string]; anchor: PointAnchor;
                found: var int): bool =
  ## The nth line whose STRIPPED text contains the anchor.
  ##
  ## STRIPPED, so re-indenting a block — which a formatter does to whole files
  ## — does not unresolve every point in it. CONTAINS rather than equals, so
  ## an anchor is a fragment an author can pick out of a line rather than a
  ## line they have to reproduce exactly, including a trailing comment.
  ##
  ## BOUNDED by `lines.len` and by the anchor length, with no backtracking:
  ## `contains` is a linear scan. §2.2's "matching is total and terminates by
  ## construction" applies to re-resolution as much as to the visualiser
  ## rules.
  var seen = 0
  for i, raw in lines:
    if raw.strip().contains(anchor.text):
      inc seen
      if seen == anchor.occurrence:
        found = i + 1
        return true
  false

func resolvePoint*(p: PointDefinition; lines: openArray[string];
                   presentInCheckout: bool): PointResolution =
  ## One point, against one file's lines.
  ##
  ## `presentInCheckout` is a PARAMETER rather than something this module
  ## works out, because working it out is a filesystem call and this package
  ## does not make any.
  ##
  ## It is not spelled `fileExistsInCheckout`, and the rename was forced by
  ## this package's own forbidden-name scan on its first run: a parameter
  ## containing the substring `fileExists` is indistinguishable, to a scanner
  ## reading text, from a call to `os.fileExists`. A guard that has to be
  ## taught about one exception is a guard the next reader will teach about
  ## the second. The caller holding the checkout answers it; see this
  ## module's header for why it is not folded into "the line list is empty".
  result.point = p
  if not presentInCheckout:
    result.outcome = prFileAbsent
    result.line = 0
    result.detail =
      "'" & p.path & "' is not in this checkout. The point was not dropped: " &
      "a collection that quietly loses the points whose files moved is a " &
      "collection nobody can trust the rest of"
    return
  var at = 0
  if not anchorLine(lines, p.anchor, at):
    result.outcome = prUnresolved
    result.line = 0
    result.detail =
      "no line in '" & p.path & "' contains '" & p.anchor.text & "'" &
      (if p.anchor.occurrence > 1:
         " for the " & $p.anchor.occurrence & getSuffix(p.anchor.occurrence) &
         " time"
       else: "") &
      ". The anchor is what makes the point survive edits above it; when the " &
      "anchored code itself is rewritten, the point is reported rather than " &
      "silently moved to whatever is at its old line number"
    return
  let target = at + p.anchor.offset
  if target > lines.len:
    # The anchor resolved and the offset walked off the end. Unresolvable
    # rather than clamped to the last line: a point clamped to the end of a
    # file is a point pointing at something arbitrary, which is the silent
    # mislocation the anchor exists to prevent.
    result.outcome = prUnresolved
    result.line = 0
    result.detail =
      "'" & p.anchor.text & "' is at line " & $at & " of '" & p.path &
      "', and the point sits " & $p.anchor.offset & " line(s) below it, " &
      "past the end of a file with " & $lines.len & " lines"
    return
  result.line = target
  if p.anchor.line == 0 or p.anchor.line == target:
    result.outcome = prResolved
    result.detail = ""
  else:
    result.outcome = prMoved
    result.detail =
      "'" & p.anchor.text & "' was at line " & $p.anchor.line & " and is now " &
      "at line " & $target & " of '" & p.path & "'. The point followed it"

type
  SourceFile* = object
    ## One file of the checkout, as the resolver needs it: whether it is
    ## there, and its lines if it is.
    present*: bool
    lines*: seq[string]

func resolveCollection*(c: PointCollection;
                        sources: proc (path: string): SourceFile {.
                          noSideEffect, gcsafe, raises: [].}):
    CollectionResolution =
  ## Re-resolve every point of one collection.
  ##
  ## `sources` is a `{.noSideEffect.}` proc TYPE, which is the compiler
  ## enforcing what this module's header claims: a caller cannot pass a
  ## lookup that reads the clock or the network, because such a proc does not
  ## satisfy the type. It CAN pass one that reads a map it filled from disk
  ## beforehand, which is exactly the intended shape — the I/O happens in the
  ## caller, once, before any of this runs.
  ##
  ## THE RESULT HAS ONE ENTRY PER DECLARED POINT. There is no `continue` in
  ## this loop and no filter after it.
  result.collection = c
  for p in c.points:
    let src = sources(p.path)
    result.points.add resolvePoint(p, src.lines, src.present)

func counts*(r: CollectionResolution): array[PointOutcome, int] =
  ## How many points met each fate. A fold rather than four counters at the
  ## call site, so a report and a test cannot count differently (§14).
  for pr in r.points:
    inc result[pr.outcome]

func unresolvedCount*(r: CollectionResolution): int =
  let c = counts(r)
  c[prUnresolved] + c[prFileAbsent]

func summarise*(r: CollectionResolution): string =
  ## One line a pane or a log can show: the collection, and what became of its
  ## points. Every point is accounted for in it — the four counts sum to the
  ## declared point count, which the suite asserts directly.
  let c = counts(r)
  var parts: seq[string] = @[]
  for o in PointOutcome:
    if c[o] > 0: parts.add $c[o] & " " & describe(o)
  "collection '" & r.collection.name & "': " & $r.points.len & " point(s) — " &
    (if parts.len > 0: parts.join(", ") else: "none declared")
