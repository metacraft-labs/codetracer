## The unified diff as an editor *document*: pure text + pure decorations.
##
## DR-R4 (``codetracer-specs/DeepReview/DeepReview-GUI.milestones.org``) turned
## the unified diff into a real Monaco tab; UD-1
## (``codetracer-specs/DeepReview/Unified-Diff-Design.milestones.org``) turned
## it into a real Monaco *diff editor*.  This module is the seam that makes
## both testable without a browser: diff rows in, TWO documents
## (``DiffPair``) and one decoration per rendered line out, plus the Monaco
## language id the models are created with.  Nothing here touches Monaco, the
## DOM or any signal — the host (``ui/unified_diff.nim``) only turns
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

type
  DiffLineKind* = enum
    ## What one line of the assembled document is.
    dlkHunkHeader   ## "@@ -N,M +N,M @@" — the section divider
    dlkAdded        ## a line present only in the new revision
    dlkRemoved      ## a line present only in the old revision
    dlkContext      ## a line present in both

  DiffDocumentLine* = object
    ## One line of the Monaco model, plus everything the gutters and the
    ## decorations need to describe it.
    kind*: DiffLineKind
    text*: string      ## exactly what the model holds for this line
    oldNumber*: int    ## line number in the old revision; 0 = none
    newNumber*: int    ## line number in the new revision; 0 = none
    fileIndex*: int    ## ``VCSDiffFileRow.fileIndex`` this line belongs to
    hunkIndex*: int
      ## Hunk within that file, or -1 for a line the diff itself did not carry
      ## — everything outside a `@@` range, which since UD-2 is most of the
      ## document.  It is what hunk selection is keyed on, so a line outside
      ## every hunk is deliberately unselectable.

  DiffSide* = enum
    ## Which revision of the file a document describes.
    dsOriginal  ## the old revision — the diff editor's `original` model
    dsModified  ## the new revision — the diff editor's `modified` model

  DiffDocument* = object
    lines*: seq[DiffDocumentLine]

  DiffPair* = object
    ## The two documents a Monaco **diff editor** compares (UD-1).
    ##
    ## Before UD-1 there was one document, interleaving both revisions, and it
    ## was created with ``language: "plaintext"`` because no tokenizer
    ## describes such a thing.  Every weakness of the old surface followed from
    ## that: no syntax highlighting, because no tokenizer ran; no word-level
    ## marking, because a single document has no *before* and *after* to
    ## compare.
    ##
    ## So the document is split in two.  ``original`` holds the old revision's
    ## lines, ``modified`` the new revision's, and Monaco is given both and
    ## asked to diff them itself — which is also how the intra-line marking
    ## arrives: it is computed by the editor, not written by us.
    ##
    ## Since UD-2 each document is the **whole file** on its side of the diff,
    ## because a model is tokenized from its own line 1 and a window that
    ## begins at the first hunk tokenizes the rest of the file from whatever
    ## state that line happens to be in.  Which of those lines a reader sees is
    ## Monaco's ``hideUnchangedRegions``, not a slice we compute.
    ##
    ## The one piece of chrome still inside the models is the ``@@`` divider
    ## DeepReview-GUI.md §4.1 requires.  It is byte-identical on both sides, so
    ## Monaco classifies it as unchanged and draws it once, and it always abuts
    ## a change, so it is never inside the part of a run that collapses.  The
    ## file header moved OUT (``files`` below): it sits at line 1, which is
    ## exactly what a collapsed run at the top of a file hides.
    ##
    ## ``modified`` is a ``DiffDocument`` and not a new shape because it is the
    ## document the Omniscience overlay maps onto: flow, values and the two
    ## steppers are all keyed on new-side source lines
    ## (``review_flow_overlay.nim``), and the new side *is* ``modified``.
    original*: DiffDocument
    modified*: DiffDocument
    language*: string
      ## The Monaco language id both models are created with — resolved from
      ## the file path, so the reviewed language is tokenized.
    unchangedRuns*: seq[DiffUnchangedRun]
      ## Every maximal run of lines the two documents share, in order (UD-2).
      ##
      ## It falls out of the assembly for free — a run is exactly a maximal
      ## sequence of ``bothSides`` emissions — and it is what
      ## ``collapsedRegionsFor`` turns into the regions Monaco collapses.  Kept
      ## on the pair rather than recomputed by comparing the two documents,
      ## because "these two lines are the same line" is a fact the builder
      ## knows and a text comparison would only guess at.
    files*: seq[DiffFileEntry]
      ## One entry per file the document actually renders, in document order.
      ## The tab's DOM chrome draws the file headers from this (§4.1, "A file
      ## header with path and diff metadata"), which is where they live since
      ## UD-2 — see ``buildDiffPair``.

  DiffUnchangedRun* = object
    ## A run of lines present, byte-identical, in both documents.
    originalStart*: int   ## 1-based line in ``DiffPair.original``
    modifiedStart*: int   ## 1-based line in ``DiffPair.modified``
    length*: int

  DiffFileEntry* = object
    ## A file the diff tab shows, and the header §4.1 requires for it.
    ##
    ## The parts are carried separately as well as pre-joined so the DOM header
    ## can style the status, the path and the counts differently — a single
    ## string could only be one of them — while ``headerText`` stays the exact
    ## line the pre-UD-2 model carried, which is what the suites assert on.
    fileIndex*: int
    path*: string
    status*: string
    additions*: int
    deletions*: int
    headerText*: string

  DiffCollapsedRegion* = object
    ## A stretch of unchanged lines a fresh diff editor hides behind an
    ## expansion boundary (UD-2).
    ##
    ## The fields are the ones Monaco's own ``UnchangedRegion`` carries, and
    ## the arithmetic in ``collapsedRegionsFor`` is a transcription of its
    ## ``fromDiffs``, so this is a *prediction of the editor's behaviour*
    ## rather than a second implementation of it.  What it is for: asserting
    ## the file-edge and hunk-adjacency cases without a browser, which is where
    ## off-by-one bugs live.
    originalStart*: int
    modifiedStart*: int
    lineCount*: int

  DiffDecoration* = object
    ## One Monaco whole-line decoration.
    line*: int             ## 1-based model line number
    className*: string     ## whole-line class (background / colour)
    gutterClassName*: string
      ## ``linesDecorationsClassName`` — the classification of the line, in
      ## the margin's decorations lane.  Since UD-1 the visible `+` / `-`
      ## marker is in the gutter *label* instead (``lineNumberLabels``); this
      ## remains the seam the GUI suites assert the added / removed / context
      ## decision on.
    lineNumberClassName*: string
      ## ``IModelDecorationOptions.lineNumberClassName`` — colours THIS line's
      ## gutter label, which is where the marker now lives.
    marginClassName*: string
      ## ``IModelDecorationOptions.marginClassName`` — paints the whole MARGIN
      ## of this line, numbers column included, rather than only the content
      ## area ``className`` reaches.
      ##
      ## Only the `@@` divider asks for it, and it asks because of the band it
      ## sits next to.  A collapsed region's band is a view zone and spans the
      ## editor from its left edge; a whole-line decoration starts where the
      ## code does.  Measured on the shipped build, the two adjacent bands
      ## therefore began 29px apart — "the collapsed band's left edge (x≈30)
      ## does not line up with the hunk divider's (x≈62)", and, from another
      ## reviewer, "band left edge starts ~30px from the pane edge while the
      ## gutter/code column starts ~60px … three different left edges in four
      ## consecutive rows".  A divider that is a separator should be full
      ## bleed, which is also what three reviewers asked for in their own
      ## words ("unify the `@@` divider with the hidden-lines band: full-bleed,
      ## ruled, same fill").

