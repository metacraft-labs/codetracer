import
  std / [ async, jsffi, json, strutils, strformat, sequtils, jsconsole, os ],
  electron_vars, config,
  ../[ types, lang ],
  ../lib/[ jslib, electron_lib ],
  ../../common/[ ct_logging, trace_source_paths ]

type FileFilter = ref object
  name*: cstring
  extensions*: seq[cstring]

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

let
  fileIcons = require("@exuanbo/file-icons-js")
  fsAsync = require("fs").promises

proc writeFileAsync(fs: JsObject, path: cstring, data: cstring): Future[JsObject] {.importjs: "#.writeFile(#, #)".}

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}
proc showSaveDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showSaveDialog(#,#)".}
  ## Electron's "save as" chooser, for `onSaveUntitled` (issue #735).
  ##
  ## Resolves `{canceled: bool, filePath: string}`. Bound here beside
  ## `showOpenDialog` and in the same shape, because both are host dialogs this
  ## module awaits and neither has a Nim wrapper anywhere else.
proc getClass(icons: js, name: cstring, options: js): Future[cstring] {.importjs: "#.getClass(#,#)".}

when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):
  proc pathExists*(path: cstring): Future[bool] {.async.} =
    var hasAccess: JsObject
    try:
      hasAccess = await fsPromises.access(path, fs.constants.F_OK)
    except:
      return false
    return hasAccess == jsUndefined

proc stripPathRoot(path: cstring): cstring =
  ## Strip the root/drive letter from a path for relative joining.
  ## D:\foo -> foo, /foo -> foo
  let s = $path
  if s.len >= 3 and s[1] == ':' and (s[2] == '\\' or s[2] == '/'):
    return cstring(s[3..^1])
  elif s.len > 0 and (s[0] == '/' or s[0] == '\\'):
    return cstring(s[1..^1])
  else:
    return path

proc firstPathSegment(path: string): string =
  let normalized = path.replace('\\', '/').strip(leading = true, trailing = true, chars = {'/'})
  if normalized.len == 0:
    return ""
  let slash = normalized.find('/')
  if slash < 0:
    normalized
  else:
    normalized[0 ..< slash]

proc containsPathName(paths: seq[cstring], name: cstring): bool =
  for path in paths:
    if $path == $name:
      return true
  false

proc stripLastChar(text: cstring, c: cstring): cstring =
  if cstring($(text[text.len - 1])) == c:
    return cstring(($(text)).substr(0, text.len - 2))
  else:
    return text

proc shouldSkipIndexedDirectory(path: cstring): bool =
  let name = $nodePath.basename(path)
  name in [".git", ".hg", ".svn", "node_modules", ".direnv", ".devenv",
           "result", "dist", "build", "build-debug", "src/build-debug",
           "test-results", "test-diagnostics", ".next", ".cache", "nimcache"]

const FilesystemLoadDepth = 1
  ## **How deep one load of the Files pane reads**: the node a load starts
  ## at (depth 0) is opened and its entries listed; every folder among them
  ## (depth 1) arrives collapsed, with a single "Loading..." child, and is
  ## read only when it is expanded (``load-path-content``, answered by
  ## ``onLoadPathContent``).
  ##
  ## One rule for every tree: a root load (``loadFilesystem``) and a lazy
  ## load (``loadPathContentPartially``), a trace's ``files/`` payload and
  ## the live disk.  It used to be two — no limit at all for a payload and
  ## two levels for the live disk — so the cost of opening a recording grew
  ## with the size of its folders, and a payload or an enclosing checkout
  ## large enough froze the window (codetracer-pm issue
  ## ``2026-10-21-filesystem-pane-renders-the-whole-enclosing-checkout-
  ## expanded-and-freezes-the-window.md``; ``Viewport-Driven-Loading.md``
  ## § V5).  Now a load lists one folder: one ``readdir`` of it and one
  ## ``lstat`` per entry, plus one ``readdir`` per subfolder, kept only to
  ## leave an empty folder without a "Loading..." child.  Nothing below a
  ## subfolder is read, so no folder's depth decides what a load costs.

