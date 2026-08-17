## The unified diff as an editor *document*: pure text + pure decorations.
##
## DR-R4 (``codetracer-specs/DeepReview/DeepReview-GUI.milestones.org``) turns
## the unified diff into a real Monaco tab.  This module is the seam that makes
## that testable without a browser: diff rows in, one document line and one
## decoration per rendered line out.  Nothing here touches Monaco, the DOM or
## any signal — the host (``ui/unified_diff.nim``) only turns
## ``documentText`` into a model and ``decorationsFor`` into a Monaco
## decoration collection.
##
## Spec:
##
##   "Uses the standard CodeTracer Monaco editor / Added lines: green
##    background with `+` gutter marker / Removed lines: red background with
##    `-` gutter marker / Context lines: normal background / Hunk headers
##    (`@@ -N,M +N,M @@`) shown as section dividers"
##   — GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Editor Integration)"
##
##   "The diff rendering code does NOT check which mode is active — it simply
##    renders whatever data is provided."
##   — GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Shared)"
##
## The second sentence is why every proc below takes ``openArray[
## VCSDiffFileRow]`` (or a ``VCSVM`` it reads *only* ``diffFiles`` from) and
## nothing else.  There is no mode parameter to branch on, by construction:
## live git fills those rows in normal version-control mode and the review
## dataset fills them in DeepReview mode, and the document is the same either
## way.

import std/strutils

import isonim/core/signals
import ../viewmodels/vcs_vm
import ../viewmodels/context_expansion

type
  DiffLineKind* = enum
    ## What one line of the assembled document is.
    dlkFileHeader   ## "M  src/main.rs  +8 -3" — one per file in the document
    dlkHunkHeader   ## "@@ -N,M +N,M @@" — the section divider
    dlkAdded        ## a line present only in the new revision
    dlkRemoved      ## a line present only in the old revision
    dlkContext      ## a line present in both
    dlkExpandAbove  ## the "Expand N lines above" control (§4.2)
    dlkExpandBelow  ## the "Expand N lines below" control (§4.2)

  DiffDocumentLine* = object
    ## One line of the Monaco model, plus everything the gutters and the
    ## decorations need to describe it.
    kind*: DiffLineKind
    text*: string      ## exactly what the model holds for this line
    oldNumber*: int    ## line number in the old revision; 0 = none
    newNumber*: int    ## line number in the new revision; 0 = none
    fileIndex*: int    ## ``VCSDiffFileRow.fileIndex`` this line belongs to
    hunkIndex*: int    ## hunk within that file; -1 on a file header
    revealed*: bool
      ## True for a context line that context expansion uncovered rather than
      ## one the diff itself carried.
      ##
      ## Deliberately a *flag on a context line* and not a sixth kind:
      ## DeepReview-GUI.md §4.2 says "Newly revealed lines become normal code
      ## lines in the diff tab and can receive Omniscience overlays", so they
      ## must classify, decorate and (for DR-R6) annotate exactly as any other
      ## unchanged line.  The flag only adds a marker class, so nothing
      ## downstream has to learn a new case.

  DiffDocument* = object
    lines*: seq[DiffDocumentLine]

  DiffExpandTarget* = object
    ## What an expand control at some model line would expand.
    ##
    ## The Monaco host maps a click position through ``expandTargetAtLine``
    ## and hands this to ``VCSVM.expandContextAbove`` / ``…Below``; nothing
    ## else turns a screen position into an expansion request.
    present*: bool    ## false when that line is not an expand control
    above*: bool      ## true for expand-above, false for expand-below
    fileIndex*: int
    hunkIndex*: int

  DiffDecoration* = object
    ## One Monaco whole-line decoration.
    line*: int             ## 1-based model line number
    className*: string     ## whole-line class (background / colour)
    gutterClassName*: string  ## ``linesDecorationsClassName`` — the +/- marker

