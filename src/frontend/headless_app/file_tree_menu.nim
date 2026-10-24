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

# ---------------------------------------------------------------------------
# The inline name field and Delete's question, typed into
# ---------------------------------------------------------------------------
#
# GPUI draws the model's name field in the tree, where the desktop draws its
# own (Filesystem-Pane.md § "Create and Rename"), and Delete's question under
# the entry's row (§ "In the terminal and GPUI"). While either is open the
# window's keys are the field's. This is the one reading of a key there, so
# what a key does to the field is decided beside the model, not in a window.

type
  FilesFieldStep* = enum
    ## What one key did to an open name field or Delete question.
    ffsNotOpen     ## Nothing is open: the key is not the field's.
    ffsAbsorbed    ## The field took the key and nothing else changed (a
                   ## key with no meaning there, or a character while
                   ## Delete's question is open).
    ffsTyped       ## The name being typed changed.
    ffsCommitted   ## Enter: the name was accepted and sent (a Rename to the
                   ## unchanged name closes and sends nothing), or Delete
                   ## was answered yes and sent.
    ffsRefused     ## Enter: the name was refused; the field stays open with
                   ## its reason (`nameEdit.val.error`).
    ffsCancelled   ## Escape: closed, nothing sent.

proc filesFieldOpen*(vm: FilesystemVM): bool =
  ## Whether the model has a name field or Delete's question open.
  not vm.isNil and (vm.nameEdit.val.kind != fneNone or
                    vm.pendingDelete.len > 0)

proc cancelFilesField*(vm: FilesystemVM): bool =
  ## Close an open name field or Delete question without acting — Escape,
  ## or leaving the field. False when nothing was open.
  if vm.isNil:
    return false
  if vm.pendingDelete.len > 0:
    vm.cancelDelete()
    return true
  if vm.nameEdit.val.kind != fneNone:
    vm.cancelNameEdit()
    return true
  false

proc dropLastRune(s: var string) =
  ## Remove the last UTF-8 character of `s` (a name may hold any).
  var i = s.high
  while i > 0 and (ord(s[i]) and 0xC0) == 0x80:
    dec i
  if i >= 0:
    s.setLen(i)

proc applyFilesFieldKey*(vm: FilesystemVM; key: string): FilesFieldStep =
  ## One key, in this product's canonical names (`Enter`, `Esc`,
  ## `Backspace`, `Space`, or one printable character), to the open name
  ## field or Delete question. The name typed so far is the model's
  ## `nameEditDraft`; Rename's field opens holding the current name.
  if not vm.filesFieldOpen():
    return ffsNotOpen
  if vm.pendingDelete.len > 0:
    case key
    of "Enter":
      discard vm.confirmDelete()
      return ffsCommitted
    of "Esc":
      vm.cancelDelete()
      return ffsCancelled
    else:
      return ffsAbsorbed
  case key
  of "Enter":
    # A COPY, not the draft itself: `commitNameEdit` clears the draft before
    # it sends the name, and a parameter aliasing the field would then send
    # whatever the freed buffer holds (measured: a Create of "new.py" asked
    # for "tmp/g").
    var name = vm.nameEditDraft
    if vm.commitNameEdit(name): ffsCommitted else: ffsRefused
  of "Esc":
    vm.cancelNameEdit()
    ffsCancelled
  of "Backspace":
    if vm.nameEditDraft.len == 0:
      return ffsAbsorbed
    vm.nameEditDraft.dropLastRune()
    ffsTyped
  of "Space":
    vm.nameEditDraft.add ' '
    ffsTyped
  else:
    if key.len == 1 and key[0] >= ' ' and key[0] <= '~':
      vm.nameEditDraft.add key
      ffsTyped
    else:
      ffsAbsorbed