proc loadFile(
    path: cstring,
    depth: int,
    index: int,
    parentIndices: seq[int],
    traceFilesPath: cstring,
    selfContained: bool,
    readPathOverride: cstring = cstring"",
    overlayPayloadTopLevel: bool = false): Future[CodetracerFile] {.async.} =
  ## Load the Files-pane node for ``path`` (its display path) and, when it
  ## is a folder at a depth below ``FilesystemLoadDepth``, its entries.
  ##
  ## Where it is read:
  ## - ``readPathOverride`` when set: the exact place to read, used for the
  ##   payload's top-level entries overlaid into a root and for a lazy load
  ##   that knows its node's payload location (``payloadPath``);
  ## - otherwise ``path`` itself on the live disk (``selfContained`` false),
  ##   or ``files/<path without its root>`` in the trace payload, falling
  ##   back to ``path`` on the live disk when the payload lacks it.
  ##
  ## ``index`` is the node's POSITION among its parent's children and
  ## ``parentIndices`` the positions leading to that parent:
  ## ``ui_js.onUpdatePathContent`` walks them to find the node a lazy load
  ## answers.  An entry that yields no node (a skipped folder, a failed
  ## ``lstat``) therefore does not use up an index.
  ##
  ## ``overlayPayloadTopLevel`` is set by a ROOT load only (``loadRoot``):
  ## it presents the payload's top-level entries inside an absolute
  ## recorded folder (see the overlay block below).  A lazy load never
  ## overlays — the folder it lists already holds what the root load put in
  ## the tree, and an overlaid copy would duplicate the payload's top level
  ## into every folder the user opens.
  var data: js
  var res: CodetracerFile

  if path.len == 0:
    return res

  var realPath = if readPathOverride.len > 0:
      readPathOverride
    elif not selfContained:
      path
    else:
      # Strip the path root (drive letter on Windows, leading / on Unix)
      # so that path.join produces traceFilesPath/relative/path
      # instead of just returning the absolute path.
      nodePath.join(traceFilesPath, stripPathRoot(path))

  # Whether this node is read from the trace payload.  It stops being so
  # when the payload lacks ``path`` and the loader falls back to the live
  # disk below.  From then on the live-filesystem rules apply to the node
  # and everything under it: the skipped directories (``.git``,
  # ``node_modules``, build output), no payload overlay and no payload
  # location.  Without them a fallback onto a repository root walked every
  # file in the repository before the tree was sent (GitHub #785: 35 764
  # rows for a Noir program inside the codetracer checkout).
  var readsPayload = selfContained

  try:
    data = await cast[Future[js]](fsAsync.lstat(realPath))
  except:
    if selfContained and readPathOverride.len == 0 and path != realPath:
      try:
        data = await cast[Future[js]](fsAsync.lstat(path))
        realPath = path
        readsPayload = false
      except:
        errorPrint "lstat error: ", getCurrentExceptionMsg()
        return res
    else:
      errorPrint "lstat error: ", getCurrentExceptionMsg()
      return res

  if path.len == 0:
    return res

  # Derive the display name (basename) from the path.  Using Node's
  # ``path.basename`` makes this correct on every platform — the previous
  # ``split("/")[^1]`` form returned the *entire* path on Windows, where
  # path separators are backslashes, so the Files tree showed full
  # absolute paths instead of file/folder names.  ``stripLastChar`` keeps
  # a trailing-separator-tolerant input for ``basename``.
  let strippedPath = path.stripLastChar(cstring"/").stripLastChar(cstring"\\")
  var name = nodePath.basename(strippedPath)
  if name.len == 0:
    name = strippedPath

  # Where in the payload this node was read, relative to ``files/``; ""
  # for a node read from the live disk.  The renderer sends it back when it
  # asks for the node's entries, and ``loadPathContentPartially`` reads
  # from there again — the display path cannot be mapped back to it for a
  # folder the overlay below placed under an absolute root.
  let payloadPath =
    if readsPayload and traceFilesPath.len > 0:
      cstring(payloadPathOf($nodePath.join(traceFilesPath),
                            $nodePath.join(realPath)))
    else:
      cstring""

  if cast[bool](data.isDirectory()):
    if not readsPayload and shouldSkipIndexedDirectory(realPath):
      return res

    try:
      # returning just the filenames, not full paths!
      let files = await cast[Future[seq[cstring]]](fsAsync.readdir(realPath))
      let listed = depth < FilesystemLoadDepth
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: listed},
        index: index,
        parentIndices: parentIndices,
        original: CodetracerFileData(text: name, path: path,
                                     payloadPath: payloadPath))

      if not listed:
        # A folder below the listed level: one placeholder child, which is
        # what makes the renderer draw it as an expandable folder and what
        # ``ui/filesystem.loadFolderContentIfNeeded`` keys on to ask for
        # its entries.  An empty folder gets none — there is nothing to load.
        if files.len > 0:
          res.children.add(CodetracerFile(text: "Loading..."))
        return res

      var childParentIndices = parentIndices
      childParentIndices.add(index)
      for file in files:
        var child = await loadFile(
          nodePath.join(path, file),
          depth + 1,
          res.children.len,
          childParentIndices,
          traceFilesPath,
          readsPayload,
          if readPathOverride.len > 0:
            nodePath.join(readPathOverride, file)
          else:
            cstring"")
        if not child.isNil:
          res.children.add(child)

      if overlayPayloadTopLevel and readsPayload and
          readPathOverride.len == 0 and
          traceFilesPath.len > 0 and isAbsoluteTraceSourcePath($path):
        # Portable self-contained traces can store source files relative to
        # the recorded workdir (`files/src/main.nr`) while project metadata
        # may still be mirrored under the root-stripped absolute path
        # (`files/home/user/project/Nargo.toml`).  Present both as one tree
        # rooted at the recorded source folder.  Each overlaid entry is read
        # through its own ``readPathOverride`` and so carries a
        # ``payloadPath`` naming the top-level entry (``src``), which is
        # what lets its later lazy load find it.
        let skippedRoot = firstPathSegment(stripTraceSourceRoot($path))
        let rootFiles = await cast[Future[seq[cstring]]](fsAsync.readdir(traceFilesPath))
        for file in rootFiles:
          if ($file).len == 0 or $file == skippedRoot or files.containsPathName(file):
            continue
          var child = await loadFile(
            nodePath.join(path, file),
            depth + 1,
            res.children.len,
            childParentIndices,
            traceFilesPath,
            selfContained,
            nodePath.join(traceFilesPath, file))
          if not child.isNil:
            res.children.add(child)
    except:
      errorPrint "probably directory error ", getCurrentExceptionMsg()
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: true},
        index: index,
        parentIndices: parentIndices,
        original: CodetracerFileData(text: name, path: path,
                                     payloadPath: payloadPath))

  elif cast[bool](data.isFile()) or cast[bool](data.isSymbolicLink()):
    let icon = await fileIcons.getClass(name, js{})
    res = CodetracerFile(
      text: name,
      children: @[],
      icon: $icon,
      index: index,
      parentIndices: parentIndices,
      original: CodetracerFileData(text: name, path: path,
                                   payloadPath: payloadPath))

  else:
    res = CodetracerFile(
      text: name,
      children: @[],
      state: js{opened: true},
      index: index,
      parentIndices: parentIndices,
      original: CodetracerFileData(text: name, path: path,
                                   payloadPath: payloadPath))

  res.toJs.path = path

  return res


