## Headless tests for context expansion in the unified diff (DR-R5, UD-2).
##
## DeepReview-GUI.md §4.2, "Context Expansion":
##
##   "The user can reveal surrounding unchanged lines around the changed
##    regions.  Required controls: Expand surrounding context above a visible
##    region / Expand surrounding context below a visible region / Repeated
##    expansion loads more file content instead of merely uncovering lines that
##    were already fetched."
##
##   "Context expansion is incremental loading.  Newly revealed lines become
##    normal code lines in the diff tab and can receive Omniscience overlays
##    when matching DeepReview data exists."
##
##   "The two instantiation modes of the diff tab differ in where the extra
##    lines come from, and only there … The control, the decorations and the
##    overlay behavior are identical in both cases."
##
## §4.3, "Draggable Edge Lines": "Each currently visible context boundary
## exposes a draggable edge line.  Dragging that boundary upward or downward
## increases the number of visible lines".
##
## ---------------------------------------------------------------------------
## What UD-2 changed about this file, and why
## ---------------------------------------------------------------------------
##
## DR-R5 built the diff tab's model as a *window* around each hunk and grew it
## by a per-hunk counter: ``context_expansion.expansionWindow`` sliced the
## file's text, ``VCSVM.expandContextAbove`` / ``…Below`` advanced the counter,
## and the control was a LINE of the model.  Every case below used to assert
## that arithmetic.
##
## UD-2 removed it.  The models are now the file itself — every line of the
## reviewed revision, in order — and Monaco's own ``hideUnchangedRegions``
## decides which of them are on screen.  There is therefore no second notion of
## "the window" left to drift from the first: the sliced window is gone, not
## duplicated.  (The reason it had to go is recorded in
## ``Unified-Diff-Design.milestones.org``, UD-1 ``:blockers:`` — a *windowed*
## model tokenizes from its own line 1, so a hunk that starts inside a
## docstring made the rest of the file tokenize as a string.)
##
## The coverage did not go with it.  Every property the old cases asserted has
## a counterpart here, against the new notion:
##
## | DR-R5 case                                  | UD-2 counterpart |
## |---------------------------------------------+------------------|
## | a hunk reveals N lines above / below        | the document already holds every line above and below the hunk |
## | repeated expansion loads *further* content  | ``collapsedRegionsFor`` says how many lines are hidden, and the menu's commands reveal by increment / to the file's edge |
## | clamping at the first and last line         | a run touching the file's edge is trimmed on ONE side only, so nothing beyond the edge is ever offered |
## | the control disappears when exhausted       | a run too short to collapse produces no region, hence no boundary at all |
## | a file with no source text offers none      | a file with no source text still renders its hunks, and has no unchanged runs to collapse |
## | revealed lines are ordinary context lines   | "the lines a boundary hides are ordinary context lines": every line outside a hunk is `dlkContext`, carries `DiffContextClass` and the context gutter, is numbered in BOTH columns, and gets exactly one decoration |
##
## The source-text cache is unchanged and its suite is carried over verbatim:
## expansion still needs the file's full text, and in normal version-control
## mode that still comes from ``git show`` exactly once per (revision, path).
##
## The boundary cases in particular are here rather than in Playwright because
## they are arithmetic, and arithmetic asserted through a browser is asserted
## at the wrong layer (Testing-Guidelines.md, "headless-first").

import std/[strutils, unittest]

import viewmodels/vcs_vm
import viewmodels/context_expansion
import viewmodels/diff_document
import viewmodels/diff_expansion_menu

proc numberedSource(count: int): seq[string] =
  ## ``count`` lines whose content names their own 1-based number, so a
  ## document line's content and its reported line number can be cross-checked
  ## against each other rather than against the same variable twice.
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = "line " & $(i + 1)

proc contextLine(n: int): VCSDiffLineRow =
  VCSDiffLineRow(lineType: "context", content: "line " & $n,
                 oldLine: n, newLine: n)

