## plugin_process_fixture.nim — builds the `acme-tools` test package
## (`plugin_packages/acme-tools/`) and installs it as a component, the way
## `ct install` lays one out: `<root>/acme-tools@1.0.0/{plugin.json, bin/…}`.
##
## The executable is compiled with the compiler running this suite, against
## the plugin SDK in this tree, into a private cache keyed by the sources'
## modification times, so a suite that runs twice builds once.
##
## Nothing here stands in for anything: the package is a real plugin, built
## the way a third party builds one.
##
## Both backends: under `nim js` (the Node suites) the same package is built
## by running the same compiler (`getCurrentCompilerExe`, fixed when the suite
## was compiled) through Node's `child_process`, and the files go through
## `common/node_os`. The plugin is a NATIVE executable either way, which is the
## point: Node spawns it as the desktop's main process and `ct host` do.

import std/[json, strutils]
when defined(js):
  import std/jsffi
  import ../../../../common/node_os
  proc readFile(path: string): string = readFileBytes(path)
  proc writeFile(path, content: string) = writeFileBytes(path, content)
  proc jsMtimeMs(path: cstring): float {.importjs: """
    (function (p) {
      try { return require('fs').statSync(p).mtimeMs; } catch (e) { return -1; }
    })(#)""".}
  proc jsRun(cmd: cstring; args: seq[cstring]; cwd: cstring): JsObject {.
      importjs: """
    (function (cmd, args, cwd) {
      var r = require('child_process').spawnSync(cmd, args,
        { cwd: cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
      return { code: r.status === null ? -1 : r.status,
               output: String(r.stdout || '') + String(r.stderr || '') +
                       (r.error ? String(r.error) : '') };
    })(#, #, #)""".}
  proc jsCopyExecutable(src, dst: cstring) {.importjs: """
    (function (s, d) {
      var fs = require('fs');
      fs.copyFileSync(s, d);
      fs.chmodSync(d, fs.statSync(s).mode);
    })(#, #)""".}
  const NimExe = getCurrentCompilerExe()
else:
  import std/[os, osproc, times]

const
  PackageSrcDir* = currentSourcePath.parentDir / "plugin_packages" / "acme-tools"
  RepoRoot* = currentSourcePath.parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
  SdkDir* = RepoRoot / "src" / "plugin_sdk"

proc scratchRoot*(): string =
  result = getEnv("CT_PLUGIN_TEST_SCRATCH", getTempDir() / "ct-plugin-process-tests")
  createDir(result)

const PackageSources = [PackageSrcDir / "acme_tools_plugins.nim",
                        SdkDir / "codetracer_plugin_sdk.nim",
                        RepoRoot / "src/frontend/viewmodel/plugin_host/protocol.nim",
                        RepoRoot / "src/frontend/viewmodel/sync/mirror_session.nim"]

when defined(js):
  proc newestSourceMs(): float =
    result = 0
    for f in PackageSources:
      result = max(result, jsMtimeMs(cstring(f)))
else:
  proc newestSource(): Time =
    result = fromUnix(0)
    for f in PackageSources:
      if fileExists(f):
        result = max(result, getLastModificationTime(f))

proc buildPackageExecutable*(): string =
  ## The built `acme-tools-plugins`, rebuilt when a source is newer.
  let outDir = scratchRoot() / "build"
  createDir(outDir)
  result = outDir / "acme-tools-plugins"
  let args = @["c", "--hints:off", "--warnings:off",
    "--threads:on", "--mm:orc", "-d:release",
    "--path:" & SdkDir,
    "--nimcache:" & outDir / "nimcache",
    "-o:" & result, PackageSrcDir / "acme_tools_plugins.nim"]
  when defined(js):
    if fileExists(result) and jsMtimeMs(cstring(result)) > newestSourceMs():
      return
    var cargs: seq[cstring]
    for a in args: cargs.add cstring(a)
    let r = jsRun(cstring(NimExe), cargs, cstring(RepoRoot))
    doAssert r["code"].to(int) == 0, "building the acme-tools test package " &
      "failed:\n" & $r["output"].to(cstring)
  else:
    if fileExists(result) and getLastModificationTime(result) > newestSource():
      return
    let nim = getCurrentCompilerExe()
    let cmd = quoteShellCommand(@[nim] & args)
    let (output, code) = execCmdEx(cmd, workingDir = RepoRoot)
    doAssert code == 0, "building the acme-tools test package failed:\n" & output

proc installPackage*(root: string; manifest = ""): string =
  ## Install the package under `root` as `acme-tools@1.0.0`; returns the
  ## component directory. `manifest` replaces `plugin.json` when given.
  let exe = buildPackageExecutable()
  result = root / "acme-tools@1.0.0"
  createDir(result / "bin")
  when defined(js):
    jsCopyExecutable(cstring(exe), cstring(result / "bin" / "acme-tools-plugins"))
  else:
    copyFileWithPermissions(exe, result / "bin" / "acme-tools-plugins")
  writeFile(result / "plugin.json",
    if manifest.len > 0: manifest else: readFile(PackageSrcDir / "plugin.json"))

proc packageManifest*(): JsonNode =
  parseJson(readFile(PackageSrcDir / "plugin.json"))
