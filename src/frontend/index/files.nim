import
  std / [ async, jsffi, json, strutils, strformat, sequtils, jsconsole, os ],
  electron_vars, config,
  ../[ types, lang ],
  ../lib/[ jslib, electron_lib ],
  ../../common/ct_logging

type FileFilter = ref object
  name*: cstring
  extensions*: seq[cstring]

let
  fileIcons = require("@exuanbo/file-icons-js")
  fsAsync = require("fs").promises

proc writeFileAsync(fs: JsObject, path: cstring, data: cstring): Future[JsObject] {.importjs: "#.writeFile(#, #)".}

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}
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

proc editFilesystemDepthLimit(selfContained: bool): int =
  if selfContained:
    int.high
  else:
    2

proc loadFile(
    path: cstring,
    depth: int,
    index: int,
    parentIndices: seq[int],
    traceFilesPath: cstring,
    selfContained: bool): Future[CodetracerFile] {.async.} =
  var data: js
  var res: CodetracerFile

  if path.len == 0:
    return res

  var realPath = if not selfContained:
      path
    else:
      # Strip the path root (drive letter on Windows, leading / on Unix)
      # so that path.join produces traceFilesPath/relative/path
      # instead of just returning the absolute path.
      nodePath.join(traceFilesPath, stripPathRoot(path))

  try:
    data = await cast[Future[js]](fsAsync.lstat(realPath))
  except:
    if selfContained and path != realPath:
      try:
        data = await cast[Future[js]](fsAsync.lstat(path))
        realPath = path
      except:
        errorPrint "lstat error: ", getCurrentExceptionMsg()
        return res
    else:
      errorPrint "lstat error: ", getCurrentExceptionMsg()
      return res

  if path.len == 0:
    return res

  let strippedPath = path.stripLastChar(cstring"/")
  let subParts = strippedPath.split(cstring"/")
  let name = subParts[^1]

  if cast[bool](data.isDirectory()):
    if not selfContained and shouldSkipIndexedDirectory(realPath):
      return res

    try:
      # returning just the filenames, not full paths!
      let files = await cast[Future[seq[cstring]]](fsAsync.readdir(realPath))
      let depthLimit = editFilesystemDepthLimit(selfContained)
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: depth < depthLimit},
        index: index,
        parentIndices: parentIndices,
        original: CodetracerFileData(text: name, path: path))

      if depth >= depthLimit:
        res.state.opened = false
        if files.len > 0:
          res.children.add(CodetracerFile(text: "Loading..."))
        return res

      if files.len > 0:
        var newParentIndices = parentIndices
        newParentIndices.add(index)
        for fileIndex, file in files:
          var child = await loadFile(
            nodePath.join(path, file),
            depth + 1,
            fileIndex,
            newParentIndices,
            traceFilesPath,
            selfContained)
          if not child.isNil:
            res.children.add(child)
    except:
      errorPrint "probably directory error ", getCurrentExceptionMsg()
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: true},
        original: CodetracerFileData(text: name, path: path))

  elif cast[bool](data.isFile()) or cast[bool](data.isSymbolicLink()):
    let icon = await fileIcons.getClass(name, js{})
    res = CodetracerFile(
      text: name,
      children: @[],
      icon: $icon,
      index: index,
      parentIndices: parentIndices,
      original: CodetracerFileData(text: name, path: path))

  else:
    res = CodetracerFile(
      text: name,
      children: @[],
      state: js{opened: true},
      original: CodetracerFileData(text: name, path: path))

  res.toJs.path = path

  return res


proc loadPathContentPartially*(path: cstring, index: int, parentIndices: seq[int], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.} =
  let depth = 0
  return await loadFile(path, depth, index, parentIndices, traceFilesPath, selfContained)

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

  var parentIndices: seq[int] = @[]
  for index, path in paths:
    let file = await loadPathContentPartially(path, index, parentIndices, traceFilesPath, selfContained)
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

  var parentIndices: seq[int] = @[]
  for index, path in paths:
    let file = await loadPathContentPartially(path, index, parentIndices, traceFilesPath, selfContained)
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
    if data.tabs.hasKey(response.name):
      data.tabs[response.name].ignoreNext += 1
    discard await writeFileAsync(fsAsync, response.name, response.raw)
    mainWindow.webContents.send "CODETRACER::saved-file", js{name: response.name}
  except:
    errorPrint "save-file error: ", getCurrentExceptionMsg()
    mainWindow.webContents.send "CODETRACER::save-file-error",
      js{name: response.name, error: cstring(getCurrentExceptionMsg())}

proc onSaveUntitled*(sender: js, response: jsobject(name=cstring, raw=cstring, saveAs=bool)) {.async.} =
  try:
    if data.tabs.hasKey(response.name):
      data.tabs[response.name].ignoreNext += 1
    discard await writeFileAsync(fsAsync, response.name, response.raw)
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

proc onLoadPathContent*(
  sender: js,
  response: jsobject(
    path=cstring,
    nodeId=cstring,
    nodeIndex=int,
    nodeParentIndices=seq[int])) {.async.} =
  # this won't work if we have multiple traces in one index_js instance!
  let traceFilesPath = nodePath.join(data.trace.outputFolder, cstring"files")
  let content = await loadPathContentPartially(
    response.path,
    response.nodeIndex,
    response.nodeParentIndices,
    traceFilesPath,
    selfContained=data.trace.imported)

  if not content.isNil:
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

proc loadFilenames*(paths: seq[cstring], traceFolder: cstring, selfContained: bool): Future[seq[string]] {.async.} =
  var res: seq[string] = @[]

  if not selfContained:
    for path in paths:
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
    else:
      # leave res empty
      discard
  return res
