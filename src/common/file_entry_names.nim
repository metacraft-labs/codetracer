## file_entry_names.nim — the rule for the name of a new or renamed file-tree
## entry, shared by the Files pane and the index process.
##
## The Files pane's context menu (codetracer-pm
## `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu", "Create and
## Rename") refuses a name "when it is empty, is `.` or `..`, contains `/` or
## `\`, or names an entry that already exists in the folder". The first three
## are properties of the name alone, and both ends check them:
##
## - the pane (`viewmodels/filesystem_vm.commitNameEdit`), so a refused name
##   keeps its field open and shows the reason before anything is sent;
## - the index process (`index/file_tree_operations`), which acts on the disk
##   and so cannot trust what a renderer — or a `ct host` client — sends it.
##
## One predicate, called by both, so the two checks cannot drift apart. The
## fourth condition, "already exists", is not here: each end answers it from
## what it can see (the pane from the tree, the index process from the disk at
## the moment it acts).
##
## Pure string code with no platform imports: it is compiled for the native
## ViewModel tests, the renderer and the Electron main process alike.

proc fileEntryNameRefusal*(name: string): string =
  ## Why `name` cannot name a file-tree entry, or `""` when it can.
  ##
  ## `/` and `\` are both refused on every platform: `\` is a separator on
  ## Windows, and a name that is legal on one host but splits into a path on
  ## another would make the tree disagree with the disk depending on where it
  ## was created. A NUL byte is refused too: no filesystem accepts it, and
  ## node's `fs` throws on it with a message about the argument rather than
  ## the name.
  if name.len == 0:
    return "A name is required"
  if name == "." or name == "..":
    return "\"" & name & "\" is not a name an entry can have"
  for c in name:
    if c == '/' or c == '\\':
      return "A name cannot contain / or \\"
    if c == '\0':
      return "A name cannot contain a NUL character"
  ""

const NoTrashReason* = "This host has no trash"
  ## Why Delete is unavailable where the index process cannot move a path to
  ## the trash (the spec's wording). The pane shows it as the disabled Delete
  ## entry's reason; the index process answers a delete with it on such a
  ## host, so a client that sends one anyway is refused in the same words and
  ## nothing is ever deleted permanently.

proc alreadyExistsRefusal*(name: string): string =
  ## The refusal for a name that is already taken in the folder. One wording
  ## for the pane's check and the index process's, which a user can meet in
  ## either order (the index process refuses a name that appeared after the
  ## field opened).
  "\"" & name & "\" already exists in this folder"
