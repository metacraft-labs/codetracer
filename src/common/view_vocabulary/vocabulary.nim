## view_vocabulary/vocabulary.nim — PLAT-3. The sixteen abstract views, each
## specified by BEHAVIOUR AND STATE, with no reference to any medium.
##
## ## THE ENUM IS NOT DEFINED HERE, AND THAT IS THE POINT
##
## `ViewKind` is `value_presentation.PresentationKind`, re-exported. PLAT-2
## opened that enum with five of PLAT-3's sixteen entries under PLAT-3's own
## names, and its header recorded the contract this milestone had to keep:
## "PLAT-3 adds the eleven entries this module does not name, and renames
## nothing". So the eleven were added THERE, and this module names none of
## them a second time. There is exactly one `Text` in the tree.
##
## What lives here is everything the enum is not: the state each entry carries,
## the keyboard contract each entry answers (`behaviour.nim`), the check that
## says whether a view is portable (`portability.nim`), the admission test
## (`admission.nim`) and the three front-end mappings (`mappings.nim`).
##
## ## SPECIFIED AGAINST THE TERMINAL FIRST
##
## PLAT-3's verification gate: "the vocabulary is designed against the terminal
## first. A vocabulary that works in cells maps onto pixels; the reverse is not
## true." Three consequences are structural rather than advisory, and each is
## enforced by `portability.checkPortable`:
##
##   1. EVERY interactive entry has a keyboard contract, and `activation` may
##      not be pointer-only. A terminal user may have no pointer at all
##      (PLAT-6 deliverable 3 says so in as many words), so a view whose only
##      way in is a click is not a view this vocabulary can carry.
##   2. NO GEOMETRY. There is no width, no height, no pixel, no cell and no
##      indent anywhere in `ViewNode`. Size is the layout's question
##      (PLAT-4/PLAT-5), not the vocabulary's, and a vocabulary that answered
##      it would answer it in one medium's units.
##   3. AN IMAGE CARRIES A TEXT EQUIVALENT. `alt` is not decoration: on a
##      terminal without a graphics protocol it is the entire rendering, and
##      PLAT-14 exists precisely because that case is the common one today.
##      An `Image` without `alt` is a portability violation, not a warning.
##
## ## STATE, NOT APPEARANCE
##
## `ViewNode` has one field per piece of state an entry's BEHAVIOUR needs and
## not one more. There is no colour, no class, no border, no font and no
## alignment. `PresentationClass` (the semantic "this is an integer") already
## exists on the value side for the one case where a front-end needs to key a
## style off meaning; nothing analogous is needed here, because a `Button` is a
## button in every medium.
##
## ## THE SIXTEEN, BY BEHAVIOUR AND STATE
##
##   `Text`      An immutable run of characters. State: `text`. No actuation,
##               no focus, no keys. The one entry every medium has trivially.
##
##   `Button`    A named action a reader can invoke. State: `label`,
##               `disabled`. Behaviour: activation raises the `activate`
##               transition exactly once; a disabled button raises nothing.
##
##   `Checkbox`  An independent boolean with a name. State: `label`,
##               `checked`, `disabled`. Behaviour: activation flips `checked`
##               and raises `check` or `uncheck`. INDEPENDENT is the word that
##               separates it from `Toggle`: nothing about a checkbox implies
##               the change takes effect immediately.
##
##   `Toggle`    A boolean that IS the setting rather than a request to change
##               it. State: `label`, `checked`, `disabled`. Same transitions as
##               `Checkbox` under different names (`on`/`off`) because the
##               difference a reader must be able to observe is when the effect
##               lands, and that is a behavioural difference rather than a
##               drawing one. Every medium draws them differently for the same
##               reason (`[x]` against a slider, a tick against a switch), and
##               that agreement across media is the evidence they are two
##               entries rather than one skinned twice.
##
##   `Input`     A single-line editable string with a caret. State: `text`,
##               `cursor` (in RUNES, never bytes or cells), `disabled`.
##               Behaviour: insert, delete before/after the caret, caret
##               motion, `submit`. Multi-line editing is deliberately NOT here
##               — see "what is not in the vocabulary" below.
##
##   `Select`    A closed choice of one option from a known list, with an
##               overlay state. State: `options`, `selected` (the COMMITTED
##               choice, -1 for none), `highlight` (the choice being
##               considered while open), `open`. Behaviour: open, move the
##               highlight, commit (which sets `selected` and closes), dismiss
##               (which closes and leaves `selected` alone). The separation of
##               `selected` from `highlight` is the whole behaviour: a reader
##               who arrows past an option and then presses Escape has not
##               chosen it.
##
##   `List`      An ordered set of items with one highlighted. State:
##               `options`, `highlight`. Behaviour: move by one, jump to
##               first/last, `activate` the highlighted item. Disabled items
##               are skipped by motion and cannot be activated.
##
##   `Tree`      Named children with per-node expansion and one cursor. State:
##               `children` (recursive), per-node `expanded`, `cursor` as an
##               index into the FLATTENED visible rows. Behaviour: move the
##               cursor by one visible row, expand, collapse, activate.
##               Collapsing a node whose descendants held the cursor moves the
##               cursor to that node — otherwise the cursor names a row that is
##               not on screen, which no medium can draw.
##
##   `Table`     Rows of cells under named columns, with a cell cursor. State:
##               `columns`, `rows`, `cursor` (row), `column`. Behaviour: move
##               the cursor in two dimensions, activate the current cell.
##               Column WIDTH is not state: it is the layout's answer.
##
##   `Tabs`      A one-of-N selection over labelled pages. State: `options`
##               (the tab labels), `selected` (the active tab). Behaviour:
##               next, previous, first, last. There is no highlight/commit
##               split as in `Select`, because activating a tab IS the
##               selection; that difference is why they are two entries.
##
##   `Collapsible` A titled region whose body is present or absent. State:
##               `label`, `expanded`, `children`. Behaviour: expand, collapse.
##               Distinct from `Tree` in that there is no cursor and no
##               recursion: a `Collapsible` is one disclosure, and a `Tree` is
##               a cursor over many.
##
##   `Modal`     A region that takes exclusive input until dismissed. State:
##               `label` (its title), `open`, `children`. Behaviour: dismiss.
##               The EXCLUSIVITY is the medium-independent part — a terminal
##               expresses it as a focus trap and the DOM as an inert
##               background, and both are the same statement about where input
##               goes.
##
##   `Menu`      A transient list of commands, opened at a point in the
##               reader's attention, from which exactly one is chosen or none.
##               State: `options`, `highlight`, `open`. Behaviour: move the
##               highlight, activate, dismiss. Distinct from `Select` because
##               it commits an ACTION rather than a VALUE, so it has no
##               `selected`: there is nothing to still be showing afterwards.
##
##   `ProgressIndicator` The state of an operation that is not finished.
##               State: `progress`, 0..100, or `ProgressIndeterminate` (-1)
##               when the fraction is unknown. Behaviour: none — a reader
##               cannot act on it. Indeterminate is a VALUE and not a second
##               entry, because "we do not know the fraction" is an answer to
##               the same question.
##
##   `Image`     Raster or vector media, by MIME type, WITH a text equivalent.
##               State: `mediaType`, `mediaBytes`, `alt`. Behaviour: none.
##               `alt` is required — see the terminal-first note above.
##
##   `Markdown`  A document in a portable markup, rendered rather than shown
##               as source. State: `text` (the source). Behaviour: none in the
##               vocabulary. Scrolling belongs to the layout, and link
##               activation is deliberately absent until something needs it —
##               adding it would be adding an entry's behaviour because a
##               surface wanted it, which is what the admission test exists to
##               refuse.
##
## ## WHAT IS NOT IN THE VOCABULARY, AND HOW A VIEW SAYS SO
##
## A source editor, a rendered frame, a timeline scrubber and a graph view are
## PLAT-9's native views: written against one renderer, declared per surface as
## `required` or `optional`. A `ViewNode` names one by setting `nativeMedium`
## and `nativeView`, and `portability.checkPortable` REFUSES any tree
## containing one. That is the intended arrangement rather than a gap: a native
## view is legal where a front-end has been named and illegal where a view
## claims to run everywhere, and the check is what tells the two apart.

