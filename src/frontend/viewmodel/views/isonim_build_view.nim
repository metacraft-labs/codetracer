## views/isonim_build_view.nim
##
## IsoNim DOM-rendering view for the Build panel (the desktop's BUILD pane).
##
## Renders a live, reactive DOM tree driven by ``BuildVM`` signals, under any
## renderer (Shared-DOM-Front-Ends D3): the browser's on the desktop, the Mock
## renderer in the headless suites. The structure (the Playwright contract in
## ``src/tests/gui/page-objects/panes/build/build-pane.ts``):
##
##   div.build-panel
##     div.build-header[.build-failed | .build-succeeded | .build-cancelled]
##       div.build-command-label                              headerText
##       div.build-header-controls
##         div.build-history-btn[.active]  "History ▾"       click→the menu
##         div.build-ctrl-btn.build-run-btn                   click→runBuild
##         div.build-ctrl-btn.build-stop-btn[.disabled]       click→cancelBuild
##         div.build-ctrl-btn.build-clear-btn                 click→clearOutput
##         div.build-ctrl-btn.build-scroll-btn[.active]       click→toggleAutoScroll
##         div.build-duration                                 durationText
##     div.build-history-menu (shown while open)
##       div.build-history-item[.active]                      click→showBuild
##     div#build.build-output-container
##       div.build-output-line.build-clickable.build-line-{severity}
##         span[style=…] per styled run                       click→jumpToLine
##       OR div.build-stdout / div.build-stderr
##         span[style=…] per styled run
##
## PLAT-56 (Build-Output-Pane.md §3.13): every word is the ViewModel's
## (`build_output_model`: the verdict, the duration, the history's labels),
## and a line is drawn from its STYLED RUNS — one `<span>` per run, styled
## with `terminal_output_model.cssOf` (the declarations `ansi_up` wrote) —
## rather than from `ansi_up`'s HTML, so the text is a text node (no markup a
## compiler printed can be injected) and the terminal and GPUI draw the same
## runs. The pane shows the build `shownSnapshot` names: the current one, or
## the history entry picked.

when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/build_vm
import ../viewmodels/terminal_output_model

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

# ---------------------------------------------------------------------------
# Reactive helpers
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "inline-block" else: "none"

proc headerClass*(status: BuildStatus): string =
  ## ``build-header`` plus the verdict's modifier (the CSS hooks
  ## ``.build-header.build-failed`` / ``.build-succeeded``; PLAT-56 adds
  ## ``.build-cancelled``).
  case status
  of bsFailed: "build-header build-failed"
  of bsSucceeded: "build-header build-succeeded"
  of bsCancelled: "build-header build-cancelled"
  of bsIdle, bsRunning: "build-header"

proc stopButtonClass(vm: BuildVM): string =
  if vm.isRunning.val:
    "build-ctrl-btn build-stop-btn"
  else:
    "build-ctrl-btn build-stop-btn disabled"

proc scrollButtonClass(vm: BuildVM): string =
  if vm.autoScroll.val:
    "build-ctrl-btn build-scroll-btn active"
  else:
    "build-ctrl-btn build-scroll-btn"

proc lineClass*(line: BuildOutputLine): string =
  ## CSS class for a single output line. A line with a location is a jump
  ## target (``build-clickable``) coloured by its severity; any other line by
  ## its stream (``build-stdout`` / ``build-stderr``).
  if line.located:
    let severity = case line.severity
                   of blsError:   "build-line-error"
                   of blsWarning: "build-line-warning"
                   of blsInfo:    "build-line-info"
                   of blsNone:    ""
    if severity.len > 0:
      "build-output-line build-clickable " & severity
    else:
      "build-output-line build-clickable"
  elif line.isStdout:
    "build-stdout"
  else:
    "build-stderr"

proc lineJumpHandler(vm: BuildVM; line: BuildOutputLine): proc() =
  ## The click handler of one output row: open the location `line` names.
  ##
  ## A FACTORY, because the rows are built in a `for` loop and Nim closures
  ## capture by reference: a `let` in the loop body (or the loop variable) is
  ## ONE variable for the whole loop, so an inline `proc() = vm.jumpToLine(x)`
  ## made every row open the LAST row's location (codetracer#860 sweep;
  ## https://nim-lang.org/docs/manual.html#procedures-closures). `line` is
  ## this call's own parameter, so each row's closure owns its value.
  result = proc() = vm.jumpToLine(line)

