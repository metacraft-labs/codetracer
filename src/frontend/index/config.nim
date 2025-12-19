import
  std / [ async, jsffi, os, strformat, strutils, sequtils, jsconsole ],
  ../[ config, types, lang ],
  ../lib/[ jslib, electron_lib, misc_lib ],
  ./bootstrap_cache,
  ../../common/[ paths, ct_logging ]

type
  ServerData* = object
    tabs*: JsAssoc[cstring, ServerTab]
    config*: Config
    trace*: Trace
    replay*: bool
    exe*: seq[cstring]
    closedTabs*: seq[cstring]
    closedPanels*: seq[cstring]
    save*: Save
    startOptions*: StartOptions
    start*: int64
    pluginCommands*: JsAssoc[cstring, SearchSource]
    pluginClient*: PluginClient
    debugInstances*: JsAssoc[int, DebugInstance]
    recordProcess*: NodeSubProcess
    layout*: js
    helpers*: Helpers
    bootstrapMessages*: seq[BootstrapPayload]
    workspaceFolder*: cstring  # The folder opened in edit mode (persists across mode switches)

  DebugInstance* = object
    process*:       NodeSubProcess
    pipe*:          JsObject

  ServerTab* = ref object
    path*:          cstring
    lang*:          Lang
    fileWatched*:   bool
    ignoreNext*:    int # save
    waitsPrompt*:   bool


var data* = ServerData(
  replay: true,
  exe: @[],
  tabs: JsAssoc[cstring, ServerTab]{},
  closedTabs: @[],
  closedPanels: @[],
  bootstrapMessages: @[],
  startOptions: StartOptions(
    loading: true,
    screen: true,
    inTest: false,
    record: false,
    edit: false,
    name: cstring"",
    frontendSocket: SocketAddressInfo(),
    backendSocket: SocketAddressInfo(),
    idleTimeoutMs: 10 * 60 * 1_000,
    rawTestStrategy: cstring""
  ),
  pluginCommands: JsAssoc[cstring, SearchSource]{},
  debugInstances: JsAssoc[int, DebugInstance]{}
)

let helpers* {.exportc: "helpers".} = require("./helpers")
var
  fsWriteFileWithErr*  {.  importcpp: "helpers.fsWriteFileWithErr(#, #)"                   .}:  proc(f: cstring, s: cstring):                    Future[js]
  fsCopyFileWithErr    {.  importcpp: "helpers.fsCopyFileWithErr(#, #)"                    .}:  proc(a: cstring, b: cstring):                    Future[js]
  fsMkdirWithErr       {.  importcpp: "helpers.fsMkdirWithErr(#, #)"                       .}:  proc(a: cstring, options: JsObject):             Future[JsObject]
  fsReadFileWithErr*   {.  importcpp: "helpers.fsReadFileWithErr(#)"                       .}:  proc(f: cstring):                                Future[(cstring, js)]

proc open*(data: ServerData, main: js, location: types.Location, editorView: EditorView, messagePath: string, replay: bool, exe: seq[cstring], lang: Lang, line: int): Future[void] {.async.} =
  var source = cstring""
  # var tokens: seq[seq[Token]] = @[]
  var symbols = JsAssoc[cstring, seq[js]]{}
  if location.highLevelPath == cstring"unknown":
    return
  let filename = location.highLevelPath
  # TODO path for low level?
  # if data.tabs.hasKey(filename):
  #   return

  # TODO: explicitly ask for trace source of direct file
  # e.g. source location/debugger always => trace source
  # ctrlp/filesystem: maybe based on where the file comes from:
  #   trace paths/trace sourcefolder or direct filesystem/other
  # ctrl+o/similar => direct
  var readPath = if data.trace.imported:
      let traceFilesFolder = $data.trace.outputFolder / "files"
      cstring(traceFilesFolder / $filename)
    else:
      filename

  var err: js
  (source, err) = await fsReadFileWithErr(readPath)
  if not err.isNil:
    # source = cstring"<file missing>!"
    # filename = cstring"<file missing: " & filename & cstring">"
    # missing = true
    console.log "error reading file directly ", filename, " ", err
    if data.trace.imported:
      # try original filename if
      # it was first tried with a trace copy path
      (source, err) = await fsReadFileWithErr(filename)

      if not err.isNil:
        console.log "error reading file from trace ", filename, " ", err
        return
    else:
      # we tried the original filename if not imported:
      # directly stop
      console.log "error: trace not imported, but file couldn't be read ", filename
      return
    # bug "file missing " & $filename

  if err.isNil:
    if not data.tabs.hasKey(filename):
      # TODO: enable again, but
      # try to not send event for our own saves/changes

      # fs.watch(filename) do (e: cstring, filenameArg: cstring):
      #   if e == cstring"change":
      #     # debugPrint "change?", filename
      #     # TODO: try to not send event for our own saves/changes
      #     if not data.tabs.hasKey(filename):
      #       data.tabs[filename] = ServerTab(path: filename, lang: LangUnknown, fileWatched: true)
      #     if data.tabs[filename].fileWatched and data.tabs[filename].ignoreNext == 0 and not data.tabs[filename].waitsPrompt:
      #       data.tabs[filename].waitsPrompt = true
      #       mainWindow.webContents.send "CODETRACER::change-file", js{path: filename}
      #     elif data.tabs[filename].ignoreNext > 0:
      #       data.tabs[filename].ignoreNext = data.tabs[filename].ignoreNext - 1

      data.tabs[filename] = ServerTab(path: filename, lang: lang, fileWatched: true)

  echo "index_config open: file read succesfully"
  var sourceLines = source.split(jsNl)

  var name = cstring""
  var argId = cstring""

  if location.isExpanded:
    sourceLines = sourceLines.slice(location.expansionFirstLine - 1, location.expansionLastLine)
    source = sourceLines.join(jsNl) & jsNl
    name = location.functionName
    argId = name
  else:
    name = basename(filename)
    # TODO maybe remove if we don't hit that for some time
    if name == cstring"expanded.nim":
      errorPrint "expanded.nim with isExpanded == false ", filename
      return
    argId = filename

  if editorView == ViewCalltrace:
    name = location.path & cstring":" & location.functionName & cstring"-" & location.key
    argId = name
    sourceLines = sourceLines.slice(location.functionFirst - 1, location.functionLast)
    source = sourceLines.join(jsNl) & jsNl

  main.webContents.send "CODETRACER::" & messagePath, js{
    "argId": argId,
    "value": TabInfo(
      overlayExpanded: -1,
      highlightLine: -1,
      location: location,
      source: source,
      sourceLines: sourceLines,
      received: true,

      name: name,
      path: filename,
      lang: lang
    )
  }


