import
  std / [json, strutils, sequtils, jsffi, options],
  types,
  lib/jslib,
  ui / shortcut_presets,
  .. / common / ct_logging

export shortcut_presets

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
    configDir* = codetracerPrefix / "config"
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

# ---------------------------------------------------------------------------
# The bundled default configuration — THE GAP IN THE PLATFORM FACADE, named.
#
# ## This is not a second config layer, it is the missing supplier of an
# ## existing field
#
# `data.config` never originates in the renderer on either platform.  It
# arrives as ONE FIELD of the `CODETRACER::no-trace` payload — the message that
# puts CodeTracer into edit mode (`ui_js.nim`'s `onNoTrace`: `data.config =
# response.config`).  On the desktop the Electron INDEX process fills that
# field: it reads `~/.config/codetracer/.config.yaml` with `js-yaml` and
# computes `shortcutMap` with `initShortcutMap` — the proc directly above this
# comment (`index/config.nim:418-450`).
#
# A statically hosted tab has no index process.  That is the facade gap: the
# web platform has nobody to send `no-trace`, so the renderer has to compose
# the payload itself, and `config` is the one field of it that is not derivable
# from the bundled template.  This proc supplies exactly that field, using the
# SAME `initShortcutMap` the index process uses, from the SAME
# `default_config.yaml` the index process falls back to.  It is a platform
# implementation of one host capability, not a parallel configuration system:
# nothing else calls it, and `onNoTrace` cannot tell where the field came from.
#
# What breaks without it is worth naming, because it is why the page was bare.
# `configure(data)` tolerates a nil config (it reads no field), but everything
# edit mode then does, does not: `ui/menu.nim:157` indexes
# `config.shortcutMap.actionShortcuts` on the first `requestMenuRender`,
# `ui/shortcuts.nim:215` reads `conflictList`, and `ui/editor.nim:272` reads
# the same map for every Monaco editor created.  The topbar, the shortcut
# table and the editor all fail on one dereference, reported as
# `TypeError: reading 'shortcutMap' of null`.
#
# ## Why `staticRead` of the real file rather than a Nim literal
#
# `ui/welcome_screen.nim:462-468` already refused the alternative for the
# shortcut table, and the reason generalises: a hand-written second copy of
# `default_config.yaml` is two statements of the product's defaults that no
# test can tell apart until they disagree.  The precedent for reading the file
# at COMPILE time on this backend is in the renderer already —
# `renderer.nim:171-174` `staticRead`s the two Monaco theme JSONs — so this
# costs no request, which matters: `ci/test/noir-studio-signed-out.sh` asserts
# the development loop has ZERO egress sites and a `fetch` here would be the
# first one.
#
# ## Why a parser rather than `json.parse` or js-yaml
#
# `js-yaml` is a node dependency, `require`d only when `not defined(ctRenderer)`
# (`lib/misc_lib.nim:56-58`), and the web bundle has no `require` at all — that
# is what `ci/test/web-bundle-smoke.sh` exists to assert.  So the parser has to
# be Nim.  It handles exactly the shape `src/config/default_config.yaml` has
# and nothing more: `key: value` at column 0, one level of two-space nesting
# under a bare `key:`, `#` comments and blank lines.  There are no anchors, no
# sequences and no multi-line scalars in that file.
#
# WHAT KEEPS THAT HONEST is `shortcutBindingCount` at the bottom of this
# module and arm F of `ci/test/web-renderer-mounts.sh`, not a unit test — this
# module imports `frontend/types`, which imports `kdom`, so it compiles on
# neither the `vm-unit` lane (C backend) nor `vm-unit-js` (node): the renderer
# is a BROWSER module and node is not a browser, which is the same constraint
# `ci/test/renderer-browser-build.sh` exists under. The count therefore travels
# in the renderer line and is asserted against a real browser instead.

const defaultConfigYaml* = staticRead("../config/default_config.yaml")
  ## `src/config/default_config.yaml`, verbatim, at compile time.

type
  ConfigYamlEntry* = object
    ## One scalar from the bundled YAML.  `section` is "" for a top-level key
    ## and the parent key otherwise, so `bindings: { openFile: "CTRL+O" }`
    ## arrives as `(section: "bindings", key: "openFile", value: "CTRL+O")`.
    section*: string
    key*: string
    value*: string

