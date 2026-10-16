## scope_path.nim — WHERE THE FOCUS IS, as data every front-end produces.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §5.2's scope path — the list of
## elements from the window to the focused element — its element kinds, the
## binding TABLE each element contributes to resolution, and the pane kinds a
## `paneKind` comparison may name.
##
## Refuses to own: how a front-end finds its focus (§6.2: the desktop reads
## the DOM's `data-scope-*` attributes, GPUI its focus chain, the terminal its
## node tree), what the context keys are (`context_keys.contextKeysOf`), and
## resolution (`editing_keymap.resolveLayers`).
##
## A scope path is DATA, and it is all the resolver knows about focus. Two
## front-ends that produce the same path for the same layout and focus are,
## from here on, indistinguishable — which is what `DIFF-13` asserts.
##
## Pure; compiles on C, JS and wasm32.

import std/strutils

type
  ElementKind* = enum
    ## The kinds of element a path is made of. The first three are the
    ## frame (window, session tab, pane); the rest are what can hold the
    ## focus inside a pane — §4.2's `elementKind` domain.
    ekWindow = "window"
    ekTab = "tab"
    ekPane = "pane"
    ekEditor = "editor"
    ekRow = "row"
    ekInput = "input"
    ekButton = "button"
    ekGutter = "gutter"
    ekMenu = "menu"
    ekOverlay = "overlay"

  ScopeElement* = object
    kind*: ElementKind
    id*: string
      ## The element's identity: a pane id, a row key, an overlay name
      ## (`find`, `palette`, `command-line`, `context-menu`), an input's role
      ## (`find-query`, `replace-query`, `palette-query`, `search-query`,
      ## `prompt`). Owners of
      ## pushed layers are named by it (`layer_stack`).
    paneKind*: string
      ## For an `ekPane`: its `PaneKind` name (one of `PaneKinds`).

  ScopePath* = seq[ScopeElement]
    ## Outermost first: the window, then the session tab, then the pane, …,
    ## then the focused element.

const
  PaletteQueryInput* = "palette-query"
    ## The palette's field.
  SearchQueryInput* = "search-query"
    ## Find in Files' query field: the desktop pane's own field, and on the
    ## terminal and GPUI the palette's field while it holds `:grep` — their
    ## field for the pane (Find-And-Incremental-Search.md §5.2). The context
    ## key `searchInputFocus` is true there, where the field's toggle keys
    ## (`Alt+C` / `Alt+W` / `Alt+R`) hold.

  PaneKinds* = ["editor", "calltrace", "state", "eventLog", "debugControls",
                "flow", "search", "pointList", "scratchpad", "shell",
                "fileTree", "buildOutput", "vcs", "agentActivity",
                "terminalOutput", "testResults", "constraints", "problems",
                "requests"]
    ## `headless_app/layout_model.PaneKind`'s names, in its order — the
    ## values `paneKind` holds and a `when` may compare against. Spelled
    ## here so this package stays free of the layout model's imports;
    ## `test_plat68_layers.nim` asserts the two lists equal, both
    ## directions.

  ListPaneKinds = ["calltrace", "state", "eventLog", "search", "pointList",
                    "fileTree", "buildOutput", "problems", "testResults",
                    "requests", "agentActivity", "vcs", "constraints"]
    ## The list-like panes (CUA-Keymap.md §3.6): a focused one is
    ## `listFocus` and takes the shared `list` table.

  TreePaneKinds = ["state", "fileTree"]
    ## The tree panes: `treeFocus`, so `Left` / `Right` collapse and expand.

  GlobalTable* = "global"
  EditorTable* = "editor"
  ListTable* = "list"
  InputTable* = "input"
  PaneTablePrefix* = "pane:"
    ## A pane kind's own table: `pane:state` holds the variables pane's
    ## `x` / `m`.

const
  ScopeKindAttribute* = "data-scope-kind"
  ScopeIdAttribute* = "data-scope-id"
    ## What every element of a front-end's focus tree that is a scope carries
    ## — its `ElementKind` and identity (§5.2) — so each front-end's producer
    ## reads the scope path off its OWN focus chain: the terminal's
    ## `isonim-tui` nodes, GPUI's elements and the desktop's DOM.

func element*(kind: ElementKind; id: string; paneKind = ""): ScopeElement =
  ScopeElement(kind: kind, id: id, paneKind: paneKind)

func pane*(paneKind: string; id = ""): ScopeElement =
  ScopeElement(kind: ekPane, id: (if id.len > 0: id else: paneKind),
               paneKind: paneKind)

func elementOfAttributes*(kindText, id: string): ScopeElement =
  ## The scope element a focus-chain node's two attributes name; a pane's
  ## identity is its pane kind.
  var kind = ekWindow
  for k in ElementKind:
    if $k == kindText: kind = k
  if kind == ekPane: pane(id) else: element(kind, id)

func isListPane*(paneKind: string): bool = paneKind in ListPaneKinds
func isTreePane*(paneKind: string): bool = paneKind in TreePaneKinds

func focused*(path: ScopePath): ScopeElement =
  ## The innermost element; a window element for an empty path.
  if path.len == 0: ScopeElement(kind: ekWindow, id: "window")
  else: path[^1]

func innermostPane*(path: ScopePath): int =
  ## Index of the innermost pane element, or -1.
  for i in countdown(path.len - 1, 0):
    if path[i].kind == ekPane: return i
  -1

func contains*(path: ScopePath; id: string): bool =
  for e in path:
    if e.id == id: return true
  false

func tablesOf*(e: ScopeElement): seq[string] =
  ## The binding tables an element contributes, innermost meaning first.
  ## A pane contributes its own table and, when it is a list, the shared
  ## list table; an overlay contributes nothing by itself — its rows arrive
  ## as the pushed layer the operation that opened it pushed
  ## (`layer_stack`).
  case e.kind
  of ekWindow: @[GlobalTable]
  of ekEditor: @[EditorTable]
  of ekInput: @[InputTable]
  of ekPane:
    if isListPane(e.paneKind): @[PaneTablePrefix & e.paneKind, ListTable]
    else: @[PaneTablePrefix & e.paneKind]
  of ekTab, ekRow, ekButton, ekGutter, ekMenu, ekOverlay: @[]

func `$`*(e: ScopeElement): string =
  if e.kind == ekPane: "pane:" & e.paneKind
  else: $e.kind & ":" & e.id

func `$`*(path: ScopePath): string =
  var parts: seq[string] = @[]
  for e in path: parts.add $e
  parts.join(" / ")