proc loadPathContentPartially*(
    path: cstring,
    index: int,
    parentIndices: seq[int],
    traceFilesPath: cstring,
    selfContained: bool,
    payloadPath: cstring = cstring""): Future[CodetracerFile] {.async.} =
  ## **A lazy load**: the entries of the folder at ``path``, one level deep
  ## (``FilesystemLoadDepth``), for the "Loading..." stub the renderer
  ## asked about (``onLoadPathContent``).  ``index`` / ``parentIndices``
  ## are the stub's, so the answer takes its place.
  ##
  ## ``payloadPath`` is the stub's own payload location
  ## (``CodetracerFileData.payloadPath``), as the renderer sent it back.
  ## For a self-contained trace it is where the folder is read — the place
  ## the root load read it, which for an overlaid folder (``files/src``
  ## shown under the absolute recorded folder) is not derivable from
  ## ``path``.  It is followed only inside ``traceFilesPath``
  ## (``payloadReadPathFor`` refuses an absolute value or one that leaves
  ## ``files/``); a refused or empty value falls back to resolving ``path``
  ## as before, payload first, then the live disk.
  ##
  ## A lazy load never overlays the payload's top level: only a root load
  ## does (``loadRoot``).
  var readPathOverride = cstring""
  if selfContained and not payloadPath.isNil and payloadPath.len > 0 and
      not traceFilesPath.isNil and traceFilesPath.len > 0:
    let resolved = payloadReadPathFor(
      $nodePath.join(traceFilesPath), $payloadPath)
    if resolved.len > 0:
      readPathOverride = nodePath.join(cstring(resolved))
    else:
      warnPrint "load-path-content: refusing payload location '", payloadPath,
        "' for ", path, ": it is not inside ", traceFilesPath
  return await loadFile(path, 0, index, parentIndices, traceFilesPath,
                        selfContained, readPathOverride,
                        overlayPayloadTopLevel = false)

