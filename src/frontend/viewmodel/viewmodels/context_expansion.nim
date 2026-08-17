## Context expansion for the unified diff: which surrounding lines a hunk can
## reveal, and where their text is cached.
##
## DeepReview-GUI.md §4.2, "Context Expansion":
##
##   "The user can reveal surrounding unchanged lines around the changed
##    regions.  Required controls: Expand surrounding context above a visible
##    region / Expand surrounding context below a visible region / Repeated
##    expansion loads more file content instead of merely uncovering lines that
##    were already fetched."
##
##   "The two instantiation modes of the diff tab differ in where the extra
##    lines come from, and only there: In DeepReview mode the exported review
##    data already carries each file's full source text, so expansion is a
##    local slice.  In normal version-control mode the surrounding lines are not
##    part of the diff and must be fetched from the repository (e.g. `git show
##    <rev>:<path>`) before they can be revealed.  The control, the decorations
##    and the overlay behavior are identical in both cases."
##
## That last sentence is the shape of this module.  Nothing here knows which
## mode it is serving: ``expansionWindow`` takes the source lines as an
## ``openArray[string]`` and has no way to ask where they came from, and
## ``SourceTextCache`` takes the fetch as a callback.  The mode question is
## answered once, at the data-source edge in ``ui/unified_diff.nim``, which is
## the rule DR-R4 established for ``diff_document.nim`` and this module keeps.
##
## The arithmetic is a port of ``src/frontend/ui/deepreview.nim`` :628-700 —
## the standalone panel DR-R8 deletes — rather than a rewrite, because the
## original already clamps correctly at both file boundaries and a rewrite
## would risk reintroducing the off-by-ones it got right.  What changed is the
## surface: it operates on ``VCSHunkRow`` / ``VCSDiffLineRow`` instead of the
## review-only ``DeepReviewHunk``, it is pure, and it compiles on the native
## backend so the boundary cases can be asserted without a browser.

import std/strutils

import ../viewmodels/vcs_vm

# ``ContextExpandStep`` is declared in ``vcs_vm``, where it has to live: the
# counters ``expandContextAbove`` / ``expandContextBelow`` advance are on the
# ViewModel, and this module imports that one.  Re-exported here so importers
# of the expansion seam get the step without having to know which of the two
# modules declares it.
export ContextExpandStep

type
  ExpansionWindow* = object
    ## What one hunk currently reveals around itself.
    ##
    ## ``above`` and ``below`` are ordinary context lines, ready to be placed
    ## in the document on either side of the hunk's own lines — §4.2: "Newly
    ## revealed lines become normal code lines in the diff tab".
    above*: seq[VCSDiffLineRow]
    below*: seq[VCSDiffLineRow]
    ## Whether a further click in that direction would reveal anything.  The
    ## host hides the control when it would not, so a user never presses a
    ## button that cannot act.
    canExpandAbove*: bool
    canExpandBelow*: bool

  SourceFetch* = proc(revision, path: string): string
    ## How the host obtains a file's full text for a revision.  A callback
    ## rather than a direct call so the cache's decisions are testable without
    ## a repository: the two modes differ only in what this proc does.

  SourceTextCache* = ref object
    ## Per-diff-tab cache of fetched file text, keyed by (revision, path).
    ##
    ## It exists because expansion is *incremental*: each click asks for the
    ## same file again with a larger window, and a tab that re-shelled to
    ## ``git show`` on every click would spawn a subprocess per press.  Keying
    ## on the revision as well as the path is what keeps two tabs showing two
    ## commits of one file from answering each other's questions.
    entries: seq[(string, seq[string])]

proc sourceTextLines*(text: string): seq[string] =
  ## Split a file's full text into lines, element ``i`` being source line
  ## ``i + 1``.  Port of ``deepreview.nim``'s ``sourceContentLines``.
  ##
  ## Empty text yields no lines, so "the export carried no source content" and
  ## "the file is empty" behave identically: neither can reveal anything.
  if text.len == 0:
    return @[]
  text.split('\n')

proc hunkLastNewLine*(hunk: VCSHunkRow): int {.noSideEffect.} =
  ## The last line number on the new side of a hunk.
  ##
  ## Prefers the declared ``newStart``/``newCount`` range and falls back to the
  ## largest ``newLine`` actually seen, because a hunk header with a missing
  ## count (git writes ``@@ -3 +3 @@`` for a single-line range) would otherwise
  ## place the boundary one line too early and hide a line forever.
  result = hunk.newStart + hunk.newCount - 1
  for line in hunk.lines:
    if line.newLine > result:
      result = line.newLine

