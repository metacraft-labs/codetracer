## views/isonim_command_palette_view.nim
##
## IsoNim DOM-rendering view for the Command Palette panel.
##
## Renders a live, reactive DOM tree driven by ``CommandPaletteVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/command.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## The legacy panel rendered an input field plus a dropdown of
## per-kind ``commandResultView`` rows (file paths, program-search
## snippets, symbol-kind suffixes, agent passthrough).  This first
## iteration intentionally renders the common path — one row per
## ``CommandPaletteResultEntry`` with the entry's display ``value``
## verbatim plus stable per-kind / per-level CSS modifiers.  The
## rich per-kind rendering paths remain a follow-up captured in the
## VM doc-comment.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy ``command-view`` layout::
##
##   div.component-container.command-container[.hidden]
##     div.command-view
##       div.command-input-row
##         input.command-input-field        (placeholder + value bound)
##         span.command-input-placeholder   (autocomplete hint)
##       div.command-results
##         div.command-result[.command-{kind}][.command-{level}]
##                            [.command-selected][.command-even|odd]
##           span.command-result-value      (entry.value verbatim)
##           span.command-result-suffix     (symbolKind suffix)
##         div.command-empty-overlay[.hidden]
##           text "No matching result found."
##
## Reactive surface:
## - One outer ``createRenderEffect`` rebuilds the result rows and
##   toggles the empty-state placeholder + the overlay hidden modifier
##   whenever any source signal (``isActive`` / ``results`` /
##   ``selectedIndex`` / ``inputValue`` / ``inputPlaceholder`` /
##   ``mode``) changes.  Mirrors the trace_log / scratchpad /
##   filesystem pattern (DSL builds the static shell, imperative
##   renderer ops inside the effect handle the dynamic content).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/command_palette_vm

const CommandPaletteContainerClass* = "component-container command-container"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "command-container")`` template produced.  Exposed for headless
  ## tests so they assert against the exact class string (and so the
  ## existing ``static/styles/components/command.styl`` rules keep
  ## targeting the same selector).

const CommandPaletteSurfaceClass* = "command-view"
  ## CSS class on the inner panel surface — the wrapper inside which
  ## the input row + results dropdown live.  Distinct from the
  ## ``command-container`` outer wrapper so the styling rules can
  ## target the active surface independently of the GoldenLayout
  ## container.

const CommandPaletteResultsClass* = "command-results"
  ## CSS class on the dropdown results container.  Mirrors the
  ## legacy ``command-results`` block the Karax view rendered for
  ## the dropdown rows.

const CommandPaletteResultRowClass* = "command-result"
  ## Base CSS class applied to every dropdown row.  Per-kind /
  ## per-level / selected / zebra modifiers append after this base
  ## class string.

const CommandPaletteEmptyStateText* = "No matching result found."
  ## Placeholder copy rendered when the palette is open but has no
  ## matching results.  Kept as a constant so the view, the headless
  ## tests, and any future fixture builder share one source of truth.
  ## Name-spaced (vs. the ``EmptyStateText`` in trace_log_view and
  ## ``FilesystemEmptyStateText``) so importing both modules from the
  ## test suite does not collide.

const CommandPaletteHiddenModifier* = "hidden"
  ## CSS modifier class appended to the outer container when the
  ## palette is closed and to the empty overlay when there are
  ## results to show.  Name-spaced as a const so tests can assert on
  ## it without re-stringifying.

const CommandPaletteInputFieldClass* = "command-input-field"
  ## CSS class on the input field.  Distinct from the legacy Karax
  ## ``command-input`` selector so styles can target the IsoNim
  ## variant separately if needed; both classes coexist in the
  ## stylesheet for the migration window.

const CommandPalettePlaceholderClass* = "command-input-placeholder"
  ## CSS class on the autocomplete hint span rendered behind the
  ## input field.  The legacy view used the same selector — the
  ## name-spaced const here keeps the IsoNim view authoritative.

# ---------------------------------------------------------------------------
# Reactive helpers used inside the render effect
# ---------------------------------------------------------------------------

proc resultKindClass*(kind: CommandPaletteResultKind): string =
  ## Map a ``CommandPaletteResultKind`` enum to the CSS modifier
  ## the legacy ``commandResultView`` proc applied per row.  Keeps
  ## the view stable as the kind enum gains variants.
  case kind
  of cprkCommand: "command-command"
  of cprkFile: "command-file"
  of cprkProgram: "command-program"
  of cprkTextSearch: "command-text-search"
  of cprkSymbol: "command-symbol"
  of cprkAgent: "command-agent"

proc resultLevelClass*(level: CommandPaletteNotificationLevel): string =
  ## Map a ``CommandPaletteNotificationLevel`` enum to the CSS
  ## modifier the legacy view applied for warning/error diagnostics.
  ## ``cpnlInfo`` returns the empty string so the row's class string
  ## stays clean for the standard branch.
  case level
  of cpnlInfo: ""
  of cpnlWarning: "command-warn"
  of cpnlError: "command-error"
  of cpnlSuccess: "command-success"

