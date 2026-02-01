import
  std / [json, strutils, sequtils, jsffi],
  types,
  lib/jslib,
  .. / common / ct_logging

let
  configPath* = ".config.yaml"
  testConfigPath* = ".config.yaml"
  defaultConfigPath* = "default_config.yaml"
  defaultLayoutPath* = "default_layout.json"

when not defined(ctRenderer):
  import
    std / os,
    paths

  let
    configDir* = linksPath / "config"
    userConfigDir* = getEnv("XDG_CONFIG_HOME", $home / ".config") / "codetracer"
    userLayoutDir* = getEnv("XDG_CONFIG_HOME", $home / ".config") / "codetracer"

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
      let normalShortcut = raw.cstring
      var l = cstring""
      if normalShortcut == cstring"Delete":
        l = cstring"del"
      elif normalShortcut == cstring"RightArrow":
        l = cstring"right"
      elif normalShortcut == cstring"LeftArrow":
        l = cstring"left"
      else:
        l = cstring(($normalShortcut).toLowerAscii)

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
