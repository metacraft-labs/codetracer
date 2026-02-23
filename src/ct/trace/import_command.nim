import
  std / [ os ],
  ../utilities/zip,
  ../../common/[ types, trace_index, lang ],
  storage_and_import,
  ../globals

proc importTraceInPreparedFolder(traceZipPath: string, outputFolderFullPath: string) =
#   let res = execProcess(unzipExe, args = @[traceZipPath, "-d", outputFolderFullPath], options={})
#   echo "unzip: ", res
  zip.unzipIntoFolder(traceZipPath, outputFolderFullPath)
  let traceKind =
    if fileExists(outputFolderFullPath / "trace_metadata.json"):
      "db"
    else:
      # replay trace imports (RR/TTD) carry trace_db_metadata.json
      "rr"
  var importedTrace = importTrace(
    outputFolderFullPath,
    NO_TRACE_ID,
    NO_PID,
    LangUnknown,
    DB_SELF_CONTAINED_DEFAULT,
    traceKind = traceKind)
  if importedTrace.isNil:
    echo "error: failed to import trace metadata from ", outputFolderFullPath
    quit(1)
  echo "recorded with id ", importedTrace.id


proc importCommand*(traceZipPath: string, importedTraceFolder: string) =
  # codetracer import <trace-zip-path> [<imported-trace-folder>]
  let outputFolder = if importedTraceFolder.len > 0: importedTraceFolder else: changeFileExt(traceZipPath, "")

  # TODO: OVERWRITES the `outputFolder`, or an already imported trace there or other files!!!
  # think if we want to check and show an error if the folder exists?
  removeDir(outputFolder)

  createDir(outputFolder)
  let outputFolderFullPath = expandFilename(expandTilde(outputFolder))
  importTraceInPreparedFolder(traceZipPath, outputFolderFullPath)
