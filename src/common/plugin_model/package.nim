## plugin_model/package.nim — a plugin PACKAGE: one `plugin.json` listing one
## or more plugins and the native executable that hosts them
## (Extensibility-Model.md §11.2.2, §11.3).
##
##   {
##     "package": "acme-tools",
##     "host": { "kind": "native", "executable": "bin/acme-tools-plugins" },
##     "plugins": [ { "id": "acme-tools.metrics", … }, { "id": "acme-tools.flame", … } ]
##   }
##
## Each entry of `plugins` is an ordinary §4.1 manifest and goes through
## `parseManifest` unchanged, so every rule PLAT-7 to PLAT-10 enforce on a
## manifest holds for each plugin of a package. This module adds the package's
## own rules:
##
## * **Identity** (§11.2.2). `package` is the component name it was installed
##   as, and each plugin id is either that name (a one-plugin package) or
##   `<package>.<local-name>`.
## * **WASM packages** (§11.9). `{"kind": "wasm", "module": "plugin.wasm"}`:
##   one module for every platform, loaded by CodeTracer's own
##   `ct-plugin-host`, each plugin in its own instance. A WASM plugin declares
##   only the grants it uses, possibly none: its reach is the imports the host
##   gives its instance, not the user's authority.
## * **Native means `process`** (§11.3). Every plugin of a native package must
##   DECLARE `process`; the host does not infer it. The package's executable is
##   added to each plugin's declared `executables`, because running it is
##   exactly what the grant covers and a manifest should not have to say so
##   twice.
## * **No native views** (§11.11, answered 2026-11-20). A third-party surface
##   declaring `nativeViews` is refused.
## * **Key bindings** (§11.7.2) are read per plugin, and the reserved keys are
##   refused by the host, which knows the active palette key.
## * **Settings** (§11.2.2): each plugin may declare a settings schema; the
##   user's `plugins.<id>.settings` are validated against it.

import std/[json, os, strutils]

import ../key_names
import ./diagnostics
import ./manifest

type
  PackageHostKind* = enum
    phkNative = "native"
    phkWasm = "wasm"

  SettingSpec* = object
    name*: string
    kind*: JsonNodeKind
    default*: JsonNode

  PackagedPlugin* = object
    parsed*: ParsedManifest
    text*: string
      ## The plugin's own manifest text, as `PluginHost.register` reads it.
    bindings*: seq[tuple[key, op, scope, whenClause: string]]
    capturesWindowInput*: bool
    capturesWindowInputReason*: string
    settings*: seq[SettingSpec]

  PluginPackage* = object
    name*: string
    hostKind*: PackageHostKind
    executable*: string
      ## Relative to the component directory. For a WASM package, the module.
    plugins*: seq[PackagedPlugin]
    errors*: seq[PluginError]

func isOk*(p: PluginPackage): bool =
  if p.errors.len > 0:
    return false
  for pl in p.plugins:
    if not pl.parsed.isOk:
      return false
  true

func pluginIds*(p: PluginPackage): seq[string] =
  for pl in p.plugins:
    result.add pl.parsed.manifest.id

func allErrors*(p: PluginPackage): seq[PluginError] =
  result = p.errors
  for pl in p.plugins:
    result.add pl.parsed.errors

func isPackageDocument*(root: JsonNode): bool =
  ## A `plugin.json` is a package when it lists `plugins`.
  not root.isNil and root.kind == JObject and root.hasKey("plugins")

func idBelongsTo*(id, component: string): bool =
  ## §11.2.2's generalised identity rule.
  id == component or (id.startsWith(component & ".") and
                      id.len > component.len + 1)

proc kindOfSchemaType(t: string; dest: var JsonNodeKind): bool =
  case t
  of "string": dest = JString
  of "boolean": dest = JBool
  of "integer": dest = JInt
  of "number": dest = JFloat
  of "object": dest = JObject
  of "array": dest = JArray
  else: return false
  true

