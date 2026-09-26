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
##   msAbsent    the front-end has no construct for it at all, AND the binding
##               cannot build one out of what the medium offers. This is a FACT
##               TO REPORT. **Three entries had it on GPUI until 2026-09-15;
##               ONE does now** — see the correction below the third bullet.
##
## ## THE THREE FRONT-ENDS, AS SURVEYED ON 2026-09-07
##
## TERMINAL — `isonim-tui`, widget modules under `src/isonim_tui/widgets/`.
## All sixteen entries land on a dedicated widget, and all sixteen are
## `msComplete` since 2026-09-26. Until then two were partial: `Menu`, because
## the library had no menu (the terminal binding hand-built an
## `OptionListWidget` inside a `ModalWidget`, which ran nothing on `Enter` and
## stayed open), and `Tabs`, because `TabsWidget` wraps at the ends and the
## entry does not — a divergence the cross-medium suite found and asserted.
## isonim-tui now has `widgets/menu.nim` and `TabsWidget(wraps = false)`, and
## each row below says which.
##
## WEB — there is NO general DOM component library, and this was measured
## rather than assumed. `codetracer-design-system`'s 116 components are
## product parts (`agent-status-icon`, `milestone-row`, `call-trace-row`); the
## `isonim_*_view.nim` modules are panes; and `isonim/src/isonim/components/`
## holds four task-list control sets, not a widget tier. What the web front-end
## actually has is HTML elements reached through isonim's `ui()` DSL, whose
## `htmlElements` list carries ~110 tags. That is the mapping target, and it is
## also §3.1's own diagnosis ("a view can be written renderer-agnostically
## today only if it restricts itself to primitives"). Product modules are
## named below where they already implement an entry
## (`viewmodel/views/isonim_toggle_view.renderToggle`,
## `viewmodel/views/isonim_menu_shell_view`, ...) — as evidence the product
## needs the entry, not as the grade: the grade is what the ELEMENT does in a
## browser, measured, and `webMapping`'s own doc comment says how that moved
## the column on 2026-09-26.
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
##   - a tag that is NOT IN `tagMap` AT ALL passes through `mapTag` unchanged.
##     `table`, `tr`, `td`, `th`, `dialog`, `progress`, `option` and `a` are in
##     this group.
##
## **THE THIRD BULLET USED TO END *"…and reaches a Rust classifier with no case
## for it. That is `msAbsent`"*, AND THAT WAS FALSE. Corrected 2026-09-15 by
## PLAT-21, which rendered every one of those tags through the real shim and
## read the plan the Rust side builds.** An unknown tag keeps its spelling and
## classifies as `Div` — the same classification `button`, `input`, `select`,
## `ul` and `li` get, and those five are `msPartial`. `verifyRenderPlan`
## answers true for all of them. Two rows below moved as a consequence
## (`Table` and `ProgressIndicator`, msAbsent -> msPartial) and one did not
## (`Modal`, still msAbsent, for a reason that is about FOCUS rather than about
## the tag). The measurement is in
## `src/frontend/gpui/tests/test_gpui_vocabulary_binding.nim`, and the lesson
## is the campaign's usual one: a status derived from a table's KEYS is a claim
## about the table, not about the renderer.
##
## **AND `Modal` MOVED TOO, ON 2026-09-22, WHICH LEAVES NO `msAbsent` ROW IN
## THE GPUI COLUMN AT ALL.** PLAT-38 gave isonim-gpui element focus — a
## per-node focus flag, a declared order read off the render tree, and a focus
## TRAP that confines the order to a subtree and refuses a focus request from
## outside it — so the exclusivity that `Modal` IS is now something the medium
## offers and the binding sets. `absentEntries(feGpui)` is therefore EMPTY, and
## the two suites that read it assert emptiness as a cardinality with a
## positive twin over all sixteen entries rather than iterating a set that is
## no longer there: a loop over an empty set passes every check written inside
## it (Verification-Harness-Traps §4).
##
## `GpuiTagMap` below is a copy of that table's KEYS, and
## `view_vocabulary_test` verifies the copy against isonim-gpui's own source
## rather than trusting it — with a count assertion, so a scan that read
## nothing cannot pass (Verification-Harness-Traps §4/§4b).
##
## ## WHAT THIS TABLE IS NOT
##
## It is a table of claims, and each column is checked by RENDERING it, not
## by reading it:
##
##   terminal  `src/frontend/tui/tests/test_view_vocabulary_cross_medium.nim`
##             builds real isonim-tui widgets and reads state out of them;
##   web       the same suite on isonim's `MockRenderer`, and
##             `src/frontend/tests/view_vocabulary_chromium_test.nim` (the
##             `renderer-chromium` lane) in a real document in headless
##             Chromium, driven by keys Chromium's own input pipeline delivers;
##   GPUI      `src/frontend/gpui/tests/test_gpui_vocabulary_binding.nim`
##             through the real Rust shim (PLAT-21), and
##             `test_gpui_key_delivery.nim` with keys through a compositor's
##             `wl_seat` (PLAT-38).
##
## (Until PLAT-21 the GPUI column was verified only against the tag table
## below, and until 2026-09-26 the web column only on `MockRenderer`.)

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
    "may RELY on, not what a widget may offer. Its caret counts GRAPHEME " &
    "CLUSTERS, which is the entry's unit since 2026-09-26 (it counted runes " &
    "before, and the two disagreed on every combining sequence)")
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
  of pkTabs: m(msComplete,
    "isonim_tui.TabsWidget (widgets/tabs.nim), with wraps = false",
    "THE WIDGET WRAPS BY DEFAULT AND THE ENTRY DOES NOT, and the library now " &
    "says so in an option: `newTabs(..., wraps = false)` stops at both ends. " &
    "Until 2026-09-26 the row was msPartial and this note was a DIVERGENCE — " &
    "`moveRight` at the last tab set the first and nothing could stop it — " &
    "found by test_view_vocabulary_cross_medium.nim and asserted there as a " &
    "difference. The default still wraps (Textual's behaviour, and the " &
    "WAI-ARIA tabs pattern's), so the binding passing the option is what " &
    "keeps the entry's contract; the cross-medium suite asserts both the " &
    "agreement at the ends and that the library default still wraps, so the " &
    "option cannot quietly stop mattering. Every other isonim-tui selection " &
    "widget — ListView, OptionList, Tree, DataTable, RadioSet — clamps")
  of pkCollapsible: m(msComplete,
    "isonim_tui.CollapsibleWidget (widgets/collapsible.nim)",
    "animates the expansion; the entry specifies the end states and not the " &
    "path between them")
  of pkModal: m(msComplete, "isonim_tui.ModalWidget (widgets/modal.nim)",
    "the focus trap is the library's own, which is what makes the entry's " &
    "exclusivity real rather than drawn")
  of pkMenu: m(msComplete, "isonim_tui.MenuWidget (widgets/menu.nim)",
    "added to isonim-tui on 2026-09-26. Until then the library had NO MENU " &
    "WIDGET and this row was msPartial: the binding hand-built an " &
    "OptionListWidget inside a ModalWidget, and that composition did not " &
    "answer Enter the way the entry specifies — it neither closed nor ran " &
    "anything, which no case asserted because none pressed Enter on the " &
    "menu. MenuWidget is the same two parts (the pairing SelectWidget uses), " &
    "plus the part neither has alone: Enter runs the highlighted command AND " &
    "closes, Escape closes without running")
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
  ## GRADED BY WHAT THE BROWSER DOES, since 2026-09-26. Every "measured"
  ## below is a case in `src/frontend/tests/view_vocabulary_chromium_test.nim`
  ## ("what the browser does on its own"): bare HTML elements in headless
  ## Chromium, trusted keys, no binding. Until then this column was graded on
  ## whether the TAG existed, and read "complete on fifteen" — but the header
  ## above names HTML elements as the web's target, and `msComplete` requires
  ## the construct to ANSWER the entry's keyboard contract. A `<ul>` answers
  ## no key at all; `role="listbox"` declares a pattern, it does not implement
  ## one. Nine rows moved to `msPartial` on that reading — the same reading,
  ## and for the same reason, as GPUI's `ul -> div`. Nothing about what the
  ## web front-end DOES changed with the grade; the grade now says who does it.
  case k
  of pkText: m(msComplete, "<span>")
  of pkButton: m(msComplete, "<button>",
    "measured: Enter and Space both activate a focused <button>, which is " &
    "the entry's contract exactly")
  of pkCheckbox: m(msPartial, "<input type=\"checkbox\">",
    "MEASURED: Space toggles a focused checkbox and Enter does NOT. The " &
    "entry answers both, so Enter is the binding's. msComplete until " &
    "2026-09-26, before anything had pressed a key in a browser")
  of pkToggle: m(msPartial,
    "<input type=\"checkbox\" role=\"switch\">",
    "the DOM has no switch ELEMENT, so the difference from Checkbox is " &
    "carried by the role and the styling — and the role adds no behaviour, " &
    "so this is Checkbox's element with Checkbox's gap: Enter is the " &
    "binding's (measured on the checkbox). The product already has a toggle: " &
    "viewmodel/views/isonim_toggle_view.renderToggle is a data-checked / " &
    "data-size / data-disabled CSS toggle")
  of pkInput: m(msComplete, "<input type=\"text\">",
    "the element edits and moves its caret itself, over GRAPHEME CLUSTERS as " &
    "the entry does (measured: `e` + U+0301 is one step of Right). It also " &
    "moves the caret on Up and Down, which the entry does not claim, so the " &
    "binding prevents those two defaults " &
    "(web_binding.nativeDefaultChangesState). The binding applies the " &
    "vocabulary's editing and keeps the model the source of truth; what makes " &
    "the row complete is that the medium answers the same contract")
  of pkSelect: m(msPartial, "<select> / <option>",
    "MEASURED: a closed, focused <select> COMMITS on Up / Down, Home / End " &
    "and type-ahead, with no highlight step. The entry's highlight/commit " &
    "split exists natively only inside the opened popup, which a page can " &
    "neither style nor read, so `open` and `highlight` are the binding's, " &
    "and it prevents those defaults. This row used to say the native element " &
    "\"commits on change and dismisses on Escape, which is the entry's " &
    "highlight/commit split\" — true of the popup, false of the closed " &
    "control; the browser suite found the difference as a real defect (Down " &
    "on a closed Select showed the second option while the model held the " &
    "first). The product's own dropdown " &
    "(viewmodel/views/isonim_event_log_filter_dropdown_view.nim) builds the " &
    "split over divs for the same reason")
  of pkList: m(msPartial, "<ul role=\"listbox\"> / <li role=\"option\">",
    "the DOM has no highlight and answers no key on these elements; motion, " &
    "the disabled-member skip and the bounds are the binding's, over a " &
    "roving tabindex (ONE element in the tab order, because the entry " &
    "specifies one highlight for the list, not one focus per row)")
  of pkTree: m(msPartial, "<ul role=\"tree\"> / nested <ul>",
    "aria-expanded DECLARES the per-node expansion; the cursor, the " &
    "expand/collapse keys and the visible-row order are the binding's")
  of pkTable: m(msPartial, "<table> / <tr> / <td>",
    "the rows and cells are the medium's; the cell cursor and its keys are " &
    "the binding's. ui/datatable.nim, the product's existing consumer, " &
    "supplies its own for the same reason")
  of pkTabs: m(msPartial,
    "<div role=\"tablist\"> / <div role=\"tab\">",
    "no element answers a key; the selection motion is the binding's. " &
    "(WAI-ARIA's tabs pattern WRAPS at the ends; the entry stops, as " &
    "isonim-tui's TabsWidget does with wraps = false.) " &
    "viewmodel/views/isonim_session_tabs_view.nim is the product's")
  of pkCollapsible: m(msComplete, "<details> / <summary>",
    "measured: Enter and Space on the <summary> disclose and close. The " &
    "binding renders the label as the summary and keeps `open` in step")
  of pkModal: m(msComplete, "<dialog>, shown with showModal()",
    "measured: showModal() makes the rest of the page INERT — a key aimed " &
    "outside lands inside the dialog — and Escape dismisses. The binding " &
    "calls showModal() once the element is in a document " &
    "(web_binding.mountModals); the entry's exclusivity is the medium's")
  of pkMenu: m(msPartial,
    "<div role=\"menu\"> / <div role=\"menuitem\">, hidden while closed",
    "no element answers a key; motion, run-and-close on Enter and dismissal " &
    "are the binding's. The product has a menu of its own " &
    "(viewmodel/views/isonim_menu_shell_view.nim, ui/menu.nim, " &
    "viewmodel/views/context_menu_bridge.nim), which supplies them the same " &
    "way")
  of pkProgressIndicator: m(msComplete, "<progress>",
    "measured: with no value attribute its position is -1 — the DOM's own " &
    "spelling of ProgressIndeterminate")
  of pkImage: m(msComplete, "<img alt=\"…\">",
    "alt is required by the entry and by HTML, for the same reason")
  of pkMarkdown: m(msPartial,
    "a <div> holding the block elements the rendering produces: <p>, " &
    "<h1>..<h6>, <ul> / <ol> / <li>, <pre><code>, <blockquote>, <hr>, and " &
    "the inline <strong>, <em>, <code>, <a>",
    "every element is the medium's and the PARSER is not: the web has no " &
    "Markdown renderer, and view_vocabulary/markdown_blocks.nim is the one " &
    "the binding brings — a CommonMark-subset parser written independently " &
    "of isonim-tui's, and compared with it by the cross-medium suite through " &
    "the block outline each medium's RENDERING reads back as. Until " &
    "2026-09-26 there was no renderer at all and the web drew the source as " &
    "one text node")

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
  of pkTable: m(msPartial, "table / tr / td — none is in tagMap, and each " &
    "KEEPS ITS OWN SPELLING and classifies as a container",
    "**CORRECTED 2026-09-15 BY PLAT-21, FROM msAbsent, AND THE REASON IT GAVE " &
    "WAS FALSE.** This row used to read: *\"mapTag passes an unknown tag " &
    "through unchanged, so `table` reaches a Rust classifier with no case for " &
    "it.\"* PLAT-21 rendered it through the real shim and read the plan the " &
    "Rust side builds: `table`, `tr`, `td`, `th`, `dialog`, `progress` and " &
    "`option` all classify as `Div` and keep their tag string — which is " &
    "EXACTLY what `button`, `input`, `select`, `ul` and `li` get, and those " &
    "five are msPartial. There is no classifier failure and no refused plan " &
    "(`verifyRenderPlan` answers true). So the msAbsent/msPartial distinction " &
    "PLAT-3 drew from tagMap MEMBERSHIP does not survive to the renderer, and " &
    "a table is nested containers here exactly as it is nested elements on " &
    "the web. The row/column relationship is the NESTING and it survives; the " &
    "cursor is the binding's on every medium. Measured by " &
    "`src/frontend/gpui/tests/test_gpui_vocabulary_binding.nim`, case *\"an " &
    "unknown tag does NOT reach a classifier with no case for it\"*")
  of pkTabs: m(msPartial, "nav -> div, button -> div",
    "the tablist and the tabs are all containers")
  of pkCollapsible: m(msPartial, "details -> div, summary -> div",
    "BOTH tags are in tagMap and BOTH collapse to div, so the disclosure " &
    "relationship — which is the entry's whole content — is lost in the tag " &
    "and must be rebuilt by the binding")
  of pkModal: m(msPartial, "dialog — renders as a container; the MODALITY is " &
    "a FOCUS TRAP the binding sets",
    "**MOVED FROM msAbsent TO msPartial BY PLAT-38, AND IT IS THE LAST ROW " &
    "IN THIS COLUMN TO MOVE.** PLAT-21 corrected two rows (`Table` and " &
    "`ProgressIndicator`) and left this one at `msAbsent` for what was, by " &
    "then, the right reason: not the tag — `dialog` keeps its spelling and " &
    "classifies as `Div`, exactly as `table` does — but ELEMENT FOCUS, which " &
    "the renderer did not have. Focus was per WINDOW (`window.onFocus`, per " &
    "window id); no element could hold, trap or refuse it. Exclusivity is " &
    "what the entry IS, so a binding could not supply it out of anything the " &
    "medium offered, and that was the difference between this row and the " &
    "Table row. **isonim-gpui has element focus now** — a per-node focus " &
    "flag, a declared order taken from the render tree, and a focus TRAP " &
    "that confines the order to a subtree and makes a focus request from " &
    "outside it REFUSE. `gpui_binding` sets the trap while the modal is " &
    "open. `msPartial` rather than `msComplete` for the reason every other " &
    "entry in this column is partial: the tag arrives at the renderer " &
    "indistinguishable from a container, so the semantics are the binding's " &
    "to supply — and it now CAN. `gpui_gaps.PLAT21-VG3` is retired; measured " &
    "by `test_gpui_key_delivery.nim`, case *\"a Modal traps focus and the " &
    "outside is refused\"*")
  of pkMenu: m(msPartial, "nav -> div",
    "as Modal for the overlay, minus the exclusivity requirement")
  of pkProgressIndicator: m(msPartial, "progress — not in tagMap; keeps its " &
    "spelling and classifies as a container",
    "**CORRECTED 2026-09-15 BY PLAT-21, FROM msAbsent.** The old row said the " &
    "entry was *\"expressible only as a div whose width the binding computes, " &
    "which is geometry the vocabulary deliberately does not carry\"* — and " &
    "the second half of that sentence is the answer to the first. The entry's " &
    "WHOLE specified state is a number in 0..100 or `ProgressIndeterminate`, " &
    "and a container carrying that number has rendered everything the entry " &
    "specifies. How wide the bar is drawn is geometry, and `vocabulary.nim`'s " &
    "second structural consequence says the vocabulary has none — in any " &
    "medium, including the terminal, where `ProgressBarWidget` computes the " &
    "same width from the same absent field. An entry cannot be short of a " &
    "thing it does not specify. It is msPartial rather than msComplete " &
    "because the tag says `progress` and the renderer treats it as a plain " &
    "container, so what tells a reader it is progress is the binding's")
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

func absentEntries*(fe: FrontEnd): seq[ViewKind] =
  ## Every entry this front-end has NO construct for, READ OUT OF the three
  ## mappings above rather than listed a second time anywhere.
  ##
  ## ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §14). Three places
  ## state "which entries are absent on GPUI" in prose — this module's header,
  ## `Extensibility-Model.md` §3.4 and §6.4, and `plugin_model/surfaces.nim`'s
  ## header — and a fourth written as a literal is exactly where they would
  ## drift apart. They already had: §6.4 and `surfaces.nim` named `Image`,
  ## which is `msComplete` here, and omitted `Modal`, which is `msAbsent`.
  ## Nothing in the tree could contradict them, because nothing read the table.
  ## `plugin_surfaces_test` now compares `surfaces.nim`'s own sentence with
  ## what this function returns.
  ##
  ## In `ViewKind` order, which is the order `mappingSummary` prints.
  for k in ViewKind:
    if mappingFor(fe, k).status == msAbsent: result.add k

func absentEntryNames*(fe: FrontEnd): seq[string] =
  ## `absentEntries`, in PLAT-3's spelling — the form a sentence uses, so a
  ## sentence can be compared with it directly.
  for k in absentEntries(fe): result.add vocabularyName(k)

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
