## The review's diff editor: Monaco's inline diff editor over a reviewed
## file, with the review's decorations and the parallel value band beside the
## changed lines (the recorded values Deep Review shows).
##
## This is the half of ``ui/unified_diff.nim`` that needs nothing of the
## application: no ``Data``, no layout, no session. It takes Monaco editors,
## a ``DiffDocument`` and the review's annotations, and draws. The diff tab
## (``UnifiedDiffComponent``) drives it from the active review, and the
## StoryBook bundle (``storybook_components.nim``), which has no ``Data``,
## drives it from a story's review, so the two draw a review's file with one
## implementation: the same editor options, the same decorations and the
## same value bands, built out of the shared flow-value views
## (``viewmodel/views/isonim_flow_value_view.nim``, the elements the
## debugger's own value chips are).
##
## Monaco's diff editor API:
## https://microsoft.github.io/monaco-editor/typedoc/functions/editor.createDiffEditor.html

when not defined(js):
  {.error: "review_diff_editor.nim requires the JS backend".}

import std/[dom, jsffi, strformat]
import isonim/web/web_renderer
from isonim/web/dom_api import nil
import ../lib/monaco_lib
import ../viewmodel/views/isonim_flow_value_view
import ../viewmodel/viewmodels/[diff_document, review_flow_overlay, vcs_vm]
import ./review_flow_adapter

type
  ReviewValueBandSink* = object
    ## Where ``placeReviewValueBands`` records what it adds to an editor, for
    ## the caller to remove before the next placement: the common left offset
    ## the bands start at, each content widget (a band beside the code) and
    ## each view zone (a band on its own row). Each is recorded the moment it
    ## is added, so a placement that raises half-way leaves the bands it did
    ## add in the caller's hands, not orphaned in the editor.
    bandLeft*: proc(px: int)
    widget*: proc(widget: js)
    zone*: proc(zoneId: int)

const noFlowStyle: FlowStyle = @[]
  ## A chip with no inline style of its own: the flow views' default look.

# The shared flow-value views, as DOM nodes (``ui/flow_value_dom.nim`` does
# the same for the application's Karax nodes).
template asNode(e: dom_api.Element): Node = cast[Node](e)

proc flowValueContainerDom(style: FlowStyle): Node =
  asNode(renderFlowValueContainer[WebRenderer, dom_api.Element](WebRenderer(), style))

proc flowValueNameDom(name: cstring): Node =
  asNode(renderFlowValueName[WebRenderer, dom_api.Element](WebRenderer(), $name))

proc flowValueBoxDom(id: cstring; className: cstring; text: cstring;
                     iteration: int; style: FlowStyle): Node =
  asNode(renderFlowValueBox[WebRenderer, dom_api.Element](
    WebRenderer(), $id, $className, $text, iteration, style, ""))

proc flowValueEmptyDom(style: FlowStyle; text: cstring): Node =
  asNode(renderFlowValueEmpty[WebRenderer, dom_api.Element](WebRenderer(), style, $text))

proc flowValueColumnDom(id: cstring; widthPx: float): Node =
  asNode(renderFlowValueColumn[WebRenderer, dom_api.Element](WebRenderer(), $id, widthPx))

proc flowValueGroupDom(): Node =
  asNode(renderFlowValueGroup[WebRenderer, dom_api.Element](WebRenderer()))

proc flowValueLoopValuesDom(loopIndex: int): Node =
  asNode(renderFlowValueLoopValues[WebRenderer, dom_api.Element](WebRenderer(), loopIndex))

proc flowValueBandDom(leftPx: float; isLoop: bool; extraClass: string;
                      positioned: bool; maxWidthPx: float): Node =
  asNode(renderFlowValueBand[WebRenderer, dom_api.Element](
    WebRenderer(), leftPx, isLoop, extraClass, positioned, maxWidthPx))
# ---------------------------------------------------------------------------
# Monaco FFI
# ---------------------------------------------------------------------------

proc udCreateDiffEditor*(divId: cstring, options: JsObject): js
  {.importjs: "monaco.editor.createDiffEditor(document.getElementById(#), #)".}
  ## UD-1: the unified diff is Monaco's own diff editor in inline mode.
  ##
  ## The binding already existed (`lib/monaco_lib.nim`'s `createDiffEditor`,
  ## used by `ui/agent_activity.nim`); this is the same call reached the same
  ## way the rest of this module reaches Monaco, by element id rather than by
  ## the `MonacoEditorOptions` object, because the option set a diff editor
  ## takes (`renderSideBySide`, `hideUnchangedRegions`, `diffAlgorithm`,
  ## `experimental.useTrueInlineView`) is wider than that record describes.

proc udCreateModel*(value: cstring, language: cstring): js
  {.importjs: "monaco.editor.createModel(#, #)".}
  ## A real model with a real language, which is the whole point of UD-1: a
  ## tokenizer runs over it.

proc udDisposeModel*(model: js)
  {.importjs: "(function(m) { if (m) { m.dispose(); } })(#)".}

proc udSetDiffModel*(editor: js, original: js, modified: js)
  {.importjs: "#.setModel({ original: #, modified: # })".}

proc udDiffModifiedEditor*(editor: js): MonacoEditor
  {.importjs: "#.getModifiedEditor()".}

proc udDiffOriginalEditor*(editor: js): MonacoEditor
  {.importjs: "#.getOriginalEditor()".}

proc udDisposeDiffEditor*(editor: js)
  {.importjs: "(function(e) { if (e) { e.dispose(); } })(#)".}

proc udCreateDecorationsCollection*(editor: MonacoEditor, decorations: js): js
  {.importjs: "#.createDecorationsCollection(#)".}

proc udCollectionSet*(collection: js, decorations: js)
  {.importjs: "#.set(#)".}

proc udSetValue*(editor: MonacoEditor, value: cstring)
  {.importjs: """
  (function(editor, value) {
    var model = editor.getModel();
    // `setValue` on an unchanged value still resets the undo stack and
    // re-runs the tokenizer over the whole document; on a diff editor it also
    // forces a full re-diff of both sides. Expansion re-publishes both models
    // on every click, and only one of them usually changes.
    if (model && model.getValue() !== value) { model.setValue(value); }
  })(#, #)"""}

proc udForceTokenization*(model: js, maxLines: int) {.importjs: """
  (function(model, maxLines) {
    if (!model || typeof model.getLineCount !== 'function') { return; }
    var count = model.getLineCount() | 0;
    if (count <= 0) { return; }
    var upTo = count > maxLines ? maxLines : count;
    // `model.tokenization` is where monaco-editor 0.54 keeps it; the bare
    // `model.forceTokenization` is the older spelling. Neither is guaranteed
    // by `monaco.d.ts`, so a build without either must degrade to the
    // untokenized deleted lines rather than throw during a tab mount.
    var owner = (model.tokenization && typeof model.tokenization.forceTokenization === 'function')
      ? model.tokenization
      : (typeof model.forceTokenization === 'function' ? model : null);
    if (!owner) {
      console.warn('unified diff: this Monaco has no forceTokenization; ' +
                   'deleted lines will render without syntax tokens');
      return;
    }
    try {
      owner.forceTokenization(upTo);
    } catch (err) {
      console.warn('unified diff: forcing tokenization of the original model failed', err);
    }
  })(#, #)""".}
  ## Tokenize the ORIGINAL model up front, so the deleted lines are coloured.
  ##
  ## Monaco's inline diff draws each deletion as a `view-lines line-delete`
  ## view zone, and it builds that zone from the ORIGINAL model's tokens —
  ## `oe.originalRange.mapToLineArray(n => Ae.tokenization.getLineTokens(n))`
  ## in the shipped bundle. `getLineTokens` returns whatever tokenization has
  ## already reached; it does not ask for any.
  ##
  ## And nothing ever asks. Tokenization is driven by what is RENDERED, and in
  ## an inline diff the original editor is a few-pixel gutter strip that never
  ## renders a line of text — so every deleted line came back as one `mtk1`
  ## run, whatever language the model was created with. UD-1 measured exactly
  ## that and recorded `experimental.useTrueInlineView` as the only known fix;
  ## it is not, and that option was never really a fix for this, because it
  ## also merges each deletion and its replacement into one line, which is a UX
  ## decision rather than a rendering one — and it would have removed the
  ## before/after pair the `diff-intraline` view exists to show.
  ##
  ## Capped, because this is synchronous work proportional to the file. A diff
  ## whose old side is longer than the cap keeps flat deleted lines past it,
  ## which is the pre-existing behaviour rather than a new failure.