proc parsePluginPackage*(text, source, component: string): PluginPackage =
  ## Read one package. `component` is the name it was installed as.
  let named = if component.len > 0: component else: UnknownPluginId
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    result.errors.add pluginError(named, pecMalformedManifest,
      source & ": " & e.msg)
    return
  if not isPackageDocument(root):
    result.errors.add pluginError(named, pecBadPackage,
      source & ": a package lists its plugins under 'plugins'")
    return
  result.name = root{"package"}.getStr("")
  if result.name.len == 0:
    result.errors.add pluginError(named, pecBadPackage,
      source & ": 'package' is required")
  elif component.len > 0 and result.name != component:
    result.errors.add pluginError(result.name, pecBadPackage,
      source & ": the package is called '" & result.name &
      "' but is installed as component '" & component & "'. `ct install`, " &
      "`ct uninstall` and `.ctrc` spell the component, so the two must agree")
  let pkgName = if result.name.len > 0: result.name else: named

  let host = root{"host"}
  if host.isNil or host.kind != JObject:
    result.errors.add pluginError(pkgName, pecBadPackage,
      source & ": 'host' is required: {\"kind\": \"native\", \"executable\": …}")
  else:
    let kind = host{"kind"}.getStr("")
    let field = if kind == "wasm": "module" else: "executable"
    case kind
    of "native": result.hostKind = phkNative
    of "wasm": result.hostKind = phkWasm
    else:
      result.errors.add pluginError(pkgName, pecBadPackage,
        source & ": host kind '" & kind & "' is not supported; a package is " &
        "hosted by a 'native' plugin process or by CodeTracer's 'wasm' host")
    result.executable = host{field}.getStr("")
    if result.executable.len == 0:
      result.errors.add pluginError(pkgName, pecBadPackage,
        source & ": 'host." & field & "' is required")
    elif result.executable.isAbsolute or ".." in result.executable.split({'/', '\\'}):
      result.errors.add pluginError(pkgName, pecBadPackage,
        source & ": 'host." & field & "' must be a path inside the component, " &
        "not '" & result.executable & "'")
    elif result.hostKind == phkWasm and
         not result.executable.toLowerAscii.endsWith(".wasm"):
      result.errors.add pluginError(pkgName, pecBadPackage,
        source & ": 'host.module' names a WebAssembly module (a '.wasm' " &
        "file), not '" & result.executable & "'")

  let plugins = root{"plugins"}
  if plugins.kind != JArray or plugins.len == 0:
    result.errors.add pluginError(pkgName, pecBadPackage,
      source & ": 'plugins' must be a non-empty array")
    return
  # A WASM module is not an executable: nothing runs it but the host, and
  # declaring it would hand the plugin a `process` declaration it never asked
  # for.
  let exeName = if result.hostKind == phkNative: result.executable.extractFilename
                else: ""
  var seen: seq[string]
  for i, entry in plugins.getElems:
    var e = entry
    var pp: PackagedPlugin
    if e.kind == JObject and exeName.len > 0:
      e = e.copy
      # The package's executable is what `process` runs: declared once, for
      # every plugin it hosts.
      if not e.hasKey("executables"):
        e["executables"] = newJArray()
      if e["executables"].kind == JArray:
        var has = false
        for x in e["executables"]:
          if x.getStr("") == exeName: has = true
        if not has:
          e["executables"].add %exeName
    pp.text = $e
    let src = source & " plugins[" & $i & "]"
    pp.parsed = parseManifest(pp.text, src)
    let m = pp.parsed.manifest
    let pid = if m.id.len > 0: m.id else: UnknownPluginId
    if m.id.len > 0:
      if m.id in seen:
        pp.parsed.errors.add pluginError(m.id, pecDuplicatePlugin,
          src & ": the package lists '" & m.id & "' twice")
      seen.add m.id
      if pkgName != UnknownPluginId and not idBelongsTo(m.id, pkgName):
        pp.parsed.errors.add pluginError(m.id, pecPluginIdComponentMismatch,
          src & ": a plugin of package '" & pkgName & "' is called '" &
          pkgName & "' or '" & pkgName & ".<name>', not '" & m.id & "'")
    # §11.3. Declared, never inferred.
    if result.hostKind == phkNative and e.kind == JObject:
      var declared = false
      let caps = e{"capabilities"}
      if not caps.isNil and caps.kind == JArray:
        for c in caps:
          if c.getStr("") == $capProcess: declared = true
      if not declared:
        pp.parsed.errors.add pluginError(pid, pecNativeWithoutProcess,
          src & ": '" & pid & "' is hosted by the native program '" &
          result.executable & "', which runs with your full authority. A " &
          "native plugin must declare the 'process' grant so that the grant " &
          "screen says so")
    # §11.11: no native views from a third party.
    for c in m.contributions:
      if c.nativeFrontEnds.len > 0:
        pp.parsed.errors.add pluginError(pid, pecNativeViewRefused,
          src & ": surface '" & c.id & "' declares 'nativeViews'. A plugin " &
          "composes the shared view vocabulary, images and sandboxed frames; " &
          "native views are drawn only by CodeTracer itself")
    # §11.7.2 static bindings.
    let kb = e{"keybindings"}
    if not kb.isNil and kb.kind == JArray:
      let commands = m.commandIds
      for b in kb:
        # The modifiers' spelling folded, the key's own case kept: `J` is
        # not `j` (`key_names.bindingKeyName`).
        let key = bindingKeyName(b{"key"}.getStr(""))
        let op = b{"command"}.getStr(b{"op"}.getStr(""))
        if key.len == 0 or op.len == 0:
          pp.parsed.errors.add pluginError(pid, pecMissingField,
            src & ": a key binding needs 'key' and 'command'")
          continue
        if op notin commands:
          pp.parsed.errors.add pluginError(pid, pecUnknownCommand,
            src & ": key '" & key & "' is bound to '" & op &
            "', which the plugin does not contribute")
        pp.bindings.add (key: key, op: op,
                         scope: b{"scope"}.getStr("window"),
                         whenClause: b{"when"}.getStr(""))
    # §11.7.3.
    let cwi = e{"capturesWindowInput"}
    if not cwi.isNil:
      if cwi.kind == JObject:
        pp.capturesWindowInput = true
        pp.capturesWindowInputReason = cwi{"reason"}.getStr("")
      elif cwi.kind == JBool and cwi.getBool:
        pp.capturesWindowInput = true
      if pp.capturesWindowInput and pp.capturesWindowInputReason.len == 0:
        pp.parsed.errors.add pluginError(pid, pecMissingField,
          src & ": 'capturesWindowInput' must say why: " &
          "{\"reason\": \"…\"}; the grant screen shows it")
    # §11.2.2 settings schema.
    let schema = e{"settings"}
    if not schema.isNil and schema.kind == JObject:
      let props = schema{"properties"}
      if not props.isNil and props.kind == JObject:
        for name, spec in props:
          var k: JsonNodeKind
          if not kindOfSchemaType(spec{"type"}.getStr(""), k):
            pp.parsed.errors.add pluginError(pid, pecBadSetting,
              src & ": setting '" & name & "' has no readable 'type'")
            continue
          pp.settings.add SettingSpec(name: name, kind: k,
                                      default: spec{"default"})
    result.plugins.add pp