import std/[strutils, unicode]

import ../value_presentation/vocabulary as presentation_vocabulary

export presentation_vocabulary.PresentationKind

type
  ViewKind* = presentation_vocabulary.PresentationKind
    ## PLAT-3's closed set of sixteen. Declared in
    ## `value_presentation/vocabulary.nim` — see this module's header for why
    ## it is not declared here.

  Activation* = enum
    ## HOW a reader can reach an interactive view. A set rather than an enum
    ## value: most views accept both, and the ones that accept only one are the
    ## interesting case.
    ##
    ## `acKeyboard` is not optional for an interactive entry, and
    ## `portability.checkPortable` is where that is enforced rather than here,
    ## so a caller can BUILD the pointer-only node the check then refuses. A
    ## constraint the type system makes unrepresentable cannot be tested for,
    ## and PLAT-3 asks for a test that a medium-specific escape is rejected.
    acKeyboard
    acPointer

  ViewOption* = object
    ## One member of a `Select`, `List`, `Menu` or `Tabs`.
    ##
    ## An option is (identity, label, availability) and nothing else. It is
    ## deliberately NOT a `ViewNode`: an option that could be an arbitrary view
    ## would make every list a nested render tree, and no medium's list widget
    ## takes one.
    id*: string        ## stable identity, for the caller to act on
    label*: string     ## what a reader sees
    disabled*: bool    ## present, but not choosable; motion skips it

  ViewNode* = ref object
    ## One node of an abstract view.
    ##
    ## ONE OBJECT WITH PER-KIND FIELDS, not a variant object, for the same
    ## reason `PresentationNode` is: a binding walks a tree and asks each node
    ## what it is, and a variant object turns every such walk into a `case`
    ## that has to be total over sixteen kinds even where fifteen of them are
    ## irrelevant. The per-kind meaning of every field is in the header, and
    ## `portability.nim` checks the ones that are load-bearing.
    kind*: ViewKind
    id*: string
      ## Stable identity within the view. Two nodes with the same `id` in one
      ## tree is a portability violation: a binding on a medium with real
      ## focus needs to name the node that has it.
    label*: string
      ## `Button`, `Checkbox`, `Toggle`, `Collapsible`, `Modal` — the node's
      ## own name. Empty elsewhere.
    text*: string
      ## `Text` content, `Input` value, `Markdown` source. Empty elsewhere.
    disabled*: bool
      ## Interactive entries only. A disabled node answers no key.
    checked*: bool
      ## `Checkbox`, `Toggle`.
    options*: seq[ViewOption]
      ## `Select`, `List`, `Menu`, `Tabs`.
    selected*: int
      ## `Select` (the COMMITTED choice) and `Tabs` (the active tab). -1 means
      ## none. `List` and `Menu` do not use it — see `highlight`.
    highlight*: int
      ## `Select`, `List`, `Menu` — the option under the reader's attention,
      ## which is not yet a choice. -1 means none.
    open*: bool
      ## `Select`, `Modal`, `Menu` — whether the transient region is showing.
    expanded*: bool
      ## `Collapsible`, and every `Tree` node.
    cursor*: int
      ## `Input` — the caret, in RUNES. `Tree` — the index into the flattened
      ## visible rows. `Table` — the row.
    column*: int
      ## `Table` — the column.
    columns*: seq[string]
      ## `Table` — the column names.
    rows*: seq[seq[string]]
      ## `Table` — the cells, row-major. A ragged row is a portability
      ## violation; no medium's table can draw one.
    children*: seq[ViewNode]
      ## `Tree` children, `Collapsible` body, `Modal` body.
    progress*: int
      ## `ProgressIndicator` — 0..100, or `ProgressIndeterminate`.
    mediaType*: string
      ## `Image` — the MIME type, e.g. `image/png`.
    mediaBytes*: int
      ## `Image` — the payload size. Carried because a one-line surface renders
      ## `<image/png, 2048 bytes>` and PLAT-2 already specifies that string.
    alt*: string
      ## `Image` — the text equivalent. REQUIRED; see the header.
    activation*: set[Activation]
      ## Interactive entries only. `{}` on a non-interactive entry.
    nativeMedium*: string
      ## PLAT-9's escape. Non-empty names the ONE front-end this node is
      ## written against (`terminal`, `web`, `gpui`). `checkPortable` refuses
      ## any tree containing one.
    nativeView*: string
      ## The native view's own id, meaningful only beside `nativeMedium`.

