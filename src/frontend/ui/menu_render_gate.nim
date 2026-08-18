## ui/menu_render_gate.nim
##
## Pure decision logic for "does the global menu shell actually need to be
## rebuilt?" — extracted out of `ui/menu.nim` so it can be exercised headlessly
## on both the native and the JS backend.
##
## Why this exists (issue #555, "Redraw issue on new file open")
## --------------------------------------------------------------
## Every `data.redraw()` in the renderer funnels through
## `renderer.sharedDirectRedraw` (installed in `ui/layout.nim`) into
## `ui/menu.nim`'s `requestMenuRender`.  That proc used to rebuild the whole
## caption chrome unconditionally via
## `viewmodel/views/isonim_menu_shell_view.renderMenuShellInto`, which starts
## with `clearChildren(container)` and then re-creates the entire subtree.
##
## The `#isonim-debug-controls` host is emitted *by that same shell view*
## (`isonim_menu_shell_view.nim`, the `tdiv(id = "isonim-debug-controls")`
## node) — it is not a static element in `index.html`, contrary to what the
## older comments in `ui/debug.nim` claimed.  So every menu rebuild destroyed
## the mounted IsoNim debug toolbar and `ui/debug.nim`'s
## `requestDebugControlsRender` had to mount a fresh one.
##
## A single trace open issues dozens of `data.redraw()` calls (IPC responses,
## layout events, session-tab refreshes), so the toolbar was torn down and
## rebuilt dozens of times before the user touched anything.  That is exactly
## the "buttons blink on and off rapidly" the reporter recorded.
##
## The gate makes the rebuild conditional on the shell's *rendered content*
## having actually changed, comparing a canonical signature of the
## `MenuShellModel`.  Model identity is useless for this: `data.webTechMenu`
## builds a brand-new `MenuNode` tree on every call, so two structurally
## identical menus are never the same objects.
##
## This module is deliberately free of any DOM / `js`-backend dependency: the
## caller passes in whether the previously rendered host is still on screen,
## and the gate answers with a pure boolean.

from ../viewmodel/views/isonim_menu_shell_view import
  MenuNodeRecord, MenuNodeRecordKind, MenuNestedRecord, MenuSearchResultRecord,
  MenuShellModel

type
  MenuRenderGate* = object
    ## Remembers the signature of the last menu shell that was actually
    ## committed to the DOM.  One instance per menu host.
    lastSignature: string
    hasRendered: bool

# ---------------------------------------------------------------------------
# Signature construction
# ---------------------------------------------------------------------------
#
# The signature has to be *injective* over everything the shell view reads,
# otherwise the gate would suppress a render that the user needed.  Every
# variable-length field is therefore length-prefixed rather than delimiter
# separated: a menu entry legitimately called "3:File" cannot then collide
# with a different pair of fields.

proc putField(dest: var string; value: string) =
  dest.add $value.len
  dest.add ':'
  dest.add value

proc putField(dest: var string; value: int) =
  dest.add $value
  dest.add ';'

proc putField(dest: var string; value: bool) =
  dest.add(if value: '1' else: '0')

proc putNode(dest: var string; node: MenuNodeRecord) =
  ## Serialize one menu record and, recursively, its submenu children.
  if node.isNil:
    dest.add "~;"
    return
  dest.putField ord(node.kind)
  dest.putField node.name
  dest.putField node.shortcut
  dest.putField node.enabled
  dest.putField node.iconClass
  dest.putField node.nameClass
  dest.putField node.nodeClass
  dest.putField node.nameWidth
  dest.putField node.beforeNextSubGroup
  dest.putField node.path.len
  for index in node.path:
    dest.putField index
  dest.putField node.children.len
  for child in node.children:
    dest.putNode child

proc menuRenderSignature*(model: MenuShellModel; extra: string = ""): string =
  ## Canonical, order-sensitive serialization of everything
  ## `renderMenuShell` reads out of `model`.
  ##
  ## `extra` carries caller state that influences the committed DOM but does
  ## not live on the model — `ui/menu.nim` passes the keyboard-navigation flag,
  ## because that decides whether the navigation element is refocused after a
  ## render.
  result = newStringOfCap(1024)
  result.putField model.showNavigation
  result.putField model.active
  result.putField model.searchQuery
  result.putField model.showWindowMenu
  result.putField model.maximized

  result.putField model.rootNodes.len
  for node in model.rootNodes:
    result.putNode node

  result.putField model.searchResults.len
  for entry in model.searchResults:
    result.putField entry.label
    result.putField entry.shortcut
    result.putField entry.iconClass
    result.putField entry.active

  result.putField model.nestedMenus.len
  for nested in model.nestedMenus:
    result.putField nested.id
    result.putField nested.className
    result.putField nested.style
    result.putField nested.nodes.len
    for node in nested.nodes:
      result.putNode node

  result.putField extra

# ---------------------------------------------------------------------------
# The gate itself
# ---------------------------------------------------------------------------

proc shouldRender*(gate: MenuRenderGate; signature: string;
                   hostIntact: bool): bool =
  ## `true` when the menu shell must be rebuilt in the DOM.
  ##
  ## `hostIntact` must report whether the DOM this gate last produced is still
  ## present.  It is not an optimisation but a correctness requirement: other
  ## code (session switching, the welcome screen, a failed render) can empty
  ## the `#menu` host behind our back, and a cache that trusted only the
  ## signature would then leave the caption bar permanently blank.
  if not gate.hasRendered:
    return true
  if not hostIntact:
    return true
  signature != gate.lastSignature

proc noteRendered*(gate: var MenuRenderGate; signature: string) =
  ## Record that `signature` is what is now committed to the DOM.
  gate.lastSignature = signature
  gate.hasRendered = true

proc invalidate*(gate: var MenuRenderGate) =
  ## Force the next `shouldRender` to answer `true`.  Used when the host
  ## element is known to have been replaced by something outside our control.
  gate.hasRendered = false
  gate.lastSignature = ""

proc shouldRemountDebugControls*(mounted: bool; hostHasChildren: bool): bool =
  ## The repair decision in `ui/debug.nim`'s `requestDebugControlsRender`.
  ##
  ## The toolbar has to be re-mounted whenever we have never mounted it, or
  ## whenever the `#isonim-debug-controls` host that survives in the DOM is
  ## empty — which is what a full menu-shell rebuild leaves behind, since the
  ## host node itself is re-created by the shell view.
  ##
  ## Kept here, next to the gate that decides whether such a rebuild happens at
  ## all, because the two are one story: while the gate suppresses the rebuild
  ## the host keeps its children and this predicate answers `false`.
  not (mounted and hostHasChildren)