proc revealedLine(source: openArray[string]; lineNum: int): VCSDiffLineRow
    {.noSideEffect.} =
  ## One revealed line, as a context line of the diff.
  ##
  ## Both line numbers are set to ``lineNum``: a revealed line is unchanged, so
  ## it occupies the same position in the old and the new revision, and the
  ## dual gutter must show both.  Out-of-range numbers yield empty content
  ## rather than raising — the callers clamp, and a defensive empty line is a
  ## better failure than a crash inside a render.
  let content =
    if lineNum >= 1 and lineNum <= source.len: source[lineNum - 1]
    else: ""
  VCSDiffLineRow(lineType: "context", content: content,
                 oldLine: lineNum, newLine: lineNum)

proc expansionWindow*(hunk: VCSHunkRow; source: openArray[string];
                      aboveCount, belowCount: int): ExpansionWindow
                      {.noSideEffect.} =
  ## The lines a hunk currently reveals, given how many steps' worth of
  ## expansion has been requested in each direction.
  ##
  ## Pure: (hunk, full source lines, above-count, below-count) in, revealed
  ## lines plus whether further expansion is possible out.  Both counts are
  ## *totals*, not deltas, so the caller's per-hunk counter is the whole state
  ## and re-deriving the window is idempotent.
  ##
  ## Without source text neither direction is offered.  That is the honest
  ## report for a review export with no ``sourceContent`` and for a ``git
  ## show`` that failed, and it is what the original did.
  if source.len == 0:
    return ExpansionWindow(canExpandAbove: false, canExpandBelow: false)

  # Lines above the hunk: [newStart - aboveCount .. newStart - 1], clamped to
  # the first line of the file.
  let aboveEnd = hunk.newStart - 1
  let aboveStart = max(1, aboveEnd - aboveCount + 1)
  if aboveCount > 0 and aboveEnd >= 1:
    for lineNum in aboveStart .. aboveEnd:
      result.above.add(revealedLine(source, lineNum))
  # A further step reveals something only while a line remains hidden above.
  result.canExpandAbove = (aboveEnd - aboveCount) >= 1

  # Lines below the hunk: [lastNew + 1 .. lastNew + belowCount], clamped to the
  # last line of the file.
  let lastNew = hunkLastNewLine(hunk)
  let belowStart = lastNew + 1
  let belowEnd = min(source.len, lastNew + belowCount)
  if belowCount > 0 and belowStart <= source.len:
    for lineNum in belowStart .. belowEnd:
      result.below.add(revealedLine(source, lineNum))
  result.canExpandBelow = (lastNew + belowCount + 1) <= source.len

# ---------------------------------------------------------------------------
# Source text cache
# ---------------------------------------------------------------------------

proc newSourceTextCache*(): SourceTextCache =
  SourceTextCache(entries: @[])

proc cacheKey*(revision, path: string): string {.noSideEffect.} =
  ## A revision and a path, joined by a byte that cannot occur in either.
  revision & "\0" & path

proc hasSource*(cache: SourceTextCache; revision, path: string): bool =
  if cache.isNil:
    return false
  let key = cacheKey(revision, path)
  for entry in cache.entries:
    if entry[0] == key:
      return true
  false

proc linesFor*(cache: SourceTextCache; revision, path: string;
               fetch: SourceFetch): seq[string] =
  ## The file's lines, fetching them at most once per (revision, path).
  ##
  ## A fetch that yields nothing is deliberately NOT cached: ``git show`` on a
  ## path absent from that revision, or on a repository that is momentarily
  ## unreadable, returns an empty string, and remembering that would disable
  ## the expand control for the rest of the tab's life on the strength of one
  ## transient failure.
  if cache.isNil:
    if fetch.isNil:
      return @[]
    return sourceTextLines(fetch(revision, path))
  let key = cacheKey(revision, path)
  for entry in cache.entries:
    if entry[0] == key:
      return entry[1]
  if fetch.isNil:
    return @[]
  let lines = sourceTextLines(fetch(revision, path))
  if lines.len > 0:
    cache.entries.add((key, lines))
  lines

proc invalidate*(cache: SourceTextCache) =
  ## Forget everything.  Called when the diff a tab shows is reloaded — after
  ## staging a hunk, say — because a working-tree revision is mutable and the
  ## cached text may no longer be what the diff describes.
  if not cache.isNil:
    cache.entries = @[]
