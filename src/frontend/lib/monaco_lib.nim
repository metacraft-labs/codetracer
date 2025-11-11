import std / [ jsffi ],
  dom, kdom

type
  Monaco* = ref object of js
    editor*: MonacoEditorLib

  MonacoEditorLib* = ref object
    create*: proc(element: dom.Element, options: MonacoEditorOptions): MonacoEditor
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
    contextmenu*:            bool
    minimap*:                JsObject
    find*:                   JsObject
    scrollbar*:              JsObject
    lineDecorationsWidth*:   int
    renderLineHighlight*:    cstring
    glyphMargin*:            bool
    folding*:                bool
    scrollBeyondLastColumn*: int
    overflowWidgetsDomNode*: JsObject
    fixedOverflowWidgets*:   bool
    fastScrollSensitivity*:  int
    scrollBeyondLastLine*:   bool
    smoothScrolling*:        bool
    mouseWheelScrollSensitivity*: int

  MonacoScrollType* = enum Smooth, Immediate

  MonacoContent* = enum EXACT, ABOVE, BELOW

  DeltaDecoration* = ref object
    `range`*:         MonacoRange
    options*:         js

  MonacoTextModel* = ref object
    getLineMaxColumn*:     proc(line: int): int
    getLineFirstNonWhitespaceColumn*: proc(line: int): int
    getLineContent*:       proc(line: int): cstring
    findMatches*:          proc(searchString: cstring,
                                searchOnlyEditableRange: bool,
                                isRegex: bool,
                                matchCase: bool,
                                captureMatches: bool): js
    getValue*:             proc(): cstring
    applyEdits*:           proc(operations: seq[js]): void
    getValueInRange*:      proc(`range`: MonacoRange, endOfLinePreference: int = 0): cstring

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
    onDidChangeModelContent*:    proc(handler: proc: void): void
    hasTextFocus*:         proc: bool
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

const
  # monaco option const
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#layoutInfo
  LAYOUT_INFO* = 144
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#lineHeight
  LINE_HEIGHT* = 67

proc newMonacoRange*(startLineNumber: int, startColumn: int, endLineNumber: int, endColumn: int): MonacoRange {.importcpp: "new monaco.Range(#, #, #, #)".}