proc rewriteHunk(line: int; context = 3): VCSHunkRow =
  ## A git-shaped hunk that rewrites exactly one line, carrying ``context``
  ## unchanged lines on each side of it — the shape ``git diff -U3`` emits, and
  ## the shape that matters here, because those context lines are unchanged and
  ## therefore belong to the run the editor collapses.
  let first = max(1, line - context)
  var lines: seq[VCSDiffLineRow] = @[]
  for n in first ..< line:
    lines.add(contextLine(n))
  lines.add(VCSDiffLineRow(lineType: "removed", content: "line " & $line &
                           " (old)", oldLine: line, newLine: 0))
  lines.add(VCSDiffLineRow(lineType: "added", content: "line " & $line &
                           " (new)", oldLine: 0, newLine: line))
  for n in line + 1 .. line + context:
    lines.add(contextLine(n))
  let count = (line - first) + 1 + context
  VCSHunkRow(oldStart: first, oldCount: count, newStart: first,
             newCount: count, lines: lines)

proc expandableFile(hunks: seq[VCSHunkRow] = @[rewriteHunk(46)];
                    lineCount = 200): VCSDiffFileRow =
  VCSDiffFileRow(
    fileIndex: 0, status: "M", path: "src/main.rs",
    additions: 1, deletions: 1,
    sourceLines: numberedSource(lineCount),
    hunks: hunks)

proc newNumbersOf(doc: DiffDocument): seq[int] =
  result = @[]
  for line in doc.lines:
    if line.newNumber > 0:
      result.add(line.newNumber)

proc hiddenNewLines(pair: DiffPair): seq[int] =
  ## The FILE line numbers a freshly opened diff editor hides behind an
  ## expansion boundary.
  ##
  ## Asserting file lines rather than model lines is deliberate: a model line
  ## is an implementation detail of the document assembly, and a reader's
  ## question is "which lines of my file can I not see".
  result = @[]
  let context = diffContextLineCount(pair)
  for region in collapsedRegionsFor(pair, context):
    for offset in 0 ..< region.lineCount:
      let line = pair.modified.lines[region.modifiedStart - 1 + offset]
      if line.newNumber > 0:
        result.add(line.newNumber)

proc hiddenKinds(pair: DiffPair): seq[DiffLineKind] =
  result = @[]
  let context = diffContextLineCount(pair)
  for region in collapsedRegionsFor(pair, context):
    for offset in 0 ..< region.lineCount:
      result.add(pair.modified.lines[region.modifiedStart - 1 + offset].kind)