proc historyPick(vm: BuildVM; index: int; open: Signal[bool]): proc() =
  ## A history entry's click (a factory for `lineJumpHandler`'s reason):
  ## -1 the current build, else history entry `index`.
  result = proc() =
    vm.showBuild(index)
    open.val = false

proc el[R](r: R; tag, class: string): auto =
  mixin createElement, createTextNode, setAttribute, setStyle, appendChild, addEventListener, clearChildren
  result = r.createElement(tag)
  if class.len > 0:
    r.setAttribute(result, "class", class)

proc lineNodeOf[R](r: R; vm: BuildVM; line: BuildOutputLine): auto =
  ## One output line: its class, its runs as styled spans, its click.
  mixin createElement, createTextNode, setAttribute, setStyle, appendChild, addEventListener, clearChildren
  result = el(r, "div", lineClass(line))
  r.setAttribute(result, "role", "button")
  r.setAttribute(result, "tabindex", "0")
  for run in line.runs:
    let span = r.createElement("span")
    let css = cssOf(run.style)
    if css.len > 0:
      r.setAttribute(span, "style", css)
    r.appendChild(span, r.createTextNode(run.text))
    r.appendChild(result, span)
  if line.located:
    r.addEventListener(result, "click", lineJumpHandler(vm, line))

when defined(js):
  import std/jsffi
  import ./list_scrubber_dom

  proc buildSetTimeout(fn: proc(); ms: int) {.importjs: "setTimeout(#, #)".}
  proc scrollToBottom(node: JsObject) {.importjs:
    "(function(node) { if (node) { node.scrollTop = node.scrollHeight; } })(#)".}
  proc outputContainerOf(panel: JsObject): JsObject {.importjs:
    "(#.querySelector('.build-output-container') || null)".}
  proc firstBuildLineHeight(el: JsObject): float {.importjs:
    "(function(e){const l=e.firstElementChild;return l ? l.getBoundingClientRect().height : 0;})(#)".}