proc udRebuildDeletedLineZones*(diffEditor: js) {.importjs: """
  (function(e) {
    if (!e || typeof e.updateOptions !== 'function') { return; }
    try {
      // Toggled and restored in the SAME synchronous block, so the option ends
      // where `initEditor` set it and no diff is ever computed under the other
      // value — what the pair does is invalidate the computation that builds
      // the zones, which is the only public way in.
      //
      // `ignoreTrimWhitespace` and not `renderIndicators`: both were tried in
      // the running product and only this one rebuilds the zones. The zones
      // are rebuilt when the DIFF result changes, not when a rendering option
      // does, so an option the diff does not depend on invalidates nothing.
      e.updateOptions({ ignoreTrimWhitespace: true });
      e.updateOptions({ ignoreTrimWhitespace: false });
    } catch (err) {
      console.warn('unified diff: could not rebuild the deleted-line zones', err);
    }
  })(#)""".}
  ## Rebuild the deleted lines' view zones, so they pick up the tokens.
  ##
  ## Monaco builds each zone ONCE, out of whatever `getLineTokens` answers at
  ## that instant, and never rebuilds it when tokenization catches up — there
  ## is no `onDidChangeTokens` path into that computation. Measured in the
  ## running product, and the measurement is what this pair of calls is for:
  ## the original model's line 4 (`  let y = x * 2;`) reports nine tokens with
  ## foregrounds `[1,23,1,25,1,25,1,34,25]`, and the zone rendered from it
  ## carries a single `mtk1` run. Forcing the tokenization earlier does not
  ## help — it is already done by then; forcing the ZONE to be rebuilt does,
  ## and turns the same line into `mtk1 mtk23 mtk25 mtk34 mtk17`.
  ##
  ## Scheduled rather than run inline, and re-checked rather than fired once:
  ## the invalidation only helps once a zone EXISTS to be rebuilt, and the diff
  ## is computed off the main thread, so "one macrotask later" is a guess. See
  ## `scheduleDeletedLineTokens`.

proc udDeletedLineTokenClasses*(hostId: cstring): int {.importjs: """
  (function(hostId) {
    var host = document.getElementById(hostId);
    if (!host) { return -1; }
    var zones = host.querySelectorAll('.view-lines.line-delete');
    if (zones.length === 0) { return -1; }
    var seen = {};
    var count = 0;
    zones.forEach(function(zone) {
      zone.querySelectorAll("span[class^='mtk']").forEach(function(span) {
        var m = /\bmtk\d+\b/.exec(span.className);
        if (m && !seen[m[0]]) { seen[m[0]] = true; count += 1; }
      });
    });
    return count;
  })(#)""".}
  ## How many distinct `mtk<n>` token classes the deleted lines carry, or `-1`
  ## when there is no deleted line to ask about.
  ##
  ## `1` is Monaco's "I have no tokens for these" answer and is what the defect
  ## looks like; `-1` is a diff with no deletion in it, which is not a defect
  ## and must not be retried forever.

const DiffTokenizeLineLimit* = 5000
  ## How far `udForceTokenization` will tokenize an original model in one go.
  ##
  ## Whole-file models (UD-2) mean this is the file's length, not a hunk's, so
  ## it needs a ceiling. 5000 lines of a Monarch grammar is a few milliseconds;
  ## the largest file in the review corpora is two orders of magnitude under
  ## it, and a reviewer scrolling a 5000-line diff has other problems.

proc udUpdateOptions*(editor: MonacoEditor, options: JsObject)
  {.importjs: "#.updateOptions(#)".}

proc udUpdateDiffOptions*(diffEditor: js, options: JsObject)
  {.importjs: "(function(e, o) { if (e) { e.updateOptions(o); } })(#, #)".}
  ## Options on the DIFF editor rather than on one of its two code editors —
  ## `hideUnchangedRegions` is the diff's, not a code editor's.

proc udOnMouseDown*(editor: MonacoEditor, handler: proc(e: js))
  {.importjs: "#.onMouseDown(#)".}

proc udScrollTop*(editor: MonacoEditor): int
  {.importjs: "#.getScrollTop()".}

proc udSetScrollTop*(editor: MonacoEditor, top: int)
  {.importjs: "#.setScrollTop(#)".}

# Monaco's mouse event carries `target.position` only when the pointer is over
# content (it is absent over the scrollbar, the overview ruler and past the
# last line), so every read below is guarded on the JS side rather than
# through Nim's `isNil`, which does not describe `undefined`.
proc udMouseLine*(e: js): int
  {.importjs: """(function(e) {
    return (e && e.target && e.target.position) ? e.target.position.lineNumber : 0;
  })(#)""".}
proc udMouseShift*(e: js): bool
  {.importjs: "(function(e) { return !!(e && e.event && e.event.shiftKey); })(#)".}
proc udMouseCtrl*(e: js): bool
  {.importjs: """(function(e) {
    return !!(e && e.event && (e.event.ctrlKey || e.event.metaKey));
  })(#)""".}

proc udAddViewZone*(editor: MonacoEditor, zone: js): int {.importjs: """
  (function(editor, zone) {
    var id = null;
    editor.changeViewZones(function(accessor) { id = accessor.addZone(zone); });
    return id;
  })(#, #)""".}
  ## Monaco's view zones can only be mutated inside a `changeViewZones`
  ## transaction, which is why this is a wrapper rather than a direct call.
  ## Identical in shape to `ui/flow.nim`'s `addMonacoViewZone`, which is what
  ## renders the loop iteration slider — §7 asks for the same mechanism, so it
  ## is the same call.

proc udRemoveViewZone*(editor: MonacoEditor, zoneId: int) {.importjs: """
  (function(editor, id) {
    editor.changeViewZones(function(accessor) { accessor.removeZone(id); });
  })(#, #)""".}

proc udLineNumberFn*(labels: seq[cstring]): js
  {.importjs: """(function(labels) {
    return function(n) {
      return (n >= 1 && n <= labels.length) ? labels[n - 1] : '';
    };
  })(#)""".}
  ## Monaco's ``lineNumbers`` option accepts a callback returning the label for
  ## a model line.  That is how one gutter carries the two columns the DOM
  ## renderer drew side by side (``deepreview-unified-gutter-old`` / ``-new``);
  ## the labels themselves are built by ``diff_document.lineNumberLabels``.