suite "the whole-file diff document (UD-2)":
  ## UD-2's central change: the models are the file, not a window around each
  ## hunk.  That is what makes the tokenizer see the file from its own line 1
  ## — the blocker UD-1 recorded — and it is what makes Monaco's
  ## ``hideUnchangedRegions`` the single notion of which lines are on screen.

  test "the modified document holds every line of the new revision":
    let pair = buildDiffPair([expandableFile()])
    # Line 1 of the file is the first numbered line of the document, so a
    # tokenizer starting at the model's first line starts at the file's first.
    check pair.modified.lines.len > 0
    check newNumbersOf(pair.modified)[0] == 1
    check newNumbersOf(pair.modified)[^1] == 200
    # Every one of the 200 lines is present exactly once, in order, and each
    # carries its own text — the property the sliced window could not have.
    var seen: seq[int] = @[]
    for line in pair.modified.lines:
      if line.newNumber > 0:
        check line.newNumber notin seen
        seen.add(line.newNumber)
        if line.kind == dlkContext:
          check line.text == "line " & $line.newNumber
    check seen.len == 200
    for expected in 1 .. 200:
      check expected in seen

  test "the original document is the OLD revision, reconstructed":
    ## The export carries the new side's text only, so the old side is that
    ## text with each hunk's own old lines put back — which is exactly what a
    ## diff says.  Getting this wrong would make Monaco report the whole file
    ## as changed.
    let pair = buildDiffPair([expandableFile()])
    var oldTexts: seq[string] = @[]
    for line in pair.original.lines:
      if line.kind in {dlkContext, dlkRemoved}:
        oldTexts.add(line.text)
    check oldTexts.len == 200
    check oldTexts[0] == "line 1"
    check oldTexts[199] == "line 200"
    # The rewritten line is the OLD text there, and the new text is absent from
    # the old side entirely.
    check oldTexts[45] == "line 46 (old)"
    check "line 46 (new)" notin oldTexts

  test "the chrome that remains is the `@@` divider, on both sides":
    ## §4.1: "Hunk headers (`@@ -N,M +N,M @@`) as section dividers".  It stays
    ## a line of the model — byte-identical on both sides so Monaco reads it as
    ## unchanged and draws it once — and it is the click target hunk selection
    ## listens on.  The file header does NOT: it sits at line 1, which is
    ## exactly what a collapsed run at the top of a file hides, so it moved to
    ## the tab's DOM chrome and is carried on the pair instead.
    let pair = buildDiffPair([expandableFile()])
    for doc in [pair.original, pair.modified]:
      var headers = 0
      for line in doc.lines:
        if line.kind == dlkHunkHeader:
          headers += 1
          check line.text == "@@ -43,7 +43,7 @@"
        check line.text != fileHeaderText(expandableFile())
      check headers == 1
    check pair.files.len == 1
    check pair.files[0].path == "src/main.rs"
    check pair.files[0].headerText == fileHeaderText(expandableFile())

  test "a file with no source text still renders its hunks":
    ## `git show` failed, or a review export carried no `sourceContent`.  The
    ## honest document is the hunks alone: there is no file to be whole.
    var file = expandableFile()
    file.sourceLines = @[]
    let pair = buildDiffPair([file])
    check pair.modified.lines.len > 0
    check newNumbersOf(pair.modified)[0] == 43
    check newNumbersOf(pair.modified)[^1] == 49
    # ... and nothing is collapsible, because no unchanged run is long enough.
    check collapsedRegionsFor(pair, diffContextLineCount(pair)).len == 0

  test "the lines a boundary hides are ordinary context lines":
    ## §4.2's "Newly revealed lines become normal code lines in the diff tab
    ## and can receive Omniscience overlays when matching DeepReview data
    ## exists."  DR-R5 asserted this of the lines its window revealed; the
    ## whole-file document has no separate kind for them at all, and this is
    ## what says so: everything outside a hunk is a context line, carries the
    ## context background and the context gutter, belongs to no hunk, and gets
    ## exactly one decoration — so DR-R6's overlay builder needs no new case
    ## for a line a reader has just brought on screen.
    let pair = buildDiffPair([expandableFile()])
    for doc in [pair.original, pair.modified]:
      let decorations = decorationsFor(doc)
      check decorations.len == doc.lines.len
      var outsideHunk = 0
      for i, line in doc.lines:
        if line.hunkIndex >= 0:
          continue
        outsideHunk += 1
        check line.kind == dlkContext
        check decorations[i].className == DiffContextClass
        check decorations[i].gutterClassName == DiffGutterContextClass
        check decorations[i].lineNumberClassName == ""
        # An unchanged line occupies a position in both revisions, so both
        # gutter columns name it — which is what makes it read as context
        # rather than as a change.
        check line.oldNumber > 0
        check line.newNumber > 0
      # 200 lines, of which the hunk itself carries 7 (43-49).
      check outsideHunk == 193
    # ... and the lines the editor actually hides are among exactly those.
    for kind in hiddenKinds(pair):
      check kind == dlkContext

  test "hunk selection still resolves, and only inside a hunk":
    ## VCS-Panel.md, "Hunk Selection": clicking the `@@` header selects the
    ## hunk.  Most of a whole-file document is outside every hunk, and those
    ## lines must resolve to nothing rather than to hunk 0.
    let pair = buildDiffPair([expandableFile()])
    var headerLine = 0
    for i, line in pair.modified.lines:
      if line.kind == dlkHunkHeader:
        headerLine = i + 1
    check headerLine > 0
    check isHunkHeaderLine(pair.modified, headerLine)
    check hunkAtLine(pair.modified, headerLine) == (0, 0)
    # Line 1 of the file is far outside the hunk.
    check not isHunkHeaderLine(pair.modified, 1)
    check hunkAtLine(pair.modified, 1) == (-1, -1)

