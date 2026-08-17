## Headless tests for the unified diff's decoration builder (DR-R4).
##
## DR-R4 (``codetracer-specs/DeepReview/DeepReview-GUI.milestones.org``) turns
## the unified diff into a real Monaco tab.  Its Layer 5c seam is
## ``viewmodel/viewmodels/diff_document.nim``: diff rows in, one document line
## and one decoration out.  Everything the appearance of a diff depends on —
## which lines are added, removed or context, where the `@@` dividers go, which
## `+` / `-` gutter marker a line gets, and what the dual old/new line numbers
## read — is decided there and asserted here, without a browser.
##
## Before DR-R4 none of this was assertable at all: the diff was nested
## ``tdiv`` elements built by ``isonim_vcs_view.renderUnifiedDiff`` and its
## appearance was CSS on those elements, reachable only through Playwright.
##
## Spec:
##   - GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Editor Integration)":
##     "Added lines: green background with `+` gutter marker / Removed lines:
##     red background with `-` gutter marker / Context lines: normal background
##     / Hunk headers (`@@ -N,M +N,M @@`) shown as section dividers".
##   - GUI/Core-Panes/VCS-Panel.md, "Unified Diff View (Shared)": "The diff
##     rendering code does NOT check which mode is active — it simply renders
##     whatever data is provided."
##   - DeepReview-GUI.md §4.1, the diff tab's contents.

import std/[strutils, unittest]

import isonim/core/[signals, computation, owner]
import viewmodels/vcs_vm
import viewmodels/diff_document

proc mixedHunkFile(): VCSDiffFileRow =
  ## One file, one hunk, all three line kinds.
  ##
  ## The hunk starts at old line 40 / new line 40 and carries one context
  ## line, one removal and two additions — the shape
  ## ``test_diff_dual_line_numbers`` names, and enough to classify every kind.
  VCSDiffFileRow(
    fileIndex: 0,
    status: "M",
    path: "src/parser.rs",
    additions: 2,
    deletions: 1,
    hunks: @[
      VCSHunkRow(
        oldStart: 40, oldCount: 2, newStart: 40, newCount: 3,
        lines: @[
          VCSDiffLineRow(lineType: "context", content: "fn parse(input: &str) {",
                         oldLine: 40, newLine: 40),
          VCSDiffLineRow(lineType: "removed", content: "  match parse(input) {",
                         oldLine: 41, newLine: 0),
          VCSDiffLineRow(lineType: "added", content: "  let token = parse(input);",
                         oldLine: 0, newLine: 41),
          VCSDiffLineRow(lineType: "added", content: "  match token {",
                         oldLine: 0, newLine: 42),
        ])
    ])

proc secondFile(): VCSDiffFileRow =
  ## A second file with two hunks, so file ordering and multi-hunk documents
  ## are exercised too.  Its ``fileIndex`` is 2, not 1: the row list omits
  ## files that carry no hunks, so the index a selection pair names is not the
  ## row's position.
  VCSDiffFileRow(
    fileIndex: 2,
    status: "A",
    path: "src/lexer.rs",
    additions: 2,
    deletions: 0,
    hunks: @[
      VCSHunkRow(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
                 lines: @[
                   VCSDiffLineRow(lineType: "added", content: "mod lexer;",
                                  oldLine: 0, newLine: 1)]),
      VCSHunkRow(oldStart: 0, oldCount: 0, newStart: 9, newCount: 1,
                 lines: @[
                   VCSDiffLineRow(lineType: "added", content: "pub fn lex() {}",
                                  oldLine: 0, newLine: 9)]),
    ])