const
  DiffLineBaseClass* = "ct-diff-line"
  DiffHunkHeaderClass* = "ct-diff-line ct-diff-line-hunk-header"
  DiffHunkHeaderMarginClass* = "ct-diff-line-hunk-header"
    ## The same paint, applied to the divider's MARGIN so the band is full
    ## bleed and shares its left edge with a collapsed region's band.  Only
    ## the kind class, without ``ct-diff-line``: that one is classification the
    ## GUI suites read off the content decoration, and emitting it twice per
    ## line would make "one decoration class per line" ambiguous.
  DiffAddedClass* = "ct-diff-line ct-diff-line-added"
  DiffRemovedClass* = "ct-diff-line ct-diff-line-removed"
  DiffContextClass* = "ct-diff-line ct-diff-line-context"
  ## Applied *in addition* to the kind class on every line of a selected hunk,
  ## so the hunk editor's selection is visible on the Monaco content
  ## (VCS-Panel.md, "Hunk Selection").
  DiffSelectedHunkClass* = "ct-diff-hunk-selected"

  DiffGutterAddedClass* = "ct-diff-gutter ct-diff-gutter-added"
  DiffGutterRemovedClass* = "ct-diff-gutter ct-diff-gutter-removed"
  DiffGutterContextClass* = "ct-diff-gutter ct-diff-gutter-context"

  ## Applied to the line's *gutter label* rather than to the line-decorations
  ## lane (Monaco's ``IModelDecorationOptions.lineNumberClassName``), because
  ## UD-1 moved the `+` / `-` marker into the label — see
  ## ``lineNumberLabels``.  These are what colour it, and they have to be per
  ## line rather than per side: every context line of the new revision would
  ## otherwise read as an addition.
  DiffLineNumberAddedClass* = "ct-diff-linenum-added"
  DiffLineNumberRemovedClass* = "ct-diff-linenum-removed"

  ## The wash a row-below value band takes from the line it annotates (UD-3's
  ## placement; see ``ui/unified_diff.applyFlowValueBands``).  A band is a view
  ## zone, so the diff editor paints nothing behind it and it would otherwise
  ## cut a block of added lines in half with a strip of editor surface.
  ReviewValueBandAddedClass* = "review-flow-band-added"
  ReviewValueBandRemovedClass* = "review-flow-band-removed"
  ReviewValueBandContextClass* = "review-flow-band-context"
    ## An unchanged line's band carries no wash — there is no block for it to
    ## belong to — but it still gets a class, so the three cases are one
    ## vocabulary and the caller never has to decide whether to add nothing.

  DiffEmptyDocumentText* = "No changes to show."
    ## The model text of a diff tab whose target produced no hunks.  A Monaco
    ## model cannot be empty and still be an editor, and a blank buffer would
    ## read as "still loading".

  DiffContextLineCount* = 3
    ## Unchanged lines Monaco keeps visible at each end of a collapsed region
    ## that abuts a change — its ``hideUnchangedRegions.contextLineCount``, and
    ## the value ``collapsedRegionsFor`` predicts against.
    ##
    ## Three, which is Monaco's own default and also git's default context, so
    ## the lines a reviewer sees around a hunk are the lines the patch carries.

  DiffMinimumLineCount* = 3
    ## How many lines must be left over, after the context above is taken off
    ## both ends, before a run is worth collapsing at all — Monaco's
    ## ``hideUnchangedRegions.minimumLineCount``.
    ##
    ## It is what decides the *adjacency* case: two hunks separated by less
    ## than ``2 * DiffContextLineCount + DiffMinimumLineCount`` lines are shown
    ## whole, with no boundary between them, so a reader is never offered a
    ## gesture that would reveal two lines.

