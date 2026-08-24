## Headless tests for the unified diff's document builder (DR-R4, UD-1).
##
## DR-R4 (``codetracer-specs/DeepReview/DeepReview-GUI.milestones.org``) turned
## the unified diff into a real Monaco tab.  UD-1
## (``codetracer-specs/DeepReview/Unified-Diff-Design.milestones.org``) turned
## it into a real Monaco **diff editor**: two models, a real language, and the
## word-level intra-line marking Monaco computes once it owns both sides.
##
## The Layer 5c seam is still ``viewmodel/viewmodels/diff_document.nim``, and
## what it emits is what changed: ``buildDiffPair`` instead of
## ``buildDiffDocument``, a ``DiffPair`` instead of one interleaved document.
## Everything the appearance of a diff depends on — which lines are added,
## removed or context, where the `@@` dividers go, which `+` / `-` gutter
## marker a line gets, what the dual old/new line numbers read, and now which
## *side* each line belongs to and which language the models carry — is decided
## there and asserted here, without a browser.
##
## What this lane can and cannot say
## ---------------------------------
## It can assert what is *handed to* Monaco.  It cannot assert what Monaco then
## does with it: that a tokenizer actually coloured the Rust, and that the
## intra-line marking actually appeared, are DOM facts, and they are asserted
## in ``src/tests/gui/tests/deepreview/deepreview-gui.spec.ts`` ("UD-1: the diff
## tab is a diff editor over two models in the reviewed language" and "UD-1: a
## partially changed line is marked word by word").  The split is deliberate:
## each half is checked where it is observable.
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

proc reviewShapedFile(): VCSDiffFileRow =
  ## The rows ``ui/unified_diff.diffRows`` projects from a *review* dataset.
  ##
  ## The materialized collector writes added and removed ``content`` with the
  ## unified-diff marker still attached
  ## (``db-backend/src/deepreview/unified_diff.rs``: "the sample dataset shows
  ## added/removed lines keeping their marker") and context content without
  ## one, while ``ui/git_cli.parseGitDiffHunks`` strips it for every kind.  A
  ## diff editor owns both sides and diffs them character by character, so a
  ## stray marker is not cosmetic: it differs on every changed line, and the
  ## word-level marking would report *it* as the change.
  VCSDiffFileRow(
    fileIndex: 0,
    status: "M",
    path: "src/main.nr",
    additions: 1,
    deletions: 1,
    hunks: @[VCSHunkRow(
      oldStart: 7, oldCount: 2, newStart: 7, newCount: 2,
      lines: @[
        VCSDiffLineRow(lineType: "removed",
                       content: "-fn scale(index: Field, factor: Field) {",
                       oldLine: 7, newLine: 0),
        VCSDiffLineRow(lineType: "added",
                       content: "+fn scale(index: Field, multiplier: Field) {",
                       oldLine: 0, newLine: 7),
      ])])

