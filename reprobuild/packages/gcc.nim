import repro_project_dsl

package gcc:
  executable gccTool:
    name "gcc"

proc actionIdForCompile(output: string): string =
  result = "gcc.compile"
  for ch in output:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '_', '-'}:
      result.add ch
    else:
      result.add "_"

proc compile*(source, output: string;
              actionId = "";
              pic = false;
              debug3 = false;
              compileOnly = true;
              includes: seq[string] = @[];
              depfile = "";
              cacheable = true;
              commandStatsId = "";
              dependencyPolicy = automaticMonitorPolicy()):
    BuildActionDef {.discardable.} =
  var args: seq[PublicCliArg] = @[]
  if pic:
    args.add(cliArg("pic", true, alias = "-fPIC"))
  if debug3:
    args.add(cliArg("debug3", true, alias = "-g3"))
  if compileOnly:
    args.add(cliArg("compileOnly", true, alias = "-c"))
  for path in includes:
    args.add(inputArg("include", path, alias = "-include"))
  args.add(outputArg("output", output, alias = "-o"))
  args.add(inputArg("source", source, kind = cpkPositional, position = 0))

  let selectedActionId =
    if actionId.len > 0: actionId else: actionIdForCompile(output)
  recordToolInvocation(
    selectedActionId,
    publicCliCall("gcc", "gcc", "", "gcc.gcc", args),
    depfile = depfile,
    cacheable = cacheable,
    commandStatsId = commandStatsId,
    dependencyPolicy = dependencyPolicy)
