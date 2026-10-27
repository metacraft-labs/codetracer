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
      ## `prompt`, `agent-prompt`; an unstamped native field's DOM id or
      ## `text-field`, `withNativeTextField`). Owners of
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
  AgentPromptInput* = "agent-prompt"
    ## The Agent Activity pane's prompt (`isonim_agent_activity_view`): a
    ## text field inside a LIST pane, so its keys are its own only because
    ## the path ends in it — `Enter` submits the prompt rather than running
    ## the list's `list.activate` (codetracer-pm issue 2026-10-21, "Pressing
    ## Enter in the Agent Activity prompt box does not submit the prompt").
  NativeTextFieldInput* = "text-field"
    ## The identity of a native text field that names no role of its own and
    ## has no DOM id (`withNativeTextField`). A role a `when` compares
    ## (`find-query`, `search-query`, …) is always stamped by its view, never
    ## inferred.

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

type
  FocusedFieldFacts* = object
    ## What a front-end's producer reads off the element that holds the
    ## focus, so `withNativeTextField` can decide — here, once, for every
    ## front-end that has native fields — whether that element accepts text.
    ## The desktop fills it from `document.activeElement`
    ## (`ui/key_router.desktopScopePath`).
    tagName*: string
      ## The element's tag, any case (`TEXTAREA`, `input`).
    inputType*: string
      ## For an `<input>`, its type: the DOM's `type` property (already
      ## lower-cased, `text` for a missing or unknown attribute) or the raw
      ## attribute (empty when absent). Ignored for other tags.
    contentEditable*: bool
      ## The DOM's `isContentEditable`: the element is editable rich text.
    id*: string
      ## The element's DOM id, or empty.
    carriesScope*: bool
      ## The element itself carries `ScopeKindAttribute`: it is already a
      ## scope element of the path, under whatever kind and id its view gave
      ## it.
    readOnly*: bool
      ## The DOM's `readOnly` of an `<input>` / `<textarea>`: it holds a caret
      ## but takes no text.
    disabled*: bool
      ## The DOM's `disabled`: it takes no focus or text at all.
    monacoText*: bool
      ## The focus is inside a WRITABLE Monaco instance (the editor in Edit
      ## mode, a tracepoint editor nested in the read-only editor). Monaco's
      ## input is not an element the DOM calls a field: its EditContext input
      ## (`div.native-edit-context`) carries no `contenteditable`, and its IME
      ## helper is a `readonly` textarea, so the tag, `readOnly` and
      ## `isContentEditable` all say "no text" and the instance is asked
      ## instead (https://developer.mozilla.org/en-US/docs/Web/API/EditContext_API).
    editorText*: bool
      ## The focus is the EDITOR'S OWN text area: the Monaco instance of the
      ## focus chain's editor element reports `hasTextFocus()`, which it does
      ## for its input only — not for its find widget, nor for an instance
      ## nested in it
      ## (https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.ICodeEditor.html#hasTextFocus).

const
  TextEntryInputTypes = ["", "text", "search", "email", "url", "tel",
                         "password", "number"]
    ## The `<input>` types the user types text into (HTML Living Standard,
    ## "the input element", the `type` attribute's states:
    ## https://html.spec.whatwg.org/multipage/input.html#attr-input-type).
    ## A missing type is the Text state. `number` is here because its caret
    ## keys and digits are the field's. Checkboxes, radios, buttons, ranges,
    ## colour and file pickers take no text, so their keys stay the pane's.

func isNativeTextField*(f: FocusedFieldFacts): bool =
  ## Whether the focused element accepts text the way §4.2's
  ## `textInputFocus` means it ("the focused element accepts text: a
  ## writable editor, a prompt, a find field, the palette"): a `<textarea>`,
  ## a text-entry `<input>`, contenteditable content, or a writable Monaco
  ## instance's input. A read-only or disabled field takes none.
  if f.monacoText: return true
  if f.readOnly or f.disabled: return false
  if f.contentEditable: return true
  case f.tagName.toLowerAscii
  of "textarea": true
  of "input": f.inputType.toLowerAscii in TextEntryInputTypes
  else: false

func withNativeTextField*(chain: ScopePath; f: FocusedFieldFacts): ScopePath =
  ## **A FOCUSED NATIVE TEXT FIELD IS THE PATH'S INPUT ELEMENT.** `chain` is
  ## the path read off the scope attributes of the focused element and its
  ## ancestors (§6.2); `f` describes the focused element itself. When that
  ## element is a text field no view named, an `ekInput` element is appended
  ## for it, identified by its DOM id (`NativeTextFieldInput` without one).
  ##
  ## Without this a field with no scope attribute was its pane: inside a
  ## list pane the focus was `listFocus`, so `Enter` was `list.activate`,
  ## the arrows moved the list, and in Debug mode the letters stepped — and
  ## the desktop ran those and stopped the key, so the field never saw it.
  ## Every field would have to be stamped by its view to type at all; this
  ## makes the safe answer the default, and a view stamps a field only to
  ## give it a ROLE a binding's `when` reads (`SearchQueryInput`,
  ## `AgentPromptInput`).
  ##
  ## Left exactly as `chain` says:
  ##   * an element that carries its own scope attribute — it is already on
  ##     the path, under the kind and id its view chose;
  ##   * the EDITOR'S OWN text area (`editorText`, with the chain ending at
  ##     the editor element) — Monaco's input, whose keys the editor's path
  ##     and tables decide (§5.3). Every other field inside the editor
  ##     element is a field like any other and gains its input element
  ##     under the editor: Monaco's find widget and a tracepoint editor keep
  ##     `editorFocus` (the editor's `Ctrl+Enter`, `F9`), not the read-only
  ##     editor's letters and `Enter`. Treating them as the editor made a
  ##     letter typed into the find widget run CUA's read-only-editor key
  ##     (`f`, `debugger.step-out`, which also took the focus away), and
  ##     `Enter` there open a tracepoint editor instead of finding the next
  ##     match (codetracer-pm issue 2026-10-21, "Pressing Enter in the
  ##     desktop Call Trace search box sends no search");
  ##   * a chain that already ends in an input element (a stamped wrapper
  ##     around the field), so the input is never doubled.
  result = chain
  if f.carriesScope or not isNativeTextField(f):
    return
  if f.editorText and chain.len > 0 and chain[^1].kind == ekEditor:
    return
  if chain.len > 0 and chain[^1].kind == ekInput:
    return
  result.add ScopeElement(kind: ekInput,
                          id: (if f.id.len > 0: f.id
                               else: NativeTextFieldInput))

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
