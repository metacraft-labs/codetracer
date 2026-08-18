import std / [ jsffi ],
  dom, kdom

type
  Monaco* = ref object of js
    editor*: MonacoEditorLib

  MonacoEditorLib* = ref object
    create*: proc(element: dom.Element, options: MonacoEditorOptions): MonacoEditor
    createDiffEditor*: proc(element: dom.Element, options: MonacoEditorOptions): DiffEditor
    createModel*: proc(value: cstring, language: cstring, uri: js = jsUndefined): MonacoTextModel
    # based on monaco signature
    defineTheme*: proc(themeName: cstring, themeData: js)

  MonacoEditorOptions* = ref object
    value*:                  cstring
    language*:               cstring
    automaticLayout*:        bool
    theme*:                  cstring
    readOnly*:               bool
    lineNumbers*:            proc(line: int): cstring
    fontSize*:               int
    fontFamily*:             cstring
    fontLigatures*:          bool
    contextmenu*:            bool
    minimap*:                JsObject
    renderIndentGuides*:     bool
    find*:                   JsObject
    scrollbar*:              JsObject
    lineNumbersMinChars*:    int
    lineDecorationsWidth*:   int
    renderLineHighlight*:    cstring
    glyphMargin*:            bool
    folding*:                bool
    showFoldingControls*:    cstring
    scrollBeyondLastColumn*: int
    overflowWidgetsDomNode*: JsObject
    fixedOverflowWidgets*:   bool
    fastScrollSensitivity*:  int
    scrollBeyondLastLine*:   bool
    smoothScrolling*:        bool
    mouseWheelScrollSensitivity*: int

    # Diff editor options:
    renderSideBySide*:       bool
    renderOverviewRuler*:    bool

  MonacoScrollType* = enum Smooth, Immediate

  MonacoContent* = enum EXACT, ABOVE, BELOW

  DeltaDecoration* = ref object
    `range`*:         MonacoRange
    options*:         js

  MonacoTextModel* = ref object
    uri*:                 js
    getLineMaxColumn*:     proc(line: int): int
    getLineFirstNonWhitespaceColumn*: proc(line: int): int
    getLineContent*:       proc(line: int): cstring
    getLineCount*:         proc(): int
    findMatches*:          proc(searchString: cstring,
                                searchOnlyEditableRange: bool,
                                isRegex: bool,
                                matchCase: bool,
                                captureMatches: bool): js
    getValue*:             proc(): cstring
    applyEdits*:           proc(operations: seq[js]): void
    getValueInRange*:      proc(`range`: MonacoRange, endOfLinePreference: int = 0): cstring
    getVersionId*:         proc(): int

  MonacoEditorLayoutInfo* = ref object
    contentLeft*: int
    contentWidth*: int
    height*: int
    minimapWidth*: int
    minimapLeft*: int
    width*: int

  MonacoEditorConfig* = ref object
    layoutInfo*: MonacoEditorLayoutInfo
    lineHeight*: int

  MonacoPossibleOptionConfig* = ref object
    minimap*: MonacoMinimapConfig
    # copied from MonacoEditorLayoutConfig
    contentLeft*: int
    contentWidth*: int
    height*: int
    width*: int
    lineHeight*: int
    fontSize*: int
    decorationsLeft*: int

  MonacoMinimapConfig* = ref object
    minimapWidth*: int
    minimapLeft*: int

  MonacoSelection* = ref object
    startColumn*:     int
    endColumn*:       int
    startLineNumber*: int
    endLineNumber*:   int

  MonacoRange* = ref object
    startColumn*:     int
    endColumn*:       int
    startLineNumber*: int
    endLineNumber*:   int

  MonacoViewModel* = ref object
    hasFocus*:        bool

  MonacoEditOperation* = ref object
    forceMoveMarkers*: bool
    `range`*:          MonacoRange
    text*:             cstring

  DiffEditor* = ref object
    config*:              MonacoEditorConfig
    layout*:              proc(layout: js)
    hasTextFocus*:        proc: bool
    domElement*:          kdom.Node
    updateOptions*:       proc(options: MonacoEditorOptions)
    getModifiedEditor*:   proc: MonacoEditor
    getOriginalEditor*:   proc: MonacoEditor
    viewModel*:           MonacoViewModel
    getOptions*:          proc: JsObject

  MonacoEditor* = ref object
    config*:               MonacoEditorConfig
    getValue*:             proc: cstring
    focus*:                proc()
    layout*:               proc(layout: js)
    setValue*:             proc(code: cstring)
    deltaDecorations*:     proc(first: seq[cstring], second: seq[DeltaDecoration]): seq[cstring]
    addCommand*:           proc(keyCode: int, f: (proc: void))
    revealLine*:           proc(line: int, scrollType: MonacoScrollType = Smooth)
    addAction*:            proc(action: js)
    addContentWidget*:     proc(widget: js)
    addOverlayWidget*:     proc(widget: js)
    domElement*:           kdom.Node
    changeViewZones*:      proc(handler: proc(view: js))
    revealLineInCenter*:   proc(line: int, scrollType: MonacoScrollType = Smooth)
    setPosition*:          proc(position: MonacoPosition)
    revealLineInCenterIfOutsideViewport*: proc(line: int, scrollType: MonacoScrollType = Smooth)
    decorations*:          seq[cstring]
    statusWidget*:         js
    removeContentWidget*:  proc(widget: js)
    # getModel*:             proc: js
    onMouseDown*:          proc(handler: proc(ev: js))
    onMouseWheel*:         proc(handler: proc(ev: js))
    onContextMenu*:        proc(handler: proc(ev: js))
    onMouseMove*:          proc(handler: proc(ev: JsObject))
    onDidScrollChange*:    proc(handler: proc(ev: js))
    getAction*:            proc(a: cstring): js
    onKeyDown*:            js #proc(e: js)
    onDidChangeModelContent*:    proc(handler: proc(event: JsObject) {.closure.}): void
    hasTextFocus*:         proc: bool
    setModel*:             proc(model: MonacoTextModel)
    updateOptions*:        proc(options: MonacoEditorOptions)
    dispose*:              proc: void
    # cursor*:               MonacoCursor
    getPosition*:          proc: MonacoPosition {.noSideEffect.}
    getOptions*:           proc: JsObject
    getOption*:            proc(option: int): MonacoPossibleOptionConfig
    getVisibleRanges*:     proc: js
    getOffsetForColumn*:   proc(line: int, column: int): int
    getModel*:             proc: MonacoTextModel
    getSelection*:         proc: MonacoSelection
    trigger*:              proc(source: cstring, handlerId: cstring)
    viewModel*:            MonacoViewModel
    executeEdits*:         proc(source: cstring, edits: seq[MonacoEditOperation]): void

  MonacoPosition* = ref object
    lineNumber*:           int
    column*:               int

  MonacoLineStyle* = object
    line*: int
    class*: cstring
    inlineClass*: cstring
    afterContent*: cstring
      ## Text to inject after the line's own text, as a real inline span inside
      ## the line's DOM (Monaco's `IModelDecorationOptions.after`).  Nil for the
      ## ordinary case, which is a decoration that only *styles* existing text.
      ##
      ## This is how the Omniscience value chips reach a line that has no
      ## `FlowComponent` behind it — a review's, whose values come from the
      ## exported dataset rather than from a loaded recording.  It is NOT a
      ## channel for comment-shaped annotations: `afterClass` carries the
      ## standard flow chip classes and the content is the value, never
      ## `// name = value`.
    afterClass*: cstring
      ## `inlineClassName` of the injected span.  Meaningless without
      ## `afterContent`.

const
  # monaco option const
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#layoutInfo
  LAYOUT_INFO* = 165
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#lineHeight
  LINE_HEIGHT* = 75
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#fontInfo
  FONT_INFO* = 59

proc newMonacoRange*(startLineNumber: int, startColumn: int, endLineNumber: int, endColumn: int): MonacoRange {.importcpp: "new monaco.Range(#, #, #, #)".}
