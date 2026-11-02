## context_keys.nim — the closed catalogue of CONTEXT KEYS a binding's `when`
## may read, and THE ONE FUNCTION that computes them: `contextKeysOf`.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §4.2's table as data — every key's
## name and its closed value set — the facts a session hands that function
## (`SessionFacts`, `EditorFacts`), and `contextKeysOf(facts, scopePath,
## delivery)` itself.
##
## Refuses to own: the `when` grammar (`when_expr.nim`), how a front-end
## finds its scope path (`scope_path.nim`, §6.2), and what an operation does.
##
## ## ONE FUNCTION, CALLED BY EVERY FRONT-END
##
## §4.2: *"Every key whose source is a ViewModel or the scope path is computed
## by one shared function … a front-end supplies only `frontEnd`, `platform`
## and `keyProtocol`."* A front-end that computed `editorReadOnly` or
## `editorHasSelection` itself would be a second spelling of one predicate
## (Verification-Harness-Traps §30a), and DIFF-13 would compare two opinions
## rather than one rule. So the facts a front-end hands in are the ViewModels'
## own answers — `editorFactsOf(EditorState)` for a document,
## `sourceViewFacts()` for the Debug-mode source view — and every key is
## derived here.

import ../editor/editor_state
import ../editor/selection
import ../editor/transaction
import ../viewmodels/product_mode
import ./scope_path

import ../../../common/key_names

export key_names.KeyProtocol
export scope_path

type
  ContextKey* = enum
    ## §4.2, in its row order. Closed: an unknown key in a `when` is a load
    ## error (`when_expr.parseWhen`), never `false`.
    ckProductMode = "productMode"
    ckReplayLoaded = "replayLoaded"
    ckPaneKind = "paneKind"
    ckElementKind = "elementKind"
    ckEditorFocus = "editorFocus"
    ckEditorTextFocus = "editorTextFocus"
    ckTextInputFocus = "textInputFocus"
    ckEditorReadOnly = "editorReadOnly"
    ckEditorHasSelection = "editorHasSelection"
    ckEditorHasMultipleSelections = "editorHasMultipleSelections"
    ckEditorHasMultiLineSelection = "editorHasMultiLineSelection"
    ckEditorMode = "editorMode"
    ckListFocus = "listFocus"
    ckTreeFocus = "treeFocus"
    ckFindWidgetVisible = "findWidgetVisible"
    ckFindInputFocus = "findInputFocus"
    ckReplaceInputFocus = "replaceInputFocus"
    ckSearchInputFocus = "searchInputFocus"
    ckSnippetMode = "snippetMode"
    ckRenameInputVisible = "renameInputVisible"
    ckPaletteVisible = "paletteVisible"
    ckContextMenuVisible = "contextMenuVisible"
    ckChordPending = "chordPending"
    ckLayoutMoveMode = "layoutMoveMode"
    ckDragActive = "dragActive"
    ckTabMovesFocus = "tabMovesFocus"
    ckFrontEnd = "frontEnd"
    ckPlatform = "platform"
    ckKeyProtocol = "keyProtocol"

  FrontEndKind* = enum
    feTerminal = "terminal"
    feGpui = "gpui"
    feDesktop = "desktop"
    feWeb = "web"

  PlatformKind* = enum
    pkLinux = "linux"
    pkWindows = "windows"
    pkMac = "mac"

  KeyDelivery* = object
    ## The three context keys a FRONT-END supplies (§4.2); everything else is
    ## computed from the ViewModels by the shared function.
    frontEnd*: FrontEndKind
    platform*: PlatformKind
    keyProtocol*: KeyProtocol

  ContextKeys* = object
    ## One value per key, spelled as a `when` compares it (`"true"`,
    ## `"edit"`). A value object, so two scopes compare with `==`.
    values*: array[ContextKey, string]

  EditorFacts* = object
    ## What the editor ViewModel says about the editor element — its own
    ## answers, built by `editorFactsOf` / `sourceViewFacts`, never by a
    ## front-end field by field.
    readOnly*: bool
    hasSelection*: bool
    multipleSelections*: bool
    multiLineSelection*: bool
    mode*: EditingMode
    tabMovesFocus*: bool

  SessionFacts* = object
    ## The ViewModel facts §4.2's keys are computed from, as one value: the
    ## session (product mode, a replay), the editor element, the overlays
    ## that are open, the layout gesture machine, and whether the router
    ## holds a pending prefix.
    product*: ProductMode
    replayLoaded*: bool
    editor*: EditorFacts
    findWidgetVisible*: bool
    paletteVisible*: bool
    contextMenuVisible*: bool
    renameInputVisible*: bool
    snippetMode*: bool
    layoutMoveMode*: bool
    dragActive*: bool
    chordPending*: bool
      ## Filled in by the router, which owns the pending prefix.
    modalBase*: bool
      ## Filled in by the router: the active base is Vim or Kakoune, so a
      ## writable editor accepts text only in insert mode.