proc monacoDecorations*(doc: DiffDocument;
                       selected: openArray[(int, int)]): seq[JsObject] =
  ## Turn the pure decorations into Monaco descriptors.  One per line, whole
  ## line, with the `+` / `-` marker in the line-decorations lane.
  result = @[]
  for decoration in decorationsFor(doc, selected):
    # Read EVERY field this descriptor needs into a local *before* building it.
    #
    # `js{...}` closes over every expression it is given, and `items` over the
    # `seq[DiffDecoration]` `decorationsFor` returns yields `lent
    # DiffDecoration` — a borrowed view of an element of a temporary seq.
    # Capturing that view in a closure that outlives the loop iteration is
    # exactly the lifetime error the compiler refuses ("'decoration' is of
    # type <lent DiffDecoration> which cannot be captured"), and it refuses it
    # on the JavaScript backend, where this proc actually runs.  Copying the
    # scalars out first means the closure captures owned values, which is what
    # it needs: the descriptor is handed to Monaco and kept, while the seq
    # backing `decoration` is gone by the time this proc returns.
    #
    # `marginClass` is here because it was NOT, and one missed field is enough:
    # the rule is per-EXPRESSION, so hoisting four of five left the fifth
    # reading `decoration` inside the closure and `nix build .#codetracer` died
    # compiling `ui.js` at the `marginClassName:` line — the same diagnostic the
    # paragraph above describes, from the one site it did not cover. Anything
    # added to this descriptor must be read into a local here too.
    let
      lineNumber = decoration.line
      lineClass = cstring(decoration.className)
      gutterClass = cstring(decoration.gutterClassName)
      lineNumberClass = cstring(decoration.lineNumberClassName)
      marginClass = cstring(decoration.marginClassName)
    result.add(js{
      range: js{
        startLineNumber: lineNumber,
        startColumn: 1,
        endLineNumber: lineNumber,
        endColumn: 1
      },
      options: js{
        isWholeLine: true,
        className: lineClass,
        linesDecorationsClassName: gutterClass,
        # Colours the `+` / `-` the gutter LABEL carries since UD-1.
        lineNumberClassName: lineNumberClass,
        # Paints the margin as well as the content, so the `@@` divider is a
        # full-bleed separator sharing its left edge with a collapsed region's
        # band. Empty on every other kind — see `diff_document.marginClassFor`.
        marginClassName: marginClass
      }
    })

proc monacoFlowDecorations*(decorations: seq[ReviewFlowDecoration]):
    seq[JsObject] =
  ## The standard Omniscience appearance: an *inline* class over the line's
  ## text, exactly as `editor.nim`'s `toDeltaDecorations` applies
  ## `MonacoLineStyle.inlineClass`.
  result = @[]
  for decoration in decorations:
    # Owned copies before the descriptor — see `monacoDecorations` above for
    # why a `lent` loop variable cannot cross into a `js{...}` closure.
    let
      lineNumber = decoration.modelLine
      inlineClass = cstring(decoration.inlineClassName)
    result.add(js{
      range: js{
        startLineNumber: lineNumber,
        startColumn: 1,
        endLineNumber: lineNumber,
        endColumn: 100000
      },
      options: js{
        isWholeLine: false,
        inlineClassName: inlineClass
      }
    })

# ---------------------------------------------------------------------------
# The parallel value band (UD-3)
# ---------------------------------------------------------------------------
#
#   "Keep the standard CodeTracer Omniscience appearance, produced by the same
#    code path as normal debugging […] Inline variable values MUST NOT be
#    rendered as text comments."  — DeepReview-GUI.md §4.4
#
# RV-5 met the "not a comment" half with Monaco *injected text* carrying the
# debugger's class names. UD-3 replaces it, because injected text cannot be the
# debugger's surface in the two ways that matter:
#
#   * it starts where the code line happens to END, so the values are a ragged
#     trailing strip rather than the aligned columns the flow view draws — and
#     a strip that starts further right is a strip that is cut off sooner,
#     which is the clipping every UD-1 and UD-2 reviewer reported;
#   * it is a flat run of spans, so a loop's several passes cannot be laid out
#     side by side at all. RV-5 therefore showed ONE pass and made the loop
#     control the only way to see the others.
#
# What replaces it is the parallel arrangement: one Monaco **content widget**
# per annotated line, holding a `.flow-parallel` row built out of
# `ui/flow_value_dom.nim` — the shared flow views, the same elements the
# debugger's chips are — anchored at ONE `left` offset for every line, past the
# longest line of the document, with one `.flow-parallel-values` column per
# recorded pass. (The debugger's own builder of this row, `ui/flow.renderFlow`,
# had no call site and was removed.)

proc udAddContentWidget*(editor: MonacoEditor, widget: js)
  {.importjs: "#.addContentWidget(#)".}

proc udRemoveContentWidget*(editor: MonacoEditor, widget: js)
  {.importjs: "#.removeContentWidget(#)".}

proc udContentWidget*(id: cstring, dom: Node, line: int): js {.importjs: """
  (function(id, dom, line) {
    return {
      getId: function() { return id; },
      getDomNode: function() { return dom; },
      getPosition: function() {
        // `0` is `ContentWidgetPositionPreference.EXACT`.
        return { position: { lineNumber: line, column: 1 }, preference: [0] };
      }
    };
  })(#, #, #)""".}
  ## A Monaco content widget, built in JS rather than as a Nim `js{}` literal
  ## of closures.
  ##
  ## This is not stylistic. A `js{ getId: (proc: cstring = widgetId) }` inside a
  ## LOOP closes over a variable Nim's JS backend hoists to the enclosing
  ## function, so every widget of the pass reports the LAST id. Monaco keys
  ## `_contentWidgets` by `getId()`, so adding N of them overwrote one map entry
  ## N times while appending N nodes — and `removeContentWidget` then removed
  ## exactly one of them. Measured: after stepping the invocation selector once,
  ## 9 bands on screen became 16, the previous call's values still beside the
  ## new call's. The JS-level factory gives each widget its own closure.

proc udContentWidth*(editor: MonacoEditor): int {.importjs: """
  (function(e) {
    var info = e.getLayoutInfo ? e.getLayoutInfo() : null;
    return info ? (info.contentWidth | 0) : 0;
  })(#)""".}
  ## The editor's content area in pixels, minimap and rulers excluded. Read
  ## through `getLayoutInfo()` rather than the cached `config.layoutInfo` that
  ## `FlowComponent` uses, because a diff tab has no `EditorViewComponent` to
  ## refresh that cache on resize.

proc udMaxLineOffset*(editor: MonacoEditor, lines: seq[int]): int {.importjs: """
  (function(e, lines) {
    var model = e.getModel();
    if (!model || !lines || lines.length === 0) { return 0; }
    var count = model.getLineCount();
    var best = 0;
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line < 1 || line > count) { continue; }
      // Monaco's own measurement, so it is right for tabs, for a changed font
      // size and for a proportional font — all three of which a
      // `column * charWidth` estimate gets wrong.
      var offset = e.getOffsetForColumn(line, model.getLineMaxColumn(line));
      if (offset > best) { best = offset; }
    }
    return best | 0;
  })(#, #)""".}
  ## The pixel offset of the end of the widest of `lines`.
  ##
  ## This is `FlowComponent.maxFlowLineWidth`: `recalculateMaxFlowLineWidth`
  ## computes exactly this maximum, and over exactly this set — the lines that
  ## carry flow (`for position, _ in flow.positionStepCounts`), not every line
  ## of the file. Restated here rather than reused because that proc is a
  ## method on a component a review has none of (RV-5 judgement call 3); the
  ## arithmetic, which is the part that decides where the values appear, is
  ## identical.

