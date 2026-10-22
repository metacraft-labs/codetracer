## ui/calltrace.nim — the Call Trace pane's component.
##
## On the desktop and the web page the pane is the session's `CalltraceVM`,
## rendered by its one generic view, which the panel host mounts into the
## container GoldenLayout creates (`ui/panel_host`). The store loads the
## sections the pane's viewport asks for and decodes the answers itself. What
## is left for this component is to be the target of the keys the renderer
## routes to the focused pane, and to hand each to the ViewModel's keyboard
## navigation (`calltrace_navigation`) — the same moves on every front-end.
##
## The VS Code extension's webviews still use the stub-store component in
## `ui/calltrace_extension.nim`.

when defined(ctInExtension):
  import ./calltrace_extension
  export calltrace_extension
else:
  import ui_imports, ../communication

  import ./panel_host
  import ../viewmodel/session_vm
  import ../viewmodel/viewmodels/calltrace_navigation
  from ../viewmodel/viewmodels/calltrace_vm import CalltraceVM

  proc paneVM(): CalltraceVM =
    ## The ViewModel the pane renders: the shown session's.
    let session = panelSession()
    if session.isNil: nil else: session.calltraceVM

  method register*(self: CalltraceComponent, api: MediatorWithSubscribers) =
    ## No subscriptions: the pane's data is the session's store.
    self.api = api

  proc registerCalltraceComponent*(component: CalltraceComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
    component.register(api)

  method onUp*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.moveSelection(-1)

  method onDown*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.moveSelection(1)

  method onLeft*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.selectParent()

  method onRight*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.selectFirstChild()

  method onEnter*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.activateSelected()

  method onPageUp*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.pageSelection(-1)

  method onPageDown*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.pageSelection(1)

  method onGotoStart*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.selectFirst()

  method onGotoEnd*(self: CalltraceComponent) {.async.} =
    let vm = paneVM()
    if not vm.isNil: vm.selectLast()

  method onFocus*(self: CalltraceComponent) {.async.} =
    ## Focusing the pane selects the first visible call when nothing is
    ## selected, so the arrow keys have somewhere to start.
    let vm = paneVM()
    if not vm.isNil: vm.moveSelection(0)

  method onFindOrFilter*(self: CalltraceComponent) {.async.} =
    ## The pane's search box takes the focus.
    let forms = document.getElementsByClass(
      cstring("calltrace-search-form-" & $self.id))
    if forms.len() > 0:
      let inputs = forms[0].Element.getElementsByTagName(cstring"input")
      if inputs.len() > 0:
        inputs[0].focus()