const
  BoolDomain = @["false", "true"]

func domainOf*(k: ContextKey): seq[string] =
  ## The CLOSED value set of a key, first member being the value a key with
  ## no source in this scope holds. Every `when` comparison is checked
  ## against it at load, and `when_expr.canBothHold` enumerates it.
  case k
  of ckProductMode: @["debug", "edit"]
  of ckPaneKind: @["none"] & @PaneKinds
  of ckElementKind: @["none", "editor", "row", "tab", "input", "button",
                      "gutter", "menu", "overlay"]
  of ckEditorMode: @["normal", "insert", "visual", "visual-line",
                     "visual-block", "operator-pending", "replace"]
  of ckFrontEnd: @["terminal", "gpui", "desktop", "web"]
  of ckPlatform: @["linux", "windows", "mac"]
  of ckKeyProtocol: @["legacy", "kitty", "modify-other-keys", "native"]
  else: BoolDomain

func isBoolKey*(k: ContextKey): bool = domainOf(k) == BoolDomain

func parseContextKey*(name: string; key: var ContextKey): bool =
  for k in ContextKey:
    if $k == name:
      key = k
      return true
  false

func defaultContextKeys*(): ContextKeys =
  for k in ContextKey:
    result.values[k] = domainOf(k)[0]

func isMultiLineRange(doc: string; r: SelectionRange): bool =
  for i in r.rangeFrom ..< min(r.rangeTo, doc.len):
    if doc[i] == '\n': return true
  false

func isReadOnly*(st: EditorState): bool =
  ## A buffer is read-only when it carries the read-only transaction filter
  ## (PLAT-33) — the editor ViewModel's own answer, not a front-end's.
  for f in st.filters:
    if f.kind == tfReadOnly: return true
  false

func editorFactsOf*(st: EditorState; tabMovesFocus = false): EditorFacts =
  ## The editor element's facts, from its document.
  result = EditorFacts(readOnly: isReadOnly(st), mode: st.mode,
                       tabMovesFocus: tabMovesFocus)
  for r in st.selection:
    if not r.isEmpty:
      result.hasSelection = true
      if isMultiLineRange(st.doc, r): result.multiLineSelection = true
  result.multipleSelections = st.selection.rangeCount > 1

func sourceViewFacts*(): EditorFacts =
  ## The Debug-mode source view with no document open over it: read-only,
  ## nothing selected. What the editor element is until `Ctrl+E`
  ## (`editor.toggle-read-only`) opens the file for writing.
  EditorFacts(readOnly: true, mode: emNormal)

func b(v: bool): string = (if v: "true" else: "false")

func contextKeysOf*(facts: SessionFacts; path: ScopePath;
                    delivery: KeyDelivery): ContextKeys =
  ## **EVERY CONTEXT KEY, FOR ONE SCOPE PATH** (§4.2). The front-end hands
  ## in its path, the ViewModels' facts and the three keys it owns
  ## (`delivery`); nothing else decides a key.
  result = defaultContextKeys()
  let f = path.focused
  let paneAt = path.innermostPane
  let paneKind = if paneAt >= 0: path[paneAt].paneKind else: ""
  var onEditor = false
  for e in path:
    if e.kind == ekEditor: onEditor = true
  let editorText = f.kind == ekEditor
  let inputFocus = f.kind == ekInput
  # A list or tree has the focus when its pane does, or one of its rows —
  # not an input inside it (a filter field is text).
  let listish = paneAt >= 0 and isListPane(paneKind) and
                f.kind in {ekPane, ekRow}
  result.values[ckProductMode] = (if facts.product == pmEdit: "edit"
                                  else: "debug")
  result.values[ckReplayLoaded] = b(facts.replayLoaded)
  if paneKind.len > 0: result.values[ckPaneKind] = paneKind
  if f.kind in {ekEditor, ekRow, ekTab, ekInput, ekButton, ekGutter, ekMenu,
                ekOverlay}:
    result.values[ckElementKind] = $f.kind
  result.values[ckEditorFocus] = b(onEditor)
  result.values[ckEditorTextFocus] = b(editorText)
  result.values[ckTextInputFocus] =
    b(inputFocus or (editorText and not facts.editor.readOnly and
                     (not facts.modalBase or facts.editor.mode == emInsert)))
  if onEditor:
    result.values[ckEditorReadOnly] = b(facts.editor.readOnly)
    result.values[ckEditorHasSelection] = b(facts.editor.hasSelection)
    result.values[ckEditorHasMultipleSelections] =
      b(facts.editor.multipleSelections)
    result.values[ckEditorHasMultiLineSelection] =
      b(facts.editor.multiLineSelection)
    result.values[ckEditorMode] = $facts.editor.mode
    result.values[ckTabMovesFocus] = b(facts.editor.tabMovesFocus)
  result.values[ckListFocus] = b(listish)
  result.values[ckTreeFocus] = b(listish and isTreePane(paneKind))
  result.values[ckFindWidgetVisible] = b(facts.findWidgetVisible)
  result.values[ckFindInputFocus] = b(inputFocus and f.id == "find-query")
  result.values[ckReplaceInputFocus] = b(inputFocus and f.id == "replace-query")
  result.values[ckSearchInputFocus] = b(inputFocus and f.id == SearchQueryInput)
  result.values[ckSnippetMode] = b(facts.snippetMode)
  result.values[ckRenameInputVisible] = b(facts.renameInputVisible)
  result.values[ckPaletteVisible] = b(facts.paletteVisible)
  result.values[ckContextMenuVisible] = b(facts.contextMenuVisible)
  result.values[ckChordPending] = b(facts.chordPending)
  result.values[ckLayoutMoveMode] = b(facts.layoutMoveMode)
  result.values[ckDragActive] = b(facts.dragActive)
  result.values[ckFrontEnd] = $delivery.frontEnd
  result.values[ckPlatform] = $delivery.platform
  result.values[ckKeyProtocol] = $delivery.keyProtocol

