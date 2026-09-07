## view_vocabulary/mappings.nim — PLAT-3 deliverables 2, 3 and 4. What each
## entry becomes on each of the three front-ends, and how complete that is.
##
## ## WHY THE MAPPING IS DATA AND NOT ONLY CODE
##
## A binding that renders an entry proves the entry can be rendered. It does
## not say what was LOST — and "GPUI puts a `Button` through the same code path
## as a `div`" is the fact PLAT-21's verification gate is about ("the count of
## vocabulary entries needing a GPUI-specific escape is zero, or each is a
## named, filed vocabulary defect"). So each mapping is a value with a STATUS,
## the three functions below are exhaustive over `ViewKind`, and the suite
## cross-checks them against `admission.nim`, which was written from the other
## direction.
##
## `msComplete` / `msPartial` / `msAbsent` mean one thing each:
##
##   msComplete  the front-end has a construct that expresses the entry's state
##               AND answers its keyboard contract, with the binding supplying
##               only the wiring.
##   msPartial   the front-end renders it, but something the entry specifies is
##               supplied by the binding rather than by the medium — a
##               composition of two widgets, or a generic container that has to
##               be taught the behaviour.
##   msAbsent    the front-end has no construct for it at all. This is a FACT
##               TO REPORT, and three entries have it on GPUI.
##
## ## THE THREE FRONT-ENDS, AS SURVEYED ON 2026-09-07
##
## TERMINAL — `isonim-tui`, 36 widget modules under
## `src/isonim_tui/widgets/`. Fifteen of the sixteen entries land on a
## dedicated widget. `Menu` is the exception: there is no `menu.nim`, and the
## closest construct is `command/palette.nim`, which is a fuzzy command
## palette rather than a menu. The terminal `Menu` is therefore a COMPOSITION
## of `OptionListWidget` inside `ModalWidget` — which is, notably, exactly how
## `SelectWidget` is built, so the composition is the library's own idiom
## rather than an invention here.
##
## WEB — there is NO general DOM component library, and this was measured
## rather than assumed. `codetracer-design-system`'s 116 components are
## product parts (`agent-status-icon`, `milestone-row`, `call-trace-row`); the
## `isonim_*_view.nim` modules are panes; and `isonim/src/isonim/components/`
## holds four task-list control sets, not a widget tier. What the web front-end
## actually has is HTML elements reached through isonim's `ui()` DSL, whose
## `htmlElements` list carries ~110 tags. That is the mapping target, and it is
## also §3.1's own diagnosis ("a view can be written renderer-agnostically
## today only if it restricts itself to primitives"). Two product modules are
## named below where they already implement an entry:
## `viewmodel/views/isonim_toggle_view.renderToggle` and
## `viewmodel/views/isonim_menu_shell_view`.
##
## GPUI — `isonim-gpui`'s `GpuiRenderer` satisfies `RendererBackend` and
## translates HTML tags through a **35-entry** `tagMap` in
## `src/isonim_gpui/renderer.nim`. Everything a binding can do on GPUI it does
## by emitting one of those tags, so an entry's GPUI status is decided by what
## its tags become:
##
##   - a tag that PASSES THROUGH (`span`, `p`, `h1`..`h6`, `label`, `strong`,
##     `em`, `small`, `code`, `pre`, `img`, `svg`) keeps its identity on the
##     Rust side, which classifies it into `GpuiElementKind`;
##   - a tag that COLLAPSES TO `div` (`button`, `input`, `select`, `textarea`,
##     `ul`, `ol`, `li`, `details`, `summary`, `nav`, …) renders, but arrives at
##     the renderer indistinguishable from a container, so every semantic the
##     entry specifies has to be supplied by the binding. That is `msPartial`;
##   - a tag that is NOT IN `tagMap` AT ALL passes through `mapTag` unchanged
##     and reaches a Rust classifier with no case for it. `table`, `tr`, `td`,
##     `th`, `dialog`, `progress` and `option` are all in this group. That is
##     `msAbsent`.
##
## `GpuiTagMap` below is a copy of that table's KEYS, and
## `view_vocabulary_test` verifies the copy against isonim-gpui's own source
## rather than trusting it — with a count assertion, so a scan that read
## nothing cannot pass (Verification-Harness-Traps §4/§4b).
##
## ## WHAT THIS TABLE IS NOT
##
## It is not a claim that every mapping has been RENDERED. The cross-medium
## suite (`src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim`)
## renders the terminal and web columns for real and drives their keyboard
## contracts; the GPUI column is verified structurally, against the tag table,
## because linking `isonim_gpui` requires the Rust cdylib at load time and
## `isonim-gpui` is an ADVISORY sibling of this repository (see
## `scripts/require-siblings.sh`). PLAT-21 is the milestone that renders it.