const
  DiffPlainLanguage* = "plaintext"
    ## What a file whose language Monaco cannot tokenize is opened as.
    ##
    ## Monaco's own fallback for an id it does not know is to tokenize nothing,
    ## which looks identical — but naming the fallback explicitly is what lets
    ## ``diffLanguageForPath`` be asserted on, and what stops an unregistered
    ## id (see below) from being mistaken for a working one.

  DiffLanguageByExtension*: seq[(string, string)] = @[
    # ---- the ids below are exactly the ones the vendored Monaco registers ---
    #
    # monaco-editor 0.54.0 (`node_modules/monaco-editor`, vendored at
    # `src/public/third_party/monaco-editor/min`) registers 89 language ids in
    # `vs/basic-languages/monaco.contribution.js`, plus `json`, `css`, `html`
    # and `typescript` from the language-service contributions, plus `nim`,
    # which CodeTracer registers itself in
    # `src/frontend/languages/nimLanguage.js`.  Anything else is silently not
    # tokenized, so every value here was checked against that list rather than
    # guessed.
    #
    # This is deliberately NOT `common_lang.toCLang`, which `ui/editor.nim`
    # passes to Monaco today: that function answers "what is this language
    # called", and its answers include `assembly`, `noir`, `c++`, `crystal`,
    # `ada`, `fortran`, `move`, `cairo` and `unknown` — none of which Monaco
    # has ever registered, so an editor opened on those files has been getting
    # no highlighting at all.  See `.agents/codebase-insights.txt`.
    ("c", "c"), ("h", "c"),
    ("cpp", "cpp"), ("cxx", "cpp"), ("cc", "cpp"), ("hpp", "cpp"),
    ("hxx", "cpp"), ("hh", "cpp"), ("ipp", "cpp"),
    ("cs", "csharp"),
    ("rs", "rust"),
    # Noir has no Monaco tokenizer.  Rust is what `ui/editor.nim` already
    # substitutes for it ("if lang == LangNoir: lang = LangRust"), and the two
    # share `fn`, `let`, `mut`, `struct`, `impl`, `//` and the literal forms,
    # so the substitution is a good approximation rather than a shrug.
    ("nr", "rust"),
    ("nim", "nim"), ("nims", "nim"), ("nimble", "nim"),
    ("go", "go"),
    ("py", "python"), ("pyi", "python"),
    ("rb", "ruby"), ("gemspec", "ruby"),
    ("js", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"),
    ("jsx", "javascript"),
    ("ts", "typescript"), ("tsx", "typescript"), ("mts", "typescript"),
    ("cts", "typescript"),
    ("java", "java"),
    ("kt", "kotlin"), ("kts", "kotlin"),
    ("scala", "scala"), ("sc", "scala"),
    ("swift", "swift"),
    ("dart", "dart"),
    ("jl", "julia"),
    ("lua", "lua"),
    ("php", "php"),
    ("ex", "elixir"), ("exs", "elixir"),
    ("pl", "perl"), ("pm", "perl"),
    ("r", "r"),
    ("sol", "sol"),
    ("sh", "shell"), ("bash", "shell"), ("zsh", "shell"),
    ("ps1", "powershell"),
    ("pas", "pascal"), ("pp", "pascal"),
    ("sv", "systemverilog"), ("svh", "systemverilog"),
    ("v", "verilog"), ("vh", "verilog"),
    ("vb", "vb"),
    ("tcl", "tcl"),
    ("m", "objective-c"),
    ("clj", "clojure"), ("cljs", "clojure"),
    ("fs", "fsharp"), ("fsx", "fsharp"),
    ("proto", "proto"),
    ("graphql", "graphql"), ("gql", "graphql"),
    ("hcl", "hcl"), ("tf", "hcl"),
    ("sql", "sql"),
    ("json", "json"),
    ("yaml", "yaml"), ("yml", "yaml"),
    ("xml", "xml"),
    ("html", "html"), ("htm", "html"),
    ("css", "css"), ("scss", "scss"), ("less", "less"),
    ("md", "markdown"), ("markdown", "markdown"),
    ("ini", "ini"), ("toml", "ini"), ("cfg", "ini"),
    ("bat", "bat"), ("cmd", "bat"),
    ("dockerfile", "dockerfile"),
    ("st", "st"),
    ("rst", "restructuredtext"),
  ]

proc diffFileExtension*(path: string): string {.noSideEffect.} =
  ## The lowercased extension of ``path``, without the dot, or "".
  ##
  ## Hand-rolled rather than ``os.splitFile`` so this module stays free of
  ## ``std/os``: it is compiled to JavaScript for the renderer as well as
  ## natively for the ViewModel suites, and the JS backend's ``os`` is a
  ## partial emulation.  A dot in a *directory* name must not be read as the
  ## file's extension, hence the separator scan.
  var lastDot = -1
  var lastSep = -1
  for i, c in path:
    if c == '.':
      lastDot = i
    elif c == '/' or c == '\\':
      lastSep = i
      lastDot = -1
  if lastDot <= lastSep + 1 or lastDot == path.high:
    # No dot after the last separator, a leading dot (`.gitignore` is not an
    # extension of nothing), or a trailing dot.
    return ""
  path[lastDot + 1 .. ^1].toLowerAscii

proc diffLanguageForPath*(path: string): string {.noSideEffect.} =
  ## The Monaco language id a diff tab on ``path`` opens its models with.
  ##
  ## UD-1's second deliverable: "the language resolved from the file so the
  ## reviewed language is tokenized".  The old surface hard-coded
  ## ``plaintext``, and this is what replaces that constant.
  ##
  ## A path with no usable extension resolves to ``plaintext`` rather than to a
  ## guess: a wrongly tokenized file is worse than an untokenized one, because
  ## it looks authoritative.
  let extension = diffFileExtension(path)
  if extension.len == 0:
    return DiffPlainLanguage
  for entry in DiffLanguageByExtension:
    if entry[0] == extension:
      return entry[1]
  DiffPlainLanguage

proc diffLanguageForFiles*(files: openArray[VCSDiffFileRow]): string
    {.noSideEffect.} =
  ## The language a whole diff target is tokenized as.
  ##
  ## A review's diff tab shows exactly one file — DeepReview-GUI.md §4.1,
  ## "Each diff tab shows a single file" — so this is normally that file's
  ## language.  A *git* target can name several ("Working Tree"), and there the
  ## honest answer is only a language if they agree: tokenizing a Python file
  ## as Rust because it shares a tab with one would be worse than tokenizing
  ## neither.
  result = ""
  for file in files:
    if file.hunks.len == 0:
      continue
    let language = diffLanguageForPath(file.path)
    if result.len == 0:
      result = language
    elif result != language:
      return DiffPlainLanguage
  if result.len == 0:
    result = DiffPlainLanguage

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

proc buildDiffPair*(files: openArray[VCSDiffFileRow]): DiffPair =
  ## Assemble the two documents a diff tab's Monaco **diff editor** compares.
  ##
  ## Since UD-2 each document is the **file itself** — every line of that
  ## revision, in order — with the `@@` dividers §4.1 requires interleaved at
  ## the hunk boundaries.  Files with no hunks are skipped: they have nothing
  ## to show, and rendering one would claim it was part of the changeset the
  ## target named.
  ##
  ## Why the whole file rather than a window around each hunk
  ## --------------------------------------------------------
  ## A Monaco model is tokenized from **its own line 1**.  DR-R5's document was
  ## a window that began at the first hunk, so a hunk starting inside a block
  ## comment or a multi-line string was tokenized as if the file began there —
  ## measured on ``tools/report.py``, whose first hunk starts on line 4 inside
  ## the module docstring, which made the whole rest of the file tokenize as
  ## one string while the English prose in the docstring came back as Python
  ## keywords (Unified-Diff-Design.milestones.org, UD-1 ``:blockers:``).
  ## Feeding the tokenizer the file from its first line is the fix, and it is
  ## the only one: nothing about a window can be adjusted to make line 4 behave
  ## like line 4.
  ##
  ## Which of those lines a reader *sees* is then Monaco's
  ## ``hideUnchangedRegions``, which collapses the runs far from any change and
  ## puts a draggable boundary at each end of them.  That is the single notion
  ## of "the window" this tab has; DR-R5's per-hunk slice was removed rather
  ## than kept alongside it.
  ##
  ## Where each line goes
  ## --------------------
  ##
  ## | line                          | original | modified |
  ## |-------------------------------+----------+----------|
  ## | ``@@`` divider                | yes      | yes      |
  ## | unchanged (in or out of hunk) | yes      | yes      |
  ## | removed                       | yes      | no       |
  ## | added                         | no       | yes      |
  ##
  ## and the code lines carry ``diffLineText`` — the file's own text — rather
  ## than the raw ``content`` a review's collector writes with its ``+``/``-``
  ## marker still attached.  Feeding the marker to a diff editor would put a
  ## differing character on *every* changed line, which is exactly what the
  ## word-level marking would then report.
  ##
  ## The file header is NOT in the model any more.  It used to be line 1, and
  ## line 1 is precisely what an unchanged region at the top of the file hides:
  ## a header the reader cannot see is worse than one drawn somewhere it cannot
  ## scroll away from, so it moved to the tab's DOM chrome and is carried here
  ## as ``DiffPair.files``.  The ``@@`` divider stayed, because it must sit at
  ## its hunk's place in the scroll and it always abuts a change — so it is
  ## always within ``contextLineCount`` of one and is never collapsed.
  ##
  ## The old side is *reconstructed*, not fetched.  ``sourceLines`` is the new
  ## revision's text; everything a diff does not mention is unchanged by
  ## definition, so the old revision is that text with each hunk's own old
  ## lines put back in place.  A file whose text could not be obtained at all
  ## (a failed ``git show``, a review export with no ``sourceContent``) still
  ## renders its hunks: the honest document is then the hunks alone, because
  ## there is no file to be whole.
  result.original.lines = @[]
  result.modified.lines = @[]
  result.unchangedRuns = @[]
  result.files = @[]
  result.language = diffLanguageForFiles(files)

  # Local so the "both sides" cases below cannot drift apart by editing one,
  # and so every shared line extends the current unchanged run — which is what
  # `collapsedRegionsFor` reads.  A run is exactly a maximal sequence of these
  # calls, so it cannot fall out of step with what was actually emitted.
  proc bothSides(pair: var DiffPair; line: DiffDocumentLine) =
    let originalLine = pair.original.lines.len + 1
    let modifiedLine = pair.modified.lines.len + 1
    pair.original.lines.add(line)
    pair.modified.lines.add(line)
    if pair.unchangedRuns.len > 0:
      let last = pair.unchangedRuns[^1]
      if last.originalStart + last.length == originalLine and
         last.modifiedStart + last.length == modifiedLine:
        pair.unchangedRuns[^1].length += 1
        return
    pair.unchangedRuns.add(DiffUnchangedRun(
      originalStart: originalLine, modifiedStart: modifiedLine, length: 1))

  for file in files:
    if file.hunks.len == 0:
      continue
    result.files.add(DiffFileEntry(
      fileIndex: file.fileIndex,
      path: file.path,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      headerText: fileHeaderText(file)))

    # The file's text is the NEW side's — but only if the file HAS a new side.
    #
    # A deletion does not: every line is a removal and the new revision holds
    # nothing.  Its ``sourceLines`` can still be populated (a review export
    # whose collector read the file before it went, or a fixture that carries
    # the old text there), and treating that as the new side would reconstruct
    # the deleted file as unchanged on both sides — measured on the review
    # fixture's ``src/config.rs``, which came out with seven context lines and
    # no deletion at all.
    #
    # Derived from the hunks rather than from ``status``, so it stays true for
    # whatever spelling of "deleted" a collector uses, and so this module keeps
    # its rule of reading only the rows.
    var hasNewSide = false
    for hunk in file.hunks:
      if hunk.newCount > 0:
        hasNewSide = true
      for line in hunk.lines:
        if line.newLine > 0:
          hasNewSide = true
    let source = if hasNewSide: file.sourceLines else: @[]
    let fileIndex = file.fileIndex
    # The next line of each revision that has not been emitted yet.  They move
    # apart as hunks add and remove lines, which is what lets an unchanged line
    # between two hunks be numbered correctly on both sides.
    var newCursor = 1
    var oldCursor = 1

    proc emitUnchanged(pair: var DiffPair; source: seq[string];
                       fileIndex: int; oldCursor, newCursor: var int;
                       upToNewLine: int) =
      ## The file's own lines from ``newCursor`` up to (not including)
      ## ``upToNewLine``.  Unchanged by definition — a diff would have
      ## mentioned them otherwise — so they carry both numbers and go on both
      ## sides.  With no source text there is nothing to emit and the document
      ## degrades to the hunks alone, which is the honest answer.
      var lineNumber = newCursor
      while lineNumber < upToNewLine and lineNumber <= source.len:
        pair.bothSides(DiffDocumentLine(
          kind: dlkContext,
          text: source[lineNumber - 1],
          oldNumber: oldCursor + (lineNumber - newCursor),
          newNumber: lineNumber,
          fileIndex: fileIndex,
          hunkIndex: -1))
        lineNumber += 1
      oldCursor += lineNumber - newCursor
      newCursor = lineNumber

    for hunkIndex, hunk in file.hunks:
      result.emitUnchanged(source, fileIndex, oldCursor, newCursor,
                           hunk.newStart)

      result.bothSides(DiffDocumentLine(
        kind: dlkHunkHeader,
        text: hunkHeaderText(hunk),
        fileIndex: fileIndex,
        hunkIndex: hunkIndex))

      for line in hunk.lines:
        let documentLine = DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: diffLineText(line),
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: fileIndex,
          hunkIndex: hunkIndex)
        case documentLine.kind
        of dlkRemoved:
          # No position in the new revision — it is what the old side had.
          result.original.lines.add(documentLine)
        of dlkAdded:
          result.modified.lines.add(documentLine)
        else:
          result.bothSides(documentLine)
        if line.oldLine >= oldCursor:
          oldCursor = line.oldLine + 1
        if line.newLine >= newCursor:
          newCursor = line.newLine + 1

      # A hunk whose lines carry no numbers at all (a malformed row) must not
      # leave the cursors behind its declared range, or the tail below would
      # emit the hunk's own lines a second time.
      if hunk.newStart + hunk.newCount > newCursor:
        newCursor = hunk.newStart + hunk.newCount
      if hunk.oldStart + hunk.oldCount > oldCursor:
        oldCursor = hunk.oldStart + hunk.oldCount

    result.emitUnchanged(source, fileIndex, oldCursor, newCursor,
                         source.len + 1)

