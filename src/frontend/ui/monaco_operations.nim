## monaco_operations.nim — PLAT-68: the editing vocabulary as Monaco performs
## it, for the desktop's router (`ui/key_router`).
##
## The router resolves a key to an OPERATION; on the desktop the editor is
## Monaco, so an editing operation runs as the Monaco command that IS it —
## VS Code's own command id (CUA's editor rows are VS Code's, so this is the
## same operation, run by the editor that ships the keymap). Monaco's own
## keybindings never answer a key the router resolved: the router's listener
## stops the event first.
##
## `HostIntents` are the file intents (Editing-Operations §5.2) the host, not
## the editor, performs.
##
## Pure, so a node suite (`src/frontend/tests/monaco_operations_test.nim`)
## holds the table to the CUA base: every editing operation CUA binds runs
## somewhere.

import std/tables

const
  HostIntents* = ["save", "save-all", "save-as"]

  # The editing vocabulary as Monaco performs it — the command each
  # operation is, VS Code's own id. CUA's editor rows ARE VS Code's, so this
  # is the same operation run by the editor that ships the keymap.
  MonacoOperations* = {
    "move-char-left": "cursorLeft", "move-char-right": "cursorRight",
    "move-line-up": "cursorUp", "move-line-down": "cursorDown",
    "move-group-left": "cursorWordLeft", "move-group-right": "cursorWordEndRight",
    "move-line-start-smart": "cursorHome", "move-line-end": "cursorEnd",
    "move-doc-start": "cursorTop", "move-doc-end": "cursorBottom",
    "move-page-up": "cursorPageUp", "move-page-down": "cursorPageDown",
    "extend-char-left": "cursorLeftSelect", "extend-char-right": "cursorRightSelect",
    "extend-line-up": "cursorUpSelect", "extend-line-down": "cursorDownSelect",
    "extend-group-left": "cursorWordLeftSelect",
    "extend-group-right": "cursorWordEndRightSelect",
    "extend-line-start-smart": "cursorHomeSelect", "extend-line-end": "cursorEndSelect",
    "extend-doc-start": "cursorTopSelect", "extend-doc-end": "cursorBottomSelect",
    "extend-page-up": "cursorPageUpSelect", "extend-page-down": "cursorPageDownSelect",
    "select-all": "editor.action.selectAll",
    "undo": "undo", "redo": "redo", "undo-selection": "cursorUndo",
    "clipboard-copy": "editor.action.clipboardCopyAction",
    "clipboard-cut": "editor.action.clipboardCutAction",
    "clipboard-paste": "editor.action.clipboardPasteAction",
    "delete-char-backward": "deleteLeft", "delete-char-forward": "deleteRight",
    "delete-group-backward": "deleteWordLeft", "delete-group-forward": "deleteWordRight",
    "delete-line": "editor.action.deleteLines",
    "copy-line-down": "editor.action.copyLinesDownAction",
    "copy-line-up": "editor.action.copyLinesUpAction",
    "swap-line-down": "editor.action.moveLinesDownAction",
    "swap-line-up": "editor.action.moveLinesUpAction",
    "indent-selection": "editor.action.indentLines",
    "dedent-selection": "editor.action.outdentLines",
    "insert-tab": "tab",
    "toggle-comment": "editor.action.commentLine",
    "line-comment": "editor.action.addCommentLine",
    "line-uncomment": "editor.action.removeCommentLine",
    "toggle-block-comment": "editor.action.blockComment",
    "open-line-below": "editor.action.insertLineAfter",
    "open-line-above": "editor.action.insertLineBefore",
    "add-cursor-above": "editor.action.insertCursorAbove",
    "add-cursor-below": "editor.action.insertCursorBelow",
    "add-cursor-at-next-match": "editor.action.addSelectionToNextFindMatch",
    "move-last-cursor-to-next-match": "editor.action.moveSelectionToNextFindMatch",
    "add-cursor-at-each-line-of-selection": "editor.action.insertCursorAtEndOfEachLineSelected",
    "select-all-matches": "editor.action.selectHighlights",
    "expand-line-selection": "expandLineSelection",
    "keep-primary-selection": "removeSecondaryCursors",
    "simplify-selection": "removeSecondaryCursors",
    "select-parent-syntax": "editor.action.smartSelect.expand",
    "select-child-syntax": "editor.action.smartSelect.shrink",
    "move-matching-bracket": "editor.action.jumpToBracket",
    "delete-trailing-whitespace": "editor.action.trimTrailingWhitespace",
    "fold": "editor.fold", "unfold": "editor.unfold",
    "toggle-fold": "editor.toggleFold",
    "fold-recursively": "editor.foldRecursively",
    "unfold-recursively": "editor.unfoldRecursively",
    "fold-all": "editor.foldAll", "unfold-all": "editor.unfoldAll",
    # Catalogued operations Monaco performs too (they keep their namespace).
    "find.open-replace": "editor.action.startFindReplaceAction",
    "find.next": "editor.action.nextMatchFindAction",
    "find.previous": "editor.action.previousMatchFindAction",
    "find.next-selection-match": "editor.action.nextSelectionMatchFindAction",
    "find.previous-selection-match":
      "editor.action.previousSelectionMatchFindAction",
    "editor.scroll-line-up": "scrollLineUp",
    "editor.scroll-line-down": "scrollLineDown",
    "editor.scroll-page-up": "scrollPageUp",
    "editor.scroll-page-down": "scrollPageDown",
  }.toTable
