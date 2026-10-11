## context_keys.nim — the closed catalogue of CONTEXT KEYS a binding's `when`
## may read, and the one function that computes the editor's.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §4.2's table as data — every key's
## name and its closed value set — and `editorContextKeys`, the slice of
## `contextKeysOf(session, scopePath)` the editor scope needs.
##
## Refuses to own: the `when` grammar (`when_expr.nim`), and the scope path —
## PLAT-68 Phase B derives `paneKind`, `listFocus` and the overlay keys from a
## front-end's scope path; until then a key with no source here holds its
## domain's first value (`false` for a bool), which is what it means in the
## editor scope (no list has focus, no overlay is open).
##
## ## ONE FUNCTION, CALLED BY EVERY FRONT-END
##
## §4.2: *"Every key whose source is a ViewModel or the scope path is computed
## by one shared function … a front-end supplies only `frontEnd`, `platform`
## and `keyProtocol`."* A front-end that computed `editorHasSelection` itself
## would be a second spelling of one predicate (Verification-Harness-Traps
## §30a). The terminal and GPUI both reach this through
## `editing_core.editScopeOf`.

import ../editor/editor_state
import ../editor/selection
import ../editor/transaction
import ../viewmodels/product_mode

import ../../../common/key_names

export key_names.KeyProtocol

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

const
  BoolDomain = @["false", "true"]
  PaneKindDomain = @["none", "editor", "callTrace", "eventLog", "variables",
                     "points", "problems", "search", "fileTree", "terminal",
                     "buildOutput", "visualReplay", "shell", "other"]
    ## The pane kinds a `when` may name. `none` is the editor-scope value
    ## until PLAT-68 Phase B gives the scope path its pane.

func domainOf*(k: ContextKey): seq[string] =
  ## The CLOSED value set of a key, first member being the value a key with
  ## no source in this scope holds. Every `when` comparison is checked
  ## against it at load, and `when_expr.canBothHold` enumerates it.
  case k
  of ckProductMode: @["debug", "edit"]
  of ckPaneKind: PaneKindDomain
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

func b(v: bool): string = (if v: "true" else: "false")

func editingModeName(m: EditingMode): string = $m

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

func editorContextKeys*(st: EditorState; product: ProductMode;
                        frontEnd: FrontEndKind; platform: PlatformKind;
                        keyProtocol: KeyProtocol): ContextKeys =
  ## **THE CONTEXT OF A FOCUSED EDITOR**, from the editor's state and the
  ## three keys a front-end supplies. Every key the editor scope reads is
  ## computed here and nowhere else.
  result = defaultContextKeys()
  var hasSel = false
  var multiLine = false
  for r in st.selection:
    if not r.isEmpty:
      hasSel = true
      if isMultiLineRange(st.doc, r): multiLine = true
  result.values[ckProductMode] = (if product == pmEdit: "edit" else: "debug")
  result.values[ckPaneKind] = "editor"
  result.values[ckElementKind] = "editor"
  result.values[ckEditorFocus] = "true"
  result.values[ckEditorTextFocus] = "true"
  result.values[ckEditorReadOnly] = b(isReadOnly(st))
  result.values[ckTextInputFocus] = b(not isReadOnly(st))
  result.values[ckEditorHasSelection] = b(hasSel)
  result.values[ckEditorHasMultipleSelections] = b(st.selection.rangeCount > 1)
  result.values[ckEditorHasMultiLineSelection] = b(multiLine)
  result.values[ckEditorMode] = editingModeName(st.mode)
  result.values[ckChordPending] = b(st.pending.chords.len > 0)
  result.values[ckFrontEnd] = $frontEnd
  result.values[ckPlatform] = $platform
  result.values[ckKeyProtocol] = $keyProtocol

func hostPlatform*(): PlatformKind =
  ## The platform this binary was built for — what a native front-end
  ## supplies as `platform`.
  when defined(windows): pkWindows
  elif defined(macosx): pkMac
  else: pkLinux

func editorContextKeys*(st: EditorState; product: ProductMode;
                        delivery: KeyDelivery): ContextKeys =
  editorContextKeys(st, product, delivery.frontEnd, delivery.platform,
                    delivery.keyProtocol)