proc loadRoot(path: cstring, index: int, traceFilesPath: cstring,
              selfContained: bool): Future[CodetracerFile] {.async.} =
  ## **A root load**: one source folder of the Files pane, one level deep,
  ## with the payload's top level overlaid into it when it is an absolute
  ## recorded folder read from a portable payload (see ``loadFile``).
  ## The only caller that asks for the overlay.
  return await loadFile(path, 0, index, @[], traceFilesPath, selfContained,
                        overlayPayloadTopLevel = true)

proc loadFilesystem*(paths: seq[cstring], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.}=
  # not a real file, but artificial(root):
  #   a group of the source folders,
  #   which might not be siblings
  var folderGroup = CodetracerFile(
    text: cstring"source folders",
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[],
    original: CodetracerFileData(
      text: cstring"source folders",
      path: cstring""))

  for path in paths:
    # Indexed by position, as in ``loadFile``: a root that yields nothing
    # does not shift the ones after it.
    let file = await loadRoot(path, folderGroup.children.len, traceFilesPath, selfContained)
    if not file.isNil:
      folderGroup.children.add(file)

  return folderGroup

proc loadFilesystemWithCategory*(categoryName: cstring, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.}=
  # Load filesystem with a custom category name
  var folderGroup = CodetracerFile(
    text: categoryName,
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[],
    original: CodetracerFileData(
      text: categoryName,
      path: cstring""))

  for path in paths:
    let file = await loadRoot(path, folderGroup.children.len, traceFilesPath, selfContained)
    if not file.isNil:
      folderGroup.children.add(file)

  return folderGroup

proc isPathInside*(child: cstring, parent: cstring): bool =
  # Check if child path is inside parent directory
  let childStr = $child
  let parentStr = $parent
  # Normalize paths by ensuring they end with /
  var normalizedParent = parentStr
  if not normalizedParent.endsWith("/"):
    normalizedParent.add("/")
  var normalizedChild = childStr
  if not normalizedChild.endsWith("/"):
    normalizedChild.add("/")
  return normalizedChild.startsWith(normalizedParent)

proc getSave*(folders: seq[cstring], test: bool): Future[Save] {.async.} =
  var save = Save(project: Project(), files: @[], id: -1)
  return save

proc onSaveFile*(sender: js, response: jsobject(name=cstring, raw=cstring, saveAs=bool)) {.async.} =
  try:
    # Arm the self-write window before the write (events can be raised while
    # it is still in progress) and re-arm it after, anchored to the moment the
    # file settled.  Without this the renderer gets a "File changed on disk"
    # conflict dialog for CodeTracer's own save — issue #603.
    suppressSelfWrite(response.name)
    discard await writeFileAsync(fsAsync, response.name, response.raw)
    suppressSelfWrite(response.name)
    mainWindow.webContents.send "CODETRACER::saved-file", js{name: response.name}
  except:
    errorPrint "save-file error: ", getCurrentExceptionMsg()
    mainWindow.webContents.send "CODETRACER::save-file-error",
      js{name: response.name, error: cstring(getCurrentExceptionMsg())}