proc findConfig(folder: cstring, configPath: cstring): cstring =
  var current = folder
  var config = false
  while true:
    let path = nodePath.join(current, configPath)
    if fs.existsSync(path):
      return path
    else:
      if config:
        return cstring""
      current = nodePath.dirname(current)
      if current == cstring"/":
        current = userConfigDir
        config = true

proc loadConfig*(main: js, startOptions: StartOptions, home: cstring = cstring"", send: bool = false): Future[Config] {.async.} =
  var file = findConfig(startOptions.folder, configPath)
  if file.len == 0:
    file = userConfigDir / configPath

    let errMkdir = await fsMkdirWithErr(cstring(userConfigDir), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for config folder error: exiting: ", errMkdir
      quit(1)

    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultConfigPath}"),
      cstring(fmt"{userConfigDir / configPath}")
    )

    if not errCopy.isNil:
      errorPrint "can't copy .config.yaml to user config dir:"
      errorPrint "  tried to copy from: ", cstring(fmt"{configDir / defaultConfigPath}")
      errorPrint "  to: ", fmt"{userConfigDir / configPath}"
      quit(1)

  infoPrint "index: load config ", file
  let (s, err) = await fsreadFileWithErr(file)
  if not err.isNil:
    errorPrint "read config file error: ", err
    quit(1)
  try:
    let config = cast[Config](yaml.load(s))
    config.shortcutMap = initShortcutMap(config.bindings)
    return config
  except:
    errorPrint "load config or init shortcut map error: ", getCurrentExceptionMsg()
    quit(1)

proc loadLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  let (data, err) = await fsreadFileWithErr(cstring(filename))
  if err.isNil:
    let config = JSON.parse(data)
    return config
  else:
    let directory = filename.parentDir
    let errMkdir = await fsMkdirWithErr(cstring(directory), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for layout config folder error: exiting: ", errMkdir
      quit(1)

    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultLayoutPath}"),
      cstring(filename)
    )

    if errCopy.isNil:
      return await loadLayoutConfig(main, filename)
    else:
      errorPrint "index: load layout config error: ", errCopy
      quit(1)

proc loadEditLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  ## Load edit mode layout configuration from file
  let (data, err) = await fsreadFileWithErr(cstring(filename))
  if err.isNil:
    let config = JSON.parse(data)
    return config
  else:
    # Edit mode layout file doesn't exist yet - use default debug layout as fallback
    let defaultLayoutFile = userLayoutDir / "default_layout.json"
    let (defaultData, defaultErr) = await fsreadFileWithErr(cstring(defaultLayoutFile))
    if defaultErr.isNil:
      let config = JSON.parse(defaultData)
      return config
    else:
      # Fall back to the bundled default layout
      let errCopy = await fsCopyFileWithErr(
        cstring(fmt"{configDir / defaultLayoutPath}"),
        cstring(filename)
      )
      if errCopy.isNil:
        return await loadEditLayoutConfig(main, filename)
      else:
        errorPrint "index: load edit layout config error: ", errCopy
        quit(1)

proc loadValues*(a: js, id: cstring): JsAssoc[cstring, cstring] =
  var fields = JsAssoc[cstring, js]{}
  var values = JsAssoc[cstring, cstring]{}
  if id == cstring"CODETRACER::updated-slice":
    return values
  if isJsObject(a):
    fields = cast[JsAssoc[cstring, js]](a)
  elif isJsArray(a):
    for i, element in a:
      fields[i.toCString] = element
  else:
    fields[cstring""] = a
  for field, value in fields:
    if field == cstring"source":
      continue
    elif not value.isNil:
      values[field] = value.toCString
    elif value.isNil:
      values[field] = cstring"undefined"
    else:
      values[field] = cstring"nil"
  return values
