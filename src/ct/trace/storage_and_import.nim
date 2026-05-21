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
  ## M-REC-3: ``recordingIdArg`` is a UUIDv7 recording-id.
  ##
  ## M-REC-10: when ``recordingIdArg == NO_RECORDING_ID`` (the empty
  ## string, the typical case from ``ct replay --trace-folder``), the
  ## recording-id stored in the folder's ``meta.dat`` is preserved as the
  ## DB row's primary key.  This is what makes cross-machine moves
  ## (`scp` a folder, replay on the other host) terminate with the same
  ## id on both hosts, per parent spec §8 ("Two machines holding the
  ## same recording should observe the same id.").  Pre-M-REC-10 this
  ## branch minted a fresh UUIDv7 via ``trace_index.newID`` which silently
  ## broke the migration's primary goal.
  ##
  ## Callers that explicitly want a fresh id (for example, the
  ## online-sharing download path on the receiving host when the upload
  ## was anonymised) should pass an explicit non-empty
  ## ``recordingIdArg``.

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

  # M-REC-10: prefer the id in meta.dat over minting a new one when the
  # caller passed ``NO_RECORDING_ID``.  ``readCtfsMetaDat`` validates the
  # length (36 chars) so we can trust ``meta.recordingId`` to be the
  # canonical UUIDv7 form here; on the rare path where it is somehow
  # absent (only possible if a future codec regression slips an empty
  # field through), we fall back to minting a fresh one to keep the
  # importer's failure surface unchanged.
  let traceID =
    if recordingIdArg != NO_RECORDING_ID:
      recordingIdArg
    elif meta.recordingId.len == 36:
      meta.recordingId
    else:
      trace_index.newID(test=false)

  let outputFolder = if recordingIdArg == NO_RECORDING_ID:
      # M-REC-7: folder name is the bare UUIDv7 ``recording_id``.  The
      # pre-M-REC-7 ``trace-<int_id>`` / ``trace-<uuid>`` form was
      # retired so that on-disk and DB identities match exactly, which
      # is what makes folders portable across machines (parent spec §4).
      #
      # M-REC-10: ``traceID`` here is the *meta.dat-derived* id, so when
      # the user has already placed the folder under
      # ``<codetracerTraceDir>/<recording_id>/`` (the canonical "scp into
      # place" workflow), this computation is a self-reference and no
      # copy happens below.
      recordingFolder(codetracerTraceDir, traceID)
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
    # The CTFS `meta.dat` stores both the recorded `program` argument
    # (the path the user typed to `ct record`, e.g.
    # `path/to/main.nim`) and the list of source paths actually
    # captured during the recording.  The pre-M-REC-1.5 code only
    # consulted `meta.paths`; that left rr/ttd recordings of
    # compiled-language traces classified as `LangUnknown` whenever
    # the captured source list happened to start with a path whose
    # extension is unknown to `detectLangFromPath` — `program` itself
    # was never used.  Probe `program` first so the visible
    # "what was recorded" identifier always seeds detection, then
    # fall back to scanning the captured paths exactly as before.
    let isWasm = program.extractFilename.split(".")[^1] == "wasm"
    var detectedLang = detectLangFromPath(program, isWasm)
    if detectedLang == LangUnknown:
      for path in paths:
        let p = detectLangFromPath(path, isWasm)
        if p != LangUnknown:
          detectedLang = p
          break
    if detectedLang != LangUnknown:
      # for now assume this is used only for db traces
      # and that C/C++/Rust there can come only from wasm targets currently
      if detectedLang == LangRust:
        lang = if traceKind == "db": LangRustWasm else: LangRust
      elif detectedLang in {LangC, LangCpp}:
        lang = if traceKind == "db": LangCppWasm else: detectedLang
      else:
        lang = detectedLang

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