const
  ProgressIndeterminate* = -1
    ## `ProgressIndicator.progress` when the fraction is unknown.

  InteractiveKinds*: set[ViewKind] = {
    pkButton, pkCheckbox, pkToggle, pkInput, pkSelect, pkList, pkTree,
    pkTable, pkTabs, pkCollapsible, pkModal, pkMenu}
    ## The twelve entries a reader can act on. The other four — `Text`,
    ## `ProgressIndicator`, `Image`, `Markdown` — are readings, not controls,
    ## and answer no key in any medium.

  ContainerKinds*: set[ViewKind] = {pkTree, pkCollapsible, pkModal}
    ## The three entries whose `children` are part of their meaning.

func vocabularyName*(k: ViewKind): string =
  ## `pkProgressIndicator` -> `ProgressIndicator`. The spelling PLAT-3 uses,
  ## derived from the enum rather than written twice, so a table of names
  ## cannot drift from the enum it describes.
  ($k)[2 .. ^1]

# ---------------------------------------------------------------------------
# Builders
#
# One per entry, so a caller cannot construct a node whose kind and state
# disagree by forgetting a field. Each sets `activation` for the entry it
# builds; the pointer-only escape is reachable only by overriding it after the
# fact, which is exactly what the portability test does.
# ---------------------------------------------------------------------------