proc wrapSingleManifest*(text, source, component, executable: string):
    PluginPackage =
  ## A one-plugin `plugin.json` written before packages existed, given the
  ## executable that hosts it, read as a one-plugin package.
  var root: JsonNode
  try:
    root = parseJson(text)
  except CatchableError as e:
    result.errors.add pluginError(component, pecMalformedManifest,
      source & ": " & e.msg)
    return
  let doc = %*{"package": component,
               "host": {"kind": "native", "executable": executable},
               "plugins": [root]}
  parsePluginPackage($doc, source, component)

proc validateSettings*(pp: PackagedPlugin; given: JsonNode;
                       problems: var seq[PluginError]): JsonNode =
  ## The effective settings: every declared setting at its default, then the
  ## user's values that the schema accepts. A value it does not accept, and a
  ## name it does not declare, is a problem naming the plugin and the setting.
  let id = pp.parsed.manifest.id
  result = newJObject()
  for s in pp.settings:
    if not s.default.isNil:
      result[s.name] = s.default
  if given.isNil or given.kind != JObject:
    return
  for name, value in given:
    var spec: SettingSpec
    var found = false
    for s in pp.settings:
      if s.name == name:
        spec = s
        found = true
    if not found:
      problems.add pluginError(id, pecBadSetting,
        "plugins." & id & ".settings." & name & " is not a setting this " &
        "plugin declares")
      continue
    let ok = value.kind == spec.kind or
             (spec.kind == JFloat and value.kind == JInt)
    if not ok:
      problems.add pluginError(id, pecBadSetting,
        "plugins." & id & ".settings." & name & " must be " & $spec.kind &
        ", not " & $value.kind)
      continue
    result[name] = value
