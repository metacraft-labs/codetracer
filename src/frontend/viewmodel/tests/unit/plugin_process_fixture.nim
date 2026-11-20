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

import std/[json, os, osproc, strutils, times]

const
  PackageSrcDir* = currentSourcePath.parentDir / "plugin_packages" / "acme-tools"
  RepoRoot* = currentSourcePath.parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
  SdkDir* = RepoRoot / "src" / "plugin_sdk"

proc scratchRoot*(): string =
  result = getEnv("CT_PLUGIN_TEST_SCRATCH", getTempDir() / "ct-plugin-process-tests")
  createDir(result)

proc newestSource(): Time =
  result = fromUnix(0)
  for f in [PackageSrcDir / "acme_tools_plugins.nim",
            SdkDir / "codetracer_plugin_sdk.nim",
            RepoRoot / "src/frontend/viewmodel/plugin_host/protocol.nim",
            RepoRoot / "src/frontend/viewmodel/sync/mirror_session.nim"]:
    if fileExists(f):
      result = max(result, getLastModificationTime(f))

proc buildPackageExecutable*(): string =
  ## The built `acme-tools-plugins`, rebuilt when a source is newer.
  let outDir = scratchRoot() / "build"
  createDir(outDir)
  result = outDir / "acme-tools-plugins"
  if fileExists(result) and getLastModificationTime(result) > newestSource():
    return
  let nim = getCurrentCompilerExe()
  let cmd = quoteShellCommand([nim, "c", "--hints:off", "--warnings:off",
    "--threads:on", "--mm:orc", "-d:release",
    "--path:" & SdkDir,
    "--nimcache:" & outDir / "nimcache",
    "-o:" & result, PackageSrcDir / "acme_tools_plugins.nim"])
  let (output, code) = execCmdEx(cmd, workingDir = RepoRoot)
  doAssert code == 0, "building the acme-tools test package failed:\n" & output

proc installPackage*(root: string; manifest = ""): string =
  ## Install the package under `root` as `acme-tools@1.0.0`; returns the
  ## component directory. `manifest` replaces `plugin.json` when given.
  let exe = buildPackageExecutable()
  result = root / "acme-tools@1.0.0"
  createDir(result / "bin")
  copyFileWithPermissions(exe, result / "bin" / "acme-tools-plugins")
  writeFile(result / "plugin.json",
    if manifest.len > 0: manifest else: readFile(PackageSrcDir / "plugin.json"))

proc packageManifest*(): JsonNode =
  parseJson(readFile(PackageSrcDir / "plugin.json"))