const BothMeans = {acKeyboard, acPointer}

func viewText*(id, text: string): ViewNode =
  ViewNode(kind: pkText, id: id, text: text, selected: -1, highlight: -1)

func viewButton*(id, label: string; disabled = false): ViewNode =
  ViewNode(kind: pkButton, id: id, label: label, disabled: disabled,
           selected: -1, highlight: -1, activation: BothMeans)

func viewCheckbox*(id, label: string; checked = false;
                   disabled = false): ViewNode =
  ViewNode(kind: pkCheckbox, id: id, label: label, checked: checked,
           disabled: disabled, selected: -1, highlight: -1,
           activation: BothMeans)

func viewToggle*(id, label: string; checked = false;
                 disabled = false): ViewNode =
  ViewNode(kind: pkToggle, id: id, label: label, checked: checked,
           disabled: disabled, selected: -1, highlight: -1,
           activation: BothMeans)

func viewInput*(id, text: string; cursor = -1; disabled = false): ViewNode =
  ## `cursor = -1` means "at the end", which is where a caret goes when a
  ## field is filled in from a model rather than typed into.
  let caret = if cursor < 0: text.runeLen else: cursor
  ViewNode(kind: pkInput, id: id, text: text, cursor: caret,
           disabled: disabled, selected: -1, highlight: -1,
           activation: BothMeans)

