import ui_imports, ../types, ../ui_helpers, ../renderer

const NO_LINE = -1

proc isNoirProject(): bool =
  data.services.debugger.location.path.split(".")[^1] == "nr"

proc formatLine(instruction: Instruction): cstring =
  var name =
    if $instruction.name == "":
      "<no instructions>"
    elif $instruction.offset == "-1":
      "<no step id>"
    else:
      $instruction.name
  let offset =
    if isNoirProject():
      fmt"StepId({instruction.offset})"
    else:
      $instruction.offset

  cstring(
    align(offset, 4, ' ') & " " & alignLeft($name, 10, ' ') & alignLeft($instruction.args, 10, ' ') & alignLeft($instruction.other, 0, ' ')
  )

proc createViewZone(self: LowLevelCodeComponent, position: int, lineHeight: int, highLevelLine: int): Node =
  let instruction = self.editor.tabInfo.instructions.instructions[position]
  var zoneDom = document.createElement("div")

  zoneDom.id = fmt"high-level-view-zone-{position}"
  zoneDom.class = "high-level-view-zone high-level-content-widget"
  zoneDom.style.display = "flex"

  let textDom = document.createElement("span")
  textDom.class = "high-level-line"

  if not data.ui.editors[instruction.highLevelPath].tabInfo.isNil:
    let sourceCode = data.ui.editors[instruction.highLevelPath].tabInfo.sourceLines[highLevelLine-1]
    textDom.innerHTML = fmt"{highLevelLine}| {sourceCode}"
    zoneDom.appendChild(textDom)

  let viewZone = js{
    afterLineNumber: position,
    heightInPx: lineHeight + 3,
    domNode: zoneDom
  }

  var zoneID: int

  if not self.editor.monacoEditor.isNil:
    self.editor.monacoEditor.changeViewZones do (view: js):
      var zoneId = cast[int](view.addZone(viewZone))
      zoneID = zoneId
      self.viewZones[position] = zoneId

  self.multiLineZones[position] = MultilineZone(dom: zoneDom, zoneId: zoneID, variables: JsAssoc[cstring, bool]{})

  return zoneDom

proc mapInstructions(self: LowLevelCodeComponent, tabInfo: TabInfo) =
  var prevLine = NO_LINE
  var prevPath = cstring""

  for i, instruction in tabInfo.instructions.instructions:
    if prevLine != instruction.highLevelLine or prevPath != instruction.highLevelPath:
      self.instructionsMapping[i] = instruction.highLevelLine

    prevLine = instruction.highLevelLine
    prevPath = instruction.highLevelPath

proc setViewZones(self: LowLevelCodeComponent) =
  for line, hLine in self.instructionsMapping:
    if not self.editor.monacoEditor.isNil and not self.multiLineZones.hasKey(line):
      let lineHeight = self.editor.monacoEditor.config.lineHeight
      let newZoneDom = createViewZone(self, line, lineHeight, hLine)

      self.viewDom[line] = newZoneDom

proc findHighlight(self: LowLevelCodeComponent, selectedLine: int): int =
  for key, val in self.instructionsMapping:
    if val == selectedLine:
      return key + 1

  return -1

proc getAsmCode(self: LowLevelCodeComponent, location: types.Location) {.async.} =
  var tabInfo = TabInfo(
    name: self.editor.name,
    location: location,
    loading: false,
    noInfo: false,
    lang: LangAsm,
  )

  tabInfo.instructions = await data.services.editor.asmLoad(location)
  tabInfo.sourceLines = tabInfo.instructions.instructions.mapIt(formatLine(it))
  tabInfo.source = tabInfo.sourceLines.join(jsNl) & jsNl
  self.editor.tabInfo = tabInfo
  self.mapInstructions(tabInfo)

  discard setTimeout(proc() =
    self.setViewZones()
    self.data.redraw(),
    50
  )

  self.editor.tabInfo.highlightLine = self.findHighlight(location.highLevelLine)
  self.data.redraw()

proc clear(self: LowLevelCodeComponent, location: types.Location) =
  self.editor.tabInfo = nil

  if location.path != self.path:
    self.editor = EditorViewComponent(
      id: data.generateId(Content.EditorView),
      path: location.path,
      data: data,
      lang: LangAsm,
      name: location.path,
      editorView: ViewLowLevelCode,
      tokens: JsAssoc[int, JsAssoc[cstring, int]]{},
      decorations: @[],
      whitespace: Whitespace(character: WhitespaceSpaces, width: 2),
      encoding: cstring"UTF-8",
      lastMouseMoveLine: -1,
      traces: JsAssoc[int, TraceComponent]{},
      expanded: JsAssoc[int, EditorViewComponent]{},
      service: data.services.editor,
      viewZones: JsAssoc[int, int]{},
    )

  self.viewZones = JsAssoc[int, int]{}
  self.instructionsMapping = JsAssoc[int, int]{}
  self.multilineZones =  JsAssoc[int, MultilineZone]{}
  self.path = location.path

  for _, dom in self.viewDom:
    discard jsDelete(dom)

  self.viewDom = JsAssoc[int, kdom.Node]{}

proc reloadLowLevel*(self: LowLevelCodeComponent) =
  self.clear()
  discard self.getAsmCode(data.services.debugger.location)

method onCompleteMove*(self: LowLevelCodeComponent, response: MoveState) {.async.} =
  if response.location.path != "":
    self.clear(response.location)
    discard self.getAsmCode(response.location)

method render*(self: LowLevelCodeComponent): VNode =
  if self.editor.renderer.isNil:
    self.editor.renderer = kxiMap[fmt"lowLevelCodeComponent-{self.id}"]

  if self.editor.tabInfo.isNil: #  or self.editor.tabInfo.instructions.instructions.len() == 0
    discard self.getAsmCode(data.services.debugger.location)

  result = buildHtml(
    tdiv(class = componentContainerClass("low-level-code"))
  ):
    render(self.editor)