proc rowZebraClass*(index: int): string =
  ## Zebra modifier — even rows get ``command-even``, odd rows get
  ## ``command-odd``.  Mirrors the legacy class string the Karax
  ## view emitted for alternating-row styling.
  if (index and 1) == 0:
    "command-even"
  else:
    "command-odd"

proc resultRowClass*(entry: CommandPaletteResultEntry; index: int;
                     selected: bool): string =
  ## Compose the full class string for a single dropdown row.  The
  ## base class is followed by per-kind, per-level, zebra, and
  ## selected modifiers in a stable order so tests can assert on the
  ## exact string.  Empty modifiers (e.g. ``cpnlInfo``) are skipped
  ## so the class string never carries spurious double spaces.
  var parts = @[CommandPaletteResultRowClass, resultKindClass(entry.kind)]
  let lvl = resultLevelClass(entry.level)
  if lvl.len > 0:
    parts.add lvl
  parts.add rowZebraClass(index)
  if selected:
    parts.add "command-selected"
  parts.join(" ")

proc rowSuffixText*(entry: CommandPaletteResultEntry): string =
  ## Build the suffix label rendered after the row's primary value.
  ## Symbol queries get a `": <symbolKind>"` tail (matching the
  ## legacy ``commandResultView`` rendering); other kinds render
  ## an empty suffix so the column lines up vertically without
  ## planting a redundant element.
  if entry.kind == cprkSymbol and entry.symbolKind.len > 0:
    ": " & entry.symbolKind
  else:
    ""

proc containerClass*(isActive: bool): string =
  ## Outer container class string — appends the ``hidden`` modifier
  ## when the palette is closed.  Mirrors the legacy
  ## ``classnames("command-container", "hidden": not active)``.
  if isActive:
    CommandPaletteContainerClass
  else:
    CommandPaletteContainerClass & " " & CommandPaletteHiddenModifier

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderMockResultRow(r: MockRenderer; vm: CommandPaletteVM;
                         entry: CommandPaletteResultEntry;
                         index: int; selected: bool): MockNode =
  ## Render a single dropdown row.  Click handler invokes
  ## ``vm.setSelected`` so the headless tests can drive the
  ## selection from a synthetic click event without touching the
  ## legacy interpreter (which the bridge wires through the row's
  ## ``runQuery`` pipeline on the production path).
  let cls = resultRowClass(entry, index, selected)
  let suffix = rowSuffixText(entry)
  let value = entry.value
  let rowIndex = index
  let row = ui(r):
    tdiv(class = cls,
         onclick = proc() =
           vm.setSelected(rowIndex)):
      span(class = "command-result-value"):
        text value
      span(class = "command-result-suffix"):
        text suffix
  row