proc udLineHeight*(editor: MonacoEditor): int {.importjs: """
  (function(e) {
    // `EditorOption.lineHeight` is the supported way to ask; the numeric ids
    // are generated and are not stable across Monaco versions, so the enum is
    // read by name rather than hard-coded.
    var option = (typeof monaco !== 'undefined' && monaco.editor &&
                  monaco.editor.EditorOption)
      ? monaco.editor.EditorOption.lineHeight
      : undefined;
    if (option !== undefined && typeof e.getOption === 'function') {
      var value = e.getOption(option) | 0;
      if (value > 0) { return value; }
    }
    return 0;
  })(#)""".}
  ## The editor's rendered line height in pixels, or 0 when it cannot be asked.

proc udCharWidth*(editor: MonacoEditor): float {.importjs: """
  (function(e) {
    var model = e.getModel();
    if (!model || model.getLineCount() < 1) { return 0; }
    // Column 11 rather than 2, so a single measurement is averaged over ten
    // characters and a sub-pixel advance does not round to zero.
    var column = model.getLineMaxColumn(1);
    if (column < 11) { return 0; }
    var offset = e.getOffsetForColumn(1, 11) - e.getOffsetForColumn(1, 1);
    return offset > 0 ? offset / 10 : 0;
  })(#)""".}
  ## The width of one character of the editor's font, or 0 when it cannot be
  ## measured yet.


proc reviewCharWidthPx*(editor: MonacoEditor; fontSize: int): float =
  ## One character of the editor's font, in pixels.
  ##
  ## Measured off the editor when it can be — `getOffsetForColumn` on a real
  ## line is Monaco's own answer and is right for the font in force — and
  ## estimated from the configured size otherwise, which is only ever the case
  ## before the first layout.
  ## `fontSize` is the configured size the estimate is made from.
  result = float(max(fontSize, 8)) * 0.62
  if editor.isNil:
    return
  let measured = editor.udCharWidth()
  if measured > 0.0:
    result = measured

proc reviewValueBandGeometry*(editor: MonacoEditor; fontSize: int;
                              annotations: seq[ReviewValueAnnotation]):
    tuple[maxOffsetPx: float, charWidthPx: float, contentWidthPx: float] =
  ## The three measurements the band's placement is decided from.
  ##
  ## `maxOffsetPx` runs over the ANNOTATED lines only, which is
  ## `recalculateMaxFlowLineWidth`'s rule (`for position, _ in
  ## flow.positionStepCounts`) rather than "the widest line in the file" — a
  ## whole-file diff tab holds plenty of long lines that carry no values, and
  ## letting one of them push the band would move every value off screen for a
  ## reason a reader cannot see.
  ##
  ## The band's own offset is NOT computed here, because it depends on how wide
  ## the widest annotated line's column is as well as on where that line ends;
  ## `applyFlowValueBands` puts the two together through
  ## `reviewValueBandLeftPx`.
  let charWidth = editor.reviewCharWidthPx(fontSize)
  if editor.isNil:
    return (0.0, charWidth, 0.0)
  var lines: seq[int] = @[]
  for annotation in annotations:
    lines.add(annotation.modelLine)
  let contentWidth = float(editor.udContentWidth())
  let maxOffset = float(editor.udMaxLineOffset(lines))
  (maxOffset, charWidth, contentWidth)

proc reviewValueBandDom*(scope: int;
                         annotation: ReviewValueAnnotation;
                        leftPx, columnWidthPx, maxWidthPx: float;
                        visibleColumns, chipCharBudget: int;
                        morePassesMarker: bool;
                        hostClasses: string): Node =
  ## One line's band, built out of the debugger's own elements.
  ##
  ## ``hostClasses`` says which placement this band is in and which wash its
  ## line carries — see the note at the call site. ``scope`` keeps the ids
  ## of one diff tab's elements apart from another's (the tab's component id).
  let isLoop = annotation.loop > 0
  # A wrapper, because the node handed to `addContentWidget` is Monaco's to
  # position: it writes `position: absolute` and its own `left`/`top` onto it
  # every frame. The band's own offset therefore lives one level in, exactly as
  # the debugger's does inside `makeFlowLineContainer`'s widget div.
  result = document.createElement(cstring"div")
  result.setAttribute(
    cstring"class",
    cstring("review-flow-band-host" &
      (if hostClasses.len > 0: " " & hostClasses else: "")))
  let band = flowValueBandDom(
    leftPx, isLoop, "review-flow-band", positioned = true,
    maxWidthPx = maxWidthPx)
  result.appendChild(band)
  let host =
    if isLoop:
      let loopValues = flowValueLoopValuesDom(annotation.loop)
      let group = flowValueGroupDom()
      loopValues.appendChild(group)
      band.appendChild(loopValues)
      group
    else:
      band
  # Trailing empty columns are dropped. An empty column between two filled
  # ones is information — "this pass did not reach the line" — and keeping the
  # passes of the loop's several lines in step depends on it. After the last
  # filled one there is nothing to keep in step, and what is left is a column
  # rule with nothing beside it, which a reviewer read as "an empty 5th slot".
  var lastFilled = -1
  for i in 0 ..< annotation.columns.len:
    if annotation.columns[i].values.len > 0:
      lastFilled = i
  var index = 0
  for column in annotation.columns:
    if index > lastFilled:
      break
    if index >= visibleColumns:
      # The passes past the pane's edge are not drawn at all rather than drawn
      # and clipped: a column sheared in half is what every UD-1 and UD-2
      # reviewer reported, and the loop control is how the rest are reached.
      break
    let columnDom = flowValueColumnDom(
      cstring(fmt"review-flow-values-{scope}-{annotation.modelLine}-{index}"),
      columnWidthPx)
    if column.selected:
      # The debugger marks the pass the reader is on with `active-flow-step`,
      # and `flow.styl` styles the value boxes inside it; the review's band
      # marks it the same way rather than inventing a highlight.
      columnDom.setAttribute(
        cstring"class",
        cstring($columnDom.getAttribute(cstring"class") &
                " flow-loop-step-container active-flow-step"))
    columnDom.setAttribute(cstring"data-iteration", cstring($column.iteration))
    if column.values.len == 0:
      # A pass that never reached this line. Keeping the empty column is
      # what stops the next pass's values sliding under this pass's heading.
      columnDom.appendChild(flowValueEmptyDom(noFlowStyle, cstring""))
    # A column wider than the pane drops whole chips from its end rather than
    # squeezing them — see `reviewChipsThatFit`. The marker says it happened.
    let fitting = reviewChipsThatFit(column.values, chipCharBudget)
    var drawn = 0
    for chip in column.values:
      if drawn >= fitting:
        # Marked, not silent: a column that quietly showed three of four
        # values would be indistinguishable from a step that recorded three.
        #
        # `…+N` and not a bare `…`, because the ellipsis said the wrong
        # thing; and not a bare `+N` either, because inside a DIFF a leading
        # `+` reads as "one added line" — two later reviewers said so
        # independently ("in a diff `+1` reads as 'one added line'", "its
        # meaning is inference from the brief, not obvious from the UI"). The
        # ellipsis says "truncated" and the count says how much.
        # Two fresh reviewers of the design corpus, independently, reported the
        # SAME defect from it — /"Rows 1 and 3 end in `…`; row 2, identical
        # content, does not. Unstable per-row width computation."/ and /"the
        # trailing dim `…` on lines 7 and 9 … while the visually identical
        # line-8 row has no `…` … reads as inconsistent/possibly broken."/
        # Measured, the computation was neither unstable nor per-row wrong:
        # lines 8 and 10 of `main.nr` recorded THREE values and line 9 recorded
        # two, so the first two hide one and the third hides none. The rows look
        # identical because what differs is exactly what is not drawn. A count
        # says so; a bare ellipsis leaves the reader to infer a bug, which is
        # what both of them did.
        let hidden = column.values.len - drawn
        let more = flowValueEmptyDom(noFlowStyle, cstring("…+" & $hidden))
        more.setAttribute(
          cstring"class",
          cstring($more.getAttribute(cstring"class") & " review-flow-more"))
        more.setAttribute(
          cstring"title",
          cstring(fmt"{hidden} more value(s) than the pane can hold"))
        columnDom.appendChild(more)
        break
      drawn += 1
      let chipDom = flowValueContainerDom(noFlowStyle)
      let nameDom = flowValueNameDom(cstring(reviewValueChipName(chip)))
      nameDom.setAttribute(
        cstring"class",
        cstring(ReviewValueNameClass))
      chipDom.appendChild(nameDom)
      chipDom.appendChild(flowValueBoxDom(
        id = cstring(fmt"review-flow-value-{scope}-{annotation.modelLine}-{index}-{chip.name}"),
        className = cstring(ReviewValueBoxClass),
        text = cstring(chip.text),
        iteration = column.iteration,
        style = noFlowStyle))
      columnDom.appendChild(chipDom)
    host.appendChild(columnDom)
    index += 1
  # A band that shows fewer passes than the loop recorded says so.
  #
  # Without this the omission is invisible and reads as missing data: a fresh
  # reviewer, unprompted — "`let contribution = …` and `total = total +
  # contribution;` each show only one group with no `…` truncation marker, even
  # though they're nested inside the same `for i in 0..4` loop whose header row
  # directly above shows four groups — reads as missing 3 of 4 passes' data."
  # It is not missing data and it is not inconsistent: those lines' columns are
  # WIDER (`<contribution> 0` against `<i> 0`), so fewer of them fit. The
  # marker is what makes that legible instead of leaving the reader to infer a
  # bug.
  #
  # `morePassesMarker` is whether the room the columns left over holds it —
  # `reviewMorePassesMarkerFits`. It is drawn out of the slack and never out of
  # a column, so a marker saying data was not shown can never itself be the
  # reason data was not shown, and it can never be the thing drawn past the
  # pane's edge.
  let dropped = (lastFilled + 1) - index
  if dropped > 0 and morePassesMarker:
    let more = flowValueEmptyDom(noFlowStyle, cstring("…+" & $dropped))
    more.setAttribute(
      cstring"class",
      cstring($more.getAttribute(cstring"class") & " review-flow-more-passes"))
    more.setAttribute(
      cstring"title",
      cstring(fmt"{dropped} more pass(es) than fit — the loop control reaches them"))
    host.appendChild(more)

