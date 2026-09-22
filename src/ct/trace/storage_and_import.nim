import
  std/[ options, os, strutils, strformat, sets, algorithm, sequtils, json ],
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

proc storeTraceFiles(paths: seq[string], traceFolder, workdir: string,
                     axes: TargetAxes) =
  let filesFolder = traceFolder / "files"
  createDir(filesFolder)

  var sourcePaths = paths.mapIt(resolveTraceSourcePath(it, workdir))

  # The project-manifest sweep below is for recordings whose sources live in a
  # project directory (`Nargo.toml`, `Cargo.toml`, …) rather than beside the
  # program.  It used to be keyed by `lang in {LangNoir, LangRustWasm,
  # LangCppWasm}`, which is the ISA spelled as a language: the ACIR and wasm
  # targets are exactly the two.  LRS-5's second deletion round deleted the
  # two wasm members, so it is keyed by the ISA -- the same set, named on the
  # axis it belongs to, and now also true of a C wasm module, which never had
  # a `Lang` value at all.
  if axes.targetIsa in {tiAcir, tiWasm}:
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

proc detectTraceAxes*(program: string, paths: seq[string],
                      traceKind: string): TargetAxes =
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
  ##
  ## ## It answers AXES, not a `Lang` (LRS-5, precondition (d))
  ##
  ## This used to be `detectTraceLang` and it was one of the three writers of
  ## `LangRustWasm` / `LangCppWasm`: for a **db-kind** container whose sources
  ## are Rust or C/C++ it answered the wasm member, because "this is a
  ## materialized wasm recording rather than a native one" had nowhere else to
  ## go — `recordings.lang` held one `Lang` name.  Since schema version 2 the
  ## column holds all four axes, so the same two facts are stated on the axes
  ## they belong to: the LANGUAGE from the path, the ISA from the artefact
  ## (`targetIsaForArtefactPath`) or from the container's kind, and the
  ## APPROACH from the ISA.
  ##
  ## Two consequences, both deliberate and neither a widening of what is
  ## claimed:
  ##
  ## * a `.c` source in a db-kind container is now `slC` + `tiWasm`, where it
  ##   used to be `LangCppWasm` — i.e. reported as **C++**, because there was
  ##   no `LangCWasm` member to report.  The ISA is unchanged; the language is
  ##   no longer rounded to its neighbour.
  ## * an rr/MCR container is untouched: `traceKind != "db"` leaves the
  ##   per-language fallback ISA and `raMcr`, which is what `LangRust` /
  ##   `LangC` / `LangCpp` decomposed to before.
  var detectedLang = detectLangFromPath(program)
  if detectedLang == LangUnknown:
    for path in paths:
      let p = detectLangFromPath(path)
      if p != LangUnknown:
        detectedLang = p
        break

  let artefactIsa = targetIsaForArtefactPath(program)
  if detectedLang == LangUnknown and artefactIsa == tiUnknown:
    return storageAxesOfLang(LangUnknown)

  var axes = storageAxesOfLang(detectedLang)
  if artefactIsa != tiUnknown:
    # The recorded program IS the artefact and names its own ISA (`foo.wasm`).
    axes.targetIsa = artefactIsa
    axes.approach = defaultRecordingApproach(artefactIsa)
  elif traceKind == "db" and detectedLang in {LangC, LangCpp, LangRust}:
    # For now assume a db-kind container whose sources are C/C++/Rust can only
    # have come from a wasm target: those three languages reach a MATERIALIZED
    # container by no other route today.  This is the same assumption the
    # `LangRustWasm` / `LangCppWasm` answer encoded, kept verbatim and now
    # visible as the two axes it always was.
    axes.targetIsa = tiWasm
    axes.approach = raVmEmulation
  axes

proc detectTraceLang*(program: string, paths: seq[string],
                      traceKind: string): Lang =
  ## The `Lang` SUMMARY of `detectTraceAxes` — kept for callers that need a
  ## label rather than a route.  A wasm Rust recording summarises as
  ## `LangRust`: the ISA and the approach are on `detectTraceAxes`' result and
  ## in the stored cell, not in this value.
  langForStorageAxes(detectTraceAxes(program, paths, traceKind)).lang

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
  axesArg: Option[TargetAxes] = none(TargetAxes),
): Trace =
  ## ``axesArg`` — LRS-5, precondition (b).  The four-axis value to REGISTER
  ## the recording under, when the caller observed one.  ``ct record`` does:
  ## the dispatch selector it just recorded with carries the language, the ISA
  ## and the approach, so a wasm recording is registered as
  ## ``rs-wasm-unknown-vm`` without anything having to name a ``LangRustWasm``
  ## member.  When it is ``none`` the axes are derived here, from ``langArg``
  ## or from ``detectTraceAxes``, exactly as the ``Lang``-only callers expect.
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

  let axes =
    if axesArg.isSome: axesArg.get
    elif langArg != LangUnknown: storageAxesOfLang(langArg)
    else: detectTraceAxes(program, paths, traceKind)
  # The summary is derived from the axes rather than kept beside them, so the
  # row's label and the row's cell can never disagree.
  let lang = if langArg != LangUnknown and axesArg.isNone:
      langArg
    else:
      langForStorageAxes(axes).lang

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
      storeTraceFiles(paths, outputFolder, workdir, axes)

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
      fileId = downloadUrl,
      axesArg = some(axes))
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
      calltraceMode = loadCalltraceMode("", axes),
      fileId = downloadUrl,
      axesArg = some(axes))

proc getFolderSize(folderPath: string): int64 =
  var totalSize: int64 = 0
  for kind, path in walkDir(folderPath):
    if kind == pcFile:
      totalSize += getFileSize(path)
  return totalSize
