## Headless tests for context expansion in the unified diff (DR-R5).
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
## VCS-Panel.md, "Unified Diff View (Editor Integration)": "Context expansion
## controls (Expand N lines above/below)".
##
## Before DR-R5 the whole capability lived as private procs inside
## ``src/frontend/ui/deepreview.nim`` (:505-535 for the counters, :608-700 for
## the slicing), a JS-only module with no importable entry point, so none of
## the arithmetic below could be asserted at all — the only coverage was three
## Playwright tests against the standalone panel's DOM.  ``viewmodels/
## context_expansion.nim`` is the seam that makes it testable; this file is the
## test the milestone's Verification section names.
##
## The boundary-clamping cases in particular are here rather than in Playwright
## because they are arithmetic, and arithmetic asserted through a browser is
## asserted at the wrong layer (Testing-Guidelines.md, "headless-first").

import std/[strutils, unittest]

import viewmodels/vcs_vm
import viewmodels/context_expansion
import viewmodels/diff_document

proc numberedSource(count: int): seq[string] =
  ## ``count`` lines whose content names their own 1-based number, so a
  ## revealed line's content and its reported line number can be cross-checked
  ## against each other rather than against the same variable twice.
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = "line " & $(i + 1)

proc hunkAt(newStart, newCount: int): VCSHunkRow =
  ## A hunk occupying new lines ``newStart .. newStart + newCount - 1``.  Its
  ## body is irrelevant to the window arithmetic — only the declared range and
  ## the line numbers of its lines are — but it carries real lines so that the
  ## ``hunkLastNewLine`` fallback is exercised on a realistic value.
  var lines: seq[VCSDiffLineRow] = @[]
  for i in 0 ..< newCount:
    lines.add(VCSDiffLineRow(lineType: "context",
                             content: "line " & $(newStart + i),
                             oldLine: newStart + i, newLine: newStart + i))
  VCSHunkRow(oldStart: newStart, oldCount: newCount,
             newStart: newStart, newCount: newCount, lines: lines)