proc untitledSaveSuggestion*(bufferName: string): string =
  ## The name to pre-fill the save dialog with, for a buffer that has no path.
  ##
  ## `renderer.openNewTab` names its buffers `#untitled{N}`: the leading `#` is
  ## the marker for "this tab has no path", not part of a name anybody wants on
  ## their disk — and a file called `#untitled1` needs quoting in every shell.
  ## `.txt` because the buffer has no language (`fromPath("#untitled1")` is
  ## `LangUnknown`) and a guess inferred from the content would be a guess shown
  ## as a fact. The user can change both in the dialog; this is only the
  ## starting point.
  ##
  ## Kept in step with `ui/web_entry_surface.untitledDownloadName`, which does
  ## the same job for the browser arm's download. They are separate procs
  ## because the two modules share no compilation unit — this one is the
  ## Electron main process — and not because the rule differs.
  var name = bufferName
  if name.len > 0 and name[0] == '#':
    name = name[1 .. ^1]
  if name.len == 0:
    name = "untitled"
  if name.find('.') < 0:
    name &= ".txt"
  name

proc isUntitledBufferName*(name: string): bool =
  ## Whether a save target is a placeholder rather than a path on disk.
  name.len > 0 and name[0] == '#'

proc onSaveUntitled*(sender: js, response: jsobject(name=cstring, raw=cstring, saveAs=bool)) {.async.} =
  ## Write an untitled buffer, ASKING WHERE FIRST.
  ##
  ## It used to write to `response.name` directly, and `response.name` is the
  ## renderer's placeholder — so a Ctrl+S over a new empty file created a file
  ## literally called `#untitled0`, in the Electron main process's working
  ## directory, and reported it as saved. That is a silent write to a place the
  ## user did not choose and cannot find; the `saveAs: true` the renderer has
  ## always sent on this message said what should happen and nothing read it.
  ##
  ## The reply still carries the BUFFER's name rather than the chosen path,
  ## because `ui_js.onSavedFile` looks the tab up by it and a reply naming the
  ## destination would clear nothing. The consequence is that the tab keeps its
  ## `#untitled{N}` title and a second save asks again; renaming the tab to its
  ## destination is a renderer-side change this did not make. Documented in
  ## `GUI/Welcome-And-Sessions/Welcome-Screen.md` §"New file, and what it
  ## creates" rather than left to be rediscovered.
  try:
    var destination = response.name
    if isUntitledBufferName($response.name):
      let selection = await showSaveDialog(electron.dialog, mainWindow, js{
        title: cstring"Save file",
        defaultPath: cstring(untitledSaveSuggestion($response.name))
      })
      let chosen = cast[cstring](selection.filePath)
      if cast[bool](selection.canceled) or chosen.isNil or chosen.len == 0:
        # Reported, not swallowed. `onSaveFileError` is what drains a queued
        # re-record request (issue #603); a cancel that replied with nothing
        # would leave that request armed for ever, and would leave the buffer
        # dirty with no account of why.
        mainWindow.webContents.send "CODETRACER::save-file-error",
          js{name: response.name, error: cstring"saving was cancelled"}
        return
      destination = chosen
    suppressSelfWrite(destination)
    discard await writeFileAsync(fsAsync, destination, response.raw)
    suppressSelfWrite(destination)
    mainWindow.webContents.send "CODETRACER::saved-file", js{name: response.name}
  except:
    errorPrint "save-untitled error: ", getCurrentExceptionMsg()
    mainWindow.webContents.send "CODETRACER::save-file-error",
      js{name: response.name, error: cstring(getCurrentExceptionMsg())}

proc onNoReloadFile*(sender: js, response: jsobject(path=cstring)) =
  if data.tabs.hasKey(response.path):
    data.tabs[response.path].waitsPrompt = false

proc selectFileOrFolder*(options: JsObject): Future[cstring] {.async.} =
  let selection = await electron.dialog.showOpenDialog(mainWindow, options)
  let filePaths = cast[seq[cstring]](selection.filePaths)

  if filePaths.len > 0:
    return filePaths[0]
  else:
    return cstring""

# tried to return a folder *with* a trailing slash, if it finds one
proc selectDir*(dialogTitle: cstring, defaultPath: cstring = cstring""): Future[cstring] {.async.} =
  let selection = await electron.dialog.showOpenDialog(
    mainWindow,
    js{
      properties: @[cstring"openDirectory", cstring"showHiddenFiles"],
      title: dialogTitle,
      buttonLabel: cstring"Select",
      defaultPath: defaultPath
    }
  )

  let filePaths = cast[seq[cstring]](selection.filePaths)
  if filePaths.len > 0:
    var resultDir = filePaths[0]
    if not ($resultDir).endsWith("/"):
      resultDir.add(cstring"/")
    return resultDir
  else:
    return cstring""

