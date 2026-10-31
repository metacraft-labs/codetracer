## ui/desktop_edit_toolbar.nim — the Electron desktop's edit-mode topbar.
##
## `debug_toolbar.setEditModeToolbar` is how a platform hands the topbar the
## edit-mode model, and until this module only the web studio called it
## (`web_noir_build.installEditModeToolbar`). So on the desktop
## `DebugControlsVM.editToolbar` stayed `none`, `topbarSurface` fell back to
## the debugger controls, and Edit mode kept all thirteen stepping buttons
## (#812; `Edit-Mode-Toolbar.md` §7.3 / EMT-A1).
##
## What a model needs only a platform knows, and this is the desktop's answer
## to each of the three:
##
## * the PROFILE — `ctPlatform().profile`, the Electron instantiation's;
## * the REGISTRY — none: the desktop runs native programs, so there is no
##   wasm module to resolve a command to;
## * the LISTING — the workspace tree the Files pane renders
##   (`data.services.editor.filesystem`), as paths relative to the folder it
##   was loaded from, which is the form `projectKinds` ranks by depth.
##
## BUILD GOES TO THE DESKTOP'S BUILD RUNNER. The desktop profile can run
## arbitrary programs, so the model enables the project's command (`nargo
## compile`, …), and the main process now runs builds
## (`index/build_runner`, Build-Output-Pane.md §4.2): a press saves every
## modified editor first (EMT-D17) and runs the button's command line in the
## project folder, its output in the BUILD panel.
##
## RUN IS STILL REFUSED, by name (EMT-D30): Run records the program and opens
## the recording (§9.3), and the runner only runs a command — a Run that built
## and recorded nothing would be a button that does less than it says.
##
## Desktop-only: the web studio composes its own model in `web_noir_build`.
## `ui_js` imports this module only on the
## Electron arm.

import ui_imports
from ../platform_host import ctPlatform
import ../viewmodel/viewmodels/edit_mode_toolbar
import ../viewmodel/platform/wasm_registry
from debug_toolbar import setEditModeToolbar
from ./build import startDesktopBuild


const DesktopRunRefusal* =
  "Running from the toolbar (record, then debug) is not available in the " &
  "desktop app yet; Build runs the project's build command."
  ## Why the desktop's Run is off. Never empty (EMT-A28): it is the button's
  ## tooltip, and a disabled button that cannot say why is a defect.

proc originalPath(node: CodetracerFile): cstring =
  ## The node's `original.path`, or nil when it has none.
  ##
  ## Read through `jsffi` rather than as `node.original.path` because the
  ## tree arrives over IPC as plain JSON, not as Nim objects: the index's
  ## `Loading...` stub is built with no `original`, so its path is a
  ## JavaScript `null` (and an absent field is `undefined`), and `$` on it
  ## throws — out of `onNoTrace`, before the editor opens.
  let original = node.toJs["original"]
  if original.isNull or original.isUndefined:
    return nil
  let path = original["path"]
  if path.isNull or path.isUndefined:
    return nil
  path.to(cstring)

proc normalizedPath(path: cstring): string =
  ## `/`-separated with no trailing separator — the listing contract
  ## `projectKinds` reads (§4.2), whatever separator the host used. A nil
  ## path is the empty string.
  if path.isNil:
    return ""
  result = ($path).replace('\\', '/')
  while result.len > 1 and result[^1] == '/':
    result.setLen(result.len - 1)

proc addLeaves(node: CodetracerFile; root: string; acc: var seq[string]) =
  ## Every leaf under `node`, relative to `root` when it lies inside it.
  ##
  ## A leaf with no path is skipped: it is the `Loading...` stub the index
  ## puts below a folder at its depth limit, or an empty group root, and
  ## neither names a file.
  if node.isNil:
    return
  if node.children.len == 0:
    let path = normalizedPath(originalPath(node))
    if path.len == 0:
      return
    if root.len > 0 and path.startsWith(root & "/"):
      acc.add path[root.len + 1 .. ^1]
    else:
      acc.add path
  else:
    for child in node.children:
      addLeaves(child, root, acc)

proc workspaceListing(tree: CodetracerFile): seq[string] =
  ## The listing `projectKinds` reads, from the tree the Files pane renders.
  ##
  ## The index roots that tree in a synthetic group with no path ("source
  ## folders") whose children are the folders it loaded, so each folder is its
  ## own root: a marker at the top of a loaded folder is at depth 0, as it is
  ## for the developer looking at it.
  if tree.isNil:
    return
  let own = normalizedPath(originalPath(tree))
  if own.len > 0:
    addLeaves(tree, own, result)
  else:
    for folder in tree.children:
      if not folder.isNil:
        addLeaves(folder, normalizedPath(originalPath(folder)), result)

var shownToolbar: EditToolbarModel
  ## The model the bar was last drawn from: a press runs ITS command line.

proc desktopEditToolbarInvoke(id: string) =
  ## The buttons' action: Build (`build-image`) saves every modified editor
  ## (EMT-D17) and runs its command line in the project folder through the
  ## desktop's build runner. Run is refused (never reaches here); an id this
  ## host does not know is ignored, the web arm's `else: discard`.
  if id != "build-image":
    return
  let button = shownToolbar.build
  if not button.enabled or button.commandLine.len == 0:
    return
  data.saveFiles()
  let folder = if data.startOptions.folder.isNil: ""
               else: $data.startOptions.folder
  let why = startDesktopBuild(button.commandLine, folder, "", "")
  if why.len > 0:
    cwarn "toolbar: " & why

proc installDesktopEditModeToolbar*() =
  ## Compose the edit-mode topbar from what this session is NOW — its mode
  ## and its workspace listing — and hand it to the topbar.
  ##
  ## Re-run on every event that can change an input rather than patched: a
  ## mode switch, an edit session starting, the filesystem tree arriving, a
  ## save (`Mode-Transitions.md` §3.1, "re-derived from the mode, never
  ## patched"). `ui_js` reaches it through `refreshEditToolbarHook`, the one
  ## hook both platforms install their composer into.
  if data.isNil or data.ui.isNil:
    return
  let listing =
    if data.services.editor.isNil: newSeq[string]()
    else: workspaceListing(data.services.editor.filesystem)
  let model = editModeToolbar(
    ctPlatform().profile,
    ToolbarMode(data.ui.mode.ord),
    listing = listing,
    wasm = WasmRegistry()).refuseCommands(DesktopRunRefusal,
                                          refused = {tbaRun})
  shownToolbar = model
  setEditModeToolbar(model, desktopEditToolbarInvoke)
