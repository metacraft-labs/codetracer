## views/isonim_shell_view.nim — the Shell pane, the desktop's view over the
## shared `ShellVM`.
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.5,
## §7.7.
##
## ONE generic builder serves both renderers (Mock for the headless suites,
## Web for the product), so the tree a suite asserts is the tree the desktop
## draws. Every word, glyph, tone and row comes from the model — the terminal
## and the GPUI window draw the same rows from the same calls
## (`shellRows`, `actionGlyph`, `actionSummary`).
##
## Structure:
##   div.component-container.shell-component.isonim-shell [data-state]
##     div.shell-status            the model's state words and note
##     div.shell-rows              monospaced, one row per output line
##       div.shell-row [data-line] [data-mark] [data-tone]
##         span.shell-gutter [title = the action's words]   glyph | bar | " "
##         span.shell-text         styled runs; the cursor's cell
##                                 `span.shell-cursor`

import std/strutils
from std/unicode import runes, `$`

import isonim/core/[signals, computation]
import isonim/testing/mock_dom

export signals, computation

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/shell_vm
import ./field_keys
import ./shell_keys

export shell_keys
import ../viewmodels/terminal_output_model

func markName*(m: ShellRowMark): string =
  case m
  of srmNone: "none"
  of srmStart: "start"
  of srmRange: "range"

proc gutterText*(vm: ShellVM; row: ShellRow): string =
  ## What the gutter cell of a row says — the same call the native panes make.
  case row.mark
  of srmNone: " "
  of srmStart: vm.actions[row.action].actionGlyph
  of srmRange: actionBar()

when defined(js):
  proc evKey(ev: isonim_dom.Event): cstring {.importjs: "(#.key || '')".}
  proc evCtrl(ev: isonim_dom.Event): bool {.importjs: "!!#.ctrlKey".}
  proc evAlt(ev: isonim_dom.Event): bool {.importjs: "!!#.altKey".}
  proc evShift(ev: isonim_dom.Event): bool {.importjs: "!!#.shiftKey".}
  proc evMeta(ev: isonim_dom.Event): bool {.importjs: "!!#.metaKey".}
  proc stopEvent(ev: isonim_dom.Event) {.importjs:
    "(function (e) { e.preventDefault(); e.stopPropagation(); })(#)".}
  proc evPaste(ev: isonim_dom.Event): cstring {.importjs:
    "(function (e) { return (e.clipboardData && e.clipboardData.getData('text')) || ''; })(#)".}
  proc evDeltaY(ev: isonim_dom.Event): float {.importjs: "(#.deltaY || 0)".}
  proc evForApp(ev: isonim_dom.Event): bool {.importjs: "(!!#.__ctShellSkip)".}
    ## The key after the prefix, which the window's router took
    ## (`ui/shell`'s `paneKeyOwner`).

proc handleKey*(vm: ShellVM; k: ShellKey): bool =
  ## A key on the focused pane: true when the pane took it (the shell's, or
  ## the prefix); false when it is CodeTracer's and must go on to the
  ## window's keymap.
  vm.pressKey(k).kind != skrApp

proc wireInput[R, N](r: R; panel: N; vm: ShellVM) =
  ## Keys, paste and the wheel on the pane.
  when defined(js):
    when N is isonim_dom.Element:
      r.addEventListener(panel, KeyDownEvent, proc(ev: isonim_dom.Event) =
        let key = $evKey(ev)
        if isModifierOnly(key) or evMeta(ev) or evForApp(ev): return
        if handleKey(vm, shellKeyOfDom(key, evCtrl(ev), evAlt(ev), evShift(ev))):
          stopEvent(ev))
      r.addEventListener(panel, "paste", proc(ev: isonim_dom.Event) =
        vm.sendInput($evPaste(ev))
        stopEvent(ev))
      r.addEventListener(panel, "wheel", proc(ev: isonim_dom.Event) =
        let d = evDeltaY(ev)
        if d != 0:
          vm.scrollShell((if d > 0: 3 else: -3), vm.screen.rows)
          stopEvent(ev))
    else:
      r.addEventListener(panel, KeyDownEvent, proc(ev: MockEvent) =
        if not isModifierOnly(ev.key) and
           handleKey(vm, shellKeyOfDom(ev.key, false, false, false)):
          ev.preventDefault())
  else:
    r.addEventListener(panel, KeyDownEvent, proc(ev: MockEvent) =
      if not isModifierOnly(ev.key) and
         handleKey(vm, shellKeyOfDom(ev.key, false, false, false)):
        ev.preventDefault())

proc activateOnClick(vm: ShellVM; index: int): proc() =
  ## A gutter's press handler, made by a FACTORY so the action it activates is
  ## this call's own (a closure inside the row loop would share the loop's
  ## variable on the JS backend — `isonim_terminal_output_view.jumpOnClick`).
  let idx = index
  result = proc() = discard vm.activateAction(idx)

