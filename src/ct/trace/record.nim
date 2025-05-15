import std/[os, osproc, strutils, sequtils, strtabs, tables],
  ../../common/[ lang, paths, types, trace_index, config ],
  ../utilities/[language_detection ],
  ../cli/build

proc recordInternal(exe: string, args: seq[string], configPath: string): Trace =
  let env = if configPath.len > 0:
      setupEnv(configPath)
    else:
      var env = newStringTable(modeStyleInsensitive)
      for name, value in envPairs():
        env[name] = value
      env
  let p = startProcess(
    exe,
    args = args,
    env = env,
    options = {poStdErrToStdOut})

  let (lines, exCode) = p.readLines
  echo args
  echo exCode
  for line in lines:
    echo line

  if exCode == 0:
    let lastLine = lines[^1]
    if lastLine.startsWith("traceId:"):
      let traceId = parseInt(lastLine[8..^1])
      result = trace_index.find(traceId, test=false)

proc record*(lang: string,
             outputFolder: string,
             backend: string,
             exportFile: string,
             stylusTrace: string,
             program: string,
             args: seq[string]): Trace =
  let detectedLang = detectLang(program, toLang(lang))
  var pargs: seq[string] = @[]
  if lang != "":
    pargs.add("--lang")
    pargs.add(lang)
  if outputFolder != "" and outputFolder != ".":
    pargs.add("-o")
    pargs.add(outputFolder)
  if exportFile != "":
    pargs.add("-e")
    pargs.add(exportFile)
  if stylusTrace != "":
    pargs.add("--stylus-trace")
    pargs.add(stylusTrace)

  pargs.add(program)
  if args.len != 0:
    pargs = concat(pargs, args)

  if detectedLang in @[LangRubyDb, LangNoir, LangRustWasm, LangCppWasm, LangSmall]:
    return recordInternal(dbBackendRecordExe, pargs, "")
  else:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      let configPath = ctConfig.rrBackend.ctPaths
      return recordInternal(ctConfig.rrBackend.path, concat(@["record"], pargs), configPath)
    else:
      echo "This functionality requires a codetracer-rr-backend installation"
