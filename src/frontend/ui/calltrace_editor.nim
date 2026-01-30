import ui_imports, value, editor, ../types

proc openNewCall(self: CalltraceEditorComponent, name: cstring, location: types.Location) =
  let callId = name
  var editor = self.data.makeEditorViewComponent(
    self.data.generateId(Content.EditorView),
    location.path,
    1,
    callId,
    ViewCalltrace,
    false,
    (types.Location)(),
    self.data.trace.lang)

  discard data.services.editor.tabLoad(
    location,
    ViewCalltrace,
    self.data.trace.lang)

  editor.contentItem = nil # tabs[state.fullPath]
  editor.renderer = kxiMap[cstring"calls"] # TODO calls-{id}?

proc callView(self: CalltraceEditorComponent, location: types.Location): VNode =
  let name = location.path & cstring":" & location.functionName & cstring"-" & location.key

  if not self.data.ui.editors.hasKey(name):
    if not self.loading.hasKey(name):
      self.loading[name] = true
      self.openNewCall(name, location)
    buildHtml(tdiv(class="calltrace-editor-call")):
      text "loading"
  else:
    var editor = self.data.ui.editors[name]
    let editorNode = editor.render()
    buildHtml(tdiv(class="calltrace-editor-call")):
      editorNode

method render*(self: CalltraceEditorComponent): VNode =
  result = buildHtml(tdiv(class=componentContainerClass("calltrace-editor")))