const
  DiffLineBaseClass* = "ct-diff-line"
  DiffFileHeaderClass* = "ct-diff-line ct-diff-line-file-header"
  DiffHunkHeaderClass* = "ct-diff-line ct-diff-line-hunk-header"
  DiffAddedClass* = "ct-diff-line ct-diff-line-added"
  DiffRemovedClass* = "ct-diff-line ct-diff-line-removed"
  DiffContextClass* = "ct-diff-line ct-diff-line-context"
  ## Applied *in addition* to the kind class on every line of a selected hunk,
  ## so the hunk editor's selection is visible on the Monaco content
  ## (VCS-Panel.md, "Hunk Selection").
  DiffSelectedHunkClass* = "ct-diff-hunk-selected"
  ## The two context-expansion controls (DeepReview-GUI.md §4.2).  They are
  ## lines of the model rather than DOM chrome for the same reason the file
  ## header is: they belong at a specific place in the scroll — immediately
  ## after a hunk's `@@` divider, and immediately after its last line — and a
  ## floating overlay could not follow them there.
  DiffExpandAboveClass* = "ct-diff-line ct-diff-line-expand ct-diff-line-expand-above"
  DiffExpandBelowClass* = "ct-diff-line ct-diff-line-expand ct-diff-line-expand-below"
  ## Applied *in addition* to the context class on a line that expansion
  ## revealed, so it reads as slightly dimmer than the diff's own context
  ## lines without becoming a different kind of line.  Carried over from
  ## ``.deepreview-expanded-context``.
  DiffRevealedClass* = "ct-diff-line-revealed"

  DiffGutterAddedClass* = "ct-diff-gutter ct-diff-gutter-added"
  DiffGutterRemovedClass* = "ct-diff-gutter ct-diff-gutter-removed"
  DiffGutterContextClass* = "ct-diff-gutter ct-diff-gutter-context"

  DiffEmptyDocumentText* = "No changes to show."
    ## The model text of a diff tab whose target produced no hunks.  A Monaco
    ## model cannot be empty and still be an editor, and a blank buffer would
    ## read as "still loading".

proc hunkHeaderText*(hunk: VCSHunkRow): string {.noSideEffect.} =
  ## The `@@` section divider.  Identical to the string the pre-DR-R4 DOM
  ## renderer produced and to the one ``buildPatchFromSelectedHunks`` emits,
  ## because a reviewer comparing the tab with a copied patch must see the same
  ## header.
  "@@ -" & $hunk.oldStart & "," & $hunk.oldCount &
    " +" & $hunk.newStart & "," & $hunk.newCount & " @@"

proc fileStatsText*(additions, deletions: int): string {.noSideEffect.} =
  if additions == 0 and deletions == 0: ""
  else: "+" & $additions & " -" & $deletions

proc fileHeaderText*(file: VCSDiffFileRow): string {.noSideEffect.} =
  ## DeepReview-GUI.md §4.1: "A file header with path and diff metadata".
  ##
  ## It is a document line rather than DOM chrome around the editor because a
  ## diff target can name several files — "Working Tree", or a whole commit —
  ## and then each file's header has to sit at that file's place in the
  ## scroll, not above the whole tab.
  let stats = fileStatsText(file.additions, file.deletions)
  result = file.status & "  " & file.path
  if stats.len > 0:
    result.add("  " & stats)

proc lineKindFor*(lineType: string): DiffLineKind {.noSideEffect.} =
  ## Map a ``VCSDiffLineRow.lineType`` onto a document line kind.
  ##
  ## Anything that is not an addition or a removal is context: git emits only
  ## those three, and treating an unknown type as context renders it plainly
  ## rather than dropping the line.
  case lineType
  of "added", "add": dlkAdded
  of "removed", "delete", "deleted": dlkRemoved
  else: dlkContext

proc expandAboveText*(): string {.noSideEffect.} =
  ## VCS-Panel.md: "Context expansion controls (Expand N lines above/below)".
  ## The leading "..." is the standalone panel's expand-row icon, kept so the
  ## migrated control reads the same.
  "... Expand " & $ContextExpandStep & " lines above"

proc expandBelowText*(): string {.noSideEffect.} =
  "... Expand " & $ContextExpandStep & " lines below"