suite "unified diff decoration builder (DR-R4)":

  test "test_diff_decorations_classify_added_removed_context":
    ## Every rendered line gets exactly one decoration, carrying the class its
    ## kind calls for, and the `@@` divider decoration appears only on the
    ## hunk-header line.
    ##
    ## UD-1 split the one document in two, so the classification is asserted
    ## per side: the new revision has the additions, the old revision has the
    ## removals, and everything that is neither — the chrome and the context —
    ## is on both, byte-identical, which is what makes Monaco treat it as
    ## unchanged and draw it once.
    let pair = buildDiffPair([mixedHunkFile()])
    let modified = pair.modified
    let original = pair.original
    let modifiedDecorations = decorationsFor(modified)
    let originalDecorations = decorationsFor(original)

    # modified: file header, @@ divider, context, addition, addition.
    check modified.lines.len == 5
    # original: file header, @@ divider, context, removal.
    check original.lines.len == 4
    check modifiedDecorations.len == modified.lines.len
    check originalDecorations.len == original.lines.len

    # One decoration per line, in model-line order, no gaps and no duplicates.
    for i, decoration in modifiedDecorations:
      check decoration.line == i + 1
    for i, decoration in originalDecorations:
      check decoration.line == i + 1

    check modifiedDecorations[0].className == DiffFileHeaderClass
    check modifiedDecorations[1].className == DiffHunkHeaderClass
    check modifiedDecorations[2].className == DiffContextClass
    check modifiedDecorations[3].className == DiffAddedClass
    check modifiedDecorations[4].className == DiffAddedClass

    check originalDecorations[0].className == DiffFileHeaderClass
    check originalDecorations[1].className == DiffHunkHeaderClass
    check originalDecorations[2].className == DiffContextClass
    check originalDecorations[3].className == DiffRemovedClass

    # No addition reaches the old revision and no removal reaches the new one:
    # that is the whole reason there are two models rather than one.
    for line in original.lines:
      check line.kind != dlkAdded
    for line in modified.lines:
      check line.kind != dlkRemoved

    # The divider is on the `@@` line and nowhere else, on both sides.
    var hunkHeaderLines: seq[int] = @[]
    for decoration in modifiedDecorations:
      if DiffHunkHeaderClass in decoration.className:
        hunkHeaderLines.add(decoration.line)
    check hunkHeaderLines == @[2]
    check modified.lines[1].text == "@@ -40,2 +40,3 @@"
    check original.lines[1].text == modified.lines[1].text
    check modified.lines[1].text.startsWith("@@")

    # VCS-Panel.md: "`+` gutter marker" / "`-` gutter marker"; the dividers
    # carry none, they are not content.
    check modifiedDecorations[0].gutterClassName == ""
    check modifiedDecorations[1].gutterClassName == ""
    check modifiedDecorations[2].gutterClassName == DiffGutterContextClass
    check modifiedDecorations[3].gutterClassName == DiffGutterAddedClass
    check originalDecorations[3].gutterClassName == DiffGutterRemovedClass

    # The models hold the code itself, so find / selection / copy operate on
    # the code rather than on decoration markup.
    check documentText(original).splitLines()[3] == "  match parse(input) {"
    check documentText(modified).splitLines()[3] == "  let token = parse(input);"

  test "the two models carry the file's own text, split by revision":
    ## UD-1's first structural requirement, and the one a review dataset used
    ## to break: the marker its collector attaches must not reach the model.
    let pair = buildDiffPair([reviewShapedFile()])
    let modifiedLines = documentText(pair.modified).splitLines()
    let originalLines = documentText(pair.original).splitLines()

    check modifiedLines[^1] == "fn scale(index: Field, multiplier: Field) {"
    check originalLines[^1] == "fn scale(index: Field, factor: Field) {"
    for line in modifiedLines & originalLines:
      check not line.startsWith("+f")
      check not line.startsWith("-f")

    # The two texts differ in exactly one word, which is the property the
    # editor's word-level marking then reports.  A marker left on either side
    # would make the whole line differ instead.
    check modifiedLines[^1].replace("multiplier", "factor") == originalLines[^1]

  test "rows that never carried a marker are not stripped twice":
    ## ``parseGitDiffHunks`` already removes the marker, so the git lane hands
    ## over bare text.  Stripping it again would eat the first character of
    ## every changed line — and a line whose own first character is `+` (a
    ## diff of a diff, a Markdown list) is exactly where that shows.
    let file = VCSDiffFileRow(
      fileIndex: 0, status: "M", path: "notes.md", additions: 1, deletions: 1,
      hunks: @[VCSHunkRow(
        oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
        lines: @[
          VCSDiffLineRow(lineType: "removed", content: "- old bullet",
                         oldLine: 1, newLine: 0),
          VCSDiffLineRow(lineType: "added", content: "* new bullet",
                         oldLine: 0, newLine: 1)])])
    let pair = buildDiffPair([file])
    check documentText(pair.modified).splitLines()[^1] == "* new bullet"
    # `- old bullet` DOES lose its leading `-`: with the two producers
    # disagreeing there is no way to tell that dash from a removal marker, and
    # `ct/agent_cli.unifiedDiffLine` already accepts the same ambiguity in the
    # other direction.  Recorded here so the trade-off is visible rather than
    # discovered.
    check documentText(pair.original).splitLines()[^1] == " old bullet"

  test "the language is resolved from the file path":
    ## UD-1's second deliverable.  The old surface hard-coded ``plaintext``;
    ## the ids below are the ones the vendored Monaco 0.54.0 registers.
    check diffLanguageForPath("src/parser.rs") == "rust"
    check diffLanguageForPath("tools/report.py") == "python"
    check diffLanguageForPath("src/main.nr") == "rust"   ## Noir → Rust
    check diffLanguageForPath("src/frontend/ui/editor.nim") == "nim"
    check diffLanguageForPath("Deep.Dir/app.ts") == "typescript"
    check diffLanguageForPath("a/b/c.PY") == "python"    ## case-insensitive

    # No extension, a dot only in a directory, a dotfile and a trailing dot all
    # resolve to plaintext rather than to a guess: a wrongly tokenized file
    # looks authoritative, an untokenized one does not.
    check diffLanguageForPath("Makefile") == DiffPlainLanguage
    check diffLanguageForPath("v1.2/Makefile") == DiffPlainLanguage
    check diffLanguageForPath(".gitignore") == DiffPlainLanguage
    check diffLanguageForPath("weird.") == DiffPlainLanguage
    check diffLanguageForPath("") == DiffPlainLanguage
    check diffLanguageForPath("x.unheardof") == DiffPlainLanguage

    # A tab is normally one file (§4.1), so its language is that file's.
    check buildDiffPair([mixedHunkFile()]).language == "rust"
    # A git target can name several.  They agree here...
    check buildDiffPair([mixedHunkFile(), secondFile()]).language == "rust"
    # ... and where they do not, neither is tokenized, because tokenizing a
    # Python file as Rust is worse than tokenizing neither.
    var python = secondFile()
    python.path = "tools/report.py"
    check buildDiffPair([mixedHunkFile(), python]).language == DiffPlainLanguage
    # A file with no hunks does not vote: it contributes no lines either.
    check buildDiffPair([]).language == DiffPlainLanguage

  test "a selected hunk adds a class rather than a second decoration":
    ## The hunk editor's selection has to be visible on the Monaco content
    ## (VCS-Panel.md, "Hunk Selection"), but a second whole-line decoration
    ## would fight the first for the line's background.
    ##
    ## Asserted on both sides: a selected hunk whose removals were left
    ## unhighlighted would read as a partial selection.
    let pair = buildDiffPair([mixedHunkFile(), secondFile()])
    for doc in [pair.modified, pair.original]:
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
    ## Driven through ``diffPairFor(vm)`` rather than through the row
    ## sequence directly, because that is the entry point the Monaco tab calls:
    ## if a later change makes it consult ``vm.deepReviewMode`` — the obvious
    ## way to "just special-case reviews" — this test fails.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let rows = @[mixedHunkFile(), secondFile()]

      vm.setDeepReviewMode(false)
      vm.setUnifiedDiff(true, rows)
      let gitPair = diffPairFor(vm)

      vm.setDeepReviewMode(true)
      let reviewPair = diffPairFor(vm)

      check reviewPair.language == gitPair.language
      for (side, gitDoc, reviewDoc) in [
          (dsModified, gitPair.modified, reviewPair.modified),
          (dsOriginal, gitPair.original, reviewPair.original)]:
        let gitDecorations = decorationsFor(gitDoc)
        let reviewDecorations = decorationsFor(reviewDoc)
        check gitDecorations.len > 0
        check reviewDecorations.len == gitDecorations.len
        for i in 0 ..< gitDecorations.len:
          check reviewDecorations[i].line == gitDecorations[i].line
          check reviewDecorations[i].className == gitDecorations[i].className
          check reviewDecorations[i].gutterClassName ==
            gitDecorations[i].gutterClassName
        check documentText(reviewDoc) == documentText(gitDoc)
        check lineNumberLabels(reviewDoc, side) == lineNumberLabels(gitDoc, side)

      dispose()

  test "test_diff_dual_line_numbers":
    ## The DOM renderer drew two gutter columns
    ## (``deepreview-unified-gutter-old`` / ``-new``), each blank where the
    ## revision has no such line.  DR-R4 had one model and therefore one
    ## gutter, so it padded the pair into a single label; UD-1 has two editors
    ## and the two columns are two columns again, one per side.  Either way
    ## the *pairing* is what a reviewer reads, and it must survive both ports:
    ## a context line carries both numbers, an addition only a new one and a
    ## removal only an old one.
    let pair = buildDiffPair([mixedHunkFile()])
    let modified = pair.modified
    let original = pair.original

    # (kind, oldNumber, newNumber) for every emitted line.
    check modified.lines[0].kind == dlkFileHeader
    check (modified.lines[0].oldNumber, modified.lines[0].newNumber) == (0, 0)
    check modified.lines[1].kind == dlkHunkHeader
    check (modified.lines[1].oldNumber, modified.lines[1].newNumber) == (0, 0)

    check (modified.lines[2].oldNumber, modified.lines[2].newNumber) == (40, 40)
    check (modified.lines[3].oldNumber, modified.lines[3].newNumber) == (0, 41)
    check (modified.lines[4].oldNumber, modified.lines[4].newNumber) == (0, 42)
    check (original.lines[3].oldNumber, original.lines[3].newNumber) == (41, 0)

    # Blank old number on additions, blank new number on removals.
    check oldNumberText(original.lines[3]) == "41"
    check newNumberText(original.lines[3]) == ""
    check oldNumberText(modified.lines[3]) == ""
    check newNumberText(modified.lines[3]) == "41"
    check oldNumberText(modified.lines[4]) == ""
    check newNumberText(modified.lines[4]) == "42"

    # The rendered labels keep the columns aligned and the chrome unnumbered,
    # and each carries the `+` / `-` marker VCS-Panel.md requires — in the
    # label, since UD-1, because Monaco's line-decorations lane does not fit
    # beside the numbers in an inline diff's original editor.
    # The modified editor's margin carries the new numbers...
    let newLabels = lineNumberLabels(modified, dsModified, width = 2)
    check newLabels[0] == ""     ## file header — chrome, neither revision
    check newLabels[1] == ""     ## `@@` divider — likewise
    check newLabels[2] == " 40"  ## context: a blank marker, so digits align
    check newLabels[3] == "+41"
    check newLabels[4] == "+42"
    # ... and the original editor's the old ones, in the column beside it, so
    # a context line still reads as a pair and a deleted line still carries the
    # number it had before it went.
    let oldLabels = lineNumberLabels(original, dsOriginal, width = 2)
    check oldLabels[0] == ""
    check oldLabels[1] == ""
    check oldLabels[2] == " 40"
    check oldLabels[3] == "-41"
    # A line that exists on only one side has no number in the other column,
    # but keeps its marker so the two columns stay in step.
    check lineNumberLabels(original, dsModified, width = 2)[3] == "-  "
    check lineNumberLabels(modified, dsOriginal, width = 2)[3] == "+  "
    check lineNumberWidth(modified) == 2
    check lineNumberWidth(original) == 2
    # The option Monaco is given: the number column plus the marker's
    # character.  Monaco sizes the inline diff's original editor from exactly
    # this, so it is what decides whether the old numbers are visible.
    check lineNumberColumnWidth(pair) == 3

    # The marker's colour is a per-LINE class on the gutter label, not a
    # per-side one: a context line of the new revision must not read as an
    # addition.
    let modifiedDecorations = decorationsFor(modified)
    check modifiedDecorations[2].lineNumberClassName == ""
    check modifiedDecorations[3].lineNumberClassName == DiffLineNumberAddedClass
    check decorationsFor(original)[3].lineNumberClassName ==
      DiffLineNumberRemovedClass

  test "a click resolves to the hunk it landed in, and only on a header":
    ## The Monaco host translates a click position through these two procs and
    ## hands the pair to ``VCSVM.selectHunk``; nothing else maps screen
    ## positions to hunks, so this is the whole mapping.
    ##
    ## Against the MODIFIED document, because that is the editor the unified
    ## view renders into and the one the click handler is attached to.
    let doc = buildDiffPair([mixedHunkFile(), secondFile()]).modified

    # File 0: header(1) @@(2) ctx(3) add(4) add(5)
    # File 2: header(6) @@(7) add(8) @@(9) add(10)
    check doc.lines.len == 10
    check isHunkHeaderLine(doc, 2)
    check hunkAtLine(doc, 2) == (0, 0)
    check not isHunkHeaderLine(doc, 1)
    check hunkAtLine(doc, 1) == (-1, -1)   ## the file header owns no hunk
    check hunkAtLine(doc, 5) == (0, 0)     ## a body line still names its hunk
    check isHunkHeaderLine(doc, 7)
    check hunkAtLine(doc, 7) == (2, 0)
    check isHunkHeaderLine(doc, 9)
    check hunkAtLine(doc, 9) == (2, 1)
    check hunkAtLine(doc, 0) == (-1, -1)
    check hunkAtLine(doc, 99) == (-1, -1)
    check not isHunkHeaderLine(doc, 99)

  test "a diff target with no hunks still produces a readable document":
    ## Defensive: a Monaco model cannot be empty and still be an editor, and a
    ## blank buffer reads as "still loading" rather than "no changes".  Both
    ## sides say the same thing, so a diff editor over them shows one line of
    ## unchanged text rather than an empty pane or a spurious deletion.
    let pair = buildDiffPair([])
    check pair.modified.lines.len == 0
    check pair.original.lines.len == 0
    check decorationsFor(pair.modified).len == 0
    check documentText(pair.modified) == DiffEmptyDocumentText
    check documentText(pair.original) == DiffEmptyDocumentText

    # A file row that carries no hunks contributes nothing — not even a
    # header, which would claim the file is part of the changeset.
    let empty = VCSDiffFileRow(fileIndex: 0, status: "M", path: "src/a.rs")
    check buildDiffPair([empty]).modified.lines.len == 0
    check buildDiffPair([empty]).original.lines.len == 0

