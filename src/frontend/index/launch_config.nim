## Parse VS Code launch.json for recording configurations
## This module runs in the ctIndex context and provides launch config parsing

import
  std/[jsffi, strutils, os, json, strformat],
  ../lib/[jslib],
  ../../common/ct_logging

# JavaScript Object global binding
var Object* {.importc, nodecl.}: JsObject

type
  LaunchConfig* = ref object
    name*: cstring
    program*: cstring
    args*: seq[cstring]
    cwd*: cstring
    configType*: cstring  # "launch" or "attach"
    env*: seq[tuple[key: cstring, value: cstring]]  # Environment variables

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

      # Only add if we have a program to run
      if launchConfig.program.len > 0:
        result.add(launchConfig)

    debugPrint fmt"Parsed {result.len} launch configs from launch.json"

  except:
    errorPrint fmt"Error parsing launch.json: {getCurrentExceptionMsg()}"

proc getLaunchConfigsForWorkspace*(workspaceFolder: cstring): seq[LaunchConfig] =
  ## Get launch configs for a given workspace folder
  ## Looks for .vscode/launch.json
  let launchJsonPath = ($workspaceFolder) / ".vscode" / "launch.json"
  return parseLaunchJson(launchJsonPath.cstring, workspaceFolder)
