import
  json, strutils, sequtils, os, jsffi,
  karax,
  lib, paths, types
import ../common/ct_logging

let configPath* = ".config.yaml"

let testConfigPath* = ".config.yaml"

let defaultConfigPath* = "default_config.yaml"

let defaultLayoutPath* = "default_layout.json"

when not defined(ctRenderer):
  let configDir* = linksPath / "config"
  let userConfigDir* = getEnv("XDG_CONFIG_HOME", $home / ".config") / "codetracer"
  let userLayoutDir* = getEnv("XDG_CONFIG_HOME", $home / ".config") / "codetracer"


func normalize(shortcut: string): string =
  # for now we expect to write editor-style monaco shortcuts
  shortcut

proc initShortcutMap*(map: InputShortcutMap): ShortcutMap =
  result = ShortcutMap(shortcutActions: JsAssoc[cstring, ClientAction]{}, conflictList: @[])
  var conflicts = JsAssoc[cstring, seq[ClientAction]]{}
  for key, value in map:
    let rawShortcuts = ($value).splitWhitespace()
    var action: ClientAction
    try:
      action = parseEnum[ClientAction]($key)
    except:
      warnPrint "config: invalid shortcut action ", $key
      continue
    for raw in rawShortcuts:
      let normalShortcut = normalize(raw)
      var l = j""
      if normalShortcut == j"Delete":
        l = j"del"
      elif normalShortcut == j"RightArrow":
        l = j"right"
      elif normalShortcut == j"LeftArrow":
        l = j"left"
      else:
        l = j(($normalShortcut).toLowerAscii)

      let shortcut = Shortcut(renderer: l, editor: normalShortcut)
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