suite "the shapes the old synthetic document flattened (UD-1)":
  ## One interleaved document rendered an addition, a deletion and a file with
  ## no source text as the same thing: a run of coloured lines.  A diff editor
  ## does not — an added file has an *empty* old side, a deleted file an empty
  ## new side — so these are the shapes where the port can break.

  proc addedFile(): VCSDiffFileRow =
    ## A file that did not exist before: every line is an addition, and
    ## `sourceLines` carries the new file's whole text.
    VCSDiffFileRow(
      fileIndex: 1, status: "A", path: "src/utils.rs",
      additions: 2, deletions: 0,
      sourceLines: @["pub fn helper() {}", "", "// trailing"],
      hunks: @[VCSHunkRow(
        oldStart: 0, oldCount: 0, newStart: 1, newCount: 2,
        lines: @[
          VCSDiffLineRow(lineType: "added", content: "pub fn helper() {}",
                         oldLine: 0, newLine: 1),
          VCSDiffLineRow(lineType: "added", content: "", oldLine: 0, newLine: 2),
        ])])

  proc deletedFile(): VCSDiffFileRow =
    ## A file that no longer exists: every line is a removal, and there is no
    ## new-side text at all — `git show <new>:<path>` has nothing to return.
    VCSDiffFileRow(
      fileIndex: 2, status: "D", path: "src/config.rs",
      additions: 0, deletions: 2,
      hunks: @[VCSHunkRow(
        oldStart: 1, oldCount: 2, newStart: 0, newCount: 0,
        lines: @[
          VCSDiffLineRow(lineType: "removed", content: "pub const N: u64 = 30;",
                         oldLine: 1, newLine: 0),
          VCSDiffLineRow(lineType: "removed", content: "pub struct Config {}",
                         oldLine: 2, newLine: 0),
        ])])

  test "an added file has content on the new side and chrome on the old one":
    let pair = buildDiffPair([addedFile()])
    # The old side is not empty — it carries the header and the divider, which
    # anchor the comparison — but it carries no code, so Monaco reports the
    # whole file as an insertion.
    for line in pair.original.lines:
      check line.kind in {dlkFileHeader, dlkHunkHeader,
                          dlkExpandAbove, dlkExpandBelow}
    check documentText(pair.original).splitLines()[0] == "A  src/utils.rs  +2 -0"
    var added = 0
    for line in pair.modified.lines:
      if line.kind == dlkAdded: added += 1
    check added == 2
    # An added line with empty text is still a line of the new file, not a
    # dropped one: dropping it would misnumber everything after it.
    check documentText(pair.modified).splitLines().len ==
      pair.modified.lines.len

  test "a deleted file has content on the old side and chrome on the new one":
    let pair = buildDiffPair([deletedFile()])
    for line in pair.modified.lines:
      check line.kind in {dlkFileHeader, dlkHunkHeader,
                          dlkExpandAbove, dlkExpandBelow}
    var removed = 0
    for line in pair.original.lines:
      if line.kind == dlkRemoved: removed += 1
    check removed == 2
    check documentText(pair.modified).splitLines()[0] == "D  src/config.rs  +0 -2"
    # A deletion has no new-side text to expand into, so no expansion control
    # is offered — pressing one could only reveal nothing.
    for line in pair.modified.lines & pair.original.lines:
      check line.kind notin {dlkExpandAbove, dlkExpandBelow}

  test "a file the dataset carries no source text for still renders its hunks":
    ## `DeepReviewFileData.sourceContent` can be absent (an unreadable file, an
    ## older collector), and the tab must then show the diff it *does* have
    ## rather than nothing.  Only expansion is unavailable, because expansion
    ## is the one thing that needs the text.
    var file = mixedHunkFile()
    file.sourceLines = @[]
    let pair = buildDiffPair([file])
    check pair.modified.lines.len == 5
    check pair.original.lines.len == 4
    for line in pair.modified.lines & pair.original.lines:
      check line.kind notin {dlkExpandAbove, dlkExpandBelow}
    check documentText(pair.modified).splitLines()[3] ==
      "  let token = parse(input);"

  test "an added, a deleted and a modified file share one tab without merging":
    ## A git "Working Tree" target names several files at once.  Each file's
    ## header is present on BOTH sides and is byte-identical, so it anchors the
    ## comparison: without it Monaco could match one file's context lines
    ## against another's and report a move across the file boundary.
    let pair = buildDiffPair([mixedHunkFile(), addedFile(), deletedFile()])
    var headersModified: seq[string] = @[]
    var headersOriginal: seq[string] = @[]
    for line in pair.modified.lines:
      if line.kind == dlkFileHeader:
        headersModified.add(line.text)
    for line in pair.original.lines:
      if line.kind == dlkFileHeader:
        headersOriginal.add(line.text)
    check headersModified == @["M  src/parser.rs  +2 -1",
                               "A  src/utils.rs  +2 -0",
                               "D  src/config.rs  +0 -2"]
    check headersOriginal == headersModified
    # Every file keeps its own identity, so a click still resolves to the right
    # hunk of the right file.
    check hunkAtLine(pair.modified, 1) == (-1, -1)
    check isHunkHeaderLine(pair.modified, 2)
    check hunkAtLine(pair.modified, 2) == (0, 0)