func viewSelect*(id: string; options: seq[ViewOption]; selected = -1;
                 disabled = false): ViewNode =
  ViewNode(kind: pkSelect, id: id, options: options, selected: selected,
           highlight: selected, disabled: disabled, activation: BothMeans)

func viewList*(id: string; options: seq[ViewOption];
               highlight = 0; disabled = false): ViewNode =
  let h = if options.len == 0: -1 else: highlight
  ViewNode(kind: pkList, id: id, options: options, highlight: h,
           selected: -1, disabled: disabled, activation: BothMeans)

func viewTreeNode*(id, label: string; children: seq[ViewNode] = @[];
                   expanded = false): ViewNode =
  ## A node of a `Tree`. The ROOT of a tree is built the same way; `cursor` is
  ## meaningful only on the root, which is where the flattening starts.
  ViewNode(kind: pkTree, id: id, label: label, children: children,
           expanded: expanded, selected: -1, highlight: -1,
           activation: BothMeans)

func viewTable*(id: string; columns: seq[string];
                rows: seq[seq[string]]; disabled = false): ViewNode =
  ViewNode(kind: pkTable, id: id, columns: columns, rows: rows,
           cursor: (if rows.len == 0: -1 else: 0), column: 0,
           selected: -1, highlight: -1, disabled: disabled,
           activation: BothMeans)

func viewTabs*(id: string; options: seq[ViewOption];
               selected = 0): ViewNode =
  let s = if options.len == 0: -1 else: selected
  ViewNode(kind: pkTabs, id: id, options: options, selected: s,
           highlight: -1, activation: BothMeans)

func viewCollapsible*(id, label: string; children: seq[ViewNode] = @[];
                      expanded = false): ViewNode =
  ViewNode(kind: pkCollapsible, id: id, label: label, children: children,
           expanded: expanded, selected: -1, highlight: -1,
           activation: BothMeans)

func viewModal*(id, label: string; children: seq[ViewNode] = @[];
                open = true): ViewNode =
  ViewNode(kind: pkModal, id: id, label: label, children: children,
           open: open, selected: -1, highlight: -1, activation: BothMeans)

func viewMenu*(id: string; options: seq[ViewOption]; open = true;
               highlight = 0): ViewNode =
  let h = if options.len == 0: -1 else: highlight
  ViewNode(kind: pkMenu, id: id, options: options, highlight: h,
           selected: -1, open: open, activation: BothMeans)

func viewProgress*(id: string; progress: int): ViewNode =
  ViewNode(kind: pkProgressIndicator, id: id, progress: progress,
           selected: -1, highlight: -1)

func viewImage*(id, mediaType, alt: string; mediaBytes = 0): ViewNode =
  ViewNode(kind: pkImage, id: id, mediaType: mediaType, alt: alt,
           mediaBytes: mediaBytes, selected: -1, highlight: -1)

func viewMarkdown*(id, source: string): ViewNode =
  ViewNode(kind: pkMarkdown, id: id, text: source, selected: -1,
           highlight: -1)

func nativeEscape*(id, medium, viewId: string): ViewNode =
  ## PLAT-9's sanctioned escape, built deliberately so that a caller writing
  ## one has said which front-end it is for. It carries `pkText` as its kind
  ## because the vocabulary has no seventeenth entry and inventing one would
  ## make the closed set open; what marks it is `nativeMedium`, and
  ## `checkPortable` reads that.
  ViewNode(kind: pkText, id: id, nativeMedium: medium, nativeView: viewId,
           selected: -1, highlight: -1)

# ---------------------------------------------------------------------------
# Reading a view back
# ---------------------------------------------------------------------------

iterator walk*(root: ViewNode): ViewNode =
  ## Every node of the tree, root first, depth-first, children in order.
  ## Written iteratively rather than recursively so it is usable from `func`
  ## call sites without a closure iterator.
  var stack = @[root]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    yield n
    for i in countdown(n.children.high, 0):
      stack.add n.children[i]