suite "unified diff decoration builder (DR-R4)":

  test "test_diff_decorations_classify_added_removed_context":
    ## Every rendered line gets exactly one decoration, carrying the class its
    ## kind calls for, and the `@@` divider decoration appears only on the
    ## hunk-header line.
    let doc = buildDiffDocument([mixedHunkFile()])
    let decorations = decorationsFor(doc)

    # file header, @@ divider, context, removal, addition, addition.
    check doc.lines.len == 6
    check decorations.len == doc.lines.len

    # One decoration per line, in model-line order, no gaps and no duplicates.
    for i, decoration in decorations:
      check decoration.line == i + 1

    check decorations[0].className == DiffFileHeaderClass
    check decorations[1].className == DiffHunkHeaderClass
    check decorations[2].className == DiffContextClass
    check decorations[3].className == DiffRemovedClass
    check decorations[4].className == DiffAddedClass
    check decorations[5].className == DiffAddedClass

    # The divider is on the `@@` line and nowhere else.
    var hunkHeaderLines: seq[int] = @[]
    for decoration in decorations:
      if DiffHunkHeaderClass in decoration.className:
        hunkHeaderLines.add(decoration.line)
    check hunkHeaderLines == @[2]
    check doc.lines[1].text == "@@ -40,2 +40,3 @@"
    check doc.lines[1].text.startsWith("@@")

    # VCS-Panel.md: "`+` gutter marker" / "`-` gutter marker"; the dividers
    # carry none, they are not content.
    check decorations[0].gutterClassName == ""
    check decorations[1].gutterClassName == ""
    check decorations[2].gutterClassName == DiffGutterContextClass
    check decorations[3].gutterClassName == DiffGutterRemovedClass
    check decorations[4].gutterClassName == DiffGutterAddedClass

    # The model holds the diff text itself, so find / selection / copy operate
    # on the code rather than on decoration markup.
    check documentText(doc).splitLines()[3] == "  match parse(input) {"

  test "a selected hunk adds a class rather than a second decoration":
    ## The hunk editor's selection has to be visible on the Monaco content
    ## (VCS-Panel.md, "Hunk Selection"), but a second whole-line decoration
    ## would fight the first for the line's background.
    let doc = buildDiffDocument([mixedHunkFile(), secondFile()])
    let decorations = decorationsFor(doc, @[(2, 1)])

    check decorations.len == doc.lines.len
    for i, decoration in decorations:
      let line = doc.lines[i]
      let selected = line.fileIndex == 2 and line.hunkIndex == 1
      check (DiffSelectedHunkClass in decoration.className) == selected
      # The kind class survives the selection modifier.
      check decoration.className.startsWith(classFor(line.kind))

  test "test_diff_decorations_are_mode_agnostic":
    ## VCS-Panel.md, "Unified Diff View (Shared)": "The diff rendering code
    ## does NOT check which mode is active — it simply renders whatever data is
    ## provided."
    ##
    ## Driven through ``diffDocumentFor(vm)`` rather than through the row
    ## sequence directly, because that is the entry point the Monaco tab calls:
    ## if a later change makes it consult ``vm.deepReviewMode`` — the obvious
    ## way to "just special-case reviews" — this test fails.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let rows = @[mixedHunkFile(), secondFile()]

      vm.setDeepReviewMode(false)
      vm.setUnifiedDiff(true, rows)
      let gitDoc = diffDocumentFor(vm)
      let gitDecorations = decorationsFor(gitDoc)
      let gitLabels = lineNumberLabels(gitDoc)

      vm.setDeepReviewMode(true)
      let reviewDoc = diffDocumentFor(vm)
      let reviewDecorations = decorationsFor(reviewDoc)
      let reviewLabels = lineNumberLabels(reviewDoc)

      check gitDecorations.len > 0
      check reviewDecorations.len == gitDecorations.len
      for i in 0 ..< gitDecorations.len:
        check reviewDecorations[i].line == gitDecorations[i].line
        check reviewDecorations[i].className == gitDecorations[i].className
        check reviewDecorations[i].gutterClassName ==
          gitDecorations[i].gutterClassName
      check documentText(reviewDoc) == documentText(gitDoc)
      check reviewLabels == gitLabels

      dispose()

  test "test_diff_dual_line_numbers":
    ## The DOM renderer drew two gutter columns
    ## (``deepreview-unified-gutter-old`` / ``-new``), each blank where the
    ## revision has no such line.  Monaco has one gutter, so the pair is
    ## reported per line and padded into a single label — but the *pairing* is
    ## what a reviewer reads, and it must survive the port.
    let doc = buildDiffDocument([mixedHunkFile()])

    # (kind, oldNumber, newNumber) for every emitted line.
    check doc.lines[0].kind == dlkFileHeader
    check (doc.lines[0].oldNumber, doc.lines[0].newNumber) == (0, 0)
    check doc.lines[1].kind == dlkHunkHeader
    check (doc.lines[1].oldNumber, doc.lines[1].newNumber) == (0, 0)

    check (doc.lines[2].oldNumber, doc.lines[2].newNumber) == (40, 40)
    check (doc.lines[3].oldNumber, doc.lines[3].newNumber) == (41, 0)
    check (doc.lines[4].oldNumber, doc.lines[4].newNumber) == (0, 41)
    check (doc.lines[5].oldNumber, doc.lines[5].newNumber) == (0, 42)

    # Blank old number on additions, blank new number on removals.
    check oldNumberText(doc.lines[3]) == "41"
    check newNumberText(doc.lines[3]) == ""
    check oldNumberText(doc.lines[4]) == ""
    check newNumberText(doc.lines[4]) == "41"
    check oldNumberText(doc.lines[5]) == ""
    check newNumberText(doc.lines[5]) == "42"

    # The rendered labels keep both columns aligned and headers unnumbered.
    let labels = lineNumberLabels(doc, width = 2)
    check labels[0] == ""
    check labels[1] == ""
    check labels[2] == "40 40"
    check labels[3] == "41   "
    check labels[4] == "   41"
    check labels[5] == "   42"
    check lineNumberWidth(doc) == 2

  test "a click resolves to the hunk it landed in, and only on a header":
    ## The Monaco host translates a click position through these two procs and
    ## hands the pair to ``VCSVM.selectHunk``; nothing else maps screen
    ## positions to hunks, so this is the whole mapping.
    let doc = buildDiffDocument([mixedHunkFile(), secondFile()])

    # File 0: header(1) @@(2) ctx(3) rm(4) add(5) add(6)
    # File 2: header(7) @@(8) add(9) @@(10) add(11)
    check doc.lines.len == 11
    check isHunkHeaderLine(doc, 2)
    check hunkAtLine(doc, 2) == (0, 0)
    check not isHunkHeaderLine(doc, 1)
    check hunkAtLine(doc, 1) == (-1, -1)   ## the file header owns no hunk
    check hunkAtLine(doc, 5) == (0, 0)     ## a body line still names its hunk
    check isHunkHeaderLine(doc, 8)
    check hunkAtLine(doc, 8) == (2, 0)
    check isHunkHeaderLine(doc, 10)
    check hunkAtLine(doc, 10) == (2, 1)
    check hunkAtLine(doc, 0) == (-1, -1)
    check hunkAtLine(doc, 99) == (-1, -1)
    check not isHunkHeaderLine(doc, 99)

  test "a diff target with no hunks still produces a readable document":
    ## Defensive: a Monaco model cannot be empty and still be an editor, and a
    ## blank buffer reads as "still loading" rather than "no changes".
    let doc = buildDiffDocument([])
    check doc.lines.len == 0
    check decorationsFor(doc).len == 0
    check documentText(doc) == DiffEmptyDocumentText

    # A file row that carries no hunks contributes nothing — not even a
    # header, which would claim the file is part of the changeset.
    let empty = VCSDiffFileRow(fileIndex: 0, status: "M", path: "src/a.rs")
    check buildDiffDocument([empty]).lines.len == 0