proc onPathValidation*(
  sender: js,
  response: jsobject(
    path=cstring,
    fieldName=cstring,
    required=bool)) {.async.} =

  var message: cstring = ""
  var isValid = true

  if response.path == "" or response.path.isNil:
    if response.required:
      isValid = false
      message = "This field is required."
  else:
    if not await pathExists(response.path):
      isValid = false
      message = cstring("Path does not exist.")

  mainWindow.webContents.send "CODETRACER::path-validated",
    js{
      execPath: response.path,
      isValid: isValid,
      fieldName: response.fieldName,
      message: message
    }


proc onLoadPathForRecord*(sender: js, response: jsobject(fieldName=cstring)) {.async.} =
  let options = js{
    # cstring"openFile",
    # for now defaulting on directories for the noir usecase
    properties: @[cstring"openDirectory"],
    title: cstring"Select project or executable to record",
    buttonLabel: cstring"Select",
    # filters: @[FileFilter(
      # This option does not provide a proper way to filter files that are able to be selected to be only binaries.
      # May be we should implement form field validation with a warning message if the user selects a file that is not a binary.
      # name: "binaries",
      # extensions: @[cstring"bin", cstring"exe"]
    # )]
  }

  let selection = await selectFileOrFolder(options)

  mainWindow.webContents.send "CODETRACER::record-path",
    js{ execPath: selection, fieldName: response.fieldName }


proc onChooseDir*(sender: js, response: jsobject(fieldName=cstring)) {.async.} =
  let selection = await selectDir(cstring("Select {cstring(capitalize(response.fieldName))}"))
  if selection != "":
    let dirExists = await pathExists(selection)
    mainWindow.webContents.send "CODETRACER::record-path",
      js{execPath: selection, fieldName: response.fieldName}

proc onAcpPickFiles*(sender: js,
                     response: jsobject(kind=cstring)) {.async.} =
  ## Open a native file/folder picker for the agent activity + dropdown.
  ## ``kind`` is one of: "files", "folders", "trace".
  ## Responds with ``CODETRACER::acp-files-selected`` carrying ``{paths}``.
  var selections: seq[cstring] = @[]
  if response.kind == cstring"folders":
    let sel = await selectDir(cstring"Select folder")
    if sel.len > 0:
      selections.add(sel)
  else:
    # "files" and "trace" both open a multi-file picker.
    let options =
      if response.kind == cstring"trace":
        js{
          properties: @[cstring"openFile", cstring"multiSelections"],
          title: cstring"Select recording or trace file",
          buttonLabel: cstring"Attach"
        }
      else:
        js{
          properties: @[cstring"openFile", cstring"multiSelections"],
          title: cstring"Select files to attach",
          buttonLabel: cstring"Attach"
        }
    let dialogResult = await electron.dialog.showOpenDialog(mainWindow, options)
    let wasCanceled =
      jsHasKey(dialogResult, cstring"canceled") and
      dialogResult[cstring"canceled"].to(bool)
    if not wasCanceled:
      let filePaths = cast[seq[cstring]](dialogResult[cstring"filePaths"])
      for p in filePaths:
        selections.add(p)
  mainWindow.webContents.send "CODETRACER::acp-files-selected",
    js{paths: selections.toJs}

