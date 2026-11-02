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
import isonim/dsl/[ui, components]

when defined(js):
  # The DSL's calls on a `WebRenderer` resolve where the generic view is
  # instantiated; the overloads must be in scope there.
  import isonim/web/web_renderer

when defined(js):
  import isonim/web/dom_api as isonim_dom

import ../viewmodels/repl_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

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
# The panel
# ---------------------------------------------------------------------------

when defined(js):
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setInputValue(node: isonim_dom.Node; value: cstring) {.importjs: "#.value = #".}

proc renderMessage[R, N](r: R; message: string): N =
  ## The pane's text when the REPL is not available.
  ui(r):
    tdiv(class = "repl-msg-wrapper"):
      tdiv(class = "repl-disabled-msg"):
        text message

proc renderHistoryEntries[R, N](r: R; historyContainer: N;
                                entries: seq[ReplInteraction]) =
  ## The last `REPL_HISTORY_VISIBLE_LEN` interactions, newest first.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild
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

proc wireHeadlessSubmit[R, N](r: R; vm: ReplVM; formEl, inputEl: N) =
  ## A headless renderer's submit: the input's "value" attribute, which a
  ## test sets before firing "submit".
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin addEventListener
  r.addEventListener(formEl, "submit", proc() =
    let value = inputEl.attributes.getOrDefault("value", "")
    if value.len > 0:
      vm.submitInput(value)
      inputEl.attributes["value"] = "")

proc renderEnabled[R, N](r: R; vm: ReplVM): N =
  ## The input form and the history.
  var formEl, inputEl, historyEl: N
  let panel = ui(r):
    tdiv(id = "repl"):
      form(ref = formEl):
        input(ref = inputEl,
              id = "repl-input",
              `type` = "text",
              placeholder = "Enter command...")
      tdiv(ref = historyEl, id = "repl-history"):
        discard

  # Submitting the form sends the input. The browser's handler needs the
  # event, to keep the page from reloading on Enter (the DSL's
  # `onclick = …` shape has no event argument).
  when defined(js):
    when N is isonim_dom.Element:
      let inputNode = isonim_dom.Node(inputEl)
      isonim_dom.addEventListener(isonim_dom.Node(formEl), cstring"submit",
        proc(ev: isonim_dom.Event) =
          ev.preventDefault()
          ev.stopPropagation()
          let expression = inputNode.inputValue()
          if expression.len > 0:
            vm.submitInput($expression)
            inputNode.setInputValue(cstring""))
    else:
      wireHeadlessSubmit(r, vm, formEl, inputEl)
  else:
    wireHeadlessSubmit(r, vm, formEl, inputEl)

  renderHistoryEntries[R, N](r, historyEl, vm.history.val)
  panel

proc renderReplPanel*[R, N](r: R; vm: ReplVM): N =
  ## The REPL panel, under any renderer (Shared-DOM-Front-Ends D3), mounted
  ## on the desktop by `ui/panel_host`. Its body follows the display mode,
  ## the history and the language, rebuilt when any of them changes.
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild
  var bodyEl: N
  let panel = ui(r):
    tdiv(ref = bodyEl, class = "repl-component"):
      discard

  createRenderEffect proc() =
    let mode = vm.displayMode.val
    discard vm.history.val
    discard vm.langName.val
    r.clearChildren(bodyEl)
    let child = case mode
      of rdmMaterializedDisabled:
        renderMessage[R, N](r, materializedMessageText(vm.langName.val))
      of rdmReplEnabled:
        renderEnabled[R, N](r, vm)
      of rdmReplDisabled:
        renderMessage[R, N](r, REPL_DISABLED_MESSAGE)
    r.appendChild(bodyEl, child)

  panel