suite "which lines a boundary hides (UD-2)":
  ## ``collapsedRegionsFor`` is this milestone's single notion of the window.
  ## It replicates the rule the vendored Monaco applies in
  ## ``UnchangedRegion.fromDiffs`` (monaco-editor 0.54.0,
  ## ``min/vs/editor.api-i0YVFWkl.js``): a run of unchanged lines keeps
  ## ``contextLineCount`` visible at each end that abuts a change, and becomes
  ## a collapsed region only when at least ``minimumLineCount`` lines are left
  ## over.  Asserting it here is what makes the edge and adjacency cases
  ## testable without a browser; the Playwright suite cross-checks it against
  ## the real editor.

  test "a hunk in the middle of a file hides the file's far ends":
    let pair = buildDiffPair([expandableFile()])
    let hidden = hiddenNewLines(pair)
    # The far ends of the file are hidden ...
    check 1 in hidden
    check 200 in hidden
    # ... the change is not, and neither is the context the hunk itself
    # carries around it (43-45 and 47-49) nor the one extra line the editor
    # keeps below the boundary.
    for visible in 43 .. 50:
      check visible notin hidden
    # The boundary sits exactly where the hunk's own context ends.
    check 42 in hidden
    check 51 in hidden
    # Two boundaries: one above the hunk, one below it.
    check collapsedRegionsFor(pair, diffContextLineCount(pair)).len == 2

  test "the `@@` divider is never hidden by the collapse":
    ## The one line §4.1 names and hunk selection is keyed on.  It is an
    ## unchanged line, so without ``diffContextLineCount`` it would sit just
    ## behind the hunk's own context lines and be collapsed out of sight —
    ## which is what it did, measured, before that proc existed.
    for start in [1, 5, 12, 46, 120, 190, 197]:
      let pair = buildDiffPair([expandableFile(@[rewriteHunk(start)])])
      check dlkHunkHeader notin hiddenKinds(pair)
    # ... at every context width a diff might have been produced with.
    for width in [0, 1, 3, 5, 10]:
      let pair = buildDiffPair([expandableFile(@[rewriteHunk(120, width)])])
      check dlkHunkHeader notin hiddenKinds(pair)

  test "two hunks that nearly touch collapse nothing between them":
    ## The adjacency case, where off-by-one bugs live.  An interior run needs
    ## `2 * contextLineCount + minimumLineCount` lines before any of it can be
    ## hidden; a shorter one stays entirely on screen and offers no boundary at
    ## all, so a reader is never asked to expand two lines.
    ##
    ## The gap starts at 7 because a smaller one is not a shape git produces:
    ## with three lines of context on each side, two changes less than seven
    ## lines apart share context and git emits them as ONE hunk.
    for gap in 7 .. 40:
      let pair = buildDiffPair([expandableFile(
        @[rewriteHunk(60), rewriteHunk(60 + gap)], lineCount = 400)])
      let context = diffContextLineCount(pair)
      let hidden = hiddenNewLines(pair)
      var between = 0
      for line in hidden:
        if line > 60 and line < 60 + gap:
          between += 1
      # The run between the two changes is exactly `gap` lines long: three
      # trailing context lines, the file's own lines, the second `@@`, and
      # three leading context lines.  An interior run loses `context` at each
      # end, and collapses only if `minimumLineCount` survives that.
      if gap >= 2 * context + DiffMinimumLineCount:
        check between == gap - 2 * context
      else:
        check between == 0
      # Whatever the gap, both changed lines are always on screen, and so is
      # the divider that introduces the second hunk.
      check 60 notin hidden
      check (60 + gap) notin hidden
      check dlkHunkHeader notin hiddenKinds(pair)

  test "a run at the file's edge needs less before it collapses":
    ## Monaco trims a boundary run on one side only, so it collapses at
    ## `contextLineCount + minimumLineCount` rather than at twice that.  That
    ## is what makes "expand to the top of the file" reachable on a hunk only a
    ## few lines in — and what stops a two-line gap being offered as a gesture.
    for firstChange in 1 .. 20:
      let pair = buildDiffPair([expandableFile(
        @[rewriteHunk(firstChange)], lineCount = 400)])
      let context = diffContextLineCount(pair)
      var aboveHidden = 0
      for line in hiddenNewLines(pair):
        if line < firstChange:
          aboveHidden += 1
      # The run above the change is exactly `firstChange` lines long, whatever
      # the hunk's leading context: the file's own lines up to the hunk, the
      # `@@`, and the hunk's context lines.  It touches the document's start,
      # so only its lower end is trimmed.
      if firstChange >= context + DiffMinimumLineCount:
        check aboveHidden == firstChange - context
      else:
        check aboveHidden == 0

  test "a hunk on the first line has nothing above it, and none is offered":
    let pair = buildDiffPair([expandableFile(@[rewriteHunk(1)])])
    for line in hiddenNewLines(pair):
      check line > 1

  test "a hunk on the last line has nothing below it":
    let pair = buildDiffPair([expandableFile(@[rewriteHunk(200, 0)])])
    for line in hiddenNewLines(pair):
      check line < 200

  test "the hidden region never runs past either end of the document":
    ## The property the clamping cases used to assert on the sliced window:
    ## nothing beyond line 1 or beyond the last line is ever offered.
    for start in [1, 2, 3, 4, 5, 40, 190, 194, 197]:
      let pair = buildDiffPair([expandableFile(@[rewriteHunk(start)])])
      for region in collapsedRegionsFor(pair, diffContextLineCount(pair)):
        check region.modifiedStart >= 1
        check region.modifiedStart + region.lineCount - 1 <=
          pair.modified.lines.len
        check region.originalStart >= 1
        check region.originalStart + region.lineCount - 1 <=
          pair.original.lines.len
        check region.lineCount >= DiffMinimumLineCount

