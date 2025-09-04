import
  std / [ async, jsffi, json, strutils ],
  electron_vars,
  ../../[ index_config, types, lib ]

type FileFilter = ref object
  name*: cstring
  extensions*: seq[cstring]

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}

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