suite "context expansion window (DR-R5)":

  test "test_context_expansion_window_reveals_lines_above_and_below":
    ## §4.2: "Expand surrounding context above a visible region / Expand
    ## surrounding context below a visible region" and "Repeated expansion
    ## loads more file content instead of merely uncovering lines that were
    ## already fetched".
    ##
    ## The fixture is the milestone's: a hunk at new lines 40-51 of a 200-line
    ## file, expanded one step and then a second step in each direction.
    let source = numberedSource(200)
    let hunk = hunkAt(40, 12)
    check hunkLastNewLine(hunk) == 51

    # One step above reveals the ten lines immediately preceding the hunk.
    let above1 = expansionWindow(hunk, source, ContextExpandStep, 0)
    check above1.above.len == ContextExpandStep
    check above1.above[0].newLine == 30
    check above1.above[0].oldLine == 30
    check above1.above[0].content == "line 30"
    check above1.above[^1].newLine == 39
    check above1.above[^1].content == "line 39"
    # Revealed lines are context lines — §4.2, "Newly revealed lines become
    # normal code lines in the diff tab".
    for line in above1.above:
      check line.lineType == "context"
    check above1.canExpandAbove
    check above1.below.len == 0

    # A second step loads ten *further* lines rather than re-revealing the
    # same ten.
    let above2 = expansionWindow(hunk, source, 2 * ContextExpandStep, 0)
    check above2.above.len == 2 * ContextExpandStep
    check above2.above[0].newLine == 20
    check above2.above[0].content == "line 20"
    check above2.above[^1].newLine == 39
    check above2.canExpandAbove

    # Below: the ten lines immediately following the hunk's last new line.
    let below1 = expansionWindow(hunk, source, 0, ContextExpandStep)
    check below1.below.len == ContextExpandStep
    check below1.below[0].newLine == 52
    check below1.below[0].content == "line 52"
    check below1.below[^1].newLine == 61
    check below1.canExpandBelow
    check below1.above.len == 0

    let below2 = expansionWindow(hunk, source, 0, 2 * ContextExpandStep)
    check below2.below.len == 2 * ContextExpandStep
    check below2.below[0].newLine == 52
    check below2.below[^1].newLine == 71
    check below2.canExpandBelow

    # Both directions at once are independent of each other.
    let both = expansionWindow(hunk, source, ContextExpandStep,
                               ContextExpandStep)
    check both.above.len == ContextExpandStep
    check both.below.len == ContextExpandStep
    check both.above[0].newLine == 30
    check both.below[^1].newLine == 61

  test "test_context_expansion_clamps_at_file_boundaries":
    ## A hunk near the top of the file can only reveal as many lines as exist
    ## above it, and must then report that no further expansion above is
    ## possible; likewise at the end of the file.  Getting this wrong is how a
    ## diff tab ends up showing blank lines numbered 0 and -1.
    let source = numberedSource(200)

    # Hunk starting at line 3: exactly two lines exist above it.
    let topHunk = hunkAt(3, 4)
    let untouched = expansionWindow(topHunk, source, 0, 0)
    check untouched.canExpandAbove  # two lines are still hidden
    check untouched.above.len == 0

    let clampedAbove = expansionWindow(topHunk, source, ContextExpandStep, 0)
    check clampedAbove.above.len == 2
    check clampedAbove.above[0].newLine == 1
    check clampedAbove.above[0].content == "line 1"
    check clampedAbove.above[^1].newLine == 2
    check not clampedAbove.canExpandAbove

    # A hunk that starts on line 1 has nothing above it at all.
    let firstHunk = hunkAt(1, 3)
    let atTop = expansionWindow(firstHunk, source, 0, 0)
    check not atTop.canExpandAbove
    check expansionWindow(firstHunk, source, ContextExpandStep, 0).above.len == 0

    # Hunk covering lines 195-197 of a 200-line file: three lines below.
    let tailHunk = hunkAt(195, 3)
    check hunkLastNewLine(tailHunk) == 197
    let beforeBelow = expansionWindow(tailHunk, source, 0, 0)
    check beforeBelow.canExpandBelow

    let clampedBelow = expansionWindow(tailHunk, source, 0, ContextExpandStep)
    check clampedBelow.below.len == 3
    check clampedBelow.below[0].newLine == 198
    check clampedBelow.below[^1].newLine == 200
    check clampedBelow.below[^1].content == "line 200"
    check not clampedBelow.canExpandBelow

    # A hunk ending on the last line has nothing below it.
    let lastHunk = hunkAt(198, 3)
    check hunkLastNewLine(lastHunk) == 200
    check not expansionWindow(lastHunk, source, 0, 0).canExpandBelow
    check expansionWindow(lastHunk, source, 0, ContextExpandStep).below.len == 0

    # Without source text nothing can be revealed and neither control is
    # offered — the honest report when a `git show` failed or a review export
    # carried no `sourceContent`.
    let noSource = expansionWindow(hunkAt(40, 12), [], ContextExpandStep,
                                   ContextExpandStep)
    check noSource.above.len == 0
    check noSource.below.len == 0
    check not noSource.canExpandAbove
    check not noSource.canExpandBelow

  test "source text splits into 1-based lines":
    ## The counterpart of ``deepreview.nim``'s ``sourceContentLines``: element
    ## ``i`` is source line ``i + 1``.  Empty text yields no lines, which is
    ## what makes "no source" and "an empty file" behave identically.
    check sourceTextLines("a\nb\nc") == @["a", "b", "c"]
    check sourceTextLines("").len == 0

suite "context expansion source cache (DR-R5)":
  ## §4.2: in normal version-control mode "the surrounding lines are not part
  ## of the diff and must be fetched from the repository (e.g. `git show
  ## <rev>:<path>`) before they can be revealed."
  ##
  ## The fetch itself is a subprocess and belongs to the host, but *whether*
  ## one happens is a decision, and this is where it is asserted.  A tab that
  ## re-shelled to git on every expansion click would still look correct in
  ## Playwright.

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

    # Repeated expansion of the same file re-reads the cache, not git.
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
    ## Caching that would permanently disable the control for the file; the
    ## next click must be allowed to try again.
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