proc el[R](r: R; tag, class: string): auto =
  result = r.createElement(tag)
  if class.len > 0:
    r.setAttribute(result, "class", class)

proc styledSpan[R](r: R; text: string; style: TermAttrs; class = ""): auto =
  result = r.createElement("span")
  if class.len > 0:
    r.setAttribute(result, "class", class)
  let css = cssOf(style)
  if css.len > 0:
    r.setAttribute(result, "style", css)
  r.appendChild(result, r.createTextNode(text))

proc appendRunsWithCursor[R, N](r: R; into: N; row: ShellRow) =
  ## A row's runs, the cursor's cell split out as `span.shell-cursor`.
  for run in row.runs:
    if row.cursorCol < run.col or row.cursorCol >= run.col + run.cells:
      r.appendChild(into, styledSpan(r, run.text, run.attrs))
      continue
    var before, at, after = ""
    var col = run.col
    for ch in run.text.runes:
      let s = $ch
      if col < row.cursorCol: before.add s
      elif col == row.cursorCol: at.add s
      else: after.add s
      col += max(1, runeCells(ch))
    if before.len > 0: r.appendChild(into, styledSpan(r, before, run.attrs))
    r.appendChild(into, styledSpan(r, (if at.len > 0: at else: " "),
                                   run.attrs, "shell-cursor"))
    if after.len > 0: r.appendChild(into, styledSpan(r, after, run.attrs))

proc renderShellPanel*[R, N](r: R; vm: ShellVM): N =
  ## The Shell panel, for every renderer. It takes no id: the host it is
  ## mounted into carries the pane's.
  let panel = el(r, "div", "component-container shell-component isonim-shell")
  r.setAttribute(panel, "tabindex", "0")
  r.setStyle(panel, "outline", "none")
  r.setStyle(panel, "display", "flex")
  r.setStyle(panel, "flex-direction", "column")
  r.setStyle(panel, "height", "100%")
  let status = el(r, "div", "shell-status")
  r.setStyle(status, "flex", "0 0 auto")
  r.setStyle(status, "opacity", "0.75")
  r.setStyle(status, "padding", "2px 6px")
  let rows = el(r, "div", "shell-rows")
  r.setStyle(rows, "flex", "1 1 auto")
  r.setStyle(rows, "overflow", "hidden")
  r.setStyle(rows, "white-space", "pre")
  r.setStyle(rows, "font-family", "\"SpaceMono\", monospace")
  r.setStyle(rows, "line-height", "1.25")
  r.appendChild(panel, status)
  r.appendChild(panel, rows)
  wireInput[R, N](r, panel, vm)

  createRenderEffect proc() =
    discard vm.revision.val
    let state = vm.state.val
    let note = vm.note.val
    r.setAttribute(panel, "data-state", $state)
    r.clearChildren(status)
    r.appendChild(status, r.createTextNode(
      "Shell — " & vm.statusWords & (if note.len > 0: " · " & note else: "")))
    r.clearChildren(rows)
    for row in vm.shellRows(vm.screen.rows):
      let rowNode = el(r, "div", "shell-row")
      r.setAttribute(rowNode, "data-line", $row.line)
      r.setAttribute(rowNode, "data-mark", markName(row.mark))
      r.setStyle(rowNode, "height", "1.25em")
      r.setStyle(rowNode, "line-height", "1.25em")
      r.setStyle(rowNode, "overflow", "hidden")
      let gutter = el(r, "span", "shell-gutter")
      r.setStyle(gutter, "display", "inline-block")
      r.setStyle(gutter, "width", "2ch")
      if row.mark != srmNone:
        let a = vm.actions[row.action]
        r.setAttribute(rowNode, "data-tone", $row.tone)
        r.setAttribute(gutter, "title", a.actionSummary & " — " & a.actionHint)
        r.setAttribute(gutter, "data-action", $row.action)
        r.setStyle(gutter, "cursor", "pointer")
        r.addEventListener(gutter, "click", activateOnClick(vm, row.action))
      r.appendChild(gutter, r.createTextNode(vm.gutterText(row)))
      r.appendChild(rowNode, gutter)
      let text = el(r, "span", "shell-text")
      appendRunsWithCursor[R, N](r, text, row)
      r.appendChild(rowNode, text)
      r.appendChild(rows, rowNode)

  panel

proc shellRowsText*(vm: ShellVM): seq[string] =
  ## The rows a pane shows as plain text, the gutter first — what the
  ## cross-front-end checks compare (§7.8).
  for row in vm.shellRows(vm.screen.rows):
    result.add vm.gutterText(row) & " " & row.text

when defined(js):
  proc mountIsoNimShell*(container: isonim_dom.Element; vm: ShellVM) =
    ## Mount the Shell panel as a child of `container` (the storybook, the
    ## IsoNim app shell); reactive effects keep it in sync with `vm`.
    let r = WebRenderer()
    let panel = renderShellPanel[WebRenderer, isonim_dom.Element](r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