type
  StateFact* = object
    ## One (node, field, value) triple of a view's observable state.
    ##
    ## THE UNIT OF CROSS-MEDIUM COMPARISON. PLAT-3's integration test asks that
    ## a view "renders and behaves equivalently on the terminal and the web,
    ## asserted on ... state transitions, not appearance". Two rendered trees
    ## cannot be compared directly — one is a `TerminalNode` tree of isonim-tui
    ## widgets and the other is a DOM element tree, and they are SUPPOSED to
    ## differ. What must not differ is what each says about the view's state,
    ## so each binding projects its own rendered tree down to these, and the
    ## suite compares the projections.
    ##
    ## Crucially the terminal projection is read out of isonim-tui's WIDGET
    ## OBJECTS — `CheckboxWidget.value`, `TreeWidget.cursor`,
    ## `DataTableWidget.selectedRow` — which are maintained by a library this
    ## repository does not own. That makes it an independent oracle rather than
    ## an echo of `applyKey`.
    id*: string
    field*: string
    value*: string

func fact*(id, field, value: string): StateFact =
  StateFact(id: id, field: field, value: value)

func nodeFacts*(v: ViewNode): seq[StateFact] =
  ## The observable state of ONE node, by kind. Exhaustive.
  case v.kind
  of pkText:
    @[fact(v.id, "text", v.text)]
  of pkButton:
    @[fact(v.id, "label", v.label), fact(v.id, "disabled", $v.disabled)]
  of pkCheckbox, pkToggle:
    @[fact(v.id, "checked", $v.checked)]
  of pkInput:
    @[fact(v.id, "text", v.text), fact(v.id, "cursor", $v.cursor)]
  of pkSelect:
    @[fact(v.id, "selected", $v.selected), fact(v.id, "highlight", $v.highlight),
      fact(v.id, "open", $v.open)]
  of pkList:
    @[fact(v.id, "highlight", $v.highlight)]
  of pkTree:
    # BOTH on every tree node, including the children whose `cursor` is
    # meaningless. Uniformity is what lets a binding stamp `nodeFacts` onto an
    # element without a special case and a reader project it back without one
    # — and a special case on the ROOT only would have to be applied
    # identically in three places that cannot see each other.
    @[fact(v.id, "expanded", $v.expanded), fact(v.id, "cursor", $v.cursor)]
  of pkTable:
    @[fact(v.id, "row", $v.cursor), fact(v.id, "column", $v.column)]
  of pkTabs:
    @[fact(v.id, "selected", $v.selected)]
  of pkCollapsible:
    @[fact(v.id, "expanded", $v.expanded)]
  of pkModal:
    @[fact(v.id, "open", $v.open)]
  of pkMenu:
    @[fact(v.id, "highlight", $v.highlight), fact(v.id, "open", $v.open)]
  of pkProgressIndicator:
    @[fact(v.id, "progress", $v.progress)]
  of pkImage:
    @[fact(v.id, "mediaType", v.mediaType), fact(v.id, "alt", v.alt)]
  of pkMarkdown:
    @[fact(v.id, "text", v.text)]

func stateFacts*(root: ViewNode): seq[StateFact] =
  ## Every node's facts, in walk order.
  for n in walk(root):
    result.add nodeFacts(n)

func describeFacts*(facts: seq[StateFact]): string =
  var lines: seq[string] = @[]
  for f in facts:
    lines.add f.id & "." & f.field & " = " & f.value
  lines.join("\n")

func visibleRows*(root: ViewNode): seq[ViewNode] =
  ## A `Tree` flattened to the rows a medium would draw: the root, then the
  ## children of every EXPANDED node, in order. This is the sequence `cursor`
  ## indexes, and it is defined here rather than in each binding because a
  ## cursor that meant a different row on each medium would make "the same
  ## view behaves the same way" untestable.
  if root.isNil: return
  result.add root
  if root.expanded:
    for c in root.children:
      result.add visibleRows(c)