proc diffPairFor*(vm: VCSVM): DiffPair =
  ## The two documents for the diff a panel currently holds.
  ##
  ## This reads ``vm.diffFiles`` and *nothing else* — in particular not
  ## ``vm.deepReviewMode``.  That is the mode-agnosticism rule of
  ## VCS-Panel.md, "Unified Diff View (Shared)", expressed as code rather than
  ## as a comment, and ``test_diff_decorations_are_mode_agnostic`` fails if a
  ## later change makes this proc consult the mode.  Where the file's text came
  ## from is the one place the two modes genuinely differ, and that is answered
  ## before the rows reach here: whoever filled ``VCSDiffFileRow.sourceLines``
  ## has already decided whether it came from a review export or from ``git
  ## show``.
  buildDiffPair(vm.diffFiles.val)

proc diffContextLineCount*(pair: DiffPair;
                           base = DiffContextLineCount): int {.noSideEffect.} =
  ## How many unchanged lines the editor must keep visible at each end of a
  ## collapsed run, for THIS document (UD-2).
  ##
  ## Three is Monaco's default and git's, and it is what a reviewer expects to
  ## see around a change.  It is not enough here, and the reason is the one
  ## piece of chrome still inside the models.
  ##
  ## A ``@@`` divider is an unchanged line: it is byte-identical on both sides,
  ## so it belongs to the run that precedes its hunk — and it is followed by
  ## the hunk's own *leading context lines*, which are unchanged too.  Keeping
  ## the last three lines of that run therefore keeps the hunk's three context
  ## lines and hides the divider, which is the one line §4.1 names ("Hunk
  ## headers (`@@ -N,M +N,M @@`) as section dividers") and the one line hunk
  ## selection is keyed on.  Measured, not reasoned about: with
  ## ``contextLineCount: 3`` every divider that followed a collapsed region
  ## disappeared into it.
  ##
  ## Keeping one more line than the longest divider-to-change tail in the
  ## document keeps every divider, whatever ``-U`` the diff was produced with.
  ## The cost is one extra line of context at every boundary, which is the
  ## right side to err on in a review.
  result = base
  let lines = pair.modified.lines
  for i, line in lines:
    if line.kind != dlkHunkHeader:
      continue
    var tail = 0
    var j = i + 1
    while j < lines.len and lines[j].kind == dlkContext and
          lines[j].hunkIndex == line.hunkIndex and
          lines[j].fileIndex == line.fileIndex:
      tail += 1
      j += 1
    if tail + 1 > result:
      result = tail + 1

