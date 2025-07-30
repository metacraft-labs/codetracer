import 
  std / [ options, strformat, strutils, osproc, os ],
  json_serialization, json_serialization / std / tables,
  ../utilities/[ env, zip ],
  ../cli/[ interactive_replay ],
  .. / launch / cleanup,
  ../../common/[ types, trace_index, start_utils, paths ],
  ../codetracerconf,
  shell,
  run

proc importTraceInPreparedFolder(traceZipPath: string, outputFolderFullPath: string) =
#   let res = execProcess(unzipExe, args = @[traceZipPath, "-d", outputFolderFullPath], options={})
#   echo "unzip: ", res
  zip.unzipIntoFolder(traceZipPath, outputFolderFullPath)
  let traceDbMetadata = Json.decode(readFile(outputFolderFullPath / "trace_db_metadata.json"), Trace)
  let newTraceId = trace_index.newID(test=false)
  var importedTrace = traceDbMetadata
  importedTrace.id = newTraceId
  importedTrace.outputFolder = outputFolderFullPath
  importedTrace.imported = true
  let t = trace_index.recordTrace(importedTrace, test=false)
  discard t
  echo "recorded with id ", newTraceId


proc importCommand*(traceZipPath: string, importedTraceFolder: string) =
  # codetracer import <trace-zip-path> [<imported-trace-folder>]
  let outputFolder = if importedTraceFolder.len > 0: importedTraceFolder else: changeFileExt(traceZipPath, "")

  # TODO: OVERWRITES the `outputFolder`, or an already imported trace there or other files!!!
  # think if we want to check and show an error if the folder exists?
  removeDir(outputFolder)

  createDir(outputFolder)
  let outputFolderFullPath = expandFilename(outputFolder)
  importTraceInPreparedFolder(traceZipPath, outputFolderFullPath)