suite "the expanded document (DR-R5)":
  ## §4.2: "Newly revealed lines become normal code lines in the diff tab and
  ## can receive Omniscience overlays when matching DeepReview data exists."
  ##
  ## "Normal code lines" is the load-bearing phrase: a revealed line must be a
  ## context line of the document — same kind, same class, same eligibility for
  ## a decoration — and not a fourth, inert kind that DR-R6's overlay builder
  ## would have to learn about.

  proc expandableFile(): VCSDiffFileRow =
    VCSDiffFileRow(
      fileIndex: 0, status: "M", path: "src/main.rs",
      additions: 1, deletions: 1,
      sourceLines: numberedSource(200),
      hunks: @[hunkAt(40, 12)])

  test "expand controls appear around a hunk that has hidden neighbours":
    let doc = buildDiffDocument([expandableFile()])
    var aboveControls = 0
    var belowControls = 0
    for line in doc.lines:
      if line.kind == dlkExpandAbove: aboveControls += 1
      if line.kind == dlkExpandBelow: belowControls += 1
    check aboveControls == 1
    check belowControls == 1

    # The control's own text names how much a click reveals — VCS-Panel.md,
    # "Context expansion controls (Expand N lines above/below)".
    for line in doc.lines:
      if line.kind == dlkExpandAbove:
        check line.text.contains($ContextExpandStep)
        check line.text.contains("above")
      if line.kind == dlkExpandBelow:
        check line.text.contains("below")

  test "a file with no source text offers no controls":
    var file = expandableFile()
    file.sourceLines = @[]
    let doc = buildDiffDocument([file])
    for line in doc.lines:
      check line.kind notin {dlkExpandAbove, dlkExpandBelow}

  test "revealed lines are context lines of the document":
    let expansion = @[VCSHunkExpansion(fileIndex: 0, hunkIndex: 0,
                                       above: ContextExpandStep,
                                       below: ContextExpandStep)]
    let doc = buildDiffDocument([expandableFile()], expansion)

    var revealed: seq[DiffDocumentLine] = @[]
    for line in doc.lines:
      if line.revealed:
        revealed.add(line)
    check revealed.len == 2 * ContextExpandStep
    for line in revealed:
      # Same kind as any other unchanged line, so ``classFor`` gives it the
      # context background and DR-R6's overlay builder needs no new case.
      check line.kind == dlkContext
      check classFor(line.kind) == DiffContextClass
      check line.hunkIndex == 0
      check line.fileIndex == 0
    check revealed[0].newNumber == 30
    check revealed[ContextExpandStep - 1].newNumber == 39
    check revealed[ContextExpandStep].newNumber == 52

    # They are in the document in reading order: revealed-above lines sit
    # between the `@@` divider and the hunk body, revealed-below after it.
    var order: seq[string] = @[]
    for line in doc.lines:
      case line.kind
      of dlkHunkHeader: order.add("@@")
      of dlkExpandAbove: order.add("^")
      of dlkExpandBelow: order.add("v")
      of dlkContext:
        order.add(if line.revealed: "r" else: "c")
      else: order.add("x")
    let text = order.join("")
    check text.contains("@@^" & "r".repeat(ContextExpandStep))
    check text.contains("r".repeat(ContextExpandStep) & "v")

    # Every rendered line still gets exactly one decoration, and the revealed
    # ones carry the marker class on top of the context class.
    let decorations = decorationsFor(doc)
    check decorations.len == doc.lines.len
    for i, line in doc.lines:
      if line.revealed:
        check decorations[i].className.contains(DiffContextClass)
        check decorations[i].className.contains(DiffRevealedClass)
        check decorations[i].gutterClassName == DiffGutterContextClass

  test "the expand control resolves back to the hunk it belongs to":
    ## The Monaco host maps a click position through this; nothing else turns a
    ## screen position into an expansion request.
    let doc = buildDiffDocument([expandableFile()])
    var aboveLine = 0
    var belowLine = 0
    for i, line in doc.lines:
      if line.kind == dlkExpandAbove: aboveLine = i + 1
      if line.kind == dlkExpandBelow: belowLine = i + 1

    let aboveTarget = expandTargetAtLine(doc, aboveLine)
    check aboveTarget.present
    check aboveTarget.above
    check aboveTarget.fileIndex == 0
    check aboveTarget.hunkIndex == 0

    let belowTarget = expandTargetAtLine(doc, belowLine)
    check belowTarget.present
    check not belowTarget.above

    # A hunk header is not an expand control: clicking it selects the hunk.
    check not expandTargetAtLine(doc, 2).present
    check not expandTargetAtLine(doc, 0).present
    check not expandTargetAtLine(doc, doc.lines.len + 1).present

  test "expansion is exhausted rather than unbounded":
    ## Once every hidden line has been revealed the control disappears, so a
    ## user cannot keep clicking a button that can no longer do anything.
    let expansion = @[VCSHunkExpansion(fileIndex: 0, hunkIndex: 0,
                                       above: 100, below: 200)]
    let doc = buildDiffDocument([expandableFile()], expansion)
    var revealed = 0
    for line in doc.lines:
      if line.revealed: revealed += 1
      check line.kind notin {dlkExpandAbove, dlkExpandBelow}
    # 39 lines above the hunk, 149 below it (52..200).
    check revealed == 39 + 149
