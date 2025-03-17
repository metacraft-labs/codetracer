import
  std/[os, json, strutils, strformat, sets, algorithm, terminal],
  ../../common/[trace_index, lang, types, paths],
  ../utilities/git,
  ../online_sharing/security_upload,
  json_serialization

proc storeTraceFiles(paths: seq[string], traceFolder: string, lang: Lang) =
  let filesFolder = traceFolder / "files"
  createDir(filesFolder)

  var sourcePaths = paths

  if lang == LangNoir:
    var baseFolder = ""
    for path in paths:
      if path.len > 0 and path.startsWith('/'):
        let originalFolder = path.parentDir
        if baseFolder.len == 0 or baseFolder.len > originalFolder.len and
            baseFolder.startsWith(originalFolder):
          baseFolder = originalFolder
    # assuming or at least trying for something like `<noir-project>/src/`
    if baseFolder.lastPathPart == "src":
      baseFolder = baseFolder.parentDir
    # adding baseFolder : if the top level of the noir project, hoping
    # that we copy Prover.toml, Nargo.toml, readme etc
    for pathData in walkDir(baseFolder):
      if pathData.kind == pcFile:
        sourcePaths.add(pathData.path)

    # echo baseFolder, " ", sourcePaths

  for path in sourcePaths:
    if path.len > 0:
      # echo "store path ", path
      let traceFilePath = filesFolder / path
      let traceFileFolder = traceFilePath.parentDir
      try:
        # echo "create ", traceFileFolder
        createDir(traceFileFolder)
        # echo "copy to ", traceFilePath
        copyFile(path, traceFilePath)
      except CatchableError as e:
        echo fmt"WARNING: trying to copy trace file {path} error: ", e.msg
        echo "  skipping copying that file"


proc processSourceFoldersList*(folderSet: HashSet[string], programDir: string = ""): seq[string] =
  var folders: seq[string] = @[]
  let gitRoot = getGitTopLevel(programDir)
  var i = 0

  for potentialChild in folderSet:
    var ok = true
    # e.g. generated_not_to_break_here/ or relative/
    if potentialChild.len == 0 or potentialChild[0] != '/':
      ok = false
    else:
      var k = 0
      for potentialParent in folderSet:
        if i != k and potentialChild.startsWith(potentialParent):
          ok = false
          break
        k += 1
    if ok and not potentialChild.startsWith(gitRoot):
      folders.add(potentialChild)
    i += 1

  # Add Git repository roots to the final result
  if gitRoot != "":
    folders.add(gitRoot)

  if folders.len == 0:
    folders.add(getAppFilename().parentDir)
  # based on https://stackoverflow.com/a/24867480/438099
  # credit to @DrCopyPaste https://stackoverflow.com/users/2186023/drcopypaste
  var sortedFolders = sorted(folders)
  result = sortedFolders


