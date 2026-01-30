import
  std/[ os, json, strutils, strformat, sets, algorithm ],
  ../../common/[ trace_index, lang, types, paths ],
  ../utilities/[ git, language_detection ],
  json_serialization, results

proc storeTraceFiles(paths: seq[string], traceFolder: string, lang: Lang) =
  let filesFolder = traceFolder / "files"
  createDir(filesFolder)

  var sourcePaths = paths

  if lang in {LangNoir, LangRustWasm, LangCppWasm}:
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
  let gitRootResult = getGitTopLevel(programDir)
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
    # echo "ok? ", ok, " ", potentialChild, " with? ", gitRootResult
    if ok:
      let startsWithGitRoot = if gitRootResult.isOk:
          potentialChild.startsWith(gitRootResult.value)
        else:
          false
      if not startsWithGitRoot:
        folders.add(potentialChild)
    i += 1

  # Add Git repository roots to the final result
  if gitRootResult.isOk:
    folders.add(gitRootResult.value)

  if folders.len == 0:
    folders.add(getAppFilename().parentDir)
  # based on https://stackoverflow.com/a/24867480/438099
  # credit to @DrCopyPaste https://stackoverflow.com/users/2186023/drcopypaste
  var sortedFolders = sorted(folders)
  result = sortedFolders


proc importTrace*(
  traceFolder: string,
  traceIdArg: int,
  recordPid: int,
  langArg: Lang = LangNoir,
  selfContained: bool = true,
  downloadUrl: string = "",
  traceKind: string = "db",
): Trace =

  # for now support different files with the same subset of fields:
  #   db: trace_metadata.json
  #   rr: trace_db_metadata.json:
  # both should have `program`, `args`, `workdir`(but maybe also others)
  let traceMetadataPath = if traceKind == "db":
      traceFolder / "trace_metadata.json"
    else:
      traceFolder / "trace_db_metadata.json"

  # echo traceMetadataPath
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
  var traceFileName = "trace.bin"
  var tracePath = traceFolder / traceFileName
  if not fileExists(tracePath):
    traceFileName = "trace.json"
    tracePath = traceFolder / traceFileName

  let outputFolder = if traceIdArg == NO_TRACE_ID:
      fmt"{codetracerTraceDir}/trace-{traceID}/"
    else:
      traceFolder
  if traceIdArg == NO_TRACE_ID:
    createDir(outputFolder)
    if traceMetadataPath.endsWith("trace_metadata.json"):
      copyFile(traceMetadataPath, outputFolder / "trace_metadata.json")
    elif traceMetadataPath.endsWith("trace_db_metadata.json"):
      copyFile(traceMetadataPath, outputFolder / "trace_db_metadata.json")

    try:
      copyFile(tracePathsPath, outputFolder / "trace_paths.json")
    except CatchableError as e:
      echo "WARNING: probably no trace_paths.json: no self-contained support in this case:"
      echo "  ", e.msg
      echo "  skipping trace_paths file"
    copyFile(tracePath, outputFolder / traceFileName)

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

  var lang = langArg

  if lang == LangUnknown:
    for path in paths:
      # `program` from trace_metadata
      let isWasm = program.extractFilename.split(".")[^1] == "wasm" # Check if language is wasm
      let traceLang = detectLangFromPath(path, isWasm)
      if traceLang != LangUnknown:
        # for now assume this is used only for db traces
        # and that C/C++/Rust there can come only from wasm targets currently
        if traceLang == LangRust:
          lang = if traceKind == "db": LangRustWasm else: LangRust
        elif traceLang in {LangC, LangCpp}:
          lang = if traceKind == "db": LangCppWasm else: traceLang
        else:
          lang = traceLang
        break # for now assume the first detected lang is ok

  if dirExists(traceFolder / "files"):
    if traceFolder != outputFolder:
      copyDir(traceFolder / "files", outputFolder / "files")
  elif selfContained and downloadUrl == "":
    # for now assuming if no `files/` dir already,
    # it happens on the original machine
    # when the source files are still available and unchanged
    if paths.len > 0:
      storeTraceFiles(paths, outputFolder, lang)

  var sourceFoldersInitialSet = initHashSet[string]()
  for path in paths:
    if path.len > 0 and path.startsWith('/'):
      sourceFoldersInitialSet.incl(path.parentDir)

  let sourceFolders = processSourceFoldersList(sourceFoldersInitialSet, workdir)
  let sourceFoldersText = sourceFolders.join(" ")

  # echo "traceKind ", traceKind
  if traceKind == "db":
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
      rrPid = recordPid,
      exitCode = -1,
      calltrace = true,
      # for now always use FullRecord for db-backend
      # and ignore possible env var override
      calltraceMode = CalltraceMode.FullRecord,
      fileId = downloadUrl)
  else:
    try:
      var trace = Json.decode(readFile(traceMetadataPath), Trace)
      trace.id = traceID
      # trace.sourceFolders = sourceFolders
      trace.outputFolder = outputFolder
      trace.imported = selfContained
      # echo trace.repr
      trace_index.recordTrace(trace, test=false)
    except CatchableError as e:
      echo "[codetracer importTrace error]: ", e.repr
      quit(1)

proc getFolderSize(folderPath: string): int64 =
  var totalSize: int64 = 0
  for kind, path in walkDir(folderPath):
    if kind == pcFile:
      totalSize += getFileSize(path)
  return totalSize