import std/strutils

import ./vocabulary

type
  FrontEnd* = enum
    feTerminal   ## isonim-tui, the terminal front-end
    feWeb        ## the DOM, through isonim's `ui()` DSL
    feGpui       ## isonim-gpui's `GpuiRenderer`

  MappingStatus* = enum
    msAbsent
    msPartial
    msComplete

  Mapping* = object
    status*: MappingStatus
    target*: string
      ## The construct the entry becomes: an isonim-tui widget type, an HTML
      ## tag (or tags), or the tag a GPUI binding emits.
    note*: string
      ## What is lost, composed, or supplied by the binding. Empty when
      ## `msComplete` and nothing needed saying.

const
  GpuiTagMap*: seq[string] = @[
    "div", "section", "article", "main", "aside", "nav", "header", "footer",
    "form", "details", "summary", "fieldset",
    "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label", "strong", "em",
    "small", "code", "pre",
    "button", "input", "textarea", "select",
    "ul", "ol", "li",
    "img", "svg"]
    ## The KEYS of `isonim-gpui`'s `tagMap`, copied here so this module needs
    ## no import of a package that dlopens a Rust cdylib at module init.
    ## Verified against the original by
    ## `src/common/view_vocabulary_test.nim`.

  GpuiPassThroughTags*: seq[string] = @[
    "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label", "strong", "em",
    "small", "code", "pre", "img", "svg"]
    ## The subset that keeps its identity instead of collapsing to `div`.

func gpuiKnowsTag*(tag: string): bool = tag in GpuiTagMap

func gpuiPassesThrough*(tag: string): bool = tag in GpuiPassThroughTags

func m(status: MappingStatus; target: string; note = ""): Mapping =
  Mapping(status: status, target: target, note: note)

# ---------------------------------------------------------------------------
# Terminal — isonim-tui
# ---------------------------------------------------------------------------