proc collapsedRegionsFor*(pair: DiffPair;
                          contextLineCount = DiffContextLineCount;
                          minimumLineCount = DiffMinimumLineCount):
                          seq[DiffCollapsedRegion] {.noSideEffect.} =
  ## The stretches a freshly opened diff editor hides, given this pair.
  ##
  ## A transcription of ``UnchangedRegion.fromDiffs`` in the vendored
  ## monaco-editor 0.54.0 (``min/vs/editor.api-i0YVFWkl.js``), so it predicts
  ## the editor rather than deciding anything itself:
  ##
  ## - a run that touches the *start or end* of the document is trimmed by
  ##   ``contextLineCount`` at its inner end only, and collapses when at least
  ##   ``contextLineCount + minimumLineCount`` lines are left;
  ## - any other run is trimmed at both ends and collapses when at least
  ##   ``2 * contextLineCount + minimumLineCount`` lines are left;
  ## - a run that is both the start and the end — an unchanged file — is not
  ##   trimmed at all.
  ##
  ## Why predict it at all: the file-edge and hunk-adjacency cases are
  ## arithmetic, and arithmetic asserted through a browser is asserted at the
  ## wrong layer.  The Playwright suite cross-checks this against the editor's
  ## own regions, which is what keeps the transcription honest.
  ##
  ## One caveat, recorded rather than hidden: Monaco computes its own diff and
  ## may pair lines the rows did not — a line whose text is byte-identical on
  ## both sides is unchanged to Monaco even where git wrote it as a removal and
  ## an addition — so on such a file the editor may collapse slightly *more*
  ## than this predicts, never less.
  result = @[]
  let originalCount = pair.original.lines.len
  let modifiedCount = pair.modified.lines.len
  for run in pair.unchangedRuns:
    var originalStart = run.originalStart
    var modifiedStart = run.modifiedStart
    var length = run.length
    let atStart = originalStart == 1 and modifiedStart == 1
    let atEnd = originalStart + length == originalCount + 1 and
                modifiedStart + length == modifiedCount + 1
    if atStart or atEnd:
      if length < contextLineCount + minimumLineCount:
        continue
      if atStart and not atEnd:
        length -= contextLineCount
      elif atEnd and not atStart:
        originalStart += contextLineCount
        modifiedStart += contextLineCount
        length -= contextLineCount
    else:
      if length < 2 * contextLineCount + minimumLineCount:
        continue
      originalStart += contextLineCount
      modifiedStart += contextLineCount
      length -= 2 * contextLineCount
    result.add(DiffCollapsedRegion(
      originalStart: originalStart,
      modifiedStart: modifiedStart,
      lineCount: length))

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
  of dlkHunkHeader: DiffHunkHeaderClass
  of dlkAdded: DiffAddedClass
  of dlkRemoved: DiffRemovedClass
  of dlkContext: DiffContextClass