proc placeReviewValueBands*(editor: MonacoEditor; doc: DiffDocument;
                            annotations: seq[ReviewValueAnnotation];
                            scope, fontSize: int; sink: ReviewValueBandSink) =
  ## Draw the parallel value band for every annotated line of the document.
  ##
  ## Two placements, and which one is used is MEASURED rather than chosen:
  ##
  ##   * **Beside the code**, in a content widget at a common left offset —
  ##     `FlowParallel`, the placement §4.4 describes. Used whenever the pane is wide enough to hold a whole
  ##     column past the widest annotated line.
  ##   * **On its own row under the line**, in a Monaco view zone — the
  ##     placement the debugger's `FlowMultiline` mode uses
  ##     (`ui/flow.createFlowViewZone`). Used when it is not.
  ##
  ## The second is not a review-specific invention and it is not a compromise
  ## on the elements: the same band, the same columns, the same chips, moved to
  ## the row below. It exists because the diff tab is ONE PANE of a layout — in
  ## the design corpus at 1920x1080 its content area measures about 580px, and
  ## the file's own annotated lines run to 59 characters — so "past the longest
  ## line" is off the right edge, and beside-the-code placement would put every
  ## value out of sight. That is the same measurement that produced the clipped
  ## chips every UD-1 and UD-2 reviewer reported; RV-5's trailing strip did not
  ## fit either, and drew itself sheared rather than admitting it.
  ##
  ## ``annotations`` should ask for every recorded pass
  ## (``maxColumns = high(int16)``): how many are DRAWN is decided per line
  ## here, from the room that line's band has, and a cap there would be a cap
  ## on what the loop control can ever scroll to. The caller removes the
  ## previous placement's widgets and zones first (see
  ## ``ui/unified_diff.clearFlowValueWidgets``), and ``sink`` is told of each
  ## new one as it is added (``ReviewValueBandSink``).
  if editor.isNil:
    return
  let geometry = editor.reviewValueBandGeometry(fontSize, annotations)
  # Both decisions — where the band starts, and whether it goes beside the code
  # at all — are taken against the width the WIDEST annotated line's column
  # actually needs.
  #
  # `reviewValueBandFitsBeside` used to be asked against a 12-character floor,
  # which is a width no band's content is ever measured against, so the beside
  # branch accepted panes it then overflowed. Measured on `sample-review.json`
  # at 1920x1080: 210px of room past a band placed at 309px, against a column
  # needing 240px — the column was drawn at its full 230px from x=618 to x=848
  # with the pane ending at 829, and the chips that missed the 21-character
  # budget were replaced by an ellipsis, so `<y> 20` left the screen.
  #
  # What gives now is the GAP first (`reviewValueBandLeftPx`'s three-argument
  # form) and the placement only after that, because the gap is whitespace and
  # the placement is not: a row-below band is a view zone and adds its own
  # height to the document.
  let widestColumnPx =
    float(reviewWidestColumnChars(annotations)) * geometry.charWidthPx
  let bandLeftPx = reviewValueBandLeftPx(
    geometry.maxOffsetPx, geometry.contentWidthPx, widestColumnPx)
  sink.bandLeft(int(bandLeftPx))
  let beside = reviewValueBandFitsBeside(
    geometry.contentWidthPx, bandLeftPx, widestColumnPx)
  for annotation in annotations:
    if annotation.modelLine <= 0 or annotation.modelLine > doc.lines.len:
      continue
    if annotation.columns.len == 0:
      continue
    # An OWNED copy of the anchor line, for the same reason `monacoDecorations`
    # takes one: `items` over `annotations` yields `lent ReviewValueAnnotation`,
    # and the view-zone descriptor below is a `js{...}` closure that outlives
    # this iteration, so it cannot capture the borrow.
    let modelLine = annotation.modelLine
    # ONE offset for every band, in both placements.
    #
    # `beside` was decided against the WIDEST annotated line, so a band at the
    # common offset is past every line's text by construction, and a tab where
    # it would not be does not use that placement at all.
    #
    # The row-below placement started out indented to the statement above it,
    # on the reasoning that a flush row "decouples the value from the statement
    # it belongs to" — which one reviewer said in those words. Three fresh
    # reviewers of the result said the opposite and said it unanimously: the
    # varying start was "the most damaging thing here", "an inconsistent left
    # rail", "roughly four different x positions". A column a reader can scan
    # downwards is the deliverable; attribution is answered instead by the line
    # number the row carries, which is also what `ui/flow.createFlowViewZone`
    # puts at the left of the debugger's own zones.
    let lineLeft = if beside: bandLeftPx else: 0.0
    # The row-below placement spends the head of its band on the source line
    # number, so the columns have that much less room than the pane.
    let prefix =
      if beside: 0.0
      else: ReviewValueBandLinePrefixChars * geometry.charWidthPx
    let available = geometry.contentWidthPx - lineLeft - prefix
    # The column's width is decided in CHARACTERS and turned into pixels once,
    # so the box the column is drawn in and the budget its chips are measured
    # against are the same number rather than two roundings of it. That
    # identity is the fix for the second half of the defect: the budget used to
    # be `available / charWidth div visible`, which on a 210px band against a
    # 24-character column came to 21 — three characters short of the column's
    # own width, so the last chip of `<x> 10 <y> 20` was dropped and `<y> 20`
    # left the screen. It also made the budget depend on the OTHER columns'
    # widths, which is why two rows with identical content could truncate
    # differently ("rows 1 and 3 end in `…`; row 2, identical content, does
    # not").
    let drawnColumnChars = reviewDrawnColumnChars(
      reviewColumnWidthChars(annotation), available, geometry.charWidthPx)
    let columnWidth = float(drawnColumnChars) * geometry.charWidthPx
    let visible = reviewVisibleColumnCount(
      available, columnWidth, annotation.columns.len)
    # The "more passes than fit" marker is drawn out of the room the columns
    # leave over, never out of a column — see `reviewMorePassesMarkerFits`.
    let markerFits = reviewMorePassesMarkerFits(
      available, columnWidth, visible,
      float(ReviewValueMorePassesChars) * geometry.charWidthPx)
    # A ROW-BELOW band takes the WASH of the line it describes.
    #
    # It is a view zone under the line, so the diff editor paints nothing
    # behind it and it came out at the editor's own surface colour — a neutral
    # strip through the middle of a coloured block. Measured on a capture of
    # the surface before this: added line `#353F36`, band `#282828`, next added
    # line `#353F36`. Two fresh reviewers reported the consequence without
    # being asked about it — "the added-line green wash runs edge-to-edge
    # behind the code but stops at the chip row below it, so chip and highlight
    # disagree about where the line ends", and "its surface matches the editor
    # rather than the added line, making it float on the green wash".
    #
    # This resolves a genuine CONFLICT of findings rather than an unfinished
    # item: an earlier reviewer wanted the chips to stop fusing with the
    # highlight, and these two want the block to stay one block. A tinted BAND
    # under an untinted CHIP satisfies both — the wash says which line the row
    # belongs to, and the chip keeps a surface of its own to sit on. The chip
    # is already `#1B1B1B` against the band, so only the band moves.
    #
    # Not in the `beside` placement: that band is a content widget drawn ON the
    # line, so the editor's own wash is already behind it and a second copy
    # would double the tint. The PLACEMENT is written onto the host rather than
    # the wash being withheld, so which branch ran is answerable from a
    # selector — `flow.styl` scopes the wash to the row-below class, and a test
    # can name the bands it means instead of assuming a placement that the pane
    # width decides.
    let hostClasses =
      reviewValueBandWashClass(doc, annotation.modelLine) & " " &
      (if beside: ReviewValueBandBesideClass else: ReviewValueBandRowBelowClass)
    let dom = reviewValueBandDom(
      scope, annotation, lineLeft, columnWidth, available, visible, drawnColumnChars,
      markerFits, hostClasses)
    # The same id in both placements, on the DOM node as well as on the
    # widget: a test that asks "does the line that shows source line N carry a
    # band" needs to name one, and `getId` is not reachable from a selector.
    dom.setAttribute(
      cstring"id",
      cstring(fmt"review-flow-band-{scope}-{annotation.modelLine}"))
    if beside:
      # Anchored at column 1 rather than at the end of the text: the band is
      # positioned by its own `left`, so anchoring it to the line's end would
      # add that line's width to a number that is meant to be the same for
      # every line — the ragged strip, reintroduced through the back door.
      let widget = udContentWidget(
        cstring(fmt"review-flow-band-{scope}-{annotation.modelLine}"),
        dom, annotation.modelLine)
      editor.udAddContentWidget(widget)
      sink.widget(widget)
    else:
      # The source line the row describes, drawn where the gutter's own numbers
      # are.  `ui/flow.createFlowViewZone` prefixes the debugger's zones with a
      # `.line-numbers` element for the same reason: a row under a line is only
      # unambiguous while no two annotated lines are adjacent, and in a review
      # they usually are.  Three reviewers found the ambiguity — "it fails at
      # line 9, line 47, and wherever two annotated lines sit adjacent".
      let number = document.createElement(cstring"div")
      # NOT the editor's own `line-numbers` class. Monaco and
      # `styles/index.styl` both style that selector for the gutter's own
      # absolutely positioned column, and borrowing it inside a flex row took
      # the band out of its zone. The look is restated in
      # `.review-flow-band-line` instead — which is a handful of declarations,
      # against a layout that silently breaks.
      number.setAttribute(cstring"class", cstring"review-flow-band-line")
      number.appendChild(document.createTextNode(
        cstring($annotation.sourceLine)))
      # Into the BAND, not into the host: the host has no layout of its own, so
      # a sibling of the band there is a block above it and the band is pushed
      # out of the zone's height onto the next code line. Measured on the
      # captured surface, that is exactly what happened — two reviewers of it
      # reported chips "drawn directly on top of the code glyphs at the same
      # baseline" and "two chip groups stacked in the same pixels".
      let bandNode = dom.firstChild
      bandNode.insertBefore(number, bandNode.firstChild)
      # Tall enough for the chip, which is not a line of text: a
      # `.ct-omni-value` carries `padding: 0.25em 0.5em` and its name half
      # another 3px below, so at a 13px font the pill is around 30px against a
      # ~20px line. A zone sized for the FONT let the pill spill onto the code
      # rows either side, which two reviewers reported in the same terms —
      # "pill tops clip the `{` of `for i in 0..4 {`", "pills overlap the lines
      # above and below by 2-4px".
      #
      # EXACTLY one code row, asked of Monaco rather than derived from the
      # font size.
      #
      # The clearance used to be `fontSize + 22`, set by adding until nothing
      # spilled, and it overshot: measured on a capture, the band came out
      # 36-37px against a 23px code row, and a reviewer put the cost plainly —
      # "the baseline rhythm skips 11px mid-hunk", "a 3-line addition doesn't
      # read as one block". Three annotated lines of a loop body cost more
      # vertical space than the code they annotate.
      #
      # A row is the right height because the band IS a row: it stands in for
      # the line above it and a reader scans the two together. `udLineHeight`
      # asks the editor, because the line height is Monaco's own answer to the
      # font, the font family and the zoom, and `fontSize + n` is a guess at
      # all three. The chip is made to fit it in `flow.styl` — a chip that
      # spilled onto the rows either side was a real defect twice, so the two
      # halves of this are deliberately kept next to each other in the comments.
      let lineHeight = editor.udLineHeight()
      sink.zone(editor.udAddViewZone(js{
        afterLineNumber: modelLine,
        heightInPx: if lineHeight > 0: lineHeight else: fontSize + 16,
        domNode: dom
      }))