func terminalMapping*(k: ViewKind): Mapping =
  ## Exhaustive over `ViewKind`; no `else`. See `behaviour.keyContract` for why
  ## every table in this package is written that way.
  case k
  of pkText: m(msComplete, "isonim_tui.LabelWidget (widgets/label.nim)",
    "StaticWidget for a multi-line block; both are non-focusable, which is " &
    "what Text specifies")
  of pkButton: m(msComplete, "isonim_tui.ButtonWidget (widgets/button.nim)",
    "answers enter/return/space and click, which is the contract exactly")
  of pkCheckbox: m(msComplete,
    "isonim_tui.CheckboxWidget (widgets/checkbox.nim)")
  of pkToggle: m(msComplete, "isonim_tui.SwitchWidget (widgets/switch.nim)",
    "the library keeps Checkbox and Switch as separate widgets for the same " &
    "reason the vocabulary keeps them as separate entries")
  of pkInput: m(msComplete, "isonim_tui.InputWidget (widgets/input.nim)",
    "a SUPERSET: the widget also answers ctrl+a/e/u/w/k/d and shift-extended " &
    "selection. A superset is not a conflict — the contract is what a view " &
    "may RELY on, not what a widget may offer")
  of pkSelect: m(msComplete, "isonim_tui.SelectWidget (widgets/select.nim)",
    "itself a composition of ModalWidget + OptionListWidget; the widget " &
    "keeps the highlight/commit split the entry specifies")
  of pkList: m(msComplete, "isonim_tui.ListViewWidget (widgets/listview.nim)",
    "also answers pageup/pagedown, which the vocabulary declines to specify " &
    "because a page is a viewport height")
  of pkTree: m(msComplete, "isonim_tui.TreeWidget (widgets/tree.nim)",
    "left/right are collapse/expand-or-descend, matching the entry")
  of pkTable: m(msComplete,
    "isonim_tui.DataTableWidget (widgets/datatable.nim)",
    "a SUPERSET: the widget adds a sortable header band reached with Tab. " &
    "The vocabulary does not specify sorting, so a view that needs it needs " &
    "a native view")
  of pkTabs: m(msPartial, "isonim_tui.TabsWidget (widgets/tabs.nim)",
    "THE WIDGET WRAPS AND THE ENTRY DOES NOT. `moveRight` at the last tab " &
    "sets the first, and `moveLeft` at the first sets the last " &
    "(widgets/tabs.nim, the two lines commented `# wrap`). No other WIDGET " &
    "wraps its selection — ListView, OptionList, Tree, DataTable, RadioSet, " &
    "ContentSwitcher and MarkdownViewer all CLAMP, checked by reading each " &
    "one's motion rather than by grepping (`grep -n wrap widgets/*.nim` " &
    "returns 34 lines, and all but these two are TEXT wrapping or the word " &
    "`wrapper`, so the grep is not the evidence). Two non-widget sites DO " &
    "wrap and are named so the claim is not overstated: `command/palette.nim` " &
    "moves `selectedIdx` modularly, and `focus/manager.nim` wraps Tab " &
    "traversal and reports it in a `wrapped` field. So this is a local " &
    "choice among widgets rather than a widget-library convention, and the " &
    "vocabulary does not adopt it. FOUND BY " &
    "test_view_vocabulary_cross_medium.nim, which is what that suite is " &
    "for, and asserted there as a divergence so it cannot change without " &
    "notice. TabbedContentWidget pairs the widget with ContentSwitcherWidget " &
    "when the pages are also the library's")
  of pkCollapsible: m(msComplete,
    "isonim_tui.CollapsibleWidget (widgets/collapsible.nim)",
    "animates the expansion; the entry specifies the end states and not the " &
    "path between them")
  of pkModal: m(msComplete, "isonim_tui.ModalWidget (widgets/modal.nim)",
    "the focus trap is the library's own, which is what makes the entry's " &
    "exclusivity real rather than drawn")
  of pkMenu: m(msPartial,
    "isonim_tui.OptionListWidget inside isonim_tui.ModalWidget",
    "THERE IS NO MENU WIDGET IN isonim-tui. The 36 widget modules include no " &
    "menubar, context menu or dropdown menu; command/palette.nim is a fuzzy " &
    "command palette, which is a different thing. The composition used here " &
    "is the same one SelectWidget uses internally, so the Escape binding " &
    "comes from the Modal and the motion from the OptionList")
  of pkProgressIndicator: m(msComplete,
    "isonim_tui.ProgressBarWidget / isonim_tui.LoadingIndicatorWidget",
    "two widgets for one entry: the bar for a known fraction, the spinner " &
    "for ProgressIndeterminate. That is a binding choice on a value, not a " &
    "second entry")
  of pkImage: m(msComplete, "isonim_tui.ImageWidget (widgets/image.nim)",
    "Kitty / iTerm2 / Sixel with a Unicode-quadrant fallback; where no " &
    "protocol is available the binding renders `alt`, which is why alt is " &
    "required. PLAT-14 deepens the fallback tiers")
  of pkMarkdown: m(msComplete,
    "isonim_tui.MarkdownWidget (widgets/markdown.nim)",
    "a full CommonMark parser in the library; MarkdownViewerWidget adds a " &
    "table of contents, which the entry does not specify")

