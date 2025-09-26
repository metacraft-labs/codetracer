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

proc stripLastChar(text: cstring, c: cstring): cstring =
  if cstring($(text[text.len - 1])) == c:
    return cstring(($(text)).substr(0, text.len - 2))
  else:
    return text

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

  let realPath = if not selfContained:
      path
    else:
      # https://stackoverflow.com/a/39836259/438099
      # see here ^:
      # join combines two absolute paths /a and /b into /a/b
      # resolve returns just /b
      # here we want the first behavior!
      nodePath.join(traceFilesPath, path)

  try:
    data = await cast[Future[js]](fsAsync.lstat(realPath))
  except:
    errorPrint "lstat error: ", getCurrentExceptionMsg()
    return res

  if path.len == 0:
    return res

  let strippedPath = path.stripLastChar(cstring"/")
  let subParts = strippedPath.split(cstring"/")
  let name = subParts[^1]

  if cast[bool](data.isDirectory()):
    try:
      # returning just the filenames, not full paths!
      let files = await cast[Future[seq[cstring]]](fsAsync.readdir(realPath))
      let depthLimit = subParts.len() - 2
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

proc getSave*(folders: seq[cstring], test: bool): Future[Save] {.async.} =
  var save = Save(project: Project(), files: @[], id: -1)
  return save

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

proc loadFilenames*(paths: seq[cstring], traceFolder: cstring, selfContained: bool): Future[seq[string]] {.async.} =
  var res: seq[string] = @[]
  var repoPathSet: JsAssoc[cstring, bool] = JsAssoc[cstring, bool]{}

  if not selfContained:
    for path in paths:
      try:
        let (stdoutRev, stderrRev, errRev) = await childProcessExec(cstring(&"git rev-parse --show-toplevel"), js{cwd: path})
        repoPathSet[stdoutRev.trim] = true
      except Exception as e:
        errorPrint "git rev-parse error for ", path, ": ", e.repr
    for path, _ in repoPathSet:
      let (stdout, stderr, err) = await childProcessExec(cstring(&"git ls-tree HEAD -r --name-only"), js{cwd: path})
      if err.isNil:
        res = res.concat(($stdout).splitLines().mapIt($path & "/" & it))
      else:
        discard
        #res = cast[seq[string]](@[])
        # if not a git repo: just load some files? empty for now
        # for now for self-contained load files from trace
        # TODO discuss
  else:
    # for now assume db-backend, otherwise empty
    if traceFolder.len > 0:
      var pathSet = JsAssoc[cstring, bool]{}
      let tracePathsPath = $traceFolder / "trace_paths.json"
      let (rawTracePaths, err) = await fsReadFileWithErr(cstring(tracePathsPath))
      if err.isNil:
        let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
        for path in tracePaths:
          pathSet[path] = true
      else:
        # leave pathSet empty
        warnPrint "loadFilenames for self contained trace trying to read ", tracePathsPath, ":", err

      for path, _ in pathSet:
        res.add($path)
    else:
      # leave res empty
      discard
  return res