proc lineNumberClassFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The class that colours the `+` / `-` marker now carried by the label.
  ##
  ## A context line gets none: its number is ordinary chrome, and colouring it
  ## would make an unchanged line read as a change.
  case kind
  of dlkAdded: DiffLineNumberAddedClass
  of dlkRemoved: DiffLineNumberRemovedClass
  of dlkContext, dlkHunkHeader: ""

proc reviewValueBandWashClass*(doc: DiffDocument;
                               modelLine: int): string {.noSideEffect.} =
  ## The wash class for the value band annotating a 1-based model line.
  ##
  ## A line outside the document is context: a band with no line to belong to
  ## is not a reason to throw, and an untinted band is the state the surface
  ## was already in.
  if modelLine < 1 or modelLine > doc.lines.len:
    return ReviewValueBandContextClass
  case doc.lines[modelLine - 1].kind
  of dlkAdded: ReviewValueBandAddedClass
  of dlkRemoved: ReviewValueBandRemovedClass
  of dlkContext, dlkHunkHeader: ReviewValueBandContextClass

proc marginClassFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The class that paints a line's whole margin.  Only the `@@` divider has
  ## one — see ``DiffDecoration.marginClassName``.  A changed line must NOT:
  ## its wash is the diff editor's own, painted over the content area, and
  ## carrying it across the numbers column would make the gutter read as part
  ## of the change rather than as the rail that indexes it.
  case kind
  of dlkHunkHeader: DiffHunkHeaderMarginClass
  of dlkAdded, dlkRemoved, dlkContext: ""