# ---------------------------------------------------------------------------
# Web — the DOM
# ---------------------------------------------------------------------------

func webMapping*(k: ViewKind): Mapping =
  case k
  of pkText: m(msComplete, "<span>")
  of pkButton: m(msComplete, "<button>")
  of pkCheckbox: m(msComplete, "<input type=\"checkbox\">")
  of pkToggle: m(msComplete,
    "<input type=\"checkbox\" role=\"switch\">",
    "the DOM has no switch ELEMENT, so the difference from Checkbox is " &
    "carried by the role and the styling. The product already has this: " &
    "viewmodel/views/isonim_toggle_view.renderToggle is a data-checked / " &
    "data-size / data-disabled CSS toggle")
  of pkInput: m(msComplete, "<input type=\"text\">")
  of pkSelect: m(msComplete, "<select> / <option>",
    "the native element commits on change and dismisses on Escape, which is " &
    "the entry's highlight/commit split. The product's own dropdown " &
    "(viewmodel/views/isonim_event_log_filter_dropdown_view.nim) reproduces " &
    "it over divs where the native element cannot be styled")
  of pkList: m(msComplete, "<ul> / <li> with a roving tabindex",
    "roving tabindex rather than one tabindex per item, because the entry " &
    "specifies ONE highlight for the list and not one focus per row")
  of pkTree: m(msComplete, "<ul role=\"tree\"> / <li role=\"treeitem\">",
    "aria-expanded carries the per-node expansion the entry specifies")
  of pkTable: m(msComplete, "<table> / <tr> / <td>",
    "the cell cursor is a roving tabindex over cells; ui/datatable.nim is " &
    "the product's existing consumer")
  of pkTabs: m(msComplete,
    "<div role=\"tablist\"> / <button role=\"tab\">",
    "viewmodel/views/isonim_session_tabs_view.nim is the product's")
  of pkCollapsible: m(msComplete, "<details> / <summary>")
  of pkModal: m(msComplete, "<dialog>",
    "showModal() supplies the exclusivity and the Escape binding")
  of pkMenu: m(msComplete,
    "<div role=\"menu\"> / <div role=\"menuitem\">",
    "the product has this already: viewmodel/views/isonim_menu_shell_view.nim " &
    "plus ui/menu.nim and viewmodel/views/context_menu_bridge.nim. This is " &
    "the entry the TERMINAL is missing, which is why the admission test's " &
    "second half — does at least one front-end already have it — matters")
  of pkProgressIndicator: m(msComplete, "<progress>",
    "omitting the value attribute is the DOM's own spelling of " &
    "ProgressIndeterminate")
  of pkImage: m(msComplete, "<img alt=\"…\">",
    "alt is required by the entry and by HTML, for the same reason")
  of pkMarkdown: m(msPartial,
    "a <div> holding the block elements the rendering produces: <p>, " &
    "<h1>..<h6>, <ul>, <code>, <pre>, <a>",
    "THERE IS NO MARKDOWN RENDERER IN THE WEB FRONT-END. isonim-tui ships a " &
    "1,241-line CommonMark parser; the DOM side has none, so a binding must " &
    "bring one or reuse isonim-tui's parser for its AST. The TARGET is " &
    "complete — every element the render needs is an ordinary tag — and the " &
    "RENDERER is what is absent, which is why this is partial rather than " &
    "absent")

# ---------------------------------------------------------------------------
# GPUI — isonim-gpui
# ---------------------------------------------------------------------------

