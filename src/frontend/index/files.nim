import
  std / [ async, jsffi, json, strutils ],
  electron_vars, config,
  ../[ types, lib ],
  ../../common/ct_logging

type FileFilter = ref object
  name*: cstring
  extensions*: seq[cstring]

let
  fileIcons = require("@exuanbo/file-icons-js")
  fsAsync = require("fs").promises

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}
proc getClass(icons: js, name: cstring, options: js): Future[cstring] {.importjs: "#.getClass(#,#)".}

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
      # extensions: @[j"bin", j"exe"]
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