proc onLoadPathContent*(
  sender: js,
  response: jsobject(
    path=cstring,
    payloadPath=cstring,
    nodeId=cstring,
    nodeIndex=int,
    nodeParentIndices=seq[int])) {.async.} =
  ## Fill in the children of a file-tree folder that was loaded as a
  ## "Loading..." stub (see ``FilesystemLoadDepth``): one more directory
  ## listing, under the same one-level rule as the root load.
  ##
  ## ``payloadPath`` is the stub's payload location, sent back by
  ## ``ui/filesystem.loadFolderContentIfNeeded``.  For a self-contained
  ## trace ``loadPathContentPartially`` reads the folder from there, so a
  ## folder the root load overlaid from the payload's top level is read
  ## from the same place again; it is absent for a live-disk folder and for
  ## a renderer that predates it, and refused when it would leave
  ## ``files/``.
  ##
  ## The renderer replaces the stub with whatever this handler sends
  ## back, so the ONE thing this handler must never do is fail to answer:
  ## a rejected promise leaves the folder showing "Loading..." forever
  ## with no way to retry.  Every exit path below therefore emits
  ## ``update-path-content``, and a failure degrades to "this folder has
  ## no children" rather than to a permanently stuck row.
  var content: CodetracerFile = nil
  try:
    # ``data.trace`` is nil whenever the user opened a plain folder
    # (edit mode) instead of a recording — the open-folder flow never
    # assigns one.  Resolving the payload root through the pure helper
    # keeps that case (and the stale-trace case) out of the handler.
    let traceOutputFolder =
      if data.trace.isNil or data.trace.outputFolder.isNil: ""
      else: $data.trace.outputFolder
    let traceImported = not data.trace.isNil and data.trace.imported
    let workspaceFolder =
      if data.workspaceFolder.isNil: "" else: $data.workspaceFolder
    let contentRoot = pathContentRootFor(
      traceOutputFolder,
      traceImported,
      workspaceFolder,
      $response.path)
    # Absent (``undefined``) from a sender that does not know the field.
    let payloadPathValue = response.toJs[cstring"payloadPath"]
    let payloadPath =
      if payloadPathValue.isNull or payloadPathValue.isUndefined: cstring""
      else: payloadPathValue.to(cstring)

    content = await loadPathContentPartially(
      response.path,
      response.nodeIndex,
      response.nodeParentIndices,
      cstring(contentRoot.filesRoot),
      selfContained = contentRoot.selfContained,
      payloadPath = payloadPath)
  except:
    errorPrint "load-path-content error for ", response.path, ": ",
      getCurrentExceptionMsg()
    content = nil

  if content.isNil:
    # Answer anyway with a childless node so the stub is cleared.
    let name =
      if response.path.isNil or response.path.len == 0: cstring""
      else: nodePath.basename(response.path.stripLastChar(cstring"/"))
    content = CodetracerFile(
      text: if name.len > 0: name else: response.path,
      children: @[],
      state: js{opened: false},
      index: response.nodeIndex,
      parentIndices: response.nodeParentIndices,
      original: CodetracerFileData(text: name, path: response.path))
    content.toJs.path = response.path

  mainWindow.webContents.send "CODETRACER::update-path-content", js{
    content: content,
    nodeId: response.nodeId,
    nodeIndex: response.nodeIndex,
    nodeParentIndices: response.nodeParentIndices}

proc openTab(main: js, location: types.Location, lang: Lang, editorView: EditorView, line: int = -1): Future[void] {.async.} =
  await data.open(main, location, editorView, "tab-load-received", data.replay, data.exe, lang, line)

proc onTabLoad*(sender: js, response: jsobject(location=types.Location, name=cstring, editorView=EditorView, lang=Lang)) {.async.} =
  console.log response
  case response.lang:
  of LangC, LangCpp, LangRust, LangNim, LangGo, LangRubyDb:
    if response.editorView in {ViewSource, ViewTargetSource, ViewCalltrace}:
      discard mainWindow.openTab(response.location, response.lang, response.editorView)
    else:
     discard
  else:
    discard mainWindow.openTab(response.location, response.lang, response.editorView)

proc onLoadLowLevelTab*(sender: js, response: jsobject(pathOrName=cstring, lang=Lang, view=EditorView)) {.async.} =
  case response.lang:
  of LangC, LangCpp, LangRust, LangGo:
    case response.view:
    of ViewTargetSource:
      warnPrint fmt"low level view source not supported for {response.lang}"
    else:
      warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  of LangNim:
    warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  else:
    warnPrint fmt"low level view not supported for {response.lang}"

proc onOpenTab*(sender: js, response: js) {.async.} =
  let options = js{
    properties: @[cstring"openFile"],
    title: cstring"Select File",
    buttonLabel: cstring"Select"}

  let file = await selectFileOrFolder(options)
  if file != "":
    if file.slice(-4) == cstring".nim":
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangNim}
    else:
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangUnknown}

var childProcessExec* {.importcpp: "helpers.childProcessExec(#, #)".}: proc(cmd: cstring, options: js = jsUndefined): Future[(cstring, cstring, js)]