proc renderBuildPanel*[R, N](r: R; vm: BuildVM): N =
  ## The build panel, under any renderer (Shared-DOM-Front-Ends D3), mounted
  ## on the desktop by `ui/panel_host`.
  mixin createElement, createTextNode, setAttribute, setStyle, appendChild, addEventListener, clearChildren
  let historyOpen = createSignal(false)
  let panel = el(r, "div", "build-panel isonim-build")
  let header = el(r, "div", "build-header")
  let label = el(r, "div", "build-command-label")
  r.appendChild(header, label)
  let controls = el(r, "div", "build-header-controls")
  let historyBtn = el(r, "div", "build-history-btn")
  r.setAttribute(historyBtn, "title", BuildHistoryLabel)
  r.appendChild(historyBtn, r.createTextNode(BuildHistoryLabel & " ▾"))
  r.addEventListener(historyBtn, "click", proc() =
    historyOpen.val = not historyOpen.val)
  r.appendChild(controls, historyBtn)
  let runBtn = el(r, "div", "build-ctrl-btn build-run-btn")
  r.setAttribute(runBtn, "title", BuildControlTitles[0])
  r.addEventListener(runBtn, "click", proc() =
    if not vm.runBuild.isNil: vm.runBuild())
  r.appendChild(controls, runBtn)
  let stopBtn = el(r, "div", "build-ctrl-btn build-stop-btn disabled")
  r.setAttribute(stopBtn, "title", BuildControlTitles[1])
  r.addEventListener(stopBtn, "click", proc() =
    if vm.isRunning.val: vm.cancelBuild())
  r.appendChild(controls, stopBtn)
  let clearBtn = el(r, "div", "build-ctrl-btn build-clear-btn")
  r.setAttribute(clearBtn, "title", BuildControlTitles[2])
  r.addEventListener(clearBtn, "click", proc() = vm.clearOutput())
  r.appendChild(controls, clearBtn)
  let scrollBtn = el(r, "div", "build-ctrl-btn build-scroll-btn active")
  r.setAttribute(scrollBtn, "title", BuildControlTitles[3])
  r.addEventListener(scrollBtn, "click", proc() = vm.toggleAutoScroll())
  r.appendChild(controls, scrollBtn)
  let duration = el(r, "div", "build-duration")
  r.appendChild(controls, duration)
  r.appendChild(header, controls)
  r.appendChild(panel, header)
  let menu = el(r, "div", "build-history-menu")
  r.appendChild(panel, menu)
  let empty = el(r, "div", "build-empty")
  r.appendChild(empty, r.createTextNode(BuildIdleText))
  r.appendChild(panel, empty)
  let output = el(r, "div", "build-output-container")
  r.setAttribute(output, "id", "build")
  r.appendChild(panel, output)

  # The header: the verdict, the controls' states, the duration.
  createRenderEffect proc() =
    let shown = vm.shownSnapshot()
    r.setAttribute(header, "class", headerClass(shown.status))
    r.clearChildren(label)
    r.appendChild(label, r.createTextNode(shown.headerText))
    r.setAttribute(stopBtn, "class", stopButtonClass(vm))
    r.setAttribute(scrollBtn, "class", scrollButtonClass(vm))
    let d = shown.durationText(vm.clockMs.val)
    r.setStyle(duration, "display", displayIf(d.len > 0))
    r.clearChildren(duration)
    r.appendChild(duration, r.createTextNode(d))
    let hasHistory = vm.history.val.len > 0
    r.setStyle(historyBtn, "display", displayIf(hasHistory))
    r.setAttribute(historyBtn, "class",
                   "build-history-btn" &
                   (if not vm.showingLatest: " active" else: ""))

  # The history picker: the current build, then the history, newest first.
  createRenderEffect proc() =
    let open = historyOpen.val and vm.history.val.len > 0
    let labels = vm.historyLabels()
    let shownAt = (if vm.showingLatest: 0 else: vm.shownIndex.val + 1)
    r.setStyle(menu, "display", if open: "block" else: "none")
    r.clearChildren(menu)
    for i, text in labels:
      let item = el(r, "div", "build-history-item" &
                              (if i == shownAt: " active" else: ""))
      r.setAttribute(item, "role", "menuitem")
      r.appendChild(item, r.createTextNode(text))
      r.addEventListener(item, "click", historyPick(vm, i - 1, historyOpen))
      r.appendChild(menu, item)

  # The output: the shown build's lines, rebuilt when they change; with no
  # build, the empty state.
  createRenderEffect proc() =
    let shown = vm.shownSnapshot()
    r.setStyle(empty, "display",
               (if shown.status == bsIdle and shown.output.len == 0: "block"
                else: "none"))
    r.clearChildren(output)
    for line in shown.output:
      r.appendChild(output, lineNodeOf(r, vm, line))
    when defined(js):
      when N is isonim_dom.Element:
        if vm.autoScroll.val and shown.latest:
          scrollToBottom(cast[JsObject](output))

  when defined(js):
    when N is isonim_dom.Element:
      # Attached once the panel is in the document: the output's scrollbar
      # is the shared list scrubber (PLAT-51, Scrollbar-Scrubbers.md §2; the
      # same model the terminal and GPUI draw), and its horizontal bar the
      # shared one (PLAT-70, Horizontal-Overflow.md §4).
      let panelEl = panel
      buildSetTimeout(proc() =
        let p = cast[JsObject](panelEl)
        let container = outputContainerOf(p)
        if not container.isNil:
          proc lineHeight(): float =
            let h = firstBuildLineHeight(container)
            if h > 0.0: h else: 24.0
          discard attachListScrubber(container, p,
            total = proc(): int = vm.shownSnapshot().output.len,
            current = proc(): int = -1,
            rowHeight = lineHeight,
            paneId = "buildOutput")
          discard attachHorizontalScrubber(container, p,
                                           paneId = "buildOutput",
                                           verticalTrack = true)
      , 0)

  panel