suite "the expansion menu's commands (UD-2)":
  ## §4.2's "expand more" and the owner's "the whole file in this direction",
  ## as data rather than as DOM, so the labels and the amounts are asserted
  ## where they are decided.  The host turns each command into one call on
  ## Monaco's unchanged region.

  test "a large hidden run offers an increment, a bigger one, and all of it":
    let commands = expansionMenuCommands(dedAbove, 137)
    check commands.len == 3
    check commands[0].lines == DiffExpandStep
    check not commands[0].wholeFile
    check commands[0].label == "Expand 10 lines above"
    check commands[1].lines == DiffExpandLargeStep
    check commands[1].label == "Expand 50 lines above"
    check commands[2].wholeFile
    check commands[2].lines == 137
    check commands[2].label == "Expand all 137 lines above"
    for command in commands:
      check command.direction == dedAbove

  test "the two directions are independent and named for themselves":
    let below = expansionMenuCommands(dedBelow, 137)
    check below.len == 3
    check below[0].label == "Expand 10 lines below"
    check below[^1].label == "Expand all 137 lines below"
    for command in below:
      check command.direction == dedBelow

  test "a command is never offered that would reveal nothing new":
    ## Offering "Expand 50 lines" beside "Expand all 30 lines" would be two
    ## names for one action, and a menu that lies about what it does is worse
    ## than a shorter menu.
    check expansionMenuCommands(dedAbove, 0).len == 0
    check expansionMenuCommands(dedAbove, -1).len == 0

    let seven = expansionMenuCommands(dedAbove, 7)
    check seven.len == 1
    check seven[0].wholeFile
    check seven[0].label == "Expand all 7 lines above"

    let thirty = expansionMenuCommands(dedAbove, 30)
    check thirty.len == 2
    check thirty[0].lines == DiffExpandStep
    check thirty[1].wholeFile

    # Exactly the increment: "all" is the only honest offer.
    let ten = expansionMenuCommands(dedAbove, DiffExpandStep)
    check ten.len == 1
    check ten[0].wholeFile

  test "the boundary announces itself to a screen reader in both directions":
    ## §4.2's controls must be reachable without a mouse, so the drag handle
    ## carries a name and a promise of what pressing it does.
    check expansionActionLabel(dedAbove).contains("above")
    check expansionActionLabel(dedAbove).contains($DiffExpandStep)
    check expansionActionLabel(dedBelow).contains("below")
    check expansionActionLabel(dedAbove) != expansionActionLabel(dedBelow)

