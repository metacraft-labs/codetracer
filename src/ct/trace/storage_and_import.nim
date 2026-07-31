import
  std/[ os, strutils, strformat, sets, algorithm, sequtils, json ],
  ../../common/[ trace_index, lang, types, paths ],
  ../utilities/[ git, language_detection ],
  ctfs_sources,
  source_paths,
  trace_container,
  results

export trace_container

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

proc detectTraceLang*(program: string, paths: seq[string],
                      traceKind: string): Lang =
  ## Infer a recording's [Lang] from its recorded `program` identifier
  ## and captured source `paths`.
  ##
  ## The CTFS `meta.dat` stores both the recorded `program` argument (the
  ## path the user typed to ``ct record``, e.g. ``path/to/main.nim``) and
  ## the list of source paths actually captured during the recording.
  ## The pre-M-REC-1.5 code only consulted the paths; that left rr/ttd
  ## recordings of compiled-language traces classified as `LangUnknown`
  ## whenever the captured source list happened to start with a path
  ## whose extension is unknown to `detectLangFromPath` — ``program``
  ## itself was never used.  Probe ``program`` first so the visible
  ## "what was recorded" identifier always seeds detection, then fall
  ## back to scanning the captured paths.
  ##
  ## Factored out of `importTrace` so the session importer classifies a
  ## multi-recording session exactly the way a single recording is
  ## classified, rather than growing a second, drifting heuristic.
  let isWasm = program.extractFilename.split(".")[^1] == "wasm"
  var detectedLang = detectLangFromPath(program, isWasm)
  if detectedLang == LangUnknown:
    for path in paths:
      let p = detectLangFromPath(path, isWasm)
      if p != LangUnknown:
        detectedLang = p
        break
  if detectedLang == LangUnknown:
    return LangUnknown
  # for now assume this is used only for db traces
  # and that C/C++/Rust there can come only from wasm targets currently
  if detectedLang == LangRust:
    return if traceKind == "db": LangRustWasm else: LangRust
  if detectedLang in {LangC, LangCpp}:
    return if traceKind == "db": LangCppWasm else: detectedLang
  detectedLang

proc readTraceFolderMeta*(folder: string): CtfsMetaDat

proc readMaterializedTraceMeta*(folder: string): CtfsMetaDat =
  ## Read the metadata of a *materialized* `runtime_tracing` recording —
  ## the shape ``ct record-web`` writes for browser sessions — into the
  ## same [CtfsMetaDat] record the CTFS path produces, so `importTrace`
  ## has exactly one downstream code path.
  ##
  ## The sidecars are:
  ##
  ## * ``trace_metadata.json`` — ``{"program", "args", "workdir",
  ##   "recorder": {"name", "version"}}``.  This is *not* the retired
  ##   M-REC-1.5 ``trace_db_metadata.json`` (a serialized Nim ``Trace``);
  ##   it is the recorder-authored descriptor the Rust replay engine
  ##   reads today.
  ## * ``trace_paths.json`` — a flat JSON array of source paths.
  ##
  ## No ``recording_id`` is carried by this shape, so the field is left
  ## empty and `importTrace` mints a fresh UUIDv7 — the same behaviour a
  ## CTFS container with an absent id gets.
  ##
  ## Missing or malformed sidecars are tolerated field-by-field: a
  ## browser recording whose ``trace_paths.json`` failed to flush is
  ## still replayable (the event stream carries `Path` records), it just
  ## has no pre-extracted source list.  A malformed *metadata* file, by
  ## contrast, raises — silently importing a recording with an empty
  ## program name would produce an unopenable entry in the trace list.
  var program = ""
  var workdir = ""
  var args: seq[string] = @[]

  let metadataPath = folder / MATERIALIZED_TRACE_METADATA_FILE
  if fileExists(metadataPath):
    var metadata: JsonNode
    try:
      metadata = parseFile(metadataPath)
    except CatchableError as e:
      raise newException(IOError,
        "malformed " & MATERIALIZED_TRACE_METADATA_FILE & " in " & folder &
        ": " & e.msg)
    if metadata.kind != JObject:
      raise newException(IOError,
        "malformed " & MATERIALIZED_TRACE_METADATA_FILE & " in " & folder &
        ": expected a JSON object, got " & $metadata.kind)
    if metadata.hasKey("program") and metadata["program"].kind == JString:
      program = metadata["program"].getStr
    if metadata.hasKey("workdir") and metadata["workdir"].kind == JString:
      workdir = metadata["workdir"].getStr
    if metadata.hasKey("args") and metadata["args"].kind == JArray:
      for arg in metadata["args"]:
        if arg.kind == JString:
          args.add(arg.getStr)

  var paths: seq[string] = @[]
  let pathsPath = folder / MATERIALIZED_TRACE_PATHS_FILE
  if fileExists(pathsPath):
    try:
      let parsed = parseFile(pathsPath)
      if parsed.kind == JArray:
        for path in parsed:
          if path.kind == JString:
            paths.add(path.getStr)
    except CatchableError as e:
      echo "WARNING: ignoring malformed ", MATERIALIZED_TRACE_PATHS_FILE,
        " in ", folder, ": ", e.msg

  # ``program`` seeds language detection and is what the trace list
  # shows, so fall back to the folder name rather than leaving it blank.
  if program.len == 0:
    program = folder.lastPathPart

  CtfsMetaDat(
    recordingId: "",
    program: program,
    workdir: workdir,
    args: args,
    paths: paths)

