## context_menu_item.nim — one entry of a context menu.
##
## Its own module so a view can build a menu without importing `types.nim`,
## the desktop renderer's type universe (the VS Code webview bundle must not
## contain it: Shared-DOM-Front-Ends D5). `types.nim` re-exports it, so every
## existing importer is unchanged.

import kdom

type
  ContextMenuItem* = ref object
    name*: cstring
    hint*: cstring
    handler*: proc(ev: kdom.Event) {.closure.}
    disabled*: bool
      ## RESERVED FOR "APPLICABLE HERE, UNAVAILABLE NOW".
      ##
      ## An entry that has no meaning in the current mode is not disabled — it
      ## is ABSENT. A greyed-out list of ten debug operations is still a menu
      ## about debugging, and it fails the complaint that produced this field
      ## ("the right click menu content over the editor area is not context
      ## dependent") exactly as squarely as an enabled one. The rule is the
      ## toolbar's, stated once in
      ## `codetracer-specs/Planned-Features/Edit-Mode-Toolbar.md` §8: hidden
      ## when the verb does not apply, disabled when it applies and the command
      ## cannot run right now.
    disabledReason*: cstring
      ## WHY, IN WORDS, AND ON THE ROW. Not a tooltip: `.ct-menu-item--disabled`
      ## sets `pointer-events: none`, so a disabled row cannot be hovered — a
      ## reason parked in `title` would be unreachable by construction. It is
      ## rendered as the row's sublabel instead.
      ##
      ## A disabled entry with an empty reason is a defect (the toolbar's
      ## EMT-D14, asserted there and asserted here by
      ## `ci/test/editor-context-menu-modes.sh`): "an action whose absence
      ## cannot be explained is one whose absence was a guess".