proc importDbTrace*(
  traceMetadataPath: string,
  traceIdArg: int,
  lang: Lang = LangNoir,
  selfContained: bool = true,
  downloadKey: string = ""
): Trace =
  let rawTraceMetadata = readFile(traceMetadataPath)
  let untypedJson = parseJson(rawTraceMetadata)
  let program = untypedJson{"program"}.getStr()
  let args = untypedJson{"args"}.getStr().splitLines()
  let workdir = untypedJson{"workdir"}.getStr()

  let traceID = if traceIdArg != NO_TRACE_ID:
      traceIdArg
    else:
      trace_index.newId(test=false)

  let traceFolder = traceMetadataPath.parentDir
  let tracePathsPath = traceFolder / "trace_paths.json"
  let tracePath = traceFolder / "trace.json"

  let outputFolder = fmt"{codetracerTraceDir}/trace-{traceID}/"
  if traceIdArg == NO_TRACE_ID:
    createDir(outputFolder)
    copyFile(traceMetadataPath, outputFolder / "trace_metadata.json")
    try:
      copyFile(tracePathsPath, outputFolder / "trace_paths.json")
    except CatchableError as e:
      echo "WARNING: probably no trace_paths.json: no self-contained support in this case:"
      echo "  ", e.msg
      echo "  skipping trace_paths file"
    copyFile(tracePath, outputFolder / "trace.json")

  var rawPaths: string
  try:
    rawPaths = readFile(tracePathsPath)
  except CatchableError as e:
    echo "warn: probably no trace_paths.json: no self-contained support for now:"
    echo "  ", e.msg
    echo "  skipping trace_paths file"

  var paths: seq[string] = @[]
  if rawPaths.len > 0:
    paths = Json.decode(rawPaths, seq[string])

  if selfContained:
    # for now assuming it happens on the original machine
    # when the source files are still available and unchanged
    if paths.len > 0:
      storeTraceFiles(paths, outputFolder, lang)

  var sourceFoldersInitialSet = initHashSet[string]()
  for path in paths:
    if path.len > 0 and path.startsWith('/'):
      sourceFoldersInitialSet.incl(path.parentDir)

  let sourceFolders = processSourceFoldersList(sourceFoldersInitialSet, workdir)
  # echo sourceFolders
  let sourceFoldersText = sourceFolders.join(" ")

  trace_index.recordTrace(
    traceID,
    program = program,
    args = args,
    compileCommand = "",
    env = "",
    workdir = workdir,
    lang = lang,
    sourceFolders = sourceFoldersText,
    lowLevelFolder = "",
    outputFolder = outputFolder,
    test = false,
    imported = selfContained,
    shellID = -1,
    rrPid = -1,
    exitCode = -1,
    calltrace = true,
    # for now always use FullRecord for db-backend
    # and ignore possible env var override
    calltraceMode = CalltraceMode.FullRecord,
    downloadKey = downloadKey)

proc getFolderSize(folderPath: string): int64 =
  var totalSize: int64 = 0
  for kind, path in walkDir(folderPath):
    if kind == pcFile:
      totalSize += getFileSize(path)
  return totalSize

const
  FILE_SIZE_LIMIT_EXCEETED_EXIT_CODE = 153

proc uploadTrace*(trace: Trace) =
  let outputZip = trace.outputFolder / "tmp.zip"
  let aesKey = generateSecurePassword()

  var (output, exitCode) = ("", 0)
  
  if getFolderSize(trace.outputFolder) > 4_000_000_000:
    quit(FILE_SIZE_LIMIT_EXCEETED_EXIT_CODE)

  try:
    zipFileWithEncryption(trace.outputFolder, outputZip, aesKey)

    (output, exitCode) = uploadEncyptedZip(outputZip)
    let jsonMessage = parseJson(output)
    let downloadKey = trace.program & "//" & jsonMessage["DownloadId"].getStr("") & "//" & aesKey

    if jsonMessage["Successful"].getBool(false):

      updateField(trace.id, "remoteShareDownloadId", downloadKey, false)
      updateField(trace.id, "remoteShareControlId", jsonMessage["ControlId"].getStr(""), false)
      updateField(trace.id, "remoteShareExpireTime", jsonMessage["Expires"].getInt(), false)

      if isatty(stdout):
        echo fmt"""
OK: uploaded, you can share the link.
NB: It's sensitive: everyone with this link can access your trace!

Download with:
`ct download {downloadKey}`
"""

      else:
        # for parsing by `ct` index code
        echo downloadKey
        echo jsonMessage["ControlId"].getStr("")
        echo jsonMessage["Expires"].getInt()

    else:
      exitCode = 1

  except CatchableError as e:
    echo fmt"error: can't delete trace {e.msg}"
    removeFile(outputZip)
    removeFile(outputZip & ".enc")
    exitCode = 1

  removeFile(outputZip)
  removeFile(outputZip & ".enc")

  quit(exitCode)
