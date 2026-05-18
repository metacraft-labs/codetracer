import
  std / [ os, strutils ],
  ../utilities/zip,
  ../../common/[ types, trace_index, lang ],
  storage_and_import,
  ../globals

proc importTraceInPreparedFolder(traceZipPath: string, outputFolderFullPath: string) =
#   let res = execProcess(unzipExe, args = @[traceZipPath, "-d", outputFolderFullPath], options={})
#   echo "unzip: ", res
  zip.unzipIntoFolder(traceZipPath, outputFolderFullPath)
  # M-REC-1.5: bundles must carry a CTFS `.ct` container; metadata comes
  # from its `meta.dat`.  Materialized DB traces and RR/TTD replay
  # traces alike now go through the same importTrace path.
  var hasCt = false
  for entry in walkDir(outputFolderFullPath):
    if entry.kind == pcFile and entry.path.endsWith(".ct"):
      hasCt = true
      break
  let traceKind =
    if hasCt:
      "db"
    else:
      "rr"
  var importedTrace = importTrace(
    outputFolderFullPath,
    NO_RECORDING_ID,
    NO_PID,
    LangUnknown,
    DB_SELF_CONTAINED_DEFAULT,
    traceKind = traceKind)
  if importedTrace.isNil:
    echo "error: failed to import trace metadata from ", outputFolderFullPath
    quit(1)
  echo "recorded with id ", importedTrace.recordingId


proc importCommand*(traceZipPath: string, importedTraceFolder: string) =
  # codetracer import <trace-zip-path> [<imported-trace-folder>]
  let outputFolder = if importedTraceFolder.len > 0: importedTraceFolder else: changeFileExt(traceZipPath, "")

  # TODO: OVERWRITES the `outputFolder`, or an already imported trace there or other files!!!
  # think if we want to check and show an error if the folder exists?
  removeDir(outputFolder)

  createDir(outputFolder)
  let outputFolderFullPath = expandFilename(expandTilde(outputFolder))
  importTraceInPreparedFolder(traceZipPath, outputFolderFullPath)
