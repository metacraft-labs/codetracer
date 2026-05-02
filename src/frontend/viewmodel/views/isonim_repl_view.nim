## views/isonim_repl_view.nim
##
## IsoNim DOM-rendering view for the REPL panel.
##
## Renders a live, reactive DOM tree driven by ``ReplVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/repl.nim`` (the IsoNim view is the single source of
## truth for the panel's DOM).
##
## The legacy view had three branches that map directly to
## ``ReplVM.displayMode``:
##
## ``rdmMaterializedDisabled``
##   Renders the "REPL not supported for materialised traces" message
##   (originally driven by ``trace.lang.usesMaterializedTraces``).
##
## ``rdmReplEnabled``
##   Renders the prompt + bounded history list:
##
##     div#repl
##       form
##         input#repl-input[type="text"]
##       div#repl-history
##         div.repl-input-history       text "><input>"
##         div.repl-output-history
##           pre.repl-output-<kind>     text <output>
##         (last REPL_HISTORY_VISIBLE_LEN entries, newest first)
##
## ``rdmReplDisabled``
##   Renders the "REPL disabled" instructional message.
##
## Reactive surface: the body is rebuilt by a single outer
## ``createRenderEffect`` reading ``vm.displayMode``,
## ``vm.history``, and ``vm.langName`` so the panel re-renders when
## any of those change.  This mirrors the step_list / no_source view
## shape — imperative MockRenderer / DOM ops inside the effect, with
## the static container shell built once via the DSL.

import std/tables

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/repl_vm

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc materializedMessageText*(langName: string): string =
  ## Mirrors the legacy
  ## ``"The Repl Component is not supported for Db based traces '{lang}'"``
  ## copy.  The lang name is interpolated even when empty (the legacy
  ## view used ``$lang.toName()`` which can be empty).
  "The Repl Component is not supported for Db based traces '" &
    langName & "'"

const REPL_DISABLED_MESSAGE* = "The Repl Component is disabled with the current configuration.\n*If you want to enable it please:\n1. Edit the 'repl' flag in CodeTracer/config/default_config.yaml\n2. Run rm -rf ~/.config/codetracer to get the updated config"
  ## Legacy "REPL disabled" copy preserved verbatim so any test or
  ## visual regression keyed on the message keeps working.

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderMaterializedMessageMock(r: MockRenderer; vm: ReplVM): MockNode =
  ## Build the "REPL not supported" sub-tree.  Wrapper is the same
  ## ``.repl-msg-wrapper`` shell the legacy view used.
  let panel = ui(r):
    tdiv(class = "repl-msg-wrapper"):
      tdiv(class = "repl-disabled-msg"):
        text materializedMessageText(vm.langName.val)
  panel

proc renderDisabledMessageMock(r: MockRenderer; vm: ReplVM): MockNode =
  ## Build the "REPL disabled" sub-tree.  Same shell as the
  ## materialised-disabled branch but with the longer instructional
  ## copy.  ``vm`` is unused; we keep the parameter for symmetry.
  let panel = ui(r):
    tdiv(class = "repl-msg-wrapper"):
      tdiv(class = "repl-disabled-msg"):
        text REPL_DISABLED_MESSAGE
  panel

proc renderHistoryEntriesMock(r: MockRenderer; historyContainer: MockNode;
                              entries: seq[ReplInteraction]) =
  ## Append rendered rows for the last ``REPL_HISTORY_VISIBLE_LEN``
  ## entries in newest-first order — matches the legacy
  ## ``(history.len-1).countdown(history.len-10)`` loop.
  let last = entries.len - 1
  let first = max(0, entries.len - REPL_HISTORY_VISIBLE_LEN)
  if last < 0:
    return
  for i in countdown(last, first):
    let interaction = entries[i]
    let inputRow = ui(r):
      tdiv(class = "repl-input-history"):
        text inputDisplayText(interaction.input)
    r.appendChild(historyContainer, inputRow)
    let outputRow = ui(r):
      tdiv(class = "repl-output-history"):
        pre(class = outputClass(interaction.output.kind)):
          text interaction.output.output
    r.appendChild(historyContainer, outputRow)