# ---------------------------------------------------------------------------
# The editor
# ---------------------------------------------------------------------------

proc reviewDiffEditorOptions*(theme: cstring; contextLineCount, fontSize: int;
                              fontFamily: cstring): JsObject =
  ## The options a review's diff editor is created with
  ## (`monaco.editor.createDiffEditor`): Monaco's diff editor in its inline
  ## layout, read-only, collapsing the unchanged regions to
  ## `contextLineCount` lines around each change
  ## (`diff_document.diffContextLineCount`).
  js{
    # UD-1: the unified view is Monaco's diff editor with the side-by-side
    # layout turned off.  Everything the old synthetic document could not do
    # follows from the editor now owning both revisions:
    #   * a tokenizer runs, because each model has a real language;
    #   * the intra-line marking is computed, because there is a before and an
    #     after to compare.
    renderSideBySide: false,
    # ... and stays off.  Monaco otherwise silently switches to the two-pane
    # layout whenever the tab is wider than `renderSideBySideInlineBreakpoint`,
    # which would make the view's identity depend on the window size.
    useInlineViewWhenSpaceIsLimited: false,
    # VCS-Panel.md requires `+` / `-` gutter markers, and there must be
    # exactly one set of them.  Ours are in the gutter LABEL since UD-1
    # (`diff_document.lineNumberLabels` emits `+42` / `-41` / ` 40`, coloured
    # by the `lineNumberClassName` decoration), because the line-decorations
    # lane they used to live in does not fit in the inline diff's original
    # editor — see `applyGutterOptions`.  Monaco's own indicators are
    # therefore turned off rather than stacked on top of them, which is what
    # put a codicon and a `+` in the same 12 pixels.
    renderIndicators: false,
    # Neither side is writable: DeepReview-GUI.md §5.1, "Keep the review
    # representation read-only by default", and a diff buffer has nowhere to
    # write back to.  `originalEditable` defaults to false; it is stated
    # because the *modified* side is the one `readOnly` covers.
    readOnly: true,
    originalEditable: false,
    domReadOnly: true,
    # The gutter's revert arrows and its context menu are write gestures.
    renderMarginRevertIcon: false,
    renderGutterMenu: false,
    # `advanced` is Monaco's current diffing algorithm and the one that
    # produces the word-level marking this milestone is about; `legacy` is
    # kept only for compatibility.
    diffAlgorithm: cstring"advanced",
    # Whitespace-only changes are changes in a code review.
    ignoreTrimWhitespace: false,
    # UD-2: the models are the whole file, and this is what decides which of
    # its lines are on screen.  It is the tab's ONLY notion of that window —
    # DR-R5's per-hunk slice was removed rather than kept beside it.
    #
    #   * `contextLineCount` is computed per document rather than fixed at
    #     three, because the `@@` divider is an unchanged line and three would
    #     collapse it out of sight behind the hunk's own context lines
    #     (`diff_document.diffContextLineCount` explains the arithmetic).
    #   * `revealLineCount` is `ContextExpandStep`, the same amount §4.2's
    #     button used to reveal, so a click, a drag-less press, a keypress and
    #     the menu's first item all move by one increment.
    hideUnchangedRegions: js{
      enabled: true,
      contextLineCount: contextLineCount,
      minimumLineCount: DiffMinimumLineCount,
      revealLineCount: ContextExpandStep
    },
    theme: theme,
    automaticLayout: true,
    folding: false,
    fontSize: fontSize,
    fontFamily: fontFamily,
    # The affordances a DOM diff could not offer, and the reason DR-R4 exists.
    #
    # `renderCharacters` and the column cap are UD-4's: a 52-line corpus fills
    # the whole minimap with block glyphs, and a reviewer read the result as
    # "a flat mid-grey ~#555 slab, far lighter than the #1e1e1e/#252526
    # palette … reads as a misplaced scrollbar". Character shapes break the
    # slab up into something that looks like the file it is a map of, and the
    # cap keeps the map from claiming width the code needs — this tab is ONE
    # PANE of a layout, not a window.
    minimap: js{
      enabled: true,
      renderCharacters: true,
      maxColumn: 60,
      showSlider: cstring"mouseover"
    },
    # ONE navigation rail on the right, not two.
    #
    # A diff editor draws its own overview ruler beside the code editor's, and
    # in the INLINE layout the two are redundant — the same change is marked
    # twice, at different x and, because the two rulers scale differently, at
    # different y. A reviewer measured exactly that: "two overview rulers side
    # by side in #484848 … the red and green mark for the *same* change sit at
    # different x and different y", and another read the pair as "two rails
    # where one is needed". The code editor's own ruler carries the diff
    # decorations' `overviewRuler` marks, so dropping the diff editor's loses
    # no information.
    renderOverviewRuler: false,
    contextmenu: true,
    renderLineHighlight: cstring"none",
    scrollBeyondLastLine: false,
    glyphMargin: false
  }