proc readTraceFolderMeta*(folder: string): CtfsMetaDat =
  ## Read the metadata of the single recording stored in `folder`,
  ## whichever on-disk shape it uses.  Raises `IOError` with a
  ## folder-specific diagnostic when the folder holds no recording.
  ##
  ## Session manifests are not a single recording, so they are not
  ## considered here (`allowSession = false`).
  let shape = detectTraceFolderShape(folder, allowSession = false)
  case shape.kind
  of TraceShapeCtfs:
    readCtfsMetaDat(shape.path)
  of TraceShapeMaterialized:
    readMaterializedTraceMeta(folder)
  else:
    raise newException(IOError, describeMissingTraceContainer(folder))

proc copyMaterializedTracePayload(sourceFolder, outputFolder: string) =
  ## Copy a materialized `runtime_tracing` recording (event stream +
  ## sidecars) into the recording folder `importTrace` allocated for it.
  ## Mirrors the CTFS branch's single ``copyFile`` of the container.
  for name in MATERIALIZED_TRACE_EVENT_FILES:
    let source = sourceFolder / name
    if fileExists(source) and source != outputFolder / name:
      copyFile(source, outputFolder / name)
  for name in [MATERIALIZED_TRACE_METADATA_FILE, MATERIALIZED_TRACE_PATHS_FILE]:
    let source = sourceFolder / name
    if fileExists(source) and source != outputFolder / name:
      copyFile(source, outputFolder / name)

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

  # M-REC-1.5: for a CTFS recording, metadata is read from the
  # ``meta.dat`` inside ``trace.ct``; the retired
  # ``trace_db_metadata.json`` sidecar is not accepted.
  #
  # M41: a *materialized* `runtime_tracing` directory (``trace.json`` +
  # ``trace_metadata.json`` + ``trace_paths.json``) is also accepted.
  # That is the shape ``ct record-web`` writes for browser recordings
  # and the shape the Rust replay engine already replays — refusing it
  # here was the reason a browser recording could be replayed by every
  # headless suite in the repo yet never opened by the GUI.
  #
  # Sessions are deliberately *not* handled here: a ``session.toml``
  # names several recordings and belongs to `importSessionManifest`.
  let shape = detectTraceFolderShape(traceFolder, allowSession = false)
  if shape.kind == TraceShapeMissing:
    raise newException(IOError,
      "importTrace: " & describeMissingTraceContainer(traceFolder))

  # The folder the recording payload actually lives in.  This is
  # ``traceFolder`` itself in every case except the one-level descent
  # `detectTraceFolderShape` performs for the recorders that treat
  # ``--out-dir`` as the recording's PARENT (codetracer-js-recorder's
  # ``trace-<n>/``, codetracer-php-recorder's ``worker_<pid>/``).  Reading
  # the payload from ``traceFolder`` there would look for sidecars one
  # directory above the ones the detector just matched.
  let recordingSourceFolder = shape.folder

  let ctPath = if shape.kind == TraceShapeCtfs: shape.path else: ""
  let meta =
    if shape.kind == TraceShapeCtfs:
      readCtfsMetaDat(ctPath)
    else:
      readMaterializedTraceMeta(recordingSourceFolder)
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
    if shape.kind == TraceShapeCtfs:
      # Copy the CTFS container itself; downstream tooling treats it as
      # the source of truth.  Any sibling ``paths.json`` produced by
      # ``materializeCtfsSources`` is regenerated by callers as needed.
      let outputCt = outputFolder / CANONICAL_CT_FILE
      if ctPath != outputCt:
        copyFile(ctPath, outputCt)
    else:
      # M41: the materialized shape has no single container, so carry
      # the event stream and its sidecars across instead.  The replay
      # engine autodetects ``trace.json`` / ``trace.bin`` in the
      # recording folder exactly as it does in the recorder's output
      # folder (``dap_server.rs::auto_detect_materialized_trace_file``).
      copyMaterializedTracePayload(recordingSourceFolder, outputFolder)

  let paths: seq[string] = meta.paths

  let lang = if langArg != LangUnknown:
      langArg
    else:
      detectTraceLang(program, paths, traceKind)

  if dirExists(recordingSourceFolder / "files"):
    if recordingSourceFolder != outputFolder:
      copyDir(recordingSourceFolder / "files", outputFolder / "files")
      # The self-contained ``files/`` payload is only browsable if the
      # frontend can map trace path indices onto it.  ``importTraceFolder``
      # / ``importCtFile`` run ``materializeCtfsSources`` +
      # ``normalizeImportedTracePaths`` against ``traceFolder`` *before*
      # this import, leaving a ``paths.json`` whose entries are relative
      # to ``files/``.  Carry that sidecar into ``outputFolder`` so
      # ``loadFilenames`` finds it next to the copied ``files/`` payload
      # — without it the frontend falls back to the absolute recorder-
      # side paths and fails to open bundled sources on another machine.
      if fileExists(recordingSourceFolder / "paths.json") and
          not fileExists(outputFolder / "paths.json"):
        copyFile(recordingSourceFolder / "paths.json",
                 outputFolder / "paths.json")
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
