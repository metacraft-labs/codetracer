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
    ## The two sides share their **chrome** — the file header, the ``@@``
    ## divider and the expansion controls, which DeepReview-GUI.md §4.1 and
    ## §4.2 require.  Shared, and byte-identical, so Monaco classifies them as
    ## unchanged and draws each exactly once; they are also what anchors the
    ## comparison, so a hunk's lines cannot be matched against a neighbouring
    ## hunk's or, in a multi-file target, against another file's.
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
    gutterClassName*: string
      ## ``linesDecorationsClassName`` — the classification of the line, in
      ## the margin's decorations lane.  Since UD-1 the visible `+` / `-`
      ## marker is in the gutter *label* instead (``lineNumberLabels``); this
      ## remains the seam the GUI suites assert the added / removed / context
      ## decision on.
    lineNumberClassName*: string
      ## ``IModelDecorationOptions.lineNumberClassName`` — colours THIS line's
      ## gutter label, which is where the marker now lives.

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

  ## Applied to the line's *gutter label* rather than to the line-decorations
  ## lane (Monaco's ``IModelDecorationOptions.lineNumberClassName``), because
  ## UD-1 moved the `+` / `-` marker into the label — see
  ## ``lineNumberLabels``.  These are what colour it, and they have to be per
  ## line rather than per side: every context line of the new revision would
  ## otherwise read as an addition.
  DiffLineNumberAddedClass* = "ct-diff-linenum-added"
  DiffLineNumberRemovedClass* = "ct-diff-linenum-removed"

  DiffEmptyDocumentText* = "No changes to show."
    ## The model text of a diff tab whose target produced no hunks.  A Monaco
    ## model cannot be empty and still be an editor, and a blank buffer would
    ## read as "still loading".

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

proc expandAboveText*(): string {.noSideEffect.} =
  ## VCS-Panel.md: "Context expansion controls (Expand N lines above/below)".
  ## The leading "..." is the standalone panel's expand-row icon, kept so the
  ## migrated control reads the same.
  "... Expand " & $ContextExpandStep & " lines above"

proc expandBelowText*(): string {.noSideEffect.} =
  "... Expand " & $ContextExpandStep & " lines below"

proc buildDiffPair*(files: openArray[VCSDiffFileRow];
                    expansion: openArray[VCSHunkExpansion] = []): DiffPair =
  ## Assemble the two documents a diff tab's Monaco **diff editor** compares.
  ##
  ## Order is exactly the render order of the rows: for each file, its header,
  ## then for each hunk the `@@` divider, the expand-above control, the lines
  ## expansion has revealed above, the hunk's own lines, the lines revealed
  ## below, and the expand-below control.  That is the order the standalone
  ## panel's DOM renderer used (``isonim_deepreview_view.nim``), and the order
  ## the pre-UD-1 single document used, so the surface reads the same.  Files
  ## with no hunks are skipped — they have nothing to show and a bare header
  ## would read as an empty diff for a file that was not, in fact, part of the
  ## changeset the target named.
  ##
  ## What changed in UD-1 is *where each line goes*:
  ##
  ## | line              | original | modified |
  ## |-------------------+----------+----------|
  ## | file header       | yes      | yes      |
  ## | ``@@`` divider    | yes      | yes      |
  ## | expand control    | yes      | yes      |
  ## | context           | yes      | yes      |
  ## | revealed context  | yes      | yes      |
  ## | removed           | yes      | no       |
  ## | added             | no       | yes      |
  ##
  ## and that the code lines carry ``diffLineText`` — the file's own text —
  ## rather than the raw ``content`` a review's collector writes with its
  ## ``+``/``-`` marker still attached.  Feeding the marker to a diff editor
  ## would put a differing character on *every* changed line, which is exactly
  ## what the word-level marking would then report.
  ##
  ## Everything present on both sides is byte-identical, so Monaco classifies
  ## it as unchanged and renders it once.
  ##
  ## ``expansion`` defaults to empty, which is exactly "nothing expanded yet":
  ## the controls still appear wherever hidden lines exist, so a caller that
  ## does not track expansion still gets a correct, if static, document.
  result.original.lines = @[]
  result.modified.lines = @[]
  result.language = diffLanguageForFiles(files)

  # Local so the "both sides" cases below cannot drift apart by editing one.
  proc bothSides(pair: var DiffPair; line: DiffDocumentLine) =
    pair.original.lines.add(line)
    pair.modified.lines.add(line)

  for file in files:
    if file.hunks.len == 0:
      continue
    result.bothSides(DiffDocumentLine(
      kind: dlkFileHeader,
      text: fileHeaderText(file),
      fileIndex: file.fileIndex,
      hunkIndex: -1))
    for hunkIndex, hunk in file.hunks:
      let counts = expansionCountsIn(expansion, file.fileIndex, hunkIndex)
      let window = expansionWindow(hunk, file.sourceLines, counts[0], counts[1])

      result.bothSides(DiffDocumentLine(
        kind: dlkHunkHeader,
        text: hunkHeaderText(hunk),
        fileIndex: file.fileIndex,
        hunkIndex: hunkIndex))

      # The control is offered only while a further click would reveal
      # something, so a user never presses a button that cannot act.
      if window.canExpandAbove:
        result.bothSides(DiffDocumentLine(
          kind: dlkExpandAbove,
          text: expandAboveText(),
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex))
      for line in window.above:
        result.bothSides(DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: diffLineText(line),
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex,
          revealed: true))

      for line in hunk.lines:
        let documentLine = DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: diffLineText(line),
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex)
        case documentLine.kind
        of dlkRemoved:
          # No position in the new revision — it is what the old side had.
          result.original.lines.add(documentLine)
        of dlkAdded:
          result.modified.lines.add(documentLine)
        else:
          result.bothSides(documentLine)

      for line in window.below:
        result.bothSides(DiffDocumentLine(
          kind: lineKindFor(line.lineType),
          text: diffLineText(line),
          oldNumber: line.oldLine,
          newNumber: line.newLine,
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex,
          revealed: true))
      if window.canExpandBelow:
        result.bothSides(DiffDocumentLine(
          kind: dlkExpandBelow,
          text: expandBelowText(),
          fileIndex: file.fileIndex,
          hunkIndex: hunkIndex))

proc diffPairFor*(vm: VCSVM): DiffPair =
  ## The two documents for the diff a panel currently holds.
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
  buildDiffPair(vm.diffFiles.val, vm.hunkExpansion.val)

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

proc lineNumberClassFor*(kind: DiffLineKind): string {.noSideEffect.} =
  ## The class that colours the `+` / `-` marker now carried by the label.
  ##
  ## A context line gets none: its number is ordinary chrome, and colouring it
  ## would make an unchanged line read as a change.
  case kind
  of dlkAdded: DiffLineNumberAddedClass
  of dlkRemoved: DiffLineNumberRemovedClass
  of dlkContext, dlkFileHeader, dlkHunkHeader,
     dlkExpandAbove, dlkExpandBelow: ""

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
  of dlkFileHeader, dlkHunkHeader, dlkExpandAbove, dlkExpandBelow: ""

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
    if line.revealed:
      className.add(" " & DiffRevealedClass)
    if line.hunkIndex >= 0 and
        isHunkSelected(selectedHunks, line.fileIndex, line.hunkIndex):
      className.add(" " & DiffSelectedHunkClass)
    result[i] = DiffDecoration(
      line: i + 1,
      className: className,
      gutterClassName: gutterClassFor(line.kind),
      lineNumberClassName: lineNumberClassFor(line.kind))

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