proc applyReviewDiffGutterOptions*(editor, originalEditor: MonacoEditor;
                                   labels, originalLabels: seq[cstring];
                                   width: int) =
  ## Give each side of the diff editor its own dual old/new gutter.
  ##
  ## Per side rather than once on the diff editor, because a diff editor's
  ## options are handed to both of its code editors and the two models are
  ## renumbered independently: one callback would label the deleted lines with
  ## the *modified* model's numbers, which is how a removed line ends up
  ## claiming the line number of whatever now stands in its place.
  ##
  ## The width is shared (``lineNumberColumnWidth``) so the two columns are the
  ## same size and read as one gutter rather than two.
  ##
  ## ``lineDecorationsWidth: 0`` on the ORIGINAL editor, with the `+` / `-`
  ## marker carried inside the label instead
  ## (``diff_document.lineNumberLabels``).  Monaco sizes the *original* editor
  ## of an inline diff from its ``lineNumbersMinChars`` alone — measured: 3
  ## characters produced a 29px strip around a 65px margin — so a decorations
  ## lane beside the numbers there is not clipped gracefully, it takes the
  ## numbers off screen with it, and a reviewer reported the deleted lines as
  ## unnumbered.
  ##
  ## The MODIFIED editor keeps a lane, and it is half of the gap between the
  ## last digit and the first glyph of the code.  Measured on the running
  ## product with the lane at zero: the label's glyphs ran ``292..317.7`` and
  ## the code started at ``321`` — 3.3px, under half a character, which every
  ## reviewer of every round has read as a collision ("`+ 7fn scale(`",
  ## "`10def format_row`").
  ##
  ## The OTHER half is the `padding-right` on `.line-numbers` in
  ## `styles/components/unified_diff.styl`, and the two are deliberately the
  ## same number.  The reason they need each other is written out there: a
  ## global rule makes `.line-numbers` span the whole margin, so the padding is
  ## what holds the digits off the code — but the padding only holds while the
  ## label still fits the box it shrinks, and the label is exactly
  ## ``lineNumbersMinChars`` characters.  This lane is what buys back the room
  ## the padding spends.  Change one and the other has to move with it.
  ##
  ## The lane draws nothing — ``.ct-diff-gutter-*::before`` is an empty
  ## `content` since UD-1 — so what it contributes is exactly its width.
  ## `width` is `diff_document.lineNumberColumnWidth` of the pair, and
  ## `labels` / `originalLabels` its `lineNumberLabels` for each side.
  # One character at the review's font size (the advance measures 8.57px):
  # enough that the digits and the code read as two columns, small enough that
  # the rail is not a third one.
  const ModifiedLineDecorationsWidth = 8
  # A few pixels above line 1.  UD-2's collapsed-region boundary is drawn by
  # Monaco with `transform: translateY(-10px)`, so a region that begins at the
  # file's first line has its upper drag handle *above* the editor's clipping
  # edge and is cut in half — measured, and reported by a design reviewer as
  # "a rule below but none above".  The padding is what gives that handle
  # somewhere to be.
  # `bottom` reserves the horizontal scrollbar's own height.
  #
  # Monaco draws that bar as an overlay at the bottom of the content, and with
  # `scrollBeyondLastLine: false` the last line is exactly there — so the
  # control that reveals a long line was drawn on top of it. Measured by a
  # reviewer of the view that exists to show this: "a horizontal scrollbar thumb
  # at the pane's bottom … it lies *on top of* the assert line, greying out
  # `assert(final_result == expected,`", and "only 15px of its 20px line height
  # is inside the pane". Twelve pixels of reserved space is the bar's 10px plus
  # a hairline either side.
  let padding = js{ top: 10, bottom: 12 }
  # The horizontal scrollbar, set on the CODE editor rather than on the diff
  # editor.
  #
  # `createDiffEditor` takes the code editors' options too, and most of them do
  # reach both sides — but `scrollbar` set there did not, measured: with
  # `scrollbar: { horizontal: "visible" }` in the diff editor's own option bag,
  # a reviewer of the resulting capture found "no horizontal scrollbar,
  # gradient, or `…` anywhere along the right edge", and the only right-edge
  # element was the VERTICAL slider. So it is applied here, where the option
  # unambiguously belongs to the editor that scrolls.
  #
  # `visible` and not the default `auto`: `auto` fades the bar out whenever the
  # pointer is elsewhere, which is the state a reader is in for all of the time
  # they spend reading. Every reviewer of every view has reported the shear —
  # "cut mid-glyph, no ellipsis, no fade, no visible scroll affordance" — and a
  # persistent bar is what VS Code's diff shows in the same place, so the
  # overflow becomes discoverable without inventing an affordance of our own.
  let scrollbar = js{
    horizontal: cstring"visible",
    horizontalScrollbarSize: 10,
    horizontalSliderSize: 10,
    useShadows: true
  }
  editor.udUpdateOptions(js{
    lineNumbers: udLineNumberFn(labels),
    lineNumbersMinChars: width,
    lineDecorationsWidth: ModifiedLineDecorationsWidth,
    padding: padding,
    scrollbar: scrollbar
  })
  if not originalEditor.isNil:
    originalEditor.udUpdateOptions(js{
      lineNumbers: udLineNumberFn(originalLabels),
      lineNumbersMinChars: width,
      lineDecorationsWidth: 0,
      padding: padding
    })