proc gutterClassFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The class that draws the `+` / `-` gutter marker VCS-Panel.md requires.
  ## The `@@` divider gets none: it is chrome, not content.
  case kind
  of dlkAdded: DiffGutterAddedClass
  of dlkRemoved: DiffGutterRemovedClass
  of dlkContext: DiffGutterContextClass
  of dlkHunkHeader: ""

proc oldNumberText*(line: DiffDocumentLine): string {.noSideEffect.} =
  ## The old-revision gutter number, blank where there is none — an added line
  ## exists only in the new revision, and a header in neither.
  if line.oldNumber > 0: $line.oldNumber else: ""

proc newNumberText*(line: DiffDocumentLine): string {.noSideEffect.} =
  if line.newNumber > 0: $line.newNumber else: ""

proc lineMarkerFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The `+` / `-` marker VCS-Panel.md requires, as a character.
  ##
  ## A *space* for a context line rather than nothing, so the numbers of
  ## changed and unchanged lines stay in the same column — the same reason
  ## `DiffGutterContextClass` used to draw a blank marker.
  case kind
  of dlkAdded: "+"
  of dlkRemoved: "-"
  of dlkContext: " "
  of dlkHunkHeader: ""

proc lineNumberLabels*(doc: DiffDocument; side: DiffSide; width = 4):
    seq[string] =
  ## One `<marker><number>` gutter label per model line, for one side of the
  ## diff editor.
  ##
  ## The pre-DR-R4 DOM renderer drew two gutter columns
  ## (``deepreview-unified-gutter-old`` / ``-new``), and DR-R4 kept both by
  ## padding them into a single label, because one synthetic model had only one
  ## gutter to put them in.
  ##
  ## UD-1 has two editors, so the two columns are back to being two columns:
  ## the original editor's margin carries the old numbers and the modified
  ## editor's carries the new ones, side by side in the order Monaco lays them
  ## out.  That is also how VS Code's inline diff draws it.  Emitting both
  ## numbers on both sides — which is what the DR-R4 label did — produced four
  ## columns, two of them duplicates, and clipped the old numbers away
  ## entirely: Monaco sizes the original editor of an inline diff from its
  ## ``lineNumbersMinChars`` alone, so a margin wider than that is simply cut
  ## off, and a reviewer reported the deleted lines as unnumbered.
  ##
  ## The marker is part of the *label* rather than a decoration in Monaco's
  ## line-decorations lane, for the same reason.  That lane is to the right of
  ## the numbers, and it does not fit beside them in the original editor's
  ## strip at any width Monaco will grant it; putting the marker in the label
  ## costs one character, is symmetric across the two sides, and reads the way
  ## a unified diff has always read.
  ##
  ## ``width`` is the number column's width, derived from the largest number in
  ## either document so the two margins agree.  The gutter is given
  ## ``white-space: pre`` so the padding survives.
  result = newSeq[string](doc.lines.len)
  for i, line in doc.lines:
    let marker = lineMarkerFor(line.kind)
    if marker.len == 0:
      # Chrome, present on both sides and belonging to neither revision.
      result[i] = ""
    else:
      result[i] = marker & align(
        if side == dsOriginal: oldNumberText(line) else: newNumberText(line),
        width)