suite "context expansion source cache (DR-R5)":
  ## §4.2: in normal version-control mode "the surrounding lines are not part
  ## of the diff and must be fetched from the repository (e.g. `git show
  ## <rev>:<path>`) before they can be revealed."
  ##
  ## Unchanged by UD-2, and needed more than before: the whole-file model is
  ## built from exactly this text, so a tab that re-shelled to git would now do
  ## it on every reload rather than on every click.

  test "test_context_expansion_fetches_source_once_and_caches":
    var calls: seq[string] = @[]
    let cache = newSourceTextCache()
    let fetch = proc(revision, path: string): string =
      calls.add(revision & ":" & path)
      "alpha\nbeta\ngamma"

    check not cache.hasSource("abc123", "src/main.rs")

    let first = cache.linesFor("abc123", "src/main.rs", fetch)
    check first == @["alpha", "beta", "gamma"]
    check calls.len == 1
    check cache.hasSource("abc123", "src/main.rs")

    # Repeated reads re-read the cache, not git.
    let second = cache.linesFor("abc123", "src/main.rs", fetch)
    check second == first
    check calls.len == 1

    # A different revision of the same path is a different blob.
    discard cache.linesFor("def456", "src/main.rs", fetch)
    check calls.len == 2
    check calls[1] == "def456:src/main.rs"

    # ... and a different path of the same revision likewise.
    discard cache.linesFor("abc123", "src/other.rs", fetch)
    check calls.len == 3

    # Invalidation is what keeps a working-tree diff honest after the tree
    # changes under it (staging a hunk, an external edit).
    cache.invalidate()
    check not cache.hasSource("abc123", "src/main.rs")
    discard cache.linesFor("abc123", "src/main.rs", fetch)
    check calls.len == 4

  test "a fetch that yields nothing is not cached as an answer":
    ## `git show` on a path that does not exist in that revision returns "".
    ## Caching that would permanently disable expansion for the file; the next
    ## reload must be allowed to try again.
    var calls = 0
    let cache = newSourceTextCache()
    let failing = proc(revision, path: string): string =
      calls += 1
      ""

    check cache.linesFor("abc", "gone.rs", failing).len == 0
    check calls == 1
    check not cache.hasSource("abc", "gone.rs")
    check cache.linesFor("abc", "gone.rs", failing).len == 0
    check calls == 2

  test "source text splits into 1-based lines":
    ## Element ``i`` is source line ``i + 1``.  Empty text yields no lines,
    ## which is what makes "no source" and "an empty file" behave identically.
    check sourceTextLines("a\nb\nc") == @["a", "b", "c"]
    check sourceTextLines("").len == 0
