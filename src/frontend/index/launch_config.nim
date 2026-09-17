## Parse VS Code launch.json for recording configurations
## This module runs in the ctIndex context and provides launch config parsing

import
  std/[jsffi, strutils, os, json, strformat],
  ../lib/[jslib, electron_lib],
  ../../common/ct_logging

# JavaScript Object global binding
var Object* {.importc, nodecl.}: JsObject

type
  HcrLaunchSettings* = ref object
    ## The `hcr` block of a launch configuration — what turns an ordinary
    ## "run this program" entry into "run this program under hot code reload".
    ##
    ## It lives in `.vscode/launch.json` beside `program`, `args`, `cwd` and
    ## `env` because that is where this product already answers the question
    ## "which program, with which arguments, in which directory, with which
    ## environment" (`getLaunchConfigsForWorkspace`, the Welcome screen's
    ## launch list, `CODETRACER::record-with-launch-config`). A live-edit launch
    ## needs exactly those four plus three more, so it is the same question with
    ## three more fields rather than a new configuration system — and it is a
    ## PROJECT FILE, checked in beside the code, which an environment variable
    ## exported into one shell is not.
    ##
    ## Unknown keys are ignored, and every optional field has a documented
    ## default, so a configuration is as short as:
    ##
    ## ```json
    ## "hcr": {
    ##   "coordinator": "${workspaceFolder}/artifacts/h5-driver/hcr_patch_driver",
    ##   "targetSymbol": "_ZN5flame8FlameSim15advanceExistingEv",
    ##   "applyEditCommand": "${workspaceFolder}/scripts/ct_hcr_apply_edit.py"
    ## }
    ## ```
    platform*: cstring
      ## Optional Node platform (`linux` or `win32`). When several HCR launch
      ## configurations exist, CodeTracer chooses the one for this host. An
      ## empty value keeps older, platform-independent configurations valid.
    coordinator*: cstring
      ## The HCR patch driver, which CodeTracer starts in `--session` mode.
      ## Linux starts it before the program; Windows starts it after the target
      ## PID exists. Required.
    targetSymbol*: cstring
      ## The function patches are published into. Required.
    applyEditCommand*: cstring
      ## The project's apply-edit command. When a launch configuration names
      ## one, it takes precedence over `CODETRACER_HCR_APPLY_EDIT_CMD` for the
      ## session that configuration opened.
    applyEditInterpreter*: cstring
      ## Optional executable used to run that command (a Python interpreter,
      ## typically, on hosts where the script is not directly executable).
    sessionDir*: cstring
      ## Where the coordinator's session lives. Optional; defaults to a
      ## pid-keyed directory under CodeTracer's temp path. Worth setting
      ## explicitly when something outside the product — a gate, a log
      ## collector — needs to find the session's own summary afterwards.
    agentSocketEnv*: cstring
      ## The environment variable the in-target agent reads the coordinator's
      ## socket from on Linux. Optional; defaults to
      ## `REPRO_HCR_AGENT_SOCKET`.
    agentDll*: cstring
      ## Windows in-target agent DLL. CodeTracer passes it to the patchable
      ## target as `REPRO_HCR_AGENT_DLL`. Required on Windows.
    targetImage*: cstring
      ## Windows PE image that contains `targetSymbol`. Required on Windows.
    targetPdb*: cstring
      ## Full PDB matching `targetImage`. Required on Windows.
    firstInstructionLength*: int
      ## Length of the target's first instruction, used by the Windows direct
      ## patch profile. Required and positive on Windows.
    coordinatorListenTimeoutMs*: int
      ## Linux: how long to wait for the coordinator's socket. 0 = default.
    readyTimeoutMs*: int
      ## How long to wait for the target and coordinator to negotiate.
      ## 0 = default. Bounded because a failed startup cannot heal itself.
    idleTimeoutMs*: int
      ## How long the coordinator holds an idle session open. 0 = default.

  LaunchConfig* = ref object
    name*: cstring
    program*: cstring
    args*: seq[cstring]
    cwd*: cstring
    configType*: cstring  # "launch" or "attach"
    env*: seq[tuple[key: cstring, value: cstring]]  # Environment variables
    hcr*: HcrLaunchSettings
      ## `nil` unless the configuration carries an `hcr` block. A configuration
      ## without one is an ordinary launch/record entry and is unaffected by
      ## everything above.

proc substituteVariables(value: cstring, workspaceFolder: cstring): cstring =
  ## Substitute VS Code variables like ${workspaceFolder}
  var res = $value
  res = res.replace("${workspaceFolder}", $workspaceFolder)
  res = res.replace("${workspaceFolderBasename}", ($workspaceFolder).splitPath().tail)
  # Add more variable substitutions as needed
  res.cstring

