## headless_app/file_tree_menu.nim — the Files pane's right-click menu (K19)
## for the native front-ends, read off the shared Files model.
##
## codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu":
## a row of the tree opens Create, Rename, Delete and Edit, always all four
## and in that order, each disabled with its reason where it cannot act. The
## desktop's view hands `FilesystemVM.fileTreeMenu`'s entries to its context
## menu; the terminal and GPUI draw a `ContextMenuModel` (`pane_clicks`). This
## module is the one conversion between the two, so the three front-ends
## show the entries, the order and the reasons one function decided.
##
## Choosing an entry re-asks the model at that moment (`runFileTreeAction`):
## a `ContextMenuModel` carries no closures (it is a value both renderers
## copy), and the row's facts may have changed while the menu was open.

import codetracer_embed
import ./pane_clicks

export pane_clicks

func fileTreeActionOf*(action: ContextAction):
    tuple[ok: bool, action: FileTreeAction] =
  ## The Files model's entry a menu action names; `ok` false for any other
  ## action.
  case action
  of caFileCreate: (true, ftaCreate)
  of caFileRename: (true, ftaRename)
  of caFileDelete: (true, ftaDelete)
  of caFileEdit: (true, ftaEdit)
  else: (false, ftaCreate)

proc fileTreeContextMenuOf*(vm: FilesystemVM; path: string): ContextMenuModel =
  ## A right-click on the row at `path` (`""`: the synthetic "source
  ## folders" row): the model's menu for it, kept as the model's last one
  ## (`FilesystemVM.openFileTreeMenu`), as a native menu.
  var decided: seq[tuple[label: string; enabled: bool; reason: string]] = @[]
  if not vm.isNil:
    for e in vm.openFileTreeMenu(path):
      decided.add (e.label, not e.disabled, e.disabledReason)
  fileTreeNodeContextMenu(path, decided)

proc runFileTreeAction*(vm: FilesystemVM; path: string;
                        action: ContextAction): string =
  ## Choose `action` on the row at `path`, as the model decides it NOW.
  ## Answers `""` when the entry ran, else its reason (the entry is
  ## disabled, or `action` is not a Files entry).
  let (isFiles, wanted) = fileTreeActionOf(action)
  if vm.isNil or not isFiles:
    return "not a Files menu entry"
  for e in vm.fileTreeMenu(path):
    if e.action == wanted:
      if e.disabled or e.run.isNil:
        return e.disabledReason
      e.run()
      return ""
  "not a Files menu entry"

proc fileTreeEntryReason*(vm: FilesystemVM; path: string;
                          action: ContextAction): string =
  ## Why the entry `action` cannot act on the row at `path` now, or `""`
  ## when it can — for a front-end that carries an entry out itself (Edit:
  ## opening a file is the front-end's editor, not the model's hook).
  let (isFiles, wanted) = fileTreeActionOf(action)
  if vm.isNil or not isFiles:
    return "not a Files menu entry"
  for e in vm.fileTreeMenu(path):
    if e.action == wanted:
      return (if e.disabled: e.disabledReason else: "")
  "not a Files menu entry"
