import std/[os, osproc, strutils, sequtils, strtabs],
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
  # echo args
  # echo exCode
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
             address: string,
             socketPath: string,
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
  if address != "":
    pargs.add("--address")
    pargs.add(address)
  if socketPath != "":
    pargs.add("--socket")
    pargs.add(socketPath)

  pargs.add(program)
  if args.len != 0:
    pargs = concat(pargs, args)

  # echo "detected lang ", detectedLang
  # TODO: eventually maybe simplify how this works
  # currently recording from startup screen form(index.nim)
  # calls `ct record` which calls another process and we need to
  # map correctly our `ct record` pid to the trace id
  # that's why we pass it as an env var to the process that
  # actually records in sqlite (except if in tup build
  # we already pass it from ct_wrapper)
  #
  # eventually Dimo/Petar want to simplify this to maybe
  # directly read the traceId from the record process output 
  if getEnv("CODETRACER_WRAPPER_PID", "").len == 0:
    putEnv("CODETRACER_WRAPPER_PID", $getCurrentProcessId())

  if detectedLang in @[LangRubyDb, LangNoir, LangRustWasm, LangCppWasm, LangSmall]:
    return recordInternal(dbBackendRecordExe, pargs, "")
  else:
    let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
    if ctConfig.rrBackend.enabled:
      let configPath = ctConfig.rrBackend.ctPaths
      return recordInternal(ctConfig.rrBackend.path, concat(@["record"], pargs), configPath)
    else:
      echo "This functionality requires a codetracer-rr-backend installation"