func gpuiMapping*(k: ViewKind): Mapping =
  case k
  of pkText: m(msComplete, "span",
    "passes through tagMap unchanged; the Rust side classifies it as a text " &
    "container")
  of pkButton: m(msPartial, "button -> div",
    "renders and takes a click listener, but arrives at the renderer as a " &
    "container. Every affordance the entry specifies is the binding's")
  of pkCheckbox: m(msPartial, "input -> div",
    "same collapse; the [x] / [ ] state has no representation in the tag")
  of pkToggle: m(msPartial, "input -> div",
    "the same collapse as Checkbox, and with the same consequence: the tag " &
    "cannot distinguish the two entries, so what tells a reader them apart " &
    "is entirely the binding's")
  of pkInput: m(msPartial, "input -> div",
    "the caret, the selection and the key handling are all the binding's. " &
    "gpui-kit has an editor (PLAT-22 evaluates it); GpuiRenderer does not " &
    "expose it")
  of pkSelect: m(msPartial, "select -> div",
    "the overlay has to be a second element the binding positions; there is " &
    "no popup concept at the renderer level")
  of pkList: m(msPartial, "ul -> div, li -> div",
    "the rows survive as containers; the highlight is the binding's")
  of pkTree: m(msPartial, "ul -> div, li -> div",
    "as List, plus per-node expansion the binding tracks")
  of pkTable: m(msAbsent, "table / tr / td — NONE of them is in tagMap",
    "mapTag passes an unknown tag through unchanged, so `table` reaches a " &
    "Rust classifier with no case for it. A binding must re-encode the table " &
    "as nested divs, which drops the row/column relationship the entry's " &
    "two-dimensional cursor is defined over. THIS IS A NAMED VOCABULARY/" &
    "RENDERER GAP for PLAT-21's gate, not a workaround to be applied quietly")
  of pkTabs: m(msPartial, "nav -> div, button -> div",
    "the tablist and the tabs are all containers")
  of pkCollapsible: m(msPartial, "details -> div, summary -> div",
    "BOTH tags are in tagMap and BOTH collapse to div, so the disclosure " &
    "relationship — which is the entry's whole content — is lost in the tag " &
    "and must be rebuilt by the binding")
  of pkModal: m(msAbsent, "dialog — not in tagMap",
    "there is no modality, no focus trap and no layer at the renderer level. " &
    "A binding must build the exclusivity itself, and exclusivity is what " &
    "the entry IS. Named for PLAT-21")
  of pkMenu: m(msPartial, "nav -> div",
    "as Modal for the overlay, minus the exclusivity requirement")
  of pkProgressIndicator: m(msAbsent, "progress — not in tagMap",
    "expressible only as a div whose width the binding computes, which is " &
    "geometry the vocabulary deliberately does not carry. Named for PLAT-21")
  of pkImage: m(msComplete, "img",
    "one of two tags that reach a dedicated Rust element kind " &
    "(GpuiElementKind::Img); svg is the other")
  of pkMarkdown: m(msPartial,
    "p, h1..h6, code, pre, strong, em pass through; ul/ol/li collapse to " &
    "div and `a` is not in tagMap at all",
    "block text renders with its identity intact, lists flatten, and links " &
    "have no tag. Rust's tree.rs accepts `a`, so this is a tagMap omission " &
    "rather than a renderer limit")

func mappingFor*(fe: FrontEnd; k: ViewKind): Mapping =
  case fe
  of feTerminal: terminalMapping(k)
  of feWeb: webMapping(k)
  of feGpui: gpuiMapping(k)

func frontEndName*(fe: FrontEnd): string =
  case fe
  of feTerminal: "terminal"
  of feWeb: "web"
  of feGpui: "gpui"

func mappingSummary*(): string =
  ## The whole table, one row per entry, as a fixed-width report. Written so a
  ## reader can see the three columns beside each other, which is the form the
  ## milestone asks the result to be reported in.
  var lines: seq[string] = @[]
  lines.add "entry               terminal   web        gpui"
  for k in ViewKind:
    var row = vocabularyName(k)
    while row.len < 20: row.add ' '
    for fe in FrontEnd:
      var cell = case mappingFor(fe, k).status
        of msComplete: "complete"
        of msPartial: "partial"
        of msAbsent: "ABSENT"
      while cell.len < 11: cell.add ' '
      row.add cell
    lines.add row.strip(leading = false)
  lines.join("\n")