proc lineNumberWidth*(doc: DiffDocument): int {.noSideEffect.} =
  ## Digits needed by the widest line number in the document, minimum 1.
  result = 1
  for line in doc.lines:
    let n = max(len(oldNumberText(line)), len(newNumberText(line)))
    if n > result:
      result = n

proc lineNumberColumnWidth*(pair: DiffPair): int {.noSideEffect.} =
  ## Characters one side's gutter needs: the widest number plus its marker.
  ##
  ## Shared by both sides so the two columns are the same size and read as one
  ## gutter.  It is what the host passes to Monaco as ``lineNumbersMinChars``,
  ## and — because Monaco sizes the inline diff's original editor from exactly
  ## that number — it is also what decides whether the old numbers are visible
  ## at all.
  max(lineNumberWidth(pair.original), lineNumberWidth(pair.modified)) + 1

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
    if line.hunkIndex >= 0 and
        isHunkSelected(selectedHunks, line.fileIndex, line.hunkIndex):
      className.add(" " & DiffSelectedHunkClass)
    result[i] = DiffDecoration(
      line: i + 1,
      className: className,
      gutterClassName: gutterClassFor(line.kind),
      lineNumberClassName: lineNumberClassFor(line.kind),
      marginClassName: marginClassFor(line.kind))

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

proc isHunkHeaderLine*(doc: DiffDocument; modelLine: int): bool {.noSideEffect.} =
  ## VCS-Panel.md, "Hunk Selection": "Click a hunk header to select it."  Only
  ## the header is the selection gesture; clicking inside a hunk's body leaves
  ## the selection alone so ordinary text selection keeps working.
  if modelLine < 1 or modelLine > doc.lines.len:
    return false
  doc.lines[modelLine - 1].kind == dlkHunkHeader