proc parseSimpleYamlConfig*(raw: string): seq[ConfigYamlEntry] =
  ## The two-level subset of YAML `default_config.yaml` is written in.
  ##
  ## Exported so the parse can be exercised without building a `Config`, and
  ## kept separate from `defaultRendererConfig` for that reason. A fixture that
  ## grew an unsupported construct loses a key silently here; what catches that
  ## is the shortcut count on the renderer line — see `shortcutBindingCount`.
  result = @[]
  var section = ""
  for rawLine in raw.splitLines():
    let trimmed = rawLine.strip()
    if trimmed.len == 0 or trimmed[0] == '#':
      continue
    let indent = rawLine.len - rawLine.strip(leading = true, trailing = false).len
    let colon = trimmed.find(':')
    if colon <= 0:
      continue
    let key = trimmed[0 ..< colon].strip()
    var value = trimmed[colon + 1 .. ^1].strip()
    if value.len == 0:
      # A bare `key:` opens a section — but only at column 0.  Nesting deeper
      # than one level is not in the file and is deliberately not supported:
      # silently flattening it would be the drift this module exists to avoid.
      if indent == 0:
        section = key
      continue
    if value.len >= 2 and value[0] == '"' and value[^1] == '"':
      value = value[1 .. ^2]
    if indent == 0:
      section = ""
    result.add(ConfigYamlEntry(section: section, key: key, value: value))

proc yamlBool(value: string): bool =
  value == "true"

proc flowUIFromName*(name: cstring): FlowUI =
  ## `ui_js.nim`'s `loadFlowUI` lives behind the renderer's host-message
  ## handlers, which a web build never reaches; this is the same mapping where
  ## a hostless renderer can call it.
  case $name
  of "inline": FlowInline
  of "multiline": FlowMultiline
  else: FlowParallel

proc applyShortcutPreset*(bindings: JsAssoc[cstring, cstring];
                          preset: ShortcutPresetId) =
  ## Overwrite the nine preset-governed bindings, in place, before the map is
  ## built.
  ##
  ## THIS IS THE WHOLE INTEGRATION, and its smallness is the point. A preset
  ## changes VALUES in the `InputShortcutMap`; `initShortcutMap` below then
  ## produces the same `ShortcutMap` it always did, and every consumer —
  ## `configureShortcuts`' Mousetrap binds, `delegateShortcuts`' Monaco
  ## commands, `renderChord`'s labels, `loadShortcut`'s menu text and
  ## `toolbarTooltip`'s parentheses — follows without knowing presets exist.
  ##
  ## `Keyboard-Shortcuts-System.md` § Requirements is what forbids the
  ## alternative: a preset that installed its own binds would be "a chord bound
  ## in code and not routed through the YAML", which is one "the user cannot
  ## change and cannot discover".
  ##
  ## `spNone` DELETES rather than leaves. Its meaning is "the nine debugger
  ## commands have no chord", and leaving the YAML's would mean "the nine
  ## debugger commands have the chords you were trying to turn off".
  let chosen = presetOf(preset)
  for action in PresetActions:
    let key = cstring($action)
    let chord = chosen.chordFor(action)
    if chord.isSome:
      bindings[key] = cstring(chord.get)
    else:
      # `JsAssoc` has no `del`; assigning `undefined` is how a key is removed
      # from the iteration `initShortcutMap` performs over it.
      {.emit: ["delete ", bindings, "[", key, "];"].}