proc parseLaunchJson*(launchJsonPath: cstring, workspaceFolder: cstring): seq[LaunchConfig] =
  ## Parse a VS Code launch.json file and return launch configurations
  ## Only returns configs with type "launch" (skip "attach")
  result = @[]

  try:
    let fs = require("fs")
    if not cast[bool](fs.existsSync(launchJsonPath)):
      debugPrint fmt"launch.json not found at {launchJsonPath}"
      return

    let content = fs.readFileSync(launchJsonPath, js{encoding: cstring"utf8"}).to(cstring)
    let jsonObj = JSON.parse(content)

    if jsonObj.isNil or jsonObj["configurations"].isUndefined:
      debugPrint "launch.json has no configurations"
      return

    let configurations = jsonObj["configurations"]
    let configsLen = cast[int](configurations.length)

    for i in 0..<configsLen:
      let config = configurations[i]

      # Skip if not a launch config (e.g., "attach" configs)
      let configType = config["type"].to(cstring)
      let request = config["request"].to(cstring)
      if request != cstring"launch":
        continue

      var launchConfig = LaunchConfig(
        configType: configType,
        name: cstring"",
        program: cstring"",
        args: @[],
        cwd: workspaceFolder,
        env: @[]
      )

      # Get name
      if not config["name"].isUndefined:
        launchConfig.name = config["name"].to(cstring)

      # Get program path with variable substitution
      if not config["program"].isUndefined:
        let rawProgram = config["program"].to(cstring)
        launchConfig.program = substituteVariables(rawProgram, workspaceFolder)

      # Get args array
      if not config["args"].isUndefined:
        let argsArray = config["args"]
        let argsLen = cast[int](argsArray.length)
        for j in 0..<argsLen:
          let arg = argsArray[j].to(cstring)
          launchConfig.args.add(substituteVariables(arg, workspaceFolder))

      # Get cwd with variable substitution
      if not config["cwd"].isUndefined:
        let rawCwd = config["cwd"].to(cstring)
        launchConfig.cwd = substituteVariables(rawCwd, workspaceFolder)

      # Get environment variables
      if not config["env"].isUndefined:
        let envObj = config["env"]
        let keys = Object.keys(envObj)
        let keysLen = cast[int](keys.length)
        for j in 0..<keysLen:
          let key = keys[j].to(cstring)
          let value = envObj[key].to(cstring)
          launchConfig.env.add((key: key, value: substituteVariables(value, workspaceFolder)))

      # The `hcr` block, when there is one. Paths inside it go through the same
      # `${workspaceFolder}` substitution as `program` and `cwd`: a launch
      # configuration that had to spell out an absolute path for the coordinator
      # while spelling a variable for the program would not be checkinable
      # beside the code, which is the whole reason it lives here.
      if not config["hcr"].isUndefined and not config["hcr"].isNil:
        let hcrObj = config["hcr"]
        proc hcrString(key: cstring): cstring =
          if hcrObj[key].isUndefined or hcrObj[key].isNil:
            cstring""
          else:
            substituteVariables(hcrObj[key].to(cstring), workspaceFolder)
        proc hcrInt(key: cstring): int =
          if hcrObj[key].isUndefined or hcrObj[key].isNil:
            0
          else:
            cast[int](hcrObj[key])
        launchConfig.hcr = HcrLaunchSettings(
          platform: hcrString(cstring"platform"),
          coordinator: hcrString(cstring"coordinator"),
          targetSymbol: hcrString(cstring"targetSymbol"),
          applyEditCommand: hcrString(cstring"applyEditCommand"),
          applyEditInterpreter: hcrString(cstring"applyEditInterpreter"),
          sessionDir: hcrString(cstring"sessionDir"),
          agentSocketEnv: hcrString(cstring"agentSocketEnv"),
          agentDll: hcrString(cstring"agentDll"),
          targetImage: hcrString(cstring"targetImage"),
          targetPdb: hcrString(cstring"targetPdb"),
          firstInstructionLength: hcrInt(cstring"firstInstructionLength"),
          coordinatorListenTimeoutMs: hcrInt(cstring"coordinatorListenTimeoutMs"),
          readyTimeoutMs: hcrInt(cstring"readyTimeoutMs"),
          idleTimeoutMs: hcrInt(cstring"idleTimeoutMs"))

      # Only add if we have a program to run
      if launchConfig.program.len > 0:
        result.add(launchConfig)

    debugPrint fmt"Parsed {result.len} launch configs from launch.json"

  except:
    errorPrint fmt"Error parsing launch.json: {getCurrentExceptionMsg()}"

proc getLaunchConfigsForWorkspace*(workspaceFolder: cstring): seq[LaunchConfig] =
  ## Get launch configs for a given workspace folder
  ## Looks for .vscode/launch.json
  let launchJsonPath = nodePath.join(workspaceFolder, cstring".vscode", cstring"launch.json")
  return parseLaunchJson(launchJsonPath.cstring, workspaceFolder)
