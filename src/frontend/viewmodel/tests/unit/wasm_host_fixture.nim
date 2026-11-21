## wasm_host_fixture.nim — the real `ct-plugin-host` and real WebAssembly
## plugin packages, for the suites that drive them through the `Supervisor`.
##
## * The host is the binary `src/plugin-host/build.sh` builds
##   (`just build-plugin-host`), found at `CT_PLUGIN_HOST_BIN` or
##   `build/bin/ct-plugin-host`. Its absence FAILS by name, with the recipe:
##   a suite about the WASM host that skipped without one would be green
##   about nothing.
## * Each module is built from its Nim source by
##   `src/plugin_sdk/build-wasm-plugin.sh` — the toolchain a plugin author
##   uses — into a cache keyed by the CONTENT of its sources (a mutation
##   harness restores a subject with its old modification time).
## * A package is installed the way `ct install` lays a component out:
##   `<root>/<name>@<version>/{plugin.json, plugin.wasm}`.

import std/[hashes, json, os, osproc, strutils]

const
  RepoRoot* = currentSourcePath.parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
  WasmPluginsDir* = RepoRoot / "src" / "frontend" / "viewmodel" / "tests" /
                    "unit" / "wasm_plugins"
  SdkDir* = RepoRoot / "src" / "plugin_sdk"
  HostRecipe* = "just build-plugin-host"

proc wasmScratchRoot*(): string =
  result = getEnv("CT_PLUGIN_TEST_SCRATCH", getTempDir() / "ct-plugin-process-tests") /
           "wasm-host"
  createDir(result)

proc pluginHostBin*(): string =
  ## The `ct-plugin-host` under test.
  result = getEnv("CT_PLUGIN_HOST_BIN", RepoRoot / "build" / "bin" / "ct-plugin-host")
  doAssert fileExists(result), "the WASM plugin host is not built: " & result &
    " does not exist. Build it with `" & HostRecipe & "` (or set " &
    "CT_PLUGIN_HOST_BIN)"

proc sourceKey(files: seq[string]; extra: string): string =
  var h: Hash = hash(extra)
  for f in files:
    if fileExists(f):
      h = h !& hash(f) !& hash(readFile(f))
  $(!$h)

proc sdkSources*(): seq[string] =
  @[SdkDir / "codetracer_plugin_sdk.nim", SdkDir / "wasm_io.nim",
    SdkDir / "build-wasm-plugin.sh",
    RepoRoot / "src/frontend/viewmodel/plugin_host/protocol.nim",
    RepoRoot / "src/frontend/viewmodel/plugin_host/plugin_io.nim",
    RepoRoot / "src/frontend/viewmodel/sync/mirror_session.nim"]

proc buildWasmModule*(source, name: string; flags: seq[string] = @[];
                      extraSources: seq[string] = @[]): string =
  ## `source` built to `<scratch>/modules/<name>.wasm`, rebuilt when a source
  ## changed.
  let outDir = wasmScratchRoot() / "modules"
  createDir(outDir)
  result = outDir / (name & ".wasm")
  let stamp = result & ".sources"
  let key = sourceKey(@[source] & extraSources & sdkSources(), flags.join(" "))
  if fileExists(result) and fileExists(stamp) and readFile(stamp) == key:
    return
  let cmd = quoteShellCommand(@["bash", SdkDir / "build-wasm-plugin.sh",
                                source, result] & flags)
  let (output, code) = execCmdEx(cmd, workingDir = RepoRoot)
  doAssert code == 0, "building " & name & ".wasm failed:\n" & output
  writeFile(stamp, key)

proc testModule*(package: string): string =
  ## One of `wasm_plugins/wasm_test_plugins.nim`'s packages.
  buildWasmModule(WasmPluginsDir / "wasm_test_plugins.nim", package,
                  @["-d:ctWasmTestPackage=" & package])

proc installWasmPackage*(root, name: string; manifest: JsonNode;
                         module: string; version = "1.0.0"): string =
  ## A component directory for one WASM package; returns it.
  result = root / (name & "@" & version)
  removeDir(result)
  createDir(result)
  copyFile(module, result / "plugin.wasm")
  writeFile(result / "plugin.json", manifest.pretty)

proc wasmPlugin*(id: string; commands: openArray[string] = [];
                 statusItems: openArray[string] = [];
                 capabilities: openArray[string] = [];
                 readPaths: openArray[string] = []): JsonNode =
  ## One plugin entry of a WASM package's `plugin.json`.
  var cmds = newJArray()
  for c in commands: cmds.add %*{"id": c, "title": c}
  var items = newJArray()
  for s in statusItems: items.add %*{"id": s, "title": s, "views": ["Text"]}
  result = %*{"id": id, "version": "1.0.0",
              "requires": {"core": ">=1.0.0 <2.0.0"},
              "capabilities": capabilities,
              "activation": [{"event": "trace-opened"}],
              "contributes": {"command": cmds, "statusItem": items}}
  if readPaths.len > 0:
    result["paths"] = %*{"read": readPaths}

proc wasmPackage*(name: string; plugins: seq[JsonNode]): JsonNode =
  %*{"package": name, "host": {"kind": "wasm", "module": "plugin.wasm"},
     "plugins": plugins}

proc processAlive*(pid: int): bool =
  pid > 0 and execCmdEx("kill -0 " & $pid).exitCode == 0