const CoherentKeys* = {ckEditorFocus, ckEditorTextFocus, ckTextInputFocus,
                       ckFindInputFocus, ckReplaceInputFocus,
                       ckSearchInputFocus, ckListFocus,
                       ckTreeFocus, ckEditorReadOnly, ckElementKind}
  ## The keys `coherent` relates. `when_expr.canBothHold` enumerates all of
  ## them together whenever a condition reads one, so a relation is never
  ## judged against a key held at its default.

func coherent*(c: ContextKeys): bool =
  ## Whether `c` is an assignment `contextKeysOf` can produce, as far as the
  ## FOCUS keys go — they all derive from one focused element, so they are
  ## not independent: the find field is not the replace field, a list with
  ## the focus is not an editor, an editor's text area is on the editor.
  ## `canBothHold` skips an incoherent assignment, which is what makes
  ## `Enter: findInputFocus` and `Enter: replaceInputFocus` two rows rather
  ## than a conflict (CUA-Keymap.md §3.5). `test_plat68_layers` asserts this
  ## is SOUND — every assignment `contextKeysOf` produces is coherent.
  template on(k: ContextKey): bool = c.values[k] == "true"
  let element = c.values[ckElementKind]
  let input = element == "input"
  if on(ckEditorTextFocus) != (element == "editor"): return false
  if on(ckEditorTextFocus) and not on(ckEditorFocus): return false
  if input and not on(ckTextInputFocus): return false
  if on(ckTextInputFocus) and not input and
     not (on(ckEditorTextFocus) and not on(ckEditorReadOnly)):
    return false
  if (on(ckFindInputFocus) or on(ckReplaceInputFocus) or
      on(ckSearchInputFocus)) and not input:
    return false
  if ord(on(ckFindInputFocus)) + ord(on(ckReplaceInputFocus)) +
     ord(on(ckSearchInputFocus)) > 1:
    return false
  if on(ckListFocus) and (on(ckEditorFocus) or input or
                          element notin ["none", "row"]):
    return false
  if on(ckTreeFocus) and not on(ckListFocus): return false
  if on(ckEditorReadOnly) and not on(ckEditorFocus): return false
  true

const EditorScopePath* = @[element(ekWindow, "window"), pane("editor"),
                           element(ekEditor, "editor")]
  ## The path of a focused editor with nothing around it — what a document
  ## resolves in when a suite drives it directly (`editing_core.applyKey`).

func hostPlatform*(): PlatformKind =
  ## The platform this binary was built for — what a native front-end
  ## supplies as `platform`.
  when defined(windows): pkWindows
  elif defined(macosx): pkMac
  else: pkLinux

func editorContextKeys*(st: EditorState; product: ProductMode;
                        delivery: KeyDelivery): ContextKeys =
  ## A focused editor's keys: `contextKeysOf` over `EditorScopePath`, with
  ## the document's own facts. A pending chord is the document's
  ## (`EditorState.pending`), which is where a document driven on its own
  ## keeps it.
  contextKeysOf(SessionFacts(product: product, editor: editorFactsOf(st),
                             chordPending: st.pending.chords.len > 0),
                EditorScopePath, delivery)