proc renderCommandPalettePanel*(r: MockRenderer;
                                vm: CommandPaletteVM): MockNode =
  ## Render the Command Palette panel for the Mock renderer.
  ##
  ## The static shell (outer container + surface + input row +
  ## results dropdown + empty overlay) is built once via the DSL.
  ## A single outer ``createRenderEffect`` rebuilds the dynamic
  ## content whenever any source signal changes.
  var outerContainer: MockNode
  var inputField: MockNode
  var placeholderSpan: MockNode
  var resultsContainer: MockNode
  var emptyContainer: MockNode

  let panel = ui(r):
    tdiv(ref = outerContainer, class = CommandPaletteContainerClass):
      tdiv(class = CommandPaletteSurfaceClass):
        tdiv(class = "command-input-row"):
          input(ref = inputField, class = CommandPaletteInputFieldClass)
          span(ref = placeholderSpan, class = CommandPalettePlaceholderClass):
            text ""
        tdiv(ref = resultsContainer, class = CommandPaletteResultsClass):
          discard
        tdiv(ref = emptyContainer, class = "command-empty-overlay"):
          text CommandPaletteEmptyStateText

  createRenderEffect proc() =
    # -- Outer container visibility --
    r.setAttribute(outerContainer, "class", containerClass(vm.isActive.val))

    # -- Input field value + placeholder --
    r.setAttribute(inputField, "value", vm.inputValue.val)
    r.setAttribute(placeholderSpan, "data-hint", vm.inputPlaceholder.val)
    # The placeholder span renders the hint as its inline text so
    # the headless tests can assert on the visible content without
    # parsing data-attributes.
    r.clearChildren(placeholderSpan)
    if vm.inputPlaceholder.val.len > 0:
      let hint = vm.inputPlaceholder.val
      let hintNode = ui(r):
        text hint
      r.appendChild(placeholderSpan, hintNode)

    # -- Results --
    let entries = vm.results.val
    let selectedIdx = vm.selectedIndex.val
    r.clearChildren(resultsContainer)
    if entries.len == 0:
      r.setAttribute(resultsContainer, "class",
                     CommandPaletteResultsClass & " " &
                       CommandPaletteHiddenModifier)
    else:
      r.setAttribute(resultsContainer, "class", CommandPaletteResultsClass)
      for i, entry in entries:
        let isSelected = (i == selectedIdx)
        let row = renderMockResultRow(r, vm, entry, i, isSelected)
        r.appendChild(resultsContainer, row)

    # -- Empty-state overlay --
    if vm.isActive.val and entries.len == 0 and vm.inputValue.val.len > 0:
      r.setAttribute(emptyContainer, "class", "command-empty-overlay")
    else:
      r.setAttribute(emptyContainer, "class",
                     "command-empty-overlay " & CommandPaletteHiddenModifier)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = "";
                        elemId: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element with optional class + id
    ## attributes.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    if elemId.len > 0:
      isonim_dom.setAttribute(n, cstring"id", cstring(elemId))
    n

  proc createWebTextElement(tag: string; textValue: string;
                            cssClass: string = "";
                            elemId: string = ""): isonim_dom.Element =
    ## Helper: create an element with a text-node child in one shot.
    let n = createWebElement(tag, cssClass, elemId)
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderWebResultRow(vm: CommandPaletteVM;
                          entry: CommandPaletteResultEntry;
                          index: int;
                          selected: bool): isonim_dom.Element =
    ## Build one dropdown row in the real DOM.  Same shape as the
    ## Mock variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", resultRowClass(entry, index, selected))
    let rowIndex = index
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) =
      vm.setSelected(rowIndex))

    let valueSpan = createWebTextElement("span", entry.value,
                                         "command-result-value")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(valueSpan))

    let suffixSpan = createWebTextElement("span", rowSuffixText(entry),
                                          "command-result-suffix")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(suffixSpan))
    row

  proc renderCommandPalettePanel*(r: WebRenderer;
                                  vm: CommandPaletteVM): isonim_dom.Element =
    ## Render the Command Palette panel for the real DOM.  Same
    ## dispatch shape as the Mock variant — outer wrapper plus a
    ## render-effect that rebuilds the result list, updates the
    ## input value + placeholder, and toggles the empty-state
    ## placeholder + outer hidden modifier.
    var outerContainer: isonim_dom.Element
    var inputField: isonim_dom.Element
    var placeholderSpan: isonim_dom.Element
    var resultsContainer: isonim_dom.Element
    var emptyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(ref = outerContainer, class = CommandPaletteContainerClass):
        tdiv(class = CommandPaletteSurfaceClass):
          tdiv(class = "command-input-row"):
            input(ref = inputField, class = CommandPaletteInputFieldClass)
            span(ref = placeholderSpan, class = CommandPalettePlaceholderClass):
              text ""
          tdiv(ref = resultsContainer, class = CommandPaletteResultsClass):
            discard
          tdiv(ref = emptyContainer, class = "command-empty-overlay"):
            text CommandPaletteEmptyStateText

    createRenderEffect proc() =
      # -- Outer container visibility --
      isonim_dom.setAttribute(outerContainer, cstring"class",
                              cstring(containerClass(vm.isActive.val)))

      # -- Input field value + placeholder --
      isonim_dom.setAttribute(inputField, cstring"value",
                              cstring(vm.inputValue.val))
      isonim_dom.setAttribute(placeholderSpan, cstring"data-hint",
                              cstring(vm.inputPlaceholder.val))
      clearWebChildren(placeholderSpan)
      if vm.inputPlaceholder.val.len > 0:
        let hint = isonim_dom.createTextNode(
          isonim_dom.document, cstring(vm.inputPlaceholder.val))
        isonim_dom.appendChild(isonim_dom.Node(placeholderSpan), hint)

      # -- Results --
      let entries = vm.results.val
      let selectedIdx = vm.selectedIndex.val
      clearWebChildren(resultsContainer)
      if entries.len == 0:
        isonim_dom.setAttribute(resultsContainer, cstring"class",
                                cstring(CommandPaletteResultsClass & " " &
                                          CommandPaletteHiddenModifier))
      else:
        isonim_dom.setAttribute(resultsContainer, cstring"class",
                                cstring(CommandPaletteResultsClass))
        for i, entry in entries:
          let isSelected = (i == selectedIdx)
          let row = renderWebResultRow(vm, entry, i, isSelected)
          isonim_dom.appendChild(isonim_dom.Node(resultsContainer),
                                 isonim_dom.Node(row))

      # -- Empty-state overlay --
      if vm.isActive.val and entries.len == 0 and vm.inputValue.val.len > 0:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"command-empty-overlay")
      else:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring("command-empty-overlay " &
                                          CommandPaletteHiddenModifier))

    panel

  proc mountIsoNimCommandPalettePanel*(container: isonim_dom.Element;
                                       vm: CommandPaletteVM) =
    ## Mount the IsoNim Command Palette panel as a child of
    ## ``container``.  Reactive effects handle every subsequent
    ## update — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderCommandPalettePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