type
  ReviewDiffEditorRefs* = tuple[diffEditor, originalModel: js]
    ## A diff editor and its original model, as their owner holds them now.

proc udModelIsDisposed*(model: js): bool {.importjs: """
  (function(m) {
    return !!(m && typeof m.isDisposed === 'function' && m.isDisposed());
  })(#)""".}
  ## Whether a Monaco text model has been disposed (`ITextModel.isDisposed`,
  ## https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.ITextModel.html#isDisposed).
  ## A model without the method answers `false`.

proc scheduleReviewDeletedLineTokens*(current: proc(): ReviewDiffEditorRefs;
                                      hostId: cstring; attempt: int) =
  ## Repaint the deleted lines with their syntax tokens, once they have any.
  ##
  ## ``current`` answers the diff editor and the original model their owner
  ## holds at the moment it is called, and it is called again on EVERY
  ## attempt. The attempts run for up to 3 s, and in that window the owner
  ## may dispose its editor (``unified_diff.resetEditor``) and create another
  ## (``initEditor``). An editor and a model captured at the first attempt
  ## would by then be disposed, and Monaco throws "Model is disposed!" from
  ## ``getLineCount`` on a disposed model, inside a timer where nothing
  ## catches it. Asking each time ends the chain when the owner holds
  ## nothing, and follows a re-created editor, as the diff tab did when it
  ## read ``self.diffEditor`` on each attempt. A model that is disposed but
  ## still held (an owner that disposes before it clears) ends it too.
  ##
  ## Three facts, all measured in the running product, force this shape:
  ##
  ##   1. Monaco builds each deleted line's view zone out of the ORIGINAL
  ##      model's tokens at the instant the diff first renders, and never
  ##      rebuilds it when tokenization catches up — `getLineTokens` is read
  ##      inside that computation, and nothing in it observes token changes.
  ##   2. So the tokens are not the problem and forcing them earlier does not
  ##      help. By the time a reader looks, the original model's line 4
  ##      (`  let y = x * 2;`) reports nine tokens with foregrounds
  ##      `[1,23,1,25,1,25,1,34,25]` — and the zone rendered from it is one
  ##      `mtk1` run.
  ##   3. Invalidating the diff rebuilds the zone, and the rebuilt zone is
  ##      coloured (`mtk1 mtk23 mtk25 mtk34 mtk17` on that same line).
  ##
  ## Hence: wait for a zone to exist, and repaint it only if it is monochrome.
  ## Bounded like `scheduleLoopSliders`, and self-verifying rather than fired
  ## blind — a nudge issued before the first render invalidates nothing, and a
  ## fixed point that keeps re-nudging would recompute the diff forever.
  const MaxAttempts = 20
  if attempt >= MaxAttempts or current.isNil:
    return
  let (diffEditor, originalModel) = current()
  if diffEditor.isNil or originalModel.isNil or originalModel.udModelIsDisposed():
    return
  let classes = udDeletedLineTokenClasses(hostId)
  if classes > 1:
    # Already coloured — either the repaint landed or this diff never needed
    # one. Either way there is nothing left to do and nothing to retry.
    return
  if classes == 1:
    originalModel.udForceTokenization(DiffTokenizeLineLimit)
    diffEditor.udRebuildDeletedLineZones()
  # `classes == -1` is "no deleted line has rendered yet", which is the normal
  # state for the first few frames and is also the permanent state of a diff
  # that only adds lines. The attempt budget is what tells the two apart
  # without having to ask which one this is.
  discard setTimeout(
    proc() = scheduleReviewDeletedLineTokens(current, hostId, attempt + 1),
    150)


# ---------------------------------------------------------------------------
# The document
# ---------------------------------------------------------------------------

proc reviewText[T](s: T): string =
  ## A dataset string as Nim text: the application's dataset carries
  ## `cstring`s, which may be nil, the native one `string`s.
  when T is cstring:
    if s.isNil: "" else: $s
  else:
    s

proc reviewDiffFileRow*[F](file: F; fileIndex: int;
                           sourceLines: seq[string]): VCSDiffFileRow =
  ## One reviewed file's hunks in the ViewModel's row shape
  ## (`VCSDiffFileRow`), which `diff_document.buildDiffPair` turns into the
  ## two model texts. `fileIndex` is the file's index in the review's files,
  ## the identity a hunk selection names; `sourceLines` the file's full text
  ## (`context_expansion.sourceTextLines` of its `sourceContent`), which the
  ## whole-file models are built from.
  var hunks: seq[VCSHunkRow] = @[]
  for hunk in file.diff.hunks:
    var lines: seq[VCSDiffLineRow] = @[]
    for line in hunk.lines:
      lines.add(VCSDiffLineRow(
        lineType: reviewText(line.`type`),
        content: reviewText(line.content),
        oldLine: line.oldLine,
        newLine: line.newLine))
    hunks.add(VCSHunkRow(
      oldStart: hunk.oldStart,
      oldCount: hunk.oldCount,
      newStart: hunk.newStart,
      newCount: hunk.newCount,
      lines: lines))
  VCSDiffFileRow(
    fileIndex: fileIndex,
    status: reviewText(file.diff.status),
    path: reviewText(file.path),
    additions: file.diff.linesAdded,
    deletions: file.diff.linesRemoved,
    hunks: hunks,
    sourceLines: sourceLines)

proc reviewDiffLineLabels*(pair: DiffPair):
    tuple[labels, originalLabels: seq[cstring]] =
  ## The dual old/new gutter labels of both models
  ## (`diff_document.lineNumberLabels`), for `applyReviewDiffGutterOptions`.
  # The NUMBER column's width; `lineNumberColumnWidth` adds the marker's
  # character on top of it for the option Monaco is given.
  let width = max(lineNumberWidth(pair.original), lineNumberWidth(pair.modified))
  for label in lineNumberLabels(pair.modified, dsModified, width):
    result.labels.add(cstring(label))
  for label in lineNumberLabels(pair.original, dsOriginal, width):
    result.originalLabels.add(cstring(label))