proc defaultRendererConfig*(preset: ShortcutPresetId =
                              DefaultShortcutPresetId): Config =
  ## The bundled defaults as a `Config` the renderer can use immediately.
  ##
  ## The `preset` argument defaults to `DefaultShortcutPresetId`, whose table
  ## is byte-for-byte `default_config.yaml`'s own — so every existing caller
  ## gets exactly the config it got before presets existed, and
  ## `shortcut_presets_test.nim` asserts that rather than assuming it.
  ##
  ## `rrBackend` is constructed explicitly and that is not decoration: it is a
  ## `ref object`, `ui/welcome_screen.nim:197` reads `.enabled` after checking
  ## only `config.isNil`, and a `Config` built without it converts one nil
  ## dereference into another one further away from its cause.
  result = Config(
    theme: cstring"default_dark",
    version: cstring"",
    flow: FlowConfigObjWrapper(enabled: true, ui: cstring"parallel",
                               realFlowUI: FlowParallel),
    layout: cstring"default_layout",
    default: cstring"",
    defaultBuild: cstring"",
    newTracePolicy: cstring"tab",
    rrBackend: RRBackendConfig(enabled: false, path: cstring""),
    bindings: JsAssoc[cstring, cstring]{})

  var bindings = JsAssoc[cstring, cstring]{}
  for entry in parseSimpleYamlConfig(defaultConfigYaml):
    case entry.section
    of "":
      case entry.key
      of "theme": result.theme = cstring(entry.value)
      of "version": result.version = cstring(entry.value)
      of "layout": result.layout = cstring(entry.value)
      of "default": result.default = cstring(entry.value)
      of "defaultBuild": result.defaultBuild = cstring(entry.value)
      of "newTracePolicy": result.newTracePolicy = cstring(entry.value)
      of "callArgs": result.callArgs = yamlBool(entry.value)
      of "history": result.history = yamlBool(entry.value)
      of "repl": result.repl = yamlBool(entry.value)
      of "trace": result.trace = yamlBool(entry.value)
      of "calltrace": result.calltrace = yamlBool(entry.value)
      of "telemetry": result.telemetry = yamlBool(entry.value)
      of "test": result.test = yamlBool(entry.value)
      of "debug": result.debug = yamlBool(entry.value)
      of "events": result.events = yamlBool(entry.value)
      of "showMinimap": result.showMinimap = yamlBool(entry.value)
      of "skipInstall": result.skipInstall = yamlBool(entry.value)
      else: discard
    of "flow":
      case entry.key
      of "enabled": result.flow.enabled = yamlBool(entry.value)
      of "ui": result.flow.ui = cstring(entry.value)
      else: discard
    of "rrBackend":
      case entry.key
      of "enabled": result.rrBackend.enabled = yamlBool(entry.value)
      of "path": result.rrBackend.path = cstring(entry.value)
      else: discard
    of "traceSharing":
      case entry.key
      of "enabled": result.traceSharing.enabled = yamlBool(entry.value)
      of "baseUrl": result.traceSharing.baseUrl = cstring(entry.value)
      of "downloadApi": result.traceSharing.downloadApi = cstring(entry.value)
      of "deleteApi": result.traceSharing.deleteApi = cstring(entry.value)
      of "getUploadUrlApi":
        result.traceSharing.getUploadUrlApi = cstring(entry.value)
      else: discard
    of "bindings":
      bindings[cstring(entry.key)] = cstring(entry.value)
    else:
      discard

  result.flow.realFlowUI = flowUIFromName(result.flow.ui)
  applyShortcutPreset(bindings, preset)
  result.bindings = bindings
  result.shortcutMap = initShortcutMap(bindings)

proc shortcutBindingCount*(config: Config): int =
  ## How many distinct key chords the config binds. `0` for a nil config, a
  ## nil map, or a `bindings:` section that did not parse.
  ##
  ## Exists to be REPORTED. `defaultRendererConfig` reads a compile-time
  ## fixture through a parser written for that fixture's shape, and the
  ## failure mode of both is silent: a `Config` with an empty `shortcutMap` is
  ## non-nil, dereferences cleanly everywhere `ui/menu.nim` and
  ## `ui/shortcuts.nim` touch it, and produces a product that mounts, paints
  ## and has no keyboard. Nothing in a DOM could tell that apart from a
  ## working one, so the renderer line carries the count and
  ## `ci/test/web-renderer-mounts.sh` asserts it — with arm F, which breaks the
  ## fixture's `bindings:` header, as the proof that the assertion can fail.
  if config.isNil or config.shortcutMap.shortcutActions.isNil:
    return 0
  for _, _ in config.shortcutMap.shortcutActions:
    result += 1
