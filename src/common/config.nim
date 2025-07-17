## keep this in sync with types.nim Config def
## a file with config code for the c backend, used mostly by ui_data for repl/tests

import json_serialization/std/tables, strutils, sequtils,  os, yaml, std/streams
import .. / common / [types, paths]

type
  RRBackendConfig* = object
    enabled*:           bool
    path*:              string
    ctPaths*:           string
    debugInfoToolPath*: string

  FlowConfigObjWrapper* = object
    enabled*:                             bool
    ui*:                                  string
    FlowUI* {.defaultVal: FlowParallel}:  types.FlowUI

  TraceSharingConfigObj* = object
    enabled*:               bool
    baseUrl*:               string
    getUploadUrlApi*:       string
    downloadApi*:           string
    deleteApi*:             string

  ConfigObject* = object
    ## The config object is the schema for config yaml files
    theme*:                                               string
    version*:                                             string

    flow* {.defaultVal: FlowConfigObjWrapper(
      enabled: true,
      ui: "parallel",
      FlowUI: FlowParallel
    ).}:                                                  FlowConfigObjWrapper

    callArgs*:                                            bool
    history*:                                             bool
    repl*:                                                bool
    trace*:                                               bool
    default*:                                             string
    calltrace*:                                           bool
    layout*:                                              string
    telemetry*:                                           bool
    test*:                                                bool
    debug*:                                               bool
    events*:                                              bool
    bindings*:                                            InputShortcutMap
    shortcutMap* {.defaultVal: ShortcutMap().}:           ShortcutMap
    defaultBuild*:                                        string
    showMinimap*:                                         bool

    traceSharing* {.defaultVal: TraceSharingConfigObj(
      enabled: false,
      baseUrl: "http://localhost:55504/api/codetracer/v1",
      downloadApi: "/download",
      deleteApi: "/delete",
      getUploadUrlApi: "/get/upload/url"
    ).}:                                                  TraceSharingConfigObj

    rrBackend* {.defaultVal: RRBackendConfig(
      enabled: false,
      path: "",
      ctPaths: "",
      debugInfoToolPath: ""
    ).}:                                                  RRBackendConfig
    skipInstall:                                          bool

  Config* = ref ConfigObject

  FlowUI* = enum FlowParallel, FlowInline, FlowMultiline

  BreakpointSave* = ref object
    # Serialized breakpoint
    line*:   int
    path*:   int

let configPath* = ".config.yaml"

let testConfigPath* = ".config.yaml"

let defaultConfigPath* = "default_config.yaml"

let defaultLayoutPath* = "default_layout.json"

let configDir* = linksPath / "config"

let userConfigDir* = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "codetracer"
let userLayoutDir* = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "codetracer"

func normalize(shortcut: string): string =
  # for now we expect to write editor-style monaco shortcuts
  shortcut

func initShortcutMap*(map: InputShortcutMap): ShortcutMap =
  result = ShortcutMap()
  var conflicts = initTable[string, seq[ClientAction]]()
  for key, value in map:
    let rawShortcuts = ($value).splitWhitespace()
    var action: ClientAction
    try:
      action = parseEnum[ClientAction]($key)
    except:
      debugecho "config.nim: invalid action ", $key
      continue
    for raw in rawShortcuts:
      let normalShortcut = normalize(raw)
      let shortcut = Shortcut(renderer: ($normalShortcut).toLowerAscii, editor: normalShortcut)
      if result.shortcutActions.hasKey(normalShortcut):
        if not conflicts.hasKey(normalShortcut):
          conflicts[normalShortcut] = @[result.shortcutActions[normalShortcut], action]
        else:
          conflicts[normalShortcut] = conflicts[normalShortcut].concat(@[action])
      else:
        result.shortcutActions[normalShortcut] = action
        result.actionShortcuts[action].add(shortcut)
  for key, value in conflicts:
    result.conflictList.add((key, value))
  return result

proc findConfig*(folder: string, configPath: string): string =
  var current = folder
  var config = false
  while true:
    let path = current / configPath
    if fileExists(path):
      return path
    else:
      if config:
        return ""
      current = current.parentDir
      if current == "":
        current = userConfigDir
        config = true

proc loadConfig*(folder: string, inTest: bool): Config =
  # ignore inTest from now: TODO eventually remove?
  var file = findConfig(folder, configPath)
  if file.len == 0:
    file = userConfigDir / configPath
    createDir(userConfigDir)
    copyFile(configDir / defaultConfigPath, userConfigDir / configPath)
  # if inTest:
  #   file = codetracerTestDir / testConfigPath
  var raw = ""
  try:
    raw = readFile(file)
  except CatchableError as e:
    echo "error: ", e.msg
    quit(1)
  try:
    var config: ConfigObject
    var stream = newStringStream(raw)
    load(stream, config)
    stream.close()
    var c = Config()
    c[] = config
    c.shortcutMap = initShortcutMap(config.bindings)
    return c
  except Exception as e:
    raise e
