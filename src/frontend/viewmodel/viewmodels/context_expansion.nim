## Context expansion for the unified diff: where the file's text comes from,
## and where it is cached.
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
## mode it is serving: ``SourceTextCache`` takes the fetch as a callback, and
## the mode question is answered once, at the data-source edge in
## ``ui/unified_diff.nim`` — the rule DR-R4 established for
## ``diff_document.nim`` and this module keeps.
##
## What UD-2 removed, and why it is not somewhere else now
## -------------------------------------------------------
## DR-R5 also owned the *window*: ``expansionWindow`` sliced the file's lines
## into "what this hunk currently reveals above and below itself", and a
## per-hunk counter on the ViewModel advanced it ten lines at a time.
##
## UD-2 deleted that.  The diff tab's models are the whole file now
## (``diff_document.buildDiffPair``), and which of its lines are on screen is
## decided by Monaco's own ``hideUnchangedRegions``.  Keeping the slice as well
## would be two notions of the same window, and the second one would drift:
## a reader dragging Monaco's boundary would move one of them and not the
## other.  The arithmetic's *coverage* — clamping at the first and last line of
## the file, and refusing to offer an expansion that would reveal nothing — did
## not go with it; it moved to ``diff_document.collapsedRegionsFor`` and is
## asserted in ``vcs_context_expansion_test.nim`` against the new notion.
##
## What stayed is the part UD-2 needs *more* than DR-R5 did: the file's full
## text, and a cache for it.  The whole-file model is built from exactly that
## text, so obtaining it is no longer a per-click cost but a per-load one.

import std/strutils

type
  SourceFetch* = proc(revision, path: string): string
    ## How the host obtains a file's full text for a revision.  A callback
    ## rather than a direct call so the cache's decisions are testable without
    ## a repository: the two modes differ only in what this proc does.

  SourceTextCache* = ref object
    ## Per-diff-tab cache of fetched file text, keyed by (revision, path).
    ##
    ## It exists because the diff tab's models ARE that text: every reload of
    ## the tab — a staged hunk, a layout restore, a re-sync — asks for the same
    ## file again, and a tab that re-shelled to ``git show`` each time would
    ## spawn a subprocess per reload.  Keying on the revision as well as the
    ## path is what keeps two tabs showing two commits of one file from
    ## answering each other's questions.
    entries: seq[(string, seq[string])]

proc sourceTextLines*(text: string): seq[string] =
  ## Split a file's full text into lines, element ``i`` being source line
  ## ``i + 1``.  Port of ``deepreview.nim``'s ``sourceContentLines``.
  ##
  ## Empty text yields no lines, so "the export carried no source content" and
  ## "the file is empty" behave identically: neither can be shown whole.
  if text.len == 0:
    return @[]
  text.split('\n')

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
