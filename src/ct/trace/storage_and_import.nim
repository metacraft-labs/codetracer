import
  std/[ os, strutils, strformat, sets, algorithm, sequtils ],
  ../../common/[ trace_index, lang, types, paths ],
  ../utilities/[ git, language_detection ],
  ctfs_sources,
  source_paths,
  results

proc isAbsolutePath(path: string): bool =
  isAbsoluteTracePath(path)

proc stripPathRoot(path: string): string =
  stripTracePathRoot(path)

proc storeTraceFiles(paths: seq[string], traceFolder, workdir: string, lang: Lang) =
  let filesFolder = traceFolder / "files"
  createDir(filesFolder)

  var sourcePaths = paths.mapIt(resolveTraceSourcePath(it, workdir))

  if lang in {LangNoir, LangRustWasm, LangCppWasm}:
    var baseFolder = ""
    for path in sourcePaths:
      if path.len > 0 and isAbsolutePath(path):
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

  for pathIndex, path in sourcePaths:
    if path.len > 0:
      # echo "store path ", path
      let traceFilePath =
        if pathIndex < paths.len:
          filesFolder / tracePayloadRelativePath(paths[pathIndex], workdir)
        else:
          filesFolder / tracePayloadRelativePath(path, workdir)
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

proc deriveWorkdir(program: string): string =
  if program.len == 0:
    return getCurrentDir()

  try:
    let programPath = expandFilename(expandTilde(program))
    let parent = programPath.parentDir
    if parent.len > 0:
      return parent
  except CatchableError:
    discard

  getCurrentDir()

proc findCtFileInFolder(folder: string): string =
  ## Locate the canonical ``trace.ct`` (falling back to any ``*.ct``) in
  ## the trace folder.  M-REC-1.5: metadata always comes from this
  ## container's ``meta.dat``.
  if fileExists(folder / "trace.ct"):
    return folder / "trace.ct"
  for entry in walkDir(folder):
    if entry.kind == pcFile and entry.path.endsWith(".ct"):
      return entry.path
  ""

proc importTrace*(
  traceFolder: string,
  recordingIdArg: string,
  recordPid: int,
  langArg: Lang = LangNoir,
  selfContained: bool = true,
  downloadUrl: string = "",
  traceKind: string = "db",
): Trace =
  ## M-REC-3: ``recordingIdArg`` is a UUIDv7 recording-id (empty
  ## string == ``NO_RECORDING_ID`` means "mint a fresh one").

  # M-REC-1.5: metadata is read from the CTFS ``meta.dat`` inside
  # ``trace.ct``.  Legacy ``trace_metadata.json`` /
  # ``trace_db_metadata.json`` sidecars are no longer accepted; readers
  # raise if the container is missing.
  let ctPath = findCtFileInFolder(traceFolder)
  if ctPath.len == 0:
    raise newException(IOError,
      "importTrace: no `.ct` CTFS container found in " & traceFolder &
      " (legacy trace_metadata.json/trace_db_metadata.json sidecars retired in M-REC-1.5)")

  let meta = readCtfsMetaDat(ctPath)
  let program = meta.program
  var args = meta.args
  var workdir = meta.workdir
  if workdir.len == 0:
    workdir = deriveWorkdir(program)

  let traceID = if recordingIdArg != NO_RECORDING_ID:
      recordingIdArg
    else:
      trace_index.newID(test=false)

  let outputFolder = if recordingIdArg == NO_RECORDING_ID:
      # M-REC-2: folder name still uses the legacy ``trace-<id>`` form
      # because the on-disk layout rename is M-REC-7's scope.  We only
      # changed what ``<id>`` is.
      fmt"{codetracerTraceDir}/trace-{traceID}/"
    else:
      traceFolder
  if recordingIdArg == NO_RECORDING_ID:
    createDir(outputFolder)
    # Copy the CTFS container itself; downstream tooling treats it as the
    # source of truth.  Any sibling ``paths.json`` produced by
    # ``materializeCtfsSources`` is regenerated by callers as needed.
    let outputCt = outputFolder / "trace.ct"
    if ctPath != outputCt:
      copyFile(ctPath, outputCt)

  let paths: seq[string] = meta.paths

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
      storeTraceFiles(paths, outputFolder, workdir, lang)

  var sourceFoldersInitialSet = initHashSet[string]()
  for path in paths:
    if path.len > 0 and isAbsolutePath(path):
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
    # M-REC-1.5: the old `rr`/`ttd` branch used to deserialize a full
    # `Trace` object from the legacy `trace_db_metadata.json`.  With the
    # JSON sidecar retired, we use the same `recordTrace` call shape as
    # the `db` branch — the meta.dat-derived fields are sufficient.
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
      calltraceMode = loadCalltraceMode("", lang),
      fileId = downloadUrl)

proc getFolderSize(folderPath: string): int64 =
  var totalSize: int64 = 0
  for kind, path in walkDir(folderPath):
    if kind == pcFile:
      totalSize += getFileSize(path)
  return totalSize
