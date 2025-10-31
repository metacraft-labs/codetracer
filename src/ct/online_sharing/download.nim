import streams, nimcrypto, std/[ terminal, options, strutils, strformat, os, httpclient, uri, net, json ]
import ../../common/[ config, trace_index, paths, lang, types ]
import ../utilities/[ types, zip, language_detection ]
import ../trace/storage_and_import, ../globals
import remote

proc downloadFile(url: string, outputPath: string): int =
  runCtRemote(@["download", url, "--output", outputPath])

proc downloadTrace*(url: string): int =
  let traceId = trace_index.newID(false)

  let downloadTarget = codetracerTmpPath / fmt"downloaded-trace-{traceId}.zip"

  let unzippedLocation = codetracerTraceDir / "trace-" & $traceId

  let downloadExitCode = downloadFile(url, downloadTarget)
  if downloadExitCode != 0:
    echo "error: problem: `ct-remote download` failed"
    quit(downloadExitCode)

  unzipIntoFolder(downloadTarget, unzippedLocation)
  removeFile(downloadTarget)

  let tracePath = unzippedLocation / "trace.json"
  let traceJson = parseJson(readFile(tracePath))
  let traceMetadataPath = unzippedLocation / "trace_metadata.json"
  let metadataJson = parseJson(readFile(traceMetadataPath))
  let tracePathsMetadata = parseJson(readFile(unzippedLocation / "trace_paths.json"))
  let isWasm = metadataJson{"program"}.getStr("").extractFilename.split(".")[^1] == "wasm" # Check if language is wasm

  var pathValue = ""
  for item in tracePathsMetadata:
    if item.getStr("") != "":
      pathValue = item.getStr("")
      break

  let lang = detectLang(pathValue.extractFilename, LangUnknown, isWasm)
  let recordPid = NO_PID # for now not processing the pid , but it can be 
  # accessed from trace metadata file if we need it in the future
  discard importDbTrace(traceMetadataPath, traceId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT, url)
  return traceId

proc downloadTraceCommand*(traceDownloadUrl: string) =
  try:
    let traceId = downloadTrace(traceDownloadUrl)
    if isatty(stdout):
      echo fmt"OK: downloaded with trace id {traceId}"
    else:
      # being parsed by `ct` index code
      echo traceId

  except CatchableError as e:
    echo fmt"error: downloading file '{e.msg}'"
    quit(1)