proc buildDiffDocument*(files: openArray[VCSDiffFileRow];
                        expansion: openArray[VCSHunkExpansion] = []):
                        DiffDocument =
  ## Assemble the document a diff tab's Monaco model holds.
  ##
  ## Order is exactly the render order of the rows: for each file, its header,
  ## then for each hunk the `@@` divider, the expand-above control, the lines
  ## expansion has revealed above, the hunk's own lines, the lines revealed
  ## below, and the expand-below control.  That is the order the standalone
  ## panel's DOM renderer used (``isonim_deepreview_view.nim``), so the
  ## migrated surface reads identically.  Files with no hunks are skipped —
  ## they have nothing to show and a bare header would read as an empty diff
  ## for a file that was not, in fact, part of the changeset the target named.
  ##
  ## ``expansion`` defaults to empty, which is exactly "nothing expanded yet":
  ## the controls still appear wherever hidden lines exist, so a caller that
  ## does not track expansion still gets a correct, if static, document.
  result.lines = @[]
  for file in files:
    if file.hunks.len == 0:
      continue
    result.lines.add(DiffDocumentLine(
      kind: dlkFileHeader,
      text: fileHeaderText(file),
      fileIndex: file.fileIndex,
      hunkIndex: -1))
    for hunkIndex, hunk in file.hunks:
      let counts = expansionCountsIn(expansion, file.fileIndex, hunkIndex)
      let window = expansionWindow(hunk, file.sourceLines, counts[0], counts[1])

      result.lines.add(DiffDocumentLine(
        kind: dlkHunkHeader,
        text: hunkHeaderText(hunk),
        fileIndex: file.fileIndex,
        hunkIndex: hunkIndex))

      # The control is offered only while a further click would reveal
      # something, so a user never presses a button that cannot act.
      if window.canExpandAbove:
        result.lines.add(DiffDocumentLine(
          kind: dlkExpandAbove,
          text: expandAboveText(),
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex))
      for line in window.above:
        result.lines.add(DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: line.content,
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex,
          revealed: true))

      for line in hunk.lines:
        result.lines.add(DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: line.content,
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex))

      for line in window.below:
        result.lines.add(DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: line.content,
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex,
          revealed: true))
      if window.canExpandBelow:
        result.lines.add(DiffDocumentLine(
          kind: dlkExpandBelow,
          text: expandBelowText(),
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex))

proc diffDocumentFor*(vm: VCSVM): DiffDocument =
  ## The document for the diff a panel currently holds.
  ##
  ## This reads ``vm.diffFiles`` and ``vm.hunkExpansion`` and *nothing else* —
  ## in particular not ``vm.deepReviewMode``.  That is the mode-agnosticism
  ## rule of VCS-Panel.md, "Unified Diff View (Shared)", expressed as code
  ## rather than as a comment, and ``test_diff_decorations_are_mode_agnostic``
  ## fails if a later change makes this proc consult the mode.  Context
  ## expansion is the one place the two modes genuinely differ, and the
  ## difference is answered before the rows reach here: whoever filled
  ## ``VCSDiffFileRow.sourceLines`` has already decided whether that text came
  ## from a review export or from ``git show``.
  buildDiffDocument(vm.diffFiles.val, vm.hunkExpansion.val)

proc documentText*(doc: DiffDocument): string {.noSideEffect.} =
  ## The Monaco model's value.
  if doc.lines.len == 0:
    return DiffEmptyDocumentText
  var texts = newSeq[string](doc.lines.len)
  for i, line in doc.lines:
    texts[i] = line.text
  texts.join("\n")

proc classFor*(kind: DiffLineKind): string {.noSideEffect.} =
  case kind
  of dlkFileHeader: DiffFileHeaderClass
  of dlkHunkHeader: DiffHunkHeaderClass
  of dlkAdded: DiffAddedClass
  of dlkRemoved: DiffRemovedClass
  of dlkContext: DiffContextClass
  of dlkExpandAbove: DiffExpandAboveClass
  of dlkExpandBelow: DiffExpandBelowClass

proc gutterClassFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The class that draws the `+` / `-` gutter marker VCS-Panel.md requires.
  ## Headers and the expand controls get none: they are chrome, not content.
  case kind
  of dlkAdded: DiffGutterAddedClass
  of dlkRemoved: DiffGutterRemovedClass
  of dlkContext: DiffGutterContextClass
  of dlkFileHeader, dlkHunkHeader, dlkExpandAbove, dlkExpandBelow: ""

proc oldNumberText*(line: DiffDocumentLine): string {.noSideEffect.} =
  ## The old-revision gutter number, blank where there is none — an added line
  ## exists only in the new revision, and a header in neither.
  if line.oldNumber > 0: $line.oldNumber else: ""

proc newNumberText*(line: DiffDocumentLine): string {.noSideEffect.} =
  if line.newNumber > 0: $line.newNumber else: ""