proc renderEnabledMock(r: MockRenderer; vm: ReplVM): MockNode =
  ## Build the prompt + history sub-tree.  The form wires its submit
  ## handler imperatively after the DSL expansion so we can read the
  ## input value from the captured ``inputEl`` before calling
  ## ``vm.submitInput``.
  var formEl: MockNode
  var inputEl: MockNode
  var historyEl: MockNode

  let panel = ui(r):
    tdiv(id = "repl"):
      form(ref = formEl):
        input(ref = inputEl,
              id = "repl-input",
              `type` = "text",
              placeholder = "Enter command...")
      tdiv(ref = historyEl, id = "repl-history"):
        discard

  # Submit handler.  ``MockNode.fireEvent`` invokes registered
  # ``proc()`` listeners with no event arg, so we read the input
  # element's "value" attribute directly here.  Headless tests set
  # the value via ``r.setAttribute(inputEl, "value", "...")`` before
  # firing ``"submit"``.
  let captureInput = inputEl
  let captureVm = vm
  r.addEventListener(formEl, "submit", proc() =
    let value = captureInput.attributes.getOrDefault("value", "")
    if value.len > 0:
      captureVm.submitInput(value)
      captureInput.attributes["value"] = ""
  )

  # History list: rebuilt by the outer render-effect in
  # ``renderReplPanel`` after this body is appended.  Stash the
  # container reference on the panel by inserting it as an attribute
  # the caller can find via ``findByClass`` if needed; for the mock
  # we rely on the outer effect re-locating ``#repl-history`` via
  # ``findByClass`` style lookups.
  renderHistoryEntriesMock(r, historyEl, vm.history.val)
  panel