proc collectDirectoryFilenames(
    path: cstring,
    res: var seq[string],
    limit: int = 5000): Future[void] {.async.} =
  if res.len >= limit:
    return

  var stat: js
  try:
    stat = await cast[Future[js]](fsAsync.lstat(path))
  except:
    return

  if cast[bool](stat.isFile()) or cast[bool](stat.isSymbolicLink()):
    res.add($path)
    return

  if not cast[bool](stat.isDirectory()) or shouldSkipIndexedDirectory(path):
    return

  var entries: seq[cstring] = @[]
  try:
    entries = await cast[Future[seq[cstring]]](fsAsync.readdir(path))
  except:
    return

  for entry in entries:
    if res.len >= limit:
      return
    await collectDirectoryFilenames(nodePath.join(path, entry), res, limit)

proc stripPathPrefix(path, root: string): string =
  if path == root:
    return ""
  let unixPrefix = root & "/"
  let windowsPrefix = root & "\\"
  if path.startsWith(unixPrefix):
    return path[unixPrefix.len .. ^1]
  if path.startsWith(windowsPrefix):
    return path[windowsPrefix.len .. ^1].replace("\\", "/")
  path

proc collectDirectoryFilenamesRelative(
    root: cstring,
    path: cstring,
    res: var seq[string],
    limit: int = 5000): Future[void] {.async.} =
  if res.len >= limit:
    return

  var stat: js
  try:
    stat = await cast[Future[js]](fsAsync.lstat(path))
  except:
    return

  if cast[bool](stat.isFile()) or cast[bool](stat.isSymbolicLink()):
    let relative = stripPathPrefix($path, $root)
    if relative.len > 0:
      res.add(relative)
    return

  if not cast[bool](stat.isDirectory()) or shouldSkipIndexedDirectory(path):
    return

  var entries: seq[cstring] = @[]
  try:
    entries = await cast[Future[seq[cstring]]](fsAsync.readdir(path))
  except:
    return

  for entry in entries:
    if res.len >= limit:
      return
    await collectDirectoryFilenamesRelative(root, nodePath.join(path, entry), res, limit)

proc loadFilenames*(paths: seq[cstring], traceFolder: cstring, selfContained: bool): Future[seq[string]] {.async.} =
  var res: seq[string] = @[]

  if not selfContained:
    for pathLent in paths:
      # ``for path in paths`` yields ``lent cstring`` on Nim 2.x and
      # the async/await closure cannot capture a lent borrow.  Copy
      # to a local owned cstring before passing into the closures.
      let path = pathLent
      try:
        let repoCheck =
          await childProcessExec(cstring(&"git rev-parse --show-toplevel"), js{cwd: path})
        let errRoot = repoCheck[2]
        if errRoot.isNil:
          let pathPrefix = path.stripLastChar(cstring"/")
          let (stdout, stderr, err) =
            await childProcessExec(cstring(&"git ls-files -- ."), js{cwd: path})
          if err.isNil:
            res = res.concat(($stdout).splitLines().filterIt(it.len > 0).mapIt($pathPrefix & "/" & it))
      except:
        discard
    if res.len == 0:
      for path in paths:
        await collectDirectoryFilenames(path, res)
  else:
    # for now assume db-backend, otherwise empty
    if traceFolder.len > 0:
      var pathSet = JsAssoc[cstring, bool]{}
      # M-REC-1.5: the runtime-materialized sidecar is `paths.json`
      # (matches the CTFS internal-file name).  The legacy
      # `trace_paths.json` is retired pre-1.0.
      let runtimePathsPath = $traceFolder / "paths.json"
      let (rawTracePaths, err) = await fsReadFileWithErr(cstring(runtimePathsPath))
      if err.isNil:
        let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
        for path in tracePaths:
          pathSet[path] = true
      else:
        # leave pathSet empty
        warnPrint "loadFilenames for self contained trace trying to read ", runtimePathsPath, ":", err

      for path, _ in pathSet:
        res.add($path)
      if res.len == 0:
        let filesRoot = nodePath.join(traceFolder, cstring"files")
        await collectDirectoryFilenamesRelative(filesRoot, filesRoot, res)
    else:
      # leave res empty
      discard
  return res