proc lineNumberLabels*(doc: DiffDocument; width = 4): seq[string] =
  ## Dual old/new line numbers, one label per model line, in the order Monaco
  ## asks for them.
  ##
  ## The pre-DR-R4 DOM renderer drew two gutter columns
  ## (``deepreview-unified-gutter-old`` / ``-new``); Monaco has one, so the two
  ## numbers are padded into a single right-aligned label and the gutter is
  ## given ``white-space: pre`` so the padding survives.  ``width`` is the
  ## per-column width the host derives from the largest number in the document.
  result = newSeq[string](doc.lines.len)
  for i, line in doc.lines:
    if line.kind in {dlkFileHeader, dlkHunkHeader,
                     dlkExpandAbove, dlkExpandBelow}:
      result[i] = ""
    else:
      result[i] = align(oldNumberText(line), width) & " " &
                  align(newNumberText(line), width)

proc lineNumberWidth*(doc: DiffDocument): int {.noSideEffect.} =
  ## Digits needed by the widest line number in the document, minimum 1.
  result = 1
  for line in doc.lines:
    let n = max(len(oldNumberText(line)), len(newNumberText(line)))
    if n > result:
      result = n

proc isHunkSelected(selected: openArray[(int, int)];
                    fileIndex, hunkIndex: int): bool {.noSideEffect.} =
  for pair in selected:
    if pair[0] == fileIndex and pair[1] == hunkIndex:
      return true
  false

proc decorationsFor*(doc: DiffDocument;
                     selectedHunks: openArray[(int, int)] = []):
                     seq[DiffDecoration] =
  ## One whole-line decoration per document line.
  ##
  ## Exactly one, so a line can never end up carrying two conflicting
  ## backgrounds, and so the count of decorations is the count of lines — which
  ## is what lets ``vcs_diff_decorations_test.nim`` assert the classification
  ## line by line.  Hunk selection is an extra class on the same decoration,
  ## not a second one, for the same reason.
  result = newSeq[DiffDecoration](doc.lines.len)
  for i, line in doc.lines:
    var className = classFor(line.kind)
    if line.revealed:
      className.add(" " & DiffRevealedClass)
    if line.hunkIndex >= 0 and
        isHunkSelected(selectedHunks, line.fileIndex, line.hunkIndex):
      className.add(" " & DiffSelectedHunkClass)
    result[i] = DiffDecoration(
      line: i + 1,
      className: className,
      gutterClassName: gutterClassFor(line.kind))

proc hunkAtLine*(doc: DiffDocument; modelLine: int): (int, int) {.noSideEffect.} =
  ## The (fileIndex, hunkIndex) a 1-based model line belongs to, or (-1, -1).
  ## The Monaco host maps a click position through this and hands the pair to
  ## ``VCSVM.selectHunk``; nothing else translates screen positions to hunks.
  if modelLine < 1 or modelLine > doc.lines.len:
    return (-1, -1)
  let line = doc.lines[modelLine - 1]
  if line.hunkIndex < 0:
    return (-1, -1)
  (line.fileIndex, line.hunkIndex)

proc expandTargetAtLine*(doc: DiffDocument; modelLine: int): DiffExpandTarget
    {.noSideEffect.} =
  ## The expansion a click on a 1-based model line requests, if any.
  ##
  ## Returns ``present: false`` for every other line, including a hunk header
  ## — clicking that selects the hunk (VCS-Panel.md, "Hunk Selection"), and
  ## the two gestures must not both fire from one click.
  if modelLine < 1 or modelLine > doc.lines.len:
    return DiffExpandTarget(present: false)
  let line = doc.lines[modelLine - 1]
  if line.kind notin {dlkExpandAbove, dlkExpandBelow}:
    return DiffExpandTarget(present: false)
  DiffExpandTarget(
    present: true,
    above: line.kind == dlkExpandAbove,
    fileIndex: line.fileIndex,
    hunkIndex: line.hunkIndex)

proc isHunkHeaderLine*(doc: DiffDocument; modelLine: int): bool {.noSideEffect.} =
  ## VCS-Panel.md, "Hunk Selection": "Click a hunk header to select it."  Only
  ## the header is the selection gesture; clicking inside a hunk's body leaves
  ## the selection alone so ordinary text selection keeps working.
  if modelLine < 1 or modelLine > doc.lines.len:
    return false
  doc.lines[modelLine - 1].kind == dlkHunkHeader
