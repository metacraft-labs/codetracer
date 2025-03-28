import std/[os, osproc, strutils, sequtils],
  ../../common/[ lang, paths, types, trace_index, config ],
  ../utilities/[language_detection ],
  ../cli/build

proc record_internal(exe: string, args: seq[string], config_path: string): Trace =
  var env = setup_env(configPath)
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
             program: string,
             args: seq[string]): Trace =
  let detected_lang = detectLang(program, toLang(lang))
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
  pargs.add(program)
  if args.len != 0:
    pargs = concat(pargs, args)

  if detected_lang in @[LangRubyDb, LangNoir, LangSmall]:
    let configPath = getEnv(
      "CODETRACER_CT_PATHS",
      getAppDir().parentDir.parentDir.parentDir / "ct_paths.json")
    return record_internal(dbBackendRecordExe, pargs, configPath)
  else:
    let ct_config = loadConfig(folder=getCurrentDir(), inTest=false)
    if ct_config.rrBackendEnabled:
      let configPath = ct_config.rrBackendCtPaths
      return record_internal(ct_config.rrBackendPath, concat(@["record"], pargs), configPath)
    else:
      echo "This functionality requires a codetracer-rr-backend installation"