proc renderReplPanel*(r: MockRenderer; vm: ReplVM): MockNode =
  ## Render the REPL panel for the Mock renderer.
  ##
  ## The outer wrapper is a single ``.repl-component`` div whose
  ## children are rebuilt by an ``createRenderEffect`` reading
  ## ``vm.displayMode``, ``vm.history`` and ``vm.langName``.  Using
  ## imperative MockRenderer ops inside the effect keeps the dynamic
  ## branch dispatch straightforward — the DSL cannot ``case`` over a
  ## runtime mode signal directly.
  var bodyEl: MockNode

  let panel = ui(r):
    tdiv(ref = bodyEl, class = "repl-component"):
      discard

  createRenderEffect proc() =
    let mode = vm.displayMode.val
    # Read history + langName so the effect re-runs on those updates
    # too — the body dispatch may not reach the reactive subtree
    # consistently otherwise.
    discard vm.history.val
    discard vm.langName.val
    r.clearChildren(bodyEl)
    let child = case mode
      of rdmMaterializedDisabled:
        renderMaterializedMessageMock(r, vm)
      of rdmReplEnabled:
        renderEnabledMock(r, vm)
      of rdmReplDisabled:
        renderDisabledMessageMock(r, vm)
    r.appendChild(bodyEl, child)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = "";
                        elemId: string = ""): isonim_dom.Element =
    ## Create a DOM element with optional class + id attributes.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    if elemId.len > 0:
      isonim_dom.setAttribute(n, cstring"id", cstring(elemId))
    n

  proc createWebTextElement(tag: string; textValue: string;
                            cssClass: string = "";
                            elemId: string = ""): isonim_dom.Element =
    ## Create an element with a text-node child in one shot.
    let n = createWebElement(tag, cssClass, elemId)
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderMaterializedMessageWeb(vm: ReplVM): isonim_dom.Element =
    let wrapper = createWebElement("div", "repl-msg-wrapper")
    let msg = createWebTextElement("div",
                                   materializedMessageText(vm.langName.val),
                                   "repl-disabled-msg")
    isonim_dom.appendChild(isonim_dom.Node(wrapper), isonim_dom.Node(msg))
    wrapper

  proc renderDisabledMessageWeb(): isonim_dom.Element =
    let wrapper = createWebElement("div", "repl-msg-wrapper")
    let msg = createWebTextElement("div", REPL_DISABLED_MESSAGE,
                                   "repl-disabled-msg")
    isonim_dom.appendChild(isonim_dom.Node(wrapper), isonim_dom.Node(msg))
    wrapper

  proc renderHistoryEntriesWeb(historyContainer: isonim_dom.Element;
                               entries: seq[ReplInteraction]) =
    let last = entries.len - 1
    let first = max(0, entries.len - REPL_HISTORY_VISIBLE_LEN)
    if last < 0:
      return
    for i in countdown(last, first):
      let interaction = entries[i]
      let inputRow = createWebTextElement("div",
                                          inputDisplayText(interaction.input),
                                          "repl-input-history")
      isonim_dom.appendChild(isonim_dom.Node(historyContainer),
                             isonim_dom.Node(inputRow))
      let outputWrapper = createWebElement("div", "repl-output-history")
      let pre = createWebTextElement("pre", interaction.output.output,
                                     outputClass(interaction.output.kind))
      isonim_dom.appendChild(isonim_dom.Node(outputWrapper),
                             isonim_dom.Node(pre))
      isonim_dom.appendChild(isonim_dom.Node(historyContainer),
                             isonim_dom.Node(outputWrapper))

  proc renderEnabledWeb(vm: ReplVM): isonim_dom.Element =
    ## Build the prompt + history sub-tree in the real DOM.
    let panel = createWebElement("div", "", "repl")

    let formEl = isonim_dom.createElement(isonim_dom.document, cstring"form")
    let inputEl = isonim_dom.createElement(isonim_dom.document, cstring"input")
    isonim_dom.setAttribute(inputEl, cstring"id", cstring"repl-input")
    isonim_dom.setAttribute(inputEl, cstring"type", cstring"text")
    isonim_dom.setAttribute(inputEl, cstring"placeholder",
                            cstring"Enter command...")
    isonim_dom.appendChild(isonim_dom.Node(formEl), isonim_dom.Node(inputEl))
    isonim_dom.appendChild(isonim_dom.Node(panel), isonim_dom.Node(formEl))

    let inputNode = isonim_dom.Node(inputEl)
    isonim_dom.addEventListener(isonim_dom.Node(formEl), cstring"submit",
      proc(ev: isonim_dom.Event) =
        # ``preventDefault`` / ``stopPropagation`` mirror the legacy
        # Karax form handler so the page does not refresh when the
        # user presses Enter.  The DSL's ``onclick = ...`` shape
        # cannot express the event arg, so we wire imperatively.
        {.emit: "`ev`.preventDefault();".}
        {.emit: "`ev`.stopPropagation();".}
        var expression: cstring
        {.emit: "`expression` = `inputNode`.value || '';".}
        if expression.len > 0:
          vm.submitInput($expression)
          {.emit: "`inputNode`.value = '';".})

    let historyEl = createWebElement("div", "", "repl-history")
    renderHistoryEntriesWeb(historyEl, vm.history.val)
    isonim_dom.appendChild(isonim_dom.Node(panel), isonim_dom.Node(historyEl))

    panel

  proc renderReplPanel*(r: WebRenderer; vm: ReplVM): isonim_dom.Element =
    ## Render the panel for the real DOM.  Same dispatch shape as the
    ## Mock variant — outer wrapper plus a render-effect that
    ## rebuilds the body whenever the relevant signals change.
    var bodyEl: isonim_dom.Element

    let panel = ui(r):
      tdiv(ref = bodyEl, class = "repl-component"):
        discard

    createRenderEffect proc() =
      let mode = vm.displayMode.val
      discard vm.history.val
      discard vm.langName.val
      clearWebChildren(bodyEl)
      let child = case mode
        of rdmMaterializedDisabled:
          renderMaterializedMessageWeb(vm)
        of rdmReplEnabled:
          renderEnabledWeb(vm)
        of rdmReplDisabled:
          renderDisabledMessageWeb()
      isonim_dom.appendChild(isonim_dom.Node(bodyEl), isonim_dom.Node(child))

    panel

  proc mountIsoNimRepl*(container: isonim_dom.Element; vm: ReplVM) =
    ## Mount the IsoNim REPL panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderReplPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
